# Adapter

Adapter is the daemon-owned integration layer that makes the Clumsies Agent
runtime usable inside Codex, Claude Code, opencode, dsh, and Antigravity. For
Codex it automatically installs and reconciles one user-level Clumsies plugin; the other
hosts retain their direct-file integrations. Both delivery forms provide the
MCP registration and non-blocking lifecycle bridge without creating a second
memory or runtime implementation.

## Runtime boundary

The macOS App bundle contains one signed Rust executable:

```text
Clumsies.app/Contents/Resources/clumsiesd
```

launchd runs that executable as the resident daemon. Adapter pins the same
absolute App-bundled path into every managed MCP and Hook entry and starts it in
one of two short-lived proxy modes:

```text
clumsiesd mcp serve
clumsiesd mcp serve --host codex --delivery host-plugin
clumsiesd _agent issue-run-event --host codex|claude-code|opencode|dsh|antigravity
clumsiesd _agent issue-run-event --host codex --delivery host-plugin
```

The installer requires an executable whose canonical path ends in
`Contents/Resources/clumsiesd` and verifies its macOS code signature. It records
the path and SHA-256 in the adapter manifest. There is no checkout build,
`PATH`, environment-variable, or copied-helper fallback.

Each proxy verifies that its Agent runtime protocol revision and build identity
match the resident daemon before forwarding traffic over XPC. Replacing the App
therefore updates every newly started proxy, while a resident from an older
release is detected and must be restarted.

## Managed host surfaces

Codex is a global host integration managed from **Settings → Agent**. It is
installed and enabled by default when the Codex App is available, and it never
writes files into a repository. The other hosts are installed and removed from
**Settings → Agent**; their direct-file integrations retain one revisioned
adapter record per Server authority, workspace root, and host.

| Host | MCP registration | Lifecycle integration |
| --- | --- | --- |
| Codex | `clumsies@clumsies-local` plugin → pinned MCP server | plugin Hooks; no project files |
| Claude Code | `.mcp.json` → `mcpServers.clumsies` | `.claude/settings.json`, `hooks/resolve-binary.sh`, `hooks/issue-run-event.sh` |
| opencode | `opencode.json` → `mcp.clumsies` | `.opencode/plugins/clumsies.ts` |
| dsh | profile-managed MCP registration | `.dsh/clumsies.json` routes the separately installed client bridge |
| Antigravity | `.mcp.json` → `mcpServers.clumsies` | `.agents/hooks.json`, `.agents/hooks/resolve-binary.sh`, `.agents/hooks/issue-run-event.sh` |

Every host consumes the MCP tools directly. The Codex plugin carries one thin
`clumsies` bootstrap Skill that tells the harness when to activate Memory and
how to use Kanban. Project-maintained skills such as `coding` are ordinary
resources in Memory Space: the bootstrap loads them through `memory.load` when
relevant and never copies or installs them into a host skill directory.

The unrelated host-native `activate` / `ntmd` skills installed by older Codex
and Claude Code releases are retired. Historical Codex Adapter rows retain
enough ownership metadata to remove exact legacy `.codex/config.toml`,
`.codex/hooks.json`, and managed Hook fragments when that repository is
removed. Direct-file update paths likewise delete previously managed retired
skill files without touching user-owned content.

The Codex plugin executes the pinned binary as `mcp serve --host codex
--delivery host-plugin`. The marker identifies the global plugin delivery; it
does not select or authorize a Project. At startup and again before every
`tools/call`, daemon resolves the repository's canonical Project binding and
requires it to remain the same Project. A missing or changed binding therefore
fails closed without consulting a Codex project Adapter row. Claude Code and
the remaining direct-file hosts retain their existing commands and Adapter
delivery checks. The opencode plugin embeds the same pinned path for lifecycle
events.

## Lifecycle bridge

The Codex plugin and Claude Code direct-file adapter each register an
`issue-run-event.sh` for prompt, subagent, and session lifecycle. Codex forwards
the same `host-plugin` delivery marker used by MCP; the Hook resolves its
repository binding rather than a project-level Codex switch.
Codex treats plugin Hooks as non-managed code and skips a new or changed Hook
until the user reviews and trusts its current hash in `/hooks`. Adapter never
bypasses that trust boundary. Plugin changes do not hot-load into an already
open Codex task: restart Codex after install or update, then start a new task.
MCP and Memory are then available; AgentRun injection and run-bound Kanban
actions begin after Hook trust.
Claude Code additionally registers `StopFailure`. Antigravity registers
`PreInvocation`. None of these adapters registers a normal root `Stop`. The
opencode plugin forwards user messages, failed assistant completions, and
session deletion, but does not turn a normal assistant completion into `Stop`.
The dsh client bridge follows the same non-blocking boundary.

```text
host event
  -> managed Hook or plugin
  -> clumsiesd _agent issue-run-event --host <host>
  -> typed XPC record_agent_run_event
  -> resident daemon AgentRun
```

