# Guides

Guides are organized by operating role rather than by subsystem.

The point of this section is not to restate the architecture. It is to tell a reader which path matches the work they are actually doing.

## Choose the guide that matches the job

| If you are trying to do | Start here | Why |
| --- | --- | --- |
| bring up Hub and the database for a team | [Deployment](/guides/deploy-for-an-org) | covers local self-hosted bring-up, bootstrap identity, and what still remains manual |
| use clumsies inside a repo as a normal member | [Member workflow](/guides/how-to-use-clumsies) | covers login, workspace binding, sync, TUI, and adapter installation from the human side |
| wire an agent host into the local runtime | [Agent runtime](/guides/agent-runtime) | covers `clumsies mcp serve`, `memory.*`, attestation, and adapter/runtime boundaries |
| look up exact command and flag behavior | [CLI reference](/guides/cli-commands) | covers the current command surface without forcing you through a walkthrough |

## What guides should and should not do

Guides should explain a real operating path from start to finish. They should answer what the actor is trying to accomplish, what state changes on disk or in Hub, and where to look when something breaks.

Guides should not duplicate the architecture pages. If a section only restates that Hub is authoritative or that MCP is agent-facing, it belongs in [Architecture](/architecture) or [MCP](/mcp), not in a guide.
