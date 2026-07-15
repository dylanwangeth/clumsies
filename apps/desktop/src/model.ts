export const memoryKinds = ["Context", "Rules", "Workflows", "Metaprompt"] as const;

export type MemoryKind = (typeof memoryKinds)[number];
export type MemoryScope = "Hub" | "Project";
export type DraftOrigin = "Desktop" | "MCP" | "CLI";
export type DraftStatus = "editing" | "in_review" | "merged";
export type SyncState = "local" | "syncing" | "synced" | "failed" | "conflict";
export type ReviewStatus = "open" | "approved" | "rejected" | "merged";
export type ResourceWorkingState =
  | "clean"
  | "draft"
  | "new"
  | "deletion"
  | "review"
  | "conflict";

export type WorkflowStepDocument = {
  ruleId: string | null;
  body: string | null;
};

export type DraftResourceContent =
  | { kind: "context"; content: string }
  | {
      kind: "rule";
      name?: string | null;
      applies_when?: string | null;
      constraint: string;
      tags?: string[] | null;
    }
  | {
      kind: "workflow";
      name?: string | null;
      description: string;
      steps: Array<{ rule_id: string | null; body: string | null }>;
    }
  | { kind: "metaprompt"; content: string };

export type MemoryDocument = {
  title: string;
  path: string;
  body: string;
  appliesWhen: string;
  tags: string[];
  steps: WorkflowStepDocument[];
};

export type AuthorityResource = {
  id: string;
  scope: MemoryScope;
  projectId: string | null;
  projectName: string | null;
  kind: MemoryKind;
  version: number;
  refCommitId?: string | null;
  contentHash?: string;
  updatedAt: string;
  document: MemoryDocument;
};

export type MemoryChange = {
  baseCommitId: string | null;
  baseResourceId: string | null;
  scope: MemoryScope;
  projectId: string | null;
  projectName: string | null;
  kind: MemoryKind;
  operation: "upsert" | "delete";
  document: MemoryDocument;
};

export type ReviewChange = MemoryChange & {
  beforeText: string | null;
  afterText: string | null;
};

export type DraftRecord = MemoryChange & {
  id: string;
  localId?: string;
  serverId?: string | null;
  serverVersion?: number;
  origin: DraftOrigin;
  status: DraftStatus;
  syncState: SyncState;
  conflict?: DraftConflictRecord | null;
  baseVersion: number | null;
  updatedAt: string;
};

export type DraftConflictRecord = {
  baseCommitId: string | null;
  currentCommitId: string | null;
  detectedAt: string;
};

export type ReviewOperation = {
  action: "create" | "update" | "rename" | "delete";
  resource: {
    scope: "org" | "project";
    kind: "context" | "rule" | "workflow" | "metaprompt";
    id: string | null;
    path: string | null;
  };
  content: DraftResourceContent | null;
  newPath: string | null;
};

export type ReviewConflict = DraftConflictRecord & {
  baseContent: string | null;
  currentContent: string | null;
};

export type ReviewComment = {
  id: string;
  author: string;
  body: string;
  createdAt: string;
};

export type ReviewRecord = {
  id: string;
  draftId: string;
  authorId: string;
  title: string;
  author: string;
  status: ReviewStatus;
  version?: number;
  draftVersion?: number;
  operations?: ReviewOperation[];
  conflict?: ReviewConflict | null;
  change: ReviewChange;
  createdAt: string;
  decisionNote: string | null;
  comments: ReviewComment[];
};

export type PersonalBundle = {
  id: string;
  name: string;
  description: string;
  resourceIds: string[];
  revision?: number;
  syncState: SyncState;
  updatedAt: string;
};

export type ResourceListItem = {
  selectionId: string;
  resource: AuthorityResource | null;
  draft: DraftRecord | null;
  document: MemoryDocument;
  kind: MemoryKind;
  scope: MemoryScope;
  projectId: string | null;
  projectName: string | null;
  workspaceView: "Hub" | "Local";
  workspaceProjectId: string | null;
  inherited: boolean;
};

export type SearchResult =
  | { type: "memory"; id: string; label: string; detail: string; scope: MemoryScope }
  | { type: "draft"; id: string; label: string; detail: string; scope: MemoryScope }
  | { type: "bundle"; id: string; label: string; detail: string }
  | { type: "review"; id: string; label: string; detail: string };

