# vim: set ft=perl:
# tests/integration/http/test_nginx_basic.t
#
# DON-97: Test::Nginx 기본 프록시 테스트
# nginx.conf 의 데이터 플레인(:8080)과 Admin API(:9090) 동작을 검증한다.
#
# 실행 방법:
#   prove -r tests/integration/http/
#   또는
#   make test-integration-http

use Test::Nginx::Socket 'no_plan';

# 테스트용 nginx 설정 — lua_shared_dict 포함
our $http_config = <<'_END_HTTP_CONFIG_';
    lua_package_path '/usr/local/openresty/lualib/?.lua;;';

    lua_shared_dict luagate_policy       10m;
    lua_shared_dict luagate_metrics       5m;
    lua_shared_dict luagate_connections   1m;
    lua_shared_dict luagate_state         1m;
    lua_shared_dict luagate_rate_limit    2m;

    map $http_x_request_id $luagate_request_id {
        default  $request_id;
        ~^.+$    $http_x_request_id;
    }

    map $request_uri $luagate_path_raw_default {
        ~^([^?]*) $1;
        default   $uri;
    }
_END_HTTP_CONFIG_

run_tests();

__DATA__

=== TEST 1: 헬스체크 — 200 OK 응답
--- http_config eval: $::http_config
--- config
    location /health {
        access_log off;
        default_type application/json;
        content_by_lua_block {
            local policy_ver = ngx.shared.luagate_policy:get("http:active_version") or "none"
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"status":"ok","policy_version":"' .. policy_ver .. '"}')
        }
    }
--- request
GET /health
--- response_code: 200
--- LAST



=== TEST 2: 헬스체크 — Content-Type이 application/json
--- http_config eval: $::http_config
--- config
    location /health {
        access_log off;
        default_type application/json;
        content_by_lua_block {
            local policy_ver = ngx.shared.luagate_policy:get("http:active_version") or "none"
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"status":"ok","policy_version":"' .. policy_ver .. '"}')
        }
    }
--- request
GET /health
--- response_headers
Content-Type: application/json
--- LAST



=== TEST 3: 헬스체크 — 초기 상태에서 policy_version이 "none"
--- http_config eval: $::http_config
--- config
    location /health {
        access_log off;
        default_type application/json;
        content_by_lua_block {
            local policy_ver = ngx.shared.luagate_policy:get("http:active_version") or "none"
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"status":"ok","policy_version":"' .. policy_ver .. '"}')
        }
    }
--- request
GET /health
--- response_body
{"status":"ok","policy_version":"none"}
--- LAST



=== TEST 4: 헬스체크 — luagate_policy에 버전이 있으면 해당 값 반환
--- http_config eval: $::http_config
--- config
    location /setup {
        content_by_lua_block {
            ngx.shared.luagate_policy:set("http:active_version", "v1.2.3")
            ngx.say("ok")
        }
    }
    location /health {
        access_log off;
        default_type application/json;
        content_by_lua_block {
            local policy_ver = ngx.shared.luagate_policy:get("http:active_version") or "none"
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"status":"ok","policy_version":"' .. policy_ver .. '"}')
        }
    }
--- request eval
["GET /setup", "GET /health"]
--- response_body eval
["ok\n", "{\"status\":\"ok\",\"policy_version\":\"v1.2.3\"}\n"]
--- LAST



=== TEST 5: Admin API /api/ — 501 Not Implemented 응답
--- http_config eval: $::http_config
--- config
    location /api/ {
        default_type application/json;
        content_by_lua_block {
            ngx.status = 501
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Not Implemented"}')
        }
    }
--- request
GET /api/
--- response_code: 501
--- LAST



=== TEST 6: Admin API /api/ — 응답 본문에 "Not Implemented" 포함
--- http_config eval: $::http_config
--- config
    location /api/ {
        default_type application/json;
        content_by_lua_block {
            ngx.status = 501
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Not Implemented"}')
        }
    }
--- request
GET /api/
--- response_body
{"error":"Not Implemented"}
--- LAST



=== TEST 7: Admin API /api/ — Content-Type이 application/json
--- http_config eval: $::http_config
--- config
    location /api/ {
        default_type application/json;
        content_by_lua_block {
            ngx.status = 501
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Not Implemented"}')
        }
    }
