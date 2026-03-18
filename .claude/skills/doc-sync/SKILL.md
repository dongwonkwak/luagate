---
description: "ADR/스펙 변경 후 관련 문서 참조 링크 동기화. ADR 추가 시 관련 spec에 링크 추가, 완료 마커 교체."
---

# Skill: 문서 참조 동기화 (doc-sync)

> DON-115에서 `.claude/agents/doc-sync.md` 에이전트를 이 skill로 전환.
> 이 skill은 특정 이벤트(ADR 추가, spec 변경) 후 수동으로 invoke한다.

## 트리거 조건

- `docs/design/adr/` 에 새 ADR 파일 추가 후
- spec 파일 대규모 변경 후 cross-reference 검증 필요 시
- `<!-- ADR 필요 -->` 마커가 있는 구간 구현 완료 후

## 절차

1. 변경된 ADR 파일 확인 (`docs/design/adr/ADR-NNN-*.md`)
2. 해당 ADR의 `## 의존성` 섹션에서 관련 spec 파일 목록 추출
3. 각 spec 파일의 `> **ADR 참조**:` 섹션 확인
4. 누락된 링크 추가
5. 완료된 `<!-- ADR 필요 -->` 마커 교체

## 참조 링크 형식

```markdown
> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-NNN 새 제목](../design/adr/ADR-NNN-<slug>.md)
```

## 마커 교체

```markdown
<!-- 전: ADR 미작성 마커 -->
<!-- ADR 필요 -->
> **TODO**: <설명>

<!-- 후: ADR 완료 후 교체 -->
> **ADR 참조**: [ADR-NNN 제목](../design/adr/ADR-NNN-<slug>.md)
```

## ADR ↔ Spec 동기화 맵

| ADR | 연결 spec 파일 |
|-----|--------------|
| ADR-001 | `architecture.md`, `rust-ffi-modules.md` |
| ADR-002 | `policy-engine.md`, `http-pipeline.md`, `stream-pipeline.md` |
| ADR-003 | `policy-engine.md`, `admin-api.md` |
| ADR-004 | `log-schema.md`, `admin-api.md` |
| 신규 ADR | architect가 ADR `## 의존성` 섹션에 명시 |

## 체크리스트

- [ ] 새 ADR의 `## 의존성` 확인
- [ ] 연결 spec 파일들에 ADR 참조 링크 존재 확인
- [ ] 누락 링크 추가
- [ ] 완료된 `<!-- ADR 필요 -->` 마커 교체
- [ ] knowledge 파일 (`architecture.md` 등) ADR 목록 갱신

## 참조

- `docs/design/adr/` — ADR 파일들
- `docs/spec/` — spec 파일들
- `.claude/knowledge/conventions.md` — same-PR 규칙
