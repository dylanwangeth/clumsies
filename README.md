# clumsies

[![CI](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml)
[![Tests](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/github/license/lilhammerfun/clumsies?label=License)](https://github.com/lilhammerfun/clumsies/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/lilhammerfun/clumsies?label=Release)](https://github.com/lilhammerfun/clumsies/releases)
[![Zig](https://img.shields.io/badge/Zig-0.16%2B-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)

Building collaborative agent memory infrastructure for distributing rules,
workflows, and project context to coding agents.

> [!WARNING]
> Work in progress. This is still a very early system. Expect rough edges, missing flows, broken corners, and backward-incompatible changes.

## The problem

AI coding agents are changing the control plane of software development.

Organizations used to manage only code. Now they also need to manage the rules, constraints, and project context that shape how agents write code.

But an agent's memory lives inside its own runtime. It is not an
organizational asset, and it is hard for teams to share, review, or evolve in
one place. When context pressure hits, useful project rules and background can
still get silently dropped.

clumsies keeps that external memory in a managed workspace. Agents activate
candidate memory for the current task, retrieve only the relevant items, and
store draft refinements through the same system.

## Key features

- **Managed agent memory.** Store rules, workflows, and project context outside
  any single agent runtime, then keep local workspaces in sync.
- **Cue-driven activation.** The MCP surface is centered on `activate`,
  `retrieve`, and `store`, so agents can select task-relevant memory before
  reasoning instead of loading everything up front.
- **Organization and project scope.** Shared memory can live at the
  organization level, while workspaces keep their own project-specific context
  and rules.
- **Bundle-based rollout.** Bundles let teams publish a curated set of shared
  memory and initialize workspaces from that set.
- **Agent adapters.** The adapter layer installs the runtime hooks and skills
  needed by supported agents. Codex and Claude Code are supported today.
- **Self-hosted, zero vendor lock-in.** Runs entirely in your infrastructure
  with PostgreSQL and Zig.

## Quick start

This gets a local clumsies install running for one project. For the product
model and system shape, see the [overview](https://lilhammerfun.github.io/clumsies/overview/)
and [architecture](https://lilhammerfun.github.io/clumsies/architecture/).

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

Start local PostgreSQL:

```bash
docker compose up -d
```

Start the Hub. See the [deployment guide](https://lilhammerfun.github.io/clumsies/guides/deploy-for-an-org/)
for organization bootstrap and self-hosted deployment notes.

```bash
clumsies hub
```

Sign in:

```bash
clumsies login --hub-url http://127.0.0.1:8400 --username admin
```

Set up the current project for your agent:

```bash
clumsies adapt
```

`adapt` installs the selected agent integration. If the current directory is
not bound to a workspace, the workspace scope can create and bind one for this
project before installing.

Optionally launch the current terminal UI:

```bash
clumsies
```

The TUI is available for inspecting workspace state and managing current Hub
objects, but the core runtime path is the Hub, CLI, adapter, and MCP memory
loop.

`clumsies init` and `clumsies sync` still exist for explicit setup and
automation, but they are no longer required for the normal quick start.

Non-interactive adapter installs are still available:

```bash
clumsies adapt --agent codex --scope workspace --yes
```

For exact command flags, use the
[CLI reference](https://lilhammerfun.github.io/clumsies/guides/cli-commands/).

Development from source requires [Zig 0.16+](https://ziglang.org/download/):

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
cp .env.example .env
zig build -Doptimize=ReleaseFast
export PATH="$PWD/zig-out/bin:$PATH"
```

## License

MIT
