---
layout: home

hero:
  name: clumsies
  text: 面向编码 Agent 的协作式外部记忆
  tagline: 分发项目上下文与约束，本地 Draft 自动同步，变更经 Review 后发布。
  image:
    src: /logo.png
    alt: clumsies
  actions:
    - theme: brand
      text: 快速开始
      link: /zh/guides/how-to-use-clumsies
    - theme: alt
      text: 架构
      link: /zh/architecture

features:
  - icon: 🧠
    title: 统一的 Memory 模型
    details: Rule、Workflow 与 Context 统一为携带语义 description 与稳定 ID 的 Markdown 组织记忆；Project 负责选择资源并承载私有 Draft overlay。
  - icon: 📝
    title: 自动 Draft
    details: Desktop 与 MCP 写入同一个常驻 daemon；本地变更无需手动 push 即可同步。
  - icon: ✅
    title: Review 后发布
    details: Project 承载的 Draft 只有通过 Review 并以 Commit 推进组织 Ref 后才会成为权威。
  - icon: 🗂️
    title: Agent 原生看板
    details: Agent 通过 typed kanban 操作认领、暂停、释放并提议关闭 Issue；只有用户的 Approve 闸门能让 Issue 进入 Done。
  - icon: 🔌
    title: Host 适配器
    details: Codex、Claude Code、opencode、DeepSeek Harness 与 Antigravity 共用同一个 App 内签名 Rust runtime，并做 release-identity 校验。
  - icon: 🏠
    title: 自托管 Server
    details: 在自有基础设施中运行 Rust 权威服务与 PostgreSQL，接入组织 OIDC。
