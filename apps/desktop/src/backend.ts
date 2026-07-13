import {
  createDaemonApiClient,
  createPublicApiClient,
  ClumsiesApiError,
  ClumsiesApi,
  type DaemonApiClient,
  type DaemonBootstrapStatus,
  type DaemonDraftDetail,
  type DaemonDraftOperationRequest,
  type DaemonHealth,
  type DaemonMcpStatus,
  type DaemonProjectConfig,
  type DaemonSyncStatus,
  type NativeInvoke,
  type PublicSchema,
} from "@clumsies/api-client";
import {
  cloneDocument,
  documentText,
  type AuthorityResource,
  type DraftOrigin,
  type DraftRecord,
  type MemoryDocument,
  type MemoryKind,
  type PersonalBundle,
  type ReviewRecord,
  type SyncState,
} from "./model";

export type ProjectOption = {
  id: string;
  name: string;
  refCommitId: string | null;
};

export type DesktopBackendRuntime = {
  bootstrap: DaemonBootstrapStatus;
  health: DaemonHealth;
  projectConfig: DaemonProjectConfig;
  syncStatus: DaemonSyncStatus;
  mcpStatus: DaemonMcpStatus;
};

export type DesktopBackendState = {
  projects: ProjectOption[];
  orgRefCommitId: string | null;
  activeProjectId: string | null;
  resources: AuthorityResource[];
  drafts: DraftRecord[];
  bundles: PersonalBundle[];
  reviews: ReviewRecord[];
  runtime: DesktopBackendRuntime;
};

export class AuthenticationRequiredError extends Error {
  readonly serverUrl: string;

  constructor(serverUrl: string) {
    super("Sign in to connect this Desktop to the Server");
    this.name = "AuthenticationRequiredError";
    this.serverUrl = serverUrl;
  }
}

export class DesktopBackend {
  readonly daemon: DaemonApiClient;
  private readonly invoke: NativeInvoke;
  api: ClumsiesApi | null = null;

  constructor(invoke: NativeInvoke) {
    this.invoke = invoke;
    this.daemon = createDaemonApiClient(invoke);
  }

  authenticate(serverUrl: string): Promise<DaemonProjectConfig> {
    return this.invoke<DaemonProjectConfig>("authenticate_desktop", { serverUrl });
  }

  async load(): Promise<DesktopBackendState> {
    const bootstrap = await ensureDaemon(this.daemon);
    let [health, projectConfig] = await Promise.all([
      waitForDaemonHealth(this.daemon),
      this.daemon.projectConfig(),
    ]);
    if (!projectConfig.has_access_token || !projectConfig.has_refresh_token) {
      throw new AuthenticationRequiredError(projectConfig.server_url);
    }
    if (!projectConfig.project_id) {
      throw new Error("Authenticated Desktop has no active project");
    }

    const api = new ClumsiesApi(createPublicApiClient({
      baseUrl: projectConfig.server_url,
      fetch: createDaemonFetch(this.daemon),
    }));
    this.api = api;

    const [syncStatus, mcpStatus, draftPage] = await Promise.all([
      this.daemon.syncStatus(),
      this.daemon.mcpStatus(),
      this.daemon.listDrafts({ limit: 200 }),
    ]);

    const [projectPage, orgCommitState] = await Promise.all([
      api.listProjects({ limit: 200 }),
      api.orgCommitState(),
    ]);
    const projects = await Promise.all(
      projectPage.items.map(async (project) => {
        const commitState = await api.projectCommitState(project.project_id);
        return {
          id: project.project_id,
          name: project.name,
          refCommitId: commitState.state.ref.commit_id,
        };
      }),
    );
    const activeProjectId = selectActiveProject(projectConfig, projects);

    const [resources, bundlePage, reviewPage, draftDetails] = await Promise.all([
      loadResources(api, projects, orgCommitState.state.ref.commit_id),
      api.listBundles({ limit: 200 }),
      api.listReviews({ limit: 200 }),
      Promise.all(
        draftPage.items
          .filter((draft) => draft.status !== "discarded")
          .map((draft) => this.daemon.draft(draft.draft_id)),
      ),
    ]);
    const [bundleDetails, reviewDetails] = await Promise.all([
      Promise.all(bundlePage.items.map((bundle) => api.bundle(bundle.bundle_id))),
      Promise.all(reviewPage.items.map((review) => api.review(review.review_id))),
    ]);

    return {
      projects,
      orgRefCommitId: orgCommitState.state.ref.commit_id,
      activeProjectId,
      resources,
      drafts: draftDetails.map((draft) =>
        mapDaemonDraft(draft, projects, resources),
      ),
      bundles: bundleDetails.map(mapBundle),
      reviews: reviewDetails.map(mapReview),
      runtime: { bootstrap, health, projectConfig, syncStatus, mcpStatus },
    };
  }
}

