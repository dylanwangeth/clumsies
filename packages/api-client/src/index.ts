import createClient from "openapi-fetch";
import type {
  components as AdminComponents,
  paths as AdminPaths,
} from "@clumsies/api-contract/admin";
import type {
  components as PublicComponents,
  paths as PublicPaths,
} from "@clumsies/api-contract/public";

export {
  ClumsiesApiError,
  ClumsiesApi,
  type DraftEventQuery,
  type OrgCommitStateQuery,
  type PageQuery,
  type ProjectPageQuery,
  type ProjectCommitStateQuery,
} from "./public-api";
export {
  ClumsiesAdminApi,
  type AdminPageQuery,
  type AdminProjectMemberQuery,
} from "./admin-api";

export type PublicApiClient = ReturnType<typeof createClient<PublicPaths>>;
export type AdminApiClient = ReturnType<typeof createClient<AdminPaths>>;
export type PublicSchema<Name extends keyof PublicComponents["schemas"]> =
  PublicComponents["schemas"][Name];
export type AdminSchema<Name extends keyof AdminComponents["schemas"]> =
  AdminComponents["schemas"][Name];
export interface CreateApiClientOptions {
  baseUrl: string;
  accessToken?: string;
  requestId?: string;
  csrfToken?: string;
  credentials?: RequestCredentials;
  fetch?: typeof fetch;
}

export function createPublicApiClient(options: CreateApiClientOptions): PublicApiClient {
  return createClient<PublicPaths>({
    baseUrl: normalizeBaseUrl(options.baseUrl),
    headers: createHeaders(options),
    credentials: options.credentials,
    fetch: options.fetch,
  });
}

export function createAdminApiClient(options: CreateApiClientOptions): AdminApiClient {
  return createClient<AdminPaths>({
    baseUrl: normalizeBaseUrl(options.baseUrl),
    headers: createHeaders(options),
    credentials: options.credentials,
    fetch: options.fetch,
  });
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "");
}

function createHeaders(options: CreateApiClientOptions): HeadersInit {
  const headers: Record<string, string> = {};

  if (options.accessToken) {
    headers.Authorization = `Bearer ${options.accessToken}`;
  }

  if (options.requestId) {
    headers["X-Clumsies-Request-Id"] = options.requestId;
  }

  if (options.csrfToken) {
    headers["X-CSRF-Token"] = options.csrfToken;
  }

  return headers;
}
