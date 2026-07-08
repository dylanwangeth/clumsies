mod common;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use hub::api::{
    ContextDetail, ContextListResponse, CreateDraftRequest, CreateProjectRequest,
    CreateReviewDecisionRequest, CreateReviewMergeRequest, CreateReviewRequest, DeleteResult,
    DraftDetail, DraftEventListResponse, DraftEventType, DraftListResponse, DraftOperationAction,
    DraftOperationBatchItem, DraftOperationBatchRequest, DraftOperationBatchResponse,
    DraftOperationInput, DraftResourceKind, DraftResourceRef, DraftStatus, PersonalBundleDetail,
    PersonalBundleRequest, PersonalBundleUpdateRequest, Project, ProjectListResponse,
    ProjectOrgSelection, ReplaceProjectOrgSelectionRequest, Review, ReviewDecision,
    ReviewMergeResult, ReviewStatus, SnapshotPayload, UpdateDraftRequest, UpdateProjectRequest,
};
use hub::http::router;
use hub::repository::HubRepository;
use serde::Serialize;
use tower::ServiceExt;

#[tokio::test]
async fn draft_review_merge_produces_project_snapshot() {
    let postgres = common::migrated_postgres().await;
    let repo = HubRepository::new(postgres.pool.clone());
    let org_id = repo.create_org("Acme Memory").await.unwrap();
    let user_id = repo
        .create_user("owner@example.com", Some("Owner"), "owner")
        .await
        .unwrap();
    let project_id = repo
        .create_project(&org_id, "Search Agent", "Project memory test")
        .await
        .unwrap();
    let org_context_id = repo
        .create_org_resource(
            &org_id,
            DraftResourceKind::Context,
            "context/org-policy.md",
            "# Org Policy\n\nPrefer concise answers.",
        )
        .await
        .unwrap();
    let org_reference_id = repo
        .create_org_resource(
            &org_id,
            DraftResourceKind::Context,
            "context/org-reference.md",
            "# Org Reference\n\nUse project-specific context after shared context.",
        )
        .await
        .unwrap();
    repo.select_org_resource_for_project(&project_id, &org_context_id)
        .await
        .unwrap();
    let app = router(postgres.pool.clone());

    let temporary_project: Project = post_json(
        app.clone(),
        "/api/v1/projects",
        &CreateProjectRequest {
            org_id: org_id.clone(),
            name: "Temporary Project".to_owned(),
            description: Some("Created through the public API".to_owned()),
        },
    )
    .await;
    assert_eq!(temporary_project.revision, 0);

    let project_page: ProjectListResponse = get_json(app.clone(), "/api/v1/projects").await;
    assert!(
        project_page
            .items
            .iter()
            .any(|project| project.project_id == temporary_project.project_id)
    );

    let temporary_project: Project = patch_json_with_if_match(
        app.clone(),
        &format!("/api/v1/projects/{}", temporary_project.project_id),
        temporary_project.revision,
        &UpdateProjectRequest {
            name: Some("Renamed Temporary Project".to_owned()),
            description: Some("Updated through the public API".to_owned()),
        },
    )
    .await;
    assert_eq!(temporary_project.revision, 1);
    assert_eq!(temporary_project.name, "Renamed Temporary Project");

    let deleted_project: DeleteResult = delete_json_with_if_match(
        app.clone(),
        &format!("/api/v1/projects/{}", temporary_project.project_id),
        temporary_project.revision,
    )
    .await;
    assert!(deleted_project.deleted);

    let org_context: ContextDetail = get_json(
        app.clone(),
        &format!("/api/v1/org/context/{org_context_id}"),
    )
    .await;
    assert_eq!(org_context.body, "# Org Policy\n\nPrefer concise answers.");

    let org_context_page: ContextListResponse = get_json(app.clone(), "/api/v1/org/context").await;
    assert_eq!(org_context_page.items.len(), 2);
    assert!(
        org_context_page
            .items
            .iter()
            .any(|item| item.context_id == org_context_id)
    );
    assert!(
        org_context_page
            .items
            .iter()
            .any(|item| item.context_id == org_reference_id)
    );

    let org_selection: ProjectOrgSelection = get_json(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/org-selections"),
    )
    .await;
    assert_eq!(org_selection.context.len(), 1);

    let org_selection: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/org-selections"),
        org_selection.revision,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec![org_context_id.clone(), org_reference_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(org_selection.revision, 2);
    assert_eq!(org_selection.context.len(), 2);

    let draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            author_user_id: user_id.clone(),
            runtime_installation_id: "runtime_test".to_owned(),
            project_id: project_id.clone(),
            title: "Add project context".to_owned(),
            description: Some("First project context entry".to_owned()),
            resource: DraftResourceRef {
                kind: DraftResourceKind::Context,
                id: None,
                path: Some("context/intro.md".to_owned()),
            },
            operations: Vec::new(),
        },
    )
    .await;
    assert_eq!(draft.draft.status, DraftStatus::Open);
    assert_eq!(draft.draft.version, 1);

    let draft: DraftDetail = patch_json_with_if_match(
        app.clone(),
        &format!("/api/v1/drafts/{}", draft.draft.draft_id),
        draft.draft.version,
        &UpdateDraftRequest {
            title: Some("Add project context v2".to_owned()),
            description: Some("Updated draft metadata".to_owned()),
            status: None,
        },
    )
    .await;
    assert_eq!(draft.draft.version, 2);
    assert_eq!(draft.draft.title, "Add project context v2");

    let draft: DraftDetail = post_json_with_if_match(
        app.clone(),
        &format!("/api/v1/drafts/{}/operations", draft.draft.draft_id),
        draft.draft.version,
        &DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                kind: DraftResourceKind::Context,
                id: None,
                path: Some("context/intro.md".to_owned()),
            },
            base_hash: None,
            body: Some("# Intro\n\nUse retrieval before answering.".to_owned()),
            new_path: None,
        },
    )
    .await;
    assert_eq!(draft.draft.version, 3);
    assert_eq!(draft.operations.len(), 1);

    let draft_page: DraftListResponse = get_json(
        app.clone(),
        &format!("/api/v1/drafts?project_id={project_id}"),
    )
    .await;
    assert!(
        draft_page
            .items
            .iter()
            .any(|item| item.draft_id == draft.draft.draft_id)
    );

    let batch_draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            author_user_id: user_id.clone(),
            runtime_installation_id: "runtime_batch_origin".to_owned(),
            project_id: project_id.clone(),
            title: "Batch draft".to_owned(),
            description: None,
            resource: DraftResourceRef {
                kind: DraftResourceKind::Context,
                id: None,
                path: Some("context/batch.md".to_owned()),
            },
            operations: Vec::new(),
        },
    )
    .await;
    let batch: DraftOperationBatchResponse = post_json(
        app.clone(),
        "/api/v1/draft-operation-batches",
        &DraftOperationBatchRequest {
            runtime_installation_id: "runtime_batch".to_owned(),
            operations: vec![DraftOperationBatchItem {
                local_operation_id: "local-op-1".to_owned(),
                draft_id: batch_draft.draft.draft_id.clone(),
                expected_draft_version: batch_draft.draft.version,
                operation: DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        kind: DraftResourceKind::Context,
                        id: None,
                        path: Some("context/batch.md".to_owned()),
                    },
                    base_hash: None,
                    body: Some("# Batch\n\nSubmitted from local sync.".to_owned()),
                    new_path: None,
                },
            }],
        },
    )
    .await;
    assert_eq!(batch.accepted_operations, vec!["local-op-1"]);
    assert!(!batch.cursor.is_empty());

    let batch_draft: DraftDetail = get_json(
        app.clone(),
        &format!("/api/v1/drafts/{}", batch_draft.draft.draft_id),
    )
    .await;
    assert_eq!(batch_draft.draft.version, 2);
    let deleted_draft: DeleteResult = delete_json_with_if_match(
        app.clone(),
        &format!("/api/v1/drafts/{}", batch_draft.draft.draft_id),
        batch_draft.draft.version,
    )
    .await;
    assert!(deleted_draft.deleted);

    let review: Review = post_json(
        app.clone(),
        "/api/v1/reviews",
        &CreateReviewRequest {
            draft_id: draft.draft.draft_id.clone(),
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    assert_eq!(review.status, ReviewStatus::Open);

    let review: Review = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/decisions", review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: 1,
            body: Some("Looks good".to_owned()),
        },
    )
    .await;
    assert_eq!(review.status, ReviewStatus::Approved);

    let merge: ReviewMergeResult = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", review.review_id),
        &CreateReviewMergeRequest {
            expected_review_version: 2,
            expected_target_version: Some(0),
        },
    )
    .await;
    assert_eq!(merge.review.status, ReviewStatus::Merged);
    assert_eq!(merge.applied_operation_count, 1);
    let snapshot_id = merge.snapshot_id.expect("merge should create a snapshot");

    let project_context_page: ContextListResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/context"),
    )
    .await;
    assert_eq!(project_context_page.items.len(), 1);

    let bundle: PersonalBundleDetail = post_json(
        app.clone(),
        "/api/v1/me/bundles",
        &PersonalBundleRequest {
            owner_user_id: draft.draft.author.user_id.clone(),
            name: "Daily context".to_owned(),
            description: Some("A personal bundle of selected context".to_owned()),
            rule_ids: Vec::new(),
            context_ids: vec![org_context_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(bundle.context.len(), 1);
    let bundle: PersonalBundleDetail = patch_json_with_if_match(
        app.clone(),
        &format!("/api/v1/me/bundles/{}", bundle.bundle.bundle_id),
        bundle.bundle.revision,
        &PersonalBundleUpdateRequest {
            name: Some("Focused context".to_owned()),
            description: Some("Updated personal bundle".to_owned()),
            rule_ids: None,
            context_ids: Some(vec![org_reference_id.clone()]),
            workflow_ids: None,
        },
    )
    .await;
    assert_eq!(bundle.bundle.revision, 2);
    assert_eq!(bundle.context[0].context_id, org_reference_id);
    let bundle: PersonalBundleDetail = get_json(
        app.clone(),
        &format!("/api/v1/me/bundles/{}", bundle.bundle.bundle_id),
    )
    .await;
    assert_eq!(bundle.context[0].context_id, org_reference_id);
    let deleted_bundle: DeleteResult = delete_json_with_if_match(
        app.clone(),
        &format!("/api/v1/me/bundles/{}", bundle.bundle.bundle_id),
        bundle.bundle.revision,
    )
    .await;
    assert!(deleted_bundle.deleted);

    let events: DraftEventListResponse = get_json(app.clone(), "/api/v1/draft-events").await;
    assert!(events.next_cursor.is_some());
    assert!(
        events
            .events
            .iter()
            .any(|event| event.event_type == DraftEventType::Created)
    );
    assert!(
        events
            .events
            .iter()
            .any(|event| event.event_type == DraftEventType::Updated)
    );
    assert!(
        events
            .events
            .iter()
            .any(|event| event.event_type == DraftEventType::OperationAppended)
    );
    assert!(
        events
            .events
            .iter()
            .any(|event| event.event_type == DraftEventType::Discarded)
    );
    assert!(
        events
            .events
            .iter()
            .any(|event| event.event_type == DraftEventType::Submitted)
    );
    assert!(events.events.iter().any(|event| {
        event.event_type == DraftEventType::OperationAppended
            && event.runtime_installation_id.as_deref() == Some("runtime_batch")
    }));
    let after_events: DraftEventListResponse = get_json(
        app.clone(),
        &format!(
            "/api/v1/draft-events?after_cursor={}",
            events.next_cursor.as_ref().unwrap()
        ),
    )
    .await;
    assert!(after_events.events.is_empty());

    let snapshot: SnapshotPayload =
        get_json(app, &format!("/api/v1/snapshots/{snapshot_id}")).await;
    assert_eq!(
        snapshot.manifest.project_id.as_deref(),
        Some(project_id.as_str())
    );
    assert_eq!(snapshot.manifest.version, 1);
    let contents = snapshot
        .content_items
        .iter()
        .map(|item| item.content.as_str())
        .collect::<Vec<_>>();
    assert!(contents.contains(&"# Intro\n\nUse retrieval before answering."));
    assert!(contents.contains(&"# Org Policy\n\nPrefer concise answers."));
    assert!(
        contents.contains(&"# Org Reference\n\nUse project-specific context after shared context.")
    );
    let selection = snapshot
        .project_org_selection
        .expect("project snapshot should include org selection");
    assert_eq!(selection.context.len(), 2);
    assert_eq!(selection.context[0].context_id, org_context_id);
    assert_eq!(selection.context[1].context_id, org_reference_id);
}

async fn post_json<TRequest, TResponse>(
    app: axum::Router,
    uri: &str,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    let body = serde_json::to_vec(request).unwrap();
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn post_json_with_if_match<TRequest, TResponse>(
    app: axum::Router,
    uri: &str,
    expected_version: i64,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    let body = serde_json::to_vec(request).unwrap();
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("content-type", "application/json")
                .header("if-match", expected_version.to_string())
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn patch_json_with_if_match<TRequest, TResponse>(
    app: axum::Router,
    uri: &str,
    expected_version: i64,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    let body = serde_json::to_vec(request).unwrap();
    let response = app
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(uri)
                .header("content-type", "application/json")
                .header("if-match", expected_version.to_string())
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn put_json_with_if_match<TRequest, TResponse>(
    app: axum::Router,
    uri: &str,
    expected_version: i64,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    let body = serde_json::to_vec(request).unwrap();
    let response = app
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(uri)
                .header("content-type", "application/json")
                .header("if-match", expected_version.to_string())
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn delete_json_with_if_match<TResponse>(
    app: axum::Router,
    uri: &str,
    expected_version: i64,
) -> TResponse
where
    TResponse: serde::de::DeserializeOwned,
{
    let response = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(uri)
                .header("if-match", expected_version.to_string())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn get_json<TResponse>(app: axum::Router, uri: &str) -> TResponse
where
    TResponse: serde::de::DeserializeOwned,
{
    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(uri)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn decode_json<TResponse>(response: axum::response::Response) -> TResponse
where
    TResponse: serde::de::DeserializeOwned,
{
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}
