use std::env;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use axum::extract::{Path as AxumPath, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteRow, SqliteSynchronous,
};
use sqlx::{Row, SqlitePool};
use thiserror::Error;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use uuid::Uuid;

pub const CURRENT_LOCAL_SCHEMA_VERSION: i64 = 3;
const META_DRAFT_EVENTS_CURSOR: &str = "draft_events_cursor";
const META_DRAFT_SYNC_LAST_ATTEMPT_AT: &str = "draft_sync_last_attempt_at";
const META_DRAFT_SYNC_LAST_SUCCESS_AT: &str = "draft_sync_last_success_at";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DaemonConfig {
    pub root_dir: PathBuf,
    pub project: ProjectConfig,
    pub listen_addr: SocketAddr,
    pub sync: SyncConfig,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectConfig {
    pub hub_url: String,
    pub author_user_id: Option<String>,
    pub project_id: Option<String>,
    pub access_token: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncConfig {
    pub enabled: bool,
    pub interval: Duration,
}

impl DaemonConfig {
    pub fn from_env() -> Result<Self, DaemonError> {
        let root_dir = match env::var_os("CLUMSIES_DAEMON_ROOT") {
            Some(value) => PathBuf::from(value),
            None => default_root_dir()?,
        };
        let project = ProjectConfig::from_env();
        let sync = SyncConfig {
            enabled: parse_bool_env("CLUMSIES_SYNC_ENABLED")?.unwrap_or(true),
            interval: Duration::from_millis(
                parse_u64_env("CLUMSIES_SYNC_INTERVAL_MS")?
                    .unwrap_or(30_000)
                    .max(1),
            ),
        };
        let listen_addr = env::var("CLUMSIES_DAEMON_ADDR")
            .unwrap_or_else(|_| "127.0.0.1:0".to_owned())
            .parse()
            .map_err(|error| {
                DaemonError::InvalidConfig(format!("invalid CLUMSIES_DAEMON_ADDR: {error}"))
            })?;
        Ok(Self {
            root_dir,
            project,
            listen_addr,
            sync,
        })
    }

    pub fn for_root(root_dir: impl Into<PathBuf>) -> Self {
        Self {
            root_dir: root_dir.into(),
            project: ProjectConfig::default(),
            listen_addr: SocketAddr::from(([127, 0, 0, 1], 0)),
            sync: SyncConfig {
                enabled: false,
                interval: Duration::from_secs(30),
            },
        }
    }

    pub fn local_db_path(&self) -> PathBuf {
        self.root_dir.join("local.db")
    }

    pub fn logs_dir(&self) -> PathBuf {
        self.root_dir.join("logs")
    }

    pub fn endpoint_file_path(&self) -> PathBuf {
        self.root_dir.join("daemon-endpoint.json")
    }
}

impl Default for ProjectConfig {
    fn default() -> Self {
        Self {
            hub_url: "http://127.0.0.1:8080".to_owned(),
            author_user_id: None,
            project_id: None,
            access_token: None,
        }
    }
}

impl ProjectConfig {
    fn from_env() -> Self {
        Self {
            hub_url: env::var("CLUMSIES_HUB_URL")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "http://127.0.0.1:8080".to_owned()),
            author_user_id: env::var("CLUMSIES_AUTHOR_USER_ID")
                .ok()
                .and_then(non_empty_string),
            project_id: env::var("CLUMSIES_PROJECT_ID")
                .ok()
                .and_then(non_empty_string),
            access_token: env::var("CLUMSIES_ACCESS_TOKEN")
                .ok()
                .and_then(non_empty_string),
        }
    }

    fn validate(&self) -> Result<(), DaemonError> {
        let url = reqwest::Url::parse(&self.hub_url)
            .map_err(|error| DaemonError::InvalidConfig(format!("invalid hub_url: {error}")))?;
        match url.scheme() {
            "http" | "https" => Ok(()),
            scheme => Err(DaemonError::InvalidConfig(format!(
                "hub_url scheme must be http or https, got {scheme}"
            ))),
        }
    }

    fn readiness(&self) -> ProjectConfigReadiness {
        let mut missing_fields = Vec::new();
        if self.hub_url.trim().is_empty() {
            missing_fields.push("hub_url".to_owned());
        }
        if self.author_user_id.as_deref().is_none_or(str::is_empty) {
            missing_fields.push("author_user_id".to_owned());
        }
        if self.project_id.as_deref().is_none_or(str::is_empty) {
            missing_fields.push("project_id".to_owned());
        }
        ProjectConfigReadiness {
            ready: missing_fields.is_empty(),
            missing_fields,
        }
    }
}

#[derive(Clone)]
pub struct DaemonState {
    inner: Arc<DaemonInner>,
}

struct DaemonInner {
    config: DaemonConfig,
    project_config: RwLock<ProjectConfig>,
    pool: SqlitePool,
    http: reqwest::Client,
    daemon_installation_id: String,
    sync_notify: Notify,
    sync_running: AtomicBool,
}

impl DaemonState {
    pub async fn initialize(config: DaemonConfig) -> Result<Self, DaemonError> {
        prepare_directories(&config)?;
        let pool = connect_local_db(&config.local_db_path()).await?;
        migrate_local_db(&pool).await?;
        let daemon_installation_id = load_or_create_installation_id(&pool).await?;
        let project_config = load_project_config(&pool, &config.project).await?;

        Ok(Self {
            inner: Arc::new(DaemonInner {
                config,
                project_config: RwLock::new(project_config),
                pool,
                http: reqwest::Client::new(),
                daemon_installation_id,
                sync_notify: Notify::new(),
                sync_running: AtomicBool::new(false),
            }),
        })
    }

    pub fn local_db_path(&self) -> PathBuf {
        self.inner.config.local_db_path()
    }

    pub fn daemon_installation_id(&self) -> &str {
        &self.inner.daemon_installation_id
    }

    fn project_config(&self) -> ProjectConfig {
        self.inner
            .project_config
            .read()
            .expect("project config rwlock poisoned")
            .clone()
    }

    async fn replace_project_config(
        &self,
        request: DaemonProjectConfigUpdateRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        let project_config = ProjectConfig {
            hub_url: request.hub_url.trim().to_owned(),
            author_user_id: request.author_user_id.and_then(non_empty_string),
            project_id: request.project_id.and_then(non_empty_string),
            access_token: request.access_token.and_then(non_empty_string),
        };
        project_config.validate()?;
        save_project_config(&self.inner.pool, &project_config).await?;
        *self
            .inner
            .project_config
            .write()
            .expect("project config rwlock poisoned") = project_config;
        self.request_sync();
        Ok(self.project_config_view())
    }

    fn project_config_view(&self) -> DaemonProjectConfig {
        let project_config = self.project_config();
        let readiness = project_config.readiness();
        DaemonProjectConfig {
            hub_url: project_config.hub_url,
            author_user_id: project_config.author_user_id,
            project_id: project_config.project_id,
            has_access_token: project_config.access_token.is_some(),
            ready: readiness.ready,
            missing_fields: readiness.missing_fields,
        }
    }

    async fn health(&self) -> DaemonHealth {
        let schema_version = current_schema_version(&self.inner.pool).await.unwrap_or(0);
        let project_config = self.project_config();
        DaemonHealth {
            daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
            hub_url: project_config.hub_url,
            project_id: project_config.project_id,
            daemon_installation_id: self.inner.daemon_installation_id.clone(),
            log_dir: self.inner.config.logs_dir().display().to_string(),
            local_db: LocalDbStatus {
                path: self.inner.config.local_db_path().display().to_string(),
                ready: schema_version == CURRENT_LOCAL_SCHEMA_VERSION,
                schema_version,
            },
        }
    }

    fn mcp_status(&self) -> DaemonMcpStatus {
        DaemonMcpStatus {
            running: false,
            endpoint: None,
            adapters: Vec::new(),
        }
    }

    async fn drain_draft_queue(&self) -> Result<(), DaemonError> {
        drain_draft_queue(self).await
    }

    async fn pull_draft_events(&self) -> Result<(), DaemonError> {
        pull_draft_events(self).await
    }

    pub fn start_sync_worker(&self) -> Option<JoinHandle<()>> {
        if !self.inner.config.sync.enabled {
            return None;
        }

        let state = self.clone();
        Some(tokio::spawn(async move {
            let mut interval = tokio::time::interval(state.inner.config.sync.interval);
            loop {
                tokio::select! {
                    _ = interval.tick() => {}
                    _ = state.inner.sync_notify.notified() => {}
                }
                let _ = state.run_sync_cycle().await;
            }
        }))
    }

    pub fn request_sync(&self) {
        if self.inner.config.sync.enabled {
            self.inner.sync_notify.notify_one();
        }
    }

    async fn run_sync_cycle(&self) -> Result<(), DaemonError> {
        if self.inner.sync_running.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let result = async {
            if !self.project_config().readiness().ready {
                return Ok(());
            }
            upsert_meta_timestamp(&self.inner.pool, META_DRAFT_SYNC_LAST_ATTEMPT_AT).await?;
            self.drain_draft_queue().await?;
            self.pull_draft_events().await?;
            upsert_meta_timestamp(&self.inner.pool, META_DRAFT_SYNC_LAST_SUCCESS_AT).await
        }
        .await;
        self.inner.sync_running.store(false, Ordering::Release);
        result
    }
}

pub fn router(state: DaemonState) -> Router {
    Router::new()
        .route("/daemon/health", get(get_daemon_health))
        .route(
            "/daemon/project-config",
            get(get_daemon_project_config).put(put_daemon_project_config),
        )
        .route("/daemon/sync-status", get(get_daemon_sync_status))
        .route("/daemon/sync-retries", post(create_daemon_sync_retry))
        .route("/daemon/mcp-status", get(get_daemon_mcp_status))
        .route("/daemon/drafts", get(list_daemon_drafts))
        .route("/daemon/drafts/{draft_id}", get(get_daemon_draft))
        .route(
            "/daemon/draft-operations",
            post(create_daemon_draft_operation),
        )
        .with_state(state)
}

async fn get_daemon_health(State(state): State<DaemonState>) -> Json<DaemonHealth> {
    Json(state.health().await)
}

async fn get_daemon_project_config(State(state): State<DaemonState>) -> Json<DaemonProjectConfig> {
    Json(state.project_config_view())
}

async fn put_daemon_project_config(
    State(state): State<DaemonState>,
    Json(request): Json<DaemonProjectConfigUpdateRequest>,
) -> Result<Json<DaemonProjectConfig>, DaemonHttpError> {
    Ok(Json(state.replace_project_config(request).await?))
}

async fn get_daemon_sync_status(
    State(state): State<DaemonState>,
) -> Result<Json<DaemonSyncStatus>, DaemonHttpError> {
    Ok(Json(load_sync_status(&state).await?))
}

async fn create_daemon_sync_retry(
    State(state): State<DaemonState>,
    Json(request): Json<DaemonSyncRetryRequest>,
) -> Result<Json<DaemonRetryResponse>, DaemonHttpError> {
    let retry_id = format!("retry_{}", Uuid::new_v4().simple());
    let channel = request.channel.as_str();

    sqlx::query(
        "INSERT INTO sync_retries (retry_id, channel)
         VALUES ($1, $2)",
    )
    .bind(&retry_id)
    .bind(channel)
    .execute(&state.inner.pool)
    .await?;

    if matches!(
        request.channel,
        SyncRetryChannel::Drafts | SyncRetryChannel::All
    ) {
        sqlx::query(
            "UPDATE local_draft_operations
             SET sync_status = 'queued', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
             WHERE sync_status = 'failed'",
        )
        .execute(&state.inner.pool)
        .await?;
        state.run_sync_cycle().await?;
    }

    Ok(Json(DaemonRetryResponse {
        retry_id,
        started: true,
    }))
}

async fn get_daemon_mcp_status(State(state): State<DaemonState>) -> Json<DaemonMcpStatus> {
    Json(state.mcp_status())
}

async fn list_daemon_drafts(
    State(state): State<DaemonState>,
    Query(query): Query<DaemonDraftListQuery>,
) -> Result<Json<DaemonDraftListResponse>, DaemonHttpError> {
    Ok(Json(list_local_drafts(&state.inner.pool, query).await?))
}

async fn get_daemon_draft(
    State(state): State<DaemonState>,
    AxumPath(draft_id): AxumPath<String>,
) -> Result<Json<DaemonDraftDetail>, DaemonHttpError> {
    Ok(Json(
        load_local_draft_detail(&state.inner.pool, &draft_id).await?,
    ))
}

async fn create_daemon_draft_operation(
    State(state): State<DaemonState>,
    Json(request): Json<DaemonDraftOperationRequest>,
) -> Result<Json<DaemonDraftOperationResponse>, DaemonHttpError> {
    request.op.validate_exactly_one()?;
    let source = request
        .source
        .unwrap_or(DaemonDraftOperationSource::Desktop);
    let operation_json = serde_json::to_string(&request.op)?;
    let mut tx = state.inner.pool.begin().await?;

    let draft_id = resolve_local_draft(&mut tx, request.resource, &request.op).await?;
    let local_operation_id = format!("op_{}", Uuid::new_v4().simple());

    sqlx::query(
        "INSERT INTO local_draft_operations (
            local_operation_id, draft_id, resource_kind, operation_json, source, sync_status
         )
         VALUES ($1, $2, $3, $4, $5, 'queued')",
    )
    .bind(&local_operation_id)
    .bind(&draft_id)
    .bind(request.resource.as_str())
    .bind(operation_json)
    .bind(source.as_str())
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE local_drafts
         SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE draft_id = $1",
    )
    .bind(&draft_id)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    state.request_sync();

    Ok(Json(DaemonDraftOperationResponse {
        local_operation_id,
        draft_id,
        queued: true,
        sync_status: DraftOperationSyncStatus::Queued,
    }))
}

