# LuaGate 면접 어필 포인트


## 프로젝트 한 줄 설명

"OpenResty(Nginx + LuaJIT) 기반의 API/보안 게이트웨이로, Rust FFI를 활용한 고성능 위협 탐지와
정책 기반 트래픽 제어를 제공하는 단일 인스턴스 게이트웨이"

## 기술적 차별점

### 1. 비동기 이벤트 루프 + 동기 FFI 통합
- OpenResty의 비동기 이벤트 기반 모델을 유지하면서 Rust 동기 함수를 안전하게 호출
- < 1ms FFI 완료 보장으로 worker 이벤트 루프 블로킹 없음
- 각 worker에서 독립적으로 `ffi.load()` — IPC, 락, 동기화 없음

### 2. Zero-Copy 정책 핫 리로드
- versioned keyspace (`policy:<hash>:blob`) + active pointer swap 패턴
- 요청 처리 중단 없는 무중단 정책 업데이트
- module-level upvalue 캐시로 shared dict 접근 최소화 (버전 일치 시 완전 bypass)

### 3. 멀티레이어 인코딩 우회 탐지
- URL 디코더 (Rust): 5레이어 디코딩 (percent, double-percent, unicode, HTML entity, base64)
- rewrite_by_lua에서 1회 정규화 → access_by_lua 이후 재정규화 없음
- path_raw (원본) + path_normalized (정규화) 이중 보존으로 로그 포렌식 지원

### 4. L4/L7 통합 처리
- HTTP (L7): rewrite + access + log 파이프라인
- TCP Stream (L4): preread_by_lua에서 프로토콜 탐지 + 정책 판정 통합
- Stream은 Nginx native proxy_pass 사용 — Lua가 data plane 관여 없음

## 설계 결정 어필 포인트

| 결정 | 선택 | 이유 |
|------|------|------|
| 정책 캐시 위치 | module-level upvalue | ngx.ctx(요청 범위) → 매 요청 reload 문제 방지 |
| 정책 원자성 | versioned keyspace + pointer | safe_set 단일 key 원자성 한계 극복 |
| Rust panic 전략 | `panic = "abort"` | C-Lua 스택에서 unwind = UB, abort가 안전 |
| Stream 파이프라인 | preread_by_lua | access_by_lua는 stream context에 없음 |
| 보안 fail mode | fail-closed | 스캐너/디코더 에러 → deny (안전 우선) |

## 포트폴리오 맥락

ironpost(Go REST API) → dbgate(DB 추상화 레이어) → LuaGate(API 게이트웨이):
- 각 프로젝트가 이전 프로젝트의 앞단을 담당하는 계층 구조
- LuaGate → dbgate → ironpost 순서로 요청이 흐르는 실제 운영 가능한 스택 구성
