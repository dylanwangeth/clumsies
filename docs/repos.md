# Codebase map

## Overview

The current docs branch lives inside a single repository. The important boundary is not repo count. It is which part of the codebase owns which layer of the system.

## Top-level layout

| Path | Role |
| --- | --- |
| `src/hub/` | Hub server modules and REST handlers |
| `src/client/` | CLI, MCP runtime, adapter engine, TUI |
| `src/protocol/` | shared API and protocol types |
| `assets/adapters/` | runtime assets installed into agent hosts |
| `docs/` | VitePress documentation site |

## `src/hub`

This directory is the authority layer. It contains the modules that back the server-side model:

| Module | Responsibility |
| --- | --- |
| `auth.zig` | identity, tokens, roles, workspace access |
| `artifact.zig` | artifact manifest, prompt metadata, bundles |
| `workspace.zig` | workspace CRUD and manifest state |
| `context.zig` | workspace context files and context collaboration endpoints |
| `collab.zig` | PR and review flows |
| `attestation.zig` | trace ingestion and stats |
| `server.zig` | route wiring and HTTP server setup |

## `src/client`

This directory holds several client surfaces that share local storage and protocol logic.

| Area | Responsibility |
| --- | --- |
| `commands/` | CLI subcommands such as login, init, sync, adapt |
| `mcp/` | the MCP runtime exposed to coding agents |
| `adapter/` | adapter engine and host package definitions |
| `tui/` | terminal dashboard views and client-side data flow |
| `prompt.zig` | manifest, cache, draft, and prompt/context lookup logic |

## `src/protocol`

This directory defines shared types and API contracts. It is the seam between client and server. If you want to understand manifest shape, stats payloads, auth responses, or workspace API types, start here.

## `assets/adapters`

These are the host-facing runtime assets that `clumsies adapt` installs. They matter because adapter behavior is not abstract. Real shells, hooks, config templates, and host-specific glue live here.

The built-in adapter subtrees are:

- `assets/adapters/agy/`
- `assets/adapters/codex/`
- `assets/adapters/claude-code/`

## How to read the repository

1. Read `src/protocol/` to understand the shared object model.
2. Read `src/hub/` to see the authority layer.
3. Read `src/client/commands/`, `src/client/mcp/`, and `src/client/adapter/` to see how local runtime surfaces consume that model.
4. Read `src/client/tui/` last, after the data model is already clear.
