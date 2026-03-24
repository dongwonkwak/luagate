# vim: set ft=perl:
# tests/integration/http/pipeline_spec.t
#
# DON-140: HTTP 파이프라인 통합 테스트
# handler.lua (rewrite / access / log_phase)의 실제 동작을 Test::Nginx로 검증한다.
#
# 실행 방법:
#   prove -r tests/integration/http/
#   또는
#   make test-integration-http
#
# 참고: Test::Nginx 0.30 동작 특성 (MEMORY.md DON-134):
#   - response_code 아님 → error_code 사용
#   - LAST는 마지막 테스트에만 배치
#   - error_code + response_body 동시 사용 시 body 검증이 있는 경우 error_code 생략
#   - location / 충돌 방지: /health, /data/, /deny-test/ 등 명시적 경로 사용

BEGIN {
    # Current HTTP integration cases do not assert debug/notice log lines.
    $ENV{TEST_NGINX_LOG_LEVEL} ||= 'warn';
}

use Test::Nginx::Socket 'no_plan';

# 공통 http_config: shared dict 5개 + map 변수 + Lua 패키지 경로
our $http_config = <<'_END_HTTP_CONFIG_';
    lua_package_path '/usr/local/openresty/lualib/?.lua;/lua/?.lua;/lua/?/init.lua;;';
    lua_package_cpath '/usr/local/openresty/lualib/?.so;;';

    lua_shared_dict luagate_policy       10m;
    lua_shared_dict luagate_metrics       5m;
    lua_shared_dict luagate_connections   1m;
    lua_shared_dict luagate_state         1m;
    lua_shared_dict luagate_ratelimit     8m;

    init_by_lua_block {
        local zone_names = {
            "luagate_policy",
            "luagate_metrics",
            "luagate_connections",
            "luagate_state",
            "luagate_ratelimit",
        }

        for _, zone_name in ipairs(zone_names) do
            local dict = ngx.shared[zone_name]
            if dict then
                dict:flush_all()
                dict:flush_expired()
            end
        end

        -- Decoder stub: pass-through (no real .so needed in test env)
        -- Override _decoder_scan_mode in init_worker or content_by_lua for scanner tests.
        local _decoder_stub = {
            normalize_path = function(path_raw)
                local mode = ngx.shared.luagate_state:get("_test_decoder_mode")
                if mode == "path_exception" then
                    error("simulated decoder path exception")
                end
                return path_raw, nil, false
            end,
            normalize_query = function(query_raw)
                local mode = ngx.shared.luagate_state:get("_test_decoder_mode")
                if mode == "query_exception" then
                    error("simulated decoder query exception")
                end
                return query_raw, nil, false
            end,
        }
        package.loaded["luagate.decoder.ffi"] = _decoder_stub

        -- Scanner stub: no threat by default.
        -- Per-test override via ngx.ctx._scanner_override in access_by_lua.
        local _scanner_stub = {
            scan = function(_ctx)
                -- Check for per-request override via shared dict flag
                local mode = ngx.shared.luagate_state:get("_test_scanner_mode")
                if mode == "threat" then
                    return {
                        threat_type = ngx.shared.luagate_state:get("_test_threat_type") or "sqli",
                        rule_name = ngx.shared.luagate_state:get("_test_rule_name") or "test_rule",
                        threat_score = 0.95,
                    }, nil
                elseif mode == "budget" then
                    return nil, "scanner_fail:-3"
                elseif mode == "error" then
                    return nil, "scanner_fail:-4"
                elseif mode == "exception" then
                    error("simulated scanner exception")
                end
                return { threat_type = nil, rule_name = nil, threat_score = 0 }, nil
            end,
            init = function(_path) return true, nil end,
        }
        package.loaded["luagate.scanner.ffi"] = _scanner_stub
    }

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

=== TEST 1: GET /health → 200 OK + {"status":"ok",...} (정책 평가 없이)
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
--- error_code: 200




=== TEST 2: /health 응답 본문에 "status" 필드 포함
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
--- response_body_like
.*"status":"ok".*




=== TEST 3: /health 응답 Content-Type: application/json
--- http_config eval: $::http_config
--- config
    location /health {
        access_log off;
        default_type application/json;
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"status":"ok"}')
        }
    }
