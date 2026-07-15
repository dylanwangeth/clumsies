use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteRow, SqliteSynchronous,
};
use sqlx::{Row, SqlitePool};
use thiserror::Error;
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;
use uuid::Uuid;

mod commit_sync;
mod credentials;
mod ipc;
pub use commit_sync::{DaemonMemoryCacheRequest, DaemonMemoryCacheStatus};
pub use credentials::{
    CredentialStore, CredentialStoreError, KEYCHAIN_ACCOUNT, ServerCredentials,
    SystemCredentialStore,
};
pub use ipc::{DaemonIpcClient, DaemonIpcServer};

pub const APP_BUNDLE_IDENTIFIER: &str = "io.github.lilhammerfun.clumsies";
pub const DAEMON_AGENT_LABEL: &str = "io.github.lilhammerfun.clumsies.agent";
pub const DAEMON_MACH_SERVICE_NAME: &str = DAEMON_AGENT_LABEL;
pub const CURRENT_LOCAL_SCHEMA_VERSION: i64 = 9;
const META_DRAFT_EVENTS_CURSOR: &str = "draft_events_cursor";
const META_DRAFT_SYNC_LAST_ATTEMPT_AT: &str = "draft_sync_last_attempt_at";
const META_DRAFT_SYNC_LAST_SUCCESS_AT: &str = "draft_sync_last_success_at";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DaemonConfig {
    pub root_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub log_dir: PathBuf,
    pub launch_agents_dir: PathBuf,
    pub project: ProjectConfig,
    pub sync: SyncConfig,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectConfig {
    pub server_url: String,
    pub project_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncConfig {
    pub enabled: bool,
    pub interval: Duration,
}

impl DaemonConfig {
    pub fn from_env() -> Result<Self, DaemonError> {
        let mut paths = match env::var_os("CLUMSIES_DAEMON_ROOT") {
            Some(value) => DaemonRuntimePaths::for_root(PathBuf::from(value)),
            None => DaemonRuntimePaths::from_home(home_dir()?),
        };
        if let Some(value) = env::var_os("CLUMSIES_DAEMON_CACHE_DIR") {
            paths.cache_dir = PathBuf::from(value);
        }
        if let Some(value) = env::var_os("CLUMSIES_DAEMON_LOG_DIR") {
            paths.log_dir = PathBuf::from(value);
        }
        if let Some(value) = env::var_os("CLUMSIES_DAEMON_LAUNCH_AGENTS_DIR") {
            paths.launch_agents_dir = PathBuf::from(value);
        }
        let project = ProjectConfig::from_env();
        let sync = SyncConfig {
            enabled: parse_bool_env("CLUMSIES_SYNC_ENABLED")?.unwrap_or(true),
            interval: Duration::from_millis(
                parse_u64_env("CLUMSIES_SYNC_INTERVAL_MS")?
                    .unwrap_or(30_000)
                    .max(1),
            ),
        };
        Ok(Self {
            root_dir: paths.root_dir,
            cache_dir: paths.cache_dir,
            log_dir: paths.log_dir,
            launch_agents_dir: paths.launch_agents_dir,
            project,
            sync,
        })
    }

    pub fn for_root(root_dir: impl Into<PathBuf>) -> Self {
        let paths = DaemonRuntimePaths::for_root(root_dir.into());
        Self {
            root_dir: paths.root_dir,
            cache_dir: paths.cache_dir,
            log_dir: paths.log_dir,
            launch_agents_dir: paths.launch_agents_dir,
            project: ProjectConfig::default(),
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
        self.log_dir.clone()
    }

    pub fn launch_agent_plist_path(&self) -> PathBuf {
        self.launch_agents_dir
            .join(format!("{DAEMON_AGENT_LABEL}.plist"))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DaemonRuntimePaths {
    root_dir: PathBuf,
    cache_dir: PathBuf,
    log_dir: PathBuf,
    launch_agents_dir: PathBuf,
}

impl DaemonRuntimePaths {
    fn for_root(root_dir: PathBuf) -> Self {
        Self {
            cache_dir: root_dir.join("cache"),
            log_dir: root_dir.join("logs"),
            launch_agents_dir: root_dir.join("LaunchAgents"),
            root_dir,
        }
    }

    fn from_home(home: PathBuf) -> Self {
        Self {
            root_dir: home
                .join("Library")
                .join("Application Support")
                .join(APP_BUNDLE_IDENTIFIER),
            cache_dir: home
                .join("Library")
                .join("Caches")
                .join(APP_BUNDLE_IDENTIFIER),
            log_dir: home
                .join("Library")
                .join("Logs")
                .join(APP_BUNDLE_IDENTIFIER),
            launch_agents_dir: home.join("Library").join("LaunchAgents"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchAgentConfig {
    pub label: String,
    pub mach_service_name: String,
    pub program_path: PathBuf,
    pub plist_path: PathBuf,
    pub root_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub log_dir: PathBuf,
}

impl LaunchAgentConfig {
    pub fn from_daemon_config(config: &DaemonConfig, program_path: impl Into<PathBuf>) -> Self {
        Self {
            label: DAEMON_AGENT_LABEL.to_owned(),
            mach_service_name: DAEMON_MACH_SERVICE_NAME.to_owned(),
            program_path: program_path.into(),
            plist_path: config.launch_agent_plist_path(),
            root_dir: config.root_dir.clone(),
            cache_dir: config.cache_dir.clone(),
            log_dir: config.log_dir.clone(),
        }
    }

    pub fn standard_output_path(&self) -> PathBuf {
        self.log_dir.join("clumsiesd.out.log")
    }

    pub fn standard_error_path(&self) -> PathBuf {
        self.log_dir.join("clumsiesd.err.log")
    }

    pub fn plist_contents(&self) -> String {
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{program}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>MachServices</key>
  <dict>
    <key>{mach_service}</key>
    <true/>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLUMSIES_DAEMON_ROOT</key>
    <string>{root_dir}</string>
    <key>CLUMSIES_DAEMON_CACHE_DIR</key>
    <string>{cache_dir}</string>
    <key>CLUMSIES_DAEMON_LOG_DIR</key>
    <string>{log_dir}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
            label = escape_plist_value(&self.label),
            program = escape_plist_value(self.program_path.to_string_lossy().as_ref()),
            mach_service = escape_plist_value(&self.mach_service_name),
            root_dir = escape_plist_value(self.root_dir.to_string_lossy().as_ref()),
            cache_dir = escape_plist_value(self.cache_dir.to_string_lossy().as_ref()),
            log_dir = escape_plist_value(self.log_dir.to_string_lossy().as_ref()),
            stdout = escape_plist_value(self.standard_output_path().to_string_lossy().as_ref()),
            stderr = escape_plist_value(self.standard_error_path().to_string_lossy().as_ref()),
        )
    }

    pub fn install_plist(&self) -> Result<(), DaemonError> {
        if let Some(parent) = self.plist_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::create_dir_all(&self.root_dir)?;
        std::fs::create_dir_all(&self.cache_dir)?;
        std::fs::create_dir_all(&self.log_dir)?;
        let tmp_path = self.plist_path.with_extension("plist.tmp");
        std::fs::write(&tmp_path, self.plist_contents())?;
        set_owner_only_permissions(&tmp_path)?;
        std::fs::rename(tmp_path, &self.plist_path)?;
        Ok(())
    }

    pub fn ipc_endpoint(&self) -> DaemonIpcEndpoint {
        DaemonIpcEndpoint {
            transport: DaemonIpcTransport::MacosXpcMachService,
            service_name: self.mach_service_name.clone(),
        }
    }

    pub fn bootstrap_status(&self) -> DaemonBootstrapStatus {
        DaemonBootstrapStatus {
            label: self.label.clone(),
            mach_service_name: self.mach_service_name.clone(),
            plist_path: self.plist_path.display().to_string(),
            installed: self.plist_path.exists(),
            endpoint: self.ipc_endpoint(),
            runtime: LaunchAgentRuntimeStatus::not_bootstrapped(self.plist_path.exists(), None),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchAgentController {
    config: LaunchAgentConfig,
    domain: String,
}

impl LaunchAgentController {
    pub fn for_current_user(config: LaunchAgentConfig) -> Result<Self, DaemonError> {
        Ok(Self {
            config,
            domain: current_user_launchctl_domain()?,
        })
    }

    pub fn with_domain(config: LaunchAgentConfig, domain: impl Into<String>) -> Self {
        Self {
            config,
            domain: domain.into(),
        }
    }

    pub fn config(&self) -> &LaunchAgentConfig {
        &self.config
    }

    pub fn domain(&self) -> &str {
        &self.domain
    }

    pub fn service_target(&self) -> String {
        format!("{}/{}", self.domain, self.config.label)
    }

    pub fn bootstrap_args(&self) -> Vec<String> {
        vec![
            "bootstrap".to_owned(),
            self.domain.clone(),
            self.config.plist_path.display().to_string(),
        ]
    }

    pub fn bootout_args(&self) -> Vec<String> {
        vec!["bootout".to_owned(), self.service_target()]
    }

    pub fn kickstart_args(&self) -> Vec<String> {
        vec![
            "kickstart".to_owned(),
            "-k".to_owned(),
            self.service_target(),
        ]
    }

    pub fn print_args(&self) -> Vec<String> {
        vec!["print".to_owned(), self.service_target()]
    }

    pub fn status(&self) -> Result<DaemonBootstrapStatus, DaemonError> {
        let installed = self.config.plist_path.exists();
        let output = run_launchctl_allow_failure(&self.print_args())?;
        let runtime = if output.status.success() {
            LaunchAgentRuntimeStatus::from_launchctl_print(
                installed,
                &String::from_utf8_lossy(&output.stdout),
            )
        } else {
            LaunchAgentRuntimeStatus::not_bootstrapped(installed, command_output_message(&output))
        };
        Ok(self.config.bootstrap_status().with_runtime(runtime))
    }

    pub fn install(&self) -> Result<DaemonBootstrapStatus, DaemonError> {
        self.config.install_plist()?;
        self.status()
    }

    pub fn bootstrap(&self) -> Result<DaemonBootstrapStatus, DaemonError> {
        self.config.install_plist()?;
        run_launchctl_success(&self.bootstrap_args())?;
        self.status()
    }

    pub fn bootout(&self) -> Result<DaemonBootstrapStatus, DaemonError> {
        run_launchctl_success(&self.bootout_args())?;
        self.status()
    }

    pub fn kickstart(&self) -> Result<DaemonBootstrapStatus, DaemonError> {
        let status = self.status()?;
        if status.runtime.bootstrapped {
            run_launchctl_success(&self.kickstart_args())?;
        } else {
            self.config.install_plist()?;
            run_launchctl_success(&self.bootstrap_args())?;
        }
        self.status()
    }
}

fn current_user_launchctl_domain() -> Result<String, DaemonError> {
    if let Some(uid) = env::var("UID").ok().and_then(non_empty_string) {
        return Ok(format!("gui/{uid}"));
    }
    let output = Command::new("id").arg("-u").output()?;
    if !output.status.success() {
        return Err(DaemonError::Launchctl(format!(
            "id -u failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let uid = non_empty_string(String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .ok_or_else(|| DaemonError::Launchctl("id -u returned an empty uid".to_owned()))?;
    Ok(format!("gui/{uid}"))
}

fn run_launchctl_success(args: &[String]) -> Result<(), DaemonError> {
    let output = run_launchctl_allow_failure(args)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(DaemonError::Launchctl(format!(
            "launchctl {} failed: {}",
            args.join(" "),
            command_output_message(&output).unwrap_or_else(|| "no output".to_owned())
        )))
    }
}

fn run_launchctl_allow_failure(args: &[String]) -> Result<Output, DaemonError> {
    Ok(Command::new("launchctl").args(args).output()?)
}

fn command_output_message(output: &Output) -> Option<String> {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if !stderr.is_empty() {
        return Some(stderr);
    }
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !stdout.is_empty() {
        return Some(stdout);
    }
    output
        .status
        .code()
        .map(|code| format!("exit status {code}"))
}

fn escape_plist_value(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(unix)]
fn set_owner_only_permissions(path: &Path) -> Result<(), DaemonError> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = std::fs::metadata(path)?.permissions();
    permissions.set_mode(0o600);
    std::fs::set_permissions(path, permissions)?;
    Ok(())
}

#[cfg(not(unix))]
fn set_owner_only_permissions(_path: &Path) -> Result<(), DaemonError> {
    Ok(())
}

impl ProjectConfig {
    fn from_env() -> Self {
        Self {
            server_url: env::var("CLUMSIES_SERVER_URL")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_default(),
            project_id: env::var("CLUMSIES_PROJECT_ID")
                .ok()
                .and_then(non_empty_string),
        }
    }

    fn validate(&self) -> Result<(), DaemonError> {
        let url = reqwest::Url::parse(&self.server_url)
            .map_err(|error| DaemonError::InvalidConfig(format!("invalid server_url: {error}")))?;
        match url.scheme() {
            "http" | "https" => Ok(()),
            scheme => Err(DaemonError::InvalidConfig(format!(
                "server_url scheme must be http or https, got {scheme}"
            ))),
        }
    }
}

#[derive(Clone)]
struct RuntimeProjectConfig {
    server_url: String,
    project_id: Option<String>,
    access_token: Option<String>,
    refresh_token: Option<String>,
}

impl RuntimeProjectConfig {
    fn validate(&self) -> Result<(), DaemonError> {
        ProjectConfig {
            server_url: self.server_url.clone(),
            project_id: self.project_id.clone(),
        }
        .validate()?;
        if self.access_token.is_none() && self.refresh_token.is_some() {
            return Err(DaemonError::InvalidConfig(
                "refresh_token cannot be configured without access_token".to_owned(),
            ));
        }
        Ok(())
    }

    fn metadata(&self) -> ProjectConfig {
        ProjectConfig {
            server_url: self.server_url.clone(),
            project_id: self.project_id.clone(),
        }
    }

    fn credentials(&self) -> Option<ServerCredentials> {
        self.access_token
            .as_ref()
            .map(|access_token| ServerCredentials {
                server_url: self.server_url.clone(),
                access_token: access_token.clone(),
                refresh_token: self.refresh_token.clone(),
            })
    }

    fn readiness(&self) -> ProjectConfigReadiness {
        let mut missing_fields = Vec::new();
        if self.server_url.trim().is_empty() {
            missing_fields.push("server_url".to_owned());
        }
        if self.project_id.as_deref().is_none_or(str::is_empty) {
            missing_fields.push("project_id".to_owned());
        }
        if self.access_token.as_deref().is_none_or(str::is_empty) {
            missing_fields.push("access_token".to_owned());
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
    project_config: RwLock<RuntimeProjectConfig>,
    credential_store: Arc<dyn CredentialStore>,
    pool: SqlitePool,
    http: reqwest::Client,
    daemon_installation_id: String,
    sync_notify: Notify,
    sync_running: AtomicBool,
    commit_sync_running: AtomicBool,
    token_refresh: Mutex<()>,
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
        prepare_directories(&config)?;
        let pool = connect_local_db(&config.local_db_path()).await?;
        migrate_local_db(&pool).await?;
        let daemon_installation_id = load_or_create_installation_id(&pool).await?;
        let credentials = load_server_credentials(credential_store.clone()).await?;
        let project_config = load_project_config(&pool, &config.project, credentials).await?;

        Ok(Self {
            inner: Arc::new(DaemonInner {
                config,
                project_config: RwLock::new(project_config),
                credential_store,
                pool,
                http: reqwest::Client::new(),
                daemon_installation_id,
                sync_notify: Notify::new(),
                sync_running: AtomicBool::new(false),
                commit_sync_running: AtomicBool::new(false),
                token_refresh: Mutex::new(()),
            }),
        })
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

    fn project_config(&self) -> RuntimeProjectConfig {
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
        self.request_sync();
        Ok(self.project_config_view())
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
        let response = execute_authenticated_server_request(
            self,
            method,
            &request.path,
            &headers,
            request.body.map(String::into_bytes),
        )
        .await?;
        let status = response.status().as_u16();
        let headers = filter_proxy_response_headers(response.headers());
        let body = response.text().await?;
        Ok(DaemonServerResponse {
            status,
            headers,
            body,
        })
    }

    fn project_config_view(&self) -> DaemonProjectConfig {
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

    pub async fn memory_cache(
        &self,
        request: DaemonMemoryCacheRequest,
    ) -> Result<DaemonMemoryCacheStatus, DaemonError> {
        commit_sync::memory_cache(self, request).await
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
                 WHERE sync_status = 'failed'",
            )
            .execute(&self.inner.pool)
            .await?;
        }
        self.run_sync_channels(retry_drafts, retry_commits).await?;

        Ok(DaemonRetryResponse {
            retry_id,
            started: true,
        })
    }

    pub async fn store_draft_operation(
        &self,
        request: DaemonDraftOperationRequest,
    ) -> Result<DaemonDraftOperationResponse, DaemonError> {
        request.op.validate_exactly_one()?;
        let source = request
            .source
            .unwrap_or(DaemonDraftOperationSource::Desktop);
        let operation_json = serde_json::to_string(&request.op)?;
        let base_commit_id = match request.base_commit_id {
            Some(commit_id) => Some(commit_id),
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
            request.draft_id.as_deref(),
            &request.project_id,
            base_commit_id.as_deref(),
            request.scope,
            request.resource,
            &request.op,
        )
        .await?;
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
        self.run_sync_channels(true, true).await
    }

    async fn run_sync_channels(
        &self,
        sync_drafts: bool,
        sync_commits: bool,
    ) -> Result<(), DaemonError> {
        if self.inner.sync_running.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let result = async {
            if !self.project_config().readiness().ready {
                return Ok(());
            }
            let mut first_error = None;
            if sync_drafts {
                let draft_result = async {
                    upsert_meta_timestamp(&self.inner.pool, META_DRAFT_SYNC_LAST_ATTEMPT_AT)
                        .await?;
                    self.drain_draft_queue().await?;
                    self.pull_draft_events().await?;
                    upsert_meta_timestamp(&self.inner.pool, META_DRAFT_SYNC_LAST_SUCCESS_AT).await
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
        .await;
        self.inner.sync_running.store(false, Ordering::Release);
        result
    }
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

    pub async fn sync_status(&self) -> Result<DaemonSyncStatus, DaemonError> {
        self.state.sync_status().await
    }

    pub async fn memory_cache(
        &self,
        request: DaemonMemoryCacheRequest,
    ) -> Result<DaemonMemoryCacheStatus, DaemonError> {
        self.state.memory_cache(request).await
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
            "health" => serde_json::to_value(self.health().await).map_err(DaemonError::from),
            "project_config" => {
                serde_json::to_value(self.project_config()).map_err(DaemonError::from)
            }
            "replace_project_config" => {
                let payload = self
                    .decode_dispatch_payload::<DaemonProjectConfigUpdateRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .replace_project_config(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "sync_status" => self
                .sync_status()
                .await
                .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
            "memory_cache" => {
                let payload =
                    self.decode_dispatch_payload::<DaemonMemoryCacheRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .memory_cache(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "retry_sync" => {
                let payload =
                    self.decode_dispatch_payload::<DaemonSyncRetryRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .retry_sync(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "mcp_status" => serde_json::to_value(self.mcp_status()).map_err(DaemonError::from),
            "list_drafts" => {
                let payload = self.decode_dispatch_payload::<DaemonDraftListQuery>(request.payload);
                match payload {
                    Ok(payload) => self
                        .list_drafts(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
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
                let payload =
                    self.decode_dispatch_payload::<DaemonDraftOperationRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .store_draft_operation(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "server_request" => {
                let payload = self.decode_dispatch_payload::<DaemonServerRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .server_request(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
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

async fn resolve_local_draft(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    requested_draft_id: Option<&str>,
    project_id: &str,
    base_commit_id: Option<&str>,
    scope: DaemonDraftScope,
    resource: DaemonDraftResourceKind,
    op: &DaemonDraftOperation,
) -> Result<String, DaemonError> {
    if let Some(draft_id) = requested_draft_id {
        let row = sqlx::query(
            "SELECT project_id, resource_scope, resource_kind, base_commit_id, status
             FROM local_drafts
             WHERE draft_id = $1",
        )
        .bind(draft_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(|| DaemonError::NotFound(format!("local draft not found: {draft_id}")))?;
        let stored_kind: String = row.try_get("resource_kind")?;
        let stored_project_id: String = row.try_get("project_id")?;
        let stored_scope: String = row.try_get("resource_scope")?;
        if stored_project_id != project_id
            || stored_scope != scope.as_str()
            || stored_kind != resource.as_str()
        {
            return Err(DaemonError::InvalidRequest(format!(
                "local draft {draft_id} belongs to a different project, scope, or resource kind"
            )));
        }
        let stored_base_commit_id: Option<String> = row.try_get("base_commit_id")?;
        if base_commit_id.is_some() && stored_base_commit_id.as_deref() != base_commit_id {
            return Err(DaemonError::InvalidRequest(format!(
                "local draft {draft_id} has a different base commit"
            )));
        }
        let status: String = row.try_get("status")?;
        if status != "open" {
            return Err(DaemonError::InvalidRequest(format!(
                "local draft {draft_id} is {status}"
            )));
        }
        if op.discard.is_some() {
            mark_local_draft_discarded(tx, draft_id).await?;
        }
        if let Some(create) = &op.create {
            sqlx::query("UPDATE local_drafts SET path = $2 WHERE draft_id = $1")
                .bind(draft_id)
                .bind(&create.path)
                .execute(&mut **tx)
                .await?;
        }
        return Ok(draft_id.to_owned());
    }

    if let Some(create) = &op.create {
        let draft_id = format!("draft_{}", Uuid::new_v4().simple());
        sqlx::query(
            "INSERT INTO local_drafts (
                draft_id, project_id, base_commit_id, resource_scope, resource_kind, target_id, path, status
             )
             VALUES ($1, $2, $3, $4, $5, NULL, $6, 'open')",
        )
        .bind(&draft_id)
        .bind(project_id)
        .bind(base_commit_id)
        .bind(scope.as_str())
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
        "SELECT draft_id, project_id, resource_scope, resource_kind, base_commit_id
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
        let stored_project_id: String = existing.try_get("project_id")?;
        let stored_scope: String = existing.try_get("resource_scope")?;
        let stored_kind: String = existing.try_get("resource_kind")?;
        if stored_project_id != project_id
            || stored_scope != scope.as_str()
            || stored_kind != resource.as_str()
        {
            return Err(DaemonError::InvalidRequest(format!(
                "local draft {draft_id} belongs to a different project, scope, or resource kind"
            )));
        }
        let stored_base_commit_id: Option<String> = existing.try_get("base_commit_id")?;
        if base_commit_id.is_some() && stored_base_commit_id.as_deref() != base_commit_id {
            return Err(DaemonError::InvalidRequest(format!(
                "local draft {draft_id} has a different base commit"
            )));
        }
        if op.discard.is_some() {
            mark_local_draft_discarded(tx, &draft_id).await?;
        }
        return Ok(draft_id);
    }

    let draft_id = format!("draft_{}", Uuid::new_v4().simple());
    sqlx::query(
        "INSERT INTO local_drafts (
            draft_id, project_id, base_commit_id, resource_scope, resource_kind, target_id, path, status
         )
         VALUES ($1, $2, $3, $4, $5, $6, NULL, $7)",
    )
    .bind(&draft_id)
    .bind(project_id)
    .bind(base_commit_id)
    .bind(scope.as_str())
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
            d.draft_id, d.project_id, d.server_draft_id, d.server_version, d.base_commit_id,
            d.resource_scope, d.resource_kind, d.target_id,
            d.path, d.conflict_base_commit_id, d.conflict_current_commit_id, d.conflicted_at,
            d.status, d.created_at, d.updated_at,
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
            d.draft_id, d.project_id, d.server_draft_id, d.server_version, d.base_commit_id,
            d.resource_scope, d.resource_kind, d.target_id,
            d.path, d.conflict_base_commit_id, d.conflict_current_commit_id, d.conflicted_at,
            d.status, d.created_at, d.updated_at,
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
    let conflicted_at: Option<String> = row.try_get("conflicted_at")?;
    let conflict = match conflicted_at {
        Some(detected_at) => Some(DaemonDraftConflict {
            base_commit_id: row.try_get("conflict_base_commit_id")?,
            current_commit_id: row.try_get("conflict_current_commit_id")?,
            detected_at,
        }),
        None => None,
    };
    Ok(DaemonDraftSummary {
        draft_id: row.try_get("draft_id")?,
        project_id: row.try_get("project_id")?,
        server_draft_id: row.try_get("server_draft_id")?,
        server_version: row.try_get("server_version")?,
        base_commit_id: row.try_get("base_commit_id")?,
        scope: daemon_draft_scope_from_str(row.try_get::<String, _>("resource_scope")?.as_str())?,
        resource_kind: draft_resource_kind_from_str(
            row.try_get::<String, _>("resource_kind")?.as_str(),
        )?,
        target_id: row.try_get("target_id")?,
        path: row.try_get("path")?,
        conflict,
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
    let conflict_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM local_drafts WHERE status = 'conflicted'")
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
    } else if conflict_count > 0 {
        SyncState::Conflicted
    } else {
        SyncState::Idle
    };
    let commit_sync = commit_sync::status(state).await?;
    let overall_last_success_at = match (&last_success_at, &commit_sync.last_success_at) {
        (Some(draft), Some(commit)) => Some(std::cmp::max(draft, commit).clone()),
        (Some(draft), None) => Some(draft.clone()),
        (None, Some(commit)) => Some(commit.clone()),
        (None, None) => None,
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
        commit_sync,
        pending_operation_count,
        failed_operation_count,
        conflict_count,
        last_success_at: overall_last_success_at,
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
    if draft_operation.discard.is_some() {
        if let Some(server_draft_id) = operation.server_draft_id.as_deref() {
            delete_server_json(
                state,
                &format!("/api/v1/drafts/{server_draft_id}"),
                operation.server_version,
            )
            .await
            .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
        }
        mark_operation_synced(&state.inner.pool, &local_operation_id)
            .await
            .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
        return Ok(());
    }
    let Some(server_operation) =
        map_daemon_operation_to_server(operation.scope, operation.resource_kind, &draft_operation)
            .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?
    else {
        mark_operation_synced(&state.inner.pool, &local_operation_id)
            .await
            .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
        return Ok(());
    };

    if let Some(server_draft_id) = operation.server_draft_id {
        let request = ServerDraftOperationBatchRequest {
            daemon_installation_id: state.inner.daemon_installation_id.clone(),
            operations: vec![ServerDraftOperationBatchItem {
                local_operation_id: local_operation_id.clone(),
                draft_id: server_draft_id,
                expected_draft_version: operation.server_version,
                operation: server_operation,
            }],
        };
        let response: ServerDraftOperationBatchResponse =
            post_server_json(state, "/api/v1/draft-operation-batches", &request)
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
                "Server did not accept local operation",
            ));
        }
        mark_batch_operation_synced(
            &state.inner.pool,
            &operation.draft_id,
            &local_operation_id,
            operation.server_version + 1,
        )
        .await
        .map_err(|error| DraftSyncError::new(local_operation_id.clone(), error.to_string()))?;
        return Ok(());
    }

    let request = ServerCreateDraftRequest {
        daemon_installation_id: state.inner.daemon_installation_id.clone(),
        project_id: operation.project_id.clone(),
        base_commit_id: operation.base_commit_id.clone(),
        title: draft_title(&operation),
        description: None,
        resource: server_operation.resource.clone(),
        operations: vec![server_operation],
    };
    let response: ServerDraftMutationResponse = post_server_json(state, "/api/v1/drafts", &request)
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
            d.project_id, d.resource_scope, d.server_draft_id, d.server_version,
            d.base_commit_id, d.target_id, d.path
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
        project_id: row.try_get("project_id")?,
        scope: daemon_draft_scope_from_str(row.try_get::<String, _>("resource_scope")?.as_str())?,
        resource_kind: draft_resource_kind_from_str(
            row.try_get::<String, _>("resource_kind")?.as_str(),
        )?,
        operation_json: row.try_get("operation_json")?,
        server_draft_id: row.try_get("server_draft_id")?,
        server_version: row.try_get("server_version")?,
        base_commit_id: row.try_get("base_commit_id")?,
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
    tx.commit().await?;
    Ok(())
}

async fn post_server_json<T, R>(
    state: &DaemonState,
    path: &str,
    request: &T,
) -> Result<R, DaemonError>
where
    T: Serialize + ?Sized,
    R: DeserializeOwned,
{
    let mut headers = BTreeMap::new();
    headers.insert("content-type".to_owned(), "application/json".to_owned());
    let response = execute_authenticated_server_request(
        state,
        reqwest::Method::POST,
        path,
        &headers,
        Some(serde_json::to_vec(request)?),
    )
    .await?;
    decode_server_json(response).await
}

async fn get_server_json<R>(state: &DaemonState, path: &str) -> Result<R, DaemonError>
where
    R: DeserializeOwned,
{
    let response = execute_authenticated_server_request(
        state,
        reqwest::Method::GET,
        path,
        &BTreeMap::new(),
        None,
    )
    .await?;
    decode_server_json(response).await
}

async fn delete_server_json(
    state: &DaemonState,
    path: &str,
    expected_version: i64,
) -> Result<(), DaemonError> {
    let mut headers = BTreeMap::new();
    headers.insert("if-match".to_owned(), expected_version.to_string());
    let response =
        execute_authenticated_server_request(state, reqwest::Method::DELETE, path, &headers, None)
            .await?;
    ensure_server_success(response).await?;
    Ok(())
}

async fn execute_authenticated_server_request(
    state: &DaemonState,
    method: reqwest::Method,
    path: &str,
    headers: &BTreeMap<String, String>,
    body: Option<Vec<u8>>,
) -> Result<reqwest::Response, DaemonError> {
    validate_server_proxy_path(path)?;
    let config = state.project_config();
    let access_token = config.access_token.clone().ok_or_else(|| {
        DaemonError::InvalidConfig("access_token is required for Server requests".to_owned())
    })?;
    let response = send_server_request(
        state,
        &config.server_url,
        &access_token,
        method.clone(),
        path,
        headers,
        body.clone(),
    )
    .await?;
    if response.status() != reqwest::StatusCode::UNAUTHORIZED || config.refresh_token.is_none() {
        return Ok(response);
    }

    refresh_server_tokens(state, &access_token).await?;
    let refreshed = state.project_config();
    let refreshed_access_token = refreshed.access_token.ok_or_else(|| {
        DaemonError::InvalidConfig("Server session is no longer authenticated".to_owned())
    })?;
    send_server_request(
        state,
        &refreshed.server_url,
        &refreshed_access_token,
        method,
        path,
        headers,
        body,
    )
    .await
}

async fn send_server_request(
    state: &DaemonState,
    server_url: &str,
    access_token: &str,
    method: reqwest::Method,
    path: &str,
    headers: &BTreeMap<String, String>,
    body: Option<Vec<u8>>,
) -> Result<reqwest::Response, DaemonError> {
    let url = format!(
        "{}/{}",
        server_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let mut builder = state
        .inner
        .http
        .request(method, url)
        .bearer_auth(access_token);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    if let Some(body) = body {
        builder = builder.body(body);
    }
    Ok(builder.send().await?)
}

async fn refresh_server_tokens(
    state: &DaemonState,
    stale_access_token: &str,
) -> Result<(), DaemonError> {
    let _refresh_guard = state.inner.token_refresh.lock().await;
    let config = state.project_config();
    if config.access_token.as_deref() != Some(stale_access_token) {
        return Ok(());
    }
    let refresh_token = config.refresh_token.clone().ok_or_else(|| {
        DaemonError::InvalidConfig("refresh_token is required to refresh the session".to_owned())
    })?;
    let url = format!(
        "{}/api/v1/auth/token",
        config.server_url.trim_end_matches('/')
    );
    let response = state
        .inner
        .http
        .post(url)
        .json(&json!({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token
        }))
        .send()
        .await?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        if status == reqwest::StatusCode::BAD_REQUEST
            || status == reqwest::StatusCode::UNAUTHORIZED
            || status == reqwest::StatusCode::FORBIDDEN
        {
            clear_server_tokens(state).await?;
        }
        return Err(DaemonError::Server(format!(
            "Server token refresh failed with status {status}: {body}"
        )));
    }
    let tokens: ServerTokenRefreshResponse = response.json().await?;
    let mut refreshed = config;
    refreshed.access_token = Some(tokens.access_token);
    refreshed.refresh_token = Some(tokens.refresh_token);
    replace_server_credentials(
        state.inner.credential_store.clone(),
        refreshed.credentials(),
    )
    .await?;
    *state
        .inner
        .project_config
        .write()
        .expect("project config rwlock poisoned") = refreshed;
    Ok(())
}

async fn clear_server_tokens(state: &DaemonState) -> Result<(), DaemonError> {
    let mut config = state.project_config();
    replace_server_credentials(state.inner.credential_store.clone(), None).await?;
    config.access_token = None;
    config.refresh_token = None;
    *state
        .inner
        .project_config
        .write()
        .expect("project config rwlock poisoned") = config;
    Ok(())
}

async fn decode_server_json<R>(response: reqwest::Response) -> Result<R, DaemonError>
where
    R: DeserializeOwned,
{
    let response = ensure_server_success(response).await?;
    Ok(response.json::<R>().await?)
}

async fn ensure_server_success(
    response: reqwest::Response,
) -> Result<reqwest::Response, DaemonError> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let body = response.text().await.unwrap_or_default();
    Err(DaemonError::Server(format!(
        "Server request failed with status {status}: {body}"
    )))
}

fn validate_server_proxy_path(path: &str) -> Result<(), DaemonError> {
    if !path.starts_with("/api/v1/")
        || path.contains("\r")
        || path.contains("\n")
        || path.contains("#")
        || path.split('?').next().is_some_and(|path| {
            path.split('/')
                .any(|segment| segment == "." || segment == "..")
        })
    {
        return Err(DaemonError::InvalidRequest(
            "Server proxy path must be a normalized /api/v1 resource".to_owned(),
        ));
    }
    Ok(())
}

fn filter_proxy_request_headers(headers: BTreeMap<String, String>) -> BTreeMap<String, String> {
    const ALLOWED: &[&str] = &[
        "accept",
        "content-type",
        "if-match",
        "if-none-match",
        "x-clumsies-request-id",
    ];
    headers
        .into_iter()
        .filter_map(|(name, value)| {
            let name = name.to_ascii_lowercase();
            ALLOWED.contains(&name.as_str()).then_some((name, value))
        })
        .collect()
}

fn filter_proxy_response_headers(headers: &reqwest::header::HeaderMap) -> BTreeMap<String, String> {
    const ALLOWED: &[&str] = &["content-type", "etag", "x-request-id"];
    headers
        .iter()
        .filter_map(|(name, value)| {
            let name = name.as_str();
            if !ALLOWED.contains(&name) {
                return None;
            }
            value
                .to_str()
                .ok()
                .map(|value| (name.to_owned(), value.to_owned()))
        })
        .collect()
}

fn map_daemon_operation_to_server(
    scope: DaemonDraftScope,
    resource: DaemonDraftResourceKind,
    operation: &DaemonDraftOperation,
) -> Result<Option<ServerDraftOperationInput>, DaemonError> {
    if let Some(create) = &operation.create {
        return Ok(Some(ServerDraftOperationInput {
            action: ServerDraftOperationAction::Create,
            resource: ServerDraftResourceRef {
                scope,
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
        return Ok(Some(ServerDraftOperationInput {
            action: ServerDraftOperationAction::Update,
            resource: ServerDraftResourceRef {
                scope,
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
        return Ok(Some(ServerDraftOperationInput {
            action: ServerDraftOperationAction::Rename,
            resource: ServerDraftResourceRef {
                scope,
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
        return Ok(Some(ServerDraftOperationInput {
            action: ServerDraftOperationAction::Delete,
            resource: ServerDraftResourceRef {
                scope,
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

fn daemon_draft_scope_from_str(value: &str) -> Result<DaemonDraftScope, DaemonError> {
    match value {
        "org" => Ok(DaemonDraftScope::Org),
        "project" => Ok(DaemonDraftScope::Project),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown draft scope: {other}"
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

fn draft_operation_source_from_str(
    value: &str,
) -> Result<DaemonDraftOperationRecordSource, DaemonError> {
    match value {
        "desktop" => Ok(DaemonDraftOperationRecordSource::Desktop),
        "cli" => Ok(DaemonDraftOperationRecordSource::Cli),
        "mcp_store" => Ok(DaemonDraftOperationRecordSource::McpStore),
        "server" => Ok(DaemonDraftOperationRecordSource::Server),
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
    let mut cursor = load_meta_value(&state.inner.pool, META_DRAFT_EVENTS_CURSOR).await?;

    loop {
        let path = cursor
            .as_deref()
            .map(|cursor| format!("/api/v1/draft-events?after_cursor={cursor}"))
            .unwrap_or_else(|| "/api/v1/draft-events".to_owned());
        let response: ServerDraftEventListResponse = get_server_json(state, &path).await?;
        if response.events.is_empty() {
            if response.has_more {
                return Err(DaemonError::Server(
                    "Server returned an empty draft event page with has_more=true".to_owned(),
                ));
            }
            return Ok(());
        }

        let next_cursor = response.next_cursor.as_deref().ok_or_else(|| {
            DaemonError::Server("Server returned draft events without a next cursor".to_owned())
        })?;
        if cursor.as_deref() == Some(next_cursor) {
            return Err(DaemonError::Server(
                "Server draft event cursor did not advance".to_owned(),
            ));
        }

        let remote_events = response
            .events
            .iter()
            .filter(|event| {
                event.daemon_installation_id.as_deref()
                    != Some(state.inner.daemon_installation_id.as_str())
            })
            .collect::<Vec<_>>();
        let mut drafts = BTreeMap::new();
        for event in &remote_events {
            if drafts.contains_key(&event.draft_id) {
                continue;
            }
            let detail: ServerDraftProjectionDetail =
                get_server_json(state, &format!("/api/v1/drafts/{}", event.draft_id)).await?;
            if detail.draft.draft_id != event.draft_id
                || detail.draft.project_id != event.project_id
                || detail.draft.version < event.version
            {
                return Err(DaemonError::Server(format!(
                    "Server returned an inconsistent projection for draft {}",
                    event.draft_id
                )));
            }
            drafts.insert(event.draft_id.clone(), detail);
        }

        let mut tx = state.inner.pool.begin().await?;
        for detail in drafts.values() {
            project_server_draft(&mut tx, detail).await?;
        }
        for event in remote_events {
            sqlx::query(
                "INSERT INTO remote_draft_events (
                    event_id, draft_id, project_id, event_type, version, daemon_installation_id, created_at
                 )
                 VALUES ($1, $2, $3, $4, $5, $6, $7)
                 ON CONFLICT(event_id) DO NOTHING",
            )
            .bind(&event.event_id)
            .bind(&event.draft_id)
            .bind(&event.project_id)
            .bind(&event.event_type)
            .bind(event.version)
            .bind(&event.daemon_installation_id)
            .bind(&event.created_at)
            .execute(&mut *tx)
            .await?;
        }
        sqlx::query(
            "INSERT INTO daemon_meta (key, value)
             VALUES ($1, $2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .bind(META_DRAFT_EVENTS_CURSOR)
        .bind(next_cursor)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        cursor = response.next_cursor;
        if !response.has_more {
            return Ok(());
        }
    }
}

async fn project_server_draft(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    detail: &ServerDraftProjectionDetail,
) -> Result<(), DaemonError> {
    let existing = sqlx::query(
        "SELECT draft_id, server_version
         FROM local_drafts
         WHERE server_draft_id = $1",
    )
    .bind(&detail.draft.draft_id)
    .fetch_optional(&mut **tx)
    .await?;
    let local_draft_id = if let Some(row) = existing {
        let local_draft_id: String = row.try_get("draft_id")?;
        let server_version: i64 = row.try_get("server_version")?;
        if detail.draft.version < server_version {
            return Err(DaemonError::Server(format!(
                "Server draft {} regressed from version {server_version} to {}",
                detail.draft.draft_id, detail.draft.version
            )));
        }
        sqlx::query(
            "UPDATE local_drafts
             SET project_id = $2, server_version = $3, base_commit_id = $4,
                 resource_scope = $5, resource_kind = $6, target_id = $7, path = $8,
                 conflict_base_commit_id = $9, conflict_current_commit_id = $10,
                 conflicted_at = $11, status = $12, updated_at = $13
             WHERE draft_id = $1",
        )
        .bind(&local_draft_id)
        .bind(&detail.draft.project_id)
        .bind(detail.draft.version)
        .bind(&detail.draft.base_commit_id)
        .bind(detail.draft.resource.scope.as_str())
        .bind(detail.draft.resource.kind.as_str())
        .bind(&detail.draft.resource.id)
        .bind(&detail.draft.resource.path)
        .bind(
            detail
                .conflict
                .as_ref()
                .and_then(|conflict| conflict.base_commit_id.as_deref()),
        )
        .bind(
            detail
                .conflict
                .as_ref()
                .and_then(|conflict| conflict.current_commit_id.as_deref()),
        )
        .bind(
            detail
                .conflict
                .as_ref()
                .map(|conflict| conflict.detected_at.as_str()),
        )
        .bind(detail.draft.status.as_str())
        .bind(&detail.draft.updated_at)
        .execute(&mut **tx)
        .await?;
        local_draft_id
    } else {
        sqlx::query(
            "INSERT INTO local_drafts (
                draft_id, project_id, server_draft_id, server_version, base_commit_id,
                resource_scope, resource_kind, target_id, path,
                conflict_base_commit_id, conflict_current_commit_id, conflicted_at,
                status, created_at, updated_at
             )
             VALUES ($1, $2, $1, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)",
        )
        .bind(&detail.draft.draft_id)
        .bind(&detail.draft.project_id)
        .bind(detail.draft.version)
        .bind(&detail.draft.base_commit_id)
        .bind(detail.draft.resource.scope.as_str())
        .bind(detail.draft.resource.kind.as_str())
        .bind(&detail.draft.resource.id)
        .bind(&detail.draft.resource.path)
        .bind(
            detail
                .conflict
                .as_ref()
                .and_then(|conflict| conflict.base_commit_id.as_deref()),
        )
        .bind(
            detail
                .conflict
                .as_ref()
                .and_then(|conflict| conflict.current_commit_id.as_deref()),
        )
        .bind(
            detail
                .conflict
                .as_ref()
                .map(|conflict| conflict.detected_at.as_str()),
        )
        .bind(detail.draft.status.as_str())
        .bind(&detail.draft.created_at)
        .bind(&detail.draft.updated_at)
        .execute(&mut **tx)
        .await?;
        detail.draft.draft_id.clone()
    };

    let linked_rows = sqlx::query(
        "SELECT local_operation_id, server_operation_id
         FROM local_draft_operations
         WHERE draft_id = $1 AND server_operation_id IS NOT NULL",
    )
    .bind(&local_draft_id)
    .fetch_all(&mut **tx)
    .await?;
    for row in linked_rows {
        let server_operation_id: String = row.try_get("server_operation_id")?;
        if detail
            .operations
            .iter()
            .any(|operation| operation.operation_id == server_operation_id)
        {
            continue;
        }
        sqlx::query("DELETE FROM local_draft_operations WHERE local_operation_id = $1")
            .bind(row.try_get::<String, _>("local_operation_id")?)
            .execute(&mut **tx)
            .await?;
    }

    let rows = sqlx::query(
        "SELECT local_operation_id, operation_json
         FROM local_draft_operations
         WHERE draft_id = $1
           AND server_operation_id IS NULL
           AND source != 'server'
           AND sync_status = 'synced'
         ORDER BY rowid",
    )
    .bind(&local_draft_id)
    .fetch_all(&mut **tx)
    .await?;
    let mut unlinked_operations = rows
        .iter()
        .map(|row| {
            Ok(UnlinkedLocalOperation {
                local_operation_id: row.try_get("local_operation_id")?,
                operation: serde_json::from_str(&row.try_get::<String, _>("operation_json")?)?,
                linked: false,
            })
        })
        .collect::<Result<Vec<_>, DaemonError>>()?;

    for server_operation in &detail.operations {
        if server_operation.resource.scope != detail.draft.resource.scope
            || server_operation.resource.kind != detail.draft.resource.kind
        {
            return Err(DaemonError::Server(format!(
                "Server operation {} does not match draft {} resource",
                server_operation.operation_id, detail.draft.draft_id
            )));
        }
        let operation = map_server_operation_to_daemon(server_operation)?;
        let already_linked: Option<String> = sqlx::query_scalar(
            "SELECT local_operation_id
             FROM local_draft_operations
             WHERE server_operation_id = $1",
        )
        .bind(&server_operation.operation_id)
        .fetch_optional(&mut **tx)
        .await?;
        if already_linked.is_some() {
            continue;
        }

        if let Some(local_operation) = unlinked_operations.iter_mut().find(|candidate| {
            !candidate.linked && draft_operations_match(&candidate.operation, &operation)
        }) {
            sqlx::query(
                "UPDATE local_draft_operations
                 SET server_operation_id = $2
                 WHERE local_operation_id = $1",
            )
            .bind(&local_operation.local_operation_id)
            .bind(&server_operation.operation_id)
            .execute(&mut **tx)
            .await?;
            local_operation.linked = true;
            continue;
        }

        sqlx::query(
            "INSERT INTO local_draft_operations (
                local_operation_id, draft_id, server_operation_id, resource_kind,
                operation_json, source, sync_status, created_at, updated_at
             )
             VALUES ($1, $2, $3, $4, $5, 'server', 'synced', $6, $6)",
        )
        .bind(format!("server_{}", server_operation.operation_id))
        .bind(&local_draft_id)
        .bind(&server_operation.operation_id)
        .bind(detail.draft.resource.kind.as_str())
        .bind(serde_json::to_string(&operation)?)
        .bind(&server_operation.created_at)
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

fn map_server_operation_to_daemon(
    operation: &ServerDraftProjectionOperation,
) -> Result<DaemonDraftOperation, DaemonError> {
    let missing = |field: &str| {
        DaemonError::Server(format!(
            "Server operation {} is missing {field}",
            operation.operation_id
        ))
    };
    let mut mapped = DaemonDraftOperation {
        create: None,
        update: None,
        rename: None,
        delete: None,
        discard: None,
    };
    match operation.action {
        ServerDraftOperationAction::Create => {
            mapped.create = Some(DaemonCreateDraftOperation {
                path: operation
                    .resource
                    .path
                    .clone()
                    .ok_or_else(|| missing("path"))?,
                body: operation.body.clone().unwrap_or_default(),
                description: None,
            });
        }
        ServerDraftOperationAction::Update => {
            mapped.update = Some(DaemonUpdateDraftOperation {
                id: operation.resource.id.clone().ok_or_else(|| missing("id"))?,
                body: operation.body.clone().unwrap_or_default(),
                description: None,
            });
        }
        ServerDraftOperationAction::Rename => {
            mapped.rename = Some(DaemonRenameDraftOperation {
                id: operation.resource.id.clone().ok_or_else(|| missing("id"))?,
                new_path: operation
                    .new_path
                    .clone()
                    .ok_or_else(|| missing("new_path"))?,
                description: None,
            });
        }
        ServerDraftOperationAction::Delete => {
            mapped.delete = Some(DaemonDeleteDraftOperation {
                id: operation.resource.id.clone().ok_or_else(|| missing("id"))?,
                description: None,
            });
        }
    }
    Ok(mapped)
}

fn draft_operations_match(left: &DaemonDraftOperation, right: &DaemonDraftOperation) -> bool {
    match (left, right) {
        (
            DaemonDraftOperation {
                create: Some(left), ..
            },
            DaemonDraftOperation {
                create: Some(right),
                ..
            },
        ) => left.path == right.path && left.body == right.body,
        (
            DaemonDraftOperation {
                update: Some(left), ..
            },
            DaemonDraftOperation {
                update: Some(right),
                ..
            },
        ) => left.id == right.id && left.body == right.body,
        (
            DaemonDraftOperation {
                rename: Some(left), ..
            },
            DaemonDraftOperation {
                rename: Some(right),
                ..
            },
        ) => left.id == right.id && left.new_path == right.new_path,
        (
            DaemonDraftOperation {
                delete: Some(left), ..
            },
            DaemonDraftOperation {
                delete: Some(right),
                ..
            },
        ) => left.id == right.id,
        _ => false,
    }
}

struct UnlinkedLocalOperation {
    local_operation_id: String,
    operation: DaemonDraftOperation,
    linked: bool,
}

fn prepare_directories(config: &DaemonConfig) -> Result<(), DaemonError> {
    std::fs::create_dir_all(&config.root_dir)?;
    std::fs::create_dir_all(&config.cache_dir)?;
    std::fs::create_dir_all(config.logs_dir())?;
    Ok(())
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
    let existing_schema_version = current_schema_version(pool).await?;
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
            resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow', 'metaprompt')),
            target_id TEXT,
            path TEXT,
            conflict_base_commit_id TEXT,
            conflict_current_commit_id TEXT,
            conflicted_at TEXT,
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
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow', 'metaprompt')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store', 'server')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
    )
    .execute(pool)
    .await?;
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

async fn save_project_metadata(
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

async fn load_server_credentials(
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

async fn replace_server_credentials(
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

fn home_dir() -> Result<PathBuf, DaemonError> {
    env::var_os("HOME").map(PathBuf::from).ok_or_else(|| {
        DaemonError::InvalidConfig(
            "HOME is required when daemon runtime paths are not configured".to_owned(),
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

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonIpcTransport {
    MacosXpcMachService,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonIpcEndpoint {
    pub transport: DaemonIpcTransport,
    pub service_name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonIpcRequest {
    pub method: String,
    pub payload: serde_json::Value,
}

impl DaemonIpcRequest {
    pub fn new(method: impl Into<String>, payload: serde_json::Value) -> Self {
        Self {
            method: method.into(),
            payload,
        }
    }

    pub fn empty(method: impl Into<String>) -> Self {
        Self::new(method, json!({}))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonIpcResponse {
    pub ok: bool,
    pub payload: serde_json::Value,
    pub error: Option<ApiError>,
}

impl DaemonIpcResponse {
    fn from_result(result: Result<serde_json::Value, DaemonError>) -> Self {
        match result {
            Ok(payload) => Self {
                ok: true,
                payload,
                error: None,
            },
            Err(error) => Self {
                ok: false,
                payload: json!({}),
                error: Some(api_error_from_daemon_error(error)),
            },
        }
    }

    pub fn into_payload<T>(self) -> Result<T, DaemonError>
    where
        T: DeserializeOwned,
    {
        if self.ok {
            serde_json::from_value(self.payload).map_err(DaemonError::from)
        } else {
            let message = self
                .error
                .map(|error| format!("{}: {}", error.code, error.message))
                .unwrap_or_else(|| "daemon IPC call failed without error details".to_owned());
            Err(DaemonError::Ipc(message))
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonBootstrapStatus {
    pub label: String,
    pub mach_service_name: String,
    pub plist_path: String,
    pub installed: bool,
    pub endpoint: DaemonIpcEndpoint,
    pub runtime: LaunchAgentRuntimeStatus,
}

impl DaemonBootstrapStatus {
    fn with_runtime(mut self, runtime: LaunchAgentRuntimeStatus) -> Self {
        self.runtime = runtime;
        self
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct LaunchAgentRuntimeStatus {
    pub installed: bool,
    pub bootstrapped: bool,
    pub running: bool,
    pub pid: Option<u32>,
    pub state: Option<String>,
    pub last_exit_code: Option<i32>,
    pub last_error: Option<String>,
}

impl LaunchAgentRuntimeStatus {
    pub fn from_launchctl_print(installed: bool, output: &str) -> Self {
        let mut status = Self {
            installed,
            bootstrapped: true,
            running: false,
            pid: None,
            state: None,
            last_exit_code: None,
            last_error: None,
        };
        for raw_line in output.lines() {
            let line = raw_line.trim();
            if let Some(value) = line.strip_prefix("pid =") {
                status.pid = value.trim().parse::<u32>().ok();
                continue;
            }
            if let Some(value) = line.strip_prefix("state =") {
                let value = value.trim();
                status.state = (!value.is_empty()).then(|| value.to_owned());
                continue;
            }
            if let Some(value) = line
                .strip_prefix("last exit code =")
                .or_else(|| line.strip_prefix("last exit status ="))
            {
                status.last_exit_code = value.trim().parse::<i32>().ok();
            }
        }
        status.running = status.pid.is_some()
            || status
                .state
                .as_deref()
                .is_some_and(|state| state == "running");
        status
    }

    fn not_bootstrapped(installed: bool, last_error: Option<String>) -> Self {
        Self {
            installed,
            bootstrapped: false,
            running: false,
            pid: None,
            state: None,
            last_exit_code: None,
            last_error,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectConfig {
    pub server_url: String,
    pub project_id: Option<String>,
    pub has_access_token: bool,
    pub has_refresh_token: bool,
    pub ready: bool,
    pub missing_fields: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectConfigUpdateRequest {
    pub server_url: String,
    pub project_id: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonServerRequest {
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    pub body: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonServerResponse {
    pub status: u16,
    pub headers: BTreeMap<String, String>,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProjectConfigReadiness {
    ready: bool,
    missing_fields: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonHealth {
    pub daemon_version: String,
    pub server_url: String,
    pub project_id: Option<String>,
    pub daemon_installation_id: String,
    pub log_dir: String,
    pub local_db: LocalDbStatus,
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
    pub commit_sync: SyncChannelStatus,
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
    Conflicted,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonSyncRetryRequest {
    pub channel: SyncRetryChannel,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncRetryChannel {
    Drafts,
    Commits,
    All,
}

impl SyncRetryChannel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Drafts => "drafts",
            Self::Commits => "commits",
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

#[derive(Clone, Debug, Deserialize, Serialize, Default, PartialEq, Eq)]
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
    pub project_id: String,
    pub server_draft_id: Option<String>,
    pub server_version: i64,
    pub base_commit_id: Option<String>,
    pub scope: DaemonDraftScope,
    pub resource_kind: DaemonDraftResourceKind,
    pub target_id: Option<String>,
    pub path: Option<String>,
    pub conflict: Option<DaemonDraftConflict>,
    pub status: DaemonLocalDraftStatus,
    pub created_at: String,
    pub updated_at: String,
    pub pending_operation_count: i64,
    pub failed_operation_count: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftConflict {
    pub base_commit_id: Option<String>,
    pub current_commit_id: Option<String>,
    pub detected_at: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonLocalDraftOperation {
    pub local_operation_id: String,
    pub resource_kind: DaemonDraftResourceKind,
    pub operation: DaemonDraftOperation,
    pub source: DaemonDraftOperationRecordSource,
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

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftOperationRequest {
    #[serde(default)]
    pub draft_id: Option<String>,
    #[serde(default)]
    pub base_commit_id: Option<String>,
    pub project_id: String,
    pub scope: DaemonDraftScope,
    pub resource: DaemonDraftResourceKind,
    pub op: DaemonDraftOperation,
    pub source: Option<DaemonDraftOperationSource>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonDraftDetailRequest {
    pub draft_id: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonDraftScope {
    Org,
    Project,
}

impl DaemonDraftScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::Org => "org",
            Self::Project => "project",
        }
    }
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

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonDraftOperationRecordSource {
    Desktop,
    Cli,
    McpStore,
    Server,
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
    fn validate_exactly_one(&self) -> Result<(), DaemonError> {
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
            Err(DaemonError::InvalidRequest(
                "draft operation must contain exactly one operation variant".to_owned(),
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
    project_id: String,
    scope: DaemonDraftScope,
    resource_kind: DaemonDraftResourceKind,
    operation_json: String,
    server_draft_id: Option<String>,
    server_version: i64,
    base_commit_id: Option<String>,
    target_id: Option<String>,
    path: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct ServerCreateDraftRequest {
    daemon_installation_id: String,
    project_id: String,
    base_commit_id: Option<String>,
    title: String,
    description: Option<String>,
    resource: ServerDraftResourceRef,
    operations: Vec<ServerDraftOperationInput>,
}

#[derive(Clone, Debug, Serialize)]
struct ServerDraftOperationBatchRequest {
    daemon_installation_id: String,
    operations: Vec<ServerDraftOperationBatchItem>,
}

#[derive(Clone, Debug, Serialize)]
struct ServerDraftOperationBatchItem {
    local_operation_id: String,
    draft_id: String,
    expected_draft_version: i64,
    operation: ServerDraftOperationInput,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftOperationBatchResponse {
    accepted_operations: Vec<String>,
    #[serde(rename = "cursor")]
    _cursor: String,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftEventListResponse {
    events: Vec<ServerDraftEvent>,
    next_cursor: Option<String>,
    has_more: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftEvent {
    event_id: String,
    draft_id: String,
    project_id: String,
    event_type: String,
    version: i64,
    daemon_installation_id: Option<String>,
    created_at: String,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerTokenRefreshResponse {
    access_token: String,
    refresh_token: String,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftMutationResponse {
    draft: ServerDraftVersion,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftVersion {
    draft_id: String,
    version: i64,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftProjectionDetail {
    draft: ServerDraftProjection,
    operations: Vec<ServerDraftProjectionOperation>,
    conflict: Option<ServerDraftConflict>,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftConflict {
    base_commit_id: Option<String>,
    current_commit_id: Option<String>,
    detected_at: String,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftProjection {
    draft_id: String,
    project_id: String,
    base_commit_id: Option<String>,
    resource: ServerDraftResourceRef,
    status: DaemonLocalDraftStatus,
    version: i64,
    created_at: String,
    updated_at: String,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftProjectionOperation {
    operation_id: String,
    action: ServerDraftOperationAction,
    resource: ServerDraftResourceRef,
    body: Option<String>,
    new_path: Option<String>,
    created_at: String,
}

#[derive(Clone, Debug, Serialize)]
struct ServerDraftOperationInput {
    action: ServerDraftOperationAction,
    resource: ServerDraftResourceRef,
    base_hash: Option<String>,
    body: Option<String>,
    new_path: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum ServerDraftOperationAction {
    Create,
    Update,
    Rename,
    Delete,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ServerDraftResourceRef {
    scope: DaemonDraftScope,
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

fn api_error_from_daemon_error(error: DaemonError) -> ApiError {
    let (code, message) = match error {
        DaemonError::InvalidConfig(message) => ("invalid_config", message),
        DaemonError::InvalidRequest(message) => ("invalid_request", message),
        DaemonError::NotFound(message) => ("not_found", message),
        DaemonError::Io(error) => ("io_error", error.to_string()),
        DaemonError::Sqlx(error) => ("local_db_error", error.to_string()),
        DaemonError::SerdeJson(error) => ("invalid_json", error.to_string()),
        DaemonError::Reqwest(error) => ("server_request_failed", error.to_string()),
        DaemonError::CredentialStore(error) => ("credential_store_failed", error.to_string()),
        DaemonError::Server(message) => ("server_sync_failed", message),
        DaemonError::Launchctl(message) => ("launchctl_failed", message),
        DaemonError::Ipc(message) => ("daemon_ipc_failed", message),
    };
    ApiError {
        code: code.to_owned(),
        message,
        request_id: format!("req_{}", Uuid::new_v4().simple()),
        details: json!({}),
    }
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
    #[error(transparent)]
    CredentialStore(#[from] CredentialStoreError),
    #[error("server sync error: {0}")]
    Server(String),
    #[error("launchctl error: {0}")]
    Launchctl(String),
    #[error("daemon IPC error: {0}")]
    Ipc(String),
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
