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
| **Entry File** | Entry point (CLAUDE.md, AGENTS.md, etc.) that declares the prompt system |
| **Bundle** | A shareable composition of prompts for specific use cases |
| **Registry** | A repository that stores prompts and bundles for distribution |

### 2.1 Project Structure (User Side)

```
project/
├── CLAUDE.md              # Entry file (auto-synced with .prompts/)
└── .prompts/              # Independent git repository
    ├── .git/
    ├── conduct/           # Behavioral rules (always active)
    ├── command/           # Executable operations (invoke by name)
    ├── {custom}/          # Project-specific context (biz/, tech/, etc.)
    └── CLAUDE.md          # Entry file copy (version-controlled)
```

### 2.2 Entry File Sync

Entry files are automatically synchronized between the project root and `.prompts/`:

| Operation | Direction | Purpose |
|-----------|-----------|---------|
| `push` | root → .prompts/ | Version control root changes |
| `pull` | .prompts/ → root | Update root from remote |
| `clone` | .prompts/ → root | Initialize root from remote |

Supported entry files: `CLAUDE.md`, `CURSOR.md`, `AGENTS.md`, `COPILOT.md`

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

When publishing to a registry, frontmatter is **recommended**:

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
| `type` | string | no | `"command"` \| `"conduct"` \| `"custom"` |
| `lang` | string | no | ISO 639-1 language code (e.g., `en`, `zh`) |
| `path` | string | no | Original path relative to `.prompts/` |
| `author` | string | no | Author identifier |

#### Publication Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `publication.name` | string | no | Display name |
| `publication.description` | string | no | Short description |
| `publication.recommended_models` | string[] | no | Tested models |
| `publication.min_context_window` | number | no | Minimum tokens needed |

---

## 6. Registry Specification

A registry stores prompts and bundles using **content-addressable storage**.

### 6.1 Registry Structure

```
registry/
├── prompts/
│   ├── index.json              # Prompt metadata index
│   └── {hash}.md               # Content files (SHA-256 hash)
└── bundles/
    ├── index.json              # Bundle listing
    └── {bundle-name}/
        ├── conduct/            # Conduct prompts
        │   └── *.md
        └── command/            # Command prompts
            └── *.md
```

### 6.2 Content-Addressable Storage (Prompts)

Prompts are stored by their SHA-256 hash:

1. Compute hash of the **complete file content**
2. Store as `prompts/{hash}.md`
3. Index in `prompts/index.json`

**Benefits**:
- Deduplication: identical prompts stored once
- Integrity: hash verifies content hasn't changed
- Immutability: content at a hash never changes

### 6.3 prompts/index.json Schema

```json
{
  "<sha256-hash>": {
    "name": "prompt_name",
    "description": "Optional description"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Display name (derived from filename) |
| `description` | string | no | Short description |

### 6.4 Bundle Storage

Bundles are stored by name as directory structures:

```
bundles/
└── my-bundle/
    ├── conduct/
    │   └── 00_RULE.md
    └── command/
        └── 00_CMD.md
```

### 6.5 bundles/index.json Schema

```json
{
  "<bundle-name>": {
    "description": "Optional description"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | no | Short description |

---

## 7. CLI Operations

### 7.1 Main Commands (manage .prompts/)

| Command | Description |
|---------|-------------|
| `init <git-url>` | Initialize .prompts/ and link to remote |
| `clone <git-url>` | Clone remote to .prompts/ |
| `push [-m "msg"]` | Commit and push to remote |
| `pull` | Pull latest from remote |
| `status` | Show git status |
| `log` | Show commit history |

### 7.2 Registry Commands

| Command | Description |
|---------|-------------|
| `list -P` | List prompts in registry |
| `list -B` | List bundles in registry |
| `show -P <hash>` | Show prompt content |
| `show -B <name>` | Show bundle contents |
| `add -P <hash>` | Add prompt to .prompts/ |
| `add -B <name>` | Add bundle to .prompts/ |
| `publish -P <file>` | Publish prompt to registry |
| `publish -B <name> <dirs>` | Publish bundle to registry |
| `rm -P <hash>` | Remove prompt from registry |
| `rm -B <name>` | Remove bundle from registry |

### 7.3 Configuration

| Command | Description |
|---------|-------------|
| `config set <key> <value>` | Set configuration |
| `config get <key>` | Get configuration |
| `config list` | List all configuration |

**Configuration keys**:
- `registry` — Registry git URL

---

## 8. Design Principles

### 8.1 Tool Agnostic

The protocol does not depend on any specific AI tool's features. It works with:
- Claude Code
- Gemini CLI
- Cursor
- Any agent that can read project files

### 8.2 Git Native

The `.prompts/` directory is an independent git repository:
- Full version control for prompts
- Team collaboration through standard git workflows
- Easy backup and restore
- Branch-based experimentation

### 8.3 Semantic Over Syntactic

Users interact through natural language, not special syntax:

| Tool-specific | Clumsies way |
|--------------|--------------|
| `/project:review-commit` | "Execute review commit" |
| `@command:gen-tests` | "Run the test generation command" |
| `--use-rule=git-commit` | "Follow GIT_COMMIT rules" |

### 8.4 Progressive Enhancement

- Start simple: Just organize files in `.prompts/`
- Add git remote when ready to share
- Publish to registry when polished

### 8.5 Human Readable

Everything is Markdown. No compilation, no special tooling required to read or edit.

---

## 9. Compatibility

### 9.1 With AGENTS.md

Clumsies Protocol is designed as an **enhancement** to AGENTS.md, not a replacement:

- Use AGENTS.md as your entry file
- Add `.prompts/` for modular organization
- Both can coexist

### 9.2 With .claude/commands/

If you prefer Claude Code's native commands:
- `.claude/commands/` for tool-triggered shortcuts
- `.prompts/command/` for semantic, natural-language invocation
- Use whichever fits your workflow

---

## 10. Migration from v1

### 10.1 Key Changes

| v1 | v2 |
|----|-----|
| Templates | Bundles |
| Local registry cache | .prompts/ as git repo |
| `clumsies use <hash>` | `clumsies clone <url>` |
| `clumsies search` | `clumsies list -P/-B` |

### 10.2 Migration Steps

1. Initialize .prompts/ as git repo: `clumsies init <your-remote>`
2. Configure registry: `clumsies config set registry <registry-url>`
3. Use new commands for registry operations
