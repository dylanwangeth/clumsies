# clumsies

[![CI](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml)
[![Tests](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml/badge.svg)](https://github.com/lilhammerfun/clumsies/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/github/license/lilhammerfun/clumsies?label=License)](https://github.com/lilhammerfun/clumsies/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/lilhammerfun/clumsies?label=Release)](https://github.com/lilhammerfun/clumsies/releases/latest)
[![Zig](https://img.shields.io/badge/Zig-0.15%2B-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)

AI agents manage their own memory. Users should too. As agent memory systems get more sophisticated, we believe users deserve a parallel layer they fully control — one that persists what they decide matters, not what the agent decides to keep.

clumsies is our attempt at this: a user-level memory layer for AI agents.

## The problem

AI coding agents all have memory systems — Claude Code writes to `~/.claude/memory/`, Windsurf stores memories per workspace, Copilot keeps them server-side, Gemini CLI appends to `GEMINI.md`. You can view them, and some tools let you manually add entries.

But unless you actively check and intervene, memory is agent-managed by default. The agent decides what to remember and what to surface. As Andrej Karpathy [put it](https://www.youtube.com/watch?v=LGo4VNfH228), LLMs are like a coworker with anterograde amnesia — all they have is short-term memory. When a conversation exceeds the context window, every major agent compresses or summarizes automatically: Claude Code at ~80% capacity, Cline at ~80%, Amazon Q at ~80%. You can influence the process, but you cannot decide precisely what gets kept and what gets forgotten.

There's also a portability problem. Every tool's memory is project-scoped. At best you get a single global config file. You refine prompts through real work — a commit format that catches edge cases, testing rules that reflect lessons learned — but each prompt stays trapped in the project where it was written.

## What clumsies does

Two things, both simple:

**A user-level memory layer.** You write prompts as markdown files in `.prompts/`, organized however you want. A meta-prompt file, or MPF (CLAUDE.md, AGENTS.md, etc.), tells the agent where things are. This sits alongside the agent's built-in memory, not replacing it — giving you a layer you fully control.

**Cross-project portability.** A central registry (a git repo) lets you register prompts, refine them over time, and import them into any project. Your prompt library grows with your practice — update once, pull everywhere.

```
workspace/
├── CLAUDE.md              # MPF — tells the agent where things are
└── .prompts/
    ├── PIN.md             # Pinned rules (highest priority, optional)
    ├── rule/              # Reusable rules (from registry)
    ├── house-rule/        # Project-specific rules
    ├── cmd/               # Procedures (invoke by name)
    ├── context/           # Project knowledge (stays local)
    ├── journal/           # Problem logs (stays local)
    └── ...                # Whatever else you need
```

The MPF (CLAUDE.md, AGENTS.md, COPILOT.md — whatever your tool reads) describes the `.prompts/` layout in natural language. No special syntax, no tool integration. The agent reads the file, understands the structure, and knows where to find what it needs.

<details>
<summary>Example CLAUDE.md</summary>

```markdown
Principle 1: This project uses the .prompts/ directory for all rules, context,
and commands. Read relevant files before starting work. (User-level memory)

Principle 2: Priority from high to low: .prompts/PIN.md > .prompts/ managed
memory > system prompt and model defaults. Higher priority wins on conflict.
(Memory priority)

Principle 3: Principles and memory must never be compressed or forgotten.
(Persistence)

Directory structure. Files use NN_UPPER_SNAKE_CASE.md naming. Numbers enable
quick invocation ("run cmd 0" maps to .prompts/cmd/00_*.md).

.prompts/
├── PIN.md             # Highest priority rules (read before every task)
├── context/           # Project context (read before starting work)
├── rule/              # Universal rules (always active, reusable)
├── house-rule/        # Project-specific rules (always active, local only)
├── cmd/               # Commands (invoked on demand)
├── journal/           # Checkpoint logs (consult when hitting problems)
└── ...                # Other directories as needed (todo, plan, etc.)
```

This is one approach. Your MPF can be as simple or detailed as you want —
the only requirement is that the agent can read it and find what it needs.

</details>

The full picture — user-level memory alongside agent-managed memory, connected through a registry:

![System overview](docs/overview.drawio.png)

Prompts get better through real use. You tell the agent "fix this code following coding rule ZIG_STYLE", review the output, find the prompt wasn't specific enough, refine it, try again. Once it reliably produces what you want, register it to the registry and reuse it across projects.

Borrow from others freely — skills marketplaces, GitHub repos, developer communities. But a prompt written for someone else's workflow rarely works perfectly in yours. clumsies is a personal registry, not a marketplace.

More on the design and registry internals in [ARCHITECTURE.md](./ARCHITECTURE.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

<details>
<summary>Manual install</summary>

```bash
# Download binary and checksums
curl -LO https://github.com/lilhammerfun/clumsies/releases/latest/download/clumsies-darwin-arm64
curl -LO https://github.com/lilhammerfun/clumsies/releases/latest/download/checksums.txt

# Verify and install
shasum -a 256 -c checksums.txt --ignore-missing
chmod +x clumsies-darwin-arm64
mkdir -p ~/.clumsies/bin
mv clumsies-darwin-arm64 ~/.clumsies/bin/clumsies
```

Platforms: `darwin-arm64`, `darwin-x86_64`, `linux-arm64`, `linux-x86_64`, `windows-x86_64`

Windows binaries are available but not yet validated in real-world use. If you're on Windows and willing to help test, see [#20](https://github.com/lilhammerfun/clumsies/issues/20).
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

Get a working prompt setup in 30 seconds, no configuration needed.

```bash
mkdir clumsies-demo && cd clumsies-demo

clumsies get opus-coding --registry https://github.com/lilhammerfun/clumsies-registry.git
```

This creates `.prompts/` with coding rules, reusable commands, and a four-layer architecture workflow (Architecture → ADR → Research → Spec). It also drops a `CLAUDE.md` at the project root that tells your agent where everything is.

Now give your agent a task. Here's an example, or replace it with any project you're interested in:

```
Follow the arch rules to design a local-first AI agent orchestration
framework. It should support multiple LLM backends, tool calling,
streaming output, and conversation memory persistence.
```

The agent reads `CLAUDE.md`, discovers `.prompts/`, and finds the arch rules. You don't need to point it to specific files. That's the whole point of the MPF: it tells the agent where things are so you can talk in natural language.

> The demo prompts are written in Chinese. The agent follows them regardless and responds in whatever language you write your task in. Add "用中文回复" or "Respond in English" if you want to be explicit.

Check if it worked. The agent should have created files following the architecture workflow:

```bash
ls .prompts/context/
# Expected: 01_ARCHITECTURE.md, and possibly adr/, research/, spec/
```

If you see an Architecture document that identifies modules, references ADRs for cross-cutting decisions, and links to Specs, the prompts are working. That structure came from the rules in `.prompts/rule/arch/`, not from the agent's defaults.

Once you've refined prompts through real use, set up your own registry to reuse them across projects:

```bash
# Point to your registry
clumsies config set registry git@github.com:you/prompt-registry.git

# Register prompts you've refined
clumsies add .prompts/rule/coding/

# Import them into another project
clumsies get my-coding-bundle
```

