mod common;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::routing::{get, post};
use axum::{Json, Router};
use daemon::{
    ActivateMemoryRequest, CURRENT_LOCAL_SCHEMA_VERSION, DAEMON_AGENT_LABEL,
    DAEMON_MACH_SERVICE_NAME, DaemonConfig, DaemonContentDraftUpdate, DaemonCreateDraftOperation,
    DaemonDeleteDraftOperation, DaemonDiscardDraftOperation, DaemonDraftContent,
    DaemonDraftListQuery, DaemonDraftOperation, DaemonDraftOperationRecordSource,
    DaemonDraftOperationRequest, DaemonDraftOperationSource, DaemonDraftResourceKind,
    DaemonDraftScope, DaemonError, DaemonHealth, DaemonIpcRequest, DaemonIpcService,
    DaemonIpcTransport, DaemonLocalDraftStatus, DaemonMemoryCacheRequest, DaemonMemoryCacheState,
    DaemonMemoryCacheStatus, DaemonProjectBindingReplaceRequest,
    DaemonProjectBindingResolveRequest, DaemonProjectCheckout, DaemonProjectCheckoutRequest,
    DaemonProjectConfigUpdateRequest, DaemonProjectSelectionRequest, DaemonServerRequest,
    DaemonState, DaemonSyncRetryRequest, DaemonUpdateDraftOperation, DraftOperationSyncStatus,
    IDENTIFIER_NAMESPACE, LaunchAgentConfig, LaunchAgentController, LaunchAgentRuntimeStatus,
    ServerCredentials, SyncRetryChannel, SyncState,
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::sync::Notify;

const COMMIT_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const COMMIT_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn fake_daemon_program(root: &Path) -> PathBuf {
    let path = root.join("bin/clumsiesd");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "test daemon").unwrap();
    path
}

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

    let restarted = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        common::TestCredentialStore::default(),
    )
    .await;
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

    let error = DaemonState::initialize_with_credential_store(
        DaemonConfig::for_root(root.path()),
        Arc::new(common::TestCredentialStore::default()),
    )
    .await
    .err()
    .unwrap();

    assert!(matches!(error, DaemonError::InvalidConfig(_)));
    assert!(error.to_string().contains("recreate the daemon database"));
}

