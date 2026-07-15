mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::routing::{get, post};
use axum::{Json, Router};
use daemon::{
    APP_BUNDLE_IDENTIFIER, CURRENT_LOCAL_SCHEMA_VERSION, DAEMON_AGENT_LABEL,
    DAEMON_MACH_SERVICE_NAME, DaemonConfig, DaemonCreateDraftOperation, DaemonDeleteDraftOperation,
    DaemonDiscardDraftOperation, DaemonDraftListQuery, DaemonDraftOperation,
    DaemonDraftOperationRecordSource, DaemonDraftOperationRequest, DaemonDraftOperationSource,
    DaemonDraftResourceKind, DaemonDraftScope, DaemonError, DaemonHealth, DaemonIpcRequest,
    DaemonIpcService, DaemonIpcTransport, DaemonLocalDraftStatus, DaemonMemoryCacheRequest,
    DaemonMemoryCacheStatus, DaemonProjectConfigUpdateRequest, DaemonState, DaemonSyncRetryRequest,
    DaemonUpdateDraftOperation, DraftOperationSyncStatus, LaunchAgentConfig, LaunchAgentController,
    LaunchAgentRuntimeStatus, SyncRetryChannel, SyncState,
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};

const COMMIT_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const COMMIT_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[tokio::test]
async fn health_initializes_local_database_and_stable_installation_id() {
    let (root, state, service) = common::test_daemon().await;
    let first_id = state.daemon_installation_id().to_owned();

    let health = service.health().await;

    assert!(health.local_db.ready);
    assert_eq!(health.local_db.schema_version, CURRENT_LOCAL_SCHEMA_VERSION);
    assert_eq!(health.daemon_installation_id, first_id);
    assert!(health.local_db.path.ends_with("local.db"));
    assert!(health.log_dir.ends_with("logs"));
    assert!(root.path().join("logs").is_dir());

    let restarted = DaemonState::initialize(DaemonConfig::for_root(root.path()))
        .await
        .unwrap();
    assert_eq!(restarted.daemon_installation_id(), first_id);
}

#[tokio::test]
async fn initialization_rejects_an_old_local_schema() {
    let root = tempfile::tempdir().unwrap();
    let database_path = root.path().join("local.db");
    std::fs::File::create(&database_path).unwrap();
    let pool = sqlx::SqlitePool::connect(&format!("sqlite://{}", database_path.display()))
        .await
        .unwrap();
    sqlx::query("CREATE TABLE daemon_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO daemon_meta (key, value) VALUES ('schema_version', '3')")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;

    let error = DaemonState::initialize(DaemonConfig::for_root(root.path()))
        .await
        .err()
        .unwrap();

    assert!(matches!(error, DaemonError::InvalidConfig(_)));
    assert!(error.to_string().contains("recreate the daemon database"));
}

#[test]
fn launch_agent_plist_uses_standard_identity_and_runtime_paths() {
    let root = tempfile::tempdir().unwrap();
    let config = DaemonConfig::for_root(root.path());
    let program_path = root.path().join("bin").join("clumsiesd");
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, &program_path);

    assert_eq!(launch_agent.label, DAEMON_AGENT_LABEL);
    assert_eq!(launch_agent.mach_service_name, DAEMON_MACH_SERVICE_NAME);
    assert_eq!(
        launch_agent.plist_path,
        root.path()
            .join("LaunchAgents")
            .join(format!("{DAEMON_AGENT_LABEL}.plist"))
    );

    let plist = launch_agent.plist_contents();
    assert!(plist.contains(&format!("<string>{DAEMON_AGENT_LABEL}</string>")));
    assert!(plist.contains(&format!("<key>{DAEMON_MACH_SERVICE_NAME}</key>")));
    assert!(plist.contains("<key>MachServices</key>"));
    assert!(plist.contains("<key>CLUMSIES_DAEMON_ROOT</key>"));
    assert!(plist.contains(&format!("<string>{}</string>", root.path().display())));
    assert!(!plist.contains("127.0.0.1"));
    assert!(!plist.contains("daemon-endpoint.json"));

    let bootstrap = launch_agent.bootstrap_status();
    assert_eq!(bootstrap.label, DAEMON_AGENT_LABEL);
    assert_eq!(bootstrap.mach_service_name, DAEMON_MACH_SERVICE_NAME);
    assert_eq!(
        bootstrap.endpoint.transport,
        DaemonIpcTransport::MacosXpcMachService
    );
    assert_eq!(bootstrap.endpoint.service_name, DAEMON_MACH_SERVICE_NAME);
    assert!(!bootstrap.installed);
}

#[test]
fn launch_agent_install_writes_owner_only_plist() {
    let root = tempfile::tempdir().unwrap();
    let config = DaemonConfig::for_root(root.path());
    let launch_agent =
        LaunchAgentConfig::from_daemon_config(&config, root.path().join("bin/clumsiesd"));

    launch_agent.install_plist().unwrap();

    let plist = std::fs::read_to_string(&launch_agent.plist_path).unwrap();
    assert!(plist.contains(APP_BUNDLE_IDENTIFIER));
    assert!(launch_agent.root_dir.is_dir());
    assert!(launch_agent.cache_dir.is_dir());
    assert!(launch_agent.log_dir.is_dir());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let mode = std::fs::metadata(&launch_agent.plist_path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }
}

#[test]
fn launch_agent_controller_uses_standard_launchctl_targets() {
    let root = tempfile::tempdir().unwrap();
    let config = DaemonConfig::for_root(root.path());
    let launch_agent =
        LaunchAgentConfig::from_daemon_config(&config, root.path().join("bin/clumsiesd"));
    let controller = LaunchAgentController::with_domain(launch_agent, "gui/501");

    assert_eq!(controller.domain(), "gui/501");
    assert_eq!(
        controller.service_target(),
        format!("gui/501/{DAEMON_AGENT_LABEL}")
    );
    assert_eq!(
        controller.bootstrap_args(),
        vec![
            "bootstrap".to_owned(),
            "gui/501".to_owned(),
            root.path()
                .join("LaunchAgents")
                .join(format!("{DAEMON_AGENT_LABEL}.plist"))
                .display()
                .to_string(),
        ]
    );
    assert_eq!(
        controller.bootout_args(),
        vec![
            "bootout".to_owned(),
            format!("gui/501/{DAEMON_AGENT_LABEL}"),
        ]
    );
    assert_eq!(
        controller.kickstart_args(),
        vec![
            "kickstart".to_owned(),
            "-k".to_owned(),
            format!("gui/501/{DAEMON_AGENT_LABEL}"),
        ]
    );
    assert_eq!(
        controller.print_args(),
        vec!["print".to_owned(), format!("gui/501/{DAEMON_AGENT_LABEL}")],
    );
}

