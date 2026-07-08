use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use thiserror::Error;
use uuid::Uuid;

use crate::api::{
    AuthProvider, ContextDetail, ContextListResponse, ContextMeta, CreateDraftRequest,
    CreateProjectRequest, CreateReviewDecisionRequest, CreateReviewMergeRequest,
    CreateReviewRequest, DeleteResult, Draft, DraftDetail, DraftEvent, DraftEventListResponse,
    DraftEventType, DraftListResponse, DraftOperation, DraftOperationAction,
    DraftOperationBatchRequest, DraftOperationBatchResponse, DraftOperationInput,
    DraftResourceKind, DraftResourceRef, DraftStatus, DraftSyncState, DraftSyncStatus,
    MetapromptDetail, MetapromptMeta, PageInfo, PersonalBundleDetail, PersonalBundleListResponse,
    PersonalBundleMeta, PersonalBundleRequest, PersonalBundleUpdateRequest, Project,
    ProjectListResponse, ProjectOrgSelection, ReplaceProjectOrgSelectionRequest, Review,
    ReviewDecision, ReviewDetail, ReviewMergeResult, ReviewStatus, RuleDetail, RuleListResponse,
    RuleMeta, SnapshotContentItem, SnapshotItemKind, SnapshotItemScope, SnapshotListResponse,
    SnapshotManifest, SnapshotManifestItem, SnapshotPayload, SnapshotScope, SnapshotSource,
    UpdateDraftRequest, UpdateProjectRequest, UserRef, WorkflowDetail, WorkflowListResponse,
    WorkflowMeta, WorkflowStep,
};

#[derive(Clone)]
pub struct HubRepository {
    pool: PgPool,
}

