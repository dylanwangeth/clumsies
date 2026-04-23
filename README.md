# clumsies

[![CI](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml)
[![Tests](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/github/license/lilhammerfun/clumsies?label=License)](https://github.com/lilhammerfun/clumsies/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/lilhammerfun/clumsies?include_prereleases&label=Release)](https://github.com/lilhammerfun/clumsies/releases)
[![Zig](https://img.shields.io/badge/Zig-0.15%2B-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)

Building the persistent, observable, and collaborative context infrastructure that coexists with agents' self-managed memory.

> [!WARNING]
> Work in progress. This is still a very early system. Expect rough edges, missing flows, broken corners, and backward-incompatible changes.

## The problem

AI coding agents are changing the control plane of software development.

Organizations used to manage only code. Now they also need to manage the rules, constraints, and project context that shape how agents write code.

But an agent's memory lives inside its own runtime — it is not an organizational asset. When context pressure hits, rules get silently dropped, and no one can tell what actually happened.

You own the rules. The agent loads them on demand. Every interaction is traced at rule level. The human stays in control.

## Key features

- **Persistent context at scale.** Agents load rules on demand instead of stuffing everything into one context window. Large projects with dozens of rule files do not silently lose instructions under context pressure.
- **Organization-owned library.** Update a rule once, sync everywhere. No more copying `.cursorrules` between repos or hoping everyone has the latest version.
- **Built-in observability.** Every agent interaction is recorded as an attestation event — which constraints were loaded, which were applied, and the agent's self-assessment. The event lifecycle (`user_prompt` → `discover`/`load`/`refer` → `agent_report`) gives you data-driven insight into which rules work and which get ignored. Agent adapters enforce turn closure: the stop hook ensures the agent submits a summary before finishing.
- **Agent-agnostic adapters.** An adapter layer sits between your rules and the agent runtime. Claude Code, Codex, Cursor — same rules, same attestations, no vendor lock-in.
- **Self-hosted, zero vendor lock-in.** Runs entirely in your infrastructure with PostgreSQL and Zig.

## TUI preview

Library view:

![TUI library view](assets/screenshots/tui_library.png)

Analysis view:

![TUI analysis view](assets/screenshots/tui_analysis.png)

Watch a short recording:

https://github.com/user-attachments/assets/3ae8473c-dac1-45b5-8a72-6ad21906f235

## Documentation

For the full documentation site content, start here:

- [Overview](docs/overview.md)
- [Architecture](docs/architecture.md)
- [Guides](docs/guides/index.md)
- [Reference](docs/reference/index.md)

## Quick start

Build from source (requires [Zig 0.15+](https://ziglang.org/download/); add `zig-out/bin` to your `PATH` for convenience):

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
export PATH="$PWD/zig-out/bin:$PATH"
```

Start local PostgreSQL:

```bash
docker compose up -d
```

Start the Hub:

```bash
clumsies-hub
```

Log in:

```bash
clumsies login --hub-url http://127.0.0.1:8400 --username admin
```

Bind the current directory to a workspace:

```bash
clumsies init --create my-workspace
```

Sync local cache:

```bash
clumsies sync
```

Install the Codex adapter in workspace scope:

```bash
clumsies adapt --agent codex --scope workspace --yes
```

Launch the TUI:

```bash
clumsies
```

> [!TIP]
> For iterative development, `just dev` spins up the Hub, seeds representative
> data, and launches the TUI in one command — no need to run the steps above
> manually. Requires [just](https://github.com/casey/just).

## License

MIT
