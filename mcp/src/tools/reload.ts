import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { AdminClient } from "../admin-client.js";
import { AdminApiRequestError } from "../admin-client.js";

export function registerReloadTools(server: McpServer, client: AdminClient): void {
  server.tool(
    "luagate_reload",
    "현재 canonical 정책 파일에서 hot reload를 트리거합니다. 운영 복구용으로 사용합니다.",
    {
      expected_active_version: z
        .string()
        .optional()
        .describe("현재 active_http_version (선택). 제공 시 불일치이면 409 Conflict"),
    },
    async ({ expected_active_version }) => {
      try {
        const result = await client.reload(expected_active_version);
        return {
          content: [
            {
              type: "text" as const,
              text: `Hot reload 성공\n\n${JSON.stringify(result, null, 2)}`,
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
