# clumsies

A CLI tool for managing AI Agent prompt systems based on [Clumsies Protocol](./PROTOCOL.md).

## Why?

A single prompt file isn't enough for complex projects. We created a multi-file system:
- **Entry file** (`CLAUDE.md`, `CURSOR.md`, etc.) — tells the AI how to understand the prompt system
- **`.prompts/` directory** — modular prompts organized by type (conduct, command, custom)

We call this complete package a **template**. Instead of copying files everywhere, use clumsies to manage them.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dylanwangeth/clumsies/main/install.sh | sh
```

The installer downloads the binary and verifies SHA256 checksum before execution.

<details>
<summary>Manual Install</summary>

```bash
# Download binary and checksums
curl -LO https://github.com/dylanwangeth/clumsies/releases/latest/download/clumsies-darwin-arm64
curl -LO https://github.com/dylanwangeth/clumsies/releases/latest/download/checksums.txt

# Verify and install
shasum -a 256 -c checksums.txt --ignore-missing
chmod +x clumsies-darwin-arm64
mkdir -p ~/.clumsies/bin
mv clumsies-darwin-arm64 ~/.clumsies/bin/clumsies
```

Platforms: `darwin-arm64`, `darwin-x86_64`, `linux-arm64`, `linux-x86_64`
</details>

## Usage

```bash
# Search templates
clumsies search                    # List all templates
clumsies search solo               # Search by keyword

# Search prompts (by type)
clumsies search --command          # List command prompts
clumsies search --conduct          # List conduct prompts
clumsies search --conduct --lang zh

# Preview a template
clumsies detail solocc
clumsies detail solocc --lang zh

# Install a template locally
clumsies install solocc
clumsies install --list            # List installed templates

# Apply a template to current project
clumsies use solocc
clumsies use solocc --lang zh
clumsies use solocc --name CURSOR.md
clumsies use solocc --force        # Overwrite existing files

# Configure defaults
clumsies config set lang zh        # Set default language
clumsies config list               # Show all config

# Upgrade clumsies
clumsies upgrade
```

Language codes follow ISO 639-1 standard (e.g., `en`, `zh`, `ja`, `ko`).

## What's in a Template?

```
your-project/
├── CLAUDE.md                    # Entry file
└── .prompts/
    ├── conduct/                 # Behavioral rules (always active)
    │   ├── CODE_COMMENTS.md
    │   ├── GIT_COMMIT.md
    │   └── ...
    └── command/                 # Executable commands (invoke by name)
        ├── 00_CONTEXT_REINFORCEMENT.md
        └── 01_REVIEW_COMMIT.md
```

After applying, extend with your own directories:
- `.prompts/biz/` — Business context
- `.prompts/tech/` — Technical documentation

## Build from Source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
git clone https://github.com/dylanwangeth/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
```

## License

MIT
