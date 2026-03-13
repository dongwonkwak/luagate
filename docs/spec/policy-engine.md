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
    7. luagate_policy shared dict에 atomic 저장
    8. policy_version 업데이트
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
local current_version = ngx.shared.luagate_policy:get("policy_version")
if current_version ~= ngx.ctx._local_policy_version then
    -- 새 정책 로드
    local policy = ngx.shared.luagate_policy:get("policy_tree")
    ngx.ctx._local_policy = cjson.decode(policy)
    ngx.ctx._local_policy_version = current_version
end
```

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
| `GET /api/v1/policies` | 현재 정책 YAML 반환 |
| `PUT /api/v1/policies` | 새 정책 저장 + 검증 (reload 미포함) |
| `POST /api/v1/policies/reload` | 즉시 reload 트리거 |
| `GET /api/v1/policies/status` | 버전, 충돌 목록, 마지막 reload 시각 |

## 7. 의존성

- [ADR-002](../design/adr/ADR-002-policy-evaluation-conflict-detection.md) — 평가 규칙
- [ADR-003](../design/adr/ADR-003-policy-storage-hot-reload.md) — Hot Reload
- [spec/admin-api.md](./admin-api.md) — 정책 관련 API
