use axum::extract::{Extension, Path, Query, Request, State};
use axum::http::header::{
    AUTHORIZATION, CACHE_CONTROL, CONTENT_TYPE, COOKIE, ETAG, HOST, IF_MATCH, LOCATION, ORIGIN,
    SET_COOKIE,
};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{delete, get, patch, post, put};
use axum::{Json, Router};
use cookie::{Cookie, SameSite};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;
use subtle::ConstantTimeEq;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::services::{ServeDir, ServeFile};

use crate::api::{
    CreateDraftRequest, CreateMemberRequest, CreateProjectMemberRequest, CreateProjectRequest,
    CreateReviewCommentRequest, CreateReviewConflictResolutionRequest, CreateReviewDecisionRequest,
    CreateReviewMergeRequest, CreateReviewRequest, CreateReviewSubmissionRequest,
    CreateSetupSessionRequest, DraftOperationBatchRequest, DraftOperationInput,
    OidcAuthorizationRequest, OidcCallbackRequest, OrgRole, PersonalBundleRequest,
    PersonalBundleUpdateRequest, ProjectRole, ReplaceProjectOrgSelectionRequest,
    ReplaceSetupConfigurationRequest, ResourceScope, SetupOidcAuthorization,
    SetupOidcAuthorizationRequest, TokenRequest, UpdateAdminOrgRequest, UpdateDraftRequest,
    UpdateMemberRequest, UpdateProjectMemberRequest, UpdateProjectRequest,
};
use crate::auth::{AuthError, AuthPrincipal, AuthService, CredentialKind};
use crate::installation::{InstallationError, InstallationService};
use crate::repository::{ServerError, ServerRepository};

const CURRENT_SCHEMA_MIGRATION: i64 = 20260716000200;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    repository: ServerRepository,
    auth: AuthService,
    installation: InstallationService,
    version: &'static str,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct HttpOperation {
    method: &'static str,
    path: &'static str,
}

macro_rules! define_routes {
    ($function:ident, $operations:ident, {
        $(
            $path:literal => {
                $first_method:ident: $first_handler:ident
                $(, $method:ident: $handler:ident)*
                $(,)?
            };
        )*
    }) => {
        #[cfg(test)]
        const $operations: &[HttpOperation] = &[
            $(
                HttpOperation {
                    method: stringify!($first_method),
                    path: $path,
                },
                $(
                    HttpOperation {
                        method: stringify!($method),
                        path: $path,
                    },
                )*
            )*
        ];

        fn $function() -> Router<AppState> {
            Router::new()
                $(.route($path, $first_method($first_handler)$(.$method($handler))*))*
        }
    };
}

define_routes!(public_routes, PUBLIC_OPERATIONS, {
    "/api/v1/admin/health" => { get: admin_health };
    "/api/v1/setup" => { get: get_setup };
    "/api/v1/setup/sessions" => { post: create_setup_session };
    "/api/v1/setup/configuration" => { put: replace_setup_configuration };
    "/api/v1/setup/oidc-authorizations" => { post: create_setup_oidc_authorization };
    "/oauth2/authorization/oidc" => { get: begin_oidc };
    "/login/oauth2/code/oidc" => { get: complete_oidc };
    "/api/v1/auth/token" => { post: exchange_auth_token };
});

define_routes!(admin_routes, ADMIN_OPERATIONS, {
    "/api/v1/admin/session" => { get: get_admin_session, delete: delete_admin_session };
    "/api/v1/admin/identity-provider" => { get: get_admin_identity_provider };
    "/api/v1/admin/org" => { get: get_admin_org, patch: update_admin_org };
    "/api/v1/admin/members" => {
        get: list_admin_members,
        post: create_admin_member,
    };
    "/api/v1/admin/members/{user_id}" => {
        patch: update_admin_member,
        delete: delete_admin_member,
    };
    "/api/v1/admin/projects" => { get: list_admin_projects, post: create_admin_project };
    "/api/v1/admin/projects/{project_id}" => {
        get: get_admin_project,
        patch: update_admin_project,
        delete: delete_admin_project,
    };
    "/api/v1/admin/projects/{project_id}/members" => {
        get: list_admin_project_members,
        post: create_admin_project_member,
    };
    "/api/v1/admin/projects/{project_id}/members/{user_id}" => {
        patch: update_admin_project_member,
        delete: delete_admin_project_member,
    };
    "/api/v1/admin/tokens" => { get: list_admin_tokens };
    "/api/v1/admin/tokens/{token_id}" => { delete: delete_admin_token };
    "/api/v1/admin/audit-events" => { get: list_admin_audit_events };
});

