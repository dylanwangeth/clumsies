# Overview

Clumsies is external memory infrastructure for coding agents. It keeps durable
Memory outside one model conversation, makes the relevant subset available to
an agent, and turns changes into reviewable drafts instead of invisible local
edits.

## Memory model

Memory is the single first-class content object. The former closed Context /
Rule / Workflow types are unified into it: whether a Memory reads as a "rule",
a "workflow", or project "context" is expressed by its content and path, not by
a type discriminator.

| Concept | Meaning |
| --- | --- |
| Memory | Markdown-backed content with stable `id`, `scope`, `title`, `path`, `description`, `content`, `revision`, and `status` |
| Organization scope | shared memory with its own Ref and immutable Commit history |
| Project scope | repository-scoped memory; projects may consume selected organization resources |
| Bundle | a personal selection of shared memory resources (`resource_ids`) |
| Issue | a native agent-managed Kanban object, distinct from Memory |

New Memory objects receive `mem_`-prefixed IDs. Legacy `ctx_` / `rul_` / `wfl_`
IDs remain stable and opaque; they are never rewritten. `description` is a
required, agent-generated semantic summary on create and an explicit retrieval
field, chunked and indexed separately from `content`.

## Product surfaces

| Surface | Role |
| --- | --- |
| Desktop | primary human product for browsing, editing, reviewing, and merging memory; the unified Memory section shows organization and project memory with a scope filter |
| resident `clumsiesd` | always-on Rust runtime for drafts, sync, retrieval, native transport, and client coordination |
| Agent runtime | short-lived `clumsiesd mcp serve` and `_agent` proxies used by supported hosts |
| Server | self-hosted authority service backed by PostgreSQL |
| MCP | agent-facing `activate`, `load`, `store`, and `kanban` interface |
| Web Admin | organization, member, project, token, audit, and health administration |

Organization memory (historically the Hub view) and project memory
(historically Local) are the two scopes of one Memory model. Server is the
process name; neither scope is a second backend.

## Memory lifecycle

```text
task cue
  -> activate ranked fragments
  -> optionally load a known complete resource
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

The unified Memory model (Server, daemon, OpenAPI, MCP, macOS), the
organization/project memory endpoints (`/api/v1/org/memories` and
`/api/v1/projects/{project_id}/memories`), description-aware retrieval, the
org-admin `memory-export` migration endpoint, generic organization OIDC,
complete Public/Admin contracts, Desktop transport, local draft queue,
refresh-token retry, macOS Keychain credential storage, reviewed Commit
creation, daemon Commit synchronization, user-resolvable stale conflicts, and
atomic MCP authority generations are implemented. Real PostgreSQL tests cover
merge-to-Commit, two-daemon convergence, restart recovery, and failure without
Ref advancement.

The resident daemon composes the installed Commit generation with current local
Draft operations into one Effective Memory view. It derives Markdown retrieval
units, SQLite FTS5 BM25 rows, local dense vectors, RRF fusion, cross-encoder
reranking, and activation delta state from that view. The App-bundled Rust
`clumsiesd mcp serve` process is a thin stdio-to-XPC adapter for `activate`,
`load`, `store`, and `kanban`; it owns no database, model, or background worker.
The private `_agent issue-run-event` mode applies the same boundary to lifecycle
Hooks.

Automatic three-way conflict resolution, the versioned production retrieval
query set, and the production installation lifecycle remain incomplete.
