# Codebase map

Clumsies is a Bun, Swift, Rust, and Zig monorepo. Ownership follows runtime
boundaries rather than language alone.

| Path | Responsibility |
| --- | --- |
| `apps/macos/` | Native macOS product client built with AppKit and SwiftUI |
| `crates/server/` | deployable Rust authority service and PostgreSQL schema |
| `crates/daemon/` | macOS launchd daemon, local SQLite state, IPC, and automatic draft sync |
| `packages/api-contract/` | Public, Admin, and daemon OpenAPI contracts |
| `packages/api-client/` | generated-type-backed TypeScript clients |
| `src/client/` | Zig CLI, MCP server, adapters, and retained TUI code |
| `src/protocol/` | Zig client-side protocol types still used by retained surfaces |
| `assets/adapters/` | host-specific integration assets |
| `docs/` | VitePress public documentation |

## Authority boundaries

`crates/server` owns authoritative organization and project memory, identity,
authorization, Bundles, review lifecycle, and Commit history.

`crates/daemon` owns local drafts, queued operations, automatic synchronization,
token refresh, and native Server transport. It is not an authority source.

`apps/macos` is the primary human product. It uses typed XPC requests and never
persists Server credentials. Hub in this UI means
organization-scoped shared memory; Local means project and local draft work.

The Zig executable remains useful for CLI and MCP. New local runtime logic that
must be shared by Desktop and MCP belongs in daemon rather than a new Zig-local
state store.

## Read in this order

1. Read the OpenAPI files in `packages/api-contract/openapi`.
2. Read `crates/server/src/http.rs` and `repository.rs` for authority behavior.
3. Read `crates/daemon/src/lib.rs` and `ipc.rs` for local synchronization.
4. Read `apps/macos/Sources/Infrastructure/DaemonXPCClient.swift` for daemon transport.
5. Read `apps/macos/Sources/Features/WorkspaceView.swift` for product workflow composition.
