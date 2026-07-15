use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::Ordering;

use reqwest::header::ETAG;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use super::*;

const META_COMMIT_SYNC_LAST_ATTEMPT_AT: &str = "commit_sync_last_attempt_at";
const META_COMMIT_SYNC_LAST_SUCCESS_AT: &str = "commit_sync_last_success_at";
const META_COMMIT_SYNC_LAST_ERROR: &str = "commit_sync_last_error";
const MAIN_REF: &str = "refs/heads/main";
const EMPTY_GENERATION: &str = "ref-none";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonMemoryCacheRequest {
    pub project_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonMemoryCacheStatus {
    pub project_id: String,
    pub commit_id: Option<String>,
    pub root_path: Option<String>,
    pub ready: bool,
}

pub(super) async fn migrate(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS cached_blobs (
            blob_id TEXT PRIMARY KEY,
            content TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS cached_trees (
            tree_id TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS cached_commits (
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
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS cached_refs (
            ref_key TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
            org_id TEXT NOT NULL,
            project_id TEXT,
            commit_id TEXT,
            etag TEXT NOT NULL,
            server_updated_at TEXT NOT NULL,
            installed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE INDEX IF NOT EXISTS idx_cached_refs_project_id
         ON cached_refs (project_id)",
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub(super) async fn run(state: &DaemonState) -> Result<(), DaemonError> {
    state
        .inner
        .commit_sync_running
        .store(true, Ordering::Release);
    let result = async {
        upsert_meta_timestamp(&state.inner.pool, META_COMMIT_SYNC_LAST_ATTEMPT_AT).await?;
        let sync_result = sync_refs(state).await;
        match &sync_result {
            Ok(()) => {
                let mut tx = state.inner.pool.begin().await?;
                upsert_meta_value(&mut tx, META_COMMIT_SYNC_LAST_ERROR, None).await?;
                tx.commit().await?;
                upsert_meta_timestamp(&state.inner.pool, META_COMMIT_SYNC_LAST_SUCCESS_AT).await?;
            }
            Err(error) => {
                let mut tx = state.inner.pool.begin().await?;
                upsert_meta_value(
                    &mut tx,
                    META_COMMIT_SYNC_LAST_ERROR,
                    Some(&error.to_string()),
                )
                .await?;
                tx.commit().await?;
            }
        }
        sync_result
    }
    .await;
    state
        .inner
        .commit_sync_running
        .store(false, Ordering::Release);
    result
}

pub(super) async fn status(state: &DaemonState) -> Result<SyncChannelStatus, DaemonError> {
    let config = state.project_config();
    let readiness = config.readiness();
    let project_id = config.project_id.as_deref();
    let server_cursor = match project_id {
        Some(project_id) => {
            load_ref_commit(&state.inner.pool, &project_ref_key(project_id)).await?
        }
        None => None,
    };
    let ref_installed = match project_id {
        Some(project_id) => ref_exists(&state.inner.pool, &project_ref_key(project_id)).await?,
        None => false,
    };
    let last_attempt_at =
        load_meta_value(&state.inner.pool, META_COMMIT_SYNC_LAST_ATTEMPT_AT).await?;
    let last_success_at =
        load_meta_value(&state.inner.pool, META_COMMIT_SYNC_LAST_SUCCESS_AT).await?;
    let last_error = load_meta_value(&state.inner.pool, META_COMMIT_SYNC_LAST_ERROR).await?;

    let config_error = (!readiness.ready && state.inner.config.sync.enabled).then(|| ApiError {
        code: "daemon_project_config_incomplete".to_owned(),
        message: format!(
            "Daemon project config is missing required fields: {}",
            readiness.missing_fields.join(", ")
        ),
        request_id: "local".to_owned(),
        details: json!({ "missing_fields": readiness.missing_fields }),
    });
    let state_value = if state.inner.commit_sync_running.load(Ordering::Acquire) {
        SyncState::Syncing
    } else if config_error.is_some() {
        SyncState::Degraded
    } else if last_error.is_some() {
        SyncState::Failed
    } else if readiness.ready && !ref_installed {
        SyncState::Queued
    } else {
        SyncState::Idle
    };

    Ok(SyncChannelStatus {
        state: state_value,
        server_cursor,
        last_attempt_at,
        last_success_at,
        last_error: config_error.or_else(|| {
            last_error.map(|message| ApiError {
                code: "commit_sync_failed".to_owned(),
                message,
                request_id: "local".to_owned(),
                details: json!({}),
            })
        }),
    })
}

pub(super) async fn current_base_commit_id(
    pool: &SqlitePool,
    project_id: &str,
    scope: DaemonDraftScope,
) -> Result<Option<String>, DaemonError> {
    match scope {
        DaemonDraftScope::Project => load_ref_commit(pool, &project_ref_key(project_id)).await,
        DaemonDraftScope::Org => {
            let org_id: Option<String> = sqlx::query_scalar(
                "SELECT org_id FROM cached_refs WHERE ref_key = $1 AND scope = 'project'",
            )
            .bind(project_ref_key(project_id))
            .fetch_optional(pool)
            .await?;
            match org_id {
                Some(org_id) => load_ref_commit(pool, &org_ref_key(&org_id)).await,
                None => Ok(None),
            }
        }
    }
}

pub(super) async fn memory_cache(
    state: &DaemonState,
    request: DaemonMemoryCacheRequest,
) -> Result<DaemonMemoryCacheStatus, DaemonError> {
    validate_cache_component("project_id", &request.project_id)?;
    let row = sqlx::query(
        "SELECT commit_id
         FROM cached_refs
         WHERE ref_key = $1 AND scope = 'project'",
    )
    .bind(project_ref_key(&request.project_id))
    .fetch_optional(&state.inner.pool)
    .await?;
    let Some(row) = row else {
        return Ok(DaemonMemoryCacheStatus {
            project_id: request.project_id,
            commit_id: None,
            root_path: None,
            ready: false,
        });
    };
    let commit_id: Option<String> = row.try_get("commit_id")?;
    let generation = generation_root(
        &state.inner.config.cache_dir,
        &request.project_id,
        commit_id.as_deref().unwrap_or(EMPTY_GENERATION),
    );
    let ready =
        verify_generation_ref(&generation, &request.project_id, commit_id.as_deref()).is_ok();
    Ok(DaemonMemoryCacheStatus {
        project_id: request.project_id,
        commit_id,
        root_path: ready.then(|| generation.display().to_string()),
        ready,
    })
}

async fn sync_refs(state: &DaemonState) -> Result<(), DaemonError> {
    let project_id = state
        .project_config()
        .project_id
        .ok_or_else(|| DaemonError::InvalidConfig("project_id is required".to_owned()))?;
    validate_cache_component("project_id", &project_id)?;

    let local_project_commit =
        load_ref_commit(&state.inner.pool, &project_ref_key(&project_id)).await?;
    let (project_state, project_etag) = fetch_commit_state(
        state,
        &format!("/api/v1/projects/{project_id}/commit-state"),
        local_project_commit.as_deref(),
    )
    .await?;
    validate_commit_state(
        &project_state,
        &project_etag,
        ServerCommitScope::Project,
        Some(&project_id),
        local_project_commit.as_deref(),
    )?;

    let org_id = project_state.reference.org_id.clone();
    let local_org_commit = load_ref_commit(&state.inner.pool, &org_ref_key(&org_id)).await?;
    let (org_state, org_etag) = fetch_commit_state(
        state,
        "/api/v1/org/commit-state",
        local_org_commit.as_deref(),
    )
    .await?;
    validate_commit_state(
        &org_state,
        &org_etag,
        ServerCommitScope::Org,
        None,
        local_org_commit.as_deref(),
    )?;
    if org_state.reference.org_id != org_id {
        return Err(DaemonError::Server(
            "Project and organization commit states belong to different organizations".to_owned(),
        ));
    }

    install_ref(state, &org_state, &org_etag, None).await?;
    install_ref(state, &project_state, &project_etag, Some(&project_id)).await?;
    Ok(())
}

async fn fetch_commit_state(
    state: &DaemonState,
    path: &str,
    local_commit_id: Option<&str>,
) -> Result<(ServerCommitState, String), DaemonError> {
    let path = match local_commit_id {
        Some(commit_id) => format!("{path}?local_commit_id={commit_id}"),
        None => path.to_owned(),
    };
    let response = execute_authenticated_server_request(
        state,
        reqwest::Method::GET,
        &path,
        &BTreeMap::new(),
        None,
    )
    .await?;
    let etag = response
        .headers()
        .get(ETAG)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned)
        .ok_or_else(|| DaemonError::Server("Commit state response is missing ETag".to_owned()))?;
    let commit_state = decode_server_json(response).await?;
    Ok((commit_state, etag))
}

fn validate_commit_state(
    state: &ServerCommitState,
    etag: &str,
    scope: ServerCommitScope,
    project_id: Option<&str>,
    local_commit_id: Option<&str>,
) -> Result<(), DaemonError> {
    if state.reference.name != MAIN_REF
        || state.reference.scope != scope
        || state.reference.project_id.as_deref() != project_id
    {
        return Err(DaemonError::Server(
            "Server returned a commit state for the wrong Ref".to_owned(),
        ));
    }
    let remote_commit_id = state.reference.commit_id.as_deref();
    if state.update_available != (local_commit_id != remote_commit_id) {
        return Err(DaemonError::Server(
            "Server commit update flag does not match the returned Ref".to_owned(),
        ));
    }
    let expected_etag = remote_commit_id.unwrap_or(EMPTY_GENERATION);
    if etag.trim().trim_matches('"') != expected_etag {
        return Err(DaemonError::Server(
            "Server commit state ETag does not match the returned Ref".to_owned(),
        ));
    }
    match (remote_commit_id, state.latest.as_ref()) {
        (Some(commit_id), Some(latest)) if latest.commit_id == commit_id => {}
        (None, None) => {}
        _ => {
            return Err(DaemonError::Server(
                "Server commit state latest Commit does not match the returned Ref".to_owned(),
            ));
        }
    }
    let expected_download = remote_commit_id.map(|id| format!("/api/v1/commits/{id}"));
    if state.download_url != expected_download {
        return Err(DaemonError::Server(
            "Server commit state download URL does not match the returned Ref".to_owned(),
        ));
    }
    Ok(())
}

async fn install_ref(
    state: &DaemonState,
    commit_state: &ServerCommitState,
    etag: &str,
    materialized_project_id: Option<&str>,
) -> Result<(), DaemonError> {
    let remote_commit_id = commit_state.reference.commit_id.as_deref();
    if let Some(commit_id) = remote_commit_id {
        validate_cache_component("commit_id", commit_id)?;
        let commit_cached = cached_commit_exists(&state.inner.pool, commit_id).await?;
        let generation_ready = match materialized_project_id {
            Some(project_id) => {
                let root = generation_root(&state.inner.config.cache_dir, project_id, commit_id);
                if root.exists() {
                    verify_generation_ref(&root, project_id, Some(commit_id))?;
                    true
                } else {
                    false
                }
            }
            None => true,
        };
        if commit_cached && generation_ready {
            let mut tx = state.inner.pool.begin().await?;
            upsert_ref(&mut tx, &commit_state.reference, etag).await?;
            tx.commit().await?;
            return Ok(());
        }

        let payload: ServerCommitPayload =
            get_server_json(state, &format!("/api/v1/commits/{commit_id}")).await?;
        validate_commit_payload(&payload, commit_state)?;
        if let Some(project_id) = materialized_project_id {
            let cache_dir = state.inner.config.cache_dir.clone();
            let project_id = project_id.to_owned();
            let materialized_payload = payload.clone();
            tokio::task::spawn_blocking(move || {
                ensure_project_generation(&cache_dir, &project_id, &materialized_payload)
            })
            .await
            .map_err(|error| {
                DaemonError::Server(format!("Commit materialization task failed: {error}"))
            })??;
        }

        let mut tx = state.inner.pool.begin().await?;
        cache_commit_payload(&mut tx, &payload).await?;
        upsert_ref(&mut tx, &commit_state.reference, etag).await?;
        tx.commit().await?;
    } else {
        if let Some(project_id) = materialized_project_id {
            let cache_dir = state.inner.config.cache_dir.clone();
            let project_id = project_id.to_owned();
            tokio::task::spawn_blocking(move || ensure_empty_generation(&cache_dir, &project_id))
                .await
                .map_err(|error| {
                    DaemonError::Server(format!("Commit materialization task failed: {error}"))
                })??;
        }
        let mut tx = state.inner.pool.begin().await?;
        upsert_ref(&mut tx, &commit_state.reference, etag).await?;
        tx.commit().await?;
    }
    Ok(())
}

fn validate_commit_payload(
    payload: &ServerCommitPayload,
    state: &ServerCommitState,
) -> Result<(), DaemonError> {
    let latest = state.latest.as_ref().ok_or_else(|| {
        DaemonError::Server("Commit payload was returned for an empty Ref".to_owned())
    })?;
    if &payload.commit != latest
        || payload.commit.tree_id != payload.tree.tree_id
        || payload.commit.scope != state.reference.scope
        || payload.commit.org_id != state.reference.org_id
        || payload.commit.project_id != state.reference.project_id
        || payload.commit.version < 1
        || payload.commit.parent_commit_id.as_deref() == Some(payload.commit.commit_id.as_str())
    {
        return Err(DaemonError::Server(
            "Server returned an inconsistent Commit payload".to_owned(),
        ));
    }

    let mut blobs = HashMap::new();
    for blob in &payload.blobs {
        if blob_object_id(&blob.content) != blob.blob_id {
            return Err(DaemonError::Server(format!(
                "Blob {} failed content-address verification",
                blob.blob_id
            )));
        }
        if blobs.insert(blob.blob_id.as_str(), blob).is_some() {
            return Err(DaemonError::Server(format!(
                "Commit payload contains duplicate Blob {}",
                blob.blob_id
            )));
        }
    }

    let mut entry_ids = BTreeSet::new();
    let mut referenced_blobs = BTreeSet::new();
    let mut selection_blob_id = None;
    for entry in &payload.tree.entries {
        if !entry_ids.insert(entry.id.as_str()) {
            return Err(DaemonError::Server(format!(
                "Tree contains duplicate entry {}",
                entry.id
            )));
        }
        if !blobs.contains_key(entry.blob_id.as_str()) {
            return Err(DaemonError::Server(format!(
                "Tree entry {} references a missing Blob",
                entry.id
            )));
        }
        referenced_blobs.insert(entry.blob_id.as_str());
        validate_tree_entry_ownership(entry, &payload.commit)?;
        if entry.kind == ServerTreeEntryKind::ProjectOrgSelection {
            if selection_blob_id.replace(entry.blob_id.as_str()).is_some() {
                return Err(DaemonError::Server(
                    "Project Commit contains more than one organization selection".to_owned(),
                ));
            }
        } else {
            validate_resource_path(entry)?;
            materialized_resource_content(entry.kind, &blobs[entry.blob_id.as_str()].content)?;
        }
    }
    if referenced_blobs.len() != blobs.len() {
        return Err(DaemonError::Server(
            "Commit payload contains unreferenced Blobs".to_owned(),
        ));
    }

    match payload.commit.scope {
        ServerCommitScope::Project => {
            let project_id = payload.commit.project_id.as_deref().ok_or_else(|| {
                DaemonError::Server("Project Commit is missing project_id".to_owned())
            })?;
            let selection = payload.project_org_selection.as_ref().ok_or_else(|| {
                DaemonError::Server(
                    "Project Commit is missing its organization selection".to_owned(),
                )
            })?;
            let selection_blob_id = selection_blob_id.ok_or_else(|| {
                DaemonError::Server(
                    "Project Commit is missing its organization selection".to_owned(),
                )
            })?;
            let selection_blob = blobs
                .get(selection_blob_id)
                .expect("selection Blob existence was validated");
            let selection_from_blob: serde_json::Value =
                serde_json::from_str(&selection_blob.content).map_err(|error| {
                    DaemonError::Server(format!(
                        "Project organization selection Blob is invalid: {error}"
                    ))
                })?;
            if &selection_from_blob != selection {
                return Err(DaemonError::Server(
                    "Project organization selection does not match its Blob".to_owned(),
                ));
            }
            if selection
                .get("project_id")
                .and_then(serde_json::Value::as_str)
                != Some(project_id)
            {
                return Err(DaemonError::Server(
                    "Project Commit organization selection belongs to another project".to_owned(),
                ));
            }
        }
        ServerCommitScope::Org => {
            if selection_blob_id.is_some() || payload.project_org_selection.is_some() {
                return Err(DaemonError::Server(
                    "Organization Commit contains a project organization selection".to_owned(),
                ));
            }
        }
    }
    Ok(())
}

fn validate_tree_entry_ownership(
    entry: &ServerTreeEntry,
    commit: &ServerCommit,
) -> Result<(), DaemonError> {
    let valid = match (commit.scope, entry.kind, entry.scope) {
        (
            ServerCommitScope::Project,
            ServerTreeEntryKind::ProjectOrgSelection,
            ServerTreeEntryScope::Daemon,
        ) => {
            entry.project_id == commit.project_id
                && entry.path.is_none()
                && entry.source == ServerTreeEntrySource::Config
        }
        (ServerCommitScope::Project, _, ServerTreeEntryScope::Project) => {
            entry.project_id == commit.project_id && entry.source == ServerTreeEntrySource::Project
        }
        (ServerCommitScope::Project, _, ServerTreeEntryScope::Org) => {
            entry.project_id.is_none() && entry.source == ServerTreeEntrySource::SelectedOrg
        }
        (ServerCommitScope::Org, _, ServerTreeEntryScope::Org) => {
            entry.project_id.is_none() && entry.source == ServerTreeEntrySource::Org
        }
        _ => false,
    };
    if !valid {
        return Err(DaemonError::Server(format!(
            "Tree entry {} has an invalid scope, source, or project ownership",
            entry.id
        )));
    }
    Ok(())
}

fn validate_resource_path(entry: &ServerTreeEntry) -> Result<(), DaemonError> {
    let path = entry
        .path
        .as_deref()
        .ok_or_else(|| DaemonError::Server(format!("Tree entry {} is missing a path", entry.id)))?;
    validate_relative_path(path)?;
    match entry.kind {
        ServerTreeEntryKind::Workflow if !path.starts_with("workflow/") => {
            return Err(DaemonError::Server(format!(
                "Workflow Tree entry {} must use the workflow/ path namespace",
                entry.id
            )));
        }
        ServerTreeEntryKind::Rule if path.starts_with("workflow/") => {
            return Err(DaemonError::Server(format!(
                "Rule Tree entry {} cannot use the workflow/ path namespace",
                entry.id
            )));
        }
        ServerTreeEntryKind::Metaprompt if path != "META_PROMPT.md" => {
            return Err(DaemonError::Server(
                "Metaprompt Tree entry must use META_PROMPT.md".to_owned(),
            ));
        }
        _ => {}
    }
    Ok(())
}

fn validate_relative_path(value: &str) -> Result<(), DaemonError> {
    if value.is_empty()
        || Path::new(value)
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(DaemonError::Server(format!(
            "Tree path is not a normalized relative path: {value}"
        )));
    }
    Ok(())
}

async fn cache_commit_payload(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    payload: &ServerCommitPayload,
) -> Result<(), DaemonError> {
    for blob in &payload.blobs {
        let existing: Option<String> =
            sqlx::query_scalar("SELECT content FROM cached_blobs WHERE blob_id = $1")
                .bind(&blob.blob_id)
                .fetch_optional(&mut **tx)
                .await?;
        match existing {
            Some(content) if content != blob.content => {
                return Err(DaemonError::Server(format!(
                    "Cached Blob {} violates immutability",
                    blob.blob_id
                )));
            }
            Some(_) => {}
            None => {
                sqlx::query("INSERT INTO cached_blobs (blob_id, content) VALUES ($1, $2)")
                    .bind(&blob.blob_id)
                    .bind(&blob.content)
                    .execute(&mut **tx)
                    .await?;
            }
        }
    }

    let tree_json = serde_json::to_string(&payload.tree)?;
    let existing_tree: Option<String> =
        sqlx::query_scalar("SELECT payload_json FROM cached_trees WHERE tree_id = $1")
            .bind(&payload.tree.tree_id)
            .fetch_optional(&mut **tx)
            .await?;
    match existing_tree {
        Some(value) if value != tree_json => {
            return Err(DaemonError::Server(format!(
                "Cached Tree {} violates immutability",
                payload.tree.tree_id
            )));
        }
        Some(_) => {}
        None => {
            sqlx::query("INSERT INTO cached_trees (tree_id, payload_json) VALUES ($1, $2)")
                .bind(&payload.tree.tree_id)
                .bind(&tree_json)
                .execute(&mut **tx)
                .await?;
        }
    }
    let commit_json = serde_json::to_string(&payload.commit)?;
    let existing: Option<String> =
        sqlx::query_scalar("SELECT payload_json FROM cached_commits WHERE commit_id = $1")
            .bind(&payload.commit.commit_id)
            .fetch_optional(&mut **tx)
            .await?;
    match existing {
        Some(value) if value != commit_json => {
            return Err(DaemonError::Server(format!(
                "Cached Commit {} violates immutability",
                payload.commit.commit_id
            )));
        }
        Some(_) => {}
        None => {
            sqlx::query(
                "INSERT INTO cached_commits (
                    commit_id, scope, org_id, project_id, tree_id,
                    parent_commit_id, version, created_at, payload_json
                 ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            )
            .bind(&payload.commit.commit_id)
            .bind(payload.commit.scope.as_str())
            .bind(&payload.commit.org_id)
            .bind(&payload.commit.project_id)
            .bind(&payload.commit.tree_id)
            .bind(&payload.commit.parent_commit_id)
            .bind(payload.commit.version)
            .bind(&payload.commit.created_at)
            .bind(commit_json)
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(())
}

async fn upsert_ref(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    reference: &ServerRef,
    etag: &str,
) -> Result<(), DaemonError> {
    let key = match reference.scope {
        ServerCommitScope::Org => org_ref_key(&reference.org_id),
        ServerCommitScope::Project => {
            project_ref_key(reference.project_id.as_deref().ok_or_else(|| {
                DaemonError::Server("Project Ref is missing project_id".to_owned())
            })?)
        }
    };
    sqlx::query(
        "INSERT INTO cached_refs (
            ref_key, name, scope, org_id, project_id, commit_id, etag, server_updated_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT(ref_key) DO UPDATE SET
            name = excluded.name,
            scope = excluded.scope,
            org_id = excluded.org_id,
            project_id = excluded.project_id,
            commit_id = excluded.commit_id,
            etag = excluded.etag,
            server_updated_at = excluded.server_updated_at,
            installed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
    )
    .bind(key)
    .bind(&reference.name)
    .bind(reference.scope.as_str())
    .bind(&reference.org_id)
    .bind(&reference.project_id)
    .bind(&reference.commit_id)
    .bind(etag)
    .bind(&reference.updated_at)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn load_ref_commit(pool: &SqlitePool, key: &str) -> Result<Option<String>, DaemonError> {
    Ok(sqlx::query_scalar::<_, Option<String>>(
        "SELECT commit_id FROM cached_refs WHERE ref_key = $1",
    )
    .bind(key)
    .fetch_optional(pool)
    .await?
    .flatten())
}

async fn ref_exists(pool: &SqlitePool, key: &str) -> Result<bool, DaemonError> {
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cached_refs WHERE ref_key = $1")
        .bind(key)
        .fetch_one(pool)
        .await?;
    Ok(count == 1)
}

async fn cached_commit_exists(pool: &SqlitePool, commit_id: &str) -> Result<bool, DaemonError> {
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cached_commits WHERE commit_id = $1")
        .bind(commit_id)
        .fetch_one(pool)
        .await?;
    Ok(count == 1)
}

fn ensure_project_generation(
    cache_dir: &Path,
    project_id: &str,
    payload: &ServerCommitPayload,
) -> Result<PathBuf, DaemonError> {
    let marker = serde_json::to_vec(payload)?;
    ensure_generation(
        cache_dir,
        project_id,
        &payload.commit.commit_id,
        &marker,
        |root| materialize_payload(root, project_id, payload),
    )
}

fn ensure_empty_generation(cache_dir: &Path, project_id: &str) -> Result<PathBuf, DaemonError> {
    let marker = serde_json::to_vec(&json!({
        "project_id": project_id,
        "commit_id": null
    }))?;
    ensure_generation(cache_dir, project_id, EMPTY_GENERATION, &marker, |root| {
        std::fs::create_dir_all(root.join("cache/rule"))?;
        std::fs::create_dir_all(root.join("cache/context"))?;
        let manifest = MaterializedManifest {
            project_id,
            commit_id: None,
            tree_id: None,
            ref_name: MAIN_REF,
            rules: BTreeMap::new(),
            context: BTreeMap::new(),
        };
        std::fs::write(
            root.join("manifest.json"),
            serde_json::to_vec_pretty(&manifest)?,
        )?;
        Ok(())
    })
}

fn ensure_generation(
    cache_dir: &Path,
    project_id: &str,
    generation: &str,
    marker: &[u8],
    materialize: impl FnOnce(&Path) -> Result<(), DaemonError>,
) -> Result<PathBuf, DaemonError> {
    validate_cache_component("project_id", project_id)?;
    validate_cache_component("generation", generation)?;
    let generations = cache_dir
        .join("projects")
        .join(project_id)
        .join("generations");
    std::fs::create_dir_all(&generations)?;
    let final_root = generations.join(generation);
    if final_root.exists() {
        verify_generation_marker(&final_root, marker)?;
        return Ok(final_root);
    }

    let temporary_root = generations.join(format!(".tmp-{}", Uuid::new_v4().simple()));
    std::fs::create_dir(&temporary_root)?;
    let build_result = (|| {
        materialize(&temporary_root)?;
        std::fs::write(temporary_root.join("commit-payload.json"), marker)?;
        Ok::<(), DaemonError>(())
    })();
    if let Err(error) = build_result {
        let _ = std::fs::remove_dir_all(&temporary_root);
        return Err(error);
    }

    match std::fs::rename(&temporary_root, &final_root) {
        Ok(()) => Ok(final_root),
        Err(error) if final_root.exists() => {
            let _ = std::fs::remove_dir_all(&temporary_root);
            verify_generation_marker(&final_root, marker)?;
            Ok(final_root)
        }
        Err(error) => {
            let _ = std::fs::remove_dir_all(&temporary_root);
            Err(error.into())
        }
    }
}

fn verify_generation_marker(root: &Path, expected: &[u8]) -> Result<(), DaemonError> {
    let actual = std::fs::read(root.join("commit-payload.json"))?;
    if actual != expected {
        return Err(DaemonError::Server(format!(
            "Materialized generation {} violates Commit immutability",
            root.display()
        )));
    }
    Ok(())
}

fn verify_generation_ref(
    root: &Path,
    project_id: &str,
    commit_id: Option<&str>,
) -> Result<(), DaemonError> {
    if !root.is_dir() {
        return Err(DaemonError::Server(format!(
            "Materialized generation {} is missing",
            root.display()
        )));
    }
    let manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.join("manifest.json"))?)?;
    let manifest_commit_matches = match commit_id {
        Some(commit_id) => {
            manifest.get("commit_id").and_then(|value| value.as_str()) == Some(commit_id)
        }
        None => manifest
            .get("commit_id")
            .is_some_and(serde_json::Value::is_null),
    };
    if manifest.get("project_id").and_then(|value| value.as_str()) != Some(project_id)
        || !manifest_commit_matches
        || manifest.get("ref_name").and_then(|value| value.as_str()) != Some(MAIN_REF)
    {
        return Err(DaemonError::Server(format!(
            "Materialized generation {} does not match its Ref",
            root.display()
        )));
    }

    let marker = std::fs::read(root.join("commit-payload.json"))?;
    match commit_id {
        Some(commit_id) => {
            let payload: ServerCommitPayload = serde_json::from_slice(&marker)?;
            if payload.commit.commit_id != commit_id
                || payload.commit.scope != ServerCommitScope::Project
                || payload.commit.project_id.as_deref() != Some(project_id)
                || payload.commit.tree_id != payload.tree.tree_id
            {
                return Err(DaemonError::Server(format!(
                    "Materialized generation {} has an invalid Commit marker",
                    root.display()
                )));
            }
        }
        None => {
            let marker: serde_json::Value = serde_json::from_slice(&marker)?;
            if marker.get("project_id").and_then(|value| value.as_str()) != Some(project_id)
                || !marker
                    .get("commit_id")
                    .is_some_and(serde_json::Value::is_null)
            {
                return Err(DaemonError::Server(format!(
                    "Materialized generation {} has an invalid empty Ref marker",
                    root.display()
                )));
            }
        }
    }
    Ok(())
}

fn materialize_payload(
    root: &Path,
    project_id: &str,
    payload: &ServerCommitPayload,
) -> Result<(), DaemonError> {
    let blobs = payload
        .blobs
        .iter()
        .map(|blob| (blob.blob_id.as_str(), blob))
        .collect::<HashMap<_, _>>();
    let mut rules = BTreeMap::new();
    let mut context = BTreeMap::new();
    let mut output_paths = BTreeSet::new();

    for entry in &payload.tree.entries {
        if entry.kind == ServerTreeEntryKind::ProjectOrgSelection {
            continue;
        }
        let path = entry.path.as_deref().ok_or_else(|| {
            DaemonError::Server(format!("Tree entry {} is missing a path", entry.id))
        })?;
        let blob = blobs.get(entry.blob_id.as_str()).ok_or_else(|| {
            DaemonError::Server(format!("Tree entry {} references a missing Blob", entry.id))
        })?;
        let materialized_content = materialized_resource_content(entry.kind, &blob.content)?;
        let manifest_entry = MaterializedManifestEntry {
            path,
            hash: content_hash(&materialized_content),
            description: "",
        };
        let relative_output = match entry.kind {
            ServerTreeEntryKind::Context => {
                context.insert(entry.id.clone(), manifest_entry);
                PathBuf::from("cache/context").join(path)
            }
            ServerTreeEntryKind::Rule | ServerTreeEntryKind::Workflow => {
                rules.insert(entry.id.clone(), manifest_entry);
                PathBuf::from("cache/rule").join(path)
            }
            ServerTreeEntryKind::Metaprompt => {
                rules.insert(entry.id.clone(), manifest_entry);
                PathBuf::from("cache").join(path)
            }
            ServerTreeEntryKind::ProjectOrgSelection => unreachable!(),
        };
        if !output_paths.insert(relative_output.clone()) {
            return Err(DaemonError::Server(format!(
                "Tree materializes more than one resource at {}",
                relative_output.display()
            )));
        }
        let output = root.join(relative_output);
        if let Some(parent) = output.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(output, materialized_content.as_bytes())?;
    }

    std::fs::create_dir_all(root.join("cache/rule"))?;
    std::fs::create_dir_all(root.join("cache/context"))?;
    let manifest = MaterializedManifest {
        project_id,
        commit_id: Some(&payload.commit.commit_id),
        tree_id: Some(&payload.tree.tree_id),
        ref_name: MAIN_REF,
        rules,
        context,
    };
    std::fs::write(
        root.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;
    Ok(())
}

#[derive(Deserialize)]
struct StructuredRuleBlob {
    format: String,
    content: StructuredRuleContent,
}

#[derive(Deserialize)]
struct StructuredRuleContent {
    name: String,
    applies_when: String,
    constraint: String,
    tags: Vec<String>,
}

#[derive(Deserialize)]
struct StructuredWorkflowBlob {
    format: String,
    content: StructuredWorkflowContent,
}

#[derive(Deserialize)]
struct StructuredWorkflowContent {
    name: String,
    description: String,
    steps: Vec<StructuredWorkflowStep>,
}

#[derive(Deserialize)]
struct StructuredWorkflowStep {
    order: i32,
    rule_id: Option<String>,
    body: Option<String>,
}

fn materialized_resource_content(
    kind: ServerTreeEntryKind,
    blob: &str,
) -> Result<String, DaemonError> {
    match kind {
        ServerTreeEntryKind::Context | ServerTreeEntryKind::Metaprompt => Ok(blob.to_owned()),
        ServerTreeEntryKind::Rule => {
            let decoded: StructuredRuleBlob = serde_json::from_str(blob).map_err(|error| {
                DaemonError::Server(format!("Rule Blob is not canonical JSON: {error}"))
            })?;
            if decoded.format != "clumsies.rule.v1" {
                return Err(DaemonError::Server(format!(
                    "Unsupported Rule Blob format: {}",
                    decoded.format
                )));
            }
            Ok([
                format!("# {}", decoded.content.name),
                String::new(),
                "## Applies when".to_owned(),
                String::new(),
                decoded.content.applies_when,
                String::new(),
                "## Constraint".to_owned(),
                String::new(),
                decoded.content.constraint,
                String::new(),
                format!(
                    "Tags: {}",
                    if decoded.content.tags.is_empty() {
                        "None".to_owned()
                    } else {
                        decoded.content.tags.join(", ")
                    }
                ),
            ]
            .join("\n"))
        }
        ServerTreeEntryKind::Workflow => {
            let decoded: StructuredWorkflowBlob = serde_json::from_str(blob).map_err(|error| {
                DaemonError::Server(format!("Workflow Blob is not canonical JSON: {error}"))
            })?;
            if decoded.format != "clumsies.workflow.v1" {
                return Err(DaemonError::Server(format!(
                    "Unsupported Workflow Blob format: {}",
                    decoded.format
                )));
            }
            let mut lines = vec![
                format!("# {}", decoded.content.name),
                String::new(),
                decoded.content.description,
            ];
            for (index, step) in decoded.content.steps.into_iter().enumerate() {
                let expected_order = i32::try_from(index + 1).map_err(|_| {
                    DaemonError::Server("Workflow Blob contains too many steps".to_owned())
                })?;
                if step.order != expected_order {
                    return Err(DaemonError::Server(
                        "Workflow Blob step order is not contiguous".to_owned(),
                    ));
                }
                let text = match (step.rule_id, step.body) {
                    (Some(rule_id), None) => format!("Apply rule `{rule_id}`."),
                    (None, Some(body)) if !body.trim().is_empty() => body,
                    _ => {
                        return Err(DaemonError::Server(
                            "Workflow Blob step must contain exactly one of rule_id or body"
                                .to_owned(),
                        ));
                    }
                };
                if lines.len() == 3 {
                    lines.push(String::new());
                }
                lines.push(format!("{}. {text}", index + 1));
            }
            Ok(lines.join("\n"))
        }
        ServerTreeEntryKind::ProjectOrgSelection => Err(DaemonError::Server(
            "Project organization selection cannot be materialized as memory".to_owned(),
        )),
    }
}

fn generation_root(cache_dir: &Path, project_id: &str, generation: &str) -> PathBuf {
    cache_dir
        .join("projects")
        .join(project_id)
        .join("generations")
        .join(generation)
}

fn validate_cache_component(label: &str, value: &str) -> Result<(), DaemonError> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
        || value == "."
        || value == ".."
    {
        return Err(DaemonError::InvalidRequest(format!(
            "{label} is not a safe cache path component"
        )));
    }
    Ok(())
}

fn project_ref_key(project_id: &str) -> String {
    format!("project:{project_id}")
}

fn org_ref_key(org_id: &str) -> String {
    format!("org:{org_id}")
}

fn blob_object_id(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"blob");
    hasher.update([0]);
    hasher.update(content.as_bytes());
    hex::encode(hasher.finalize())
}

fn content_hash(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerCommitState {
    update_available: bool,
    #[serde(rename = "ref")]
    reference: ServerRef,
    latest: Option<ServerCommit>,
    download_url: Option<String>,
    incremental_supported: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerRef {
    name: String,
    scope: ServerCommitScope,
    org_id: String,
    project_id: Option<String>,
    commit_id: Option<String>,
    updated_at: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerCommit {
    commit_id: String,
    scope: ServerCommitScope,
    org_id: String,
    project_id: Option<String>,
    tree_id: String,
    parent_commit_id: Option<String>,
    version: i64,
    created_at: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerCommitPayload {
    commit: ServerCommit,
    tree: ServerTree,
    blobs: Vec<ServerBlob>,
    project_org_selection: Option<serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerTree {
    tree_id: String,
    entries: Vec<ServerTreeEntry>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerTreeEntry {
    id: String,
    #[serde(rename = "type")]
    kind: ServerTreeEntryKind,
    scope: ServerTreeEntryScope,
    project_id: Option<String>,
    path: Option<String>,
    blob_id: String,
    source: ServerTreeEntrySource,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ServerBlob {
    blob_id: String,
    content: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ServerCommitScope {
    Org,
    Project,
}

impl ServerCommitScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::Org => "org",
            Self::Project => "project",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ServerTreeEntryKind {
    Rule,
    Context,
    Workflow,
    Metaprompt,
    ProjectOrgSelection,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ServerTreeEntryScope {
    Org,
    Project,
    Daemon,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ServerTreeEntrySource {
    Org,
    Project,
    SelectedOrg,
    Bootstrap,
    Config,
}

#[derive(Serialize)]
struct MaterializedManifest<'a> {
    project_id: &'a str,
    commit_id: Option<&'a str>,
    tree_id: Option<&'a str>,
    ref_name: &'a str,
    rules: BTreeMap<String, MaterializedManifestEntry<'a>>,
    context: BTreeMap<String, MaterializedManifestEntry<'a>>,
}

#[derive(Serialize)]
struct MaterializedManifestEntry<'a> {
    path: &'a str,
    hash: String,
    description: &'a str,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_address_verification_matches_server_blob_ids() {
        assert_eq!(
            blob_object_id("hello"),
            "b7da690ebce9312567657893e936fe6935d0a52372f2703f02616bbd53eccb0c"
        );
        assert_eq!(
            content_hash("hello"),
            "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn rejects_unsafe_cache_components_and_resource_paths() {
        assert!(validate_cache_component("project_id", "project_123").is_ok());
        assert!(validate_cache_component("project_id", "../project").is_err());
        assert!(validate_relative_path("spec/API.md").is_ok());
        assert!(validate_relative_path("../secrets").is_err());
        assert!(validate_relative_path("/absolute").is_err());
    }

    #[test]
    fn materializes_all_memory_resource_kinds() {
        let root = tempfile::tempdir().unwrap();
        let entries = [
            (
                "ctx_test",
                ServerTreeEntryKind::Context,
                ServerTreeEntryScope::Project,
                Some("prj_test"),
                "spec/API.md",
                ServerTreeEntrySource::Project,
                "Context body",
            ),
            (
                "rule_test",
                ServerTreeEntryKind::Rule,
                ServerTreeEntryScope::Org,
                None,
                "coding/STYLE.md",
                ServerTreeEntrySource::SelectedOrg,
                r#"{"format":"clumsies.rule.v1","content":{"name":"Style","applies_when":"While coding","constraint":"Rule body","tags":["coding"]}}"#,
            ),
            (
                "workflow_test",
                ServerTreeEntryKind::Workflow,
                ServerTreeEntryScope::Project,
                Some("prj_test"),
                "workflow/CODING.md",
                ServerTreeEntrySource::Project,
                r#"{"format":"clumsies.workflow.v1","content":{"name":"Coding","description":"Workflow body","steps":[{"order":1,"rule_id":null,"body":"Run tests"}]}}"#,
            ),
            (
                "mpf_test",
                ServerTreeEntryKind::Metaprompt,
                ServerTreeEntryScope::Project,
                Some("prj_test"),
                "META_PROMPT.md",
                ServerTreeEntrySource::Project,
                "Metaprompt body",
            ),
        ];
        let blobs = entries
            .iter()
            .map(|entry| ServerBlob {
                blob_id: blob_object_id(entry.6),
                content: entry.6.to_owned(),
            })
            .collect::<Vec<_>>();
        let tree_entries = entries
            .iter()
            .zip(&blobs)
            .map(|(entry, blob)| ServerTreeEntry {
                id: entry.0.to_owned(),
                kind: entry.1,
                scope: entry.2,
                project_id: entry.3.map(ToOwned::to_owned),
                path: Some(entry.4.to_owned()),
                blob_id: blob.blob_id.clone(),
                source: entry.5,
            })
            .collect();
        let payload = ServerCommitPayload {
            commit: ServerCommit {
                commit_id: "commit_test".to_owned(),
                scope: ServerCommitScope::Project,
                org_id: "org_test".to_owned(),
                project_id: Some("prj_test".to_owned()),
                tree_id: "tree_test".to_owned(),
                parent_commit_id: None,
                version: 1,
                created_at: "2026-07-15T00:00:00Z".to_owned(),
            },
            tree: ServerTree {
                tree_id: "tree_test".to_owned(),
                entries: tree_entries,
            },
            blobs,
            project_org_selection: None,
        };

        materialize_payload(root.path(), "prj_test", &payload).unwrap();

        assert_eq!(
            std::fs::read_to_string(root.path().join("cache/context/spec/API.md")).unwrap(),
            "Context body"
        );
        assert_eq!(
            std::fs::read_to_string(root.path().join("cache/rule/coding/STYLE.md")).unwrap(),
            "# Style\n\n## Applies when\n\nWhile coding\n\n## Constraint\n\nRule body\n\nTags: coding"
        );
        assert_eq!(
            std::fs::read_to_string(root.path().join("cache/rule/workflow/CODING.md")).unwrap(),
            "# Coding\n\nWorkflow body\n\n1. Run tests"
        );
        assert_eq!(
            std::fs::read_to_string(root.path().join("cache/META_PROMPT.md")).unwrap(),
            "Metaprompt body"
        );
    }
}
