# HTTP Pipeline Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-002 정책 평가 규칙](../design/adr/ADR-002-policy-evaluation-conflict-detection.md)
> - [ADR-004 로그/메트릭](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

LuaGate HTTP 파이프라인은 클라이언트 HTTP 요청을 수신하여 정책 평가, 위협 탐지, 업스트림 프록시, 로그 기록까지의 전체 처리 흐름을 정의한다.

## 2. 처리 단계

### 2.1 init_by_lua (서버 기동 시 1회)

```lua
-- 초기화 순서
1. C/Rust .so 로드 (ffi.load)
   - luagate_scanner.so  (보안 스캐너)
   - luagate_decoder.so  (URL/인코딩 디코더)
2. 정책 파일 파싱 및 로드 (conf/policies.yaml)
3. 정책 버전(SHA256) → luagate_policy shared dict
4. 초기화 실패 시: nginx 시작 중단 (fatal)
```

### 2.2 rewrite_by_lua (URL 정규화)

**목적**: `path_raw` → `path_normalized` 변환

**정규화 단계 (§5 멀티레이어 디코딩):**

```
입력: path_raw = "/api/v1/%2e%2e/admin?id=1%27OR%271%27%3D%271"
                          │
                          ▼
1단계: URL 디코딩 (percent-encoding)
       /api/v1/../admin?id=1'OR'1'='1
                          │
                          ▼
2단계: 경로 정규화 (.. 제거, 중복 슬래시 등)
       /admin?id=1'OR'1'='1
                          │
                          ▼
3단계: 유니코드 정규화 (NFC)
       /admin?id=1'OR'1'='1
                          │
                          ▼
4단계: null byte, 제어문자 제거
       /admin?id=1'OR'1'='1
                          │
                          ▼
출력: path_normalized = "/admin"
      query_normalized = "id=1'OR'1'='1"
```

**중요**: `path_raw`는 항상 원본 그대로 보존 (로그 기록 목적, ADR-004)

### 2.3 access_by_lua (핵심 처리 — 정책 평가 + 위협 탐지)

```
┌─────────────────────────────────────────────┐
│  access_by_lua 처리 순서                     │
│                                             │
│  1. 정책 버전 확인 (shared dict)             │
│     └─ 변경됨 → 새 정책 로드               │
│                                             │
│  2. C FFI: URL 디코더 (§5)                  │
│     └─ path_raw → path_normalized           │
│                                             │
│  3. C FFI: 보안 스캐너 (§5)                 │
│     입력: path_normalized, query, body      │
│     출력: { threat_type, threat_score }     │
│                                             │
│  4. 정책 평가 (ADR-002)                     │
│     priority 정렬 → first-match-wins        │
│     ├─ allow → 통과                        │
│     └─ deny  → 403 반환                    │
│                │                            │
│                ▼                            │
│  5. deny 처리:                              │
│     - ngx.status = 403                     │
│     - ngx.say(JSON 에러 응답)               │
│     - ngx.exit(403)                        │
│     - 로그: action=deny 기록 예약           │
└─────────────────────────────────────────────┘
```

**에러 응답 형식 (deny):**

```json
{
  "error": "Forbidden",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "reason": "policy: deny-path-traversal"
}
```

### 2.4 proxy_pass (업스트림 프록시)

- `access_by_lua`에서 allow 판정된 요청만 도달
- Nginx `proxy_pass` 지시자로 업스트림 서버에 프록시
- 업스트림 latency 측정: `$upstream_response_time`
- 헤더 전달: `X-Request-ID`, `X-Forwarded-For`, `X-Real-IP`

### 2.5 log_by_lua (요청 완료 후 비동기 로그)

- Nginx 응답 후 처리 (클라이언트 응답에 영향 없음)
- 22개 필드 JSON 레코드 생성 (ADR-004 §4.1)
- `luagate_metrics` shared dict 카운터 증가 (ADR-001)
- `luagate_connections` active count 갱신

## 3. 멀티레이어 디코딩 (§5)

보안 우회 기법에 대응하기 위해 다음 인코딩 레이어를 순차 디코딩한다:

| 레이어 | 기법 | 예시 |
|--------|------|------|
| 1 | URL percent-encoding | `%2e%2e` → `..` |
| 2 | 이중 URL 인코딩 | `%252e` → `%2e` → `.` |
| 3 | 유니코드 인코딩 | `\u002e` → `.` |
| 4 | HTML 엔티티 | `&#46;` → `.` |
| 5 | Base64 (본문) | 바이너리 데이터 검사 |

**구현**: `src/decoder/` Rust 모듈이 처리. Lua에서 `ffi.lua` 바인딩으로 호출.

```lua
-- decoder/ffi.lua 인터페이스 예시
local decoder = require("luagate.decoder.ffi")
local result = decoder.normalize(path_raw, query_raw)
-- result.path_normalized
-- result.query_normalized
-- result.encoding_layers_detected (int)
```

## 4. 요청 컨텍스트 객체

`access_by_lua`에서 `log_by_lua`까지 공유되는 요청 컨텍스트:

```lua
ngx.ctx.luagate = {
  request_id        = "UUID",
  path_raw          = string,
  path_normalized   = string,
  query_string      = string,
  action            = "allow" | "deny",
  matched_rule_id   = string | nil,
  deny_reason       = string | nil,
  threat_type       = string | nil,
  threat_score      = number | nil,
  policy_version    = string,
  start_time_ms     = number,   -- ngx.now() * 1000
}
```

## 5. 타임아웃 설정

| 단계 | 타임아웃 | 설명 |
|------|----------|------|
| C FFI 디코더 | < 0.5ms | Rust 함수 실행 시간 제한 (소프트) |
| C FFI 스캐너 | < 1ms | Rust 함수 실행 시간 제한 (소프트) |
| 업스트림 연결 | 5s | `proxy_connect_timeout` |
| 업스트림 읽기 | 30s | `proxy_read_timeout` |
| 업스트림 쓰기 | 30s | `proxy_send_timeout` |

<!-- ADR 필요 -->
> **TODO**: C FFI 타임아웃 강제 메커니즘 (watchdog timer 등) 구현 시 ADR 필요

## 6. 헬스체크

- 경로: `GET /health`
- 정책 평가 없이 즉시 응답
- 응답: `200 OK` + `{"status": "ok", "policy_version": "..."}`
- Nginx `location /health` 별도 처리 블록

## 7. 의존성

- [spec/security-scanner.md](./security-scanner.md) — 보안 스캐너 상세
- [spec/policy-engine.md](./policy-engine.md) — 정책 평가 엔진 상세
- [spec/log-schema.md](./log-schema.md) — 로그 스키마 상세
- [spec/c-ffi-modules.md](./c-ffi-modules.md) — C FFI 모듈 인터페이스
