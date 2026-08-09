use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use serde::de::DeserializeOwned;
use sqlx::SqlitePool;
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;
use uuid::Uuid;

use super::*;

const STARTUP_CREDENTIAL_LOAD_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone)]
pub struct DaemonState {
    pub(crate) inner: Arc<DaemonInner>,
}

pub(crate) struct DaemonInner {
    pub(crate) config: DaemonConfig,
    pub(crate) project_config: RwLock<RuntimeProjectConfig>,
    pub(crate) credential_store: Arc<dyn CredentialStore>,
    pub(crate) pool: SqlitePool,
    pub(crate) http: reqwest::Client,
    pub(crate) daemon_installation_id: String,
    pub(crate) sync_notify: Notify,
    pub(crate) sync_lock: Mutex<()>,
    pub(crate) commit_sync_running: AtomicBool,
    pub(crate) token_refresh: Mutex<()>,
    pub(crate) search_models: Arc<dyn search::models::SearchModels>,
    pub(crate) search_lock: Mutex<()>,
    pub(crate) retrieval_history_lock: Mutex<()>,
    pub(crate) draft_mutation_lock: Mutex<()>,
    pub(crate) local_setup_lock: Mutex<()>,
    pub(crate) agent_run_lock: Mutex<()>,
    pub(crate) storage_access: tokio::sync::RwLock<()>,
}

impl DaemonState {
    pub async fn initialize(config: DaemonConfig) -> Result<Self, DaemonError> {
        Self::initialize_with_credential_store(config, Arc::new(SystemCredentialStore::default()))
            .await
    }

    pub async fn initialize_with_credential_store(
        config: DaemonConfig,
        credential_store: Arc<dyn CredentialStore>,
    ) -> Result<Self, DaemonError> {
        let search_models = search::production_models(config.cache_dir.clone());
        Self::initialize_with_credential_store_and_search_models(
            config,
            credential_store,
            search_models,
        )
        .await
    }

    pub(crate) async fn initialize_with_credential_store_and_search_models(
        config: DaemonConfig,
        credential_store: Arc<dyn CredentialStore>,
        search_models: Arc<dyn search::models::SearchModels>,
    ) -> Result<Self, DaemonError> {
        prepare_directories(&config)?;
        let pool = connect_local_db(&config.local_db_path()).await?;
        migrate_local_db(&pool).await?;
        reset_memory_cache_if_required(&pool, &config.cache_dir).await?;
        recover_interrupted_operations(&pool).await?;
        retrieval_history::recover_interrupted_runs(&pool).await?;
        work_tracking::recover_expired_runs(&pool).await?;
        let daemon_installation_id = load_or_create_installation_id(&pool).await?;
        let credentials =
            load_startup_credentials(credential_store.clone(), STARTUP_CREDENTIAL_LOAD_TIMEOUT)
                .await;
        let project_config = load_project_config(&pool, &config.project, credentials).await?;

        let state = Self {
            inner: Arc::new(DaemonInner {
                config,
                project_config: RwLock::new(project_config),
                credential_store,
                pool,
                http: reqwest::Client::new(),
                daemon_installation_id,
                sync_notify: Notify::new(),
                sync_lock: Mutex::new(()),
                commit_sync_running: AtomicBool::new(false),
                token_refresh: Mutex::new(()),
                search_models,
                search_lock: Mutex::new(()),
                retrieval_history_lock: Mutex::new(()),
                draft_mutation_lock: Mutex::new(()),
                local_setup_lock: Mutex::new(()),
                agent_run_lock: Mutex::new(()),
                storage_access: tokio::sync::RwLock::new(()),
            }),
        };
        project_storage::resume_pending_moves(&state);
        Ok(state)
    }

    pub fn local_db_path(&self) -> PathBuf {
        self.inner.config.local_db_path()
    }

    pub fn daemon_installation_id(&self) -> &str {
        &self.inner.daemon_installation_id
    }

    pub fn project_config_status(&self) -> DaemonProjectConfig {
        self.project_config_view()
    }

    pub(crate) fn project_config(&self) -> RuntimeProjectConfig {
        self.inner
            .project_config
            .read()
            .expect("project config rwlock poisoned")
            .clone()
    }

    pub async fn replace_project_config(
        &self,
        request: DaemonProjectConfigUpdateRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        let project_config = RuntimeProjectConfig {
            server_url: request.server_url.trim().to_owned(),
            project_id: request.project_id.and_then(non_empty_string),
            access_token: request.access_token.and_then(non_empty_string),
            refresh_token: request.refresh_token.and_then(non_empty_string),
        };
        project_config.validate()?;
        clear_server_response_cache(&self.inner.pool).await?;
        let previous_credentials = self.project_config().credentials();
        replace_server_credentials(
            self.inner.credential_store.clone(),
            project_config.credentials(),
        )
        .await?;
        if let Err(error) =
            save_project_metadata(&self.inner.pool, &project_config.metadata()).await
        {
            if let Err(rollback_error) = replace_server_credentials(
                self.inner.credential_store.clone(),
                previous_credentials,
            )
            .await
            {
                return Err(DaemonError::CredentialStore(CredentialStoreError::new(
                    format!(
                        "failed to persist project metadata ({error}) and failed to restore the previous Keychain session ({rollback_error})"
                    ),
                )));
            }
            return Err(error);
        }
        *self
            .inner
            .project_config
            .write()
            .expect("project config rwlock poisoned") = project_config;
        queue_retrying_operations(&self.inner.pool).await?;
        self.request_sync();
        Ok(self.project_config_view())
    }

    pub async fn select_project(
        &self,
        request: DaemonProjectSelectionRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        let project_id = non_empty_string(request.project_id).ok_or_else(|| {
            DaemonError::InvalidRequest("project_id must not be empty".to_owned())
        })?;
        let mut project_config = self.project_config();
        project_config.project_id = Some(project_id);
        project_config.validate()?;
        save_project_metadata(&self.inner.pool, &project_config.metadata()).await?;
        *self
            .inner
            .project_config
            .write()
            .expect("project config rwlock poisoned") = project_config;
        self.request_sync();
        Ok(self.project_config_view())
    }

    pub async fn resolve_project_binding(
        &self,
        request: DaemonProjectBindingResolveRequest,
    ) -> Result<DaemonProjectBinding, DaemonError> {
        let workspace_path = canonical_workspace_directory(&request.workspace_path)?;
        let server_url = canonical_server_url(&self.project_config().server_url)?;
        let rows = sqlx::query(
            "SELECT server_url, workspace_root, project_id, revision, created_at, updated_at
             FROM project_bindings
             WHERE server_url = $1",
        )
        .bind(&server_url)
        .fetch_all(&self.inner.pool)
        .await?;

        let mut candidates = vec![workspace_path.clone()];
        // A git worktree belongs to the same repository as its main checkout,
        // so it should resolve to the same Project. Fall back to the main
        // repository root when the worktree path itself is not bound.
        if let Some(main_root) = git_worktree_main_root(&workspace_path)
            && main_root != workspace_path
        {
            candidates.push(main_root);
        }

        let mut best: Option<(usize, DaemonProjectBinding)> = None;
        for candidate in &candidates {
            for row in &rows {
                let binding = project_binding_from_row(row)?;
                // Stored roots were canonicalized at insert time; re-canonicalize
                // them now so a later workspace move or symlink change (e.g. a
                // repository migrated to an external volume) still matches.
                let root = canonical_binding_root(&binding.workspace_root);
                if !candidate.starts_with(&root) {
                    continue;
                }
                let specificity = root.components().count();
                if best
                    .as_ref()
                    .is_some_and(|(best_specificity, _)| *best_specificity >= specificity)
                {
                    continue;
                }
                best = Some((specificity, binding));
            }
        }

        best.map(|(_, binding)| binding)
            .ok_or_else(|| DaemonError::State {
                code: "project_binding_not_found",
                message: format!(
                    "No Project is bound to workspace path {} on {server_url}",
                    workspace_path.display()
                ),
            })
    }

