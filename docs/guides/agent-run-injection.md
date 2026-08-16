# AgentRun lifecycle and Hook coordination

This page describes how the resident daemon observes coding-Agent lifecycle
events, how a current `run_id` reaches the Agent, and where semantic Issue
decisions happen.

## Process boundary

Adapter-managed Hooks and the opencode plugin invoke the App-bundled Rust
runtime directly:

```text
Agent host
  -> clumsiesd _agent issue-run-event --host <host>
  -> verify resident protocol revision + build identity
  -> resolve current directory to canonical Project
  -> normalize the event to a bounded typed request
  -> resident clumsiesd over XPC
```

`_agent issue-run-event` is a short-lived proxy mode of the same signed
`clumsiesd` that launchd runs as the resident daemon. It does not initialize a
database, model, search worker, or sync worker. Adapter pins its exact
App-bundled path; it does not search a checkout, `PATH`, or a helper directory.

## Why AgentRuns exist

An `AgentRun` is the daemon-side record of one root turn or subagent execution.
It provides:

- a durable identity for auditing native Issue mutations;
- root/subagent authority boundaries;
- optimistic concurrency through the run revision;
- a lease and terminal outcome for board staleness;
- recovery when a host session ends unexpectedly.

Lifecycle events do not infer an Issue from prompt text. A run may remain
unbound, and one active Issue cannot be claimed by a second active run.

## Event mapping

| Host | Observed events | Integration surface |
| --- | --- | --- |
| Codex | `UserPromptSubmit`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionEnd` | `.codex/hooks.json` → managed shell Hook |
| Claude Code | the common set plus `StopFailure` | `.claude/settings.json` → managed shell Hook |
| opencode | user message, completed/failed assistant message, deleted session | managed plugin maps them to `UserPromptSubmit`, `Stop`/`StopFailure`, and `SessionEnd` |
| dsh | the same hook vocabulary (`UserPromptSubmit`, `Stop`/`StopFailure`, `SubagentStart`/`SubagentStop`, `SessionEnd`) | dsh client plugin pipes events to `clumsiesd _agent issue-run-event --host dsh` |

The resident daemon upserts a run by Project, host, and host run key. Stable
event IDs make delivery idempotent; replaying the same event is a no-op, while
reusing an ID with different content is rejected.

## Injected context

After a successful root `UserPromptSubmit` or `SubagentStart`, the proxy prints
host-native JSON containing bounded `additionalContext`. It includes the
current run ID, revision, and whether the run is already bound to an Issue.

Root context tells the Agent to:

1. use `kanban.list` or `kanban.get` to inspect real board state;
2. create durable work only when appropriate;
3. call `kanban.begin_work` only for the active line of work and only when no
   other run already holds the Issue;
4. call `kanban.request_closure` only after judging acceptance criteria;
5. otherwise leave the Issue In Progress.

Subagent context allows explicit work binding but forbids requesting closure;
the subagent reports findings to the root Agent instead.

## Stop is a reminder, not a decision

For Codex and Claude Code, the first root Stop becomes a distinct non-terminal
heartbeat probe. The proxy asks the host to continue once so the Agent can make
the semantic Kanban decision itself. If the Issue is ready, the Agent calls
`kanban.request_closure`; if it is not ready, the Agent makes no state change.

The follow-up Stop records the run end. A duplicate probe does not ask again.
`StopFailure` records a failed outcome, and `SessionEnd` ends remaining runs for
the session. No Stop event advances, approves, or closes an Issue.

opencode forwards the lifecycle events exposed by its plugin API but does not
synthesize an unsupported stop-blocking exchange.

## Privacy and failure behavior

The proxy reads at most 1 MiB and reduces raw host JSON in memory to an
allowlist: session and turn/agent identifiers, parent key, workspace path,
bounded display label, event type, and outcome. Oversized identifiers are
hashed; bounded labels are validated and truncated.

Prompts, transcripts, assistant messages, tool inputs, and raw failure details
do not cross XPC and are never persisted by this bridge. Hook wrappers are
fail-open: malformed input, a missing Project binding, runtime identity
mismatch, and IPC failure must not prevent the Agent host from continuing.

## Observation and semantic mutation

The two paths are deliberately separate:

```text
Hook lifecycle event -> record_agent_run_event -> AgentRun observation
Agent judgment       -> MCP kanban operation   -> Issue transition
```

The private bridge is not an MCP tool. Conversely, `kanban.begin_work`, pause,
resume, unclaim, and `request_closure` do not pretend to be host lifecycle
events. This keeps transport telemetry from becoming product intent.

## Implementation map

| Concern | Active path |
| --- | --- |
| Proxy dispatch, runtime identity gate, and injected context | `crates/daemon/src/main.rs` |
| Host payload normalization | `crates/daemon/src/agent_runtime/hook.rs` |
| AgentRun persistence and Issue transitions | `crates/daemon/src/work_tracking.rs` |
| Adapter rendering and migration | `crates/daemon/src/agent_adapter.rs` |
| Codex / Claude Code Hook templates | `assets/adapters/*/runtime/hooks/issue-run-event.sh.tpl` |
| opencode plugin | `assets/adapters/opencode/runtime/plugin.ts` |
