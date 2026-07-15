mod common;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use serde::Serialize;
use server::api::{
    CommitListResponse, CommitPayload, CommitStateResponse, ContextDetail, ContextListResponse,
    CreateDraftRequest, CreateProjectRequest, CreateReviewCommentRequest,
    CreateReviewConflictResolutionRequest, CreateReviewDecisionRequest, CreateReviewMergeRequest,
    CreateReviewRequest, CreateReviewSubmissionRequest, DeleteResult, DraftDetail,
    DraftEventListResponse, DraftEventType, DraftListResponse, DraftOperationAction,
    DraftOperationBatchItem, DraftOperationBatchRequest, DraftOperationBatchResponse,
    DraftOperationInput, DraftResourceContent, DraftResourceKind, DraftResourceRef, DraftStatus,
    MeResponse, PersonalBundleDetail, PersonalBundleRequest, PersonalBundleUpdateRequest, Project,
    ProjectListResponse, ProjectOrgSelection, ReplaceProjectOrgSelectionRequest, ResourceScope,
    Review, ReviewComment, ReviewCommentListResponse, ReviewDecision, ReviewDetail,
    ReviewListResponse, ReviewMergeResult, ReviewStatus, RuleDetail, TreeEntryKind,
    UpdateDraftRequest, UpdateProjectRequest, WorkflowDetail, WorkflowStepInput,
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
        .create_org_context(
            &org_id,
            "context/org-policy.md",
            "# Org Policy\n\nPrefer concise answers.",
        )
        .await
        .unwrap();
    let org_reference_id = repo
        .create_org_context(
            &org_id,
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
    assert_eq!(
        org_context.content,
        "# Org Policy\n\nPrefer concise answers."
    );

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
            content: context_draft_content("# Intro\n\nUse retrieval before answering."),
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
            content: context_draft_content("# Intro\n\nUse activated memory before answering."),
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
                    content: context_draft_content("# Batch\n\nSubmitted from local sync."),
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

    let review_detail: ReviewDetail = post_json(
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
    let review = review_detail.review;
    assert_eq!(review.status, ReviewStatus::Open);
    assert_eq!(review_detail.draft.status, DraftStatus::Submitted);

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

    let review_detail: ReviewDetail = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/decisions", review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: 1,
            body: Some("Looks good".to_owned()),
        },
    )
    .await;
    let review = review_detail.review;
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

    let first_event_page: DraftEventListResponse =
        get_json(app.clone(), "/api/v1/draft-events?limit=1").await;
    assert_eq!(first_event_page.events.len(), 1);
    assert!(first_event_page.has_more);
    let second_event_page: DraftEventListResponse = get_json(
        app.clone(),
        &format!(
            "/api/v1/draft-events?after_cursor={}&limit=1",
            first_event_page.next_cursor.as_ref().unwrap()
        ),
    )
    .await;
    assert_eq!(second_event_page.events.len(), 1);
    assert_ne!(
        second_event_page.events[0].event_id,
        first_event_page.events[0].event_id
    );

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
    assert!(events.events.iter().any(|event| {
        event.event_type == DraftEventType::Updated && event.daemon_installation_id.is_none()
    }));
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
        event.event_type == DraftEventType::Submitted && event.daemon_installation_id.is_none()
    }));
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
        .create_org_context(
            &bootstrap.org_id,
            "context/shared.md",
            "# Shared\n\nBefore review.",
        )
        .await
        .unwrap();
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;
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
                content: context_draft_content("# Shared\n\nAfter review."),
                new_path: None,
            }],
        },
    )
    .await;
    let review: ReviewDetail = post_json(
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
    let review: ReviewDetail = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/decisions", review.review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: review.review.version,
            body: None,
        },
    )
    .await;
    let merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", review.review.review_id),
        &org_ref_etag,
        &CreateReviewMergeRequest {
            expected_review_version: review.review.version,
        },
    )
    .await;
    let commit_id = merge.commit_id.unwrap();

    let updated: ContextDetail =
        get_json(app.clone(), &format!("/api/v1/org/context/{context_id}")).await;
    assert_eq!(updated.content, "# Shared\n\nAfter review.");
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
async fn rejected_review_reopens_its_draft_and_reuses_the_same_review() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Review Lifecycle",
        )
        .await
        .unwrap();
    let member_id = repo
        .create_user("member@example.com", Some("Member"), "member")
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role) VALUES ($1, $2, 'member')",
    )
    .bind(&bootstrap.project_id)
    .bind(&member_id)
    .execute(&postgres.pool)
    .await
    .unwrap();
    let (owner_app, _) = common::authenticated_router(postgres.pool.clone()).await;
    let (member_app, _) = common::authenticated_router_as(
        postgres.pool.clone(),
        "member@example.com",
        "oidc-subject-member",
        "Member",
    )
    .await;

    let draft: DraftDetail = post_json(
        owner_app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_review_lifecycle".to_owned(),
            project_id: bootstrap.project_id.clone(),
            base_commit_id: None,
            title: "Create review lifecycle context".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Context,
                id: None,
                path: Some("context/review-lifecycle.md".to_owned()),
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Create,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some("context/review-lifecycle.md".to_owned()),
                },
                content: context_draft_content("# First submission"),
                new_path: None,
            }],
        },
    )
    .await;
    let submitted: ReviewDetail = post_json(
        owner_app.clone(),
        "/api/v1/reviews",
        &CreateReviewRequest {
            draft_id: draft.draft.draft_id.clone(),
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    assert_eq!(submitted.review.status, ReviewStatus::Open);
    assert_eq!(submitted.review.decision_body, None);
    assert_eq!(submitted.draft.status, DraftStatus::Submitted);
    assert_eq!(submitted.draft.version, 2);
    let visible_to_reviewer: ReviewDetail = get_json(
        member_app.clone(),
        &format!("/api/v1/reviews/{}", submitted.review.review_id),
    )
    .await;
    assert_eq!(
        visible_to_reviewer.review.review_id,
        submitted.review.review_id
    );
    assert_eq!(visible_to_reviewer.operations, submitted.operations);

    let stale_decision = post_response(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/decisions", submitted.review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Rejected,
            expected_review_version: 0,
            body: Some("Stale decision".to_owned()),
        },
    )
    .await;
    assert_eq!(stale_decision.status(), StatusCode::CONFLICT);
    let unchanged: ReviewDetail = get_json(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}", submitted.review.review_id),
    )
    .await;
    assert_eq!(unchanged.review.status, ReviewStatus::Open);
    assert_eq!(unchanged.draft.status, DraftStatus::Submitted);
    assert_eq!(unchanged.draft.version, 2);

    let rejected: ReviewDetail = post_json(
        member_app.clone(),
        &format!("/api/v1/reviews/{}/decisions", submitted.review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Rejected,
            expected_review_version: submitted.review.version,
            body: Some("Add the operational constraint.".to_owned()),
        },
    )
    .await;
    assert_eq!(rejected.review.status, ReviewStatus::Rejected);
    assert_eq!(rejected.review.version, 2);
    assert_eq!(
        rejected.review.decision_body.as_deref(),
        Some("Add the operational constraint.")
    );
    assert_eq!(rejected.draft.status, DraftStatus::Open);
    assert_eq!(rejected.draft.version, 3);

    let edited: DraftDetail = post_json_with_if_match(
        owner_app.clone(),
        &format!("/api/v1/drafts/{}/operations", rejected.draft.draft_id),
        rejected.draft.version,
        &DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: rejected.draft.resource.clone(),
            content: context_draft_content(
                "# Revised submission\n\nApply the operational constraint.",
            ),
            new_path: None,
        },
    )
    .await;
    assert_eq!(edited.draft.status, DraftStatus::Open);
    assert_eq!(edited.draft.version, 4);

    let stale_review_submission = post_response(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &CreateReviewSubmissionRequest {
            expected_review_version: 1,
            expected_draft_version: edited.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    assert_eq!(stale_review_submission.status(), StatusCode::CONFLICT);

    let stale_draft_submission = post_response(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version - 1,
            title: None,
            description: None,
        },
    )
    .await;
    assert_eq!(stale_draft_submission.status(), StatusCode::CONFLICT);

    let member_submission = post_response(
        member_app,
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    assert_eq!(member_submission.status(), StatusCode::FORBIDDEN);
    let still_rejected: ReviewDetail = get_json(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}", rejected.review.review_id),
    )
    .await;
    assert_eq!(still_rejected.review.status, ReviewStatus::Rejected);
    assert_eq!(still_rejected.review.version, rejected.review.version);
    assert_eq!(still_rejected.draft.status, DraftStatus::Open);
    assert_eq!(still_rejected.draft.version, edited.draft.version);

    let resubmitted: ReviewDetail = post_json(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version,
            title: Some("Revised review lifecycle context".to_owned()),
            description: None,
        },
    )
    .await;
    assert_eq!(resubmitted.review.review_id, submitted.review.review_id);
    assert_eq!(resubmitted.review.status, ReviewStatus::Open);
    assert_eq!(resubmitted.review.version, 3);
    assert_eq!(resubmitted.review.title, "Revised review lifecycle context");
    assert_eq!(resubmitted.review.decision_body, None);
    assert_eq!(resubmitted.draft.status, DraftStatus::Submitted);
    assert_eq!(resubmitted.draft.version, 5);
    assert_eq!(resubmitted.operations.len(), 2);

    let duplicate_submission = post_response(
        owner_app.clone(),
        &format!(
            "/api/v1/reviews/{}/submissions",
            resubmitted.review.review_id
        ),
        &CreateReviewSubmissionRequest {
            expected_review_version: resubmitted.review.version,
            expected_draft_version: resubmitted.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    assert_eq!(duplicate_submission.status(), StatusCode::BAD_REQUEST);

    let review_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM reviews WHERE draft_id = $1")
        .bind(&resubmitted.draft.draft_id)
        .fetch_one(&postgres.pool)
        .await
        .unwrap();
    assert_eq!(review_count, 1);
    let events: DraftEventListResponse = get_json(owner_app, "/api/v1/draft-events").await;
    let draft_events = events
        .events
        .iter()
        .filter(|event| event.draft_id == resubmitted.draft.draft_id)
        .collect::<Vec<_>>();
    assert!(draft_events.iter().any(|event| {
        event.event_type == DraftEventType::Reopened && event.version == rejected.draft.version
    }));
    let submitted_versions = draft_events
        .iter()
        .filter(|event| event.event_type == DraftEventType::Submitted)
        .map(|event| event.version)
        .collect::<Vec<_>>();
    assert_eq!(submitted_versions, vec![2, 5]);
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
    let discardable = create_approved_context_review(
        app.clone(),
        &project_id,
        None,
        "context/discarded.md",
        "# Discarded",
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

    let discardable_conflict_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/reviews/{}/merges", discardable.review_id))
                .header("content-type", "application/json")
                .header("if-match", format!("\"{first_commit_id}\""))
                .body(Body::from(
                    serde_json::to_vec(&CreateReviewMergeRequest {
                        expected_review_version: discardable.version,
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(discardable_conflict_response.status(), StatusCode::CONFLICT);
    let discardable_conflict: ReviewDetail = get_json(
        app.clone(),
        &format!("/api/v1/reviews/{}", discardable.review_id),
    )
    .await;
    let _: DeleteResult = delete_json_with_if_match(
        app.clone(),
        &format!("/api/v1/drafts/{}", discardable.draft_id),
        discardable_conflict.draft.version,
    )
    .await;
    let discarded: ReviewDetail = get_json(
        app.clone(),
        &format!("/api/v1/reviews/{}", discardable.review_id),
    )
    .await;
    assert_eq!(discarded.review.status, ReviewStatus::Rejected);
    assert_eq!(discarded.draft.status, DraftStatus::Discarded);
    assert_eq!(discarded.conflict, None);

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
    assert_eq!(
        wrong_head_response.status(),
        StatusCode::PRECONDITION_FAILED
    );
    let wrong_head_error: serde_json::Value = decode_json(wrong_head_response).await;
    assert_eq!(wrong_head_error["error"]["code"], "precondition_failed");
    assert_eq!(
        wrong_head_error["error"]["details"]["current_commit_id"],
        first_commit_id
    );

    let stale_wrong_head_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/reviews/{}/merges", stale.review_id))
                .header("content-type", "application/json")
                .header(
                    "if-match",
                    "\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"",
                )
                .body(Body::from(
                    serde_json::to_vec(&CreateReviewMergeRequest {
                        expected_review_version: stale.version,
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        stale_wrong_head_response.status(),
        StatusCode::PRECONDITION_FAILED
    );
    let unchanged: ReviewDetail =
        get_json(app.clone(), &format!("/api/v1/reviews/{}", stale.review_id)).await;
    assert_eq!(unchanged.draft.status, DraftStatus::Submitted);
    assert_eq!(unchanged.draft.version, 2);
    assert_eq!(unchanged.conflict, None);

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
    let stale_error: serde_json::Value = decode_json(stale_response).await;
    assert_eq!(stale_error["error"]["code"], "draft_conflict");
    assert_eq!(stale_error["error"]["details"]["draft_id"], stale.draft_id);
    assert_eq!(
        stale_error["error"]["details"]["current_commit_id"],
        first_commit_id
    );

    let conflicted: ReviewDetail =
        get_json(app.clone(), &format!("/api/v1/reviews/{}", stale.review_id)).await;
    assert_eq!(conflicted.draft.status, DraftStatus::Conflicted);
    assert_eq!(conflicted.draft.version, 3);
    assert_eq!(
        conflicted
            .conflict
            .as_ref()
            .and_then(|conflict| conflict.current_commit_id.as_deref()),
        Some(first_commit_id.as_str())
    );
    let illegal_reopen_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/v1/drafts/{}", stale.draft_id))
                .header("content-type", "application/json")
                .header("if-match", conflicted.draft.version.to_string())
                .body(Body::from(
                    serde_json::to_vec(&UpdateDraftRequest {
                        title: None,
                        description: None,
                        status: Some(DraftStatus::Open),
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(illegal_reopen_response.status(), StatusCode::BAD_REQUEST);
    let still_conflicted: DraftDetail =
        get_json(app.clone(), &format!("/api/v1/drafts/{}", stale.draft_id)).await;
    assert_eq!(still_conflicted.draft.status, DraftStatus::Conflicted);
    assert_eq!(still_conflicted.draft.version, conflicted.draft.version);
    assert!(still_conflicted.conflict.is_some());
    let events: DraftEventListResponse = get_json(app.clone(), "/api/v1/draft-events").await;
    let conflict_event = events
        .events
        .iter()
        .find(|event| {
            event.draft_id == stale.draft_id && event.event_type == DraftEventType::Conflicted
        })
        .expect("stale merge should emit a conflict event");
    assert_eq!(conflict_event.daemon_installation_id, None);

    let context: ContextListResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/context"),
    )
    .await;
    assert_eq!(context.items.len(), 1);
    assert_eq!(context.items[0].path, "context/first.md");
    let commits: CommitListResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/commits"),
    )
    .await;
    assert_eq!(commits.items.len(), 1);
    assert_eq!(commits.items[0].commit_id, first_commit_id);

    let resolved: ReviewDetail = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/conflict-resolutions", stale.review_id),
        &format!("\"{first_commit_id}\""),
        &CreateReviewConflictResolutionRequest {
            expected_review_version: conflicted.review.version,
            expected_draft_version: conflicted.draft.version,
            operations: conflicted
                .operations
                .iter()
                .map(|operation| operation.input.clone())
                .collect(),
        },
    )
    .await;
    assert_eq!(resolved.review.status, ReviewStatus::Open);
    assert_eq!(resolved.draft.status, DraftStatus::Submitted);
    assert_eq!(
        resolved.draft.base_commit_id.as_deref(),
        Some(first_commit_id.as_str())
    );
    assert_eq!(resolved.conflict, None);

    let approved: ReviewDetail = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/decisions", stale.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: resolved.review.version,
            body: Some("Resolved against the current Commit.".to_owned()),
        },
    )
    .await;
    let merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", stale.review_id),
        &format!("\"{first_commit_id}\""),
        &CreateReviewMergeRequest {
            expected_review_version: approved.review.version,
        },
    )
    .await;
    assert!(merge.commit_id.is_some());
    let context: ContextListResponse =
        get_json(app, &format!("/api/v1/projects/{project_id}/context")).await;
    assert_eq!(context.items.len(), 2);
}

#[tokio::test]
async fn project_org_selection_rejects_foreign_and_colliding_resources_atomically() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Effective Memory",
        )
        .await
        .unwrap();
    let collision_id = repo
        .create_org_context(&bootstrap.org_id, "context/shared.md", "# Shared from Hub")
        .await
        .unwrap();
    let prefix_collision_id = repo
        .create_org_context(
            &bootstrap.org_id,
            "context/manual/chapter.md",
            "# Manual chapter",
        )
        .await
        .unwrap();
    let case_collision_id = repo
        .create_org_context(&bootstrap.org_id, "context/readme.md", "# Lowercase readme")
        .await
        .unwrap();
    let valid_id = repo
        .create_org_context(
            &bootstrap.org_id,
            "context/org-only.md",
            "# Organization only",
        )
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO resources (
            resource_id, org_id, project_id, scope, resource_kind, path, name,
            status, content_hash, body, context_kind
         ) VALUES ($1, $2, $3, 'project', 'context', $4, $5, 'active', $6, $7, 'file')",
    )
    .bind("ctx_project_shared")
    .bind(&bootstrap.org_id)
    .bind(&bootstrap.project_id)
    .bind("context/shared.md")
    .bind("Project shared")
    .bind("project-shared-hash")
    .bind("# Shared from Project")
    .execute(&postgres.pool)
    .await
    .unwrap();
    for (resource_id, path, name) in [
        ("ctx_project_manual", "context/manual", "Project manual"),
        ("ctx_project_readme", "context/README.md", "Project readme"),
    ] {
        sqlx::query(
            "INSERT INTO resources (
                resource_id, org_id, project_id, scope, resource_kind, path, name,
                status, content_hash, body, context_kind
             ) VALUES ($1, $2, $3, 'project', 'context', $4, $5, 'active', $6, $7, 'file')",
        )
        .bind(resource_id)
        .bind(&bootstrap.org_id)
        .bind(&bootstrap.project_id)
        .bind(path)
        .bind(name)
        .bind(format!("{resource_id}-hash"))
        .bind(format!("# {name}"))
        .execute(&postgres.pool)
        .await
        .unwrap();
    }

    let foreign_org_id = repo.create_org("Foreign Memory").await.unwrap();
    let foreign_context_id = repo
        .create_org_context(
            &foreign_org_id,
            "context/foreign.md",
            "# Foreign organization",
        )
        .await
        .unwrap();
    let (app, _token) = common::authenticated_router(postgres.pool.clone()).await;
    let selection_uri = format!("/api/v1/projects/{}/org-selections", bootstrap.project_id);
    let before: ProjectOrgSelection = get_json(app.clone(), &selection_uri).await;
    let before_state: CommitStateResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{}/commit-state", bootstrap.project_id),
    )
    .await;

    for collision_id in [collision_id, prefix_collision_id, case_collision_id] {
        let collision_response = put_response_with_if_match(
            app.clone(),
            &selection_uri,
            before.revision,
            &ReplaceProjectOrgSelectionRequest {
                rule_ids: Vec::new(),
                context_ids: vec![collision_id],
                workflow_ids: Vec::new(),
            },
        )
        .await;
        assert_eq!(collision_response.status(), StatusCode::BAD_REQUEST);
        let collision_error: serde_json::Value = decode_json(collision_response).await;
        assert!(
            collision_error["error"]["message"]
                .as_str()
                .unwrap()
                .contains("materializes")
        );
    }

    let foreign_response = put_response_with_if_match(
        app.clone(),
        &selection_uri,
        before.revision,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec![foreign_context_id],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(foreign_response.status(), StatusCode::NOT_FOUND);

    let after_failures: ProjectOrgSelection = get_json(app.clone(), &selection_uri).await;
    assert_eq!(after_failures.revision, before.revision);
    assert!(after_failures.context.is_empty());
    let state_after_failures: CommitStateResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{}/commit-state", bootstrap.project_id),
    )
    .await;
    assert_eq!(
        state_after_failures.reference.commit_id,
        before_state.reference.commit_id
    );

    let selected: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &selection_uri,
        before.revision,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec![valid_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(selected.revision, before.revision + 1);
    let selected_state: CommitStateResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{}/commit-state", bootstrap.project_id),
    )
    .await;
    let commit_id = selected_state.reference.commit_id.unwrap();
    let commit: CommitPayload = get_json(app, &format!("/api/v1/commits/{commit_id}")).await;
    assert!(commit.tree.entries.iter().any(|entry| entry.id == valid_id));
}

#[tokio::test]
async fn project_org_selection_cannot_remove_a_rule_used_by_effective_workflow() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Workflow Memory",
        )
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO resources (
            resource_id, org_id, project_id, scope, resource_kind, path, name,
            status, content_hash, body
         ) VALUES ($1, $2, NULL, 'org', 'rule', $3, $4, 'active', $5, $6)",
    )
    .bind("rul_shared_dependency")
    .bind(&bootstrap.org_id)
    .bind("rules/shared-dependency")
    .bind("Shared dependency")
    .bind("shared-rule-hash")
    .bind("Use the shared dependency.")
    .execute(&postgres.pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO resources (
            resource_id, org_id, project_id, scope, resource_kind, path, name,
            status, content_hash, body
         ) VALUES ($1, $2, $3, 'project', 'workflow', $4, $5, 'active', $6, $7)",
    )
    .bind("wfl_project_dependency")
    .bind(&bootstrap.org_id)
    .bind(&bootstrap.project_id)
    .bind("workflow/dependency")
    .bind("Dependency workflow")
    .bind("workflow-hash")
    .bind("Uses a shared Rule.")
    .execute(&postgres.pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO workflow_steps (resource_id, step_order, rule_id, body)
         VALUES ($1, 1, $2, NULL)",
    )
    .bind("wfl_project_dependency")
    .bind("rul_shared_dependency")
    .execute(&postgres.pool)
    .await
    .unwrap();

    let (app, _token) = common::authenticated_router(postgres.pool.clone()).await;
    let selection_uri = format!("/api/v1/projects/{}/org-selections", bootstrap.project_id);
    let selected: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &selection_uri,
        0,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: vec!["rul_shared_dependency".to_owned()],
            context_ids: Vec::new(),
            workflow_ids: Vec::new(),
        },
    )
    .await;
    let state_before: CommitStateResponse = get_json(
        app.clone(),
        &format!("/api/v1/projects/{}/commit-state", bootstrap.project_id),
    )
    .await;

    let response = put_response_with_if_match(
        app.clone(),
        &selection_uri,
        selected.revision,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: Vec::new(),
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let error: serde_json::Value = decode_json(response).await;
    assert!(
        error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not available in project effective memory")
    );
    let selection_after: ProjectOrgSelection = get_json(app.clone(), &selection_uri).await;
    assert_eq!(selection_after.revision, selected.revision);
    assert_eq!(selection_after.rules.len(), 1);
    let state_after: CommitStateResponse = get_json(
        app,
        &format!("/api/v1/projects/{}/commit-state", bootstrap.project_id),
    )
    .await;
    assert_eq!(
        state_after.reference.commit_id,
        state_before.reference.commit_id
    );
}

