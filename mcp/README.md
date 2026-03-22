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
        "LUAGATE_ADMIN_TOKEN": "your-token-here",
        "MCP_CLIENT_NAME": "claude-desktop"
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
        "LUAGATE_ADMIN_TOKEN": "${env:LUAGATE_ADMIN_TOKEN}",
        "MCP_CLIENT_NAME": "vscode"
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

## 연동 테스트 시나리오

### 사전 조건

```bash
# 1. .env 파일에 Admin API 토큰 설정 (최소 32바이트)
cp .env.example .env  # 또는 직접 생성
echo 'LUAGATE_ADMIN_TOKEN=your-token-here-at-least-32-bytes-long' >> .env

# 2. LuaGate 기동
make up

# 3. MCP 서버 빌드
cd mcp && npm install && npm run build
```

> **참고**: `LUAGATE_ADMIN_TOKEN`이 설정되지 않으면 `docker compose up`이 실패합니다.

### 시나리오 1 — 정책 조회

프롬프트: "현재 LuaGate 정책 보여줘"

기대 동작:
- `luagate_get_policies` tool 호출
- YAML 정책 내용 + ETag(source_version) 출력

### 시나리오 2 — IP 차단 정책 추가

프롬프트: "203.0.113.0/24 대역을 차단해줘"

> seed policy에 존재하지 않는 IP 대역을 사용하여 실제 규칙 추가를 검증합니다.

기대 동작:
1. `luagate_get_policies` → 현재 정책 + ETag 확인
2. `luagate_validate_policies` → 수정된 YAML dry-run 검증 (서버 파이프라인 실행)
3. `luagate_update_policies(confirm=true)` → 적용
4. 버전 번호(ETag) 변경 확인

### 시나리오 3 — Self-healing (잘못된 정책)

프롬프트: "version 필드를 삭제하고 정책을 업데이트해줘"

기대 동작:
- `luagate_validate_policies` → 서버 dry-run에서 422 `validation_failed` 반환
- Claude가 검증 실패를 사용자에게 안내 (예: "version 필드 누락")
- 실제 `luagate_update_policies`는 호출되지 않음 (검증 실패로 차단)
- 기존 정책(LKG)이 그대로 유지됨

> **참고**: 만약 검증을 건너뛰고 직접 update를 시도해도, Admin API가 validate
> 단계에서 422로 거부하므로 기존 정책은 변경되지 않습니다 (fail-closed).

### 시나리오 4 — 409 Conflict (동시성 충돌)

프롬프트: 오래된 `expected_source_version`으로 업데이트 시도

기대 동작:
- `Admin API 에러 (409)` 응답
- 최신 정책을 다시 조회하라는 안내

### 감사 로그 검증

> **주의**: 감사 로그는 **mutation/reload 요청**에서만 기록됩니다.
> GET 요청(`luagate_get_policies`, `luagate_get_status`)과 dry-run(`luagate_validate_policies`)은 감사 로그를 남기지 않습니다.
> 따라서 **시나리오 2(정책 업데이트)** 실행 후 검증하세요.

```bash
# Docker 환경 — 시나리오 2 실행 후
docker compose logs luagate | grep "luagate:audit"

# 확인할 MCP 메타데이터 필드 (ADR-011 §8)
# - actor_type: "mcp" (MCP 호출 시)
# - client_name: MCP_CLIENT_NAME 환경변수 값 (예: "claude-desktop")
# - tool_name: 호출된 tool 이름 (예: "luagate_update_policies")
# - session_id: MCP 세션 ID
# - request_id: UUID (X-Request-ID 헤더)
```

## 감사 로그

모든 MCP tool 호출 시 Admin API 요청에 다음 헤더가 추가됩니다:

- `X-MCP-Client`: 클라이언트 이름 (예: `claude-desktop`)
- `X-MCP-Tool`: 호출된 tool 이름
- `X-MCP-Session-Id`: 세션 ID

## ADR 참조

- [ADR-011: LuaGate MCP 서버 설계](../docs/design/adr/ADR-011-mcp-server.md)
