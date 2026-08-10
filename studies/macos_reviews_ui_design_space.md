# macOS Reviews UI 设计空间研究（基于 Apple HIG）

## 1. 研究问题与范围

**研究问题**：Clumsies macOS app 的 Reviews 功能区（审阅者查看、评论、批准/拒绝/合并内存草稿的界面）是否需要重新设计？如果重新设计，按照 Apple 的 macOS 设计规范（Human Interface Guidelines）应该采用什么布局、什么 UX 逻辑、怎么展示数据？

**为什么值得理解**：Reviews 是团队协作的核心流程（提交 → 评审 → 决策 → 合并），当前实现是功能堆叠式的单栏滚动页，动作埋在页面底部、状态全靠文字、无排序无计数，与 macOS 平台习惯（工具栏动作、可扫描列表、状态可视化）有明显差距。BUNDLE_REVIEW_DETAIL.md 的 UI/UX 遗留问题也指向同一片区域。

**范围**：
- 覆盖：Reviews 列表与详情的信息架构、布局选项、状态与动作的 UX 逻辑、数据展示方式。
- 不覆盖：server 端 API 重构（仅列出依赖缺口）、Bundle 界面、其他 section 的统一样式迁移、最终实现方案（本文件是设计空间研究，不是决策记录或实现计划）。

## 2. Reviews 领域模型（可展示的数据）

来源：`apps/macos/Sources/Infrastructure/ServerModels.swift`、`apps/macos/Sources/Domain/MemoryModels.swift`、`crates/server/src/repository.rs:2134`（`list_reviews`）。

**Review 元数据（列表可用）**
- `reviewId`、`projectId`、`draftId`、`title`、`description`
- `author`（UserReference：email / displayName / avatarUrl / role）
- `status`：`open` / `approved` / `rejected` / `merged`
- `version`、`decisionBody`（决策正文，可空）、`approvedResultHash`（可空）
- `createdAt`、`updatedAt`
- `coordination`：`freshness`（current / behind）、`reconciliation`（unknown / clean / conflicts）、`currentCommitId`、`candidateId`

**Review 详情（打开后追加）**
- `draft`（ServerDraft：title、description、resource reference：scope/kind/path）
- `operations`（ServerDraftOperation：action = create/update/delete/rename，content，newPath，时间）
- `comments`（ReviewComment：author、body、createdAt）

**服务端排序**：`ORDER BY updated_at DESC, review_id`，`LIMIT 200`，无游标分页（跨 org 或按 project 过滤）。

**客户端现状**：`loadReviews()` 在 workspace 整体加载时并行拉取（`WorkspaceStore.swift:1866`），`ReviewDetail` 打开时单独拉取（`reviewDetail`）。

## 3. 现状盘点（实现清单与 HIG 差距）

来源：`apps/macos/Sources/Features/ReviewsView.swift`（292 行，唯一实现文件）、`WorkspaceView.swift:615-707`（导航器/详情装配）、`SharedUpdateIndicator.swift:50`（DraftBaseBehindIndicator）。

当前结构：侧栏 section `.reviews` → `ReviewNavigator`（List：title + status·author 两行，可带 freshness 指示器）→ `ReviewDetailPane`（ScrollView：title/description → Changes 区（operation labels + SplitDiffView 内嵌）→ Discussion GroupBox → Decision GroupBox / Resubmit / Merge 按钮）。工具栏有一个 status 筛选 Picker。

**与 HIG 的主要差距**：

