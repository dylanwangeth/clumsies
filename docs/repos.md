# Repo Map

## Overview

This workspace may look like a monorepo at first glance, but it behaves more like a multi-repo workbench evolving side by side.

## clumsies

`clumsies/` is the primary repository at the center of the current system. It carries several responsibilities at once:

- CLI entrypoints
- Hub Server modules
- MCP interfaces
- sync logic
- seed and data-pump utilities

Its structure already reflects those boundaries:

| Directory | Role |
| --- | --- |
| `src/commands/` | CLI subcommands |
| `src/hub/` | Hub Server business modules |
| `src/mcp/` | MCP protocol and server implementation |
| `src/lib/` | shared internal logic |
| `src/protocol/` | protocol objects and ID / hash types |
| `src/seed/` | seed and data-pump tooling |

## clumsies-tui

`clumsies-tui/` is the terminal interface and interaction lab. Its job is not to squeeze a web page into a terminal. Its job is to test which high-density workflows are genuinely better in a TUI.

It is effectively exploring questions like:

- how Library, Workspace, Proposal, and Trace should be operated from a dense terminal dashboard
- whether the terminal can carry higher information density and faster interaction loops than the web for this product

## clumsies-registry

`clumsies-registry/` represents an earlier stage of asset management. It still matters because bundle content, distribution ideas, and historical prompt assets remain tied to that phase.

From the target architecture perspective, it is more of a migration reference than the final center of gravity.

## docs

Within this worktree, `docs/` is the root of the documentation site. It does not carry runtime code. It carries the public explanation layer for the project and its companion repositories.
