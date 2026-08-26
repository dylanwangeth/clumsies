# Unified Memory Model

Date: 2026-08-15 · Status: implemented in code (native ISSUE-012 in review)

This document is the implementation blueprint for ISSUE-012: replacing the
closed Rule / Workflow / Context types with one unified Memory object across
Server, daemon, OpenAPI, MCP, macOS, and the Agent Adapter. The Server, daemon,
API contract, MCP, and macOS unification commits landed on 2026-08-15; this
page is the design and migration record for that change. It is a destructive
refactor: existing data is protected and migrated, while the old
three-type write contracts are not preserved for the long term.

> Authority update (2026-08-26): Organization is now the only active Memory
> authority. Projects select Organization Memory, own a projection Ref, and
> carry Organization-scoped Draft overlays. References to Project-scoped
> authority below describe the ISSUE-012 historical schema; they are retained
> only as migration context. See [Project authority cutover](/project-authority-migration).

## Core object

A Memory is the only first-class content object. No Category/Tag is
introduced in this phase; `title`, `description` and `content` are the
primary semantic surface an Agent can understand.

```text
Memory {
  id: string            // stable opaque ID, e.g. mem_... (see ID policy)
  scope: org            // project is historical read/cleanup compatibility
  title: string
  path: string          // stable path within org or project namespace
  description: string   // required on create, optional on update
  content: string       // Markdown body
  content_format: string // e.g. "markdown"
  revision: int
  status: active | deprecated | archived
  provenance: string    // org | project | selected_org | bootstrap | config
  created_at, updated_at
}
```

### ID policy

- Existing `ctx_` / `rul_` / `wfl_` IDs stay stable and opaque; they are not
  rewritten. The migration emits an `old_id -> memory_id` map that is the
  identity for those IDs.
- New objects are created with `mem_` prefixed IDs.
- Identity never changes when a user renames a category or a path.

### Description

- `description` is a required, agent-generated semantic summary on create.
- Updates may change `description`; concurrent overwrite is prevented with
  `revision` / `content_hash` (If-Match semantics) exactly like content.
- `description` is an explicit retrieval field: it is chunked and indexed
  separately by BM25 and vector search, and the reranker records its field
  source. A test proves the retrieval chain consumes the field rather than
  merely echoing it back.

## What is deleted

- `ResourceKind` / `DraftResourceKind` / `TreeEntryKind` closed enums and all
  long-term compatibility branches for the old three types.
- Type-specific endpoints (`/rules`, `/context`, `/workflows` lists and gets).
- The three ID groups on `ProjectOrgSelection` (`rule_ids`, `context_ids`,
  `workflow_ids`) and `PersonalBundle`; both become a single `resource_ids`
  list.
- Type-specific materialization directories (`cache/context/`,
  `cache/rule/`); one unified materialization layout is used.
- `ContextKind` (file/note/decision/reference) and `workflow_steps`.
- The kind double-check between Draft identity and Draft content.

## What is retained

- Organization authority and per-Project Draft-overlay isolation.
- Draft / Review / Commit lifecycle (drafts still belong to a project).
- Commit and Ref mechanics; the Organization Ref is authoritative and each
  Project Ref is a selected-memory projection.
- Authority and provenance: `provenance`, `status` and `scope` remain system
  fields and are never inferred from `description` text or user naming.
- Content format detection for Markdown preview (via `content_format`, not
  via the deleted kind).
- Unified RAG: all Memory enters one retrieval corpus; the algorithms
  (BM25, dense, RRF, reranker, budget) are unchanged.

## Server changes

- `resources` table: `resource_kind` CHECK narrowed to `('memory')` for new
  writes; `description` column added (NOT NULL with a migration backfill);
  `context_kind` and `applies_when` dropped; `workflow_steps` dropped.
- `tree_entries.resource_kind` accepts `('memory', 'project_org_selection')`;
  the latter remains a system entry kind for daemon bookkeeping.
- `drafts` / `draft_operations`: `resource_kind` CHECK narrowed to
  `('memory')`; typed content variants collapse into one Memory content
  carrying `description`.
- `project_org_resource_selections` and `personal_bundle_items`: drop the
  `resource_kind` column (already keyed by `resource_id`).
