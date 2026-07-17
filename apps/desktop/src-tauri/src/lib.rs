use std::path::PathBuf;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use daemon::{
    DaemonBootstrapStatus, DaemonConfig, DaemonDraftDetail, DaemonDraftListQuery,
    DaemonDraftListResponse, DaemonDraftOperationRequest, DaemonDraftOperationResponse,
    DaemonError, DaemonHealth, DaemonIpcClient, DaemonMcpStatus, DaemonProjectConfig,
    DaemonProjectConfigUpdateRequest, DaemonProjectSelectionRequest, DaemonRetryResponse,
    DaemonServerRequest, DaemonServerResponse, DaemonSyncRetryRequest, DaemonSyncStatus,
    LaunchAgentConfig, LaunchAgentController,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::Emitter;
use tauri_plugin_opener::OpenerExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;
use url::Url;
use uuid::Uuid;

mod lifecycle;

const OIDC_CALLBACK_TIMEOUT: Duration = Duration::from_secs(300);
const OIDC_HTTP_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_CALLBACK_HEADER_BYTES: usize = 16 * 1024;
const DESKTOP_AUTHENTICATED_EVENT: &str = "desktop-authenticated";
const DESKTOP_SERVER_URL: &str = "https://app.clumsies.ai";

#[tauri::command]
async fn read_daemon_bootstrap_status() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?
        .status()
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn install_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?
        .install()
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn start_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?
        .reconcile()
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn restart_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?
        .kickstart()
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn stop_daemon_launch_agent() -> Result<DaemonBootstrapStatus, String> {
    launch_agent_controller()?
        .bootout()
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn read_daemon_health() -> Result<DaemonHealth, String> {
    call_daemon(|client| client.health()).await
}

#[tauri::command]
async fn read_daemon_project_config() -> Result<DaemonProjectConfig, String> {
    call_daemon(|client| client.project_config()).await
}

#[tauri::command]
async fn select_daemon_project(
    request: DaemonProjectSelectionRequest,
) -> Result<DaemonProjectConfig, String> {
    call_daemon(move |client| client.select_project(request)).await
}

#[tauri::command]
async fn read_daemon_sync_status() -> Result<DaemonSyncStatus, String> {
    call_daemon(|client| client.sync_status()).await
}

#[tauri::command]
async fn retry_daemon_sync(request: DaemonSyncRetryRequest) -> Result<DaemonRetryResponse, String> {
    call_daemon(move |client| client.retry_sync(request)).await
}

#[tauri::command]
async fn read_daemon_mcp_status() -> Result<DaemonMcpStatus, String> {
    call_daemon(|client| client.mcp_status()).await
}

#[tauri::command]
async fn list_daemon_drafts(
    query: DaemonDraftListQuery,
) -> Result<DaemonDraftListResponse, String> {
    call_daemon(move |client| client.list_drafts(query)).await
}

#[tauri::command]
async fn read_daemon_draft(draft_id: String) -> Result<DaemonDraftDetail, String> {
    call_daemon(move |client| client.get_draft(draft_id)).await
}

#[tauri::command]
async fn store_daemon_draft_operation(
    request: DaemonDraftOperationRequest,
) -> Result<DaemonDraftOperationResponse, String> {
    call_daemon(move |client| client.store_draft_operation(request)).await
}

#[tauri::command]
async fn proxy_server_request(
    request: DaemonServerRequest,
) -> Result<DaemonServerResponse, String> {
    call_daemon(move |client| client.server_request(request)).await
}

#[tauri::command]
async fn authenticate_desktop(app: tauri::AppHandle) -> Result<DaemonProjectConfig, String> {
    let server_url = normalize_server_url(DESKTOP_SERVER_URL)?;
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|error| format!("failed to bind the OIDC callback listener: {error}"))?;
    let callback_port = listener
        .local_addr()
        .map_err(|error| format!("failed to read the OIDC callback address: {error}"))?
        .port();
    let redirect_uri = format!("http://127.0.0.1:{callback_port}/callback");
    let verifier = random_secret();
    let challenge = pkce_challenge(&verifier);
    let state = random_secret();
    let authorization_url = authorization_url(&server_url, &redirect_uri, &challenge, &state)?;

    app.opener()
        .open_url(authorization_url.as_str(), None::<&str>)
        .map_err(|error| format!("failed to open the system browser: {error}"))?;

    let (mut stream, _) = timeout(OIDC_CALLBACK_TIMEOUT, listener.accept())
        .await
        .map_err(|_| "Organization SSO sign-in timed out".to_owned())?
        .map_err(|error| format!("failed to accept the OIDC callback: {error}"))?;
    let code = match read_loopback_callback(&mut stream, &state).await {
        Ok(code) => code,
        Err(error) => {
            let _ = write_loopback_response(&mut stream, false).await;
            return Err(error);
        }
    };

    let result = async {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(OIDC_HTTP_TIMEOUT)
            .build()
            .map_err(|error| format!("failed to initialize the Server client: {error}"))?;
        let tokens =
            exchange_authorization_code(&http, &server_url, &code, &redirect_uri, &verifier)
                .await?;
        let me = load_current_user(&http, &server_url, &tokens.access_token).await?;
        let project_id = me
            .default_project_id
            .or_else(|| {
                me.projects
                    .first()
                    .map(|project| project.project_id.clone())
            })
            .ok_or_else(|| "The signed-in account has no accessible project".to_owned())?;

        call_daemon(move |client| {
            client.replace_project_config(DaemonProjectConfigUpdateRequest {
                server_url,
                project_id: Some(project_id),
                access_token: Some(tokens.access_token),
                refresh_token: Some(tokens.refresh_token),
            })
        })
        .await
    }
    .await;
    let _ = write_loopback_response(&mut stream, result.is_ok()).await;
    if result.is_ok() {
        app.emit_to("main", DESKTOP_AUTHENTICATED_EVENT, ())
            .map_err(|error| format!("failed to notify the Desktop after sign-in: {error}"))?;
    }
    result
}

#[tauri::command]
async fn present_main_window(app: tauri::AppHandle) -> Result<(), String> {
    lifecycle::present_main_window(&app).map_err(|error| error.to_string())
}

#[tauri::command]
async fn present_authentication_window(app: tauri::AppHandle) -> Result<(), String> {
    lifecycle::present_authentication_window(&app).map_err(|error| error.to_string())
}

#[derive(Serialize)]
struct AuthorizationCodeTokenRequest<'a> {
    grant_type: &'static str,
    code: &'a str,
    redirect_uri: &'a str,
    code_verifier: &'a str,
}

