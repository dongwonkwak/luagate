# Test Strategy Specification

## 1. 개요

LuaGate의 테스트 전략은 세 계층으로 구성된다:

| 계층 | 프레임워크 | 범위 | 속도 |
|------|-----------|------|------|
| 단위 테스트 | busted (Lua) + cargo test (Rust) + Vitest (React) | 함수/모듈/컴포넌트 | 빠름 |
| 통합 테스트 | Test::Nginx (HTTP/Stream) | HTTP/TCP 엔드투엔드 | 중간 |
| E2E 테스트 | Playwright (TypeScript) | 대시보드 UI 유저 플로우 | 중간 |
| 부하 테스트 | wrk / vegeta | 성능/처리량 | 느림 (선택) |

## 2. Makefile 명령 계약

| 명령 | 내용 | PR blocking |
|------|------|------------|
| `make test` | 전체 (unit + integration) | Yes |
| `make test-unit` | Lua + Rust 단위 테스트 | Yes |
| `make test-unit-lua` | busted 단위 테스트만 | Yes |
| `make test-unit-rust` | Rust cargo test 단위 테스트만 | Yes |
| `make ui-test` | Vitest 프론트엔드 단위 테스트 | Yes |
| `make test-integration-http` | HTTP 통합 (로컬 Test::Nginx 또는 Docker Compose fallback) | Yes |
| `make test-integration-stream` | Stream 통합 (Test::Nginx::Stream) | Yes |
| `make test-reload` | Hot reload 전용 테스트 | Yes |
| `make test-docker` | Docker Compose 기반 HTTP 통합 테스트 (shard env override 지원) | No |
| `make e2e` | Playwright E2E 테스트 (대시보드 UI) | No |
| `make e2e-ui` | Playwright E2E 테스트 (UI 모드) | No |
| `make bench` | 전체 벤치마크 (smoke) | No |
| `make bench-http` | HTTP 벤치마크 (wrk/vegeta) | No |
| `make bench-stream` | Stream 벤치마크 | No |

> **PR blocking**: `make test`는 CI에서 필수. `make bench`는 성능 비교 시에만 실행.

### 2.1 실행 환경 가이드

### 권장 순서

1. Nix dev shell에서 `make test-unit`
2. `make test` 또는 `make test-integration-http`
3. 필요 시 `make test-docker`로 HTTP 통합 테스트만 단독 실행

### 환경별 동작

- `nix develop` 환경은 `busted`, `prove`, `ctest`를 제공한다.
- `make test-integration-http`는 로컬 Perl에 `Test::Nginx::Socket`이 있으면 직접 `prove`를 실행한다.
- 로컬 `Test::Nginx::Socket`이 없고 Docker가 있으면 `make test-integration-http`는 자동으로 `make test-docker`로 fallback 한다.
- CI의 HTTP 통합 테스트 source of truth는 `make test-docker`이며, GitHub Actions에서는 `tests/integration/http/*.t`를 파일 단위 matrix shard로 병렬 실행한다.
- shard 실행 시 `make test-docker`는 `TEST_HTTP_PROVE_ARGS`, `TEST_NGINX_PORT`, `TEST_NGINX_SERVROOT`, `COMPOSE_PROJECT_NAME` override를 지원한다.
- `make test-unit-rust`는 각 Rust crate 디렉토리에 `Cargo.toml`이 없으면 skip 한다.
- `make test-integration-stream`, `make test-reload`는 해당 테스트 디렉터리가 없으면 skip 한다.

### 예시

```bash
# Nix dev shell에서 전체 테스트
nix --extra-experimental-features 'nix-command flakes' develop --command make test

# HTTP 통합 테스트만 Docker Compose로 실행
make test-docker

# 특정 HTTP integration 파일만 shard처럼 실행
make test-docker \
  TEST_HTTP_PROVE_ARGS='-v tests/integration/http/pipeline_spec.t' \
  TEST_NGINX_PORT=1984 \
  TEST_NGINX_SERVROOT=/tmp/nginx-test-servroot-pipeline \
  COMPOSE_PROJECT_NAME=luagate-pipeline
```

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

### 3.2 Rust 단위 테스트 — cargo test

```bash
make test-unit-rust
# 또는: cd src/scanner && cargo test && cd ../decoder && cargo test && cd ../stream && cargo test
```

### 3.3 FFI Contract 테스트

Lua↔Rust FFI 계약 검증 (ABI/메모리/에러 전파):

