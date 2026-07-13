import type { components } from "@clumsies/api-contract/public";
import type { PublicApiClient } from "./index";

type Schema<Name extends keyof components["schemas"]> =
  components["schemas"][Name];

export type PageQuery = {
  limit?: number;
  cursor?: string;
};

export type ProjectPageQuery = PageQuery & {
  project_id?: string;
};

export type DraftEventQuery = {
  after_cursor?: string;
  limit?: number;
};

export type OrgCommitStateQuery = {
  local_commit_id?: string;
};

export type ProjectCommitStateQuery = {
  local_commit_id?: string;
};

export type CommitStateResult = {
  state: Schema<"CommitStateResponse">;
  etag: string;
};

type ApiResult<T> = {
  data?: T;
  error?: unknown;
  response: Response;
};

export class ClumsiesApiError extends Error {
  readonly status: number;
  readonly details: unknown;

  constructor(status: number, details: unknown) {
    super(apiErrorMessage(status, details));
    this.name = "ClumsiesApiError";
    this.status = status;
    this.details = details;
  }
}

export class ClumsiesApi {
  readonly raw: PublicApiClient;

  constructor(client: PublicApiClient) {
    this.raw = client;
  }

  exchangeToken(request: Schema<"TokenRequest">) {
    return unwrap(
      this.raw.POST("/api/v1/auth/token", { body: request }),
    );
  }

  revokeSession() {
    return unwrap(this.raw.DELETE("/api/v1/auth/session"));
  }

  me() {
    return unwrap(this.raw.GET("/api/v1/me"));
  }

