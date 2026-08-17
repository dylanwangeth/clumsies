# Memory 文件树右键菜单：需求设计 vs 当前实现（差距分析）

> 日期：2026-08-17 ｜ 范围：macOS Memory 导航器文件树 dropdown（context menu）
> 需求来源：ISSUE-004（核心）、ISSUE-006/041（投影）、ISSUE-012（统一模型）、macOS 交互惯例

## 1. 需求设计应有的操作（按组）

### A. 打开与查看
1. **Open** —— 默认打开（Markdown 预览）；
2. **Open Source** —— 源码模式打开；
3. ~~Open in Hub~~ —— ISSUE-004 证据提及的历史操作；统一 Memory（org/project 合并）后
   该概念被项目引用关系操作取代，需确认是有意移除。

### B. 项目引用关系（ISSUE-004 核心交付）
4. **Add to Project** —— org(Organization) 资源加入当前项目（project scope 引用，多选批量、一次原子更新）；
5. **Remove from Project** —— 继承自 org 的、已被当前项目引用的资源移除引用；
6. **批量语义**：一次请求、携带最新 revision（If-Match 并发控制）；
7. **混合选择**：已引用+未引用同时选中时文案与作用域明确，不静默反转；
8. **权限**：无管理权限时禁用。

### C. 生命周期
9. **Rename**；10. **Discard Draft**；11. **Move to Trash**；
12. **Review Changes / Update Draft**（draft behind 时的差异审查入口）。

### D. 新建
13. **New Memory**（空选区/空白处右键）。

### E. 选区语义（决定菜单行为的基础，非菜单项）
- 单击选择、Cmd+Click 多选、Shift 范围选择；
- 右键未选中文件 → 该文件成为目标；右键已选中集合 → 保留多选；
- 失败不改变本地可见状态；成功后 org 与 project 投影立即一致。

## 2. 当前实现（MemoryWorkspaceView.fileTreeMenu + contextMenu(forSelectionType:)）

已实现：Open / Open Source / Review Changes / Update Draft / Add to Project（项目子菜单）/
Remove from Project / Rename / Discard Draft / Move to Trash / New Memory（空选区）。
多选模型（selectedNodeIds + FileTreeSelectionInteraction）、右键目标语义（原生 contextMenu）、
原子批量更新（mutateProjectOrgSelection → 单次 PUT + If-Match）、权限门控（canManageOrgSelection）、
成功刷新（applyProjectOrgSelection + daemon retrySync）均已就位；旧的 Choose Hub Memory 入口（历史概念）与 ProjectOrgSelectionView 已移除。

## 3. 差距表

| # | 需求项 | 当前状态 | 差距/说明 |
| --- | --- | --- | --- |
| 1-2 | Open / Open Source | 完整 | — |
| 3 | Open in Hub | 已移除 | 设计演进（统一 Memory）；需确认是有意为之并更新 ISSUE-004 表述 |
| 4 | Add to Project | 已实现 | 当前为选择项目子菜单；仅一个项目时多一步选择，可优化为直接对当前项目执行 |
| 5 | Remove from Project | 完整 | — |
| 6-8 | 批量/混合/权限 | 已实现 | 混合选择同时显示 Add N 与 Remove M，作用域明确；文案可打磨 |
| 9-12 | 生命周期操作 | 完整 | — |
| 13 | New Memory | 空选区可建 | 无法在指定目录内创建（ISSUE-041 投影落地后可增强为目录级新建） |
| 14 | 多选模型 | 完整 | FileTreeSelectionTests 已覆盖单/多/Shift/Cmd/目录展开 |
| 15 | 右键目标语义 | 原生实现 | — |
| 16 | 原子更新+revision | 完整 | 单次 PUT + If-Match |
| 17 | 失败一致性 | 完整 | guard 前置校验，失败不改状态 |
| 18 | 成功刷新 | 基本 | 非 active 项目的投影刷新时机待验证（低风险） |
| 19 | **验收测试覆盖** | 部分 | **主要缺口**：ISSUE-004 验收第 11 条要求变更类测试（add/remove 混合选择、权限拒绝、revision 冲突、成功刷新），现有测试仅覆盖选择交互 |
| 20 | 旧入口移除 | 已移除 | — |
| 21 | 看板状态 | todo | 功能已落地但 ISSUE-004 看板状态未推进 |

## 4. 其他发现

1. **MemoryKind（context/rules/workflows）仍是新建类型选择**：与 ISSUE-012 统一 Memory 模型的
   关系需明确（目录结构保留还是统一）；
2. **ISSUE-041（可见文件投影）落地后**，菜单应补充文件系统层操作（如 Reveal in Finder、目录内新建）；
3. **Add to Project 交互优化**：单项目场景直接执行，多项目才出子菜单（保持批量+无窗口原则）。

## 5. 建议下一步

1. 补 ISSUE-004 缺失的变更类 Swift 测试（add/remove 混合、权限拒绝、revision 冲突、成功刷新）；
2. 核实已实现范围后推进 ISSUE-004 看板状态（begin_work → request_closure）；
3. 小优化：单项目 Add to Project 直执行；确认 Open in Hub 移除为有意设计；
4. 明确 MemoryKind 与统一 Memory 模型的演进路线（联动 ISSUE-012/041）。
