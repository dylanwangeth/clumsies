# Member workflow

This page is for a human team member working inside a workspace. It is not the agent runtime page. It is not the Hub deployment page.

## What you actually do

The normal project setup flow has two commands:

```bash
clumsies login
clumsies adapt
```

`login` connects the client to Hub. `adapt` installs the selected agent
integration and, for workspace scope, can create and bind a workspace for the
current directory before installing.

After that, open the TUI whenever you want to observe the project or inspect
its context:

```bash
clumsies
```

From there, the TUI handles the normal product workflow:

1. inspect the active workspace
2. read local context and rules
3. browse shared artifact rules and bundles
4. review changes and manage workspace membership
5. check activity and runtime signals

You do not need to run `init` or `sync` for the quick start. Those commands
remain available for scripts, automation, and explicit troubleshooting.

That is the member path. The MCP server belongs to the agent runtime path, not to the normal user path.

## Step 1: log in

Run:

```bash
clumsies login --hub-url http://127.0.0.1:8400 --username admin
```

Current flags:

| Flag | Meaning |
| --- | --- |
| `--hub-url <url>` | Hub base URL. Default is `http://127.0.0.1:8400` |
| `--username <user>` | username to authenticate as |

If you omit `--username`, the CLI prompts for it.

## Step 2: adapt the project

Run:

```bash
clumsies adapt
```

The interactive flow asks which agent to adapt for and where to install
Clumsies. Choose workspace scope when this repository should carry its own
agent integration. If the current directory is not bound to a workspace,
workspace scope creates and binds one before it builds the install plan.

Use explicit flags when you already know what you want:

```bash
clumsies adapt --agent codex --scope workspace --yes
```

Current flags:

| Flag | Meaning |
| --- | --- |
| `--agent <name>` | skip adapter selection and choose a package directly |
| `--scope workspace|user` | skip scope selection |
| `--yes` | skip the final confirmation |
| `--update` | update an existing install instead of doing a fresh install flow |

## Step 3: open the TUI

Launch:

```bash
clumsies
```

Use Workspace to inspect what the current project has selected. Use Artifact
to browse the organization library and import rules into the active workspace.
Use Review to handle changes, and Settings to manage account, organization,
tokens, members, workspaces, and local path bindings.

## Explicit setup commands

`init` and `sync` are still useful when you want direct control.

```bash
clumsies init --create my-workspace
clumsies init --ws-id ws-123
clumsies sync
```

Use them for automation, recovery, or cases where you do not want the adapter
flow to create or bind the workspace.

Remove an install:

```bash
clumsies adapt --remove --agent codex --scope workspace --yes
```

Adapter setup is still a member-facing action because it configures your
machine or repo. The runtime behavior that follows belongs to the agent path,
which is documented separately.

## What to read next

If you are deploying the system rather than just using it, go to [Deployment](/guides/deploy-for-an-org).

If you are wiring an agent host into clumsies, go to [Agent runtime](/guides/agent-runtime).

If you want the command surface in one place, go to [CLI reference](/guides/cli-commands).
