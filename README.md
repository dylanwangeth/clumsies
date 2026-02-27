# clumsies

A semantic layer for AI agent prompts.

## Why

Prompts break once projects grow. We keep writing good ones, but they end up as loose text with no structure — hard to reuse, hard to share, hard to move between tools.

At some point we noticed: prompts already form a semantic layer. We just never named it.

Some prompts behave like rules (always active), others are more like procedures (invoke on demand). We found it useful to sort them by what they *mean*:

- **conduct/** — behavioral rules, always in effect
- **command/** — executable procedures, invoked by name or number
- **context/** — project knowledge, loaded as needed (local only)

The `.prompts/` directory is its own git repo. A meta-prompt file (CLAUDE.md, etc.) acts as a natural language index pointing AI into this structure.

Different developers and stages of work need different slices of the prompt system. The registry preserves that structure across projects.

More in [DESIGN.md](./DESIGN.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

The installer downloads the binary and verifies SHA256 before execution.

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

## Quick Start

```bash
# Point to your registry
clumsies config set registry git@github.com:org/prompt-registry.git

# Import a bundle into your project
clumsies get my-bundle

# Or clone an existing .prompts/ repo
clumsies clone git@github.com:team/shared-prompts.git
```

Run `clumsies -h` to see what else is available.

## Architecture

```
project/
├── CLAUDE.md                    # Meta-prompt (natural language index)
└── .prompts/                    # Independent git repo
    ├── .git/
    ├── conduct/                 # Rules (always active)
    │   ├── coding/
    │   ├── git/
    │   └── writing/
    └── command/                 # Procedures (invoke by name)
        ├── 00_context_reinforcement.md
        └── 01_review_commit.md
```

The registry is a separate git repo storing prompts and bundles:

```
registry/
├── prompts/
│   ├── index.json
│   └── <sha256>                 # Content-addressed, no extension
├── meta-prompts/
│   └── <sha256>
└── bundles/
    └── index.json
```

## Build from Source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
```

## License

MIT
