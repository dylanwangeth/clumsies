# Workspace

## What Workspace is

Workspace is the project boundary inside clumsies. It is where shared organizational behavior meets project-specific knowledge and local runtime state.

That sentence hides three different responsibilities, so it is worth unpacking them.

A workspace selects Artifact-backed behavior. It owns project context. It also acts as the server-side anchor for the manifest and cache that local runtime reads from.

This is why workspace is more than a folder binding and more than a repo name.

## What a workspace contains

A workspace combines several distinct object types that should not be collapsed into one bucket.

| Part | Ownership | What it is |
| --- | --- | --- |
| selected rules and workflows | reference to Artifact | shared behavioral assets chosen for this project |
| selected bundles | reference to Artifact | named group selections that expand into behavior content |
| context files | workspace-owned | project knowledge such as specs, ADRs, research, design notes |
| manifest | Server-generated | current indexed snapshot of workspace runtime state |
| local drafts | local in-progress work | edits not yet merged into Artifact or workspace mainline |

The first three rows are the most important. They explain why workspace exists as its own object rather than being implied by a local checkout path.

## Workspace is not the same thing as a repo

The specs are explicit about this: a workspace can bind to more than one local path and does not need to be reduced to a single repository checkout.

The server-side workspace ID is the real identity. Local paths are bindings recorded by the client. That distinction matters because the product is trying to model a project boundary, not just a folder on one machine.

## Binding: how local paths attach to a workspace

The current client records workspace bindings in:

```text
~/.clumsies/config.toml
```

That file stores at least:

| Field | Meaning |
| --- | --- |
| `server.url` | Server base URL |
| `[[workspaces]].name` | local label |
| `[[workspaces]].ws_id` | authoritative workspace ID |
| `[[workspaces]].paths` | local filesystem paths bound to this workspace |

This means a local path lookup is a resolution step, not identity creation. The client does not infer a workspace from a folder name. It resolves the folder through the binding config and then works against the authoritative `ws_id`.

A simplified example looks like this:

```toml
[server]
url = "http://127.0.0.1:8400"

[[workspaces]]
name = "clumsies"
ws_id = "ws-4a5c282474c9b5d9385dec0502267738"
paths = [
  "/Users/lilhammer/workspace/clumsies",
  "/Users/lilhammer/workspace/clumsies-docs"
]
```

That example makes two design points concrete.

First, both local paths bind to the same workspace ID. Second, the path list is only local resolution state. The server-side workspace still remains the real project identity.

The TUI can manage these bindings from Settings > Workspaces. A user can create
a workspace, choose an initial bundle, and bind a local directory without
leaving the TUI. The CLI `init` command remains available for scripts and
explicit setup.

Bound paths are a list, not a single value. A workspace can have several local
directories on one machine, and each path resolves back to the same server-side
workspace ID.

## Manifest: the current workspace snapshot

The manifest is the bridge between Server authority and local runtime. In the current implementation it is written to:

```text
~/.clumsies/workspaces/{workspace_name}/manifest.json
```

The current top-level schema is:

| Field | Meaning |
| --- | --- |
| `ws_id` | workspace identity |
| `name` | workspace name |
| `revision` | current workspace snapshot revision |
| `rules` | stable-ID keyed map of selected Artifact behavior |
| `context` | stable-ID keyed map of workspace context |

The current entry schema inside `rules` and `context` includes:

| Field | Meaning |
| --- | --- |
| `path` | runtime-relative path for the item |
| `hash` | content hash used during sync |
| `description` | optional schema-carried description |

A simplified example looks like this:

```json
{
  "ws_id": "ws-1",
  "name": "demo",
  "revision": 7,
  "rules": {
    "p-1": {
      "path": "rule/coding/00_COMPATIBILITY.md",
      "hash": "sha256:def",
      "description": ""
    }
  },
  "context": {
    "ctx-1": {
      "path": "spec/ARCHITECTURE.md",
      "hash": "sha256:abc",
      "description": ""
    }
  }
}
```

There are two design choices here that deserve explicit explanation.

