use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::Row;

use crate::retrieval_history::{RetrievalRunRequest, RetrievalRunStatus};
use crate::util::home_dir;
use crate::{DaemonError, DaemonState};

fn run_status_str(status: RetrievalRunStatus) -> &'static str {
    match status {
        RetrievalRunStatus::Running => "running",
        RetrievalRunStatus::Succeeded => "succeeded",
        RetrievalRunStatus::Failed => "failed",
    }
}

/// Upper bound on the number of sessions a single Recall list returns, newest
/// first. The panel is a diagnostic surface, not an unbounded archive dump.
const DEFAULT_SESSION_LIMIT: usize = 50;
const MAX_SESSION_LIMIT: usize = 200;
const MAX_TASKS_PER_SESSION: usize = 500;
const MAX_ACTIVATIONS_PER_TASK: usize = 100;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ListRecallsRequest {
    /// Optional workspace root filter. When omitted, every bound workspace is
    /// included.
    #[serde(default)]
    pub workspace_root: Option<String>,
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ListRecallsResponse {
    pub sessions: Vec<RecallSession>,
    pub workspace_roots: Vec<String>,
}

/// A dsh session and the tasks it contained, with each task's memory
/// activations attached.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecallSession {
    pub session_id: String,
    pub title: Option<String>,
    pub workspace_root: String,
    pub created_at: Option<i64>,
    pub tasks: Vec<RecallTask>,
}

/// One user prompt (task) and the memory activations the agent issued while
/// working on it.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecallTask {
    pub message_id: String,
    pub text: String,
    pub time: Option<i64>,
    pub activations: Vec<RecallActivation>,
}

/// A single memory activation: the tool call, its query, and the fragments
/// that were recalled for it.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecallActivation {
    pub tool_name: String,
    pub call_id: String,
    pub query: String,
    pub state: Option<String>,
    pub time: Option<i64>,
    /// Resolved retrieval-run identity when the daemon has a matching record.
    pub run_id: Option<String>,
    pub run_status: Option<String>,
    /// Recalled fragments. Populated from the daemon's retrieval run when a
    /// matching run exists; otherwise empty.
    pub fragments: Vec<RecallFragment>,
    /// A short error when the activation's tool result reported failure.
    pub result_error: Option<String>,
}

/// One recalled memory fragment: where it lives and what it says.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecallFragment {
    pub action: Option<String>,
    pub resource_id: String,
    pub path: String,
    pub content: String,
}

/// Resolves the bound workspaces (and their project ids) that Recall should
/// read session logs for.
async fn load_bindings(state: &DaemonState) -> Result<Vec<(String, String)>, DaemonError> {
    let rows = sqlx::query(
        "SELECT workspace_root, project_id FROM project_bindings ORDER BY workspace_root",
    )
    .fetch_all(&state.inner.pool)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| {
            let root: String = row.try_get("workspace_root").ok()?;
            let project_id: String = row.try_get("project_id").ok()?;
            Some((root, project_id))
        })
        .collect())
}

/// Encodes a workspace root into the directory name dsh uses under
/// `~/.dsh/sessions/`. For example `/Volumes/ORICO/workspace/clumsies`
/// becomes `--Volumes-ORICO-workspace-clumsies--`.
fn encode_workspace_dir(root: &str) -> String {
    let trimmed = root.trim_start_matches('/');
    format!("--{}--", trimmed.replace('/', "-").trim_end_matches('-'))
}

fn list_session_files(dir: &Path) -> Result<Vec<PathBuf>, DaemonError> {
    let mut files = Vec::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(files),
        Err(error) => return Err(DaemonError::Io(error)),
    };
    for entry in entries.flatten() {
        let session_file = entry.path().join("session.jsonl.zstd");
        if session_file.is_file() {
            files.push(session_file);
        }
    }
    Ok(files)
}

fn decompress(path: &Path) -> Result<Vec<u8>, DaemonError> {
    let data = std::fs::read(path)?;
    let cursor = std::io::Cursor::new(data);
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(cursor).map_err(|error| {
        DaemonError::State {
            code: "recall_zstd",
            message: format!("cannot decode {}: {error}", path.display()),
        }
    })?;
    let mut output = Vec::new();
    std::io::Read::read_to_end(&mut decoder, &mut output)?;
    Ok(output)
}

