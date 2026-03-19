# AGENTS.md — LuaGate 공통 프로젝트 지침

> **대상**: Claude Code, Codex CLI, 모든 AI 코딩 도구
> **읽기 순서**: README → `.claude/knowledge/architecture.md` → 관련 spec → AGENTS.md → CLAUDE.md

## 프로젝트 개요

**LuaGate**: OpenResty(Nginx + LuaJIT) 기반 API/보안 게이트웨이.
HTTP 요청 및 TCP 스트림을 가로채어 정책 기반 허용/차단, 위협 탐지(Rust FFI), 로그/메트릭 수집을 수행한다.

**기술 스택**: OpenResty 1.25.x · LuaJIT 2.1 · Rust 1.75+ (cdylib) · YAML 정책 · Prometheus 메트릭 · NDJSON 로그

## Source Precedence

> **ADR/Spec > Guide > AGENTS 요약 > 도구별 문서**

충돌 시 항상 더 구체적이고 권위 있는 소스를 따른다.
예: `docs/spec/policy-engine.md §4`와 AGENTS 요약이 다르면 spec을 따른다.

## 핵심 아키텍처

- **단일 인스턴스 배포** — 수평 확장은 LB 뒤 다중 인스턴스
- **Worker 간 공유**: `ngx.shared.DICT` (mmap)만 사용, IPC 없음
- **Rust FFI**: 각 worker에서 `ffi.load()`, 동일 worker 내 동기 호출
- **정책 캐시**: module-level upvalue (`_cached_policy`, `_cached_version`) — `ngx.ctx` 아님
- **Stream 파이프라인**: `preread_by_lua` 기반 (HTTP의 `access_by_lua`에 해당하는 단계 없음)
- **Shared dict 원자성**: versioned keyspace (`policy:<hash>:blob`) + active pointer swap

## 불변식 (항상 준수 — 예외 없음)

1. **`luagate_` prefix 필수** — 모든 `ngx.shared.DICT` zone 이름 (네임스페이스 충돌 방지)
2. **보안 경로 fail-closed** — 스캐너/디코더/FFI 에러 시 deny (fail-open은 메트릭 실패에만 허용)
3. **`ngx.worker.id()` 사용** — `ngx.worker.pid()` 사용 금지 (reload 시 PID 변경)
4. **Hot Reload 7단계 준수** — staged → validate → hash → blob store → pointer swap (실패 시 LKG 유지)
5. **Same-PR 규칙** — 코드 변경과 문서/spec 변경은 같은 PR에 포함
6. **Linear 파일 경로 포인터** — 이슈 코멘트에 구현/테스트 파일 경로 포함
7. **이슈 시작 전 브랜치 생성 필수** — 사용자가 이슈 진행을 승인하는 순간 다른 어떤 작업보다 먼저 브랜치를 생성한다. 첫 번째 파일 수정 전 Linear `gitBranchName`으로 브랜치를 반드시 생성. main/epic 브랜치에 직접 커밋 금지.
   - **한글 제거 필수**: `gitBranchName`에 한글이 포함된 경우 한글 부분을 제거하고 남은 연속 하이픈(`--`)을 단일 하이픈(`-`)으로 정리한다.
   - 예: `dongwonkwak/don-106-git-hooks-설정-pre-commit` → `dongwonkwak/don-106-git-hooks-pre-commit`
   - (`git checkout -b <sanitized-branch-name>`)
8. **spec/ADR 수정 시 sync-spec 필수** — `docs/spec/` 또는 `docs/design/adr/` 파일을 수정한 경우, 이슈 완료(Done 전환) 전에 반드시 `sync-spec` 스킬을 invoke하여 Linear 문서를 동기화한다.

## 리뷰 관련 불변식

- **result-template.md 경로 명시** — Codex 리뷰 지시 시 반드시 경로 명시:
  `.claude/skills/request-codex-review/result-template.md`
