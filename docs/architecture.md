# Architecture

## System boundary

```mermaid
flowchart LR
    subgraph Machine["User machine"]
        Desktop["Desktop"]
        MCP["Zig MCP server"]
        CLI["CLI"]
        Daemon["Rust daemon"]
        LocalDB[("Local SQLite")]
        ProjectStorage["Project Local Storage<br/>generations + search index"]
        Models["Shared model cache"]
    end

    subgraph Deployment["Self-hosted deployment"]
        Server["Rust Server"]
        Postgres[("PostgreSQL")]
        Admin["Web Admin"]
    end

    Browser["System browser / organization OIDC"]

    Desktop -->|"macOS XPC"| Daemon
    MCP -->|"activate / load / store over XPC"| Daemon
    CLI -.->|"client operations"| Daemon
    Daemon --> LocalDB
    Daemon -->|"resolve + atomic materialization"| ProjectStorage
    Daemon --> Models
    Daemon -->|"authenticated HTTPS"| Server
    Desktop --> Browser
    Browser --> Server
    Server --> Postgres
    Admin -->|"Admin API"| Server
```

## Why Desktop and daemon both exist

A browser cannot reliably own arbitrary local project files or remain available
when its page is closed. Desktop provides the native user experience and local
file access; daemon provides a lifecycle independent from whether the Desktop
window is open.

For example, an MCP `store` call can create a draft while Desktop is closed.
Daemon persists and synchronizes it. When Desktop opens later, it reads the same
draft queue. Conversely, a draft edited in Desktop remains available to MCP
because it was not stored in renderer state.

## Ownership

| Component | Owns | Does not own |
| --- | --- | --- |
| Server | authority resources, identity, authorization, review state, Commit graph, audit | local files and client process lifecycle |
| daemon | local Project bindings, Project storage registry, local drafts, queued operations, cached Blob/Tree/Commit objects, installed Refs, immutable generations, derived search indexes, refresh handling, native Server proxy | authority decisions and merge policy |
| Desktop | interaction state, editors, navigation, review workflows | bearer tokens and durable authority |
| MCP | activation, exact loading, and agent-originated store calls | a parallel draft database or search implementation |
| Web Admin | administrative operations | memory editing and review workflows |

## Write path

```mermaid
sequenceDiagram
    participant C as Desktop or MCP
    participant D as daemon
    participant S as Server
    participant P as PostgreSQL

    C->>D: store(project_id, scope, resource, op, base_commit_id)
    D->>P: no direct access
    D->>D: persist local draft and queued operation
    D-->>C: local operation accepted
    D->>S: create/reuse draft and append operation
    S->>P: transaction
    S-->>D: server draft/version
    D->>D: mark operation synchronized
```

The first response is local acceptance, not publication. Automatic sync retries
failed operations. Desktop can inspect pending/failed sync separately from
behind/conflicts coordination; neither coordination state blocks editing.

## Review and merge path

```mermaid
sequenceDiagram
    participant Desktop
    participant Daemon
    participant Server
    participant DB as PostgreSQL

    Desktop->>Daemon: request candidate when Draft is behind
    Daemon->>Server: compare Base / Current / Draft Result
    Server->>DB: persist immutable candidate only
    Desktop->>Daemon: confirm result and create or resubmit Review
    Daemon->>Server: candidate + resolved state + If-Match
    Server->>DB: save Draft revision, rebase and submit atomically
    Desktop->>Daemon: merge with If-Match target Ref
    Daemon->>Server: POST review merge
    Server->>DB: lock Ref, check current Base and approval, write Blob/Tree/Commit, move Ref
    Server-->>Desktop: new commit_id
```

Organization and project Refs are independent. Merging a Hub draft advances the
organization Ref only; merging a Local draft advances the selected project Ref
only.

## Authority read path

```mermaid
sequenceDiagram
    participant S as Server
    participant D as daemon
    participant DB as SQLite
    participant F as generation files
    participant M as MCP

    M->>D: resolve_project_binding(current directory)
    D-->>M: canonical project_id
    D->>S: GET project commit-state(local_commit_id)
    S-->>D: Ref, latest Commit, ETag, download URL
    D->>S: GET Commit payload
    D->>D: validate Commit, Tree, Blobs, ownership, paths
    D->>F: build temporary generation and atomic rename
    D->>DB: cache objects and move local Ref in one transaction
    M->>D: activate_memory or load_memory over XPC
    D->>F: read exact generation and overlay local Drafts
    D-->>M: ranked fragments or complete resources
```

