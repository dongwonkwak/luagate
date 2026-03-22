# Admin API Specification

> **ADR 참조**:
>
> - [ADR-003 정책 저장소 + Hot Reload](../design/adr/ADR-003-policy-storage-hot-reload.md)
> - [ADR-004 로그/메트릭 + 관리면 보안](../design/adr/ADR-004-log-metrics-admin-security.md)
> - [ADR-005 정책 활성화 모델 + 동시성 제어](../design/adr/ADR-005-policy-activation-concurrency.md)

## 1. 개요

Admin API는 LuaGate의 관리 인터페이스로, 정책 관리, 상태 조회, 메트릭 노출을 담당한다.

- **바인딩**: `127.0.0.1:9090` (ADR-004 §6.1) — server block identity로 data plane과 분리
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
- 재기동 없는 교체: `POST /api/v1/admin/token/rotate` (§6.10 참조)
- 토큰은 로그/응답 바디에 절대 포함하지 않음

인증 실패 응답:

```json
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error": "Unauthorized", "message": "Invalid or missing Bearer token"}
```

> **WWW-Authenticate 헤더**: 포함하지 않음 (Bearer realm 노출 불필요 — admin-auth-contract.md 참조).
> **body 형식 근거**: `admin-auth-contract.md`의 `_reject()` 구현이 Source of Truth. 상세 이유(`reason`)는 정보 노출 방지를 위해 응답 body에 미포함하며 감사 로그에만 기록한다.

인증 실패 시 감사 로그 기록 (ADR-004 §6.3).

## 2.1 Rate Limiting

모든 요청에 IP 기반 sliding window rate limit 적용 (`GET /health` 제외 -- 메서드+경로 모두 일치해야 면제):

- **Zone**: `luagate_admin_ratelimit` (shared dict)
- **알고리즘**: Sliding window counter (increment-then-check)
- **제한**: 30 requests / 60s window / IP
- **면제**: `GET /health`만 (POST /health 등 다른 메서드는 rate limit 적용)
- **초과 응답**: `429 Too Many Requests` + `Retry-After` 헤더 (초 단위, 현재 window 만료까지 남은 시간)

```json
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
Retry-After: 42

{"error":"rate_limited","message":"Too many requests. Try again later."}
```

- **fail-closed**: shared dict 사용 불가 또는 incr 실패 시 `503 Service Unavailable` 반환
- **Worker 간 원자성**: `ngx.shared.DICT:incr()`의 원자적 증분을 먼저 수행한 뒤 결과값으로 판단 (increment-then-check 패턴)

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
| `Unauthorized` | n/a (auth 계층) | 401 |
| `validation_failed` | `validate` | 422 |
| `conflict_detected` | `conflict_detect` | 422 |
| `compile_failed` | `compile` | 422 |
| `commit_failed` | `commit` | 500 |
| `reload_failed` | `reload` | 500 |
| `version_mismatch` | `reload` | 409 |
| `reload_in_progress` | `reload` | 409 |
| `audit_write_failed` | `audit` | 500 |
| `rate_limited` | n/a (rate limit 계층) | 429 |
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
| `PUT /api/v1/policies` | source 저장(canonical file write) + validate + commit까지 **전체 파이프라인** | **필수** (`<source_version>` 형식 — `GET /api/v1/policies` ETag와 동일). `?dry_run=true` 시 선택 (§6.5.1) |
| `POST /api/v1/policies/reload` | 현재 canonical file에서 reload 트리거만 | 선택 (`<http_active_version>` 형식) |

> **PUT /api/v1/policies**: 저장 + validate + conflict_detect + compile + commit을 한 번에 수행한다.
> 응답 contract는 **success-only atomicity** 기준이다: `200 OK`일 때만 `source_version == active_http_version == active_stream_version`가 성립한다.
> 실패 응답에서는 canonical file(`conf/policies.yaml`)을 변경하지 않는다. 단, commit 단계에서 한쪽 swap 또는 file write 실패 시 이전 버전으로 **best-effort rollback**을 시도하며, rollback까지 실패하면 `500 commit_failed`와 함께 HTTP/Stream active version이 일시적으로 불일치할 수 있다 (ADR-005 §1).
> 이 경우 운영자는 `SIGHUP` 또는 수동 복구로 일관성을 회복해야 한다.

