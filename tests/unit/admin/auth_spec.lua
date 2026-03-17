--- Unit tests for lua/luagate/admin/auth.lua
-- Implementation: lua/luagate/admin/auth.lua
-- Tests: tests/unit/admin/auth_spec.lua
--
-- auth.lua는 OpenResty ngx 전역 + bit 모듈에 의존하므로
-- busted (Lua 5.4) 환경에서 stub을 주입한다.

-- ---------------------------------------------------------------------------
-- cjson.safe stub (dkjson wrapper — LuaJIT 없는 busted 환경)
-- ---------------------------------------------------------------------------
package.preload["cjson.safe"] = function()
  local dkjson = require("dkjson")
  return {
    encode = dkjson.encode,
    decode = dkjson.decode,
    null = {},
  }
end

-- ---------------------------------------------------------------------------
-- bit stub (Lua 5.4 native bitwise operators → LuaJIT bit API 에뮬레이션)
-- ---------------------------------------------------------------------------
package.preload["bit"] = function()
  return {
    bxor = function(a, b)
      return a ~ b
    end,
    bor = function(a, b)
      return a | b
    end,
    band = function(a, b)
      return a & b
    end,
    bnot = function(a)
      return ~a
    end,
  }
end

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local exited_with = nil
  local logged = {}
  local said = {}

  local mock = {
    var = {
      remote_addr = "10.0.0.1",
      uri = "/api/policies",
    },
    ctx = {},
    header = {},
    status = 0,
    -- Log levels (match OpenResty constants)
    EMERG = 0,
    ALERT = 1,
    CRIT = 2,
    ERR = 3,
    WARN = 4,
    NOTICE = 5,
    INFO = 6,
    DEBUG = 7,
    log = function(level, ...)
      local parts = {}
      for _, v in ipairs({ ... }) do
        parts[#parts + 1] = tostring(v)
      end
      logged[#logged + 1] = { level = level, msg = table.concat(parts, "") }
    end,
    exit = function(code)
      exited_with = code
    end,
    say = function(s)
      said[#said + 1] = s
    end,
    utctime = function()
      return "2026-03-17 00:00:00"
    end,
    req = {
      get_headers = function()
        return {}
      end,
    },
  }

  -- 추적용 getter
  mock._get_exited = function()
    return exited_with
  end
  mock._get_logged = function()
    return logged
  end
  mock._get_said = function()
    return said
  end
  mock._reset_tracking = function()
    exited_with = nil
    for i = 1, #logged do
      logged[i] = nil
    end
    for i = 1, #said do
      said[i] = nil
    end
    mock.status = 0
    mock.header = {}
  end

  -- override 적용
  if overrides then
    for k, v in pairs(overrides) do
      if type(v) == "table" and type(mock[k]) == "table" then
        for k2, v2 in pairs(v) do
          mock[k][k2] = v2
        end
      else
        mock[k] = v
      end
    end
  end

  return mock
end

-- ---------------------------------------------------------------------------
-- 모듈 로드
-- ---------------------------------------------------------------------------
local _saved_ngx = _G.ngx
_G.ngx = make_ngx()

-- os.getenv stub: 테스트에서 제어 가능하도록 래핑
local _env_override = nil -- nil이면 실제 getenv 사용, 테이블이면 stub 반환

local _original_os_getenv = os.getenv
os.getenv = function(key) -- luacheck: ignore 122
  if _env_override ~= nil then
    return _env_override[key]
  end
  return _original_os_getenv(key)
end

local auth -- 테스트마다 fresh require

--- auth 모듈을 fresh require하는 헬퍼.
-- package.loaded를 제거하여 모듈 upvalue(_admin_token)를 초기화한다.
local function load_auth()
  package.loaded["luagate.admin.auth"] = nil
  return require("luagate.admin.auth")
end

-- ---------------------------------------------------------------------------
-- 전체 테스트 완료 후 정리
-- ---------------------------------------------------------------------------
teardown(function()
  _G.ngx = _saved_ngx
  os.getenv = _original_os_getenv -- luacheck: ignore 122
  package.preload["cjson.safe"] = nil
  package.preload["bit"] = nil
  package.loaded["cjson.safe"] = nil
  package.loaded["bit"] = nil
  package.loaded["luagate.admin.auth"] = nil
end)

-- ===========================================================================
-- init()
-- ===========================================================================
describe("auth.init", function()
  before_each(function()
    _G.ngx = make_ngx()
    auth = load_auth()
  end)

  it("환경변수 미설정 시 false 반환 + EMERG 로그", function()
    _env_override = {} -- LUAGATE_ADMIN_TOKEN 없음
    auth = load_auth()

    local ok = auth.init()

    assert.is_false(ok)
    local logged = _G.ngx._get_logged()
    local found_emerg = false
    for _, entry in ipairs(logged) do
      if entry.level == _G.ngx.EMERG and entry.msg:find("LUAGATE_ADMIN_TOKEN not set") then
        found_emerg = true
        break
      end
    end
    assert.is_true(found_emerg, "EMERG 로그에 'LUAGATE_ADMIN_TOKEN not set' 메시지가 포함되어야 한다")
  end)

  it("빈 문자열 토큰 시 false 반환 + EMERG 로그", function()
    _env_override = { LUAGATE_ADMIN_TOKEN = "" }
    auth = load_auth()

    local ok = auth.init()

    assert.is_false(ok)
    local logged = _G.ngx._get_logged()
    local found_emerg = false
    for _, entry in ipairs(logged) do
      if entry.level == _G.ngx.EMERG then
        found_emerg = true
        break
      end
    end
    assert.is_true(found_emerg)
  end)

  it("토큰 32바이트 미만 시 false 반환 + EMERG 로그", function()
    _env_override = { LUAGATE_ADMIN_TOKEN = "short-token-only-20chars" } -- 24 bytes
    auth = load_auth()

    local ok = auth.init()

    assert.is_false(ok)
    local logged = _G.ngx._get_logged()
    local found_too_short = false
    for _, entry in ipairs(logged) do
      if entry.level == _G.ngx.EMERG and entry.msg:find("too short") then
        found_too_short = true
        break
      end
    end
    assert.is_true(found_too_short, "EMERG 로그에 'too short' 메시지가 포함되어야 한다")
  end)

  it("유효 토큰 (>= 32바이트) 시 true 반환", function()
    _env_override = { LUAGATE_ADMIN_TOKEN = "a]veryLongSecretTokenThatIs32byt" } -- exactly 32
    auth = load_auth()

    local ok = auth.init()

    assert.is_true(ok)
  end)

  it("유효 토큰 시 NOTICE 로그에 토큰 길이가 포함된다", function()
    local token = "a]veryLongSecretTokenThatIs32bytes+extra" -- 40 bytes
    _env_override = { LUAGATE_ADMIN_TOKEN = token }
    auth = load_auth()

    auth.init()

    local logged = _G.ngx._get_logged()
    local found_notice = false
    for _, entry in ipairs(logged) do
      if entry.level == _G.ngx.NOTICE and entry.msg:find("token length: " .. #token) then
        found_notice = true
        break
      end
    end
    assert.is_true(found_notice, "NOTICE 로그에 토큰 길이가 포함되어야 한다")
  end)

  it("유효 토큰 시 로그에 토큰 값이 노출되지 않는다 (ADR-004 ss6.2)", function()
    local token = "super-secret-token-must-never-appear-in-logs"
    _env_override = { LUAGATE_ADMIN_TOKEN = token }
    auth = load_auth()

    auth.init()

    local logged = _G.ngx._get_logged()
    for _, entry in ipairs(logged) do
      assert.is_nil(entry.msg:find(token, 1, true), "토큰 값이 로그에 노출되면 안 된다")
    end
  end)
end)

-- ===========================================================================
-- verify()
-- ===========================================================================
describe("auth.verify", function()
  local VALID_TOKEN = "test-admin-token-that-is-at-least-32-bytes-long"

  before_each(function()
    _G.ngx = make_ngx()
    _env_override = { LUAGATE_ADMIN_TOKEN = VALID_TOKEN }
    auth = load_auth()
    auth.init()
    _G.ngx._reset_tracking()
  end)

  -- /health 경로 면제
  it("/health 경로 요청 시 인증 없이 true 반환", function()
    _G.ngx.var.uri = "/health"

    local ok = auth.verify()

    assert.is_true(ok)
    assert.is_nil(_G.ngx._get_exited(), "ngx.exit가 호출되지 않아야 한다")
  end)

  it("/health 경로에서는 Authorization 헤더가 없어도 통과", function()
    _G.ngx.var.uri = "/health"
    _G.ngx.req.get_headers = function()
      return {}
    end

    local ok = auth.verify()

    assert.is_true(ok)
  end)

  -- Authorization 헤더 누락
  it("Authorization 헤더 없을 때 401 + audit missing_token", function()
    _G.ngx.req.get_headers = function()
      return {}
    end

    auth.verify()

    assert.are.equal(401, _G.ngx.status)
    assert.are.equal(401, _G.ngx._get_exited())
    -- audit 로그 확인
    local logged = _G.ngx._get_logged()
    local found_missing = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("missing_token") then
        found_missing = true
        break
      end
    end
    assert.is_true(found_missing, "audit 로그에 'missing_token' reason이 포함되어야 한다")
  end)

  -- Basic 인증 방식 (Bearer가 아닌 경우)
  it("Authorization: Basic xxx 시 401 + audit malformed_header", function()
    _G.ngx.req.get_headers = function()
      return { Authorization = "Basic dXNlcjpwYXNz" }
    end

    auth.verify()

    assert.are.equal(401, _G.ngx.status)
    assert.are.equal(401, _G.ngx._get_exited())
    local logged = _G.ngx._get_logged()
    local found_malformed = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("malformed_header") then
        found_malformed = true
        break
      end
    end
    assert.is_true(found_malformed, "audit 로그에 'malformed_header' reason이 포함되어야 한다")
  end)

  -- 잘못된 토큰
  it("잘못된 Bearer 토큰 시 401 + audit invalid_token", function()
    _G.ngx.req.get_headers = function()
      return { Authorization = "Bearer wrong-token-definitely-not-valid" }
    end

    auth.verify()

    assert.are.equal(401, _G.ngx.status)
    assert.are.equal(401, _G.ngx._get_exited())
    local logged = _G.ngx._get_logged()
    local found_invalid = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("invalid_token") then
        found_invalid = true
        break
      end
    end
    assert.is_true(found_invalid, "audit 로그에 'invalid_token' reason이 포함되어야 한다")
  end)

  -- 올바른 토큰
  it("올바른 Bearer 토큰 시 true 반환", function()
    _G.ngx.req.get_headers = function()
      return { Authorization = "Bearer " .. VALID_TOKEN }
    end

    local ok = auth.verify()

    assert.is_true(ok)
    assert.is_nil(_G.ngx._get_exited(), "ngx.exit가 호출되지 않아야 한다")
  end)

  -- init() 미호출
  it("init() 미호출 시 401 + audit token_not_initialised", function()
    -- fresh module without init()
    auth = load_auth()
    -- init() 호출하지 않음

    auth.verify()

    assert.are.equal(401, _G.ngx.status)
    assert.are.equal(401, _G.ngx._get_exited())
    local logged = _G.ngx._get_logged()
    local found_not_init = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("token_not_initialised") or entry.msg:find("not initialised") then
        found_not_init = true
        break
      end
    end
    assert.is_true(
      found_not_init,
      "audit 로그에 'token_not_initialised' 또는 'not initialised' 메시지가 포함되어야 한다"
    )
  end)

  -- reset() 후 verify()
  it("reset() 후 verify() 호출 시 401 + token_not_initialised", function()
    auth.reset()

    auth.verify()

    assert.are.equal(401, _G.ngx.status)
    assert.are.equal(401, _G.ngx._get_exited())
  end)

  -- 401 응답 본문 확인
  it("인증 실패 시 JSON 에러 본문이 ngx.say로 전송된다", function()
    _G.ngx.req.get_headers = function()
      return {}
    end

    auth.verify()

    local said = _G.ngx._get_said()
    assert.are.equal(1, #said)
    assert.truthy(said[1]:find('"error"'), "응답 본문에 error 필드가 있어야 한다")
    assert.truthy(said[1]:find("Unauthorized"), "응답 본문에 Unauthorized가 포함되어야 한다")
  end)

  -- 401 응답 헤더 확인
  it("인증 실패 시 Content-Type: application/json + Cache-Control: no-store 헤더 설정", function()
    _G.ngx.req.get_headers = function()
      return {}
    end

    auth.verify()

    assert.are.equal("application/json", _G.ngx.header["Content-Type"])
    assert.are.equal("no-store", _G.ngx.header["Cache-Control"])
  end)

  -- audit 로그에 actor_ip와 path 포함
  it("audit 로그에 actor_ip와 path가 포함된다", function()
    _G.ngx.var.remote_addr = "192.168.1.100"
    _G.ngx.var.uri = "/api/policies"
    _G.ngx.req.get_headers = function()
      return {}
    end

    auth.verify()

    local logged = _G.ngx._get_logged()
    local found_ip = false
    local found_path = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("192.168.1.100") then
        found_ip = true
      end
      if entry.msg:find("/api/policies") then
        found_path = true
      end
    end
    assert.is_true(found_ip, "audit 로그에 actor_ip가 포함되어야 한다")
    assert.is_true(found_path, "audit 로그에 path가 포함되어야 한다")
  end)

  -- Bearer 키워드만 있고 토큰이 없는 경우
  it("'Bearer ' (공백 후 토큰 없음)은 malformed_header", function()
    _G.ngx.req.get_headers = function()
      return { Authorization = "Bearer " }
    end

    auth.verify()

    assert.are.equal(401, _G.ngx.status)
  end)
end)

-- ===========================================================================
-- constant_time_compare()
-- ===========================================================================
describe("auth._constant_time_compare", function()
  local ctc

  before_each(function()
    _G.ngx = make_ngx()
    _env_override = { LUAGATE_ADMIN_TOKEN = "dummy-token-for-loading-only-32bytes" }
    auth = load_auth()
    ctc = auth._constant_time_compare
  end)

  it("동일 문자열 비교 시 true 반환", function()
    assert.is_true(ctc("hello-world", "hello-world"))
  end)

  it("같은 길이 다른 문자열 비교 시 false 반환", function()
    assert.is_false(ctc("hello-world", "hello-worle"))
  end)

  it("다른 길이 문자열 비교 시 false 반환", function()
    assert.is_false(ctc("short", "much-longer-string"))
  end)

  it("빈 문자열 두 개 비교 시 true 반환", function()
    assert.is_true(ctc("", ""))
  end)

  it("빈 문자열과 비어있지 않은 문자열 비교 시 false 반환", function()
    assert.is_false(ctc("", "non-empty"))
  end)

  it("긴 동일 문자열 비교 시 true 반환", function()
    local long = string.rep("abcdefghij", 100) -- 1000 bytes
    assert.is_true(ctc(long, long))
  end)

  it("마지막 바이트만 다른 경우 false 반환", function()
    local a = "identical-prefix-then-a"
    local b = "identical-prefix-then-b"
    assert.is_false(ctc(a, b))
  end)
end)
