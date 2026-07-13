# Overview

Clumsies is external memory infrastructure for coding agents. It keeps durable
Context, Rules, Workflows, and Metaprompt outside one model conversation, makes
the relevant subset available to an agent, and turns changes into reviewable
drafts instead of invisible local edits.

## Memory model

Memory is a product concept, not one database table.

| Type | Meaning |
| --- | --- |
| Context | file-oriented project or organization knowledge |
| Rule | structured strong constraints |
| Workflow | ordered operational behavior with its own lifecycle |
| Metaprompt | bootstrap instructions used to enter the memory loop |
| Bundle | a personal selection of shared memory resources |

Organization resources are general and shared. Projects may consume selected
organization resources and own independent Context, Rules, Workflows, and
Metaprompt.

## Product surfaces

| Surface | Role |
| --- | --- |
| Desktop | primary human product for browsing, editing, reviewing, and merging memory |
| daemon | always-on local runtime for drafts, sync, native transport, and client coordination |
| Server | self-hosted authority service backed by PostgreSQL |
| MCP | agent-facing `activate`, `retrieve`, and `store` interface |
| CLI | optional command-line client for useful product operations |
| Web Admin | organization, member, project, token, audit, and health administration |

In Desktop, **Hub** means organization-scoped shared memory. **Local** means the
selected project's resources and local drafts. Server is the process name; Hub
is not a second backend.

## Memory lifecycle

```text
task cue
  -> activate candidates
  -> retrieve selected memory
  -> use it in working context
  -> store a local draft
  -> daemon synchronizes the draft
  -> review and merge
  -> new Commit advances the target Ref
```

`store` never edits authoritative memory. Desktop and MCP both write to daemon,
and daemon automatically sends queued operations to Server. Only an approved
merge creates the next authority Commit.

## Version model

Clumsies uses Git terminology for Git-equivalent concepts:

- Blob: immutable resource content
- Tree: the indexed resource set for a version
- Commit: an immutable authority version with a parent
- Ref: the movable organization or project head

HTTP `ETag` and `If-Match` protect Ref updates. They do not replace Commit
history. A draft records `base_commit_id`; a merge is rejected if the target Ref
has moved.

## Current implementation boundary

The Rust Server, generic organization OIDC, complete Public/Admin contracts,
Desktop transport, local draft queue, refresh-token retry, and reviewed Commit
creation are implemented and covered by real PostgreSQL integration tests.

Authoritative Commit download/materialization into the local MCP read cache is
not implemented yet. The daemon currently synchronizes drafts upward; its
`commit_sync` channel is a truthful idle placeholder until that path is built.
