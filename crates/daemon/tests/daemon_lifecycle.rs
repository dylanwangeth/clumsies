mod common;

use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use daemon::{
    DaemonConfig, DaemonDraftDetail, DaemonDraftListResponse, DaemonDraftOperationResponse,
    DaemonDraftOperationSource, DaemonDraftResourceKind, DaemonEndpointFile, DaemonHealth,
    DaemonLocalDraftStatus, DaemonMcpStatus, DaemonProjectConfig, DaemonState, DaemonSyncStatus,
    DraftOperationSyncStatus, ErrorEnvelope, SyncState, router,
};
use serde::de::DeserializeOwned;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn health_initializes_local_database_and_stable_installation_id() {
    let (root, state, app) = common::test_daemon().await;
    let first_id = state.daemon_installation_id().to_owned();

    let health: DaemonHealth = get_json(app, "/daemon/health").await;

    assert!(health.local_db.ready);
    assert_eq!(health.local_db.schema_version, 3);
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
async fn binary_writes_endpoint_file_for_random_port() {
    let root = tempfile::tempdir().unwrap();
    let endpoint_path = root.path().join("daemon-endpoint.json");
    let mut child = Command::new(env!("CARGO_BIN_EXE_clumsiesd"))
        .env("CLUMSIES_DAEMON_ROOT", root.path())
        .env("CLUMSIES_DAEMON_ADDR", "127.0.0.1:0")
        .env("CLUMSIES_SYNC_ENABLED", "false")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let endpoint = wait_for_endpoint_file(&endpoint_path, &mut child).await;
    assert_eq!(endpoint.pid, child.id());
    assert!(endpoint.endpoint.starts_with("http://127.0.0.1:"));
    assert!(endpoint.daemon_installation_id.starts_with("daemon_"));

    let health: DaemonHealth = reqwest::get(format!("{}/daemon/health", endpoint.endpoint))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        health.daemon_installation_id,
        endpoint.daemon_installation_id
    );
    assert!(health.local_db.ready);

    let interrupt_status = Command::new("kill")
        .arg("-INT")
        .arg(child.id().to_string())
        .status()
        .unwrap();
    assert!(interrupt_status.success());
    let exit_status = child.wait().unwrap();
    assert!(exit_status.success());
    assert!(!endpoint_path.exists());
}

#[tokio::test]
async fn draft_operation_is_written_to_local_queue_and_visible_in_sync_status() {
    let (_root, _state, app) = common::test_daemon().await;
    let operation = json!({
        "resource": "context",
        "op": {
            "create": {
                "path": "docs/architecture.md",
                "body": "Initial context",
                "description": "seed project context"
            }
        },
        "source": "mcp_store"
    });

    let response = app
        .clone()
        .oneshot(json_request("/daemon/draft-operations", operation))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body: DaemonDraftOperationResponse = response_json(response).await;
    assert!(body.local_operation_id.starts_with("op_"));
    assert!(body.draft_id.starts_with("draft_"));
    assert!(body.queued);
    assert_eq!(body.sync_status, DraftOperationSyncStatus::Queued);

    let status: DaemonSyncStatus = get_json(app, "/daemon/sync-status").await;
    assert_eq!(status.pending_operation_count, 1);
    assert_eq!(status.failed_operation_count, 0);
    assert_eq!(status.draft_sync.state, SyncState::Queued);
    assert_eq!(status.draft_sync.server_cursor, None);
    assert_eq!(status.draft_sync.last_attempt_at, None);
    assert_eq!(status.draft_sync.last_success_at, None);
    assert_eq!(status.last_success_at, None);
}

