# CLAUDE.md — Claude Code 전용 지침

> **공통 프로젝트 지침**: → [AGENTS.md](./AGENTS.md) 참조 (코딩 컨벤션, 불변식, 용어집, spec 참조 맵)
> **읽기 순서**: AGENTS.md → CLAUDE.md

## Claude Code 역할: Coordinator

CLAUDE.md는 Claude Code의 **coordinator** 역할을 정의한다.
서브에이전트는 상호 직접 호출하지 않으며, 항상 coordinator(CLAUDE.md)를 통해 조율된다.

### 항상 적용 규칙 (skill invoke 없이도 적용)

- AGENTS.md 불변식 전체 (`luagate_` prefix, fail-closed, `ngx.worker.id()`, hot reload 7단계, same-PR)
- AGENTS.md 리뷰 관련 불변식 (Codex 역할 제한, result-template.md 경로 명시, 재리뷰 기해결 항목 지적 금지)
- **이슈 시작 전 브랜치 생성** — 사용자 승인 직후 즉시 `git checkout -b <Linear gitBranchName>` 실행. 상세 규칙: [AGENTS.md 불변식 7](./AGENTS.md)
- **spec/ADR 수정 시 sync-spec 필수** — `docs/spec/` 또는 `docs/design/adr/` 변경 시 Done 전환 전 `sync-spec` 스킬 invoke (AGENTS.md 불변식 8)
- `ngx.ctx`에 정책 캐시 저장 금지
- blocking I/O 핸들러 금지
- Lua access_log 직접 쓰기 금지 (Nginx native 사용)
- FFI free 함수 호출 의무

## 서브에이전트 목록

| 에이전트 | 파일 | 호출 조건 |
|---------|------|---------|
| `architect` | `.claude/agents/architect.md` | 설계 대안 2개+, `<!-- ADR 필요 -->` 마커 구간 |
| `implementer` | `.claude/agents/implementer.md` | Lua/FFI/설정 파일 구현 + 문서 업데이트 |
| `security-reviewer` | `.claude/agents/security-reviewer.md` | 보안 관련 코드/ADR 검증 |
| `tester` | `.claude/agents/tester.md` | 새 기능 구현 후 테스트 작성 |

> **doc-sync**: `.claude/agents/doc-sync.md` → `.claude/skills/doc-sync/SKILL.md` 로 전환됨.
> ADR 추가/변경 후 doc-sync skill을 invoke한다.

### 서브에이전트 간 직접 호출 금지

```
# WRONG: 서브에이전트 간 직접 호출
implementer → security-reviewer (직접)

# CORRECT: coordinator(CLAUDE.md)를 통한 조율
implementer 완료 → CLAUDE.md coordinator → security-reviewer 호출
```

### 변경 유형 → 서브에이전트 결정 표

| 변경 유형 | 호출 에이전트 |
|----------|------------|
| 새 API 엔드포인트 | implementer → (보안 포함 시) security-reviewer → tester |
| 설계 결정 필요 | architect → (보안 ADR) security-reviewer → doc-sync skill |
| FFI 모듈 변경 | implementer + security-reviewer → tester |
| 정책 엔진 변경 | implementer → tester → (설계 변경 시) architect |
| 문서만 변경 | doc-sync skill (직접 편집) |

## knowledge 인덱스 (작업별 필독 파일)

| 작업 | 반드시 읽을 knowledge |
|------|-------------------|
| Lua 핸들러 수정 | `openresty-patterns.md` + `architecture.md` |
| FFI 코드 작성/수정 | `c-ffi-guide.md` |
| 보안 기능 구현 | `security-patterns.md` |
| 코드 리뷰 | `review-checklist.md` |
| 새 spec 작성 | `conventions.md` + `architecture.md` |
| 정책/zone 관련 | `architecture.md` (zone map + hot reload 7단계) |
| 프로덕션 제한 확인 | `known-limitations-detail.md` |

## skills 목록

| Skill | 디렉토리 | invoke 조건 |
|-------|---------|------------|
| `new-lua-module` | `.claude/skills/new-lua-module/` | 새 Lua 모듈 생성 시 |
| `new-api-endpoint` | `.claude/skills/new-api-endpoint/` | 새 Admin API 엔드포인트 추가 시 |
| `new-policy-rule` | `.claude/skills/new-policy-rule/` | 새 정책 규칙 추가 시 |
| `new-hot-reload-bundle` | `.claude/skills/new-hot-reload-bundle/` | Hot Reload 구현/수정 시 |
| `new-ffi-binding` | `.claude/skills/new-ffi-binding/` | 새 Rust FFI 바인딩 추가 시 |
| `new-shdict-zone` | `.claude/skills/new-shdict-zone/` | 새 shared dict zone 추가 시 |
| `new-security-log-field` | `.claude/skills/new-security-log-field/` | 새 보안 로그 필드 추가 시 |
| `doc-sync` | `.claude/skills/doc-sync/` | ADR 추가/변경 후 |
| `pr-review-context` | `.claude/skills/pr-review-context/` | PR 생성 직후 Codex 심화 리뷰 컨텍스트 생성 시 |

