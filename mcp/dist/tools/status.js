import { AdminApiRequestError } from "../admin-client.js";
export function registerStatusTools(server, client) {
    server.tool("luagate_get_status", "LuaGate 서버의 상세 상태를 조회합니다 (버전, uptime, worker 수, 마지막 reload 상태).", {}, async () => {
        try {
            const status = await client.getStatus();
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify(status, null, 2),
                    },
                ],
            };
        }
        catch (e) {
            if (e instanceof AdminApiRequestError) {
                return {
                    content: [
                        {
                            type: "text",
                            text: `Admin API 에러 (${e.status}): ${JSON.stringify(e.apiError, null, 2)}`,
                        },
                    ],
                    isError: true,
                };
            }
            const message = e instanceof Error ? e.message : String(e);
            return {
                content: [{ type: "text", text: `에러: ${message}` }],
                isError: true,
            };
        }
    });
}
//# sourceMappingURL=status.js.map
