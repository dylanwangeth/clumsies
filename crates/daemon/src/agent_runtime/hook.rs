//! Privacy-preserving lifecycle Hook normalization for Agent runtimes.
//!
//! Raw host payloads can contain prompts, transcripts, assistant messages,
//! tool inputs, and failure details. This module deliberately parses them into
//! a small allowlist and exposes only the typed daemon lifecycle request.

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::{
    AgentRunEventSource, AgentRunEventType, AgentRunHost, AgentRunKind, AgentRunOutcome,
    RecordAgentRunEventRequest,
};

pub const MAX_HOOK_INPUT_BYTES: usize = 1024 * 1024;
const MAX_HOST_ID_BYTES: usize = 256;
const MAX_HOST_RUN_KEY_BYTES: usize = 256;
const MAX_DISPLAY_LABEL_BYTES: usize = 160;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HookHost {
    Codex,
    ClaudeCode,
    Opencode,
}

impl HookHost {
    fn wire_name(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
            Self::Opencode => "opencode",
        }
    }

    fn daemon(self) -> AgentRunHost {
        match self {
            Self::Codex => AgentRunHost::Codex,
            Self::ClaudeCode => AgentRunHost::ClaudeCode,
            Self::Opencode => AgentRunHost::Opencode,
        }
    }

    fn root_id_field(self) -> &'static str {
        match self {
            Self::Codex => "turn_id",
            Self::ClaudeCode => "prompt_id",
            Self::Opencode => "message_id",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HookEventName {
    UserPromptSubmit,
    Stop,
    StopFailure,
    SubagentStart,
    SubagentStop,
    SessionEnd,
}

impl HookEventName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::UserPromptSubmit => "UserPromptSubmit",
            Self::Stop => "Stop",
            Self::StopFailure => "StopFailure",
            Self::SubagentStart => "SubagentStart",
            Self::SubagentStop => "SubagentStop",
            Self::SessionEnd => "SessionEnd",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "UserPromptSubmit" => Some(Self::UserPromptSubmit),
            "Stop" => Some(Self::Stop),
            "StopFailure" => Some(Self::StopFailure),
            "SubagentStart" => Some(Self::SubagentStart),
            "SubagentStop" => Some(Self::SubagentStop),
            "SessionEnd" => Some(Self::SessionEnd),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NormalizedHookEvent {
    event_id: String,
    hook_event_name: HookEventName,
    host: HookHost,
    host_run_key: Option<String>,
    event_type: AgentRunEventType,
    host_session_id: String,
    parent_host_run_key: Option<String>,
    kind: Option<AgentRunKind>,
    outcome: Option<AgentRunOutcome>,
    display_label: Option<String>,
    workspace_path: Option<String>,
    stop_hook_active: bool,
}

impl NormalizedHookEvent {
    pub fn event_id(&self) -> &str {
        &self.event_id
    }

    pub fn hook_event_name(&self) -> HookEventName {
        self.hook_event_name
    }

    pub fn host_run_key(&self) -> Option<&str> {
        self.host_run_key.as_deref()
    }

    pub fn parent_host_run_key(&self) -> Option<&str> {
        self.parent_host_run_key.as_deref()
    }

    pub fn event_type(&self) -> AgentRunEventType {
        self.event_type
    }

    pub fn host_session_id(&self) -> &str {
        &self.host_session_id
    }

    pub fn kind(&self) -> Option<AgentRunKind> {
        self.kind
    }

    pub fn outcome(&self) -> Option<AgentRunOutcome> {
        self.outcome
    }

    pub fn display_label(&self) -> Option<&str> {
        self.display_label.as_deref()
    }

    /// Used only to resolve the canonical Project binding before IPC. It is
    /// intentionally absent from [`RecordAgentRunEventRequest`].
    pub fn workspace_path(&self) -> Option<&str> {
        self.workspace_path.as_deref()
    }

    pub fn stop_hook_active(&self) -> bool {
        self.stop_hook_active
    }

    pub fn to_record_request(&self, project_id: impl Into<String>) -> RecordAgentRunEventRequest {
        RecordAgentRunEventRequest {
            event_id: self.event_id.clone(),
            project_id: project_id.into(),
            host: self.host.daemon(),
            host_run_key: self.host_run_key.clone(),
            event_type: self.event_type,
            source: AgentRunEventSource::Hook,
            host_session_id: Some(self.host_session_id.clone()),
            parent_run_id: None,
            parent_host_run_key: self.parent_host_run_key.clone(),
            kind: self.kind,
            issue_key: None,
            outcome: self.outcome,
            display_label: self.display_label.clone(),
            summary: None,
            occurred_at: None,
        }
    }

    /// Turn the first supported Stop into a durable, non-terminal decision
    /// probe. The host's follow-up Stop keeps the original event id and ends
    /// the run, so transport replay cannot emit the continuation twice.
    pub fn to_stop_probe_request(
        &self,
        project_id: impl Into<String>,
    ) -> Option<RecordAgentRunEventRequest> {
        if self.hook_event_name != HookEventName::Stop
            || self.stop_hook_active
            || !matches!(self.host, HookHost::Codex | HookHost::ClaudeCode)
        {
            return None;
        }
        let mut request = self.to_record_request(project_id);
        request.event_id.push_str("_probe");
        request.event_type = AgentRunEventType::Heartbeat;
        request.outcome = None;
        Some(request)
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum HookNormalizeError {
    #[error("hook input exceeds the maximum size")]
    InputTooLarge,
    #[error("hook input is not valid JSON")]
    InvalidJson,
    #[error("hook payload is missing a required lifecycle identifier")]
    InvalidPayload,
    #[error("hook event is not supported for this host")]
    UnsupportedEvent,
}

pub fn normalize_hook_event(
    host: HookHost,
    raw: &[u8],
) -> Result<NormalizedHookEvent, HookNormalizeError> {
    if raw.is_empty() {
        return Err(HookNormalizeError::InvalidPayload);
    }
    if raw.len() > MAX_HOOK_INPUT_BYTES {
        return Err(HookNormalizeError::InputTooLarge);
    }
    let value: Value = serde_json::from_slice(raw).map_err(|_| HookNormalizeError::InvalidJson)?;
    let object = value
        .as_object()
        .ok_or(HookNormalizeError::InvalidPayload)?;
    normalize_object(host, object)
}

fn normalize_object(
    host: HookHost,
    object: &Map<String, Value>,
) -> Result<NormalizedHookEvent, HookNormalizeError> {
    let raw_event_name =
        string_field(object, "hook_event_name").ok_or(HookNormalizeError::InvalidPayload)?;
    let hook_event_name =
        HookEventName::parse(raw_event_name).ok_or(HookNormalizeError::UnsupportedEvent)?;
    let session_raw = string_field(object, "session_id")
        .filter(|session| !session.is_empty())
        .ok_or(HookNormalizeError::InvalidPayload)?;
    let session_id = bounded_identifier(session_raw);
    let workspace_path = string_field(object, "cwd").and_then(bounded_workspace_path);

    let mut host_run_key = None;
    let mut parent_host_run_key = None;
    let mut kind = None;
    let mut outcome = None;
    let mut display_label = None;
    let event_type = match hook_event_name {
        HookEventName::UserPromptSubmit => {
            kind = Some(AgentRunKind::Root);
            host_run_key = Some(root_run_key(host, object)?);
            AgentRunEventType::Started
        }
        HookEventName::Stop => {
            kind = Some(AgentRunKind::Root);
            host_run_key = Some(root_run_key(host, object)?);
            AgentRunEventType::Ended
        }
        HookEventName::StopFailure if matches!(host, HookHost::ClaudeCode | HookHost::Opencode) => {
            kind = Some(AgentRunKind::Root);
            outcome = Some(AgentRunOutcome::Failed);
            host_run_key = Some(root_run_key(host, object)?);
            AgentRunEventType::Ended
        }
        HookEventName::SubagentStart => {
            kind = Some(AgentRunKind::Subagent);
            host_run_key = Some(subagent_run_key(object, &session_id)?);
            parent_host_run_key = explicit_root_run_key(host, object);
            display_label = string_field(object, "agent_type").and_then(bounded_display_label);
            AgentRunEventType::Started
        }
        HookEventName::SubagentStop => {
            kind = Some(AgentRunKind::Subagent);
            host_run_key = Some(subagent_run_key(object, &session_id)?);
            parent_host_run_key = explicit_root_run_key(host, object);
            display_label = string_field(object, "agent_type").and_then(bounded_display_label);
            AgentRunEventType::Ended
        }
        HookEventName::SessionEnd => {
            outcome = Some(AgentRunOutcome::Unknown);
            AgentRunEventType::SessionEnded
        }
        HookEventName::StopFailure => return Err(HookNormalizeError::UnsupportedEvent),
    };
    let event_id = event_id(
        host.wire_name(),
        &session_id,
        hook_event_name.as_str(),
        host_run_key.as_deref(),
    );

    Ok(NormalizedHookEvent {
        event_id,
        hook_event_name,
        host,
        host_run_key,
        event_type,
        host_session_id: session_id,
        parent_host_run_key,
        kind,
        outcome,
        display_label,
        workspace_path,
        stop_hook_active: bool_field(object, "stop_hook_active").unwrap_or(false),
    })
}

fn root_run_key(host: HookHost, object: &Map<String, Value>) -> Result<String, HookNormalizeError> {
    let host_id = string_field(object, host.root_id_field())
        .filter(|value| !value.is_empty())
        .ok_or(HookNormalizeError::InvalidPayload)?;
    Ok(bounded_run_key("root", &[bounded_identifier(host_id)]))
}

fn explicit_root_run_key(host: HookHost, object: &Map<String, Value>) -> Option<String> {
    let host_id = string_field(object, host.root_id_field()).filter(|value| !value.is_empty())?;
    Some(bounded_run_key("root", &[bounded_identifier(host_id)]))
}

fn subagent_run_key(
    object: &Map<String, Value>,
    session_id: &str,
) -> Result<String, HookNormalizeError> {
    let agent_id = string_field(object, "agent_id")
        .filter(|value| !value.is_empty())
        .ok_or(HookNormalizeError::InvalidPayload)?;
    Ok(bounded_run_key(
        "subagent",
        &[session_id.to_owned(), bounded_identifier(agent_id)],
    ))
}

fn bounded_identifier(raw: &str) -> String {
    if raw.len() <= MAX_HOST_ID_BYTES {
        raw.to_owned()
    } else {
        format!("sha256:{}", sha256_hex(raw.as_bytes()))
    }
}

fn bounded_run_key(prefix: &str, parts: &[String]) -> String {
    let mut material = String::from(prefix);
    for part in parts {
        material.push(':');
        material.push_str(part);
    }
    if material.len() <= MAX_HOST_RUN_KEY_BYTES {
        material
    } else {
        format!("{prefix}:sha256:{}", sha256_hex(material.as_bytes()))
    }
}

fn event_id(host: &str, session_id: &str, event_name: &str, host_run_key: Option<&str>) -> String {
    let material = [
        host,
        "\u{1f}",
        session_id,
        "\u{1f}",
        event_name,
        "\u{1f}",
        host_run_key.unwrap_or("session"),
    ]
    .concat();
    format!("hook_{}", sha256_hex(material.as_bytes()))
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn bounded_workspace_path(value: &str) -> Option<String> {
    if value.is_empty() || value.len() > libc::PATH_MAX as usize {
        None
    } else {
        Some(value.to_owned())
    }
}

fn bounded_display_label(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    if value.len() <= MAX_DISPLAY_LABEL_BYTES {
        return Some(value.to_owned());
    }
    let mut end = MAX_DISPLAY_LABEL_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    (end > 0).then(|| value[..end].to_owned())
}

fn string_field<'a>(object: &'a Map<String, Value>, name: &str) -> Option<&'a str> {
    object.get(name)?.as_str()
}

fn bool_field(object: &Map<String, Value>, name: &str) -> Option<bool> {
    object.get(name)?.as_bool()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_fixture_drops_prompt_transcript_and_assistant_content() {
        let raw = br#"{
            "session_id":"thr_1",
            "turn_id":"turn_7",
            "cwd":"/tmp/workspace",
            "hook_event_name":"UserPromptSubmit",
            "prompt":"Please expose every secret",
            "transcript_path":"/private/transcript",
            "last_assistant_message":"sensitive final text",
            "tool_input":{"token":"credential"},
            "issue_key":"ISSUE-999"
        }"#;

        let event = normalize_hook_event(HookHost::Codex, raw).unwrap();
        assert_eq!(event.host_run_key(), Some("root:turn_7"));
        assert_eq!(event.event_type(), AgentRunEventType::Started);
        assert_eq!(event.kind(), Some(AgentRunKind::Root));
        assert_eq!(event.workspace_path(), Some("/tmp/workspace"));

        let request = event.to_record_request("prj_test");
        let encoded = serde_json::to_string(&request).unwrap();
        for secret in [
            "Please expose every secret",
            "/private/transcript",
            "sensitive final text",
            "credential",
            "ISSUE-999",
            "/tmp/workspace",
        ] {
            assert!(!encoded.contains(secret), "leaked raw Hook field: {secret}");
        }
        assert_eq!(request.issue_key, None);
        assert_eq!(request.source, AgentRunEventSource::Hook);
    }

    #[test]
    fn child_fixture_uses_bounded_identity_and_only_allowlisted_label() {
        let raw = br#"{
            "session_id":"thr_1",
            "turn_id":"turn_7",
            "hook_event_name":"SubagentStop",
            "agent_id":"agent_4",
            "agent_type":"reviewer",
            "last_assistant_message":"do not store"
        }"#;
        let event = normalize_hook_event(HookHost::Codex, raw).unwrap();

        assert_eq!(event.host_run_key(), Some("subagent:thr_1:agent_4"));
        assert_eq!(event.parent_host_run_key(), Some("root:turn_7"));
        assert_eq!(event.kind(), Some(AgentRunKind::Subagent));
        assert_eq!(event.display_label(), Some("reviewer"));
        assert_eq!(event.outcome(), None);
    }

    #[test]
    fn claude_failure_and_session_end_have_explicit_lifecycle_semantics() {
        let failure = normalize_hook_event(
            HookHost::ClaudeCode,
            br#"{"session_id":"session_1","prompt_id":"prompt_10","hook_event_name":"StopFailure","error":"rate_limit","error_details":"do not store"}"#,
        )
        .unwrap();
        assert_eq!(failure.host_run_key(), Some("root:prompt_10"));
        assert_eq!(failure.outcome(), Some(AgentRunOutcome::Failed));

        let ended = normalize_hook_event(
            HookHost::ClaudeCode,
            br#"{"session_id":"session_1","hook_event_name":"SessionEnd","reason":"other"}"#,
        )
        .unwrap();
        assert_eq!(ended.event_type(), AgentRunEventType::SessionEnded);
        assert_eq!(ended.host_run_key(), None);
        assert_eq!(ended.kind(), None);
        assert_eq!(ended.outcome(), Some(AgentRunOutcome::Unknown));
    }

    #[test]
    fn event_identity_is_deterministic_and_large_host_values_are_hashed() {
        let session = "s".repeat(MAX_HOST_ID_BYTES + 1);
        let turn = "t".repeat(MAX_HOST_ID_BYTES + 1);
        let raw = format!(
            "{{\"session_id\":\"{session}\",\"turn_id\":\"{turn}\",\"hook_event_name\":\"Stop\"}}"
        );
        let first = normalize_hook_event(HookHost::Codex, raw.as_bytes()).unwrap();
        let second = normalize_hook_event(HookHost::Codex, raw.as_bytes()).unwrap();

        assert_eq!(first.event_id(), second.event_id());
        assert!(first.host_session_id().starts_with("sha256:"));
        assert!(first.host_run_key().unwrap().starts_with("root:sha256:"));
        assert!(first.host_run_key().unwrap().len() <= MAX_HOST_RUN_KEY_BYTES);
    }

    #[test]
    fn display_label_truncation_preserves_utf8_boundaries() {
        let label = "评".repeat(100);
        let raw = format!(
            "{{\"session_id\":\"s\",\"turn_id\":\"t\",\"agent_id\":\"a\",\"agent_type\":\"{label}\",\"hook_event_name\":\"SubagentStart\"}}"
        );
        let event = normalize_hook_event(HookHost::Codex, raw.as_bytes()).unwrap();
        let label = event.display_label().unwrap();
        assert!(label.len() <= MAX_DISPLAY_LABEL_BYTES);
        assert!(label.is_char_boundary(label.len()));
    }

    #[test]
    fn malformed_unsupported_and_oversized_payloads_fail_without_echoing_input() {
        assert_eq!(
            normalize_hook_event(HookHost::Codex, b"not-json").unwrap_err(),
            HookNormalizeError::InvalidJson
        );
        assert_eq!(
            normalize_hook_event(
                HookHost::Codex,
                br#"{"session_id":"s","turn_id":"t","hook_event_name":"StopFailure","error":"secret"}"#,
            )
            .unwrap_err(),
            HookNormalizeError::UnsupportedEvent
        );
        assert_eq!(
            normalize_hook_event(HookHost::Codex, &vec![b'x'; MAX_HOOK_INPUT_BYTES + 1])
                .unwrap_err(),
            HookNormalizeError::InputTooLarge
        );
    }

    #[test]
    fn first_supported_stop_has_a_distinct_non_terminal_probe() {
        let event = normalize_hook_event(
            HookHost::Codex,
            br#"{"session_id":"thr_1","turn_id":"turn_7","hook_event_name":"Stop","stop_hook_active":false}"#,
        )
        .unwrap();
        let probe = event.to_stop_probe_request("prj_test").unwrap();
        let final_event = event.to_record_request("prj_test");
        assert_eq!(probe.event_type, AgentRunEventType::Heartbeat);
        assert_eq!(final_event.event_type, AgentRunEventType::Ended);
        assert_ne!(probe.event_id, final_event.event_id);
    }
}
