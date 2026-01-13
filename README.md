# clumsies

A CLI tool for managing AI Agent prompt systems based on [Clumsies Protocol](./PROTOCOL.md).

## Why?

A single prompt file isn't enough for complex projects. We created a multi-file system:
- **Meta-prompt file** (`CLAUDE.md`, `CURSOR.md`, etc.) — tells the AI how to understand the prompt system
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

# Create bundle from local directories
clumsies bundle create <name> <dirs...> [-t <task>] [-d <desc>] [-M <file>]
clumsies bundle create my-bundle ./conduct ./command -t coding -d "My coding bundle"
clumsies bundle create my-bundle ./conduct ./command -M CLAUDE.md  # Specify meta-prompt file

# Update bundle contents
clumsies bundle update <name> --add <files...>
clumsies bundle update <name> --rm <files...>

# Remove bundle
clumsies bundle rm <name>
```

### Prompt Commands (manage prompts in registry)

```bash
# List and show prompts
clumsies prompt list
clumsies prompt show <hash>

# Create prompt from file
clumsies prompt create <file>

# Import prompt to local .prompts/
clumsies prompt import <hash>

# Remove prompt
clumsies prompt rm <hash>
```

### Configuration

```bash
clumsies config set registry <url>           # Set registry URL
clumsies config set meta_prompt_file <file>  # Set default meta-prompt file for bundle create
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
    │   ├── CODE_COMMENTS.md
    │   ├── GIT_COMMIT.md
    │   └── ...
    ├── command/                 # Executable commands (invoke by name)
    │   ├── 00_CONTEXT_REINFORCEMENT.md
    │   └── 01_REVIEW_COMMIT.md
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
│   └── <sha256>.md
├── meta-prompts/
│   └── <sha256>.md
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
