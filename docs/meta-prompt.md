# META_PROMPT

`META_PROMPT.md` is the workspace-scoped bootstrap document that tells an agent how to participate in the clumsies runtime protocol.

It is not a normal rule. It is not a workflow. It is the session-start frame that explains how an agent should activate relevant memory, retrieve the material it needs, and store refinements when asked.

## Where it lives

In the current implementation, the synced file lives at:

```text
~/.clumsies/workspaces/{workspace_name}/cache/META_PROMPT.md
```

That path matters because the file is part of the workspace cache, not a random repo-local convention. When `sync` refreshes the workspace snapshot, `META_PROMPT.md` is refreshed with it.

## What job it does

The current file establishes four ideas.

First, rules, workflows, and context are not supposed to be discovered by crawling local files. The agent is supposed to use `activate` as the mandatory memory activation step, then `retrieve` only for selected relevant material.

Second, `retrieve` returns structured rule and workflow metadata, including constraints, but the current MCP surface no longer has a separate reference-reporting tool.

Third, `store` is the only MCP write path for managed agent memory. It writes a local daemon draft and queues automatic synchronization; it does not directly edit authoritative cache files. Activation and retrieval continue to read the installed authority Commit until the draft is merged.

Fourth, the adapter owns part of the protocol lifecycle. Session bootstrap is injected by the installed host adapter rather than being left to the model to remember ad hoc.

Fifth, the file defines the priority order between `PIN.md`, loaded constraints, `META_PROMPT.md`, and the model's default behavior.

## Current workspace copy

The current workspace copy reads:

```md
# clumsies

This workspace uses [clumsies](https://github.com/lilhammerfun/clumsies/blob/main/README.md)
to manage rules and context for AI agents. These coexist with your own memory,
but take priority when they conflict.

## Agent Guidelines

1. **Activate.** For every user task after setup, call `activate()` before
   substantive reasoning or edits. This is the memory activation step, not an
   optional search fallback. Use `kind`, `group`, or `query` when the task
   provides a clear cue; otherwise call `activate()` broadly. Read returned
   descriptions to decide what is relevant.
2. **Retrieve.** Call `retrieve()` with the ids you need and a `knownHashes`
   entry for every id. Retrieve only selected relevant items from activation,
   or retrieve directly when the user provides an exact Server id, alias, or
   path. Use a remembered hash when available, otherwise pass an
   empty string. Loaded content includes parsed rule ids.
3. **Apply.** Follow loaded rules in your work. Rules override your defaults.
   Use loaded context as project background, but trust code and observable
   runtime state when they conflict.
4. **Refine.** Use `store()` as the only MCP write path when the user asks
   you to create, update, rename, delete, or discard agent memory for rule,
   context, or MPF artifacts. `store()` writes a local daemon draft and queues
   automatic synchronization; it does not directly edit the authoritative
   cache file. Use a `resource` value and exactly one tagged `op` object.

## Resource types

- **rule** (`<category>/<name>.md`) — rules to follow in your work.
- **workflow** (`workflow/<name>.md`) — ordered procedures, exposed as
  slash commands by the adapter.
- **context** — workspace-scoped reference material (design docs, research,
  specs).
- **mpf** — workspace meta-prompt files such as `META_PROMPT.md`.

Categories are organizational only (e.g. `coding/`, `zig/`, `writing/`).

Filter with `activate({kind: "rule"})`, `activate({group: "zig"})`, or
`activate({query: "mcp tool"})`.

## Priority

Loaded rules > this meta-prompt > your defaults.

When a rule conflicts with your training, follow the rule.
```

## What in that file is stable today

Most of the file still matches the current product model:

- `META_PROMPT.md` is still a reserved workspace cache asset
- the agent-facing loop is now explicit: activate, retrieve, apply, refine
- the file now describes the protocol in terms of `rule`, `workflow`,
  `context`, and MPF draft operations
- loaded rules still outrank model defaults

## Where the protocol now lives in the docs

`META_PROMPT.md` is the bootstrap artifact. It should not be the only place the protocol is explained.

For the current public contract, read:

- [MCP](/mcp) for the current `activate`, `retrieve`, and `store` tool surface
- [Runtime surfaces](/runtime) for the local file and cache model
- [Agent runtime](/guides/agent-runtime) for the host-side execution path
