# AgentRun 生命周期与 Hook 注入

本文说明 resident daemon 如何观察编码 Agent 生命周期、可信 `run_id` 如何到达 Agent，
以及为什么 Issue 的语义状态不能由 Hook 自动决定。Issue 状态机和共享 claim 见
[《原生 Issue 看板设计》](../issue-board-design.md)。

## 1. 为什么 `run_id` 必须来自 Hook

`AgentRun` 是 daemon 对一次根 turn 或 subagent 执行的本机记录，用于：

- 为 Issue mutation 提供可审计的执行身份；
- 区分 root 与 subagent 的权限；
- 用 revision 做乐观并发；
- 用 lease、phase 和 outcome 判断本机执行是否仍活跃；
- 在 host 异常结束或新根 turn 到来时恢复生命周期。

如果让 Agent 在提示词里自报身份，它可以误用、伪造或复用另一 run，daemon 也无法证明
调用来自哪个 host turn。Hook 位于 host 与 Agent 之间：它能在 Agent 开始推理前观察
真实 turn/subagent 标识，在 session 结束或失败后继续报告生命周期，因此是 `run_id` 的
签发和注入边界。

这不表示 Hook 有权决定 Issue。Hook 只报告“发生了什么”；是否创建 Issue、绑定哪条
Issue、何时满足验收标准，仍由 Agent 基于任务语义显式调用 Kanban MCP。两条路径必须
保持分离：

```text
Host Hook 事实          -> record_agent_run_event -> AgentRun 生命周期
Agent/用户语义判断      -> kanban MCP             -> Issue 状态转换
```

因此系统既不根据提示词文本匹配 Issue，也不把正常停止、失败、取消或 lease 到期推断为
完成。

## 2. 进程边界

受管理 Hook 和 opencode plugin 调用 App bundle 内同一份签名 Rust runtime：

```text
Agent host
  -> clumsiesd _agent issue-run-event --host <host>
  -> 校验 resident protocol revision 与 build identity
  -> 用当前目录解析 canonical Project
  -> 将 host JSON 归一化为有界类型请求
  -> 通过 XPC 转发给 resident clumsiesd
```

`_agent issue-run-event` 是短生命周期代理模式，不初始化 SQLite、模型、检索 worker 或
同步 worker。adapter 固定使用 App bundle 中的绝对路径，不从 checkout、`PATH` 或辅助
目录寻找可执行文件。

## 3. 身份、修订与幂等

daemon 以 `(project_id, host, host_run_key)` 唯一确定一条 AgentRun，并生成
`arun_` 加 32 位小写十六进制的 `run_id`。host 过长的 session/turn/subagent 标识会先
哈希，再形成有界 `host_run_key`；subagent 另保存 parent run 关系。

每条 run 从 revision 1 开始，生命周期更新会推进 revision。Kanban `begin_work` 必须带
Hook 注入的 `run_id` 和预期 revision；不存在、来源不可信或已过期的 run 不能由 Agent
临时补造。运行态 lease 由 daemon 数据库时钟续为 24 小时，lease 过期只影响 active/stale
投影，不自动改变 Issue 状态。

每个归一化 Hook 事件还具有确定的 `event_id` 和内容 fingerprint。相同事件重放是幂等
no-op；同一 ID 携带不同内容会被拒绝。新根 turn 在同一 host session 中启动时，daemon
会 recovery-end 尚未结束的前一根 turn，再创建新 run；这只是生命周期记账，不表示新
turn 延续旧 Issue。

## 4. 当前 host 事件映射

| Host | 观察事件 | 接入面 |
| --- | --- | --- |
| Codex | `UserPromptSubmit`、`SubagentStart`、`SubagentStop`、`SessionEnd` | App 管理的全局 Clumsies Plugin Hook；用户需通过 `/hooks` 信任当前 hash；不写仓库 Hook，不注册根 `Stop` |
| Claude Code | 上述事件及 `StopFailure` | `.claude/settings.json` 指向受管理 shell Hook；不注册根 `Stop` |
| Antigravity | `PreInvocation` | `.agents/hooks.json` 指向受管理 shell Hook；不注册根 `Stop` |
| opencode | 用户消息、失败的 assistant 消息、session 删除 | 受管理 plugin 映射为 `UserPromptSubmit`、`StopFailure`、`SessionEnd`；成功结束不合成 `Stop` |
| dsh | turn start、失败 turn、session disposal | dsh client plugin 非阻塞转发根事件；成功结束不合成 `Stop` |