#[derive(Deserialize)]
struct DesktopTokenResponse {
    access_token: String,
    refresh_token: String,
}

#[derive(Deserialize)]
struct DesktopMeResponse {
    projects: Vec<DesktopProjectRef>,
    default_project_id: Option<String>,
}

#[derive(Deserialize)]
struct DesktopProjectRef {
    project_id: String,
}

async fn exchange_authorization_code(
    http: &reqwest::Client,
    server_url: &str,
    code: &str,
    redirect_uri: &str,
    verifier: &str,
) -> Result<DesktopTokenResponse, String> {
    let response = http
        .post(format!("{server_url}/api/v1/auth/token"))
        .json(&AuthorizationCodeTokenRequest {
            grant_type: "authorization_code",
            code,
            redirect_uri,
            code_verifier: verifier,
        })
        .send()
        .await
        .map_err(|error| format!("failed to exchange the authorization code: {error}"))?;
    decode_server_response(response, "authorization code exchange").await
}

async fn load_current_user(
    http: &reqwest::Client,
    server_url: &str,
    access_token: &str,
) -> Result<DesktopMeResponse, String> {
    let response = http
        .get(format!("{server_url}/api/v1/me"))
        .bearer_auth(access_token)
        .send()
        .await
        .map_err(|error| format!("failed to load the signed-in account: {error}"))?;
    decode_server_response(response, "current account lookup").await
}

async fn decode_server_response<T: for<'de> Deserialize<'de>>(
    response: reqwest::Response,
    operation: &str,
) -> Result<T, String> {
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!(
            "Server {operation} failed with status {status}: {body}"
        ));
    }
    response
        .json()
        .await
        .map_err(|error| format!("Server returned an invalid {operation} response: {error}"))
}

