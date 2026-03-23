# Policy Engine Specification

> **ADR 참조**:
>
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-002 정책 평가 규칙 + 충돌 감지](../design/adr/ADR-002-policy-evaluation-conflict-detection.md)
> - [ADR-003 정책 저장소 + Hot Reload](../design/adr/ADR-003-policy-storage-hot-reload.md)
> - [ADR-005 정책 활성화 모델 + 동시성 제어](../design/adr/ADR-005-policy-activation-concurrency.md)

## 1. 개요

정책 엔진은 LuaGate의 핵심 컴포넌트로, YAML로 정의된 규칙 집합을 기반으로
요청/연결에 대한 allow/deny 판정을 수행한다.

구현 위치: `lua/luagate/policy/`

## 2. 정책 파일 구조 (YAML)

### 2.0 Top-level Canonical Schema

> **설계 결정 — Flat top-level key 방식 채택**:
> HTTP 규칙은 `rules:`, 스트림 규칙은 `stream_rules:` 키를 top-level에 직접 배치한다.
> 중첩 구조(`http.rules` / `stream.rules`)는 사용하지 않는다.
> 이 결정은 이 문서와 `admin-api.md`에서 동일하게 적용되며, 모든 예시는 flat top-level key 표기를 따른다.

```yaml
# conf/policies.yaml — full canonical example
version: "1.0"

global:
  default_action: deny          # allow | deny (ADR-002: 기본값 deny)

rules:                          # HTTP 규칙 목록 (top-level key: "rules" — 중첩 http.rules 아님)
  - id: allow-health            # 규칙 고유 식별자 (파일 전체 유일, subsystem 무관)
    description: "헬스체크 허용"
    enabled: true               # 기본값 true. false이면 평가 제외 (schema 검증은 수행)
    priority: 10                # 낮은 숫자 = 높은 우선순위 (ADR-002: 오름차순 정렬)
    scope:
      path: /health             # 정확 일치(exact)
      method: GET               # 단일 메서드
    action: allow
    tags: [ops]                 # 선택적 분류 태그

  - id: block-admin-from-public
    description: "외부망에서 admin 경로 차단"
    enabled: true
    priority: 20
    scope:
      path: /admin/*            # prefix 매칭 (/* 포함)
      src_ip_cidr: 0.0.0.0/0
    action: deny
    tags: [security]

stream_rules:                   # TCP 스트림 규칙 목록 (top-level key: "stream_rules")
  - id: allow-tls-443
    description: "TLS 443 허용"
    enabled: true
    priority: 10
    scope:
      dst_port: 443             # 단일 포트 (exact)
      detected_protocol: tls    # tls | http | raw
    action: proxy
    upstream: "backend:8443"
    tags: []

  - id: block-raw-non-22
    description: "raw 프로토콜 22번 외 차단"
    enabled: true
    priority: 100
    scope:
      dst_port: "1-65535"       # 포트 범위 (range)
      detected_protocol: raw
    action: deny
    tags: [security]
```

### 2.1 필드 정의

**공통 필드:**

| 필드 | 타입 | 필수 | 설명 |
| --- | --- | --- | --- |
| `id` | string | ✓ | 규칙 고유 식별자 — **파일 전체(http + stream) 유일성**. 문자 제한: `[a-z0-9-]+` (소문자 영숫자와 하이픈만 허용). rate limit 카운터 키 구분자 `:`와의 충돌 방지 ([ADR-012](../design/adr/ADR-012-http-data-plane-rate-limiting.md)) |
| `description` | string | — | 설명 |
| `enabled` | boolean | — | 기본값 `true`. `false`이면 평가에서 제외 (schema 검증은 수행, conflict detect에서 제외) |
| `priority` | integer | ✓ | **낮은 숫자 = 높은 우선순위** (ADR-002). 동률은 `rule.id ASC` stable sort |
| `scope` | map | — | 매칭 조건 (AND). 생략 시 catch-all (wildcard) |
| `action` | enum | ✓ | HTTP: `allow` \| `deny`. Stream: `proxy` \| `deny` |
| `tags` | `list<string>` | — | 분류용 태그. 평가에 영향 없음 |
| `rate_limit` | map | — | HTTP 규칙 전용. 요청 속도 제한 설정. 상세: [ADR-012](../design/adr/ADR-012-http-data-plane-rate-limiting.md) |

