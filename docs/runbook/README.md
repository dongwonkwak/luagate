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

### 로그 경로

각 runbook의 로그 쿼리는 `/var/log/luagate/` 경로를 사용합니다.
환경에 따라 아래와 같이 조정하세요:

| 환경 | access.log / stream.log | audit.log / error.log |
|------|------------------------|----------------------|
| 프로덕션 (파일) | `/var/log/luagate/access.log` | `/var/log/luagate/audit.log` |
| Docker (기본) | `docker compose logs luagate` (stdout) | `docker compose logs luagate` (stderr) |
| 개발 (기본) | stdout (`conf/nginx.conf` 기본 설정) | stderr |

> **audit.log 참고**: 기본 배포에서 감사 이벤트는 `[luagate:audit]` 접두사로 error_log(stderr)에 기록된다.
> Docker 환경에서 audit 이벤트만 필터링:
>
> ```bash
> docker compose logs luagate 2>&1 | grep '\[luagate:audit\]' | \
>   sed 's/.*\[luagate:audit\] //' | jq .
> ```

```bash
# 토큰 설정
export TOKEN="$LUAGATE_ADMIN_TOKEN"

# 헬스체크
curl -s http://localhost:9090/health | jq .
```
