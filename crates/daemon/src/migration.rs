use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;

use serde_json::json;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::config::{
    CURRENT_LOCAL_SCHEMA_VERSION, META_MEMORY_CACHE_RESET_REQUIRED,
};
use crate::util::non_empty_string;
use crate::{
    CredentialStore, CredentialStoreError, DaemonConfig, DaemonError, ProjectConfig,
    RuntimeProjectConfig, ServerCredentials,
};
use crate::{agent_adapter, commit_sync, project_storage, retrieval_history, search};

pub(crate) fn prepare_directories(config: &DaemonConfig) -> Result<(), DaemonError> {
    project_storage::ensure_private_directory(&config.root_dir)?;
    project_storage::ensure_private_directory(&config.cache_dir)?;
    project_storage::ensure_private_directory(&config.logs_dir())?;
    Ok(())
}

pub(crate) async fn connect_local_db(path: &Path) -> Result<SqlitePool, DaemonError> {
    let options = SqliteConnectOptions::from_str(&path.display().to_string())?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal);
    Ok(SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?)
}

pub(crate) async fn migrate_local_db(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS daemon_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    let mut existing_schema_version = current_schema_version(pool).await?;
    if existing_schema_version == 13 {
        migrate_local_schema_13_to_14(pool).await?;
        existing_schema_version = 14;
    }
    if existing_schema_version == 14 {
        migrate_local_schema_14_to_15(pool).await?;
        existing_schema_version = 15;
    }
    if existing_schema_version == 15 {
        migrate_local_schema_15_to_16(pool).await?;
        existing_schema_version = 16;
    }
    if existing_schema_version == 16 {
        migrate_local_schema_16_to_17(pool).await?;
        existing_schema_version = 17;
    }
    if existing_schema_version == 17 {
        migrate_local_schema_17_to_18(pool).await?;
        existing_schema_version = 18;
    }
    if existing_schema_version == 18 {
        migrate_local_schema_18_to_19(pool).await?;
        existing_schema_version = 19;
    }
    if existing_schema_version == 19 {
        migrate_local_schema_19_to_20(pool).await?;
        existing_schema_version = 20;
    }
    if existing_schema_version != 0 && existing_schema_version != CURRENT_LOCAL_SCHEMA_VERSION {
        return Err(DaemonError::InvalidConfig(format!(
            "local database schema version {existing_schema_version} is incompatible with version {CURRENT_LOCAL_SCHEMA_VERSION}; recreate the daemon database"
        )));
    }
    sqlx::query(
        "DELETE FROM daemon_meta
         WHERE key IN ('project_config_access_token', 'project_config_refresh_token')",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS local_drafts (
            draft_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            server_draft_id TEXT,
            server_version BIGINT NOT NULL DEFAULT 0,
            base_commit_id TEXT,
            current_commit_id TEXT,
            freshness TEXT NOT NULL CHECK (freshness IN ('current', 'behind')) DEFAULT 'current',
            reconciliation TEXT NOT NULL CHECK (reconciliation IN ('unknown', 'clean', 'conflicts')) DEFAULT 'unknown',
            reconciliation_candidate_id TEXT,
            resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            target_id TEXT,
            path TEXT,
            status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'merged', 'discarded')) DEFAULT 'open',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE INDEX IF NOT EXISTS idx_local_drafts_target_id
         ON local_drafts (target_id)",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_local_drafts_server_draft_id
         ON local_drafts (server_draft_id)
         WHERE server_draft_id IS NOT NULL",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS local_draft_operations (
            local_operation_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL REFERENCES local_drafts(draft_id) ON DELETE CASCADE,
            server_operation_id TEXT,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store', 'server')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'retrying', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS server_response_cache (
            server_url TEXT NOT NULL,
            path TEXT NOT NULL,
            status BIGINT NOT NULL,
            headers_json TEXT NOT NULL,
            body TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (server_url, path)
        )",
    )
    .execute(pool)
    .await?;
    create_project_bindings_table(pool).await?;
    agent_adapter::migrate(pool).await?;
    sqlx::query(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_local_draft_operations_server_operation_id
         ON local_draft_operations (server_operation_id)
         WHERE server_operation_id IS NOT NULL",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE INDEX IF NOT EXISTS idx_local_draft_operations_sync_status
         ON local_draft_operations (sync_status)",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS sync_retries (
            retry_id TEXT PRIMARY KEY,
            channel TEXT NOT NULL CHECK (channel IN ('drafts', 'commits', 'all')),
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS remote_draft_events (
            event_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            version BIGINT NOT NULL,
            daemon_installation_id TEXT,
            created_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    commit_sync::migrate(pool).await?;
    project_storage::migrate(pool).await?;
    search::migrate(pool).await?;
    retrieval_history::migrate(pool).await?;
    sqlx::query(
        "INSERT INTO daemon_meta (key, value)
         VALUES ('schema_version', $1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .bind(CURRENT_LOCAL_SCHEMA_VERSION.to_string())
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn migrate_local_schema_13_to_14(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    for statement in [
        "DROP INDEX IF EXISTS idx_local_drafts_target_id",
        "DROP INDEX IF EXISTS idx_local_drafts_server_draft_id",
        "DROP INDEX IF EXISTS idx_local_draft_operations_server_operation_id",
        "DROP INDEX IF EXISTS idx_local_draft_operations_sync_status",
        "ALTER TABLE local_draft_operations RENAME TO local_draft_operations_v13",
        "ALTER TABLE local_drafts RENAME TO local_drafts_v13",
        "CREATE TABLE local_drafts (
            draft_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            server_draft_id TEXT,
            server_version BIGINT NOT NULL DEFAULT 0,
            base_commit_id TEXT,
            resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            target_id TEXT,
            path TEXT,
            conflict_base_commit_id TEXT,
            conflict_current_commit_id TEXT,
            conflicted_at TEXT,
            status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'discarded', 'conflicted', 'merged')) DEFAULT 'open',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
        "INSERT INTO local_drafts (
            draft_id, project_id, server_draft_id, server_version, base_commit_id,
            resource_scope, resource_kind, target_id, path, conflict_base_commit_id,
            conflict_current_commit_id, conflicted_at, status, created_at, updated_at
         )
         SELECT
            draft_id, project_id, server_draft_id, server_version, base_commit_id,
            resource_scope, resource_kind, target_id, path, conflict_base_commit_id,
            conflict_current_commit_id, conflicted_at, status, created_at, updated_at
         FROM local_drafts_v13
         WHERE resource_kind <> 'metaprompt'",
        "CREATE TABLE local_draft_operations (
            local_operation_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL REFERENCES local_drafts(draft_id) ON DELETE CASCADE,
            server_operation_id TEXT,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store', 'server')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'retrying', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
        "INSERT INTO local_draft_operations (
            local_operation_id, draft_id, server_operation_id, resource_kind,
            operation_json, source, sync_status, last_error, created_at, updated_at
         )
         SELECT
            operation.local_operation_id, operation.draft_id, operation.server_operation_id,
            operation.resource_kind, operation.operation_json, operation.source,
            operation.sync_status, operation.last_error, operation.created_at, operation.updated_at
         FROM local_draft_operations_v13 AS operation
         JOIN local_drafts AS draft ON draft.draft_id = operation.draft_id
         WHERE operation.resource_kind <> 'metaprompt'",
        "DROP TABLE local_draft_operations_v13",
        "DROP TABLE local_drafts_v13",
        "DELETE FROM daemon_meta WHERE key = 'draft_events_cursor'",
        "INSERT INTO daemon_meta (key, value)
         VALUES ('memory_cache_reset_required', '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    migrate_legacy_rule_operations(&mut tx).await?;
    tx.commit().await?;
    Ok(())
}

pub(crate) async fn migrate_local_schema_14_to_15(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    for statement in [
        "DROP INDEX IF EXISTS idx_local_drafts_target_id",
        "DROP INDEX IF EXISTS idx_local_drafts_server_draft_id",
        "DROP INDEX IF EXISTS idx_local_draft_operations_server_operation_id",
        "DROP INDEX IF EXISTS idx_local_draft_operations_sync_status",
        "ALTER TABLE local_draft_operations RENAME TO local_draft_operations_v14",
        "ALTER TABLE local_drafts RENAME TO local_drafts_v14",
        "CREATE TABLE local_drafts (
            draft_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            server_draft_id TEXT,
            server_version BIGINT NOT NULL DEFAULT 0,
            base_commit_id TEXT,
            current_commit_id TEXT,
            freshness TEXT NOT NULL CHECK (freshness IN ('current', 'behind')) DEFAULT 'current',
            reconciliation TEXT NOT NULL CHECK (reconciliation IN ('unknown', 'clean', 'conflicts')) DEFAULT 'unknown',
            reconciliation_candidate_id TEXT,
            resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            target_id TEXT,
            path TEXT,
            status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'merged', 'discarded')) DEFAULT 'open',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
        "INSERT INTO local_drafts (
            draft_id, project_id, server_draft_id, server_version, base_commit_id,
            current_commit_id, freshness, reconciliation, reconciliation_candidate_id,
            resource_scope, resource_kind, target_id, path, status, created_at, updated_at
         )
         SELECT
            draft_id, project_id, server_draft_id, server_version, base_commit_id,
            CASE WHEN status = 'conflicted' THEN conflict_current_commit_id ELSE base_commit_id END,
            CASE WHEN status = 'conflicted' THEN 'behind' ELSE 'current' END,
            'unknown', NULL,
            resource_scope, resource_kind, target_id, path,
            CASE WHEN status = 'conflicted' THEN 'submitted' ELSE status END,
            created_at, updated_at
         FROM local_drafts_v14",
        "CREATE TABLE local_draft_operations (
            local_operation_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL REFERENCES local_drafts(draft_id) ON DELETE CASCADE,
            server_operation_id TEXT,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store', 'server')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'retrying', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
        "INSERT INTO local_draft_operations (
            local_operation_id, draft_id, server_operation_id, resource_kind,
            operation_json, source, sync_status, last_error, created_at, updated_at
         )
         SELECT local_operation_id, draft_id, server_operation_id, resource_kind,
                operation_json, source, sync_status, last_error, created_at, updated_at
         FROM local_draft_operations_v14",
        "DROP TABLE local_draft_operations_v14",
        "DROP TABLE local_drafts_v14",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(())
}