    pub async fn list_project_bindings(
        &self,
        request: DaemonProjectBindingListRequest,
    ) -> Result<DaemonProjectBindingListResponse, DaemonError> {
        let project_id = non_empty_string(request.project_id).ok_or_else(|| {
            DaemonError::InvalidRequest("project_id must not be empty".to_owned())
        })?;
        let server_url = canonical_server_url(&self.project_config().server_url)?;
        let rows = sqlx::query(
            "SELECT server_url, workspace_root, project_id, revision, created_at, updated_at
             FROM project_bindings
             WHERE server_url = $1 AND project_id = $2
             ORDER BY workspace_root",
        )
        .bind(server_url)
        .bind(project_id)
        .fetch_all(&self.inner.pool)
        .await?;
        Ok(DaemonProjectBindingListResponse {
            items: rows
                .iter()
                .map(project_binding_from_row)
                .collect::<Result<Vec<_>, _>>()?,
        })
    }

    pub async fn replace_project_binding(
        &self,
        request: DaemonProjectBindingReplaceRequest,
    ) -> Result<DaemonProjectBinding, DaemonError> {
        let workspace_root = canonical_workspace_directory(&request.workspace_root)?;
        let project_id = non_empty_string(request.project_id).ok_or_else(|| {
            DaemonError::InvalidRequest("project_id must not be empty".to_owned())
        })?;
        commit_sync::validate_cache_component("project_id", &project_id)?;
        let server_url = canonical_server_url(&self.project_config().server_url)?;

        let response = execute_authenticated_server_request(
            self,
            reqwest::Method::GET,
            &format!("/api/v1/projects/{project_id}"),
            &BTreeMap::new(),
            None,
        )
        .await?;
        if response.status() == reqwest::StatusCode::NOT_FOUND
            || response.status() == reqwest::StatusCode::FORBIDDEN
        {
            return Err(DaemonError::State {
                code: "project_binding_unresolved",
                message: format!(
                    "Project {project_id} does not exist or is not accessible on {server_url}"
                ),
            });
        }
        ensure_server_success(response).await?;

        let _guard = self.inner.local_setup_lock.lock().await;
        let workspace_root = workspace_root.display().to_string();
        let mut tx = self.inner.pool.begin().await?;
        let existing = sqlx::query(
            "SELECT server_url, workspace_root, project_id, revision, created_at, updated_at
             FROM project_bindings
             WHERE server_url = $1 AND workspace_root = $2",
        )
        .bind(&server_url)
        .bind(&workspace_root)
        .fetch_optional(&mut *tx)
        .await?;

        if let Some(row) = existing {
            let existing = project_binding_from_row(&row)?;
            if request.expected_revision.is_none() && existing.project_id == project_id {
                tx.commit().await?;
                return Ok(existing);
            }
            if request.expected_revision != Some(existing.revision) {
                return Err(DaemonError::State {
                    code: "project_binding_changed",
                    message: format!(
                        "Project binding for {workspace_root} changed from the expected revision"
                    ),
                });
            }
            sqlx::query(
                "UPDATE project_bindings
                 SET project_id = $3, revision = revision + 1,
                     updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                 WHERE server_url = $1 AND workspace_root = $2",
            )
            .bind(&server_url)
            .bind(&workspace_root)
            .bind(&project_id)
            .execute(&mut *tx)
            .await?;
        } else {
            if request.expected_revision.is_some() {
                return Err(DaemonError::State {
                    code: "project_binding_changed",
                    message: format!("Project binding for {workspace_root} no longer exists"),
                });
            }
            sqlx::query(
                "INSERT INTO project_bindings (server_url, workspace_root, project_id, revision)
                 VALUES ($1, $2, $3, 1)",
            )
            .bind(&server_url)
            .bind(&workspace_root)
            .bind(&project_id)
            .execute(&mut *tx)
            .await?;
        }

        let row = sqlx::query(
            "SELECT server_url, workspace_root, project_id, revision, created_at, updated_at
             FROM project_bindings
             WHERE server_url = $1 AND workspace_root = $2",
        )
        .bind(&server_url)
        .bind(&workspace_root)
        .fetch_one(&mut *tx)
        .await?;
        let binding = project_binding_from_row(&row)?;
        tx.commit().await?;
        self.request_sync();
        Ok(binding)
    }

