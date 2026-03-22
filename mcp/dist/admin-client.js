export class AdminClient {
    baseUrl;
    token;
    mcpClientName;
    mcpSessionId;
    constructor(config) {
        this.baseUrl = config.baseUrl.replace(/\/+$/, "");
        this.token = config.token;
        this.mcpClientName = config.mcpClientName ?? "unknown";
        this.mcpSessionId = config.mcpSessionId ?? "";
    }
    headers(toolName, extra) {
        return {
            Authorization: `Bearer ${this.token}`,
            "X-MCP-Client": this.mcpClientName,
            "X-MCP-Tool": toolName,
            "X-MCP-Session-Id": this.mcpSessionId,
            "X-Request-ID": crypto.randomUUID(),
            ...extra,
        };
    }
    async request(method, path, toolName, options) {
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
            let error;
            try {
                error = JSON.parse(errorBody);
            }
            catch {
                error = { error: "unknown", message: errorBody };
            }
            throw new AdminApiRequestError(res.status, error);
        }
        const expectJson = options?.expectJson ?? true;
        const data = expectJson
            ? (await res.json())
            : (await res.text());
        return { data, headers: res.headers, status: res.status };
    }
    /** GET /health — no auth required */
    async getHealth() {
        const url = `${this.baseUrl}/health`;
        const res = await fetch(url);
        return (await res.json());
    }
    /** GET /api/v1/status */
    async getStatus() {
        const { data } = await this.request("GET", "/api/v1/status", "luagate_get_status");
        return data;
    }
    /** GET /api/v1/policies — returns YAML + ETag */
    async getPolicies() {
        const { data, headers } = await this.request("GET", "/api/v1/policies", "luagate_get_policies", { expectJson: false });
        const etag = headers.get("etag")?.replace(/"/g, "") ?? "";
        return { yaml: data, etag };
    }
    /** GET /api/v1/policies/version */
    async getPolicyVersions() {
        const { data } = await this.request("GET", "/api/v1/policies/version", "luagate_get_policy_versions");
        return data;
    }
    /** PUT /api/v1/policies — update with If-Match */
    async updatePolicies(yaml, expectedSourceVersion, toolName = "luagate_update_policies") {
        const { data } = await this.request("PUT", "/api/v1/policies", toolName, {
            body: yaml,
            contentType: "application/x-yaml",
            extraHeaders: { "If-Match": `"${expectedSourceVersion}"` },
        });
        return data;
    }
    /**
     * Validate policy YAML via server-side dry-run.
     * Calls PUT /api/v1/policies?dry_run=true which executes the full
     * parse → validate → conflict_detect → hash pipeline without committing.
     */
    async validatePolicies(yaml) {
        try {
            const { data } = await this.request("PUT", "/api/v1/policies?dry_run=true", "luagate_validate_policies", {
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
        }
        catch (e) {
            if (e instanceof AdminApiRequestError) {
                const details = e.apiError.details?.join("; ") ??
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
    async reload(expectedActiveVersion) {
        const extraHeaders = {};
        if (expectedActiveVersion) {
            extraHeaders["If-Match"] = `"${expectedActiveVersion}"`;
        }
        const { data } = await this.request("POST", "/api/v1/policies/reload", "luagate_reload", { extraHeaders });
        return data;
    }
}
export class AdminApiRequestError extends Error {
    status;
    apiError;
    constructor(status, apiError) {
        super(`Admin API error ${status}: ${apiError.error} — ${apiError.details?.join(", ") ?? apiError.message ?? ""}`);
        this.status = status;
        this.apiError = apiError;
        this.name = "AdminApiRequestError";
    }
}
//# sourceMappingURL=admin-client.js.map
