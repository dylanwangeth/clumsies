# Metaprompt removal

`META_PROMPT.md` is no longer part of the agent runtime contract or the search
corpus. The MCP server delivers stable protocol guidance through
`InitializeResult.instructions` and each tool description.

The removed bootstrap path required a host session ID and a special
`retrieve` call before any other memory operation. It duplicated protocol
state across an adapter hook, an MCP session object, an attestation log, and a
special authority resource. The current `activate`, `load`, and `store` tools
have no compatibility dispatch for that path.

Existing Server and Desktop Metaprompt domain records remain historical data
until the separately planned domain cleanup classifies and removes them. They
must not enter Effective Memory or a new search index. Long-lived behavioral
constraints belong in Rules, reusable procedures belong in Workflows, and
background material belongs in Context.

See [MCP](/mcp) for the current wire contract and [Runtime](/runtime) for the
daemon-owned Effective Memory path.
