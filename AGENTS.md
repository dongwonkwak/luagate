# AGENTS.md — LuaGate 공통 프로젝트 지침

> **대상**: Claude Code, Codex CLI, 모든 AI 코딩 도구
> **읽기 순서**: README → `.claude/knowledge/architecture.md` → 관련 spec → AGENTS.md → CLAUDE.md

## 프로젝트 개요

**LuaGate**: OpenResty(Nginx + LuaJIT) 기반 API/보안 게이트웨이.
HTTP 요청 및 TCP 스트림을 가로채어 정책 기반 허용/차단, 위협 탐지(Rust FFI), 로그/메트릭 수집을 수행한다.

**기술 스택**: OpenResty 1.25.x · LuaJIT 2.1 · Rust 1.75+ (cdylib) · YAML 정책 · Prometheus 메트릭 · NDJSON 로그

## Source Precedence

> ADR/Spec > Guide > AGENTS 요약 > 도구별 문서

충돌 시 항상 더 구체적이고 권위 있는 소스를 따른다.

## 핵심 아키텍처

- **단일 인스턴스 배포** — 수평 확장은 LB 뒤 다중 인스턴스
- **Worker 간 공유**: `ngx.shared.DICT` (mmap)만 사용, IPC 없음
- **C FFI**: 각 worker에서 `ffi.load()`, 동일 worker 내 동기 호출
- **정책 캐시**: module-level upvalue (`_cached_policy`, `_cached_version`) — `ngx.ctx` 아님
- **Stream 파이프라인**: `preread_by_lua` 기반 (HTTP의 `access_by_lua`에 해당하는 단계 없음)
- **Shared dict 원자성**: versioned keyspace (`policy:<hash>:blob`) + active pointer swap

## .claude/knowledge/ 참조 맵

| 작업 | 읽을 파일 |
|------|----------|
| Lua 모듈 작성 / 코드 리뷰 | `conventions.md`, `openresty-patterns.md` |
| 아키텍처 이해 / 파이프라인 | `architecture.md` |
| FFI 모듈 구현 / 수정 | `c-ffi-guide.md` |
| 보안 기능 구현 | `security-patterns.md` |
| 코드 리뷰 | `review-checklist.md` |
| 프로덕션 제한사항 확인 | `known-limitations-detail.md` |
| 신규 policy/zone/log 관련 | `architecture.md` (zone map) |

## docs/spec/ 참조 맵

| 작업 | 읽을 파일 |
|------|----------|
| HTTP 파이프라인 구현 | `docs/spec/http-pipeline.md` |
| Stream(TCP) 파이프라인 구현 | `docs/spec/stream-pipeline.md` |
| 정책 엔진 / Hot Reload | `docs/spec/policy-engine.md` |
| Admin API 구현 | `docs/spec/admin-api.md` |
| 로그 스키마 / 메트릭 | `docs/spec/log-schema.md` |
| C FFI 모듈 인터페이스 | `docs/spec/c-ffi-modules.md` |
| 보안 스캐너 | `docs/spec/security-scanner.md` |
| 전체 아키텍처 | `docs/spec/architecture.md` |
| ADR 목록 | `docs/design/adr/` |

## 코딩 컨벤션

- **Lua**: StyLua (`--indent-type Spaces --indent-width 4`) + luacheck
- **C/Rust**: clang-format + `cargo fmt` + `cargo clippy --deny warnings`
- 전역 변수 금지 — module-level local 또는 `ngx.ctx.luagate` 사용
- blocking I/O 금지 (핸들러 내 `io.open`, `os.execute` 등)

## 커밋 메시지 형식

```
<type>(<scope>): <description> [DON-XX]
```

type: `feat` | `fix` | `docs` | `test` | `refactor` | `chore` | `perf`

## 불변식 (항상 준수)

1. **zone prefix** `luagate_` 필수 (shared dict 이름 충돌 방지)
2. **보안 경로 fail-closed** — 스캐너/디코더 에러 시 deny
3. **`ngx.worker.id()` 사용** — PID(`ngx.worker.pid()`) 사용 금지
4. **Hot Reload 7단계 준수** — staged → validate → hash → blob store → pointer swap
5. **Same-PR 규칙** — 코드 변경과 문서/spec 변경은 같은 PR에 포함
6. **Linear 파일 경로 포인터** — 이슈 코멘트에 구현/테스트 파일 경로 포함

## 테스트 규칙

- Lua 단위 테스트: **busted**, 한국어 서술형 BDD (`describe`/`it`)
- 통합 테스트: **Test::Nginx** (Docker)
- C 단위 테스트: **CMocka** / `cargo test`
- OWASP 페이로드: `tests/fixtures/` 에서 로드
- 새 기능 = 새 테스트 (필수)

```bash
make test           # 전체 테스트
make test-unit      # Lua 단위 테스트만
make up             # Docker Compose 기동
make down           # Docker Compose 종료
```

## 변경 유형 → spec / 테스트 / 문서 매트릭스

| 변경 유형 | spec 갱신 | 테스트 필요 | ADR 필요 |
|----------|----------|------------|---------|
| HTTP 파이프라인 | http-pipeline.md | access_test, log_test | 설계 대안 2개+ 시 |
| Stream 파이프라인 | stream-pipeline.md | preread_test | 설계 대안 2개+ 시 |
| 정책 평가 규칙 | policy-engine.md | evaluator_test | 항상 |
| Admin API 엔드포인트 | admin-api.md | handler_test | 보안 변경 시 |
| FFI 모듈 변경 | c-ffi-modules.md | ffi_test (Lua + Rust) | 항상 |
| 로그 스키마 변경 | log-schema.md | 로그 형식 테스트 | PII 정책 변경 시 |
| 보안 패턴 추가 | security-scanner.md | OWASP 페이로드 테스트 | 새 탐지 카테고리 시 |

## 프로젝트 용어집

| 용어 | 정의 |
|------|------|
| zone | `ngx.shared.DICT` 단위 공유 메모리 영역 |
| envelope | 정책 blob 저장 컨테이너 (versioned keyspace) |
| LKG | Last-Known-Good — 새 버전 로드 실패 시 유지되는 이전 정책 |
| fail-closed | 에러 시 deny (보안 경로 기본값) |
| fail-open | 에러 시 allow (메트릭, 비보안 경로에서만 허용) |
| partial | 일부 기능만 구현된 MVP 단계 |
| preread | Stream 컨텍스트에서 프로토콜 탐지를 위한 초기 바이트 읽기 단계 |
| staged | API로 업로드되었으나 아직 active하지 않은 정책 버전 |
| active | 현재 트래픽에 적용 중인 정책 버전 |

## 금지 사항

- 핸들러에서 blocking I/O (`io.open`, `os.execute`, `os.time` 반복 호출)
- `log_by_lua`에서 cosocket (네트워크 I/O)
- Lua `io.write`/`io.open`으로 access.log 직접 작성
- 정책 캐시를 `ngx.ctx`에 저장
- shared dict zone 이름에 `luagate_` prefix 누락
- C 포인터를 Lua 테이블에 장기 저장
- Rust `free()` 함수 미호출 (메모리 누수)
