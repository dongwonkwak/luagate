---
description: "정책 Hot Reload 구현 또는 수정 시 절차. 7단계 파이프라인 + LKG 보장 + versioned keyspace."
---

# Skill: Hot Reload 번들 구현/수정

## Hot Reload 7단계 파이프라인

```
1. PUT /api/v1/policies 수신
   └─ conf/policies.yaml atomic write (tmp file + rename)

2. POST /api/v1/policies/reload 수신 (또는 자동 트리거)

3. 파일 읽기 (io.open — init_by_lua 또는 admin handler에서만)
   └─ 실패 시: 500 ReloadFailed, LKG 유지

4. YAML 파싱 (lyaml)
   └─ 파싱 에러: 500 ReloadFailed, LKG 유지

5. Schema validation + conflict/shadow 감지
   └─ 검증 실패: 400 ValidationError
   └─ 충돌/음영: WARN 로그 + warnings 수집, 계속 진행

6. SHA256 해시 계산 (전체 파일 내용)
   └─ blob_key = "policy:" .. sha256 .. ":blob"

7. shared dict 업데이트 (versioned keyspace + pointer swap)
   └─ safe_set(blob_key, policy_json)
   └─ 성공 시: set("active_policy_version", sha256)
   └─ safe_set 실패 (no memory): 500 ReloadFailed, LKG 유지
```

## 구현 코드 패턴

### Atomic File Write

```lua
-- conf/policies.yaml atomic write
local tmp = filepath .. ".tmp." .. ngx.now()
local f = assert(io.open(tmp, "w"))
f:write(yaml_content)
f:close()
assert(os.rename(tmp, filepath))  -- atomic rename
```

### Versioned Keyspace + Pointer Swap

```lua
-- lua/luagate/policy/loader.lua
local function store_policy(sha256, policy_json)
    local blob_key = "policy:" .. sha256 .. ":blob"

    -- 1. blob 저장
    local ok, err, forcible = ngx.shared.luagate_policy:safe_set(blob_key, policy_json)
    if not ok then
        if err == "no memory" then
            ngx.log(ngx.ERR, "policy store: no memory, reload aborted")
            return false, "no memory"
        end
        ngx.log(ngx.ERR, "policy store error: ", err)
        return false, err
    end

    -- 2. active pointer 교체 (원자적)
    ngx.shared.luagate_policy:set("active_policy_version", sha256)
    return true, nil
end
```

### Worker-level 캐시 갱신 (evaluator.lua)

```lua
-- module-level upvalue
local _cached_policy = nil
local _cached_version = nil

local function get_policy()
    local current_version = ngx.shared.luagate_policy:get("active_policy_version")

    -- 버전 일치: shared dict 접근 없이 캐시 반환
    if _cached_version == current_version and _cached_policy ~= nil then
        return _cached_policy
    end

    -- 버전 변경: blob 로드 + upvalue 갱신
    local blob_key = "policy:" .. current_version .. ":blob"
    local policy_json = ngx.shared.luagate_policy:get(blob_key)
    if not policy_json then
        ngx.log(ngx.ERR, "policy blob not found: ", current_version, " (LKG maintained)")
        return _cached_policy  -- LKG 유지
    end

    _cached_policy = cjson.decode(policy_json)
    _cached_version = current_version
    return _cached_policy
end
```

## 체크리스트

- [ ] atomic file write (tmp + rename)
- [ ] YAML 파싱 에러 시 LKG 유지 (active pointer 변경 없음)
- [ ] safe_set no-memory 에러 처리
- [ ] versioned keyspace 사용 (`policy:<hash>:blob`)
- [ ] active_policy_version 포인터 교체는 blob 저장 성공 후에만
- [ ] worker-level upvalue 캐시 (`_cached_policy`, `_cached_version`) — ngx.ctx 아님
- [ ] 충돌/음영 감지 경고 수집
- [ ] 감사 로그 (`policy_reload` 이벤트)
- [ ] 409 Conflict: 동시 reload 시 두 번째 요청 거부

## 참조

- `docs/spec/policy-engine.md` §4 — 로더 상세
- `docs/design/adr/ADR-003` — Hot Reload 시맨틱스
- `.claude/knowledge/architecture.md` — Hot Reload 7단계 + zone map
- `lua/luagate/policy/loader.lua` — 구현 위치
