---
name: plan-next-work
description: "Linear MCP로 다음 작업 계획. 의존성 분석 후 블로커 없는 최우선 이슈 선택."
trigger: "다음 할 일 진행해 | 다음 이슈 선택 | plan-next-work | 자동 모드"
---

# plan-next-work Skill

## 역할

Linear에서 이슈를 조회하여 의존성을 분석하고, 블로커가 없는 최우선 이슈를 선택하여 실행 계획을 제시한다.

## 실행 절차

1. **Linear 이슈 조회**
   - `list_issues` — 현재 스프린트/사이클의 In Progress + Todo 이슈 조회
   - 상태 필터: `Todo`, `In Progress`
   - 우선순위 기준: Priority 1 (Urgent) → 2 (High) → 3 (Medium)

2. **의존성 분석**
   - 각 이슈의 `dependencies` 확인
   - 의존 이슈가 Done이 아니면 블로커로 분류

3. **이슈 선택 기준**
   - 블로커 없는 이슈 중 우선순위 최고 이슈 선택
   - 동순위 시 이슈 번호 오름차순

4. **리뷰 횟수 판단** (선택 이슈에 대해)
   2회 리뷰 조건 중 하나라도 해당 시 2회:
   - ADR 수정 또는 신규 ADR 필요
   - 스펙 문서 2개 이상 수정
   - 새로운 shared dict zone 추가
   - 새로운 Rust FFI 인터페이스 추가
   - Dependencies 3개 이상
   - 이슈 라벨에 "architecture" 포함

5. **실행 계획 보고**
   ```
   선택 이슈: DON-XXX — <제목>
   우선순위: <Priority>
   리뷰 계획: 1회 리뷰 | 2회 리뷰 (사유: <조건>)
   예상 에이전트: architect → implementer → tester → [codex review] → security-reviewer

   진행하려면: "DON-XXX 진행해줘" 또는 implement-issue 스킬 실행
   ```

## 출력 형식

```markdown
## 다음 작업 계획

**선택 이슈**: DON-XXX — <이슈 제목>
**우선순위**: P<N> (<텍스트>)
**리뷰 계획**: <1회 | 2회> 리뷰

### 에이전트 순서
1. architect (필요 시)
2. implementer
3. tester
4. [Codex 리뷰 대기]
5. security-reviewer

### 블로커 없는 이슈 목록
| 이슈 | 제목 | 우선순위 |
|------|------|---------|
| DON-XXX | ... | P1 |

### 블로커 있는 이슈 (대기 중)
| 이슈 | 블로커 |
|------|--------|
| DON-YYY | DON-ZZZ 완료 필요 |
```
