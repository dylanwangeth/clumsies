# Native Issue Board Requirements

## 1. Product language

The product term is **Issue**. Chinese UI and documentation may use
**议题（Issue）**. Do not call it a task: a task/turn/run is transient agent
execution, while an Issue is a durable project concern.

## 2. Product principle

The Issue experience follows the same responsibility split as a coding agent:

- The user describes needs and gives feedback in natural language.
- The Agent interprets that language and creates or updates structured Issues
  through the `kanban` MCP tool.
- The board is a read-and-gate surface, not an authoring surface.
- The user only performs small, explicit gate decisions such as approving a
  closure request, requesting more work, releasing an abandoned Issue, or
  reopening a completed Issue.

The macOS app must not expose blank Issue forms, free-form Issue editors,
drag-and-drop status mutation, or a generic status picker.

## 3. Native source of truth

Issue is a native Clumsies domain object stored in the local daemon database.
It is not a Memory object, Draft, file path, or Effective Memory projection.

A native Issue contains at least:

- stable `(project_id, issue_number)` identity and `ISSUE-NNN` key;
- Agent-authored title and Markdown description;
- structured acceptance criteria;
- an optional, typed collection of external Issue and Pull Request links;
- an optional collection of dependency Issue keys and checkable blocking
  predicates (external conditions such as a missing host capability);
- one of five board states (`todo`, `in_progress`, `paused`, `in_review`,
  `done`) and an optimistic-concurrency revision;
- a verification protocol (`verification_level` plus human
  `verification_steps` when needed);
- `changed_by_run_id` (the latest semantic Agent owner/proposer), creation/
  update timestamps, and optional closure proposal summary.

Issue deliberately has no free-form `type`, `priority`, or `components` fields.
Without controlled vocabularies and concrete filtering or retrieval semantics,
they are decorative metadata rather than useful domain concepts. Project scope
plus title, description, state, acceptance criteria, and typed external
references are sufficient for the current Agent and Kanban workflows.

External references are relationships, not a free-form metadata bag. Each item
contains only `kind` (`issue` or `pull_request`) and an absolute HTTP(S) URL.
One native Issue may reference multiple remote objects. The daemon normalizes
and de-duplicates the bounded list; create omission defaults to an empty list,
update omission preserves it, and an explicit empty list clears it. Provider is
derived from the URL host rather than stored independently.

Legacy `issues/open|closed/*.md` Memory resources may be copied once into the
native store during upgrade. After that import they are ordinary Memory
documents and never drive or receive Issue changes.

Exporting a native Issue as Markdown is implemented as the `kanban.export`
operation, which returns a deterministic, portable snapshot.

## 4. Core states and authority

The board shows five visible columns:

| Column | Backing state | Meaning | Authority |
| --- | --- | --- | --- |
| Todo | `todo` | Captured durable work that no Agent is currently pursuing. | Agent `kanban.create`, or user Reopen gate. |
| In Progress | `in_progress` | An Agent explicitly started or resumed the Issue. | Agent `kanban.begin_work` / `kanban.resume_issue`; user Request Changes gate. |
| In Review | `in_review` | The root Agent judged the acceptance criteria satisfied and proposed completion. | Root Agent `kanban.request_closure`. |
| Abandoned | derived | In Progress Issues whose AgentRun claim silently died (no active run, 24h of inactivity). | Derived bucket; the daemon never stores an "abandoned" state. |
| Done | `done` | The user accepted the closure proposal. | User Approve gate only. |

A Paused Issue (`paused`) keeps its place in In Progress with a paused badge:
its handling Agent paused work and may resume it later, or another handler may
take it over with `takeover=true`.

Valid transitions are:

```text
create ------------------------------------------> Todo
Todo ---------------- kanban.begin_work ---------------> In Progress
In Progress --------- kanban.pause_issue --------------> Paused
Paused -------------- kanban.resume_issue -------------> In Progress (owner run, or takeover=true)
Paused -------------- user Release / kanban.unclaim ----> Todo
In Progress --------- kanban.request_closure ----------> In Review
In Review ----------- kanban.begin_work ---------------> In Progress
In Review ----------- user Request Changes ------------> In Progress
In Review ----------- user Approve --------------------> Done
Done ---------------- user Reopen ---------------------> Todo
In Progress --------- user Release / kanban.unclaim ----> Todo (only when no active run holds it)
```

`kanban.begin_work` binds a hook-issued AgentRun and moves any non-Done Issue
to In Progress. One session holds at most one In Progress Issue; starting
another requires pausing or requesting closure of the current one. There is no
generic `set_status` command. A Stop, failure, cancellation, lease expiry,
transcript phrase, or tool result never advances an Issue.

`Stale` is a filter/badge, not a state: it applies to In Progress Issues with
no live unexpired AgentRun and no activity for 24 hours. The Abandoned column
collects those cards so a human can verify what the previous handler left
behind and Release it back to Todo.

## 5. Agent decisions

### Prompt submission

On every supported root prompt event, the hook records/upserts the AgentRun and
injects the exact `run_id` and revision. The Agent decides semantically whether
the request:

1. continues an existing Issue;
2. creates a new durable Issue;
3. is transient work that should not become an Issue.

For (1), call `kanban.begin_work`. For (2), call `kanban.create`, then call
`kanban.begin_work` only when the Issue is the active line of work. If an
unrelated problem is discovered while doing other work, call `kanban.create`
without `begin_work`; this is the primary source of Todo cards.

### Before stopping

The root Agent calls `kanban.request_closure` only after it judges every
acceptance criterion satisfied. When the Issue's `verification_level` requires
human verification (`human_required` or `mixed`), the Agent must first attach
the human `verification_steps` with `kanban.update`; `request_closure` is
rejected while they are missing. Otherwise it makes no lifecycle mutation.
Hooks create this decision point but never make the decision themselves.

