# ADR-004: 로그/메트릭 데이터 모델 + 관리면 보안

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-13 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-88](https://linear.app/dongwon/issue/DON-88) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md) |

---

## Status

**Accepted** — Phase 0-A에서 고정.

---

## Context

LuaGate는 API 게이트웨이이자 보안 게이트웨이로서 두 가지 관찰 가능성 요구가 있다:

1. **로그/메트릭**: 요청별 상세 로그와 집계 메트릭을 어떤 스키마로 기록하는가?
   - 보안 분석을 위해 원본(raw)과 정규화(normalized) 경로 모두 보존해야 한다.
2. **관리면 보안**: Admin API 엔드포인트를 어떻게 보호하는가?
   - 관리 인터페이스 노출은 공격 표면이 되므로 최소 권한 원칙을 적용해야 한다.

---

## Decision

### §4 로그/메트릭 데이터 모델

#### 4.1 HTTP 요청 로그 스키마 (22개 필드)

각 HTTP 요청 처리 완료 시 아래 JSON 레코드를 `access.log`에 기록한다.

| # | 필드명 | 타입 | 설명 |
|---|--------|------|------|
| 1 | `timestamp` | ISO-8601 string | 요청 수신 시각 (UTC) |
| 2 | `request_id` | UUID string | 요청별 고유 식별자 |
| 3 | `src_ip` | string | 클라이언트 원본 IP (X-Forwarded-For 처리 후) |
| 4 | `src_port` | number | 클라이언트 원본 포트 |
| 5 | `dst_port` | number | 서버 리슨 포트 |
| 6 | `method` | string | HTTP 메서드 (GET, POST 등) |
| 7 | `path_raw` | string | 원본 요청 경로 (디코딩 전, 그대로) |
| 8 | `path_normalized` | string | 정규화된 경로 (URL 디코딩, 경로 정규화 후) |
| 9 | `query_string` | string | 원본 쿼리 스트링 |
| 10 | `http_version` | string | HTTP 버전 (1.0/1.1/2.0) |
| 11 | `user_agent` | string | User-Agent 헤더값 |
| 12 | `content_length` | number \| null | 요청 본문 크기 (바이트) |
| 13 | `action` | enum | `allow` \| `deny` |
| 14 | `matched_rule_id` | string \| null | 매칭된 규칙 ID (기본 정책 적용 시 null) |
| 15 | `deny_reason` | string \| null | 차단 이유 (action=deny일 때만) |
| 16 | `threat_type` | string \| null | 탐지된 위협 유형 (sqli/xss/path-traversal 등) |
| 17 | `threat_score` | number \| null | 위협 점수 (0.0 ~ 1.0) |
| 18 | `latency_ms` | number | 총 처리 시간 (밀리초) |
| 19 | `upstream_latency_ms` | number \| null | 업스트림 응답 시간 |
| 20 | `response_status` | number | HTTP 응답 상태 코드 |
| 21 | `policy_version` | string | 요청 처리 시 활성 정책의 SHA256 해시 |
| 22 | `worker_pid` | number | 처리한 Nginx worker PID |

**로그 예시:**

```json
{
  "timestamp": "2026-03-13T12:34:56.789Z",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "src_ip": "203.0.113.42",
  "src_port": 54321,
  "dst_port": 80,
  "method": "GET",
  "path_raw": "/api/v1/%2e%2e/admin",
  "path_normalized": "/admin",
  "query_string": "id=1%27OR%271%27%3D%271",
  "http_version": "1.1",
  "user_agent": "Mozilla/5.0 ...",
  "content_length": null,
  "action": "deny",
  "matched_rule_id": "deny-path-traversal",
  "deny_reason": "path traversal detected",
  "threat_type": "path-traversal",
  "threat_score": 0.95,
  "latency_ms": 0.8,
  "upstream_latency_ms": null,
  "response_status": 403,
  "policy_version": "a3f2c1d4e5b6789012345678901234567890abcd",
  "worker_pid": 12345
}
```

#### 4.2 TCP 세션 로그 스키마 (12개 필드)

TCP 스트림 프록시 세션 종료 시 아래 레코드를 `stream.log`에 기록한다.

| # | 필드명 | 타입 | 설명 |
|---|--------|------|------|
| 1 | `timestamp` | ISO-8601 string | 세션 시작 시각 (UTC) |
| 2 | `connection_id` | UUID string | 세션별 고유 식별자 |
| 3 | `src_ip` | string | 클라이언트 IP |
| 4 | `src_port` | number | 클라이언트 포트 |
| 5 | `dst_port` | number | 서버 리슨 포트 |
| 6 | `detected_protocol` | string | 탐지된 애플리케이션 프로토콜 (http/tls/ssh/unknown 등) |
| 7 | `sni` | string \| null | TLS SNI 값 (TLS 세션인 경우) |
| 8 | `action` | enum | `proxy` \| `deny` |
| 9 | `deny_reason` | string \| null | 차단 이유 |
| 10 | `duration_ms` | number | 세션 지속 시간 (밀리초) |
| 11 | `bytes_tx` | number | 클라이언트→서버 전송 바이트 |
| 12 | `bytes_rx` | number | 서버→클라이언트 수신 바이트 |

#### 4.2b 로그 Redaction 정책

보안/개인정보 보호를 위해 다음 헤더/필드의 값을 로그에 기록하기 전에 마스킹한다.

**마스킹 대상 (우선순위 순):**

| 우선순위 | 대상 | 마스킹 방법 | 예시 |
|----------|------|-------------|------|
| P1 (필수) | `Authorization` 헤더 | 전체 마스킹 `"***"` | `Bearer abc123` → `"***"` |
| P1 (필수) | `Cookie` 헤더 | 전체 마스킹 `"***"` | `session=xyz` → `"***"` |
| P1 (필수) | `token`, `api_key`, `apikey` 쿼리 파라미터 | 값만 마스킹 `"***"` | `?token=secret` → `?token=***` |
| P1 (필수) | `password`, `passwd`, `secret` 쿼리 파라미터 | 값만 마스킹 `"***"` | `?password=abc` → `?password=***` |
| P2 (권장) | `X-API-Key`, `X-Auth-Token` 헤더 | 전체 마스킹 `"***"` | — |
| P2 (권장) | JWT payload (Authorization: Bearer) | 전체 마스킹, 타입만 보존 | `Bearer <jwt>` → `"***"` |

**Redaction 적용 시점:**
- `log_by_lua` 단계에서 JSON 레코드 생성 시 적용
- 원본 데이터는 Lua 메모리에서만 처리하며 파일에 기록하지 않음
- `query_string` 필드: 민감 파라미터 값만 마스킹, 파라미터 키는 유지

**Redaction 미적용 필드:**
- `path_raw`, `path_normalized`: 경로 자체는 보안 분석 필수 → 마스킹 없음
- `user_agent`: 스캐너 탐지용 → 마스킹 없음

#### 4.3 메트릭 스키마

Prometheus 형식으로 `/metrics` 엔드포인트(관리면)에서 노출.
집계 기준: **path_normalized** (path_raw가 아님).

**Cardinality 원칙**: 메트릭 레이블은 cardinality 폭발을 방지하기 위해 **low-cardinality** 값만 허용한다.
- `path_normalized`: 허용. 그러나 UUID/세션ID 등 고유값이 포함된 경로는 정규화 단계에서 제거되어야 함 (예: `/api/v1/users/12345` → `/api/v1/users/:id`)
- `policy_version`: cardinality 위험 있음. **메트릭 레이블에서 제거**, 대신 게이지 `luagate_policy_info`로 별도 노출
- `deny_reason`: low-cardinality enum으로 제한 (최대 20개 고정값). 임의 문자열 허용 금지

| 메트릭 이름 | 타입 | 레이블 | 설명 |
|------------|------|--------|------|
| `luagate_requests_total` | Counter | `action`, `method`, `route` | 총 HTTP 요청 수. `route`는 정규화된 경로 패턴 (`/api/v1/users/:id` 등) |
| `luagate_blocked_total` | Counter | `threat_type`, `rule_id` | 차단된 요청 수. `rule_id`는 정책 규칙 ID (고정 enum) |
| `luagate_latency_seconds` | Histogram | `method`, `route` | 요청 처리 latency. 버킷: 0.0001/0.0005/0.001/0.005/0.01/0.05/0.1/0.5/1.0s |
| `luagate_active_connections` | Gauge | `type` (`http`/`stream`) | 현재 활성 연결 수 |
| `luagate_policy_reload_total` | Counter | `status` (`success`/`failure`) | 정책 리로드 횟수 |
| `luagate_policy_conflicts_gauge` | Gauge | — | 현재 정책의 충돌 규칙 수 |
| `luagate_policy_info` | Gauge | `version`, `rules_count` | 현재 활성 정책 메타데이터 (값 항상 1) |

> **주의**: `luagate_requests_total`에서 `policy_version` 레이블 제거. 정책 버전 추적은 `luagate_policy_info` 게이지로 대체.

**저장 방식:**
- 카운터는 `luagate_metrics` shared dict에 원자적으로 증가
- Histogram 버킷은 `latency:bucket:<ms>` 키로 shared dict에 저장 (ADR-001 §1.1 참조)
- 메트릭 읽기는 `/metrics` 요청 시 shared dict에서 직접 집계

### §6 관리면 보안

#### 6.1 네트워크 바인딩

- Admin API 서버: `127.0.0.1:8080` (localhost만 바인딩)
- 외부 네트워크 노출 금지 (방화벽/Nginx listen 설정으로 강제)
- 외부 대시보드 접근: 역방향 프록시 또는 SSH 터널링을 통해야 함

#### 6.2 인증

- **Static Bearer Token** 방식:
  - 환경 변수 `LUAGATE_ADMIN_TOKEN`으로 설정
  - 모든 Admin API 요청에 `Authorization: Bearer <token>` 헤더 필수
  - 토큰 불일치 또는 누락: `401 Unauthorized`
- 토큰 최소 길이: 32자 (서버 시작 시 검증)
- HTTPS는 역방향 프록시가 처리하며 Admin API 자체는 HTTP (localhost 한정)

#### 6.3 감사 로그

아래 이벤트 발생 시 `audit.log`에 별도 기록:

| 이벤트 | 기록 필드 |
|--------|----------|
| 정책 변경 (`PUT /api/v1/policies`) | timestamp, event=policy_update, src_ip, policy_version_before, policy_version_after |
| 정책 리로드 (`POST /api/v1/policies/reload`) | timestamp, event=policy_reload, src_ip, trigger=api\|hup, status, policy_version |
| 인증 실패 | timestamp, event=auth_failure, src_ip, path, reason |
| 서버 기동/종료 | timestamp, event=startup\|shutdown, policy_version |

#### 6.3b 위협 모델

Admin API에 대한 주요 위협과 완화 방안:

| 위협 | 공격 시나리오 | 완화 방안 |
|------|-------------|-----------|
| **SSRF-to-loopback** | 외부 서비스를 경유하여 `127.0.0.1:8080`에 요청 전달 | localhost 바인딩 + 방화벽으로 외부 직접 접근 차단. 역방향 프록시에서 Admin 포트 노출 금지 |
| **Container breakout** | 컨테이너 탈출 후 호스트 네트워크에서 Admin API 접근 | UDS(Unix Domain Socket) 바인딩 또는 mTLS를 통한 mutual authentication 검토 (별도 ADR) |
| **Token 탈취** | 로그/환경변수에서 `LUAGATE_ADMIN_TOKEN` 노출 | 토큰을 로그에 기록하지 않음. 최소 32자 엔트로피 요구. 시크릿 관리 시스템(Vault 등) 연동 권장 |
| **Brute force** | Bearer token 추측 시도 | 연속 인증 실패 시 IP 기반 일시 차단 (임계값: 10회/분) 구현 권장 |
| **IP allowlist 우회** | X-Forwarded-For 헤더 조작 | Admin API 요청에서 XFF 헤더 무시. `$remote_addr`만 신뢰 |

**강화 옵션 (우선순위):**
1. **UDS 바인딩**: `unix:/var/run/luagate/admin.sock` — 파일시스템 권한으로 접근 제어. 컨테이너 환경에서 소켓 파일을 명시적으로 마운트해야 접근 가능
2. **IP Allowlist**: `allow 127.0.0.1; deny all;` — Nginx 레벨에서 적용. 컨테이너 오케스트레이터 IP 범위 추가 가능
3. **mTLS**: 클라이언트 인증서 검증 — 엔터프라이즈 환경에서 토큰 방식 대체 (별도 ADR 필요)

#### 6.4 CORS

- `Access-Control-Allow-Origin`: 환경 변수 `LUAGATE_DASHBOARD_ORIGIN`에 설정된 단일 origin만 허용
- Preflight(`OPTIONS`) 요청에 올바른 CORS 헤더 응답
- `Access-Control-Allow-Methods`: GET, POST, PUT, DELETE, OPTIONS
- `Access-Control-Allow-Headers`: Authorization, Content-Type

---

## Consequences

### 긍정적 결과

- **보안 분석**: raw + normalized 경로 모두 저장으로 우회 시도 탐지 가능
- **관찰 가능성**: 22개 HTTP 로그 필드 + 메트릭으로 풍부한 분석 환경
- **관리면 보호**: localhost 바인딩 + Bearer token으로 최소 공격 표면
- **감사 추적**: 정책 변경 이력이 audit.log에 기록됨

### 부정적 결과

- **로그 볼륨**: 요청마다 22개 필드 → 고트래픽 환경에서 디스크 I/O 주의 필요.
  로그 로테이션 정책과 외부 로그 집계(ELK 등) 설정 권장
- **Static Token 한계**: 토큰 교체 시 재시작 필요.
  토큰 교체 무중단화는 별도 ADR에서 결정
- **메트릭 경계**: 인스턴스별 메트릭이므로 전체 집계는 Prometheus 등 외부 도구 필요

### 향후 고려

- 로그 샘플링(고트래픽 시 비율 조절) 기능 추가 검토
- Admin API mTLS 지원 검토 (엔터프라이즈 요구 시)

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) — shared dict 기반 메트릭 저장
- [spec/log-schema.md](../../spec/log-schema.md) — 로그 스키마 상세 스펙
- [spec/admin-api.md](../../spec/admin-api.md) — Admin API 전체 엔드포인트 스펙
