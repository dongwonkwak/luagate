# Test Strategy Specification

## 1. 개요

LuaGate의 테스트 전략은 세 계층으로 구성된다:

| 계층 | 프레임워크 | 범위 | 속도 |
|------|-----------|------|------|
| 단위 테스트 | busted (Lua) + cargo test (Rust) | 함수/모듈 | 빠름 |
| 통합 테스트 | Docker + pytest | HTTP/TCP 엔드투엔드 | 중간 |
| 부하 테스트 | wrk / k6 | 성능/처리량 | 느림 (선택) |

## 2. 단위 테스트 (§7.1)

### 2.1 Lua 단위 테스트 — busted

```bash
# 의존성 설치
luarocks install busted
luarocks install luassert

# 실행
busted tests/unit/
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
    │   └── ffi_test.lua           # FFI 바인딩 (실제 .so 필요)
    ├── decoder/
    │   └── ffi_test.lua           # 멀티레이어 디코딩 (§5)
    ├── log/
    │   ├── http_test.lua          # HTTP 로그 직렬화 (ADR-004)
    │   └── stream_test.lua        # TCP 세션 로그 직렬화
    └── admin/
        └── auth_test.lua          # Bearer token 인증 (ADR-004)
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

### 2.2 Rust 단위 테스트 — cargo test

```bash
cd src/scanner && cargo test
cd src/decoder && cargo test
```

**테스트 범위:**

```rust
// src/scanner/src/lib.rs
#[cfg(test)]
mod tests {
    #[test]
    fn test_sqli_detection() {
        let result = scan_path("/search", "id=1' OR '1'='1", "", "");
        assert_eq!(result.threat_type, Some("sqli".to_string()));
        assert!(result.threat_score > 0.7);
    }

    #[test]
    fn test_path_traversal() {
        let result = scan_path("/admin", "", "", "");
        // 정규화 후 경로 탐색 없음
        assert_eq!(result.threat_type, None);
    }

    #[test]
    fn test_clean_request() {
        let result = scan_path("/api/v1/users", "page=1", "", "curl/7.88");
        assert_eq!(result.threat_type, None);
        assert_eq!(result.threat_score, 0.0);
    }
}
```

## 3. 통합 테스트 (§7.2)

### 3.1 Docker 환경 구성

```yaml
# docker-compose.test.yml
services:
  luagate:
    build: .
    ports:
      - "8080:80"      # HTTP
      - "18080:8080"   # Admin API
    volumes:
      - ./tests/fixtures/policies.yaml:/app/conf/policies.yaml
    environment:
      LUAGATE_ADMIN_TOKEN: test-token-for-integration-tests

  backend:
    image: kennethreitz/httpbin
    ports:
      - "8000:80"
```

```bash
# 통합 테스트 실행
docker-compose -f docker-compose.test.yml up -d
pytest tests/integration/ -v
docker-compose -f docker-compose.test.yml down
```

### 3.2 테스트 픽스처

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

  # deny-sqli: threat_type scope는 현재 미구현 (policy-engine.md §2.1 canonical scope 외)
  # 구현 후 활성화 예정 (ADR 필요)
  # - id: deny-sqli
  #   scope:
  #     threat_type: sqli
  #   priority: 2
  #   action: deny

  - id: allow-api
    scope:
      path: /api/v1/*
    priority: 10
    action: allow
```

### 3.3 통합 테스트 케이스

```python
# tests/integration/test_http_pipeline.py
import pytest
import requests

BASE_URL = "http://localhost:8080"
ADMIN_URL = "http://localhost:18080"
ADMIN_TOKEN = "test-token-for-integration-tests"

class TestHTTPPipeline:
    def test_health_endpoint(self):
        resp = requests.get(f"{BASE_URL}/health")
        assert resp.status_code == 200
        assert resp.json()["data"]["status"] == "ok"

    def test_allowed_request(self):
        resp = requests.get(f"{BASE_URL}/api/v1/users")
        assert resp.status_code == 200

    def test_default_deny(self):
        resp = requests.get(f"{BASE_URL}/unknown-path")
        assert resp.status_code == 403

    def test_path_traversal_blocked(self):
        resp = requests.get(f"{BASE_URL}/api/v1/%2e%2e/admin")
        assert resp.status_code == 403

    def test_request_id_header(self):
        resp = requests.get(f"{BASE_URL}/api/v1/users")
        assert "X-Request-ID" in resp.headers

class TestAdminAPI:
    headers = {"Authorization": f"Bearer {ADMIN_TOKEN}"}

    def test_auth_required(self):
        resp = requests.get(f"{ADMIN_URL}/api/v1/policies")
        assert resp.status_code == 401

    def test_policy_reload(self):
        resp = requests.post(
            f"{ADMIN_URL}/api/v1/policies/reload",
            headers=self.headers
        )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

    def test_metrics_endpoint(self):
        resp = requests.get(
            f"{ADMIN_URL}/metrics",
            headers=self.headers
        )
        assert resp.status_code == 200
        assert "luagate_requests_total" in resp.text

class TestReloadFailure:
    """정책 reload 실패 시 last-known-good 유지 검증"""
    headers = {"Authorization": f"Bearer {ADMIN_TOKEN}"}

    def test_reload_failure_keeps_last_known_good(self):
        # 1. 현재 정상 정책 버전 확인
        status = requests.get(f"{ADMIN_URL}/api/v1/policies/status", headers=self.headers)
        original_version = status.json()["data"]["active_policy_version"]

        # 2. 검증은 통과하지만 apply 단계에서 실패하도록 shared dict write mock 또는 fault injection 사용
        bad_policy = """
global:
  default_action: deny
rules:
  - id: large-rule-set
    scope: { path: /api/v1/* }
    priority: 1
    action: allow
"""
        put_headers = {**self.headers, "Content-Type": "application/x-yaml"}
        requests.put(f"{ADMIN_URL}/api/v1/policies", headers=put_headers, data=bad_policy)

        # 3. fault injection 활성화 후 reload 시도 → shared dict write failure 예상
        reload_resp = requests.post(f"{ADMIN_URL}/api/v1/policies/reload", headers=self.headers)
        assert reload_resp.status_code in (500, 507)

        # 4. 기존 버전이 유지되었는지 확인
        status_after = requests.get(f"{ADMIN_URL}/api/v1/policies/status", headers=self.headers)
        assert status_after.json()["data"]["active_policy_version"] == original_version

    def test_concurrent_reload(self):
        """동시 reload 요청 시 race condition 없음 검증"""
        import threading
        results = []

        def do_reload():
            resp = requests.post(f"{ADMIN_URL}/api/v1/policies/reload", headers=self.headers)
            results.append(resp.status_code)

        threads = [threading.Thread(target=do_reload) for _ in range(5)]
        for t in threads: t.start()
        for t in threads: t.join()

        # 첫 요청만 성공, 나머지는 lock 충돌로 409
        assert 200 in results
        assert all(r in (200, 409) for r in results)

class TestSharedDictExhaustion:
    """shared dict 용량 초과 시 메트릭 손실 허용, 요청 처리 계속 검증"""
    headers = {"Authorization": f"Bearer {ADMIN_TOKEN}"}

    def test_metrics_loss_on_dict_full(self):
        # shared dict 초과는 환경 재현이 어려우므로 단위 테스트에서 mock으로 검증
        # 통합 테스트: 메트릭 엔드포인트가 항상 응답함을 확인
        resp = requests.get(f"{ADMIN_URL}/metrics", headers=self.headers)
        assert resp.status_code == 200
        # 정상 요청이 계속 처리되는지 확인
        data_resp = requests.get(f"{BASE_URL}/api/v1/users")
        assert data_resp.status_code in (200, 403)
```

