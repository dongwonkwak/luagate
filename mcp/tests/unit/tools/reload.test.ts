import { describe, it, expect, vi, beforeEach } from "vitest";
import { z } from "zod";
import { registerReloadTools } from "../../../src/tools/reload.js";
import { AdminApiRequestError } from "../../../src/admin-client.js";

type ToolRegistration = {
  description: string;
  schema: Record<string, z.ZodTypeAny>;
  handler: (args: Record<string, unknown>) => Promise<unknown>;
};

function createToolRegistry() {
  const tools = new Map<string, ToolRegistration>();
  const server = {
    tool(
      name: string,
      description: string,
      schema: Record<string, z.ZodTypeAny>,
      handler: (args: Record<string, unknown>) => Promise<unknown>,
    ) {
      tools.set(name, { description, schema, handler });
    },
  };
  return { server, tools };
}

describe("Reload Tools", () => {
  let tools: Map<string, ToolRegistration>;
  let client: { reload: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    const registry = createToolRegistry();
    client = { reload: vi.fn() };
    registerReloadTools(registry.server as never, client as never);
    tools = registry.tools;
  });

  it("registers luagate_reload tool", () => {
    expect(tools.has("luagate_reload")).toBe(true);
  });

  it("succeeds without expected_active_version", async () => {
    const reloadResult = {
      previous_http_version: "v5",
      previous_stream_version: "v5",
      new_http_version: "v6",
      new_stream_version: "v6",
      http_result: "committed",
      stream_result: "committed",
      reloaded_at: "2026-03-19T00:00:00Z",
    };
    client.reload.mockResolvedValue(reloadResult);

    const handler = tools.get("luagate_reload")!.handler;
    const schema = tools.get("luagate_reload")!.schema;
    const args = z.object(schema).parse({});

    const result = (await handler(args)) as { content: Array<{ text: string }> };
    expect(result.content[0].text).toContain("reload 성공");
    expect(client.reload).toHaveBeenCalledWith(undefined);
  });

  it("passes expected_active_version when provided", async () => {
    client.reload.mockResolvedValue({
      previous_http_version: "v5",
      new_http_version: "v6",
      http_result: "committed",
      stream_result: "committed",
    });

    const handler = tools.get("luagate_reload")!.handler;
    const schema = tools.get("luagate_reload")!.schema;
    const args = z.object(schema).parse({ expected_active_version: "v5" });

    await handler(args);
    expect(client.reload).toHaveBeenCalledWith("v5");
  });

  it("returns 409 conflict on version mismatch", async () => {
    client.reload.mockRejectedValue(
      new AdminApiRequestError(409, {
        error: "version_mismatch",
        details: ["expected v5 but active is v6"],
      }),
    );

    const handler = tools.get("luagate_reload")!.handler;
    const schema = tools.get("luagate_reload")!.schema;
    const args = z.object(schema).parse({ expected_active_version: "v5" });

    const result = (await handler(args)) as { isError: boolean; content: Array<{ text: string }> };
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("409");
  });

  it("returns generic error on network failure", async () => {
    client.reload.mockRejectedValue(new Error("ECONNREFUSED"));

    const handler = tools.get("luagate_reload")!.handler;
    const schema = tools.get("luagate_reload")!.schema;
    const args = z.object(schema).parse({});

    const result = (await handler(args)) as { isError: boolean; content: Array<{ text: string }> };
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("ECONNREFUSED");
  });
});
