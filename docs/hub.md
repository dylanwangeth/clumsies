# Hub

## What Hub is

Hub is the authority layer of clumsies. It is the server-side system that owns Artifact, workspace manifests, context collaboration state, authentication, and aggregated attestation data.

If you only remember one sentence from this page, it should be this: Hub is the only place in the architecture that is supposed to own business truth.

## Why Hub exists

The project specs describe a clear reason for introducing Hub instead of staying with purely local prompt folders. Teams need one organizational source of rules and workflows. Multiple machines and multiple members need a shared workspace state. Attestation needs to be aggregated beyond one local checkout. Collaboration needs review, merge, and authorization boundaries.

Without Hub, those concerns either stay manual or get reimplemented inconsistently in local runtime surfaces. The result would be a system that feels convenient in one repo but falls apart as soon as rules, context, and usage evidence need to move across projects.

## What Hub owns

The top-level architecture and Hub specs break Hub into several server-side domains:

| Domain | Responsibility |
| --- | --- |
| Auth | identities, tokens, roles, and effective access |
| Artifact | rule truth, rule metadata, bundle views, review flow |
| Workspace | workspace lifecycle, manifest, rule membership |
| Context | workspace-owned knowledge and context collaboration |
| Collaboration | PR-style review and merge paths |
| Attestation and stats | event ingestion, aggregation, and analysis |

This is the real product core. CLI, MCP, TUI, and adapters matter, but they orbit these domains rather than replacing them.

The current HTTP server wiring in `src/hub/server.zig` makes that split concrete. The server exposes route groups for:

- `/api/auth/*`
- `/api/members*`
- `/api/workspaces/*`
- `/api/workspaces/:ws_id/rules/*`
- `/api/workspaces/:ws_id/context/*`
- `/api/artifact/*`
- `/api/bundles*`
- `/api/attestations`
- `/api/stats*`
- `/api/prs*`

That list matters because it shows what Hub really is in the current implementation: not just a login endpoint and a manifest service, but the place where identities, artifact state, workspace state, review state, and attestation ingestion are all coordinated.

## The actual API surface

The docs should not stop at route family names. Hub is a concrete JSON API, and several runtime surfaces depend on exact endpoint behavior.

These are the route families that matter most in the current implementation:

| Domain | Route family | Used by |
| --- | --- | --- |
| auth | `/api/auth/*` | CLI, TUI, adapters |
| membership | `/api/members*` | org administration, TUI |
| workspace | `/api/workspaces/*` | CLI init, sync, TUI |
| workspace rules | `/api/workspaces/:ws_id/rules*` | sync, TUI |
| workspace context | `/api/workspaces/:ws_id/context/*` | sync, TUI, agent proposals |
| Artifact | `/api/artifact/*`, `/api/bundles*` | sync, TUI, CLI |
| PR review | `/api/prs*`, `/api/workspaces/:ws_id/context/prs*` | TUI, collaboration flow |
| attestation and stats | `/api/attestations`, `/api/stats*` | TUI startup upload, TUI analysis |

The important point is architectural. Hub is not "the place that sometimes answers manifest requests." It owns the wire contract that every serious client surface already depends on.

## Hub and clients

Hub is not supposed to be one client surface among several equal peers.

| Layer | Role |
| --- | --- |
| Hub | authority and coordination |
| CLI | human operational client |
| MCP | agent-facing protocol client |
| TUI | human visual client |
| Adapter | host integration layer |

That split is important because the repository includes a lot of runtime code. The docs should help the reader keep that code in perspective instead of mistaking local execution surfaces for system truth.

## Hub and manifest

One of Hub's most important jobs is maintaining workspace manifest state.

Manifest is how Hub publishes which rules and workflows belong to a workspace, which context files belong to it, which content hashes are current, and which revision clients should compare against.

In the running server, that authority surface is the workspace manifest endpoint:

```text
GET /api/workspaces/:ws_id/manifest
```

That endpoint is what lets local runtime avoid rediscovering state object by object. The client pulls one indexed snapshot, stores it as `~/.clumsies/workspaces/{workspace_name}/manifest.json`, and then uses hashes to decide what must be refreshed under `cache/`.

