# 로그 조회 및 분석

## 증상

- 특정 요청의 차단/허용 이유를 확인해야 함
- 공격 패턴 분석 필요
- 비정상 트래픽 탐지

## 원인 분류

| 조사 유형 | 주요 로그 |
|----------|----------|
| 요청 차단 이유 | `access.log` |
| 관리 API 감사 | `audit.log` |
| TCP 스트림 분석 | `stream.log` |
| 서버 에러 | `error.log` |

## 즉시 조치 (< 5분)

### 1. 로그 파일 위치

```bash
# Docker 환경
docker compose logs luagate | tail -100

# 로컬/프로덕션
ls -la /var/log/luagate/
# access.log   — HTTP 요청 (NDJSON)
# stream.log   — TCP 세션 (NDJSON)
# audit.log    — Admin API 감사 (NDJSON)
# error.log    — Nginx/Lua 에러
```

### 2. 특정 IP의 요청 조회

```bash
# 특정 IP에서 온 요청
cat /var/log/luagate/access.log | \
  jq 'select(.src_ip == "192.168.1.100")'

# 차단된 요청만
cat /var/log/luagate/access.log | \
  jq 'select(.action == "deny")'
```

### 3. 시간 범위 조회

```bash
# 특정 시간대 요청 (ISO-8601)
cat /var/log/luagate/access.log | \
  jq 'select(.timestamp >= "2026-03-19T10:00:00" and .timestamp <= "2026-03-19T11:00:00")'
```

### 4. 위협 탐지 결과 조회

```bash
# SQLi/XSS 탐지된 요청
cat /var/log/luagate/access.log | \
  jq 'select(.threat_type != null)'

# 위협 유형별 집계
cat /var/log/luagate/access.log | \
  jq 'select(.threat_type != null) | .threat_type' | sort | uniq -c | sort -rn
```

### 5. 정책 매칭 분석

```bash
# 특정 규칙에 의해 처리된 요청
cat /var/log/luagate/access.log | \
  jq 'select(.matched_rule_id == "allow-health")'

# 정책 엔진에 의해 판정된 요청 (default_action 포함)
cat /var/log/luagate/access.log | \
  jq 'select(.decision_source == "policy_engine")'
```

## 근본 원인 분석

### 요청 추적 (request_id)

```bash
# 특정 요청의 전체 컨텍스트
REQUEST_ID="abc-123-def"
cat /var/log/luagate/access.log | jq "select(.request_id == \"$REQUEST_ID\")"
```

### 상위 차단 경로 분석

```bash
# 가장 많이 차단된 경로 Top 10
cat /var/log/luagate/access.log | \
  jq 'select(.action == "deny") | .path_raw' | sort | uniq -c | sort -rn | head -10
```

### 감사 로그 분석

```bash
# Admin API 정책 변경 이력
cat /var/log/luagate/audit.log | \
  jq 'select(.event | test("^policy_"))'
```

## 재발 방지

- 정기적 로그 분석 스케줄 수립
- 알림 룰 (alerts.yml)에서 임곗값 조정
- 공격 패턴 발견 시 정책 규칙 추가

## 관련 메트릭/로그 쿼리

```bash
# 최근 1시간 요청 통계
cat /var/log/luagate/access.log | \
  jq 'select(.timestamp >= "2026-03-19T09:00:00") | .action' | sort | uniq -c

# HTTP 상태 코드 분포
cat /var/log/luagate/access.log | \
  jq '.response_status' | sort | uniq -c | sort -rn
```
