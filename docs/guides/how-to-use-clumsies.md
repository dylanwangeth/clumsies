# Use clumsies

Desktop is the primary human client. The normal workflow does not require a
separate command-line client or manual draft synchronization.

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
2. keep editing normally while newer shared Commits synchronize
3. review and explicitly merge the latest shared version when prompted
4. submit the coordinated draft for review
5. review comments and a decision
6. merge an approved current review
7. receive the new authority Commit

When the target Ref advances, Desktop continuously shows **共享版本已有更新**.
Viewing the candidate does not change the Draft. **合并最新版本** shows the
Base/Current/Draft comparison and requires confirmation even when the result is
clean. Conflicts use the same screen for manual resolution. The Draft remains
editable throughout, and its old revision is retained when the result is
applied.

Creating or resubmitting a Review must use the latest Ref. If it moves again
during confirmation, Clumsies recalculates instead of overwriting authority.
An existing Review may remain behind and continue to receive comments, but it
must be coordinated before merge. An update that changes the final resource
result invalidates prior approval; a Base-only change with byte-identical final
result preserves it.

## Agent workflow

The MCP server exposes:

- `activate` to return task-relevant, directly usable memory fragments
- `load` to read a known complete resource by stable ID or exact path
- `store` to create or update a local project draft

Each MCP process resolves its Project from the current directory through the
always-on daemon. This binding is durable and does not follow the Project shown
in Desktop, so Desktop may be closed or displaying another Project. An unbound
directory fails with `project_binding_not_found`; it is never silently attached
to a default Project.

MCP `store` and Desktop editing use the same daemon queue, so a change created
by an agent appears in Desktop for review. Organization-scoped MCP writes are
not exposed yet; Hub edits remain explicit Desktop operations.

## Bundles

Bundles are personal, Server-stored selections of shared memory. They help one
user reuse a curated set without making that selection an organization-wide
authority object.

## Manage Project local storage

Open Settings and use **Project Local Storage** to inspect the selected Project's
cache location, availability, and size. **Choose...** opens the native macOS
directory picker. Clumsies creates its own hidden managed subtree below that
directory; the directory itself remains yours and is never treated as a memory
editing folder.

Moving storage continues in the background daemon if Desktop closes. Do not edit
files inside the managed subtree. **Reset** moves the cache back to the standard
macOS location through the same verified migration. **Clear Cache...** removes
only rebuildable Commit generations and the Project search index; Drafts,
pending operations, settings, and unrelated files in the selected directory are
preserved.

If an external volume is disconnected or permission is revoked, the Project
location shows **Unavailable**. Clumsies does not create a replacement cache in
the default location. Draft editing and synchronization continue, while checkout
and MCP retrieval resume after the configured location is accessible again.

## Administration

Web Admin is reserved for organization settings, member admission, projects,
tokens, audit events, and health. It is not a second memory editor.

See [Deployment](/guides/deploy-for-an-org) for Server configuration and
[Architecture](/architecture) for component boundaries.