export function createDaemonFetch(daemon: DaemonApiClient): typeof fetch {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const method = serverMethod(request.method);
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => {
      headers[name] = value;
    });
    const response = await daemon.serverRequest({
      method,
      path: `${url.pathname}${url.search}`,
      headers,
      body: request.body === null ? null : await request.text(),
    });
    return new Response(response.body, {
      status: response.status,
      headers: response.headers,
    });
  };
}

function serverMethod(method: string): "GET" | "POST" | "PUT" | "PATCH" | "DELETE" {
  const normalized = method.toUpperCase();
  if (
    normalized === "GET" ||
    normalized === "POST" ||
    normalized === "PUT" ||
    normalized === "PATCH" ||
    normalized === "DELETE"
  ) {
    return normalized;
  }
  throw new Error(`Unsupported Server request method: ${method}`);
}

async function ensureDaemon(
  daemon: DaemonApiClient,
): Promise<DaemonBootstrapStatus> {
  const status = await daemon.bootstrapStatus();
  if (status.runtime.running) {
    return status;
  }
  return status.runtime.bootstrapped ? daemon.restart() : daemon.start();
}

async function waitForDaemonHealth(
  daemon: DaemonApiClient,
): Promise<DaemonHealth> {
  let lastError: unknown = null;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      return await daemon.health();
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw lastError instanceof Error
    ? lastError
    : new Error("daemon did not become ready");
}

async function loadResources(
  api: ClumsiesApi,
  projects: ProjectOption[],
  orgRefCommitId: string | null,
): Promise<AuthorityResource[]> {
  const org = await loadScopedResources(api, null, null, orgRefCommitId);
  const projectResources = await Promise.all(
    projects.map((project) =>
      loadScopedResources(
        api,
        project.id,
        project.name,
        project.refCommitId,
      ),
    ),
  );
  return [...org, ...projectResources.flat()];
}

async function loadScopedResources(
  api: ClumsiesApi,
  projectId: string | null,
  projectName: string | null,
  refCommitId: string | null,
): Promise<AuthorityResource[]> {
  const [rules, context, workflows, metaprompt] = projectId
    ? await Promise.all([
        api.listProjectRules(projectId, { limit: 200 }),
        api.listProjectContext(projectId, { limit: 200 }),
        api.listProjectWorkflows(projectId, { limit: 200 }),
        optionalNotFound(() => api.projectMetaprompt(projectId)),
      ])
    : await Promise.all([
        api.listOrgRules({ limit: 200 }),
        api.listOrgContext({ limit: 200 }),
        api.listOrgWorkflows({ limit: 200 }),
        optionalNotFound(() => api.orgMetaprompt()),
      ]);

  const [ruleDetails, contextDetails, workflowDetails] = await Promise.all([
    Promise.all(
      rules.items.map((rule) =>
        projectId
          ? api.projectRule(projectId, rule.rule_id)
          : api.orgRule(rule.rule_id),
      ),
    ),
    Promise.all(
      context.items.map((item) =>
        projectId
          ? api.projectContext(projectId, item.context_id)
          : api.orgContext(item.context_id),
      ),
    ),
    Promise.all(
      workflows.items.map((workflow) =>
        projectId
          ? api.projectWorkflow(projectId, workflow.workflow_id)
          : api.orgWorkflow(workflow.workflow_id),
      ),
    ),
  ]);

  return [
    ...ruleDetails.map((detail) =>
      mapRule(detail, projectName, refCommitId),
    ),
    ...contextDetails.map((detail) =>
      mapContext(detail, projectName, refCommitId),
    ),
    ...workflowDetails.map((detail) =>
      mapWorkflow(detail, projectName, refCommitId),
    ),
    ...(metaprompt
      ? [mapMetaprompt(metaprompt, projectName, refCommitId)]
      : []),
  ];
}

