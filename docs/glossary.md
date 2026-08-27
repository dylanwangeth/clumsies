# Glossary

## Server

Server is the authority layer. It owns Organization Memory, Project selections
and projections, personal Bundles, Draft and Review lifecycles, identity and
authorization, and the Blob / Tree / Commit / Ref version graph.

This is the architectural center of gravity for the whole project. If a page explains clumsies as a set of local files plus some helper commands, it is missing the point.

## Memory

Memory is the single first-class content object in clumsies. Active authority
is Organization-scoped and carries a stable opaque ID, title, stable path,
required semantic `description`, Markdown `content` body, `revision`, and
`status` (`active`, `deprecated`, or `archived`). The wire/storage scope value
`project` remains only for reading and discarding historical rows.

New objects get `mem_`-prefixed IDs. Existing `ctx_` / `rul_` / `wfl_` IDs stay
stable and opaque; the migration emits an `old_id -> memory_id` map as their
identity. Identity never changes when a user renames a path.

`description` is an explicit retrieval field: it is chunked and indexed
separately by BM25 and vector search, and the reranker records its field
source.

## Rule, Workflow, and Context

Rule, Workflow, and Context were the former closed memory types. They are now
roles a Memory plays, expressed by its content and path rather than by a type
discriminator:

| Former type | Meaning as a Memory role |
| --- | --- |
| Rule | a strong behavioral constraint for an agent |
| Workflow | an ordered reusable procedure |
| Context | project or organization knowledge and evidence |

All three are Markdown-backed Memory objects in the unified model. When the
docs mean a single behavioral instruction, they should usually say `rule`, not
`prompt`. A rule tells the agent what to do; it does not tell the agent what
the project is.

## Organization authority and Project view

Organization Memory is shared across the Organization and has the sole
authority Ref and Commit history. A Project selects the Organization resources
its repository consumes and carries Organization Draft overlays that remain
visible only in that Project before merge. Its Project Ref versions this
selection projection; it is not a second authority head.

The historical UI labels were **Hub** (Organization authority) and **Local**
(Project-scoped authority). The macOS app has since merged navigation into one
Memory section. Any surviving Project-scoped resource is legacy read-only data
scheduled for the authority cutover, not an active product namespace.

## Artifact

Artifact is a retired name for the former organization-level memory manager.
The current product surface is the Memory section's organization scope
(historically called Hub). Server, not Hub, is the authority process.

## Project

Project is the repository binding, membership boundary, Organization Memory
selection, projection Ref, and carrier for private Draft overlays. It is not a
Memory authority scope or a local folder; local paths resolve to a stable
Server-issued Project ID.

`Workspace` is a retired name that may still appear in old code and legacy
documents.

## Project binding

A Project binding is daemon-owned local state that maps a canonical directory
root to one canonical Server `project_id` under a specific Server authority.
MCP resolves the nearest bound ancestor of its current working directory. The
binding is independent from the Project currently displayed by Desktop.

A legacy `ws_id` is not a Project binding. It may supply a path and display name
during one-time migration, but its identifier is never accepted as a
`project_id`.

## Project Local Storage

Project Local Storage is the current installation's daemon-owned location for
one Project's rebuildable Commit generations and derived search index. The
setting is keyed by Server authority and `project_id`; it is not Server Project
metadata, does not synchronize across installations, and is not an editable
working directory.

The selected directory is only a parent for a marker-owned `.clumsies/cache-v1`
subtree. Drafts, operation queues, cached authority objects, credentials, and
shared retrieval models remain in their central stores. If the selected volume
is unavailable, daemon does not silently use a second default cache.

## Bundle

A Bundle is a personal, Server-stored selection of shared memory resources
(a single `resource_ids` list). It helps one user reuse a curated set without
turning that selection into organization authority. A resource may exist
outside every Bundle, and the same resource may appear in multiple Bundles.

## Manifest

Manifest is a retired runtime term. Authority versions use Blob, Tree, Commit,
and Ref. The daemon materializes a validated Commit generation, overlays local
Draft operations into Effective Memory, and builds a separate derived Index
Revision for retrieval.

