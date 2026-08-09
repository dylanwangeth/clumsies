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
const RESOLVE_BINARY_CODEX: &str =
    include_str!("../../../assets/adapters/codex/runtime/hooks/resolve-binary.sh.tpl");
const ISSUE_RUN_EVENT_CODEX: &str =
    include_str!("../../../assets/adapters/codex/runtime/hooks/issue-run-event.sh.tpl");
const RESOLVE_BINARY_CLAUDE: &str =
    include_str!("../../../assets/adapters/claude-code/runtime/hooks/resolve-binary.sh.tpl");
const ISSUE_RUN_EVENT_CLAUDE: &str =
    include_str!("../../../assets/adapters/claude-code/runtime/hooks/issue-run-event.sh.tpl");
const OPENCODE_PLUGIN: &str = include_str!("../../../assets/adapters/opencode/runtime/plugin.ts");
const LEGACY_USER_PROMPT_SUBMIT_CODEX_SHA256: &str =
    "03bfb5ddbad36dcf53ba3f1e4e07a83cece33d4a98c29298dc0d7e776f63f815";
const LEGACY_USER_PROMPT_SUBMIT_CLAUDE_SHA256: &str =
    "6a2daa1dca1e4ae6ee5c7855bf160418fea46a3ca881c47acdd3f7e7f539aa54";

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ProjectAgentAdapterKind {
    Codex,
    ClaudeCode,
    Opencode,
}

impl ProjectAgentAdapterKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
            Self::Opencode => "opencode",
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
    CodexHooks,
    ClaudeMcp,
    ClaudeSettings,
    OpencodeConfig,
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
            adapter TEXT NOT NULL CHECK (adapter IN ('codex', 'claude-code', 'opencode')),
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
        ProjectAgentAdapterKind::Codex => {
            let hooks_path = workspace_root.join(".codex/hooks.json");
            let hook_script_path = workspace_root.join(".codex/hooks/issue-run-event.sh");
            let legacy_hook_script_path = workspace_root.join(".codex/hooks/user-prompt-submit.sh");
            let hook_ownership = HookOwnership {
                lifecycle: manifest_manages_path(previous_manifest, &hook_script_path),
                legacy_prompt: legacy_hook_is_proven_managed(
                    previous_manifest,
                    &legacy_hook_script_path,
                    LEGACY_USER_PROMPT_SUBMIT_CODEX_SHA256,
                )?,
            };
            let managed_hook = render_managed_hook_script(ISSUE_RUN_EVENT_CODEX, &helper);
            vec![
                PendingChange {
                    path: workspace_root.join(".codex/config.toml"),
                    desired: Some(render_codex_config(
                        read_optional(&workspace_root.join(".codex/config.toml"))?.as_deref(),
                        &helper,
                    )?),
                    kind: ManagedFileKind::CodexConfig,
                    mode: 0o644,
                },
                PendingChange {
                    path: hooks_path.clone(),
                    desired: Some(render_hook_registry(
                        read_optional(&hooks_path)?.as_deref(),
                        &hook_script_path,
                        false,
                        hook_ownership,
                    )?),
                    kind: ManagedFileKind::CodexHooks,
                    mode: 0o644,
                },
                exclusive_change(
                    workspace_root.join(".codex/hooks/resolve-binary.sh"),
                    RESOLVE_BINARY_CODEX.as_bytes(),
                    previous_manifest,
                    0o755,
                )?,
                exclusive_change(
                    hook_script_path,
                    managed_hook.as_bytes(),
                    previous_manifest,
                    0o755,
                )?,
                exclusive_change(
                    workspace_root.join(".agents/skills/activate/SKILL.md"),
                    ACTIVATE_SKILL_CODEX.as_bytes(),
                    previous_manifest,
                    0o644,
                )?,
                exclusive_change(
                    workspace_root.join(".agents/skills/ntmd/SKILL.md"),
                    NTMD_SKILL_CODEX.as_bytes(),
                    previous_manifest,
                    0o644,
                )?,
            ]
        }
        ProjectAgentAdapterKind::ClaudeCode => {
            let settings_path = workspace_root.join(".claude/settings.json");
            let hook_script_path = workspace_root.join(".claude/hooks/issue-run-event.sh");
            let legacy_hook_script_path =
                workspace_root.join(".claude/hooks/user-prompt-submit.sh");
            let hook_ownership = HookOwnership {
                lifecycle: manifest_manages_path(previous_manifest, &hook_script_path),
                legacy_prompt: legacy_hook_is_proven_managed(
                    previous_manifest,
                    &legacy_hook_script_path,
                    LEGACY_USER_PROMPT_SUBMIT_CLAUDE_SHA256,
                )?,
            };
            let managed_hook = render_managed_hook_script(ISSUE_RUN_EVENT_CLAUDE, &helper);
            vec![
                PendingChange {
                    path: workspace_root.join(".mcp.json"),
                    desired: Some(render_claude_mcp(
                        read_optional(&workspace_root.join(".mcp.json"))?.as_deref(),
                        &helper,
                    )?),
                    kind: ManagedFileKind::ClaudeMcp,
                    mode: 0o644,
                },
                PendingChange {
                    path: settings_path.clone(),
                    desired: Some(render_hook_registry(
                        read_optional(&settings_path)?.as_deref(),
                        &hook_script_path,
                        true,
                        hook_ownership,
                    )?),
                    kind: ManagedFileKind::ClaudeSettings,
                    mode: 0o644,
                },
                exclusive_change(
                    workspace_root.join(".claude/hooks/resolve-binary.sh"),
                    RESOLVE_BINARY_CLAUDE.as_bytes(),
                    previous_manifest,
                    0o755,
                )?,
                exclusive_change(
                    hook_script_path,
                    managed_hook.as_bytes(),
                    previous_manifest,
                    0o755,
                )?,
                exclusive_change(
                    workspace_root.join(".claude/skills/activate/SKILL.md"),
                    ACTIVATE_SKILL_CLAUDE.as_bytes(),
                    previous_manifest,
                    0o644,
                )?,
                exclusive_change(
                    workspace_root.join(".claude/skills/ntmd/SKILL.md"),
                    NTMD_SKILL_CLAUDE.as_bytes(),
                    previous_manifest,
                    0o644,
                )?,
            ]
        }
        ProjectAgentAdapterKind::Opencode => {
            let config_path = workspace_root.join("opencode.json");
            let plugin_path = workspace_root.join(".opencode/plugins/clumsies.ts");
            vec![
                PendingChange {
                    path: config_path.clone(),
                    desired: Some(render_opencode_config(
                        read_optional(&config_path)?.as_deref(),
                        &helper,
                    )?),
                    kind: ManagedFileKind::OpencodeConfig,
                    mode: 0o644,
                },
                exclusive_change(
                    plugin_path,
                    render_opencode_plugin(&helper).as_bytes(),
                    previous_manifest,
                    0o644,
                )?,
            ]
        }
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
                ManagedFileKind::CodexHooks => current
                    .as_deref()
                    .map(|content| {
                        remove_hook_registry(
                            content,
                            &path
                                .parent()
                                .unwrap_or(Path::new("."))
                                .join("hooks/issue-run-event.sh"),
                            false,
                        )
                    })
                    .transpose()?
                    .flatten(),
                ManagedFileKind::ClaudeMcp => current
                    .as_deref()
                    .map(|content| remove_claude_mcp(content, helper))
                    .transpose()?
                    .flatten(),
                ManagedFileKind::ClaudeSettings => current
                    .as_deref()
                    .map(|content| {
                        remove_hook_registry(
                            content,
                            &path
                                .parent()
                                .unwrap_or(Path::new("."))
                                .join("hooks/issue-run-event.sh"),
                            true,
                        )
                    })
                    .transpose()?
                    .flatten(),
                ManagedFileKind::OpencodeConfig => current
                    .as_deref()
                    .map(|content| remove_opencode_config(content, helper))
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
    mode: u32,
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
        mode,
    })
}

