# 脏数据排查 Checklist

Clumsies 仍处在 alpha 阶段。遇到历史实现改名、语义收敛、schema 收紧或本地 draft 异常时，不要先在新代码里加入长期兼容分支。默认先判断这是不是历史脏数据问题，再决定是修数据、删数据，还是补一次性迁移。

## 先判断是不是脏数据

- 新代码的 canonical 语义已经明确，但旧本地文件或旧数据库里还残留旧字段值。
- 同一个稳定对象 id 出现多条互相冲突的 active draft，例如同一条 rule 同时有 `update` 和 `rename`。
- UI 列表、MCP discovery、Hub API 返回值读到的 path/status 与本地 `drafts/index.json` 或数据库 row 不一致。
- Fresh workspace 或 fresh database 不能复现，只有长期使用过的本地环境复现。
- 新写入路径正常，但旧记录无法通过新 schema、constraint 或 reducer。

## 本地 workspace 检查

1. 找到 workspace 目录：

```sh
ls ~/.clumsies/workspaces
```

2. 检查 draft index：

```sh
rg '"operation": "modify"|current_path|draft_path|rule_id|context_id' ~/.clumsies/workspaces/*/drafts/index.json
```

3. 检查同一对象是否有多条 active draft：

- `rule_id` 相同。
- `context_id` 相同。
- 或 `current_path` 相同。

4. 检查 draft 文件是否和 index 对得上：

- `update`：`draft_path` 通常等于 `current_path`。
- `rename`：`current_path` 是旧路径，`draft_path` 是新路径，正文应在新路径文件里。
- `delete`：不应依赖正文文件。
- `create`：没有 `current_path`，必须有新 `draft_path`。

## Hub 数据库检查

用当前本地默认数据库连接：

```sh
psql postgresql://clumsies:clumsies@127.0.0.1:5432/clumsies
```

常见检查：

```sql
SELECT pr_id, op_index, type, rule_id, path
FROM rule_pr_operations
WHERE type NOT IN ('update', 'rename', 'create', 'delete', 'bundle_create', 'bundle_add', 'bundle_remove');

SELECT pr_id, op_index, type, context_id, path
FROM context_pr_operations
WHERE type NOT IN ('update', 'rename', 'create', 'delete');
```

如果出现旧值，例如 `modify`，这是历史脏数据。不要在业务代码里重新接受旧值；应该明确修正这些 rows，或者确认它们已经无保留价值后删除相关测试数据。

## 修复原则

- Canonical 代码只接受当前语义，不长期保留旧拼写、旧 enum、旧 API path。
- 对用户仍有价值的数据，写一次性修复命令或手动 SQL，修正为当前 schema。
- 对测试环境、seed 数据、临时 workspace，优先删掉重建。
- 修复后重新跑 fresh database/fresh workspace 测试，确保问题不是新代码路径。
- 如果需要自动清理，清理逻辑必须是“状态归约”而不是“兼容旧语义”：例如 draft index 可归约成每个对象一条最终 active draft，但不应该让 `modify` 继续成为合法 operation。

## 本次 rename/update 类问题的判断方式

- 如果 index 里还有 `"operation": "modify"`，直接判定为旧 dirty data。
- 如果同一个 `rule_id` 同时有 `update` 和 `rename`，应该归约成一条 `rename`，并把 update 后的正文移动到 rename 的 `draft_path`。
- 如果同一个 `rule_id` 同时有 `update`/`rename` 和 `delete`，最终状态是 `delete`。
- 如果 `create` 后又 `delete`，最终状态是不保留 draft。
