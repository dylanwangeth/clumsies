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

## Tool loop

The current tool surface is:

- `activate`: send a natural-language task cue and receive ranked fragments
  ready for the current reasoning context.
- `load`: read complete resources by known stable ID or exact path.
- `store`: persist an explicit user-requested Context, Rule, or Workflow Draft.

Typical use is:

```text
activate(query, optional state)
  -> use returned fragments
  -> optionally load known complete resources
  -> store only when the user explicitly requests memory maintenance
```

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
