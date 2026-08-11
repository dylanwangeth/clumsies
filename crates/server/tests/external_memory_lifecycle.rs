mod common;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use serde::Serialize;
use server::api::{
    CommitListResponse, CommitPayload, CommitStateResponse, ContextDetail, ContextListResponse,
    CreateDraftRebaseRequest, CreateDraftRequest, CreateProjectRequest, CreateReviewCommentRequest,
    CreateReviewDecisionRequest, CreateReviewMergeRequest, CreateReviewRequest,
    CreateReviewSubmissionRequest, DeleteResult, DraftDetail, DraftEventListResponse,
    DraftEventType, DraftFreshness, DraftListResponse, DraftOperationAction,
    DraftOperationBatchItem, DraftOperationBatchRequest, DraftOperationBatchResponse,
    DraftOperationInput, DraftRebaseResult, DraftReconciliationCandidate,
    DraftReconciliationStatus, DraftResourceContent, DraftResourceKind, DraftResourceRef,
    DraftStatus, MeResponse, PersonalBundleDetail, PersonalBundleRequest,
    PersonalBundleUpdateRequest, Project, ProjectListResponse, ProjectOrgSelection,
    ReconciliationCandidateStatus, ReplaceProjectOrgSelectionRequest, ResourceScope, Review,
    ReviewComment, ReviewCommentListResponse, ReviewDecision, ReviewDetail, ReviewListResponse,
    ReviewMergeResult, ReviewStatus, RuleDetail, TreeEntryKind, UpdateDraftRequest,
    UpdateProjectRequest, WorkflowDetail,
};
use server::repository::ServerRepository;
use tower::ServiceExt;

#[tokio::test]
async fn draft_created_resource_must_be_discarded_instead_of_deleted() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Draft normalization",
    )
    .await;
    let resource = DraftResourceRef {
        scope: ResourceScope::Project,
        kind: DraftResourceKind::Rule,
        id: None,
        path: Some("rules/new-rule.md".to_owned()),
    };
    let create = DraftOperationInput {
        action: DraftOperationAction::Create,
        resource: resource.clone(),
        content: Some(DraftResourceContent::Rule {
            content: "# New rule".to_owned(),
        }),
        new_path: None,
    };
    let delete = DraftOperationInput {
        action: DraftOperationAction::Delete,
        resource: resource.clone(),
        content: None,
        new_path: None,
    };

    let invalid_create = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_normalization".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: None,
                title: "Invalid create and delete".to_owned(),
                description: None,
                resource: resource.clone(),
                operations: vec![create.clone(), delete.clone()],
            },
        )
        .await
        .unwrap_err();
    assert!(
        invalid_create
            .to_string()
            .contains("must be discarded instead of deleted")
    );

    let draft = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_normalization".to_owned(),
                project_id: bootstrap.project_id,
                base_commit_id: None,
                title: "Create a new rule".to_owned(),
                description: None,
                resource,
                operations: vec![create],
            },
        )
        .await
        .unwrap();
    let invalid_append = repo
        .append_draft_operation(&draft.draft.draft_id, draft.draft.version, delete)
        .await
        .unwrap_err();
    assert!(
        invalid_append
            .to_string()
            .contains("must be discarded instead of deleted")
    );

    repo.discard_draft(
        &draft.draft.draft_id,
        &bootstrap.user_id,
        draft.draft.version,
    )
    .await
    .unwrap();
    let discarded = repo.get_draft(&draft.draft.draft_id).await.unwrap();
    assert_eq!(discarded.draft.status, DraftStatus::Discarded);
}