--- request
GET /api/
--- response_headers
Content-Type: application/json
--- LAST



=== TEST 8: Admin API 알 수 없는 경로 — 404 반환
--- http_config eval: $::http_config
--- config
    location / {
        return 404;
    }
--- request
GET /unknown-path
--- response_code: 404
--- LAST



=== TEST 9: 데이터 플레인 — luagate_policy shared dict 접근 가능
--- http_config eval: $::http_config
--- config
    location /check-dict {
        content_by_lua_block {
            -- luagate_policy dict가 접근 가능한지 확인
            local ok, err = ngx.shared.luagate_policy:set("__test__", "1")
            if not ok then
                ngx.status = 500
                ngx.say("dict_error: " .. (err or "unknown"))
                return
            end
            ngx.shared.luagate_policy:delete("__test__")
            ngx.say("dict_ok")
        }
    }
--- request
GET /check-dict
--- response_code: 200
--- response_body
dict_ok
--- LAST



=== TEST 10: Nginx 변수 — luagate_action 기본값이 "allow"
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /check-vars {
        content_by_lua_block {
            ngx.say(ngx.var.luagate_action)
        }
    }
--- request
GET /check-vars
--- response_body
allow
--- LAST



=== TEST 11: Nginx 변수 — luagate_decision_source 기본값이 "nginx_core"
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /check-vars {
        content_by_lua_block {
            ngx.say(ngx.var.luagate_decision_source)
        }
    }
--- request
GET /check-vars
--- response_body
nginx_core
--- LAST



=== TEST 12: Nginx 변수 — rewrite_by_lua_block 이후 decision_source가 "policy_engine"으로 갱신
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /check-pipeline {
        rewrite_by_lua_block {
            ngx.var.luagate_decision_source = "nginx_core"
            ngx.var.luagate_action          = "allow"
        }
        access_by_lua_block {
            -- policy stub: decision_source를 policy_engine으로 갱신
            ngx.var.luagate_decision_source = "policy_engine"
            ngx.var.luagate_action          = "allow"
        }
        content_by_lua_block {
            ngx.say(ngx.var.luagate_decision_source)
        }
    }
--- request
GET /check-pipeline
--- response_body
policy_engine
--- LAST



=== TEST 13: Nginx 변수 — luagate_active_version 기본값이 "none"
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /check-vars {
        content_by_lua_block {
            ngx.say(ngx.var.luagate_active_version)
        }
    }
--- request
GET /check-vars
--- response_body
none
--- LAST



=== TEST 14: X-Request-ID 헤더 — 클라이언트 헤더가 있으면 그대로 사용
--- http_config eval: $::http_config
--- config
    location /check-rid {
        content_by_lua_block {
            ngx.say(ngx.var.luagate_request_id)
        }
    }
--- request
GET /check-rid
--- more_headers
X-Request-ID: test-request-id-abc123
--- response_body
test-request-id-abc123
--- LAST



=== TEST 15: X-Request-ID 헤더 — 클라이언트 헤더가 없으면 $request_id fallback
--- http_config eval: $::http_config
--- config
    location /check-rid {
        content_by_lua_block {
            -- $request_id는 nginx 내부 생성값 (비어있지 않아야 함)
            local rid = ngx.var.luagate_request_id
            if rid and #rid > 0 then
                ngx.say("has_request_id")
            else
                ngx.say("no_request_id")
            end
        }
    }
--- request
GET /check-rid
--- response_body
has_request_id
--- LAST



