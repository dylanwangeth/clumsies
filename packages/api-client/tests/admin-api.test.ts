import { describe, expect, test } from "bun:test";
import {
  ClumsiesAdminApi,
  createAdminApiClient,
} from "../src/index";

describe("Clumsies Admin API", () => {
  test("maps the complete admin contract to HTTP requests", async () => {
    const requests: string[] = [];
    const ifMatch = new Map<string, string | null>();
    const fetch: typeof globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      const operation = `${request.method} ${url.pathname}`;
      requests.push(operation);
      ifMatch.set(operation, request.headers.get("if-match"));
      return new Response("{}", {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };
    const api = new ClumsiesAdminApi(
      createAdminApiClient({ baseUrl: "http://server.test", fetch }),
    );

    await api.org();
    await api.updateOrg(1, { name: "Clumsies Lab" });
    await api.listMembers();
    await api.createMember({ email: "member@example.com", role: "member" });
    await api.updateMember("user", 2, { role: "admin" });
    await api.deleteMember("user", 3);
    await api.listProjects();
    await api.listProjectMembers("project", { role: "member" });
    await api.createProjectMember("project", {
      user_id: "user",
      role: "member",
    });
    await api.updateProjectMember("project", "user", { role: "admin" });
    await api.deleteProjectMember("project", "user");
    await api.listTokens();
    await api.deleteToken("token");
    await api.listAuditEvents();
    await api.health();

    expect(requests).toEqual([
      "GET /api/v1/admin/org",
      "PATCH /api/v1/admin/org",
      "GET /api/v1/admin/members",
      "POST /api/v1/admin/members",
      "PATCH /api/v1/admin/members/user",
      "DELETE /api/v1/admin/members/user",
      "GET /api/v1/admin/projects",
      "GET /api/v1/admin/projects/project/members",
      "POST /api/v1/admin/projects/project/members",
      "PATCH /api/v1/admin/projects/project/members/user",
      "DELETE /api/v1/admin/projects/project/members/user",
      "GET /api/v1/admin/tokens",
      "DELETE /api/v1/admin/tokens/token",
      "GET /api/v1/admin/audit-events",
      "GET /api/v1/admin/health",
    ]);
    expect(ifMatch.get("PATCH /api/v1/admin/org")).toBe("1");
    expect(ifMatch.get("PATCH /api/v1/admin/members/user")).toBe("2");
    expect(ifMatch.get("DELETE /api/v1/admin/members/user")).toBe("3");
  });
});
