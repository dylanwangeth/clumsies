# Clumsies Protocol v1

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

```
Instead of:  /project:gen-commit --scope backend
Just say:    "Generate a commit message following GIT_COMMIT rules"
```

---

## 2. Core Concepts

| Concept | Description |
|---------|-------------|
| **Prompt** | Atomic unit — a markdown file that guides AI Agent behavior |
| **Entry File** | Entry point (CLAUDE.md, AGENTS.md, etc.) that declares the prompt system |
| **Template** | A shareable composition of prompts for specific use cases |
| **Registry** | A repository that stores prompts and templates for distribution |

### 2.1 Project Structure (User Side)

```
project/
├── CLAUDE.md              # Entry file (or AGENTS.md, GEMINI.md, etc.)
└── .prompts/
    ├── conduct/           # Behavioral rules (always active)
    ├── command/           # Executable operations (invoke by name)
    └── {custom}/          # Project-specific context (biz/, tech/, etc.)
```

---

## 3. Prompt Types

### 3.1 conduct — Behavioral Rules

**Semantic**: Constraints and standards the AI should **always follow**.

**When loaded**: Injected into context at the start of every conversation.

**Examples**:
- `CODE_STYLE.md` — Coding conventions
- `GIT_COMMIT.md` — Commit message format
- `NAMING.md` — Naming conventions
- `SECURITY.md` — Security guidelines

**How to reference**:
- "Follow the coding standards in conduct/"
- "Apply all rules from the conduct directory"

### 3.2 command — Executable Operations

**Semantic**: Procedures the AI can **execute on request**.

**When loaded**: When the user explicitly invokes by name.

**Examples**:
- `00_CONTEXT_REINFORCEMENT.md` — Re-read context and correct drift
- `01_REVIEW_COMMIT.md` — Code review procedure
- `02_GENERATE_TESTS.md` — Test generation workflow

**How to reference**:
- "Run command 01"
- "Execute context reinforcement"
- "Invoke the review commit procedure"

**Naming convention**: Numeric prefixes (00_, 01_) indicate suggested order or priority, but are not mandatory.

### 3.3 custom — Project-Specific Context

**Semantic**: Domain knowledge and project context loaded **as needed**.

**When loaded**: When discussing related topics.

**Examples**:
- `biz/PRODUCT_SPEC.md` — Product requirements
- `tech/ARCHITECTURE.md` — System architecture
- `api/ENDPOINTS.md` — API documentation

**How to reference**:
- "Refer to the product docs in biz/"
- "Check the architecture doc in tech/"

---

## 4. Entry File Specification

The entry file (CLAUDE.md, AGENTS.md, etc.) serves as the **meta-prompt** that teaches the AI how to use the prompt system.

### 4.1 Required Sections

```markdown
# Project Name

## Prompt System

This project uses Clumsies Protocol for prompt organization.

### Directory Structure
- `.prompts/conduct/` — Always-active behavioral rules
- `.prompts/command/` — Executable commands (invoke by name/number)
- `.prompts/{custom}/` — Project-specific context

### Available Commands
- `00_CONTEXT_REINFORCEMENT` — Re-read docs and correct behavioral drift
- `01_REVIEW_COMMIT` — Code review checklist

### Usage
- Always follow rules in `conduct/`
- Execute commands when asked: "run command 01"
- Reference custom docs as needed
```

### 4.2 Why This Works

The AI doesn't need special syntax or tool support. It simply:
1. Reads the entry file
2. Understands the directory structure semantically
3. Responds to natural language requests

---

## 5. Prompt File Format

Each prompt is a Markdown file with optional YAML frontmatter.

### 5.1 Basic Format (Local Use)

```markdown
# Command Name

## Description
What this command does.

## Procedure
1. Step one
2. Step two
3. Step three
```

Frontmatter is **optional** for local use.

### 5.2 Full Format (For Registry)

When publishing to a registry, frontmatter is **required**:

```markdown
---
type: command
lang: en
path: command/00_CONTEXT_REINFORCEMENT.md
author: dylan
publication:
  name: Context Reinforcement
  description: Re-review docs and correct behavioral drift
  recommended_models:
    - claude-sonnet-4
    - gpt-4
---

# Context Reinforcement

## Description
...
```

### 5.3 Frontmatter Schema

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | `"command"` \| `"conduct"` \| `"custom"` |
| `lang` | string | yes | ISO 639-1 language code (e.g., `en`, `zh`) |
| `path` | string | yes | Original path relative to `.prompts/` |
| `author` | string | yes | Author identifier |

#### Publication Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `publication.name` | string | yes | Display name |
| `publication.description` | string | yes | Short description |
| `publication.recommended_models` | string[] | no | Tested models |
| `publication.min_context_window` | number | no | Minimum tokens needed |

---

## 6. Registry Specification

