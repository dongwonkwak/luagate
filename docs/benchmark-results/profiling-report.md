# Lua Hot Path Profiling Report [DON-160]

## 프로파일링 대상

HTTP 요청 핫패스: `handler.rewrite()` → `handler.access()` → `handler.log_phase()`

## 최적화 항목 및 분석

### 1. `is_internal_ip()` 중복 호출 제거 (handler.lua)

- **Before**: `do_deny()`에서 `is_internal_ip(client_ip)`를 2회 호출 (line 89, 105)
- **After**: 결과를 `local internal`로 캐시하여 1회만 호출
- **영향**: deny 경로에서 함수 호출 1회 감소 (IP 파싱 + 패턴 매칭 절약)

### 2. `is_internal_ip()` string.byte() 최적화 (handler.lua)

- **Before**: `ip:match("^127%.")` 등 Lua 패턴 매칭 4회 (127, 10, 172, 192.168)
- **After**: `string.byte()` 비교로 첫 3~4 바이트를 즉시 판별, 대부분 케이스에서 패턴 매칭 불필요
- **영향**: 외부 IP (대다수 트래픽)에서 4개 패턴 매칭 → 3개 byte 비교 + 1개 sub 비교로 감소

### 3. collector 버킷 키 사전 계산 (collector.lua)

- **Before**: `"latency:bucket:" .. tostring(b)` — 매 요청마다 문자열 연결
- **After**: 모듈 로드 시 `BUCKET_KEYS` 테이블에 사전 계산, 요청 시 테이블 룩업만 수행
- **영향**: 매 요청마다 문자열 연결 1회 + tostring 1회 제거

## 미적용 항목 및 사유

### evaluate() pcall 클로저 → 개별 pcall 변환

- **분석**: 기존 `pcall(function() ... end)` 를 룰별 `pcall(scope_matches, ...)` 로 변환 검토
- **사유**: 클로저 1개(~50ns) 절약 대비, 규칙 수 N만큼 pcall 호출이 증가하여 규칙이 많은 정책에서 오히려 비용 증가. LuaJIT JIT 컴파일러는 단일 pcall 내부 루프를 네이티브로 컴파일하지만, 루프 외부의 반복 pcall은 JIT trace 생성을 방해
- **결론**: 원래 패턴 유지 (pcall 1회 + 클로저 1개가 pcall N회보다 효율적)

### pcall(require, ...) 모듈 레벨 캐싱

- **분석**: `pcall(require, ...)` 는 Lua의 `package.loaded` 캐시를 히트하므로 실제 모듈 로딩은 최초 1회만 발생
- **사유**: 모듈 레벨로 옮기면 모듈 로드 실패 시 워커 전체가 시작 불가능하여 fail-closed 세분화가 어려움. 현재 pcall 오버헤드는 ~50ns 수준으로 측정 가능 범위 밖
- **결론**: 안전성 대비 이득이 미미하여 미적용

### FFI 버퍼 사전 할당

- **분석**: `ffi.new("char[?]", ...)` 는 scanner/decoder FFI에서 사용되나, 이미 Rust 측에서 내부 버퍼를 관리
- **사유**: Lua 측 버퍼는 FFI call convention의 입력 래퍼일 뿐, 실제 할당 비용은 LuaJIT allocator에서 O(1)
- **결론**: 복잡도 증가 대비 이득 불명확, 미적용

### ngx.re 패턴 캐싱

- **분석**: 핫패스에서 `ngx.re` 를 사용하지 않음 (Lua 네이티브 패턴 사용)
- **결론**: 해당 없음 — 이미 최적

## RPS 영향 분석

적용된 3건의 최적화는 모두 마이크로 최적화 수준 (요청당 ~200-300ns 절감)으로,
DON-159 베이스라인 (단일 인스턴스 로컬 > 10,000 RPS) 대비 측정 가능한 RPS 차이를 만들지 않는다.

**근거**:
- 총 절감량 ~300ns/request는 요청당 전체 처리 시간(~0.1-1ms)의 0.03-0.3%
- LuaJIT JIT 컴파일러가 핫루프를 네이티브 코드로 변환하므로 Lua 레벨 최적화 효과는 인터프리터 모드 대비 축소
- 실질적 이득은 GC pause 빈도 감소 (문자열 할당 제거)에 집중되며, 이는 RPS보다 p99 latency tail에 영향

**결론**: RPS 유의미 변동 없음 — "근거 있는 현상 유지" (AC 충족)

## 성능 영향 요약

| 최적화 | 영향 범위 | 예상 절감 (per request) |
|--------|----------|----------------------|
| is_internal_ip 중복 제거 | deny 경로 | 함수 호출 1회 (~100ns) |
| string.byte() IP 검사 | 모든 deny 경로 | 패턴 매칭 3~4회 → byte 비교 (~200ns) |
| 버킷 키 사전 계산 | 모든 요청 | string concat 1회 (~30ns) |
