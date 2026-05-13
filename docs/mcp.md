# MCP

## What MCP does here

MCP is the agent-facing protocol surface for clumsies. It is how an agent discovers available material, loads the specific rules, workflows, and context it needs, declares which constraints it actually applied, and proposes edits back into the system.

That makes MCP more than a transport layer. It is the runtime contract between agent work and the managed rule, context, and attestation model.

## The current tool surface

The current implementation exposes these MCP tools:

| Tool family | Tools |
| --- | --- |
| session and attestation | `memsetup`, `memdisc`, `memload`, `memref`, `agentreport`, `agentrejected` |
| artifact mutations | `artifact` |

This is the real protocol surface in the running code. The server test suite explicitly asserts that `memory.begin`, `memory.complete`, `memory.startup`, `memory.list`, and `memory.activate` are not part of the public tool list.
The older `context.propose_*`, `rule.propose_*`, and `draft` tool surfaces are
also not public MCP tools anymore; local content changes go through
`artifact`.

## The core runtime cycle

The stable mental model now matches the current `META_PROMPT` very closely:

1. bootstrap the session with `memsetup`
2. discover relevant material with `memdisc`
3. load only the content the task actually needs with `memload`
4. apply the loaded rules in the work
5. declare applied constraints with `memref`
6. use `artifact` when the task is to refine rules, context, or MPF
7. close the turn with `agentreport` or `agentrejected`

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

## `memsetup`

`memsetup` bootstraps the session. It returns the current workspace identity, the current session ID, and the current `META_PROMPT` frame.

`memsetup` is a binding operation. The caller must pass the real host session
or thread ID supplied by the adapter. Agents should call it once at session
startup, before any other clumsies MCP tool. Repeated calls are only for an
explicit user-invoked setup flow.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `session_id` | string | yes | host-agent session or thread id |
| `knownHashes` | object map | yes | must include `META_PROMPT.md`; pass the remembered hash, or `""` when unknown |

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

## `memdisc`

`memdisc` discovers available rules, workflows, and context files without loading their full content.

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
| `hasDraft` | whether the object currently has a local draft |

Discover is inventory, not content delivery. Its job is to let the agent
choose what is relevant before spending context window on full content.

Create-only drafts have no Hub-issued object ID yet. The client assigns them a
deterministic `tmp-*` ID when the draft is created, and `memdisc` exposes that
temporary ID as the public `id`. Agents should use that ID for later
`memload` calls or for `artifact` operations such as `delete` and `discard`.
Draft paths are not a public identity for create-only drafts.

## `memload`

`memload` resolves full content for the selected IDs. This is where protocol flow stops being inventory and becomes working task context.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `ids` | string array | yes | one or more rule, workflow, or context IDs |
| `knownHashes` | object map | yes | `{id: hash}` map for delta loading; include every requested id |

Each `ids` entry must also be present in `knownHashes`. Pass the remembered
hash when available. Pass an empty string when the caller explicitly does not
know the hash yet. Omitting `knownHashes`, or omitting one requested id from the
map, is invalid.

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
| `constraints` | referable rule/workflow constraint entries parsed from the loaded content |

For rules and workflows, the returned content includes the refer reminder footer. Context items do not get that footer.

Delta loading only suppresses repeated content text. For rule and workflow
items, `constraints` are still returned when `changed` is `false` and
`content` is `null`, because agents need those stable entries to call
`memref` without guessing from markdown.

In this protocol, a constraint is a referable semantic markdown section in a
rule or workflow file. It is either a whole H2 section, or one list item inside
an H2 section. A whole H2 section uses the H2 title as its stable returned
`id`. A list item uses `H2 title/ordinal`, such as `Steps/1` and `Steps/2`.
The `name` field is the H2 title used for display/grouping, and `text` is the
H2 body or list item content. Agents must copy the returned `id` exactly into
the `constraintId` wire field in `memref`; they must not invent IDs.

## `memref`

`memref` is the strongest usage signal in the model. It is the point where the agent claims that one of the `constraints` entries returned by `memload` for a rule or workflow actually shaped the turn.

Context files are reference material, not refer targets. A context ID supplied as `ruleId` is rejected.

### Input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `refs` | object array | yes | one or more declared constraint references |

Each ref object can contain:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `ruleId` | string | yes | stable rule or workflow ID |
| `constraintId` | string | yes | wire field containing an exact returned `constraints[].id` value |
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

### Retryable errors

