use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::DaemonError;
use crate::project_storage::{ensure_private_directory, write_private_file};

#[cfg(target_os = "macos")]
use super::code_signature_info;
use super::{DaemonCodexPluginStatus, is_executable, shell_single_quote, state_error};

const MARKETPLACE_NAME: &str = "clumsies-local";
const PLUGIN_ID: &str = "clumsies@clumsies-local";
#[cfg(target_os = "macos")]
const CODEX_SIGNING_IDENTIFIER: &str = "codex";
#[cfg(target_os = "macos")]
const OPENAI_TEAM_IDENTIFIER: &str = "2DC432GLL2";
const CLI_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_CLI_OUTPUT_BYTES: usize = 1024 * 1024;

const PLUGIN_MANIFEST: &str =
    include_str!("../../../../packages/clumsies/.codex-plugin/plugin.json");
const MCP_TEMPLATE: &str = include_str!("../../../../packages/clumsies/.mcp.json.tpl");
const HOOKS: &str = include_str!("../../../../packages/clumsies/hooks/hooks.json");
const HOOK_SCRIPT_TEMPLATE: &str =
    include_str!("../../../../packages/clumsies/scripts/issue-run-event.sh.tpl");
const BOOTSTRAP_SKILL: &str =
    include_str!("../../../../packages/clumsies/skills/clumsies/SKILL.md");

struct MaterializedPlugin {
    marketplace_root: PathBuf,
    version: String,
}

#[derive(Debug, Deserialize)]
struct MarketplaceList {
    #[serde(default)]
    marketplaces: Vec<MarketplaceEntry>,
}

#[derive(Debug, Deserialize)]
struct MarketplaceEntry {
    name: String,
    #[serde(default)]
    root: String,
    #[serde(default, rename = "marketplaceSource")]
    marketplace_source: Option<MarketplaceSource>,
}

#[derive(Debug, Deserialize)]
struct MarketplaceSource {
    #[serde(rename = "sourceType")]
    source_type: String,
    source: String,
}

#[derive(Debug, Deserialize)]
struct PluginList {
    #[serde(default)]
    installed: Vec<PluginEntry>,
}

#[derive(Debug, Deserialize)]
struct PluginEntry {
    #[serde(rename = "pluginId")]
    plugin_id: String,
    version: String,
    installed: bool,
    enabled: bool,
}

pub(super) async fn ensure_installed(
    daemon_root: &Path,
    runtime_binary: &Path,
    runtime_hash: &str,
    host_binary_path: Option<&str>,
) -> Result<(), DaemonError> {
    let host_binary_path = host_binary_path.ok_or_else(|| {
        DaemonError::InvalidRequest(
            "host_binary_path must identify the installed Codex App CLI".to_owned(),
        )
    })?;
    let codex = canonical_codex_cli(host_binary_path)?;
    verify_codex_cli(&codex)?;
    let plugin = materialize(daemon_root, runtime_binary, runtime_hash)?;
    ensure_marketplace(&codex, &plugin.marketplace_root).await?;
    ensure_plugin(&codex, &plugin.version).await
}

pub(super) async fn inspect(
    daemon_root: &Path,
    runtime_binary: &Path,
    runtime_hash: &str,
    host_binary_path: Option<&str>,
) -> Result<DaemonCodexPluginStatus, DaemonError> {
    let expected_version = plugin_version(
        runtime_binary.to_str().ok_or_else(|| {
            DaemonError::InvalidRequest("Codex plugin runtime path is not UTF-8".to_owned())
        })?,
        runtime_hash,
    );
    let Some(host_binary_path) = host_binary_path else {
        return Ok(DaemonCodexPluginStatus {
            host_installed: false,
            marketplace_installed: false,
            marketplace_conflict: false,
            plugin_installed: false,
            plugin_enabled: false,
            installed_version: None,
            expected_version,
            ready: false,
        });
    };
    let codex = canonical_codex_cli(host_binary_path)?;
    verify_codex_cli(&codex)?;
    let marketplace_root = daemon_root.join("agent-plugins/codex-marketplace");
    inspect_verified(&codex, &marketplace_root, expected_version).await
}

