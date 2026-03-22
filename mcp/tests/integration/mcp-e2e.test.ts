/**
 * MCP E2E Integration Tests
 *
 * These tests require a running LuaGate instance.
 * Run via: cd tests/integration && docker compose up --abort-on-container-exit
 *
 * Environment variables:
 *   LUAGATE_ADMIN_URL   - LuaGate Admin API base URL (default: http://127.0.0.1:9090)
 *   LUAGATE_ADMIN_TOKEN - Admin API bearer token
 */
import { describe, it, expect, beforeAll } from "vitest";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { AdminClient, AdminApiRequestError } from "../../src/admin-client.js";
import { registerPolicyTools } from "../../src/tools/policies.js";
import { registerStatusTools } from "../../src/tools/status.js";
import { registerReloadTools } from "../../src/tools/reload.js";

const ADMIN_URL = process.env.LUAGATE_ADMIN_URL ?? "http://127.0.0.1:9090";
const ADMIN_TOKEN = process.env.LUAGATE_ADMIN_TOKEN ?? "integration-test-token-minimum-32bytes!";

describe("MCP E2E Integration", () => {
  let client: AdminClient;

  beforeAll(() => {
    client = new AdminClient({
      baseUrl: ADMIN_URL,
      token: ADMIN_TOKEN,
      mcpClientName: "integration-test",
      mcpSessionId: "e2e-session",
    });
  });

  it("getHealth returns ok status", async () => {
    const health = await client.getHealth();
    expect(health.status).toBe("ok");
  });

  it("getStatus returns server info", async () => {
    const status = await client.getStatus();
    expect(status.worker_count).toBeGreaterThan(0);
    expect(status.luagate_version).toBeDefined();
  });

  it("getPolicies returns YAML with ETag", async () => {
    const { yaml, etag } = await client.getPolicies();
    expect(yaml).toContain("version");
    expect(etag).toBeTruthy();
  });

  it("getPolicyVersions returns version snapshot", async () => {
    const versions = await client.getPolicyVersions();
    expect(versions.source_version).toBeTruthy();
    expect(versions.active_http_version).toBeTruthy();
  });

  it("updatePolicies with wrong ETag returns 409", async () => {
    const { yaml } = await client.getPolicies();

    try {
      await client.updatePolicies(yaml, "wrong-etag-value");
      expect.fail("Should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(AdminApiRequestError);
      expect((e as AdminApiRequestError).status).toBe(409);
    }
  });

  it("full update cycle: get → update → verify version change", async () => {
    // Get current policies and ETag
    const { yaml, etag } = await client.getPolicies();

    // Update with correct ETag (re-apply same YAML — safe for integration test)
    const result = await client.updatePolicies(yaml, etag);
    expect(result.http_result).toBe("committed");
    expect(result.new_http_version).toBeTruthy();

    // Verify version changed
    const versions = await client.getPolicyVersions();
    expect(versions.source_version).toBe(result.new_http_version);
  });

  it("reload succeeds", async () => {
    const result = await client.reload();
    expect(result.http_result).toBeDefined();
  });

  it("validatePolicies performs server-side dry-run", async () => {
    const validResult = await client.validatePolicies(
      'version: "1.0"\nglobal:\n  default_action: deny\nrules: []\nstream_rules: []\n',
    );
    expect(validResult.valid).toBe(true);
    expect(validResult.version_hash).toBeDefined();

    const invalidResult = await client.validatePolicies(
      "global:\n  default_action: deny\n",
    );
    expect(invalidResult.valid).toBe(false);
    expect(invalidResult.error).toContain("version");
  });
});

describe("MCP Server Bootstrap (real Admin API)", () => {
  it("boots MCP server with real AdminClient and lists tools via InMemoryTransport", async () => {
    const adminClient = new AdminClient({
      baseUrl: ADMIN_URL,
      token: ADMIN_TOKEN,
      mcpClientName: "integration-test",
      mcpSessionId: "boot-test",
    });

    const server = new McpServer({ name: "luagate", version: "0.1.0" });
    registerPolicyTools(server, adminClient);
    registerStatusTools(server, adminClient);
    registerReloadTools(server, adminClient);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const mcpClient = new Client({ name: "test", version: "1.0.0" });

    await server.connect(serverTransport);
    await mcpClient.connect(clientTransport);

    // Verify all 7 tools are registered
    const { tools } = await mcpClient.listTools();
    expect(tools).toHaveLength(7);

    // Call a tool against the real Admin API
    const result = await mcpClient.callTool({
      name: "luagate_get_status",
      arguments: {},
    });
    const text = (result.content[0] as { text: string }).text;
    const status = JSON.parse(text);
    expect(status.worker_count).toBeGreaterThan(0);
  });
});
