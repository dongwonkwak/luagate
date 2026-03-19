import { describe, it, expect, vi, beforeEach } from "vitest";
import { AdminClient, AdminApiRequestError } from "../admin-client.js";

const mockFetch = vi.fn();
global.fetch = mockFetch;

function jsonResponse(data: unknown, status = 200, headers?: Record<string, string>) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(data),
    text: () => Promise.resolve(JSON.stringify(data)),
    headers: new Headers(headers),
  };
}

function textResponse(text: string, status = 200, headers?: Record<string, string>) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(JSON.parse(text)),
    text: () => Promise.resolve(text),
    headers: new Headers(headers),
  };
}

describe("AdminClient", () => {
  let client: AdminClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new AdminClient({
      baseUrl: "http://localhost:9090",
      token: "test-token",
      mcpClientName: "test-client",
      mcpSessionId: "test-session",
    });
  });

  describe("getHealth", () => {
    it("returns health status without auth", async () => {
      const healthData = {
        status: "ok",
        source_version: "abc123",
        active_http_version: "abc123",
        active_stream_version: "abc123",
        policy_loaded_at: "2026-03-19T00:00:00Z",
        ffi_watchdog_leak_count: [0, 0, 0, 0],
        ffi_watchdog_timeouts: 0,
      };
      mockFetch.mockResolvedValueOnce(jsonResponse(healthData));

      const result = await client.getHealth();
      expect(result.status).toBe("ok");
      expect(result.source_version).toBe("abc123");

      // Health check should NOT include Authorization header
      const callArgs = mockFetch.mock.calls[0];
      expect(callArgs[0]).toBe("http://localhost:9090/health");
    });
  });

  describe("getStatus", () => {
    it("returns detailed status with auth headers", async () => {
      const statusData = {
        luagate_version: "0.1.0",
        uptime_seconds: 3600,
        worker_count: 4,
        active_http_version: "abc123",
        active_stream_version: "abc123",
        last_reload_at: "2026-03-19T00:00:00Z",
        last_reload_status: "success",
      };
      mockFetch.mockResolvedValueOnce(jsonResponse(statusData));

      const result = await client.getStatus();
      expect(result.worker_count).toBe(4);

      const callArgs = mockFetch.mock.calls[0];
      const headers = callArgs[1].headers;
      expect(headers.Authorization).toBe("Bearer test-token");
      expect(headers["X-MCP-Client"]).toBe("test-client");
      expect(headers["X-MCP-Tool"]).toBe("luagate_get_status");
      expect(headers["X-MCP-Session-Id"]).toBe("test-session");
    });
  });

  describe("getPolicies", () => {
    it("returns YAML and ETag", async () => {
      const yaml = 'version: "1.0"\nglobal:\n  default_action: deny\n';
      mockFetch.mockResolvedValueOnce(
        textResponse(yaml, 200, { etag: '"v5hash"' }),
      );

      const result = await client.getPolicies();
      expect(result.yaml).toBe(yaml);
      expect(result.etag).toBe("v5hash");
    });
  });

  describe("updatePolicies", () => {
    it("sends If-Match header with expected version", async () => {
      const updateResult = {
        previous_http_version: "v5",
        previous_stream_version: "v5",
        new_http_version: "v6",
        new_stream_version: "v6",
        http_result: "committed",
        stream_result: "committed",
      };
      mockFetch.mockResolvedValueOnce(jsonResponse(updateResult));

      await client.updatePolicies("new yaml", "v5");

      const callArgs = mockFetch.mock.calls[0];
      expect(callArgs[1].method).toBe("PUT");
      expect(callArgs[1].headers["If-Match"]).toBe('"v5"');
      expect(callArgs[1].headers["Content-Type"]).toBe("application/x-yaml");
    });

    it("throws AdminApiRequestError on 409 conflict", async () => {
      const errorData = {
        error: "version_mismatch",
        stage: "reload",
        details: ["If-Match version mismatch"],
      };
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 409,
        text: () => Promise.resolve(JSON.stringify(errorData)),
      });

      await expect(client.updatePolicies("yaml", "wrong-version")).rejects.toThrow(
        AdminApiRequestError,
      );
    });
  });

  describe("validatePolicies", () => {
    it("sends dry_run=true query parameter", async () => {
      const result = {
        previous_http_version: "",
        previous_stream_version: "",
        new_http_version: "",
        new_stream_version: "",
        http_result: "validated",
        stream_result: "validated",
      };
      mockFetch.mockResolvedValueOnce(jsonResponse(result));

      await client.validatePolicies("test yaml");

      const callArgs = mockFetch.mock.calls[0];
      expect(callArgs[0]).toContain("dry_run=true");
    });
  });

  describe("reload", () => {
    it("sends If-Match when expectedActiveVersion provided", async () => {
      const reloadResult = {
        previous_http_version: "v5",
        previous_stream_version: "v5",
        new_http_version: "v6",
        new_stream_version: "v6",
        http_result: "committed",
        stream_result: "committed",
        reloaded_at: "2026-03-19T00:00:00Z",
      };
      mockFetch.mockResolvedValueOnce(jsonResponse(reloadResult));

      await client.reload("v5");

      const callArgs = mockFetch.mock.calls[0];
      expect(callArgs[1].method).toBe("POST");
      expect(callArgs[1].headers["If-Match"]).toBe('"v5"');
    });

    it("omits If-Match when no expectedActiveVersion", async () => {
      const reloadResult = {
        previous_http_version: "v5",
        previous_stream_version: "v5",
        new_http_version: "v6",
        new_stream_version: "v6",
        http_result: "committed",
        stream_result: "committed",
      };
      mockFetch.mockResolvedValueOnce(jsonResponse(reloadResult));

      await client.reload();

      const callArgs = mockFetch.mock.calls[0];
      expect(callArgs[1].headers["If-Match"]).toBeUndefined();
    });
  });
});
