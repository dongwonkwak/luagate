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
| `src_ip` | string | No | 클라이언트 IP. trusted proxy 기준으로 계산된 실제 원본 IP |
| `src_port` | number | No | 클라이언트 원본 포트 |
| `dst_port` | number | No | LuaGate 수신 포트 |
| `method` | string | No | HTTP 메서드 (대문자) |
| `path_raw` | string | No | 원본 요청 경로 (디코딩 전) |
| `path_normalized` | string | No | 정규화된 경로 |
| `query_string` | string | No | redaction 적용된 raw 쿼리 스트링 (비어있으면 "") |
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

### 2.3 X-Forwarded-For 처리 — Trusted Proxy 기반 파싱

XFF 헤더의 최좌측 IP를 무조건 신뢰하면 IP 스푸핑에 취약하다.
LuaGate는 **right-to-left** 파싱 방식을 사용한다:
신뢰하는 프록시 수(`LUAGATE_TRUSTED_PROXIES`)만큼 오른쪽에서 건너뛰고,
그 다음 IP를 실제 클라이언트 IP로 사용한다.

```lua
-- LUAGATE_TRUSTED_PROXIES: 신뢰하는 프록시 홉 수 (기본값: 0)
-- 예: L4 LB 1개 뒤에 배치 → LUAGATE_TRUSTED_PROXIES=1
local trusted_proxies = tonumber(os.getenv("LUAGATE_TRUSTED_PROXIES")) or 0
local real_ip

if trusted_proxies == 0 then
    -- 프록시 없음: remote_addr 직접 사용 (XFF 무시)
    real_ip = ngx.var.remote_addr
else
    local xff = ngx.req.get_headers()["X-Forwarded-For"]
    if xff then
        local ips = {}
        for ip in xff:gmatch("[^,%s]+") do
            table.insert(ips, ip)
        end
        -- right-to-left: 신뢰 프록시 수만큼 오른쪽에서 건너뜀
        local idx = #ips - trusted_proxies
        real_ip = (idx >= 1) and ips[idx] or ngx.var.remote_addr
    else
        real_ip = ngx.var.remote_addr
    end
end

-- real_ip_module 대안: ngx_http_realip_module을 사용하면
-- nginx.conf에서 set_real_ip_from + real_ip_header로 동일 효과
-- 단, Lua 로직과 중복되지 않도록 하나만 선택해야 함
```

> **권장**: 프로덕션 환경에서는 Nginx `ngx_http_realip_module`을 우선 사용하고,
> `$realip_remote_addr`을 `src_ip` 필드에 사용한다. Lua 기반 파싱은 모듈 사용이 불가할 때의 대안이다.

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
  "staged_policy_version": "b4e3f2a1...",
  "active_policy_version": "a3f2c1d4...",
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
# Nginx-managed logging 방식 (권장):
# log_by_lua에서 ngx.var를 사용하여 JSON을 구성하고,
# nginx log_format + access_log 지시자로 파일에 기록한다.
# 이 방식은 Nginx의 log buffering, rotation 시그널(USR1) 처리를 활용한다.

log_format luagate_json escape=json
    '{"timestamp":"$time_iso8601",'
    '"request_id":"$http_x_request_id",'
    '"src_ip":"$realip_remote_addr",'
    '"method":"$request_method",'
    '"path_raw":"$request_uri",'
    '"response_status":$status,'
    '"latency_ms":$request_time,'
    '"worker_pid":$pid}';

# log_by_lua에서 ngx.var.luagate_log_json 변수에 전체 JSON을 설정하거나,
# Nginx log_format으로 구조화된 필드를 조합한다.
access_log /var/log/luagate/access.log luagate_json buffer=64k flush=5s;
```

> **Lua 직접 파일 쓰기(`io.open`/`io.write`) 사용 금지**:
> - Lua에서 `io.open`으로 직접 파일에 쓰면 Nginx의 non-blocking I/O 모델을 우회하여 worker 이벤트 루프를 블로킹할 수 있다.
> - 파일 rotate 시 `kill -USR1` 시그널이 Nginx 관리 파일 핸들에만 작용하므로, Lua가 직접 연 파일 핸들은 rotate 후에도 구 파일에 계속 쓰게 된다.
> - **대안**: Nginx `access_log`(위 설정), 또는 non-blocking socket logger(syslog/UDP), 또는 per-worker in-memory buffer + 주기적 flush 방식을 사용한다.

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

<!-- ADR 필요 -->
> **TODO**: metrics-cardinality-and-export — low-cardinality 레이블 정책, route 정규화 전략, Prometheus export 형식 결정 시 ADR 필요

<!-- ADR 필요 -->
> **TODO**: log-redaction-and-retention — 민감정보 마스킹 대상/방법, 로그 보존 기간, 파기 정책 결정 시 ADR 필요

## 7. 의존성

- [ADR-004](../design/adr/ADR-004-log-metrics-admin-security.md) — 스키마 원본 정의
- [spec/http-pipeline.md](./http-pipeline.md) — access.log 생성 단계
- [spec/stream-pipeline.md](./stream-pipeline.md) — stream.log 생성 단계
- [spec/admin-api.md](./admin-api.md) — audit.log 생성 단계
