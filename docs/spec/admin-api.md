# Admin API Specification

> **ADR 참조**:
> - [ADR-003 정책 저장소 + Hot Reload](../design/adr/ADR-003-policy-storage-hot-reload.md)
> - [ADR-004 로그/메트릭 + 관리면 보안](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

Admin API는 LuaGate의 관리 인터페이스로, 정책 관리, 상태 조회, 메트릭 노출을 담당한다.

- **바인딩**: `127.0.0.1:8080` (ADR-004 §6.1)
- **인증**: Static Bearer Token (ADR-004 §6.2)
- **프로토콜**: HTTP/1.1
- **구현**: `lua/luagate/admin/`

## 2. 인증

모든 요청에 `Authorization` 헤더 필수 (GET /health 제외):

```
Authorization: Bearer <token>
```

토큰은 환경 변수 `LUAGATE_ADMIN_TOKEN`에서 로드.
인증 실패 응답:

```json
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{
  "error": "Unauthorized",
  "message": "Invalid or missing Bearer token"
}
```

인증 실패 시 감사 로그 기록 (ADR-004 §6.3).

## 3. 공통 응답 형식

```json
{
  "ok": true | false,
  "data": { ... },      // 성공 시
  "error": "...",       // 실패 시
  "message": "..."      // 실패 시 상세
}
```

## 4. 엔드포인트

### 4.1 헬스체크

```
GET /health
```

인증 불필요. 서버 기동 상태 확인용.

**응답 200:**
```json
{
  "ok": true,
  "data": {
    "status": "ok",
    "policy_version": "a3f2c1d4e5b6...",
    "uptime_seconds": 3600
  }
}
```

---

### 4.2 정책 조회

```
GET /api/v1/policies
Authorization: Bearer <token>
```

현재 활성 정책 YAML 반환.

**응답 200:**
```
Content-Type: application/x-yaml

version: "1.0"
global:
  default_action: deny
rules:
  - id: allow-health
    ...
```

---

### 4.3 정책 업데이트

```
PUT /api/v1/policies
Authorization: Bearer <token>
Content-Type: application/x-yaml

<새 정책 YAML>
```

1. Schema 검증
2. 충돌/음영 감지 (경고 수집)
3. `conf/policies.yaml` atomic write (ADR-003)
4. `staged_policy_version` 계산 (SHA256 of new policy)
5. 감사 로그 기록 (`policy_update` 이벤트, `staged_policy_version` 포함)
6. **reload는 별도로 트리거** — 이 엔드포인트는 파일만 저장하며 active_policy_version은 변경하지 않음

> **staged vs active 구분**:
> - `staged_policy_version`: `PUT /api/v1/policies`로 저장된 정책의 버전 해시. 아직 활성화되지 않음.
> - `active_policy_version`: 현재 요청을 처리하는 정책 버전. `POST /api/v1/policies/reload` 성공 후 변경됨.
>
> 저장과 활성화를 하나의 트랜잭션으로 처리하려면 `PUT /api/v1/policies?activate=true` 쿼리 파라미터를 사용한다 (저장 + 즉시 reload를 원자적으로 수행, 실패 시 rollback).

**응답 200:**
```json
{
  "ok": true,
  "data": {
    "staged_policy_version": "b4e3f2a1...",
    "active_policy_version": "a3f2c1d4...",
    "warnings": [
      {
        "type": "conflict",
        "rule_ids": ["rule-a", "rule-b"],
        "message": "same scope, priority, opposing action"
      }
    ]
  }
}
```

**응답 400 (검증 실패):**
```json
{
  "ok": false,
  "error": "ValidationError",
  "message": "rule 'my-rule': action must be 'allow' or 'deny'"
}
```

---

### 4.4 정책 리로드

```
POST /api/v1/policies/reload
Authorization: Bearer <token>
```

현재 `conf/policies.yaml`을 즉시 reload한다 (ADR-003).

**응답 200:**
```json
{
  "ok": true,
  "data": {
    "policy_version": "b4e3f2a1...",
    "reloaded_at": "2026-03-13T12:34:56Z",
    "warnings_count": 0
  }
}
```

**응답 500 (reload 실패 — last-known-good 유지):**
```json
{
  "ok": false,
  "error": "ReloadFailed",
  "message": "YAML parse error at line 42: unexpected token",
  "current_policy_version": "a3f2c1d4..."
}
```

---

### 4.5 정책 상태 조회

```
GET /api/v1/policies/status
Authorization: Bearer <token>
```

**응답 200:**
```json
{
  "ok": true,
  "data": {
    "policy_version": "a3f2c1d4...",
    "last_reload_at": "2026-03-13T12:00:00Z",
    "last_reload_status": "success",
    "rules_count": 42,
    "stream_rules_count": 5,
    "conflicts": [
      {
        "type": "conflict",
        "rule_ids": ["rule-a", "rule-b"]
      }
    ],
    "shadowed": ["narrow-allow"]
  }
}
```

---

### 4.6 메트릭 (Prometheus)

```
GET /metrics
Authorization: Bearer <token>
```

Prometheus text format (OpenMetrics 호환).

**응답 200:**
```
# HELP luagate_requests_total Total HTTP requests processed
# TYPE luagate_requests_total counter
luagate_requests_total{action="allow",method="GET",route="/api/v1/users"} 12345
luagate_requests_total{action="deny",method="GET",route="/admin"} 23

# HELP luagate_blocked_total Total blocked requests
# TYPE luagate_blocked_total counter
luagate_blocked_total{threat_type="sqli",deny_reason="policy: deny-sqli"} 145

# HELP luagate_latency_seconds Request latency
# TYPE luagate_latency_seconds histogram
luagate_latency_seconds_bucket{le="0.001"} 9000
...

# HELP luagate_active_connections Active connections
# TYPE luagate_active_connections gauge
luagate_active_connections{type="http"} 25
luagate_active_connections{type="stream"} 3
```

ADR-004 §4.3 메트릭 전체 목록 참조.

---

### 4.7 감사 로그 조회

```
GET /api/v1/audit?limit=100&since=2026-03-13T00:00:00Z
Authorization: Bearer <token>
```

**응답 200:**
```json
{
  "ok": true,
  "data": {
    "entries": [
      {
        "timestamp": "2026-03-13T12:34:56Z",
        "event": "policy_reload",
        "src_ip": "127.0.0.1",
        "trigger": "api",
        "status": "success",
        "policy_version": "b4e3f2a1..."
      }
    ],
    "total": 1
  }
}
```

## 5. CORS 설정 (ADR-004 §6.4)

```nginx
# conf/nginx.http.conf (admin server 블록)
add_header Access-Control-Allow-Origin $LUAGATE_DASHBOARD_ORIGIN always;
add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
add_header Vary "Origin" always;  # CDN/프록시 캐시가 Origin별로 응답을 구분하도록

# OPTIONS preflight는 인증(Bearer token) 없이 허용
# preflight에는 Authorization 헤더가 없으므로 auth 미들웨어에서 OPTIONS를 예외 처리해야 함
if ($request_method = 'OPTIONS') {
    add_header Access-Control-Max-Age 86400;
    return 204;
}
```

## 6. 에러 코드 표

| HTTP Status | error 문자열 | 설명 |
|------------|-------------|------|
| 400 | ValidationError | 정책 스키마 검증 실패 |
| 401 | Unauthorized | 인증 실패/누락 |
| 404 | NotFound | 존재하지 않는 엔드포인트 |
| 405 | MethodNotAllowed | 허용되지 않은 HTTP 메서드 |
| 500 | InternalError | 서버 내부 오류 |
| 500 | ReloadFailed | 정책 reload 실패 |

## 7. 의존성

- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — 정책 reload 흐름
- [ADR-004](../design/adr/ADR-004-log-metrics-admin-security.md) — 보안 설정, 감사 로그
- [spec/policy-engine.md](./policy-engine.md) — 정책 검증/평가
- [spec/log-schema.md](./log-schema.md) — 감사 로그 스키마
