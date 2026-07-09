use daemon::{
    DaemonConfig, DaemonIpcServer, DaemonIpcService, DaemonState, LaunchAgentConfig,
    LaunchAgentController,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = DaemonConfig::from_env()?;
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, std::env::current_exe()?);
    let launch_agent_controller = LaunchAgentController::for_current_user(launch_agent.clone())?;
    let args: Vec<String> = std::env::args().skip(1).collect();

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
        [] => {}
        _ => {
            eprintln!(
                "usage: clumsiesd [--print-launch-agent-plist|--install-launch-agent|--status-launch-agent|--bootstrap-launch-agent|--bootout-launch-agent|--restart-launch-agent]"
            );
            std::process::exit(64);
        }
    }

    let state = DaemonState::initialize(config).await?;
    let service = DaemonIpcService::new(state.clone());
    let _ipc_server =
        DaemonIpcServer::start(launch_agent.mach_service_name.clone(), service.clone())?;
    let _sync_worker = state.start_sync_worker();
    let health = service.health().await;

    eprintln!(
        "clumsiesd initialized for Mach service {} with installation {}",
        launch_agent.mach_service_name, health.daemon_installation_id
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
