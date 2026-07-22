mod common;

use daemon::{
    DaemonConfig, DaemonCreateDraftOperation, DaemonDeleteDraftOperation, DaemonDraftContent,
    DaemonDraftListQuery, DaemonDraftOperation, DaemonDraftOperationRecordSource,
    DaemonDraftOperationRequest, DaemonDraftOperationSource, DaemonDraftResourceKind,
    DaemonDraftScope, DaemonIpcService, DaemonLocalDraftStatus, DaemonMemoryCacheRequest,
    DaemonProjectCheckoutRequest, DaemonProjectSelectionRequest, DaemonRenameDraftOperation,
    DaemonSyncRetryRequest, DaemonUpdateDraftOperation, DraftOperationSyncStatus, SyncRetryChannel,
    SyncState,
};
use server::api::{
    CreateDraftRequest, CreateReviewConflictResolutionRequest, CreateReviewDecisionRequest,
    CreateReviewMergeRequest, CreateReviewRequest, CreateReviewSubmissionRequest,
    DraftOperationAction, DraftOperationInput, DraftResourceContent, DraftResourceKind,
    DraftResourceRef, DraftStatus, ReplaceProjectOrgSelectionRequest, ResourceScope,
    ReviewDecision, ReviewMergeResult, ReviewStatus,
};
use server::repository::ServerRepository;
use sha2::{Digest, Sha256};

fn context_content(content: &str) -> DaemonDraftContent {
    DaemonDraftContent::Context {
        content: content.to_owned(),
    }
}

fn rule_content(content: &str) -> DaemonDraftContent {
    DaemonDraftContent::Rule {
        content: content.to_owned(),
    }
}

fn workflow_content(content: &str) -> DaemonDraftContent {
    DaemonDraftContent::Workflow {
        content: content.to_owned(),
    }
}

async fn approve_and_merge(
    repository: &ServerRepository,
    draft_id: &str,
    expected_draft_version: i64,
    expected_ref: Option<&str>,
) -> ReviewMergeResult {
    let review = repository
        .create_review(CreateReviewRequest {
            draft_id: draft_id.to_owned(),
            expected_draft_version,
            title: None,
            description: None,
        })
        .await
        .unwrap();
    let approved = repository
        .create_review_decision(
            &review.review.review_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    repository
        .create_review_merge(
            &approved.review.review_id,
            expected_ref,
            CreateReviewMergeRequest {
                expected_review_version: approved.review.version,
            },
        )
        .await
        .unwrap()
}

async fn sync_local_draft_and_merge(
    service: &DaemonIpcService,
    repository: &ServerRepository,
    local_draft_id: &str,
    expected_ref: Option<&str>,
) -> String {
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let projection = service.get_draft(local_draft_id).await.unwrap();
    let merge = approve_and_merge(
        repository,
        projection.draft.server_draft_id.as_deref().unwrap(),
        projection.draft.server_version,
        expected_ref,
    )
    .await;
    let commit_id = merge.commit_id.unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::All,
        })
        .await
        .unwrap();
    assert_eq!(
        service
            .get_draft(local_draft_id)
            .await
            .unwrap()
            .draft
            .status,
        DaemonLocalDraftStatus::Merged
    );
    commit_id
}

async fn create_resource_draft(
    service: &DaemonIpcService,
    project_id: &str,
    scope: DaemonDraftScope,
    resource: DaemonDraftResourceKind,
    path: &str,
    content: DaemonDraftContent,
    source: DaemonDraftOperationSource,
) -> String {
    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: project_id.to_owned(),
            scope,
            resource,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: path.to_owned(),
                    content,
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(source),
        })
        .await
        .unwrap()
        .draft_id
}

async fn update_and_rename_resource_draft(
    service: &DaemonIpcService,
    project_id: &str,
    target: (DaemonDraftScope, DaemonDraftResourceKind),
    resource_id: &str,
    content: DaemonDraftContent,
    new_path: &str,
    update_source: DaemonDraftOperationSource,
) -> String {
    let (scope, resource) = target;
    let draft_id = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: project_id.to_owned(),
            scope,
            resource,
            op: DaemonDraftOperation {
                create: None,
                update: Some(DaemonUpdateDraftOperation {
                    id: resource_id.to_owned(),
                    content,
                    description: None,
                }),
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(update_source),
        })
        .await
        .unwrap()
        .draft_id;
    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(draft_id.clone()),
            base_commit_id: None,
            project_id: project_id.to_owned(),
            scope,
            resource,
            op: DaemonDraftOperation {
                create: None,
                update: None,
                rename: Some(DaemonRenameDraftOperation {
                    id: resource_id.to_owned(),
                    new_path: new_path.to_owned(),
                    description: None,
                }),
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    draft_id
}

async fn delete_resource_draft(
    service: &DaemonIpcService,
    project_id: &str,
    scope: DaemonDraftScope,
    resource: DaemonDraftResourceKind,
    resource_id: &str,
) -> String {
    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: project_id.to_owned(),
            scope,
            resource,
            op: DaemonDraftOperation {
                create: None,
                update: None,
                rename: None,
                delete: Some(DaemonDeleteDraftOperation {
                    id: resource_id.to_owned(),
                    description: None,
                }),
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap()
        .draft_id
}

async fn cache_root_for_commit(
    service: &DaemonIpcService,
    project_id: &str,
    commit_id: &str,
) -> std::path::PathBuf {
    let cache = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: project_id.to_owned(),
        })
        .await
        .unwrap();
    assert_eq!(cache.commit_id.as_deref(), Some(commit_id));
    std::path::PathBuf::from(cache.root_path.unwrap())
}

