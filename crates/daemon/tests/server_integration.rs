use daemon::{
    DaemonConfig, DaemonCreateDraftOperation, DaemonDraftOperation, DaemonDraftOperationRequest,
    DaemonDraftOperationSource, DaemonDraftResourceKind, DaemonDraftScope, DaemonIpcService,
    DaemonState, DaemonSyncRetryRequest, SyncRetryChannel,
};
use server::repository::ServerRepository;
use sha2::{Digest, Sha256};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::postgres::Postgres;

#[tokio::test]
async fn local_draft_refreshes_auth_and_syncs_to_the_real_server() {
    let postgres = Postgres::default().start().await.unwrap();
    let port = postgres.get_host_port_ipv4(5432).await.unwrap();
    let database_url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = sqlx::PgPool::connect(&database_url).await.unwrap();
    server::db::run_migrations(&pool).await.unwrap();
    let repository = ServerRepository::new(pool.clone());
    let bootstrap = repository
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Daemon Integration",
        )
        .await
        .unwrap();

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
    config.project.access_token = Some(stale_access_token.to_owned());
    config.project.refresh_token = Some(refresh_token.to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let service = DaemonIpcService::new(state);

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: bootstrap.project_id.clone(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/from-daemon.md".to_owned(),
                    body: "# Synced\n\nCreated through the local daemon.".to_owned(),
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
        draft.operations[0].input.body.as_deref(),
        Some("# Synced\n\nCreated through the local daemon.")
    );

    server_task.abort();
}
