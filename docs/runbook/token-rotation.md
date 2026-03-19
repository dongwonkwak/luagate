# Admin Token 교체

## 증상

- 토큰 유출 의심 (로그에서 비인가 Admin API 접근 시도 발견)
- 정기 토큰 교체 주기 도래
- 401 에러 없이 비인가 요청이 성공하는 경우

## 원인 분류

| 원인 | 대응 긴급도 |
|------|-----------|
| 토큰 유출 (로그/소스코드 노출) | 즉시 |
| 정기 교체 (보안 정책) | 계획 |
| 팀원 퇴사/권한 변경 | 높음 |

## 즉시 조치 (< 5분)

### 1. 새 토큰 생성

```bash
# 256-bit random 토큰 생성 (32바이트 entropy)
NEW_TOKEN=$(openssl rand -base64 32)
echo "New token: $NEW_TOKEN"
```

### 2. 토큰 교체 (재기동 없음)

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"new_token\": \"$NEW_TOKEN\"}" \
  http://localhost:9090/api/v1/admin/token/rotate | jq .
```

### 3. 환경변수 갱신

```bash
# 로컬
export LUAGATE_ADMIN_TOKEN="$NEW_TOKEN"

# Docker Compose
# docker-compose.yml 또는 .env 파일에서 LUAGATE_ADMIN_TOKEN 갱신
# 재기동 없이 적용됨 (rotate API 사용 시)

# Kubernetes Secret
# 주의: LuaGate는 시작 시 환경변수를 한 번만 읽는다.
# rotate API로 즉시 교체 후, Secret도 갱신하여 Pod 재시작에 대비
kubectl create secret generic luagate-admin-token \
  --from-literal=token="$NEW_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
# 롤링 재시작으로 새 Secret 반영 (rotate API 사용 시 즉시 불필요, Pod 재생성 대비)
kubectl rollout restart deployment/luagate
```

### 4. 교체 확인

> **참고**: 이전 토큰은 30초 grace period 동안 계속 유효하다.

```bash
# 새 토큰으로 즉시 접근 확인
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $NEW_TOKEN" \
  http://localhost:9090/api/v1/status
# 기대값: 200

# 30초 후 이전 토큰 만료 확인
sleep 35
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:9090/api/v1/status
# 기대값: 401
```

## 근본 원인 분석

1. `audit.log`에서 토큰 유출 경로 추적
2. 환경변수/설정 파일 접근 권한 검토
3. CI/CD 파이프라인에서 토큰 노출 여부 확인

## 재발 방지

- 토큰을 소스코드에 하드코딩하지 않음
- Secret manager (Vault, K8s Secret) 사용
- 정기 교체 주기 설정 (예: 90일)
- `audit.log`에서 비인가 접근 모니터링

## 관련 메트릭/로그 쿼리

```bash
# 감사 로그에서 인증 실패 조회
cat /var/log/luagate/audit.log | jq 'select(.event == "auth_failure")'

# 최근 Admin API 접근 이력
cat /var/log/luagate/audit.log | jq 'select(.event != null)' | tail -20
```