#[tokio::test]
async fn local_draft_refreshes_auth_and_syncs_to_the_real_server() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = common::initialize_installation(pool.clone(), "Daemon Integration").await;

    let stale_access_token = "expired-daemon-access-token";
    let refresh_token = "daemon-integration-refresh-token";
    let token_hash = hex::encode(Sha256::digest(refresh_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_integration', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();

    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_refresh', 'ses_daemon_integration', $1,
            'refresh', $2, now() + interval '30 days'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let verification_pool = pool.clone();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });

    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{server_address}");
    config.project.project_id = Some(bootstrap.project_id.clone());
    let (state, credential_store) = common::initialize_authenticated_daemon(
        config,
        stale_access_token,
        Some(refresh_token.to_owned()),
    )
    .await;
    let service = DaemonIpcService::new(state);

    let local_draft = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/from-daemon.md".to_owned(),
                    content: context_content("# Synced\n\nCreated through the local daemon."),
                    description: Some("Real Server integration".to_owned()),
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::McpStore),
        })
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    let sync = service.sync_status().await.unwrap();
    assert_eq!(sync.pending_operation_count, 0);
    assert_eq!(sync.failed_operation_count, 0);
    assert!(sync.draft_sync.server_cursor.is_some());
    let project_config = service.project_config();
    assert!(project_config.has_access_token);
    assert!(project_config.has_refresh_token);
    let refreshed_credentials = credential_store.credentials().unwrap();
    assert_ne!(refreshed_credentials.access_token, stale_access_token);
    assert_ne!(
        refreshed_credentials.refresh_token.as_deref(),
        Some(refresh_token)
    );

    let active_token_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM access_tokens
         WHERE session_id = 'ses_daemon_integration' AND revoked_at IS NULL",
    )
    .fetch_one(&verification_pool)
    .await
    .unwrap();
    assert_eq!(active_token_count, 2);

    let drafts = repository
        .list_drafts(&bootstrap.user_id, Some(&bootstrap.project_id))
        .await
        .unwrap();
    assert_eq!(drafts.items.len(), 1);
    assert_eq!(drafts.items[0].author.user_id, bootstrap.user_id);
    let draft = repository
        .get_draft(&drafts.items[0].draft_id)
        .await
        .unwrap();
    assert_eq!(draft.operations.len(), 1);
    assert_eq!(
        draft.operations[0].input.content,
        Some(DraftResourceContent::Context {
            content: "# Synced\n\nCreated through the local daemon.".to_owned(),
        })
    );

    let review = repository
        .create_review(CreateReviewRequest {
            draft_id: draft.draft.draft_id.clone(),
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
        })
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let projected = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(projected.draft.status, DaemonLocalDraftStatus::Submitted);
    assert_eq!(projected.draft.server_version, review.draft.version);

    let rejected = repository
        .create_review_decision(
            &review.review.review_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Rejected,
                expected_review_version: review.review.version,
                body: Some("Revise the context.".to_owned()),
            },
        )
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let projected = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(projected.draft.status, DaemonLocalDraftStatus::Open);
    assert_eq!(projected.draft.server_version, rejected.draft.version);

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(local_draft.draft_id.clone()),
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/from-daemon.md".to_owned(),
                    content: context_content("# Revised\n\nEdited after the rejected review."),
                    description: Some("Rejected review revision".to_owned()),
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let edited = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(edited.draft.status, DaemonLocalDraftStatus::Open);
    assert_eq!(edited.draft.server_version, rejected.draft.version + 1);

    let resubmitted = repository
        .create_review_submission(
            &rejected.review.review_id,
            &bootstrap.user_id,
            CreateReviewSubmissionRequest {
                expected_review_version: rejected.review.version,
                expected_draft_version: edited.draft.server_version,
                title: Some("Revised daemon context".to_owned()),
                description: None,
            },
        )
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let projected = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(projected.draft.status, DaemonLocalDraftStatus::Submitted);
    assert_eq!(projected.draft.server_version, resubmitted.draft.version);
    assert_eq!(resubmitted.review.review_id, review.review.review_id);

    server_task.abort();
}

#[tokio::test]
async fn merged_context_drafts_are_terminal_across_update_rename_and_delete() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = common::initialize_installation(pool.clone(), "Context Lifecycle").await;

    let seed_draft = repository
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_seed_context".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: None,
                title: "Seed context".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some("context/original.md".to_owned()),
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
                        kind: DraftResourceKind::Context,
                        id: None,
                        path: Some("context/original.md".to_owned()),
                    },
                    content: Some(DraftResourceContent::Context {
                        content: "# Original\n\nBefore local editing.".to_owned(),
                    }),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let seed_merge = approve_and_merge(
        &repository,
        &seed_draft.draft.draft_id,
        seed_draft.draft.version,
        None,
    )
    .await;
    let seed_commit_id = seed_merge.commit_id.unwrap();
    let context_id = repository
        .list_project_context(&bootstrap.project_id)
        .await
        .unwrap()
        .items
        .into_iter()
        .find(|context| context.path == "context/original.md")
        .unwrap()
        .context_id;

    let access_token = "daemon-context-lifecycle-access-token";
    let token_hash = hex::encode(Sha256::digest(access_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_context_lifecycle', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_context_lifecycle', 'ses_daemon_context_lifecycle', $1,
            'access', $2, now() + interval '30 minutes'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{server_address}");
    config.project.project_id = Some(bootstrap.project_id.clone());
    let (state, _) = common::initialize_authenticated_daemon(config, access_token, None).await;
    let service = DaemonIpcService::new(state);
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();

    let update_draft = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: None,
                update: Some(DaemonUpdateDraftOperation {
                    id: context_id.clone(),
                    content: context_content("# Renamed\n\nUpdated through the daemon."),
                    description: None,
                }),
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(update_draft.draft_id.clone()),
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: None,
                update: None,
                rename: Some(DaemonRenameDraftOperation {
                    id: context_id.clone(),
                    new_path: "context/renamed.md".to_owned(),
                    description: None,
                }),
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let update_projection = service.get_draft(&update_draft.draft_id).await.unwrap();
    let update_merge = approve_and_merge(
        &repository,
        update_projection.draft.server_draft_id.as_deref().unwrap(),
        update_projection.draft.server_version,
        Some(&seed_commit_id),
    )
    .await;
    let update_commit_id = update_merge.commit_id.unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::All,
        })
        .await
        .unwrap();
    let merged_update = service.get_draft(&update_draft.draft_id).await.unwrap();
    assert_eq!(merged_update.draft.status, DaemonLocalDraftStatus::Merged);
    let cache = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: bootstrap.project_id.clone(),
        })
        .await
        .unwrap();
    let cache_root = std::path::PathBuf::from(cache.root_path.unwrap());
    assert!(
        !cache_root
            .join("cache/context/context/original.md")
            .exists()
    );
    assert_eq!(
        std::fs::read_to_string(cache_root.join("cache/context/context/renamed.md")).unwrap(),
        "# Renamed\n\nUpdated through the daemon."
    );

    let delete_draft = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: None,
                update: None,
                rename: None,
                delete: Some(DaemonDeleteDraftOperation {
                    id: context_id,
                    description: None,
                }),
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    assert_ne!(delete_draft.draft_id, update_draft.draft_id);
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let delete_projection = service.get_draft(&delete_draft.draft_id).await.unwrap();
    let delete_merge = approve_and_merge(
        &repository,
        delete_projection.draft.server_draft_id.as_deref().unwrap(),
        delete_projection.draft.server_version,
        Some(&update_commit_id),
    )
    .await;
    let delete_commit_id = delete_merge.commit_id.unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::All,
        })
        .await
        .unwrap();
    let merged_delete = service.get_draft(&delete_draft.draft_id).await.unwrap();
    assert_eq!(merged_delete.draft.status, DaemonLocalDraftStatus::Merged);
    let deleted_cache = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: bootstrap.project_id.clone(),
        })
        .await
        .unwrap();
    assert_eq!(
        deleted_cache.commit_id.as_deref(),
        Some(delete_commit_id.as_str())
    );
    let deleted_cache_root = std::path::PathBuf::from(deleted_cache.root_path.unwrap());
    assert_ne!(deleted_cache_root, cache_root);
    assert!(cache_root.join("cache/context/context/renamed.md").exists());
    assert!(
        !deleted_cache_root
            .join("cache/context/context/renamed.md")
            .exists()
    );
    assert!(
        repository
            .list_project_context(&bootstrap.project_id)
            .await
            .unwrap()
            .items
            .is_empty()
    );

    server_task.abort();
}

