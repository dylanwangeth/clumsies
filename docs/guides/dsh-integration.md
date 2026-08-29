# DeepSeek Harness (dsh) Integration

The Clumsies daemon treats the DeepSeek Harness web app as a first-class
Agent host ("dsh"). This guide covers both halves of the integration:

1. **MCP access** — the dsh web profile connects to the Clumsies MCP server,
   which gives the model `mcp__clumsies__activate / load / store / kanban`.
2. **AgentRun lifecycle** — a dsh-side client plugin forwards non-blocking
   session/turn events to the daemon's hook proxy, which issues `dsh`
   AgentRuns and records failure or session boundaries. With a live run the
   model can use `kanban.begin_work`; an opt-in skill or manually maintained
   workflow may explicitly call `kanban.request_closure`.

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

## Agent adapter (global settings)

dsh is a first-class Agent adapter. In the macOS app, **Settings → Agent**
lists **DeepSeek Harness (dsh)** next to Claude Code, opencode, and Antigravity
for every bound repository. Enabling the toggle installs a workspace marker the
dsh side reads:

```json
{
  "server_url": "https://clumsies.example.com",
  "project_id": "prj_…",
  "runtime": "/Applications/Clumsies.app/Contents/Resources/clumsiesd"
}
```

The marker lives at `.dsh/clumsies.json` in the repository and is fully
managed (installed, updated, and removed) by the daemon's adapter journal,
like the other adapters' files. Disabling the toggle removes it.

The marker is per-machine state (the App-bundled clumsiesd path and the
daemon's server URL), so repositories using the dsh adapter should ignore it
in git, like the other repository-scoped Agent files:

```gitignore
.dsh/
```

The dsh hook plugin (`dev/dsh/clumsies-hook.mjs`) resolves the marker by
walking up from the session cwd: the marker's workspace root is forwarded as
the event `cwd` (so the daemon binds the run to the adapter-managed
Project even when `dsh web` was launched from a parent directory) and the
marker's `runtime` pins the clumsiesd binary that forwards events (no
machine-specific path in the plugin). Sessions without a marker fall back to
the session cwd and the environment/default runtime, so manual setups keep
working. `dev/dsh/issue-run-event.sh` does the same lookup for shell-driven
forwarding.

The MCP side remains a one-time profile registration (below): the static
`cwd` pins the spawned `clumsiesd mcp serve` to one workspace, so the
profile patch targets the workspace whose kanban the dsh sessions should see.

## AgentRun lifecycle hook

The daemon accepts hook events from the `dsh` host:

```sh
printf '%s' "$PAYLOAD" | clumsiesd _agent issue-run-event --host dsh
```

`$PAYLOAD` is a JSON object with the shared hook vocabulary:

| Field | Required | Meaning |
|---|---|---|
| `hook_event_name` | yes | New integrations send `UserPromptSubmit`, `StopFailure`, `SubagentStart`, `SubagentStop`, or `SessionEnd`; `Stop` is accepted only for legacy/manual compatibility |
| `session_id` | yes | dsh session id (e.g. `session-…`); deduplicates events |
| `turn_id` | root events | one id per user prompt, reused by a matching `StopFailure` or legacy/manual `Stop` |
| `agent_id` | subagent events | subagent id (`subagent:…`) |
| `agent_type` | subagent events | display label for the subagent run |
| `cwd` | no | workspace path; resolves the project binding when present |
| `error` | `StopFailure` | ignored (never stored) |

Example turn lifecycle:

```json
{"hook_event_name":"UserPromptSubmit","session_id":"session-abc","turn_id":"turn-001","cwd":"/work/repo"}
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
  // ctx.on('session/…', …) — turn start/failure, session end, subagent start/stop
}
```

The shipped plugin (`dev/dsh/clumsies-hook.mjs`) also resolves the
`.dsh/clumsies.json` marker described above; a shell wrapper
(`dev/dsh/issue-run-event.sh`) drives the same contract from any event
source. A normal successful turn does not emit root `Stop`. The invariant to
preserve is **one `turn_id` per user prompt, reused for a failure event**, and
**no event ever blocks the session**. If an older or manually maintained
integration still sends `Stop`, the bridge records telemetry only and returns
no stop-blocking decision.

## Daemon-side changes (landed)

- `AgentRunHost::Dsh` + `HookHost::Dsh` (`--host dsh`) accepted by
  `clumsiesd _agent issue-run-event`.
- `agent_runs.host` CHECK constraint extended with `'dsh'` via schema
  migration 35 → 36 (table rebuild, idempotent).
- `StopFailure` supported for dsh (root run ends with outcome `failed`).