async fn resolve_local_draft(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    resource: DaemonDraftResourceKind,
    op: &DaemonDraftOperation,
) -> Result<String, DaemonError> {
    if let Some(create) = &op.create {
        let draft_id = format!("draft_{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO local_drafts (draft_id, resource_kind, target_id, path, status)
             VALUES ($1, $2, NULL, $3, 'open')",
        )
        .bind(&draft_id)
        .bind(resource.as_str())
        .bind(&create.path)
        .execute(&mut **tx)
        .await?;
        return Ok(draft_id);
    }

    let target_id = op
        .target_id()
        .ok_or_else(|| DaemonError::InvalidRequest("operation target id is required".to_owned()))?;
    if let Some(existing) = sqlx::query(
        "SELECT draft_id
         FROM local_drafts
         WHERE draft_id = $1 OR target_id = $1
         ORDER BY updated_at DESC
         LIMIT 1",
    )
    .bind(target_id)
    .fetch_optional(&mut **tx)
    .await?
    {
        let draft_id: String = existing.try_get("draft_id")?;
        if op.discard.is_some() {
            mark_local_draft_discarded(tx, &draft_id).await?;
        }
        return Ok(draft_id);
    }

    let draft_id = format!("draft_{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO local_drafts (draft_id, resource_kind, target_id, path, status)
         VALUES ($1, $2, $3, NULL, $4)",
    )
    .bind(&draft_id)
    .bind(resource.as_str())
    .bind(target_id)
    .bind(if op.discard.is_some() {
        "discarded"
    } else {
        "open"
    })
    .execute(&mut **tx)
    .await?;
    Ok(draft_id)
}

