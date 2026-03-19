import { describe, it, expect, vi, beforeEach } from "vitest";
import { registerStatusTools } from "../../../src/tools/status.js";
import { AdminApiRequestError } from "../../../src/admin-client.js";

type ToolRegistration = {
  description: string;
  schema: Record<string, unknown>;
  handler: (args: Record<string, unknown>) => Promise<unknown>;
};

function createToolRegistry() {
  const tools = new Map<string, ToolRegistration>();
  const server = {
    tool(
      name: string,
      description: string,
      schema: Record<string, unknown>,
      handler: (args: Record<string, unknown>) => Promise<unknown>,
    ) {
      tools.set(name, { description, schema, handler });
    },
  };
  return { server, tools };
}

describe("Status Tools", () => {
  let tools: Map<string, ToolRegistration>;
  let client: { getStatus: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    const registry = createToolRegistry();
    client = { getStatus: vi.fn() };
    registerStatusTools(registry.server as never, client as never);
    tools = registry.tools;
  });

  it("registers luagate_get_status tool", () => {
    expect(tools.has("luagate_get_status")).toBe(true);
  });

  it("returns status as formatted JSON", async () => {
    const statusData = {
      luagate_version: "0.1.0",
      uptime_seconds: 3600,
      worker_count: 4,
      active_http_version: "abc123",
      active_stream_version: "abc123",
      last_reload_at: "2026-03-19T00:00:00Z",
      last_reload_status: "success",
    };
    client.getStatus.mockResolvedValue(statusData);

    const handler = tools.get("luagate_get_status")!.handler;
    const result = (await handler({})) as { content: Array<{ text: string }> };

    const parsed = JSON.parse(result.content[0].text);
    expect(parsed.worker_count).toBe(4);
    expect(parsed.luagate_version).toBe("0.1.0");
  });

  it("returns error on API failure", async () => {
    client.getStatus.mockRejectedValue(
      new AdminApiRequestError(500, { error: "internal", message: "server error" }),
    );

    const handler = tools.get("luagate_get_status")!.handler;
    const result = (await handler({})) as { isError: boolean; content: Array<{ text: string }> };

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("500");
  });

  it("returns error on network failure", async () => {
    client.getStatus.mockRejectedValue(new Error("fetch failed"));

    const handler = tools.get("luagate_get_status")!.handler;
    const result = (await handler({})) as { isError: boolean; content: Array<{ text: string }> };

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("fetch failed");
  });
});