## 4. 부하 테스트 (§7.3)

### 4.1 wrk 기본 벤치마크

```bash
# 기준 성능: allow 경로
wrk -t4 -c100 -d30s http://localhost:8080/api/v1/users

# 보안 스캐너 포함 경로
wrk -t4 -c100 -d30s "http://localhost:8080/api/v1/search?q=normal"
```

**목표 지표:**

| 지표 | 목표값 |
|------|--------|
| Requests/sec | > 10,000 |
| Latency p50 | < 1ms |
| Latency p99 | < 5ms |
| 에러율 | 0% |

### 4.2 k6 시나리오 테스트

```javascript
// tests/load/scenario.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    normal_traffic: {
      executor: 'constant-vus',
      vus: 50,
      duration: '60s',
    },
  },
};

export default function () {
  const res = http.get('http://localhost:8080/api/v1/users');
  check(res, { 'status is 200': (r) => r.status === 200 });
}
```

## 5. 보안 테스트

OWASP Top 10 기반 공격 벡터 테스트:

> **주의**: 현재 canonical policy scope에는 `threat_type`가 없으므로, 스캐너 탐지가 자동 차단을 의미하지 않는다.
> 통합 테스트는 "차단"과 "탐지"를 분리해 검증한다.

```python
# tests/integration/test_security.py
def test_path_traversal_blocked_by_normalization_and_default_deny():
    resp = requests.get(f"{BASE_URL}/api/v1/%2e%2e/admin")
    assert resp.status_code == 403

@pytest.mark.parametrize("path,params,expected_threat", [
    ("/api/v1/search", {"q": "1' OR '1'='1"}, "sqli"),
    ("/api/v1/search", {"q": "<script>alert(1)</script>"}, "xss"),
    ("/api/v1/cmd", {"cmd": "; ls -la"}, "cmd-injection"),
])
def test_scanner_detection_logged(path, params, expected_threat):
    requests.get(f"{BASE_URL}{path}", params=params)
    # access.log를 읽어 threat_type이 기록되었는지 검증
    # read_last_access_log_line() helper는 테스트 컨테이너/볼륨에 마운트된 access.log를 파싱한다.
    last_log = read_last_access_log_line()
    assert last_log["threat_type"] == expected_threat
```

## 6. CI 파이프라인

```yaml
# .github/workflows/test.yml (또는 GitLab CI)
stages:
  - lint
  - unit
  - build
  - integration

unit-lua:
  stage: unit
  script:
    - luarocks install busted
    - busted tests/unit/

unit-rust:
  stage: unit
  script:
    - cd src/scanner && cargo test
    - cd src/decoder && cargo test

build-so:
  stage: build
  script:
    - make build-ffi

integration:
  stage: integration
  services:
    - docker:dind
  script:
    - docker-compose -f docker-compose.test.yml up -d
    - sleep 3
    - pytest tests/integration/ -v
    - docker-compose -f docker-compose.test.yml down
```

<!-- ADR 필요 -->
> **TODO**: 카오스 엔지니어링(worker 강제 종료, shared dict 초과) 테스트 전략 수립 시 ADR 필요

## 7. 의존성

- [spec/policy-engine.md](./policy-engine.md) — 정책 평가 테스트 기준
- [spec/security-scanner.md](./security-scanner.md) — 공격 벡터 테스트 기준
- [spec/http-pipeline.md](./http-pipeline.md) — 통합 테스트 시나리오
