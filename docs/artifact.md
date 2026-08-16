# Organization memory

Organization memory is the organization-scoped half of the unified Memory
model. This page keeps the former `/artifact` URL because `Artifact` was the
retired name for this product surface, and the historical UI called the view
**Hub**.

## Scope and authority

Organization memory is shared across the organization and has an independent
Ref and immutable Commit history. Projects may consume selected organization
Memory resources, but they do not create unrelated copies or turn local paths
into identity.

Resource identity is stable while the display path may change. Blob, Tree,
Commit, and Ref provide version history; Draft, Review, and merge provide the
human coordination boundary.

## Memory in organization scope

Every Memory object — whether it reads as a rule, a workflow, or reusable
project context — uses a Markdown body, a required semantic `description`, and
stable resource metadata. There are no closed Context / Rule / Workflow types;
the unified model stores one object in organization or project scope. Editing
in Desktop creates a Draft; it never mutates the authority Ref directly.

## Bundles

A Bundle is one member's Server-stored selection of shared memory resources
(`resource_ids`). It supports reuse and discovery without becoming a new
authority source:

- a resource may exist outside every Bundle;
- the same resource may appear in multiple Bundles;
- Bundle membership does not change resource identity;
- a Project's memory history remains independent from the member's Bundle
  selection.

See [Project](/workspace) for project-scoped memory and [Architecture](/architecture)
for the independent organization and Project Ref model.