    pub async fn remove_project_binding(
        &self,
        request: DaemonProjectBindingRemoveRequest,
    ) -> Result<DaemonProjectBindingRemoveResponse, DaemonError> {
        let workspace_root = canonical_workspace_directory(&request.workspace_root)?;
        let server_url = canonical_server_url(&self.project_config().server_url)?;
        let _guard = self.inner.local_setup_lock.lock().await;
        let workspace_root = workspace_root.display().to_string();
        let adapter_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)
             FROM project_agent_adapters
             WHERE server_url = $1 AND workspace_root = $2",
        )
        .bind(&server_url)
        .bind(&workspace_root)
        .fetch_one(&self.inner.pool)
        .await?;
        if adapter_count > 0 {
            return Err(DaemonError::State {
                code: "project_binding_has_adapters",
                message: "Remove the repository's Coding Agent integrations before unbinding it."
                    .to_owned(),
            });
        }
        let result = sqlx::query(
            "DELETE FROM project_bindings
             WHERE server_url = $1 AND workspace_root = $2 AND revision = $3",
        )
        .bind(&server_url)
        .bind(&workspace_root)
        .bind(request.expected_revision)
        .execute(&self.inner.pool)
        .await?;
        if result.rows_affected() != 1 {
            return Err(DaemonError::State {
                code: "project_binding_changed",
                message: format!(
                    "Project binding for {workspace_root} changed from the expected revision"
                ),
            });
        }
        Ok(DaemonProjectBindingRemoveResponse {
            workspace_root,
            removed: true,
        })
    }

    pub async fn list_project_agent_adapters(
        &self,
        request: DaemonProjectAgentAdapterListRequest,
    ) -> Result<DaemonProjectAgentAdapterListResponse, DaemonError> {
        agent_adapter::list(self, request).await
    }

    pub async fn install_project_agent_adapter(
        &self,
        request: DaemonProjectAgentAdapterInstallRequest,
    ) -> Result<DaemonProjectAgentAdapter, DaemonError> {
        agent_adapter::install(self, request).await
    }

    pub async fn remove_project_agent_adapter(
        &self,
        request: DaemonProjectAgentAdapterRemoveRequest,
    ) -> Result<DaemonProjectAgentAdapterRemoveResponse, DaemonError> {
        agent_adapter::remove(self, request).await
    }

    pub async fn server_request(
        &self,
        request: DaemonServerRequest,
    ) -> Result<DaemonServerResponse, DaemonError> {
        validate_server_proxy_path(&request.path)?;
        if request
            .body
            .as_ref()
            .is_some_and(|body| body.len() > 10 * 1024 * 1024)
        {
            return Err(DaemonError::InvalidRequest(
                "server request body exceeds 10 MiB".to_owned(),
            ));
        }
        let method = reqwest::Method::from_bytes(request.method.as_bytes())
            .map_err(|_| DaemonError::InvalidRequest("invalid server request method".to_owned()))?;
        if ![
            reqwest::Method::GET,
            reqwest::Method::POST,
            reqwest::Method::PUT,
            reqwest::Method::PATCH,
            reqwest::Method::DELETE,
        ]
        .contains(&method)
        {
            return Err(DaemonError::InvalidRequest(
                "server request method is not allowed".to_owned(),
            ));
        }
        let headers = filter_proxy_request_headers(request.headers);
        let server_url = self.project_config().server_url;
        let cacheable = method == reqwest::Method::GET;
        let response = match execute_authenticated_server_request(
            self,
            method,
            &request.path,
            &headers,
            request.body.map(String::into_bytes),
        )
        .await
        {
            Ok(response) => response,
            Err(error) if cacheable && error.is_retryable() => {
                if let Some(cached) =
                    load_cached_server_response(&self.inner.pool, &server_url, &request.path)
                        .await?
                {
                    return Ok(cached);
                }
                return Err(error);
            }
            Err(error) => return Err(error),
        };
        let status = response.status().as_u16();
        let headers = filter_proxy_response_headers(response.headers());
        let body = match response.text().await {
            Ok(body) => body,
            Err(error) if cacheable => {
                if let Some(cached) =
                    load_cached_server_response(&self.inner.pool, &server_url, &request.path)
                        .await?
                {
                    return Ok(cached);
                }
                return Err(error.into());
            }
            Err(error) => return Err(error.into()),
        };
        let response = DaemonServerResponse {
            status,
            headers,
            body,
        };
        if cacheable && ((200..300).contains(&status) || status == 404) {
            save_cached_server_response(&self.inner.pool, &server_url, &request.path, &response)
                .await?;
        } else if cacheable
            && is_retryable_http_status(status)
            && let Some(cached) =
                load_cached_server_response(&self.inner.pool, &server_url, &request.path).await?
        {
            return Ok(cached);
        }
        Ok(response)
    }

    pub(crate) fn project_config_view(&self) -> DaemonProjectConfig {
        let project_config = self.project_config();
        let readiness = project_config.readiness();
        DaemonProjectConfig {
            server_url: project_config.server_url,
            project_id: project_config.project_id,
            has_access_token: project_config.access_token.is_some(),
            has_refresh_token: project_config.refresh_token.is_some(),
            ready: readiness.ready,
            missing_fields: readiness.missing_fields,
        }
    }

    pub async fn health(&self) -> DaemonHealth {
        let schema_version = current_schema_version(&self.inner.pool).await.unwrap_or(0);
        let project_config = self.project_config();
        DaemonHealth {
            daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
            server_url: project_config.server_url,
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

    pub fn mcp_status(&self) -> DaemonMcpStatus {
        DaemonMcpStatus {
            running: false,
            endpoint: None,
            adapters: Vec::new(),
        }
    }

    pub async fn sync_status(&self) -> Result<DaemonSyncStatus, DaemonError> {
        load_sync_status(self).await
    }

    pub async fn project_storage(
        &self,
        request: DaemonProjectStorageRequest,
    ) -> Result<DaemonProjectStorage, DaemonError> {
        project_storage::project_storage(self, request).await
    }

    pub async fn replace_project_storage(
        &self,
        request: DaemonProjectStorageReplaceRequest,
    ) -> Result<DaemonProjectStorageMove, DaemonError> {
        project_storage::replace_project_storage(self, request).await
    }

    pub async fn project_storage_move(
        &self,
        request: DaemonProjectStorageMoveRequest,
    ) -> Result<DaemonProjectStorageMove, DaemonError> {
        project_storage::project_storage_move(self, request).await
    }

    pub async fn reset_project_storage(
        &self,
        request: DaemonProjectStorageResetRequest,
    ) -> Result<DaemonProjectStorageMove, DaemonError> {
        project_storage::reset_project_storage(self, request).await
    }

    pub async fn clear_project_cache(
        &self,
        request: DaemonProjectCacheClearRequest,
    ) -> Result<DaemonProjectStorage, DaemonError> {
        project_storage::clear_project_cache(self, request).await
    }

    pub async fn memory_cache(
        &self,
        request: DaemonMemoryCacheRequest,
    ) -> Result<DaemonMemoryCacheStatus, DaemonError> {
        commit_sync::memory_cache(self, request).await
    }

    pub async fn project_checkout(
        &self,
        request: DaemonProjectCheckoutRequest,
    ) -> Result<DaemonProjectCheckout, DaemonError> {
        commit_sync::project_checkout(self, request).await
    }

    pub async fn activate_memory(
        &self,
        request: ActivateMemoryRequest,
    ) -> Result<ActivateMemoryResponse, DaemonError> {
        search::activate_memory(self, request).await
    }

    pub async fn load_memory(
        &self,
        request: LoadMemoryRequest,
    ) -> Result<LoadMemoryResponse, DaemonError> {
        search::load_memory(self, request).await
    }

    pub async fn record_agent_run_event(
        &self,
        request: RecordAgentRunEventRequest,
    ) -> Result<RecordAgentRunEventResponse, DaemonError> {
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::record_agent_run_event(&self.inner.pool, request).await
    }

    pub async fn list_issue_board(
        &self,
        request: IssueBoardListRequest,
    ) -> Result<IssueBoardResponse, DaemonError> {
        let project_id = request.project_id.trim();
        if project_id.is_empty() {
            return Err(DaemonError::InvalidRequest(
                "project_id must not be empty".to_owned(),
            ));
        }
        self.ensure_native_issues_imported(project_id).await?;
        let runs = work_tracking::load_project_runs(&self.inner.pool, project_id).await?;
        let (now, stale_before): (String, String) = sqlx::query_as(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                    strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-24 hours')",
        )
        .fetch_one(&self.inner.pool)
        .await?;
        let issues = work_tracking::project_native_issue_board(
            &self.inner.pool,
            project_id,
            &runs,
            &now,
            &stale_before,
        )
        .await?;
        let valid_issue_numbers = issues
            .iter()
            .map(|issue| issue.issue_number)
            .collect::<std::collections::BTreeSet<_>>();
        let mut unlinked_runs = runs
            .into_iter()
            .filter(|run| match run.issue_number {
                Some(number) => !valid_issue_numbers.contains(&number),
                None => true,
            })
            .map(|run| work_tracking::project_agent_run(run, &now))
            .collect::<Vec<_>>();
        unlinked_runs.sort_by(|left, right| {
            right
                .last_seen_at
                .cmp(&left.last_seen_at)
                .then_with(|| right.run_id.cmp(&left.run_id))
        });
        unlinked_runs.truncate(100);
        Ok(IssueBoardResponse {
            project_id: project_id.to_owned(),
            effective_hash: work_tracking::native_board_hash(&issues),
            issues,
            unlinked_runs,
            diagnostics: Vec::new(),
        })
    }

    pub async fn get_issue_detail(
        &self,
        request: IssueDetailRequest,
    ) -> Result<IssueDetailResponse, DaemonError> {
        let project_id = request.project_id.trim();
        if project_id.is_empty() {
            return Err(DaemonError::InvalidRequest(
                "project_id must not be empty".to_owned(),
            ));
        }
        if !(1..=999).contains(&request.issue_number) {
            return Err(DaemonError::InvalidRequest(
                "issue_number must be between 1 and 999".to_owned(),
            ));
        }
        self.ensure_native_issues_imported(project_id).await?;
        let runs = work_tracking::load_project_runs(&self.inner.pool, project_id).await?;
        let (now, stale_before): (String, String) = sqlx::query_as(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                    strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-24 hours')",
        )
        .fetch_one(&self.inner.pool)
        .await?;
        work_tracking::load_native_issue_detail(
            &self.inner.pool,
            project_id,
            request.issue_number,
            &runs,
            &now,
            &stale_before,
        )
        .await
    }

    pub async fn get_issue(
        &self,
        request: GetIssueRequest,
    ) -> Result<IssueDetailResponse, DaemonError> {
        let (project_id, issue_number) =
            match (request.issue_id.as_deref(), request.issue_key.as_deref()) {
                (Some(issue_id), None) => {
                    work_tracking::resolve_native_issue_identity(&self.inner.pool, issue_id)
                        .await?
                        .ok_or_else(|| DaemonError::NotFound(format!("Issue {issue_id}")))?
                }
                (None, Some(issue_key)) => {
                    let project_id = request.project_id.as_deref().ok_or_else(|| {
                        DaemonError::InvalidRequest(
                            "project_id is required when resolving by issue_key".to_owned(),
                        )
                    })?;
                    let issue_number = work_tracking::parse_issue_reference(issue_key)?;
                    let project_id = project_id.trim();
                    work_tracking::ensure_native_issue_in_project(
                        &self.inner.pool,
                        project_id,
                        issue_number,
                    )
                    .await?
                    .ok_or_else(|| {
                        DaemonError::NotFound(format!("{issue_key} in project {project_id}"))
                    })?;
                    (project_id.to_owned(), issue_number)
                }
                _ => {
                    return Err(DaemonError::InvalidRequest(
                        "get_issue requires exactly one of issue_id or issue_key".to_owned(),
                    ));
                }
            };
        let runs = work_tracking::load_project_runs(&self.inner.pool, &project_id).await?;
        let (now, stale_before): (String, String) = sqlx::query_as(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                    strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-24 hours')",
        )
        .fetch_one(&self.inner.pool)
        .await?;
        work_tracking::load_native_issue_detail(
            &self.inner.pool,
            &project_id,
            issue_number,
            &runs,
            &now,
            &stale_before,
        )
        .await
    }

    pub async fn export_issue(
        &self,
        request: ExportIssueRequest,
    ) -> Result<ExportIssueResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let issue_number = work_tracking::parse_issue_reference(&request.issue_key)?;
        let runs = work_tracking::load_project_runs(&self.inner.pool, &request.project_id).await?;
        let (now, stale_before): (String, String) = sqlx::query_as(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                    strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-24 hours')",
        )
        .fetch_one(&self.inner.pool)
        .await?;
        let detail = work_tracking::load_native_issue_detail(
            &self.inner.pool,
            &request.project_id,
            issue_number,
            &runs,
            &now,
            &stale_before,
        )
        .await?;
        Ok(ExportIssueResponse {
            issue_key: detail.issue.issue_key.clone(),
            filename: work_tracking::issue_export_filename(issue_number),
            markdown: work_tracking::render_issue_markdown(
                &detail.issue,
                &detail.body,
                &detail.acceptance_criteria,
            ),
        })
    }
    pub async fn create_issue(
        &self,
        request: CreateIssueRequest,
    ) -> Result<IssueMutationResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::create_issue(&self.inner.pool, request).await
    }

    pub async fn update_issue(
        &self,
        request: UpdateIssueRequest,
    ) -> Result<IssueMutationResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::update_issue(&self.inner.pool, request).await
    }

    pub async fn apply_issue_gate(
        &self,
        request: ApplyIssueGateRequest,
    ) -> Result<IssueMutationResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::apply_issue_gate(&self.inner.pool, request).await
    }

    pub async fn remove_issue(
        &self,
        request: RemoveIssueRequest,
    ) -> Result<IssueRemovalResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::remove_issue(&self.inner.pool, request).await
    }

    pub async fn start_issue_work(
        &self,
        request: StartIssueWorkRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        if let Some(run_id) = &request.run_id {
            work_tracking::load_agent_run_for_project(
                &self.inner.pool,
                &request.project_id,
                run_id,
            )
            .await?
            .ok_or_else(|| DaemonError::NotFound(format!("AgentRun {run_id}")))?;
        }
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::start_issue_work(&self.inner.pool, request).await
    }

    pub async fn request_issue_closure(
        &self,
        request: RequestIssueClosureRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        if let Some(run_id) = &request.run_id {
            work_tracking::load_agent_run_for_project(
                &self.inner.pool,
                &request.project_id,
                run_id,
            )
            .await?
            .ok_or_else(|| DaemonError::NotFound(format!("AgentRun {run_id}")))?;
        }
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::request_issue_closure(&self.inner.pool, request).await
    }

    pub async fn pause_issue_work(
        &self,
        request: PauseIssueRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::pause_issue_work(&self.inner.pool, request).await
    }

    pub async fn resume_issue_work(
        &self,
        request: ResumeIssueRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        self.ensure_native_issues_imported(&request.project_id)
            .await?;
        let _guard = self.inner.agent_run_lock.lock().await;
        work_tracking::resume_issue_work(&self.inner.pool, request).await
    }

    async fn ensure_native_issues_imported(&self, project_id: &str) -> Result<(), DaemonError> {
        if work_tracking::native_issue_import_completed(&self.inner.pool, project_id).await? {
            return Ok(());
        }
        let effective = search::load_effective_memory(self, project_id).await?;
        let runs = work_tracking::load_project_runs(&self.inner.pool, project_id).await?;
        let (now, stale_before): (String, String) = sqlx::query_as(
            "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                    strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-24 hours')",
        )
        .fetch_one(&self.inner.pool)
        .await?;
        let (mut cards, _) = work_tracking::project_issue_board(
            project_id,
            effective.resources.as_ref(),
            &runs,
            &now,
        );
        let _guard = self.inner.agent_run_lock.lock().await;
        if work_tracking::native_issue_import_completed(&self.inner.pool, project_id).await? {
            return Ok(());
        }
        work_tracking::reconcile_issue_workflow_states(
            &self.inner.pool,
            project_id,
            &mut cards,
            &stale_before,
        )
        .await?;
        work_tracking::import_legacy_issues(
            &self.inner.pool,
            project_id,
            &cards,
            effective.resources.as_ref(),
        )
        .await
    }

    pub async fn search_index_status(
        &self,
        request: SearchIndexProjectRequest,
    ) -> Result<SearchIndexStatus, DaemonError> {
        search::search_index_status(self, request).await
    }

    pub async fn rebuild_search_index(
        &self,
        request: SearchIndexProjectRequest,
    ) -> Result<SearchIndexStatus, DaemonError> {
        search::rebuild_search_index(self, request).await
    }

    pub async fn list_retrieval_runs(
        &self,
        request: RetrievalRunListRequest,
    ) -> Result<RetrievalRunListResponse, DaemonError> {
        retrieval_history::list_retrieval_runs(self, request).await
    }

    pub async fn get_retrieval_run(
        &self,
        request: RetrievalRunRequest,
    ) -> Result<RetrievalRunDetail, DaemonError> {
        retrieval_history::get_retrieval_run(self, request).await
    }

    pub async fn create_evaluation_case(
        &self,
        request: CreateEvaluationCaseRequest,
    ) -> Result<EvaluationCaseDetail, DaemonError> {
        retrieval_history::create_evaluation_case(self, request).await
    }

    pub async fn resolve_evaluation_case(
        &self,
        request: ResolveEvaluationCaseRequest,
    ) -> Result<EvaluationCaseDetail, DaemonError> {
        retrieval_history::resolve_evaluation_case(self, request).await
    }

    pub async fn clear_retrieval_runs(
        &self,
        request: ClearRetrievalRunsRequest,
    ) -> Result<ClearRetrievalRunsResponse, DaemonError> {
        retrieval_history::clear_retrieval_runs(self, request).await
    }

    pub async fn export_evaluation_set(
        &self,
        request: ExportEvaluationSetRequest,
    ) -> Result<ExportEvaluationSetResponse, DaemonError> {
        retrieval_history::export_evaluation_set(self, request).await
    }

    pub async fn retry_sync(
        &self,
        request: DaemonSyncRetryRequest,
    ) -> Result<DaemonRetryResponse, DaemonError> {
        let retry_id = format!("retry_{}", Uuid::new_v4().simple());
        let channel = request.channel.as_str();

        sqlx::query(
            "INSERT INTO sync_retries (retry_id, channel)
             VALUES ($1, $2)",
        )
        .bind(&retry_id)
        .bind(channel)
        .execute(&self.inner.pool)
        .await?;

        let retry_drafts = matches!(
            request.channel,
            SyncRetryChannel::Drafts | SyncRetryChannel::All
        );
        let retry_commits = matches!(
            request.channel,
            SyncRetryChannel::Commits | SyncRetryChannel::All
        );
        if retry_drafts {
            sqlx::query(
                "UPDATE local_draft_operations
                 SET sync_status = 'queued', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                 WHERE sync_status IN ('retrying', 'failed')",
            )
            .execute(&self.inner.pool)
            .await?;
        }
        self.run_sync_channels(retry_drafts, retry_commits, false)
            .await?;

        Ok(DaemonRetryResponse {
            retry_id,
            started: true,
        })
    }

    pub async fn store_draft_operation(
        &self,
        request: DaemonDraftOperationRequest,
    ) -> Result<DaemonDraftOperationResponse, DaemonError> {
        request.op.validate(request.resource)?;
        if request.op.has_text_update() {
            let _sync_guard = self.inner.sync_lock.lock().await;
            let _mutation_guard = self.inner.draft_mutation_lock.lock().await;
            let request = self.materialize_text_update(request).await?;
            return self.persist_draft_operation(request).await;
        }
        if request.op.delete.is_some() || request.op.discard.is_some() {
            let _sync_guard = self.inner.sync_lock.lock().await;
            let _mutation_guard = self.inner.draft_mutation_lock.lock().await;
            return self.persist_draft_operation(request).await;
        }

        let _mutation_guard = self.inner.draft_mutation_lock.lock().await;
        self.persist_draft_operation(request).await
    }

    async fn materialize_text_update(
        &self,
        mut request: DaemonDraftOperationRequest,
    ) -> Result<DaemonDraftOperationRequest, DaemonError> {
        let update = request
            .op
            .update
            .take()
            .and_then(DaemonUpdateDraftOperation::into_text)
            .ok_or_else(|| {
                DaemonError::InvalidRequest(
                    "draft operation does not contain a text replacement update".to_owned(),
                )
            })?;
        let loaded = search::load_memory(
            self,
            LoadMemoryRequest {
                project_id: request.project_id.clone(),
                ids: vec![update.id.clone()],
                known_hashes: BTreeMap::new(),
            },
        )
        .await?;
        let resource = loaded.resources.into_iter().next().ok_or_else(|| {
            DaemonError::NotFound(format!("memory resource {} is not available", update.id))
        })?;
        if resource.resource_id != update.id {
            return Err(DaemonError::InvalidRequest(
                "text replacement update id must be a stable resource id, not a path".to_owned(),
            ));
        }
        if !memory_kind_matches_resource(resource.kind, request.resource) {
            return Err(DaemonError::InvalidRequest(
                "text replacement resource kind does not match its target".to_owned(),
            ));
        }
        if resource.content_hash != update.expected_hash {
            return Err(DaemonError::State {
                code: "memory_content_changed",
                message: format!(
                    "Memory resource {} changed from expected hash {}; reload it before updating (current hash: {})",
                    update.id, update.expected_hash, resource.content_hash
                ),
            });
        }
        let content = resource.content.ok_or_else(|| DaemonError::State {
            code: "memory_content_unavailable",
            message: format!(
                "Memory resource {} did not include content for replacement",
                update.id
            ),
        })?;
        let content = apply_exact_text_replacements(&content, &update.replacements)?;
        request.op.update = Some(DaemonUpdateDraftOperation::Content(
            DaemonContentDraftUpdate {
                id: update.id,
                content: DaemonDraftContent::from_resource(request.resource, content),
                description: update.description,
            },
        ));
        request.op.validate(request.resource)?;
        Ok(request)
    }

    async fn persist_draft_operation(
        &self,
        mut request: DaemonDraftOperationRequest,
    ) -> Result<DaemonDraftOperationResponse, DaemonError> {
        let source = request
            .source
            .unwrap_or(DaemonDraftOperationSource::Desktop);
        let requested_base_commit_id = request.base_commit_id;
        let new_draft_base_commit_id = match requested_base_commit_id.as_deref() {
            Some(commit_id) => Some(commit_id.to_owned()),
            None => {
                commit_sync::current_base_commit_id(
                    &self.inner.pool,
                    &request.project_id,
                    request.scope,
                )
                .await?
            }
        };
        let mut tx = self.inner.pool.begin().await?;

        let draft_id = resolve_local_draft(
            &mut tx,
            LocalDraftResolutionInput {
                requested_draft_id: request.draft_id.as_deref(),
                project_id: &request.project_id,
                requested_base_commit_id: requested_base_commit_id.as_deref(),
                new_draft_base_commit_id: new_draft_base_commit_id.as_deref(),
                scope: request.scope,
                resource: request.resource,
                op: &mut request.op,
            },
        )
        .await?;
        let operation_json = serde_json::to_string(&request.op)?;
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
             SET reconciliation = 'unknown', reconciliation_candidate_id = NULL,
                 updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
             WHERE draft_id = $1",
        )
        .bind(&draft_id)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        self.request_sync();

        Ok(DaemonDraftOperationResponse {
            local_operation_id,
            draft_id,
            queued: true,
            sync_status: DraftOperationSyncStatus::Queued,
        })
    }

    pub async fn list_drafts(
        &self,
        query: DaemonDraftListQuery,
    ) -> Result<DaemonDraftListResponse, DaemonError> {
        list_local_drafts(&self.inner.pool, query).await
    }

    pub async fn get_draft(&self, draft_id: &str) -> Result<DaemonDraftDetail, DaemonError> {
        load_local_draft_detail(&self.inner.pool, draft_id).await
    }

    async fn drain_draft_queue(&self) -> Result<bool, DaemonError> {
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
                let retry_transient_failures = tokio::select! {
                    _ = interval.tick() => true,
                    _ = state.inner.sync_notify.notified() => false,
                };
                let _ = state.run_sync_cycle(retry_transient_failures).await;
            }
        }))
    }

    pub fn start_search_model_worker(&self) -> JoinHandle<()> {
        let models = self.inner.search_models.clone();
        models.begin_preparation();
        tokio::spawn(async move {
            let mut retry_delay = Duration::from_secs(5);
            loop {
                let attempt_models = models.clone();
                let result = tokio::task::spawn_blocking(move || attempt_models.prepare()).await;
                match result {
                    Ok(Ok(())) => break,
                    Ok(Err(error)) => {
                        tracing::warn!("search model preparation failed: {}", error.message);
                    }
                    Err(error) => {
                        tracing::error!("search model preparation worker failed: {error}");
                    }
                }
                tokio::time::sleep(retry_delay).await;
                retry_delay = retry_delay.saturating_mul(2).min(Duration::from_secs(60));
                models.begin_preparation();
            }
        })
    }

    pub fn request_sync(&self) {
        if self.inner.config.sync.enabled {
            self.inner.sync_notify.notify_one();
        }
    }

    async fn run_sync_cycle(&self, retry_transient_failures: bool) -> Result<(), DaemonError> {
        self.run_sync_channels(true, true, retry_transient_failures)
            .await
    }

    async fn run_sync_channels(
        &self,
        sync_drafts: bool,
        sync_commits: bool,
        retry_transient_failures: bool,
    ) -> Result<(), DaemonError> {
        let _sync_guard = self.inner.sync_lock.lock().await;
        async {
            if !self.project_config().server_readiness().ready {
                return Ok(());
            }
            let mut first_error = None;
            if sync_drafts {
                let draft_result = async {
                    if retry_transient_failures {
                        queue_retrying_operations(&self.inner.pool).await?;
                    }
                    upsert_meta_timestamp(&self.inner.pool, META_DRAFT_SYNC_LAST_ATTEMPT_AT)
                        .await?;
                    let queue_converged = self.drain_draft_queue().await?;
                    self.pull_draft_events().await?;
                    if queue_converged {
                        upsert_meta_timestamp(&self.inner.pool, META_DRAFT_SYNC_LAST_SUCCESS_AT)
                            .await?;
                    }
                    Ok::<(), DaemonError>(())
                }
                .await;
                if let Err(error) = draft_result {
                    first_error = Some(error);
                }
            }
            if sync_commits
                && let Err(error) = commit_sync::run(self).await
                && first_error.is_none()
            {
                first_error = Some(error);
            }
            match first_error {
                Some(error) => Err(error),
                None => Ok(()),
            }
        }
        .await
    }
}

