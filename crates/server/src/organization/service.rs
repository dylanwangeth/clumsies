use std::collections::BTreeSet;

use time::OffsetDateTime;
use uuid::Uuid;

use crate::api::*;
use crate::auth::{AuthPrincipal, user_capabilities};
use crate::repository::{ServerError, ServerRepository};

use super::postgres;

impl ServerRepository {
    pub async fn get_me(&self, principal: &AuthPrincipal) -> Result<MeResponse, ServerError> {
        let mut tx = self.pool().begin().await?;
        let user = postgres::load_user_ref(&mut tx, &principal.user_id).await?;
        let org = postgres::load_org_ref(&mut tx, &principal.org_id).await?;
        let projects =
            postgres::list_project_refs(&mut tx, &principal.org_id, &principal.user_id).await?;
        let response = MeResponse {
            user,
            org,
            default_project_id: projects.first().map(|project| project.project_id.clone()),
            projects,
            capabilities: user_capabilities(&principal.role),
        };
        tx.commit().await?;
        Ok(response)
    }

    pub async fn ensure_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
    ) -> Result<(), ServerError> {
        if postgres::project_member_exists(
            self.pool(),
            project_id,
            &principal.org_id,
            &principal.user_id,
        )
        .await?
        {
            Ok(())
        } else {
            Err(ServerError::not_found("project", project_id))
        }
    }

    pub async fn list_kanban_issues(
        &self,
        project_id: &str,
    ) -> Result<KanbanIssueListResponse, ServerError> {
        Ok(KanbanIssueListResponse {
            items: postgres::list_kanban_issues(self.pool(), project_id).await?,
        })
    }

    pub async fn import_kanban_issues(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        request: ImportKanbanIssuesRequest,
    ) -> Result<KanbanIssueListResponse, ServerError> {
        if request.items.is_empty() || request.items.len() > 999 {
            return Err(ServerError::InvalidRequest(
                "Kanban import must contain between 1 and 999 Issues".to_owned(),
            ));
        }
        let mut identities = BTreeSet::new();
        for item in &request.items {
            validate_kanban_issue_payload(
                project_id,
                &item.issue_id,
                item.issue_number,
                item.content_revision,
                &item.payload,
            )?;
            if !identities.insert((item.issue_id.clone(), item.issue_number)) {
                return Err(ServerError::InvalidRequest(
                    "Kanban import contains duplicate Issue identities".to_owned(),
                ));
            }
        }
        let mut tx = self.pool().begin().await?;
        for item in request.items {
            postgres::insert_kanban_issue(
                &mut tx,
                project_id,
                &item.issue_id,
                item.issue_number,
                &principal.user_id,
                item.content_revision,
                item.payload,
            )
            .await?;
        }
        tx.commit().await?;
        self.list_kanban_issues(project_id).await
    }

    pub async fn update_kanban_issue(
        &self,
        project_id: &str,
        issue_id: &str,
        request: UpdateKanbanIssueRequest,
    ) -> Result<KanbanIssue, ServerError> {
        let identity = request.payload.get("issue").unwrap_or(&request.payload);
        let issue_number = identity
            .get("issue_number")
            .and_then(serde_json::Value::as_i64)
            .ok_or_else(|| {
                ServerError::InvalidRequest("Issue payload has no issue_number".to_owned())
            })?;
        validate_kanban_issue_payload(
            project_id,
            issue_id,
            issue_number,
            request.content_revision,
            &request.payload,
        )?;
        let updated = postgres::update_kanban_issue(
            self.pool(),
            project_id,
            issue_id,
            request.content_revision,
            request.payload,
            request.expected_content_revision,
        )
        .await?;
        if !updated {
            let actual = postgres::kanban_content_revision(self.pool(), project_id, issue_id)
                .await?
                .ok_or_else(|| ServerError::not_found("kanban_issue", issue_id))?;
            return Err(ServerError::version_conflict(
                "kanban_issue",
                request.expected_content_revision,
                actual,
            ));
        }
        postgres::load_kanban_issue(self.pool(), project_id, issue_id).await
    }

    pub async fn assign_kanban_issue(
        &self,
        project_id: &str,
        issue_id: &str,
        assignee_user_id: &str,
    ) -> Result<KanbanIssue, ServerError> {
        if !postgres::assign_kanban_issue(self.pool(), project_id, issue_id, assignee_user_id)
            .await?
        {
            return Err(ServerError::InvalidRequest(
                "Assignee must be a member of this Project".to_owned(),
            ));
        }
        postgres::load_kanban_issue(self.pool(), project_id, issue_id).await
    }

    pub async fn delete_kanban_issue(
        &self,
        project_id: &str,
        issue_id: &str,
    ) -> Result<DeleteResult, ServerError> {
        if !postgres::delete_kanban_issue(self.pool(), project_id, issue_id).await? {
            return Err(ServerError::not_found("kanban_issue", issue_id));
        }
        Ok(DeleteResult {
            deleted: true,
            id: issue_id.to_owned(),
        })
    }

    pub async fn list_issue_claims(
        &self,
        project_id: &str,
    ) -> Result<IssueClaimListResponse, ServerError> {
        Ok(IssueClaimListResponse {
            items: postgres::list_issue_claims(self.pool(), project_id).await?,
        })
    }

    pub async fn acquire_issue_claim(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        issue_id: &str,
        request: AcquireIssueClaimRequest,
    ) -> Result<IssueClaim, ServerError> {
        validate_issue_claim_input(issue_id, &request)?;
        let Some(claim) = postgres::acquire_issue_claim(
            self.pool(),
            project_id,
            issue_id,
            &request.issue_key,
            &principal.user_id,
            &request.run_id,
            request.lease_expires_at,
        )
        .await?
        else {
            return Err(ServerError::already_exists("issue_claim", issue_id));
        };
        Ok(IssueClaim {
            project_id: claim.project_id,
            issue_id: claim.issue_id,
            issue_key: claim.issue_key,
            run_id: claim.run_id,
            claimant: postgres::load_user_ref_from_pool(self.pool(), &principal.user_id).await?,
            claimed_at: claim.claimed_at,
            lease_expires_at: claim.lease_expires_at,
        })
    }

    pub async fn release_issue_claim(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        issue_id: &str,
        run_id: &str,
    ) -> Result<bool, ServerError> {
        if issue_id.trim().is_empty() || run_id.trim().is_empty() {
            return Err(ServerError::InvalidRequest(
                "issue_id and run_id must not be empty".to_owned(),
            ));
        }
        postgres::release_issue_claim(
            self.pool(),
            project_id,
            issue_id,
            &principal.user_id,
            run_id,
        )
        .await
    }

    pub async fn get_admin_org(&self, org_id: &str) -> Result<AdminOrg, ServerError> {
        postgres::load_admin_org(self.pool(), org_id).await
    }

    pub async fn update_admin_org(
        &self,
        principal: &AuthPrincipal,
        expected_revision: i64,
        request: UpdateAdminOrgRequest,
    ) -> Result<AdminOrg, ServerError> {
        let mut tx = self.pool().begin().await?;
        let current = postgres::lock_admin_org(&mut tx, &principal.org_id).await?;
        if current.revision != expected_revision {
            return Err(ServerError::version_conflict(
                "org",
                expected_revision,
                current.revision,
            ));
        }
        let name = match request.name {
            Some(name) if !name.trim().is_empty() => name.trim().to_owned(),
            Some(_) => {
                return Err(ServerError::InvalidRequest(
                    "organization name must not be empty".to_owned(),
                ));
            }
            None => current.name,
        };
        let allowed_email_domains = match request.allowed_email_domains {
            Some(domains) => normalize_email_domains(domains)?,
            None => current.allowed_email_domains,
        };
        postgres::update_admin_org(&mut tx, &principal.org_id, &name, &allowed_email_domains)
            .await?;
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.org_updated",
            "org",
            Some(&principal.org_id),
        )
        .await?;
        tx.commit().await?;
        self.get_admin_org(&principal.org_id).await
    }

    pub async fn list_admin_members(
        &self,
        offset: i64,
        limit: i64,
    ) -> Result<MemberListResponse, ServerError> {
        let items = postgres::list_admin_members(self.pool(), offset, limit + 1).await?;
        let (items, page_info) = admin_page(items, offset, limit);
        Ok(MemberListResponse { items, page_info })
    }

    pub async fn create_admin_member(
        &self,
        principal: &AuthPrincipal,
        request: CreateMemberRequest,
    ) -> Result<Member, ServerError> {
        if request.role == OrgRole::Owner && principal.role != "owner" {
            return Err(ServerError::Forbidden(
                "only an organization owner can create another owner".to_owned(),
            ));
        }
        let email = normalize_email(&request.email)?;
        let allowed_domains =
            postgres::load_allowed_email_domains(self.pool(), &principal.org_id).await?;
        enforce_invited_email_domain(&email, &allowed_domains)?;
        if postgres::member_email_exists(self.pool(), &email).await? {
            return Err(ServerError::InvalidRequest(
                "a member with this email already exists".to_owned(),
            ));
        }
        let user_id = prefixed_id("usr");
        let mut tx = self.pool().begin().await?;
        postgres::insert_member(&mut tx, &user_id, &email, request.role.as_str()).await?;
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.member_created",
            "user",
            Some(&user_id),
        )
        .await?;
        tx.commit().await?;
        postgres::load_member(self.pool(), &user_id).await
    }

    pub async fn update_admin_member(
        &self,
        principal: &AuthPrincipal,
        user_id: &str,
        expected_revision: i64,
        request: UpdateMemberRequest,
    ) -> Result<Member, ServerError> {
        if user_id == principal.user_id
            && (request
                .role
                .is_some_and(|role| role.as_str() != principal.role)
                || request
                    .status
                    .is_some_and(|status| status != MemberStatus::Active))
        {
            return Err(ServerError::InvalidRequest(
                "the current user cannot change their own role or active status".to_owned(),
            ));
        }
        let mut tx = self.pool().begin().await?;
        let current = postgres::lock_member(&mut tx, user_id).await?;
        if current.revision != expected_revision {
            return Err(ServerError::version_conflict(
                "member",
                expected_revision,
                current.revision,
            ));
        }
        let next_role = request
            .role
            .map(|role| role.as_str().to_owned())
            .unwrap_or_else(|| current.role.clone());
        let next_status = request
            .status
            .map(|status| status.as_str().to_owned())
            .unwrap_or_else(|| current.status.clone());
        if principal.role != "owner" && (current.role == "owner" || next_role == "owner") {
            return Err(ServerError::Forbidden(
                "only an organization owner can modify an owner account".to_owned(),
            ));
        }
        let removes_active_owner = current.role == "owner"
            && current.status == "active"
            && (next_role != "owner" || next_status != "active");
        if removes_active_owner && postgres::active_owner_count(&mut tx).await? <= 1 {
            return Err(ServerError::InvalidRequest(
                "the last active organization owner cannot be disabled or demoted".to_owned(),
            ));
        }
        postgres::update_member(&mut tx, user_id, &next_role, &next_status).await?;
        if next_status == "disabled" {
            postgres::revoke_user_sessions(&mut tx, &principal.org_id, user_id).await?;
        }
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.member_updated",
            "user",
            Some(user_id),
        )
        .await?;
        tx.commit().await?;
        postgres::load_member(self.pool(), user_id).await
    }

    pub async fn delete_admin_member(
        &self,
        principal: &AuthPrincipal,
        user_id: &str,
        expected_revision: i64,
    ) -> Result<DeleteResult, ServerError> {
        if user_id == principal.user_id {
            return Err(ServerError::InvalidRequest(
                "the current user cannot disable their own account".to_owned(),
            ));
        }
        self.update_admin_member(
            principal,
            user_id,
            expected_revision,
            UpdateMemberRequest {
                role: None,
                status: Some(MemberStatus::Disabled),
            },
        )
        .await?;
        Ok(DeleteResult {
            deleted: true,
            id: user_id.to_owned(),
        })
    }

    pub async fn list_admin_projects(
        &self,
        org_id: &str,
        offset: i64,
        limit: i64,
    ) -> Result<AdminProjectListResponse, ServerError> {
        let items = postgres::list_admin_projects(self.pool(), org_id, offset, limit + 1).await?;
        let (items, page_info) = admin_page(items, offset, limit);
        Ok(AdminProjectListResponse { items, page_info })
    }

    pub async fn get_admin_project(
        &self,
        org_id: &str,
        project_id: &str,
    ) -> Result<AdminProject, ServerError> {
        postgres::load_admin_project(self.pool(), org_id, project_id).await
    }

    pub async fn create_admin_project(
        &self,
        principal: &AuthPrincipal,
        request: CreateProjectRequest,
    ) -> Result<AdminProject, ServerError> {
        let name = normalize_project_name(&request.name)?;
        let description = normalize_project_description(request.description.as_deref())?;
        let project_id = prefixed_id("prj");
        let mut tx = self.pool().begin().await?;
        postgres::ensure_project_name_available(&mut tx, &principal.org_id, &name, None).await?;
        postgres::insert_project(&mut tx, &project_id, &principal.org_id, &name, &description)
            .await?;
        postgres::insert_main_ref(&mut tx, &principal.org_id, &project_id).await?;
        postgres::insert_selection_state(&mut tx, &project_id).await?;
        postgres::insert_project_member(&mut tx, &project_id, &principal.user_id, "admin").await?;
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_created",
            "project",
            Some(&project_id),
        )
        .await?;
        tx.commit().await?;
        self.get_admin_project(&principal.org_id, &project_id).await
    }

    pub async fn update_admin_project(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        expected_revision: i64,
        request: UpdateProjectRequest,
    ) -> Result<AdminProject, ServerError> {
        let mut tx = self.pool().begin().await?;
        let current = postgres::lock_admin_project(&mut tx, &principal.org_id, project_id).await?;
        if current.revision != expected_revision {
            return Err(ServerError::version_conflict(
                "project",
                expected_revision,
                current.revision,
            ));
        }
        let name = match request.name {
            Some(name) => normalize_project_name(&name)?,
            None => current.name,
        };
        postgres::ensure_project_name_available(
            &mut tx,
            &principal.org_id,
            &name,
            Some(project_id),
        )
        .await?;
        let description = match request.description {
            Some(description) => normalize_project_description(Some(&description))?,
            None => current.description,
        };
        postgres::update_project(&mut tx, project_id, &name, &description).await?;
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_updated",
            "project",
            Some(project_id),
        )
        .await?;
        tx.commit().await?;
        self.get_admin_project(&principal.org_id, project_id).await
    }

    pub async fn delete_admin_project(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        expected_revision: i64,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        let revision =
            postgres::lock_admin_project_revision(&mut tx, &principal.org_id, project_id).await?;
        if revision != expected_revision {
            return Err(ServerError::version_conflict(
                "project",
                expected_revision,
                revision,
            ));
        }
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_deleted",
            "project",
            Some(project_id),
        )
        .await?;
        postgres::delete_admin_project(&mut tx, &principal.org_id, project_id).await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: project_id.to_owned(),
        })
    }

    pub async fn list_admin_project_members(
        &self,
        org_id: &str,
        project_id: &str,
        role: Option<ProjectRole>,
        offset: i64,
        limit: i64,
    ) -> Result<ProjectMemberListResponse, ServerError> {
        ensure_project_in_org(self.pool(), org_id, project_id).await?;
        let items = postgres::list_project_members(
            self.pool(),
            org_id,
            project_id,
            role.map(ProjectRole::as_str),
            offset,
            limit + 1,
        )
        .await?;
        let (items, page_info) = admin_page(items, offset, limit);
        Ok(ProjectMemberListResponse { items, page_info })
    }

    pub async fn create_admin_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        request: CreateProjectMemberRequest,
    ) -> Result<ProjectMember, ServerError> {
        let mut tx = self.pool().begin().await?;
        ensure_project_in_org_tx(&mut tx, &principal.org_id, project_id).await?;
        let status = postgres::load_user_status(&mut tx, &request.user_id).await?;
        if status == "disabled" {
            return Err(ServerError::InvalidRequest(
                "a disabled organization member cannot be added to a project".to_owned(),
            ));
        }
        if !postgres::insert_project_member(
            &mut tx,
            project_id,
            &request.user_id,
            request.role.as_str(),
        )
        .await?
        {
            return Err(ServerError::already_exists(
                "project_member",
                format!("{project_id}:{}", request.user_id),
            ));
        }
        let target_id = format!("{project_id}:{}", request.user_id);
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_member_created",
            "project_member",
            Some(&target_id),
        )
        .await?;
        tx.commit().await?;
        postgres::load_project_member(self.pool(), &principal.org_id, project_id, &request.user_id)
            .await
    }

    pub async fn update_admin_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        user_id: &str,
        request: UpdateProjectMemberRequest,
    ) -> Result<ProjectMember, ServerError> {
        let mut tx = self.pool().begin().await?;
        ensure_project_in_org_tx(&mut tx, &principal.org_id, project_id).await?;
        if !postgres::update_project_member(&mut tx, project_id, user_id, request.role.as_str())
            .await?
        {
            return Err(ServerError::not_found(
                "project_member",
                format!("{project_id}:{user_id}"),
            ));
        }
        let target_id = format!("{project_id}:{user_id}");
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_member_updated",
            "project_member",
            Some(&target_id),
        )
        .await?;
        tx.commit().await?;
        postgres::load_project_member(self.pool(), &principal.org_id, project_id, user_id).await
    }

    pub async fn delete_admin_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        user_id: &str,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        ensure_project_in_org_tx(&mut tx, &principal.org_id, project_id).await?;
        if postgres::assigned_issue_count(&mut tx, project_id, user_id).await? > 0 {
            return Err(ServerError::InvalidRequest(
                "reassign this member's Issues before removing them from the Project".to_owned(),
            ));
        }
        if !postgres::delete_project_member(&mut tx, project_id, user_id).await? {
            return Err(ServerError::not_found(
                "project_member",
                format!("{project_id}:{user_id}"),
            ));
        }
        let target_id = format!("{project_id}:{user_id}");
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_member_deleted",
            "project_member",
            Some(&target_id),
        )
        .await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: user_id.to_owned(),
        })
    }

    pub async fn list_admin_tokens(
        &self,
        org_id: &str,
        offset: i64,
        limit: i64,
    ) -> Result<AccessTokenListResponse, ServerError> {
        let items = postgres::list_access_tokens(self.pool(), org_id, offset, limit + 1).await?;
        let (items, page_info) = admin_page(items, offset, limit);
        Ok(AccessTokenListResponse { items, page_info })
    }

    pub async fn delete_admin_token(
        &self,
        principal: &AuthPrincipal,
        token_id: &str,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        if !postgres::access_token_exists(&mut tx, &principal.org_id, token_id).await? {
            return Err(ServerError::not_found("access_token", token_id));
        }
        postgres::revoke_access_token(&mut tx, &principal.org_id, token_id).await?;
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.token_revoked",
            "access_token",
            Some(token_id),
        )
        .await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: token_id.to_owned(),
        })
    }

    pub async fn list_admin_audit_events(
        &self,
        org_id: &str,
        offset: i64,
        limit: i64,
    ) -> Result<AuditEventListResponse, ServerError> {
        let items = postgres::list_audit_events(self.pool(), org_id, offset, limit + 1).await?;
        let (items, page_info) = admin_page(items, offset, limit);
        Ok(AuditEventListResponse { items, page_info })
    }

    pub async fn create_project(
        &self,
        org_id: &str,
        name: &str,
        description: &str,
    ) -> Result<String, ServerError> {
        let name = normalize_project_name(name)?;
        let description = normalize_project_description(Some(description))?;
        let project_id = prefixed_id("prj");
        let mut tx = self.pool().begin().await?;
        postgres::ensure_project_name_available(&mut tx, org_id, &name, None).await?;
        postgres::insert_project(&mut tx, &project_id, org_id, &name, &description).await?;
        postgres::insert_main_ref(&mut tx, org_id, &project_id).await?;
        postgres::insert_selection_state(&mut tx, &project_id).await?;
        tx.commit().await?;
        Ok(project_id)
    }

    pub async fn create_project_from_request(
        &self,
        principal: &AuthPrincipal,
        request: CreateProjectRequest,
        idempotency_key: &str,
    ) -> Result<Project, ServerError> {
        let idempotency_key = normalize_idempotency_key(idempotency_key)?;
        let name = normalize_project_name(&request.name)?;
        let description = normalize_project_description(request.description.as_deref())?;
        let project_id = prefixed_id("prj");
        let mut tx = self.pool().begin().await?;
        let claimed = postgres::claim_project_creation(
            &mut tx,
            &principal.org_id,
            &principal.user_id,
            &idempotency_key,
            &project_id,
            &name,
            &description,
        )
        .await?;
        if !claimed {
            let existing = postgres::load_project_creation(
                &mut tx,
                &principal.org_id,
                &principal.user_id,
                &idempotency_key,
            )
            .await?;
            if existing.name != name || existing.description != description {
                return Err(ServerError::already_exists(
                    "idempotency_key",
                    idempotency_key,
                ));
            }
            tx.commit().await?;
            return self.get_project(&existing.project_id).await;
        }
        postgres::ensure_project_name_available(&mut tx, &principal.org_id, &name, None).await?;
        postgres::insert_project(&mut tx, &project_id, &principal.org_id, &name, &description)
            .await?;
        postgres::insert_main_ref(&mut tx, &principal.org_id, &project_id).await?;
        postgres::insert_selection_state(&mut tx, &project_id).await?;
        postgres::insert_project_member(&mut tx, &project_id, &principal.user_id, "admin").await?;
        postgres::insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "project.created",
            "project",
            Some(&project_id),
        )
        .await?;
        tx.commit().await?;
        self.get_project(&project_id).await
    }

    pub async fn list_projects(
        &self,
        principal: &AuthPrincipal,
    ) -> Result<ProjectListResponse, ServerError> {
        Ok(ProjectListResponse {
            items: postgres::list_projects(self.pool(), &principal.user_id, &principal.org_id)
                .await?,
            page_info: page_info(),
        })
    }

    pub async fn get_project(&self, project_id: &str) -> Result<Project, ServerError> {
        postgres::load_project(self.pool(), project_id).await
    }

    pub async fn update_project(
        &self,
        project_id: &str,
        expected_version: i64,
        request: UpdateProjectRequest,
    ) -> Result<Project, ServerError> {
        let mut tx = self.pool().begin().await?;
        let current = postgres::lock_project_revision(&mut tx, project_id).await?;
        if current != expected_version {
            return Err(ServerError::version_conflict(
                "project",
                expected_version,
                current,
            ));
        }
        let existing = postgres::load_project_update_state(&mut tx, project_id).await?;
        let name = match request.name {
            Some(name) => normalize_project_name(&name)?,
            None => existing.name,
        };
        postgres::ensure_project_name_available(&mut tx, &existing.org_id, &name, Some(project_id))
            .await?;
        let description = match request.description {
            Some(description) => normalize_project_description(Some(&description))?,
            None => existing.description,
        };
        postgres::update_project(&mut tx, project_id, &name, &description).await?;
        tx.commit().await?;
        self.get_project(project_id).await
    }

    pub async fn delete_project(
        &self,
        project_id: &str,
        expected_version: i64,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        let current = postgres::lock_project_revision(&mut tx, project_id).await?;
        if current != expected_version {
            return Err(ServerError::version_conflict(
                "project",
                expected_version,
                current,
            ));
        }
        postgres::delete_project(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: project_id.to_owned(),
        })
    }
}

