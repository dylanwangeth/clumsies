# Overview

## What clumsies is

clumsies is building the persistent, observable, and collaborative context infrastructure that coexists with agents' self-managed memory.

In practical terms, that means shared rules stop living as scattered local copies, project context stops being glued onto one agent runtime at a time, and real usage produces attestation data that a team can inspect later.

The point is not just to store rule text. The system is trying to solve three problems at the same time:

- rule lifecycle management across many workspaces
- project context management at workspace scope
- attestation-backed observability for how agents actually used those materials

## Why the project exists

The architecture documents describe a specific failure mode in agent-heavy teams: rules get copied into local repos, drift independently, and become impossible to review, measure, or refine across projects.

That produces four structural problems:

1. rule reuse is manual and fragile
2. rule identity gets tied to local file paths
3. local improvements have no clean path back to shared infrastructure
4. attestation data stays trapped inside per-project islands

clumsies exists to turn that into a managed system. Artifact owns shared rule truth. Workspace binds that truth to a project. Context carries project knowledge. Attestation makes the runtime legible enough to support review and refinement.

## The stable object model

The clearest way to understand clumsies is through eight core objects:

| Object | Role |
| --- | --- |
| Hub | the authority layer that owns server-side state and coordination |
| Artifact | the organization-level source of rules, workflows, and bundles |
| Rule | the basic behavioral asset that the rest of the lifecycle is built around |
| Workspace | the project boundary that selects Artifact content and owns context |
| Context | project facts such as specs, ADRs, and research |
| Attestation | usage signals from activate, retrieve, and draft operations |
| Draft | local in-progress work before review or merge |
| PR | the review path that moves changes back into shared authority |

Everything else in the system exists to serve those objects. CLI, MCP, TUI, adapters, manifests, and local cache all sit around this model rather than replacing it.

## The authority model

Hub is the authority layer. It owns artifact state, workspace manifests, collaboration flow, and aggregated attestation data. CLI, MCP, TUI, and adapters are client or integration surfaces around that authority.

That distinction matters because the repository already contains a lot of local runtime code. Public docs should not describe those surfaces as separate truth sources. They are execution layers built around the Hub-centered model.

This also implies a hard design rule: business logic belongs in Hub. Clients execute against it. Adapters bridge host runtimes into it. They do not become parallel authority layers.

## What a workspace actually contains

The specs make one boundary explicit: a workspace is not "a repo with rules in it."

It contains:

- rule, workflow, and bundle selections from Artifact
- workspace-owned context files
- a Hub-maintained manifest that indexes current rule, workflow, and context hashes
- local drafts used for in-progress editing before review or merge

That model is what keeps shared policy and project-specific knowledge from collapsing into one bucket. Artifact content stays organization-owned. Context stays workspace-owned. The workspace binds them together for actual work.

## The collaboration split

clumsies has two different collaboration models, and the docs need to preserve that distinction.

Artifact content moves through proposal and review flow before it becomes shared truth again. Workspace context uses workspace-scoped collaboration and PR flow because it is project knowledge rather than cross-org policy.

If docs flatten those two workflows into one vague "edit and sync" story, the system becomes much harder to reason about than it actually is.

## Current implementation and stable system shape

This repository already has a working Hub-centered runtime. The docs should not undersell that by talking as if the real architecture only exists in the future.

At the same time, some details are still evolving. The useful documentation move is not to blur those together. It is to separate:

- what is already implemented and user-visible now
- what is clearly part of the stable product boundary
- what is still being refined inside that boundary

## The naming transition is real

The project also still carries some older naming. The design intent has moved from prompt-heavy wording toward rule-oriented wording, and from Trace toward Attestation, but older terms still appear in parts of the implementation and historical documents.

Good docs for this project need to do two things at once:

1. explain what exists now
2. show what the system is clearly moving toward

## Recommended reading order

1. Start with [Architecture](/architecture).
2. Use [Glossary](/glossary) when you need the stable meaning of project terms.
3. Read [Hub](/hub) if you want the server-side model directly.
4. Read [Runtime surfaces](/runtime) to understand CLI, MCP, TUI, cache, and adapters.
5. Read [MCP](/mcp) and [Adapter](/adapter) when you care about agent execution paths.
6. Use [Codebase map](/repos) when you want to connect the model back to the repository.
