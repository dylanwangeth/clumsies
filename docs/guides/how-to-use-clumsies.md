# Member workflow

This page is for a human team member working inside a workspace. It is not the agent runtime page. It is not the Hub deployment page.

## What you actually do

A normal member flow looks like this:

1. log in to the Hub
2. bind the current directory to a workspace
3. sync the local cache
4. use the CLI for explicit actions
5. open the TUI when you need a denser view of state

That is the member path. The MCP server belongs to the agent runtime path, not to the normal user path.

## Step 1: log in

Use `login` to authenticate against the Hub:

```bash
clumsies login --hub-url http://127.0.0.1:8400 --username admin
```

Current flags:

| Flag | Meaning |
| --- | --- |
| `--hub-url <url>` | Hub base URL. Default is `http://127.0.0.1:8400` |
| `--username <user>` | username to authenticate as |

If you omit `--username`, the CLI prompts for it.

## Step 2: bind the repo to a workspace

Use `init` in the repo directory you want to bind.

Create a new workspace:

```bash
clumsies init --create my-workspace
```

Bind to an existing one:

```bash
clumsies init --ws-id ws-123
```

Create and attach a bundle at the same time:

```bash
clumsies init --create my-workspace --bundle bundle-123
```

Current flags:

| Flag | Meaning |
| --- | --- |
| `--create <name>` | create a new workspace with this name |
| `--ws-id <id>` | bind to an existing workspace |
| `--bundle <bundle_id>` | associate a bundle during create |

## Step 3: sync local state

Once the directory is bound, sync the local cache:

```bash
clumsies sync
```

This pulls workspace rules and context into the local runtime cache. It is the step that makes the workspace usable by local tools.

## Step 4: choose the right surface

Use the CLI when the job is explicit and short-lived.

Use the TUI when the job is state-heavy. That usually means browsing the Artifact, inspecting Workspace status, reading a denser analysis view, or staying inside review work longer than one command at a time.

Launch the TUI with:

```bash
clumsies
```

## Step 5: install adapters when you need host integration

If you want a supported agent host to pick up clumsies-managed runtime behavior, install an adapter.

The most flexible way is the interactive flow:

```bash
clumsies adapt
```

When multiple adapter packages are available, the CLI lets you choose interactively. If scope is not provided, the install flow can also guide you through that choice.

Use explicit flags when you already know what you want.

Workspace-scoped install:

```bash
clumsies adapt --agent codex --scope workspace --yes
```

User-scoped install:

```bash
clumsies adapt --agent claude-code --scope user --yes
```

Remove an install:

```bash
clumsies remove-adapter --agent codex --scope workspace --yes
```

The relevant flags are:

| Flag | Meaning |
| --- | --- |
| `--agent <name>` | skip adapter selection and choose a package directly |
| `--scope workspace|user` | skip scope selection |
| `--yes` | skip the final confirmation |
| `--update` | update an existing install instead of doing a fresh install flow |

This is still a member-facing action because it is about configuring your machine or repo. The runtime behavior that follows belongs to the agent path, which is documented separately.

## What to read next

If you are deploying the system rather than just using it, go to [Deployment](/guides/deploy-for-an-org).

If you are wiring an agent host into clumsies, go to [Agent runtime](/guides/agent-runtime).

If you want the command surface in one place, go to [CLI reference](/guides/cli-commands).
