# LuaGate MCP Server

LuaGate Admin API를 [MCP(Model Context Protocol)](https://modelcontextprotocol.io/) tools로 노출하는 TypeScript sidecar 서버.

AI 어시스턴트(Claude Desktop, VS Code 등)에서 자연어로 LuaGate 정책을 관리할 수 있습니다.

## 설치

```bash
cd mcp
npm install
npm run build
```

## 환경변수

| 변수 | 필수 | 기본값 | 설명 |
|------|------|--------|------|
| `LUAGATE_ADMIN_URL` | - | `http://127.0.0.1:9090` | Admin API 주소 |
| `LUAGATE_ADMIN_TOKEN` | 필수 | - | Admin API Bearer token |
| `MCP_CLIENT_NAME` | - | `unknown` | 감사 로그에 기록할 클라이언트 이름 |
| `MCP_SESSION_ID` | - | (자동 생성) | 감사 로그에 기록할 세션 ID |

## Claude Desktop 연동

`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "luagate": {
      "command": "node",
      "args": ["<path-to-luagate>/mcp/dist/index.js"],
      "env": {
        "LUAGATE_ADMIN_URL": "http://127.0.0.1:9090",
        "LUAGATE_ADMIN_TOKEN": "your-token-here"
      }
    }
  }
}
```

## VS Code MCP 연동

`.vscode/mcp.json`:

```json
{
  "servers": {
    "luagate": {
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js"],
      "env": {
        "LUAGATE_ADMIN_URL": "http://127.0.0.1:9090",
        "LUAGATE_ADMIN_TOKEN": "${env:LUAGATE_ADMIN_TOKEN}"
      }
    }
  }
}
```

## MCP Tools

| Tool | 설명 |
|------|------|
| `luagate_get_policies` | 정책 YAML + ETag 조회 |
| `luagate_get_policy_versions` | 버전 스냅샷 조회 (source/active versions) |
| `luagate_get_status` | 서버 상태 조회 (uptime, workers, reload 상태) |
| `luagate_validate_policies` | 정책 검증 (dry-run, 적용 안 함) |
| `luagate_update_policies` | 정책 업데이트 (ETag 기반 동시성 제어) |
| `luagate_rollback_policies` | 이전 정책으로 롤백 |
| `luagate_reload` | Hot reload 트리거 |

## 안전한 정책 변경 워크플로우

```
1. luagate_get_policies → 현재 정책 + ETag 확인
2. 정책 수정
3. luagate_validate_policies → dry-run 검증
4. luagate_update_policies(confirm=true) → 적용
5. 자동 health check → 실패 시 알림
```

## 감사 로그

모든 MCP tool 호출 시 Admin API 요청에 다음 헤더가 추가됩니다:

- `X-MCP-Client`: 클라이언트 이름 (예: `claude-desktop`)
- `X-MCP-Tool`: 호출된 tool 이름
- `X-MCP-Session-Id`: 세션 ID

## ADR 참조

- [ADR-011: LuaGate MCP 서버 설계](../docs/design/adr/ADR-011-mcp-server.md)
