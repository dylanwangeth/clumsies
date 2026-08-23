mod common;

use server::api::{
    CreateDraftRequest, CreateReviewDecisionRequest, CreateReviewMergeRequest, CreateReviewRequest,
    DraftOperationAction, DraftOperationBatchItem, DraftOperationBatchRequest, DraftOperationInput,
    DraftResourceContent, DraftResourceRef, ResourceScope, ReviewDecision, ReviewDraftRequest,
};
use server::repository::ServerRepository;

fn memory_content(content: &str) -> Option<DraftResourceContent> {
    Some(DraftResourceContent {
        description: None,
        content: content.to_owned(),
    })
}

#[tokio::test]
async fn multi_draft_review_merges_every_file_in_one_commit() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Directory Review",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Directory Review",
    )
    .await;
    let head = repo
        .get_org_commit_state(&bootstrap.org_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;

    let mut drafts = Vec::new();
    for (index, path) in [
        "skills/coding/SKILL.md",
        "skills/coding/references/workflow.md",
    ]
    .into_iter()
    .enumerate()
    {
        drafts.push(
            repo.create_draft(
                &bootstrap.user_id,
                CreateDraftRequest {
                    daemon_installation_id: format!("daemon_directory_{index}"),
                    project_id: bootstrap.project_id.clone(),
                    base_commit_id: head.clone(),
                    title: format!("Create {path}"),
                    description: None,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Org,
                        id: None,
                        path: Some(path.to_owned()),
                    },
                    operations: vec![DraftOperationInput {
                        action: DraftOperationAction::Create,
                        resource: DraftResourceRef {
                            scope: ResourceScope::Org,
                            id: None,
                            path: Some(path.to_owned()),
                        },
                        content: memory_content(&format!("# File {index}")),
                        new_path: None,
                    }],
                },
            )
            .await
            .unwrap(),
        );
    }

    let first_submission = repo
        .create_review(
            &bootstrap.user_id,
            head.as_deref(),
            CreateReviewRequest {
                drafts: vec![ReviewDraftRequest {
                    draft_id: drafts[0].draft.draft_id.clone(),
                    expected_draft_version: drafts[0].draft.version,
                }],
                title: Some("Create coding skill".to_owned()),
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let rejected = repo
        .create_review_decision(
            &first_submission.review.review_id,
            &bootstrap.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Rejected,
                expected_review_version: first_submission.review.version,
                body: Some("Include every file in the directory.".to_owned()),
            },
        )
        .await
        .unwrap();
    let detail = repo
        .create_review(
            &bootstrap.user_id,
            head.as_deref(),
            CreateReviewRequest {
                drafts: vec![
                    ReviewDraftRequest {
                        draft_id: rejected.drafts[0].draft.draft_id.clone(),
                        expected_draft_version: rejected.drafts[0].draft.version,
                    },
                    ReviewDraftRequest {
                        draft_id: drafts[1].draft.draft_id.clone(),
                        expected_draft_version: drafts[1].draft.version,
                    },
                ],
                title: Some("Create coding skill".to_owned()),
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(detail.review.review_id, first_submission.review.review_id);
    assert_eq!(detail.review.draft_ids.len(), 2);
    assert_eq!(detail.drafts.len(), 2);
    assert!(
        detail
            .drafts
            .iter()
            .all(|item| item.draft.status == server::api::DraftStatus::Submitted)
    );

    let approved = repo
        .create_review_decision(
            &detail.review.review_id,
            &bootstrap.user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: detail.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    let merged = repo
        .create_review_merge(
            &detail.review.review_id,
            &bootstrap.user_id,
            head.as_deref(),
            CreateReviewMergeRequest {
                expected_review_version: approved.review.version,
            },
        )
        .await
        .unwrap();
    assert_eq!(merged.applied_operation_count, 2);

    let commit = repo
        .get_commit_payload(merged.commit_id.as_deref().unwrap())
        .await
        .unwrap();
    let paths = commit
        .tree
        .entries
        .iter()
        .filter_map(|entry| entry.path.as_deref())
        .collect::<Vec<_>>();
    assert!(paths.contains(&"skills/coding/SKILL.md"));
    assert!(paths.contains(&"skills/coding/references/workflow.md"));
}

async fn approve_and_merge(
    repo: &ServerRepository,
    user_id: &str,
    expected_ref: Option<&str>,
    draft_id: &str,
    expected_draft_version: i64,
) {
    let review = repo
        .create_review(
            user_id,
            expected_ref,
            CreateReviewRequest {
                drafts: vec![ReviewDraftRequest {
                    draft_id: draft_id.to_owned(),
                    expected_draft_version,
                }],
                title: None,
                description: None,
                candidate_id: None,
                resolved_state: None,
            },
        )
        .await
        .unwrap();
    let approved = repo
        .create_review_decision(
            &review.review.review_id,
            user_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    repo.create_review_merge(
        &approved.review.review_id,
        user_id,
        expected_ref,
        CreateReviewMergeRequest {
            expected_review_version: approved.review.version,
        },
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn create_request_preserves_create_update_rename_order_through_review_and_merge() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Operation Ordering",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Create Request Ordering",
    )
    .await;
    let head = repo
        .get_org_commit_state(&bootstrap.org_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    let initial_path = "context/created-in-order.md";
    let final_path = "context/created-in-final-order.md";

    let draft = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_create_ordering".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: head.clone(),
                title: "Create and refine in one request".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Org,
                    id: None,
                    path: Some(initial_path.to_owned()),
                },
                operations: vec![
                    DraftOperationInput {
                        action: DraftOperationAction::Create,
                        resource: DraftResourceRef {
                            scope: ResourceScope::Org,
                            id: None,
                            path: Some(initial_path.to_owned()),
                        },
                        content: memory_content("# Initial"),
                        new_path: None,
                    },
                    DraftOperationInput {
                        action: DraftOperationAction::Update,
                        resource: DraftResourceRef {
                            scope: ResourceScope::Org,
                            id: None,
                            path: Some(initial_path.to_owned()),
                        },
                        content: memory_content("# Refined"),
                        new_path: None,
                    },
                    DraftOperationInput {
                        action: DraftOperationAction::Rename,
                        resource: DraftResourceRef {
                            scope: ResourceScope::Org,
                            id: None,
                            path: Some(initial_path.to_owned()),
                        },
                        content: None,
                        new_path: Some(final_path.to_owned()),
                    },
                ],
            },
        )
        .await
        .unwrap();

    // Make every legacy tie-breaker disagree with request order. Stable reads
    // must continue to follow ordinal, not timestamp or generated ID.
    sqlx::query(
        "UPDATE draft_operations
         SET operation_id = CASE action
                WHEN 'create' THEN 'dop_z_create'
                WHEN 'update' THEN 'dop_m_update'
                WHEN 'rename' THEN 'dop_a_rename'
                ELSE operation_id
             END,
             created_at = '2026-08-20T00:00:00Z'
         WHERE draft_id = $1",
    )
    .bind(&draft.draft.draft_id)
    .execute(&postgres.pool)
    .await
    .unwrap();

    let stored: Vec<(String, i64)> = sqlx::query_as(
        "SELECT action, ordinal FROM draft_operations
         WHERE draft_id = $1 ORDER BY ordinal",
    )
    .bind(&draft.draft.draft_id)
    .fetch_all(&postgres.pool)
    .await
    .unwrap();
    assert_eq!(
        stored,
        vec![
            ("create".to_owned(), 1),
            ("update".to_owned(), 2),
            ("rename".to_owned(), 3),
        ]
    );

    let detail = repo.get_draft(&draft.draft.draft_id).await.unwrap();
    assert_eq!(
        detail
            .operations
            .iter()
            .map(|operation| operation.input.action)
            .collect::<Vec<_>>(),
        vec![
            DraftOperationAction::Create,
            DraftOperationAction::Update,
            DraftOperationAction::Rename,
        ]
    );
    approve_and_merge(
        &repo,
        &bootstrap.user_id,
        head.as_deref(),
        &detail.draft.draft_id,
        detail.draft.version,
    )
    .await;

    let created = repo
        .list_org_memories(&bootstrap.org_id)
        .await
        .unwrap()
        .items
        .into_iter()
        .find(|memory| memory.path == final_path)
        .expect("ordered operations should materialize the final path");
    assert_eq!(
        repo.get_org_memory(&bootstrap.org_id, &created.memory_id)
            .await
            .unwrap()
            .content,
        "# Refined"
    );
}

#[tokio::test]
async fn batch_preserves_multiple_operations_and_their_event_versions() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Operation Ordering",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Batch Ordering",
    )
    .await;
    let resource_id = repo
        .create_org_context(&bootstrap.org_id, "context/batch-order.md", "# Authority")
        .await
        .unwrap();
    repo.select_org_resource_for_project(&bootstrap.project_id, &resource_id)
        .await
        .unwrap();
    let head = repo
        .get_org_commit_state(&bootstrap.org_id, None)
        .await
        .unwrap()
        .reference
        .commit_id;
    let target = DraftResourceRef {
        scope: ResourceScope::Org,
        id: Some(resource_id.clone()),
        path: None,
    };
    let draft = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_batch_ordering".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: head.clone(),
                title: "Apply ordered batch".to_owned(),
                description: None,
                resource: target.clone(),
                operations: Vec::new(),
            },
        )
        .await
        .unwrap();

    let batch = repo
        .create_draft_operation_batch(DraftOperationBatchRequest {
            daemon_installation_id: "daemon_batch_ordering".to_owned(),
            operations: vec![
                DraftOperationBatchItem {
                    local_operation_id: "local_first".to_owned(),
                    draft_id: draft.draft.draft_id.clone(),
                    expected_draft_version: 1,
                    operation: DraftOperationInput {
                        action: DraftOperationAction::Update,
                        resource: target.clone(),
                        content: memory_content("# First"),
                        new_path: None,
                    },
                },
                DraftOperationBatchItem {
                    local_operation_id: "local_final".to_owned(),
                    draft_id: draft.draft.draft_id.clone(),
                    expected_draft_version: 2,
                    operation: DraftOperationInput {
                        action: DraftOperationAction::Update,
                        resource: target,
                        content: memory_content("# Final"),
                        new_path: None,
                    },
                },
            ],
        })
        .await
        .unwrap();
    assert_eq!(batch.accepted_operations, ["local_first", "local_final"]);

    sqlx::query(
        "UPDATE draft_operations
         SET operation_id = CASE content->>'content'
                WHEN '# First' THEN 'dop_z_batch_first'
                WHEN '# Final' THEN 'dop_a_batch_final'
                ELSE operation_id
             END,
             created_at = '2026-08-20T00:00:00Z'
         WHERE draft_id = $1",
    )
    .bind(&draft.draft.draft_id)
    .execute(&postgres.pool)
    .await
    .unwrap();

    let stored: Vec<(String, i64)> = sqlx::query_as(
        "SELECT content->>'content', ordinal
         FROM draft_operations
         WHERE draft_id = $1
         ORDER BY ordinal",
    )
    .bind(&draft.draft.draft_id)
    .fetch_all(&postgres.pool)
    .await
    .unwrap();
    assert_eq!(
        stored,
        vec![("# First".to_owned(), 1), ("# Final".to_owned(), 2)]
    );

    let detail = repo.get_draft(&draft.draft.draft_id).await.unwrap();
    assert_eq!(
        detail
            .operations
            .iter()
            .map(|operation| {
                (
                    operation.input.content.as_ref().unwrap().content.as_str(),
                    operation.operation_id.as_str(),
                )
            })
            .collect::<Vec<_>>(),
        vec![
            ("# First", "dop_z_batch_first"),
            ("# Final", "dop_a_batch_final"),
        ]
    );
    assert_eq!(detail.draft.version, 3);

    let events = repo
        .list_draft_events(&bootstrap.user_id, None, None)
        .await
        .unwrap()
        .events
        .into_iter()
        .filter(|event| event.draft_id == draft.draft.draft_id)
        .map(|event| (event.event_type, event.version))
        .collect::<Vec<_>>();
    assert_eq!(
        events,
        vec![
            (server::api::DraftEventType::Created, 1),
            (server::api::DraftEventType::OperationAppended, 2),
            (server::api::DraftEventType::OperationAppended, 3),
        ]
    );

    approve_and_merge(
        &repo,
        &bootstrap.user_id,
        head.as_deref(),
        &detail.draft.draft_id,
        detail.draft.version,
    )
    .await;
    assert_eq!(
        repo.get_org_memory(&bootstrap.org_id, &resource_id)
            .await
            .unwrap()
            .content,
        "# Final"
    );
}
