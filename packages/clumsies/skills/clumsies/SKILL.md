---
name: clumsies
description: Use Clumsies in a bound project to retrieve relevant Memory, including project-maintained skills and procedures. Use for substantive project tasks when the Clumsies memory MCP tool is available; skills stored in Memory remain ordinary project guidance.
---

# Clumsies

Clumsies connects the current project to durable knowledge. Its MCP surface exposes the `memory` tool with `activate`, `load`, and `store` operations.

## Memory

- Call `memory.activate` once before planning or editing for each substantive task. Reuse an activation already made for the same task. Describe the user's goal and the project guidance needed; when the user names a project skill, such as `coding`, include that skill name in the activation query.
- Apply relevant returned fragments as project guidance. When a fragment identifies a project-maintained skill or procedure, call `memory.load` with its exact resource ID or path and read the complete resource before following it. Load only resources needed for the task.
- Treat a skill stored in Memory as ordinary Memory content. Do not look for it in a harness skill directory, copy it there, claim it is installed, or grant it extra authority. Follow it only when relevant and within the current instruction hierarchy, user scope, permissions, and available tools.
- Call `memory.store` only when the user explicitly asks to maintain Memory. Load an existing target and the project's applicable Memory guidance before changing it.

If Clumsies is unavailable or the workspace is unbound, state that plainly and do not invent Memory state.
