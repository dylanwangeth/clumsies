# clumsies

User-controlled memory for AI agents.

## Why

AI coding agents manage their own memory. Claude Code writes to `~/.claude/memory/`, Cursor stores context in its database, Copilot and Windsurf each have their own systems. They decide what to remember and what to surface in each conversation.

You can't see what they remembered. You can't remove stale context or reorganize it. When the agent behaves differently across sessions, you have no way to check what context it was actually working with.

clumsies flips this: you write the context as markdown files, organize them by meaning, and the agent reads what you put there.

## How it works

Prompts live in `.prompts/`, an independent git repo inside your working directory:

```
workspace/
├── CLAUDE.md              # MPF (tells the agent where things are)
└── .prompts/
    ├── .git/
    ├── rules/             # Coding standards, commit format, ...
    ├── cmd/               # Procedures (run on demand)
    ├── context/           # Project knowledge, architecture notes
    └── ...                # Whatever else you need
```

You write the prompt files yourself, organize them into whatever directories make sense for you, and name them however you like. clumsies doesn't enforce any layout. You register them to a registry when you want to share or reuse across projects.

The meta-prompt file (MPF) sits in the agent's working directory, which is where all coding agents look for instructions by default. It can be CLAUDE.md, AGENTS.md, COPILOT.md, or whatever your tool reads. The working directory can be a single project or a workspace containing multiple codebases. The MPF describes the `.prompts/` layout in natural language so the agent knows where to find rules, commands, and context. No special syntax, no tool integration needed.

A registry (a separate git repo) handles sharing prompts across projects.

More in [DESIGN.md](./DESIGN.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

The installer downloads the binary and verifies SHA256 before execution.

<details>
<summary>Manual install</summary>

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

## Quick start

```bash
# Point to your registry
clumsies config set registry git@github.com:org/prompt-registry.git

# Import a bundle into your project
clumsies get my-bundle

# Or clone an existing .prompts/ repo
clumsies clone git@github.com:team/shared-prompts.git
```

Run `clumsies -h` to see what else is available.

## Registry

The registry is a git repo that stores prompts and bundles:

```
registry/
├── prompts/
│   ├── index.json
│   └── <sha256>             # Content-addressed, no extension
└── bundles/
    └── index.json
```

Prompts are stored by SHA-256 hash. Same content, same hash, stored once. Bundles group prompts together for distribution.

## Build from source

Requires [Zig](https://ziglang.org/) 0.15+:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
```

## License

MIT