#[tokio::test]
async fn offline_draft_converges_through_stale_ref_conflict_resolution() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = common::initialize_installation(pool.clone(), "Offline Conflict").await;

    let base_draft = repository
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_conflict_seed".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: None,
                title: "Seed conflict base".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some("context/base.md".to_owned()),
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
                        kind: DraftResourceKind::Context,
                        id: None,
                        path: Some("context/base.md".to_owned()),
                    },
                    content: Some(DraftResourceContent::Context {
                        content: "# Base\n\nThe offline Draft starts from this Commit.".to_owned(),
                    }),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let base_merge = approve_and_merge(
        &repository,
        &base_draft.draft.draft_id,
        base_draft.draft.version,
        None,
    )
    .await;
    let base_commit_id = base_merge.commit_id.unwrap();

    let access_token = "daemon-offline-conflict-access-token";
    let token_hash = hex::encode(Sha256::digest(access_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_offline_conflict', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_offline_conflict', 'ses_daemon_offline_conflict', $1,
            'access', $2, now() + interval '30 minutes'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let server_url = format!("http://{server_address}");
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server_url.clone();
    config.project.project_id = Some(bootstrap.project_id.clone());
    let (state, _) = common::initialize_authenticated_daemon(config, access_token, None).await;
    let service = DaemonIpcService::new(state);
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();

    service
        .replace_project_config(daemon::DaemonProjectConfigUpdateRequest {
            server_url: "http://127.0.0.1:1".to_owned(),
            project_id: Some(bootstrap.project_id.clone()),
            access_token: Some(access_token.to_owned()),
            refresh_token: None,
        })
        .await
        .unwrap();
    let local_draft = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/offline-conflict.md".to_owned(),
                    content: context_content(
                        "# Offline conflict\n\nThis content must survive recovery and resolution.",
                    ),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    assert!(
        service
            .retry_sync(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::Drafts,
            })
            .await
            .is_err()
    );
    let retrying = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(
        retrying.draft.base_commit_id.as_deref(),
        Some(base_commit_id.as_str())
    );
    assert_eq!(
        retrying.operations[0].sync_status,
        DraftOperationSyncStatus::Retrying
    );

    let remote_draft = repository
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_remote_change".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: Some(base_commit_id.clone()),
                title: "Advance the remote Ref".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some("context/remote-change.md".to_owned()),
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
                        kind: DraftResourceKind::Context,
                        id: None,
                        path: Some("context/remote-change.md".to_owned()),
                    },
                    content: Some(DraftResourceContent::Context {
                        content: "# Remote change\n\nThis advances the Project Ref.".to_owned(),
                    }),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let remote_merge = approve_and_merge(
        &repository,
        &remote_draft.draft.draft_id,
        remote_draft.draft.version,
        Some(&base_commit_id),
    )
    .await;
    let current_commit_id = remote_merge.commit_id.unwrap();

    service
        .replace_project_config(daemon::DaemonProjectConfigUpdateRequest {
            server_url: server_url.clone(),
            project_id: Some(bootstrap.project_id.clone()),
            access_token: Some(access_token.to_owned()),
            refresh_token: None,
        })
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let uploaded = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(uploaded.draft.status, DaemonLocalDraftStatus::Open);
    assert_eq!(
        uploaded.draft.base_commit_id.as_deref(),
        Some(base_commit_id.as_str())
    );
    assert_eq!(uploaded.operations.len(), 1);
    assert_eq!(
        uploaded.operations[0].sync_status,
        DraftOperationSyncStatus::Synced
    );

    service
        .replace_project_config(daemon::DaemonProjectConfigUpdateRequest {
            server_url: "http://127.0.0.1:1".to_owned(),
            project_id: Some(bootstrap.project_id.clone()),
            access_token: Some(access_token.to_owned()),
            refresh_token: None,
        })
        .await
        .unwrap();
    let later_offline_content =
        "# Offline conflict\n\nThis later offline edit must be included in the resolution.";
    let later_offline_operation = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(local_draft.draft_id.clone()),
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/offline-conflict.md".to_owned(),
                    content: context_content(later_offline_content),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    assert!(
        service
            .retry_sync(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::Drafts,
            })
            .await
            .is_err()
    );
    let later_offline = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(later_offline.operations.len(), 2);
    assert_eq!(
        later_offline
            .operations
            .iter()
            .find(|operation| {
                operation.local_operation_id == later_offline_operation.local_operation_id
            })
            .unwrap()
            .sync_status,
        DraftOperationSyncStatus::Retrying
    );

    let review = repository
        .create_review(CreateReviewRequest {
            draft_id: uploaded.draft.server_draft_id.clone().unwrap(),
            expected_draft_version: uploaded.draft.server_version,
            title: None,
            description: None,
        })
        .await
        .unwrap();
    let approved = repository
        .create_review_decision(
            &review.review.review_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    assert!(
        repository
            .create_review_merge(
                &approved.review.review_id,
                Some(&current_commit_id),
                CreateReviewMergeRequest {
                    expected_review_version: approved.review.version,
                },
            )
            .await
            .is_err()
    );

    service
        .replace_project_config(daemon::DaemonProjectConfigUpdateRequest {
            server_url,
            project_id: Some(bootstrap.project_id.clone()),
            access_token: Some(access_token.to_owned()),
            refresh_token: None,
        })
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let projected_conflict = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(
        projected_conflict.draft.status,
        DaemonLocalDraftStatus::Conflicted
    );
    let conflict = projected_conflict.draft.conflict.as_ref().unwrap();
    assert_eq!(
        conflict.base_commit_id.as_deref(),
        Some(base_commit_id.as_str())
    );
    assert_eq!(
        conflict.current_commit_id.as_deref(),
        Some(current_commit_id.as_str())
    );
    let failed_offline_operation = projected_conflict
        .operations
        .iter()
        .find(|operation| {
            operation.local_operation_id == later_offline_operation.local_operation_id
        })
        .unwrap();
    assert_eq!(
        failed_offline_operation.sync_status,
        DraftOperationSyncStatus::Failed
    );
    assert_eq!(
        failed_offline_operation
            .operation
            .create
            .as_ref()
            .unwrap()
            .content,
        context_content(later_offline_content)
    );
    assert_eq!(
        service.sync_status().await.unwrap().draft_sync.state,
        SyncState::Failed
    );

    let conflicted = repository
        .get_review_detail(&approved.review.review_id)
        .await
        .unwrap();
    assert_eq!(conflicted.review.status, ReviewStatus::Approved);
    assert_eq!(conflicted.draft.status, DraftStatus::Conflicted);
    assert_eq!(conflicted.operations.len(), 1);
    let mut resolved_operations = conflicted
        .operations
        .iter()
        .map(|operation| operation.input.clone())
        .collect::<Vec<_>>();
    resolved_operations.last_mut().unwrap().content = Some(DraftResourceContent::Context {
        content: later_offline_content.to_owned(),
    });
    let resolved = repository
        .create_review_conflict_resolution(
            &conflicted.review.review_id,
            &bootstrap.user_id,
            Some(&current_commit_id),
            CreateReviewConflictResolutionRequest {
                expected_review_version: conflicted.review.version,
                expected_draft_version: conflicted.draft.version,
                operations: resolved_operations,
            },
        )
        .await
        .unwrap();
    assert_eq!(resolved.review.status, ReviewStatus::Open);
    assert_eq!(resolved.draft.status, DraftStatus::Submitted);
    assert_eq!(
        resolved.draft.base_commit_id.as_deref(),
        Some(current_commit_id.as_str())
    );
    assert!(resolved.conflict.is_none());

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let projected_resolution = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(
        projected_resolution.draft.status,
        DaemonLocalDraftStatus::Submitted
    );
    assert_eq!(
        projected_resolution.draft.base_commit_id.as_deref(),
        Some(current_commit_id.as_str())
    );
    assert!(projected_resolution.draft.conflict.is_none());
    assert_eq!(projected_resolution.operations.len(), 1);
    assert_eq!(
        projected_resolution.operations[0].local_operation_id,
        later_offline_operation.local_operation_id
    );
    assert_eq!(
        projected_resolution.operations[0].sync_status,
        DraftOperationSyncStatus::Synced
    );
    assert!(projected_resolution.operations[0].last_error.is_none());
    assert_eq!(
        projected_resolution.operations[0]
            .operation
            .create
            .as_ref()
            .unwrap()
            .content,
        context_content(later_offline_content)
    );
    let resolved_sync_status = service.sync_status().await.unwrap();
    assert_eq!(resolved_sync_status.failed_operation_count, 0);
    assert_eq!(resolved_sync_status.draft_sync.state, SyncState::Idle);

    let reapproved = repository
        .create_review_decision(
            &resolved.review.review_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: resolved.review.version,
                body: Some("Resolved against the current Ref.".to_owned()),
            },
        )
        .await
        .unwrap();
    let final_merge = repository
        .create_review_merge(
            &reapproved.review.review_id,
            Some(&current_commit_id),
            CreateReviewMergeRequest {
                expected_review_version: reapproved.review.version,
            },
        )
        .await
        .unwrap();
    let final_commit_id = final_merge.commit_id.unwrap();
    assert_ne!(final_commit_id, current_commit_id);

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::All,
        })
        .await
        .unwrap();
    let merged = service.get_draft(&local_draft.draft_id).await.unwrap();
    assert_eq!(merged.draft.status, DaemonLocalDraftStatus::Merged);
    assert!(merged.draft.conflict.is_none());
    let cache = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: bootstrap.project_id,
        })
        .await
        .unwrap();
    assert_eq!(cache.commit_id.as_deref(), Some(final_commit_id.as_str()));
    let cache_root = std::path::PathBuf::from(cache.root_path.unwrap());
    assert_eq!(
        std::fs::read_to_string(cache_root.join("cache/context/context/offline-conflict.md"))
            .unwrap(),
        later_offline_content
    );
    assert!(
        cache_root
            .join("cache/context/context/remote-change.md")
            .is_file()
    );

    server_task.abort();
}

