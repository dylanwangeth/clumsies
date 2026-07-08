use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post, put};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;

use crate::api::{
    CreateDraftRequest, CreateProjectRequest, CreateReviewDecisionRequest,
    CreateReviewMergeRequest, CreateReviewRequest, DraftOperationBatchRequest, DraftOperationInput,
    PersonalBundleRequest, PersonalBundleUpdateRequest, ReplaceProjectOrgSelectionRequest,
    UpdateDraftRequest, UpdateProjectRequest,
};
use crate::repository::{HubError, HubRepository};

const CURRENT_SCHEMA_MIGRATION: i64 = 20260708000100;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    repository: HubRepository,
    version: &'static str,
}

pub fn router(pool: PgPool) -> Router {
    Router::new()
        .route("/api/v1/admin/health", get(admin_health))
        .route("/api/v1/projects", get(list_projects))
        .route("/api/v1/projects", post(create_project))
        .route("/api/v1/projects/{project_id}", get(get_project))
        .route("/api/v1/projects/{project_id}", patch(update_project))
        .route("/api/v1/projects/{project_id}", delete(delete_project))
        .route("/api/v1/me/bundles", get(list_personal_bundles))
        .route("/api/v1/me/bundles", post(create_personal_bundle))
        .route("/api/v1/me/bundles/{bundle_id}", get(get_personal_bundle))
        .route(
            "/api/v1/me/bundles/{bundle_id}",
            patch(update_personal_bundle),
        )
        .route(
            "/api/v1/me/bundles/{bundle_id}",
            delete(delete_personal_bundle),
        )
        .route("/api/v1/org/rules", get(list_org_rules))
        .route("/api/v1/org/rules/{rule_id}", get(get_org_rule))
        .route("/api/v1/org/context", get(list_org_context))
        .route("/api/v1/org/context/{context_id}", get(get_org_context))
        .route("/api/v1/org/workflows", get(list_org_workflows))
        .route("/api/v1/org/workflows/{workflow_id}", get(get_org_workflow))
        .route("/api/v1/org/metaprompt", get(get_org_metaprompt))
        .route(
            "/api/v1/projects/{project_id}/rules",
            get(list_project_rules),
        )
        .route(
            "/api/v1/projects/{project_id}/rules/{rule_id}",
            get(get_project_rule),
        )
        .route(
            "/api/v1/projects/{project_id}/context",
            get(list_project_context),
        )
        .route(
            "/api/v1/projects/{project_id}/context/{context_id}",
            get(get_project_context),
        )
        .route(
            "/api/v1/projects/{project_id}/workflows",
            get(list_project_workflows),
        )
        .route(
            "/api/v1/projects/{project_id}/workflows/{workflow_id}",
            get(get_project_workflow),
        )
        .route(
            "/api/v1/projects/{project_id}/metaprompt",
            get(get_project_metaprompt),
        )
        .route(
            "/api/v1/projects/{project_id}/org-selections",
            get(get_project_org_selection),
        )
        .route(
            "/api/v1/projects/{project_id}/org-selections",
            put(replace_project_org_selection),
        )
        .route("/api/v1/drafts", get(list_drafts))
        .route("/api/v1/drafts", post(create_draft))
        .route("/api/v1/drafts/{draft_id}", get(get_draft))
        .route("/api/v1/drafts/{draft_id}", patch(update_draft))
        .route("/api/v1/drafts/{draft_id}", delete(delete_draft))
        .route(
            "/api/v1/drafts/{draft_id}/operations",
            post(append_draft_operation),
        )
        .route("/api/v1/draft-events", get(list_draft_events))
        .route(
            "/api/v1/draft-operation-batches",
            post(create_draft_operation_batch),
        )
        .route("/api/v1/reviews", post(create_review))
        .route("/api/v1/reviews/{review_id}", get(get_review))
        .route(
            "/api/v1/reviews/{review_id}/decisions",
            post(create_review_decision),
        )
        .route(
            "/api/v1/reviews/{review_id}/merges",
            post(create_review_merge),
        )
        .route(
            "/api/v1/projects/{project_id}/snapshots",
            get(list_project_snapshots),
        )
        .route("/api/v1/snapshots/{snapshot_id}", get(get_snapshot))
        .with_state(AppState {
            repository: HubRepository::new(pool.clone()),
            pool,
            version: env!("CARGO_PKG_VERSION"),
        })
}

