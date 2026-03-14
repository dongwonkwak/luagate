# Hot Reload Paths — Write Path / Read Path / Rollback

> 참조: `docs/spec/policy-engine.md §4`, ADR-003, `.claude/knowledge/architecture.md`

## Write Path (정책 업데이트 → 활성화)

```
Admin Client
    │ PUT /api/v1/policies (새 YAML)
    ▼
[Admin API Handler] lua/luagate/admin/handlers/policy.lua
    │
    ├─ 1. Schema validation + conflict/shadow 감지
    │      실패 → 400 ValidationError (파일 미수정)
    │
    ├─ 2. atomic file write
    │      tmp = "conf/policies.yaml.tmp." + ngx.now()
    │      write(tmp, new_yaml)
    │      os.rename(tmp, "conf/policies.yaml")  -- atomic
    │
    ├─ 3. staged_version 계산 (SHA256 of new_yaml)
    │
    └─ 4. audit_log("policy_update", {staged_policy_version, active_policy_version})
         → 200 OK (staged_policy_version, active_policy_version)
         ⚠️ 아직 reload 안됨 — staged != active

    │ POST /api/v1/policies/reload
    ▼
[Reload Handler]
    │
    ├─ 5. reload lock 확인 (409 Conflict if locked)
    │
    ├─ 6. 파일 읽기 + YAML 파싱
    │      실패 → 500 ReloadFailed, LKG 유지
    │
    ├─ 7. SHA256 계산 → blob_key = "policy:" + sha256 + ":blob"
    │
    ├─ 8. safe_set(blob_key, policy_json)
    │      no memory → 500 ReloadFailed, LKG 유지
    │
    ├─ 9. set("active_policy_version", sha256)  -- L2 pointer 교체
    │
    └─ 10. audit_log("policy_reload", {policy_version, status: "success"})
          → 200 OK
```

## Read Path (요청 처리 중 정책 조회)

```
요청 도착 (access_by_lua / preread_by_lua)
    │
    ├─ 1. L1 캐시 확인 (module-level upvalue)
    │      current_v = shared.luagate_policy:get("active_policy_version")
    │      if current_v == _cached_version and _cached_policy != nil:
    │          → L1 캐시 반환 (shared dict 접근 없음 — 최적 경로)
    │
    └─ 2. L1 miss: L2(shared dict) 조회
               blob_key = "policy:" + current_v + ":blob"
               policy_json = shared.luagate_policy:get(blob_key)
               if policy_json == nil:
                   WARN "blob not found: " + current_v
                   → LKG 반환 (_cached_policy 유지)
               else:
                   _cached_policy = cjson.decode(policy_json)
                   _cached_version = current_v
                   → 새 정책 반환
```

## Version Bump 흐름

```
버전 교체 순서:
1. blob 저장 성공 (policy:<new_hash>:blob)
2. active_policy_version = new_hash  ← 이 시점부터 새 정책 적용

각 worker는 다음 요청에서 L1 miss 발생 시 새 버전 로드:
- Worker 1: 다음 요청에서 갱신
- Worker 2: 다음 요청에서 갱신
- Worker N: 다음 요청에서 갱신
⚠️ 순간적으로 일부 worker는 구 버전, 일부는 새 버전을 사용할 수 있음 (허용)
```

## L1 Invalidation

L1 캐시(module-level upvalue)는 active_policy_version 비교로 자동 무효화된다.
명시적 invalidation API 없음 — 버전 변경만으로 충분.

```lua
-- Worker가 새 버전을 발견하면 자동으로 L1 갱신
-- 강제 invalidation이 필요한 경우: 없음 (버전 시스템이 처리)
```

## Exiting Worker 처리

nginx graceful shutdown(HUP 또는 upgrade) 시:
- 기존 worker: 진행 중인 요청 완료 후 shutdown
- 새 worker: init_by_lua에서 현재 active_policy_version 로드 (L1 초기화)
- 기존 worker의 L1 캐시는 shutdown과 함께 소멸 (GC)

## Rollback

```
자동 롤백: reload 실패 시 LKG 유지 (active_policy_version 미변경)

수동 롤백:
1. 이전 정책 파일 복원 (Git에서 checkout)
2. PUT /api/v1/policies (이전 버전 업로드)
3. POST /api/v1/policies/reload

staged 버전으로 강등:
현재는 별도 API 없음 — staged = conf/policies.yaml에 저장된 내용
```

## 실패 시나리오

| 단계 | 실패 원인 | 결과 |
|------|---------|------|
| atomic write | 디스크 풀 | 400/500, 원본 파일 유지 |
| YAML 파싱 | 구문 오류 | 500 ReloadFailed, LKG 유지 |
| safe_set | no memory | 500 ReloadFailed, LKG 유지 |
| active pointer 교체 | (불가능 — in-memory) | 발생 않음 |
| 동시 reload | 두 번째 요청 | 409 Conflict |

## 참조

- `docs/spec/policy-engine.md §4` — loader 상세
- `docs/design/adr/ADR-003` — Hot Reload 시맨틱스
- `lua/luagate/policy/loader.lua` — write path 구현
- `lua/luagate/policy/evaluator.lua` — read path 구현
