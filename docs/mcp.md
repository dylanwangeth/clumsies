# MCP

Clumsies exposes four agent-facing tools:

| Tool | Purpose |
|---|---|
| `activate` | Retrieve ranked, directly usable memory fragments for the current task. |
| `load` | Read complete resources by a known stable ID or exact path. |
| `store` | Persist an explicitly requested Memory Draft. |
| `kanban` | Create, update, list, or semantically transition native Issues. |

The App-bundled Rust `clumsiesd mcp serve` process is a protocol proxy.
Effective Memory construction, indexing, retrieval, exact loading, Draft
persistence, and AgentRun projection belong to the resident `clumsiesd` and
are reached over local XPC. The proxy exposes only the four typed MCP tools; it
cannot pass arbitrary JSON through to daemon methods.

The proxy verifies the resident's Agent runtime protocol revision and build
identity before resolving the current directory's Project binding, and the
resident revalidates that marker on every Agent-scoped dispatch. A missing or
stale resident or proxy fails explicitly instead of mixing releases.

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
      "scope": "project",
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

## Load

Use `load` for complete resources already identified by ID or exact path:

```json
{
  "ids": ["mem_123", "architecture/retrieval.md"],
  "knownHashes": {
    "mem_123": "sha256:..."
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
delete, or discard managed memory. Issues are native objects managed by
`kanban`; do not model them as Memory documents.

Top-level input:

| Field | Type | Meaning |
|---|---|---|
| `resource` | `memory` | The unified Memory type. Legacy `context`, `rule`, and `workflow` values are accepted and treated as memory. |
| `op` | tagged object | Exactly one of `create`, `update`, `rename`, `delete`, or `discard`. |

Operations:

| Operation | Required fields | Optional fields |
|---|---|---|
| `create` | `path`, `body` | `description` |
| `update` | `id`, `expected_hash`, `replacements` | `description` |
| `rename` | `id`, `new_path` | `description` |
| `delete` | `id` | `description` |
| `discard` | `id` | none |

IDs may be `mem_`-prefixed or legacy `ctx_` / `rul_` / `wfl_` values; legacy
IDs stay stable and opaque and are never rewritten.

`delete` removes the addressed item from Local Effective Memory. When the item
is an unpublished Create Draft, daemon normalizes the operation to `discard`;
only deletion of an authoritative resource remains an open deletion Draft that
can be submitted for Review.

Example:

```json
{
  "resource": "memory",
  "op": {
    "create": {
      "path": "release/RELEASE.md",
      "description": "Release procedure for the project",
      "body": "# Release\n\nRun verification before publishing."
    }
  }
}
```

Before updating a resource, call `load` and pass its complete-resource
`content_hash` as `expected_hash`. An update contains one or more exact text
replacements:

```json
{
  "resource": "memory",
  "op": {
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
```

Every `old_text` must occur exactly once in the current Effective Memory
resource. Replacements in one update must not overlap and are applied
atomically against the same original content. A stale hash, missing match,
ambiguous match, or overlap rejects the complete update without creating a
Draft operation. `new_text` may be empty to delete text.

Paths are free-form within the organization or project namespace. The create
`body` is the complete resource content; updates never accept a complete body
from the agent — daemon materializes the verified replacements into the
complete Draft result. Memory bodies are Markdown; whether a resource reads as
a rule, workflow, or context is expressed by its content and path, not by a
wire type. `description` is an optional semantic summary on create/update and
an explicit retrieval field. Metaprompt and `mpf` are not valid wire values.

A successful result contains the local operation ID, Draft ID, queue status,
and sync status. It means the operation is durably stored locally and queued
for automatic synchronization. It does not mean a Review was merged or an
authority Ref moved.

## Issue

`kanban` manages durable native Issues and connects them to installation-local
AgentRun observations without deriving semantic state from execution telemetry. An
AgentRun records one root turn or subagent execution; its Stop does not advance
an Issue.

The input contains exactly one tagged operation under `op`:

| Operation | Fields | Result |
|---|---|---|
| `list` | none | The bound Project's native Issue board and recent unlinked runs. |
| `get` | exactly one of global `issue_id` or Project-local `issue_key` | The complete Issue, acceptance criteria, external references, dependencies, blocking facts, verification protocol, `changed_by_run_id`, state, revision, event timeline, and owning `project_id`. |
| `create` | `title`, `description`; optional `acceptance_criteria`, `external_references`, `dependencies`, `blocking_facts`, `verification_level`, `verification_steps` | A new Todo Issue with an atomically allocated key. |
| `update` | `issue_key`, Issue `expected_revision`, and at least one semantic field, including optional `external_references`, `dependencies`, `blocking_facts`, `verification_level`, `verification_steps` | Updated Issue content without a status transition. |
| `begin_work` | `issue_key`, Hook-issued `run_id`, and `expected_revision` | In Progress state plus the linked AgentRun. Agents cannot mint a manual run, and one session holds at most one In Progress Issue. |
| `pause_issue` | `run_id`, `issue_key` | Paused state; the pausing run may later resume. |
| `resume_issue` | `run_id`, `issue_key`; optional `takeover` | Back to In Progress. Non-owner resume requires `takeover`. |
| `request_closure` | `issue_key`, `run_id`, `expected_revision`; optional `summary` | In Review state plus the linked AgentRun. Rejected when the Issue requires human verification and `verification_steps` is empty. |
| `unclaim` | `issue_key`, `expected_revision`; optional `run_id` | Releases an In Progress, Paused, or abandoned Issue back to Todo without an AgentRun binding. Refused while an active run is working the Issue (that run must pause or request closure first); a human release omits `run_id`. |
| `export` | `issue_key` | A deterministic, portable Markdown snapshot of the Issue. |

`issue_id` uses `issue_` followed by 32 lowercase hexadecimal characters and is
globally unique. This is the value copied from Kanban and passed to `get`.
`issue_key` uses the exact `ISSUE-NNN` form and is only Project-local: exactly three
digits, with `ISSUE-000` reserved as invalid. Repeating the same start is
idempotent; changing an existing run association to another Issue is a
conflict. `expected_revision` is the exact positive run revision injected by
the lifecycle hook.

`verification_level` is `agent_self`, `human_required`, or `mixed`, with
`verification_steps` listing the human verification protocol for closure.
`request_closure` is rejected when the level is not `agent_self` and
`verification_steps` is empty; the Agent must first add the protocol with
`update`.

`external_references` is a bounded array of objects with `kind` (`issue` or
`pull_request`) and an absolute HTTP(S) `url`. Omitting it on create produces an
empty list; omitting it on update preserves the current list; passing `[]`
clears it. `list` and `get` return the normalized list.

`dependencies` is a bounded array of `ISSUE-NNN` keys in the same Project that
must be Done before this Issue can start. `blocking_facts` is a bounded array of
checkable predicates: `fact_id` (stable identifier), `kind`
(`host_capability` or `external`), optional `value`, `description`, and
`satisfied`. Both follow the same patch semantics as `external_references`:
omission preserves, `[]` clears. Dependency cycles, self-references,
duplicates, and missing targets are rejected. `list` and `get` return each
Issue's resolved dependency states, blocking facts, `blocked`, and concrete
`blocking_reasons`, so an Agent can judge whether a Todo is actionable now.

On a successful root or subagent start, the lifecycle hook adds a short context
message containing that agent's current `run_id` and revision. Use those exact
values after deciding semantically whether the prompt continues an Issue,
creates a new native Issue, or should not create one. Use `create` for durable
work and `begin_work` only when it is the active line of work. Before finishing,
a root Agent uses `request_closure` only after judging the linked Issue
acceptance criteria satisfied. Subagents cannot request closure. Do not choose
a current run from `list` by recency: concurrent runs make that inference
ambiguous.

The optional closure summary is limited to 1,000 UTF-8 bytes. In Review
(formerly called Closure Requested) is an Agent proposal. Agents cannot approve
it; only the user's desktop Approve gate makes the Issue Done. The board shows
five columns — Todo, In Progress, In Review, Abandoned, Done — where Abandoned
is a derived bucket of In Progress Issues whose AgentRun claim silently died
(stale, no active run, 24h of inactivity); the daemon never stores an
"abandoned" state. A Paused Issue keeps its place in In Progress with a paused
badge, and its handling Agent may resume it or a new handler may take it over
with `takeover`.

Example:

```json
{
  "op": {
    "request_closure": {
      "issue_key": "ISSUE-123",
      "run_id": "arun_123",
      "summary": "Acceptance criteria are satisfied.",
      "expected_revision": 4
    }
  }
}
```

`get` resolves its global ID independently and returns the owning Project. List
and mutations use the Project binding established for the MCP process. For
`begin_work` and `request_closure`, the MCP proxy injects that Project ID into
the private daemon request; a run from another Project is not visible or
mutable even if its ID and revision are known. The resident daemon owns Issue
discovery, AgentRun association, and board-state derivation; the proxy only
validates the tagged input and forwards the operation.

## Daemon operations

| XPC method | Consumer |
|---|---|
| `activate_memory` | MCP `activate` |
| `load_memory` | MCP `load` |
| `store_draft_operation` | MCP `store`, Desktop, and other clients |
| `list_issue_board` | MCP `kanban.list` and Desktop |
| `get_issue_detail` | Native Issue detail lookup for local clients |
| `get_issue` | MCP `kanban.get` (by `issue_id` or `issue_key`) |
| `export_issue` | MCP `kanban.export` |
| `start_issue_work` | MCP `kanban.begin_work` |
| `pause_issue` | MCP `kanban.pause_issue` |
| `resume_issue` | MCP `kanban.resume_issue` |
| `request_issue_closure` | MCP `kanban.request_closure` |
| `unclaim_issue` | MCP `kanban.unclaim`, Desktop Release |
| `apply_issue_gate` | Desktop Approve / Request Changes / Reopen gates |
| `remove_issue` | Desktop Archive / Delete cleanup |
| `record_agent_run_event` | Private Coding Agent lifecycle hook bridge |
| `search_index_status` | Desktop diagnostics and tests |
| `rebuild_search_index` | Recovery, tests, and development tooling |

Lifecycle hooks do not call the agent-facing `kanban` tool. Adapter-managed
scripts pipe the host event to the private command
`clumsiesd _agent issue-run-event --host codex|claude-code|opencode`. The
short-lived Rust proxy resolves the repository's daemon Project binding,
reduces the host payload to bounded identifiers and lifecycle fields, and
calls `record_agent_run_event`. It emits a bounded current-run context
containing `run_id`, revision, and the semantic decision instruction after a
successful root or subagent start. For Codex and Claude Code, the first root
Stop is a non-terminal decision probe; a follow-up Stop records the end. All
parsing, binding, IPC, and daemon failures remain fail-open.

The private bridge does not persist raw hook JSON, prompts, transcripts, tool
payloads, or assistant messages. `record_agent_run_event` is not exposed as an
MCP tool; agents use `kanban.begin_work` and `kanban.request_closure` for explicit
semantic updates. Prompt text is not matched to an Issue automatically, and a
normal Stop records no semantic outcome.

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
