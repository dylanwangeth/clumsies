# clumsies

A CLI tool for managing AI Agent prompt systems based on [Clumsies Protocol](./PROTOCOL.md).

## Why?

A single prompt file isn't enough for complex projects. We created a multi-file system:
- **Meta-prompt file** (`CLAUDE.md`, `CURSOR.md`, etc.) — a natural language index that guides AI to navigate the `.prompts/` directory. It explains what each directory contains and when to load which prompts.
- **`.prompts/` directory** — modular prompts organized by type (conduct, command, custom)

We call this complete package a **bundle**. The `.prompts/` directory operates as an **independent git repository**, enabling version control and team collaboration.

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

### Main Commands (manage .prompts/)

```bash
# Initialize .prompts/ and link to your remote repository
clumsies init git@github.com:user/my-prompts.git

# Or clone existing prompts
clumsies clone git@github.com:team/shared-prompts.git

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

# Register bundle from meta-prompt file and directories
# Bundle name comes from frontmatter in meta-prompt file
clumsies bundle register <meta-prompt-file> <dirs...>
clumsies bundle register CLAUDE.md ./conduct ./command

# Update bundle contents
clumsies bundle update <name> --add <files...>
clumsies bundle update <name> --rm <hash...>

# Remove bundle
clumsies bundle rm <name>
```

### Prompt Commands (manage prompts in registry)

```bash
# List and show prompts
clumsies prompt list
clumsies prompt show <hash>

# Register prompt to registry
clumsies prompt register <file>

# Import prompt to local .prompts/
clumsies prompt import <hash>

# Remove prompt
clumsies prompt rm <hash>
```

### Configuration

```bash
clumsies config set registry <url>           # Set registry URL
clumsies config set meta_prompt_file <file>  # Set default meta-prompt file for bundle register
clumsies config get registry                 # Get registry URL
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
    │   ├── 00_code_comments.md
    │   ├── 01_git_commit.md
    │   └── ...
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
