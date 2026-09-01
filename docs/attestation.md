# Archived attestation client

The former Zig client attestation pipeline is not part of the current Agent
runtime or MCP contract. Its last active implementation remains recoverable
from Git commit `4b18f7947a977dbc6b62f560b698dc992597f19d`; no copy is built,
installed, uploaded, or exposed as an active product surface.

Current lifecycle observation is the privacy-bounded daemon `AgentRun` bridge.
It records host lifecycle identifiers for Kanban coordination and never uploads
prompts or transcripts. See [AgentRun lifecycle](/guides/agent-run-injection).
