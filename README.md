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

clumsies keeps that external memory in managed organization and project scopes. Agents activate
ranked task-relevant fragments, load complete known resources only when needed,
and store explicit draft refinements through the same system.

## Key features

- **Managed agent memory.** Store rules, workflows, and project context outside
  any single agent runtime, then keep local project state in sync.
- **Cue-driven activation.** The MCP surface is centered on `activate`, `load`,
  and `store`; hybrid retrieval returns useful fragments directly instead of
  loading every complete resource up front.
- **Organization and project scope.** Shared memory can live at the
  organization level, while projects keep their own project-specific context
  and rules.
- **Personal bundles.** Bundles let each user maintain reusable selections of
  memory resources without turning those selections into organization truth.
- **Agent adapters.** The adapter layer installs the runtime hooks and skills
  needed by supported agents. Codex and Claude Code are supported today.
- **Self-hosted authority.** The Rust Server and PostgreSQL run in your
  infrastructure; Zig remains focused on CLI and MCP client surfaces.

## Quick start

The macOS client currently runs from source and connects to the hosted Clumsies
Server at `https://app.clumsies.ai`:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
bun install
bun run dev:macos
```

The build embeds the Rust daemon binary, atomically replaces
`~/Applications/Clumsies.app`, and launches the native AppKit/SwiftUI
application from that stable path.

Install the development CLI and MCP entrypoint on macOS with:

```bash
bun run install:cli:macos
```

The installer ad-hoc signs a staging binary and atomically replaces
`~/.clumsies/bin/clumsies`, so active MCP processes can finish on the previous
inode while new agent sessions start the new version.

For local Server and Web Admin development, start PostgreSQL, the deterministic
fake OIDC provider, and Server with:

```bash
bun run dev:server
```

The fake provider is for local Server development only; production uses the
organization's OIDC provider. The macOS app talks to the local daemon, which
owns automatic draft synchronization and authenticated Server transport.

For the self-hosted configuration, see the
[deployment guide](https://lilhammerfun.github.io/clumsies/guides/deploy-for-an-org/).
The Zig CLI and MCP server can still be built separately:

```bash
zig build -Doptimize=ReleaseFast
```

## License

MIT
