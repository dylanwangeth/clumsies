# 术语表

## Server

共享权威服务。负责 Organization Memory、Project 选择与投影、Bundle、Draft/Review、
Blob/Tree/Commit/Ref、身份授权，以及 Server 共享的 Kanban Issue/claim。它不负责本机
工作目录、检索模型或 AgentRun。

## Memory

clumsies 唯一的一等内容对象。active 发布权威只存在于 Organization scope。Memory
拥有稳定 opaque ID、可变路径、Server `name`、语义 `description`、Markdown 正文、
revision 与状态（`active`、`deprecated`、`archived`）。daemon 的展示标题从 Markdown
第一个标题或路径派生。

新对象使用 `mem_` 前缀；历史 `ctx_`、`rul_`、`wfl_` ID 保持稳定。重命名改变路径与
`name`，不改变 ID。`description` 会作为独立检索字段，但当前链路仍可能为空或在 merge
时未持久化，不能把它描述为已端到端强制。

## Rule、Workflow、Context

旧版封闭 Memory 类型。当前它们只是正文表达的角色：Rule 是行为约束，Workflow 是可
复用步骤，Context 是背景或证据。Server、daemon 主链与 MCP 不再按这三种类型分派；
macOS 残留的 `MemoryKind` 属于待清理兼容实现。

## Organization authority

Organization Memory 的唯一发布 Ref 与 Commit 历史。所有 active Memory 的 create、
update、rename、delete 最终都必须经 Organization-scoped Draft、Review 和 merge 发布。

## Project

Server 签发的仓库绑定、成员授权、Organization Memory 选择、投影 Ref 与 Draft carrier。
Project 不是 Memory authority scope，也不等于本机文件夹。`Workspace` 是已退役旧称。

## Project view / Effective Memory

Project view 包含该 Project 选择的 Organization Memory 投影。daemon 在已安装投影上叠加
该 Project 携带的 `open` / `submitted` Draft，形成 Effective Memory。Project Ref 只
版本化投影，不是第二个发布头。

## Project binding

daemon 本机状态，把“规范 Server authority + canonical workspace root”映射到规范
`project_id`。managed host-plugin 必须从当前目录解析绑定；普通 `mcp serve` 在没有目录
绑定时可以兼容使用 Desktop 当前选中的 Project。旧 `ws_id` 不是 Project 身份，当前
runtime 不再读取或迁移 `~/.clumsies/config.toml`。

## Project Local Storage

当前安装为某个 Project 保存可重建 Commit generation 和检索索引的位置。设置以 Server
authority 与 `project_id` 为键，不进入 Server Project 元数据，也不跨安装同步。自定义
目录只作为 marker-owned `.clumsies/cache-v1` 子树的父目录；Draft、队列、凭据和共享
模型仍留在中心存储。

## Bundle

某成员保存在 Server 的 Organization Memory ID 集合（`resource_ids`）。它用于发现和
复用，不复制资源、不改变资源身份，也不影响 Project Org Selection 或 Organization Ref。

## Blob / Tree / Commit / Ref

- Blob：内容寻址的不可变正文；
- Tree：某版本的资源集合；
- Commit：带 parent 的不可变版本；
- Ref：可前移的头指针。

Organization Ref 是发布权威；Project Ref 标识选择投影。Manifest 是退役运行时术语。

## Draft

由 Project 携带、以 Organization 为发布目标的本地优先提案。Draft 保存 Base Commit、
version 和有序 create/update/rename/delete 操作。生命周期只有 `open`、`submitted`、
`merged`、`discarded`；`behind` 是 freshness，`clean` / `conflicts` 是 reconciliation。

## Review

Server 上的人类协调与授权发布对象。一个 Review 可有序包含一个或多个 Draft；决定和
merge 在同一事务中校验整组 Draft、生成一个 Commit 并推进一次 Ref。任何一项失败都不
发布部分结果。

## Reconciliation / Rebase

Reconciliation 是 Server 对 Base、Current 与 Draft Result 的规范比较，只生成绑定 Draft
version 和当前 Ref 的候选，不修改 Draft。Rebase 是显式应用确认候选：保留旧 revision、
把 Base 推进到 Current，并用 `diff(Current, confirmed result)` 替换操作。两者都不发布；
只有 Review merge 推进 Ref。

## Adapter

让 Clumsies runtime 在 Agent Host 中可用的纳管集成层。Codex 使用 App 管理的全局
Plugin；Claude Code、opencode、dsh、Antigravity 使用各自 direct-file/client 集成。
Adapter 注册 MCP 和生命周期桥，不是 Server 或 MCP 协议本身。

## MCP

Agent-facing 协议面，只暴露两个工具：

- `memory`：`activate`、`load`、`store`；
- `kanban`：Issue 查询、语义更新和显式状态转换。

App 内 `clumsiesd mcp serve` 是 stdio-to-XPC 短进程 proxy，不拥有数据库、模型或后台
worker，也不是内容发布权威。

## Issue / Kanban

Issue 是 Server 共享的 Project 工作事项，不是 Memory 或 GitHub Issue。Server 的
`kanban_issues` 保存内容、状态、assignee 与 revision；`issue_claims` 保存跨安装短租约；
daemon 的 `native_issues` 是本地副本与离线执行状态。

持久状态为 `todo`、`in_progress`、`paused`、`in_review`、`done`。看板显示 Todo、In
Progress、In Review、派生的 Abandoned 与 Done；Paused 保留在 In Progress。Agent 只能
显式请求转换，最终 Approve 属于用户。

## AgentRun

daemon 本机记录的一次 root turn 或 subagent 执行。它提供 Hook 签发的 `run_id`、revision、
父子关系、lease 与 outcome，可绑定 Issue，但生命周期事件不会自动推进 Issue。Server
claim 也不会把 AgentRun 变成共享权威。

## Retrieval Run

daemon 本机保存的一次有效 `memory.activate` 轨迹，包括 query、Effective Memory/Index
Revision 身份、各排序阶段候选、最终 disposition、延迟和失败信息。它不是 MCP 工具，也
不会上传 Server。

## Evaluation Case / Corpus

Evaluation Case 把成功 Retrieval Run 的 query、完整 Effective Memory corpus 和人工证据
判断冻结为版本化评测样本。Corpus 包含该次运行的完整资源集合，不只是返回片段；被 Case
引用的 Run 不随普通历史清理删除。

## Assignee / claim

assignee 是 Server 保存的长期负责人，必须是 Project 成员；claim 是某用户与
AgentRun 当前执行 Issue 的短租约。两者彼此独立，也都不能代替 Issue content revision
CAS。

## Artifact / Hub / Local / Attestation

- Artifact：Organization Memory 管理面的退役名称；
- Hub：早期 Organization UI 标签，不是服务；
- Local：早期 Project-scoped Memory UI 标签，不代表当前 authority；
- Attestation：退役 Zig 客户端事件流能力，历史源码可从 Git commit `4b18f7947a977dbc6b62f560b698dc992597f19d` 恢复。