- **Codex 역할 제한** — Codex 역할은 리뷰(찾기)만. 수정은 사람의 별도 지시로만 수행
- **완료 항목 기입 형식** — 수정 완료 항목은 반드시 아래 형식으로 result.md에 기입:
  ```
  - [x] 피드백 내용
        → 해결자: Claude Code / Codex
        → 해결 방식: (한 줄 요약)
  ```
- **재리뷰 시 기해결 항목 지적 금지** — 기존 `[x]` 항목은 추가 지적하지 않음. 미해결 항목만 재검토
- **테스트 실행 주체** — 테스트 실행은 사람이 수동으로 요청. Claude Code는 수정만 수행, Codex는 리뷰만 수행

## .claude/knowledge/ 참조 맵 (전체 18개)

| 파일 | 내용 | 참조 시점 |
|------|------|---------|
| `conventions.md` | 코딩/커밋/브랜치 규칙 | 코드 작성 시 |
| `architecture.md` | 아키텍처 요약, zone map, hot reload 7단계 | 파이프라인/zone 관련 작업 |
| `openresty-patterns.md` | 패턴/안티패턴/gotchas | Lua 핸들러 작성 시 |
| `rust-ffi-guide.md` | FFI unsafe 경고 + 메모리 관리 규칙 | FFI 코드 작성 시 |
| `security-patterns.md` | precedence matrix, OWASP 기준, Admin 보안 | 보안 기능 구현 시 |
| `review-checklist.md` | 코드 리뷰 체크리스트 (커버리지 상태 포함) | PR 리뷰 시 |
| `known-limitations-detail.md` | MVP vs 영구 제약 (내부용) | 프로덕션 갭 확인 시 |
| `policy-evaluation-pseudocode.md` | 정책 평가 의사코드 전체 흐름 | 정책 엔진 구현 시 |
| `hot-reload-paths.md` | write/read path, version bump, L1 invalidate, rollback | Hot Reload 구현 시 |
| `zone-registry.md` | zone별 value shape, TTL, safe_set, fail mode | zone 추가/수정 시 |
| `admin-auth-contract.md` | 인증 헤더, timing-safe compare, 401 body, rate limit | Admin API 인증 구현 시 |
| `logging-contract.md` | native vs Lua log, decision fields, PII redaction | 로그 관련 작업 시 |
| `ffi-abi-contract.md` | 함수별 ownership, NULLability, max length, error code | FFI 함수 추가 시 |
| `frontend-conventions.md` | 프론트엔드 코딩 컨벤션 (React/TS/Tailwind) | UI 구현 시 |
| `ui-review-checklist.md` | UI 코드 리뷰 체크리스트 (TypeScript/React/Playwright) | UI PR 리뷰 시 |
| `parallel-work.md` | git worktree 기반 병렬 작업 가이드 | 병렬 작업 시 |
| `interview-points.md` → `docs/human/` | 면접 포인트 (DON-116에서 이동) | — |
| `portfolio-synergy.md` → `docs/human/` | 포트폴리오 시너지 (DON-116에서 이동) | — |

## docs/spec/ 참조 맵

| 작업 | 읽을 파일 |
|------|----------|
| HTTP 파이프라인 구현 | `docs/spec/http-pipeline.md` |
| Stream(TCP) 파이프라인 구현 | `docs/spec/stream-pipeline.md` |
| 정책 엔진 / Hot Reload | `docs/spec/policy-engine.md` |
| Admin API 구현 | `docs/spec/admin-api.md` |
| 로그 스키마 / 메트릭 | `docs/spec/log-schema.md` |
| Rust FFI 모듈 인터페이스 | `docs/spec/rust-ffi-modules.md` |
| 보안 스캐너 | `docs/spec/security-scanner.md` |
| 전체 아키텍처 | `docs/spec/architecture.md` |
| ADR 목록 | `docs/design/adr/` |

## 코딩 컨벤션

