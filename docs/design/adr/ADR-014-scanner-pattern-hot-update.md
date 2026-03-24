# ADR-014: Scanner Pattern Hot Update

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-23 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-226](https://linear.app/dongwon/issue/DON-226) |
| **Depends on** | [ADR-003](./ADR-003-policy-storage-hot-reload.md), [ADR-009](./ADR-009-ffi-timeout-enforcement.md) |
| **Resolves** | security-scanner.md §6 TODO: 패턴 핫 업데이트 구현 시 ADR 필요 |

---

## Status

**Accepted** — 보안 스캐너 패턴을 서버 재시작 없이 런타임에 갱신하는 메커니즘을 확정한다.

---

## Context

현재 보안 스캐너(`luagate_scanner.so`)는 `init_by_lua`에서 `luagate_scanner_init()`을 1회 호출하여 패턴을 로드한다. YAML 로더는 stub 상태이며 하드코딩된 패턴만 사용한다 (`src/scanner/src/lib.rs:209-218`). 새 패턴을 적용하려면 Rust 바이너리를 재빌드하거나 Nginx를 재시작해야 한다.

### 해결해야 할 문제

1. **런타임 패턴 갱신**: 새 OWASP 패턴, 커스텀 규칙을 서비스 중단 없이 적용
2. **원자성**: 패턴 교체 중 스캔 요청이 불완전한 패턴 세트를 사용하는 상황 방지
3. **Concurrent read 성능**: worker 내부에서 reload가 진행되지 않는 정상 상태에서 scan 호출의 lock contention 최소화
4. **실패 안전성**: 새 패턴이 유효하지 않을 때 기존 패턴(LKG) 유지
5. **버전 추적**: 어느 패턴 세트가 현재 활성인지 확인

### 현재 구현의 제약

| 항목 | 현재 상태 | 문제 |
|------|----------|------|
| `SCANNER` 타입 | `Lazy<Mutex<Option<Scanner>>>` | Mutex는 모든 `luagate_scan_http` 호출마다 exclusive lock 필요 — reload가 없는 정상 상태에서도 불필요한 contention |
| 패턴 소스 | Rust 바이너리 하드코딩 | YAML stub만 존재, 런타임 로드 불가 |
| 패턴 교체 | `luagate_scanner_init()` 재호출 | init은 startup-fatal 계약 (실패 시 서버 시작 차단) — 런타임 reload 용도에 부적합 |

### 검토된 대안

| 대안 | 장점 | 단점 |
|------|------|------|
| `luagate_scanner_init()` 재호출 | 기존 함수 재사용 | startup-fatal 계약 위반 (런타임 실패 시 서버 abort 위험), Mutex로 인한 scan/reload 간 contention |
| **전용 `luagate_scanner_reload()` + RwLock** | reload 미진행 시 read lock contention-free 획득, reload 실패 시 LKG 유지, startup 계약 분리 | 새 FFI 함수 추가 필요, RwLock 마이그레이션 |
| Lua 레벨에서 패턴 관리 | FFI 변경 불필요 | 정규식 컴파일 성능 저하, Lua-Rust 경계 데이터 전달 복잡 |

---

## Decision

### 1. 전용 `luagate_scanner_reload()` FFI 함수 추가

`luagate_scanner_init()` 재호출 대신 런타임 전용 reload 함수를 추가한다.

```c
/* 새 FFI 함수 — 런타임 패턴 교체 */
int luagate_scanner_reload(
    const char *patterns_path,
    size_t      patterns_path_len
);
```

**init vs reload 계약 분리:**

| 함수 | 호출 시점 | 실패 시 동작 | 용도 |
|------|----------|------------|------|
| `luagate_scanner_init()` | `init_by_lua` 1회 | `LUAGATE_INTERNAL_ERROR` → 서버 시작 실패 (startup-fatal) | 초기 패턴 로드 |
| `luagate_scanner_reload()` | Admin API 트리거 | `LUAGATE_INTERNAL_ERROR` → LKG 유지, 에러 반환 | 런타임 패턴 교체 |

**이유**: `luagate_scanner_init()`은 ADR-001의 startup-fatal 계약을 따른다. 런타임 reload에서 이 함수를 재사용하면 실패 시 서버가 abort될 수 있다. 전용 함수로 분리하여 reload 실패가 기존 서비스에 영향을 주지 않도록 한다.

### 2. `SCANNER` global을 `RwLock`으로 변경

```rust
// 현재 (변경 전)
static SCANNER: Lazy<Mutex<Option<Scanner>>> = Lazy::new(|| Mutex::new(None));

// 변경 후
static SCANNER: Lazy<RwLock<Option<Scanner>>> = Lazy::new(|| RwLock::new(None));
```

- **`luagate_scan_http()`**: `try_read()`로 RwLock 접근. reload가 진행되지 않는 정상 상태에서 read lock은 contention 없이 즉시 획득 가능하여 Mutex 대비 스캔 성능 향상. SCANNER는 worker-local이므로 worker 내부에서 reload thread(write)와 scan 호출(read) 간 동기화가 목적이다.
- **`luagate_scanner_init()`**: `write()`로 exclusive lock 획득 (startup 시 1회).
- **`luagate_scanner_reload()`**: `write()`로 exclusive lock 획득 (패턴 교체 시).

**Reload 중 스캔 동작:**

`luagate_scan_http()`가 `try_read()`를 사용하므로, reload 중(write lock 보유) `try_read()`는 즉시 실패한다. 이 경우 `LUAGATE_INTERNAL_ERROR`를 반환한다 (fail-closed). Lua 래퍼는 이를 `scanner_fail:-4`로 매핑하고 403 deny로 처리한다.

reload는 100ms 이내에 완료되어야 한다 (ADR-009 watchdog 적용). 이 시간 동안 도착하는 요청은 fail-closed로 deny되며, reload 완료 후 즉시 정상 스캔을 재개한다.

### 3. Hot Reload 5단계 파이프라인

ADR-003의 정책 Hot Reload 7단계를 참고하여 스캐너 패턴에 적합한 5단계 파이프라인을 정의한다.

```
[1] Read    — YAML 패턴 파일 읽기 (conf/scanner-patterns/*.yaml)
[2] Parse   — YAML 파싱 + 스키마 검증 (threat_type, rule_name, pattern, score 필드)
[3] Compile — 정규식 컴파일 (Regex::new). 실패 시 전체 reload 중단 + LKG 유지
[4] Swap    — RwLock write lock 획득 → Scanner 인스턴스 교체 (atomic)
[5] Verify  — shared dict 메타데이터 갱신 (version, loaded_at, pattern_count)
```

**모든 단계에서 fail-closed:**

| 단계 | 실패 시 동작 |
|------|------------|
| Read | LKG 유지, `LUAGATE_INTERNAL_ERROR` 반환 |
| Parse | LKG 유지, `LUAGATE_INTERNAL_ERROR` 반환 |
| Compile | LKG 유지, `LUAGATE_INTERNAL_ERROR` 반환 (1개라도 정규식 컴파일 실패 시 전체 중단) |
| Swap | LKG 유지, `LUAGATE_INTERNAL_ERROR` 반환 (write lock 획득 실패 = poisoned) |
| Verify | 스캐너는 이미 교체됨, shared dict 갱신 실패 시 WARN 로그 (스캔 기능에는 영향 없음) |

**LKG (Last Known Good) 패턴:**

- reload 중 새 `Scanner` 인스턴스를 별도로 구성한다.
- Swap 단계에서 구성이 완료된 새 인스턴스만 기존 인스턴스를 교체한다.
- Read/Parse/Compile 실패 시 기존 `Scanner`는 그대로 유지된다 (write lock 미획득).

### 4. 버전 관리

패턴 버전은 패턴 파일 전체 내용의 **SHA256 해시**로 식별한다.

**해시 계산 방식:**

1. `conf/scanner-patterns/` 디렉토리의 모든 `.yaml` 파일을 파일명 기준 사전순 정렬
2. 각 파일의 바이트 내용을 순서대로 연결 (concatenate)
3. 연결된 바이트열의 SHA256 해시 계산

**Shared dict 저장:**

`luagate_scanner_patterns` shared dict zone에 다음 키를 추적한다:

| 키 | 값 | 설명 |
|---|---|------|
| `scanner:active_version` | SHA256 hex (64자) | 현재 활성 패턴 버전 |
| `scanner:loaded_at` | ISO 8601 timestamp | 마지막 패턴 로드 시각 |
| `scanner:pattern_count` | 정수 | 현재 로드된 패턴 수 |

> **zone prefix**: `luagate_scanner_patterns` — `luagate_` prefix 규칙 준수.

### 5. Cross-Worker 동기화

`SCANNER`는 Rust 프로세스 로컬(static) 상태이므로, `luagate_scanner_reload()`는 호출한 worker 프로세스 내에서만 패턴을 갱신한다. Admin API 요청을 처리한 단일 worker만 새 패턴을 적용하고, 나머지 worker는 구 패턴을 유지하는 문제가 발생한다.

ADR-003 정책 Hot Reload와 동일한 shared dict version polling 패턴으로 해결한다.

1. Admin API handler가 `luagate_scanner_reload()` 호출 성공 후, `luagate_scanner_patterns` shared dict에 `scanner:active_version`을 새 SHA256 해시로 갱신한다.
2. 각 worker는 `init_worker_by_lua`에서 `ngx.timer.every(1)`로 1초 주기 타이머를 등록한다.
3. 타이머 콜백에서 `luagate_scanner_patterns:get("scanner:active_version")`을 읽고, worker 로컬 버전(`_local_scanner_version` module upvalue)과 비교한다.
4. 버전이 다르면 해당 worker 내에서 `luagate_scanner_reload()`를 호출하여 패턴을 갱신한다.
5. reload 성공 시 `_local_scanner_version`을 새 버전으로 업데이트한다. 실패 시 LKG 유지, WARN 로그.

```
[Admin API worker]                    [Other workers]
   │                                      │
   ├─ luagate_scanner_reload() 성공        │
   ├─ shared dict: scanner:active_version  │
   │   = "new_sha256"                      │
   │                                      ┌┤ timer.every(1s) 콜백
   │                                      ││ get("scanner:active_version")
   │                                      ││ != _local_scanner_version?
   │                                      ││  → luagate_scanner_reload()
   │                                      ││  → _local_scanner_version = new
   │                                      └┤
```

**전파 지연**: 최대 1초 (타이머 주기). ADR-003 정책 reload는 "다음 요청 시" 전파되지만, 스캐너 패턴은 Rust FFI 호출이므로 요청 처리 시점에 lazy 확인이 불가능하다. 따라서 주기적 타이머로 능동적 polling을 수행한다.

**init_worker_by_lua 초기화**: 각 worker 시작 시 shared dict에서 현재 `scanner:active_version`을 읽어 `_local_scanner_version`을 초기화한다. 이 시점에서 `luagate_scanner_init()`은 이미 `init_by_lua`에서 완료된 상태이므로 추가 reload는 불필요하다.

### 6. Admin API 엔드포인트

`/api/v1/scanner/patterns` 하위 3개 엔드포인트를 추가한다. 기존 정책 관리(`/api/v1/policies`)와 동일한 auth/locking 패턴을 따른다.

#### GET /api/v1/scanner/patterns

현재 패턴 상태를 조회한다.

```json
{
  "active_version": "a3f2c1d4e5b6...",
  "loaded_at": "2026-03-23T10:30:00Z",
  "pattern_count": 24,
  "patterns": [
    {
      "threat_type": "sqli",
      "rule_name": "sqli_union_select",
      "score": 0.9
    }
  ]
}
```

#### PUT /api/v1/scanner/patterns

패턴 파일을 업로드한다. 요청 body는 YAML 형식의 패턴 배열(bare array)이다.

**파일 매핑 규칙:**

- 저장 대상: 단일 파일 `conf/scanner-patterns/custom.yaml`
- 스키마 변환: 요청 body가 bare array(`- threat_type: ...`)인 경우, 서버가 `patterns:` top-level 키로 래핑하여 저장한다. `patterns:` 키가 이미 포함된 body는 그대로 저장한다.
- 기존 `custom.yaml`은 원자적으로 교체된다 (다른 패턴 파일 `sqli.yaml`, `xss.yaml` 등은 변경하지 않음).

**처리 순서:**

1. 요청 body를 임시 파일에 기록 (`custom.yaml.tmp`)
2. YAML 파싱 + 스키마 검증 + 정규식 컴파일 (검증 실패 시 임시 파일 삭제, 400 반환. canonical source는 변경 없음)
3. 기존 `custom.yaml`이 존재하면 `custom.yaml.bak`으로 복사 (rollback 백업)
4. `rename()` 시스템 콜로 `custom.yaml.tmp` → `custom.yaml` 원자적 교체
5. `luagate_scanner_reload()` 호출 — 전체 `conf/scanner-patterns/` 디렉토리 재로드
6. reload 실패 시: `custom.yaml.bak` → `custom.yaml`로 복원 (rollback), `.bak` 삭제, LKG 유지, 에러 반환
7. reload 성공 시: `custom.yaml.bak` 삭제, shared dict `scanner:active_version` 갱신 (§5 cross-worker 동기화 트리거)

**Rollback 보장**: 검증(Parse + Compile)은 rename 전에 완료되므로, 검증 실패 시 canonical source(`custom.yaml`)는 변경되지 않는다. Reload 단계(전체 디렉토리 재로드)에서 실패하는 경우에만 `.bak` rollback이 필요하며, 이는 다른 파일(`sqli.yaml` 등)과의 조합 문제 등 사전 검증으로 잡을 수 없는 케이스를 처리한다.

```
PUT /api/v1/scanner/patterns
Content-Type: application/yaml
Authorization: Bearer <token>

- threat_type: sqli
  rule_name: custom_sqli_1
  pattern: "(?i)(custom_injection_pattern)"
  score: 0.95
```

> 위 bare array body는 서버에서 다음과 같이 `patterns:` 래핑되어 저장된다:
> ```yaml
> patterns:
>   - threat_type: sqli
>     rule_name: custom_sqli_1
>     pattern: "(?i)(custom_injection_pattern)"
>     score: 0.95
> ```

응답:
- `200 OK`: 업로드 + reload 성공
- `400 Bad Request`: YAML 파싱 또는 정규식 컴파일 실패
- `409 Conflict`: 다른 reload가 진행 중

#### POST /api/v1/scanner/patterns/reload

기존 파일에서 패턴을 다시 로드한다 (파일 시스템에 직접 패턴 파일을 배치한 경우).

```
POST /api/v1/scanner/patterns/reload
Authorization: Bearer <token>
```

응답:
- `200 OK`: reload 성공 (새 version, pattern_count 포함)
- `400 Bad Request`: 패턴 파일 파싱 또는 정규식 컴파일 실패 (LKG 유지)
- `409 Conflict`: 다른 reload가 진행 중

**동시 reload 방지:**

ADR-003과 동일하게 shared dict에 `scanner_reload_lock` 키를 사용한다. Admin API handler는 reload 후 shared dict `scanner:active_version`을 갱신하고 응답한다. 다른 worker로의 전파는 §5 cross-worker 동기화 타이머가 담당한다.

```lua
local ok = dict:add("scanner_reload_lock", ngx.worker.id(), 5)
if not ok then
    return 409, { error = "ReloadInProgress" }
end
-- reload 수행
dict:delete("scanner_reload_lock")
```

### 7. Reload Budget 및 ADR-009 Watchdog 적용

<!-- TODO: §7 timeout 격리 (LUAGATE_TIMEOUT(-5) 반환 경로)는 Phase 3-Reliability (DON-232)에서
     ADR-009 Layer 2 detached thread watchdog와 통합하여 구현 예정.  현재는 Lua worker.lua에서
     elapsed > RELOAD_WARN_THRESHOLD 시 CRIT 로그만 출력한다. -->

`luagate_scanner_reload()`는 ADR-009의 L2 watchdog 계층을 적용한다.

| 항목 | 값 |
|------|---|
| Reload budget (Layer 1) | 100ms |
| Hard timeout (Layer 2) | 1000ms |
| 초과 시 동작 | `LUAGATE_TIMEOUT(-5)` 반환, LKG 유지 |
| Watchdog | L2 detached thread (ADR-009 §3.2) |

**Layer 2 timeout 시 동작:**

L2 watchdog는 detached thread 방식이다 (ADR-009 §3.2). 작업 thread가 timeout을 초과하면 호출자 thread는 즉시 `LUAGATE_TIMEOUT(-5)`을 반환하고, 작업 thread는 detach된다. Detached thread에서 보유 중인 write lock은 해당 thread 외부에서 명시적으로 해제할 수 없다. 그러나 Rust `panic=abort` 설정(rust-ffi-modules.md §8)에 의해 detached thread 내부에서 panic이 발생하면 worker 프로세스 자체가 abort되며, Nginx master가 worker를 재시작한다. Detached thread가 정상 종료하면 `Drop`에 의해 lock이 해제된다.

**Detached thread hang 시 /health 503 전환 메커니즘:**

Detached thread가 write lock을 쥔 채 무한 hang하면, 해당 worker의 `luagate_scan_http()`는 모든 호출에서 `try_read()` 실패로 `LUAGATE_INTERNAL_ERROR(-4)`를 반환하여 403 deny 처리한다 (fail-closed). 그러나 leak 카운터가 reload 1회만 증가하면 `/health`가 200을 유지하여 오케스트레이터가 문제를 감지하지 못하는 시나리오가 발생할 수 있다. 이를 방지하기 위해 다음 3단계 메커니즘을 적용한다.

1. **Per-worker leak 카운터 증가**: `luagate_scanner_reload()` timeout 발생 시 shared dict에 `ffi:timeout:leak:<worker_id>` 키를 증가시킨다 (ADR-009 §3.3과 동일 패턴). 이 카운터는 worker 재시작 전까지 감소하지 않는 단조 증가 카운터다.

2. **Worker-local `scanner_reload_failed` 플래그 설정**: timeout 발생 시 Rust 측 worker-local static 변수 `SCANNER_RELOAD_FAILED: AtomicBool`을 `true`로 설정한다. 이후 모든 `luagate_scan_http()` 호출에서 `try_read()` 성공 여부와 무관하게 이 플래그를 먼저 확인한다. 플래그가 `true`이면 즉시 `LUAGATE_INTERNAL_ERROR(-4)`를 반환한다. 이는 detached thread가 뒤늦게 lock을 해제하더라도 손상된 상태의 scanner를 사용하지 않도록 보장한다. 플래그는 다음 번 `luagate_scanner_reload()` 성공 시에만 `false`로 리셋된다.

3. **누적 leak 카운터 임곗값 초과 시 /health 503 전환**: `/health` 엔드포인트는 전체 worker의 `ffi:timeout:leak:*` 카운터 합산을 확인한다. 합산 값이 임곗값(10)을 초과하면 503을 반환하여 외부 오케스트레이터(로드밸런서, Kubernetes 등)가 해당 인스턴스를 서비스에서 제거하고 프로세스를 재시작하도록 유도한다.

```
[Reload timeout 발생]
   │
   ├─ (1) shared dict: ffi:timeout:leak:<worker_id> += 1
   ├─ (2) worker-local: SCANNER_RELOAD_FAILED = true
   │
   ├─ 이후 luagate_scan_http() 호출 시:
   │   └─ SCANNER_RELOAD_FAILED == true → INTERNAL_ERROR(-4) → 403 deny
   │
   └─ /health 확인 시:
       └─ sum(ffi:timeout:leak:*) > 10 → 503
```

이 메커니즘은 단일 reload timeout으로는 `/health` 503이 발동하지 않으므로, 일시적 OS 스케줄링 지연에 의한 불필요한 재시작을 방지한다. 반복적 timeout이 누적되어야만 503으로 전환되며, 이는 worker 프로세스의 구조적 문제(메모리 부족, thread 고갈 등)를 나타내는 신호로 간주한다.

**Write lock 보유 시간 최소화:**

write lock은 Swap 단계(< 1ms)에서만 획득한다. Read/Parse/Compile은 lock 바깥에서 수행되므로, L2 hard timeout(1000ms)에 도달할 가능성은 극소화된다. L2 timeout이 발동하는 상황은 Swap 단계에서의 비정상적 지연(OS 스케줄링 극단 사례)에 한정된다.

**단계별 budget 분배:**

| 단계 | 예상 소요 | 비고 |
|------|----------|------|
| Read | < 1ms | 파일 I/O (수 KB) |
| Parse | < 5ms | YAML 파싱 |
| Compile | < 90ms | 정규식 컴파일 (50개 패턴 기준) |
| Swap | < 1ms | pointer swap |
| Verify | < 1ms | shared dict write |

정규식 컴파일이 전체 budget의 대부분을 차지한다. write lock은 Swap 단계에서만 획득하므로, Read/Parse/Compile 동안 스캔 요청은 정상 처리된다.

> **핵심**: write lock 보유 시간을 최소화하기 위해 새 `Scanner` 인스턴스를 lock 바깥에서 완전히 구성한 뒤, Swap 단계에서만 lock을 획득하여 교체한다.

### 8. YAML 패턴 파일 스키마

```yaml
# conf/scanner-patterns/sqli.yaml
patterns:
  - threat_type: sqli
    rule_name: sqli_union_select
    pattern: "(?i)(union\\s+(all\\s+)?select)"
    score: 0.9
  - threat_type: sqli
    rule_name: sqli_or_always_true
    pattern: "(?i)(or\\s+1\\s*=\\s*1|and\\s+1\\s*=\\s*1)"
    score: 0.8
```

**필수 필드:**

| 필드 | 타입 | 제약 |
|------|------|------|
| `threat_type` | string | security-scanner.md §2의 enum 값 |
| `rule_name` | string | `[a-z0-9_]+`, 64자 이내, 전체 고유 |
| `pattern` | string | 유효한 Rust `regex::Regex` 문법 |
| `score` | float | 0.0 ~ 1.0 |

**검증 규칙:**

- 중복 `rule_name` 감지 → reload 거부
- `pattern`이 `Regex::new()`로 컴파일 실패 → reload 거부
- `score` 범위 벗어남 → reload 거부

---

## File Structure

```
src/scanner/src/lib.rs          # RwLock 변경, luagate_scanner_reload() 추가, YAML 로더 구현
lua/luagate/scanner/ffi.lua     # reload() 함수 바인딩 추가
lua/luagate/scanner/worker.lua  # init_worker_by_lua 타이머: cross-worker 동기화 (§5)
lua/luagate/admin/scanner.lua   # Admin API 핸들러 (GET/PUT/POST), PUT rollback 포함
conf/scanner-patterns/          # YAML 패턴 파일 디렉토리
    sqli.yaml
    xss.yaml
    path-traversal.yaml
    cmd-injection.yaml
    custom.yaml
```

---

## Consequences

### 긍정적

- **무중단 패턴 갱신**: Nginx 재시작 없이 새 OWASP 패턴 또는 커스텀 규칙 적용
- **read contention 제거**: `Mutex` → `RwLock` 변경으로 worker 내부에서 reload가 없는 정상 상태의 scan 호출이 contention-free로 read lock 획득
- **실패 안전성**: reload 실패 시 LKG 패턴 유지 — 보안 스캔 중단 없음
- **버전 추적**: shared dict 메타데이터로 현재 패턴 버전 확인 가능
- **정책 관리와 일관된 UX**: Admin API 패턴이 `/api/v1/policies`와 동일
- **Cross-worker 동기화**: shared dict version polling으로 모든 worker가 최대 1초 이내에 새 패턴 적용
- **PUT rollback 안전성**: 검증 후 rename, reload 실패 시 `.bak`에서 복원하여 canonical source 일관성 보장

### 부정적

- **reload 중 fail-closed**: write lock 보유 시간(< 1ms) 동안 도착하는 요청은 deny 처리. 정상 트래픽 10,000 req/s 기준 최대 10건 영향
- **Cross-worker 전파 지연**: 타이머 주기(1초) 동안 일부 worker는 구 패턴을 사용. 보안상 허용 가능한 수준 (정책 reload와 동일 패턴)
- **YAML 파서 의존성**: Rust 바이너리에 YAML 파싱 라이브러리(`serde_yaml`) 추가 필요
- **새 FFI 함수**: `luagate_scanner_reload()` 추가로 ABI 표면 확대
- **새 shared dict zone**: `luagate_scanner_patterns` zone 추가로 공유 메모리 사용량 증가 (1MB 이내)

### 리스크

| 리스크 | 완화 |
|--------|------|
| 정규식 catastrophic backtracking (새 패턴) | ADR-009 L2 watchdog 100ms 강제 중단. 패턴 업로드 시 compile 단계에서 기본 입력으로 사전 검증 |
| YAML 파싱 중 메모리 폭발 (악의적 입력) | 패턴 파일 크기 제한 (1MB). `serde_yaml` 기본 depth limit |
| write lock 보유 중 panic | `panic=abort` 설정 (ADR-001). worker abort 후 master가 재시작 |
| 패턴 파일 디스크 장애 | LKG 유지 (메모리 내 Scanner 인스턴스 유지). 디스크 복구 후 reload |
| 동시 reload 경합 | shared dict lock으로 직렬화. 5초 TTL 자동 해제 |

---

## Implementation Plan

1. **Rust 변경**: `Mutex<Option<Scanner>>` → `RwLock<Option<Scanner>>` 마이그레이션. `luagate_scan_http()`에서 `try_read()` 사용
2. **YAML 로더 구현**: `serde_yaml` 의존성 추가. `conf/scanner-patterns/*.yaml` 파일 읽기 + 파싱 + 정규식 컴파일
3. **`luagate_scanner_reload()` 구현**: 5단계 파이프라인 (Read → Parse → Compile → Swap → Verify)
4. **Lua FFI 바인딩 업데이트**: `ffi.lua`에 `reload()` 함수 추가
5. **Admin API 핸들러**: `lua/luagate/admin/scanner.lua` — GET/PUT/POST 엔드포인트. PUT은 검증 후 rename + .bak rollback 패턴 적용
6. **Cross-worker 동기화**: `init_worker_by_lua`에서 `ngx.timer.every(1)` 타이머 등록. shared dict `scanner:active_version` polling + worker 로컬 `luagate_scanner_reload()` 호출
7. **shared dict zone 추가**: `nginx.conf`에 `lua_shared_dict luagate_scanner_patterns 1m;` 선언
8. **기본 YAML 패턴 파일 생성**: 현재 하드코딩 패턴을 YAML로 추출하여 `conf/scanner-patterns/` 배치

---

## 관련 문서

- [ADR-003](./ADR-003-policy-storage-hot-reload.md) — 정책 Hot Reload 7단계 (참고 모델)
- [ADR-009](./ADR-009-ffi-timeout-enforcement.md) — FFI 타임아웃 강제 (reload budget)
- [ADR-001](./ADR-001-execution-shared-state-model.md) — FFI 호출 모델, startup-fatal 계약
- [spec/security-scanner.md](../../spec/security-scanner.md) — 보안 스캐너 스펙
- [spec/rust-ffi-modules.md](../../spec/rust-ffi-modules.md) — FFI ABI 규격