fn is_recall_tool(name: &str) -> bool {
    name.contains("clumsies") && (name.ends_with("__memory") || name.ends_with("__activate"))
}

fn extract_activate(args: &str) -> Option<(String, Option<String>)> {
    let value: Value = serde_json::from_str(args).ok()?;
    let object = value.as_object()?;
    // Unified tool: { op: { activate: { query, state } } }
    if let Some(activate) = object
        .get("op")
        .and_then(Value::as_object)
        .and_then(|op| op.get("activate"))
        .and_then(Value::as_object)
    {
        if let Some(query) = activate.get("query").and_then(Value::as_str) {
            let state = activate.get("state").and_then(Value::as_str);
            return Some((query.to_owned(), state.map(str::to_owned)));
        }
    }
    // Legacy tool: { query, state }
    let query = object.get("query").and_then(Value::as_str)?;
    let state = object.get("state").and_then(Value::as_str);
    Some((query.to_owned(), state.map(str::to_owned)))
}

fn message_text(content: &Value) -> Option<String> {
    let parts = content.as_array()?;
    let mut text = String::new();
    for part in parts {
        if let Some(t) = part.get("text").and_then(Value::as_str) {
            text.push_str(t);
        }
    }
    (!text.is_empty()).then_some(text)
}

/// Extracts the tool-result text and whether it reported an error.
fn extract_result(data: &Value) -> Option<(String, bool)> {
    let first = data.get("message")?.get("content")?.as_array()?.first()?;
    let is_error = first
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let inner = first.get("content")?.as_array()?;
    let mut text = String::new();
    for part in inner {
        if let Some(t) = part.get("text").and_then(Value::as_str) {
            text.push_str(t);
        }
    }
    Some((text, is_error))
}

/// Best-effort extraction of fragments already embedded in an activation's
/// tool result. Existing dsh sessions carry no fragments here (they live in
/// the daemon retrieval run), but the shape is stable so future sessions work.
fn extract_fragments(text: &str) -> Vec<RecallFragment> {
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return Vec::new();
    };
    let Some(fragments) = value.get("fragments").and_then(Value::as_array) else {
        return Vec::new();
    };
    fragments
        .iter()
        .filter_map(|fragment| {
            let path = fragment.get("path").and_then(Value::as_str)?.to_owned();
            let resource_id = fragment
                .get("resource_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let action = fragment
                .get("action")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let content = fragment
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            Some(RecallFragment {
                action,
                resource_id,
                path,
                content,
            })
        })
        .collect()
}

/// Joins an activation against the daemon's retrieval history by project and
/// exact query, returning the recalled fragments when a match exists.
async fn join_retrieval_run(
    state: &DaemonState,
    project_id: &str,
    query: &str,
) -> Result<Option<(String, String, Vec<RecallFragment>)>, DaemonError> {
    let run_id: Option<String> = sqlx::query_scalar(
        "SELECT run_id FROM retrieval_runs
         WHERE project_id = $1 AND query = $2
         ORDER BY created_at DESC, run_id DESC LIMIT 1",
    )
    .bind(project_id)
    .bind(query)
    .fetch_optional(&state.inner.pool)
    .await?;
    let Some(run_id) = run_id else {
        return Ok(None);
    };
    let detail =
        crate::retrieval_history::get_retrieval_run(state, RetrievalRunRequest { run_id }).await?;
    let fragments = detail
        .candidates
        .into_iter()
        .filter(|candidate| candidate.selected)
        .map(|candidate| RecallFragment {
            action: candidate.delta_action.map(|action| action.as_str().to_owned()),
            resource_id: candidate.resource_id,
            path: candidate.path,
            content: candidate.evidence_excerpt,
        })
        .collect();
    Ok(Some((
        detail.run.run_id,
        run_status_str(detail.run.status).to_owned(),
        fragments,
    )))
}

