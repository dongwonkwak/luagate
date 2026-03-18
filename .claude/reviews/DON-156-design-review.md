# Codex Review: DON-156 — ADR-009 FFI .so 타임아웃 강제 메커니즘 (design)

## 리뷰 유형

설계 리뷰 — 아키텍처 결정의 타당성, 대안 검토, ADR 품질 검토

## 변경 파일 목록

```
docs/design/adr/ADR-009-ffi-timeout-enforcement.md
```

## 관련 스펙 문서

- `docs/design/adr/ADR-001-execution-shared-state-model.md` (실행 모델, FFI 통합 방식)
- `docs/design/adr/ADR-003-policy-storage-hot-reload.md` (Hot Reload 7단계)
- `docs/spec/c-ffi-modules.md` (FFI ABI 계약, 에러 코드 정의)
- `docs/spec/http-pipeline.md` (HTTP 파이프라인 타임아웃 설정)
- `docs/spec/architecture.md` (전체 아키텍처)

## Acceptance Criteria

- [ ] 3계층 방어 전략(Layer 1/2/3)의 타당성 검증
- [ ] OpenResty worker 모델과의 호환성 확인
- [ ] 기존 ADR (ADR-001 실행 모델, ADR-003 hot reload)과의 정합성
- [ ] Rust watchdog thread의 thread leak 위험성 평가
- [ ] fail-closed 패턴 준수 확인
- [ ] 성능 오버헤드 분석의 충분성 검증

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

다음 관점에서 집중 리뷰하라:

1. **3계층 방어 전략의 타당성**: Layer 1(budget guard) → Layer 2(watchdog thread) → Layer 3(worker_shutdown_timeout) 각 계층의 역할 분담과 fallback 논리가 적절한지
2. **OpenResty worker 모델과의 호환성**: Rust watchdog thread가 OpenResty의 단일 스레드 이벤트 루프 모델과 충돌하지 않는지, recv_timeout이 worker 이벤트 루프를 블로킹하는 영향
3. **기존 ADR과의 정합성**: ADR-001의 "동일 worker 내 동기 호출" 원칙 유지 여부, ADR-003 hot reload 7단계와의 상호작용 (init 단계 radix_build 1000ms timeout 등)
4. **Rust watchdog thread의 thread leak 위험성**: detach된 thread의 자원 회수 전략, leak 카운터 임곗값(10)의 적절성, OOM 시나리오 분석
5. **fail-closed 패턴 준수**: 모든 타임아웃 경로에서 deny 처리가 보장되는지, LUAGATE_TIMEOUT(-5) 에러 코드의 Lua wrapper 처리
6. **성능 오버헤드 분석의 충분성**: 매 FFI 호출마다 thread spawn하는 비용(수 us~수십 us) 추정의 근거, thread pool 전환 기준의 명확성

발견한 문제점을 result.md 형식으로 출력하라. 코드를 직접 수정하거나 수정 방법을 실행하지 말 것.
수정은 사람의 별도 지시로만 수행한다.

## 결과 출력 형식

결과는 반드시 아래 포맷으로만 출력하라. 헤더/구조를 임의로 변경하지 말 것.

```
# 리뷰 결과: DON-156-design

## 1차 리뷰 (YYYY-MM-DD)

- [ ] 발견된 문제 1
- [ ] 발견된 문제 2
```

규칙:
- 각 항목은 반드시 `- [ ]` 로 시작
- 헤더(`#`, `##`)는 위 포맷 외 추가 금지
- 문제가 없으면 `- [ ] 없음` 한 줄만 출력

참조: `.claude/skills/request-codex-review/result-template.md`

결과 파일 경로: .claude/reviews/DON-156-design-result.md