--- request
GET /health
--- response_headers
Content-Type: application/json




=== TEST 4: rewrite phase — ngx.ctx.luagate 초기화 검증
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /rewrite-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        content_by_lua_block {
            local ctx = ngx.ctx.luagate
            if not ctx then
                ngx.status = 500
                ngx.say('{"error":"ctx_not_initialized"}')
                return
            end
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"ok":true,"decision_source":"' .. (ngx.var.luagate_decision_source or "") .. '"}')
        }
    }
--- request
GET /rewrite-test/?param=value
--- response_body_like
.*"ok":true.*




=== TEST 5: rewrite phase — luagate_decision_source 기본값 = "nginx_core"
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /rewrite-vars/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            local ds = ngx.var.luagate_decision_source or ""
            ngx.say('{"decision_source":"' .. ds .. '"}')
        }
    }
--- request
GET /rewrite-vars/
--- response_body
{"decision_source":"nginx_core"}




=== TEST 6: rewrite phase — path_raw가 query string 제외
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /path-raw-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            local path_raw = ngx.var.luagate_path_raw or ""
            ngx.say('{"path_raw":"' .. path_raw .. '"}')
        }
    }
--- request
GET /path-raw-test/?foo=bar&baz=qux
--- response_body
{"path_raw":"/path-raw-test/"}




=== TEST 7: access phase — fail-closed: 정책 없으면 403 deny
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /data/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say('{"reached":"upstream"}')
        }
    }
--- request
GET /data/test
--- error_code: 403




=== TEST 8: access phase — fail-closed: 403 응답 본문에 "Forbidden" 포함
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /data-body/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say('{"reached":"upstream"}')
        }
    }
--- request
GET /data-body/test
--- error_code: 403
--- response_body_like
.*"error":"Forbidden".*




=== TEST 9: access phase — 403 응답에 X-LuaGate-Block-Reason 헤더 포함
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /deny-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say('should not reach here')
        }
    }
--- request
GET /deny-test/
--- error_code: 403
--- response_headers_like
X-LuaGate-Block-Reason: .+




=== TEST 10: access phase — allow 정책 설정 시 upstream 도달
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-policy/ {
        content_by_lua_block {
            -- allow-all 정책을 shared dict에 직접 설정
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-allow:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-allow")
            ngx.say("ok")
        }
    }

    location /allow-path/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"reached":"upstream","status":"ok"}')
        }
    }
--- request eval
["GET /setup-policy/", "GET /allow-path/"]
--- error_code eval
[200, 200]




=== TEST 11: access phase — deny 정책 설정 시 403 반환
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-deny/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"deny"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-deny:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-deny")
            ngx.say("ok")
        }
    }

    location /deny-policy/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say('should not reach here')
        }
    }
--- request eval
["GET /setup-deny/", "GET /deny-policy/"]
--- error_code eval
[200, 403]




=== TEST 12: log_phase — 에러 없이 완료
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';
    set $luagate_log_json '';

    location /log-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.ctx.luagate = ngx.ctx.luagate or {}
            ngx.ctx.luagate.request_state = "completed"
            ngx.ctx.luagate.action = "allow"
            ngx.say('{"ok":true}')
        }
        log_by_lua_block {
            require("luagate.http.handler").log_phase()
        }
    }
--- request
GET /log-test/
--- error_code: 200




=== TEST 13: log_phase — 기본 변수 구성에서도 응답을 깨지 않는다
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source 'nginx_core';
    set $luagate_action 'allow';
    set $luagate_matched_rule 'null';
    set $luagate_threat_type 'null';
    set $luagate_rule_name 'null';
    set $luagate_request_state 'short_circuited';
    set $luagate_deny_reason 'null';
    set $luagate_threat_score 'null';
    set $luagate_worker_id '0';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version 'none';
    set $luagate_log_json '';

    location /log-json-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"ok":true}')
        }
        log_by_lua_block {
            require("luagate.http.handler").log_phase()
        }
    }
--- request
GET /log-json-test/
--- error_code: 200




