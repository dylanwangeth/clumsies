use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::sqlite::SqliteRow;
use sqlx::{Row, Sqlite, SqlitePool, Transaction};
use uuid::Uuid;

use crate::DaemonError;

const LEASE_EXPIRED_REASON: &str = "lease_expired";
const SESSION_ENDED_REASON: &str = "session_ended";
const RECOVERED_END_REASON: &str = "recovered_end";
const HOOK_END_REASON: &str = "hook";
const MAX_IDENTIFIER_BYTES: usize = 256;
const MAX_RUN_KEY_BYTES: usize = 256;
const MAX_DISPLAY_LABEL_BYTES: usize = 160;
const MAX_SUMMARY_BYTES: usize = 1_000;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum AgentRunHost {
    #[serde(rename = "codex")]
    Codex,
    #[serde(rename = "claude-code")]
    ClaudeCode,
    #[serde(rename = "manual")]
    Manual,
    #[serde(rename = "zed")]
    Zed,
    #[serde(rename = "opencode")]
    Opencode,
    #[serde(rename = "dsh")]
    Dsh,
    #[serde(rename = "antigravity")]
    Antigravity,
}

impl AgentRunHost {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
            Self::Manual => "manual",
            Self::Zed => "zed",
            Self::Opencode => "opencode",
            Self::Dsh => "dsh",
            Self::Antigravity => "antigravity",
        }
    }

    fn from_db(value: &str) -> Result<Self, DaemonError> {
        match value {
            "codex" => Ok(Self::Codex),
            "claude-code" => Ok(Self::ClaudeCode),
            "manual" => Ok(Self::Manual),
            "zed" => Ok(Self::Zed),
            "opencode" => Ok(Self::Opencode),
            "dsh" => Ok(Self::Dsh),
            "antigravity" => Ok(Self::Antigravity),
            value => Err(corrupt_run(format!("unknown AgentRun host {value}"))),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentRunKind {
    Root,
    Subagent,
}

impl AgentRunKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Root => "root",
            Self::Subagent => "subagent",
        }
    }

    fn from_db(value: &str) -> Result<Self, DaemonError> {
        match value {
            "root" => Ok(Self::Root),
            "subagent" => Ok(Self::Subagent),
            value => Err(corrupt_run(format!("unknown AgentRun kind {value}"))),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentRunPhase {
    Running,
    Ended,
}

impl AgentRunPhase {
    fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Ended => "ended",
        }
    }

    fn from_db(value: &str) -> Result<Self, DaemonError> {
        match value {
            "running" => Ok(Self::Running),
            "ended" => Ok(Self::Ended),
            value => Err(corrupt_run(format!("unknown AgentRun phase {value}"))),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentRunOutcome {
    Completed,
    Blocked,
    Failed,
    Cancelled,
    Unknown,
}

impl AgentRunOutcome {
    fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Blocked => "blocked",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unknown => "unknown",
        }
    }

    fn from_db(value: &str) -> Result<Self, DaemonError> {
        match value {
            "completed" => Ok(Self::Completed),
            "blocked" => Ok(Self::Blocked),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            "unknown" => Ok(Self::Unknown),
            value => Err(corrupt_run(format!("unknown AgentRun outcome {value}"))),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentRunEventType {
    Started,
    Heartbeat,
    Ended,
    SessionEnded,
}

impl AgentRunEventType {
    fn as_str(self) -> &'static str {
        match self {
            Self::Started => "started",
            Self::Heartbeat => "heartbeat",
            Self::Ended => "ended",
            Self::SessionEnded => "session_ended",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentRunEventSource {
    Hook,
    Recovery,
}

impl AgentRunEventSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Hook => "hook",
            Self::Recovery => "recovery",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecordAgentRunEventRequest {
    pub event_id: String,
    pub project_id: String,
    pub host: AgentRunHost,
    pub host_run_key: Option<String>,
    pub event_type: AgentRunEventType,
    pub source: AgentRunEventSource,
    pub host_session_id: Option<String>,
    pub parent_run_id: Option<String>,
    pub parent_host_run_key: Option<String>,
    pub kind: Option<AgentRunKind>,
    pub outcome: Option<AgentRunOutcome>,
    pub display_label: Option<String>,
    pub summary: Option<String>,
    pub occurred_at: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecordAgentRunEventResponse {
    pub run: Option<AgentRun>,
    pub affected_runs: Vec<AgentRun>,
    pub duplicate: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct AgentRun {
    pub run_id: String,
    pub project_id: String,
    pub host: AgentRunHost,
    pub host_run_key: String,
    pub host_session_id: Option<String>,
    pub parent_run_id: Option<String>,
    pub kind: AgentRunKind,
    pub phase: AgentRunPhase,
    pub outcome: Option<AgentRunOutcome>,
    pub end_reason: Option<String>,
    pub display_label: Option<String>,
    pub summary: Option<String>,
    pub revision: i64,
    pub started_at: String,
    pub last_seen_at: String,
    pub lease_expires_at: String,
    pub ended_at: Option<String>,
}

pub(crate) async fn migrate(pool: &SqlitePool) -> Result<(), DaemonError> {
    for statement in [
        "CREATE TABLE IF NOT EXISTS agent_runs (
            run_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            host TEXT NOT NULL CHECK (host IN (
                'codex', 'claude-code', 'manual', 'zed', 'opencode', 'dsh', 'antigravity'
            )),
            host_run_key TEXT NOT NULL,
            host_session_id TEXT,
            parent_run_id TEXT REFERENCES agent_runs(run_id),
            kind TEXT NOT NULL CHECK (kind IN ('root', 'subagent')),
            phase TEXT NOT NULL CHECK (phase IN ('running', 'ended')),
            outcome TEXT CHECK (outcome IN (
                'completed', 'blocked', 'failed', 'cancelled', 'unknown'
            )),
            end_reason TEXT,
            display_label TEXT,
            summary TEXT,
            revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
            start_observed INTEGER NOT NULL DEFAULT 1 CHECK (start_observed IN (0, 1)),
            started_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            lease_expires_at TEXT NOT NULL,
            ended_at TEXT,
            UNIQUE (project_id, host, host_run_key)
        )",
        "CREATE INDEX IF NOT EXISTS idx_agent_runs_running_lease
         ON agent_runs (phase, lease_expires_at)",
        "CREATE INDEX IF NOT EXISTS idx_agent_runs_project_session
         ON agent_runs (project_id, host, host_session_id, phase)",
        "CREATE TABLE IF NOT EXISTS agent_run_events (
            event_id TEXT PRIMARY KEY,
            event_fingerprint TEXT NOT NULL,
            run_id TEXT REFERENCES agent_runs(run_id) ON DELETE CASCADE,
            host_session_id TEXT,
            event_type TEXT NOT NULL CHECK (event_type IN (
                'started', 'heartbeat', 'ended', 'session_ended'
            )),
            source TEXT NOT NULL CHECK (source IN ('hook', 'recovery')),
            outcome TEXT CHECK (outcome IN (
                'completed', 'blocked', 'failed', 'cancelled', 'unknown'
            )),
            summary TEXT,
            occurred_at TEXT NOT NULL,
            received_at TEXT NOT NULL DEFAULT (
                strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            ),
            CHECK (
                run_id IS NOT NULL
                OR (event_type = 'session_ended' AND host_session_id IS NOT NULL)
            )
        )",
        "CREATE INDEX IF NOT EXISTS idx_agent_run_events_run_occurred
         ON agent_run_events (run_id, occurred_at DESC, event_id DESC)",
    ] {
        sqlx::query(statement).execute(pool).await?;
    }

    let event_columns = sqlx::query("PRAGMA table_info(agent_run_events)")
        .fetch_all(pool)
        .await?;
    if !event_columns
        .iter()
        .any(|row| row.get::<String, _>("name") == "event_fingerprint")
    {
        sqlx::query(
            "ALTER TABLE agent_run_events
             ADD COLUMN event_fingerprint TEXT NOT NULL DEFAULT 'legacy'",
        )
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub(crate) async fn record_agent_run_event(
    pool: &SqlitePool,
    request: RecordAgentRunEventRequest,
) -> Result<RecordAgentRunEventResponse, DaemonError> {
    validate_record_request(&request)?;
    let event_fingerprint = canonical_json_fingerprint(&request)?;
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let existing_event = load_existing_event(&mut tx, &request.event_id).await?;
    if let Some(existing_event) = &existing_event
        && existing_event.event_fingerprint != event_fingerprint
    {
        return Err(run_conflict(format!(
            "event_id {} was already used for a different request",
            request.event_id
        )));
    }
    if request.event_type != AgentRunEventType::SessionEnded
        && let Some(existing_event) = &existing_event
    {
        let response =
            duplicate_run_event_response(&mut tx, &request, existing_event.run_id.as_deref())
                .await?;
        tx.commit().await?;
        return Ok(response);
    }

    let duplicate = existing_event.is_some();
    let (received_at, lease_expires_at) = db_clock(&mut tx).await?;
    let occurred_at =
        normalize_occurred_at(&mut tx, request.occurred_at.as_deref(), &received_at).await?;

    if request.event_type == AgentRunEventType::SessionEnded {
        let host_session_id = request
            .host_session_id
            .as_deref()
            .expect("validated session_ended host_session_id");
        let rows = sqlx::query(
            "SELECT run_id, project_id, host, host_run_key, host_session_id,
                    parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                    revision, started_at, last_seen_at, lease_expires_at, ended_at
             FROM agent_runs
             WHERE project_id = $1 AND host = $2 AND host_session_id = $3
               AND phase = 'running'
             ORDER BY last_seen_at DESC, run_id DESC",
        )
        .bind(&request.project_id)
        .bind(request.host.as_str())
        .bind(host_session_id)
        .fetch_all(&mut *tx)
        .await?;
        let mut affected_runs = Vec::with_capacity(rows.len());
        for row in rows {
            let mut run = agent_run_from_row(&row)?;
            run.phase = AgentRunPhase::Ended;
            run.outcome = Some(request.outcome.unwrap_or(AgentRunOutcome::Unknown));
            run.end_reason = Some(SESSION_ENDED_REASON.to_owned());
            run.revision += 1;
            run.last_seen_at = received_at.clone();
            run.ended_at = Some(occurred_at.clone());
            update_run(&mut tx, &run).await?;
            affected_runs.push(run);
        }
        if !duplicate {
            insert_event(
                &mut tx,
                &request.event_id,
                Some(&event_fingerprint),
                None,
                request.host_session_id.as_deref(),
                request.event_type,
                request.source,
                request.outcome.or(Some(AgentRunOutcome::Unknown)),
                request.summary.as_deref(),
                &occurred_at,
            )
            .await?;
        }
        tx.commit().await?;
        return Ok(RecordAgentRunEventResponse {
            run: None,
            affected_runs,
            duplicate,
        });
    }

    let host_run_key = request
        .host_run_key
        .as_deref()
        .expect("validated host_run_key");
    let existing =
        load_run_by_host_key(&mut tx, &request.project_id, request.host, host_run_key).await?;
    let kind = request
        .kind
        .or(existing.as_ref().map(|run| run.kind))
        .unwrap_or(AgentRunKind::Root);
    if let Some(existing) = &existing
        && existing.kind != kind
    {
        return Err(run_conflict(format!(
            "AgentRun {} is already recorded as {:?}",
            existing.run_id, existing.kind
        )));
    }

    let mut affected_runs = if request.source == AgentRunEventSource::Hook
        && request.event_type == AgentRunEventType::Started
        && kind == AgentRunKind::Root
        && existing.is_none()
        && let Some(host_session_id) = request.host_session_id.as_deref()
    {
        recover_prior_root_runs_for_new_hook_turn(
            &mut tx,
            &request.project_id,
            request.host,
            host_session_id,
            host_run_key,
            &received_at,
            &occurred_at,
        )
        .await?
    } else {
        Vec::new()
    };
    let parent = resolve_parent_run(&mut tx, &request, kind).await?;

    let run = if let Some(mut run) = existing {
        if run.host_session_id.is_none() {
            run.host_session_id = request.host_session_id.clone();
        }
        if run.parent_run_id.is_none() {
            run.parent_run_id = parent.as_ref().map(|parent| parent.run_id.clone());
        }
        if let Some(label) = &request.display_label {
            run.display_label = Some(label.clone());
        }
        if let Some(summary) = &request.summary {
            run.summary = Some(summary.clone());
        }
        match request.event_type {
            AgentRunEventType::Started | AgentRunEventType::Heartbeat
                if run.phase == AgentRunPhase::Running =>
            {
                run.last_seen_at = received_at.clone();
                run.lease_expires_at = lease_expires_at.clone();
                run.revision += 1;
                update_run(&mut tx, &run).await?;
            }
            AgentRunEventType::Ended => {
                run.phase = AgentRunPhase::Ended;
                if let Some(outcome) = request.outcome {
                    run.outcome = Some(outcome);
                }
                run.end_reason = Some(HOOK_END_REASON.to_owned());
                run.last_seen_at = received_at.clone();
                if run.ended_at.is_none() {
                    run.ended_at = Some(occurred_at.clone());
                }
                run.revision += 1;
                update_run(&mut tx, &run).await?;
            }
            _ => {}
        }
        run
    } else {
        let ended = request.event_type == AgentRunEventType::Ended;
        let run = AgentRun {
            run_id: format!("arun_{}", Uuid::new_v4().simple()),
            project_id: request.project_id.clone(),
            host: request.host,
            host_run_key: host_run_key.to_owned(),
            host_session_id: request.host_session_id.clone(),
            parent_run_id: parent.as_ref().map(|parent| parent.run_id.clone()),
            kind,
            phase: if ended {
                AgentRunPhase::Ended
            } else {
                AgentRunPhase::Running
            },
            outcome: ended.then_some(request.outcome).flatten(),
            end_reason: ended.then(|| RECOVERED_END_REASON.to_owned()),
            display_label: request.display_label.clone(),
            summary: request.summary.clone(),
            revision: 1,
            started_at: occurred_at.clone(),
            last_seen_at: received_at.clone(),
            lease_expires_at,
            ended_at: ended.then(|| occurred_at.clone()),
        };
        insert_run(
            &mut tx,
            &run,
            request.event_type == AgentRunEventType::Started,
        )
        .await?;
        run
    };
    insert_event(
        &mut tx,
        &request.event_id,
        Some(&event_fingerprint),
        Some(&run.run_id),
        request.host_session_id.as_deref(),
        request.event_type,
        request.source,
        request.outcome,
        request.summary.as_deref(),
        &occurred_at,
    )
    .await?;
    tx.commit().await?;
    let response_run = run.clone();
    affected_runs.push(run);
    Ok(RecordAgentRunEventResponse {
        run: Some(response_run),
        affected_runs,
        duplicate: false,
    })
}

#[allow(clippy::too_many_arguments)]
async fn recover_prior_root_runs_for_new_hook_turn(
    tx: &mut Transaction<'_, Sqlite>,
    project_id: &str,
    host: AgentRunHost,
    host_session_id: &str,
    new_host_run_key: &str,
    received_at: &str,
    occurred_at: &str,
) -> Result<Vec<AgentRun>, DaemonError> {
    let rows = sqlx::query(
        "SELECT run_id, project_id, host, host_run_key, host_session_id,
                parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                revision, started_at, last_seen_at, lease_expires_at, ended_at
         FROM agent_runs
         WHERE project_id = $1 AND host = $2 AND host_session_id = $3
           AND host_run_key <> $4 AND kind = 'root' AND phase = 'running'
         ORDER BY last_seen_at DESC, run_id DESC",
    )
    .bind(project_id)
    .bind(host.as_str())
    .bind(host_session_id)
    .bind(new_host_run_key)
    .fetch_all(&mut **tx)
    .await?;

    let mut recovered = Vec::with_capacity(rows.len());
    for row in rows {
        let mut run = agent_run_from_row(&row)?;
        run.phase = AgentRunPhase::Ended;
        run.outcome = Some(AgentRunOutcome::Unknown);
        run.end_reason = Some(RECOVERED_END_REASON.to_owned());
        run.revision += 1;
        run.last_seen_at = received_at.to_owned();
        if run.ended_at.is_none() {
            run.ended_at = Some(occurred_at.to_owned());
        }
        update_run(tx, &run).await?;
        insert_event(
            tx,
            &format!("arevt_{}", Uuid::new_v4().simple()),
            None,
            Some(&run.run_id),
            run.host_session_id.as_deref(),
            AgentRunEventType::Ended,
            AgentRunEventSource::Recovery,
            run.outcome,
            None,
            occurred_at,
        )
        .await?;
        recovered.push(run);
    }
    Ok(recovered)
}

pub(crate) async fn recover_stale_runs(pool: &SqlitePool) -> Result<u64, DaemonError> {
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let rows = sqlx::query(
        "SELECT run_id, project_id, host, host_run_key, host_session_id,
                parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                revision, started_at, last_seen_at, lease_expires_at, ended_at
         FROM agent_runs
         WHERE phase = 'running'
           AND lease_expires_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         ORDER BY lease_expires_at, run_id",
    )
    .fetch_all(&mut *tx)
    .await?;
    let count = rows.len() as u64;
    for row in rows {
        let mut run = agent_run_from_row(&row)?;
        run.phase = AgentRunPhase::Ended;
        run.outcome = Some(AgentRunOutcome::Unknown);
        run.end_reason = Some(LEASE_EXPIRED_REASON.to_owned());
        run.revision += 1;
        run.ended_at = Some(run.lease_expires_at.clone());
        update_run(&mut tx, &run).await?;
        insert_event(
            &mut tx,
            &format!("arevt_{}", Uuid::new_v4().simple()),
            None,
            Some(&run.run_id),
            run.host_session_id.as_deref(),
            AgentRunEventType::Ended,
            AgentRunEventSource::Recovery,
            run.outcome,
            None,
            &run.lease_expires_at,
        )
        .await?;
    }
    tx.commit().await?;
    Ok(count)
}

fn validate_record_request(request: &RecordAgentRunEventRequest) -> Result<(), DaemonError> {
    validate_required("event_id", &request.event_id, MAX_IDENTIFIER_BYTES)?;
    validate_required("project_id", &request.project_id, MAX_IDENTIFIER_BYTES)?;
    validate_optional(
        "host_run_key",
        request.host_run_key.as_deref(),
        MAX_RUN_KEY_BYTES,
    )?;
    validate_optional(
        "host_session_id",
        request.host_session_id.as_deref(),
        MAX_IDENTIFIER_BYTES,
    )?;
    validate_optional(
        "parent_run_id",
        request.parent_run_id.as_deref(),
        MAX_IDENTIFIER_BYTES,
    )?;
    validate_optional(
        "parent_host_run_key",
        request.parent_host_run_key.as_deref(),
        MAX_RUN_KEY_BYTES,
    )?;
    validate_optional(
        "display_label",
        request.display_label.as_deref(),
        MAX_DISPLAY_LABEL_BYTES,
    )?;
    validate_optional("summary", request.summary.as_deref(), MAX_SUMMARY_BYTES)?;
    validate_optional("occurred_at", request.occurred_at.as_deref(), 64)?;

    match request.event_type {
        AgentRunEventType::SessionEnded => {
            if request.host_run_key.is_some() {
                return Err(DaemonError::InvalidRequest(
                    "session_ended must not include host_run_key".to_owned(),
                ));
            }
            if request.host_session_id.is_none() {
                return Err(DaemonError::InvalidRequest(
                    "session_ended requires host_session_id".to_owned(),
                ));
            }
            if !matches!(request.outcome, None | Some(AgentRunOutcome::Unknown)) {
                return Err(DaemonError::InvalidRequest(
                    "session_ended outcome must be unknown".to_owned(),
                ));
            }
        }
        AgentRunEventType::Started | AgentRunEventType::Heartbeat => {
            if request.host_run_key.is_none() {
                return Err(DaemonError::InvalidRequest(
                    "run lifecycle events require host_run_key".to_owned(),
                ));
            }
            if request.outcome.is_some() {
                return Err(DaemonError::InvalidRequest(
                    "start and heartbeat events must not include outcome".to_owned(),
                ));
            }
        }
        AgentRunEventType::Ended => {
            if request.host_run_key.is_none() {
                return Err(DaemonError::InvalidRequest(
                    "run lifecycle events require host_run_key".to_owned(),
                ));
            }
        }
    }
    if request.kind == Some(AgentRunKind::Root)
        && (request.parent_run_id.is_some() || request.parent_host_run_key.is_some())
    {
        return Err(DaemonError::InvalidRequest(
            "a root AgentRun cannot have a parent".to_owned(),
        ));
    }
    Ok(())
}

fn validate_required(name: &str, value: &str, max_bytes: usize) -> Result<(), DaemonError> {
    if value.trim().is_empty() {
        return Err(DaemonError::InvalidRequest(format!(
            "{name} must not be empty"
        )));
    }
    if value.len() > max_bytes {
        return Err(DaemonError::InvalidRequest(format!(
            "{name} must not exceed {max_bytes} UTF-8 bytes"
        )));
    }
    Ok(())
}

fn validate_optional(name: &str, value: Option<&str>, max_bytes: usize) -> Result<(), DaemonError> {
    if let Some(value) = value {
        validate_required(name, value, max_bytes)?;
    }
    Ok(())
}

fn canonical_json_fingerprint(value: &impl Serialize) -> Result<String, DaemonError> {
    let value = serde_json::to_value(value)?;
    let mut canonical = String::new();
    write_canonical_json(&value, &mut canonical)?;
    Ok(format!(
        "sha256:{}",
        hex::encode(Sha256::digest(canonical.as_bytes()))
    ))
}

fn write_canonical_json(value: &serde_json::Value, output: &mut String) -> Result<(), DaemonError> {
    match value {
        serde_json::Value::Null => output.push_str("null"),
        serde_json::Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
        serde_json::Value::Number(value) => output.push_str(&value.to_string()),
        serde_json::Value::String(value) => output.push_str(&serde_json::to_string(value)?),
        serde_json::Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(']');
        }
        serde_json::Value::Object(values) => {
            output.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                output.push_str(&serde_json::to_string(key)?);
                output.push(':');
                write_canonical_json(&values[key], output)?;
            }
            output.push('}');
        }
    }
    Ok(())
}

async fn db_clock(tx: &mut Transaction<'_, Sqlite>) -> Result<(String, String), DaemonError> {
    let row = sqlx::query(
        "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now') AS now,
                strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+24 hours') AS lease_expires_at",
    )
    .fetch_one(&mut **tx)
    .await?;
    Ok((row.try_get("now")?, row.try_get("lease_expires_at")?))
}

async fn normalize_occurred_at(
    tx: &mut Transaction<'_, Sqlite>,
    value: Option<&str>,
    fallback: &str,
) -> Result<String, DaemonError> {
    let Some(value) = value else {
        return Ok(fallback.to_owned());
    };
    let normalized: Option<String> =
        sqlx::query_scalar("SELECT strftime('%Y-%m-%dT%H:%M:%fZ', $1)")
            .bind(value)
            .fetch_one(&mut **tx)
            .await?;
    normalized.ok_or_else(|| {
        DaemonError::InvalidRequest("occurred_at must be a valid RFC 3339 timestamp".to_owned())
    })
}

#[derive(Debug)]
struct ExistingAgentRunEvent {
    run_id: Option<String>,
    event_fingerprint: String,
}

async fn load_existing_event(
    tx: &mut Transaction<'_, Sqlite>,
    event_id: &str,
) -> Result<Option<ExistingAgentRunEvent>, DaemonError> {
    let row = sqlx::query(
        "SELECT run_id, event_fingerprint
         FROM agent_run_events WHERE event_id = $1",
    )
    .bind(event_id)
    .fetch_optional(&mut **tx)
    .await?;
    row.map(|row| {
        Ok(ExistingAgentRunEvent {
            run_id: row.try_get("run_id")?,
            event_fingerprint: row.try_get("event_fingerprint")?,
        })
    })
    .transpose()
}

async fn duplicate_run_event_response(
    tx: &mut Transaction<'_, Sqlite>,
    request: &RecordAgentRunEventRequest,
    run_id: Option<&str>,
) -> Result<RecordAgentRunEventResponse, DaemonError> {
    let run_id = run_id.ok_or_else(|| {
        corrupt_run(format!(
            "non-session event {} does not reference an AgentRun",
            request.event_id
        ))
    })?;
    let run = load_agent_run_tx(tx, run_id).await?.ok_or_else(|| {
        corrupt_run(format!(
            "event {} references missing AgentRun {run_id}",
            request.event_id
        ))
    })?;
    if run.project_id != request.project_id || run.host != request.host {
        return Err(corrupt_run(format!(
            "event {} fingerprint points to an inconsistent AgentRun",
            request.event_id
        )));
    }
    Ok(RecordAgentRunEventResponse {
        run: Some(run.clone()),
        affected_runs: vec![run],
        duplicate: true,
    })
}

async fn resolve_parent_run(
    tx: &mut Transaction<'_, Sqlite>,
    request: &RecordAgentRunEventRequest,
    kind: AgentRunKind,
) -> Result<Option<AgentRun>, DaemonError> {
    if kind == AgentRunKind::Root {
        return Ok(None);
    }
    let by_id = if let Some(parent_run_id) = request.parent_run_id.as_deref() {
        Some(
            load_agent_run_tx(tx, parent_run_id)
                .await?
                .ok_or_else(|| DaemonError::NotFound(format!("AgentRun {parent_run_id}")))?,
        )
    } else {
        None
    };
    let by_host_key = if let Some(parent_host_run_key) = request.parent_host_run_key.as_deref() {
        load_run_by_host_key(tx, &request.project_id, request.host, parent_host_run_key).await?
    } else {
        None
    };
    if let (Some(by_id), Some(by_host_key)) = (&by_id, &by_host_key)
        && by_id.run_id != by_host_key.run_id
    {
        return Err(run_conflict(
            "parent_run_id and parent_host_run_key resolve to different runs".to_owned(),
        ));
    }
    let parent = by_id.or(by_host_key);
    if let Some(parent) = &parent {
        if parent.project_id != request.project_id || parent.host != request.host {
            return Err(run_conflict(
                "an AgentRun parent must belong to the same project and host".to_owned(),
            ));
        }
        if parent.kind != AgentRunKind::Root {
            return Err(run_conflict(
                "a subagent AgentRun parent must be a root run".to_owned(),
            ));
        }
    }
    Ok(parent)
}

async fn load_run_by_host_key(
    tx: &mut Transaction<'_, Sqlite>,
    project_id: &str,
    host: AgentRunHost,
    host_run_key: &str,
) -> Result<Option<AgentRun>, DaemonError> {
    let row = sqlx::query(
        "SELECT run_id, project_id, host, host_run_key, host_session_id,
                parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                revision, started_at, last_seen_at, lease_expires_at, ended_at
         FROM agent_runs
         WHERE project_id = $1 AND host = $2 AND host_run_key = $3",
    )
    .bind(project_id)
    .bind(host.as_str())
    .bind(host_run_key)
    .fetch_optional(&mut **tx)
    .await?;
    row.as_ref().map(agent_run_from_row).transpose()
}

async fn load_agent_run_tx(
    tx: &mut Transaction<'_, Sqlite>,
    run_id: &str,
) -> Result<Option<AgentRun>, DaemonError> {
    let row = sqlx::query(
        "SELECT run_id, project_id, host, host_run_key, host_session_id,
                parent_run_id, kind, phase, outcome, end_reason, display_label, summary,
                revision, started_at, last_seen_at, lease_expires_at, ended_at
         FROM agent_runs WHERE run_id = $1",
    )
    .bind(run_id)
    .fetch_optional(&mut **tx)
    .await?;
    row.as_ref().map(agent_run_from_row).transpose()
}

async fn insert_run(
    tx: &mut Transaction<'_, Sqlite>,
    run: &AgentRun,
    start_observed: bool,
) -> Result<(), DaemonError> {
    sqlx::query(
        "INSERT INTO agent_runs (
            run_id, project_id, host, host_run_key, host_session_id, parent_run_id,
            kind, phase, outcome, end_reason, display_label, summary, revision,
            start_observed, started_at, last_seen_at, lease_expires_at, ended_at
         ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            $14, $15, $16, $17, $18
         )",
    )
    .bind(&run.run_id)
    .bind(&run.project_id)
    .bind(run.host.as_str())
    .bind(&run.host_run_key)
    .bind(&run.host_session_id)
    .bind(&run.parent_run_id)
    .bind(run.kind.as_str())
    .bind(run.phase.as_str())
    .bind(run.outcome.map(AgentRunOutcome::as_str))
    .bind(&run.end_reason)
    .bind(&run.display_label)
    .bind(&run.summary)
    .bind(run.revision)
    .bind(start_observed)
    .bind(&run.started_at)
    .bind(&run.last_seen_at)
    .bind(&run.lease_expires_at)
    .bind(&run.ended_at)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn update_run(tx: &mut Transaction<'_, Sqlite>, run: &AgentRun) -> Result<(), DaemonError> {
    let result = sqlx::query(
        "UPDATE agent_runs
         SET host_session_id = $2, parent_run_id = $3, kind = $4, phase = $5,
             outcome = $6, end_reason = $7, display_label = $8, summary = $9,
             revision = $10, last_seen_at = $11, lease_expires_at = $12,
             ended_at = $13
         WHERE run_id = $1",
    )
    .bind(&run.run_id)
    .bind(&run.host_session_id)
    .bind(&run.parent_run_id)
    .bind(run.kind.as_str())
    .bind(run.phase.as_str())
    .bind(run.outcome.map(AgentRunOutcome::as_str))
    .bind(&run.end_reason)
    .bind(&run.display_label)
    .bind(&run.summary)
    .bind(run.revision)
    .bind(&run.last_seen_at)
    .bind(&run.lease_expires_at)
    .bind(&run.ended_at)
    .execute(&mut **tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(DaemonError::NotFound(format!("AgentRun {}", run.run_id)));
    }
    Ok(())
}

#[derive(Serialize)]
struct StoredAgentRunEventFingerprint<'a> {
    event_id: &'a str,
    run_id: Option<&'a str>,
    host_session_id: Option<&'a str>,
    event_type: AgentRunEventType,
    source: AgentRunEventSource,
    outcome: Option<AgentRunOutcome>,
    summary: Option<&'a str>,
    occurred_at: &'a str,
}

#[allow(clippy::too_many_arguments)]
async fn insert_event(
    tx: &mut Transaction<'_, Sqlite>,
    event_id: &str,
    supplied_fingerprint: Option<&str>,
    run_id: Option<&str>,
    host_session_id: Option<&str>,
    event_type: AgentRunEventType,
    source: AgentRunEventSource,
    outcome: Option<AgentRunOutcome>,
    summary: Option<&str>,
    occurred_at: &str,
) -> Result<(), DaemonError> {
    let generated_fingerprint = if supplied_fingerprint.is_none() {
        Some(canonical_json_fingerprint(
            &StoredAgentRunEventFingerprint {
                event_id,
                run_id,
                host_session_id,
                event_type,
                source,
                outcome,
                summary,
                occurred_at,
            },
        )?)
    } else {
        None
    };
    let event_fingerprint = supplied_fingerprint
        .or(generated_fingerprint.as_deref())
        .expect("an event fingerprint is always supplied or generated");
    sqlx::query(
        "INSERT INTO agent_run_events (
            event_id, event_fingerprint, run_id, host_session_id, event_type,
            source, outcome, summary, occurred_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(event_id)
    .bind(event_fingerprint)
    .bind(run_id)
    .bind(host_session_id)
    .bind(event_type.as_str())
    .bind(source.as_str())
    .bind(outcome.map(AgentRunOutcome::as_str))
    .bind(summary)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

fn agent_run_from_row(row: &SqliteRow) -> Result<AgentRun, DaemonError> {
    let host: String = row.try_get("host")?;
    let kind: String = row.try_get("kind")?;
    let phase: String = row.try_get("phase")?;
    let outcome: Option<String> = row.try_get("outcome")?;
    Ok(AgentRun {
        run_id: row.try_get("run_id")?,
        project_id: row.try_get("project_id")?,
        host: AgentRunHost::from_db(&host)?,
        host_run_key: row.try_get("host_run_key")?,
        host_session_id: row.try_get("host_session_id")?,
        parent_run_id: row.try_get("parent_run_id")?,
        kind: AgentRunKind::from_db(&kind)?,
        phase: AgentRunPhase::from_db(&phase)?,
        outcome: outcome
            .as_deref()
            .map(AgentRunOutcome::from_db)
            .transpose()?,
        end_reason: row.try_get("end_reason")?,
        display_label: row.try_get("display_label")?,
        summary: row.try_get("summary")?,
        revision: row.try_get("revision")?,
        started_at: row.try_get("started_at")?,
        last_seen_at: row.try_get("last_seen_at")?,
        lease_expires_at: row.try_get("lease_expires_at")?,
        ended_at: row.try_get("ended_at")?,
    })
}

fn run_conflict(message: impl Into<String>) -> DaemonError {
    DaemonError::State {
        code: "agent_run_conflict",
        message: message.into(),
    }
}

fn corrupt_run(message: impl Into<String>) -> DaemonError {
    DaemonError::State {
        code: "agent_run_corrupt",
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::sqlite::SqlitePoolOptions;

    fn request(event_id: &str, event_type: AgentRunEventType) -> RecordAgentRunEventRequest {
        RecordAgentRunEventRequest {
            event_id: event_id.to_owned(),
            project_id: "prj_test".to_owned(),
            host: AgentRunHost::Codex,
            host_run_key: Some("thread-1".to_owned()),
            event_type,
            source: AgentRunEventSource::Hook,
            host_session_id: Some("session-1".to_owned()),
            parent_run_id: None,
            parent_host_run_key: None,
            kind: Some(AgentRunKind::Root),
            outcome: None,
            display_label: None,
            summary: None,
            occurred_at: Some("2026-09-03T00:00:00Z".to_owned()),
        }
    }

    async fn test_pool() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        migrate(&pool).await.unwrap();
        pool
    }

    #[tokio::test]
    async fn lifecycle_events_are_idempotent() {
        let pool = test_pool().await;
        let first = record_agent_run_event(&pool, request("evt-start", AgentRunEventType::Started))
            .await
            .unwrap();
        let duplicate =
            record_agent_run_event(&pool, request("evt-start", AgentRunEventType::Started))
                .await
                .unwrap();

        assert_eq!(first.run, duplicate.run);
        assert!(duplicate.duplicate);
    }

    #[tokio::test]
    async fn session_end_closes_running_runs() {
        let pool = test_pool().await;
        record_agent_run_event(&pool, request("evt-start", AgentRunEventType::Started))
            .await
            .unwrap();
        let mut ended = request("evt-session-end", AgentRunEventType::SessionEnded);
        ended.host_run_key = None;
        ended.kind = None;
        let response = record_agent_run_event(&pool, ended).await.unwrap();

        assert_eq!(response.affected_runs.len(), 1);
        assert_eq!(response.affected_runs[0].phase, AgentRunPhase::Ended);
        assert_eq!(
            response.affected_runs[0].outcome,
            Some(AgentRunOutcome::Unknown)
        );
    }
}
