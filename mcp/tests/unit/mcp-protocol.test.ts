/**
 * MCP Protocol-level tests using InMemoryTransport.
 * Verifies tool registration, request/response wiring, and transport layer.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { registerPolicyTools } from "../../src/tools/policies.js";
import { registerStatusTools } from "../../src/tools/status.js";
import { registerReloadTools } from "../../src/tools/reload.js";

function createMockClient() {
  return {
    getPolicies: vi.fn().mockResolvedValue({
      yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
      etag: "abc123",
    }),
    getPolicyVersions: vi.fn().mockResolvedValue({
      source_version: "abc",
      active_http_version: "abc",
      active_stream_version: "abc",
      etag: "abc",
    }),
    validatePolicies: vi.fn().mockResolvedValue({
      valid: true,
      version_hash: "abc123",
      http_rules_count: 2,
      stream_rules_count: 1,
      warnings: [],
      shadowed: [],
    }),
    updatePolicies: vi.fn().mockResolvedValue({
      previous_http_version: "v1",
      new_http_version: "v2",
      http_result: "committed",
      stream_result: "committed",
    }),
    getHealth: vi.fn().mockResolvedValue({ status: "ok" }),
    getStatus: vi.fn().mockResolvedValue({
      luagate_version: "0.1.0",
      uptime_seconds: 3600,
      worker_count: 4,
      active_http_version: "abc",
      active_stream_version: "abc",
      last_reload_at: "2026-03-19T00:00:00Z",
      last_reload_status: "success",
    }),
    reload: vi.fn().mockResolvedValue({
      previous_http_version: "v1",
      new_http_version: "v2",
      http_result: "committed",
      stream_result: "committed",
    }),
  };
}

describe("MCP Protocol (InMemoryTransport)", () => {
  let mcpClient: Client;
  let adminClient: ReturnType<typeof createMockClient>;

  beforeEach(async () => {
    adminClient = createMockClient();

    const server = new McpServer({ name: "luagate-test", version: "0.1.0" });
    registerPolicyTools(server, adminClient as never);
    registerStatusTools(server, adminClient as never);
    registerReloadTools(server, adminClient as never);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    mcpClient = new Client({ name: "test-client", version: "1.0.0" });
    await server.connect(serverTransport);
    await mcpClient.connect(clientTransport);
  });

  it("lists all 7 registered tools", async () => {
    const { tools } = await mcpClient.listTools();
    const toolNames = tools.map((t) => t.name).sort();

    expect(toolNames).toEqual([
      "luagate_get_policies",
      "luagate_get_policy_versions",
      "luagate_get_status",
      "luagate_reload",
      "luagate_rollback_policies",
      "luagate_update_policies",
      "luagate_validate_policies",
    ]);
  });

  it("calls luagate_get_policies via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_get_policies",
      arguments: {},
    });

    expect(result.content).toBeDefined();
    expect(result.content).toHaveLength(1);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("abc123");
    expect(text).toContain("version:");
  });

  it("calls luagate_get_status via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_get_status",
      arguments: {},
    });

    const text = (result.content[0] as { text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed.worker_count).toBe(4);
  });

  it("calls luagate_validate_policies via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_validate_policies",
      arguments: {
        policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
      },
    });

    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("검증 성공");
  });

  it("calls luagate_update_policies — blocks without confirm", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_update_policies",
      arguments: {
        policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
        expected_source_version: "v1",
      },
    });

    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("confirm=true");
    expect(adminClient.updatePolicies).not.toHaveBeenCalled();
  });

  it("calls luagate_update_policies with confirm=true via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_update_policies",
      arguments: {
        policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
        expected_source_version: "v1",
        confirm: true,
      },
    });

    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("업데이트 성공");
    expect(adminClient.updatePolicies).toHaveBeenCalled();
  });

  it("calls luagate_rollback_policies with confirm=true via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_rollback_policies",
      arguments: {
        policy_yaml: 'version: "1.0"\nglobal:\n  default_action: deny\n',
        expected_source_version: "v1",
        confirm: true,
      },
    });

    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("롤백 성공");
    expect(adminClient.updatePolicies).toHaveBeenCalledWith(
      expect.any(String),
      "v1",
      "luagate_rollback_policies",
    );
  });

  it("calls luagate_reload via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_reload",
      arguments: {},
    });

    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("reload 성공");
  });

  it("calls luagate_get_policy_versions via MCP protocol", async () => {
    const result = await mcpClient.callTool({
      name: "luagate_get_policy_versions",
      arguments: {},
    });

    const text = (result.content[0] as { text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed.source_version).toBe("abc");
  });
});
