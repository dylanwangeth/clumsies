mod common;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use serde::Serialize;
use server::api::{
    CommitListResponse, CommitPayload, CommitStateResponse, ContextDetail, ContextListResponse,
    CreateDraftRequest, CreateProjectRequest, CreateReviewCommentRequest,
    CreateReviewDecisionRequest, CreateReviewMergeRequest, CreateReviewRequest, DeleteResult,
    DraftDetail, DraftEventListResponse, DraftEventType, DraftListResponse, DraftOperationAction,
    DraftOperationBatchItem, DraftOperationBatchRequest, DraftOperationBatchResponse,
    DraftOperationInput, DraftResourceKind, DraftResourceRef, DraftStatus, MeResponse,
    PersonalBundleDetail, PersonalBundleRequest, PersonalBundleUpdateRequest, Project,
    ProjectListResponse, ProjectOrgSelection, ReplaceProjectOrgSelectionRequest, ResourceScope,
    Review, ReviewComment, ReviewCommentListResponse, ReviewDecision, ReviewDetail,
    ReviewListResponse, ReviewMergeResult, ReviewStatus, UpdateDraftRequest, UpdateProjectRequest,
};
use server::repository::ServerRepository;
use tower::ServiceExt;

#[tokio::test]
async fn draft_review_merge_produces_project_commit() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Search Agent",
        )
        .await
        .unwrap();
    let org_id = bootstrap.org_id;
    let user_id = bootstrap.user_id;
    let project_id = bootstrap.project_id;
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
    let (app, _token) = common::authenticated_router(postgres.pool.clone()).await;

    let me: MeResponse = get_json(app.clone(), "/api/v1/me").await;
    assert_eq!(me.user.user_id, user_id);
    assert_eq!(me.user.display_name.as_deref(), Some("Owner"));
    assert_eq!(
        me.user.avatar_url.as_deref(),
        Some("https://images.example.test/avatar.png")
    );
    assert_eq!(me.org.org_id, org_id);
    assert_eq!(me.default_project_id.as_deref(), Some(project_id.as_str()));

    let (org_commit_state, org_ref_etag): (CommitStateResponse, String) =
        get_json_with_etag(app.clone(), "/api/v1/org/commit-state").await;
    assert_eq!(org_commit_state.reference.name, "refs/heads/main");
    assert_eq!(org_commit_state.reference.org_id, org_id);
    assert!(org_commit_state.latest.is_some());
    assert_ne!(org_ref_etag, "\"ref-none\"");
    let org_commits: CommitListResponse = get_json(app.clone(), "/api/v1/org/commits").await;
    assert_eq!(org_commits.items.len(), 2);

    let temporary_project: Project = post_json(
        app.clone(),
        "/api/v1/projects",
        &CreateProjectRequest {
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

    let empty_selection: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &format!(
            "/api/v1/projects/{}/org-selections",
            temporary_project.project_id
        ),
        0,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: Vec::new(),
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(empty_selection.revision, 1);
    assert!(empty_selection.context.is_empty());

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

    let (commit_state, initial_head_etag): (CommitStateResponse, String) = get_json_with_etag(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/commit-state"),
    )
    .await;
    let initial_commit_id = commit_state
        .latest
        .expect("selection replacement should create a project commit")
        .commit_id;
    assert!(commit_state.update_available);
    assert_eq!(initial_head_etag, format!("\"{initial_commit_id}\""));

    let draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_test".to_owned(),
            project_id: project_id.clone(),
            base_commit_id: Some(initial_commit_id.clone()),
            title: "Add project context".to_owned(),
            description: Some("First project context entry".to_owned()),
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
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
                scope: ResourceScope::Project,
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

    let draft: DraftDetail = post_json_with_if_match(
        app.clone(),
        &format!("/api/v1/drafts/{}/operations", draft.draft.draft_id),
        draft.draft.version,
        &DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Context,
                id: None,
                path: Some("context/intro.md".to_owned()),
            },
            base_hash: None,
            body: Some("# Intro\n\nUse activated memory before answering.".to_owned()),
            new_path: None,
        },
    )
    .await;
    assert_eq!(draft.draft.version, 4);
    assert_eq!(draft.operations.len(), 2);

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
            daemon_installation_id: "daemon_batch_origin".to_owned(),
            project_id: project_id.clone(),
            base_commit_id: Some(initial_commit_id.clone()),
            title: "Batch draft".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
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
            daemon_installation_id: "daemon_batch".to_owned(),
            operations: vec![DraftOperationBatchItem {
                local_operation_id: "local-op-1".to_owned(),
                draft_id: batch_draft.draft.draft_id.clone(),
                expected_draft_version: batch_draft.draft.version,
                operation: DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
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

    let review_page: ReviewListResponse = get_json(
        app.clone(),
        &format!("/api/v1/reviews?project_id={project_id}"),
    )
    .await;
    assert_eq!(review_page.items.len(), 1);
    assert_eq!(review_page.items[0].review_id, review.review_id);

    let created_comment: ReviewComment = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/comments", review.review_id),
        &CreateReviewCommentRequest {
            body: "Ready to merge".to_owned(),
        },
    )
    .await;
    assert_eq!(created_comment.author.user_id, user_id);

    let comments: ReviewCommentListResponse = get_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/comments", review.review_id),
    )
    .await;
    assert_eq!(comments.items.len(), 1);
    assert_eq!(comments.items[0].body, "Ready to merge");

    let review_detail: ReviewDetail = get_json(
        app.clone(),
        &format!("/api/v1/reviews/{}", review.review_id),
    )
    .await;
    assert_eq!(review_detail.comments, comments.items);

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

    let merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", review.review_id),
        &initial_head_etag,
        &CreateReviewMergeRequest {
            expected_review_version: 2,
        },
    )
    .await;
    assert_eq!(merge.review.status, ReviewStatus::Merged);
    assert_eq!(merge.applied_operation_count, 1);
    let commit_id = merge.commit_id.expect("merge should create a commit");

    let project: Project = get_json(app.clone(), &format!("/api/v1/projects/{project_id}")).await;
    assert_eq!(project.revision, 0);
    let (commit_state, merged_head_etag): (CommitStateResponse, String) = get_json_with_etag(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/commit-state?local_commit_id={initial_commit_id}"),
    )
    .await;
    assert!(commit_state.update_available);
    assert_eq!(
        commit_state
            .latest
            .as_ref()
            .map(|commit| commit.commit_id.as_str()),
        Some(commit_id.as_str())
    );
    assert_eq!(merged_head_etag, format!("\"{commit_id}\""));
    let (current_commit_state, _): (CommitStateResponse, String) = get_json_with_etag(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/commit-state?local_commit_id={commit_id}"),
    )
    .await;
    assert!(!current_commit_state.update_available);

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
            && event.daemon_installation_id.as_deref() == Some("daemon_batch")
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

    let current_selection: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/org-selections"),
        2,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec![org_context_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(current_selection.context.len(), 1);

    let commit: CommitPayload = get_json(app, &format!("/api/v1/commits/{commit_id}")).await;
    assert_eq!(
        commit.commit.project_id.as_deref(),
        Some(project_id.as_str())
    );
    assert_eq!(commit.commit.version, 2);
    assert_eq!(
        commit.commit.parent_commit_id.as_deref(),
        Some(initial_commit_id.as_str())
    );
    let contents = commit
        .blobs
        .iter()
        .map(|item| item.content.as_str())
        .collect::<Vec<_>>();
    assert!(contents.contains(&"# Intro\n\nUse activated memory before answering."));
    assert!(!contents.contains(&"# Intro\n\nUse retrieval before answering."));
    assert!(contents.contains(&"# Org Policy\n\nPrefer concise answers."));
    assert!(
        contents.contains(&"# Org Reference\n\nUse project-specific context after shared context.")
    );
    let selection = commit
        .project_org_selection
        .expect("project commit should include org selection");
    assert_eq!(selection.context.len(), 2);
    assert_eq!(selection.context[0].context_id, org_context_id);
    assert_eq!(selection.context[1].context_id, org_reference_id);
}

