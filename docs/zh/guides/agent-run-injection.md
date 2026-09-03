# AgentRun 生命周期观测

AgentRun 只记录受支持 Coding Agent 宿主的本地、有界生命周期遥测，用于 Activity 与诊断。
它不管理任务，也不会向模型注入工作协议。

## 数据路径

```text
宿主生命周期事件
  -> 受管 Adapter
  -> clumsiesd _agent agent-run-event --host <host>
  -> 通过 XPC 到常驻 daemon
  -> 本地 AgentRun 与事件记录
```

短进程 bridge 解析当前 workspace 的 Project binding，只保留允许的标识字段，再转发一条
强类型事件。它不会打开数据库，也不会启动模型 worker。

## 记录内容

Run 可以包含宿主、有界的 run/session key、root 或 subagent 类型、parent run ID、生命周期
阶段、结果、显示标签、时间戳与 revision。Bridge 不保存原始 Hook JSON、prompt、
transcript、tool payload、assistant message 或 workspace path。

支持的事件是 start、heartbeat、end 与 session end。同一 event ID 重试保持幂等；相同 ID
携带不同内容会被拒绝。同一宿主 session 出现新的 root turn 时，遗漏结束事件的旧 turn 会
以 unknown 收束；过期 lease 也会恢复为 ended。

## 运行行为

生命周期投递对宿主 fail-open。解析、binding、IPC 或 daemon 失败只记录日志，不阻塞 Agent。
Bridge 不输出 prompt context，也不通过 MCP 暴露 AgentRun mutation。

Codex 用户需要在 `/hooks` 中审查并信任 Clumsies Hook。Plugin 更新后应重启 Codex 并创建
新任务。
