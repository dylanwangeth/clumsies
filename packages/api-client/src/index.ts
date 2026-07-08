import createClient from "openapi-fetch";
import type { paths as AdminPaths } from "@clumsies/api-contract/admin";
import type { paths as PublicPaths } from "@clumsies/api-contract/public";
import type { paths as DaemonPaths } from "@clumsies/api-contract/daemon";

export type PublicApiClient = ReturnType<typeof createClient<PublicPaths>>;
export type AdminApiClient = ReturnType<typeof createClient<AdminPaths>>;
export type DaemonApiClient = ReturnType<typeof createClient<DaemonPaths>>;

export interface CreateApiClientOptions {
  baseUrl: string;
  accessToken?: string;
  requestId?: string;
  fetch?: typeof fetch;
}

export function createPublicApiClient(options: CreateApiClientOptions): PublicApiClient {
  return createClient<PublicPaths>({
    baseUrl: normalizeBaseUrl(options.baseUrl),
    headers: createHeaders(options),
    fetch: options.fetch,
  });
}

export function createAdminApiClient(options: CreateApiClientOptions): AdminApiClient {
  return createClient<AdminPaths>({
    baseUrl: normalizeBaseUrl(options.baseUrl),
    headers: createHeaders(options),
    fetch: options.fetch,
  });
}

export function createDaemonApiClient(options: CreateApiClientOptions): DaemonApiClient {
  return createClient<DaemonPaths>({
    baseUrl: normalizeBaseUrl(options.baseUrl),
    headers: createHeaders(options),
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

  return headers;
}