Subagents may bind to an existing Issue when explicitly assigned its work, but
cannot request closure.

## 6. MCP requirements

Expose one agent-facing `kanban` tool with tagged operations:

- `list`: inspect native Issues, active runs, and current revisions;
- `get`: load one Issue by its globally unique `issue_id` or Project-local
  `issue_key`, including its owning Project, complete semantic content,
  verification protocol, `changed_by_run_id`, and event timeline;
- `create`: create a structured Issue in Todo;
- `update`: revise semantic content with optimistic concurrency;
- `begin_work`: bind the current AgentRun and enter In Progress;
- `pause_issue`: pause an In Progress Issue held by the current run;
- `resume_issue`: resume a Paused Issue (owner run, or `takeover=true`);
- `unclaim`: release a Paused or abandoned In Progress Issue back to Todo
  without an AgentRun binding (refused while an active run works it);
- `request_closure`: propose closure for the linked Issue, moving it to In
  Review;
- `export`: produce a deterministic, portable Markdown snapshot of an Issue.

User-only gate commands are private daemon operations and are intentionally not
available to Agents:

- `approve_closure` (In Review -> Done);
- `request_changes` (In Review -> In Progress);
- `reopen` (Done -> Todo);
- human Release/Resume of Paused or abandoned Issues without a run.

The desktop also owns two lifecycle cleanup commands:

- `archive`, available only for Done Issues and hiding them from normal lists;
- `delete`, available only for non-Done Issues and retaining AgentRun telemetry
  after removing its Issue link.

`get` resolves a global `issue_id` without requiring a Project hint. List and
all mutations remain scoped to the MCP-bound Project. Create allocates the next
available Issue number atomically. Mutations reject stale revisions. A run can
link to at most one Issue, and retries are idempotent.

`create` and `update` accept optional `external_references`, `dependencies`
(ISSUE-NNN keys that must be Done before this Issue can start),
`blocking_facts` (checkable predicates with a kind, optional value, description
and satisfied flag), `verification_level`, and `verification_steps`. `list` and
`get` return the normalized references, the resolved dependency states, the
blocking facts, and a `blocked` flag with concrete `blocking_reasons` so an
Agent can decide whether a Todo is actionable now without scraping the Issue
description. Dependency cycles, self-references, duplicates, and missing
targets are rejected.

## 7. AgentRun and attention

AgentRun is execution telemetry, not Issue truth. Store bounded identifiers,
labels, summaries, timestamps, parentage, phase, and lease information; never
persist raw prompts, transcripts, tool payloads, or assistant messages. The
daemon reaps stale runs periodically and labels them in the UI; a dead claim
surfaces as Stale/Abandoned rather than keeping the Issue blocked.

## 8. macOS experience

- `Kanban` is the top-level workspace destination, so the product surface is
  distinct from GitHub Issues. `Issue` remains the native domain entity.
- Kanban keeps the existing global sidebar and a single board; Project is a
  toolbar filter.
- The five columns (Todo, In Progress, In Review, Abandoned, Done) use the
  workspace background. Single-click selects a card; double-click opens its
  detail. The card context menu also provides View Details.
- Cards show the title and a description excerpt, a handler status chip for
  the active/pausing AgentRun, `changed_by_run_id` ownership, and compact
  external-reference summaries. A Paused card shows a paused badge.
- The detail is a destination pushed in the board detail column's native
  `NavigationStack`. It replaces the board content while preserving the global
  sidebar, uses the system Back affordance, and remains below the system
  toolbar in both windowed and full-screen modes.
- The detail shows the Issue title, native description, a verification section
  titled by verification level, and an event timeline of board-state
  transitions with their run attribution.
- Todo cards show Created. In Progress, Paused, and In Review show Opened.
  Done shows Opened and Closed. No duration is synthesized.
- Cards with external references show compact typed link summaries that remain
  readable under long URLs and mixed CJK/Latin content. Raw URL authoring does
  not appear in the app.
- The detail contains no text fields and no "Open in Editor" action.
- Right-clicking a card exposes its contextual commands: Copy Issue ID on every
  state; Delete on non-Done states; Pause, Resume/Take Over, Release (unclaim)
  on the relevant active states; Approve Closure and Request Changes on In
  Review; Reopen or Archive on Done; and Open/Copy commands for each external
  reference when present.
- Done icons are green in the board column.
- There is no New Issue button: the user asks an Agent in natural language and
  the Agent calls `kanban.create`.
- Project, Stale, blocked, external-reference filters, unlinked activity, and
  concise workflow guidance may remain toolbar controls. Automatic polling has
  no persistent toolbar indicator; manual retry appears only when a refresh
  actually fails.

## 9. Acceptance criteria

- Native Issues continue to exist and change independently of Memory files.
- An Agent can create/update/list an Issue through MCP without using `store`.
- An Agent can resolve a copied global Issue ID through `kanban.get` and discover
  the owning Project.
- `kanban.begin_work` enters In Progress; Stop has no Issue transition.
- A root Agent can request closure but cannot approve its own request.
- Only the desktop Approve gate moves In Review to Done.
- Request Changes, Reopen, Release, Pause, and Resume are explicit, validated,
  revision-safe operations.
- Cards push the native full-content detail by double-click or View Details;
  Back returns to the existing board state and every visible command works.
- Cards and detail expose native Issue lifecycle timing without substituting
  AgentRun start/stop timestamps.
- The UI offers no direct Issue authoring and shows Done with a green icon.
- Legacy Memory Issues are imported at most once and are not live-linked.
- `kanban.export` produces a deterministic, portable Markdown snapshot.
