# Architecture Specification

> **ADR 참조**: [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)

## 1. 개요

LuaGate는 OpenResty(Nginx + LuaJIT) 기반의 단일 인스턴스 API/보안 게이트웨이다.
HTTP 요청 및 TCP 스트림을 가로채어 정책 기반 허용/차단, 위협 탐지, 로그/메트릭 수집을 수행한다.

## 2. 프로세스 모델

```text
┌─────────────────────────────────────────────────────────────┐
│  OS Process: nginx (OpenResty)                              │
│                                                             │
│  ┌─────────────┐                                           │
│  │   Master    │  - 설정 로드, worker 스폰/재시작            │
│  │   Process   │  - HUP 시그널 처리 (config reload)          │
│  └──────┬──────┘                                           │
│         │ fork                                             │
│  ┌──────┴──────────────────────────────────────┐           │
│  │  Worker Pool (nginx worker_processes = auto) │           │
│  │                                             │           │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │           │
│  │  │ Worker 1 │  │ Worker 2 │  │ Worker N │  │           │
│  │  │ Lua VM   │  │ Lua VM   │  │ Lua VM   │  │           │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  │           │
│  └───────┼─────────────┼─────────────┼─────────┘           │
│          │             │             │                      │
│  ┌───────▼─────────────▼─────────────▼─────────┐           │
│  │         ngx.shared.DICT (mmap)               │           │
│  │  luagate_policy | luagate_metrics |           │           │
│  │  luagate_stream_metrics | luagate_connections │           │
│  │  luagate_state                               │           │
│  └──────────────────────────────────────────────┘           │
│                                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  Shared Libraries (ffi.load per worker)      │           │
│  │  luagate_scanner.so | luagate_decoder.so      │           │
│  └──────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

- **master process**: 설정 파싱, worker 관리, 시그널 처리
  - HUP 시그널 수신 시: nginx.conf 재로드 + 새 worker 기동 + 기존 worker graceful shutdown (full config reload, ADR-002 §3.3)
- **worker process**: 실제 요청 처리. 각자 독립 Lua VM 보유. 이벤트 기반 비동기 처리
- **shared dict**: worker 간 정책 버전, 메트릭, 연결 수 공유 (ADR-001)
- **C/Rust FFI**: `.so` 파일을 각 worker에서 `ffi.load()`로 로드. IPC 없음 (ADR-001)

## 3. Shared Dict Zone 모델

### 3.1 Zone 목록 및 역할

| Zone | 역할 | Key Model | Write Owner | Atomicity Unit |
| --- | --- | --- | --- | --- |
| `luagate_policy` | 정책 버전 포인터 + 버전별 blob | `http:active_version`, `stream:active_version`, `policy:<ver>:blob`, `policy:<ver>:meta` | reload worker | active_version pointer 교체 단위 |
| `luagate_stream_metrics` | Stream 메트릭 | `stream:metrics:*` | 각 worker (incr) | 키 단위 |
| `luagate_metrics` | HTTP 메트릭 | `metrics:*` | 각 worker (incr) | 키 단위 |
| `luagate_connections` | 활성 연결 수 | `active_http`, `active_stream` | 해당 worker | 키 단위 |
| `luagate_state` | Reload/health 플래그 | `state:reload_flag`, `state:health` | reload worker | 키 단위 |

> **Versioned keyspace 원칙** (ADR-001 §1.1, ADR-002 §3.4):
> 새 정책을 `policy:<new_version>:blob`에 먼저 기록한 뒤, `http:active_version` / `stream:active_version` 포인터를 교체한다.
> 이렇게 하면 pointer 교체 이전까지 기존 worker는 old version을 계속 사용하며 무중단이 보장된다.

### 3.2 `luagate_policy` Versioned Keyspace 구조

```text
-- 서브시스템별 active version pointer (단순 string 값)
luagate_policy["http:active_version"]   = "<sha256 hex>"   -- HTTP 활성 버전
luagate_policy["stream:active_version"] = "<sha256 hex>"   -- Stream 활성 버전

-- 버전별 blob (JSON 직렬화된 compiled rules)
luagate_policy["policy:<sha256>:blob"] = "<json>"

