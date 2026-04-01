# clumsies

[![CI](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml)
[![Tests](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/github/license/lilhammerfun/clumsies?label=License)](https://github.com/lilhammerfun/clumsies/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/lilhammerfun/clumsies?include_prereleases&label=Release)](https://github.com/lilhammerfun/clumsies/releases/tag/v0.17.0-alpha)
[![Zig](https://img.shields.io/badge/Zig-0.15%2B-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)

User-controlled constraints that survive agent memory compression.

> **v0.17.0-alpha** — functional but not battle-tested. The stable release (v0.16.3) does not include MCP, stats, or the Claude Code plugin.

## The problem

Every AI agent compresses memory when context runs low. Claude Code at ~80% capacity, Cline at ~80%, Amazon Q at ~80%. The agent decides what matters and what gets dropped. This works for generic knowledge — common patterns, standard library usage, widely known conventions.

But your project has rules that are specific to you. "All Zig code must use explicit allocators, never GeneralPurposeAllocator." "Commit messages follow this exact subsystem:subject format." "External API calls must go through the retry wrapper." These rules matter to your project, but from the compression algorithm's perspective, they are edge cases — not frequent enough to be prioritized, not generic enough to be preserved. They get silently dropped, and the agent keeps working confidently with outputs that look correct but violate constraints you thought were non-negotiable.

You have no way to know what was compressed away. The agent does not tell you.

## The approach

clumsies puts your critical constraints in a place the agent's compression algorithm cannot touch: a `.prompts/` directory in your project that the agent queries but never manages.

You decide what goes in `.prompts/`. You write rules, workflows, and context as markdown files. The agent discovers them through a structured protocol (`memory.search`, `memory.load`), follows them, and declares which ones it actually used (`memory.refer`). Over time, the trace data tells you which constraints are effective and which are dead weight — so you can refine what you wrote.

The agent has no authority to compress, summarize, or delete anything in `.prompts/`. It can only read.

## What we're building

**CLI + Registry.** Manage a personal prompt library. Register constraints refined through real use, store them in a git-based registry, import them into any project.

**MCP Server.** Structured protocol for agents to discover constraints (`memory.search`), load them (`memory.load`), and declare references (`memory.refer`). Every interaction produces a trace log.

**Stats engine.** Aggregates trace data: which constraints are hot, which are cold, how coverage changes across versions.

**Claude Code plugin.** Hooks and skills that solve MCP's passive nature. Startup hook loads your meta-prompt automatically. Stop hook reminds the agent to declare constraint references. `/complete-task` puts task completion in your hands.

## Quick start with Claude Code

Install the CLI (v0.17.0-alpha — the install script pulls the stable release; for alpha, download manually from [releases](https://github.com/lilhammerfun/clumsies/releases/tag/v0.17.0-alpha)):

```bash
# stable (v0.16.3, no MCP/plugin support)
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh

# alpha (v0.17.0-alpha, recommended for full experience)
curl -LO https://github.com/lilhammerfun/clumsies/releases/download/v0.17.0-alpha/clumsies-darwin-arm64
chmod +x clumsies-darwin-arm64
mkdir -p ~/.clumsies/bin
mv clumsies-darwin-arm64 ~/.clumsies/bin/clumsies
```

Import a starter bundle into your project:

```bash
cd your-project
clumsies get opus-coding --registry https://github.com/lilhammerfun/clumsies-registry.git
```

This creates `.prompts/` with coding rules, workflows, and a `META_PROMPT.md`. Launch Claude Code with the plugin (marketplace distribution planned):

```bash
claude --plugin-dir /path/to/clumsies/cc-plugin
```

On session start, the plugin loads `META_PROMPT.md`, creates a task, and generates slash commands for your workflows. Give the agent a task — it will search and load constraints from `.prompts/`. When you're done, type `/complete-task`.

Check what happened:

```bash
clumsies stats
```

## The `.prompts/` layout

```
.prompts/
├── META_PROMPT.md     # protocol bootstrap — loaded on session start
├── rule/              # constraints — coding rules, project context, etc.
├── workflow/           # ordered procedures — commit messages, architecture, etc.
├── context/           # reference material — research, specs, documentation
└── ...                # whatever else you need
```

`META_PROMPT.md` tells the agent what clumsies is, how to use the protocol, and what the priority model looks like. Everything else is discovered through `memory.search` and loaded on demand.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

This installs the stable release. For the alpha release with MCP and plugin support, see [Quick start](#quick-start-with-claude-code) above.

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

**Current version: v0.17.0-alpha**

| Component | Status |
|-----------|--------|
| CLI + Registry | Working — prompt management, bundles, import/export, task lifecycle |
| MCP Server | Working — `clumsies mcp serve`, 9 tools |
| Stats engine | Working — workspace/prompt/diff/timebucket scopes |
| Claude Code plugin | Alpha — hooks, skills, auto-skill generation |

The MCP server and stats engine are functional but not yet tested at scale. Trace data quality depends on agent compliance — which is what the Claude Code plugin is designed to improve.
