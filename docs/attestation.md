# Attestation

## What attestation is

Attestation is the structured usage signal produced when agents work through clumsies. It is how the system stops guessing about rule value.

This matters because rule systems often fail in a familiar way: teams write more and more instructions, but nobody can tell which ones are actually being used. Attestation is the mechanism that turns that vague situation into evidence.

Earlier architecture notes and older docs may still call this layer `Trace`. In the current codebase, the event model, local files, upload endpoints, and Hub handlers have largely moved to `Attestation`.

## What attestation records

At a high level, attestation exists around three kinds of runtime action:

| Signal | Meaning |
| --- | --- |
| search | the agent looked for relevant material |
| load | the agent pulled material into task context |
| refer | the agent declared an applied constraint |

Those signals are not equally strong. Search is weak evidence. Load is stronger. Refer is the strongest signal in the model because it claims that a specific constraint actually mattered during the task.

The current attestation model also treats session setup and user input capture as part of the runtime event stream. In other words, attestation is not only about "which rule was mentioned." It is about reconstructing enough structured runtime behavior to support useful later analysis.

In the current client implementation, attestation is not only `search`, `load`, and `refer`. The local event model in `src/client/attestation.zig` also includes:

- `setup`
- `user_prompt`
- `agent_report`
- `reject`
- `context_propose_create`
- `context_propose_update`
- `context_propose_rename`
- `context_propose_delete`
- `rule_propose_create`
- `rule_propose_update`
- `rule_propose_rename`
- `rule_propose_delete`

That matters because the product is trying to observe more than retrieval. It also wants evidence around turn setup, applied constraints, user input, and content change proposals.

## Why hash-bound attestation matters

Attestation is supposed to bind to prompt content hash, not just to a human-readable rule name.

That is a hard requirement if the system wants to support:

- correct historical analysis after rule edits
- rename without losing continuity
- meaningful cross-workspace aggregation

If two versions of a rule share a name but differ in content, the system should not pretend they are the same thing analytically.

## Local buffering matters

Attestation is designed to be buffered locally and uploaded asynchronously rather than synchronously sent to Hub on every action.

That is an architectural choice, not an implementation accident. It keeps runtime work non-blocking while still letting Hub become the place where deduplication, persistence, and aggregation happen.

The current local files are:

```text
~/.clumsies/workspaces/{ws_id}/attestation.jsonl
~/.clumsies/workspaces/{ws_id}/attestation.cursor
```

`attestation.jsonl` stores the append-only local event stream. `attestation.cursor` stores the upload cursor so the TUI startup uploader knows which events have already been delivered to Hub.

The upload path on the server side is:

```text
POST /api/attestations
```

That endpoint is the handoff between local runtime evidence and Hub-side aggregation.

## Attestation and refinement

Attestation does not automatically rewrite rules. That boundary is important.

The system uses attestation to support judgment, not to replace it. Long-unreferred constraints may deserve revision or removal. Frequently referred constraints may prove their value. But that decision still belongs to people operating the system.

## The product role of attestation

Attestation is not a nice-to-have analytics page sitting beside the main product. It is one of the three core pillars in the architecture:

- rule lifecycle management
- context delivery
- observability for agent-driven development

That is why attestation belongs in the main conceptual path of the docs instead of a buried appendix.