#[test]
fn launchctl_print_parser_reports_runtime_status() {
    let status = LaunchAgentRuntimeStatus::from_launchctl_print(
        true,
        r#"
        state = running
        pid = 12345
        last exit code = 0
        "#,
    );

    assert!(status.installed);
    assert!(status.bootstrapped);
    assert!(status.running);
    assert_eq!(status.pid, Some(12345));
    assert_eq!(status.state.as_deref(), Some("running"));
    assert_eq!(status.last_exit_code, Some(0));
    assert_eq!(status.last_error, None);
}

#[tokio::test]
async fn draft_operation_is_written_to_local_queue_and_visible_in_sync_status() {
    let (_root, _state, service) = common::test_daemon().await;
    let body = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/architecture.md".to_owned(),
                    body: "Initial context".to_owned(),
                    description: Some("seed project context".to_owned()),
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

    assert!(body.local_operation_id.starts_with("op_"));
    assert!(body.draft_id.starts_with("draft_"));
    assert!(body.queued);
    assert_eq!(body.sync_status, DraftOperationSyncStatus::Queued);

    let status = service.sync_status().await.unwrap();
    assert_eq!(status.pending_operation_count, 1);
    assert_eq!(status.failed_operation_count, 0);
    assert_eq!(status.draft_sync.state, SyncState::Queued);
    assert_eq!(status.draft_sync.server_cursor, None);
    assert_eq!(status.draft_sync.last_attempt_at, None);
    assert_eq!(status.draft_sync.last_success_at, None);
    assert_eq!(status.last_success_at, None);
}

#[tokio::test]
async fn draft_operation_service_method_writes_local_queue_without_http() {
    let (_root, _state, service) = common::test_daemon().await;

    let response = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/ipc.md".to_owned(),
                    body: "Created through daemon service".to_owned(),
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

    assert!(response.local_operation_id.starts_with("op_"));
    assert!(response.draft_id.starts_with("draft_"));

    let status = service.sync_status().await.unwrap();
    assert_eq!(status.pending_operation_count, 1);
    assert_eq!(status.draft_sync.state, SyncState::Queued);

    let drafts = service
        .list_drafts(Default::default())
        .await
        .expect("service should list local drafts");
    assert_eq!(drafts.items.len(), 1);
    assert_eq!(drafts.items[0].draft_id, response.draft_id);

    let draft = service
        .get_draft(&response.draft_id)
        .await
        .expect("service should read local draft details");
    assert_eq!(draft.operations.len(), 1);
    assert_eq!(
        draft.operations[0].source,
        DaemonDraftOperationRecordSource::Desktop
    );
}

#[tokio::test]
async fn ipc_dispatch_routes_the_complete_daemon_api() {
    let (_root, _state, service) = common::test_daemon().await;

    let health: DaemonHealth = service
        .dispatch(DaemonIpcRequest::empty("health"))
        .await
        .into_payload()
        .unwrap();
    assert!(health.local_db.ready);

    let project_config = service
        .dispatch(DaemonIpcRequest::empty("project_config"))
        .await;
    assert!(project_config.ok);

    let sync_status = service
        .dispatch(DaemonIpcRequest::empty("sync_status"))
        .await;
    assert!(sync_status.ok);

    let memory_cache: DaemonMemoryCacheStatus = service
        .dispatch(DaemonIpcRequest::new(
            "memory_cache",
            serde_json::to_value(DaemonMemoryCacheRequest {
                project_id: "prj_test".to_owned(),
            })
            .unwrap(),
        ))
        .await
        .into_payload()
        .unwrap();
    assert!(!memory_cache.ready);

    let retry = service
        .dispatch(DaemonIpcRequest::new(
            "retry_sync",
            serde_json::to_value(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::All,
            })
            .unwrap(),
        ))
        .await;
    assert!(retry.ok);

    let mcp_status = service
        .dispatch(DaemonIpcRequest::empty("mcp_status"))
        .await;
    assert!(mcp_status.ok);

    let response = service
        .dispatch(DaemonIpcRequest::new(
            "store_draft_operation",
            serde_json::to_value(DaemonDraftOperationRequest {
                draft_id: None,
                base_commit_id: None,
                project_id: "prj_test".to_owned(),
                scope: DaemonDraftScope::Project,
                resource: DaemonDraftResourceKind::Context,
                op: DaemonDraftOperation {
                    create: Some(DaemonCreateDraftOperation {
                        path: "docs/ipc-dispatch.md".to_owned(),
                        body: "Created through IPC dispatch".to_owned(),
                        description: None,
                    }),
                    update: None,
                    rename: None,
                    delete: None,
                    discard: None,
                },
                source: Some(DaemonDraftOperationSource::Desktop),
            })
            .unwrap(),
        ))
        .await;
    assert!(response.ok);

    let list = service
        .dispatch(DaemonIpcRequest::new(
            "list_drafts",
            serde_json::to_value(DaemonDraftListQuery::default()).unwrap(),
        ))
        .await;
    assert!(list.ok);
    let list: daemon::DaemonDraftListResponse = list.into_payload().unwrap();
    assert_eq!(list.items.len(), 1);

    let detail = service
        .dispatch(DaemonIpcRequest::new(
            "get_draft",
            json!({ "draft_id": list.items[0].draft_id }),
        ))
        .await;
    assert!(detail.ok);

    let replaced = service
        .dispatch(DaemonIpcRequest::new(
            "replace_project_config",
            serde_json::to_value(DaemonProjectConfigUpdateRequest {
                server_url: "http://127.0.0.1:8080".to_owned(),
                project_id: Some("prj_test".to_owned()),
                access_token: Some("secret".to_owned()),
                refresh_token: Some("refresh-secret".to_owned()),
            })
            .unwrap(),
        ))
        .await;
    assert!(replaced.ok);

    let status = service.sync_status().await.unwrap();
    assert_eq!(status.pending_operation_count, 1);
}

