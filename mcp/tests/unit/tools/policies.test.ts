import { describe, it, expect, vi, beforeEach } from "vitest";
import { z } from "zod";
import { registerPolicyTools } from "../../../src/tools/policies.js";
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

function createMockClient() {
  return {
    getPolicies: vi.fn(),
    getPolicyVersions: vi.fn(),
    validatePolicies: vi.fn(),
    updatePolicies: vi.fn(),
    getHealth: vi.fn(),
    reload: vi.fn(),
  };
}

describe("Policy Tools", () => {
  let tools: Map<string, ToolRegistration>;
  let client: ReturnType<typeof createMockClient>;

  beforeEach(() => {
    const registry = createToolRegistry();
    client = createMockClient();
    registerPolicyTools(registry.server as never, client as never);
    tools = registry.tools;
  });

  it("registers all 5 policy tools", () => {
    expect(tools.has("luagate_get_policies")).toBe(true);
    expect(tools.has("luagate_get_policy_versions")).toBe(true);
    expect(tools.has("luagate_validate_policies")).toBe(true);
    expect(tools.has("luagate_update_policies")).toBe(true);
    expect(tools.has("luagate_rollback_policies")).toBe(true);
  });

  describe("luagate_get_policies", () => {
    it("returns YAML with ETag on success", async () => {
      client.getPolicies.mockResolvedValue({
        yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
        etag: "abc123",
      });

      const handler = tools.get("luagate_get_policies")!.handler;
      const result = (await handler({})) as { content: Array<{ text: string }> };

      expect(result.content[0].text).toContain("abc123");
      expect(result.content[0].text).toContain("version:");
    });

    it("returns error on network failure", async () => {
      client.getPolicies.mockRejectedValue(new Error("ECONNREFUSED"));

      const handler = tools.get("luagate_get_policies")!.handler;
      const result = (await handler({})) as { isError: boolean; content: Array<{ text: string }> };

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("ECONNREFUSED");
    });

    it("returns structured error on API error", async () => {
      client.getPolicies.mockRejectedValue(
        new AdminApiRequestError(401, { error: "unauthorized", message: "Invalid token" }),
      );

      const handler = tools.get("luagate_get_policies")!.handler;
      const result = (await handler({})) as { isError: boolean; content: Array<{ text: string }> };

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("401");
      expect(result.content[0].text).toContain("unauthorized");
    });
  });

  describe("luagate_get_policy_versions", () => {
    it("returns version snapshot as JSON", async () => {
      const versions = {
        source_version: "abc",
        active_http_version: "abc",
        active_stream_version: "abc",
        etag: "abc",
      };
      client.getPolicyVersions.mockResolvedValue(versions);

      const handler = tools.get("luagate_get_policy_versions")!.handler;
      const result = (await handler({})) as { content: Array<{ text: string }> };

      const parsed = JSON.parse(result.content[0].text);
      expect(parsed.source_version).toBe("abc");
    });
  });

  describe("luagate_validate_policies", () => {
    it("accepts valid YAML", async () => {
      client.validatePolicies.mockResolvedValue({
        valid: true,
        version_hash: "abc123",
        http_rules_count: 2,
        stream_rules_count: 1,
        warnings: [],
        shadowed: [],
      });

      const handler = tools.get("luagate_validate_policies")!.handler;
      const schema = tools.get("luagate_validate_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
      });

      const result = (await handler(args)) as { content: Array<{ text: string }> };
      expect(result.content[0].text).toContain("검증 성공");
      expect(result.content[0].text).toContain("abc123");
    });

    it("rejects invalid YAML with error message", async () => {
      client.validatePolicies.mockResolvedValue({
        valid: false,
        error: "validation_failed: policy is missing required 'version' field",
      });

      const handler = tools.get("luagate_validate_policies")!.handler;
      const schema = tools.get("luagate_validate_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: "global:\n  default_action: deny\n",
      });

      const result = (await handler(args)) as { isError: boolean; content: Array<{ text: string }> };
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("version");
    });
  });

  describe("luagate_update_policies", () => {
    it("blocks execution without confirm=true", async () => {
      const handler = tools.get("luagate_update_policies")!.handler;
      const schema = tools.get("luagate_update_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
        expected_source_version: "v5",
      });

      const result = (await handler(args)) as { content: Array<{ text: string }> };

      expect(client.updatePolicies).not.toHaveBeenCalled();
      expect(result.content[0].text).toContain("confirm=true");
    });

    it("executes update with confirm=true", async () => {
      client.updatePolicies.mockResolvedValue({
        previous_http_version: "v5",
        new_http_version: "v6",
        http_result: "committed",
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
      expect(client.updatePolicies).toHaveBeenCalledWith(
        expect.any(String),
        "v5",
      );
    });

    it("returns 409 conflict error", async () => {
      client.updatePolicies.mockRejectedValue(
        new AdminApiRequestError(409, {
          error: "version_mismatch",
          details: ["If-Match version mismatch"],
        }),
      );

      const handler = tools.get("luagate_update_policies")!.handler;
      const schema = tools.get("luagate_update_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: "yaml",
        expected_source_version: "wrong",
        confirm: true,
      });

      const result = (await handler(args)) as { isError: boolean; content: Array<{ text: string }> };
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("409");
    });

    it("includes health warning when post-update check fails", async () => {
      client.updatePolicies.mockResolvedValue({
        previous_http_version: "v5",
        new_http_version: "v6",
        http_result: "committed",
      });
      client.getHealth.mockResolvedValue({ status: "unhealthy", reason: "policy error" });

      const handler = tools.get("luagate_update_policies")!.handler;
      const schema = tools.get("luagate_update_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: "yaml",
        expected_source_version: "v5",
        confirm: true,
      });

      const result = (await handler(args)) as { content: Array<{ text: string }> };
      expect(result.content[0].text).toContain("Health check warning");
      expect(result.content[0].text).toContain("luagate_rollback_policies");
    });
  });

  describe("luagate_rollback_policies", () => {
    it("blocks execution without confirm=true", async () => {
      const handler = tools.get("luagate_rollback_policies")!.handler;
      const schema = tools.get("luagate_rollback_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: "yaml",
        expected_source_version: "v5",
      });

      const result = (await handler(args)) as { content: Array<{ text: string }> };
      expect(client.updatePolicies).not.toHaveBeenCalled();
      expect(result.content[0].text).toContain("confirm=true");
    });

    it("executes rollback with confirm=true using rollback tool name", async () => {
      client.updatePolicies.mockResolvedValue({
        previous_http_version: "v6",
        new_http_version: "v5",
      });

      const handler = tools.get("luagate_rollback_policies")!.handler;
      const schema = tools.get("luagate_rollback_policies")!.schema;
      const args = z.object(schema).parse({
        policy_yaml: "yaml",
        expected_source_version: "v6",
        confirm: true,
      });

      const result = (await handler(args)) as { content: Array<{ text: string }> };
      expect(result.content[0].text).toContain("롤백 성공");
      expect(client.updatePolicies).toHaveBeenCalledWith(
        "yaml",
        "v6",
        "luagate_rollback_policies",
      );
    });
  });
});
