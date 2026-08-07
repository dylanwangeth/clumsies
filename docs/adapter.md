# Adapter

## What Adapter is

Adapter is the host integration layer. It is the system layer that makes clumsies actually run inside a concrete coding agent host such as Codex or Claude Code.

It is not Server. It is not MCP. It is not just a bundle of convenience scripts. It is the layer that installs and manages the host-side runtime surfaces required for the protocol to work reliably.

## Why Adapter is a first-class layer

The specs make a strong point here: MCP alone is not enough.

Real agent hosts need additional runtime surfaces such as config entries, hook registration, shell glue, skills, and optional plugin or marketplace assets.

If clumsies leaves that work to hand-written README instructions, install and uninstall quality immediately degrades. Adapter exists so `clumsies adapt` can own that integration path as a product surface.

## The product rule

The intended user-facing rule is simple: users install a clumsies adapter. They do not manually assemble a host-specific pile of config fragments.

That matters because different hosts expose very different native surfaces. A plugin-centric model may fit one host well and fit another poorly. Adapter gives clumsies one stable entry point across those differences without pretending every host has the same native packaging story.

## Adapter versus MCP

These two layers are adjacent but different:

| Layer | Job |
| --- | --- |
| MCP | define the agent-facing activate, load, store, and issue protocol |
| Adapter | make the host actually launch and reinforce that protocol |

MCP tells you what the runtime contract is. Adapter tells you how a specific host gets wired up so that contract becomes usable.

## Codex as the reference case

The Codex adapter specs describe the runtime path as centered on repo-level or user-level `.codex/` surfaces rather than on a single monolithic plugin.

The important runtime pieces include `.codex/config.toml`, `.codex/hooks.json`, `.codex/hooks/*.sh`, and optional repo-local skills.

This is useful for the docs because it clarifies a general design point: adapter assets are real runtime infrastructure, not decorative extras. They are part of the path that makes the protocol actually happen inside a host.

In the current implementation, the Codex package renders at least these managed resources:

| Resource ID | Path shape | Ownership | Purpose |
| --- | --- | --- | --- |
| `codex.config` | `config.toml` | shared | configure Codex runtime behavior for clumsies |
| `codex.hooks.registry` | `hooks.json` | shared | register the currently managed host hooks |
| `codex.hooks.resolve_binary` | `hooks/resolve-binary.sh` | exclusive | locate the active `clumsies` binary |
| `codex.hooks.issue_run_event` | `hooks/issue-run-event.sh` | exclusive | normalize root and subagent lifecycle events for the private daemon bridge |
| `codex.skills.*` | `skills/...` | exclusive | install built-in and imported workflow skills |

Scope changes the target root rather than the package identity:

| Scope | Target root |
| --- | --- |
| `workspace` | `<repo>/.codex` |
| `user` | `~/.codex` |

That is why the install key includes both scope and target root. A workspace-scoped Codex install and a user-scoped Codex install are not the same managed object.

## Claude Code as the second implemented case

Claude Code follows the same top-level product rule but uses a different host surface layout.

In the current implementation, the adapter manages at least:

| Resource ID | Path shape | Ownership | Purpose |
| --- | --- | --- | --- |
| `claude-code.settings` | `.claude/settings.json` | shared | register hook commands |
| `claude-code.mcp` | `.mcp.json` or user-scoped MCP file | shared | register the clumsies MCP server |
| `claude-code.hooks.resolve_binary` | `.claude/hooks/resolve-binary.sh` | exclusive | locate the active `clumsies` binary |
| `claude-code.hooks.session_start` | `.claude/hooks/session-start.sh` | exclusive | run bootstrap at session start |
| `claude-code.hooks.issue_run_event` | `.claude/hooks/issue-run-event.sh` | exclusive | normalize root, subagent, session-end, and failure lifecycle events for the private daemon bridge |
| `claude-code.skills.*` | `.claude/skills/...` | exclusive | install built-in and imported workflow skills |

