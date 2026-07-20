import { describe, expect, test } from "bun:test";
import {
  createDaemonApiClient,
  type NativeInvoke,
} from "../src/index";

describe("daemon API client", () => {
  test("maps every typed method to its Tauri command", async () => {
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: NativeInvoke = async <T>(
      command: string,
      args?: Record<string, unknown>,
    ) => {
      calls.push({ command, args });
      return {} as T;
    };
    const client = createDaemonApiClient(invoke);

    await client.bootstrapStatus();
    await client.health();
    await client.projectConfig();
    await client.selectProject({ project_id: "prj_other" });
    await client.syncStatus();
    await client.retrySync({ channel: "all" });
    await client.mcpStatus();
    await client.listDrafts({ resource: "context", limit: 20 });
    await client.draft("draft_test");
    await client.storeDraftOperation({
      draft_id: null,
      project_id: "prj_test",
      scope: "project",
      resource: "context",
      op: {
        create: {
          path: "context/new.md",
          content: { kind: "context", content: "# New" },
        },
      },
      source: "desktop",
    });
    await client.serverRequest({
      method: "GET",
      path: "/api/v1/me",
      headers: { accept: "application/json" },
      body: null,
    });

    expect(calls.map((call) => call.command)).toEqual([
      "read_daemon_bootstrap_status",
      "read_daemon_health",
      "read_daemon_project_config",
      "select_daemon_project",
      "read_daemon_sync_status",
      "retry_daemon_sync",
      "read_daemon_mcp_status",
      "list_daemon_drafts",
      "read_daemon_draft",
      "store_daemon_draft_operation",
      "proxy_server_request",
    ]);
    expect(calls[3]?.args).toEqual({
      request: { project_id: "prj_other" },
    });
    expect(calls[7]?.args).toEqual({
      query: { resource: "context", limit: 20 },
    });
    expect(calls[8]?.args).toEqual({ draftId: "draft_test" });
  });
});
