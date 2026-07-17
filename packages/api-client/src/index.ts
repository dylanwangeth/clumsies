import createClient from "openapi-fetch";
import type {
  components as AdminComponents,
  paths as AdminPaths,
} from "@clumsies/api-contract/admin";
import type { components as DaemonComponents } from "@clumsies/api-contract/daemon";
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
export type DaemonBootstrapStatus = DaemonComponents["schemas"]["DaemonBootstrapStatus"];
export type DaemonProjectConfig = DaemonComponents["schemas"]["DaemonProjectConfig"];
export type DaemonProjectSelectionRequest =
  DaemonComponents["schemas"]["DaemonProjectSelectionRequest"];
export type DaemonHealth = DaemonComponents["schemas"]["DaemonHealth"];
export type DaemonSyncStatus = DaemonComponents["schemas"]["DaemonSyncStatus"];
export type DaemonSyncRetryRequest =
  DaemonComponents["schemas"]["DaemonSyncRetryRequest"];
export type DaemonRetryResponse = DaemonComponents["schemas"]["DaemonRetryResponse"];
export type DaemonMcpStatus = DaemonComponents["schemas"]["DaemonMcpStatus"];
export type DaemonDraftListResponse =
  DaemonComponents["schemas"]["DaemonDraftListResponse"];
export type DaemonDraftDetail = DaemonComponents["schemas"]["DaemonDraftDetail"];
export type DaemonDraftOperationRequest =
  DaemonComponents["schemas"]["DaemonDraftOperationRequest"];
export type DaemonDraftOperationResponse =
  DaemonComponents["schemas"]["DaemonDraftOperationResponse"];
export type DaemonServerRequest = DaemonComponents["schemas"]["DaemonServerRequest"];
export type DaemonServerResponse = DaemonComponents["schemas"]["DaemonServerResponse"];

export type DaemonDraftListQuery = {
  resource?: "context" | "rule" | "workflow" | "metaprompt" | null;
  status?: "open" | "submitted" | "discarded" | "conflicted" | null;
  limit?: number | null;
};

export type NativeInvoke = <T>(
  command: string,
  args?: Record<string, unknown>,
) => Promise<T>;

export type DaemonApiClient = ReturnType<typeof createDaemonApiClient>;

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

export function createDaemonApiClient(invoke: NativeInvoke) {
  return {
    bootstrapStatus: () =>
      invoke<DaemonBootstrapStatus>("read_daemon_bootstrap_status"),
    install: () => invoke<DaemonBootstrapStatus>("install_daemon_launch_agent"),
    start: () => invoke<DaemonBootstrapStatus>("start_daemon_launch_agent"),
    restart: () => invoke<DaemonBootstrapStatus>("restart_daemon_launch_agent"),
    stop: () => invoke<DaemonBootstrapStatus>("stop_daemon_launch_agent"),
    health: () => invoke<DaemonHealth>("read_daemon_health"),
    projectConfig: () =>
      invoke<DaemonProjectConfig>("read_daemon_project_config"),
    selectProject: (request: DaemonProjectSelectionRequest) =>
      invoke<DaemonProjectConfig>("select_daemon_project", { request }),
    syncStatus: () => invoke<DaemonSyncStatus>("read_daemon_sync_status"),
    retrySync: (request: DaemonSyncRetryRequest) =>
      invoke<DaemonRetryResponse>("retry_daemon_sync", { request }),
    mcpStatus: () => invoke<DaemonMcpStatus>("read_daemon_mcp_status"),
    listDrafts: (query: DaemonDraftListQuery = {}) =>
      invoke<DaemonDraftListResponse>("list_daemon_drafts", { query }),
    draft: (draftId: string) =>
      invoke<DaemonDraftDetail>("read_daemon_draft", { draftId }),
    storeDraftOperation: (request: DaemonDraftOperationRequest) =>
      invoke<DaemonDraftOperationResponse>("store_daemon_draft_operation", {
        request,
      }),
    serverRequest: (request: DaemonServerRequest) =>
      invoke<DaemonServerResponse>("proxy_server_request", { request }),
  };
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
