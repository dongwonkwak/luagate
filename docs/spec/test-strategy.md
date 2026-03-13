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

  - id: deny-sqli
    scope:
      threat_type: sqli     # 확장 scope (구현 후 활성화)
    priority: 2
    action: deny

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

```python
# tests/integration/test_security.py
ATTACK_VECTORS = [
    ("/api/v1/search", {"q": "1' OR '1'='1"}, "sqli"),
    ("/api/v1/search", {"q": "<script>alert(1)</script>"}, "xss"),
    ("/api/v1/%2e%2e/admin", {}, "path-traversal"),
    ("/api/v1/cmd", {"cmd": "; ls -la"}, "cmd-injection"),
]

@pytest.mark.parametrize("path,params,threat_type", ATTACK_VECTORS)
def test_attack_blocked(path, params, threat_type):
    resp = requests.get(f"{BASE_URL}{path}", params=params)
    assert resp.status_code == 403
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