async fn mark_local_draft_discarded(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    draft_id: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_drafts
         SET status = 'discarded', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE draft_id = $1",
    )
    .bind(draft_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn list_local_drafts(
    pool: &SqlitePool,
    query: DaemonDraftListQuery,
) -> Result<DaemonDraftListResponse, DaemonError> {
    let resource_kind = query
        .resource
        .map(|value| draft_resource_kind_from_str(value.as_str()).map(|kind| kind.as_str()))
        .transpose()?
        .map(ToOwned::to_owned);
    let status = query
        .status
        .map(|value| local_draft_status_from_str(value.as_str()).map(|status| status.as_str()))
        .transpose()?
        .map(ToOwned::to_owned);
    let limit = query.limit.unwrap_or(100).clamp(1, 500);
    let rows = sqlx::query(
        "SELECT
            d.draft_id, d.server_draft_id, d.server_version, d.resource_kind, d.target_id,
            d.path, d.status, d.created_at, d.updated_at,
            (
                SELECT COUNT(*)
                FROM local_draft_operations o
                WHERE o.draft_id = d.draft_id AND o.sync_status IN ('queued', 'syncing')
            ) AS pending_operation_count,
            (
                SELECT COUNT(*)
                FROM local_draft_operations o
                WHERE o.draft_id = d.draft_id AND o.sync_status = 'failed'
            ) AS failed_operation_count
         FROM local_drafts d
         WHERE ($1 IS NULL OR d.resource_kind = $1)
           AND ($2 IS NULL OR d.status = $2)
         ORDER BY d.updated_at DESC, d.created_at DESC, d.draft_id ASC
         LIMIT $3",
    )
    .bind(resource_kind.as_deref())
    .bind(status.as_deref())
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let items = rows
        .iter()
        .map(local_draft_summary_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(DaemonDraftListResponse { items })
}

async fn load_local_draft_detail(
    pool: &SqlitePool,
    draft_id: &str,
) -> Result<DaemonDraftDetail, DaemonError> {
    let row = sqlx::query(
        "SELECT
            d.draft_id, d.server_draft_id, d.server_version, d.resource_kind, d.target_id,
            d.path, d.status, d.created_at, d.updated_at,
            (
                SELECT COUNT(*)
                FROM local_draft_operations o
                WHERE o.draft_id = d.draft_id AND o.sync_status IN ('queued', 'syncing')
            ) AS pending_operation_count,
            (
                SELECT COUNT(*)
                FROM local_draft_operations o
                WHERE o.draft_id = d.draft_id AND o.sync_status = 'failed'
            ) AS failed_operation_count
         FROM local_drafts d
         WHERE d.draft_id = $1",
    )
    .bind(draft_id)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| DaemonError::NotFound(format!("local draft not found: {draft_id}")))?;
    let draft = local_draft_summary_from_row(&row)?;
    let rows = sqlx::query(
        "SELECT
            local_operation_id, resource_kind, operation_json, source, sync_status,
            last_error, created_at, updated_at
         FROM local_draft_operations
         WHERE draft_id = $1
         ORDER BY rowid ASC",
    )
    .bind(draft_id)
    .fetch_all(pool)
    .await?;
    let operations = rows
        .iter()
        .map(local_draft_operation_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(DaemonDraftDetail { draft, operations })
}

fn local_draft_summary_from_row(row: &SqliteRow) -> Result<DaemonDraftSummary, DaemonError> {
    Ok(DaemonDraftSummary {
        draft_id: row.try_get("draft_id")?,
        server_draft_id: row.try_get("server_draft_id")?,
        server_version: row.try_get("server_version")?,
        resource_kind: draft_resource_kind_from_str(
            row.try_get::<String, _>("resource_kind")?.as_str(),
        )?,
        target_id: row.try_get("target_id")?,
        path: row.try_get("path")?,
        status: local_draft_status_from_str(row.try_get::<String, _>("status")?.as_str())?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
        pending_operation_count: row.try_get("pending_operation_count")?,
        failed_operation_count: row.try_get("failed_operation_count")?,
    })
}

fn local_draft_operation_from_row(
    row: &SqliteRow,
) -> Result<DaemonLocalDraftOperation, DaemonError> {
    Ok(DaemonLocalDraftOperation {
        local_operation_id: row.try_get("local_operation_id")?,
        resource_kind: draft_resource_kind_from_str(
            row.try_get::<String, _>("resource_kind")?.as_str(),
        )?,
        operation: serde_json::from_str(&row.try_get::<String, _>("operation_json")?)?,
        source: draft_operation_source_from_str(row.try_get::<String, _>("source")?.as_str())?,
        sync_status: draft_operation_sync_status_from_str(
            row.try_get::<String, _>("sync_status")?.as_str(),
        )?,
        last_error: row.try_get("last_error")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn load_sync_status(state: &DaemonState) -> Result<DaemonSyncStatus, DaemonError> {
    let pool = &state.inner.pool;
    let pending_operation_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM local_draft_operations
         WHERE sync_status IN ('queued', 'syncing')",
    )
    .fetch_one(pool)
    .await?;
    let failed_operation_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM local_draft_operations
         WHERE sync_status = 'failed'",
    )
    .fetch_one(pool)
    .await?;
    let server_cursor = load_meta_value(pool, META_DRAFT_EVENTS_CURSOR).await?;
    let last_attempt_at = load_meta_value(pool, META_DRAFT_SYNC_LAST_ATTEMPT_AT).await?;
    let last_success_at = load_meta_value(pool, META_DRAFT_SYNC_LAST_SUCCESS_AT).await?;
    let last_error: Option<String> = sqlx::query_scalar(
        "SELECT last_error
         FROM local_draft_operations
         WHERE sync_status = 'failed' AND last_error IS NOT NULL
         ORDER BY updated_at DESC
         LIMIT 1",
    )
    .fetch_optional(pool)
    .await?;
    let readiness = state.project_config().readiness();
    let config_error = (!readiness.ready
        && state.inner.config.sync.enabled
        && pending_operation_count > 0)
        .then(|| ApiError {
            code: "daemon_project_config_incomplete".to_owned(),
            message: format!(
                "Daemon project config is missing required fields: {}",
                readiness.missing_fields.join(", ")
            ),
            request_id: "local".to_owned(),
            details: json!({ "missing_fields": readiness.missing_fields }),
        });
    let draft_state = if config_error.is_some() {
        SyncState::Degraded
    } else if failed_operation_count > 0 {
        SyncState::Failed
    } else if pending_operation_count > 0 {
        SyncState::Queued
    } else {
        SyncState::Idle
    };

    Ok(DaemonSyncStatus {
        draft_sync: SyncChannelStatus {
            state: draft_state,
            server_cursor,
            last_attempt_at,
            last_success_at: last_success_at.clone(),
            last_error: config_error.or_else(|| {
                last_error.map(|message| ApiError {
                    code: "draft_sync_failed".to_owned(),
                    message,
                    request_id: "local".to_owned(),
                    details: json!({}),
                })
            }),
        },
        snapshot_sync: SyncChannelStatus {
            state: SyncState::Idle,
            server_cursor: None,
            last_attempt_at: None,
            last_success_at: None,
            last_error: None,
        },
        pending_operation_count,
        failed_operation_count,
        conflict_count: 0,
        last_success_at,
    })
}

async fn drain_draft_queue(state: &DaemonState) -> Result<(), DaemonError> {
    loop {
        let Some(operation) = load_next_queued_operation(&state.inner.pool).await? else {
            break;
        };
        mark_operation_syncing(&state.inner.pool, &operation.local_operation_id).await?;
        if let Err(error) = sync_one_draft_operation(state, operation).await {
            mark_operation_failed(
                &state.inner.pool,
                error.local_operation_id(),
                &error.to_string(),
            )
            .await?;
        }
    }
    Ok(())
}

async fn sync_one_draft_operation(
    state: &DaemonState,
    operation: QueuedDraftOperation,
) -> Result<(), DraftSyncError> {
    let local_operation_id = operation.local_operation_id.clone();
    let draft_operation: DaemonDraftOperation = serde_json::from_str(&operation.operation_json)
        .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
    let Some(hub_operation) =
        map_daemon_operation_to_hub(operation.resource_kind, &draft_operation)
            .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?
    else {
        mark_operation_synced(&state.inner.pool, &local_operation_id)
            .await
            .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
        return Ok(());
    };

    if let Some(server_draft_id) = operation.server_draft_id {
        let request = HubDraftOperationBatchRequest {
            daemon_installation_id: state.inner.daemon_installation_id.clone(),
            operations: vec![HubDraftOperationBatchItem {
                local_operation_id: local_operation_id.clone(),
                draft_id: server_draft_id,
                expected_draft_version: operation.server_version,
                operation: hub_operation,
            }],
        };
        let response: HubDraftOperationBatchResponse =
            post_hub_json(state, "/api/v1/draft-operation-batches", &request)
                .await
                .map_err(|error| {
                    DraftSyncError::new(local_operation_id.clone(), error.to_string())
                })?;
        if !response
            .accepted_operations
            .iter()
            .any(|accepted| accepted == &local_operation_id)
        {
            return Err(DraftSyncError::new(
                local_operation_id,
                "Hub did not accept local operation",
            ));
        }
        mark_batch_operation_synced(
            &state.inner.pool,
            &operation.draft_id,
            &local_operation_id,
            operation.server_version + 1,
            &response.cursor,
        )
        .await
        .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
        return Ok(());
    }

    let project_config = state.project_config();
    let author_user_id = project_config.author_user_id.clone().ok_or_else(|| {
        DraftSyncError::new(
            local_operation_id.clone(),
            "author_user_id is required to create a server draft",
        )
    })?;
    let project_id = project_config.project_id.clone().ok_or_else(|| {
        DraftSyncError::new(
            local_operation_id.clone(),
            "project_id is required to create a server draft",
        )
    })?;
    let request = HubCreateDraftRequest {
        author_user_id,
        daemon_installation_id: state.inner.daemon_installation_id.clone(),
        project_id,
        title: draft_title(&operation),
        description: None,
        resource: hub_operation.resource.clone(),
        operations: vec![hub_operation],
    };
    let response: HubDraftDetail = post_hub_json(state, "/api/v1/drafts", &request)
        .await
        .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
    mark_initial_operation_synced(
        &state.inner.pool,
        &operation.draft_id,
        &local_operation_id,
        &response.draft.draft_id,
        response.draft.version,
    )
    .await
    .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
    Ok(())
}

async fn load_next_queued_operation(
    pool: &SqlitePool,
) -> Result<Option<QueuedDraftOperation>, DaemonError> {
    let Some(row) = sqlx::query(
        "SELECT
            o.local_operation_id, o.draft_id, o.resource_kind, o.operation_json,
            d.server_draft_id, d.server_version, d.target_id, d.path
         FROM local_draft_operations o
         JOIN local_drafts d ON d.draft_id = o.draft_id
         WHERE o.sync_status = 'queued'
         ORDER BY o.created_at
         LIMIT 1",
    )
    .fetch_optional(pool)
    .await?
    else {
        return Ok(None);
    };

    Ok(Some(QueuedDraftOperation {
        local_operation_id: row.try_get("local_operation_id")?,
        draft_id: row.try_get("draft_id")?,
        resource_kind: draft_resource_kind_from_str(
            row.try_get::<String, _>("resource_kind")?.as_str(),
        )?,
        operation_json: row.try_get("operation_json")?,
        server_draft_id: row.try_get("server_draft_id")?,
        server_version: row.try_get("server_version")?,
        target_id: row.try_get("target_id")?,
        path: row.try_get("path")?,
    }))
}

async fn mark_operation_syncing(
    pool: &SqlitePool,
    local_operation_id: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'syncing', last_error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE local_operation_id = $1",
    )
    .bind(local_operation_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_operation_failed(
    pool: &SqlitePool,
    local_operation_id: &str,
    message: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'failed', last_error = $2, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE local_operation_id = $1",
    )
    .bind(local_operation_id)
    .bind(message)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_operation_synced(
    pool: &SqlitePool,
    local_operation_id: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'synced', last_error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE local_operation_id = $1",
    )
    .bind(local_operation_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_initial_operation_synced(
    pool: &SqlitePool,
    draft_id: &str,
    local_operation_id: &str,
    server_draft_id: &str,
    server_version: i64,
) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "UPDATE local_drafts
         SET server_draft_id = $2, server_version = $3, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE draft_id = $1",
    )
    .bind(draft_id)
    .bind(server_draft_id)
    .bind(server_version)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'synced', last_error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE local_operation_id = $1",
    )
    .bind(local_operation_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

async fn mark_batch_operation_synced(
    pool: &SqlitePool,
    draft_id: &str,
    local_operation_id: &str,
    server_version: i64,
    cursor: &str,
) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "UPDATE local_drafts
         SET server_version = $2, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE draft_id = $1",
    )
    .bind(draft_id)
    .bind(server_version)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'synced', last_error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE local_operation_id = $1",
    )
    .bind(local_operation_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO daemon_meta (key, value)
         VALUES ($1, $2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .bind(META_DRAFT_EVENTS_CURSOR)
    .bind(cursor)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

async fn post_hub_json<T, R>(state: &DaemonState, path: &str, request: &T) -> Result<R, DaemonError>
where
    T: Serialize + ?Sized,
    R: DeserializeOwned,
{
    let project_config = state.project_config();
    let url = format!(
        "{}/{}",
        project_config.hub_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let mut builder = state.inner.http.post(url).json(request);
    if let Some(token) = &project_config.access_token {
        builder = builder.bearer_auth(token);
    }
    let response = builder.send().await?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(DaemonError::Hub(format!(
            "Hub request failed with status {status}: {body}"
        )));
    }
    Ok(response.json::<R>().await?)
}

async fn get_hub_json<R>(state: &DaemonState, path: &str) -> Result<R, DaemonError>
where
    R: DeserializeOwned,
{
    let project_config = state.project_config();
    let url = format!(
        "{}/{}",
        project_config.hub_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let mut builder = state.inner.http.get(url);
    if let Some(token) = &project_config.access_token {
        builder = builder.bearer_auth(token);
    }
    let response = builder.send().await?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(DaemonError::Hub(format!(
            "Hub request failed with status {status}: {body}"
        )));
    }
    Ok(response.json::<R>().await?)
}

fn map_daemon_operation_to_hub(
    resource: DaemonDraftResourceKind,
    operation: &DaemonDraftOperation,
) -> Result<Option<HubDraftOperationInput>, DaemonError> {
    if let Some(create) = &operation.create {
        return Ok(Some(HubDraftOperationInput {
            action: HubDraftOperationAction::Create,
            resource: HubDraftResourceRef {
                kind: resource,
                id: None,
                path: Some(create.path.clone()),
            },
            base_hash: None,
            body: Some(create.body.clone()),
            new_path: None,
        }));
    }
    if let Some(update) = &operation.update {
        return Ok(Some(HubDraftOperationInput {
            action: HubDraftOperationAction::Update,
            resource: HubDraftResourceRef {
                kind: resource,
                id: Some(update.id.clone()),
                path: None,
            },
            base_hash: None,
            body: Some(update.body.clone()),
            new_path: None,
        }));
    }
    if let Some(rename) = &operation.rename {
        return Ok(Some(HubDraftOperationInput {
            action: HubDraftOperationAction::Rename,
            resource: HubDraftResourceRef {
                kind: resource,
                id: Some(rename.id.clone()),
                path: None,
            },
            base_hash: None,
            body: None,
            new_path: Some(rename.new_path.clone()),
        }));
    }
    if let Some(delete) = &operation.delete {
        return Ok(Some(HubDraftOperationInput {
            action: HubDraftOperationAction::Delete,
            resource: HubDraftResourceRef {
                kind: resource,
                id: Some(delete.id.clone()),
                path: None,
            },
            base_hash: None,
            body: None,
            new_path: None,
        }));
    }
    if operation.discard.is_some() {
        return Ok(None);
    }
    Err(DaemonError::InvalidRequest(
        "draft operation must contain exactly one operation variant".to_owned(),
    ))
}

fn draft_resource_kind_from_str(value: &str) -> Result<DaemonDraftResourceKind, DaemonError> {
    match value {
        "context" => Ok(DaemonDraftResourceKind::Context),
        "rule" => Ok(DaemonDraftResourceKind::Rule),
        "workflow" => Ok(DaemonDraftResourceKind::Workflow),
        "metaprompt" => Ok(DaemonDraftResourceKind::Metaprompt),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown draft resource kind: {other}"
        ))),
    }
}

fn local_draft_status_from_str(value: &str) -> Result<DaemonLocalDraftStatus, DaemonError> {
    match value {
        "open" => Ok(DaemonLocalDraftStatus::Open),
        "submitted" => Ok(DaemonLocalDraftStatus::Submitted),
        "discarded" => Ok(DaemonLocalDraftStatus::Discarded),
        "conflicted" => Ok(DaemonLocalDraftStatus::Conflicted),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown local draft status: {other}"
        ))),
    }
}

