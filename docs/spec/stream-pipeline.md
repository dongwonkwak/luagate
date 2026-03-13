# Stream Pipeline Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-002 정책 평가 규칙](../design/adr/ADR-002-policy-evaluation-conflict-detection.md)
> - [ADR-004 로그/메트릭](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

> **HTTP vs Stream 용어 차이**:
> - HTTP 파이프라인의 허용 action: `allow` / 차단 action: `deny`
> - Stream 파이프라인의 허용 action: **`proxy`** / 차단 action: `deny`
>
> Stream에서 `allow` 대신 `proxy`를 사용하는 이유: TCP 스트림은 단순 허용이 아니라 반드시 업스트림으로 **프록시**해야 하기 때문이다. 정책 스키마의 `action` 필드에 `proxy`를 명시함으로써 업스트림 지정(`upstream: ...`)과의 연관성을 명확히 한다.

LuaGate Stream 파이프라인은 TCP/UDP 레벨 스트림 연결을 처리한다.
HTTP와 달리 L4 레벨에서 연결을 수신하여 프로토콜을 탐지하고 정책 기반으로 프록시 또는 차단한다.

Nginx `stream {}` 블록 (`conf/nginx.stream.conf`)에서 구성한다.

## 2. 처리 단계

### 2.1 preread_by_lua (프로토콜 탐지 + 스트림 정책 평가)

**목적**: 첫 N 바이트를 읽어 애플리케이션 프로토콜을 탐지한다.

```lua
-- preread 단계: ngx.req.socket() 기반으로 preread buffer를 소비하지 않고 조회
local sock = assert(ngx.req.socket())
local data, err = peek_preread_bytes(sock, 16)  -- 의사 코드
if not data then
    -- peek 실패 → "unknown"으로 처리
    ngx.ctx.luagate_stream.detected_protocol = "unknown"
    return
end

-- 프로토콜 탐지 순서
1. TLS ClientHello 탐지 (0x16 0x03 ...)
   └─ SNI 추출: TLS Extension(server_name) 파싱
2. HTTP 메서드 탐지 (GET/POST/... 으로 시작)
3. SSH 배너 탐지 (SSH-2.0-...)
4. 기타 → "unknown"
```

**탐지 가능 프로토콜:**

| 프로토콜 | 탐지 방법 | SNI 추출 |
|---------|---------|---------|
| `tls` | TLS ClientHello 레코드 (첫 바이트: 0x16) | ✅ |
| `http` | HTTP 메서드 문자열 (GET/POST/PUT/DELETE/HEAD/OPTIONS) | ❌ |
| `ssh` | SSH 배너 (`SSH-`) | ❌ |
| `unknown` | 위 패턴 불일치 | ❌ |

탐지 결과는 `ngx.ctx.luagate_stream` 컨텍스트에 저장.

> **중요**: stream 파이프라인에는 HTTP 모듈의 `access_by_lua`와 동일한 단계를 가정하지 않는다.
> 탐지와 정책 평가는 모두 `preread_by_lua`에서 수행하고, 판정 결과만 `ngx.ctx.luagate_stream`에 저장한다.

### 2.2 preread 내 정책 판정

```
┌──────────────────────────────────────────┐
│  stream preread_by_lua 처리 순서          │
│                                          │
│  1. 정책 버전 확인 (shared dict)          │
│     └─ 변경됨 → 새 정책 로드            │
│                                          │
│  2. 스트림 정책 매칭 (ADR-002)            │
│     scope 기준:                          │
│       - src_ip / src_ip_cidr             │
│       - dst_port                         │
│       - detected_protocol                │
│       - sni (TLS인 경우)                 │
│                                          │
│  3. 판정:                                │
│     ├─ proxy → 연결 계속                 │
│     └─ deny → 연결 종료                 │
│              + luagate_connections 감소  │
└──────────────────────────────────────────┘
```

**스트림 정책 예시:**

```yaml
stream_rules:
  - id: deny-ssh-external
    scope:
      detected_protocol: ssh
      src_ip_cidr: "0.0.0.0/0"
    priority: 1
    action: deny

  - id: allow-tls-api
    scope:
      detected_protocol: tls
      sni: "api.example.com"
      dst_port: 443
    priority: 10
    action: proxy
    upstream: "backend:443"
```

### 2.3 proxy_pass (TCP 프록시)

- `preread_by_lua`에서 `proxy` 판정된 연결만 도달
- Nginx stream `proxy_pass` 지시자로 업스트림 TCP 서버에 연결
- 양방향 트래픽 투명 전달
- `bytes_tx`, `bytes_rx` 추적: `$bytes_sent`, `$upstream_bytes_received` 변수 활용

### 2.4 log_by_lua (세션 종료 후 로그)

- TCP 연결 종료 시 트리거
- 12개 필드 JSON 레코드 생성 (ADR-004 §4.2)
- `luagate_connections` shared dict 활성 연결 수 감소

## 3. 스트림 컨텍스트 객체

```lua
ngx.ctx.luagate_stream = {
  connection_id        = "UUID",
  src_ip               = string,
  src_port             = number,
  dst_port             = number,
  detected_protocol    = "tls" | "http" | "ssh" | "unknown",
  sni                  = string | nil,
  action               = "proxy" | "deny",
  matched_rule_id      = string | nil,
  deny_reason          = string | nil,
  start_time_ms        = number,
  upstream             = string | nil,
}
```

## 4. 활성 연결 추적

```lua
-- 연결 수락 시
ngx.shared.luagate_connections:incr("active_stream", 1, 0)

-- 연결 종료 시 (log_by_lua)
ngx.shared.luagate_connections:incr("active_stream", -1, 0)
```

Prometheus 메트릭: `luagate_active_connections{type="stream"}`

## 5. TLS 패스스루 vs 터미네이션

LuaGate Stream 파이프라인은 기본적으로 **TLS 패스스루** 모드다:
- TLS 연결을 복호화하지 않음
- SNI만 탐지하여 라우팅/차단 결정에 사용
- 실제 TLS 핸드쉐이크는 업스트림이 처리

<!-- ADR 필요 -->
> **TODO**: TLS 터미네이션 지원(LuaGate에서 인증서 처리) 필요 시 ADR 필요

## 6. 타임아웃 설정

| 설정 | 값 | 설명 |
|------|----|------|
| `preread_timeout` | 5s | preread 데이터 수신 대기 |
| `proxy_connect_timeout` | 5s | 업스트림 연결 대기 |
| `proxy_timeout` | 300s | 세션 유휴 타임아웃 |

## 7. 의존성

- [spec/policy-engine.md](./policy-engine.md) — 스트림 정책 평가
- [spec/log-schema.md](./log-schema.md) — TCP 세션 로그 스키마
- [spec/architecture.md](./architecture.md) — 전체 프로세스 모델