pub(crate) async fn migrate_local_schema_15_to_16(pool: &SqlitePool) -> Result<(), DaemonError> {
    create_project_bindings_table(pool).await
}

pub(crate) async fn migrate_local_schema_16_to_17(pool: &SqlitePool) -> Result<(), DaemonError> {
    project_storage::migrate(pool).await
}

pub(crate) async fn migrate_local_schema_17_to_18(pool: &SqlitePool) -> Result<(), DaemonError> {
    retrieval_history::migrate_schema_17_to_18(pool).await
}

pub(crate) async fn migrate_local_schema_18_to_19(pool: &SqlitePool) -> Result<(), DaemonError> {
    retrieval_history::migrate_schema_18_to_19(pool).await
}

pub(crate) async fn migrate_local_schema_19_to_20(pool: &SqlitePool) -> Result<(), DaemonError> {
    agent_adapter::migrate(pool).await
}

pub(crate) async fn create_project_bindings_table(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS project_bindings (
            server_url TEXT NOT NULL,
            workspace_root TEXT NOT NULL,
            project_id TEXT NOT NULL,
            revision BIGINT NOT NULL CHECK (revision > 0),
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (server_url, workspace_root)
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE INDEX IF NOT EXISTS idx_project_bindings_project
         ON project_bindings (server_url, project_id)",
    )
    .execute(pool)
    .await?;
    Ok(())
}

