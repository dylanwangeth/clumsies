use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use daemon::agent_runtime::hook::{
    HookEventName, HookHost, MAX_HOOK_INPUT_BYTES, NormalizedHookEvent, normalize_hook_event,
};
use daemon::agent_runtime::mcp::McpServer;
use daemon::{
    AgentRunKind, CredentialStore, CredentialStoreError, DAEMON_MACH_SERVICE_NAME, DaemonConfig,
    DaemonError, DaemonIpcClient, DaemonIpcServer, DaemonIpcService,
    DaemonProjectBindingResolveRequest, DaemonState, IssueBoardState, IssueDetailRequest,
    LaunchAgentConfig, LaunchAgentController, RecordAgentRunEventResponse, ServerCredentials,
};
use serde_json::{Value, json};
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::time::SystemTime;
use tracing_subscriber::fmt::writer::MakeWriterExt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProcessMode {
    McpServe,
    AgentIssueRunEvent(HookHost),
    Daemon,
}

const AGENT_RUNTIME_TEST_MACH_SERVICE_ENV: &str = "CLUMSIES_AGENT_RUNTIME_TEST_MACH_SERVICE";
const AGENT_RUNTIME_TEST_MACH_SERVICE_PREFIX: &str = "ai.clumsies.test.";
const AGENT_RUNTIME_TEST_STALE_TOOL_BUILD_ENV: &str =
    "CLUMSIES_AGENT_RUNTIME_TEST_STALE_TOOL_BUILD_ID";
// A launchd cold start may include the bounded startup credential probe before
// the resident listener is ready. Keep MCP bootstrap finite but long enough to
// survive that supported path; Hook delivery remains deliberately short and
// fail-open below.
const AGENT_RUNTIME_STARTUP_IPC_TIMEOUT: Duration = Duration::from_secs(30);
const AGENT_RUNTIME_MCP_IPC_TIMEOUT: Duration = Duration::from_secs(65);
const AGENT_RUNTIME_HOOK_IPC_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug)]
struct IsolatedTestCredentialStore;

impl CredentialStore for IsolatedTestCredentialStore {
    fn load(&self) -> Result<Option<ServerCredentials>, CredentialStoreError> {
        Ok(None)
    }

    fn replace(&self, _credentials: &ServerCredentials) -> Result<(), CredentialStoreError> {
        Err(CredentialStoreError::new(
            "credential writes are disabled for the isolated Agent runtime test service",
        ))
    }

