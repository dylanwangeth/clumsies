# Runtime

## Local daemon

`clumsiesd` is an owner-scoped macOS launchd service. Desktop installs and
starts it through native Tauri commands. MCP connects to the same process over
XPC. The daemon has one local SQLite database for durable client state.

The database currently stores:

- installation identity and schema version
- Server URL and selected project configuration
- local drafts and ordered operations
- synchronization status, failures, and Server draft identity
- immutable Blob, Tree, and Commit metadata
- installed organization and project Refs

File permissions are owner-only. Access and refresh tokens are stored as one
Server-bound generic-password item in macOS Keychain. SQLite never persists
either token, and daemon has no plaintext credential fallback.

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

When the caller omits `base_commit_id`, daemon reads it from the installed
project Ref before creating the local draft. A missing Ref produces a draft
with no base; daemon never invents a Commit ID.

MCP does not currently expose organization scope in `store`; interpreting the
same call as a Hub write would be ambiguous. Hub writes are explicit in Desktop.

Local drafts and authority generations are currently separate read models.
`store` persists and synchronizes a draft, but MCP `activate` and `retrieve`
continue to read the installed authority generation until a later effective
local view overlays open drafts.

## Commit synchronization

The daemon synchronizes both organization and project Refs on its background
interval and through explicit retry:

```text
Server commit-state + ETag
  -> validate Ref identity
  -> download Commit payload
  -> verify Blob addresses and Tree ownership
  -> build an immutable project generation
  -> move the local SQLite Ref
  -> MCP asks daemon for that exact generation
```

The generation is built under a temporary directory and renamed before the Ref
transaction commits. A failed download, invalid payload, or incomplete
generation leaves the previous Ref and MCP-visible files unchanged. The
`commit_sync.server_cursor` is the installed project Commit ID, not a fabricated
timestamp or independent revision.

Server currently publishes full Commit payloads, so incremental object transfer
is not implemented. Cached immutable objects are retained for restart and
integrity checks; type-aware diff and merge remain separate work.

## Diagnostics

Desktop can read daemon health, bootstrap state, project configuration, sync
status, MCP status, draft lists, draft details, and operation results through
typed commands. It can request explicit retry without directly mutating queue
rows.

Server diagnostics are available at `/api/v1/admin/health`. Database, schema,
Commit service, and OIDC are reported as separate components.