First, the manifest is not just a list of names. It is the indexed state of the workspace.

Second, `rules` and `context` are keyed by stable IDs rather than paths. That keeps identity stable across rename. The system can understand that an item moved without pretending it was deleted and recreated.

For example, if a rule keeps the same `rule_id` but moves from `rule/coding/STYLE.md` to `rule/style/STYLE.md`, the manifest only needs to update the `path` field for that one entry. The client does not need to treat it as a delete plus a brand-new unrelated rule.

## Why manifest matters

The manifest does three jobs at once.

It tells the client what the workspace currently contains. It gives sync a stable object to compare against. It gives runtime surfaces one shared snapshot instead of forcing each client to invent its own discovery path.

That is why manifest belongs in the workspace model, not only in a sync page.

## Cache: the materialized side of workspace runtime

Each workspace also has a dedicated local runtime directory:

```text
~/.clumsies/workspaces/{workspace_name}/
```

The synced content lives under:

```text
~/.clumsies/workspaces/{workspace_name}/cache/
```

The current implementation materializes at least:

| Path under cache | Meaning |
| --- | --- |
| `rule/` | synced rules and workflows selected by the workspace |
| `context/` | synced workspace context files |
| `META_PROMPT.md` | cached meta prompt used by agent bootstrap |

This is where the workspace model touches runtime directly.

The local workspace directory has two layers:

| Path | Role |
| --- | --- |
| `~/.clumsies/workspaces/{workspace_name}/manifest.json` | workspace snapshot and sync index |
| `~/.clumsies/workspaces/{workspace_name}/cache/` | materialized files used by local runtime |

That split explains practical behavior. Sync can skip unchanged content because the manifest tells it what should exist and which hash each item should have. MCP can serve from local state because the cache already contains the materialized files.

## Context belongs to the workspace side

Context is where project-specific facts live. In the current design, that includes things like:

- architecture documents
- specs
- ADRs
- research notes
- design material
- journals

The important point is not the file type. The important point is ownership and role. Context is workspace knowledge.

That means context should not be explained as a special kind of Artifact content. It may be rendered into cache in a similar way, but it has a different collaboration destination and a different authority model.

## Artifact selections stay Artifact selections

Rules, workflows, and bundles remain Artifact-backed even after a workspace selects them. The workspace does not become their new authority. It becomes the project boundary that selects which shared behavioral assets should be active for this project.

That distinction is what keeps the object model clean:

- Artifact owns shared behavior
- workspace owns project knowledge
- manifest brings both into one runtime snapshot

The TUI exposes that split directly. From Artifact, a user can select rules and
import them into the active workspace. From Workspace, a user can select rules
and detach them from the workspace. Both flows update Server state and the local
manifest/cache instead of editing files by hand.

Import means "make this Artifact rule active in this workspace." Detach means
"stop selecting this Artifact rule for this workspace." Neither operation
changes the rule's Artifact identity.

## Drafts and review flow

Workspace also matters because real editing happens around it.

A local draft is not the same thing as synced cache. Cache is pulled state. Draft is in-progress work.

The collaboration split stays important here:

- rule-oriented edits move back toward Artifact proposal and review flow
- context-oriented edits move toward workspace-owned mainline

This is one of the reasons the workspace model exists at all. Without it, rule lifecycle and project-knowledge lifecycle would collapse into one ambiguous bucket.

## Workspace membership and authorization

The workspace boundary is also where membership starts to matter. A workspace is not only a content container. It is an authorization boundary for who can bind, inspect, edit, and review project-specific material.

That is why the server-side workspace object has to stay authoritative. If local folders were treated as identity, permission checks would become guesswork.

The TUI Settings surface includes workspace membership management. Maintainers
can create invite tokens, change workspace roles, and remove members. These
operations are checked against Server policy; the client presents errors in the
same modal when the user can retry the operation.

## Why Workspace matters in the docs

If docs talk only about Artifact, the system looks too centralized. If docs talk only about local cache, the system looks too accidental. Workspace is the object that explains how shared behavior, project-specific knowledge, sync, and runtime all meet in one place.