-- 버전별 메타데이터 (로드 시각, 규칙 수, 충돌 목록 등)
luagate_policy["policy:<sha256>:meta"] = "<json>"
```

> **LKG(Last-Known-Good)**: LKG 버전 포인터는 meta 내 `lkg_version` 필드로 보관한다.
> commit 실패 시 active_version을 lkg_version으로 복원한다 (policy-engine.md §4.1 step [7] 참조).

### 3.3 L1 캐시 무효화 전략

각 worker는 module-level upvalue로 정책을 캐싱한다.
갱신 조건: `active_version != _cached_version` (요청 진입 시 shared dict에서 확인).

```lua
-- worker-local L1 캐시 갱신 흐름 (policy-engine.md §4.4 참조)
local current_version = ngx.shared.luagate_policy:get("http:active_version")
if current_version ~= _cached_version then
    -- shared dict(L2)에서 버전별 blob 로드
    local blob_key = "policy:" .. current_version .. ":blob"
    local policy_json = ngx.shared.luagate_policy:get(blob_key)
    if policy_json then
        _cached_policy = cjson.decode(policy_json)
        _cached_version = current_version
    end
    -- blob 없으면 last-known-good(_cached_policy) 유지
end
```

### 3.4 LKG (Last-Known-Good) 형성 및 사용

- **형성**: 첫 번째 성공 reload 완료 시 LKG 포인터를 `luagate_policy["policy:<active_sha256>:meta"]`의 `lkg_version` 필드에 기록
- **사용**: 다음 reload 실패(validate/compile/commit 오류) 시 현재 active 정책을 LKG로 복원
- **Cold start 조건**: parse + validate + conflict_detect + compile 단계 중 하나라도 실패 시 LKG 사용. LKG 없으면 fail-closed (기동 거부)

## 4. 요청 처리 파이프라인

### 4.1 HTTP 파이프라인

```text
Client
  │
  ▼
[Nginx TCP Accept]
  │
  ▼
[SSL/TLS Termination] (선택적)
  │
  ▼
[init_by_lua] ── 서버 기동 시 1회: 정책 로드, .so 초기화
  │
  ▼ (요청마다)
[rewrite_by_lua] ── URL 정규화, path_raw → path_normalized
  │
  ▼
[access_by_lua] ── 정책 평가 (핵심 처리 단계)
  │               1. 정책 버전 확인 (shared dict L2, L1 캐시 비교)
  │               2. C FFI: 보안 스캐너 실행
  │               3. 정책 매칭 (ADR-002)
  │               ├─ deny → 403 반환, 로그 기록
  │               └─ allow → 다음 단계
  ▼
[proxy_pass / content_by_lua] ── 업스트림 프록시
  │
  ▼
[log_by_lua] ── 액세스 로그 기록 (27필드, ADR-004), 메트릭 업데이트
  │
  ▼
Client Response
```

### 4.2 Stream(TCP) 파이프라인

```text
Client TCP Connect
  │
  ▼
[stream preread_by_lua] ── 프로토콜 탐지 + 스트림 정책 평가
  │                        ngx.req.socket() 기반 preread buffer 조회
  │                        src_ip/dst_port/detected_protocol/sni 기반 매칭
  │                        ├─ deny → 연결 종료, 로그 기록
  │                        └─ proxy → 다음 단계
  ▼
[stream proxy_pass] ── Nginx native TCP 프록시
  │                    (Lua가 아닌 Nginx native data plane)
  ▼
