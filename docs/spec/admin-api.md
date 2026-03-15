# Admin API Specification

> **ADR 참조**:
>
> - [ADR-003 정책 저장소 + Hot Reload](../design/adr/ADR-003-policy-storage-hot-reload.md)
> - [ADR-004 로그/메트릭 + 관리면 보안](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

Admin API는 LuaGate의 관리 인터페이스로, 정책 관리, 상태 조회, 메트릭 노출을 담당한다.

- **바인딩**: `127.0.0.1:8080` (ADR-004 §6.1) — server block identity로 data plane과 분리
- **인증**: Static Bearer Token (ADR-004 §6.2)
- **프로토콜**: HTTP/1.1
- **구현**: `lua/luagate/admin/`
- **CORS**: 기본 off. 필요 시 explicit origin allowlist로만 활성화

## 2. 인증

모든 요청에 `Authorization` 헤더 필수 (`GET /health` 제외 — 아래 각 엔드포인트 참조):

```http
Authorization: Bearer <token>
```

**Static token 관리 규칙**:

- 환경변수 `LUAGATE_ADMIN_TOKEN` 또는 파일(마운트) 방식으로 주입
- 최소 32바이트 entropy (256-bit random)
- 재기동 없는 교체: **Phase 2** (현재는 재기동 필요)
- 토큰은 로그/응답 바디에 절대 포함하지 않음

인증 실패 응답:

```json
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error": "unauthorized", "stage": "auth", "details": ["missing or invalid bearer token"]}
```

인증 실패 시 감사 로그 기록 (ADR-004 §6.3).

## 3. 에러 응답 Contract

모든 에러 응답의 JSON body shape:

```json
{
  "error": "<snake_case_error_code>",
  "stage": "<pipeline_stage>",
  "details": ["<detail_message>", ...]
}
```

| error 코드 | stage | HTTP 상태 |
| --- | --- | --- |
| `unauthorized` | `auth` | 401 |
| `validation_failed` | `validate` | 422 |
| `conflict_detected` | `conflict_detect` | 422 |
| `compile_failed` | `compile` | 422 |
| `commit_failed` | `commit` | 500 |
| `reload_failed` | `reload` | 500 |
| `version_mismatch` | `reload` | 409 |
| `reload_in_progress` | `reload` | 409 |
| `audit_write_failed` | `audit` | 500 |
| `not_found` | `routing` | 404 |
| `method_not_allowed` | `routing` | 405 |
| `payload_too_large` | `request` | 413 |
| `internal_error` | `internal` | 500 |

> **감사 기록 실패 시**: mutation/reload를 **거부**한다. `audit_write_failed` 에러 반환.
> ADR-004 드롭 비허용 원칙: 감사 로그 없이 상태 변경 불가.

## 4. PUT vs POST /reload 상태 머신

**확정된 설계:**

| 엔드포인트 | 동작 | If-Match |
| --- | --- | --- |
| `PUT /api/v1/policies` | source 저장(canonical file write) + validate + commit까지 **전체 파이프라인** | **필수** (`<source_version>` 형식 — `GET /api/v1/policies` ETag와 동일) |
| `POST /api/v1/policies/reload` | 현재 canonical file에서 reload 트리거만 | 선택 (`<http_active_version>` 형식) |

> **PUT /api/v1/policies**: 저장 + validate + conflict_detect + compile + commit을 한 번에 수행.
> 실패 시 canonical file을 변경하지 않는다. Partial commit은 §policy-engine.md commit 단계 규칙 따름.

## 5. ETag / If-Match

- `GET /api/v1/policies` 응답에 `ETag: "<source_version>"` 포함
  - `source_version`은 canonical source 파일(conf/policies.yaml) 전체 raw bytes의 SHA256이다.
  - 응답 본문이 canonical source 파일을 그대로 반환하므로, ETag validator는 `source_version` 기준이다.
- `PUT /api/v1/policies` 요청에 `If-Match: "<source_version>"` 필수 (`GET /api/v1/policies` ETag와 동일 기준)
  - 불일치 시 → `409 Conflict` + `error: "version_mismatch"`
- `POST /api/v1/policies/reload`에 `If-Match` 선택. 제공 시 `http:active_version`과 비교하여 불일치이면 `409 Conflict`
  - 불일치 시 → `error: "version_mismatch"`
- **ETag / If-Match 기준값 분리**:
  - `GET /api/v1/policies` ETag, `PUT /api/v1/policies` If-Match: `source_version`
  - `POST /api/v1/policies/reload` If-Match: `http:active_version`
  - Stream active_version은 If-Match 비교 대상이 아님 (조회 전용: `GET /api/v1/policies/version` 응답 참조)

## 6. 엔드포인트

### 6.1 헬스체크 (Liveness)

```http
GET /health
```

**인증 불필요**. 서버 liveness 확인용. 상세 정보 미포함.

**응답 200:**

```json
{"status": "ok"}
```

**응답 503** (unhealthy):

```json
{"status": "unhealthy", "reason": "policy not loaded"}
```

---

### 6.2 서버 상태 (Detailed Status)

```http
GET /api/v1/status
Authorization: Bearer <token>
```

상세 정보: worker 수, 버전, uptime, policy version.

**응답 200:**

```json
{
  "luagate_version": "0.1.0",
  "uptime_seconds": 3600,
  "worker_count": 4,
  "active_http_version": "a3f2c1d4...",
  "active_stream_version": "b4e3f2a1...",
  "last_reload_at": "2026-03-14T07:00:00Z",
  "last_reload_status": "success"
}
```

---

### 6.3 정책 조회

```http
GET /api/v1/policies
Authorization: Bearer <token>
```

현재 canonical source (`conf/policies.yaml`) 반환.

> **ETag 기준값**: `source_version` (canonical source 파일 전체 raw bytes의 SHA256). `PUT /api/v1/policies` If-Match와 동일 기준이다.
>
> **YAML schema**: HTTP 규칙은 top-level `rules:` 키, 스트림 규칙은 top-level `stream_rules:` 키를 사용한다 (flat 구조 — `http.rules`/`stream.rules` 중첩 아님). 상세: [policy-engine.md §2.0](./policy-engine.md#20-top-level-canonical-schema) 참조.

**응답 200:**

```http
Content-Type: application/x-yaml
ETag: "a3f2c1d4..."

version: "1.0"
global:
  default_action: deny
rules:                    # HTTP 규칙 (flat top-level key)
  - id: allow-health
    ...
stream_rules:             # 스트림 규칙 (flat top-level key)
  - id: allow-tls-443
    ...
```

---

### 6.4 정책 버전 조회

```http
GET /api/v1/policies/version
Authorization: Bearer <token>
```

**응답 200:**

```json
{
  "source_version": "b4e3f2a1...",
  "active_http_version": "a3f2c1d4...",
  "active_stream_version": "a3f2c1d4...",
  "etag": "b4e3f2a1..."
}
```

> **etag 기준**: `GET /api/v1/policies`의 ETag와 동일하게 `source_version`을 기준으로 한다. `active_http_version`/`active_stream_version`과 값이 다를 수 있다 (활성 버전은 reload 결과, source_version은 현재 canonical 파일 기준).

---

### 6.5 정책 업데이트 (전체 파이프라인)

```http
PUT /api/v1/policies
Authorization: Bearer <token>
Content-Type: application/x-yaml
Content-Length: <bytes>
If-Match: "<source_version>"

<새 정책 YAML>
```

**요청 제한**:

- `Content-Length` 최대 1MB. 초과 시 → 413 `payload_too_large`
- charset: UTF-8 only. BOM 미허용
- 압축 미허용 (`Content-Encoding` 거부)

처리 순서: [1] If-Match 확인 → [2] parse → [3] validate → [4] conflict_detect → [5] hash(SHA256) → [6] compile → [7] audit write → [8] commit + canonical file write

> **hash 단계**: [5]에서 업로드된 YAML 전체의 SHA256을 계산하여 new_version으로 사용. If-Match 불일치가 있으면 [1]에서 409 반환.
> **policy-engine.md와의 관계**: 파일 기반 reload(`POST /reload`)는 policy-engine.md §4.1의 7단계를 그대로 따른다. PUT의 [1] If-Match / [7] audit / [8] commit+file-write는 API 전용 단계다.

**응답 200 (성공):**

```json
{
  "previous_http_version": "a3f2c1d4...",
  "previous_stream_version": "a3f2c1d4...",
  "new_http_version": "b4e3f2a1...",
  "new_stream_version": "b4e3f2a1...",
  "http_result": "committed",
  "stream_result": "committed",
  "warnings": [
    {
      "type": "conflict",
      "rule_ids": ["rule-a", "rule-b"],
      "message": "same scope, priority, opposing action"
    }
  ]
}
```

**응답 422 (검증 실패):**

```json
{
  "error": "validation_failed",
  "stage": "validate",
  "details": ["rule 'my-rule': action must be 'allow' or 'deny'"]
}
```

**응답 409 (If-Match 불일치):**

```json
{
  "error": "version_mismatch",
  "stage": "reload",
  "details": ["If-Match version mismatch: expected a3f2c1d4, got b4e3f2a1"]
}
```

---

### 6.6 정책 리로드

```http
POST /api/v1/policies/reload
Authorization: Bearer <token>
If-Match: "<http_active_version>"   (선택 — 제공 시 http:active_version과 비교)
```

현재 `conf/policies.yaml`에서 reload 트리거 (ADR-003).

**응답 200:**

```json
{
  "previous_http_version": "a3f2c1d4...",
  "previous_stream_version": "a3f2c1d4...",
  "new_http_version": "b4e3f2a1...",
  "new_stream_version": "b4e3f2a1...",
  "http_result": "committed",
  "stream_result": "committed",
  "reloaded_at": "2026-03-14T07:00:00Z",
  "warnings_count": 0,
  "errors": []
}
```

**응답 500 (reload 실패 — LKG 유지):**

```json
{
  "error": "reload_failed",
  "stage": "reload",
  "details": ["parse error at line 42: unexpected token"],
  "current_http_version": "a3f2c1d4...",
  "current_stream_version": "a3f2c1d4..."
}
```

> **stage 값**: §3 에러 Contract에 따라 `reload_failed`의 stage는 `"reload"`다. 실패가 발생한 내부 단계(parse/validate/compile 등)는 `details` 배열 메시지에 기술한다.

**응답 409 (동시 reload 충돌):**

```json
{
  "error": "reload_in_progress",
  "stage": "reload",
  "details": ["another reload is already in progress"]
}
```

---

### 6.7 정책 상태 조회

```http
GET /api/v1/policies/status
Authorization: Bearer <token>
```

**응답 200:**

```json
{
  "active_http_version": "a3f2c1d4...",
  "active_stream_version": "a3f2c1d4...",
  "source_version": "b4e3f2a1...",
  "last_reload_at": "2026-03-14T07:00:00Z",
  "last_reload_status": "success",
  "http_rules_count": 42,
  "stream_rules_count": 5,
  "conflicts": [
    {"type": "conflict", "rule_ids": ["rule-a", "rule-b"]}
  ],
  "shadowed": ["narrow-allow"]
}
```

---

### 6.8 메트릭 (Prometheus)

```http
GET /metrics
```

**인증**: Bearer auth 적용. (GET /health와 달리 인증 필요)

Prometheus text format (OpenMetrics 호환).

**응답 200:**

```text
# HELP luagate_http_requests_total Total HTTP requests processed
# TYPE luagate_http_requests_total counter
luagate_http_requests_total{action="allow"} 12345
luagate_http_requests_total{action="deny"} 23

# HELP luagate_active_connections Active connections
# TYPE luagate_active_connections gauge
luagate_active_connections{type="http"} 25
luagate_active_connections{type="stream"} 3

# HELP luagate_shared_dict_capacity_bytes Shared dict capacity
# TYPE luagate_shared_dict_capacity_bytes gauge
luagate_shared_dict_capacity_bytes{zone="luagate_policy"} 10485760
luagate_shared_dict_free_bytes{zone="luagate_policy"} 8388608
```

log-schema.md §7 메트릭 전체 목록 참조.

---

### 6.9 감사 로그 조회

```http
GET /api/v1/audit?offset=0&limit=100&since=2026-03-13T00:00:00Z&until=2026-03-14T00:00:00Z
Authorization: Bearer <token>
```

**쿼리 파라미터**:

- `offset`: 건너뛸 항목 수 (기본 0)
- `limit`: 최대 반환 항목 수 (기본 100, 최대 1000)
- `since`: 시작 시각 (ISO-8601 UTC, 포함)
- `until`: 종료 시각 (ISO-8601 UTC, 미포함)

**응답 200:**

```json
{
  "entries": [
    {
      "timestamp": "2026-03-14T07:00:00Z",
      "event": "policy_reload_success",
      "actor_ip": "127.0.0.1",
      "trigger": "api",
      "previous_version": "a3f2c1d4...",
      "new_version": "b4e3f2a1...",
      "subsystem": "http"
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 100
}
```

## 7. 감사 로그 (audit.log) 섹션

감사 로그 상세 스키마: [log-schema.md §5](./log-schema.md#5-감사-로그-auditlog-adr-004-63)

역방향 참조: [policy-engine.md §6 Reload Audit Log](./policy-engine.md#6-reload-audit-log) ↔ 이 섹션은 감사 로그 필드 및 드롭 금지 원칙을 공유한다.

> **감사 로그 드롭 금지**: audit 기록 실패 = mutation/reload 거부.
> 이 규칙은 코드 불변식이며 설정으로 우회 불가.

### Reload 이벤트 Audit Log Shape

reload 성공/실패/partial 각 경우의 감사 로그 엔트리 shape:

**성공 (event: "policy_reload_success")**:

```json
{
  "timestamp": "2026-03-14T07:00:00Z",
  "event": "policy_reload_success",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "previous_version": "a3f2c1d4...",
  "new_version": "b4e3f2a1...",
  "subsystem": "http"
}
```

> `trigger`: `"api"` (POST /reload) 또는 `"hup"` (SIGHUP). 상세 스키마: log-schema.md §5.1.

**실패 (event: "policy_reload_failure")**:

```json
{
  "timestamp": "2026-03-14T07:00:00Z",
  "event": "policy_reload_failure",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "stage": "compile",
  "reason": "YAML parse error at line 42",
  "current_version": "a3f2c1d4..."
}
```

**Partial (event: "policy_reload_partial")**:

```json
{
  "timestamp": "2026-03-14T07:00:00Z",
  "event": "policy_reload_partial",
  "actor_ip": "127.0.0.1",
  "http_result": "committed",
  "stream_result": "lkg_retained"
}
```

## 8. CORS

기본 **off**. 필요 시 nginx.conf에서 explicit origin allowlist로만 활성화:

```nginx
# nginx.conf (http {} 스코프)
# LUAGATE_DASHBOARD_ORIGIN은 템플릿 렌더링(envsubst) 또는 nginx `env` + `map`으로 주입한다.
# CORS 기본 off — 아래 map은 명시적으로 활성화할 때만 사용
map $http_origin $cors_allow_origin {
    default "";
    "https://dashboard.example.com" "https://dashboard.example.com";
}
```

```nginx
# conf/nginx.http.conf (admin server/location 블록)
# http {} 에서 정의된 $cors_allow_origin만 참조한다.

add_header Access-Control-Allow-Origin $cors_allow_origin always;
add_header Access-Control-Allow-Methods "GET, POST, PUT, OPTIONS" always;
add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
add_header Vary "Origin" always;

if ($request_method = 'OPTIONS') {
    add_header Access-Control-Max-Age 86400;
    return 204;
}
```

`map`은 **http-context directive**이므로 admin `server` 블록 안에 inline으로 두지 않는다.

> **wildcard origin (`*`) 금지**: Bearer token과 함께 사용 시 보안 취약점.

## 9. 의존성

- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — 정책 reload 흐름
- [ADR-004](../design/adr/ADR-004-log-metrics-admin-security.md) — 보안 설정, 감사 로그
- [spec/policy-engine.md](./policy-engine.md) — 정책 검증/평가, If-Match 대상
- [spec/log-schema.md](./log-schema.md) — 감사 로그 스키마, 메트릭 목록
