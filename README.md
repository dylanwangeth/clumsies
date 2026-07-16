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
- **Self-hosted authority.** The Rust Server and PostgreSQL run in your
  infrastructure; Zig remains focused on CLI and MCP client surfaces.

## Quick start

The current product is run from source while the Desktop distribution is being
prepared. The local stack includes Server, PostgreSQL, and a deterministic fake
OIDC provider:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
bun install
bun run dev:server
```

This keeps the Rust Server in the foreground and starts PostgreSQL and the fake
provider in Docker. In another terminal, launch Desktop. Its Tauri build
prepares the Rust daemon binary automatically:

```bash
bun run dev:desktop
```

Desktop opens the fake provider in the system browser and signs in as the local
bootstrap owner. The renderer talks to the local daemon; daemon owns automatic
draft synchronization and authenticated Server transport. The fake provider is
for local development only; production uses the organization's OIDC provider.

For the self-hosted configuration, see the
[deployment guide](https://lilhammerfun.github.io/clumsies/guides/deploy-for-an-org/).
The Zig CLI and MCP server can still be built separately:

```bash
zig build -Doptimize=ReleaseFast
```

## License

MIT
