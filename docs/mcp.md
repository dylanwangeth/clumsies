# MCP

## What MCP does here

MCP is the agent-facing protocol surface for clumsies. It is how an agent discovers available material, loads the specific rules, workflows, and context it needs, declares which constraints it actually applied, and proposes edits back into the system.

That makes MCP more than a transport layer. It is the runtime contract between agent work and the managed rule, context, and attestation model.

## The current tool surface

The current implementation exposes these MCP tools:

| Tool family | Tools |
| --- | --- |
| session and attestation | `memory.setup`, `memory.search`, `memory.load`, `memory.refer`, `memory.submit`, `memory.reject` |
| workspace context proposals | `context.propose_create`, `context.propose_update`, `context.propose_rename`, `context.propose_delete` |
| Library rule proposals | `rule.propose_create`, `rule.propose_update`, `rule.propose_rename`, `rule.propose_delete` |

This is the real protocol surface in the running code. The server test suite explicitly asserts that `memory.begin`, `memory.complete`, `memory.startup`, `memory.list`, and `memory.activate` are not part of the public tool list.

## The core runtime cycle

The stable mental model now matches the current `META_PROMPT` very closely:

1. bootstrap the session with `memory.setup`
2. discover relevant material with `memory.search`
3. load only the content the task actually needs with `memory.load`
4. apply the loaded rules in the work
5. declare applied constraints with `memory.refer`
6. use proposal tools when the task is to refine rules or context
7. close the turn with `memory.submit` or `memory.reject`

That cycle is the runtime expression of the whole product:

- Hub publishes authoritative state
- local cache keeps runtime fast
- MCP serves that state to the agent
- attestation records what actually happened

## Result envelope

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

This detail matters because the protocol is not only human-readable. Agents are expected to consume the machine-readable `structuredContent` payload directly.

## `memory.setup`

`memory.setup` bootstraps the session. It returns the current workspace identity, the current session ID, and the current `META_PROMPT` frame.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `knownHash` | string | no | lets the client ask for delta behavior if it already knows the last meta-prompt hash |

### Structured result

| Field | Meaning |
| --- | --- |
| `workspaceId` | authoritative workspace ID |
| `sessionId` | session identifier used to group later attestation events |
| `mpf.hash` | current `META_PROMPT` hash |
| `mpf.content` | current `META_PROMPT` content when changed or initially loaded |
| `mpf.changed` | `false` when the caller already knows the same hash |

A typical result looks like this:

```json
{
  "workspaceId": "ws-4a5c282474c9b5d9385dec0502267738",
  "sessionId": "4f04001af902673e92094a7c59d86abb",
  "mpf": {
    "hash": "1eb791139b9f265846dc2d0d8d6a0c1ce5116a245c42829838ddcb492fc13337",
    "content": "# clumsies\n..."
  }
}
```

In the current runtime, that meta-prompt frame comes from the workspace-scoped [`META_PROMPT.md`](/meta-prompt) asset. The session object also records a local `.setup` attestation event when the session is created.

The current bootstrap content is intentionally simpler than earlier revisions. It now frames the protocol as `discover -> load -> apply -> refer -> refine -> submit`, and its priority model is `loaded rules > this meta-prompt > your defaults`.

## `memory.search`

`memory.search` discovers available rules, workflows, and context files without loading their full content.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `kind` | string enum | no | one of `rule`, `workflow`, `context` |
| `group` | string | no | filter by first path segment or logical group |
| `query` | string | no | free-text query across searchable metadata |

### Structured result

The tool returns:

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
| `id` | stable object ID |
| `kind` | `rule`, `workflow`, or `context` |
| `path` | current workspace-relative path |
| `name` | display name derived from the path |
| `group` | optional group value |
| `hash` | current content hash |
| `description` | optional metadata description when present |

Search is inventory, not content delivery. Its job is to let the agent choose what is relevant before spending context window on full content.

## `memory.load`

`memory.load` resolves full content for the selected IDs. This is where protocol flow stops being inventory and becomes working task context.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `ids` | string array | yes | one or more rule, workflow, or context IDs |
| `knownHashes` | object map | no | optional `{id: hash}` map for delta loading |

### Structured result

The tool returns:

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
          "id": "c-1",
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
| `constraints` | parsed constraint IDs for rules and workflows |