1. **动作埋在滚动内容底部**。Approve/Reject/Merge/Resubmit 都在长滚动页最下方，审阅人必须滚到底才能决策。HIG Toolbars 要求主动作放在工具栏 trailing edge（`https://developer.apple.com/design/human-interface-guidelines/toolbars`）；HIG Buttons 要求用 prominent 样式突出"最可能执行的动作"，且每屏不超过 1-2 个（`https://developer.apple.com/design/human-interface-guidelines/buttons`）。
2. **状态只靠文字**。列表行和详情标题都是 `status.capitalized` 纯文本。HIG Sidebars 明确允许"少量固定色/图标表达意义"（Mail 的 VIP 黄色徽标例子，`https://developer.apple.com/design/human-interface-guidelines/sidebars`），状态机（open/approved/rejected/merged）是典型适合 symbol + 颜色的数据。
3. **列表行信息不足**。没有 project、没有相对时间、没有描述预览、没有决策结果、没有版本。审阅人无法在列表中做 triage 判断。
4. **筛选器是裸 Picker**，无计数、无状态图标、无分组。筛选与"哪些需要我处理"的 inbox 逻辑没有挂钩。
5. **freshness/reconciliation 藏太深**。behind/conflicts 状态只在列表 contextMenu 里有 "Review Changes"，详情里没有任何提示条；冲突态是流程阻断点，应该一眼可见。
6. **空态单一**。只有 `ContentUnavailableView("No Reviews")`，无"当前筛选下没有结果"、无"没有待我审阅"等区分。
7. **详情缺少元数据行**。version、createdAt/updatedAt、draft 路径、决策正文（decisionBody）、approvedResultHash 都没有展示。
8. **评论无时间戳**，讨论不可按时间理解上下文。
9. 已有组件可复用：`SplitDiffView`（分栏 diff）、`DraftBaseBehindIndicator`（freshness 图标）。

## 4. Apple HIG 一手证据

### 4.1 Split views（https://developer.apple.com/design/human-interface-guidelines/split-views）

- 用 split view 同时展示多级层级并支持导航：主面板选中 → 次面板显示内容；次级还有内容时可加第三面板。
- macOS 上：窗格可拖拽调宽，用 1pt 细 divider；设置合理的 min/max 宽度；可以考虑让用户隐藏某面板（如 Keynote 隐藏 navigator/notes），并提供多种恢复方式（工具栏按钮 + 菜单命令 + 快捷键）。
- 每个通往详情的面板都要持久高亮当前选中项。

### 4.2 Sidebars（https://developer.apple.com/design/human-interface-guidelines/sidebars）

- Sidebar 用于顶层导航（列表项目/集合），一般不超过两层层级；数据层级更深时应改用"sidebar + 内容列表 + 详情"的 split view。
- 图标用 SF Symbols、跟随系统 accent 色；少量固定色可以表达意义（Mail VIP）。
- 不要把关键信息或动作放在 sidebar 底部（窗口移动时容易遮住底边）。

### 4.3 Toolbars（https://developer.apple.com/design/human-interface-guidelines/toolbars）

- 内容三要素：当前视图标题、导航控件、动作。位置三分：leading（返回/侧栏切换 + 标题）、center（常用控件）、trailing（重要动作、打开 inspector 的按钮、搜索、More、**主动作**）。
- 分组最多约 3 组，避免拥挤；图标优于文字（Edit 类除外）；文字标签按钮与图标按钮分开排放避免误读为组合按钮。
- **prominent 样式用于唯一主动作（Done/Submit 类），放 trailing**；每屏一个主动作。
- macOS：**每个 toolbar 项都要能在菜单栏里找到对应命令**（用户可能隐藏工具栏）。

### 4.4 Buttons（https://developer.apple.com/design/human-interface-guidelines/buttons）

- 用 prominent 样式突出最可能执行的动作；**每屏 1-2 个 prominent**，多了增加认知负担。
- 同一组选择（如 Approve/Reject）用**相同尺寸**，用样式（prominent vs 普通）区分推荐项。
- Role：primary 响应 Return；**destructive（红）专用于会造成数据销毁的动作**——Reject 不是数据销毁，不应轻易用红 primary；Merge 不可逆但非删除，语义上也算"主要动作"。
- macOS push button：标题含省略号表示会打开新窗口/视图。

### 4.5 Inspector / Sheet / Popover（来自 kanban 研究 `studies/macos_kanban_issue_detail_presentation.md` 的既有结论）

