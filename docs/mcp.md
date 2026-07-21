# MCP

Clumsies exposes three agent-facing memory tools:

| Tool | Purpose |
|---|---|
| `activate` | Retrieve ranked, directly usable memory fragments for the current task. |
| `load` | Read complete resources by a known stable ID or exact path. |
| `store` | Persist an explicit user-requested Context, Rule, or Workflow Draft. |

The Zig MCP server is a protocol adapter. Effective Memory construction,
indexing, retrieval, exact loading, and Draft persistence belong to the Rust
daemon and are reached over local XPC.

There is no setup call. The removed `retrieve` tool, host-session binding,
`META_PROMPT.md` bootstrap, and MCP attestation path have no compatibility
dispatch. Runtime guidance is delivered by `InitializeResult.instructions` and
the tool descriptions.

## Activate

Call `activate` once at the beginning of each substantive task:

```json
{
  "query": "adjust the MCP hybrid retrieval interface",
  "state": "optional-opaque-state"
}
```

| Field | Required | Meaning |
|---|---:|---|
| `query` | yes | A non-empty natural-language representation of the current task or cue. |
| `state` | no | The preceding `next_state`, but only while its earlier fragments remain in the model context. |

The daemon performs BM25 and dense-vector recall, RRF fusion, Cross-Encoder
reranking, resource diversity limits, token budgeting, and fragment delta
calculation in one operation. `kind`, `group`, `limit`, model names, and ranking
parameters are deliberately not agent-facing inputs.

The response contains:

```json
{
  "index_revision": "search_...",
  "profile": "agent_activation.v1",
  "next_state": "opaque-state",
  "fragments": [
    {
      "action": "add",
      "unit_key": "ctx_123/mcp/memory-delta/0/0",
      "content_hash": "sha256:...",
      "resource_id": "ctx_123",
      "scope": "project",
      "kind": "context",
      "path": "architecture/retrieval.md",
      "heading_path": ["MCP", "Memory Delta"],
      "content": "..."
    }
  ],
  "removed": []
}
```

`add` and `replace` include content. `reuse` identifies content already present
in the caller's context and omits it. `removed` invalidates units that have been
deleted, lost permission, or disappeared after reparsing. A unit that is merely
irrelevant to the current query is not removed.

Omit `state` after context compaction, after old tool output is dropped, or
when starting fresh. Invalid or unsupported state returns
`invalid_activation_state`; it is never silently treated as an empty state.

The daemon prepares its pinned local models in the background. Until they are
ready, activation returns `search_model_preparing` with current and total byte
counts instead of holding the MCP request open. Model preparation retries in
the background and has no lexical-only fallback.

## Load

Use `load` for complete resources already identified by ID or exact path:

```json
{
  "ids": ["ctx_123", "architecture/retrieval.md"],
  "knownHashes": {
    "ctx_123": "sha256:..."
  }
}
```

`ids` is required, non-empty, unique, and contains strings. `knownHashes` is
optional. When a known hash matches the current complete resource,
`changed=false` and content is omitted. A missing requested resource returns
`memory_resource_not_found` instead of being silently dropped.

`load` reads the same Effective Memory as `activate`, including current local
Draft overlays. It does not perform fuzzy search, embedding, or reranking.

## Store

Call `store` only when the user explicitly asks to create, update, rename,
delete, or discard managed memory. Ordinary task execution, summarization, and
the agent's judgment that something may be useful are not write authorization.

Top-level input:

| Field | Type | Meaning |
|---|---|---|
| `resource` | `context`, `rule`, or `workflow` | The explicit memory domain type. |
| `op` | tagged object | Exactly one of `create`, `update`, `rename`, `delete`, or `discard`. |

Operations:

| Operation | Required fields | Optional fields |
|---|---|---|
| `create` | `path`, `body` | `description`; Rule may also provide `name`, `applies_when`, `tags`. |
| `update` | `id`, `body` | `description`; Rule may also provide `name`, `applies_when`, `tags`. |
| `rename` | `id`, `new_path` | `description` |
| `delete` | `id` | `description` |
| `discard` | `id` | none |

Example:

```json
{
  "resource": "workflow",
  "op": {
    "create": {
      "path": "workflow/RELEASE.md",
      "body": "# Release\n\nRun verification before publishing."
    }
  }
}
```

Workflow paths use the `workflow/` namespace. Context and Workflow `body`
values become complete text content. Rule `body` becomes the structured
constraint; omitted optional Rule fields retain their current values on update.
Metaprompt and `mpf` are not valid wire values.

A successful result contains the local operation ID, Draft ID, queue status,
and sync status. It means the operation is durably stored locally and queued
for automatic synchronization. It does not mean a Review was merged or an
authority Ref moved.

## Daemon operations

| XPC method | Consumer |
|---|---|
| `activate_memory` | MCP `activate` |
| `load_memory` | MCP `load` |
| `store_draft_operation` | MCP `store`, Desktop, and other clients |
| `search_index_status` | Desktop diagnostics and tests |
| `rebuild_search_index` | Recovery, tests, and development tooling |

The default retrieval profile has no silent BM25-only, old substring-search,
or stale-index fallback. Model, vector, generation, and state failures remain
explicit protocol errors.