[stream log_by_lua] ── 세션 로그 기록 (18필드, ADR-004)
```

> **설계 원칙**: stream 파이프라인은 `content_by_lua`나 가상의 `stream access_by_lua`가 아니라 Nginx native `proxy_pass`를 사용한다.
> Lua는 `preread_by_lua`(탐지 + 정책 판정)와 `log_by_lua`에만 관여하며, 실제 바이트 전달은 Nginx가 담당한다.
> `ngx.req.get_body_data()`는 stream context에서 사용하지 않는다. preread buffer 조회는 `ngx.req.socket()` 기반 접근을 기준으로 설명한다.

## 5. 실패 정책 표

| 실패 유형 | 실패 모드 | 비고 |
| --- | --- | --- |
| 정책 decode 에러 | **fail-closed** (기존 best-effort degrade 폐기) | LKG로 복원 또는 기동 거부 |
| 정책 parse 에러 | fail-closed | |
| 정책 validate 에러 | fail-closed (all-or-nothing) | |
| 정책 compile 에러 | fail-closed (all-or-nothing) | |
| 정책 commit 에러 | partial (서브시스템별 독립) | 실패 서브시스템만 LKG 유지 |
| upstream 연결 실패 | 502 반환 | |
| rate limit counter eviction | fail-open | shared_dict 용량 초과 시 |
| logging 실패 | fail-closed (감사 로그) | ADR-004: 감사 로그 드롭 금지 |
| FFI .so 로드 실패 | fail-closed | 기동 거부 |
| native crash (worker) | process failure | nginx master가 재기동 |

## 6. 기술 스택

| 계층 | 기술 | 버전 |
| --- | --- | --- |
| 웹 서버/런타임 | OpenResty | 1.25.x |
| 스크립팅 언어 | LuaJIT | 2.1 |
| 고성능 모듈 | Rust (cdylib) | 1.75+ |
| FFI 바인딩 | LuaJIT FFI | (내장) |
| 정책 설정 | YAML | — |
| 메트릭 형식 | Prometheus text format | 0.0.4 |
| 로그 형식 | JSON (NDJSON) | — |

## 7. 디렉토리 구조

```text
luagate/
├── conf/
│   ├── nginx.conf              # Nginx 메인 설정
│   ├── nginx.http.conf         # HTTP 서버 설정
│   ├── nginx.stream.conf       # Stream 서버 설정
│   └── policies.yaml           # 정책 파일 (canonical source, ADR-003)
├── lua/
│   ├── luagate/
│   │   ├── init.lua            # 초기화, .so 로드
│   │   ├── policy/
│   │   │   ├── loader.lua      # YAML 파싱, 정책 로드
│   │   │   ├── evaluator.lua   # 정책 평가 엔진 (ADR-002)
│   │   │   └── conflict.lua    # 충돌/음영 감지 (ADR-002)
│   │   ├── scanner/
│   │   │   └── ffi.lua         # C FFI 바인딩 (보안 스캐너)
│   │   ├── decoder/
│   │   │   └── ffi.lua         # C FFI 바인딩 (URL 디코더)
│   │   ├── log/
│   │   │   ├── http.lua        # HTTP 요청 로그 (ADR-004, 27필드)
│   │   │   └── stream.lua      # TCP 세션 로그 (ADR-004, 18필드)
│   │   ├── metrics/
│   │   │   └── collector.lua   # 메트릭 수집/집계 (ADR-004)
│   │   └── admin/
│   │       ├── router.lua      # Admin API 라우터
│   │       └── auth.lua        # Bearer token 인증 (ADR-004)
├── src/
│   ├── scanner/                # Rust: 보안 스캐너 .so
│   └── decoder/                # Rust: URL/인코딩 디코더 .so
├── docs/
│   ├── design/adr/             # Architecture Decision Records
│   └── spec/                   # 기술 스펙 문서 (이 디렉토리)
└── tests/
    ├── unit/                   # Lua 단위 테스트 (busted)
    ├── integration/            # Docker 기반 통합 테스트
    └── fixtures/               # 테스트 정책/요청 픽스처
```

## 8. Admin API Binding

Admin API는 server block identity 기반으로 data plane에서 분리된다.

| 항목 | 설명 |
| --- | --- |
| **설정값** | 환경변수/파일로 주입 가능한 값 (토큰, 포트, 로그 레벨 등) |
| **불변규약** | 코드에 하드코딩된 정책 불변식 (fail-closed, 감사 로그 드롭 금지 등) |
| **정책 우회 조건** | Admin 서버는 별도 server block으로 분리. 해당 server block에서는 ADR-002 정책 평가 제외 (server block identity로 구분) |

## 9. 수평 확장 전략

LuaGate는 단일 인스턴스 단위로 배포된다 (ADR-001).
수평 확장은 로드밸런서 뒤에 복수 인스턴스를 배치하는 방식으로 달성한다:

```text
Internet
    │
    ▼
[L4/L7 Load Balancer]
    │          │          │
    ▼          ▼          ▼
[LuaGate 1] [LuaGate 2] [LuaGate N]
```

- 인스턴스 간 상태 동기화 없음 (메트릭은 각 인스턴스 독립)
- 전체 메트릭 집계: Prometheus 등 외부 시스템이 담당
- 정책 동기화: 모든 인스턴스에 동일 `policies.yaml` 배포 (CI/CD 책임)

## 10. 의존성

- **ADR-001**: 실행 모델, shared dict 구조, C FFI 통합 방식
- **ADR-002**: 정책 평가 규칙 → `lua/luagate/policy/evaluator.lua`
- **ADR-003**: Hot Reload 시맨틱스 → `lua/luagate/policy/loader.lua`
- **ADR-004**: 로그/메트릭 스키마, Admin 보안 → `lua/luagate/log/`, `lua/luagate/admin/`

<!-- ADR 필요 -->
> **TODO**: 멀티 인스턴스 정책 동기화(실시간) 구현 시 ADR 필요

<!-- ADR 필요 -->
> **TODO**: `.so` 함수 타임아웃 강제 메커니즘 구현 시 ADR 필요