## Attestation

Attestation is a legacy event-stream capability. Agent observability is not part
of the current product direction or MCP memory contract. Historical client
source is preserved under `archive/zig-cli/` only.

## Adapter

Adapter is the host integration layer. It connects clumsies to coding agents
such as Codex, Claude Code, opencode, and the DeepSeek Harness by installing
the hooks, config, and runtime glue needed for the protocol to actually run.
Codex uses one App-managed user-global Plugin; repository-writing hosts use
project-scoped adapters.
Hosts consume the MCP tools directly; the former thin host-native skill layer
is retired.

Adapter is not the Server and not the MCP protocol itself. It is the layer that makes the runtime usable inside a specific host.

## MCP

MCP is the agent-facing protocol surface. It is the runtime path through which an agent activates task-relevant fragments, loads known complete resources, stores explicit Draft refinements, and drives the native Kanban.

MCP is not an authority or storage layer. The App-bundled Rust `clumsiesd mcp
serve` proxy validates the agent-facing contract and delegates Effective
Memory, retrieval, loading, Draft persistence, and Kanban operations to the
resident daemon over XPC.

The current implementation exposes four concise tools: `activate`, `load`,
`store`, and `kanban`. That is the runtime contract the docs should describe.

## Issue and Kanban

An Issue is a native, agent-managed project concern stored in the daemon
database — not a Memory object and not a GitHub Issue. The macOS board shows
five columns: Todo, In Progress, In Review, the derived Abandoned bucket (In
Progress Issues whose AgentRun claim silently died), and Done. A Paused Issue
keeps its place in In Progress with a paused badge.

Board states are `todo`, `in_progress`, `paused`, `in_review`, and `done`.
Agents transition them with explicit `kanban` operations (`begin_work`,
`pause_issue`, `resume_issue`, `unclaim`, `request_closure`); only the user's
Desktop gates (Approve, Request Changes, Reopen, Release) move authority
states. AgentRun lifecycle events never advance an Issue.

## Retrieval Run and Evaluation Case

A Retrieval Run is the daemon-local durable record of one valid memory
activation. It captures the query, Effective Memory and Index Revision
identities, all ranking-stage values, final candidate disposition, latency, and
failure details. It is not an agent-facing tool and is never Server telemetry.

An Evaluation Case pins one successful Run together with its immutable
Evaluation Corpus and versioned human judgments. The corpus is the complete
Effective Memory resource set used by that Run, not only the returned
fragments. Evaluation Cases survive unpinned history clearing and can be
exported for B1–B4 comparison.

## Draft and Review

A Draft is local in-progress work over a Memory resource and is carried by a
Project. A Review is the Server collaboration object that decides whether
those operations may move an authority Ref. The carrying Project and authority
target are separate concepts; Organization is not modeled as a Project.

Draft is local-first state. Review is shared workflow.

Every new Draft targets Organization authority. `project_id` identifies the
Project carrying its private pre-merge overlay; it does not select a Project
authority Ref. Project-scoped Drafts exist only as historical cleanup inputs.

Draft lifecycle is only `open`, `submitted`, `merged`, or `discarded`.
`behind` is freshness, not a lifecycle state; `clean` and `conflicts` describe a
reconciliation candidate and do not prevent further Draft edits.

## Sync, Reconciliation, and Rebase

Sync downloads the latest authority Commit/Ref or uploads Draft operations. It
does not change a Draft Base.

Reconciliation is Server's canonical comparison of Base, Current, and Draft
Result. It produces a candidate bound to one Draft version and one current Ref,
without modifying the Draft.

Rebase is the explicit application of a confirmed candidate. It preserves the
previous Draft revision, advances `base_commit_id` to Current, and replaces the
operations with the diff from Current to the confirmed result. Rebase never
moves an authority Ref; only Review merge does that.

## Effective Memory

Effective Memory is the daemon's local read model. It starts with the latest
installed Project projection of selected Organization Memory. A resource with
a personal Draft uses that Draft's complete `Base + operations` result; all
other resources use the projection generation. It is not a personal Ref or a
whole-Project branch pinned to an old Organization Commit.
