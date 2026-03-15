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
PENDING_REVIEW: epic-05-spec-review-fixes-design