#[tokio::test]
async fn schema_13_migration_removes_metaprompt_and_resets_rebuildable_memory_state() {
    let root = tempfile::tempdir().unwrap();
    let database_path = root.path().join("local.db");
    std::fs::File::create(&database_path).unwrap();
    let database_url = format!("sqlite://{}", database_path.display());
    let pool = sqlx::SqlitePool::connect(&database_url).await.unwrap();
    for statement in [
        "CREATE TABLE daemon_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "INSERT INTO daemon_meta (key, value) VALUES
            ('schema_version', '13'),
            ('search_schema_version', '1'),
            ('draft_events_cursor', 'cursor_old')",
        "CREATE TABLE local_drafts (
            draft_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            server_draft_id TEXT,
            server_version BIGINT NOT NULL DEFAULT 0,
            base_commit_id TEXT,
            resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow', 'metaprompt')),
            target_id TEXT,
            path TEXT,
            conflict_base_commit_id TEXT,
            conflict_current_commit_id TEXT,
            conflicted_at TEXT,
            status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'discarded', 'conflicted', 'merged')) DEFAULT 'open',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
        "CREATE TABLE local_draft_operations (
            local_operation_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL REFERENCES local_drafts(draft_id) ON DELETE CASCADE,
            server_operation_id TEXT,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow', 'metaprompt')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store', 'server')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'retrying', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
        "INSERT INTO local_drafts (
            draft_id, project_id, resource_scope, resource_kind, path, status,
            created_at, updated_at
         ) VALUES
            ('draft_context', 'project', 'project', 'context', 'context/keep.md', 'open', 'now', 'now'),
            ('draft_rule', 'project', 'project', 'rule', 'rules/testing.md', 'open', 'now', 'now'),
            ('draft_metaprompt', 'project', 'project', 'metaprompt', 'META_PROMPT.md', 'open', 'now', 'now')",
        r##"INSERT INTO local_draft_operations (
            local_operation_id, draft_id, resource_kind, operation_json, source,
            sync_status, created_at, updated_at
         ) VALUES
            ('operation_context', 'draft_context', 'context', '{}', 'desktop', 'queued', 'now', 'now'),
            ('operation_rule', 'draft_rule', 'rule', '{"create":{"path":"rules/testing.md","content":{"kind":"rule","name":"Testing","applies_when":"While coding","constraint":"# Testing\n\nRun focused tests.","tags":["testing"]},"description":null},"update":null,"rename":null,"delete":null,"discard":null}', 'desktop', 'queued', 'now', 'now'),
            ('operation_metaprompt', 'draft_metaprompt', 'metaprompt', '{}', 'desktop', 'queued', 'now', 'now')"##,
        "CREATE TABLE cached_blobs (
            blob_id TEXT PRIMARY KEY,
            content TEXT NOT NULL
        )",
        "CREATE TABLE cached_trees (
            tree_id TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL
        )",
        "CREATE TABLE cached_commits (
            commit_id TEXT PRIMARY KEY,
            scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
            org_id TEXT NOT NULL,
            project_id TEXT,
            tree_id TEXT NOT NULL,
            parent_commit_id TEXT,
            version BIGINT NOT NULL,
            created_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )",
        "CREATE TABLE cached_refs (
            ref_key TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
            org_id TEXT NOT NULL,
            project_id TEXT,
            commit_id TEXT,
            etag TEXT NOT NULL,
            server_updated_at TEXT NOT NULL,
            installed_at TEXT NOT NULL
        )",
        "INSERT INTO cached_blobs (blob_id, content)
         VALUES ('blob_old', 'obsolete bootstrap')",
        "INSERT INTO cached_trees (tree_id, payload_json)
         VALUES ('tree_old', '{\"tree_id\":\"tree_old\",\"entries\":[{\"type\":\"metaprompt\"}]}')",
        "INSERT INTO cached_commits (
            commit_id, scope, org_id, tree_id, version, created_at, payload_json
         ) VALUES ('commit_old', 'org', 'org', 'tree_old', 1, 'now', '{}')",
        "INSERT INTO cached_refs (
            ref_key, name, scope, org_id, commit_id, etag, server_updated_at, installed_at
         ) VALUES ('org:org', 'refs/heads/main', 'org', 'org', 'commit_old', 'commit_old', 'now', 'now')",
    ] {
        sqlx::query(statement).execute(&pool).await.unwrap();
    }
    pool.close().await;

    let stale_generation = root
        .path()
        .join("cache/projects/project/generations/commit_old");
    std::fs::create_dir_all(&stale_generation).unwrap();
    std::fs::write(
        stale_generation.join("META_PROMPT.md"),
        "obsolete bootstrap",
    )
    .unwrap();

    let _state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        common::TestCredentialStore::default(),
    )
    .await;
    let pool = sqlx::SqlitePool::connect(&database_url).await.unwrap();

    let schema_version: String =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'schema_version'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(schema_version, CURRENT_LOCAL_SCHEMA_VERSION.to_string());
    let drafts: Vec<String> =
        sqlx::query_scalar("SELECT draft_id FROM local_drafts ORDER BY draft_id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(drafts, vec!["draft_context", "draft_rule"]);
    let operations: Vec<String> = sqlx::query_scalar(
        "SELECT local_operation_id FROM local_draft_operations ORDER BY local_operation_id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(operations, vec!["operation_context", "operation_rule"]);
    let migrated_rule_operation: String = sqlx::query_scalar(
        "SELECT operation_json
         FROM local_draft_operations
         WHERE local_operation_id = 'operation_rule'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let migrated_rule_operation: serde_json::Value =
        serde_json::from_str(&migrated_rule_operation).unwrap();
    assert_eq!(
        migrated_rule_operation["create"]["content"],
        json!({
            "kind": "rule",
            "content": "# Testing\n\n## Applies when\n\nWhile coding\n\n## Constraint\n\n# Testing\n\nRun focused tests.\n\nTags: testing"
        })
    );
    for table in [
        "cached_refs",
        "cached_commits",
        "cached_trees",
        "cached_blobs",
    ] {
        let query = format!("SELECT COUNT(*) FROM {table}");
        let count: i64 = sqlx::query_scalar(&query).fetch_one(&pool).await.unwrap();
        assert_eq!(count, 0, "{table} was not reset");
    }
    let replay_cursor: Option<String> =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'draft_events_cursor'")
            .fetch_optional(&pool)
            .await
            .unwrap();
    assert!(replay_cursor.is_none());
    let reset_marker: Option<String> = sqlx::query_scalar(
        "SELECT value FROM daemon_meta WHERE key = 'memory_cache_reset_required'",
    )
    .fetch_optional(&pool)
    .await
    .unwrap();
    assert!(reset_marker.is_none());
    let search_schema_version: String =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'search_schema_version'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(search_schema_version, "2");
    assert!(!root.path().join("cache/projects").exists());

    let rejected = sqlx::query(
        "INSERT INTO local_drafts (
            draft_id, project_id, resource_scope, resource_kind, status
         ) VALUES ('draft_rejected', 'project', 'project', 'metaprompt', 'open')",
    )
    .execute(&pool)
    .await;
    assert!(rejected.is_err());
}

#[tokio::test]
async fn schema_14_migration_separates_conflicted_lifecycle_from_coordination() {
    let root = tempfile::tempdir().unwrap();
    let database_path = root.path().join("local.db");
    std::fs::File::create(&database_path).unwrap();
    let database_url = format!("sqlite://{}", database_path.display());
    let pool = sqlx::SqlitePool::connect(&database_url).await.unwrap();
    for statement in [
        "CREATE TABLE daemon_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "INSERT INTO daemon_meta (key, value) VALUES ('schema_version', '14')",
        "CREATE TABLE local_drafts (
            draft_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            server_draft_id TEXT,
            server_version BIGINT NOT NULL DEFAULT 0,
            base_commit_id TEXT,
            resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            target_id TEXT,
            path TEXT,
            conflict_base_commit_id TEXT,
            conflict_current_commit_id TEXT,
            conflicted_at TEXT,
            status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'discarded', 'conflicted', 'merged')) DEFAULT 'open',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
        "CREATE TABLE local_draft_operations (
            local_operation_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL REFERENCES local_drafts(draft_id) ON DELETE CASCADE,
            server_operation_id TEXT,
            resource_kind TEXT NOT NULL CHECK (resource_kind IN ('context', 'rule', 'workflow')),
            operation_json TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('desktop', 'cli', 'mcp_store', 'server')),
            sync_status TEXT NOT NULL CHECK (sync_status IN ('queued', 'syncing', 'retrying', 'synced', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
        "INSERT INTO local_drafts (
            draft_id, project_id, server_draft_id, server_version, base_commit_id,
            resource_scope, resource_kind, target_id, path,
            conflict_base_commit_id, conflict_current_commit_id, conflicted_at,
            status, created_at, updated_at
         ) VALUES (
            'draft_conflicted', 'project_test', 'server_draft', 4, 'commit_base',
            'project', 'context', 'context_test', 'context/test.md',
            'commit_base', 'commit_current', '2026-07-22T00:00:00Z',
            'conflicted', '2026-07-22T00:00:00Z', '2026-07-22T00:01:00Z'
         )",
        r#"INSERT INTO local_draft_operations (
            local_operation_id, draft_id, server_operation_id, resource_kind,
            operation_json, source, sync_status, created_at, updated_at
         ) VALUES (
            'operation_test', 'draft_conflicted', 'server_operation', 'context',
            '{"create":null,"update":{"id":"context_test","content":{"kind":"context","content":"Draft body"},"description":null},"rename":null,"delete":null,"discard":null}',
            'desktop', 'synced', '2026-07-22T00:00:00Z', '2026-07-22T00:01:00Z'
         )"#,
    ] {
        sqlx::query(statement).execute(&pool).await.unwrap();
    }
    pool.close().await;

    let _state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        common::TestCredentialStore::default(),
    )
    .await;
    let pool = sqlx::SqlitePool::connect(&database_url).await.unwrap();
    let row: (
        Option<String>,
        Option<String>,
        String,
        String,
        Option<String>,
        String,
    ) = sqlx::query_as(
        "SELECT base_commit_id, current_commit_id, freshness, reconciliation,
                    reconciliation_candidate_id, status
             FROM local_drafts WHERE draft_id = 'draft_conflicted'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row.0.as_deref(), Some("commit_base"));
    assert_eq!(row.1.as_deref(), Some("commit_current"));
    assert_eq!(row.2, "behind");
    assert_eq!(row.3, "unknown");
    assert_eq!(row.4, None);
    assert_eq!(row.5, "submitted");
    let operation_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM local_draft_operations WHERE draft_id = 'draft_conflicted'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(operation_count, 1);
    assert!(
        sqlx::query(
            "UPDATE local_drafts SET status = 'conflicted' WHERE draft_id = 'draft_conflicted'"
        )
        .execute(&pool)
        .await
        .is_err()
    );
    let project_bindings_table: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master
         WHERE type = 'table' AND name = 'project_bindings'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(project_bindings_table, 1);
}

