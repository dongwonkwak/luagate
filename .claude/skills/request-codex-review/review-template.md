# Codex Review: {{ISSUE}} — {{TITLE}} ({{TYPE}})

## 리뷰 유형

{{TYPE_LABEL}}

## 변경 파일 목록

```
{{CHANGED_FILES}}
```

## 관련 스펙 문서

{{SPEC_DOCS}}

## Acceptance Criteria

{{ACCEPTANCE_CRITERIA}}

## 적용 불변식 (AGENTS.md)

- `luagate_` prefix 필수 — 모든 ngx.shared.DICT zone 이름
- fail-closed — 스캐너/디코더/FFI 에러 시 deny
- `ngx.worker.id()` 사용 (`ngx.worker.pid()` 금지)
- Hot Reload 7단계 준수 (staged → validate → hash → blob store → pointer swap)
- same-PR 규칙 — 코드 변경과 문서/spec 변경은 같은 PR에 포함
- FFI free 함수 호출 의무

## 리뷰 체크리스트

참조: `.claude/knowledge/review-checklist.md`

### 코드 품질

- [ ] 불변식 위반 없음
- [ ] 에러 핸들링 (fail-closed)
- [ ] 테스트 커버리지 충분
- [ ] blocking I/O 없음 (핸들러 내 io.open, os.execute 등)
- [ ] ngx.ctx에 정책 캐시 저장 없음

### 보안

- [ ] 인증/인가 처리
- [ ] PII 레독션
- [ ] OWASP 패턴 적용

### 문서

- [ ] spec/ADR 갱신 여부
- [ ] same-PR 규칙 준수

## 리뷰 관점 안내

역할: 찾기만, 수정 없음

발견한 문제점을 result.md 형식으로 출력하라. 코드를 직접 수정하거나 수정 방법을 실행하지 말 것.
수정은 사람의 별도 지시로만 수행한다.

## 결과 출력 형식

결과는 반드시 아래 result-template.md 포맷을 준수하여 출력하라:

참조: `.claude/skills/request-codex-review/result-template.md`

결과 파일 경로: {{RESULT_PATH}}
