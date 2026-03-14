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
| 2026-03-12 | DON-85 | ADR-001: OpenResty 선택 | `docs/adr/ADR-001-openresty.md` | 완료 |
| 2026-03-12 | DON-86 | ADR-002: Lua 정책 엔진 | `docs/adr/ADR-002-lua-policy-engine.md` | 완료 |
| 2026-03-12 | DON-87 | ADR-003: Rust FFI | `docs/adr/ADR-003-rust-ffi.md` | 완료 |
| 2026-03-12 | DON-88 | ADR-004: 감사 로그 설계 | `docs/adr/ADR-004-audit-log.md` | 완료 |

## Phase 0-B: 프로젝트 스캐폴딩

| 날짜 | 이슈 | 제목 | 산출물 | 비고 |
|------|------|------|--------|------|
| 2026-03-12 | DON-89 | 디렉토리 구조 생성 | 전체 디렉토리 트리 | 완료 |
| 2026-03-12 | DON-90 | Docker/Nix 환경 | `Dockerfile`, `flake.nix`, `docker-compose.yml` | 완료 |
| 2026-03-12 | DON-91 | CLAUDE.md + AGENTS.md | `CLAUDE.md`, `AGENTS.md` | 완료 |
| 2026-03-12 | DON-93 | Phase 1 이슈 생성 | Linear 이슈 등록 | 완료 |
| 2026-03-12 | DON-94 | Makefile 초안 | `Makefile` | 완료 |
| 2026-03-12 | DON-95 | 기본 conf 파일 | `conf/` | 완료 |
| 2026-03-13 | DON-99 | 정책 의미론 닫기 | `docs/spec/policies.md` | 리뷰 반영 |
| 2026-03-13 | DON-100 | 원자성 모델 정리 | `docs/spec/hot-reload.md` | 리뷰 반영 |
| 2026-03-13 | DON-101 | ADR-004 전체 반영 | `docs/adr/ADR-004-audit-log.md` | 리뷰 반영 |
| 2026-03-13 | DON-102 | 파이프라인 수정 | `docs/spec/pipeline.md` | 리뷰 반영 |
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