#[test]
fn launch_agent_plist_uses_standard_identity_and_runtime_paths() {
    let root = tempfile::tempdir().unwrap();
    let config = DaemonConfig::for_root(root.path());
    let program_path = fake_daemon_program(root.path());
    let launch_agent = LaunchAgentConfig::from_daemon_config(&config, &program_path).unwrap();

    assert_eq!(IDENTIFIER_NAMESPACE, "ai.clumsies");
    assert_eq!(DAEMON_AGENT_LABEL, "ai.clumsies.daemon");
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
        LaunchAgentConfig::from_daemon_config(&config, fake_daemon_program(root.path())).unwrap();

    launch_agent.install_plist().unwrap();

    let plist = std::fs::read_to_string(&launch_agent.plist_path).unwrap();
    assert!(plist.contains(IDENTIFIER_NAMESPACE));
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
        LaunchAgentConfig::from_daemon_config(&config, fake_daemon_program(root.path())).unwrap();
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
                    content: context_content("Initial context"),
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
                    content: context_content("Created through daemon service"),
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
    assert_eq!(
        memory_cache.state,
        DaemonMemoryCacheState::ProjectRefNotSynced
    );

    let activation = service
        .dispatch(DaemonIpcRequest::new(
            "activate_memory",
            serde_json::to_value(ActivateMemoryRequest {
                project_id: "prj_test".to_owned(),
                query: "writing".to_owned(),
                state: None,
            })
            .unwrap(),
        ))
        .await;
    assert!(!activation.ok);
    assert_eq!(activation.error.unwrap().code, "project_ref_not_synced");

    let project_checkout: DaemonProjectCheckout = service
        .dispatch(DaemonIpcRequest::new(
            "project_checkout",
            serde_json::to_value(DaemonProjectCheckoutRequest {
                project_id: "prj_test".to_owned(),
            })
            .unwrap(),
        ))
        .await
        .into_payload()
        .unwrap();
    assert!(!project_checkout.ready);
    assert!(project_checkout.resources.is_empty());

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
                        content: context_content("Created through IPC dispatch"),
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
                        "content": {
                            "kind": "context",
                            "content": "Stored through the Zig MCP envelope"
                        }
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
                    content: context_content("Local draft"),
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
                update: Some(DaemonUpdateDraftOperation::Content(
                    DaemonContentDraftUpdate {
                        id: created.draft_id.clone(),
                        content: context_content("Local draft v2"),
                        description: None,
                    },
                )),
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
        detail.operations[0]
            .operation
            .create
            .as_ref()
            .unwrap()
            .content,
        context_content("Local draft")
    );
    assert_eq!(
        detail.operations[1].source,
        DaemonDraftOperationRecordSource::Cli
    );
    assert_eq!(
        detail.operations[1]
            .operation
            .update
            .as_ref()
            .unwrap()
            .content(),
        Some(&context_content("Local draft v2"))
    );

    assert!(matches!(
        service.get_draft("missing").await,
        Err(DaemonError::NotFound(_))
    ));
}

#[tokio::test]
async fn project_config_can_be_replaced_and_persists_across_restarts() {
    let root = tempfile::tempdir().unwrap();
    let credential_store = common::TestCredentialStore::default();
    let state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;
    let service = DaemonIpcService::new(state);

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
    let stored_credentials = credential_store.credentials().unwrap();
    assert_eq!(stored_credentials.server_url, "http://127.0.0.1:18080");
    assert_eq!(stored_credentials.access_token, "secret-token");
    assert_eq!(
        stored_credentials.refresh_token.as_deref(),
        Some("refresh-token")
    );

    let metadata_pool = sqlx::SqlitePool::connect(&format!(
        "sqlite://{}",
        root.path().join("local.db").display()
    ))
    .await
    .unwrap();
    let persisted_secret_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM daemon_meta
         WHERE key IN ('project_config_access_token', 'project_config_refresh_token')",
    )
    .fetch_one(&metadata_pool)
    .await
    .unwrap();
    assert_eq!(persisted_secret_count, 0);
    metadata_pool.close().await;

    let health = service.health().await;
    assert_eq!(health.server_url, "http://127.0.0.1:18080");
    assert_eq!(health.project_id.as_deref(), Some("prj_config"));

    let restarted = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;
    let restarted_service = DaemonIpcService::new(restarted);
    let persisted = restarted_service.project_config();
    assert_eq!(persisted.server_url, "http://127.0.0.1:18080");
    assert_eq!(persisted.project_id.as_deref(), Some("prj_config"));
    assert!(persisted.has_access_token);
    assert!(persisted.has_refresh_token);
    assert!(persisted.ready);

    let signed_out = restarted_service
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: "http://127.0.0.1:18080".to_owned(),
            project_id: Some("prj_config".to_owned()),
            access_token: None,
            refresh_token: None,
        })
        .await
        .unwrap();
    assert!(!signed_out.has_access_token);
    assert!(!signed_out.has_refresh_token);
    assert!(credential_store.credentials().is_none());
}