## 5. ETag / If-Match

- `GET /api/v1/policies` 응답에 `ETag: "<source_version>"` 포함
  - `source_version`은 canonical source 파일(conf/policies.yaml) 전체 raw bytes의 SHA256이다.
  - 응답 본문이 canonical source 파일을 그대로 반환하므로, ETag validator는 `source_version` 기준이다.
- `PUT /api/v1/policies` 요청에 `If-Match: "<source_version>"` 필수 (`GET /api/v1/policies` ETag와 동일 기준). 예외: `?dry_run=true` 시 생략 가능 (§6.5.1)
  - 불일치 시 → `409 Conflict` + `error: "version_mismatch"` (dry_run에서도 제공 시 동일 검증)
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

**인증 불필요**. 서버 liveness 확인용.

**응답 200:**

```json
{
  "status": "ok",
  "source_version": "a3f2c1d4e5b6...",
  "active_http_version": "a3f2c1d4e5b6...",
  "active_stream_version": "a3f2c1d4e5b6...",
  "policy_loaded_at": "2026-03-18T10:30:00Z",
  "ffi_watchdog_leak_count": [0, 0, 0, 0],
  "ffi_watchdog_timeouts": 0
}
```

| 필드 | 타입 | 설명 |
|------|------|------|
| `status` | string | `"ok"` 또는 `"unhealthy"` |
| `source_version` | string\|null | Canonical source (YAML) SHA256 해시. [ADR-008](../design/adr/ADR-008-multi-instance-policy-sync.md) §8.2 |
| `active_http_version` | string\|null | HTTP 서브시스템 active 정책 버전 |
| `active_stream_version` | string\|null | Stream 서브시스템 active 정책 버전. null/"none"일 때: `nginx.conf`에 stream 블록이 없으면 HTTP-only 배포(정상), stream 블록이 있으면 stream 정책 로드 장애 — `LuagateStreamPolicyNotLoaded` alert 확인 필요 |
| `policy_loaded_at` | string\|null | 마지막 성공적 정책 로드 시각 (ISO-8601 UTC) |
| `ffi_watchdog_leak_count` | array\<integer\> | Per-worker detached thread leak 카운터 배열 (인덱스 = worker id). [ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md) Phase 3 |
| `ffi_watchdog_timeouts` | integer | 전체 worker의 leak count 합산. [ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md) Phase 3 |

> 멀티 인스턴스 환경에서 외부 모니터링은 각 인스턴스의 `source_version`, `active_http_version`, `active_stream_version`이 CI/CD가 계산한 `target_version`과 모두 일치하는지 확인해야 한다 ([ADR-008](../design/adr/ADR-008-multi-instance-policy-sync.md) §8.3).

**응답 503** (unhealthy):

```json
{"status": "unhealthy", "reason": "policy not loaded"}
```

또는 FFI leak 임곗값 초과 시:

```json
{"status": "unhealthy", "reason": "ffi_thread_leak_threshold_exceeded", "ffi_watchdog_leak_count": [0, 0, 12, 0], "ffi_watchdog_timeouts": 12}
```

> **503 응답 조건** (우선순위 순):
> 1. FFI leak 임곗값 초과: 임의 worker의 `ffi_watchdog_leak_count[i]` > 10 (기본 임곗값). `reason: "ffi_thread_leak_threshold_exceeded"` ([ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md) Phase 3)
> 2. 정책 미로드: `http:active_version`이 없거나 `"none"`. `reason: "policy not loaded"`

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
> **commit 단계 규칙**: [8]에서는 HTTP swap → Stream swap → canonical file write 순으로 진행한다. canonical file write는 두 swap이 모두 성공한 경우에만 수행되며, 중간 실패 시 이전 버전으로 best-effort rollback 후 `500 commit_failed`를 반환한다. rollback까지 실패하면 active version 불일치가 남을 수 있다.
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
  "warnings": []
}
```

#### 6.5.1 Dry-run 검증 모드

```http
PUT /api/v1/policies?dry_run=true
Authorization: Bearer <token>
Content-Type: application/x-yaml
Content-Length: <bytes>

