---
name: linear-update
description: "Linear 이슈 상태 변경 + 코멘트 작성 + 문서 CRUD."
trigger: "linear-update | Linear 업데이트 | 이슈 Done | 이슈 상태 변경"
---

# linear-update Skill

## 역할

Linear 이슈 상태 변경, 코멘트 작성, 문서 CRUD를 일관된 형식으로 처리한다.

## 사용 패턴

### 이슈 상태 변경

```
linear-update DON-XXX → In Progress
linear-update DON-XXX → Done
```

**MCP 호출:**
```
save_issue(id: DON-XXX, status: "In Progress" | "Done")
```

### 완료 코멘트 작성

이슈 Done 전환 시 표준 코멘트 형식:

```markdown
## 구현 완료 [DON-XX]

**브랜치**: `<branch-name>`
**커밋**: `<hash>`

### 생성/수정 파일
- `<file-path>` — <설명>

### 확인 사항
- ADR 준수: <ADR-NNN> (해당 시)
- 테스트: `tests/unit/<path>_test.lua`
- Codex 리뷰: <결과 요약 1~2줄>
```

**MCP 호출:**
```
save_comment(issueId: DON-XXX, body: <위 형식>)
```

### 시작 코멘트 작성

이슈 In Progress 전환 시:

```markdown
## 작업 시작 [DON-XX]

**에이전트 계획**: architect → implementer → tester → security-reviewer
**리뷰 계획**: <1회 | 2회>
```

### Linear 문서 CRUD

- 문서 조회: `get_document(id)`
- 문서 목록: `list_documents()`
- 문서 수정: `update_document(id, content)`
- 문서 생성: `create_document(title, content)`

## 주의사항

- 이슈 상태를 Done으로 변경하기 전 반드시 완료 체크리스트 확인
- 에러 발생 시 이슈 상태를 Done으로 변경하지 않음 (In Progress 유지)
- 코멘트는 한 번 작성 후 수정하지 않음 (추가 코멘트로 보완)
