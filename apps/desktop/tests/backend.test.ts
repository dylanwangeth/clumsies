import { describe, expect, test } from "bun:test";
import {
  createDaemonFetch,
  daemonOperationsForDraft,
  syncStateForDaemonDraft,
} from "../src/backend";
import type { DaemonApiClient } from "@clumsies/api-client";
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
        op: { create: { path: "context/new.md", body: "# First" } },
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
        op: { create: { path: "context/new.md", body: "# Second" } },
        source: "desktop",
      },
    ]);
  });

  test("preserves rename and body updates for an existing resource", () => {
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
        op: { update: { id: "ctx_existing", body: "# Updated" } },
        source: "desktop",
      },
    ]);
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
            create: { path: "context/new.md", body: "# New" },
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
});