async fn ensure_project_in_org(
    pool: &sqlx::PgPool,
    org_id: &str,
    project_id: &str,
) -> Result<(), ServerError> {
    if postgres::project_in_org(pool, org_id, project_id).await? {
        Ok(())
    } else {
        Err(ServerError::not_found("project", project_id))
    }
}

async fn ensure_project_in_org_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    org_id: &str,
    project_id: &str,
) -> Result<(), ServerError> {
    if postgres::project_in_org_tx(tx, org_id, project_id).await? {
        Ok(())
    } else {
        Err(ServerError::not_found("project", project_id))
    }
}

fn validate_kanban_issue_payload(
    project_id: &str,
    issue_id: &str,
    issue_number: i64,
    content_revision: i64,
    payload: &serde_json::Value,
) -> Result<(), ServerError> {
    let identity = payload.get("issue").unwrap_or(payload);
    let valid_issue_id = issue_id.len() == 38
        && issue_id.starts_with("issue_")
        && issue_id[6..].bytes().all(|byte| byte.is_ascii_hexdigit());
    let payload_matches = identity
        .get("project_id")
        .and_then(serde_json::Value::as_str)
        == Some(project_id)
        && identity.get("issue_id").and_then(serde_json::Value::as_str) == Some(issue_id)
        && identity
            .get("issue_number")
            .and_then(serde_json::Value::as_i64)
            == Some(issue_number)
        && identity
            .get("state_revision")
            .and_then(serde_json::Value::as_i64)
            == Some(content_revision);
    if !valid_issue_id
        || !(1..=999).contains(&issue_number)
        || content_revision <= 0
        || !payload_matches
        || serde_json::to_string(payload).map_or(true, |value| value.len() > 512 * 1024)
    {
        return Err(ServerError::InvalidRequest(
            "invalid Kanban Issue snapshot".to_owned(),
        ));
    }
    Ok(())
}