fn draft_operation_source_from_str(value: &str) -> Result<DaemonDraftOperationSource, DaemonError> {
    match value {
        "desktop" => Ok(DaemonDraftOperationSource::Desktop),
        "cli" => Ok(DaemonDraftOperationSource::Cli),
        "mcp_store" => Ok(DaemonDraftOperationSource::McpStore),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown draft operation source: {other}"
        ))),
    }
}

fn draft_operation_sync_status_from_str(
    value: &str,
) -> Result<DraftOperationSyncStatus, DaemonError> {
    match value {
        "queued" => Ok(DraftOperationSyncStatus::Queued),
        "syncing" => Ok(DraftOperationSyncStatus::Syncing),
        "synced" => Ok(DraftOperationSyncStatus::Synced),
        "failed" => Ok(DraftOperationSyncStatus::Failed),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown draft operation sync status: {other}"
        ))),
    }
}

fn draft_title(operation: &QueuedDraftOperation) -> String {
    operation
        .path
        .as_deref()
        .or(operation.target_id.as_deref())
        .map(|target| format!("Draft for {target}"))
        .unwrap_or_else(|| "Draft operation".to_owned())
}

async fn pull_draft_events(state: &DaemonState) -> Result<(), DaemonError> {
    let cursor = load_meta_value(&state.inner.pool, META_DRAFT_EVENTS_CURSOR).await?;
    let path = cursor
        .as_deref()
        .map(|cursor| format!("/api/v1/draft-events?after_cursor={cursor}"))
        .unwrap_or_else(|| "/api/v1/draft-events".to_owned());
    let response: HubDraftEventListResponse = get_hub_json(state, &path).await?;

    let mut tx = state.inner.pool.begin().await?;
    for event in response.events {
        if event.daemon_installation_id.as_deref() == Some(&state.inner.daemon_installation_id) {
            continue;
        }
        sqlx::query(
            "INSERT INTO remote_draft_events (
                event_id, draft_id, project_id, event_type, version, daemon_installation_id, created_at
             )
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT(event_id) DO NOTHING",
        )
        .bind(event.event_id)
        .bind(event.draft_id)
        .bind(event.project_id)
        .bind(event.event_type)
        .bind(event.version)
        .bind(event.daemon_installation_id)
        .bind(event.created_at)
        .execute(&mut *tx)
        .await?;
    }
    if let Some(next_cursor) = response.next_cursor {
        sqlx::query(
            "INSERT INTO daemon_meta (key, value)
             VALUES ($1, $2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .bind(META_DRAFT_EVENTS_CURSOR)
        .bind(next_cursor)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

fn prepare_directories(config: &DaemonConfig) -> Result<(), DaemonError> {
    std::fs::create_dir_all(&config.root_dir)?;
    std::fs::create_dir_all(config.logs_dir())?;
    Ok(())
}

pub fn write_daemon_endpoint_file(
    config: &DaemonConfig,
    actual_addr: SocketAddr,
    daemon_installation_id: &str,
) -> Result<DaemonEndpointFile, DaemonError> {
    let endpoint = DaemonEndpointFile {
        endpoint: format!("http://{actual_addr}"),
        pid: std::process::id(),
        daemon_installation_id: daemon_installation_id.to_owned(),
    };
    let body = serde_json::to_vec_pretty(&endpoint)?;
    std::fs::write(config.endpoint_file_path(), body)?;
    Ok(endpoint)
}

pub fn remove_daemon_endpoint_file(config: &DaemonConfig) -> Result<(), DaemonError> {
    match std::fs::remove_file(config.endpoint_file_path()) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

async fn connect_local_db(path: &Path) -> Result<SqlitePool, DaemonError> {
    let options = SqliteConnectOptions::from_str(&path.display().to_string())?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal);
    Ok(SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?)
}

async fn migrate_local_db(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS daemon_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS local_drafts (
            draft_id TEXT PRIMARY KEY,
            server_draft_id TEXT,
            server_version BIGINT NOT NULL DEFAULT 0,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow', 'metaprompt')),
            target_id TEXT,
            path TEXT,
            status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'discarded', 'conflicted')) DEFAULT 'open',
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
        "CREATE TABLE IF NOT EXISTS local_draft_operations (
            local_operation_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL REFERENCES local_drafts(draft_id) ON DELETE CASCADE,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow', 'metaprompt')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
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
            channel TEXT NOT NULL CHECK (channel IN ('drafts', 'snapshots', 'all')),
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

async fn current_schema_version(pool: &SqlitePool) -> Result<i64, DaemonError> {
    let value: Option<String> =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'schema_version'")
            .fetch_optional(pool)
            .await?;
    Ok(value
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or_default())
}

async fn load_or_create_installation_id(pool: &SqlitePool) -> Result<String, DaemonError> {
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

async fn load_project_config(
    pool: &SqlitePool,
    defaults: &ProjectConfig,
) -> Result<ProjectConfig, DaemonError> {
    Ok(ProjectConfig {
        hub_url: load_meta_value(pool, "project_config_hub_url")
            .await?
            .unwrap_or_else(|| defaults.hub_url.clone()),
        author_user_id: load_meta_value(pool, "project_config_author_user_id")
            .await?
            .or_else(|| defaults.author_user_id.clone()),
        project_id: load_meta_value(pool, "project_config_project_id")
            .await?
            .or_else(|| defaults.project_id.clone()),
        access_token: load_meta_value(pool, "project_config_access_token")
            .await?
            .or_else(|| defaults.access_token.clone()),
    })
}

async fn save_project_config(pool: &SqlitePool, config: &ProjectConfig) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    upsert_meta_value(&mut tx, "project_config_hub_url", Some(&config.hub_url)).await?;
    upsert_meta_value(
        &mut tx,
        "project_config_author_user_id",
        config.author_user_id.as_deref(),
    )
    .await?;
    upsert_meta_value(
        &mut tx,
        "project_config_project_id",
        config.project_id.as_deref(),
    )
    .await?;
    upsert_meta_value(
        &mut tx,
        "project_config_access_token",
        config.access_token.as_deref(),
    )
    .await?;
    tx.commit().await?;
    Ok(())
}

async fn load_meta_value(pool: &SqlitePool, key: &str) -> Result<Option<String>, DaemonError> {
    Ok(
        sqlx::query_scalar::<_, String>("SELECT value FROM daemon_meta WHERE key = $1")
            .bind(key)
            .fetch_optional(pool)
            .await?
            .and_then(non_empty_string),
    )
}

async fn upsert_meta_timestamp(pool: &SqlitePool, key: &str) -> Result<(), DaemonError> {
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

async fn upsert_meta_value(
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

fn default_root_dir() -> Result<PathBuf, DaemonError> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".clumsies").join("daemon"))
        .ok_or_else(|| {
            DaemonError::InvalidConfig(
                "HOME is required when CLUMSIES_DAEMON_ROOT is not set".to_owned(),
            )
        })
}

fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn parse_bool_env(name: &str) -> Result<Option<bool>, DaemonError> {
    let Some(value) = env::var(name).ok() else {
        return Ok(None);
    };
    match value.as_str() {
        "1" | "true" | "TRUE" | "yes" | "YES" => Ok(Some(true)),
        "0" | "false" | "FALSE" | "no" | "NO" => Ok(Some(false)),
        _ => Err(DaemonError::InvalidConfig(format!(
            "{name} must be a boolean value"
        ))),
    }
}

fn parse_u64_env(name: &str) -> Result<Option<u64>, DaemonError> {
    let Some(value) = env::var(name).ok() else {
        return Ok(None);
    };
    value.parse::<u64>().map(Some).map_err(|error| {
        DaemonError::InvalidConfig(format!("{name} must be a positive integer: {error}"))
    })
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectConfig {
    pub hub_url: String,
    pub author_user_id: Option<String>,
    pub project_id: Option<String>,
    pub has_access_token: bool,
    pub ready: bool,
    pub missing_fields: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct DaemonProjectConfigUpdateRequest {
    pub hub_url: String,
    pub author_user_id: Option<String>,
    pub project_id: Option<String>,
    pub access_token: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProjectConfigReadiness {
    ready: bool,
    missing_fields: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonHealth {
    pub daemon_version: String,
    pub hub_url: String,
    pub project_id: Option<String>,
    pub daemon_installation_id: String,
    pub log_dir: String,
    pub local_db: LocalDbStatus,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonEndpointFile {
    pub endpoint: String,
    pub pid: u32,
    pub daemon_installation_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct LocalDbStatus {
    pub path: String,
    pub ready: bool,
    pub schema_version: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonSyncStatus {
    pub draft_sync: SyncChannelStatus,
    pub snapshot_sync: SyncChannelStatus,
    pub pending_operation_count: i64,
    pub failed_operation_count: i64,
    pub conflict_count: i64,
    pub last_success_at: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct SyncChannelStatus {
    pub state: SyncState,
    pub server_cursor: Option<String>,
    pub last_attempt_at: Option<String>,
    pub last_success_at: Option<String>,
    pub last_error: Option<ApiError>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncState {
    Idle,
    Queued,
    Syncing,
    Degraded,
    Failed,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct DaemonSyncRetryRequest {
    pub channel: SyncRetryChannel,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncRetryChannel {
    Drafts,
    Snapshots,
    All,
}

impl SyncRetryChannel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Drafts => "drafts",
            Self::Snapshots => "snapshots",
            Self::All => "all",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonRetryResponse {
    pub retry_id: String,
    pub started: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonMcpStatus {
    pub running: bool,
    pub endpoint: Option<String>,
    pub adapters: Vec<McpAdapterStatus>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct McpAdapterStatus {
    pub name: String,
    pub running: bool,
    pub last_error: Option<ApiError>,
}

#[derive(Clone, Debug, Deserialize, Default, PartialEq, Eq)]
pub struct DaemonDraftListQuery {
    pub resource: Option<String>,
    pub status: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftListResponse {
    pub items: Vec<DaemonDraftSummary>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftDetail {
    pub draft: DaemonDraftSummary,
    pub operations: Vec<DaemonLocalDraftOperation>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftSummary {
    pub draft_id: String,
    pub server_draft_id: Option<String>,
    pub server_version: i64,
    pub resource_kind: DaemonDraftResourceKind,
    pub target_id: Option<String>,
    pub path: Option<String>,
    pub status: DaemonLocalDraftStatus,
    pub created_at: String,
    pub updated_at: String,
    pub pending_operation_count: i64,
    pub failed_operation_count: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonLocalDraftOperation {
    pub local_operation_id: String,
    pub resource_kind: DaemonDraftResourceKind,
    pub operation: DaemonDraftOperation,
    pub source: DaemonDraftOperationSource,
    pub sync_status: DraftOperationSyncStatus,
    pub last_error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonLocalDraftStatus {
    Open,
    Submitted,
    Discarded,
    Conflicted,
}

impl DaemonLocalDraftStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Submitted => "submitted",
            Self::Discarded => "discarded",
            Self::Conflicted => "conflicted",
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct DaemonDraftOperationRequest {
    pub resource: DaemonDraftResourceKind,
    pub op: DaemonDraftOperation,
    pub source: Option<DaemonDraftOperationSource>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonDraftResourceKind {
    Context,
    Rule,
    Workflow,
    Metaprompt,
}

impl DaemonDraftResourceKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Context => "context",
            Self::Rule => "rule",
            Self::Workflow => "workflow",
            Self::Metaprompt => "metaprompt",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonDraftOperationSource {
    Desktop,
    Cli,
    McpStore,
}

impl DaemonDraftOperationSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Cli => "cli",
            Self::McpStore => "mcp_store",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftOperation {
    pub create: Option<DaemonCreateDraftOperation>,
    pub update: Option<DaemonUpdateDraftOperation>,
    pub rename: Option<DaemonRenameDraftOperation>,
    pub delete: Option<DaemonDeleteDraftOperation>,
    pub discard: Option<DaemonDiscardDraftOperation>,
}

impl DaemonDraftOperation {
    fn validate_exactly_one(&self) -> Result<(), DaemonHttpError> {
        let count = [
            self.create.is_some(),
            self.update.is_some(),
            self.rename.is_some(),
            self.delete.is_some(),
            self.discard.is_some(),
        ]
        .into_iter()
        .filter(|present| *present)
        .count();
        if count == 1 {
            Ok(())
        } else {
            Err(DaemonHttpError::new(
                StatusCode::BAD_REQUEST,
                "invalid_draft_operation",
                "draft operation must contain exactly one operation variant",
            ))
        }
    }

    fn target_id(&self) -> Option<&str> {
        self.update
            .as_ref()
            .map(|operation| operation.id.as_str())
            .or_else(|| self.rename.as_ref().map(|operation| operation.id.as_str()))
            .or_else(|| self.delete.as_ref().map(|operation| operation.id.as_str()))
            .or_else(|| self.discard.as_ref().map(|operation| operation.id.as_str()))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonCreateDraftOperation {
    pub path: String,
    pub body: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonUpdateDraftOperation {
    pub id: String,
    pub body: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonRenameDraftOperation {
    pub id: String,
    pub new_path: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDeleteDraftOperation {
    pub id: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDiscardDraftOperation {
    pub id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftOperationResponse {
    pub local_operation_id: String,
    pub draft_id: String,
    pub queued: bool,
    pub sync_status: DraftOperationSyncStatus,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DraftOperationSyncStatus {
    Queued,
    Syncing,
    Synced,
    Failed,
}

#[derive(Clone, Debug)]
struct QueuedDraftOperation {
    local_operation_id: String,
    draft_id: String,
    resource_kind: DaemonDraftResourceKind,
    operation_json: String,
    server_draft_id: Option<String>,
    server_version: i64,
    target_id: Option<String>,
    path: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct HubCreateDraftRequest {
    author_user_id: String,
    daemon_installation_id: String,
    project_id: String,
    title: String,
    description: Option<String>,
    resource: HubDraftResourceRef,
    operations: Vec<HubDraftOperationInput>,
}

#[derive(Clone, Debug, Serialize)]
struct HubDraftOperationBatchRequest {
    daemon_installation_id: String,
    operations: Vec<HubDraftOperationBatchItem>,
}

#[derive(Clone, Debug, Serialize)]
struct HubDraftOperationBatchItem {
    local_operation_id: String,
    draft_id: String,
    expected_draft_version: i64,
    operation: HubDraftOperationInput,
}

#[derive(Clone, Debug, Deserialize)]
struct HubDraftOperationBatchResponse {
    accepted_operations: Vec<String>,
    cursor: String,
}

#[derive(Clone, Debug, Deserialize)]
struct HubDraftEventListResponse {
    events: Vec<HubDraftEvent>,
    next_cursor: Option<String>,
    #[serde(rename = "has_more")]
    _has_more: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct HubDraftEvent {
    event_id: String,
    draft_id: String,
    project_id: String,
    event_type: String,
    version: i64,
    daemon_installation_id: Option<String>,
    created_at: String,
}

#[derive(Clone, Debug, Deserialize)]
struct HubDraftDetail {
    draft: HubDraft,
}

#[derive(Clone, Debug, Deserialize)]
struct HubDraft {
    draft_id: String,
    version: i64,
}

#[derive(Clone, Debug, Serialize)]
struct HubDraftOperationInput {
    action: HubDraftOperationAction,
    resource: HubDraftResourceRef,
    base_hash: Option<String>,
    body: Option<String>,
    new_path: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum HubDraftOperationAction {
    Create,
    Update,
    Rename,
    Delete,
}

#[derive(Clone, Debug, Serialize)]
struct HubDraftResourceRef {
    kind: DaemonDraftResourceKind,
    id: Option<String>,
    path: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ErrorEnvelope {
    pub error: ApiError,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ApiError {
    pub code: String,
    pub message: String,
    pub request_id: String,
    pub details: serde_json::Value,
}

#[derive(Debug, Error)]
pub enum DaemonError {
    #[error("invalid config: {0}")]
    InvalidConfig(String),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),
    #[error(transparent)]
    SerdeJson(#[from] serde_json::Error),
    #[error(transparent)]
    Reqwest(#[from] reqwest::Error),
    #[error("hub sync error: {0}")]
    Hub(String),
}

#[derive(Debug)]
struct DraftSyncError {
    local_operation_id: String,
    message: String,
}

impl DraftSyncError {
    fn new(local_operation_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            local_operation_id: local_operation_id.into(),
            message: message.into(),
        }
    }

    fn local_operation_id(&self) -> &str {
        &self.local_operation_id
    }
}

impl std::fmt::Display for DraftSyncError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for DraftSyncError {}

#[derive(Debug)]
pub struct DaemonHttpError {
    status: StatusCode,
    code: &'static str,
    message: String,
    details: serde_json::Value,
}

impl DaemonHttpError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            details: json!({}),
        }
    }
}

impl IntoResponse for DaemonHttpError {
    fn into_response(self) -> Response {
        let body = ErrorEnvelope {
            error: ApiError {
                code: self.code.to_owned(),
                message: self.message,
                request_id: format!("req_{}", Uuid::new_v4().simple()),
                details: self.details,
            },
        };
        (self.status, Json(body)).into_response()
    }
}

impl From<DaemonError> for DaemonHttpError {
    fn from(error: DaemonError) -> Self {
        match error {
            DaemonError::InvalidRequest(message) => {
                Self::new(StatusCode::BAD_REQUEST, "invalid_request", message)
            }
            DaemonError::NotFound(message) => {
                Self::new(StatusCode::NOT_FOUND, "not_found", message)
            }
            DaemonError::InvalidConfig(message) => {
                Self::new(StatusCode::INTERNAL_SERVER_ERROR, "invalid_config", message)
            }
            DaemonError::Io(error) => Self::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "io_error",
                error.to_string(),
            ),
            DaemonError::Sqlx(error) => Self::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "local_db_error",
                error.to_string(),
            ),
            DaemonError::SerdeJson(error) => {
                Self::new(StatusCode::BAD_REQUEST, "invalid_json", error.to_string())
            }
            DaemonError::Reqwest(error) => Self::new(
                StatusCode::BAD_GATEWAY,
                "hub_request_failed",
                error.to_string(),
            ),
            DaemonError::Hub(message) => {
                Self::new(StatusCode::BAD_GATEWAY, "hub_sync_failed", message)
            }
        }
    }
}

impl From<sqlx::Error> for DaemonHttpError {
    fn from(error: sqlx::Error) -> Self {
        DaemonError::Sqlx(error).into()
    }
}

impl From<serde_json::Error> for DaemonHttpError {
    fn from(error: serde_json::Error) -> Self {
        DaemonError::SerdeJson(error).into()
    }
}