async fn migrate_legacy_rule_operations(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
) -> Result<(), DaemonError> {
    let rows = sqlx::query(
        "SELECT operation.local_operation_id, operation.operation_json, draft.path
         FROM local_draft_operations AS operation
         JOIN local_drafts AS draft ON draft.draft_id = operation.draft_id
         WHERE operation.resource_kind = 'rule'",
    )
    .fetch_all(&mut **tx)
    .await?;
    for row in rows {
        let operation_id: String = row.try_get("local_operation_id")?;
        let operation_json: String = row.try_get("operation_json")?;
        let fallback_path: Option<String> = row.try_get("path")?;
        let Some(operation_json) =
            flatten_legacy_rule_operation(&operation_json, fallback_path.as_deref())?
        else {
            continue;
        };
        sqlx::query(
            "UPDATE local_draft_operations SET operation_json = $2
             WHERE local_operation_id = $1",
        )
        .bind(operation_id)
        .bind(operation_json)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

fn flatten_legacy_rule_operation(
    operation_json: &str,
    fallback_path: Option<&str>,
) -> Result<Option<String>, DaemonError> {
    let mut operation: serde_json::Value = serde_json::from_str(operation_json)?;
    let mut changed = false;
    for action in ["create", "update"] {
        let Some(action_value) = operation
            .get_mut(action)
            .and_then(|value| value.as_object_mut())
        else {
            continue;
        };
        let fallback_name = action_value
            .get("path")
            .and_then(|value| value.as_str())
            .or(fallback_path)
            .and_then(legacy_rule_name_from_path)
            .unwrap_or("Rule")
            .to_owned();
        let Some(content) = action_value
            .get_mut("content")
            .and_then(|value| value.as_object_mut())
        else {
            continue;
        };
        if content.get("kind").and_then(|value| value.as_str()) != Some("rule") {
            continue;
        }
        let Some(constraint) = content
            .get("constraint")
            .and_then(|value| value.as_str())
            .map(ToOwned::to_owned)
        else {
            continue;
        };
        let name = content
            .get("name")
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(&fallback_name)
            .to_owned();
        let applies_when = content
            .get("applies_when")
            .and_then(|value| value.as_str())
            .unwrap_or_default()
            .to_owned();
        let tags = content
            .get("tags")
            .and_then(|value| value.as_array())
            .map(|values| {
                values
                    .iter()
                    .filter_map(|value| value.as_str().map(ToOwned::to_owned))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        *content = serde_json::Map::from_iter([
            ("kind".to_owned(), json!("rule")),
            (
                "content".to_owned(),
                json!(render_legacy_rule_markdown(
                    &name,
                    &applies_when,
                    &constraint,
                    &tags,
                )),
            ),
        ]);
        changed = true;
    }
    if changed {
        Ok(Some(serde_json::to_string(&operation)?))
    } else {
        Ok(None)
    }
}

fn legacy_rule_name_from_path(path: &str) -> Option<&str> {
    Path::new(path).file_stem().and_then(|name| name.to_str())
}

fn render_legacy_rule_markdown(
    name: &str,
    applies_when: &str,
    constraint: &str,
    tags: &[String],
) -> String {
    format!(
        "# {name}\n\n## Applies when\n\n{applies_when}\n\n## Constraint\n\n{constraint}\n\nTags: {}",
        if tags.is_empty() {
            "None".to_owned()
        } else {
            tags.join(", ")
        }
    )
}

pub(crate) async fn reset_memory_cache_if_required(
    pool: &SqlitePool,
    cache_dir: &Path,
) -> Result<(), DaemonError> {
    let required: Option<String> =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = $1")
            .bind(META_MEMORY_CACHE_RESET_REQUIRED)
            .fetch_optional(pool)
            .await?;
    if required.as_deref() != Some("1") {
        return Ok(());
    }

    let mut tx = pool.begin().await?;
    for statement in [
        "DELETE FROM cached_refs",
        "DELETE FROM cached_commits",
        "DELETE FROM cached_trees",
        "DELETE FROM cached_blobs",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    tx.commit().await?;

    match std::fs::remove_dir_all(cache_dir.join("projects")) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }

    sqlx::query("DELETE FROM daemon_meta WHERE key = $1")
        .bind(META_MEMORY_CACHE_RESET_REQUIRED)
        .execute(pool)
        .await?;
    Ok(())
}

pub(crate) async fn current_schema_version(pool: &SqlitePool) -> Result<i64, DaemonError> {
    let value: Option<String> =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'schema_version'")
            .fetch_optional(pool)
            .await?;
    Ok(value
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or_default())
}

pub(crate) async fn load_or_create_installation_id(
    pool: &SqlitePool,
) -> Result<String, DaemonError> {
    if let Some(value) = sqlx::query_scalar::<_, String>(
        "SELECT value FROM daemon_meta WHERE key = 'daemon_installation_id'",
    )
    .fetch_optional(pool)
    .await?
    .filter(|value| !value.trim().is_empty())
    {
        return Ok(value);
    }

    let value = format!("daemon_{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO daemon_meta (key, value)
         VALUES ('daemon_installation_id', $1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .bind(&value)
    .execute(pool)
    .await?;
    Ok(value)
}

pub(crate) async fn load_project_config(
    pool: &SqlitePool,
    defaults: &ProjectConfig,
    credentials: Option<ServerCredentials>,
) -> Result<RuntimeProjectConfig, DaemonError> {
    let server_url = load_meta_value(pool, "project_config_server_url")
        .await?
        .unwrap_or_else(|| defaults.server_url.clone());
    let project_id = load_meta_value(pool, "project_config_project_id")
        .await?
        .or_else(|| defaults.project_id.clone());
    let credentials = credentials.filter(|credentials| credentials.server_url == server_url);
    Ok(RuntimeProjectConfig {
        server_url,
        project_id,
        access_token: credentials
            .as_ref()
            .map(|credentials| credentials.access_token.clone()),
        refresh_token: credentials.and_then(|credentials| credentials.refresh_token),
    })
}

pub(crate) async fn save_project_metadata(
    pool: &SqlitePool,
    config: &ProjectConfig,
) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    upsert_meta_value(
        &mut tx,
        "project_config_server_url",
        Some(&config.server_url),
    )
    .await?;
    upsert_meta_value(
        &mut tx,
        "project_config_project_id",
        config.project_id.as_deref(),
    )
    .await?;
    tx.commit().await?;
    Ok(())
}

pub(crate) async fn load_server_credentials(
    credential_store: Arc<dyn CredentialStore>,
) -> Result<Option<ServerCredentials>, DaemonError> {
    let credentials = tokio::task::spawn_blocking(move || credential_store.load())
        .await
        .map_err(|error| {
            DaemonError::CredentialStore(CredentialStoreError::new(format!(
                "credential worker failed: {error}"
            )))
        })??;
    Ok(credentials)
}

pub(crate) async fn replace_server_credentials(
    credential_store: Arc<dyn CredentialStore>,
    credentials: Option<ServerCredentials>,
) -> Result<(), DaemonError> {
    tokio::task::spawn_blocking(move || match credentials {
        Some(credentials) => credential_store.replace(&credentials),
        None => credential_store.clear(),
    })
    .await
    .map_err(|error| {
        DaemonError::CredentialStore(CredentialStoreError::new(format!(
            "credential worker failed: {error}"
        )))
    })??;
    Ok(())
}

pub(crate) async fn load_meta_value(
    pool: &SqlitePool,
    key: &str,
) -> Result<Option<String>, DaemonError> {
    Ok(
        sqlx::query_scalar::<_, String>("SELECT value FROM daemon_meta WHERE key = $1")
            .bind(key)
            .fetch_optional(pool)
            .await?
            .and_then(non_empty_string),
    )
}

pub(crate) async fn upsert_meta_timestamp(pool: &SqlitePool, key: &str) -> Result<(), DaemonError> {
    sqlx::query(
        "INSERT INTO daemon_meta (key, value)
         VALUES ($1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .bind(key)
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn upsert_meta_value(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    key: &str,
    value: Option<&str>,
) -> Result<(), DaemonError> {
    if let Some(value) = value.and_then(|value| non_empty_string(value.to_owned())) {
        sqlx::query(
            "INSERT INTO daemon_meta (key, value)
             VALUES ($1, $2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .bind(key)
        .bind(value)
        .execute(&mut **tx)
        .await?;
    } else {
        sqlx::query("DELETE FROM daemon_meta WHERE key = $1")
            .bind(key)
            .execute(&mut **tx)
            .await?;
    }
    Ok(())
}