**`rate_limit` 필드 (HTTP 규칙, 선택적):**

| 필드 | 타입 | 필수 | 설명 |
| --- | --- | --- | --- |
| `rate_limit.requests` | integer (> 0) | Y (rate_limit 존재 시) | 윈도우 내 최대 허용 요청 수 |
| `rate_limit.window` | integer (> 0) | Y (rate_limit 존재 시) | 윈도우 크기 (초) |
| `rate_limit.scope` | enum | Y (rate_limit 존재 시) | 카운터 키 scope. MVP: `client_ip`만 지원 |

> `rate_limit`은 `action: allow` 규칙에서만 유효하다 (`action: deny` 규칙에는 rate limiting 불필요).
> `rate_limit` 필드가 있으면 `requests`, `window`, `scope` 모두 필수. 검증 실패 시 정책 로드 거부 (ADR-003 startup-fatal).

**Stream 전용:**

| 필드 | 타입 | 필수 | 설명 |
| --- | --- | --- | --- |
| `upstream` | string | proxy 시 ✓ | `"host:port"` 형식 |
| `tls_termination` | boolean | — | `true`: LuaGate가 TLS 종료, `false`(기본값): 패스스루. `action: deny` 규칙에서는 무시됨. non-TLS 규칙에 `true` 설정 시 스키마 검증 경고. 상세: [stream-pipeline.md §10.3](./stream-pipeline.md#103-정책-스키마-tls_termination-필드), [ADR-015](../design/adr/ADR-015-tls-termination.md) |

### 2.2 Scope 키 및 매칭 연산자

**HTTP 규칙 scope:**

| scope 키 | 타입 | 매칭 연산자 | 설명 | 예시 |
| --- | --- | --- | --- | --- |
| `path` | string | exact / prefix (`/*` suffix) | URL 경로. `/*`로 끝나면 prefix 매칭, 아니면 exact | `/health`, `/api/v1/*` |
| `host` | string | exact / wildcard (`*.`) | 가상 호스트. `*.`로 시작하면 서브도메인 wildcard | `api.example.com`, `*.example.com` |
| `method` | string \| list | exact (대소문자 무관) | HTTP 메서드 | `"GET"`, `["GET","POST"]` |
| `src_ip_cidr` | string | CIDR 포함 여부 | 클라이언트 IP CIDR | `10.0.0.0/8`, `0.0.0.0/0` |
| `query_param` | map | 키=값 exact | 쿼리 파라미터 | `{q: "admin"}` |
| `header` | map | 키=값 exact (헤더 대소문자 무관) | 요청 헤더 | `{X-Role: "admin"}` |

**Stream 규칙 scope:**

| scope 키 | 타입 | 매칭 연산자 | 설명 | 예시 |
| --- | --- | --- | --- | --- |
| `src_ip_cidr` | string | CIDR 포함 여부 | 클라이언트 IP CIDR | `0.0.0.0/0` |
| `dst_port` | string \| integer | exact(정수) / range(`"lo-hi"`) | 목적지 포트 | `443`, `"1024-65535"` |
| `detected_protocol` | string | exact | 탐지된 프로토콜 enum | `tls`, `http`, `raw` |
| `sni` | string | exact / wildcard (`*.` prefix) | TLS SNI | `api.example.com`, `*.example.com` |

> **Omitted field = wildcard**: scope 키를 생략하면 해당 조건은 "모두 매칭"으로 처리된다.
> scope 전체를 생략하면 catch-all 규칙이 된다.

**`threat_type` 등 스캐너 출력 기반 scope 필드**는 현재 canonical scope에 포함되지 않는다.
향후 도입 시 별도 ADR/appendix로 정의한다 (`ADR 필요` 마커 유지).

## 3. 정책 평가 알고리즘 (ADR-002)

### 3.1 HTTP 규칙 평가

```text
function evaluate_http(request):
    rules = get_active_http_rules()  # enabled=true만, priority 오름차순 정렬

    for rule in rules:
        if matches(rule.scope, request):
            log_access(action=rule.action, matched_rule=rule.id)
            return rule.action, rule.id, nil, rule.rate_limit

    # 매칭 없음 → 기본 정책
    log_access(action=global.default_action, matched_rule=nil)
    return global.default_action, nil, nil, nil
```

**반환값 계약** (ADR-012 확장):

| 순서 | 이름 | 타입 | 설명 |
| --- | --- | --- | --- |
| 1 | `action` | `"allow"` \| `"deny"` | 판정 결과 |
| 2 | `rule_id` | `string` \| `nil` | 매칭된 규칙 ID. 매칭 없으면 `nil` |
| 3 | `deny_reason` | `string` \| `nil` | 거부 사유. 현재 미사용 (`nil`), 향후 확장 예약 |
| 4 | `rate_limit` | `table` \| `nil` | 매칭된 규칙의 `rate_limit` 설정 (`{requests, window, scope}`). 미설정 시 `nil` |

> `handler.lua`는 `action == "allow"` AND `rate_limit ~= nil`일 때만 rate limit 검사를 수행한다.
> `deny` 판정 시 `rate_limit`은 항상 `nil`이다 (`action: deny` 규칙에는 rate_limit 필드 불허).
> 상세: [ADR-012 §4](../design/adr/ADR-012-http-data-plane-rate-limiting.md)

### 3.2 Stream 규칙 평가

```text
function evaluate_stream(connection):
    rules = get_active_stream_rules()  # enabled=true만, priority 오름차순 정렬

    for rule in rules:
        if matches(rule.scope, connection):
            log_stream(action=rule.action, matched_rule=rule.id)
            return rule.action, rule.upstream

    # 매칭 없음 → fail-closed (deny)
    log_stream(action="deny", matched_rule=nil)
    return "deny", nil
```

### 3.3 scope 매칭 로직

모든 scope 조건이 AND로 평가된다.

| scope 키 | 매칭 방식 |
| --- | --- |
| `path` | `/*` suffix → prefix 매칭, 그 외 exact |
| `host` | `*.` prefix → 서브도메인 wildcard, 그 외 exact |
| `method` | exact (대소문자 무관) |
| `src_ip_cidr` | CIDR 포함 여부 |
| `dst_port` | `"lo-hi"` 형식 → range, 정수 → exact |
| `detected_protocol` | exact |
| `sni` | `*.` prefix → 서브도메인 wildcard, 그 외 exact |
| `query_param` | 키=값 exact |
| `header` | 키=값 exact (헤더 이름 대소문자 무관) |

scope 조건이 없는 규칙은 모든 요청에 매칭 (catch-all).

### 3.4 우선순위 정렬 및 `original_index`

정책 로드 시 규칙을 priority 오름차순으로 정렬하여 메모리에 유지한다.

- **동률(동일 priority)**: `priority ASC` 후 `rule.id ASC` stable sort 적용 (ADR-002 §3.1)
- **`original_index`**: `enabled` 값에 관계없이 **source order 기준** (disabled 규칙 포함 전체 목록의 **1-based index — Lua 배열 인덱스와 동일**). FFI 결과의 `rule_index`는 Lua에서 `rules[rule_index]`로 직접 역참조 가능하다 (`rules[rule_index + 1]` 보정 불필요).

## 4. 정책 로더 (ADR-003)

### 4.1 로드 흐름 (7단계)

```text
load_policy(filepath):
    [1] 파일 읽기 (io.open)
    [2] YAML 파싱 (lyaml 또는 lua-yaml)
    [3] Schema validation (전체 또는 전무 — 하나라도 실패 시 전체 거부)
        - 필수 필드 검증 (id, priority, action)
        - 타입 검증
        - id 유일성 검증 (http + stream 합산, 파일 전체)
        - enabled=false 규칙도 schema validation 대상
    [4] 충돌/음영 감지 (enabled=true 규칙만 대상)
        - 충돌 → WARN 로그, 계속 진행
    [5] SHA256 해시 계산 (전체 파일 내용 기준)
    [6] compile: priority 오름차순 정렬 (CIDR 매칭은 평가 시 Lua 연산)
        - compile 실패 → 전체 거부 (전체 또는 전무)
    [7] commit:
        - HTTP 서브시스템 교체
        - Stream 서브시스템 교체
        - PUT /api/v1/policies: 성공 응답(200)일 때만 all-or-nothing 보장. 한쪽 서브시스템 또는 canonical file write 실패 시 전체 실패 반환 + 이전 버전으로 best-effort rollback 시도 (ADR-005 §1)
        - POST /api/v1/policies/reload: partial success 허용. 한 쪽 실패 시 해당 서브시스템만 LKG 유지 (ADR-003)
```

> **Partial success 범위**: `POST /api/v1/policies/reload`의 [7] commit 단계에 한정한다. `PUT /api/v1/policies`는 실패를 성공으로 승격하지 않으며, commit 단계에서도 부분 성공을 `500`으로 반환한다. 단, rollback 자체가 실패하면 active version 불일치가 잔존할 수 있다 (ADR-005 §1).
> [3] validate / [6] compile은 **전체 또는 전무(all-or-nothing)** — 하나라도 실패 시 전체 거부.
> **Reload 실패 시 (commit 이전)**: active pointer가 변경되지 않았으므로 **롤백 불필요**. 기존 active version의 blob/meta가 shared dict에 그대로 유지된다. 실패한 신규 버전의 blob/meta는 폐기 대상이지만, 정리 타이밍은 구현 재량이다.
> **Reload 실패 시 (commit 단계 partial)**: 실패한 서브시스템의 active pointer는 변경되지 않으며, 해당 서브시스템은 이전 성공 버전(LKG)을 계속 사용한다.
> **LKG(Last-Known-Good)**: 첫 성공 reload 이후 형성된다. cold start 시에는 LKG 없음 — 정책 로드 실패 시 fail-closed (기동 거부). LKG는 자동 롤백 트리거가 아니라 "이전 성공 버전 데이터가 shared dict에 남아 있는 상태"다 (architecture.md §3.5 참조).

### 4.2 Schema Validation

```lua
-- 필수 필드 검증
assert(rule.id, "rule.id is required")
assert(type(rule.id) == "string" and rule.id:match("^[a-z0-9%-]+$"),
       "rule.id must match [a-z0-9-]+ (no ':' allowed)")
assert(type(rule.priority) == "number", "rule.priority must be number")

-- action 검증: HTTP와 Stream은 허용 action이 다름
if is_http_rule then
    assert(rule.action == "allow" or rule.action == "deny",
           "http rule.action must be 'allow' or 'deny'")
else  -- stream rule
    assert(rule.action == "proxy" or rule.action == "deny",
           "stream rule.action must be 'proxy' or 'deny'")
    if rule.action == "proxy" then
        assert(rule.upstream, "stream proxy rule requires 'upstream' field")
    end
end

-- id 유일성: http rules + stream_rules 합산 검증
local seen_ids = {}
for _, rule in ipairs(all_rules) do  -- http + stream 합산
    assert(not seen_ids[rule.id], "duplicate rule id: " .. rule.id)
    seen_ids[rule.id] = true
end
```

### 4.3 Active Version Canonical Serialization

> **Envelope 모델 (pointer swap 원자성)**: `luagate_policy` zone은 **Envelope zone**으로 분류된다. 원자성 보장 방식은 다음과 같다:
> 1. 새 버전의 `policy:<new_ver>:blob`와 `policy:<new_ver>:meta`를 shared dict에 먼저 기록 (이 시점에 기존 active pointer는 변경되지 않음)
> 2. `http:active_version` 또는 `stream:active_version` 포인터 키를 단일 write로 교체 — 이것이 **원자적 단위**
> 3. pointer swap 이전까지 기존 worker는 old version blob을 계속 사용 (무중단)
>
> shared dict는 다중 키 트랜잭션을 제공하지 않는다. blob + meta는 pointer swap 이전에 기록되고 swap 이후에도 유지된다(LKG). Envelope vs State zone 분류 상세는 [architecture.md §3.1](./architecture.md#31-zone-분류-모델) 참조.

`active_version`은 정책 파일 전체(raw bytes) 기준 **SHA256 hex string(lowercase, 64자)**로 정의한다.

```text
active_version = sha256_hex(file_raw_bytes)
-- 예: "a3f9c2d1e8b4071f6a5d39c0e7b12345..."
```

- HTTP 서브시스템 active version: `luagate_policy["http:active_version"]`
- Stream 서브시스템 active version: `luagate_policy["stream:active_version"]`
- **ETag 기준값**: `GET /api/v1/policies`의 응답 `ETag`는 **`source_version`** (canonical source 파일 SHA256) 기준이다.
  - `source_version`은 파일 전체 raw bytes의 SHA256으로 계산하며, commit 완료 후 `luagate_policy["source_version"]`에 저장된다.
  - `GET /api/v1/policies`가 canonical source 본문을 그대로 반환하므로, ETag validator는 해당 파일의 `source_version`과 연결된다.
- **If-Match 비교 대상 (subsystem별 분리)**:
  - `PUT /api/v1/policies`의 `If-Match` 헤더 비교 대상: **`source_version`** (`GET /api/v1/policies` ETag와 동일 기준)
  - `POST /api/v1/policies/reload`의 `If-Match` 헤더 비교 대상: `luagate_policy["http:active_version"]`
  - Stream 서브시스템 active_version은 별도 조회 전용: `GET /api/v1/policies/version` 응답 내 `active_stream_version` 필드
  - **근거**: PUT은 canonical source 파일을 교체하는 작업이므로 ETag/If-Match 모두 `source_version` 기준. reload는 이미 적재된 HTTP 활성 정책을 기준으로 충돌을 감지하므로 `http:active_version` 기준. Stream active_version은 If-Match 비교 대상이 아니다.

### 4.4 Hot Reload (ADR-003)

Worker 버전 확인 로직 (`access_by_lua` 진입 시):

```lua
-- lua/luagate/policy/evaluator.lua (module-level upvalue)
-- ngx.ctx는 요청 단위 스코프이므로 policy 캐시에 사용하지 않는다.
-- Worker-level Lua module state (upvalue)로 캐시한다.
local _cached_policy = nil          -- worker-level 캐시
local _cached_version = nil         -- 캐시된 정책 버전

local function get_policy()
    local current_version = ngx.shared.luagate_policy:get("http:active_version")

    if _cached_version == current_version and _cached_policy ~= nil then
        -- 버전 동일 → 캐시 사용 (shared dict 접근 최소화)
        return _cached_policy
    end

    -- 버전 변경 → shared dict에서 새 정책 로드
    local blob_key = "policy:" .. current_version .. ":blob"
    local policy_json = ngx.shared.luagate_policy:get(blob_key)
    if not policy_json then
        ngx.log(ngx.ERR, "policy blob not found for version: ", current_version)
        return _cached_policy  -- last-known-good 유지
    end

    _cached_policy = cjson.decode(policy_json)
    _cached_version = current_version
    return _cached_policy
end
```

> **중요**: `ngx.ctx`는 요청(request) 단위 스코프로, 요청 종료 시 GC된다.
> 정책 캐시를 `ngx.ctx`에 저장하면 매 요청마다 shared dict를 조회하게 된다.
> Module-level upvalue(`_cached_policy`, `_cached_version`)는 worker 프로세스 수명 동안 유지되므로,
> 버전이 바뀌지 않는 한 shared dict 조회를 건너뛸 수 있다.

## 5. 충돌 감지기 (ADR-002)

충돌/음영 감지는 **`enabled=true` 규칙만 대상**으로 한다.

### 5.1 충돌(conflict) 감지

```lua
-- 동일 scope + 동일 priority + 상반 action
function detect_conflicts(rules):
    conflicts = []
    for i, rule_a in ipairs(rules):
        for j, rule_b in ipairs(rules):
            if i >= j: continue
            if rule_a.priority == rule_b.priority
               and scopes_equal(rule_a.scope, rule_b.scope)
               and rule_a.action != rule_b.action:
                conflicts.append({rule_a.id, rule_b.id})
                ngx.log(ngx.WARN, "conflict: " .. rule_a.id .. " vs " .. rule_b.id)
    return conflicts
```

### 5.2 음영 규칙(shadowed) 감지

```lua
-- 넓은 scope 높은 priority가 좁은 scope를 완전히 포함
function detect_shadowed(rules):
    shadowed = []
    for i, broad in ipairs(rules):
        for j, narrow in ipairs(rules):
            if broad.priority < narrow.priority  -- broad가 더 높은 우선순위
               and scope_contains(broad.scope, narrow.scope):
                shadowed.append(narrow.id)
                ngx.log(ngx.WARN, "shadowed rule: " .. narrow.id ..
                        " by " .. broad.id)
    return shadowed
```

## 6. Reload Audit Log

정책 reload 성공/실패/partial 각 경우에 감사 로그를 기록한다.
기록 필드 정의는 [admin-api.md §7 감사 로그 섹션](./admin-api.md#7-감사-로그-auditlog-섹션)을 참조한다.
역방향 참조: admin-api.md §7 ↔ 이 섹션(policy-engine.md §6)은 감사 로그 필드 및 드롭 금지 원칙을 공유한다.

감사 로그 필드는 [admin-api.md §7](./admin-api.md#7-감사-로그-auditlog-섹션) 및 [log-schema.md §5](./log-schema.md#5-감사-로그-auditlog-adr-004-63)와 동일한 스키마를 사용한다.

| 결과 | 기록 필드 |
| --- | --- |
| 성공 | `timestamp`, `event="policy_reload_success"`, `actor_ip`, `previous_version`, `new_version`, `subsystem` |
| 실패 | `timestamp`, `event="policy_reload_failure"`, `actor_ip`, `stage`, `reason`, `current_version` |
| Partial | `timestamp`, `event="policy_reload_partial"`, `actor_ip`, `http_result`, `stream_result` |

> **감사 로그 직렬화 실패 시 동작 (pre-commit vs post-commit)**:
>
> - **Pre-commit audit** (`policy_reload_attempt`): 직렬화(`cjson.encode`) 실패 시 reload commit 거부.
> - **Post-commit audit** (`policy_reload_success`, `policy_reload_partial`): 직렬화 실패 시 경고 로그만 남김.
>   reload는 이미 적용되었으므로 거부하지 않는다.
>
> 디스크 I/O 기록 보장은 Nginx `error_log` 인프라에 위임. ([admin-api.md §7](./admin-api.md#7-감사-로그-auditlog-섹션) 참조)

## 7. 관리 API 연동

| 엔드포인트 | 기능 | If-Match |
| --- | --- | --- |
| `GET /api/v1/policies` | 현재 canonical source (`conf/policies.yaml`) 반환. 응답 `ETag: "<source_version>"` 포함 | — |
| `PUT /api/v1/policies` | 새 정책 저장 + validate + compile + commit | **필수** (`<source_version>`) |
| `POST /api/v1/policies/reload` | 현재 canonical file에서 reload 트리거 | 선택 (제공 시 `http:active_version`과 비교, 불일치이면 409) |
| `GET /api/v1/policies/version` | 서브시스템별 active_version 조회 (`active_http_version`, `active_stream_version` 분리 반환) | — |
| `GET /api/v1/policies/status` | 버전, 충돌 목록, 마지막 reload 시각 | — |

> **If-Match 기준값 요약**:
> - `PUT /api/v1/policies`: `source_version` (`GET /api/v1/policies` ETag와 동일)
> - `POST /api/v1/policies/reload`: `luagate_policy["http:active_version"]`
> - Stream 서브시스템의 active_version은 `GET /api/v1/policies/version` 응답의 `active_stream_version` 필드로만 조회 가능하며, If-Match 비교 대상이 아니다. 상세: §4.3 참조.

## 8. 의존성

- [ADR-002](../design/adr/ADR-002-policy-evaluation-conflict-detection.md) — 평가 규칙
- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — Hot Reload
- [ADR-005](../design/adr/ADR-005-policy-activation-concurrency.md) — 정책 활성화 모델 + 동시성 제어
- [spec/admin-api.md](./admin-api.md) — 정책 관련 API, 감사 로그
