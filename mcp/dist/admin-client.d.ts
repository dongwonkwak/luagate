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
    updatePolicies(yaml: string, expectedSourceVersion: string): Promise<PolicyUpdateResponse>;
    /** PUT /api/v1/policies?dry_run=true — validate only */
    validatePolicies(yaml: string): Promise<PolicyUpdateResponse>;
    /** POST /api/v1/policies/reload */
    reload(expectedActiveVersion?: string): Promise<PolicyUpdateResponse>;
}
export declare class AdminApiRequestError extends Error {
    readonly status: number;
    readonly apiError: AdminApiError;
    constructor(status: number, apiError: AdminApiError);
}
