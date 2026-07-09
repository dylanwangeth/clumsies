use std::path::PathBuf;

use daemon::{
    DaemonBootstrapStatus, DaemonConfig, DaemonHealth, DaemonXpcClient, LaunchAgentConfig,
    LaunchAgentController,
};

#[tauri::command]
async fn read_daemon_bootstrap_status() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?.status().map_err(|error| error.to_string())
}

#[tauri::command]
async fn install_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?.install().map_err(|error| error.to_string())
}

#[tauri::command]
async fn start_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?.bootstrap().map_err(|error| error.to_string())
}

#[tauri::command]
async fn restart_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?.kickstart().map_err(|error| error.to_string())
}

#[tauri::command]
async fn stop_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?.bootout().map_err(|error| error.to_string())
}

#[tauri::command]
async fn read_daemon_health() -> Result<DaemonHealth, String> {
    let client = daemon_xpc_client()?;
    tauri::async_runtime::spawn_blocking(move || client.health())
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| error.to_string())
}

fn launch_agent_controller() -> Result<LaunchAgentController, String> {
    let config = DaemonConfig::from_env().map_err(|error| error.to_string())?;
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, daemon_program_path()?);
    LaunchAgentController::for_current_user(launch_agent).map_err(|error| error.to_string())
}

fn daemon_xpc_client() -> Result<DaemonXpcClient, String> {
    let config = DaemonConfig::from_env().map_err(|error| error.to_string())?;
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, daemon_program_path()?);
    Ok(DaemonXpcClient::new(launch_agent.mach_service_name))
}

fn daemon_program_path() -> Result<PathBuf, String> {
    if let Some(value) = std::env::var_os("CLUMSIES_DAEMON_PROGRAM") {
        return Ok(PathBuf::from(value));
    }
    let current_exe = std::env::current_exe().map_err(|error| error.to_string())?;
    let parent = current_exe
        .parent()
        .ok_or_else(|| "desktop executable path has no parent directory".to_owned())?;
    Ok(parent.join("clumsiesd"))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            read_daemon_bootstrap_status,
            install_daemon_launch_agent,
            start_daemon_launch_agent,
            restart_daemon_launch_agent,
            stop_daemon_launch_agent,
            read_daemon_health
        ])
        .run(tauri::generate_context!())
        .expect("failed to run clumsies desktop");
}