async fn load_startup_credentials(
    credential_store: Arc<dyn CredentialStore>,
    timeout: Duration,
) -> Option<ServerCredentials> {
    match tokio::time::timeout(timeout, load_server_credentials(credential_store)).await {
        Ok(Ok(credentials)) => credentials,
        Ok(Err(error)) => {
            tracing::warn!(
                "Server credentials are unavailable; continuing daemon startup without authentication: {error}"
            );
            None
        }
        Err(_) => {
            tracing::warn!(
                "Timed out loading Server credentials after {} ms; continuing daemon startup without authentication",
                timeout.as_millis()
            );
            None
        }
    }
}

macro_rules! dispatch_async {
    ($self:expr, $payload:expr, $method:ident) => {{
        let payload = $self.decode_dispatch_payload::<_>($payload);
        match payload {
            Ok(payload) => $self
                .$method(payload)
                .await
                .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
            Err(error) => Err(error),
        }
    }};
}

macro_rules! dispatch_result_async {
    ($self:expr, $method:ident) => {
        $self
            .$method()
            .await
            .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from))
    };
}

macro_rules! dispatch_value {
    ($self:expr, $method:ident) => {
        serde_json::to_value($self.$method()).map_err(DaemonError::from)
    };
    ($self:expr, $method:ident, async) => {
        serde_json::to_value($self.$method().await).map_err(DaemonError::from)
    };
}

