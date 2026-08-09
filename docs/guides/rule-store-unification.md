# Rule / Workflow Storage Unification Design

Status: Draft (ISSUE-020)

## 现状

Rules, workflows, and context content currently live in the **client file cache**:

- Path: `~/.clumsies/workspaces/<ws-id>/cache/rule/`, `cache/context/` + `manifest.json`
- Written by `clumsies sync` (sync_cmd.zig `writeToCache`) from Server responses
- The daemon installs a **commit generation** (a directory snapshot under
  project storage) that mirrors the same rule/context files
- Workflow skill proxies are generated at install time (`clumsies adapt`,
  Codex) or at session start (Claude Code `session-start.sh`)
- MCP `load` reads rules from the local file cache

Two mechanisms coexist: the daemon generation (authoritative, per-commit
snapshot) and the client cache (what `sync` materializes). This split causes:

- MCP `load` and hook skill proxies can disagree on content
- `clumsies adapt` static generation + session-time file scanning are
  different paths for the same workflow proxies
- No single place answers "what rules does this Project actually have now?"

## 目标

1. **单一事实来源**: daemon local.db (sqlite) holds the Project's rule/context
   resource rows (path, kind, content, content_hash, current_commit).
2. **MCP load 走 daemon**: Zig MCP `load` reads via daemon instead of the
   client file cache.
3. **统一 skill 代理时机**: workflow skill proxies are generated from the
   daemon's rule rows at one consistent point (install + post-sync), for all
   hosts (Codex / Claude Code / opencode).
4. **存量迁移**: existing file caches migrate into sqlite once; the client
   cache stops being a runtime source of truth (kept only as a display/mirror).

## 方案 A：daemon sqlite 规则表（推荐）

### Schema（schema 34 迁移）

```
CREATE TABLE project_resources (
    project_id TEXT NOT NULL,
    path TEXT NOT NULL,          -- rule/<...>.md, workflow/<...>.md, context/<...>
    kind TEXT NOT NULL CHECK (kind IN ('rule','workflow','context')),
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    commit_id TEXT,              -- generation the row came from
    PRIMARY KEY (project_id, path)
)
```

- Populated by commit generation install (daemon reads the generation dir
  and upserts rows) and by Server sync (rules/contexts written as rows).
- `cached_refs` stays as the commit pointer; `project_resources` is the
  materialized content table.

### MCP load

- daemon endpoint `load_resource(project_id, path)` reads
  `project_resources`, validates the `workflow/` namespace, returns content +
  hash. Zig MCP calls daemon instead of reading cache files.
- `knownHashes` unchanged: hash compares against the row.

### Skill proxy generation

- Single daemon command `_agent refresh-workflow-skills --project <id>`
  reads workflow rows and writes SKILL.md proxies into
  `.agents/skills/` (Codex/opencode) or `.claude/skills/` (Claude Code).
- Trigger points: after `adapt` install (as today) and after a Server sync
  that changes workflow rows (daemon notifies; host hook runs refresh).
- Removes the separate session-start scan in `session-start.sh`; the hook
  only calls refresh if a marker indicates workflows changed.

### 存量迁移

- schema 34 migration reads the existing client cache
  (`~/.clumsies/workspaces/<ws-id>/cache/rule|context`) and the active
  generation dir, upserts into `project_resources`, then marks the cache as
  mirror-only. Idempotent; no runtime dual-write after migration.
- `clumsies sync` stops writing cache files (or writes them only as a
  display mirror); daemon is the source of truth.

### 影响面

- `commit_sync.rs`: generation install populates `project_resources`.
- `sync_cmd.zig`: no longer writes authoritative rule cache.
- `tools.zig` (Zig MCP): `load` via daemon.
- `workflow_skills.zig`: reads daemon rows (through an IPC call) instead of
  the cache manifest.
- `agent_adapter.rs`: skill proxy generation calls the refresh command.

## 方案 B（放弃）：保持文件缓存，只统一代理

Keep files as truth; only unify proxy generation timing. Rejected: does not
fix the MCP load / proxy content disagreement, which is the core problem.

## 风险与决策

- **Performance**: sqlite rows for large Projects are fine (content indexed by
  path). The existing retrieval index already reads content from generations.
- **Migration completeness**: the client cache may be stale relative to the
  current commit; migration must prefer the generation dir (authoritative)
  over the cache.
- **Open questions**:
  - Should context files migrate too, or stay file-based? Proposal: migrate
    all three (rule/workflow/context) for one source of truth.
  - Desktop display of rules: keep the mirror cache or read via daemon? Keep
    the mirror for now (cheap), mark rows as authoritative.

## 验收

1. daemon local.db holds project_resources populated from generation install.
2. MCP `load` returns rule/workflow content via daemon (no client cache).
3. workflow skill proxies generate from daemon rows at install + post-sync,
   consistent for Codex / Claude Code / opencode.
4. Existing caches migrate idempotently (schema 34); no runtime dual-write.
