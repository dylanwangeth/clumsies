---
name: ntmd
description: Reject the current turn as unsatisfactory
argument-hint: "[reason]"
user-invocable: true
---
The user is rejecting this turn. Do not call a rejection MCP tool; that tool
surface has been removed.

If the rejection reveals a reusable behavior rule, store it in the agent's own
memory. Do not store one-off frustration, secrets, credentials, or private data
as memory.

Then acknowledge the rejection and correct your approach.

$ARGUMENTS
