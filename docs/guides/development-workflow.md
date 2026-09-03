# Development Workflow: Worktrees

Clumsies development uses Git worktrees so concurrent changes do not share a
working tree, build output, or development runtime.

## Core loop

1. Create a worktree and branch from the appropriate baseline:

   ```sh
   git worktree add target/codex-worktrees/<name> -b codex/<name> main
   ```

2. Develop and verify inside that worktree.
3. Open and merge one focused PR.
4. Stop the worktree's Dev Instance before removing it:

   ```sh
   just dev-macos-reset
   git worktree remove target/codex-worktrees/<name>
   git branch -d codex/<name>
   ```

## Conventions

| Thing | Convention |
|---|---|
| Worktree | `target/codex-worktrees/<slug>` |
| Agent branch | `codex/<slug>` |
| Commit subject | `<area>: <summary>`, at most 72 characters |

Keep unrelated changes on separate branches. Do not rewrite a pushed branch
that is under review; create a new branch and cherry-pick the relevant commits.

## Dev Instance isolation

Each worktree can run a complete isolated Dev Instance with `just dev-macos`.
Its canonical path determines the App identity, daemon service, runtime
directories, Keychain service, Compose project, dynamic ports, and isolated
`CODEX_HOME`.

`down` stops only that instance and preserves its data. `reset` removes its
data and test credentials and must run before deleting the worktree. Only
`just promote-debug-macos` may replace the stable Debug installation.

## Validation

| Layer | Command |
|---|---|
| daemon | `cargo test -p daemon --lib` and `cargo test -p daemon --test daemon_lifecycle` |
| macOS app | `just test-macos` |
| Dev lifecycle | `just test-dev-macos` |
| public docs | `bun run build` |