fn parse_session_text(text: &str, workspace_root: &str) -> Option<RecallSession> {
    let mut session_id: Option<String> = None;
    let mut title: Option<String> = None;
    let mut created_at: Option<i64> = None;
    let mut cwd: Option<String> = None;

    // Ordered task list plus a lookup for associating tool results to calls.
    let mut tasks: Vec<RecallTask> = Vec::new();
    // Map from callId -> (task index, activation index).
    let mut activation_lookup: std::collections::HashMap<String, (usize, usize)> =
        std::collections::HashMap::new();
    // Map from callId -> result text, is_error (results can arrive after the
    // call, so we buffer them).
    let mut pending_results: std::collections::HashMap<String, (String, bool)> =
        std::collections::HashMap::new();

    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(event_type) = event.get("type").and_then(Value::as_str) else {
            continue;
        };
        let data = event.get("data");

        match event_type {
            "session" => {
                // The session event is flat: id/cwd/createdAt are top-level.
                session_id = event.get("id").and_then(Value::as_str).map(str::to_owned);
                created_at = event.get("createdAt").and_then(Value::as_i64);
                cwd = event.get("cwd").and_then(Value::as_str).map(str::to_owned);
            }
            "session/title" => {
                if let Some(data) = data {
                    if let Some(t) = data.get("title").and_then(Value::as_str) {
                        title = Some(t.to_owned());
                    }
                }
            }
            "user/message" => {
                let Some(data) = data else { continue };
                let is_human = data
                    .get("source")
                    .and_then(|source| source.get("kind"))
                    .and_then(Value::as_str)
                    == Some("user");
                if !is_human {
                    continue;
                }
                if tasks.len() >= MAX_TASKS_PER_SESSION {
                    continue;
                }
                let Some(text_value) = data.get("content").and_then(message_text) else {
                    continue;
                };
                tasks.push(RecallTask {
                    message_id: data
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    text: text_value,
                    time: event.get("time").and_then(Value::as_i64),
                    activations: Vec::new(),
                });
            }
            "tool/call" => {
                let Some(data) = data else { continue };
                let name = data.get("name").and_then(Value::as_str).unwrap_or_default();
                if !is_recall_tool(name) {
                    continue;
                }
                let call_id = data.get("callId").and_then(Value::as_str).unwrap_or_default();
                let Some(arguments) = data.get("arguments").and_then(Value::as_str) else {
                    continue;
                };
                let Some((query, state)) = extract_activate(arguments) else {
                    continue;
                };
                if tasks.is_empty() {
                    // An activation before any recorded human message; keep a
                    // synthetic task so the activation is never lost.
                    tasks.push(RecallTask {
                        message_id: format!("synthetic-{call_id}"),
                        text: "(no recorded user message)".to_owned(),
                        time: None,
                        activations: Vec::new(),
                    });
                }
                let task_index = tasks.len() - 1;
                if tasks[task_index].activations.len() >= MAX_ACTIVATIONS_PER_TASK {
                    continue;
                }
                let activation_index = tasks[task_index].activations.len();
                tasks[task_index].activations.push(RecallActivation {
                    tool_name: name.to_owned(),
                    call_id: call_id.to_owned(),
                    query,
                    state,
                    time: event.get("time").and_then(Value::as_i64),
                    run_id: None,
                    run_status: None,
                    fragments: Vec::new(),
                    result_error: None,
                });
                activation_lookup.insert(call_id.to_owned(), (task_index, activation_index));
                // Attach a result that arrived before the call.
                if let Some((result_text, is_error)) = pending_results.remove(call_id) {
                    apply_result(&mut tasks, task_index, activation_index, &result_text, is_error);
                }
            }
            "tool/result" => {
                let Some(data) = data else { continue };
                let Some(call_id) = data
                    .get("message")
                    .and_then(|message| message.get("source"))
                    .and_then(|source| source.get("callId"))
                    .and_then(Value::as_str)
                else {
                    continue;
                };
                let Some((result_text, is_error)) = extract_result(data) else {
                    continue;
                };
                match activation_lookup.get(call_id) {
                    Some(&(task_index, activation_index)) => {
                        apply_result(&mut tasks, task_index, activation_index, &result_text, is_error);
                    }
                    None => {
                        pending_results.insert(call_id.to_owned(), (result_text, is_error));
                    }
                }
            }
            _ => {}
        }
    }

    let session_id = session_id?;
    let root = cwd.unwrap_or_else(|| workspace_root.to_owned());

    Some(RecallSession {
        session_id,
        title,
        workspace_root: root,
        created_at,
        tasks,
    })
}