- **Lua**: StyLua (`--indent-type Spaces --indent-width 4`) + luacheck
- **Rust**: `cargo fmt` + `cargo clippy --deny warnings`. clang-format은 C 헤더 포맷용으로 유지
- 전역 변수 금지 — module-level local 또는 `ngx.ctx.luagate` 사용
- blocking I/O 금지 (핸들러 내 `io.open`, `os.execute` 등)

## 커밋 메시지 형식

```
<type>(<scope>): <description> [DON-XX]
```

type: `feat` | `fix` | `docs` | `test` | `refactor` | `chore` | `perf`

## Git Hooks 설치

신규 클론 후 반드시 실행:
```bash
make install-hooks
```
pre-commit (lint/format) + commit-msg (commitlint) + pre-push (test-unit) hooks 등록.

## PR 컨벤션 요약

- **PR 제목**: `type(scope): 설명 [DON-XX]` (커밋 메시지와 동일 형식)
- **머지 전략**: Squash merge (epic → main), Merge commit (issue → epic)
- **리뷰**: CI 통과 + 최소 1개 승인 필수. 보안 변경 시 `security-reviewer` 에이전트 호출.
- **PR 템플릿**: `.github/pull_request_template.md` 자동 적용
- **Same-PR 규칙**: 코드/문서/spec 변경은 같은 PR에 포함

## 테스트 규칙

- Lua 단위 테스트: **busted**, 한국어 서술형 BDD (`describe`/`it`)
- 통합 테스트: **Test::Nginx** (Docker)
- Rust 단위 테스트: `cargo test`
- OWASP 페이로드: `tests/fixtures/` 에서 로드
- 새 기능 = 새 테스트 (필수)

```bash
make test           # 전체 테스트
make test-unit      # Lua + Rust 단위 테스트
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
| FFI 모듈 변경 | rust-ffi-modules.md | ffi_test (Lua + Rust) | 항상 |
| 로그 스키마 변경 | log-schema.md | 로그 형식 테스트 | PII 정책 변경 시 |
| 보안 패턴 추가 | security-scanner.md | OWASP 페이로드 테스트 | 새 탐지 카테고리 시 |
| Shared dict zone 추가 | architecture.md zone map | zone 초기화 테스트 | 항상 |

## 프로젝트 용어집

| 용어 | 정의 |
|------|------|
| zone | `ngx.shared.DICT` 단위 공유 메모리 영역 (`luagate_policy` 등) |
| envelope | 정책 blob 저장 컨테이너 (versioned keyspace: `policy:<hash>:blob`) |
| LKG | Last-Known-Good — 새 버전 로드 실패 시 유지되는 이전 정책 |
| fail-closed | 에러 시 deny (보안 경로 기본값) |
| fail-open | 에러 시 allow (메트릭, 비보안 경로에서만 허용) |
| partial | 일부 기능만 구현된 MVP 단계 |
| preread | Stream 컨텍스트에서 프로토콜 탐지를 위한 초기 바이트 읽기 단계 |
| staged | API로 업로드되었으나 아직 active하지 않은 정책 버전 |
| active | 현재 트래픽에 적용 중인 정책 버전 |
| L1 cache | Worker-level module upvalue 캐시 (`_cached_policy`) |
| active pointer | `luagate_policy:get("active_policy_version")` — 현재 active blob 키 |

## 금지 사항

- 핸들러에서 blocking I/O (`io.open`, `os.execute`)
- `log_by_lua`에서 cosocket (네트워크 I/O)
- Lua `io.write`/`io.open`으로 access.log 직접 작성 (Nginx native 사용)
- 정책 캐시를 `ngx.ctx`에 저장
- shared dict zone 이름에 `luagate_` prefix 누락
- C 포인터를 Lua 테이블에 장기 저장 (dangling pointer)
- Rust `free()` 함수 미호출 (메모리 누수)
- `ngx.worker.pid()` 사용 (reload 시 불안정)
