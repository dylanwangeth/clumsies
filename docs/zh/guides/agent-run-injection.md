# Agent run 注入

生命周期 hook 把 run_id 与 revision 注入 Agent 上下文；Agent 据此调用
`kanban.begin_work` / `kanban.request_closure` 绑定并推进 Issue。
一个 session 同时只能持有一个 In Progress Issue；换 Issue 前先 pause
或 request_closure。

（中文文档持续翻译中；英文为准。）