async fn admin_health(State(state): State<AppState>) -> Json<AdminHealth> {
    let database = check_database(&state.pool).await;
    let schema = if database.status == HealthStatus::Ok {
        check_schema(&state.pool).await
    } else {
        dependency_down("schema", "database")
    };
    let snapshot_service = if schema.status == HealthStatus::Ok {
        implemented_component("snapshot service")
    } else {
        dependency_down("snapshot service", "schema")
    };
    let sync_queue = unimplemented_component("sync queue");
    let status = overall_status([
        database.status,
        schema.status,
        snapshot_service.status,
        sync_queue.status,
    ]);

    Json(AdminHealth {
        status,
        version: state.version.to_owned(),
        database,
        schema,
        snapshot_service,
        sync_queue,
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

fn unimplemented_component(name: &str) -> HealthCheck {
    HealthCheck {
        status: HealthStatus::Down,
        message: format!("{name} is not implemented"),
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
    Json(request): Json<CreateProjectRequest>,
) -> Result<Json<crate::api::Project>, HttpError> {
    Ok(Json(
        state
            .repository
            .create_project_from_request(request)
            .await?,
    ))
}

async fn list_projects(
    State(state): State<AppState>,
) -> Result<Json<crate::api::ProjectListResponse>, HttpError> {
    Ok(Json(state.repository.list_projects().await?))
}

async fn get_project(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::Project>, HttpError> {
    Ok(Json(state.repository.get_project(&project_id).await?))
}

async fn update_project(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<UpdateProjectRequest>,
) -> Result<Json<crate::api::Project>, HttpError> {
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
    Path(project_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
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
    Json(request): Json<CreateDraftRequest>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
    Ok(Json(state.repository.create_draft(request).await?))
}

async fn create_personal_bundle(
    State(state): State<AppState>,
    Json(request): Json<PersonalBundleRequest>,
) -> Result<Json<crate::api::PersonalBundleDetail>, HttpError> {
    Ok(Json(
        state.repository.create_personal_bundle(request).await?,
    ))
}

async fn list_personal_bundles(
    State(state): State<AppState>,
) -> Result<Json<crate::api::PersonalBundleListResponse>, HttpError> {
    Ok(Json(state.repository.list_personal_bundles().await?))
}

async fn get_personal_bundle(
    State(state): State<AppState>,
    Path(bundle_id): Path<String>,
) -> Result<Json<crate::api::PersonalBundleDetail>, HttpError> {
    Ok(Json(
        state.repository.get_personal_bundle(&bundle_id).await?,
    ))
}

async fn update_personal_bundle(
    State(state): State<AppState>,
    Path(bundle_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<PersonalBundleUpdateRequest>,
) -> Result<Json<crate::api::PersonalBundleDetail>, HttpError> {
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .update_personal_bundle(&bundle_id, expected_revision, request)
            .await?,
    ))
}

async fn delete_personal_bundle(
    State(state): State<AppState>,
    Path(bundle_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
    let expected_revision = parse_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .delete_personal_bundle(&bundle_id, expected_revision)
            .await?,
    ))
}

async fn list_org_rules(
    State(state): State<AppState>,
) -> Result<Json<crate::api::RuleListResponse>, HttpError> {
    Ok(Json(state.repository.list_org_rules().await?))
}

async fn get_org_rule(
    State(state): State<AppState>,
    Path(rule_id): Path<String>,
) -> Result<Json<crate::api::RuleDetail>, HttpError> {
    Ok(Json(state.repository.get_org_rule(&rule_id).await?))
}

async fn list_org_context(
    State(state): State<AppState>,
) -> Result<Json<crate::api::ContextListResponse>, HttpError> {
    Ok(Json(state.repository.list_org_context().await?))
}

async fn get_org_context(
    State(state): State<AppState>,
    Path(context_id): Path<String>,
) -> Result<Json<crate::api::ContextDetail>, HttpError> {
    Ok(Json(state.repository.get_org_context(&context_id).await?))
}

async fn list_org_workflows(
    State(state): State<AppState>,
) -> Result<Json<crate::api::WorkflowListResponse>, HttpError> {
    Ok(Json(state.repository.list_org_workflows().await?))
}

async fn get_org_workflow(
    State(state): State<AppState>,
    Path(workflow_id): Path<String>,
) -> Result<Json<crate::api::WorkflowDetail>, HttpError> {
    Ok(Json(state.repository.get_org_workflow(&workflow_id).await?))
}

async fn get_org_metaprompt(
    State(state): State<AppState>,
) -> Result<Json<crate::api::MetapromptDetail>, HttpError> {
    Ok(Json(state.repository.get_org_metaprompt().await?))
}

async fn list_project_rules(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::RuleListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_project_rules(&project_id).await?,
    ))
}

async fn get_project_rule(
    State(state): State<AppState>,
    Path((project_id, rule_id)): Path<(String, String)>,
) -> Result<Json<crate::api::RuleDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_project_rule(&project_id, &rule_id)
            .await?,
    ))
}

async fn list_project_context(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::ContextListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_project_context(&project_id).await?,
    ))
}

async fn get_project_context(
    State(state): State<AppState>,
    Path((project_id, context_id)): Path<(String, String)>,
) -> Result<Json<crate::api::ContextDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_project_context(&project_id, &context_id)
            .await?,
    ))
}

async fn list_project_workflows(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::WorkflowListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_project_workflows(&project_id).await?,
    ))
}

async fn get_project_workflow(
    State(state): State<AppState>,
    Path((project_id, workflow_id)): Path<(String, String)>,
) -> Result<Json<crate::api::WorkflowDetail>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_project_workflow(&project_id, &workflow_id)
            .await?,
    ))
}

