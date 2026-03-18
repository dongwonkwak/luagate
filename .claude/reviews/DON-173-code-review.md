# Codex Review: DON-173 — Admin API Rate Limiting (Sliding Window) (code)

## 리뷰 유형

코드 리뷰 — 구현 정확성, 보안, 테스트 완전성 검토

## 변경 파일 목록

```
.claude/knowledge/zone-registry.md
conf/nginx.conf
lua/luagate/admin/ratelimit.lua
lua/luagate/admin/router.lua
tests/unit/admin/ratelimit_spec.lua
tests/unit/admin/router_spec.lua
```

## 관련 스펙 문서

- `docs/spec/admin-api.md` — Admin API 엔드포인트 계약
- `docs/spec/architecture.md` §shared dict — zone 선언 및 크기 정책
- `docs/design/adr/ADR-004-log-metrics-admin-security.md` §4.4 — Admin API 보안 요구사항
- `.claude/knowledge/zone-registry.md` — shared dict zone 상세 스펙

## Acceptance Criteria

- [ ] `lua/luagate/admin/ratelimit.lua`: sliding window 알고리즘 구현 (60s window, 30 req/IP)
- [ ] shared dict zone: `luagate_admin_ratelimit` (`luagate_` prefix 준수)
- [ ] 429 Too Many Requests + Retry-After 헤더 반환
- [ ] `/health` 엔드포인트 rate limit 면제
- [ ] fail-closed: shared dict 사용 불가 시 요청 거부
- [ ] `conf/nginx.conf`: `luagate_admin_ratelimit` shared dict 선언
- [ ] `lua/luagate/admin/router.lua`: ratelimit 미들웨어 통합
- [ ] `zone-registry.md`: 새 zone 문서화
- [ ] 단위 테스트 충분한 커버리지

## 적용 불변식 (AGENTS.md)

- `luagate_` prefix 필수 — 모든 ngx.shared.DICT zone 이름
- fail-closed — shared dict 에러 시 deny
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

### 추가 리뷰 지시문

- AGENTS.md 불변식 준수 확인 (luagate_ prefix, fail-closed, ngx.worker.id())
- sliding window 알고리즘 정확성: 윈도우 경계 처리, 가중치 계산, 시간 정밀도
- shared dict race condition 검토: 다중 워커 동시 접근 시 정합성, atomic 연산 사용 여부
- Admin router 통합 정합성: ratelimit 미들웨어 호출 순서, 인증 전/후 배치
- 테스트 커버리지 충분성: edge case (윈도우 경계, 동시 요청, dict 오류) 포함 여부
- zone-registry.md 업데이트 정합성: 기존 zone 문서 형식과 일치 여부

## 결과 출력 형식

결과는 반드시 아래 포맷으로만 출력하라. 헤더/구조를 임의로 변경하지 말 것.

```
# 리뷰 결과: DON-173-code

## 1차 리뷰 (YYYY-MM-DD)

- [ ] 발견된 문제 1
- [ ] 발견된 문제 2
```

규칙:
- 각 항목은 반드시 `- [ ]` 로 시작
- 헤더(`#`, `##`)는 위 포맷 외 추가 금지
- 문제가 없으면 `- [ ] 없음` 한 줄만 출력

참조: `.claude/skills/request-codex-review/result-template.md`

결과 파일 경로: .claude/reviews/DON-173-code-result.md