兼容桥仍接受旧安装或人工 Hook 发送的 `Stop`，但只记录终止观察，不返回 block 决策、不
调用 Kanban，也不推进 Issue。

## 5. 注入给 Agent 的上下文

根 `UserPromptSubmit` 或 `SubagentStart` 成功记录后，代理向 host 输出原生 JSON，其中
`additionalContext` 只包含当前 run 的 ID、revision 和已有 Issue 绑定提示。

根 Agent 被要求：

1. 用 `kanban.list` 或 `kanban.get` 读取真实看板；
2. 语义判断当前请求是延续 Issue、新建长期 Issue，还是无需落盘的临时工作；
3. 仅在该 Issue 是当前工作主线且没有其他 active run 时调用 `kanban.begin_work`。

Subagent 可以在明确受派时绑定已有 Issue，但不能请求关闭；它应把结论交回根 Agent。
关闭策略不由生命周期 callback 注入，只有 opt-in skill 或人工维护的工作流在确认验收
标准后，才显式调用 `kanban.request_closure`。

## 6. 正常根 Stop 不受管理

当前 adapter 不注册或合成正常根 `Stop`，代理也不会要求 host 阻止退出以追加关闭提醒。
`StopFailure` 记录失败结果，`SubagentStop` 结束 subagent 观察，`SessionEnd` 结束该 session
尚存的 run。这样生命周期遥测不会反过来控制 Agent 的完成流程。

即使 Hook 没有收到终止事件，24 小时 lease 和 daemon 启动恢复也只会让 run 不再 active；
Issue 仍保持原状态，等待 Agent 或用户显式处理。

## 7. 隐私与失败语义

代理最多读取 1 MiB host 输入，并在内存中缩减为 allowlist：session、turn/agent 标识、
parent key、workspace path、有界显示标签、事件类型和 outcome。原始提示词、transcript、
assistant 消息、工具输入和原始失败详情不会跨 XPC，也不会被此链路持久化。

Hook wrapper 必须 fail-open：输入损坏、Project 未绑定、runtime 身份不匹配或 XPC 失败都
不能阻止 Agent host 继续运行。代价是本次没有可信 AgentRun；Memory 读取和不依赖 run
的 Kanban 读取仍可进行，但 `begin_work`、pause、unclaim 和 closure 等 run-bound 操作
必须等待真实 Hook 注入，不能回退为 Agent 自报 ID。

Codex 对新增或变更的 Plugin Hook 还受用户 `/hooks` 信任决定约束，Clumsies 不绕过该
边界。

## 8. 实现定位

| 关注点 | 当前代码 |
| --- | --- |
| 代理分派、runtime 身份校验与上下文注入 | `crates/daemon/src/main.rs` |
| host payload 归一化、event ID 与 host run key | `crates/daemon/src/agent_runtime/hook.rs` |
| AgentRun 持久化、revision/lease 与 Issue 绑定 | `crates/daemon/src/work_tracking.rs` |
| adapter 渲染与迁移 | `crates/daemon/src/agent_adapter.rs` |
| Codex Plugin reconciliation | `crates/daemon/src/agent_adapter/codex_plugin.rs` |
| 直接文件 Hook 模板 | `assets/adapters/*/runtime/hooks/issue-run-event.sh.tpl` |
| opencode plugin | `assets/adapters/opencode/runtime/plugin.ts` |

私有 Hook bridge 不是 MCP 工具；反过来，`kanban.begin_work`、pause、resume、unclaim 和
`request_closure` 也不伪装成 host 生命周期事件。