#[tokio::test]
async fn mcp_store_envelope_matches_the_daemon_contract() {
    let (_root, _state, service) = common::test_daemon().await;
    let request: DaemonIpcRequest = serde_json::from_str(
        r#"{
            "method": "store_draft_operation",
            "payload": {
                "project_id": "prj_mcp",
                "scope": "project",
                "resource": "context",
                "op": {
                    "create": {
                        "path": "notes/from-mcp.md",
                        "body": "Stored through the Zig MCP envelope"
                    }
                },
                "source": "mcp_store"
            }
        }"#,
    )
    .unwrap();

    let response = service.dispatch(request).await;
    assert!(
        response.ok,
        "daemon rejected MCP envelope: {:?}",
        response.error
    );

    let drafts = service
        .list_drafts(DaemonDraftListQuery::default())
        .await
        .unwrap();
    assert_eq!(drafts.items.len(), 1);
    assert_eq!(drafts.items[0].project_id, "prj_mcp");
    assert_eq!(drafts.items[0].scope, DaemonDraftScope::Project);

    let detail = service.get_draft(&drafts.items[0].draft_id).await.unwrap();
    assert_eq!(detail.operations.len(), 1);
    assert_eq!(
        detail.operations[0].source,
        DaemonDraftOperationRecordSource::McpStore
    );
}

#[tokio::test]
async fn local_drafts_can_be_listed_and_read_with_operation_history() {
    let (_root, _state, service) = common::test_daemon().await;

    let created = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/local.md".to_owned(),
                    body: "Local draft".to_owned(),
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

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(created.draft_id.clone()),
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: None,
                update: Some(DaemonUpdateDraftOperation {
                    id: created.draft_id.clone(),
                    body: "Local draft v2".to_owned(),
                    description: None,
                }),
                rename: None,
                delete: None,
                discard: None,
            },
            source: Some(DaemonDraftOperationSource::Cli),
        })
        .await
        .unwrap();

    let list = service
        .list_drafts(DaemonDraftListQuery {
            resource: Some("context".to_owned()),
            status: Some("open".to_owned()),
            limit: None,
        })
        .await
        .unwrap();
    assert_eq!(list.items.len(), 1);
    let item = &list.items[0];
    assert_eq!(item.draft_id, created.draft_id);
    assert_eq!(item.server_draft_id, None);
    assert_eq!(item.server_version, 0);
    assert_eq!(item.resource_kind, DaemonDraftResourceKind::Context);
    assert_eq!(item.path.as_deref(), Some("docs/local.md"));
    assert_eq!(item.status, DaemonLocalDraftStatus::Open);
    assert_eq!(item.pending_operation_count, 2);
    assert_eq!(item.failed_operation_count, 0);

    let detail = service.get_draft(&created.draft_id).await.unwrap();
    assert_eq!(detail.draft.draft_id, created.draft_id);
    assert_eq!(detail.operations.len(), 2);
    assert_eq!(
        detail.operations[0].source,
        DaemonDraftOperationRecordSource::McpStore
    );
    assert_eq!(
        detail.operations[0].sync_status,
        DraftOperationSyncStatus::Queued
    );
    assert_eq!(
        detail.operations[0].operation.create.as_ref().unwrap().body,
        "Local draft"
    );
    assert_eq!(
        detail.operations[1].source,
        DaemonDraftOperationRecordSource::Cli
    );
    assert_eq!(
        detail.operations[1].operation.update.as_ref().unwrap().body,
        "Local draft v2"
    );

    assert!(matches!(
        service.get_draft("missing").await,
        Err(DaemonError::NotFound(_))
    ));
}

#[tokio::test]
async fn project_config_can_be_replaced_and_persists_across_restarts() {
    let (root, _state, service) = common::test_daemon().await;

    let initial = service.project_config();
    assert_eq!(initial.server_url, "");
    assert_eq!(initial.project_id, None);
    assert!(!initial.has_access_token);
    assert!(!initial.ready);
    assert_eq!(
        initial.missing_fields,
        vec!["server_url", "project_id", "access_token"]
    );

    let updated = service
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: "http://127.0.0.1:18080".to_owned(),
            project_id: Some("prj_config".to_owned()),
            access_token: Some("secret-token".to_owned()),
            refresh_token: Some("refresh-token".to_owned()),
        })
        .await
        .unwrap();
    assert_eq!(updated.server_url, "http://127.0.0.1:18080");
    assert_eq!(updated.project_id.as_deref(), Some("prj_config"));
    assert!(updated.has_access_token);
    assert!(updated.has_refresh_token);
    assert!(updated.ready);
    assert!(updated.missing_fields.is_empty());

    let health = service.health().await;
    assert_eq!(health.server_url, "http://127.0.0.1:18080");
    assert_eq!(health.project_id.as_deref(), Some("prj_config"));

    let restarted = DaemonState::initialize(DaemonConfig::for_root(root.path()))
        .await
        .unwrap();
    let restarted_service = DaemonIpcService::new(restarted);
    let persisted = restarted_service.project_config();
    assert_eq!(persisted.server_url, "http://127.0.0.1:18080");
    assert_eq!(persisted.project_id.as_deref(), Some("prj_config"));
    assert!(persisted.has_access_token);
    assert!(persisted.has_refresh_token);
    assert!(persisted.ready);
}

