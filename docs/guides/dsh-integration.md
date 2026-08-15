# DeepSeek Harness (dsh) Integration

The Clumsies daemon treats the DeepSeek Harness web app as a first-class
Agent host ("dsh"). This guide covers both halves of the integration:

1. **MCP access** — the dsh web profile connects to the Clumsies MCP server,
   which gives the model `mcp__clumsies__activate / load / store / kanban`.
2. **AgentRun lifecycle** — a dsh-side client plugin forwards session/turn
   events to the daemon's hook proxy, which issues and ends `dsh` AgentRuns.
   With a live run the model can `kanban.begin_work` and
   `kanban.request_closure` exactly like codex or Claude Code sessions.

## MCP access (read + mutate content)

Register the Clumsies MCP server in the dsh profile patch layer
(`~/.dsh/profiles/<profile>/cordis.patch.yml`):

```yaml
- insert:
    - id: mcp-clumsies
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: clumsies
        transport: stdio
        command: /Users/weiwang/Applications/Clumsies.app/Contents/Resources/clumsiesd
        args: [mcp, serve]
        cwd: /path/to/workspace
```

`cwd` pins the proxy to the project whose kanban the session should see
(kanban scope follows the workspace binding). Tools appear as
`mcp__clumsies__*` and are usable without any AgentRun, but
`kanban.begin_work` / `kanban.request_closure` require a live run issued
by the hook (see below) — the daemon never lets an agent mint its own
identity.

## AgentRun lifecycle hook

The daemon accepts hook events from the `dsh` host:

```sh
printf '%s' "$PAYLOAD" | clumsiesd _agent issue-run-event --host dsh
```

`$PAYLOAD` is a JSON object with the shared hook vocabulary:

| Field | Required | Meaning |
|---|---|---|
| `hook_event_name` | yes | `UserPromptSubmit`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `SessionEnd` |
| `session_id` | yes | dsh session id (e.g. `session-…`); deduplicates events |
| `turn_id` | root events | one id per user prompt, reused by the matching `Stop`/`StopFailure` |
| `agent_id` | subagent events | subagent id (`subagent:…`) |
| `agent_type` | subagent events | display label for the subagent run |
| `cwd` | no | workspace path; resolves the project binding when present |
| `error` | `StopFailure` | ignored (never stored) |

Example turn lifecycle:

```json
{"hook_event_name":"UserPromptSubmit","session_id":"session-abc","turn_id":"turn-001","cwd":"/work/repo"}
{"hook_event_name":"Stop","session_id":"session-abc","turn_id":"turn-001"}
{"hook_event_name":"SubagentStart","session_id":"session-abc","turn_id":"turn-001","agent_id":"sub-1","agent_type":"reviewer"}
{"hook_event_name":"SubagentStop","session_id":"session-abc","turn_id":"turn-001","agent_id":"sub-1","agent_type":"reviewer"}
{"hook_event_name":"SessionEnd","session_id":"session-abc"}
```

The hook proxy is fail-open: a missing daemon or a malformed payload never
blocks the dsh session.

### Wiring the dsh side

A small client plugin in the dsh web profile subscribes to session lifecycle
events and forwards them. Skeleton (cordis plugin in the dsh profile):

```ts
// forward session/turn lifecycle events to the Clumsies daemon
import { Context } from 'cordis'
export const name = 'clumsies-hook'
export function apply(ctx: Context) {
  const forward = (payload: object) => {
    try { execFileSync('clumsiesd', ['_agent', 'issue-run-event', '--host', 'dsh'], { input: JSON.stringify(payload), stdio: 'pipe' }) } catch { /* fail-open */ }
  }
  // ctx.on('session/…', …) — session start/end, turn start/stop, subagent start/stop
}
```

Until the plugin ships, a shell wrapper can drive the same contract from any
event source; `dev/dsh/issue-run-event.sh` is a reference implementation.
The invariant to preserve: **one `turn_id` per user prompt, reused for the
matching `Stop`**, and **no event ever blocks the session**.

## Daemon-side changes (landed)

- `AgentRunHost::Dsh` + `HookHost::Dsh` (`--host dsh`) accepted by
  `clumsiesd _agent issue-run-event`.
- `agent_runs.host` CHECK constraint extended with `'dsh'` via schema
  migration 35 → 36 (table rebuild, idempotent).
- `StopFailure` supported for dsh (root run ends with outcome `failed`).
