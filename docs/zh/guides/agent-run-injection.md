# Agent run 注入

生命周期 hook 把 run_id 与 revision 注入 Agent 上下文；Agent 据此调用
`kanban.begin_work` / `kanban.request_closure` 绑定并推进 Issue。
一个 session 同时只能持有一个 In Progress Issue；换 Issue 前先 pause
或 request_closure。

Codex 与 Claude Code 的第一次根 Stop 只记录非终态 decision probe，并让
Agent 自己判断是否应调用 `request_closure`；后续 Stop 才结束 AgentRun。
opencode 使用 plugin API 转发同一组事件，dsh 使用相同的 lifecycle 词汇。
Stop 本身不会推进、批准或关闭 Issue。Hook 输入会缩减为有限的 lifecycle
标识，prompt、transcript 和 tool payload 不进入 daemon。

（中文文档持续翻译中；英文为准。）