#[tokio::test]
async fn selecting_a_project_preserves_credentials_and_persists_the_active_project() {
    let root = tempfile::tempdir().unwrap();
    let credential_store = common::TestCredentialStore::default();
    let state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;
    let service = DaemonIpcService::new(state);

    service
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: "https://clumsies.example.com".to_owned(),
            project_id: Some("prj_first".to_owned()),
            access_token: Some("access-token".to_owned()),
            refresh_token: Some("refresh-token".to_owned()),
        })
        .await
        .unwrap();

    let selected = service
        .select_project(DaemonProjectSelectionRequest {
            project_id: "prj_second".to_owned(),
        })
        .await
        .unwrap();

    assert_eq!(selected.project_id.as_deref(), Some("prj_second"));
    assert_eq!(selected.server_url, "https://clumsies.example.com");
    assert!(selected.has_access_token);
    assert!(selected.has_refresh_token);
    assert_eq!(
        credential_store.credentials().unwrap(),
        ServerCredentials {
            server_url: "https://clumsies.example.com".to_owned(),
            access_token: "access-token".to_owned(),
            refresh_token: Some("refresh-token".to_owned()),
        }
    );

    let restarted = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;
    assert_eq!(
        restarted.project_config_status().project_id.as_deref(),
        Some("prj_second")
    );

    let error = DaemonIpcService::new(restarted)
        .select_project(DaemonProjectSelectionRequest {
            project_id: "  ".to_owned(),
        })
        .await
        .unwrap_err();
    assert!(error.to_string().contains("project_id must not be empty"));
}

async fn accessible_project() -> Json<serde_json::Value> {
    Json(json!({
        "project_id": "accessible",
        "name": "Accessible Project"
    }))
}

async fn empty_project_commit_state(
    axum::extract::Path(project_id): axum::extract::Path<String>,
) -> impl axum::response::IntoResponse {
    (
        [(axum::http::header::ETAG, "\"ref-none\"")],
        Json(json!({
            "update_available": false,
            "ref": {
                "name": "refs/heads/main",
                "scope": "project",
                "org_id": "org_bindings",
                "project_id": project_id,
                "commit_id": null,
                "updated_at": "2026-07-22T00:00:00Z"
            },
            "latest": null,
            "download_url": null,
            "incremental_supported": false
        })),
    )
}

async fn empty_org_commit_state() -> impl axum::response::IntoResponse {
    (
        [(axum::http::header::ETAG, "\"ref-none\"")],
        Json(json!({
            "update_available": false,
            "ref": {
                "name": "refs/heads/main",
                "scope": "org",
                "org_id": "org_bindings",
                "project_id": null,
                "commit_id": null,
                "updated_at": "2026-07-22T00:00:00Z"
            },
            "latest": null,
            "download_url": null,
            "incremental_supported": false
        })),
    )
}

#[tokio::test]
async fn project_bindings_resolve_by_canonical_root_and_persist_across_restarts() {
    let app = Router::new().route("/api/v1/projects/{project_id}", get(accessible_project));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let daemon_root = tempfile::tempdir().unwrap();
    let workspaces = tempfile::tempdir().unwrap();
    let first_root = workspaces.path().join("first");
    let first_nested = first_root.join("packages/app");
    let second_root = workspaces.path().join("second");
    std::fs::create_dir_all(&first_nested).unwrap();
    std::fs::create_dir_all(&second_root).unwrap();

    let mut config = DaemonConfig::for_root(daemon_root.path());
    config.project.server_url = format!("http://{address}/");
    let credential_store = common::TestCredentialStore::new(Some(ServerCredentials {
        server_url: config.project.server_url.clone(),
        access_token: "test-token".to_owned(),
        refresh_token: None,
    }));
    let state = common::initialize_daemon(config.clone(), credential_store.clone()).await;
    let service = DaemonIpcService::new(state);

    let first = service
        .replace_project_binding(DaemonProjectBindingReplaceRequest {
            workspace_root: first_root.display().to_string(),
            project_id: "prj_first".to_owned(),
            expected_revision: None,
        })
        .await
        .unwrap();
    assert_eq!(first.revision, 1);
    assert_eq!(first.server_url, format!("http://{address}"));

    let second = service
        .replace_project_binding(DaemonProjectBindingReplaceRequest {
            workspace_root: second_root.display().to_string(),
            project_id: "prj_second".to_owned(),
            expected_revision: None,
        })
        .await
        .unwrap();
    assert_eq!(second.revision, 1);

    let first_resolution = service.resolve_project_binding(DaemonProjectBindingResolveRequest {
        workspace_path: first_nested.display().to_string(),
    });
    let second_resolution = service.resolve_project_binding(DaemonProjectBindingResolveRequest {
        workspace_path: second_root.display().to_string(),
    });
    let (first_resolution, second_resolution) = tokio::join!(first_resolution, second_resolution);
    assert_eq!(first_resolution.unwrap().project_id, "prj_first");
    assert_eq!(second_resolution.unwrap().project_id, "prj_second");

    let restarted = common::initialize_daemon(config, credential_store).await;
    let persisted = restarted
        .resolve_project_binding(DaemonProjectBindingResolveRequest {
            workspace_path: first_nested.display().to_string(),
        })
        .await
        .unwrap();
    assert_eq!(persisted.project_id, "prj_first");
    assert_eq!(
        persisted.workspace_root,
        std::fs::canonicalize(&first_root)
            .unwrap()
            .display()
            .to_string()
    );

    let error = restarted
        .replace_project_binding(DaemonProjectBindingReplaceRequest {
            workspace_root: first_root.display().to_string(),
            project_id: "prj_other".to_owned(),
            expected_revision: Some(99),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        DaemonError::State {
            code: "project_binding_changed",
            ..
        }
    ));
}

#[tokio::test]
async fn resolving_an_unbound_workspace_reports_project_binding_not_found() {
    let root = tempfile::tempdir().unwrap();
    let workspace = root.path().join("unbound");
    std::fs::create_dir_all(&workspace).unwrap();
    let mut config = DaemonConfig::for_root(root.path().join("daemon"));
    config.project.server_url = "https://app.clumsies.ai".to_owned();
    let state = common::initialize_daemon(config, common::TestCredentialStore::default()).await;
    let error = state
        .resolve_project_binding(DaemonProjectBindingResolveRequest {
            workspace_path: workspace.display().to_string(),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        DaemonError::State {
            code: "project_binding_not_found",
            ..
        }
    ));
}

