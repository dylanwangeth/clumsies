mod chunker;
pub(crate) mod models;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use pulldown_cmark::{Event, Options, Parser, Tag};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{Row, Sqlite, SqlitePool, Transaction};

use self::chunker::build_units;
use self::models::{FastEmbedSearchModels, SearchModelRuntimeStatus, SearchModels};
use super::{
    DaemonDraftContent, DaemonDraftOperation, DaemonError, DaemonMemoryCacheRequest, DaemonState,
};

const SEARCH_SCHEMA_VERSION: i64 = 1;
const PARSER_VERSION: &str = "markdown-units.v1";
const RANKING_CONFIG_VERSION: &str = "agent_activation.v1";
const BM25_TOP_K: usize = 60;
const VECTOR_TOP_K: usize = 60;
const RRF_CONSTANT: f32 = 60.0;
const RRF_CANDIDATES: usize = 40;
const RERANK_CANDIDATES: usize = 24;
const FINAL_FRAGMENTS: usize = 12;
const PER_RESOURCE_LIMIT: usize = 2;
const FRAGMENT_TOKEN_BUDGET: usize = 2400;
const MAX_ACTIVATION_IDENTITIES: usize = 256;
const MAX_ACTIVATION_STATE_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    Context,
    Rule,
    Workflow,
}

impl MemoryKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Context => "context",
            Self::Rule => "rule",
            Self::Workflow => "workflow",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SourceScope {
    Org,
    Project,
}

impl SourceScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::Org => "org",
            Self::Project => "project",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SourceLocator {
    MarkdownSpan {
        start_byte: usize,
        end_byte: usize,
        heading_path: Vec<String>,
    },
}

