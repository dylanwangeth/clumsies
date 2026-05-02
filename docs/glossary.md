# Glossary

## Hub

Hub is the authority layer. It owns the server-side state for Library, Workspace, context collaboration, and aggregated attestation data.

This is the architectural center of gravity for the whole project. If a page explains clumsies as a set of local files plus some helper commands, it is missing the point.

## Rule

A rule is a behavioral instruction for an agent. It answers one question: how should the agent act?

In clumsies, the behavioral layer in Library has two main forms:

| Type | Meaning |
| --- | --- |
| Rule | an individual constraint or policy |
| Workflow | an ordered set of constraints that implies execution flow |

When the docs mean a single behavioral instruction, they should usually say `rule`, not `prompt`.

`Prompt` still exists as an umbrella term in some parts of the system, especially in protocol naming and identity fields such as `prompt_id`. But that broader term should not replace `rule` when the actual meaning is narrower.

Rule is not the same thing as project knowledge. A rule tells the agent what to do. It does not tell the agent what the project is.

## Workflow

A workflow is an ordered behavioral structure rather than a single rule. It groups multiple constraints into an execution path that implies sequence or discipline rather than one isolated instruction.

That is why a workflow belongs in the same behavioral layer as rules, but it should not be collapsed into the same concept.

## Bundle

A bundle is a reusable selection unit inside Library. It packages rule or workflow choices so a workspace can adopt a coherent set rather than hand-picking everything one item at a time.

Bundles matter because they are the bridge between organization-level curation and workspace-level adoption.

## Context

Context is project knowledge owned by a workspace. It answers a different question: what is this project, why is it shaped this way, and what do we currently know?

Specs, ADRs, research notes, and design material are all context. They give the agent evidence and background. They do not directly impose behavior.

Context is not managed by Library. That boundary matters. If project knowledge were flattened into the shared behavioral layer, workspace ownership and collaboration would become much harder to reason about.

## Library

Library is the organization-level source of rules, workflows, and bundles. It is not a cache and not a loose pile of copies. It owns rule identity, current path, content hash, and review history.

Once Library stops being authoritative, cross-workspace convergence becomes fragile. Rule history, rule review, and attestation aggregation all become harder to trust.

## Workspace

Workspace is the project boundary where rules, workflows, bundles, and context are combined for real work. A workspace does not own Library behavior content. It selects a subset from Library and combines it with workspace-owned context.

| Part of a workspace | Ownership |
| --- | --- |
| selected rules, workflows, and bundles | references to Library |
| context files | workspace-owned |
| local drafts | local working state |
| manifest | Hub-maintained index of current state |

That is why a workspace is not just a folder and not simply a git repository. It is the collaboration boundary around a project.

Workspace also has its own membership model. Org-level maintainers exist above it, while workspace admins and members control project-level collaboration inside it.

## Manifest

Manifest is the current indexed snapshot of workspace state. It bridges Hub and local runtime by recording which rules, workflows, bundles, and context files belong to the workspace and which content hashes are current.

That matters because sync, cache refresh, rename handling, and non-blocking local reads all depend on it.

## Attestation

Attestation is the event stream produced when agents discover and load
Library behavior, then refer to it during real work.

Attestation is not decorative analytics. It is the feedback signal for the rule lifecycle and the broader improvement loop around Library content. Without it, teams are left guessing which constraints actually mattered and which ones were only present in theory.

Older specs and pages may still call this layer `Trace`. The current codebase and newer docs are moving toward `Attestation`.

## Adapter

Adapter is the host integration layer. It connects clumsies to coding agents such as Codex or Claude Code by installing the hooks, config, skills, and runtime glue needed for the protocol to actually run.

Adapter is not the Hub and not the MCP protocol itself. It is the layer that makes the runtime usable inside a specific host.

## MCP

MCP is the agent-facing protocol surface. It is the runtime path through which an agent discovers Library content and context, loads content, and declares the constraints it actually applied.

MCP is not just a transport detail. It is the mechanism that turns rule and context management into a live runtime system with traceable usage.

The current implementation exposes a `memory.*` tool surface. That is the runtime contract the docs should describe.

## Draft and PR

A draft is local in-progress work. It can target either a Library rule or workflow, or a workspace context file. A pull request is the collaboration object that moves those changes back to the authority layer.

Draft is local state. PR is shared workflow.

For Library content, PR is the path back into org-level shared truth. For workspace context, PR is the path back into workspace mainline knowledge. Those are related patterns, but not the same authority boundary.
