# clumsies

[![CI](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml)
[![Tests](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/github/license/lilhammerfun/clumsies?label=License)](https://github.com/lilhammerfun/clumsies/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/lilhammerfun/clumsies?label=Release)](https://github.com/lilhammerfun/clumsies/releases/latest)
[![Zig](https://img.shields.io/badge/Zig-0.15%2B-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)

> **Work in progress.** clumsies is an experimental project. The paradigm is clear; the tooling is still catching up.

## The paradigm

AI agents have memory systems — Claude Code writes to `~/.claude/memory/`, Windsurf stores memories per workspace, Copilot keeps them server-side. The agent decides what to remember, what to surface, and what to compress away when context runs low.

We think users should have a parallel memory layer they fully control. One where you decide what matters, where it lives, and how it gets used — not one managed by the agent on your behalf.

That layer is a directory of markdown files (`.prompts/`) sitting in your project. Inside it, a `META_PROMPT.md` file defines how the agent should interact with the constraints — when to search, when to load, when to declare what it used. The MCP server reads this file on `memory.setup` and bootstraps the entire protocol from it.

The idea itself is simple. The hard part is making it actually work — making agents reliably discover, follow, and report on constraints. That's what clumsies is building tools for.

## What we're building

clumsies is a set of tools layered on top of this paradigm:

**CLI + Registry.** A command-line tool for managing a personal prompt library. Register prompts you've refined through real use, store them in a git-based registry, and import them into any project. Task lifecycle commands (`setup`, `begin`, `complete`, `search`, `load`, `refer`, `validate`, `stats`) mirror the MCP protocol for use by hooks and scripts.

**MCP Server.** A protocol layer that gives agents structured access to your `.prompts/` space. Instead of the agent blindly reading files, it discovers available constraints (`memory.search`), loads what it needs (`memory.load`), and declares which constraints it referenced (`memory.refer`). Every interaction produces a trace log.

**Stats engine.** Aggregates trace data into views: which prompts are hot, which constraints are cold, how coverage changes across versions. Available via CLI (`clumsies stats`) and the MCP `memory.stats` tool.

**Claude Code plugin.** Hooks and skills that solve MCP's biggest weakness — agents forgetting to call tools. A startup hook loads your meta-prompt and creates a task automatically. A stop hook reminds the agent to declare constraint references. Slash commands (`/complete-task`, `/stats`, `/search`) put control in your hands. Workflow files are auto-generated as skills on session start.

## Quick start with Claude Code

Install the CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

Import a starter bundle into your project:

```bash
cd your-project
clumsies get opus-coding --registry https://github.com/lilhammerfun/clumsies-registry.git
```

This creates `.prompts/` with coding rules and workflows. Launch Claude Code with the plugin (local development — marketplace distribution coming once stable):

```bash
claude --plugin-dir /path/to/clumsies/cc-plugin
```

On session start, the plugin loads `META_PROMPT.md`, creates a task, and generates slash commands for your workflows. Give the agent a task — it will discover and follow constraints from `.prompts/`. When you're done, type `/complete-task`.

Check what happened:

```bash
clumsies stats
```

Once you've refined prompts through real use, set up your own registry:

```bash
clumsies config set registry git@github.com:you/prompt-registry.git
clumsies add .prompts/rule/coding/
```

## The `.prompts/` layout

```
workspace/
└── .prompts/
    ├── META_PROMPT.md     # protocol bootstrap — loaded on session start
    ├── rule/              # constraints — coding rules, project context, etc.
    ├── workflow/           # ordered procedures — commit messages, reviews, etc.
    ├── context/           # reference material — research, specs, etc.
    └── ...                # whatever else you need
```

`META_PROMPT.md` is the entry point. The plugin loads it on session start and injects its content into the agent's context. Everything else — rules, workflows, context — is discovered through `memory.search` and loaded on demand.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

<details>
<summary>Manual install</summary>

```bash
curl -LO https://github.com/lilhammerfun/clumsies/releases/latest/download/clumsies-darwin-arm64
curl -LO https://github.com/lilhammerfun/clumsies/releases/latest/download/checksums.txt

shasum -a 256 -c checksums.txt --ignore-missing
chmod +x clumsies-darwin-arm64
mkdir -p ~/.clumsies/bin
mv clumsies-darwin-arm64 ~/.clumsies/bin/clumsies
```

Platforms: `darwin-arm64`, `darwin-x86_64`, `linux-arm64`, `linux-x86_64`, `windows-x86_64`

Windows binaries are available but not yet validated. If you're on Windows and willing to help test, see [#20](https://github.com/lilhammerfun/clumsies/issues/20).
</details>

<details>
<summary>Build from source</summary>

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
```

</details>

## Status

| Component | Status |
|-----------|--------|
| CLI + Registry | Working — prompt management, bundles, import/export, task lifecycle |
| MCP Server | Working — `clumsies mcp serve`, 9 tools |
| Stats engine | Working — workspace/prompt/diff/timebucket scopes |
| Claude Code plugin | Alpha — hooks, skills, auto-skill generation |

The MCP server and stats engine are functional but haven't been battle-tested at scale. Trace data quality depends on agent compliance — which is what the Claude Code plugin is designed to improve.
