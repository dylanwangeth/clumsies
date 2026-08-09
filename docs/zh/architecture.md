# 架构

clumsies 是编码 Agent 的协作式外部记忆基础设施：把规则、工作流与项目上下文分发到 Agent，并把本地 Draft 变更同步回组织。

- **Hub**：组织共享记忆的权威来源。
- **Local**：项目专属记忆 + 个人 Draft。
- **daemon**：常驻本地服务，是 Desktop、MCP 与 Agent hook 的统一协调者。
- **Adapter**：把 Codex / Claude Code / opencode 的 lifecycle 事件接入 daemon 的 AgentRun。

（中文文档持续翻译中；英文为准。）
