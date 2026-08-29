# 原生 Issue 看板需求

本文是当前原生 Issue 看板的产品需求基线。实现与一致性设计见
[《原生 Issue 看板设计》](./issue-board-design.md)，Agent 接口见
[《MCP》](./mcp.md)。

## 1. 产品术语

产品对象统一称为 **Issue**，中文界面和文档可写作“议题（Issue）”。
不要把它称为任务：task、turn、run 都是一次临时的 Agent 执行，Issue
则是 Project 内长期存在、可协作、可审查的工作事项。

## 2. 产品原则

Issue 体验沿用编码 Agent 的责任分工：

- 用户用自然语言描述需求并给出反馈；
- Agent 理解语义，通过 `kanban` MCP 工具创建或更新结构化 Issue；
- macOS 看板负责浏览、协作分派和少量明确的人工闸门，不承担正文创作；
- 用户只执行批准关闭、要求修改、释放、恢复、重新打开和归档等窄操作。

macOS 应用不得提供空白新建表单、自由编辑器、拖拽改状态或通用状态选择器。

## 3. 领域边界与权威

Issue 是 Clumsies 的原生领域对象，不是 Memory、Draft、文件路径，也不是
Effective Memory 的投影。两套模型只在一次性迁移时发生联系，此后各自演进。

当前协作边界如下：

| 信息 | 权威位置 | 本机职责 |
| --- | --- | --- |
| Issue 内容、状态、修订和时间线 | Server 中的 Project 级 Issue 记录 | daemon 保留可执行的 SQLite 副本，并在读取时用 Server 快照刷新 |
| 负责人（assignee） | Server | macOS 展示并允许从 Project 成员中重新分派 |
| 跨安装执行占用（claim） | Server 的短期租约 | daemon 在开始或恢复 Agent 工作时申请，在暂停、提请关闭或释放时回收 |
| AgentRun | 当前安装的 daemon | 记录本机执行活动，并投影出 active、stale 等状态 |
| Abandoned、blocked 等看板信息 | daemon 的派生投影 | 由 Issue、依赖、阻塞事实和本机 AgentRun 计算 |

Server Issue 是团队共享记录。`native_issues` 是 daemon 的本地副本和执行存储，
不得再被描述为整个系统唯一的 Issue 权威。负责人和 claim 相互独立：负责人表示
长期责任归属，claim 只表示某个用户的某次 AgentRun 正在处理该 Issue；负责人既
不是写权限，也不会自动取得 claim。

Server 不可用或尚未就绪时，daemon 可以继续使用本地副本，但此时无法提供跨安装
互斥、最新负责人或最新团队快照。产品不得把这种降级模式描述成已经完成团队同步。

## 4. Issue 内容模型

一个原生 Issue 至少包含：

- 稳定的 `(project_id, issue_number)` 身份、全局 `issue_id` 和 Project 内
  `ISSUE-NNN` 键；
- Agent 编写的标题和 Markdown 描述；
- 结构化验收标准；
- 可选的外部 Issue、Pull Request 链接；
- 可选的依赖 Issue 和可检查阻塞事实；
- `todo`、`in_progress`、`paused`、`in_review`、`done` 五种持久状态之一；
- 乐观并发修订号；
- 验证级别，以及需要人工验证时的验证步骤；
- 最近一次语义变更的 `changed_by_run_id`、创建/更新/开始/关闭时间和可选的关闭说明；
- 由 Server 保存的负责人。

Issue 不设自由填写的 `type`、`priority` 或 `components`。在没有受控词表、筛选或
检索语义之前，这些字段只会形成装饰性元数据。当前工作流使用 Project、标题、描述、
状态、验收标准、依赖、阻塞事实和外部关系即可。

外部引用是关系而不是任意元数据。每项只含 `kind`（`issue` 或
`pull_request`）和一个绝对 HTTP(S) URL。daemon 对有界列表做规范化与去重；创建时
省略表示空列表，更新时省略表示保持不变，显式空列表表示清空。provider 从 URL 主机
推导，不单独保存。

`dependencies` 必须指向同一 Project 中的 Issue，不得重复、自指、引用不存在的
Issue 或形成环。`blocking_facts` 是有稳定标识和满足状态的可检查条件，而不是备注。
只要任一依赖未 Done，或任一阻塞事实未满足，Issue 就是 blocked。

## 5. 旧 Memory Issue 迁移

升级时可将 `issues/open|closed/*.md` 中的旧 Memory 资源复制一次到原生 Issue。
迁移完成标记必须与导入事务一起写入，包括没有旧 Issue 的情况。

迁移后：

- 旧 Markdown 仍只是普通 Memory 文档；
- Issue 的列表、详情、变更和状态机不再读取这些文档；
- Issue 变更不会反写 Memory；
- `kanban.export` 只生成确定、可移植的 Markdown 快照，不建立活链接。

## 6. 状态、列与权限

