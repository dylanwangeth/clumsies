# MCP

Clumsies exposes one agent-facing tool:

| Tool | Purpose |
|---|---|
| `memory` | Read the bound Project's Effective Memory or persist Project-carried proposal Drafts (`store`). |

The App-bundled Rust `clumsiesd mcp serve` process is a protocol proxy.
Effective Memory construction, indexing, retrieval, exact loading, Draft
persistence, and AgentRun observation belong to the resident `clumsiesd` and
are reached over local XPC. The proxy exposes only the typed `memory` tool; it
cannot pass arbitrary JSON through to daemon methods.

The proxy verifies the resident's Agent runtime protocol revision and build
identity before resolving the current directory's Project binding, and the
resident revalidates that marker on every Agent-scoped dispatch. A missing or
stale resident or proxy fails explicitly instead of mixing releases.

There is no setup call. The removed `retrieve` tool, host-session binding,
`META_PROMPT.md` bootstrap, and MCP attestation path have no compatibility
dispatch. Runtime guidance is delivered by `InitializeResult.instructions` and
the tool descriptions.

## Memory

`memory` unifies all memory operations under a single tool with an `op` tagged enum: `activate`, `load`, and `store`.

### Memory Guidelines (`CLUMSIES.md`)

Each project may define a memory guidelines document (conventionally `CLUMSIES.md` or `README.md` at the workspace root). This document establishes:
1. **Taxonomy & Organization**: Standard directory layouts (e.g. `architecture/*`, `decisions/*`, `guides/*`).
2. **Update Rules & Mutation Policy**: When the agent should propose drafts, what descriptions to write, and what not to persist.
3. **Deprecation Policy**: How conflicting or obsolete memories should be superseded.

Agents can read this document via `memory` with `op: { load: { ids: ["CLUMSIES.md"] } }` before making substantial memory updates.

### Activate

Call `memory` with `op: { activate: ... }` once at the beginning of each substantive task:

