# ADR-003: 정책 저장소 + Hot Reload Semantics

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-13 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-87](https://linear.app/dongwon/issue/DON-87) |
| **Depends on** | [ADR-002](./ADR-002-policy-evaluation-conflict-detection.md) |

---

## Status

**Accepted** — Phase 0-A에서 고정.

---

## Context

정책 규칙은 운영 중에 변경될 수 있다(보안 패턴 업데이트, IP 차단 추가 등).
변경 시 서비스 중단 없이 새 정책을 적용해야 한다.

해결해야 할 문제:

1. **정책 저장소**: 정책의 canonical source는 무엇인가?
2. **변경 API**: 어떤 인터페이스로 정책을 수정하는가?
3. **Reload 트리거**: 어떤 방식으로 새 정책을 로드하는가?
4. **원자성**: 일부 worker만 새 정책을 보는 상황을 방지하는가?
5. **실패 안전성**: 새 정책이 유효하지 않을 때 어떻게 처리하는가?
6. **버전 관리**: 어느 정책이 현재 활성인지 추적하는가?

---

## Decision

### §3.3 정책 저장소

#### Canonical source: YAML 파일 (file-backed)

- 정책의 단일 진실의 원천은 파일시스템의 YAML 파일이다.
- 기본 경로: `conf/policies.yaml` (Nginx config 디렉토리 기준)
- 런타임 상태(shared dict)는 이 파일로부터 파생된다.

**Admin API에 의한 수정:**

- Admin API(`PUT /api/v1/policies`)가 YAML 파일을 직접 수정한다.
- 쓰기는 **atomic write** 방식:
  1. 임시 파일(`policies.yaml.tmp`)에 새 내용 기록
  2. `rename()` 시스템 콜로 원자적 교체
  3. 실패 시 임시 파일 삭제, 원본 보존

### §3.4 Hot Reload 시맨틱스

**Reload 트리거 (두 가지):**

1. **HUP 시그널**: `kill -HUP <nginx_master_pid>`
2. **Admin API**: `POST /api/v1/policies/reload`

**HUP와 Admin API의 의미 차이:**

| 트리거 | 실행 주체 | 의미 |
|--------|-----------|------|
| `kill -HUP <nginx_master_pid>` | Nginx master | nginx.conf 재파싱 + 새 worker 기동 + 기존 worker graceful shutdown |
| `POST /api/v1/policies/reload` | Admin API를 처리 중인 worker | 정책 파일 재검증 + shared dict versioned keyspace 갱신 + active pointer 교체 |

**Admin API reload 과정 (순서 보장):**

```mermaid
sequenceDiagram
    participant T as Trigger(API)
    participant A as AdminHandler(worker)
    participant FS as FileSystem
    participant V as Validator
    participant CD as ConflictDetector
    participant SD as ngx.shared.DICT
    participant W as Workers

    T->>A: POST /api/v1/policies/reload
    A->>SD: add("reload_lock", worker_pid, 5s)
    alt lock already exists
        SD-->>A: false
        A-->>T: 409 ReloadInProgress
    else lock acquired
        A->>FS: YAML 파일 읽기
        FS-->>A: file content
        A->>V: Schema validation
    alt 유효하지 않은 스키마
        V-->>A: 검증 실패
        A->>A: last-known-good 유지
        A->>A: ERROR 로그 기록
        A->>SD: delete("reload_lock")
        A-->>T: 400 Bad Request
    else 스키마 유효
        V-->>A: 검증 통과
        A->>CD: 충돌/음영 감지 (ADR-002)
        CD-->>A: 경고 목록
        A->>A: SHA256 해시 계산 (new_version)
        A->>SD: set("policy:<new_version>:blob", ...)
        A->>SD: set("policy:<new_version>:meta", ...)
        Note over A,SD: commit 단계 — HTTP/Stream 서브시스템 독립적으로 pointer swap
        A->>SD: set("http:active_version", new_version)
        Note over SD: HTTP pointer swap 완료 (원자적 단위: 단일 key write)
        A->>SD: set("stream:active_version", new_version)
        Note over SD: Stream pointer swap 완료
        A->>SD: set("source_version", new_version)
        A->>SD: delete("reload_lock")
        A->>A: 충돌 경고 로그 기록
        A-->>T: 200 OK
        Note over W: 다음 요청 처리 시
        W->>SD: http:active_version 확인 (HTTP worker)
        alt 버전 변경 감지
            W->>SD: policy:<version>:blob 로드
        end
    end
```

**정책 버전 관리:**

- 버전 식별자: 정책 파일 전체 내용의 **SHA256 해시** (16진수 문자열)
- 저장 위치: `luagate_policy` shared dict — **HTTP/Stream 서브시스템 분리 키**:
  - `http:active_version` — HTTP 서브시스템 활성 버전 pointer
  - `stream:active_version` — Stream 서브시스템 활성 버전 pointer
  - `source_version` — canonical source 파일 SHA256 (PUT ETag/If-Match 기준)
- 모든 요청 로그 및 메트릭에 현재 `policy_version` 포함
- 예: `policy_version: "a3f2c1d4e5b6..."`

**Partial commit (HTTP/Stream 독립적 commit):**

commit 단계([7])에서 HTTP와 Stream의 pointer swap은 독립적으로 수행된다.
한쪽 서브시스템의 pointer swap이 실패해도 성공한 서브시스템의 버전은 교체된 상태를 유지한다.
실패한 서브시스템은 active pointer가 변경되지 않으므로 **롤백 불필요** — 이전 blob/meta가 shared dict에 그대로 유지된다.

| 시나리오 | HTTP active_version | Stream active_version |
|----------|--------------------|-----------------------|
| 전체 성공 | new_version | new_version |
| HTTP 성공, Stream 실패 | new_version | 이전 버전 유지 |
| HTTP 실패, Stream 성공 | 이전 버전 유지 | new_version |
| 전체 실패 | 이전 버전 유지 | 이전 버전 유지 |

**Worker 전파 메커니즘:**

각 worker는 요청 처리 시작 시(`access_by_lua_block` 진입 전):
1. HTTP: `luagate_policy:get("http:active_version")`으로 shared dict 버전 확인
2. 로컬 캐시 버전과 다르면 `policy:<version>:blob`를 shared dict에서 읽어 worker module upvalue에 캐시
3. 로컬 버전 업데이트
4. 요청 처리 계속

Stream worker는 동일한 방식으로 `stream:active_version`을 확인한다.
이 방식으로 reload 완료 후 **모든 worker가 다음 요청 시** 새 정책을 사용한다.

**실패 안전성 (last-known-good):**

| 실패 시나리오 | 동작 |
|--------------|------|
| YAML 파싱 오류 | last-known-good 유지, ERROR 로그 |
| Schema 검증 실패 | last-known-good 유지, ERROR 로그 |
| 충돌 감지 | 로드 계속, WARN 로그 |
| shared dict 쓰기 실패 | last-known-good 유지, ERROR 로그, `http:active_version` / `stream:active_version` 미변경 |
| 동시 reload 요청 | 첫 요청만 lock 획득, 나머지는 `409 ReloadInProgress` 반환 |

서버 최초 기동 시 정책 로드 실패 → 서버 시작 실패(fatal).

---

## Consequences

### 긍정적 결과

- **무중단 업데이트**: 정책 변경 시 Nginx worker 재시작 불필요
- **원자성**: versioned keyspace(blob + meta) 저장 후 `http:active_version` / `stream:active_version` 단일 키 교체(pointer swap)로 partial update 방지. 서브시스템별 독립 commit으로 한쪽 실패 시에도 성공한 서브시스템은 새 버전 적용
- **실패 안전**: last-known-good 보장으로 잘못된 정책이 적용되지 않음
- **감사 추적**: 모든 로그/메트릭에 policy_version 포함

### 부정적 결과

- **전파 지연**: worker가 새 정책을 인식하는 시점이 "다음 요청 시"이므로,
  reload 직후 들어온 요청은 구 정책으로 처리될 수 있음 (수 ms 단위)
- **단일 reload 직렬화**: reload lock을 사용하므로 동시에 여러 운영자가 reload하면 일부 요청은 `409`를 받는다
- **파일 시스템 의존**: YAML 파일이 canonical source이므로 디스크 장애 시 정책 복구 불가.
  정책 파일 백업 정책 필요
- **단일 파일 한계**: 정책 수가 매우 많아지면 단일 YAML 파일이 관리하기 어려워질 수 있음.
  멀티 파일 지원은 별도 ADR에서 결정

### 향후 고려

- 정책 변경 이력(git 기반) 관리 도구 연동 검토
- 대규모 정책(1000+ 규칙) 성능 측정 후 파싱 최적화 ADR 추가 가능

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) — shared dict 구조
- [ADR-002](./ADR-002-policy-evaluation-conflict-detection.md) — 충돌 감지 (reload 과정에 포함)
- [spec/policy-engine.md](../../spec/policy-engine.md) — 정책 엔진 상세 스펙
- [spec/admin-api.md](../../spec/admin-api.md) — Admin API 엔드포인트 스펙
