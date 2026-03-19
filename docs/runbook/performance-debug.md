# 성능 저하 시 진단

## 증상

- `LuagateHighLatency` 알림 발화 (p99 > 100ms)
- 사용자 체감 응답 지연
- 처리량(RPS) 감소

## 원인 분류

| 원인 | 빈도 | 진단 방법 |
|------|------|----------|
| upstream 응답 지연 | 높음 | access.log의 upstream 관련 필드 |
| 정책 규칙 과다 (수백 개) | 중간 | 정책 규칙 수 확인 |
| shared dict 용량 부족 | 낮음 | metrics의 free_bytes |
| FFI 호출 지연 (스캐너) | 낮음 | health의 ffi_watchdog |
| worker 수 부족 | 낮음 | CPU 사용률 + 연결 수 |

## 즉시 조치 (< 5분)

### 1. 메트릭 기반 빠른 진단

```bash
# Latency histogram 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_http_response_time_ms

# Active connections
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_active_connections

# Shared dict 용량
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_shared_dict
```

### 2. 시스템 리소스 확인

```bash
# CPU / 메모리
top -bn1 | head -20
free -h

# 디스크 I/O (로그 쓰기 병목)
iostat -x 1 3

# 네트워크 연결 상태
ss -s
```

### 3. FFI watchdog 확인

```bash
# FFI thread leak 여부
curl -s http://localhost:9090/health | jq '{ffi_watchdog_leak_count, ffi_watchdog_timeouts}'
```

### 4. Nginx worker 상태

```bash
# Worker 프로세스 확인
ps aux | grep 'nginx: worker'

# 연결 상태
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/status | jq '{worker_count, uptime_seconds}'
```

## 근본 원인 분석

### Shared dict 용량 분석

```bash
# 각 zone의 사용률 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | \
  grep -E 'luagate_shared_dict_(capacity|free)_bytes' | sort
```

용량 부족 시 `conf/nginx.conf`에서 zone 크기 조정 후 재시작 필요.

### 정책 규칙 수 확인

```bash
# 현재 활성 정책의 규칙 수 세기
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies | grep -c '^\s*- id:'
```

규칙이 100개 이상이면 평가 오버헤드 증가 가능. 규칙 통합 또는 우선순위 최적화 검토.

### Flamegraph 생성 (고급)

```bash
# perf로 프로파일링 (60초)
sudo perf record -F 99 -p $(pgrep -f 'nginx: worker' | head -1) -g -- sleep 60
sudo perf script | ./FlameGraph/stackcollapse-perf.pl | \
  ./FlameGraph/flamegraph.pl > flamegraph.svg
```

## 재발 방지

- 정책 규칙 수 모니터링 (상한선 설정)
- 정기적 성능 벤치마크 (베이스라인 비교)
- shared dict 용량 알림 추가 (free < 10%)

## 관련 메트릭/로그 쿼리

```bash
# 느린 요청 Top 10 (latency_ms 기준)
cat /var/log/luagate/access.log | \
  jq -s 'sort_by(-.latency_ms) | .[0:10] | .[] | {path_raw, response_status, action, latency_ms, timestamp}'
```
