use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;

use serde_json::json;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{Connection, Row, SqlitePool};
use uuid::Uuid;

use crate::config::{CURRENT_LOCAL_SCHEMA_VERSION, META_MEMORY_CACHE_RESET_REQUIRED};
use crate::util::non_empty_string;
use crate::{
    CredentialStore, CredentialStoreError, DaemonConfig, DaemonError, ProjectConfig,
    RuntimeProjectConfig, ServerCredentials,
};
use crate::{
    agent_adapter, commit_sync, project_storage, retrieval_history, search, work_tracking,
};

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
    if existing_schema_version == 20 {
        migrate_local_schema_20_to_21(pool).await?;
        existing_schema_version = 21;
    }
    if existing_schema_version == 21 {
        migrate_local_schema_21_to_22(pool).await?;
        existing_schema_version = 22;
    }
    if existing_schema_version == 22 {
        migrate_local_schema_22_to_23(pool).await?;
        existing_schema_version = 23;
    }
    if existing_schema_version == 23 {
        migrate_local_schema_23_to_24(pool).await?;
        existing_schema_version = 24;
    }
    if existing_schema_version == 24 {
        migrate_local_schema_24_to_25(pool).await?;
        existing_schema_version = 25;
    }
    if existing_schema_version == 25 {
        migrate_local_schema_25_to_26(pool).await?;
        existing_schema_version = 26;
    }
    if existing_schema_version == 26 {
        migrate_local_schema_26_to_27(pool).await?;
        existing_schema_version = 27;
    }
    if existing_schema_version == 27 {
        migrate_local_schema_27_to_28(pool).await?;
        existing_schema_version = 28;
    }
    if existing_schema_version == 28 {
        migrate_local_schema_28_to_29(pool).await?;
        existing_schema_version = 29;
    }
    if existing_schema_version == 29 {
        migrate_local_schema_29_to_30(pool).await?;
        existing_schema_version = 30;
    }
    if existing_schema_version == 30 {
        migrate_local_schema_30_to_31(pool).await?;
        existing_schema_version = 31;
    }
    if existing_schema_version == 31 {
        migrate_local_schema_31_to_32(pool).await?;
        existing_schema_version = 32;
    }
    if existing_schema_version == 32 {
        migrate_local_schema_32_to_33(pool).await?;
        existing_schema_version = 33;
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
            has_upstream_resource_changes INTEGER NOT NULL CHECK (has_upstream_resource_changes IN (0, 1)) DEFAULT 0,
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
    work_tracking::migrate(pool).await?;
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

pub(crate) async fn migrate_local_schema_20_to_21(pool: &SqlitePool) -> Result<(), DaemonError> {
    let local_drafts_exists: bool = sqlx::query_scalar(
        "SELECT EXISTS (
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = 'local_drafts'
         )",
    )
    .fetch_one(pool)
    .await?;
    if !local_drafts_exists {
        return Ok(());
    }
    sqlx::query(
        "ALTER TABLE local_drafts
         ADD COLUMN has_upstream_resource_changes INTEGER NOT NULL
         CHECK (has_upstream_resource_changes IN (0, 1)) DEFAULT 0",
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn migrate_local_schema_21_to_22(pool: &SqlitePool) -> Result<(), DaemonError> {
    work_tracking::migrate(pool).await
}

pub(crate) async fn migrate_local_schema_22_to_23(pool: &SqlitePool) -> Result<(), DaemonError> {
    work_tracking::migrate(pool).await
}

pub(crate) async fn migrate_local_schema_23_to_24(pool: &SqlitePool) -> Result<(), DaemonError> {
    work_tracking::migrate(pool).await
}

pub(crate) async fn migrate_local_schema_24_to_25(pool: &SqlitePool) -> Result<(), DaemonError> {
    work_tracking::migrate(pool).await?;
    let columns = sqlx::query("PRAGMA table_info(native_issues)")
        .fetch_all(pool)
        .await?;
    if !columns
        .iter()
        .any(|row| row.get::<String, _>("name") == "started_at")
    {
        sqlx::query("ALTER TABLE native_issues ADD COLUMN started_at TEXT")
            .execute(pool)
            .await?;
    }
    Ok(())
}

pub(crate) async fn migrate_local_schema_25_to_26(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "CREATE TABLE native_issues_v26 (
            issue_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            issue_number BIGINT NOT NULL CHECK (issue_number BETWEEN 1 AND 999),
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            acceptance_criteria_json TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL CHECK (status IN (
                'todo', 'in_progress', 'closure_requested', 'done'
            )),
            revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
            changed_by_run_id TEXT REFERENCES agent_runs(run_id),
            closure_summary TEXT,
            created_at TEXT NOT NULL,
            started_at TEXT,
            updated_at TEXT NOT NULL,
            closed_at TEXT,
            archived_at TEXT,
            UNIQUE (project_id, issue_number)
        )",
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO native_issues_v26 (
            issue_id, project_id, issue_number, title, description,
            acceptance_criteria_json, status, revision, changed_by_run_id,
            closure_summary, created_at, started_at, updated_at, closed_at,
            archived_at
         )
         SELECT issue_id, project_id, issue_number, title, description,
                acceptance_criteria_json, status, revision, changed_by_run_id,
                closure_summary, created_at, started_at, updated_at, closed_at,
                NULL
         FROM native_issues",
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query("DROP TABLE native_issues")
        .execute(&mut *tx)
        .await?;
    sqlx::query("ALTER TABLE native_issues_v26 RENAME TO native_issues")
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "CREATE INDEX idx_native_issues_project_status
         ON native_issues (project_id, status, issue_number)",
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

pub(crate) async fn migrate_local_schema_27_to_28(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    let table_sql: Option<String> = sqlx::query_scalar(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'agent_runs'",
    )
    .fetch_optional(&mut *tx)
    .await?;
    if table_sql
        .as_deref()
        .is_some_and(|sql| sql.contains("'manual'"))
    {
        tx.commit().await?;
        return Ok(());
    }
    if table_sql.is_none() {
        // A library that never ran the schema-25 migration has no agent_runs
        // table at all; create the v28 shape directly instead of rebuilding.
        for statement in [
            "CREATE TABLE agent_runs (
                run_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                issue_number BIGINT CHECK (issue_number IS NULL OR issue_number > 0),
                host TEXT NOT NULL CHECK (host IN ('codex', 'claude-code', 'zed', 'manual')),
                host_run_key TEXT NOT NULL,
                host_session_id TEXT,
                parent_run_id TEXT REFERENCES agent_runs(run_id),
                kind TEXT NOT NULL CHECK (kind IN ('root', 'subagent')),
                phase TEXT NOT NULL CHECK (phase IN ('running', 'ended')),
                outcome TEXT CHECK (outcome IN ('completed', 'blocked', 'failed', 'cancelled', 'unknown')),
                end_reason TEXT,
                display_label TEXT,
                summary TEXT,
                revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
                start_observed INTEGER NOT NULL DEFAULT 1 CHECK (start_observed IN (0, 1)),
                started_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                lease_expires_at TEXT NOT NULL,
                ended_at TEXT,
                UNIQUE (project_id, host, host_run_key)
            )",
            "CREATE INDEX idx_agent_runs_project_issue_latest
             ON agent_runs (project_id, issue_number, last_seen_at DESC, run_id DESC)",
            "CREATE INDEX idx_agent_runs_running_lease
             ON agent_runs (phase, lease_expires_at)",
            "CREATE INDEX idx_agent_runs_project_session
             ON agent_runs (project_id, host, host_session_id, phase)",
        ] {
            sqlx::query(statement).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        return Ok(());
    }
    for statement in [
        "CREATE TABLE agent_runs_v28 (
            run_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            issue_number BIGINT CHECK (issue_number IS NULL OR issue_number > 0),
            host TEXT NOT NULL CHECK (host IN ('codex', 'claude-code', 'zed', 'manual')),
            host_run_key TEXT NOT NULL,
            host_session_id TEXT,
            parent_run_id TEXT REFERENCES agent_runs(run_id),
            kind TEXT NOT NULL CHECK (kind IN ('root', 'subagent')),
            phase TEXT NOT NULL CHECK (phase IN ('running', 'ended')),
            outcome TEXT CHECK (outcome IN ('completed', 'blocked', 'failed', 'cancelled', 'unknown')),
            end_reason TEXT,
            display_label TEXT,
            summary TEXT,
            revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
            start_observed INTEGER NOT NULL DEFAULT 1 CHECK (start_observed IN (0, 1)),
            started_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            lease_expires_at TEXT NOT NULL,
            ended_at TEXT,
            UNIQUE (project_id, host, host_run_key)
        )",
        "INSERT INTO agent_runs_v28 (
            run_id, project_id, issue_number, host, host_run_key, host_session_id,
            parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
            revision, start_observed, started_at, last_seen_at, lease_expires_at, ended_at
         )
         SELECT run_id, project_id, issue_number, host, host_run_key, host_session_id,
                parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                revision, start_observed, started_at, last_seen_at, lease_expires_at, ended_at
         FROM agent_runs",
        "DROP TABLE agent_runs",
        "ALTER TABLE agent_runs_v28 RENAME TO agent_runs",
        "CREATE INDEX idx_agent_runs_project_issue_latest
         ON agent_runs (project_id, issue_number, last_seen_at DESC, run_id DESC)",
        "CREATE INDEX idx_agent_runs_running_lease
         ON agent_runs (phase, lease_expires_at)",
        "CREATE INDEX idx_agent_runs_project_session
         ON agent_runs (project_id, host, host_session_id, phase)",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(())
}

pub(crate) async fn migrate_local_schema_26_to_27(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut connection = pool.acquire().await?;
    let columns = sqlx::query("PRAGMA table_info(native_issues)")
        .fetch_all(&mut *connection)
        .await?;
    if !columns
        .iter()
        .any(|row| row.get::<String, _>("name") == "external_references_json")
    {
        let result = sqlx::query(
            "ALTER TABLE native_issues
             ADD COLUMN external_references_json TEXT NOT NULL DEFAULT '[]'",
        )
        .execute(&mut *connection)
        .await;
        if let Err(error) = result {
            let columns = sqlx::query("PRAGMA table_info(native_issues)")
                .fetch_all(&mut *connection)
                .await?;
            if !columns
                .iter()
                .any(|row| row.get::<String, _>("name") == "external_references_json")
            {
                return Err(error.into());
            }
        }
    }
    Ok(())
}

pub(crate) async fn migrate_local_schema_28_to_29(pool: &SqlitePool) -> Result<(), DaemonError> {
    work_tracking::migrate(pool).await
}

/// Widen the agent_runs host CHECK constraint to accept the opencode plugin
/// integration host. SQLite cannot alter a CHECK constraint in place, so the
/// table is rebuilt following the same pattern as schema 27 to 28.
///
/// The rebuild drops agent_runs, which issue_workflow_states references via
/// changed_by_run_id. sqlx enables foreign key enforcement by default, so the
/// drop would fail; foreign keys are disabled for this connection during the
/// rebuild only. A single dedicated connection is used because the PRAGMA is
/// per-connection.
pub(crate) async fn migrate_local_schema_29_to_30(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut connection = pool.acquire().await?;
    let table_sql: Option<String> = sqlx::query_scalar(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'agent_runs'",
    )
    .fetch_optional(&mut *connection)
    .await?;
    if table_sql
        .as_deref()
        .is_some_and(|sql| sql.contains("'opencode'"))
    {
        return Ok(());
    }
    if table_sql.is_none() {
        // A library that never ran schema 28 has no agent_runs table at all;
        // the work_tracking::migrate path already creates the widened shape.
        return Ok(());
    }
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&mut *connection)
        .await?;
    let mut tx = connection.begin().await?;
    for statement in [
        "CREATE TABLE agent_runs_v30 (
            run_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            issue_number BIGINT CHECK (issue_number IS NULL OR issue_number > 0),
            host TEXT NOT NULL CHECK (host IN ('codex', 'claude-code', 'zed', 'manual', 'opencode')),
            host_run_key TEXT NOT NULL,
            host_session_id TEXT,
            parent_run_id TEXT REFERENCES agent_runs(run_id),
            kind TEXT NOT NULL CHECK (kind IN ('root', 'subagent')),
            phase TEXT NOT NULL CHECK (phase IN ('running', 'ended')),
            outcome TEXT CHECK (outcome IN ('completed', 'blocked', 'failed', 'cancelled', 'unknown')),
            end_reason TEXT,
            display_label TEXT,
            summary TEXT,
            revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
            start_observed INTEGER NOT NULL DEFAULT 1 CHECK (start_observed IN (0, 1)),
            started_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            lease_expires_at TEXT NOT NULL,
            ended_at TEXT,
            UNIQUE (project_id, host, host_run_key)
        )",
        "INSERT INTO agent_runs_v30 (
            run_id, project_id, issue_number, host, host_run_key, host_session_id,
            parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
            revision, start_observed, started_at, last_seen_at, lease_expires_at, ended_at
         )
         SELECT run_id, project_id, issue_number, host, host_run_key, host_session_id,
                parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                revision, start_observed, started_at, last_seen_at, lease_expires_at, ended_at
         FROM agent_runs",
        "DROP TABLE agent_runs",
        "ALTER TABLE agent_runs_v30 RENAME TO agent_runs",
        "CREATE INDEX idx_agent_runs_project_issue_latest
         ON agent_runs (project_id, issue_number, last_seen_at DESC, run_id DESC)",
        "CREATE INDEX idx_agent_runs_running_lease
         ON agent_runs (phase, lease_expires_at)",
        "CREATE INDEX idx_agent_runs_project_session
         ON agent_runs (project_id, host, host_session_id, phase)",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&mut *connection)
        .await?;
    Ok(())
}

