# Zone Registry — Shared Dict Zone 상세 스펙

> 참조: `docs/spec/architecture.md §shared dict`, ADR-001

모든 zone 이름은 `luagate_` prefix 필수. nginx.conf에서 `lua_shared_dict`로 선언.

## Zone 1: luagate_policy

| 항목 | 값 |
|------|-----|
| **역할** | 정책 blob 저장 + active pointer |
| **크기** | 10m |
| **Writer** | admin API (policy update/reload), init_by_lua |
| **Reader** | 모든 worker (access_by_lua, preread_by_lua) |
| **Phase** | 모든 phase (주로 access/preread 읽기) |
| **Fail Mode** | fail-closed: 읽기 실패 시 LKG(_cached_policy) 유지 |
| **HTTP/Stream** | 공통 |
| **Reload 민감도** | 높음 — active_policy_version 교체 시 즉시 새 정책 적용 |

**Value Shape:**
```
Key: "active_policy_version"
Value: "<sha256-hex>" (64자 hex string)

Key: "policy:<sha256>:blob"
Value: JSON string (정렬된 규칙 배열)

Key: "staged_policy_version"
Value: "<sha256-hex>" (가장 최근 PUT 버전)
```

**TTL**: 0 (만료 없음)

**safe_set 사용**: blob 저장 시 `safe_set` 사용.
- `no memory` → reload 실패, LKG 유지
- `forcible=true` → 다른 오래된 blob이 삭제됨 (크기 설정 주의)

---

## Zone 2: luagate_metrics

| 항목 | 값 |
|------|-----|
| **역할** | HTTP 요청 카운터/게이지 (Prometheus exporter용) |
| **크기** | 5m |
| **Writer** | log_by_lua (모든 worker, 원자적 incr) |
| **Reader** | GET /metrics 핸들러 |
| **Phase** | log (쓰기), admin handler (읽기) |
| **Fail Mode** | fail-open: 메트릭 카운터 실패는 요청 처리에 영향 없음 |
| **HTTP/Stream** | HTTP 전용 |
| **Reload 민감도** | 낮음 — 정책 reload와 무관 |

**Value Shape:**
```
Key: "requests_total:<action>:<method>:<route>"
Value: number (counter)
예: "requests_total:allow:GET:/api/v1/users" = 12345

Key: "blocked_total:<threat_type>:<rule_id>"
Value: number (counter)

Key: "active_connections_http"
Value: number (gauge)
```

**TTL**: 0 (만료 없음)
**safe_set 사용**: `incr()` 사용 (원자적 증가). 초기값 없으면 init 값으로 0 사용.
```lua
ngx.shared.luagate_metrics:incr("requests_total:allow:GET:/api/v1", 1, 0)
--                                                                       ↑ init value
```

---

## Zone 3: luagate_connections

| 항목 | 값 |
|------|-----|
| **역할** | 활성 연결 수 (HTTP + Stream) |
| **크기** | 1m |
| **Writer** | preread_by_lua (stream 연결 수락/종료), log_by_lua |
| **Reader** | GET /metrics 핸들러, 모니터링 |
| **Phase** | preread (stream), log (감소) |
| **Fail Mode** | fail-open: 카운터 실패는 연결 처리에 영향 없음 |
| **HTTP/Stream** | Stream 전용 (HTTP는 Nginx 내장 카운터 사용) |
| **Reload 민감도** | 낮음 |

**Value Shape:**
```
Key: "active_stream"
Value: number (gauge, 연결 수락 시 +1, 종료 시 -1)
```

**TTL**: 0

**incr 패턴:**
```lua
-- 연결 수락 시
ngx.shared.luagate_connections:incr("active_stream", 1, 0)

-- 연결 종료 시 (log_by_lua)
ngx.shared.luagate_connections:incr("active_stream", -1, 0)
```

---

## Zone 추가 시 체크리스트

- [ ] 이름: `luagate_` prefix
- [ ] nginx.conf에 `lua_shared_dict` 선언 (크기: 예상 엔트리 × 평균 크기 × 1.5)
- [ ] 이 registry에 zone 정보 추가
- [ ] architecture.md zone map 갱신
- [ ] Fail mode 명시 (fail-open or fail-closed)
- [ ] safe_set no-memory 에러 처리 구현
- [ ] ADR 작성 (신규 zone은 항상 ADR 필요)

## 참조

- `docs/spec/architecture.md §shared dict` — zone 역할 원본
- `docs/design/adr/ADR-001` — shared dict 설계 결정
- `.claude/skills/new-shdict-zone/SKILL.md` — zone 추가 절차