async fn parse_session(
    state: &DaemonState,
    file: &Path,
    workspace_root: &str,
    project_id: &str,
) -> Result<Option<RecallSession>, DaemonError> {
    let bytes = decompress(file)?;
    let text = String::from_utf8_lossy(&bytes);
    let Some(mut session) = parse_session_text(&text, workspace_root) else {
        return Ok(None);
    };

    // Enrich each activation with the matching daemon retrieval run.
    for task in &mut session.tasks {
        for activation in &mut task.activations {
            let joined = join_retrieval_run(state, project_id, &activation.query).await?;
            if let Some((run_id, run_status, fragments)) = joined {
                activation.run_id = Some(run_id);
                activation.run_status = Some(run_status);
                if activation.fragments.is_empty() {
                    activation.fragments = fragments;
                }
            }
        }
    }

    Ok(Some(session))
}

fn apply_result(
    tasks: &mut [RecallTask],
    task_index: usize,
    activation_index: usize,
    result_text: &str,
    is_error: bool,
) {
    let Some(activation) = tasks
        .get_mut(task_index)
        .and_then(|task| task.activations.get_mut(activation_index))
    else {
        return;
    };
    if is_error {
        activation.result_error = Some(truncate(result_text, 240));
    }
    let fragments = extract_fragments(result_text);
    if !fragments.is_empty() {
        activation.fragments = fragments;
    }
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_owned();
    }
    let mut truncated: String = value.chars().take(max_chars).collect();
    truncated.push('…');
    truncated
}