async fn get_project_metaprompt(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::MetapromptDetail>, HttpError> {
    Ok(Json(
        state.repository.get_project_metaprompt(&project_id).await?,
    ))
}

async fn get_project_org_selection(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::ProjectOrgSelection>, HttpError> {
    Ok(Json(
        state
            .repository
            .get_project_org_selection(&project_id)
            .await?,
    ))
}

async fn replace_project_org_selection(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<ReplaceProjectOrgSelectionRequest>,
) -> Result<Json<crate::api::ProjectOrgSelection>, HttpError> {
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
    Query(query): Query<ListDraftsQuery>,
) -> Result<Json<crate::api::DraftListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_drafts(query.project_id.as_deref())
            .await?,
    ))
}

async fn get_draft(
    State(state): State<AppState>,
    Path(draft_id): Path<String>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
    Ok(Json(state.repository.get_draft(&draft_id).await?))
}

async fn update_draft(
    State(state): State<AppState>,
    Path(draft_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<UpdateDraftRequest>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
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
    Path(draft_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<crate::api::DeleteResult>, HttpError> {
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
    Path(draft_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<DraftOperationInput>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
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
}

async fn list_draft_events(
    State(state): State<AppState>,
    Query(query): Query<ListDraftEventsQuery>,
) -> Result<Json<crate::api::DraftEventListResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .list_draft_events(query.after_cursor.as_deref())
            .await?,
    ))
}

async fn create_draft_operation_batch(
    State(state): State<AppState>,
    Json(request): Json<DraftOperationBatchRequest>,
) -> Result<Json<crate::api::DraftOperationBatchResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .create_draft_operation_batch(request)
            .await?,
    ))
}

async fn create_review(
    State(state): State<AppState>,
    Json(request): Json<CreateReviewRequest>,
) -> Result<Json<crate::api::Review>, HttpError> {
    Ok(Json(state.repository.create_review(request).await?))
}

async fn get_review(
    State(state): State<AppState>,
    Path(review_id): Path<String>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    Ok(Json(state.repository.get_review_detail(&review_id).await?))
}

async fn create_review_decision(
    State(state): State<AppState>,
    Path(review_id): Path<String>,
    Json(request): Json<CreateReviewDecisionRequest>,
) -> Result<Json<crate::api::Review>, HttpError> {
    Ok(Json(
        state
            .repository
            .create_review_decision(&review_id, request)
            .await?,
    ))
}

async fn create_review_merge(
    State(state): State<AppState>,
    Path(review_id): Path<String>,
    Json(request): Json<CreateReviewMergeRequest>,
) -> Result<Json<crate::api::ReviewMergeResult>, HttpError> {
    Ok(Json(
        state
            .repository
            .create_review_merge(&review_id, request)
            .await?,
    ))
}

async fn list_project_snapshots(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<crate::api::SnapshotListResponse>, HttpError> {
    Ok(Json(
        state.repository.list_project_snapshots(&project_id).await?,
    ))
}

async fn get_snapshot(
    State(state): State<AppState>,
    Path(snapshot_id): Path<String>,
) -> Result<Json<crate::api::SnapshotPayload>, HttpError> {
    Ok(Json(
        state.repository.get_snapshot_payload(&snapshot_id).await?,
    ))
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

struct HttpError(HubError);

impl HttpError {
    fn bad_request(message: &str) -> Self {
        Self(HubError::InvalidRequest(message.to_owned()))
    }
}

impl From<HubError> for HttpError {
    fn from(error: HubError) -> Self {
        Self(error)
    }
}

impl IntoResponse for HttpError {
    fn into_response(self) -> Response {
        let status = match self.0 {
            HubError::NotFound { .. } => StatusCode::NOT_FOUND,
            HubError::VersionConflict { .. } => StatusCode::CONFLICT,
            HubError::InvalidTransition { .. } | HubError::InvalidRequest(_) => {
                StatusCode::BAD_REQUEST
            }
            HubError::Sqlx(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        let code = match status {
            StatusCode::NOT_FOUND => "not_found",
            StatusCode::CONFLICT => "version_conflict",
            StatusCode::BAD_REQUEST => "invalid_request",
            _ => "internal_error",
        };
        (
            status,
            Json(json!({
                "error": {
                    "code": code,
                    "message": self.0.to_string(),
                    "request_id": "local"
                }
            })),
        )
            .into_response()
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
    pub snapshot_service: HealthCheck,
    pub sync_queue: HealthCheck,
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
    use axum::body::{Body, to_bytes};
    use axum::http::{Request, StatusCode};
    use sqlx::postgres::PgPoolOptions;
    use std::time::Duration;
    use tower::ServiceExt;

    use crate::http::{AdminHealth, HealthStatus, router};

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
        assert_eq!(health.snapshot_service.status, HealthStatus::Down);
        assert_eq!(health.sync_queue.status, HealthStatus::Down);
    }
}
