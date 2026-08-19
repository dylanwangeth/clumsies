# Recall

Recall is the sidebar page that joins an agent's **tasks** (user prompts from the
harness session log) with the **memory activations** (retrieval records) the
agent issued for each task. It answers one question at a glance:

> **For each task, which memories did the agent recall?**

The page sits at the same level as Memory, Kanban, Bundles, and Reviews in the
macOS sidebar. It replaces the earlier practice of burying retrieval runs inside
Diagnostics, where a run's `query` had no link back to the originating task.

## What it renders

Three columns, newest session first:

| Column | Shows |
| --- | --- |
| Sidebar | Bound projects (the existing global sidebar, with Recall selected). |
| Content | Sessions read from the dsh session log, each labelled with its title and task count. |
| Detail | The selected session's tasks; under each task, every memory activation with its query and the recalled fragments. |

Empty states explain themselves: no sessions, no tasks, and "no fragments were
recalled for this activation" each carry a one-line description.

## Data sources and join

Recall reads two local sources and joins them by project and query.

1. **dsh session log** — `~/.dsh/sessions/<encoded-workspace>/<session>/session.jsonl.zstd`.
   The daemon decompresses the zstd frame and parses the typed JSONL events:
   - `session` / `session/title` — session identity and title.
   - `user/message` where `source.kind == "user"` — the task (prompt). Plugin and
     system-reminder messages are filtered out.
   - `tool/call` for `mcp__clumsies__memory` / `mcp__clumsies__activate` — the
     activation query (`op.activate.query`, or the legacy top-level `query`).

2. **Retrieval history** — the daemon's `retrieval_runs` tables. Each activation is
   joined to its run by `(project_id, query)`, and the selected candidates become the
   fragments shown under the task.

The workspace root is encoded to the dsh directory name the same way dsh does it
(`/a/b` → `--a-b--`), and the project id comes from `project_bindings`.

## Scope (first version)

- **dsh only.** The parser is isolated in `crates/daemon/src/recall.rs` behind
  `list_recalls`, so other hosts (Claude Code, Codex, opencode, Antigravity) can be
  added as additional readers without touching the UI.
- **Read-only.** Recall never mutates memory, Issues, or daemon state. A parse or
  decompression failure degrades to an empty/error state instead of blocking.
- Fragments are taken from the daemon retrieval run; the `result_error` field
  surfaces activations whose tool result reported an error.

## Implementation map

| Concern | Path |
| --- | --- |
| Session-log parser + join | `crates/daemon/src/recall.rs` |
| XPC dispatch | `crates/daemon/src/state.rs` (`list_recalls`) |
| XPC client | `apps/macos/Sources/Infrastructure/DaemonXPCClient.swift` |
| Models | `apps/macos/Sources/Infrastructure/DaemonModels.swift` |
| Sidebar section | `apps/macos/Sources/Domain/MemoryModels.swift` (`WorkspaceSection.recall`) |
| UI | `apps/macos/Sources/Features/RecallView.swift` + `RecallModel.swift` |
| Workspace wiring | `apps/macos/Sources/Features/WorkspaceView.swift` |