    fn clear(&self) -> Result<(), CredentialStoreError> {
        Err(CredentialStoreError::new(
            "credential writes are disabled for the isolated Agent runtime test service",
        ))
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match process_mode(&args)? {
        ProcessMode::McpServe => run_mcp_proxy(),
        ProcessMode::AgentIssueRunEvent(host) => {
            // Lifecycle observation is fail-open. The managed wrapper records
            // bounded diagnostics, while raw Hook input is never echoed here.
            if run_hook_proxy(host).is_err() {
                eprintln!("clumsiesd Hook proxy could not record this lifecycle event");
            }
            Ok(())
        }
        ProcessMode::Daemon => {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()?;
            runtime.block_on(run_daemon(args))
        }
    }
}

fn process_mode(args: &[String]) -> Result<ProcessMode, Box<dyn std::error::Error>> {
    match args {
        [first, second] if first == "mcp" && second == "serve" => Ok(ProcessMode::McpServe),
        [agent, command, flag, host]
            if agent == "_agent" && command == "issue-run-event" && flag == "--host" =>
        {
            let host = match host.as_str() {
                "codex" => HookHost::Codex,
                "claude-code" => HookHost::ClaudeCode,
                "opencode" => HookHost::Opencode,
                _ => return Err("unsupported Agent Hook host".into()),
            };
            Ok(ProcessMode::AgentIssueRunEvent(host))
        }
        _ => Ok(ProcessMode::Daemon),
    }
}

fn run_mcp_proxy() -> Result<(), Box<dyn std::error::Error>> {
    let client = agent_runtime_client(AGENT_RUNTIME_STARTUP_IPC_TIMEOUT)?;
    verify_agent_runtime(&client)?;
    let workspace_path = std::env::current_dir()?.to_string_lossy().into_owned();
    let binding =
        client.resolve_project_binding(DaemonProjectBindingResolveRequest { workspace_path })?;
    // The debug-only test seam changes the backend identity only after the
    // startup health and binding requests. This models a resident replacement
    // between MCP initialize and the next tools/call over real XPC.
    let backend = match stale_tool_identity_for_test()? {
        Some(identity) => DaemonIpcClient::for_agent_runtime(client.service_name(), identity)
            .with_timeout(AGENT_RUNTIME_MCP_IPC_TIMEOUT),
        None => client.with_timeout(AGENT_RUNTIME_MCP_IPC_TIMEOUT),
    };
    let mut server = McpServer::new(backend, binding.project_id, env!("CARGO_PKG_VERSION"));
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    server.serve(&mut stdin.lock(), &mut stdout.lock())?;
    Ok(())
}

fn run_hook_proxy(host: HookHost) -> Result<(), Box<dyn std::error::Error>> {
    let mut raw = Vec::new();
    std::io::stdin()
        .take((MAX_HOOK_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut raw)?;
    let event = normalize_hook_event(host, &raw)?;

    let workspace_path = match event.workspace_path() {
        Some(path) => path.to_owned(),
        None => std::env::current_dir()?.to_string_lossy().into_owned(),
    };
    let client = agent_runtime_client(AGENT_RUNTIME_HOOK_IPC_TIMEOUT)?;
    verify_agent_runtime(&client)?;
    let binding =
        client.resolve_project_binding(DaemonProjectBindingResolveRequest { workspace_path })?;
    if should_offer_stop_decision(host, &event) {
        let probe = event
            .to_stop_probe_request(&binding.project_id)
            .ok_or("Stop event did not produce a decision probe")?;
        let response = client.record_agent_run_event(probe)?;
        if !response.duplicate {
            write_hook_output(&json!({
                "decision": "block",
                "reason": "Before stopping, make the explicit semantic Issue decision now. If the current root task is linked to an In Progress Issue and its acceptance criteria are satisfied, call kanban.request_closure with the current run_id and AgentRun revision. Otherwise leave it In Progress. Stop itself never completes or advances an Issue."
            }))?;
        }
        return Ok(());
    }
    let response = client.record_agent_run_event(event.to_record_request(&binding.project_id))?;
    if response.duplicate {
        return Ok(());
    }
    if let Some(output) = hook_context(&client, &binding.project_id, &event, &response) {
        write_hook_output(&output)?;
    }
    Ok(())
}

fn verify_agent_runtime(client: &DaemonIpcClient) -> Result<(), Box<dyn std::error::Error>> {
    let resident = client.health()?.agent_runtime;
    if !agent_runtime_matches(&resident) {
        return Err(
            "Agent runtime does not match the resident daemon; restart Clumsies and the Agent host"
                .into(),
        );
    }
    Ok(())
}

fn agent_runtime_client(request_timeout: Duration) -> Result<DaemonIpcClient, DaemonError> {
    Ok(DaemonIpcClient::for_agent_runtime(
        agent_runtime_mach_service_name()?,
        daemon::agent_runtime::current_identity(),
    )
    .with_timeout(request_timeout))
}

/// An isolated Mach service is required by the process/XPC integration test.
/// The strict prefix and character allowlist prevent this seam from targeting
/// the installed service or another user's launchd job.
fn agent_runtime_mach_service_name() -> Result<String, DaemonError> {
    let Some(service_name) = std::env::var(AGENT_RUNTIME_TEST_MACH_SERVICE_ENV).ok() else {
        return Ok(DAEMON_MACH_SERVICE_NAME.to_owned());
    };
    if !cfg!(debug_assertions) {
        return Err(DaemonError::InvalidConfig(format!(
            "{AGENT_RUNTIME_TEST_MACH_SERVICE_ENV} is unavailable in release builds"
        )));
    }
    validate_test_mach_service_name(&service_name)?;
    Ok(service_name)
}

fn validate_test_mach_service_name(service_name: &str) -> Result<(), DaemonError> {
    let valid = service_name.starts_with(AGENT_RUNTIME_TEST_MACH_SERVICE_PREFIX)
        && service_name.len() <= 255
        && service_name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'));
    if !valid {
        return Err(DaemonError::InvalidConfig(format!(
            "{AGENT_RUNTIME_TEST_MACH_SERVICE_ENV} must be a bounded {AGENT_RUNTIME_TEST_MACH_SERVICE_PREFIX}* service name"
        )));
    }
    Ok(())
}

fn stale_tool_identity_for_test() -> Result<Option<daemon::AgentRuntimeIdentity>, DaemonError> {
    let Some(build_id) = std::env::var(AGENT_RUNTIME_TEST_STALE_TOOL_BUILD_ENV).ok() else {
        return Ok(None);
    };
    if !cfg!(debug_assertions)
        || std::env::var(AGENT_RUNTIME_TEST_MACH_SERVICE_ENV).is_err()
        || build_id.is_empty()
        || build_id.len() > 128
        || !build_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(DaemonError::InvalidConfig(format!(
            "{AGENT_RUNTIME_TEST_STALE_TOOL_BUILD_ENV} is allowed only for a bounded debug test service build id"
        )));
    }
    // Re-validate the service here so the stale identity seam can never be
    // used with the installed resident endpoint.
    agent_runtime_mach_service_name()?;
    Ok(Some(daemon::AgentRuntimeIdentity {
        protocol_revision: daemon::agent_runtime::AGENT_RUNTIME_PROTOCOL_REVISION,
        build_id,
    }))
}

fn agent_runtime_matches(resident: &daemon::AgentRuntimeIdentity) -> bool {
    resident.protocol_revision == daemon::agent_runtime::AGENT_RUNTIME_PROTOCOL_REVISION
        && resident.build_id == daemon::agent_runtime::AGENT_RUNTIME_BUILD_ID
}

fn should_offer_stop_decision(host: HookHost, event: &NormalizedHookEvent) -> bool {
    matches!(host, HookHost::Codex | HookHost::ClaudeCode)
        && event.hook_event_name() == HookEventName::Stop
        && !event.stop_hook_active()
        && std::env::var_os("CLUMSIES_HOOK_FORCE_FINAL_STOP").as_deref()
            != Some(std::ffi::OsStr::new("1"))
}

fn hook_context(
    client: &DaemonIpcClient,
    project_id: &str,
    event: &NormalizedHookEvent,
    response: &RecordAgentRunEventResponse,
) -> Option<Value> {
    if !matches!(
        event.hook_event_name(),
        HookEventName::UserPromptSubmit | HookEventName::SubagentStart
    ) {
        return None;
    }
    let run = response.run.as_ref()?;
    if run.revision < 1 || !safe_run_id(&run.run_id) {
        return None;
    }
    let binding = run
        .issue_number
        .and_then(|number| {
            client
                .get_issue_detail(IssueDetailRequest {
                    project_id: project_id.to_owned(),
                    issue_number: number,
                })
                .ok()
        })
        .map(|detail| {
            format!(
                "This run is bound to {} ({}). ",
                detail.issue.issue_key,
                board_state_title(detail.issue.board_state)
            )
        })
        .unwrap_or_else(|| "This run is not bound to any Issue yet. ".to_owned());
    let context = match run.kind {
        AgentRunKind::Root => format!(
            "Clumsies current root AgentRun: run_id={}, revision={}. {}Decide semantically whether this prompt continues an existing native Issue, creates a new durable Issue, or should not become an Issue; never infer that from text matching. Use kanban.list to inspect existing Issues and kanban.create to capture a new one. Before calling kanban.begin_work, check the Issue's active_runs via kanban.get: another AgentRun may already hold it, so claim only the Issue this run is actually working. Call kanban.begin_work with this run_id and revision only when the Issue is the active line of work. Before finishing, call kanban.request_closure only when the linked Issue's acceptance criteria are satisfied; otherwise leave it In Progress. AgentRun Stop never advances, approves, or closes an Issue.",
            run.run_id, run.revision, binding
        ),
        AgentRunKind::Subagent => format!(
            "Clumsies current subagent AgentRun: run_id={}, revision={}. {}Call kanban.begin_work only when this subagent is explicitly working an existing native Issue. Subagents must not request Issue closure; report findings to the root Agent. AgentRun Stop never advances or closes an Issue.",
            run.run_id, run.revision, binding
        ),
    };
    Some(json!({
        "hookSpecificOutput": {
            "hookEventName": event.hook_event_name().as_str(),
            "additionalContext": context
        }
    }))
}

fn write_hook_output(output: &Value) -> Result<(), Box<dyn std::error::Error>> {
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, output)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn safe_run_id(run_id: &str) -> bool {
    run_id.strip_prefix("arun_").is_some_and(|suffix| {
        suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}

fn board_state_title(state: IssueBoardState) -> &'static str {
    match state {
        IssueBoardState::Todo => "Todo",
        IssueBoardState::InProgress => "In Progress",
        IssueBoardState::Paused => "Paused",
        IssueBoardState::InReview => "In Review",
        IssueBoardState::Done => "Done",
    }
}

async fn run_daemon(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    let config = DaemonConfig::from_env()?;
    let test_mach_service = std::env::var_os(AGENT_RUNTIME_TEST_MACH_SERVICE_ENV).is_some();
    let mach_service_name = agent_runtime_mach_service_name()?;

    let log_file = Mutex::new(
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(config.log_dir.join("daemon.log"))?,
    );
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_timer(SystemTime)
        .with_writer(std::io::stderr.and(log_file))
        .with_target(false)
        .init();
    let mut launch_agent =
        LaunchAgentConfig::from_daemon_config(&config, std::env::current_exe()?)?;
    launch_agent.mach_service_name = mach_service_name;
    let launch_agent_controller = LaunchAgentController::for_current_user(launch_agent.clone())?;

    match args.as_slice() {
        [command] if command == "--print-launch-agent-plist" => {
            print!("{}", launch_agent.plist_contents());
            return Ok(());
        }
        [command] if command == "--install-launch-agent" => {
            print_status(&launch_agent_controller.install()?)?;
            return Ok(());
        }
        [command] if command == "--status-launch-agent" => {
            print_status(&launch_agent_controller.status()?)?;
            return Ok(());
        }
        [command] if command == "--bootstrap-launch-agent" => {
            print_status(&launch_agent_controller.bootstrap()?)?;
            return Ok(());
        }
        [command] if command == "--bootout-launch-agent" => {
            print_status(&launch_agent_controller.bootout()?)?;
            return Ok(());
        }
        [command] if command == "--restart-launch-agent" => {
            print_status(&launch_agent_controller.kickstart()?)?;
            return Ok(());
        }
        [command] if command == "--reconcile-launch-agent" => {
            print_status(&launch_agent_controller.reconcile()?)?;
            return Ok(());
        }
        [] => {}
        _ => {
            tracing::error!(
                "usage: clumsiesd [mcp serve|_agent issue-run-event --host <host>|--print-launch-agent-plist|--install-launch-agent|--status-launch-agent|--bootstrap-launch-agent|--bootout-launch-agent|--restart-launch-agent|--reconcile-launch-agent]"
            );
            std::process::exit(64);
        }
    }

    let state = if test_mach_service {
        DaemonState::initialize_with_credential_store(config, Arc::new(IsolatedTestCredentialStore))
            .await?
    } else {
        DaemonState::initialize(config).await?
    };
    let service = DaemonIpcService::new(state.clone());
    let _ipc_server =
        DaemonIpcServer::start(launch_agent.mach_service_name.clone(), service.clone())?;
    // The unique test service exercises the real process/XPC boundary while
    // deliberately avoiding network sync and model downloads in user space.
    let _sync_worker = (!test_mach_service).then(|| state.start_sync_worker());
    let _search_model_worker = (!test_mach_service).then(|| state.start_search_model_worker());
    let _search_index_worker = (!test_mach_service).then(|| state.start_search_index_worker());
    let _run_reaper = (!test_mach_service).then(|| state.start_run_reaper());
    let health = service.health().await;

    tracing::info!(
        "clumsiesd initialized for Mach service {} with installation {}",
        launch_agent.mach_service_name,
        health.daemon_installation_id
    );

    shutdown_signal().await;
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

fn print_status(status: &daemon::DaemonBootstrapStatus) -> Result<(), serde_json::Error> {
    println!("{}", serde_json::to_string_pretty(status)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_modes_are_parsed_before_daemon_initialization() {
        assert_eq!(
            process_mode(&["mcp".to_owned(), "serve".to_owned()]).unwrap(),
            ProcessMode::McpServe
        );
        assert_eq!(
            process_mode(&[
                "_agent".to_owned(),
                "issue-run-event".to_owned(),
                "--host".to_owned(),
                "codex".to_owned(),
            ])
            .unwrap(),
            ProcessMode::AgentIssueRunEvent(HookHost::Codex)
        );
        assert_eq!(process_mode(&[]).unwrap(), ProcessMode::Daemon);
    }

    #[test]
    fn run_id_validation_is_bounded_and_exact() {
        assert!(safe_run_id("arun_0123456789abcdef0123456789abcdef"));
        assert!(!safe_run_id("arun_0123"));
        assert!(!safe_run_id("manual_0123456789abcdef0123456789abcdef"));
    }

    #[test]
    fn proxy_rejects_a_different_resident_build() {
        assert!(agent_runtime_matches(&daemon::AgentRuntimeIdentity {
            protocol_revision: daemon::agent_runtime::AGENT_RUNTIME_PROTOCOL_REVISION,
            build_id: daemon::agent_runtime::AGENT_RUNTIME_BUILD_ID.to_owned(),
        }));
        assert!(!agent_runtime_matches(&daemon::AgentRuntimeIdentity {
            protocol_revision: daemon::agent_runtime::AGENT_RUNTIME_PROTOCOL_REVISION,
            build_id: "different-build".to_owned(),
        }));
    }

    #[test]
    fn test_mach_service_seam_cannot_target_the_installed_daemon() {
        let error = validate_test_mach_service_name(DAEMON_MACH_SERVICE_NAME).unwrap_err();
        assert!(matches!(error, DaemonError::InvalidConfig(_)));
        assert!(validate_test_mach_service_name("ai.clumsies.test.issue049_1").is_ok());
    }
}
