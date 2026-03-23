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
└── _default/            # 기본 인증서 (SNI 불일치 시, 필수)
    ├── fullchain.pem    # TLS 터미네이션 활성화 시 반드시 존재해야 함
    └── privkey.pem      # self-signed 또는 placeholder 인증서 가능
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

**Multi-port 구조 + Phase 순서:**

OpenResty stream에서 phase 순서는 `ssl_certificate_by_lua` → `preread_by_lua` → `proxy_pass`이다. `listen ssl`로 선언된 서버에서는 TLS 핸드셰이크가 먼저 완료된 후 preread 단계에 진입한다. 따라서 **하나의 `listen` 블록에서 패스스루와 터미네이션을 동시에 처리할 수 없다**.

이 제약을 해결하기 위해 multi-port 구조를 사용한다:

```
Port 8443 (listen 8443, ssl 없음) — 패스스루 진입점
    │
    ├─ preread_by_lua: 프로토콜 탐지 + 정책 매칭
    │   ├─ tls_termination=true → proxy_pass를 localhost:8445로 라우팅
    │   └─ tls_termination=false → 기존 패스스루 (업스트림에 직접 proxy_pass)
    └─ TLS 핸드셰이크 없음. 암호화된 스트림을 투명 전달

Port 8445 (listen 8445, 내부 전용) — PROXY protocol 전달 서버
    │
    ├─ proxy_protocol on: 원본 클라이언트 IP/port를 PROXY protocol v2로 전달
    └─ proxy_pass 127.0.0.1:8444

Port 8444 (listen 8444 ssl proxy_protocol, 내부 전용) — 터미네이션 전용
    │
    ├─ PROXY protocol v2로 원본 클라이언트 IP/port 수신
    ├─ ssl_certificate_by_lua: SNI 기반 인증서 선택 (캐시 조회만, 파일 I/O 없음)
    │   ├─ ngx.ssl.server_name() → SNI 확인
    │   ├─ worker upvalue 캐시에서 DER 인증서/키 조회
    │   │   ├─ hit → ngx.ssl.set_der_cert() + ngx.ssl.set_der_priv_key()
    │   │   └─ miss → ngx.exit(ngx.ERROR) (fail-closed, init_by_lua에서 사전 로드 필수)
    │   └─ 실패 시 → ngx.exit(ngx.ERROR) (fail-closed)
    │
    ├─ preread_by_lua: 복호화된 데이터에 대한 추가 처리 (TLS 핸드셰이크 이미 완료)
    │
    └─ proxy_pass: 평문 업스트림으로 전달
```

> **Port 8444는 외부 노출하지 않는다.** 방화벽/네트워크 정책으로 localhost만 접근 가능하게 제한한다.
> 외부 클라이언트는 항상 8443으로 연결하고, 터미네이션이 필요한 경우 내부적으로 8444로 전달된다.

**PROXY Protocol v2 (8443 → 8444 원본 클라이언트 메타데이터 전달):**

8444는 별도 stream 세션으로 동작하므로, PROXY protocol 없이는 `$remote_addr`가 `127.0.0.1`(내부 홉)로 설정된다. 원본 클라이언트의 src_ip, src_port, dst_port 등이 유실되어 감사 로그와 정책 평가에서 실제 클라이언트를 식별할 수 없다.

- **8443 → 8445 → 8444 전달 경로**: `proxy_protocol on`은 Nginx stream의 server 레벨 지시자이므로, 패스스루(proxy_protocol 없음)와 터미네이션(proxy_protocol 필요)을 분리하기 위해 중간 서버(8445)를 둔다
- **Port 8445 (PROXY protocol 전달)**: `proxy_protocol on` + `proxy_pass 127.0.0.1:8444`로 원본 클라이언트 IP/port를 PROXY protocol v2 헤더에 실어 전달
- **8444 수신 시**: `listen 8444 ssl proxy_protocol`로 PROXY protocol 헤더를 파싱
- **로그/정책에서 사용**: `$proxy_protocol_addr` / `$proxy_protocol_port`를 src_ip / src_port로 사용
- **preread_by_lua (8444)**: `ngx.var.proxy_protocol_addr`로 원본 클라이언트 IP 조회

**OpenResty `ngx.ssl` API 사용:**

