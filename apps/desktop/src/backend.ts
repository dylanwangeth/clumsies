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
  type DraftResourceContent,
  type MemoryDocument,
  type MemoryKind,
  type PersonalBundle,
  type ReviewChange,
  type ReviewConflict,
  type ReviewRecord,
  type SyncState,
} from "./model";
import { ensureDaemonReady } from "./daemon-readiness";

export type ProjectOption = {
  id: string;
  name: string;
  refCommitId: string | null;
};

export type ProjectOrgSelectionState = {
  projectId: string;
  ruleIds: string[];
  contextIds: string[];
  workflowIds: string[];
  revision: number;
};

export type DesktopAccount = {
  userId: string;
  email: string;
  displayName: string | null;
  avatarUrl: string | null;
  capabilities: string[];
};

export type DesktopOrganization = {
  id: string;
  name: string;
};

export type DesktopBackendRuntime = {
  bootstrap: DaemonBootstrapStatus;
  health: DaemonHealth;
  projectConfig: DaemonProjectConfig;
  syncStatus: DaemonSyncStatus;
  mcpStatus: DaemonMcpStatus;
};

export type DesktopBackendState = {
  account: DesktopAccount;
  organization: DesktopOrganization;
  projects: ProjectOption[];
  projectOrgSelections: ProjectOrgSelectionState[];
  orgRefCommitId: string | null;
  activeProjectId: string | null;
  resources: AuthorityResource[];
  drafts: DraftRecord[];
  bundles: PersonalBundle[];
  reviews: ReviewRecord[];
  runtime: DesktopBackendRuntime;
};