#[tokio::test]
async fn draft_review_merge_produces_project_commit() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Search Agent",
    )
    .await;
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
    let initial_commit = commit_state
        .latest
        .expect("selection replacement should create a project commit");
    let initial_commit_id = initial_commit.commit_id;
    let initial_commit_version = initial_commit.version;
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

    let review_detail = create_review_for_draft(app.clone(), &draft).await;
    let review = review_detail.review;
    assert_eq!(review.status, ReviewStatus::Open);
    assert_eq!(review.decided_by, None);
    assert_eq!(review.decided_at, None);
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
        &serde_json::json!({
            "body": "Ready to merge",
            "expected_review_version": review.version
        }),
    )
    .await;
    assert_eq!(created_comment.author.user_id, user_id);
    assert_eq!(created_comment.anchor_path, None);
    assert_eq!(created_comment.anchor_line, None);
    assert_eq!(created_comment.review_version, review.version);

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
    assert_eq!(
        review.decided_by.as_ref().map(|user| user.user_id.as_str()),
        Some(user_id.as_str())
    );
    assert_eq!(
        review
            .decided_by
            .as_ref()
            .and_then(|user| user.display_name.as_deref()),
        Some("Owner")
    );
    let approved_at = review.decided_at.expect("approval time should be recorded");
    let incomplete_decision_metadata =
        sqlx::query("UPDATE reviews SET decided_by_user_id = NULL WHERE review_id = $1")
            .bind(&review.review_id)
            .execute(&postgres.pool)
            .await;
    assert!(incomplete_decision_metadata.is_err());

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
    assert_eq!(merge.review.decided_by, review.decided_by);
    assert_eq!(merge.review.decided_at, Some(approved_at));
    assert_eq!(merge.applied_operation_count, 1);
    let commit_id = merge.commit_id.expect("merge should create a commit");
    let merged_draft: DraftDetail = get_json(
        app.clone(),
        &format!("/api/v1/drafts/{}", draft.draft.draft_id),
    )
    .await;
    assert_eq!(merged_draft.draft.status, DraftStatus::Merged);
    assert_eq!(merged_draft.draft.version, draft.draft.version + 2);

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

    let invalid_bundle = post_response(
        app.clone(),
        "/api/v1/me/bundles",
        &PersonalBundleRequest {
            name: "Invalid project memory".to_owned(),
            description: None,
            rule_ids: Vec::new(),
            context_ids: vec![project_context_page.items[0].context_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(invalid_bundle.status(), StatusCode::NOT_FOUND);

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
        event.event_type == DraftEventType::Merged && event.daemon_installation_id.is_none()
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
    assert_eq!(commit.commit.version, initial_commit_version + 1);
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
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Project Memory",
    )
    .await;
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
    let review = create_review_for_draft(app.clone(), &draft).await;
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
async fn selected_org_context_changes_rebuild_only_affected_project_commits() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Selected Hub Memory",
    )
    .await;
    let context_id = repo
        .create_org_context(
            &bootstrap.org_id,
            "context/shared.md",
            "# Shared\n\nBefore review.",
        )
        .await
        .unwrap();
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;
    let primary_selection_uri = format!("/api/v1/projects/{}/org-selections", bootstrap.project_id);
    let selected: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &primary_selection_uri,
        0,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec![context_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    let primary_state_uri = format!("/api/v1/projects/{}/commit-state", bootstrap.project_id);
    let primary_before: CommitStateResponse = get_json(app.clone(), &primary_state_uri).await;
    let primary_before_id = primary_before.reference.commit_id.unwrap();

    let secondary: Project = post_json(
        app.clone(),
        "/api/v1/projects",
        &CreateProjectRequest {
            name: "Unrelated Project".to_owned(),
            description: None,
        },
    )
    .await;
    let secondary_selection_uri =
        format!("/api/v1/projects/{}/org-selections", secondary.project_id);
    let _: ProjectOrgSelection = put_json_with_if_match(
        app.clone(),
        &secondary_selection_uri,
        0,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: Vec::new(),
            workflow_ids: Vec::new(),
        },
    )
    .await;
    let secondary_state_uri = format!("/api/v1/projects/{}/commit-state", secondary.project_id);
    let secondary_before: CommitStateResponse = get_json(app.clone(), &secondary_state_uri).await;

    let (org_before, org_etag): (CommitStateResponse, String) =
        get_json_with_etag(app.clone(), "/api/v1/org/commit-state").await;
    let approved = create_approved_review(
        app.clone(),
        CreateDraftRequest {
            daemon_installation_id: "daemon_hub_context".to_owned(),
            project_id: bootstrap.project_id.clone(),
            base_commit_id: org_before.reference.commit_id,
            title: "Update shared context".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Org,
                kind: DraftResourceKind::Context,
                id: Some(context_id.clone()),
                path: None,
            },
            operations: vec![
                DraftOperationInput {
                    action: DraftOperationAction::Update,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Org,
                        kind: DraftResourceKind::Context,
                        id: Some(context_id.clone()),
                        path: None,
                    },
                    content: context_draft_content("# Shared\n\nAfter review."),
                    new_path: None,
                },
                DraftOperationInput {
                    action: DraftOperationAction::Rename,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Org,
                        kind: DraftResourceKind::Context,
                        id: Some(context_id.clone()),
                        path: None,
                    },
                    content: None,
                    new_path: Some("context/shared-updated.md".to_owned()),
                },
            ],
        },
    )
    .await;
    let _: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", approved.review_id),
        &org_etag,
        &CreateReviewMergeRequest {
            expected_review_version: approved.version,
        },
    )
    .await;

    let primary_after: CommitStateResponse = get_json(app.clone(), &primary_state_uri).await;
    let primary_after_id = primary_after.reference.commit_id.unwrap();
    assert_ne!(primary_after_id, primary_before_id);
    assert_eq!(
        primary_after.latest.unwrap().parent_commit_id.as_deref(),
        Some(primary_before_id.as_str())
    );
    let secondary_after: CommitStateResponse = get_json(app.clone(), &secondary_state_uri).await;
    assert_eq!(
        secondary_after.reference.commit_id,
        secondary_before.reference.commit_id
    );
    let selection_after_update: ProjectOrgSelection =
        get_json(app.clone(), &primary_selection_uri).await;
    assert_eq!(selection_after_update.revision, selected.revision);
    assert_eq!(selection_after_update.context.len(), 1);

    let old_payload: CommitPayload =
        get_json(app.clone(), &format!("/api/v1/commits/{primary_before_id}")).await;
    let old_entry = old_payload
        .tree
        .entries
        .iter()
        .find(|entry| entry.id == context_id)
        .unwrap();
    assert_eq!(old_entry.path.as_deref(), Some("context/shared.md"));
    assert_eq!(
        old_payload
            .blobs
            .iter()
            .find(|blob| blob.blob_id == old_entry.blob_id)
            .unwrap()
            .content,
        "# Shared\n\nBefore review."
    );
    let updated_payload: CommitPayload =
        get_json(app.clone(), &format!("/api/v1/commits/{primary_after_id}")).await;
    let updated_entry = updated_payload
        .tree
        .entries
        .iter()
        .find(|entry| entry.id == context_id)
        .unwrap();
    assert_eq!(
        updated_entry.path.as_deref(),
        Some("context/shared-updated.md")
    );
    assert_eq!(
        updated_payload
            .blobs
            .iter()
            .find(|blob| blob.blob_id == updated_entry.blob_id)
            .unwrap()
            .content,
        "# Shared\n\nAfter review."
    );

    let (org_after_update, org_etag): (CommitStateResponse, String) =
        get_json_with_etag(app.clone(), "/api/v1/org/commit-state").await;
    let approved = create_approved_review(
        app.clone(),
        CreateDraftRequest {
            daemon_installation_id: "daemon_hub_context".to_owned(),
            project_id: bootstrap.project_id.clone(),
            base_commit_id: org_after_update.reference.commit_id,
            title: "Delete shared context".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Org,
                kind: DraftResourceKind::Context,
                id: Some(context_id.clone()),
                path: None,
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Delete,
                resource: DraftResourceRef {
                    scope: ResourceScope::Org,
                    kind: DraftResourceKind::Context,
                    id: Some(context_id.clone()),
                    path: None,
                },
                content: None,
                new_path: None,
            }],
        },
    )
    .await;
    let _: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", approved.review_id),
        &org_etag,
        &CreateReviewMergeRequest {
            expected_review_version: approved.version,
        },
    )
    .await;

    let selection_after_delete: ProjectOrgSelection =
        get_json(app.clone(), &primary_selection_uri).await;
    assert_eq!(
        selection_after_delete.revision,
        selection_after_update.revision + 1
    );
    assert!(selection_after_delete.context.is_empty());
    let primary_after_delete: CommitStateResponse = get_json(app.clone(), &primary_state_uri).await;
    let primary_after_delete_id = primary_after_delete.reference.commit_id.unwrap();
    assert_ne!(primary_after_delete_id, primary_after_id);
    let deleted_payload: CommitPayload = get_json(
        app.clone(),
        &format!("/api/v1/commits/{primary_after_delete_id}"),
    )
    .await;
    assert!(
        deleted_payload
            .tree
            .entries
            .iter()
            .all(|entry| entry.id != context_id)
    );
    let secondary_after_delete: CommitStateResponse = get_json(app, &secondary_state_uri).await;
    assert_eq!(
        secondary_after_delete.reference.commit_id,
        secondary_before.reference.commit_id
    );
}

