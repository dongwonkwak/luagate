# scripts/

LuaGate 프로젝트 보조 스크립트 모음.

---

## codex-review.sh

Codex CLI를 사용한 코드/설계 리뷰 자동화 스크립트.

### 사용법

```bash
# 1. PROGRESS.md의 PENDING_REVIEW 마커를 자동 감지하여 실행
./scripts/codex-review.sh

# 2. 이슈/유형을 수동으로 지정하여 실행
./scripts/codex-review.sh DON-97 code
./scripts/codex-review.sh DON-97 design
```

### PENDING_REVIEW 마커 포맷

`request-codex-review` 스킬이 PROGRESS.md 끝에 아래 형식으로 마커를 기입한다:

```
PENDING_REVIEW: DON-97-code
```

스크립트는 이 마커를 읽어 다음 경로를 자동으로 결정한다:

- 리뷰 파일: `.claude/reviews/DON-97-code-review.md`
- 결과 파일: `.claude/reviews/DON-97-code-result.md`

### 최초 리뷰 vs 재리뷰

| 상황 | 동작 |
|------|------|
| result.md가 없거나 `[x]` 항목 없음 | 최초 리뷰: review.md → Codex → result.md 신규 생성 |
| result.md에 `[x]` 항목 있음 | 재리뷰: 기해결 항목 스킵 프롬프트 + 날짜 헤더 추가 → result.md에 append |

재리뷰 시 기존 `[x]` 항목은 Codex에게 스킵 지시가 전달된다 (AGENTS.md 불변식).

### 마커 자동 정리

리뷰 실행 완료 후 스크립트가 PROGRESS.md의 마커를 자동으로 갱신한다:

```
# 실행 전
PENDING_REVIEW: DON-97-code

# 실행 후
COMPLETED_REVIEW: DON-97-code (2026-03-14)
```

### 전제 조건

- `codex` CLI가 PATH에 설치되어 있어야 한다.
- 리뷰 파일(`.claude/reviews/DON-XXX-{type}-review.md`)이 사전 생성되어 있어야 한다.
  → `request-codex-review` 스킬로 생성.

---

## 향후 추가 예정 스크립트

| 스크립트 | 설명 |
|---------|------|
| `lint-all.sh` | StyLua + luacheck + cargo clippy 일괄 실행 |
| `gen-metrics-doc.sh` | Prometheus 메트릭 목록 자동 생성 |