This is the bridge between server-side authority and local non-blocking runtime. Clients do not need to rediscover the workspace by crawling local files or asking ad hoc APIs for each object. They can sync one indexed snapshot, compare revisions and hashes, and then refresh only what changed.

### `GET /api/workspaces/:ws_id/manifest`

This endpoint is the core of workspace sync. The current response shape is `WorkspaceManifestResponse`:

```json
{
  "ws_id": "ws-4a5c282474c9b5d9385dec0502267738",
  "name": "clumsies",
  "revision": 12,
  "rules": {
    "p-b9c03c6b-d55a-41d0-a61c-768367f9005a": {
      "path": "style/UIUX_DESIGN_METHOD.md",
      "hash": "sha256:...",
      "description": ""
    }
  },
  "context": {
    "ctx-architecture": {
      "path": "01_ARCHITECTURE.md",
      "hash": "sha256:...",
      "description": ""
    }
  }
}
```

The implementation also sets an `ETag` shaped like `"rev-<revision>"`. Clients can send `If-None-Match` and get `304` when nothing changed. That is one of the reasons sync can be cheap even though the system is Hub-centered.

Two details matter here:

- `rules` and `context` are stable-ID keyed maps, not arrays
- Hub, not the client, decides the current workspace revision

That is why `manifest.json` in local runtime should be understood as a cached Hub snapshot, not as a source of truth invented on the machine.

## Hub and content retrieval

Manifest answers "what exists." The content endpoints answer "what does it contain."

### Artifact content endpoints

The current Artifact endpoints separate metadata from full content:

| Endpoint | What it returns |
| --- | --- |
| `GET /api/artifact/rules` | metadata list for Artifact rules |
| `POST /api/artifact/rules/content` | batch rule content fetch |

The split is intentional. TUI often wants metadata-first browsing, while sync
and preview panes need content by stable rule id. Content loads always go
through the batch endpoint, even for a single selected rule, so fast scrolling
can be debounced and coalesced behind one request shape.

A simplified `GET /api/artifact/rules` response looks like:

```json
{
  "rules": [
    {
      "rule_id": "p-e2cf9316-3a30-4b66-9598-53bcb6e88769",
      "path": "arch/TECH_WRITING.md",
      "content_hash": "sha256:...",
      "updated_at": "2026-04-23 09:58:21+00",
      "source": "default"
    }
  ]
}
```

And the batch content endpoint returns:

```json
{
  "items": [
    {
      "rule_id": "p-e2cf9316-3a30-4b66-9598-53bcb6e88769",
      "path": "arch/TECH_WRITING.md",
      "content_hash": "sha256:...",
      "body": "# Technical Writing\n...",
      "error": ""
    }
  ]
}
```

### Workspace rule endpoints

Workspace rules are the subset of Artifact rules attached to a workspace. The
workspace route keeps the permission and attachment boundary explicit:

| Endpoint | What it returns |
| --- | --- |
| `GET /api/workspaces/:ws_id/manifest` | revisioned workspace rule and context metadata |
| `POST /api/workspaces/:ws_id/rules` | attach Artifact rules to a workspace |
| `POST /api/workspaces/:ws_id/rules/content` | batch content fetch for attached rules |
| `POST /api/workspaces/:ws_id/rules/detach` | detach Artifact rules from a workspace |

The content response uses the same item shape as
`POST /api/artifact/rules/content`, but it only serves rules attached to the
requested workspace.

### Workspace context endpoints

Workspace context follows the same overall pattern, but it stays workspace-scoped:

| Endpoint | What it returns |
| --- | --- |
| `GET /api/workspaces/:ws_id/context` | metadata list for context entries |
| `POST /api/workspaces/:ws_id/context/content` | batch context content fetch |

A simplified `GET /api/workspaces/:ws_id/context` response looks like:

```json
{
  "files": [
    {
      "context_id": "ctx-architecture",
      "path": "01_ARCHITECTURE.md",
      "content_hash": "sha256:...",
      "size": 8421,
      "author": "lilhammer",
      "updated_at": "2026-04-22 18:17:04+00"
    }
  ]
}
```

This is one of the cleanest examples of the product boundary. Rules live in org Artifact. Context lives in a workspace. Hub exposes both through similar shapes without flattening them into the same domain.