=== TEST 16: ngx.ctx.luagate 초기화 — request_id, path_raw, action 필드 존재
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /check-ctx {
        rewrite_by_lua_block {
            ngx.var.luagate_decision_source = "nginx_core"
            ngx.var.luagate_action          = "allow"
            local request_uri = ngx.var.request_uri or ngx.var.uri
            local path_raw = request_uri:match("^([^?]*)") or ngx.var.uri
            ngx.var.luagate_path_raw = path_raw
            ngx.var.luagate_path_normalized = ngx.var.uri
            local ver = ngx.shared.luagate_policy:get("http:active_version")
            ngx.var.luagate_active_version = ver or "none"
            ngx.ctx.luagate = {
                request_id       = ngx.var.luagate_request_id,
                path_raw         = path_raw,
                path_normalized  = ngx.var.luagate_path_normalized,
                query_raw        = ngx.var.args or "",
                query_normalized = ngx.var.args or "",
                action           = "allow",
                decision_source  = "nginx_core",
                active_version   = ver or "none",
                start_time_ms    = ngx.now() * 1000,
            }
        }
        content_by_lua_block {
            local ctx = ngx.ctx.luagate
            if not ctx then
                ngx.status = 500
                ngx.say("no_ctx")
                return
            end
            -- 필수 필드 존재 확인
            local fields = {"request_id","path_raw","path_normalized",
                            "query_raw","action","decision_source",
                            "active_version","start_time_ms"}
            local missing = {}
            for _, f in ipairs(fields) do
                if ctx[f] == nil then
                    missing[#missing+1] = f
                end
            end
            if #missing > 0 then
                ngx.say("missing:" .. table.concat(missing, ","))
            else
                ngx.say("ctx_ok")
            end
        }
    }
--- request
GET /check-ctx
--- response_body
ctx_ok
--- LAST



=== TEST 17: ngx.ctx.luagate — action 초기값이 "allow"
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /check-ctx-action {
        rewrite_by_lua_block {
            ngx.ctx.luagate = {
                action          = "allow",
                decision_source = "nginx_core",
            }
        }
        content_by_lua_block {
            ngx.say(ngx.ctx.luagate.action)
        }
    }
--- request
GET /check-ctx-action
--- response_body
allow
--- LAST



=== TEST 18: 프록시 — upstream 연결 실패 시 502 반환 (no upstream)
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location / {
        rewrite_by_lua_block {
            ngx.var.luagate_decision_source = "nginx_core"
            ngx.var.luagate_action          = "allow"
            local request_uri = ngx.var.request_uri or ngx.var.uri
            local path_raw = request_uri:match("^([^?]*)") or ngx.var.uri
            ngx.var.luagate_path_raw = path_raw
            ngx.var.luagate_path_normalized = ngx.var.uri
            local ver = ngx.shared.luagate_policy:get("http:active_version")
            ngx.var.luagate_active_version = ver or "none"
            ngx.ctx.luagate = {
                request_id       = ngx.var.luagate_request_id,
                path_raw         = path_raw,
                path_normalized  = ngx.var.luagate_path_normalized,
                query_raw        = ngx.var.args or "",
                query_normalized = ngx.var.args or "",
                action           = "allow",
                decision_source  = "nginx_core",
                active_version   = ver or "none",
                start_time_ms    = ngx.now() * 1000,
            }
        }
        access_by_lua_block {
            ngx.var.luagate_decision_source = "policy_engine"
            ngx.var.luagate_action          = "allow"
            if ngx.ctx.luagate then
                ngx.ctx.luagate.decision_source = "policy_engine"
            end
        }
        # 존재하지 않는 포트로 proxy_pass — 502 유도
        proxy_pass http://127.0.0.1:19999;
        proxy_connect_timeout 1s;
        proxy_read_timeout    1s;
        proxy_send_timeout    1s;
    }
--- request
GET /
--- response_code: 502



=== TEST 19: HTTP 프록시 성공 경로 — upstream 200 응답 전달
--- http_config eval: $::http_config
--- config
    set $luagate_path_raw        $luagate_path_raw_default;
    set $luagate_path_normalized $uri;
    set $luagate_action          "allow";
    set $luagate_matched_rule    "null";
    set $luagate_decision_source "nginx_core";
    set $luagate_threat_type     "null";
    set $luagate_rule_name       "null";
    set $luagate_active_version  "none";

    location /upstream_mock {
        content_by_lua_block {
            ngx.status = 200
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"message":"from upstream"}')
        }
    }

    location / {
        rewrite_by_lua_block {
            ngx.var.luagate_decision_source = "nginx_core"
            ngx.var.luagate_action          = "allow"
            ngx.var.luagate_matched_rule    = "null"
            ngx.var.luagate_threat_type     = "null"
            ngx.var.luagate_rule_name       = "null"
            local request_uri = ngx.var.request_uri or ngx.var.uri
            local path_raw = request_uri:match("^([^?]*)") or ngx.var.uri
            ngx.var.luagate_path_raw = path_raw
            ngx.var.luagate_path_normalized = ngx.var.uri
            local ver = ngx.shared.luagate_policy:get("http:active_version")
            ngx.var.luagate_active_version  = ver or "none"
            ngx.ctx.luagate = {
                request_id      = ngx.var.luagate_request_id,
                path_raw        = path_raw,
                action          = "allow",
                decision_source = "nginx_core",
                active_version  = ver or "none",
                start_time_ms   = ngx.now() * 1000,
            }
        }
        access_by_lua_block {
            ngx.var.luagate_decision_source = "policy_engine"
            ngx.var.luagate_action          = "allow"
        }
        proxy_pass http://127.0.0.1:$TEST_NGINX_SERVER_PORT/upstream_mock;
        proxy_set_header Host $host;
    }
