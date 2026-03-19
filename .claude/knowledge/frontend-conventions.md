# Frontend Conventions

> **대상**: frontend-developer 에이전트, new-react-component/new-api-client 스킬
> **참조**: `docs/spec/admin-api.md`, `.claude/knowledge/admin-auth-contract.md`

## 1. 프로젝트 구조

```
ui/
├── src/
│   ├── api/          # Admin API 클라이언트 (new-api-client 스킬)
│   ├── components/   # React 컴포넌트 (new-react-component 스킬)
│   ├── pages/        # 페이지 레벨 컴포넌트
│   ├── hooks/        # 커스텀 훅 (useAuth, useMetrics, usePolicies)
│   └── main.tsx      # 진입점
├── index.html
└── vite.config.ts
```

## 2. 기술 스택 및 버전

| 라이브러리 | 버전 | 용도 | 상태 |
|-----------|------|------|------|
| React | 19 | UI 프레임워크 | 설치됨 |
| TypeScript | 5 | strict mode 필수 | 설치됨 |
| Vite | 6 | 빌드 + HMR | 설치됨 |
| Tailwind CSS | 3 | 유틸리티 기반 스타일 | 설치됨 |
| Monaco Editor | — | 정책 YAML 편집기 | 미설치 (후보) |
| Recharts | — | 메트릭 시각화 | 미설치 (후보) |
| Zustand | — | 전역 상태관리 | 미설치 (후보) |

## 3. Admin API 연동 계약

- **Base URL**: `import.meta.env.VITE_ADMIN_API_URL || "/api"` (환경변수)
- **인증**: Bearer token ([admin-auth-contract.md](admin-auth-contract.md) 참조)
  - 토큰 저장: 현재 `localStorage` 사용 중 (인증 저장 방식 ADR 미확정 — `ui-review-checklist.md` 참조)
  - 401 응답 시: `apiClient()`는 `ApiError`만 throw하므로 호출자가 명시적으로 401을 처리해야 함 (예: 토큰 삭제 + 로그인 화면 리다이렉트). 자동 로그아웃/리다이렉트는 현재 구현되어 있지 않음
- **API 클라이언트**: `ui/src/api/client.ts`의 `apiClient<T>()` 래퍼 사용
- **ETag**: 정책 조회 시 ETag 반환 → PUT 시 `If-Match` 헤더로 전달 (낙관적 동시성)
- **CORS**: 개발 환경에서는 Vite proxy 사용 (`/api` → `localhost:9090`)

## 4. 코딩 컨벤션

### 네이밍

| 대상 | 규칙 | 예시 |
|------|------|------|
| 컴포넌트 | PascalCase, 파일명 = 컴포넌트명 | `PolicyEditor.tsx` |
| 훅 | `use` prefix, camelCase | `useMetrics.ts` |
| API 함수 | camelCase 동사 + 명사 | `getPolicies`, `putPolicies` |
| 타입/인터페이스 | PascalCase | `PolicyRule`, `ApiResponse<T>` |
| 상수 | UPPER_SNAKE_CASE | `API_BASE`, `POLL_INTERVAL_MS` |

### TypeScript

- **strict mode 필수** — `tsconfig.json`에서 `strict: true`
- **`any` 타입 사용 금지** — `unknown` + type guard 사용
- **모든 API 함수에 반환 타입 명시** — `Promise<T>` 형태

### React

- **함수형 컴포넌트만** — class component 금지
- **Props interface 필수** — 컴포넌트와 같은 파일에 정의
- **에러 처리** — 모든 API 호출에 try/catch + 사용자 친화적 에러 메시지 표시
- **key prop** — 리스트 렌더링 시 안정적 key 사용 (index 지양)

### 스타일

- **Tailwind utility class 사용** — inline style 금지
- **`cn()` 헬퍼** — 조건부 클래스 결합 시 사용
- **다크 모드**: 현재 미지원 (Phase 3 예정)

## 5. nginx static serving 설정

- 빌드 산출물: `ui/dist/` → nginx `/dashboard` location에서 서빙
- `conf/nginx.conf` Admin server block에 이미 설정됨:
  ```nginx
  location /dashboard {
      alias /etc/luagate/ui/dist;
      try_files $uri $uri/ /dashboard/index.html;
  }
  ```

## 6. 금지 패턴

| 금지 | 이유 |
|------|------|
| `localStorage`에 YAML 정책 저장 | 보안: 대용량 정책 데이터 로컬 노출 |
| Admin API 토큰 `console.log` 출력 | 보안: 토큰 노출 |
| `any` 타입 사용 | 타입 안전성 훼손 |
| API URL 하드코딩 | 환경 이식성 (환경변수 사용) |
| inline style (`style={{...}}`) | Tailwind 일관성 |
| `var` 키워드 | ES6+ `const`/`let` 사용 |

## 7. 테스트 컨벤션

- **단위 테스트**: 추후 결정 (Vitest 후보, 현재 미설치)
- **E2E 테스트**: Playwright (`e2e/` — scaffold만 존재)
- **테스트 파일 위치**: 컴포넌트와 같은 디렉토리의 `__tests__/` 하위
- **Mock**: API 호출은 직접 mock 또는 MSW (미설치 후보) 사용