- New unified endpoints: `GET /api/v1/org/memories`,
  `GET /api/v1/projects/{project_id}/memories`,
  `GET /api/v1/org/memories/{memory_id}`,
  `GET /api/v1/projects/{project_id}/memories/{memory_id}`.
- `ProjectOrgSelection` and `PersonalBundle` DTOs use a single
  `resource_ids: [string]`.
- Draft create/update DTOs accept a unified Memory ref (scope + id/path)
  without a kind.

## daemon changes

- `DaemonDraftContent` collapses from three variants to one Memory content
  carrying `description`.
- `DaemonResourceKind` is removed or reduced to the system kinds the daemon
  still manages (`memory`, `project_org_selection`).
- Commit sync accepts the unified `TreeEntryKind`; unknown system kinds are
  rejected with a distinct error.
- Search schema: `search_resources` indexes `description` as its own column;
  chunking, BM25 and vector fields record `description` vs `content` source;
  retrieval history keeps the field source.
- Materialization uses one namespace instead of `context/` vs `rule/`.
- Draft overlay validation drops the kind double-check.
- Local SQLite schema version bump with a migration that rewrites kind values
  and rebuilds derived search indexes.

## MCP / Agent Adapter

- `activate` / `load` / `store` use the unified Memory contract; results no
  longer carry a three-type kind.
- Workflow Skill generation is explicitly retired: it lived in the archived
  Zig CLI (`archive/zig-cli/src/client/adapter/workflow_skills.zig`), which
  is outside the active build boundary.
- The former `activate` / `ntmd` host-native layer is retired (ISSUE-064).
  Direct-file adapters no longer install project guidance as host skills and
  clean up their old `.agents/skills` / `.claude/skills` artifacts. The Codex
  plugin adds only a generic Clumsies bootstrap Skill: it uses MCP to activate
  Memory and dynamically load relevant project-maintained skills. Those skills
  remain ordinary resources in Memory Space, are governed by the unified
  Memory contract, and are never copied into Codex's skill directories.

## macOS

- `MemoryKind` is removed from the UI (the Local/Hub merge into one Memory
  section landed first; this phase removes the remaining kind-driven
  creation defaults, path validation, preview gating, bundle grouping and
  selection ID splitting).
- Create flow collects a non-empty `description`.
- Bundles and Project Org Selection use single `resource_ids`.
- Empty states, search details and context menus are kind-free.

## Migration

1. Generate a repeatable, verifiable neutral export covering: effective
   Memory bodies, title/path, description (backfilled), status, provenance,
   active Drafts, Project/Org relations, and native Issues that must be
   preserved. This is implemented as the org-admin endpoint
   `GET /api/v1/admin/memory-export`, which emits every Memory (including
   `issues/` paths), all Drafts with their raw operations, Project org
   selections and personal bundles. IDs are emitted verbatim, so the export
   doubles as the `old_id -> memory_id` identity map; the exported
   `content_hash` is the byte-level comparison key.
2. Take a full database backup (PostgreSQL dump and daemon SQLite copy).
3. Import into the new schema; verify counts, content hashes, description,
   scope/project relations, active Drafts, and preserved native Issues.
   `dev/memory-migration-verify.sh check <before.json> <after.json>` compares
   two exports (identity set, per-memory hash/scope/description, draft,
   selection and bundle counts, draft operation count) and fails loudly on
   any discrepancy; `dev/memory-migration-verify.sh fetch` pulls the export
   from a live server with an org-admin bearer token.
4. Emit an `old_id -> memory_id` map; any unmigrated or conflicting object is
   reported explicitly.
5. Archive old Commit history offline; generate and verify a new baseline
   Commit from the migrated effective state.
6. A migration rehearsal must be able to restore from backup and repeat
   export / import / verification on a fresh database.

## Acceptance evidence

- No new write path accepts the old three types (grep for the enum variants
  in Server/daemon/OpenAPI/generated clients).
- `activate` returns description-aware results and a test demonstrates the
  retrieval chain uses the field.
- macOS creates a Memory with a required description and edits it with
  revision guards.
- Unified RAG, Draft sync, Commit install, macOS Memory section, MCP real
  host and data-restore end-to-end tests pass.
