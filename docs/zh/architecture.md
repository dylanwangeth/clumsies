# 架构

clumsies 是编码 Agent 的协作式外部记忆基础设施：把规则、工作流与项目上下文作为统一的 **Memory** 对象分发到 Agent，并把本地 Draft 变更同步回组织。

- **Memory**：唯一的头等内容对象（Markdown 正文 + 必填语义 `description` + 稳定 ID）。组织是唯一权威作用域；Project 只选择组织记忆、维护物化 Ref，并承载合并前仅在该 Project 生效的组织 Draft overlay。历史 Project scope 只用于迁移兼容。
- **常驻 `clumsiesd`**：由 launchd 管理的 Rust 本地服务，独占数据库、模型、同步与检索任务。
- **Agent runtime proxy**：同一份 App 内签名的 `clumsiesd` 以 `mcp serve` 或 `_agent` 短进程模式运行，通过 XPC 转发给常驻服务。
- **Adapter**：把 Codex / Claude Code / opencode / dsh 固定到 App 内的 `clumsiesd` 路径，并接入 MCP 与 AgentRun lifecycle。
- **Kanban**：原生 Issue 看板（Todo / In Progress / Paused / In Review / Abandoned / Done）；Agent 显式调用 `kanban` 工具推进状态，用户闸门决定最终关闭。

（中文文档持续翻译中；英文为准。）
