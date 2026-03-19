# ADR-011: LuaGate MCP 서버 설계

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-19 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-190](https://linear.app/dongwon/issue/DON-190) |
| **Depends on** | [ADR-004](./ADR-004-log-metrics-admin-security.md), [ADR-005](./ADR-005-policy-activation-concurrency.md) |

---

## Status

**Accepted** -- LuaGate Admin API를 MCP(Model Context Protocol) 서버로 노출하여 AI 어시스턴트에서 자연어로 정책 관리가 가능하도록 한다.

---

## Context

AI 코딩 에이전트와 IDE 통합(Claude Desktop, VS Code 등)이 확산되면서, LuaGate Admin API를 MCP Tool로 노출하면 자연어 기반 정책 관리가 가능해진다.

### 배경

- 2026년 MCP 로드맵: Streamable HTTP transport, enterprise readiness 강화
- Anthropic이 MCP를 Linux Foundation에 기증 (2025.12)
- OpenAI, Google, Microsoft 등 주요 벤더 채택
- LuaGate는 이미 REST Admin API를 갖추고 있어 MCP 래핑이 자연스러움

### 요구사항

1. AI 어시스턴트에서 정책 조회/수정/검증/롤백 가능
2. Blind overwrite 방지 (낙관적 동시성 제어)
3. 감사 로그에 MCP 호출 메타데이터 기록
4. 기존 Admin API 인증 체계 재사용

---

## Decision

### 1. Transport 방식

| 옵션 | 채택 | 이유 |
|------|------|------|
| **stdio** | 1순위 | 로컬 배포 기본, 가장 단순하고 안전 |
| Streamable HTTP | 2순위 | 원격 접근 필요 시 확장 |
| ~~SSE~~ | 제외 | MCP spec에서 deprecated |

**결정**: stdio를 기본 transport로 채택. 원격 필요 시 Streamable HTTP 추가.

> **인증 경계**: Streamable HTTP 활성화 시 ADR-004 §6의 localhost 바인딩 전제가 깨진다. 원격 transport 도입 전 반드시 별도 ADR에서 mTLS 또는 OAuth 인증 경계를 정의해야 한다. stdio-only v1에서는 이 문제가 발생하지 않는다.

### 2. 구현 언어

| 옵션 | 채택 | 이유 |
|------|------|------|
| **TypeScript/Node** | 1순위 | 공식 Tier 1 SDK, 저장소에 Node tooling 이미 존재 (ui/) |
| Python | 2순위 | 공식 SDK 있지만 런타임 추가 필요 |
| ~~Lua~~ | 제외 | 공식 SDK 없음, 유지보수 비용 과다 |

**결정**: TypeScript sidecar 프로세스로 구현.

### 3. 배포 방식

- **별도 프로세스 sidecar** (OpenResty와 분리)
- 로컬: stdio transport로 직접 실행
- Docker: 같은 컨테이너 내 프로세스 매니저 또는 Docker Compose 서비스 분리

### 4. 통신 방식 (MCP ↔ OpenResty)

| 옵션 | 채택 | 이유 |
|------|------|------|
| **UDS (Unix Domain Socket)** | 권장 | 네트워크 오버헤드 없이 OpenResty ↔ MCP 서버 통신 |
| TCP localhost | 대안 | UDS 미지원 환경용 |

**결정**: v1은 localhost HTTP (`127.0.0.1:9090`) 사용 (기존 Admin API 계약 그대로). UDS는 성능 최적화가 필요한 경우 향후 검토.

### 5. 인증

- v1: 기존 Admin API Bearer token 재사용 (ADR-004 §6)
- OAuth는 다중 사용자 원격 배포 시 재검토

### 6. MCP Tools (7개)

| Tool | Admin API 매핑 | 설명 |
|------|---------------|------|
| `luagate_get_policies` | GET /api/v1/policies | 정책 YAML + ETag 조회 |
| `luagate_get_policy_versions` | GET /api/v1/policies/version | 현재 시점 버전 스냅샷 조회 (source_version, active_http_version, active_stream_version) |
| `luagate_get_status` | GET /api/v1/status | 상태 + active_version + worker 수 |
| `luagate_validate_policies` | PUT /api/v1/policies?dry_run=true | Dry-run: 문법/충돌 검증만, 적용 안 함 (**Admin API 확장 필요** — DON-191에서 구현) |
| `luagate_update_policies` | PUT /api/v1/policies | 정책 업데이트 (`expected_source_version` 필수, MCP 서버는 이를 `If-Match` 헤더로 변환) |
| `luagate_rollback_policies` | PUT /api/v1/policies (이전 YAML + expected_source_version) | 이전 버전 YAML로 복원 (**기존 PUT 재사용**, `expected_source_version`은 `If-Match` 헤더로 변환, 이전 YAML은 클라이언트 세션 캐시 또는 향후 버전 이력 API에서 확보) |
| `luagate_reload` | POST /api/v1/policies/reload | Hot reload (운영 복구용) |

### 7. Blind Overwrite 방지

`luagate_update_policies`는 반드시 `expected_source_version` 파라미터를 요구하며, MCP 서버는 이를 `PUT /api/v1/policies`의 `If-Match` 헤더로 전달해야 한다. 동일한 PUT 기반 도구인 `luagate_rollback_policies`에도 같은 매핑을 적용한다:

1. 먼저 `luagate_get_policies`로 현재 ETag 조회
2. 수정 후 `expected_source_version`과 함께 업데이트
3. 버전 불일치 시 409 Conflict 반환

```
AI Agent flow:
  get_policies → { yaml, etag: "v5" }
  (사용자와 수정 논의)
  update_policies { yaml: "...", expected_source_version: "v5" }
  → 200 OK (v5 → v6)

  만약 다른 사용자가 v5→v6으로 업데이트한 경우:
  update_policies { yaml: "...", expected_source_version: "v5" }
  → 409 Conflict
```

### 8. 감사 로그 확장

MCP 호출 시 감사 로그에 추가 메타데이터:

```json
{
  "actor_type": "mcp",
  "client_name": "claude-desktop",
  "tool_name": "luagate_update_policies",
  "session_id": "...",
  "request_id": "..."
}
```

기존 Admin API 직접 호출은 `actor_type: "api"` (하위 호환 기본값).

> **스키마 동기화**: 위 필드 추가는 DON-191 (MCP 구현) 시 `docs/spec/admin-api.md` 감사 로그 섹션과 `docs/spec/log-schema.md` audit 필드에 동시 반영해야 한다 (same-PR 규칙). 이 ADR은 스키마 방향만 확정하며, spec 갱신은 구현 이슈에서 수행한다.

---

## Alternatives Considered

### A. OpenResty 내장 MCP

Lua로 MCP 프로토콜을 직접 구현하여 OpenResty 프로세스 내에서 실행.

**기각 이유**: 공식 Lua SDK 없음, MCP spec 변경 시 직접 유지보수 부담, OpenResty 이벤트 루프에 부하 추가.

### B. Rust sidecar

Rust로 MCP 서버 구현.

**기각 이유**: MCP Rust SDK는 비공식이며 성숙도 낮음. 빌드 복잡도 증가. MCP 서버는 I/O 바운드이므로 Rust의 성능 이점이 미미.

### C. Python sidecar

Python FastMCP로 구현.

**기각 이유**: 공식 SDK 존재하나 Python 런타임 추가 필요. 저장소에 Python tooling 없음. TypeScript 대비 타입 안전성 열위.

---

## Consequences

### 긍정적

- AI 어시스턴트에서 자연어로 정책 관리 가능 (포트폴리오 차별화)
- expected_source_version으로 안전한 정책 변경 보장
- 감사 로그에 MCP 메타데이터 추적 가능
- 기존 Admin API 위에 thin wrapper이므로 유지보수 부담 최소

### 부정적

- Node.js 런타임 의존성 추가 (이미 ui/ 빌드에서 사용 중이므로 영향 제한적)
- sidecar 프로세스 관리 복잡도 (Docker Compose로 완화)
- Admin API 스키마 변경 시 MCP Tool 스키마도 동기화 필요

### 향후 과제

- `luagate_validate_policies` dry-run 엔드포인트 Admin API에 추가 (현재 미존재)
- Streamable HTTP transport 구현 (원격 접근 필요 시)
- MCP Resources 노출 검토 (정책 YAML을 Resource로 노출)

---

## References

- [MCP 공식 문서](https://modelcontextprotocol.io/)
- [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP Transports spec](https://spec.modelcontextprotocol.io/specification/basic/transports/)
- [ADR-004: 로그/메트릭 + Admin 보안](./ADR-004-log-metrics-admin-security.md)
- [ADR-005: 정책 활성화 + 동시성](./ADR-005-policy-activation-concurrency.md)
