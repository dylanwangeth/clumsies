# Project

`Project` is the current product term for a repository-scoped memory and
authorization boundary. This page keeps its historical `/workspace` URL so old
links continue to resolve, but active APIs and runtime state use `project_id`.

## Identity and local binding

Server issues the canonical Project identity. A local directory is only an
installation-local binding to that identity:

```text
normalized Server authority
  + canonical workspace root
  -> canonical project_id
```

The resident daemon stores bindings in central SQLite. It canonicalizes a
caller's current directory and chooses the longest bound ancestor, so nested
worktrees resolve to the intended Project without treating the folder name as
identity. An unbound directory returns an explicit binding error.

The Desktop-selected Project is UI state and is deliberately separate. Two MCP
proxies can resolve two different repositories concurrently while Desktop is
closed or showing a third Project.

Legacy `ws_id` configuration is only a one-time migration input. It is never
sent to daemon as a Project identity and is not a runtime fallback.

## Memory scope

Projects own repository-specific Memory. Organization memory remains under the
independent organization scope (historically the Hub view). Each scope has its
own Ref and immutable Commit history; merging one scope never advances the
other. A Memory's role — rule, workflow, or context — is carried by its content
and path, not by a closed type.

Bundles are personal selections of shared organization memory. They help a
member reuse a curated set but do not become Project identity or replace the
organization Ref. A Bundle holds a single `resource_ids` list; membership never
changes resource identity.

## Local state

The resident daemon owns the Project's installation-local state:

- directory binding and selected Server authority;
- installed organization and Project Refs;
- immutable Commit generations;
- current local Drafts and their queued operations;
- the derived search index for the current Effective Memory;
- optional Project Local Storage location and move status;
- adapter installation records for the repository.

Server remains authoritative for Project membership, memory history, Reviews,
and merges. A local binding or cache never creates authority.

## Effective Memory

For Agent reads, daemon composes the latest installed authority generations
with the Project's current open/submitted Draft operations:

```text
organization Commit + Project Commit + local Draft overlay
  -> Effective Memory hash
  -> matching derived Index Revision
  -> activate / load
```

`store` writes a durable local Project Draft through daemon. It does not update
the authority Ref. Desktop shows the same Draft for coordination, Review, and
merge.

## Project Local Storage

A Project may choose where this installation stores rebuildable generations
and its search database. The setting is keyed by Server authority and
`project_id`, remains local to the machine, and never enters Server Project
metadata.

The selected directory is only a parent for a marker-owned managed subtree.
Central Drafts, operation queues, credentials, cached authority objects, and
shared models do not move. If a custom location is unavailable, daemon reports
the condition explicitly and does not create a second active cache elsewhere.

See [Runtime](/runtime) for migration and recovery semantics.

## Agent runtime path

The adapter starts the App-bundled `clumsiesd mcp serve` proxy from the
repository. At startup the proxy verifies the resident daemon release identity,
resolves the current directory through the binding registry, and fixes that
canonical `project_id` for the process. Agent input cannot select another
Project or reuse Desktop's current selection.
