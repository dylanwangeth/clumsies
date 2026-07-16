use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction, types::Json};
use std::collections::{BTreeMap, BTreeSet};
use thiserror::Error;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::api::{
    AccessTokenKind, AccessTokenListResponse, AccessTokenMeta, AdminOrg, AdminProject,
    AdminProjectListResponse, AuditEvent, AuditEventListResponse, Blob, Commit, CommitListResponse,
    CommitPayload, CommitScope, CommitStateResponse, ContextDetail, ContextListResponse,
    ContextMeta, CreateDraftRequest, CreateMemberRequest, CreateProjectMemberRequest,
    CreateProjectRequest, CreateReviewCommentRequest, CreateReviewConflictResolutionRequest,
    CreateReviewDecisionRequest, CreateReviewMergeRequest, CreateReviewRequest,
    CreateReviewSubmissionRequest, DeleteResult, Draft, DraftConflict, DraftDetail, DraftEvent,
    DraftEventListResponse, DraftEventType, DraftListResponse, DraftOperation,
    DraftOperationAction, DraftOperationBatchRequest, DraftOperationBatchResponse,
    DraftOperationInput, DraftResourceContent, DraftResourceKind, DraftResourceRef, DraftStatus,
    DraftSyncState, DraftSyncStatus, MeResponse, Member, MemberListResponse, MemberStatus,
    MetapromptDetail, MetapromptMeta, OrgRef, OrgRole, PageInfo, PersonalBundleDetail,
    PersonalBundleListResponse, PersonalBundleMeta, PersonalBundleRequest,
    PersonalBundleUpdateRequest, Project, ProjectListResponse, ProjectMember,
    ProjectMemberListResponse, ProjectOrgSelection, ProjectRef, ProjectRole, Ref,
    ReplaceProjectOrgSelectionRequest, ResourceScope, Review, ReviewComment,
    ReviewCommentListResponse, ReviewDecision, ReviewDetail, ReviewListResponse, ReviewMergeResult,
    ReviewStatus, RuleContent, RuleDetail, RuleListResponse, RuleMeta, Tree, TreeEntry,
    TreeEntryKind, TreeEntryScope, TreeEntrySource, UpdateAdminOrgRequest, UpdateDraftRequest,
    UpdateMemberRequest, UpdateProjectMemberRequest, UpdateProjectRequest, UserRef,
    WorkflowContent, WorkflowDetail, WorkflowListResponse, WorkflowMeta, WorkflowStep,
    WorkflowStepInput,
};
use crate::auth::AuthPrincipal;

#[derive(Clone)]
pub struct ServerRepository {
    pool: PgPool,
}

impl ServerRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn get_me(&self, principal: &AuthPrincipal) -> Result<MeResponse, ServerError> {
        let mut tx = self.pool.begin().await?;
        let user_row = sqlx::query(
            "SELECT user_id, email, display_name, avatar_url, role
             FROM users
             WHERE user_id = $1",
        )
        .bind(&principal.user_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("user", &principal.user_id))?;
        let org_row = sqlx::query("SELECT org_id, name FROM orgs WHERE org_id = $1")
            .bind(&principal.org_id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(|| ServerError::not_found("org", &principal.org_id))?;
        let project_rows = sqlx::query(
            "SELECT p.project_id, p.name
             FROM projects p
             JOIN project_members m ON m.project_id = p.project_id
             WHERE p.org_id = $1 AND m.user_id = $2
             ORDER BY p.created_at",
        )
        .bind(&principal.org_id)
        .bind(&principal.user_id)
        .fetch_all(&mut *tx)
        .await?;
        let projects = project_rows
            .iter()
            .map(|row| {
                Ok(ProjectRef {
                    project_id: row.try_get("project_id")?,
                    name: row.try_get("name")?,
                })
            })
            .collect::<Result<Vec<_>, ServerError>>()?;
        let response = MeResponse {
            user: user_ref_from_row(&user_row)?,
            org: OrgRef {
                org_id: org_row.try_get("org_id")?,
                name: org_row.try_get("name")?,
            },
            default_project_id: projects.first().map(|project| project.project_id.clone()),
            projects,
            capabilities: principal_capabilities(&principal.role),
        };
        tx.commit().await?;
        Ok(response)
    }

