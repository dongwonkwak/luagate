# Codex Review: DON-142 — access_by_lua 보안 스캐너 통합 — decoder + scanner HTTP 파이프라인 연결 (code)

## 리뷰 유형

코드 리뷰 — 구현 정확성, 보안, 테스트 완전성 검토

## 변경 파일 목록

```
PROGRESS.md
lua/luagate/http/handler.lua
lua/luagate/metrics/collector.lua
tests/unit/http/handler_spec.lua
tests/unit/metrics/collector_spec.lua
```

## 관련 스펙 문서

- `docs/spec/security-scanner.md` — 보안 스캐너 스펙 (에러 3계층, 8KB 제한, threat_type)
- `docs/spec/http-pipeline.md` — HTTP 파이프라인 (access_by_lua 순서, decision_source)
- `docs/spec/c-ffi-modules.md` — FFI 모듈 ABI 계약 (§4 scanner, §5 decoder)
- `docs/spec/log-schema.md` — 로그 스키마 (threat_type, rule_name, decision_source 필드)
- `docs/design/adr/ADR-001-execution-shared-state-model.md` — fail-closed 원칙
- `docs/design/adr/ADR-006-metrics-cardinality-export-model.md` — scanner_threats 메트릭 키

## Acceptance Criteria

- [ ] decoder → scanner 순서 보장
- [ ] threat 탐지 시 정책 평가 스킵 (scanner가 먼저)
- [ ] 감사 로그: `threat_type`, `rule_name`, `decision_source=scanner_block`
- [ ] Admin plane 요청 스캐너 제외
- [ ] path 8KB / query 8KB 상한 초과 → fail-closed
- [ ] 통합 테스트: scanner block 케이스 추가

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

결과는 반드시 아래 포맷으로만 출력하라. 헤더/구조를 임의로 변경하지 말 것.

```
# 리뷰 결과: DON-142-code

## 1차 리뷰 (YYYY-MM-DD)

- [ ] 발견된 문제 1
- [ ] 발견된 문제 2
```

규칙:
- 각 항목은 반드시 체크박스(`- [ ]`)로 시작
- 헤더(`#`, `##`)는 위 포맷 외 추가 금지
- 문제가 없으면 `- [ ] 없음` 한 줄만 출력

참조: `.claude/skills/request-codex-review/result-template.md`

결과 파일 경로: .claude/reviews/DON-142-code-result.md
