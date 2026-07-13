# Runtime

## Local daemon

`clumsiesd` is an owner-scoped macOS launchd service. Desktop installs and
starts it through native Tauri commands. MCP connects to the same process over
XPC. The daemon has one local SQLite database for durable client state.

The database currently stores:

- installation identity and schema version
- Server URL and selected project configuration
- access and refresh tokens
- local drafts and ordered operations
- synchronization status, failures, and Server draft identity

File permissions are owner-only. Token storage must move to macOS Keychain
before production release; SQLite token persistence is not the desired final
security boundary.

## Desktop request path

The TypeScript client builds standard OpenAPI-shaped `Request` objects. A custom
transport serializes them into a typed Tauri command. Native Rust sends that
request to daemon, and daemon sends the authenticated HTTP request to Server.

```text
React -> typed API client -> Tauri command -> XPC -> daemon -> HTTPS -> Server
```

This keeps all product API methods typed without exposing credentials to the
renderer or depending on WebView CORS.

## Draft synchronization

Every local operation is persisted before synchronization is attempted. The
queue supports create, update, rename, delete, and discard for Context, Rule,
Workflow, and Metaprompt resources.

Each draft carries:

- `project_id`
- `scope` (`org` or `project`)
- resource kind
- `base_commit_id`
- local draft ID and optional Server draft ID
- ordered operation history

The sync worker starts automatically, wakes when a new operation arrives or
configuration changes, and retries failed work. A local draft is reused across
successive edits, so repeated writes do not create one Server draft per
keystroke.

## MCP write path

MCP keeps the public `store(resource, op)` tool shape. Internally it adds the
current bound project ID and project scope before sending the operation to
daemon. The Rust daemon test suite consumes a literal Zig MCP envelope to keep
that cross-language contract executable.

MCP does not currently expose organization scope in `store`; interpreting the
same call as a Hub write would be ambiguous. Hub writes are explicit in Desktop.

The retained Zig cache does not yet record the Server `base_commit_id`. That
must be solved by Commit materialization before MCP drafts can preserve a
provably correct base while offline.

## Commit synchronization

The daemon contract has a `commit_sync` status channel, but no Commit download
worker exists yet. It reports idle with no fabricated cursor or success time.
The required future path is:

```text
Server Ref -> Commit -> Tree/Blobs -> atomic local materialization -> MCP reads
```

It must preserve the exact Commit ID consumed by MCP so a later local draft can
use that value as `base_commit_id`.

## Diagnostics

Desktop can read daemon health, bootstrap state, project configuration, sync
status, MCP status, draft lists, draft details, and operation results through
typed commands. It can request explicit retry without directly mutating queue
rows.

Server diagnostics are available at `/api/v1/admin/health`. Database, schema,
Commit service, and OIDC are reported as separate components.
