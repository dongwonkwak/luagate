# Architecture Specification

> **ADR 참조**: [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)

## 1. 개요

LuaGate는 OpenResty(Nginx + LuaJIT) 기반의 단일 인스턴스 API/보안 게이트웨이다.
HTTP 요청 및 TCP 스트림을 가로채어 정책 기반 허용/차단, 위협 탐지, 로그/메트릭 수집을 수행한다.

## 2. 프로세스 모델

```
┌─────────────────────────────────────────────────────────────┐
│  OS Process: nginx (OpenResty)                              │
│                                                             │
│  ┌─────────────┐                                           │
│  │   Master    │  - 설정 로드, worker 스폰/재시작            │
│  │   Process   │  - HUP 시그널 처리 (정책 리로드)            │
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
│  │  luagate_connections                         │           │
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

## 3. 요청 처리 파이프라인

### 3.1 HTTP 파이프라인

```
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
  │               1. 정책 버전 확인 (shared dict)
  │               2. C FFI: 보안 스캐너 실행
  │               3. 정책 매칭 (ADR-002)
  │               ├─ deny → 403 반환, 로그 기록
  │               └─ allow → 다음 단계
  ▼
[proxy_pass / content_by_lua] ── 업스트림 프록시
  │
  ▼
[log_by_lua] ── 액세스 로그 기록 (22필드, ADR-004), 메트릭 업데이트
  │
  ▼
Client Response
```

### 3.2 Stream(TCP) 파이프라인

```
Client TCP Connect
  │
  ▼
[stream preread_by_lua] ── 프로토콜 탐지 (HTTP/TLS/SSH/unknown)
  │                        ngx.req.socket()으로 첫 N 바이트 peek
  │                        SNI 추출 (TLS ClientHello)
  │                        탐지 결과 → ngx.ctx.luagate_stream에 저장
  ▼
[stream access_by_lua] ── 스트림 정책 평가
  │                       src_ip/dst_port/detected_protocol/sni 기반 매칭
  │                       ├─ deny → 연결 종료 (ngx.exit), 로그 기록
  │                       └─ proxy → 다음 단계
  ▼
[stream proxy_pass] ── Nginx native TCP 프록시
  │                    (content_by_lua가 아닌 proxy_pass 지시자 사용)
  ▼
[stream log_by_lua] ── 세션 로그 기록 (12필드, ADR-004)
```

> **설계 원칙**: stream 파이프라인은 `content_by_lua`가 아닌 Nginx native `proxy_pass`를 사용한다.
> Lua는 `preread_by_lua`(탐지)와 `access_by_lua`(정책 판정)에만 관여하며, 실제 바이트 전달은 Nginx가 담당한다.
> `ngx.req.get_body_data()`는 stream context에서 사용하지 않는다. 데이터 peek은 `ngx.req.socket()`의 `receive(N, "keep")`으로 수행한다.

## 4. 기술 스택

| 계층 | 기술 | 버전 |
|------|------|------|
| 웹 서버/런타임 | OpenResty | 1.25.x |
| 스크립팅 언어 | LuaJIT | 2.1 |
| 고성능 모듈 | Rust (cdylib) | 1.75+ |
| FFI 바인딩 | LuaJIT FFI | (내장) |
| 정책 설정 | YAML | — |
| 메트릭 형식 | Prometheus text format | 0.0.4 |
| 로그 형식 | JSON (NDJSON) | — |

## 5. 디렉토리 구조

```
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
│   │   │   ├── http.lua        # HTTP 요청 로그 (ADR-004)
│   │   │   └── stream.lua      # TCP 세션 로그 (ADR-004)
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

## 6. 수평 확장 전략

LuaGate는 단일 인스턴스 단위로 배포된다 (ADR-001).
수평 확장은 로드밸런서 뒤에 복수 인스턴스를 배치하는 방식으로 달성한다:

```
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

## 7. 의존성

- **ADR-001**: 실행 모델, shared dict 구조, C FFI 통합 방식
- **ADR-002**: 정책 평가 규칙 → `lua/luagate/policy/evaluator.lua`
- **ADR-003**: Hot Reload 시맨틱스 → `lua/luagate/policy/loader.lua`
- **ADR-004**: 로그/메트릭 스키마, Admin 보안 → `lua/luagate/log/`, `lua/luagate/admin/`

<!-- ADR 필요 -->
> **TODO**: 멀티 인스턴스 정책 동기화(실시간) 구현 시 ADR 필요

<!-- ADR 필요 -->
> **TODO**: `.so` 함수 타임아웃 강제 메커니즘 구현 시 ADR 필요