    pub async fn ensure_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
    ) -> Result<(), ServerError> {
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM projects p
                JOIN project_members m ON m.project_id = p.project_id
                WHERE p.project_id = $1 AND p.org_id = $2 AND m.user_id = $3
             )",
        )
        .bind(project_id)
        .bind(&principal.org_id)
        .bind(&principal.user_id)
        .fetch_one(&self.pool)
        .await?;
        if exists {
            Ok(())
        } else {
            Err(ServerError::not_found("project", project_id))
        }
    }

    pub async fn ensure_draft_owner(
        &self,
        principal: &AuthPrincipal,
        draft_id: &str,
    ) -> Result<(), ServerError> {
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM drafts d
                JOIN projects p ON p.project_id = d.project_id
                JOIN project_members m ON m.project_id = p.project_id
                WHERE d.draft_id = $1
                  AND d.author_user_id = $2
                  AND p.org_id = $3
                  AND m.user_id = $2
             )",
        )
        .bind(draft_id)
        .bind(&principal.user_id)
        .bind(&principal.org_id)
        .fetch_one(&self.pool)
        .await?;
        if exists {
            Ok(())
        } else {
            Err(ServerError::not_found("draft", draft_id))
        }
    }

    pub async fn ensure_review_member(
        &self,
        principal: &AuthPrincipal,
        review_id: &str,
    ) -> Result<(), ServerError> {
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM reviews r
                JOIN projects p ON p.project_id = r.project_id
                JOIN project_members m ON m.project_id = p.project_id
                WHERE r.review_id = $1 AND p.org_id = $2 AND m.user_id = $3
             )",
        )
        .bind(review_id)
        .bind(&principal.org_id)
        .bind(&principal.user_id)
        .fetch_one(&self.pool)
        .await?;
        if exists {
            Ok(())
        } else {
            Err(ServerError::not_found("review", review_id))
        }
    }

    pub async fn ensure_commit_access(
        &self,
        principal: &AuthPrincipal,
        commit_id: &str,
    ) -> Result<(), ServerError> {
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM commits c
                LEFT JOIN project_members m
                  ON m.project_id = c.project_id AND m.user_id = $3
                WHERE c.commit_id = $1
                  AND c.org_id = $2
                  AND (c.scope = 'org' OR m.user_id IS NOT NULL)
             )",
        )
        .bind(commit_id)
        .bind(&principal.org_id)
        .bind(&principal.user_id)
        .fetch_one(&self.pool)
        .await?;
        if exists {
            Ok(())
        } else {
            Err(ServerError::not_found("commit", commit_id))
        }
    }

    pub async fn get_admin_org(&self, org_id: &str) -> Result<AdminOrg, ServerError> {
        let row = sqlx::query(
            "SELECT org_id, name, allowed_email_domains, revision, updated_at
             FROM orgs WHERE org_id = $1",
        )
        .bind(org_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| ServerError::not_found("org", org_id))?;
        admin_org_from_row(&row)
    }

    pub async fn update_admin_org(
        &self,
        principal: &AuthPrincipal,
        expected_revision: i64,
        request: UpdateAdminOrgRequest,
    ) -> Result<AdminOrg, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT name, allowed_email_domains, revision
             FROM orgs WHERE org_id = $1 FOR UPDATE",
        )
        .bind(&principal.org_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("org", &principal.org_id))?;
        let revision: i64 = row.try_get("revision")?;
        if revision != expected_revision {
            return Err(ServerError::version_conflict(
                "org",
                expected_revision,
                revision,
            ));
        }
        let name = match request.name {
            Some(name) if !name.trim().is_empty() => name.trim().to_owned(),
            Some(_) => {
                return Err(ServerError::InvalidRequest(
                    "organization name must not be empty".to_owned(),
                ));
            }
            None => row.try_get("name")?,
        };
        let allowed_email_domains = match request.allowed_email_domains {
            Some(domains) => normalize_email_domains(domains)?,
            None => row.try_get("allowed_email_domains")?,
        };
        sqlx::query(
            "UPDATE orgs
             SET name = $2, allowed_email_domains = $3, revision = revision + 1, updated_at = now()
             WHERE org_id = $1",
        )
        .bind(&principal.org_id)
        .bind(name)
        .bind(allowed_email_domains)
        .execute(&mut *tx)
        .await?;
        insert_repository_audit_event(
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

    pub async fn list_admin_members(&self) -> Result<MemberListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT u.user_id, u.email, u.display_name, u.role, u.status, u.revision,
                    EXISTS (
                        SELECT 1 FROM external_identities i WHERE i.user_id = u.user_id
                    ) AS external_identity_bound
             FROM users u ORDER BY u.created_at LIMIT 200",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(MemberListResponse {
            items: rows
                .iter()
                .map(member_from_row)
                .collect::<Result<Vec<_>, _>>()?,
            page_info: page_info(),
        })
    }

    pub async fn create_admin_member(
        &self,
        principal: &AuthPrincipal,
        request: CreateMemberRequest,
    ) -> Result<Member, ServerError> {
        let email = normalize_email(&request.email)?;
        let allowed_domains = sqlx::query_scalar::<_, Vec<String>>(
            "SELECT allowed_email_domains FROM orgs WHERE org_id = $1",
        )
        .bind(&principal.org_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| ServerError::not_found("org", &principal.org_id))?;
        enforce_invited_email_domain(&email, &allowed_domains)?;
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (SELECT 1 FROM users WHERE lower(email) = lower($1))",
        )
        .bind(&email)
        .fetch_one(&self.pool)
        .await?;
        if exists {
            return Err(ServerError::InvalidRequest(
                "a member with this email already exists".to_owned(),
            ));
        }
        let user_id = prefixed_id("usr");
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "INSERT INTO users (user_id, email, role, status)
             VALUES ($1, $2, $3, 'invited')",
        )
        .bind(&user_id)
        .bind(&email)
        .bind(request.role.as_str())
        .execute(&mut *tx)
        .await?;
        insert_repository_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.member_created",
            "user",
            Some(&user_id),
        )
        .await?;
        tx.commit().await?;
        load_member(&self.pool, &user_id).await
    }

    pub async fn update_admin_member(
        &self,
        principal: &AuthPrincipal,
        user_id: &str,
        expected_revision: i64,
        request: UpdateMemberRequest,
    ) -> Result<Member, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row =
            sqlx::query("SELECT role, status, revision FROM users WHERE user_id = $1 FOR UPDATE")
                .bind(user_id)
                .fetch_optional(&mut *tx)
                .await?
                .ok_or_else(|| ServerError::not_found("user", user_id))?;
        let revision: i64 = row.try_get("revision")?;
        if revision != expected_revision {
            return Err(ServerError::version_conflict(
                "member",
                expected_revision,
                revision,
            ));
        }
        let current_role: String = row.try_get("role")?;
        let current_status: String = row.try_get("status")?;
        let next_role = request
            .role
            .map(|role| role.as_str().to_owned())
            .unwrap_or_else(|| current_role.clone());
        let next_status = request
            .status
            .map(|status| status.as_str().to_owned())
            .unwrap_or_else(|| current_status.clone());
        if principal.role != "owner" && (current_role == "owner" || next_role == "owner") {
            return Err(ServerError::Forbidden(
                "only an organization owner can modify an owner account".to_owned(),
            ));
        }
        ensure_active_owner_remains(
            &mut tx,
            &current_role,
            &current_status,
            &next_role,
            &next_status,
        )
        .await?;
        sqlx::query(
            "UPDATE users
             SET role = $2, status = $3, revision = revision + 1, updated_at = now()
             WHERE user_id = $1",
        )
        .bind(user_id)
        .bind(&next_role)
        .bind(&next_status)
        .execute(&mut *tx)
        .await?;
        if next_status == "disabled" {
            revoke_user_sessions(&mut tx, &principal.org_id, user_id).await?;
        }
        insert_repository_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.member_updated",
            "user",
            Some(user_id),
        )
        .await?;
        tx.commit().await?;
        load_member(&self.pool, user_id).await
    }

    pub async fn delete_admin_member(
        &self,
        principal: &AuthPrincipal,
        user_id: &str,
        expected_revision: i64,
    ) -> Result<DeleteResult, ServerError> {
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
    ) -> Result<AdminProjectListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT p.project_id, p.name, COUNT(m.user_id)::BIGINT AS member_count, p.updated_at
             FROM projects p
             LEFT JOIN project_members m ON m.project_id = p.project_id
             WHERE p.org_id = $1
             GROUP BY p.project_id
             ORDER BY p.updated_at DESC
             LIMIT 200",
        )
        .bind(org_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(AdminProjectListResponse {
            items: rows
                .iter()
                .map(|row| {
                    Ok(AdminProject {
                        project_id: row.try_get("project_id")?,
                        name: row.try_get("name")?,
                        member_count: row.try_get("member_count")?,
                        updated_at: row.try_get("updated_at")?,
                    })
                })
                .collect::<Result<Vec<_>, ServerError>>()?,
            page_info: page_info(),
        })
    }

    pub async fn list_admin_project_members(
        &self,
        org_id: &str,
        project_id: &str,
        role: Option<ProjectRole>,
    ) -> Result<ProjectMemberListResponse, ServerError> {
        ensure_project_in_org(&self.pool, org_id, project_id).await?;
        let rows = sqlx::query(
            "SELECT p.project_id, u.user_id, u.email, u.display_name, u.avatar_url,
                    u.role AS org_role, m.role AS project_role, m.joined_at
             FROM project_members m
             JOIN projects p ON p.project_id = m.project_id
             JOIN users u ON u.user_id = m.user_id
             WHERE p.project_id = $1
               AND p.org_id = $2
               AND ($3::TEXT IS NULL OR m.role = $3)
             ORDER BY m.joined_at, u.user_id
             LIMIT 200",
        )
        .bind(project_id)
        .bind(org_id)
        .bind(role.map(ProjectRole::as_str))
        .fetch_all(&self.pool)
        .await?;
        Ok(ProjectMemberListResponse {
            items: rows
                .iter()
                .map(project_member_from_row)
                .collect::<Result<Vec<_>, _>>()?,
            page_info: page_info(),
        })
    }

    pub async fn create_admin_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        request: CreateProjectMemberRequest,
    ) -> Result<ProjectMember, ServerError> {
        let mut tx = self.pool.begin().await?;
        ensure_project_in_org_tx(&mut tx, &principal.org_id, project_id).await?;
        let status = sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE user_id = $1")
            .bind(&request.user_id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(|| ServerError::not_found("user", &request.user_id))?;
        if status == "disabled" {
            return Err(ServerError::InvalidRequest(
                "a disabled organization member cannot be added to a project".to_owned(),
            ));
        }
        let inserted = sqlx::query(
            "INSERT INTO project_members (project_id, user_id, role)
             VALUES ($1, $2, $3)
             ON CONFLICT (project_id, user_id) DO NOTHING",
        )
        .bind(project_id)
        .bind(&request.user_id)
        .bind(request.role.as_str())
        .execute(&mut *tx)
        .await?;
        if inserted.rows_affected() == 0 {
            return Err(ServerError::already_exists(
                "project_member",
                format!("{project_id}:{}", request.user_id),
            ));
        }
        insert_repository_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_member_created",
            "project_member",
            Some(&format!("{project_id}:{}", request.user_id)),
        )
        .await?;
        tx.commit().await?;
        load_project_member(&self.pool, &principal.org_id, project_id, &request.user_id).await
    }

    pub async fn update_admin_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        user_id: &str,
        request: UpdateProjectMemberRequest,
    ) -> Result<ProjectMember, ServerError> {
        let mut tx = self.pool.begin().await?;
        ensure_project_in_org_tx(&mut tx, &principal.org_id, project_id).await?;
        let updated = sqlx::query(
            "UPDATE project_members SET role = $3 WHERE project_id = $1 AND user_id = $2",
        )
        .bind(project_id)
        .bind(user_id)
        .bind(request.role.as_str())
        .execute(&mut *tx)
        .await?;
        if updated.rows_affected() == 0 {
            return Err(ServerError::not_found(
                "project_member",
                format!("{project_id}:{user_id}"),
            ));
        }
        insert_repository_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_member_updated",
            "project_member",
            Some(&format!("{project_id}:{user_id}")),
        )
        .await?;
        tx.commit().await?;
        load_project_member(&self.pool, &principal.org_id, project_id, user_id).await
    }

    pub async fn delete_admin_project_member(
        &self,
        principal: &AuthPrincipal,
        project_id: &str,
        user_id: &str,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool.begin().await?;
        ensure_project_in_org_tx(&mut tx, &principal.org_id, project_id).await?;
        let deleted =
            sqlx::query("DELETE FROM project_members WHERE project_id = $1 AND user_id = $2")
                .bind(project_id)
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
        if deleted.rows_affected() == 0 {
            return Err(ServerError::not_found(
                "project_member",
                format!("{project_id}:{user_id}"),
            ));
        }
        insert_repository_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "admin.project_member_deleted",
            "project_member",
            Some(&format!("{project_id}:{user_id}")),
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
    ) -> Result<AccessTokenListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT t.token_id, t.user_id, t.kind, t.revoked_at, t.expires_at, t.created_at
             FROM access_tokens t
             JOIN auth_sessions s ON s.session_id = t.session_id
             WHERE s.org_id = $1
             ORDER BY t.created_at DESC
             LIMIT 200",
        )
        .bind(org_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(AccessTokenListResponse {
            items: rows
                .iter()
                .map(access_token_meta_from_row)
                .collect::<Result<Vec<_>, _>>()?,
            page_info: page_info(),
        })
    }

    pub async fn delete_admin_token(
        &self,
        principal: &AuthPrincipal,
        token_id: &str,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool.begin().await?;
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1 FROM access_tokens t
                JOIN auth_sessions s ON s.session_id = t.session_id
                WHERE t.token_id = $1 AND s.org_id = $2
             )",
        )
        .bind(token_id)
        .bind(&principal.org_id)
        .fetch_one(&mut *tx)
        .await?;
        if !exists {
            return Err(ServerError::not_found("access_token", token_id));
        }
        sqlx::query(
            "UPDATE access_tokens t SET revoked_at = now()
             FROM auth_sessions s
             WHERE t.session_id = s.session_id AND t.token_id = $1 AND s.org_id = $2",
        )
        .bind(token_id)
        .bind(&principal.org_id)
        .execute(&mut *tx)
        .await?;
        insert_repository_audit_event(
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
    ) -> Result<AuditEventListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT event_id, actor_user_id, action, target_type, target_id, created_at
             FROM audit_events
             WHERE org_id = $1
             ORDER BY created_at DESC
             LIMIT 200",
        )
        .bind(org_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(AuditEventListResponse {
            items: rows
                .iter()
                .map(|row| {
                    Ok(AuditEvent {
                        event_id: row.try_get("event_id")?,
                        actor_user_id: row.try_get("actor_user_id")?,
                        action: row.try_get("action")?,
                        target_type: row.try_get("target_type")?,
                        target_id: row.try_get("target_id")?,
                        created_at: row.try_get("created_at")?,
                    })
                })
                .collect::<Result<Vec<_>, ServerError>>()?,
            page_info: page_info(),
        })
    }

    pub async fn create_project(
        &self,
        org_id: &str,
        name: &str,
        description: &str,
    ) -> Result<String, ServerError> {
        let project_id = prefixed_id("prj");
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "INSERT INTO projects (project_id, org_id, name, description)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(&project_id)
        .bind(org_id)
        .bind(name)
        .bind(description)
        .execute(&mut *tx)
        .await?;
        insert_ref(&mut tx, "project", org_id, Some(&project_id)).await?;
        sqlx::query("INSERT INTO project_org_selection_states (project_id) VALUES ($1)")
            .bind(&project_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(project_id)
    }

    pub async fn create_project_from_request(
        &self,
        principal: &AuthPrincipal,
        request: CreateProjectRequest,
    ) -> Result<Project, ServerError> {
        let project_id = self
            .create_project(
                &principal.org_id,
                &request.name,
                request.description.as_deref().unwrap_or_default(),
            )
            .await?;
        sqlx::query(
            "INSERT INTO project_members (project_id, user_id, role)
             VALUES ($1, $2, 'admin')",
        )
        .bind(&project_id)
        .bind(&principal.user_id)
        .execute(&self.pool)
        .await?;
        self.get_project(&project_id).await
    }

    pub async fn list_projects(
        &self,
        principal: &AuthPrincipal,
    ) -> Result<ProjectListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT p.project_id, p.name, p.description, p.revision, p.created_at, p.updated_at
             FROM projects p
             JOIN project_members m ON m.project_id = p.project_id
             WHERE m.user_id = $1 AND p.org_id = $2
             ORDER BY p.updated_at DESC
             LIMIT 200",
        )
        .bind(&principal.user_id)
        .bind(&principal.org_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(ProjectListResponse {
            items: rows
                .iter()
                .map(project_from_row)
                .collect::<Result<Vec<_>, _>>()?,
            page_info: page_info(),
        })
    }

    pub async fn get_project(&self, project_id: &str) -> Result<Project, ServerError> {
        let row = sqlx::query(
            "SELECT project_id, name, description, revision, created_at, updated_at
             FROM projects
             WHERE project_id = $1",
        )
        .bind(project_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| ServerError::not_found("project", project_id))?;
        project_from_row(&row)
    }

    pub async fn update_project(
        &self,
        project_id: &str,
        expected_version: i64,
        request: UpdateProjectRequest,
    ) -> Result<Project, ServerError> {
        let mut tx = self.pool.begin().await?;
        let current = current_project_revision(&mut tx, project_id).await?;
        if current != expected_version {
            return Err(ServerError::version_conflict(
                "project",
                expected_version,
                current,
            ));
        }
        let existing = sqlx::query(
            "SELECT name, description
             FROM projects
             WHERE project_id = $1",
        )
        .bind(project_id)
        .fetch_one(&mut *tx)
        .await?;
        let existing_name: String = existing.try_get("name")?;
        let existing_description: String = existing.try_get("description")?;
        let name = request.name.unwrap_or(existing_name);
        let description = request.description.unwrap_or(existing_description);
        sqlx::query(
            "UPDATE projects
             SET name = $2, description = $3, revision = revision + 1, updated_at = now()
             WHERE project_id = $1",
        )
        .bind(project_id)
        .bind(name)
        .bind(description)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.get_project(project_id).await
    }

    pub async fn delete_project(
        &self,
        project_id: &str,
        expected_version: i64,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool.begin().await?;
        let current = current_project_revision(&mut tx, project_id).await?;
        if current != expected_version {
            return Err(ServerError::version_conflict(
                "project",
                expected_version,
                current,
            ));
        }
        sqlx::query("DELETE FROM projects WHERE project_id = $1")
            .bind(project_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: project_id.to_owned(),
        })
    }

    pub async fn create_org_context(
        &self,
        org_id: &str,
        path: &str,
        body: &str,
    ) -> Result<String, ServerError> {
        let resource_id = prefixed_id(DraftResourceKind::Context.resource_id_prefix());
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "INSERT INTO resources (
                resource_id, org_id, project_id, scope, resource_kind, path, name,
                status, revision, content_hash, body, context_kind
             )
             VALUES ($1, $2, NULL, 'org', $3, $4, $5, 'active', 1, $6, $7, $8)",
        )
        .bind(&resource_id)
        .bind(org_id)
        .bind(DraftResourceKind::Context.as_str())
        .bind(path)
        .bind(name_from_path(path))
        .bind(content_hash(body))
        .bind(body)
        .bind(context_kind_for(DraftResourceKind::Context))
        .execute(&mut *tx)
        .await?;
        let parent_commit_id = current_org_ref(&mut tx, org_id).await?;
        let commit_id = create_org_commit(&mut tx, org_id, parent_commit_id.as_deref()).await?;
        advance_org_ref(&mut tx, org_id, &commit_id).await?;
        tx.commit().await?;
        Ok(resource_id)
    }

    pub async fn select_org_resource_for_project(
        &self,
        project_id: &str,
        resource_id: &str,
    ) -> Result<(), ServerError> {
        let mut tx = self.pool.begin().await?;
        let org_id = project_org_id(&mut tx, project_id).await?;
        lock_org_ref_for_project_projection(&mut tx, &org_id).await?;
        let parent_commit_id = current_project_ref(&mut tx, project_id).await?;
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(
                SELECT 1
                FROM resources
                WHERE resource_id = $1 AND org_id = $2
                  AND scope = 'org' AND status = 'active'
             )",
        )
        .bind(resource_id)
        .bind(&org_id)
        .fetch_one(&mut *tx)
        .await?;
        if !exists {
            return Err(ServerError::not_found("org_resource", resource_id));
        }
        let current_revision = current_project_org_selection_revision(&mut tx, project_id).await?;
        let next_revision = current_revision + 1;
        sqlx::query(
            "INSERT INTO project_org_resource_selections (project_id, resource_id, revision)
             VALUES ($1, $2, $3)
             ON CONFLICT (project_id, resource_id)
             DO UPDATE SET revision = EXCLUDED.revision,
                           updated_at = now()",
        )
        .bind(project_id)
        .bind(resource_id)
        .bind(next_revision)
        .execute(&mut *tx)
        .await?;
        validate_project_effective_memory(&mut tx, project_id, &org_id).await?;
        update_project_org_selection_revision(&mut tx, project_id, next_revision).await?;
        let commit_id =
            create_project_commit(&mut tx, project_id, parent_commit_id.as_deref()).await?;
        advance_project_ref(&mut tx, project_id, &commit_id).await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn replace_project_org_selection(
        &self,
        project_id: &str,
        expected_revision: i64,
        request: ReplaceProjectOrgSelectionRequest,
    ) -> Result<ProjectOrgSelection, ServerError> {
        let mut tx = self.pool.begin().await?;
        let org_id = project_org_id(&mut tx, project_id).await?;
        lock_org_ref_for_project_projection(&mut tx, &org_id).await?;
        let parent_commit_id = current_project_ref(&mut tx, project_id).await?;
        let current_revision = current_project_org_selection_revision(&mut tx, project_id).await?;
        if current_revision != expected_revision {
            return Err(ServerError::version_conflict(
                "project_org_selection",
                expected_revision,
                current_revision,
            ));
        }
        let next_revision = current_revision + 1;
        sqlx::query("DELETE FROM project_org_resource_selections WHERE project_id = $1")
            .bind(project_id)
            .execute(&mut *tx)
            .await?;
        insert_project_org_selection_items(
            &mut tx,
            project_id,
            &org_id,
            "rule",
            next_revision,
            &request.rule_ids,
        )
        .await?;
        insert_project_org_selection_items(
            &mut tx,
            project_id,
            &org_id,
            "context",
            next_revision,
            &request.context_ids,
        )
        .await?;
        insert_project_org_selection_items(
            &mut tx,
            project_id,
            &org_id,
            "workflow",
            next_revision,
            &request.workflow_ids,
        )
        .await?;
        update_project_org_selection_revision(&mut tx, project_id, next_revision).await?;
        let commit_id =
            create_project_commit(&mut tx, project_id, parent_commit_id.as_deref()).await?;
        advance_project_ref(&mut tx, project_id, &commit_id).await?;
        let selection = load_project_org_selection(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(selection)
    }

    pub async fn create_personal_bundle(
        &self,
        owner_user_id: &str,
        request: PersonalBundleRequest,
    ) -> Result<PersonalBundleDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        user_ref(&mut tx, owner_user_id).await?;
        let bundle_id = prefixed_id("bdl");
        sqlx::query(
            "INSERT INTO personal_bundles (
                bundle_id, owner_user_id, name, description, revision
             )
             VALUES ($1, $2, $3, $4, 1)",
        )
        .bind(&bundle_id)
        .bind(owner_user_id)
        .bind(&request.name)
        .bind(request.description.as_deref().unwrap_or_default())
        .execute(&mut *tx)
        .await?;
        insert_bundle_items(&mut tx, &bundle_id, "rule", &request.rule_ids).await?;
        insert_bundle_items(&mut tx, &bundle_id, "context", &request.context_ids).await?;
        insert_bundle_items(&mut tx, &bundle_id, "workflow", &request.workflow_ids).await?;
        tx.commit().await?;
        self.get_personal_bundle(owner_user_id, &bundle_id).await
    }

    pub async fn list_personal_bundles(
        &self,
        owner_user_id: &str,
    ) -> Result<PersonalBundleListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT
                b.bundle_id, b.owner_user_id, b.name, b.description, b.revision,
                b.created_at, b.updated_at,
                count(*) FILTER (WHERE i.resource_kind = 'rule') AS rule_count,
                count(*) FILTER (WHERE i.resource_kind = 'context') AS context_count,
                count(*) FILTER (WHERE i.resource_kind = 'workflow') AS workflow_count
             FROM personal_bundles b
             LEFT JOIN personal_bundle_items i ON i.bundle_id = b.bundle_id
             WHERE b.owner_user_id = $1
             GROUP BY b.bundle_id
             ORDER BY b.updated_at DESC
             LIMIT 50",
        )
        .bind(owner_user_id)
        .fetch_all(&self.pool)
        .await?;

        Ok(PersonalBundleListResponse {
            items: rows
                .iter()
                .map(personal_bundle_meta_from_row)
                .collect::<Result<Vec<_>, _>>()?,
            page_info: page_info(),
        })
    }

    pub async fn get_personal_bundle(
        &self,
        owner_user_id: &str,
        bundle_id: &str,
    ) -> Result<PersonalBundleDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        ensure_bundle_owner(&mut tx, bundle_id, owner_user_id).await?;
        let detail = load_personal_bundle_detail(&mut tx, bundle_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn update_personal_bundle(
        &self,
        owner_user_id: &str,
        bundle_id: &str,
        expected_revision: i64,
        request: PersonalBundleUpdateRequest,
    ) -> Result<PersonalBundleDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT name, description, revision
             FROM personal_bundles
             WHERE bundle_id = $1 AND owner_user_id = $2
             FOR UPDATE",
        )
        .bind(bundle_id)
        .bind(owner_user_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("bundle", bundle_id))?;
        let current_revision: i64 = row.try_get("revision")?;
        if current_revision != expected_revision {
            return Err(ServerError::version_conflict(
                "bundle",
                expected_revision,
                current_revision,
            ));
        }
        let existing_name: String = row.try_get("name")?;
        let existing_description: String = row.try_get("description")?;
        let name = request.name.unwrap_or(existing_name);
        let description = request.description.unwrap_or(existing_description);
        sqlx::query(
            "UPDATE personal_bundles
             SET name = $2, description = $3, revision = revision + 1, updated_at = now()
             WHERE bundle_id = $1",
        )
        .bind(bundle_id)
        .bind(name)
        .bind(description)
        .execute(&mut *tx)
        .await?;

        replace_bundle_items_if_present(&mut tx, bundle_id, "rule", request.rule_ids).await?;
        replace_bundle_items_if_present(&mut tx, bundle_id, "context", request.context_ids).await?;
        replace_bundle_items_if_present(&mut tx, bundle_id, "workflow", request.workflow_ids)
            .await?;
        let detail = load_personal_bundle_detail(&mut tx, bundle_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn delete_personal_bundle(
        &self,
        owner_user_id: &str,
        bundle_id: &str,
        expected_revision: i64,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool.begin().await?;
        let current_revision = sqlx::query_scalar::<_, i64>(
            "SELECT revision
             FROM personal_bundles
             WHERE bundle_id = $1 AND owner_user_id = $2
             FOR UPDATE",
        )
        .bind(bundle_id)
        .bind(owner_user_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("bundle", bundle_id))?;
        if current_revision != expected_revision {
            return Err(ServerError::version_conflict(
                "bundle",
                expected_revision,
                current_revision,
            ));
        }
        sqlx::query("DELETE FROM personal_bundles WHERE bundle_id = $1")
            .bind(bundle_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: bundle_id.to_owned(),
        })
    }

    pub async fn list_org_rules(&self, org_id: &str) -> Result<RuleListResponse, ServerError> {
        Ok(RuleListResponse {
            items: list_rule_meta(&self.pool, "org", Some(org_id), None).await?,
            page_info: page_info(),
        })
    }

    pub async fn list_project_rules(
        &self,
        project_id: &str,
    ) -> Result<RuleListResponse, ServerError> {
        Ok(RuleListResponse {
            items: list_rule_meta(&self.pool, "project", None, Some(project_id)).await?,
            page_info: page_info(),
        })
    }

    pub async fn get_org_rule(
        &self,
        org_id: &str,
        rule_id: &str,
    ) -> Result<RuleDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_rule_detail(&mut tx, rule_id, "org", Some(org_id), None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_rule(
        &self,
        project_id: &str,
        rule_id: &str,
    ) -> Result<RuleDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_rule_detail(&mut tx, rule_id, "project", None, Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_org_context(&self, org_id: &str) -> Result<ContextListResponse, ServerError> {
        Ok(ContextListResponse {
            items: list_context_meta(&self.pool, "org", Some(org_id), None).await?,
            page_info: page_info(),
        })
    }

    pub async fn list_project_context(
        &self,
        project_id: &str,
    ) -> Result<ContextListResponse, ServerError> {
        Ok(ContextListResponse {
            items: list_context_meta(&self.pool, "project", None, Some(project_id)).await?,
            page_info: page_info(),
        })
    }

    pub async fn get_org_context(
        &self,
        org_id: &str,
        context_id: &str,
    ) -> Result<ContextDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_context_detail(&mut tx, context_id, "org", Some(org_id), None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_context(
        &self,
        project_id: &str,
        context_id: &str,
    ) -> Result<ContextDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail =
            load_context_detail(&mut tx, context_id, "project", None, Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_org_workflows(
        &self,
        org_id: &str,
    ) -> Result<WorkflowListResponse, ServerError> {
        Ok(WorkflowListResponse {
            items: list_workflow_meta(&self.pool, "org", Some(org_id), None).await?,
            page_info: page_info(),
        })
    }

    pub async fn list_project_workflows(
        &self,
        project_id: &str,
    ) -> Result<WorkflowListResponse, ServerError> {
        Ok(WorkflowListResponse {
            items: list_workflow_meta(&self.pool, "project", None, Some(project_id)).await?,
            page_info: page_info(),
        })
    }

    pub async fn get_org_workflow(
        &self,
        org_id: &str,
        workflow_id: &str,
    ) -> Result<WorkflowDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_workflow_detail(&mut tx, workflow_id, "org", Some(org_id), None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_workflow(
        &self,
        project_id: &str,
        workflow_id: &str,
    ) -> Result<WorkflowDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail =
            load_workflow_detail(&mut tx, workflow_id, "project", None, Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_org_metaprompt(&self, org_id: &str) -> Result<MetapromptDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_metaprompt_detail(&mut tx, "org", Some(org_id), None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_metaprompt(
        &self,
        project_id: &str,
    ) -> Result<MetapromptDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_metaprompt_detail(&mut tx, "project", None, Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_org_selection(
        &self,
        project_id: &str,
    ) -> Result<ProjectOrgSelection, ServerError> {
        let mut tx = self.pool.begin().await?;
        let selection = load_project_org_selection(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(selection)
    }

    pub async fn create_draft(
        &self,
        author_user_id: &str,
        request: CreateDraftRequest,
    ) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let org_id = project_org_id(&mut tx, &request.project_id).await?;
        user_ref(&mut tx, author_user_id).await?;
        if let Some(base_commit_id) = request.base_commit_id.as_deref() {
            match request.resource.scope {
                ResourceScope::Org => validate_org_commit(&mut tx, &org_id, base_commit_id).await?,
                ResourceScope::Project => {
                    validate_project_commit(&mut tx, &request.project_id, base_commit_id).await?
                }
            }
        }
        validate_draft_resource(&request.resource)?;
        for operation in &request.operations {
            validate_draft_operation_resource(&request.resource, operation)?;
        }

        let draft_id = prefixed_id("drf");
        sqlx::query(
            "INSERT INTO drafts (
                draft_id, project_id, author_user_id, title, description,
                resource_scope, resource_kind, base_commit_id, target_id, path, status, version,
                daemon_installation_id
             )
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'open', 1, $11)",
        )
        .bind(&draft_id)
        .bind(&request.project_id)
        .bind(author_user_id)
        .bind(&request.title)
        .bind(request.description.as_deref().unwrap_or_default())
        .bind(request.resource.scope.as_str())
        .bind(request.resource.kind.as_str())
        .bind(&request.base_commit_id)
        .bind(&request.resource.id)
        .bind(&request.resource.path)
        .bind(&request.daemon_installation_id)
        .execute(&mut *tx)
        .await?;

        for operation in request.operations {
            insert_draft_operation(&mut tx, &draft_id, operation).await?;
        }
        insert_draft_event(
            &mut tx,
            &draft_id,
            &request.project_id,
            DraftEventType::Created,
            1,
            Some(&request.daemon_installation_id),
        )
        .await?;

        tx.commit().await?;
        self.get_draft(&draft_id).await
    }

    pub async fn list_drafts(
        &self,
        author_user_id: &str,
        project_id: Option<&str>,
    ) -> Result<DraftListResponse, ServerError> {
        let rows = if let Some(project_id) = project_id {
            sqlx::query(
                "SELECT draft_id
                 FROM drafts
                 WHERE project_id = $1 AND author_user_id = $2
                 ORDER BY updated_at DESC
                 LIMIT 100",
            )
            .bind(project_id)
            .bind(author_user_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                "SELECT draft_id
                 FROM drafts
                 WHERE author_user_id = $1
                 ORDER BY updated_at DESC
                 LIMIT 100",
            )
            .bind(author_user_id)
            .fetch_all(&self.pool)
            .await?
        };
        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let draft_id: String = row.try_get("draft_id")?;
            items.push(self.get_draft(&draft_id).await?.draft);
        }
        Ok(DraftListResponse {
            items,
            page_info: page_info(),
        })
    }

    pub async fn get_draft(&self, draft_id: &str) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_draft_detail(&mut tx, draft_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn append_draft_operation(
        &self,
        draft_id: &str,
        expected_draft_version: i64,
        operation: DraftOperationInput,
    ) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        append_draft_operation_in_tx(&mut tx, draft_id, expected_draft_version, operation, None)
            .await?;
        tx.commit().await?;
        self.get_draft(draft_id).await
    }

    pub async fn update_draft(
        &self,
        draft_id: &str,
        expected_draft_version: i64,
        request: UpdateDraftRequest,
    ) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT title, description, status, version, project_id
             FROM drafts
             WHERE draft_id = $1
             FOR UPDATE",
        )
        .bind(draft_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
        let current_version: i64 = row.try_get("version")?;
        if current_version != expected_draft_version {
            return Err(ServerError::version_conflict(
                "draft",
                expected_draft_version,
                current_version,
            ));
        }
        let status = row.try_get::<String, _>("status")?;
        if status != "open" && status != "conflicted" {
            return Err(ServerError::invalid_transition("draft", &status, "updated"));
        }
        let next_status = match request.status {
            Some(DraftStatus::Open) if status == "open" => "open",
            Some(DraftStatus::Conflicted) if status == "conflicted" => "conflicted",
            Some(DraftStatus::Open) => {
                return Err(ServerError::invalid_transition("draft", &status, "open"));
            }
            Some(DraftStatus::Conflicted) => {
                return Err(ServerError::invalid_transition(
                    "draft",
                    &status,
                    "conflicted",
                ));
            }
            Some(DraftStatus::Discarded) => "discarded",
            Some(DraftStatus::Submitted) => {
                return Err(ServerError::InvalidRequest(
                    "draft submission must use review creation".to_owned(),
                ));
            }
            Some(DraftStatus::Merged) => {
                return Err(ServerError::InvalidRequest(
                    "draft merge must use review merge".to_owned(),
                ));
            }
            None => status.as_str(),
        };
        let existing_title: String = row.try_get("title")?;
        let existing_description: String = row.try_get("description")?;
        let title = request.title.unwrap_or(existing_title);
        let description = request.description.unwrap_or(existing_description);
        let updated = sqlx::query(
            "UPDATE drafts
             SET title = $2, description = $3, status = $4,
                 version = version + 1, updated_at = now()
             WHERE draft_id = $1
             RETURNING project_id, version",
        )
        .bind(draft_id)
        .bind(title)
        .bind(description)
        .bind(next_status)
        .fetch_one(&mut *tx)
        .await?;
        let event_type = match next_status {
            "discarded" => DraftEventType::Discarded,
            "conflicted" => DraftEventType::Conflicted,
            _ => DraftEventType::Updated,
        };
        insert_draft_event(
            &mut tx,
            draft_id,
            &updated.try_get::<String, _>("project_id")?,
            event_type,
            updated.try_get("version")?,
            None,
        )
        .await?;
        if next_status == "discarded" {
            sqlx::query(
                "UPDATE reviews
                 SET status = 'rejected', version = version + 1,
                     decision_body = 'Draft discarded after conflict.', updated_at = now()
                 WHERE draft_id = $1 AND status IN ('open', 'approved')",
            )
            .bind(draft_id)
            .execute(&mut *tx)
            .await?;
            sqlx::query("DELETE FROM draft_conflicts WHERE draft_id = $1")
                .bind(draft_id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        self.get_draft(draft_id).await
    }

    pub async fn discard_draft(
        &self,
        draft_id: &str,
        expected_draft_version: i64,
    ) -> Result<DeleteResult, ServerError> {
        self.update_draft(
            draft_id,
            expected_draft_version,
            UpdateDraftRequest {
                title: None,
                description: None,
                status: Some(DraftStatus::Discarded),
            },
        )
        .await?;
        Ok(DeleteResult {
            deleted: true,
            id: draft_id.to_owned(),
        })
    }

    pub async fn create_draft_operation_batch(
        &self,
        request: DraftOperationBatchRequest,
    ) -> Result<DraftOperationBatchResponse, ServerError> {
        if request.operations.is_empty() {
            return Err(ServerError::InvalidRequest(
                "draft operation batch cannot be empty".to_owned(),
            ));
        }
        let mut tx = self.pool.begin().await?;
        let mut accepted_operations = Vec::new();
        let mut cursor = None;
        let daemon_installation_id = request.daemon_installation_id;
        for item in request.operations {
            cursor = Some(
                append_draft_operation_in_tx(
                    &mut tx,
                    &item.draft_id,
                    item.expected_draft_version,
                    item.operation,
                    Some(&daemon_installation_id),
                )
                .await?,
            );
            accepted_operations.push(item.local_operation_id);
        }
        tx.commit().await?;
        Ok(DraftOperationBatchResponse {
            cursor: cursor.expect("non-empty batch").to_string(),
            accepted_operations,
        })
    }

    pub async fn list_draft_events(
        &self,
        author_user_id: &str,
        after_cursor: Option<&str>,
        limit: Option<i64>,
    ) -> Result<DraftEventListResponse, ServerError> {
        let limit = limit.unwrap_or(50);
        if !(1..=200).contains(&limit) {
            return Err(ServerError::InvalidRequest(
                "draft event limit must be between 1 and 200".to_owned(),
            ));
        }
        let fetch_limit = limit + 1;
        let mut rows = if let Some(after_cursor) = after_cursor {
            let after_sequence = after_cursor.parse::<i64>().map_err(|_| {
                ServerError::InvalidRequest("invalid draft event cursor".to_owned())
            })?;
            sqlx::query(
                "SELECT e.server_sequence, e.event_id, e.draft_id, e.project_id, e.event_type,
                        e.version, e.daemon_installation_id, e.created_at
                 FROM draft_events e
                 JOIN drafts d ON d.draft_id = e.draft_id
                 WHERE e.server_sequence > $1 AND d.author_user_id = $2
                 ORDER BY e.server_sequence
                 LIMIT $3",
            )
            .bind(after_sequence)
            .bind(author_user_id)
            .bind(fetch_limit)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                "SELECT e.server_sequence, e.event_id, e.draft_id, e.project_id, e.event_type,
                        e.version, e.daemon_installation_id, e.created_at
                 FROM draft_events e
                 JOIN drafts d ON d.draft_id = e.draft_id
                 WHERE d.author_user_id = $1
                 ORDER BY e.server_sequence
                 LIMIT $2",
            )
            .bind(author_user_id)
            .bind(fetch_limit)
            .fetch_all(&self.pool)
            .await?
        };
        let has_more = rows.len() > limit as usize;
        rows.truncate(limit as usize);
        let next_cursor = rows
            .last()
            .map(|row| {
                row.try_get::<i64, _>("server_sequence")
                    .map(|value| value.to_string())
            })
            .transpose()?;
        let events = rows
            .iter()
            .map(draft_event_from_row)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(DraftEventListResponse {
            next_cursor,
            has_more,
            events,
        })
    }

    pub async fn create_review(
        &self,
        request: CreateReviewRequest,
    ) -> Result<ReviewDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT draft_id, project_id, author_user_id, title, description, status, version
             FROM drafts
             WHERE draft_id = $1
             FOR UPDATE",
        )
        .bind(&request.draft_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("draft", &request.draft_id))?;

        let status: String = row.try_get("status")?;
        let version: i64 = row.try_get("version")?;
        if status != "open" {
            return Err(ServerError::invalid_transition(
                "draft",
                &status,
                "submitted",
            ));
        }
        if version != request.expected_draft_version {
            return Err(ServerError::version_conflict(
                "draft",
                request.expected_draft_version,
                version,
            ));
        }

        let review_id = prefixed_id("rev");
        let project_id: String = row.try_get("project_id")?;
        let author_user_id: String = row.try_get("author_user_id")?;
        let fallback_title: String = row.try_get("title")?;
        let fallback_description: String = row.try_get("description")?;
        let title = request.title.unwrap_or(fallback_title);
        let description = request.description.unwrap_or(fallback_description);

        let draft_event_row = sqlx::query(
            "UPDATE drafts
             SET status = 'submitted', version = version + 1, updated_at = now()
             WHERE draft_id = $1
             RETURNING project_id, version",
        )
        .bind(&request.draft_id)
        .fetch_one(&mut *tx)
        .await?;
        insert_draft_event(
            &mut tx,
            &request.draft_id,
            &draft_event_row.try_get::<String, _>("project_id")?,
            DraftEventType::Submitted,
            draft_event_row.try_get("version")?,
            None,
        )
        .await?;

        sqlx::query(
            "INSERT INTO reviews (
                review_id, draft_id, project_id, author_user_id, title, description,
                status, version
             )
             VALUES ($1, $2, $3, $4, $5, $6, 'open', 1)",
        )
        .bind(&review_id)
        .bind(&request.draft_id)
        .bind(&project_id)
        .bind(&author_user_id)
        .bind(&title)
        .bind(&description)
        .execute(&mut *tx)
        .await?;

        let detail = load_review_detail(&mut tx, &review_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_reviews(
        &self,
        principal: &AuthPrincipal,
        project_id: Option<&str>,
    ) -> Result<ReviewListResponse, ServerError> {
        let rows = if let Some(project_id) = project_id {
            sqlx::query(
                "SELECT
                    r.review_id, r.project_id, r.draft_id, r.title, r.description,
                    r.status, r.version, r.decision_body, r.created_at, r.updated_at,
                    u.user_id, u.email, u.display_name, u.avatar_url, u.role
                 FROM reviews r
                 JOIN users u ON u.user_id = r.author_user_id
                 JOIN projects p ON p.project_id = r.project_id
                 JOIN project_members m ON m.project_id = p.project_id
                 WHERE r.project_id = $1 AND p.org_id = $2 AND m.user_id = $3
                 ORDER BY r.updated_at DESC, r.review_id
                 LIMIT 200",
            )
            .bind(project_id)
            .bind(&principal.org_id)
            .bind(&principal.user_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                "SELECT
                    r.review_id, r.project_id, r.draft_id, r.title, r.description,
                    r.status, r.version, r.decision_body, r.created_at, r.updated_at,
                    u.user_id, u.email, u.display_name, u.avatar_url, u.role
                 FROM reviews r
                 JOIN users u ON u.user_id = r.author_user_id
                 JOIN projects p ON p.project_id = r.project_id
                 JOIN project_members m ON m.project_id = p.project_id
                 WHERE p.org_id = $1 AND m.user_id = $2
                 ORDER BY r.updated_at DESC, r.review_id
                 LIMIT 200",
            )
            .bind(&principal.org_id)
            .bind(&principal.user_id)
            .fetch_all(&self.pool)
            .await?
        };
        Ok(ReviewListResponse {
            items: rows
                .iter()
                .map(review_from_row)
                .collect::<Result<Vec<_>, _>>()?,
            page_info: page_info(),
        })
    }

    pub async fn get_review(&self, review_id: &str) -> Result<Review, ServerError> {
        let mut tx = self.pool.begin().await?;
        let review = load_review(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(review)
    }

    pub async fn get_review_detail(&self, review_id: &str) -> Result<ReviewDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_review_detail(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_review_comments(
        &self,
        review_id: &str,
    ) -> Result<ReviewCommentListResponse, ServerError> {
        let mut tx = self.pool.begin().await?;
        load_review(&mut tx, review_id).await?;
        let comments = load_review_comments(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(ReviewCommentListResponse {
            items: comments,
            page_info: page_info(),
        })
    }

    pub async fn create_review_comment(
        &self,
        review_id: &str,
        author_user_id: &str,
        request: CreateReviewCommentRequest,
    ) -> Result<ReviewComment, ServerError> {
        if request.body.trim().is_empty() {
            return Err(ServerError::InvalidRequest(
                "review comment body must not be empty".to_owned(),
            ));
        }
        let mut tx = self.pool.begin().await?;
        load_review(&mut tx, review_id).await?;
        user_ref(&mut tx, author_user_id).await?;
        let comment_id = prefixed_id("cmt");
        sqlx::query(
            "INSERT INTO review_comments (comment_id, review_id, author_user_id, body)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(&comment_id)
        .bind(review_id)
        .bind(author_user_id)
        .bind(request.body)
        .execute(&mut *tx)
        .await?;
        let comments = load_review_comments(&mut tx, review_id).await?;
        let comment = comments
            .into_iter()
            .find(|comment| comment.comment_id == comment_id)
            .ok_or_else(|| ServerError::not_found("review_comment", &comment_id))?;
        tx.commit().await?;
        Ok(comment)
    }

    pub async fn create_review_decision(
        &self,
        review_id: &str,
        request: CreateReviewDecisionRequest,
    ) -> Result<ReviewDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT r.draft_id, r.status AS review_status, r.version AS review_version,
                    d.project_id, d.status AS draft_status
             FROM reviews r
             JOIN drafts d ON d.draft_id = r.draft_id
             WHERE r.review_id = $1
             FOR UPDATE OF r, d",
        )
        .bind(review_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("review", review_id))?;
        let status: String = row.try_get("review_status")?;
        let version: i64 = row.try_get("review_version")?;

        if status != "open" {
            return Err(ServerError::invalid_transition(
                "review", &status, "decision",
            ));
        }
        if version != request.expected_review_version {
            return Err(ServerError::version_conflict(
                "review",
                request.expected_review_version,
                version,
            ));
        }
        let draft_status: String = row.try_get("draft_status")?;
        if draft_status != "submitted" {
            return Err(ServerError::invalid_transition(
                "draft",
                &draft_status,
                "review_decided",
            ));
        }

        let next_status = match request.decision {
            ReviewDecision::Approved => "approved",
            ReviewDecision::Rejected => "rejected",
        };
        if request.decision == ReviewDecision::Rejected {
            let draft_id: String = row.try_get("draft_id")?;
            let project_id: String = row.try_get("project_id")?;
            let next_draft_version: i64 = sqlx::query_scalar(
                "UPDATE drafts
                 SET status = 'open', version = version + 1, updated_at = now()
                 WHERE draft_id = $1
                 RETURNING version",
            )
            .bind(&draft_id)
            .fetch_one(&mut *tx)
            .await?;
            insert_draft_event(
                &mut tx,
                &draft_id,
                &project_id,
                DraftEventType::Reopened,
                next_draft_version,
                None,
            )
            .await?;
        }
        sqlx::query(
            "UPDATE reviews
             SET status = $2, version = version + 1, decision_body = $3, updated_at = now()
             WHERE review_id = $1",
        )
        .bind(review_id)
        .bind(next_status)
        .bind(&request.body)
        .execute(&mut *tx)
        .await?;

        let detail = load_review_detail(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn create_review_submission(
        &self,
        review_id: &str,
        author_user_id: &str,
        request: CreateReviewSubmissionRequest,
    ) -> Result<ReviewDetail, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT r.draft_id, r.status AS review_status, r.version AS review_version,
                    d.project_id, d.author_user_id, d.status AS draft_status,
                    d.version AS draft_version
             FROM reviews r
             JOIN drafts d ON d.draft_id = r.draft_id
             WHERE r.review_id = $1
             FOR UPDATE OF r, d",
        )
        .bind(review_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("review", review_id))?;

        let draft_author_user_id: String = row.try_get("author_user_id")?;
        if draft_author_user_id != author_user_id {
            return Err(ServerError::Forbidden(
                "only the draft author can resubmit its review".to_owned(),
            ));
        }
        let review_status: String = row.try_get("review_status")?;
        if review_status != "rejected" {
            return Err(ServerError::invalid_transition(
                "review",
                &review_status,
                "resubmitted",
            ));
        }
        let review_version: i64 = row.try_get("review_version")?;
        if review_version != request.expected_review_version {
            return Err(ServerError::version_conflict(
                "review",
                request.expected_review_version,
                review_version,
            ));
        }
        let draft_status: String = row.try_get("draft_status")?;
        if draft_status != "open" {
            return Err(ServerError::invalid_transition(
                "draft",
                &draft_status,
                "submitted",
            ));
        }
        let draft_version: i64 = row.try_get("draft_version")?;
        if draft_version != request.expected_draft_version {
            return Err(ServerError::version_conflict(
                "draft",
                request.expected_draft_version,
                draft_version,
            ));
        }

        let draft_id: String = row.try_get("draft_id")?;
        let project_id: String = row.try_get("project_id")?;
        let next_draft_version: i64 = sqlx::query_scalar(
            "UPDATE drafts
             SET status = 'submitted', version = version + 1, updated_at = now()
             WHERE draft_id = $1
             RETURNING version",
        )
        .bind(&draft_id)
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query(
            "UPDATE reviews
             SET status = 'open', version = version + 1, decision_body = NULL,
                 title = COALESCE($2, title), description = COALESCE($3, description),
                 updated_at = now()
             WHERE review_id = $1",
        )
        .bind(review_id)
        .bind(request.title)
        .bind(request.description)
        .execute(&mut *tx)
        .await?;
        insert_draft_event(
            &mut tx,
            &draft_id,
            &project_id,
            DraftEventType::Submitted,
            next_draft_version,
            None,
        )
        .await?;

        let detail = load_review_detail(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn create_review_merge(
        &self,
        review_id: &str,
        expected_project_ref: Option<&str>,
        request: CreateReviewMergeRequest,
    ) -> Result<ReviewMergeResult, ServerError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT r.review_id, r.draft_id, r.project_id, r.status, r.version,
                    d.resource_scope, d.base_commit_id, d.status AS draft_status,
                    d.version AS draft_version
             FROM reviews r
             JOIN drafts d ON d.draft_id = r.draft_id
             WHERE r.review_id = $1
             FOR UPDATE",
        )
        .bind(review_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("review", review_id))?;

        let status: String = row.try_get("status")?;
        let version: i64 = row.try_get("version")?;
        if status != "approved" {
            return Err(ServerError::invalid_transition("review", &status, "merged"));
        }
        if version != request.expected_review_version {
            return Err(ServerError::version_conflict(
                "review",
                request.expected_review_version,
                version,
            ));
        }

        let project_id: String = row.try_get("project_id")?;
        let draft_id: String = row.try_get("draft_id")?;
        let org_id = project_org_id(&mut tx, &project_id).await?;
        let resource_scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
        let current_head = match resource_scope {
            ResourceScope::Org => current_org_ref(&mut tx, &org_id).await?,
            ResourceScope::Project => {
                lock_org_ref_for_project_projection(&mut tx, &org_id).await?;
                current_project_ref(&mut tx, &project_id).await?
            }
        };
        if current_head.as_deref() != expected_project_ref {
            return Err(ServerError::precondition_failed(
                expected_project_ref,
                current_head.as_deref(),
            ));
        }
        let draft_base_commit_id: Option<String> = row.try_get("base_commit_id")?;
        if draft_base_commit_id != current_head {
            let draft_status: String = row.try_get("draft_status")?;
            let existing_conflict = load_draft_conflict(&mut tx, &draft_id).await?;
            let conflict_changed = draft_status != "conflicted"
                || existing_conflict.as_ref().is_none_or(|conflict| {
                    conflict.base_commit_id != draft_base_commit_id
                        || conflict.current_commit_id != current_head
                });
            if conflict_changed {
                sqlx::query(
                    "INSERT INTO draft_conflicts (
                        draft_id, base_commit_id, current_commit_id, detected_at
                     ) VALUES ($1, $2, $3, now())
                     ON CONFLICT (draft_id) DO UPDATE
                     SET base_commit_id = excluded.base_commit_id,
                         current_commit_id = excluded.current_commit_id,
                         detected_at = excluded.detected_at",
                )
                .bind(&draft_id)
                .bind(&draft_base_commit_id)
                .bind(&current_head)
                .execute(&mut *tx)
                .await?;
                let updated_version: i64 = sqlx::query_scalar(
                    "UPDATE drafts
                     SET status = 'conflicted', version = version + 1, updated_at = now()
                     WHERE draft_id = $1
                     RETURNING version",
                )
                .bind(&draft_id)
                .fetch_one(&mut *tx)
                .await?;
                insert_draft_event(
                    &mut tx,
                    &draft_id,
                    &project_id,
                    DraftEventType::Conflicted,
                    updated_version,
                    None,
                )
                .await?;
            }
            let error = ServerError::DraftConflict {
                review_id: review_id.to_owned(),
                draft_id,
                scope: resource_scope,
                base_commit_id: draft_base_commit_id,
                current_commit_id: current_head,
            };
            tx.commit().await?;
            return Err(error);
        }

        let operations = load_draft_operations(&mut tx, &draft_id).await?;
        let materialized_operations = materialize_draft_operations(&operations)?;
        let org_resource_impact = match resource_scope {
            ResourceScope::Org => {
                resolve_org_resource_impact(&mut tx, &org_id, &materialized_operations).await?
            }
            ResourceScope::Project => OrgResourceImpact::default(),
        };
        for operation in &materialized_operations {
            apply_operation(&mut tx, &project_id, resource_scope, operation).await?;
        }

        let commit_id = match resource_scope {
            ResourceScope::Org => {
                let commit_id =
                    create_org_commit(&mut tx, &org_id, current_head.as_deref()).await?;
                advance_org_ref(&mut tx, &org_id, &commit_id).await?;
                refresh_projects_for_org_resource_changes(&mut tx, &org_id, &org_resource_impact)
                    .await?;
                commit_id
            }
            ResourceScope::Project => {
                let commit_id =
                    create_project_commit(&mut tx, &project_id, current_head.as_deref()).await?;
                advance_project_ref(&mut tx, &project_id, &commit_id).await?;
                commit_id
            }
        };
        sqlx::query(
            "UPDATE reviews
             SET status = 'merged', version = version + 1, updated_at = now()
             WHERE review_id = $1",
        )
        .bind(review_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "INSERT INTO review_merges (
                merge_id, review_id, commit_id, applied_operation_count
             )
             VALUES ($1, $2, $3, $4)",
        )
        .bind(prefixed_id("mrg"))
        .bind(review_id)
        .bind(&commit_id)
        .bind(materialized_operations.len() as i32)
        .execute(&mut *tx)
        .await?;
        let merged_draft_version: i64 = sqlx::query_scalar(
            "UPDATE drafts
             SET status = 'merged', version = version + 1, updated_at = now()
             WHERE draft_id = $1
             RETURNING version",
        )
        .bind(&draft_id)
        .fetch_one(&mut *tx)
        .await?;
        insert_draft_event(
            &mut tx,
            &draft_id,
            &project_id,
            DraftEventType::Merged,
            merged_draft_version,
            None,
        )
        .await?;

        tx.commit().await?;
        let review = self.get_review(review_id).await?;
        Ok(ReviewMergeResult {
            review,
            commit_id: Some(commit_id),
            applied_operation_count: materialized_operations.len() as i64,
        })
    }

    pub async fn create_review_conflict_resolution(
        &self,
        review_id: &str,
        author_user_id: &str,
        expected_ref: Option<&str>,
        request: CreateReviewConflictResolutionRequest,
    ) -> Result<ReviewDetail, ServerError> {
        if request.operations.is_empty() {
            return Err(ServerError::InvalidRequest(
                "conflict resolution must contain at least one operation".to_owned(),
            ));
        }

        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT r.draft_id, r.project_id, r.status AS review_status,
                    r.version AS review_version, d.author_user_id, d.status AS draft_status,
                    d.version AS draft_version, d.resource_scope, d.resource_kind,
                    d.target_id, d.path
             FROM reviews r
             JOIN drafts d ON d.draft_id = r.draft_id
             WHERE r.review_id = $1
             FOR UPDATE",
        )
        .bind(review_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ServerError::not_found("review", review_id))?;

        let draft_id: String = row.try_get("draft_id")?;
        let draft_author_user_id: String = row.try_get("author_user_id")?;
        if draft_author_user_id != author_user_id {
            return Err(ServerError::Forbidden(
                "only the draft author can resolve its conflict".to_owned(),
            ));
        }
        let review_status: String = row.try_get("review_status")?;
        if review_status != "approved" {
            return Err(ServerError::invalid_transition(
                "review",
                &review_status,
                "conflict_resolved",
            ));
        }
        let review_version: i64 = row.try_get("review_version")?;
        if review_version != request.expected_review_version {
            return Err(ServerError::version_conflict(
                "review",
                request.expected_review_version,
                review_version,
            ));
        }
        let draft_status: String = row.try_get("draft_status")?;
        if draft_status != "conflicted" {
            return Err(ServerError::invalid_transition(
                "draft",
                &draft_status,
                "conflict_resolved",
            ));
        }
        let draft_version: i64 = row.try_get("draft_version")?;
        if draft_version != request.expected_draft_version {
            return Err(ServerError::version_conflict(
                "draft",
                request.expected_draft_version,
                draft_version,
            ));
        }

        let project_id: String = row.try_get("project_id")?;
        let resource_scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
        let draft_resource = DraftResourceRef {
            scope: resource_scope,
            kind: draft_resource_kind(row.try_get::<String, _>("resource_kind")?.as_str())?,
            id: row.try_get("target_id")?,
            path: row.try_get("path")?,
        };
        for operation in &request.operations {
            validate_draft_operation_resource(&draft_resource, operation)?;
        }

        let org_id = project_org_id(&mut tx, &project_id).await?;
        let current_head = match resource_scope {
            ResourceScope::Org => current_org_ref(&mut tx, &org_id).await?,
            ResourceScope::Project => current_project_ref(&mut tx, &project_id).await?,
        };
        if current_head.as_deref() != expected_ref {
            return Err(ServerError::precondition_failed(
                expected_ref,
                current_head.as_deref(),
            ));
        }

        sqlx::query("DELETE FROM draft_operations WHERE draft_id = $1")
            .bind(&draft_id)
            .execute(&mut *tx)
            .await?;
        for operation in request.operations {
            insert_draft_operation(&mut tx, &draft_id, operation).await?;
        }
        let next_draft_version: i64 = sqlx::query_scalar(
            "UPDATE drafts
             SET base_commit_id = $2, status = 'submitted', version = version + 1,
                 updated_at = now()
             WHERE draft_id = $1
             RETURNING version",
        )
        .bind(&draft_id)
        .bind(&current_head)
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM draft_conflicts WHERE draft_id = $1")
            .bind(&draft_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "UPDATE reviews
             SET status = 'open', version = version + 1, decision_body = NULL,
                 updated_at = now()
             WHERE review_id = $1",
        )
        .bind(review_id)
        .execute(&mut *tx)
        .await?;
        insert_draft_event(
            &mut tx,
            &draft_id,
            &project_id,
            DraftEventType::Updated,
            next_draft_version,
            None,
        )
        .await?;
        let detail = load_review_detail(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_project_commits(
        &self,
        project_id: &str,
    ) -> Result<CommitListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT commit_id
             FROM commits
             WHERE scope = 'project' AND project_id = $1
             ORDER BY version DESC
             LIMIT 50",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let commit_id: String = row.try_get("commit_id")?;
            items.push(self.get_commit_payload(&commit_id).await?.commit);
        }

        Ok(CommitListResponse {
            items,
            page_info: PageInfo {
                next_cursor: None,
                has_more: false,
            },
        })
    }

    pub async fn get_commit_payload(&self, commit_id: &str) -> Result<CommitPayload, ServerError> {
        let mut tx = self.pool.begin().await?;
        let payload = load_commit_payload(&mut tx, commit_id).await?;
        tx.commit().await?;
        Ok(payload)
    }

    pub async fn get_project_commit_state(
        &self,
        project_id: &str,
        local_commit_id: Option<&str>,
    ) -> Result<CommitStateResponse, ServerError> {
        let mut tx = self.pool.begin().await?;
        project_org_id(&mut tx, project_id).await?;
        let reference = load_project_ref(&mut tx, project_id).await?;
        let latest = match reference.commit_id.as_deref() {
            Some(commit_id) => Some(load_commit_payload(&mut tx, commit_id).await?.commit),
            None => None,
        };
        tx.commit().await?;

        Ok(CommitStateResponse {
            update_available: local_commit_id != reference.commit_id.as_deref(),
            download_url: reference
                .commit_id
                .as_ref()
                .map(|commit_id| format!("/api/v1/commits/{commit_id}")),
            reference,
            latest,
            incremental_supported: false,
        })
    }

    pub async fn list_org_commits(&self, org_id: &str) -> Result<CommitListResponse, ServerError> {
        let rows = sqlx::query(
            "SELECT commit_id
             FROM commits
             WHERE scope = 'org' AND org_id = $1
             ORDER BY version DESC
             LIMIT 50",
        )
        .bind(org_id)
        .fetch_all(&self.pool)
        .await?;
        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let commit_id: String = row.try_get("commit_id")?;
            items.push(self.get_commit_payload(&commit_id).await?.commit);
        }
        Ok(CommitListResponse {
            items,
            page_info: page_info(),
        })
    }

    pub async fn get_org_commit_state(
        &self,
        org_id: &str,
        local_commit_id: Option<&str>,
    ) -> Result<CommitStateResponse, ServerError> {
        let mut tx = self.pool.begin().await?;
        let reference = load_org_ref(&mut tx, org_id).await?;
        let latest = match reference.commit_id.as_deref() {
            Some(commit_id) => Some(load_commit_payload(&mut tx, commit_id).await?.commit),
            None => None,
        };
        tx.commit().await?;
        Ok(CommitStateResponse {
            update_available: local_commit_id != reference.commit_id.as_deref(),
            download_url: reference
                .commit_id
                .as_ref()
                .map(|commit_id| format!("/api/v1/commits/{commit_id}")),
            reference,
            latest,
            incremental_supported: false,
        })
    }
}

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("{entity} not found: {id}")]
    NotFound { entity: &'static str, id: String },
    #[error("{entity} already exists: {id}")]
    AlreadyExists { entity: &'static str, id: String },
    #[error("{entity} version conflict: expected {expected}, actual {actual}")]
    VersionConflict {
        entity: &'static str,
        expected: i64,
        actual: i64,
    },
    #[error("ref precondition failed: expected {expected:?}, actual {actual:?}")]
    PreconditionFailed {
        expected: Option<String>,
        actual: Option<String>,
    },
    #[error(
        "draft {draft_id} is based on {base_commit_id:?}, but the current ref is {current_commit_id:?}"
    )]
    DraftConflict {
        review_id: String,
        draft_id: String,
        scope: ResourceScope,
        base_commit_id: Option<String>,
        current_commit_id: Option<String>,
    },
    #[error("{entity} cannot transition from {from} to {to}")]
    InvalidTransition {
        entity: &'static str,
        from: String,
        to: String,
    },
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),
}