```lua
-- ssl_certificate_by_lua_block (Port 8444 터미네이션 서버에서만 실행)
local ssl = require("ngx.ssl")

local sni, err = ssl.server_name()
if not sni then
    ngx.log(ngx.ERR, "failed to get SNI: ", err)
    return ngx.exit(ngx.ERROR)  -- fail-closed
end

-- worker upvalue 캐시에서만 조회. 파일 I/O 없음.
-- init_by_lua에서 모든 인증서를 사전 로드하여 캐시에 저장.
local cert_der, key_der = get_cached_cert(sni)
if not cert_der or not key_der then
    ngx.log(ngx.ERR, "no cached cert for domain: ", sni)
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

> **Blocking I/O 금지**: `ssl_certificate_by_lua` 내에서 파일 읽기(PEM 로드)를 수행하지 않는다.
> 모든 인증서는 `init_by_lua` 단계에서 사전 로드하여 worker upvalue에 DER 변환 결과를 캐시한다.
> 캐시 miss = 인증서 미등록 → fail-closed (연결 거부).

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

1. **`init_by_lua`** (서버 기동 시): `conf/certs/` 디렉토리를 스캔하여 모든 도메인의 PEM 파일을 읽고 DER 변환 후 module-level table에 저장. 이 시점에만 파일 I/O 허용.
2. **`init_worker_by_lua`** (각 worker 기동 후): `ngx.timer.every()`로 주기적 타이머 등록 (예: 60초). 타이머 콜백에서 `luagate_tls_certs:get("tls_certs_version")`을 확인하고, 버전 변경 감지 시 파일에서 재로드.
   > **Timer 콜백 내 파일 읽기와 blocking I/O**: `ngx.timer.every` 콜백에서의 디스크 파일 읽기는 기술적으로 worker 이벤트 루프를 블로킹한다. 그러나 다음 이유로 실질적 영향이 극소하므로 허용한다:
   > - (a) 인증서 PEM 파일은 수 KB 크기로 읽기 시간이 < 1ms
   > - (b) 타이머 주기가 60초이므로 핸드셰이크 hot path와 달리 빈도가 매우 낮음
   > - (c) `ssl_certificate_by_lua` (TLS 핸드셰이크 hot path)에서는 절대 파일 I/O를 하지 않음 -- worker upvalue 캐시 조회만 수행
   > - 향후 Phase 2에서 `ngx.pipe` 기반 비동기 파일 읽기로 개선 가능
3. **`ssl_certificate_by_lua`** (TLS 핸드셰이크 시): worker upvalue 캐시에서만 조회. **파일 I/O 없음**. 캐시 miss → fail-closed.
4. **Admin API 인증서 업로드 시**: 파일 저장 후 `luagate_tls_certs:set("tls_certs_version", new_version)` 갱신 → 다음 타이머 주기에 각 worker가 감지하여 백그라운드 재로드.

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

**preread_by_lua 판정 흐름 변경 (Port 8443 패스스루 서버):**

```
1. 프로토콜 탐지 (기존)
2. 정책 매칭 (기존)
3. 매칭된 규칙의 tls_termination 확인
   ├─ true  → ngx.ctx.luagate_stream.tls_termination = true
   │          → $luagate_upstream = "127.0.0.1:8445" (PROXY protocol 전달 서버 → 8444 터미네이션)
   └─ false → 기존 패스스루 동작 ($luagate_upstream = 정책의 upstream 값)