impl HubRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn create_org(&self, name: &str) -> Result<String, HubError> {
        let org_id = prefixed_id("org");
        sqlx::query("INSERT INTO orgs (org_id, name) VALUES ($1, $2)")
            .bind(&org_id)
            .bind(name)
            .execute(&self.pool)
            .await?;
        Ok(org_id)
    }

    pub async fn create_user(
        &self,
        email: &str,
        display_name: Option<&str>,
        role: &str,
    ) -> Result<String, HubError> {
        let user_id = prefixed_id("usr");
        sqlx::query(
            "INSERT INTO users (user_id, email, display_name, role)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(&user_id)
        .bind(email)
        .bind(display_name)
        .bind(role)
        .execute(&self.pool)
        .await?;
        Ok(user_id)
    }

    pub async fn create_project(
        &self,
        org_id: &str,
        name: &str,
        description: &str,
    ) -> Result<String, HubError> {
        let project_id = prefixed_id("prj");
        sqlx::query(
            "INSERT INTO projects (project_id, org_id, name, description)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(&project_id)
        .bind(org_id)
        .bind(name)
        .bind(description)
        .execute(&self.pool)
        .await?;
        Ok(project_id)
    }

    pub async fn create_project_from_request(
        &self,
        request: CreateProjectRequest,
    ) -> Result<Project, HubError> {
        let project_id = self
            .create_project(
                &request.org_id,
                &request.name,
                request.description.as_deref().unwrap_or_default(),
            )
            .await?;
        self.get_project(&project_id).await
    }

    pub async fn list_projects(&self) -> Result<ProjectListResponse, HubError> {
        let rows = sqlx::query(
            "SELECT project_id, name, description, revision, created_at, updated_at
             FROM projects
             ORDER BY updated_at DESC
             LIMIT 200",
        )
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

    pub async fn get_project(&self, project_id: &str) -> Result<Project, HubError> {
        let row = sqlx::query(
            "SELECT project_id, name, description, revision, created_at, updated_at
             FROM projects
             WHERE project_id = $1",
        )
        .bind(project_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| HubError::not_found("project", project_id))?;
        project_from_row(&row)
    }

    pub async fn update_project(
        &self,
        project_id: &str,
        expected_version: i64,
        request: UpdateProjectRequest,
    ) -> Result<Project, HubError> {
        let mut tx = self.pool.begin().await?;
        let current = current_project_revision(&mut tx, project_id).await?;
        if current != expected_version {
            return Err(HubError::version_conflict(
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
    ) -> Result<DeleteResult, HubError> {
        let mut tx = self.pool.begin().await?;
        let current = current_project_revision(&mut tx, project_id).await?;
        if current != expected_version {
            return Err(HubError::version_conflict(
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

    pub async fn create_org_resource(
        &self,
        org_id: &str,
        kind: DraftResourceKind,
        path: &str,
        body: &str,
    ) -> Result<String, HubError> {
        if kind == DraftResourceKind::Metaprompt {
            return Err(HubError::InvalidRequest(
                "metaprompt is not stored in resources".to_owned(),
            ));
        }
        let resource_id = prefixed_id(kind.resource_id_prefix());
        sqlx::query(
            "INSERT INTO resources (
                resource_id, org_id, project_id, scope, resource_kind, path, name,
                status, revision, content_hash, body, context_kind
             )
             VALUES ($1, $2, NULL, 'org', $3, $4, $5, 'active', 1, $6, $7, $8)",
        )
        .bind(&resource_id)
        .bind(org_id)
        .bind(kind.as_str())
        .bind(path)
        .bind(name_from_path(path))
        .bind(content_hash(body))
        .bind(body)
        .bind(context_kind_for(kind))
        .execute(&self.pool)
        .await?;
        Ok(resource_id)
    }

    pub async fn select_org_resource_for_project(
        &self,
        project_id: &str,
        resource_id: &str,
    ) -> Result<(), HubError> {
        sqlx::query(
            "INSERT INTO project_org_resource_selections (project_id, resource_id)
             VALUES ($1, $2)
             ON CONFLICT (project_id, resource_id)
             DO UPDATE SET revision = project_org_resource_selections.revision + 1,
                           updated_at = now()",
        )
        .bind(project_id)
        .bind(resource_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn replace_project_org_selection(
        &self,
        project_id: &str,
        expected_revision: i64,
        request: ReplaceProjectOrgSelectionRequest,
    ) -> Result<ProjectOrgSelection, HubError> {
        let mut tx = self.pool.begin().await?;
        project_org_id(&mut tx, project_id).await?;
        let current_revision = current_project_org_selection_revision(&mut tx, project_id).await?;
        if current_revision != expected_revision {
            return Err(HubError::version_conflict(
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
            "rule",
            next_revision,
            &request.rule_ids,
        )
        .await?;
        insert_project_org_selection_items(
            &mut tx,
            project_id,
            "context",
            next_revision,
            &request.context_ids,
        )
        .await?;
        insert_project_org_selection_items(
            &mut tx,
            project_id,
            "workflow",
            next_revision,
            &request.workflow_ids,
        )
        .await?;
        let selection = load_project_org_selection(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(selection)
    }

    pub async fn create_personal_bundle(
        &self,
        request: PersonalBundleRequest,
    ) -> Result<PersonalBundleDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        user_ref(&mut tx, &request.owner_user_id).await?;
        let bundle_id = prefixed_id("bdl");
        sqlx::query(
            "INSERT INTO personal_bundles (
                bundle_id, owner_user_id, name, description, revision
             )
             VALUES ($1, $2, $3, $4, 1)",
        )
        .bind(&bundle_id)
        .bind(&request.owner_user_id)
        .bind(&request.name)
        .bind(request.description.as_deref().unwrap_or_default())
        .execute(&mut *tx)
        .await?;
        insert_bundle_items(&mut tx, &bundle_id, "rule", &request.rule_ids).await?;
        insert_bundle_items(&mut tx, &bundle_id, "context", &request.context_ids).await?;
        insert_bundle_items(&mut tx, &bundle_id, "workflow", &request.workflow_ids).await?;
        tx.commit().await?;
        self.get_personal_bundle(&bundle_id).await
    }

    pub async fn list_personal_bundles(&self) -> Result<PersonalBundleListResponse, HubError> {
        let rows = sqlx::query(
            "SELECT
                b.bundle_id, b.owner_user_id, b.name, b.description, b.revision,
                b.created_at, b.updated_at,
                count(*) FILTER (WHERE i.resource_kind = 'rule') AS rule_count,
                count(*) FILTER (WHERE i.resource_kind = 'context') AS context_count,
                count(*) FILTER (WHERE i.resource_kind = 'workflow') AS workflow_count
             FROM personal_bundles b
             LEFT JOIN personal_bundle_items i ON i.bundle_id = b.bundle_id
             GROUP BY b.bundle_id
             ORDER BY b.updated_at DESC
             LIMIT 50",
        )
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
        bundle_id: &str,
    ) -> Result<PersonalBundleDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_personal_bundle_detail(&mut tx, bundle_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn update_personal_bundle(
        &self,
        bundle_id: &str,
        expected_revision: i64,
        request: PersonalBundleUpdateRequest,
    ) -> Result<PersonalBundleDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT name, description, revision
             FROM personal_bundles
             WHERE bundle_id = $1
             FOR UPDATE",
        )
        .bind(bundle_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| HubError::not_found("bundle", bundle_id))?;
        let current_revision: i64 = row.try_get("revision")?;
        if current_revision != expected_revision {
            return Err(HubError::version_conflict(
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
        bundle_id: &str,
        expected_revision: i64,
    ) -> Result<DeleteResult, HubError> {
        let mut tx = self.pool.begin().await?;
        let current_revision = sqlx::query_scalar::<_, i64>(
            "SELECT revision
             FROM personal_bundles
             WHERE bundle_id = $1
             FOR UPDATE",
        )
        .bind(bundle_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| HubError::not_found("bundle", bundle_id))?;
        if current_revision != expected_revision {
            return Err(HubError::version_conflict(
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

    pub async fn list_org_rules(&self) -> Result<RuleListResponse, HubError> {
        Ok(RuleListResponse {
            items: list_rule_meta(&self.pool, "org", None).await?,
            page_info: page_info(),
        })
    }

    pub async fn list_project_rules(&self, project_id: &str) -> Result<RuleListResponse, HubError> {
        Ok(RuleListResponse {
            items: list_rule_meta(&self.pool, "project", Some(project_id)).await?,
            page_info: page_info(),
        })
    }

    pub async fn get_org_rule(&self, rule_id: &str) -> Result<RuleDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_rule_detail(&mut tx, rule_id, "org", None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_rule(
        &self,
        project_id: &str,
        rule_id: &str,
    ) -> Result<RuleDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_rule_detail(&mut tx, rule_id, "project", Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_org_context(&self) -> Result<ContextListResponse, HubError> {
        Ok(ContextListResponse {
            items: list_context_meta(&self.pool, "org", None).await?,
            page_info: page_info(),
        })
    }

    pub async fn list_project_context(
        &self,
        project_id: &str,
    ) -> Result<ContextListResponse, HubError> {
        Ok(ContextListResponse {
            items: list_context_meta(&self.pool, "project", Some(project_id)).await?,
            page_info: page_info(),
        })
    }

    pub async fn get_org_context(&self, context_id: &str) -> Result<ContextDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_context_detail(&mut tx, context_id, "org", None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_context(
        &self,
        project_id: &str,
        context_id: &str,
    ) -> Result<ContextDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_context_detail(&mut tx, context_id, "project", Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_org_workflows(&self) -> Result<WorkflowListResponse, HubError> {
        Ok(WorkflowListResponse {
            items: list_workflow_meta(&self.pool, "org", None).await?,
            page_info: page_info(),
        })
    }

    pub async fn list_project_workflows(
        &self,
        project_id: &str,
    ) -> Result<WorkflowListResponse, HubError> {
        Ok(WorkflowListResponse {
            items: list_workflow_meta(&self.pool, "project", Some(project_id)).await?,
            page_info: page_info(),
        })
    }

    pub async fn get_org_workflow(&self, workflow_id: &str) -> Result<WorkflowDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_workflow_detail(&mut tx, workflow_id, "org", None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_workflow(
        &self,
        project_id: &str,
        workflow_id: &str,
    ) -> Result<WorkflowDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail =
            load_workflow_detail(&mut tx, workflow_id, "project", Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_org_metaprompt(&self) -> Result<MetapromptDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_metaprompt_detail(&mut tx, "org", None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_metaprompt(
        &self,
        project_id: &str,
    ) -> Result<MetapromptDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let detail = load_metaprompt_detail(&mut tx, "project", Some(project_id)).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_org_selection(
        &self,
        project_id: &str,
    ) -> Result<ProjectOrgSelection, HubError> {
        let mut tx = self.pool.begin().await?;
        let selection = load_project_org_selection(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(selection)
    }

    pub async fn create_draft(&self, request: CreateDraftRequest) -> Result<DraftDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        project_org_id(&mut tx, &request.project_id).await?;
        user_ref(&mut tx, &request.author_user_id).await?;

        let draft_id = prefixed_id("drf");
        sqlx::query(
            "INSERT INTO drafts (
                draft_id, project_id, author_user_id, title, description,
                resource_kind, target_id, path, status, version, daemon_installation_id
             )
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'open', 1, $9)",
        )
        .bind(&draft_id)
        .bind(&request.project_id)
        .bind(&request.author_user_id)
        .bind(&request.title)
        .bind(request.description.as_deref().unwrap_or_default())
        .bind(request.resource.kind.as_str())
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
        project_id: Option<&str>,
    ) -> Result<DraftListResponse, HubError> {
        let rows = if let Some(project_id) = project_id {
            sqlx::query(
                "SELECT draft_id
                 FROM drafts
                 WHERE project_id = $1
                 ORDER BY updated_at DESC
                 LIMIT 100",
            )
            .bind(project_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                "SELECT draft_id
                 FROM drafts
                 ORDER BY updated_at DESC
                 LIMIT 100",
            )
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

    pub async fn get_draft(&self, draft_id: &str) -> Result<DraftDetail, HubError> {
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
    ) -> Result<DraftDetail, HubError> {
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
    ) -> Result<DraftDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT title, description, status, version, project_id, daemon_installation_id
             FROM drafts
             WHERE draft_id = $1
             FOR UPDATE",
        )
        .bind(draft_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| HubError::not_found("draft", draft_id))?;
        let current_version: i64 = row.try_get("version")?;
        if current_version != expected_draft_version {
            return Err(HubError::version_conflict(
                "draft",
                expected_draft_version,
                current_version,
            ));
        }
        let status = row.try_get::<String, _>("status")?;
        if status != "open" && status != "conflicted" {
            return Err(HubError::invalid_transition("draft", &status, "updated"));
        }
        let next_status = match request.status {
            Some(DraftStatus::Open) => "open",
            Some(DraftStatus::Conflicted) => "conflicted",
            Some(DraftStatus::Discarded) => "discarded",
            Some(DraftStatus::Submitted) => {
                return Err(HubError::InvalidRequest(
                    "draft submission must use review creation".to_owned(),
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
             RETURNING project_id, version, daemon_installation_id",
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
            updated
                .try_get::<Option<String>, _>("daemon_installation_id")?
                .as_deref(),
        )
        .await?;
        tx.commit().await?;
        self.get_draft(draft_id).await
    }

    pub async fn discard_draft(
        &self,
        draft_id: &str,
        expected_draft_version: i64,
    ) -> Result<DeleteResult, HubError> {
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
    ) -> Result<DraftOperationBatchResponse, HubError> {
        if request.operations.is_empty() {
            return Err(HubError::InvalidRequest(
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
        after_cursor: Option<&str>,
    ) -> Result<DraftEventListResponse, HubError> {
        let rows = if let Some(after_cursor) = after_cursor {
            let after_sequence = after_cursor
                .parse::<i64>()
                .map_err(|_| HubError::InvalidRequest("invalid draft event cursor".to_owned()))?;
            sqlx::query(
                "SELECT server_sequence, event_id, draft_id, project_id, event_type, version,
                        daemon_installation_id, created_at
                 FROM draft_events
                 WHERE server_sequence > $1
                 ORDER BY server_sequence
                 LIMIT 100",
            )
            .bind(after_sequence)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                "SELECT server_sequence, event_id, draft_id, project_id, event_type, version,
                        daemon_installation_id, created_at
                 FROM draft_events
                 ORDER BY server_sequence
                 LIMIT 100",
            )
            .fetch_all(&self.pool)
            .await?
        };
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
            has_more: false,
            events,
        })
    }

    pub async fn create_review(&self, request: CreateReviewRequest) -> Result<Review, HubError> {
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
        .ok_or_else(|| HubError::not_found("draft", &request.draft_id))?;

        let status: String = row.try_get("status")?;
        let version: i64 = row.try_get("version")?;
        if status != "open" {
            return Err(HubError::invalid_transition("draft", &status, "submitted"));
        }
        if version != request.expected_draft_version {
            return Err(HubError::version_conflict(
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
             RETURNING project_id, version, daemon_installation_id",
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
            draft_event_row
                .try_get::<Option<String>, _>("daemon_installation_id")?
                .as_deref(),
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

        tx.commit().await?;
        self.get_review(&review_id).await
    }

    pub async fn get_review(&self, review_id: &str) -> Result<Review, HubError> {
        let mut tx = self.pool.begin().await?;
        let review = load_review(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(review)
    }

    pub async fn get_review_detail(&self, review_id: &str) -> Result<ReviewDetail, HubError> {
        let mut tx = self.pool.begin().await?;
        let review = load_review(&mut tx, review_id).await?;
        let draft = load_draft_detail(&mut tx, &review.draft_id).await?;
        tx.commit().await?;
        Ok(ReviewDetail {
            review,
            draft: draft.draft,
            operations: draft.operations,
            comments: Vec::new(),
        })
    }

    pub async fn create_review_decision(
        &self,
        review_id: &str,
        request: CreateReviewDecisionRequest,
    ) -> Result<Review, HubError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT status, version
             FROM reviews
             WHERE review_id = $1
             FOR UPDATE",
        )
        .bind(review_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| HubError::not_found("review", review_id))?;
        let status: String = row.try_get("status")?;
        let version: i64 = row.try_get("version")?;

        if status != "open" {
            return Err(HubError::invalid_transition("review", &status, "decision"));
        }
        if version != request.expected_review_version {
            return Err(HubError::version_conflict(
                "review",
                request.expected_review_version,
                version,
            ));
        }

        let next_status = match request.decision {
            ReviewDecision::Approved => "approved",
            ReviewDecision::Rejected => "rejected",
        };
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

        tx.commit().await?;
        self.get_review(review_id).await
    }

    pub async fn create_review_merge(
        &self,
        review_id: &str,
        request: CreateReviewMergeRequest,
    ) -> Result<ReviewMergeResult, HubError> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT review_id, draft_id, project_id, status, version
             FROM reviews
             WHERE review_id = $1
             FOR UPDATE",
        )
        .bind(review_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| HubError::not_found("review", review_id))?;

        let status: String = row.try_get("status")?;
        let version: i64 = row.try_get("version")?;
        if status != "approved" {
            return Err(HubError::invalid_transition("review", &status, "merged"));
        }
        if version != request.expected_review_version {
            return Err(HubError::version_conflict(
                "review",
                request.expected_review_version,
                version,
            ));
        }

        let project_id: String = row.try_get("project_id")?;
        let draft_id: String = row.try_get("draft_id")?;
        let project_version = current_project_revision(&mut tx, &project_id).await?;
        if let Some(expected_target_version) = request.expected_target_version
            && project_version != expected_target_version
        {
            return Err(HubError::version_conflict(
                "project",
                expected_target_version,
                project_version,
            ));
        }

        let operations = load_draft_operations(&mut tx, &draft_id).await?;
        for operation in &operations {
            apply_operation(&mut tx, &project_id, &operation.input).await?;
        }

        sqlx::query(
            "UPDATE projects
             SET revision = revision + 1, updated_at = now()
             WHERE project_id = $1",
        )
        .bind(&project_id)
        .execute(&mut *tx)
        .await?;

        let snapshot_id = create_project_snapshot(&mut tx, &project_id).await?;
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
                merge_id, review_id, snapshot_id, applied_operation_count
             )
             VALUES ($1, $2, $3, $4)",
        )
        .bind(prefixed_id("mrg"))
        .bind(review_id)
        .bind(&snapshot_id)
        .bind(operations.len() as i32)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        let review = self.get_review(review_id).await?;
        Ok(ReviewMergeResult {
            review,
            snapshot_id: Some(snapshot_id),
            applied_operation_count: operations.len() as i64,
        })
    }

    pub async fn list_project_snapshots(
        &self,
        project_id: &str,
    ) -> Result<SnapshotListResponse, HubError> {
        let rows = sqlx::query(
            "SELECT snapshot_id
             FROM snapshots
             WHERE scope = 'project' AND project_id = $1
             ORDER BY version DESC
             LIMIT 50",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let snapshot_id: String = row.try_get("snapshot_id")?;
            items.push(self.get_snapshot_payload(&snapshot_id).await?.manifest);
        }

        Ok(SnapshotListResponse {
            items,
            page_info: PageInfo {
                next_cursor: None,
                has_more: false,
            },
        })
    }

    pub async fn get_snapshot_payload(
        &self,
        snapshot_id: &str,
    ) -> Result<SnapshotPayload, HubError> {
        let mut tx = self.pool.begin().await?;
        let payload = load_snapshot_payload(&mut tx, snapshot_id).await?;
        tx.commit().await?;
        Ok(payload)
    }
}

#[derive(Debug, Error)]
pub enum HubError {
    #[error("{entity} not found: {id}")]
    NotFound { entity: &'static str, id: String },
    #[error("{entity} version conflict: expected {expected}, actual {actual}")]
    VersionConflict {
        entity: &'static str,
        expected: i64,
        actual: i64,
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

impl HubError {
    fn not_found(entity: &'static str, id: impl Into<String>) -> Self {
        Self::NotFound {
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
}

async fn insert_draft_operation(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    input: DraftOperationInput,
) -> Result<String, HubError> {
    let operation_id = prefixed_id("dop");
    sqlx::query(
        "INSERT INTO draft_operations (
            operation_id, draft_id, action, resource_kind, target_id, path,
            base_hash, new_path, body
         )
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(&operation_id)
    .bind(draft_id)
    .bind(input.action.as_str())
    .bind(input.resource.kind.as_str())
    .bind(&input.resource.id)
    .bind(&input.resource.path)
    .bind(&input.base_hash)
    .bind(&input.new_path)
    .bind(&input.body)
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
) -> Result<i64, HubError> {
    let row = sqlx::query(
        "SELECT status, version
         FROM drafts
         WHERE draft_id = $1
         FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| HubError::not_found("draft", draft_id))?;
    let status: String = row.try_get("status")?;
    let version: i64 = row.try_get("version")?;

    if status != "open" {
        return Err(HubError::invalid_transition("draft", &status, "append"));
    }
    if version != expected_draft_version {
        return Err(HubError::version_conflict(
            "draft",
            expected_draft_version,
            version,
        ));
    }

    insert_draft_operation(tx, draft_id, operation).await?;
    let updated = sqlx::query(
        "UPDATE drafts
         SET version = version + 1, updated_at = now()
         WHERE draft_id = $1
         RETURNING project_id, version, daemon_installation_id",
    )
    .bind(draft_id)
    .fetch_one(&mut **tx)
    .await?;
    let draft_daemon_installation_id: Option<String> = updated.try_get("daemon_installation_id")?;
    let daemon_installation_id =
        event_daemon_installation_id.or(draft_daemon_installation_id.as_deref());
    insert_draft_event(
        tx,
        draft_id,
        &updated.try_get::<String, _>("project_id")?,
        DraftEventType::OperationAppended,
        updated.try_get("version")?,
        daemon_installation_id,
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
) -> Result<i64, HubError> {
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
) -> Result<(), HubError> {
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
) -> Result<(), HubError> {
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
) -> Result<i64, HubError> {
    Ok(sqlx::query_scalar::<_, Option<i64>>(
        "SELECT max(revision)
         FROM project_org_resource_selections
         WHERE project_id = $1",
    )
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?
    .unwrap_or(0))
}

async fn insert_project_org_selection_items(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    resource_kind: &str,
    revision: i64,
    resource_ids: &[String],
) -> Result<(), HubError> {
    for resource_id in resource_ids {
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM resources
                WHERE resource_id = $1
                  AND resource_kind = $2
                  AND scope = 'org'
                  AND status = 'active'
            )",
        )
        .bind(resource_id)
        .bind(resource_kind)
        .fetch_one(&mut **tx)
        .await?;
        if !exists {
            return Err(HubError::not_found("org_resource", resource_id));
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
) -> Result<PersonalBundleDetail, HubError> {
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
    .ok_or_else(|| HubError::not_found("bundle", bundle_id))?;

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
                return Err(HubError::InvalidRequest(format!(
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
    project_id: Option<&str>,
) -> Result<Vec<RuleMeta>, HubError> {
    let rows = list_resource_rows(pool, "rule", scope, project_id).await?;
    rows.iter().map(rule_meta_from_row).collect()
}

async fn list_context_meta(
    pool: &PgPool,
    scope: &str,
    project_id: Option<&str>,
) -> Result<Vec<ContextMeta>, HubError> {
    let rows = list_resource_rows(pool, "context", scope, project_id).await?;
    rows.iter().map(context_meta_from_row).collect()
}

async fn list_workflow_meta(
    pool: &PgPool,
    scope: &str,
    project_id: Option<&str>,
) -> Result<Vec<WorkflowMeta>, HubError> {
    let rows = list_resource_rows(pool, "workflow", scope, project_id).await?;
    rows.iter().map(workflow_meta_from_row).collect()
}

async fn list_resource_rows(
    pool: &PgPool,
    kind: &str,
    scope: &str,
    project_id: Option<&str>,
) -> Result<Vec<sqlx::postgres::PgRow>, HubError> {
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
    } else {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                content_hash, context_kind, octet_length(body) AS size, updated_at
             FROM resources
             WHERE resource_kind = $1 AND scope = $2 AND status = 'active'
             ORDER BY path
             LIMIT 200",
        )
        .bind(kind)
        .bind(scope)
        .fetch_all(pool)
        .await?
    };
    Ok(rows)
}

async fn load_rule_detail(
    tx: &mut Transaction<'_, Postgres>,
    rule_id: &str,
    scope: &str,
    project_id: Option<&str>,
) -> Result<RuleDetail, HubError> {
    let row = load_resource_detail_row(tx, rule_id, "rule", scope, project_id).await?;
    let rule = rule_meta_from_row(&row)?;
    Ok(RuleDetail {
        body: row.try_get("body")?,
        etag: etag(row.try_get("revision")?),
        rule,
    })
}

async fn load_context_detail(
    tx: &mut Transaction<'_, Postgres>,
    context_id: &str,
    scope: &str,
    project_id: Option<&str>,
) -> Result<ContextDetail, HubError> {
    let row = load_resource_detail_row(tx, context_id, "context", scope, project_id).await?;
    let context = context_meta_from_row(&row)?;
    Ok(ContextDetail {
        body: row.try_get("body")?,
        etag: etag(row.try_get("revision")?),
        context,
    })
}

async fn load_workflow_detail(
    tx: &mut Transaction<'_, Postgres>,
    workflow_id: &str,
    scope: &str,
    project_id: Option<&str>,
) -> Result<WorkflowDetail, HubError> {
    let row = load_resource_detail_row(tx, workflow_id, "workflow", scope, project_id).await?;
    let workflow = workflow_meta_from_row(&row)?;
    let steps = load_workflow_steps(tx, workflow_id).await?;
    Ok(WorkflowDetail {
        etag: etag(row.try_get("revision")?),
        workflow,
        steps,
    })
}

async fn load_resource_detail_row(
    tx: &mut Transaction<'_, Postgres>,
    resource_id: &str,
    kind: &str,
    scope: &str,
    project_id: Option<&str>,
) -> Result<sqlx::postgres::PgRow, HubError> {
    let row = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                revision, content_hash, body, context_kind, octet_length(body) AS size,
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
    } else {
        sqlx::query(
            "SELECT
                resource_id, resource_kind, scope, project_id, path, name, status,
                revision, content_hash, body, context_kind, octet_length(body) AS size,
                updated_at
             FROM resources
             WHERE resource_id = $1
               AND resource_kind = $2
               AND scope = $3
               AND status = 'active'",
        )
        .bind(resource_id)
        .bind(kind)
        .bind(scope)
        .fetch_optional(&mut **tx)
        .await?
    };
    row.ok_or_else(|| HubError::not_found("resource", resource_id))
}

async fn load_workflow_steps(
    tx: &mut Transaction<'_, Postgres>,
    resource_id: &str,
) -> Result<Vec<WorkflowStep>, HubError> {
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
    project_id: Option<&str>,
) -> Result<MetapromptDetail, HubError> {
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
    } else {
        sqlx::query(
            "SELECT
                metaprompt_id, scope, project_id, status, revision,
                content_hash, body, updated_at
             FROM metaprompts
             WHERE scope = $1 AND status = 'active'
             ORDER BY updated_at DESC
             LIMIT 1",
        )
        .bind(scope)
        .fetch_optional(&mut **tx)
        .await?
    }
    .ok_or_else(|| HubError::not_found("metaprompt", project_id.unwrap_or(scope)))?;

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
        body: row.try_get("body")?,
        etag: etag(row.try_get("revision")?),
        metaprompt,
    })
}

fn personal_bundle_meta_from_row(
    row: &sqlx::postgres::PgRow,
) -> Result<PersonalBundleMeta, HubError> {
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

fn project_from_row(row: &sqlx::postgres::PgRow) -> Result<Project, HubError> {
    Ok(Project {
        project_id: row.try_get("project_id")?,
        name: row.try_get("name")?,
        description: row.try_get("description")?,
        revision: row.try_get("revision")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

fn draft_event_from_row(row: &sqlx::postgres::PgRow) -> Result<DraftEvent, HubError> {
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

fn rule_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<RuleMeta, HubError> {
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

fn context_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<ContextMeta, HubError> {
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

fn workflow_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<WorkflowMeta, HubError> {
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
) -> Result<DraftDetail, HubError> {
    let row = sqlx::query(
        "SELECT
            d.draft_id, d.project_id, d.title, d.description, d.status, d.version,
            d.resource_kind, d.target_id, d.path, d.daemon_installation_id,
            d.created_at, d.updated_at,
            u.user_id, u.email, u.display_name, u.role
         FROM drafts d
         JOIN users u ON u.user_id = d.author_user_id
         WHERE d.draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| HubError::not_found("draft", draft_id))?;

    let daemon_installation_id: String = row.try_get("daemon_installation_id")?;
    let draft = Draft {
        draft_id: row.try_get("draft_id")?,
        project_id: row.try_get("project_id")?,
        author: user_ref_from_row(&row)?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        resource: DraftResourceRef {
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

    Ok(DraftDetail {
        draft,
        operations,
        sync_state: DraftSyncState {
            status: DraftSyncStatus::Synced,
            server_cursor: Some(format!(
                "draft:{}:{}",
                draft_id,
                row.try_get::<i64, _>("version")?
            )),
            daemon_installation_id: Some(daemon_installation_id),
            conflict_count: 0,
        },
    })
}

async fn load_draft_operations(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<Vec<DraftOperation>, HubError> {
    let rows = sqlx::query(
        "SELECT operation_id, action, resource_kind, target_id, path, base_hash,
                new_path, body, created_at
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
                        kind: draft_resource_kind(
                            row.try_get::<String, _>("resource_kind")?.as_str(),
                        )?,
                        id: row.try_get("target_id")?,
                        path: row.try_get("path")?,
                    },
                    base_hash: row.try_get("base_hash")?,
                    body: row.try_get("body")?,
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
) -> Result<Review, HubError> {
    let row = sqlx::query(
        "SELECT
            r.review_id, r.project_id, r.draft_id, r.title, r.description,
            r.status, r.version, r.created_at, r.updated_at,
            u.user_id, u.email, u.display_name, u.role
         FROM reviews r
         JOIN users u ON u.user_id = r.author_user_id
         WHERE r.review_id = $1",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| HubError::not_found("review", review_id))?;

    Ok(Review {
        review_id: row.try_get("review_id")?,
        project_id: row.try_get("project_id")?,
        draft_id: row.try_get("draft_id")?,
        author: user_ref_from_row(&row)?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        status: review_status(row.try_get::<String, _>("status")?.as_str())?,
        version: row.try_get("version")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn apply_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    operation: &DraftOperationInput,
) -> Result<(), HubError> {
    match operation.resource.kind {
        DraftResourceKind::Metaprompt => {
            apply_metaprompt_operation(tx, project_id, operation).await
        }
        _ => apply_resource_operation(tx, project_id, operation).await,
    }
}

async fn apply_resource_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    operation: &DraftOperationInput,
) -> Result<(), HubError> {
    let org_id = project_org_id(tx, project_id).await?;
    match operation.action {
        DraftOperationAction::Create => {
            let path = operation.resource.path.as_ref().ok_or_else(|| {
                HubError::InvalidRequest("create operation requires path".to_owned())
            })?;
            let body = operation.body.as_deref().unwrap_or_default();
            let resource_id = prefixed_id(operation.resource.kind.resource_id_prefix());
            sqlx::query(
                "INSERT INTO resources (
                    resource_id, org_id, project_id, scope, resource_kind, path, name,
                    status, revision, content_hash, body, context_kind
                 )
                 VALUES ($1, $2, $3, 'project', $4, $5, $6, 'active', 1, $7, $8, $9)",
            )
            .bind(&resource_id)
            .bind(&org_id)
            .bind(project_id)
            .bind(operation.resource.kind.as_str())
            .bind(path)
            .bind(name_from_path(path))
            .bind(content_hash(body))
            .bind(body)
            .bind(context_kind_for(operation.resource.kind))
            .execute(&mut **tx)
            .await?;
        }
        DraftOperationAction::Update => {
            let resource = load_target_resource(tx, project_id, &operation.resource).await?;
            assert_base_hash(&resource, operation.base_hash.as_deref())?;
            let body = operation.body.as_deref().ok_or_else(|| {
                HubError::InvalidRequest("update operation requires body".to_owned())
            })?;
            sqlx::query(
                "UPDATE resources
                 SET body = $2, content_hash = $3, revision = revision + 1,
                     status = 'active', updated_at = now()
                 WHERE resource_id = $1",
            )
            .bind(&resource.resource_id)
            .bind(body)
            .bind(content_hash(body))
            .execute(&mut **tx)
            .await?;
        }
        DraftOperationAction::Rename => {
            let resource = load_target_resource(tx, project_id, &operation.resource).await?;
            assert_base_hash(&resource, operation.base_hash.as_deref())?;
            let new_path = operation.new_path.as_ref().ok_or_else(|| {
                HubError::InvalidRequest("rename operation requires new_path".to_owned())
            })?;
            sqlx::query(
                "UPDATE resources
                 SET path = $2, name = $3, revision = revision + 1, updated_at = now()
                 WHERE resource_id = $1",
            )
            .bind(&resource.resource_id)
            .bind(new_path)
            .bind(name_from_path(new_path))
            .execute(&mut **tx)
            .await?;
        }
        DraftOperationAction::Delete => {
            let resource = load_target_resource(tx, project_id, &operation.resource).await?;
            assert_base_hash(&resource, operation.base_hash.as_deref())?;
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

async fn apply_metaprompt_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    operation: &DraftOperationInput,
) -> Result<(), HubError> {
    let org_id = project_org_id(tx, project_id).await?;
    let existing = sqlx::query(
        "SELECT metaprompt_id, content_hash
         FROM metaprompts
         WHERE scope = 'project' AND project_id = $1 AND status = 'active'
         FOR UPDATE",
    )
    .bind(project_id)
    .fetch_optional(&mut **tx)
    .await?;

    match operation.action {
        DraftOperationAction::Create | DraftOperationAction::Update => {
            let body = operation.body.as_deref().ok_or_else(|| {
                HubError::InvalidRequest("metaprompt create/update requires body".to_owned())
            })?;
            if let Some(row) = existing {
                let current_hash: String = row.try_get("content_hash")?;
                if let Some(expected_hash) = operation.base_hash.as_deref()
                    && expected_hash != current_hash
                {
                    return Err(HubError::InvalidRequest(format!(
                        "metaprompt hash conflict: expected {expected_hash}, actual {current_hash}"
                    )));
                }
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
                     VALUES ($1, $2, $3, 'project', 'active', 1, $4, $5)",
                )
                .bind(prefixed_id("mpf"))
                .bind(&org_id)
                .bind(project_id)
                .bind(content_hash(body))
                .bind(body)
                .execute(&mut **tx)
                .await?;
            }
        }
        DraftOperationAction::Delete => {
            let row = existing.ok_or_else(|| HubError::not_found("metaprompt", project_id))?;
            let current_hash: String = row.try_get("content_hash")?;
            if let Some(expected_hash) = operation.base_hash.as_deref()
                && expected_hash != current_hash
            {
                return Err(HubError::InvalidRequest(format!(
                    "metaprompt hash conflict: expected {expected_hash}, actual {current_hash}"
                )));
            }
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
            return Err(HubError::InvalidRequest(
                "metaprompt does not support rename".to_owned(),
            ));
        }
    }
    Ok(())
}

async fn create_project_snapshot(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<String, HubError> {
    let version = sqlx::query_scalar::<_, Option<i64>>(
        "SELECT max(version)
         FROM snapshots
         WHERE scope = 'project' AND project_id = $1",
    )
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?
    .unwrap_or(0)
        + 1;
    let snapshot_id = prefixed_id("snp");
    sqlx::query(
        "INSERT INTO snapshots (snapshot_id, scope, project_id, version)
         VALUES ($1, 'project', $2, $3)",
    )
    .bind(&snapshot_id)
    .bind(project_id)
    .bind(version)
    .execute(&mut **tx)
    .await?;

    let project_rows = sqlx::query(
        "SELECT resource_id, resource_kind, path, content_hash, body
         FROM resources
         WHERE scope = 'project' AND project_id = $1 AND status = 'active'
         ORDER BY resource_kind, path",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in project_rows {
        insert_snapshot_resource_item(tx, &snapshot_id, &row, "project", "project").await?;
    }

    let selected_rows = sqlx::query(
        "SELECT r.resource_id, r.resource_kind, r.path, r.content_hash, r.body
         FROM project_org_resource_selections s
         JOIN resources r ON r.resource_id = s.resource_id
         WHERE s.project_id = $1 AND r.status = 'active'
         ORDER BY r.resource_kind, r.path",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in selected_rows {
        insert_snapshot_resource_item(tx, &snapshot_id, &row, "org", "selected_org").await?;
    }

    let metaprompt_rows = sqlx::query(
        "SELECT metaprompt_id, 'metaprompt' AS resource_kind, 'META_PROMPT.md' AS path,
                content_hash, body
         FROM metaprompts
         WHERE scope = 'project' AND project_id = $1 AND status = 'active'
         ORDER BY metaprompt_id",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in metaprompt_rows {
        insert_snapshot_metaprompt_item(tx, &snapshot_id, project_id, &row).await?;
    }

    let has_selection = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
            SELECT 1 FROM project_org_resource_selections WHERE project_id = $1
        )",
    )
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?;
    if has_selection {
        sqlx::query(
            "INSERT INTO snapshot_items (
                snapshot_id, item_id, resource_kind, scope, project_id,
                path, content_hash, content, source
             )
             VALUES ($1, $2, 'project_org_selection', 'daemon', $3, NULL, NULL, NULL, 'config')",
        )
        .bind(&snapshot_id)
        .bind(format!("project_org_selection:{project_id}"))
        .bind(project_id)
        .execute(&mut **tx)
        .await?;
    }

    Ok(snapshot_id)
}

async fn insert_snapshot_resource_item(
    tx: &mut Transaction<'_, Postgres>,
    snapshot_id: &str,
    row: &sqlx::postgres::PgRow,
    scope: &str,
    source: &str,
) -> Result<(), HubError> {
    let resource_id: String = row.try_get("resource_id")?;
    let resource_kind: String = row.try_get("resource_kind")?;
    let path: String = row.try_get("path")?;
    let content_hash: String = row.try_get("content_hash")?;
    let body: String = row.try_get("body")?;
    sqlx::query(
        "INSERT INTO snapshot_items (
            snapshot_id, item_id, resource_kind, scope, path,
            content_hash, content, source
         )
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(snapshot_id)
    .bind(resource_id)
    .bind(resource_kind)
    .bind(scope)
    .bind(path)
    .bind(content_hash)
    .bind(body)
    .bind(source)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn insert_snapshot_metaprompt_item(
    tx: &mut Transaction<'_, Postgres>,
    snapshot_id: &str,
    project_id: &str,
    row: &sqlx::postgres::PgRow,
) -> Result<(), HubError> {
    let metaprompt_id: String = row.try_get("metaprompt_id")?;
    let resource_kind: String = row.try_get("resource_kind")?;
    let path: String = row.try_get("path")?;
    let content_hash: String = row.try_get("content_hash")?;
    let body: String = row.try_get("body")?;
    sqlx::query(
        "INSERT INTO snapshot_items (
            snapshot_id, item_id, resource_kind, scope, project_id, path,
            content_hash, content, source
         )
         VALUES ($1, $2, $3, 'project', $4, $5, $6, $7, 'project')",
    )
    .bind(snapshot_id)
    .bind(metaprompt_id)
    .bind(resource_kind)
    .bind(project_id)
    .bind(path)
    .bind(content_hash)
    .bind(body)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn load_snapshot_payload(
    tx: &mut Transaction<'_, Postgres>,
    snapshot_id: &str,
) -> Result<SnapshotPayload, HubError> {
    let snapshot_row = sqlx::query(
        "SELECT snapshot_id, scope, project_id, version, created_at
         FROM snapshots
         WHERE snapshot_id = $1",
    )
    .bind(snapshot_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| HubError::not_found("snapshot", snapshot_id))?;

    let item_rows = sqlx::query(
        "SELECT item_id, resource_kind, scope, project_id, path, content_hash, content, source
         FROM snapshot_items
         WHERE snapshot_id = $1
         ORDER BY resource_kind, path NULLS LAST, item_id",
    )
    .bind(snapshot_id)
    .fetch_all(&mut **tx)
    .await?;

    let mut manifest_items = Vec::with_capacity(item_rows.len());
    let mut content_items = Vec::new();
    for row in item_rows {
        let kind = snapshot_item_kind(row.try_get::<String, _>("resource_kind")?.as_str())?;
        let scope = snapshot_item_scope(row.try_get::<String, _>("scope")?.as_str())?;
        let source = snapshot_source(row.try_get::<String, _>("source")?.as_str())?;
        let id: String = row.try_get("item_id")?;
        let project_id: Option<String> = row.try_get("project_id")?;
        let path: Option<String> = row.try_get("path")?;
        let content_hash: Option<String> = row.try_get("content_hash")?;
        manifest_items.push(SnapshotManifestItem {
            id: id.clone(),
            kind,
            scope,
            project_id: project_id.clone(),
            path: path.clone(),
            content_hash: content_hash.clone(),
            source,
        });
        if kind != SnapshotItemKind::ProjectOrgSelection {
            content_items.push(SnapshotContentItem {
                id,
                kind,
                scope,
                project_id,
                path,
                content_hash: content_hash.ok_or_else(|| {
                    HubError::InvalidRequest("snapshot content item missing hash".to_owned())
                })?,
                content: row
                    .try_get::<Option<String>, _>("content")?
                    .ok_or_else(|| {
                        HubError::InvalidRequest("snapshot content item missing content".to_owned())
                    })?,
            });
        }
    }

    let project_id: Option<String> = snapshot_row.try_get("project_id")?;
    let project_org_selection = match project_id.as_deref() {
        Some(project_id) => Some(load_project_org_selection(tx, project_id).await?),
        None => None,
    };

    Ok(SnapshotPayload {
        manifest: SnapshotManifest {
            snapshot_id: snapshot_row.try_get("snapshot_id")?,
            scope: snapshot_scope(snapshot_row.try_get::<String, _>("scope")?.as_str())?,
            project_id,
            version: snapshot_row.try_get("version")?,
            created_at: snapshot_row.try_get("created_at")?,
            items: manifest_items,
        },
        content_items,
        project_org_selection,
    })
}

async fn load_project_org_selection(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<ProjectOrgSelection, HubError> {
    let revision = sqlx::query_scalar::<_, Option<i64>>(
        "SELECT max(revision)
         FROM project_org_resource_selections
         WHERE project_id = $1",
    )
    .bind(project_id)
    .fetch_one(&mut **tx)
    .await?
    .unwrap_or(0);

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
                return Err(HubError::InvalidRequest(format!(
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
    content_hash: String,
}

async fn load_target_resource(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    resource: &DraftResourceRef,
) -> Result<TargetResource, HubError> {
    let row = if let Some(id) = resource.id.as_deref() {
        sqlx::query(
            "SELECT resource_id, content_hash
             FROM resources
             WHERE resource_id = $1 AND project_id = $2 AND status = 'active'
             FOR UPDATE",
        )
        .bind(id)
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
    } else if let Some(path) = resource.path.as_deref() {
        sqlx::query(
            "SELECT resource_id, content_hash
             FROM resources
             WHERE project_id = $1
               AND resource_kind = $2
               AND path = $3
               AND status = 'active'
             FOR UPDATE",
        )
        .bind(project_id)
        .bind(resource.kind.as_str())
        .bind(path)
        .fetch_optional(&mut **tx)
        .await?
    } else {
        return Err(HubError::InvalidRequest(
            "operation target requires id or path".to_owned(),
        ));
    }
    .ok_or_else(|| HubError::not_found("resource", resource.id.as_deref().unwrap_or("path")))?;

    Ok(TargetResource {
        resource_id: row.try_get("resource_id")?,
        content_hash: row.try_get("content_hash")?,
    })
}

fn assert_base_hash(resource: &TargetResource, base_hash: Option<&str>) -> Result<(), HubError> {
    match base_hash {
        Some(base_hash) if base_hash == resource.content_hash => Ok(()),
        Some(base_hash) => Err(HubError::InvalidRequest(format!(
            "resource hash conflict: expected {base_hash}, actual {}",
            resource.content_hash
        ))),
        None => Err(HubError::InvalidRequest(
            "update, rename, and delete operations require base_hash".to_owned(),
        )),
    }
}

async fn project_org_id(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<String, HubError> {
    sqlx::query_scalar::<_, String>("SELECT org_id FROM projects WHERE project_id = $1")
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| HubError::not_found("project", project_id))
}

async fn current_project_revision(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<i64, HubError> {
    sqlx::query_scalar::<_, i64>("SELECT revision FROM projects WHERE project_id = $1 FOR UPDATE")
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| HubError::not_found("project", project_id))
}

async fn user_ref(tx: &mut Transaction<'_, Postgres>, user_id: &str) -> Result<UserRef, HubError> {
    let row = sqlx::query(
        "SELECT user_id, email, display_name, role
         FROM users
         WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| HubError::not_found("user", user_id))?;
    user_ref_from_row(&row)
}

fn user_ref_from_row(row: &sqlx::postgres::PgRow) -> Result<UserRef, HubError> {
    Ok(UserRef {
        user_id: row.try_get("user_id")?,
        email: row.try_get("email")?,
        display_name: row.try_get("display_name")?,
        role: row.try_get("role")?,
        auth_provider: AuthProvider::Google,
    })
}

fn prefixed_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

fn content_hash(body: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(body.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
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

fn draft_resource_kind(value: &str) -> Result<DraftResourceKind, HubError> {
    match value {
        "context" => Ok(DraftResourceKind::Context),
        "rule" => Ok(DraftResourceKind::Rule),
        "workflow" => Ok(DraftResourceKind::Workflow),
        "metaprompt" => Ok(DraftResourceKind::Metaprompt),
        other => Err(HubError::InvalidRequest(format!(
            "unknown resource kind: {other}"
        ))),
    }
}

fn resource_scope(value: &str) -> Result<crate::api::ResourceScope, HubError> {
    match value {
        "org" => Ok(crate::api::ResourceScope::Org),
        "project" => Ok(crate::api::ResourceScope::Project),
        other => Err(HubError::InvalidRequest(format!(
            "unknown resource scope: {other}"
        ))),
    }
}

fn resource_status(value: &str) -> Result<crate::api::ResourceStatus, HubError> {
    match value {
        "active" => Ok(crate::api::ResourceStatus::Active),
        "deprecated" => Ok(crate::api::ResourceStatus::Deprecated),
        "archived" => Ok(crate::api::ResourceStatus::Archived),
        other => Err(HubError::InvalidRequest(format!(
            "unknown resource status: {other}"
        ))),
    }
}

fn context_kind(value: &str) -> Result<crate::api::ContextKind, HubError> {
    match value {
        "file" => Ok(crate::api::ContextKind::File),
        "note" => Ok(crate::api::ContextKind::Note),
        "decision" => Ok(crate::api::ContextKind::Decision),
        "reference" => Ok(crate::api::ContextKind::Reference),
        other => Err(HubError::InvalidRequest(format!(
            "unknown context kind: {other}"
        ))),
    }
}

fn draft_operation_action(value: &str) -> Result<DraftOperationAction, HubError> {
    match value {
        "create" => Ok(DraftOperationAction::Create),
        "update" => Ok(DraftOperationAction::Update),
        "rename" => Ok(DraftOperationAction::Rename),
        "delete" => Ok(DraftOperationAction::Delete),
        other => Err(HubError::InvalidRequest(format!(
            "unknown draft operation action: {other}"
        ))),
    }
}

fn draft_status(value: &str) -> Result<DraftStatus, HubError> {
    match value {
        "open" => Ok(DraftStatus::Open),
        "submitted" => Ok(DraftStatus::Submitted),
        "discarded" => Ok(DraftStatus::Discarded),
        "conflicted" => Ok(DraftStatus::Conflicted),
        other => Err(HubError::InvalidRequest(format!(
            "unknown draft status: {other}"
        ))),
    }
}

fn draft_event_type(value: &str) -> Result<DraftEventType, HubError> {
    match value {
        "created" => Ok(DraftEventType::Created),
        "updated" => Ok(DraftEventType::Updated),
        "operation_appended" => Ok(DraftEventType::OperationAppended),
        "discarded" => Ok(DraftEventType::Discarded),
        "submitted" => Ok(DraftEventType::Submitted),
        "conflicted" => Ok(DraftEventType::Conflicted),
        other => Err(HubError::InvalidRequest(format!(
            "unknown draft event type: {other}"
        ))),
    }
}

fn review_status(value: &str) -> Result<ReviewStatus, HubError> {
    match value {
        "open" => Ok(ReviewStatus::Open),
        "approved" => Ok(ReviewStatus::Approved),
        "rejected" => Ok(ReviewStatus::Rejected),
        "merged" => Ok(ReviewStatus::Merged),
        other => Err(HubError::InvalidRequest(format!(
            "unknown review status: {other}"
        ))),
    }
}

fn snapshot_scope(value: &str) -> Result<SnapshotScope, HubError> {
    match value {
        "org" => Ok(SnapshotScope::Org),
        "project" => Ok(SnapshotScope::Project),
        other => Err(HubError::InvalidRequest(format!(
            "unknown snapshot scope: {other}"
        ))),
    }
}

fn snapshot_item_kind(value: &str) -> Result<SnapshotItemKind, HubError> {
    match value {
        "rule" => Ok(SnapshotItemKind::Rule),
        "context" => Ok(SnapshotItemKind::Context),
        "workflow" => Ok(SnapshotItemKind::Workflow),
        "metaprompt" => Ok(SnapshotItemKind::Metaprompt),
        "project_org_selection" => Ok(SnapshotItemKind::ProjectOrgSelection),
        other => Err(HubError::InvalidRequest(format!(
            "unknown snapshot item kind: {other}"
        ))),
    }
}

fn snapshot_item_scope(value: &str) -> Result<SnapshotItemScope, HubError> {
    match value {
        "org" => Ok(SnapshotItemScope::Org),
        "project" => Ok(SnapshotItemScope::Project),
        "daemon" => Ok(SnapshotItemScope::Daemon),
        other => Err(HubError::InvalidRequest(format!(
            "unknown snapshot item scope: {other}"
        ))),
    }
}

fn snapshot_source(value: &str) -> Result<SnapshotSource, HubError> {
    match value {
        "org" => Ok(SnapshotSource::Org),
        "project" => Ok(SnapshotSource::Project),
        "selected_org" => Ok(SnapshotSource::SelectedOrg),
        "bootstrap" => Ok(SnapshotSource::Bootstrap),
        "config" => Ok(SnapshotSource::Config),
        other => Err(HubError::InvalidRequest(format!(
            "unknown snapshot source: {other}"
        ))),
    }
}