const blankDocument = (kind: MemoryKind, suffix: string): MemoryDocument => ({
  title: `Untitled ${kind === "Rules" ? "Rule" : kind}`,
  path:
    kind === "Context"
      ? `context/untitled-${suffix}.md`
      : kind === "Rules"
        ? `rules/untitled-${suffix}`
        : kind === "Workflows"
          ? `workflow/untitled-${suffix}`
          : "META_PROMPT.md",
  body:
    kind === "Rules"
      ? "State the durable constraint here."
      : kind === "Context" || kind === "Metaprompt"
        ? `# Untitled ${kind}\n\n`
        : "",
  appliesWhen: kind === "Rules" ? "Describe when this rule applies." : "",
  tags: [],
  steps:
    kind === "Workflows"
      ? [{ ruleId: null, body: "Describe the first step" }]
      : [],
});

export function createBlankDraft(
  scope: MemoryScope,
  kind: MemoryKind,
  projectId: string | null,
  projectName: string | null,
  baseCommitId: string | null = null,
): DraftRecord {
  const suffix = Date.now().toString(36);
  return {
    id: `draft-${scope.toLowerCase()}-${kind.toLowerCase()}-${suffix}`,
    baseCommitId,
    baseResourceId: null,
    scope,
    projectId,
    projectName,
    kind,
    operation: "upsert",
    origin: "Desktop",
    status: "editing",
    syncState: "local",
    baseVersion: null,
    updatedAt: "just now",
    document: blankDocument(kind, suffix),
  };
}

export function createDraftFromResource(resource: AuthorityResource): DraftRecord {
  return {
    id: `draft-${resource.id}-${Date.now().toString(36)}`,
    baseCommitId: resource.refCommitId ?? null,
    baseResourceId: resource.id,
    scope: resource.scope,
    projectId: resource.projectId,
    projectName: resource.projectName,
    kind: resource.kind,
    operation: "upsert",
    origin: "Desktop",
    status: "editing",
    syncState: "local",
    baseVersion: resource.version,
    updatedAt: "just now",
    document: cloneDocument(resource.document),
  };
}

export function reviewChangeFromDraft(
  draft: DraftRecord,
  resource: AuthorityResource | null,
): ReviewChange {
  return {
    baseCommitId: draft.baseCommitId,
    baseResourceId: draft.baseResourceId,
    scope: draft.scope,
    projectId: draft.projectId,
    projectName: draft.projectName,
    kind: draft.kind,
    operation: draft.operation,
    document: cloneDocument(draft.document),
    beforeText: resource ? documentText(resource.kind, resource.document) : null,
    afterText:
      draft.operation === "delete"
        ? null
        : documentText(draft.kind, draft.document),
  };
}

export function cloneDocument(document: MemoryDocument): MemoryDocument {
  return {
    ...document,
    tags: [...document.tags],
    steps: document.steps.map((step) => ({ ...step })),
  };
}

export function listResources(
  resources: AuthorityResource[],
  drafts: DraftRecord[],
  scope: MemoryScope,
  projectId: string | null,
  kind: MemoryKind,
): ResourceListItem[] {
  const scopedResources = resources.filter(
    (resource) =>
      resource.scope === scope &&
      resource.kind === kind &&
      (scope === "Hub" || resource.projectId === projectId),
  );
  const activeDrafts = drafts.filter(
    (draft) =>
      draft.status !== "merged" &&
      draft.scope === scope &&
      draft.kind === kind &&
      (scope === "Hub" || draft.projectId === projectId),
  );
  const draftsByResource = new Map(
    activeDrafts
      .filter((draft) => draft.baseResourceId)
      .map((draft) => [draft.baseResourceId as string, draft]),
  );

  const items = scopedResources.map((resource): ResourceListItem => {
    const draft = draftsByResource.get(resource.id) ?? null;
    return {
      selectionId: resource.id,
      resource,
      draft,
      document: draft?.document ?? resource.document,
      kind,
      scope,
      projectId: resource.projectId,
      projectName: resource.projectName,
      workspaceView: scope === "Hub" ? "Hub" : "Local",
      workspaceProjectId: scope === "Project" ? projectId : null,
      inherited: false,
    };
  });

  for (const draft of activeDrafts) {
    if (draft.baseResourceId) {
      continue;
    }
    items.unshift({
      selectionId: draft.id,
      resource: null,
      draft,
      document: draft.document,
      kind,
      scope,
      projectId: draft.projectId,
      projectName: draft.projectName,
      workspaceView: scope === "Hub" ? "Hub" : "Local",
      workspaceProjectId: scope === "Project" ? projectId : null,
      inherited: false,
    });
  }

  return items.sort((left, right) => left.document.path.localeCompare(right.document.path));
}

