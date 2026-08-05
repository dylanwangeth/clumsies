use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteRow, SqliteSynchronous,
};
use sqlx::{Row, SqlitePool};
use thiserror::Error;
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;
use uuid::Uuid;

mod agent_adapter;
mod commit_sync;
pub mod config;
mod credentials;
mod draft;
mod ipc;
mod migration;
mod project_storage;
mod retrieval_history;
mod search;
mod server_client;
mod state;
mod types;
mod util;

pub use agent_adapter::{
    DaemonProjectAgentAdapter, DaemonProjectAgentAdapterInstallRequest,
    DaemonProjectAgentAdapterListRequest, DaemonProjectAgentAdapterListResponse,
    DaemonProjectAgentAdapterRemoveRequest, DaemonProjectAgentAdapterRemoveResponse,
    ProjectAgentAdapterKind,
};
pub use commit_sync::{
    DaemonMemoryCacheRequest, DaemonMemoryCacheState, DaemonMemoryCacheStatus,
    DaemonProjectCheckout, DaemonProjectCheckoutRequest, DaemonProjectCheckoutResource,
};
pub use config::{
    CURRENT_LOCAL_SCHEMA_VERSION, DAEMON_AGENT_LABEL, DAEMON_MACH_SERVICE_NAME, DaemonConfig,
    IDENTIFIER_NAMESPACE, LaunchAgentConfig, LaunchAgentController, ProjectConfig, SyncConfig,
};
pub(crate) use config::{
    META_DRAFT_EVENTS_CURSOR, META_DRAFT_SYNC_LAST_ATTEMPT_AT, META_DRAFT_SYNC_LAST_SUCCESS_AT,
    META_MEMORY_CACHE_RESET_REQUIRED, RuntimeProjectConfig,
};
pub use credentials::{
    CredentialStore, CredentialStoreError, KEYCHAIN_ACCOUNT, ServerCredentials,
    SystemCredentialStore,
};
pub(crate) use draft::{
    LocalDraftResolutionInput, drain_draft_queue, list_local_drafts, load_local_draft_detail,
    load_sync_status, pull_draft_events, queue_retrying_operations, recover_interrupted_operations,
    resolve_local_draft,
};
pub use ipc::{DaemonIpcClient, DaemonIpcServer};
pub(crate) use migration::{
    connect_local_db, current_schema_version, load_meta_value, load_or_create_installation_id,
    load_project_config, load_server_credentials, migrate_local_db, prepare_directories,
    replace_server_credentials, reset_memory_cache_if_required, save_project_metadata,
    upsert_meta_timestamp, upsert_meta_value,
};
pub use project_storage::{
    DaemonProjectCacheClearRequest, DaemonProjectStorage, DaemonProjectStorageAvailability,
    DaemonProjectStorageMode, DaemonProjectStorageMove, DaemonProjectStorageMoveRequest,
    DaemonProjectStorageMoveState, DaemonProjectStorageReplaceRequest, DaemonProjectStorageRequest,
    DaemonProjectStorageResetRequest,
};
pub use retrieval_history::{
    ClearRetrievalRunsRequest, ClearRetrievalRunsResponse, CreateEvaluationCaseRequest,
    EvaluationCase, EvaluationCaseDetail, EvaluationCaseStatus, EvaluationEvidence,
    EvaluationEvidenceInput, EvaluationEvidenceSuggestion, ExportEvaluationSetRequest,
    ExportEvaluationSetResponse, ResolveEvaluationCaseRequest, RetrievalBenchmarkMetrics,
    RetrievalBenchmarkReport, RetrievalBenchmarkVariant, RetrievalCandidate, RetrievalDeltaAction,
    RetrievalExclusionReason, RetrievalFailureStage, RetrievalRun, RetrievalRunDetail,
    RetrievalRunListRequest, RetrievalRunListResponse, RetrievalRunRequest, RetrievalRunStatus,
    RetrievalStageLatencies,
};
pub use search::{
    ActivateMemoryRequest, ActivateMemoryResponse, ActivationAction, ActivationFragment,
    ActivationRemoval, LoadMemoryRequest, LoadMemoryResponse, LoadedMemoryResource, MemoryKind,
    SearchIndexProjectRequest, SearchIndexStatus, SearchModelStatus, SourceLocator, SourceScope,
};
pub(crate) use server_client::{
    clear_server_response_cache, decode_server_json, delete_server_json, ensure_server_success,
    execute_authenticated_server_request, filter_proxy_request_headers,
    filter_proxy_response_headers, get_server_json, is_retryable_http_status,
    load_cached_server_response, post_server_json, save_cached_server_response,
    validate_server_proxy_path,
};
pub(crate) use state::DaemonInner;
pub use state::DaemonIpcService;
pub use state::DaemonState;
pub use types::{
    ApiError, DaemonBootstrapStatus, DaemonDraftContent, DaemonDraftDetail,
    DaemonDraftDetailRequest, DaemonDraftFreshness, DaemonDraftListQuery, DaemonDraftListResponse,
    DaemonDraftOperation, DaemonDraftOperationRecordSource, DaemonDraftOperationRequest,
    DaemonDraftOperationResponse, DaemonDraftOperationSource, DaemonDraftReconciliationStatus,
    DaemonDraftResourceKind, DaemonDraftScope, DaemonDraftSummary, DaemonError, DaemonHealth,
    DaemonIpcEndpoint, DaemonIpcRequest, DaemonIpcResponse, DaemonIpcTransport,
    DaemonLocalDraftStatus, DaemonMcpStatus, DaemonProjectBinding, DaemonProjectBindingListRequest,
    DaemonProjectBindingListResponse, DaemonProjectBindingRemoveRequest,
    DaemonProjectBindingRemoveResponse, DaemonProjectBindingReplaceRequest,
    DaemonProjectBindingResolveRequest, DaemonProjectConfig, DaemonProjectConfigUpdateRequest,
    DaemonProjectSelectionRequest, DaemonRetryResponse, DaemonServerRequest, DaemonServerResponse,
    DaemonSyncRetryRequest, DaemonSyncStatus, DraftOperationSyncStatus, ErrorEnvelope,
    LaunchAgentRuntimeStatus, LocalDbStatus, McpAdapterStatus, SyncChannelStatus, SyncRetryChannel,
    SyncState,
};
pub(crate) use types::{
    DaemonContentDraftUpdate, DaemonCreateDraftOperation, DaemonDeleteDraftOperation,
    DaemonDiscardDraftOperation, DaemonLocalDraftOperation, DaemonRenameDraftOperation,
    DaemonTextDraftUpdate, DaemonTextReplacement, DaemonUpdateDraftOperation, DraftSyncError,
    ProjectConfigReadiness, QueuedDraftOperation, ServerCreateDraftRequest,
    ServerDraftCoordination, ServerDraftEvent, ServerDraftEventListResponse,
    ServerDraftMutationResponse, ServerDraftOperationAction, ServerDraftOperationBatchItem,
    ServerDraftOperationBatchRequest, ServerDraftOperationBatchResponse, ServerDraftOperationInput,
    ServerDraftProjection, ServerDraftProjectionDetail, ServerDraftProjectionOperation,
    ServerDraftResourceRef, ServerDraftVersion, ServerTokenRefreshResponse,
    project_binding_from_row,
};
pub(crate) use util::is_normalized_relative_path;
use util::{
    apply_exact_text_replacements, canonical_server_url, canonical_workspace_directory,
    memory_kind_matches_resource, non_empty_string, validate_draft_resource_path,
};
