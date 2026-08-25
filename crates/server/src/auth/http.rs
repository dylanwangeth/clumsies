use axum::Json;
use axum::extract::{Extension, Query, State};
use axum::http::header::{CACHE_CONTROL, LOCATION, SET_COOKIE};
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use cookie::{Cookie, SameSite};

use crate::api::{OidcAuthorizationRequest, OidcCallbackRequest, TokenRequest};
use crate::http::{AppState, HttpError, require_org_admin};

use super::{AuthError, AuthPrincipal, AuthService, CredentialKind};

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
    let completion = state
        .auth
        .complete_login(request, &state.installation)
        .await?;
    let mut response = redirect_response(completion.redirect_uri)?;
    if let Some(token) = completion.web_session_token {
        let cookie = admin_session_cookie(&state.auth, token, false);
        response.headers_mut().insert(
            SET_COOKIE,
            HeaderValue::from_str(&cookie.to_string())
                .map_err(|_| HttpError::internal("admin cookie contains an invalid value"))?,
        );
    }
    Ok(response)
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

pub(crate) async fn get_admin_session(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::WebAdminSession>, HttpError> {
    Ok(Json(state.auth.web_admin_session(&principal).await?))
}

pub(crate) async fn delete_admin_session(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Response, HttpError> {
    if principal.credential_kind != CredentialKind::WebSession {
        return Err(AuthError::Unauthorized.into());
    }
    let revoked = state.auth.revoke_session(&principal).await?;
    let cookie = admin_session_cookie(&state.auth, String::new(), true);
    let mut response = Json(revoked).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&cookie.to_string())
            .map_err(|_| HttpError::internal("admin cookie contains an invalid value"))?,
    );
    Ok(response)
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

fn admin_session_cookie(auth: &AuthService, token: String, clear: bool) -> Cookie<'static> {
    let mut builder = Cookie::build((auth.admin_cookie_name().to_owned(), token))
        .path("/")
        .http_only(true)
        .secure(auth.admin_cookie_secure())
        .same_site(SameSite::Lax);
    builder = if clear {
        builder.max_age(cookie::time::Duration::ZERO)
    } else {
        builder.max_age(cookie::time::Duration::seconds(
            auth.web_session_ttl_seconds(),
        ))
    };
    builder.build()
}

pub(crate) async fn get_me(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::MeResponse>, HttpError> {
    Ok(Json(state.repository.get_me(&principal).await?))
}
