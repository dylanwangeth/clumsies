---
name: complete-task
description: Mark the current task as completed or abandoned
argument-hint: "[--abandon]"
user-invocable: true
---
Call the `memory.complete` MCP tool to finalize the current task.

- Default status: `completed`
- If `$ARGUMENTS` contains `--abandon`, use status: `abandoned`

The taskId is available from the session start message.