```json
{
  "op": {
    "activate": {
      "query": "adjust the MCP hybrid retrieval interface",
      "state": "optional-opaque-state"
    }
  }
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

The `agent_activation.v2` profile maps the BGE reranker logit through sigmoid
and removes candidates below the daemon-owned relevance floor. It also keeps
only the highest-ranked member of overlapping spans from the same resource.
Token budgeting consumes the remaining relevance-ordered prefix instead of
filling unused space with lower-ranked short fragments.

The response contains:

```json
{
  "index_revision": "search_...",
  "profile": "agent_activation.v2",
  "next_state": "opaque-state",
  "fragments": [
    {
      "action": "add",
      "unit_key": "mem_123/memory-delta/0/0",
      "content_hash": "sha256:...",
      "resource_id": "mem_123",
      "scope": "org",
      "kind": "memory",
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

### Load

Use `memory` with `op: { load: ... }` for complete resources already identified by ID or exact path (including project guidelines like `CLUMSIES.md`):

```json
{
  "op": {
    "load": {
      "ids": ["mem_123", "CLUMSIES.md", "architecture/retrieval.md"],
      "knownHashes": {
        "mem_123": "sha256:..."
      }
    }
  }
}
```

`ids` is required, non-empty, unique, and contains strings. `knownHashes` is
optional. When a known hash matches the current complete resource,
`changed=false` and content is omitted. A missing requested resource returns
`memory_resource_not_found` instead of being silently dropped.

`load` reads the same Effective Memory as `activate`, including current local
Draft overlays. It does not perform fuzzy search, embedding, or reranking.

### Store

Call `memory` with `op: { store: ... }` only when the user explicitly asks to create, update, rename,
delete, or discard managed memory.

Every MCP Draft is carried by the Project resolved from the current directory.
Its internal `org` scope is the authority target for a future Review, not Draft
ownership and not a direct Organization write. Before merge, the Draft overlays
only that Project's Effective Memory. MCP exposes no Review decision, merge, or
publish operation; those Organization authority actions require an Org
administrator in the Review workflow. Organization is not represented by a
synthetic Project.

Operations:

| Operation | Required fields | Optional fields |
|---|---|---|
| `create` | `path`, `body` | `description`, `resource` |
| `update` | `id`, `expected_hash`, `replacements` | `description`, `resource` |
| `rename` | `id`, `new_path` | `description`, `resource` |
| `delete` | `id` | `description`, `resource` |
| `discard` | `id` | `resource` |

`resource` defaults to `memory`. IDs may be `mem_`-prefixed or legacy `ctx_` / `rul_` / `wfl_` values; legacy
IDs stay stable and opaque and are never rewritten.

`delete` removes the addressed item from Local Effective Memory. When the item
is an unpublished Create Draft, daemon normalizes the operation to `discard`;
only deletion of an authoritative resource remains an open deletion Draft that
can be submitted for Review.

Example Create:

```json
{
  "op": {
    "store": {
      "create": {
        "path": "release/RELEASE.md",
        "description": "Release procedure for the project",
        "body": "# Release\n\nRun verification before publishing."
      }
    }
  }
}
```

Before updating a resource, call `load` and pass its complete-resource
`content_hash` as `expected_hash`. An update contains one or more exact text
replacements:

```json
{
  "op": {
    "store": {
      "update": {
        "id": "mem_123",
        "expected_hash": "sha256:...",
        "replacements": [
          {
            "old_text": "The original exact text.",
            "new_text": "The replacement text."
          }
        ]
      }
    }
  }
}
```

Every `old_text` must occur exactly once in the current Effective Memory
resource. Replacements in one update must not overlap and are applied
atomically against the same original content. A stale hash, missing match,
ambiguous match, or overlap rejects the complete update without creating a
Draft operation. `new_text` may be empty to delete text.

Paths are free-form within the managed Memory namespace. The create
`body` is the complete resource content; updates never accept a complete body
from the agent — daemon materializes the verified replacements into the
complete Draft result. Memory bodies are Markdown; whether a resource reads as
a rule, workflow, or context is expressed by its content and path, not by a
wire type. `description` is an optional semantic summary on create/update and
an explicit retrieval field. Metaprompt and `mpf` are not valid wire values.

A successful result contains the local operation ID, Draft ID, queue status,
and sync status. It means the operation is durably stored locally and queued
for automatic synchronization. It does not mean a Review was merged or an
authority Ref moved. Ordinary Project members may propose and submit changes,
but only an Org owner or administrator may approve, reject, or merge an Org
publication Review.

## Daemon operations

| XPC method | Consumer |
|---|---|
| `activate_memory` | MCP `activate` |
| `load_memory` | MCP `load` |
| `store_draft_operation` | MCP `store`, Desktop, and other clients |
| `record_agent_run_event` | Private Coding Agent lifecycle hook bridge |
| `search_index_status` | Desktop diagnostics and tests |
| `rebuild_search_index` | Recovery, tests, and development tooling |

Adapter-managed scripts pipe lifecycle events to the private command
`clumsiesd _agent agent-run-event --host codex|claude-code|opencode|dsh|antigravity`. The
short-lived Rust proxy resolves the repository's daemon Project binding,
reduces the host payload to bounded identifiers and lifecycle fields, and
calls `record_agent_run_event`. Managed adapters neither install nor synthesize
a normal root `Stop`, and the proxy never blocks a host.
`StopFailure`, `SubagentStop`, and `SessionEnd` remain non-blocking lifecycle
observations. All parsing, binding, IPC, and daemon failures remain fail-open.

The private bridge does not persist raw hook JSON, prompts, transcripts, tool
payloads, or assistant messages. `record_agent_run_event` is not exposed as an
MCP tool. The bridge accepts a legacy or manually forwarded normal `Stop` for
compatibility, but records only AgentRun telemetry and never blocks the host.

Every valid `activate_memory` call also writes one local Retrieval Run from the
same ranked candidate trace used for the response. This does not add fields to
the MCP `activate` schema. Retrieval history, Evaluation Cases, and B1–B4
exports are daemon/Desktop diagnostic APIs described in
`docs/retrieval-evaluation.md`; they are not additional MCP tools and are never
sent to Server.

The default retrieval profile has no silent BM25-only, old substring-search,
or fallback to an incompatible index. While a compatible replacement index is
building, the previous ready generation remains queryable; the scheduler
atomically publishes the new generation when it is complete. Model, vector,
generation, and state failures remain
explicit protocol errors.
