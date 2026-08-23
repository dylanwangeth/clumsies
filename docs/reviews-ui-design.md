# Reviews UI Design (macOS App)

The Reviews section follows the same native navigation hierarchy as Kanban:
the global app sidebar stays in place, the Review list is the root page, and a
selected Review is pushed onto a `NavigationStack`. The detail is a file-review
workspace rather than a permanently visible third app column.

This document replaces both the earlier web-style Review page and the temporary
three-column master-detail variant.

## 1. Navigation model

The outer shell has two stable roles:

```
global sidebar | NavigationStack (Review list -> Review detail)
```

- Entering Reviews opens the list, not an automatically selected Review.
- A native `NavigationLink` opens a Review. The system owns pointer, keyboard,
  VoiceOver activation, Back, and navigation transition behavior.
- Returning from a detail restores the list and its filter context.
- Search and newly created Reviews may deep-link to a stable `reviewId`.
- The global sidebar remains visible according to the user's existing sidebar
  preference and is not replaced by Review navigation.

## 2. Review list

Use a native inset `List` with information-rich rows and visible row separators.
A single click pushes the Review detail. The scroll area fills its content
region without drawing an outer border; record boundaries come from system
separators, focus, selection, hover, and inactive-window behavior. Do not enable
alternating row backgrounds: AppKit continues their stripes through empty table
space, making nonexistent Reviews look like blank rows. Pin the separator's
leading alignment to the row rather than allowing trailing metadata such as the
relative update time to shorten it.

The list is a review queue. Each row answers five scan questions: what changed,
where it belongs, who submitted it, when its Review record last changed, and
what the current viewer can do next:

```
review title                     symbol + one semantic workflow state
description excerpt
Submitted by author for project · updated relative time
```

- Keep descriptions to a one-line excerpt; the complete description stays in
  the detail page.
- Express Project, author, and relative update time as one muted sentence in the
  GitHub Issue metadata style. The author is the submitter, not necessarily the
  person who last updated the Review record, so never label the update as theirs.
  If a Project name or timestamp cannot be resolved, omit the value; never expose
  an opaque Project ID or raw protocol timestamp.
- Resolve one workflow state for the row. Precedence is `Merged`, `Conflicts`,
  `Update Required`/`Out of Date`, then the viewer-aware lifecycle state:
  `Needs Review`, `Ready to Merge`/`Approved`, or `Resubmit`/`Awaiting Author`.
  A merged Review never displays stale merely because the merge advanced the
  current Project ref. `Ready to Merge` also requires a nonempty approved result
  hash; capability alone does not make a legacy approval mergeable.
- The workflow state is a plain system `Label` with an SF Symbol and semantic
  foreground color. It is neither a button nor a capsule. Never stack a status
  icon and freshness icon that require hover to distinguish. Always show the
  resolved state because it anchors the row's workflow meaning even inside a
  filtered scope. At narrow widths, the label may reduce to its symbol so the
  primary Review title retains priority.
- Let macOS draw separators, focus, hover/press feedback, and inactive-window
  state. Do not draw an outer list border, per-row cards, or empty-space zebra
  stripes. `NavigationLink` and the stack path are the only navigation state;
  do not add a parallel `List(selection:)` binding that can push the same route
  twice during a programmatic deep-link.
- The status Filter menu belongs to the list page's leading/navigation toolbar
  area. Its collapsed label communicates the selected scope; counts remain in
  the menu, help, and accessibility value. The menu contains Open, Approved,
  Rejected, Merged, and All with counts.
- Search is an independent window-level action and remains the trailing-most
  Review tool. Sync and decision actions are not grouped with Filter.
- Loading without cached Reviews uses a labeled `ProgressView`. Existing cached
  rows remain visible during refresh. Empty and filtered-empty states use
  `ContentUnavailableView`; filtered-empty includes `Show All Reviews`.

The GitHub pull-request list informs the information order — title first,
scope/author/time second, and a small number of workflow signals — but not its
Web chrome. Do not copy blue links, colored pills, PR numbers, avatar stacks,
comment counters, or pagination. The
Server does not currently provide unread counts, unresolved-thread counts, or a
true last-activity timestamp, and the macOS client must not invent them from
`updatedAt`.

