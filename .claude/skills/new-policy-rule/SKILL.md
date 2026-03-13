---
description: "conf/policies.yaml에 새 정책 규칙 추가 절차. HTTP/Stream 규칙 모두 포함."
---

# Skill: 새 정책 규칙 추가

## 절차

1. **규칙 유형 결정**: HTTP 규칙 (`rules:`) or Stream 규칙 (`stream_rules:`)
2. **ID 결정**: kebab-case, 고유한 이름 (예: `deny-path-traversal`, `allow-internal-api`)
3. **priority 결정**: 낮은 숫자 = 높은 우선순위. 기존 규칙과 충돌/음영 없는지 확인
4. **scope 작성**: 필요한 조건만 명시 (AND 조건)
5. `conf/policies.yaml` 에 추가
6. **검증**: `POST /api/v1/policies/reload` 또는 테스트 환경에서 검증
7. **테스트 케이스 추가**: `tests/unit/policy/evaluator_test.lua`

## HTTP 규칙 scope 키

| scope 키 | 타입 | 예시 |
|----------|------|------|
| `path` | string (glob) | `/api/v1/*`, `/health` |
| `method` | string or list | `GET`, `["GET", "POST"]` |
| `src_ip` | string | `192.168.1.1` |
| `src_ip_cidr` | string | `10.0.0.0/8` |
| `query_param` | map | `{q: "admin"}` |
| `header` | map | `{X-Role: "admin"}` |

## Stream 규칙 scope 키

| scope 키 | 타입 | 예시 |
|----------|------|------|
| `src_ip_cidr` | string | `0.0.0.0/0` |
| `dst_port` | number | `443`, `22` |
| `detected_protocol` | string | `tls`, `http`, `ssh`, `unknown` |
| `sni` | string | `api.example.com` |

## 예시

```yaml
# conf/policies.yaml

rules:
  # HTTP: path traversal 차단 (최고 우선순위)
  - id: deny-path-traversal
    description: "../ 패턴 포함 요청 차단"
    scope:
      path: "*..*"
    priority: 1
    action: deny
    tags: [security, owasp]

  # HTTP: 내부망 Admin API 허용
  - id: allow-internal-admin
    scope:
      path: /api/v1/*
      src_ip_cidr: 10.0.0.0/8
    priority: 10
    action: allow

stream_rules:
  # Stream: SSH 외부 접근 차단
  - id: deny-ssh-external
    scope:
      detected_protocol: ssh
      src_ip_cidr: "0.0.0.0/0"
    priority: 1
    action: deny
```

## 체크리스트

- [ ] rule id: kebab-case, 고유, 의미 있는 이름
- [ ] priority: 기존 규칙과 충돌/음영 없음 (낮을수록 높은 우선순위)
- [ ] scope: canonical key만 사용 (policy-engine.md §2.1 참조)
- [ ] action: HTTP는 `allow`/`deny`, Stream은 `proxy`/`deny`
- [ ] Stream proxy 시 `upstream:` 필드 포함
- [ ] 충돌 감지: reload 응답의 `warnings` 확인
- [ ] 테스트 케이스 추가

## 참조

- `docs/spec/policy-engine.md` — 정책 스키마 + 평가 알고리즘
- `docs/spec/stream-pipeline.md` — Stream 정책
- `.claude/knowledge/architecture.md` — Hot Reload 7단계
