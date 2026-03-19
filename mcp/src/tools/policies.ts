import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { AdminClient } from "../admin-client.js";
import { AdminApiRequestError } from "../admin-client.js";

export function registerPolicyTools(server: McpServer, client: AdminClient): void {
  // luagate_get_policies — 정책 YAML + ETag 조회
  server.tool(
    "luagate_get_policies",
    "현재 정책 YAML과 ETag(source_version)을 조회합니다. 정책 수정 전 반드시 호출하여 expected_source_version을 확보하세요.",
    {},
    async () => {
      try {
        const { yaml, etag } = await client.getPolicies();
        return {
          content: [
            {
              type: "text" as const,
              text: `ETag (source_version): ${etag}\n\n---\n\n${yaml}`,
            },
          ],
        };
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  // luagate_get_policy_versions — 버전 이력 조회
  server.tool(
    "luagate_get_policy_versions",
    "현재 정책 버전 스냅샷을 조회합니다 (source_version, active_http_version, active_stream_version).",
    {},
    async () => {
      try {
        const versions = await client.getPolicyVersions();
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(versions, null, 2),
            },
          ],
        };
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  // luagate_validate_policies — Dry-run 검증
  server.tool(
    "luagate_validate_policies",
    "정책 YAML을 검증합니다 (dry-run). 실제 적용하지 않고 문법/충돌 검사만 수행합니다.",
    {
      policy_yaml: z
        .string()
        .describe("검증할 정책 YAML 문자열"),
    },
    async ({ policy_yaml }) => {
      const result = client.validatePoliciesLocally(policy_yaml);
      if (result.valid) {
        return {
          content: [
            {
              type: "text" as const,
              text: "검증 성공: YAML 구조가 유효합니다.\n\n참고: 현재 로컬 구문 검증만 수행합니다. 서버 측 충돌 감지/컴파일 검증은 luagate_update_policies 호출 시 수행됩니다.",
            },
          ],
        };
      }
      return {
        content: [
          {
            type: "text" as const,
            text: `검증 실패: ${result.error}`,
          },
        ],
        isError: true,
      };
    },
  );

  // luagate_update_policies — 정책 업데이트
  server.tool(
    "luagate_update_policies",
    "정책을 업데이트합니다. 반드시 luagate_get_policies로 현재 ETag를 먼저 확인하세요. confirm=true일 때만 실행됩니다.",
    {
      policy_yaml: z
        .string()
        .describe("새 정책 YAML 문자열"),
      expected_source_version: z
        .string()
        .describe("luagate_get_policies에서 받은 ETag 값 (낙관적 동시성 제어)"),
      confirm: z
        .boolean()
        .optional()
        .default(false)
        .describe("true로 설정해야 실제 업데이트를 실행합니다"),
    },
    async ({ policy_yaml, expected_source_version, confirm }) => {
      if (!confirm) {
        return {
          content: [
            {
              type: "text" as const,
              text: "confirm=true를 설정해야 정책이 업데이트됩니다. 먼저 luagate_validate_policies로 검증하세요.",
            },
          ],
        };
      }

      try {
        const result = await client.updatePolicies(
          policy_yaml,
          expected_source_version,
        );

        // Self-healing: health check after update
        try {
          const health = await client.getHealth();
          if (health.status !== "ok") {
            // Auto-rollback attempt
            return {
              content: [
                {
                  type: "text" as const,
                  text: `정책 업데이트 후 health check 실패 (status: ${health.status}). 수동 롤백이 필요할 수 있습니다.\n\n업데이트 결과:\n${JSON.stringify(result, null, 2)}`,
                },
              ],
              isError: true,
            };
          }
        } catch {
          // Health check itself failed — report but don't fail the update
        }

        return {
          content: [
            {
              type: "text" as const,
              text: `정책 업데이트 성공\n\n${JSON.stringify(result, null, 2)}`,
            },
          ],
        };
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  // luagate_rollback_policies — 롤백
  server.tool(
    "luagate_rollback_policies",
    "이전 정책 YAML로 롤백합니다. 롤백할 YAML과 현재 source_version이 필요합니다.",
    {
      policy_yaml: z
        .string()
        .describe("롤백할 이전 정책 YAML"),
      expected_source_version: z
        .string()
        .describe("현재 source_version (낙관적 동시성 제어)"),
    },
    async ({ policy_yaml, expected_source_version }) => {
      try {
        const result = await client.updatePolicies(
          policy_yaml,
          expected_source_version,
          "luagate_rollback_policies",
        );
        return {
          content: [
            {
              type: "text" as const,
              text: `정책 롤백 성공\n\n${JSON.stringify(result, null, 2)}`,
            },
          ],
        };
      } catch (e) {
        return errorResult(e);
      }
    },
  );
}

function errorResult(e: unknown) {
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