#[tokio::test]
async fn commit_sync_installs_every_bound_project_independently_of_desktop_selection() {
    let app = Router::new()
        .route("/api/v1/projects/{project_id}", get(accessible_project))
        .route(
            "/api/v1/projects/{project_id}/commit-state",
            get(empty_project_commit_state),
        )
        .route("/api/v1/org/commit-state", get(empty_org_commit_state));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let daemon_root = tempfile::tempdir().unwrap();
    let workspaces = tempfile::tempdir().unwrap();
    let first_root = workspaces.path().join("first");
    let second_root = workspaces.path().join("second");
    std::fs::create_dir_all(&first_root).unwrap();
    std::fs::create_dir_all(&second_root).unwrap();
    let mut config = DaemonConfig::for_root(daemon_root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_desktop_selection".to_owned());
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;

    state
        .replace_project_binding(DaemonProjectBindingReplaceRequest {
            workspace_root: first_root.display().to_string(),
            project_id: "prj_bound_first".to_owned(),
            expected_revision: None,
        })
        .await
        .unwrap();
    state
        .replace_project_binding(DaemonProjectBindingReplaceRequest {
            workspace_root: second_root.display().to_string(),
            project_id: "prj_bound_second".to_owned(),
            expected_revision: None,
        })
        .await
        .unwrap();
    state
        .retry_sync(DaemonSyncRetryRequest {
            channel: SyncRetryChannel::Commits,
        })
        .await
        .unwrap();

    for project_id in ["prj_bound_first", "prj_bound_second"] {
        let cache = state
            .memory_cache(DaemonMemoryCacheRequest {
                project_id: project_id.to_owned(),
            })
            .await
            .unwrap();
        assert_eq!(cache.state, DaemonMemoryCacheState::Ready);
    }
}

#[tokio::test]
async fn keychain_credentials_are_bound_to_the_configured_server() {
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = "https://current.example.com".to_owned();
    config.project.project_id = Some("prj_current".to_owned());
    let credential_store = common::TestCredentialStore::new(Some(ServerCredentials {
        server_url: "https://previous.example.com".to_owned(),
        access_token: "previous-access".to_owned(),
        refresh_token: Some("previous-refresh".to_owned()),
    }));

    let state = common::initialize_daemon(config, credential_store.clone()).await;
    let project_config = state.project_config_status();

    assert_eq!(project_config.server_url, "https://current.example.com");
    assert!(!project_config.has_access_token);
    assert!(!project_config.has_refresh_token);
    assert!(!project_config.ready);
    assert!(credential_store.credentials().is_some());
}

#[tokio::test]
async fn refresh_token_without_access_token_is_rejected_before_persistence() {
    let root = tempfile::tempdir().unwrap();
    let credential_store = common::TestCredentialStore::default();
    let state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;

    let error = state
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: "https://clumsies.example.com".to_owned(),
            project_id: Some("prj_test".to_owned()),
            access_token: None,
            refresh_token: Some("orphan-refresh".to_owned()),
        })
        .await
        .unwrap_err();

    assert!(error.to_string().contains("without access_token"));
    assert!(credential_store.credentials().is_none());
    assert_eq!(state.project_config_status().server_url, "");
}

#[tokio::test]
async fn credential_write_failure_does_not_change_project_metadata_or_runtime_state() {
    let root = tempfile::tempdir().unwrap();
    let credential_store = common::TestCredentialStore::default();
    let state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;
    credential_store.set_fail_writes(true);

    let error = state
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: "https://clumsies.example.com".to_owned(),
            project_id: Some("prj_test".to_owned()),
            access_token: Some("access-secret".to_owned()),
            refresh_token: Some("refresh-secret".to_owned()),
        })
        .await
        .unwrap_err();

    assert!(
        error
            .to_string()
            .contains("injected credential write failure")
    );
    assert!(credential_store.credentials().is_none());
    let project_config = state.project_config_status();
    assert_eq!(project_config.server_url, "");
    assert_eq!(project_config.project_id, None);
    assert!(!project_config.has_access_token);

    let metadata_pool = sqlx::SqlitePool::connect(&format!(
        "sqlite://{}",
        root.path().join("local.db").display()
    ))
    .await
    .unwrap();
    let persisted_config_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM daemon_meta
         WHERE key IN ('project_config_server_url', 'project_config_project_id')",
    )
    .fetch_one(&metadata_pool)
    .await
    .unwrap();
    assert_eq!(persisted_config_count, 0);
    metadata_pool.close().await;
}

#[tokio::test]
async fn sync_retry_uploads_new_local_draft_to_server() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server.url.clone();
    config.project.project_id = Some("prj_default".to_owned());
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
    let pool = sqlx::SqlitePool::connect(&state.local_db_path().display().to_string())
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO cached_commits (
            commit_id, scope, org_id, project_id, tree_id,
            parent_commit_id, version, created_at, payload_json
         ) VALUES ($1, 'project', 'org_test', 'prj_test', 'tree_test',
                   NULL, 1, '2026-07-08T00:00:00Z', '{}')",
    )
    .bind(COMMIT_A)
    .execute(&pool)
    .await
    .unwrap();
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
                    content: context_content("Sync me"),
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
            .content,
        context_content("Remote revision")
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
    assert_eq!(requests[0]["operations"][0]["content"]["kind"], "context");
    assert_eq!(
        requests[0]["operations"][0]["content"]["content"],
        "Sync me"
    );
}

