import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { AdminClient } from "../admin-client.js";
import { AdminApiRequestError } from "../admin-client.js";

export function registerStatusTools(server: McpServer, client: AdminClient): void {
  server.tool(
    "luagate_get_status",
    "LuaGate 서버의 상세 상태를 조회합니다 (버전, uptime, worker 수, 마지막 reload 상태).",
    {},
    async () => {
      try {
        const status = await client.getStatus();
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(status, null, 2),
            },
          ],
        };
      } catch (e) {
        if (e instanceof AdminApiRequestError) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Admin API 에러 (${e.status}): ${JSON.stringify(e.apiError, null, 2)}`,
              },
            ],
            isError: true,
          };
        }
        const message = e instanceof Error ? e.message : String(e);
        return {
          content: [{ type: "text" as const, text: `에러: ${message}` }],
          isError: true,
        };
      }
    },
  );
}
