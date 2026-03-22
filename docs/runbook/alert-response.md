# 알림별 대응 절차

> 참조: [conf/alerts.yml](../../conf/alerts.yml)

## LuagateHighBlockRate

**심각도**: warning
**조건**: deny 비율 > 30% (5분 지속)

### 증상

- 정상 사용자 요청이 차단되고 있을 수 있음
- 또는 실제 공격 트래픽이 증가

### 즉시 조치

```bash
# 1. 현재 block rate 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_http_requests_total

# 2. 최근 차단 로그 확인
cat /var/log/luagate/access.log | \
  jq -c 'select(.action == "deny")' | tail -20 | jq .

# 3. 차단 원인 분류
cat /var/log/luagate/access.log | \
  jq -c 'select(.action == "deny") | {src_ip, path_raw, deny_reason, threat_type}' | tail -20 | jq .
```

### 판단 기준

- 동일 IP에서 대량 차단 → 공격 트래픽 (정상 동작)
- 다양한 IP에서 정상 경로 차단 → 정책 오류 가능성 → [정책 롤백](./policy-rollback.md)

---

## LuagateBlockRateSpike

**심각도**: critical
**조건**: 최근 1분 deny rate가 1시간 평균의 10배 초과

### 즉시 조치

```bash
# 1. 상위 차단 IP 확인
cat /var/log/luagate/access.log | \
  jq 'select(.action == "deny") | .src_ip' | sort | uniq -c | sort -rn | head -10

# 2. 최근 정책 변경 여부 확인
cat /var/log/luagate/audit.log | \
  jq -c 'select(.event | test("^policy_"))' | tail -5 | jq .

# 3. 정책 변경이 원인이면 롤백
# → policy-rollback.md 참조
```

---

## LuagateHighLatency

**심각도**: warning
**조건**: p99 레이턴시 > 100ms (5분 지속)

### 즉시 조치

```bash
# 1. 현재 latency 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_http_response_time_ms

# 2. 서버 리소스 확인
top -bn1 | head -20
free -h

# 3. worker 연결 수 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_active_connections
```

→ 상세 진단: [performance-debug.md](./performance-debug.md)

---

## LuagateActiveConnectionsHigh

**심각도**: warning
**조건**: active HTTP connections > 1000 (2분 지속)

### 즉시 조치

```bash
# 1. 연결 수 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_active_connections

# 2. 상위 클라이언트 IP
cat /var/log/luagate/access.log | \
  jq '.src_ip' | sort | uniq -c | sort -rn | head -10

# 3. Nginx worker 상태
ps aux | grep nginx
```

---

## LuagateUpstreamErrors

**심각도**: critical
**조건**: upstream 5xx 에러 발생 (2분 지속)

### 즉시 조치

```bash
# 1. upstream 에러 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_http_upstream_errors_total

# 2. 에러 로그 확인
tail -50 /var/log/luagate/error.log | grep upstream

# 3. upstream 서버 상태 확인
curl -s http://upstream-server:port/health
```

---

## LuagatePolicyReloadFailed

**심각도**: critical
**조건**: 정책 reload 실패 발생

### 즉시 조치

```bash
# 1. 현재 정책 상태 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/version | jq .

# 2. 에러 로그에서 reload 실패 원인 확인
tail -50 /var/log/luagate/error.log | grep -i reload

# 3. 감사 로그에서 최근 정책 변경 확인
cat /var/log/luagate/audit.log | \
  jq -c 'select(.event | test("^policy_"))' | tail -5 | jq .

# 4. 정책 파일 직접 검증
cat conf/policies.yaml | head -20

# 5. 수동 reload 시도
curl -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/reload | jq .
```

---

## LuagateWorkerDown

**심각도**: critical
**조건**: Prometheus scrape 실패 또는 `luagate_policy_loaded{subsystem="http"} == 0` (1분 지속)

### 즉시 조치

```bash
# 1. 프로세스 확인
ps aux | grep nginx

# 2. 헬스체크
curl -s http://localhost:9090/health | jq .

# 3. 프로세스가 없으면 재시작
# Docker
docker compose restart luagate

# systemd
sudo systemctl restart openresty

# 4. 정책 로드 상태 확인 (subsystem별)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_policy_loaded
```

> **참고**: `luagate_policy_loaded`는 `subsystem` 라벨로 HTTP/Stream을 구분한다.
> HTTP-only 배포에서 `{subsystem="stream"} 0`은 정상이다.

→ 상세 복구: [disaster-recovery.md](./disaster-recovery.md)

---

## LuagateStreamPolicyNotLoaded (Optional)

> **이 alert는 stream-enabled 배포에서만 해당된다.**
> 기본 `conf/alerts.yml`에는 포함되지 않으며, stream을 사용하는 배포에서만 별도 alert rule로 추가한다.

**심각도**: warning
**조건**: `luagate_policy_loaded{subsystem="stream"} == 0` (5분 지속)

### 즉시 조치

```bash
# 1. Stream 정책 로드 상태 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_policy_loaded

# 2. active_stream_version 확인
curl -s http://localhost:9090/health | jq .active_stream_version

# 3. nginx.conf에 stream 블록이 존재하는지 확인
grep -c 'stream {' /etc/openresty/nginx.conf
```

### `active_stream_version`이 null/"none"인 경우 판단 기준

`active_stream_version`이 null 또는 `"none"`이라고 해서 항상 정상은 아니다.
반드시 배포 설정과 대조하여 원인을 구분해야 한다.

| 조건 | `nginx.conf`에 stream 블록 | 판단 | 조치 |
|------|---------------------------|------|------|
| (1) HTTP-only 배포 | 없음 | **정상** — stream 서브시스템 미사용 | 없음 |
| (2) Stream-enabled 배포 | 있음 | **장애** — stream 정책 로드 실패 또는 포인터 깨짐 | 아래 복구 절차 진행 |

**장애(2)인 경우 복구 절차**:

```bash
# stream 정책 수동 reload 시도
curl -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/reload | jq .

# 실패 시 에러 로그 확인
tail -50 /var/log/luagate/error.log | grep -i stream
```

> **주의**: `LuagateStreamPolicyNotLoaded` alert가 발생했는데 `active_stream_version`만 보고
> "HTTP-only 배포이므로 정상"으로 오인하지 않도록, 반드시 `nginx.conf`의 stream 블록 존재 여부를 함께 확인할 것.
>
> **참고**: alert rule 예시는 `conf/alerts.yml`의 주석을 참조한다.
