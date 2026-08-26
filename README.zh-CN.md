# Clumsies

<p align="center">
  <img src="https://raw.githubusercontent.com/lilhammerfun/clumsies/main/docs/public/logo.svg" width="72" height="72" alt="Clumsies Logo" />
</p>

<p align="center">
  <b>面向 Agent 编程的团队协同记忆平台</b><br>
  <i>像管理代码一样，在研发团队与 AI 编程智能体之间共享、评审与沉淀组织级记忆资产。</i>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml"><img src="https://github.com/lilhammerfun/clumsies/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/lilhammerfun/clumsies/blob/main/LICENSE"><img src="https://img.shields.io/github/license/lilhammerfun/clumsies?label=License" alt="License: MIT"></a>
  <a href="https://github.com/lilhammerfun/clumsies/releases"><img src="https://img.shields.io/github/v/release/lilhammerfun/clumsies?label=Release" alt="Release"></a>
</p>

---

## 时代范式转移

AI 编程智能体（Coding Agents）正在彻底重构软件开发的控制面（Control Plane）。

过去，研发组织只需要通过 Git 仓库管理源代码；而在智能体协同时代，团队必须同时管理**指导 Agent 编写代码的架构规则、业务约束与项目上下文**。

然而，传统的 Agent 记忆往往被困在单次会话或单机本地文件中：它既无法在团队成员之间共享，也无法接受同行评审，更无法跨会话同步。一旦上下文超出窗口，关键的项目约束就会被模型无声丢弃。

**Clumsies 是面向 Agent 编程的团队协同记忆平台。** 它将智能体记忆视作一等公民的版本化组织资产，让人类工程师与自主编程 Agent 能够无缝构建、评审和激活同一套共享大脑。

---

## 核心特性

- **记忆即团队资产（Git 语义上下文管理）**：将架构规则、工作流规范与项目上下文收敛为统一的 Markdown 组织记忆。Project 只选择要使用的组织记忆并承载项目内可见的 Draft overlay；变更经过团队 Review 后原子合入组织 Commit 历史，杜绝静默覆盖。
- **混合检索与按需精准激活**：深度融合 SQLite FTS5 BM25 全文检索、本地向量嵌入、倒数排名融合（RRF）与交叉编码器（Cross-Encoder）重排。Agent 通过 `activate` 按需动态召回最相关切片，避免上下文窗口浪费。
- **面向 Agent 的原生异步看板（Issue DAG）**：Agent 通过类型化 MCP 操作自主认领任务（`begin_work`）、构建有向无环依赖图、评估阻塞谓词并沉淀验证步骤。最终必须由人类通过审批关卡（`approve_closure`）验收完成。
- **MCP + 非阻塞生命周期集成**：原生支持 Google Antigravity、Claude Code、OpenAI Codex、opencode 与 DeepSeek Harness (dsh)，由统一签名的 Rust 守护进程（`clumsiesd`）提供代理。Codex 由 Adapter 安装用户级 Plugin，项目维护的 Skill 留在 Memory Space 并按需加载；启用或更新后需重启 Codex 并新建 task，Plugin Hook 首次运行前还需要用户在 `/hooks` 中审查并信任。纳管适配器不安装正常根 `Stop` Hook；Issue 关闭由可选 skill 或人工维护的工作流显式决定。
- **私有化权威部署**：在自有基础设施中运行 Rust Server 与 PostgreSQL（支持组织 OIDC 鉴权），本地守护进程独立管理高速本地缓存与 XPC 通信。

---

## 适配智能体矩阵

| 智能体宿主 | 协议表面 | 纳管文件 | 支持的生命周期 |
| :--- | :--- | :--- | :--- |
| **Google Antigravity** | MCP + 生命周期 Hook | `.mcp.json`, `.agents/hooks.json` | `PreInvocation`；无根 `Stop` |
| **Claude Code** | MCP + 生命周期 Hook | `.mcp.json`, `.claude/settings.json` | prompt、subagent、失败与会话事件；无根 `Stop` |
| **OpenAI Codex** | Plugin：MCP + Hook + 启动 Skill | App 纳管的用户级 Plugin；无项目文件 | Hook 获得信任后的 prompt、subagent 与会话事件；无根 `Stop` |
| **opencode** | MCP + Plugin | `opencode.json`, `.opencode/plugins/clumsies.ts` | prompt、失败与会话事件；不转发正常根 `Stop` |
| **DeepSeek Harness (dsh)** | MCP + Hook 桥接 | `.dsh/clumsies.json` | prompt、失败与会话事件；不转发正常根 `Stop` |

---

## 快速上手

### 桌面端 macOS App（推荐）

1. 在 [Releases 发布页面](https://github.com/lilhammerfun/clumsies/releases) 下载最新的安装包。
2. 将 `Clumsies.app` 拖入 `/Applications` 或 `~/Applications` 目录。
3. 打开 `Clumsies.app`，系统将自动配置常驻后台守护进程（`ai.clumsies.daemon`）并连接至组织服务器。
4. 在 **Project Settings → Coding Agents** 中勾选需要激活的 Coding Agent 即可开箱即用。

### 源码构建与本地开发

```bash
# 克隆代码仓库
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies

# 安装依赖并一键构建拉起原生 macOS App
bun install
bun run dev:macos
```

启动本地后端与测试鉴权环境：

```bash
# 启动 PostgreSQL 数据库、测试 OIDC 鉴权与 Rust Server
bun run dev:server
```

---

## 技术文档

完整技术文档请访问 [docs.clumsies.ai](https://docs.clumsies.ai)。

---

## 开源协议

[MIT License](LICENSE) © 2026 Clumsies Lab
