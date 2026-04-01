# Architecture

How clumsies organizes user-level memory for AI agents.

## 1. System overview

```
Core (Zig library)
├── MCP Server     → agent-facing protocol (search, load, refer, etc.)
├── CLI            → human-facing commands + hook/script target
└── CC Plugin      → Claude Code adapter (hooks + skills)
    ├── Hooks      → call CLI on session start / stop
    └── Skills     → /complete-task, /stats, /search, auto-generated workflows
```

All three entry points share a single core library and write to the same trace log. MCP works with any MCP-compatible agent. The CC Plugin adds reliability on top of MCP for Claude Code specifically.

## 2. The `.prompts/` space

A directory of markdown files sitting in your project. Three kinds:

| Kind | Directory | Meaning |
|------|-----------|---------|
| **Rule** | `rule/` | Constraints that guide agent behavior. Parsed into individual constraints. |
| **Workflow** | `workflow/` | Ordered sequences of constraints. Used as procedures or methodologies. |
| **Context** | `context/` | Reference material. No instructions — just facts for the agent to draw on. |

Subdirectories under each kind are groups (e.g., `rule/coding/`, `workflow/cmd/`). The first-level directory name is the kind, everything below is organizational.

```
.prompts/
├── META_PROMPT.md         # Protocol bootstrap — loaded on session start
├── rule/
│   ├── coding/            # group=coding
│   └── zig/               # group=zig
├── workflow/
│   └── cmd/               # group=cmd
└── context/
    ├── spec/              # group=spec
    └── research/          # group=research
```

`META_PROMPT.md` is the entry point. It tells the agent what `.prompts/` is, how to use the MCP tools, and what the priority model looks like. The MCP server reads it on `memory.setup`. The CC Plugin loads it automatically on session start.

## 3. MCP Protocol

Nine tools for agent interaction:

| Tool | Purpose |
|------|---------|
| `memory.setup` | Bootstrap — load META_PROMPT.md content |
| `memory.begin` | Start a task, return task_id |
| `memory.search` | Discover available rules/workflows/context |
| `memory.load` | Load prompt content by id (with hash-based delta) |
| `memory.refer` | Declare a constraint reference |
| `memory.shortcut` | Invoke a workflow by name |
| `memory.complete` | Finalize a task |
| `memory.stats` | Query aggregated trace data |
| `memory.validate` | Check prompt format, list constraints |

Every tool call produces a trace event in `.clumsies/trace.jsonl`. Trace data drives the stats engine.

## 4. Trace and stats

`.clumsies/` is the system space (like `.git/` for git). It stores trace logs — a JSONL timeline of all MCP interactions. Users don't edit it directly.

The stats engine aggregates trace data into views:

- **Workspace scope**: which prompts are used, how often, in how many tasks
- **Prompt scope**: which constraints within a prompt are hot, cold, or dead
- **Diff scope**: how constraint usage changed between prompt versions
- **Time buckets**: coverage trends over days or weeks

Available via `clumsies stats` (CLI) and `memory.stats` (MCP).

## 5. Claude Code Plugin

The plugin solves MCP's passive nature — agents may forget to call tools.

**Hooks** (system-driven):
- `SessionStart`: loads META_PROMPT.md, creates/resumes a task, generates workflow skills
- `Stop`: reminds the agent to declare constraint references

**Skills** (user-driven):
- `/complete-task` — mark task as done (user decides, not agent)
- `/stats` — show constraint usage
- `/search` — discover available prompts
- Auto-generated workflow skills from `.prompts/workflow/` (e.g., `/gen-commit-msg`)

All workflow skills support `$ARGUMENTS` — pass a task description to use the workflow as a methodology, or invoke without arguments for a quick procedure.

## 6. Registry

A git repo for sharing prompts and bundles across projects.

```
registry/
├── prompts/
│   ├── index.json         # Prompt metadata
│   └── {hash}             # Content files (SHA-256, no extension)
└── bundles/
    └── index.json
```

Prompts are content-addressed by SHA-256. Same content = same hash = stored once. Metadata (name, description, group) lives in `index.json`, separate from content.

Bundles group prompts for distribution. A bundle can include a meta-prompt file (stored with `"group": "../"` to indicate it belongs at the project root).

## 7. Prompt format

Prompts are plain markdown. No frontmatter required.

Rule and Workflow files follow a constraint format: `##` headings and list items are parsed as individual constraints by `memory.validate`. Each constraint gets a stable id (`c-1`, `c-2`, ...) and a `text_hash` for cross-version tracking.

Context files are not parsed for constraints — they provide background information as-is.

## 8. CLI commands

**Registry**: `add`, `rm`, `ls`, `show`, `set`, `get`, `pub` — manage prompts and bundles.

**Workspace**: `clone`, `remote`, `push`, `pull`, `status`, `log` — manage `.prompts/` as a git repo.

**Task**: `setup`, `begin`, `complete`, `search`, `load`, `refer`, `validate` — mirror MCP tools for use by hooks and scripts.

**Other**: `stats`, `config`, `mcp`, `upgrade`.

All task commands detect whether stdout is a terminal. TTY mode shows human-friendly output with colors. Pipe mode outputs raw text for programmatic consumption by hooks.