impl ServerError {
    fn not_found(entity: &'static str, id: impl Into<String>) -> Self {
        Self::NotFound {
            entity,
            id: id.into(),
        }
    }

    fn already_exists(entity: &'static str, id: impl Into<String>) -> Self {
        Self::AlreadyExists {
            entity,
            id: id.into(),
        }
    }

    fn version_conflict(entity: &'static str, expected: i64, actual: i64) -> Self {
        Self::VersionConflict {
            entity,
            expected,
            actual,
        }
    }

    fn invalid_transition(entity: &'static str, from: &str, to: &str) -> Self {
        Self::InvalidTransition {
            entity,
            from: from.to_owned(),
            to: to.to_owned(),
        }
    }

    fn precondition_failed(expected: Option<&str>, actual: Option<&str>) -> Self {
        Self::PreconditionFailed {
            expected: expected.map(ToOwned::to_owned),
            actual: actual.map(ToOwned::to_owned),
        }
    }
}

fn validate_draft_operation_resource(
    draft_resource: &DraftResourceRef,
    operation: &DraftOperationInput,
) -> Result<(), ServerError> {
    validate_draft_resource(draft_resource)?;
    if operation.resource.scope != draft_resource.scope
        || operation.resource.kind != draft_resource.kind
    {
        return Err(ServerError::InvalidRequest(
            "one draft cannot mix resource scopes or kinds".to_owned(),
        ));
    }
    if let Some(content) = operation.content.as_ref() {
        if content.kind() != operation.resource.kind {
            return Err(ServerError::InvalidRequest(
                "draft content kind does not match its resource".to_owned(),
            ));
        }
        validate_draft_content_shape(content)?;
    }
    if operation.resource.kind == DraftResourceKind::Metaprompt
        && operation.action == DraftOperationAction::Rename
    {
        return Err(ServerError::InvalidRequest(
            "metaprompt does not support rename".to_owned(),
        ));
    }
    if let Some(path) = operation.resource.path.as_deref() {
        validate_resource_path(operation.resource.kind.as_str(), path)?;
    }
    if let Some(path) = operation.new_path.as_deref() {
        validate_resource_path(operation.resource.kind.as_str(), path)?;
    }
    let valid = match operation.action {
        DraftOperationAction::Create => {
            operation.resource.path.is_some()
                && operation.content.is_some()
                && operation.new_path.is_none()
        }
        DraftOperationAction::Update => {
            (operation.resource.id.is_some() || operation.resource.path.is_some())
                && operation.content.is_some()
                && operation.new_path.is_none()
        }
        DraftOperationAction::Rename => {
            (operation.resource.id.is_some() || operation.resource.path.is_some())
                && operation.content.is_none()
                && operation.new_path.is_some()
        }
        DraftOperationAction::Delete => {
            (operation.resource.id.is_some() || operation.resource.path.is_some())
                && operation.content.is_none()
                && operation.new_path.is_none()
        }
    };
    if valid {
        Ok(())
    } else {
        Err(ServerError::InvalidRequest(
            "draft operation fields do not match its action".to_owned(),
        ))
    }
}

