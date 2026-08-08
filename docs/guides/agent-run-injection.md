# AgentRun Injection and Hook Coordination

This document describes how the daemon learns about coding-agent lifecycle
events, how the resulting `run_id` reaches the agent's reasoning context, and
how the two supported hosts (Codex and Claude Code) differ in their hook
plumbing.

## 1. Why runs exist

An `AgentRun` is the daemon-side record of one host turn (root) or one subagent
execution. It is the unit that:

- **audits** issue mutations: `native_issues.changed_by_run_id` and
  `issue_workflow_states.changed_by_run_id` record which run moved an issue
  (`crates/daemon/src/work_tracking.rs`);
- **grants authority**: only a *root* run may call `kanban.request_closure`;
  subagents must report findings to the root agent (injected text enforces
  this; the daemon validates it);
- **provides optimistic concurrency**: mutations carry `expected_revision` and
  the run's own revision, so stale writers are rejected;
- **drives staleness**: an issue in `In Progress` with no active runs and no
  activity for 24 h is flagged stale on the board (`docs/issue-board-design.md`);
- **survives crashes**: a `SessionEnd` event ends every still-running run of
  that session, and expired leases (`lease_expires_at`) are treated as
  inactive.

## 2. Why hooks, not tools

MCP tools are invoked *by the agent*; the daemon never hears about a turn the
agent does not mention. Host hooks fire *regardless*, at well-defined moments
(prompt submitted, stop requested, subagent started/stopped, session ended).
That makes hooks the only reliable observation point for:

- injecting the run identity *before* the agent starts reasoning,
- blocking a Claude Code Stop once so the closure decision is actually made,
- ending runs when a session dies without the agent calling anything.

## 3. Design principles

- **Observation vs decision are separated.** Hooks observe and inject context;
  they never change issue state. Only explicit agent calls
  (`kanban.create`, `kanban.begin_work`, `kanban.request_closure`) do.
- **Fail-open.** Every hook script and the private command exit successfully
  on any failure; lifecycle observation never blocks the host agent.
- **Privacy boundary.** The raw host event JSON is reduced in memory to a
  bounded allowlist of identifiers (session id, turn id, agent id, workspace
  path, label). Prompts, transcripts, tool payloads, and assistant messages
  never cross the daemon IPC boundary.
- **Idempotent.** `event_id` is a stable hash of
  `host + session + event name + run key`, and the daemon rejects replaying a
  different payload under the same id (event fingerprint).

## 4. Registered lifecycle events

Both hosts wire their lifecycle events to the single `issue-run-event.sh`
hook; the mappings are rendered by the adapter packages:

| Host | Events → script | Where rendered |
|---|---|---|
| Codex | `UserPromptSubmit`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionEnd` → `hooks/issue-run-event.sh` | `src/client/adapter/packages/codex.zig` (`renderHooksRegistry`) |
| Claude Code | `UserPromptSubmit`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionEnd`, `StopFailure` → `hooks/issue-run-event.sh`; `SessionStart` → `hooks/session-start.sh` | `src/client/adapter/packages/claude_code.zig` |

Codex has no `SessionStart` hook; this is a deliberate difference (see
section 9).

## 5. Event flow

1. The host fires a lifecycle event and runs the registered script with the
   raw event JSON on stdin.
2. The script sources `resolve-binary.sh`, which locates the `clumsies`
   binary: `CLUMSIES_ADAPTER_BINARY` → project `zig-out/bin/clumsies` (Codex)
   → `PATH` → `~/.clumsies/bin/clumsies`. Missing binary → silent exit.
3. The script pipes stdin to
   `clumsies _agent issue-run-event --host codex|claude-code`
   (`src/client/commands/issue_run_event_cmd.zig`).
4. The command normalizes the payload:
   - `event_id = "hook_" + sha256(host, session_id, event_name, run_key)`;
   - `host_run_key`: `root:<turn_id>` (Codex) / `root:<prompt_id>` (Claude
     Code), or `subagent:<session_id>:<agent_id>`;
   - identifiers longer than 256 bytes are replaced by `sha256:<digest>`;
     labels are UTF-8-checked and truncated to 160 bytes.
