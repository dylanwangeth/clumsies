use crate::api::*;
use crate::auth::AuthPrincipal;
use crate::memory::{
    OrgResourceImpact, advance_org_ref, advance_project_ref, apply_resource_operation,
    create_org_commit, create_project_commit, current_org_ref, current_project_ref, load_org_ref,
    load_project_ref, lock_org_draft_selection_coordination,
    lock_org_draft_selection_coordination_for_project, lock_org_ref_for_project_projection,
    project_org_id, refresh_projects_for_org_resource_changes, resolve_org_resource_impact,
    select_created_org_resources_for_project, validate_org_commit, validate_project_commit,
};
use crate::repository::ServerError;
use crate::shared::*;

use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction, types::Json};
use std::collections::{BTreeMap, BTreeSet};
use time::OffsetDateTime;

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

pub(super) fn validate_draft_operation_resource(
    draft_resource: &DraftResourceRef,
    operation: &DraftOperationInput,
) -> Result<(), ServerError> {
    validate_draft_resource(draft_resource)?;
    if operation.resource.scope != draft_resource.scope {
        return Err(ServerError::InvalidRequest(
            "one draft cannot mix resource scopes".to_owned(),
        ));
    }
    if let Some(content) = operation.content.as_ref() {
        validate_draft_content_shape(content)?;
    }
    if let Some(path) = operation.resource.path.as_deref() {
        validate_resource_path(path)?;
    }
    if let Some(path) = operation.new_path.as_deref() {
        validate_resource_path(path)?;
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

pub(super) fn ensure_publishable_draft_scope(scope: ResourceScope) -> Result<(), ServerError> {
    if scope == ResourceScope::Project {
        return Err(ServerError::InvalidRequest(
            "project-scoped Memory authority is read-only; publish an Organization-scoped Draft"
                .to_owned(),
        ));
    }
    Ok(())
}

pub(super) async fn canonicalize_org_draft_targets_are_selected(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    base_commit_id: Option<&str>,
    draft_resource: &mut DraftResourceRef,
    operations: &mut [DraftOperationInput],
) -> Result<(), ServerError> {
    if operations
        .first()
        .is_some_and(|operation| operation.action == DraftOperationAction::Create)
    {
        return Ok(());
    }
    if draft_resource.id.is_some() {
        canonicalize_org_draft_target_is_selected(
            tx,
            project_id,
            org_id,
            base_commit_id,
            draft_resource,
        )
        .await?;
    } else if draft_resource.path.is_some()
        && let Some(resource_id) = resolve_org_draft_target_id(
            tx,
            org_id,
            base_commit_id,
            draft_resource,
            !operations.is_empty(),
        )
        .await?
    {
        draft_resource.id = Some(resource_id);
        validate_org_draft_target_is_selected(tx, project_id, org_id, draft_resource).await?;
    }
    for operation in operations {
        if operation.action != DraftOperationAction::Create {
            canonicalize_org_draft_target_is_selected(
                tx,
                project_id,
                org_id,
                base_commit_id,
                &mut operation.resource,
            )
            .await?;
        }
    }
    Ok(())
}

pub(super) async fn validate_org_draft_operation_inputs_are_selected(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    base_commit_id: Option<&str>,
    operations: &[DraftOperationInput],
) -> Result<(), ServerError> {
    if operations
        .first()
        .is_some_and(|operation| operation.action == DraftOperationAction::Create)
    {
        return Ok(());
    }
    for operation in operations {
        if operation.action != DraftOperationAction::Create {
            validate_org_draft_target_is_selected_at_base(
                tx,
                project_id,
                org_id,
                base_commit_id,
                &operation.resource,
            )
            .await?;
        }
    }
    Ok(())
}

pub(super) async fn validate_stored_org_draft_operations_are_selected(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    base_commit_id: Option<&str>,
    operations: &[DraftOperation],
) -> Result<(), ServerError> {
    if operations
        .first()
        .is_some_and(|operation| operation.input.action == DraftOperationAction::Create)
    {
        return Ok(());
    }
    for operation in operations {
        if operation.input.action != DraftOperationAction::Create {
            validate_org_draft_target_is_selected_at_base(
                tx,
                project_id,
                org_id,
                base_commit_id,
                &operation.input.resource,
            )
            .await?;
        }
    }
    Ok(())
}

pub(super) async fn canonicalize_org_draft_target_is_selected(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    base_commit_id: Option<&str>,
    resource: &mut DraftResourceRef,
) -> Result<(), ServerError> {
    if resource.id.is_none() {
        resource.id =
            resolve_org_draft_target_id(tx, org_id, base_commit_id, resource, true).await?;
    }
    validate_org_draft_target_is_selected(tx, project_id, org_id, resource).await
}

pub(super) async fn validate_org_draft_target_is_selected_at_base(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    base_commit_id: Option<&str>,
    resource: &DraftResourceRef,
) -> Result<(), ServerError> {
    let mut canonical = resource.clone();
    canonicalize_org_draft_target_is_selected(
        tx,
        project_id,
        org_id,
        base_commit_id,
        &mut canonical,
    )
    .await
}

pub(super) async fn resolve_org_draft_target_id(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    base_commit_id: Option<&str>,
    resource: &DraftResourceRef,
    allow_historical_lookup: bool,
) -> Result<Option<String>, ServerError> {
    if let Some(resource_id) = resource.id.as_ref() {
        return Ok(Some(resource_id.clone()));
    }
    let Some(path) = resource.path.as_deref() else {
        return Ok(None);
    };

    if let Some(base_commit_id) = base_commit_id {
        let resource_id = sqlx::query_scalar::<_, String>(
            "SELECT entry.item_id
             FROM commits AS commit
             JOIN tree_entries AS entry ON entry.tree_id = commit.tree_id
             WHERE commit.commit_id = $1
               AND commit.org_id = $2
               AND commit.scope = 'org'
               AND entry.scope = 'org'
               AND entry.resource_kind = 'memory'
               AND entry.path = $3",
        )
        .bind(base_commit_id)
        .bind(org_id)
        .bind(path)
        .fetch_optional(&mut **tx)
        .await?;
        if resource_id.is_some() {
            return Ok(resource_id);
        }
    }

    let current_resource_id = sqlx::query_scalar::<_, String>(
        "SELECT resource_id
         FROM resources
         WHERE org_id = $1
           AND scope = 'org'
           AND status = 'active'
           AND path = $2",
    )
    .bind(org_id)
    .bind(path)
    .fetch_optional(&mut **tx)
    .await?;
    if current_resource_id.is_some() || !allow_historical_lookup {
        return Ok(current_resource_id);
    }

    let resource_ids = sqlx::query_scalar::<_, String>(
        "SELECT DISTINCT entry.item_id
         FROM commits AS commit
         JOIN tree_entries AS entry ON entry.tree_id = commit.tree_id
         WHERE commit.org_id = $1
           AND commit.scope = 'org'
           AND entry.scope = 'org'
           AND entry.resource_kind = 'memory'
           AND entry.path = $2
         ORDER BY entry.item_id
         LIMIT 2",
    )
    .bind(org_id)
    .bind(path)
    .fetch_all(&mut **tx)
    .await?;
    match resource_ids.as_slice() {
        [] => Ok(None),
        [resource_id] => Ok(Some(resource_id.clone())),
        _ => Err(ServerError::InvalidRequest(format!(
            "Organization Memory path {path} has referred to multiple resources; target it by resource id"
        ))),
    }
}

pub(super) async fn validate_org_draft_target_is_selected(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    resource: &DraftResourceRef,
) -> Result<(), ServerError> {
    let selected = if let Some(resource_id) = resource.id.as_deref() {
        sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM project_org_resource_selections s
                JOIN resources r ON r.resource_id = s.resource_id
                WHERE s.project_id = $1
                  AND r.resource_id = $2
                  AND r.org_id = $3
                  AND r.scope = 'org'
                  AND r.status = 'active'
             )",
        )
        .bind(project_id)
        .bind(resource_id)
        .bind(org_id)
        .fetch_one(&mut **tx)
        .await?
    } else if let Some(path) = resource.path.as_deref() {
        sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM project_org_resource_selections s
                JOIN resources r ON r.resource_id = s.resource_id
                WHERE s.project_id = $1
                  AND r.org_id = $2
                  AND r.scope = 'org'
                  AND r.path = $3
                  AND r.status = 'active'
             )",
        )
        .bind(project_id)
        .bind(org_id)
        .bind(path)
        .fetch_one(&mut **tx)
        .await?
    } else {
        false
    };
    if selected {
        return Ok(());
    }
    Err(ServerError::InvalidRequest(
        "an Organization Memory Draft may target only Memory currently selected by its carrying Project"
            .to_owned(),
    ))
}

