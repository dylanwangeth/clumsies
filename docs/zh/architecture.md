# 架构

clumsies 是编码 Agent 的协作式外部记忆基础设施：把规则、工作流与项目上下文分发到 Agent，并把本地 Draft 变更同步回组织。

- **Hub**：组织共享记忆的权威来源。
- **Local**：项目专属记忆 + 个人 Draft。
- **常驻 `clumsiesd`**：由 launchd 管理的 Rust 本地服务，独占数据库、模型、同步与检索任务。
- **Agent runtime proxy**：同一份 App 内签名的 `clumsiesd` 以 `mcp serve` 或 `_agent` 短进程模式运行，通过 XPC 转发给常驻服务。
- **Adapter**：把 Codex / Claude Code / opencode 固定到 App 内的 `clumsiesd` 路径，并接入 MCP 与 AgentRun lifecycle。

（中文文档持续翻译中；英文为准。）
