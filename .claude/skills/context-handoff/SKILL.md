---
name: context-handoff
description: "에이전트 간 작업 인계 자동화. 완료 에이전트의 산출물을 다음 에이전트에게 구조화 전달 + Linear 코멘트 기록."
trigger: "context-handoff | 작업 인계 | 핸드오프 | handoff"
---

# context-handoff Skill

## 역할

서브에이전트 작업 완료 시, 다음 에이전트에게 필요한 맥락을 구조화하여 전달한다.
coordinator(CLAUDE.md)가 에이전트 간 전환 시 이 스킬을 invoke하여 컨텍스트 손실을 방지한다.

## 전제 조건

- 선행 에이전트 작업 완료 상태
- Linear 이슈 번호 (DON-XXX)
- Linear MCP 접근 가능

## 실행 절차

### 1. 완료 에이전트 산출물 수집

선행 에이전트의 작업 결과를 분석하여 다음 정보를 추출한다:

- 생성/수정된 파일 목록 (`git diff --name-only` 또는 에이전트 출력에서)
- 주요 설계 결정 사항
- 미해결 TODO 또는 주의사항
- 관련 ADR/spec 참조

### 2. 핸드오프 문서 생성

다음 템플릿으로 핸드오프 내용을 구성한다:

```markdown
## 작업 인계 ({{from_agent}} → {{to_agent}})

**이슈**: DON-XXX — {{이슈 제목}}
**날짜**: {{YYYY-MM-DD}}

### 완료된 작업
- {{선행 에이전트가 완료한 항목}}

### 생성/수정된 파일
- `{{file_path}}:{{line_number}}` — {{변경 설명}}
  - 예: `lua/luagate/http/handler.lua:42` — access() 함수 추가
  - 예: `tests/unit/policy/evaluator_spec.lua:15-89` — 불변식 테스트 추가

> **규칙**: 프로젝트 컨벤션에 따라 `file_path:line_number` 포인터 형식 사용 (`.claude/knowledge/conventions.md` §파일 경로 포인터)

### 설계 결정 사항
- {{결정 내용}} (근거: {{ADR-NNN 또는 이유}})

### 주의사항
- {{다음 에이전트가 알아야 할 제약/경고}}

### 다음 단계
- {{다음 에이전트가 수행할 작업 목록}}

### 관련 참조
- ADR: {{관련 ADR 경로}}
- Spec: {{관련 spec 경로}}
- 이슈: DON-XXX
```

### 3. Linear 이슈 코멘트 추가

`save_comment`로 핸드오프 내용을 Linear 이슈에 기록한다:

```
save_comment(
  issueId: "DON-XXX",
  body: "## 작업 인계 ({{from_agent}} → {{to_agent}})\n\n..."
)
```

### 4. 다음 에이전트에게 맥락 전달

coordinator가 다음 에이전트를 호출할 때 핸드오프 문서의 핵심 내용을 프롬프트에 포함한다:

- 수정된 파일 경로 (에이전트가 읽어야 할 파일)
- 설계 결정 사항 (에이전트가 준수해야 할 규칙)
- 주의사항 (에이전트가 피해야 할 패턴)

## 에이전트 전환 매트릭스

| 전환 | 핸드오프 핵심 내용 |
|------|----------------|
| architect → implementer | ADR 경로, 선택된 대안 번호, 구현 제약 |
| architect → security-reviewer | ADR 경로, 보안 관련 결정 사항 |
| implementer → tester | 구현 파일 경로, 테스트 대상 함수, edge case 힌트 |
| implementer → security-reviewer | 변경된 FFI/인증/정책 코드 경로 |
| security-reviewer → implementer | 발견된 취약점, 수정 필요 파일, 권고 패치 |
| frontend-developer → tester | 컴포넌트 경로, 테스트 시나리오, mock 데이터 |

## plan-next-work 연동

`plan-next-work` 스킬이 이슈를 선택하면, 해당 이슈에 이전 핸드오프 코멘트가 있는지 확인한다:

```
list_comments(issueId: "DON-XXX")
→ "작업 인계" 키워드가 포함된 코멘트 검색
→ 있으면 핸드오프 맥락을 implement-issue에 전달
```

## 출력 형식

```markdown
## 핸드오프 완료

**전환**: {{from_agent}} → {{to_agent}}
**이슈**: DON-XXX
**Linear 코멘트**: 추가 완료
**전달 파일**: {{N}}개
**주의사항**: {{N}}개
```