#[tokio::test]
async fn rule_and_workflow_crud_preserve_materialized_markdown() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = common::initialize_installation(pool.clone(), "Structured Lifecycle").await;

    let access_token = "daemon-structured-lifecycle-access-token";
    let token_hash = hex::encode(Sha256::digest(access_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_structured_lifecycle', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_structured_lifecycle', 'ses_daemon_structured_lifecycle', $1,
            'access', $2, now() + interval '30 minutes'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{server_address}");
    config.project.project_id = Some(bootstrap.project_id.clone());
    let (state, _) = common::initialize_authenticated_daemon(config, access_token, None).await;
    let service = DaemonIpcService::new(state);

    let create_rule = create_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Project,
        DaemonDraftResourceKind::Rule,
        "rules/memory-review",
        rule_content(
            "# Memory review discipline\n\nApply when publishing durable memory.\n\nReview every memory change before merge.\n\nTags: memory, review",
        ),
        DaemonDraftOperationSource::Desktop,
    )
    .await;
    let rule_create_commit =
        sync_local_draft_and_merge(&service, &repository, &create_rule, None).await;
    let rule_meta = repository
        .list_project_rules(&bootstrap.project_id)
        .await
        .unwrap()
        .items
        .into_iter()
        .find(|rule| rule.path == "rules/memory-review")
        .unwrap();
    let rule_id = rule_meta.rule_id;
    let created_rule = repository
        .get_project_rule(&bootstrap.project_id, &rule_id)
        .await
        .unwrap();
    assert_eq!(created_rule.rule.name, "memory-review");
    assert_eq!(
        created_rule.content,
        "# Memory review discipline\n\nApply when publishing durable memory.\n\nReview every memory change before merge.\n\nTags: memory, review"
    );
    let rule_create_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &rule_create_commit).await;
    assert_eq!(
        std::fs::read_to_string(rule_create_root.join("cache/rule/rules/memory-review")).unwrap(),
        created_rule.content
    );

    let create_workflow = create_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Project,
        DaemonDraftResourceKind::Workflow,
        "workflow/memory-publication",
        workflow_content(&format!(
            "# Memory publication\n\nPublish durable memory safely.\n\n1. Apply rule `{rule_id}`.\n2. Verify the materialized generation."
        )),
        DaemonDraftOperationSource::Desktop,
    )
    .await;
    let workflow_create_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &create_workflow,
        Some(&rule_create_commit),
    )
    .await;
    let workflow_meta = repository
        .list_project_workflows(&bootstrap.project_id)
        .await
        .unwrap()
        .items
        .into_iter()
        .find(|workflow| workflow.path == "workflow/memory-publication")
        .unwrap();
    let workflow_id = workflow_meta.workflow_id;
    let created_workflow = repository
        .get_project_workflow(&bootstrap.project_id, &workflow_id)
        .await
        .unwrap();
    assert_eq!(
        created_workflow.content,
        format!(
            "# Memory publication\n\nPublish durable memory safely.\n\n1. Apply rule `{rule_id}`.\n2. Verify the materialized generation."
        )
    );
    let workflow_create_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &workflow_create_commit).await;
    assert_eq!(
        std::fs::read_to_string(
            workflow_create_root.join("cache/rule/workflow/memory-publication")
        )
        .unwrap(),
        format!(
            "# Memory publication\n\nPublish durable memory safely.\n\n1. Apply rule `{rule_id}`.\n2. Verify the materialized generation."
        )
    );

    let update_rule = update_and_rename_resource_draft(
        &service,
        &bootstrap.project_id,
        (DaemonDraftScope::Project, DaemonDraftResourceKind::Rule),
        &rule_id,
        rule_content(
            "# Memory review discipline\n\nApply when publishing durable memory.\n\nReview the change and its materialized result before merge.\n\nTags: memory, review, verification",
        ),
        "rules/memory-review-policy",
        DaemonDraftOperationSource::McpStore,
    )
    .await;
    let rule_update_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &update_rule,
        Some(&workflow_create_commit),
    )
    .await;
    let updated_rule = repository
        .get_project_rule(&bootstrap.project_id, &rule_id)
        .await
        .unwrap();
    assert_eq!(updated_rule.rule.path, "rules/memory-review-policy");
    assert_eq!(
        updated_rule.content,
        "# Memory review discipline\n\nApply when publishing durable memory.\n\nReview the change and its materialized result before merge.\n\nTags: memory, review, verification"
    );
    let rule_update_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &rule_update_commit).await;
    assert!(
        !rule_update_root
            .join("cache/rule/rules/memory-review")
            .exists()
    );
    assert!(
        rule_update_root
            .join("cache/rule/rules/memory-review-policy")
            .exists()
    );
    assert!(
        workflow_create_root
            .join("cache/rule/rules/memory-review")
            .exists()
    );

    let update_workflow = update_and_rename_resource_draft(
        &service,
        &bootstrap.project_id,
        (DaemonDraftScope::Project, DaemonDraftResourceKind::Workflow),
        &workflow_id,
        workflow_content(&format!(
            "# Memory publication\n\nPublish and verify durable memory.\n\n1. Verify the materialized generation.\n2. Apply rule `{rule_id}`."
        )),
        "workflow/memory-publish",
        DaemonDraftOperationSource::Desktop,
    )
    .await;
    let workflow_update_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &update_workflow,
        Some(&rule_update_commit),
    )
    .await;
    let updated_workflow = repository
        .get_project_workflow(&bootstrap.project_id, &workflow_id)
        .await
        .unwrap();
    assert_eq!(updated_workflow.workflow.path, "workflow/memory-publish");
    assert_eq!(
        updated_workflow.content,
        format!(
            "# Memory publication\n\nPublish and verify durable memory.\n\n1. Verify the materialized generation.\n2. Apply rule `{rule_id}`."
        )
    );
    let workflow_update_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &workflow_update_commit).await;
    assert!(
        !workflow_update_root
            .join("cache/rule/workflow/memory-publication")
            .exists()
    );
    assert_eq!(
        std::fs::read_to_string(workflow_update_root.join("cache/rule/workflow/memory-publish"))
            .unwrap(),
        format!(
            "# Memory publication\n\nPublish and verify durable memory.\n\n1. Verify the materialized generation.\n2. Apply rule `{rule_id}`."
        )
    );
    assert!(
        workflow_create_root
            .join("cache/rule/workflow/memory-publication")
            .exists()
    );

    let delete_workflow = delete_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Project,
        DaemonDraftResourceKind::Workflow,
        &workflow_id,
    )
    .await;
    let workflow_delete_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &delete_workflow,
        Some(&workflow_update_commit),
    )
    .await;
    assert!(matches!(
        repository
            .get_project_workflow(&bootstrap.project_id, &workflow_id)
            .await,
        Err(server::repository::ServerError::NotFound { .. })
    ));
    let workflow_delete_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &workflow_delete_commit).await;
    assert!(
        !workflow_delete_root
            .join("cache/rule/workflow/memory-publish")
            .exists()
    );
    assert!(
        workflow_update_root
            .join("cache/rule/workflow/memory-publish")
            .exists()
    );

    let delete_rule = delete_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Project,
        DaemonDraftResourceKind::Rule,
        &rule_id,
    )
    .await;
    let rule_delete_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &delete_rule,
        Some(&workflow_delete_commit),
    )
    .await;
    assert!(matches!(
        repository
            .get_project_rule(&bootstrap.project_id, &rule_id)
            .await,
        Err(server::repository::ServerError::NotFound { .. })
    ));
    let rule_delete_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &rule_delete_commit).await;
    assert!(
        !rule_delete_root
            .join("cache/rule/rules/memory-review-policy")
            .exists()
    );
    assert!(
        workflow_delete_root
            .join("cache/rule/rules/memory-review-policy")
            .exists()
    );

    server_task.abort();
}

