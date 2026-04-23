# META_PROMPT

`META_PROMPT.md` is the workspace-scoped bootstrap document that tells an agent how to participate in the clumsies runtime protocol.

It is not a normal rule. It is not a workflow. It is the session-start frame that explains how an agent should discover constraints, load them, and declare what was actually applied.

## Where it lives

In the current implementation, the synced file lives at:

```text
~/.clumsies/workspaces/{ws_id}/cache/META_PROMPT.md
```

That path matters because the file is part of the workspace cache, not a random repo-local convention. When `sync` refreshes the workspace snapshot, `META_PROMPT.md` is refreshed with it.

## What job it does

The current file establishes four ideas.

First, rules and workflows are not supposed to be discovered by crawling local files. The agent is supposed to use `memory.search` and `memory.load`.

Second, applying a constraint is not silent. The agent is supposed to call `memory.refer` when a loaded constraint actually shaped the turn.

Third, the adapter owns part of the protocol lifecycle. Session bootstrap and stop-time reminders are injected by the installed host adapter rather than being left to the model to remember ad hoc.

Fourth, the file defines the priority order between `PIN.md`, loaded constraints, `META_PROMPT.md`, and the model's default behavior.

## Current workspace copy

The current workspace copy reads:

```md
# clumsies

This workspace uses [clumsies](https://github.com/lilhammerfun/clumsies/blob/main/README.md)
to manage rules and context for AI agents. These coexist with your own memory,
but take priority when they conflict.

## Protocol

Follow this loop every turn:

1. **Discover.** Call `memory.search()` to list all available rules,
   workflows, and context. Read their descriptions to decide what is relevant.
2. **Load.** Call `memory.load()` with the ids you need. Loaded content includes
   parsed rule ids.
3. **Apply.** Follow loaded rules in your work. Rules override your defaults.
4. **Refer.** Call `memory.refer()` for each rule you applied. This is
   not optional — it is how the system measures rule effectiveness.
5. **Refine.** When the user asks you to create, update, or delete rules or
   context, use `context.propose_create()`, `context.propose_update()`,
   `context.propose_rename()`, `context.propose_delete()` for workspace context,
   and `prompt.propose_create()`, `prompt.propose_update()`,
   `prompt.propose_rename()`, `prompt.propose_delete()` for library rules.
6. **Submit.** Call `memory.submit()` with a short summary of your work before
   finishing every response. The stop hook will block if you forget.

## Resource types

- **rule** (`<category>/<name>.md`) — rules to follow in your work.
- **workflow** (`workflow/<name>.md`) — ordered procedures, exposed as
  slash commands by the adapter.
- **context** — workspace-scoped reference material (design docs, research,
  specs).

Categories are organizational only (e.g. `coding/`, `zig/`, `writing/`).

Filter with `memory.search({kind: "rule"})` or `memory.search({group: "zig"})`.

## Priority

Loaded rules > this meta-prompt > your defaults.

When a rule conflicts with your training, follow the rule.
```

## What in that file is stable today

Most of the file still matches the current product model:

- `META_PROMPT.md` is still a reserved workspace cache asset
- the agent-facing loop is now explicit: discover, load, apply, refer, refine, submit
- the file now describes the protocol in terms of `rule`, `workflow`, and `context`
- loaded rules still outrank model defaults

## What in that file is lagging behind the current implementation

The docs should not pretend every line above is still the live protocol surface.

One part is still ahead of the currently implemented public tool names:

| In the current file | Current implementation |
| --- | --- |
| `prompt.propose_*` for Library rule refinement | current public MCP tool surface still exposes `rule.propose_*` |

So the right way to read `META_PROMPT.md` today is as the current session bootstrap contract, with one notable naming mismatch on library proposal tools.

## Where the protocol now lives in the docs

`META_PROMPT.md` is the bootstrap artifact. It should not be the only place the protocol is explained.

For the current public contract, read:

- [MCP](/mcp) for the `memory.*` tool surface
- [Runtime surfaces](/runtime) for the local file and cache model
- [Agent runtime](/guides/agent-runtime) for the host-side execution path
