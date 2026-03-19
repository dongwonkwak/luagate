import { describe, it, expect, vi, beforeEach } from "vitest";
import { AdminClient } from "../../src/admin-client.js";

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

describe("Audit Log Headers", () => {
  let client: AdminClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new AdminClient({
      baseUrl: "http://127.0.0.1:9090",
      token: "test-token",
      mcpClientName: "claude-desktop",
      mcpSessionId: "session-abc",
    });
  });

  it("sends X-MCP-Client header on getStatus", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({ luagate_version: "0.1.0", uptime_seconds: 100, worker_count: 4 }),
    );

    await client.getStatus();

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-MCP-Client"]).toBe("claude-desktop");
  });

  it("sends X-MCP-Tool header matching tool name", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({ source_version: "v1", active_http_version: "v1", active_stream_version: "v1", etag: "v1" }),
    );

    await client.getPolicyVersions();

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-MCP-Tool"]).toBe("luagate_get_policy_versions");
  });

  it("sends X-MCP-Session-Id header", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({ luagate_version: "0.1.0", uptime_seconds: 100, worker_count: 4 }),
    );

    await client.getStatus();

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-MCP-Session-Id"]).toBe("session-abc");
  });

  it("sends X-Request-Id as UUID", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({ luagate_version: "0.1.0", uptime_seconds: 100, worker_count: 4 }),
    );

    await client.getStatus();

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-Request-Id"]).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
  });

  it("sends correct tool name for updatePolicies", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({
        previous_http_version: "v1",
        new_http_version: "v2",
        http_result: "committed",
        stream_result: "committed",
      }),
    );

    await client.updatePolicies("yaml", "v1");

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-MCP-Tool"]).toBe("luagate_update_policies");
  });

  it("sends rollback tool name for rollback operations", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({
        previous_http_version: "v2",
        new_http_version: "v1",
        http_result: "committed",
        stream_result: "committed",
      }),
    );

    await client.updatePolicies("yaml", "v2", "luagate_rollback_policies");

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-MCP-Tool"]).toBe("luagate_rollback_policies");
  });

  it("sends correct tool name for reload", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({
        previous_http_version: "v1",
        new_http_version: "v2",
        http_result: "committed",
        stream_result: "committed",
      }),
    );

    await client.reload();

    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers["X-MCP-Tool"]).toBe("luagate_reload");
  });

  it("does not send MCP headers on getHealth (no auth)", async () => {
    mockFetch.mockResolvedValueOnce(
      jsonResponse({ status: "ok", source_version: "v1" }),
    );

    await client.getHealth();

    // getHealth calls fetch directly without custom headers
    const callArgs = mockFetch.mock.calls[0];
    expect(callArgs[1]).toBeUndefined();
  });
});