fn normalize_server_url(value: &str) -> Result<String, String> {
    let mut url =
        Url::parse(value.trim()).map_err(|error| format!("invalid Server URL: {error}"))?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("Server URL must not include credentials".to_owned());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("Server URL must not include a query or fragment".to_owned());
    }
    let loopback_http = url.scheme() == "http"
        && matches!(
            url.host_str(),
            Some("127.0.0.1") | Some("::1") | Some("localhost")
        );
    if url.scheme() != "https" && !loopback_http {
        return Err("Server URL must use HTTPS unless it is a loopback address".to_owned());
    }
    if url.path() != "/" && !url.path().is_empty() {
        return Err("Server URL must not include a path".to_owned());
    }
    url.set_path("");
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

fn authorization_url(
    server_url: &str,
    redirect_uri: &str,
    challenge: &str,
    state: &str,
) -> Result<Url, String> {
    let mut url = Url::parse(&format!("{server_url}/oauth2/authorization/oidc"))
        .map_err(|error| format!("failed to build the authorization URL: {error}"))?;
    url.query_pairs_mut()
        .append_pair("client_kind", "desktop")
        .append_pair("redirect_uri", redirect_uri)
        .append_pair("code_challenge", challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("state", state);
    Ok(url)
}

fn random_secret() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

async fn read_loopback_callback(stream: &mut TcpStream, state: &str) -> Result<String, String> {
    let mut request = Vec::with_capacity(1024);
    let mut chunk = [0_u8; 1024];
    while !request.windows(4).any(|window| window == b"\r\n\r\n") {
        let count = stream
            .read(&mut chunk)
            .await
            .map_err(|error| format!("failed to read the OIDC callback: {error}"))?;
        if count == 0 {
            return Err("browser closed the OIDC callback connection".to_owned());
        }
        request.extend_from_slice(&chunk[..count]);
        if request.len() > MAX_CALLBACK_HEADER_BYTES {
            return Err("OIDC callback headers are too large".to_owned());
        }
    }
    let request =
        std::str::from_utf8(&request).map_err(|_| "OIDC callback is not valid HTTP".to_owned())?;
    let request_line = request
        .lines()
        .next()
        .ok_or_else(|| "OIDC callback has no request line".to_owned())?;
    let mut parts = request_line.split_whitespace();
    if parts.next() != Some("GET") {
        return Err("OIDC callback must use GET".to_owned());
    }
    let target = parts
        .next()
        .ok_or_else(|| "OIDC callback has no request target".to_owned())?;
    parse_callback_target(target, state)
}

fn parse_callback_target(target: &str, expected_state: &str) -> Result<String, String> {
    let callback = Url::parse(&format!("http://127.0.0.1{target}"))
        .map_err(|_| "OIDC callback target is invalid".to_owned())?;
    if callback.path() != "/callback" {
        return Err("OIDC callback path is invalid".to_owned());
    }
    let mut code = None;
    let mut state = None;
    let mut provider_error = None;
    let mut provider_error_description = None;
    for (name, value) in callback.query_pairs() {
        match name.as_ref() {
            "code" => code = Some(value.into_owned()),
            "state" => state = Some(value.into_owned()),
            "error" => provider_error = Some(value.into_owned()),
            "error_description" => provider_error_description = Some(value.into_owned()),
            _ => {}
        }
    }
    if state.as_deref() != Some(expected_state) {
        return Err("OIDC callback state does not match the login request".to_owned());
    }
    if let Some(error) = provider_error {
        return Err(match provider_error_description {
            Some(description) => {
                format!("Organization SSO sign-in failed: {error}: {description}")
            }
            None => format!("Organization SSO sign-in failed: {error}"),
        });
    }
    code.ok_or_else(|| "OIDC callback contains no authorization code".to_owned())
}

async fn write_loopback_response(stream: &mut TcpStream, success: bool) -> Result<(), String> {
    let (status, title, message) = if success {
        (
            "200 OK",
            "Signed in to clumsies",
            "You can close this window and return to the Desktop app.",
        )
    } else {
        (
            "400 Bad Request",
            "Sign-in failed",
            "Return to the Desktop app to review the error.",
        )
    };
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>{title}</title></head>\
         <body><main><h1>{title}</h1><p>{message}</p></main></body></html>"
    );
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .await
        .map_err(|error| format!("failed to write the OIDC callback response: {error}"))
}

