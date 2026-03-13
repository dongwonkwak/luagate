# CLAUDE.md — Claude Code 전용 지침

> **공통 프로젝트 지침**: → [AGENTS.md](./AGENTS.md) 참조 (코딩 컨벤션, 불변식, 용어집, spec 참조 맵)
> **읽기 순서**: AGENTS.md → CLAUDE.md

## Claude Code 역할: Coordinator

CLAUDE.md는 Claude Code의 **coordinator** 역할을 정의한다.
서브에이전트는 상호 직접 호출하지 않으며, 항상 coordinator(CLAUDE.md)를 통해 조율된다.

### 항상 적용 규칙 (skill invoke 없이도 적용)

- AGENTS.md 불변식 전체 (`luagate_` prefix, fail-closed, `ngx.worker.id()`, hot reload 7단계, same-PR)
- `ngx.ctx`에 정책 캐시 저장 금지
- blocking I/O 핸들러 금지
- Lua access_log 직접 쓰기 금지 (Nginx native 사용)
- FFI free 함수 호출 의무

## 서브에이전트 목록

| 에이전트 | 파일 | 호출 조건 |
|---------|------|---------|
| `architect` | `.claude/agents/architect.md` | 설계 대안 2개+, `<!-- ADR 필요 -->` 마커 구간 |
| `api-developer` | `.claude/agents/api-developer.md` | HTTP/Stream/Admin API 핸들러 구현 |
| `security-reviewer` | `.claude/agents/security-reviewer.md` | 보안 관련 코드/ADR 검증 |
| `test-writer` | `.claude/agents/test-writer.md` | 새 기능 구현 후 테스트 작성 |

> **doc-sync**: `.claude/agents/doc-sync.md` → `.claude/skills/doc-sync/SKILL.md` 로 전환됨.
> ADR 추가/변경 후 doc-sync skill을 invoke한다.

### 서브에이전트 간 직접 호출 금지

```
# WRONG: 서브에이전트 간 직접 호출
api-developer → security-reviewer (직접)

# CORRECT: coordinator(CLAUDE.md)를 통한 조율
api-developer 완료 → CLAUDE.md coordinator → security-reviewer 호출
```

### 변경 유형 → 서브에이전트 결정 표

| 변경 유형 | 호출 에이전트 |
|----------|------------|
| 새 API 엔드포인트 | api-developer → (보안 포함 시) security-reviewer → test-writer |
| 설계 결정 필요 | architect → (보안 ADR) security-reviewer → doc-sync skill |
| FFI 모듈 변경 | api-developer + security-reviewer → test-writer |
| 정책 엔진 변경 | api-developer → test-writer → (설계 변경 시) architect |
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

## 이슈 완료 Exit Criteria 체크리스트

이슈 Done 전환 전 반드시 확인:

- [ ] 코드 구현 완료
- [ ] 테스트 추가/통과 (`make test`)
- [ ] 관련 spec/ADR 준수 확인 (AGENTS.md 불변식)
- [ ] 문서 갱신 (코드와 같은 PR — same-PR 규칙)
- [ ] Linear 코멘트: 구현 파일 경로 포인터 포함
- [ ] PROGRESS.md append (날짜/이슈/산출물/비고)

> **AGENTS.md 불변식 확인**: `luagate_` prefix, fail-closed, `ngx.worker.id()`,
> hot reload 7단계, same-PR — 이 중 하나라도 위반하면 Done 전환 불가

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

## pre-commit / post-commit hook 규칙

- pre-commit: `stylua --check`, `luacheck`, `cargo fmt --check`, `cargo clippy`
- post-commit: `PROGRESS.md` 업데이트 리마인더
