# clumsies

## What is this?

A scaffolding tool for AI Agent prompts systems.

We found that a single prompts file isn't enough for complex projects. So we created a multi-file system: a **meta-prompt file** (`CLAUDE.md`, `CURSOR.md`, or `GEMINI.md`) that tells the AI how to understand and extend the prompts, plus a `.prompts/` directory with all the actual rules.

We call this complete package a **template**. Instead of copying these files everywhere, use clumsies to manage them.

## Install

### Quick Install (with checksum verification)

```bash
curl -fsSL https://raw.githubusercontent.com/dylanwangeth/clumsies/main/install.sh | sh
```

The installer downloads both the binary and `checksums.txt`, verifying SHA256 before execution.

### Manual Install (verify yourself)

```bash
# Download binary and checksums
curl -LO https://github.com/dylanwangeth/clumsies/releases/latest/download/clumsies-darwin-arm64
curl -LO https://github.com/dylanwangeth/clumsies/releases/latest/download/checksums.txt

# Verify checksum
shasum -a 256 -c checksums.txt --ignore-missing

# Install
chmod +x clumsies-darwin-arm64
mv clumsies-darwin-arm64 ~/.clumsies/bin/clumsies
```

Replace `darwin-arm64` with your platform: `darwin-x86_64`, `linux-arm64`, or `linux-x86_64`.

## Usage

```bash
# Search available templates
clumsies search

# Preview a template's meta-prompt file
clumsies detail solocc
clumsies detail solocc --lang zh

# Apply a template to current directory
clumsies use solocc
clumsies use solocc --lang zh
clumsies use solocc --name CURSOR.md     # Use CURSOR.md instead of CLAUDE.md
clumsies use solocc --force              # Overwrite existing files

# Install community templates
clumsies install react-agent
clumsies install --list                  # List installed templates
```

## What's in a Template?

```
your-project/
├── CLAUDE.md                    # Meta-prompt file: tells AI how to understand the system
└── .prompts/
    ├── conduct/                 # Development standards
    │   ├── CODE_COMMENTS.md
    │   ├── GIT_COMMIT.md
    │   └── ...
    └── command/                 # Executable commands
        ├── 00_CONTEXT_REINFORCEMENT.md
        └── 01_REVIEW_COMMIT.md
```

## Extending

After applying a template, add directories based on your needs:

- `.prompts/biz/` — Business context
- `.prompts/tech/` — Technical documentation

The AI will understand them automatically because the meta-prompt file defines the rules.

## Build from Source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
git clone https://github.com/dylanwangeth/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
```

## License

MIT