export function listLocalResources(
  resources: AuthorityResource[],
  drafts: DraftRecord[],
  projectId: string | null,
  kind: MemoryKind,
  selectedOrgResourceIds: readonly string[],
): ResourceListItem[] {
  const projectItems = listResources(resources, drafts, "Project", projectId, kind);
  const selectedIds = new Set(selectedOrgResourceIds);
  const inheritedItems = resources
    .filter(
      (resource) =>
        resource.scope === "Hub" &&
        resource.kind === kind &&
        selectedIds.has(resource.id),
    )
    .map((resource): ResourceListItem => ({
      selectionId: resource.id,
      resource,
      draft: null,
      document: resource.document,
      kind,
      scope: resource.scope,
      projectId: resource.projectId,
      projectName: resource.projectName,
      workspaceView: "Local",
      workspaceProjectId: projectId,
      inherited: true,
    }));
  return [...projectItems, ...inheritedItems].sort((left, right) =>
    left.document.path.localeCompare(right.document.path),
  );
}

export function findListItem(
  items: ResourceListItem[],
  selectedId: string | null,
): ResourceListItem | null {
  return items.find((item) => item.selectionId === selectedId) ?? items[0] ?? null;
}

export function resourceWorkingState(item: ResourceListItem): ResourceWorkingState {
  const draft = item.draft;
  if (!draft) {
    return "clean";
  }
  if (draft.syncState === "conflict") {
    return "conflict";
  }
  if (draft.status === "in_review") {
    return "review";
  }
  if (draft.operation === "delete") {
    return "deletion";
  }
  if (!draft.baseResourceId) {
    return "new";
  }
  return "draft";
}

export function applyDraft(
  resources: AuthorityResource[],
  draft: DraftRecord,
): AuthorityResource[] {
  return applyMemoryChange(resources, draft, `memory-${draft.id}`);
}

export function applyMemoryChange(
  resources: AuthorityResource[],
  change: MemoryChange,
  newResourceId: string,
): AuthorityResource[] {
  if (change.operation === "delete") {
    return resources.filter((resource) => resource.id !== change.baseResourceId);
  }

  if (!change.baseResourceId) {
    const next: AuthorityResource = {
      id: newResourceId,
      scope: change.scope,
      projectId: change.projectId,
      projectName: change.projectName,
      kind: change.kind,
      version: 1,
      updatedAt: "just now",
      document: cloneDocument(change.document),
    };
    return [next, ...resources];
  }

  return resources.map((resource) =>
    resource.id === change.baseResourceId
      ? {
          ...resource,
          version: resource.version + 1,
          updatedAt: "just now",
          document: cloneDocument(change.document),
        }
      : resource,
  );
}