pub(super) async fn list_recalls(
    state: &DaemonState,
    request: ListRecallsRequest,
) -> Result<ListRecallsResponse, DaemonError> {
    let limit = request
        .limit
        .map(|limit| limit as usize)
        .unwrap_or(DEFAULT_SESSION_LIMIT)
        .clamp(1, MAX_SESSION_LIMIT);

    let bindings = load_bindings(state).await?;
    let roots: Vec<(String, String)> = match request.workspace_root.as_deref() {
        Some(root) => {
            let canonical = crate::util::canonical_binding_root(root);
            let canonical = canonical.display().to_string();
            let project_id = bindings
                .iter()
                .find(|(bound, _)| bound == &canonical)
                .map(|(_, project)| project.clone())
                .unwrap_or_default();
            vec![(canonical, project_id)]
        }
        None => bindings,
    };

    let home = home_dir()?;
    let sessions_root = home.join(".dsh").join("sessions");

    let mut sessions = Vec::new();
    let mut workspace_roots = Vec::new();
    for (root, project_id) in &roots {
        workspace_roots.push(root.clone());
        let dir = sessions_root.join(encode_workspace_dir(root));
        for file in list_session_files(&dir)? {
            if let Some(session) = parse_session(state, &file, root, project_id).await? {
                sessions.push(session);
            }
        }
    }

    sessions.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| b.session_id.cmp(&a.session_id)));
    sessions.truncate(limit);

    Ok(ListRecallsResponse {
        sessions,
        workspace_roots,
    })
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_workspace_directory() {
        assert_eq!(
            encode_workspace_dir("/Volumes/ORICO/workspace/clumsies"),
            "--Volumes-ORICO-workspace-clumsies--"
        );
        assert_eq!(
            encode_workspace_dir("/Users/weiwang/koal-agentos"),
            "--Users-weiwang-koal-agentos--"
        );
    }

    #[test]
    fn recognizes_recall_tools() {
        assert!(is_recall_tool("mcp__clumsies__memory"));
        assert!(is_recall_tool("mcp__clumsies__activate"));
        assert!(!is_recall_tool("mcp__clumsies__load"));
        assert!(!is_recall_tool("mcp__clumsies__store"));
        assert!(!is_recall_tool("run_code"));
    }

    #[test]
    fn extracts_unified_activate_query() {
        let (query, state) = extract_activate(
            r#"{"op":{"activate":{"query":"adjust the MCP hybrid retrieval interface","state":"opaque"}}}"#,
        )
        .unwrap();
        assert_eq!(query, "adjust the MCP hybrid retrieval interface");
        assert_eq!(state.as_deref(), Some("opaque"));
    }

    #[test]
    fn extracts_legacy_activate_query() {
        let (query, state) = extract_activate(r#"{"query":"writing rules","state":null}"#).unwrap();
        assert_eq!(query, "writing rules");
        assert_eq!(state, None);
    }

    #[test]
    fn extracts_tool_result_text_and_error_flag() {
        let data: Value = serde_json::from_str(
            r#"{"message":{"source":{"kind":"tool","callId":"call_1"},"content":[{"type":"tool-result","toolCallId":"call_1","content":[{"type":"text","text":"boom"}],"isError":true}]}}"#,
        )
        .unwrap();
        let (text, is_error) = extract_result(&data).unwrap();
        assert_eq!(text, "boom");
        assert!(is_error);
    }

    #[test]
    fn parses_a_minimal_session_log() {
        let log = [
            r#"{"type":"session","id":"s1","createdAt":1000,"cwd":"/repo"}"#,
            r#"{"type":"session/title","data":{"title":"tune retrieval"}}"#,
            r#"{"type":"user/message","time":2000,"data":{"id":"m1","role":"user","content":[{"type":"text","text":"帮我调整检索接口"}],"source":{"kind":"user"}}}"#,
            r#"{"type":"tool/call","time":3000,"data":{"callId":"c1","name":"mcp__clumsies__memory","arguments":"{\"op\":{\"activate\":{\"query\":\"adjust MCP retrieval\"}}}"}}"#,
        ]
        .join("\n");
        let session = parse_session_text(&log, "/repo").unwrap();
        assert_eq!(session.session_id, "s1");
        assert_eq!(session.title.as_deref(), Some("tune retrieval"));
        assert_eq!(session.tasks.len(), 1);
        assert_eq!(session.tasks[0].text, "帮我调整检索接口");
        assert_eq!(session.tasks[0].activations.len(), 1);
        assert_eq!(session.tasks[0].activations[0].query, "adjust MCP retrieval");
    }

    #[test]
    fn skips_plugin_injected_user_messages() {
        let log = [
            r#"{"type":"session","id":"s2","createdAt":1,"cwd":"/repo"}"#,
            r#"{"type":"user/message","data":{"id":"p1","role":"user","content":[{"type":"text","text":"system snapshot"}],"source":{"kind":"plugin","plugin":"@deepseek-ai/dsh-system-prompt"}}}"#,
            r#"{"type":"user/message","data":{"id":"u1","role":"user","content":[{"type":"text","text":"real task"}],"source":{"kind":"user"}}}"#,
        ]
        .join("\n");
        let session = parse_session_text(&log, "/repo").unwrap();
        assert_eq!(session.tasks.len(), 1);
        assert_eq!(session.tasks[0].text, "real task");
    }

    #[test]
    fn decompresses_a_real_dsh_session_when_present() {
        // Best-effort local sanity check: only runs on machines that actually
        // have dsh session logs under ~/.dsh.
        let Ok(home) = std::env::var("HOME") else {
            return;
        };
        let sessions_root = std::path::Path::new(&home).join(".dsh").join("sessions");
        let Ok(workspaces) = std::fs::read_dir(&sessions_root) else {
            return;
        };
        let mut found = false;
        for workspace in workspaces.flatten() {
            for session in std::fs::read_dir(workspace.path()).into_iter().flatten().flatten() {
                let file = session.path().join("session.jsonl.zstd");
                if !file.is_file() {
                    continue;
                }
                let bytes = decompress(&file).expect("decompress real session");
                let text = String::from_utf8_lossy(&bytes);
                assert!(text.contains("\"type\":\"session\""));
                if let Some(session) = parse_session_text(&text, "/repo") {
                    // A real session must yield a non-empty session id; tasks
                    // may be zero only if the session had no human messages.
                    assert!(!session.session_id.is_empty());
                }
                found = true;
                break;
            }
            if found {
                break;
            }
        }
        if found {
            // Nothing more to assert; decompression already succeeded.
        }
    }
}