#[tokio::test]
async fn concurrent_explicit_sync_retries_wait_for_the_inflight_sync() {
    let blocking_state = BlockingDraftEventsState {
        started: Arc::new(Notify::new()),
        release: Arc::new(Notify::new()),
        request_count: Arc::new(AtomicUsize::new(0)),
    };
    let app = Router::new()
        .route("/api/v1/draft-events", get(blocking_draft_events))
        .with_state(blocking_state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_retry_lock".to_owned());
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
    let service = DaemonIpcService::new(state);

    let first_service = service.clone();
    let first = tokio::spawn(async move {
        first_service
            .retry_sync(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::Drafts,
            })
            .await
            .unwrap();
    });
    blocking_state.started.notified().await;

    let second_service = service.clone();
    let second = tokio::spawn(async move {
        second_service
            .retry_sync(DaemonSyncRetryRequest {
                channel: SyncRetryChannel::Drafts,
            })
            .await
            .unwrap();
    });
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(!second.is_finished());
    assert_eq!(blocking_state.request_count.load(Ordering::Acquire), 1);

    blocking_state.release.notify_one();
    first.await.unwrap();
    second.await.unwrap();
    assert_eq!(blocking_state.request_count.load(Ordering::Acquire), 2);
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
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
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
async fn server_reconciliation_projection_keeps_lifecycle_separate_from_coordination() {
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
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
    let pool = sqlx::SqlitePool::connect(&state.local_db_path().display().to_string())
        .await
        .unwrap();
    for (commit_id, tree_id) in [(COMMIT_A, "tree_a"), (COMMIT_B, "tree_b")] {
        sqlx::query(
            "INSERT INTO cached_commits (
                commit_id, scope, org_id, project_id, tree_id,
                parent_commit_id, version, created_at, payload_json
             ) VALUES ($1, 'project', 'org_test', 'prj_conflict', $2,
                       NULL, 1, '2026-07-15T00:00:00Z', '{}')",
        )
        .bind(commit_id)
        .bind(tree_id)
        .execute(&pool)
        .await
        .unwrap();
    }
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
    assert_eq!(draft.status, DaemonLocalDraftStatus::Submitted);
    assert_eq!(draft.base_commit_id.as_deref(), Some(COMMIT_A));
    assert_eq!(draft.current_commit_id.as_deref(), Some(COMMIT_B));
    assert_eq!(draft.freshness, daemon::DaemonDraftFreshness::Behind);
    assert_eq!(
        draft.reconciliation,
        daemon::DaemonDraftReconciliationStatus::Conflicts
    );
    assert_eq!(
        draft.reconciliation_candidate_id.as_deref(),
        Some("rcn_conflict")
    );

    let sync = service.sync_status().await.unwrap();
    assert_eq!(sync.behind_draft_count, 1);
    assert_eq!(sync.reconciliation_conflict_count, 1);
    assert_eq!(sync.draft_sync.state, SyncState::Idle);
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
    assert_eq!(resolved.draft.current_commit_id.as_deref(), Some(COMMIT_B));
    assert_eq!(
        resolved.draft.freshness,
        daemon::DaemonDraftFreshness::Current
    );
    assert_eq!(
        resolved.draft.reconciliation,
        daemon::DaemonDraftReconciliationStatus::Unknown
    );
    assert_eq!(resolved.draft.reconciliation_candidate_id, None);
    assert_eq!(resolved.operations.len(), 1);
    assert_eq!(
        resolved.operations[0]
            .operation
            .update
            .as_ref()
            .unwrap()
            .content(),
        Some(&context_content("Resolved content"))
    );
    let sync = service.sync_status().await.unwrap();
    assert_eq!(sync.behind_draft_count, 0);
    assert_eq!(sync.reconciliation_conflict_count, 0);
    assert_eq!(sync.draft_sync.state, SyncState::Idle);
}

#[tokio::test]
async fn queued_draft_syncs_after_project_config_is_set() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let state = common::initialize_daemon(config, common::TestCredentialStore::default()).await;
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
                    content: context_content("sync after config"),
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
    assert_eq!(
        requests[0]["operations"][0]["content"]["content"],
        "sync after config"
    );
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
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
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
                    content: context_content("automatic"),
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
    assert_eq!(
        requests[0]["operations"][0]["content"]["content"],
        "automatic"
    );
    drop(requests);
    worker.abort();
}

