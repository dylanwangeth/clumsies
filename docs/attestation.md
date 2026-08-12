# Archived attestation client

The former Zig client attestation pipeline is not part of the current Agent
runtime or MCP contract. Its historical implementation is preserved only under
`archive/zig-cli/`; it is not built, installed, uploaded, or exposed as an
active product surface.

Current lifecycle observation is the privacy-bounded daemon `AgentRun` bridge.
It records host lifecycle identifiers for Kanban coordination and never uploads
prompts or transcripts. See [AgentRun lifecycle](/guides/agent-run-injection).
