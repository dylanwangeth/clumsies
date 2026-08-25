use axum::Json;
use axum::extract::State;
use axum::http::header::SET_COOKIE;
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use cookie::{Cookie, SameSite};

use crate::api::{
    CreateSetupSessionRequest, ReplaceSetupConfigurationRequest, SetupOidcAuthorization,
    SetupOidcAuthorizationRequest,
};
use crate::http::{AppState, HttpError, cookie_value};

use super::{InstallationError, InstallationService};

pub(crate) async fn get_setup(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::api::SetupStatus>, HttpError> {
    let session_token = setup_session_token(&headers, state.installation.cookie_name());
    Ok(Json(
        state
            .installation
            .status(session_token.as_deref(), state.auth.configured())
            .await?,
    ))
}

pub(crate) async fn create_setup_session(
    State(state): State<AppState>,
    Json(request): Json<CreateSetupSessionRequest>,
) -> Result<Response, HttpError> {
    let credentials = state
        .installation
        .create_session(&request.setup_code)
        .await?;
    let cookie = Cookie::build((
        state.installation.cookie_name().to_owned(),
        credentials.token,
    ))
    .path("/")
    .http_only(true)
    .secure(state.installation.cookie_secure())
    .same_site(SameSite::Strict)
    .max_age(cookie::time::Duration::minutes(15))
    .build();
    let mut response = (StatusCode::CREATED, Json(credentials.session)).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&cookie.to_string())
            .map_err(|_| HttpError::internal("setup cookie contains an invalid value"))?,
    );
    Ok(response)
}

pub(crate) async fn replace_setup_configuration(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ReplaceSetupConfigurationRequest>,
) -> Result<Json<crate::api::SetupConfiguration>, HttpError> {
    let (session_token, csrf_token) = setup_credentials(&state.installation, &headers)?;
    Ok(Json(
        state
            .installation
            .replace_configuration(&session_token, &csrf_token, request)
            .await?,
    ))
}

pub(crate) async fn create_setup_oidc_authorization(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<SetupOidcAuthorizationRequest>,
) -> Result<(StatusCode, Json<SetupOidcAuthorization>), HttpError> {
    let (session_token, csrf_token) = setup_credentials(&state.installation, &headers)?;
    let setup_session_id = state
        .installation
        .authorize_oidc(&session_token, &csrf_token)
        .await?;
    let authorization_url = state
        .auth
        .begin_setup_login(&setup_session_id, &request.redirect_uri)
        .await?;
    Ok((
        StatusCode::CREATED,
        Json(SetupOidcAuthorization { authorization_url }),
    ))
}

fn setup_credentials(
    installation: &InstallationService,
    headers: &HeaderMap,
) -> Result<(String, String), HttpError> {
    let session_token = setup_session_token(headers, installation.cookie_name())
        .ok_or(InstallationError::InvalidSession)?;
    let csrf_token = headers
        .get("x-csrf-token")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .ok_or(InstallationError::CsrfMismatch)?
        .to_owned();
    Ok((session_token, csrf_token))
}

fn setup_session_token(headers: &HeaderMap, cookie_name: &str) -> Option<String> {
    cookie_value(headers, cookie_name)
}
