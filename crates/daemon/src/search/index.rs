use std::path::Path;
use std::str::FromStr;

use sha2::{Digest, Sha256};
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{Sqlite, SqlitePool, Transaction};

use super::chunker::build_units;
use super::{
    DaemonError, EffectiveMemory, PARSER_VERSION, RANKING_CONFIG_VERSION, RetrievalUnit,
    SEARCH_SCHEMA_VERSION, SearchFailure, SearchModels, SourceResource,
};

#[derive(Clone, Debug)]
pub(super) struct BuiltUnit {
    pub(super) resource_index: usize,
    pub(super) unit: RetrievalUnit,
    vector: Vec<f32>,
}

pub(super) const INDEX_EMBED_BATCH_SIZE: usize = 32;

pub(super) async fn connect_project_index(path: &Path) -> Result<SqlitePool, DaemonError> {
    if let Some(parent) = path.parent() {
        crate::project_storage::ensure_private_directory(parent)?;
    }
    let options = SqliteConnectOptions::from_str(&path.display().to_string())?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal);
    let pool = SqlitePoolOptions::new()
        .max_connections(3)
        .connect_with(options)
        .await?;
    migrate_project_index(&pool).await?;
    crate::project_storage::secure_managed_tree(path.parent().unwrap_or(path))?;
    Ok(pool)
}

