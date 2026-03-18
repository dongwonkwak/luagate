---
name: pr-review-context
description: "PR 생성 시 변경 파일을 분석하여 관련 knowledge/spec/ADR을 매핑하고 심화 리뷰 컨텍스트를 생성한다."
trigger: "pr-review-context | PR 심화 컨텍스트 | PR 생성 후 리뷰 컨텍스트"
---

# pr-review-context Skill

## 역할

`gh pr create` 완료 직후 호출된다. 변경 파일 경로를 분석하여 `.claude/knowledge/`, `docs/spec/`, `docs/design/adr/` 에서 관련 문서를 선별하고, Codex 리뷰 파일의 `{{SPEC_DOCS}}` 섹션에 삽입할 **심화 리뷰 컨텍스트**를 생성한다.

DON-103(GitHub Actions 범용 체크리스트)과의 차이:
- DON-103: 모든 PR에 파일 유형별 **고정 체크리스트** (CI workflow)
- **이 스킬**: Claude Code가 PR 생성 시 **프로젝트 지식 기반 맞춤 심화 지시문** (Claude Code 스킬)

---

## 실행 절차

### 1. 변경 파일 수집

```bash
./scripts/review-changed-files.sh
```

### 2. 파일 경로 → 지식 매핑

아래 매핑 테이블에서 변경 파일에 해당하는 행을 모두 선택한다.
동일 문서가 여러 행에서 나타나면 중복 제거 후 1회만 포함한다.

| 변경 파일 경로 패턴 | knowledge | spec | ADR |
|---|---|---|---|
| `lua/luagate/policy/**` | openresty-patterns, conventions | policy-engine | ADR-002, ADR-003 |
| `lua/luagate/http/**` | openresty-patterns, security-patterns | http-pipeline | ADR-001, ADR-002 |
| `lua/luagate/stream/**` | openresty-patterns | stream-pipeline | ADR-001, ADR-002 |
| `lua/luagate/security/**` | security-patterns, openresty-patterns | security-scanner | ADR-002 |
| `lua/luagate/admin/**` | security-patterns, conventions | admin-api | ADR-003, ADR-004 |
| `lua/luagate/log/**` | openresty-patterns | log-schema | ADR-004 |
| `lua/luagate/metrics/**` | openresty-patterns | log-schema | ADR-004 |
| `src/stream/**` | rust-ffi-guide | rust-ffi-modules, stream-pipeline | ADR-001 |
| `src/scanner/**` | rust-ffi-guide, security-patterns | rust-ffi-modules, security-scanner | ADR-001 |
| `src/decoder/**` | rust-ffi-guide, security-patterns | rust-ffi-modules, security-scanner | ADR-001 |
| `conf/**` | openresty-patterns | architecture | ADR-001 |
| `policies/**` | — | policy-engine | ADR-002, ADR-003 |
| `frontend/**` | — | admin-api | ADR-004 |
| `tests/unit/**` | conventions | test-strategy | — |
| `tests/integration/**` | conventions | test-strategy | — |
| `docs/design/adr/**` | — | doc-strategy | — |
| `docs/spec/**` | — | doc-strategy | — |

### 파일 경로 매핑표

| 이름 | 실제 경로 |
|---|---|
| openresty-patterns | `.claude/knowledge/openresty-patterns.md` |
| security-patterns | `.claude/knowledge/security-patterns.md` |
| rust-ffi-guide | `.claude/knowledge/rust-ffi-guide.md` |
| conventions | `.claude/knowledge/conventions.md` |
| policy-engine | `docs/spec/policy-engine.md` |
| http-pipeline | `docs/spec/http-pipeline.md` |
| stream-pipeline | `docs/spec/stream-pipeline.md` |
| security-scanner | `docs/spec/security-scanner.md` |
| admin-api | `docs/spec/admin-api.md` |
| log-schema | `docs/spec/log-schema.md` |
| rust-ffi-modules | `docs/spec/rust-ffi-modules.md` |
| architecture | `docs/spec/architecture.md` |
| test-strategy | `docs/spec/test-strategy.md` |
| doc-strategy | `docs/spec/doc-strategy.md` |
| ADR-001 | `docs/design/adr/ADR-001-execution-shared-state-model.md` |
| ADR-002 | `docs/design/adr/ADR-002-policy-evaluation-conflict-detection.md` |
| ADR-003 | `docs/design/adr/ADR-003-policy-storage-hot-reload.md` |
| ADR-004 | `docs/design/adr/ADR-004-log-metrics-admin-security.md` |
| ADR-005 | `docs/design/adr/ADR-005-policy-activation-concurrency.md` |
| ADR-006 | `docs/design/adr/ADR-006-metrics-cardinality-export-model.md` |
| ADR-007 | `docs/design/adr/ADR-007-log-redaction-and-retention.md` |