<정책 YAML>
```

정책을 실제 적용하지 않고 검증만 수행한다. MCP `luagate_validate_policies` tool이 사용한다.

**처리 순서**: [1] parse → [2] validate → [3] conflict_detect → [4] hash(SHA256). commit/file write 없음.

**If-Match**: 선택 (dry-run은 저장하지 않으므로 생략 가능). 단, 제공 시 `source_version`과 비교하여 불일치이면 `409 version_mismatch` 반환 (일반 PUT과 동일)

**응답 200 (검증 성공):**

```json
{
  "dry_run": true,
  "valid": true,
  "version_hash": "b4e3f2a1...",
  "warnings": [
    {"type": "conflict", "rule_ids": ["rule-a", "rule-b"], "message": "same scope, priority, opposing action"}
  ],
  "shadowed": ["narrow-allow"],
  "http_rules_count": 42,
  "stream_rules_count": 5
}
```

> **충돌(conflict)은 경고로 보고**: 일반 PUT에서는 conflict 발견 시 422를 반환하지만, dry-run에서는 `warnings` 배열에 포함하여 200으로 반환한다.
> **감사 로그 미기록**: dry-run은 상태 변경이 없으므로 감사 로그를 남기지 않는다.

**응답 422 (parse/validate 실패):**

일반 PUT과 동일한 에러 응답 형식. parse/validate 에러는 dry-run에서도 422로 반환한다.

---

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

**응답 500 (commit 실패):**

```json
{
  "error": "commit_failed",
  "stage": "commit",
  "details": [
    "stream active pointer swap failed",
    "rollback of http active pointer also failed; active versions may be inconsistent"
  ],
  "current_http_version": "b4e3f2a1...",
  "current_stream_version": "a3f2c1d4..."
}
```

> `current_http_version` / `current_stream_version`은 실패 처리 직후 관측된 값이다. rollback이 모두 성공한 경우 두 값은 이전 버전으로 같게 유지된다.
> 이 응답은 PUT이 `200`이 아니더라도 commit 단계 side effect가 일부 남을 수 있음을 의미한다. 단, canonical file은 변경되지 않는다.

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

# HELP luagate_policy_loaded Whether policy is loaded per subsystem (1=loaded, 0=not loaded).
# TYPE luagate_policy_loaded gauge
luagate_policy_loaded{subsystem="http"} 1
luagate_policy_loaded{subsystem="stream"} 0
```

`luagate_policy_loaded`는 `subsystem` 라벨로 HTTP/Stream을 구분한다.
HTTP-only 배포에서 `{subsystem="stream"} 0`은 정상이다.

**Migration note**: v0.x 이전의 `luagate_policy_loaded` (라벨 없음)에서 `{subsystem="http"|"stream"}` 라벨이 추가됨. 기존 Grafana 대시보드/alert rule 업데이트 필요.

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

### 6.10 Token Rotation

```http
POST /api/v1/admin/token/rotate
Authorization: Bearer <current-token>
Content-Type: application/json

{"new_token": "<new-token-string>"}
```

**인증 필수**. 현재 유효한 토큰으로 인증해야 함.

**규칙**:

- `new_token` 최소 32바이트 (MIN_TOKEN_LENGTH)
- 새 토큰은 `luagate_state` shared dict의 `luagate_admin_token` 키에 저장
- 이전 토큰은 30초 grace period 동안 유효 (`luagate_admin_token_old` 키, TTL=30s)
- 토큰 값은 로그/응답 바디에 절대 미포함
- 감사 로그: `event: token_rotated`

**인증 우선순위** (auth.lua verify):

1. Rotated token (shared dict `luagate_admin_token`) — rotation 후 유일한 정상 토큰
2. Grace period old token (shared dict `luagate_admin_token_old`, TTL 30s) — 읽기 전용, rotation 재호출 불가
3. Env-loaded token (`LUAGATE_ADMIN_TOKEN`) — rotation 미발생 시에만 유효