#[tokio::test]
async fn selected_hub_rule_and_workflow_changes_converge_without_reselection() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = common::initialize_installation(pool.clone(), "Selected Hub Lifecycle").await;

    let access_token = "daemon-selected-hub-lifecycle-access-token";
    let token_hash = hex::encode(Sha256::digest(access_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_selected_hub_lifecycle', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_selected_hub_lifecycle', 'ses_daemon_selected_hub_lifecycle', $1,
            'access', $2, now() + interval '30 minutes'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{server_address}");
    config.project.project_id = Some(bootstrap.project_id.clone());
    let (state, _) = common::initialize_authenticated_daemon(config, access_token, None).await;
    let service = DaemonIpcService::new(state);
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();

    let create_rule = create_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Org,
        DaemonDraftResourceKind::Rule,
        "rules/shared-review",
        rule_content(
            "# Shared review discipline\n\nReview shared memory before merge.\n\nTags: hub, review",
        ),
        DaemonDraftOperationSource::Desktop,
    )
    .await;
    let org_rule_commit =
        sync_local_draft_and_merge(&service, &repository, &create_rule, None).await;
    let rule = repository
        .list_org_rules(&bootstrap.org_id)
        .await
        .unwrap()
        .items
        .into_iter()
        .find(|rule| rule.path == "rules/shared-review")
        .unwrap();
    let rule_id = rule.rule_id;

    let create_workflow = create_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Org,
        DaemonDraftResourceKind::Workflow,
        "workflow/shared-publication",
        workflow_content(&format!(
            "# Shared publication\n\nPublish organization memory safely.\n\n1. Apply rule `{rule_id}`.\n2. Confirm the effective project memory."
        )),
        DaemonDraftOperationSource::McpStore,
    )
    .await;
    let org_workflow_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &create_workflow,
        Some(&org_rule_commit),
    )
    .await;
    let workflow = repository
        .list_org_workflows(&bootstrap.org_id)
        .await
        .unwrap()
        .items
        .into_iter()
        .find(|workflow| workflow.path == "workflow/shared-publication")
        .unwrap();
    let workflow_id = workflow.workflow_id;

    let selection = repository
        .replace_project_org_selection(
            &bootstrap.project_id,
            0,
            ReplaceProjectOrgSelectionRequest {
                rule_ids: vec![rule_id.clone()],
                context_ids: Vec::new(),
                workflow_ids: vec![workflow_id.clone()],
            },
        )
        .await
        .unwrap();
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();
    let selected_project_commit = repository
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();
    let selected_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &selected_project_commit).await;
    assert!(
        selected_root
            .join("cache/rule/rules/shared-review")
            .exists()
    );
    assert!(
        selected_root
            .join("cache/rule/workflow/shared-publication")
            .exists()
    );

    let update_rule = update_and_rename_resource_draft(
        &service,
        &bootstrap.project_id,
        (DaemonDraftScope::Org, DaemonDraftResourceKind::Rule),
        &rule_id,
        rule_content(
            "# Shared review discipline\n\nReview shared memory and its project projections before merge.\n\nTags: hub, review, projection",
        ),
        "rules/shared-review-policy",
        DaemonDraftOperationSource::Desktop,
    )
    .await;
    let org_rule_update_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &update_rule,
        Some(&org_workflow_commit),
    )
    .await;
    let rule_update_project_commit = repository
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();
    assert_ne!(rule_update_project_commit, selected_project_commit);
    assert_ne!(rule_update_project_commit, org_rule_update_commit);
    let rule_update_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &rule_update_project_commit).await;
    assert!(
        !rule_update_root
            .join("cache/rule/rules/shared-review")
            .exists()
    );
    assert_eq!(
        std::fs::read_to_string(rule_update_root.join("cache/rule/rules/shared-review-policy"))
            .unwrap(),
        "# Shared review discipline\n\nReview shared memory and its project projections before merge.\n\nTags: hub, review, projection"
    );
    assert!(
        selected_root
            .join("cache/rule/rules/shared-review")
            .exists()
    );

    let update_workflow = update_and_rename_resource_draft(
        &service,
        &bootstrap.project_id,
        (DaemonDraftScope::Org, DaemonDraftResourceKind::Workflow),
        &workflow_id,
        workflow_content(&format!(
            "# Shared publication\n\nPublish and verify organization memory.\n\n1. Confirm the effective project memory.\n2. Apply rule `{rule_id}`."
        )),
        "workflow/shared-publish",
        DaemonDraftOperationSource::McpStore,
    )
    .await;
    let org_workflow_update_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &update_workflow,
        Some(&org_rule_update_commit),
    )
    .await;
    let workflow_update_project_commit = repository
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();
    assert_ne!(workflow_update_project_commit, rule_update_project_commit);
    let workflow_update_root = cache_root_for_commit(
        &service,
        &bootstrap.project_id,
        &workflow_update_project_commit,
    )
    .await;
    assert!(
        !workflow_update_root
            .join("cache/rule/workflow/shared-publication")
            .exists()
    );
    assert_eq!(
        std::fs::read_to_string(workflow_update_root.join("cache/rule/workflow/shared-publish"))
            .unwrap(),
        format!(
            "# Shared publication\n\nPublish and verify organization memory.\n\n1. Confirm the effective project memory.\n2. Apply rule `{rule_id}`."
        )
    );

    let delete_workflow = delete_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Org,
        DaemonDraftResourceKind::Workflow,
        &workflow_id,
    )
    .await;
    let org_workflow_delete_commit = sync_local_draft_and_merge(
        &service,
        &repository,
        &delete_workflow,
        Some(&org_workflow_update_commit),
    )
    .await;
    let workflow_delete_project_commit = repository
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();
    let workflow_delete_root = cache_root_for_commit(
        &service,
        &bootstrap.project_id,
        &workflow_delete_project_commit,
    )
    .await;
    assert!(
        !workflow_delete_root
            .join("cache/rule/workflow/shared-publish")
            .exists()
    );
    assert!(
        workflow_delete_root
            .join("cache/rule/rules/shared-review-policy")
            .exists()
    );
    let selection_after_workflow_delete = repository
        .get_project_org_selection(&bootstrap.project_id)
        .await
        .unwrap();
    assert_eq!(
        selection_after_workflow_delete.revision,
        selection.revision + 1
    );
    assert!(selection_after_workflow_delete.workflows.is_empty());
    assert_eq!(selection_after_workflow_delete.rules.len(), 1);

    let delete_rule = delete_resource_draft(
        &service,
        &bootstrap.project_id,
        DaemonDraftScope::Org,
        DaemonDraftResourceKind::Rule,
        &rule_id,
    )
    .await;
    sync_local_draft_and_merge(
        &service,
        &repository,
        &delete_rule,
        Some(&org_workflow_delete_commit),
    )
    .await;
    let rule_delete_project_commit = repository
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();
    let rule_delete_root =
        cache_root_for_commit(&service, &bootstrap.project_id, &rule_delete_project_commit).await;
    assert!(
        !rule_delete_root
            .join("cache/rule/rules/shared-review-policy")
            .exists()
    );
    let final_selection = repository
        .get_project_org_selection(&bootstrap.project_id)
        .await
        .unwrap();
    assert_eq!(final_selection.revision, selection.revision + 2);
    assert!(final_selection.rules.is_empty());
    assert!(final_selection.workflows.is_empty());
    assert!(
        workflow_update_root
            .join("cache/rule/workflow/shared-publish")
            .exists()
    );
    assert!(matches!(
        repository.get_org_rule(&bootstrap.org_id, &rule_id).await,
        Err(server::repository::ServerError::NotFound { .. })
    ));
    assert!(matches!(
        repository
            .get_org_workflow(&bootstrap.org_id, &workflow_id)
            .await,
        Err(server::repository::ServerError::NotFound { .. })
    ));

    server_task.abort();
}

