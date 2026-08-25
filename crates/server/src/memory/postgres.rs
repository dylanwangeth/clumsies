use crate::api::*;
use crate::auth::AuthPrincipal;
use crate::repository::ServerError;
use crate::shared::*;

use sqlx::{PgPool, Postgres, Row, Transaction};
use std::collections::{BTreeMap, BTreeSet};
use time::OffsetDateTime;

pub(super) async fn insert_bundle_items(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    org_id: &str,
    resource_ids: &[String],
) -> Result<(), ServerError> {
    for (position, resource_id) in resource_ids.iter().enumerate() {
        let exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (
                SELECT 1
                FROM resources
                WHERE resource_id = $1
                  AND org_id = $2
                  AND scope = 'org'
                  AND status = 'active'
            )",
        )
        .bind(resource_id)
        .bind(org_id)
        .fetch_one(&mut **tx)
        .await?;
        if !exists {
            return Err(ServerError::not_found("org_resource", resource_id));
        }
        sqlx::query(
            "INSERT INTO personal_bundle_items (
                bundle_id, resource_id, position
             )
             VALUES ($1, $2, $3)",
        )
        .bind(bundle_id)
        .bind(resource_id)
        .bind(position as i32)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

pub(super) async fn replace_bundle_items_if_present(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    org_id: &str,
    resource_ids: Option<Vec<String>>,
) -> Result<(), ServerError> {
    if let Some(resource_ids) = resource_ids {
        sqlx::query("DELETE FROM personal_bundle_items WHERE bundle_id = $1")
            .bind(bundle_id)
            .execute(&mut **tx)
            .await?;
        insert_bundle_items(tx, bundle_id, org_id, &resource_ids).await?;
    }
    Ok(())
}