#[tokio::test]
async fn invalid_org_projection_rolls_back_authority_and_every_ref() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Projection Rollback",
    )
    .await;
    let context_id = repo
        .create_org_context(&bootstrap.org_id, "context/shared.md", "# Shared authority")
        .await
        .unwrap();
    repo.replace_project_org_selection(
        &bootstrap.project_id,
        0,
        ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec![context_id.clone()],
            workflow_ids: Vec::new(),
        },
    )
    .await
    .unwrap();

    let initial_project_head = repo
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    let project_draft = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_projection_rollback".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: initial_project_head.clone(),
                title: "Create colliding project context".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some("context/collision.md".to_owned()),
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
                        kind: DraftResourceKind::Context,
                        id: None,
                        path: Some("context/collision.md".to_owned()),
                    },
                    content: context_draft_content("# Project context"),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let project_review = repo
        .create_review(
            &bootstrap.user_id,
            initial_project_head.as_deref(),
            CreateReviewRequest {
                draft_id: project_draft.draft.draft_id,
                expected_draft_version: project_draft.draft.version,
                title: None,
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let project_review = repo
        .create_review_decision(
            &project_review.review.review_id,
            &project_review.review.author.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: project_review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    repo.create_review_merge(
        &project_review.review.review_id,
        initial_project_head.as_deref(),
        CreateReviewMergeRequest {
            expected_review_version: project_review.review.version,
        },
    )
    .await
    .unwrap();

    let org_head_before = repo
        .get_org_commit_state(&bootstrap.org_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    let project_head_before = repo
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    let org_draft = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_projection_rollback".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: org_head_before.clone(),
                title: "Create an invalid Hub projection".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Org,
                    kind: DraftResourceKind::Context,
                    id: Some(context_id.clone()),
                    path: None,
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Rename,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Org,
                        kind: DraftResourceKind::Context,
                        id: Some(context_id.clone()),
                        path: None,
                    },
                    content: None,
                    new_path: Some("context/collision.md".to_owned()),
                }],
            },
        )
        .await
        .unwrap();
    let org_review = repo
        .create_review(
            &bootstrap.user_id,
            org_head_before.as_deref(),
            CreateReviewRequest {
                draft_id: org_draft.draft.draft_id,
                expected_draft_version: org_draft.draft.version,
                title: None,
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let org_review = repo
        .create_review_decision(
            &org_review.review.review_id,
            &org_review.review.author.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: org_review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    let error = repo
        .create_review_merge(
            &org_review.review.review_id,
            org_head_before.as_deref(),
            CreateReviewMergeRequest {
                expected_review_version: org_review.review.version,
            },
        )
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        server::repository::ServerError::InvalidRequest(ref message)
            if message.contains("materializes")
    ));

    let org_head_after = repo
        .get_org_commit_state(&bootstrap.org_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    let project_head_after = repo
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    assert_eq!(org_head_after, org_head_before);
    assert_eq!(project_head_after, project_head_before);
    assert_eq!(
        repo.get_org_context(&bootstrap.org_id, &context_id)
            .await
            .unwrap()
            .context
            .path,
        "context/shared.md"
    );
    assert_eq!(
        repo.get_review(&org_review.review.review_id)
            .await
            .unwrap()
            .status,
        ReviewStatus::Approved
    );
}

#[tokio::test]
async fn rejected_review_reopens_its_draft_and_reuses_the_same_review() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Review Lifecycle",
    )
    .await;
    let member_id = "usr_review_member".to_owned();
    sqlx::query(
        "INSERT INTO users (user_id, email, display_name, role, status)
         VALUES ($1, 'member@example.com', 'Member', 'member', 'active')",
    )
    .bind(&member_id)
    .execute(&postgres.pool)
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
    let submitted = create_review_for_draft(owner_app.clone(), &draft).await;
    assert_eq!(submitted.review.status, ReviewStatus::Open);
    assert_eq!(submitted.review.decision_body, None);
    assert_eq!(submitted.review.decided_by, None);
    assert_eq!(submitted.review.decided_at, None);
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
        rejected
            .review
            .decided_by
            .as_ref()
            .map(|user| user.user_id.as_str()),
        Some(member_id.as_str())
    );
    assert_eq!(
        rejected
            .review
            .decided_by
            .as_ref()
            .and_then(|user| user.display_name.as_deref()),
        Some("Member")
    );
    assert!(rejected.review.decided_at.is_some());
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

    let remote = create_approved_context_review(
        owner_app.clone(),
        &bootstrap.project_id,
        None,
        "context/remote.md",
        "# Remote authority",
    )
    .await;
    let remote_merge: ReviewMergeResult = post_json_with_etag(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/merges", remote.review_id),
        "\"ref-none\"",
        &CreateReviewMergeRequest {
            expected_review_version: remote.version,
        },
    )
    .await;
    let current_commit_id = remote_merge.commit_id.unwrap();
    let submission_ref_etag = format!("\"{current_commit_id}\"");
    let behind_before_submission: DraftDetail = get_json(
        owner_app.clone(),
        &format!("/api/v1/drafts/{}", edited.draft.draft_id),
    )
    .await;
    assert_eq!(behind_before_submission.draft.base_commit_id, None);
    assert_eq!(
        behind_before_submission.draft.coordination.freshness,
        DraftFreshness::Behind
    );
    assert!(
        !behind_before_submission
            .draft
            .coordination
            .has_upstream_resource_changes
    );
    assert_eq!(behind_before_submission.operations, edited.operations);

    let stale_review_submission = post_response_with_etag(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &submission_ref_etag,
        &CreateReviewSubmissionRequest {
            expected_review_version: 1,
            expected_draft_version: edited.draft.version,
            title: None,
            description: None,
            candidate_id: None,
            resolved_state: None,
        },
    )
    .await;
    assert_eq!(stale_review_submission.status(), StatusCode::CONFLICT);

    let stale_draft_submission = post_response_with_etag(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &submission_ref_etag,
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version - 1,
            title: None,
            description: None,
            candidate_id: None,
            resolved_state: None,
        },
    )
    .await;
    assert_eq!(stale_draft_submission.status(), StatusCode::CONFLICT);

    let member_submission = post_response_with_etag(
        member_app,
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &submission_ref_etag,
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version,
            title: None,
            description: None,
            candidate_id: None,
            resolved_state: None,
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

    let reconciliation_required = post_response_with_etag(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &submission_ref_etag,
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version,
            title: Some("Revised review lifecycle context".to_owned()),
            description: None,
            candidate_id: None,
            resolved_state: None,
        },
    )
    .await;
    assert_eq!(reconciliation_required.status(), StatusCode::CONFLICT);
    let required_body = to_bytes(reconciliation_required.into_body(), usize::MAX)
        .await
        .unwrap();
    let required_error: serde_json::Value = serde_json::from_slice(&required_body).unwrap();
    assert_eq!(required_error["error"]["code"], "reconciliation_required");
    let candidate_id = required_error["error"]["details"]["candidate_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let candidate: DraftReconciliationCandidate = get_json(
        owner_app.clone(),
        &format!(
            "/api/v1/drafts/{}/reconciliation-candidates/{candidate_id}",
            edited.draft.draft_id
        ),
    )
    .await;
    assert_eq!(candidate.status, ReconciliationCandidateStatus::Clean);
    assert_eq!(candidate.draft_version, edited.draft.version);
    assert_eq!(candidate.base_commit_id, None);
    assert_eq!(
        candidate.current_commit_id.as_deref(),
        Some(current_commit_id.as_str())
    );
    let viewed_only: DraftDetail = get_json(
        owner_app.clone(),
        &format!("/api/v1/drafts/{}", edited.draft.draft_id),
    )
    .await;
    assert_eq!(viewed_only.draft.base_commit_id, None);
    assert_eq!(viewed_only.draft.version, edited.draft.version);
    assert_eq!(viewed_only.operations, edited.operations);

    let resubmitted: ReviewDetail = post_json_with_etag(
        owner_app.clone(),
        &format!("/api/v1/reviews/{}/submissions", rejected.review.review_id),
        &submission_ref_etag,
        &CreateReviewSubmissionRequest {
            expected_review_version: rejected.review.version,
            expected_draft_version: edited.draft.version,
            title: Some("Revised review lifecycle context".to_owned()),
            description: None,
            candidate_id: Some(candidate_id),
            resolved_state: None,
        },
    )
    .await;
    assert_eq!(resubmitted.review.review_id, submitted.review.review_id);
    assert_eq!(resubmitted.review.status, ReviewStatus::Open);
    assert_eq!(resubmitted.review.version, 4);
    assert_eq!(resubmitted.review.title, "Revised review lifecycle context");
    assert_eq!(resubmitted.review.decision_body, None);
    assert_eq!(resubmitted.review.decided_by, None);
    assert_eq!(resubmitted.review.decided_at, None);
    assert_eq!(resubmitted.draft.status, DraftStatus::Submitted);
    assert_eq!(
        resubmitted.draft.base_commit_id.as_deref(),
        Some(current_commit_id.as_str())
    );
    assert_eq!(resubmitted.draft.version, 6);
    assert_eq!(resubmitted.operations.len(), 1);
    let revision_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM draft_revisions WHERE draft_id = $1")
            .bind(&resubmitted.draft.draft_id)
            .fetch_one(&postgres.pool)
            .await
            .unwrap();
    assert_eq!(revision_count, 1);

    let duplicate_submission = post_response_with_etag(
        owner_app.clone(),
        &format!(
            "/api/v1/reviews/{}/submissions",
            resubmitted.review.review_id
        ),
        &submission_ref_etag,
        &CreateReviewSubmissionRequest {
            expected_review_version: resubmitted.review.version,
            expected_draft_version: resubmitted.draft.version,
            title: None,
            description: None,
            candidate_id: None,
            resolved_state: None,
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
    assert_eq!(submitted_versions, vec![2, 6]);
}

#[tokio::test]
async fn stale_draft_cannot_overwrite_a_new_project_ref() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Concurrent Memory",
    )
    .await;
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
    assert_eq!(
        discarded.review.decision_body.as_deref(),
        Some("Draft discarded.")
    );
    assert_eq!(
        discarded
            .review
            .decided_by
            .as_ref()
            .map(|user| user.user_id.as_str()),
        Some(bootstrap.user_id.as_str())
    );
    assert!(discarded.review.decided_at.is_some());
    assert_eq!(discarded.draft.status, DraftStatus::Discarded);

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
    assert_eq!(stale_error["error"]["code"], "reconciliation_required");
    assert_eq!(stale_error["error"]["details"]["draft_id"], stale.draft_id);
    assert_eq!(
        stale_error["error"]["details"]["current_commit_id"],
        first_commit_id
    );
    let candidate_id = stale_error["error"]["details"]["candidate_id"]
        .as_str()
        .unwrap()
        .to_owned();

    let behind: ReviewDetail =
        get_json(app.clone(), &format!("/api/v1/reviews/{}", stale.review_id)).await;
    assert_eq!(behind.draft.status, DraftStatus::Submitted);
    assert_eq!(behind.draft.version, 2);
    assert_eq!(behind.draft.base_commit_id, None);
    assert_eq!(behind.draft.coordination.freshness, DraftFreshness::Behind);
    assert_eq!(
        behind.draft.coordination.reconciliation,
        DraftReconciliationStatus::Clean
    );
    assert_eq!(
        behind.draft.coordination.candidate_id.as_deref(),
        Some(candidate_id.as_str())
    );
    assert_eq!(behind.review.status, ReviewStatus::Approved);

    let candidate: DraftReconciliationCandidate = get_json(
        app.clone(),
        &format!(
            "/api/v1/drafts/{}/reconciliation-candidates/{candidate_id}",
            stale.draft_id
        ),
    )
    .await;
    assert!(candidate.valid);
    assert_eq!(candidate.draft_version, behind.draft.version);
    assert_eq!(candidate.base_commit_id, None);
    assert_eq!(
        candidate.current_commit_id.as_deref(),
        Some(first_commit_id.as_str())
    );
    let clean_override = post_response_with_etag(
        app.clone(),
        &format!("/api/v1/drafts/{}/rebases", stale.draft_id),
        &format!("\"{first_commit_id}\""),
        &CreateDraftRebaseRequest {
            candidate_id: candidate_id.clone(),
            expected_draft_version: behind.draft.version,
            resolved_state: Some(candidate.draft_state.clone()),
        },
    )
    .await;
    assert_eq!(clean_override.status(), StatusCode::BAD_REQUEST);
    let still_behind: ReviewDetail =
        get_json(app.clone(), &format!("/api/v1/reviews/{}", stale.review_id)).await;
    assert_eq!(still_behind.draft.base_commit_id, None);
    assert_eq!(still_behind.draft.version, behind.draft.version);

    let events: DraftEventListResponse = get_json(app.clone(), "/api/v1/draft-events").await;
    assert!(!events.events.iter().any(|event| {
        event.draft_id == stale.draft_id && event.event_type == DraftEventType::Rebased
    }));

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

    let second = create_approved_context_review(
        app.clone(),
        &project_id,
        Some(&first_commit_id),
        "context/second.md",
        "# Second",
    )
    .await;
    let second_merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", second.review_id),
        &format!("\"{first_commit_id}\""),
        &CreateReviewMergeRequest {
            expected_review_version: second.version,
        },
    )
    .await;
    let second_commit_id = second_merge.commit_id.unwrap();
    let invalidated_candidate: DraftReconciliationCandidate = get_json(
        app.clone(),
        &format!(
            "/api/v1/drafts/{}/reconciliation-candidates/{candidate_id}",
            stale.draft_id
        ),
    )
    .await;
    assert!(!invalidated_candidate.valid);
    let behind_again: ReviewDetail =
        get_json(app.clone(), &format!("/api/v1/reviews/{}", stale.review_id)).await;
    assert_eq!(
        behind_again.draft.coordination.freshness,
        DraftFreshness::Behind
    );
    assert_eq!(
        behind_again.draft.coordination.current_commit_id.as_deref(),
        Some(second_commit_id.as_str())
    );
    assert_eq!(
        behind_again.draft.coordination.reconciliation,
        DraftReconciliationStatus::Unknown
    );

    let refreshed_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/reviews/{}/merges", stale.review_id))
                .header("content-type", "application/json")
                .header("if-match", format!("\"{second_commit_id}\""))
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
    assert_eq!(refreshed_response.status(), StatusCode::CONFLICT);
    let refreshed_error: serde_json::Value = decode_json(refreshed_response).await;
    let refreshed_candidate_id = refreshed_error["error"]["details"]["candidate_id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(refreshed_candidate_id, candidate_id);

    let rebased: DraftRebaseResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/drafts/{}/rebases", stale.draft_id),
        &format!("\"{second_commit_id}\""),
        &CreateDraftRebaseRequest {
            candidate_id: refreshed_candidate_id,
            expected_draft_version: behind.draft.version,
            resolved_state: None,
        },
    )
    .await;
    assert!(!rebased.approval_invalidated);
    assert_eq!(rebased.draft.draft.status, DraftStatus::Submitted);
    assert_eq!(
        rebased.draft.draft.base_commit_id.as_deref(),
        Some(second_commit_id.as_str())
    );
    assert_eq!(
        rebased.draft.draft.coordination.freshness,
        DraftFreshness::Current
    );
    let rebased_review = rebased.review.expect("existing Review should be returned");
    assert_eq!(rebased_review.status, ReviewStatus::Approved);
    assert_eq!(
        rebased_review.approved_result_hash,
        behind.review.approved_result_hash
    );
    assert_eq!(rebased_review.decided_by, behind.review.decided_by);
    assert_eq!(rebased_review.decided_at, behind.review.decided_at);

    let merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", stale.review_id),
        &format!("\"{second_commit_id}\""),
        &CreateReviewMergeRequest {
            expected_review_version: rebased_review.version,
        },
    )
    .await;
    assert!(merge.commit_id.is_some());
    let context: ContextListResponse =
        get_json(app, &format!("/api/v1/projects/{project_id}/context")).await;
    assert_eq!(context.items.len(), 3);
}