#[tokio::test]
async fn sync_retry_uploads_new_local_draft_to_server() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server.url.clone();
    config.project.project_id = Some("prj_default".to_owned());
    config.project.access_token = Some("test-token".to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let service = DaemonIpcService::new(state.clone());

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: Some(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
            ),
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/sync.md".to_owned(),
                    body: "Sync me".to_owned(),
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

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    let status = service.sync_status().await.unwrap();
    assert_eq!(status.pending_operation_count, 0);
    assert_eq!(status.failed_operation_count, 0);
    assert_eq!(status.draft_sync.state, SyncState::Idle);
    assert_eq!(status.draft_sync.server_cursor.as_deref(), Some("42"));
    assert!(status.draft_sync.last_attempt_at.is_some());
    assert!(status.draft_sync.last_success_at.is_some());
    assert_eq!(status.last_success_at, status.draft_sync.last_success_at);

    let drafts = service
        .list_drafts(DaemonDraftListQuery::default())
        .await
        .unwrap();
    assert_eq!(drafts.items.len(), 1);
    assert_eq!(drafts.items[0].server_version, 2);
    let projected = service.get_draft(&drafts.items[0].draft_id).await.unwrap();
    assert_eq!(projected.operations.len(), 2);
    assert_eq!(
        projected.operations[0].source,
        DaemonDraftOperationRecordSource::Desktop
    );
    assert_eq!(
        projected.operations[1].source,
        DaemonDraftOperationRecordSource::Server
    );
    assert_eq!(
        projected.operations[1]
            .operation
            .create
            .as_ref()
            .unwrap()
            .body,
        "Remote revision"
    );

    let pool = sqlx::SqlitePool::connect(&state.local_db_path().display().to_string())
        .await
        .unwrap();
    let remote_event_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM remote_draft_events")
        .fetch_one(&pool)
        .await
        .unwrap();
    let cursor: String =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'draft_events_cursor'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(remote_event_count, 1);
    assert_eq!(cursor, "42");

    let requests = server.create_requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].get("author_user_id").is_none());
    assert_eq!(requests[0]["project_id"], "prj_test");
    assert_eq!(requests[0]["resource"]["scope"], "project");
    assert_eq!(
        requests[0]["base_commit_id"],
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    );
    assert!(
        requests[0]["daemon_installation_id"]
            .as_str()
            .unwrap()
            .starts_with("daemon_")
    );
    assert_eq!(requests[0]["resource"]["kind"], "context");
    assert_eq!(requests[0]["resource"]["path"], "docs/sync.md");
    assert_eq!(requests[0]["operations"][0]["action"], "create");
    assert_eq!(requests[0]["operations"][0]["body"], "Sync me");
}

#[tokio::test]
async fn failed_remote_projection_does_not_advance_the_event_cursor() {
    let app = Router::new()
        .route("/api/v1/draft-events", get(fake_list_draft_events))
        .route("/api/v1/drafts/{draft_id}", get(fake_stale_draft));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_test".to_owned());
    config.project.access_token = Some("test-token".to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let service = DaemonIpcService::new(state.clone());

    let error = service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap_err();

    assert!(error.to_string().contains("inconsistent projection"));
    assert_eq!(
        service
            .sync_status()
            .await
            .unwrap()
            .draft_sync
            .server_cursor,
        None
    );
    assert!(
        service
            .list_drafts(DaemonDraftListQuery::default())
            .await
            .unwrap()
            .items
            .is_empty()
    );
    let pool = sqlx::SqlitePool::connect(&state.local_db_path().display().to_string())
        .await
        .unwrap();
    let event_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM remote_draft_events")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(event_count, 0);
}

#[tokio::test]
async fn server_conflict_event_converges_into_local_draft_state() {
    let conflict_state = FakeConflictProjectionState {
        resolved: Arc::new(AtomicUsize::new(0)),
    };
    let app = Router::new()
        .route("/api/v1/draft-events", get(fake_conflicted_draft_events))
        .route("/api/v1/drafts/{draft_id}", get(fake_conflicted_draft))
        .with_state(conflict_state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_conflict".to_owned());
    config.project.access_token = Some("test-token".to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let service = DaemonIpcService::new(state);

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    let drafts = service
        .list_drafts(DaemonDraftListQuery::default())
        .await
        .unwrap();
    assert_eq!(drafts.items.len(), 1);
    let draft = &drafts.items[0];
    assert_eq!(draft.status, DaemonLocalDraftStatus::Conflicted);
    let conflict = draft.conflict.as_ref().unwrap();
    assert_eq!(conflict.base_commit_id.as_deref(), Some(COMMIT_A));
    assert_eq!(conflict.current_commit_id.as_deref(), Some(COMMIT_B));

    let sync = service.sync_status().await.unwrap();
    assert_eq!(sync.conflict_count, 1);
    assert_eq!(sync.draft_sync.state, SyncState::Conflicted);
    assert_eq!(sync.failed_operation_count, 0);

    conflict_state.resolved.store(1, Ordering::SeqCst);
    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    let resolved = service.get_draft("drf_conflict").await.unwrap();
    assert_eq!(resolved.draft.status, DaemonLocalDraftStatus::Submitted);
    assert_eq!(resolved.draft.base_commit_id.as_deref(), Some(COMMIT_B));
    assert_eq!(resolved.draft.conflict, None);
    assert_eq!(resolved.operations.len(), 1);
    assert_eq!(
        resolved.operations[0]
            .operation
            .update
            .as_ref()
            .unwrap()
            .body,
        "Resolved content"
    );
    let sync = service.sync_status().await.unwrap();
    assert_eq!(sync.conflict_count, 0);
    assert_eq!(sync.draft_sync.state, SyncState::Idle);
}

#[tokio::test]
async fn queued_draft_syncs_after_project_config_is_set() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let state = DaemonState::initialize(config).await.unwrap();
    let worker = state.start_sync_worker().unwrap();
    let service = DaemonIpcService::new(state);

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_late".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/later-config.md".to_owned(),
                    body: "sync after config".to_owned(),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: None,
        })
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(50)).await;
    let before = service.sync_status().await.unwrap();
    assert_eq!(before.pending_operation_count, 1);
    assert_eq!(before.failed_operation_count, 0);
    assert_eq!(before.draft_sync.state, SyncState::Degraded);
    assert_eq!(before.draft_sync.server_cursor, None);
    assert_eq!(before.draft_sync.last_attempt_at, None);
    assert_eq!(before.draft_sync.last_success_at, None);
    assert_eq!(
        before.draft_sync.last_error.unwrap().code,
        "daemon_project_config_incomplete"
    );
    assert!(server.create_requests.lock().unwrap().is_empty());

    service
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: server.url.clone(),
            project_id: Some("prj_late".to_owned()),
            access_token: Some("test-token".to_owned()),
            refresh_token: None,
        })
        .await
        .unwrap();

    wait_for_create_request(&server).await;
    let after = service.sync_status().await.unwrap();
    assert_eq!(after.pending_operation_count, 0);
    assert_eq!(after.failed_operation_count, 0);
    assert_eq!(after.draft_sync.state, SyncState::Idle);

    let requests = server.create_requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].get("author_user_id").is_none());
    assert_eq!(requests[0]["project_id"], "prj_late");
    assert_eq!(requests[0]["operations"][0]["body"], "sync after config");
    drop(requests);
    worker.abort();
}

