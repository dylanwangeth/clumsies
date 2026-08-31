use axum::Json;
use axum::extract::{Extension, Query, State};
use axum::http::header::{CACHE_CONTROL, LOCATION};
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::api::{OidcAuthorizationRequest, OidcCallbackRequest, TokenRequest};
use crate::http::{AppState, HttpError, require_org_admin};

use super::AuthPrincipal;

pub(crate) async fn begin_oidc(
    State(state): State<AppState>,
    Query(request): Query<OidcAuthorizationRequest>,
) -> Result<Response, HttpError> {
    state.installation.require_initialized().await?;
    redirect_response(state.auth.begin_login(request).await?)
}

pub(crate) async fn complete_oidc(
    State(state): State<AppState>,
    Query(request): Query<OidcCallbackRequest>,
) -> Result<Response, HttpError> {
    let redirect_uri = state
        .auth
        .complete_login(request, &state.installation)
        .await?;
    redirect_response(redirect_uri)
}

pub(crate) async fn exchange_auth_token(
    State(state): State<AppState>,
    Json(request): Json<TokenRequest>,
) -> Result<Json<crate::api::TokenResponse>, HttpError> {
    Ok(Json(state.auth.exchange_token(request).await?))
}

pub(crate) async fn revoke_auth_session(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::SessionRevoked>, HttpError> {
    Ok(Json(state.auth.revoke_session(&principal).await?))
}

pub(crate) async fn get_admin_identity_provider(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::OidcProviderStatus>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(state.auth.provider_status()))
}

fn redirect_response(location: String) -> Result<Response, HttpError> {
    let location = HeaderValue::from_str(&location)
        .map_err(|_| HttpError::bad_request("redirect URL produced an invalid Location header"))?;
    Ok((
        StatusCode::FOUND,
        [
            (LOCATION, location),
            (CACHE_CONTROL, HeaderValue::from_static("no-store")),
        ],
    )
        .into_response())
}

pub(crate) async fn get_me(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::MeResponse>, HttpError> {
    Ok(Json(state.repository.get_me(&principal).await?))
}