A registry stores prompts and templates using **content-addressable storage**.

### 6.1 Registry Structure

```
registry/
├── prompts/
│   ├── index.json              # Prompt metadata index
│   └── {hash}.md               # Content files (with frontmatter)
└── templates/
    ├── index.json              # Template listing
    └── {template-name}/
        ├── meta.json           # Template definition
        └── files/
            ├── en/CLAUDE.md    # Entry files by language
            └── zh/CLAUDE.md
```

### 6.2 Content-Addressable Storage

Prompts are stored by their SHA-256 hash:

1. Compute hash of the **complete file content** (including frontmatter)
2. Store as `prompts/{hash}.md`
3. Index in `prompts/index.json`

**Benefits**:
- Deduplication: identical prompts stored once
- Integrity: hash verifies content hasn't changed
- Immutability: content at a hash never changes

### 6.3 prompts/index.json Schema

```json
{
  "version": "1",
  "prompts": [
    {
      "hash": "36995f0ae35fcafcc0c44ac1570a96708302932df0addd1dd60eecc17ea2da90",
      "type": "command",
      "task": "coding",
      "lang": "en",
      "path": "command/00_CONTEXT_REINFORCEMENT.md",
      "author": "dylan",
      "publication": {
        "name": "Context Reinforcement",
        "description": "Re-review docs and correct behavioral drift"
      }
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hash` | string | yes | SHA-256 hash of the file content |
| `type` | string | yes | `"command"` \| `"conduct"` |
| `task` | string | yes | Task category (e.g., `coding`, `writing`, `design`) |
| `lang` | string | yes | ISO 639-1 language code |
| `path` | string | yes | Original path relative to `.prompts/` |
| `author` | string | yes | Author identifier |
| `publication` | object | yes | Display metadata |

### 6.4 Template meta.json Schema

```json
{
  "name": "solocc",
  "task": "coding",
  "description": "Solo developer workflow for Claude Code",
  "author": "dylan",
  "version": "1.0.0",
  "prompts": {
    "en": ["hash1", "hash2", "..."],
    "zh": ["hash3", "hash4", "..."]
  },
  "files": ["CLAUDE.md"]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Template identifier (URL-safe) |
| `task` | string | yes | Task category (e.g., `coding`, `writing`, `design`) |
| `description` | string | yes | Human-readable description |
| `author` | string | yes | Author identifier |
| `version` | string | yes | Semantic version |
| `prompts` | object | yes | Language → hash arrays |
| `files` | string[] | yes | Entry file names to include |

### 6.5 templates/index.json Schema

```json
{
  "version": "1",
  "templates": [
    {
      "hash": "e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6",
      "name": "solocc",
      "task": "coding",
      "description": "Solo developer workflow",
      "author": "dylan",
      "version": "1.0.0",
      "languages": ["en", "zh"]
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hash` | string | yes | SHA-256 hash of template directory contents |
| `name` | string | yes | Template display name (not required to be unique) |
| `task` | string | yes | Task category |
| `description` | string | yes | Human-readable description |
| `author` | string | yes | Author identifier |
| `version` | string | yes | Semantic version |
| `languages` | string[] | yes | Available language codes |

### 6.6 Template Hash Calculation

Template hash is computed from the entire template directory contents:

```
hash = SHA-256(meta.json + files/en/CLAUDE.md + files/zh/CLAUDE.md + ...)
```

Files are concatenated in alphabetical order by path. This ensures:
- Any change to meta.json → hash changes
- Any change to entry files → hash changes
- Adding/removing language files → hash changes

---

## 7. Design Principles

### 7.1 Tool Agnostic

The protocol does not depend on any specific AI tool's features. It works with:
- Claude Code
- Gemini CLI
- Cursor
- Any agent that can read project files

### 7.2 Semantic Over Syntactic

Users interact through natural language, not special syntax:

| Tool-specific | Clumsies way |
|--------------|--------------|
| `/project:review-commit` | "Execute review commit" |
| `@command:gen-tests` | "Run the test generation command" |
| `--use-rule=git-commit` | "Follow GIT_COMMIT rules" |

### 7.3 Progressive Enhancement

- Start simple: Just organize files in `.prompts/`
- Add frontmatter when you want to share
- Publish to registry when polished

### 7.4 Human Readable

Everything is Markdown. No compilation, no special tooling required to read or edit.

---

## 8. Compatibility

### 8.1 With AGENTS.md

Clumsies Protocol is designed as an **enhancement** to AGENTS.md, not a replacement:

- Use AGENTS.md as your entry file
- Add `.prompts/` for modular organization
- Both can coexist

### 8.2 With .claude/commands/

If you prefer Claude Code's native commands:
- `.claude/commands/` for tool-triggered shortcuts
- `.prompts/command/` for semantic, natural-language invocation
- Use whichever fits your workflow
