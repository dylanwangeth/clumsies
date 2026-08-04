use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Row, SqlitePool};
use toml_edit::{Array, DocumentMut, Item, Table, value};
use uuid::Uuid;

use crate::{
    DaemonError, DaemonState, canonical_server_url, canonical_workspace_directory,
    project_binding_from_row,
};

const ACTIVATE_SKILL_CODEX: &str =
    include_str!("../../../assets/adapters/codex/runtime/skills/activate/SKILL.md");
const NTMD_SKILL_CODEX: &str =
    include_str!("../../../assets/adapters/codex/runtime/skills/ntmd/SKILL.md");
const ACTIVATE_SKILL_CLAUDE: &str =
    include_str!("../../../assets/adapters/claude-code/runtime/skills/activate/SKILL.md");
const NTMD_SKILL_CLAUDE: &str =
    include_str!("../../../assets/adapters/claude-code/runtime/skills/ntmd/SKILL.md");

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ProjectAgentAdapterKind {
    Codex,
    ClaudeCode,
}

impl ProjectAgentAdapterKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectAgentAdapterListRequest {
    pub project_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectAgentAdapterInstallRequest {
    pub project_id: String,
    pub workspace_root: String,
    pub adapter: ProjectAgentAdapterKind,
    pub helper_binary_path: String,
    pub expected_revision: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectAgentAdapterRemoveRequest {
    pub workspace_root: String,
    pub adapter: ProjectAgentAdapterKind,
    pub expected_revision: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectAgentAdapter {
    pub server_url: String,
    pub project_id: String,
    pub workspace_root: String,
    pub adapter: ProjectAgentAdapterKind,
    pub revision: i64,
    pub managed_files: Vec<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectAgentAdapterListResponse {
    pub items: Vec<DaemonProjectAgentAdapter>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonProjectAgentAdapterRemoveResponse {
    pub workspace_root: String,
    pub adapter: ProjectAgentAdapterKind,
    pub removed: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct AdapterManifest {
    helper_binary_hash: String,
    helper_binary_path: String,
    managed_files: Vec<ManagedFile>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct ManagedFile {
    path: String,
    kind: ManagedFileKind,
    installed_hash: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ManagedFileKind {
    CodexConfig,
    ClaudeMcp,
    Exclusive,
}

struct PendingChange {
    path: PathBuf,
    desired: Option<Vec<u8>>,
    kind: ManagedFileKind,
    mode: u32,
}

struct FileBackup {
    path: PathBuf,
    content: Option<Vec<u8>>,
    mode: Option<u32>,
}

pub(crate) async fn migrate(pool: &SqlitePool) -> Result<(), DaemonError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS project_agent_adapters (
            server_url TEXT NOT NULL,
            workspace_root TEXT NOT NULL,
            project_id TEXT NOT NULL,
            adapter TEXT NOT NULL CHECK (adapter IN ('codex', 'claude-code')),
            revision BIGINT NOT NULL CHECK (revision > 0),
            manifest_json TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (server_url, workspace_root, adapter),
            FOREIGN KEY (server_url, workspace_root)
                REFERENCES project_bindings(server_url, workspace_root)
                ON DELETE CASCADE
        )",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "CREATE INDEX IF NOT EXISTS idx_project_agent_adapters_project
         ON project_agent_adapters (server_url, project_id)",
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn list(
    state: &DaemonState,
    request: DaemonProjectAgentAdapterListRequest,
) -> Result<DaemonProjectAgentAdapterListResponse, DaemonError> {
    let project_id = required_value("project_id", request.project_id)?;
    let server_url = canonical_server_url(&state.project_config().server_url)?;
    let rows = sqlx::query(
        "SELECT server_url, workspace_root, project_id, adapter, revision,
                manifest_json, created_at, updated_at
         FROM project_agent_adapters
         WHERE server_url = $1 AND project_id = $2
         ORDER BY workspace_root, adapter",
    )
    .bind(&server_url)
    .bind(&project_id)
    .fetch_all(&state.inner.pool)
    .await?;
    Ok(DaemonProjectAgentAdapterListResponse {
        items: rows
            .iter()
            .map(adapter_from_row)
            .collect::<Result<Vec<_>, _>>()?,
    })
}

pub(crate) async fn install(
    state: &DaemonState,
    request: DaemonProjectAgentAdapterInstallRequest,
) -> Result<DaemonProjectAgentAdapter, DaemonError> {
    let _guard = state.inner.local_setup_lock.lock().await;
    let project_id = required_value("project_id", request.project_id)?;
    let workspace_root = canonical_workspace_directory(&request.workspace_root)?;
    let server_url = canonical_server_url(&state.project_config().server_url)?;
    ensure_binding(&state.inner.pool, &server_url, &workspace_root, &project_id).await?;

    let existing_row = sqlx::query(
        "SELECT server_url, workspace_root, project_id, adapter, revision,
                manifest_json, created_at, updated_at
         FROM project_agent_adapters
         WHERE server_url = $1 AND workspace_root = $2 AND adapter = $3",
    )
    .bind(&server_url)
    .bind(workspace_root.display().to_string())
    .bind(request.adapter.as_str())
    .fetch_optional(&state.inner.pool)
    .await?;
    let existing = existing_row
        .as_ref()
        .map(adapter_record_from_row)
        .transpose()?;
    if let Some(expected_revision) = request.expected_revision {
        if existing.as_ref().map(|record| record.status.revision) != Some(expected_revision) {
            return Err(state_error(
                "project_agent_adapter_changed",
                "The Coding Agent integration changed from the expected revision.",
            ));
        }
    }

    let source_binary = canonical_helper_binary(&request.helper_binary_path)?;
    let helper_binary = state.inner.config.root_dir.join("bin").join("clumsies");
    let helper_hash = sha256_file(&source_binary)?;
    let helper_changed = install_helper_binary(&source_binary, &helper_binary, &helper_hash)?;
    let previous_manifest = existing.as_ref().map(|record| &record.manifest);
    let changes = install_plan(
        request.adapter,
        &workspace_root,
        &helper_binary,
        previous_manifest,
    )?;
    let files_changed = changes.iter().any(change_is_needed);
    let manifest = manifest_for_changes(&changes, &helper_binary, helper_hash);
    let backups = apply_changes(&changes)?;

    let next_revision = match &existing {
        Some(record) if !helper_changed && !files_changed && record.manifest == manifest => {
            record.status.revision
        }
        Some(record) => record.status.revision + 1,
        None => 1,
    };
    let manifest_json = serde_json::to_string(&manifest)?;
    let database_result = async {
        sqlx::query(
            "INSERT INTO project_agent_adapters (
                 server_url, workspace_root, project_id, adapter, revision, manifest_json
             )
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (server_url, workspace_root, adapter) DO UPDATE SET
                 project_id = excluded.project_id,
                 revision = excluded.revision,
                 manifest_json = excluded.manifest_json,
                 updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
        )
        .bind(&server_url)
        .bind(workspace_root.display().to_string())
        .bind(&project_id)
        .bind(request.adapter.as_str())
        .bind(next_revision)
        .bind(manifest_json)
        .execute(&state.inner.pool)
        .await?;
        let row = sqlx::query(
            "SELECT server_url, workspace_root, project_id, adapter, revision,
                    manifest_json, created_at, updated_at
             FROM project_agent_adapters
             WHERE server_url = $1 AND workspace_root = $2 AND adapter = $3",
        )
        .bind(&server_url)
        .bind(workspace_root.display().to_string())
        .bind(request.adapter.as_str())
        .fetch_one(&state.inner.pool)
        .await?;
        adapter_from_row(&row)
    }
    .await;
    if database_result.is_err() {
        rollback_changes(&backups);
    }
    database_result
}

pub(crate) async fn remove(
    state: &DaemonState,
    request: DaemonProjectAgentAdapterRemoveRequest,
) -> Result<DaemonProjectAgentAdapterRemoveResponse, DaemonError> {
    let _guard = state.inner.local_setup_lock.lock().await;
    let workspace_root = canonical_workspace_directory(&request.workspace_root)?;
    let server_url = canonical_server_url(&state.project_config().server_url)?;
    let row = sqlx::query(
        "SELECT server_url, workspace_root, project_id, adapter, revision,
                manifest_json, created_at, updated_at
         FROM project_agent_adapters
         WHERE server_url = $1 AND workspace_root = $2 AND adapter = $3",
    )
    .bind(&server_url)
    .bind(workspace_root.display().to_string())
    .bind(request.adapter.as_str())
    .fetch_optional(&state.inner.pool)
    .await?
    .ok_or_else(|| {
        state_error(
            "project_agent_adapter_not_found",
            "The Coding Agent integration is not installed for this repository.",
        )
    })?;
    let existing = adapter_record_from_row(&row)?;
    if existing.status.revision != request.expected_revision {
        return Err(state_error(
            "project_agent_adapter_changed",
            "The Coding Agent integration changed from the expected revision.",
        ));
    }

    let changes = remove_plan(&existing.manifest)?;
    let backups = apply_changes(&changes)?;
    let delete_result = sqlx::query(
        "DELETE FROM project_agent_adapters
         WHERE server_url = $1 AND workspace_root = $2 AND adapter = $3 AND revision = $4",
    )
    .bind(&server_url)
    .bind(workspace_root.display().to_string())
    .bind(request.adapter.as_str())
    .bind(request.expected_revision)
    .execute(&state.inner.pool)
    .await;
    match delete_result {
        Ok(result) if result.rows_affected() == 1 => {
            cleanup_empty_adapter_directories(&changes, &workspace_root);
            Ok(DaemonProjectAgentAdapterRemoveResponse {
                workspace_root: workspace_root.display().to_string(),
                adapter: request.adapter,
                removed: true,
            })
        }
        Ok(_) => {
            rollback_changes(&backups);
            Err(state_error(
                "project_agent_adapter_changed",
                "The Coding Agent integration changed while it was being removed.",
            ))
        }
        Err(error) => {
            rollback_changes(&backups);
            Err(error.into())
        }
    }
}

async fn ensure_binding(
    pool: &SqlitePool,
    server_url: &str,
    workspace_root: &Path,
    project_id: &str,
) -> Result<(), DaemonError> {
    let row = sqlx::query(
        "SELECT server_url, workspace_root, project_id, revision, created_at, updated_at
         FROM project_bindings
         WHERE server_url = $1 AND workspace_root = $2",
    )
    .bind(server_url)
    .bind(workspace_root.display().to_string())
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| {
        state_error(
            "project_binding_not_found",
            "Bind this repository to the Project before installing a Coding Agent integration.",
        )
    })?;
    let binding = project_binding_from_row(&row)?;
    if binding.project_id != project_id {
        return Err(state_error(
            "project_binding_changed",
            "This repository is bound to a different Project.",
        ));
    }
    Ok(())
}

fn install_plan(
    adapter: ProjectAgentAdapterKind,
    workspace_root: &Path,
    helper_binary: &Path,
    previous_manifest: Option<&AdapterManifest>,
) -> Result<Vec<PendingChange>, DaemonError> {
    let helper = helper_binary.display().to_string();
    let mut changes = match adapter {
        ProjectAgentAdapterKind::Codex => vec![
            PendingChange {
                path: workspace_root.join(".codex/config.toml"),
                desired: Some(render_codex_config(
                    read_optional(&workspace_root.join(".codex/config.toml"))?.as_deref(),
                    &helper,
                )?),
                kind: ManagedFileKind::CodexConfig,
                mode: 0o644,
            },
            exclusive_change(
                workspace_root.join(".agents/skills/activate/SKILL.md"),
                ACTIVATE_SKILL_CODEX.as_bytes(),
                previous_manifest,
            )?,
            exclusive_change(
                workspace_root.join(".agents/skills/ntmd/SKILL.md"),
                NTMD_SKILL_CODEX.as_bytes(),
                previous_manifest,
            )?,
        ],
        ProjectAgentAdapterKind::ClaudeCode => vec![
            PendingChange {
                path: workspace_root.join(".mcp.json"),
                desired: Some(render_claude_mcp(
                    read_optional(&workspace_root.join(".mcp.json"))?.as_deref(),
                    &helper,
                )?),
                kind: ManagedFileKind::ClaudeMcp,
                mode: 0o644,
            },
            exclusive_change(
                workspace_root.join(".claude/skills/activate/SKILL.md"),
                ACTIVATE_SKILL_CLAUDE.as_bytes(),
                previous_manifest,
            )?,
            exclusive_change(
                workspace_root.join(".claude/skills/ntmd/SKILL.md"),
                NTMD_SKILL_CLAUDE.as_bytes(),
                previous_manifest,
            )?,
        ],
    };
    changes.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(changes)
}

fn remove_plan(manifest: &AdapterManifest) -> Result<Vec<PendingChange>, DaemonError> {
    let helper = &manifest.helper_binary_path;
    manifest
        .managed_files
        .iter()
        .map(|file| {
            let path = PathBuf::from(&file.path);
            let current = read_optional(&path)?;
            let desired = match file.kind {
                ManagedFileKind::CodexConfig => current
                    .as_deref()
                    .map(|content| remove_codex_config(content, helper))
                    .transpose()?
                    .flatten(),
                ManagedFileKind::ClaudeMcp => current
                    .as_deref()
                    .map(|content| remove_claude_mcp(content, helper))
                    .transpose()?
                    .flatten(),
                ManagedFileKind::Exclusive => {
                    if let Some(content) = &current {
                        if sha256(content) != file.installed_hash {
                            return Err(state_error(
                                "project_agent_adapter_conflict",
                                &format!(
                                    "{} changed after Clumsies installed it; review it before removing the integration.",
                                    path.display()
                                ),
                            ));
                        }
                    }
                    None
                }
            };
            Ok(PendingChange {
                path,
                desired,
                kind: file.kind,
                mode: 0o644,
            })
        })
        .collect()
}

fn exclusive_change(
    path: PathBuf,
    desired: &[u8],
    previous_manifest: Option<&AdapterManifest>,
) -> Result<PendingChange, DaemonError> {
    if let Some(current) = read_optional(&path)? {
        let current_hash = sha256(&current);
        let previously_managed = previous_manifest
            .and_then(|manifest| {
                manifest
                    .managed_files
                    .iter()
                    .find(|file| Path::new(&file.path) == path)
            })
            .is_some_and(|file| file.installed_hash == current_hash);
        if current != desired && !previously_managed {
            return Err(state_error(
                "project_agent_adapter_conflict",
                &format!(
                    "{} already exists and is not managed by this Clumsies integration.",
                    path.display()
                ),
            ));
        }
    }
    Ok(PendingChange {
        path,
        desired: Some(desired.to_vec()),
        kind: ManagedFileKind::Exclusive,
        mode: 0o644,
    })
}

fn render_codex_config(
    existing: Option<&[u8]>,
    helper_binary: &str,
) -> Result<Vec<u8>, DaemonError> {
    let mut document = match existing {
        Some(content) => std::str::from_utf8(content)
            .map_err(|_| adapter_conflict("The existing Codex config is not UTF-8."))?
            .parse::<DocumentMut>()
            .map_err(|_| adapter_conflict("The existing Codex config is not valid TOML."))?,
        None => DocumentMut::new(),
    };
    if !document.as_table().contains_key("mcp_servers") {
        document["mcp_servers"] = Item::Table(Table::new());
    }
    let servers = document["mcp_servers"]
        .as_table_mut()
        .ok_or_else(|| adapter_conflict("Codex `mcp_servers` must be a TOML table."))?;
    let mut clumsies = Table::new();
    clumsies.insert("command", value(helper_binary));
    let mut args = Array::new();
    args.push("mcp");
    args.push("serve");
    clumsies.insert("args", value(args));
    servers.insert("clumsies", Item::Table(clumsies));
    Ok(document.to_string().into_bytes())
}

fn remove_codex_config(
    content: &[u8],
    helper_binary: &str,
) -> Result<Option<Vec<u8>>, DaemonError> {
    let mut document = std::str::from_utf8(content)
        .map_err(|_| adapter_conflict("The existing Codex config is not UTF-8."))?
        .parse::<DocumentMut>()
        .map_err(|_| adapter_conflict("The existing Codex config is not valid TOML."))?;
    let Some(servers) = document
        .as_table_mut()
        .get_mut("mcp_servers")
        .and_then(Item::as_table_mut)
    else {
        return Ok(Some(content.to_vec()));
    };
    let Some(clumsies) = servers.get("clumsies").and_then(Item::as_table) else {
        return Ok(Some(content.to_vec()));
    };
    let command_matches = clumsies.get("command").and_then(Item::as_str) == Some(helper_binary);
    let args_match = clumsies
        .get("args")
        .and_then(Item::as_array)
        .is_some_and(|args| {
            args.len() == 2
                && args.get(0).and_then(|item| item.as_str()) == Some("mcp")
                && args.get(1).and_then(|item| item.as_str()) == Some("serve")
        });
    if !command_matches || !args_match {
        return Err(adapter_conflict(
            "The Codex `mcp_servers.clumsies` entry changed after installation.",
        ));
    }
    servers.remove("clumsies");
    if servers.is_empty() {
        document.as_table_mut().remove("mcp_servers");
    }
    let rendered = document.to_string();
    Ok((!rendered.trim().is_empty()).then(|| rendered.into_bytes()))
}

fn render_claude_mcp(existing: Option<&[u8]>, helper_binary: &str) -> Result<Vec<u8>, DaemonError> {
    let mut root = match existing {
        Some(content) => serde_json::from_slice::<Value>(content).map_err(|_| {
            adapter_conflict("The existing Claude Code MCP config is not valid JSON.")
        })?,
        None => Value::Object(Map::new()),
    };
    let root = root
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The Claude Code MCP config must be a JSON object."))?;
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("Claude Code `mcpServers` must be a JSON object."))?;
    servers.insert(
        "clumsies".to_owned(),
        json!({
            "type": "stdio",
            "command": helper_binary,
            "args": ["mcp", "serve"]
        }),
    );
    let mut rendered = serde_json::to_vec_pretty(&Value::Object(root.clone()))?;
    rendered.push(b'\n');
    Ok(rendered)
}

fn remove_claude_mcp(content: &[u8], helper_binary: &str) -> Result<Option<Vec<u8>>, DaemonError> {
    let mut root = serde_json::from_slice::<Value>(content)
        .map_err(|_| adapter_conflict("The existing Claude Code MCP config is not valid JSON."))?;
    let object = root
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The Claude Code MCP config must be a JSON object."))?;
    let Some(servers) = object.get_mut("mcpServers").and_then(Value::as_object_mut) else {
        return Ok(Some(content.to_vec()));
    };
    let Some(current) = servers.get("clumsies") else {
        return Ok(Some(content.to_vec()));
    };
    let expected = json!({
        "type": "stdio",
        "command": helper_binary,
        "args": ["mcp", "serve"]
    });
    if current != &expected {
        return Err(adapter_conflict(
            "The Claude Code `mcpServers.clumsies` entry changed after installation.",
        ));
    }
    servers.remove("clumsies");
    if servers.is_empty() {
        object.remove("mcpServers");
    }
    if object.is_empty() {
        return Ok(None);
    }
    let mut rendered = serde_json::to_vec_pretty(&root)?;
    rendered.push(b'\n');
    Ok(Some(rendered))
}

fn manifest_for_changes(
    changes: &[PendingChange],
    helper_binary: &Path,
    helper_binary_hash: String,
) -> AdapterManifest {
    AdapterManifest {
        helper_binary_hash,
        helper_binary_path: helper_binary.display().to_string(),
        managed_files: changes
            .iter()
            .filter_map(|change| {
                change.desired.as_ref().map(|content| ManagedFile {
                    path: change.path.display().to_string(),
                    kind: change.kind,
                    installed_hash: sha256(content),
                })
            })
            .collect(),
    }
}

fn apply_changes(changes: &[PendingChange]) -> Result<Vec<FileBackup>, DaemonError> {
    let mut backups = Vec::with_capacity(changes.len());
    for change in changes {
        let content = read_optional(&change.path)?;
        let mode = file_mode(&change.path)?;
        if content == change.desired {
            continue;
        }
        backups.push(FileBackup {
            path: change.path.clone(),
            content,
            mode,
        });
        let result = match &change.desired {
            Some(content) => atomic_write(&change.path, content, change.mode),
            None => remove_file_if_present(&change.path),
        };
        if let Err(error) = result {
            rollback_changes(&backups);
            return Err(error);
        }
    }
    Ok(backups)
}

fn rollback_changes(backups: &[FileBackup]) {
    for backup in backups.iter().rev() {
        let result = match &backup.content {
            Some(content) => atomic_write(&backup.path, content, backup.mode.unwrap_or(0o644)),
            None => remove_file_if_present(&backup.path),
        };
        if let Err(error) = result {
            eprintln!(
                "failed to roll back adapter file {}: {error}",
                backup.path.display()
            );
        }
    }
}

fn change_is_needed(change: &PendingChange) -> bool {
    read_optional(&change.path)
        .map(|current| current != change.desired)
        .unwrap_or(true)
}

fn atomic_write(path: &Path, content: &[u8], mode: u32) -> Result<(), DaemonError> {
    let parent = path.parent().ok_or_else(|| {
        DaemonError::InvalidRequest(format!("{} has no parent directory", path.display()))
    })?;
    fs::create_dir_all(parent)?;
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("file");
    let temporary = parent.join(format!(".{name}.clumsies-{}.tmp", Uuid::new_v4().simple()));
    fs::write(&temporary, content)?;
    set_mode(&temporary, mode)?;
    fs::rename(&temporary, path)?;
    Ok(())
}

fn remove_file_if_present(path: &Path) -> Result<(), DaemonError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn install_helper_binary(
    source: &Path,
    destination: &Path,
    expected_hash: &str,
) -> Result<bool, DaemonError> {
    if destination.exists() && sha256_file(destination)? == expected_hash {
        return Ok(false);
    }
    let content = fs::read(source)?;
    atomic_write(destination, &content, 0o755)?;
    #[cfg(target_os = "macos")]
    verify_code_signature(destination)?;
    Ok(true)
}

#[cfg(target_os = "macos")]
fn verify_code_signature(path: &Path) -> Result<(), DaemonError> {
    let output = std::process::Command::new("/usr/bin/codesign")
        .arg("--verify")
        .arg("--strict")
        .arg(path)
        .output()?;
    if output.status.success() {
        return Ok(());
    }
    Err(state_error(
        "project_agent_adapter_invalid_helper",
        &format!(
            "The bundled Clumsies MCP executable failed code-signature verification: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ),
    ))
}

fn canonical_helper_binary(path: &str) -> Result<PathBuf, DaemonError> {
    let path = path.trim();
    if path.is_empty() {
        return Err(DaemonError::InvalidRequest(
            "helper_binary_path must not be empty".to_owned(),
        ));
    }
    let canonical = fs::canonicalize(path).map_err(|error| {
        DaemonError::InvalidRequest(format!(
            "helper binary path {path} cannot be resolved: {error}"
        ))
    })?;
    if !canonical.is_file() {
        return Err(DaemonError::InvalidRequest(format!(
            "helper binary path {} is not a file",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, DaemonError> {
    match fs::read(path) {
        Ok(content) => Ok(Some(content)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn sha256_file(path: &Path) -> Result<String, DaemonError> {
    Ok(sha256(&fs::read(path)?))
}

fn sha256(content: &[u8]) -> String {
    hex::encode(Sha256::digest(content))
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<(), DaemonError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<(), DaemonError> {
    Ok(())
}

#[cfg(unix)]
fn file_mode(path: &Path) -> Result<Option<u32>, DaemonError> {
    use std::os::unix::fs::PermissionsExt;
    match fs::metadata(path) {
        Ok(metadata) => Ok(Some(metadata.permissions().mode())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

#[cfg(not(unix))]
fn file_mode(_path: &Path) -> Result<Option<u32>, DaemonError> {
    Ok(None)
}

fn cleanup_empty_adapter_directories(changes: &[PendingChange], workspace_root: &Path) {
    for change in changes.iter().rev() {
        let mut current = change.path.parent();
        while let Some(directory) = current {
            if directory == workspace_root {
                break;
            }
            if fs::remove_dir(directory).is_err() {
                break;
            }
            current = directory.parent();
        }
    }
}

fn adapter_from_row(
    row: &sqlx::sqlite::SqliteRow,
) -> Result<DaemonProjectAgentAdapter, DaemonError> {
    Ok(adapter_record_from_row(row)?.status)
}

struct AdapterRecord {
    status: DaemonProjectAgentAdapter,
    manifest: AdapterManifest,
}

fn adapter_record_from_row(row: &sqlx::sqlite::SqliteRow) -> Result<AdapterRecord, DaemonError> {
    let raw_adapter: String = row.try_get("adapter")?;
    let adapter = match raw_adapter.as_str() {
        "codex" => ProjectAgentAdapterKind::Codex,
        "claude-code" => ProjectAgentAdapterKind::ClaudeCode,
        _ => {
            return Err(DaemonError::InvalidConfig(format!(
                "unknown persisted Coding Agent adapter {raw_adapter}"
            )));
        }
    };
    let manifest: AdapterManifest =
        serde_json::from_str(&row.try_get::<String, _>("manifest_json")?)?;
    Ok(AdapterRecord {
        status: DaemonProjectAgentAdapter {
            server_url: row.try_get("server_url")?,
            project_id: row.try_get("project_id")?,
            workspace_root: row.try_get("workspace_root")?,
            adapter,
            revision: row.try_get("revision")?,
            managed_files: manifest
                .managed_files
                .iter()
                .map(|file| file.path.clone())
                .collect(),
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get("updated_at")?,
        },
        manifest,
    })
}

fn required_value(name: &str, value: String) -> Result<String, DaemonError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(DaemonError::InvalidRequest(format!(
            "{name} must not be empty"
        )));
    }
    Ok(value.to_owned())
}

fn adapter_conflict(message: &str) -> DaemonError {
    state_error("project_agent_adapter_conflict", message)
}

fn state_error(code: &'static str, message: &str) -> DaemonError {
    DaemonError::State {
        code,
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_config_preserves_unrelated_tables() {
        let rendered =
            render_codex_config(Some(b"[model]\nname = \"gpt\"\n"), "/tmp/clumsies").unwrap();
        let text = String::from_utf8(rendered).unwrap();
        assert!(text.contains("[model]"));
        assert!(text.contains("name = \"gpt\""));
        assert!(text.contains("[mcp_servers.clumsies]"));
        assert!(text.contains("command = \"/tmp/clumsies\""));
    }

    #[test]
    fn claude_mcp_preserves_unrelated_servers() {
        let rendered = render_claude_mcp(
            Some(br#"{"mcpServers":{"other":{"command":"other"}}}"#),
            "/tmp/clumsies",
        )
        .unwrap();
        let value: Value = serde_json::from_slice(&rendered).unwrap();
        assert_eq!(value["mcpServers"]["other"]["command"], "other");
        assert_eq!(value["mcpServers"]["clumsies"]["command"], "/tmp/clumsies");
    }
}
