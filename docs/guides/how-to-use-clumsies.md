# Use clumsies

Desktop is the primary human client. The normal workflow does not require a
separate command-line client or manual draft synchronization.

## Sign in

Open the macOS App and enter your organization's Server origin. Remote Servers
must use HTTPS; HTTP is accepted only for loopback development, and the App
rejects addresses containing credentials, a path, query, or fragment. It saves
the normalized origin and checks the Server's installation state before
starting the local daemon.

For an initialized Server, continue with SSO in the system browser. Desktop
owns the ephemeral loopback callback, state, and `S256` PKCE verifier. Your
email must already be admitted by an organization owner or admin.

For a new Server, the same screen expands into native setup. Enter the
deployment Setup Code, organization name, default Project, and optional allowed
email domains, then continue in the browser. The first verified identity
becomes Owner, the installation is locked, and the resulting token pair is
installed in daemon without creating a browser session.

## Browse memory

The unified **Memory** section shows two views of one Organization-authority
model in a single navigator:

- **Org** (organization scope, historically called Hub) contains
  organization-shared Memory.
- **Project** contains that Project's selected Organization resources plus its
  private pre-merge Organization Draft overlays.

There are no closed Context / Rule / Workflow types in the current domain
model — a Memory's role is carried by its content and path. The navigator lists
Memory by path; opening one shows its Markdown body and semantic description in
the workbench. A non-empty description is the intended authoring rule, but the
current write and merge paths do not yet enforce or preserve it consistently.

## Edit and review

Editing creates or reuses a local draft. The daemon persists each operation and
automatically synchronizes it to Server. Saving a draft does not publish it.

The collaboration flow is:

1. create a proposal or edit selected Organization Memory inside a Project
2. keep editing normally while newer shared Commits synchronize
3. review and explicitly merge the latest shared version when prompted
4. submit one or more coordinated Drafts as an ordered Review
5. an Organization owner/admin rejects it or approves and merges the complete Draft set atomically
6. receive the new authority Commit

When the target Ref advances, Desktop continuously shows **A shared update is available**.
Viewing the candidate does not change the Draft. **Merge latest version** shows the
Base/Current/Draft comparison and requires confirmation even when the result is
clean. Conflicts use the same screen for manual resolution. The Draft remains
editable throughout, and its old revision is retained when the result is
applied.

Creating or resubmitting a Review must use the latest Ref. If it moves again
during confirmation, Clumsies recalculates instead of overwriting authority.
An existing Review may remain behind and continue to receive comments, but it
must be coordinated before approval. Approval uses `If-Match` as a final guard;
if the Ref moves, the Review remains Open rather than stopping in a partially
approved state. Historical Approved Reviews can still be merged.

## Agent workflow

The MCP server exposes exactly one tool:

- `memory`, with `activate`, `load`, and `store` operations

Managed host-plugin processes resolve their Project from the current directory
through the always-on daemon and fail closed if that binding is missing or
changes. A manually launched plain `mcp serve` keeps a compatibility fallback
to the Project currently selected in Desktop when no directory binding exists;
the caller still cannot pass an arbitrary Project ID.

MCP `store` and Desktop editing use the same daemon queue, so a change created
by an agent appears in Desktop for review. The Draft changes only the bound
Project's Effective Memory before merge. Its publication target is Organization
authority, but MCP cannot approve, merge, or publish it; an Org administrator
must do that through the Review workflow. Organization is not represented as a
Project.

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

After signing in as an organization owner or administrator, open
**Administration** in the macOS App to manage organization settings, member
admission, Projects, Project membership, tokens, audit events, identity-provider
status, and Server health. It is not a second memory editor. Cached data is
clearly marked, and changes remain disabled until a live Server refresh
succeeds.

If the local daemon cannot start, choose **Administrator Recovery** from the
failure screen. The App signs in directly to the trusted Server and holds the
recovery session only in memory so an administrator can inspect health, repair
member access, or revoke tokens. Retry normal startup after recovery; ordinary
product work still requires daemon.

See [Deployment](/guides/deploy-for-an-org) for Server configuration and
[Architecture](/architecture) for component boundaries.
