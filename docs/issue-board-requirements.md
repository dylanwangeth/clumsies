# Native Issue Board Requirements

## 1. Product language

The product term is **Issue**. Chinese UI and documentation may use
**议题（Issue）**. Do not call it a task: a task/turn/run is transient agent
execution, while an Issue is a durable project concern.

## 2. Product principle

The Issue experience follows the same responsibility split as a coding agent:

- The user describes needs and gives feedback in natural language.
- The Agent interprets that language and creates or updates structured Issues
  through the `issue` MCP tool.
- The board is a read-and-gate surface, not an authoring surface.
- The user only performs small, explicit gate decisions such as approving a
  closure request, requesting more work, or reopening a completed Issue.

The macOS app must not expose blank Issue forms, free-form Issue editors,
drag-and-drop status mutation, or a generic status picker.

## 3. Native source of truth

Issue is a native Clumsies domain object stored in the local daemon database.
It is not a Context, Rule, Workflow, Draft, file path, or Effective Memory
projection.

A native Issue contains at least:

- stable `(project_id, issue_number)` identity and `ISSUE-NNN` key;
- Agent-authored title and Markdown description;
- structured acceptance criteria;
- an optional, typed collection of external Issue and Pull Request links;
- one of four board states and an optimistic-concurrency revision;
- creation/update timestamps and optional closure proposal summary.

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

Legacy `issues/open|closed/*.md` Context resources may be copied once into the
native store during upgrade. After that import they are ordinary Context
documents and never drive or receive Issue changes.

Exporting native Issues as Markdown is a future explicit operation, not a live
mapping. Track that capability as its own Todo Issue.

## 4. Core states and authority

The board has exactly four columns:

| State | Meaning | Authority |
|---|---|---|
| Todo | Captured durable work that no Agent is currently pursuing. | Agent `issue.create`, or user Reopen gate. |
| In Progress | An Agent explicitly started or resumed the Issue. | Agent `issue.start`; user Request Changes gate. |
| Closure Requested | The root Agent judged the acceptance criteria satisfied and proposed completion. | Root Agent `issue.request_closure`. |
| Done | The user accepted the closure proposal. | User Approve gate only. |

Valid transitions are:

```text
create ------------------------------------------> Todo
Todo ---------------- issue.start --------------> In Progress
In Progress ---------- issue.start -------------> In Progress
Closure Requested ---- issue.start -------------> In Progress
In Progress ---------- issue.request_closure ---> Closure Requested
Closure Requested ---- user Request Changes ----> In Progress
Closure Requested ---- user Approve ------------> Done
Done ----------------- user Reopen -------------> Todo
```

There is no generic `set_status` command. A Stop, failure, cancellation, lease
expiry, transcript phrase, or tool result never advances an Issue.

## 5. Agent decisions

### Prompt submission

On every supported root prompt event, the hook records/upserts the AgentRun and
injects the exact `run_id` and revision. The Agent decides semantically whether
the request:

1. continues an existing Issue;
2. creates a new durable Issue;
3. is transient work that should not become an Issue.

For (1), call `issue.start`. For (2), call `issue.create`, then call
`issue.start` only when the Issue is the active line of work. If an unrelated
problem is discovered while doing other work, call `issue.create` without
`start`; this is the primary source of Todo cards.

### Before stopping

The root Agent calls `issue.request_closure` only after it judges every
acceptance criterion satisfied. Otherwise it makes no lifecycle mutation.
Hooks create this decision point but never make the decision themselves.

Subagents may bind to an existing Issue when explicitly assigned its work, but
cannot request closure.

## 6. MCP requirements

Expose one agent-facing `issue` tool with tagged operations:

- `list`: inspect native Issues and current revisions;
- `get`: load one Issue by its globally unique `issue_id`, including its owning
  Project and complete semantic content;
- `create`: create a structured Issue in Todo;
- `update`: revise semantic content with optimistic concurrency;
- `start`: bind the current AgentRun and enter In Progress;
- `request_closure`: propose closure for the linked Issue.

User-only gate commands are private daemon operations and are intentionally not
available to Agents:

- `approve_closure`;
- `request_changes`;
- `reopen`.

The desktop also owns two lifecycle cleanup commands:

- `archive`, available only for Done Issues and hiding them from normal lists;
- `delete`, available only for non-Done Issues and retaining AgentRun telemetry
  after removing its Issue link.

`get` resolves a global `issue_id` without requiring a Project hint. List and
all mutations remain scoped to the MCP-bound Project. Create allocates the next
available Issue number atomically. Mutations reject stale revisions. A run can
link to at most one Issue, and retries are idempotent.

`create` and `update` accept optional `external_references`. `list` and `get`
return the normalized references so an Agent can understand linked remote work
without scraping the Issue description.

## 7. AgentRun and attention

AgentRun is execution telemetry, not Issue truth. Store bounded identifiers,
labels, summaries, timestamps, parentage, phase, and lease information; never
persist raw prompts, transcripts, tool payloads, or assistant messages.

`Stale` is a filter/badge, not a fifth status. It applies when an Issue is In
Progress, has no live unexpired AgentRun, and has no activity for 24 hours.

## 8. macOS experience

- `Kanban` is the top-level workspace destination, so the product surface is
  distinct from GitHub Issues. `Issue` remains the native domain entity.
- Kanban keeps the existing global sidebar and a single board; Project is a
  toolbar filter.
- The four columns use the workspace background. Single-click selects a card;
  double-click opens its detail. The card context menu also provides View
  Details.
- The detail is a destination pushed in the board detail column's native
  `NavigationStack`. It replaces the board content while preserving the global
  sidebar, uses the system Back affordance, and remains below the system toolbar
  in both windowed and full-screen modes.
- The detail content shows only the Issue title and native description in a
  readable-width document layout. It has no metadata chrome, acceptance-criteria
  section, custom panel background, border, or shadow.
- Todo cards show Created. In Progress and Closure Requested show Opened. Done
  shows Opened and Closed. No duration is synthesized.
- Cards with external references show compact typed link summaries that remain
  readable under long URLs and mixed CJK/Latin content. Raw URL authoring does
  not appear in the app.
- The detail contains no text fields and no “Open in Editor” action.
- Right-clicking a card exposes its contextual commands: Copy Issue ID on every
  state; Delete on non-Done states; Approve Closure and Request Changes on
  Closure Requested; Reopen or Archive on Done; and Open/Copy commands for each
  external reference when present.
- Done icons are green in the board column.
- There is no New Issue button: the user asks an Agent in natural language and
  the Agent calls `issue.create`.
- Project, Stale, external-reference filters, unlinked activity, and concise
  workflow guidance may remain toolbar controls. Automatic polling has no
  persistent toolbar indicator; manual retry appears only when a refresh
  actually fails.

## 9. Acceptance criteria

- Native Issues continue to exist and change independently of Context files.
- An Agent can create/update/list an Issue through MCP without using `store`.
- An Agent can resolve a copied global Issue ID through `issue.get` and discover
  the owning Project.
- `issue.start` enters In Progress; Stop has no Issue transition.
- A root Agent can request closure but cannot approve its own request.
- Only the desktop Approve gate moves Closure Requested to Done.
- Request Changes and Reopen are explicit, validated, revision-safe gates.
- Cards push the native full-content detail by double-click or View Details;
  Back returns to the existing board state and every visible command works.
- Cards and detail expose native Issue lifecycle timing without substituting
  AgentRun start/stop timestamps.
- The UI offers no direct Issue authoring and shows Done with a green icon.
- Legacy Context Issues are imported at most once and are not live-linked.
- The Markdown export capability exists as a native Todo Issue.