#[tokio::test]
async fn draft_operation_notifies_auto_sync_worker() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server.url.clone();
    config.project.project_id = Some("prj_test".to_owned());
    config.project.access_token = Some("test-token".to_owned());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let state = DaemonState::initialize(config).await.unwrap();
    let worker = state.start_sync_worker().unwrap();
    let service = DaemonIpcService::new(state);

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/auto.md".to_owned(),
                    body: "automatic".to_owned(),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: None,
        })
        .await
        .unwrap();

    wait_for_create_request(&server).await;
    let status = wait_for_draft_sync_idle(&service).await;
    assert_eq!(status.pending_operation_count, 0);
    assert_eq!(status.failed_operation_count, 0);

    let requests = server.create_requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["operations"][0]["body"], "automatic");
    drop(requests);
    worker.abort();
}

#[tokio::test]
async fn sync_retry_uploads_later_new_resource_edits_to_the_same_draft() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server.url.clone();
    config.project.project_id = Some("prj_test".to_owned());
    config.project.access_token = Some("test-token".to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let service = DaemonIpcService::new(state);

    let first = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/batch.md".to_owned(),
                    body: "one".to_owned(),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: None,
        })
        .await
        .unwrap();

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    assert_eq!(
        service
            .sync_status()
            .await
            .unwrap()
            .draft_sync
            .server_cursor
            .as_deref(),
        Some("42")
    );

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(first.draft_id.clone()),
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "docs/batch.md".to_owned(),
                    body: "two".to_owned(),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: None,
                discard: None,
            },
            source: None,
        })
        .await
        .unwrap();

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();
    assert_eq!(
        service
            .sync_status()
            .await
            .unwrap()
            .draft_sync
            .server_cursor
            .as_deref(),
        Some("42")
    );

    service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: Some(first.draft_id),
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: None,
                update: None,
                rename: None,
                delete: None,
                discard: Some(DaemonDiscardDraftOperation {
                    id: "draft_local".to_owned(),
                }),
            },
            source: None,
        })
        .await
        .unwrap();

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Drafts,
        })
        .await
        .unwrap();

    let status = service.sync_status().await.unwrap();
    assert_eq!(status.pending_operation_count, 0);
    assert_eq!(status.failed_operation_count, 0);

    let creates = server.create_requests.lock().unwrap();
    assert_eq!(creates.len(), 1);
    drop(creates);

    let batches = server.batch_requests.lock().unwrap();
    assert_eq!(batches.len(), 1);
    assert!(
        batches[0]["daemon_installation_id"]
            .as_str()
            .unwrap()
            .starts_with("daemon_")
    );
    assert_eq!(batches[0]["operations"][0]["draft_id"], "drf_remote");
    assert_eq!(batches[0]["operations"][0]["expected_draft_version"], 2);
    assert_eq!(batches[0]["operations"][0]["operation"]["action"], "create");
    assert_eq!(
        batches[0]["operations"][0]["operation"]["resource"]["path"],
        "docs/batch.md"
    );
    assert_eq!(batches[0]["operations"][0]["operation"]["body"], "two");
    drop(batches);

    let deletes = server.delete_requests.lock().unwrap();
    assert_eq!(
        deletes.as_slice(),
        &[("drf_remote".to_owned(), "3".to_owned())]
    );
}

#[tokio::test]
async fn draft_operation_rejects_multiple_operation_variants() {
    let (_root, _state, service) = common::test_daemon().await;

    let response = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_test".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Rule,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "rules/a.md".to_owned(),
                    body: "Rule".to_owned(),
                    description: None,
                }),
                update: None,
                rename: None,
                delete: Some(DaemonDeleteDraftOperation {
                    id: "rule_1".to_owned(),
                    description: None,
                }),
                discard: None,
            },
            source: None,
        })
        .await;

    assert!(matches!(response, Err(DaemonError::InvalidRequest(_))));
}

#[tokio::test]
async fn mcp_status_reports_no_daemon_owned_supervisor() {
    let (_, _, service) = common::test_daemon().await;

    let status = service.mcp_status();

    assert!(!status.running);
    assert_eq!(status.endpoint, None);
    assert!(status.adapters.is_empty());
}