fn manifest_manages_path(manifest: Option<&AdapterManifest>, path: &Path) -> bool {
    manifest.is_some_and(|manifest| {
        manifest
            .managed_files
            .iter()
            .any(|file| Path::new(&file.path) == path)
    })
}

fn legacy_hook_is_proven_managed(
    manifest: Option<&AdapterManifest>,
    path: &Path,
    known_hash: &str,
) -> Result<bool, DaemonError> {
    let Some(content) = read_optional(path)? else {
        return Ok(false);
    };
    let current_hash = sha256(&content);
    if current_hash == known_hash {
        return Ok(true);
    }
    Ok(manifest.is_some_and(|manifest| {
        manifest
            .managed_files
            .iter()
            .any(|file| Path::new(&file.path) == path && file.installed_hash == current_hash)
    }))
}

const BASE_AGENT_RUN_HOOKS: [(&str, u64); 5] = [
    ("UserPromptSubmit", 5),
    ("Stop", 5),
    ("SubagentStart", 5),
    ("SubagentStop", 5),
    ("SessionEnd", 3),
];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct HookOwnership {
    lifecycle: bool,
    legacy_prompt: bool,
}

fn render_managed_hook_script(template: &str, helper_binary: &str) -> String {
    let injected = format!(
        "export CLUMSIES_ADAPTER_BINARY={}\n",
        shell_single_quote(helper_binary)
    );
    match template.find('\n') {
        Some(index) => {
            let mut rendered = String::with_capacity(template.len() + injected.len());
            rendered.push_str(&template[..=index]);
            rendered.push_str(&injected);
            rendered.push_str(&template[index + 1..]);
            rendered
        }
        None => format!("{template}\n{injected}"),
    }
}