async fn migrate_project_index(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS search_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    let existing: Option<String> =
        sqlx::query_scalar("SELECT value FROM search_meta WHERE key = 'schema_version'")
            .fetch_optional(pool)
            .await?;
    let expected_version = SEARCH_SCHEMA_VERSION.to_string();
    if existing.as_deref() != Some(expected_version.as_str()) {
        let mut tx = pool.begin().await?;
        for statement in [
            "DROP TABLE IF EXISTS search_units_fts",
            "DROP TABLE IF EXISTS search_heads",
            "DROP TABLE IF EXISTS search_units",
            "DROP TABLE IF EXISTS search_resources",
            "DROP TABLE IF EXISTS search_revisions",
        ] {
            sqlx::query(statement).execute(&mut *tx).await?;
        }
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
        "INSERT INTO search_meta (key, value) VALUES ('schema_version', $1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )
    .bind(SEARCH_SCHEMA_VERSION.to_string())
    .execute(pool)
    .await?;
    Ok(())
}

pub(super) async fn ensure_index(
    state: &super::DaemonState,
    pool: &SqlitePool,
    effective: &EffectiveMemory,
) -> Result<String, DaemonError> {
    match state.inner.search_models.status() {
        super::SearchModelRuntimeStatus::Missing => {
            return Err(SearchFailure::model_preparing(
                "search models are waiting for background preparation",
            )
            .into());
        }
        super::SearchModelRuntimeStatus::Preparing {
            downloaded_bytes,
            total_bytes,
        } => {
            return Err(SearchFailure::model_preparing(format!(
                "search models are preparing ({downloaded_bytes}/{total_bytes} bytes)"
            ))
            .into());
        }
        super::SearchModelRuntimeStatus::Failed => {
            return Err(SearchFailure::model(
                "search model preparation failed and will retry in the background",
            )
            .into());
        }
        super::SearchModelRuntimeStatus::Ready => {}
    }
    let models = state.inner.search_models.clone();
    let model_revision = super::run_model_work(move || models.revision()).await?;
    let revision_id = index_revision_id(&effective.effective_hash, &model_revision);
    let existing: Option<i64> = sqlx::query_scalar(
        "SELECT COUNT(*)
         FROM search_heads h
         JOIN search_revisions r ON r.revision_id = h.revision_id
         WHERE h.project_id = $1 AND h.revision_id = $2 AND r.status = 'ready'",
    )
    .bind(&effective.project_id)
    .bind(&revision_id)
    .fetch_optional(pool)
    .await?;
    if existing.unwrap_or_default() == 1 {
        return Ok(revision_id);
    }

    let resources = effective.resources.clone();
    let models = state.inner.search_models.clone();
    let built =
        match super::run_model_work(move || build_index_units(&resources, models.as_ref())).await {
            Ok(built) => built,
            Err(error) => {
                let _ = record_failed_index(
                    pool,
                    effective,
                    &revision_id,
                    &model_revision,
                    &error.to_string(),
                )
                .await;
                return Err(error);
            }
        };
    let current = super::load_effective_memory(state, &effective.project_id).await?;
    if current.effective_hash != effective.effective_hash {
        return Err(SearchFailure::generation_changed(
            "Commit or Draft state changed while the search index was being built",
        )
        .into());
    }
    if let Err(error) = install_index(
        pool,
        effective,
        &revision_id,
        &model_revision,
        &built,
        state.inner.search_models.dimensions(),
    )
    .await
    {
        let _ = record_failed_index(
            pool,
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

pub(super) fn build_index_units(
    resources: &[SourceResource],
    models: &dyn SearchModels,
) -> Result<Vec<BuiltUnit>, SearchFailure> {
    let mut built = Vec::new();
    let mut pending = Vec::with_capacity(INDEX_EMBED_BATCH_SIZE);
    for (resource_index, resource) in resources.iter().enumerate() {
        for unit in build_units(resource, models)? {
            pending.push((resource_index, unit));
            if pending.len() == INDEX_EMBED_BATCH_SIZE {
                embed_pending_units(resources, models, &mut pending, &mut built)?;
            }
        }
    }
    embed_pending_units(resources, models, &mut pending, &mut built)?;
    Ok(built)
}

fn embed_pending_units(
    resources: &[SourceResource],
    models: &dyn SearchModels,
    pending: &mut Vec<(usize, RetrievalUnit)>,
    built: &mut Vec<BuiltUnit>,
) -> Result<(), SearchFailure> {
    if pending.is_empty() {
        return Ok(());
    }
    let passages = pending
        .iter()
        .map(|(resource_index, unit)| {
            let resource = &resources[*resource_index];
            format!(
                "{}\n{}\n{}",
                resource.path,
                unit.heading_path.join(" > "),
                unit.text
            )
        })
        .collect::<Vec<_>>();
    let embeddings = models.embed_passages(&passages)?;
    if embeddings.len() != pending.len() {
        return Err(SearchFailure::vector(format!(
            "embedding count {} does not match unit count {}",
            embeddings.len(),
            pending.len()
        )));
    }
    built.extend(
        pending
            .drain(..)
            .zip(embeddings)
            .map(|((resource_index, unit), vector)| BuiltUnit {
                resource_index,
                unit,
                vector,
            }),
    );
    Ok(())
}

pub(super) fn index_revision_id(effective_hash: &str, model_revision: &str) -> String {
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
    if units.iter().any(|built| {
        built.vector.len() != dimensions
            || !valid_normalized_vector(&built.vector)
            || effective
                .resources
                .get(built.resource_index)
                .is_none_or(|resource| resource.resource_id != built.unit.resource_id)
    }) {
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

    for resource in effective.resources.iter() {
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
        let resource = &effective.resources[built.resource_index];
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
        .bind(&resource.path)
        .bind(&resource.title)
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

pub(super) async fn delete_revision(
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

pub(super) async fn delete_project_index(
    pool: &SqlitePool,
    project_id: &str,
) -> Result<(), DaemonError> {
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

pub(super) fn decode_vector(bytes: &[u8], dimensions: usize) -> Result<Vec<f32>, SearchFailure> {
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

pub(super) fn valid_normalized_vector(vector: &[f32]) -> bool {
    if vector.is_empty() || vector.iter().any(|value| !value.is_finite()) {
        return false;
    }
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    norm.is_finite() && (norm - 1.0).abs() <= 0.01
}
