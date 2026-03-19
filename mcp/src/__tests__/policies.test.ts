import { describe, it, expect, vi } from "vitest";
import { z } from "zod";
import { registerPolicyTools } from "../tools/policies.js";

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

describe("registerPolicyTools", () => {
  it("requires confirm before rollback executes", async () => {
    const { server, tools } = createToolRegistry();
    const client = {
      getPolicies: vi.fn(),
      getPolicyVersions: vi.fn(),
      validatePoliciesLocally: vi.fn(),
      updatePolicies: vi.fn(),
      getHealth: vi.fn(),
    };

    registerPolicyTools(server as never, client as never);

    const rollbackTool = tools.get("luagate_rollback_policies");
    expect(rollbackTool).toBeDefined();

    const parsedArgs = z.object(rollbackTool!.schema).parse({
      policy_yaml: "version: '1.0'",
      expected_source_version: "v5",
    });

    const result = await rollbackTool!.handler(parsedArgs);

    expect(client.updatePolicies).not.toHaveBeenCalled();
    expect(result).toEqual({
      content: [
        {
          type: "text",
          text: "confirm=true를 설정해야 정책이 롤백됩니다. 롤백할 YAML과 source_version을 다시 확인하세요.",
        },
      ],
    });
  });

  it("executes rollback when confirm is true", async () => {
    const { server, tools } = createToolRegistry();
    const client = {
      getPolicies: vi.fn(),
      getPolicyVersions: vi.fn(),
      validatePoliciesLocally: vi.fn(),
      updatePolicies: vi.fn().mockResolvedValue({
        previous_http_version: "v5",
        new_http_version: "v4",
      }),
      getHealth: vi.fn(),
    };

    registerPolicyTools(server as never, client as never);

    const rollbackTool = tools.get("luagate_rollback_policies");
    expect(rollbackTool).toBeDefined();

    const parsedArgs = z.object(rollbackTool!.schema).parse({
      policy_yaml: "version: '1.0'",
      expected_source_version: "v5",
      confirm: true,
    });

    await rollbackTool!.handler(parsedArgs);

    expect(client.updatePolicies).toHaveBeenCalledWith(
      "version: '1.0'",
      "v5",
      "luagate_rollback_policies",
    );
  });
});
