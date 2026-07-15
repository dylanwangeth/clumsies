use axum::extract::{Extension, Path, Query, Request, State};
use axum::http::header::{AUTHORIZATION, CACHE_CONTROL, CONTENT_TYPE, ETAG, IF_MATCH, LOCATION};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::api::{
    CreateDraftRequest, CreateMemberRequest, CreateProjectMemberRequest, CreateProjectRequest,
    CreateReviewCommentRequest, CreateReviewDecisionRequest, CreateReviewMergeRequest,
    CreateReviewRequest, DraftOperationBatchRequest, DraftOperationInput, OidcAuthorizationRequest,
    OidcCallbackRequest, OrgRole, PersonalBundleRequest, PersonalBundleUpdateRequest, ProjectRole,
    ReplaceProjectOrgSelectionRequest, ResourceScope, TokenRequest, UpdateAdminOrgRequest,
    UpdateDraftRequest, UpdateMemberRequest, UpdateProjectMemberRequest, UpdateProjectRequest,
};
use crate::auth::{AuthError, AuthPrincipal, AuthService};
use crate::repository::{ServerError, ServerRepository};

const CURRENT_SCHEMA_MIGRATION: i64 = 20260714000100;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    repository: ServerRepository,
    auth: AuthService,
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
    "/oauth2/authorization/oidc" => { get: begin_oidc };
    "/login/oauth2/code/oidc" => { get: complete_oidc };
    "/api/v1/auth/token" => { post: exchange_auth_token };
});

define_routes!(protected_routes, PROTECTED_OPERATIONS, {
    "/api/v1/auth/session" => { delete: revoke_auth_session };
    "/api/v1/admin/org" => { get: get_admin_org, patch: update_admin_org };
    "/api/v1/admin/members" => {
        get: list_admin_members,
        post: create_admin_member,
    };
    "/api/v1/admin/members/{user_id}" => {
        patch: update_admin_member,
        delete: delete_admin_member,
    };
    "/api/v1/admin/projects" => { get: list_admin_projects };
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
    "/api/v1/reviews/{review_id}/merges" => { post: create_review_merge };
    "/api/v1/org/commits" => { get: list_org_commits };
    "/api/v1/org/commit-state" => { get: get_org_commit_state };
    "/api/v1/projects/{project_id}/commits" => { get: list_project_commits };
    "/api/v1/projects/{project_id}/commit-state" => { get: get_project_commit_state };
    "/api/v1/commits/{commit_id}" => { get: get_commit };
});

pub fn router(pool: PgPool) -> Router {
    let auth = AuthService::unconfigured(pool.clone());
    router_with_auth(pool, auth)
}

pub fn router_with_auth(pool: PgPool, auth: AuthService) -> Router {
    let state = AppState {
        repository: ServerRepository::new(pool.clone()),
        auth,
        pool,
        version: env!("CARGO_PKG_VERSION"),
    };
    let public_routes = public_routes();
    let protected_routes =
        protected_routes().route_layer(middleware::from_fn_with_state(state.clone(), require_auth));
    Router::new()
        .merge(public_routes)
        .merge(protected_routes)
        .with_state(state)
        .layer(cors_layer())
}

fn cors_layer() -> CorsLayer {
    let configured = std::env::var("CLUMSIES_CORS_ORIGINS").unwrap_or_else(|_| {
        "tauri://localhost,http://tauri.localhost,http://127.0.0.1:1420,http://localhost:1420"
            .to_owned()
    });
    let origins = configured
        .split(',')
        .filter_map(|origin| origin.trim().parse::<HeaderValue>().ok())
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
        .allow_headers([AUTHORIZATION, CONTENT_TYPE, IF_MATCH])
        .expose_headers([ETAG, HeaderName::from_static("x-request-id")])
}

async fn begin_oidc(
    State(state): State<AppState>,
    Query(request): Query<OidcAuthorizationRequest>,
) -> Result<Response, HttpError> {
    redirect_response(state.auth.begin_login(request).await?)
}

async fn complete_oidc(
    State(state): State<AppState>,
    Query(request): Query<OidcCallbackRequest>,
) -> Result<Response, HttpError> {
    redirect_response(state.auth.complete_login(request).await?)
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
) -> Result<Json<crate::api::MemberListResponse>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(state.repository.list_admin_members().await?))
}