### 3. 관련 문서에서 핵심 규칙 추출

선택된 각 문서에서 아래 항목만 발췌한다 (문서 전체를 포함하지 않는다):

- **ADR**: "결정(Decision)" 또는 "핵심 결정" 섹션 — 2~4줄 요약
- **spec**: 해당 모듈이 준수해야 할 구현 계약 — 핵심 제약만
- **knowledge**: 패턴/안티패턴 — 코드 예시 1개 이하

### 4. 심화 리뷰 컨텍스트 출력

`request-codex-review` 스킬이 생성하는 리뷰 파일의 **`## 관련 스펙 문서`** 섹션을 아래 형식으로 대체할 내용을 출력한다.

```markdown
## LuaGate 심화 리뷰 컨텍스트

이 PR은 <변경 요약>을 수정합니다.

### 관련 ADR 핵심 결정
<!-- 해당 ADR의 Decision 섹션 요약 -->
- **ADR-00N:** <결정 내용 1줄>
- **ADR-00M:** <결정 내용 1줄>

### 구현 계약 (<spec 이름>)
<!-- spec에서 이 모듈이 반드시 준수해야 하는 제약 -->
- <계약 항목 1>
- <계약 항목 2>

### OpenResty / 보안 패턴 체크
<!-- 관련 knowledge에서 발췌한 패턴/안티패턴 -->
- <패턴 1>
- <패턴 2>

### 관련 문서 경로
<!-- 리뷰어가 전문 참조 시 사용 -->
- `<경로>` — <용도>
```

### 5. request-codex-review 연계

이 스킬 단독으로는 리뷰 파일을 생성하지 않는다.
생성된 컨텍스트를 `request-codex-review` 스킬 실행 시 `{{SPEC_DOCS}}` 자리에 삽입한다.

**통합 워크플로우 (PR 생성 후)**:

```
1. gh pr create → PR URL 확인
2. pr-review-context 스킬 실행 → 심화 컨텍스트 생성
3. request-codex-review 스킬 실행 (생성된 컨텍스트 포함)
4. 사람이 codex CLI 실행
```

---

## 출력 예시 (policy/** 변경 시)

```markdown
## LuaGate 심화 리뷰 컨텍스트

이 PR은 정책 평가 엔진(lua/luagate/policy/)을 수정합니다.

### 관련 ADR 핵심 결정
- **ADR-002:** priority first-match-wins, stable sort (priority, original_index). Conflict(same-priority + overlap + opposing action) → load error
- **ADR-003:** validate-first, commit-last. 단일 envelope key per subsystem. LKG(last-known-good) 보장

### 구현 계약 (policy-engine.md)
- global.default_action 필수 (기본값 deny)
- HTTP/Stream independent commit → partial success 가능
- policy_hash 변경 시에만 reload 수행

### OpenResty 패턴 체크
- table.sort에 original_index 포함 (Lua 5.1 비안정 sort)
- shared dict 쓰기: `safe_set` 사용 (luagate_policy_* zone)
- cjson.decode 결과 반드시 nil 체크 후 사용

### 관련 문서 경로
- `docs/spec/policy-engine.md` — YAML schema, match operators, partial semantics
- `docs/design/adr/ADR-002-policy-evaluation-conflict-detection.md` — 충돌 탐지 알고리즘
- `docs/design/adr/ADR-003-policy-storage-hot-reload.md` — Hot Reload 7단계
- `.claude/knowledge/openresty-patterns.md` — shared dict 패턴, safe_set
```

---

## 참조

- `.claude/knowledge/review-checklist.md`
- `.claude/skills/request-codex-review/SKILL.md`
- `AGENTS.md` — 불변식 목록