fn launch_agent_controller() -> Result<LaunchAgentController, String> {
    let config = DaemonConfig::from_env().map_err(|error| error.to_string())?;
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, daemon_program_path()?);
    LaunchAgentController::for_current_user(launch_agent).map_err(|error| error.to_string())
}

fn daemon_ipc_client() -> Result<DaemonIpcClient, String> {
    let config = DaemonConfig::from_env().map_err(|error| error.to_string())?;
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, daemon_program_path()?);
    Ok(DaemonIpcClient::new(launch_agent.mach_service_name))
}

async fn call_daemon<T, F>(operation: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(DaemonIpcClient) -> Result<T, DaemonError> + Send + 'static,
{
    let client = daemon_ipc_client()?;
    tauri::async_runtime::spawn_blocking(move || operation(client))
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| error.to_string())
}

fn daemon_program_path() -> Result<PathBuf, String> {
    if let Some(value) = std::env::var_os("CLUMSIES_DAEMON_PROGRAM") {
        return Ok(PathBuf::from(value));
    }
    let current_exe = std::env::current_exe().map_err(|error| error.to_string())?;
    let parent = current_exe
        .parent()
        .ok_or_else(|| "desktop executable path has no parent directory".to_owned())?;
    let bundled = parent.join("clumsiesd");
    if bundled.is_file() {
        return Ok(bundled);
    }

    let target = match (std::env::consts::ARCH, std::env::consts::OS) {
        ("aarch64", "macos") => "aarch64-apple-darwin",
        ("x86_64", "macos") => "x86_64-apple-darwin",
        _ => return Err("clumsiesd is not bundled for this platform".to_owned()),
    };
    let development_binary = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("binaries")
        .join(format!("clumsiesd-{target}"));
    if development_binary.is_file() {
        return Ok(development_binary);
    }
    Err(format!(
        "clumsiesd was not found at {} or {}",
        bundled.display(),
        development_binary.display()
    ))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            lifecycle::setup(app)?;
            Ok(())
        })
        .on_menu_event(lifecycle::handle_menu_event)
        .on_window_event(lifecycle::handle_window_event)
        .invoke_handler(tauri::generate_handler![
            read_daemon_bootstrap_status,
            install_daemon_launch_agent,
            start_daemon_launch_agent,
            restart_daemon_launch_agent,
            stop_daemon_launch_agent,
            read_daemon_health,
            read_daemon_project_config,
            select_daemon_project,
            read_daemon_sync_status,
            retry_daemon_sync,
            read_daemon_mcp_status,
            list_daemon_drafts,
            read_daemon_draft,
            store_daemon_draft_operation,
            proxy_server_request,
            authenticate_desktop,
            present_main_window,
            present_authentication_window
        ])
        .build(tauri::generate_context!())
        .expect("failed to build clumsies desktop");
    app.run(|app, event| lifecycle::handle_run_event(app, &event));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc_7636_example() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(
            pkce_challenge(verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn callback_requires_the_expected_state() {
        assert_eq!(
            parse_callback_target("/callback?code=code_test&state=state_test", "state_test")
                .unwrap(),
            "code_test"
        );
        assert!(
            parse_callback_target("/callback?code=code_test&state=wrong", "state_test")
                .unwrap_err()
                .contains("state")
        );
    }

    #[test]
    fn server_url_rejects_cleartext_remote_hosts() {
        assert_eq!(
            normalize_server_url("http://127.0.0.1:8080/").unwrap(),
            "http://127.0.0.1:8080"
        );
        assert!(normalize_server_url("http://server.example").is_err());
        assert_eq!(
            normalize_server_url("https://server.example/").unwrap(),
            "https://server.example"
        );
    }

    #[test]
    fn desktop_uses_the_clumsies_cloud_server() {
        assert_eq!(DESKTOP_SERVER_URL, "https://app.clumsies.ai");
        assert_eq!(
            normalize_server_url(DESKTOP_SERVER_URL).unwrap(),
            DESKTOP_SERVER_URL
        );
    }
}