define_routes!(protected_routes, PROTECTED_OPERATIONS, {
    "/api/v1/auth/session" => { delete: revoke_auth_session };
    "/api/v1/me" => { get: get_me };
    "/api/v1/projects" => { get: list_projects, post: create_project };
    "/api/v1/projects/{project_id}" => {
        get: get_project,
        patch: update_project,
        delete: delete_project,
    };
    "/api/v1/me/bundles" => {
        get: list_personal_bundles,
        post: create_personal_bundle,
    };
    "/api/v1/me/bundles/{bundle_id}" => {
        get: get_personal_bundle,
        patch: update_personal_bundle,
        delete: delete_personal_bundle,
    };
    "/api/v1/org/rules" => { get: list_org_rules };
    "/api/v1/org/rules/{rule_id}" => { get: get_org_rule };
    "/api/v1/org/context" => { get: list_org_context };
    "/api/v1/org/context/{context_id}" => { get: get_org_context };
    "/api/v1/org/workflows" => { get: list_org_workflows };
    "/api/v1/org/workflows/{workflow_id}" => { get: get_org_workflow };
    "/api/v1/org/metaprompt" => { get: get_org_metaprompt };
    "/api/v1/projects/{project_id}/rules" => { get: list_project_rules };
    "/api/v1/projects/{project_id}/rules/{rule_id}" => { get: get_project_rule };
    "/api/v1/projects/{project_id}/context" => { get: list_project_context };
    "/api/v1/projects/{project_id}/context/{context_id}" => { get: get_project_context };
    "/api/v1/projects/{project_id}/workflows" => { get: list_project_workflows };
    "/api/v1/projects/{project_id}/workflows/{workflow_id}" => { get: get_project_workflow };
    "/api/v1/projects/{project_id}/metaprompt" => { get: get_project_metaprompt };
    "/api/v1/projects/{project_id}/org-selections" => {
        get: get_project_org_selection,
        put: replace_project_org_selection,
    };
    "/api/v1/drafts" => { get: list_drafts, post: create_draft };
    "/api/v1/drafts/{draft_id}" => {
        get: get_draft,
        patch: update_draft,
        delete: delete_draft,
    };
    "/api/v1/drafts/{draft_id}/operations" => { post: append_draft_operation };
    "/api/v1/draft-events" => { get: list_draft_events };
    "/api/v1/draft-operation-batches" => { post: create_draft_operation_batch };
    "/api/v1/reviews" => { get: list_reviews, post: create_review };
    "/api/v1/reviews/{review_id}" => { get: get_review };
    "/api/v1/reviews/{review_id}/comments" => {
        get: list_review_comments,
        post: create_review_comment,
    };
    "/api/v1/reviews/{review_id}/decisions" => { post: create_review_decision };
    "/api/v1/reviews/{review_id}/submissions" => { post: create_review_submission };
    "/api/v1/reviews/{review_id}/conflict-resolutions" => {
        post: create_review_conflict_resolution,
    };
    "/api/v1/reviews/{review_id}/merges" => { post: create_review_merge };
    "/api/v1/org/commits" => { get: list_org_commits };
    "/api/v1/org/commit-state" => { get: get_org_commit_state };
    "/api/v1/projects/{project_id}/commits" => { get: list_project_commits };
    "/api/v1/projects/{project_id}/commit-state" => { get: get_project_commit_state };
    "/api/v1/commits/{commit_id}" => { get: get_commit };
});

pub fn router(pool: PgPool) -> Router {
    let auth = AuthService::unconfigured(pool.clone());
    let installation = InstallationService::new(pool.clone(), None, true)
        .expect("an installation service without a setup code is valid");
    router_with_services(pool, auth, installation)
}

pub fn router_with_auth(pool: PgPool, auth: AuthService) -> Router {
    let installation = InstallationService::new(pool.clone(), None, true)
        .expect("an installation service without a setup code is valid");
    router_with_services(pool, auth, installation)
}

pub fn router_with_services(
    pool: PgPool,
    auth: AuthService,
    installation: InstallationService,
) -> Router {
    let state = AppState {
        repository: ServerRepository::new(pool.clone()),
        auth,
        installation,
        pool,
        version: env!("CARGO_PKG_VERSION"),
    };
    let public_routes = public_routes();
    let admin_routes = admin_routes().route_layer(middleware::from_fn_with_state(
        state.clone(),
        require_admin_auth,
    ));
    let protected_routes =
        protected_routes().route_layer(middleware::from_fn_with_state(state.clone(), require_auth));
    let mut router = Router::new()
        .merge(public_routes)
        .merge(admin_routes)
        .merge(protected_routes)
        .route("/setup", get(redirect_to_setup));
    if let Some(directory) = optional_env("CLUMSIES_WEB_ADMIN_DIR") {
        let index = std::path::Path::new(&directory).join("index.html");
        let service = ServeDir::new(directory).fallback(ServeFile::new(index));
        router = router.nest_service("/admin", service);
    }
    router
        .with_state(state)
        .layer(middleware::from_fn(security_headers))
        .layer(cors_layer())
}

async fn redirect_to_setup() -> Redirect {
    Redirect::temporary("/admin/setup")
}