fn validate_draft_content_shape(content: &DraftResourceContent) -> Result<(), ServerError> {
    match content {
        DraftResourceContent::Rule { constraint, .. } => validate_rule_constraint(constraint),
        DraftResourceContent::Workflow { steps, .. } => validate_workflow_step_shapes(steps),
        DraftResourceContent::Context { .. } | DraftResourceContent::Metaprompt { .. } => Ok(()),
    }
}

fn validate_draft_resource(resource: &DraftResourceRef) -> Result<(), ServerError> {
    if let Some(path) = resource.path.as_deref() {
        validate_resource_path(resource.kind.as_str(), path)?;
    }
    Ok(())
}

fn validate_resource_path(resource_kind: &str, path: &str) -> Result<(), ServerError> {
    if !is_normalized_relative_path(path) {
        return Err(ServerError::InvalidRequest(format!(
            "resource path is not a portable normalized relative path: {path}"
        )));
    }
    match resource_kind {
        "workflow" if !path.starts_with("workflow/") => Err(ServerError::InvalidRequest(
            "workflow path must use the workflow/ namespace".to_owned(),
        )),
        "rule" if path.to_ascii_lowercase().starts_with("workflow/") => Err(
            ServerError::InvalidRequest("rule path cannot use the workflow/ namespace".to_owned()),
        ),
        "metaprompt" if path != "META_PROMPT.md" => Err(ServerError::InvalidRequest(
            "metaprompt path must be META_PROMPT.md".to_owned(),
        )),
        _ => Ok(()),
    }
}

fn is_normalized_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.ends_with('/')
        && path.split('/').all(is_portable_path_segment)
}

fn is_portable_path_segment(segment: &str) -> bool {
    if segment.is_empty()
        || segment == "."
        || segment == ".."
        || segment.trim() != segment
        || segment.ends_with('.')
        || segment.chars().any(|character| {
            character.is_control()
                || matches!(character, '\\' | '<' | '>' | ':' | '"' | '|' | '?' | '*')
        })
    {
        return false;
    }
    let stem = segment
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        && !reserved_numbered_name(&stem, "COM")
        && !reserved_numbered_name(&stem, "LPT")
}

fn reserved_numbered_name(stem: &str, prefix: &str) -> bool {
    stem.strip_prefix(prefix)
        .is_some_and(|suffix| matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"))
}

fn materialization_output_path(resource_kind: &str, path: &str) -> Result<String, ServerError> {
    match resource_kind {
        "context" => Ok(format!("cache/context/{path}")),
        "rule" | "workflow" => Ok(format!("cache/rule/{path}")),
        "metaprompt" => Ok(format!("cache/{path}")),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown materialized resource kind: {other}"
        ))),
    }
}

fn insert_materialization_path(
    paths: &mut BTreeMap<String, (String, String)>,
    resource_id: &str,
    output_path: &str,
    owner: &str,
) -> Result<(), ServerError> {
    let normalized = output_path.to_lowercase();
    if let Some((existing_id, existing_path)) = paths.get(&normalized) {
        return Err(ServerError::InvalidRequest(format!(
            "{owner} materializes {existing_id} at {existing_path} and {resource_id} at {output_path}, which conflict"
        )));
    }
    for (index, _) in normalized.rmatch_indices('/') {
        if let Some((existing_id, existing_path)) = paths.get(&normalized[..index]) {
            return Err(ServerError::InvalidRequest(format!(
                "{owner} materializes {existing_id} at {existing_path} and {resource_id} at {output_path}, which conflict"
            )));
        }
    }
    let descendant_prefix = format!("{normalized}/");
    if let Some((_, (existing_id, existing_path))) = paths
        .range(descendant_prefix.clone()..)
        .next()
        .filter(|(path, _)| path.starts_with(&descendant_prefix))
    {
        return Err(ServerError::InvalidRequest(format!(
            "{owner} materializes {existing_id} at {existing_path} and {resource_id} at {output_path}, which conflict"
        )));
    }
    paths.insert(normalized, (resource_id.to_owned(), output_path.to_owned()));
    Ok(())
}

async fn insert_draft_operation(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    input: DraftOperationInput,
) -> Result<String, ServerError> {
    let operation_id = prefixed_id("dop");
    sqlx::query(
        "INSERT INTO draft_operations (
            operation_id, draft_id, action, resource_scope, resource_kind, target_id, path,
            new_path, content
         )
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(&operation_id)
    .bind(draft_id)
    .bind(input.action.as_str())
    .bind(input.resource.scope.as_str())
    .bind(input.resource.kind.as_str())
    .bind(&input.resource.id)
    .bind(&input.resource.path)
    .bind(&input.new_path)
    .bind(input.content.as_ref().map(Json))
    .execute(&mut **tx)
    .await?;
    Ok(operation_id)
}

async fn append_draft_operation_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    expected_draft_version: i64,
    operation: DraftOperationInput,
    event_daemon_installation_id: Option<&str>,
) -> Result<i64, ServerError> {
    let row = sqlx::query(
        "SELECT status, version, resource_scope, resource_kind
         FROM drafts
         WHERE draft_id = $1
         FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    let status: String = row.try_get("status")?;
    let version: i64 = row.try_get("version")?;
    let draft_resource = DraftResourceRef {
        scope: resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?,
        kind: draft_resource_kind(row.try_get::<String, _>("resource_kind")?.as_str())?,
        id: None,
        path: None,
    };

    if status != "open" {
        return Err(ServerError::invalid_transition("draft", &status, "append"));
    }
    if version != expected_draft_version {
        return Err(ServerError::version_conflict(
            "draft",
            expected_draft_version,
            version,
        ));
    }
    validate_draft_operation_resource(&draft_resource, &operation)?;

    insert_draft_operation(tx, draft_id, operation).await?;
    let updated = sqlx::query(
        "UPDATE drafts
         SET version = version + 1, updated_at = now()
         WHERE draft_id = $1
         RETURNING project_id, version",
    )
    .bind(draft_id)
    .fetch_one(&mut **tx)
    .await?;
    insert_draft_event(
        tx,
        draft_id,
        &updated.try_get::<String, _>("project_id")?,
        DraftEventType::OperationAppended,
        updated.try_get("version")?,
        event_daemon_installation_id,
    )
    .await
}

async fn insert_draft_event(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    project_id: &str,
    event_type: DraftEventType,
    version: i64,
    daemon_installation_id: Option<&str>,
) -> Result<i64, ServerError> {
    let row = sqlx::query(
        "INSERT INTO draft_events (
            event_id, draft_id, project_id, event_type, version, daemon_installation_id
         )
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING server_sequence",
    )
    .bind(prefixed_id("evt"))
    .bind(draft_id)
    .bind(project_id)
    .bind(event_type.as_str())
    .bind(version)
    .bind(daemon_installation_id)
    .fetch_one(&mut **tx)
    .await?;
    Ok(row.try_get("server_sequence")?)
}