pub(super) async fn current_project_org_selection_revision(
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

/// Serializes transitions that can change the relationship between Project
/// selections and active Organization Drafts: replacing a selection,
/// creating/appending a Draft, and merging Organization authority. The lock
/// is Organization-scoped because one delete merge projects into every
/// selecting Project. It is acquired before Draft/ref/selection rows, works
/// across server instances, and therefore avoids opposing row-lock orders.
pub(crate) async fn lock_org_draft_selection_coordination(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "SELECT pg_advisory_xact_lock(
            hashtextextended('org_draft_selection:' || $1, 0)
         )",
    )
    .bind(org_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(crate) async fn lock_org_draft_selection_coordination_for_project(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<(), ServerError> {
    let org_id = project_org_id(tx, project_id).await?;
    lock_org_draft_selection_coordination(tx, &org_id).await
}

pub(super) async fn ensure_removed_org_resources_have_no_active_drafts(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    retained_resource_ids: &[String],
) -> Result<(), ServerError> {
    let blocked = sqlx::query(
        "WITH removed AS (
            SELECT selection.resource_id, resource.org_id
            FROM project_org_resource_selections AS selection
            JOIN resources AS resource
              ON resource.resource_id = selection.resource_id
            WHERE selection.project_id = $1
              AND NOT (selection.resource_id = ANY($2))
         ), active_drafts AS (
            SELECT draft.draft_id, draft.base_commit_id, draft.created_at,
                   draft.target_id, draft.path
            FROM drafts AS draft
            WHERE draft.project_id = $1
              AND draft.resource_scope = 'org'
              AND draft.status IN ('open', 'submitted')
              AND NOT COALESCE((
                    SELECT operation.action = 'create'
                    FROM draft_operations AS operation
                    WHERE operation.draft_id = draft.draft_id
                    ORDER BY operation.ordinal
                    LIMIT 1
              ), FALSE)
         ), targets AS (
            SELECT draft_id, base_commit_id, created_at, target_id, path
            FROM active_drafts
            UNION ALL
            SELECT draft.draft_id, draft.base_commit_id, draft.created_at,
                   operation.target_id, operation.path
            FROM active_drafts AS draft
            JOIN draft_operations AS operation
              ON operation.draft_id = draft.draft_id
            WHERE operation.resource_scope = 'org'
              AND operation.action <> 'create'
         )
         SELECT removed.resource_id, target.draft_id
         FROM removed
         JOIN targets AS target
           ON COALESCE(
                target.target_id,
                (
                    SELECT base_entry.item_id
                    FROM commits AS base_commit
                    JOIN tree_entries AS base_entry
                      ON base_entry.tree_id = base_commit.tree_id
                    WHERE base_commit.commit_id = target.base_commit_id
                      AND base_commit.org_id = removed.org_id
                      AND base_commit.scope = 'org'
                      AND base_entry.scope = 'org'
                      AND base_entry.resource_kind = 'memory'
                      AND base_entry.path = target.path
                ),
                (
                    SELECT resource.resource_id
                    FROM resources AS resource
                    WHERE resource.org_id = removed.org_id
                      AND resource.scope = 'org'
                      AND resource.status = 'active'
                      AND resource.path = target.path
                ),
                (
                    SELECT CASE
                        WHEN COUNT(DISTINCT historical_entry.item_id) = 1
                        THEN MIN(historical_entry.item_id)
                    END
                    FROM commits AS historical_commit
                    JOIN tree_entries AS historical_entry
                      ON historical_entry.tree_id = historical_commit.tree_id
                    WHERE historical_commit.org_id = removed.org_id
                      AND historical_commit.scope = 'org'
                      AND historical_entry.scope = 'org'
                      AND historical_entry.resource_kind = 'memory'
                      AND historical_entry.path = target.path
                )
              ) = removed.resource_id
         ORDER BY removed.resource_id, target.created_at, target.draft_id
         LIMIT 1",
    )
    .bind(project_id)
    .bind(retained_resource_ids)
    .fetch_optional(&mut **tx)
    .await?;
    let Some(blocked) = blocked else {
        return Ok(());
    };
    let resource_id: String = blocked.try_get("resource_id")?;
    let draft_id: String = blocked.try_get("draft_id")?;
    Err(ServerError::InvalidRequest(format!(
        "cannot remove Organization Memory {resource_id} from this Project while active Organization Draft {draft_id} targets it; discard or finish the Draft first"
    )))
}

pub(super) async fn update_project_org_selection_revision(
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

pub(super) async fn insert_project_org_selection_items(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
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
                  AND org_id = $2
                  AND scope = 'org'
                  AND status = 'active'
            )",
        )
        .bind(resource_id)
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

pub(super) async fn load_personal_bundle_detail(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
) -> Result<PersonalBundleDetail, ServerError> {
    let bundle_row = sqlx::query(
        "SELECT
            b.bundle_id, b.owner_user_id, b.name, b.description, b.revision,
            b.created_at, b.updated_at,
            count(i.resource_id) AS resource_count
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
            r.resource_id, r.scope, r.project_id, r.path, r.name, r.description,
            r.status, r.content_hash, r.updated_at
         FROM personal_bundle_items i
         JOIN resources r ON r.resource_id = i.resource_id
         WHERE i.bundle_id = $1 AND r.status = 'active'
         ORDER BY i.position, r.path",
    )
    .bind(bundle_id)
    .fetch_all(&mut **tx)
    .await?;

    let memories = rows
        .iter()
        .map(memory_meta_from_row)
        .collect::<Result<_, _>>()?;

    let bundle = personal_bundle_meta_from_row(&bundle_row)?;
    Ok(PersonalBundleDetail {
        etag: etag(bundle.revision),
        bundle,
        memories,
    })
}

pub(super) async fn list_memory_meta(
    pool: &PgPool,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<MemoryMeta>, ServerError> {
    let rows = list_resource_rows(pool, scope, org_id, project_id).await?;
    rows.iter().map(memory_meta_from_row).collect()
}

pub(super) async fn list_resource_rows(
    pool: &PgPool,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<sqlx::postgres::PgRow>, ServerError> {
    let rows = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                resource_id, scope, project_id, path, name, description, status,
                content_hash, updated_at
             FROM resources
             WHERE scope = $1 AND project_id = $2 AND status = 'active'
             ORDER BY path
             LIMIT 200",
        )
        .bind(scope)
        .bind(project_id)
        .fetch_all(pool)
        .await?
    } else if let Some(org_id) = org_id {
        sqlx::query(
            "SELECT
                resource_id, scope, project_id, path, name, description, status,
                content_hash, updated_at
             FROM resources
             WHERE scope = $1 AND org_id = $2 AND status = 'active'
             ORDER BY path
             LIMIT 200",
        )
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

pub(super) async fn load_memory_detail(
    tx: &mut Transaction<'_, Postgres>,
    memory_id: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<MemoryDetail, ServerError> {
    let row = load_resource_detail_row(tx, memory_id, scope, org_id, project_id).await?;
    let memory = memory_meta_from_row(&row)?;
    Ok(MemoryDetail {
        content: row.try_get("body")?,
        etag: etag(row.try_get("revision")?),
        memory,
    })
}

pub(super) async fn load_resource_detail_row(
    tx: &mut Transaction<'_, Postgres>,
    resource_id: &str,
    scope: &str,
    org_id: Option<&str>,
    project_id: Option<&str>,
) -> Result<sqlx::postgres::PgRow, ServerError> {
    let row = if let Some(project_id) = project_id {
        sqlx::query(
            "SELECT
                resource_id, scope, project_id, path, name, description, status,
                revision, content_hash, body, updated_at
             FROM resources
             WHERE resource_id = $1
               AND scope = $2
               AND project_id = $3
               AND status = 'active'",
        )
        .bind(resource_id)
        .bind(scope)
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
    } else if let Some(org_id) = org_id {
        sqlx::query(
            "SELECT
                resource_id, scope, project_id, path, name, description, status,
                revision, content_hash, body, updated_at
             FROM resources
             WHERE resource_id = $1
               AND scope = $2
               AND org_id = $3
               AND status = 'active'",
        )
        .bind(resource_id)
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

pub(super) fn personal_bundle_meta_from_row(
    row: &sqlx::postgres::PgRow,
) -> Result<PersonalBundleMeta, ServerError> {
    Ok(PersonalBundleMeta {
        bundle_id: row.try_get("bundle_id")?,
        owner_user_id: row.try_get("owner_user_id")?,
        name: row.try_get("name")?,
        description: row.try_get("description")?,
        resource_count: row.try_get::<i64, _>("resource_count")?,
        revision: row.try_get("revision")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

pub(super) fn memory_meta_from_row(row: &sqlx::postgres::PgRow) -> Result<MemoryMeta, ServerError> {
    Ok(MemoryMeta {
        memory_id: row.try_get("resource_id")?,
        scope: resource_scope(row.try_get::<String, _>("scope")?.as_str())?,
        project_id: row.try_get("project_id")?,
        path: row.try_get("path")?,
        name: row.try_get("name")?,
        description: row.try_get("description")?,
        content_hash: row.try_get("content_hash")?,
        status: resource_status(row.try_get::<String, _>("status")?.as_str())?,
        updated_at: row.try_get("updated_at")?,
    })
}

pub(super) fn etag(revision: i64) -> String {
    format!("\"rev-{revision}\"")
}

pub(crate) async fn apply_resource_operation(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    scope: ResourceScope,
    operation: &DraftOperationInput,
) -> Result<Option<String>, ServerError> {
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
            let prepared = prepare_resource_content(path, content, None)?;
            let resource_id = prefixed_id("mem");
            sqlx::query(
                "INSERT INTO resources (
                    resource_id, org_id, project_id, scope, resource_kind, path, name,
                    status, revision, content_hash, body
                 )
                 VALUES ($1, $2, $3, $4, 'memory', $5, $6, 'active', 1, $7, $8)",
            )
            .bind(&resource_id)
            .bind(&org_id)
            .bind(resource_project_id)
            .bind(scope.as_str())
            .bind(path)
            .bind(&prepared.name)
            .bind(content_hash(&prepared.body))
            .bind(&prepared.body)
            .execute(&mut **tx)
            .await?;
            return Ok(Some(resource_id));
        }
        DraftOperationAction::Update => {
            let resource =
                load_target_resource(tx, &org_id, resource_project_id, &operation.resource).await?;
            let content = operation.content.as_ref().ok_or_else(|| {
                ServerError::InvalidRequest("update operation requires content".to_owned())
            })?;
            let prepared = prepare_resource_content(&resource.path, content, Some(&resource))?;
            sqlx::query(
                "UPDATE resources
                 SET name = $2, body = $3, content_hash = $4, revision = revision + 1,
                     status = 'active', updated_at = now()
                 WHERE resource_id = $1",
            )
            .bind(&resource.resource_id)
            .bind(&prepared.name)
            .bind(&prepared.body)
            .bind(content_hash(&prepared.body))
            .execute(&mut **tx)
            .await?;
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
                     name = $3,
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
    Ok(None)
}

/// A new Organization Memory proposed from a Project becomes part of that
/// Project's effective Memory when the Review merges. Existing Organization
/// resources keep their explicit Add/Remove membership semantics.
pub(crate) async fn select_created_org_resources_for_project(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    org_id: &str,
    resource_ids: &[String],
) -> Result<(), ServerError> {
    let parent_commit_id = current_project_ref(tx, project_id).await?;
    let current_revision = current_project_org_selection_revision(tx, project_id).await?;
    let next_revision = current_revision + 1;
    for resource_id in resource_ids {
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
        .execute(&mut **tx)
        .await?;
    }
    validate_project_effective_memory(tx, project_id, org_id).await?;
    update_project_org_selection_revision(tx, project_id, next_revision).await?;
    let commit_id = create_project_commit(tx, project_id, parent_commit_id.as_deref()).await?;
    advance_project_ref(tx, project_id, &commit_id).await?;
    Ok(())
}

pub(super) struct PreparedResourceContent {
    name: String,
    body: String,
}

pub(super) fn prepare_resource_content(
    path: &str,
    content: &DraftResourceContent,
    existing: Option<&TargetResource>,
) -> Result<PreparedResourceContent, ServerError> {
    let body = &content.content;
    Ok(PreparedResourceContent {
        name: existing
            .map(|resource| resource.name.clone())
            .unwrap_or_else(|| name_from_path(path)),
        body: body.clone(),
    })
}

#[derive(Default)]
pub(crate) struct OrgResourceImpact {
    resource_ids: BTreeSet<String>,
    deleted_resource_ids: BTreeSet<String>,
}

pub(crate) async fn resolve_org_resource_impact(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    operations: &[DraftOperationInput],
) -> Result<OrgResourceImpact, ServerError> {
    let mut impact = OrgResourceImpact::default();
    for operation in operations {
        if operation.action == DraftOperationAction::Create {
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

pub(crate) async fn refresh_projects_for_org_resource_changes(
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

pub(super) async fn validate_project_effective_memory(
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
         ORDER BY r.path, r.resource_id",
    )
    .bind(project_id)
    .bind(org_id)
    .fetch_all(&mut **tx)
    .await?;
    let mut output_paths = BTreeMap::new();
    for row in rows {
        let resource_id: String = row.try_get("resource_id")?;
        let path: String = row.try_get("path")?;
        validate_resource_path(&path)?;
        let output_path = materialization_output_path(&path)?;
        insert_materialization_path(
            &mut output_paths,
            &resource_id,
            &output_path,
            "project effective memory",
        )?;
    }

    Ok(())
}

pub(crate) async fn create_project_commit(
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
        "SELECT resource_id, resource_kind, path, name, body, description
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
        "SELECT r.resource_id, r.resource_kind, r.path, r.name, r.body, r.description
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
        description: String::new(),
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

pub(crate) async fn create_org_commit(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    parent_commit_id: Option<&str>,
) -> Result<String, ServerError> {
    let version = sqlx::query_scalar::<_, Option<i64>>(
        "SELECT max(version) FROM commits WHERE scope = 'org' AND org_id = $1",
    )
    .bind(org_id)
    .fetch_one(&mut **tx)
    .await?
    .unwrap_or(0)
        + 1;
    let rows = sqlx::query(
        "SELECT resource_id, resource_kind, path, name, body, description
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
    validate_tree_materialization_paths(&entries)?;
    let tree_id = store_tree(tx, &entries).await?;
    create_commit(tx, "org", org_id, None, &tree_id, parent_commit_id, version).await
}

#[derive(serde::Serialize)]
pub(super) struct PendingTreeEntry {
    item_id: String,
    resource_kind: String,
    scope: String,
    project_id: Option<String>,
    path: Option<String>,
    blob_id: String,
    source: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    description: String,
}

pub(super) fn validate_tree_materialization_paths(
    entries: &[PendingTreeEntry],
) -> Result<(), ServerError> {
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
        validate_resource_path(path)?;
        let output_path = materialization_output_path(path)?;
        insert_materialization_path(&mut paths, &entry.item_id, &output_path, "Commit Tree")?;
    }
    Ok(())
}

pub(super) async fn pending_resource_entry(
    tx: &mut Transaction<'_, Postgres>,
    row: &sqlx::postgres::PgRow,
    scope: &str,
    project_id: Option<&str>,
    source: &str,
) -> Result<PendingTreeEntry, ServerError> {
    let resource_id: String = row.try_get("resource_id")?;
    let body: String = row.try_get("body")?;
    let description: String = row.try_get("description")?;
    let resource_kind: String = row.try_get("resource_kind")?;
    let path: String = row.try_get("path")?;
    validate_resource_path(&path)?;
    match resource_kind.as_str() {
        "memory" => {}
        other => {
            return Err(ServerError::InvalidRequest(format!(
                "unknown resource kind while creating Commit: {other}"
            )));
        }
    }
    Ok(PendingTreeEntry {
        item_id: resource_id,
        resource_kind,
        scope: scope.to_owned(),
        project_id: project_id.map(ToOwned::to_owned),
        path: Some(path),
        blob_id: store_blob(tx, &body).await?,
        source: source.to_owned(),
        description,
    })
}

pub(super) async fn store_blob(
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

pub(super) async fn store_tree(
    tx: &mut Transaction<'_, Postgres>,
    entries: &[PendingTreeEntry],
) -> Result<String, ServerError> {
    let mut canonical_entries = entries.iter().collect::<Vec<_>>();
    canonical_entries.sort_by(|left, right| {
        left.resource_kind
            .cmp(&right.resource_kind)
            .then_with(|| match (&left.path, &right.path) {
                (Some(left), Some(right)) => left.cmp(right),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            })
            .then_with(|| left.item_id.cmp(&right.item_id))
    });
    let encoded = serde_json::to_vec(&canonical_entries)
        .map_err(|error| ServerError::InvalidRequest(format!("failed to encode tree: {error}")))?;
    let tree_id = object_id("tree", &encoded);
    sqlx::query("INSERT INTO trees (tree_id) VALUES ($1) ON CONFLICT DO NOTHING")
        .bind(&tree_id)
        .execute(&mut **tx)
        .await?;
    for entry in entries {
        sqlx::query(
            "INSERT INTO tree_entries (
                tree_id, item_id, resource_kind, scope, project_id, path, blob_id, source,
                description
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
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
        .bind(&entry.description)
        .execute(&mut **tx)
        .await?;
    }
    Ok(tree_id)
}

pub(super) async fn create_commit(
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

pub(super) fn commit_from_row(row: &sqlx::postgres::PgRow) -> Result<Commit, ServerError> {
    Ok(Commit {
        commit_id: row.try_get("commit_id")?,
        scope: commit_scope(row.try_get::<String, _>("scope")?.as_str())?,
        org_id: row.try_get("org_id")?,
        project_id: row.try_get("project_id")?,
        tree_id: row.try_get("tree_id")?,
        parent_commit_id: row.try_get("parent_commit_id")?,
        version: row.try_get("version")?,
        created_at: row.try_get("created_at")?,
    })
}

pub(super) async fn load_commit_metadata(
    tx: &mut Transaction<'_, Postgres>,
    commit_id: &str,
) -> Result<Commit, ServerError> {
    let row = sqlx::query(
        "SELECT commit_id, scope, org_id, project_id, tree_id, parent_commit_id, version, created_at
         FROM commits
         WHERE commit_id = $1",
    )
    .bind(commit_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("commit", commit_id))?;
    commit_from_row(&row)
}

pub(super) async fn load_commit_payload(
    tx: &mut Transaction<'_, Postgres>,
    commit_id: &str,
) -> Result<CommitPayload, ServerError> {
    let commit = load_commit_metadata(tx, commit_id).await?;
    let item_rows = sqlx::query(
        "SELECT e.item_id, e.resource_kind, e.scope, e.project_id, e.path, e.blob_id,
                e.source, e.description, b.content
         FROM tree_entries e
         JOIN blobs b ON b.blob_id = e.blob_id
         WHERE e.tree_id = $1
         ORDER BY e.resource_kind, e.path NULLS LAST, e.item_id",
    )
    .bind(&commit.tree_id)
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
            description: row.try_get("description")?,
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

    if commit.project_id.is_some() && project_org_selection.is_none() {
        return Err(ServerError::InvalidRequest(
            "project commit missing project org selection".to_owned(),
        ));
    }

    Ok(CommitPayload {
        tree: Tree {
            tree_id: commit.tree_id.clone(),
            entries: tree_entries,
        },
        commit,
        blobs: blobs.into_values().collect(),
        project_org_selection,
    })
}

pub(super) async fn load_project_org_selection(
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
            r.resource_id, r.scope, r.project_id, r.path, r.name, r.description,
            r.status, r.content_hash, r.updated_at
         FROM project_org_resource_selections s
         JOIN resources r ON r.resource_id = s.resource_id
         WHERE s.project_id = $1 AND r.status = 'active'
         ORDER BY r.path",
    )
    .bind(project_id)
    .fetch_all(&mut **tx)
    .await?;

    let memories = rows
        .iter()
        .map(memory_meta_from_row)
        .collect::<Result<_, _>>()?;

    Ok(ProjectOrgSelection {
        project_id: project_id.to_owned(),
        memories,
        revision,
    })
}

#[derive(Debug)]
pub(super) struct TargetResource {
    resource_id: String,
    path: String,
    name: String,
}

pub(super) async fn load_target_resource(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    project_id: Option<&str>,
    resource: &DraftResourceRef,
) -> Result<TargetResource, ServerError> {
    let row = if let Some(id) = resource.id.as_deref() {
        sqlx::query(
            "SELECT resource_id, path, name
             FROM resources
             WHERE resource_id = $1 AND org_id = $2 AND scope = $3
               AND (($3 = 'org' AND project_id IS NULL) OR project_id = $4)
               AND status = 'active'
             FOR UPDATE",
        )
        .bind(id)
        .bind(org_id)
        .bind(resource.scope.as_str())
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
    } else if let Some(path) = resource.path.as_deref() {
        sqlx::query(
            "SELECT resource_id, path, name
             FROM resources
             WHERE org_id = $1 AND scope = $2
               AND (($2 = 'org' AND project_id IS NULL) OR project_id = $3)
               AND path = $4
               AND status = 'active'
             FOR UPDATE",
        )
        .bind(org_id)
        .bind(resource.scope.as_str())
        .bind(project_id)
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
    })
}

pub(crate) async fn project_org_id(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<String, ServerError> {
    sqlx::query_scalar::<_, String>("SELECT org_id FROM projects WHERE project_id = $1")
        .bind(project_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| ServerError::not_found("project", project_id))
}

pub(crate) async fn current_project_ref(
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

pub(crate) async fn advance_project_ref(
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
    sqlx::query(
        "UPDATE draft_reconciliation_candidates c
         SET invalidated_at = now()
         FROM drafts d
         WHERE c.draft_id = d.draft_id
           AND d.project_id = $1
           AND d.resource_scope = 'project'
           AND c.invalidated_at IS NULL",
    )
    .bind(project_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(crate) async fn validate_project_commit(
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

pub(crate) async fn validate_org_commit(
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

pub(crate) async fn current_org_ref(
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

pub(crate) async fn lock_org_ref_for_project_projection(
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

pub(crate) async fn advance_org_ref(
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
    sqlx::query(
        "UPDATE draft_reconciliation_candidates c
         SET invalidated_at = now()
         FROM drafts d
         JOIN projects p ON p.project_id = d.project_id
         WHERE c.draft_id = d.draft_id
           AND p.org_id = $1
           AND d.resource_scope = 'org'
           AND c.invalidated_at IS NULL",
    )
    .bind(org_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(crate) async fn load_project_ref(
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

pub(crate) async fn load_org_ref(
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

pub(super) fn ref_from_row(row: &sqlx::postgres::PgRow) -> Result<Ref, ServerError> {
    Ok(Ref {
        name: row.try_get("ref_name")?,
        scope: commit_scope(row.try_get::<String, _>("scope")?.as_str())?,
        org_id: row.try_get("org_id")?,
        project_id: row.try_get("project_id")?,
        commit_id: row.try_get("commit_id")?,
        updated_at: row.try_get("updated_at")?,
    })
}

pub(super) async fn user_ref(
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

pub(super) fn user_ref_from_row(row: &sqlx::postgres::PgRow) -> Result<UserRef, ServerError> {
    Ok(UserRef {
        user_id: row.try_get("user_id")?,
        email: row.try_get("email")?,
        display_name: row.try_get("display_name")?,
        avatar_url: row.try_get("avatar_url")?,
        role: row.try_get("role")?,
    })
}

pub(super) async fn ensure_bundle_owner(
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

pub(super) fn resource_status(value: &str) -> Result<crate::api::ResourceStatus, ServerError> {
    match value {
        "active" => Ok(crate::api::ResourceStatus::Active),
        "deprecated" => Ok(crate::api::ResourceStatus::Deprecated),
        "archived" => Ok(crate::api::ResourceStatus::Archived),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown resource status: {other}"
        ))),
    }
}

pub(super) fn commit_scope(value: &str) -> Result<CommitScope, ServerError> {
    match value {
        "org" => Ok(CommitScope::Org),
        "project" => Ok(CommitScope::Project),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown commit scope: {other}"
        ))),
    }
}

pub(super) fn tree_entry_kind(value: &str) -> Result<TreeEntryKind, ServerError> {
    match value {
        // Legacy kinds from archived pre-unification Commits stay decodable
        // so archived history can still be read; the unified runtime only
        // writes 'memory' and the system 'project_org_selection' entry.
        "rule" | "context" | "workflow" | "memory" => Ok(TreeEntryKind::Memory),
        "project_org_selection" => Ok(TreeEntryKind::ProjectOrgSelection),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown tree entry kind: {other}"
        ))),
    }
}

pub(super) fn tree_entry_scope(value: &str) -> Result<TreeEntryScope, ServerError> {
    match value {
        "org" => Ok(TreeEntryScope::Org),
        "project" => Ok(TreeEntryScope::Project),
        "daemon" => Ok(TreeEntryScope::Daemon),
        other => Err(ServerError::InvalidRequest(format!(
            "unknown tree entry scope: {other}"
        ))),
    }
}

pub(super) fn tree_entry_source(value: &str) -> Result<TreeEntrySource, ServerError> {
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

pub(super) async fn commit_is_accessible(
    pool: &PgPool,
    principal: &AuthPrincipal,
    commit_id: &str,
) -> Result<bool, ServerError> {
    Ok(sqlx::query_scalar::<_, bool>(
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
    .fetch_one(pool)
    .await?)
}

pub(super) async fn insert_org_context(
    tx: &mut Transaction<'_, Postgres>,
    resource_id: &str,
    org_id: &str,
    path: &str,
    body: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "INSERT INTO resources (
            resource_id, org_id, project_id, scope, resource_kind, path, name,
            status, revision, content_hash, body
         )
         VALUES ($1, $2, NULL, 'org', 'memory', $3, $4, 'active', 1, $5, $6)",
    )
    .bind(resource_id)
    .bind(org_id)
    .bind(path)
    .bind(name_from_path(path))
    .bind(content_hash(body))
    .bind(body)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(super) async fn org_resource_exists(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    resource_id: &str,
) -> Result<bool, ServerError> {
    Ok(sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1
            FROM resources
            WHERE resource_id = $1 AND org_id = $2
              AND scope = 'org' AND status = 'active'
         )",
    )
    .bind(resource_id)
    .bind(org_id)
    .fetch_one(&mut **tx)
    .await?)
}

pub(super) async fn upsert_project_org_selection(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
    resource_id: &str,
    revision: i64,
) -> Result<(), ServerError> {
    sqlx::query(
        "INSERT INTO project_org_resource_selections (project_id, resource_id, revision)
         VALUES ($1, $2, $3)
         ON CONFLICT (project_id, resource_id)
         DO UPDATE SET revision = EXCLUDED.revision,
                       updated_at = now()",
    )
    .bind(project_id)
    .bind(resource_id)
    .bind(revision)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(super) async fn delete_project_org_selections(
    tx: &mut Transaction<'_, Postgres>,
    project_id: &str,
) -> Result<(), ServerError> {
    sqlx::query("DELETE FROM project_org_resource_selections WHERE project_id = $1")
        .bind(project_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

pub(super) async fn insert_personal_bundle(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    owner_user_id: &str,
    request: &PersonalBundleRequest,
) -> Result<(), ServerError> {
    sqlx::query(
        "INSERT INTO personal_bundles (
            bundle_id, owner_user_id, name, description, revision
         )
         VALUES ($1, $2, $3, $4, 1)",
    )
    .bind(bundle_id)
    .bind(owner_user_id)
    .bind(&request.name)
    .bind(request.description.as_deref().unwrap_or_default())
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(super) struct PersonalBundleSnapshot {
    pub(super) name: String,
    pub(super) description: String,
    pub(super) revision: i64,
}

pub(super) async fn lock_personal_bundle(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    owner_user_id: &str,
) -> Result<PersonalBundleSnapshot, ServerError> {
    let row = sqlx::query(
        "SELECT name, description, revision
         FROM personal_bundles
         WHERE bundle_id = $1 AND owner_user_id = $2
         FOR UPDATE",
    )
    .bind(bundle_id)
    .bind(owner_user_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("bundle", bundle_id))?;
    Ok(PersonalBundleSnapshot {
        name: row.try_get("name")?,
        description: row.try_get("description")?,
        revision: row.try_get("revision")?,
    })
}

pub(super) async fn update_personal_bundle_metadata(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    name: &str,
    description: &str,
) -> Result<(), ServerError> {
    sqlx::query(
        "UPDATE personal_bundles
         SET name = $2, description = $3, revision = revision + 1, updated_at = now()
         WHERE bundle_id = $1",
    )
    .bind(bundle_id)
    .bind(name)
    .bind(description)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub(super) async fn lock_personal_bundle_revision(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
    owner_user_id: &str,
) -> Result<i64, ServerError> {
    sqlx::query_scalar::<_, i64>(
        "SELECT revision
         FROM personal_bundles
         WHERE bundle_id = $1 AND owner_user_id = $2
         FOR UPDATE",
    )
    .bind(bundle_id)
    .bind(owner_user_id)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(|| ServerError::not_found("bundle", bundle_id))
}

pub(super) async fn delete_personal_bundle(
    tx: &mut Transaction<'_, Postgres>,
    bundle_id: &str,
) -> Result<(), ServerError> {
    sqlx::query("DELETE FROM personal_bundles WHERE bundle_id = $1")
        .bind(bundle_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

pub(super) async fn export_memory_state(
    pool: &PgPool,
    org_id: &str,
) -> Result<MemoryExport, ServerError> {
    let memories = sqlx::query(
        "SELECT resource_id, scope, project_id, path, name, description, status,
                content_hash, body, updated_at
         FROM resources
         WHERE org_id = $1 AND status = 'active'
         ORDER BY scope, path, resource_id",
    )
    .bind(org_id)
    .fetch_all(pool)
    .await?;
    let memories = memories
        .iter()
        .map(|row| {
            Ok(MemoryExportItem {
                memory_id: row.try_get("resource_id")?,
                scope: row.try_get("scope")?,
                project_id: row.try_get("project_id")?,
                path: row.try_get("path")?,
                name: row.try_get("name")?,
                description: row.try_get("description")?,
                status: row.try_get("status")?,
                content_hash: row.try_get("content_hash")?,
                body: row.try_get("body")?,
                updated_at: row
                    .try_get::<time::OffsetDateTime, _>("updated_at")?
                    .format(&time::format_description::well_known::Rfc3339)
                    .map_err(|e| ServerError::InvalidRequest(format!("invalid timestamp: {e}")))?,
            })
        })
        .collect::<Result<Vec<_>, ServerError>>()?;

    let draft_rows = sqlx::query(
        "SELECT d.draft_id, d.project_id, d.title, d.description, d.resource_scope,
                d.target_id, d.path, d.status, d.version
         FROM drafts d
         JOIN projects p ON p.project_id = d.project_id
         WHERE p.org_id = $1
         ORDER BY d.updated_at DESC",
    )
    .bind(org_id)
    .fetch_all(pool)
    .await?;
    let mut drafts = Vec::with_capacity(draft_rows.len());
    for row in draft_rows {
        let draft_id: String = row.try_get("draft_id")?;
        let operations = sqlx::query(
            "SELECT operation_id, action, resource_scope, resource_kind,
                    target_id, path, new_path, content
             FROM draft_operations
             WHERE draft_id = $1
             ORDER BY ordinal",
        )
        .bind(&draft_id)
        .fetch_all(pool)
        .await?
        .iter()
        .map(|operation_row| {
            let action: String = operation_row.try_get("action")?;
            let resource_scope: String = operation_row.try_get("resource_scope")?;
            let resource_kind: String = operation_row.try_get("resource_kind")?;
            let target_id: Option<String> = operation_row.try_get("target_id")?;
            let path: Option<String> = operation_row.try_get("path")?;
            let new_path: Option<String> = operation_row.try_get("new_path")?;
            let content: Option<serde_json::Value> = operation_row.try_get("content")?;
            Ok(serde_json::json!({
                "action": action,
                "resource_scope": resource_scope,
                "resource_kind": resource_kind,
                "target_id": target_id,
                "path": path,
                "new_path": new_path,
                "content": content,
            }))
        })
        .collect::<Result<Vec<_>, ServerError>>()?;
        drafts.push(MemoryExportDraft {
            draft_id,
            project_id: row.try_get("project_id")?,
            title: row.try_get("title")?,
            description: row.try_get("description")?,
            resource_scope: row.try_get("resource_scope")?,
            target_id: row.try_get("target_id")?,
            path: row.try_get("path")?,
            status: row.try_get("status")?,
            version: row.try_get("version")?,
            operations,
        });
    }

    let selections = sqlx::query(
        "SELECT s.project_id, s.revision,
                coalesce(array_agg(sr.resource_id ORDER BY sr.resource_id)
                         FILTER (WHERE sr.resource_id IS NOT NULL), '{}') AS resource_ids
         FROM project_org_selection_states s
         LEFT JOIN project_org_resource_selections sr ON sr.project_id = s.project_id
         JOIN projects p ON p.project_id = s.project_id
         WHERE p.org_id = $1
         GROUP BY s.project_id, s.revision",
    )
    .bind(org_id)
    .fetch_all(pool)
    .await?
    .iter()
    .map(|row| {
        Ok(MemoryExportSelection {
            project_id: row.try_get("project_id")?,
            resource_ids: row.try_get::<Vec<String>, _>("resource_ids")?,
            revision: row.try_get("revision")?,
        })
    })
    .collect::<Result<Vec<_>, ServerError>>()?;

    let bundles = sqlx::query(
        "SELECT b.bundle_id, b.owner_user_id, b.name, b.description, b.revision,
                coalesce(array_agg(bi.resource_id ORDER BY bi.position)
                         FILTER (WHERE bi.resource_id IS NOT NULL), '{}') AS resource_ids
         FROM personal_bundles b
         LEFT JOIN personal_bundle_items bi ON bi.bundle_id = b.bundle_id
         GROUP BY b.bundle_id
         ORDER BY b.bundle_id",
    )
    .fetch_all(pool)
    .await?
    .iter()
    .map(|row| {
        Ok(MemoryExportBundle {
            bundle_id: row.try_get("bundle_id")?,
            owner_user_id: row.try_get("owner_user_id")?,
            name: row.try_get("name")?,
            description: row.try_get("description")?,
            resource_ids: row.try_get::<Vec<String>, _>("resource_ids")?,
            revision: row.try_get("revision")?,
        })
    })
    .collect::<Result<Vec<_>, ServerError>>()?;

    Ok(MemoryExport {
        org_id: org_id.to_owned(),
        exported_at: time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|e| ServerError::InvalidRequest(format!("invalid timestamp: {e}")))?,
        memories,
        drafts,
        selections,
        bundles,
    })
}

pub(super) async fn list_personal_bundles(
    pool: &PgPool,
    owner_user_id: &str,
) -> Result<PersonalBundleListResponse, ServerError> {
    let rows = sqlx::query(
        "SELECT
            b.bundle_id, b.owner_user_id, b.name, b.description, b.revision,
            b.created_at, b.updated_at,
            count(i.resource_id) AS resource_count
         FROM personal_bundles b
         LEFT JOIN personal_bundle_items i ON i.bundle_id = b.bundle_id
         WHERE b.owner_user_id = $1
         GROUP BY b.bundle_id
         ORDER BY b.updated_at DESC
         LIMIT 50",
    )
    .bind(owner_user_id)
    .fetch_all(pool)
    .await?;

    Ok(PersonalBundleListResponse {
        items: rows
            .iter()
            .map(personal_bundle_meta_from_row)
            .collect::<Result<Vec<_>, _>>()?,
        page_info: page_info(),
    })
}

pub(super) async fn list_project_commits(
    pool: &PgPool,
    project_id: &str,
) -> Result<CommitListResponse, ServerError> {
    let rows = sqlx::query(
        "SELECT commit_id, scope, org_id, project_id, tree_id, parent_commit_id,
                version, created_at
         FROM commits
         WHERE scope = 'project' AND project_id = $1
         ORDER BY version DESC
         LIMIT 50",
    )
    .bind(project_id)
    .fetch_all(pool)
    .await?;

    let items = rows.iter().map(commit_from_row).collect::<Result<_, _>>()?;

    Ok(CommitListResponse {
        items,
        page_info: PageInfo {
            next_cursor: None,
            has_more: false,
        },
    })
}

pub(super) async fn list_org_commits(
    pool: &PgPool,
    org_id: &str,
) -> Result<CommitListResponse, ServerError> {
    let rows = sqlx::query(
        "SELECT commit_id, scope, org_id, project_id, tree_id, parent_commit_id,
                version, created_at
         FROM commits
         WHERE scope = 'org' AND org_id = $1
         ORDER BY version DESC
         LIMIT 50",
    )
    .bind(org_id)
    .fetch_all(pool)
    .await?;
    let items = rows.iter().map(commit_from_row).collect::<Result<_, _>>()?;
    Ok(CommitListResponse {
        items,
        page_info: page_info(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending_context_entry(id: &str, path: &str) -> PendingTreeEntry {
        PendingTreeEntry {
            item_id: id.to_owned(),
            resource_kind: "memory".to_owned(),
            scope: "project".to_owned(),
            project_id: Some("prj_test".to_owned()),
            path: Some(path.to_owned()),
            blob_id: format!("blob_{id}"),
            source: "project".to_owned(),
            description: String::new(),
        }
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