async fn create_admin_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateMemberRequest>,
) -> Result<Json<crate::api::Member>, HttpError> {
    require_org_admin(&principal)?;
    if request.role == OrgRole::Owner && principal.role != "owner" {
        return Err(ServerError::Forbidden(
            "only an organization owner can create another owner".to_owned(),
        )
        .into());
    }
    Ok(Json(
        state
            .repository
            .create_admin_member(&principal, request)
            .await?,
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
) -> Result<Json<crate::api::AdminProjectListResponse>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .list_admin_projects(&principal.org_id)
            .await?,
    ))
}

#[derive(Debug, Deserialize)]
struct ListAdminProjectMembersQuery {
    role: Option<ProjectRole>,
}

async fn list_admin_project_members(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    Query(query): Query<ListAdminProjectMembersQuery>,
) -> Result<Json<crate::api::ProjectMemberListResponse>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .list_admin_project_members(&principal.org_id, &project_id, query.role)
            .await?,
    ))
}

async fn create_admin_project_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(project_id): Path<String>,
    Json(request): Json<CreateProjectMemberRequest>,
) -> Result<Json<crate::api::ProjectMember>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .create_admin_project_member(&principal, &project_id, request)
            .await?,
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
) -> Result<Json<crate::api::AccessTokenListResponse>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .list_admin_tokens(&principal.org_id)
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
) -> Result<Json<crate::api::AuditEventListResponse>, HttpError> {
    require_org_admin(&principal)?;
    Ok(Json(
        state
            .repository
            .list_admin_audit_events(&principal.org_id)
            .await?,
    ))
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
) -> Result<Json<crate::api::Review>, HttpError> {
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
) -> Result<Json<crate::api::Review>, HttpError> {
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
}

impl HttpError {
    fn bad_request(message: &str) -> Self {
        Self::Server(ServerError::InvalidRequest(message.to_owned()))
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

impl IntoResponse for HttpError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Server(error) => {
                let status = match &error {
                    ServerError::Forbidden(_) => StatusCode::FORBIDDEN,
                    ServerError::NotFound { .. } => StatusCode::NOT_FOUND,
                    ServerError::AlreadyExists { .. }
                    | ServerError::VersionConflict { .. }
                    | ServerError::RefConflict { .. } => StatusCode::CONFLICT,
                    ServerError::InvalidTransition { .. } | ServerError::InvalidRequest(_) => {
                        StatusCode::BAD_REQUEST
                    }
                    ServerError::Sqlx(_) => StatusCode::INTERNAL_SERVER_ERROR,
                };
                let code = match &error {
                    ServerError::Forbidden(_) => "forbidden",
                    ServerError::NotFound { .. } => "not_found",
                    ServerError::AlreadyExists { .. } => "already_exists",
                    ServerError::VersionConflict { .. } | ServerError::RefConflict { .. } => {
                        "version_conflict"
                    }
                    ServerError::InvalidTransition { .. } | ServerError::InvalidRequest(_) => {
                        "invalid_request"
                    }
                    ServerError::Sqlx(_) => "internal_error",
                };
                (status, code, error.to_string())
            }
            Self::Auth(error) => {
                let status = match &error {
                    AuthError::Unauthorized => StatusCode::UNAUTHORIZED,
                    AuthError::MemberNotAllowed
                    | AuthError::DomainNotAllowed
                    | AuthError::ProviderIdentityConflict => StatusCode::FORBIDDEN,
                    AuthError::NotConfigured | AuthError::ProviderUnavailable(_) => {
                        StatusCode::SERVICE_UNAVAILABLE
                    }
                    AuthError::Configuration(_) | AuthError::Sqlx(_) => {
                        StatusCode::INTERNAL_SERVER_ERROR
                    }
                    _ => StatusCode::BAD_REQUEST,
                };
                (status, error.code(), error.to_string())
            }
        };
        let request_id = format!("req_{}", uuid::Uuid::new_v4().simple());
        let mut response = (
            status,
            Json(json!({
                "error": {
                    "code": code,
                    "message": message,
                    "request_id": request_id
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

    use crate::http::{AdminHealth, HealthStatus, PROTECTED_OPERATIONS, PUBLIC_OPERATIONS, router};

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