#[tokio::test]
async fn transient_server_failure_is_retried_automatically() {
    let server_state = RecoveringServerState {
        available: Arc::new(AtomicBool::new(false)),
        create_request_count: Arc::new(AtomicUsize::new(0)),
    };
    let app = Router::new()
        .route("/api/v1/drafts", post(recovering_create_draft))
        .route("/api/v1/draft-events", get(empty_draft_events))
        .route("/api/v1/org/commit-state", get(fake_org_commit_state))
        .route(
            "/api/v1/projects/{project_id}/commit-state",
            get(fake_project_commit_state),
        )
        .with_state(server_state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_recovery".to_owned());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_millis(50);
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
    let worker = state.start_sync_worker().unwrap();
    let service = DaemonIpcService::new(state);

    let stored = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_recovery".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/offline.md".to_owned(),
                    content: context_content("Saved while Server is unavailable"),
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

    let retrying = wait_for_operation_status(
        &service,
        &stored.draft_id,
        DraftOperationSyncStatus::Retrying,
    )
    .await;
    assert_eq!(retrying.draft.pending_operation_count, 1);
    let status = service.sync_status().await.unwrap();
    assert_eq!(status.draft_sync.state, SyncState::Retrying);
    assert_eq!(status.pending_operation_count, 1);
    assert_eq!(status.failed_operation_count, 0);
    assert!(status.draft_sync.last_attempt_at.is_some());
    assert!(status.draft_sync.last_error.is_some());

    server_state.available.store(true, Ordering::Release);
    let synced =
        wait_for_operation_status(&service, &stored.draft_id, DraftOperationSyncStatus::Synced)
            .await;
    assert_eq!(synced.draft.pending_operation_count, 0);
    assert_eq!(synced.draft.failed_operation_count, 0);
    assert!(server_state.create_request_count.load(Ordering::Acquire) >= 2);
    assert_eq!(
        service.sync_status().await.unwrap().draft_sync.state,
        SyncState::Idle
    );
    worker.abort();
}

#[tokio::test]
async fn successful_new_draft_does_not_hide_an_existing_retrying_operation() {
    let server_state = RecoveringServerState {
        available: Arc::new(AtomicBool::new(true)),
        create_request_count: Arc::new(AtomicUsize::new(0)),
    };
    let app = Router::new()
        .route("/api/v1/drafts", post(recovering_create_draft))
        .route("/api/v1/draft-events", get(empty_draft_events))
        .route("/api/v1/org/commit-state", get(fake_org_commit_state))
        .route(
            "/api/v1/projects/{project_id}/commit-state",
            get(fake_project_commit_state),
        )
        .with_state(server_state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_retrying".to_owned());
    config.sync.enabled = true;
    config.sync.interval = Duration::from_secs(60);
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
    let worker = state.start_sync_worker().unwrap();
    let service = DaemonIpcService::new(state.clone());

    let mut baseline_last_success = None;
    for _ in 0..100 {
        if let Some(last_success) = service
            .sync_status()
            .await
            .unwrap()
            .draft_sync
            .last_success_at
        {
            baseline_last_success = Some(last_success);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let baseline_last_success = baseline_last_success.expect("initial sync cycle did not complete");

    let pool = sqlx::SqlitePool::connect(&state.local_db_path().display().to_string())
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO local_drafts (
            draft_id, project_id, resource_scope, resource_kind, status
         ) VALUES ('draft_retrying', 'prj_retrying', 'project', 'context', 'open')",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO local_draft_operations (
            local_operation_id, draft_id, resource_kind, operation_json, source, sync_status,
            last_error
         ) VALUES (
            'operation_retrying', 'draft_retrying', 'context', '{}', 'desktop', 'retrying',
            'Server unavailable'
         )",
    )
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;
    tokio::time::sleep(Duration::from_millis(20)).await;

    let stored = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_retrying".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/synced-while-retrying.md".to_owned(),
                    content: context_content("This operation can sync"),
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
    wait_for_operation_status(&service, &stored.draft_id, DraftOperationSyncStatus::Synced).await;

    let status = service.sync_status().await.unwrap();
    assert_eq!(status.draft_sync.state, SyncState::Retrying);
    assert_eq!(status.pending_operation_count, 1);
    assert_eq!(
        status.draft_sync.last_success_at.as_deref(),
        Some(baseline_last_success.as_str())
    );
    worker.abort();
}

#[tokio::test]
async fn daemon_restart_requeues_an_interrupted_operation() {
    let root = tempfile::tempdir().unwrap();
    let credential_store = common::TestCredentialStore::default();
    let state = common::initialize_daemon(
        DaemonConfig::for_root(root.path()),
        credential_store.clone(),
    )
    .await;
    let service = DaemonIpcService::new(state.clone());
    let stored = service
        .store_draft_operation(DaemonDraftOperationRequest {
            draft_id: None,
            base_commit_id: None,
            project_id: "prj_restart".to_owned(),
            scope: DaemonDraftScope::Project,
            resource: DaemonDraftResourceKind::Context,
            op: DaemonDraftOperation {
                create: Some(DaemonCreateDraftOperation {
                    path: "context/restart.md".to_owned(),
                    content: context_content("Recover after process exit"),
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
    let pool = sqlx::SqlitePool::connect(&state.local_db_path().display().to_string())
        .await
        .unwrap();
    sqlx::query(
        "UPDATE local_draft_operations SET sync_status = 'syncing' WHERE local_operation_id = $1",
    )
    .bind(&stored.local_operation_id)
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;
    drop(service);
    drop(state);

    let restarted =
        common::initialize_daemon(DaemonConfig::for_root(root.path()), credential_store).await;
    let detail = DaemonIpcService::new(restarted)
        .get_draft(&stored.draft_id)
        .await
        .unwrap();
    assert_eq!(
        detail.operations[0].sync_status,
        DraftOperationSyncStatus::Queued
    );
    assert_eq!(detail.draft.pending_operation_count, 1);
    assert_eq!(detail.draft.failed_operation_count, 0);
}

#[tokio::test]
async fn server_proxy_uses_stale_cache_only_for_read_failures() {
    let proxy_state = CachedProxyState {
        unavailable: Arc::new(AtomicBool::new(false)),
    };
    let app = Router::new()
        .route(
            "/api/v1/cache-probe",
            get(cached_proxy_get).post(cached_proxy_post),
        )
        .route("/api/v1/missing-probe", get(cached_missing_get))
        .with_state(proxy_state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = format!("http://{address}");
    config.project.project_id = Some("prj_cache".to_owned());
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
    let get_request = DaemonServerRequest {
        method: "GET".to_owned(),
        path: "/api/v1/cache-probe".to_owned(),
        headers: BTreeMap::new(),
        body: None,
    };

    let live = state.server_request(get_request.clone()).await.unwrap();
    assert_eq!(live.status, 200);
    assert_eq!(live.body, r#"{"source":"live"}"#);
    assert_eq!(live.headers.get("x-clumsies-cache"), None);

    let missing_request = DaemonServerRequest {
        method: "GET".to_owned(),
        path: "/api/v1/missing-probe".to_owned(),
        headers: BTreeMap::new(),
        body: None,
    };
    let missing = state.server_request(missing_request.clone()).await.unwrap();
    assert_eq!(missing.status, 404);
    assert_eq!(missing.headers.get("x-clumsies-cache"), None);

    proxy_state.unavailable.store(true, Ordering::Release);
    let cached_after_503 = state.server_request(get_request.clone()).await.unwrap();
    assert_eq!(cached_after_503.status, 200);
    assert_eq!(cached_after_503.body, live.body);
    assert_eq!(
        cached_after_503
            .headers
            .get("x-clumsies-cache")
            .map(String::as_str),
        Some("stale")
    );
    let cached_missing = state.server_request(missing_request).await.unwrap();
    assert_eq!(cached_missing.status, 404);
    assert_eq!(
        cached_missing
            .headers
            .get("x-clumsies-cache")
            .map(String::as_str),
        Some("stale")
    );

    let write = state
        .server_request(DaemonServerRequest {
            method: "POST".to_owned(),
            path: "/api/v1/cache-probe".to_owned(),
            headers: BTreeMap::new(),
            body: Some("{}".to_owned()),
        })
        .await
        .unwrap();
    assert_eq!(write.status, 503);
    assert_eq!(write.headers.get("x-clumsies-cache"), None);

    server.abort();
    tokio::time::sleep(Duration::from_millis(20)).await;
    let cached_after_disconnect = state.server_request(get_request.clone()).await.unwrap();
    assert_eq!(cached_after_disconnect.status, 200);
    assert_eq!(
        cached_after_disconnect
            .headers
            .get("x-clumsies-cache")
            .map(String::as_str),
        Some("stale")
    );

    state
        .replace_project_config(DaemonProjectConfigUpdateRequest {
            server_url: format!("http://{address}"),
            project_id: Some("prj_cache".to_owned()),
            access_token: Some("replacement-token".to_owned()),
            refresh_token: None,
        })
        .await
        .unwrap();
    assert!(state.server_request(get_request).await.is_err());
}

#[tokio::test]
async fn sync_retry_uploads_later_new_resource_edits_to_the_same_draft() {
    let server = FakeServer::start().await;
    let root = tempfile::tempdir().unwrap();
    let mut config = DaemonConfig::for_root(root.path());
    config.project.server_url = server.url.clone();
    config.project.project_id = Some("prj_test".to_owned());
    let (state, _) = common::initialize_authenticated_daemon(config, "test-token", None).await;
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
                    content: context_content("one"),
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
                    content: context_content("two"),
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
    assert_eq!(
        batches[0]["operations"][0]["operation"]["content"]["content"],
        "two"
    );
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
                    content: rule_content("Rule"),
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
    let (state, _) =
        common::initialize_authenticated_daemon(config, "fake-access-token", None).await;
    let service = DaemonIpcService::new(state);

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
    assert_eq!(installed.state, DaemonMemoryCacheState::Ready);
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
    assert_eq!(after_failure.state, DaemonMemoryCacheState::Ready);
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
    assert_eq!(corrupted.state, DaemonMemoryCacheState::GenerationCorrupt);
    assert_eq!(corrupted.commit_id.as_deref(), Some("commit-valid"));
    assert_eq!(corrupted.root_path, None);
    let corrupt_activation = service
        .activate_memory(ActivateMemoryRequest {
            project_id: "prj_atomic".to_owned(),
            query: "authority".to_owned(),
            state: None,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        corrupt_activation,
        DaemonError::State {
            code: "commit_generation_corrupt",
            ..
        }
    ));

    std::fs::remove_dir_all(&installed_root).unwrap();
    let missing = service
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: "prj_atomic".to_owned(),
        })
        .await
        .unwrap();
    assert_eq!(missing.state, DaemonMemoryCacheState::GenerationMissing);
    let missing_activation = service
        .activate_memory(ActivateMemoryRequest {
            project_id: "prj_atomic".to_owned(),
            query: "authority".to_owned(),
            state: None,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        missing_activation,
        DaemonError::State {
            code: "commit_generation_missing",
            ..
        }
    ));
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

async fn wait_for_operation_status(
    service: &DaemonIpcService,
    draft_id: &str,
    expected: DraftOperationSyncStatus,
) -> daemon::DaemonDraftDetail {
    for _ in 0..100 {
        let detail = service.get_draft(draft_id).await.unwrap();
        if detail
            .operations
            .iter()
            .any(|operation| operation.sync_status == expected)
        {
            return detail;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for draft operation status {expected:?}");
}

#[derive(Clone)]
struct RecoveringServerState {
    available: Arc<AtomicBool>,
    create_request_count: Arc<AtomicUsize>,
}

async fn recovering_create_draft(
    axum::extract::State(state): axum::extract::State<RecoveringServerState>,
    Json(_body): Json<serde_json::Value>,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    state.create_request_count.fetch_add(1, Ordering::AcqRel);
    if !state.available.load(Ordering::Acquire) {
        return (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "temporarily unavailable" })),
        )
            .into_response();
    }
    Json(json!({
        "draft": {
            "draft_id": "drf_recovered",
            "version": 1
        }
    }))
    .into_response()
}

async fn empty_draft_events() -> Json<serde_json::Value> {
    Json(json!({
        "events": [],
        "next_cursor": null,
        "has_more": false
    }))
}

#[derive(Clone)]
struct CachedProxyState {
    unavailable: Arc<AtomicBool>,
}

async fn cached_proxy_get(
    axum::extract::State(state): axum::extract::State<CachedProxyState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    if state.unavailable.load(Ordering::Acquire) {
        return (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "temporarily unavailable" })),
        )
            .into_response();
    }
    Json(json!({ "source": "live" })).into_response()
}

async fn cached_proxy_post() -> axum::response::Response {
    use axum::response::IntoResponse;

    (
        axum::http::StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({ "error": "temporarily unavailable" })),
    )
        .into_response()
}

async fn cached_missing_get(
    axum::extract::State(state): axum::extract::State<CachedProxyState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    if state.unavailable.load(Ordering::Acquire) {
        return (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "temporarily unavailable" })),
        )
            .into_response();
    }
    (
        axum::http::StatusCode::NOT_FOUND,
        Json(json!({ "error": "not found" })),
    )
        .into_response()
}

