# clumsies

A semantic layer for AI agent prompts.

## Why

Prompts break once projects grow — not because they're badly written, but because we treat them as syntax instead of semantics.

Most AI tools today assume prompts are disposable. You write them, tweak them, move on. That works — until you try to reuse them across projects, share them with a team, or migrate between tools.

At some point we realized: prompts already form a semantic layer — we just never named it.

In practice, some prompts behave like rules (always active), others feel more like procedures (invoke on demand). We found it useful to organize them by meaning:

- **conduct/** — behavioral rules, always in effect
- **command/** — executable procedures, invoked by name or number
- **context/** — project-specific knowledge, loaded as needed (local only)

The `.prompts/` directory operates as an independent git repository. A meta-prompt file (`CLAUDE.md`, etc.) serves as a natural language index that guides AI to navigate this structure.

### A semantic system, not a prompt collection

Clumsies does not treat prompts as a flat collection to be shared wholesale.

In real projects, prompts are inherently role- and context-sensitive: different developers, responsibilities, and stages of work require different parts of the system — not the same monolithic prompt.

This is why Clumsies focuses on semantic structure. Prompts are meant to be composed, adapted, and selectively reused, instead of copied as a single block.

The registry exists to preserve structure across projects, not to define a universal set of "best prompts".

For more background, see [DESIGN.md](./DESIGN.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

The installer downloads the binary and verifies SHA256 checksum before execution.

<details>
<summary>Manual Install</summary>

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

Platforms: `darwin-arm64`, `darwin-x86_64`, `linux-arm64`, `linux-x86_64`
</details>

## Usage

The CLI exists mostly to keep us honest. If this idea can't survive real workflows, it probably isn't worth much.

### Main Commands (manage .prompts/)

```bash
# Clone existing prompts
clumsies clone git@github.com:team/shared-prompts.git

# Set/update remote origin
clumsies remote git@github.com:user/my-prompts.git

# Make changes and push
clumsies push -m "Add review command"

# Pull latest changes
clumsies pull

# Check status and history
clumsies status
clumsies log
```

### Bundle Commands (manage bundles in registry)

```bash
# Configure registry (one-time setup)
clumsies config set registry git@github.com:org/prompt-registry.git

# List and show bundles
clumsies bundle list
clumsies bundle show <name>

# Import bundle to .prompts/
clumsies bundle import <name> [--remote-url <url>]

# Register bundle from meta-prompt file and directories
# Bundle name comes from frontmatter in meta-prompt file
clumsies bundle register <meta-prompt-file> <dirs...>
clumsies bundle register CLAUDE.md ./conduct ./command

# Update bundle contents
clumsies bundle update <name> --add <files...>
clumsies bundle update <name> --rm <hash...>
clumsies bundle update <name> --meta <file>

# Remove bundle(s)
clumsies bundle rm <name>...
```

### Prompt Commands (manage prompts in registry)

```bash
# List and show prompts
clumsies prompt list
clumsies prompt show <hash>

# Register prompt to registry (metadata via flags, not frontmatter)
clumsies prompt register <file> [--desc "..."] [--cat "..."]

# Update prompt metadata (without changing content/hash)
clumsies prompt update <hash> [--desc "..."] [--cat "..."]

# Import prompt(s) to local .prompts/
clumsies prompt import <hash>...
clumsies prompt import --cat <category>...    # Import by category (prefix match)

# Remove prompt(s)
clumsies prompt rm <hash>...
```

### Configuration

```bash
clumsies config set registry <url>           # Set registry URL
clumsies config set entry_files <files>      # Set meta-prompt files to sync
clumsies config set meta_prompt_file <file>  # Set default meta-prompt for init
clumsies config get registry                 # Get config value
clumsies config list                         # Show all config
clumsies upgrade                             # Upgrade clumsies
```

## Architecture

```
project/
├── CLAUDE.md                    # Meta-prompt file (auto-synced with .prompts/)
└── .prompts/                    # Independent git repository
    ├── .git/
    ├── conduct/                 # Behavioral rules (always active)
    │   ├── coding/              # Code style, testing, dependencies
    │   ├── git/                 # Git conventions
    │   ├── writing/             # Writing standards
    │   └── teaching/            # Teaching methodology
    ├── command/                 # Executable commands (invoke by name)
    │   ├── 00_context_reinforcement.md
    │   └── 01_review_commit.md
    └── CLAUDE.md                # Meta-prompt file copy
```

### Meta-Prompt File Sync

Meta-prompt files (`CLAUDE.md`, `CURSOR.md`, `AGENTS.md`, `COPILOT.md`) are automatically synchronized:

| Operation | Direction |
|-----------|-----------|
| `push` | root → .prompts/ |
| `pull` | .prompts/ → root |
| `clone` | .prompts/ → root |

This ensures meta-prompt files are version-controlled with prompts while remaining accessible at the project root.

### Registry Structure

```
registry/
├── prompts/
│   ├── index.json
│   └── <sha256>              # Pure hash, no extension
├── meta-prompts/
│   └── <sha256>              # Pure hash, no extension
└── bundles/
    └── index.json
```

Bundles reference prompts and meta-prompts by SHA-256 hash in `bundles/index.json`.

## Build from Source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
```

## License

MIT