#[tokio::test]
async fn org_draft_review_merge_advances_only_the_org_ref() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Project Memory",
        )
        .await
        .unwrap();
    let context_id = repo
        .create_org_resource(
            &bootstrap.org_id,
            DraftResourceKind::Context,
            "context/shared.md",
            "# Shared\n\nBefore review.",
        )
        .await
        .unwrap();
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;
    let context: ContextDetail =
        get_json(app.clone(), &format!("/api/v1/org/context/{context_id}")).await;
    let (org_state, org_ref_etag): (CommitStateResponse, String) =
        get_json_with_etag(app.clone(), "/api/v1/org/commit-state").await;
    let org_base_commit_id = org_state.latest.unwrap().commit_id;

    let draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_org".to_owned(),
            project_id: bootstrap.project_id.clone(),
            base_commit_id: Some(org_base_commit_id.clone()),
            title: "Update shared context".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Org,
                kind: DraftResourceKind::Context,
                id: Some(context_id.clone()),
                path: None,
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Update,
                resource: DraftResourceRef {
                    scope: ResourceScope::Org,
                    kind: DraftResourceKind::Context,
                    id: Some(context_id.clone()),
                    path: None,
                },
                base_hash: Some(context.context.content_hash),
                body: Some("# Shared\n\nAfter review.".to_owned()),
                new_path: None,
            }],
        },
    )
    .await;
    let review: Review = post_json(
        app.clone(),
        "/api/v1/reviews",
        &CreateReviewRequest {
            draft_id: draft.draft.draft_id,
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    let review: Review = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/decisions", review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: review.version,
            body: None,
        },
    )
    .await;
    let merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", review.review_id),
        &org_ref_etag,
        &CreateReviewMergeRequest {
            expected_review_version: review.version,
        },
    )
    .await;
    let commit_id = merge.commit_id.unwrap();

    let updated: ContextDetail =
        get_json(app.clone(), &format!("/api/v1/org/context/{context_id}")).await;
    assert_eq!(updated.body, "# Shared\n\nAfter review.");
    let (org_state, org_ref_etag): (CommitStateResponse, String) =
        get_json_with_etag(app.clone(), "/api/v1/org/commit-state").await;
    assert_eq!(
        org_state.reference.commit_id.as_deref(),
        Some(commit_id.as_str())
    );
    assert_eq!(org_ref_etag, format!("\"{commit_id}\""));
    let project_state: CommitStateResponse = get_json(
        app,
        &format!("/api/v1/projects/{}/commit-state", bootstrap.project_id),
    )
    .await;
    assert_eq!(project_state.reference.commit_id, None);
}