async fn security_headers(request: Request, next: Next) -> Response {
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

fn cors_layer() -> CorsLayer {
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
        .unwrap_or_else(|_| {
            "tauri://localhost,http://tauri.localhost,http://127.0.0.1:1420,http://localhost:1420"
                .to_owned()
        })
        .split(',')
        .map(str::trim)
        .filter(|origin| !origin.is_empty())
        .map(str::to_owned)
        .collect()
}

fn optional_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

async fn begin_oidc(
    State(state): State<AppState>,
    Query(request): Query<OidcAuthorizationRequest>,
) -> Result<Response, HttpError> {
    state.installation.require_initialized().await?;
    redirect_response(state.auth.begin_login(request).await?)
}

async fn complete_oidc(
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

async fn get_setup(
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

async fn create_setup_session(
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

async fn replace_setup_configuration(
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

async fn create_setup_oidc_authorization(
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

async fn exchange_auth_token(
    State(state): State<AppState>,
    Json(request): Json<TokenRequest>,
) -> Result<Json<crate::api::TokenResponse>, HttpError> {
    Ok(Json(state.auth.exchange_token(request).await?))
}

async fn revoke_auth_session(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::SessionRevoked>, HttpError> {
    Ok(Json(state.auth.revoke_session(&principal).await?))
}

async fn get_admin_session(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::WebAdminSession>, HttpError> {
    Ok(Json(state.auth.web_admin_session(&principal).await?))
}

async fn delete_admin_session(
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

async fn get_admin_identity_provider(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::OidcProviderStatus>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(state.auth.provider_status()))
}

async fn require_auth(
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

async fn require_admin_auth(
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

fn cookie_value(headers: &HeaderMap, cookie_name: &str) -> Option<String> {
    headers
        .get_all(COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(Cookie::split_parse)
        .filter_map(Result::ok)
        .find(|cookie| cookie.name() == cookie_name)
        .map(|cookie| cookie.value().to_owned())
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

async fn get_me(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::MeResponse>, HttpError> {
    Ok(Json(state.repository.get_me(&principal).await?))
}

async fn get_admin_org(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::AdminOrg>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state.repository.get_admin_org(&principal.org_id).await?,
    ))
}

async fn update_admin_org(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    headers: HeaderMap,
    Json(request): Json<UpdateAdminOrgRequest>,
) -> Result<Json<crate::api::AdminOrg>, HttpError> {
    require_org_admin(&principal)?;
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_admin_org(&principal, expected_revision, request)
            .await?,
    ))
}

async fn list_admin_members(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<AdminPageQuery>,
) -> Result<Json<crate::api::MemberListResponse>, HttpError> {
    require_org_admin(&principal)?;
    let page = parse_admin_page(query)?;
    Ok(Json(
        state
            .repository
            .list_admin_members(page.offset, page.limit)
            .await?,
    ))
}

async fn create_admin_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateMemberRequest>,
) -> Result<(StatusCode, Json<crate::api::Member>), HttpError> {
    require_org_admin(&principal)?;
    if request.role == OrgRole::Owner && principal.role != "owner" {
        return Err(ServerError::Forbidden(
            "only an organization owner can create another owner".to_owned(),
        )
        .into());
    }
    Ok((
        StatusCode::CREATED,
        Json(
            state
                .repository
                .create_admin_member(&principal, request)
                .await?,
        ),
    ))
}

async fn update_admin_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<UpdateMemberRequest>,
) -> Result<Json<crate::api::Member>, HttpError> {
    require_org_admin(&principal)?;
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_admin_member(&principal, &user_id, expected_revision, request)
            .await?,
    ))
}

async fn delete_admin_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    require_org_admin(&principal)?;
    if user_id == principal.user_id {
        return Err(ServerError::InvalidRequest(
            "the current user cannot disable their own account".to_owned(),
        )
        .into());
    }
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .delete_admin_member(&principal, &user_id, expected_revision)
            .await?,
    ))
}

async fn list_admin_projects(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<AdminPageQuery>,
) -> Result<Json<crate::api::AdminProjectListResponse>, HttpError> {
    require_org_admin(&principal)?;
    let page = parse_admin_page(query)?;
    Ok(Json(
        state
            .repository
            .list_admin_projects(&principal.org_id, page.offset, page.limit)
            .await?,
    ))
}

async fn create_admin_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateProjectRequest>,
) -> Result<(StatusCode, Json<crate::api::AdminProject>), HttpError> {
    require_org_admin(&principal)?;
    Ok((
        StatusCode::CREATED,
        Json(
            state
                .repository
                .create_admin_project(&principal, request)
                .await?,
        ),
    ))
}

async fn get_admin_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::AdminProject>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .get_admin_project(&principal.org_id, &project_id)
            .await?,
    ))
}

async fn update_admin_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<UpdateProjectRequest>,
) -> Result<Json<crate::api::AdminProject>, HttpError> {
    require_org_admin(&principal)?;
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_admin_project(&principal, &project_id, expected_revision, request)
            .await?,
    ))
}

async fn delete_admin_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    require_org_admin(&principal)?;
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .delete_admin_project(&principal, &project_id, expected_revision)
            .await?,
    ))
}

#[derive(Debug, Deserialize)]
struct ListAdminProjectMembersQuery {
    role: Option<String>,
    limit: Option<String>,
    cursor: Option<String>,
}

async fn list_admin_project_members(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    Query(query): Query<ListAdminProjectMembersQuery>,
) -> Result<Json<crate::api::ProjectMemberListResponse>, HttpError> {
    require_org_admin(&principal)?;
    let role = parse_admin_project_role(query.role.as_deref())?;
    let page = parse_admin_page(AdminPageQuery {
        limit: query.limit,
        cursor: query.cursor,
    })?;
    Ok(Json(
        state
            .repository
            .list_admin_project_members(
                &principal.org_id,
                &project_id,
                role,
                page.offset,
                page.limit,
            )
            .await?,
    ))
}

async fn create_admin_project_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    Json(request): Json<CreateProjectMemberRequest>,
) -> Result<(StatusCode, Json<crate::api::ProjectMember>), HttpError> {
    require_org_admin(&principal)?;
    Ok((
        StatusCode::CREATED,
        Json(
            state
                .repository
                .create_admin_project_member(&principal, &project_id, request)
                .await?,
        ),
    ))
}

