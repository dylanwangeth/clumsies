---
name: activate
description: Activate available managed agent memory
argument-hint: "[task or retrieval cue]"
user-invocable: true
---
Call the `memory` MCP tool once with `op: { activate: { query: "..." } }` describing
the current task or retrieval cue. Use `$ARGUMENTS` when provided; otherwise
derive the query from the current user task.

Apply the returned fragments directly. Pass a prior `next_state` only when its
earlier fragments are still present in the current model context; omit state
when starting fresh or after context compaction.

$ARGUMENTS