#[tokio::test]
async fn reconciliation_handles_overlapping_updates_and_editable_behind_drafts() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Reconciliation Memory",
    )
    .await;

    let resource = DraftResourceRef {
        scope: ResourceScope::Project,
        kind: DraftResourceKind::Context,
        id: None,
        path: Some("context/coordination.md".to_owned()),
    };
    let seed = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_seed".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: None,
                title: "Seed coordination context".to_owned(),
                description: None,
                resource: resource.clone(),
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: resource.clone(),
                    content: context_draft_content(
                        "# Coordination\n\nmode: base\n\nfooter: base\n",
                    ),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let seed_review = repo
        .create_review(
            &bootstrap.user_id,
            None,
            CreateReviewRequest {
                draft_id: seed.draft.draft_id,
                expected_draft_version: seed.draft.version,
                title: None,
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let seed_review = repo
        .create_review_decision(
            &seed_review.review.review_id,
            &seed_review.review.author.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: seed_review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    let base_commit_id = repo
        .create_review_merge(
            &seed_review.review.review_id,
            None,
            CreateReviewMergeRequest {
                expected_review_version: seed_review.review.version,
            },
        )
        .await
        .unwrap()
        .commit_id
        .unwrap();
    let payload = repo.get_commit_payload(&base_commit_id).await.unwrap();
    let resource_id = payload
        .tree
        .entries
        .iter()
        .find(|entry| entry.path.as_deref() == Some("context/coordination.md"))
        .unwrap()
        .id
        .clone();
    let existing_resource = DraftResourceRef {
        scope: ResourceScope::Project,
        kind: DraftResourceKind::Context,
        id: Some(resource_id.clone()),
        path: None,
    };

    let local_update = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_local_update".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: Some(base_commit_id.clone()),
                title: "Update coordination locally".to_owned(),
                description: None,
                resource: existing_resource.clone(),
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Update,
                    resource: existing_resource.clone(),
                    content: context_draft_content(
                        "# Coordination\n\nmode: local\n\nfooter: base\n",
                    ),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let local_review = repo
        .create_review(
            &bootstrap.user_id,
            Some(&base_commit_id),
            CreateReviewRequest {
                draft_id: local_update.draft.draft_id.clone(),
                expected_draft_version: local_update.draft.version,
                title: None,
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let local_review = repo
        .create_review_decision(
            &local_review.review.review_id,
            &local_review.review.author.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: local_review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();

    let rename = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_local_rename".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: Some(base_commit_id.clone()),
                title: "Rename coordination context".to_owned(),
                description: None,
                resource: existing_resource.clone(),
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Rename,
                    resource: existing_resource.clone(),
                    content: None,
                    new_path: Some("context/coordination-local.md".to_owned()),
                }],
            },
        )
        .await
        .unwrap();

    let remote = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_remote_update".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: Some(base_commit_id.clone()),
                title: "Update coordination remotely".to_owned(),
                description: None,
                resource: existing_resource.clone(),
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Update,
                    resource: existing_resource.clone(),
                    content: context_draft_content(
                        "# Coordination\n\nmode: remote\n\nfooter: base\n",
                    ),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let remote_review = repo
        .create_review(
            &bootstrap.user_id,
            Some(&base_commit_id),
            CreateReviewRequest {
                draft_id: remote.draft.draft_id,
                expected_draft_version: remote.draft.version,
                title: None,
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let remote_review = repo
        .create_review_decision(
            &remote_review.review.review_id,
            &remote_review.review.author.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: remote_review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    let current_commit_id = repo
        .create_review_merge(
            &remote_review.review.review_id,
            Some(&base_commit_id),
            CreateReviewMergeRequest {
                expected_review_version: remote_review.review.version,
            },
        )
        .await
        .unwrap()
        .commit_id
        .unwrap();

    let conflicting = repo
        .create_draft_reconciliation_candidate(
            &local_update.draft.draft_id,
            server::api::CreateDraftReconciliationCandidateRequest {
                expected_draft_version: local_review.draft.version,
            },
        )
        .await
        .unwrap();
    assert_eq!(conflicting.status, ReconciliationCandidateStatus::Conflicts);
    assert!(conflicting.proposed_state.is_none());
    assert!(!conflicting.conflicts.is_empty());
    let unchanged = repo.get_draft(&local_update.draft.draft_id).await.unwrap();
    assert_eq!(
        unchanged.draft.base_commit_id.as_deref(),
        Some(base_commit_id.as_str())
    );
    assert_eq!(unchanged.draft.status, DraftStatus::Submitted);
    assert_eq!(unchanged.draft.version, local_review.draft.version);
    assert!(
        repo.create_draft_rebase(
            &local_update.draft.draft_id,
            &bootstrap.user_id,
            Some(&current_commit_id),
            CreateDraftRebaseRequest {
                candidate_id: conflicting.candidate_id.clone(),
                expected_draft_version: unchanged.draft.version,
                resolved_state: None,
            },
        )
        .await
        .is_err()
    );
    let mut resolved_state = conflicting.draft_state.clone();
    resolved_state.content =
        context_draft_content("# Coordination\n\nmode: resolved\n\nfooter: base\n");
    let resolved = repo
        .create_draft_rebase(
            &local_update.draft.draft_id,
            &bootstrap.user_id,
            Some(&current_commit_id),
            CreateDraftRebaseRequest {
                candidate_id: conflicting.candidate_id,
                expected_draft_version: unchanged.draft.version,
                resolved_state: Some(resolved_state),
            },
        )
        .await
        .unwrap();
    assert!(resolved.approval_invalidated);
    assert_eq!(
        resolved.draft.draft.base_commit_id.as_deref(),
        Some(current_commit_id.as_str())
    );
    let invalidated_review = resolved.review.as_ref().unwrap();
    assert_eq!(invalidated_review.status, ReviewStatus::Open);
    assert_eq!(invalidated_review.decision_body, None);
    assert_eq!(invalidated_review.approved_result_hash, None);
    assert_eq!(invalidated_review.decided_by, None);
    assert_eq!(invalidated_review.decided_at, None);
    let revision_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM draft_revisions WHERE draft_id = $1")
            .bind(&local_update.draft.draft_id)
            .fetch_one(&postgres.pool)
            .await
            .unwrap();
    assert_eq!(revision_count, 1);

    let rename_candidate = repo
        .create_draft_reconciliation_candidate(
            &rename.draft.draft_id,
            server::api::CreateDraftReconciliationCandidateRequest {
                expected_draft_version: rename.draft.version,
            },
        )
        .await
        .unwrap();
    assert_eq!(
        rename_candidate.status,
        ReconciliationCandidateStatus::Clean
    );
    let renamed = repo
        .append_draft_operation(
            &rename.draft.draft_id,
            rename.draft.version,
            DraftOperationInput {
                action: DraftOperationAction::Rename,
                resource: existing_resource,
                content: None,
                new_path: Some("context/coordination-final.md".to_owned()),
            },
        )
        .await
        .unwrap();
    assert_eq!(renamed.draft.status, DraftStatus::Open);
    assert_eq!(
        renamed.draft.base_commit_id.as_deref(),
        Some(base_commit_id.as_str())
    );
    assert_eq!(renamed.draft.coordination.freshness, DraftFreshness::Behind);
    assert!(renamed.draft.coordination.has_upstream_resource_changes);
    let invalidated = repo
        .get_draft_reconciliation_candidate(&rename.draft.draft_id, &rename_candidate.candidate_id)
        .await
        .unwrap();
    assert!(!invalidated.valid);
    let refreshed = repo
        .create_draft_reconciliation_candidate(
            &rename.draft.draft_id,
            server::api::CreateDraftReconciliationCandidateRequest {
                expected_draft_version: renamed.draft.version,
            },
        )
        .await
        .unwrap();
    assert_eq!(refreshed.status, ReconciliationCandidateStatus::Clean);
    assert_eq!(
        refreshed
            .proposed_state
            .as_ref()
            .and_then(|state| state.resource.path.as_deref()),
        Some("context/coordination-final.md")
    );
    assert_eq!(
        refreshed
            .proposed_state
            .as_ref()
            .and_then(|state| state.content.as_ref())
            .map(content_text_for_test),
        Some("# Coordination\n\nmode: remote\n\nfooter: base\n")
    );
}

#[tokio::test]
async fn project_org_selection_rejects_foreign_and_colliding_resources_atomically() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Effective Memory",
    )
    .await;
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

    let unknown_response = put_response_with_if_match(
        app.clone(),
        &selection_uri,
        before.revision,
        &ReplaceProjectOrgSelectionRequest {
            rule_ids: Vec::new(),
            context_ids: vec!["ctx_unknown".to_owned()],
            workflow_ids: Vec::new(),
        },
    )
    .await;
    assert_eq!(unknown_response.status(), StatusCode::NOT_FOUND);

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
async fn invalid_memory_paths_and_rule_shapes_are_rejected_before_draft_storage() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Path Validation",
    )
    .await;
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
                content: "# Invalid Workflow".to_owned(),
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
                content: "  ".to_owned(),
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

    let draft_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM drafts")
        .fetch_one(&postgres.pool)
        .await
        .unwrap();
    assert_eq!(draft_count, 0);
}

#[tokio::test]
async fn markdown_rule_and_workflow_survive_draft_review_and_commit_round_trip() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Search Agent",
    )
    .await;
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
                    content: "# Coding discipline\n\nApply while changing production code.\n\nRun the focused tests before committing.\n\nTags: coding, quality"
                        .to_owned(),
                }),
                new_path: None,
            }],
        },
    )
    .await;
    let rule_review = create_review_for_draft(app.clone(), &rule_draft).await;
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
    assert_eq!(rule.rule.name, "coding");
    assert_eq!(
        rule.content,
        "# Coding discipline\n\nApply while changing production code.\n\nRun the focused tests before committing.\n\nTags: coding, quality"
    );
    let rule_blob = rule_commit
        .blobs
        .iter()
        .find(|blob| blob.blob_id == rule_entry.blob_id)
        .expect("rule Blob should be present");
    assert_eq!(rule_blob.content, rule.content);

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
                    content: format!(
                        "# Coding workflow\n\nPrepare a production change.\n\n- Apply rule `{rule_id}`.\n- Summarize verification evidence."
                    ),
                }),
                new_path: None,
            }],
        },
    )
    .await;
    let workflow_review = create_review_for_draft(app.clone(), &workflow_draft).await;
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
    assert_eq!(workflow.workflow.name, "coding");
    assert_eq!(
        workflow.content,
        format!(
            "# Coding workflow\n\nPrepare a production change.\n\n- Apply rule `{rule_id}`.\n- Summarize verification evidence."
        )
    );
    let workflow_blob = workflow_commit
        .blobs
        .iter()
        .find(|blob| blob.blob_id == workflow_entry.blob_id)
        .expect("workflow Blob should be present");
    assert_eq!(workflow_blob.content, workflow.content);
}