The proxy accepts at most 1 MiB, validates the host event, and reduces it to a
bounded allowlist of lifecycle identifiers. Raw prompts, transcripts, assistant
messages, tool payloads, and failure bodies never enter the daemon request.
Lifecycle observation is fail-open: an unavailable runtime or daemon must not
prevent the Agent host from continuing.

Successful root and subagent starts return bounded context containing the
current `run_id`, revision, binding status, and the information needed for
explicit Kanban work. Lifecycle integration never creates a stop-blocking
closure prompt. Acceptance-criteria judgment and `kanban.request_closure`
belong to an opt-in skill or a manually maintained Agent workflow.

The private bridge continues to accept a legacy or manually forwarded root
`Stop` so older installations fail open while they are cleaned up. Such an
event is only a non-blocking AgentRun observation: it cannot call `kanban`,
block the host, or advance an Issue. `StopFailure`, `SubagentStop`, and
`SessionEnd` remain available because they do not create a root completion
decision point.

See [AgentRun lifecycle](/guides/agent-run-injection) for the event mapping and
authority boundary.

## Safe install, update, and remove

Direct-file adapters merge shared host configuration while treating generated
scripts and plugins as exclusive managed files. Their manifests record the
installed hash of every managed file, and update retires managed files that the
current plan no longer includes.

Codex uses a distinct `host_plugin` delivery. Before authentication, the App
inspects the Codex host, App-owned local marketplace, installed/enabled state,
and expected plugin version. Missing or stale managed state is reconciled
through the signed Codex CLI. Inspection is read-only; automatic reconciliation
and the explicit **Repair** action in **Settings → Agent** materialize the
marketplace and install or update the plugin. Neither operation writes a
`project_agent_adapters` row or repository file.

Installed and enabled describes plugin delivery, not Hook trust or AgentRun
readiness. Settings therefore keeps the `/hooks` reminder and requires a Codex
restart and a new task after plugin changes; an existing task is not a valid
convergence probe for the new plugin snapshot and may still own a retired
legacy proxy until it exits. Historical Codex Adapter rows remain readable only
so repository removal and legacy-file cleanup can retire them safely; current
installation and runtime routing ignore them.

The App refuses to bootstrap `clumsiesd` or persist an Agent runtime path while
macOS is running it from an App Translocation mount. Move the released App to
`/Applications` or `~/Applications` and reopen it first; this prevents a
temporary quarantine UUID from entering LaunchAgent and host configuration.

- Install refuses to replace an unrelated MCP entry or unmanaged file.
- Update uses the adapter record revision as an optimistic concurrency guard.
- A prior managed runtime path can be migrated to the current App-bundled path.
- Installations created directly by the archived Zig CLI are discovered
  read-only and left unchanged. Missing workspaces remain pending; reachable
  installs report an actionable review-and-reinstall warning. Inspection is
  best-effort, has a short App-side deadline, and never blocks reconciliation
  of daemon-owned integrations, including while signed out or offline. Their external
  manifests are not accepted as native ownership proof.
- Archived `repo`-scope generations are reported as unsupported. Remove their
  old Clumsies MCP/Hook entries; the App-owned global Codex Plugin replaces
  repository-local Codex integration. Other hosts remain repository-scoped
  integrations managed from **Settings → Agent**.
- Reinstalling from the App is the explicit handoff: the native installer
  refuses foreign or drifted entries instead of silently adopting them.
- Remove deletes only exact managed entries and files; drift becomes a conflict
  instead of an overwrite.
- Filesystem and record changes are journaled so an interrupted install or
  migration is recovered deterministically on the next reconciliation pass.

This keeps unrelated host configuration intact and prevents an old worktree or
helper copy from silently taking over the Agent runtime.

## Implementation map

| Concern | Active path |
| --- | --- |
| Native installer, merge rules, and legacy discovery | `crates/daemon/src/agent_adapter.rs` |
| Codex plugin materialization and CLI reconciliation | `crates/daemon/src/agent_adapter/codex_plugin.rs` |
| Codex plugin source bundle | `packages/clumsies/` |
| MCP and Hook proxy modes | `crates/daemon/src/main.rs` |
| Typed MCP contract | `crates/daemon/src/agent_runtime/mcp_contract.rs` |
| Hook normalization | `crates/daemon/src/agent_runtime/hook.rs` |
| Codex plugin Hook template | `packages/clumsies/scripts/issue-run-event.sh.tpl` |
| Direct-file Hook templates | `assets/adapters/*/runtime/hooks/issue-run-event.sh.tpl` |
| opencode lifecycle plugin | `assets/adapters/opencode/runtime/plugin.ts` |

The retired Zig adapter implementation is historical source under
`archive/zig-cli/`; it is not executed as an installation or compatibility
path. The native daemon contains only a bounded, read-only manifest discovery
pass; it never runs code from the archive or treats archived manifests as an
ownership database.
