# Server

Server is the deployable authority service for clumsies. **Hub is not another
service name**: Hub is the Desktop product view over organization-scoped shared
memory. The Rust binary and container are named Server.

## Responsibilities

Server owns:

- organization membership, project membership, roles, and token sessions
- organization and project Context, Rules, Workflows, and Metaprompt resources
- personal Bundles
- drafts, draft operation history, reviews, decisions, comments, and merges
- immutable Commit history, Trees, Blobs, and movable organization/project Refs
- admin configuration, token revocation, audit events, and health reporting

Desktop and MCP write local drafts through the daemon. The daemon synchronizes
them to Server. No client is allowed to update authoritative memory directly.

## Version model

The authority graph uses Git terminology because the concepts are equivalent:

```text
Blob -> Tree -> Commit -> Ref
                    ^
Draft(base_commit_id)
```

Each organization and project has its own Ref. A merge locks the target Ref,
checks `If-Match`, verifies that the draft still has the same base Commit,
creates a new immutable Commit, and advances only that Ref. Project metadata
revision is separate from memory history.

The current conflict policy is strict. If the Ref moved after the draft was
created, merge returns `409 Conflict`; the Server does not silently overwrite or
pretend to perform a three-way merge.

## HTTP contracts

The OpenAPI sources are the canonical wire contracts:

| Contract | Scope |
| --- | --- |
| `packages/api-contract/openapi/clumsies.public.v1.yaml` | Desktop, daemon, MCP, and CLI product API |
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
`compose.production.yml`. Expose Server through HTTPS and set
`CLUMSIES_OIDC_CALLBACK_URL` to the public
`/login/oauth2/code/oidc` URL registered with the organization's IdP.

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