#[tokio::test]
async fn two_daemon_installations_converge_on_the_same_draft_history() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let bootstrap = common::initialize_installation(pool.clone(), "Daemon Convergence").await;

    let access_token = "daemon-convergence-access-token";
    let token_hash = hex::encode(Sha256::digest(access_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_convergence', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_convergence', 'ses_daemon_convergence', $1,
            'access', $2, now() + interval '30 minutes'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });

    let root_a = tempfile::tempdir().unwrap();
    let mut config_a = DaemonConfig::for_root(root_a.path());
    config_a.project.server_url = format!("http://{server_address}");
    config_a.project.project_id = Some(bootstrap.project_id.clone());
    let (state_a, credential_store_a) =
        common::initialize_authenticated_daemon(config_a.clone(), access_token, None).await;
    let service_a = DaemonIpcService::new(state_a);

    let root_b = tempfile::tempdir().unwrap();
    let mut config_b = DaemonConfig::for_root(root_b.path());
    config_b.project.server_url = format!("http://{server_address}");
    config_b.project.project_id = Some(bootstrap.project_id.clone());
    let (state_b, _) = common::initialize_authenticated_daemon(config_b, access_token, None).await;
    let service_b = DaemonIpcService::new(state_b);

    let first = service_a
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/converged.md".to_owned(),
                    content: context_content("First installation"),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::McpStore),
        })
        .await
        .unwrap();
    service_a
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    service_b
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let drafts_b = service_b
        .list_drafts(DaemonDraftListQuery::default())
        .await
        .unwrap();
    assert_eq!(drafts_b.items.len(), 1);
    assert_eq!(drafts_b.items[0].server_version, 1);
    let projected_on_b = service_b
        .get_draft(&drafts_b.items[0].draft_id)
        .await
        .unwrap();
    assert_eq!(projected_on_b.operations.len(), 1);
    assert_eq!(
        projected_on_b.operations[0].source,
        DaemonDraftOperationRecordSource::Server
    );
    assert_eq!(
        projected_on_b.operations[0]
            .operation
            .create
            .as_ref()
            .unwrap()
            .content,
        context_content("First installation")
    );

    service_b
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(projected_on_b.draft.draft_id.clone()),
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/converged.md".to_owned(),
                    content: context_content("Second installation"),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    service_b
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    service_a
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    let converged_a = service_a.get_draft(&first.draft_id).await.unwrap();
    let converged_b = service_b
        .get_draft(&projected_on_b.draft.draft_id)
        .await
        .unwrap();
    assert_eq!(converged_a.draft.server_version, 2);
    assert_eq!(converged_b.draft.server_version, 2);
    assert_eq!(converged_a.operations.len(), 2);
    assert_eq!(converged_b.operations.len(), 2);
    assert_eq!(
        converged_a.operations[0].source,
        DaemonDraftOperationRecordSource::McpStore
    );
    assert_eq!(
        converged_a.operations[1].source,
        DaemonDraftOperationRecordSource::Server
    );
    assert_eq!(
        converged_a.operations[1]
            .operation
            .create
            .as_ref()
            .unwrap()
            .content,
        context_content("Second installation")
    );

    service_a
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    service_b
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    assert_eq!(
        service_a
            .get_draft(&first.draft_id)
            .await
            .unwrap()
            .operations
            .len(),
        2
    );

    drop(service_a);
    let restarted_a = DaemonIpcService::new(
        common::initialize_daemon(config_a, credential_store_a.clone()).await,
    );
    restarted_a
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    let after_restart = restarted_a.get_draft(&first.draft_id).await.unwrap();
    assert_eq!(after_restart.draft.server_version, 2);
    assert_eq!(after_restart.operations.len(), 2);

    server_task.abort();
}