async fn update_admin_project_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((project_id, user_id)): Path<(String, String)>,
    Json(request): Json<UpdateProjectMemberRequest>,
) -> Result<Json<crate::api::ProjectMember>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .update_admin_project_member(&principal, &project_id, &user_id, request)
            .await?,
    ))
}

async fn delete_admin_project_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((project_id, user_id)): Path<(String, String)>,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .delete_admin_project_member(&principal, &project_id, &user_id)
            .await?,
    ))
}

async fn list_admin_tokens(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<AdminPageQuery>,
) -> Result<Json<crate::api::AccessTokenListResponse>, HttpError> {
    require_org_admin(&principal)?;
    let page = parse_admin_page(query)?;
    Ok(Json(
        state
            .repository
            .list_admin_tokens(&principal.org_id, page.offset, page.limit)
            .await?,
    ))
}

async fn delete_admin_token(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(token_id): Path<String>,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .delete_admin_token(&principal, &token_id)
            .await?,
    ))
}

async fn list_admin_audit_events(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<AdminPageQuery>,
) -> Result<Json<crate::api::AuditEventListResponse>, HttpError> {
    require_org_admin(&principal)?;
    let page = parse_admin_page(query)?;
    Ok(Json(
        state
            .repository
            .list_admin_audit_events(&principal.org_id, page.offset, page.limit)
            .await?,
    ))
}

#[derive(Debug, Deserialize)]
struct AdminPageQuery {
    limit: Option<String>,
    cursor: Option<String>,
}

#[derive(Debug, Clone, Copy)]
struct AdminPage {
    offset: i64,
    limit: i64,
}

fn parse_admin_page(query: AdminPageQuery) -> Result<AdminPage, HttpError> {
    let limit = match query.limit {
        Some(limit) => limit.parse::<i64>().map_err(|_| {
            HttpError::from(ServerError::InvalidRequest(
                "invalid admin page limit".to_owned(),
            ))
        })?,
        None => 50,
    };
    if !(1..=200).contains(&limit) {
        return Err(ServerError::InvalidRequest(
            "admin page limit must be between 1 and 200".to_owned(),
        )
        .into());
    }
    let offset = match query.cursor {
        Some(cursor) => cursor.parse::<i64>().map_err(|_| {
            HttpError::from(ServerError::InvalidRequest(
                "invalid admin page cursor".to_owned(),
            ))
        })?,
        None => 0,
    };
    if offset < 0 {
        return Err(ServerError::InvalidRequest("invalid admin page cursor".to_owned()).into());
    }
    Ok(AdminPage { offset, limit })
}

fn parse_admin_project_role(role: Option<&str>) -> Result<Option<ProjectRole>, HttpError> {
    match role {
        Some("member") => Ok(Some(ProjectRole::Member)),
        Some("admin") => Ok(Some(ProjectRole::Admin)),
        Some(_) => {
            Err(ServerError::InvalidRequest("invalid project role filter".to_owned()).into())
        }
        None => Ok(None),
    }
}

async fn admin_health(State(state): State<AppState>) -> Json<AdminHealth> {
    let database = check_database(&state.pool).await;
    let schema = if database.status == HealthStatus::Ok {
        check_schema(&state.pool).await
    } else {
        dependency_down("schema", "database")
    };
    let commit_service = if schema.status == HealthStatus::Ok {
        implemented_component("commit service")
    } else {
        dependency_down("commit service", "schema")
    };
    let oidc = if state.auth.configured() {
        implemented_component("OIDC")
    } else {
        HealthCheck {
            status: HealthStatus::Down,
            message: "OIDC is not configured".to_owned(),
        }
    };
    let status = overall_status([
        database.status,
        schema.status,
        commit_service.status,
        oidc.status,
    ]);

    Json(AdminHealth {
        status,
        version: state.version.to_owned(),
        database,
        schema,
        commit_service,
        oidc,
    })
}

async fn check_database(pool: &PgPool) -> HealthCheck {
    match sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(pool)
        .await
    {
        Ok(1) => HealthCheck {
            status: HealthStatus::Ok,
            message: "postgres reachable".to_owned(),
        },
        Ok(_) => HealthCheck {
            status: HealthStatus::Down,
            message: "postgres returned an unexpected health value".to_owned(),
        },
        Err(error) => HealthCheck {
            status: HealthStatus::Down,
            message: error.to_string(),
        },
    }
}

async fn check_schema(pool: &PgPool) -> HealthCheck {
    match sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
            SELECT 1
            FROM _sqlx_migrations
            WHERE version = $1 AND success = true
        )",
    )
    .bind(CURRENT_SCHEMA_MIGRATION)
    .fetch_one(pool)
    .await
    {
        Ok(true) => HealthCheck {
            status: HealthStatus::Ok,
            message: format!("migration {CURRENT_SCHEMA_MIGRATION} applied"),
        },
        Ok(false) => HealthCheck {
            status: HealthStatus::Down,
            message: format!("migration {CURRENT_SCHEMA_MIGRATION} is not applied"),
        },
        Err(error) => HealthCheck {
            status: HealthStatus::Down,
            message: error.to_string(),
        },
    }
}

fn implemented_component(name: &str) -> HealthCheck {
    HealthCheck {
        status: HealthStatus::Ok,
        message: format!("{name} ready"),
    }
}

