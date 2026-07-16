import type { components } from "@clumsies/api-contract/admin";
import type { AdminApiClient } from "./index";
import { ClumsiesApiError } from "./public-api";

type Schema<Name extends keyof components["schemas"]> =
  components["schemas"][Name];

export type AdminPageQuery = {
  limit?: number;
  cursor?: string;
};

export type AdminProjectMemberQuery = AdminPageQuery & {
  role?: Schema<"ProjectRole">;
};

type ApiResult<T> = {
  data?: T;
  error?: unknown;
  response: Response;
};

export class ClumsiesAdminApi {
  readonly raw: AdminApiClient;

  constructor(client: AdminApiClient) {
    this.raw = client;
  }

  setup() {
    return unwrap(this.raw.GET("/api/v1/setup"));
  }

  createSetupSession(setupCode: string) {
    return unwrap(
      this.raw.POST("/api/v1/setup/sessions", {
        body: { setup_code: setupCode },
      }),
    );
  }

  replaceSetupConfiguration(
    csrfToken: string,
    request: Schema<"ReplaceSetupConfigurationRequest">,
  ) {
    return unwrap(
      this.raw.PUT("/api/v1/setup/configuration", {
        params: { header: { "X-CSRF-Token": csrfToken } },
        body: request,
      }),
    );
  }

  createSetupOidcAuthorization(csrfToken: string, redirectUri: string) {
    return unwrap(
      this.raw.POST("/api/v1/setup/oidc-authorizations", {
        params: { header: { "X-CSRF-Token": csrfToken } },
        body: { redirect_uri: redirectUri },
      }),
    );
  }

  session() {
    return unwrap(this.raw.GET("/api/v1/admin/session"));
  }

  deleteSession() {
    return unwrap(this.raw.DELETE("/api/v1/admin/session"));
  }

  identityProvider() {
    return unwrap(this.raw.GET("/api/v1/admin/identity-provider"));
  }

  org() {
    return unwrap(this.raw.GET("/api/v1/admin/org"));
  }

  updateOrg(revision: number, request: Schema<"UpdateAdminOrgRequest">) {
    return unwrap(
      this.raw.PATCH("/api/v1/admin/org", {
        params: { header: { "If-Match": String(revision) } },
        body: request,
      }),
    );
  }

  listMembers(query: AdminPageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/admin/members", { params: { query } }),
    );
  }

  createMember(request: Schema<"CreateMemberRequest">) {
    return unwrap(this.raw.POST("/api/v1/admin/members", { body: request }));
  }

  updateMember(
    userId: string,
    revision: number,
    request: Schema<"UpdateMemberRequest">,
  ) {
    return unwrap(
      this.raw.PATCH("/api/v1/admin/members/{user_id}", {
        params: {
          path: { user_id: userId },
          header: { "If-Match": String(revision) },
        },
        body: request,
      }),
    );
  }

  deleteMember(userId: string, revision: number) {
    return unwrap(
      this.raw.DELETE("/api/v1/admin/members/{user_id}", {
        params: {
          path: { user_id: userId },
          header: { "If-Match": String(revision) },
        },
      }),
    );
  }

  listProjects(query: AdminPageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/admin/projects", { params: { query } }),
    );
  }

  createProject(request: Schema<"CreateProjectRequest">) {
    return unwrap(this.raw.POST("/api/v1/admin/projects", { body: request }));
  }

  project(projectId: string) {
    return unwrap(
      this.raw.GET("/api/v1/admin/projects/{project_id}", {
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
      this.raw.PATCH("/api/v1/admin/projects/{project_id}", {
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
      this.raw.DELETE("/api/v1/admin/projects/{project_id}", {
        params: {
          path: { project_id: projectId },
          header: { "If-Match": String(revision) },
        },
      }),
    );
  }

  listProjectMembers(
    projectId: string,
    query: AdminProjectMemberQuery = {},
  ) {
    return unwrap(
      this.raw.GET("/api/v1/admin/projects/{project_id}/members", {
        params: { path: { project_id: projectId }, query },
      }),
    );
  }

  createProjectMember(
    projectId: string,
    request: Schema<"CreateProjectMemberRequest">,
  ) {
    return unwrap(
      this.raw.POST("/api/v1/admin/projects/{project_id}/members", {
        params: { path: { project_id: projectId } },
        body: request,
      }),
    );
  }

  updateProjectMember(
    projectId: string,
    userId: string,
    request: Schema<"UpdateProjectMemberRequest">,
  ) {
    return unwrap(
      this.raw.PATCH(
        "/api/v1/admin/projects/{project_id}/members/{user_id}",
        {
          params: {
            path: { project_id: projectId, user_id: userId },
          },
          body: request,
        },
      ),
    );
  }

  deleteProjectMember(projectId: string, userId: string) {
    return unwrap(
      this.raw.DELETE(
        "/api/v1/admin/projects/{project_id}/members/{user_id}",
        {
          params: {
            path: { project_id: projectId, user_id: userId },
          },
        },
      ),
    );
  }

  listTokens(query: AdminPageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/admin/tokens", { params: { query } }),
    );
  }

  deleteToken(tokenId: string) {
    return unwrap(
      this.raw.DELETE("/api/v1/admin/tokens/{token_id}", {
        params: { path: { token_id: tokenId } },
      }),
    );
  }

  listAuditEvents(query: AdminPageQuery = {}) {
    return unwrap(
      this.raw.GET("/api/v1/admin/audit-events", { params: { query } }),
    );
  }

  health() {
    return unwrap(this.raw.GET("/api/v1/admin/health"));
  }
}

async function unwrap<T>(request: Promise<ApiResult<T>>): Promise<T> {
  const result = await request;
  if (result.data !== undefined) {
    return result.data;
  }
  throw new ClumsiesApiError(result.response.status, result.error);
}
