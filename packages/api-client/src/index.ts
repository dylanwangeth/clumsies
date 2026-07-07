import createClient from "openapi-fetch";
import type { paths as AdminPaths } from "@clumsies/api-contract/admin";
import type { paths as PublicPaths } from "@clumsies/api-contract/public";
import type { paths as RuntimePaths } from "@clumsies/api-contract/runtime";

export type PublicApiClient = ReturnType<typeof createClient<PublicPaths>>;
export type AdminApiClient = ReturnType<typeof createClient<AdminPaths>>;
export type RuntimeApiClient = ReturnType<typeof createClient<RuntimePaths>>;

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

export function createRuntimeApiClient(options: CreateApiClientOptions): RuntimeApiClient {
  return createClient<RuntimePaths>({
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
