# MCP 工具契约

Clumsies 只向 Coding Agent 暴露一个 MCP 工具：

| 工具 | 职责 |
|---|---|
| `memory` | 读取当前绑定 Project 的 Effective Memory，或创建由该 Project 携带的 Memory 提案 Draft |

`clumsiesd mcp serve` 是短生命周期的 stdio 协议代理。Effective Memory 构建、索引、检索、Draft 持久化与 AgentRun 观测都由常驻 `clumsiesd` 管理，代理通过本地 XPC 调用它。代理只接受本文列出的强类型输入，不能把任意 JSON 转发给 daemon。

启动时，代理会校验常驻 daemon 的 Agent runtime 协议修订和构建标识，再根据当前目录解析 Project binding。版本不一致、daemon 不可用或严格 host-plugin 模式下无法解析 binding 时都会显式失败。当前协议没有 setup 调用，也不兼容已移除的 `retrieve` 工具、host-session binding、`META_PROMPT.md` bootstrap 或 MCP attestation。

## 通用输入规则

`memory` 使用 tagged operation 结构：

```json
{
  "op": {
    "operation_name": {}
  }
}
```

- `op` 必填，并且必须且只能包含一个 operation。
- 输入不能包含 `null`；可选字段应直接省略。
- operation 和字段名区分大小写，未知字段会被拒绝。
- MCP 进程的 Project binding 决定 `memory` 的 Effective Memory；调用方不能在参数中改写 `project_id`。

## `memory`

`memory` 包含 `activate`、`load` 和 `store` 三个 operation。

### Project Memory 指南

Project 可以约定一份 Memory 指南，默认路径为 `CLUMSIES.md`；受管集成也可以提供其他路径。它通常定义：

- 目录与命名方式；
- 何时允许提出 Memory 变更；
- description、替代与弃用规则；
- 不应持久化的内容。

进行实质性 Memory 维护前，先通过 `load` 读取该指南。指南本身仍是普通 Memory，不是安装到 Agent 本地目录的特殊 skill。

### `activate`

每个实质任务开始时调用一次 `activate`，让 daemon 从当前 Effective Memory 中返回最相关的片段：

```json
{
  "op": {
    "activate": {
      "query": "校正 MCP 工具契约和并发修订语义"
    }
  }
}
```

| 字段 | 必填 | 语义 |
|---|---:|---|
| `query` | 是 | 非空的自然语言任务或检索线索 |
| `state` | 否 | 上一次响应的 `next_state`；仅在上一次片段仍完整保留于模型上下文时传入 |

daemon 在一次调用内完成 BM25、向量召回、RRF 融合、Cross-Encoder 重排、资源多样性限制、token 预算和片段增量计算。模型名、候选数量和排序参数由 daemon 管理，不是 Agent 输入。

响应的主要结构为：

```json
{
  "index_revision": "search_...",
  "profile": "agent_activation.v2",
  "next_state": "opaque-state",
  "fragments": [
    {
      "action": "add",
      "unit_key": "mem_123/mcp/0/0",
      "content_hash": "sha256:...",
      "resource_id": "mem_123",
      "scope": "org",
      "kind": "memory",
      "path": "architecture/mcp.md",
      "heading_path": ["MCP", "并发控制"],
      "content": "..."
    }
  ],
  "removed": []
}
```

`add` 与 `replace` 携带正文；`reuse` 表示调用方上下文里已有同一片段，因此省略正文；`removed` 只撤销已删除、失去权限或重新解析后消失的单元，不会因为本次 query 不相关就撤销旧片段。

上下文压缩、旧工具输出已丢弃或开始新任务时必须省略 `state`。无效状态返回 `invalid_activation_state`，不会静默按空状态处理。固定检索模型尚未就绪时返回 `search_model_preparing` 和下载进度，不会退化为另一套检索算法。

### `load`

`load` 按稳定资源 ID 或精确路径加载完整资源，不做模糊检索和重排：

```json
{
  "op": {
    "load": {
      "ids": ["mem_123", "CLUMSIES.md"],
      "knownHashes": {
        "mem_123": "sha256:..."
      }
    }
  }
}
```

| 字段 | 必填 | 语义 |
|---|---:|---|
| `ids` | 是 | 非空、无重复的 ID 或精确路径数组；每项都必须是非空字符串 |
| `knownHashes` | 否 | 以请求 ID/路径为 key 的已知完整资源哈希 |

当 `knownHashes` 与当前资源一致时，结果返回 `changed = false` 并省略 `content`。任一请求目标不存在时返回 `memory_resource_not_found`，不会静默忽略。`load` 与 `activate` 读取同一份 Effective Memory，包括当前 Project 的 Draft overlay。

### `store`

只有用户明确要求维护 Memory 时才调用 `store`。

每次 `store` 只能提供一个变更 operation：

| operation | 必填字段 | 可选字段 |
|---|---|---|
| `create` | `path`、`body` | `description` |
| `update` | `id`、`expected_hash`、`replacements` | `description` |
| `rename` | `id`、`new_path` | `description` |
| `delete` | `id` | `description` |
| `discard` | `id` | 无 |

`store` 本身还可带 `resource`，当前唯一允许值是 `memory`，省略时默认使用该值。description 在当前 MCP 契约中是可选字段；其 Server merge 持久化仍有已知缺口，参见[统一 Memory 数据模型](/zh/unified-memory-model#当前实现缺口)。

Create 示例：

```json
{
  "op": {
    "store": {
      "create": {
        "path": "release/RELEASE.md",
        "description": "项目发布步骤和发布前验证要求",
        "body": "# 发布\n\n发布前先完成验证。"
      }
    }
  }
}
```

Update 不接受完整的新正文。先 `load` 资源，再把返回的完整资源 `content_hash` 作为 `expected_hash`，提交一个或多个精确替换：

```json
{
  "op": {
    "store": {
      "update": {
        "id": "mem_123",
        "expected_hash": "sha256:...",
        "replacements": [
          {
            "old_text": "发布前先完成验证。",
            "new_text": "发布前先完成构建、测试和文档验证。"
          }
        ]
      }
    }
  }
}
```

每个 `old_text` 必须在当前完整资源中恰好出现一次；同一请求内的替换不能重叠，并基于同一份原文原子应用。哈希过期、匹配缺失、匹配不唯一或区间重叠都会拒绝整个 update，不创建部分 Draft operation。`new_text` 可以为空字符串，用于删除文本。

`delete` 的目标如果只是尚未发布的 Create Draft，daemon 会把它归一化为 `discard`；只有删除已发布资源时才会保留待 Review 的 Delete Draft。`discard` 取消 Draft，不发布删除。

成功结果包含本地 operation ID、Draft ID、队列状态和同步状态。它只表示变更已在本机持久化并排队同步：

- Draft 由当前绑定 Project 携带；
- Draft 的权威目标是 Organization；
- merge 前只影响该 Project 的 Effective Memory；
- `store` 不能审批 Review、merge 或前移 Organization Ref。

## 私有 daemon 边界

MCP operation 会映射到 daemon 的 `activate_memory`、`load_memory` 与 `store_draft_operation`。Desktop 还使用 Review、merge 和检索诊断等私有 XPC 方法；它们不是额外 MCP 工具。

每次有效 `activate` 会基于同一候选轨迹写入一条本地 Retrieval Run，但不会改变 MCP 响应 schema。Retrieval Run、Evaluation Case 和评测导出属于 daemon/Desktop 诊断能力，参见[检索运行与评测](/zh/retrieval-evaluation)，不会发送给 Server。
