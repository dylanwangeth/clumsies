import { describe, expect, test } from "bun:test";
import {
  AuthenticationRequiredError,
  createDaemonFetch,
  daemonOperationsForDraft,
  DesktopBackend,
  mapReviewWithConflict,
  syncStateForDaemonDraft,
} from "../src/backend";
import type {
  ClumsiesApi,
  DaemonApiClient,
  PublicSchema,
} from "@clumsies/api-client";
import {
  createBlankDraft,
  createDraftFromResource,
  type AuthorityResource,
} from "../src/model";

const resource: AuthorityResource = {
  id: "ctx_existing",
  scope: "Project",
  projectId: "prj_test",
  projectName: "Test",
  kind: "Context",
  version: 3,
  refCommitId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  contentHash: "hash",
  updatedAt: "2026-07-13",
  document: {
    title: "Existing",
    path: "context/existing.md",
    body: "# Existing",
    appliesWhen: "",
    tags: [],
    steps: [],
  },
};

describe("Desktop backend mapping", () => {
  test("routes typed Server requests through daemon without an authorization header", async () => {
    const calls: unknown[] = [];
    const daemon = {
      serverRequest: async (request: unknown) => {
        calls.push(request);
        return {
          status: 200,
          headers: { "content-type": "application/json", etag: '"commit_1"' },
          body: '{"ok":true}',
        };
      },
    } as DaemonApiClient;

    const response = await createDaemonFetch(daemon)(
      "https://server.example/api/v1/projects?limit=20",
      {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "If-Match": '"commit_0"',
        },
        body: '{"name":"Koal"}',
      },
    );

    expect(calls).toEqual([{
      method: "POST",
      path: "/api/v1/projects?limit=20",
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        "if-match": '"commit_0"',
      },
      body: '{"name":"Koal"}',
    }]);
    expect(response.status).toBe(200);
    expect(response.headers.get("etag")).toBe('"commit_1"');
    expect(await response.json()).toEqual({ ok: true });
  });

  test("maps a cleared daemon session directly to sign-in", async () => {
    const daemon = {
      serverRequest: async () => {
        throw new Error("Server token refresh failed");
      },
      projectConfig: async () => ({
        server_url: "http://127.0.0.1:18080",
        project_id: "prj_test",
        has_access_token: false,
        has_refresh_token: false,
        ready: false,
        missing_fields: ["access_token"],
      }),
    } as DaemonApiClient;

    await expect(
      createDaemonFetch(daemon)("http://127.0.0.1:18080/api/v1/me"),
    ).rejects.toBeInstanceOf(AuthenticationRequiredError);
  });

  test("writes repeated new-resource edits to one local draft", () => {
    const draft = createBlankDraft(
      "Project",
      "Context",
      "prj_test",
      "Test",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    draft.document.path = "context/new.md";
    draft.document.body = "# First";

    expect(daemonOperationsForDraft(draft, null)).toEqual([
      {
        project_id: "prj_test",
        scope: "project",
        draft_id: null,
        base_commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resource: "context",
        op: {
          create: {
            path: "context/new.md",
            content: { kind: "context", content: "# First" },
          },
        },
        source: "desktop",
      },
    ]);

    draft.localId = "draft_local";
    draft.document.body = "# Second";
    expect(daemonOperationsForDraft(draft, null)).toEqual([
      {
        project_id: "prj_test",
        scope: "project",
        draft_id: "draft_local",
        base_commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resource: "context",
        op: {
          create: {
            path: "context/new.md",
            content: { kind: "context", content: "# Second" },
          },
        },
        source: "desktop",
      },
    ]);
  });

  test("preserves rename and content updates for an existing resource", () => {
    const draft = createDraftFromResource(resource);
    draft.localId = "draft_local";
    draft.document.path = "context/renamed.md";
    draft.document.body = "# Updated";

    expect(daemonOperationsForDraft(draft, resource)).toEqual([
      {
        project_id: "prj_test",
        scope: "project",
        draft_id: "draft_local",
        base_commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resource: "context",
        op: {
          rename: { id: "ctx_existing", new_path: "context/renamed.md" },
        },
        source: "desktop",
      },
      {
        project_id: "prj_test",
        scope: "project",
        draft_id: "draft_local",
        base_commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resource: "context",
        op: {
          update: {
            id: "ctx_existing",
            content: { kind: "context", content: "# Updated" },
          },
        },
        source: "desktop",
      },
    ]);
  });

  test("serializes structured Rule and Workflow drafts without flattening fields", () => {
    const ruleDraft = createBlankDraft(
      "Project",
      "Rules",
      "prj_test",
      "Test",
    );
    ruleDraft.document.path = "rules/coding";
    ruleDraft.document.title = "Coding discipline";
    ruleDraft.document.appliesWhen = "While changing production code";
    ruleDraft.document.body = "Run focused tests.";
    ruleDraft.document.tags = ["coding", "quality"];
    expect(daemonOperationsForDraft(ruleDraft, null)[0]?.op.create?.content).toEqual({
      kind: "rule",
      name: "Coding discipline",
      applies_when: "While changing production code",
      constraint: "Run focused tests.",
      tags: ["coding", "quality"],
    });

    const workflowDraft = createBlankDraft(
      "Project",
      "Workflows",
      "prj_test",
      "Test",
    );
    workflowDraft.document.path = "workflow/coding";
    workflowDraft.document.title = "Coding workflow";
    workflowDraft.document.body = "Prepare a production change.";
    workflowDraft.document.steps = [
      { ruleId: "rul_coding", body: null },
      { ruleId: null, body: "Summarize verification evidence." },
    ];
    expect(daemonOperationsForDraft(workflowDraft, null)[0]?.op.create?.content).toEqual({
      kind: "workflow",
      name: "Coding workflow",
      description: "Prepare a production change.",
      steps: [
        { rule_id: "rul_coding", body: null },
        { rule_id: null, body: "Summarize verification evidence." },
      ],
    });
  });

  test("uses daemon operation status instead of optimistic success", () => {
    const detail = {
      draft: {
        draft_id: "draft_local",
        project_id: "prj_test",
        server_draft_id: null,
        server_version: 0,
        base_commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        scope: "project" as const,
        resource_kind: "context" as const,
        target_id: null,
        path: "context/new.md",
        status: "open" as const,
        created_at: "2026-07-13T00:00:00Z",
        updated_at: "2026-07-13T00:00:00Z",
        pending_operation_count: 0,
        failed_operation_count: 1,
      },
      operations: [
        {
          local_operation_id: "op_failed",
          resource_kind: "context" as const,
          operation: {
            create: {
              path: "context/new.md",
              content: { kind: "context", content: "# New" },
            },
          },
          source: "desktop" as const,
          sync_status: "failed" as const,
          last_error: "network down",
          created_at: "2026-07-13T00:00:00Z",
          updated_at: "2026-07-13T00:00:00Z",
        },
      ],
    };

    expect(syncStateForDaemonDraft(detail)).toBe("failed");
  });

  test("builds a review change without the review author's local draft", async () => {
    const baseCommitId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const detail = {
      review: {
        review_id: "rev_teammate",
        project_id: "prj_test",
        draft_id: "drf_teammate",
        author: {
          user_id: "usr_teammate",
          email: "teammate@example.com",
          display_name: "Teammate",
        },
        title: "Update shared context",
        description: "",
        status: "open",
        version: 2,
        decision_body: null,
        created_at: "2026-07-15T00:00:00Z",
        updated_at: "2026-07-15T00:01:00Z",
      },
      draft: {
        draft_id: "drf_teammate",
        project_id: "prj_test",
        base_commit_id: baseCommitId,
        author: {
          user_id: "usr_teammate",
          email: "teammate@example.com",
          display_name: "Teammate",
        },
        title: "Update shared context",
        description: "",
        resource: {
          scope: "project",
          kind: "context",
          id: "ctx_existing",
          path: "context/existing.md",
        },
        status: "submitted",
        version: 3,
        created_at: "2026-07-15T00:00:00Z",
        updated_at: "2026-07-15T00:01:00Z",
      },
      operations: [
        {
          operation_id: "dop_teammate_rename",
          action: "rename",
          resource: {
            scope: "project",
            kind: "context",
            id: "ctx_existing",
            path: "context/existing.md",
          },
          content: null,
          new_path: "context/renamed.md",
          created_at: "2026-07-15T00:00:30Z",
        },
        {
          operation_id: "dop_teammate_update",
          action: "update",
          resource: {
            scope: "project",
            kind: "context",
            id: "ctx_existing",
            path: "context/existing.md",
          },
          content: { kind: "context", content: "# Shared update" },
          new_path: null,
          created_at: "2026-07-15T00:01:00Z",
        },
      ],
      comments: [],
      conflict: null,
    } as PublicSchema<"ReviewDetail">;
    const api = {
      commit: async () => ({
        commit: {
          commit_id: baseCommitId,
          scope: "project",
          org_id: "org_test",
          project_id: "prj_test",
          tree_id: "tree_base",
          parent_commit_id: null,
          version: 1,
          created_at: "2026-07-15T00:00:00Z",
        },
        tree: {
          tree_id: "tree_base",
          entries: [{
            id: "ctx_existing",
            type: "context",
            scope: "project",
            project_id: "prj_test",
            path: "context/existing.md",
            blob_id: "blob_base",
            source: "project",
          }],
        },
        blobs: [{ blob_id: "blob_base", content: "# Existing" }],
        project_org_selection: null,
      }),
    } as ClumsiesApi;

    const review = await mapReviewWithConflict(
      api,
      detail,
      [{ id: "prj_test", name: "Test", refCommitId: baseCommitId }],
      [],
    );

    expect(review.authorId).toBe("usr_teammate");
    expect(review.change).toMatchObject({
      baseCommitId,
      baseResourceId: "ctx_existing",
      projectId: "prj_test",
      projectName: "Test",
      kind: "Context",
      beforeText: "# Existing",
      afterText: "# Shared update",
      document: { path: "context/renamed.md" },
    });
  });

  test("hydrates a conflicted review from its base and current commits", async () => {
    const baseCommitId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const currentCommitId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const detail = {
      review: {
        review_id: "rev_conflict",
        project_id: "prj_test",
        draft_id: "drf_conflict",
        author: { user_id: "usr_author", email: "author@example.com", display_name: "Author" },
        title: "Update conflict handling",
        description: "",
        status: "approved",
        version: 4,
        decision_body: "Approved after conflict resolution.",
        created_at: "2026-07-15T00:00:00Z",
        updated_at: "2026-07-15T00:02:00Z",
      },
      draft: {
        draft_id: "drf_conflict",
        project_id: "prj_test",
        base_commit_id: baseCommitId,
        author: { user_id: "usr_author", email: "author@example.com", display_name: "Author" },
        title: "Update conflict handling",
        description: "",
        resource: {
          scope: "project",
          kind: "context",
          id: "ctx_existing",
          path: "context/existing.md",
        },
        status: "conflicted",
        version: 3,
        created_at: "2026-07-15T00:00:00Z",
        updated_at: "2026-07-15T00:02:00Z",
      },
      operations: [{
        operation_id: "dop_conflict",
        action: "update",
        resource: {
          scope: "project",
          kind: "context",
          id: "ctx_existing",
          path: "context/existing.md",
        },
        content: { kind: "context", content: "# Draft" },
        new_path: null,
        created_at: "2026-07-15T00:01:00Z",
      }],
      comments: [],
      conflict: {
        base_commit_id: baseCommitId,
        current_commit_id: currentCommitId,
        detected_at: "2026-07-15T00:02:00Z",
      },
    } as PublicSchema<"ReviewDetail">;
    const api = {
      commit: async (commitId: string) => ({
        commit: {
          commit_id: commitId,
          scope: "project",
          org_id: "org_test",
          project_id: "prj_test",
          tree_id: `tree_${commitId[0]}`,
          parent_commit_id: null,
          version: commitId === baseCommitId ? 1 : 2,
          created_at: "2026-07-15T00:00:00Z",
        },
        tree: {
          tree_id: `tree_${commitId[0]}`,
          entries: [{
            id: "ctx_existing",
            type: "context",
            scope: "project",
            project_id: "prj_test",
            path: "context/existing.md",
            blob_id: `blob_${commitId[0]}`,
            source: "project",
          }],
        },
        blobs: [{
          blob_id: `blob_${commitId[0]}`,
          content: commitId === baseCommitId ? "# Base" : "# Current",
        }],
        project_org_selection: null,
      }),
    } as ClumsiesApi;

    const review = await mapReviewWithConflict(api, detail);

    expect(review.version).toBe(4);
    expect(review.draftVersion).toBe(3);
    expect(review.operations?.[0]?.content).toEqual({
      kind: "context",
      content: "# Draft",
    });
    expect(review.decisionNote).toBe("Approved after conflict resolution.");
    expect(review.conflict).toEqual({
      baseCommitId,
      currentCommitId,
      detectedAt: "2026-07-15",
      baseContent: "# Base",
      currentContent: "# Current",
    });
  });

  test("synchronizes and reads the daemon projection before unlocking a rejected draft", async () => {
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const detail = {
      draft: {
        draft_id: "draft_local",
        project_id: "prj_test",
        server_draft_id: "drf_server",
        server_version: 4,
        base_commit_id: null,
        scope: "project" as const,
        resource_kind: "context" as const,
        target_id: "ctx_existing",
        path: "context/existing.md",
        conflict: null,
        status: "open" as const,
        created_at: "2026-07-15T00:00:00Z",
        updated_at: "2026-07-15T00:02:00Z",
        pending_operation_count: 0,
        failed_operation_count: 0,
      },
      operations: [],
    } as DaemonDraftDetail;
    const backend = new DesktopBackend(async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "retry_daemon_sync") {
        return { retry_id: "retry_test", started: true } as T;
      }
      if (command === "read_daemon_draft") {
        return detail as T;
      }
      throw new Error(`Unexpected command: ${command}`);
    });

    const projected = await backend.syncDraftProjection(
      "draft_local",
      [{ id: "prj_test", name: "Test", refCommitId: null }],
      [resource],
    );

    expect(calls).toEqual([
      { command: "retry_daemon_sync", args: { request: { channel: "drafts" } } },
      { command: "read_daemon_draft", args: { draftId: "draft_local" } },
    ]);
    expect(projected.status).toBe("editing");
    expect(projected.serverVersion).toBe(4);
    expect(projected.document.body).toBe("# Existing");
  });

  test("maps a merged daemon draft to the terminal Desktop state", async () => {
    const detail = {
      draft: {
        draft_id: "draft_merged",
        project_id: "prj_test",
        server_draft_id: "drf_server",
        server_version: 5,
        base_commit_id: null,
        scope: "project" as const,
        resource_kind: "context" as const,
        target_id: "ctx_existing",
        path: "context/existing.md",
        conflict: null,
        status: "merged" as const,
        created_at: "2026-07-15T00:00:00Z",
        updated_at: "2026-07-15T00:03:00Z",
        pending_operation_count: 0,
        failed_operation_count: 0,
      },
      operations: [],
    } as DaemonDraftDetail;
    const backend = new DesktopBackend(async <T>(command: string) => {
      if (command === "retry_daemon_sync") {
        return { retry_id: "retry_merged", started: true } as T;
      }
      if (command === "read_daemon_draft") {
        return detail as T;
      }
      throw new Error(`Unexpected command: ${command}`);
    });

    const projected = await backend.syncDraftProjection(
      "draft_merged",
      [{ id: "prj_test", name: "Test", refCommitId: null }],
      [resource],
    );

    expect(projected.status).toBe("merged");
    expect(projected.syncState).toBe("local");
  });

  test("switches the daemon project without replacing credentials and publishes Hub selection", async () => {
    const daemonCalls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const backend = new DesktopBackend(async <T>(command: string, args?: Record<string, unknown>) => {
      daemonCalls.push({ command, args });
      if (command === "select_daemon_project") {
        return {
          server_url: "https://clumsies.example.com",
          project_id: "prj_test",
          has_access_token: true,
          has_refresh_token: true,
          ready: true,
          missing_fields: [],
        } as T;
      }
      if (command === "retry_daemon_sync") {
        return { retry_id: "retry_commits", started: true } as T;
      }
      throw new Error(`Unexpected command: ${command}`);
    });
    const apiCalls: unknown[] = [];
    backend.api = {
      replaceProjectOrgSelection: async (
        projectId: string,
        revision: number,
        request: unknown,
      ) => {
        apiCalls.push({ projectId, revision, request });
        return {
          project_id: projectId,
          revision: revision + 1,
          rules: [],
          context: [{
            context_id: "ctx_hub",
            scope: "org",
            project_id: null,
            kind: "file",
            path: "context/hub.md",
            content_hash: "hash",
            size: 10,
            updated_at: "2026-07-15T00:00:00Z",
          }],
          workflows: [],
        };
      },
      projectCommitState: async () => ({
        state: { ref: { commit_id: "commit_next" } },
      }),
    } as unknown as ClumsiesApi;
    const hubContext: AuthorityResource = {
      ...resource,
      id: "ctx_hub",
      scope: "Hub",
      projectId: null,
      projectName: null,
      document: { ...resource.document, path: "context/hub.md" },
    };

    await backend.selectProject("prj_test");
    const result = await backend.replaceProjectOrgSelection(
      {
        projectId: "prj_test",
        ruleIds: [],
        contextIds: [],
        workflowIds: [],
        revision: 2,
      },
      [hubContext.id],
      [hubContext],
    );

    expect(daemonCalls).toEqual([
      {
        command: "select_daemon_project",
        args: { request: { project_id: "prj_test" } },
      },
      {
        command: "retry_daemon_sync",
        args: { request: { channel: "commits" } },
      },
    ]);
    expect(apiCalls).toEqual([{
      projectId: "prj_test",
      revision: 2,
      request: {
        rule_ids: [],
        context_ids: ["ctx_hub"],
        workflow_ids: [],
      },
    }]);
    expect(result.selection).toEqual({
      projectId: "prj_test",
      ruleIds: [],
      contextIds: ["ctx_hub"],
      workflowIds: [],
      revision: 3,
    });
    expect(result.refCommitId).toBe("commit_next");
  });
});
