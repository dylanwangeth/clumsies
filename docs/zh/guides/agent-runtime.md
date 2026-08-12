# Agent 运行时

Agent host 通过 App 内同一份签名的 Rust `clumsiesd` 使用两个短进程入口：

```text
clumsiesd mcp serve
clumsiesd _agent issue-run-event --host <host>
```

- launchd 常驻模式独占数据库、模型、同步与检索 worker。
- MCP / Hook proxy 启动时校验常驻 daemon 的协议版本和 build identity，再通过 XPC 转发。
- Adapter 固定使用 App 内路径，不搜索 `PATH`、worktree 构建产物或旧 helper。
- AgentRun 只记录 lifecycle；看板状态由 Agent 显式调用 `kanban` 工具推进。

（中文文档持续翻译中；英文为准。）
