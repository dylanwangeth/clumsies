# Memory 文件树右键菜单设计（v2：通用/领域分层，待确认）

> 日期：2026-08-18 ｜ 状态：设计稿，待用户确认后实现
> 关联：ISSUE-004 / ISSUE-063 / 统一 Memory 模型

## 0. 分层原则

菜单 = **通用文档操作段**（标准 macOS 文件树惯例，不区分领域状态）+ Divider +
**领域业务操作段**（Clumsies Memory 特有语义，按视图/选择/项类型精确定义）。
通用段按标准实现一次，所有场景一致；领域段是设计重点。

## 1. 通用文档操作段（标准惯例）

适用：文件项（含草稿项）。与 org/project/inherited 无关。

| 操作 | 单选 | 多选 | 标准依据 |
| --- | --- | --- | --- |
| Open | 是 | 是（逐个打开） | Finder/文档应用：多选 Open 打开全部 |
| Open Source（源码模式） | 是（仅 Markdown 可预览） | 否 | 打开类仅单选细化模式 |
| Rename... | 是 | 否 | Finder：重命名仅单选 |
| Move to Trash | 是 | 是（批量） | Finder：多选可批量删除 |

目录项：右键=该目录下后代文件项的集合菜单（现有语义）；目录本身无 Open/Rename/Trash。

## 2. 领域业务操作段（Clumsies Memory 特有）

| 操作 | 适用项 | 视图 | 单选/多选 | 权限 | 语义 |
| --- | --- | --- | --- | --- | --- |
| **Add to Project...** | org 记忆 | **仅 Org 视图** | 单+多（批量一次原子提交） | admin:write | 把 org 记忆加入所选项目的引用集合 |
| **Remove from Project** | inherited（org 且被当前项目引用） | **仅 Project 视图** | 单+多（批量一次原子提交） | admin:write | 从当前项目移除引用 |
| **Review Changes / Update Draft** | draft 落后 | 两视图 | 单选 | - | 同步共享修改（Review=上游有改动；Update=仅本地落后） |
| **Discard Draft** | 有 draft 的项 | 两视图 | 单选 | - | 丢弃草稿（纯草稿项无 Move to Trash，Discard 即其删除语义） |
| **New Memory** | 空选区/空白处 | 两视图 | - | canCreateMemory | Org 视图建 org 记忆；Project 视图建 project 记忆 |

## 3. 合成菜单矩阵（通用段 + Divider + 领域段）

### 3.1 Org 视图（过滤器 = Org）

| 场景 | 菜单（通用段｜领域段） |
| --- | --- |
| 单选 org 文件 | Open / Open Source / Rename... / Move to Trash ｜ **Add to Project...** /（draft）Review.Update / Discard Draft |
| 多选 org 文件 | Open / Move to Trash ｜ **Add N Items to Project...** |
| 空选区 | ｜ **New Memory**（org scope） |

### 3.2 Project 视图（过滤器 = 项目 P）

| 场景 | 菜单（通用段｜领域段） |
| --- | --- |
| 单选 project 自有 | Open / Open Source / Rename... / Move to Trash ｜（draft）Review.Update / Discard Draft |
| 单选 inherited | Open / Open Source ｜ **Remove from Project** /（draft）Review.Update / Discard Draft（通用段无 Rename/Trash） |
| 单选 org 未引用 | Open / Open Source ｜（draft）Review.Update（无 Add——Add 仅 Org 视图） |
| 多选 inherited | Open / Move to Trash ｜ **Remove N Items from Project** |
| 多选 project 自有 | Open / Move to Trash ｜ - |
| 多选混合（inherited+自有） | Open / Move to Trash（对自有子集）｜ **Remove M Items from Project**（M=inherited 子集；自有子集无领域操作） |
| 多选混合（inherited+未引用） | Open / Move to Trash（对未引用子集？——见决策点）｜ Remove M（inherited 子集） |
| 空选区 | ｜ **New Memory**（project scope） |

### 3.3 特殊项

- 纯草稿项（无 resource）：Open / Rename... ｜ Discard Draft（无 Trash——草稿删除即 Discard）；
- 目录：右键=后代集合菜单（按后代项类型套用 3.1/3.2 规则）。

## 4. 行内指示器（inherited 可见性）

- inherited 项行尾显示可见徽标（building.2）＋ tooltip「Inherited from Organization」；
- 保留现有 secondary 灰色标题色。

## 5. 文档标题 scope 前缀（验证路径）

- 主面板顶部文档 tab 副标题：Organization · <Kind> · <path> / Project · <Kind> · <path>。

## 6. 边界与错误语义

- 无 admin:write 时 Add/Remove 禁用；失败不改本地状态并展示错误；
- 批量更新：单次原子 PUT + If-Match revision，冲突不覆盖；
- 目录选择=后代集合（现有语义）。

## 7. 待确认决策点

1. **多选 Open**：是否逐个打开（Finder 标准）还是多选不显示 Open？（推荐：显示，符合标准）
2. **多选 Move to Trash**：对混合集合（含 inherited）是否按自有子集批量 Trash？
   （推荐：Trash 仅作用于 project 自有/org 子集；inherited 子集只有 Remove——两段各自作用域明确）
3. **多选 Discard Draft**：是否批量？（推荐：暂单选，保守）
4. **Org 视图单选菜单**中 Rename/Move to Trash 保留（org 记忆可在 Org 视图管理）——确认；
5. **Project 视图单选 project 自有**的领域段为空（只有通用段）——确认。