## 3. Review detail

The pushed detail contains an independent split:

```
changed-file navigator | review metadata + unified diff
```

The file navigator reuses the path hierarchy, folder expansion, file symbols,
and native row styling extracted from the Memory file tree. It owns only Review
file selection; it must not inherit Memory rename, delete, or open side effects.

The current Server contract models one Draft resource per Review, so the tree
currently contains one real terminal file path. Do not turn operation history
into fake files. The tree accepts stable file IDs and paths so a future
materialized multi-file API can extend it without changing the interaction.

The main pane contains only information needed to make the decision:

1. title and plain status;
2. author, project, and update time;
3. description when present;
4. actionable stale/conflict state when present;
5. decision result and audit metadata after a decision;
6. unified diff.

Do not show a `Changes` heading or summaries such as `Create path · 20 changed
lines`. The file navigator already communicates the path and the diff directly
communicates insertions/removals. Delete-only and metadata-only Reviews retain a
short explicit empty state because the diff cannot communicate those outcomes.

## 4. Diff and comments

- Replacement rows render both the removal and insertion.
- Long lines scroll horizontally. Unchanged regions remain collapsed unless
  expanded or required to reveal an anchored comment.
- A line anchor is the final/new-side `(path, line)` pair. Removal rows are not
  comment targets until the API gains an explicit side field.
- A line thread renders immediately after its exact diff row. It is never moved
  to the top of the diff.
- Review-wide comments have no path or line. They live in an explicitly labeled,
  user-opened `Review comments` area and must never look like line feedback.
- Anchored comments for an earlier path remain discoverable in that area with
  their original `path:line` label instead of silently disappearing.
- Comment creation uses the version of the Review detail that produced the
  visible diff. If that version is stale, the strict Server contract rejects it
  and the detail reloads rather than anchoring a comment to unrelated content.

Historical comments created before the strict Server anchor deployment may be
General because the old Server discarded unknown path/line fields before the
client failed to decode its response. The client cannot infer the lost line;
the UI labels these honestly rather than pretending they are inline comments.

## 5. Toolbar decisions

Decision actions remain native symbol toolbar items with menu-command parity:

- Open: Org owners/admins with `review:decide` see Reject (`xmark`) and the
  single prominent Approve (`checkmark`); ordinary members remain read/comment
  participants and see neither authority action.
- Approved: Merge (`arrow.triangle.merge`) when permitted and the Server
  supplied a nonempty approved result hash. Legacy approvals without that
  immutable result identity remain visible but cannot be merged.
- Rejected: Resubmit (`arrow.clockwise`) for the Draft author.

Filter belongs only to the list page. Decision tools belong only to an active
detail. Sync remains its own utility slot. Search remains independent and
trailing-most. Cross-section toolbar grouping and macOS 14-26 placement are
tracked as a separate workspace-wide design issue; Reviews must not reintroduce
one catch-all action group while that work is pending.

## 6. State and accessibility

| State | Native handling |
| --- | --- |
| Loading | `ProgressView` |
| No Reviews/filter matches | Contextual `ContentUnavailableView` |
| Detail load failure | Explicit error and Retry; decisions stay unavailable |
| Stale/conflict | Concise semantic label and nearby action |
| Delete/metadata-only | Explicit main-pane result instead of an empty diff |
| Narrow window | Native outer sidebar behavior and toolbar overflow |

- Preserve system focus and link activation feedback; do not encode state by
  color alone.
- Every symbol-only control has `.help()` and an accessibility label.
- Verify list -> detail -> Back with mouse, keyboard, and Full Keyboard Access.
- Verify nested paths, long paths, CJK text, long diff lines, comments inside
  omissions, rename-only comments, stale details, and loading/error states.

## 7. Data boundary

The current domain is intentionally honest: one Review is one Draft resource
with operation history. A true multi-file Review requires a Server-provided
materialized list of file changes with stable change IDs, per-file source
states, reconciliation, and comment anchors. That contract expansion must be a
separate backend change; the macOS client must not infer it from operations.
