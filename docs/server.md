# Server

Server is the deployable authority service for clumsies. **Hub is not another
service name**: Hub is a historical Desktop label for the organization scope of
the unified Memory model. The Rust binary and container are named Server.

## Responsibilities

Server owns:

- organization membership, project membership, roles, and token sessions
- organization and project Memory (the unified model)
- personal Bundles (`resource_ids`)
- drafts, draft operation history, reviews, decisions, comments, and merges
- immutable Commit history, Trees, Blobs, and movable organization/project Refs
- admin configuration, token revocation, audit events, and health reporting

Desktop and MCP write local drafts through the daemon. The daemon synchronizes
them to Server. Local directory-to-Project bindings belong to daemon SQLite;
Server only supplies and authorizes the canonical `project_id`. Project Local
Storage paths, macOS bookmarks, per-Project search databases, and storage move
jobs also belong exclusively to daemon and never enter a Public or Admin Server
endpoint. No client is allowed to update authoritative memory directly.

## Version model

The authority graph uses Git terminology because the concepts are equivalent:

```text
Blob -> Tree -> Commit -> Ref
                    ^
Draft(base_commit_id)
```

Each organization and project has its own Ref. A merge locks the target Ref,
checks `If-Match`, verifies that the Draft is based on that Commit, creates a new
immutable Commit, and advances only that Ref. Project metadata revision is
separate from memory history.

The unified Memory endpoints are `GET /api/v1/org/memories`,
`GET /api/v1/projects/{project_id}/memories`, and the corresponding
`{memory_id}` detail routes. An org-admin `GET /api/v1/admin/memory-export`
emits every Memory (including `issues/` paths), all Drafts with their raw
operations, Project org selections, and personal bundles as the repeatable,
verifiable migration export.

Draft lifecycle (`open`, `submitted`, `merged`, `discarded`) is independent from
freshness (`current`, `behind`) and reconciliation (`unknown`, `clean`,
`conflicts`). When a Ref advances, Server keeps the Draft Base and operations
unchanged. It computes a canonical Base/Current/Draft candidate only when asked,
and applies it only after explicit confirmation. Rebase saves an immutable Draft
revision before atomically changing `base_commit_id` and operations.
Applying a clean candidate always uses the Server's canonical proposed result;
only a conflicts candidate accepts a complete user-resolved state.

Creating or resubmitting a Review and merging an approved Review are coordination
boundaries. Review creation/submission can apply a confirmed candidate in the
same Ref-locked transaction. Merge never performs the first stale check as a
normal workflow; it retains `If-Match`/CAS as the final concurrency guard.

The detailed state model and failure semantics are maintained in the Obsidian
architecture document `architecture/draft-reconciliation.md`.

## HTTP contracts

The OpenAPI sources are the canonical wire contracts:

| Contract | Scope |
| --- | --- |
| `packages/api-contract/openapi/clumsies.public.v1.yaml` | Desktop and daemon product API |
| `packages/api-contract/openapi/clumsies.admin.v1.yaml` | Web Admin API |
| `packages/api-contract/openapi/clumsies.daemon.v1.yaml` | local daemon IPC capability map |

Authentication uses the organization's OIDC provider in the system browser. Desktop uses an
ephemeral loopback callback and PKCE, then sends the issued token pair directly
from native Rust to daemon. The renderer never receives bearer or refresh
tokens. Daemon performs authenticated Server requests, rotates the refresh
token after a `401`, persists the replacement pair, and retries once.

## Run locally

Local development runs PostgreSQL and a deterministic fake OIDC provider in
Docker, then runs the Rust Server natively for a fast edit-and-run cycle. It
requires no enterprise identity configuration:

```bash
bun run dev:server
```

The default endpoints are:

| Service | Address |
| --- | --- |
| Server | `http://127.0.0.1:18080` |
| PostgreSQL | `127.0.0.1:5432` |
| Fake OIDC | `http://127.0.0.1:18081/clumsies` |
| Health | `http://127.0.0.1:18080/api/v1/admin/health` |

The stack uses
[NAV's mock OAuth2 server](https://github.com/navikt/mock-oauth2-server), pinned
to `4.0.0`. It automatically authenticates `owner@clumsies.local`, matching the
default bootstrap owner. It still exercises discovery, authorization code and
PKCE handling, signed ID tokens, JWKS verification, and nonce validation. The
fake provider is never part of `compose.production.yml`.

Stop the local services with:

```bash
bun run dev:infra:down
```

## Run in production

Copy `.env.example` to `.env`, configure the enterprise OIDC values, and start
`compose.production.yml`. Set `CLUMSIES_PUBLIC_ORIGIN` to the Server's canonical
HTTPS origin and register its derived `/login/oauth2/code/oidc` URL with the
organization's IdP. The same origin serves Public API, Admin API, Web Admin, and
OIDC callbacks.

When OIDC variables are intentionally empty, Server still starts so health and
database diagnostics remain available. Health reports the OIDC component as
`down`, and login is unavailable. That state is for infrastructure smoke tests,
not a usable deployment.

## Verify

```bash
bun run api:check
cargo test -p server
cargo test -p daemon
```

Server and daemon integration tests use Testcontainers with a real PostgreSQL
instance. The repository also verifies the production Docker image and Compose
health path.