- Inspector：跟随当前 selection 显示补充细节/控件，适合"看板持续可见 + 小属性面板"，不适合主动打开长文阅读。
- Sheet：模态、阻断父窗口，只适合需要完成的 scoped 任务，不适合被动阅读 Review 详情。
- Popover：transient、容量小，不适合长详情。
- 结论沿用：Review 详情应为 **split view 的主内容面板**，而非 inspector/sheet/popover。

### 4.6 关于 Table

- HIG 无独立 table 页面（该 URL 不存在，证据缺口）；macOS 的列式列表是平台惯例（Mail、Xcode 的队列视图、Finder 列表）。SwiftUI `Table`（https://developer.apple.com/documentation/swiftui/table）支持列、排序、选择，天然适配"审阅队列"。

## 5. 布局选项（设计空间，非决策）

共同前提（全部方案成立的基础）：详情是 split view 的内容面板（4.5）；保持选中高亮（4.1）；工具栏承载主动作（4.3）；状态用 symbol + 固定色徽章（4.2）。

### 方案 A：改良双栏 List-Detail（低成本，对现状的增量修正）

- 结构不变：sidebar → 审阅列表 → 详情。
- 列表行升级：title（1 行）+ description/path 预览（1 行）+ trailing 状态徽章 + freshness 指示器；副文本行 author · project · 相对时间。
- 工具栏：状态筛选改 segmented control（带计数），主动作（Approve/Merge）进 trailing。
- 详情：标题下加元数据行（作者/项目/版本/时间），动作区从滚动底部移出（工具栏或固定于详情头部），Changes/Discussion/Decision 保留分区但 Decision 前移到 header 区。
- HIG 契合：完全符合 split view/sidebar/toolbar 基本规则；成本最低；保留现有导航肌肉记忆。

### 方案 B：三栏 Table-Detail（中成本，面向"审阅队列"工作流）

- sidebar（项目/筛选分组）→ `Table`（Title / Project / Author / Status / Updated，可排序、列可调）→ 详情。
- HIG 依据：sidebar 只做顶层导航（4.2），深度数据用 sidebar + 内容列表 + 详情（4.1 三面板）。列式表格适合扫描与 triage：200 条上限下，状态列 + 时间列 + 作者列一眼筛选。
- 代价：三栏占横向空间；需要给 ReviewRecord 补 project name（现在只有 projectId）；排序如需服务端支持则是 server 改动（当前 `updated_at DESC, LIMIT 200` 无游标）。
- 适合：跨项目 review 数量多的组织。

### 方案 C：Inbox 式单列队列 + 快速操作（中成本，面向审阅者每日 triage）

- 类似 Mail：列表即收件箱，"Awaiting my review / All / Approved / Merged" 作为筛选即导航；行内状态图标 + 摘要；详情为可滚动长文，头部固定操作条（安全区内），讨论做成时间线。
- 关键不同：动作区**常驻可见**（不随滚动消失），freshness/conflicts 用 banner 提示条而不是 contextMenu。
- HIG 契合：工具栏主动作（4.3）、状态颜色语义（4.2）；但列表筛选"即导航"更像 iOS 的 tab/segment，macOS 上需谨慎（可退化为 A 的 toolbar 分段）。
- 适合：审阅是高频日常动作的个人工作流。

### 对照表

| 维度 | A 改良双栏 | B 三栏 Table | C Inbox 队列 |
|---|---|---|---|
| HIG 契合度 | 高 | 高（需三栏空间） | 高 |
| 实现成本 | 低（现有结构） | 中（新 Table + 数据补字段） | 中 |
| 扫描效率 | 中 | 高（列化排序） | 中高 |
| 动作可达性 | 中（需移出滚动区） | 高（工具栏常驻） | 高（常驻动作条） |
| 适配场景 | 少量 review | 大量 review / 跨项目 | 个人审阅节奏 |

## 6. UX 逻辑设计

### 6.1 筛选与导航
- 筛选作为 **toolbar 分段控件或 menu**（带每项计数，如 "Open 3"），而非裸 Picker；或 sidebar 分组（需 ≤2 层，4.2）。
- "Awaiting me" 语义可映射到：status == open 且（我非作者 或 我是作者但需要合并）。
- 当前 `selectedSection` 切换已有导航记忆（tabs/back/forward），保留。

