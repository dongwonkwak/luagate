---
name: archive-memory
description: "마일스톤 완료 시 agent-memory 압축/아카이브. MEMORY.md에 한 줄 요약만 남기고 상세는 archive/로 이동."
trigger: "archive-memory | 메모리 압축 | 마일스톤 완료 | memory archive"
---

# archive-memory Skill

## 역할

마일스톤 완료 시 각 에이전트의 `agent-memory`를 압축하여 MEMORY.md를 200줄 이내로 유지한다.

## 실행 조건

- 마일스톤(Phase) 완료 시
- MEMORY.md가 150줄 초과 시 (예방적 압축)
- 사람이 명시적으로 요청 시

## 실행 절차

### 1. 대상 에이전트 확인

```
.claude/agent-memory/
├── architect/MEMORY.md
├── implementer/MEMORY.md
├── tester/MEMORY.md
└── security-reviewer/MEMORY.md
```

### 2. 각 MEMORY.md 압축

각 에이전트에 대해:

1. 현재 MEMORY.md 읽기
2. 마일스톤 명 + 날짜로 아카이브 파일 생성:
   ```
   .claude/agent-memory/<agent>/archive/<milestone>-<YYYY-MM-DD>.md
   ```
3. MEMORY.md를 다음 형식으로 재작성:

```markdown
# Current Focus
(없음)

# Key Decisions (latest first)
- <마일스톤명> 완료 (<날짜>): 상세는 archive/<파일명>.md

# Cross-Agent Notes
(없음)

# References
- archive/<마일스톤명>-<날짜>.md
```

### 3. 완료 보고

```markdown
## archive-memory 완료

**마일스톤**: <Phase N — 이름>
**날짜**: YYYY-MM-DD

### 아카이브 생성
| 에이전트 | 아카이브 파일 | 원본 크기 |
|---------|-------------|---------|
| architect | archive/phase-N-YYYY-MM-DD.md | 120줄 |
| implementer | archive/phase-N-YYYY-MM-DD.md | 85줄 |
| tester | archive/phase-N-YYYY-MM-DD.md | 60줄 |
| security-reviewer | archive/phase-N-YYYY-MM-DD.md | 45줄 |

### 갱신된 MEMORY.md
각 에이전트 MEMORY.md: 10줄 이내로 압축 완료
```

## 주의사항

- `.claude/agent-memory/` 전체가 `.gitignore` 대상 — 아카이브도 로컬 전용
- 마일스톤 요약은 PROGRESS.md에도 기록 (영구 보존)
- archive/ 디렉토리는 압축하지 않음 (나중에 참조 가능)
