# Test Strategy Specification

## 1. 개요

LuaGate의 테스트 전략은 세 계층으로 구성된다:

| 계층 | 프레임워크 | 범위 | 속도 |
|------|-----------|------|------|
| 단위 테스트 | busted (Lua) + CMocka (C) + cargo test (Rust) | 함수/모듈 | 빠름 |
| 통합 테스트 | Test::Nginx (HTTP/Stream) | HTTP/TCP 엔드투엔드 | 중간 |
| 부하 테스트 | wrk / vegeta | 성능/처리량 | 느림 (선택) |

## 2. Makefile 명령 계약

| 명령 | 내용 | PR blocking |
|------|------|------------|
| `make test` | 전체 (unit + integration) | Yes |
| `make test-unit` | Lua + C 단위 테스트 | Yes |
| `make test-unit-lua` | busted 단위 테스트만 | Yes |
| `make test-unit-c` | CMocka 단위 테스트만 | Yes |
| `make test-integration-http` | HTTP 통합 (Test::Nginx) | Yes |
| `make test-integration-stream` | Stream 통합 (Test::Nginx::Stream) | Yes |
| `make test-reload` | Hot reload 전용 테스트 | Yes |
| `make bench` | 전체 벤치마크 (smoke) | No |
| `make bench-http` | HTTP 벤치마크 (wrk/vegeta) | No |
| `make bench-stream` | Stream 벤치마크 | No |

> **PR blocking**: `make test`는 CI에서 필수. `make bench`는 성능 비교 시에만 실행.

## 3. 단위 테스트 (§7.1)

### 3.1 Lua 단위 테스트 — busted

```bash
make test-unit-lua
# 또는: busted tests/unit/
```

**테스트 구조:**

```
tests/
└── unit/
    ├── policy/
    │   ├── evaluator_test.lua     # 정책 평가 로직 (ADR-002)
    │   ├── conflict_test.lua      # 충돌/음영 감지 (ADR-002)
    │   └── loader_test.lua        # YAML 로딩, hot reload (ADR-003)
    ├── scanner/
    │   └── ffi_test.lua           # FFI 바인딩 계약 (ABI/메모리/에러 전파)
    ├── decoder/
    │   └── ffi_test.lua           # 멀티레이어 디코딩 + FFI contract
    ├── log/
    │   ├── http_test.lua          # HTTP 로그 직렬화 + golden snapshot
    │   └── stream_test.lua        # TCP 세션 로그 직렬화
    ├── admin/
    │   └── auth_test.lua          # Bearer token 인증 (ADR-004)
    └── reload/
        ├── atomic_swap_test.lua   # atomic pointer swap 검증
        ├── rollback_test.lua      # LKG rollback 검증
        └── inflight_test.lua      # in-flight request 보존 검증
```

**테스트 예시:**

```lua
-- tests/unit/policy/evaluator_test.lua
describe("Policy Evaluator", function()
    local evaluator = require("luagate.policy.evaluator")

    describe("first-match-wins", function()
        it("returns action of highest priority matching rule", function()
            local rules = {
                { id="r1", priority=1, scope={path="/admin/*"}, action="deny" },
                { id="r2", priority=10, scope={path="/*"},      action="allow" },
            }
            local result = evaluator.evaluate(rules, {
                path_normalized = "/admin/users",
                method = "GET"
            })
            assert.equals("deny", result.action)
            assert.equals("r1", result.matched_rule_id)
        end)
    end)

    describe("default policy", function()
        it("returns default_action when no rule matches", function()
            local rules = {}
            local result = evaluator.evaluate(rules, {
                path_normalized = "/unknown",
                method = "GET"
            }, { default_action = "deny" })
            assert.equals("deny", result.action)
            assert.is_nil(result.matched_rule_id)
        end)
    end)
end)
```

### 3.2 C 단위 테스트 — CMocka

**테스트 위치**: `csrc/tests/` (단일 위치)

CMake test discovery 규칙:
- 파일명: `test_<module>.c`
- CMake: `add_executable(test_<module> tests/test_<module>.c)` + `add_test(NAME <module> COMMAND test_<module>)`

```bash
make test-unit-c
# 또는: cmake --build csrc/build --target test && ctest --test-dir csrc/build
```

### 3.3 Rust 단위 테스트 — cargo test

```bash
cd csrc && cargo test
```

### 3.4 FFI Contract 테스트

Lua↔C FFI 계약 검증 (ABI/메모리/에러 전파):

```lua
-- tests/unit/scanner/ffi_test.lua
describe("FFI contract", function()
    it("returns non-NULL result for valid input", function()
        local result = ffi_scanner.scan_http("/path", "body", "ua")
        assert.is_not_nil(result)
    end)

    it("frees result without error", function()
        local result = ffi_scanner.scan_http("/path", "", "")
        -- free 호출 후 dangling pointer 없음 검증
        ffi_scanner.free_result(result)
    end)

    it("handles NULL body gracefully (fail-closed)", function()
        local result = ffi_scanner.scan_http("/path", nil, "ua")
        -- fail-closed: NULL input은 deny 결과
        assert.equals("deny", result.action)
    end)
end)
```

### 3.5 로그 Golden/Snapshot 테스트

`log-schema.md` 필드와 동기화:

```lua
-- tests/unit/log/http_test.lua
describe("Log serialization golden test", function()
    it("HTTP access log contains required fields", function()
        local entry = log_serializer.build_http_entry(mock_ctx)
        -- log-schema.md §2 required fields
        assert.is_not_nil(entry.ts)
        assert.is_not_nil(entry.request_id)
        assert.is_not_nil(entry.method)
        assert.is_not_nil(entry.path)
        assert.is_not_nil(entry.status)
        assert.is_not_nil(entry.decision)
        assert.is_not_nil(entry.decision_source)
    end)
end)
```