/// Widen the project_agent_adapters adapter CHECK constraint to accept the
/// opencode plugin-hook integration. SQLite cannot alter a CHECK constraint
/// in place, so the table is rebuilt. The table is a child of project_bindings
/// and is referenced by nothing else, so the rebuild is FK-safe on a single
/// transaction.
pub(crate) async fn migrate_local_schema_30_to_31(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    let table_sql: Option<String> = sqlx::query_scalar(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'project_agent_adapters'",
    )
    .fetch_optional(&mut *tx)
    .await?;
    if table_sql
        .as_deref()
        .is_some_and(|sql| sql.contains("'opencode'"))
    {
        tx.commit().await?;
        return Ok(());
    }
    if table_sql.is_none() {
        // A library that never ran schema 20 has no project_agent_adapters
        // table; agent_adapter::migrate creates the widened shape.
        tx.commit().await?;
        return Ok(());
    }
    for statement in [
        "CREATE TABLE project_agent_adapters_v31 (
            server_url TEXT NOT NULL,
            workspace_root TEXT NOT NULL,
            project_id TEXT NOT NULL,
            adapter TEXT NOT NULL CHECK (adapter IN ('codex', 'claude-code', 'opencode')),
            revision BIGINT NOT NULL CHECK (revision > 0),
            manifest_json TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (server_url, workspace_root, adapter),
            FOREIGN KEY (server_url, workspace_root)
                REFERENCES project_bindings(server_url, workspace_root)
                ON DELETE CASCADE
        )",
        "INSERT INTO project_agent_adapters_v31 (
            server_url, workspace_root, project_id, adapter, revision,
            manifest_json, created_at, updated_at
         )
         SELECT server_url, workspace_root, project_id, adapter, revision,
                manifest_json, created_at, updated_at
         FROM project_agent_adapters",
        "DROP TABLE project_agent_adapters",
        "ALTER TABLE project_agent_adapters_v31 RENAME TO project_agent_adapters",
        "CREATE INDEX idx_project_agent_adapters_project
         ON project_agent_adapters (server_url, project_id)",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(())
}