For rules and workflows, the returned content includes the refer reminder footer. Context items do not get that footer.

## `memory.refer`

`memory.refer` is the strongest usage signal in the model. It is the point where the agent claims that a loaded constraint actually shaped the turn.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `refs` | object array | yes | one or more declared constraint references |

Each ref object can contain:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `ruleId` | string | yes | stable rule or workflow ID |
| `constraintId` | string | yes | parsed constraint ID |
| `ruleHash` | string | no | current content hash when available |
| `reason` | string | no | human-readable explanation of why the constraint mattered |

### Structured result

```json
{
  "ok": true,
  "count": 2
}
```

`count` is the number of accepted reference objects processed in that call.

## `memory.submit`

`memory.submit` closes a successful turn by recording the agent summary.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `summary` | string | yes | short summary of the completed work |

### Validation

- `summary` must be present
- `summary` must be a string
- `summary` must not be empty

### Structured result

```json
{
  "ok": true
}
```

In the current implementation, this records an `.agent_report` attestation event.

## `memory.reject`

`memory.reject` closes an unsatisfactory turn when the output did not follow loaded constraints.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `reason` | string | no | optional rejection reason |

### Structured result

```json
{
  "ok": true
}
```

In the current implementation, this records a `.reject` attestation event.

## Proposal tools

The proposal tools are the editing side of the protocol. They let an agent stage changes as drafts instead of mutating Library or workspace context directly.

The split is intentional:

- `context.propose_*` operates on workspace-owned context
- `rule.propose_*` operates on Library-owned rules

One detail is worth calling out explicitly: the latest `META_PROMPT` text says `prompt.propose_*` for library-side refinement. The current public MCP implementation still exposes `rule.propose_*`. This page documents the implementation surface as it exists today.

### Create

These tools create a new draft file:

- `context.propose_create`
- `rule.propose_create`

#### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | target path for the new draft |
| `body` | string | yes | draft content |
| `description` | string | no | optional human-facing summary |

#### Structured result

```json
{
  "ok": true,
  "draft_path": "spec/new-context.md"
}
```

### Update

These tools create a modify draft against an existing object:

- `context.propose_update`
- `rule.propose_update`

#### Input

| Tool | Required ID field |
| --- | --- |
| `context.propose_update` | `context_id` |
| `rule.propose_update` | `rule_id` |

Additional fields:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `body` | string | yes | replacement draft body |
| `description` | string | no | optional summary |

The implementation resolves the object through the current manifest, reads the current cached file, computes a base hash, and creates a modify draft from that state.

### Rename

These tools create a rename draft:

- `context.propose_rename`
- `rule.propose_rename`

#### Input

| Tool | Required ID field |
| --- | --- |
| `context.propose_rename` | `context_id` |
| `rule.propose_rename` | `rule_id` |

Additional fields:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `new_path` | string | yes | proposed new path |
| `description` | string | no | optional summary |

### Delete

These tools create a delete draft:

- `context.propose_delete`
- `rule.propose_delete`

#### Input

| Tool | Required ID field |
| --- | --- |
| `context.propose_delete` | `context_id` |
| `rule.propose_delete` | `rule_id` |

Additional fields:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `description` | string | no | optional summary |

## Current error behavior

Several validation and runtime errors are already stable enough to document:

| Situation | Result |
| --- | --- |
| invalid argument types or missing required fields | `isError: true` with an error message |
| unknown tool name | `Unknown tool` |
| `memory.load` receives an unknown rule ID | `Unknown rule id` |
| propose tool path is unsafe | `unsafe path` |
| propose tool target file is missing from current cache/manifest | `file not found in cache` |
| propose create collides with an existing draft | `draft already exists for this path` |

For `memory.submit`, validation is slightly stricter than the schema summary alone suggests. `summary` is required, must be a string, and must not be empty.

## MCP and attestation

The protocol is tightly coupled to attestation, but not in a noisy way.

Each meaningful runtime action records structured local evidence. `memory.search`, `memory.load`, `memory.refer`, `memory.submit`, `memory.reject`, and all proposal tools generate attestation events that later feed Hub-side aggregation.

This is one reason clumsies is different from plain prompt storage. The protocol is not there only to serve content. It is there to make rule use and content-change proposals legible.
