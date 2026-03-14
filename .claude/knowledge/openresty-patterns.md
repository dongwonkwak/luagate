# OpenResty 패턴 & 안티패턴 & Gotchas

> 참조: `docs/spec/architecture.md`, `docs/spec/http-pipeline.md`, `docs/spec/stream-pipeline.md`

## 핵심 패턴

### 1. ngx.ctx: 요청 범위 데이터 전달

`ngx.ctx`는 요청 단위(request-scoped) 테이블이며, 요청 종료 시 GC된다.
**절대로 정책 캐시나 worker 수명 데이터를 ngx.ctx에 저장하지 않는다.**

```lua
-- GOOD: 요청별 데이터 저장
ngx.ctx.luagate = {
    request_id      = generate_uuid(),
    path_raw        = ngx.var.request_uri,
    path_normalized = nil,  -- rewrite_by_lua에서 채움
    action          = nil,  -- access_by_lua에서 채움
}

-- BAD: 정책 캐시를 ngx.ctx에 저장 (매 요청마다 shared dict 조회 발생)
ngx.ctx.policy = ngx.shared.luagate_policy:get("blob")  -- 절대 금지
```

### 2. Module-level Upvalue: Worker 범위 캐시

```lua
-- GOOD: worker 수명 캐시
local _cached_policy = nil
local _cached_version = nil

local function get_policy()
    local v = ngx.shared.luagate_policy:get("active_policy_version")
    if _cached_version == v then return _cached_policy end
    -- reload ...
end
```

### 3. shared dict safe_set 원자성

`safe_set`은 **key 단위** 원자성만 보장한다. 복수 key 간 원자성은 보장되지 않는다.
버전드 keyspace + active pointer 방식으로 multi-key consistency를 달성한다.

```lua
-- GOOD: versioned keyspace + pointer swap
local blob_key = "policy:" .. sha256 .. ":blob"
local ok, err, forcible = ngx.shared.luagate_policy:safe_set(blob_key, policy_json)
if not ok then
    if err == "no memory" then
        -- no memory 에러: 기존 항목 강제 삭제(forcible=true)로 공간 확보 후 재시도하거나
        -- fallback: 현재 active 정책 유지
        ngx.log(ngx.ERR, "shared dict no memory, policy reload aborted")
        return false
    end
    ngx.log(ngx.ERR, "safe_set failed: ", err)
    return false
end
-- 성공 후 포인터 교체
ngx.shared.luagate_policy:set("active_policy_version", sha256)

-- BAD: 하나의 key로 정책 전체를 원자 교체 시도 (크기 제한 위험)
ngx.shared.luagate_policy:set("policy", policy_json)  -- 구버전 패턴
```

### 4. 안정 정렬 (stable sort)

LuaJIT의 `table.sort`는 불안정 정렬이다. 동일 priority 규칙의 YAML 선언 순서를 보장하려면
original_index를 키로 추가 후 비교해야 한다.

```lua
-- GOOD: stable sort
for i, rule in ipairs(rules) do
    rule._original_index = i
end
table.sort(rules, function(a, b)
    if a.priority ~= b.priority then
        return a.priority < b.priority
    end
    return a._original_index < b._original_index  -- 동률 시 원래 순서 유지
end)

-- BAD: priority만 비교 (동률 시 비결정론적)
table.sort(rules, function(a, b) return a.priority < b.priority end)
```

### 5. Lua 핸들러 내 *_by_lua_block / *_by_lua_file 사용

```nginx
# GOOD: 블록 또는 파일 참조 방식
access_by_lua_block {
    require("luagate.policy.evaluator").evaluate()
}

access_by_lua_file /usr/local/luagate/lua/access.lua;

# BAD: content_by_lua는 구식 인라인 방식 (단일 라인 제약)
# content_by_lua "ngx.say('hello')";  -- 가능하지만 권장 안함
```

## 안티패턴 (하지 말 것)

### ❌ Blocking I/O in handlers

```lua
-- BAD: io.open은 blocking — worker 이벤트 루프 블로킹
local f = io.open("/etc/luagate/policy.yaml")
local content = f:read("*all")

-- GOOD: init_by_lua에서 1회 로드 후 shared dict에 저장
```

### ❌ log_by_lua에서 cosocket (네트워크 I/O)

```lua
-- BAD: log phase에서 cosocket 사용 불가 (OpenResty 제약)
-- log_by_lua 단계에서는 ngx.socket, httpc 등 cosocket 계열 API를 사용할 수 없다.
-- non-blocking socket logger가 필요하면 timer(ngx.timer.at)를 사용하거나
-- Nginx native access_log를 활용한다.

-- BAD
log_by_lua_block {
    local httpc = require("resty.http").new()  -- cosocket → 에러
    httpc:request_uri("http://log-aggregator/ingest", ...)
}

-- GOOD: Nginx native access_log 활용
-- log_by_lua에서는 ngx.var 설정 + Nginx log_format으로 기록
```

### ❌ Lua access_log 대체

```lua
-- BAD: Lua io.write로 access_log 직접 작성
-- 이유: USR1 rotate 시그널이 Nginx 관리 파일 핸들에만 작용
--       Lua가 직접 연 핸들은 rotate 후 구 파일에 계속 씀
local f = io.open("/var/log/luagate/access.log", "a")
f:write(json_line .. "\n")  -- 절대 금지
```

### ❌ 전역 변수

```lua
-- BAD: 전역 변수 선언
policy_cache = {}  -- worker간 격리 안됨, 예측 불가

-- GOOD: module-level local
local _cache = {}
```

### ❌ ngx.worker.id() 대신 PID 사용

```lua
-- BAD: PID는 reload 시 변경, 인덱스 범위 불예측
local pid = ngx.worker.pid()

-- GOOD: worker.id()는 0부터 worker_processes-1 범위의 안정적 인덱스
local wid = ngx.worker.id()
```

## Phase별 가능한 API

| API | init | rewrite | access | content | log | preread (stream) |
|-----|------|---------|--------|---------|-----|-----------------|
| `ngx.shared` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `ngx.ctx` | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `ngx.req.*` | ❌ | ✅ | ✅ | ✅ | ⚠️ | ✅ |
| `cosocket` | ❌ | ✅ | ✅ | ✅ | ❌ | ✅ |
| `ngx.exit()` | ❌ | ✅ | ✅ | ✅ | ❌ | ✅ |

> ⚠️ log 단계에서 `ngx.req.*`는 읽기만 가능, 수정 불가

## Gotchas

1. **`ngx.req.read_body()` 위치**: `access_by_lua` 이전에 `lua_need_request_body on`으로 설정하거나 명시적으로 호출해야 함. `log_by_lua`에서는 body 이미 소비됨.
2. **stream preread buffer 소비 주의**: `ngx.req.socket()`으로 읽으면 버퍼가 소비됨. peek 구현 시 receive/unread 패턴 사용.
3. **`ffi.cast` 수명**: Lua 문자열을 `ffi.cast("const char*", s)`로 전달 시, Lua GC가 문자열을 소유. FFI 호출 완료 전까지 Lua 변수 참조를 유지해야 함.
4. **`safe_set` forcible**: 메모리 부족 시 `safe_set`이 오래된 키를 삭제(`forcible=true`)하고 성공할 수 있음. 이 경우 다른 유효한 캐시가 삭제될 수 있으므로 zone 크기를 충분히 할당해야 함.