/// Add the Issue verification protocol columns to native_issues.
pub(crate) async fn migrate_local_schema_31_to_32(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut connection = pool.acquire().await?;
    let columns = sqlx::query("PRAGMA table_info(native_issues)")
        .fetch_all(&mut *connection)
        .await?;
    let has_verification_level = columns
        .iter()
        .any(|row| row.get::<String, _>("name") == "verification_level");
    let has_verification_steps = columns
        .iter()
        .any(|row| row.get::<String, _>("name") == "verification_steps_json");
    if !has_verification_level {
        sqlx::query(
            "ALTER TABLE native_issues
             ADD COLUMN verification_level TEXT NOT NULL DEFAULT 'agent_self'
             CHECK (verification_level IN ('agent_self', 'human_required', 'mixed'))",
        )
        .execute(&mut *connection)
        .await?;
    }
    if !has_verification_steps {
        sqlx::query(
            "ALTER TABLE native_issues
             ADD COLUMN verification_steps_json TEXT NOT NULL DEFAULT '[]'",
        )
        .execute(&mut *connection)
        .await?;
    }
    Ok(())
}

/// Add the paused board state to the native_issues.status and
/// issue_workflow_states.open_state CHECK constraints. SQLite cannot alter a
/// CHECK in place, so both tables are rebuilt in a single FK-safe
/// transaction. project_bindings rows are preserved; native_issues is a
/// child of agent_runs via changed_by_run_id (FK kept, rows copied).
pub(crate) async fn migrate_local_schema_32_to_33(pool: &SqlitePool) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    for statement in [
        // Rebuild native_issues with the widened status CHECK.
        "CREATE TABLE native_issues_v33 (
            issue_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            issue_number BIGINT NOT NULL CHECK (issue_number BETWEEN 1 AND 999),
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            acceptance_criteria_json TEXT NOT NULL DEFAULT '[]',
            external_references_json TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL CHECK (status IN (
                'todo', 'in_progress', 'paused', 'closure_requested', 'done'
            )),
            revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
            changed_by_run_id TEXT REFERENCES agent_runs(run_id),
            closure_summary TEXT,
            verification_level TEXT NOT NULL DEFAULT 'agent_self' CHECK (verification_level IN ('agent_self', 'human_required', 'mixed')),
            verification_steps_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            started_at TEXT,
            updated_at TEXT NOT NULL,
            closed_at TEXT,
            archived_at TEXT,
            UNIQUE (project_id, issue_number)
        )",
        "INSERT INTO native_issues_v33 (
            issue_id, project_id, issue_number, title, description,
            acceptance_criteria_json, external_references_json, status, revision,
            changed_by_run_id, closure_summary, verification_level, verification_steps_json,
            created_at, started_at, updated_at, closed_at, archived_at
         )
         SELECT issue_id, project_id, issue_number, title, description,
                acceptance_criteria_json, external_references_json, status, revision,
                changed_by_run_id, closure_summary, verification_level, verification_steps_json,
                created_at, started_at, updated_at, closed_at, archived_at
         FROM native_issues",
        "DROP TABLE native_issues",
        "ALTER TABLE native_issues_v33 RENAME TO native_issues",
        "CREATE INDEX idx_native_issues_project_status
         ON native_issues (project_id, status, issue_number)",
        // Rebuild issue_workflow_states with the widened open_state CHECK.
        "CREATE TABLE issue_workflow_states_v33 (
            project_id TEXT NOT NULL,
            issue_number BIGINT NOT NULL CHECK (issue_number > 0),
            open_state TEXT NOT NULL CHECK (open_state IN (
                'todo', 'in_progress', 'paused', 'closure_requested'
            )),
            observed_lifecycle TEXT NOT NULL CHECK (observed_lifecycle IN ('open', 'closed')),
            revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
            changed_by_run_id TEXT REFERENCES agent_runs(run_id),
            summary TEXT,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (project_id, issue_number)
        )",
        "INSERT INTO issue_workflow_states_v33 (
            project_id, issue_number, open_state, observed_lifecycle, revision,
            changed_by_run_id, summary, updated_at
         )
         SELECT project_id, issue_number, open_state, observed_lifecycle, revision,
                changed_by_run_id, summary, updated_at
         FROM issue_workflow_states",
        "DROP TABLE issue_workflow_states",
        "ALTER TABLE issue_workflow_states_v33 RENAME TO issue_workflow_states",
        "CREATE INDEX idx_issue_workflow_states_project_state
         ON issue_workflow_states (project_id, open_state, updated_at DESC)",
    ] {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    tx.commit().await?;
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
