use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use crate::util::{home_dir, non_empty_string, parse_bool_env, parse_u64_env};
use crate::{
    DaemonBootstrapStatus, DaemonError, DaemonIpcEndpoint, DaemonIpcTransport,
    LaunchAgentRuntimeStatus, ProjectConfigReadiness, ServerCredentials,
};

pub const IDENTIFIER_NAMESPACE: &str = "ai.clumsies";
pub const DAEMON_AGENT_LABEL: &str = "ai.clumsies.daemon";
pub const DAEMON_MACH_SERVICE_NAME: &str = DAEMON_AGENT_LABEL;
pub const CURRENT_LOCAL_SCHEMA_VERSION: i64 = 32;
pub(crate) const META_DRAFT_EVENTS_CURSOR: &str = "draft_events_cursor";
pub(crate) const META_MEMORY_CACHE_RESET_REQUIRED: &str = "memory_cache_reset_required";
pub(crate) const META_DRAFT_SYNC_LAST_ATTEMPT_AT: &str = "draft_sync_last_attempt_at";
pub(crate) const META_DRAFT_SYNC_LAST_SUCCESS_AT: &str = "draft_sync_last_success_at";

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
    <key>RUST_LOG</key>
    <string>info</string>
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
    pub(crate) fn from_env() -> Self {
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

    pub(crate) fn validate(&self) -> Result<(), DaemonError> {
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
pub(crate) struct RuntimeProjectConfig {
    pub(crate) server_url: String,
    pub(crate) project_id: Option<String>,
    pub(crate) access_token: Option<String>,
    pub(crate) refresh_token: Option<String>,
}

impl RuntimeProjectConfig {
    pub(crate) fn validate(&self) -> Result<(), DaemonError> {
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

    pub(crate) fn metadata(&self) -> ProjectConfig {
        ProjectConfig {
            server_url: self.server_url.clone(),
            project_id: self.project_id.clone(),
        }
    }

    pub(crate) fn credentials(&self) -> Option<ServerCredentials> {
        self.access_token
            .as_ref()
            .map(|access_token| ServerCredentials {
                server_url: self.server_url.clone(),
                access_token: access_token.clone(),
                refresh_token: self.refresh_token.clone(),
            })
    }

    pub(crate) fn readiness(&self) -> ProjectConfigReadiness {
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

    pub(crate) fn server_readiness(&self) -> ProjectConfigReadiness {
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
