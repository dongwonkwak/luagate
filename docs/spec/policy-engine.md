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

```yaml
# conf/policies.yaml

version: "1.0"

global:
  default_action: deny          # allow | deny (ADR-002: 기본값 deny)

rules:
  - id: string                  # 규칙 고유 식별자 (필수, unique)
    description: string         # 설명 (선택)
    scope:                      # 매칭 조건 (AND 조건)
      path: string              # glob 패턴 (예: /api/v1/*)
      method: string | list     # HTTP 메서드 (GET, POST, ...)
      src_ip: string            # 단일 IP
      src_ip_cidr: string       # CIDR 표기법
      query_param: map          # 쿼리 파라미터 매칭
      header: map               # 요청 헤더 매칭
    priority: number            # 낮은 숫자 = 높은 우선순위 (ADR-002)
    action: allow | deny        # 판정
    tags: list                  # 태그 (선택, 분류용)

stream_rules:                   # TCP 스트림 규칙
  - id: string
    scope:
      src_ip_cidr: string
      dst_port: number
      detected_protocol: string # tls | http | ssh | unknown
      sni: string               # TLS SNI
    priority: number
    action: proxy | deny
    upstream: string            # proxy 시 업스트림 주소
```

### 2.1 Canonical Scope 키 정의

아래 scope 키는 LuaGate의 공식(canonical) 키다. 이 외의 scope 확장은 별도 ADR을 통해 추가한다.

**HTTP 규칙 scope:**

| scope 키 | 타입 | 설명 | 예시 |
|----------|------|------|------|
| `path` | string (glob) | URL 경로 패턴 | `/api/v1/*`, `/health` |
| `method` | string \| list | HTTP 메서드 | `GET`, `["GET", "POST"]` |
| `src_ip` | string | 단일 클라이언트 IP | `192.168.1.1` |
| `src_ip_cidr` | string | CIDR 범위 | `10.0.0.0/8` |
| `query_param` | map | 쿼리 파라미터 키=값 | `{q: "admin"}` |
| `header` | map | 요청 헤더 키=값 | `{X-Role: "admin"}` |

**Stream 규칙 scope:**

| scope 키 | 타입 | 설명 | 예시 |
|----------|------|------|------|
| `src_ip_cidr` | string | CIDR 범위 | `0.0.0.0/0` |
| `dst_port` | number | 목적지 포트 | `443`, `22` |
| `detected_protocol` | string (enum) | 탐지된 프로토콜 | `tls`, `http`, `ssh`, `unknown` |
| `sni` | string | TLS SNI 값 (exact match) | `api.example.com` |

**`threat_type` 등 스캐너 출력 기반 scope 필드**는 현재 canonical scope에 포함되지 않는다.
향후 도입 시 별도 ADR/appendix로 정의한다 (`<!-- ADR 필요 -->` 마커 유지).

## 3. 정책 평가 알고리즘 (ADR-002)

### 3.1 HTTP 규칙 평가

```
function evaluate_http(request):
    rules = get_rules_sorted_by_priority()  # priority 오름차순

    for rule in rules:
        if matches(rule.scope, request):
            log_access(action=rule.action, matched_rule=rule.id)
            return rule.action

    # 매칭 없음 → 기본 정책
    log_access(action=global.default_action, matched_rule=nil)
    return global.default_action
```

### 3.2 scope 매칭 로직

모든 scope 조건이 AND로 평가된다.

| scope 키 | 매칭 방식 |
|----------|----------|
| `path` | glob 패턴 (`*`, `**`, `?` 지원) |
| `method` | 정확 매칭 (대소문자 무관) |
| `src_ip` | 정확 매칭 |
| `src_ip_cidr` | CIDR 포함 여부 |
| `query_param` | 키=값 정확 매칭 |
| `header` | 키=값 정확 매칭 (대소문자 무관) |

scope 조건이 없는 규칙은 모든 요청에 매칭 (catch-all).

### 3.3 우선순위 정렬

정책 로드 시 규칙을 priority 오름차순으로 정렬하여 메모리에 유지.
동률(동일 priority) 규칙은 YAML 파일 내 선언 순서를 유지한다 (ADR-002).

## 4. 정책 로더 (ADR-003)

### 4.1 로드 흐름

```
load_policy(filepath):
    1. 파일 읽기 (io.open)
    2. YAML 파싱 (lyaml 또는 lua-yaml)
    3. Schema validation
       - 필수 필드 검증 (id, priority, action)
       - 타입 검증
       - id 유일성 검증
    4. 충돌/음영 감지 (conflict_detector)
       - 충돌 → WARN 로그, 계속 진행
    5. SHA256 해시 계산 (전체 파일 내용)
    6. 정렬된 규칙 트리 생성
    7. luagate_policy["policy:<version>:blob"] / meta 저장
    8. active_policy_version 포인터 교체
```

### 4.2 Schema Validation

```lua
-- 필수 필드 검증
assert(rule.id, "rule.id is required")
assert(type(rule.priority) == "number", "rule.priority must be number")
assert(rule.action == "allow" or rule.action == "deny",
       "rule.action must be 'allow' or 'deny'")

-- id 유일성
local seen_ids = {}
for _, rule in ipairs(rules) do
    assert(not seen_ids[rule.id], "duplicate rule id: " .. rule.id)
    seen_ids[rule.id] = true
end
```

### 4.3 Hot Reload (ADR-003)

Worker 버전 확인 로직 (`access_by_lua` 진입 시):

```lua
-- lua/luagate/policy/evaluator.lua (module-level upvalue)
-- ngx.ctx는 요청 단위 스코프이므로 policy 캐시에 사용하지 않는다.
-- Worker-level Lua module state (upvalue)로 캐시한다.
local _cached_policy = nil          -- worker-level 캐시
local _cached_version = nil         -- 캐시된 정책 버전

local function get_policy()
    local current_version = ngx.shared.luagate_policy:get("active_policy_version")

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

## 6. 관리 API 연동

| 엔드포인트 | 기능 |
|-----------|------|
| `GET /api/v1/policies` | staged 정책 YAML 반환 (파일 기준 canonical source) |
| `PUT /api/v1/policies` | 새 정책 저장 + 검증 (reload 미포함) |
| `POST /api/v1/policies/reload` | 즉시 reload 트리거 |
| `GET /api/v1/policies/status` | 버전, 충돌 목록, 마지막 reload 시각 |

## 7. 의존성

- [ADR-002](../design/adr/ADR-002-policy-evaluation-conflict-detection.md) — 평가 규칙
- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — Hot Reload
- [spec/admin-api.md](./admin-api.md) — 정책 관련 API