#[tokio::test]
async fn invalid_memory_shapes_are_rejected_before_draft_storage() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Path Validation",
        )
        .await
        .unwrap();
    let (app, _token) = common::authenticated_router(postgres.pool.clone()).await;
    let invalid_workflow = CreateDraftRequest {
        daemon_installation_id: "daemon_paths".to_owned(),
        project_id: bootstrap.project_id.clone(),
        base_commit_id: None,
        title: "Invalid Workflow path".to_owned(),
        description: None,
        resource: DraftResourceRef {
            scope: ResourceScope::Project,
            kind: DraftResourceKind::Workflow,
            id: None,
            path: Some("workflows/invalid".to_owned()),
        },
        operations: vec![DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Workflow,
                id: None,
                path: Some("workflows/invalid".to_owned()),
            },
            content: Some(DraftResourceContent::Workflow {
                name: Some("Invalid Workflow".to_owned()),
                description: String::new(),
                steps: vec![WorkflowStepInput {
                    rule_id: None,
                    body: Some("Run the step.".to_owned()),
                }],
            }),
            new_path: None,
        }],
    };
    assert_eq!(
        post_response(app.clone(), "/api/v1/drafts", &invalid_workflow)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    let invalid_empty_draft = CreateDraftRequest {
        daemon_installation_id: "daemon_paths".to_owned(),
        project_id: bootstrap.project_id.clone(),
        base_commit_id: None,
        title: "Invalid empty Workflow draft".to_owned(),
        description: None,
        resource: DraftResourceRef {
            scope: ResourceScope::Project,
            kind: DraftResourceKind::Workflow,
            id: None,
            path: Some("workflows/empty".to_owned()),
        },
        operations: Vec::new(),
    };
    assert_eq!(
        post_response(app.clone(), "/api/v1/drafts", &invalid_empty_draft)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    let empty_workflow = CreateDraftRequest {
        daemon_installation_id: "daemon_paths".to_owned(),
        project_id: bootstrap.project_id.clone(),
        base_commit_id: None,
        title: "Empty Workflow".to_owned(),
        description: None,
        resource: DraftResourceRef {
            scope: ResourceScope::Project,
            kind: DraftResourceKind::Workflow,
            id: None,
            path: Some("workflow/empty".to_owned()),
        },
        operations: vec![DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Workflow,
                id: None,
                path: Some("workflow/empty".to_owned()),
            },
            content: Some(DraftResourceContent::Workflow {
                name: Some("Empty Workflow".to_owned()),
                description: String::new(),
                steps: Vec::new(),
            }),
            new_path: None,
        }],
    };
    assert_eq!(
        post_response(app.clone(), "/api/v1/drafts", &empty_workflow)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    let empty_rule = CreateDraftRequest {
        daemon_installation_id: "daemon_paths".to_owned(),
        project_id: bootstrap.project_id.clone(),
        base_commit_id: None,
        title: "Empty Rule".to_owned(),
        description: None,
        resource: DraftResourceRef {
            scope: ResourceScope::Project,
            kind: DraftResourceKind::Rule,
            id: None,
            path: Some("rules/empty".to_owned()),
        },
        operations: vec![DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Rule,
                id: None,
                path: Some("rules/empty".to_owned()),
            },
            content: Some(DraftResourceContent::Rule {
                name: Some("Empty Rule".to_owned()),
                applies_when: None,
                constraint: "  ".to_owned(),
                tags: None,
            }),
            new_path: None,
        }],
    };
    assert_eq!(
        post_response(app.clone(), "/api/v1/drafts", &empty_rule)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    let invalid_context_path = CreateDraftRequest {
        daemon_installation_id: "daemon_paths".to_owned(),
        project_id: bootstrap.project_id.clone(),
        base_commit_id: None,
        title: "Invalid Context path".to_owned(),
        description: None,
        resource: DraftResourceRef {
            scope: ResourceScope::Project,
            kind: DraftResourceKind::Context,
            id: None,
            path: Some("context//invalid.md".to_owned()),
        },
        operations: vec![DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Context,
                id: None,
                path: Some("context//invalid.md".to_owned()),
            },
            content: Some(DraftResourceContent::Context {
                content: "# Invalid".to_owned(),
            }),
            new_path: None,
        }],
    };
    assert_eq!(
        post_response(app.clone(), "/api/v1/drafts", &invalid_context_path)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    let invalid_metaprompt = CreateDraftRequest {
        daemon_installation_id: "daemon_paths".to_owned(),
        project_id: bootstrap.project_id,
        base_commit_id: None,
        title: "Invalid Metaprompt path".to_owned(),
        description: None,
        resource: DraftResourceRef {
            scope: ResourceScope::Project,
            kind: DraftResourceKind::Metaprompt,
            id: None,
            path: Some("prompts/META_PROMPT.md".to_owned()),
        },
        operations: vec![DraftOperationInput {
            action: DraftOperationAction::Create,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Metaprompt,
                id: None,
                path: Some("prompts/META_PROMPT.md".to_owned()),
            },
            content: Some(DraftResourceContent::Metaprompt {
                content: "# Metaprompt".to_owned(),
            }),
            new_path: None,
        }],
    };
    assert_eq!(
        post_response(app, "/api/v1/drafts", &invalid_metaprompt)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let draft_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM drafts")
        .fetch_one(&postgres.pool)
        .await
        .unwrap();
    assert_eq!(draft_count, 0);
}