fn dependency_down(name: &str, dependency: &str) -> HealthCheck {
    HealthCheck {
        status: HealthStatus::Down,
        message: format!("{name} check skipped because {dependency} is down"),
    }
}

async fn create_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateProjectRequest>,
) -> Result<Json<crate::api::Project>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .create_project_from_request(&principal, request)
            .await?,
    ))
}

async fn list_projects(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::ProjectListResponse>, HttpError> {
    Ok(Json(state.repository.list_projects(&principal).await?))
}

async fn get_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::Project>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(state.repository.get_project(&project_id).await?))
}

async fn update_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<UpdateProjectRequest>,
) -> Result<Json<crate::api::Project>, HttpError> {
    require_org_admin(&principal)?;
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    let expected_version = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_project(&project_id, expected_version, request)
            .await?,
    ))
}

async fn delete_project(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    require_org_admin(&principal)?;
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    let expected_version = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .delete_project(&project_id, expected_version)
            .await?,
    ))
}

async fn create_draft(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateDraftRequest>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
    if request.resource.scope == ResourceScope::Org {
        require_org_admin(&principal)?;
    }
    state
        .repository
        .ensure_project_member(&principal, &request.project_id)
        .await?;
    Ok(Json(
        state
            .repository
            .create_draft(&principal.user_id, request)
            .await?,
    ))
}

async fn create_personal_bundle(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<PersonalBundleRequest>,
) -> Result<Json<crate::api::PersonalBundleDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .create_personal_bundle(&principal.user_id, request)
            .await?,
    ))
}

async fn list_personal_bundles(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::PersonalBundleListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_personal_bundles(&principal.user_id)
            .await?,
    ))
}

async fn get_personal_bundle(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(bundle_id): Path<String>,
) -> Result<Json<crate::api::PersonalBundleDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_personal_bundle(&principal.user_id, &bundle_id)
            .await?,
    ))
}

async fn update_personal_bundle(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(bundle_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<PersonalBundleUpdateRequest>,
) -> Result<Json<crate::api::PersonalBundleDetail>, HttpError> {
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_personal_bundle(&principal.user_id, &bundle_id, expected_revision, request)
            .await?,
    ))
}

async fn delete_personal_bundle(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(bundle_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .delete_personal_bundle(&principal.user_id, &bundle_id, expected_revision)
            .await?,
    ))
}

async fn list_org_rules(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::RuleListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_org_rules(&principal.org_id).await?,
    ))
}

async fn get_org_rule(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(rule_id): Path<String>,
) -> Result<Json<crate::api::RuleDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_org_rule(&principal.org_id, &rule_id)
            .await?,
    ))
}

async fn list_org_context(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::ContextListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_org_context(&principal.org_id).await?,
    ))
}

async fn get_org_context(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(context_id): Path<String>,
) -> Result<Json<crate::api::ContextDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_org_context(&principal.org_id, &context_id)
            .await?,
    ))
}

async fn list_org_workflows(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::WorkflowListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_org_workflows(&principal.org_id)
            .await?,
    ))
}

async fn get_org_workflow(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(workflow_id): Path<String>,
) -> Result<Json<crate::api::WorkflowDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_org_workflow(&principal.org_id, &workflow_id)
            .await?,
    ))
}

async fn get_org_metaprompt(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::MetapromptDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_org_metaprompt(&principal.org_id)
            .await?,
    ))
}

async fn list_project_rules(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::RuleListResponse>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state.repository.list_project_rules(&project_id).await?,
    ))
}

async fn get_project_rule(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((project_id, rule_id)): Path<(String, String)>,
) -> Result<Json<crate::api::RuleDetail>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state
            .repository
            .get_project_rule(&project_id, &rule_id)
            .await?,
    ))
}

async fn list_project_context(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::ContextListResponse>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state.repository.list_project_context(&project_id).await?,
    ))
}

async fn get_project_context(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((project_id, context_id)): Path<(String, String)>,
) -> Result<Json<crate::api::ContextDetail>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state
            .repository
            .get_project_context(&project_id, &context_id)
            .await?,
    ))
}

async fn list_project_workflows(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::WorkflowListResponse>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state.repository.list_project_workflows(&project_id).await?,
    ))
}

async fn get_project_workflow(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((project_id, workflow_id)): Path<(String, String)>,
) -> Result<Json<crate::api::WorkflowDetail>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state
            .repository
            .get_project_workflow(&project_id, &workflow_id)
            .await?,
    ))
}

async fn get_project_metaprompt(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::MetapromptDetail>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state.repository.get_project_metaprompt(&project_id).await?,
    ))
}

async fn get_project_org_selection(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::ProjectOrgSelection>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state
            .repository
            .get_project_org_selection(&project_id)
            .await?,
    ))
}

async fn replace_project_org_selection(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<ReplaceProjectOrgSelectionRequest>,
) -> Result<Json<crate::api::ProjectOrgSelection>, HttpError> {
    require_org_admin(&principal)?;
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .replace_project_org_selection(&project_id, expected_revision, request)
            .await?,
    ))
}

#[derive(Deserialize)]
struct ListDraftsQuery {
    project_id: Option<String>,
}

async fn list_drafts(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<ListDraftsQuery>,
) -> Result<Json<crate::api::DraftListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_drafts(&principal.user_id, query.project_id.as_deref())
            .await?,
    ))
}

async fn get_draft(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(draft_id): Path<String>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    Ok(Json(state.repository.get_draft(&draft_id).await?))
}

