# Agent runtime

This page is for the host runtime side. It is not the member quickstart.

Members use the TUI or `login` to authenticate, then `init`, `sync`, and
adapters. Agent hosts use the MCP server and the adapter layer.

## Where the agent path starts

The current entrypoint is:

```bash
clumsies mcp serve
```

That starts the MCP stdio server for the current workspace.

That sentence sounds small, but it hides an important precondition: `mcp serve` only makes sense after a member has already done the human-side work. The repo must be bound to a workspace, local state must be synced, and the relevant adapter must already have installed the host-facing config or hook files.

So the practical order is:

1. member logs in and binds the repo
2. member runs `sync` and, if needed, `adapt`
3. host starts `clumsies mcp serve`
4. agent runtime talks to the local MCP server

## What the agent actually talks to

In the current implementation, the MCP tool surface is:

- `activate`
- `retrieve`
- `store`

That path activates available memory, retrieves selected rules and context, and
stages memory drafts.

The runtime shape is easier to understand as a sequence:

```text
agent host
  -> MCP stdio server (`clumsies mcp serve`)
  -> local workspace manifest + cache
  -> attestation/{session_id}.jsonl
  -> TUI background upload to Hub
```

That path is why MCP should be described as a local runtime surface rather than as a direct Hub API wrapper. It serves the synchronized local workspace state first, and only later do attestation events move back up to Hub.

One bootstrap detail sits between step 2 and step 3: the agent imports
`META_PROMPT.md` from the cache. That file tells the runtime to activate
relevant memory first, then retrieve intentionally. The host starts an MCP
server and a workspace-scoped bootstrap contract.

## What state the runtime depends on

The host runtime depends on several local files under `~/.clumsies`:

| Path | Why the runtime needs it |
| --- | --- |
| `config.toml` | resolves which workspace is bound to the current repo path |
| `workspaces/{workspace_name}/manifest.json` | gives the current workspace snapshot and revision |
| `workspaces/{workspace_name}/cache/` | stores materialized rules, context, and `META_PROMPT` |
| `workspaces/{workspace_name}/attestation/` | session logs and cursors |
| `adapters/installs/{install_id}/manifest.json` | records what an adapter installation owns |
| `adapters/installs/{install_id}/wal.jsonl` | supports safe update and remove behavior |

If any of those layers are missing or stale, the runtime can still look "installed" from the host side while serving the wrong local state. That is why runtime docs need to name the files, not just the commands.

## Where adapters fit

The adapter is what connects a host runtime such as Codex or Claude Code to this MCP path.

From the member machine, the relevant install commands are still:

```bash
clumsies adapt --agent codex --scope workspace --yes
clumsies adapt --agent claude-code --scope user --yes
```

That is still a user action. What changes after installation is the runtime behavior. The host can now start `clumsies mcp serve` and follow the structured `retrieve` → `activate` → `retrieve` → `store` flow instead of treating rule and context files as ad hoc local memory.

In the current implementation, the built-in adapter packages are:

| Adapter package | Display name | Role |
| --- | --- | --- |
| `codex` | `Codex` | installs `.codex` config, hooks, and related runtime assets |
| `claude-code` | `Claude Code` | installs Claude Code settings, hooks, and related runtime assets |

Those packages are not generic installers. Each one carries host-specific resources and merge behavior, which is why adapter is a real system layer rather than a wrapper around `mcp serve`.

## Keep this boundary clean

This distinction is worth keeping explicit:

- `Member workflow` is for humans doing workspace operations
- `Agent runtime` is for runtime wiring and MCP behavior

Blurring those two paths is exactly how docs drift into vague "just run everything" language.

The clean rule is simple: members operate the workspace, adapters make the host reachable, and MCP serves the synchronized local runtime to the agent.
