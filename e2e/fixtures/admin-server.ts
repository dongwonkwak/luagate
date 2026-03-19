/**
 * Admin API mock server fixture for Playwright E2E tests.
 *
 * Intercepts API requests via Playwright route() instead of spawning a real server.
 * This allows testing UI behavior without a running LuaGate instance.
 */
import { type Page } from "@playwright/test";

const VALID_TOKEN = "test-e2e-token";

const MOCK_POLICY_YAML = `version: "1.0"
global:
  default_action: deny
rules:
  - id: allow-health
    priority: 100
    match:
      path: /health
    action: allow
`;

let currentEtag = "v1-initial";
let currentYaml = MOCK_POLICY_YAML;

const MOCK_STATUS = {
  luagate_version: "0.1.0",
  uptime_seconds: 3600,
  worker_count: 4,
  active_http_version: currentEtag,
  active_stream_version: currentEtag,
  last_reload_at: "2026-03-19T00:00:00Z",
  last_reload_status: "success",
};

const MOCK_METRICS = `# HELP luagate_http_requests_total Total HTTP requests
# TYPE luagate_http_requests_total counter
luagate_http_requests_total{action="allow"} 1500
luagate_http_requests_total{action="deny"} 42
# HELP luagate_active_connections Active connections
# TYPE luagate_active_connections gauge
luagate_active_connections{type="http"} 12
luagate_active_connections{type="stream"} 3
# HELP luagate_shared_dict_capacity_bytes Shared dict capacity
# TYPE luagate_shared_dict_capacity_bytes gauge
luagate_shared_dict_capacity_bytes{zone="luagate_policy"} 10485760
luagate_shared_dict_capacity_bytes{zone="luagate_metrics"} 5242880
# HELP luagate_shared_dict_free_bytes Shared dict free space
# TYPE luagate_shared_dict_free_bytes gauge
luagate_shared_dict_free_bytes{zone="luagate_policy"} 9961472
luagate_shared_dict_free_bytes{zone="luagate_metrics"} 5000000
`;

function checkAuth(headers: Record<string, string>): boolean {
  const auth = headers["authorization"] || "";
  return auth === `Bearer ${VALID_TOKEN}`;
}

/**
 * Set up API route interception on the given page.
 * Call this in beforeEach to mock all Admin API endpoints.
 */
export async function setupAdminMock(page: Page) {
  // Reset state
  currentEtag = "v1-initial";
  currentYaml = MOCK_POLICY_YAML;

  // GET /api/v1/policies/version — used by login to validate token
  await page.route("**/api/v1/policies/version", (route) => {
    const headers = route.request().headers();
    if (!checkAuth(headers)) {
      return route.fulfill({ status: 401, body: JSON.stringify({ error: "unauthorized" }) });
    }
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        source_version: currentEtag,
        active_http_version: currentEtag,
        active_stream_version: currentEtag,
        etag: currentEtag,
      }),
    });
  });

  // GET /api/v1/policies — returns YAML + ETag
  await page.route("**/api/v1/policies", (route, request) => {
    if (request.method() === "GET") {
      const headers = route.request().headers();
      if (!checkAuth(headers)) {
        return route.fulfill({ status: 401, body: JSON.stringify({ error: "unauthorized" }) });
      }
      return route.fulfill({
        status: 200,
        contentType: "application/x-yaml",
        headers: { ETag: `"${currentEtag}"` },
        body: currentYaml,
      });
    }

    // PUT /api/v1/policies — update
    if (request.method() === "PUT") {
      const headers = route.request().headers();
      if (!checkAuth(headers)) {
        return route.fulfill({ status: 401, body: JSON.stringify({ error: "unauthorized" }) });
      }

      const ifMatch = headers["if-match"];
      if (ifMatch && ifMatch !== `"${currentEtag}"`) {
        return route.fulfill({
          status: 409,
          contentType: "application/json",
          body: JSON.stringify({ error: "version_mismatch", details: ["ETag mismatch"] }),
        });
      }

      const body = request.postData() || "";

      // Simulate validation: check for 'version' key
      if (!body.includes("version:")) {
        return route.fulfill({
          status: 422,
          contentType: "application/json",
          body: JSON.stringify({
            error: "validation_failed",
            stage: "parse",
            details: ["Missing required 'version' key"],
          }),
        });
      }

      const prevVersion = currentEtag;
      currentEtag = `v${Date.now()}`;
      currentYaml = body;

      return route.fulfill({
        status: 200,
        contentType: "application/json",
        headers: { ETag: `"${currentEtag}"` },
        body: JSON.stringify({
          previous_http_version: prevVersion,
          previous_stream_version: prevVersion,
          new_http_version: currentEtag,
          new_stream_version: currentEtag,
          http_result: "committed",
          stream_result: "committed",
        }),
      });
    }

    return route.continue();
  });

  // POST /api/v1/policies/reload
  await page.route("**/api/v1/policies/reload", (route) => {
    const headers = route.request().headers();
    if (!checkAuth(headers)) {
      return route.fulfill({ status: 401, body: JSON.stringify({ error: "unauthorized" }) });
    }

    const prevVersion = currentEtag;
    currentEtag = `v${Date.now()}`;

    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        previous_http_version: prevVersion,
        previous_stream_version: prevVersion,
        new_http_version: currentEtag,
        new_stream_version: currentEtag,
        http_result: "committed",
        stream_result: "committed",
        reloaded_at: new Date().toISOString(),
      }),
    });
  });

  // GET /api/v1/status
  await page.route("**/api/v1/status", (route) => {
    const headers = route.request().headers();
    if (!checkAuth(headers)) {
      return route.fulfill({ status: 401, body: JSON.stringify({ error: "unauthorized" }) });
    }
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(MOCK_STATUS),
    });
  });

  // GET /health
  await page.route("**/health", (route) => {
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        status: "ok",
        source_version: currentEtag,
        active_http_version: currentEtag,
        active_stream_version: currentEtag,
        policy_loaded_at: "2026-03-19T00:00:00Z",
        ffi_watchdog_leak_count: [0, 0, 0, 0],
        ffi_watchdog_timeouts: 0,
      }),
    });
  });

  // GET /metrics
  await page.route("**/metrics", (route) => {
    return route.fulfill({
      status: 200,
      contentType: "text/plain",
      body: MOCK_METRICS,
    });
  });
}

export { VALID_TOKEN };