#[tokio::test]
async fn stale_draft_cannot_overwrite_a_new_project_ref() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Concurrent Memory",
        )
        .await
        .unwrap();
    let project_id = bootstrap.project_id;
    let (app, _token) = common::authenticated_router(postgres.pool.clone()).await;

    let first = create_approved_context_review(
        app.clone(),
        &project_id,
        None,
        "context/first.md",
        "# First",
    )
    .await;
    let stale = create_approved_context_review(
        app.clone(),
        &project_id,
        None,
        "context/stale.md",
        "# Stale",
    )
    .await;

    let first_merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", first.review_id),
        "\"ref-none\"",
        &CreateReviewMergeRequest {
            expected_review_version: first.version,
        },
    )
    .await;
    let first_commit_id = first_merge.commit_id.unwrap();

    let current = create_approved_context_review(
        app.clone(),
        &project_id,
        Some(&first_commit_id),
        "context/current.md",
        "# Current",
    )
    .await;
    let wrong_head_body = serde_json::to_vec(&CreateReviewMergeRequest {
        expected_review_version: current.version,
    })
    .unwrap();
    let wrong_head_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/reviews/{}/merges", current.review_id))
                .header("content-type", "application/json")
                .header(
                    "if-match",
                    "\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"",
                )
                .body(Body::from(wrong_head_body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(wrong_head_response.status(), StatusCode::CONFLICT);

    let stale_body = serde_json::to_vec(&CreateReviewMergeRequest {
        expected_review_version: stale.version,
    })
    .unwrap();
    let stale_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/reviews/{}/merges", stale.review_id))
                .header("content-type", "application/json")
                .header("if-match", format!("\"{first_commit_id}\""))
                .body(Body::from(stale_body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(stale_response.status(), StatusCode::CONFLICT);

    let context: ContextListResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/context"),
    )
    .await;
    assert_eq!(context.items.len(), 1);
    assert_eq!(context.items[0].path, "context/first.md");
    let commits: CommitListResponse =
        get_json(app, &format!("/api/v1/projects/{project_id}/commits")).await;
    assert_eq!(commits.items.len(), 1);
    assert_eq!(commits.items[0].commit_id, first_commit_id);
}

async fn create_approved_context_review(
    app: axum::Router,
    project_id: &str,
    base_commit_id: Option<&str>,
    path: &str,
    body: &str,
) -> Review {
    let draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_concurrent".to_owned(),
            project_id: project_id.to_owned(),
            base_commit_id: base_commit_id.map(ToOwned::to_owned),
            title: format!("Create {path}"),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Context,
                id: None,
                path: Some(path.to_owned()),
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Create,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some(path.to_owned()),
                },
                base_hash: None,
                body: Some(body.to_owned()),
                new_path: None,
            }],
        },
    )
    .await;
    let review: Review = post_json(
        app.clone(),
        "/api/v1/reviews",
        &CreateReviewRequest {
            draft_id: draft.draft.draft_id,
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    post_json(
        app,
        &format!("/api/v1/reviews/{}/decisions", review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: review.version,
            body: None,
        },
    )
    .await
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

async fn get_json_with_etag<TResponse>(app: axum::Router, uri: &str) -> (TResponse, String)
where
    TResponse: serde::de::DeserializeOwned,
{
    let response = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let etag = response
        .headers()
        .get("etag")
        .expect("commit state should return ETag")
        .to_str()
        .unwrap()
        .to_owned();
    (decode_json(response).await, etag)
}

async fn post_json_with_etag<TRequest, TResponse>(
    app: axum::Router,
    uri: &str,
    etag: &str,
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
                .header("if-match", etag)
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
