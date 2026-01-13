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
Just say:    "Generate a commit message following GIT_COMMIT rules"
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
- `CODE_STYLE.md` — Coding conventions
- `GIT_COMMIT.md` — Commit message format
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

**How to reference**:
- "Run command 01"
- "Execute context reinforcement"

**Naming convention**: Numeric prefixes (00_, 01_) enable quick invocation by number.

### 3.3 custom — Project-Specific Context

**Semantic**: Domain knowledge and project context loaded **as needed**.

**When loaded**: When discussing related topics.

**Examples**:
- `biz/PRODUCT_SPEC.md` — Product requirements
- `tech/ARCHITECTURE.md` — System architecture

---

## 4. Meta-Prompt File Specification

The meta-prompt file (CLAUDE.md, AGENTS.md, etc.) teaches the AI how to use the prompt system.

### 4.1 Minimal Structure

```markdown
# Project Name

Brief description.

@import .prompts/conduct/
@import .prompts/command/
```

The `@import` directive tells the AI to load all prompts from the specified directory.

### 4.2 Why This Works

The AI doesn't need special syntax or tool support. It simply:
1. Reads the meta-prompt file
2. Understands the directory structure semantically
3. Responds to natural language requests

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
type: command
lang: en
author: username
---

# Command Name
...
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"command"` \| `"conduct"` \| `"custom"` |
| `lang` | string | ISO 639-1 language code |
| `author` | string | Author identifier |

---

## 6. Registry Specification

A registry is a git repository that stores prompts and bundles for sharing.

### 6.1 Registry Structure

```
registry/
├── prompts/
│   ├── index.json           # Prompt metadata
│   └── {hash}.md            # Content files (SHA-256)
└── bundles/
    ├── index.json           # Bundle metadata
    └── {bundle-name}/       # Bundle directory
        ├── conduct/
        └── command/
```

### 6.2 Content-Addressable Storage (Prompts)

Individual prompts are stored by SHA-256 hash:

1. Compute hash of the file content
2. Store as `prompts/{hash}.md`
3. Index in `prompts/index.json`

**Benefits**:
- Deduplication: identical prompts stored once
- Integrity: hash verifies content
- Immutability: content at a hash never changes

### 6.3 prompts/index.json

```json
{
  "prompts": [
    {
      "hash": "a1b2c3...",
      "name": "GIT_COMMIT",
      "description": "Git commit message format",
      "created_at": "1704067200"
    }
  ]
}
```

### 6.4 Bundle Storage

Bundles are stored as named directories containing conduct/ and command/ subdirectories.

### 6.5 bundles/index.json

```json
{
  "bundles": [
    {
      "hash": "my-bundle",
      "name": "my-bundle",
      "description": "A starter bundle",
      "created_at": "1704067200"
    }
  ]
}
```

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