async fn inspect_verified(
    codex: &Path,
    marketplace_root: &Path,
    expected_version: String,
) -> Result<DaemonCodexPluginStatus, DaemonError> {
    let marketplaces = marketplace_list(codex).await?;
    let marketplace = marketplaces
        .marketplaces
        .iter()
        .find(|entry| entry.name == MARKETPLACE_NAME);
    let marketplace_installed =
        marketplace.is_some_and(|entry| marketplace_matches(entry, marketplace_root));
    let marketplace_conflict = marketplace.is_some() && !marketplace_installed;
    let plugin = if marketplace_installed {
        plugin_list(codex)
            .await?
            .installed
            .into_iter()
            .find(|entry| entry.plugin_id == PLUGIN_ID)
    } else {
        None
    };
    let plugin_installed = plugin.as_ref().is_some_and(|entry| entry.installed);
    let plugin_enabled = plugin.as_ref().is_some_and(|entry| entry.enabled);
    let installed_version = plugin.map(|entry| entry.version);
    let ready = marketplace_installed
        && plugin_installed
        && plugin_enabled
        && installed_version.as_deref() == Some(expected_version.as_str());
    Ok(DaemonCodexPluginStatus {
        host_installed: true,
        marketplace_installed,
        marketplace_conflict,
        plugin_installed,
        plugin_enabled,
        installed_version,
        expected_version,
        ready,
    })
}

fn materialize(
    daemon_root: &Path,
    runtime_binary: &Path,
    runtime_hash: &str,
) -> Result<MaterializedPlugin, DaemonError> {
    if runtime_hash.len() != 64 || !runtime_hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(DaemonError::InvalidConfig(
            "Codex plugin runtime identity is invalid".to_owned(),
        ));
    }
    let runtime_path = runtime_binary.to_str().ok_or_else(|| {
        DaemonError::InvalidRequest("Codex plugin runtime path is not UTF-8".to_owned())
    })?;
    let marketplace_root = daemon_root.join("agent-plugins/codex-marketplace");
    let plugin_root = marketplace_root.join("plugins/clumsies");
    for directory in [
        marketplace_root.join(".agents/plugins"),
        plugin_root.join(".codex-plugin"),
        plugin_root.join("hooks"),
        plugin_root.join("scripts"),
        plugin_root.join("skills/clumsies"),
    ] {
        ensure_private_directory(&directory)?;
    }

    let version = plugin_version(runtime_path, runtime_hash);
    let mut manifest: Value = serde_json::from_str(PLUGIN_MANIFEST)?;
    manifest["version"] = Value::String(version.clone());
    manifest["mcpServers"] = Value::String("./.mcp.json".to_owned());
    write_json(&plugin_root.join(".codex-plugin/plugin.json"), &manifest)?;

    let mut mcp: Value = serde_json::from_str(MCP_TEMPLATE)?;
    mcp["mcpServers"]["clumsies"]["command"] = Value::String(runtime_path.to_owned());
    write_json(&plugin_root.join(".mcp.json"), &mcp)?;
    write_private_file(&plugin_root.join("hooks/hooks.json"), HOOKS.as_bytes())?;
    let hook_script = HOOK_SCRIPT_TEMPLATE.replace(
        "__CLUMSIESD_SHELL_LITERAL_REQUIRED__",
        &shell_single_quote(runtime_path),
    );
    if hook_script.contains("__CLUMSIESD_SHELL_LITERAL_REQUIRED__") {
        return Err(DaemonError::InvalidConfig(
            "Codex plugin Hook template was not materialized".to_owned(),
        ));
    }
    write_private_file(
        &plugin_root.join("scripts/issue-run-event.sh"),
        hook_script.as_bytes(),
    )?;
    write_private_file(
        &plugin_root.join("skills/clumsies/SKILL.md"),
        BOOTSTRAP_SKILL.as_bytes(),
    )?;

    write_json(
        &marketplace_root.join(".agents/plugins/marketplace.json"),
        &json!({
            "name": MARKETPLACE_NAME,
            "interface": { "displayName": "Clumsies Local" },
            "plugins": [{
                "name": "clumsies",
                "source": { "source": "local", "path": "./plugins/clumsies" },
                "policy": {
                    "installation": "AVAILABLE",
                    "authentication": "ON_INSTALL"
                },
                "category": "Productivity"
            }]
        }),
    )?;

    Ok(MaterializedPlugin {
        marketplace_root,
        version,
    })
}

fn plugin_version(runtime_path: &str, runtime_hash: &str) -> String {
    let mut digest = Sha256::new();
    for component in [
        b"clumsies-codex-plugin-v1".as_slice(),
        runtime_hash.as_bytes(),
        runtime_path.as_bytes(),
        PLUGIN_MANIFEST.as_bytes(),
        MCP_TEMPLATE.as_bytes(),
        HOOKS.as_bytes(),
        HOOK_SCRIPT_TEMPLATE.as_bytes(),
        BOOTSTRAP_SKILL.as_bytes(),
    ] {
        digest.update((component.len() as u64).to_be_bytes());
        digest.update(component);
    }
    let identity = hex::encode(digest.finalize());
    format!("0.1.0+codex.{}", &identity[..16])
}