## 이슈 완료 Exit Criteria 체크리스트

이슈 Done 전환 전 반드시 확인:

- [ ] 코드 구현 완료
- [ ] 테스트 추가/통과 (`make test`)
- [ ] 관련 spec/ADR 준수 확인 (AGENTS.md 불변식)
- [ ] 문서 갱신 (코드와 같은 PR — same-PR 규칙)
- [ ] `docs/spec/` 또는 `docs/design/adr/` 변경 시 `sync-spec` 스킬 완료 (AGENTS.md 불변식 8)
- [ ] **Codex 리뷰 완료** (`request-codex-review` 스킬 → 리뷰 결과 반영 → COMPLETED_REVIEW 마커)
- [ ] Linear 코멘트: 구현 파일 경로 포인터 포함
- [ ] PROGRESS.md append (날짜/이슈/산출물/비고)

> **AGENTS.md 불변식 확인**: `luagate_` prefix, fail-closed, `ngx.worker.id()`,
> hot reload 7단계, same-PR, 브랜치 선생성, sync-spec — 이 중 하나라도 위반하면 Done 전환 불가

## Linear 이슈 코멘트 템플릿

```markdown
## 구현 완료 [DON-XX]

**브랜치**: `<branch-name>`
**커밋**: `<hash>`

### 생성/수정 파일
- `<file-path>` — <설명>

### 확인 사항
- ADR 준수: <ADR-NNN>
- 테스트: `tests/unit/<path>_test.lua`
```

## ADR 워크플로우 트리거

다음 중 하나라도 해당하면 architect 에이전트 호출:

1. `<!-- ADR 필요 -->` 마커가 달린 코드 구간 구현 시
2. 구현 중 2개 이상의 설계 대안 발견 시
3. 기존 ADR 범위를 벗어나는 새 패턴 도입 시

## Linear vs PROGRESS.md 역할 분담

| 항목 | Linear | PROGRESS.md |
|------|--------|-------------|
| 목적 | 상태 추적, 이슈 관리 | 시간순 구현 일지 |
| 내용 | 완료 코멘트 (산출물 요약 + 파일 경로) | 날짜/이슈/산출물/비고 |
| 업데이트 시점 | 이슈 Done 전환 시 | 각 이슈 완료 시 append |

## make 워크플로우

```bash
make implement ISSUE=42     # 이슈 구현 워크플로우 시작
make test                   # 전체 테스트
make test-unit              # Lua 단위 테스트
make lint                   # StyLua + luacheck + cargo clippy
make up                     # Docker Compose 기동 (통합 테스트 환경)
make down                   # 종료
make build-ffi              # Rust FFI 빌드 + lib/ 복사
```

## PR 생성 워크플로우

Epic 완료 후 PR 생성 절차:

1. **Test Plan 검증** — PR 본문에 포함될 Test Plan 항목을 **모두** 실행하여 통과 확인
   - 코드 변경: `make test-unit` + 관련 테스트 파일 개별 실행 (TAP 출력으로 항목별 확인)
   - 문서/ADR 변경: spec 정합성 검증 (관련 spec 파일 간 참조 일관성, TODO 교체 여부, same-PR 동기화)
   - Test Plan 항목 중 하나라도 FAIL이면 PR 생성 불가
2. `git push -u origin <epic-branch>`
3. `gh pr create` — 제목: `type(scope): 설명 [DON-XX]`, 본문: `.github/pull_request_template.md` 참조
4. `pr-review-context` 스킬 invoke → 변경 파일 기반 심화 리뷰 컨텍스트 생성
5. `request-codex-review` 스킬 invoke (3단계 컨텍스트 포함, code 리뷰). 보안/설계 변경 포함 시 design 리뷰도 추가
6. CI 통과 + 최소 1개 승인 후 Squash merge

> **머지 전략**: epic → main은 Squash merge (단일 커밋), issue → epic은 Merge commit.

PR에 `chatgpt-codex-connector` review thread 가 달린 뒤 후속 수정/답글 처리는
`./scripts/codex-address-pr-review.sh` 를 사용한다.
상세 절차는 `docs/workflow/codex-review.md` 참조.

## pre-commit / post-commit hook 규칙

- pre-commit: `stylua --check`, `luacheck`, `clang-format --check`, `shellcheck`, `markdownlint`
- commit-msg: `commitlint` (Conventional Commits 형식 강제)
- pre-push: `make test-unit` + `clang-tidy` + `luacheck` 전체