=== TEST 14: 전체 파이프라인 — rewrite + access(allow) + log
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';
    set $luagate_log_json '';

    location /setup-allow-full/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-full:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-full")
            ngx.say("ok")
        }
    }

    location /full-pipeline/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"pipeline":"ok"}')
        }
        log_by_lua_block {
            require("luagate.http.handler").log_phase()
        }
    }
--- request eval
["GET /setup-allow-full/", "GET /full-pipeline/"]
--- error_code eval
[200, 200]




=== TEST 15: admin plane route — 별도 location은 access 평가 없이 통과
# Admin plane guard 자체는 unit test에서 server_port=9090으로 검증한다.
# 통합 레벨에서는 별도 admin route가 data plane access 평가 없이 응답하는 구성을 검증한다.
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /admin-guard-test/ {
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"admin_guard":"passed"}')
        }
    }
--- request
GET /admin-guard-test/
--- error_code: 200
--- response_body
{"admin_guard":"passed"}




=== TEST 16: metrics 카운터 증가 — allow 요청 후 metrics:http_requests_total:allow 확인
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';
    set $luagate_log_json '';

    location /setup-metrics/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-metrics:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-metrics")
            ngx.shared.luagate_metrics:set("metrics:http_requests_total:allow", 0)
            ngx.say("ok")
        }
    }

    location /metrics-target/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say('{"ok":true}')
        }
        log_by_lua_block {
            require("luagate.http.handler").log_phase()
        }
    }

    location /check-metrics/ {
        content_by_lua_block {
            local total = ngx.shared.luagate_metrics:get("metrics:http_requests_total:allow") or 0
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"total":' .. total .. '}')
        }
    }
--- request eval
["GET /setup-metrics/", "GET /metrics-target/", "GET /check-metrics/"]
--- response_body eval
["ok\n", '{"ok":true}' . "\n", '{"total":1}' . "\n"]




=== TEST 17: 403 deny 응답 — Content-Type: application/json
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /deny-ct-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach")
        }
    }
--- request
GET /deny-ct-test/
--- error_code: 403
--- response_headers
Content-Type: application/json




=== TEST 18: 403 deny 응답 — Cache-Control: no-store
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /deny-cache-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach")
        }
    }
--- request
GET /deny-cache-test/
--- error_code: 403
--- response_headers
Cache-Control: no-store




=== TEST 19: scanner threat 탐지 → 403 deny (DON-142)
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-scanner-threat/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-scan:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-scan")
            ngx.shared.luagate_state:set("_test_scanner_mode", "threat")
            ngx.shared.luagate_state:set("_test_threat_type", "sqli")
            ngx.shared.luagate_state:set("_test_rule_name", "sqli_union_select")
            ngx.say("ok")
        }
    }

    location /scanner-threat-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach upstream")
        }
    }

    location /cleanup-scanner/ {
        content_by_lua_block {
            ngx.shared.luagate_state:delete("_test_scanner_mode")
            ngx.shared.luagate_state:delete("_test_threat_type")
            ngx.shared.luagate_state:delete("_test_rule_name")
            ngx.say("ok")
        }
    }
--- request eval
["GET /setup-scanner-threat/", "GET /scanner-threat-test/", "GET /cleanup-scanner/"]
--- error_code eval
[200, 403, 200]




=== TEST 20: scanner threat → decision_source=security_scanner + threat_type 응답 확인
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-scanner-body/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-scan2:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-scan2")
            ngx.shared.luagate_state:set("_test_scanner_mode", "threat")
            ngx.shared.luagate_state:set("_test_threat_type", "xss")
            ngx.shared.luagate_state:set("_test_rule_name", "xss_script_tag")
            ngx.say("ok")
        }
    }

    location /scanner-body-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach upstream")
        }
    }

    location /cleanup-scanner2/ {
        content_by_lua_block {
            ngx.shared.luagate_state:delete("_test_scanner_mode")
            ngx.shared.luagate_state:delete("_test_threat_type")
            ngx.shared.luagate_state:delete("_test_rule_name")
            ngx.say("ok")
        }
    }
--- request eval
["GET /setup-scanner-body/", "GET /scanner-body-test/", "GET /cleanup-scanner2/"]
--- error_code eval
[200, 403, 200]




