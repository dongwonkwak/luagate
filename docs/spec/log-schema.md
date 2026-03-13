# Log Schema Specification

> **ADR 참조**:
> - [ADR-004 로그/메트릭 데이터 모델 + 관리면 보안](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

LuaGate는 세 가지 로그 스트림을 생성한다:

| 로그 파일 | 내용 | 포맷 |
|-----------|------|------|
| `access.log` | HTTP 요청 로그 | JSON (NDJSON) |
| `stream.log` | TCP 세션 로그 | JSON (NDJSON) |
| `audit.log` | 관리면 감사 로그 | JSON (NDJSON) |
| `error.log` | Nginx/Lua 에러 | Nginx 기본 형식 |

모든 로그는 NDJSON(Newline-Delimited JSON) 형식으로 기록된다.

## 2. HTTP 요청 로그 (`access.log`)

### 2.1 전체 필드 정의 (ADR-004 §4.1)

```json
{
  "timestamp":            "2026-03-13T12:34:56.789Z",
  "request_id":           "550e8400-e29b-41d4-a716-446655440000",
  "src_ip":               "203.0.113.42",
  "src_port":             54321,
  "dst_port":             80,
  "method":               "GET",
  "path_raw":             "/api/v1/%2e%2e/admin",
  "path_normalized":      "/admin",
  "query_string":         "id=1%27OR%271%27%3D%271",
  "http_version":         "1.1",
  "user_agent":           "Mozilla/5.0 (compatible; scanner/1.0)",
  "content_length":       null,
  "action":               "deny",
  "matched_rule_id":      "deny-path-traversal",
  "deny_reason":          "policy: deny-path-traversal",
  "threat_type":          "path-traversal",
  "threat_score":         0.95,
  "latency_ms":           0.8,
  "upstream_latency_ms":  null,
  "response_status":      403,
  "policy_version":       "a3f2c1d4e5b6789012345678901234567890abcd",
  "worker_pid":           12345
}
```

### 2.2 필드 상세

| 필드 | 타입 | Nullable | 설명 |
|------|------|----------|------|
| `timestamp` | string (ISO-8601 UTC) | No | 요청 수신 시각 |
| `request_id` | string (UUID v4) | No | 요청 고유 ID. `X-Request-ID` 응답 헤더로도 전달 |
| `src_ip` | string | No | 클라이언트 IP. `X-Forwarded-For` 최좌측 값 |
| `src_port` | number | No | 클라이언트 원본 포트 |
| `dst_port` | number | No | LuaGate 수신 포트 |
| `method` | string | No | HTTP 메서드 (대문자) |
| `path_raw` | string | No | 원본 요청 경로 (디코딩 전) |
| `path_normalized` | string | No | 정규화된 경로 |
| `query_string` | string | No | 원본 쿼리 스트링 (비어있으면 "") |
| `http_version` | string | No | "1.0", "1.1", "2.0" |
| `user_agent` | string | No | User-Agent 헤더값 |
| `content_length` | number | Yes | 요청 본문 크기. 없으면 null |
| `action` | string (enum) | No | "allow" \| "deny" |
| `matched_rule_id` | string | Yes | 매칭 규칙 ID. 기본 정책 적용 시 null |
| `deny_reason` | string | Yes | 차단 이유. action=allow 시 null |
| `threat_type` | string | Yes | 탐지된 위협 유형. 없으면 null |
| `threat_score` | number (0.0~1.0) | Yes | 위협 점수. 스캐너 미실행 시 null |
| `latency_ms` | number | No | 요청 수신~응답 전송 완료까지 (ms) |
| `upstream_latency_ms` | number | Yes | 업스트림 응답 시간. deny 시 null |
| `response_status` | number | No | HTTP 응답 코드 |
| `policy_version` | string | No | SHA256 정책 버전 해시 |
| `worker_pid` | number | No | 처리 worker의 PID |

### 2.3 X-Forwarded-For 처리

```lua
-- 신뢰할 수 있는 프록시 수: LUAGATE_TRUSTED_PROXIES 환경변수로 설정
local forwarded_for = ngx.req.get_headers()["X-Forwarded-For"]
if forwarded_for then
    -- 최좌측 IP가 실제 클라이언트
    src_ip = forwarded_for:match("^([^,]+)")
else
    src_ip = ngx.var.remote_addr
end
```

## 3. TCP 세션 로그 (`stream.log`)

### 3.1 전체 필드 정의 (ADR-004 §4.2)

```json
{
  "timestamp":          "2026-03-13T12:34:56.789Z",
  "connection_id":      "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "src_ip":             "10.0.1.5",
  "src_port":           12345,
  "dst_port":           443,
  "detected_protocol":  "tls",
  "sni":                "api.example.com",
  "action":             "proxy",
  "deny_reason":        null,
  "duration_ms":        15234,
  "bytes_tx":           2048,
  "bytes_rx":           8192
}
```

### 3.2 필드 상세

| 필드 | 타입 | Nullable | 설명 |
|------|------|----------|------|
| `timestamp` | string (ISO-8601 UTC) | No | 세션 시작 시각 |
| `connection_id` | string (UUID v4) | No | 세션 고유 ID |
| `src_ip` | string | No | 클라이언트 IP |
| `src_port` | number | No | 클라이언트 포트 |
| `dst_port` | number | No | LuaGate 수신 포트 |
| `detected_protocol` | string | No | "tls" \| "http" \| "ssh" \| "unknown" |
| `sni` | string | Yes | TLS SNI. TLS가 아니면 null |
| `action` | string (enum) | No | "proxy" \| "deny" |
| `deny_reason` | string | Yes | 차단 이유. action=proxy 시 null |
| `duration_ms` | number | No | 세션 지속 시간 (ms) |
| `bytes_tx` | number | No | 클라이언트→서버 전송 바이트 |
| `bytes_rx` | number | No | 서버→클라이언트 수신 바이트 |

## 4. 감사 로그 (`audit.log`) (ADR-004 §6.3)

### 4.1 이벤트별 스키마

**정책 변경 (`policy_update`):**
```json
{
  "timestamp": "2026-03-13T12:34:56Z",
  "event": "policy_update",
  "src_ip": "127.0.0.1",
  "policy_version_before": "a3f2c1d4...",
  "policy_version_after": "b4e3f2a1...",
  "warnings_count": 0
}
```

**정책 리로드 (`policy_reload`):**
```json
{
  "timestamp": "2026-03-13T12:34:56Z",
  "event": "policy_reload",
  "src_ip": "127.0.0.1",
  "trigger": "api",
  "status": "success",
  "policy_version": "b4e3f2a1..."
}
```

**인증 실패 (`auth_failure`):**
```json
{
  "timestamp": "2026-03-13T12:34:56Z",
  "event": "auth_failure",
  "src_ip": "127.0.0.1",
  "path": "/api/v1/policies",
  "reason": "missing_token"
}
```

**서버 기동/종료 (`startup` / `shutdown`):**
```json
{
  "timestamp": "2026-03-13T12:00:00Z",
  "event": "startup",
  "policy_version": "a3f2c1d4...",
  "version": "luagate/0.1.0"
}
```

## 5. Nginx 로그 설정

```nginx
# conf/nginx.http.conf
log_format luagate_json escape=json
    '{'
    '"timestamp":"$time_iso8601",'
    '"request_id":"$request_id",'
    '"src_ip":"$remote_addr",'
    ...
    '}';

# log_by_lua_block이 JSON 생성을 담당하므로
# nginx access_log는 비활성화
access_log off;

# Lua가 직접 파일에 기록
# lua/luagate/log/http.lua → /var/log/luagate/access.log
```

## 6. 로그 로테이션 권장 설정

```
# /etc/logrotate.d/luagate
/var/log/luagate/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}
```

## 7. 의존성

- [ADR-004](../design/adr/ADR-004-log-metrics-admin-security.md) — 스키마 원본 정의
- [spec/http-pipeline.md](./http-pipeline.md) — access.log 생성 단계
- [spec/stream-pipeline.md](./stream-pipeline.md) — stream.log 생성 단계
- [spec/admin-api.md](./admin-api.md) — audit.log 생성 단계
