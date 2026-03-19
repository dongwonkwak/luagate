# 정책 롤백 절차

## 증상

- 새 정책 배포 후 정상 요청이 차단됨
- `LuagateBlockRateSpike` 알림 발화
- `GET /health` 응답의 `active_http_version`이 의도한 버전과 다름

## 원인 분류

| 원인 | 빈도 |
|------|------|
| 잘못된 정책 규칙 (IP/경로 오타) | 높음 |
| `default_action: deny`로 변경 후 허용 규칙 누락 | 높음 |
| 정책 YAML 문법 오류 (배포 시 422 에러 무시) | 중간 |

## 즉시 조치 (< 5분)

### 1. 현재 상태 확인

```bash
# 현재 정책 버전 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/version | jq .

# 현재 정책 내용 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies > current_policy.yaml
```

### 2. 이전 정책으로 롤백

이전 정책 YAML 파일을 보관하고 있다면:

```bash
# ETag 조회
ETAG=$(curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/version | jq -r '.etag')

# 이전 정책으로 PUT
curl -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/x-yaml" \
  -H "If-Match: $ETAG" \
  --data-binary @previous_policy.yaml \
  http://localhost:9090/api/v1/policies | jq .
```

### 3. Reload 트리거 (canonical 파일 직접 수정한 경우)

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/reload | jq .
```

### 4. 롤백 확인

```bash
# source_version과 active 버전이 일치하는지 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/policies/version | jq .

# Block rate 정상화 확인
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_http_requests_total
```

## 근본 원인 분석

1. 롤백한 정책과 문제 정책을 `diff`로 비교
2. `audit.log`에서 정책 변경 이력 확인 (event: `policy_update_*`/`policy_reload_*`)
3. 정책 검증 파이프라인(CI)에서 누락된 케이스 확인

## 재발 방지

- 정책 변경 전 staging 환경에서 테스트
- 이전 정책 YAML을 git으로 버전 관리
- `PUT /api/v1/policies` 응답의 `422 validation_failed` 에러 무시 금지

## 관련 메트릭/로그 쿼리

```bash
# Block rate 추이
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_http_requests_total

# 정책 reload 실패 횟수
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/metrics | grep luagate_policy_reload
```