fn validate_issue_claim_input(
    issue_id: &str,
    request: &AcquireIssueClaimRequest,
) -> Result<(), ServerError> {
    let valid_issue_key = request.issue_key.len() == 9
        && request.issue_key.starts_with("ISSUE-")
        && request.issue_key[6..]
            .bytes()
            .all(|byte| byte.is_ascii_digit())
        && request.issue_key != "ISSUE-000";
    let valid_issue_id = issue_id.len() == 38
        && issue_id.starts_with("issue_")
        && issue_id[6..].bytes().all(|byte| byte.is_ascii_hexdigit());
    if !valid_issue_id
        || request.run_id.trim().is_empty()
        || request.run_id.len() > 256
        || !valid_issue_key
    {
        return Err(ServerError::InvalidRequest(
            "invalid native Issue claim identity".to_owned(),
        ));
    }
    let now = OffsetDateTime::now_utc();
    if request.lease_expires_at <= now || request.lease_expires_at > now + time::Duration::hours(24)
    {
        return Err(ServerError::InvalidRequest(
            "issue claim lease must expire within the next 24 hours".to_owned(),
        ));
    }
    Ok(())
}

fn admin_page<T>(mut items: Vec<T>, offset: i64, limit: i64) -> (Vec<T>, PageInfo) {
    let has_more = items.len() > limit as usize;
    if has_more {
        items.truncate(limit as usize);
    }
    let next_cursor = has_more.then(|| (offset + limit).to_string());
    (
        items,
        PageInfo {
            next_cursor,
            has_more,
        },
    )
}

