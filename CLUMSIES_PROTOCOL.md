# Clumsies Protocol v1

> An open standard for organizing, sharing, and reusing AI Agent prompts.

## 1. Overview

Clumsies Protocol defines a **multi-file prompt** organization standard that enables developers to:

- Organize AI Agent prompts in a unified structure
- Share and reuse high-quality prompts
- Maintain consistent Agent behavior across projects

### 1.1 Project Structure

A Clumsies Protocol compliant project:

```
project/
├── CLAUDE.md           # Entry file
└── .prompts/           # Prompt directory
    ├── command/        # Executable skills (standard type)
    ├── conduct/        # Behavioral rules (standard type)
    └── {custom}/       # Custom prompts (e.g., biz/, tech/)
```

### 1.2 Core Concepts

| Concept | Description |
|---------|-------------|
| **Prompt** | Atomic unit - an instruction that guides AI Agent behavior |
| **Entry File** | Entry point (e.g., CLAUDE.md), the first file Agent reads |
| **Template** | A composition of Prompts, a shareable and reusable configuration |

---

## 2. Prompt Types

### 2.1 Standard Types

| Type | Directory | Purpose |
|------|-----------|---------|
| `command` | `.prompts/command/` | Executable skills/actions (similar to Anthropic's SKILL.md) |
| `conduct` | `.prompts/conduct/` | Behavioral rules and guidelines |

### 2.2 Custom Type

| Type | Directory | Purpose |
|------|-----------|---------|
| `custom` | `.prompts/{path}` | Project-specific content (e.g., `biz/`, `tech/`) |

Future protocol versions may introduce additional standard types.

---

## 3. Prompt Schema

### 3.1 Universal Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | `"command"` \| `"conduct"` \| `"custom"` |
| `lang` | string | yes | Language code (ISO 639-1) |
| `path` | string | yes | Output path (relative to `.prompts/`) |
| `author` | string | yes | Author identifier |

### 3.2 Publication Fields (Optional)

For prompts intended for public sharing:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `publication.name` | string | yes | Display name |
| `publication.description` | string | yes | Short description for discovery |
| `publication.recommended_models` | string[] | no | Recommended AI models |
| `publication.min_context_window` | number | no | Minimum context window (tokens) |

### 3.3 Schema Diagram

```
┌─────────────────────────────────────┐
│           Prompt Schema             │
│                                     │
│  type: string        (required)     │
│  lang: string        (required)     │
│  path: string        (required)     │
│  author: string      (required)     │
│                                     │
│  publication?: {     (optional)     │
│    name: string                     │
│    description: string              │
│    recommended_models?: string[]    │
│    min_context_window?: number      │
│  }                                  │
└─────────────────────────────────────┘
```

---

## 4. File Format

Prompts use Markdown format with **Frontmatter** for metadata:

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
    - claude-3-opus
---

# Context Reinforcement

## Description
...
```

### 4.1 Frontmatter Rules

- YAML format
- Must be at the beginning of the file
- Enclosed by `---`
- Non-compliant files will be rejected

---

## 5. Template Schema

A Template is a composition of Prompts:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Template identifier |
| `description` | string | yes | Template description |
| `author` | string | yes | Author identifier |
| `version` | string | yes | Semantic version |
| `prompts` | string[] | yes | List of Prompt hashes |
| `files` | string[] | no | Additional files |

---

## 6. Unique Identification

Each Prompt is uniquely identified by its **SHA-256 hash**:

```
hash = SHA-256(file_content)
```

- Same content = same hash (deduplication)
- Different content = different hash (no collision)

---

## 7. Language Specification

- Use ISO 639-1 language codes (`en`, `zh`, `ja`, etc.)
- Different language versions are **independent Prompts**
- Each has its own unique hash

---

## 8. Implementations

Reference implementation of this protocol:

- **Clumsies CLI** - Command-line tool for installing, using, and managing protocol-compliant Prompts