async fn insert_bundle_items(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    resource_kind: &str,
    resource_ids: &[String],
) -> Result<(), ServerError> {
    for (position, resource_id) in resource_ids.iter().enumerate() {
        sqlx::query(
            "INSERT INTO personal_bundle_items (
                bundle_id, resource_id, resource_kind, position
             )
             VALUES ($1, $2, $3, $4)",
        )
        .bind(bundle_id)
        .bind(resource_id)
        .bind(resource_kind)
        .bind(position as i32)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

async fn replace_bundle_items_if_present(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    resource_kind: &str,
    resource_ids: Option<Vec<String>>,
) -> Result<(), ServerError> {
    if let Some(resource_ids) = resource_ids {
        sqlx::query(
            "DELETE FROM personal_bundle_items
             WHERE bundle_id = $1 AND resource_kind = $2",
        )
        .bind(bundle_id)
        .bind(resource_kind)
        .execute(&mut **tx)
        .await?;
        insert_bundle_items(tx, bundle_id, resource_kind, &resource_ids).await?;
    }
    Ok(())
}

async fn current_project_org_selection_revision(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<i64, ServerError> {
    sqlx::query_scalar::<_, i64>(
        "SELECT revision
         FROM project_org_selection_states
         WHERE project_id = $1
         FOR UPDATE",
    )
    .bind(project_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("project_org_selection", project_id))
}

async fn update_project_org_selection_revision(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    revision: i64,
) -> Result<(), ServerError> {
    sqlx::query(
        "UPDATE project_org_selection_states
         SET revision = $2, updated_at = now()
         WHERE project_id = $1",
    )
    .bind(project_id)
    .bind(revision)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn insert_project_org_selection_items(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    resource_kind: &str,
    revision: i64,
    resource_ids: &[String],
) -> Result<(), ServerError> {
    let mut seen = BTreeSet::new();
    for resource_id in resource_ids {
        if !seen.insert(resource_id) {
            return Err(ServerError::InvalidRequest(format!(
                "project org selection contains duplicate resource: {resource_id}"
            )));
        }
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM resources
                WHERE resource_id = $1
                  AND resource_kind = $2
                  AND org_id = $3
                  AND scope = 'org'
                  AND status = 'active'
            )",
        )
        .bind(resource_id)
        .bind(resource_kind)
        .bind(org_id)
        .fetch_one(&mut **tx)
        .await?;
        if !exists {
            return Err(ServerError::not_found("org_resource", resource_id));
        }
        sqlx::query(
            "INSERT INTO project_org_resource_selections (
                project_id, resource_id, revision
             )
             VALUES ($1, $2, $3)",
        )
        .bind(project_id)
        .bind(resource_id)
        .bind(revision)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

async fn load_personal_bundle_detail(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
) -> Result<PersonalBundleDetail, ServerError> {
    let bundle_row = sqlx::query(
        "SELECT
            b.bundle_id, b.owner_user_id, b.name, b.description, b.revision,
            b.created_at, b.updated_at,
            count(*) FILTER (WHERE i.resource_kind = 'rule') AS rule_count,
            count(*) FILTER (WHERE i.resource_kind = 'context') AS context_count,
            count(*) FILTER (WHERE i.resource_kind = 'workflow') AS workflow_count
         FROM personal_bundles b
         LEFT JOIN personal_bundle_items i ON i.bundle_id = b.bundle_id
         WHERE b.bundle_id = $1
         GROUP BY b.bundle_id",
    )
    .bind(bundle_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("bundle", bundle_id))?;

    let rows = sqlx::query(
        "SELECT
            r.resource_id, r.resource_kind, r.scope, r.project_id, r.path, r.name,
            r.status, r.content_hash, r.context_kind, octet_length(r.body) AS size,
            r.updated_at
         FROM personal_bundle_items i
         JOIN resources r ON r.resource_id = i.resource_id
         WHERE i.bundle_id = $1 AND r.status = 'active'
         ORDER BY i.position, r.resource_kind, r.path",
    )
    .bind(bundle_id)
    .fetch_all(&mut **tx)
    .await?;

    let mut rules = Vec::new();
    let mut context = Vec::new();
    let mut workflows = Vec::new();
    for row in rows {
        match row.try_get::<String, _>("resource_kind")?.as_str() {
            "rule" => rules.push(rule_meta_from_row(&row)?),
            "context" => context.push(context_meta_from_row(&row)?),
            "workflow" => workflows.push(workflow_meta_from_row(&row)?),
            other => {
                return Err(ServerError::InvalidRequest(format!(
                    "unknown bundle resource kind: {other}"
                )));
            }
        }
    }

    let bundle = personal_bundle_meta_from_row(&bundle_row)?;
    Ok(PersonalBundleDetail {
        etag: etag(bundle.revision),
        bundle,
        rules,
        context,
        workflows,
    })
}

async fn list_rule_meta(
    pool: &PgPool,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<RuleMeta>, ServerError> {
    let rows = list_resource_rows(pool, "rule", scope, org_id, project_id).await?;
    rows.iter().map(rule_meta_from_row).collect()
}

async fn list_context_meta(
    pool: &PgPool,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<ContextMeta>, ServerError> {
    let rows = list_resource_rows(pool, "context", scope, org_id, project_id).await?;
    rows.iter().map(context_meta_from_row).collect()
}

async fn list_workflow_meta(
    pool: &PgPool,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<WorkflowMeta>, ServerError> {
    let rows = list_resource_rows(pool, "workflow", scope, org_id, project_id).await?;
    rows.iter().map(workflow_meta_from_row).collect()
}

async fn list_resource_rows(
    pool: &PgPool,
    kind: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<sqlx::postgres::PgRow>, ServerError> {
    let rows = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                content_hash, context_kind, octet_length(body) AS size, updated_at
             FROM resources
             WHERE resource_kind = $1 AND scope = $2 AND project_id = $3 AND status = 'active'
             ORDER BY path
             LIMIT 200",
        )
        .bind(kind)
        .bind(scope)
        .bind(project_id)
        .fetch_all(pool)
        .await?
    } else if let Some(org_id) = org_id {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                content_hash, context_kind, octet_length(body) AS size, updated_at
             FROM resources
             WHERE resource_kind = $1 AND scope = $2 AND org_id = $3 AND status = 'active'
             ORDER BY path
             LIMIT 200",
        )
        .bind(kind)
        .bind(scope)
        .bind(org_id)
        .fetch_all(pool)
        .await?
    } else {
        return Err(ServerError::InvalidRequest(
            "resource query requires org_id or project_id".to_owned(),
        ));
    };
    Ok(rows)
}

async fn load_rule_detail(
    tx: &mut Transaction<'_, Postgres>,
    rule_id: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<RuleDetail, ServerError> {
    let row = load_resource_detail_row(tx, rule_id, "rule", scope, org_id, project_id).await?;
    let rule = rule_meta_from_row(&row)?;
    Ok(RuleDetail {
        content: RuleContent {
            applies_when: row.try_get("applies_when")?,
            constraint: row.try_get("body")?,
            tags: row.try_get("tags")?,
        },
        etag: etag(row.try_get("revision")?),
        rule,
    })
}

async fn load_context_detail(
    tx: &mut Transaction<'_, Postgres>,
    context_id: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<ContextDetail, ServerError> {
    let row =
        load_resource_detail_row(tx, context_id, "context", scope, org_id, project_id).await?;
    let context = context_meta_from_row(&row)?;
    Ok(ContextDetail {
        content: row.try_get("body")?,
        etag: etag(row.try_get("revision")?),
        context,
    })
}

async fn load_workflow_detail(
    tx: &mut Transaction<'_, Postgres>,
    workflow_id: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<WorkflowDetail, ServerError> {
    let row =
        load_resource_detail_row(tx, workflow_id, "workflow", scope, org_id, project_id).await?;
    let workflow = workflow_meta_from_row(&row)?;
    let steps = load_workflow_steps(tx, workflow_id).await?;
    Ok(WorkflowDetail {
        content: WorkflowContent {
            description: row.try_get("body")?,
            steps,
        },
        etag: etag(row.try_get("revision")?),
        workflow,
    })
}

async fn load_resource_detail_row(
    tx: &mut Transaction<'_, Postgres>,
    resource_id: &str,
    kind: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<sqlx::postgres::PgRow, ServerError> {
    let row = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                revision, content_hash, body, applies_when, tags, context_kind,
                octet_length(body) AS size,
                updated_at
             FROM resources
             WHERE resource_id = $1
               AND resource_kind = $2
               AND scope = $3
               AND project_id = $4
               AND status = 'active'",
        )
        .bind(resource_id)
        .bind(kind)
        .bind(scope)
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
    } else if let Some(org_id) = org_id {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                revision, content_hash, body, applies_when, tags, context_kind,
                octet_length(body) AS size,
                updated_at
             FROM resources
             WHERE resource_id = $1
               AND resource_kind = $2
               AND scope = $3
               AND org_id = $4
               AND status = 'active'",
        )
        .bind(resource_id)
        .bind(kind)
        .bind(scope)
        .bind(org_id)
        .fetch_optional(&mut **tx)
        .await?
    } else {
        return Err(ServerError::InvalidRequest(
            "resource detail requires org_id or project_id".to_owned(),
        ));
    };
    row.ok_or_else(|| ServerError::not_found("resource", resource_id))
}

async fn load_workflow_steps(
    tx: &mut Transaction<'_, Postgres>,
    resource_id: &str,
) -> Result<Vec<WorkflowStep>, ServerError> {
    let rows = sqlx::query(
        "SELECT step_order, rule_id, body
         FROM workflow_steps
         WHERE resource_id = $1
         ORDER BY step_order",
    )
    .bind(resource_id)
    .fetch_all(&mut **tx)
    .await?;

    rows.iter()
        .map(|row| {
            Ok(WorkflowStep {
                order: row.try_get("step_order")?,
                rule_id: row.try_get("rule_id")?,
                body: row.try_get("body")?,
            })
        })
        .collect()
}

async fn load_metaprompt_detail(
    tx: &mut Transaction<'_, Postgres>,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<MetapromptDetail, ServerError> {
    let row = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                metaprompt_id, scope, project_id, status, revision,
                content_hash, body, updated_at
             FROM metaprompts
             WHERE scope = $1 AND project_id = $2 AND status = 'active'",
        )
        .bind(scope)
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
    } else if let Some(org_id) = org_id {
        sqlx::query(
            "SELECT
                metaprompt_id, scope, project_id, status, revision,
                content_hash, body, updated_at
             FROM metaprompts
             WHERE scope = $1 AND org_id = $2 AND status = 'active'",
        )
        .bind(scope)
        .bind(org_id)
        .fetch_optional(&mut **tx)
        .await?
    } else {
        return Err(ServerError::InvalidRequest(
            "metaprompt query requires org_id or project_id".to_owned(),
        ));
    }
    .ok_or_else(|| ServerError::not_found("metaprompt", project_id.unwrap_or(scope)))?;

    let metaprompt = MetapromptMeta {
        metaprompt_id: row.try_get("metaprompt_id")?,
        scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
        project_id: row.try_get("project_id")?,
        path: "META_PROMPT.md".to_owned(),
        content_hash: row.try_get("content_hash")?,
        status: resource_status(row.try_get::<String, _>("status")?.as_str())?,
        updated_at: row.try_get("updated_at")?,
    };
    Ok(MetapromptDetail {
        content: row.try_get("body")?,
        etag: etag(row.try_get("revision")?),
        metaprompt,
    })
}

fn personal_bundle_meta_from_row(
    row: &sqlx::postgres::PgRow,
) -> Result<PersonalBundleMeta, ServerError> {
    Ok(PersonalBundleMeta {
        bundle_id: row.try_get("bundle_id")?,
        owner_user_id: row.try_get("owner_user_id")?,
        name: row.try_get("name")?,
        description: row.try_get("description")?,
        rule_count: row.try_get::<i64, _>("rule_count")?,
        context_count: row.try_get::<i64, _>("context_count")?,
        workflow_count: row.try_get::<i64, _>("workflow_count")?,
        revision: row.try_get("revision")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

fn project_from_row(row: &sqlx::postgres::PgRow) -> Result<Project, ServerError> {
    Ok(Project {
        project_id: row.try_get("project_id")?,
        name: row.try_get("name")?,
        description: row.try_get("description")?,
        revision: row.try_get("revision")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

fn draft_event_from_row(row: &sqlx::postgres::PgRow) -> Result<DraftEvent, ServerError> {
    Ok(DraftEvent {
        event_id: row.try_get("event_id")?,
        draft_id: row.try_get("draft_id")?,
        project_id: row.try_get("project_id")?,
        event_type: draft_event_type(row.try_get::<String, _>("event_type")?.as_str())?,
        version: row.try_get("version")?,
        daemon_installation_id: row.try_get("daemon_installation_id")?,
        created_at: row.try_get("created_at")?,
    })
}

fn rule_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<RuleMeta, ServerError> {
    Ok(RuleMeta {
        rule_id: row.try_get("resource_id")?,
        scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
        project_id: row.try_get("project_id")?,
        path: row.try_get("path")?,
        name: row.try_get("name")?,
        content_hash: row.try_get("content_hash")?,
        status: resource_status(row.try_get::<String, _>("status")?.as_str())?,
        updated_at: row.try_get("updated_at")?,
    })
}

fn context_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<ContextMeta, ServerError> {
    Ok(ContextMeta {
        context_id: row.try_get("resource_id")?,
        scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
        project_id: row.try_get("project_id")?,
        kind: context_kind(
            row.try_get::<Option<String>, _>("context_kind")?
                .as_deref()
                .unwrap_or("file"),
        )?,
        path: row.try_get("path")?,
        content_hash: row.try_get("content_hash")?,
        size: row.try_get::<i32, _>("size")? as i64,
        updated_at: row.try_get("updated_at")?,
    })
}

fn workflow_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<WorkflowMeta, ServerError> {
    Ok(WorkflowMeta {
        workflow_id: row.try_get("resource_id")?,
        scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
        project_id: row.try_get("project_id")?,
        path: row.try_get("path")?,
        name: row.try_get("name")?,
        content_hash: row.try_get("content_hash")?,
        status: resource_status(row.try_get::<String, _>("status")?.as_str())?,
        updated_at: row.try_get("updated_at")?,
    })
}

fn etag(revision: i64) -> String {
    format!("\"rev-{revision}\"")
}

fn page_info() -> PageInfo {
    PageInfo {
        next_cursor: None,
        has_more: false,
    }
}

async fn load_draft_detail(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<DraftDetail, ServerError> {
    let row = sqlx::query(
        "SELECT
            d.draft_id, d.project_id, d.base_commit_id, d.title, d.description,
            d.status, d.version,
            d.resource_scope, d.resource_kind, d.target_id, d.path, d.daemon_installation_id,
            d.created_at, d.updated_at,
            u.user_id, u.email, u.display_name, u.avatar_url, u.role
         FROM drafts d
         JOIN users u ON u.user_id = d.author_user_id
         WHERE d.draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;

    let daemon_installation_id: String = row.try_get("daemon_installation_id")?;
    let draft = Draft {
        draft_id: row.try_get("draft_id")?,
        project_id: row.try_get("project_id")?,
        base_commit_id: row.try_get("base_commit_id")?,
        author: user_ref_from_row(&row)?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        resource: DraftResourceRef {
            scope: resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?,
            kind: draft_resource_kind(row.try_get::<String, _>("resource_kind")?.as_str())?,
            id: row.try_get("target_id")?,
            path: row.try_get("path")?,
        },
        status: draft_status(row.try_get::<String, _>("status")?.as_str())?,
        version: row.try_get("version")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    };
    let operations = load_draft_operations(tx, draft_id).await?;
    let conflict = load_draft_conflict(tx, draft_id).await?;
    let conflict_count = i64::from(conflict.is_some());

    Ok(DraftDetail {
        draft,
        operations,
        sync_state: DraftSyncState {
            status: if conflict.is_some() {
                DraftSyncStatus::Conflicted
            } else {
                DraftSyncStatus::Synced
            },
            server_cursor: Some(format!(
                "draft:{}:{}",
                draft_id,
                row.try_get::<i64, _>("version")?
            )),
            daemon_installation_id: Some(daemon_installation_id),
            conflict_count,
        },
        conflict,
    })
}

async fn load_draft_conflict(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<Option<DraftConflict>, ServerError> {
    let row = sqlx::query(
        "SELECT base_commit_id, current_commit_id, detected_at
         FROM draft_conflicts
         WHERE draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?;
    row.map(|row| {
        Ok(DraftConflict {
            base_commit_id: row.try_get("base_commit_id")?,
            current_commit_id: row.try_get("current_commit_id")?,
            detected_at: row.try_get("detected_at")?,
        })
    })
    .transpose()
}

async fn load_draft_operations(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<Vec<DraftOperation>, ServerError> {
    let rows = sqlx::query(
        "SELECT operation_id, action, resource_scope, resource_kind, target_id, path,
                new_path, content, created_at
         FROM draft_operations
         WHERE draft_id = $1
         ORDER BY created_at, operation_id",
    )
    .bind(draft_id)
    .fetch_all(&mut **tx)
    .await?;

    rows.into_iter()
        .map(|row| {
            Ok(DraftOperation {
                input: DraftOperationInput {
                    action: draft_operation_action(row.try_get::<String, _>("action")?.as_str())?,
                    resource: DraftResourceRef {
                        scope: resource_scope(
                            row.try_get::<String, _>("resource_scope")?.as_str(),
                        )?,
                        kind: draft_resource_kind(
                            row.try_get::<String, _>("resource_kind")?.as_str(),
                        )?,
                        id: row.try_get("target_id")?,
                        path: row.try_get("path")?,
                    },
                    content: row
                        .try_get::<Option<Json<DraftResourceContent>>, _>("content")?
                        .map(|value| value.0),
                    new_path: row.try_get("new_path")?,
                },
                operation_id: row.try_get("operation_id")?,
                created_at: row.try_get("created_at")?,
            })
        })
        .collect()
}

async fn load_review(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<Review, ServerError> {
    let row = sqlx::query(
        "SELECT
            r.review_id, r.project_id, r.draft_id, r.title, r.description,
            r.status, r.version, r.decision_body, r.created_at, r.updated_at,
            u.user_id, u.email, u.display_name, u.avatar_url, u.role
         FROM reviews r
         JOIN users u ON u.user_id = r.author_user_id
         WHERE r.review_id = $1",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("review", review_id))?;

    review_from_row(&row)
}

async fn load_review_detail(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<ReviewDetail, ServerError> {
    let review = load_review(tx, review_id).await?;
    let draft = load_draft_detail(tx, &review.draft_id).await?;
    let comments = load_review_comments(tx, review_id).await?;
    Ok(ReviewDetail {
        review,
        draft: draft.draft,
        operations: draft.operations,
        comments,
        conflict: draft.conflict,
    })
}

fn review_from_row(row: &sqlx::postgres::PgRow) -> Result<Review, ServerError> {
    Ok(Review {
        review_id: row.try_get("review_id")?,
        project_id: row.try_get("project_id")?,
        draft_id: row.try_get("draft_id")?,
        author: user_ref_from_row(row)?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        status: review_status(row.try_get::<String, _>("status")?.as_str())?,
        version: row.try_get("version")?,
        decision_body: row.try_get("decision_body")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn load_review_comments(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<Vec<ReviewComment>, ServerError> {
    let rows = sqlx::query(
        "SELECT
            c.comment_id, c.review_id, c.body, c.created_at,
            u.user_id, u.email, u.display_name, u.avatar_url, u.role
         FROM review_comments c
         JOIN users u ON u.user_id = c.author_user_id
         WHERE c.review_id = $1
         ORDER BY c.created_at, c.comment_id
         LIMIT 200",
    )
    .bind(review_id)
    .fetch_all(&mut **tx)
    .await?;

    rows.iter()
        .map(|row| {
            Ok(ReviewComment {
                comment_id: row.try_get("comment_id")?,
                review_id: row.try_get("review_id")?,
                author: user_ref_from_row(row)?,
                body: row.try_get("body")?,
                created_at: row.try_get("created_at")?,
            })
        })
        .collect()
}

async fn apply_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    scope: ResourceScope,
    operation: &DraftOperationInput,
) -> Result<(), ServerError> {
    if operation.resource.scope != scope {
        return Err(ServerError::InvalidRequest(
            "draft operation scope does not match its draft".to_owned(),
        ));
    }
    match operation.resource.kind {
        DraftResourceKind::Metaprompt => {
            apply_metaprompt_operation(tx, project_id, scope, operation).await
        }
        _ => apply_resource_operation(tx, project_id, scope, operation).await,
    }
}

fn materialize_draft_operations(
    operations: &[DraftOperation],
) -> Result<Vec<DraftOperationInput>, ServerError> {
    let Some(first) = operations.first() else {
        return Err(ServerError::InvalidRequest(
            "review draft has no operations".to_owned(),
        ));
    };
    if first.input.action != DraftOperationAction::Create {
        return Ok(operations
            .iter()
            .map(|operation| operation.input.clone())
            .collect());
    }

    let mut materialized = first.input.clone();
    for operation in operations.iter().skip(1) {
        if operation.input.resource.kind != materialized.resource.kind {
            return Err(ServerError::InvalidRequest(
                "one draft cannot create multiple resource kinds".to_owned(),
            ));
        }
        match operation.input.action {
            DraftOperationAction::Create => {
                materialized.resource.path = operation.input.resource.path.clone();
                materialized.content = operation.input.content.clone();
            }
            DraftOperationAction::Update => {
                materialized.content = merge_draft_contents(
                    materialized.content.take(),
                    operation.input.content.clone(),
                )?;
            }
            DraftOperationAction::Rename => {
                materialized.resource.path = operation.input.new_path.clone();
            }
            DraftOperationAction::Delete => return Ok(Vec::new()),
        }
    }
    Ok(vec![materialized])
}

fn merge_draft_contents(
    base: Option<DraftResourceContent>,
    update: Option<DraftResourceContent>,
) -> Result<Option<DraftResourceContent>, ServerError> {
    match (base, update) {
        (
            Some(DraftResourceContent::Rule {
                name: base_name,
                applies_when: base_applies_when,
                constraint: _,
                tags: base_tags,
            }),
            Some(DraftResourceContent::Rule {
                name,
                applies_when,
                constraint,
                tags,
            }),
        ) => Ok(Some(DraftResourceContent::Rule {
            name: name.or(base_name),
            applies_when: applies_when.or(base_applies_when),
            constraint,
            tags: tags.or(base_tags),
        })),
        (
            Some(DraftResourceContent::Workflow {
                name: base_name, ..
            }),
            Some(DraftResourceContent::Workflow {
                name,
                description,
                steps,
            }),
        ) => Ok(Some(DraftResourceContent::Workflow {
            name: name.or(base_name),
            description,
            steps,
        })),
        (Some(base), Some(update)) if base.kind() != update.kind() => {
            Err(ServerError::InvalidRequest(
                "draft update content kind does not match its create operation".to_owned(),
            ))
        }
        (_, update) => Ok(update),
    }
}

async fn apply_resource_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    scope: ResourceScope,
    operation: &DraftOperationInput,
) -> Result<(), ServerError> {
    let org_id = project_org_id(tx, project_id).await?;
    let resource_project_id = (scope == ResourceScope::Project).then_some(project_id);
    match operation.action {
        DraftOperationAction::Create => {
            let path = operation.resource.path.as_ref().ok_or_else(|| {
                ServerError::InvalidRequest("create operation requires path".to_owned())
            })?;
            let content = operation.content.as_ref().ok_or_else(|| {
                ServerError::InvalidRequest("create operation requires content".to_owned())
            })?;
            let prepared = prepare_resource_content(operation.resource.kind, path, content, None)?;
            let resource_id = prefixed_id(operation.resource.kind.resource_id_prefix());
            sqlx::query(
                "INSERT INTO resources (
                    resource_id, org_id, project_id, scope, resource_kind, path, name,
                    status, revision, content_hash, body, applies_when, tags, context_kind
                 )
                 VALUES ($1, $2, $3, $4, $5, $6, $7, 'active', 1, $8, $9, $10, $11, $12)",
            )
            .bind(&resource_id)
            .bind(&org_id)
            .bind(resource_project_id)
            .bind(scope.as_str())
            .bind(operation.resource.kind.as_str())
            .bind(path)
            .bind(&prepared.name)
            .bind(content_hash(&prepared.blob_content))
            .bind(&prepared.body)
            .bind(&prepared.applies_when)
            .bind(&prepared.tags)
            .bind(context_kind_for(operation.resource.kind))
            .execute(&mut **tx)
            .await?;
            if operation.resource.kind == DraftResourceKind::Workflow {
                replace_workflow_steps(
                    tx,
                    &resource_id,
                    &org_id,
                    resource_project_id,
                    scope,
                    &prepared.workflow_steps,
                )
                .await?;
            }
        }
        DraftOperationAction::Update => {
            let resource =
                load_target_resource(tx, &org_id, resource_project_id, &operation.resource).await?;
            let content = operation.content.as_ref().ok_or_else(|| {
                ServerError::InvalidRequest("update operation requires content".to_owned())
            })?;
            let prepared = prepare_resource_content(
                operation.resource.kind,
                &resource.path,
                content,
                Some(&resource),
            )?;
            sqlx::query(
                "UPDATE resources
                 SET name = $2, body = $3, applies_when = $4, tags = $5,
                     content_hash = $6, revision = revision + 1,
                     status = 'active', updated_at = now()
                 WHERE resource_id = $1",
            )
            .bind(&resource.resource_id)
            .bind(&prepared.name)
            .bind(&prepared.body)
            .bind(&prepared.applies_when)
            .bind(&prepared.tags)
            .bind(content_hash(&prepared.blob_content))
            .execute(&mut **tx)
            .await?;
            if operation.resource.kind == DraftResourceKind::Workflow {
                replace_workflow_steps(
                    tx,
                    &resource.resource_id,
                    &org_id,
                    resource_project_id,
                    scope,
                    &prepared.workflow_steps,
                )
                .await?;
            }
        }
        DraftOperationAction::Rename => {
            let resource =
                load_target_resource(tx, &org_id, resource_project_id, &operation.resource).await?;
            let new_path = operation.new_path.as_ref().ok_or_else(|| {
                ServerError::InvalidRequest("rename operation requires new_path".to_owned())
            })?;
            sqlx::query(
                "UPDATE resources
                 SET path = $2,
                     name = CASE WHEN resource_kind = 'context' THEN $3 ELSE name END,
                     revision = revision + 1,
                     updated_at = now()
                 WHERE resource_id = $1",
            )
            .bind(&resource.resource_id)
            .bind(new_path)
            .bind(name_from_path(new_path))
            .execute(&mut **tx)
            .await?;
        }
        DraftOperationAction::Delete => {
            let resource =
                load_target_resource(tx, &org_id, resource_project_id, &operation.resource).await?;
            sqlx::query(
                "UPDATE resources
                 SET status = 'archived', revision = revision + 1, updated_at = now()
                 WHERE resource_id = $1",
            )
            .bind(&resource.resource_id)
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(())
}

struct PreparedResourceContent {
    name: String,
    body: String,
    applies_when: String,
    tags: Vec<String>,
    workflow_steps: Vec<WorkflowStepInput>,
    blob_content: String,
}

fn prepare_resource_content(
    kind: DraftResourceKind,
    path: &str,
    content: &DraftResourceContent,
    existing: Option<&TargetResource>,
) -> Result<PreparedResourceContent, ServerError> {
    if content.kind() != kind {
        return Err(ServerError::InvalidRequest(
            "draft content kind does not match its resource".to_owned(),
        ));
    }
    match content {
        DraftResourceContent::Context { content } => Ok(PreparedResourceContent {
            name: existing
                .map(|resource| resource.name.clone())
                .unwrap_or_else(|| name_from_path(path)),
            body: content.clone(),
            applies_when: String::new(),
            tags: Vec::new(),
            workflow_steps: Vec::new(),
            blob_content: content.clone(),
        }),
        DraftResourceContent::Rule {
            name,
            applies_when,
            constraint,
            tags,
        } => {
            validate_rule_constraint(constraint)?;
            let name = optional_non_empty(name.as_deref())
                .map(ToOwned::to_owned)
                .or_else(|| existing.map(|resource| resource.name.clone()))
                .unwrap_or_else(|| name_from_path(path));
            let applies_when = applies_when
                .clone()
                .or_else(|| existing.map(|resource| resource.applies_when.clone()))
                .unwrap_or_default();
            let tags = tags
                .clone()
                .map(normalize_tags)
                .or_else(|| existing.map(|resource| resource.tags.clone()))
                .unwrap_or_default();
            let authority = RuleContent {
                applies_when: applies_when.clone(),
                constraint: constraint.clone(),
                tags: tags.clone(),
            };
            let blob_content = rule_blob_content(&name, &authority)?;
            Ok(PreparedResourceContent {
                name,
                body: constraint.clone(),
                applies_when,
                tags,
                workflow_steps: Vec::new(),
                blob_content,
            })
        }
        DraftResourceContent::Workflow {
            name,
            description,
            steps,
        } => {
            validate_workflow_step_shapes(steps)?;
            let name = optional_non_empty(name.as_deref())
                .map(ToOwned::to_owned)
                .or_else(|| existing.map(|resource| resource.name.clone()))
                .unwrap_or_else(|| name_from_path(path));
            let authority = WorkflowContent {
                description: description.clone(),
                steps: ordered_workflow_steps(steps)?,
            };
            let blob_content = workflow_blob_content(&name, &authority)?;
            Ok(PreparedResourceContent {
                name,
                body: description.clone(),
                applies_when: String::new(),
                tags: Vec::new(),
                workflow_steps: steps.clone(),
                blob_content,
            })
        }
        DraftResourceContent::Metaprompt { .. } => Err(ServerError::InvalidRequest(
            "metaprompt content cannot be stored as a resource".to_owned(),
        )),
    }
}

fn optional_non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn normalize_tags(tags: Vec<String>) -> Vec<String> {
    tags.into_iter()
        .map(|tag| tag.trim().to_owned())
        .filter(|tag| !tag.is_empty())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

#[derive(Default)]
struct OrgResourceImpact {
    resource_ids: BTreeSet<String>,
    deleted_resource_ids: BTreeSet<String>,
}

async fn resolve_org_resource_impact(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    operations: &[DraftOperationInput],
) -> Result<OrgResourceImpact, ServerError> {
    let mut impact = OrgResourceImpact::default();
    for operation in operations {
        if operation.resource.kind == DraftResourceKind::Metaprompt
            || operation.action == DraftOperationAction::Create
        {
            continue;
        }
        let target = load_target_resource(tx, org_id, None, &operation.resource).await?;
        impact.resource_ids.insert(target.resource_id.clone());
        if operation.action == DraftOperationAction::Delete {
            impact.deleted_resource_ids.insert(target.resource_id);
        }
    }
    Ok(impact)
}

async fn refresh_projects_for_org_resource_changes(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    impact: &OrgResourceImpact,
) -> Result<(), ServerError> {
    if impact.resource_ids.is_empty() {
        return Ok(());
    }

    let resource_ids = impact.resource_ids.iter().cloned().collect::<Vec<_>>();
    let rows = sqlx::query(
        "SELECT DISTINCT s.project_id
         FROM project_org_resource_selections s
         JOIN projects p ON p.project_id = s.project_id
         WHERE p.org_id = $1 AND s.resource_id = ANY($2::text[])
         ORDER BY s.project_id",
    )
    .bind(org_id)
    .bind(&resource_ids)
    .fetch_all(&mut **tx)
    .await?;
    let deleted_resource_ids = impact
        .deleted_resource_ids
        .iter()
        .cloned()
        .collect::<Vec<_>>();

    for row in rows {
        let project_id: String = row.try_get("project_id")?;
        let parent_commit_id = current_project_ref(tx, &project_id).await?;
        if !deleted_resource_ids.is_empty() {
            let deleted = sqlx::query(
                "DELETE FROM project_org_resource_selections
                 WHERE project_id = $1 AND resource_id = ANY($2::text[])",
            )
            .bind(&project_id)
            .bind(&deleted_resource_ids)
            .execute(&mut **tx)
            .await?;
            if deleted.rows_affected() > 0 {
                let revision = current_project_org_selection_revision(tx, &project_id).await?;
                update_project_org_selection_revision(tx, &project_id, revision + 1).await?;
            }
        }
        let commit_id = create_project_commit(tx, &project_id, parent_commit_id.as_deref()).await?;
        advance_project_ref(tx, &project_id, &commit_id).await?;
    }
    Ok(())
}

fn validate_rule_constraint(constraint: &str) -> Result<(), ServerError> {
    if constraint.trim().is_empty() {
        return Err(ServerError::InvalidRequest(
            "rule constraint must not be empty".to_owned(),
        ));
    }
    Ok(())
}

fn validate_workflow_step_shapes(steps: &[WorkflowStepInput]) -> Result<(), ServerError> {
    if steps.is_empty() {
        return Err(ServerError::InvalidRequest(
            "workflow must contain at least one step".to_owned(),
        ));
    }
    for step in steps {
        let has_rule = step
            .rule_id
            .as_deref()
            .is_some_and(|rule_id| !rule_id.trim().is_empty());
        let has_body = step
            .body
            .as_deref()
            .is_some_and(|body| !body.trim().is_empty());
        if has_rule == has_body {
            return Err(ServerError::InvalidRequest(
                "workflow step must contain exactly one of rule_id or body".to_owned(),
            ));
        }
    }
    Ok(())
}

fn ordered_workflow_steps(steps: &[WorkflowStepInput]) -> Result<Vec<WorkflowStep>, ServerError> {
    steps
        .iter()
        .enumerate()
        .map(|(index, step)| {
            Ok(WorkflowStep {
                order: i32::try_from(index + 1).map_err(|_| {
                    ServerError::InvalidRequest("workflow has too many steps".to_owned())
                })?,
                rule_id: step.rule_id.clone(),
                body: step.body.clone(),
            })
        })
        .collect()
}

async fn replace_workflow_steps(
    tx: &mut Transaction<'_, Postgres>,
    workflow_id: &str,
    org_id: &str,
    project_id: Option<&str>,
    scope: ResourceScope,
    steps: &[WorkflowStepInput],
) -> Result<(), ServerError> {
    sqlx::query("DELETE FROM workflow_steps WHERE resource_id = $1")
        .bind(workflow_id)
        .execute(&mut **tx)
        .await?;
    for (index, step) in steps.iter().enumerate() {
        if let Some(rule_id) = step.rule_id.as_deref() {
            validate_workflow_rule_reference(tx, org_id, project_id, scope, rule_id).await?;
        }
        sqlx::query(
            "INSERT INTO workflow_steps (resource_id, step_order, rule_id, body)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(workflow_id)
        .bind(
            i32::try_from(index + 1).map_err(|_| {
                ServerError::InvalidRequest("workflow has too many steps".to_owned())
            })?,
        )
        .bind(&step.rule_id)
        .bind(&step.body)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

async fn validate_workflow_rule_reference(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    project_id: Option<&str>,
    workflow_scope: ResourceScope,
    rule_id: &str,
) -> Result<(), ServerError> {
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1
            FROM resources r
            WHERE r.resource_id = $1 AND r.org_id = $2 AND r.resource_kind = 'rule'
              AND r.status = 'active'
              AND (
                ($3 = 'org' AND r.scope = 'org')
                OR (
                    $3 = 'project'
                    AND (
                        (r.scope = 'project' AND r.project_id = $4)
                        OR (
                            r.scope = 'org'
                            AND EXISTS(
                                SELECT 1
                                FROM project_org_resource_selections s
                                WHERE s.project_id = $4 AND s.resource_id = r.resource_id
                            )
                        )
                    )
                )
              )
         )",
    )
    .bind(rule_id)
    .bind(org_id)
    .bind(workflow_scope.as_str())
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?;
    if exists {
        Ok(())
    } else {
        Err(ServerError::InvalidRequest(format!(
            "workflow references unavailable rule: {rule_id}"
        )))
    }
}

async fn apply_metaprompt_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    scope: ResourceScope,
    operation: &DraftOperationInput,
) -> Result<(), ServerError> {
    let org_id = project_org_id(tx, project_id).await?;
    let resource_project_id = (scope == ResourceScope::Project).then_some(project_id);
    let existing = sqlx::query(
        "SELECT metaprompt_id
         FROM metaprompts
         WHERE scope = $1 AND org_id = $2
           AND (($1 = 'org' AND project_id IS NULL) OR project_id = $3)
           AND status = 'active'
         FOR UPDATE",
    )
    .bind(scope.as_str())
    .bind(&org_id)
    .bind(resource_project_id)
    .fetch_optional(&mut **tx)
    .await?;

    match operation.action {
        DraftOperationAction::Create | DraftOperationAction::Update => {
            let body = match operation.content.as_ref() {
                Some(DraftResourceContent::Metaprompt { content }) => content,
                Some(_) => {
                    return Err(ServerError::InvalidRequest(
                        "metaprompt operation has the wrong content kind".to_owned(),
                    ));
                }
                None => {
                    return Err(ServerError::InvalidRequest(
                        "metaprompt create/update requires content".to_owned(),
                    ));
                }
            };
            if let Some(row) = existing {
                let metaprompt_id: String = row.try_get("metaprompt_id")?;
                sqlx::query(
                    "UPDATE metaprompts
                     SET body = $2, content_hash = $3, revision = revision + 1,
                         status = 'active', updated_at = now()
                     WHERE metaprompt_id = $1",
                )
                .bind(metaprompt_id)
                .bind(body)
                .bind(content_hash(body))
                .execute(&mut **tx)
                .await?;
            } else {
                sqlx::query(
                    "INSERT INTO metaprompts (
                        metaprompt_id, org_id, project_id, scope, status,
                        revision, content_hash, body
                     )
                     VALUES ($1, $2, $3, $4, 'active', 1, $5, $6)",
                )
                .bind(prefixed_id("mpf"))
                .bind(&org_id)
                .bind(resource_project_id)
                .bind(scope.as_str())
                .bind(content_hash(body))
                .bind(body)
                .execute(&mut **tx)
                .await?;
            }
        }
        DraftOperationAction::Delete => {
            let row = existing.ok_or_else(|| ServerError::not_found("metaprompt", project_id))?;
            let metaprompt_id: String = row.try_get("metaprompt_id")?;
            sqlx::query(
                "UPDATE metaprompts
                 SET status = 'archived', revision = revision + 1, updated_at = now()
                 WHERE metaprompt_id = $1",
            )
            .bind(metaprompt_id)
            .execute(&mut **tx)
            .await?;
        }
        DraftOperationAction::Rename => {
            return Err(ServerError::InvalidRequest(
                "metaprompt does not support rename".to_owned(),
            ));
        }
    }
    Ok(())
}

async fn validate_project_effective_memory(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
) -> Result<(), ServerError> {
    let cross_org_resource = sqlx::query_scalar::<_, String>(
        "SELECT s.resource_id
         FROM project_org_resource_selections s
         JOIN resources r ON r.resource_id = s.resource_id
         WHERE s.project_id = $1 AND r.org_id <> $2
         LIMIT 1",
    )
    .bind(project_id)
    .bind(org_id)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(resource_id) = cross_org_resource {
        return Err(ServerError::InvalidRequest(format!(
            "project cannot select a resource from another organization: {resource_id}"
        )));
    }

    let rows = sqlx::query(
        "SELECT r.resource_id, r.resource_kind, r.path
         FROM resources r
         WHERE r.status = 'active'
           AND (
             (r.scope = 'project' AND r.project_id = $1)
             OR (
               r.scope = 'org' AND r.org_id = $2
               AND EXISTS(
                 SELECT 1
                 FROM project_org_resource_selections s
                 WHERE s.project_id = $1 AND s.resource_id = r.resource_id
               )
             )
           )
         ORDER BY r.resource_kind, r.path, r.resource_id",
    )
    .bind(project_id)
    .bind(org_id)
    .fetch_all(&mut **tx)
    .await?;
    let mut output_paths = BTreeMap::new();
    for row in rows {
        let resource_id: String = row.try_get("resource_id")?;
        let resource_kind: String = row.try_get("resource_kind")?;
        let path: String = row.try_get("path")?;
        validate_resource_path(&resource_kind, &path)?;
        let output_path = materialization_output_path(&resource_kind, &path)?;
        insert_materialization_path(
            &mut output_paths,
            &resource_id,
            &output_path,
            "project effective memory",
        )?;
    }

    let missing_rule = sqlx::query(
        "SELECT w.name, ws.rule_id
         FROM resources w
         JOIN workflow_steps ws ON ws.resource_id = w.resource_id
         WHERE w.resource_kind = 'workflow' AND w.status = 'active'
           AND ws.rule_id IS NOT NULL
           AND (
             (w.scope = 'project' AND w.project_id = $1)
             OR (
               w.scope = 'org' AND w.org_id = $2
               AND EXISTS(
                 SELECT 1
                 FROM project_org_resource_selections selected_workflow
                 WHERE selected_workflow.project_id = $1
                   AND selected_workflow.resource_id = w.resource_id
               )
             )
           )
           AND NOT EXISTS(
             SELECT 1
             FROM resources r
             WHERE r.resource_id = ws.rule_id
               AND r.resource_kind = 'rule' AND r.status = 'active'
               AND (
                 (r.scope = 'project' AND r.project_id = $1)
                 OR (
                   r.scope = 'org' AND r.org_id = $2
                   AND EXISTS(
                     SELECT 1
                     FROM project_org_resource_selections selected_rule
                     WHERE selected_rule.project_id = $1
                       AND selected_rule.resource_id = r.resource_id
                   )
                 )
               )
           )
         ORDER BY w.resource_id, ws.step_order
         LIMIT 1",
    )
    .bind(project_id)
    .bind(org_id)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(row) = missing_rule {
        let workflow_name: String = row.try_get("name")?;
        let rule_id: String = row.try_get("rule_id")?;
        return Err(ServerError::InvalidRequest(format!(
            "workflow {workflow_name} references rule {rule_id}, which is not available in project effective memory"
        )));
    }
    Ok(())
}

async fn validate_org_effective_memory(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
) -> Result<(), ServerError> {
    let missing_rule = sqlx::query(
        "SELECT w.name, ws.rule_id
         FROM resources w
         JOIN workflow_steps ws ON ws.resource_id = w.resource_id
         WHERE w.scope = 'org' AND w.org_id = $1
           AND w.resource_kind = 'workflow' AND w.status = 'active'
           AND ws.rule_id IS NOT NULL
           AND NOT EXISTS(
             SELECT 1
             FROM resources r
             WHERE r.resource_id = ws.rule_id
               AND r.scope = 'org' AND r.org_id = $1
               AND r.resource_kind = 'rule' AND r.status = 'active'
           )
         ORDER BY w.resource_id, ws.step_order
         LIMIT 1",
    )
    .bind(org_id)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(row) = missing_rule {
        let workflow_name: String = row.try_get("name")?;
        let rule_id: String = row.try_get("rule_id")?;
        return Err(ServerError::InvalidRequest(format!(
            "workflow {workflow_name} references rule {rule_id}, which is not available in organization memory"
        )));
    }
    Ok(())
}

async fn create_project_commit(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    parent_commit_id: Option<&str>,
) -> Result<String, ServerError> {
    let org_id = project_org_id(tx, project_id).await?;
    validate_project_effective_memory(tx, project_id, &org_id).await?;
    let version = sqlx::query_scalar::<_, Option<i64>>(
        "SELECT max(version)
         FROM commits
         WHERE scope = 'project' AND project_id = $1",
    )
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?
    .unwrap_or(0)
        + 1;
    let mut entries = Vec::new();
    let project_rows = sqlx::query(
        "SELECT resource_id, resource_kind, path, name, body, applies_when, tags
         FROM resources
         WHERE scope = 'project' AND project_id = $1 AND status = 'active'
         ORDER BY resource_kind, path",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in project_rows {
        entries
            .push(pending_resource_entry(tx, &row, "project", Some(project_id), "project").await?);
    }

    let selected_rows = sqlx::query(
        "SELECT r.resource_id, r.resource_kind, r.path, r.name, r.body,
                r.applies_when, r.tags
         FROM project_org_resource_selections s
         JOIN resources r ON r.resource_id = s.resource_id
         WHERE s.project_id = $1 AND r.status = 'active'
         ORDER BY r.resource_kind, r.path",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in selected_rows {
        entries.push(pending_resource_entry(tx, &row, "org", None, "selected_org").await?);
    }

    let metaprompt_rows = sqlx::query(
        "SELECT metaprompt_id, 'metaprompt' AS resource_kind, 'META_PROMPT.md' AS path,
                body
         FROM metaprompts
         WHERE scope = 'project' AND project_id = $1 AND status = 'active'
         ORDER BY metaprompt_id",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in metaprompt_rows {
        entries.push(
            pending_metaprompt_entry(tx, &row, "project", Some(project_id), "project").await?,
        );
    }

    let project_org_selection = load_project_org_selection(tx, project_id).await?;
    let selection_content = serde_json::to_string(&project_org_selection).map_err(|error| {
        ServerError::InvalidRequest(format!(
            "failed to serialize project org selection: {error}"
        ))
    })?;
    let selection_blob_id = store_blob(tx, &selection_content).await?;
    entries.push(PendingTreeEntry {
        item_id: format!("project_org_selection:{project_id}"),
        resource_kind: "project_org_selection".to_owned(),
        scope: "daemon".to_owned(),
        project_id: Some(project_id.to_owned()),
        path: None,
        blob_id: selection_blob_id,
        source: "config".to_owned(),
    });

    validate_tree_materialization_paths(&entries)?;
    let tree_id = store_tree(tx, &entries).await?;
    create_commit(
        tx,
        "project",
        &org_id,
        Some(project_id),
        &tree_id,
        parent_commit_id,
        version,
    )
    .await
}

async fn create_org_commit(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    parent_commit_id: Option<&str>,
) -> Result<String, ServerError> {
    validate_org_effective_memory(tx, org_id).await?;
    let version = sqlx::query_scalar::<_, Option<i64>>(
        "SELECT max(version) FROM commits WHERE scope = 'org' AND org_id = $1",
    )
    .bind(org_id)
    .fetch_one(&mut **tx)
    .await?
    .unwrap_or(0)
        + 1;
    let rows = sqlx::query(
        "SELECT resource_id, resource_kind, path, name, body, applies_when, tags
         FROM resources
         WHERE scope = 'org' AND org_id = $1 AND status = 'active'
         ORDER BY resource_kind, path",
    )
    .bind(org_id)
    .fetch_all(&mut **tx)
    .await?;
    let mut entries = Vec::with_capacity(rows.len());
    for row in rows {
        entries.push(pending_resource_entry(tx, &row, "org", None, "org").await?);
    }
    let metaprompt_rows = sqlx::query(
        "SELECT metaprompt_id, 'metaprompt' AS resource_kind, 'META_PROMPT.md' AS path, body
         FROM metaprompts
         WHERE scope = 'org' AND org_id = $1 AND status = 'active'
         ORDER BY metaprompt_id",
    )
    .bind(org_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in metaprompt_rows {
        entries.push(pending_metaprompt_entry(tx, &row, "org", None, "org").await?);
    }
    validate_tree_materialization_paths(&entries)?;
    let tree_id = store_tree(tx, &entries).await?;
    create_commit(tx, "org", org_id, None, &tree_id, parent_commit_id, version).await
}

#[derive(serde::Serialize)]
struct PendingTreeEntry {
    item_id: String,
    resource_kind: String,
    scope: String,
    project_id: Option<String>,
    path: Option<String>,
    blob_id: String,
    source: String,
}

fn validate_tree_materialization_paths(entries: &[PendingTreeEntry]) -> Result<(), ServerError> {
    let mut paths = BTreeMap::new();
    for entry in entries {
        if entry.resource_kind == "project_org_selection" {
            continue;
        }
        let path = entry.path.as_deref().ok_or_else(|| {
            ServerError::InvalidRequest(format!(
                "Commit Tree entry {} is missing a path",
                entry.item_id
            ))
        })?;
        validate_resource_path(&entry.resource_kind, path)?;
        let output_path = materialization_output_path(&entry.resource_kind, path)?;
        insert_materialization_path(&mut paths, &entry.item_id, &output_path, "Commit Tree")?;
    }
    Ok(())
}

async fn pending_resource_entry(
    tx: &mut Transaction<'_, Postgres>,
    row: &sqlx::postgres::PgRow,
    scope: &str,
    project_id: Option<&str>,
    source: &str,
) -> Result<PendingTreeEntry, ServerError> {
    let resource_id: String = row.try_get("resource_id")?;
    let body: String = row.try_get("body")?;
    let resource_kind: String = row.try_get("resource_kind")?;
    let path: String = row.try_get("path")?;
    validate_resource_path(&resource_kind, &path)?;
    let blob_content = match resource_kind.as_str() {
        "context" => body,
        "rule" => rule_blob_content(
            &row.try_get::<String, _>("name")?,
            &RuleContent {
                applies_when: row.try_get("applies_when")?,
                constraint: body,
                tags: row.try_get("tags")?,
            },
        )?,
        "workflow" => workflow_blob_content(
            &row.try_get::<String, _>("name")?,
            &WorkflowContent {
                description: body,
                steps: load_workflow_steps(tx, &resource_id).await?,
            },
        )?,
        other => {
            return Err(ServerError::InvalidRequest(format!(
                "unknown resource kind while creating Commit: {other}"
            )));
        }
    };
    Ok(PendingTreeEntry {
        item_id: resource_id,
        resource_kind,
        scope: scope.to_owned(),
        project_id: project_id.map(ToOwned::to_owned),
        path: Some(path),
        blob_id: store_blob(tx, &blob_content).await?,
        source: source.to_owned(),
    })
}

async fn pending_metaprompt_entry(
    tx: &mut Transaction<'_, Postgres>,
    row: &sqlx::postgres::PgRow,
    scope: &str,
    project_id: Option<&str>,
    source: &str,
) -> Result<PendingTreeEntry, ServerError> {
    let body: String = row.try_get("body")?;
    Ok(PendingTreeEntry {
        item_id: row.try_get("metaprompt_id")?,
        resource_kind: row.try_get("resource_kind")?,
        scope: scope.to_owned(),
        project_id: project_id.map(ToOwned::to_owned),
        path: Some(row.try_get("path")?),
        blob_id: store_blob(tx, &body).await?,
        source: source.to_owned(),
    })
}

async fn store_blob(
    tx: &mut Transaction<'_, Postgres>,
    content: &str,
) -> Result<String, ServerError> {
    let blob_id = object_id("blob", content.as_bytes());
    sqlx::query("INSERT INTO blobs (blob_id, content) VALUES ($1, $2) ON CONFLICT DO NOTHING")
        .bind(&blob_id)
        .bind(content)
        .execute(&mut **tx)
        .await?;
    Ok(blob_id)
}

async fn store_tree(
    tx: &mut Transaction<'_, Postgres>,
    entries: &[PendingTreeEntry],
) -> Result<String, ServerError> {
    let encoded = serde_json::to_vec(entries)
        .map_err(|error| ServerError::InvalidRequest(format!("failed to encode tree: {error}")))?;
    let tree_id = object_id("tree", &encoded);
    sqlx::query("INSERT INTO trees (tree_id) VALUES ($1) ON CONFLICT DO NOTHING")
        .bind(&tree_id)
        .execute(&mut **tx)
        .await?;
    for entry in entries {
        sqlx::query(
            "INSERT INTO tree_entries (
                tree_id, item_id, resource_kind, scope, project_id, path, blob_id, source
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT DO NOTHING",
        )
        .bind(&tree_id)
        .bind(&entry.item_id)
        .bind(&entry.resource_kind)
        .bind(&entry.scope)
        .bind(&entry.project_id)
        .bind(&entry.path)
        .bind(&entry.blob_id)
        .bind(&entry.source)
        .execute(&mut **tx)
        .await?;
    }
    Ok(tree_id)
}

async fn create_commit(
    tx: &mut Transaction<'_, Postgres>,
    scope: &str,
    org_id: &str,
    project_id: Option<&str>,
    tree_id: &str,
    parent_commit_id: Option<&str>,
    version: i64,
) -> Result<String, ServerError> {
    let created_at = OffsetDateTime::now_utc();
    let encoded = serde_json::to_vec(&(
        scope,
        org_id,
        project_id,
        tree_id,
        parent_commit_id,
        version,
        created_at.unix_timestamp_nanos(),
    ))
    .map_err(|error| ServerError::InvalidRequest(format!("failed to encode commit: {error}")))?;
    let commit_id = object_id("commit", &encoded);
    sqlx::query(
        "INSERT INTO commits (
            commit_id, scope, org_id, project_id, tree_id, parent_commit_id, version, created_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(&commit_id)
    .bind(scope)
    .bind(org_id)
    .bind(project_id)
    .bind(tree_id)
    .bind(parent_commit_id)
    .bind(version)
    .bind(created_at)
    .execute(&mut **tx)
    .await?;
    Ok(commit_id)
}

async fn load_commit_payload(
    tx: &mut Transaction<'_, Postgres>,
    commit_id: &str,
) -> Result<CommitPayload, ServerError> {
    let commit_row = sqlx::query(
        "SELECT commit_id, scope, org_id, project_id, tree_id, parent_commit_id, version, created_at
         FROM commits
         WHERE commit_id = $1",
    )
    .bind(commit_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("commit", commit_id))?;

    let tree_id: String = commit_row.try_get("tree_id")?;

    let item_rows = sqlx::query(
        "SELECT e.item_id, e.resource_kind, e.scope, e.project_id, e.path, e.blob_id,
                e.source, b.content
         FROM tree_entries e
         JOIN blobs b ON b.blob_id = e.blob_id
         WHERE e.tree_id = $1
         ORDER BY e.resource_kind, e.path NULLS LAST, e.item_id",
    )
    .bind(&tree_id)
    .fetch_all(&mut **tx)
    .await?;

    let mut tree_entries = Vec::with_capacity(item_rows.len());
    let mut blobs = BTreeMap::new();
    let mut project_org_selection = None;
    for row in item_rows {
        let kind = tree_entry_kind(row.try_get::<String, _>("resource_kind")?.as_str())?;
        let scope = tree_entry_scope(row.try_get::<String, _>("scope")?.as_str())?;
        let source = tree_entry_source(row.try_get::<String, _>("source")?.as_str())?;
        let id: String = row.try_get("item_id")?;
        let project_id: Option<String> = row.try_get("project_id")?;
        let path: Option<String> = row.try_get("path")?;
        let blob_id: String = row.try_get("blob_id")?;
        let content: String = row.try_get("content")?;
        tree_entries.push(TreeEntry {
            id,
            kind,
            scope,
            project_id,
            path,
            blob_id: blob_id.clone(),
            source,
        });
        if kind == TreeEntryKind::ProjectOrgSelection {
            project_org_selection = Some(serde_json::from_str(&content).map_err(|error| {
                ServerError::InvalidRequest(format!(
                    "commit project org selection is invalid: {error}"
                ))
            })?);
        }
        blobs
            .entry(blob_id.clone())
            .or_insert(Blob { blob_id, content });
    }

    let project_id: Option<String> = commit_row.try_get("project_id")?;
    if project_id.is_some() && project_org_selection.is_none() {
        return Err(ServerError::InvalidRequest(
            "project commit missing project org selection".to_owned(),
        ));
    }

    Ok(CommitPayload {
        commit: Commit {
            commit_id: commit_row.try_get("commit_id")?,
            scope: commit_scope(commit_row.try_get::<String, _>("scope")?.as_str())?,
            org_id: commit_row.try_get("org_id")?,
            project_id,
            tree_id: tree_id.clone(),
            parent_commit_id: commit_row.try_get("parent_commit_id")?,
            version: commit_row.try_get("version")?,
            created_at: commit_row.try_get("created_at")?,
        },
        tree: Tree {
            tree_id,
            entries: tree_entries,
        },
        blobs: blobs.into_values().collect(),
        project_org_selection,
    })
}

async fn load_project_org_selection(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<ProjectOrgSelection, ServerError> {
    let revision = sqlx::query_scalar::<_, i64>(
        "SELECT revision
         FROM project_org_selection_states
         WHERE project_id = $1",
    )
    .bind(project_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("project_org_selection", project_id))?;

    let rows = sqlx::query(
        "SELECT
            r.resource_id, r.resource_kind, r.scope, r.project_id, r.path, r.name,
            r.status, r.content_hash, r.context_kind, octet_length(r.body) AS size,
            r.updated_at
         FROM project_org_resource_selections s
         JOIN resources r ON r.resource_id = s.resource_id
         WHERE s.project_id = $1 AND r.status = 'active'
         ORDER BY r.resource_kind, r.path",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;

    let mut rules = Vec::new();
    let mut context = Vec::new();
    let mut workflows = Vec::new();
    for row in rows {
        let kind: String = row.try_get("resource_kind")?;
        match kind.as_str() {
            "rule" => rules.push(crate::api::RuleMeta {
                rule_id: row.try_get("resource_id")?,
                scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
                project_id: row.try_get("project_id")?,
                path: row.try_get("path")?,
                name: row.try_get("name")?,
                content_hash: row.try_get("content_hash")?,
                status: resource_status(row.try_get::<String, _>("status")?.as_str())?,
                updated_at: row.try_get("updated_at")?,
            }),
            "context" => context.push(crate::api::ContextMeta {
                context_id: row.try_get("resource_id")?,
                scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
                project_id: row.try_get("project_id")?,
                kind: context_kind(
                    row.try_get::<Option<String>, _>("context_kind")?
                        .as_deref()
                        .unwrap_or("file"),
                )?,
                path: row.try_get("path")?,
                content_hash: row.try_get("content_hash")?,
                size: row.try_get::<i32, _>("size")? as i64,
                updated_at: row.try_get("updated_at")?,
            }),
            "workflow" => workflows.push(crate::api::WorkflowMeta {
                workflow_id: row.try_get("resource_id")?,
                scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
                project_id: row.try_get("project_id")?,
                path: row.try_get("path")?,
                name: row.try_get("name")?,
                content_hash: row.try_get("content_hash")?,
                status: resource_status(row.try_get::<String, _>("status")?.as_str())?,
                updated_at: row.try_get("updated_at")?,
            }),
            other => {
                return Err(ServerError::InvalidRequest(format!(
                    "unknown selected resource kind: {other}"
                )));
            }
        }
    }

    Ok(ProjectOrgSelection {
        project_id: project_id.to_owned(),
        rules,
        context,
        workflows,
        revision,
    })
}

#[derive(Debug)]
struct TargetResource {
    resource_id: String,
    path: String,
    name: String,
    applies_when: String,
    tags: Vec<String>,
}

async fn load_target_resource(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    project_id: Option<&str>,
    resource: &DraftResourceRef,
) -> Result<TargetResource, ServerError> {
    let row = if let Some(id) = resource.id.as_deref() {
        sqlx::query(
            "SELECT resource_id, path, name, applies_when, tags
             FROM resources
             WHERE resource_id = $1 AND org_id = $2 AND scope = $3
               AND (($3 = 'org' AND project_id IS NULL) OR project_id = $4)
               AND resource_kind = $5
               AND status = 'active'
             FOR UPDATE",
        )
        .bind(id)
        .bind(org_id)
        .bind(resource.scope.as_str())
        .bind(project_id)
        .bind(resource.kind.as_str())
        .fetch_optional(&mut **tx)
        .await?
    } else if let Some(path) = resource.path.as_deref() {
        sqlx::query(
            "SELECT resource_id, path, name, applies_when, tags
             FROM resources
             WHERE org_id = $1 AND scope = $2
               AND (($2 = 'org' AND project_id IS NULL) OR project_id = $3)
               AND resource_kind = $4
               AND path = $5
               AND status = 'active'
             FOR UPDATE",
        )
        .bind(org_id)
        .bind(resource.scope.as_str())
        .bind(project_id)
        .bind(resource.kind.as_str())
        .bind(path)
        .fetch_optional(&mut **tx)
        .await?
    } else {
        return Err(ServerError::InvalidRequest(
            "operation target requires id or path".to_owned(),
        ));
    }
    .ok_or_else(|| ServerError::not_found("resource", resource.id.as_deref().unwrap_or("path")))?;

    Ok(TargetResource {
        resource_id: row.try_get("resource_id")?,
        path: row.try_get("path")?,
        name: row.try_get("name")?,
        applies_when: row.try_get("applies_when")?,
        tags: row.try_get("tags")?,
    })
}

async fn project_org_id(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<String, ServerError> {
    sqlx::query_scalar::<_, String>("SELECT org_id FROM projects WHERE project_id = $1")
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| ServerError::not_found("project", project_id))
}

async fn current_project_revision(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<i64, ServerError> {
    sqlx::query_scalar::<_, i64>("SELECT revision FROM projects WHERE project_id = $1 FOR UPDATE")
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| ServerError::not_found("project", project_id))
}

async fn current_project_ref(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<Option<String>, ServerError> {
    sqlx::query_scalar::<_, Option<String>>(
        "SELECT commit_id
         FROM refs
         WHERE scope = 'project' AND project_id = $1 AND ref_name = 'refs/heads/main'
         FOR UPDATE",
    )
    .bind(project_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("ref", project_id))
}

async fn advance_project_ref(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    commit_id: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "UPDATE refs
         SET commit_id = $2, updated_at = now()
         WHERE scope = 'project' AND project_id = $1 AND ref_name = 'refs/heads/main'",
    )
    .bind(project_id)
    .bind(commit_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn validate_project_commit(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    commit_id: &str,
) -> Result<(), ServerError> {
    let belongs_to_project = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
            SELECT 1
            FROM commits
            WHERE commit_id = $1 AND scope = 'project' AND project_id = $2
         )",
    )
    .bind(commit_id)
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?;
    if !belongs_to_project {
        return Err(ServerError::InvalidRequest(format!(
            "base commit {commit_id} does not belong to project {project_id}"
        )));
    }
    Ok(())
}

async fn validate_org_commit(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    commit_id: &str,
) -> Result<(), ServerError> {
    let belongs_to_org = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
            SELECT 1
            FROM commits
            WHERE commit_id = $1 AND scope = 'org' AND org_id = $2
         )",
    )
    .bind(commit_id)
    .bind(org_id)
    .fetch_one(&mut **tx)
    .await?;
    if !belongs_to_org {
        return Err(ServerError::InvalidRequest(format!(
            "base commit {commit_id} does not belong to organization {org_id}"
        )));
    }
    Ok(())
}

async fn insert_ref(
    tx: &mut Transaction<'_, Postgres>,
    scope: &str,
    org_id: &str,
    project_id: Option<&str>,
) -> Result<(), ServerError> {
    sqlx::query(
        "INSERT INTO refs (ref_id, ref_name, scope, org_id, project_id)
         VALUES ($1, 'refs/heads/main', $2, $3, $4)",
    )
    .bind(prefixed_id("ref"))
    .bind(scope)
    .bind(org_id)
    .bind(project_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn current_org_ref(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
) -> Result<Option<String>, ServerError> {
    sqlx::query_scalar::<_, Option<String>>(
        "SELECT commit_id
         FROM refs
         WHERE scope = 'org' AND org_id = $1 AND ref_name = 'refs/heads/main'
         FOR UPDATE",
    )
    .bind(org_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("ref", org_id))
}

async fn lock_org_ref_for_project_projection(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
) -> Result<(), ServerError> {
    sqlx::query_scalar::<_, String>(
        "SELECT ref_id
         FROM refs
         WHERE scope = 'org' AND org_id = $1 AND ref_name = 'refs/heads/main'
         FOR SHARE",
    )
    .bind(org_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("ref", org_id))?;
    Ok(())
}

async fn advance_org_ref(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    commit_id: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "UPDATE refs
         SET commit_id = $2, updated_at = now()
         WHERE scope = 'org' AND org_id = $1 AND ref_name = 'refs/heads/main'",
    )
    .bind(org_id)
    .bind(commit_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn load_project_ref(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<Ref, ServerError> {
    let row = sqlx::query(
        "SELECT ref_name, scope, org_id, project_id, commit_id, updated_at
         FROM refs
         WHERE scope = 'project' AND project_id = $1 AND ref_name = 'refs/heads/main'",
    )
    .bind(project_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("ref", project_id))?;
    ref_from_row(&row)
}

async fn load_org_ref(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
) -> Result<Ref, ServerError> {
    let row = sqlx::query(
        "SELECT ref_name, scope, org_id, project_id, commit_id, updated_at
         FROM refs
         WHERE scope = 'org' AND org_id = $1 AND ref_name = 'refs/heads/main'",
    )
    .bind(org_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("ref", org_id))?;
    ref_from_row(&row)
}

fn ref_from_row(row: &sqlx::postgres::PgRow) -> Result<Ref, ServerError> {
    Ok(Ref {
        name: row.try_get("ref_name")?,
        scope: commit_scope(row.try_get::<String, _>("scope")?.as_str())?,
        org_id: row.try_get("org_id")?,
        project_id: row.try_get("project_id")?,
        commit_id: row.try_get("commit_id")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn user_ref(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<UserRef, ServerError> {
    let row = sqlx::query(
        "SELECT user_id, email, display_name, avatar_url, role
         FROM users
         WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("user", user_id))?;
    user_ref_from_row(&row)
}

fn user_ref_from_row(row: &sqlx::postgres::PgRow) -> Result<UserRef, ServerError> {
    Ok(UserRef {
        user_id: row.try_get("user_id")?,
        email: row.try_get("email")?,
        display_name: row.try_get("display_name")?,
        avatar_url: row.try_get("avatar_url")?,
        role: row.try_get("role")?,
    })
}

async fn ensure_project_in_org(
    pool: &PgPool,
    org_id: &str,
    project_id: &str,
) -> Result<(), ServerError> {
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM projects WHERE project_id = $1 AND org_id = $2)",
    )
    .bind(project_id)
    .bind(org_id)
    .fetch_one(pool)
    .await?;
    if exists {
        Ok(())
    } else {
        Err(ServerError::not_found("project", project_id))
    }
}

async fn ensure_project_in_org_tx(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    project_id: &str,
) -> Result<(), ServerError> {
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM projects WHERE project_id = $1 AND org_id = $2)",
    )
    .bind(project_id)
    .bind(org_id)
    .fetch_one(&mut **tx)
    .await?;
    if exists {
        Ok(())
    } else {
        Err(ServerError::not_found("project", project_id))
    }
}

async fn load_project_member(
    pool: &PgPool,
    org_id: &str,
    project_id: &str,
    user_id: &str,
) -> Result<ProjectMember, ServerError> {
    let row = sqlx::query(
        "SELECT p.project_id, u.user_id, u.email, u.display_name, u.avatar_url,
                u.role AS org_role, m.role AS project_role, m.joined_at
         FROM project_members m
         JOIN projects p ON p.project_id = m.project_id
         JOIN users u ON u.user_id = m.user_id
         WHERE p.project_id = $1 AND p.org_id = $2 AND u.user_id = $3",
    )
    .bind(project_id)
    .bind(org_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| ServerError::not_found("project_member", format!("{project_id}:{user_id}")))?;
    project_member_from_row(&row)
}

fn project_member_from_row(row: &sqlx::postgres::PgRow) -> Result<ProjectMember, ServerError> {
    Ok(ProjectMember {
        project_id: row.try_get("project_id")?,
        user: UserRef {
            user_id: row.try_get("user_id")?,
            email: row.try_get("email")?,
            display_name: row.try_get("display_name")?,
            avatar_url: row.try_get("avatar_url")?,
            role: row.try_get("org_role")?,
        },
        role: project_role(row.try_get::<String, _>("project_role")?.as_str())?,
        joined_at: row.try_get("joined_at")?,
    })
}

fn admin_org_from_row(row: &sqlx::postgres::PgRow) -> Result<AdminOrg, ServerError> {
    Ok(AdminOrg {
        org_id: row.try_get("org_id")?,
        name: row.try_get("name")?,
        allowed_email_domains: row.try_get("allowed_email_domains")?,
        revision: row.try_get("revision")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn load_member(pool: &PgPool, user_id: &str) -> Result<Member, ServerError> {
    let row = sqlx::query(
        "SELECT u.user_id, u.email, u.display_name, u.role, u.status, u.revision,
                EXISTS (
                    SELECT 1 FROM external_identities i WHERE i.user_id = u.user_id
                ) AS external_identity_bound
         FROM users u WHERE u.user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| ServerError::not_found("user", user_id))?;
    member_from_row(&row)
}

fn member_from_row(row: &sqlx::postgres::PgRow) -> Result<Member, ServerError> {
    Ok(Member {
        user_id: row.try_get("user_id")?,
        email: row.try_get("email")?,
        display_name: row.try_get("display_name")?,
        role: org_role(row.try_get::<String, _>("role")?.as_str())?,
        status: member_status(row.try_get::<String, _>("status")?.as_str())?,
        external_identity_bound: row.try_get("external_identity_bound")?,
        revision: row.try_get("revision")?,
    })
}

fn access_token_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<AccessTokenMeta, ServerError> {
    Ok(AccessTokenMeta {
        token_id: row.try_get("token_id")?,
        user_id: row.try_get("user_id")?,
        kind: access_token_kind(row.try_get::<String, _>("kind")?.as_str())?,
        revoked: row
            .try_get::<Option<OffsetDateTime>, _>("revoked_at")?
            .is_some(),
        expires_at: row.try_get("expires_at")?,
        created_at: row.try_get("created_at")?,
    })
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

async fn ensure_active_owner_remains(
    tx: &mut Transaction<'_, Postgres>,
    current_role: &str,
    current_status: &str,
    next_role: &str,
    next_status: &str,
) -> Result<(), ServerError> {
    let removes_active_owner = current_role == "owner"
        && current_status == "active"
        && (next_role != "owner" || next_status != "active");
    if !removes_active_owner {
        return Ok(());
    }
    let active_owner_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM users WHERE role = 'owner' AND status = 'active'",
    )
    .fetch_one(&mut **tx)
    .await?;
    if active_owner_count <= 1 {
        Err(ServerError::InvalidRequest(
            "the last active organization owner cannot be disabled or demoted".to_owned(),
        ))
    } else {
        Ok(())
    }
}

async fn revoke_user_sessions(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    user_id: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "UPDATE access_tokens t SET revoked_at = now()
         FROM auth_sessions s
         WHERE t.session_id = s.session_id AND s.org_id = $1 AND s.user_id = $2",
    )
    .bind(org_id)
    .bind(user_id)
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "UPDATE auth_sessions SET revoked_at = now()
         WHERE org_id = $1 AND user_id = $2",
    )
    .bind(org_id)
    .bind(user_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn insert_repository_audit_event(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    actor_user_id: Option<&str>,
    action: &str,
    target_type: &str,
    target_id: Option<&str>,
) -> Result<(), ServerError> {
    sqlx::query(
        "INSERT INTO audit_events (
            event_id, org_id, actor_user_id, action, target_type, target_id
         ) VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(prefixed_id("evt"))
    .bind(org_id)
    .bind(actor_user_id)
    .bind(action)
    .bind(target_type)
    .bind(target_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn ensure_bundle_owner(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    owner_user_id: &str,
) -> Result<(), ServerError> {
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
            SELECT 1 FROM personal_bundles
            WHERE bundle_id = $1 AND owner_user_id = $2
         )",
    )
    .bind(bundle_id)
    .bind(owner_user_id)
    .fetch_one(&mut **tx)
    .await?;
    if exists {
        Ok(())
    } else {
        Err(ServerError::not_found("bundle", bundle_id))
    }
}

fn principal_capabilities(role: &str) -> Vec<String> {
    let mut capabilities = vec![
        "memory:read".to_owned(),
        "draft:write".to_owned(),
        "review:write".to_owned(),
    ];
    if role == "owner" || role == "admin" {
        capabilities.push("review:merge".to_owned());
        capabilities.push("admin:write".to_owned());
    }
    capabilities
}

fn prefixed_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

fn content_hash(body: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(body.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[derive(serde::Serialize)]
struct StructuredBlob<'a, T> {
    format: &'static str,
    content: &'a T,
}

#[derive(serde::Serialize)]
struct RuleBlobContent<'a> {
    name: &'a str,
    applies_when: &'a str,
    constraint: &'a str,
    tags: &'a [String],
}

#[derive(serde::Serialize)]
struct WorkflowBlobContent<'a> {
    name: &'a str,
    description: &'a str,
    steps: &'a [WorkflowStep],
}

fn rule_blob_content(name: &str, content: &RuleContent) -> Result<String, ServerError> {
    structured_blob_content(
        "clumsies.rule.v1",
        &RuleBlobContent {
            name,
            applies_when: &content.applies_when,
            constraint: &content.constraint,
            tags: &content.tags,
        },
    )
}

fn workflow_blob_content(name: &str, content: &WorkflowContent) -> Result<String, ServerError> {
    structured_blob_content(
        "clumsies.workflow.v1",
        &WorkflowBlobContent {
            name,
            description: &content.description,
            steps: &content.steps,
        },
    )
}

fn structured_blob_content<T: serde::Serialize>(
    format: &'static str,
    content: &T,
) -> Result<String, ServerError> {
    serde_json::to_string(&StructuredBlob { format, content }).map_err(|error| {
        ServerError::InvalidRequest(format!("failed to encode {format} Blob: {error}"))
    })
}

fn object_id(kind: &str, content: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(kind.as_bytes());
    hasher.update([0]);
    hasher.update(content);
    hex::encode(hasher.finalize())
}

fn name_from_path(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_owned()
}

fn context_kind_for(kind: DraftResourceKind) -> Option<&'static str> {
    match kind {
        DraftResourceKind::Context => Some("file"),
        DraftResourceKind::Rule | DraftResourceKind::Workflow | DraftResourceKind::Metaprompt => {
            None
        }
    }
}

fn draft_resource_kind(value: &str) -> Result<DraftResourceKind, ServerError> {
    match value {
        "context" => Ok(DraftResourceKind::Context),
        "rule" => Ok(DraftResourceKind::Rule),
        "workflow" => Ok(DraftResourceKind::Workflow),
        "metaprompt" => Ok(DraftResourceKind::Metaprompt),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown resource kind: {other}"
        ))),
    }
}

fn resource_scope(value: &str) -> Result<crate::api::ResourceScope, ServerError> {
    match value {
        "org" => Ok(crate::api::ResourceScope::Org),
        "project" => Ok(crate::api::ResourceScope::Project),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown resource scope: {other}"
        ))),
    }
}

fn resource_status(value: &str) -> Result<crate::api::ResourceStatus, ServerError> {
    match value {
        "active" => Ok(crate::api::ResourceStatus::Active),
        "deprecated" => Ok(crate::api::ResourceStatus::Deprecated),
        "archived" => Ok(crate::api::ResourceStatus::Archived),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown resource status: {other}"
        ))),
    }
}

fn context_kind(value: &str) -> Result<crate::api::ContextKind, ServerError> {
    match value {
        "file" => Ok(crate::api::ContextKind::File),
        "note" => Ok(crate::api::ContextKind::Note),
        "decision" => Ok(crate::api::ContextKind::Decision),
        "reference" => Ok(crate::api::ContextKind::Reference),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown context kind: {other}"
        ))),
    }
}

fn draft_operation_action(value: &str) -> Result<DraftOperationAction, ServerError> {
    match value {
        "create" => Ok(DraftOperationAction::Create),
        "update" => Ok(DraftOperationAction::Update),
        "rename" => Ok(DraftOperationAction::Rename),
        "delete" => Ok(DraftOperationAction::Delete),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown draft operation action: {other}"
        ))),
    }
}

fn draft_status(value: &str) -> Result<DraftStatus, ServerError> {
    match value {
        "open" => Ok(DraftStatus::Open),
        "submitted" => Ok(DraftStatus::Submitted),
        "discarded" => Ok(DraftStatus::Discarded),
        "conflicted" => Ok(DraftStatus::Conflicted),
        "merged" => Ok(DraftStatus::Merged),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown draft status: {other}"
        ))),
    }
}

fn draft_event_type(value: &str) -> Result<DraftEventType, ServerError> {
    match value {
        "created" => Ok(DraftEventType::Created),
        "updated" => Ok(DraftEventType::Updated),
        "operation_appended" => Ok(DraftEventType::OperationAppended),
        "discarded" => Ok(DraftEventType::Discarded),
        "submitted" => Ok(DraftEventType::Submitted),
        "reopened" => Ok(DraftEventType::Reopened),
        "conflicted" => Ok(DraftEventType::Conflicted),
        "merged" => Ok(DraftEventType::Merged),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown draft event type: {other}"
        ))),
    }
}

fn review_status(value: &str) -> Result<ReviewStatus, ServerError> {
    match value {
        "open" => Ok(ReviewStatus::Open),
        "approved" => Ok(ReviewStatus::Approved),
        "rejected" => Ok(ReviewStatus::Rejected),
        "merged" => Ok(ReviewStatus::Merged),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown review status: {other}"
        ))),
    }
}

fn commit_scope(value: &str) -> Result<CommitScope, ServerError> {
    match value {
        "org" => Ok(CommitScope::Org),
        "project" => Ok(CommitScope::Project),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown commit scope: {other}"
        ))),
    }
}