=== TEST 21: scanner no threat → 정책 평가 진행 (allow)
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-scanner-pass/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-pass:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-pass")
            ngx.shared.luagate_state:delete("_test_scanner_mode")
            ngx.say("ok")
        }
    }

    location /scanner-pass-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"reached":"upstream","scanner":"passed"}')
        }
    }
--- request eval
["GET /setup-scanner-pass/", "GET /scanner-pass-test/"]
--- error_code eval
[200, 200]



=== TEST 22: decoder path exception → 403 fail-closed + decode_error
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-decoder-exception/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-decoder-ex:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-decoder-ex")
            ngx.shared.luagate_state:set("_test_decoder_mode", "path_exception")
            ngx.say("ok")
        }
    }

    location /decoder-exception-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach upstream")
        }
    }

    location /cleanup-decoder-exception/ {
        content_by_lua_block {
            ngx.shared.luagate_state:delete("_test_decoder_mode")
            ngx.say("ok")
        }
    }
--- request eval
["GET /setup-decoder-exception/", "GET /decoder-exception-test/", "GET /cleanup-decoder-exception/"]
--- error_code eval
[200, 403, 200]
--- response_body_like eval
["^ok\\n\$", '.*"reason":"decoder_path_exception".*', "^ok\\n\$"]
--- response_headers_like eval
["", "decoder_path_exception", ""]



=== TEST 23: scanner exception → scanner_internal_error로 403 fail-closed
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-scanner-exception/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-scan-ex:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-scan-ex")
            ngx.shared.luagate_state:set("_test_scanner_mode", "exception")
            ngx.say("ok")
        }
    }

    location /scanner-exception-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach upstream")
        }
    }

    location /cleanup-scanner-exception/ {
        content_by_lua_block {
            ngx.shared.luagate_state:delete("_test_scanner_mode")
            ngx.say("ok")
        }
    }
--- request eval
["GET /setup-scanner-exception/", "GET /scanner-exception-test/", "GET /cleanup-scanner-exception/"]
--- error_code eval
[200, 403, 200]
--- response_body_like eval
["^ok\\n\$", '.*"reason":"scanner_internal_error".*', "^ok\\n\$"]
--- response_headers_like eval
["", "scanner_internal_error", ""]



=== TEST 24: scanner budget exceeded → budget_exceeded로 403 fail-closed
--- http_config eval: $::http_config
--- config
    set $luagate_decision_source '';
    set $luagate_action '';
    set $luagate_matched_rule '';
    set $luagate_threat_type '';
    set $luagate_rule_name '';
    set $luagate_request_state '';
    set $luagate_deny_reason '';
    set $luagate_threat_score '';
    set $luagate_worker_id '';
    set $luagate_path_raw '';
    set $luagate_path_normalized '';
    set $luagate_query_string '';
    set $luagate_src_ip '';
    set $luagate_active_version '';

    location /setup-scanner-budget/ {
        content_by_lua_block {
            local policy_json = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
            ngx.shared.luagate_policy:set("policy:v-scan-budget:blob", policy_json)
            ngx.shared.luagate_policy:set("http:active_version", "v-scan-budget")
            ngx.shared.luagate_state:set("_test_scanner_mode", "budget")
            ngx.say("ok")
        }
    }

    location /scanner-budget-test/ {
        rewrite_by_lua_block {
            require("luagate.http.handler").rewrite()
        }
        access_by_lua_block {
            require("luagate.http.handler").access()
        }
        content_by_lua_block {
            ngx.say("should not reach upstream")
        }
    }

    location /cleanup-scanner-budget/ {
        content_by_lua_block {
            ngx.shared.luagate_state:delete("_test_scanner_mode")
            ngx.say("ok")
        }
    }
--- request eval
["GET /setup-scanner-budget/", "GET /scanner-budget-test/", "GET /cleanup-scanner-budget/"]
--- error_code eval
[200, 403, 200]
--- response_body_like eval
["^ok\\n\$", '.*"reason":"budget_exceeded".*', "^ok\\n\$"]
--- response_headers_like eval
["", "budget_exceeded", ""]
--- LAST