fn render_hook_registry(
    existing: Option<&[u8]>,
    script_path: &Path,
    include_stop_failure: bool,
    ownership: HookOwnership,
) -> Result<Vec<u8>, DaemonError> {
    let mut root = match existing {
        Some(content) => serde_json::from_slice::<Value>(content)
            .map_err(|_| adapter_conflict("The existing hook registry is not valid JSON."))?,
        None => Value::Object(Map::new()),
    };
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The hook registry must be a JSON object."))?;
    let hooks = root_object
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The hook registry `hooks` value must be an object."))?;

    for &(event, timeout) in &BASE_AGENT_RUN_HOOKS {
        install_hook_handler(hooks, event, timeout, script_path, ownership)?;
    }
    if include_stop_failure {
        install_hook_handler(hooks, "StopFailure", 5, script_path, ownership)?;
    }

    render_json(&root)
}

fn install_hook_handler(
    hooks: &mut Map<String, Value>,
    event: &str,
    timeout: u64,
    script_path: &Path,
    ownership: HookOwnership,
) -> Result<(), DaemonError> {
    let groups = hooks
        .entry(event)
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| {
            adapter_conflict(&format!(
                "The hook registry `{event}` value must be an array."
            ))
        })?;
    remove_owned_hook_handlers(groups, script_path, timeout, ownership)?;
    groups.push(json!({
        "hooks": [{
            "type": "command",
            "command": hook_command(script_path),
            "timeout": timeout
        }]
    }));
    Ok(())
}

fn remove_hook_registry(
    content: &[u8],
    script_path: &Path,
    include_stop_failure: bool,
) -> Result<Option<Vec<u8>>, DaemonError> {
    let mut root = serde_json::from_slice::<Value>(content)
        .map_err(|_| adapter_conflict("The existing hook registry is not valid JSON."))?;
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The hook registry must be a JSON object."))?;
    let Some(hooks) = root_object.get_mut("hooks").and_then(Value::as_object_mut) else {
        return Ok(Some(content.to_vec()));
    };

    let mut events = BASE_AGENT_RUN_HOOKS
        .iter()
        .map(|(event, _)| *event)
        .collect::<Vec<_>>();
    if include_stop_failure {
        events.push("StopFailure");
    }
    for event in events {
        let Some(groups) = hooks.get_mut(event).and_then(Value::as_array_mut) else {
            continue;
        };
        remove_owned_hook_handlers(
            groups,
            script_path,
            timeout_for_event(event),
            HookOwnership {
                lifecycle: true,
                legacy_prompt: false,
            },
        )?;
        if groups.is_empty() {
            hooks.remove(event);
        }
    }
    if hooks.is_empty() {
        root_object.remove("hooks");
    }
    if root_object.is_empty() {
        return Ok(None);
    }
    Ok(Some(render_json(&root)?))
}

fn timeout_for_event(event: &str) -> u64 {
    BASE_AGENT_RUN_HOOKS
        .iter()
        .find_map(|(candidate, timeout)| (*candidate == event).then_some(*timeout))
        .unwrap_or(5)
}

