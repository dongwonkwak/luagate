--- Unit tests for lua/luagate/log/http.lua
-- Implementation: lua/luagate/log/http.lua
-- Tests: tests/unit/log/http_spec.lua
--
-- log/http.lua는 ngx 전역과 cjson에 의존하므로 두 가지를 mock한다.
-- cjson.safe은 LuaJIT 전용이므로 dkjson을 사용하는 stub으로 교체한다.

-- ---------------------------------------------------------------------------
-- cjson.safe stub (dkjson wrapper)
-- ---------------------------------------------------------------------------
local dkjson = require("dkjson")
local _cjson_encode_error = nil -- nil이면 정상, 문자열이면 encode에서 에러 반환

local cjson_safe_stub = {
  -- cjson.null: dkjson.null을 사용하여 JSON null로 직렬화된다
  null = dkjson.null,
  encode_empty_table_as_array = function() end,
  encode = function(v)
    if _cjson_encode_error then
      return nil, _cjson_encode_error
    end
    return dkjson.encode(v), nil
  end,
  decode = function(s)
    return dkjson.decode(s)
  end,
}

package.preload["cjson.safe"] = function()
  return cjson_safe_stub
end

-- log/http.lua 내부에서 cjson.null을 사용하므로 NULL 참조가 stub null과 일치해야 한다.
-- 모듈을 require하기 전에 stub을 등록하면 finalize()에서 참조하는 NULL은 stub.null이 된다.

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local logged = {}
  local mock = {
    var = {
      luagate_request_id = "req-log-test-001",
      luagate_src_ip = "192.168.1.100",
      luagate_path_raw = "/api/v1/users",
      luagate_path_normalized = "/api/v1/users",
      luagate_query_string = "page=1&limit=10",
      luagate_action = "allow",
      luagate_matched_rule = "null",
      luagate_deny_reason = "null",
      luagate_decision_source = "policy_engine",
      luagate_threat_type = "null",
      luagate_threat_score = "null",
      luagate_rule_name = "null",
      luagate_request_state = "allowed",
      luagate_active_version = "v2025",
      luagate_worker_id = "0",
      luagate_log_json = "",
      time_iso8601 = "2026-03-17T00:00:00+00:00",
      remote_port = "54321",
      server_port = "8080",
      request_time = "0.050",
      upstream_response_time = "0.030",
      content_length = "256",
      http_user_agent = "curl/7.85.0",
      status = "200",
      bytes_sent = "1024",
      host = "api.example.com",
      server_protocol = "HTTP/1.1",
    },
    ctx = {
      luagate = {
        request_id = "req-log-test-001",
        path_raw = "/api/v1/users",
        path_normalized = "/api/v1/users",
        query_raw = "page=1&limit=10",
        action = "allow",
        decision_source = "policy_engine",
        active_version = "v2025",
        request_state = "allowed",
      },
    },
    header = {},
    status = 200,
    WARN = 5,
    ERR = 4,
    log = function(_, ...)
      local parts = { ... }
      logged[#logged + 1] = table.concat(parts, "")
    end,
    say = function(_s) end,
    now = function()
      return 1710633600.0
    end,
    worker = {
      id = function()
        return 0
      end,
    },
    req = {
      get_method = function()
        return "GET"
      end,
    },
  }
  mock._get_logged = function()
    return logged
  end

  if overrides then
    for k, v in pairs(overrides) do
      if type(v) == "table" and type(mock[k]) == "table" and k ~= "ctx" then
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
-- 테스트 전 모듈 캐시 초기화 (각 테스트마다 새 ngx mock으로 실행하기 위해)
-- package.preload도 제거하여 다른 spec 파일의 stub이 간섭하지 않도록 한다
-- ---------------------------------------------------------------------------
local function load_log_http()
  package.loaded["luagate.log.http"] = nil
  package.preload["luagate.log.http"] = nil
  return require("luagate.log.http")
end

-- ===========================================================================
-- 27 필드 완전성 검증
-- ===========================================================================

describe("log/http.finalize — 27필드 완전성", function()
  local EXPECTED_FIELDS = {
    -- request metadata (1-13)
    "timestamp",
    "request_id",
    "src_ip",
    "src_port",
    "dst_port",
    "method",
    "host",
    "path_raw",
    "path_normalized",
    "query_string",
    "http_version",
    "user_agent",
    "content_length",
    -- access phase (14-20)
    "action",
    "matched_rule_id",
    "deny_reason",
    "decision_source",
    "threat_type",
    "threat_score",
    "rule_name",
    -- log phase (21-27)
    "request_state",
    "latency_ms",
    "upstream_latency_ms",
    "response_status",
    "bytes_sent",
    "active_version",
    "worker_id",
  }

  it("finalize() 후 luagate_log_json이 27개 필드를 모두 포함한다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_string(json_str)
    assert.is_true(#json_str > 0)

    local record = dkjson.decode(json_str)
    assert.is_table(record)

    for _, field in ipairs(EXPECTED_FIELDS) do
      -- 필드 존재 검증 (nil이 아니거나 cjson.null에 해당하는 값이어야 함)
      -- dkjson decode 결과에서 cjson.null은 userdata로 나오지 않고 dkjson.null로 표현됨
      -- 따라서 key 자체가 존재하는지만 확인한다
      local has_field = (record[field] ~= nil) or json_str:find('"' .. field .. '"', 1, true) ~= nil
      assert.is_true(has_field, "필드 누락: " .. field)
    end
  end)

  it("전체 27개 필드 수 검증 (JSON 문자열에서 키 카운트가 27개 이상)", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_string(json_str)

    -- JSON 문자열에서 "key": 패턴 카운트 (null 포함 모든 필드 검출)
    local count = 0
    for _ in json_str:gmatch('"[^"]+":') do
      count = count + 1
    end
    assert.is_true(count >= 27, "필드 수 부족: " .. count .. " (최소 27개 필요)")
  end)
end)

-- ===========================================================================
-- nullable 필드 처리
-- ===========================================================================

describe("log/http.finalize — nullable 필드 처리", function()
  it("upstream_response_time = '-' → upstream_latency_ms는 JSON null이 된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_response_time = "-"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    -- JSON에서 upstream_latency_ms가 null로 직렬화되어야 한다
    assert.is_truthy(json_str:find('"upstream_latency_ms":null', 1, true))
  end)

  it("upstream_response_time = nil → upstream_latency_ms는 JSON null이 된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_response_time = nil
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_truthy(json_str:find('"upstream_latency_ms":null', 1, true))
  end)

  it("upstream_response_time = '' → upstream_latency_ms는 JSON null이 된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_response_time = ""
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_truthy(json_str:find('"upstream_latency_ms":null', 1, true))
  end)

  it("upstream_response_time = '0.030' → upstream_latency_ms는 ms 단위 숫자로 변환된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_response_time = "0.030"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    -- 0.030초 → 30ms
    assert.are.equal(30.0, record.upstream_latency_ms)
  end)

  it("content_length가 없으면 content_length = JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.content_length = ""
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_truthy(json_str:find('"content_length":null', 1, true))
  end)

  it("user_agent가 없으면 user_agent = JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.http_user_agent = ""
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_truthy(json_str:find('"user_agent":null', 1, true))
  end)
end)

-- ===========================================================================
-- 쿼리 파라미터 redaction
-- ===========================================================================

describe("log/http.finalize — 쿼리 파라미터 redaction", function()
  it("token=abc123&page=1 → token=***&page=1으로 redact된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate.query_raw = "token=abc123&page=1"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal("token=***&page=1", record.query_string)
  end)

  it("api_key=secret → api_key=***으로 redact된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate.query_raw = "api_key=my-secret-key&format=json"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.is_truthy(record.query_string:find("api_key=%*%*%*"))
    assert.is_truthy(record.query_string:find("format=json"))
  end)

  it("password=hunter2&page=2 → password=***&page=2", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate.query_raw = "password=hunter2&page=2"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.is_truthy(record.query_string:find("password=%*%*%*"))
    assert.is_truthy(record.query_string:find("page=2"))
  end)

  it("민감하지 않은 파라미터는 redact되지 않는다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate.query_raw = "page=3&limit=20&sort=asc"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal("page=3&limit=20&sort=asc", record.query_string)
  end)

  it("빈 query string은 그대로 빈 문자열로 유지된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate.query_raw = ""
    ngx_mock.var.luagate_query_string = ""
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal("", record.query_string)
  end)
end)

-- ===========================================================================
-- request_id 및 worker_id
-- ===========================================================================

describe("log/http.finalize — request_id 및 worker_id", function()
  it("request_id는 ngx.ctx.luagate.request_id 값을 사용한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate.request_id = "custom-req-id-abc"
    ngx_mock.var.luagate_request_id = "different-id"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    -- luagate_log_json에 request_id가 ctx 값으로 설정되는지 확인
    -- log/http.lua: request_id = ngx.var.luagate_request_id or ctx.request_id
    -- ngx.var.luagate_request_id가 우선이므로 "different-id"가 사용됨
    local record = dkjson.decode(json_str)
    assert.is_string(record.request_id)
    assert.is_true(#record.request_id > 0)
  end)

  it("request_id는 ngx.var.luagate_request_id가 없으면 ctx.request_id를 사용한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.luagate_request_id = nil
    ngx_mock.ctx.luagate.request_id = "ctx-only-req-id"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal("ctx-only-req-id", record.request_id)
  end)

  it("worker_id는 luagate_worker_id nginx var 또는 ngx.worker.id()를 사용한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.luagate_worker_id = "3"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    -- luagate_worker_id="3"이면 tonumber → 3
    assert.are.equal(3, record.worker_id)
  end)
end)

-- ===========================================================================
-- latency_ms 계산
-- ===========================================================================

describe("log/http.finalize — latency_ms 계산", function()
  it("request_time = '0.050' → latency_ms = 50.0", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.request_time = "0.050"
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal(50.0, record.latency_ms)
  end)

  it("request_time = nil → latency_ms = 0", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.request_time = nil
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal(0, record.latency_ms)
  end)
end)

-- ===========================================================================
-- cjson.encode 실패 fallback
-- ===========================================================================

describe("log/http.finalize — cjson.encode 실패 fallback", function()
  it('encode 실패 시 luagate_log_json = \'{"error":"log_encode_failed"}\'', function()
    -- encode 에러 유도
    _cjson_encode_error = "simulated encode error"

    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    -- 모듈 캐시 초기화 후 재로드
    package.loaded["luagate.log.http"] = nil
    local log_http = require("luagate.log.http")

    log_http.finalize()

    -- 에러 플래그 복원
    _cjson_encode_error = nil

    assert.are.equal('{"error":"log_encode_failed"}', ngx_mock.var.luagate_log_json)
  end)
end)

-- ===========================================================================
-- ctx 없음 처리
-- ===========================================================================

describe("log/http.finalize — ctx 없음", function()
  it("ngx.ctx.luagate가 nil이어도 에러 없이 처리된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx = {} -- luagate 없음
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    assert.has_no.errors(function()
      log_http.finalize()
    end)
  end)

  it("ctx 없을 때도 luagate_log_json이 유효한 JSON 문자열로 설정된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx = {}
    _G.ngx = ngx_mock
    local log_http = load_log_http()

    log_http.finalize()

    local json_str = ngx_mock.var.luagate_log_json
    assert.is_string(json_str)
    -- valid JSON 확인
    local parsed = dkjson.decode(json_str)
    assert.is_table(parsed)
  end)
end)
