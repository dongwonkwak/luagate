# ADR-015: TLS Termination

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-23 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-230](https://linear.app/dongwon/issue/DON-230) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md), [ADR-003](./ADR-003-policy-storage-hot-reload.md) |
| **Resolves** | Stream 파이프라인에서 TLS 패스스루만 지원하여 인증서 관리/터미네이션이 불가한 문제; 도메인별 선택적 TLS 처리 부재 |

---

## Status

**Accepted** -- LuaGate Stream 파이프라인에 TLS 터미네이션 기능을 도입한다. 기존 TLS 패스스루와 공존하며 도메인별로 선택 가능하다.

---

## Context

현재 LuaGate Stream 파이프라인은 **TLS 패스스루** 모드만 지원한다 (stream-pipeline.md S10). TLS 연결을 복호화하지 않고 SNI만 탐지하여 라우팅/차단 결정에 사용하며, 실제 TLS 핸드셰이크는 업스트림이 처리한다.

### 현재 상태

1. **TLS 처리**: 패스스루 전용. SNI 추출 후 암호화된 스트림을 업스트림에 투명 전달
2. **인증서 관리**: 없음. LuaGate가 인증서를 보유하지 않음
3. **도메인별 TLS 정책**: 없음. 모든 TLS 연결에 동일한 패스스루 동작 적용
4. **mTLS**: 미지원

### 요구 사항

- LuaGate에서 TLS를 종료하고 복호화된 트래픽을 업스트림에 전달할 수 있어야 한다
- 도메인별로 터미네이션과 패스스루를 선택할 수 있어야 한다
- 인증서 추가/교체 시 Nginx 재시작 없이 반영 가능해야 한다
- Private key 보안: 메모리 덤프/LRU eviction으로 인한 유출 방지
- fail-closed: 인증서 로드 실패 시 해당 도메인 연결 거부 (패스스루 fallback 하지 않음)

### 검토된 대안

| 대안 | 장점 | 단점 |
|------|------|------|
| Nginx 정적 `ssl_certificate` 지시자 | 단순, 검증된 방식 | SNI 기반 동적 선택 불가, 추가/교체 시 reload 필요 |
| **`ssl_certificate_by_lua_block` + `ngx.ssl` API** | SNI 기반 동적 인증서, Hot Reload 가능, OpenResty 네이티브 | 구현 복잡도 증가 |
| 외부 TLS proxy (Envoy/HAProxy) | 성숙한 TLS 스택 | 아키텍처 복잡도 증가, 별도 프로세스 관리 |

---

## Decision

### 1. 인증서 관리: 파일 기반 + Admin API 업로드

Canonical source는 파일시스템이다.

- 인증서/키 파일의 단일 진실의 원천은 파일시스템이다.
- 기본 경로: `conf/certs/` (도메인별 하위 디렉토리)
- ACME(Let's Encrypt) 자동 발급은 Phase 4 범위로 분리한다.

**파일 구조:**

```
conf/certs/
├── api.example.com/
│   ├── fullchain.pem    # 인증서 체인
│   └── privkey.pem      # Private key (0600)
├── web.example.com/
│   ├── fullchain.pem
│   └── privkey.pem
└── _default/            # 기본 인증서 (SNI 불일치 시, 선택적)
    ├── fullchain.pem
    └── privkey.pem
```

**Admin API 인증서 업로드 (Phase 2):**

- `PUT /api/v1/certs/{domain}` -- 인증서/키 쌍 업로드
- Atomic write 방식: 임시 파일 → `rename()` 원자적 교체 (ADR-003 패턴)
- 업로드 후 자동으로 SSL context 캐시 무효화

### 2. Private Key 보호

| 저장소 | Private Key 저장 | 이유 |
|--------|-----------------|------|
| 파일시스템 | O (canonical) | 파일 권한(0600)으로 보호 |
| shared dict | **X (저장 금지)** | LRU eviction으로 예고 없이 삭제될 수 있음; 메모리 덤프 시 유출 위험 |
| worker upvalue (SSL context) | O (파생, 캐시) | 프로세스 메모리 내 OpenSSL 구조체로 보관, 파일에서 로드 |

**키 파일 권한 강제:**

- `init_by_lua`에서 인증서 디렉토리 스캔 시 키 파일 권한 검증
- `0600`이 아닌 키 파일 발견 시 해당 도메인 로드 거부 + `ngx.log(ngx.ERR, ...)` 경고
- 서버 기동 자체는 차단하지 않음 (다른 도메인 서비스 유지). 해당 도메인만 fail-closed 처리

### 3. SSL 컨텍스트: `ssl_certificate_by_lua_block` + `ngx.ssl` API

**SNI 기반 동적 인증서 선택:**

```
[TLS ClientHello]
    │
    ├─ SNI 추출 (stream preread_by_lua: 기존 detect_protocol FFI)
    │
    ├─ 정책 확인: tls_termination=true?
    │   ├─ false → TLS 패스스루 (기존 동작)
    │   └─ true  → ssl_certificate_by_lua_block 진입
    │
    └─ ssl_certificate_by_lua_block:
        ├─ ngx.ssl.server_name() → SNI 확인
        ├─ worker upvalue 캐시에서 SSL context 조회
        │   ├─ hit → ngx.ssl.set_der_cert() + ngx.ssl.set_der_priv_key()
        │   └─ miss → 파일에서 PEM 로드 → DER 변환 → 캐시 저장 → 설정
        └─ 실패 시 → ngx.exit(ngx.ERROR) (fail-closed)
```

**OpenResty `ngx.ssl` API 사용:**

```lua
-- ssl_certificate_by_lua_block
local ssl = require("ngx.ssl")

local sni, err = ssl.server_name()
if not sni then
    ngx.log(ngx.ERR, "failed to get SNI: ", err)
    return ngx.exit(ngx.ERROR)  -- fail-closed
end

local cert_der, key_der = load_cert_for_domain(sni)
if not cert_der or not key_der then
    ngx.log(ngx.ERR, "no cert for domain: ", sni)
    return ngx.exit(ngx.ERROR)  -- fail-closed
end

local ok, err = ssl.clear_certs()
if not ok then
    ngx.log(ngx.ERR, "clear_certs failed: ", err)
    return ngx.exit(ngx.ERROR)
end

ok, err = ssl.set_der_cert(cert_der)
if not ok then
    ngx.log(ngx.ERR, "set_der_cert failed: ", err)
    return ngx.exit(ngx.ERROR)
end

ok, err = ssl.set_der_priv_key(key_der)
if not ok then
    ngx.log(ngx.ERR, "set_der_priv_key failed: ", err)
    return ngx.exit(ngx.ERROR)
end
```

### 4. SNI 매핑: `luagate_tls_certs` shared dict + worker upvalue 캐시

**2-tier 캐시 구조 (ADR-001/003 패턴 준수):**

| 계층 | 저장소 | 내용 | 갱신 방식 |
|------|--------|------|----------|
| L1 | worker module upvalue | `{ [sni] = { cert_der, key_der, version } }` | 요청 시 L2 버전 비교 |
| L2 | `luagate_tls_certs` shared dict | `{ tls_certs_version, cert:<domain>:path, cert:<domain>:hash }` | Admin API 업로드 또는 reload 시 갱신 |

**shared dict 키 스키마:**

| 키 | 타입 | 설명 |
|----|------|------|
| `tls_certs_version` | string | 인증서 맵 전체 버전 (SHA256) |
| `cert:<domain>:cert_path` | string | 인증서 파일 경로 |
| `cert:<domain>:key_path` | string | 키 파일 경로 |
| `cert:<domain>:hash` | string | 인증서 파일 SHA256 해시 (변경 감지) |

**L1 캐시 갱신 프로토콜:**

1. `ssl_certificate_by_lua` 진입 시 `luagate_tls_certs:get("tls_certs_version")` 확인
2. L1 캐시 버전과 다르면 해당 도메인의 인증서를 파일에서 재로드
3. 동일하면 L1 캐시 hit → SSL context 즉시 설정

**zone 크기**: `luagate_tls_certs` -- 2m (메타데이터만 저장, PEM/DER 데이터 미저장)

### 5. 정책 연동: stream rule에 `tls_termination` 속성 추가

**정책 스키마 확장:**

```yaml
stream_rules:
  - id: terminate-api-tls
    scope:
      detected_protocol: tls
      sni: "api.example.com"
      dst_port: 443
    priority: 10
    action: proxy
    upstream: "backend:8080"          # 복호화 후 평문 업스트림
    tls_termination: true             # 신규 필드

  - id: passthrough-internal-tls
    scope:
      detected_protocol: tls
      sni: "internal.example.com"
      dst_port: 443
    priority: 10
    action: proxy
    upstream: "internal-backend:443"  # 암호화 유지 업스트림
    tls_termination: false            # 기본값: 패스스루

  - id: deny-raw
    scope:
      detected_protocol: raw
    priority: 1
    action: deny
    # tls_termination 필드 없음: non-TLS 규칙에는 무관
```

**하위 호환성:**

- `tls_termination` 필드 생략 시 기본값 `false` (기존 패스스루 동작 유지)
- `action: deny` 규칙에 `tls_termination` 필드가 있으면 무시 (의미 없음)
- non-TLS 프로토콜 규칙(`detected_protocol: http/raw`)에 `tls_termination: true` 설정 시 스키마 검증 경고

**preread_by_lua 판정 흐름 변경:**

```
1. 프로토콜 탐지 (기존)
2. 정책 매칭 (기존)
3. 매칭된 규칙의 tls_termination 확인
   ├─ true  → ngx.ctx.luagate_stream.tls_termination = true
   │          (ssl_certificate_by_lua에서 참조)
   └─ false → 기존 패스스루 동작
```

### 6. mTLS: Phase 4 연기

mTLS(상호 TLS 인증)는 다음 이유로 Phase 4로 연기한다:

- CA/CRL/OCSP 관리 복잡도가 높음
- 클라이언트 인증서 검증 로직이 별도 ADR 수준의 설계 필요
- 현재 요구 사항에 mTLS 없음

Phase 4 구현 시 별도 ADR을 작성한다.

### 7. 성능 최적화

**SSL 세션 캐시:**

```nginx
# stream server block
ssl_session_cache   shared:luagate_ssl_sessions:10m;
ssl_session_timeout 1h;
ssl_session_tickets off;  # 보안 우선 (ticket key 관리 복잡도 회피)
```

**Worker-level SSL context 캐시:**

- 도메인별 DER 변환 결과를 worker module upvalue에 캐시
- SSL 핸드셰이크마다 파일 I/O + PEM→DER 변환을 반복하지 않음
- 캐시 무효화: `tls_certs_version` 변경 감지 시 해당 도메인만 재로드

**성능 영향 추정:**

| 항목 | 추가 비용 | 비고 |
|------|----------|------|
| SSL 핸드셰이크 | ~1-2ms (RSA 2048), ~0.3ms (ECDSA P-256) | OpenSSL 네이티브 |
| DER 변환 (캐시 miss) | ~0.1ms | 초기 1회만 |
| L1 캐시 조회 | <0.01ms | Lua table lookup |
| L2 버전 확인 | <0.01ms | shared dict get |

### 8. 보안 요구 사항

**TLS 프로토콜 버전:**

| 버전 | 지원 |
|------|------|
| TLS 1.3 | O (권장) |
| TLS 1.2 | O (호환성) |
| TLS 1.1 이하 | X (금지) |

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
```

**Cipher suite (Mozilla Modern 기반):**

```nginx
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers off;  # TLS 1.3에서는 클라이언트 선호 존중
```

**Fail-closed 원칙:**

| 실패 시나리오 | 동작 | 이유 |
|--------------|------|------|
| 인증서 파일 없음 | 해당 도메인 연결 거부 | 패스스루 fallback 시 의도치 않은 평문 노출 위험 |
| 키 파일 권한 오류 (0600 아님) | 해당 도메인 로드 거부 | 키 파일 보안 위반 |
| PEM 파싱 실패 | 해당 도메인 연결 거부 | 손상된 인증서 사용 방지 |
| DER 변환 실패 | 해당 도메인 연결 거부 | OpenSSL 내부 오류 |
| SNI 없는 TLS 연결 + 기본 인증서 없음 | 연결 거부 | 잘못된 인증서 제공 방지 |

> **패스스루 fallback 금지**: 터미네이션 실패 시 패스스루로 전환하면, 공격자가 의도적으로 인증서 오류를 유발하여 암호화된 트래픽을 업스트림에 직접 전달시킬 수 있다. fail-closed만 허용한다.

---

## File Structure

```
lua/luagate/tls/
├── init.lua          # 인증서 디렉토리 스캔, shared dict 초기화, 권한 검증
├── cert_manager.lua  # 인증서 로드/캐시/갱신 로직
└── ssl_handler.lua   # ssl_certificate_by_lua 진입점

conf/certs/           # 인증서 저장 디렉토리 (canonical source)
```

---

## Stream Context 확장

`ngx.ctx.luagate_stream`에 TLS 터미네이션 필드 추가:

```lua
ngx.ctx.luagate_stream = {
    -- 기존 필드 (stream-pipeline.md S7) ...
    tls_termination = boolean,  -- true: LuaGate가 TLS 종료, false: 패스스루
}
```

---

## Nginx Configuration 변경

stream server block에 TLS 터미네이션 관련 지시자 추가:

```nginx
stream {
    server {
        listen 8443 ssl;

        # TLS 프로토콜/cipher 설정
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers '...';  # Mozilla Modern
        ssl_prefer_server_ciphers off;

        # 세션 캐시
        ssl_session_cache   shared:luagate_ssl_sessions:10m;
        ssl_session_timeout 1h;
        ssl_session_tickets off;

        # placeholder 인증서 (ssl_certificate_by_lua에서 동적 교체)
        ssl_certificate     conf/certs/_default/fullchain.pem;
        ssl_certificate_key conf/certs/_default/privkey.pem;

        # 동적 인증서 선택
        ssl_certificate_by_lua_block {
            require("luagate.tls.ssl_handler").select_cert()
        }

        preread_by_lua_block {
            require("luagate.stream.handler").preread()
        }

        proxy_pass $luagate_upstream;

        log_by_lua_block {
            -- 기존 로직 ...
        }
    }
}
```

> **`listen 8443 ssl` vs 현재 `listen 8443`**: TLS 터미네이션을 위해 `ssl` 파라미터를 추가한다. 패스스루 전용 포트가 필요하면 별도 `listen` 블록을 구성한다. `ssl_certificate_by_lua`에서 정책에 따라 패스스루/터미네이션을 분기한다.

---

## Shared Dict Zone 추가

`nginx.conf` http 블록에 추가:

```nginx
lua_shared_dict luagate_tls_certs 2m;
```

명명 규칙: `luagate_` prefix 준수.

---

## Consequences

### 긍정적

- LuaGate에서 TLS를 종료하여 업스트림에 평문 트래픽 전달 가능 (upstream TLS 설정 불필요)
- 도메인별 선택적 터미네이션/패스스루로 유연한 배포 구성
- `ssl_certificate_by_lua`로 Nginx reload 없이 인증서 추가/교체 가능
- 기존 TLS 패스스루 동작과 완전 하위 호환

### 부정적

- 인증서 관리 책임이 LuaGate로 이전 (운영 복잡도 증가)
- SSL 핸드셰이크 연산 비용 추가 (CPU 사용량 증가)
- Private key를 LuaGate 프로세스가 보유해야 함 (보안 표면 확대)
- `luagate_tls_certs` shared dict zone 추가 (메모리 사용량 증가)

### 리스크

| 리스크 | 완화 |
|--------|------|
| Private key 유출 (메모리 덤프) | shared dict 저장 금지, 파일 권한 0600 강제, worker upvalue에 OpenSSL 구조체로만 보관 |
| 인증서 만료 미감지 | Phase 2: Admin API `/api/v1/certs/status`에서 만료일 조회 기능 추가 |
| SSL context 캐시 메모리 증가 | 도메인 수 제한 없으나, DER 인증서 크기는 도메인당 ~5KB 수준. 1000 도메인 = ~5MB |
| 패스스루/터미네이션 정책 혼동 | `tls_termination` 필드 생략 시 기본값 `false` (패스스루). 스키마 검증에서 경고 |
| ACME 미지원으로 인한 수동 갱신 부담 | Phase 4에서 ACME 통합 예정. 현재는 외부 certbot + Admin API 업로드 워크플로 |

---

## Implementation Plan

1. **DON-231** (예정): `lua/luagate/tls/` 모듈 구현 (init, cert_manager, ssl_handler)
2. `luagate_tls_certs` shared dict zone 추가 (`conf/nginx.conf`)
3. stream server block에 `ssl` 파라미터 + `ssl_certificate_by_lua_block` 추가
4. stream rule 스키마에 `tls_termination` 필드 추가 (정책 검증 로직 수정)
5. `preread_by_lua`에서 `tls_termination` 필드를 `ngx.ctx.luagate_stream`에 전달
6. Admin API 인증서 업로드 엔드포인트 구현 (Phase 2)
7. ACME 자동 발급 통합 (Phase 4)
8. mTLS 지원 (Phase 4, 별도 ADR)

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) -- shared dict 구조, 실행 모델
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) -- versioned keyspace, atomic write 패턴
- [spec/stream-pipeline.md](../../spec/stream-pipeline.md) -- Stream 파이프라인, TLS 패스스루 (S10)
- [spec/rust-ffi-modules.md](../../spec/rust-ffi-modules.md) -- detect_protocol, SNI 추출