export class AuthenticationRequiredError extends Error {
  constructor() {
    super("Sign in to connect this Desktop to the Server");
    this.name = "AuthenticationRequiredError";
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

  authenticate(): Promise<DaemonProjectConfig> {
    return this.invoke<DaemonProjectConfig>("authenticate_desktop");
  }

  async load(): Promise<DesktopBackendState> {
    const bootstrap = await ensureDaemonReady(this.daemon);
    let [health, projectConfig] = await Promise.all([
      waitForDaemonHealth(this.daemon),
      this.daemon.projectConfig(),
    ]);
    if (!projectConfig.has_access_token || !projectConfig.has_refresh_token) {
      throw new AuthenticationRequiredError();
    }
    if (!projectConfig.project_id) {
      throw new Error("Authenticated Desktop has no active project");
    }
    await this.daemon.retrySync({ channel: "all" });

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

    const [me, orgCommitState] = await Promise.all([
      api.me(),
      api.orgCommitState(),
    ]);
    const projectStates = await Promise.all(
      me.projects.map(async (project) => {
        const [commitState, orgSelection] = await Promise.all([
          api.projectCommitState(project.project_id),
          api.projectOrgSelection(project.project_id),
        ]);
        return {
          project: {
            id: project.project_id,
            name: project.name,
            refCommitId: commitState.state.ref.commit_id,
          },
          orgSelection: mapProjectOrgSelection(orgSelection),
        };
      }),
    );
    const projects = projectStates.map((state) => state.project);
    const activeProjectId = selectActiveProject(projectConfig, projects);

    const [resources, bundlePage, reviewPage, draftDetails] = await Promise.all([
      loadResources(api, projects, orgCommitState.state.ref.commit_id),
      api.listBundles({ limit: 200 }),
      api.listReviews({ limit: 200 }),
      Promise.all(
        draftPage.items
          .filter((draft) => draft.status !== "discarded" && draft.status !== "merged")
          .map((draft) => this.daemon.draft(draft.draft_id)),
      ),
    ]);
    const [bundleDetails, reviewDetails] = await Promise.all([
      Promise.all(bundlePage.items.map((bundle) => api.bundle(bundle.bundle_id))),
      Promise.all(reviewPage.items.map((review) => api.review(review.review_id))),
    ]);

    const commitRequests = new Map<
      string,
      Promise<PublicSchema<"CommitPayload">>
    >();
    const loadCommit = (commitId: string) => {
      const existing = commitRequests.get(commitId);
      if (existing) {
        return existing;
      }
      const request = api.commit(commitId);
      commitRequests.set(commitId, request);
      return request;
    };

    return {
      account: {
        userId: me.user.user_id,
        email: me.user.email,
        displayName: me.user.display_name,
        avatarUrl: me.user.avatar_url,
        capabilities: me.capabilities,
      },
      organization: {
        id: me.org.org_id,
        name: me.org.name,
      },
      projects,
      projectOrgSelections: projectStates.map((state) => state.orgSelection),
      orgRefCommitId: orgCommitState.state.ref.commit_id,
      activeProjectId,
      resources,
      drafts: draftDetails.map((draft) =>
        mapDaemonDraft(draft, projects, resources),
      ),
      bundles: bundleDetails.map(mapBundle),
      reviews: await Promise.all(
        reviewDetails.map((detail) =>
          mapReviewWithConflict(api, detail, projects, resources, loadCommit),
        ),
      ),
      runtime: { bootstrap, health, projectConfig, syncStatus, mcpStatus },
    };
  }

  async syncDraftProjection(
    draftId: string,
    projects: ProjectOption[],
    resources: AuthorityResource[],
  ): Promise<DraftRecord> {
    const retry = await this.daemon.retrySync({ channel: "drafts" });
    if (!retry.started) {
      throw new Error("daemon did not start the draft synchronization");
    }
    return mapDaemonDraft(await this.daemon.draft(draftId), projects, resources);
  }

  selectProject(projectId: string): Promise<DaemonProjectConfig> {
    return this.daemon.selectProject({ project_id: projectId });
  }

  async replaceProjectOrgSelection(
    selection: ProjectOrgSelectionState,
    resourceIds: readonly string[],
    resources: AuthorityResource[],
  ): Promise<{ selection: ProjectOrgSelectionState; refCommitId: string | null }> {
    if (!this.api) {
      throw new Error("Server API is unavailable");
    }
    const selected = resources.filter(
      (resource) => resource.scope === "Hub" && resourceIds.includes(resource.id),
    );
    const updated = await this.api.replaceProjectOrgSelection(
      selection.projectId,
      selection.revision,
      {
        rule_ids: selected.filter((resource) => resource.kind === "Rules").map((resource) => resource.id),
        context_ids: selected.filter((resource) => resource.kind === "Context").map((resource) => resource.id),
        workflow_ids: selected
          .filter((resource) => resource.kind === "Workflows")
          .map((resource) => resource.id),
      },
    );
    const [commitState] = await Promise.all([
      this.api.projectCommitState(selection.projectId),
      this.daemon.retrySync({ channel: "commits" }),
    ]);
    return {
      selection: mapProjectOrgSelection(updated),
      refCommitId: commitState.state.ref.commit_id,
    };
  }
}

function mapProjectOrgSelection(
  selection: PublicSchema<"ProjectOrgSelection">,
): ProjectOrgSelectionState {
  return {
    projectId: selection.project_id,
    ruleIds: selection.rules.map((resource) => resource.rule_id),
    contextIds: selection.context.map((resource) => resource.context_id),
    workflowIds: selection.workflows.map((resource) => resource.workflow_id),
    revision: selection.revision,
  };
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
    let response;
    try {
      response = await daemon.serverRequest({
        method,
        path: `${url.pathname}${url.search}`,
        headers,
        body: request.body === null ? null : await request.text(),
      });
    } catch (error) {
      const projectConfig = await daemon.projectConfig().catch(() => null);
      if (
        projectConfig
        && (!projectConfig.has_access_token || !projectConfig.has_refresh_token)
      ) {
        throw new AuthenticationRequiredError();
      }
      throw error;
    }
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
      body: detail.content.constraint,
      appliesWhen: detail.content.applies_when,
      tags: detail.content.tags,
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
    documentForBody(detail.context.path, detail.content),
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
      body: detail.content.description,
      appliesWhen: "",
      tags: [],
      steps: detail.content.steps.map((step) => ({
        ruleId: step.rule_id,
        body: step.body,
      })),
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
    documentForBody(detail.metaprompt.path, detail.content),
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
      applyDraftContent(document, op.create.content);
    } else if (op.update) {
      applyDraftContent(document, op.update.content);
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
    status:
      summary.status === "merged"
        ? "merged"
        : summary.status === "submitted" || summary.status === "conflicted"
          ? "in_review"
          : "editing",
    syncState: draftSyncState(detail),
    conflict: summary.conflict
      ? {
          baseCommitId: summary.conflict.base_commit_id,
          currentCommitId: summary.conflict.current_commit_id,
          detectedAt: formatDate(summary.conflict.detected_at),
        }
      : null,
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

export function mapReview(
  detail: PublicSchema<"ReviewDetail">,
  projects: ProjectOption[] = [],
  resources: AuthorityResource[] = [],
  baseCommit: PublicSchema<"CommitPayload"> | null = null,
): ReviewRecord {
  return {
    id: detail.review.review_id,
    draftId: detail.review.draft_id,
    authorId: detail.review.author.user_id,
    title: detail.review.title,
    author:
      detail.review.author.display_name ?? detail.review.author.email,
    status: detail.review.status,
    version: detail.review.version,
    draftVersion: detail.draft.version,
    operations: detail.operations.map((operation) => ({
      action: operation.action,
      resource: operation.resource,
      content: operation.content ?? null,
      newPath: operation.new_path ?? null,
    })),
    conflict: detail.conflict
      ? {
          baseCommitId: detail.conflict.base_commit_id,
          currentCommitId: detail.conflict.current_commit_id,
          detectedAt: formatDate(detail.conflict.detected_at),
          baseContent: null,
          currentContent: null,
        }
      : null,
    change: mapReviewChange(detail, projects, resources, baseCommit),
    createdAt: formatDate(detail.review.created_at),
    decisionNote: detail.review.decision_body,
    comments: detail.comments.map((comment) => ({
      id: comment.comment_id,
      author: comment.author.display_name ?? comment.author.email,
      body: comment.body,
      createdAt: formatDate(comment.created_at),
    })),
  };
}

export async function mapReviewWithConflict(
  api: ClumsiesApi,
  detail: PublicSchema<"ReviewDetail">,
  projects: ProjectOption[] = [],
  resources: AuthorityResource[] = [],
  loadCommit: (commitId: string) => Promise<PublicSchema<"CommitPayload">> =
    (commitId) => api.commit(commitId),
): Promise<ReviewRecord> {
  const baseCommitId = detail.draft.base_commit_id;
  const currentCommitId = detail.conflict?.current_commit_id ?? null;
  const baseCommitRequest = baseCommitId ? loadCommit(baseCommitId) : null;
  const currentCommitRequest = !currentCommitId
    ? null
    : currentCommitId === baseCommitId
      ? baseCommitRequest
      : loadCommit(currentCommitId);
  const [baseCommit, currentCommit] = await Promise.all([
    baseCommitRequest,
    currentCommitRequest,
  ]);
  const review = mapReview(detail, projects, resources, baseCommit);
  if (!review.conflict) {
    return review;
  }
  const conflict = hydrateReviewConflict(
    detail,
    review.conflict,
    baseCommit,
    currentCommit,
  );
  return { ...review, conflict };
}

function hydrateReviewConflict(
  detail: PublicSchema<"ReviewDetail">,
  conflict: ReviewConflict,
  base: PublicSchema<"CommitPayload"> | null,
  current: PublicSchema<"CommitPayload"> | null,
): ReviewConflict {
  return {
    ...conflict,
    baseContent: commitResourceContent(base, detail.draft.resource),
    currentContent: commitResourceContent(current, detail.draft.resource),
  };
}

function mapReviewChange(
  detail: PublicSchema<"ReviewDetail">,
  projects: ProjectOption[],
  resources: AuthorityResource[],
  baseCommit: PublicSchema<"CommitPayload"> | null,
): ReviewChange {
  const resourceRef = detail.draft.resource;
  const kind = memoryKind(resourceRef.kind);
  const baseResource = resourceRef.id
    ? resources.find((resource) => resource.id === resourceRef.id) ?? null
    : null;
  const commitDocument = commitResourceDocument(baseCommit, resourceRef);
  const baseDocument = commitDocument ??
    (baseResource ? cloneDocument(baseResource.document) : null);
  const beforeText = baseDocument ? documentText(kind, baseDocument) : null;
  let path = resourceRef.path ?? baseResource?.document.path ?? defaultPath(kind);
  let operation: ReviewChange["operation"] = "upsert";
  const document = baseDocument ?? blankDocumentForKind(kind, path);

  for (const change of detail.operations) {
    if (change.action === "create") {
      path = change.resource.path ?? path;
      if (change.content) {
        applyDraftContent(document, change.content);
      }
    } else if (change.action === "update") {
      if (change.content) {
        applyDraftContent(document, change.content);
      }
    } else if (change.action === "rename") {
      path = change.new_path ?? path;
    } else if (change.action === "delete") {
      operation = "delete";
    }
  }

  document.path = path;
  if (kind === "Context" || kind === "Metaprompt") {
    document.title = markdownTitle(document.body, titleFromPath(path));
  }
  const afterText = operation === "delete" ? null : documentText(kind, document);

  return {
    baseCommitId: detail.draft.base_commit_id,
    baseResourceId: resourceRef.id,
    scope: resourceRef.scope === "org" ? "Hub" : "Project",
    projectId: detail.draft.project_id,
    projectName:
      baseResource?.projectName ??
      projects.find((project) => project.id === detail.draft.project_id)?.name ??
      null,
    kind,
    operation,
    document,
    beforeText,
    afterText,
  };
}

function commitResourceDocument(
  payload: PublicSchema<"CommitPayload"> | null,
  resource: PublicSchema<"DraftResourceRef">,
): MemoryDocument | null {
  if (!payload) {
    return null;
  }
  const entry = payload.tree.entries.find((candidate) =>
    resource.id
      ? candidate.id === resource.id
      : candidate.path === resource.path && candidate.type === resource.kind,
  );
  if (!entry) {
    return null;
  }
  const blob = payload.blobs.find((candidate) => candidate.blob_id === entry.blob_id);
  return blob
    ? documentFromBlob(
        memoryKind(resource.kind),
        entry.path ?? resource.path ?? defaultPath(memoryKind(resource.kind)),
        blob.content,
      )
    : null;
}

function commitResourceContent(
  payload: PublicSchema<"CommitPayload"> | null,
  resource: PublicSchema<"DraftResourceRef">,
): string | null {
  const document = commitResourceDocument(payload, resource);
  return document ? documentText(memoryKind(resource.kind), document) : null;
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

  const content = draftContentForDocument(draft.kind, draft.document);
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
            content,
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
      op: { update: { id: target, content } },
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

function blankDocumentForKind(kind: MemoryKind, path: string): MemoryDocument {
  return {
    title: titleFromPath(path),
    path,
    body: "",
    appliesWhen: "",
    tags: [],
    steps: [],
  };
}

function applyDraftContent(
  document: MemoryDocument,
  content: DraftResourceContent,
): void {
  if (content.kind === "context" || content.kind === "metaprompt") {
    document.body = content.content;
    document.title = markdownTitle(content.content, titleFromPath(document.path));
    return;
  }
  if (content.kind === "rule") {
    document.title = content.name ?? document.title;
    document.appliesWhen = content.applies_when ?? document.appliesWhen;
    document.body = content.constraint;
    document.tags = content.tags ? [...content.tags] : document.tags;
    return;
  }
  document.title = content.name ?? document.title;
  document.body = content.description;
  document.steps = content.steps.map((step) => ({
    ruleId: step.rule_id,
    body: step.body,
  }));
}

export function draftContentForDocument(
  kind: MemoryKind,
  document: MemoryDocument,
  bodyOverride?: string,
): DraftResourceContent {
  const body = bodyOverride ?? document.body;
  if (kind === "Rules") {
    return {
      kind: "rule",
      name: document.title,
      applies_when: document.appliesWhen,
      constraint: body,
      tags: [...document.tags],
    };
  }
  if (kind === "Workflows") {
    return {
      kind: "workflow",
      name: document.title,
      description: body,
      steps: document.steps.map((step) => ({
        rule_id: step.ruleId,
        body: step.body,
      })),
    };
  }
  return {
    kind: kind === "Metaprompt" ? "metaprompt" : "context",
    content: body,
  };
}

function documentFromBlob(
  kind: MemoryKind,
  path: string,
  blob: string,
): MemoryDocument {
  if (kind === "Context" || kind === "Metaprompt") {
    return documentForBody(path, blob);
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(blob);
  } catch {
    throw new Error(`${kind} commit blob is not valid JSON`);
  }
  if (!isObject(decoded) || !isObject(decoded.content)) {
    throw new Error(`${kind} commit blob has no structured content`);
  }

  if (kind === "Rules") {
    const content = decoded.content;
    if (
      decoded.format !== "clumsies.rule.v1"
      || typeof content.name !== "string"
      || typeof content.applies_when !== "string"
      || typeof content.constraint !== "string"
      || !isStringArray(content.tags)
    ) {
      throw new Error("Rule commit blob does not match clumsies.rule.v1");
    }
    return {
      title: content.name,
      path,
      body: content.constraint,
      appliesWhen: content.applies_when,
      tags: [...content.tags],
      steps: [],
    };
  }

  const content = decoded.content;
  if (
    decoded.format !== "clumsies.workflow.v1"
    || typeof content.name !== "string"
    || typeof content.description !== "string"
    || !Array.isArray(content.steps)
  ) {
    throw new Error("Workflow commit blob does not match clumsies.workflow.v1");
  }
  const steps = content.steps.map((step) => {
    if (
      !isObject(step)
      || typeof step.order !== "number"
      || (step.rule_id !== null && typeof step.rule_id !== "string")
      || (step.body !== null && typeof step.body !== "string")
    ) {
      throw new Error("Workflow commit blob contains an invalid step");
    }
    return {
      order: step.order,
      ruleId: step.rule_id,
      body: step.body,
    };
  });
  steps.sort((left, right) => left.order - right.order);
  return {
    title: content.name,
    path,
    body: content.description,
    appliesWhen: "",
    tags: [],
    steps: steps.map(({ ruleId, body }) => ({ ruleId, body })),
  };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
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
    return "workflow/untitled";
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
