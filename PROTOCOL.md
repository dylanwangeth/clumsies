# Clumsies Protocol v2

> An open standard for organizing, sharing, and reusing AI Agent prompts.

## 1. Problem Statement

### 1.1 The Single-File Limitation

As projects grow in complexity, a single prompt file (CLAUDE.md, AGENTS.md) faces fundamental limitations:

- **Context overflow**: Too much information for the AI to retain effectively
- **Mixed concerns**: Rules, commands, and business context tangled together
- **Poor reusability**: Copy-pasting entire files across projects
- **Maintenance burden**: One change requires reviewing the entire file

### 1.2 The Tool Lock-in Problem

Current solutions like `.claude/commands/` or tool-specific shortcuts create fragmentation:

```
Claude Code:    /project:gen-commit
Gemini CLI:     @gen-commit
Cursor:         /gen-commit
```

Developers must learn different syntaxes for each tool, and prompt configurations don't transfer.

### 1.3 Our Approach

Clumsies Protocol takes a **pure semantic layer** approach:

- Organize prompts by **meaning** (conduct, command, custom)
- Let AI understand the structure through **natural language**
- **Tool-agnostic**: Works with any AI agent that can read files
- **Git-native**: `.prompts/` operates as an independent git repository

```
Instead of:  /project:gen-commit --scope backend
Just say:    "Generate a commit message following git_commit rules"
```

---

## 2. Core Concepts

| Concept | Description |
|---------|-------------|
| **Prompt** | Atomic unit — a markdown file that guides AI Agent behavior |
| **Meta-Prompt File** | Entry point (CLAUDE.md, AGENTS.md, etc.) that declares the prompt system |
| **Bundle** | A shareable composition of prompts for specific use cases |
| **Registry** | A git repository that stores prompts and bundles for sharing |

### 2.1 Project Structure

```
workspace/
├── CLAUDE.md              # Meta-prompt file
└── .prompts/              # Independent git repository
    ├── conduct/           # Behavioral rules (always active)
    ├── command/           # Executable operations (invoke by name)
    └── {custom}/          # Project-specific context
```

---

## 3. Prompt Types

### 3.1 conduct — Behavioral Rules

**Semantic**: Constraints and standards the AI should **always follow**.

**When loaded**: Injected into context at the start of every conversation.

**Examples**:
- `code_style.md` — Coding conventions
- `git_commit.md` — Commit message format
- `security.md` — Security guidelines

**How to reference**:
- "Follow the coding standards in conduct/"
- "Apply all rules from the conduct directory"

### 3.2 command — Executable Operations

**Semantic**: Procedures the AI can **execute on request**.

**When loaded**: When the user explicitly invokes by name.

**Examples**:
- `00_context_reinforcement.md` — Re-read context and correct drift
- `01_review_commit.md` — Code review procedure

**How to reference**:
- "Run command 01"
- "Execute context reinforcement"

**Naming convention**: Numeric prefixes (00_, 01_) enable quick invocation by number.

### 3.3 custom — Project-Specific Context

**Semantic**: Domain knowledge and project context loaded **as needed**.

**When loaded**: When discussing related topics.

**Examples**:
- `biz/product_spec.md` — Product requirements
- `tech/architecture.md` — System architecture

---

## 4. Meta-Prompt File Specification

The meta-prompt file (CLAUDE.md, AGENTS.md, etc.) is a **natural language index** that helps AI agents understand and navigate the `.prompts/` directory.

### 4.1 Purpose

The meta-prompt file is **NOT** a project introduction. It serves as:
- Natural language index for the `.prompts/` directory
- Navigation guide for AI to find and use prompts
- Explanation of directory structure and file conventions

### 4.2 Required Content

A meta-prompt file should include:

| Section | Description |
|---------|-------------|
| Directory structure | Tree view of `.prompts/` subdirectories |
| Directory explanation | What each directory contains and when to load it |
| File naming | Naming convention (`NN_UPPER_SNAKE_CASE.md`) |
| Command invocation | How to call commands (by number or name) |

### 4.3 Bundle Frontmatter

When used as part of a bundle, the meta-prompt file should include YAML frontmatter:

```yaml
---
name: bundle-name
description: Brief description of the bundle
task: coding
---
```

| Field | Description |
|-------|-------------|
| `name` | Bundle identifier (used in `init -B <name>`) |
| `description` | Brief description of the bundle |
| `task` | Task category (e.g., `coding`, `writing`) |

### 4.4 Example