async fn update_draft(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(draft_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<UpdateDraftRequest>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    let expected_version = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_draft(&draft_id, expected_version, request)
            .await?,
    ))
}

async fn delete_draft(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(draft_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    let expected_version = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .discard_draft(&draft_id, expected_version)
            .await?,
    ))
}

async fn append_draft_operation(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(draft_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<DraftOperationInput>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    let expected_version = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .append_draft_operation(&draft_id, expected_version, request)
            .await?,
    ))
}

#[derive(Deserialize)]
struct ListDraftEventsQuery {
    after_cursor: Option<String>,
    limit: Option<i64>,
}

async fn list_draft_events(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<ListDraftEventsQuery>,
) -> Result<Json<crate::api::DraftEventListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_draft_events(
                &principal.user_id,
                query.after_cursor.as_deref(),
                query.limit,
            )
            .await?,
    ))
}

async fn create_draft_operation_batch(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<DraftOperationBatchRequest>,
) -> Result<Json<crate::api::DraftOperationBatchResponse>, HttpError> {
    for operation in &request.operations {
        state
            .repository
            .ensure_draft_owner(&principal, &operation.draft_id)
            .await?;
    }
    Ok(Json(
        state
            .repository
            .create_draft_operation_batch(request)
            .await?,
    ))
}

async fn create_review(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateReviewRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &request.draft_id)
        .await?;
    Ok(Json(state.repository.create_review(request).await?))
}

#[derive(Deserialize)]
struct ListReviewsQuery {
    project_id: Option<String>,
}

async fn list_reviews(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<ListReviewsQuery>,
) -> Result<Json<crate::api::ReviewListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_reviews(&principal, query.project_id.as_deref())
            .await?,
    ))
}

async fn get_review(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    Ok(Json(state.repository.get_review_detail(&review_id).await?))
}

async fn list_review_comments(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
) -> Result<Json<crate::api::ReviewCommentListResponse>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    Ok(Json(
        state.repository.list_review_comments(&review_id).await?,
    ))
}

async fn create_review_comment(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    Json(request): Json<CreateReviewCommentRequest>,
) -> Result<Json<crate::api::ReviewComment>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    Ok(Json(
        state
            .repository
            .create_review_comment(&review_id, &principal.user_id, request)
            .await?,
    ))
}

async fn create_review_decision(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    Json(request): Json<CreateReviewDecisionRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    Ok(Json(
        state
            .repository
            .create_review_decision(&review_id, request)
            .await?,
    ))
}

async fn create_review_submission(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    Json(request): Json<CreateReviewSubmissionRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    Ok(Json(
        state
            .repository
            .create_review_submission(&review_id, &principal.user_id, request)
            .await?,
    ))
}

async fn create_review_merge(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<CreateReviewMergeRequest>,
) -> Result<Json<crate::api::ReviewMergeResult>, HttpError> {
    require_org_admin(&principal)?;
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    let expected_ref = parse_ref_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .create_review_merge(&review_id, expected_ref.as_deref(), request)
            .await?,
    ))
}

async fn create_review_conflict_resolution(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<CreateReviewConflictResolutionRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    let expected_ref = parse_ref_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .create_review_conflict_resolution(
                &review_id,
                &principal.user_id,
                expected_ref.as_deref(),
                request,
            )
            .await?,
    ))
}

async fn list_project_commits(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::CommitListResponse>, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    Ok(Json(
        state.repository.list_project_commits(&project_id).await?,
    ))
}

#[derive(Deserialize)]
struct CommitStateQuery {
    local_commit_id: Option<String>,
}

async fn get_project_commit_state(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    Query(query): Query<CommitStateQuery>,
) -> Result<Response, HttpError> {
    state
        .repository
        .ensure_project_member(&principal, &project_id)
        .await?;
    let commit_state = state
        .repository
        .get_project_commit_state(&project_id, query.local_commit_id.as_deref())
        .await?;
    let mut response = Json(commit_state.clone()).into_response();
    let etag = ref_etag(commit_state.reference.commit_id.as_deref());
    response.headers_mut().insert(
        ETAG,
        HeaderValue::from_str(&etag)
            .map_err(|_| HttpError::bad_request("ref produced an invalid ETag"))?,
    );
    Ok(response)
}

async fn list_org_commits(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<crate::api::CommitListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_org_commits(&principal.org_id).await?,
    ))
}

async fn get_org_commit_state(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(query): Query<CommitStateQuery>,
) -> Result<Response, HttpError> {
    let commit_state = state
        .repository
        .get_org_commit_state(&principal.org_id, query.local_commit_id.as_deref())
        .await?;
    let mut response = Json(commit_state.clone()).into_response();
    let etag = ref_etag(commit_state.reference.commit_id.as_deref());
    response.headers_mut().insert(
        ETAG,
        HeaderValue::from_str(&etag)
            .map_err(|_| HttpError::bad_request("ref produced an invalid ETag"))?,
    );
    Ok(response)
}

async fn get_commit(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(commit_id): Path<String>,
) -> Result<Json<crate::api::CommitPayload>, HttpError> {
    state
        .repository
        .ensure_commit_access(&principal, &commit_id)
        .await?;
    Ok(Json(state.repository.get_commit_payload(&commit_id).await?))
}

