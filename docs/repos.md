# Codebase map

Clumsies is an active Bun, Swift, and Rust monorepo. Ownership follows runtime
boundaries rather than language alone. The retired Zig client is preserved only
as historical source under `archive/zig-cli/`; it is outside active builds,
tests, packaging, and release artifacts.

| Path | Responsibility |
| --- | --- |
| `apps/macos/` | Native macOS product client built with AppKit and SwiftUI |
| `crates/server/` | deployable Rust authority service and PostgreSQL schema |
| `crates/daemon/` | resident macOS launchd daemon, local state and workers, Agent runtime proxies, native adapter installer, and XPC contracts |
| `packages/api-contract/` | Public, Admin, and daemon OpenAPI contracts |
| `packages/api-client/` | generated-type-backed TypeScript clients |
| `assets/adapters/` | host-specific integration assets |
| `archive/zig-cli/` | historical Zig CLI, MCP, TUI, and attestation source; not a supported runtime |
| `docs/` | VitePress public documentation |

## Authority boundaries

`crates/server` owns authoritative organization and project memory, identity,
authorization, Bundles, review lifecycle, and Commit history.

`crates/daemon` owns local drafts, queued operations, automatic synchronization,
token refresh, retrieval, native Server transport, and both short-lived Agent
proxy modes. A proxy validates and forwards typed requests to the resident
process over XPC; it does not initialize daemon state. The crate is not an
authority source.

`apps/macos` is the primary human product. It uses typed XPC requests and never
persists Server credentials. Hub in this UI means
organization-scoped shared memory; Local means project and local draft work.

The App bundle contains one signed `clumsiesd`. launchd runs it as the resident
daemon, while supported Agent hosts run the same binary as `mcp serve` or
`_agent issue-run-event`. Adapter manifests pin the bundled path and release
identity so another checkout or stale helper cannot become the runtime.

## Read in this order

1. Read the OpenAPI files in `packages/api-contract/openapi`.
2. Read `crates/server/src/http.rs` and `repository.rs` for authority behavior.
3. Read `crates/daemon/src/lib.rs` and `ipc.rs` for local synchronization.
4. Read `crates/daemon/src/main.rs` and `agent_runtime/` for resident/proxy process boundaries.
5. Read `crates/daemon/src/agent_adapter.rs` for host installation and migration.
6. Read `apps/macos/Sources/Infrastructure/DaemonXPCClient.swift` for daemon transport.
7. Read `apps/macos/Sources/Features/WorkspaceView.swift` for product workflow composition.