5. The command calls the daemon IPC `record_agent_run_event`
   (`crates/daemon/src/work_tracking.rs`), which upserts the run
   (`UNIQUE (project_id, host, host_run_key)`), advances its revision, renews
   the lease, records the event row, and transitions phase
   (`started` → running; `ended` → ended with outcome; `session_ended` → ends
   the session's running runs with outcome `unknown`).
6. On a successful **started** event (`UserPromptSubmit`, `SubagentStart`),
   the command emits a context JSON on stdout containing the run's `run_id`
   and revision plus a semantic decision instruction; the host adds it to the
   agent's context.

## 6. Injected context

Root prompt (`UserPromptSubmit`):

> Clumsies current root AgentRun: run_id=..., revision=.... Decide semantically
> whether this prompt continues an existing native Issue, creates a new
> durable Issue, or should not become an Issue; never infer that from text
> matching. Use `kanban.list` to inspect existing Issues and `kanban.create` to
> capture a new one. Call `kanban.begin_work` with this run_id and revision
> only when the Issue is the active line of work. Capture unrelated follow-up
> work with `kanban.create` but do not call `kanban.begin_work`, so it remains
> Todo. Before finishing, call `kanban.request_closure` only when the linked
> Issue's acceptance criteria are satisfied; otherwise leave it In Progress.
> AgentRun Stop never advances, approves, or closes an Issue.

Subagent start (`SubagentStart`):

> Clumsies current subagent AgentRun: run_id=..., revision=.... Call
> `kanban.begin_work` only when this subagent is explicitly working an existing
> native Issue. Subagents must not request Issue closure; report findings to
> the root Agent. AgentRun Stop never advances or closes an Issue.

Codex Stop reminder (`additionalContext`):

> Before ending, make an explicit semantic Issue decision. If the current root
> task is linked to an In Progress Issue and its acceptance criteria are
> satisfied, call `kanban.request_closure` with the current run_id and
> revision. Otherwise leave it In Progress. Stop itself never completes or
> advances an Issue.

Claude Code first Stop (`decision: block`):

> Before stopping, make the explicit semantic Issue decision now. ... call
> `kanban.request_closure` with the current run_id and revision. ... If you
> already made the appropriate decision, stop again without another mutation.

## 7. Claude Code Stop blocking

Claude Code's first Stop is a *decision point*, not a run end. The hook emits
`{"decision":"block", ...}`, which interrupts the stop once and forces the
closure decision. The follow-up Stop carries `stop_hook_active=true`; only that
one is recorded as `ended` (unless it is a `StopFailure`, which records
`outcome=failed`). Codex cannot block stops; it receives the reminder text
instead.

## 8. Session end and leases

`SessionEnd` ends every running run of the host session with outcome `unknown`
and `end_reason=session_ended` (the daemon keeps `end_reason` first-write-wins
for `agent_report`). Each recorded event renews `lease_expires_at`; a run
whose lease expires is no longer counted as active, which feeds the board's
stale computation.

## 9. Host differences

### Claude Code keeps `SessionStart` + `workspace-info`; Codex does not

Claude Code installs `hooks/session-start.sh` (`SessionStart` event). On every
session start it:

1. writes `export CLAUDE_PROJECT_DIR=...` into `$CLAUDE_ENV_FILE` so the other
   hooks know the project root (Claude Code hooks have no reliable cwd —
   `resolve-binary.sh` falls back to `$PWD` only when the env var is absent);
2. runs `clumsies _agent workspace-info`
   (`src/client/commands/workspace_info_cmd.zig`), which resolves the
   workspace binding for the current directory and prints `WS_ID=` and
   `CACHE_DIR=` lines (deliberately not shell-eval-able; parsed with
   `while IFS='=' read`);
3. scans `$CACHE_DIR/workflow/*.md` (the synchronized workflow rule cache) and
   generates a thin `SKILL.md` proxy for each rule that does not already have
   one, under the rendered `WORKFLOW_SKILLS_DIR` (`.claude/skills` for
   workspace scope, disabled for user scope).

Codex has no such hook. Per `d675aa8` ("adapter: import workflow-backed
skills from cache"): workflow skill auto-import runs **during
`clumsies adapt` / `clumsies adapt --update`**, from the synchronized cache
manifest, **not from a Codex SessionStart hook** — and the runtime test
"runtime no longer injects a SessionStart memory bootstrap" pins that
decision. Codex hooks can locate the repository via `git rev-parse
--show-toplevel` in `resolve-binary.sh`, so they never needed
`workspace-info`.

Rationale for the asymmetry:

- Codex resolves the project root from git, so its hooks do not need a
  workspace-info lookup.
- Claude Code's hooks receive the project root through the environment file
  written by `session-start.sh`; the same hook doubles as the place to
  incrementally sync newly synchronized workflow rules into skills, because
  Claude Code discovers skills at session start and rules arrive in the cache
  asynchronously from the server.
- Codex re-runs `clumsies adapt --update` to refresh workflow skill proxies;
  the install-time import path is shared by both hosts
  (`src/client/adapter/workflow_skills.zig`).

### Other differences

- Claude Code registers `StopFailure`; Codex has no equivalent event.
- Claude Code blocks the first Stop; Codex only receives reminder context.

## 10. Zed status

The `zed_extension_api` crate (latest 0.7.0, 2026-07) exposes no lifecycle
hook surface: the `Extension` trait has 19 methods covering language servers,
slash commands, context servers (MCP), DAP, docs indexing, and
completion/label helpers — there is no `on_event`, no prompt/stop callback.
Zed therefore cannot participate in this hook protocol. The supported
integration is MCP-only (issue `ISSUE-008`), and run tracking for Zed needs
one of:

- an MCP-session-scoped run created by the daemon at session initialize
  (`host=zed`, keyed by session id); or
- a lazily created anonymous run on `kanban.begin_work` without `run_id`,
  relying on the existing lease-expiry machinery to end it.

Both options are tracked in `ISSUE-018`.

## 11. File index

| Concern | Path |
|---|---|
| Hook scripts (Codex) | `assets/adapters/codex/runtime/hooks/` |
| Hook scripts (Claude Code) | `assets/adapters/claude-code/runtime/hooks/` |
| Event → script registration | `src/client/adapter/packages/codex.zig`, `src/client/adapter/packages/claude_code.zig` |
| Private bridge command | `src/client/commands/issue_run_event_cmd.zig` |
| Workspace info command | `src/client/commands/workspace_info_cmd.zig` |
| Run records and events | `crates/daemon/src/work_tracking.rs` |
| Run ↔ Issue transitions | `crates/daemon/src/work_tracking.rs` (`start_issue_work`, `request_issue_closure`) |
| Workflow skill import | `src/client/adapter/workflow_skills.zig` |
