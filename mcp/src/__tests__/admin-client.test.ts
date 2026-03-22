import { describe, it, expect, vi, beforeEach } from "vitest";
import { AdminClient, AdminApiRequestError } from "../admin-client.js";

const mockFetch = vi.fn();
global.fetch = mockFetch;

function jsonResponse(
  data: unknown,
  status = 200,
  headers?: Record<string, string>,
) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(data),
    text: () => Promise.resolve(JSON.stringify(data)),
    headers: new Headers(headers),
  };
}

function textResponse(
  text: string,
  status = 200,
  headers?: Record<string, string>,
) {
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
      baseUrl: "http://127.0.0.1:9090",
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

      const callArgs = mockFetch.mock.calls[0];
      expect(callArgs[0]).toBe("http://127.0.0.1:9090/health");
    });
  });

  describe("getStatus", () => {
    it("returns detailed status with MCP audit headers", async () => {
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
      expect(headers["X-Request-ID"]).toBeDefined();
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

      await expect(
        client.updatePolicies("yaml", "wrong-version"),
      ).rejects.toThrow(AdminApiRequestError);
    });
  });

  describe("validatePolicies", () => {
    it("returns valid result on dry-run success", async () => {
      const dryRunResponse = {
        dry_run: true,
        valid: true,
        version_hash: "abc123",
        warnings: {},
        shadowed: [],
        http_rules_count: 2,
        stream_rules_count: 1,
      };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve(dryRunResponse),
        headers: new Headers(),
        status: 200,
      } as Response);

      const yaml =
        'version: "1.0"\nglobal:\n  default_action: deny\nrules: []\n';
      const result = await client.validatePolicies(yaml);
      expect(result.valid).toBe(true);
      expect(result.version_hash).toBe("abc123");
      expect(result.http_rules_count).toBe(2);
    });

    it("returns error on validation failure (422)", async () => {
      const errorBody = {
        error: "validation_failed",
        stage: "validate",
        details: ["policy is missing required 'version' field"],
      };
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 422,
        text: () => Promise.resolve(JSON.stringify(errorBody)),
        headers: new Headers(),
      } as Response);

      const yaml = "global:\n  default_action: deny\n";
      const result = await client.validatePolicies(yaml);
      expect(result.valid).toBe(false);
      expect(result.error).toContain("version");
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