```lua
-- tests/unit/scanner/ffi_spec.lua
describe("FFI contract", function()
    it("maps caller-allocated scanner output into Lua values", function()
        local scanner = load_module_with({
            threat_type = "sqli",
            rule_name = "sqli_union_select",
        })
        local result, err = scanner.scan({
            path_raw = "/search",
            path_normalized = "/search",
            query_raw = "id=1 UNION SELECT",
            query_normalized = "id=1 UNION SELECT",
        })

        assert.is_nil(err)
        assert.equals("sqli", result.threat_type)
        assert.equals("sqli_union_select", result.rule_name)
    end)

    it("defaults optional fields and NULL body safely", function()
        local scanner = load_module_with()
        local result, err = scanner.scan({
            path_raw = "/health",
            path_normalized = "/health",
        })

        assert.is_nil(err)
        assert.is_nil(result.threat_type)
        assert.is_nil(result.rule_name)
    end)

    it("propagates hard FFI errors as fail-closed tokens", function()
        local scanner = load_module_with({ scan_rc = -3 })
        local result, err = scanner.scan({
            path_raw = "/search",
            path_normalized = "/search",
        })

        assert.is_nil(result)
        assert.truthy(err and err:find("scanner_fail"))
    end)
end)
```

### 3.4 로그 Golden/Snapshot 테스트

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

실행 규칙:

- 로컬에 `Test::Nginx::Socket`이 있으면 `LUAGATE_ADMIN_TOKEN=<token> prove -r tests/integration/http/`
- 로컬 모듈이 없으면 Docker Compose fallback: `make test-docker`
- 기본 admin 토큰 값은 `TEST_ADMIN_TOKEN` / `LUAGATE_ADMIN_TOKEN`의 기본값 `test-secret-token-for-integration`
- CI는 현재 `pipeline_spec.t`, `test_nginx_basic.t`를 파일 단위 shard로 나눠 병렬 실행한다.
- shard 간 간섭 방지를 위해 각 실행은 고유한 `TEST_NGINX_PORT`, `TEST_NGINX_SERVROOT`, `COMPOSE_PROJECT_NAME`을 사용한다.

```bash
make test-integration-http
# 또는 명시적으로 Docker Compose 경로:
make test-docker
# 또는:
LUAGATE_ADMIN_TOKEN=test-secret-token-for-integration \
docker compose -f docker-compose.test.yml up --build --exit-code-from test

# 또는 특정 shard만 Docker Compose로 실행:
LUAGATE_ADMIN_TOKEN=test-secret-token-for-integration \
TEST_HTTP_PROVE_ARGS='-v tests/integration/http/test_nginx_basic.t' \
TEST_NGINX_PORT=1985 \
TEST_NGINX_SERVROOT=/tmp/nginx-test-servroot-basic \
COMPOSE_PROJECT_NAME=luagate-basic \
docker compose -f docker-compose.test.yml up --build --exit-code-from test
```

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
| `src/` (Rust) | 80%+ | cargo-llvm-cov |
| FFI contract paths | 100% | 수동 확인 |

> 커버리지는 CI에서 측정하고 PR에 리포트. 핵심 경로(policy evaluation, scanner) 아래로 내려가면 PR 블록.

## 6. 변경 유형별 필수 테스트 매트릭스

| 변경 유형 | 필수 테스트 |
|----------|-----------|
| 정책 평가 로직 | `test-unit-lua` (evaluator_test, conflict_test) |
| Hot Reload 경로 | `test-reload` + `test-unit-lua` (reload/) |
| FFI 모듈 변경 | `test-unit-rust` + `test-unit-lua` (ffi_test) |
| 로그 스키마 변경 | `test-unit-lua` (log/ golden test) |
| Admin API 변경 | `test-unit-lua` (auth_test) + `test-integration-http` |
| Stream 파이프라인 | `test-integration-stream` |
| 대시보드 UI 변경 | `e2e` (Playwright) |
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

## 9. E2E 테스트 — Playwright

### 개요

React 대시보드(Admin plane)의 핵심 유저 플로우를 Playwright로 검증한다.
컴포넌트 단위 테스트(Vitest)로 커버 불가한 실제 API 연동 흐름을 대상으로 한다.

### 디렉토리 구조

```
e2e/                          # 프로젝트 루트 (ui/ 외부)
├── package.json              # npm 사용
├── playwright.config.ts
├── fixtures/
│   └── admin-server.ts       # Admin API mock server (추후)
└── tests/
    ├── auth.spec.ts
    ├── policy-editor.spec.ts
    ├── metrics.spec.ts
    └── error-handling.spec.ts
```

> **위치 결정**: `ui/e2e/`가 아닌 프로젝트 루트 `e2e/`에 배치한다.
> 대시보드는 Admin API(:9090)와 밀접하므로 UI 패키지 외부에서 통합 검증한다.