fn require_org_admin(principal: &AuthPrincipal) -> Result<(), HttpError> {
    if principal.role == "owner" || principal.role == "admin" {
        Ok(())
    } else {
        Err(ServerError::Forbidden("organization administrator role required".to_owned()).into())
    }
}

fn parse_if_match(headers: &HeaderMap) -> Result<i64, HttpError> {
    let value = headers
        .get("if-match")
        .ok_or_else(|| HttpError::bad_request("missing If-Match header"))?
        .to_str()
        .map_err(|_| HttpError::bad_request("If-Match must be valid UTF-8"))?;
    let value = value.trim().trim_matches('"');
    value
        .parse::<i64>()
        .map_err(|_| HttpError::bad_request("If-Match must be an integer version"))
}

fn parse_ref_if_match(headers: &HeaderMap) -> Result<Option<String>, HttpError> {
    let value = headers
        .get("if-match")
        .ok_or_else(|| HttpError::bad_request("missing If-Match header"))?
        .to_str()
        .map_err(|_| HttpError::bad_request("If-Match must be valid UTF-8"))?
        .trim();
    if value.starts_with("W/") {
        return Err(HttpError::bad_request("ref If-Match must be a strong ETag"));
    }
    if value.len() < 2 || !value.starts_with('"') || !value.ends_with('"') {
        return Err(HttpError::bad_request("ref If-Match must be a quoted ETag"));
    }
    let opaque_tag = &value[1..value.len() - 1];
    match opaque_tag {
        "ref-none" => Ok(None),
        value if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) => {
            Ok(Some(value.to_owned()))
        }
        _ => Err(HttpError::bad_request(
            "ref If-Match contains an invalid commit ID",
        )),
    }
}

fn ref_etag(commit_id: Option<&str>) -> String {
    format!("\"{}\"", commit_id.unwrap_or("ref-none"))
}

enum HttpError {
    Server(ServerError),
    Auth(AuthError),
    Installation(InstallationError),
    Internal(String),
}

impl HttpError {
    fn bad_request(message: &str) -> Self {
        Self::Server(ServerError::InvalidRequest(message.to_owned()))
    }

    fn internal(message: &str) -> Self {
        Self::Internal(message.to_owned())
    }

    fn forbidden(message: &str) -> Self {
        Self::Server(ServerError::Forbidden(message.to_owned()))
    }
}

impl From<ServerError> for HttpError {
    fn from(error: ServerError) -> Self {
        Self::Server(error)
    }
}

impl From<AuthError> for HttpError {
    fn from(error: AuthError) -> Self {
        Self::Auth(error)
    }
}

impl From<InstallationError> for HttpError {
    fn from(error: InstallationError) -> Self {
        Self::Installation(error)
    }
}

impl IntoResponse for HttpError {
    fn into_response(self) -> Response {
        let (status, code, message, details) = match self {
            Self::Server(error) => {
                let status = match &error {
                    ServerError::Forbidden(_) => StatusCode::FORBIDDEN,
                    ServerError::NotFound { .. } => StatusCode::NOT_FOUND,
                    ServerError::AlreadyExists { .. }
                    | ServerError::VersionConflict { .. }
                    | ServerError::DraftConflict { .. } => StatusCode::CONFLICT,
                    ServerError::PreconditionFailed { .. } => StatusCode::PRECONDITION_FAILED,
                    ServerError::InvalidTransition { .. } | ServerError::InvalidRequest(_) => {
                        StatusCode::BAD_REQUEST
                    }
                    ServerError::Sqlx(_) => StatusCode::INTERNAL_SERVER_ERROR,
                };
                let code = match &error {
                    ServerError::Forbidden(_) => "forbidden",
                    ServerError::NotFound { .. } => "not_found",
                    ServerError::AlreadyExists { .. } => "already_exists",
                    ServerError::VersionConflict { .. } => "version_conflict",
                    ServerError::PreconditionFailed { .. } => "precondition_failed",
                    ServerError::DraftConflict { .. } => "draft_conflict",
                    ServerError::InvalidTransition { .. } | ServerError::InvalidRequest(_) => {
                        "invalid_request"
                    }
                    ServerError::Sqlx(_) => "internal_error",
                };
                let details = match &error {
                    ServerError::VersionConflict {
                        entity,
                        expected,
                        actual,
                    } => json!({
                        "entity": entity,
                        "expected_version": expected,
                        "actual_version": actual,
                    }),
                    ServerError::PreconditionFailed { expected, actual } => json!({
                        "expected_commit_id": expected,
                        "current_commit_id": actual,
                    }),
                    ServerError::DraftConflict {
                        review_id,
                        draft_id,
                        scope,
                        base_commit_id,
                        current_commit_id,
                    } => json!({
                        "review_id": review_id,
                        "draft_id": draft_id,
                        "scope": scope.as_str(),
                        "base_commit_id": base_commit_id,
                        "current_commit_id": current_commit_id,
                    }),
                    _ => json!({}),
                };
                (status, code, error.to_string(), details)
            }
            Self::Auth(error) => {
                let status = match &error {
                    AuthError::Unauthorized => StatusCode::UNAUTHORIZED,
                    AuthError::MemberNotAllowed
                    | AuthError::AdminAccessRequired
                    | AuthError::DomainNotAllowed
                    | AuthError::ProviderIdentityConflict => StatusCode::FORBIDDEN,
                    AuthError::NotConfigured | AuthError::ProviderUnavailable(_) => {
                        StatusCode::SERVICE_UNAVAILABLE
                    }
                    AuthError::Configuration(_)
                    | AuthError::CorruptWebSession
                    | AuthError::Sqlx(_) => StatusCode::INTERNAL_SERVER_ERROR,
                    AuthError::Installation(error) => installation_error_status(error),
                    _ => StatusCode::BAD_REQUEST,
                };
                (status, error.code(), error.to_string(), json!({}))
            }
            Self::Installation(error) => (
                installation_error_status(&error),
                error.code(),
                error.to_string(),
                json!({}),
            ),
            Self::Internal(message) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                message,
                json!({}),
            ),
        };
        let request_id = format!("req_{}", uuid::Uuid::new_v4().simple());
        let mut response = (
            status,
            Json(json!({
                "error": {
                    "code": code,
                    "message": message,
                    "request_id": request_id,
                    "details": details
                }
            })),
        )
            .into_response();
        if let Ok(value) = HeaderValue::from_str(&request_id) {
            response
                .headers_mut()
                .insert(HeaderName::from_static("x-request-id"), value);
        }
        response
    }
}