fn org_role(value: &str) -> Result<OrgRole, ServerError> {
    match value {
        "owner" => Ok(OrgRole::Owner),
        "admin" => Ok(OrgRole::Admin),
        "member" => Ok(OrgRole::Member),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown organization role: {other}"
        ))),
    }
}

fn project_role(value: &str) -> Result<ProjectRole, ServerError> {
    match value {
        "admin" => Ok(ProjectRole::Admin),
        "member" => Ok(ProjectRole::Member),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown project role: {other}"
        ))),
    }
}

fn member_status(value: &str) -> Result<MemberStatus, ServerError> {
    match value {
        "invited" => Ok(MemberStatus::Invited),
        "active" => Ok(MemberStatus::Active),
        "disabled" => Ok(MemberStatus::Disabled),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown member status: {other}"
        ))),
    }
}

fn access_token_kind(value: &str) -> Result<AccessTokenKind, ServerError> {
    match value {
        "access" => Ok(AccessTokenKind::Access),
        "refresh" => Ok(AccessTokenKind::Refresh),
        "integration" => Ok(AccessTokenKind::Integration),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown access token kind: {other}"
        ))),
    }
}

fn tree_entry_kind(value: &str) -> Result<TreeEntryKind, ServerError> {
    match value {
        "rule" => Ok(TreeEntryKind::Rule),
        "context" => Ok(TreeEntryKind::Context),
        "workflow" => Ok(TreeEntryKind::Workflow),
        "metaprompt" => Ok(TreeEntryKind::Metaprompt),
        "project_org_selection" => Ok(TreeEntryKind::ProjectOrgSelection),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown tree entry kind: {other}"
        ))),
    }
}

