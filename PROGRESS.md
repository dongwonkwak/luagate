# LuaGate Progress

append-only 구현 일지. 각 이슈 완료 시 아래 형식으로 추가한다.

---

## 형식 (향후 이슈 완료 시 사용)

```
| YYYY-MM-DD | DON-XX | <제목> | <산출물 파일 경로> | <비고> |
```

---

## Phase 0-A: ADR 고정

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-12 | DON-85 | ADR-001: 실행/상태 공유 모델 | `docs/design/adr/ADR-001-execution-shared-state-model.md` | 완료 |
| 2026-03-12 | DON-86 | ADR-002: 정책 평가/충돌 탐지 | `docs/design/adr/ADR-002-policy-evaluation-conflict-detection.md` | 완료 |
| 2026-03-12 | DON-87 | ADR-003: 정책 저장/Hot Reload | `docs/design/adr/ADR-003-policy-storage-hot-reload.md` | 완료 |
| 2026-03-12 | DON-88 | ADR-004: 로그/메트릭/Admin/보안 | `docs/design/adr/ADR-004-log-metrics-admin-security.md` | 완료 |

## Phase 0-B: 프로젝트 스캐폴딩

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-12 | DON-89 | 디렉토리 구조 생성 | 전체 디렉토리 트리 | 완료 |
| 2026-03-12 | DON-90 | Docker/Nix 환경 | `Dockerfile`, `flake.nix`, `docker-compose.yml` | 완료 |
| 2026-03-12 | DON-91 | CLAUDE.md + AGENTS.md | `CLAUDE.md`, `AGENTS.md` | 완료 |
| 2026-03-12 | DON-93 | Phase 1 이슈 생성 | Linear 이슈 등록 | 완료 |
| 2026-03-12 | DON-94 | Makefile 초안 | `Makefile` | 완료 |
| 2026-03-12 | DON-95 | 기본 conf 파일 | `conf/` | 완료 |
| 2026-03-13 | DON-99 | 정책 의미론 닫기 | `docs/spec/policy-engine.md` | 리뷰 반영 |
| 2026-03-13 | DON-100 | 원자성 모델 정리 | `docs/spec/architecture.md` | 리뷰 반영 |
| 2026-03-13 | DON-101 | ADR-004 전체 반영 | `docs/design/adr/ADR-004-log-metrics-admin-security.md` | 리뷰 반영 |
| 2026-03-13 | DON-102 | 파이프라인 수정 | `docs/spec/http-pipeline.md` | 리뷰 반영 |
| 2026-03-13 | DON-103 | Makefile 보강 | `Makefile` | 리뷰 반영 |
| 2026-03-13 | DON-104 | CODEOWNERS 생성 | `CODEOWNERS` | 리뷰 반영 |
| 2026-03-13 | DON-107 | Claude Code 워크플로우 설계 | `.claude/` 전체 | 완료 |
| 2026-03-13 | DON-115 | skills/new-lua-module | `.claude/skills/new-lua-module/` | 완료 |
| 2026-03-13 | DON-116 | skills/new-api-endpoint | `.claude/skills/new-api-endpoint/` | 완료 |
| 2026-03-13 | DON-117 | skills/new-policy-rule 외 | `.claude/skills/` 전체 | 완료 |
| 2026-03-13 | DON-118 | agents/ 디렉토리 | `.claude/agents/` | 완료 |
| 2026-03-13 | DON-119 | CLAUDE.md 워크플로우 v1 적용 | `CLAUDE.md` | 완료 |

## Epic 4: Project Operations and Conventions

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-14 | DON-92 | PROGRESS.md 초기화 | `PROGRESS.md` | 완료 |
| 2026-03-14 | DON-96 | README.md 초안 작성 | `README.md` | 완료 |
| 2026-03-14 | DON-108 | README 전면 수정 | `README.md` | 리뷰 반영 |
| 2026-03-14 | DON-105 | PR 컨벤션 + PR 템플릿 | `.github/pull_request_template.md`, `AGENTS.md`, `CLAUDE.md`, `.claude/knowledge/conventions.md` | 완료 |
| 2026-03-14 | DON-106 | Git hooks 설정 | `.pre-commit-config.yaml`, `commitlint.config.js`, `flake.nix`, `Makefile` | 완료 |
| 2026-03-14 | DON-110 | test/doc strategy 강화 | `docs/spec/test-strategy.md`, `docs/spec/doc-strategy.md`, `Makefile` | 리뷰 반영 |
| 2026-03-14 | DON-111 | CONTRIBUTING.md 생성 | `CONTRIBUTING.md`, `README.md` | 완료 |