fn installation_error_status(error: &InstallationError) -> StatusCode {
    match error {
        InstallationError::SetupRequired | InstallationError::Locked => StatusCode::CONFLICT,
        InstallationError::SetupUnavailable => StatusCode::SERVICE_UNAVAILABLE,
        InstallationError::InvalidSetupCode | InstallationError::InvalidSession => {
            StatusCode::UNAUTHORIZED
        }
        InstallationError::CsrfMismatch | InstallationError::OwnerDomainNotAllowed => {
            StatusCode::FORBIDDEN
        }
        InstallationError::ConfigurationRequired
        | InstallationError::InvalidOwnerIdentity
        | InstallationError::InvalidRequest(_) => StatusCode::BAD_REQUEST,
        InstallationError::Configuration(_)
        | InstallationError::CorruptSession
        | InstallationError::CorruptInstallation
        | InstallationError::Sqlx(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

fn overall_status(statuses: impl IntoIterator<Item = HealthStatus>) -> HealthStatus {
    let mut has_degraded = false;
    for status in statuses {
        match status {
            HealthStatus::Ok => {}
            HealthStatus::Degraded => has_degraded = true,
            HealthStatus::Down => return HealthStatus::Down,
        }
    }
    if has_degraded {
        HealthStatus::Degraded
    } else {
        HealthStatus::Ok
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdminHealth {
    pub status: HealthStatus,
    pub version: String,
    pub database: HealthCheck,
    pub schema: HealthCheck,
    pub commit_service: HealthCheck,
    pub oidc: HealthCheck,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HealthStatus {
    Ok,
    Degraded,
    Down,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct HealthCheck {
    pub status: HealthStatus,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::time::Duration;

    use axum::body::{Body, to_bytes};
    use axum::http::{Request, StatusCode};
    use serde::Deserialize;
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt;

    use crate::http::{
        ADMIN_OPERATIONS, AdminHealth, HealthStatus, PROTECTED_OPERATIONS, PUBLIC_OPERATIONS,
        router,
    };

    #[derive(Debug, Deserialize)]
    struct OpenApiDocument {
        paths: BTreeMap<String, BTreeMap<String, serde_yaml_ng::Value>>,
    }

    #[test]
    fn axum_routes_match_public_and_admin_openapi() {
        let public = include_str!("../../../packages/api-contract/openapi/clumsies.public.v1.yaml");
        let admin = include_str!("../../../packages/api-contract/openapi/clumsies.admin.v1.yaml");
        let contract_operations = openapi_operations(public)
            .into_iter()
            .chain(openapi_operations(admin))
            .collect::<BTreeSet<_>>();
        let server_operations = PUBLIC_OPERATIONS
            .iter()
            .chain(ADMIN_OPERATIONS)
            .chain(PROTECTED_OPERATIONS)
            .map(|operation| (operation.method.to_owned(), operation.path.to_owned()))
            .collect::<BTreeSet<_>>();

        assert_eq!(server_operations, contract_operations);
    }

    #[tokio::test]
    async fn admin_health_matches_contract_shape_when_database_is_down() {
        let pool = PgPoolOptions::new()
            .acquire_timeout(Duration::from_millis(100))
            .connect_lazy("postgres://clumsies:clumsies@127.0.0.1:1/clumsies")
            .unwrap();
        let app = router(pool);
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/admin/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let health: AdminHealth = serde_json::from_slice(&body).unwrap();
        assert_eq!(health.status, HealthStatus::Down);
        assert_eq!(health.database.status, HealthStatus::Down);
        assert_eq!(health.schema.status, HealthStatus::Down);
        assert_eq!(health.commit_service.status, HealthStatus::Down);
        assert_eq!(health.oidc.status, HealthStatus::Down);
    }

    fn openapi_operations(source: &str) -> BTreeSet<(String, String)> {
        const HTTP_METHODS: [&str; 8] = [
            "get", "put", "post", "delete", "options", "head", "patch", "trace",
        ];
        let document: OpenApiDocument = serde_yaml_ng::from_str(source).unwrap();
        document
            .paths
            .into_iter()
            .flat_map(|(path, item)| {
                item.into_keys()
                    .filter(|method| HTTP_METHODS.contains(&method.as_str()))
                    .map(move |method| (method, path.clone()))
            })
            .collect()
    }
}
