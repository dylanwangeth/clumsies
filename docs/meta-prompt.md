# Metaprompt removal

> **历史迁移记录。** 本页说明已删除协议的迁移事实，不属于现行运行合同。
> 当前合同见 [MCP](/mcp) 与 [Agent 运行时](/guides/agent-runtime)。

`META_PROMPT.md` is no longer part of the agent runtime contract or the search
corpus. The MCP server delivers stable protocol guidance through
`InitializeResult.instructions` and each tool description.

The removed bootstrap path required a host session ID and a special
`retrieve` call before any other memory operation. It duplicated protocol
state across an adapter hook, an MCP session object, a retired client event
log, and a special authority resource. The current `memory` tool operations
(`activate`, `load`, and `store`) have no compatibility dispatch for that path.

The removal migration rewrites affected Commit chains with Trees that omit the
obsolete resource, advances every dependent Ref and draft base to the rewritten
Commit, removes related drafts and reviews, and then drops the Metaprompt table.
The daemon schema migration removes local Metaprompt drafts and operations while
preserving Context, Rule, and Workflow drafts. Because Server Commit IDs change,
it also resets rebuildable Commit and search caches, removes old materialized
generations, and replays remote Draft projections so preserved drafts receive
their rewritten base Commit IDs. No compatibility type, endpoint, or local
record remains after migration.

The removed bootstrap content is protocol instruction rather than durable
memory, so it is deleted instead of reclassified. Long-lived behavioral
constraints, reusable procedures, and background material are all Memory
resources in the unified model; nothing is recreated as a separate type.

See [MCP](/mcp) for the current wire contract and [Runtime](/runtime) for the
daemon-owned Effective Memory path.
