# ADR-001: 실행/상태 공유 모델

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-13 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-85](https://linear.app/dongwon/issue/DON-85) |

---

## Status

**Accepted** — Phase 0-A에서 고정. 이후 변경 시 신규 ADR로 supersede.

---

## Context

LuaGate는 OpenResty(Nginx + LuaJIT) 위에서 동작하는 단일 인스턴스 API 게이트웨이다.
OpenResty는 master 프로세스가 N개의 worker 프로세스를 관리하며, 각 worker는 독립된 Lua VM을 갖는다.

이 구조에서 다음 문제를 해결해야 한다:

1. **상태 공유**: worker 간 정책 버전, 메트릭 카운터, 활성 연결 수를 공유해야 한다.
2. **C FFI 통합**: Rust/C로 작성된 고성능 모듈(스캐너, 파서)을 Lua에서 호출해야 한다.
3. **배포 단위**: 수평 확장 전략을 명확히 정의해야 한다.
4. **실패 정책**: worker 또는 C FFI 호출 실패 시 시스템 동작을 정의해야 한다.

---

## Decision

### §1.1 실행 모델

```
┌─────────────────────────────────────────────┐
│  OpenResty Process (단일 인스턴스)            │
│                                             │
│  ┌──────────┐   ngx.shared.DICT (mmap)     │
│  │  Master  │──────────────────────────┐   │
│  └──────────┘                          │   │
│       │         ┌──────────────────────▼─┐ │
│  ┌────▼────┐    │  policy_version (str)  │ │
│  │Worker 1 │◄──►│  req_counter   (num)  │ │
│  └─────────┘    │  blocked_counter(num) │ │
│  ┌─────────┐    │  active_conns  (num)  │ │
│  │Worker 2 │◄──►│  latency_buckets(arr) │ │
│  └─────────┘    └────────────────────────┘ │
│       ⋮                                     │
│  ┌─────────┐                               │
│  │Worker N │                               │
│  └────┬────┘                               │
│       │ dlopen / ffi.load                  │
│  ┌────▼─────────────────────────────────┐  │
│  │  C/Rust Shared Library (.so)         │  │
│  │  - luagate_scanner.so                │  │
│  │  - luagate_decoder.so                │  │
│  └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**결정 사항:**

1. **단일 인스턴스 배포 단위** — LuaGate는 1 OpenResty 인스턴스 = 1 배포 단위로 운용한다.
   수평 확장은 로드밸런서(L4/L7) 뒤에 복수 인스턴스를 두는 방식으로 달성한다.
   인스턴스 간 상태 동기화는 이 ADR의 범위 밖이다.

2. **worker 간 공유 메커니즘: `ngx.shared.DICT`** — Nginx의 mmap 기반 공유 딕셔너리를 사용한다.
   모든 worker가 동일한 메모리 페이지를 읽고 원자적으로 쓴다.
   LuaGate가 사용하는 shared dict 이름과 용도:

   | shared dict 이름       | 용도                              | 기본 크기 |
   |------------------------|-----------------------------------|-----------|
   | `luagate_policy`       | 정책 버전 해시, 직렬화된 정책 트리 | 10m       |
   | `luagate_metrics`      | 요청/차단 카운터, latency 버킷    | 5m        |
   | `luagate_connections`  | 활성 TCP 연결 수                   | 1m        |

#### Shared Dict 키 스키마

각 shared dict에서 사용하는 키 이름과 값 타입을 명시한다.

**`luagate_policy`:**

| 키 | 타입 | 설명 |
|----|------|------|
| `active_policy_version` | string | 현재 활성 정책 버전 SHA256 해시 |
| `policy:<version>:blob` | string (JSON) | 버전별 직렬화된 정책 트리 (예: `policy:a3f2c1d4:blob`) |
| `policy:<version>:meta` | string (JSON) | 버전별 메타데이터 (로드 시각, 규칙 수, 충돌 목록 등) |

**`luagate_metrics`:**

| 키 | 타입 | 설명 |
|----|------|------|
| `req:total` | number | 총 HTTP 요청 수 |
| `req:allowed` | number | 허용된 요청 수 |
| `req:blocked` | number | 차단된 요청 수 |
| `latency:bucket:<ms>` | number | latency 히스토그램 버킷 (예: `latency:bucket:1`, `latency:bucket:5`) |
| `policy_reload:success` | number | 정책 리로드 성공 횟수 |
| `policy_reload:failure` | number | 정책 리로드 실패 횟수 |

**`luagate_connections`:**

| 키 | 타입 | 설명 |
|----|------|------|
| `active_http` | number | 현재 활성 HTTP 연결 수 |
| `active_stream` | number | 현재 활성 TCP 스트림 연결 수 |

3. **C FFI 호출 모델** — Rust/C 공유 라이브러리(`.so`)는 `ffi.load()`로 로드하며,
   worker 프로세스 내부에서 동기 함수 호출로 실행된다.
   IPC(소켓, 파이프 등)를 사용하지 않는다.
   모든 FFI 호출은 동일 worker의 이벤트 루프 내에서 블로킹 없이 완료되어야 한다.

### §1.2 실패 정책

#### FFI 실패 분류

C FFI 실패는 두 가지 유형으로 엄격히 구분한다:

| 실패 유형 | 정의 | 탐지 방법 |
|-----------|------|-----------|
| **Lua 예외** | Rust 함수가 오류 코드/NULL 반환, 또는 LuaJIT가 pcall로 잡을 수 있는 예외 | `pcall()` 반환값 확인 |
| **Native crash** | Rust panic → abort, segfault, SIGABRT 등 worker 프로세스 자체 종료 | Nginx master가 worker 재시작으로 감지 |

| 실패 시나리오 | 유형 | 대응 |
|--------------|------|------|
| C FFI 함수 오류 코드/NULL 반환 | Lua 예외 | `pcall`로 포착 → fail-closed (deny) 후 오류 로그 기록 |
| Rust panic (panic = "abort") | Native crash | worker 프로세스 abort → Nginx master가 자동 재시작 |
| segfault / SIGABRT | Native crash | worker 프로세스 종료 → Nginx master가 자동 재시작 |
| shared dict 쓰기 실패 (용량 초과) | Lua 예외 | 메트릭 손실 허용, 오류 로그 기록, 요청은 계속 처리 |
| 정책 로드 실패 (파싱/검증) | Lua 예외 | last-known-good 정책 유지, 오류 로그 + 관리 API 상태에 반영 |
| worker 크래시 | Native crash | Nginx master가 worker 재시작, 다른 worker 영향 없음 |
| `.so` 로드 실패 | Native crash | 서버 시작 실패 (fatal), 배포 파이프라인에서 사전 검증 필요 |

#### Native Crash 완화책

- **Worker 재기동**: Nginx master는 worker 비정상 종료 시 자동으로 새 worker를 spawn한다. `worker_processes auto`와 `worker_rlimit_nofile` 설정으로 재시작 속도를 보장한다.
- **헬스체크**: 로드밸런서 헬스체크(`GET /health`)가 worker 재시작 완료를 감지하여 트래픽을 복구한다.
- **사전 self-test**: `init_by_lua`에서 각 `.so` 함수를 알려진 입력으로 호출하여 정상 동작을 검증한다. 실패 시 서버 시작을 중단한다.
- **panic = "abort" 결정**: Rust cdylib에서 `panic = "abort"` 설정은 의도적인 **crash-fail-fast** 전략이다. Rust panic을 C stack에서 unwinding하면 UB(Undefined Behavior)가 발생할 수 있으므로, worker를 즉시 abort하고 master가 재시작하는 것이 더 안전하다. `catch_unwind` 사용은 이 프로젝트에서 채택하지 않는다.

---

## Consequences

### 긍정적 결과

- **단순성**: IPC 없이 mmap 공유로 worker 간 상태 동기화, 구현 복잡도 낮음
- **성능**: C FFI 호출이 동일 프로세스 내 함수 호출이므로 오버헤드 최소
- **신뢰성**: Nginx master-worker 모델이 worker 재시작을 자동 처리

### 부정적 결과

- **단일 인스턴스 한계**: worker 간 공유는 가능하지만 인스턴스 간 상태 동기화 없음.
  메트릭/카운터는 인스턴스별 집계이므로, 전체 집계는 외부 시스템(Prometheus 등)이 담당
- **shared dict 용량**: mmap 크기는 Nginx 설정에서 정적으로 결정됨.
  런타임 확장 불가 → 초기 용량 설계 중요
- **블로킹 FFI 위험**: C FFI 함수가 블로킹하면 worker 전체가 블로킹됨.
  모든 `.so` 함수는 시간 제한(< 1ms) 준수 필요

### 향후 고려

- 클러스터 모드(multi-instance)가 필요해지면 외부 KV 스토어(Redis 등) 도입 검토
- `.so` 함수 타임아웃 강제는 별도 ADR에서 결정

---

## 관련 문서

- [ADR-002](./ADR-002-policy-evaluation-conflict-detection.md) — 정책 평가 규칙
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) — 정책 저장소 + Hot Reload
- [ADR-004](./ADR-004-log-metrics-admin-security.md) — 로그/메트릭 + 관리면 보안
- [spec/architecture.md](../../spec/architecture.md) — 전체 아키텍처 스펙
