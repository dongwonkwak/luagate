import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { AdminClient } from "./admin-client.js";
import { registerPolicyTools } from "./tools/policies.js";
import { registerStatusTools } from "./tools/status.js";
import { registerReloadTools } from "./tools/reload.js";

function getConfig() {
  const baseUrl = process.env.LUAGATE_ADMIN_URL ?? "http://127.0.0.1:9090";
  const token = process.env.LUAGATE_ADMIN_TOKEN;

  if (!token) {
    console.error("LUAGATE_ADMIN_TOKEN environment variable is required");
    process.exit(1);
  }

  return {
    baseUrl,
    token,
    mcpClientName: process.env.MCP_CLIENT_NAME ?? "unknown",
    mcpSessionId: process.env.MCP_SESSION_ID ?? crypto.randomUUID(),
  };
}

async function main() {
  const config = getConfig();
  const client = new AdminClient(config);

  const server = new McpServer({
    name: "luagate",
    version: "0.1.0",
  });

  registerPolicyTools(server, client);
  registerStatusTools(server, client);
  registerReloadTools(server, client);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
