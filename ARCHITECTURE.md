# Architecture

How clumsies organizes user-level memory for AI agents.

## 1. Core Concepts

Four things to know: **prompts** are individual markdown files. A **meta-prompt file (MPF)** (CLAUDE.md, etc.) tells AI where to find them. **Bundles** group prompts together for sharing. The **registry** is a git repo that holds all of it.

### Project structure

```
workspace/
├── CLAUDE.md              # MPF (meta-prompt file)
└── .prompts/              # Independent git repo
    ├── rule/              # Universal rules (reusable across projects)
    ├── house-rule/        # Project-specific rules (current project only)
    ├── cmd/               # Procedures (invoke by name)
    ├── context/           # Project knowledge (local only)
    ├── journal/           # Problem logs (local only)
    └── ...                # Whatever else you need
```

`rule/`, `house-rule/`, and `cmd/` are shareable via registry. `context/` and `journal/` stay local.

## 2. Directory Organization

clumsies does not enforce any directory layout. You organize `.prompts/` however you want — the directory names, nesting, and semantics are entirely up to you. clumsies only uses the directory path structurally: it derives the `group` metadata from the path relative to `.prompts/` (e.g., a file in `.prompts/coding/style/` gets group `coding/style`).

The project structure shown above is one example. Here's the reasoning behind that particular layout:

- **rule/** — Rules reusable across projects (coding standards, commit format). Registered in the registry and imported as-is into new projects.
- **house-rule/** — Rules specific to the current project. Not expected to transfer.
- **cmd/** — Procedures the AI runs on request. Numbered prefixes (00_, 01_) let users invoke by number: "Run cmd 01."
- **context/** — Project knowledge (architecture notes, tech decisions). Stays local.
- **journal/** — Problem logs (how bugs were fixed, why decisions changed). Stays local.

## 3. Meta-Prompt File (MPF)

The meta-prompt file is a navigation guide, not a project introduction. It tells AI what's in `.prompts/` and how to use it.

Typical contents: directory tree, what each directory means, file naming convention (`NN_UPPER_SNAKE_CASE.md`), how to invoke commands.

The AI doesn't need special syntax or tool support. It reads the MPF, understands the directory layout, and knows when to load what.

## 4. Prompt File Format

Prompts are plain markdown. No frontmatter, no embedded metadata.

Metadata lives in `prompts/index.json` and is managed separately:

| Field | Source |
|-------|--------|
| `name` | From filename, prefix stripped. `03_GIT_COMMIT.md` becomes `GIT_COMMIT` |
| `description` | `--desc` flag, or `"-"` |
| `group` | `--group` flag, or derived from `.prompts/` path (e.g., `rule/coding`) |

This separation means you can update metadata (rename, re-categorize) without changing the prompt content or its hash.

## 5. Registry

A registry is a git repo for sharing prompts and bundles.

### Structure

```
registry/
├── prompts/
│   ├── index.json           # Prompt metadata (includes meta-prompt files)
│   └── {hash}               # Content files (SHA-256, no extension)
└── bundles/
    └── index.json
```

Meta-prompt files are stored in `prompts/` with `"group": "../"`. The `../` convention reflects their position relative to `.prompts/` — they live at the project root, one level above `.prompts/`.

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
      "group": "rule",
      "created_at": "1704067200"
    },
    {
      "hash": "f7g8h9...",
      "name": "CLAUDE",
      "description": "Navigation guide for AI agents",
      "format": "md",
      "group": "../",
      "created_at": "1704067200"
    }
  ]
}
```

The `"group": "../"` entry is a meta-prompt file. On import, it is placed at the project root (e.g., `./CLAUDE.md`) without sequence prefix.

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
        { "hash": "a1b2c3..." },
        { "hash": "d4e5f6..." },
        { "hash": "f7g8h9..." }
      ]
    }
  ]
}
```

The `meta_prompt` field is a convenience pointer to the meta-prompt file's hash; the same hash also appears in the `prompts` array and in `prompts/index.json` with `"group": "../"`. Full prompt details come from `prompts/index.json`.

### Sequence numbers on import

When importing prompts to `.prompts/`, sequence numbers are auto-assigned: scan for existing `NN_` prefixes, fill the first gap, or use the next number. Final filename: `{NN}_{name}.{format}`.

## 6. Compatibility

Works alongside existing tool-specific setups:

- Use AGENTS.md as your meta-prompt file if you want
- `.claude/commands/` and `.prompts/cmd/` can coexist — one for tool shortcuts, the other for semantic invocation
