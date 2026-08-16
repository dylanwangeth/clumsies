# Development Workflow: Worktrees + Kanban

## Why worktrees

Clumsies development uses kanban-driven, parallel agent work: multiple issues
are worked on concurrently by different Agent hosts. A single working directory
does not survive this model:

- switching branches in one checkout dirties the working tree, rebuilds, and
  editor state;
- concurrent agents on the same checkout race on files and tooling caches;
- a kanban issue needs an isolated, disposable environment from start to merge.

Git worktrees give each issue its own checkout and branch while sharing one
repository, one remote, and one set of git hooks.

## Core loop

1. **Take an issue from the kanban.** Call `kanban.begin_work` on the issue so
   the board reflects who is working on it (run binding keeps concurrent agents
   from claiming the same issue).
2. **Create the worktree** from `main`:
   ```sh
   git worktree add target/codex-worktrees/<wt-name> -b <branch> main
   ```
3. **Develop inside the worktree.** All commits stay on `<branch>`; the main
   checkout and other worktrees are untouched.
4. **Verify before finishing.** Run the relevant suites for the touched layers
   (see [Validation](#validation)).
5. **Request closure on the kanban.** `kanban.request_closure` with a summary
   of what changed and what was verified.
6. **Merge the PR** after the user approves the gate. Prefer merge over rebase
   so the branch stays reviewable.
7. **Clean up**:
   ```sh
   git worktree remove target/codex-worktrees/<wt-name>
   git branch -d <branch>
   ```

## Naming

| Thing | Convention | Examples |
|---|---|---|
| Worktree directory | `target/codex-worktrees/<slug>` | `issue-board-release`, `search-index-refresh` |
| Branch | `codex/<slug>` for agent work; `fix/` or `feat/` for tracked issues | `codex/search-index-refresh`, `fix/issue-134-dispatch-macro` |
| Commit subject | ≤ 72 characters, `<area>: <summary>` | `daemon: move agent protocols into clumsiesd proxies` |

The `clumsies-commit-format` commit-msg hook enforces the 72-character subject
and runs in every worktree.

## One issue = one worktree = one PR

- Keep one worktree per kanban issue. Do not accumulate unrelated commits on a
  branch that is ready to merge.
- If a branch already contains merged-ready work and new work starts on top of
  it, split it: create a new worktree from the merge-ready commit, cherry-pick
  the new commits there, and reset the original branch. The new branch stacks
  on the first PR.
- When a worktree's branch has been pushed to `origin`, do not `reset --hard`
  it afterwards; use the new-branch split instead.

## Isolation and shared state

- Each worktree has its own `target/` and frontend build output; builds do not
  interfere.
- Git hooks, remotes, and `~/.clumsies` state are shared by design.
- The running daemon and macOS app are **not** part of the worktree: they run
  from `~/Applications/Clumsies.app` and `~/Library/...`. Code changes take
  effect only after the daemon/app is rebuilt and redeployed.
- Safety snapshot branches (e.g. `codex/safety-*`) are kept until their
  content is confirmed present in `main`; deleting the worktree does not delete
  the branch.

## Validation

| Layer | Command |
|---|---|
| daemon (lib + integration) | `cargo test -p daemon --lib` and `cargo test -p daemon --test daemon_lifecycle` |
| macOS app | `cd apps/macos && xcodebuild -project Clumsies.xcodeproj -scheme Clumsies -configuration Debug build` |
| public docs | `bun run build` |

Run at least the suites covering the changed layer before `kanban.request_closure`.

## Kanban integration (roadmap)

Worktree creation and cleanup will eventually be driven from the kanban itself:
- `kanban.begin_work` ↔ worktree creation;
- issue dependencies (ISSUE-024) tell an agent which worktrees can be
  created now (`kanban.list` reports `blocked` and `blocking_reasons`);
- AgentRun identity comes from supported host lifecycle integration; Agents do
  not mint a manual run through the public MCP contract.
