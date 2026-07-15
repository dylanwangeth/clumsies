import { describe, expect, test } from "bun:test";
import {
  createPublicApiClient,
  ClumsiesApi,
} from "../src/index";

describe("Clumsies API", () => {
  test("maps the complete public contract to HTTP requests", async () => {
    const requests: string[] = [];
    let mergeIfMatch: string | null = null;
    const fetch: typeof globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      requests.push(`${request.method} ${url.pathname}`);
      if (url.pathname.endsWith("/merges") || url.pathname.endsWith("/conflict-resolutions")) {
        mergeIfMatch = request.headers.get("if-match");
      }
      return new Response("{}", {
        status: 200,
        headers: {
          "content-type": "application/json",
          etag: '"ref-none"',
        },
      });
    };
    const api = new ClumsiesApi(
      createPublicApiClient({ baseUrl: "http://server.test", fetch }),
    );

    await api.exchangeToken({ grant_type: "authorization_code", code: "code" });
    await api.revokeSession();
    await api.me();
    await api.listProjects();
    await api.createProject({ org_id: "org", name: "Project" });
    await api.project("project");
    await api.updateProject("project", 1, { name: "Updated" });
    await api.deleteProject("project", 2);
    await api.listBundles();
    await api.createBundle({ owner_user_id: "user", name: "Bundle" });
    await api.bundle("bundle");
    await api.updateBundle("bundle", 1, { name: "Updated" });
    await api.deleteBundle("bundle", 2);
    await api.listOrgRules();
    await api.orgRule("rule");
    await api.listOrgContext();
    await api.orgContext("context");
    await api.listOrgWorkflows();
    await api.orgWorkflow("workflow");
    await api.orgMetaprompt();
    await api.listProjectRules("project");
    await api.projectRule("project", "rule");
    await api.listProjectContext("project");
    await api.projectContext("project", "context");
    await api.listProjectWorkflows("project");
    await api.projectWorkflow("project", "workflow");
    await api.projectMetaprompt("project");
    await api.projectOrgSelection("project");
    await api.replaceProjectOrgSelection("project", 1, {});
    await api.listDrafts();
    await api.createDraft({
      daemon_installation_id: "daemon",
      project_id: "project",
      title: "Draft",
      resource: { scope: "project", kind: "context", id: null, path: "context/new.md" },
    });
    await api.draft("draft");
    await api.updateDraft("draft", 1, { title: "Updated" });
    await api.discardDraft("draft", 2);
    await api.appendDraftOperation("draft", 1, {
      action: "create",
      resource: { scope: "project", kind: "context", id: null, path: "context/new.md" },
      body: "# New",
    });
    await api.listDraftEvents();
    await api.createDraftOperationBatch({
      daemon_installation_id: "daemon",
      operations: [],
    });
    await api.listReviews();
    await api.createReview({ draft_id: "draft", expected_draft_version: 1 });
    await api.review("review");
    await api.listReviewComments("review");
    await api.createReviewComment("review", { body: "Comment" });
    await api.createReviewDecision("review", {
      decision: "approved",
      expected_review_version: 1,
    });
    await api.createReviewSubmission("review", {
      expected_review_version: 2,
      expected_draft_version: 3,
    });
    await api.createReviewConflictResolution("review", '"commit"', {
      expected_review_version: 2,
      expected_draft_version: 3,
      operations: [{
        action: "update",
        resource: { scope: "project", kind: "context", id: "context", path: null },
        base_hash: null,
        body: "Resolved",
      }],
    });
    await api.createReviewMerge("review", '"ref-none"', {
      expected_review_version: 2,
    });
    await api.listOrgCommits();
    await api.orgCommitState();
    await api.listProjectCommits("project");
    await api.projectCommitState("project");
    await api.commit("commit");

    expect(requests).toEqual([
      "POST /api/v1/auth/token",
      "DELETE /api/v1/auth/session",
      "GET /api/v1/me",
      "GET /api/v1/projects",
      "POST /api/v1/projects",
      "GET /api/v1/projects/project",
      "PATCH /api/v1/projects/project",
      "DELETE /api/v1/projects/project",
      "GET /api/v1/me/bundles",
      "POST /api/v1/me/bundles",
      "GET /api/v1/me/bundles/bundle",
      "PATCH /api/v1/me/bundles/bundle",
      "DELETE /api/v1/me/bundles/bundle",
      "GET /api/v1/org/rules",
      "GET /api/v1/org/rules/rule",
      "GET /api/v1/org/context",
      "GET /api/v1/org/context/context",
      "GET /api/v1/org/workflows",
      "GET /api/v1/org/workflows/workflow",
      "GET /api/v1/org/metaprompt",
      "GET /api/v1/projects/project/rules",
      "GET /api/v1/projects/project/rules/rule",
      "GET /api/v1/projects/project/context",
      "GET /api/v1/projects/project/context/context",
      "GET /api/v1/projects/project/workflows",
      "GET /api/v1/projects/project/workflows/workflow",
      "GET /api/v1/projects/project/metaprompt",
      "GET /api/v1/projects/project/org-selections",
      "PUT /api/v1/projects/project/org-selections",
      "GET /api/v1/drafts",
      "POST /api/v1/drafts",
      "GET /api/v1/drafts/draft",
      "PATCH /api/v1/drafts/draft",
      "DELETE /api/v1/drafts/draft",
      "POST /api/v1/drafts/draft/operations",
      "GET /api/v1/draft-events",
      "POST /api/v1/draft-operation-batches",
      "GET /api/v1/reviews",
      "POST /api/v1/reviews",
      "GET /api/v1/reviews/review",
      "GET /api/v1/reviews/review/comments",
      "POST /api/v1/reviews/review/comments",
      "POST /api/v1/reviews/review/decisions",
      "POST /api/v1/reviews/review/submissions",
      "POST /api/v1/reviews/review/conflict-resolutions",
      "POST /api/v1/reviews/review/merges",
      "GET /api/v1/org/commits",
      "GET /api/v1/org/commit-state",
      "GET /api/v1/projects/project/commits",
      "GET /api/v1/projects/project/commit-state",
      "GET /api/v1/commits/commit",
    ]);
    expect(mergeIfMatch).toBe('"ref-none"');
  });
});
