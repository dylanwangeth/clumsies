# Organization Memory

> 文档属性：概念定义型 / 详细设计型｜L2–L3｜当前权威。

Organization Memory 是统一 Memory 模型唯一可发布的内容权威。本页保留历史路由
`/artifact`，因为早期产品曾把该对象称为 Artifact、把对应界面称为 Hub；这些名称不再
代表独立领域对象或服务。

## 权威边界

每个 Organization 拥有唯一的权威 Ref 与不可变 Commit 历史。Project 只选择其中的
Memory、物化自己的投影 Ref，并承载合并前 Draft；它不创建第二套权威命名空间，也不以
路径或本机副本替代稳定资源 ID。

```text
Organization Ref -> Organization Commit -> Organization Memory
                                      |
                                      +-> Project selection -> Project Ref
Project-carried Organization Draft ---------------------------> Review / merge
```

Blob、Tree、Commit 与 Ref 记录发布版本；Draft、Review 与 merge 构成人工协调和发布
边界。普通成员可提出、提交和评论变更，Organization owner/admin 决定发布。MCP 与
daemon 不能直接推进 Organization Ref。

## Memory

当前只有一个一等内容对象 `Memory`。规则、流程、项目背景等用途由 Markdown 正文与路径
表达，不再由 Context、Rule、Workflow 三种封闭类型决定。

Memory 拥有稳定 opaque ID、Organization 内唯一路径、权威 `name`、语义
`description`、Markdown 正文、revision 与状态。展示标题由 daemon 从 Markdown 第一
个标题或路径派生，不等同于 Server `name` 或 Draft title。

`description` 是目标模型中的独立检索摘要，但当前写入链允许空值，Server merge 也尚未
可靠持久化 Draft description；这属于现行实现缺口，不应把“字段存在”写成“端到端必填
且保留”。完整字段、版本和兼容边界见[统一 Memory 数据模型](/zh/unified-memory-model)。

## Bundle

Bundle 是某个成员保存在 Server 的 Organization Memory ID 集合（`resource_ids`），用于
发现和复用共享内容，不形成内容副本或新权威：

- Memory 可以不属于任何 Bundle，也可以同时属于多个 Bundle；
- Bundle membership 不改变资源 ID、路径、正文或发布状态；
- Bundle 是个人选择，Project Org Selection 是 Project 投影输入，两者彼此独立；
- 删除或调整 Bundle 不能推进 Organization Ref。

Project 选择、Draft overlay 与 Effective Memory 见 [Project](/zh/workspace)，系统级权威图
见[系统架构](/zh/architecture)。
