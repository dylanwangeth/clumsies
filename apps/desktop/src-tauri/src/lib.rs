use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
struct DaemonHealthPayload {
    daemon_version: String,
    hub_url: String,
    project_id: Option<String>,
    daemon_installation_id: String,
    log_dir: String,
    local_db: LocalDbStatusPayload,
}

#[derive(Debug, Deserialize, Serialize)]
struct LocalDbStatusPayload {
    path: String,
    ready: bool,
    schema_version: i64,
}

#[tauri::command]
async fn read_daemon_health(daemon_url: String) -> Result<DaemonHealthPayload, String> {
    let url = format!("{}/daemon/health", daemon_url.trim_end_matches('/'));
    let response = reqwest::Client::new()
        .get(url)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("daemon health request failed with status {status}"));
    }
    response
        .json::<DaemonHealthPayload>()
        .await
        .map_err(|error| error.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_daemon_health])
        .run(tauri::generate_context!())
        .expect("failed to run clumsies desktop");
}
