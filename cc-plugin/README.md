# clumsies Claude Code Plugin

Claude Code plugin for [clumsies](https://github.com/lilhammerfun/clumsies) — user-level memory for AI agents.

This plugin bridges the gap between MCP tools (which agents may forget to call) and reliable protocol execution through hooks and skills.

## Prerequisites

[clumsies CLI](https://github.com/lilhammerfun/clumsies) must be installed and in PATH.

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

Your project needs a `.prompts/` directory. The plugin is silent when `.prompts/` is absent.

## What it does

### Hooks (automatic)

**SessionStart**: Loads `.prompts/META_PROMPT.md` (protocol bootstrap), creates or resumes a task, and generates slash commands for each workflow file found in `.prompts/workflow/`.

**Stop**: Reminds the agent to declare constraint references via `memory.refer` before finishing.

### Skills (user-invoked)

| Command | Description |
|---------|-------------|
| `/complete-task` | Mark the current task as completed |
| `/complete-task --abandon` | Mark as abandoned |
| `/stats` | Show prompt usage statistics |
| `/search` | Discover available prompts |

Workflow files in `.prompts/workflow/` are auto-generated as skills on session start. For example, `.prompts/workflow/cmd/00_GEN_COMMIT_MSG.md` becomes `/gen-commit-msg`. All workflow skills accept arguments — pass a task description to use the workflow as a methodology.

### MCP Server

The plugin bundles the clumsies MCP server (`clumsies mcp serve`), giving the agent structured access to search, load, and refer constraints.

## Install

Local development:

```bash
claude --plugin-dir ./cc-plugin
```

## Project structure

```
cc-plugin/
├── .claude-plugin/plugin.json   # Plugin manifest
├── hooks/hooks.json             # Hook configuration
├── skills/                      # Static skills (complete, stats, search)
├── scripts/                     # Hook scripts
├── .mcp.json                    # MCP server config
└── README.md
```
