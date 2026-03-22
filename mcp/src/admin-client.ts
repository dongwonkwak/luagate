import type {
  AdminClientConfig,
  HealthResponse,
  StatusResponse,
  PolicyVersionResponse,
  PolicyUpdateResponse,
  AdminApiError,
} from "./types.js";

export class AdminClient {
  private baseUrl: string;
  private token: string;
  private mcpClientName: string;
  private mcpSessionId: string;

  constructor(config: AdminClientConfig) {
    this.baseUrl = config.baseUrl.replace(/\/+$/, "");
    this.token = config.token;
    this.mcpClientName = config.mcpClientName ?? "unknown";
    this.mcpSessionId = config.mcpSessionId ?? "";
  }

  private headers(
    toolName: string,
    extra?: Record<string, string>,
  ): Record<string, string> {
    return {
      Authorization: `Bearer ${this.token}`,
      "X-MCP-Client": this.mcpClientName,
      "X-MCP-Tool": toolName,
      "X-MCP-Session-Id": this.mcpSessionId,
      "X-Request-ID": crypto.randomUUID(),
      ...extra,
    };
  }

  private async request<T>(
    method: string,
    path: string,
    toolName: string,
    options?: {
      body?: string;
      contentType?: string;
      extraHeaders?: Record<string, string>;
      expectJson?: boolean;
    },
  ): Promise<{ data: T; headers: Headers; status: number }> {
    const url = `${this.baseUrl}${path}`;
    const headers = this.headers(toolName, {
      ...(options?.contentType ? { "Content-Type": options.contentType } : {}),
      ...options?.extraHeaders,
    });

    const res = await fetch(url, {
      method,
      headers,
      body: options?.body,
    });

    if (!res.ok) {
      const errorBody = await res.text();
      let error: AdminApiError;
      try {
        error = JSON.parse(errorBody) as AdminApiError;
      } catch {
        error = { error: "unknown", message: errorBody };
      }
      throw new AdminApiRequestError(res.status, error);
    }

    const expectJson = options?.expectJson ?? true;
    const data = expectJson
      ? ((await res.json()) as T)
      : ((await res.text()) as unknown as T);

    return { data, headers: res.headers, status: res.status };
  }

  /** GET /health — no auth required */
  async getHealth(): Promise<HealthResponse> {
    const url = `${this.baseUrl}/health`;
    const res = await fetch(url);
    return (await res.json()) as HealthResponse;
  }

  /** GET /api/v1/status */
  async getStatus(): Promise<StatusResponse> {
    const { data } = await this.request<StatusResponse>(
      "GET",
      "/api/v1/status",
      "luagate_get_status",
    );
    return data;
  }

  /** GET /api/v1/policies — returns YAML + ETag */
  async getPolicies(): Promise<{ yaml: string; etag: string }> {
    const { data, headers } = await this.request<string>(
      "GET",
      "/api/v1/policies",
      "luagate_get_policies",
      { expectJson: false },
    );
    const etag = headers.get("etag")?.replace(/"/g, "") ?? "";
    return { yaml: data, etag };
  }

  /** GET /api/v1/policies/version */
  async getPolicyVersions(): Promise<PolicyVersionResponse> {
    const { data } = await this.request<PolicyVersionResponse>(
      "GET",
      "/api/v1/policies/version",
      "luagate_get_policy_versions",
    );
    return data;
  }

  /** PUT /api/v1/policies — update with If-Match */
  async updatePolicies(
    yaml: string,
    expectedSourceVersion: string,
    toolName = "luagate_update_policies",
  ): Promise<PolicyUpdateResponse> {
    const { data } = await this.request<PolicyUpdateResponse>(
      "PUT",
      "/api/v1/policies",
      toolName,
      {
        body: yaml,
        contentType: "application/x-yaml",
        extraHeaders: { "If-Match": `"${expectedSourceVersion}"` },
      },
    );
    return data;
  }

  /**
   * Validate policy YAML via server-side dry-run.
   * Calls PUT /api/v1/policies?dry_run=true which executes the full
   * parse → validate → conflict_detect → hash pipeline without committing.
   */
  async validatePolicies(yaml: string): Promise<{
    valid: boolean;
    error?: string;
    /** HTTP status code when the request failed (non-422 errors indicate infra issues, not validation failures) */
    errorStatus?: number;
    warnings?: Array<{ type: string; rule_ids: string[]; message: string }>;
    shadowed?: string[];
    version_hash?: string;
    http_rules_count?: number;
    stream_rules_count?: number;
  }> {
    try {
      const { data } = await this.request<{
        dry_run: boolean;
        valid: boolean;
        version_hash: string;
        warnings: Array<{ type: string; rule_ids: string[]; message: string }>;
        shadowed: string[];
        http_rules_count: number;
        stream_rules_count: number;
      }>("PUT", "/api/v1/policies?dry_run=true", "luagate_validate_policies", {
        body: yaml,
        contentType: "application/x-yaml",
      });
      return {
        valid: data.valid,
        warnings: data.warnings ? Object.values(data.warnings) : [],
        shadowed: Array.isArray(data.shadowed) ? data.shadowed : [],
        version_hash: data.version_hash,
        http_rules_count: data.http_rules_count,
        stream_rules_count: data.stream_rules_count,
      };
    } catch (e) {
      if (e instanceof AdminApiRequestError) {
        const details =
          e.apiError.details?.join("; ") ??
          e.apiError.message ??
          "unknown error";
        return {
          valid: false,
          error: `${e.apiError.error}: ${details}`,
          errorStatus: e.status,
        };
      }
      const message = e instanceof Error ? e.message : String(e);
      return { valid: false, error: message };
    }
  }

  /** POST /api/v1/policies/reload */
  async reload(expectedActiveVersion?: string): Promise<PolicyUpdateResponse> {
    const extraHeaders: Record<string, string> = {};
    if (expectedActiveVersion) {
      extraHeaders["If-Match"] = `"${expectedActiveVersion}"`;
    }
    const { data } = await this.request<PolicyUpdateResponse>(
      "POST",
      "/api/v1/policies/reload",
      "luagate_reload",
      { extraHeaders },
    );
    return data;
  }
}

export class AdminApiRequestError extends Error {
  constructor(
    public readonly status: number,
    public readonly apiError: AdminApiError,
  ) {
    super(
      `Admin API error ${status}: ${apiError.error} — ${apiError.details?.join(", ") ?? apiError.message ?? ""}`,
    );
    this.name = "AdminApiRequestError";
  }
}