## Epic 5: Spec Review Fixes (DON-121)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-14 | DON-99 | 정책 의미론 닫기 | `docs/spec/policy-engine.md` | YAML schema, match operators, partial semantics |
| 2026-03-14 | DON-100 | 원자성 모델 정리 | `docs/spec/architecture.md` | envelope/state zone, Stream metrics, LKG, 실패 정책 |
| 2026-03-14 | DON-101 | ADR-004 전체 반영 | `docs/spec/http-pipeline.md`, `docs/spec/stream-pipeline.md` | 27/18필드, decision_source, ngx.var 목록 |
| 2026-03-14 | DON-102 | 파이프라인 수정 | `docs/spec/http-pipeline.md`, `docs/spec/stream-pipeline.md` | failure taxonomy, detection miss 매트릭스 |
| 2026-03-14 | DON-112 | log-schema 전면 수정 | `docs/spec/log-schema.md` | path_raw, null 계약, 기본값 전략, 예시 JSON 6개 |
| 2026-03-14 | DON-113 | security-scanner + admin-api 수정 | `docs/spec/security-scanner.md`, `docs/spec/admin-api.md` | 에러 3계층, 스캔 계약, 상태 머신, 에러 contract |
| 2026-03-14 | DON-114 | c-ffi-modules ABI 문서 격상 | `docs/spec/c-ffi-modules.md` | 헤더 시그니처, 에러 enum, radix lifecycle, fuzzing |

## Epic 5: Spec Review Fixes — Linear 상태 정리 (2026-03-15)

| 날짜 | 이슈 | 내용 |
|------|------|------|
| 2026-03-15 | DON-101~102, DON-112~114 | DON-121 리뷰 작업 중 선반영 확인 → Linear Done 전환. 모든 AC 충족. |

## Epic 6: Codex 리뷰 워크플로우 구현 (DON-128)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-14 | DON-129 | AGENTS.md 리뷰 불변식 추가 | `AGENTS.md`, `CLAUDE.md` | 완료 |
| 2026-03-14 | DON-130 | request-codex-review 스킬 생성 | `.claude/skills/request-codex-review/SKILL.md`, `review-template.md`, `result-template.md` | 완료 |
| 2026-03-14 | DON-131 | scripts/codex-review.sh 생성 + scripts/README.md | `scripts/codex-review.sh`, `scripts/README.md` | 완료 |
| 2026-03-14 | DON-132 | docs/workflow/codex-review.md 작성 | `docs/workflow/codex-review.md` | 완료 |

COMPLETED_REVIEW: DON-128-code (2026-03-14)
COMPLETED_REVIEW: DON-99-code (2026-03-15)
COMPLETED_REVIEW: DON-100-code (2026-03-15)
COMPLETED_REVIEW: epic-05-spec-review-fixes-design (2026-03-15)
COMPLETED_REVIEW: DON-123-design (2026-03-15)

## Phase 0-A: ADR 고정 (추가)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-15 | DON-123 | ADR-006: Metrics cardinality and export model | `docs/design/adr/ADR-006-metrics-cardinality-export-model.md`, `docs/design/adr/ADR-004-log-metrics-admin-security.md` (§4.3 수정), `docs/spec/architecture.md` (§3.2 수정), `docs/spec/log-schema.md` (§7 수정) | 2회 리뷰 완료. 보안 리뷰 PASS |
| 2026-03-15 | DON-124 | ADR-007: Log redaction and retention policy | `docs/design/adr/ADR-007-log-redaction-and-retention.md`, `docs/spec/log-schema.md`, `docs/design/adr/ADR-004-log-metrics-admin-security.md` (§4.2b 부분 대체 주석) | 2회 리뷰 완료. 보안 리뷰 PASS |

COMPLETED_REVIEW: DON-124-design (2026-03-15)

## Phase 1-Core: HTTP 프록시 + 정책 엔진

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-15 | DON-97 | Nginx conf template + HTTP reverse proxy basic setup | `conf/nginx.conf`, `tests/integration/http/test_nginx_basic.t` | shared dict 8개 선언, 보안 강화(admin IP 제한, server_tokens off, XFF 차단). 1회 Codex 리뷰 예정 |

COMPLETED_REVIEW: DON-97-code (2026-03-15)

COMPLETED_REVIEW: DON-133-code (2026-03-15)

## Phase 1-Infra: Docker + 벤치마크 + CI

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-15 | DON-133 | Docker 기반 Test::Nginx 테스트 환경 구축 | `Dockerfile.test`, `docker-compose.test.yml`, `.github/workflows/integration-test.yml` | busted 2.3.0 포함, non-root 실행, CI permissions:read. 미반영: 인라인 테스트 구조 + admin auth 계약 충돌 별도 이슈 예정 |

