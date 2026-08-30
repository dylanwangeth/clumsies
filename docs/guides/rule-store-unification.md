# Effective Memory storage boundary

This page replaces the retired client-cache unification proposal. The active
runtime has one read model owned by the resident Rust daemon; no CLI cache or
Agent-host skill directory is an authority source.

## Current data flow

```text
Server Blob / Tree / Commit / Ref
  -> daemon validates and installs immutable Commit generations
  -> daemon applies current local Draft operations
  -> Effective Memory
  -> Project-local derived search revision
  -> clumsiesd MCP proxy forwards activate / load over XPC
```

`activate` and `load` read the same Effective Memory snapshot. A successful
`store` changes the local Draft overlay, which changes the Effective Memory hash
and queues a matching incremental Index Revision. The previously ready revision
remains readable until the new one publishes atomically.

## Ownership

| Data | Owner |
| --- | --- |
| canonical resource history and Refs | Server |
| cached immutable authority objects and local Ref pointers | resident daemon central SQLite |
| materialized Commit generations | Project Local Storage |
| current Drafts and queued operations | resident daemon central SQLite |
| complete Effective Memory resources, retrieval units, FTS rows, and vectors | Project-local search database |
| MCP parsing and response framing | short-lived `clumsiesd mcp serve` proxy |

The proxy does not read generation files, inspect an old manifest, or maintain a
second resource cache. The thin host-native skill layer is retired (ISSUE-064):
no adapter installs skills, and skill directories are not an authority source.

## Historical implementation

The former Zig CLI cache, MCP implementation, and workflow-skill generation
code are preserved under `archive/zig-cli/` only. They are outside the active
build, release, installation, and compatibility boundary.

See [Runtime](/runtime), [Architecture](/architecture), and [MCP](/mcp) for the
active contracts.
