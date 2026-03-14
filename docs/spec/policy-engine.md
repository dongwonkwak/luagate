# Policy Engine Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-002 정책 평가 규칙 + 충돌 감지](../design/adr/ADR-002-policy-evaluation-conflict-detection.md)
> - [ADR-003 정책 저장소 + Hot Reload](../design/adr/ADR-003-policy-storage-hot-reload.md)

## 1. 개요

정책 엔진은 LuaGate의 핵심 컴포넌트로, YAML로 정의된 규칙 집합을 기반으로
요청/연결에 대한 allow/deny 판정을 수행한다.

구현 위치: `lua/luagate/policy/`

## 2. 정책 파일 구조 (YAML)

### 2.0 Top-level Canonical Schema

```yaml
# conf/policies.yaml — full canonical example
version: "1.0"

global:
  default_action: deny          # allow | deny (ADR-002: 기본값 deny)

rules:                          # HTTP 규칙 목록 (http_rules 섹션)
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

stream_rules:                   # TCP 스트림 규칙 목록
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
|------|------|------|------|
| `id` | string | ✓ | 규칙 고유 식별자 — **파일 전체(http + stream) 유일성** |
| `description` | string | — | 설명 |
| `enabled` | boolean | — | 기본값 `true`. `false`이면 평가에서 제외 (schema 검증은 수행, conflict detect에서 제외) |
| `priority` | integer | ✓ | **낮은 숫자 = 높은 우선순위** (ADR-002). 동률은 `rule.id ASC` stable sort |
| `scope` | map | — | 매칭 조건 (AND). 생략 시 catch-all (wildcard) |
| `action` | enum | ✓ | HTTP: `allow` \| `deny`. Stream: `proxy` \| `deny` |
| `tags` | list<string> | — | 분류용 태그. 평가에 영향 없음 |

**Stream 전용:**

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `upstream` | string | proxy 시 ✓ | `"host:port"` 형식 |

### 2.2 Scope 키 및 매칭 연산자

**HTTP 규칙 scope:**

| scope 키 | 타입 | 매칭 연산자 | 설명 | 예시 |
|----------|------|------------|------|------|
| `path` | string | exact / prefix (`/*` suffix) | URL 경로. `/*`로 끝나면 prefix 매칭, 아니면 exact | `/health`, `/api/v1/*` |
| `host` | string | exact / wildcard (`*.`) | 가상 호스트. `*.`로 시작하면 서브도메인 wildcard | `api.example.com`, `*.example.com` |
| `method` | string \| list | exact (대소문자 무관) | HTTP 메서드 | `"GET"`, `["GET","POST"]` |
| `src_ip_cidr` | string | CIDR 포함 여부 | 클라이언트 IP CIDR | `10.0.0.0/8`, `0.0.0.0/0` |
| `query_param` | map | 키=값 exact | 쿼리 파라미터 | `{q: "admin"}` |
| `header` | map | 키=값 exact (헤더 대소문자 무관) | 요청 헤더 | `{X-Role: "admin"}` |

**Stream 규칙 scope:**

| scope 키 | 타입 | 매칭 연산자 | 설명 | 예시 |
|----------|------|------------|------|------|
| `src_ip_cidr` | string | CIDR 포함 여부 | 클라이언트 IP CIDR | `0.0.0.0/0` |
| `dst_port` | string \| integer | exact(정수) / range(`"lo-hi"`) | 목적지 포트 | `443`, `"1024-65535"` |
| `detected_protocol` | string | exact | 탐지된 프로토콜 enum | `tls`, `http`, `raw` |
| `sni` | string | exact / wildcard (`*.` prefix) | TLS SNI | `api.example.com`, `*.example.com` |

> **Omitted field = wildcard**: scope 키를 생략하면 해당 조건은 "모두 매칭"으로 처리된다.
> scope 전체를 생략하면 catch-all 규칙이 된다.

**`threat_type` 등 스캐너 출력 기반 scope 필드**는 현재 canonical scope에 포함되지 않는다.
향후 도입 시 별도 ADR/appendix로 정의한다 (`<!-- ADR 필요 -->` 마커 유지).

## 3. 정책 평가 알고리즘 (ADR-002)

### 3.1 HTTP 규칙 평가

```
function evaluate_http(request):
    rules = get_active_http_rules()  # enabled=true만, priority 오름차순 정렬

    for rule in rules:
        if matches(rule.scope, request):
            log_access(action=rule.action, matched_rule=rule.id)
            return rule.action

    # 매칭 없음 → 기본 정책
    log_access(action=global.default_action, matched_rule=nil)
    return global.default_action
```

### 3.2 Stream 규칙 평가

```
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
|----------|----------|
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
- **`original_index`**: `enabled` 값에 관계없이 **source order 기준** (disabled 규칙 포함 전체 목록의 0-based index)

## 4. 정책 로더 (ADR-003)

### 4.1 로드 흐름 (7단계)

```
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
    [6] compile: priority 오름차순 정렬 + radix tree 빌드
        - compile 실패 → 전체 거부 (전체 또는 전무)
    [7] commit (partial success 허용 구간):
        - HTTP 서브시스템 교체
        - Stream 서브시스템 교체
        - 각 서브시스템은 독립적으로 commit. 한 쪽 실패 시 해당 서브시스템만 LKG 유지
```

> **Partial success 범위**: [7] commit 단계에 한정.
> [3] validate / [6] compile은 **전체 또는 전무(all-or-nothing)** — 하나라도 실패 시 전체 거부.

> **Reload 실패 시**: 기존 active 정책(LKG) 유지. 실패한 버전은 폐기.
> LKG(Last-Known-Good)는 첫 성공 reload 후 형성되며, 이후 reload 실패 시 복원 대상이 된다.

### 4.2 Schema Validation

```lua
-- 필수 필드 검증
assert(rule.id, "rule.id is required")
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

`active_version`은 정책 파일 전체(raw bytes) 기준 **SHA256 hex string(lowercase, 64자)**로 정의한다.

```
active_version = sha256_hex(file_raw_bytes)
-- 예: "a3f9c2d1e8b4071f6a5d39c0e7b12345..."
```

- HTTP 서브시스템 active version: `luagate_policy["http:active_version"]`
- Stream 서브시스템 active version: `luagate_policy["stream:active_version"]`
- If-Match 비교 대상: 각 서브시스템의 active version (subsystem별 독립)

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
기록 필드 정의는 [admin-api.md — 감사 로그 섹션](./admin-api.md#감사-로그)을 참조한다.

| 결과 | 기록 필드 |
|------|---------|
| 성공 | `timestamp`, `actor`, `action=reload_success`, `previous_version`, `new_version`, `subsystem` |
| 실패 | `timestamp`, `actor`, `action=reload_failure`, `stage`, `reason`, `current_version` |
| Partial | `timestamp`, `actor`, `action=reload_partial`, `http_result`, `stream_result` |

> **감사 로그 드롭 금지**: 감사 로그 기록 실패 시 reload commit 거부.
> ([admin-api.md](./admin-api.md) 감사 실패 처리 참조)

## 7. 관리 API 연동

| 엔드포인트 | 기능 |
|-----------|------|
| `GET /api/v1/policies` | staged 정책 YAML 반환 (파일 기준 canonical source) |
| `PUT /api/v1/policies` | 새 정책 저장 + validate + compile + commit. `If-Match: <subsystem active_version>` 필수 |
| `POST /api/v1/policies/reload` | 현재 canonical file에서 reload 트리거. `If-Match` 선택 |
| `GET /api/v1/policies/version` | 서브시스템별 active_version + ETag 반환 |
| `GET /api/v1/policies/status` | 버전, 충돌 목록, 마지막 reload 시각 |

## 8. 의존성

- [ADR-002](../design/adr/ADR-002-policy-evaluation-conflict-detection.md) — 평가 규칙
- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — Hot Reload
- [spec/admin-api.md](./admin-api.md) — 정책 관련 API, 감사 로그