  listProjects(query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/projects", { params: { query } }),
    );
  }

  createProject(request: Schema<"CreateProjectRequest">) {
    return unwrap(this.raw.POST("/api/v1/projects", { body: request }));
  }

  project(projectId: string) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}", {
        params: { path: { project_id: projectId } },
      }),
    );
  }

  updateProject(
    projectId: string,
    revision: number,
    request: Schema<"UpdateProjectRequest">,
  ) {
    return unwrap(
      this.raw.PATCH("/api/v1/projects/{project_id}", {
        params: {
          path: { project_id: projectId },
          header: { "If-Match": String(revision) },
        },
        body: request,
      }),
    );
  }

  deleteProject(projectId: string, revision: number) {
    return unwrap(
      this.raw.DELETE("/api/v1/projects/{project_id}", {
        params: {
          path: { project_id: projectId },
          header: { "If-Match": String(revision) },
        },
      }),
    );
  }

  listBundles(query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/me/bundles", { params: { query } }),
    );
  }

  createBundle(request: Schema<"PersonalBundleRequest">) {
    return unwrap(this.raw.POST("/api/v1/me/bundles", { body: request }));
  }

  bundle(bundleId: string) {
    return unwrap(
      this.raw.GET("/api/v1/me/bundles/{bundle_id}", {
        params: { path: { bundle_id: bundleId } },
      }),
    );
  }

  updateBundle(
    bundleId: string,
    revision: number,
    request: Schema<"PersonalBundleUpdateRequest">,
  ) {
    return unwrap(
      this.raw.PATCH("/api/v1/me/bundles/{bundle_id}", {
        params: {
          path: { bundle_id: bundleId },
          header: { "If-Match": String(revision) },
        },
        body: request,
      }),
    );
  }

  deleteBundle(bundleId: string, revision: number) {
    return unwrap(
      this.raw.DELETE("/api/v1/me/bundles/{bundle_id}", {
        params: {
          path: { bundle_id: bundleId },
          header: { "If-Match": String(revision) },
        },
      }),
    );
  }

  listOrgRules(query: PageQuery = {}) {
    return unwrap(this.raw.GET("/api/v1/org/rules", { params: { query } }));
  }

  orgRule(ruleId: string) {
    return unwrap(
      this.raw.GET("/api/v1/org/rules/{rule_id}", {
        params: { path: { rule_id: ruleId } },
      }),
    );
  }

  listOrgContext(query: PageQuery = {}) {
    return unwrap(this.raw.GET("/api/v1/org/context", { params: { query } }));
  }

  orgContext(contextId: string) {
    return unwrap(
      this.raw.GET("/api/v1/org/context/{context_id}", {
        params: { path: { context_id: contextId } },
      }),
    );
  }

  listOrgWorkflows(query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/org/workflows", { params: { query } }),
    );
  }

  orgWorkflow(workflowId: string) {
    return unwrap(
      this.raw.GET("/api/v1/org/workflows/{workflow_id}", {
        params: { path: { workflow_id: workflowId } },
      }),
    );
  }

  orgMetaprompt() {
    return unwrap(this.raw.GET("/api/v1/org/metaprompt"));
  }

  listProjectRules(projectId: string, query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/rules", {
        params: { path: { project_id: projectId }, query },
      }),
    );
  }

  projectRule(projectId: string, ruleId: string) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/rules/{rule_id}", {
        params: { path: { project_id: projectId, rule_id: ruleId } },
      }),
    );
  }

  listProjectContext(projectId: string, query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/context", {
        params: { path: { project_id: projectId }, query },
      }),
    );
  }

  projectContext(projectId: string, contextId: string) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/context/{context_id}", {
        params: { path: { project_id: projectId, context_id: contextId } },
      }),
    );
  }

  listProjectWorkflows(projectId: string, query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/workflows", {
        params: { path: { project_id: projectId }, query },
      }),
    );
  }

  projectWorkflow(projectId: string, workflowId: string) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/workflows/{workflow_id}", {
        params: {
          path: { project_id: projectId, workflow_id: workflowId },
        },
      }),
    );
  }

  projectMetaprompt(projectId: string) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/metaprompt", {
        params: { path: { project_id: projectId } },
      }),
    );
  }

  projectOrgSelection(projectId: string) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/org-selections", {
        params: { path: { project_id: projectId } },
      }),
    );
  }

  replaceProjectOrgSelection(
    projectId: string,
    revision: number,
    request: Schema<"ReplaceProjectOrgSelectionRequest">,
  ) {
    return unwrap(
      this.raw.PUT("/api/v1/projects/{project_id}/org-selections", {
        params: {
          path: { project_id: projectId },
          header: { "If-Match": String(revision) },
        },
        body: request,
      }),
    );
  }

  listDrafts(query: ProjectPageQuery = {}) {
    return unwrap(this.raw.GET("/api/v1/drafts", { params: { query } }));
  }

  createDraft(request: Schema<"CreateDraftRequest">) {
    return unwrap(this.raw.POST("/api/v1/drafts", { body: request }));
  }

  draft(draftId: string) {
    return unwrap(
      this.raw.GET("/api/v1/drafts/{draft_id}", {
        params: { path: { draft_id: draftId } },
      }),
    );
  }

  updateDraft(
    draftId: string,
    version: number,
    request: Schema<"UpdateDraftRequest">,
  ) {
    return unwrap(
      this.raw.PATCH("/api/v1/drafts/{draft_id}", {
        params: {
          path: { draft_id: draftId },
          header: { "If-Match": String(version) },
        },
        body: request,
      }),
    );
  }

  discardDraft(draftId: string, version: number) {
    return unwrap(
      this.raw.DELETE("/api/v1/drafts/{draft_id}", {
        params: {
          path: { draft_id: draftId },
          header: { "If-Match": String(version) },
        },
      }),
    );
  }

  appendDraftOperation(
    draftId: string,
    version: number,
    request: Schema<"AppendDraftOperationRequest">,
  ) {
    return unwrap(
      this.raw.POST("/api/v1/drafts/{draft_id}/operations", {
        params: {
          path: { draft_id: draftId },
          header: { "If-Match": String(version) },
        },
        body: request,
      }),
    );
  }

  listDraftEvents(query: DraftEventQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/draft-events", { params: { query } }),
    );
  }

  createDraftOperationBatch(request: Schema<"DraftOperationBatchRequest">) {
    return unwrap(
      this.raw.POST("/api/v1/draft-operation-batches", { body: request }),
    );
  }

  listReviews(query: ProjectPageQuery = {}) {
    return unwrap(this.raw.GET("/api/v1/reviews", { params: { query } }));
  }

  createReview(request: Schema<"CreateReviewRequest">) {
    return unwrap(this.raw.POST("/api/v1/reviews", { body: request }));
  }

  review(reviewId: string) {
    return unwrap(
      this.raw.GET("/api/v1/reviews/{review_id}", {
        params: { path: { review_id: reviewId } },
      }),
    );
  }

  listReviewComments(reviewId: string, query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/reviews/{review_id}/comments", {
        params: { path: { review_id: reviewId }, query },
      }),
    );
  }

  createReviewComment(
    reviewId: string,
    request: Schema<"CreateReviewCommentRequest">,
  ) {
    return unwrap(
      this.raw.POST("/api/v1/reviews/{review_id}/comments", {
        params: { path: { review_id: reviewId } },
        body: request,
      }),
    );
  }

  createReviewDecision(
    reviewId: string,
    request: Schema<"CreateReviewDecisionRequest">,
  ) {
    return unwrap(
      this.raw.POST("/api/v1/reviews/{review_id}/decisions", {
        params: { path: { review_id: reviewId } },
        body: request,
      }),
    );
  }

  createReviewMerge(
    reviewId: string,
    refEtag: string,
    request: Schema<"CreateReviewMergeRequest">,
  ) {
    return unwrap(
      this.raw.POST("/api/v1/reviews/{review_id}/merges", {
        params: {
          path: { review_id: reviewId },
          header: { "If-Match": refEtag },
        },
        body: request,
      }),
    );
  }

  listOrgCommits(query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/org/commits", { params: { query } }),
    );
  }

  async orgCommitState(
    query: OrgCommitStateQuery = {},
  ): Promise<CommitStateResult> {
    return unwrapCommitState(
      await this.raw.GET("/api/v1/org/commit-state", {
        params: { query },
      }),
    );
  }

  listProjectCommits(projectId: string, query: PageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/projects/{project_id}/commits", {
        params: { path: { project_id: projectId }, query },
      }),
    );
  }

  async projectCommitState(
    projectId: string,
    query: ProjectCommitStateQuery = {},
  ): Promise<CommitStateResult> {
    return unwrapCommitState(
      await this.raw.GET("/api/v1/projects/{project_id}/commit-state", {
        params: { path: { project_id: projectId }, query },
      }),
    );
  }

  commit(commitId: string) {
    return unwrap(
      this.raw.GET("/api/v1/commits/{commit_id}", {
        params: { path: { commit_id: commitId } },
      }),
    );
  }
}

async function unwrap<T>(request: Promise<ApiResult<T>>): Promise<T> {
  const result = await request;
  if (result.data !== undefined) {
    return result.data;
  }
  throw new ClumsiesApiError(result.response.status, result.error);
}

function unwrapCommitState(
  result: ApiResult<Schema<"CommitStateResponse">>,
): CommitStateResult {
  if (result.data === undefined) {
    throw new ClumsiesApiError(result.response.status, result.error);
  }
  const etag = result.response.headers.get("etag");
  if (!etag) {
    throw new ClumsiesApiError(result.response.status, {
      error: { message: "Commit state response is missing ETag" },
    });
  }
  return { state: result.data, etag };
}

function apiErrorMessage(status: number, details: unknown): string {
  if (
    details &&
    typeof details === "object" &&
    "error" in details &&
    details.error &&
    typeof details.error === "object" &&
    "message" in details.error &&
    typeof details.error.message === "string"
  ) {
    return details.error.message;
  }
  return `Server request failed with status ${status}`;
}