function mapRule(
  detail: PublicSchema<"RuleDetail">,
  projectName: string | null,
  refCommitId: string | null,
): AuthorityResource {
  return resourceFromDocument(
    detail.rule.rule_id,
    detail.rule.scope,
    detail.rule.project_id,
    projectName,
    refCommitId,
    "Rules",
    detail.etag,
    detail.rule.updated_at,
    detail.rule.content_hash,
    {
      title: detail.rule.name,
      path: detail.rule.path,
      body: detail.body,
      appliesWhen: "",
      tags: [],
      steps: [],
    },
  );
}

function mapContext(
  detail: PublicSchema<"ContextDetail">,
  projectName: string | null,
  refCommitId: string | null,
): AuthorityResource {
  return resourceFromDocument(
    detail.context.context_id,
    detail.context.scope,
    detail.context.project_id,
    projectName,
    refCommitId,
    "Context",
    detail.etag,
    detail.context.updated_at,
    detail.context.content_hash,
    documentForBody(detail.context.path, detail.body),
  );
}

function mapWorkflow(
  detail: PublicSchema<"WorkflowDetail">,
  projectName: string | null,
  refCommitId: string | null,
): AuthorityResource {
  return resourceFromDocument(
    detail.workflow.workflow_id,
    detail.workflow.scope,
    detail.workflow.project_id,
    projectName,
    refCommitId,
    "Workflows",
    detail.etag,
    detail.workflow.updated_at,
    detail.workflow.content_hash,
    {
      title: detail.workflow.name,
      path: detail.workflow.path,
      body: "",
      appliesWhen: "",
      tags: [],
      steps: detail.steps.map(
        (step) => step.body ?? step.rule_id ?? `Step ${step.order}`,
      ),
    },
  );
}

function mapMetaprompt(
  detail: PublicSchema<"MetapromptDetail">,
  projectName: string | null,
  refCommitId: string | null,
): AuthorityResource {
  return resourceFromDocument(
    detail.metaprompt.metaprompt_id,
    detail.metaprompt.scope,
    detail.metaprompt.project_id,
    projectName,
    refCommitId,
    "Metaprompt",
    detail.etag,
    detail.metaprompt.updated_at,
    detail.metaprompt.content_hash,
    documentForBody(detail.metaprompt.path, detail.body),
  );
}

function resourceFromDocument(
  id: string,
  scope: "org" | "project",
  projectId: string | null,
  projectName: string | null,
  refCommitId: string | null,
  kind: MemoryKind,
  etag: string,
  updatedAt: string,
  contentHash: string,
  document: MemoryDocument,
): AuthorityResource {
  return {
    id,
    scope: scope === "org" ? "Hub" : "Project",
    projectId,
    projectName,
    refCommitId,
    kind,
    version: parseEtag(etag),
    contentHash,
    updatedAt: formatDate(updatedAt),
    document,
  };
}

