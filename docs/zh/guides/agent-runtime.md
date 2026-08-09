# Agent 运行时

运行时面包括 CLI、MCP 与 Agent hook。常驻 daemon 是唯一协调者：

- Desktop 与 MCP 通过 daemon 读写 Draft。
- Agent hook（Codex / Claude Code / opencode）把 lifecycle 事件送入 daemon 的 AgentRun 记录。
- AgentRun 绑定到原生 Issue，看板状态由 Agent 显式调用 `kanban` 工具推进。

（中文文档持续翻译中；英文为准。）
