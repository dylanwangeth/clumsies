use axum::Json;
use axum::extract::{Extension, Path, Query, State};
use axum::http::HeaderMap;
use serde::Deserialize;

use crate::api::{
    CreateDraftRebaseRequest, CreateDraftReconciliationCandidateRequest, CreateDraftRequest,
    CreateReviewCommentRequest, CreateReviewDecisionRequest, CreateReviewMergeRequest,
    CreateReviewRequest, CreateReviewSubmissionRequest, DraftOperationBatchRequest,
    DraftOperationInput, UpdateDraftRequest,
};
use crate::auth::AuthPrincipal;
use crate::http::{AppState, HttpError, parse_if_match, parse_ref_if_match, require_org_admin};

pub(crate) async fn create_draft(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<CreateDraftRequest>,
) -> Result<Json<crate::api::DraftDetail>, HttpError> {
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

#[derive(Deserialize)]
pub(crate) struct ListDraftsQuery {
    project_id: Option<String>,
}

pub(crate) async fn list_drafts(
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

pub(crate) async fn get_draft(
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

pub(crate) async fn update_draft(
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

pub(crate) async fn delete_draft(
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
            .discard_draft(&draft_id, &principal.user_id, expected_version)
            .await?,
    ))
}

pub(crate) async fn append_draft_operation(
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

pub(crate) async fn create_draft_reconciliation_candidate(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(draft_id): Path<String>,
    Json(request): Json<CreateDraftReconciliationCandidateRequest>,
) -> Result<Json<crate::api::DraftReconciliationCandidate>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    Ok(Json(
        state
            .repository
            .create_draft_reconciliation_candidate(&draft_id, request)
            .await?,
    ))
}

pub(crate) async fn get_draft_reconciliation_candidate(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((draft_id, candidate_id)): Path<(String, String)>,
) -> Result<Json<crate::api::DraftReconciliationCandidate>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    Ok(Json(
        state
            .repository
            .get_draft_reconciliation_candidate(&draft_id, &candidate_id)
            .await?,
    ))
}

pub(crate) async fn create_draft_rebase(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(draft_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<CreateDraftRebaseRequest>,
) -> Result<Json<crate::api::DraftRebaseResult>, HttpError> {
    state
        .repository
        .ensure_draft_owner(&principal, &draft_id)
        .await?;
    let expected_ref = parse_ref_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .create_draft_rebase(
                &draft_id,
                &principal.user_id,
                expected_ref.as_deref(),
                request,
            )
            .await?,
    ))
}

#[derive(Deserialize)]
pub(crate) struct ListDraftEventsQuery {
    after_cursor: Option<String>,
    limit: Option<i64>,
}

pub(crate) async fn list_draft_events(
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

pub(crate) async fn create_draft_operation_batch(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(request): Json<DraftOperationBatchRequest>,
) -> Result<Json<crate::api::DraftOperationBatchResponse>, HttpError> {
    Ok(Json(
        state
            .repository
            .create_draft_operation_batch(&principal, request)
            .await?,
    ))
}

pub(crate) async fn create_review(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    headers: HeaderMap,
    Json(request): Json<CreateReviewRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    let expected_ref = parse_ref_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .create_review(&principal.user_id, expected_ref.as_deref(), request)
            .await?,
    ))
}

#[derive(Deserialize)]
pub(crate) struct ListReviewsQuery {
    project_id: Option<String>,
}

pub(crate) async fn list_reviews(
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

pub(crate) async fn get_review(
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

pub(crate) async fn list_review_comments(
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

pub(crate) async fn create_review_comment(
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

pub(crate) async fn create_review_decision(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    Json(request): Json<CreateReviewDecisionRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    require_org_admin(&principal)?;
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    Ok(Json(
        state
            .repository
            .create_review_decision(&review_id, &principal.user_id, request)
            .await?,
    ))
}

pub(crate) async fn create_review_submission(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(review_id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<CreateReviewSubmissionRequest>,
) -> Result<Json<crate::api::ReviewDetail>, HttpError> {
    state
        .repository
        .ensure_review_member(&principal, &review_id)
        .await?;
    let expected_ref = parse_ref_if_match(&headers)?;
    Ok(Json(
        state
            .repository
            .create_review_submission(
                &review_id,
                &principal.user_id,
                expected_ref.as_deref(),
                request,
            )
            .await?,
    ))
}

pub(crate) async fn create_review_merge(
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
            .create_review_merge(
                &review_id,
                &principal.user_id,
                expected_ref.as_deref(),
                request,
            )
            .await?,
    ))
}