> **보안**: grace period 토큰으로 인증한 요청은 `POST /api/v1/admin/token/rotate` 호출 불가 (403).

**응답 200:**

```json
{
  "status": "rotated",
  "grace_period_seconds": 30
}
```

**에러 응답:**

| 상태 코드 | error 코드 | 조건 |
|----------|----------|------|
| 400 | `bad_request` | body 없음, 잘못된 JSON, new_token 누락, new_token 길이 부족 |
| 403 | `forbidden` | grace period 토큰으로 rotation 시도 |
| 500 | `internal_error` | shared dict 사용 불가 (fail-closed) |
| 500 | `audit_write_failed` | 감사 로그 기록 실패 → mutation rollback (stage: `audit`) |

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

### 7.1 MCP 메타데이터 (ADR-011 §8)

MCP 서버를 통한 요청 시 감사 로그에 추가 메타데이터가 기록된다. `X-MCP-Client` 헤더 유무로 `actor_type`을 결정한다.

| 필드 | 타입 | 조건 | 설명 |
|------|------|------|------|
| `actor_type` | string | 항상 | `"mcp"` (MCP 헤더 존재 시) 또는 `"api"` (기본값) |
| `client_name` | string | MCP only | `X-MCP-Client` 헤더값 (예: `"claude-desktop"`) |
| `tool_name` | string | MCP only | `X-MCP-Tool` 헤더값 (예: `"luagate_update_policies"`) |
| `session_id` | string | MCP only | `X-MCP-Session-Id` 헤더값 |
| `request_id` | string | MCP only | `X-Request-ID` 헤더값 |

**MCP 호출 시 감사 로그 예시:**

```json
{
  "timestamp": "2026-03-20T12:00:00Z",
  "event": "policy_update_success",
  "actor_ip": "127.0.0.1",
  "actor_type": "mcp",
  "client_name": "claude-desktop",
  "tool_name": "luagate_update_policies",
  "session_id": "sess-abc123",
  "request_id": "req-xyz789",
  "trigger": "api",
  "previous_version": "a3f2c1d4...",
  "new_version": "b4e3f2a1..."
}
```

**일반 API 호출 시 감사 로그 예시 (하위 호환):**

```json
{
  "timestamp": "2026-03-20T12:00:00Z",
  "event": "policy_update_success",
  "actor_ip": "127.0.0.1",
  "actor_type": "api",
  "trigger": "api",
  "previous_version": "a3f2c1d4...",
  "new_version": "b4e3f2a1..."
}
```

> **하위 호환성**: `X-MCP-Client` 헤더가 없는 기존 API 호출은 `actor_type: "api"`로 기록되며, MCP 전용 필드(`client_name`, `tool_name`, `session_id`, `request_id`)는 생략된다.

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

### 8.2 보안 응답 헤더 (DON-174)

Admin server block의 모든 응답에 아래 헤더를 추가한다:

```nginx
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options        "DENY"    always;
add_header Referrer-Policy        "strict-origin-when-cross-origin" always;
add_header Permissions-Policy     "geolocation=(), microphone=()" always;
add_header Cache-Control          "no-store" always;
```

- `style-src 'unsafe-inline'`: Tailwind CSS 런타임 스타일 삽입에 필요
- `worker-src 'self' blob:`: Monaco Editor Web Worker에 필요
- `Cache-Control: no-store`: Admin API 응답 캐시 방지

## 9. 의존성

- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — 정책 reload 흐름
- [ADR-004](../design/adr/ADR-004-log-metrics-admin-security.md) — 보안 설정, 감사 로그
- [ADR-005](../design/adr/ADR-005-policy-activation-concurrency.md) — 정책 활성화 모델 + 동시성 제어
- [spec/policy-engine.md](./policy-engine.md) — 정책 검증/평가, If-Match 대상
- [spec/log-schema.md](./log-schema.md) — 감사 로그 스키마, 메트릭 목록
