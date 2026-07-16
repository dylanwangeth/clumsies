import { describe, expect, test } from "bun:test";
import {
  ClumsiesAdminApi,
  createAdminApiClient,
} from "../src/index";

describe("Clumsies Admin API", () => {
  test("maps the complete admin contract to HTTP requests", async () => {
    const requests: string[] = [];
    const ifMatch = new Map<string, string | null>();
    const csrf = new Map<string, string | null>();
    const fetch: typeof globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      const operation = `${request.method} ${url.pathname}`;
      requests.push(operation);
      ifMatch.set(operation, request.headers.get("if-match"));
      csrf.set(operation, request.headers.get("x-csrf-token"));
      return new Response("{}", {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };
    const api = new ClumsiesAdminApi(
      createAdminApiClient({
        baseUrl: "http://server.test",
        csrfToken: "admin-csrf",
        fetch,
      }),
    );

    await api.setup();
    await api.createSetupSession("setup-code");
    await api.replaceSetupConfiguration("csrf-token", {
      org_name: "Clumsies Lab",
      default_project_name: "Default",
      allowed_email_domains: ["example.com"],
    });
    await api.createSetupOidcAuthorization(
      "csrf-token",
      "http://127.0.0.1:1421/admin/setup/callback",
    );
    await api.session();
    await api.identityProvider();
    await api.org();
    await api.updateOrg(1, { name: "Clumsies Lab" });
    await api.listMembers();
    await api.createMember({ email: "member@example.com", role: "member" });
    await api.updateMember("user", 2, { role: "admin" });
    await api.deleteMember("user", 3);
    await api.listProjects();
    await api.createProject({ name: "Project", description: "Description" });
    await api.project("project");
    await api.updateProject("project", 4, { name: "Renamed" });
    await api.deleteProject("project", 5);
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
    await api.deleteSession();

    expect(requests).toEqual([
      "GET /api/v1/setup",
      "POST /api/v1/setup/sessions",
      "PUT /api/v1/setup/configuration",
      "POST /api/v1/setup/oidc-authorizations",
      "GET /api/v1/admin/session",
      "GET /api/v1/admin/identity-provider",
      "GET /api/v1/admin/org",
      "PATCH /api/v1/admin/org",
      "GET /api/v1/admin/members",
      "POST /api/v1/admin/members",
      "PATCH /api/v1/admin/members/user",
      "DELETE /api/v1/admin/members/user",
      "GET /api/v1/admin/projects",
      "POST /api/v1/admin/projects",
      "GET /api/v1/admin/projects/project",
      "PATCH /api/v1/admin/projects/project",
      "DELETE /api/v1/admin/projects/project",
      "GET /api/v1/admin/projects/project/members",
      "POST /api/v1/admin/projects/project/members",
      "PATCH /api/v1/admin/projects/project/members/user",
      "DELETE /api/v1/admin/projects/project/members/user",
      "GET /api/v1/admin/tokens",
      "DELETE /api/v1/admin/tokens/token",
      "GET /api/v1/admin/audit-events",
      "GET /api/v1/admin/health",
      "DELETE /api/v1/admin/session",
    ]);
    expect(ifMatch.get("PATCH /api/v1/admin/org")).toBe("1");
    expect(ifMatch.get("PATCH /api/v1/admin/members/user")).toBe("2");
    expect(ifMatch.get("DELETE /api/v1/admin/members/user")).toBe("3");
    expect(ifMatch.get("PATCH /api/v1/admin/projects/project")).toBe("4");
    expect(ifMatch.get("DELETE /api/v1/admin/projects/project")).toBe("5");
    expect(csrf.get("PUT /api/v1/setup/configuration")).toBe("csrf-token");
    expect(csrf.get("POST /api/v1/setup/oidc-authorizations")).toBe(
      "csrf-token",
    );
    expect(csrf.get("PATCH /api/v1/admin/org")).toBe("admin-csrf");
    expect(csrf.get("POST /api/v1/admin/projects")).toBe("admin-csrf");
    expect(csrf.get("DELETE /api/v1/admin/session")).toBe("admin-csrf");
  });
});