## 4. 통합 테스트 (§7.2)

### 4.1 HTTP 통합 — Test::Nginx

```bash
make test-integration-http
```

**harness**: Test::Nginx (Perl) — `tests/integration/http/`

### 4.2 Stream 통합 — Test::Nginx::Stream

```bash
make test-integration-stream
```

**harness**: Test::Nginx::Stream — `tests/integration/stream/`

TLS 검증: `openssl s_client` 또는 별도 TCP harness.

```perl
# tests/integration/stream/basic.t
use Test::Nginx::Socket::Lua::Stream;
plan tests => 2;

run_tests();

__DATA__
=== TEST 1: TCP connection is proxied
--- stream_server_config
    content_by_lua_block { ... }
--- stream_request: HELLO
--- stream_response: OK
```

### 4.3 Hot Reload 통합 — test-reload

```bash
make test-reload
```

검증 항목:
- atomic pointer swap (새 버전이 원자적으로 활성화)
- rollback (검증 실패 시 LKG 유지)
- in-flight request 보존 (reload 중 처리 중인 요청이 완료됨)

### 4.4 테스트 픽스처

```yaml
# tests/fixtures/policies.yaml
global:
  default_action: deny

rules:
  - id: allow-health
    scope:
      path: /health
      method: GET
    priority: 1
    action: allow

  - id: allow-api
    scope:
      path: /api/v1/*
    priority: 10
    action: allow
```

## 5. 커버리지 목표

| 모듈 | 목표 | 측정 방법 |
|------|------|----------|
| `lua/luagate/policy/` | 90%+ | luacov |
| `lua/luagate/log/` | 80%+ | luacov |
| `lua/luagate/admin/` | 80%+ | luacov |
| `csrc/` (C) | 80%+ | gcov/lcov |
| `csrc/` (Rust) | 80%+ | cargo-llvm-cov |
| FFI contract paths | 100% | 수동 확인 |

> 커버리지는 CI에서 측정하고 PR에 리포트. 핵심 경로(policy evaluation, scanner) 아래로 내려가면 PR 블록.

## 6. 변경 유형별 필수 테스트 매트릭스

| 변경 유형 | 필수 테스트 |
|----------|-----------|
| 정책 평가 로직 | `test-unit-lua` (evaluator_test, conflict_test) |
| Hot Reload 경로 | `test-reload` + `test-unit-lua` (reload/) |
| FFI 모듈 변경 | `test-unit-c` + `test-unit-lua` (ffi_test) |
| 로그 스키마 변경 | `test-unit-lua` (log/ golden test) |
| Admin API 변경 | `test-unit-lua` (auth_test) + `test-integration-http` |
| Stream 파이프라인 | `test-integration-stream` |
| 보안 스캐너 | `test-unit-lua` (ffi_test) + OWASP 페이로드 테스트 |
| 전체 | `make test` |

## 7. 부하 테스트 (§7.3)

### SLO 재현 조건

| 항목 | 값 |
|------|-----|
| worker 수 | `nginx worker_processes auto` (코어 수) |
| 정책 corpus 크기 | 100 rules (표준), 1000 rules (stress) |
| warm-up 기간 | 30초 |
| 동시 연결 수 | 100 (표준), 500 (stress) |
| 하드웨어 baseline | 4 vCPU / 8GB RAM |

### HTTP 벤치마크 (PR smoke)

```bash
make bench-http
# wrk -t4 -c100 -d30s http://localhost:8080/api/v1/users
```

**목표 지표:**

| 지표 | SLO |
|------|-----|
| Requests/sec | > 10,000 |
| Latency p50 | < 1ms |
| Latency p99 | < 5ms |
| 에러율 | 0% |

### Full 벤치마크 (릴리스 전)

```bash
make bench
# HTTP + Stream 전체 시나리오, vegeta rate test 포함
```

## 8. Fuzz / Property 테스트

대상 모듈:
- TLS parser (stream preread)
- decoder (멀티레이어 인코딩)
- radix tree (경로 매칭)

도구: Rust `cargo fuzz` (libFuzzer), Lua `busted` property-based (추후 도입).

## 9. 보안 테스트

OWASP Top 10 기반 공격 벡터 테스트 (`tests/fixtures/` 픽스처):

> **주의**: canonical policy scope에 `threat_type`가 없으므로 스캐너 탐지가 자동 차단을 의미하지 않는다.
> 통합 테스트는 "차단"과 "탐지"를 분리해 검증한다.

## 10. CI 파이프라인

```yaml
# .github/workflows/test.yml
stages:
  - lint        # stylua, luacheck, clang-format
  - unit        # test-unit-lua, test-unit-c, cargo test
  - build       # make build-ffi
  - integration # test-integration-http, test-integration-stream, test-reload
```

- `lint` + `unit` + `build` + `integration` 모두 PR blocking
- `bench` 는 PR blocking 아님 (릴리스 태그 트리거)

<!-- ADR 필요 -->
> **TODO**: 카오스 엔지니어링(worker 강제 종료, shared dict 초과) 테스트 전략 수립 시 ADR 필요

## 11. 의존성

- [spec/policy-engine.md](./policy-engine.md) — 정책 평가 테스트 기준
- [spec/security-scanner.md](./security-scanner.md) — 공격 벡터 테스트 기준
- [spec/http-pipeline.md](./http-pipeline.md) — 통합 테스트 시나리오
- [spec/log-schema.md](./log-schema.md) — 로그 golden test 기준