```

> **Phase 순서 주의**: Port 8443에서는 `listen ssl`이 아니므로 `ssl_certificate_by_lua`가 실행되지 않는다.
> TLS 터미네이션 판정은 preread 단계에서 SNI 기반으로 수행하고, 실제 TLS 핸드셰이크는 8444 서버가 처리한다.

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
- 캐시 무효화: `tls_certs_version` 변경 감지 시 `init_worker_by_lua` 타이머가 해당 도메인만 재로드

**SSL 세션 캐시 무효화 (인증서 교체 시):**

- SSL session resumption 시 `ssl_certificate_by_lua`가 스킵된다. 이전 인증서로 생성된 세션이 재사용될 수 있다.
- 인증서 교체 시 세션 캐시를 무효화해야 새 인증서가 즉시 반영된다.
- **`ssl_session_cache`는 Lua에서 접근 불가**: `ssl_session_cache shared:SSL:10m`은 Nginx SSL 모듈의 내장 shared memory이며, `lua_shared_dict`가 아니다. 따라서 `ngx.shared.*:flush_all()`로 flush할 수 없다.
- **무효화 전략 (HUP 시그널)**: 인증서 교체 시 `nginx -s reload` (HUP 시그널)을 사용한다. OpenResty에서 HUP은 worker를 graceful restart하므로 SSL 세션 캐시가 자연스럽게 초기화된다. 기존 연결은 old worker가 처리 완료할 때까지 유지되므로 무중단 교체가 가능하다.
- **대안 검토**: `ssl_session_tickets`의 ticket key rotation으로 구 세션을 만료시키는 방안도 있으나, 현재는 `ssl_session_tickets off` 설정(ticket key 관리 복잡도 회피)이므로 HUP 방식을 채택한다.
- **Hot Reload와의 관계**: 인증서 교체는 빈번한 작업이 아니므로(일반적으로 수개월 주기), HUP에 의한 worker graceful restart가 운영에 미치는 영향은 극소하다. DER 캐시 갱신(worker upvalue)은 `init_worker_by_lua` 타이머로 무중단 수행하되, SSL 세션 캐시 무효화만 HUP으로 처리한다.

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

### 9. 로그/메트릭 소유권 규칙 (Multi-port 중복 방지)

8443 → 8445 → 8444 경로에서 TLS terminate 세션은 8443과 8444 양쪽 server block에서 `log_by_lua`가 실행된다. 중복 로그/메트릭을 방지하기 위해 다음 소유권 규칙을 적용한다:

| 포트 | 조건 | 로그 | 메트릭 | 이유 |
|------|------|------|--------|------|
| 8443 | `tls_termination=true` (8444로 전달) | 억제 | 억제 | 내부 홉. 8444가 실제 세션 소유 |
| 8443 | `tls_termination=false` (패스스루) | 정상 출력 | 정상 카운트 | 8443이 최종 처리자 |
| 8444 | 항상 | 정상 출력 | 정상 카운트 | PROXY protocol로 전달받은 원본 IP/port 사용 |

**구현 방법:**

- 8443 `preread_by_lua`에서 `tls_termination=true` 판정 시 `ngx.ctx.luagate_stream.tls_termination = true` 설정
- 8443 `log_by_lua`에서 `ngx.ctx.luagate_stream.tls_termination == true`이면 로그 생성과 메트릭 카운트를 모두 스킵
- stream metrics(`luagate_stream_connections_total`, `luagate_active_connections{type="stream"}` 등)도 동일 규칙: 8443→8444 전달 세션은 8443에서 카운트하지 않고 8444에서만 카운트

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

Multi-port 구조로 패스스루와 터미네이션을 분리한다:

```nginx
stream {
    # ── Port 8443: 패스스루 진입점 ──
    # preread에서 프로토콜 탐지 + 정책 매칭 후 라우팅 결정
    # tls_termination=true → 8445(내부 PROXY protocol 전달 서버)로 라우팅
    # tls_termination=false → 업스트림 직접 패스스루
    server {
        listen 8443;
        # ssl 파라미터 없음 — TLS 핸드셰이크를 수행하지 않는다

        preread_by_lua_block {
            -- 프로토콜 탐지 + 정책 매칭
            -- tls_termination=true → $luagate_upstream = "127.0.0.1:8445"
            -- tls_termination=false → $luagate_upstream = 정책 upstream (패스스루)
            require("luagate.stream.handler").preread()
        }

        proxy_pass $luagate_upstream;

        log_by_lua_block {
            require("luagate.stream.handler").log()
        }
    }

    # ── Port 8445: PROXY protocol 전달 서버 (내부 전용) ──
    # 8443에서 tls_termination=true로 판정된 연결을 수신하여
    # PROXY protocol 헤더를 붙여 8444로 전달한다.
    # proxy_protocol on은 server 레벨 지시자이므로 별도 서버 블록이 필요하다.
    server {
        listen 8445;

        proxy_protocol on;  # 원본 클라이언트 메타데이터를 PROXY protocol v2로 전달
        proxy_pass 127.0.0.1:8444;
    }

    # ── Port 8444: TLS 터미네이션 서버 (내부 전용) ──
    server {
        listen 8444 ssl proxy_protocol;  # PROXY protocol로 원본 클라이언트 IP/port 수신

        # TLS 프로토콜/cipher 설정
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
        ssl_prefer_server_ciphers off;

        # 세션 캐시
        ssl_session_cache   shared:luagate_ssl_sessions:10m;
        ssl_session_timeout 1h;
        ssl_session_tickets off;

        # _default 인증서 (필수 — listen ssl에 ssl_certificate가 없으면 Nginx 기동 실패)
        # ssl_certificate_by_lua에서 SNI 기반으로 동적 교체됨
        # TLS 터미네이션 비활성화 시 이 server 블록 자체를 제거한다
        ssl_certificate     conf/certs/_default/fullchain.pem;
        ssl_certificate_key conf/certs/_default/privkey.pem;

        # PROXY protocol에서 원본 클라이언트 IP 사용
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        # 동적 인증서 선택 (Phase 순서: ssl_certificate_by_lua → preread_by_lua)
        ssl_certificate_by_lua_block {
            -- worker upvalue 캐시에서만 조회. 파일 I/O 없음.
            require("luagate.tls.ssl_handler").select_cert()
        }

        preread_by_lua_block {
            -- TLS 핸드셰이크 완료 후 실행. 복호화된 데이터 처리 가능.
            -- $proxy_protocol_addr로 원본 클라이언트 IP 조회 가능
            require("luagate.stream.handler").preread_terminated()
        }

        proxy_pass $luagate_upstream;

        log_by_lua_block {
            require("luagate.stream.handler").log()
        }
    }
}
```

> **Multi-port 설계 근거**: `listen ssl`을 선언하면 해당 서버의 모든 연결에 TLS 핸드셰이크가 강제되어 패스스루가 불가능하다. 또한 `proxy_protocol on`은 server 레벨 지시자이므로 패스스루 연결에도 적용되어 업스트림이 예기치 않은 PROXY protocol 헤더를 수신하게 된다. 따라서 세 개의 포트로 분리한다: Port 8443(진입점 + 패스스루), Port 8445(PROXY protocol 전달), Port 8444(TLS 터미네이션).
>
> **PROXY Protocol**: 8443 → 8445 → 8444 경로에서 8445가 `proxy_protocol on`으로 원본 클라이언트 IP/port를 전달한다. 8444에서는 `listen 8444 ssl proxy_protocol`로 수신하여 `$proxy_protocol_addr`를 src_ip로 사용한다. 이를 통해 감사 로그와 정책 평가에서 내부 홉(`127.0.0.1`) 대신 실제 클라이언트를 식별할 수 있다.
>
> **Port 8444/8445 접근 제한**: 외부에서 직접 접근하면 안 된다. 방화벽 규칙 또는 `allow 127.0.0.1; deny all;` (stream 모듈에서 지원 시)로 제한한다.

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
- 인증서 파일 교체 시 worker가 타이머로 자동 감지하여 새 TLS 핸드셰이크부터 적용. 단, 기존 세션 캐시의 완전 무효화가 필요하면 `nginx -s reload`를 수행한다
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
| SSL session resumption 시 인증서 교체 미반영 | 인증서 교체 시 `nginx -s reload` (HUP)로 worker graceful restart → SSL 세션 캐시 자연 초기화. §7 참조 |
| ACME 미지원으로 인한 수동 갱신 부담 | Phase 4에서 ACME 통합 예정. 현재는 외부 certbot + Admin API 업로드 워크플로 |

---

## Implementation Plan

1. **DON-231** (예정): `lua/luagate/tls/` 모듈 구현 (init, cert_manager, ssl_handler)
   - `init.lua`: `init_by_lua`에서 인증서 디렉토리 스캔, PEM→DER 변환, worker upvalue 초기화
   - `cert_manager.lua`: `init_worker_by_lua` 타이머로 `tls_certs_version` 변경 감지 및 백그라운드 재로드
   - `ssl_handler.lua`: `ssl_certificate_by_lua` 진입점 (캐시 조회만, 파일 I/O 없음)
2. `luagate_tls_certs` shared dict zone 추가 (`conf/nginx.conf`)
3. Multi-port stream 구성: Port 8443 (진입점/패스스루) + Port 8445 (PROXY protocol 전달) + Port 8444 (터미네이션, `ssl proxy_protocol` + `ssl_certificate_by_lua_block`)
4. stream rule 스키마에 `tls_termination` 필드 추가 (정책 검증 로직 수정)
5. Port 8443 `preread_by_lua`에서 `tls_termination=true` 시 `$luagate_upstream = "127.0.0.1:8445"` 설정 (8445가 PROXY protocol로 8444에 전달)
6. Admin API 인증서 업로드 엔드포인트 구현 (Phase 2) — 업로드 후 `nginx -s reload` (HUP)로 SSL 세션 캐시 무효화
7. ACME 자동 발급 통합 (Phase 4)
8. mTLS 지원 (Phase 4, 별도 ADR)

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) -- shared dict 구조, 실행 모델
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) -- versioned keyspace, atomic write 패턴
- [spec/stream-pipeline.md](../../spec/stream-pipeline.md) -- Stream 파이프라인, TLS 패스스루 (S10)
- [spec/rust-ffi-modules.md](../../spec/rust-ffi-modules.md) -- detect_protocol, SNI 추출
