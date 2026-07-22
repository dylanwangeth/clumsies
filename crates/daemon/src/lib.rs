use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
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
mod search;
pub use commit_sync::{
    DaemonMemoryCacheRequest, DaemonMemoryCacheState, DaemonMemoryCacheStatus,
    DaemonProjectCheckout, DaemonProjectCheckoutRequest, DaemonProjectCheckoutResource,
};
pub use credentials::{
    CredentialStore, CredentialStoreError, KEYCHAIN_ACCOUNT, ServerCredentials,
    SystemCredentialStore,
};
pub use ipc::{DaemonIpcClient, DaemonIpcServer};
pub use search::{
    ActivateMemoryRequest, ActivateMemoryResponse, ActivationAction, ActivationFragment,
    ActivationRemoval, LoadMemoryRequest, LoadMemoryResponse, LoadedMemoryResource, MemoryKind,
    SearchIndexProjectRequest, SearchIndexStatus, SearchModelStatus, SourceLocator, SourceScope,
};

pub const IDENTIFIER_NAMESPACE: &str = "ai.clumsies";
pub const DAEMON_AGENT_LABEL: &str = "ai.clumsies.daemon";
pub const DAEMON_MACH_SERVICE_NAME: &str = DAEMON_AGENT_LABEL;
pub const CURRENT_LOCAL_SCHEMA_VERSION: i64 = 16;
const META_DRAFT_EVENTS_CURSOR: &str = "draft_events_cursor";
const META_MEMORY_CACHE_RESET_REQUIRED: &str = "memory_cache_reset_required";
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
                .join(IDENTIFIER_NAMESPACE),
            cache_dir: home
                .join("Library")
                .join("Caches")
                .join(IDENTIFIER_NAMESPACE),
            log_dir: home.join("Library").join("Logs").join(IDENTIFIER_NAMESPACE),
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
    binary_sha256: String,
}