```markdown
---
name: my-coding-bundle
description: Coding conduct and commands for AI agents
task: coding
---

# Prompts Index

> Natural language index for `.prompts/` directory.

## Directory Structure

\`\`\`
workspace/
├── CLAUDE.md
└── .prompts/
    ├── context/    # Project context (read before starting)
    ├── conduct/    # Behavioral rules (always active)
    ├── command/    # Executable commands (on demand)
    └── journal/    # Checkpoint logs (reference when needed)
\`\`\`

## Directory Explanation

| Directory | When to Load | Content |
|-----------|--------------|---------|
| `context/` | Before starting work | Project goals, architecture, tech stack |
| `conduct/` | Always active | Code style, git conventions, testing |
| `command/` | User triggers | Reusable task workflows |
| `journal/` | When facing issues | Problem solutions, key decisions |

## File Naming

All files use: `NN_UPPER_SNAKE_CASE.md`

## Command Invocation

- By number: "Execute command 0" → `.prompts/command/00_*.md`
- By name: "Execute REVIEW_COMMIT" → matches the file
```

### 4.5 Why This Works

The AI doesn't need special syntax or tool support. It simply:
1. Reads the meta-prompt file as a navigation guide
2. Understands the `.prompts/` directory structure
3. Knows when and how to load each type of prompt

---

## 5. Prompt File Format

Each prompt is a Markdown file.

### 5.1 Basic Format

```markdown
# Command Name

## Description
What this command does.

## Procedure
1. Step one
2. Step two
3. Step three
```

### 5.2 Optional Frontmatter

For metadata, YAML frontmatter can be added:

```markdown
---
description: Commit message format and conventions
category: conduct
---

# Git Commit Rules
...
```

| Field | Type | Description |
|-------|------|-------------|
| `description` | string | Brief description of the prompt |
| `category` | string | Target directory: `"conduct"` \| `"command"` |

The prompt name is derived from the filename (without sequence prefix). For example, `03_GIT_COMMIT.md` becomes `GIT_COMMIT` in the registry.

The `category` field determines where the prompt is placed when imported. If not specified, the CLI will attempt to detect it from the file path, defaulting to `"conduct"`.

---

## 6. Registry Specification

A registry is a git repository that stores prompts and bundles for sharing.

### 6.1 Registry Structure

```
registry/
├── prompts/
│   ├── index.json           # Prompt metadata (includes format)
│   └── {hash}               # Content files (pure SHA-256, no extension)
├── meta-prompts/
│   └── {hash}               # Meta-prompt files (pure SHA-256)
└── bundles/
    └── index.json           # Bundle metadata with prompt references
```

### 6.2 Content-Addressable Storage (Prompts)

Individual prompts are stored by SHA-256 hash:

1. Compute hash of the file content
2. Store as `prompts/{hash}` (pure hash, no extension)
3. Index in `prompts/index.json` with `format` field

**Benefits**:
- Deduplication: identical prompts stored once
- Integrity: hash verifies content
- Immutability: content at a hash never changes
- Format-agnostic: supports any file type

### 6.3 prompts/index.json

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

| Field | Description |
|-------|-------------|
| `hash` | SHA-256 hash of the file content |
| `name` | Prompt name (from frontmatter or filename) |
| `description` | Description (from frontmatter or default) |
| `format` | Original file extension (md, txt, etc.) |
| `category` | Target directory (conduct or command) |
| `created_at` | Unix timestamp |

When importing, the full filename is constructed as: `{category}/{sequence}_{name}.{format}`

### 6.4 Bundle Storage

Bundles store references to prompts and meta-prompts by hash in `bundles/index.json`.

### 6.5 bundles/index.json

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

The `category` in bundle references is just the directory name (conduct or command).
Full prompt details (name, format, etc.) are stored in `prompts/index.json`.

### 6.6 Sequence Number Assignment

When importing prompts to a local `.prompts/` directory, sequence numbers are automatically assigned:

1. Scan target directory for existing files with `NN_` prefix
2. Find first available gap (e.g., if 00, 01, 03 exist, assign 02)
3. If no gap, use the next number after the highest
4. Final filename: `{sequence:02d}_{name}.{format}`

This allows easy reference by number: "Run command 01" or "Follow conduct 03".

---

## 7. Design Principles

### 7.1 Tool Agnostic

The protocol does not depend on any specific AI tool. It works with:
- Claude Code
- Gemini CLI
- Cursor
- Any agent that can read files

### 7.2 Git Native

`.prompts/` is an independent git repository:
- Full version control
- Team collaboration via standard git workflows
- Easy backup and sharing

### 7.3 Semantic Over Syntactic

Users interact through natural language:

| Tool-specific | Clumsies way |
|--------------|--------------|
| `/project:review-commit` | "Execute review commit" |
| `@command:gen-tests` | "Run the test generation command" |

### 7.4 Human Readable

Everything is Markdown. No compilation, no special tooling required.

---

## 8. Compatibility

### 8.1 With AGENTS.md

Clumsies Protocol enhances AGENTS.md:
- Use AGENTS.md as your meta-prompt file
- Add `.prompts/` for modular organization

### 8.2 With .claude/commands/

Both can coexist:
- `.claude/commands/` for tool-triggered shortcuts
- `.prompts/command/` for semantic invocation
