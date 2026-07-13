# Use clumsies

Desktop is the primary human client. The normal workflow does not start in the
TUI and does not require manual draft synchronization.

## Sign in

Open Desktop, enter your organization's Server URL, and continue with SSO.
The system browser handles authentication. Your email must already be admitted
by an organization owner or admin.

For local development, the Server URL is usually:

```text
http://127.0.0.1:8080
```

Remote URLs must use HTTPS.

## Browse memory

Desktop has two memory scopes:

- **Hub** contains organization-shared Context, Rules, Workflows, and
  Metaprompt.
- **Local** contains the selected project's resources and local drafts.

Choose a resource kind in the Content Region navigator, then open a file or
structured resource in the workbench. Context behaves as a file tree; Rules
and Workflows retain their domain identity even when their bodies are textual.

## Edit and review

Editing creates or reuses a local draft. The daemon persists each operation and
automatically synchronizes it to Server. Saving a draft does not publish it.

The collaboration flow is:

1. edit a Hub or Local resource
2. submit the draft for review
3. review comments and a decision
4. merge an approved review
5. receive the new authority Commit

If the target Ref changed after the draft's base Commit, merge stops with a
conflict. Clumsies does not silently overwrite the newer authority state.

## Agent workflow

The MCP server exposes:

- `activate` to list task-relevant candidates
- `retrieve` to load selected content
- `store` to create or update a local project draft

MCP `store` and Desktop editing use the same daemon queue, so a change created
by an agent appears in Desktop for review. Organization-scoped MCP writes are
not exposed yet; Hub edits remain explicit Desktop operations.

## Bundles

Bundles are personal, Server-stored selections of shared memory. They help one
user reuse a curated set without making that selection an organization-wide
authority object.

## Administration

Web Admin is reserved for organization settings, member admission, projects,
tokens, audit events, and health. It is not a second memory editor.

See [Deployment](/guides/deploy-for-an-org) for Server configuration and
[Architecture](/architecture) for component boundaries.