fn write_json(path: &Path, value: &Value) -> Result<(), DaemonError> {
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    write_private_file(path, &bytes)
}

async fn ensure_marketplace(codex: &Path, marketplace_root: &Path) -> Result<(), DaemonError> {
    let observed = marketplace_list(codex).await?;
    match observed
        .marketplaces
        .iter()
        .find(|entry| entry.name == MARKETPLACE_NAME)
    {
        Some(entry) if marketplace_matches(entry, marketplace_root) => return Ok(()),
        Some(_) => {
            return Err(state_error(
                "codex_plugin_conflict",
                "Codex already has a different marketplace named clumsies-local.",
            ));
        }
        None => {}
    }

    let source = marketplace_root.to_str().ok_or_else(|| {
        DaemonError::InvalidRequest("Codex plugin marketplace path is not UTF-8".to_owned())
    })?;
    run_cli_json(codex, &["plugin", "marketplace", "add", source, "--json"]).await?;
    let observed = marketplace_list(codex).await?;
    if observed
        .marketplaces
        .iter()
        .any(|entry| entry.name == MARKETPLACE_NAME && marketplace_matches(entry, marketplace_root))
    {
        Ok(())
    } else {
        Err(state_error(
            "codex_plugin_install_failed",
            "Codex did not retain the Clumsies marketplace after installation.",
        ))
    }
}

async fn marketplace_list(codex: &Path) -> Result<MarketplaceList, DaemonError> {
    serde_json::from_value(run_cli_json(codex, &["plugin", "marketplace", "list", "--json"]).await?)
        .map_err(Into::into)
}

async fn ensure_plugin(codex: &Path, version: &str) -> Result<(), DaemonError> {
    if plugin_installed_and_enabled(&plugin_list(codex).await?, version) {
        return Ok(());
    }
    run_cli_json(codex, &["plugin", "add", PLUGIN_ID, "--json"]).await?;
    if plugin_installed_and_enabled(&plugin_list(codex).await?, version) {
        Ok(())
    } else {
        Err(state_error(
            "codex_plugin_install_failed",
            "Codex did not enable the expected Clumsies plugin version.",
        ))
    }
}

async fn plugin_list(codex: &Path) -> Result<PluginList, DaemonError> {
    serde_json::from_value(
        run_cli_json(
            codex,
            &[
                "plugin",
                "list",
                "--marketplace",
                MARKETPLACE_NAME,
                "--available",
                "--json",
            ],
        )
        .await?,
    )
    .map_err(Into::into)
}

fn plugin_installed_and_enabled(list: &PluginList, version: &str) -> bool {
    list.installed.iter().any(|entry| {
        entry.plugin_id == PLUGIN_ID && entry.version == version && entry.installed && entry.enabled
    })
}

async fn run_cli_json(codex: &Path, args: &[&str]) -> Result<Value, DaemonError> {
    let mut command = tokio::process::Command::new(codex);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = tokio::time::timeout(CLI_TIMEOUT, command.output())
        .await
        .map_err(|_| {
            state_error(
                "codex_plugin_timeout",
                "Codex did not finish the plugin operation in time.",
            )
        })??;
    if output.stdout.len() > MAX_CLI_OUTPUT_BYTES || output.stderr.len() > MAX_CLI_OUTPUT_BYTES {
        return Err(state_error(
            "codex_plugin_output_too_large",
            "Codex returned an unexpectedly large plugin response.",
        ));
    }
    if !output.status.success() {
        return Err(state_error(
            "codex_plugin_install_failed",
            "Codex could not install the Clumsies plugin. Open Codex once, then retry the integration.",
        ));
    }
    serde_json::from_slice(&output.stdout).map_err(|_| {
        state_error(
            "codex_plugin_invalid_response",
            "Codex returned an invalid plugin response.",
        )
    })
}

fn canonical_paths_match(left: &Path, right: &Path) -> bool {
    fs::canonicalize(left)
        .ok()
        .zip(fs::canonicalize(right).ok())
        .is_some_and(|(left, right)| left == right)
}

fn marketplace_matches(entry: &MarketplaceEntry, marketplace_root: &Path) -> bool {
    match &entry.marketplace_source {
        Some(source) => {
            source.source_type == "local"
                && canonical_paths_match(Path::new(&source.source), marketplace_root)
        }
        None => canonical_paths_match(Path::new(&entry.root), marketplace_root),
    }
}