export function documentText(kind: MemoryKind, document: MemoryDocument): string {
  if (kind === "Rules") {
    return [
      `# ${document.title}`,
      "",
      "## Applies when",
      "",
      document.appliesWhen,
      "",
      "## Constraint",
      "",
      document.body,
      "",
      `Tags: ${document.tags.join(", ") || "None"}`,
    ].join("\n");
  }
  if (kind === "Workflows") {
    return [
      `# ${document.title}`,
      "",
      document.body,
      "",
      ...document.steps.map(
        (step, index) =>
          `${index + 1}. ${step.body ?? (step.ruleId ? `Apply rule \`${step.ruleId}\`.` : "")}`,
      ),
    ].join("\n");
  }
  return document.body;
}

export function reviewDiff(
  resource: AuthorityResource | null,
  change: MemoryChange | ReviewChange,
): string[] {
  const beforeText = "beforeText" in change
    ? change.beforeText
    : resource
      ? documentText(resource.kind, resource.document)
      : null;
  const afterText = "afterText" in change
    ? change.afterText
    : documentText(change.kind, change.document);
  if (change.operation === "delete") {
    return beforeText === null
      ? ["- Delete this memory after the review is merged."]
      : beforeText.split("\n").map((line) => `- ${line}`);
  }
  if (beforeText === null) {
    return (afterText ?? "")
      .split("\n")
      .map((line) => `+ ${line}`);
  }

  const before = beforeText.split("\n");
  const after = (afterText ?? "").split("\n");
  const lines: string[] = [];
  const length = Math.max(before.length, after.length);
  for (let index = 0; index < length; index += 1) {
    if (before[index] === after[index]) {
      lines.push(`  ${before[index] ?? ""}`);
      continue;
    }
    if (before[index] !== undefined) {
      lines.push(`- ${before[index]}`);
    }
    if (after[index] !== undefined) {
      lines.push(`+ ${after[index]}`);
    }
  }
  return lines;
}

export function globalSearch(
  query: string,
  resources: AuthorityResource[],
  drafts: DraftRecord[],
  bundles: PersonalBundle[],
  reviews: ReviewRecord[],
): SearchResult[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) {
    return [];
  }
  const matches = (value: string) => value.toLocaleLowerCase().includes(needle);
  const results: SearchResult[] = [];

  for (const resource of resources) {
    const haystack = `${resource.document.title} ${resource.document.path} ${resource.kind} ${resource.document.body}`;
    if (matches(haystack)) {
      results.push({
        type: "memory",
        id: resource.id,
        label: resource.document.title,
        detail: `${resource.scope} · ${resource.kind}`,
        scope: resource.scope,
      });
    }
  }
  for (const draft of drafts.filter((item) => item.status !== "merged")) {
    const haystack = `${draft.document.title} ${draft.document.path} ${draft.kind} ${draft.origin}`;
    if (matches(haystack)) {
      results.push({
        type: "draft",
        id: draft.id,
        label: draft.document.title,
        detail: `${draft.origin} draft · ${draft.projectName ?? "Hub"}`,
        scope: draft.scope,
      });
    }
  }
  for (const bundle of bundles) {
    if (matches(`${bundle.name} ${bundle.description}`)) {
      results.push({
        type: "bundle",
        id: bundle.id,
        label: bundle.name,
        detail: `${bundle.resourceIds.length} resources`,
      });
    }
  }
  for (const review of reviews) {
    if (matches(`${review.title} ${review.author} ${review.status}`)) {
      results.push({
        type: "review",
        id: review.id,
        label: review.title,
        detail: `${review.status} · ${review.author}`,
      });
    }
  }
  return results.slice(0, 12);
}

const context = (
  title: string,
  path: string,
  body: string,
): MemoryDocument => ({
  title,
  path,
  body,
  appliesWhen: "",
  tags: [],
  steps: [],
});

const rule = (
  title: string,
  path: string,
  appliesWhen: string,
  body: string,
  tags: string[],
): MemoryDocument => ({
  title,
  path,
  body,
  appliesWhen,
  tags,
  steps: [],
});

const workflow = (
  title: string,
  path: string,
  body: string,
  steps: string[],
): MemoryDocument => ({
  title,
  path,
  body,
  appliesWhen: "",
  tags: [],
  steps: steps.map((step) => ({ ruleId: null, body: step })),
});

const koalResource = (
  id: string,
  kind: MemoryKind,
  version: number,
  updatedAt: string,
  document: MemoryDocument,
): AuthorityResource => ({
  id,
  scope: "Project",
  projectId: "koal",
  projectName: "Koal",
  kind,
  version,
  updatedAt,
  document,
});

export const initialResources: AuthorityResource[] = [
  {
    id: "hub-context-desktop-product",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Context",
    version: 4,
    updatedAt: "2h ago",
    document: context(
      "Desktop product architecture",
      "architecture/desktop-product.md",
      "# Desktop product architecture\n\nClumsies Desktop is the primary workspace for organization and project memory. The local daemon owns drafts, synchronization, and recovery independently of the window lifecycle.",
    ),
  },
  {
    id: "hub-context-external-memory",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Context",
    version: 7,
    updatedAt: "1d ago",
    document: context(
      "External memory model",
      "architecture/external-memory.md",
      "# External memory model\n\nExternal memory includes context, rules, workflows, and the metaprompt. Changes enter a personal draft before review can produce a new authoritative version.",
    ),
  },
  {
    id: "hub-rule-ui-product",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Rules",
    version: 3,
    updatedAt: "3h ago",
    document: rule(
      "Semantic single source",
      "style/UIUX_DESIGN_METHOD",
      "Designing or reviewing a user interface",
      "Express each interface meaning through one primary source. Visible text must add information instead of repeating structure, selection, iconography, or color.",
      ["ui", "semantics", "product"],
    ),
  },
  {
    id: "hub-rule-compatibility",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Rules",
    version: 5,
    updatedAt: "4d ago",
    document: rule(
      "No compatibility layers",
      "coding/COMPATIBILITY",
      "Changing pre-product interfaces without external users",
      "Migrate the implementation directly. Do not preserve obsolete interfaces through wrappers or aliases.",
      ["coding", "migration"],
    ),
  },
  {
    id: "hub-workflow-coding",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Workflows",
    version: 8,
    updatedAt: "2d ago",
    document: workflow(
      "Coding",
      "workflow/CODING",
      "Implement repository changes with loaded rules and proportional verification.",
      [
        "Activate relevant rules and context",
        "Inspect the existing implementation",
        "Implement the smallest coherent change",
        "Run focused tests and review the diff",
      ],
    ),
  },
  {
    id: "hub-metaprompt-default",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Metaprompt",
    version: 6,
    updatedAt: "6h ago",
    document: context(
      "Default agent metaprompt",
      "META_PROMPT.md",
      "# Clumsies\n\nActivate relevant memory before substantive work. Retrieve only selected resources and store every proposed change as a personal draft.",
    ),
  },
  {
    id: "project-context-daemon",
    scope: "Project",
    projectId: "koal",
    projectName: "Koal",
    kind: "Context",
    version: 9,
    updatedAt: "25m ago",
    document: context(
      "Desktop daemon decision",
      "adr/ADR_012_DESKTOP_DAEMON_LOCAL_MEMORY_RUNTIME.md",
      "# Desktop daemon decision\n\n## Context\n\nThe Desktop owns the product experience. A user-level daemon owns the local draft projection, synchronization queue, cache, and recovery independently of whether the Desktop window is open.\n\n## Decision\n\nUse a macOS LaunchAgent and XPC Mach service as the local memory runtime.",
    ),
  },
  {
    id: "project-context-production",
    scope: "Project",
    projectId: "koal",
    projectName: "Koal",
    kind: "Context",
    version: 5,
    updatedAt: "1h ago",
    document: context(
      "Production architecture",
      "clumsies/外部记忆生产化架构设计.md",
      "# Production architecture\n\nHub is authoritative, the daemon owns local runtime state, and Desktop is the primary memory workspace. Web is limited to administration.",
    ),
  },
  {
    id: "project-rule-testing",
    scope: "Project",
    projectId: "koal",
    projectName: "Koal",
    kind: "Rules",
    version: 2,
    updatedAt: "2d ago",
    document: rule(
      "Rust integration testing",
      "rust/TEST_RS",
      "Adding or changing Rust persistence and service behavior",
      "Exercise behavior through the real PostgreSQL integration boundary when persistence semantics are involved.",
      ["rust", "testing"],
    ),
  },
  {
    id: "project-workflow-release",
    scope: "Project",
    projectId: "koal",
    projectName: "Koal",
    kind: "Workflows",
    version: 3,
    updatedAt: "3d ago",
    document: workflow(
      "Release",
      "workflow/RELEASE",
      "Prepare and publish a verified Clumsies release.",
      ["Review the release diff", "Run workspace verification", "Publish artifacts", "Verify installation"],
    ),
  },
  {
    id: "project-metaprompt",
    scope: "Project",
    projectId: "koal",
    projectName: "Koal",
    kind: "Metaprompt",
    version: 11,
    updatedAt: "18m ago",
    document: context(
      "Workspace metaprompt",
      "META_PROMPT.md",
      "# Clumsies workspace\n\nThis workspace uses Clumsies to activate, retrieve, and refine external memory for every agent task.",
    ),
  },
  koalResource(
    "project-context-api-contract",
    "Context",
    6,
    "42m ago",
    context(
      "API contract design",
      "clumsies/API 契约设计.md",
      "# API contract design\n\nThe product contract separates public Desktop and CLI APIs, Web Admin APIs, and the local daemon contract. Context, rules, workflows, and the singleton metaprompt remain concrete resources rather than a generic memory endpoint.",
    ),
  ),
  koalResource(
    "project-context-monorepo",
    "Context",
    4,
    "3h ago",
    context(
      "Monorepo and technology stack",
      "clumsies/monorepo 改造与技术栈选型.md",
      "# Monorepo and technology stack\n\nBun manages the TypeScript workspace, Tauri hosts the Desktop shell, Rust owns the daemon and server evolution, and Zig remains focused on CLI, TUI, and MCP adapter entry points.",
    ),
  ),
  koalResource(
    "project-context-implementation-plan",
    "Context",
    10,
    "14m ago",
    context(
      "Production implementation plan",
      "clumsies/生产化实施规划.md",
      "# Production implementation plan\n\nThe implementation plan records ordered phases and manually managed status. No phase status changes without an explicit user instruction.",
    ),
  ),
  koalResource(
    "project-context-app-shell",
    "Context",
    3,
    "1d ago",
    context(
      "Desktop app shell",
      "design/01_APP_SHELL.md",
      "# Desktop app shell\n\nThe shell separates the global sidebar, workbench content region, optional navigator, main pane, optional agent panel, and bottom toolbar.",
    ),
  ),
  koalResource(
    "project-context-content-editing",
    "Context",
    2,
    "1d ago",
    context(
      "Content editing",
      "design/12_CONTENT_EDITING.md",
      "# Content editing\n\nContext is a file-backed resource and can use common text formats. Markdown source opens in the text editor and renders in a separate preview item. Rules and workflows keep structured editors that preserve their distinct storage models.",
    ),
  ),
  koalResource(
    "project-context-memory-graph",
    "Context",
    5,
    "20m ago",
    context(
      "Dynamic memory graph foundations",
      "studies/dynamic_memory_graph/README.md",
      "# Dynamic memory graph foundations\n\nThis study maps the open questions around memory identity, associations, salience, activation, consolidation, and evaluation before choosing an implementation model.",
    ),
  ),
  koalResource(
    "project-context-associative-model",
    "Context",
    3,
    "46m ago",
    context(
      "Associative context model",
      "studies/agent/ASSOCIATIVE_CONTEXT_MODEL.md",
      "# Associative context model\n\nThe study explores how task cues can activate a bounded set of related context without treating retrieval as a flat keyword search.",
    ),
  ),
  koalResource(
    "project-context-memrl-recall",
    "Context",
    2,
    "55m ago",
    context(
      "MemRL for context recall",
      "studies/agent/MEMRL_FOR_CONTEXT_RECALL.md",
      "# MemRL for context recall\n\nThe study examines whether outcome feedback can improve which memories are activated for a task while preserving an inspectable retrieval boundary.",
    ),
  ),
  koalResource(
    "project-context-role-members",
    "Context",
    1,
    "2d ago",
    context(
      "Roles and workspace members",
      "todo/ROLE_AND_WORKSPACE_MEMBERS.md",
      "# Roles and workspace members\n\nDefine the remaining authorization and membership decisions for organization and project collaboration.",
    ),
  ),
  koalResource(
    "project-context-root-architecture",
    "Context",
    12,
    "5d ago",
    context(
      "Clumsies architecture",
      "01_ARCHITECTURE.md",
      "# Clumsies architecture\n\nThe architecture records the system boundaries that connect Hub authority, local clients, managed memory, and workspace distribution.",
    ),
  ),
  koalResource(
    "project-context-manifest-schema",
    "Context",
    2,
    "3h ago",
    context(
      "Context manifest schema",
      "schemas/context-manifest.schema.json",
      "{\n  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",\n  \"title\": \"Clumsies context manifest\",\n  \"type\": \"object\",\n  \"required\": [\"resources\"],\n  \"properties\": {\n    \"resources\": {\n      \"type\": \"array\",\n      \"items\": {\n        \"type\": \"string\"\n      }\n    }\n  }\n}\n",
    ),
  ),
  koalResource(
    "project-context-routing-config",
    "Context",
    3,
    "5h ago",
    context(
      "Context routing configuration",
      "config/context-routing.yaml",
      "activation:\n  default_limit: 12\n  include_project_context: true\nretrieval:\n  max_documents: 20\n  prefer_local_drafts: true\n",
    ),
  ),
  koalResource(
    "project-context-desktop-config",
    "Context",
    1,
    "1d ago",
    context(
      "Desktop runtime configuration",
      "config/desktop.toml",
      "[daemon]\nautostart = true\n\n[sync]\ndebounce_ms = 650\nconflict_policy = \"review\"\n",
    ),
  ),
  koalResource(
    "project-rule-document-structure",
    "Rules",
    4,
    "4h ago",
    rule(
      "Document structure",
      "clumsies/DOCUMENT_STRUCTURE",
      "Creating or revising a managed Context or Rule document",
      "Use the minimum required document opening and language conventions so future humans and agents can identify the document without reconstructing its intent.",
      ["clumsies", "documents"],
    ),
  ),
  koalResource(
    "project-rule-study-document",
    "Rules",
    3,
    "6h ago",
    rule(
      "Study document",
      "clumsies/STUDY_DOCUMENT",
      "Writing internal technical study context",
      "Explain the technical object clearly enough that a future reader can recover the formed understanding without repeating the complete investigation.",
      ["study", "writing"],
    ),
  ),
  koalResource(
    "project-rule-mission-document",
    "Rules",
    2,
    "1d ago",
    rule(
      "Mission document",
      "clumsies/MISSION_DOCUMENT",
      "Recording a durable project mission",
      "Preserve the long-term purpose and boundaries that short-term implementation work must not silently redefine.",
      ["mission", "product"],
    ),
  ),
  koalResource(
    "project-rule-adr-document",
    "Rules",
    6,
    "2d ago",
    rule(
      "ADR document",
      "arch/ADR_DOCUMENT",
      "Recording an architectural decision",
      "State the context, decision, rejected alternatives, and consequences so the reasoning remains recoverable after the implementation changes.",
      ["architecture", "adr"],
    ),
  ),
  koalResource(
    "project-rule-architecture-workflow",
    "Rules",
    4,
    "2d ago",
    rule(
      "Architecture workflow",
      "arch/ARCH_WORKFLOW",
      "Designing or revising system architecture",
      "Work through the architecture layers in order and keep product boundaries, contracts, implementation, and operational consequences explicit.",
      ["architecture", "workflow"],
    ),
  ),
  koalResource(
    "project-workflow-coding",
    "Workflows",
    9,
    "2h ago",
    workflow(
      "Coding",
      "workflow/CODING",
      "Implement a repository change using activated workspace memory.",
      [
        "Activate relevant rules and context",
        "Inspect the current implementation and worktree",
        "Make the smallest coherent change",
        "Run focused verification and review the diff",
      ],
    ),
  ),
  koalResource(
    "project-workflow-study",
    "Workflows",
    5,
    "4h ago",
    workflow(
      "Study",
      "workflow/STUDY",
      "Investigate a technical object and preserve the resulting understanding.",
      ["Define the question", "Collect primary evidence", "Resolve contradictions", "Write durable study context"],
    ),
  ),
  koalResource(
    "project-workflow-todo",
    "Workflows",
    4,
    "5h ago",
    workflow(
      "Todo",
      "workflow/TODO",
      "Capture work that must survive the current task.",
      ["Clarify the unfinished objective", "Record dependencies and constraints", "Store the Todo as managed context"],
    ),
  ),
  koalResource(
    "project-workflow-commit-message",
    "Workflows",
    7,
    "7h ago",
    workflow(
      "Generate commit message",
      "workflow/GEN_COMMIT_MSG",
      "Generate a commit message from the staged change and repository conventions.",
      ["Inspect staged files", "Identify the single change intent", "Generate the message", "Validate it with the commit hook"],
    ),
  ),
  koalResource(
    "project-workflow-error-prone",
    "Workflows",
    3,
    "1d ago",
    workflow(
      "Record error-prone work",
      "workflow/ERROR_PRONE",
      "Turn a recurring or high-risk mistake into durable workspace memory.",
      ["Describe the failure mode", "Identify the triggering conditions", "Record the preventive rule or context"],
    ),
  ),
  koalResource(
    "project-workflow-commit-hook",
    "Workflows",
    2,
    "2d ago",
    workflow(
      "Set up commit message hook",
      "workflow/SETUP_COMMIT_MSG_HOOK",
      "Install the repository commit message hook used by Clumsies workflows.",
      ["Locate the repository hook directory", "Install the managed hook", "Verify an invalid message is rejected"],
    ),
  ),
];

export const initialDrafts: DraftRecord[] = [
  {
    id: "draft-mcp-production-architecture",
    baseCommitId: null,
    baseResourceId: "project-context-production",
    scope: "Project",
    projectId: "koal",
    projectName: "Koal",
    kind: "Context",
    operation: "upsert",
    origin: "MCP",
    status: "editing",
    syncState: "synced",
    baseVersion: 5,
    updatedAt: "8m ago",
    document: context(
      "Production architecture",
      "clumsies/外部记忆生产化架构设计.md",
      "# Production architecture\n\nHub is authoritative, the daemon owns local runtime state, and Desktop is the primary memory workspace. Web is limited to administration.\n\n## Product constraint\n\nDraft synchronization is automatic. Users decide whether to continue editing, submit a review, or discard the draft; they never upload it manually.",
    ),
  },
  {
    id: "draft-review-desktop-shell",
    baseCommitId: null,
    baseResourceId: "hub-context-desktop-product",
    scope: "Hub",
    projectId: null,
    projectName: null,
    kind: "Context",
    operation: "upsert",
    origin: "Desktop",
    status: "in_review",
    syncState: "synced",
    baseVersion: 4,
    updatedAt: "32m ago",
    document: context(
      "Desktop product architecture",
      "architecture/desktop-product.md",
      "# Desktop product architecture\n\nClumsies Desktop is the primary workspace for organization and project memory. The local daemon owns drafts, synchronization, and recovery independently of the window lifecycle.\n\nThe Agent panel proposes reviewable draft operations; it never changes authoritative memory directly.",
    ),
  },
  {
    id: "draft-cli-infinite-context",
    baseCommitId: null,
    baseResourceId: null,
    scope: "Project",
    projectId: "infinite",
    projectName: "Infinite",
    kind: "Context",
    operation: "upsert",
    origin: "CLI",
    status: "editing",
    syncState: "local",
    baseVersion: null,
    updatedAt: "1h ago",
    document: context(
      "Admission policy notes",
      "notes/admission-policy.md",
      "# Admission policy notes\n\nCapture constraints discovered while debugging policy evaluation.",
    ),
  },
];

export const initialReviews: ReviewRecord[] = [
  {
    id: "review-desktop-shell",
    draftId: "draft-review-desktop-shell",
    authorId: "preview-user",
    title: "Desktop product architecture",
    author: "weiwang",
    status: "open",
    change: reviewChangeFromDraft(
      initialDrafts[1]!,
      initialResources.find(
        (resource) => resource.id === initialDrafts[1]!.baseResourceId,
      ) ?? null,
    ),
    createdAt: "32m ago",
    decisionNote: null,
    comments: [
      {
        id: "comment-review-boundary",
        author: "dylan",
        body: "The Agent boundary is explicit and keeps authority in Hub.",
        createdAt: "18m ago",
      },
    ],
  },
  {
    id: "review-teammate-sync-boundary",
    draftId: "server-draft-teammate-sync-boundary",
    authorId: "preview-teammate",
    title: "Clarify automatic draft synchronization",
    author: "Dylan",
    status: "open",
    change: {
      baseCommitId: null,
      baseResourceId: "project-context-production",
      scope: "Project",
      projectId: "koal",
      projectName: "Koal",
      kind: "Context",
      operation: "upsert",
      document: {
        ...cloneDocument(
          initialResources.find(
            (resource) => resource.id === "project-context-production",
          )!.document,
        ),
        body: "# Production architecture\n\nDraft synchronization is automatic across Desktop and MCP. Review is the only path into authoritative memory.",
      },
      beforeText: documentText(
        "Context",
        initialResources.find(
          (resource) => resource.id === "project-context-production",
        )!.document,
      ),
      afterText: "# Production architecture\n\nDraft synchronization is automatic across Desktop and MCP. Review is the only path into authoritative memory.",
    },
    createdAt: "12m ago",
    decisionNote: null,
    comments: [],
  },
];

export const initialBundles: PersonalBundle[] = [
  {
    id: "bundle-daily-coding",
    name: "Daily coding",
    description: "Durable constraints and context used for implementation tasks.",
    resourceIds: ["hub-rule-compatibility", "hub-rule-ui-product", "hub-workflow-coding"],
    syncState: "synced",
    updatedAt: "12m ago",
  },
  {
    id: "bundle-architecture-review",
    name: "Architecture review",
    description: "Product boundaries, runtime decisions, and review rules.",
    resourceIds: ["hub-context-desktop-product", "hub-context-external-memory", "hub-rule-ui-product"],
    syncState: "synced",
    updatedAt: "2h ago",
  },
];
