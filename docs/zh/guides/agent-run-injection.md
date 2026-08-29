# Agent run 注入

生命周期 hook 把 run_id 与 revision 注入 Agent 上下文；Agent 据此调用
`kanban.begin_work` / `kanban.request_closure` 绑定并推进 Issue。
一个 session 同时只能持有一个 In Progress Issue；换 Issue 前先 pause
或 request_closure。

纳管适配器不再安装或自动转发正常根 `Stop`，proxy 也不会阻断宿主来注入
closure 提醒。是否满足验收条件、何时调用 `request_closure`，由可选 skill
或人工维护的 Agent 工作流显式决定；否则 Issue 保持 In Progress。

`StopFailure`、`SubagentStop` 与 `SessionEnd` 等非侵入性生命周期仍会记录。
同一宿主 session 开始新的根 turn 时，daemon 会先以 recovery 结束仍在运行的
旧根 turn；这只维护生命周期，不推进旧 Issue，也不推断新 turn 继续该 Issue。
`SessionEnd` 会结束最后尚未结束的 turn。
为清理旧安装，bridge 继续兼容旧 Hook 或手动发送的 `Stop`，但只把它作为
AgentRun 遥测：不会返回 block、调用 `kanban`，也不会推进、批准或关闭
Issue。Hook 输入会缩减为有限的 lifecycle 标识，prompt、transcript 和
tool payload 不进入 daemon。
