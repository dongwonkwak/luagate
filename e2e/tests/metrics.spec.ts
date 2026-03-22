import { test, expect } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

test.describe("Metrics Dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await setupAdminMock(page);

    // Login
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/dashboard$/);
  });

  test("displays metrics page with charts", async ({ page }) => {
    await page.click('a[href="/dashboard/metrics"]');
    await expect(page).toHaveURL(/\/dashboard\/metrics/);

    // Should show Metrics heading
    await expect(
      page.getByRole("heading", { name: "Metrics", exact: true }),
    ).toBeVisible();

    // Should show metric cards
    await expect(
      page.locator("text=HTTP Requests Total"),
    ).toBeVisible();
    await expect(
      page.locator("text=Active Connections"),
    ).toBeVisible();
    await expect(page.locator("text=Shared Dict Memory")).toBeVisible();
    await expect(page.locator("text=All Metrics")).toBeVisible();
  });

  test("shows auto-refresh indicator", async ({ page }) => {
    await page.click('a[href="/dashboard/metrics"]');
    await expect(page.locator("text=Auto-refresh every 30s")).toBeVisible();
  });

  test("raw metrics table shows metric names", async ({ page }) => {
    await page.click('a[href="/dashboard/metrics"]');

    // Should display metric names in the table
    await expect(
      page.locator("text=luagate_http_requests_total"),
    ).toBeVisible();
    await expect(
      page.locator("text=luagate_active_connections"),
    ).toBeVisible();
  });
});