#[tokio::test]
async fn merged_commit_materializes_on_two_daemons_and_survives_restart() {
    let postgres = common::start_postgres().await;
    let port = postgres.port;
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = common::initialize_installation(pool.clone(), "Commit Convergence").await;

    let access_token = "daemon-commit-convergence-access-token";
    let token_hash = hex::encode(Sha256::digest(access_token.as_bytes()));
    sqlx::query(
        "INSERT INTO auth_sessions (session_id, user_id, org_id)
         VALUES ('ses_daemon_commit_convergence', $1, $2)",
    )
    .bind(&bootstrap.user_id)
    .bind(&bootstrap.org_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO access_tokens (
            token_id, session_id, user_id, kind, token_hash, expires_at
         ) VALUES (
            'tok_daemon_commit_convergence', 'ses_daemon_commit_convergence', $1,
            'access', $2, now() + interval '30 minutes'
         )",
    )
    .bind(&bootstrap.user_id)
    .bind(token_hash)
    .execute(&pool)
    .await
    .unwrap();

    let secondary_project_id = repository
        .create_project(&bootstrap.org_id, "Secondary Memory", "")
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role)
         VALUES ($1, $2, 'admin')",
    )
    .bind(&secondary_project_id)
    .bind(&bootstrap.user_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO resources (
            resource_id, org_id, project_id, scope, resource_kind, path, name,
            status, content_hash, body, context_kind
         ) VALUES (
            'ctx_secondary_project', $1, $2, 'project', 'context',
            'context/secondary.md', 'Secondary', 'active', 'secondary-hash',
            '# Secondary project', 'file'
         )",
    )
    .bind(&bootstrap.org_id)
    .bind(&secondary_project_id)
    .execute(&pool)
    .await
    .unwrap();
    repository
        .replace_project_org_selection(
            &secondary_project_id,
            0,
            ReplaceProjectOrgSelectionRequest {
                rule_ids: Vec::new(),
                context_ids: Vec::new(),
                workflow_ids: Vec::new(),
            },
        )
        .await
        .unwrap();
    let secondary_commit_id = repository
        .get_project_commit_state(&secondary_project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_address = listener.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, server::http::router(pool))
            .await
            .unwrap();
    });

    let root_a = tempfile::tempdir().unwrap();
    let mut config_a = DaemonConfig::for_root(root_a.path());
    config_a.project.server_url = format!("http://{server_address}");
    config_a.project.project_id = Some(bootstrap.project_id.clone());
    let (state_a, credential_store_a) =
        common::initialize_authenticated_daemon(config_a.clone(), access_token, None).await;
    let service_a = DaemonIpcService::new(state_a);

    let root_b = tempfile::tempdir().unwrap();
    let mut config_b = DaemonConfig::for_root(root_b.path());
    config_b.project.server_url = format!("http://{server_address}");
    config_b.project.project_id = Some(bootstrap.project_id.clone());
    let (state_b, _) = common::initialize_authenticated_daemon(config_b, access_token, None).await;
    let service_b = DaemonIpcService::new(state_b);

    for service in [&service_a, &service_b] {
        service
            .retry_sync(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::Commits,
            })
            .await
            .unwrap();
        let empty = service
            .memory_cache(DaemonMemoryCacheRequest {
                project_id: bootstrap.project_id.clone(),
            })
            .await
            .unwrap();
        assert!(empty.ready);
        assert_eq!(empty.commit_id, None);
        let empty_checkout = service
            .project_checkout(DaemonProjectCheckoutRequest {
                project_id: bootstrap.project_id.clone(),
            })
            .await
            .unwrap();
        assert!(empty_checkout.ready);
        assert_eq!(empty_checkout.commit_id, None);
        assert!(empty_checkout.resources.is_empty());
    }

    let draft = repository
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_commit_origin".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: None,
                title: "Add synchronized context".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    kind: DraftResourceKind::Context,
                    id: None,
                    path: Some("context/commit-sync.md".to_owned()),
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
                        kind: DraftResourceKind::Context,
                        id: None,
                        path: Some("context/commit-sync.md".to_owned()),
                    },
                    content: Some(DraftResourceContent::Context {
                        content: "# Commit sync\n\nInstalled from an immutable Commit.".to_owned(),
                    }),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();
    let review = repository
        .create_review(CreateReviewRequest {
            draft_id: draft.draft.draft_id,
            expected_draft_version: draft.draft.version,
            title: None,
            description: None,
        })
        .await
        .unwrap();
    let approved = repository
        .create_review_decision(
            &review.review.review_id,
            CreateReviewDecisionRequest {
                decision: ReviewDecision::Approved,
                expected_review_version: review.review.version,
                body: None,
            },
        )
        .await
        .unwrap();
    let merge = repository
        .create_review_merge(
            &approved.review.review_id,
            None,
            CreateReviewMergeRequest {
                expected_review_version: approved.review.version,
            },
        )
        .await
        .unwrap();
    let project_commit_id = merge.commit_id.unwrap();
    let org_context_id = repository
        .create_org_context(
            &bootstrap.org_id,
            "context/shared-from-hub.md",
            "# Shared from Hub\n\nSelected by the project.",
        )
        .await
        .unwrap();
    repository
        .replace_project_org_selection(
            &bootstrap.project_id,
            0,
            ReplaceProjectOrgSelectionRequest {
                rule_ids: Vec::new(),
                context_ids: vec![org_context_id.clone()],
                workflow_ids: Vec::new(),
            },
        )
        .await
        .unwrap();
    let commit_id = repository
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .unwrap();
    assert_ne!(commit_id, project_commit_id);

    let mut roots = Vec::new();
    for service in [&service_a, &service_b] {
        service
            .retry_sync(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::Commits,
            })
            .await
            .unwrap();
        let cache = service
            .memory_cache(DaemonMemoryCacheRequest {
                project_id: bootstrap.project_id.clone(),
            })
            .await
            .unwrap();
        assert!(cache.ready);
        assert_eq!(cache.commit_id.as_deref(), Some(commit_id.as_str()));
        let cache_root = std::path::PathBuf::from(cache.root_path.unwrap());
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(cache_root.join("manifest.json")).unwrap())
                .unwrap();
        assert_eq!(manifest["project_id"], bootstrap.project_id);
        assert_eq!(manifest["commit_id"], commit_id);
        assert_eq!(
            std::fs::read_to_string(cache_root.join("cache/context/context/commit-sync.md"))
                .unwrap(),
            "# Commit sync\n\nInstalled from an immutable Commit."
        );
        assert_eq!(
            std::fs::read_to_string(cache_root.join("cache/context/context/shared-from-hub.md"))
                .unwrap(),
            "# Shared from Hub\n\nSelected by the project."
        );
        let checkout = service
            .project_checkout(DaemonProjectCheckoutRequest {
                project_id: bootstrap.project_id.clone(),
            })
            .await
            .unwrap();
        assert!(checkout.ready);
        assert_eq!(checkout.commit_id.as_deref(), Some(commit_id.as_str()));
        assert_eq!(checkout.org_selection_revision, 1);
        assert_eq!(
            checkout.selected_org_resource_ids,
            vec![org_context_id.clone()]
        );
        assert!(checkout.resources.iter().any(|resource| {
            resource.scope == DaemonDraftScope::Project
                && resource.path == "context/commit-sync.md"
                && resource.content
                    == context_content("# Commit sync\n\nInstalled from an immutable Commit.")
        }));
        assert!(checkout.resources.iter().any(|resource| {
            resource.scope == DaemonDraftScope::Org && resource.path == "context/shared-from-hub.md"
        }));
        let sync = service.sync_status().await.unwrap();
        assert_eq!(sync.commit_sync.state, SyncState::Idle);
        assert_eq!(
            sync.commit_sync.server_cursor.as_deref(),
            Some(commit_id.as_str())
        );
        assert!(sync.commit_sync.last_error.is_none());
        roots.push(cache_root);
    }
    assert_ne!(roots[0], roots[1]);
    assert_eq!(
        roots[0].file_name().unwrap().to_str(),
        roots[1].file_name().unwrap().to_str()
    );

    drop(service_a);
    let restarted_a = DaemonIpcService::new(
        common::initialize_daemon(config_a, credential_store_a.clone()).await,
    );
    let cache_after_restart = restarted_a
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: bootstrap.project_id.clone(),
        })
        .await
        .unwrap();
    assert!(cache_after_restart.ready);
    assert_eq!(
        cache_after_restart.commit_id.as_deref(),
        Some(commit_id.as_str())
    );
    assert_eq!(
        cache_after_restart.root_path.as_deref(),
        Some(roots[0].to_str().unwrap())
    );

    let next_draft = restarted_a
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/next.md".to_owned(),
                    content: context_content("Uses the installed Ref as its base."),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Desktop),
        })
        .await
        .unwrap();
    let next_draft = restarted_a.get_draft(&next_draft.draft_id).await.unwrap();
    assert_eq!(
        next_draft.draft.base_commit_id.as_deref(),
        Some(commit_id.as_str())
    );

    let selected = restarted_a
        .select_project(DaemonProjectSelectionRequest {
            project_id: secondary_project_id.clone(),
        })
        .await
        .unwrap();
    assert_eq!(
        selected.project_id.as_deref(),
        Some(secondary_project_id.as_str())
    );
    restarted_a
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();
    let secondary_cache = restarted_a
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: secondary_project_id.clone(),
        })
        .await
        .unwrap();
    assert_eq!(
        secondary_cache.commit_id.as_deref(),
        Some(secondary_commit_id.as_str())
    );
    assert_eq!(
        std::fs::read_to_string(
            std::path::PathBuf::from(secondary_cache.root_path.unwrap())
                .join("cache/context/context/secondary.md")
        )
        .unwrap(),
        "# Secondary project"
    );

    server_task.abort();
}