function mapDaemonDraft(
  detail: DaemonDraftDetail,
  projects: ProjectOption[],
  resources: AuthorityResource[],
): DraftRecord {
  const summary = detail.draft;
  const resource = summary.target_id
    ? resources.find((item) => item.id === summary.target_id) ?? null
    : null;
  const kind = memoryKind(summary.resource_kind);
  const projectId = summary.project_id;
  const projectName =
    resource?.projectName ??
    projects.find((project) => project.id === projectId)?.name ??
    null;
  const document = resource
    ? cloneDocument(resource.document)
    : documentForBody(summary.path ?? defaultPath(kind), "");
  let operation: DraftRecord["operation"] = "upsert";

  for (const localOperation of detail.operations) {
    const op = localOperation.operation;
    if (op.create) {
      document.path = op.create.path;
      document.title = titleFromPath(op.create.path);
      document.body = op.create.body;
    } else if (op.update) {
      document.body = op.update.body;
    } else if (op.rename) {
      document.path = op.rename.new_path;
      document.title = titleFromPath(op.rename.new_path);
    } else if (op.delete) {
      operation = "delete";
    }
  }

  return {
    id: summary.draft_id,
    localId: summary.draft_id,
    serverId: summary.server_draft_id,
    serverVersion: summary.server_version,
    baseCommitId: summary.base_commit_id,
    baseResourceId: summary.target_id,
    scope: summary.scope === "org" ? "Hub" : "Project",
    projectId,
    projectName,
    kind,
    operation,
    origin: draftOrigin(detail),
    status: summary.status === "submitted" ? "in_review" : "editing",
    syncState: draftSyncState(detail),
    baseVersion: resource?.version ?? null,
    updatedAt: formatDate(summary.updated_at),
    document,
  };
}

export function mapBundle(
  detail: PublicSchema<"PersonalBundleDetail">,
): PersonalBundle {
  return {
    id: detail.bundle.bundle_id,
    name: detail.bundle.name,
    description: detail.bundle.description,
    resourceIds: [
      ...detail.rules.map((item) => item.rule_id),
      ...detail.context.map((item) => item.context_id),
      ...detail.workflows.map((item) => item.workflow_id),
    ],
    revision: detail.bundle.revision,
    syncState: "synced",
    updatedAt: formatDate(detail.bundle.updated_at),
  };
}

export function mapReview(detail: PublicSchema<"ReviewDetail">): ReviewRecord {
  return {
    id: detail.review.review_id,
    draftId: detail.review.draft_id,
    title: detail.review.title,
    author:
      detail.review.author.display_name ?? detail.review.author.email,
    status: detail.review.status,
    version: detail.review.version,
    createdAt: formatDate(detail.review.created_at),
    decisionNote: null,
    comments: detail.comments.map((comment) => ({
      id: comment.comment_id,
      author: comment.author.display_name ?? comment.author.email,
      body: comment.body,
      createdAt: formatDate(comment.created_at),
    })),
  };
}

export function mapReviewSummary(
  review: PublicSchema<"Review">,
): ReviewRecord {
  return {
    id: review.review_id,
    draftId: review.draft_id,
    title: review.title,
    author: review.author.display_name ?? review.author.email,
    status: review.status,
    version: review.version,
    createdAt: formatDate(review.created_at),
    decisionNote: null,
    comments: [],
  };
}

export function daemonOperationsForDraft(
  draft: DraftRecord,
  resource: AuthorityResource | null,
): DaemonDraftOperationRequest[] {
  if (!draft.projectId) {
    throw new Error("Draft has no project context");
  }
  const requestContext = {
    project_id: draft.projectId,
    scope: draft.scope === "Hub" ? "org" as const : "project" as const,
  };
  const kind = daemonResourceKind(draft.kind);
  if (draft.operation === "delete") {
    const id = draft.baseResourceId ?? draft.localId;
    if (!id) {
      return [];
    }
    return [
      {
        ...requestContext,
        draft_id: draft.localId ?? null,
        base_commit_id: draft.baseCommitId,
        resource: kind,
        op: { delete: { id } },
        source: "desktop",
      },
    ];
  }

  const body =
    draft.kind === "Workflows"
      ? documentText(draft.kind, draft.document)
      : draft.document.body;
  if (!draft.baseResourceId) {
    return [
      {
        ...requestContext,
        draft_id: draft.localId ?? null,
        base_commit_id: draft.baseCommitId,
        resource: kind,
        op: {
          create: {
            path: draft.document.path,
            body,
          },
        },
        source: "desktop",
      },
    ];
  }

  const requests: DaemonDraftOperationRequest[] = [];
  if (
    resource &&
    draft.document.path !== resource.document.path &&
    draft.baseResourceId
  ) {
    requests.push({
      ...requestContext,
      draft_id: draft.localId ?? null,
      base_commit_id: draft.baseCommitId,
      resource: kind,
      op: {
        rename: {
          id: draft.baseResourceId,
          new_path: draft.document.path,
        },
      },
      source: "desktop",
    });
  }
  const target = draft.baseResourceId ?? draft.localId;
  if (target) {
    requests.push({
      ...requestContext,
      draft_id: draft.localId ?? null,
      base_commit_id: draft.baseCommitId,
      resource: kind,
      op: { update: { id: target, body } },
      source: "desktop",
    });
  }
  return requests;
}