看板显示五列，`paused` 不是第六列，而是在 In Progress 列内显示暂停标记。

| 列 | 持久状态 | 含义 | 状态变更权 |
| --- | --- | --- | --- |
| Todo | `todo` | 已记录但当前没有 Agent 处理 | Agent `kanban.create`，或用户 Reopen |
| In Progress | `in_progress` / `paused` | Agent 已开始、恢复或暂停工作 | Agent `begin_work`、`pause_issue`、`resume_issue`；用户 Request Changes、Resume |
| In Review | `in_review` | 根 Agent 判断验收标准已满足并提请关闭 | 根 Agent `request_closure` |
| Abandoned | 派生 | 无活跃本机 AgentRun 且超过 24 小时无活动的 In Progress Issue | daemon 计算；不会存储 `abandoned` 状态 |
| Done | `done` | 用户接受关闭提议 | 仅用户 Approve |

有效转换如下：

```text
create ------------------------------------------> Todo
Todo ---------------- kanban.begin_work ---------> In Progress
In Progress --------- kanban.pause_issue --------> Paused
Paused -------------- kanban.resume_issue -------> In Progress
Paused -------------- user Release / unclaim ---> Todo
In Progress --------- kanban.request_closure ----> In Review
In Review ----------- kanban.begin_work ---------> In Progress
In Review ----------- user Request Changes ------> In Progress
In Review ----------- user Approve --------------> Done
Done ---------------- user Reopen ---------------> Todo
In Progress --------- user Release / unclaim ----> Todo
```

`kanban.begin_work` 把 Hook 签发的 AgentRun 绑定到 Issue。一个会话最多持有一个
In Progress Issue；开始另一个 Issue 前，必须先暂停当前 Issue 或提请关闭。系统没有
通用 `set_status`；Stop、失败、取消、claim 到期、对话文字或工具返回值都不得自动
推进 Issue。

`Stale` 是筛选条件和标记，不是持久状态。Abandoned 列只是 stale In Progress Issue
的集合，用户需要检查前一个执行者留下的结果，再决定是否 Release。

## 7. 团队分派与 claim

负责人必须是当前 Project 的未禁用成员。新 Issue 首次进入 Server 时，创建者成为
默认负责人；之后用户可在 macOS 中重新分派。重新分派不改变 Issue 内容修订、状态、
AgentRun 或 claim。

联网协作时，开始或恢复 Agent 工作必须先取得 Server claim：

- 同一 Project 的同一 Issue 同时最多有一个未过期 claim；
- claim 标识 claimant、`run_id`、取得时间和租约到期时间；
- 同一 claimant 与 `run_id` 可续期；其他执行者只有在原租约过期后才能接管；
- 活跃 claim 冲突必须明确失败，不得在本地悄悄绕过；
- pause、request closure 或带 `run_id` 的 unclaim 应释放对应 claim；
- claim 到期只解除跨安装互斥，不自动改变 Issue 状态。

离线模式没有 Server claim，因此只能保证当前 daemon 内部的 AgentRun 约束。重新联网
后必须以 Server 快照和 claim 为团队视图，不能假定离线变更已经自动合并。

## 8. Agent 决策

### 提交提示词时

每个受支持的根提示事件都由 Hook 创建或更新 AgentRun，并注入精确的 `run_id` 和
修订号。Agent 需要根据语义判断请求属于：

1. 延续现有 Issue；
2. 新建一个需要长期跟踪的 Issue；
3. 不需要形成 Issue 的临时工作。

对第一种情况调用 `kanban.begin_work`。对第二种情况先调用 `kanban.create`；只有当它
就是当前工作主线时才继续调用 `begin_work`。执行中发现的无关问题只创建为 Todo，
不应抢占当前 Issue。

### 交付完成前

根 Agent 只有在确认所有验收标准已满足后才能调用 `kanban.request_closure`。当
`verification_level` 为 `human_required` 或 `mixed` 时，必须先用 `kanban.update`
补齐人工验证步骤，否则提请关闭应失败。Subagent 可以在明确受派时绑定现有 Issue，
但不能提请关闭。

## 9. MCP 要求

Agent 侧只暴露一个 `kanban` 工具，并以 tagged operation 区分操作：

- `list`：列出当前 Project 的 Issue、claim、本机 AgentRun 投影和修订；
- `get`：按全局 `issue_id`，或按当前 Project 的 `issue_key` 读取完整 Issue；
- `create`：创建 Todo Issue；
- `update`：按预期修订更新语义内容；
- `begin_work`：绑定当前 AgentRun 并进入 In Progress；
- `pause_issue`：暂停当前 run 持有的 In Progress Issue；
- `resume_issue`：由原 run 或显式 takeover 恢复 Paused Issue；
- `unclaim`：MCP 必须携带 Hook 注入的 `run_id`；当前绑定该 Issue 的 run 可把自己的
  In Progress 或 Paused Issue 释放回 Todo；
