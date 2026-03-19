---
description: "LuaGate Admin 대시보드용 React 컴포넌트 생성. TypeScript + Tailwind 기반 뼈대 자동 생성."
---

# Skill: 새 React 컴포넌트 생성

## 절차

1. **파일 생성**: `ui/src/components/<ComponentName>.tsx`
2. **Props interface 정의**: 컴포넌트 상단에 `<ComponentName>Props` interface
3. **컴포넌트 구현**: `React.FC<Props>` 패턴, default export
4. **스타일 적용**: Tailwind utility class 사용
5. **테스트 파일 생성**: `ui/src/components/__tests__/<ComponentName>.test.tsx`
6. **ESLint + 타입 검사**: `cd ui && npm run lint && npx tsc --noEmit`

## 컴포넌트 뼈대

```tsx
interface PolicyEditorProps {
  initialYaml: string;
  etag: string | null;
  onSave: (yaml: string) => void;
}

export default function PolicyEditor({ initialYaml, etag, onSave }: PolicyEditorProps) {
  const [yaml, setYaml] = useState(initialYaml);
  const [error, setError] = useState<string | null>(null);

  const handleSave = async () => {
    if (!etag) {
      setError("ETag가 없습니다. 정책을 다시 조회해주세요.");
      return;
    }
    try {
      await putPolicies(yaml, etag);
      onSave(yaml);
    } catch (err) {
      if (err instanceof ApiError) {
        setError(`저장 실패: ${err.statusText}`);
      }
    }
  };

  if (error) {
    return <div className="rounded-md bg-red-50 p-4 text-red-700">{error}</div>;
  }

  return (
    <div className="flex flex-col gap-4">
      {/* Monaco Editor 또는 textarea */}
      <button
        onClick={handleSave}
        className="rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
      >
        저장
      </button>
    </div>
  );
}
```

## 체크리스트

- [ ] `ui/src/components/<ComponentName>.tsx` 생성
- [ ] Props interface 정의 (PascalCase, 컴포넌트명 + `Props`)
- [ ] default export 사용
- [ ] Tailwind utility class로 스타일 (inline style 금지)
- [ ] API 호출 시 try/catch + 사용자 친화적 에러 표시
- [ ] `any` 타입 미사용 (strict TypeScript)
- [ ] API URL 하드코딩 금지 (`apiClient` 래퍼 사용)
- [ ] 테스트 파일 생성 (`__tests__/<ComponentName>.test.tsx`)
- [ ] ESLint + 타입 검사 통과

## 대표 컴포넌트 예시

| 컴포넌트 | 용도 | API 연동 |
|---------|------|---------|
| `PolicyEditor` | YAML 정책 편집 (Monaco Editor) | `getPolicies`, `putPolicies` |
| `MetricsChart` | Prometheus 메트릭 시각화 (Recharts) | `GET /metrics` (텍스트 파싱) |
| `LogViewer` | 실시간 로그 스트림 표시 | `GET /api/v1/audit` |
| `HealthStatus` | 헬스체크 상태 표시 | `GET /health` |
| `RuleList` | 정책 규칙 목록 | `getPolicies` (YAML 파싱) |

## 참조

- `.claude/knowledge/frontend-conventions.md` — 코딩 컨벤션
- `.claude/knowledge/ui-review-checklist.md` — UI 리뷰 체크리스트
- `ui/src/api/client.ts` — API 클라이언트 패턴