fn page_info() -> PageInfo {
    PageInfo {
        next_cursor: None,
        has_more: false,
    }
}

fn normalize_project_name(name: &str) -> Result<String, ServerError> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 120 {
        return Err(ServerError::InvalidRequest(
            "project name must contain between 1 and 120 characters".to_owned(),
        ));
    }
    Ok(name.to_owned())
}

fn normalize_idempotency_key(value: &str) -> Result<String, ServerError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 200 {
        return Err(ServerError::InvalidRequest(
            "Idempotency-Key must contain between 1 and 200 bytes".to_owned(),
        ));
    }
    Ok(value.to_owned())
}

fn normalize_project_description(description: Option<&str>) -> Result<String, ServerError> {
    let description = description.unwrap_or_default().trim();
    if description.chars().count() > 4_000 {
        return Err(ServerError::InvalidRequest(
            "project description must not exceed 4000 characters".to_owned(),
        ));
    }
    Ok(description.to_owned())
}

fn normalize_email(email: &str) -> Result<String, ServerError> {
    let email = email.trim().to_ascii_lowercase();
    let Some((local, domain)) = email.split_once('@') else {
        return Err(ServerError::InvalidRequest(
            "invalid member email".to_owned(),
        ));
    };
    if local.is_empty() || domain.is_empty() || domain.contains('@') || !valid_domain(domain) {
        return Err(ServerError::InvalidRequest(
            "invalid member email".to_owned(),
        ));
    }
    Ok(email)
}

fn normalize_email_domains(domains: Vec<String>) -> Result<Vec<String>, ServerError> {
    let mut normalized = BTreeSet::new();
    for domain in domains {
        let domain = domain.trim().trim_start_matches('@').to_ascii_lowercase();
        if !valid_domain(&domain) {
            return Err(ServerError::InvalidRequest(format!(
                "invalid allowed email domain: {domain}"
            )));
        }
        normalized.insert(domain);
    }
    Ok(normalized.into_iter().collect())
}

fn valid_domain(domain: &str) -> bool {
    !domain.is_empty()
        && domain.len() <= 253
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn enforce_invited_email_domain(
    email: &str,
    allowed_domains: &[String],
) -> Result<(), ServerError> {
    if allowed_domains.is_empty() {
        return Ok(());
    }
    let domain = email
        .rsplit_once('@')
        .map(|(_, domain)| domain)
        .unwrap_or("");
    if allowed_domains.iter().any(|allowed| allowed == domain) {
        Ok(())
    } else {
        Err(ServerError::InvalidRequest(
            "member email is outside the organization allowlist".to_owned(),
        ))
    }
}

fn prefixed_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}