- `request_closure`：由根 Agent 提请关闭并进入 In Review；
- `export`：生成确定的 Markdown 快照。

用户专属闸门是 daemon 私有操作，不向 Agent 暴露：

- `approve_closure`：In Review → Done；
- `request_changes`：In Review → In Progress；
- `reopen`：Done → Todo；
- 无 run 的人工 Release 或 Resume；其中 Release 只在没有活跃本机 run 时用于 Paused
  或 abandoned In Progress；
- 负责人重新分派。

桌面端还拥有两项清理操作：`archive` 只适用于 Done，并从普通列表隐藏；`delete`
只适用于非 Done，并在删除 Issue 后保留本机 AgentRun 遥测。

`get` 可在没有 Project 提示时解析全局 `issue_id`。列表和所有变更仍受 MCP 绑定的
Project 限制。创建在同一 Project 内原子分配 `001...999` 中最小可用编号；变更拒绝
过期修订，同一 run 不得绑定多个 Issue，重复请求应保持幂等。

## 10. AgentRun 与隐私

AgentRun 是本机执行遥测，不是共享 Issue 权威。daemon 只保留有界的标识、标签、摘要、
时间、父子关系、阶段和租约信息；Hook 不得保存原始提示词、transcript、工具 payload
或 assistant 消息。

Server Issue 快照中的 run attribution 不得被另一安装当作本机活跃 AgentRun。daemon
从 Server 刷新副本时，只保留当前本机确实存在的 `changed_by_run_id`，并用本机
AgentRun 重新计算 active、latest 和 stale 投影。

## 11. macOS 体验

- `Kanban` 是工作区一级入口，`Issue` 是领域实体和 MCP 名称；
- 全局侧栏保持不变，Project 是工具栏筛选条件，看板主体只显示五列；
- 单击选择卡片，双击或 View Details 推入原生详情页，系统 Back 返回原看板状态；
- 卡片显示标题、描述摘要、负责人、claim/handler 状态、最近本机 run、外部引用摘要，
  Paused 卡片显示暂停标记；
- 详情显示标题、Markdown 描述、验收标准、验证协议和状态事件时间线，不显示编辑框或
  “Open in Editor”；
- Todo 显示 Created，In Progress、Paused、In Review 显示 Opened，Done 同时显示
  Opened 和 Closed，不从 AgentRun 推造持续时间；
- 上下文菜单按状态提供复制 ID、分派、Pause、Resume/Take Over、Release、Approve、
  Request Changes、Reopen、Archive、Delete，以及外部链接的打开/复制；
- Done 图标为绿色；应用不提供 New Issue 按钮；
- Project、Stale、blocked、负责人、外部引用和未关联活动可作为筛选或辅助视图；
- 自动轮询不显示常驻状态，只有刷新失败时才出现重试提示，并保留最后一次成功视图。

## 12. 一致性与错误可见性

共享 Issue 更新必须携带预期内容修订，并由 Server 以 CAS 拒绝覆盖并发修改。冲突、
网络失败或 claim 冲突必须返回明确错误，客户端不得声称变更已完成团队同步。

当前 Kanban 没有类似 Memory Draft 的持久 outbox 或自动合并协议。本地事务已经成功、
而 Server 发布失败时，daemon 可以暂时领先于 Server；下一次成功刷新以 Server 快照
重建团队视图。具体失败窗口与恢复边界见
[《原生 Issue 看板设计》](./issue-board-design.md#_9-一致性、失败语义与已知限制)。

## 13. 验收标准

- Issue 作为 Server 共享原生对象存在，且始终独立于 Memory 文件；
- daemon 可从 Server 快照建立本地副本，并在其上叠加本机 AgentRun；
- 首次升级能至多一次导入旧 Memory Issue，并能把已有本地原生 Issue 导入空的
  Server Issue 集；
- Project 成员可以被设为负责人；分派不会等同于 claim 或授权；
- 两个用户并发申请同一 Issue 的有效 claim 时最多一个成功；
- Agent 可通过 MCP 创建、更新、列出和导出 Issue，而不使用 `memory.store`；
- 全局 `issue_id` 可解析出所属 Project，`ISSUE-NNN` 只在 Project 内有效；
- `begin_work` 进入 In Progress，Stop 和 claim 到期均不自动改变 Issue 状态；
- 根 Agent 可提请关闭但不能批准自己完成，只有桌面 Approve 能进入 Done；
- Request Changes、Reopen、Release、Pause、Resume 都是显式、受校验且修订安全的操作；
- 看板只显示五列，Paused 位于 In Progress，Abandoned 始终是派生列；
- 卡片和详情显示真实 Issue 生命周期时间，不用 AgentRun 时间替代；
- UI 不提供直接正文创作，并正确展示负责人、共享 claim 和本机 run 的区别；
- 并发冲突或 Server 发布失败对调用方可见，不会被误报为同步成功；
- `kanban.export` 生成确定、可移植且不与 Memory 建立活链接的 Markdown 快照。