### Base URL

- nginx.conf의 Admin server block(:9090)이 `/dashboard`로 UI를 서빙
- `PLAYWRIGHT_BASE_URL` 기본값: `http://localhost:9090/dashboard`

### Makefile 명령

```bash
make e2e       # cd e2e && npm run test
make e2e-ui    # cd e2e && npm run test:ui
```

### 패키지 매니저

npm을 사용한다 (`ui/`, 루트 `package.json`과 동일).

### 참조

- DON-166: Playwright E2E 테스트 — 핵심 유저 플로우 5개
- DON-169: CI codex-review.yml — e2e/** 파일 패턴 추가

## 10. 보안 테스트

OWASP Top 10 기반 공격 벡터 테스트 (`tests/fixtures/` 픽스처):

> **주의**: canonical policy scope에 `threat_type`가 없으므로 스캐너 탐지가 자동 차단을 의미하지 않는다.
> 통합 테스트는 "차단"과 "탐지"를 분리해 검증한다.

## 11. CI 파이프라인

```yaml
# .github/workflows/test.yml
stages:
  - lint        # stylua, luacheck, clang-format, cargo clippy
  - unit        # test-unit-lua, cargo test
  - build       # make build-ffi
  - integration # test-integration-http, test-integration-stream, test-reload
```

- `lint` + `unit` + `build` + `integration` 모두 PR blocking
- `bench` 는 PR blocking 아님 (릴리스 태그 트리거)

### 10.1 프론트엔드 CI 파이프라인

| 워크플로우 | Status Check 이름 | 내용 | PR blocking |
|-----------|-------------------|------|------------|
| `frontend-quality.yml` | `frontend-quality-status` | ESLint + Prettier + tsc + Vite build | Yes |
| `frontend-unit.yml` | `frontend-unit-status` | Vitest 단위 테스트 + Codecov | Yes |
| `frontend-e2e.yml` | `frontend-e2e-status` | Playwright E2E 테스트 (Docker) | Yes |

- Path filter: `ui/**` 또는 `.github/workflows/frontend-*.yml` 변경 시에만 실행
- E2E는 추가로 `e2e/**`, `conf/**`, `lua/luagate/**`, `src/**` 등 백엔드 변경도 감지
- 각 워크플로우의 final status job (`*-status`)은 `if: always()`로 항상 실행되어 PR blocking 가능
- Path filter로 skip된 경우에도 status job은 success로 완료됨

### 10.2 GitHub Branch Protection — Required Status Checks

main 브랜치 보호 규칙에 다음 status check를 required로 설정한다:

**프론트엔드:**

- `frontend-quality-status`
- `frontend-unit-status`
- `frontend-e2e-status`

**백엔드:**

- `Test::Nginx (Docker)` (integration-test.yml — `test-docker-compat` aggregation job, `if: always()`)

> **참고**: 개별 shard (`Test::Nginx (pipeline_spec)` 등)는 matrix 확장 시 이름이 변경되므로
> required check에는 항상 실행되는 aggregation job `Test::Nginx (Docker)`만 등록한다.
>
> **설정 경로**: Repository Settings → Branches → Branch protection rules → main
> → Require status checks to pass before merging → 위 check 이름 추가

### 10.3 변경 유형별 CI 실행 매트릭스

`integration-test.yml`은 path filter 없이 모든 PR에서 실행된다.
프론트엔드 워크플로우만 path filter로 조건부 실행한다.

| 변경 파일 | frontend-quality | frontend-unit | frontend-e2e | integration-test |
|----------|-----------------|--------------|-------------|-----------------|
| `ui/src/**` 만 | 실행 | 실행 | 실행 | 실행 (항상) |
| `lua/**` 만 | skip (success) | skip (success) | 실행 | 실행 (항상) |
| `ui/**` + `lua/**` | 실행 | 실행 | 실행 | 실행 (항상) |
| `docs/**` 만 | skip (success) | skip (success) | skip (success) | 실행 (항상) |

<!-- ADR 필요 -->
> **TODO**: 카오스 엔지니어링(worker 강제 종료, shared dict 초과) 테스트 전략 수립 시 ADR 필요

## 12. 의존성

- [spec/policy-engine.md](./policy-engine.md) — 정책 평가 테스트 기준
- [spec/security-scanner.md](./security-scanner.md) — 공격 벡터 테스트 기준
- [spec/http-pipeline.md](./http-pipeline.md) — 통합 테스트 시나리오
- [spec/log-schema.md](./log-schema.md) — 로그 golden test 기준