pub(super) fn validate_new_resource_draft_operations(
    operations: &[DraftOperationInput],
) -> Result<(), ServerError> {
    let creates_resource = operations
        .iter()
        .any(|operation| operation.action == DraftOperationAction::Create);
    let deletes_resource = operations
        .iter()
        .any(|operation| operation.action == DraftOperationAction::Delete);
    if creates_resource && deletes_resource {
        return Err(ServerError::InvalidRequest(
            "a draft-created resource must be discarded instead of deleted".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn validate_draft_content_shape(
    content: &DraftResourceContent,
) -> Result<(), ServerError> {
    if content.content.trim().is_empty() {
        return Err(ServerError::InvalidRequest(
            "memory content must not be empty".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn validate_draft_resource(resource: &DraftResourceRef) -> Result<(), ServerError> {
    if let Some(path) = resource.path.as_deref() {
        validate_resource_path(path)?;
    }
    Ok(())
}

pub(super) async fn insert_draft_operation(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    input: DraftOperationInput,
) -> Result<String, ServerError> {
    let operation_id = prefixed_id("dop");
    // Serialize every allocator, including future call sites that do not
    // already hold the draft row lock. A per-draft MAX is safe once this lock
    // is held and keeps replacement operation sets densely ordered.
    sqlx::query("SELECT draft_id FROM drafts WHERE draft_id = $1 FOR UPDATE")
        .bind(draft_id)
        .fetch_one(&mut **tx)
        .await?;
    sqlx::query(
        "INSERT INTO draft_operations (
            operation_id, draft_id, action, resource_scope, resource_kind, target_id, path,
            new_path, content, ordinal
         )
         SELECT $1, $2, $3, $4, 'memory', $5, $6, $7, $8,
                COALESCE(MAX(ordinal), 0) + 1
         FROM draft_operations
         WHERE draft_id = $2",
    )
    .bind(&operation_id)
    .bind(draft_id)
    .bind(input.action.as_str())
    .bind(input.resource.scope.as_str())
    .bind(&input.resource.id)
    .bind(&input.resource.path)
    .bind(&input.new_path)
    .bind(input.content.as_ref().map(Json))
    .execute(&mut **tx)
    .await?;
    Ok(operation_id)
}

pub(super) async fn append_draft_operation_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    expected_draft_version: i64,
    mut operation: DraftOperationInput,
    event_daemon_installation_id: Option<&str>,
    org_coordination_already_locked: bool,
) -> Result<i64, ServerError> {
    let identity = sqlx::query(
        "SELECT project_id, resource_scope
         FROM drafts
         WHERE draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    let identity_scope = resource_scope(identity.try_get::<String, _>("resource_scope")?.as_str())?;
    if identity_scope == ResourceScope::Org && !org_coordination_already_locked {
        lock_org_draft_selection_coordination_for_project(
            tx,
            &identity.try_get::<String, _>("project_id")?,
        )
        .await?;
    }
    let row = sqlx::query(
        "SELECT d.status, d.version, d.project_id, d.resource_scope, d.resource_kind,
                d.base_commit_id,
                COALESCE((
                    SELECT operation.action = 'create'
                    FROM draft_operations AS operation
                    WHERE operation.draft_id = d.draft_id
                    ORDER BY operation.ordinal
                    LIMIT 1
                ), FALSE) AS creates_resource
         FROM drafts AS d
         WHERE d.draft_id = $1
         FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    let status: String = row.try_get("status")?;
    let version: i64 = row.try_get("version")?;
    let scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
    let draft_resource = DraftResourceRef {
        scope,
        id: None,
        path: None,
    };

    if status != "open" && status != "submitted" {
        return Err(ServerError::invalid_transition("draft", &status, "append"));
    }
    if version != expected_draft_version {
        return Err(ServerError::version_conflict(
            "draft",
            expected_draft_version,
            version,
        ));
    }
    let creates_resource: bool = row.try_get("creates_resource")?;
    if creates_resource && operation.action == DraftOperationAction::Delete {
        return Err(ServerError::InvalidRequest(
            "a draft-created resource must be discarded instead of deleted".to_owned(),
        ));
    }
    validate_draft_operation_resource(&draft_resource, &operation)?;
    if scope == ResourceScope::Org
        && !creates_resource
        && operation.action != DraftOperationAction::Create
    {
        let project_id: String = row.try_get("project_id")?;
        let org_id = project_org_id(tx, &project_id).await?;
        let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
        canonicalize_org_draft_target_is_selected(
            tx,
            &project_id,
            &org_id,
            base_commit_id.as_deref(),
            &mut operation.resource,
        )
        .await?;
    }

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
    invalidate_draft_candidates(tx, draft_id).await?;
    refresh_review_after_draft_content_change(tx, draft_id).await?;
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

pub(super) async fn invalidate_draft_candidates(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "UPDATE draft_reconciliation_candidates
         SET invalidated_at = now()
         WHERE draft_id = $1 AND invalidated_at IS NULL",
    )
    .bind(draft_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(super) async fn refresh_review_after_draft_content_change(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<(), ServerError> {
    let approved_hash = sqlx::query_scalar::<_, Option<String>>(
        "SELECT approved_result_hash FROM reviews
         WHERE draft_id = $1 AND status = 'approved' FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .flatten();
    let new_hash = if approved_hash.is_some() {
        Some(draft_result_hash(tx, draft_id).await?)
    } else {
        None
    };
    let preserve_approval = approved_hash.is_some() && approved_hash == new_hash;
    sqlx::query(
        "UPDATE reviews
         SET status = CASE WHEN status = 'approved' AND NOT $2 THEN 'open' ELSE status END,
             approved_result_hash = CASE WHEN status = 'approved' AND $2 THEN approved_result_hash ELSE NULL END,
             decision_body = CASE WHEN status = 'approved' AND $2 THEN decision_body ELSE NULL END,
             decided_by_user_id = CASE WHEN status = 'approved' AND $2 THEN decided_by_user_id ELSE NULL END,
             decided_at = CASE WHEN status = 'approved' AND $2 THEN decided_at ELSE NULL END,
             version = version + 1,
             updated_at = now()
         WHERE draft_id = $1 AND status IN ('open', 'approved')",
    )
    .bind(draft_id)
    .bind(preserve_approval)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(super) async fn insert_draft_event(
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

pub(super) async fn load_draft_detail(
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
    let resource_scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
    let resource = DraftResourceRef {
        scope: resource_scope,
        id: row.try_get("target_id")?,
        path: row.try_get("path")?,
    };
    let operations = load_draft_operations(tx, draft_id).await?;
    let allow_path_lookup = operations
        .first()
        .is_none_or(|operation| operation.input.action != DraftOperationAction::Create);
    let coordination = load_draft_coordination(
        tx,
        draft_id,
        row.try_get("project_id")?,
        row.try_get("base_commit_id")?,
        row.try_get("version")?,
        &resource,
        allow_path_lookup,
    )
    .await?;
    let draft = Draft {
        draft_id: row.try_get("draft_id")?,
        project_id: row.try_get("project_id")?,
        base_commit_id: row.try_get("base_commit_id")?,
        author: user_ref_from_row(&row)?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        resource,
        status: draft_status(row.try_get::<String, _>("status")?.as_str())?,
        coordination,
        version: row.try_get("version")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    };
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
        },
    })
}

pub(super) async fn load_draft_coordination(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    project_id: String,
    base_commit_id: Option<String>,
    draft_version: i64,
    resource: &DraftResourceRef,
    allow_path_lookup: bool,
) -> Result<DraftCoordination, ServerError> {
    let current_commit_id = match resource.scope {
        ResourceScope::Org => {
            let org_id = project_org_id(tx, &project_id).await?;
            load_org_ref(tx, &org_id).await?.commit_id
        }
        ResourceScope::Project => load_project_ref(tx, &project_id).await?.commit_id,
    };
    let freshness = if base_commit_id == current_commit_id {
        DraftFreshness::Current
    } else {
        DraftFreshness::Behind
    };
    let has_upstream_resource_changes = if freshness == DraftFreshness::Behind {
        let base_state =
            resource_state_at_commit(tx, base_commit_id.as_deref(), resource, allow_path_lookup)
                .await?;
        let current_state = resource_state_at_commit(
            tx,
            current_commit_id.as_deref(),
            resource,
            allow_path_lookup,
        )
        .await?;
        base_state != current_state
    } else {
        false
    };
    let candidate = if freshness == DraftFreshness::Behind {
        sqlx::query(
            "SELECT candidate_id, status
             FROM draft_reconciliation_candidates
             WHERE draft_id = $1 AND draft_version = $2
               AND base_commit_id IS NOT DISTINCT FROM $3
               AND current_commit_id IS NOT DISTINCT FROM $4
               AND invalidated_at IS NULL
             ORDER BY created_at DESC
             LIMIT 1",
        )
        .bind(draft_id)
        .bind(draft_version)
        .bind(&base_commit_id)
        .bind(&current_commit_id)
        .fetch_optional(&mut **tx)
        .await?
    } else {
        None
    };
    let (reconciliation, candidate_id) = match candidate {
        Some(row) => {
            let status: String = row.try_get("status")?;
            (
                match status.as_str() {
                    "clean" => DraftReconciliationStatus::Clean,
                    "conflicts" => DraftReconciliationStatus::Conflicts,
                    _ => {
                        return Err(ServerError::InvalidRequest(format!(
                            "unknown reconciliation status: {status}"
                        )));
                    }
                },
                Some(row.try_get("candidate_id")?),
            )
        }
        None => (DraftReconciliationStatus::Unknown, None),
    };
    Ok(DraftCoordination {
        freshness,
        current_commit_id,
        has_upstream_resource_changes,
        reconciliation,
        candidate_id,
    })
}

pub(super) async fn load_draft_operations(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<Vec<DraftOperation>, ServerError> {
    let rows = sqlx::query(
        "SELECT operation_id, action, resource_scope, resource_kind, target_id, path,
                new_path, content, created_at
         FROM draft_operations
         WHERE draft_id = $1
         ORDER BY ordinal",
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

pub(super) fn content_text(content: &DraftResourceContent) -> &str {
    &content.content
}

pub(super) fn content_for_kind(
    _kind: &str,
    content: String,
    description: Option<String>,
) -> DraftResourceContent {
    DraftResourceContent {
        description,
        content,
    }
}

pub(super) async fn resource_state_at_commit(
    tx: &mut Transaction<'_, Postgres>,
    commit_id: Option<&str>,
    resource: &DraftResourceRef,
    allow_path_lookup: bool,
) -> Result<ReconciliationResourceState, ServerError> {
    let Some(commit_id) = commit_id else {
        return Ok(ReconciliationResourceState {
            exists: false,
            resource: resource.clone(),
            content: None,
        });
    };
    let row = sqlx::query(
        "SELECT e.item_id, e.path, e.blob_id, b.content
         FROM commits c
         LEFT JOIN LATERAL (
             SELECT item_id, path, blob_id
             FROM tree_entries
             WHERE tree_id = c.tree_id
               AND resource_kind = 'memory'
               AND scope = $2
               AND (
                   ($3::TEXT IS NOT NULL AND item_id = $3)
                   OR ($3::TEXT IS NULL AND $4 AND path = $5)
               )
             ORDER BY item_id
             LIMIT 1
         ) e ON TRUE
         LEFT JOIN blobs b ON b.blob_id = e.blob_id
         WHERE c.commit_id = $1",
    )
    .bind(commit_id)
    .bind(resource.scope.as_str())
    .bind(resource.id.as_deref())
    .bind(allow_path_lookup)
    .bind(resource.path.as_deref())
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("commit", commit_id))?;

    let Some(id) = row.try_get::<Option<String>, _>("item_id")? else {
        return Ok(ReconciliationResourceState {
            exists: false,
            resource: resource.clone(),
            content: None,
        });
    };
    let blob_id: String = row.try_get("blob_id")?;
    let content = row
        .try_get::<Option<String>, _>("content")?
        .ok_or_else(|| {
            ServerError::InvalidRequest(format!("commit {commit_id} is missing blob {blob_id}"))
        })?;
    Ok(ReconciliationResourceState {
        exists: true,
        resource: DraftResourceRef {
            scope: resource.scope,
            id: Some(id),
            path: row.try_get("path")?,
        },
        content: Some(content_for_kind("memory", content, None)),
    })
}

pub(super) fn apply_operations_to_state(
    mut state: ReconciliationResourceState,
    operations: &[DraftOperation],
) -> Result<ReconciliationResourceState, ServerError> {
    for operation in operations {
        match operation.input.action {
            DraftOperationAction::Create => {
                let content = operation.input.content.clone().ok_or_else(|| {
                    ServerError::InvalidRequest("create operation requires content".to_owned())
                })?;
                state = ReconciliationResourceState {
                    exists: true,
                    resource: operation.input.resource.clone(),
                    content: Some(content),
                };
            }
            DraftOperationAction::Update => {
                if !state.exists {
                    return Err(ServerError::InvalidRequest(
                        "update operation targets a resource absent from the draft base".to_owned(),
                    ));
                }
                state.content = Some(operation.input.content.clone().ok_or_else(|| {
                    ServerError::InvalidRequest("update operation requires content".to_owned())
                })?);
            }
            DraftOperationAction::Rename => {
                if !state.exists {
                    return Err(ServerError::InvalidRequest(
                        "rename operation targets a resource absent from the draft base".to_owned(),
                    ));
                }
                state.resource.path = operation.input.new_path.clone();
            }
            DraftOperationAction::Delete => {
                state.exists = false;
                state.content = None;
            }
        }
    }
    Ok(state)
}

pub(super) fn state_hash(state: &ReconciliationResourceState) -> Result<String, ServerError> {
    let bytes = serde_json::to_vec(state).map_err(|error| {
        ServerError::InvalidRequest(format!("failed to hash resource state: {error}"))
    })?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

pub(super) fn merge_scalar<T: Clone + PartialEq>(base: &T, current: &T, draft: &T) -> Option<T> {
    if current == draft {
        Some(current.clone())
    } else if current == base {
        Some(draft.clone())
    } else if draft == base {
        Some(current.clone())
    } else {
        None
    }
}

pub(super) fn merge_resource_states(
    base: &ReconciliationResourceState,
    current: &ReconciliationResourceState,
    draft: &ReconciliationResourceState,
) -> (
    Option<ReconciliationResourceState>,
    Vec<ReconciliationConflict>,
) {
    if current == draft {
        return (Some(current.clone()), Vec::new());
    }
    if current == base {
        return (Some(draft.clone()), Vec::new());
    }
    if draft == base {
        return (Some(current.clone()), Vec::new());
    }

    if base.exists
        && ((!current.exists && draft.exists && draft != base)
            || (!draft.exists && current.exists && current != base))
    {
        return (
            None,
            vec![ReconciliationConflict {
                kind: ReconciliationConflictKind::Existence,
                field: "exists".to_owned(),
                base: Some(base.exists.to_string()),
                current: Some(current.exists.to_string()),
                draft: Some(draft.exists.to_string()),
            }],
        );
    }

    let Some(exists) = merge_scalar(&base.exists, &current.exists, &draft.exists) else {
        return (
            None,
            vec![ReconciliationConflict {
                kind: ReconciliationConflictKind::Existence,
                field: "exists".to_owned(),
                base: Some(base.exists.to_string()),
                current: Some(current.exists.to_string()),
                draft: Some(draft.exists.to_string()),
            }],
        );
    };
    if !exists {
        let mut state = draft.clone();
        state.exists = false;
        state.content = None;
        return (Some(state), Vec::new());
    }

    if !current.exists || !draft.exists {
        return (
            None,
            vec![ReconciliationConflict {
                kind: ReconciliationConflictKind::Existence,
                field: "exists".to_owned(),
                base: Some(base.exists.to_string()),
                current: Some(current.exists.to_string()),
                draft: Some(draft.exists.to_string()),
            }],
        );
    }

    let mut conflicts = Vec::new();
    let path = merge_scalar(
        &base.resource.path,
        &current.resource.path,
        &draft.resource.path,
    );
    if path.is_none() {
        conflicts.push(ReconciliationConflict {
            kind: ReconciliationConflictKind::Path,
            field: "path".to_owned(),
            base: base.resource.path.clone(),
            current: current.resource.path.clone(),
            draft: draft.resource.path.clone(),
        });
    }

    let base_text = base.content.as_ref().map(content_text).unwrap_or_default();
    let current_text = current
        .content
        .as_ref()
        .map(content_text)
        .unwrap_or_default();
    let draft_text = draft.content.as_ref().map(content_text).unwrap_or_default();
    let merged_text = if current_text == draft_text {
        Some(current_text.to_owned())
    } else if current_text == base_text {
        Some(draft_text.to_owned())
    } else if draft_text == base_text {
        Some(current_text.to_owned())
    } else {
        match diffy::merge(base_text, current_text, draft_text) {
            Ok(content) => Some(content),
            Err(_) => {
                conflicts.push(ReconciliationConflict {
                    kind: ReconciliationConflictKind::Content,
                    field: "content".to_owned(),
                    base: Some(base_text.to_owned()),
                    current: Some(current_text.to_owned()),
                    draft: Some(draft_text.to_owned()),
                });
                None
            }
        }
    };

    if !conflicts.is_empty() {
        return (None, conflicts);
    }
    let mut resource = current.resource.clone();
    resource.path = path.expect("path is present without conflicts");
    if resource.id.is_none() {
        resource.id = draft.resource.id.clone();
    }
    (
        Some(ReconciliationResourceState {
            exists: true,
            resource,
            content: merged_text.map(|content| content_for_kind("memory", content, None)),
        }),
        Vec::new(),
    )
}

pub(super) async fn path_is_occupied(
    tx: &mut Transaction<'_, Postgres>,
    commit_id: Option<&str>,
    state: &ReconciliationResourceState,
) -> Result<bool, ServerError> {
    if !state.exists {
        return Ok(false);
    }
    let Some(path) = state.resource.path.as_deref() else {
        return Ok(false);
    };
    let Some(commit_id) = commit_id else {
        return Ok(false);
    };
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
             SELECT 1
             FROM tree_entries e
             WHERE e.tree_id = c.tree_id
               AND e.resource_kind = 'memory'
               AND e.scope = $2
               AND e.path = $3
               AND e.item_id IS DISTINCT FROM $4
         )
         FROM commits c
         WHERE c.commit_id = $1",
    )
    .bind(commit_id)
    .bind(state.resource.scope.as_str())
    .bind(path)
    .bind(state.resource.id.as_deref())
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("commit", commit_id))
}

pub(super) fn diff_resource_states(
    current: &ReconciliationResourceState,
    resolved: &ReconciliationResourceState,
) -> Vec<DraftOperationInput> {
    match (current.exists, resolved.exists) {
        (false, false) => Vec::new(),
        (false, true) => vec![DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: resolved.resource.clone(),
            content: resolved.content.clone(),
            new_path: None,
        }],
        (true, false) => vec![DraftOperationInput {
            action: DraftOperationAction::Delete,
            resource: current.resource.clone(),
            content: None,
            new_path: None,
        }],
        (true, true) => {
            let mut operations = Vec::new();
            if current.resource.path != resolved.resource.path {
                operations.push(DraftOperationInput {
                    action: DraftOperationAction::Rename,
                    resource: current.resource.clone(),
                    content: None,
                    new_path: resolved.resource.path.clone(),
                });
            }
            if current.content != resolved.content {
                let mut resource = current.resource.clone();
                resource.path = resolved.resource.path.clone();
                operations.push(DraftOperationInput {
                    action: DraftOperationAction::Update,
                    resource,
                    content: resolved.content.clone(),
                    new_path: None,
                });
            }
            operations
        }
    }
}

pub(super) async fn draft_result_state(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<ReconciliationResourceState, ServerError> {
    let row = sqlx::query(
        "SELECT base_commit_id, resource_scope, resource_kind, target_id, path
         FROM drafts WHERE draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    let operations = load_draft_operations(tx, draft_id).await?;
    let resource = DraftResourceRef {
        scope: resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?,
        id: row.try_get("target_id")?,
        path: row.try_get("path")?,
    };
    let allow_path_lookup = operations
        .first()
        .is_none_or(|operation| operation.input.action != DraftOperationAction::Create);
    let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
    let base =
        resource_state_at_commit(tx, base_commit_id.as_deref(), &resource, allow_path_lookup)
            .await?;
    apply_operations_to_state(base, &operations)
}

pub(super) async fn draft_result_hash(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
) -> Result<String, ServerError> {
    state_hash(&draft_result_state(tx, draft_id).await?)
}

pub(super) async fn review_result_hash(
    tx: &mut Transaction<'_, Postgres>,
    draft_ids: &[String],
) -> Result<String, ServerError> {
    if let [draft_id] = draft_ids {
        return draft_result_hash(tx, draft_id).await;
    }
    let mut hasher = Sha256::new();
    for draft_id in draft_ids {
        hasher.update(draft_id.as_bytes());
        hasher.update([0]);
        hasher.update(draft_result_hash(tx, draft_id).await?.as_bytes());
        hasher.update([0]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub(super) async fn target_ref_for_draft(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    scope: ResourceScope,
) -> Result<Option<String>, ServerError> {
    match scope {
        ResourceScope::Org => {
            let org_id = project_org_id(tx, project_id).await?;
            current_org_ref(tx, &org_id).await
        }
        ResourceScope::Project => current_project_ref(tx, project_id).await,
    }
}

pub(super) async fn create_reconciliation_candidate_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    expected_draft_version: i64,
) -> Result<DraftReconciliationCandidate, ServerError> {
    let row = sqlx::query(
        "SELECT project_id, base_commit_id, resource_scope, resource_kind,
                target_id, path, status, version
         FROM drafts
         WHERE draft_id = $1
         FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    let draft_version: i64 = row.try_get("version")?;
    if draft_version != expected_draft_version {
        return Err(ServerError::version_conflict(
            "draft",
            expected_draft_version,
            draft_version,
        ));
    }
    let lifecycle: String = row.try_get("status")?;
    if lifecycle != "open" && lifecycle != "submitted" {
        return Err(ServerError::invalid_transition(
            "draft",
            &lifecycle,
            "reconciled",
        ));
    }
    let project_id: String = row.try_get("project_id")?;
    let scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
    let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
    let current_commit_id = target_ref_for_draft(tx, &project_id, scope).await?;
    if base_commit_id == current_commit_id {
        return Err(ServerError::DraftAlreadyCurrent {
            draft_id: draft_id.to_owned(),
        });
    }

    if let Some(existing_id) = sqlx::query_scalar::<_, String>(
        "SELECT candidate_id
         FROM draft_reconciliation_candidates
         WHERE draft_id = $1 AND draft_version = $2
           AND base_commit_id IS NOT DISTINCT FROM $3
           AND current_commit_id IS NOT DISTINCT FROM $4
           AND invalidated_at IS NULL
         LIMIT 1",
    )
    .bind(draft_id)
    .bind(draft_version)
    .bind(&base_commit_id)
    .bind(&current_commit_id)
    .fetch_optional(&mut **tx)
    .await?
    {
        return load_reconciliation_candidate(tx, draft_id, &existing_id).await;
    }

    invalidate_draft_candidates(tx, draft_id).await?;
    let mut resource = DraftResourceRef {
        scope,
        id: row.try_get("target_id")?,
        path: row.try_get("path")?,
    };
    let operations = load_draft_operations(tx, draft_id).await?;
    let allow_path_lookup = operations
        .first()
        .is_none_or(|operation| operation.input.action != DraftOperationAction::Create);
    if scope == ResourceScope::Org && resource.id.is_none() && allow_path_lookup {
        let org_id = project_org_id(tx, &project_id).await?;
        resource.id =
            resolve_org_draft_target_id(tx, &org_id, base_commit_id.as_deref(), &resource, true)
                .await?;
    }
    let base_state =
        resource_state_at_commit(tx, base_commit_id.as_deref(), &resource, allow_path_lookup)
            .await?;
    let current_state = resource_state_at_commit(
        tx,
        current_commit_id.as_deref(),
        &resource,
        allow_path_lookup,
    )
    .await?;
    let draft_state = apply_operations_to_state(base_state.clone(), &operations)?;
    let (mut proposed_state, mut conflicts) =
        merge_resource_states(&base_state, &current_state, &draft_state);
    if let Some(proposed) = proposed_state.as_ref()
        && path_is_occupied(tx, current_commit_id.as_deref(), proposed).await?
    {
        conflicts.push(ReconciliationConflict {
            kind: ReconciliationConflictKind::PathOccupied,
            field: "path".to_owned(),
            base: base_state.resource.path.clone(),
            current: current_state.resource.path.clone(),
            draft: proposed.resource.path.clone(),
        });
        proposed_state = None;
    }
    let status = if conflicts.is_empty() {
        ReconciliationCandidateStatus::Clean
    } else {
        ReconciliationCandidateStatus::Conflicts
    };
    let result_hash = proposed_state.as_ref().map(state_hash).transpose()?;
    let candidate_id = prefixed_id("rcn");
    sqlx::query(
        "INSERT INTO draft_reconciliation_candidates (
            candidate_id, draft_id, draft_version, base_commit_id, current_commit_id,
            status, base_state, current_state, draft_state, proposed_state,
            conflicts, result_hash
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
    )
    .bind(&candidate_id)
    .bind(draft_id)
    .bind(draft_version)
    .bind(&base_commit_id)
    .bind(&current_commit_id)
    .bind(match status {
        ReconciliationCandidateStatus::Clean => "clean",
        ReconciliationCandidateStatus::Conflicts => "conflicts",
    })
    .bind(Json(&base_state))
    .bind(Json(&current_state))
    .bind(Json(&draft_state))
    .bind(proposed_state.as_ref().map(Json))
    .bind(Json(&conflicts))
    .bind(&result_hash)
    .execute(&mut **tx)
    .await?;
    load_reconciliation_candidate(tx, draft_id, &candidate_id).await
}

pub(super) async fn load_reconciliation_candidate(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    candidate_id: &str,
) -> Result<DraftReconciliationCandidate, ServerError> {
    let row = sqlx::query(
        "SELECT candidate_id, draft_id, draft_version, base_commit_id, current_commit_id,
                status, base_state, current_state, draft_state, proposed_state,
                conflicts, result_hash, created_at, invalidated_at
         FROM draft_reconciliation_candidates
         WHERE candidate_id = $1 AND draft_id = $2",
    )
    .bind(candidate_id)
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("reconciliation_candidate", candidate_id))?;

    let draft_row = sqlx::query(
        "SELECT project_id, base_commit_id, resource_scope, version
         FROM drafts WHERE draft_id = $1",
    )
    .bind(draft_id)
    .fetch_one(&mut **tx)
    .await?;
    let scope = resource_scope(draft_row.try_get::<String, _>("resource_scope")?.as_str())?;
    let current =
        target_ref_for_draft(tx, &draft_row.try_get::<String, _>("project_id")?, scope).await?;
    let invalidated_at: Option<OffsetDateTime> = row.try_get("invalidated_at")?;
    let valid = invalidated_at.is_none()
        && row.try_get::<i64, _>("draft_version")? == draft_row.try_get::<i64, _>("version")?
        && row.try_get::<Option<String>, _>("base_commit_id")?
            == draft_row.try_get::<Option<String>, _>("base_commit_id")?
        && row.try_get::<Option<String>, _>("current_commit_id")? == current;
    if !valid && invalidated_at.is_none() {
        sqlx::query(
            "UPDATE draft_reconciliation_candidates SET invalidated_at = now()
             WHERE candidate_id = $1 AND invalidated_at IS NULL",
        )
        .bind(candidate_id)
        .execute(&mut **tx)
        .await?;
    }
    let status: String = row.try_get("status")?;
    Ok(DraftReconciliationCandidate {
        candidate_id: row.try_get("candidate_id")?,
        draft_id: row.try_get("draft_id")?,
        draft_version: row.try_get("draft_version")?,
        base_commit_id: row.try_get("base_commit_id")?,
        current_commit_id: row.try_get("current_commit_id")?,
        status: match status.as_str() {
            "clean" => ReconciliationCandidateStatus::Clean,
            "conflicts" => ReconciliationCandidateStatus::Conflicts,
            _ => {
                return Err(ServerError::InvalidRequest(format!(
                    "unknown candidate status: {status}"
                )));
            }
        },
        base_state: row
            .try_get::<Json<ReconciliationResourceState>, _>("base_state")?
            .0,
        current_state: row
            .try_get::<Json<ReconciliationResourceState>, _>("current_state")?
            .0,
        draft_state: row
            .try_get::<Json<ReconciliationResourceState>, _>("draft_state")?
            .0,
        proposed_state: row
            .try_get::<Option<Json<ReconciliationResourceState>>, _>("proposed_state")?
            .map(|state| state.0),
        conflicts: row
            .try_get::<Json<Vec<ReconciliationConflict>>, _>("conflicts")?
            .0,
        result_hash: row.try_get("result_hash")?,
        valid,
        created_at: row.try_get("created_at")?,
        invalidated_at: if valid {
            None
        } else {
            invalidated_at.or_else(|| Some(OffsetDateTime::now_utc()))
        },
    })
}

pub(super) async fn apply_draft_rebase_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    author_user_id: &str,
    expected_ref: Option<&str>,
    request: CreateDraftRebaseRequest,
) -> Result<DraftRebaseResult, ServerError> {
    let row = sqlx::query(
        "SELECT project_id, author_user_id, base_commit_id, resource_scope,
                resource_kind, target_id, path, status, version, title, description
         FROM drafts WHERE draft_id = $1 FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    if row.try_get::<String, _>("author_user_id")? != author_user_id {
        return Err(ServerError::Forbidden(
            "only the draft author can rebase it".to_owned(),
        ));
    }
    let version: i64 = row.try_get("version")?;
    if version != request.expected_draft_version {
        return Err(ServerError::version_conflict(
            "draft",
            request.expected_draft_version,
            version,
        ));
    }
    let lifecycle: String = row.try_get("status")?;
    if lifecycle != "open" && lifecycle != "submitted" {
        return Err(ServerError::invalid_transition(
            "draft", &lifecycle, "rebased",
        ));
    }
    let candidate = load_reconciliation_candidate(tx, draft_id, &request.candidate_id).await?;
    if !candidate.valid
        || candidate.draft_version != version
        || candidate.base_commit_id != row.try_get::<Option<String>, _>("base_commit_id")?
    {
        return Err(ServerError::ReconciliationCandidateInvalid {
            candidate_id: request.candidate_id,
        });
    }
    let project_id: String = row.try_get("project_id")?;
    let scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
    let current_ref = target_ref_for_draft(tx, &project_id, scope).await?;
    if current_ref.as_deref() != expected_ref {
        return Err(ServerError::precondition_failed(
            expected_ref,
            current_ref.as_deref(),
        ));
    }
    if candidate.current_commit_id != current_ref {
        return Err(ServerError::ReconciliationCandidateInvalid {
            candidate_id: request.candidate_id,
        });
    }
    let resolved_state = match (candidate.status, request.resolved_state) {
        (ReconciliationCandidateStatus::Clean, Some(_)) => {
            return Err(ServerError::InvalidRequest(
                "a clean candidate must be applied without resolved_state".to_owned(),
            ));
        }
        (ReconciliationCandidateStatus::Clean, None) => {
            candidate.proposed_state.clone().ok_or_else(|| {
                ServerError::InvalidRequest("clean candidate has no result".to_owned())
            })?
        }
        (ReconciliationCandidateStatus::Conflicts, Some(resolved)) => resolved,
        (ReconciliationCandidateStatus::Conflicts, None) => {
            return Err(ServerError::InvalidRequest(
                "a conflicts candidate requires a resolved_state".to_owned(),
            ));
        }
    };
    if resolved_state.resource.scope != scope
        || (resolved_state.exists && resolved_state.content.is_none())
    {
        return Err(ServerError::InvalidRequest(
            "resolved state does not match the draft resource".to_owned(),
        ));
    }
    if path_is_occupied(tx, current_ref.as_deref(), &resolved_state).await? {
        return Err(ServerError::InvalidRequest(
            "resolved state path is occupied in the current commit".to_owned(),
        ));
    }

    let previous_operations = load_draft_operations(tx, draft_id).await?;
    let previous_revision_id = prefixed_id("drv");
    sqlx::query(
        "INSERT INTO draft_revisions (
            revision_id, draft_id, draft_version, base_commit_id, lifecycle_status,
            title, description, operations
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(&previous_revision_id)
    .bind(draft_id)
    .bind(version)
    .bind(row.try_get::<Option<String>, _>("base_commit_id")?)
    .bind(&lifecycle)
    .bind(row.try_get::<String, _>("title")?)
    .bind(row.try_get::<String, _>("description")?)
    .bind(Json(&previous_operations))
    .execute(&mut **tx)
    .await?;

    let operations = diff_resource_states(&candidate.current_state, &resolved_state);
    sqlx::query("DELETE FROM draft_operations WHERE draft_id = $1")
        .bind(draft_id)
        .execute(&mut **tx)
        .await?;
    for operation in operations {
        insert_draft_operation(tx, draft_id, operation).await?;
    }
    let next_version: i64 = sqlx::query_scalar(
        "UPDATE drafts
         SET base_commit_id = $2, version = version + 1, updated_at = now()
         WHERE draft_id = $1 RETURNING version",
    )
    .bind(draft_id)
    .bind(&current_ref)
    .fetch_one(&mut **tx)
    .await?;
    invalidate_draft_candidates(tx, draft_id).await?;
    let result_hash = state_hash(&resolved_state)?;
    let review_row = sqlx::query(
        "SELECT reviews.review_id, reviews.status, reviews.approved_result_hash
         FROM reviews
         JOIN review_drafts ON review_drafts.review_id = reviews.review_id
         WHERE review_drafts.draft_id = $1
         FOR UPDATE OF reviews",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?;
    let mut approval_invalidated = false;
    if let Some(review_row) = review_row {
        let status: String = review_row.try_get("status")?;
        let approved_hash: Option<String> = review_row.try_get("approved_result_hash")?;
        let review_id: String = review_row.try_get("review_id")?;
        let draft_ids = load_review_draft_ids(tx, &review_id).await?;
        let current_review_hash = review_result_hash(tx, &draft_ids).await?;
        let preserve_approval =
            status == "approved" && approved_hash.as_deref() == Some(&current_review_hash);
        approval_invalidated = status == "approved" && !preserve_approval;
        sqlx::query(
            "UPDATE reviews
             SET status = CASE WHEN status = 'approved' AND NOT $2 THEN 'open' ELSE status END,
                 approved_result_hash = CASE WHEN status = 'approved' AND $2 THEN approved_result_hash ELSE NULL END,
                 decision_body = CASE WHEN status = 'approved' AND $2 THEN decision_body ELSE NULL END,
                 decided_by_user_id = CASE WHEN status = 'approved' AND $2 THEN decided_by_user_id ELSE NULL END,
                 decided_at = CASE WHEN status = 'approved' AND $2 THEN decided_at ELSE NULL END,
                 version = version + 1, updated_at = now()
             WHERE review_id = $1",
        )
        .bind(&review_id)
        .bind(preserve_approval)
        .execute(&mut **tx)
        .await?;
    }
    let rebase_id = prefixed_id("rbs");
    sqlx::query(
        "INSERT INTO draft_rebases (
            rebase_id, draft_id, candidate_id, previous_revision_id,
            applied_by_user_id, resulting_draft_version, result_hash
         ) VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(&rebase_id)
    .bind(draft_id)
    .bind(&candidate.candidate_id)
    .bind(&previous_revision_id)
    .bind(author_user_id)
    .bind(next_version)
    .bind(&result_hash)
    .execute(&mut **tx)
    .await?;
    insert_draft_event(
        tx,
        draft_id,
        &project_id,
        DraftEventType::Rebased,
        next_version,
        None,
    )
    .await?;
    let draft = load_draft_detail(tx, draft_id).await?;
    let review = match sqlx::query_scalar::<_, String>(
        "SELECT review_id FROM review_drafts WHERE draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    {
        Some(review_id) => Some(load_review(tx, &review_id).await?),
        None => None,
    };
    Ok(DraftRebaseResult {
        rebase_id,
        previous_revision_id,
        draft,
        review,
        approval_invalidated,
    })
}

pub(super) async fn load_review(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<Review, ServerError> {
    Ok(load_review_with_drafts(tx, review_id).await?.0)
}

pub(super) async fn load_review_with_drafts(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<(Review, Vec<ReviewDraftDetail>), ServerError> {
    let row = sqlx::query(
        "SELECT
            r.review_id, r.project_id, r.draft_id, r.title, r.description,
            r.status, r.version, r.decision_body, r.approved_result_hash,
            r.decided_by_user_id, r.decided_at,
            r.created_at, r.updated_at,
            u.user_id, u.email, u.display_name, u.avatar_url, u.role,
            du.user_id AS decision_user_id, du.email AS decision_user_email,
            du.display_name AS decision_user_display_name,
            du.avatar_url AS decision_user_avatar_url, du.role AS decision_user_role
         FROM reviews r
         JOIN users u ON u.user_id = r.author_user_id
         LEFT JOIN users du ON du.user_id = r.decided_by_user_id
         WHERE r.review_id = $1",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("review", review_id))?;

    let draft_ids = load_review_draft_ids(tx, review_id).await?;
    let drafts = load_review_drafts(tx, &draft_ids).await?;
    let coordinations = drafts
        .iter()
        .map(|detail| detail.draft.coordination.clone())
        .collect::<Vec<_>>();
    let review = review_from_row(
        &row,
        draft_ids,
        aggregate_draft_coordination(&coordinations),
    )?;
    Ok((review, drafts))
}

pub(super) async fn load_review_detail(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<ReviewDetail, ServerError> {
    let (review, drafts) = load_review_with_drafts(tx, review_id).await?;
    let primary = drafts
        .first()
        .cloned()
        .ok_or_else(|| ServerError::InvalidRequest("a review must contain a draft".to_owned()))?;
    let comments = load_review_comments(tx, review_id).await?;
    Ok(ReviewDetail {
        review,
        draft: primary.draft,
        operations: primary.operations,
        drafts,
        comments,
    })
}

pub(super) async fn load_review_drafts(
    tx: &mut Transaction<'_, Postgres>,
    draft_ids: &[String],
) -> Result<Vec<ReviewDraftDetail>, ServerError> {
    let mut drafts = Vec::with_capacity(draft_ids.len());
    for draft_id in draft_ids {
        let detail = load_draft_detail(tx, draft_id).await?;
        drafts.push(ReviewDraftDetail {
            draft: detail.draft,
            operations: detail.operations,
        });
    }
    Ok(drafts)
}

pub(super) async fn load_review_draft_ids(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<Vec<String>, ServerError> {
    let mut draft_ids = sqlx::query_scalar::<_, String>(
        "SELECT draft_id FROM review_drafts WHERE review_id = $1 ORDER BY ordinal",
    )
    .bind(review_id)
    .fetch_all(&mut **tx)
    .await?;
    if draft_ids.is_empty() {
        let primary =
            sqlx::query_scalar::<_, String>("SELECT draft_id FROM reviews WHERE review_id = $1")
                .bind(review_id)
                .fetch_optional(&mut **tx)
                .await?
                .ok_or_else(|| ServerError::not_found("review", review_id))?;
        draft_ids.push(primary);
    }
    Ok(draft_ids)
}

pub(super) async fn load_review_list_projections(
    tx: &mut Transaction<'_, Postgres>,
    review_ids: &[String],
) -> Result<BTreeMap<String, (Vec<String>, Vec<DraftCoordination>)>, ServerError> {
    if review_ids.is_empty() {
        return Ok(BTreeMap::new());
    }
    let rows = sqlx::query(
        "SELECT
            rd.review_id, rd.draft_id, d.base_commit_id,
            current_ref.commit_id AS current_commit_id,
            candidate.status AS candidate_status,
            candidate.candidate_id,
            CASE
                WHEN d.base_commit_id IS NOT DISTINCT FROM current_ref.commit_id THEN FALSE
                WHEN base_entry.item_id IS NULL AND current_entry.item_id IS NULL THEN FALSE
                WHEN base_entry.item_id IS NOT NULL
                  AND current_entry.item_id IS NOT NULL
                  AND base_entry.item_id = current_entry.item_id
                  AND base_entry.path IS NOT DISTINCT FROM current_entry.path
                  AND base_entry.blob_id = current_entry.blob_id THEN FALSE
                ELSE TRUE
            END AS has_upstream_resource_changes
         FROM review_drafts rd
         JOIN drafts d ON d.draft_id = rd.draft_id
         JOIN projects p ON p.project_id = d.project_id
         JOIN refs current_ref
           ON current_ref.ref_name = 'refs/heads/main'
          AND (
              (d.resource_scope = 'org'
               AND current_ref.scope = 'org'
               AND current_ref.org_id = p.org_id)
              OR
              (d.resource_scope = 'project'
               AND current_ref.scope = 'project'
               AND current_ref.project_id = d.project_id)
          )
         LEFT JOIN LATERAL (
             SELECT operation.action
             FROM draft_operations operation
             WHERE operation.draft_id = d.draft_id
             ORDER BY operation.ordinal
             LIMIT 1
         ) first_operation ON TRUE
         LEFT JOIN LATERAL (
             SELECT e.item_id, e.path, e.blob_id
             FROM commits c
             JOIN tree_entries e ON e.tree_id = c.tree_id
             WHERE c.commit_id = d.base_commit_id
               AND d.base_commit_id IS DISTINCT FROM current_ref.commit_id
               AND e.resource_kind = 'memory'
               AND e.scope = d.resource_scope
               AND (
                   (d.target_id IS NOT NULL AND e.item_id = d.target_id)
                   OR
                   (d.target_id IS NULL
                    AND first_operation.action IS DISTINCT FROM 'create'
                    AND e.path = d.path)
               )
             ORDER BY e.item_id
             LIMIT 1
         ) base_entry ON TRUE
         LEFT JOIN LATERAL (
             SELECT e.item_id, e.path, e.blob_id
             FROM commits c
             JOIN tree_entries e ON e.tree_id = c.tree_id
             WHERE c.commit_id = current_ref.commit_id
               AND d.base_commit_id IS DISTINCT FROM current_ref.commit_id
               AND e.resource_kind = 'memory'
               AND e.scope = d.resource_scope
               AND (
                   (d.target_id IS NOT NULL AND e.item_id = d.target_id)
                   OR
                   (d.target_id IS NULL
                    AND first_operation.action IS DISTINCT FROM 'create'
                    AND e.path = d.path)
               )
             ORDER BY e.item_id
             LIMIT 1
         ) current_entry ON TRUE
         LEFT JOIN LATERAL (
             SELECT c.status, c.candidate_id
             FROM draft_reconciliation_candidates c
             WHERE c.draft_id = d.draft_id
               AND c.draft_version = d.version
               AND c.base_commit_id IS NOT DISTINCT FROM d.base_commit_id
               AND c.current_commit_id IS NOT DISTINCT FROM current_ref.commit_id
               AND c.invalidated_at IS NULL
               AND d.base_commit_id IS DISTINCT FROM current_ref.commit_id
             ORDER BY c.created_at DESC
             LIMIT 1
         ) candidate ON TRUE
         WHERE rd.review_id = ANY($1)
         ORDER BY rd.review_id, rd.ordinal",
    )
    .bind(review_ids)
    .fetch_all(&mut **tx)
    .await?;

    let mut projections = BTreeMap::<String, (Vec<String>, Vec<DraftCoordination>)>::new();
    for row in rows {
        let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
        let current_commit_id: Option<String> = row.try_get("current_commit_id")?;
        let freshness = if base_commit_id == current_commit_id {
            DraftFreshness::Current
        } else {
            DraftFreshness::Behind
        };
        let candidate_status: Option<String> = row.try_get("candidate_status")?;
        let reconciliation = if freshness == DraftFreshness::Current {
            DraftReconciliationStatus::Unknown
        } else {
            match candidate_status.as_deref() {
                Some("clean") => DraftReconciliationStatus::Clean,
                Some("conflicts") => DraftReconciliationStatus::Conflicts,
                Some(status) => {
                    return Err(ServerError::InvalidRequest(format!(
                        "unknown reconciliation status: {status}"
                    )));
                }
                None => DraftReconciliationStatus::Unknown,
            }
        };
        let coordination = DraftCoordination {
            freshness,
            current_commit_id,
            has_upstream_resource_changes: row.try_get("has_upstream_resource_changes")?,
            reconciliation,
            candidate_id: row.try_get("candidate_id")?,
        };
        let projection = projections.entry(row.try_get("review_id")?).or_default();
        projection.0.push(row.try_get("draft_id")?);
        projection.1.push(coordination);
    }
    Ok(projections)
}

pub(super) fn aggregate_draft_coordination(
    coordinations: &[DraftCoordination],
) -> DraftCoordination {
    let primary = coordinations.first().cloned().unwrap_or(DraftCoordination {
        freshness: DraftFreshness::Current,
        current_commit_id: None,
        has_upstream_resource_changes: false,
        reconciliation: DraftReconciliationStatus::Unknown,
        candidate_id: None,
    });
    DraftCoordination {
        freshness: if coordinations
            .iter()
            .any(|coordination| coordination.freshness == DraftFreshness::Behind)
        {
            DraftFreshness::Behind
        } else {
            DraftFreshness::Current
        },
        current_commit_id: primary.current_commit_id,
        has_upstream_resource_changes: coordinations
            .iter()
            .any(|coordination| coordination.has_upstream_resource_changes),
        reconciliation: if coordinations
            .iter()
            .any(|coordination| coordination.reconciliation == DraftReconciliationStatus::Conflicts)
        {
            DraftReconciliationStatus::Conflicts
        } else if coordinations
            .iter()
            .any(|coordination| coordination.reconciliation == DraftReconciliationStatus::Unknown)
        {
            DraftReconciliationStatus::Unknown
        } else {
            DraftReconciliationStatus::Clean
        },
        candidate_id: if coordinations.len() == 1 {
            primary.candidate_id
        } else {
            None
        },
    }
}

pub(super) fn review_from_row(
    row: &sqlx::postgres::PgRow,
    draft_ids: Vec<String>,
    coordination: DraftCoordination,
) -> Result<Review, ServerError> {
    Ok(Review {
        review_id: row.try_get("review_id")?,
        project_id: row.try_get("project_id")?,
        draft_id: row.try_get("draft_id")?,
        draft_ids,
        author: user_ref_from_row(row)?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        status: review_status(row.try_get::<String, _>("status")?.as_str())?,
        version: row.try_get("version")?,
        decision_body: row.try_get("decision_body")?,
        approved_result_hash: row.try_get("approved_result_hash")?,
        decided_by: row
            .try_get::<Option<String>, _>("decision_user_id")?
            .map(|user_id| {
                Ok::<UserRef, sqlx::Error>(UserRef {
                    user_id,
                    email: row.try_get("decision_user_email")?,
                    display_name: row.try_get("decision_user_display_name")?,
                    avatar_url: row.try_get("decision_user_avatar_url")?,
                    role: row.try_get("decision_user_role")?,
                })
            })
            .transpose()?,
        decided_at: row.try_get("decided_at")?,
        coordination,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

pub(super) async fn load_review_comments(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<Vec<ReviewComment>, ServerError> {
    let rows = sqlx::query(
        "SELECT
            c.comment_id, c.review_id, c.body, c.anchor_path, c.anchor_line,
            c.review_version, c.created_at,
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
                anchor_path: row.try_get("anchor_path")?,
                anchor_line: row.try_get("anchor_line")?,
                review_version: row.try_get("review_version")?,
                created_at: row.try_get("created_at")?,
            })
        })
        .collect()
}

pub(super) fn review_comment_line_count(content: &str) -> i64 {
    if content.is_empty() {
        0
    } else {
        content.split('\n').count() as i64
    }
}

pub(super) async fn apply_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    scope: ResourceScope,
    operation: &DraftOperationInput,
) -> Result<Option<String>, ServerError> {
    if operation.resource.scope != scope {
        return Err(ServerError::InvalidRequest(
            "draft operation scope does not match its draft".to_owned(),
        ));
    }
    apply_resource_operation(tx, project_id, scope, operation).await
}

pub(super) fn materialize_draft_operations(
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

pub(super) fn merge_draft_contents(
    base: Option<DraftResourceContent>,
    update: Option<DraftResourceContent>,
) -> Result<Option<DraftResourceContent>, ServerError> {
    let _ = base;
    Ok(update)
}

pub(super) fn draft_operation_action(value: &str) -> Result<DraftOperationAction, ServerError> {
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

pub(super) fn draft_status(value: &str) -> Result<DraftStatus, ServerError> {
    match value {
        "open" => Ok(DraftStatus::Open),
        "submitted" => Ok(DraftStatus::Submitted),
        "discarded" => Ok(DraftStatus::Discarded),
        "merged" => Ok(DraftStatus::Merged),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown draft status: {other}"
        ))),
    }
}

pub(super) fn draft_event_type(value: &str) -> Result<DraftEventType, ServerError> {
    match value {
        "created" => Ok(DraftEventType::Created),
        "updated" => Ok(DraftEventType::Updated),
        "operation_appended" => Ok(DraftEventType::OperationAppended),
        "discarded" => Ok(DraftEventType::Discarded),
        "submitted" => Ok(DraftEventType::Submitted),
        "reopened" => Ok(DraftEventType::Reopened),
        "rebased" => Ok(DraftEventType::Rebased),
        "merged" => Ok(DraftEventType::Merged),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown draft event type: {other}"
        ))),
    }
}

pub(super) fn review_status(value: &str) -> Result<ReviewStatus, ServerError> {
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

pub(super) enum CommitOutcome<T> {
    Success(T),
    Failure(ServerError),
}

impl<T> CommitOutcome<T> {
    pub(super) fn into_result(self) -> Result<T, ServerError> {
        match self {
            Self::Success(value) => Ok(value),
            Self::Failure(error) => Err(error),
        }
    }
}

pub(super) struct ReviewMergeData {
    pub(super) commit_id: String,
    pub(super) applied_operation_count: i64,
}

pub(super) async fn draft_is_owned_by(
    pool: &PgPool,
    principal: &AuthPrincipal,
    draft_id: &str,
) -> Result<bool, ServerError> {
    Ok(sqlx::query_scalar::<_, bool>(
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
    .fetch_one(pool)
    .await?)
}

pub(super) async fn review_is_accessible(
    pool: &PgPool,
    principal: &AuthPrincipal,
    review_id: &str,
) -> Result<bool, ServerError> {
    Ok(sqlx::query_scalar::<_, bool>(
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
    .fetch_one(pool)
    .await?)
}

pub(super) async fn ensure_drafts_owned_by(
    tx: &mut Transaction<'_, Postgres>,
    principal: &AuthPrincipal,
    draft_ids: &[String],
) -> Result<(), ServerError> {
    let unauthorized_draft_id = sqlx::query_scalar::<_, String>(
        "SELECT requested.draft_id
         FROM unnest($1::TEXT[]) WITH ORDINALITY AS requested(draft_id, ordinal)
         WHERE NOT EXISTS (
             SELECT 1
             FROM drafts d
             JOIN projects p ON p.project_id = d.project_id
             JOIN project_members m ON m.project_id = p.project_id
             WHERE d.draft_id = requested.draft_id
               AND d.author_user_id = $2
               AND p.org_id = $3
               AND m.user_id = $2
         )
         ORDER BY requested.ordinal
         LIMIT 1",
    )
    .bind(draft_ids)
    .bind(&principal.user_id)
    .bind(&principal.org_id)
    .fetch_optional(&mut **tx)
    .await?;
    match unauthorized_draft_id {
        Some(draft_id) => Err(ServerError::not_found("draft", draft_id)),
        None => Ok(()),
    }
}

pub(super) async fn ensure_drafts_authored_by(
    tx: &mut Transaction<'_, Postgres>,
    author_user_id: &str,
    draft_ids: &[String],
) -> Result<(), ServerError> {
    let owned_count = sqlx::query_scalar::<_, i64>(
        "SELECT count(DISTINCT draft_id)
         FROM drafts
         WHERE draft_id = ANY($1) AND author_user_id = $2",
    )
    .bind(draft_ids)
    .bind(author_user_id)
    .fetch_one(&mut **tx)
    .await?;
    if owned_count == draft_ids.len() as i64 {
        Ok(())
    } else {
        Err(ServerError::Forbidden(
            "only the draft author can create its review".to_owned(),
        ))
    }
}

pub(super) async fn find_rejected_review(
    pool: &PgPool,
    draft_id: &str,
) -> Result<Option<(String, i64)>, ServerError> {
    let row = sqlx::query(
        "SELECT review_id, version
         FROM reviews
         WHERE draft_id = $1 AND status = 'rejected'",
    )
    .bind(draft_id)
    .fetch_optional(pool)
    .await?;
    row.map(|row| Ok((row.try_get("review_id")?, row.try_get("version")?)))
        .transpose()
}

pub(super) async fn ensure_review_exists(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
) -> Result<(), ServerError> {
    sqlx::query_scalar::<_, String>("SELECT review_id FROM reviews WHERE review_id = $1")
        .bind(review_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| ServerError::not_found("review", review_id))?;
    Ok(())
}

pub(super) async fn create_draft(
    tx: &mut Transaction<'_, Postgres>,
    author_user_id: &str,
    mut request: CreateDraftRequest,
) -> Result<String, ServerError> {
    if request.resource.scope == ResourceScope::Org {
        lock_org_draft_selection_coordination_for_project(tx, &request.project_id).await?;
    }
    let org_id = project_org_id(tx, &request.project_id).await?;
    user_ref(tx, author_user_id).await?;
    if let Some(base_commit_id) = request.base_commit_id.as_deref() {
        match request.resource.scope {
            ResourceScope::Org => validate_org_commit(tx, &org_id, base_commit_id).await?,
            ResourceScope::Project => {
                validate_project_commit(tx, &request.project_id, base_commit_id).await?
            }
        }
    }
    validate_draft_resource(&request.resource)?;
    for operation in &request.operations {
        validate_draft_operation_resource(&request.resource, operation)?;
    }
    validate_new_resource_draft_operations(&request.operations)?;
    if request.resource.scope == ResourceScope::Org {
        canonicalize_org_draft_targets_are_selected(
            tx,
            &request.project_id,
            &org_id,
            request.base_commit_id.as_deref(),
            &mut request.resource,
            &mut request.operations,
        )
        .await?;
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
    .bind("memory")
    .bind(&request.base_commit_id)
    .bind(&request.resource.id)
    .bind(&request.resource.path)
    .bind(&request.daemon_installation_id)
    .execute(&mut **tx)
    .await?;

    for operation in request.operations {
        insert_draft_operation(tx, &draft_id, operation).await?;
    }
    insert_draft_event(
        tx,
        &draft_id,
        &request.project_id,
        DraftEventType::Created,
        1,
        Some(&request.daemon_installation_id),
    )
    .await?;

    Ok(draft_id)
}

pub(super) async fn list_drafts(
    pool: &PgPool,
    author_user_id: &str,
    project_id: Option<&str>,
) -> Result<DraftListResponse, ServerError> {
    let rows = sqlx::query(
        "SELECT
            d.draft_id, d.project_id, d.base_commit_id, d.title, d.description,
            d.status, d.version, d.resource_scope, d.target_id, d.path,
            d.created_at, d.updated_at,
            u.user_id, u.email, u.display_name, u.avatar_url, u.role,
            current_ref.commit_id AS current_commit_id,
            candidate.status AS candidate_status,
            candidate.candidate_id,
            CASE
                WHEN d.base_commit_id IS NOT DISTINCT FROM current_ref.commit_id THEN FALSE
                WHEN base_entry.item_id IS NULL AND current_entry.item_id IS NULL THEN FALSE
                WHEN base_entry.item_id IS NOT NULL
                  AND current_entry.item_id IS NOT NULL
                  AND base_entry.item_id = current_entry.item_id
                  AND base_entry.path IS NOT DISTINCT FROM current_entry.path
                  AND base_entry.blob_id = current_entry.blob_id THEN FALSE
                ELSE TRUE
            END AS has_upstream_resource_changes
         FROM drafts d
         JOIN users u ON u.user_id = d.author_user_id
         JOIN projects p ON p.project_id = d.project_id
         JOIN refs current_ref
           ON current_ref.ref_name = 'refs/heads/main'
          AND (
              (d.resource_scope = 'org'
               AND current_ref.scope = 'org'
               AND current_ref.org_id = p.org_id)
              OR
              (d.resource_scope = 'project'
               AND current_ref.scope = 'project'
               AND current_ref.project_id = d.project_id)
          )
         LEFT JOIN LATERAL (
             SELECT operation.action
             FROM draft_operations operation
             WHERE operation.draft_id = d.draft_id
             ORDER BY operation.ordinal
             LIMIT 1
         ) first_operation ON TRUE
         LEFT JOIN LATERAL (
             SELECT e.item_id, e.path, e.blob_id
             FROM commits c
             JOIN tree_entries e ON e.tree_id = c.tree_id
             WHERE c.commit_id = d.base_commit_id
               AND d.base_commit_id IS DISTINCT FROM current_ref.commit_id
               AND e.resource_kind = 'memory'
               AND e.scope = d.resource_scope
               AND (
                   (d.target_id IS NOT NULL AND e.item_id = d.target_id)
                   OR
                   (d.target_id IS NULL
                    AND first_operation.action IS DISTINCT FROM 'create'
                    AND e.path = d.path)
               )
             ORDER BY e.item_id
             LIMIT 1
         ) base_entry ON TRUE
         LEFT JOIN LATERAL (
             SELECT e.item_id, e.path, e.blob_id
             FROM commits c
             JOIN tree_entries e ON e.tree_id = c.tree_id
             WHERE c.commit_id = current_ref.commit_id
               AND d.base_commit_id IS DISTINCT FROM current_ref.commit_id
               AND e.resource_kind = 'memory'
               AND e.scope = d.resource_scope
               AND (
                   (d.target_id IS NOT NULL AND e.item_id = d.target_id)
                   OR
                   (d.target_id IS NULL
                    AND first_operation.action IS DISTINCT FROM 'create'
                    AND e.path = d.path)
               )
             ORDER BY e.item_id
             LIMIT 1
         ) current_entry ON TRUE
         LEFT JOIN LATERAL (
             SELECT c.status, c.candidate_id
             FROM draft_reconciliation_candidates c
             WHERE c.draft_id = d.draft_id
               AND c.draft_version = d.version
               AND c.base_commit_id IS NOT DISTINCT FROM d.base_commit_id
               AND c.current_commit_id IS NOT DISTINCT FROM current_ref.commit_id
               AND c.invalidated_at IS NULL
               AND d.base_commit_id IS DISTINCT FROM current_ref.commit_id
             ORDER BY c.created_at DESC
             LIMIT 1
         ) candidate ON TRUE
         WHERE d.author_user_id = $1
           AND ($2::text IS NULL OR d.project_id = $2)
         ORDER BY d.updated_at DESC
         LIMIT 100",
    )
    .bind(author_user_id)
    .bind(project_id)
    .fetch_all(pool)
    .await?;

    let items = rows
        .iter()
        .map(|row| {
            Ok(Draft {
                draft_id: row.try_get("draft_id")?,
                project_id: row.try_get("project_id")?,
                base_commit_id: row.try_get("base_commit_id")?,
                author: user_ref_from_row(row)?,
                title: row.try_get("title")?,
                description: row.try_get("description")?,
                resource: DraftResourceRef {
                    scope: resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?,
                    id: row.try_get("target_id")?,
                    path: row.try_get("path")?,
                },
                status: draft_status(row.try_get::<String, _>("status")?.as_str())?,
                coordination: draft_coordination_from_projection_row(row)?,
                version: row.try_get("version")?,
                created_at: row.try_get("created_at")?,
                updated_at: row.try_get("updated_at")?,
            })
        })
        .collect::<Result<Vec<_>, ServerError>>()?;
    Ok(DraftListResponse {
        items,
        page_info: page_info(),
    })
}

fn draft_coordination_from_projection_row(
    row: &sqlx::postgres::PgRow,
) -> Result<DraftCoordination, ServerError> {
    let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
    let current_commit_id: Option<String> = row.try_get("current_commit_id")?;
    let freshness = if base_commit_id == current_commit_id {
        DraftFreshness::Current
    } else {
        DraftFreshness::Behind
    };
    let candidate_status: Option<String> = row.try_get("candidate_status")?;
    let reconciliation = if freshness == DraftFreshness::Current {
        DraftReconciliationStatus::Unknown
    } else {
        match candidate_status.as_deref() {
            Some("clean") => DraftReconciliationStatus::Clean,
            Some("conflicts") => DraftReconciliationStatus::Conflicts,
            Some(status) => {
                return Err(ServerError::InvalidRequest(format!(
                    "unknown reconciliation status: {status}"
                )));
            }
            None => DraftReconciliationStatus::Unknown,
        }
    };
    Ok(DraftCoordination {
        freshness,
        current_commit_id,
        has_upstream_resource_changes: row.try_get("has_upstream_resource_changes")?,
        reconciliation,
        candidate_id: row.try_get("candidate_id")?,
    })
}

pub(super) async fn update_draft(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    expected_draft_version: i64,
    request: UpdateDraftRequest,
) -> Result<(), ServerError> {
    let row = sqlx::query(
        "SELECT title, description, status, version, project_id
             FROM drafts
             WHERE draft_id = $1
             FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
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
    if status != "open" && status != "submitted" {
        return Err(ServerError::invalid_transition("draft", &status, "updated"));
    }
    let existing_title: String = row.try_get("title")?;
    let existing_description: String = row.try_get("description")?;
    let title = request.title.unwrap_or(existing_title);
    let description = request.description.unwrap_or(existing_description);
    let updated = sqlx::query(
        "UPDATE drafts
             SET title = $2, description = $3, version = version + 1, updated_at = now()
             WHERE draft_id = $1
             RETURNING project_id, version",
    )
    .bind(draft_id)
    .bind(title)
    .bind(description)
    .fetch_one(&mut **tx)
    .await?;
    invalidate_draft_candidates(tx, draft_id).await?;
    insert_draft_event(
        tx,
        draft_id,
        &updated.try_get::<String, _>("project_id")?,
        DraftEventType::Updated,
        updated.try_get("version")?,
        None,
    )
    .await?;
    Ok(())
}

pub(super) async fn discard_draft(
    tx: &mut Transaction<'_, Postgres>,
    draft_id: &str,
    actor_user_id: &str,
    expected_draft_version: i64,
) -> Result<DeleteResult, ServerError> {
    let row = sqlx::query(
        "SELECT project_id, status, version FROM drafts WHERE draft_id = $1 FOR UPDATE",
    )
    .bind(draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", draft_id))?;
    let version: i64 = row.try_get("version")?;
    if version != expected_draft_version {
        return Err(ServerError::version_conflict(
            "draft",
            expected_draft_version,
            version,
        ));
    }
    let status: String = row.try_get("status")?;
    if status != "open" && status != "submitted" {
        return Err(ServerError::invalid_transition(
            "draft",
            &status,
            "discarded",
        ));
    }
    let next_version: i64 = sqlx::query_scalar(
        "UPDATE drafts SET status = 'discarded', version = version + 1, updated_at = now()
             WHERE draft_id = $1 RETURNING version",
    )
    .bind(draft_id)
    .fetch_one(&mut **tx)
    .await?;
    invalidate_draft_candidates(tx, draft_id).await?;
    sqlx::query(
        "UPDATE reviews
             SET status = 'rejected', version = version + 1,
                 decision_body = 'Draft discarded.', approved_result_hash = NULL,
                 decided_by_user_id = $2, decided_at = now(),
                 updated_at = now()
             WHERE draft_id = $1 AND status IN ('open', 'approved')",
    )
    .bind(draft_id)
    .bind(actor_user_id)
    .execute(&mut **tx)
    .await?;
    insert_draft_event(
        tx,
        draft_id,
        &row.try_get::<String, _>("project_id")?,
        DraftEventType::Discarded,
        next_version,
        None,
    )
    .await?;
    Ok(DeleteResult {
        deleted: true,
        id: draft_id.to_owned(),
    })
}

pub(super) async fn create_draft_operation_batch(
    tx: &mut Transaction<'_, Postgres>,
    request: DraftOperationBatchRequest,
) -> Result<DraftOperationBatchResponse, ServerError> {
    if request.operations.is_empty() {
        return Err(ServerError::InvalidRequest(
            "draft operation batch cannot be empty".to_owned(),
        ));
    }
    let draft_ids = request
        .operations
        .iter()
        .map(|item| item.draft_id.clone())
        .collect::<Vec<_>>();
    let rows = sqlx::query(
        "SELECT DISTINCT project.org_id
             FROM drafts AS draft
             JOIN projects AS project ON project.project_id = draft.project_id
             WHERE draft.draft_id = ANY($1)
               AND draft.resource_scope = 'org'
             ORDER BY project.org_id",
    )
    .bind(&draft_ids)
    .fetch_all(&mut **tx)
    .await?;
    for row in rows {
        lock_org_draft_selection_coordination(tx, &row.try_get::<String, _>("org_id")?).await?;
    }
    let mut accepted_operations = Vec::new();
    let mut cursor = None;
    let daemon_installation_id = request.daemon_installation_id;
    for item in request.operations {
        cursor = Some(
            append_draft_operation_in_tx(
                tx,
                &item.draft_id,
                item.expected_draft_version,
                item.operation,
                Some(&daemon_installation_id),
                true,
            )
            .await?,
        );
        accepted_operations.push(item.local_operation_id);
    }
    Ok(DraftOperationBatchResponse {
        cursor: cursor.expect("non-empty batch").to_string(),
        accepted_operations,
    })
}

pub(super) async fn list_draft_events(
    pool: &PgPool,
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
        let after_sequence = after_cursor
            .parse::<i64>()
            .map_err(|_| ServerError::InvalidRequest("invalid draft event cursor".to_owned()))?;
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
        .fetch_all(pool)
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
        .fetch_all(pool)
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

pub(super) fn draft_event_from_row(row: &sqlx::postgres::PgRow) -> Result<DraftEvent, ServerError> {
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

pub(super) async fn list_reviews(
    tx: &mut Transaction<'_, Postgres>,
    principal: &AuthPrincipal,
    project_id: Option<&str>,
) -> Result<ReviewListResponse, ServerError> {
    let rows = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                r.review_id, r.project_id, r.draft_id, r.title, r.description,
                r.status, r.version, r.decision_body, r.approved_result_hash,
                r.decided_at, r.created_at, r.updated_at,
                u.user_id, u.email, u.display_name, u.avatar_url, u.role,
                du.user_id AS decision_user_id, du.email AS decision_user_email,
                du.display_name AS decision_user_display_name,
                du.avatar_url AS decision_user_avatar_url, du.role AS decision_user_role
             FROM reviews r
             JOIN users u ON u.user_id = r.author_user_id
             LEFT JOIN users du ON du.user_id = r.decided_by_user_id
             JOIN projects p ON p.project_id = r.project_id
             JOIN project_members m ON m.project_id = p.project_id
             WHERE r.project_id = $1 AND p.org_id = $2 AND m.user_id = $3
             ORDER BY r.updated_at DESC, r.review_id
             LIMIT 200",
        )
        .bind(project_id)
        .bind(&principal.org_id)
        .bind(&principal.user_id)
        .fetch_all(&mut **tx)
        .await?
    } else {
        sqlx::query(
            "SELECT
                r.review_id, r.project_id, r.draft_id, r.title, r.description,
                r.status, r.version, r.decision_body, r.approved_result_hash,
                r.decided_at, r.created_at, r.updated_at,
                u.user_id, u.email, u.display_name, u.avatar_url, u.role,
                du.user_id AS decision_user_id, du.email AS decision_user_email,
                du.display_name AS decision_user_display_name,
                du.avatar_url AS decision_user_avatar_url, du.role AS decision_user_role
             FROM reviews r
             JOIN users u ON u.user_id = r.author_user_id
             LEFT JOIN users du ON du.user_id = r.decided_by_user_id
             JOIN projects p ON p.project_id = r.project_id
             JOIN project_members m ON m.project_id = p.project_id
             WHERE p.org_id = $1 AND m.user_id = $2
             ORDER BY r.updated_at DESC, r.review_id
             LIMIT 200",
        )
        .bind(&principal.org_id)
        .bind(&principal.user_id)
        .fetch_all(&mut **tx)
        .await?
    };
    let review_ids = rows
        .iter()
        .map(|row| row.try_get::<String, _>("review_id"))
        .collect::<Result<Vec<_>, _>>()?;
    let mut projections = load_review_list_projections(tx, &review_ids).await?;
    let mut items = Vec::with_capacity(review_ids.len());
    for row in rows {
        let review_id: String = row.try_get("review_id")?;
        let (draft_ids, coordinations) = projections.remove(&review_id).ok_or_else(|| {
            ServerError::InvalidRequest(format!("review {review_id} has no drafts"))
        })?;
        items.push(review_from_row(
            &row,
            draft_ids,
            aggregate_draft_coordination(&coordinations),
        )?);
    }
    Ok(ReviewListResponse {
        items,
        page_info: page_info(),
    })
}

pub(super) async fn create_review_comment(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
    author_user_id: &str,
    request: CreateReviewCommentRequest,
) -> Result<ReviewComment, ServerError> {
    if request.body.trim().is_empty() {
        return Err(ServerError::InvalidRequest(
            "review comment body must not be empty".to_owned(),
        ));
    }
    let anchor = match (request.anchor_path.as_deref(), request.anchor_line) {
        (None, None) => None,
        (Some(path), Some(line)) if !path.is_empty() && line > 0 => Some((path, line)),
        (Some(_), Some(_)) => {
            return Err(ServerError::InvalidRequest(
                "review comment anchor_path must not be empty and anchor_line must be positive"
                    .to_owned(),
            ));
        }
        _ => {
            return Err(ServerError::InvalidRequest(
                "review comment anchor_path and anchor_line must be provided together".to_owned(),
            ));
        }
    };
    let review_row = sqlx::query(
        "SELECT draft_id, version
             FROM reviews
             WHERE review_id = $1
             FOR UPDATE",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("review", review_id))?;
    let review_version: i64 = review_row.try_get("version")?;
    if review_version != request.expected_review_version {
        return Err(ServerError::version_conflict(
            "review",
            request.expected_review_version,
            review_version,
        ));
    }
    if let Some((anchor_path, anchor_line)) = anchor {
        let draft_ids = load_review_draft_ids(tx, review_id).await?;
        let mut matching_state = None;
        for draft_id in draft_ids {
            let state = draft_result_state(tx, &draft_id).await?;
            if state.exists && state.resource.path.as_deref() == Some(anchor_path) {
                matching_state = Some(state);
                break;
            }
        }
        let Some(final_state) = matching_state else {
            return Err(ServerError::InvalidRequest(format!(
                "review comment anchor_path must match a final review path ({anchor_path})"
            )));
        };
        let line_count = final_state
            .content
            .as_ref()
            .map(|content| review_comment_line_count(content_text(content)))
            .unwrap_or(0);
        if anchor_line > line_count {
            return Err(ServerError::InvalidRequest(format!(
                "review comment anchor_line {anchor_line} is outside the final review line range 1..={line_count}"
            )));
        }
    }
    user_ref(tx, author_user_id).await?;
    let comment_id = prefixed_id("cmt");
    sqlx::query(
        "INSERT INTO review_comments (
                comment_id, review_id, author_user_id, body, anchor_path, anchor_line,
                review_version
             )
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(&comment_id)
    .bind(review_id)
    .bind(author_user_id)
    .bind(&request.body)
    .bind(request.anchor_path.as_deref())
    .bind(request.anchor_line)
    .bind(review_version)
    .execute(&mut **tx)
    .await?;
    let comments = load_review_comments(tx, review_id).await?;
    let comment = comments
        .into_iter()
        .find(|comment| comment.comment_id == comment_id)
        .ok_or_else(|| ServerError::not_found("review_comment", &comment_id))?;
    Ok(comment)
}

pub(super) async fn create_review_decision(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
    decided_by_user_id: &str,
    request: CreateReviewDecisionRequest,
) -> Result<ReviewDetail, ServerError> {
    let row = sqlx::query(
        "SELECT r.status AS review_status, r.version AS review_version
             FROM reviews r
             WHERE r.review_id = $1
             FOR UPDATE OF r",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
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
    let draft_ids = load_review_draft_ids(tx, review_id).await?;
    for draft_id in &draft_ids {
        let draft_status: String =
            sqlx::query_scalar("SELECT status FROM drafts WHERE draft_id = $1 FOR UPDATE")
                .bind(draft_id)
                .fetch_one(&mut **tx)
                .await?;
        if draft_status != "submitted" {
            return Err(ServerError::invalid_transition(
                "draft",
                &draft_status,
                "review_decided",
            ));
        }
    }

    let next_status = match request.decision {
        ReviewDecision::Approved => "approved",
        ReviewDecision::Rejected => "rejected",
    };
    let approved_result_hash = if request.decision == ReviewDecision::Approved {
        Some(review_result_hash(tx, &draft_ids).await?)
    } else {
        None
    };
    if request.decision == ReviewDecision::Rejected {
        for draft_id in &draft_ids {
            let reopened = sqlx::query(
                "UPDATE drafts
                     SET status = 'open', version = version + 1, updated_at = now()
                     WHERE draft_id = $1
                     RETURNING project_id, version",
            )
            .bind(draft_id)
            .fetch_one(&mut **tx)
            .await?;
            invalidate_draft_candidates(tx, draft_id).await?;
            insert_draft_event(
                tx,
                draft_id,
                &reopened.try_get::<String, _>("project_id")?,
                DraftEventType::Reopened,
                reopened.try_get("version")?,
                None,
            )
            .await?;
        }
    }
    sqlx::query(
        "UPDATE reviews
             SET status = $2, version = version + 1, decision_body = $3,
                 approved_result_hash = $4, decided_by_user_id = $5,
                 decided_at = now(), updated_at = now()
             WHERE review_id = $1",
    )
    .bind(review_id)
    .bind(next_status)
    .bind(&request.body)
    .bind(&approved_result_hash)
    .bind(decided_by_user_id)
    .execute(&mut **tx)
    .await?;

    let detail = load_review_detail(tx, review_id).await?;
    Ok(detail)
}

pub(super) async fn create_review(
    tx: &mut Transaction<'_, Postgres>,
    author_user_id: &str,
    expected_ref: Option<&str>,
    request: CreateReviewRequest,
    requested_drafts: Vec<(String, i64)>,
) -> Result<CommitOutcome<ReviewDetail>, ServerError> {
    let (primary_draft_id, primary_expected_version) = requested_drafts
        .first()
        .cloned()
        .expect("service validates non-empty review drafts");
    let mut row = sqlx::query(
        "SELECT draft_id, project_id, author_user_id, title, description, status, version,
                    base_commit_id, resource_scope
             FROM drafts
             WHERE draft_id = $1
             FOR UPDATE",
    )
    .bind(&primary_draft_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("draft", &primary_draft_id))?;

    if row.try_get::<String, _>("author_user_id")? != author_user_id {
        return Err(ServerError::Forbidden(
            "only the draft author can create its review".to_owned(),
        ));
    }
    let mut status: String = row.try_get("status")?;
    let version: i64 = row.try_get("version")?;
    if status != "open" {
        return Err(ServerError::invalid_transition(
            "draft",
            &status,
            "submitted",
        ));
    }
    if version != primary_expected_version {
        return Err(ServerError::version_conflict(
            "draft",
            primary_expected_version,
            version,
        ));
    }
    let project_id: String = row.try_get("project_id")?;
    let scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
    ensure_publishable_draft_scope(scope)?;
    let current_ref = target_ref_for_draft(tx, &project_id, scope).await?;
    if current_ref.as_deref() != expected_ref {
        return Err(ServerError::precondition_failed(
            expected_ref,
            current_ref.as_deref(),
        ));
    }
    let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
    if base_commit_id != current_ref {
        let Some(candidate_id) = request.candidate_id.clone() else {
            let candidate = create_reconciliation_candidate_in_tx(
                tx,
                &primary_draft_id,
                primary_expected_version,
            )
            .await?;
            return Ok(CommitOutcome::Failure(
                ServerError::ReconciliationRequired {
                    draft_id: primary_draft_id,
                    candidate_id: candidate.candidate_id,
                    current_commit_id: candidate.current_commit_id,
                },
            ));
        };
        apply_draft_rebase_in_tx(
            tx,
            &primary_draft_id,
            author_user_id,
            expected_ref,
            CreateDraftRebaseRequest {
                candidate_id,
                expected_draft_version: primary_expected_version,
                resolved_state: request.resolved_state.clone(),
            },
        )
        .await?;
        row = sqlx::query(
            "SELECT draft_id, project_id, author_user_id, title, description, status, version,
                        base_commit_id, resource_scope
                 FROM drafts WHERE draft_id = $1 FOR UPDATE",
        )
        .bind(&primary_draft_id)
        .fetch_one(&mut **tx)
        .await?;
        status = row.try_get("status")?;
    } else if request.candidate_id.is_some() || request.resolved_state.is_some() {
        return Err(ServerError::InvalidRequest(
            "a current draft must not submit reconciliation data".to_owned(),
        ));
    }
    if status != "open" {
        return Err(ServerError::invalid_transition(
            "draft",
            &status,
            "submitted",
        ));
    }
    let operations = load_draft_operations(tx, &primary_draft_id).await?;
    if operations.is_empty() {
        return Err(ServerError::InvalidRequest(
            "a review draft must contain at least one operation".to_owned(),
        ));
    }
    if scope == ResourceScope::Org {
        let org_id = project_org_id(tx, &project_id).await?;
        validate_stored_org_draft_operations_are_selected(
            tx,
            &project_id,
            &org_id,
            current_ref.as_deref(),
            &operations,
        )
        .await?;
    }

    for (additional_draft_id, expected_version) in requested_drafts.iter().skip(1) {
        let additional = sqlx::query(
            "SELECT project_id, author_user_id, status, version, base_commit_id, resource_scope
                 FROM drafts WHERE draft_id = $1 FOR UPDATE",
        )
        .bind(additional_draft_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| ServerError::not_found("draft", additional_draft_id))?;
        if additional.try_get::<String, _>("author_user_id")? != author_user_id {
            return Err(ServerError::Forbidden(
                "only the draft author can create its review".to_owned(),
            ));
        }
        let additional_status: String = additional.try_get("status")?;
        if additional_status != "open" {
            return Err(ServerError::invalid_transition(
                "draft",
                &additional_status,
                "submitted",
            ));
        }
        let actual_version: i64 = additional.try_get("version")?;
        if actual_version != *expected_version {
            return Err(ServerError::version_conflict(
                "draft",
                *expected_version,
                actual_version,
            ));
        }
        if additional.try_get::<String, _>("project_id")? != project_id {
            return Err(ServerError::InvalidRequest(
                "all drafts in a review must belong to the same project".to_owned(),
            ));
        }
        let additional_scope =
            resource_scope(additional.try_get::<String, _>("resource_scope")?.as_str())?;
        ensure_publishable_draft_scope(additional_scope)?;
        if additional_scope != scope {
            return Err(ServerError::InvalidRequest(
                "all drafts in a review must use the same scope".to_owned(),
            ));
        }
        if additional.try_get::<Option<String>, _>("base_commit_id")? != current_ref {
            return Err(ServerError::InvalidRequest(format!(
                "draft {additional_draft_id} must be reconciled before requesting this review"
            )));
        }
        let additional_operations = load_draft_operations(tx, additional_draft_id).await?;
        if additional_operations.is_empty() {
            return Err(ServerError::InvalidRequest(
                "a review draft must contain at least one operation".to_owned(),
            ));
        }
        if scope == ResourceScope::Org {
            let org_id = project_org_id(tx, &project_id).await?;
            validate_stored_org_draft_operations_are_selected(
                tx,
                &project_id,
                &org_id,
                current_ref.as_deref(),
                &additional_operations,
            )
            .await?;
        }
    }

    let review_id = prefixed_id("rev");
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
    .bind(&primary_draft_id)
    .fetch_one(&mut **tx)
    .await?;
    invalidate_draft_candidates(tx, &primary_draft_id).await?;
    insert_draft_event(
        tx,
        &primary_draft_id,
        &draft_event_row.try_get::<String, _>("project_id")?,
        DraftEventType::Submitted,
        draft_event_row.try_get("version")?,
        None,
    )
    .await?;

    for (additional_draft_id, _) in requested_drafts.iter().skip(1) {
        let additional_event_row = sqlx::query(
            "UPDATE drafts
                 SET status = 'submitted', version = version + 1, updated_at = now()
                 WHERE draft_id = $1
                 RETURNING project_id, version",
        )
        .bind(additional_draft_id)
        .fetch_one(&mut **tx)
        .await?;
        invalidate_draft_candidates(tx, additional_draft_id).await?;
        insert_draft_event(
            tx,
            additional_draft_id,
            &additional_event_row.try_get::<String, _>("project_id")?,
            DraftEventType::Submitted,
            additional_event_row.try_get("version")?,
            None,
        )
        .await?;
    }

    sqlx::query(
        "INSERT INTO reviews (
                review_id, draft_id, project_id, author_user_id, title, description,
                status, version
             )
             VALUES ($1, $2, $3, $4, $5, $6, 'open', 1)",
    )
    .bind(&review_id)
    .bind(&primary_draft_id)
    .bind(&project_id)
    .bind(author_user_id)
    .bind(&title)
    .bind(&description)
    .execute(&mut **tx)
    .await?;

    for (ordinal, (draft_id, _)) in requested_drafts.iter().enumerate() {
        sqlx::query(
            "INSERT INTO review_drafts (review_id, draft_id, ordinal)
                 VALUES ($1, $2, $3)",
        )
        .bind(&review_id)
        .bind(draft_id)
        .bind(ordinal as i32)
        .execute(&mut **tx)
        .await?;
    }

    let detail = load_review_detail(tx, &review_id).await?;
    Ok(CommitOutcome::Success(detail))
}

pub(super) async fn create_review_submission(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
    author_user_id: &str,
    expected_ref: Option<&str>,
    request: CreateReviewSubmissionRequest,
) -> Result<CommitOutcome<ReviewDetail>, ServerError> {
    let Some(primary_request) = request.drafts.first() else {
        return Err(ServerError::InvalidRequest(
            "a review must contain at least one draft".to_owned(),
        ));
    };
    let primary_expected_version = primary_request.expected_draft_version;
    let distinct_draft_ids = request
        .drafts
        .iter()
        .map(|draft| &draft.draft_id)
        .collect::<BTreeSet<_>>();
    if distinct_draft_ids.len() != request.drafts.len() {
        return Err(ServerError::InvalidRequest(
            "a review must not contain duplicate drafts".to_owned(),
        ));
    }
    let row = sqlx::query(
        "SELECT r.draft_id, r.status AS review_status, r.version AS review_version,
                    d.project_id, d.author_user_id, d.status AS draft_status,
                    d.version AS draft_version, d.base_commit_id, d.resource_scope
             FROM reviews r
             JOIN drafts d ON d.draft_id = r.draft_id
             WHERE r.review_id = $1
             FOR UPDATE OF r, d",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
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
    if draft_version != primary_expected_version {
        return Err(ServerError::version_conflict(
            "draft",
            primary_expected_version,
            draft_version,
        ));
    }

    let draft_id: String = row.try_get("draft_id")?;
    if primary_request.draft_id != draft_id {
        return Err(ServerError::InvalidRequest(
            "a resubmission must keep the review's primary draft first".to_owned(),
        ));
    }
    let project_id: String = row.try_get("project_id")?;
    let scope = resource_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
    ensure_publishable_draft_scope(scope)?;
    let current_ref = target_ref_for_draft(tx, &project_id, scope).await?;
    if current_ref.as_deref() != expected_ref {
        return Err(ServerError::precondition_failed(
            expected_ref,
            current_ref.as_deref(),
        ));
    }
    let base_commit_id: Option<String> = row.try_get("base_commit_id")?;
    if base_commit_id != current_ref {
        let Some(candidate_id) = request.candidate_id.clone() else {
            let candidate =
                create_reconciliation_candidate_in_tx(tx, &draft_id, primary_expected_version)
                    .await?;
            return Ok(CommitOutcome::Failure(
                ServerError::ReconciliationRequired {
                    draft_id,
                    candidate_id: candidate.candidate_id,
                    current_commit_id: candidate.current_commit_id,
                },
            ));
        };
        apply_draft_rebase_in_tx(
            tx,
            &draft_id,
            author_user_id,
            expected_ref,
            CreateDraftRebaseRequest {
                candidate_id,
                expected_draft_version: primary_expected_version,
                resolved_state: request.resolved_state.clone(),
            },
        )
        .await?;
    } else if request.candidate_id.is_some() || request.resolved_state.is_some() {
        return Err(ServerError::InvalidRequest(
            "a current draft must not submit reconciliation data".to_owned(),
        ));
    }
    if request.drafts.len() > 1
        && (request.candidate_id.is_some() || request.resolved_state.is_some())
    {
        return Err(ServerError::InvalidRequest(
            "reconcile every draft before resubmitting a multi-file review".to_owned(),
        ));
    }
    let operations = load_draft_operations(tx, &draft_id).await?;
    if operations.is_empty() {
        return Err(ServerError::InvalidRequest(
            "a review draft must contain at least one operation".to_owned(),
        ));
    }
    if scope == ResourceScope::Org {
        let org_id = project_org_id(tx, &project_id).await?;
        validate_stored_org_draft_operations_are_selected(
            tx,
            &project_id,
            &org_id,
            current_ref.as_deref(),
            &operations,
        )
        .await?;
    }
    for requested in request.drafts.iter().skip(1) {
        let linked_review_id: Option<String> =
            sqlx::query_scalar("SELECT review_id FROM review_drafts WHERE draft_id = $1")
                .bind(&requested.draft_id)
                .fetch_optional(&mut **tx)
                .await?;
        if linked_review_id
            .as_deref()
            .is_some_and(|linked_review_id| linked_review_id != review_id)
        {
            return Err(ServerError::already_exists(
                "review for draft",
                &requested.draft_id,
            ));
        }
        let additional = sqlx::query(
            "SELECT project_id, author_user_id, status, version, base_commit_id, resource_scope
                 FROM drafts WHERE draft_id = $1 FOR UPDATE",
        )
        .bind(&requested.draft_id)
        .fetch_one(&mut **tx)
        .await?;
        if additional.try_get::<String, _>("author_user_id")? != author_user_id {
            return Err(ServerError::Forbidden(
                "only the draft author can resubmit its review".to_owned(),
            ));
        }
        let additional_status: String = additional.try_get("status")?;
        if additional_status != "open" {
            return Err(ServerError::invalid_transition(
                "draft",
                &additional_status,
                "submitted",
            ));
        }
        let actual_version: i64 = additional.try_get("version")?;
        if actual_version != requested.expected_draft_version {
            return Err(ServerError::version_conflict(
                "draft",
                requested.expected_draft_version,
                actual_version,
            ));
        }
        if additional.try_get::<String, _>("project_id")? != project_id
            || resource_scope(additional.try_get::<String, _>("resource_scope")?.as_str())? != scope
        {
            return Err(ServerError::InvalidRequest(
                "all drafts in a review must share one project and scope".to_owned(),
            ));
        }
        if additional.try_get::<Option<String>, _>("base_commit_id")? != current_ref {
            return Err(ServerError::InvalidRequest(format!(
                "draft {} must be reconciled before resubmitting this review",
                requested.draft_id
            )));
        }
        let operations = load_draft_operations(tx, &requested.draft_id).await?;
        if operations.is_empty() {
            return Err(ServerError::InvalidRequest(
                "a review draft must contain at least one operation".to_owned(),
            ));
        }
        if scope == ResourceScope::Org {
            let org_id = project_org_id(tx, &project_id).await?;
            validate_stored_org_draft_operations_are_selected(
                tx,
                &project_id,
                &org_id,
                current_ref.as_deref(),
                &operations,
            )
            .await?;
        }
    }
    let next_draft_version: i64 = sqlx::query_scalar(
        "UPDATE drafts
             SET status = 'submitted', version = version + 1, updated_at = now()
             WHERE draft_id = $1
             RETURNING version",
    )
    .bind(&draft_id)
    .fetch_one(&mut **tx)
    .await?;
    invalidate_draft_candidates(tx, &draft_id).await?;
    sqlx::query(
        "UPDATE reviews
             SET status = 'open', version = version + 1, decision_body = NULL,
                 approved_result_hash = NULL,
                 decided_by_user_id = NULL, decided_at = NULL,
                 title = COALESCE($2, title), description = COALESCE($3, description),
                 updated_at = now()
             WHERE review_id = $1",
    )
    .bind(review_id)
    .bind(request.title)
    .bind(request.description)
    .execute(&mut **tx)
    .await?;
    insert_draft_event(
        tx,
        &draft_id,
        &project_id,
        DraftEventType::Submitted,
        next_draft_version,
        None,
    )
    .await?;
    for requested in request.drafts.iter().skip(1) {
        let submitted = sqlx::query(
            "UPDATE drafts
                 SET status = 'submitted', version = version + 1, updated_at = now()
                 WHERE draft_id = $1
                 RETURNING project_id, version",
        )
        .bind(&requested.draft_id)
        .fetch_one(&mut **tx)
        .await?;
        invalidate_draft_candidates(tx, &requested.draft_id).await?;
        insert_draft_event(
            tx,
            &requested.draft_id,
            &submitted.try_get::<String, _>("project_id")?,
            DraftEventType::Submitted,
            submitted.try_get("version")?,
            None,
        )
        .await?;
    }

    sqlx::query("DELETE FROM review_drafts WHERE review_id = $1")
        .bind(review_id)
        .execute(&mut **tx)
        .await?;
    for (ordinal, requested) in request.drafts.iter().enumerate() {
        sqlx::query(
            "INSERT INTO review_drafts (review_id, draft_id, ordinal)
                 VALUES ($1, $2, $3)",
        )
        .bind(review_id)
        .bind(&requested.draft_id)
        .bind(ordinal as i32)
        .execute(&mut **tx)
        .await?;
    }

    let detail = load_review_detail(tx, review_id).await?;
    Ok(CommitOutcome::Success(detail))
}

pub(super) async fn create_review_merge(
    tx: &mut Transaction<'_, Postgres>,
    review_id: &str,
    actor_user_id: &str,
    expected_project_ref: Option<&str>,
    request: CreateReviewMergeRequest,
) -> Result<CommitOutcome<ReviewMergeData>, ServerError> {
    let coordination = sqlx::query(
        "SELECT draft.project_id, draft.resource_scope
             FROM reviews AS review
             JOIN drafts AS draft ON draft.draft_id = review.draft_id
             WHERE review.review_id = $1",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(coordination) = coordination
        && resource_scope(
            coordination
                .try_get::<String, _>("resource_scope")?
                .as_str(),
        )? == ResourceScope::Org
    {
        lock_org_draft_selection_coordination_for_project(
            tx,
            &coordination.try_get::<String, _>("project_id")?,
        )
        .await?;
    }
    let row = sqlx::query(
        "SELECT r.project_id, r.status, r.version, r.approved_result_hash
             FROM reviews r
             WHERE r.review_id = $1
             FOR UPDATE OF r",
    )
    .bind(review_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("review", review_id))?;

    let status: String = row.try_get("status")?;
    let version: i64 = row.try_get("version")?;
    if status != "open" && status != "approved" {
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
    let draft_ids = load_review_draft_ids(tx, review_id).await?;
    let mut draft_rows = Vec::with_capacity(draft_ids.len());
    for draft_id in &draft_ids {
        draft_rows.push(
            sqlx::query(
                "SELECT resource_scope, base_commit_id, status, version
                     FROM drafts WHERE draft_id = $1 FOR UPDATE",
            )
            .bind(draft_id)
            .fetch_one(&mut **tx)
            .await?,
        );
    }
    let primary_scope = resource_scope(
        draft_rows
            .first()
            .ok_or_else(|| ServerError::InvalidRequest("a review must contain a draft".to_owned()))?
            .try_get::<String, _>("resource_scope")?
            .as_str(),
    )?;
    ensure_publishable_draft_scope(primary_scope)?;
    for draft_row in &draft_rows {
        let scope = resource_scope(draft_row.try_get::<String, _>("resource_scope")?.as_str())?;
        if scope != primary_scope {
            return Err(ServerError::InvalidRequest(
                "all drafts in a review must use the same scope".to_owned(),
            ));
        }
        let draft_status: String = draft_row.try_get("status")?;
        if draft_status != "submitted" {
            return Err(ServerError::invalid_transition(
                "draft",
                &draft_status,
                "merged",
            ));
        }
    }
    let org_id = project_org_id(tx, &project_id).await?;
    let current_head = match primary_scope {
        ResourceScope::Org => current_org_ref(tx, &org_id).await?,
        ResourceScope::Project => {
            lock_org_ref_for_project_projection(tx, &org_id).await?;
            current_project_ref(tx, &project_id).await?
        }
    };
    if current_head.as_deref() != expected_project_ref {
        return Err(ServerError::precondition_failed(
            expected_project_ref,
            current_head.as_deref(),
        ));
    }
    for (draft_id, draft_row) in draft_ids.iter().zip(&draft_rows) {
        let draft_base_commit_id: Option<String> = draft_row.try_get("base_commit_id")?;
        if draft_base_commit_id != current_head {
            let candidate =
                create_reconciliation_candidate_in_tx(tx, draft_id, draft_row.try_get("version")?)
                    .await?;
            let error = ServerError::ReconciliationRequired {
                draft_id: draft_id.clone(),
                candidate_id: candidate.candidate_id,
                current_commit_id: candidate.current_commit_id,
            };
            return Ok(CommitOutcome::Failure(error));
        }
    }

    let approved_result_hash: Option<String> = row.try_get("approved_result_hash")?;
    let current_result_hash = review_result_hash(tx, &draft_ids).await?;
    if status == "approved" && approved_result_hash.as_deref() != Some(&current_result_hash) {
        return Err(ServerError::InvalidTransition {
            entity: "review",
            from: "approval_for_previous_content".to_owned(),
            to: "merged".to_owned(),
        });
    }

    let mut materialized_operations = Vec::new();
    for draft_id in &draft_ids {
        let operations = load_draft_operations(tx, draft_id).await?;
        materialized_operations.extend(materialize_draft_operations(&operations)?);
    }
    if primary_scope == ResourceScope::Org {
        validate_org_draft_operation_inputs_are_selected(
            tx,
            &project_id,
            &org_id,
            current_head.as_deref(),
            &materialized_operations,
        )
        .await?;
    }
    let org_resource_impact = match primary_scope {
        ResourceScope::Org => {
            resolve_org_resource_impact(tx, &org_id, &materialized_operations).await?
        }
        ResourceScope::Project => OrgResourceImpact::default(),
    };
    let mut created_resource_ids = Vec::new();
    for operation in &materialized_operations {
        if let Some(resource_id) =
            apply_operation(tx, &project_id, primary_scope, operation).await?
        {
            created_resource_ids.push(resource_id);
        }
    }

    let commit_id = match primary_scope {
        ResourceScope::Org => {
            let commit_id = create_org_commit(tx, &org_id, current_head.as_deref()).await?;
            advance_org_ref(tx, &org_id, &commit_id).await?;
            refresh_projects_for_org_resource_changes(tx, &org_id, &org_resource_impact).await?;
            if !created_resource_ids.is_empty() {
                select_created_org_resources_for_project(
                    tx,
                    &project_id,
                    &org_id,
                    &created_resource_ids,
                )
                .await?;
            }
            commit_id
        }
        ResourceScope::Project => {
            let commit_id = create_project_commit(tx, &project_id, current_head.as_deref()).await?;
            advance_project_ref(tx, &project_id, &commit_id).await?;
            commit_id
        }
    };
    sqlx::query(
        "UPDATE reviews
             SET status = 'merged', version = version + 1,
                 decision_body = CASE WHEN $2 THEN NULL ELSE decision_body END,
                 approved_result_hash = CASE WHEN $2 THEN $3 ELSE approved_result_hash END,
                 decided_by_user_id = CASE WHEN $2 THEN $4 ELSE decided_by_user_id END,
                 decided_at = CASE WHEN $2 THEN now() ELSE decided_at END,
                 updated_at = now()
             WHERE review_id = $1",
    )
    .bind(review_id)
    .bind(status == "open")
    .bind(&current_result_hash)
    .bind(actor_user_id)
    .execute(&mut **tx)
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
    .execute(&mut **tx)
    .await?;
    for draft_id in &draft_ids {
        let merged_draft_version: i64 = sqlx::query_scalar(
            "UPDATE drafts
                 SET status = 'merged', version = version + 1, updated_at = now()
                 WHERE draft_id = $1
                 RETURNING version",
        )
        .bind(draft_id)
        .fetch_one(&mut **tx)
        .await?;
        insert_draft_event(
            tx,
            draft_id,
            &project_id,
            DraftEventType::Merged,
            merged_draft_version,
            None,
        )
        .await?;
    }

    Ok(CommitOutcome::Success(ReviewMergeData {
        commit_id,
        applied_operation_count: materialized_operations.len() as i64,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context_state(
        exists: bool,
        path: &str,
        content: Option<&str>,
    ) -> ReconciliationResourceState {
        ReconciliationResourceState {
            exists,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                id: exists.then(|| "mem_test".to_owned()),
                path: Some(path.to_owned()),
            },
            content: content.map(|content| DraftResourceContent {
                description: None,
                content: content.to_owned(),
            }),
        }
    }

    fn assert_clean(
        base: &ReconciliationResourceState,
        current: &ReconciliationResourceState,
        draft: &ReconciliationResourceState,
    ) -> ReconciliationResourceState {
        let (result, conflicts) = merge_resource_states(base, current, draft);
        assert!(conflicts.is_empty(), "unexpected conflicts: {conflicts:?}");
        result.expect("clean reconciliation must produce a state")
    }

    fn assert_conflicts(
        base: &ReconciliationResourceState,
        current: &ReconciliationResourceState,
        draft: &ReconciliationResourceState,
    ) {
        let (result, conflicts) = merge_resource_states(base, current, draft);
        assert!(result.is_none());
        assert!(!conflicts.is_empty());
    }

    #[test]
    fn memory_content_must_not_be_blank() {
        assert!(
            validate_draft_content_shape(&DraftResourceContent {
                description: None,
                content: String::new(),
            })
            .is_err()
        );
        assert!(
            validate_draft_content_shape(&DraftResourceContent {
                description: None,
                content: "  \n".to_owned(),
            })
            .is_err()
        );
        assert!(
            validate_draft_content_shape(&DraftResourceContent {
                description: None,
                content: "# Testing\n\nRun focused tests.".to_owned(),
            })
            .is_ok()
        );
    }

    #[test]
    fn review_comment_line_count_matches_client_line_numbering() {
        assert_eq!(review_comment_line_count(""), 0);
        assert_eq!(review_comment_line_count("one"), 1);
        assert_eq!(review_comment_line_count("one\ntwo"), 2);
        assert_eq!(review_comment_line_count("one\n"), 2);
        assert_eq!(review_comment_line_count("one\n\n"), 3);
    }

    #[test]
    fn reconciliation_merges_non_overlapping_markdown_updates() {
        let base = context_state(
            true,
            "context/guide.md",
            Some("# Guide\n\nalpha: base\n\nmiddle: base\n\nomega: base\n"),
        );
        let current = context_state(
            true,
            "context/guide.md",
            Some("# Guide\n\nalpha: remote\n\nmiddle: base\n\nomega: base\n"),
        );
        let draft = context_state(
            true,
            "context/guide.md",
            Some("# Guide\n\nalpha: base\n\nmiddle: base\n\nomega: local\n"),
        );

        let result = assert_clean(&base, &current, &draft);
        let content = result.content.as_ref().map(content_text).unwrap();
        assert!(content.contains("alpha: remote"));
        assert!(content.contains("omega: local"));
    }

    #[test]
    fn reconciliation_reports_overlapping_markdown_updates() {
        let base = context_state(true, "context/guide.md", Some("# Guide\n\nmode: base\n"));
        let current = context_state(true, "context/guide.md", Some("# Guide\n\nmode: remote\n"));
        let draft = context_state(true, "context/guide.md", Some("# Guide\n\nmode: local\n"));

        assert_conflicts(&base, &current, &draft);
    }

    #[test]
    fn reconciliation_covers_create_rename_and_delete_boundaries() {
        let absent = context_state(false, "context/new.md", None);
        let created = context_state(true, "context/new.md", Some("# Local\n"));
        assert_eq!(assert_clean(&absent, &absent, &created), created);
        let remote_created = context_state(true, "context/new.md", Some("# Remote\n"));
        assert_conflicts(&absent, &remote_created, &created);

        let base = context_state(true, "context/old.md", Some("# Base\n"));
        let remote_content = context_state(true, "context/old.md", Some("# Remote\n"));
        let renamed = context_state(true, "context/new.md", Some("# Base\n"));
        let renamed_result = assert_clean(&base, &remote_content, &renamed);
        assert_eq!(
            renamed_result.resource.path.as_deref(),
            Some("context/new.md")
        );
        assert_eq!(
            renamed_result.content.as_ref().map(content_text),
            Some("# Remote\n")
        );
        let remote_renamed = context_state(true, "context/remote.md", Some("# Base\n"));
        assert_conflicts(&base, &remote_renamed, &renamed);

        let deleted = context_state(false, "context/old.md", None);
        assert_eq!(assert_clean(&base, &base, &deleted), deleted);
        assert_conflicts(&base, &remote_content, &deleted);
        assert_conflicts(&base, &deleted, &remote_content);
    }
}