### 6.2 动作放置（核心修正）
- 主动作永远在 toolbar trailing：open 态 = Approve（prominent）+ Reject；approved 态 = Merge（prominent）；rejected 态且我是作者 = Resubmit（prominent）。
- 每个状态**只有一个 prominent**（4.4）；Reject 用普通样式（非数据销毁，4.4 的 role 规则）。
- 每个动作同时提供菜单栏命令 + 快捷键（4.3 macOS 规则）：如 ⌘⌥A Approve、⌘⌥R Reject、⌘↩ Merge。
- 按钮进行中状态：用 ProgressView 反馈（Buttons HIG iOS 部分的活动指示器惯例，macOS 同理）。

### 6.3 状态与流程处理
- 状态徽章：open = `clock`/`pencil`（accent 或次要色）、approved = `checkmark.circle`（绿）、rejected = `xmark.circle`（红）、merged = `arrow.triangle.merge`（次要色）。固定色仅用于状态语义（4.2 允许）。
- freshness/conflicts：详情顶部 **banner 提示条**（behind → "基于较旧版本，Review Changes"按钮；conflicts → 显式进入 reconciliation 流程），不再藏在 contextMenu。
- 空态：按筛选区分（"No Open Reviews"、"No reviews awaiting you"），保留无数据时的 ContentUnavailableView。
- 加载态：详情已有 ProgressView；列表保持已加载数据 + 静默刷新（进入 section 时刷新，复用现有 `reload()` 机制）。

### 6.4 键盘与可达性
- 列表 ↑/↓ 移动选择；↩ 打开详情（当前 List selection 已支持）。
- 每个状态徽章/指示器带 `.help()` 与 `.accessibilityLabel()`（现有 DraftBaseBehindIndicator 已这么做，保持惯例）。

## 7. 数据展示

### 7.1 列表行
- 主文本：title（1 行截断）。
- 副文本：description 或 resource path 预览（1 行，secondary）。
- Trailing：状态徽章（symbol+色）+ freshness 指示器（复用 `DraftBaseBehindIndicator`）。
- 第三行或 caption：author · project · 相对时间（updatedAt）。

### 7.2 详情
- Header：title（title2 semibold）+ 状态徽章 + 元数据 caption（作者 / 项目 / version / createdAt / updatedAt，时间用相对格式）。
- Decision 区：open 态显示 Reject/Approve + optional note（现有字段 decisionNote）；已决策态显示 decisionBody 全文；merged 态可显示结果路径/approvedResultHash 前缀（可复制）。
- Changes 区：保留 `SplitDiffView`；operation labels 改为 symbol 行（plus/minus/pencil/arrow.right 对应 create/delete/update/rename），避免与 diff 正文混淆（对齐 BUNDLE_REVIEW_DETAIL.md 的同类结论）。
- Discussion：评论显示头像（avatarUrl 存在时）+ 作者 + **时间戳** + 正文；输入框保持底部。
- 删除型 review（terminal action = delete）：Changes 区只显示删除说明，不渲染空 diff。

### 7.3 数据依赖缺口（供实现时评估）
- `ReviewRecord` 缺 project name（有 projectId，可 client 端用 projects 映射，或 server 补充）。
- 列表无分页游标（server `LIMIT 200`），Table 排序若要服务端支持需 server 改动。
- 时间字段为 ISO 字符串，客户端格式化。

## 8. 开放问题与证据缺口

1. **方案选型**：A/B/C 取决于用户数量级与使用习惯；未做用户调研，本文件不决策。
2. Table 的 macOS HIG 页面不存在（证据缺口），列式列表论据来自平台惯例与 SwiftUI Table 文档，非 HIG 原文。
3. 状态徽章配色需与 macOS 26 Liquid Glass 材质协调（未验证具体渲染效果）。
4. 是否把 Reviews 与 Issues 的交互模式统一（两处都有"detail 呈现"研究，未来可合成一份 macOS 详情呈现总则）。
5. Review 变更集较大时（如多文件操作）的 diff 展示上限与性能未评估。
