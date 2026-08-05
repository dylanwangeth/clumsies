use std::collections::BTreeMap;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::json;
use sqlx::{Row, SqlitePool};

use crate::DaemonError;
use crate::DaemonServerResponse;
use crate::DaemonState;
use crate::ServerTokenRefreshResponse;

pub(crate) async fn post_server_json<T, R>(
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

pub(crate) async fn get_server_json<R>(state: &DaemonState, path: &str) -> Result<R, DaemonError>
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

pub(crate) async fn delete_server_json(
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

pub(crate) async fn execute_authenticated_server_request(
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
    crate::replace_server_credentials(
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
    crate::replace_server_credentials(state.inner.credential_store.clone(), None).await?;
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

pub(crate) async fn decode_server_json<R>(response: reqwest::Response) -> Result<R, DaemonError>
where
    R: DeserializeOwned,
{
    let response = ensure_server_success(response).await?;
    Ok(response.json::<R>().await?)
}

pub(crate) async fn ensure_server_success(
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

pub(crate) fn validate_server_proxy_path(path: &str) -> Result<(), DaemonError> {
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

pub(crate) fn filter_proxy_request_headers(
    headers: BTreeMap<String, String>,
) -> BTreeMap<String, String> {
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

pub(crate) fn filter_proxy_response_headers(
    headers: &reqwest::header::HeaderMap,
) -> BTreeMap<String, String> {
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

pub(crate) fn is_retryable_http_status(status: u16) -> bool {
    status == 408 || status == 429 || status >= 500
}

pub(crate) async fn save_cached_server_response(
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

pub(crate) async fn load_cached_server_response(
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

pub(crate) async fn clear_server_response_cache(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query("DELETE FROM server_response_cache")
        .execute(pool)
        .await?;
    Ok(())
}