`memref` validation errors are structured so agents can retry instead
of treating the text message as opaque. Unknown rule/workflow IDs tell the
agent to rediscover and reload. Unknown constraint IDs include the valid
constraint candidates for that rule/workflow when available.

Example invalid constraint response:

```json
{
  "error": "memref constraintId 'Step' is not valid for ruleId 'p-...'; retry with one of: Steps",
  "code": "unknown_constraint",
  "retryable": true,
  "retryAction": "retry_with_valid_constraint",
  "validConstraints": [
    {
      "id": "Steps",
      "name": "Steps",
      "text": "Inspect the diff and suggest a commit message."
    }
  ]
}
```

Agents should use `validConstraints[].id` exactly.

## `agentreport`

`agentreport` closes a successful turn by recording the agent summary.

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

## `agentrejected`

`agentrejected` closes an unsatisfactory turn when the output did not follow loaded constraints.

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

## `artifact`

`artifact` stages local changes for Artifact rules, workspace context, or MPF.
Those local changes are stored as drafts until they enter review.

The input is a tagged command object:

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

`op` must contain exactly one key. The protocol has one public MCP tool,
and payloads stay typed.

### Top-level input

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `resource` | string enum | yes | one of `context`, `rule`, or `mpf` |
| `op` | tagged object | yes | tagged operation |

### `create`

Creates a new local artifact change.

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

### `update`

Creates or updates an `update` change against an existing object. For `context` and
`rule`, the implementation resolves `id` through the manifest, reads the
current cached file, computes a base hash, and writes the local draft form. For
MPF, `id` should be `META_PROMPT.md`.

If a matching update draft already exists, `update` replaces its content and
keeps it in draft state. This is what allows agents to refine a local context
or rule draft through MCP instead of writing draft files directly.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | context id, rule id, or `META_PROMPT.md` |
| `body` | string | yes | replacement draft body |
| `description` | string | no | optional summary |

### `rename`

Creates a rename change. `rename` is valid for `context` and `rule`; MPF
has the reserved path `META_PROMPT.md` and cannot be renamed.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | context id or rule id |
| `new_path` | string | yes | proposed new path |
| `description` | string | no | optional summary |

### `delete`

Creates a delete draft for an existing resource. If `delete` targets a
create-only draft with no manifest entry, the client treats the call as
discarding that create draft. In that create-only case, `id` must be the
`tmp-*` local ID returned by `memdisc`; draft paths are not accepted as public
identity.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | resource id, create-draft temp id, or MPF |
| `description` | string | no | optional summary |

### `discard`

Discards an existing draft object. This is different from `delete`:
`delete` proposes deletion of a real resource. `discard` removes an
unsubmitted draft.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | any draft or resource identifier |

## Current error behavior

Several validation and runtime errors are already stable enough to document:

| Situation | Result |
| --- | --- |
| invalid argument types or missing required fields | `isError: true` with an error message |
| unknown tool name | `Unknown tool` |
| `memsetup` omits `knownHashes.META_PROMPT.md` | `isError: true` with an invalid params error |
| `memload` omits `knownHashes` or an entry for a requested ID | `isError: true` with an invalid params error |
| `memload` receives an unknown rule ID | `Unknown rule id` |
| `memref` receives an unknown rule/workflow ID | structured `code: "unknown_rule_or_workflow"`, `retryable: true`, `retryAction: "rediscover_and_reload"` |
| `memref` receives an invalid constraint ID | structured `code: "unknown_constraint"`, `retryable: true`, `retryAction: "retry_with_valid_constraint"`, optional `validConstraints` |
| artifact path is unsafe | `unsafe path` |
| artifact target is missing | `file not found in cache` |
| artifact update conflicts with a non-update local draft | `artifact already has an incompatible local change` |
| artifact delete targets a create-only draft by path | `file not found in cache` |
| create collides with an existing draft | `draft already exists` |

For `agentreport`, validation is slightly stricter than the schema summary alone suggests. `summary` is required, must be a string, and must not be empty.

## MCP and attestation

The protocol is tightly coupled to attestation, but not in a noisy way.

Each meaningful runtime action records structured local evidence.
`memdisc`, `memload`, `memref`, `agentreport`,
`agentrejected`, and `artifact` operations generate attestation events that
later feed Hub-side aggregation.

This is one reason clumsies is different from plain prompt storage. The protocol is not there only to serve content. It is there to make rule use and content-change proposals legible.
