# CLI reference

This page is the command surface in one place. Every command listed here is based on the current local binary help output.

## Top-level commands

| Command | Purpose |
| --- | --- |
| `clumsies` | launch the TUI |
| `clumsies login` | authenticate with Hub |
| `clumsies init` | bind the current directory to a workspace |
| `clumsies sync` | sync local cache from Hub |
| `clumsies adapt` | install or update an adapter |
| `clumsies remove-adapter` | remove an adapter |
| `clumsies mcp serve` | start the MCP server |

## login

Usage:

```bash
clumsies login [--hub-url <url>] [--username <user>]
```

| Flag | Meaning |
| --- | --- |
| `--hub-url <url>` | Hub URL. Default is `http://127.0.0.1:8400` |
| `--username <user>` | username. Prompted if omitted |

## init

Usage:

```bash
clumsies init [--create <name> | --ws-id <id>] [--bundle <bundle_id>]
```

| Flag | Meaning |
| --- | --- |
| `--create <name>` | create a new workspace |
| `--ws-id <id>` | bind to an existing workspace |
| `--bundle <bundle_id>` | attach a bundle while creating |

## sync

Usage:

```bash
clumsies sync
```

This syncs workspace rules and context files from Hub into the local cache.

## adapt

Usage:

```bash
clumsies adapt [--agent <name>] [--scope workspace|user] [--update] [--yes]
```

This command supports both interactive and explicit use.

Interactive:

```bash
clumsies adapt
```

Explicit:

```bash
clumsies adapt --agent codex --scope workspace --yes
```

| Flag | Meaning |
| --- | --- |
| `--agent <name>` | adapter package name such as `codex` or `claude-code` |
| `--scope workspace|user` | install scope |
| `--update` | update an existing install |
| `--yes` | skip confirmation |

If multiple adapter packages are available, omitting `--agent` leaves package selection to the interactive flow.

## remove-adapter

Usage:

```bash
clumsies remove-adapter [--agent <name>] [--scope workspace|user] [--yes]
```

| Flag | Meaning |
| --- | --- |
| `--agent <name>` | adapter package to remove |
| `--scope workspace|user` | scope to remove from |
| `--yes` | skip confirmation |

## mcp serve

Usage:

```bash
clumsies mcp serve
```

This starts the MCP stdio server for the current workspace. It is the entrypoint agent hosts use, not a normal member command.