#[derive(Clone)]
pub struct DaemonIpcService {
    state: DaemonState,
}

impl DaemonIpcService {
    pub fn new(state: DaemonState) -> Self {
        Self { state }
    }

    pub async fn health(&self) -> DaemonHealth {
        self.state.health().await
    }

    pub fn project_config(&self) -> DaemonProjectConfig {
        self.state.project_config_status()
    }

    pub async fn replace_project_config(
        &self,
        request: DaemonProjectConfigUpdateRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        self.state.replace_project_config(request).await
    }

    pub async fn select_project(
        &self,
        request: DaemonProjectSelectionRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        self.state.select_project(request).await
    }

    pub async fn resolve_project_binding(
        &self,
        request: DaemonProjectBindingResolveRequest,
    ) -> Result<DaemonProjectBinding, DaemonError> {
        self.state.resolve_project_binding(request).await
    }

    pub async fn list_project_bindings(
        &self,
        request: DaemonProjectBindingListRequest,
    ) -> Result<DaemonProjectBindingListResponse, DaemonError> {
        self.state.list_project_bindings(request).await
    }

    pub async fn replace_project_binding(
        &self,
        request: DaemonProjectBindingReplaceRequest,
    ) -> Result<DaemonProjectBinding, DaemonError> {
        self.state.replace_project_binding(request).await
    }

