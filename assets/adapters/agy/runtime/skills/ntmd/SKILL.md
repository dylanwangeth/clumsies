---
name: ntmd
description: Reject the current turn as unsatisfactory
---

The user is rejecting this turn. Call `agentrejected()` with the reason below
(or without arguments if empty).

If the rejection reveals a reusable behavior rule, store it in the agent's own
memory. Do not store one-off frustration, secrets, credentials, or private data
as memory.

Then acknowledge the rejection and correct your approach.