fn remove_owned_hook_handlers(
    groups: &mut Vec<Value>,
    script_path: &Path,
    lifecycle_timeout: u64,
    ownership: HookOwnership,
) -> Result<(), DaemonError> {
    let legacy_path = script_path
        .parent()
        .unwrap_or(Path::new("."))
        .join("user-prompt-submit.sh");
    let mut lifecycle_exact = Vec::new();
    let mut lifecycle_drifted = false;
    let mut legacy_exact = Vec::new();
    let mut legacy_drifted = false;

    for (index, group) in groups.iter().enumerate() {
        if group_contains_local_hook_kind(group, script_path, LocalHookScriptKind::Lifecycle) {
            if is_exact_command_group(group, script_path, lifecycle_timeout) {
                lifecycle_exact.push(index);
            } else {
                lifecycle_drifted = true;
            }
        }
        if group_contains_local_hook_kind(group, script_path, LocalHookScriptKind::LegacyPrompt) {
            if is_exact_command_group(group, &legacy_path, 5) {
                legacy_exact.push(index);
            } else {
                legacy_drifted = true;
            }
        }
    }

    if (!lifecycle_exact.is_empty() || lifecycle_drifted) && !ownership.lifecycle {
        return Err(adapter_conflict(
            "The lifecycle hook path is already registered but is not owned by this Clumsies integration.",
        ));
    }
    if ownership.lifecycle && (lifecycle_drifted || lifecycle_exact.len() > 1) {
        return Err(adapter_conflict(
            "The managed lifecycle hook group changed after installation.",
        ));
    }
    if ownership.legacy_prompt && (legacy_drifted || legacy_exact.len() > 1) {
        return Err(adapter_conflict(
            "The managed legacy prompt hook group changed after installation.",
        ));
    }

    let mut indexes_to_remove = Vec::with_capacity(2);
    if ownership.lifecycle {
        indexes_to_remove.extend(lifecycle_exact);
    }
    if ownership.legacy_prompt {
        indexes_to_remove.extend(legacy_exact);
    }
    indexes_to_remove.sort_unstable_by(|left, right| right.cmp(left));
    indexes_to_remove.dedup();
    for index in indexes_to_remove {
        groups.remove(index);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LocalHookScriptKind {
    Lifecycle,
    LegacyPrompt,
}

fn local_hook_script_kind(handler: &Value, script_path: &Path) -> Option<LocalHookScriptKind> {
    let Some(object) = handler.as_object() else {
        return None;
    };
    if object.get("type").and_then(Value::as_str) != Some("command") {
        return None;
    }
    let Some(command) = object.get("command").and_then(Value::as_str) else {
        return None;
    };
    let command_path = single_bash_script_path(command)?;
    let candidate = Path::new(&command_path);
    let expected_hooks_directory = script_path.parent()?;
    if candidate.parent()? != expected_hooks_directory {
        return None;
    }
    match candidate.file_name().and_then(|name| name.to_str()) {
        Some("issue-run-event.sh") => Some(LocalHookScriptKind::Lifecycle),
        Some("user-prompt-submit.sh") => Some(LocalHookScriptKind::LegacyPrompt),
        _ => None,
    }
}

fn group_contains_local_hook_kind(
    group: &Value,
    script_path: &Path,
    expected: LocalHookScriptKind,
) -> bool {
    group
        .as_object()
        .and_then(|object| object.get("hooks"))
        .and_then(Value::as_array)
        .is_some_and(|handlers| {
            handlers
                .iter()
                .any(|handler| local_hook_script_kind(handler, script_path) == Some(expected))
        })
}

fn is_exact_command_group(group: &Value, script_path: &Path, timeout: u64) -> bool {
    let Some(object) = group.as_object() else {
        return false;
    };
    if object.len() != 1 {
        return false;
    }
    let Some(handlers) = object.get("hooks").and_then(Value::as_array) else {
        return false;
    };
    handlers.len() == 1 && is_exact_command_handler(&handlers[0], script_path, timeout)
}

fn is_exact_command_handler(handler: &Value, script_path: &Path, timeout: u64) -> bool {
    let Some(object) = handler.as_object() else {
        return false;
    };
    if object.len() != 3
        || object.get("type").and_then(Value::as_str) != Some("command")
        || object.get("timeout").and_then(Value::as_u64) != Some(timeout)
    {
        return false;
    }
    let Some(command) = object.get("command").and_then(Value::as_str) else {
        return false;
    };
    single_bash_script_path(command).is_some_and(|path| Path::new(&path) == script_path)
}

fn single_bash_script_path(command: &str) -> Option<String> {
    let command = command.trim();
    let rest = command.strip_prefix("bash")?;
    if !rest.chars().next().is_some_and(char::is_whitespace) {
        return None;
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Quote {
        None,
        Single,
        Double,
    }

    let mut quote = Quote::None;
    let mut escaped = false;
    let mut path = String::new();
    let mut chars = rest.trim_start().chars();
    while let Some(character) = chars.next() {
        if escaped {
            path.push(character);
            escaped = false;
            continue;
        }
        match quote {
            Quote::Single => {
                if character == '\'' {
                    quote = Quote::None;
                } else {
                    path.push(character);
                }
            }
            Quote::Double => match character {
                '"' => quote = Quote::None,
                '\\' => escaped = true,
                '$' | '`' => return None,
                _ => path.push(character),
            },
            Quote::None => match character {
                '\'' => quote = Quote::Single,
                '"' => quote = Quote::Double,
                '\\' => escaped = true,
                character if character.is_whitespace() => {
                    if chars.all(|remaining| remaining.is_whitespace()) {
                        break;
                    }
                    return None;
                }
                '$' | '`' | ';' | '|' | '&' | '<' | '>' => return None,
                _ => path.push(character),
            },
        }
    }
    (quote == Quote::None && !escaped && !path.is_empty()).then_some(path)
}

fn hook_command(script_path: &Path) -> String {
    format!(
        "bash {}",
        shell_single_quote(&script_path.display().to_string())
    )
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn render_json(value: &Value) -> Result<Vec<u8>, DaemonError> {
    let mut rendered = serde_json::to_vec_pretty(value)?;
    rendered.push(b'\n');
    Ok(rendered)
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

/// opencode.json merge: register the clumsies MCP server under `mcp` and
/// append the clumsies plugin to the `plugin` array. User-owned keys and
/// other servers/plugins are preserved.
fn render_opencode_config(
    existing: Option<&[u8]>,
    helper_binary: &str,
) -> Result<Vec<u8>, DaemonError> {
    let mut root = match existing {
        Some(content) => serde_json::from_slice::<Value>(content).map_err(|_| {
            adapter_conflict("The existing opencode config is not valid JSON.")
        })?,
        None => Value::Object(Map::new()),
    };
    let root = root
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The opencode config must be a JSON object."))?;

    let mcp = root
        .entry("mcp")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("opencode `mcp` must be a JSON object."))?;
    mcp.insert(
        "clumsies".to_owned(),
        json!({
            "type": "local",
            "command": [helper_binary, "mcp", "serve"],
            "enabled": true
        }),
    );

    const PLUGIN_SPEC: &str = "./.opencode/plugins/clumsies.ts";
    let plugins = root
        .entry("plugin")
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| adapter_conflict("opencode `plugin` must be an array."))?;
    if !plugins
        .iter()
        .any(|item| item.as_str() == Some(PLUGIN_SPEC))
    {
        plugins.push(Value::String(PLUGIN_SPEC.to_owned()));
    }

    let mut rendered = serde_json::to_vec_pretty(&Value::Object(root.clone()))?;
    rendered.push(b'\n');
    Ok(rendered)
}

fn remove_opencode_config(
    content: &[u8],
    helper_binary: &str,
) -> Result<Option<Vec<u8>>, DaemonError> {
    let mut root = serde_json::from_slice::<Value>(content)
        .map_err(|_| adapter_conflict("The existing opencode config is not valid JSON."))?;
    let root = root
        .as_object_mut()
        .ok_or_else(|| adapter_conflict("The opencode config must be a JSON object."))?;

    if let Some(mcp) = root.get_mut("mcp").and_then(Value::as_object_mut) {
        if let Some(current) = mcp.get("clumsies") {
            let expected = json!({
                "type": "local",
                "command": [helper_binary, "mcp", "serve"],
                "enabled": true
            });
            if current != &expected {
                return Err(adapter_conflict(
                    "The opencode `mcp.clumsies` entry changed after installation.",
                ));
            }
            mcp.remove("clumsies");
        }
        if mcp.is_empty() {
            root.remove("mcp");
        }
    }

    if let Some(plugins) = root.get_mut("plugin").and_then(Value::as_array_mut) {
        plugins.retain(|item| item.as_str() != Some("./.opencode/plugins/clumsies.ts"));
        if plugins.is_empty() {
            root.remove("plugin");
        }
    }

    if root.is_empty() {
        return Ok(None);
    }
    let mut rendered = serde_json::to_vec_pretty(&Value::Object(root.clone()))?;
    rendered.push(b'\n');
    Ok(Some(rendered))
}

/// Injects the managed helper binary path into the plugin template so the
/// plugin can reach the daemon bridge without relying on PATH.
fn render_opencode_plugin(helper_binary: &str) -> String {
    OPENCODE_PLUGIN.replace("__CLUMSIES_HELPER_BINARY__", helper_binary)
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
            tracing::error!(
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
        "opencode" => ProjectAgentAdapterKind::Opencode,
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

    fn hook_commands<'a>(registry: &'a Value, event: &str) -> Vec<&'a str> {
        registry["hooks"][event]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|group| group.get("hooks").and_then(Value::as_array))
            .flatten()
            .filter_map(|handler| handler.get("command").and_then(Value::as_str))
            .collect()
    }

    fn assert_hook_registry_migration(
        script: &Path,
        host_directory: &str,
        foreign_host_directory: &str,
        include_stop_failure: bool,
    ) {
        let current_command = hook_command(script);
        let current_legacy = format!(
            "bash \"{}\"",
            script
                .parent()
                .unwrap()
                .join("user-prompt-submit.sh")
                .display()
        );
        let foreign_lifecycle =
            format!("bash \"/old/workspace/{host_directory}/hooks/issue-run-event.sh\"");
        let foreign_legacy =
            format!("bash '/old/workspace/{host_directory}/hooks/user-prompt-submit.sh'");
        let foreign_known =
            format!("bash \"/old/workspace/{foreign_host_directory}/hooks/user-prompt-submit.sh\"");
        let foreign_same_host = format!("bash \"/opt/tools/{host_directory}/hooks/custom.sh\"");

        let mut hooks = Map::new();
        hooks.insert(
            "UserPromptSubmit".to_owned(),
            json!([
                {
                    "hooks": [
                        {"type": "command", "command": current_legacy, "timeout": 5}
                    ]
                },
                {
                    "hooks": [
                        {"type": "command", "command": foreign_legacy},
                        {"type": "command", "command": foreign_known},
                        {"type": "command", "command": foreign_same_host},
                        {"type": "command", "command": "echo foreign"}
                    ]
                }
            ]),
        );
        hooks.insert(
            "Stop".to_owned(),
            json!([
                {"hooks": [{"type": "command", "command": current_command, "timeout": 5}]},
                {"hooks": [{"type": "command", "command": foreign_lifecycle}]},
                {"hooks": [{"type": "command", "command": "echo stop foreign"}]}
            ]),
        );
        if include_stop_failure {
            hooks.insert(
                "StopFailure".to_owned(),
                json!([{
                    "hooks": [
                        {"type": "command", "command": foreign_lifecycle},
                        {"type": "command", "command": "echo failure foreign"}
                    ]
                }]),
            );
        }
        let existing = render_json(&json!({"theme": "dark", "hooks": hooks})).unwrap();

        let first = render_hook_registry(
            Some(&existing),
            script,
            include_stop_failure,
            HookOwnership {
                lifecycle: true,
                legacy_prompt: true,
            },
        )
        .unwrap();
        let second = render_hook_registry(
            Some(&first),
            script,
            include_stop_failure,
            HookOwnership {
                lifecycle: true,
                legacy_prompt: false,
            },
        )
        .unwrap();
        let rendered: Value = serde_json::from_slice(&second).unwrap();
        for &(event, _) in &BASE_AGENT_RUN_HOOKS {
            assert_eq!(
                hook_commands(&rendered, event)
                    .iter()
                    .filter(|command| **command == current_command)
                    .count(),
                1,
                "{event} should contain one current lifecycle handler"
            );
        }
        if include_stop_failure {
            assert_eq!(
                hook_commands(&rendered, "StopFailure")
                    .iter()
                    .filter(|command| **command == current_command)
                    .count(),
                1
            );
        } else {
            assert!(rendered["hooks"].get("StopFailure").is_none());
        }
        let prompt_commands = hook_commands(&rendered, "UserPromptSubmit");
        assert!(!prompt_commands.contains(&current_legacy.as_str()));
        assert!(prompt_commands.contains(&foreign_legacy.as_str()));
        assert!(prompt_commands.contains(&foreign_known.as_str()));
        assert!(prompt_commands.contains(&foreign_same_host.as_str()));
        assert!(prompt_commands.contains(&"echo foreign"));
        let stop_commands = hook_commands(&rendered, "Stop");
        assert!(stop_commands.contains(&foreign_lifecycle.as_str()));
        assert!(stop_commands.contains(&"echo stop foreign"));
        if include_stop_failure {
            let failure_commands = hook_commands(&rendered, "StopFailure");
            assert!(failure_commands.contains(&foreign_lifecycle.as_str()));
            assert!(failure_commands.contains(&"echo failure foreign"));
        }

        let removed = remove_hook_registry(&second, script, include_stop_failure)
            .unwrap()
            .unwrap();
        let removed: Value = serde_json::from_slice(&removed).unwrap();
        assert_eq!(removed["theme"], "dark");
        let prompt_commands = hook_commands(&removed, "UserPromptSubmit");
        assert!(!prompt_commands.contains(&current_legacy.as_str()));
        assert!(prompt_commands.contains(&foreign_legacy.as_str()));
        assert!(prompt_commands.contains(&foreign_known.as_str()));
        assert!(prompt_commands.contains(&foreign_same_host.as_str()));
        assert!(prompt_commands.contains(&"echo foreign"));
        let stop_commands = hook_commands(&removed, "Stop");
        assert!(!stop_commands.contains(&current_command.as_str()));
        assert!(stop_commands.contains(&foreign_lifecycle.as_str()));
        assert!(stop_commands.contains(&"echo stop foreign"));
        if include_stop_failure {
            assert_eq!(
                hook_commands(&removed, "StopFailure"),
                vec![foreign_lifecycle.as_str(), "echo failure foreign"]
            );
        }
    }

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

    #[test]
    fn codex_hooks_retire_proven_legacy_without_touching_foreign_handlers() {
        let script = Path::new("/tmp/workspace/.codex/hooks/issue-run-event.sh");
        assert_hook_registry_migration(script, ".codex", ".claude", false);
    }

    #[test]
    fn claude_hooks_retire_proven_legacy_without_touching_foreign_handlers() {
        let script = Path::new("/tmp/workspace/.claude/hooks/issue-run-event.sh");
        assert_hook_registry_migration(script, ".claude", ".codex", true);
    }

    #[test]
    fn managed_hook_script_prefers_the_desktop_helper() {
        let rendered = render_managed_hook_script(
            "#!/usr/bin/env bash\nsource resolver.sh\n",
            "/tmp/Clumsies App/bin/clumsies",
        );
        assert!(rendered.starts_with(
            "#!/usr/bin/env bash\nexport CLUMSIES_ADAPTER_BINARY='/tmp/Clumsies App/bin/clumsies'\n"
        ));
    }

    #[test]
    fn install_plan_includes_lifecycle_assets_for_both_hosts() {
        let workspace = tempfile::tempdir().unwrap();
        let helper = Path::new("/tmp/clumsies-managed/bin/clumsies");

        let codex = install_plan(
            ProjectAgentAdapterKind::Codex,
            workspace.path(),
            helper,
            None,
        )
        .unwrap();
        assert!(codex.iter().any(|change| {
            change.path.ends_with(".codex/hooks.json") && change.kind == ManagedFileKind::CodexHooks
        }));
        assert!(codex.iter().any(|change| {
            change.path.ends_with(".codex/hooks/issue-run-event.sh") && change.mode == 0o755
        }));

        let claude = install_plan(
            ProjectAgentAdapterKind::ClaudeCode,
            workspace.path(),
            helper,
            None,
        )
        .unwrap();
        assert!(claude.iter().any(|change| {
            change.path.ends_with(".claude/settings.json")
                && change.kind == ManagedFileKind::ClaudeSettings
        }));
        assert!(claude.iter().any(|change| {
            change.path.ends_with(".claude/hooks/issue-run-event.sh") && change.mode == 0o755
        }));
    }

    #[test]
    fn lifecycle_migration_does_not_claim_or_delete_unowned_legacy_scripts() {
        let helper = Path::new("/tmp/clumsies-managed/bin/clumsies");
        for (adapter, legacy_relative_path, registry_relative_path) in [
            (
                ProjectAgentAdapterKind::Codex,
                ".codex/hooks/user-prompt-submit.sh",
                ".codex/hooks.json",
            ),
            (
                ProjectAgentAdapterKind::ClaudeCode,
                ".claude/hooks/user-prompt-submit.sh",
                ".claude/settings.json",
            ),
        ] {
            let workspace = tempfile::tempdir().unwrap();
            let legacy_path = workspace.path().join(legacy_relative_path);
            let registry_path = workspace.path().join(registry_relative_path);
            fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
            fs::write(&legacy_path, b"#!/bin/sh\necho user-owned\n").unwrap();
            let legacy_command = hook_command(&legacy_path);
            fs::write(
                &registry_path,
                render_json(&json!({
                    "hooks": {
                        "UserPromptSubmit": [{
                            "hooks": [{
                                "type": "command",
                                "command": legacy_command,
                                "timeout": 5
                            }]
                        }]
                    }
                }))
                .unwrap(),
            )
            .unwrap();

            let changes = install_plan(adapter, workspace.path(), helper, None).unwrap();
            assert!(changes.iter().all(|change| change.path != legacy_path));
            apply_changes(&changes).unwrap();
            assert_eq!(
                fs::read(&legacy_path).unwrap(),
                b"#!/bin/sh\necho user-owned\n"
            );
            let installed_registry: Value =
                serde_json::from_slice(&fs::read(&registry_path).unwrap()).unwrap();
            assert!(
                hook_commands(&installed_registry, "UserPromptSubmit")
                    .contains(&legacy_command.as_str())
            );

            let manifest = manifest_for_changes(&changes, helper, "helper-hash".to_owned());
            let removals = remove_plan(&manifest).unwrap();
            assert!(removals.iter().all(|change| change.path != legacy_path));
            apply_changes(&removals).unwrap();
            assert_eq!(
                fs::read(&legacy_path).unwrap(),
                b"#!/bin/sh\necho user-owned\n"
            );
            let removed_registry: Value =
                serde_json::from_slice(&fs::read(&registry_path).unwrap()).unwrap();
            assert!(
                hook_commands(&removed_registry, "UserPromptSubmit")
                    .contains(&legacy_command.as_str())
            );
        }
    }

    #[test]
    fn managed_lifecycle_wrapper_drift_conflicts_without_mutating_the_group() {
        let script = Path::new("/tmp/workspace/.codex/hooks/issue-run-event.sh");
        let command = hook_command(script);
        for group in [
            json!({
                "matcher": "special",
                "hooks": [{"type": "command", "command": command, "timeout": 5}]
            }),
            json!({
                "hooks": [
                    {"type": "command", "command": command, "timeout": 5},
                    {"type": "command", "command": "echo user-owned"}
                ]
            }),
        ] {
            let original = group.clone();
            let mut groups = vec![group];
            let error = remove_owned_hook_handlers(
                &mut groups,
                script,
                5,
                HookOwnership {
                    lifecycle: true,
                    legacy_prompt: false,
                },
            )
            .unwrap_err();
            assert!(matches!(error, DaemonError::State { .. }));
            assert_eq!(groups, vec![original]);
        }
    }

    #[test]
    fn opencode_config_preserves_unrelated_keys_and_servers() {
        let rendered = render_opencode_config(
            Some(
                br#"{"model":"deepseek/deepseek-chat","mcp":{"other":{"type":"remote","url":"https://x"}}}"#,
            ),
            "/tmp/clumsies",
        )
        .unwrap();
        let value: Value = serde_json::from_slice(&rendered).unwrap();
        assert_eq!(value["model"], "deepseek/deepseek-chat");
        assert_eq!(value["mcp"]["other"]["url"], "https://x");
        assert_eq!(value["mcp"]["clumsies"]["type"], "local");
        assert_eq!(value["mcp"]["clumsies"]["command"][0], "/tmp/clumsies");
        assert_eq!(value["mcp"]["clumsies"]["command"][1], "mcp");
        assert_eq!(value["mcp"]["clumsies"]["enabled"], true);
        assert!(value["plugin"]
            .as_array()
            .unwrap()
            .contains(&Value::String("./.opencode/plugins/clumsies.ts".to_owned())));
    }

    #[test]
    fn opencode_config_render_is_idempotent() {
        let first = render_opencode_config(None, "/tmp/clumsies").unwrap();
        let second = render_opencode_config(Some(&first), "/tmp/clumsies").unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn opencode_config_remove_restores_user_content() {
        let rendered = render_opencode_config(
            Some(br#"{"model":"deepseek/deepseek-chat"}"#),
            "/tmp/clumsies",
        )
        .unwrap();
        let removed = remove_opencode_config(&rendered, "/tmp/clumsies")
            .unwrap()
            .unwrap();
        let value: Value = serde_json::from_slice(&removed).unwrap();
        assert_eq!(value["model"], "deepseek/deepseek-chat");
        assert!(value.get("mcp").is_none());
        assert!(value.get("plugin").is_none());
    }

    #[test]
    fn opencode_remove_rejects_drifted_clumsies_entry() {
        let rendered = render_opencode_config(None, "/tmp/clumsies").unwrap();
        let mutated = render_opencode_config(
            Some(&rendered),
            "/tmp/some-other-helper",
        )
        .unwrap();
        let error = remove_opencode_config(&mutated, "/tmp/clumsies").unwrap_err();
        assert!(matches!(error, DaemonError::State { .. }));
    }

    #[test]
    fn opencode_plugin_template_injects_helper_binary() {
        let rendered = render_opencode_plugin("/tmp/Clumsies App/bin/clumsies");
        assert!(rendered.contains(
            "return process.env.CLUMSIES_BINARY || \"/tmp/Clumsies App/bin/clumsies\""
        ));
    }

    #[test]
    fn install_plan_includes_opencode_assets() {
        let workspace = tempfile::tempdir().unwrap();
        let helper = Path::new("/tmp/clumsies-managed/bin/clumsies");

        let changes = install_plan(
            ProjectAgentAdapterKind::Opencode,
            workspace.path(),
            helper,
            None,
        )
        .unwrap();
        assert!(changes.iter().any(|change| {
            change.path.ends_with("opencode.json")
                && change.kind == ManagedFileKind::OpencodeConfig
        }));
        assert!(changes.iter().any(|change| {
            change.path.ends_with(".opencode/plugins/clumsies.ts")
                && change.kind == ManagedFileKind::Exclusive
        }));
    }

    #[test]
    fn opencode_install_remove_round_trip() {
        let workspace = tempfile::tempdir().unwrap();
        let helper = Path::new("/tmp/clumsies-managed/bin/clumsies");

        let changes = install_plan(
            ProjectAgentAdapterKind::Opencode,
            workspace.path(),
            helper,
            None,
        )
        .unwrap();
        apply_changes(&changes).unwrap();

        let config_path = workspace.path().join("opencode.json");
        let config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        assert_eq!(config["mcp"]["clumsies"]["command"][0], "/tmp/clumsies-managed/bin/clumsies");
        assert!(config["plugin"]
            .as_array()
            .unwrap()
            .contains(&Value::String("./.opencode/plugins/clumsies.ts".to_owned())));
        assert!(
            workspace
                .path()
                .join(".opencode/plugins/clumsies.ts")
                .exists()
        );

        let manifest = manifest_for_changes(&changes, helper, "helper-hash".to_owned());
        let removals = remove_plan(&manifest).unwrap();
        apply_changes(&removals).unwrap();
        assert!(!config_path.exists());
        assert!(!workspace.path().join(".opencode/plugins/clumsies.ts").exists());
    }
}
