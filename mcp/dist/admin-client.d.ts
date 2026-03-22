import type { AdminClientConfig, HealthResponse, StatusResponse, PolicyVersionResponse, PolicyUpdateResponse, AdminApiError } from "./types.js";
export declare class AdminClient {
    private baseUrl;
    private token;
    private mcpClientName;
    private mcpSessionId;
    constructor(config: AdminClientConfig);
    private headers;
    private request;
    /** GET /health — no auth required */
    getHealth(): Promise<HealthResponse>;
    /** GET /api/v1/status */
    getStatus(): Promise<StatusResponse>;
    /** GET /api/v1/policies — returns YAML + ETag */
    getPolicies(): Promise<{
        yaml: string;
        etag: string;
    }>;
    /** GET /api/v1/policies/version */
    getPolicyVersions(): Promise<PolicyVersionResponse>;
    /** PUT /api/v1/policies — update with If-Match */
    updatePolicies(yaml: string, expectedSourceVersion: string, toolName?: string): Promise<PolicyUpdateResponse>;
    /**
     * Validate policy YAML via server-side dry-run.
     * Calls PUT /api/v1/policies?dry_run=true which executes the full
     * parse → validate → conflict_detect → hash pipeline without committing.
     */
    validatePolicies(yaml: string): Promise<{
        valid: boolean;
        error?: string;
        /** HTTP status code when the request failed (non-422 errors indicate infra issues, not validation failures) */
        errorStatus?: number;
        warnings?: Array<{
            type: string;
            rule_ids: string[];
            message: string;
        }>;
        shadowed?: string[];
        version_hash?: string;
        http_rules_count?: number;
        stream_rules_count?: number;
    }>;
    /** POST /api/v1/policies/reload */
    reload(expectedActiveVersion?: string): Promise<PolicyUpdateResponse>;
}
export declare class AdminApiRequestError extends Error {
    readonly status: number;
    readonly apiError: AdminApiError;
    constructor(status: number, apiError: AdminApiError);
}
