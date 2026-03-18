# ADR-009: FFI .so 함수 타임아웃 강제 메커니즘

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-18 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-156](https://linear.app/dongwon/issue/DON-156) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md), [ADR-003](./ADR-003-policy-storage-hot-reload.md) |
| **Resolves** | ADR-001 "향후 고려" `.so` 함수 타임아웃 강제; `architecture.md` §10 TODO; `http-pipeline.md` §11 TODO |

---

## Status

**Accepted** -- ADR-001 §1.2에서 "별도 ADR에서 결정"으로 미뤄둔 FFI 타임아웃 강제 전략을 확정한다.

---

## Context

LuaGate의 모든 FFI 호출(scanner, decoder, stream)은 OpenResty worker의 이벤트 루프 내에서 **동기 블로킹** 호출로 실행된다(ADR-001 §1.1). 현재 방어 체계는 다음과 같다.

1. **Rust 내부 budget 검사**: `luagate_scanner.so`는 5ms budget을 초과하면 `LUAGATE_BUDGET_EXCEEDED(-3)`을 반환한다. `luagate_decoder.so`는 0.5ms 내 완료를 목표로 한다.
2. **pcall 래핑**: Lua 레벨 예외는 `pcall`로 포착한다.
3. **panic=abort**: Rust panic 시 worker를 즉시 abort하고 Nginx master가 재시작한다.

**미해결 위험**: Rust 함수가 정상적으로 반환하지 않는 경우(무한루프, 데드락, 정규식 catastrophic backtracking 등)에 대한 **외부 강제 중단** 메커니즘이 없다. 이 상황에서는 budget 검사 코드 자체가 실행되지 않으므로, 해당 worker가 영구적으로 블로킹되어 이벤트 루프 전체가 중단된다.

### 위험 시나리오

| 시나리오 | 영향 | 현재 방어 |
|----------|------|-----------|
| 정규식 catastrophic backtracking | worker 단일 코어 100% 점유, 이벤트 루프 중단 | budget 검사가 정규식 내부에서 실행 불가 |
| 패턴 파일 파싱 중 무한루프 (init 단계) | 서버 시작 실패 (init_by_lua 블로킹) | 없음 |
| Rust unsafe 코드의 데드락 | worker 영구 행 | 없음 |
| 악의적 입력으로 인한 O(n^2+) 알고리즘 트리거 | worker 수십 초 블로킹 | budget 검사가 루프 카운터 기반이면 우회 가능 |
| hot reload 시 radix_build hang | worker 블로킹, stream 요청 처리 불가 | 없음 |

---

## Decision

### 3계층 방어 전략 (Defence-in-Depth) 채택

FFI 타임아웃을 단일 메커니즘이 아닌 3개 계층으로 방어한다.

```
Layer 1: Rust 내부 budget guard (기존)
  ↓ 실패 시
Layer 2: Rust 전용 watchdog thread (신규)
  ↓ 실패 시
Layer 3: Nginx worker_shutdown_timeout + 모니터링 (신규)
```

### Layer 1: Rust 내부 budget guard (기존 유지 + 강화)

현행 `LUAGATE_BUDGET_EXCEEDED` 메커니즘을 유지하되, 다음을 강화한다.

**강화 사항:**

1. **시간 기반 budget 검사 의무화**: 루프 카운터가 아닌 `Instant::now()` 기반 경과 시간 검사로 통일한다. 정규식 엔진 콜백 또는 사용자 정의 함수 내부에서도 시간 검사가 가능하도록 한다.
2. **정규식 엔진 size limit**: `regex` 크레이트의 `size_limit`, `dfa_size_limit` 설정을 명시적으로 제한하여 catastrophic backtracking을 구조적으로 방지한다.
3. **budget 임곗값 규격화**:

| 모듈 | budget 임곗값 | 비고 |
|------|--------------|------|
| `luagate_scanner.so` | 5ms | 기존 유지 |
| `luagate_decoder.so` | 2ms | 기존 0.5ms 목표 → 2ms hard limit 신설 |
| `luagate_stream.so` (detect/sni) | 1ms | 신규 |
| `luagate_stream.so` (radix_build) | 100ms | hot reload 시에도 호출됨 (§ radix_build hot reload 참조) |

### Layer 2: Rust 전용 watchdog thread (신규 -- 핵심 결정)

각 FFI 함수 호출 시 Rust 내부에서 watchdog thread를 활용하여 하드 타임아웃을 강제한다.

#### 메모리 소유권 계약 (ABI 안전성)

Layer 2는 작업 thread에서 FFI 로직을 실행하므로, timeout 후 detach된 thread가 caller-owned 메모리에 접근하는 **use-after-return** 위험이 존재한다. 이를 방지하기 위해 **copy-in/copy-out** 전략을 채택한다.

**원칙:**
- 작업 thread는 caller-owned 버퍼에 **직접 읽기/쓰기하지 않는다**.
- `with_timeout` 진입 시 입력 데이터를 Rust-owned `Vec<u8>`로 복사(copy-in)한다.
- 작업 thread 내부에서 Rust-owned 출력 버퍼에 결과를 기록한다.
- 정상 완료 시 결과를 caller-owned 출력 버퍼에 복사(copy-out)한다.
- timeout 발생 시 caller-owned 버퍼는 한 번도 접근되지 않았으므로 안전하다.

**메커니즘:**

```rust
// src/common/watchdog.rs (공통 라이브러리)

/// 입력/출력을 Rust-owned 버퍼로 격리하여 ABI 안전성을 보장하는 watchdog.
/// F는 Rust-owned 입력을 받아 Rust-owned 출력을 반환한다.
/// caller-owned 포인터는 closure에 캡처되지 않는다.
pub fn with_timeout<F, R>(timeout: Duration, f: F) -> Result<R, TimeoutError>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::channel();

    // 작업 스레드 spawn — closure는 Rust-owned 데이터만 캡처
    let handle = std::thread::spawn(move || {
        let result = f();
        let _ = tx.send(result);
    });

    // watchdog: 타임아웃 대기
    match rx.recv_timeout(timeout) {
        Ok(result) => {
            // 정상 완료: thread join으로 자원 회수
            let _ = handle.join();
            Ok(result)
        }
        Err(_) => {
            // 타임아웃 초과: 스레드를 detach하고 에러 반환
            // NOTE: std::thread는 강제 종료 불가 -- detach 후 자연 종료 대기
            drop(handle);
            Err(TimeoutError::Exceeded(timeout))
        }
    }
}
```

**FFI export 함수의 copy-in/copy-out 패턴:**

```rust
// 예시: luagate_scan_http의 watchdog 적용
#[no_mangle]
pub extern "C" fn luagate_scan_http(
    path_raw: *const c_char, path_raw_len: usize,
    // ... 기타 caller-owned 입력/출력 포인터 ...
    threat_type_out: *mut c_char, threat_type_cap: usize, threat_type_len: *mut usize,
    // ...
) -> c_int {
    // 1. Copy-in: caller-owned 입력 → Rust Vec<u8>
    let path_raw_owned = unsafe {
        std::slice::from_raw_parts(path_raw as *const u8, path_raw_len)
    }.to_vec();
    // ... 나머지 입력도 동일하게 복사 ...

    // 2. Watchdog 실행 — closure는 Rust-owned 데이터만 캡처
    let result = watchdog::with_timeout(Duration::from_millis(50), move || {
        scan_http_impl(&path_raw_owned /*, ... */)
    });

    // 3. Copy-out: 정상 완료 시만 caller-owned 출력 버퍼에 기록
    match result {
        Ok(scan_result) => {
            // scan_result → caller-owned 출력 버퍼 복사
            unsafe { copy_to_caller_buf(scan_result.threat_type, threat_type_out, threat_type_cap, threat_type_len) };
            LUAGATE_OK
        }
        Err(TimeoutError::Exceeded(_)) => LUAGATE_TIMEOUT,
    }
}
```

**Radix Tree 소유권 처리 (`radix_build`):**

`luagate_radix_build`는 opaque pointer(`luagate_radix_t *`)를 반환하는 예외적 API이다. timeout 시 Rust-owned tree가 작업 thread 내부에 갇히므로, 다음 규칙을 적용한다.

1. 작업 thread 내부에서 `Box::new(RadixTree)`로 tree를 생성한다.
2. 정상 완료 시: `Box::into_raw()` → caller의 `tree_out`에 기록 (copy-out).
3. **timeout 시**: 작업 thread의 closure가 `Box<RadixTree>` 소유권을 갖고 있으므로, thread 종료 시 `Drop`이 실행되어 자동 해제된다. thread가 hang되어 종료하지 못하는 경우, worker 프로세스 종료 시 OS가 회수한다.
4. **send 실패 시**(channel이 닫힌 경우): closure 내에서 생성된 tree는 closure 스코프 종료 시 `Drop`으로 해제된다. 별도 free 경로 불필요.

**동작 원리:**

1. FFI export 함수 진입 시 caller-owned 입력을 Rust-owned 버퍼로 복사한다 (copy-in).
2. 실제 로직을 별도 thread에서 Rust-owned 데이터로 실행한다.
3. 호출자 thread(= worker 이벤트 루프)는 `recv_timeout`으로 hard timeout만큼 대기한다.
4. 정상 완료 시 결과를 caller-owned 출력 버퍼에 복사한다 (copy-out).
5. 타임아웃 초과 시 작업 thread를 detach하고 즉시 에러 코드를 반환한다. Caller-owned 버퍼는 미접촉 상태이므로 안전하다.
6. Lua wrapper는 `LUAGATE_TIMEOUT(-5)` 코드를 받아 fail-closed 처리한다.

**Hard timeout 값:**

| 모듈 | hard timeout | Layer 1 budget의 몇 배 |
|------|-------------|----------------------|
| `luagate_scanner.so` | 50ms | 10x |
| `luagate_decoder.so` | 20ms | 10x |
| `luagate_stream.so` (detect/sni) | 10ms | 10x |
| `luagate_stream.so` (radix_build) | 1000ms | 10x |

> **Hard timeout = Layer 1 budget의 10배**: Layer 1이 정상 동작하면 Layer 2에 도달하지 않는다. Layer 2는 Layer 1이 실패한 비정상 상황에서만 발동하는 안전망이다.

**detach된 thread 처리 및 회수 전략:**

- Detach된 thread는 OS가 관리한다. 해당 thread가 결국 정상 종료하면 자원이 회수된다.
- thread가 무한 루프에 빠진 경우, worker 프로세스 종료 시 OS가 회수한다.
- **per-worker leak 카운터**: `luagate_metrics` shared dict에 `ffi:timeout:leak:<worker_id>` 키로 worker별 leak 카운터를 관리한다 (AGENTS.md `ngx.worker.id()` 불변식 준수).
- **worker 자발적 종료 불가 -- 외부 health check 의존**: `ngx.exit()`는 요청 처리 컨텍스트(rewrite, access, content, preread)에서만 유효하며, `ngx.timer.at` 콜백 컨텍스트에서는 worker 프로세스 종료를 유발하지 않는다. 따라서 worker 내부에서 자발적으로 프로세스를 종료하는 메커니즘은 존재하지 않는다. 대신 다음 전략으로 leak된 thread의 누적을 감지하고 외부에서 worker를 교체한다.
  1. `GET /health` 응답에 per-worker `ffi_watchdog_leak_count`를 포함한다.
  2. leak 카운터가 임곗값(기본 10)을 초과하면 `/health` 응답을 `503 unhealthy`로 전환한다 (`"reason": "ffi_thread_leak_threshold_exceeded"`).
  3. 외부 오케스트레이터(Kubernetes liveness probe, systemd watchdog 등)가 503을 감지하여 프로세스를 재시작한다.
  4. 이벤트 루프 자체가 hang되어 `/health`에 응답하지 못하는 극단적 상황에서는, liveness probe의 timeout 실패로 동일하게 프로세스 재시작이 트리거된다.

> **`ngx.timer.at` + `ngx.exit()` 조합이 동작하지 않는 이유**: `ngx.exit()`는 OpenResty의 요청 처리 phase(rewrite, access, content, preread)에서만 현재 요청을 종료하는 API이다. Timer 콜백은 요청 컨텍스트가 아닌 독립적인 "light thread" 컨텍스트에서 실행되므로, `ngx.exit()`를 호출해도 worker 프로세스 종료가 발생하지 않는다. OpenResty/Nginx에는 worker가 스스로 프로세스를 종료하는 공개 API가 존재하지 않으며, 이는 Nginx master-worker 아키텍처의 설계 의도(master만이 worker 수명을 관리)에 부합한다.

### Layer 3: Nginx worker_shutdown_timeout + 모니터링 (신규)

Layer 2의 watchdog가 실패하거나, FFI 호출 자체가 watchdog 래핑 이전에 행(hang)하는 극단적 상황을 대비한다.

**Nginx 설정:**

```nginx
# nginx.conf
worker_shutdown_timeout 30s;
```

> **`worker_shutdown_timeout`의 동작 범위**: 이 설정은 HUP/QUIT 시그널에 의한 graceful shutdown 과정에서만 의미를 가진다. Steady-state에서 hang된 worker를 자동으로 종료하는 메커니즘이 **아니다**. 따라서 Layer 3는 운영자가 `kill -HUP`로 reload를 트리거하거나, Kubernetes/systemd 등 외부 오케스트레이터가 health check 실패를 감지하여 프로세스를 재시작하는 시나리오에서 보조적으로 동작한다.

**외부 health check 연동 (steady-state 방어):**

Steady-state에서 hang된 detached thread 누적을 감지하기 위해 외부 health check를 활용한다.

1. `GET /health` 응답에 per-worker `ffi_watchdog_leak_count` 필드를 포함한다.
2. 외부 오케스트레이터(Kubernetes liveness probe, systemd watchdog 등)가 health check 실패 또는 leak count 임곗값 초과를 감지하면 프로세스를 재시작한다.
3. 이로써 steady-state에서도 hang된 thread가 CPU/TID/stack 메모리를 무한정 잠식하는 것을 방지한다.

**모니터링:**

1. Prometheus 메트릭에 `luagate_ffi_timeout_total{module="scanner|decoder|stream", layer="1|2", worker="<id>"}` 카운터를 노출한다. `worker` 라벨로 per-worker 식별이 가능하다.
2. `layer=2` 카운터가 1 이상이면 alerting 대상이다 (Layer 1 budget guard 우회를 의미).
3. `luagate_ffi_thread_leak_total{worker="<id>"}` 게이지로 per-worker 누적 leak 수를 노출한다.
4. `GET /health` 엔드포인트에 `ffi_watchdog_timeouts` 및 per-worker `ffi_watchdog_leak_count` 필드를 추가하여 최근 타임아웃 발생 여부를 보고한다.

### radix_build hot reload 시 timeout 동작 (ADR-003 연동)

`luagate_stream.so`의 `radix_build`는 init 단계 1회성 호출이 **아니다**. `c-ffi-modules.md` §6.4 및 `stream-pipeline.md` §2.2에 따라, `active_version` 변경 시 각 worker가 독립적으로 radix tree를 rebuild한다. 따라서 hot reload 이후 첫 stream 요청에서 `radix_build`가 호출될 수 있으며, 이때 Layer 2 hard timeout(1000ms)이 적용된다.

**rebuild timeout 시 동작 정의:**

| 단계 | 동작 |
|------|------|
| radix_build 정상 완료 | new tree로 교체 (c-ffi-modules.md §6.4 atomic swap) |
| radix_build Layer 1 timeout (100ms) | `LUAGATE_BUDGET_EXCEEDED(-3)` 반환 |
| radix_build Layer 2 timeout (1000ms) | `LUAGATE_TIMEOUT(-5)` 반환 |
| timeout 후 fallback | **old tree(LKG) 유지**: 현재 worker의 module-level upvalue에 저장된 이전 radix tree 포인터를 계속 사용. `_cached_stream_version`을 갱신하지 않으므로 다음 요청에서 rebuild를 재시도한다. |
| 반복 timeout | 매 요청마다 rebuild를 재시도하되, 실패가 연속되면 per-worker leak 카운터가 증가하여 `/health` 503 전환 → 외부 오케스트레이터가 프로세스 재시작 |
| cold start (LKG 없음) | init 단계에서 radix_build 실패 시 서버 시작 거부 (fail-closed). `worker_shutdown_timeout` 미적용 (init 단계는 graceful shutdown 대상이 아님) |

> **설계 근거**: hot reload 시 rebuild timeout은 일시적 부하(큰 CIDR 목록) 또는 비정상 입력이 원인일 수 있다. Old tree(LKG)를 유지하면 stream 정책 평가는 이전 버전 기준으로 계속 동작하므로 서비스 가용성이 보장된다. 이는 ADR-003의 "commit 실패 시 롤백 불필요 — 기존 active pointer 유지" 원칙과 일관된다.

### 스코프: 모든 FFI 모듈에 적용

| 모듈 | Layer 1 (budget) | Layer 2 (watchdog) | Layer 3 (shutdown) |
|------|-----------------|-------------------|-------------------|
| `luagate_scanner.so` | 기존 강화 | 적용 | 적용 |
| `luagate_decoder.so` | 신규 추가 | 적용 | 적용 |
| `luagate_stream.so` | 신규 추가 | 적용 | 적용 |

**근거**: 모든 `.so` 모듈이 동일한 위험(무한루프, 데드락)에 노출되어 있으므로, 특정 모듈만 제외할 이유가 없다. 공통 `watchdog.rs` 모듈로 일관된 적용이 가능하다.

### 실패 시 처리: 해당 요청만 fail-closed

타임아웃 발생 시 **해당 요청만 deny(fail-closed)** 처리하고, worker는 계속 동작한다.

| 계층 | 실패 시 동작 | worker 영향 |
|------|------------|------------|
| Layer 1 | `LUAGATE_BUDGET_EXCEEDED(-3)` 반환 → deny | 없음 (정상 반환) |
| Layer 2 | `LUAGATE_TIMEOUT(-5)` 반환 → deny + per-worker leak 카운터 증가 | thread leak 누적 시 `/health` 503 전환 → 외부 오케스트레이터가 프로세스 재시작 |
| Layer 3 | 외부 오케스트레이터가 health check 기반 프로세스 재시작 | worker 교체 |

> **worker 즉시 재시작을 기본으로 하지 않는 이유**: Layer 2 타임아웃은 단일 요청의 비정상 입력이 원인일 가능성이 높다. Worker 전체를 재시작하면 해당 worker가 처리 중인 다른 정상 요청까지 영향받는다. Per-worker thread leak 카운터로 누적 상태를 추적하여, 반복 발생 시에만 worker를 교체한다.

### 새 에러 코드

| 코드 | 상수 | 의미 |
|------|------|------|
| `-5` | `LUAGATE_TIMEOUT` | Layer 2 watchdog 타임아웃 (외부 강제) |

기존 에러 코드(`-3 BUDGET_EXCEEDED`)는 Layer 1(내부 자발적 종료)과 구분하여 유지한다.

### Lua wrapper 변경

```lua
-- 새 에러 코드 상수 추가
local LUAGATE_TIMEOUT = -5

-- 기존 에러 처리에 추가
if rc == LUAGATE_BUDGET_EXCEEDED or rc == LUAGATE_TIMEOUT
   or rc == LUAGATE_INTERNAL_ERROR then
    -- fail-closed
    if rc == LUAGATE_TIMEOUT then
        ngx.log(ngx.ERR, "FFI hard timeout exceeded (Layer 2 watchdog)")
        -- per-worker thread leak 카운터 증가
        local dict = ngx.shared.luagate_metrics
        if dict then
            local wid = ngx.worker.id()
            dict:incr("ffi:timeout:leak:" .. wid, 1, 0)
        end
    end
    return nil, "ffi_fail:" .. rc
end
```

---

## Alternatives Considered

### Alternative A: SIGALRM 기반 타이머

**설명**: POSIX `setitimer(ITIMER_REAL)` / `SIGALRM`으로 프로세스 레벨 타이머를 설정하고, 시그널 핸들러에서 `longjmp`로 FFI 호출을 탈출한다.

**기각 이유:**

1. **OpenResty 이벤트 루프 파괴**: Nginx는 자체 시그널 핸들링(SIGCHLD, SIGHUP, SIGUSR1 등)을 사용한다. SIGALRM 핸들러가 Nginx의 시그널 처리와 충돌하여 워커 불안정을 초래한다.
2. **프로세스 단위 타이머**: `setitimer`는 프로세스 전체에 하나만 설정 가능하다. 동시에 여러 FFI 호출이 진행되는 시나리오(향후 코루틴 기반 확장 등)에서 충돌한다.
3. **longjmp + FFI = UB**: Rust 스택 프레임을 넘어가는 `longjmp`는 미정의 동작(Undefined Behavior)을 유발한다. Rust의 `Drop` 구현이 실행되지 않아 자원 누수와 상태 불일치가 발생한다.
4. **LuaJIT 호환성**: LuaJIT의 FFI 호출 중 시그널을 받으면 trace abort가 발생하여 성능 퇴행이 나타난다.

### Alternative B: pthread_cancel

**설명**: FFI 호출 전 `pthread_create`로 작업 스레드를 생성하고, 타임아웃 시 `pthread_cancel`로 강제 종료한다.

**기각 이유:**

1. **Cancellation safety**: `pthread_cancel`은 cancellation point에서만 동작한다. CPU-bound 연산(정규식 매칭)에는 cancellation point가 없어 실질적으로 동작하지 않는다. `pthread_cancel` + `PTHREAD_CANCEL_ASYNCHRONOUS`는 임의 지점에서 스레드를 종료시키므로 뮤텍스 누수, 메모리 누수를 유발한다.
2. **Rust와 비호환**: Rust 표준 라이브러리는 `pthread_cancel`을 지원하지 않으며, Rust 코드가 cancel된 후의 상태는 완전히 미정의이다.
3. **glibc 의존성**: `pthread_cancel`의 세부 동작은 glibc 버전에 따라 다르며, musl libc(Alpine 기반 컨테이너)에서는 다르게 동작한다.

### Alternative C: 별도 watchdog 프로세스 (fork 기반)

**설명**: FFI 호출을 자식 프로세스(`fork()`)에서 실행하고, 부모 프로세스가 `waitpid` + `alarm`으로 타임아웃을 감시한다. 타임아웃 시 `SIGKILL`로 강제 종료한다.

**기각 이유:**

1. **성능 오버헤드**: `fork()`는 CoW 기반이지만, 프로세스 생성/파괴 비용이 요청당 수백 us~수 ms로 FFI 호출 자체(< 5ms)에 비해 과도하다.
2. **IPC 복잡도**: 자식 프로세스에서 부모로 결과를 전달하려면 pipe/shared memory가 필요하다. ADR-001의 "IPC 없음" 원칙에 위배된다.
3. **OpenResty worker 모델 침해**: Nginx worker 내부에서 `fork()`하면 master-worker 관계가 복잡해지며, Nginx의 프로세스 관리 로직과 충돌할 수 있다.
4. **shared dict 접근 불가**: 자식 프로세스는 `ngx.shared.DICT`에 접근할 수 없다(Nginx API가 worker 프로세스 전용).

### Alternative D: Watchdog thread (채택)

위 대안들의 단점을 회피하면서 실질적인 타임아웃 강제가 가능한 방안이다. Decision 섹션에 상세 기술.

**채택 이유:**

1. **OpenResty 이벤트 루프 비침해**: Rust 내부 thread이므로 Nginx 시그널/이벤트 루프와 무관하다.
2. **프로세스 모델 유지**: ADR-001의 "동일 worker 내 동기 호출" 원칙을 유지한다. Worker 프로세스 외부에 새 프로세스를 생성하지 않는다.
3. **구현 단순성**: `std::thread::spawn` + `mpsc::channel` + `recv_timeout`으로 구현 가능하다.
4. **강제 종료 불가 한계 인정**: `std::thread`는 강제 종료할 수 없으나, detach + per-worker leak 카운터 + `/health` 503 전환 + Layer 3(외부 오케스트레이터 health check)으로 보완한다.
5. **ABI 안전성**: copy-in/copy-out 전략으로 caller-owned 버퍼와 작업 thread 간 소유권 충돌을 원천 차단한다.

---

## Consequences

### 긍정적 결과

- **무한루프/데드락 방어**: Layer 1이 실패해도 Layer 2가 50ms 이내에 worker 이벤트 루프를 해방시켜 다른 요청 처리를 계속할 수 있다.
- **worker 안정성**: 단일 비정상 요청이 worker 전체를 중단시키지 않는다. Per-worker thread leak 카운터로 누적 상태를 추적하고, 임곗값 초과 시 `/health` 503 전환을 통해 외부 오케스트레이터가 프로세스를 재시작한다.
- **관측 가능성**: 3계층 각각에서 per-worker 메트릭을 수집하므로, 타임아웃 발생 원인(Layer 1 vs Layer 2)과 영향 범위(어느 worker)를 구분하여 진단할 수 있다.
- **점진적 적용**: 기존 코드(Layer 1)를 유지하면서 Layer 2/3을 추가하는 방식이므로, 기존 동작에 대한 regression 위험이 낮다.
- **ABI 안전성**: copy-in/copy-out으로 caller-owned 버퍼와 작업 thread 간 use-after-return 위험을 원천 차단한다.
- **hot reload 안전성**: radix_build timeout 시 old tree(LKG) 유지로 stream 서비스 가용성을 보장한다.

### 부정적 결과

- **copy-in/copy-out 오버헤드**: 입력 데이터를 Rust-owned 버퍼로 복사하는 비용이 추가된다. 아래 성능 분석 섹션에서 상세 평가.
- **thread spawn 오버헤드**: 매 FFI 호출마다 thread를 spawn하면 추가 지연이 발생한다. 아래 성능 분석 섹션에서 상세 평가.
- **thread leak 가능성**: Detach된 thread가 OS 자원(스택 메모리 8MB 기본 스택, TID)을 점유한다. Per-worker leak 카운터로 감시하되, 극단적 공격 시나리오에서 OOM 가능성이 있다.
- **Rust 코드 복잡도 증가**: 모든 FFI export 함수에 watchdog wrapper + copy-in/copy-out를 적용해야 하므로, Rust 코드 구조가 복잡해진다. 공통 매크로/제네릭으로 boilerplate를 최소화해야 한다.
- **테스트 난이도**: 무한루프를 의도적으로 유발하는 테스트 시나리오 구성이 필요하다.

### 성능 분석

#### 측정 환경 요구사항

Phase 2 구현 시 다음 환경에서 벤치마크를 수행하고 결과를 이 ADR에 추가한다.

| 항목 | 값 |
|------|-----|
| CPU | x86_64, 4+ cores (CI runner 또는 개발 머신) |
| OS | Linux 6.x |
| Rust toolchain | stable, release 빌드 (LTO + codegen-units=1) |
| 측정 도구 | `criterion` crate (Rust micro-benchmark) |
| 반복 횟수 | 최소 1000회, p50/p95/p99 보고 |

#### 요청당 FFI 호출 수 모델

| 파이프라인 | 호출 경로 | 호출 수/요청 |
|-----------|----------|------------|
| HTTP | `normalize_path` → `normalize_query` → `scan_http` | 3회 |
| HTTP (decoder 2회) | `normalize_path` + retry(BUFFER_TOO_SMALL) → `normalize_query` → `scan_http` | 4회 (최악) |
| Stream | `detect_protocol` → `extract_sni` → `radix_lookup` | 2~3회 |
| Stream (hot reload) | `radix_build` + `detect_protocol` → `extract_sni` → `radix_lookup` | 3~4회 |

> `radix_lookup`은 순수 읽기 연산(tree 포인터 + IP 문자열)이므로 watchdog 오버헤드가 가장 낮다.

#### 오버헤드 항목별 추정치 및 허용 기준

| 오버헤드 항목 | 추정치 (사전) | p99 허용치 | 초과 시 대응 |
|-------------|-------------|----------|------------|
| `std::thread::spawn` | 5~30 us | 50 us | thread pool 전환 (아래 임계값 참조) |
| `mpsc::channel` 생성 + send/recv | 1~5 us | 10 us | 무시 가능 |
| copy-in (입력 복사) | 0.1~2 us (path: ~2KB, query: ~4KB) | 5 us | 대형 body 검사 시 재평가 (MVP에서 body=0) |
| copy-out (출력 복사) | 0.1~1 us (threat_type: ~64B, rule_name: ~128B) | 2 us | 무시 가능 |
| **요청당 총 누적** (HTTP 3회) | **18~114 us** | **200 us** | thread pool 전환 검토 |
| **요청당 총 누적** (HTTP 4회, 최악) | **24~152 us** | **260 us** | thread pool 전환 검토 |

#### Thread pool 전환 임계값

다음 조건 중 하나라도 충족되면 `std::thread::spawn`에서 thread pool로 전환한다.

1. **p99 요청당 watchdog 오버헤드 > 200 us** (HTTP 3회 호출 기준)
2. **p95 단일 호출 thread spawn > 50 us**
3. **초당 요청 수 > 10,000 RPS** 환경에서 watchdog 오버헤드가 총 요청 latency의 5% 이상

thread pool 후보: `crossbeam` scoped thread pool 또는 Rust `std::thread::scope` (1.63+). `rayon`은 work-stealing 오버헤드로 단일 작업 디스패치에 비효율적이므로 비채택.

#### decoder 2회 호출 경로 누적 비용

`LUAGATE_BUFFER_TOO_SMALL` 재시도 시 watchdog가 2번 실행된다. 최악 케이스에서 HTTP 요청당 4회 watchdog 호출(normalize_path x2 + normalize_query + scan_http)이 발생하며, 추정 누적 오버헤드는 24~152 us이다. 이는 scanner의 5ms budget 대비 3% 이하이므로 허용 범위 내이나, Phase 2 벤치마크에서 실측하여 확인한다.

### 향후 고려

- **thread pool 전환**: 위 임계값 기준으로 벤치마크 결과에 따라 전환 결정. 초기 구현은 단순 `std::thread::spawn`으로 시작한다.
- **regex 엔진 교체**: `regex` 크레이트의 `size_limit`으로도 해결되지 않는 패턴이 발견되면, RE2 또는 Hyperscan 같은 보장된 선형 시간 엔진으로 교체를 검토한다.
- **LUAGATE_TIMEOUT 메트릭 알림 임곗값**: 운영 데이터 축적 후 적절한 알림 임곗값을 결정한다 (초기 기본값: Layer 2 타임아웃 1회 이상/분).
- **copy-in zero-copy 최적화**: 입력이 immutable인 경우(Lua 문자열은 GC 전까지 안정) `Arc<[u8]>` 공유로 복사를 생략할 수 있으나, Lua GC와의 수명 보장이 복잡하므로 초기에는 복사 방식 유지.

---

## 구현 계획 (Phase)

| Phase | 내용 | 예상 이슈 |
|-------|------|-----------|
| Phase 1 | Layer 1 강화: 시간 기반 budget, regex size_limit, decoder hard limit 추가 | DON-157 (후보) |
| Phase 2 | Layer 2: `src/common/watchdog.rs` 구현 + copy-in/copy-out + scanner/decoder/stream 적용 + 벤치마크 | DON-158 (후보) |
| Phase 3 | Layer 3: nginx.conf `worker_shutdown_timeout`, per-worker 메트릭/헬스체크 확장 | DON-159 (후보) |

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) -- 실행 모델, FFI 통합 방식, 실패 정책 (이 ADR이 해결하는 "향후 고려" 항목)
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) -- 정책 저장소 + Hot Reload (radix_build timeout 시 LKG 동작 연동)
- [spec/c-ffi-modules.md](../../spec/c-ffi-modules.md) -- FFI ABI 계약, 에러 코드 정의, timeout budget
- [spec/http-pipeline.md](../../spec/http-pipeline.md) -- HTTP 파이프라인 타임아웃 설정
- [spec/architecture.md](../../spec/architecture.md) -- 전체 아키텍처, 실패 정책 표
- [knowledge/c-ffi-guide.md](../../../.claude/knowledge/c-ffi-guide.md) -- FFI 메모리 관리 규칙
