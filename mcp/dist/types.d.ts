/** Health check response (GET /health) */
export interface HealthResponse {
    status: "ok" | "unhealthy";
    source_version: string | null;
    active_http_version: string | null;
    active_stream_version: string | null;
    policy_loaded_at: string | null;
    ffi_watchdog_leak_count: number[];
    ffi_watchdog_timeouts: number;
    reason?: string;
}
/** Detailed status response (GET /api/v1/status) */
export interface StatusResponse {
    luagate_version: string;
    uptime_seconds: number;
    worker_count: number;
    active_http_version: string;
    active_stream_version: string;
    last_reload_at: string;
    last_reload_status: string;
}
/** Policy version response (GET /api/v1/policies/version) */
export interface PolicyVersionResponse {
    source_version: string;
    active_http_version: string;
    active_stream_version: string;
    etag: string;
}
/** Policy update/reload success response */
export interface PolicyUpdateResponse {
    previous_http_version: string;
    previous_stream_version: string;
    new_http_version: string;
    new_stream_version: string;
    http_result: string;
    stream_result: string;
    warnings?: Array<{
        type: string;
        rule_ids: string[];
        message: string;
    }>;
    reloaded_at?: string;
}
/** Error response from Admin API */
export interface AdminApiError {
    error: string;
    stage?: string;
    details?: string[];
    message?: string;
}
/** Admin client configuration */
export interface AdminClientConfig {
    baseUrl: string;
    token: string;
    mcpClientName?: string;
    mcpSessionId?: string;
}
