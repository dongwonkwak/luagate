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
            "X-Request-Id": crypto.randomUUID(),
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
     * Validate policy YAML locally (parse check).
     * Note: Admin API does not yet support dry_run parameter.
     * When backend dry_run is implemented, this should call
     * PUT /api/v1/policies?dry_run=true instead.
     */
    validatePoliciesLocally(yaml) {
        // Basic YAML structure validation
        if (!yaml || !yaml.trim()) {
            return { valid: false, error: "Empty YAML" };
        }
        // Check for required top-level keys
        const hasVersion = /^version\s*:/m.test(yaml);
        const hasGlobal = /^global\s*:/m.test(yaml);
        if (!hasVersion) {
            return { valid: false, error: "Missing required 'version' key" };
        }
        if (!hasGlobal) {
            return { valid: false, error: "Missing required 'global' key" };
        }
        // Check for basic YAML syntax errors (unclosed quotes, bad indentation)
        const lines = yaml.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (line.includes("\t")) {
                return { valid: false, error: `Tab character found at line ${i + 1} (use spaces)` };
            }
        }
        return { valid: true };
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