The SQLite Ref is the only mutable authority pointer. Moving it does not move a
Draft Base. Search heads are local derived pointers bound to an Effective Memory
hash. For Draft resources, that memory uses `Base + operations`; for all other
resources it uses the latest installed Commit. MCP never scans cache files or
falls back to an old generation when daemon has no matching ready index.

## Project Local Storage

Project Local Storage controls where one installation keeps a Project's
rebuildable generations and search index. Its registry key is:

```text
(normalized Server authority, canonical project_id)
```

The setting belongs to daemon even though Desktop presents it under Project
settings. Server never receives the path or macOS bookmark. Central SQLite keeps
Drafts, queued operations, cached authority objects, local Refs, storage move
state, and the Project search-head registration. Shared retrieval models remain
in the daemon cache.

```mermaid
sequenceDiagram
    participant UI as Desktop Settings
    participant D as daemon
    participant S as Source cache
    participant T as Destination managed subtree

    UI->>D: replace_project_storage(handoff_bookmark, expected_location_revision)
    D->>D: resolve handoff and create daemon-owned security-scoped bookmark
    D-->>UI: persistent move_id
    D->>T: materialize staging generations and search index
    D->>T: verify Commit markers, Ref generation, Effective Memory hash
    D->>D: acquire storage write gate and CAS location revision
    D->>T: promote staging atomically
    D->>S: remove only the verified marker-owned subtree
    D-->>UI: completed location
```

Commit sync and storage moves share one sync mutex, so a local Ref cannot advance
during the switch. Requests already reading the source hold a storage read gate;
cleanup waits for them. If a custom volume is unavailable, daemon reports that
location as unavailable and does not create an active cache elsewhere. Draft
editing and Draft sync remain available because they do not live in Project
Local Storage.

## Retrieval history and evaluation

Every valid memory activation produces one local Retrieval Run. The daemon
persists the exact/BM25, vector, RRF, reranker, and final rank values from the
same candidate trace used to assemble the MCP response. It also records the
Effective Memory and Index Revision identities, stage latency, stable exclusion
reason, delta action, and bounded failure details.

Retrieval Runs and Evaluation Cases live in central local SQLite, while frozen
resource bodies use a daemon-owned content-addressed blob store. They do not
move with Project Local Storage and are never uploaded to Server. A user may
pin a successful Run as a versioned Evaluation Case, label retrieved units or
missed resources with relevance 0–3, and export a self-contained fixture with
B1–B4 metrics. See `docs/retrieval-evaluation.md`.

## Local Project binding

The Server connection, the Desktop-selected Project, and a local directory
binding are separate state:

```text
Server authority + credentials
Local canonical workspace root -> canonical project_id
Desktop selected project_id (UI only)
```

Daemon persists bindings in SQLite under the normalized Server authority and
resolves the longest canonical ancestor of the MCP working directory. Commit
sync enumerates all bound Projects, so two MCP processes can use different
Projects concurrently while Desktop is closed or displaying a third Project.
Legacy `ws_id` configuration is only a one-time name-and-path migration source;
it is not part of the runtime identity model.

## Authentication boundary

The native macOS app owns the browser loopback listener and PKCE verifier. After
the code exchange and `/api/v1/me` lookup succeed, the app sends the token pair
directly to daemon over XPC.

Daemon injects bearer tokens into Server requests. On `401`, it rotates the
refresh token and retries exactly once.

## Platform boundary

The current daemon transport is macOS launchd plus XPC. Its LaunchAgent label
and Mach service are both `ai.clumsies.daemon`, under the `ai.clumsies` product
namespace. Windows is a later roadmap item and will need a native service
manager and IPC transport behind the same daemon capability contract. It is not
implemented as a degraded fallback.

## Incomplete boundary

Draft upload, remote projection, Commit download, atomic local materialization,
Effective Memory Draft overlay, canonical three-way reconciliation, explicit
rebase, Review freshness, hybrid retrieval, exact loading, activation delta, and
macOS Keychain token storage, local Retrieval Run history, Evaluation Case
labeling, B1–B4 metric calculation, and native Retrieval Diagnostics are
operational. A representative human-reviewed retrieval query set and Windows
service transport remain outside the implemented boundary.