impl LaunchAgentConfig {
    pub fn from_daemon_config(
        config: &DaemonConfig,
        program_path: impl Into<PathBuf>,
    ) -> Result<Self, DaemonError> {
        let program_path = program_path.into();
        let binary_sha256 = hex::encode(Sha256::digest(std::fs::read(&program_path)?));
        Ok(Self {
            label: DAEMON_AGENT_LABEL.to_owned(),
            mach_service_name: DAEMON_MACH_SERVICE_NAME.to_owned(),
            program_path,
            plist_path: config.launch_agent_plist_path(),
            root_dir: config.root_dir.clone(),
            cache_dir: config.cache_dir.clone(),
            log_dir: config.log_dir.clone(),
            binary_sha256,
        })
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
    <key>CLUMSIES_DAEMON_BINARY_SHA256</key>
    <string>{binary_sha256}</string>
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
            binary_sha256 = escape_plist_value(&self.binary_sha256),
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

    fn plist_is_current(&self) -> Result<bool, DaemonError> {
        match std::fs::read_to_string(&self.plist_path) {
            Ok(contents) => Ok(contents == self.plist_contents()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
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

    pub fn reconcile(&self) -> Result<DaemonBootstrapStatus, DaemonError> {
        let status = self.status()?;
        let action = launch_agent_reconcile_action(
            status.runtime.bootstrapped,
            status.runtime.running,
            self.config.plist_is_current()?,
        );
        match action {
            LaunchAgentReconcileAction::Ready => return Ok(status),
            LaunchAgentReconcileAction::Bootstrap => {
                self.config.install_plist()?;
                run_launchctl_success(&self.bootstrap_args())?;
            }
            LaunchAgentReconcileAction::Reload => {
                run_launchctl_success(&self.bootout_args())?;
                self.config.install_plist()?;
                self.bootstrap_after_bootout()?;
            }
            LaunchAgentReconcileAction::Kickstart => {
                run_launchctl_success(&self.kickstart_args())?;
            }
        }
        self.status()
    }

    fn bootstrap_after_bootout(&self) -> Result<(), DaemonError> {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match run_launchctl_success(&self.bootstrap_args()) {
                Ok(()) => return Ok(()),
                Err(DaemonError::Launchctl(_)) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(error) => return Err(error),
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LaunchAgentReconcileAction {
    Ready,
    Bootstrap,
    Reload,
    Kickstart,
}

fn launch_agent_reconcile_action(
    bootstrapped: bool,
    running: bool,
    plist_current: bool,
) -> LaunchAgentReconcileAction {
    if !bootstrapped {
        LaunchAgentReconcileAction::Bootstrap
    } else if !plist_current {
        LaunchAgentReconcileAction::Reload
    } else if !running {
        LaunchAgentReconcileAction::Kickstart
    } else {
        LaunchAgentReconcileAction::Ready
    }
}

#[cfg(test)]
mod launch_agent_tests {
    use super::*;

    #[test]
    fn plist_currency_tracks_the_installed_launch_agent_definition() {
        let root = tempfile::tempdir().unwrap();
        let daemon_config = DaemonConfig::for_root(root.path());
        let program_path = root.path().join("bin/clumsiesd");
        std::fs::create_dir_all(program_path.parent().unwrap()).unwrap();
        std::fs::write(&program_path, "daemon-v1").unwrap();
        let launch_agent =
            LaunchAgentConfig::from_daemon_config(&daemon_config, &program_path).unwrap();

        assert!(!launch_agent.plist_is_current().unwrap());

        launch_agent.install_plist().unwrap();
        assert!(launch_agent.plist_is_current().unwrap());

        std::fs::write(&program_path, "daemon-v2").unwrap();
        let updated = LaunchAgentConfig::from_daemon_config(&daemon_config, &program_path).unwrap();
        assert!(!updated.plist_is_current().unwrap());

        std::fs::write(&launch_agent.plist_path, "stale launch agent").unwrap();
        assert!(!launch_agent.plist_is_current().unwrap());
    }

    #[test]
    fn reconcile_bootstraps_an_unloaded_agent() {
        assert_eq!(
            launch_agent_reconcile_action(false, false, false),
            LaunchAgentReconcileAction::Bootstrap
        );
    }

    #[test]
    fn reconcile_reloads_a_stale_agent_definition() {
        assert_eq!(
            launch_agent_reconcile_action(true, true, false),
            LaunchAgentReconcileAction::Reload
        );
    }

    #[test]
    fn reconcile_kickstarts_a_loaded_stopped_agent() {
        assert_eq!(
            launch_agent_reconcile_action(true, false, true),
            LaunchAgentReconcileAction::Kickstart
        );
    }

    #[test]
    fn reconcile_keeps_a_current_running_agent() {
        assert_eq!(
            launch_agent_reconcile_action(true, true, true),
            LaunchAgentReconcileAction::Ready
        );
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

    fn server_readiness(&self) -> ProjectConfigReadiness {
        let mut missing_fields = Vec::new();
        if self.server_url.trim().is_empty() {
            missing_fields.push("server_url".to_owned());
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
    sync_lock: Mutex<()>,
    commit_sync_running: AtomicBool,
    token_refresh: Mutex<()>,
    search_models: Arc<dyn search::models::SearchModels>,
    search_lock: Mutex<()>,
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
                sync_lock: Mutex::new(()),
                commit_sync_running: AtomicBool::new(false),
                token_refresh: Mutex::new(()),
                search_models,
                search_lock: Mutex::new(()),
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

        let mut best: Option<(usize, DaemonProjectBinding)> = None;
        for row in rows {
            let binding = project_binding_from_row(&row)?;
            let root = Path::new(&binding.workspace_root);
            if !workspace_path.starts_with(root) {
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

        best.map(|(_, binding)| binding)
            .ok_or_else(|| DaemonError::State {
                code: "project_binding_not_found",
                message: format!(
                    "No Project is bound to workspace path {} on {server_url}",
                    workspace_path.display()
                ),
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
        let source = request
            .source
            .unwrap_or(DaemonDraftOperationSource::Desktop);
        let operation_json = serde_json::to_string(&request.op)?;
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
                op: &request.op,
            },
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
                        eprintln!("search model preparation failed: {}", error.message);
                    }
                    Err(error) => {
                        eprintln!("search model preparation worker failed: {error}");
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

    pub async fn replace_project_binding(
        &self,
        request: DaemonProjectBindingReplaceRequest,
    ) -> Result<DaemonProjectBinding, DaemonError> {
        self.state.replace_project_binding(request).await
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
            "select_project" => {
                let payload =
                    self.decode_dispatch_payload::<DaemonProjectSelectionRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .select_project(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "resolve_project_binding" => {
                let payload = self
                    .decode_dispatch_payload::<DaemonProjectBindingResolveRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .resolve_project_binding(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "replace_project_binding" => {
                let payload = self
                    .decode_dispatch_payload::<DaemonProjectBindingReplaceRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .replace_project_binding(payload)
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
            "project_checkout" => {
                let payload =
                    self.decode_dispatch_payload::<DaemonProjectCheckoutRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .project_checkout(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "activate_memory" => {
                let payload =
                    self.decode_dispatch_payload::<ActivateMemoryRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .activate_memory(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "load_memory" => {
                let payload = self.decode_dispatch_payload::<LoadMemoryRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .load_memory(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "search_index_status" => {
                let payload =
                    self.decode_dispatch_payload::<SearchIndexProjectRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .search_index_status(payload)
                        .await
                        .and_then(|value| serde_json::to_value(value).map_err(DaemonError::from)),
                    Err(error) => Err(error),
                }
            }
            "rebuild_search_index" => {
                let payload =
                    self.decode_dispatch_payload::<SearchIndexProjectRequest>(request.payload);
                match payload {
                    Ok(payload) => self
                        .rebuild_search_index(payload)
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

struct LocalDraftResolutionInput<'a> {
    requested_draft_id: Option<&'a str>,
    project_id: &'a str,
    requested_base_commit_id: Option<&'a str>,
    new_draft_base_commit_id: Option<&'a str>,
    scope: DaemonDraftScope,
    resource: DaemonDraftResourceKind,
    op: &'a DaemonDraftOperation,
}

async fn resolve_local_draft(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    input: LocalDraftResolutionInput<'_>,
) -> Result<String, DaemonError> {
    let LocalDraftResolutionInput {
        requested_draft_id,
        project_id,
        requested_base_commit_id,
        new_draft_base_commit_id,
        scope,
        resource,
        op,
    } = input;
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
        if requested_base_commit_id.is_some()
            && stored_base_commit_id.as_deref() != requested_base_commit_id
        {
            return Err(DaemonError::InvalidRequest(format!(
                "local draft {draft_id} has a different base commit"
            )));
        }
        let status: String = row.try_get("status")?;
        if status != "open" && status != "submitted" {
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
                draft_id, project_id, base_commit_id, current_commit_id,
                resource_scope, resource_kind, target_id, path, status
             )
             VALUES ($1, $2, $3, $3, $4, $5, NULL, $6, 'open')",
        )
        .bind(&draft_id)
        .bind(project_id)
        .bind(new_draft_base_commit_id)
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
         WHERE (draft_id = $1 OR target_id = $1)
           AND status IN ('open', 'submitted')
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
        if requested_base_commit_id.is_some()
            && stored_base_commit_id.as_deref() != requested_base_commit_id
        {
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
            draft_id, project_id, base_commit_id, current_commit_id,
            resource_scope, resource_kind, target_id, path, status
         )
         VALUES ($1, $2, $3, $3, $4, $5, $6, NULL, $7)",
    )
    .bind(&draft_id)
    .bind(project_id)
    .bind(new_draft_base_commit_id)
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
            d.current_commit_id, d.freshness, d.reconciliation, d.reconciliation_candidate_id,
            d.resource_scope, d.resource_kind, d.target_id, d.path,
            d.status, d.created_at, d.updated_at,
            (
                SELECT COUNT(*)
                FROM local_draft_operations o
                WHERE o.draft_id = d.draft_id AND o.sync_status IN ('queued', 'syncing', 'retrying')
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
    let mut tx = pool.begin().await?;
    let row = sqlx::query(
        "SELECT
            d.draft_id, d.project_id, d.server_draft_id, d.server_version, d.base_commit_id,
            d.current_commit_id, d.freshness, d.reconciliation, d.reconciliation_candidate_id,
            d.resource_scope, d.resource_kind, d.target_id, d.path,
            d.status, d.created_at, d.updated_at,
            (
                SELECT COUNT(*)
                FROM local_draft_operations o
                WHERE o.draft_id = d.draft_id AND o.sync_status IN ('queued', 'syncing', 'retrying')
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
    .fetch_optional(&mut *tx)
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
    .fetch_all(&mut *tx)
    .await?;
    let operations = rows
        .iter()
        .map(local_draft_operation_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    tx.commit().await?;
    Ok(DaemonDraftDetail { draft, operations })
}

fn local_draft_summary_from_row(row: &SqliteRow) -> Result<DaemonDraftSummary, DaemonError> {
    Ok(DaemonDraftSummary {
        draft_id: row.try_get("draft_id")?,
        project_id: row.try_get("project_id")?,
        server_draft_id: row.try_get("server_draft_id")?,
        server_version: row.try_get("server_version")?,
        base_commit_id: row.try_get("base_commit_id")?,
        current_commit_id: row.try_get("current_commit_id")?,
        freshness: draft_freshness_from_str(row.try_get::<String, _>("freshness")?.as_str())?,
        reconciliation: draft_reconciliation_status_from_str(
            row.try_get::<String, _>("reconciliation")?.as_str(),
        )?,
        reconciliation_candidate_id: row.try_get("reconciliation_candidate_id")?,
        scope: daemon_draft_scope_from_str(row.try_get::<String, _>("resource_scope")?.as_str())?,
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
         WHERE sync_status IN ('queued', 'syncing', 'retrying')",
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
    let retrying_operation_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM local_draft_operations
         WHERE sync_status = 'retrying'",
    )
    .fetch_one(pool)
    .await?;
    let behind_draft_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM local_drafts WHERE freshness = 'behind'")
            .fetch_one(pool)
            .await?;
    let reconciliation_conflict_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM local_drafts WHERE reconciliation = 'conflicts'")
            .fetch_one(pool)
            .await?;
    let server_cursor = load_meta_value(pool, META_DRAFT_EVENTS_CURSOR).await?;
    let last_attempt_at = load_meta_value(pool, META_DRAFT_SYNC_LAST_ATTEMPT_AT).await?;
    let last_success_at = load_meta_value(pool, META_DRAFT_SYNC_LAST_SUCCESS_AT).await?;
    let last_error: Option<String> = sqlx::query_scalar(
        "SELECT last_error
         FROM local_draft_operations
         WHERE sync_status IN ('retrying', 'failed') AND last_error IS NOT NULL
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
    } else if retrying_operation_count > 0 {
        SyncState::Retrying
    } else if pending_operation_count > 0 {
        SyncState::Queued
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
                    code: if retrying_operation_count > 0 {
                        "draft_sync_retrying".to_owned()
                    } else {
                        "draft_sync_failed".to_owned()
                    },
                    message,
                    request_id: "local".to_owned(),
                    details: json!({}),
                })
            }),
        },
        commit_sync,
        pending_operation_count,
        failed_operation_count,
        behind_draft_count,
        reconciliation_conflict_count,
        last_success_at: overall_last_success_at,
    })
}

async fn drain_draft_queue(state: &DaemonState) -> Result<bool, DaemonError> {
    let mut queue_converged = true;
    loop {
        let Some(operation) = load_next_queued_operation(&state.inner.pool).await? else {
            break;
        };
        mark_operation_syncing(&state.inner.pool, &operation.local_operation_id).await?;
        if let Err(error) = sync_one_draft_operation(state, operation).await {
            queue_converged = false;
            if error.is_retryable() {
                mark_operation_retrying(
                    &state.inner.pool,
                    error.local_operation_id(),
                    &error.to_string(),
                )
                .await?;
            } else {
                mark_operation_failed(
                    &state.inner.pool,
                    error.local_operation_id(),
                    &error.to_string(),
                )
                .await?;
            }
        }
    }
    let unsynced_operation_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM local_draft_operations
         WHERE sync_status != 'synced'",
    )
    .fetch_one(&state.inner.pool)
    .await?;
    Ok(queue_converged && unsynced_operation_count == 0)
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
            .map_err(|error| {
                DraftSyncError::from_daemon_error(local_operation_id.clone(), error)
            })?;
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
                    DraftSyncError::from_daemon_error(local_operation_id.clone(), error)
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
        .map_err(|error| DraftSyncError::from_daemon_error(local_operation_id.clone(), error))?;
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

async fn mark_operation_retrying(
    pool: &SqlitePool,
    local_operation_id: &str,
    message: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'retrying', last_error = $2, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE local_operation_id = $1",
    )
    .bind(local_operation_id)
    .bind(message)
    .execute(pool)
    .await?;
    Ok(())
}

async fn queue_retrying_operations(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'queued', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE sync_status = 'retrying'",
    )
    .execute(pool)
    .await?;
    Ok(())
}

async fn recover_interrupted_operations(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "UPDATE local_draft_operations
         SET sync_status = 'queued', last_error = NULL,
             updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE sync_status = 'syncing'",
    )
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
        return Err(DaemonError::ServerResponse {
            status: status.as_u16(),
            body,
        });
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
    clear_server_response_cache(&state.inner.pool).await?;
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
    Err(DaemonError::ServerResponse {
        status: status.as_u16(),
        body,
    })
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

fn is_retryable_http_status(status: u16) -> bool {
    status == 408 || status == 429 || status >= 500
}

async fn save_cached_server_response(
    pool: &SqlitePool,
    server_url: &str,
    path: &str,
    response: &DaemonServerResponse,
) -> Result<(), DaemonError> {
    sqlx::query(
        "INSERT INTO server_response_cache (
            server_url, path, status, headers_json, body, updated_at
         )
         VALUES ($1, $2, $3, $4, $5, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
         ON CONFLICT(server_url, path) DO UPDATE SET
            status = excluded.status,
            headers_json = excluded.headers_json,
            body = excluded.body,
            updated_at = excluded.updated_at",
    )
    .bind(server_url)
    .bind(path)
    .bind(i64::from(response.status))
    .bind(serde_json::to_string(&response.headers)?)
    .bind(&response.body)
    .execute(pool)
    .await?;
    Ok(())
}

async fn load_cached_server_response(
    pool: &SqlitePool,
    server_url: &str,
    path: &str,
) -> Result<Option<DaemonServerResponse>, DaemonError> {
    let Some(row) = sqlx::query(
        "SELECT status, headers_json, body
         FROM server_response_cache
         WHERE server_url = $1 AND path = $2",
    )
    .bind(server_url)
    .bind(path)
    .fetch_optional(pool)
    .await?
    else {
        return Ok(None);
    };
    let mut headers: BTreeMap<String, String> =
        serde_json::from_str(&row.try_get::<String, _>("headers_json")?)?;
    headers.insert("x-clumsies-cache".to_owned(), "stale".to_owned());
    Ok(Some(DaemonServerResponse {
        status: row.try_get::<i64, _>("status")?.try_into().map_err(|_| {
            DaemonError::Server("cached Server response has an invalid status".to_owned())
        })?,
        headers,
        body: row.try_get("body")?,
    }))
}

async fn clear_server_response_cache(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query("DELETE FROM server_response_cache")
        .execute(pool)
        .await?;
    Ok(())
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
            content: Some(create.content.clone()),
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
            content: Some(update.content.clone()),
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
            content: None,
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
            content: None,
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
        "merged" => Ok(DaemonLocalDraftStatus::Merged),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown local draft status: {other}"
        ))),
    }
}

fn draft_freshness_from_str(value: &str) -> Result<DaemonDraftFreshness, DaemonError> {
    match value {
        "current" => Ok(DaemonDraftFreshness::Current),
        "behind" => Ok(DaemonDraftFreshness::Behind),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown draft freshness: {other}"
        ))),
    }
}

fn draft_reconciliation_status_from_str(
    value: &str,
) -> Result<DaemonDraftReconciliationStatus, DaemonError> {
    match value {
        "unknown" => Ok(DaemonDraftReconciliationStatus::Unknown),
        "clean" => Ok(DaemonDraftReconciliationStatus::Clean),
        "conflicts" => Ok(DaemonDraftReconciliationStatus::Conflicts),
        other => Err(DaemonError::InvalidRequest(format!(
            "unknown draft reconciliation status: {other}"
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
        "retrying" => Ok(DraftOperationSyncStatus::Retrying),
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

        // The Server projection is canonical even for events produced by this installation.
        // Re-projecting them refreshes coordination fields that an upload response cannot carry.
        let remote_events = response.events.iter().collect::<Vec<_>>();
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
            if let Some(base_commit_id) = detail.draft.base_commit_id.as_deref() {
                commit_sync::ensure_commit_cached(state, base_commit_id).await?;
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
                 current_commit_id = $5, freshness = $6, reconciliation = $7,
                 reconciliation_candidate_id = $8,
                 resource_scope = $9, resource_kind = $10, target_id = $11, path = $12,
                 status = $13, updated_at = $14
             WHERE draft_id = $1",
        )
        .bind(&local_draft_id)
        .bind(&detail.draft.project_id)
        .bind(detail.draft.version)
        .bind(&detail.draft.base_commit_id)
        .bind(&detail.draft.coordination.current_commit_id)
        .bind(detail.draft.coordination.freshness.as_str())
        .bind(detail.draft.coordination.reconciliation.as_str())
        .bind(&detail.draft.coordination.candidate_id)
        .bind(detail.draft.resource.scope.as_str())
        .bind(detail.draft.resource.kind.as_str())
        .bind(&detail.draft.resource.id)
        .bind(&detail.draft.resource.path)
        .bind(detail.draft.status.as_str())
        .bind(&detail.draft.updated_at)
        .execute(&mut **tx)
        .await?;
        local_draft_id
    } else {
        sqlx::query(
            "INSERT INTO local_drafts (
                draft_id, project_id, server_draft_id, server_version, base_commit_id,
                current_commit_id, freshness, reconciliation, reconciliation_candidate_id,
                resource_scope, resource_kind, target_id, path,
                status, created_at, updated_at
             )
             VALUES ($1, $2, $1, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)",
        )
        .bind(&detail.draft.draft_id)
        .bind(&detail.draft.project_id)
        .bind(detail.draft.version)
        .bind(&detail.draft.base_commit_id)
        .bind(&detail.draft.coordination.current_commit_id)
        .bind(detail.draft.coordination.freshness.as_str())
        .bind(detail.draft.coordination.reconciliation.as_str())
        .bind(&detail.draft.coordination.candidate_id)
        .bind(detail.draft.resource.scope.as_str())
        .bind(detail.draft.resource.kind.as_str())
        .bind(&detail.draft.resource.id)
        .bind(&detail.draft.resource.path)
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
                 SET server_operation_id = $2,
                     sync_status = 'synced',
                     last_error = NULL,
                     updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
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
                content: operation
                    .content
                    .clone()
                    .ok_or_else(|| missing("content"))?,
                description: None,
            });
        }
        ServerDraftOperationAction::Update => {
            mapped.update = Some(DaemonUpdateDraftOperation {
                id: operation.resource.id.clone().ok_or_else(|| missing("id"))?,
                content: operation
                    .content
                    .clone()
                    .ok_or_else(|| missing("content"))?,
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
        ) => left.path == right.path && left.content == right.content,
        (
            DaemonDraftOperation {
                update: Some(left), ..
            },
            DaemonDraftOperation {
                update: Some(right),
                ..
            },
        ) => left.id == right.id && left.content == right.content,
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
    search::migrate(pool).await?;
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

async fn migrate_local_schema_13_to_14(pool: &SqlitePool) -> Result<(), DaemonError> {
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

async fn migrate_local_schema_14_to_15(pool: &SqlitePool) -> Result<(), DaemonError> {
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

async fn migrate_local_schema_15_to_16(pool: &SqlitePool) -> Result<(), DaemonError> {
    create_project_bindings_table(pool).await
}

async fn create_project_bindings_table(pool: &SqlitePool) -> Result<(), DaemonError> {
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

async fn reset_memory_cache_if_required(
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

fn canonical_server_url(server_url: &str) -> Result<String, DaemonError> {
    ProjectConfig {
        server_url: server_url.to_owned(),
        project_id: None,
    }
    .validate()?;
    Ok(server_url.trim().trim_end_matches('/').to_owned())
}

fn canonical_workspace_directory(path: &str) -> Result<PathBuf, DaemonError> {
    let path = path.trim();
    if path.is_empty() {
        return Err(DaemonError::InvalidRequest(
            "workspace path must not be empty".to_owned(),
        ));
    }
    let canonical = std::fs::canonicalize(path).map_err(|error| {
        DaemonError::InvalidRequest(format!("workspace path {path} cannot be resolved: {error}"))
    })?;
    if !canonical.is_dir() {
        return Err(DaemonError::InvalidRequest(format!(
            "workspace path {} is not a directory",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn project_binding_from_row(row: &SqliteRow) -> Result<DaemonProjectBinding, DaemonError> {
    Ok(DaemonProjectBinding {
        server_url: row.try_get("server_url")?,
        workspace_root: row.try_get("workspace_root")?,
        project_id: row.try_get("project_id")?,
        revision: row.try_get("revision")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
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
pub struct DaemonProjectSelectionRequest {
    pub project_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectBindingResolveRequest {
    pub workspace_path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectBindingReplaceRequest {
    pub workspace_root: String,
    pub project_id: String,
    pub expected_revision: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectBinding {
    pub server_url: String,
    pub workspace_root: String,
    pub project_id: String,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
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
    pub behind_draft_count: i64,
    pub reconciliation_conflict_count: i64,
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
    Retrying,
    Degraded,
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
    pub current_commit_id: Option<String>,
    pub freshness: DaemonDraftFreshness,
    pub reconciliation: DaemonDraftReconciliationStatus,
    pub reconciliation_candidate_id: Option<String>,
    pub scope: DaemonDraftScope,
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
    Merged,
    Discarded,
}

impl DaemonLocalDraftStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Submitted => "submitted",
            Self::Merged => "merged",
            Self::Discarded => "discarded",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonDraftFreshness {
    Current,
    Behind,
}

impl DaemonDraftFreshness {
    fn as_str(self) -> &'static str {
        match self {
            Self::Current => "current",
            Self::Behind => "behind",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DaemonDraftReconciliationStatus {
    Unknown,
    Clean,
    Conflicts,
}

impl DaemonDraftReconciliationStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Clean => "clean",
            Self::Conflicts => "conflicts",
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
}

impl DaemonDraftResourceKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Context => "context",
            Self::Rule => "rule",
            Self::Workflow => "workflow",
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
    fn validate(&self, resource: DaemonDraftResourceKind) -> Result<(), DaemonError> {
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
        if count != 1 {
            return Err(DaemonError::InvalidRequest(
                "draft operation must contain exactly one operation variant".to_owned(),
            ));
        }
        if let Some(create) = &self.create {
            validate_draft_resource_path(resource, &create.path)?;
        }
        if let Some(rename) = &self.rename {
            validate_draft_resource_path(resource, &rename.new_path)?;
        }
        let content = self
            .create
            .as_ref()
            .map(|operation| &operation.content)
            .or_else(|| self.update.as_ref().map(|operation| &operation.content));
        if let Some(content) = content {
            if content.resource_kind() != resource {
                return Err(DaemonError::InvalidRequest(
                    "draft content kind does not match its resource".to_owned(),
                ));
            }
            content.validate()?;
        }
        Ok(())
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

pub(crate) fn is_normalized_relative_path(path: &str) -> bool {
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

fn validate_draft_resource_path(
    resource: DaemonDraftResourceKind,
    path: &str,
) -> Result<(), DaemonError> {
    if !is_normalized_relative_path(path) {
        return Err(DaemonError::InvalidRequest(format!(
            "resource path is not a portable normalized relative path: {path}"
        )));
    }
    match resource {
        DaemonDraftResourceKind::Workflow if !path.starts_with("workflow/") => {
            Err(DaemonError::InvalidRequest(
                "workflow path must use the workflow/ namespace".to_owned(),
            ))
        }
        DaemonDraftResourceKind::Rule if path.to_ascii_lowercase().starts_with("workflow/") => Err(
            DaemonError::InvalidRequest("rule path cannot use the workflow/ namespace".to_owned()),
        ),
        _ => Ok(()),
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonCreateDraftOperation {
    pub path: String,
    pub content: DaemonDraftContent,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonUpdateDraftOperation {
    pub id: String,
    pub content: DaemonDraftContent,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DaemonDraftContent {
    Context { content: String },
    Rule { content: String },
    Workflow { content: String },
}

impl DaemonDraftContent {
    fn resource_kind(&self) -> DaemonDraftResourceKind {
        match self {
            Self::Context { .. } => DaemonDraftResourceKind::Context,
            Self::Rule { .. } => DaemonDraftResourceKind::Rule,
            Self::Workflow { .. } => DaemonDraftResourceKind::Workflow,
        }
    }

    fn validate(&self) -> Result<(), DaemonError> {
        match self {
            Self::Rule { content } if content.trim().is_empty() => Err(
                DaemonError::InvalidRequest("rule content must not be empty".to_owned()),
            ),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod draft_operation_validation_tests {
    use super::*;

    fn create_operation(content: DaemonDraftContent) -> DaemonDraftOperation {
        let path = match content.resource_kind() {
            DaemonDraftResourceKind::Context => "context/test.md",
            DaemonDraftResourceKind::Rule => "rules/test",
            DaemonDraftResourceKind::Workflow => "workflow/test",
        };
        DaemonDraftOperation {
            create: Some(DaemonCreateDraftOperation {
                path: path.to_owned(),
                content,
                description: None,
            }),
            update: None,
            rename: None,
            delete: None,
            discard: None,
        }
    }

    #[test]
    fn rejects_blank_rule_content_before_storage() {
        let operation = create_operation(DaemonDraftContent::Rule {
            content: "  ".to_owned(),
        });

        assert!(operation.validate(DaemonDraftResourceKind::Rule).is_err());
    }

    #[test]
    fn rejects_content_that_does_not_match_the_resource() {
        let operation = create_operation(DaemonDraftContent::Context {
            content: "# Context".to_owned(),
        });

        assert!(operation.validate(DaemonDraftResourceKind::Rule).is_err());
    }

    #[test]
    fn rejects_non_portable_paths_before_storage() {
        for path in [
            "../outside.md",
            "context//test.md",
            "context/AUX.md",
            "context/test\\file.md",
        ] {
            let mut operation = create_operation(DaemonDraftContent::Context {
                content: "# Context".to_owned(),
            });
            operation.create.as_mut().unwrap().path = path.to_owned();

            assert!(
                operation
                    .validate(DaemonDraftResourceKind::Context)
                    .is_err(),
                "path should be rejected: {path}"
            );
        }
    }
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
    Retrying,
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
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftCoordination {
    current_commit_id: Option<String>,
    freshness: DaemonDraftFreshness,
    reconciliation: DaemonDraftReconciliationStatus,
    candidate_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct ServerDraftProjection {
    draft_id: String,
    project_id: String,
    base_commit_id: Option<String>,
    coordination: ServerDraftCoordination,
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
    content: Option<DaemonDraftContent>,
    new_path: Option<String>,
    created_at: String,
}

#[derive(Clone, Debug, Serialize)]
struct ServerDraftOperationInput {
    action: ServerDraftOperationAction,
    resource: ServerDraftResourceRef,
    content: Option<DaemonDraftContent>,
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
    let error = match error {
        DaemonError::Search { code, message } => {
            return ApiError {
                code,
                message,
                request_id: format!("req_{}", Uuid::new_v4().simple()),
                details: json!({}),
            };
        }
        DaemonError::State { code, message } => {
            return ApiError {
                code: code.to_owned(),
                message,
                request_id: format!("req_{}", Uuid::new_v4().simple()),
                details: json!({}),
            };
        }
        error => error,
    };
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
        DaemonError::ServerResponse { status, body } => (
            "server_request_failed",
            format!("Server request failed with status {status}: {body}"),
        ),
        DaemonError::Launchctl(message) => ("launchctl_failed", message),
        DaemonError::Ipc(message) => ("daemon_ipc_failed", message),
        DaemonError::Search { .. } => unreachable!("search errors return above"),
        DaemonError::State { .. } => unreachable!("state errors return above"),
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
    #[error("Server request failed with status {status}: {body}")]
    ServerResponse { status: u16, body: String },
    #[error("launchctl error: {0}")]
    Launchctl(String),
    #[error("daemon IPC error: {0}")]
    Ipc(String),
    #[error("search error ({code}): {message}")]
    Search { code: String, message: String },
    #[error("state error ({code}): {message}")]
    State { code: &'static str, message: String },
}

impl DaemonError {
    fn is_retryable(&self) -> bool {
        match self {
            Self::Reqwest(_) => true,
            Self::ServerResponse { status, .. } => is_retryable_http_status(*status),
            _ => false,
        }
    }
}

#[derive(Debug)]
struct DraftSyncError {
    local_operation_id: String,
    message: String,
    retryable: bool,
}

impl DraftSyncError {
    fn new(local_operation_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            local_operation_id: local_operation_id.into(),
            message: message.into(),
            retryable: false,
        }
    }

    fn from_daemon_error(local_operation_id: impl Into<String>, error: DaemonError) -> Self {
        Self {
            local_operation_id: local_operation_id.into(),
            retryable: error.is_retryable(),
            message: error.to_string(),
        }
    }

    fn local_operation_id(&self) -> &str {
        &self.local_operation_id
    }

    fn is_retryable(&self) -> bool {
        self.retryable
    }
}

impl std::fmt::Display for DraftSyncError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for DraftSyncError {}
