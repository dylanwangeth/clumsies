# Use clumsies

Desktop is the primary human client. The normal workflow does not start in the
TUI and does not require manual draft synchronization.

## Sign in

Open Desktop and continue with SSO. The current development distribution
connects to `https://app.clumsies.ai`; it does not expose a local/production
profile selector. The system browser handles authentication, and your email
must already be admitted by an organization owner or admin.

Local Server and OIDC environments are test infrastructure for backend and E2E
development. They are not a second interactive Desktop mode. A future
self-hosted distribution will receive its organization Server authority from
the installation or deployment channel instead of asking users to switch
profiles in the app.

## Browse memory

Desktop has two memory scopes:

- **Hub** contains organization-shared Context, Rules, and Workflows.
- **Local** contains the selected project's resources and local drafts.

Choose a resource kind in the Content Region navigator, then open its Markdown
file in the workbench. Rules and Workflows retain their domain identity through
resource metadata while using the same document editing model as Context.

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

- `activate` to return task-relevant, directly usable memory fragments
- `load` to read a known complete resource by stable ID or exact path
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