    pub async fn remove_project_binding(
        &self,
        request: DaemonProjectBindingRemoveRequest,
    ) -> Result<DaemonProjectBindingRemoveResponse, DaemonError> {
        self.state.remove_project_binding(request).await
    }

    pub async fn list_project_agent_adapters(
        &self,
        request: DaemonProjectAgentAdapterListRequest,
    ) -> Result<DaemonProjectAgentAdapterListResponse, DaemonError> {
        self.state.list_project_agent_adapters(request).await
    }

    pub async fn install_project_agent_adapter(
        &self,
        request: DaemonProjectAgentAdapterInstallRequest,
    ) -> Result<DaemonProjectAgentAdapter, DaemonError> {
        self.state.install_project_agent_adapter(request).await
    }

    pub async fn remove_project_agent_adapter(
        &self,
        request: DaemonProjectAgentAdapterRemoveRequest,
    ) -> Result<DaemonProjectAgentAdapterRemoveResponse, DaemonError> {
        self.state.remove_project_agent_adapter(request).await
    }

    pub async fn sync_status(&self) -> Result<DaemonSyncStatus, DaemonError> {
        self.state.sync_status().await
    }

    pub async fn project_storage(
        &self,
        request: DaemonProjectStorageRequest,
    ) -> Result<DaemonProjectStorage, DaemonError> {
        self.state.project_storage(request).await
    }

