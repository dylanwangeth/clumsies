# Glossary

## Server

Server is the authority layer. It owns organization and project resources,
personal Bundles, Draft and Review lifecycles, identity and authorization, and
the Blob / Tree / Commit / Ref version graph.

This is the architectural center of gravity for the whole project. If a page explains clumsies as a set of local files plus some helper commands, it is missing the point.

## Rule

A rule is a behavioral instruction for an agent. It answers one question: how should the agent act?

In clumsies, behavioral memory has two domain forms:

| Type | Meaning |
| --- | --- |
| Rule | an individual constraint or policy |
| Workflow | an ordered set of constraints that implies execution flow |

When the docs mean a single behavioral instruction, they should usually say `rule`, not `prompt`.

Rule is not the same thing as project knowledge. A rule tells the agent what to do. It does not tell the agent what the project is.

## Workflow

A workflow is an ordered behavioral structure rather than a single rule. It groups multiple constraints into an execution path that implies sequence or discipline rather than one isolated instruction.

That is why a workflow belongs in the same behavioral layer as rules, but it should not be collapsed into the same concept.

## Bundle

A Bundle is a personal, Server-stored selection of memory resources. It helps
one user reuse a curated set without turning that selection into organization
authority.

## Context

Context is file-oriented knowledge. Project Context answers what a project is,
why it is shaped this way, and what is currently known. Organization Context
holds knowledge that is intentionally reusable across projects.

Specs, ADRs, research notes, and design material are all context. They give the agent evidence and background. They do not directly impose behavior.

Context does not impose behavior. Scope and resource identity determine its
authority; its file-tree presentation is not its storage identity.

## Artifact

Artifact is a retired name for the former organization-level memory manager.
The current user-facing term is **Hub**, which exposes organization-scoped
Context, Rules, and Workflows. Server, not Hub, is the authority process.

## Project

Project is the collaboration and authority boundary for project-specific
Context, Rules, and Workflows. It may also consume selected Hub resources. A
Project is not a local folder or Git repository; local paths resolve to a
stable Server-issued project ID.

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

## Manifest

Manifest is a retired runtime term. Authority versions use Blob, Tree, Commit,
and Ref. The daemon materializes a validated Commit generation, overlays local
Draft operations into Effective Memory, and builds a separate derived Index
Revision for retrieval.

## Attestation

Attestation is a legacy event-stream capability. Agent observability is not part
of the current product direction or MCP memory contract.

## Adapter

Adapter is the host integration layer. It connects clumsies to coding agents such as Codex or Claude Code by installing the hooks, config, skills, and runtime glue needed for the protocol to actually run.

Adapter is not the Server and not the MCP protocol itself. It is the layer that makes the runtime usable inside a specific host.

## MCP

MCP is the agent-facing protocol surface. It is the runtime path through which an agent activates task-relevant fragments, loads known complete resources, and stores explicit Draft refinements.

MCP is not an authority or storage layer. The Zig MCP server validates the
agent-facing contract and delegates Effective Memory, retrieval, loading, and
Draft persistence to the Rust daemon over XPC.

The current implementation exposes concise tools: `activate`, `load`, and
`store`. That is the runtime contract the docs should describe.

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

A Draft is local in-progress work over a Context, Rule, or Workflow. A Review
is the Server collaboration object that decides whether those operations may
move an organization or project Ref.

Draft is local-first state. Review is shared workflow.

For Hub content, Review targets organization authority. For Local content,
Review targets project authority. Those are related lifecycles, but they move
different Refs.

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

Effective Memory is the daemon's local read model. A resource with a personal
Draft uses that Draft's complete `Base + operations` result. Resources without a
Draft use the latest installed authority Commit. It is not a personal Ref or a
whole-project branch pinned to an old Commit.
