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

Today, most agents still need an external meta-prompt file (CLAUDE.md, .cursorrules, etc.) to learn about `.prompts/` in the first place. The planned Claude Code plugin eliminates this gap — a startup hook calls `memory.setup` automatically, loading `META_PROMPT.md` and injecting it into context. The meta-prompt lives inside `.prompts/` and syncs with the rest of your constraints.

The idea itself is simple. The hard part is making it actually work — making agents reliably discover, follow, and report on constraints. That's what clumsies is building tools for.

## What we're building

clumsies is a set of tools layered on top of this paradigm:

**CLI + Registry.** A command-line tool for managing a personal prompt library. Register prompts you've refined through real use, store them in a git-based registry, and import them into any project. Your prompt library grows with your practice.

```bash
clumsies add .prompts/rule/coding/     # register refined prompts
clumsies get my-coding-bundle           # import into a new project
clumsies stats                          # see which constraints get used
```

**MCP Server.** A protocol layer that gives agents structured access to your `.prompts/` space. Instead of the agent blindly reading files, it discovers available constraints (`memory.search`), loads what it needs (`memory.load`), and declares which constraints it referenced (`memory.refer`). Every interaction produces a trace log. Over time, you can see which constraints actually get used and which are dead weight.

**Stats engine.** Aggregates trace data into views: which prompts are hot, which constraints are cold, how coverage changes across versions. Available via CLI (`clumsies stats`) and the MCP `memory.stats` tool.

**Claude Code plugin.** (Planned.) Hooks and slash commands that solve MCP's biggest weakness — agents forgetting to call tools. A startup hook loads your meta-prompt automatically. A `/complete-task` command puts task completion in your hands instead of the agent's. A stop hook reminds the agent to declare which constraints it used.

## The `.prompts/` layout

```
workspace/
└── .prompts/
    ├── META_PROMPT.md     # protocol bootstrap — loaded by memory.setup
    ├── rule/              # constraints — coding rules, project context, etc.
    ├── workflow/           # ordered procedures — commit messages, reviews, etc.
    ├── context/           # reference material — research, specs, etc.
    └── ...                # whatever else you need
```

`META_PROMPT.md` is the entry point. It tells the agent what the `.prompts/` system is, how to use the MCP tools, and what the priority model looks like. The MCP server reads it on `memory.setup` and returns its content to the agent. Everything else — rules, workflows, data — is discovered through `memory.search` and loaded on demand.

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

## Quick start

```bash
mkdir demo && cd demo

clumsies get opus-coding --registry https://github.com/lilhammerfun/clumsies-registry.git
```

This creates `.prompts/` with coding rules and a meta-prompt file. Give your agent a task and see if it follows the constraints.

Once you've refined prompts through real use, set up your own registry:

```bash
clumsies config set registry git@github.com:you/prompt-registry.git
clumsies add .prompts/rule/coding/
```

## Status

| Component | Status |
|-----------|--------|
| CLI + Registry | Stable — prompt management, bundles, import/export |
| MCP Server | Working — `clumsies mcp serve`, 9 tools implemented |
| Stats engine | Working — workspace/prompt/diff/timebucket scopes |
| Claude Code plugin | Planned — hooks, slash commands, startup bootstrap |

The MCP server and stats engine are functional but haven't been tested with real agent workflows at scale. Trace data quality depends on agent compliance — which is exactly the problem the planned Claude Code plugin aims to address.
