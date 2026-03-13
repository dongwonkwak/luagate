# LuaGate 아키텍처 요약

> 상세 스펙: `docs/spec/architecture.md`, ADR-001~004

## 핵심 설계 원칙

1. **단일 인스턴스 단위 배포** — 수평 확장은 LB 뒤 다중 인스턴스로 달성
2. **Worker 간 공유 = shared dict만** — IPC, 소켓, 파일 기반 워커 통신 없음
3. **C FFI는 동기·동일 Worker 내** — IPC 없음, 각 worker에서 `ffi.load()` 후 직접 호출
4. **정책 캐시 = module-level upvalue** — `ngx.ctx`가 아님 (요청 범위 아님, worker 수명 동안 유지)
5. **Stream 파이프라인 = `preread_by_lua` 기반** — HTTP의 `access_by_lua`에 해당하는 단계가 없음

## 프로세스 모델

```
OS Process: nginx (OpenResty)
│
├── Master Process: 설정 파싱, worker 스폰, HUP 시그널 처리
│
└── Worker Pool (worker_processes = auto)
    ├── Worker 1: 독립 Lua VM, 이벤트 기반 비동기
    ├── Worker 2: 독립 Lua VM
    └── Worker N: 독립 Lua VM
         │
         └── ngx.shared.DICT (mmap, 모든 worker 공유)
              ├── luagate_policy   — 정책 blob + active pointer
              ├── luagate_metrics  — 카운터/게이지
              └── luagate_connections — 활성 연결 수
```

## Shared Dict Zone 상세

| Zone 이름 | Writer | Reader | 사용 Phase | Fail Mode | HTTP/Stream | Reload 민감도 |
|-----------|--------|--------|-----------|-----------|------------|--------------|
| `luagate_policy` | admin API / init_by_lua | 모든 worker | access/preread | fail-closed (LKG 유지) | 공통 | 높음 |
| `luagate_metrics` | log_by_lua (모든 worker) | metrics exporter | log | fail-open (warn) | HTTP | 낮음 |
| `luagate_connections` | preread/log_by_lua | metrics | log | fail-open (warn) | Stream | 낮음 |

**원자성**: versioned keyspace + active pointer 방식
- 정책 업로드: `policy:<sha256>:blob` 키에 새 데이터 저장
- 활성화: `active_policy_version` 포인터를 원자적으로 교체
- 조회: active pointer 읽기 → 해당 blob 읽기 (2-step, 동일 worker 내에서는 일관성 보장)

## HTTP 파이프라인 요약

```
[init_by_lua]         — 서버 기동 1회: .so 로드, 정책 로드
[rewrite_by_lua]      — URL 정규화 (path_raw → path_normalized)
[access_by_lua]       — 정책 평가 + 보안 스캐너 (핵심 처리)
[proxy_pass]          — 업스트림 프록시 (allow 판정 시)
[log_by_lua]          — JSON 로그 + 메트릭 업데이트
```

**중요**: URL 디코딩/정규화는 `rewrite_by_lua`에서만 수행. `access_by_lua`에서 재정규화하지 않음.

## Stream(TCP) 파이프라인 요약

```
[preread_by_lua]      — 프로토콜 탐지 + 정책 평가 (HTTP의 rewrite+access 역할 통합)
[proxy_pass]          — Nginx native TCP 프록시 (Lua 관여 없음)
[log_by_lua]          — 세션 로그 + 연결 수 감소
```

**중요**: Stream은 `access_by_lua` 없음. 탐지와 판정 모두 `preread_by_lua`에서 수행.
HTTP action: `allow` / `deny`, Stream action: `proxy` / `deny`

## 정책 캐시 패턴 (Worker-level)

```lua
-- lua/luagate/policy/evaluator.lua
local _cached_policy = nil   -- worker-level upvalue (ngx.ctx 아님!)
local _cached_version = nil

local function get_policy()
    local current_version = ngx.shared.luagate_policy:get("active_policy_version")
    if _cached_version == current_version and _cached_policy ~= nil then
        return _cached_policy  -- 버전 동일 → shared dict 접근 없이 반환
    end
    -- 버전 변경 → blob 조회 + upvalue 갱신
    local blob_key = "policy:" .. current_version .. ":blob"
    ...
end
```

## Hot Reload 7단계 파이프라인

1. `PUT /api/v1/policies` → `conf/policies.yaml` atomic write
2. `POST /api/v1/policies/reload` 트리거
3. 파일 읽기 + YAML 파싱
4. Schema validation + conflict/shadow 감지
5. SHA256 해시 계산
6. `luagate_policy["policy:<hash>:blob"]` 저장
7. `active_policy_version` 포인터 교체 → 다음 요청부터 새 정책 적용

실패 시: active pointer 교체 없이 이전 버전(LKG) 유지.

## 기술 스택

| 계층 | 기술 | 버전 |
|------|------|------|
| 웹 서버/런타임 | OpenResty | 1.25.x |
| 스크립팅 | LuaJIT | 2.1 |
| 고성능 모듈 | Rust (cdylib) | 1.75+ |
| 정책 설정 | YAML | — |
| 메트릭 | Prometheus text format | 0.0.4 |
| 로그 | JSON (NDJSON) | — |

## 의존성 참조

- `docs/spec/architecture.md` — 전체 다이어그램
- `docs/design/adr/ADR-001` — 실행 모델 + shared dict + FFI
- `docs/design/adr/ADR-002` — 정책 평가 규칙
- `docs/design/adr/ADR-003` — Hot Reload 시맨틱스
- `docs/design/adr/ADR-004` — 로그/메트릭/Admin 보안