The point is not just that Codex and Claude Code use different file names. The point is that Adapter absorbs those host differences behind one command surface.

## Issue lifecycle decision hooks

Both adapters register the same core AgentRun lifecycle events:

| Host event | Normalized observation |
| --- | --- |
| `UserPromptSubmit` | start or upsert a root AgentRun and prompt the Agent to decide whether to call `issue.start` |
| `Stop` | prompt the root Agent to decide whether to call `issue.request_closure`, then end the AgentRun without an inferred outcome |
| `SubagentStart` | start or upsert a child AgentRun and retain its parent host key |
| `SubagentStop` | end the child AgentRun without inferring Issue state or an outcome |
| `SessionEnd` | end remaining runs for the host session with an `unknown` outcome |

Claude Code additionally registers `StopFailure`, which ends the root run with
`failed`. Its existing `SessionStart` hook remains a separate workflow-skill
bootstrap surface and does not create an AgentRun. Codex does not register
`StopFailure`.

Claude Code root lifecycle correlation uses the common `prompt_id` field added
in Claude Code 2.1.196. Earlier payloads are ignored fail-open; falling back to
the session ID would incorrectly merge every turn in a session.

All lifecycle events use the same private path:

```text
Codex or Claude Code hook JSON
  -> managed issue-run-event.sh
  -> clumsies _agent issue-run-event --host <host>
  -> daemon record_agent_run_event
```

The hook command is fail-open. It resolves the repository binding, keeps only
bounded host IDs, run keys, parentage, normalized outcomes, and a short display
label, then discards the raw host payload. A successful root or subagent start
returns the current `run_id`, revision, and semantic Issue instruction as
bounded host-native context. Prompt text is not matched to an Issue.
Transcripts, tool payloads, assistant messages, and raw hook JSON are not sent
to daemon.

Claude Code's first root Stop returns a loop-safe `decision=block` reminder
when `stop_hook_active=false`; it is not yet an ended run. The follow-up Stop is
recorded and not blocked. Codex receives Stop additional context on a fail-open
basis.

Hooks observe execution. They do not close or reopen Issues. The agent-facing
MCP `issue` tool provides explicit `list`, `start`, and `request_closure`
operations. Done continues to come only from the Effective Memory path.

## Equivalent installation paths

The Zig `clumsies adapt` package and native Project Management through the Rust
daemon both install the lifecycle bridge. They use the same core event set and
managed script name while preserving the host's unrelated hook handlers.

For repository-scoped native installation, Codex uses
`.codex/hooks.json` and `.codex/hooks/issue-run-event.sh`; Claude Code uses
`.claude/settings.json` and `.claude/hooks/issue-run-event.sh`. Shared JSON
registries are merged, while hook scripts are exclusive managed files whose
installed hashes are checked before update or removal.

During upgrade, both installers remove legacy Clumsies
`user-prompt-submit.sh` registry handlers and stale lifecycle-handler paths only
when previous managed content, a manifest, or a known managed-content hash
proves ownership. Unrelated and unowned same-name commands are preserved. A
legacy script file without such ownership proof may remain inert on disk. The
native installer replaces or removes only the exact managed hook group; a
user-added matcher, sibling handler, or duplicate is reported as drift and is
left unchanged.

## Skills are workflow proxies

Clumsies skills should stay thin. A skill installed into Codex, Claude Code, or another host is only a host-native entry point that loads a Clumsies workflow through MCP and then follows it.

That indirection is the design advantage. The workflow remains a Hub or Project resource, so the team can update the real process through the normal review flow without asking every user to hand-edit host skill files. The adapter only needs to keep the proxy stable.

Workflow proxies load by the exact materialized path, such as `workflow/GEN_COMMIT_MSG.md`, rather than requiring the generated skill author to know a Server ID. The proxy calls `load` and may pass a remembered hash when it has one.

## Workflow skill auto-import

Workflow-backed skills are imported when the adapter is installed or updated. For workspace-scoped installs, the adapter scans the local workspace cache manifest for files under `workflow/*.md`, turns each workflow filename into a host skill name, and writes a thin skill proxy into the host's skill directory.

