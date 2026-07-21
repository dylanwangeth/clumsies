# Glossary

## Server

Server is the authority layer. It owns organization and project resources,
personal Bundles, Draft and Review lifecycles, identity and authorization, and
the Blob / Tree / Commit / Ref version graph.

This is the architectural center of gravity for the whole project. If a page explains clumsies as a set of local files plus some helper commands, it is missing the point.

## Rule

A rule is a behavioral instruction for an agent. It answers one question: how should the agent act?

In clumsies, behavioral memory has two domain forms:

| Type | Meaning |
| --- | --- |
| Rule | an individual constraint or policy |
| Workflow | an ordered set of constraints that implies execution flow |

When the docs mean a single behavioral instruction, they should usually say `rule`, not `prompt`.

Rule is not the same thing as project knowledge. A rule tells the agent what to do. It does not tell the agent what the project is.

## Workflow

A workflow is an ordered behavioral structure rather than a single rule. It groups multiple constraints into an execution path that implies sequence or discipline rather than one isolated instruction.

That is why a workflow belongs in the same behavioral layer as rules, but it should not be collapsed into the same concept.

## Bundle

A Bundle is a personal, Server-stored selection of memory resources. It helps
one user reuse a curated set without turning that selection into organization
authority.

## Context

Context is file-oriented knowledge. Project Context answers what a project is,
why it is shaped this way, and what is currently known. Organization Context
holds knowledge that is intentionally reusable across projects.

Specs, ADRs, research notes, and design material are all context. They give the agent evidence and background. They do not directly impose behavior.

Context does not impose behavior. Scope and resource identity determine its
authority; its file-tree presentation is not its storage identity.

## Artifact

Artifact is a retired name for the former organization-level memory manager.
The current user-facing term is **Hub**, which exposes organization-scoped
Context, Rules, and Workflows. Server, not Hub, is the authority process.

## Project

Project is the collaboration and authority boundary for project-specific
Context, Rules, and Workflows. It may also consume selected Hub resources. A
Project is not a local folder or Git repository; local paths resolve to a
stable Server-issued project ID.

`Workspace` is a retired name that may still appear in old code and legacy
documents.

## Manifest

Manifest is a retired runtime term. Authority versions use Blob, Tree, Commit,
and Ref. The daemon materializes a validated Commit generation, overlays local
Draft operations into Effective Memory, and builds a separate derived Index
Revision for retrieval.

## Attestation

Attestation is a legacy event-stream capability. Agent observability is not part
of the current product direction or MCP memory contract.

## Adapter

Adapter is the host integration layer. It connects clumsies to coding agents such as Codex or Claude Code by installing the hooks, config, skills, and runtime glue needed for the protocol to actually run.

Adapter is not the Server and not the MCP protocol itself. It is the layer that makes the runtime usable inside a specific host.

## MCP

MCP is the agent-facing protocol surface. It is the runtime path through which an agent activates task-relevant fragments, loads known complete resources, and stores explicit Draft refinements.

MCP is not an authority or storage layer. The Zig MCP server validates the
agent-facing contract and delegates Effective Memory, retrieval, loading, and
Draft persistence to the Rust daemon over XPC.

The current implementation exposes concise tools: `activate`, `load`, and
`store`. That is the runtime contract the docs should describe.

## Draft and Review

A Draft is local in-progress work over a Context, Rule, or Workflow. A Review
is the Server collaboration object that decides whether those operations may
move an organization or project Ref.

Draft is local-first state. Review is shared workflow.

For Hub content, Review targets organization authority. For Local content,
Review targets project authority. Those are related lifecycles, but they move
different Refs.