#[tokio::test]
async fn structured_rule_and_workflow_survive_draft_review_and_commit_round_trip() {
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
    let project_id = bootstrap.project_id;
    let (app, _token) = common::authenticated_router(postgres.pool.clone()).await;
    let (initial_state, initial_etag): (CommitStateResponse, String) = get_json_with_etag(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/commit-state"),
    )
    .await;

    let rule_draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_structured".to_owned(),
            project_id: project_id.clone(),
            base_commit_id: initial_state.latest.map(|commit| commit.commit_id),
            title: "Add coding rule".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Rule,
                id: None,
                path: Some("rules/coding".to_owned()),
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Create,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Rule,
                    id: None,
                    path: Some("rules/coding".to_owned()),
                },
                content: Some(DraftResourceContent::Rule {
                    name: Some("Coding discipline".to_owned()),
                    applies_when: Some("While changing production code".to_owned()),
                    constraint: "Run the focused tests before committing.".to_owned(),
                    tags: Some(vec!["quality".to_owned(), "coding".to_owned()]),
                }),
                new_path: None,
            }],
        },
    )
    .await;
    let rule_review: ReviewDetail = post_json(
        app.clone(),
        "/api/v1/reviews",
        &CreateReviewRequest {
            draft_id: rule_draft.draft.draft_id,
            expected_draft_version: rule_draft.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    let approved_rule: ReviewDetail = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{}/decisions", rule_review.review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: rule_review.review.version,
            body: None,
        },
    )
    .await;
    let rule_merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", approved_rule.review.review_id),
        &initial_etag,
        &CreateReviewMergeRequest {
            expected_review_version: approved_rule.review.version,
        },
    )
    .await;
    let rule_commit_id = rule_merge
        .commit_id
        .expect("rule merge should create a Commit");
    let rule_commit: CommitPayload =
        get_json(app.clone(), &format!("/api/v1/commits/{rule_commit_id}")).await;
    let rule_entry = rule_commit
        .tree
        .entries
        .iter()
        .find(|entry| entry.kind == TreeEntryKind::Rule)
        .expect("rule Commit should contain the Rule");
    let rule_id = rule_entry.id.clone();
    let rule: RuleDetail = get_json(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/rules/{rule_id}"),
    )
    .await;
    assert_eq!(rule.rule.name, "Coding discipline");
    assert_eq!(rule.content.applies_when, "While changing production code");
    assert_eq!(
        rule.content.constraint,
        "Run the focused tests before committing."
    );
    assert_eq!(rule.content.tags, vec!["coding", "quality"]);
    let rule_blob = rule_commit
        .blobs
        .iter()
        .find(|blob| blob.blob_id == rule_entry.blob_id)
        .expect("rule Blob should be present");
    let encoded_rule: serde_json::Value = serde_json::from_str(&rule_blob.content).unwrap();
    assert_eq!(encoded_rule["format"], "clumsies.rule.v1");
    assert_eq!(encoded_rule["content"]["name"], "Coding discipline");

    let (_, rule_ref_etag): (CommitStateResponse, String) = get_json_with_etag(
        app.clone(),
        &format!("/api/v1/projects/{project_id}/commit-state"),
    )
    .await;
    let workflow_draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_structured".to_owned(),
            project_id: project_id.clone(),
            base_commit_id: Some(rule_commit_id),
            title: "Add coding workflow".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Workflow,
                id: None,
                path: Some("workflow/coding".to_owned()),
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Create,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Workflow,
                    id: None,
                    path: Some("workflow/coding".to_owned()),
                },
                content: Some(DraftResourceContent::Workflow {
                    name: Some("Coding workflow".to_owned()),
                    description: "Prepare a production change.".to_owned(),
                    steps: vec![
                        WorkflowStepInput {
                            rule_id: Some(rule_id.clone()),
                            body: None,
                        },
                        WorkflowStepInput {
                            rule_id: None,
                            body: Some("Summarize verification evidence.".to_owned()),
                        },
                    ],
                }),
                new_path: None,
            }],
        },
    )
    .await;
    let workflow_review: ReviewDetail = post_json(
        app.clone(),
        "/api/v1/reviews",
        &CreateReviewRequest {
            draft_id: workflow_draft.draft.draft_id,
            expected_draft_version: workflow_draft.draft.version,
            title: None,
            description: None,
        },
    )
    .await;
    let approved_workflow: ReviewDetail = post_json(
        app.clone(),
        &format!(
            "/api/v1/reviews/{}/decisions",
            workflow_review.review.review_id
        ),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: workflow_review.review.version,
            body: None,
        },
    )
    .await;
    let workflow_merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!(
            "/api/v1/reviews/{}/merges",
            approved_workflow.review.review_id
        ),
        &rule_ref_etag,
        &CreateReviewMergeRequest {
            expected_review_version: approved_workflow.review.version,
        },
    )
    .await;
    let workflow_commit_id = workflow_merge
        .commit_id
        .expect("workflow merge should create a Commit");
    let workflow_commit: CommitPayload = get_json(
        app.clone(),
        &format!("/api/v1/commits/{workflow_commit_id}"),
    )
    .await;
    let workflow_entry = workflow_commit
        .tree
        .entries
        .iter()
        .find(|entry| entry.kind == TreeEntryKind::Workflow)
        .expect("workflow Commit should contain the Workflow");
    let workflow: WorkflowDetail = get_json(
        app,
        &format!(
            "/api/v1/projects/{project_id}/workflows/{}",
            workflow_entry.id
        ),
    )
    .await;
    assert_eq!(workflow.workflow.name, "Coding workflow");
    assert_eq!(workflow.content.description, "Prepare a production change.");
    assert_eq!(workflow.content.steps.len(), 2);
    assert_eq!(workflow.content.steps[0].order, 1);
    assert_eq!(
        workflow.content.steps[0].rule_id.as_deref(),
        Some(rule_id.as_str())
    );
    assert_eq!(
        workflow.content.steps[1].body.as_deref(),
        Some("Summarize verification evidence.")
    );
    let workflow_blob = workflow_commit
        .blobs
        .iter()
        .find(|blob| blob.blob_id == workflow_entry.blob_id)
        .expect("workflow Blob should be present");
    let encoded_workflow: serde_json::Value = serde_json::from_str(&workflow_blob.content).unwrap();
    assert_eq!(encoded_workflow["format"], "clumsies.workflow.v1");
    assert_eq!(encoded_workflow["content"]["steps"][0]["rule_id"], rule_id);
}

