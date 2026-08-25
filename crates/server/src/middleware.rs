use axum::extract::{Request, State};
use axum::http::header::{AUTHORIZATION, CONTENT_TYPE, COOKIE, ETAG, HOST, IF_MATCH, ORIGIN};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method};
use axum::middleware::Next;
use axum::response::Response;
use cookie::Cookie;
use subtle::ConstantTimeEq;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::auth::{AuthError, AuthPrincipal, CredentialKind};
use crate::http::{AppState, HttpError, require_org_admin};

pub(crate) async fn security_headers(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    for (name, value) in [
        (
            "content-security-policy",
            "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: https:; connect-src 'self'",
        ),
        ("referrer-policy", "no-referrer"),
        ("x-content-type-options", "nosniff"),
        ("x-frame-options", "DENY"),
        (
            "permissions-policy",
            "camera=(), microphone=(), geolocation=()",
        ),
    ] {
        response.headers_mut().insert(
            HeaderName::from_static(name),
            HeaderValue::from_static(value),
        );
    }
    response
}

pub(crate) fn cors_layer() -> CorsLayer {
    let origins = configured_cors_origins()
        .into_iter()
        .filter_map(|origin| origin.parse::<HeaderValue>().ok())
        .collect::<Vec<_>>();
    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
        ])
        .allow_headers([
            AUTHORIZATION,
            CONTENT_TYPE,
            IF_MATCH,
            HeaderName::from_static("x-csrf-token"),
        ])
        .expose_headers([ETAG, HeaderName::from_static("x-request-id")])
        .allow_credentials(true)
}

fn configured_cors_origins() -> Vec<String> {
    std::env::var("CLUMSIES_CORS_ORIGINS")
        .unwrap_or_else(|_| "http://127.0.0.1:1421,http://localhost:1421".to_owned())
        .split(',')
        .map(str::trim)
        .filter(|origin| !origin.is_empty())
        .map(str::to_owned)
        .collect()
}

pub(crate) async fn require_auth(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response, HttpError> {
    let bearer_token = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
        .ok_or(AuthError::Unauthorized)?;
    let principal = state.auth.authenticate(bearer_token).await?;
    request.extensions_mut().insert(principal);
    Ok(next.run(request).await)
}

pub(crate) async fn require_admin_auth(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response, HttpError> {
    let bearer_token = bearer_token(request.headers());
    let principal = match bearer_token {
        Some(token) => state.auth.authenticate(token).await?,
        None => {
            let token = cookie_value(request.headers(), state.auth.admin_cookie_name())
                .ok_or(AuthError::Unauthorized)?;
            state.auth.authenticate_web_session(&token).await?
        }
    };
    require_org_admin(&principal)?;
    if principal.credential_kind == CredentialKind::WebSession
        && !matches!(
            *request.method(),
            Method::GET | Method::HEAD | Method::OPTIONS
        )
    {
        validate_admin_csrf(request.headers(), &principal)?;
        validate_admin_origin(request.headers())?;
    }
    request.extensions_mut().insert(principal);
    Ok(next.run(request).await)
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
}

fn validate_admin_csrf(headers: &HeaderMap, principal: &AuthPrincipal) -> Result<(), HttpError> {
    let expected = principal
        .csrf_token
        .as_deref()
        .ok_or_else(|| HttpError::forbidden("Web Admin session has no CSRF binding"))?;
    let actual = headers
        .get("x-csrf-token")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| HttpError::forbidden("X-CSRF-Token is required"))?;
    if expected.len() == actual.len()
        && expected.as_bytes().ct_eq(actual.as_bytes()).unwrap_u8() == 1
    {
        Ok(())
    } else {
        Err(HttpError::forbidden(
            "X-CSRF-Token does not match this session",
        ))
    }
}

fn validate_admin_origin(headers: &HeaderMap) -> Result<(), HttpError> {
    let origin = headers
        .get(ORIGIN)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| HttpError::forbidden("Origin is required for Web Admin mutations"))?;
    if configured_cors_origins()
        .iter()
        .any(|allowed| allowed == origin)
    {
        return Ok(());
    }
    let origin_url =
        url::Url::parse(origin).map_err(|_| HttpError::forbidden("Origin is not trusted"))?;
    let request_host = headers
        .get("x-forwarded-host")
        .or_else(|| headers.get(HOST))
        .and_then(|value| value.to_str().ok());
    let forwarded_proto = headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok());
    let authority_matches = request_host.is_some_and(|host| {
        origin_url
            .host_str()
            .map(|origin_host| {
                let origin_authority = match origin_url.port() {
                    Some(port) => format!("{origin_host}:{port}"),
                    None => origin_host.to_owned(),
                };
                origin_authority.eq_ignore_ascii_case(host)
            })
            .unwrap_or(false)
    });
    let protocol_matches = forwarded_proto
        .map(|protocol| protocol.eq_ignore_ascii_case(origin_url.scheme()))
        .unwrap_or(true);
    if authority_matches && protocol_matches {
        Ok(())
    } else {
        Err(HttpError::forbidden("Origin is not trusted"))
    }
}

pub(crate) fn cookie_value(headers: &HeaderMap, cookie_name: &str) -> Option<String> {
    headers
        .get_all(COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(Cookie::split_parse)
        .filter_map(Result::ok)
        .find(|cookie| cookie.name() == cookie_name)
        .map(|cookie| cookie.value().to_owned())
}
