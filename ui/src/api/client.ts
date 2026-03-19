/** Base URL for Admin API requests.
 *  Dev: omit VITE_ADMIN_API_URL — Vite proxy forwards /api to localhost:9090.
 *  Prod: leave unset or empty — same-origin /api is used. */
const BASE_URL: string = import.meta.env.VITE_ADMIN_API_URL || "/api";

/** Response wrapper that includes headers for ETag extraction */
export interface ApiResponse<T> {
  data: T;
  headers: Headers;
}

/** Default request headers (JSON endpoints) */
function defaultHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};

  const token = localStorage.getItem("luagate_admin_token");
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  return headers;
}

/**
 * Determine how to parse the response based on Content-Type header.
 * - application/x-yaml or text/yaml -> raw text (string)
 * - application/json (default) -> parsed JSON
 */
async function parseResponse<T>(response: Response): Promise<T> {
  const contentType = response.headers.get("Content-Type") || "";

  if (
    contentType.includes("application/x-yaml") ||
    contentType.includes("text/yaml") ||
    contentType.includes("text/plain")
  ) {
    return (await response.text()) as unknown as T;
  }

  return response.json() as Promise<T>;
}

/**
 * Generic fetch wrapper for Admin API.
 * Automatically sets Content-Type based on the request and parses the
 * response according to the returned Content-Type header.
 *
 * Returns both `data` and `headers` so callers can extract ETag, etc.
 */
export async function apiClient<T>(
  path: string,
  options: RequestInit = {},
): Promise<ApiResponse<T>> {
  const url = `${BASE_URL}${path}`;

  const response = await fetch(url, {
    ...options,
    headers: {
      ...defaultHeaders(),
      ...options.headers,
    },
  });

  if (!response.ok) {
    if (response.status === 401) {
      localStorage.removeItem("luagate_admin_token");
      window.location.href = "/dashboard/login";
    }
    const body = await response.text().catch(() => "");
    throw new ApiError(response.status, response.statusText, body);
  }

  const data = await parseResponse<T>(response);
  return { data, headers: response.headers };
}

// ── Policy-specific helpers ───────────────────────────────────────────────

/**
 * GET /api/v1/policies — returns YAML text and the ETag for subsequent
 * If-Match usage.
 *
 * Admin API spec (admin-api.md $6.3):
 *   Response Content-Type: application/x-yaml
 *   ETag: "<source_version>"
 */
export async function getPolicies(): Promise<{
  yaml: string;
  etag: string | null;
}> {
  const { data, headers } = await apiClient<string>("/v1/policies");
  const etag = headers.get("ETag");
  return { yaml: data, etag };
}

/**
 * PUT /api/v1/policies — upload new policy YAML.
 *
 * Admin API spec (admin-api.md $6.5):
 *   Request Content-Type: application/x-yaml
 *   If-Match: "<source_version>" (required, from GET ETag)
 */
export async function putPolicies(
  yaml: string,
  ifMatch: string,
): Promise<ApiResponse<unknown>> {
  return apiClient("/v1/policies", {
    method: "PUT",
    headers: {
      "Content-Type": "application/x-yaml",
      "If-Match": ifMatch,
    },
    body: yaml,
  });
}

/** Structured error for API failures */
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
  ) {
    super(`API ${status}: ${statusText}`);
    this.name = "ApiError";
  }
}
