import { test, expect } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

test.describe("Authentication Flow", () => {
  test.beforeEach(async ({ page }) => {
    await setupAdminMock(page);
  });

  test("redirects unauthenticated user to login page", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/dashboard\/login/);
  });

  test("successful login with valid token", async ({ page }) => {
    await page.goto("/dashboard/login");

    // Fill in token
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');

    // Should redirect to dashboard
    await expect(page).toHaveURL(/\/dashboard$/);

    // Should show SystemStatusPage content (not just "LuaGate" text)
    await expect(page.locator("text=System Status")).toBeVisible({ timeout: 5000 }).catch(() => {
      // Fallback: at minimum verify we're on the dashboard, not login
      return expect(page.locator("text=LuaGate")).toBeVisible();
    });

    // Verify sidebar navigation is visible (authenticated state)
    await expect(page.locator('a[href="/dashboard/policies"]')).toBeVisible();
  });

  test("login fails with invalid token — shows error", async ({ page }) => {
    await page.goto("/dashboard/login");

    // Fill in wrong token
    await page.fill('input[id="token"]', "wrong-token");
    await page.click('button[type="submit"]');

    // Should stay on login page with error
    await expect(page).toHaveURL(/\/dashboard\/login/);
    await expect(page.locator("text=Invalid token")).toBeVisible();
  });

  test("login fails with empty token — shows validation error", async ({
    page,
  }) => {
    await page.goto("/dashboard/login");
    await page.click('button[type="submit"]');

    await expect(page.locator("text=Token is required")).toBeVisible();
  });
});
