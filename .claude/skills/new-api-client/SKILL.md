---
description: "LuaGate Admin API 클라이언트 함수 생성. Bearer 인증, 에러 핸들링, TypeScript 타입 패턴."
---

# Skill: 새 API 클라이언트 함수 생성

## 절차

1. **파일 위치 결정**: `ui/src/api/<resource>.ts` (또는 기존 `client.ts`에 추가)
2. **응답 타입 정의**: TypeScript interface
3. **함수 구현**: `apiClient<T>()` 래퍼 사용
4. **에러 처리**: `ApiError` 클래스 활용
5. **타입 검사**: `cd ui && npx tsc --noEmit`

## 기본 패턴

### Base URL

```typescript
// ui/src/api/client.ts에서 import
import { apiClient, ApiResponse, ApiError } from "./client";
```

- Base URL: `import.meta.env.VITE_ADMIN_API_URL || "/api"`
- 개발 환경: Vite proxy (`/api` → `localhost:9090`)
- 프로덕션: same-origin `/api`

### 인증

- Bearer token: 현재 `localStorage.getItem("luagate_admin_token")` 사용 중 (인증 저장 방식 ADR 미확정 — `ui-review-checklist.md` 참조)
- `apiClient` 래퍼가 자동으로 `Authorization` 헤더 추가
- 401 응답 시: 자동 로그아웃 + 로그인 리다이렉트 처리 필요
- 계약: `.claude/knowledge/admin-auth-contract.md` 참조

### 에러 타입

```typescript
// ui/src/api/client.ts에 이미 정의됨
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
  ) {
    super(`API ${status}: ${statusText}`);
    this.name = "ApiError";
  }
}
```

## 엔드포인트별 함수 예시

### GET /health (인증 불필요)

> **주의**: `/health`와 `/metrics`는 `/api` prefix 하위가 아님.
> `apiClient()`는 `BASE_URL`(`/api`)을 자동 부여하므로 직접 `fetch` 사용 필요.

```typescript
export interface HealthResponse {
  status: "ok" | "unhealthy";
  source_version: string | null;
  active_http_version: string | null;
  active_stream_version: string | null;
  policy_loaded_at: string | null;
  ffi_watchdog_leak_count: number;
  reason?: string;
}

/** /health는 /api prefix 밖이므로 직접 fetch.
 *  Dev: Vite proxy에 /health → localhost:9090/health 매핑 필요 (vite.config.ts).
 *  Prod: same-origin이므로 상대 경로 "/health" 그대로 사용. */
export async function getHealth(): Promise<HealthResponse> {
  const response = await fetch("/health");
  if (!response.ok) throw new ApiError(response.status, response.statusText, "");
  return response.json();
}
```

### GET /metrics (Prometheus 텍스트)

```typescript
/** /metrics는 /api prefix 밖이므로 직접 fetch.
 *  Dev: Vite proxy에 /metrics → localhost:9090/metrics 매핑 필요.
 *  Prod: same-origin 상대 경로 사용. */
export async function getMetrics(): Promise<string> {
  const token = localStorage.getItem("luagate_admin_token");
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const response = await fetch("/metrics", { headers });
  if (!response.ok) throw new ApiError(response.status, response.statusText, "");
  return response.text();
}

/** Prometheus 텍스트 파싱 헬퍼 */
export function parsePrometheusText(text: string): Map<string, number> {
  const metrics = new Map<string, number>();
  for (const line of text.split("\n")) {
    if (line.startsWith("#") || line.trim() === "") continue;
    const match = line.match(/^(\S+)\s+(\S+)$/);
    if (match) {
      metrics.set(match[1], parseFloat(match[2]));
    }
  }
  return metrics;
}
```

### GET /api/v1/policies (YAML + ETag)

```typescript
// ui/src/api/client.ts에 이미 구현됨 — getPolicies()
export async function getPolicies(): Promise<{ yaml: string; etag: string | null }> {
  const { data, headers } = await apiClient<string>("/v1/policies");
  return { yaml: data, etag: headers.get("ETag") };
}
```

### PUT /api/v1/policies (YAML 업로드)

```typescript
// ui/src/api/client.ts에 이미 구현됨 — putPolicies()
export async function putPolicies(yaml: string, ifMatch: string): Promise<ApiResponse<unknown>> {
  return apiClient("/v1/policies", {
    method: "PUT",
    headers: { "Content-Type": "application/x-yaml", "If-Match": ifMatch },
    body: yaml,
  });
}
```

### POST /api/v1/policies/reload

```typescript
export interface ReloadResponse {
  previous_http_version: string;
  previous_stream_version: string;
  new_http_version: string;
  new_stream_version: string;
  http_result: string;
  stream_result: string;
  reloaded_at: string;
  warnings_count: number;
  errors: string[];
}

export async function reloadPolicies(): Promise<ReloadResponse> {
  const { data } = await apiClient<ReloadResponse>("/v1/policies/reload", {
    method: "POST",
  });
  return data;
}
```

## 401 자동 처리 패턴

> 인증 토큰 저장 방식은 ADR 미확정 (`ui-review-checklist.md` 참조). 현재는 `localStorage` 사용.

```typescript
// 앱 최상위에서 ApiError 401 인터셉트
function handleApiError(err: unknown): void {
  if (err instanceof ApiError && err.status === 401) {
    localStorage.removeItem("luagate_admin_token");
    window.location.href = "/dashboard/login";
  }
}
```

## 체크리스트

- [ ] 응답 타입 TypeScript interface 정의
- [ ] `apiClient<T>()` 래퍼 사용 (URL 하드코딩 금지)
- [ ] `ApiError` 클래스로 에러 처리
- [ ] 반환 타입 명시 (`Promise<T>`)
- [ ] `any` 타입 미사용
- [ ] Bearer token 자동 첨부 확인
- [ ] 401 처리 로직 포함
- [ ] 타입 검사 통과 (`npx tsc --noEmit`)

## 참조

- `ui/src/api/client.ts` — 기존 API 클라이언트 (apiClient, ApiError, getPolicies, putPolicies)
- `docs/spec/admin-api.md` — Admin API 엔드포인트 스펙
- `.claude/knowledge/admin-auth-contract.md` — 인증 계약
- `.claude/knowledge/frontend-conventions.md` — 코딩 컨벤션