    pub async fn replace_project_storage(
        &self,
        request: DaemonProjectStorageReplaceRequest,
    ) -> Result<DaemonProjectStorageMove, DaemonError> {
        self.state.replace_project_storage(request).await
    }

    pub async fn project_storage_move(
        &self,
        request: DaemonProjectStorageMoveRequest,
    ) -> Result<DaemonProjectStorageMove, DaemonError> {
        self.state.project_storage_move(request).await
    }

    pub async fn reset_project_storage(
        &self,
        request: DaemonProjectStorageResetRequest,
    ) -> Result<DaemonProjectStorageMove, DaemonError> {
        self.state.reset_project_storage(request).await
    }

    pub async fn clear_project_cache(
        &self,
        request: DaemonProjectCacheClearRequest,
    ) -> Result<DaemonProjectStorage, DaemonError> {
        self.state.clear_project_cache(request).await
    }

    pub async fn memory_cache(
        &self,
        request: DaemonMemoryCacheRequest,
    ) -> Result<DaemonMemoryCacheStatus, DaemonError> {
        self.state.memory_cache(request).await
    }

    pub async fn project_checkout(
        &self,
        request: DaemonProjectCheckoutRequest,
    ) -> Result<DaemonProjectCheckout, DaemonError> {
        self.state.project_checkout(request).await
    }

    pub async fn activate_memory(
        &self,
        request: ActivateMemoryRequest,
    ) -> Result<ActivateMemoryResponse, DaemonError> {
        self.state.activate_memory(request).await
    }

    pub async fn load_memory(
        &self,
        request: LoadMemoryRequest,
    ) -> Result<LoadMemoryResponse, DaemonError> {
        self.state.load_memory(request).await
    }

    pub async fn record_agent_run_event(
        &self,
        request: RecordAgentRunEventRequest,
    ) -> Result<RecordAgentRunEventResponse, DaemonError> {
        self.state.record_agent_run_event(request).await
    }

    pub async fn list_issue_board(
        &self,
        request: IssueBoardListRequest,
    ) -> Result<IssueBoardResponse, DaemonError> {
        self.state.list_issue_board(request).await
    }

    pub async fn get_issue_detail(
        &self,
        request: IssueDetailRequest,
    ) -> Result<IssueDetailResponse, DaemonError> {
        self.state.get_issue_detail(request).await
    }

    pub async fn get_issue(
        &self,
        request: GetIssueRequest,
    ) -> Result<IssueDetailResponse, DaemonError> {
        self.state.get_issue(request).await
    }

    pub async fn export_issue(
        &self,
        request: ExportIssueRequest,
    ) -> Result<ExportIssueResponse, DaemonError> {
        self.state.export_issue(request).await
    }

    pub async fn create_issue(
        &self,
        request: CreateIssueRequest,
    ) -> Result<IssueMutationResponse, DaemonError> {
        self.state.create_issue(request).await
    }

    pub async fn update_issue(
        &self,
        request: UpdateIssueRequest,
    ) -> Result<IssueMutationResponse, DaemonError> {
        self.state.update_issue(request).await
    }

    pub async fn apply_issue_gate(
        &self,
        request: ApplyIssueGateRequest,
    ) -> Result<IssueMutationResponse, DaemonError> {
        self.state.apply_issue_gate(request).await
    }

    pub async fn remove_issue(
        &self,
        request: RemoveIssueRequest,
    ) -> Result<IssueRemovalResponse, DaemonError> {
        self.state.remove_issue(request).await
    }

    pub async fn start_issue_work(
        &self,
        request: StartIssueWorkRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        self.state.start_issue_work(request).await
    }

    pub async fn request_issue_closure(
        &self,
        request: RequestIssueClosureRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        self.state.request_issue_closure(request).await
    }

    pub async fn pause_issue_work(
        &self,
        request: PauseIssueRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        self.state.pause_issue_work(request).await
    }

    pub async fn resume_issue_work(
        &self,
        request: ResumeIssueRequest,
    ) -> Result<IssueWorkflowMutationResponse, DaemonError> {
        self.state.resume_issue_work(request).await
    }

    pub async fn search_index_status(
        &self,
        request: SearchIndexProjectRequest,
    ) -> Result<SearchIndexStatus, DaemonError> {
        self.state.search_index_status(request).await
    }

    pub async fn rebuild_search_index(
        &self,
        request: SearchIndexProjectRequest,
    ) -> Result<SearchIndexStatus, DaemonError> {
        self.state.rebuild_search_index(request).await
    }

    pub async fn list_retrieval_runs(
        &self,
        request: RetrievalRunListRequest,
    ) -> Result<RetrievalRunListResponse, DaemonError> {
        self.state.list_retrieval_runs(request).await
    }

    pub async fn get_retrieval_run(
        &self,
        request: RetrievalRunRequest,
    ) -> Result<RetrievalRunDetail, DaemonError> {
        self.state.get_retrieval_run(request).await
    }

    pub async fn create_evaluation_case(
        &self,
        request: CreateEvaluationCaseRequest,
    ) -> Result<EvaluationCaseDetail, DaemonError> {
        self.state.create_evaluation_case(request).await
    }

    pub async fn resolve_evaluation_case(
        &self,
        request: ResolveEvaluationCaseRequest,
    ) -> Result<EvaluationCaseDetail, DaemonError> {
        self.state.resolve_evaluation_case(request).await
    }

    pub async fn clear_retrieval_runs(
        &self,
        request: ClearRetrievalRunsRequest,
    ) -> Result<ClearRetrievalRunsResponse, DaemonError> {
        self.state.clear_retrieval_runs(request).await
    }

    pub async fn export_evaluation_set(
        &self,
        request: ExportEvaluationSetRequest,
    ) -> Result<ExportEvaluationSetResponse, DaemonError> {
        self.state.export_evaluation_set(request).await
    }

    pub async fn retry_sync(
        &self,
        request: DaemonSyncRetryRequest,
    ) -> Result<DaemonRetryResponse, DaemonError> {
        self.state.retry_sync(request).await
    }

    pub fn mcp_status(&self) -> DaemonMcpStatus {
        self.state.mcp_status()
    }

    pub async fn list_drafts(
        &self,
        query: DaemonDraftListQuery,
    ) -> Result<DaemonDraftListResponse, DaemonError> {
        self.state.list_drafts(query).await
    }

    pub async fn get_draft(&self, draft_id: &str) -> Result<DaemonDraftDetail, DaemonError> {
        self.state.get_draft(draft_id).await
    }

