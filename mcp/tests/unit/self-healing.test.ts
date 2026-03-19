import { describe, it, expect, vi, beforeEach } from "vitest";
import { z } from "zod";
import { registerPolicyTools } from "../../src/tools/policies.js";

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

function createMockClient() {
  return {
    getPolicies: vi.fn(),
    getPolicyVersions: vi.fn(),
    validatePoliciesLocally: vi.fn(),
    updatePolicies: vi.fn(),
    getHealth: vi.fn(),
    reload: vi.fn(),
  };
}

describe("Self-healing pipeline", () => {
  let tools: Map<string, ToolRegistration>;
  let client: ReturnType<typeof createMockClient>;

  beforeEach(() => {
    const registry = createToolRegistry();
    client = createMockClient();
    registerPolicyTools(registry.server as never, client as never);
    tools = registry.tools;
  });

  it("update succeeds and health check passes — no rollback needed", async () => {
    client.updatePolicies.mockResolvedValue({
      previous_http_version: "v5",
      new_http_version: "v6",
      http_result: "committed",
      stream_result: "committed",
    });
    client.getHealth.mockResolvedValue({ status: "ok" });

    const handler = tools.get("luagate_update_policies")!.handler;
    const schema = tools.get("luagate_update_policies")!.schema;
    const args = z.object(schema).parse({
      policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
      expected_source_version: "v5",
      confirm: true,
    });

    const result = (await handler(args)) as { content: Array<{ text: string }> };

    expect(result.content[0].text).toContain("업데이트 성공");
    expect(result.content[0].text).not.toContain("Health check warning");
  });

  it("update succeeds but health check fails — warns to rollback", async () => {
    client.updatePolicies.mockResolvedValue({
      previous_http_version: "v5",
      new_http_version: "v6",
      http_result: "committed",
      stream_result: "committed",
    });
    client.getHealth.mockResolvedValue({
      status: "unhealthy",
      reason: "policy compilation failed",
    });

    const handler = tools.get("luagate_update_policies")!.handler;
    const schema = tools.get("luagate_update_policies")!.schema;
    const args = z.object(schema).parse({
      policy_yaml: "bad policy",
      expected_source_version: "v5",
      confirm: true,
    });

    const result = (await handler(args)) as { content: Array<{ text: string }> };

    expect(result.content[0].text).toContain("Health check warning");
    expect(result.content[0].text).toContain("luagate_rollback_policies");
  });

  it("update succeeds but health check fetch fails — still returns success", async () => {
    client.updatePolicies.mockResolvedValue({
      previous_http_version: "v5",
      new_http_version: "v6",
      http_result: "committed",
      stream_result: "committed",
    });
    client.getHealth.mockRejectedValue(new Error("ECONNREFUSED"));

    const handler = tools.get("luagate_update_policies")!.handler;
    const schema = tools.get("luagate_update_policies")!.schema;
    const args = z.object(schema).parse({
      policy_yaml: "yaml",
      expected_source_version: "v5",
      confirm: true,
    });

    const result = (await handler(args)) as { content: Array<{ text: string }> };

    // Health check failure is silently caught — update result still returned
    expect(result.content[0].text).toContain("업데이트 성공");
  });

  it("simulates full self-healing flow: update → health fail → rollback", async () => {
    // Step 1: Update succeeds but health check fails
    client.updatePolicies.mockResolvedValue({
      previous_http_version: "v5",
      new_http_version: "v6",
      http_result: "committed",
      stream_result: "committed",
    });
    client.getHealth.mockResolvedValue({ status: "unhealthy" });

    const updateHandler = tools.get("luagate_update_policies")!.handler;
    const updateSchema = tools.get("luagate_update_policies")!.schema;
    const updateArgs = z.object(updateSchema).parse({
      policy_yaml: "bad yaml",
      expected_source_version: "v5",
      confirm: true,
    });

    const updateResult = (await updateHandler(updateArgs)) as { content: Array<{ text: string }> };
    expect(updateResult.content[0].text).toContain("Health check warning");

    // Step 2: Agent detects warning and triggers rollback
    client.updatePolicies.mockResolvedValue({
      previous_http_version: "v6",
      new_http_version: "v5",
      http_result: "committed",
      stream_result: "committed",
    });

    const rollbackHandler = tools.get("luagate_rollback_policies")!.handler;
    const rollbackSchema = tools.get("luagate_rollback_policies")!.schema;
    const rollbackArgs = z.object(rollbackSchema).parse({
      policy_yaml: "original good yaml",
      expected_source_version: "v6",
      confirm: true,
    });

    const rollbackResult = (await rollbackHandler(rollbackArgs)) as { content: Array<{ text: string }> };
    expect(rollbackResult.content[0].text).toContain("롤백 성공");
    expect(client.updatePolicies).toHaveBeenCalledWith(
      "original good yaml",
      "v6",
      "luagate_rollback_policies",
    );
  });
});