struct FakeServer {
    url: String,
    create_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    batch_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    delete_requests: Arc<Mutex<Vec<(String, String)>>>,
}

#[derive(Clone)]
struct BlockingDraftEventsState {
    started: Arc<Notify>,
    release: Arc<Notify>,
    request_count: Arc<AtomicUsize>,
}

async fn blocking_draft_events(
    axum::extract::State(state): axum::extract::State<BlockingDraftEventsState>,
) -> Json<serde_json::Value> {
    let request_index = state.request_count.fetch_add(1, Ordering::AcqRel);
    if request_index == 0 {
        state.started.notify_one();
        state.release.notified().await;
    }
    Json(json!({
        "events": [],
        "next_cursor": null,
        "has_more": false
    }))
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
            .route(
                "/api/v1/draft-events",
                get(fake_list_draft_events_after_create),
            )
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
                    "content": {
                        "kind": "context",
                        "content": "Remote base"
                    },
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
            "coordination": {
                "current_commit_id": create_request["base_commit_id"],
                "freshness": "current",
                "reconciliation": "unknown",
                "candidate_id": null
            },
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
                "content": initial_operation["content"],
                "new_path": initial_operation["new_path"],
                "created_at": "2026-07-08T00:00:00Z"
            },
            {
                "operation_id": "dop_remote",
                "action": "create",
                "resource": create_request["resource"],
                "content": {
                    "kind": "context",
                    "content": "Remote revision"
                },
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
            "coordination": {
                "current_commit_id": null,
                "freshness": "current",
                "reconciliation": "unknown",
                "candidate_id": null
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
    fake_draft_events_response(query)
}

async fn fake_list_draft_events_after_create(
    axum::extract::State(state): axum::extract::State<FakeServerState>,
    axum::extract::Query(query): axum::extract::Query<FakeDraftEventQuery>,
) -> Json<serde_json::Value> {
    if state.create_requests.lock().unwrap().is_empty() {
        return Json(json!({
            "events": [],
            "next_cursor": null,
            "has_more": false
        }));
    }
    fake_draft_events_response(query)
}

fn fake_draft_events_response(query: FakeDraftEventQuery) -> Json<serde_json::Value> {
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
                    "event_type": "updated",
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
                "coordination": {
                    "current_commit_id": COMMIT_B,
                    "freshness": "current",
                    "reconciliation": "unknown",
                    "candidate_id": null
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
                    "content": {
                        "kind": "context",
                        "content": "Resolved content"
                    },
                    "new_path": null,
                    "created_at": "2026-07-15T00:02:00Z"
                }
            ]
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
            "coordination": {
                "current_commit_id": COMMIT_B,
                "freshness": "behind",
                "reconciliation": "conflicts",
                "candidate_id": "rcn_conflict"
            },
            "status": "submitted",
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
                "content": {
                    "kind": "context",
                    "content": "Draft content"
                },
                "new_path": null,
                "created_at": "2026-07-15T00:00:30Z"
            }
        ]
    }))
}