export function daemonDiscardOperationForDraft(
  draft: DraftRecord,
): DaemonDraftOperationRequest | null {
  const id = draft.localId ?? draft.baseResourceId;
  if (!id) {
    return null;
  }
  if (!draft.projectId) {
    throw new Error("Draft has no project context");
  }
  return {
    project_id: draft.projectId,
    scope: draft.scope === "Hub" ? "org" : "project",
    draft_id: draft.localId ?? null,
    base_commit_id: draft.baseCommitId,
    resource: daemonResourceKind(draft.kind),
    op: { discard: { id } },
    source: "desktop",
  };
}

export function syncStateForDaemonDraft(detail: DaemonDraftDetail): SyncState {
  return draftSyncState(detail);
}

function draftOrigin(detail: DaemonDraftDetail): DraftOrigin {
  const source = detail.operations.at(-1)?.source;
  if (source === "mcp_store") {
    return "MCP";
  }
  if (source === "cli") {
    return "CLI";
  }
  return "Desktop";
}

function draftSyncState(detail: DaemonDraftDetail): SyncState {
  if (detail.draft.status === "conflicted") {
    return "conflict";
  }
  if (detail.operations.some((operation) => operation.sync_status === "failed")) {
    return "failed";
  }
  if (
    detail.operations.some(
      (operation) =>
        operation.sync_status === "queued" || operation.sync_status === "syncing",
    )
  ) {
    return "syncing";
  }
  return detail.operations.length > 0 ? "synced" : "local";
}

function documentForBody(path: string, body: string): MemoryDocument {
  return {
    title: markdownTitle(body, titleFromPath(path)),
    path,
    body,
    appliesWhen: "",
    tags: [],
    steps: [],
  };
}

function memoryKind(kind: string): MemoryKind {
  if (kind === "rule") {
    return "Rules";
  }
  if (kind === "workflow") {
    return "Workflows";
  }
  if (kind === "metaprompt") {
    return "Metaprompt";
  }
  return "Context";
}

function daemonResourceKind(
  kind: MemoryKind,
): "context" | "rule" | "workflow" | "metaprompt" {
  if (kind === "Rules") {
    return "rule";
  }
  if (kind === "Workflows") {
    return "workflow";
  }
  if (kind === "Metaprompt") {
    return "metaprompt";
  }
  return "context";
}

function selectActiveProject(
  config: DaemonProjectConfig,
  projects: ProjectOption[],
): string | null {
  if (
    config.project_id &&
    projects.some((project) => project.id === config.project_id)
  ) {
    return config.project_id;
  }
  return projects[0]?.id ?? null;
}

function parseEtag(etag: string): number {
  const revision = Number.parseInt(
    etag.replaceAll('"', "").replace(/^rev-/, ""),
    10,
  );
  return Number.isFinite(revision) ? revision : 0;
}

function titleFromPath(path: string): string {
  const name = path.split("/").filter(Boolean).at(-1) ?? path;
  return name.replace(/\.[^.]+$/, "");
}

function defaultPath(kind: MemoryKind): string {
  if (kind === "Rules") {
    return "rules/untitled";
  }
  if (kind === "Workflows") {
    return "workflows/untitled";
  }
  if (kind === "Metaprompt") {
    return "META_PROMPT.md";
  }
  return "context/untitled.md";
}

function markdownTitle(body: string, fallback: string): string {
  return body.match(/^#\s+(.+)$/m)?.[1]?.trim() || fallback;
}

function formatDate(value: string): string {
  return value.slice(0, 10);
}

async function optionalNotFound<T>(read: () => Promise<T>): Promise<T | null> {
  try {
    return await read();
  } catch (error) {
    if (error instanceof ClumsiesApiError && error.status === 404) {
      return null;
    }
    throw error;
  }
}