--- request
GET /
--- response_code: 200
--- response_body_like: "message":"from upstream"



=== TEST 20: Admin /api/ — Authorization 헤더 없음 → 401
--- http_config eval: $::http_config
--- config
    location /api/ {
        content_by_lua_block {
            local auth = ngx.req.get_headers()["Authorization"]
            if not auth or not auth:match("^Bearer .+") then
                ngx.status = 401
                ngx.header["Content-Type"] = "application/json"
                ngx.header["WWW-Authenticate"] = 'Bearer realm="luagate-admin"'
                ngx.say('{"error":"Unauthorized"}')
                return
            end
            ngx.status = 501
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Not Implemented"}')
        }
    }
--- request
GET /api/policies
--- response_code: 401
--- response_body_like: "error":"Unauthorized"



=== TEST 21: Admin /api/ — 유효한 Bearer token → 501 Not Implemented
--- http_config eval: $::http_config
--- config
    location /api/ {
        content_by_lua_block {
            local auth = ngx.req.get_headers()["Authorization"]
            if not auth or not auth:match("^Bearer .+") then
                ngx.status = 401
                ngx.header["Content-Type"] = "application/json"
                ngx.header["WWW-Authenticate"] = 'Bearer realm="luagate-admin"'
                ngx.say('{"error":"Unauthorized"}')
                return
            end
            ngx.status = 501
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Not Implemented"}')
        }
    }
--- request eval
"GET /api/policies HTTP/1.0\r\nAuthorization: Bearer test-token-12345\r\n\r\n"
--- response_code: 501
--- response_body_like: "error":"Not Implemented"



=== TEST 22: path_raw — request_uri에서 query 제거 후 원본 경로 유지
--- http_config eval: $::http_config
--- config
    location / {
        content_by_lua_block {
            local request_uri = ngx.var.request_uri or ngx.var.uri
            local path_raw  = request_uri:match("^([^?]*)") or ngx.var.uri
            local query_str = ngx.var.args or ""
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"path_raw":"' .. path_raw .. '","query_string":"' .. query_str .. '"}')
        }
    }
--- request
GET /api/test?foo=bar&baz=qux
--- response_code: 200
--- response_body_like: "path_raw":"/api/test"
--- response_body_like: "query_string":"foo=bar
--- LAST



=== TEST 23: path_raw/path_normalized — 인코딩된 우회 시도는 raw에 보존되고 normalized와 구분됨
--- http_config eval: $::http_config
--- config
    location / {
        content_by_lua_block {
            local request_uri = ngx.var.request_uri or ngx.var.uri
            local path_raw = request_uri:match("^([^?]*)") or ngx.var.uri
            local path_normalized = ngx.var.uri
            local different = tostring(path_raw ~= path_normalized)
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"path_raw":"' .. path_raw .. '","path_normalized":"' .. path_normalized .. '","different":' .. different .. '}')
        }
    }
--- request
GET /api/v1/%2e%2e/admin?foo=bar
--- response_code: 200
--- response_body_like: "path_raw":"/api/v1/%2e%2e/admin"
--- response_body_like: "different":true
--- LAST