| 2026-03-16 | DON-106 | Git hooks 설정 (detect-secrets 보완) | `.pre-commit-config.yaml`, `.secrets.baseline`, `scripts/detect-secrets-hook-wrapper.sh`, `scripts/shellcheck-wrapper.sh`, `flake.nix` | detect-secrets hook 추가, CI fail-hard, --baseline 인자 수정. Codex 리뷰 반영 완료 |

COMPLETED_REVIEW: DON-106-code (2026-03-16)

COMPLETED_REVIEW: DON-134-code (2026-03-16)

## Phase 1-Core: Admin Auth 테스트 수정 (DON-134)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-16 | DON-134 | admin auth 테스트를 admin-auth-contract.md 계약에 맞게 수정 | `tests/integration/http/test_nginx_basic.t`, `conf/nginx.conf`, `Makefile`, `docs/spec/admin-api.md` | TEST 25 신규 추가, constant-time compare 구현, WWW-Authenticate 제거. 보안 리뷰 PASS |

## Phase 1-Core: YAML policy parser + schema validator (DON-98)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-16 | DON-98 | YAML policy parser + schema validator | `lua/luagate/policy/parser.lua`, `lua/luagate/policy/validator.lua`, `tests/unit/policy/parser_spec.lua`, `tests/unit/policy/validator_spec.lua` | 95개 busted 테스트 통과. Codex 리뷰 대기 |
| 2026-03-16 | DON-98 | Codex 리뷰 피드백 반영 (3건) | `lua/luagate/policy/parser.lua`, `lua/luagate/policy/validator.lua`, `tests/unit/policy/parser_spec.lua`, `tests/unit/policy/validator_spec.lua` | 비리스트 입력 guard, upstream host:port 형식 검증, CIDR/port-range 형식 검증 추가. 115개 busted 테스트 통과 |
| 2026-03-16 | DON-98 | 보안 리뷰 수정 (M-1, R-2, R-3) | `lua/luagate/policy/validator.lua`, `tests/unit/policy/validator_spec.lua` | CIDR octet/prefix 범위 검증, port 1-65535 범위 검증. 132개 busted 테스트 통과. 보안 리뷰 PASS |

COMPLETED_REVIEW: DON-98-code (2026-03-16)

COMPLETED_REVIEW: DON-103-code (2026-03-16)
| 2026-03-16 | DON-103 | GitHub Actions: PR file detection codex review auto directive | `.github/workflows/codex-review.yml` | 9개 카테고리 감지, 페이지네이션, 중복 코멘트 방지. Codex 리뷰 2건 반영. 보안 리뷰 PASS |

## Phase 0-B: 워크플로우 설계서 v2 (DON-127)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-16 | DON-127 | Update workflow design doc v2 after Phase 0-B completion | Linear 문서 `24e2cc7ac680` (v1 → v2) | 에이전트 frontmatter 정확화, 스킬 이름 정정(doc-sync-hook→doc-sync), ADR-005~007 반영, 구현 완료 항목 표시. ADR-005 파일 미생성 사실 명시 |

## Phase 0-A: ADR-005 파일 생성 (DON-135)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-16 | DON-135 | ADR-005 파일 생성 (architect) | `docs/design/adr/ADR-005-policy-activation-concurrency.md` | 설계 리뷰 대기 중 |

COMPLETED_REVIEW: DON-135-design (2026-03-16)
COMPLETED_REVIEW: DON-135-code (2026-03-16)

## Phase 1-Infra: pr-review-context 스킬 (DON-104)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-104 | Claude Code skill: knowledge-based codex review context on PR creation | `.claude/skills/pr-review-context/SKILL.md`, `CLAUDE.md` (PR 워크플로우 + skills 테이블) | 16개 파일 패턴 매핑, 출력 예시 포함 |

COMPLETED_REVIEW: DON-138-code (2026-03-17)

## Phase 1-Core: policy/loader.lua Hot Reload 7단계 (DON-138)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-138 | policy/loader.lua — Hot Reload 7단계 구현 | `lua/luagate/policy/loader.lua`, `tests/unit/policy/loader_spec.lua`, `conf/nginx.conf` | 290 tests, Codex 3개+Security 2개 피드백 반영 |

## Phase 1-Core: HTTP 파이프라인 핸들러 통합 (DON-140)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-140 | HTTP 파이프라인 핸들러 통합 — rewrite/access/log_by_lua | `lua/luagate/http/handler.lua`, `lua/luagate/log/http.lua`, `lua/luagate/metrics/collector.lua`, `conf/nginx.conf`, `tests/unit/http/handler_spec.lua`, `tests/unit/log/http_spec.lua`, `tests/unit/metrics/collector_spec.lua`, `tests/integration/http/pipeline_spec.t` | 395 tests. Codex 4건 + 보안 리뷰 PASS (H-1/M-1/M-3/L-1/L-2) |

COMPLETED_REVIEW: DON-140-code (2026-03-17)