For example, `workflow/STUDY.md` becomes a `study` skill. The generated skill does not embed the workflow body. It calls `load` with the exact `workflow/STUDY.md` path and then tells the agent to follow the loaded workflow. The same rule applies to other workflow files, such as `workflow/ERROR_PRONE.md` becoming `error-prone`.

This import path runs during `clumsies adapt` or `clumsies adapt --update`. Codex has no SessionStart memory bootstrap; MCP initialization carries the protocol instructions.

The import source is the synchronized local cache, not the review draft list. A newly created workflow draft may be visible through MCP tools, but it will not necessarily produce a host skill until the workflow is accepted into the cache and the adapter is updated.

## Install, update, remove

Adapter is also responsible for lifecycle discipline. It needs to detect available host capabilities, plan what should be installed, write only the managed resources it owns, update those resources later, and remove them cleanly.

That is what turns host integration into a trustworthy product feature instead of a one-way setup script.

## Current support and future targets

The current implementation ships two built-in adapter packages:

| Adapter ID | Display name | Status |
| --- | --- | --- |
| `codex` | `Codex` | supported now |
| `claude-code` | `Claude Code` | supported now |

Future targets will likely include more coding-agent CLIs and agentic editors. When those land, the docs should use the official product names. Examples of current external brand names include:

- `Qwen Code`
- `Kimi Code CLI`
- `Cursor`
- `Windsurf`
- `GitHub Copilot coding agent`

Those are examples of host surfaces the project may care about. They are not current built-in adapters.

## The technical design in the current implementation

The current adapter system already has a concrete internal model. It is not just "run some setup scripts."

### Package layer

Each built-in adapter package defines:

- a stable package ID
- a display name
- scope descriptions
- how to resolve the target root
- how to render runtime assets
- how to re-render managed shared resources during update or remove

That is why the built-in package definitions for Codex and Claude Code are the real authority for which resources exist.

### Plan layer

The planner turns a package plus scope into an explicit install plan. Each plan contains:

- `agent_name`
- `mode`
- `install_id`
- `scope`
- `target_root`
- `revision`
- `steps`

Each step records:

- `resource_id`
- `resource_kind`
- `relative_path`
- optional `absolute_path`
- `ownership`
- `action`
- `label`
- `content`
- optional `managed_content`
- `file_mode`

This matters because install is not supposed to be implicit. The planner decides whether each resource is a create, update, keep, or conflict before the apply path starts mutating host files.

### Resource kinds and merge behavior

The current planner already distinguishes several resource kinds:

| Resource kind | Typical use | Behavior |
| --- | --- | --- |
| `plain_file` | hook scripts, skills | exclusive file write |
| `toml_fragment` | Codex config | shared-file TOML merge logic |
| `json_hooks_registry` | hooks registration | shared-file JSON merge logic |
| `json_mcp_registry` | MCP registry | shared-file JSON merge logic |

That split is what lets Adapter be reversible. Shared files need merge-aware behavior. Exclusive files can be written and later removed as managed assets.

### Install state

Adapter install state lives under:

```text
~/.clumsies/adapters/installs/{install_id}/
```

The current implementation persists at least:

| File | Role |
| --- | --- |
| `manifest.json` | active managed install state |
| `wal.jsonl` | append-only install, update, and remove history |

The install manifest carries:

- `install_id`
- `adapter_id`
- `target_agent`
- `scope`
- `target_root`
- `status`
- `active_revision`
- `managed_resources`

This is the reason remove can be conservative. Adapter does not have to guess what it wrote last time.

### Conflict handling

The planner can return a conflict instead of a plan. In the current implementation, conflicts are raised when:

- an active install already exists and the user did not ask for update
- no active install exists for an update request
- a shared file cannot be merged safely
- an existing unmanaged file already occupies a managed path with different content

That is a real product boundary. Adapter is designed to stop on ambiguous host state rather than silently overwrite it.
