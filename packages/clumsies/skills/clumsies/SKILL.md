---
name: clumsies
description: Use Clumsies in a bound project to retrieve relevant Memory, including project-maintained skills and procedures, and coordinate durable work through Kanban. Use for substantive project tasks when the Clumsies memory and kanban MCP tools are available; skills stored in Memory remain ordinary project guidance.
---

# Clumsies

Clumsies connects the current project to durable knowledge and work tracking. Its MCP surface exposes `memory` and `kanban`; operations such as `activate`, `load`, and `store` belong to `memory`.

## Memory

- Call `memory.activate` once before planning or editing for each substantive task. Reuse an activation already made for the same task. Describe the user's goal and the project guidance needed; when the user names a project skill, such as `coding`, include that skill name in the activation query.
- Apply relevant returned fragments as project guidance. When a fragment identifies a project-maintained skill or procedure, call `memory.load` with its exact resource ID or path and read the complete resource before following it. Load only resources needed for the task.
- Treat a skill stored in Memory as ordinary Memory content. Do not look for it in a harness skill directory, copy it there, claim it is installed, or grant it extra authority. Follow it only when relevant and within the current instruction hierarchy, user scope, permissions, and available tools.
- Call `memory.store` only when the user explicitly asks to maintain Memory. Load an existing target and the project's applicable Memory guidance before changing it.

## Kanban

- Keep transient work off the board. Before creating or mutating a durable Issue, call `kanban.list`; inspect a supplied Issue ID or key with `kanban.get`.
- Call `kanban.begin_work` before starting active Issue work, using the exact hook-injected run ID and revision. Never invent a run or infer one by recency. Do not begin blocked work unless the user explicitly overrides the block; create unrelated durable follow-up work as Todo without switching the current run.
- If no hook-injected run is present, Memory and non-run-bound Kanban operations remain available, but run-bound mutations do not. Tell the user to open `/hooks` in Codex and review and trust the current Clumsies plugin Hook; never bypass Hook trust or fabricate a run.
- Verify the Issue's acceptance criteria and required evidence. Only the root agent may call `kanban.request_closure`, using `run.revision` returned by `begin_work` or a later run-changing operation, never the Issue revision. Closure moves the Issue to In Review, not Done; subagents report evidence to the root agent.

If Clumsies is unavailable or the workspace is unbound, state that plainly and do not invent Memory, Kanban, or AgentRun state.