## Phase 1-Core: luagate_decoder.so Rust FFI + Lua 바인딩 (DON-139)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-139 | luagate_decoder.so Rust FFI + Lua 바인딩 | `src/decoder/Cargo.toml`, `src/decoder/src/lib.rs`, `lua/luagate/decoder/ffi.lua`, `tests/unit/decoder/ffi_spec.lua`, `Makefile` (build-ffi 타겟), `lib/.gitkeep` | 15 Rust + 18 Lua 단위 테스트. caller-allocated buffer, pcall 래핑, 1회 재시도 패턴. |

COMPLETED_REVIEW: DON-139-code (2026-03-17)

## Phase 1-Security: luagate_scanner.so Rust FFI + Lua 바인딩 (DON-141)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-141 | luagate_scanner.so Rust FFI + Lua binding | `src/scanner/Cargo.toml`, `src/scanner/src/lib.rs`, `conf/scanner-patterns/*.yaml` (8개), `lua/luagate/scanner/ffi.lua`, `tests/unit/scanner/ffi_spec.lua` | Rust 11 tests + Lua 22 tests (총 419 busted tests 통과). caller-allocated buffer, 5ms budget, 8KB limit, 8개 threat_type, panic=abort |

COMPLETED_REVIEW: DON-141-code (2026-03-17)

COMPLETED_REVIEW: DON-153-code (2026-03-17)

## Infra: Codex review 스크립트 worktree 호환성 (DON-153)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-153 | codex review 스크립트 git worktree 호환성 확보 | `scripts/codex-review.sh`, `scripts/codex-address-pr-review.sh`, `docs/workflow/codex-review.md`, `scripts/README.md` | MAIN_ROOT/WORKTREE_ROOT 분리, worktree 무인자 실행 차단, 문서 반영. Codex 리뷰 3건 반영 |

## Phase 1-Core: HTTP 로그 + 메트릭 수집 (DON-137)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-137 | HTTP 로그 + 메트릭 수집 | `lua/luagate/log/http.lua`, `lua/luagate/metrics/collector.lua`, `tests/unit/log/http_spec.lua`, `tests/unit/metrics/collector_spec.lua` | DON-140에서 이미 구현 완료 확인. 27필드 JSON, 리댁션, 히스토그램 포함 |

## Phase 1-Security: access_by_lua 보안 스캐너 통합 (DON-142)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-142 | decoder + scanner HTTP 파이프라인 통합 | `lua/luagate/http/handler.lua`, `lua/luagate/metrics/collector.lua`, `tests/unit/http/handler_spec.lua`, `tests/unit/metrics/collector_spec.lua` | 454 tests 통과. decoder→scanner→policy eval 순서, fail-closed, 8KB 제한, scanner threat 메트릭 추가 |

COMPLETED_REVIEW: DON-142-code (2026-03-17)

COMPLETED_REVIEW: DON-142-code (2026-03-17)

COMPLETED_REVIEW: DON-145-code (2026-03-17)

## Phase 1-Admin: Admin API Bearer token 인증 모듈 (DON-145)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-17 | DON-145 | lua/luagate/admin/auth.lua — Bearer token 인증 모듈 | `lua/luagate/admin/auth.lua`, `tests/unit/admin/auth_spec.lua`, `.claude/knowledge/security-patterns.md` | 497 tests 통과. Codex 4건 반영 (startup-fatal error(), OPTIONS preflight, audit ERR 레벨, TEST 25 wiring → DON-146 범위). 보안 리뷰 PASS |

## Phase 1-Stream: luagate_stream.so Rust FFI + Lua 바인딩 (DON-143)

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-18 | DON-143 | luagate_stream.so Rust FFI + Lua 바인딩 + stream handler | `src/stream/Cargo.toml`, `src/stream/src/lib.rs`, `lua/luagate/stream/ffi.lua`, `lua/luagate/stream/handler.lua`, `tests/unit/stream/ffi_spec.lua`, `tests/unit/stream/handler_spec.lua`, `Makefile`, `conf/nginx.conf` | Rust 23 + Lua 66 테스트 (총 564 busted). 설계 리뷰 대기 |
| 2026-03-18 | DON-143 | 설계 리뷰 피드백 5건 수정 | `src/stream/src/lib.rs`, `lua/luagate/stream/handler.lua`, `tests/unit/stream/handler_spec.lua` | Rust 23 + Lua 570 테스트 통과. 피드백: (1) preread 주석 추가 + raw=true, (2) NEED_MORE_DATA 재시도 루프 + malformed TLS fail-closed, (3) radix tree 실제 연결, (4) Vec→trie, (5) CONNECT 제거 |

COMPLETED_REVIEW: DON-143-design (2026-03-18)

COMPLETED_REVIEW: DON-143-code (2026-03-18)
