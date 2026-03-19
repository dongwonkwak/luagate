/** GET /health response */
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

/** GET /api/v1/status response */
export interface StatusResponse {
  luagate_version: string;
  uptime_seconds: number;
  worker_count: number;
  active_http_version: string;
  active_stream_version: string;
  last_reload_at: string;
  last_reload_status: string;
}

/** GET /api/v1/policies/version response */
export interface PolicyVersionResponse {
  source_version: string;
  active_http_version: string;
  active_stream_version: string;
  etag: string;
}

/** PUT /api/v1/policies success response */
export interface PolicyUpdateResponse {
  previous_http_version: string;
  previous_stream_version: string;
  new_http_version: string;
  new_stream_version: string;
  http_result: string;
  stream_result: string;
  warnings?: PolicyWarning[];
}

export interface PolicyWarning {
  type: string;
  rule_ids: string[];
  message: string;
}

/** POST /api/v1/policies/reload response */
export interface ReloadResponse extends PolicyUpdateResponse {
  reloaded_at: string;
}

/** GET /api/v1/audit response */
export interface AuditResponse {
  entries: AuditEntry[];
  total: number;
  offset: number;
  limit: number;
}

export interface AuditEntry {
  timestamp: string;
  event: string;
  actor_ip: string;
  trigger: string;
  previous_version?: string;
  new_version?: string;
  subsystem?: string;
  stage?: string;
  reason?: string;
}

/** Admin API error body */
export interface ApiErrorBody {
  error: string;
  stage?: string;
  details?: string[];
  message?: string;
}
