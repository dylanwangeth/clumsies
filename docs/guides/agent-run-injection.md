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
| Codex | `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `SessionEnd` | App-managed global Clumsies Plugin Hook after the user trusts its current hash in `/hooks`; repository binding supplies the Project, with no project Hook files or root `Stop` registration |
| Claude Code | the Codex set plus `StopFailure` | `.claude/settings.json` → managed shell Hook; no root `Stop` registration |
| Antigravity | `PreInvocation` | `.agents/hooks.json` → managed shell Hook; no root `Stop` registration |
| opencode | user message, failed assistant message, deleted session | managed plugin maps them to `UserPromptSubmit`, `StopFailure`, and `SessionEnd`; successful completion emits no `Stop` |
| dsh | turn start, failed turn, session disposal | dsh client plugin forwards non-blocking root events to `clumsiesd _agent issue-run-event --host dsh`; successful completion emits no `Stop` |

The resident daemon upserts a run by Project, host, and host run key. Stable
event IDs make delivery idempotent; replaying the same event is a no-op, while
reusing an ID with different content is rejected.

When a new root turn starts in the same host session, the daemon recovery-ends
any still-running prior root turn before creating the new run. This rollover is
only lifecycle bookkeeping: it does not advance the prior Issue or decide that
the new turn continues it. `SessionEnd` closes the final outstanding turn.

## Injected context

After a successful root `UserPromptSubmit` or `SubagentStart`, the proxy prints
host-native JSON containing bounded `additionalContext`. It includes the
current run ID, revision, and whether the run is already bound to an Issue.

Root context tells the Agent to:

1. use `kanban.list` or `kanban.get` to inspect real board state;
2. create durable work only when appropriate;
3. call `kanban.begin_work` only for the active line of work and only when no
   other run already holds the Issue.

Closure policy is not injected by a lifecycle callback. An opt-in skill or a
manually maintained workflow decides when acceptance criteria are satisfied
and explicitly calls `kanban.request_closure`; otherwise the Issue stays In
Progress.

Subagent context allows explicit work binding but forbids requesting closure;
the subagent reports findings to the root Agent instead.

## Normal root Stop is not managed

Managed integrations do not register or synthesize a normal root `Stop` and
the proxy never asks a host to continue so that it can inject a closure
reminder. This avoids making lifecycle telemetry part of the Agent's control
flow. `StopFailure` records a failed root outcome, `SubagentStop` ends a
subagent observation, and `SessionEnd` ends remaining runs for the session.

For cleanup compatibility, the private bridge still accepts `Stop` from an
older installation or a manually maintained hook. It records a terminal
AgentRun observation without returning a block decision, calling `kanban`, or
advancing an Issue. New adapters do not produce that input.

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
Hook lifecycle event        -> record_agent_run_event -> AgentRun observation
Skill/manual Agent judgment -> MCP kanban operation   -> Issue transition
```

Codex skips a new or changed plugin Hook until the user reviews and trusts it
through `/hooks`. Clumsies never bypasses that decision. Memory and non-run-bound
Kanban reads remain available, while `begin_work` and closure must wait for a
real Hook-injected run ID.

The private bridge is not an MCP tool. Conversely, `kanban.begin_work`, pause,
resume, unclaim, and `request_closure` do not pretend to be host lifecycle
events. This keeps transport telemetry from becoming product intent.

## Implementation map

| Concern | Active path |
| --- | --- |
| Proxy dispatch, runtime identity gate, and injected run context | `crates/daemon/src/main.rs` |
| Host payload normalization | `crates/daemon/src/agent_runtime/hook.rs` |
| AgentRun persistence and Issue transitions | `crates/daemon/src/work_tracking.rs` |
| Adapter rendering and migration | `crates/daemon/src/agent_adapter.rs` |
| Codex plugin reconciliation and Hook template | `crates/daemon/src/agent_adapter/codex_plugin.rs`, `packages/clumsies/scripts/issue-run-event.sh.tpl` |
| Direct-file Hook templates | `assets/adapters/*/runtime/hooks/issue-run-event.sh.tpl` |
| opencode plugin | `assets/adapters/opencode/runtime/plugin.ts` |