#[tokio::test]
async fn local_drafts_can_be_listed_and_read_with_operation_history() {
    let (_root, _state, app) = common::test_daemon().await;

    let created = app
        .clone()
        .oneshot(json_request(
            "/daemon/draft-operations",
            json!({
                "resource": "context",
                "op": {
                    "create": {
                        "path": "docs/local.md",
                        "body": "Local draft"
                    }
                },
                "source": "mcp_store"
            }),
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let created: DaemonDraftOperationResponse = response_json(created).await;

    let updated = app
        .clone()
        .oneshot(json_request(
            "/daemon/draft-operations",
            json!({
                "resource": "context",
                "op": {
                    "update": {
                        "id": created.draft_id,
                        "body": "Local draft v2"
                    }
                },
                "source": "cli"
            }),
        ))
        .await
        .unwrap();
    assert_eq!(updated.status(), StatusCode::OK);

    let list: DaemonDraftListResponse =
        get_json(app.clone(), "/daemon/drafts?resource=context&status=open").await;
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

    let detail: DaemonDraftDetail =
        get_json(app.clone(), &format!("/daemon/drafts/{}", created.draft_id)).await;
    assert_eq!(detail.draft.draft_id, created.draft_id);
    assert_eq!(detail.operations.len(), 2);
    assert_eq!(
        detail.operations[0].source,
        DaemonDraftOperationSource::McpStore
    );
    assert_eq!(
        detail.operations[0].sync_status,
        DraftOperationSyncStatus::Queued
    );
    assert_eq!(
        detail.operations[0].operation.create.as_ref().unwrap().body,
        "Local draft"
    );
    assert_eq!(detail.operations[1].source, DaemonDraftOperationSource::Cli);
    assert_eq!(
        detail.operations[1].operation.update.as_ref().unwrap().body,
        "Local draft v2"
    );

    let missing = app
        .oneshot(
            Request::builder()
                .uri("/daemon/drafts/missing")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    let body: ErrorEnvelope = response_json(missing).await;
    assert_eq!(body.error.code, "not_found");
}

#[tokio::test]
async fn project_config_can_be_replaced_and_persists_across_restarts() {
    let (root, _state, app) = common::test_daemon().await;

    let initial: DaemonProjectConfig = get_json(app.clone(), "/daemon/project-config").await;
    assert_eq!(initial.hub_url, "http://127.0.0.1:8080");
    assert_eq!(initial.author_user_id, None);
    assert_eq!(initial.project_id, None);
    assert!(!initial.has_access_token);
    assert!(!initial.ready);
    assert_eq!(initial.missing_fields, vec!["author_user_id", "project_id"]);

    let response = app
        .clone()
        .oneshot(json_put_request(
            "/daemon/project-config",
            json!({
                "hub_url": "http://127.0.0.1:18080",
                "author_user_id": "usr_config",
                "project_id": "prj_config",
                "access_token": "secret-token"
            }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let updated: DaemonProjectConfig = response_json(response).await;
    assert_eq!(updated.hub_url, "http://127.0.0.1:18080");
    assert_eq!(updated.author_user_id.as_deref(), Some("usr_config"));
    assert_eq!(updated.project_id.as_deref(), Some("prj_config"));
    assert!(updated.has_access_token);
    assert!(updated.ready);
    assert!(updated.missing_fields.is_empty());

    let health: DaemonHealth = get_json(app, "/daemon/health").await;
    assert_eq!(health.hub_url, "http://127.0.0.1:18080");
    assert_eq!(health.project_id.as_deref(), Some("prj_config"));

    let restarted = DaemonState::initialize(DaemonConfig::for_root(root.path()))
        .await
        .unwrap();
    let restarted_app = router(restarted);
    let persisted: DaemonProjectConfig = get_json(restarted_app, "/daemon/project-config").await;
    assert_eq!(persisted.hub_url, "http://127.0.0.1:18080");
    assert_eq!(persisted.author_user_id.as_deref(), Some("usr_config"));
    assert_eq!(persisted.project_id.as_deref(), Some("prj_config"));
    assert!(persisted.has_access_token);
    assert!(persisted.ready);
}

#[tokio::test]
async fn sync_retry_uploads_new_local_draft_to_hub() {
    let hub = FakeHub::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.hub_url = hub.url.clone();
    config.project.author_user_id = Some("usr_test".to_owned());
    config.project.project_id = Some("prj_test".to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let app = router(state.clone());

    let operation = json!({
        "resource": "context",
        "op": {
            "create": {
                "path": "docs/sync.md",
                "body": "Sync me"
            }
        },
        "source": "desktop"
    });
    let queued = app
        .clone()
        .oneshot(json_request("/daemon/draft-operations", operation))
        .await
        .unwrap();
    assert_eq!(queued.status(), StatusCode::OK);

    let retry = app
        .clone()
        .oneshot(json_request(
            "/daemon/sync-retries",
            json!({ "channel": "drafts" }),
        ))
        .await
        .unwrap();
    assert_eq!(retry.status(), StatusCode::OK);

    let status: DaemonSyncStatus = get_json(app, "/daemon/sync-status").await;
    assert_eq!(status.pending_operation_count, 0);
    assert_eq!(status.failed_operation_count, 0);
    assert_eq!(status.draft_sync.state, SyncState::Idle);
    assert_eq!(status.draft_sync.server_cursor.as_deref(), Some("42"));
    assert!(status.draft_sync.last_attempt_at.is_some());
    assert!(status.draft_sync.last_success_at.is_some());
    assert_eq!(status.last_success_at, status.draft_sync.last_success_at);

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

    let requests = hub.create_requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["author_user_id"], "usr_test");
    assert_eq!(requests[0]["project_id"], "prj_test");
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
async fn queued_draft_syncs_after_project_config_is_set() {
    let hub = FakeHub::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let state = DaemonState::initialize(config).await.unwrap();
    let worker = state.start_sync_worker().unwrap();
    let app = router(state);

    let queued = app
        .clone()
        .oneshot(json_request(
            "/daemon/draft-operations",
            json!({
                "resource": "context",
                "op": {
                    "create": {
                        "path": "docs/later-config.md",
                        "body": "sync after config"
                    }
                }
            }),
        ))
        .await
        .unwrap();
    assert_eq!(queued.status(), StatusCode::OK);

    tokio::time::sleep(Duration::from_millis(50)).await;
    let before: DaemonSyncStatus = get_json(app.clone(), "/daemon/sync-status").await;
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
    assert!(hub.create_requests.lock().unwrap().is_empty());

    let configured = app
        .clone()
        .oneshot(json_put_request(
            "/daemon/project-config",
            json!({
                "hub_url": hub.url.clone(),
                "author_user_id": "usr_late",
                "project_id": "prj_late",
                "access_token": null
            }),
        ))
        .await
        .unwrap();
    assert_eq!(configured.status(), StatusCode::OK);

    wait_for_create_request(&hub).await;
    let after: DaemonSyncStatus = get_json(app, "/daemon/sync-status").await;
    assert_eq!(after.pending_operation_count, 0);
    assert_eq!(after.failed_operation_count, 0);
    assert_eq!(after.draft_sync.state, SyncState::Idle);

    let requests = hub.create_requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["author_user_id"], "usr_late");
    assert_eq!(requests[0]["project_id"], "prj_late");
    assert_eq!(requests[0]["operations"][0]["body"], "sync after config");
    drop(requests);
    worker.abort();
}

#[tokio::test]
async fn draft_operation_notifies_auto_sync_worker() {
    let hub = FakeHub::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.hub_url = hub.url.clone();
    config.project.author_user_id = Some("usr_test".to_owned());
    config.project.project_id = Some("prj_test".to_owned());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let state = DaemonState::initialize(config).await.unwrap();
    let worker = state.start_sync_worker().unwrap();
    let app = router(state);

    let queued = app
        .clone()
        .oneshot(json_request(
            "/daemon/draft-operations",
            json!({
                "resource": "context",
                "op": {
                    "create": {
                        "path": "docs/auto.md",
                        "body": "automatic"
                    }
                }
            }),
        ))
        .await
        .unwrap();
    assert_eq!(queued.status(), StatusCode::OK);

    wait_for_create_request(&hub).await;
    let status: DaemonSyncStatus = get_json(app, "/daemon/sync-status").await;
    assert_eq!(status.pending_operation_count, 0);
    assert_eq!(status.failed_operation_count, 0);

    let requests = hub.create_requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["operations"][0]["body"], "automatic");
    drop(requests);
    worker.abort();
}

#[tokio::test]
async fn sync_retry_uploads_existing_draft_operations_as_batch() {
    let hub = FakeHub::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.hub_url = hub.url.clone();
    config.project.author_user_id = Some("usr_test".to_owned());
    config.project.project_id = Some("prj_test".to_owned());
    let state = DaemonState::initialize(config).await.unwrap();
    let app = router(state);

    let first = app
        .clone()
        .oneshot(json_request(
            "/daemon/draft-operations",
            json!({
                "resource": "context",
                "op": {
                    "create": {
                        "path": "docs/batch.md",
                        "body": "one"
                    }
                }
            }),
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let first: DaemonDraftOperationResponse = response_json(first).await;
    assert_eq!(
        app.clone()
            .oneshot(json_request(
                "/daemon/sync-retries",
                json!({ "channel": "drafts" }),
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );

    let second = app
        .clone()
        .oneshot(json_request(
            "/daemon/draft-operations",
            json!({
                "resource": "context",
                "op": {
                    "update": {
                        "id": first.draft_id,
                        "body": "two"
                    }
                }
            }),
        ))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);
    assert_eq!(
        app.clone()
            .oneshot(json_request(
                "/daemon/sync-retries",
                json!({ "channel": "drafts" }),
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );

    let status: DaemonSyncStatus = get_json(app, "/daemon/sync-status").await;
    assert_eq!(status.pending_operation_count, 0);
    assert_eq!(status.failed_operation_count, 0);

    let creates = hub.create_requests.lock().unwrap();
    assert_eq!(creates.len(), 1);
    drop(creates);

    let batches = hub.batch_requests.lock().unwrap();
    assert_eq!(batches.len(), 1);
    assert!(
        batches[0]["daemon_installation_id"]
            .as_str()
            .unwrap()
            .starts_with("daemon_")
    );
    assert_eq!(batches[0]["operations"][0]["draft_id"], "drf_remote");
    assert_eq!(batches[0]["operations"][0]["expected_draft_version"], 1);
    assert_eq!(batches[0]["operations"][0]["operation"]["action"], "update");
    assert_eq!(batches[0]["operations"][0]["operation"]["body"], "two");
}

#[tokio::test]
async fn draft_operation_rejects_multiple_operation_variants() {
    let (_root, _state, app) = common::test_daemon().await;
    let operation = json!({
        "resource": "rule",
        "op": {
            "create": {
                "path": "rules/a.md",
                "body": "Rule"
            },
            "delete": {
                "id": "rule_1"
            }
        }
    });

    let response = app
        .oneshot(json_request("/daemon/draft-operations", operation))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body: ErrorEnvelope = response_json(response).await;
    assert_eq!(body.error.code, "invalid_draft_operation");
}

#[tokio::test]
async fn mcp_status_reports_no_daemon_owned_supervisor() {
    let (_, _, app) = common::test_daemon().await;

    let status: DaemonMcpStatus = get_json(app, "/daemon/mcp-status").await;

    assert!(!status.running);
    assert_eq!(status.endpoint, None);
    assert!(status.adapters.is_empty());
}

async fn get_json<T>(app: axum::Router, uri: &str) -> T
where
    T: DeserializeOwned,
{
    let response = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response_json(response).await
}

fn json_request(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap()
}

fn json_put_request(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("PUT")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap()
}

async fn response_json<T>(response: axum::response::Response) -> T
where
    T: DeserializeOwned,
{
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}

async fn wait_for_endpoint_file(
    path: &std::path::Path,
    child: &mut std::process::Child,
) -> DaemonEndpointFile {
    let started_at = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("clumsiesd exited before writing endpoint file: {status}");
        }
        if let Ok(body) = std::fs::read_to_string(path) {
            return serde_json::from_str(&body).unwrap();
        }
        if started_at.elapsed() > Duration::from_secs(5) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("timed out waiting for clumsiesd endpoint file");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

async fn wait_for_create_request(hub: &FakeHub) {
    for _ in 0..50 {
        if !hub.create_requests.lock().unwrap().is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for fake Hub create request");
}

struct FakeHub {
    url: String,
    create_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    batch_requests: Arc<Mutex<Vec<serde_json::Value>>>,
}

impl FakeHub {
    async fn start() -> Self {
        let create_requests = Arc::new(Mutex::new(Vec::new()));
        let batch_requests = Arc::new(Mutex::new(Vec::new()));
        let state = FakeHubState {
            create_requests: create_requests.clone(),
            batch_requests: batch_requests.clone(),
        };
        let app = Router::new()
            .route("/api/v1/drafts", post(fake_create_draft))
            .route("/api/v1/draft-events", get(fake_list_draft_events))
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
        }
    }
}

#[derive(Clone)]
struct FakeHubState {
    create_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    batch_requests: Arc<Mutex<Vec<serde_json::Value>>>,
}

async fn fake_create_draft(
    axum::extract::State(state): axum::extract::State<FakeHubState>,
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
    axum::extract::State(state): axum::extract::State<FakeHubState>,
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

async fn fake_list_draft_events() -> Json<serde_json::Value> {
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
