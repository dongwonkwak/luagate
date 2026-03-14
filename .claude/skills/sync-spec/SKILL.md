---
name: sync-spec
description: "docs/spec/ 수정 시 해당 Linear 문서에 변경분 자동 반영. docs/spec/가 Source of Truth."
trigger: "sync-spec | 스펙 동기화 | spec 변경 후 Linear 반영"
---

# sync-spec Skill

## 역할

`docs/spec/*.md` 파일 수정 후 해당 Linear 문서에 변경분을 반영한다.
**방향: `docs/spec/` (원본) → Linear 문서 (미러). 역방향 없음.**

## 실행 절차

### 1. 변경된 스펙 파일 확인

```bash
git diff --name-only HEAD~1 HEAD -- docs/spec/
# 또는 현재 staged 변경사항:
git diff --cached --name-only -- docs/spec/
```

### 2. 파일 → Linear 문서 매핑

| 로컬 파일 | Linear 문서 제목 (검색어) |
|-----------|--------------------------|
| `docs/spec/architecture.md` | "architecture" |
| `docs/spec/http-pipeline.md` | "http-pipeline" |
| `docs/spec/stream-pipeline.md` | "stream-pipeline" |
| `docs/spec/policy-engine.md` | "policy-engine" |
| `docs/spec/admin-api.md` | "admin-api" |
| `docs/spec/log-schema.md` | "log-schema" |
| `docs/spec/security-scanner.md` | "security-scanner" |
| `docs/spec/c-ffi-modules.md` | "c-ffi-modules" |
| `docs/spec/test-strategy.md` | "test-strategy" |
| `docs/spec/doc-strategy.md` | "doc-strategy" |
| `docs/design/adr/*.md` | ADR 번호로 검색 |

### 3. Linear 문서 조회 및 업데이트

```
list_documents() → 제목으로 문서 ID 찾기
get_document(id) → 현재 내용 확인
update_document(id, content: <로컬 파일 내용>)
```

### 4. 동기화 결과 보고

```markdown
## sync-spec 완료

| 파일 | Linear 문서 | 상태 |
|------|------------|------|
| docs/spec/admin-api.md | DON-doc-XXX | 업데이트 완료 |
```

## 주의사항

- Linear 문서가 없는 경우 새로 생성하지 않음 — 사람에게 보고
- 로컬 파일이 더 최신임을 전제 (역방향 덮어쓰기 없음)
- ADR의 경우 `docs/design/adr/` 경로의 파일도 동기화 대상
