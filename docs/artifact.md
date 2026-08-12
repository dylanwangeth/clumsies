# Hub

Hub is the Desktop view of organization-scoped Context, Rules, and Workflows.
It is not a separate service: Server remains the authority process. This page
keeps the former `/artifact` URL because `Artifact` was the retired name for
this product surface.

## Scope and authority

Hub resources are shared across the organization and have an independent Ref
and immutable Commit history. Projects may consume selected Hub resources, but
they do not create unrelated copies or turn local paths into identity.

Resource identity is stable while the display path may change. Blob, Tree,
Commit, and Ref provide version history; Draft, Review, and merge provide the
human coordination boundary.

## Rules, Workflows, and Context

| Kind | Role |
| --- | --- |
| Context | reusable organization knowledge and evidence |
| Rule | a strong behavioral constraint |
| Workflow | an ordered reusable procedure |

All three use Markdown bodies and stable resource metadata. Editing in Desktop
creates a Draft; it never mutates the authority Ref directly.

## Bundles

A Bundle is one member's Server-stored selection of Hub resources. It supports
reuse and discovery without becoming a new authority source:

- a resource may exist outside every Bundle;
- the same resource may appear in multiple Bundles;
- Bundle membership does not change resource identity;
- a Project's memory history remains independent from the member's Bundle
  selection.

See [Project](/workspace) for repository-scoped memory and [Architecture](/architecture)
for the independent organization and Project Ref model.
