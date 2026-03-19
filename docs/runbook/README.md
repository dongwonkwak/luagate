# Runbook 인덱스

> LuaGate 운영 시나리오별 대응 절차

| Runbook | 시나리오 |
|---------|---------|
| [policy-rollback.md](./policy-rollback.md) | 정책 롤백 절차 |
| [token-rotation.md](./token-rotation.md) | Admin token 교체 |
| [log-investigation.md](./log-investigation.md) | 로그 조회 및 분석 |
| [alert-response.md](./alert-response.md) | 알림별 대응 절차 |
| [performance-debug.md](./performance-debug.md) | 성능 저하 시 진단 |
| [disaster-recovery.md](./disaster-recovery.md) | 장애 복구 |

## 공통 사전 조건

- LuaGate Admin API 접근 가능 (`localhost:9090`)
- `LUAGATE_ADMIN_TOKEN` 환경변수 설정
- `curl`, `jq` 설치

```bash
# 토큰 설정
export TOKEN="$LUAGATE_ADMIN_TOKEN"

# 헬스체크
curl -s http://localhost:9090/health | jq .
```