#[tokio::test]
async fn invalid_commit_payload_does_not_advance_the_installed_ref() {
    let server = AtomicCommitServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server.url.clone();
    config.project.project_id = Some("prj_atomic".to_owned());
    config.project.access_token = Some("fake-access-token".to_owned());
    let service = DaemonIpcService::new(DaemonState::initialize(config).await.unwrap());

    service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();
    let installed = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: "prj_atomic".to_owned(),
        })
        .await
        .unwrap();
    assert!(installed.ready);
    assert_eq!(installed.commit_id.as_deref(), Some("commit-valid"));
    let installed_root = installed.root_path.unwrap();
    assert_eq!(
        std::fs::read_to_string(
            std::path::Path::new(&installed_root).join("cache/context/context/valid.md")
        )
        .unwrap(),
        "Valid authority"
    );

    server.publish_invalid_commit();
    let error = service
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap_err();
    assert!(error.to_string().contains("content-address verification"));

    let after_failure = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: "prj_atomic".to_owned(),
        })
        .await
        .unwrap();
    assert!(after_failure.ready);
    assert_eq!(after_failure.commit_id.as_deref(), Some("commit-valid"));
    assert_eq!(
        after_failure.root_path.as_deref(),
        Some(installed_root.as_str())
    );
    assert_eq!(
        std::fs::read_to_string(
            std::path::Path::new(&installed_root).join("cache/context/context/valid.md")
        )
        .unwrap(),
        "Valid authority"
    );
    assert!(
        !root
            .path()
            .join("cache/projects/prj_atomic/generations/commit-invalid")
            .exists()
    );

    let sync = service.sync_status().await.unwrap();
    assert_eq!(sync.commit_sync.state, SyncState::Failed);
    assert_eq!(
        sync.commit_sync.server_cursor.as_deref(),
        Some("commit-valid")
    );
    assert!(sync.commit_sync.last_error.is_some());

    std::fs::remove_file(std::path::Path::new(&installed_root).join("manifest.json")).unwrap();
    let corrupted = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: "prj_atomic".to_owned(),
        })
        .await
        .unwrap();
    assert!(!corrupted.ready);
    assert_eq!(corrupted.commit_id.as_deref(), Some("commit-valid"));
    assert_eq!(corrupted.root_path, None);
}

