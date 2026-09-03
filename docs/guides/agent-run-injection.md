# AgentRun lifecycle observation

AgentRun records bounded local lifecycle telemetry for supported coding-agent
hosts. It powers Activity and diagnostics; it does not manage tasks or inject a
work protocol into the model.

## Data path

```text
host lifecycle event
  -> managed adapter
  -> clumsiesd _agent agent-run-event --host <host>
  -> resident daemon over XPC
  -> local AgentRun and event rows
```

The short-lived bridge resolves the current workspace's Project binding,
normalizes allowlisted identifiers, and forwards one typed event. It never
opens the database or starts model workers.

## Recorded data

A run may contain the host, bounded host run/session keys, root or subagent
kind, parent run ID, lifecycle phase, outcome, display label, timestamps, and a
revision. The bridge does not persist raw hook JSON, prompts, transcripts, tool
payloads, assistant messages, or workspace paths.

Supported events are start, heartbeat, end, and session end. Duplicate event
IDs are idempotent; reusing an ID for different content is rejected. A new root
turn in the same host session ends a missing prior turn as unknown, and expired
leases are recovered as ended.

## Runtime behavior

Lifecycle delivery is fail-open for the host. Parsing, binding, IPC, or daemon
failures are logged without blocking the agent. The bridge emits no prompt
context and exposes no AgentRun mutation as an MCP tool.

For Codex, the user must review and trust the Clumsies Hook in `/hooks`.
Plugin changes require restarting Codex and starting a new task.