impl SourceLocator {
    #[cfg(test)]
    pub(crate) fn start_byte(&self) -> usize {
        match self {
            Self::MarkdownSpan { start_byte, .. } => *start_byte,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceResource {
    pub(crate) resource_id: String,
    pub(crate) project_id: String,
    pub(crate) scope: SourceScope,
    pub(crate) kind: MemoryKind,
    pub(crate) path: String,
    pub(crate) title: String,
    pub(crate) content: String,
    pub(crate) content_hash: String,
    pub(crate) source_commit_id: Option<String>,
    pub(crate) draft_id: Option<String>,
    pub(crate) draft_revision: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RetrievalUnit {
    pub(crate) unit_key: String,
    pub(crate) resource_id: String,
    pub(crate) ordinal: usize,
    pub(crate) heading_path: Vec<String>,
    pub(crate) locator: SourceLocator,
    pub(crate) text: String,
    pub(crate) text_hash: String,
    pub(crate) token_count: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ActivateMemoryRequest {
    pub project_id: String,
    pub query: String,
    #[serde(default)]
    pub state: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct ActivateMemoryResponse {
    pub index_revision: String,
    pub profile: String,
    pub next_state: String,
    pub fragments: Vec<ActivationFragment>,
    pub removed: Vec<ActivationRemoval>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ActivationAction {
    Add,
    Replace,
    Reuse,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct ActivationFragment {
    pub action: ActivationAction,
    pub unit_key: String,
    pub content_hash: String,
    pub resource_id: String,
    pub scope: SourceScope,
    pub kind: MemoryKind,
    pub path: String,
    pub heading_path: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ActivationRemoval {
    pub unit_key: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct LoadMemoryRequest {
    pub project_id: String,
    pub ids: Vec<String>,
    #[serde(default)]
    pub known_hashes: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct LoadMemoryResponse {
    pub resources: Vec<LoadedMemoryResource>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct LoadedMemoryResource {
    pub resource_id: String,
    pub scope: SourceScope,
    pub kind: MemoryKind,
    pub path: String,
    pub title: String,
    pub content_hash: String,
    pub changed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct SearchIndexProjectRequest {
    pub project_id: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SearchModelStatus {
    Missing,
    Ready,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct SearchIndexStatus {
    pub project_id: String,
    pub effective_hash: String,
    pub active_revision: Option<String>,
    pub active_effective_hash: Option<String>,
    pub ready: bool,
    pub model_status: SearchModelStatus,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug)]
struct EffectiveMemory {
    project_id: String,
    effective_hash: String,
    resources: Vec<SourceResource>,
}

#[derive(Clone, Debug)]
struct EffectiveResource {
    source: SourceResource,
    rule: Option<RuleFields>,
}

#[derive(Clone, Debug, Deserialize)]
struct RuleEnvelope {
    format: String,
    content: RuleFields,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RuleFields {
    name: String,
    applies_when: String,
    constraint: String,
    tags: Vec<String>,
}

#[derive(Debug)]
pub(crate) struct SearchFailure {
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

impl SearchFailure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub(crate) fn model(message: impl Into<String>) -> Self {
        Self::new("search_model_unavailable", message)
    }

    pub(crate) fn vector(message: impl Into<String>) -> Self {
        Self::new("search_vector_corrupt", message)
    }

    fn invalid_state(message: impl Into<String>) -> Self {
        Self::new("invalid_activation_state", message)
    }

    fn not_ready(message: impl Into<String>) -> Self {
        Self::new("search_index_not_ready", message)
    }

    fn generation_changed(message: impl Into<String>) -> Self {
        Self::new("search_generation_changed", message)
    }

    fn resource_not_found(message: impl Into<String>) -> Self {
        Self::new("memory_resource_not_found", message)
    }

    fn failed(message: impl Into<String>) -> Self {
        Self::new("search_index_failed", message)
    }
}

impl From<SearchFailure> for DaemonError {
    fn from(error: SearchFailure) -> Self {
        Self::Search {
            code: error.code.to_owned(),
            message: error.message,
        }
    }
}

pub(crate) fn production_models(cache_dir: PathBuf) -> Arc<dyn SearchModels> {
    Arc::new(FastEmbedSearchModels::new(cache_dir.join("models")))
}

pub(crate) async fn migrate(pool: &SqlitePool) -> Result<(), DaemonError> {
    let existing: Option<String> =
        sqlx::query_scalar("SELECT value FROM daemon_meta WHERE key = 'search_schema_version'")
            .fetch_optional(pool)
            .await?;
    let version = existing.and_then(|value| value.parse::<i64>().ok());
    if version != Some(SEARCH_SCHEMA_VERSION) {
        let mut tx = pool.begin().await?;
        sqlx::query("DROP TABLE IF EXISTS search_units_fts")
            .execute(&mut *tx)
            .await?;
        sqlx::query("DROP TABLE IF EXISTS search_heads")
            .execute(&mut *tx)
            .await?;
        sqlx::query("DROP TABLE IF EXISTS search_units")
            .execute(&mut *tx)
            .await?;
        sqlx::query("DROP TABLE IF EXISTS search_resources")
            .execute(&mut *tx)
            .await?;
        sqlx::query("DROP TABLE IF EXISTS search_revisions")
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
    }

    sqlx::query(
        "CREATE TABLE IF NOT EXISTS search_revisions (
            revision_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            effective_hash TEXT NOT NULL,
            model_revision TEXT NOT NULL,
            parser_version TEXT NOT NULL,
            ranking_version TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('building', 'ready', 'failed')),
            last_error TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            ready_at TEXT
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS search_resources (
            revision_id TEXT NOT NULL REFERENCES search_revisions(revision_id) ON DELETE CASCADE,
            resource_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
            kind TEXT NOT NULL CHECK (kind IN ('context', 'rule', 'workflow')),
            path TEXT NOT NULL,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            source_commit_id TEXT,
            draft_id TEXT,
            draft_revision TEXT,
            PRIMARY KEY (revision_id, resource_id)
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS search_units (
            unit_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            revision_id TEXT NOT NULL REFERENCES search_revisions(revision_id) ON DELETE CASCADE,
            unit_key TEXT NOT NULL,
            resource_id TEXT NOT NULL,
            ordinal BIGINT NOT NULL,
            heading_path_json TEXT NOT NULL,
            locator_json TEXT NOT NULL,
            text TEXT NOT NULL,
            text_hash TEXT NOT NULL,
            token_count BIGINT NOT NULL,
            vector BLOB NOT NULL,
            UNIQUE (revision_id, unit_key),
            FOREIGN KEY (revision_id, resource_id)
                REFERENCES search_resources(revision_id, resource_id) ON DELETE CASCADE
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE INDEX IF NOT EXISTS idx_search_units_revision
         ON search_units (revision_id, unit_key)",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE VIRTUAL TABLE IF NOT EXISTS search_units_fts USING fts5(
            revision_id UNINDEXED,
            unit_key UNINDEXED,
            path,
            title,
            heading,
            body,
            tokenize = 'trigram case_sensitive 0'
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS search_heads (
            project_id TEXT PRIMARY KEY,
            revision_id TEXT NOT NULL REFERENCES search_revisions(revision_id)
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "INSERT INTO daemon_meta (key, value)
         VALUES ('search_schema_version', $1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .bind(SEARCH_SCHEMA_VERSION.to_string())
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn activate_memory(
    state: &DaemonState,
    request: ActivateMemoryRequest,
) -> Result<ActivateMemoryResponse, DaemonError> {
    let query = request.query.trim();
    if request.project_id.trim().is_empty() || query.is_empty() {
        return Err(DaemonError::InvalidRequest(
            "project_id and a non-empty query are required".to_owned(),
        ));
    }
    let previous_state = decode_activation_state(request.state.as_deref())?;
    let _guard = state.inner.search_lock.lock().await;
    let effective = load_effective_memory(state, &request.project_id).await?;
    let revision_id = ensure_index(state, &effective).await?;
    query_index(state, &revision_id, query, previous_state).await
}

pub(crate) async fn load_memory(
    state: &DaemonState,
    request: LoadMemoryRequest,
) -> Result<LoadMemoryResponse, DaemonError> {
    if request.project_id.trim().is_empty() || request.ids.is_empty() {
        return Err(DaemonError::InvalidRequest(
            "project_id and at least one memory id or path are required".to_owned(),
        ));
    }
    let effective = load_effective_memory(state, &request.project_id).await?;
    let by_id = effective
        .resources
        .iter()
        .map(|resource| (resource.resource_id.as_str(), resource))
        .collect::<HashMap<_, _>>();
    let by_path = effective
        .resources
        .iter()
        .map(|resource| (resource.path.as_str(), resource))
        .collect::<HashMap<_, _>>();
    let mut seen = HashSet::new();
    let mut resources = Vec::new();
    for requested in &request.ids {
        let resource = by_id
            .get(requested.as_str())
            .or_else(|| by_path.get(requested.as_str()))
            .copied()
            .ok_or_else(|| {
                SearchFailure::resource_not_found(format!(
                    "memory resource {requested} is not present in the current effective view"
                ))
            })?;
        if !seen.insert(resource.resource_id.clone()) {
            continue;
        }
        let known_hash = request
            .known_hashes
            .get(&resource.resource_id)
            .or_else(|| request.known_hashes.get(requested));
        let changed = known_hash != Some(&resource.content_hash);
        resources.push(LoadedMemoryResource {
            resource_id: resource.resource_id.clone(),
            scope: resource.scope,
            kind: resource.kind,
            path: resource.path.clone(),
            title: resource.title.clone(),
            content_hash: resource.content_hash.clone(),
            changed,
            content: changed.then(|| resource.content.clone()),
        });
    }
    Ok(LoadMemoryResponse { resources })
}

pub(crate) async fn search_index_status(
    state: &DaemonState,
    request: SearchIndexProjectRequest,
) -> Result<SearchIndexStatus, DaemonError> {
    let effective = load_effective_memory(state, &request.project_id).await?;
    let row = sqlx::query(
        "SELECT r.revision_id, r.effective_hash, r.status, r.last_error
         FROM search_heads h
         JOIN search_revisions r ON r.revision_id = h.revision_id
         WHERE h.project_id = $1",
    )
    .bind(&request.project_id)
    .fetch_optional(&state.inner.pool)
    .await?;
    let (active_revision, active_effective_hash, revision_ready, last_error) = match row {
        Some(row) => {
            let status: String = row.try_get("status")?;
            (
                Some(row.try_get("revision_id")?),
                Some(row.try_get("effective_hash")?),
                status == "ready",
                row.try_get("last_error")?,
            )
        }
        None => (None, None, false, None),
    };
    let model_status = match state.inner.search_models.status() {
        SearchModelRuntimeStatus::Missing => SearchModelStatus::Missing,
        SearchModelRuntimeStatus::Ready => SearchModelStatus::Ready,
        SearchModelRuntimeStatus::Failed => SearchModelStatus::Failed,
    };
    let current_failure: Option<String> = sqlx::query_scalar(
        "SELECT last_error
         FROM search_revisions
         WHERE project_id = $1 AND effective_hash = $2 AND status = 'failed'
         ORDER BY created_at DESC
         LIMIT 1",
    )
    .bind(&request.project_id)
    .bind(&effective.effective_hash)
    .fetch_optional(&state.inner.pool)
    .await?
    .flatten();
    let ready = revision_ready
        && active_effective_hash.as_deref() == Some(effective.effective_hash.as_str());
    Ok(SearchIndexStatus {
        project_id: request.project_id,
        effective_hash: effective.effective_hash,
        active_revision,
        active_effective_hash,
        ready,
        model_status,
        last_error: current_failure.or(last_error),
    })
}

pub(crate) async fn rebuild_search_index(
    state: &DaemonState,
    request: SearchIndexProjectRequest,
) -> Result<SearchIndexStatus, DaemonError> {
    let _guard = state.inner.search_lock.lock().await;
    delete_project_index(&state.inner.pool, &request.project_id).await?;
    let effective = load_effective_memory(state, &request.project_id).await?;
    ensure_index(state, &effective).await?;
    drop(_guard);
    search_index_status(state, request).await
}

#[derive(Deserialize)]
struct CachedCommitPayload {
    commit: CachedCommit,
    tree: CachedTree,
    blobs: Vec<CachedBlob>,
}

#[derive(Deserialize)]
struct CachedCommit {
    commit_id: String,
}

#[derive(Deserialize)]
struct CachedTree {
    entries: Vec<CachedTreeEntry>,
}

#[derive(Deserialize)]
struct CachedTreeEntry {
    id: String,
    #[serde(rename = "type")]
    kind: CachedMemoryKind,
    scope: CachedScope,
    path: Option<String>,
    blob_id: String,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum CachedMemoryKind {
    Context,
    Rule,
    Workflow,
    Metaprompt,
    ProjectOrgSelection,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum CachedScope {
    Org,
    Project,
    Daemon,
}

#[derive(Deserialize)]
struct CachedBlob {
    blob_id: String,
    content: String,
}

#[derive(Debug)]
struct DraftOverlay {
    draft_id: String,
    scope: SourceScope,
    kind: Option<MemoryKind>,
    target_id: Option<String>,
    updated_at: String,
    operations: Vec<(i64, String, DaemonDraftOperation)>,
}

async fn load_effective_memory(
    state: &DaemonState,
    project_id: &str,
) -> Result<EffectiveMemory, DaemonError> {
    let cache = state
        .memory_cache(DaemonMemoryCacheRequest {
            project_id: project_id.to_owned(),
        })
        .await?;
    if !cache.ready {
        return Err(SearchFailure::not_ready(format!(
            "the installed Commit generation for project {project_id} is not ready"
        ))
        .into());
    }

    let mut resources = BTreeMap::<String, EffectiveResource>::new();
    if let (Some(root_path), Some(base_commit_id)) =
        (cache.root_path.as_deref(), cache.commit_id.as_deref())
    {
        let marker_path = PathBuf::from(root_path).join("commit-payload.json");
        let payload: CachedCommitPayload =
            serde_json::from_slice(&std::fs::read(&marker_path).map_err(|error| {
                SearchFailure::failed(format!(
                    "failed to read installed Commit payload {}: {error}",
                    marker_path.display()
                ))
            })?)
            .map_err(|error| {
                SearchFailure::failed(format!(
                    "installed Commit payload {} is invalid: {error}",
                    marker_path.display()
                ))
            })?;
        if payload.commit.commit_id != base_commit_id {
            return Err(SearchFailure::generation_changed(
                "installed Commit payload does not match the current Project Ref",
            )
            .into());
        }
        let blobs = payload
            .blobs
            .into_iter()
            .map(|blob| (blob.blob_id, blob.content))
            .collect::<HashMap<_, _>>();
        for entry in payload.tree.entries {
            let Some(kind) = cached_memory_kind(entry.kind) else {
                continue;
            };
            let Some(scope) = cached_scope(entry.scope) else {
                continue;
            };
            let path = entry.path.ok_or_else(|| {
                SearchFailure::failed(format!(
                    "memory Tree entry {} is missing its path",
                    entry.id
                ))
            })?;
            let blob = blobs.get(&entry.blob_id).ok_or_else(|| {
                SearchFailure::failed(format!(
                    "memory Tree entry {} references missing Blob {}",
                    entry.id, entry.blob_id
                ))
            })?;
            let (content, rule, title) = project_authority_content(kind, &path, blob)?;
            resources.insert(
                entry.id.clone(),
                EffectiveResource {
                    source: SourceResource {
                        resource_id: entry.id,
                        project_id: project_id.to_owned(),
                        scope,
                        kind,
                        path,
                        title,
                        content_hash: sha256(&content),
                        content,
                        source_commit_id: Some(base_commit_id.to_owned()),
                        draft_id: None,
                        draft_revision: None,
                    },
                    rule,
                },
            );
        }
    }

    for draft in load_draft_overlays(&state.inner.pool, project_id).await? {
        apply_draft_overlay(project_id, &mut resources, draft)?;
    }
    let source_resources = resources
        .into_values()
        .map(|resource| resource.source)
        .collect::<Vec<_>>();
    let effective_hash =
        effective_memory_hash(project_id, cache.commit_id.as_deref(), &source_resources);
    Ok(EffectiveMemory {
        project_id: project_id.to_owned(),
        effective_hash,
        resources: source_resources,
    })
}

fn cached_memory_kind(kind: CachedMemoryKind) -> Option<MemoryKind> {
    match kind {
        CachedMemoryKind::Context => Some(MemoryKind::Context),
        CachedMemoryKind::Rule => Some(MemoryKind::Rule),
        CachedMemoryKind::Workflow => Some(MemoryKind::Workflow),
        CachedMemoryKind::Metaprompt | CachedMemoryKind::ProjectOrgSelection => None,
    }
}

fn cached_scope(scope: CachedScope) -> Option<SourceScope> {
    match scope {
        CachedScope::Org => Some(SourceScope::Org),
        CachedScope::Project => Some(SourceScope::Project),
        CachedScope::Daemon => None,
    }
}

fn project_authority_content(
    kind: MemoryKind,
    path: &str,
    blob: &str,
) -> Result<(String, Option<RuleFields>, String), DaemonError> {
    match kind {
        MemoryKind::Context | MemoryKind::Workflow => {
            let title = markdown_title(blob).unwrap_or_else(|| title_from_path(path));
            Ok((blob.to_owned(), None, title))
        }
        MemoryKind::Rule => {
            let envelope: RuleEnvelope = serde_json::from_str(blob).map_err(|error| {
                SearchFailure::failed(format!(
                    "Rule Blob at {path} is not canonical JSON: {error}"
                ))
            })?;
            if envelope.format != "clumsies.rule.v1"
                || envelope.content.constraint.trim().is_empty()
            {
                return Err(SearchFailure::failed(format!(
                    "Rule Blob at {path} has an unsupported format or empty constraint"
                ))
                .into());
            }
            let title = envelope.content.name.clone();
            let content = render_rule(&envelope.content);
            Ok((content, Some(envelope.content), title))
        }
    }
}

async fn load_draft_overlays(
    pool: &SqlitePool,
    project_id: &str,
) -> Result<Vec<DraftOverlay>, DaemonError> {
    let rows = sqlx::query(
        "SELECT d.draft_id, d.resource_scope, d.resource_kind, d.target_id, d.updated_at,
                o.rowid AS operation_order, o.operation_json
         FROM local_drafts d
         JOIN local_draft_operations o ON o.draft_id = d.draft_id
         WHERE d.project_id = $1
           AND d.status IN ('open', 'submitted', 'conflicted')
         ORDER BY d.updated_at, d.draft_id, o.rowid",
    )
    .bind(project_id)
    .fetch_all(pool)
    .await?;

    let mut overlays = Vec::<DraftOverlay>::new();
    for row in rows {
        let draft_id: String = row.try_get("draft_id")?;
        let operation_json: String = row.try_get("operation_json")?;
        let operation = serde_json::from_str(&operation_json).map_err(|error| {
            SearchFailure::failed(format!(
                "local Draft {draft_id} contains an invalid operation: {error}"
            ))
        })?;
        if overlays
            .last()
            .is_none_or(|overlay| overlay.draft_id != draft_id)
        {
            let scope = parse_source_scope(row.try_get::<String, _>("resource_scope")?.as_str())?;
            let kind = parse_memory_kind(row.try_get::<String, _>("resource_kind")?.as_str());
            overlays.push(DraftOverlay {
                draft_id: draft_id.clone(),
                scope,
                kind,
                target_id: row.try_get("target_id")?,
                updated_at: row.try_get("updated_at")?,
                operations: Vec::new(),
            });
        }
        overlays
            .last_mut()
            .expect("overlay inserted above")
            .operations
            .push((row.try_get("operation_order")?, operation_json, operation));
    }
    Ok(overlays)
}

fn apply_draft_overlay(
    project_id: &str,
    resources: &mut BTreeMap<String, EffectiveResource>,
    draft: DraftOverlay,
) -> Result<(), DaemonError> {
    let Some(kind) = draft.kind else {
        return Ok(());
    };
    if draft
        .operations
        .iter()
        .any(|(_, _, operation)| operation.discard.is_some())
    {
        return Ok(());
    }
    if draft.scope == SourceScope::Org
        && draft
            .target_id
            .as_ref()
            .is_none_or(|target| !resources.contains_key(target))
    {
        return Ok(());
    }

    let mut revision_hasher = Sha256::new();
    revision_hasher.update(draft.updated_at.as_bytes());
    for (order, operation_json, _) in &draft.operations {
        revision_hasher.update(order.to_le_bytes());
        revision_hasher.update(operation_json.as_bytes());
    }
    let draft_revision = format!("sha256:{}", hex::encode(revision_hasher.finalize()));

    for (_, _, operation) in &draft.operations {
        if let Some(create) = &operation.create {
            if draft.scope == SourceScope::Org {
                continue;
            }
            let resource_id = draft.draft_id.clone();
            let resource = draft_content_resource(
                project_id,
                resource_id.clone(),
                draft.scope,
                kind,
                create.path.clone(),
                &create.content,
                None,
                &draft.draft_id,
                &draft_revision,
            )?;
            resources.insert(resource_id, resource);
        }
        if let Some(update) = &operation.update {
            let Some(existing) = resources.remove(&update.id) else {
                continue;
            };
            let path = existing.source.path.clone();
            let updated = draft_content_resource(
                project_id,
                update.id.clone(),
                existing.source.scope,
                kind,
                path,
                &update.content,
                Some(existing),
                &draft.draft_id,
                &draft_revision,
            )?;
            resources.insert(update.id.clone(), updated);
        }
        if let Some(rename) = &operation.rename
            && let Some(resource) = resources.get_mut(&rename.id)
        {
            resource.source.path = rename.new_path.clone();
            if markdown_title(&resource.source.content).is_none() {
                resource.source.title = title_from_path(&rename.new_path);
            }
            resource.source.draft_id = Some(draft.draft_id.clone());
            resource.source.draft_revision = Some(draft_revision.clone());
        }
        if let Some(delete) = &operation.delete {
            resources.remove(&delete.id);
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn draft_content_resource(
    project_id: &str,
    resource_id: String,
    scope: SourceScope,
    kind: MemoryKind,
    path: String,
    content: &DaemonDraftContent,
    existing: Option<EffectiveResource>,
    draft_id: &str,
    draft_revision: &str,
) -> Result<EffectiveResource, DaemonError> {
    let source_commit_id = existing
        .as_ref()
        .and_then(|resource| resource.source.source_commit_id.clone());
    let (rendered, rule, title) = match (kind, content) {
        (MemoryKind::Context, DaemonDraftContent::Context { content })
        | (MemoryKind::Workflow, DaemonDraftContent::Workflow { content }) => (
            content.clone(),
            None,
            markdown_title(content).unwrap_or_else(|| title_from_path(&path)),
        ),
        (
            MemoryKind::Rule,
            DaemonDraftContent::Rule {
                name,
                applies_when,
                constraint,
                tags,
            },
        ) => {
            let previous = existing
                .as_ref()
                .and_then(|resource| resource.rule.as_ref());
            let fields = RuleFields {
                name: name
                    .clone()
                    .or_else(|| previous.map(|rule| rule.name.clone()))
                    .unwrap_or_else(|| title_from_path(&path)),
                applies_when: applies_when
                    .clone()
                    .or_else(|| previous.map(|rule| rule.applies_when.clone()))
                    .unwrap_or_default(),
                constraint: constraint.clone(),
                tags: tags
                    .clone()
                    .or_else(|| previous.map(|rule| rule.tags.clone()))
                    .unwrap_or_default(),
            };
            let title = fields.name.clone();
            (render_rule(&fields), Some(fields), title)
        }
        _ => {
            return Err(SearchFailure::failed(
                "Draft content kind does not match its indexed memory kind",
            )
            .into());
        }
    };
    Ok(EffectiveResource {
        source: SourceResource {
            resource_id,
            project_id: project_id.to_owned(),
            scope,
            kind,
            path,
            title,
            content_hash: sha256(&rendered),
            content: rendered,
            source_commit_id,
            draft_id: Some(draft_id.to_owned()),
            draft_revision: Some(draft_revision.to_owned()),
        },
        rule,
    })
}

fn parse_source_scope(value: &str) -> Result<SourceScope, DaemonError> {
    match value {
        "org" => Ok(SourceScope::Org),
        "project" => Ok(SourceScope::Project),
        _ => Err(SearchFailure::failed(format!("unknown Draft scope: {value}")).into()),
    }
}

fn parse_memory_kind(value: &str) -> Option<MemoryKind> {
    match value {
        "context" => Some(MemoryKind::Context),
        "rule" => Some(MemoryKind::Rule),
        "workflow" => Some(MemoryKind::Workflow),
        "metaprompt" => None,
        _ => None,
    }
}

fn render_rule(rule: &RuleFields) -> String {
    [
        format!("# {}", rule.name),
        String::new(),
        "## Applies when".to_owned(),
        String::new(),
        rule.applies_when.clone(),
        String::new(),
        "## Constraint".to_owned(),
        String::new(),
        rule.constraint.clone(),
        String::new(),
        format!(
            "Tags: {}",
            if rule.tags.is_empty() {
                "None".to_owned()
            } else {
                rule.tags.join(", ")
            }
        ),
    ]
    .join("\n")
}

fn markdown_title(content: &str) -> Option<String> {
    let mut in_heading = false;
    let mut title = String::new();
    for event in Parser::new_ext(content, Options::all()) {
        match event {
            Event::Start(Tag::Heading { .. }) if title.is_empty() => in_heading = true,
            Event::Text(text) | Event::Code(text) if in_heading => {
                if !title.is_empty() {
                    title.push(' ');
                }
                title.push_str(&text);
            }
            Event::End(pulldown_cmark::TagEnd::Heading(_)) if in_heading => {
                let collapsed = title.split_whitespace().collect::<Vec<_>>().join(" ");
                return (!collapsed.is_empty()).then_some(collapsed);
            }
            _ => {}
        }
    }
    None
}

fn title_from_path(path: &str) -> String {
    path.rsplit('/')
        .next()
        .unwrap_or(path)
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or_else(|| path.rsplit('/').next().unwrap_or(path))
        .replace(['_', '-'], " ")
}

fn effective_memory_hash(
    project_id: &str,
    base_commit_id: Option<&str>,
    resources: &[SourceResource],
) -> String {
    let mut ordered = resources.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| left.resource_id.cmp(&right.resource_id));
    let mut hasher = Sha256::new();
    hasher.update(project_id.as_bytes());
    hasher.update([0]);
    hasher.update(base_commit_id.unwrap_or_default().as_bytes());
    for resource in ordered {
        for value in [
            resource.resource_id.as_str(),
            resource.kind.as_str(),
            resource.scope.as_str(),
            resource.path.as_str(),
            resource.content_hash.as_str(),
            resource.draft_id.as_deref().unwrap_or_default(),
            resource.draft_revision.as_deref().unwrap_or_default(),
        ] {
            hasher.update(value.as_bytes());
            hasher.update([0]);
        }
    }
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

fn sha256(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[derive(Clone, Debug)]
struct BuiltUnit {
    resource: SourceResource,
    unit: RetrievalUnit,
    vector: Vec<f32>,
}

async fn ensure_index(
    state: &DaemonState,
    effective: &EffectiveMemory,
) -> Result<String, DaemonError> {
    let models = state.inner.search_models.clone();
    let model_revision = run_model_work(move || models.revision()).await?;
    let revision_id = index_revision_id(&effective.effective_hash, &model_revision);
    let existing: Option<i64> = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM search_heads h
         JOIN search_revisions r ON r.revision_id = h.revision_id
         WHERE h.project_id = $1 AND h.revision_id = $2 AND r.status = 'ready'",
    )
    .bind(&effective.project_id)
    .bind(&revision_id)
    .fetch_optional(&state.inner.pool)
    .await?;
    if existing.unwrap_or_default() == 1 {
        return Ok(revision_id);
    }

    let resources = effective.resources.clone();
    let models = state.inner.search_models.clone();
    let built = match run_model_work(move || build_index_units(&resources, models.as_ref())).await {
        Ok(built) => built,
        Err(error) => {
            let _ = record_failed_index(
                &state.inner.pool,
                effective,
                &revision_id,
                &model_revision,
                &error.to_string(),
            )
            .await;
            return Err(error);
        }
    };
    let current = load_effective_memory(state, &effective.project_id).await?;
    if current.effective_hash != effective.effective_hash {
        return Err(SearchFailure::generation_changed(
            "Commit or Draft state changed while the search index was being built",
        )
        .into());
    }
    if let Err(error) = install_index(
        &state.inner.pool,
        effective,
        &revision_id,
        &model_revision,
        &built,
        state.inner.search_models.dimensions(),
    )
    .await
    {
        let _ = record_failed_index(
            &state.inner.pool,
            effective,
            &revision_id,
            &model_revision,
            &error.to_string(),
        )
        .await;
        return Err(error);
    }
    Ok(revision_id)
}

async fn record_failed_index(
    pool: &SqlitePool,
    effective: &EffectiveMemory,
    revision_id: &str,
    model_revision: &str,
    message: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "INSERT INTO search_revisions (
            revision_id, project_id, effective_hash, model_revision,
            parser_version, ranking_version, status, last_error
         ) VALUES ($1, $2, $3, $4, $5, $6, 'failed', $7)
         ON CONFLICT(revision_id) DO UPDATE SET
            status = 'failed',
            last_error = excluded.last_error,
            ready_at = NULL",
    )
    .bind(revision_id)
    .bind(&effective.project_id)
    .bind(&effective.effective_hash)
    .bind(model_revision)
    .bind(PARSER_VERSION)
    .bind(RANKING_CONFIG_VERSION)
    .bind(message)
    .execute(pool)
    .await?;
    Ok(())
}

fn build_index_units(
    resources: &[SourceResource],
    models: &dyn SearchModels,
) -> Result<Vec<BuiltUnit>, SearchFailure> {
    let mut pairs = Vec::<(SourceResource, RetrievalUnit)>::new();
    let mut passages = Vec::<String>::new();
    for resource in resources {
        for unit in build_units(resource, models)? {
            passages.push(format!(
                "{}\n{}\n{}",
                resource.path,
                unit.heading_path.join(" > "),
                unit.text
            ));
            pairs.push((resource.clone(), unit));
        }
    }
    let embeddings = models.embed_passages(&passages)?;
    if embeddings.len() != pairs.len() {
        return Err(SearchFailure::vector(format!(
            "embedding count {} does not match unit count {}",
            embeddings.len(),
            pairs.len()
        )));
    }
    Ok(pairs
        .into_iter()
        .zip(embeddings)
        .map(|((resource, unit), vector)| BuiltUnit {
            resource,
            unit,
            vector,
        })
        .collect())
}

async fn run_model_work<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T, SearchFailure> + Send + 'static,
) -> Result<T, DaemonError> {
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|error| {
            SearchFailure::failed(format!(
                "search model worker terminated unexpectedly: {error}"
            ))
        })?
        .map_err(DaemonError::from)
}

fn index_revision_id(effective_hash: &str, model_revision: &str) -> String {
    let mut hasher = Sha256::new();
    for value in [
        effective_hash,
        PARSER_VERSION,
        model_revision,
        RANKING_CONFIG_VERSION,
    ] {
        hasher.update(value.as_bytes());
        hasher.update([0]);
    }
    format!("search_{}", hex::encode(hasher.finalize()))
}

async fn install_index(
    pool: &SqlitePool,
    effective: &EffectiveMemory,
    revision_id: &str,
    model_revision: &str,
    units: &[BuiltUnit],
    dimensions: usize,
) -> Result<(), DaemonError> {
    if units
        .iter()
        .any(|unit| unit.vector.len() != dimensions || !valid_normalized_vector(&unit.vector))
    {
        return Err(SearchFailure::vector(
            "index build produced a corrupt or non-normalized vector",
        )
        .into());
    }
    let mut tx = pool.begin().await?;
    delete_revision(&mut tx, revision_id).await?;
    sqlx::query(
        "INSERT INTO search_revisions (
            revision_id, project_id, effective_hash, model_revision,
            parser_version, ranking_version, status
         ) VALUES ($1, $2, $3, $4, $5, $6, 'building')",
    )
    .bind(revision_id)
    .bind(&effective.project_id)
    .bind(&effective.effective_hash)
    .bind(model_revision)
    .bind(PARSER_VERSION)
    .bind(RANKING_CONFIG_VERSION)
    .execute(&mut *tx)
    .await?;

    for resource in &effective.resources {
        sqlx::query(
            "INSERT INTO search_resources (
                revision_id, resource_id, project_id, scope, kind, path, title,
                content, content_hash, source_commit_id, draft_id, draft_revision
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        )
        .bind(revision_id)
        .bind(&resource.resource_id)
        .bind(&resource.project_id)
        .bind(resource.scope.as_str())
        .bind(resource.kind.as_str())
        .bind(&resource.path)
        .bind(&resource.title)
        .bind(&resource.content)
        .bind(&resource.content_hash)
        .bind(&resource.source_commit_id)
        .bind(&resource.draft_id)
        .bind(&resource.draft_revision)
        .execute(&mut *tx)
        .await?;
    }

    for built in units {
        let result = sqlx::query(
            "INSERT INTO search_units (
                revision_id, unit_key, resource_id, ordinal, heading_path_json,
                locator_json, text, text_hash, token_count, vector
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(revision_id)
        .bind(&built.unit.unit_key)
        .bind(&built.unit.resource_id)
        .bind(built.unit.ordinal as i64)
        .bind(serde_json::to_string(&built.unit.heading_path)?)
        .bind(serde_json::to_string(&built.unit.locator)?)
        .bind(&built.unit.text)
        .bind(&built.unit.text_hash)
        .bind(built.unit.token_count as i64)
        .bind(encode_vector(&built.vector))
        .execute(&mut *tx)
        .await?;
        let rowid = result.last_insert_rowid();
        sqlx::query(
            "INSERT INTO search_units_fts (
                rowid, revision_id, unit_key, path, title, heading, body
             ) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(rowid)
        .bind(revision_id)
        .bind(&built.unit.unit_key)
        .bind(&built.resource.path)
        .bind(&built.resource.title)
        .bind(built.unit.heading_path.join(" > "))
        .bind(&built.unit.text)
        .execute(&mut *tx)
        .await?;
    }

    let resource_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM search_resources WHERE revision_id = $1")
            .bind(revision_id)
            .fetch_one(&mut *tx)
            .await?;
    let unit_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM search_units WHERE revision_id = $1")
            .bind(revision_id)
            .fetch_one(&mut *tx)
            .await?;
    if resource_count != effective.resources.len() as i64 || unit_count != units.len() as i64 {
        return Err(SearchFailure::failed(
            "search index row counts do not match the Effective Memory build",
        )
        .into());
    }

    let old_revision: Option<String> =
        sqlx::query_scalar("SELECT revision_id FROM search_heads WHERE project_id = $1")
            .bind(&effective.project_id)
            .fetch_optional(&mut *tx)
            .await?;
    sqlx::query(
        "UPDATE search_revisions
         SET status = 'ready', ready_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), last_error = NULL
         WHERE revision_id = $1",
    )
    .bind(revision_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO search_heads (project_id, revision_id)
         VALUES ($1, $2)
         ON CONFLICT(project_id) DO UPDATE SET revision_id = excluded.revision_id",
    )
    .bind(&effective.project_id)
    .bind(revision_id)
    .execute(&mut *tx)
    .await?;
    if let Some(old_revision) = old_revision.filter(|old| old != revision_id) {
        delete_revision(&mut tx, &old_revision).await?;
    }
    tx.commit().await?;
    Ok(())
}

async fn delete_revision(
    tx: &mut Transaction<'_, Sqlite>,
    revision_id: &str,
) -> Result<(), DaemonError> {
    sqlx::query(
        "DELETE FROM search_units_fts
         WHERE rowid IN (SELECT unit_rowid FROM search_units WHERE revision_id = $1)",
    )
    .bind(revision_id)
    .execute(&mut **tx)
    .await?;
    sqlx::query("DELETE FROM search_revisions WHERE revision_id = $1")
        .bind(revision_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

async fn delete_project_index(pool: &SqlitePool, project_id: &str) -> Result<(), DaemonError> {
    let mut tx = pool.begin().await?;
    let revisions = sqlx::query_scalar::<_, String>(
        "SELECT revision_id FROM search_revisions WHERE project_id = $1",
    )
    .bind(project_id)
    .fetch_all(&mut *tx)
    .await?;
    sqlx::query("DELETE FROM search_heads WHERE project_id = $1")
        .bind(project_id)
        .execute(&mut *tx)
        .await?;
    for revision in revisions {
        delete_revision(&mut tx, &revision).await?;
    }
    tx.commit().await?;
    Ok(())
}

fn encode_vector(vector: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(std::mem::size_of_val(vector));
    for value in vector {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    bytes
}

fn decode_vector(bytes: &[u8], dimensions: usize) -> Result<Vec<f32>, SearchFailure> {
    if bytes.len() != dimensions * std::mem::size_of::<f32>() {
        return Err(SearchFailure::vector(format!(
            "vector byte length {} does not match dimension {dimensions}",
            bytes.len()
        )));
    }
    let vector = bytes
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect::<Vec<_>>();
    if !valid_normalized_vector(&vector) {
        return Err(SearchFailure::vector(
            "stored vector contains invalid values or is not normalized",
        ));
    }
    Ok(vector)
}

fn valid_normalized_vector(vector: &[f32]) -> bool {
    if vector.is_empty() || vector.iter().any(|value| !value.is_finite()) {
        return false;
    }
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    norm.is_finite() && (norm - 1.0).abs() <= 0.01
}

#[derive(Clone, Debug)]
struct IndexRow {
    rowid: i64,
    unit_key: String,
    resource_id: String,
    scope: SourceScope,
    kind: MemoryKind,
    path: String,
    title: String,
    heading_path: Vec<String>,
    text: String,
    text_hash: String,
    token_count: usize,
    vector: Vec<f32>,
}

#[derive(Clone, Debug)]
struct RankedRow {
    row: IndexRow,
    rrf_score: f32,
    rerank_score: f32,
}

async fn query_index(
    state: &DaemonState,
    revision_id: &str,
    query: &str,
    previous_state: ActivationStateToken,
) -> Result<ActivateMemoryResponse, DaemonError> {
    let rows = fetch_index_rows(
        &state.inner.pool,
        revision_id,
        state.inner.search_models.dimensions(),
    )
    .await?;
    if rows.is_empty() {
        return activation_response(revision_id, Vec::new(), &rows, previous_state);
    }
    let lexical = lexical_ranks(&state.inner.pool, revision_id, query, &rows).await?;
    let query_owned = query.to_owned();
    let models = state.inner.search_models.clone();
    let query_vector = run_model_work(move || models.embed_query(&query_owned)).await?;
    if query_vector.len() != state.inner.search_models.dimensions()
        || !valid_normalized_vector(&query_vector)
    {
        return Err(SearchFailure::vector("query embedding is corrupt").into());
    }
    let vector = vector_ranks(&rows, &query_vector);
    let fused = rrf_candidates(&rows, &lexical, &vector);
    let mut candidates = fused
        .into_iter()
        .take(RERANK_CANDIDATES)
        .collect::<Vec<_>>();
    if !candidates.is_empty() {
        let documents = candidates
            .iter()
            .map(|candidate| {
                format!(
                    "{}\n{}\n{}",
                    candidate.row.path,
                    candidate.row.heading_path.join(" > "),
                    candidate.row.text
                )
            })
            .collect::<Vec<_>>();
        let query_owned = query.to_owned();
        let models = state.inner.search_models.clone();
        let scores = run_model_work(move || models.rerank(&query_owned, &documents)).await?;
        if scores.len() != candidates.len() {
            return Err(SearchFailure::failed(
                "reranker result count does not match its candidate count",
            )
            .into());
        }
        for (candidate, score) in candidates.iter_mut().zip(scores) {
            candidate.rerank_score = score;
        }
        candidates.sort_by(|left, right| {
            right
                .rerank_score
                .total_cmp(&left.rerank_score)
                .then_with(|| right.rrf_score.total_cmp(&left.rrf_score))
                .then_with(|| left.row.unit_key.cmp(&right.row.unit_key))
        });
    }

    let selected = apply_fragment_budget(candidates);
    activation_response(revision_id, selected, &rows, previous_state)
}

async fn fetch_index_rows(
    pool: &SqlitePool,
    revision_id: &str,
    dimensions: usize,
) -> Result<Vec<IndexRow>, DaemonError> {
    let rows = sqlx::query(
        "SELECT u.unit_rowid, u.unit_key, u.resource_id, u.heading_path_json,
                u.text, u.text_hash, u.token_count, u.vector,
                r.scope, r.kind, r.path, r.title
         FROM search_units u
         JOIN search_resources r
           ON r.revision_id = u.revision_id AND r.resource_id = u.resource_id
         WHERE u.revision_id = $1
         ORDER BY u.unit_key",
    )
    .bind(revision_id)
    .fetch_all(pool)
    .await?;
    rows.into_iter()
        .map(|row| {
            let kind_value: String = row.try_get("kind")?;
            let scope_value: String = row.try_get("scope")?;
            let vector_bytes: Vec<u8> = row.try_get("vector")?;
            let token_count: i64 = row.try_get("token_count")?;
            if token_count < 0 {
                return Err(SearchFailure::failed("stored token count is negative").into());
            }
            Ok(IndexRow {
                rowid: row.try_get("unit_rowid")?,
                unit_key: row.try_get("unit_key")?,
                resource_id: row.try_get("resource_id")?,
                scope: parse_source_scope(&scope_value)?,
                kind: parse_memory_kind(&kind_value).ok_or_else(|| {
                    SearchFailure::failed(format!("unknown indexed memory kind: {kind_value}"))
                })?,
                path: row.try_get("path")?,
                title: row.try_get("title")?,
                heading_path: serde_json::from_str(
                    row.try_get::<String, _>("heading_path_json")?.as_str(),
                )?,
                text: row.try_get("text")?,
                text_hash: row.try_get("text_hash")?,
                token_count: token_count as usize,
                vector: decode_vector(&vector_bytes, dimensions)?,
            })
        })
        .collect()
}

async fn lexical_ranks(
    pool: &SqlitePool,
    revision_id: &str,
    query: &str,
    rows: &[IndexRow],
) -> Result<Vec<i64>, DaemonError> {
    let normalized = query.trim().to_lowercase();
    let mut exact = rows
        .iter()
        .filter_map(|row| {
            let resource_id = row.resource_id.to_lowercase();
            let path = row.path.to_lowercase();
            let title = row.title.to_lowercase();
            let priority = if resource_id == normalized {
                Some(0u8)
            } else if path == normalized || title == normalized {
                Some(1)
            } else if resource_id.starts_with(&normalized)
                || path.starts_with(&normalized)
                || title.starts_with(&normalized)
            {
                Some(2)
            } else {
                None
            }?;
            Some((priority, row.unit_key.as_str(), row.rowid))
        })
        .collect::<Vec<_>>();
    exact.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(right.1)));
    let mut ordered = exact
        .into_iter()
        .map(|(_, _, rowid)| rowid)
        .collect::<Vec<_>>();
    let mut seen = ordered.iter().copied().collect::<HashSet<_>>();

    if let Some(expression) = fts_expression(query) {
        let matches = sqlx::query(
            "SELECT rowid, bm25(search_units_fts, 0.0, 0.0, 8.0, 6.0, 4.0, 1.0) AS score
             FROM search_units_fts
             WHERE search_units_fts MATCH $1 AND revision_id = $2
             ORDER BY score, unit_key
             LIMIT $3",
        )
        .bind(expression)
        .bind(revision_id)
        .bind(BM25_TOP_K as i64)
        .fetch_all(pool)
        .await?;
        for row in matches {
            let rowid: i64 = row.try_get("rowid")?;
            if seen.insert(rowid) {
                ordered.push(rowid);
            }
        }
    }
    ordered.truncate(BM25_TOP_K);
    Ok(ordered)
}

fn fts_expression(query: &str) -> Option<String> {
    let mut runs = Vec::<String>::new();
    let mut current = String::new();
    for character in query.trim().chars() {
        if character.is_alphanumeric()
            || character == '_'
            || matches!(character, '/' | '-' | '.' | ':')
        {
            current.push(character);
        } else if !current.is_empty() {
            runs.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        runs.push(current);
    }

    let mut terms = BTreeSet::new();
    for run in runs {
        let characters = run.chars().collect::<Vec<_>>();
        if characters.len() < 3 {
            continue;
        }
        if characters.iter().any(|character| !character.is_ascii()) {
            for window in characters.windows(3) {
                terms.insert(window.iter().collect::<String>());
                if terms.len() >= 32 {
                    break;
                }
            }
        } else {
            terms.insert(run);
        }
        if terms.len() >= 32 {
            break;
        }
    }
    (!terms.is_empty()).then(|| {
        terms
            .into_iter()
            .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" OR ")
    })
}

fn vector_ranks(rows: &[IndexRow], query_vector: &[f32]) -> Vec<i64> {
    let mut scored = rows
        .iter()
        .map(|row| {
            let score = row
                .vector
                .iter()
                .zip(query_vector)
                .map(|(left, right)| left * right)
                .sum::<f32>();
            (score, row.unit_key.as_str(), row.rowid)
        })
        .collect::<Vec<_>>();
    scored.sort_by(|left, right| right.0.total_cmp(&left.0).then_with(|| left.1.cmp(right.1)));
    scored
        .into_iter()
        .take(VECTOR_TOP_K)
        .map(|(_, _, rowid)| rowid)
        .collect()
}

fn rrf_candidates(rows: &[IndexRow], lexical: &[i64], vector: &[i64]) -> Vec<RankedRow> {
    let mut scores = HashMap::<i64, (f32, usize)>::new();
    for channel in [lexical, vector] {
        for (index, rowid) in channel.iter().enumerate() {
            let rank = index + 1;
            let entry = scores.entry(*rowid).or_insert((0.0, usize::MAX));
            entry.0 += 1.0 / (RRF_CONSTANT + rank as f32);
            entry.1 = entry.1.min(rank);
        }
    }
    let by_rowid = rows
        .iter()
        .map(|row| (row.rowid, row))
        .collect::<HashMap<_, _>>();
    let mut fused = scores
        .into_iter()
        .filter_map(|(rowid, (rrf_score, best_rank))| {
            by_rowid.get(&rowid).map(|row| {
                (
                    RankedRow {
                        row: (*row).clone(),
                        rrf_score,
                        rerank_score: f32::NEG_INFINITY,
                    },
                    best_rank,
                )
            })
        })
        .collect::<Vec<_>>();
    fused.sort_by(|left, right| {
        right
            .0
            .rrf_score
            .total_cmp(&left.0.rrf_score)
            .then_with(|| left.1.cmp(&right.1))
            .then_with(|| left.0.row.unit_key.cmp(&right.0.row.unit_key))
    });
    fused
        .into_iter()
        .take(RRF_CANDIDATES)
        .map(|(row, _)| row)
        .collect()
}

fn apply_fragment_budget(candidates: Vec<RankedRow>) -> Vec<RankedRow> {
    let mut selected = Vec::new();
    let mut per_resource = HashMap::<String, usize>::new();
    let mut tokens = 0usize;
    for candidate in candidates {
        if selected.len() >= FINAL_FRAGMENTS {
            break;
        }
        let count = per_resource
            .get(&candidate.row.resource_id)
            .copied()
            .unwrap_or_default();
        if count >= PER_RESOURCE_LIMIT {
            continue;
        }
        if !selected.is_empty()
            && tokens.saturating_add(candidate.row.token_count) > FRAGMENT_TOKEN_BUDGET
        {
            continue;
        }
        tokens = tokens.saturating_add(candidate.row.token_count);
        *per_resource
            .entry(candidate.row.resource_id.clone())
            .or_default() += 1;
        selected.push(candidate);
    }
    selected
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
struct ActivationStateToken {
    version: u8,
    epoch: u64,
    known: Vec<KnownActivationIdentity>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct KnownActivationIdentity {
    unit_key: String,
    content_hash: String,
    last_seen: u64,
}

fn decode_activation_state(state: Option<&str>) -> Result<ActivationStateToken, DaemonError> {
    let Some(state) = state else {
        return Ok(ActivationStateToken {
            version: 1,
            epoch: 0,
            known: Vec::new(),
        });
    };
    if state.len() > MAX_ACTIVATION_STATE_BYTES * 2 {
        return Err(SearchFailure::invalid_state("activation state is too large").into());
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(state)
        .map_err(|_| SearchFailure::invalid_state("activation state is not valid base64url"))?;
    if bytes.len() > MAX_ACTIVATION_STATE_BYTES {
        return Err(SearchFailure::invalid_state("activation state is too large").into());
    }
    let decoded: ActivationStateToken = serde_json::from_slice(&bytes)
        .map_err(|_| SearchFailure::invalid_state("activation state is not valid JSON"))?;
    if decoded.version != 1 || decoded.known.len() > MAX_ACTIVATION_IDENTITIES {
        return Err(SearchFailure::invalid_state(
            "activation state version or identity count is unsupported",
        )
        .into());
    }
    let mut identities = HashSet::new();
    if decoded
        .known
        .iter()
        .any(|identity| !identities.insert(identity.unit_key.as_str()))
    {
        return Err(SearchFailure::invalid_state(
            "activation state contains duplicate unit identities",
        )
        .into());
    }
    Ok(decoded)
}

fn activation_response(
    revision_id: &str,
    selected: Vec<RankedRow>,
    all_rows: &[IndexRow],
    previous_state: ActivationStateToken,
) -> Result<ActivateMemoryResponse, DaemonError> {
    let epoch = previous_state.epoch.saturating_add(1);
    let existing = all_rows
        .iter()
        .map(|row| row.unit_key.as_str())
        .collect::<HashSet<_>>();
    let previous = previous_state
        .known
        .iter()
        .map(|identity| (identity.unit_key.clone(), identity.content_hash.clone()))
        .collect::<HashMap<_, _>>();
    let mut removed = previous_state
        .known
        .iter()
        .filter(|identity| !existing.contains(identity.unit_key.as_str()))
        .map(|identity| ActivationRemoval {
            unit_key: identity.unit_key.clone(),
        })
        .collect::<Vec<_>>();
    removed.sort_by(|left, right| left.unit_key.cmp(&right.unit_key));

    let mut next_known = previous_state
        .known
        .into_iter()
        .filter(|identity| existing.contains(identity.unit_key.as_str()))
        .map(|identity| (identity.unit_key.clone(), identity))
        .collect::<HashMap<_, _>>();
    let mut fragments = Vec::new();
    for candidate in selected {
        let action = match previous.get(candidate.row.unit_key.as_str()) {
            Some(content_hash) if *content_hash == candidate.row.text_hash => {
                ActivationAction::Reuse
            }
            Some(_) => ActivationAction::Replace,
            None => ActivationAction::Add,
        };
        next_known.insert(
            candidate.row.unit_key.clone(),
            KnownActivationIdentity {
                unit_key: candidate.row.unit_key.clone(),
                content_hash: candidate.row.text_hash.clone(),
                last_seen: epoch,
            },
        );
        fragments.push(ActivationFragment {
            action,
            unit_key: candidate.row.unit_key,
            content_hash: candidate.row.text_hash,
            resource_id: candidate.row.resource_id,
            scope: candidate.row.scope,
            kind: candidate.row.kind,
            path: candidate.row.path,
            heading_path: candidate.row.heading_path,
            content: (action != ActivationAction::Reuse).then_some(candidate.row.text),
        });
    }
    let mut known = next_known.into_values().collect::<Vec<_>>();
    known.sort_by(|left, right| {
        right
            .last_seen
            .cmp(&left.last_seen)
            .then_with(|| left.unit_key.cmp(&right.unit_key))
    });
    known.truncate(MAX_ACTIVATION_IDENTITIES);
    let next_state = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&ActivationStateToken {
        version: 1,
        epoch,
        known,
    })?);
    Ok(ActivateMemoryResponse {
        index_revision: revision_id.to_owned(),
        profile: RANKING_CONFIG_VERSION.to_owned(),
        next_state,
        fragments,
        removed,
    })
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;
    use tempfile::TempDir;

    use super::*;
    use crate::{
        CredentialStore, CredentialStoreError, DaemonDraftOperationRequest,
        DaemonDraftOperationSource, DaemonIpcRequest, DaemonIpcService, DaemonUpdateDraftOperation,
        ServerCredentials,
    };

    struct NoCredentials;

    impl CredentialStore for NoCredentials {
        fn load(&self) -> Result<Option<ServerCredentials>, CredentialStoreError> {
            Ok(None)
        }

        fn replace(&self, _credentials: &ServerCredentials) -> Result<(), CredentialStoreError> {
            Ok(())
        }

        fn clear(&self) -> Result<(), CredentialStoreError> {
            Ok(())
        }
    }

    struct DeterministicModels;

    struct FailingIndexModels;

    impl SearchModels for DeterministicModels {
        fn revision(&self) -> Result<String, SearchFailure> {
            Ok("deterministic-models.v1".to_owned())
        }

        fn token_offsets(&self, text: &str) -> Result<Vec<(usize, usize)>, SearchFailure> {
            Ok(text
                .char_indices()
                .map(|(start, character)| (start, start + character.len_utf8()))
                .collect())
        }

        fn embed_passages(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, SearchFailure> {
            Ok(texts.iter().map(|text| test_vector(text)).collect())
        }

        fn embed_query(&self, query: &str) -> Result<Vec<f32>, SearchFailure> {
            Ok(test_vector(query))
        }

        fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f32>, SearchFailure> {
            let needle = query.to_lowercase();
            Ok(documents
                .iter()
                .map(|document| {
                    if document.to_lowercase().contains(&needle) {
                        1.0
                    } else {
                        0.0
                    }
                })
                .collect())
        }

        fn dimensions(&self) -> usize {
            3
        }

        fn status(&self) -> SearchModelRuntimeStatus {
            SearchModelRuntimeStatus::Ready
        }
    }

    impl SearchModels for FailingIndexModels {
        fn revision(&self) -> Result<String, SearchFailure> {
            Ok("failing-index-models.v1".to_owned())
        }

        fn token_offsets(&self, text: &str) -> Result<Vec<(usize, usize)>, SearchFailure> {
            Ok(text
                .char_indices()
                .map(|(start, character)| (start, start + character.len_utf8()))
                .collect())
        }

        fn embed_passages(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>, SearchFailure> {
            Err(SearchFailure::model("deterministic index failure"))
        }

        fn embed_query(&self, _query: &str) -> Result<Vec<f32>, SearchFailure> {
            unreachable!("query embedding is not reached when index construction fails")
        }

        fn rerank(&self, _query: &str, _documents: &[String]) -> Result<Vec<f32>, SearchFailure> {
            unreachable!("reranking is not reached when index construction fails")
        }

        fn dimensions(&self) -> usize {
            3
        }

        fn status(&self) -> SearchModelRuntimeStatus {
            SearchModelRuntimeStatus::Ready
        }
    }

    fn test_vector(text: &str) -> Vec<f32> {
        let lower = text.to_lowercase();
        if lower.contains("hybrid") || lower.contains("混合") {
            vec![1.0, 0.0, 0.0]
        } else if lower.contains("workflow") {
            vec![0.0, 1.0, 0.0]
        } else {
            vec![0.0, 0.0, 1.0]
        }
    }

    async fn test_state() -> (TempDir, DaemonState) {
        test_state_with_models(Arc::new(DeterministicModels)).await
    }

    async fn test_state_with_models(
        search_models: Arc<dyn SearchModels>,
    ) -> (TempDir, DaemonState) {
        let temp = tempfile::tempdir().unwrap();
        let config = crate::DaemonConfig::for_root(temp.path().join("daemon"));
        let cache_dir = config.cache_dir.clone();
        let state = DaemonState::initialize_with_credential_store_and_search_models(
            config,
            Arc::new(NoCredentials),
            search_models,
        )
        .await
        .unwrap();

        let payload = json!({
            "commit": {
                "commit_id": "commit_test",
                "scope": "project",
                "org_id": "org_test",
                "project_id": "prj_test",
                "tree_id": "tree_test",
                "parent_commit_id": null,
                "version": 1,
                "created_at": "2026-07-21T00:00:00Z"
            },
            "tree": {
                "tree_id": "tree_test",
                "entries": [
                    {
                        "id": "ctx_retrieval",
                        "type": "context",
                        "scope": "project",
                        "project_id": "prj_test",
                        "path": "architecture/retrieval.md",
                        "blob_id": "blob_context",
                        "source": "project"
                    },
                    {
                        "id": "rule_testing",
                        "type": "rule",
                        "scope": "org",
                        "project_id": null,
                        "path": "coding/TESTING.md",
                        "blob_id": "blob_rule",
                        "source": "selected_org"
                    },
                    {
                        "id": "workflow_coding",
                        "type": "workflow",
                        "scope": "project",
                        "project_id": "prj_test",
                        "path": "workflow/CODING.md",
                        "blob_id": "blob_workflow",
                        "source": "project"
                    },
                    {
                        "id": "mpf_ignored",
                        "type": "metaprompt",
                        "scope": "org",
                        "project_id": null,
                        "path": "META_PROMPT.md",
                        "blob_id": "blob_mpf",
                        "source": "selected_org"
                    }
                ]
            },
            "blobs": [
                {
                    "blob_id": "blob_context",
                    "content": "# Retrieval\n\nHybrid search combines BM25 and dense vectors."
                },
                {
                    "blob_id": "blob_rule",
                    "content": "{\"format\":\"clumsies.rule.v1\",\"content\":{\"name\":\"Testing\",\"applies_when\":\"changing retrieval\",\"constraint\":\"Run integration tests.\",\"tags\":[\"testing\"]}}"
                },
                {
                    "blob_id": "blob_workflow",
                    "content": "# Coding Workflow\n\nImplement, test, and review."
                },
                {"blob_id": "blob_mpf", "content": "ignored bootstrap"}
            ],
            "project_org_selection": null
        });
        let marker = serde_json::to_vec(&payload).unwrap();
        let root = cache_dir.join("projects/prj_test/generations/commit_test");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("commit-payload.json"), marker).unwrap();
        fs::write(
            root.join("manifest.json"),
            serde_json::to_vec(&json!({
                "project_id": "prj_test",
                "commit_id": "commit_test",
                "tree_id": "tree_test",
                "ref_name": "refs/heads/main",
                "rules": {},
                "context": {}
            }))
            .unwrap(),
        )
        .unwrap();
        sqlx::query(
            "INSERT INTO cached_refs (
                ref_key, name, scope, org_id, project_id, commit_id, etag, server_updated_at
             ) VALUES ('project:prj_test', 'refs/heads/main', 'project', 'org_test',
                       'prj_test', 'commit_test', '\"commit_test\"', '2026-07-21T00:00:00Z')",
        )
        .execute(&state.inner.pool)
        .await
        .unwrap();
        (temp, state)
    }

    #[tokio::test]
    async fn commit_activate_load_and_draft_delta_form_one_effective_memory_loop() {
        let (_temp, state) = test_state().await;
        let first = state
            .activate_memory(ActivateMemoryRequest {
                project_id: "prj_test".to_owned(),
                query: "hybrid".to_owned(),
                state: None,
            })
            .await
            .unwrap();
        assert!(first.fragments.iter().any(|fragment| {
            fragment.resource_id == "ctx_retrieval"
                && fragment.action == ActivationAction::Add
                && fragment
                    .content
                    .as_deref()
                    .is_some_and(|content| content.contains("BM25"))
        }));
        assert!(
            first
                .fragments
                .iter()
                .all(|fragment| fragment.resource_id != "mpf_ignored")
        );

        let second = state
            .activate_memory(ActivateMemoryRequest {
                project_id: "prj_test".to_owned(),
                query: "hybrid".to_owned(),
                state: Some(first.next_state.clone()),
            })
            .await
            .unwrap();
        let reused = second
            .fragments
            .iter()
            .find(|fragment| fragment.resource_id == "ctx_retrieval")
            .unwrap();
        assert_eq!(reused.action, ActivationAction::Reuse);
        assert!(reused.content.is_none());

        state
            .store_draft_operation(DaemonDraftOperationRequest {
                draft_id: None,
                base_commit_id: None,
                project_id: "prj_test".to_owned(),
                scope: crate::DaemonDraftScope::Project,
                resource: crate::DaemonDraftResourceKind::Context,
                op: DaemonDraftOperation {
                    create: None,
                    update: Some(DaemonUpdateDraftOperation {
                        id: "ctx_retrieval".to_owned(),
                        content: DaemonDraftContent::Context {
                            content: "# Retrieval\n\nHybrid search now uses BM25, vectors, RRF, and reranking."
                                .to_owned(),
                        },
                        description: None,
                    }),
                    rename: None,
                    delete: None,
                    discard: None,
                },
                source: Some(DaemonDraftOperationSource::McpStore),
            })
            .await
            .unwrap();

        let third = state
            .activate_memory(ActivateMemoryRequest {
                project_id: "prj_test".to_owned(),
                query: "hybrid".to_owned(),
                state: Some(second.next_state),
            })
            .await
            .unwrap();
        assert_ne!(third.index_revision, first.index_revision);
        let replaced = third
            .fragments
            .iter()
            .find(|fragment| fragment.resource_id == "ctx_retrieval")
            .unwrap();
        assert_eq!(replaced.action, ActivationAction::Replace);
        assert!(
            replaced
                .content
                .as_deref()
                .is_some_and(|content| content.contains("RRF"))
        );

        let load_response = DaemonIpcService::new(state.clone())
            .dispatch(DaemonIpcRequest::new(
                "load_memory",
                serde_json::to_value(LoadMemoryRequest {
                    project_id: "prj_test".to_owned(),
                    ids: vec!["architecture/retrieval.md".to_owned()],
                    known_hashes: BTreeMap::from([(
                        "ctx_retrieval".to_owned(),
                        first
                            .fragments
                            .iter()
                            .find(|fragment| fragment.resource_id == "ctx_retrieval")
                            .unwrap()
                            .content_hash
                            .clone(),
                    )]),
                })
                .unwrap(),
            ))
            .await;
        assert!(load_response.ok);
        let loaded: LoadMemoryResponse = serde_json::from_value(load_response.payload).unwrap();
        assert_eq!(loaded.resources.len(), 1);
        assert!(loaded.resources[0].changed);
        assert!(
            loaded.resources[0]
                .content
                .as_deref()
                .is_some_and(|content| content.contains("reranking"))
        );

        let indexed_kinds = sqlx::query_scalar::<_, String>(
            "SELECT kind FROM search_resources
             WHERE revision_id = $1 ORDER BY kind",
        )
        .bind(&third.index_revision)
        .fetch_all(&state.inner.pool)
        .await
        .unwrap();
        assert_eq!(indexed_kinds, ["context", "rule", "workflow"]);
    }

    #[tokio::test]
    async fn failed_index_build_is_recorded_without_moving_the_search_head() {
        let (_temp, state) = test_state_with_models(Arc::new(FailingIndexModels)).await;
        let error = state
            .activate_memory(ActivateMemoryRequest {
                project_id: "prj_test".to_owned(),
                query: "hybrid".to_owned(),
                state: None,
            })
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            DaemonError::Search { ref code, .. } if code == "search_model_unavailable"
        ));

        let status = state
            .search_index_status(SearchIndexProjectRequest {
                project_id: "prj_test".to_owned(),
            })
            .await
            .unwrap();
        assert!(!status.ready);
        assert!(status.active_revision.is_none());
        assert!(
            status
                .last_error
                .as_deref()
                .is_some_and(|message| message.contains("deterministic index failure"))
        );
    }

    #[test]
    fn fts_builder_never_exposes_user_syntax() {
        let expression = fts_expression("混合检索 OR \"secret\" path/file.rs").unwrap();
        assert!(expression.contains("\"混合检\""));
        assert!(expression.contains("\"path/file.rs\""));
        assert!(
            expression
                .split(" OR ")
                .all(|term| term.starts_with('"') && term.ends_with('"'))
        );
    }

    #[test]
    fn activation_state_rejects_corruption_and_duplicate_identities() {
        assert!(decode_activation_state(Some("not-base64!")).is_err());
        let duplicate = ActivationStateToken {
            version: 1,
            epoch: 1,
            known: vec![
                KnownActivationIdentity {
                    unit_key: "same".to_owned(),
                    content_hash: "one".to_owned(),
                    last_seen: 1,
                },
                KnownActivationIdentity {
                    unit_key: "same".to_owned(),
                    content_hash: "two".to_owned(),
                    last_seen: 1,
                },
            ],
        };
        let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&duplicate).unwrap());
        assert!(decode_activation_state(Some(&encoded)).is_err());
    }
}