fn canonical_codex_cli(path: &str) -> Result<PathBuf, DaemonError> {
    let path = path.trim();
    if path.is_empty() {
        return Err(DaemonError::InvalidRequest(
            "host_binary_path must identify the installed Codex App CLI".to_owned(),
        ));
    }
    let canonical = fs::canonicalize(path).map_err(|error| {
        DaemonError::InvalidRequest(format!("Codex CLI path {path} cannot be resolved: {error}"))
    })?;
    if !canonical.is_file()
        || !canonical.ends_with("Contents/Resources/codex")
        || !is_executable(&canonical)?
    {
        return Err(DaemonError::InvalidRequest(format!(
            "Codex CLI path {} is not an App-bundled executable",
            canonical.display()
        )));
    }
    Ok(canonical)
}

#[cfg(target_os = "macos")]
fn verify_codex_cli(path: &Path) -> Result<(), DaemonError> {
    let output = std::process::Command::new("/usr/bin/codesign")
        .arg("--verify")
        .arg("--strict")
        .arg(path)
        .output()?;
    let info = code_signature_info(path)?;
    if !output.status.success()
        || info.identifier != CODEX_SIGNING_IDENTIFIER
        || info.team_identifier.as_deref() != Some(OPENAI_TEAM_IDENTIFIER)
        || info.ad_hoc
        || !info.hardened_runtime
    {
        return Err(state_error(
            "codex_plugin_invalid_host",
            "The selected Codex CLI does not have the required OpenAI signing identity.",
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn verify_codex_cli(_path: &Path) -> Result<(), DaemonError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn materialized_plugin_pins_runtime_and_keeps_memory_skills_remote() {
        let root = tempfile::tempdir().unwrap();
        let runtime = Path::new("/Applications/Clumsies.app/Contents/Resources/clumsiesd");
        let plugin = materialize(root.path(), runtime, &"a".repeat(64)).unwrap();
        assert!(plugin.version.starts_with("0.1.0+codex."));
        let moved_root = tempfile::tempdir().unwrap();
        let moved = materialize(
            moved_root.path(),
            Path::new("/Users/test/Applications/Clumsies.app/Contents/Resources/clumsiesd"),
            &"a".repeat(64),
        )
        .unwrap();
        assert_ne!(plugin.version, moved.version);

        let plugin_root = plugin.marketplace_root.join("plugins/clumsies");
        let mcp: Value =
            serde_json::from_slice(&fs::read(plugin_root.join(".mcp.json")).unwrap()).unwrap();
        assert_eq!(
            mcp["mcpServers"]["clumsies"]["command"],
            runtime.display().to_string()
        );
        assert_eq!(
            mcp["mcpServers"]["clumsies"]["args"],
            json!([
                "mcp",
                "serve",
                "--host",
                "codex",
                "--delivery",
                "host-plugin"
            ])
        );
        let skill = fs::read_to_string(plugin_root.join("skills/clumsies/SKILL.md")).unwrap();
        assert!(skill.contains("skill stored in Memory as ordinary Memory content"));
        assert!(!plugin_root.join("skills/coding").exists());
        let hooks = fs::read_to_string(plugin_root.join("hooks/hooks.json")).unwrap();
        assert!(hooks.contains("${PLUGIN_ROOT}/scripts/issue-run-event.sh"));
    }

    #[test]
    fn exact_installed_plugin_state_is_required() {
        let ready = PluginList {
            installed: vec![PluginEntry {
                plugin_id: PLUGIN_ID.to_owned(),
                version: "0.1.0+codex.abc".to_owned(),
                installed: true,
                enabled: true,
            }],
        };
        assert!(plugin_installed_and_enabled(&ready, "0.1.0+codex.abc"));
        assert!(!plugin_installed_and_enabled(&ready, "0.1.0+codex.def"));
    }

    #[tokio::test]
    async fn inspection_without_codex_is_read_only() {
        let root = tempfile::tempdir().unwrap();
        let status = inspect(
            root.path(),
            Path::new("/Applications/Clumsies.app/Contents/Resources/clumsiesd"),
            &"a".repeat(64),
            None,
        )
        .await
        .unwrap();

        assert!(!status.host_installed);
        assert!(!status.ready);
        assert!(root.path().read_dir().unwrap().next().is_none());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn inspection_with_codex_lists_state_without_materializing() {
        use std::os::unix::fs::PermissionsExt;

        let host = tempfile::tempdir().unwrap();
        let codex = host.path().join("Codex.app/Contents/Resources/codex");
        fs::create_dir_all(codex.parent().unwrap()).unwrap();
        fs::write(&codex, "#!/bin/sh\necho '{\"marketplaces\":[]}'\n").unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
        let daemon = tempfile::tempdir().unwrap();
        let marketplace = daemon.path().join("agent-plugins/codex-marketplace");

        let status = inspect_verified(&codex, &marketplace, "0.1.0+codex.expected".to_owned())
            .await
            .unwrap();

        assert!(status.host_installed);
        assert!(!status.marketplace_installed);
        assert!(!status.ready);
        assert!(!marketplace.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reconciliation_repairs_missing_stale_and_disabled_state() {
        use std::os::unix::fs::PermissionsExt;

        let daemon = tempfile::tempdir().unwrap();
        let plugin = materialize(
            daemon.path(),
            Path::new("/Applications/Clumsies.app/Contents/Resources/clumsiesd"),
            &"a".repeat(64),
        )
        .unwrap();
        let host = tempfile::tempdir().unwrap();
        let state = host.path().join("state");
        fs::create_dir_all(&state).unwrap();
        let marketplace_marker = state.join("marketplace");
        let plugin_marker = state.join("plugin");
        let marketplace_ready = json!({
            "marketplaces": [{
                "name": MARKETPLACE_NAME,
                "root": plugin.marketplace_root.display().to_string()
            }]
        })
        .to_string();
        let plugin_stale = json!({
            "installed": [{
                "pluginId": PLUGIN_ID,
                "version": "0.1.0+codex.old",
                "installed": true,
                "enabled": false
            }]
        })
        .to_string();
        let plugin_ready = json!({
            "installed": [{
                "pluginId": PLUGIN_ID,
                "version": plugin.version,
                "installed": true,
                "enabled": true
            }]
        })
        .to_string();
        let codex = host.path().join("Codex.app/Contents/Resources/codex");
        fs::create_dir_all(codex.parent().unwrap()).unwrap();
        fs::write(
            &codex,
            format!(
                "#!/bin/sh\n\
                 if [ \"$1\" = plugin ] && [ \"$2\" = marketplace ] && [ \"$3\" = list ]; then\n\
                   if [ -f {marketplace_marker} ]; then printf '%s\\n' {marketplace_ready}; else printf '%s\\n' '{{\"marketplaces\":[]}}'; fi\n\
                 elif [ \"$1\" = plugin ] && [ \"$2\" = marketplace ] && [ \"$3\" = add ]; then\n\
                   touch {marketplace_marker}; printf '%s\\n' '{{}}'\n\
                 elif [ \"$1\" = plugin ] && [ \"$2\" = list ]; then\n\
                   if [ -f {plugin_marker} ]; then printf '%s\\n' {plugin_ready}; else printf '%s\\n' {plugin_stale}; fi\n\
                 elif [ \"$1\" = plugin ] && [ \"$2\" = add ]; then\n\
                   touch {plugin_marker}; printf '%s\\n' '{{}}'\n\
                 else exit 1; fi\n",
                marketplace_marker = shell_single_quote(&marketplace_marker.display().to_string()),
                marketplace_ready = shell_single_quote(&marketplace_ready),
                plugin_marker = shell_single_quote(&plugin_marker.display().to_string()),
                plugin_ready = shell_single_quote(&plugin_ready),
                plugin_stale = shell_single_quote(&plugin_stale),
            ),
        )
        .unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

        ensure_marketplace(&codex, &plugin.marketplace_root)
            .await
            .unwrap();
        ensure_plugin(&codex, &plugin.version).await.unwrap();
        let status = inspect_verified(&codex, &plugin.marketplace_root, plugin.version)
            .await
            .unwrap();

        assert!(marketplace_marker.exists());
        assert!(plugin_marker.exists());
        assert!(status.ready);
    }

    #[test]
    fn marketplace_source_is_authoritative_when_reported() {
        let expected = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let entry = MarketplaceEntry {
            name: MARKETPLACE_NAME.to_owned(),
            root: expected.path().display().to_string(),
            marketplace_source: Some(MarketplaceSource {
                source_type: "local".to_owned(),
                source: other.path().display().to_string(),
            }),
        };
        assert!(!marketplace_matches(&entry, expected.path()));

        let legacy_entry = MarketplaceEntry {
            name: MARKETPLACE_NAME.to_owned(),
            root: expected.path().display().to_string(),
            marketplace_source: None,
        };
        assert!(marketplace_matches(&legacy_entry, expected.path()));
    }
}
