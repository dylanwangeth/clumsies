# 搜索索引 schema 漂移复盘：一次“版本号没升”引发的持续构建失败

> 关联：Kanban ISSUE-065（search index schema drift）｜日期：2026-08-18｜状态：已修复（v6→v7 迁移 + 列存在性守卫）

## 1. 业务场景：用户到底经历了什么

### 1.1 症状

用户反馈“服务器是不是不响应了”，排查后发现：

1. 服务端健康检查一切正常（200，全部服务 green）；
2. **daemon 日志每 ~30 秒刷两条 WARN**：
   `background search index build failed: ... table search_resources has no column named description`，
   且只针对两个项目（prj_4d77be / prj_ec9250）；
3. 这两个项目是 **custom storage**（外置卷 `/Volumes/ORICO/workspace/DylanVault/…`），
   它们的 search index 库不在 `~/Library/Caches/ai.clumsies/projects/` 下，而在
   `.clumsies/cache-v1/<org-hash>/<project>/search/index.sqlite` —— 排查时先找错了地方；
4. 每次失败后 scheduler 进入退避重试，**永续循环**，项目检索长期不可用。

### 1.2 影响面

| 影响 | 说明 |
| --- | --- |
| 项目检索不可用 | 两个项目（DylanVault/clumsies、DylanVault/infinite）激活/检索全部失败 |
| 日志噪音 | 每 30s 两条 WARN 持续刷屏，掩盖其他问题 |
| 数据同步停滞 | 这两个项目的索引永远停在旧 revision |

## 2. 根因：版本号没升 + 迁移路径缺失

### 2.1 提交史实

- `4b18f79`（8-12）引入 `PROJECT_INDEX_SCHEMA_VERSION = 6`，并为 v3/v4/v5 写了 ALTER 迁移；
- `232eaac`（8-15）给 `search_resources` 的 **CREATE TABLE** 加了 `description` 列、
  把 kind CHECK 扩为含 `'memory'` —— **但没有升版本号，也没有补 ALTER TABLE**。

结果：8-15 之前创建（或迁移到）v6 的库，version 标记是 6，表结构却是旧版：
无 `description` 列、kind CHECK 只允许 `('context','rule','workflow')`。
新代码打开库时看到 version 6 == 当前版本 → 跳过所有迁移 → 构建时 INSERT 带 `description`
的语句直接报 “no column named description”。

### 2.2 为什么 5 个项目的库没坏、2 个坏了

同一 org 下 5 个项目在 cache 目录（8-16 之后由新二进制重建过，含 description 列）；
而 2 个 custom-storage 项目在**外置卷**上，库还是 8-15 之前的旧二进制写的，
一直没被重建 → 恰好命中旧 flavor。这也是“本机只有部分项目坏”的原因。

### 2.3 为什么没早报出来

1. **版本号撒谎**：v6 有两个 flavor（有/无 description），靠 version 无法区分；
2. **无 schema 漂移检测**：迁移逻辑只比对版本号，从不校验列存在性；
3. **错误被降级成 WARN**：后台构建失败只打 WARN + 重试，没有上报/告警；
4. **失败项目不在默认 cache 目录**：如果两个坏库在 `~/Library/Caches` 下，
   8-16 的 daemon 重启后就会被重建，问题可能当时就暴露/自愈了。

## 3. 修复方案

原则：**schema 迁移必须同时考虑“列存在性”与“版本号”**；SQLite 不能改 CHECK 约束，
所以要么重建表、要么整库重建。

`crates/daemon/src/search/index.rs`：

1. `PROJECT_INDEX_SCHEMA_VERSION` 6 → 7；
2. 迁移函数新增守卫：`search_resources` 存在但缺 `description` 列时——
   - 若表带**旧 kind CHECK**（不含 `'memory'`）：整库重建（drop 全部索引表，下一次
     后台构建从当前 generation 重建，统一 Memory schema）；
   - 否则（如 v3 时代的无 CHECK 表）：只 `ALTER TABLE ADD COLUMN description`，
     保留 ready head，避免全量重嵌入。

并回退了错误的全局 `SEARCH_SCHEMA_VERSION` 3→4 改动：全局 local.db 表走
drop-recreate 干净路径，版本 bump 既不必要也无效果（每个 project 库才是问题所在）。

## 4. 教训

1. **改 CREATE TABLE 必须同步升 schema 版本**；改表结构（加列/改 CHECK）必须写迁移。
   这是 ISSUE-062（blob 内容寻址）之后第二次同型事故；
2. **迁移守卫用“列存在性”而非仅版本号**：当历史上有“同版本多 flavor”时，版本号不可信；
3. **SQLite 的 CHECK 无法 ALTER**：遇到 CHECK 变更，数据保留需要
   foreign_keys 开关/重建表（有连接池状态泄漏风险），直接整库重建更安全——反正
   后台构建会自动补齐；
4. **custom-storage 项目的索引不在 cache 下**：排查 search 问题时先查
   `project_storage_locations`，再找 `.clumsies/cache-v1/`。