fn context_draft_content(content: &str) -> Option<DraftResourceContent> {
    Some(DraftResourceContent::Context {
        content: content.to_owned(),
    })
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
                content: context_draft_content(body),
                new_path: None,
            }],
        },
    )
    .await;
    let review: ReviewDetail = post_json(
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
    let approved: ReviewDetail = post_json(
        app,
        &format!("/api/v1/reviews/{}/decisions", review.review.review_id),
        &CreateReviewDecisionRequest {
            decision: ReviewDecision::Approved,
            expected_review_version: review.review.version,
            body: None,
        },
    )
    .await;
    approved.review
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

async fn post_response<TRequest>(
    app: axum::Router,
    uri: &str,
    request: &TRequest,
) -> axum::response::Response
where
    TRequest: Serialize,
{
    app.oneshot(
        Request::builder()
            .method("POST")
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_vec(request).unwrap()))
            .unwrap(),
    )
    .await
    .unwrap()
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

async fn put_response_with_if_match<TRequest>(
    app: axum::Router,
    uri: &str,
    expected_version: i64,
    request: &TRequest,
) -> axum::response::Response
where
    TRequest: Serialize,
{
    app.oneshot(
        Request::builder()
            .method("PUT")
            .uri(uri)
            .header("content-type", "application/json")
            .header("if-match", expected_version.to_string())
            .body(Body::from(serde_json::to_vec(request).unwrap()))
            .unwrap(),
    )
    .await
    .unwrap()
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