async fn wait_for_create_request(server: &FakeServer) {
    for _ in 0..50 {
        if !server.create_requests.lock().unwrap().is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for fake Server create request");
}

async fn wait_for_draft_sync_idle(service: &DaemonIpcService) -> daemon::DaemonSyncStatus {
    for _ in 0..50 {
        let status = service.sync_status().await.unwrap();
        if status.pending_operation_count == 0 {
            return status;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for daemon draft sync");
}

struct FakeServer {
    url: String,
    create_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    batch_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    delete_requests: Arc<Mutex<Vec<(String, String)>>>,
}

struct AtomicCommitServer {
    url: String,
    revision: Arc<AtomicUsize>,
}

impl AtomicCommitServer {
    async fn start() -> Self {
        let revision = Arc::new(AtomicUsize::new(0));
        let app = Router::new()
            .route("/api/v1/org/commit-state", get(atomic_org_commit_state))
            .route(
                "/api/v1/projects/{project_id}/commit-state",
                get(atomic_project_commit_state),
            )
            .route("/api/v1/commits/{commit_id}", get(atomic_commit_payload))
            .with_state(revision.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self {
            url: format!("http://{addr}"),
            revision,
        }
    }

    fn publish_invalid_commit(&self) {
        self.revision.store(1, Ordering::Release);
    }
}

#[derive(Deserialize)]
struct AtomicCommitStateQuery {
    local_commit_id: Option<String>,
}

async fn atomic_org_commit_state() -> impl axum::response::IntoResponse {
    (
        [(axum::http::header::ETAG, "\"ref-none\"")],
        Json(json!({
            "update_available": false,
            "ref": {
                "name": "refs/heads/main",
                "scope": "org",
                "org_id": "org_atomic",
                "project_id": null,
                "commit_id": null,
                "updated_at": "2026-07-15T00:00:00Z"
            },
            "latest": null,
            "download_url": null,
            "incremental_supported": false
        })),
    )
}

async fn atomic_project_commit_state(
    axum::extract::State(revision): axum::extract::State<Arc<AtomicUsize>>,
    axum::extract::Path(project_id): axum::extract::Path<String>,
    axum::extract::Query(query): axum::extract::Query<AtomicCommitStateQuery>,
) -> impl axum::response::IntoResponse {
    let invalid = revision.load(Ordering::Acquire) == 1;
    let commit_id = if invalid {
        "commit-invalid"
    } else {
        "commit-valid"
    };
    let tree_id = if invalid {
        "tree-invalid"
    } else {
        "tree-valid"
    };
    let parent_commit_id = invalid.then_some("commit-valid");
    let version = if invalid { 2 } else { 1 };
    let mut headers = axum::http::HeaderMap::new();
    headers.insert(
        axum::http::header::ETAG,
        axum::http::HeaderValue::from_str(&format!("\"{commit_id}\"")).unwrap(),
    );
    (
        headers,
        Json(json!({
            "update_available": query.local_commit_id.as_deref() != Some(commit_id),
            "ref": {
                "name": "refs/heads/main",
                "scope": "project",
                "org_id": "org_atomic",
                "project_id": project_id,
                "commit_id": commit_id,
                "updated_at": "2026-07-15T00:00:00Z"
            },
            "latest": {
                "commit_id": commit_id,
                "scope": "project",
                "org_id": "org_atomic",
                "project_id": "prj_atomic",
                "tree_id": tree_id,
                "parent_commit_id": parent_commit_id,
                "version": version,
                "created_at": "2026-07-15T00:00:00Z"
            },
            "download_url": format!("/api/v1/commits/{commit_id}"),
            "incremental_supported": false
        })),
    )
}

async fn atomic_commit_payload(
    axum::extract::Path(commit_id): axum::extract::Path<String>,
) -> Json<serde_json::Value> {
    let invalid = commit_id == "commit-invalid";
    let tree_id = if invalid {
        "tree-invalid"
    } else {
        "tree-valid"
    };
    let path = if invalid {
        "context/invalid.md"
    } else {
        "context/valid.md"
    };
    let content = if invalid {
        "Invalid authority"
    } else {
        "Valid authority"
    };
    let content_blob_id = if invalid {
        "not-the-content-address".to_owned()
    } else {
        test_blob_id(content)
    };
    let selection = json!({
        "project_id": "prj_atomic",
        "rules": [],
        "context": [],
        "workflows": [],
        "revision": 0
    });
    let selection_content = serde_json::to_string(&selection).unwrap();
    let selection_blob_id = test_blob_id(&selection_content);
    Json(json!({
        "commit": {
            "commit_id": commit_id,
            "scope": "project",
            "org_id": "org_atomic",
            "project_id": "prj_atomic",
            "tree_id": tree_id,
            "parent_commit_id": invalid.then_some("commit-valid"),
            "version": if invalid { 2 } else { 1 },
            "created_at": "2026-07-15T00:00:00Z"
        },
        "tree": {
            "tree_id": tree_id,
            "entries": [
                {
                    "id": if invalid { "ctx_invalid" } else { "ctx_valid" },
                    "type": "context",
                    "scope": "project",
                    "project_id": "prj_atomic",
                    "path": path,
                    "blob_id": content_blob_id,
                    "source": "project"
                },
                {
                    "id": "project_org_selection",
                    "type": "project_org_selection",
                    "scope": "daemon",
                    "project_id": "prj_atomic",
                    "path": null,
                    "blob_id": selection_blob_id,
                    "source": "config"
                }
            ]
        },
        "blobs": [
            { "blob_id": content_blob_id, "content": content },
            { "blob_id": selection_blob_id, "content": selection_content }
        ],
        "project_org_selection": selection
    }))
}

fn test_blob_id(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"blob\0");
    hasher.update(content.as_bytes());
    hex::encode(hasher.finalize())
}

impl FakeServer {
    async fn start() -> Self {
        let create_requests = Arc::new(Mutex::new(Vec::new()));
        let batch_requests = Arc::new(Mutex::new(Vec::new()));
        let delete_requests = Arc::new(Mutex::new(Vec::new()));
        let state = FakeServerState {
            create_requests: create_requests.clone(),
            batch_requests: batch_requests.clone(),
            delete_requests: delete_requests.clone(),
        };
        let app = Router::new()
            .route("/api/v1/drafts", post(fake_create_draft))
            .route("/api/v1/draft-events", get(fake_list_draft_events))
            .route("/api/v1/org/commit-state", get(fake_org_commit_state))
            .route(
                "/api/v1/projects/{project_id}/commit-state",
                get(fake_project_commit_state),
            )
            .route(
                "/api/v1/drafts/{draft_id}",
                get(fake_get_draft).delete(fake_delete_draft),
            )
            .route(
                "/api/v1/draft-operation-batches",
                post(fake_create_draft_operation_batch),
            )
            .with_state(state);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self {
            url: format!("http://{addr}"),
            create_requests,
            batch_requests,
            delete_requests,
        }
    }
}

async fn fake_org_commit_state() -> impl axum::response::IntoResponse {
    (
        [(axum::http::header::ETAG, "\"ref-none\"")],
        Json(json!({
            "update_available": false,
            "ref": {
                "name": "refs/heads/main",
                "scope": "org",
                "org_id": "org_test",
                "project_id": null,
                "commit_id": null,
                "updated_at": "2026-07-08T00:00:00Z"
            },
            "latest": null,
            "download_url": null,
            "incremental_supported": false
        })),
    )
}

async fn fake_project_commit_state(
    axum::extract::Path(project_id): axum::extract::Path<String>,
) -> impl axum::response::IntoResponse {
    (
        [(axum::http::header::ETAG, "\"ref-none\"")],
        Json(json!({
            "update_available": false,
            "ref": {
                "name": "refs/heads/main",
                "scope": "project",
                "org_id": "org_test",
                "project_id": project_id,
                "commit_id": null,
                "updated_at": "2026-07-08T00:00:00Z"
            },
            "latest": null,
            "download_url": null,
            "incremental_supported": false
        })),
    )
}

#[derive(Clone)]
struct FakeServerState {
    create_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    batch_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    delete_requests: Arc<Mutex<Vec<(String, String)>>>,
}

async fn fake_create_draft(
    axum::extract::State(state): axum::extract::State<FakeServerState>,
    Json(body): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    state.create_requests.lock().unwrap().push(body);
    Json(json!({
        "draft": {
            "draft_id": "drf_remote",
            "version": 1
        }
    }))
}

async fn fake_create_draft_operation_batch(
    axum::extract::State(state): axum::extract::State<FakeServerState>,
    Json(body): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    let accepted_operations = body["operations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|operation| operation["local_operation_id"].clone())
        .collect::<Vec<_>>();
    state.batch_requests.lock().unwrap().push(body);
    Json(json!({
        "accepted_operations": accepted_operations,
        "cursor": "2"
    }))
}

async fn fake_get_draft(
    axum::extract::State(state): axum::extract::State<FakeServerState>,
    axum::extract::Path(draft_id): axum::extract::Path<String>,
) -> Json<serde_json::Value> {
    let create_request = state
        .create_requests
        .lock()
        .unwrap()
        .first()
        .cloned()
        .unwrap_or_else(|| {
            json!({
                "project_id": "prj_test",
                "base_commit_id": null,
                "resource": {
                    "scope": "project",
                    "kind": "context",
                    "id": null,
                    "path": "docs/remote.md"
                },
                "operations": [{
                    "action": "create",
                    "resource": {
                        "scope": "project",
                        "kind": "context",
                        "id": null,
                        "path": "docs/remote.md"
                    },
                    "base_hash": null,
                    "body": "Remote base",
                    "new_path": null
                }]
            })
        });
    let resource = create_request["resource"].clone();
    let initial_operation = create_request["operations"][0].clone();
    Json(json!({
        "draft": {
            "draft_id": draft_id,
            "project_id": create_request["project_id"],
            "base_commit_id": create_request["base_commit_id"],
            "resource": resource,
            "status": "open",
            "version": 2,
            "created_at": "2026-07-08T00:00:00Z",
            "updated_at": "2026-07-08T00:01:00Z"
        },
        "operations": [
            {
                "operation_id": "dop_initial",
                "action": initial_operation["action"],
                "resource": initial_operation["resource"],
                "base_hash": initial_operation["base_hash"],
                "body": initial_operation["body"],
                "new_path": initial_operation["new_path"],
                "created_at": "2026-07-08T00:00:00Z"
            },
            {
                "operation_id": "dop_remote",
                "action": "create",
                "resource": create_request["resource"],
                "base_hash": null,
                "body": "Remote revision",
                "new_path": null,
                "created_at": "2026-07-08T00:01:00Z"
            }
        ],
        "sync_state": {
            "status": "synced",
            "server_cursor": "draft:drf_remote:2",
            "daemon_installation_id": "daemon_other",
            "conflict_count": 0
        },
        "conflict": null
    }))
}

async fn fake_stale_draft(
    axum::extract::Path(draft_id): axum::extract::Path<String>,
) -> Json<serde_json::Value> {
    Json(json!({
        "draft": {
            "draft_id": draft_id,
            "project_id": "prj_test",
            "base_commit_id": null,
            "resource": {
                "scope": "project",
                "kind": "context",
                "id": null,
                "path": "docs/remote.md"
            },
            "status": "open",
            "version": 1,
            "created_at": "2026-07-08T00:00:00Z",
            "updated_at": "2026-07-08T00:00:00Z"
        },
        "operations": [],
        "conflict": null
    }))
}

async fn fake_delete_draft(
    axum::extract::State(state): axum::extract::State<FakeServerState>,
    axum::extract::Path(draft_id): axum::extract::Path<String>,
    headers: axum::http::HeaderMap,
) -> Json<serde_json::Value> {
    let version = headers
        .get("if-match")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    state
        .delete_requests
        .lock()
        .unwrap()
        .push((draft_id.clone(), version));
    Json(json!({ "deleted": true, "id": draft_id }))
}

#[derive(Deserialize)]
struct FakeDraftEventQuery {
    after_cursor: Option<String>,
}

#[derive(Clone)]
struct FakeConflictProjectionState {
    resolved: Arc<AtomicUsize>,
}

async fn fake_list_draft_events(
    axum::extract::Query(query): axum::extract::Query<FakeDraftEventQuery>,
) -> Json<serde_json::Value> {
    if query.after_cursor.is_some() {
        return Json(json!({
            "events": [],
            "next_cursor": null,
            "has_more": false
        }));
    }
    Json(json!({
        "events": [
            {
                "event_id": "evt_remote",
                "draft_id": "drf_remote",
                "project_id": "prj_test",
                "event_type": "updated",
                "version": 2,
                "daemon_installation_id": "daemon_other",
                "created_at": "2026-07-08T00:00:00Z"
            }
        ],
        "next_cursor": "42",
        "has_more": false
    }))
}

async fn fake_conflicted_draft_events(
    axum::extract::State(state): axum::extract::State<FakeConflictProjectionState>,
    axum::extract::Query(query): axum::extract::Query<FakeDraftEventQuery>,
) -> Json<serde_json::Value> {
    if query.after_cursor.as_deref() == Some("conflict:3")
        && state.resolved.load(Ordering::SeqCst) > 0
    {
        return Json(json!({
            "events": [
                {
                    "event_id": "evt_resolved",
                    "draft_id": "drf_conflict",
                    "project_id": "prj_conflict",
                    "event_type": "updated",
                    "version": 4,
                    "daemon_installation_id": null,
                    "created_at": "2026-07-15T00:02:00Z"
                }
            ],
            "next_cursor": "resolved:4",
            "has_more": false
        }));
    }
    if query.after_cursor.is_some() {
        return Json(json!({
            "events": [],
            "next_cursor": null,
            "has_more": false
        }));
    }
    Json(json!({
        "events": [
            {
                "event_id": "evt_conflict",
                "draft_id": "drf_conflict",
                "project_id": "prj_conflict",
                "event_type": "conflicted",
                "version": 3,
                "daemon_installation_id": null,
                "created_at": "2026-07-15T00:00:00Z"
            }
        ],
        "next_cursor": "conflict:3",
        "has_more": false
    }))
}

async fn fake_conflicted_draft(
    axum::extract::State(state): axum::extract::State<FakeConflictProjectionState>,
    axum::extract::Path(draft_id): axum::extract::Path<String>,
) -> Json<serde_json::Value> {
    if state.resolved.load(Ordering::SeqCst) > 0 {
        return Json(json!({
            "draft": {
                "draft_id": draft_id,
                "project_id": "prj_conflict",
                "base_commit_id": COMMIT_B,
                "resource": {
                    "scope": "project",
                    "kind": "context",
                    "id": "ctx_conflict",
                    "path": "docs/conflict.md"
                },
                "status": "submitted",
                "version": 4,
                "created_at": "2026-07-15T00:00:00Z",
                "updated_at": "2026-07-15T00:02:00Z"
            },
            "operations": [
                {
                    "operation_id": "dop_resolved",
                    "action": "update",
                    "resource": {
                        "scope": "project",
                        "kind": "context",
                        "id": "ctx_conflict",
                        "path": "docs/conflict.md"
                    },
                    "body": "Resolved content",
                    "new_path": null,
                    "created_at": "2026-07-15T00:02:00Z"
                }
            ],
            "conflict": null
        }));
    }
    Json(json!({
        "draft": {
            "draft_id": draft_id,
            "project_id": "prj_conflict",
            "base_commit_id": COMMIT_A,
            "resource": {
                "scope": "project",
                "kind": "context",
                "id": "ctx_conflict",
                "path": "docs/conflict.md"
            },
            "status": "conflicted",
            "version": 3,
            "created_at": "2026-07-15T00:00:00Z",
            "updated_at": "2026-07-15T00:01:00Z"
        },
        "operations": [
            {
                "operation_id": "dop_conflict",
                "action": "update",
                "resource": {
                    "scope": "project",
                    "kind": "context",
                    "id": "ctx_conflict",
                    "path": "docs/conflict.md"
                },
                "body": "Draft content",
                "new_path": null,
                "created_at": "2026-07-15T00:00:30Z"
            }
        ],
        "conflict": {
            "base_commit_id": COMMIT_A,
            "current_commit_id": COMMIT_B,
            "detected_at": "2026-07-15T00:01:00Z"
        }
    }))
}