## Hub and collaboration

Hub is also where collaboration becomes a product feature rather than a side effect of editing files.

Two review paths matter. Rule-oriented work flows back toward Artifact. Context-oriented work flows into workspace-owned context mainline.

The current route split reflects that design while keeping the main review
queue under a single resource:

- PR listing, rule PR create/detail/action/comment flows go through `/api/prs*`
- workspace context PR create/detail/action/comment flows go through `/api/workspaces/:ws_id/context/prs*`

That separation is one of the most important boundaries in the product. Rules are shared organizational behavior assets. Context is workspace-owned project knowledge. Both need review semantics, but they do not belong to the same authority domain.

Those paths are related but not identical. Hub is what keeps them coherent without flattening rules and context into the same lifecycle. That distinction is one reason clumsies can treat organizational behavior and project knowledge as separate assets without making the overall system feel fragmented.

### Rule PRs versus context PRs

The difference becomes clearer when you look at the actual create-PR request shape.

Rule PR creation goes to:

```text
POST /api/prs
```

with an operation-based body:

```json
{
  "description": "Split the adapter guidance into host-specific sections.",
  "operations": [
    {
      "type": "modify",
      "rule_id": "p-adapter",
      "base_hash": "sha256:old",
      "content": "# Adapter\n..."
    }
  ]
}
```

The operation types are `modify`, `rename`, `create`, and `delete`. Validation is hash-bound. If `base_hash` no longer matches current Artifact state, Hub returns `409`.

Context PR creation follows the same operation model, but at workspace scope:

```text
POST /api/workspaces/:ws_id/context/prs
```

with context-specific identity fields:

```json
{
  "description": "Update the architecture note for the new MCP flow.",
  "operations": [
    {
      "type": "modify",
      "context_id": "ctx-architecture",
      "base_hash": "sha256:old",
      "content": "# Architecture\n..."
    }
  ]
}
```

This is exactly the sort of design-level detail a docs page should preserve. The review model is parallel, but not identical.

## Hub and membership

Hub also owns the authorization boundary that local runtime cannot safely fake.

There are two membership layers in the current implementation:

| Scope | Route family | What it controls |
| --- | --- | --- |
| org membership | `/api/members*` | who belongs to the organization and what org role they have |
| workspace membership | `/api/workspaces/:ws_id/members*` | who can access a specific workspace and what role they have there |

This is why a workspace is not only a local path binding. The server-side object has members, revisioned state, and policy boundaries. Local runtime can cache that state, but it should not invent it.

## Hub and stats

Hub is also where local attestation becomes aggregated product-level evidence.

The upload endpoint is:

```text
POST /api/attestations
```

and the stats family is:

- `GET /api/stats`
- `GET /api/stats/workspace/:ws_id`
- `GET /api/stats/rule/:rule_id`

The current org-level response shape is not a toy analytics payload. It already includes:

```json
{
  "total_refer_count": 481,
  "workspace_count": 6,
  "rule_count": 42,
  "rules": [
    {
      "rule_id": "p-e2cf9316-3a30-4b66-9598-53bcb6e88769",
      "refer_count": 38,
      "active_constraint_count": 6,
      "workspace_count": 3,
      "bundle_count": 1,
      "open_pr_count": 0,
      "last_referred_at": 1713848811000,
      "trend": [0, 1, 4, 3, 7, 2, 5]
    }
  ],
  "users": [],
  "trend": {
    "period": "daily",
    "data": []
  }
}
```

That shape is why the TUI can render rule ranking, recent trend, and member activity without inventing a second analytics backend.

## Why interface detail belongs on this page

If this page only says "Hub is the authority layer," it is still missing the most useful proof: the current implementation already exposes a coherent, typed, versioned API surface.

That is what makes Hub more than an architectural aspiration. It is already the concrete integration point for sync, TUI, MCP-adjacent runtime, collaboration, and attestation.

## Hub and deployment

The specs position Hub as a self-hosted service backed by PostgreSQL and exposed through a RESTful JSON API. In other words, Hub is not an optional cloud control plane bolted onto a local tool. It is the intended backend architecture of the system.

That is why the public docs should explain Hub early instead of leaving it implicit behind CLI examples.