    pub async fn store_draft_operation(
        &self,
        request: DaemonDraftOperationRequest,
    ) -> Result<DaemonDraftOperationResponse, DaemonError> {
        self.state.store_draft_operation(request).await
    }

    pub async fn server_request(
        &self,
        request: DaemonServerRequest,
    ) -> Result<DaemonServerResponse, DaemonError> {
        self.state.server_request(request).await
    }

    pub async fn dispatch(&self, request: DaemonIpcRequest) -> DaemonIpcResponse {
        let result = match request.method.as_str() {
            "health" => dispatch_value!(self, health, async),
            "project_config" => dispatch_value!(self, project_config),
            "replace_project_config" => {
                dispatch_async!(self, request.payload, replace_project_config)
            }
            "select_project" => dispatch_async!(self, request.payload, select_project),
            "resolve_project_binding" => {
                dispatch_async!(self, request.payload, resolve_project_binding)
            }
            "list_project_bindings" => {
                dispatch_async!(self, request.payload, list_project_bindings)
            }
            "replace_project_binding" => {
                dispatch_async!(self, request.payload, replace_project_binding)
            }
            "remove_project_binding" => {
                dispatch_async!(self, request.payload, remove_project_binding)
            }
            "list_project_agent_adapters" => {
                dispatch_async!(self, request.payload, list_project_agent_adapters)
            }
            "install_project_agent_adapter" => {
                dispatch_async!(self, request.payload, install_project_agent_adapter)
            }
            "remove_project_agent_adapter" => {
                dispatch_async!(self, request.payload, remove_project_agent_adapter)
            }
            "sync_status" => dispatch_result_async!(self, sync_status),
            "project_storage" => dispatch_async!(self, request.payload, project_storage),
            "replace_project_storage" => {
                dispatch_async!(self, request.payload, replace_project_storage)
            }
            "project_storage_move" => {
                dispatch_async!(self, request.payload, project_storage_move)
            }
            "reset_project_storage" => {
                dispatch_async!(self, request.payload, reset_project_storage)
            }
            "clear_project_cache" => {
                dispatch_async!(self, request.payload, clear_project_cache)
            }
            "memory_cache" => dispatch_async!(self, request.payload, memory_cache),
            "project_checkout" => dispatch_async!(self, request.payload, project_checkout),
            "activate_memory" => dispatch_async!(self, request.payload, activate_memory),
            "load_memory" => dispatch_async!(self, request.payload, load_memory),
            "record_agent_run_event" => {
                dispatch_async!(self, request.payload, record_agent_run_event)
            }
            "list_issue_board" => dispatch_async!(self, request.payload, list_issue_board),
            "get_issue_detail" => dispatch_async!(self, request.payload, get_issue_detail),
            "get_issue" => dispatch_async!(self, request.payload, get_issue),
            "export_issue" => dispatch_async!(self, request.payload, export_issue),
            "create_issue" => dispatch_async!(self, request.payload, create_issue),
            "update_issue" => dispatch_async!(self, request.payload, update_issue),
            "apply_issue_gate" => dispatch_async!(self, request.payload, apply_issue_gate),
            "remove_issue" => dispatch_async!(self, request.payload, remove_issue),
            "start_issue_work" => {
                dispatch_async!(self, request.payload, start_issue_work)
            }
            "request_issue_closure" => {
                dispatch_async!(self, request.payload, request_issue_closure)
            }
            "pause_issue" => {
                dispatch_async!(self, request.payload, pause_issue_work)
            }
            "resume_issue" => {
                dispatch_async!(self, request.payload, resume_issue_work)
            }
            "search_index_status" => {
                dispatch_async!(self, request.payload, search_index_status)
            }
            "rebuild_search_index" => {
                dispatch_async!(self, request.payload, rebuild_search_index)
            }
            "list_retrieval_runs" => {
                dispatch_async!(self, request.payload, list_retrieval_runs)
            }
            "get_retrieval_run" => dispatch_async!(self, request.payload, get_retrieval_run),
            "create_evaluation_case" => {
                dispatch_async!(self, request.payload, create_evaluation_case)
            }
            "resolve_evaluation_case" => {
                dispatch_async!(self, request.payload, resolve_evaluation_case)
            }
            "clear_retrieval_runs" => {
                dispatch_async!(self, request.payload, clear_retrieval_runs)
            }
            "export_evaluation_set" => {
                dispatch_async!(self, request.payload, export_evaluation_set)
            }
            "retry_sync" => dispatch_async!(self, request.payload, retry_sync),
            "mcp_status" => dispatch_value!(self, mcp_status),
            "list_drafts" => dispatch_async!(self, request.payload, list_drafts),
            "get_draft" => {
                let payload =
                    self.decode_dispatch_payload::<DaemonDraftDetailRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .get_draft(&payload.draft_id)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "store_draft_operation" => {
                dispatch_async!(self, request.payload, store_draft_operation)
            }
            "server_request" => dispatch_async!(self, request.payload, server_request),
            method => Err(DaemonError::InvalidRequest(format!(
                "unknown daemon IPC method: {method}"
            ))),
        };
        DaemonIpcResponse::from_result(result)
    }

    fn decode_dispatch_payload<T>(&self, payload: serde_json::Value) -> Result<T, DaemonError>
    where
        T: DeserializeOwned,
    {
        serde_json::from_value(payload).map_err(DaemonError::from)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Condvar, Mutex as StdMutex};

    use super::*;

    struct BlockingCredentialStore {
        gate: Arc<(StdMutex<bool>, Condvar)>,
    }

    impl CredentialStore for BlockingCredentialStore {
        fn load(&self) -> Result<Option<ServerCredentials>, CredentialStoreError> {
            let (ready, wake) = &*self.gate;
            let ready = ready.lock().unwrap();
            let _ = wake
                .wait_timeout_while(ready, Duration::from_secs(1), |ready| !*ready)
                .unwrap();
            Ok(Some(ServerCredentials {
                server_url: "https://clumsies.example.test".to_owned(),
                access_token: "access-token".to_owned(),
                refresh_token: None,
            }))
        }

        fn replace(&self, _credentials: &ServerCredentials) -> Result<(), CredentialStoreError> {
            Ok(())
        }

        fn clear(&self) -> Result<(), CredentialStoreError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn startup_continues_when_credential_store_blocks() {
        let gate = Arc::new((StdMutex::new(false), Condvar::new()));
        let store = Arc::new(BlockingCredentialStore { gate: gate.clone() });

        let credentials = tokio::time::timeout(
            Duration::from_millis(250),
            load_startup_credentials(store, Duration::from_millis(10)),
        )
        .await
        .expect("startup credential fallback must remain bounded");

        assert!(credentials.is_none());
        let (ready, wake) = &*gate;
        *ready.lock().unwrap() = true;
        wake.notify_all();
    }

    #[test]
    fn startup_credential_load_timeout_tolerates_slow_keychain_reads() {
        // A Keychain read right after unlock was measured at ~3.7 s; the
        // timeout must stay well above that so a slow-but-valid read does
        // not silently drop the session at startup.
        assert!(
            STARTUP_CREDENTIAL_LOAD_TIMEOUT >= Duration::from_secs(5),
            "startup credential load timeout must tolerate slow Keychain reads"
        );
    }
}
