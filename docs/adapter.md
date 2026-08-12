# Adapter

Adapter is the daemon-owned integration layer that makes the Clumsies Agent
runtime usable inside Codex, Claude Code, and opencode. It installs each host's
MCP registration, lifecycle bridge, and thin skills without creating a second
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
clumsiesd _agent issue-run-event --host codex|claude-code|opencode
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

Adapter is installed and removed from native Project Management. The resident
daemon requires the repository's canonical Project binding first, serializes
local setup, and persists one revisioned adapter record per Server authority,
workspace root, and host.

| Host | MCP registration | Lifecycle integration | Thin skills |
| --- | --- | --- | --- |
| Codex | `.codex/config.toml` → `mcp_servers.clumsies` | `.codex/hooks.json`, `hooks/resolve-binary.sh`, `hooks/issue-run-event.sh` | `.agents/skills/activate`, `.agents/skills/ntmd` |
| Claude Code | `.mcp.json` → `mcpServers.clumsies` | `.claude/settings.json`, `hooks/resolve-binary.sh`, `hooks/issue-run-event.sh` | `.claude/skills/activate`, `.claude/skills/ntmd` |
| opencode | `opencode.json` → `mcp.clumsies` | `.opencode/plugins/clumsies.ts` | MCP tools are used directly |

Codex and Claude Code MCP entries execute the pinned binary with arguments
`mcp`, `serve`. The opencode local MCP entry executes the equivalent command
array. The opencode plugin embeds the same pinned path for lifecycle events.

## Lifecycle bridge

Codex and Claude Code register one managed `issue-run-event.sh` for the common
event set. Claude Code additionally registers `StopFailure`. opencode maps the
events its plugin API actually exposes.

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
current `run_id`, revision, binding status, and semantic Kanban instructions.
Hooks observe and remind; only an explicit `kanban` tool call changes an Issue.
For Codex and Claude Code, the first root Stop is stored as a non-terminal
decision probe and asks the Agent to judge whether `request_closure` is
appropriate. A follow-up Stop ends the run. Stop itself never advances an
Issue.

See [AgentRun lifecycle](/guides/agent-run-injection) for the event mapping and
decision semantics.

## Safe install, update, and remove

Adapter merges shared host configuration while treating generated scripts,
plugins, and thin skills as exclusive managed files. Its manifest records the
installed hash of every managed file.

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
- Archived `repo`-scope generations are reported as unsupported. For a
  workspace install, remove its old Clumsies MCP/Hook entries and reinstall in
  Project settings. For a user-wide install, remove the global entries and
  enable the integration separately for each repository; the App deliberately
  has no global-install ownership mode.
- Reinstalling from the App is the explicit handoff: the native installer
  refuses foreign or drifted entries instead of silently adopting them.
- Remove deletes only exact managed entries and files; drift becomes a conflict
  instead of an overwrite.
- Filesystem changes are rolled back if the adapter record cannot be committed.

This keeps unrelated host configuration intact and prevents an old worktree or
helper copy from silently taking over the Agent runtime.

## Implementation map

| Concern | Active path |
| --- | --- |
| Native installer, merge rules, and legacy discovery | `crates/daemon/src/agent_adapter.rs` |
| MCP and Hook proxy modes | `crates/daemon/src/main.rs` |
| Typed MCP contract | `crates/daemon/src/agent_runtime/mcp_contract.rs` |
| Hook normalization | `crates/daemon/src/agent_runtime/hook.rs` |
| Codex and Claude Code Hook templates | `assets/adapters/*/runtime/hooks/issue-run-event.sh.tpl` |
| opencode lifecycle plugin | `assets/adapters/opencode/runtime/plugin.ts` |

The retired Zig adapter implementation is historical source under
`archive/zig-cli/`; it is not executed as an installation or compatibility
path. The native daemon contains only a bounded, read-only manifest discovery
pass; it never runs code from the archive or treats archived manifests as an
ownership database.
