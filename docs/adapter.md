# Adapter

## What Adapter is

Adapter is the host integration layer. It is the system layer that makes clumsies actually run inside a concrete coding agent host such as Codex or Claude Code.

It is not Hub. It is not MCP. It is not just a bundle of convenience scripts. It is the layer that installs and manages the host-side runtime surfaces required for the protocol to work reliably.

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
| MCP | define the agent-facing search, load, and refer protocol |
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
| `codex.hooks.registry` | `hooks.json` | shared | register SessionStart, UserPromptSubmit, and Stop hooks |
| `codex.hooks.resolve_binary` | `hooks/resolve-binary.sh` | exclusive | locate the active `clumsies` binary |
| `codex.hooks.session_start` | `hooks/session-start.sh` | exclusive | run bootstrap at session start |
| `codex.hooks.user_prompt_submit` | `hooks/user-prompt-submit.sh` | exclusive | append session input telemetry |
| `codex.hooks.stop_check` | `hooks/stop-refer-check.sh` | exclusive | enforce refer reminder at turn end |
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
| `claude-code.hooks.user_prompt_submit` | `.claude/hooks/user-prompt-submit.sh` | exclusive | append session input telemetry |
| `claude-code.hooks.stop_check` | `.claude/hooks/stop-refer-check.sh` | exclusive | enforce refer reminder at turn end |
| `claude-code.skills.*` | `.claude/skills/...` | exclusive | install built-in and imported workflow skills |

The point is not just that Codex and Claude Code use different file names. The point is that Adapter absorbs those host differences behind one command surface.

## Skills are workflow proxies

Clumsies skills should stay thin. A skill installed into Codex, Claude Code, or another host is only a host-native entry point that loads a Clumsies workflow through MCP and then follows it.

That indirection is the design advantage. The workflow content remains an Artifact object, so the team can update the real process through the normal review flow without asking every user to reinstall or hand-edit host skill files. The adapter only needs to keep the proxy stable.

Workflow proxies should load by workflow name or path alias, such as `workflow:GEN_COMMIT_MSG`, rather than requiring the generated skill author to know a Hub `p-*` id. The proxy should pass a remembered hash to `memload` when it has one, and use an empty string only when the hash is unknown.

## Workflow skill auto-import

Workflow-backed skills are imported when the adapter is installed or updated. For workspace-scoped installs, the adapter scans the local workspace cache manifest for files under `workflow/*.md`, turns each workflow filename into a host skill name, and writes a thin skill proxy into the host's skill directory.

For example, `workflow/STUDY.md` becomes a `study` skill. The generated skill does not embed the workflow body. It calls `memload` with `workflow:STUDY` and then tells the agent to follow the loaded workflow. The same rule applies to other workflow files, such as `workflow/ERROR_PRONE.md` becoming `error-prone`.

This import path runs during `clumsies adapt` or `clumsies adapt --update`. It is not part of the Codex `SessionStart` hook. The Codex hook only bootstraps the MCP protocol by injecting the `memsetup` instruction for the current host session.

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
