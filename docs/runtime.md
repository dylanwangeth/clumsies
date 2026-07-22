# Runtime

## Local daemon

`clumsiesd` is an owner-scoped macOS launchd service. The macOS app installs and
starts it, while both the app and MCP connect to the same process over XPC. The
daemon has one local SQLite database for durable client state.

The database currently stores:

- installation identity and schema version
- Server URL and selected project configuration
- canonical local Project bindings from Server authority plus workspace root to `project_id`
- local drafts and ordered operations
- synchronization status, failures, and Server draft identity
- immutable Blob, Tree, and Commit metadata
- installed organization and project Refs
- derived search revisions, complete effective resources, Markdown units,
  FTS5 rows, and local vectors

File permissions are owner-only. Access and refresh tokens are stored as one
Server-bound generic-password item in macOS Keychain. SQLite never persists
either token, and daemon has no plaintext credential fallback.

## Desktop request path

The native Swift client serializes typed capability requests over XPC. Daemon
executes local operations or sends authenticated HTTP requests to Server.

```text
SwiftUI/AppKit -> XPC -> daemon -> HTTPS -> Server
```

This keeps credentials in daemon and macOS Keychain without a WebView or CORS
dependency.

## Draft synchronization

Every local operation is persisted before synchronization is attempted. The
queue supports create, update, rename, delete, and discard for Context, Rule,
and Workflow resources.

Each draft carries:

- `project_id`
- `scope` (`org` or `project`)
- resource kind
- `base_commit_id`
- the currently installed target Ref Commit
- derived freshness and Server reconciliation projection
- local draft ID and optional Server draft ID
- ordered operation history

The sync worker starts automatically, wakes when a new operation arrives or
configuration changes, and retries failed work. A local draft is reused across
successive edits, so repeated writes do not create one Server draft per
keystroke.

## MCP write path

MCP keeps the public `store(resource, op)` tool shape. Internally it adds the
current bound project ID and project scope before sending the operation to
daemon. At process startup, MCP gives its current working directory to daemon;
daemon canonicalizes the path and resolves the nearest bound ancestor in
SQLite. MCP never treats a legacy Workspace ID as a Project ID. The Rust daemon
test suite consumes a literal Zig MCP envelope to keep that cross-language
contract executable.

An old `~/.clumsies/config.toml` entry is used only when no daemon binding
exists. MCP matches its display name against the signed-in user's Server
Projects, persists the unique canonical `project_id` in daemon, and removes the
migrated path from the old file. Missing or duplicate matches fail explicitly;
the legacy `ws_id` value is never sent to daemon.

When the caller omits `base_commit_id`, daemon reads it from the installed
project Ref before creating the local draft. A missing Ref produces a draft
with no base; daemon never invents a Commit ID.

MCP does not currently expose organization scope in `store`; interpreting the
same call as a Hub write would be ambiguous. Hub writes are explicit in Desktop.

The daemon combines the installed authority generation with current
`open`/`submitted` Draft operations before both `activate` and `load`. For a
resource with a Draft, it restores that resource from the Draft Base Commit,
applies the ordered operations, and overlays the complete Draft result on the
latest installed authority. All other resources come from the latest Commit.
This applies equally to create, update, rename, and delete. A successful `store`
therefore changes the next Effective Memory hash and causes the next activation
to build or select a matching search revision.

## Synchronization and reconciliation

Draft sync and Commit sync are independent. Commit sync may update the local Ref,
`current_commit_id`, freshness, and candidate validity, but it never changes a
Draft Base, operations, content, or lifecycle. A behind Draft remains editable,
syncable, restart-safe, and visible to MCP.

Server is the canonical reconciliation executor. A candidate binds Draft ID,
Draft version, Base Commit, and current Commit, and is either `clean` or
`conflicts`. Merely creating or viewing it does not mutate the Draft. Explicit
rebase stores the previous Draft revision and rewrites the Draft as
`base = Current` plus `operations = diff(Current, confirmed result)`. Any Draft
edit or Ref advance invalidates the old candidate.

## Commit synchronization

The daemon synchronizes both organization and project Refs on its background
interval and through explicit retry. Its target set is the union of durable
directory bindings, active Draft Projects, and the Project currently selected
by Desktop. Desktop selection is UI state and cannot redirect an MCP process in
another directory.

```text
Server commit-state + ETag
  -> validate Ref identity
  -> download Commit payload
  -> verify Blob addresses and Tree ownership
  -> build an immutable project generation
  -> move the local SQLite Ref
  -> daemon combines that generation with local Drafts
  -> MCP asks daemon to activate fragments or load complete resources
```

Before moving a local Ref, every sync also checks active `open` and `submitted`
Drafts and fetches any missing Base Commit, Tree, and Blob payloads referenced by
their `base_commit_id`. This preserves an old-Base overlay after a cache rebuild
without pinning the rest of the project to that Base.

The generation is built under a temporary directory and renamed before the Ref
transaction commits. A failed download, invalid payload, or incomplete
generation leaves the previous Ref and MCP-visible files unchanged. The
`commit_sync.server_cursor` is the installed project Commit ID, not a fabricated
timestamp or independent revision.

Server currently publishes full Commit payloads, so incremental object transfer
is not implemented. Cached immutable objects are retained for restart and
integrity checks. Active Draft Base references are retention roots and cannot be
garbage-collected.

Cache diagnostics preserve layer boundaries: an unknown local Ref reports
`project_ref_not_synced`; an absent or invalid materialized generation reports
`commit_generation_missing` or `commit_generation_corrupt`; only derived search
index preparation and build failures use search-index error codes.

## Diagnostics

Desktop can read daemon health, bootstrap state, project configuration, sync
status, MCP status, draft lists, draft details, and operation results through
typed XPC requests. It can request explicit retry without directly mutating queue
rows.

Server diagnostics are available at `/api/v1/admin/health`. Database, schema,
Commit service, and OIDC are reported as separate components.
