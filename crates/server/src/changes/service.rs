use crate::api::*;
use crate::auth::AuthPrincipal;
use crate::repository::{ServerError, ServerRepository};

use super::postgres::{self, CommitOutcome};

use std::collections::BTreeSet;

impl ServerRepository {
    pub async fn ensure_draft_owner(
        &self,
        principal: &AuthPrincipal,
        draft_id: &str,
    ) -> Result<(), ServerError> {
        if postgres::draft_is_owned_by(self.pool(), principal, draft_id).await? {
            Ok(())
        } else {
            Err(ServerError::not_found("draft", draft_id))
        }
    }

    pub async fn ensure_review_member(
        &self,
        principal: &AuthPrincipal,
        review_id: &str,
    ) -> Result<(), ServerError> {
        if postgres::review_is_accessible(self.pool(), principal, review_id).await? {
            Ok(())
        } else {
            Err(ServerError::not_found("review", review_id))
        }
    }

    pub async fn create_draft(
        &self,
        author_user_id: &str,
        request: CreateDraftRequest,
    ) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let draft_id = postgres::create_draft(&mut tx, author_user_id, request).await?;
        tx.commit().await?;
        self.get_draft(&draft_id).await
    }

    pub async fn list_drafts(
        &self,
        author_user_id: &str,
        project_id: Option<&str>,
    ) -> Result<DraftListResponse, ServerError> {
        postgres::list_drafts(self.pool(), author_user_id, project_id).await
    }

    pub async fn get_draft(&self, draft_id: &str) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let detail = postgres::load_draft_detail(&mut tx, draft_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn append_draft_operation(
        &self,
        draft_id: &str,
        expected_draft_version: i64,
        operation: DraftOperationInput,
    ) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::append_draft_operation_in_tx(
            &mut tx,
            draft_id,
            expected_draft_version,
            operation,
            None,
            false,
        )
        .await?;
        tx.commit().await?;
        self.get_draft(draft_id).await
    }

    pub async fn create_draft_reconciliation_candidate(
        &self,
        draft_id: &str,
        request: CreateDraftReconciliationCandidateRequest,
    ) -> Result<DraftReconciliationCandidate, ServerError> {
        let mut tx = self.pool().begin().await?;
        let candidate = postgres::create_reconciliation_candidate_in_tx(
            &mut tx,
            draft_id,
            request.expected_draft_version,
        )
        .await?;
        tx.commit().await?;
        Ok(candidate)
    }

    pub async fn get_draft_reconciliation_candidate(
        &self,
        draft_id: &str,
        candidate_id: &str,
    ) -> Result<DraftReconciliationCandidate, ServerError> {
        let mut tx = self.pool().begin().await?;
        let candidate =
            postgres::load_reconciliation_candidate(&mut tx, draft_id, candidate_id).await?;
        tx.commit().await?;
        Ok(candidate)
    }

    pub async fn create_draft_rebase(
        &self,
        draft_id: &str,
        author_user_id: &str,
        expected_ref: Option<&str>,
        request: CreateDraftRebaseRequest,
    ) -> Result<DraftRebaseResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        let applied = postgres::apply_draft_rebase_in_tx(
            &mut tx,
            draft_id,
            author_user_id,
            expected_ref,
            request,
        )
        .await?;
        tx.commit().await?;
        Ok(applied)
    }

    pub async fn update_draft(
        &self,
        draft_id: &str,
        expected_draft_version: i64,
        request: UpdateDraftRequest,
    ) -> Result<DraftDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::update_draft(&mut tx, draft_id, expected_draft_version, request).await?;
        tx.commit().await?;
        self.get_draft(draft_id).await
    }

    pub async fn discard_draft(
        &self,
        draft_id: &str,
        actor_user_id: &str,
        expected_draft_version: i64,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        let result =
            postgres::discard_draft(&mut tx, draft_id, actor_user_id, expected_draft_version)
                .await?;
        tx.commit().await?;
        Ok(result)
    }

    pub async fn create_draft_operation_batch(
        &self,
        principal: &AuthPrincipal,
        request: DraftOperationBatchRequest,
    ) -> Result<DraftOperationBatchResponse, ServerError> {
        if request.operations.is_empty() {
            return Err(ServerError::InvalidRequest(
                "draft operation batch cannot be empty".to_owned(),
            ));
        }
        let draft_ids = request
            .operations
            .iter()
            .map(|item| item.draft_id.clone())
            .collect::<Vec<_>>();
        let mut tx = self.pool().begin().await?;
        postgres::ensure_drafts_owned_by(&mut tx, principal, &draft_ids).await?;
        let result = postgres::create_draft_operation_batch(&mut tx, request).await?;
        tx.commit().await?;
        Ok(result)
    }

    pub async fn list_draft_events(
        &self,
        author_user_id: &str,
        after_cursor: Option<&str>,
        limit: Option<i64>,
    ) -> Result<DraftEventListResponse, ServerError> {
        let limit = limit.unwrap_or(50);
        if !(1..=200).contains(&limit) {
            return Err(ServerError::InvalidRequest(
                "draft event limit must be between 1 and 200".to_owned(),
            ));
        }
        after_cursor
            .map(str::parse::<i64>)
            .transpose()
            .map_err(|_| ServerError::InvalidRequest("invalid draft event cursor".to_owned()))?;
        postgres::list_draft_events(self.pool(), author_user_id, after_cursor, Some(limit)).await
    }

    pub async fn create_review(
        &self,
        author_user_id: &str,
        expected_ref: Option<&str>,
        request: CreateReviewRequest,
    ) -> Result<ReviewDetail, ServerError> {
        let requested_drafts = request
            .drafts
            .iter()
            .map(|draft| (draft.draft_id.clone(), draft.expected_draft_version))
            .collect::<Vec<_>>();
        let Some((primary_draft_id, _)) = requested_drafts.first() else {
            return Err(ServerError::InvalidRequest(
                "a review must contain at least one draft".to_owned(),
            ));
        };
        let distinct_draft_ids = requested_drafts
            .iter()
            .map(|(draft_id, _)| draft_id)
            .collect::<BTreeSet<_>>();
        if distinct_draft_ids.len() != requested_drafts.len() {
            return Err(ServerError::InvalidRequest(
                "a review must not contain duplicate drafts".to_owned(),
            ));
        }
        if requested_drafts.len() > 1
            && (request.candidate_id.is_some() || request.resolved_state.is_some())
        {
            return Err(ServerError::InvalidRequest(
                "reconcile every draft before requesting a multi-file review".to_owned(),
            ));
        }
        if let Some((review_id, version)) =
            postgres::find_rejected_review(self.pool(), primary_draft_id).await?
        {
            return self
                .create_review_submission(
                    &review_id,
                    author_user_id,
                    expected_ref,
                    CreateReviewSubmissionRequest {
                        expected_review_version: version,
                        drafts: request.drafts,
                        title: request.title,
                        description: request.description,
                        candidate_id: request.candidate_id,
                        resolved_state: request.resolved_state,
                    },
                )
                .await;
        }

        let draft_ids = requested_drafts
            .iter()
            .map(|(draft_id, _)| draft_id.clone())
            .collect::<Vec<_>>();
        let mut tx = self.pool().begin().await?;
        postgres::ensure_drafts_authored_by(&mut tx, author_user_id, &draft_ids).await?;
        let outcome = postgres::create_review(
            &mut tx,
            author_user_id,
            expected_ref,
            request,
            requested_drafts,
        )
        .await?;
        tx.commit().await?;
        outcome.into_result()
    }

    pub async fn list_reviews(
        &self,
        principal: &AuthPrincipal,
        project_id: Option<&str>,
    ) -> Result<ReviewListResponse, ServerError> {
        let mut tx = self.pool().begin().await?;
        let response = postgres::list_reviews(&mut tx, principal, project_id).await?;
        tx.commit().await?;
        Ok(response)
    }

    pub async fn get_review(&self, review_id: &str) -> Result<Review, ServerError> {
        let mut tx = self.pool().begin().await?;
        let review = postgres::load_review(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(review)
    }

    pub async fn get_review_detail(&self, review_id: &str) -> Result<ReviewDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let detail = postgres::load_review_detail(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn list_review_comments(
        &self,
        review_id: &str,
    ) -> Result<ReviewCommentListResponse, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::ensure_review_exists(&mut tx, review_id).await?;
        let comments = postgres::load_review_comments(&mut tx, review_id).await?;
        tx.commit().await?;
        Ok(ReviewCommentListResponse {
            items: comments,
            page_info: crate::shared::page_info(),
        })
    }

    pub async fn create_review_comment(
        &self,
        review_id: &str,
        author_user_id: &str,
        request: CreateReviewCommentRequest,
    ) -> Result<ReviewComment, ServerError> {
        if request.body.trim().is_empty() {
            return Err(ServerError::InvalidRequest(
                "review comment body must not be empty".to_owned(),
            ));
        }
        match (request.anchor_path.as_deref(), request.anchor_line) {
            (None, None) => {}
            (Some(path), Some(line)) if !path.is_empty() && line > 0 => {}
            (Some(_), Some(_)) => {
                return Err(ServerError::InvalidRequest(
                    "review comment anchor_path must not be empty and anchor_line must be positive"
                        .to_owned(),
                ));
            }
            _ => {
                return Err(ServerError::InvalidRequest(
                    "review comment anchor_path and anchor_line must be provided together"
                        .to_owned(),
                ));
            }
        }
        let mut tx = self.pool().begin().await?;
        let comment =
            postgres::create_review_comment(&mut tx, review_id, author_user_id, request).await?;
        tx.commit().await?;
        Ok(comment)
    }

    pub async fn create_review_decision(
        &self,
        review_id: &str,
        decided_by_user_id: &str,
        request: CreateReviewDecisionRequest,
    ) -> Result<ReviewDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let detail =
            postgres::create_review_decision(&mut tx, review_id, decided_by_user_id, request)
                .await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn create_review_submission(
        &self,
        review_id: &str,
        author_user_id: &str,
        expected_ref: Option<&str>,
        request: CreateReviewSubmissionRequest,
    ) -> Result<ReviewDetail, ServerError> {
        let Some(_) = request.drafts.first() else {
            return Err(ServerError::InvalidRequest(
                "a review must contain at least one draft".to_owned(),
            ));
        };
        let distinct_draft_ids = request
            .drafts
            .iter()
            .map(|draft| &draft.draft_id)
            .collect::<BTreeSet<_>>();
        if distinct_draft_ids.len() != request.drafts.len() {
            return Err(ServerError::InvalidRequest(
                "a review must not contain duplicate drafts".to_owned(),
            ));
        }
        let mut tx = self.pool().begin().await?;
        let outcome = postgres::create_review_submission(
            &mut tx,
            review_id,
            author_user_id,
            expected_ref,
            request,
        )
        .await?;
        tx.commit().await?;
        outcome.into_result()
    }

    pub async fn create_review_merge(
        &self,
        review_id: &str,
        actor_user_id: &str,
        expected_project_ref: Option<&str>,
        request: CreateReviewMergeRequest,
    ) -> Result<ReviewMergeResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        let outcome = postgres::create_review_merge(
            &mut tx,
            review_id,
            actor_user_id,
            expected_project_ref,
            request,
        )
        .await?;
        tx.commit().await?;
        let merge = match outcome {
            CommitOutcome::Success(merge) => merge,
            CommitOutcome::Failure(error) => return Err(error),
        };
        let review = self.get_review(review_id).await?;
        Ok(ReviewMergeResult {
            review,
            commit_id: Some(merge.commit_id),
            applied_operation_count: merge.applied_operation_count,
        })
    }
}
