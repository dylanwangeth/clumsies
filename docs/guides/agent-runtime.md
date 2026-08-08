# Agent runtime

This page describes the host runtime path, not the human member workflow.

## Entrypoint

The current local MCP entrypoint is:

```bash
clumsies mcp serve
```

The repository must already resolve to a selected Project, the macOS daemon
must be installed and running, and its current Project Commit generation must
be ready. Supported adapters install the host's MCP registration and thin
skills; they do not own a second memory cache.

## Runtime path

```text
agent host
  -> Zig MCP stdio (`clumsies mcp serve`)
  -> Rust daemon over macOS XPC
  -> Effective Memory (installed Commit + current local Draft overlay)
  -> SQLite FTS/vector index and local ONNX models
```

MCP does not crawl the repository, read a workspace manifest, or append a
session attestation log. The daemon is the single owner of the current local
read and write model.

## Model preparation

The daemon starts model preparation in the background before the first MCP
request. It downloads a pinned int8
[`multilingual-e5-small`](https://huggingface.co/intfloat/multilingual-e5-small)
embedding model and a pinned int8
[`bge-reranker-base`](https://huggingface.co/Xenova/bge-reranker-base)
conversion. The complete payload is 431,831,479 bytes.

Every repository revision and artifact SHA-256 is fixed in the daemon. Files
are downloaded into the model cache with resume support, verified before ONNX
loading, and reused offline afterward. Search index status reports `preparing`
with downloaded and total bytes while this work is in progress. Activation
returns `search_model_preparing` immediately during that state; it never blocks
an MCP request on an unreported download and never falls back to a weaker
retrieval path.

## Tool loop

The current tool surface is:

- `activate`: send a natural-language task cue and receive ranked fragments
  ready for the current reasoning context.
- `load`: read complete resources by known stable ID or exact path.
- `store`: persist an explicit user-requested Context, Rule, or Workflow Draft.
- `kanban`: get a native Issue by global ID, create/update/list native Issues, explicitly start Issue work, or
  request Issue closure after semantic judgment.

Typical use is:

```text
activate(query, optional state)
  -> use returned fragments
  -> optionally load known complete resources
  -> store only for explicit Context, Rule, or Workflow maintenance
  -> kanban.get when the user supplies a copied global Issue ID
  -> kanban.create for durable new or follow-up work
  -> explicitly kanban.begin_work when this is durable Local Issue work
  -> kanban.request_closure only when acceptance criteria are satisfied
```

For an update, `load` is mandatory: use the returned complete-resource hash and
exact source text in one or more atomic `store.update` replacements. The agent
does not send a reconstructed complete document.

There is no setup call, host-session binding, or `META_PROMPT.md` bootstrap.
Protocol guidance comes from the MCP initialization instructions and tool
descriptions. The `state` returned by `activate` is only a bounded fragment
delta token; pass it again only while earlier fragments remain in model
context.

## Adapter boundary

Adapters make a concrete host launch the MCP server and expose thin host-native
skills. They may still manage host-specific hooks for capabilities outside the
MCP memory contract, but those hooks must not reimplement retrieval or inject a
second bootstrap protocol.

Members configure and select Projects through product clients. Agents consume
the selected Project through MCP. Keeping those roles separate prevents host
integration details from becoming a second memory system.
