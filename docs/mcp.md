# MCP

## What MCP Does Here

MCP is the agent-facing protocol surface for clumsies. It is how an agent activates relevant memory, retrieves the specific rules, workflows, and context it needs, and stores draft edits back into the local memory system.

That makes MCP more than a transport layer. It is the runtime contract between agent work and managed rule, workflow, context, and MPF memory.

## Current Tool Surface

The current implementation exposes three MCP tools:

| Tool | Purpose |
| --- | --- |
| `activate` | discover available rules, workflows, and context files |
| `retrieve` | bootstrap the session or retrieve selected content |
| `store` | create, update, rename, delete, or discard local memory drafts |

There is no `memory.` namespace prefix. The older public tools are not part of the current surface: `memsetup`, `memdisc`, `memload`, `memref`, `artifact`, `agentreport`, and `agentrejected` are removed rather than wrapped.

## Runtime Cycle

The current loop is:

1. bootstrap the connection with `retrieve` using `session_id` and `knownHashes`
2. activate relevant material with `activate`
3. retrieve only the content the task needs with `retrieve` using `ids` and `knownHashes`
4. apply the loaded material in the work
5. use `store` when the task is to refine rules, context, or MPF

This phase intentionally does not redesign retrieval parameters or write algorithms. `activate` keeps the old discover arguments, `retrieve` keeps the old setup/load argument shapes, and `store` keeps the old draft operation shape.

## Result Envelope

Every successful tool call is wrapped in the same envelope shape:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{...serialized structured result...}"
    }
  ],
  "structuredContent": {
    "...": "tool-specific payload"
  },
  "isError": false
}
```

Error results use the same outer shape, but set `isError` to `true` and place an error string under `structuredContent.error`.

## `retrieve` For Bootstrap

When `session_id` is present, `retrieve` bootstraps the connection. This is the old setup parameter structure under the new tool name.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `session_id` | string | yes | host-agent session or thread id |
| `knownHashes` | object map | yes | must include `META_PROMPT.md`; pass the remembered hash, or `""` when unknown |

Example:

```json
{
  "session_id": "4f04001af902673e92094a7c59d86abb",
  "knownHashes": {
    "META_PROMPT.md": ""
  }
}
```

### Structured Result

| Field | Meaning |
| --- | --- |
| `workspaceId` | authoritative workspace ID |
| `sessionId` | session identifier used to group later local events |
| `mpf.hash` | current `META_PROMPT` hash |
| `mpf.content` | current `META_PROMPT` content when changed or initially loaded |
| `mpf.changed` | `false` when the caller already knows the same hash |

## `activate`

`activate` discovers available rules, workflows, and context files without loading their full content. It keeps the old discover parameters unchanged.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `kind` | string enum | no | one of `rule`, `workflow`, `context` |
| `group` | string | no | filter by first path segment or logical group |
| `query` | string | no | free-text query across searchable metadata |

### Structured Result

```json
{
  "items": [
    {
      "id": "p-e60e775a-fc91-4780-bd32-2bb451404298",
      "kind": "workflow",
      "path": "workflow/CODING.md",
      "name": "CODING",
      "group": "workflow",
      "hash": "sha256:..."
    }
  ]
}
```

Each item can include:

| Field | Meaning |
| --- | --- |
| `id` | stable object ID or local `tmp-*` draft ID |
| `kind` | `rule`, `workflow`, or `context` |
| `path` | current workspace-relative path |
| `name` | display name derived from the path |
| `group` | optional group value |
| `hash` | current content hash |
| `description` | optional metadata description when present |
| `hasDraft` | whether the object currently has a local draft |

## `retrieve` For Content

When `ids` is present and `session_id` is absent, `retrieve` resolves full content for the selected IDs. This is the old load parameter structure under the new tool name.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `ids` | string array | yes | one or more rule, workflow, context, path, alias, or local `tmp-*` IDs |
| `knownHashes` | object map | yes | `{id: hash}` map for delta loading; include every requested id |

Each `ids` entry must also be present in `knownHashes`. Pass the remembered hash when available. Pass an empty string when the caller explicitly does not know the hash yet.

### Structured Result

```json
{
  "workspaceId": "ws-4a5c282474c9b5d9385dec0502267738",
  "items": [
    {
      "id": "p-e60e775a-fc91-4780-bd32-2bb451404298",
      "kind": "workflow",
      "path": "workflow/CODING.md",
      "changed": true,
      "hash": "sha256:...",
      "hasDraft": false,
      "content": "# ...",
      "constraints": [
        {
          "id": "Steps",
          "name": "Steps",
          "text": "Inspect the diff and suggest a commit message.",
          "textHash": "..."
        }
      ]
    }
  ]
}
```

Important item fields are:

| Field | Meaning |
| --- | --- |
| `changed` | whether the current hash differs from the caller's `knownHashes` entry |
| `hash` | current content hash |
| `hasDraft` | whether the loaded result resolves to draft-aware state |
| `draftBaseHash` | optional base hash when draft-aware content is involved |
| `content` | full text content, or `null` when unchanged under delta loading |
| `constraints` | parsed rule/workflow constraint entries returned as metadata |

The content no longer includes a footer telling the agent to call a reference-reporting tool. `constraints` metadata is still returned because it is useful structure for agents and later protocol work.

## `store`

`store` stages local changes for rules, workspace context, or MPF. Those local changes are stored as drafts until they enter review.

The input is still the tagged command object used by the previous draft tool. This phase does not introduce text-fragment replacement or multi-patch operations; `update.body` is the complete replacement draft body.

```json
{
  "resource": "context",
  "op": {
    "update": {
      "id": "ctx-123",
      "body": "# New content\n",
      "description": "Clarify setup notes"
    }
  }
}
```

### Top-Level Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `resource` | string enum | yes | one of `context`, `rule`, or `mpf` |
| `op` | tagged object | yes | exactly one of `create`, `update`, `rename`, `delete`, or `discard` |

### `create`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | target path for the new draft |
| `body` | string | yes | draft content |
| `description` | string | no | optional human-facing summary |

### `update`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | context id, rule id, local draft id, or `META_PROMPT.md` |
| `body` | string | yes | complete replacement draft body |
| `description` | string | no | optional summary |

### `rename`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | context id, rule id, or local draft id |
| `new_path` | string | yes | proposed new path |
| `description` | string | no | optional summary |

### `delete`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | resource id, create-draft temp id, or MPF |
| `description` | string | no | optional summary |

### `discard`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | any draft or resource identifier |

## Current Error Behavior

| Situation | Result |
| --- | --- |
| invalid argument types or missing required fields | `isError: true` with an error message |
| unknown tool name | `Unknown tool` |
| `retrieve` bootstrap omits `knownHashes.META_PROMPT.md` | `isError: true` with an invalid params error |
| `retrieve` content load omits `knownHashes` or an entry for a requested ID | `isError: true` with an invalid params error |
| `retrieve` content load receives an unknown rule ID | `Unknown rule id` |
| `store` path is unsafe | `unsafe path` |
| `store` target is missing | `memory artifact or draft not found` |
| `store` update conflicts with a non-update local draft | `memory artifact already has an incompatible local change` |
| `store` create collides with an existing draft | `draft already exists` |