fn tree_entry_scope(value: &str) -> Result<TreeEntryScope, ServerError> {
    match value {
        "org" => Ok(TreeEntryScope::Org),
        "project" => Ok(TreeEntryScope::Project),
        "daemon" => Ok(TreeEntryScope::Daemon),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown tree entry scope: {other}"
        ))),
    }
}

fn tree_entry_source(value: &str) -> Result<TreeEntrySource, ServerError> {
    match value {
        "org" => Ok(TreeEntrySource::Org),
        "project" => Ok(TreeEntrySource::Project),
        "selected_org" => Ok(TreeEntrySource::SelectedOrg),
        "bootstrap" => Ok(TreeEntrySource::Bootstrap),
        "config" => Ok(TreeEntrySource::Config),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown tree entry source: {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending_context_entry(id: &str, path: &str) -> PendingTreeEntry {
        PendingTreeEntry {
            item_id: id.to_owned(),
            resource_kind: "context".to_owned(),
            scope: "project".to_owned(),
            project_id: Some("prj_test".to_owned()),
            path: Some(path.to_owned()),
            blob_id: format!("blob_{id}"),
            source: "project".to_owned(),
        }
    }

    #[test]
    fn rule_constraint_must_not_be_blank() {
        assert!(validate_rule_constraint("").is_err());
        assert!(validate_rule_constraint("  \n").is_err());
        assert!(validate_rule_constraint("Run focused tests.").is_ok());
    }

    #[test]
    fn workflow_steps_require_non_empty_exclusive_content() {
        assert!(validate_workflow_step_shapes(&[]).is_err());
        assert!(
            validate_workflow_step_shapes(&[WorkflowStepInput {
                rule_id: None,
                body: None,
            }])
            .is_err()
        );
        assert!(
            validate_workflow_step_shapes(&[WorkflowStepInput {
                rule_id: Some("rule-one".to_owned()),
                body: Some("duplicate".to_owned()),
            }])
            .is_err()
        );
        assert!(
            validate_workflow_step_shapes(&[WorkflowStepInput {
                rule_id: Some("rule-one".to_owned()),
                body: None,
            }])
            .is_ok()
        );
        assert!(
            validate_workflow_step_shapes(&[WorkflowStepInput {
                rule_id: None,
                body: Some("Run the step.".to_owned()),
            }])
            .is_ok()
        );
    }

    #[test]
    fn resource_paths_follow_the_portable_file_contract() {
        assert!(validate_resource_path("context", "spec/API.md").is_ok());
        assert!(validate_resource_path("workflow", "workflow/CODING").is_ok());
        assert!(validate_resource_path("metaprompt", "META_PROMPT.md").is_ok());

        for path in [
            "../outside.md",
            "spec//API.md",
            "spec/AUX.md",
            "spec/API.md ",
            "spec/API\\draft.md",
        ] {
            assert!(
                validate_resource_path("context", path).is_err(),
                "path should be rejected: {path}"
            );
        }
        assert!(validate_resource_path("rule", "Workflow/CODING").is_err());
        assert!(validate_resource_path("workflow", "workflows/CODING").is_err());
    }

    #[test]
    fn commit_trees_reject_case_and_file_directory_collisions() {
        assert!(
            validate_tree_materialization_paths(&[
                pending_context_entry("one", "spec/API.md"),
                pending_context_entry("two", "spec/api.md"),
            ])
            .is_err()
        );
        assert!(
            validate_tree_materialization_paths(&[
                pending_context_entry("one", "spec/API.md"),
                pending_context_entry("two", "spec/API.md/examples.md"),
            ])
            .is_err()
        );
        assert!(
            validate_tree_materialization_paths(&[
                pending_context_entry("one", "spec/API.md/examples.md"),
                pending_context_entry("two", "spec/API.md"),
            ])
            .is_err()
        );
        assert!(
            validate_tree_materialization_paths(&[
                pending_context_entry("one", "spec/API.md"),
                pending_context_entry("two", "spec/CLI.md"),
            ])
            .is_ok()
        );
    }
}
