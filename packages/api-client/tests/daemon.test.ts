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
    await client.install();
    await client.start();
    await client.restart();
    await client.stop();
    await client.health();
    await client.projectConfig();
    await client.replaceProjectConfig({
      server_url: "http://127.0.0.1:8080",
      project_id: "prj_test",
      access_token: null,
      refresh_token: null,
    });
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
          body: "# New",
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
      "install_daemon_launch_agent",
      "start_daemon_launch_agent",
      "restart_daemon_launch_agent",
      "stop_daemon_launch_agent",
      "read_daemon_health",
      "read_daemon_project_config",
      "replace_daemon_project_config",
      "read_daemon_sync_status",
      "retry_daemon_sync",
      "read_daemon_mcp_status",
      "list_daemon_drafts",
      "read_daemon_draft",
      "store_daemon_draft_operation",
      "proxy_server_request",
    ]);
    expect(calls[7]?.args).toEqual({
      request: {
        server_url: "http://127.0.0.1:8080",
        project_id: "prj_test",
        access_token: null,
        refresh_token: null,
      },
    });
    expect(calls[11]?.args).toEqual({
      query: { resource: "context", limit: 20 },
    });
    expect(calls[12]?.args).toEqual({ draftId: "draft_test" });
  });
});
