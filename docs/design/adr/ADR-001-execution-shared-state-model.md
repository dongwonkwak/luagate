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

3. **C FFI 호출 모델** — Rust/C 공유 라이브러리(`.so`)는 `ffi.load()`로 로드하며,
   worker 프로세스 내부에서 동기 함수 호출로 실행된다.
   IPC(소켓, 파이프 등)를 사용하지 않는다.
   모든 FFI 호출은 동일 worker의 이벤트 루프 내에서 블로킹 없이 완료되어야 한다.

### §1.2 실패 정책

| 실패 시나리오 | 대응 |
|--------------|------|
| C FFI 함수 반환 오류 | Lua pcall로 포착, deny 처리 후 오류 로그 기록 |
| shared dict 쓰기 실패 (용량 초과) | 메트릭 손실 허용, 오류 로그 기록, 요청은 계속 처리 |
| 정책 로드 실패 (파싱/검증) | last-known-good 정책 유지, 오류 로그 + 관리 API 상태에 반영 |
| worker 크래시 | Nginx master가 worker 재시작, 다른 worker 영향 없음 |
| `.so` 로드 실패 | 서버 시작 실패 (fatal), 배포 파이프라인에서 사전 검증 필요 |

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
