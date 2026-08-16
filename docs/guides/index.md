# Guides

Guides are organized by operating role rather than by subsystem.

The point of this section is not to restate the architecture. It is to tell a reader which path matches the work they are actually doing.

## Choose the guide that matches the job

| If you are trying to do | Start here | Why |
| --- | --- | --- |
| bring up Server and the database for a team | [Deployment](/guides/deploy-for-an-org) | covers local self-hosted bring-up, bootstrap identity, and what still remains manual |
| use clumsies inside a repo as a normal member | [Member workflow](/guides/how-to-use-clumsies) | starts from Desktop, then follows the Draft, Review, and Commit workflow |
| wire an agent host into the local runtime | [Agent runtime](/guides/agent-runtime) | covers `clumsiesd mcp serve`, the private Hook proxy, daemon XPC, and release identity |
| understand run injection and Stop behavior | [AgentRun lifecycle](/guides/agent-run-injection) | separates lifecycle observation from explicit `kanban` decisions |
| connect the DeepSeek Harness web app | [DSH integration](/guides/dsh-integration) | registers the MCP server and forwards session/turn events as `dsh` AgentRuns |
| work on the clumsies repository itself | [Development workflow](/guides/development-workflow) | worktree + kanban loop used by the project's own agents |
| learn where effective Memory comes from | [Memory storage boundary](/guides/rule-store-unification) | Server Commit generations, Draft overlays, and the MCP proxy read path |
| understand the retired standalone CLI | [Archived Zig CLI](/guides/cli-commands) | why `clumsies` the binary is not an active surface |

## What guides should and should not do

Guides should explain a real operating path from start to finish. They should answer what the actor is trying to accomplish, what state changes on disk or in Server, and where to look when something breaks.

Guides should not duplicate the architecture pages. If a section only restates that Server is authoritative or that MCP is agent-facing, it belongs in [Architecture](/architecture) or [MCP](/mcp), not in a guide.