fn context_draft_content(content: &str) -> Option<DraftResourceContent> {
    Some(DraftResourceContent::Context {
        content: content.to_owned(),
    })
}

fn content_text_for_test(content: &DraftResourceContent) -> &str {
    match content {
        DraftResourceContent::Context { content }
        | DraftResourceContent::Rule { content }
        | DraftResourceContent::Workflow { content } => content,
    }
}

async fn create_review_for_draft(app: axum::Router, draft: &DraftDetail) -> ReviewDetail {
    let ref_etag = draft
        .draft
        .coordination
        .current_commit_id
        .as_deref()
        .map(|commit_id| format!("\"{commit_id}\""))
        .unwrap_or_else(|| "\"ref-none\"".to_owned());
    post_json_with_etag(
        app,
        "/api/v1/reviews",
        &ref_etag,
        &CreateReviewRequest {
            draft_id: draft.draft.draft_id.clone(),
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
            candidate_id: None,
            resolved_state: None,
        },
    )
    .await
}

async fn create_approved_review(app: axum::Router, request: CreateDraftRequest) -> Review {
    let draft: DraftDetail = post_json(app.clone(), "/api/v1/drafts", &request).await;
    let review = create_review_for_draft(app.clone(), &draft).await;
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
    let review = create_review_for_draft(app.clone(), &draft).await;
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
                .header("idempotency-key", format!("test-{}", uuid::Uuid::new_v4()))
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    assert!(
        status == StatusCode::OK || status == StatusCode::CREATED,
        "request failed with {status}: {}",
        String::from_utf8_lossy(&body)
    );
    serde_json::from_slice(&body).unwrap()
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

async fn post_response_with_etag<TRequest>(
    app: axum::Router,
    uri: &str,
    etag: &str,
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
            .header("if-match", etag)
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

#[tokio::test]
async fn review_comments_support_line_anchors() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Anchored comments",
    )
    .await;
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;
    let seed = create_approved_context_review(
        app.clone(),
        &bootstrap.project_id,
        None,
        "context/anchored.md",
        "# Anchored\n\nBody.\n",
    )
    .await;
    let seed_merge: ReviewMergeResult = post_json_with_etag(
        app.clone(),
        &format!("/api/v1/reviews/{}/merges", seed.review_id),
        "\"ref-none\"",
        &CreateReviewMergeRequest {
            expected_review_version: seed.version,
        },
    )
    .await;
    let base_commit_id = seed_merge
        .commit_id
        .expect("seeding the anchored resource should create a commit");
    let base_payload: CommitPayload =
        get_json(app.clone(), &format!("/api/v1/commits/{base_commit_id}")).await;
    let resource_id = base_payload
        .tree
        .entries
        .iter()
        .find(|entry| entry.path.as_deref() == Some("context/anchored.md"))
        .expect("seeded anchored resource should be present in the base commit")
        .id
        .clone();
    let draft: DraftDetail = post_json(
        app.clone(),
        "/api/v1/drafts",
        &CreateDraftRequest {
            daemon_installation_id: "daemon_anchors".to_owned(),
            project_id: bootstrap.project_id.clone(),
            base_commit_id: Some(base_commit_id),
            title: "Anchored comment draft".to_owned(),
            description: None,
            resource: DraftResourceRef {
                scope: ResourceScope::Project,
                kind: DraftResourceKind::Context,
                id: Some(resource_id.clone()),
                path: None,
            },
            operations: vec![DraftOperationInput {
                action: DraftOperationAction::Rename,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: Some(resource_id),
                    path: None,
                },
                content: None,
                new_path: Some("context/anchored-final.md".to_owned()),
            }],
        },
    )
    .await;
    let review = create_review_for_draft(app.clone(), &draft).await;
    let review_id = review.review.review_id.clone();

    let unpaired_storage_anchor = sqlx::query(
        "INSERT INTO review_comments (
            comment_id, review_id, author_user_id, body, anchor_path, anchor_line,
            review_version
         ) VALUES ('cmt_unpaired_storage', $1, $2, 'invalid', $3, NULL, $4)",
    )
    .bind(&review_id)
    .bind(&bootstrap.user_id)
    .bind("context/anchored.md")
    .bind(review.review.version)
    .execute(&postgres.pool)
    .await;
    assert!(unpaired_storage_anchor.is_err());

    let non_positive_storage_anchor = sqlx::query(
        "INSERT INTO review_comments (
            comment_id, review_id, author_user_id, body, anchor_path, anchor_line,
            review_version
         ) VALUES ('cmt_non_positive_storage', $1, $2, 'invalid', $3, 0, $4)",
    )
    .bind(&review_id)
    .bind(&bootstrap.user_id)
    .bind("context/anchored.md")
    .bind(review.review.version)
    .execute(&postgres.pool)
    .await;
    assert!(non_positive_storage_anchor.is_err());

    let anchored: ReviewComment = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{review_id}/comments"),
        &CreateReviewCommentRequest {
            body: "Trailing line looks off".to_owned(),
            expected_review_version: review.review.version,
            anchor_path: Some("context/anchored-final.md".to_owned()),
            anchor_line: Some(4),
        },
    )
    .await;
    assert_eq!(
        anchored.anchor_path.as_deref(),
        Some("context/anchored-final.md")
    );
    assert_eq!(anchored.anchor_line, Some(4));
    assert_eq!(anchored.review_version, review.review.version);

    let general: ReviewComment = post_json(
        app.clone(),
        &format!("/api/v1/reviews/{review_id}/comments"),
        &CreateReviewCommentRequest {
            body: "Overall direction is fine".to_owned(),
            expected_review_version: review.review.version,
            anchor_path: None,
            anchor_line: None,
        },
    )
    .await;
    assert_eq!(general.anchor_path, None);
    assert_eq!(general.anchor_line, None);
    assert_eq!(general.review_version, review.review.version);

    let detail: ReviewDetail = get_json(app.clone(), &format!("/api/v1/reviews/{review_id}")).await;
    assert_eq!(detail.comments.len(), 2);
    let anchored_in_detail = detail
        .comments
        .iter()
        .find(|comment| comment.comment_id == anchored.comment_id)
        .expect("anchored comment should appear in review detail");
    assert_eq!(
        anchored_in_detail.anchor_path.as_deref(),
        Some("context/anchored-final.md")
    );
    assert_eq!(anchored_in_detail.anchor_line, Some(4));
    assert_eq!(anchored_in_detail.review_version, review.review.version);
    let general_in_detail = detail
        .comments
        .iter()
        .find(|comment| comment.comment_id == general.comment_id)
        .expect("general comment should appear in review detail");
    assert_eq!(general_in_detail.anchor_line, None);
    assert_eq!(general_in_detail.anchor_path, None);

    let unpaired = post_response(
        app.clone(),
        &format!("/api/v1/reviews/{review_id}/comments"),
        &CreateReviewCommentRequest {
            body: "Bad anchor".to_owned(),
            expected_review_version: review.review.version,
            anchor_path: None,
            anchor_line: Some(3),
        },
    )
    .await;
    assert_eq!(unpaired.status(), StatusCode::BAD_REQUEST);

    let wrong_path = post_response(
        app.clone(),
        &format!("/api/v1/reviews/{review_id}/comments"),
        &CreateReviewCommentRequest {
            body: "Wrong file".to_owned(),
            expected_review_version: review.review.version,
            anchor_path: Some("context/anchored.md".to_owned()),
            anchor_line: Some(1),
        },
    )
    .await;
    assert_eq!(wrong_path.status(), StatusCode::BAD_REQUEST);

    let out_of_range = post_response(
        app.clone(),
        &format!("/api/v1/reviews/{review_id}/comments"),
        &CreateReviewCommentRequest {
            body: "Past the end".to_owned(),
            expected_review_version: review.review.version,
            anchor_path: Some("context/anchored-final.md".to_owned()),
            anchor_line: Some(5),
        },
    )
    .await;
    assert_eq!(out_of_range.status(), StatusCode::BAD_REQUEST);

    let stale = post_response(
        app,
        &format!("/api/v1/reviews/{review_id}/comments"),
        &CreateReviewCommentRequest {
            body: "Stale context".to_owned(),
            expected_review_version: review.review.version - 1,
            anchor_path: None,
            anchor_line: None,
        },
    )
    .await;
    assert_eq!(stale.status(), StatusCode::CONFLICT);
}
