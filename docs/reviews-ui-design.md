# Reviews UI Design (macOS App)

Design for the Reviews section of the macOS app, following Apple HIG and
GitHub's page-navigation model. Supersedes the previous master-detail split
and the bundled decision/discussion sections.

## 1. Navigation model

Two pages, push navigation (GitHub issues style). The app sidebar (section
navigation) stays visible on both pages; the review list is replaced by the
detail page on selection.

```
page 1 列表页  (sidebar + review list)
   │  click a row
   ▼
page 2 详情页  (sidebar + full detail, no list)
```

- Back: toolbar Back button, ⌘[, window gestures.
- ⌘↑ / ⌘↓ jump to previous/next review in place (no return to list).
- Mirrors the existing Issues pattern in `WorkspaceView`
  (`issueNavigationPath` + `NavigationStack`).

## 2. Page 1 - Review list

Toolbar: sidebar toggle, window title "Reviews", status filter with counts
(`Open(n) Approved(n) Rejected(n) Merged(n) All(n)`) as a segmented control
that collapses to a menu on narrow windows.

List rows (GitHub issues style, ~64pt, `.inset`):

```
title (1 line)                     [status badge] [freshness ⟳]
description or resource path (1 line, secondary)
author · project · relative time (caption, secondary)
```

- Status badge: shared component, symbol + tint per status:
  open = clock (accent), approved = checkmark.circle (green),
  rejected = xmark.circle (red), merged = arrow.triangle.merge (secondary).
  `.help()` and accessibility labels on all indicators.
- Freshness indicator reuses `DraftBaseBehindIndicator` (behind/conflicts only).
- project name is resolved client-side from the projects list
  (`ReviewRecord` only carries `projectId`).

Empty states: no reviews at all / no results for the current filter
("No Open Reviews") / no selection is no longer possible (push model).

## 3. Page 2 - Review detail

Toolbar: Back button, review title, trailing decision buttons
(`Reject` / `Approve` prominent / `Merge` prominent / `Resubmit` prominent,
one prominent per state) and a More menu. Every toolbar action also exists
in the menu bar with shortcuts (⌘⌥A approve, ⌘⌥R reject, ⌘↩ merge).

Detail body, top to bottom:

```
Header     status badge · version · updated time
Meta line  resource path · author · project   ↻ stale [view changes]   (condition)
Title      review title
Description full text
Changes    General slot [＋ add general comment]
           unified diff (no card, full width)
              hunk headers @@, line numbers, - red / + green
              hover line → [＋] inline comment composer under the line
              anchored comment threads rendered under their line
```

- Stale/conflict state renders as a compact status chip in the meta line
  (`↻ base stale · [view changes]` / `⚠ needs conflict resolution`),
  not a full-width banner and not a context-menu-only entry.
- Decided states render the decision result (decisionBody, result hash,
  decision author/time) inside the header area - controls only, no separate
  Decision section.
- Changes: unified diff rendered directly, no container card. Operation
  summary as a symbol line (`＋ update rules/search.md · 15 lines changed`).
  Delete-only reviews render a deletion note, no empty diff.

## 4. Comments

One comment mechanism only: anchored comments on the diff.

- Anchor targets: a diff line, or the synthetic "General" slot above the
  diff (for whole-review feedback).
- Composer opens inline under the anchor ([＋] on hover / in General slot),
  submit inserts the thread under the anchor; threads support replies.
- No bottom composer, no standalone discussion section, no decision-in-
  comment flow.
- Server: comments gain an optional anchor (`path` + line) - schema change
  in `reviews` comments table, `POST /api/v1/reviews/{id}/comments` accepts
  the anchor, `GET /api/v1/reviews/{id}` returns anchored comments.
  Line numbers refer to the new file side; review version is the expected
  optimistic-concurrency token.

## 5. Decisions

Header buttons are the only decision surface:

- open: Reject / Approve (prominent)
- approved: Merge (prominent) - only for authors with merge capability
- rejected: Resubmit (prominent) - only for the draft author

Decisions carry no note by default; `decisionBody` stays for server
compatibility and may be left empty. Keyboard shortcuts cover the quick path.

## 6. States

| State | Handling |
|-------|----------|
| Loading | detail ProgressView; list keeps cached data, silent refresh on entry |
| No reviews | ContentUnavailableView with explanation |
| Filter empty | per-filter ContentUnavailableView |
| Narrow window | filter collapses to menu; decision buttons stay visible |
| Stale/conflict | meta-line status chip + view changes entry |

## 7. Data gaps

- project name: client-side mapping from projects list (no server change).
- anchored comments: server schema + API change (section 4).
- relative time formatting for createdAt/updatedAt strings.
