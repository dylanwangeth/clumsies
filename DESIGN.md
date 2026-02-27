# Design Notes

Working notes on organizing prompts as a semantic layer. This is a snapshot of what currently works for us.

## 1. The Problem

A single prompt file (CLAUDE.md, AGENTS.md) stops working once a project gets complex enough. Too much context crammed in, rules mixed with procedures, no way to reuse pieces across projects without copy-pasting the whole thing.

Tool-specific prompt systems make it worse. Claude Code uses `/project:gen-commit`, Gemini CLI uses `@gen-commit`, Cursor uses `/gen-commit`. Same idea, three syntaxes, none portable.

We wanted something simpler: organize prompts by meaning, let AI navigate via natural language, and keep everything in plain files so it works with any tool.

```
Instead of:  /project:gen-commit --scope backend
Just say:    "Generate a commit message following git_commit rules"
```

## 2. Core Concepts

Four things to know: **prompts** are individual markdown files. A **meta-prompt file** (CLAUDE.md, etc.) is the entry point that tells AI where to find them. **Bundles** group prompts together for sharing. The **registry** is a git repo that holds all of it.

### Project structure

```
workspace/
├── CLAUDE.md              # Meta-prompt file
└── .prompts/              # Independent git repo
    ├── conduct/           # Rules (always active)
    ├── command/           # Procedures (invoke by name)
    ├── context/           # Project knowledge (local only)
    └── journal/           # Problem logs (local only)
```

Only `conduct/` and `command/` are shareable via registry. `context/` and `journal/` stay local.

## 3. Prompt Types

### conduct — Rules

Things the AI should always follow. Coding conventions, commit format, security guidelines. Loaded at the start of every conversation.

Reference them naturally: "Follow the coding standards in conduct/" or "Apply all conduct rules."

### command — Procedures

Things the AI runs on request. Review flows, release checklists, code generation steps. Numbered prefixes (00_, 01_) let users invoke by number: "Run command 01."

### context — Project Knowledge (local)

Domain context, architecture notes, tech decisions. Read before starting work. Not shared — every project has its own.

### journal — Problem Logs (local)

How bugs were fixed, why decisions were made. Reference when facing similar issues. Also not shared.

## 4. Meta-Prompt File

The meta-prompt file is a navigation guide, not a project introduction. It tells AI what's in `.prompts/` and how to use it.

Typical contents: directory tree, what each directory means, file naming convention (`NN_UPPER_SNAKE_CASE.md`), how to invoke commands.

When used as part of a bundle, the file includes YAML frontmatter:

```yaml
---
name: my-coding-bundle
description: Coding conduct and commands for AI agents
task: coding
---
```

The AI doesn't need special syntax or tool support. It reads the meta-prompt, understands the directory layout, and knows when to load what.

## 5. Prompt File Format

Prompts are plain markdown. No frontmatter, no embedded metadata.

Metadata lives in `prompts/index.json` and is managed separately:

| Field | Source |
|-------|--------|
| `name` | From filename, prefix stripped. `03_GIT_COMMIT.md` becomes `GIT_COMMIT` |
| `description` | `--desc` flag at registration, or `"-"` |
| `category` | `--cat` flag, or inferred from directory structure |

This separation means you can update metadata (rename, re-categorize) without changing the prompt content or its hash.

## 6. Registry

A registry is a git repo for sharing prompts and bundles.

### Structure

```
registry/
├── prompts/
│   ├── index.json           # Prompt metadata
│   └── {hash}               # Content files (SHA-256, no extension)
├── meta-prompts/
│   └── {hash}
└── bundles/
    └── index.json
```

### Content-addressable storage

Prompts are stored by SHA-256 hash. Same content, same hash, stored once. The hash also serves as integrity check — content at a given hash never changes.

### prompts/index.json

```json
{
  "prompts": [
    {
      "hash": "a1b2c3...",
      "name": "git_commit",
      "description": "Git commit message format",
      "format": "md",
      "category": "conduct",
      "created_at": "1704067200"
    }
  ]
}
```

### bundles/index.json

```json
{
  "bundles": [
    {
      "name": "my-bundle",
      "task": "coding",
      "description": "A starter bundle",
      "created_at": "1704067200",
      "meta_prompt": "f7g8h9...",
      "prompts": [
        { "hash": "a1b2c3...", "category": "conduct" },
        { "hash": "d4e5f6...", "category": "command" }
      ]
    }
  ]
}
```

Bundle `category` is the directory path (e.g., `conduct/git`). Full prompt details come from `prompts/index.json`.

### Sequence numbers on import

When importing prompts to `.prompts/`, sequence numbers are auto-assigned: scan for existing `NN_` prefixes, fill the first gap, or use the next number. Final filename: `{NN}_{name}.{format}`.

## 7. Compatibility

Works alongside existing tool-specific setups:

- Use AGENTS.md as your meta-prompt file if you want
- `.claude/commands/` and `.prompts/command/` can coexist — one for tool shortcuts, the other for semantic invocation
