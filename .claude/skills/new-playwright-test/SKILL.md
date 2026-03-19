---
description: "Playwright E2E 테스트 파일 생성. Admin API mock + page object 패턴 기반 E2E 테스트 컨벤션."
---

# Skill: 새 Playwright E2E 테스트 생성

## 절차

1. **테스트 파일 생성**: `e2e/tests/<feature>.spec.ts`
2. **fixture import**: `admin-server.ts`에서 mock 세팅 import
3. **page object 생성** (필요 시): `e2e/pages/<PageName>Page.ts`
4. **테스트 작성**: beforeEach에서 상태 초기화 + 독립 실행 보장
5. **실행 검증**: `cd e2e && npx playwright test tests/<feature>.spec.ts`

## 1. 파일 위치

```
e2e/
├── fixtures/
│   └── admin-server.ts      # Admin API mock (공용)
├── pages/
│   └── <PageName>Page.ts    # Page Object (필요 시)
├── tests/
│   └── <feature>.spec.ts    # 테스트 파일
├── playwright.config.ts
└── tsconfig.json
```

## 2. Fixture 패턴

`admin-server.ts`는 Playwright `page.route()`를 사용해 Admin API를 인터셉트한다.
실제 서버 없이 UI 동작을 테스트할 수 있다.

```typescript
import { test, expect } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

// 인증이 필요한 페이지 테스트 — beforeEach에서 로그인
test.describe("Feature Name (authenticated)", () => {
  test.beforeEach(async ({ page }) => {
    await setupAdminMock(page);
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/dashboard$/);
  });

  test("should do something", async ({ page }) => {
    // 테스트 본문
  });
});

// 비인증/인증 실패 시나리오 — 로그인 없이 mock만 설정
test.describe("Feature Name (unauthenticated)", () => {
  test.beforeEach(async ({ page }) => {
    await setupAdminMock(page);
  });

  test("redirects to login when not authenticated", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/dashboard\/login/);
  });
});
```

### 환경변수

- `LUAGATE_ADMIN_TOKEN`: 실제 서버 테스트 시 토큰 주입
- `PLAYWRIGHT_BASE_URL`: 기본값 `http://localhost:9090/dashboard`

## 3. Page Object 패턴

복잡한 페이지는 Page Object로 분리한다.

```typescript
// e2e/pages/PoliciesPage.ts
import { type Page, type Locator, expect } from "@playwright/test";

export class PoliciesPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly saveButton: Locator;
  readonly editor: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.locator("text=Policy Editor");
    this.saveButton = page.locator("button", { hasText: "Save" });
    this.editor = page.locator(".monaco-editor textarea");
  }

  async goto() {
    await this.page.click('a[href="/dashboard/policies"]');
    await expect(this.heading).toBeVisible();
  }

  async waitForEditor() {
    await this.editor.waitFor({ state: "attached", timeout: 10000 });
  }
}
```

사용 예시:

```typescript
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";
import { PoliciesPage } from "../pages/PoliciesPage";

test("policy editor loads", async ({ page }) => {
  await setupAdminMock(page);
  await page.goto("/dashboard/login");
  await page.fill('input[id="token"]', VALID_TOKEN);
  await page.click('button[type="submit"]');

  const policies = new PoliciesPage(page);
  await policies.goto();
  await expect(policies.saveButton).toBeDisabled();
});
```

## 4. 어설션 패턴

```typescript
// URL 확인
await expect(page).toHaveURL(/\/dashboard\/policies/);

// 요소 가시성
await expect(page.locator("text=Policy Editor")).toBeVisible();

// 버튼 상태
await expect(page.locator("button", { hasText: "Save" })).toBeDisabled();

// API 응답 인터셉트 후 확인 (메서드 구분 필수)
const [response] = await Promise.all([
  page.waitForResponse(
    (res) => res.url().includes("/api/v1/policies") && res.request().method() === "PUT",
  ),
  page.locator("button", { hasText: "Save" }).click(),
]);
expect(response.status()).toBe(200);
```

## 5. 실패 처리

`playwright.config.ts`에 이미 설정됨:

- `screenshot: "only-on-failure"` — 실패 시 자동 스크린샷
- `video: "retain-on-failure"` — 실패 시 비디오 보존
- `trace: "on-first-retry"` — 첫 재시도에 trace 수집
- CI 환경: `retries: 2`

## 6. 금지 패턴

| 금지 | 이유 | 대안 |
|------|------|------|
| `page.waitForTimeout(ms)` | flaky 테스트 원인 | `expect(locator).toBeVisible()` 등 조건 대기 |
| URL 하드코딩 (`http://localhost:9090`) | 환경별 차이 | `page.goto("/dashboard")` (baseURL 자동 적용) |
| `page.waitForSelector()` | deprecated | `locator.waitFor()` 또는 `expect(locator)` |
| `test.only()` 커밋 | 다른 테스트 skip | CI에서 감지됨, 커밋 전 제거 |

## 7. Admin API Mock 패턴

`page.route()`로 `/api/v1/*` 요청을 인터셉트한다.

```typescript
// 커스텀 mock 응답 오버라이드 (특정 테스트에서)
test("shows error when health check fails", async ({ page }) => {
  // 1. 기본 mock 설정 (인증 등 다른 엔드포인트 활성화)
  await setupAdminMock(page);

  // 2. 특정 엔드포인트만 오버라이드 (setupAdminMock 이후)
  await page.route("**/health", (route) =>
    route.fulfill({
      status: 503,
      contentType: "application/json",
      body: JSON.stringify({ status: "unhealthy", reason: "policy not loaded" }),
    }),
  );

  // 3. 로그인 후 대시보드 접근
  await page.goto("/dashboard/login");
  await page.fill('input[id="token"]', VALID_TOKEN);
  await page.click('button[type="submit"]');
  await expect(page.locator("text=Health Check Failed")).toBeVisible();
});
```

### Mock 엔드포인트 목록 (`admin-server.ts`)

| 엔드포인트 | 메서드 | 인증 |
|-----------|--------|------|
| `/health` | GET | 불필요 |
| `/metrics` | GET | Bearer |
| `/api/v1/status` | GET | Bearer |
| `/api/v1/policies` | GET, PUT | Bearer |
| `/api/v1/policies/version` | GET | Bearer |
| `/api/v1/policies/reload` | POST | Bearer |

## 8. 테스트 격리

- 각 테스트는 **독립적으로 실행 가능**해야 함
- `beforeEach`에서 `setupAdminMock(page)` 호출 → 상태 초기화
- 테스트 간 공유 상태 금지 (전역 변수, 외부 파일 등)
- 병렬 실행 안전: 각 테스트가 자체 browser context 사용

## 체크리스트

- [ ] `e2e/tests/<feature>.spec.ts` 생성
- [ ] `beforeEach`에서 `setupAdminMock(page)` (인증 필요 시 로그인도 추가)
- [ ] `page.waitForTimeout()` 미사용
- [ ] URL 하드코딩 없음 (baseURL 활용)
- [ ] 각 테스트 독립 실행 가능
- [ ] `npx playwright test tests/<feature>.spec.ts` 로컬 통과

## 참조

- `e2e/fixtures/admin-server.ts` — Admin API mock 구현
- `e2e/playwright.config.ts` — Playwright 설정
- `docs/spec/admin-api.md` — Admin API 명세
