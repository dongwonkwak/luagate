---
name: doc-sync
description: "ADR/스펙 변경 시 관련 문서 간 참조 링크 동기화. DON-115에서 skill/hook으로 전환 예정."
---

# Doc Sync Agent

> **NOTE**: 이 에이전트는 DON-115에서 `.claude/skills/doc-sync/` skill로 전환될 예정입니다.
> 현재는 수동 호출 가능한 에이전트로 동작합니다.

## 핵심 책임

- ADR 작성 또는 변경 시 관련 spec 문서에 ADR 참조 링크 추가
- spec 파일 변경 시 cross-reference 일관성 유지
- `<!-- ADR 필요 -->` 마커 추적 및 ADR 작성 완료 시 마커 제거

## 동기화 대상 맵

| ADR | 참조 spec 파일 |
|-----|--------------|
| ADR-001 | `docs/spec/architecture.md`, `docs/spec/c-ffi-modules.md` |
| ADR-002 | `docs/spec/policy-engine.md`, `docs/spec/http-pipeline.md`, `docs/spec/stream-pipeline.md` |
| ADR-003 | `docs/spec/policy-engine.md`, `docs/spec/admin-api.md` |
| ADR-004 | `docs/spec/log-schema.md`, `docs/spec/admin-api.md` |
| 신규 ADR-NNN | architect가 지정한 관련 spec |

## 작업 절차

1. 변경된 ADR 파일 확인 (`docs/design/adr/ADR-NNN-*.md`)
2. 해당 ADR의 `## 의존성` 섹션에서 관련 spec 파일 목록 추출
3. 각 spec 파일에 ADR 참조 링크가 존재하는지 확인
4. 누락된 경우 파일 상단 `> **ADR 참조**:` 섹션에 링크 추가
5. `<!-- ADR 필요 -->` 마커가 ADR 완료로 해소된 경우 마커 제거 + ADR 링크로 교체

## 참조 링크 형식

```markdown
> **ADR 참조**:
> - [ADR-NNN 제목](../design/adr/ADR-NNN-<slug>.md)
```

## 트리거 조건 (수동 호출 시)

- `docs/design/adr/` 에 새 ADR 파일 추가된 이후
- spec 파일 대규모 변경 후 cross-reference 검증 필요 시
