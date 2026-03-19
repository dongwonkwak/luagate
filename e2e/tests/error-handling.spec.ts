import { test, expect } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

test.describe("Error Handling", () => {
  test.beforeEach(async ({ page }) => {
    await setupAdminMock(page);
  });

  test("displays 401 error with spec-compliant message on invalid token", async ({
    page,
  }) => {
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', "wrong-token-value");
    await page.click('button[type="submit"]');

    // Should show spec-compliant error message
    await expect(page.locator("text=Invalid token")).toBeVisible();
    await expect(page).toHaveURL(/\/dashboard\/login/);
  });

  test("handles network error gracefully", async ({ page }) => {
    // Abort only the login validation request so the rest of the mocked API stays hermetic.
    await page.unroute("**/api/v1/policies/version");
    await page.route("**/api/v1/policies/version", (route) =>
      route.abort("failed"),
    );

    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');

    // Should show a connection error, not crash
    await expect(
      page.locator('[role="alert"], .bg-red-50, text=Failed'),
    ).toBeVisible({ timeout: 10000 });
  });

  test("invalid YAML submission shows validation error from server", async ({
    page,
  }) => {
    // Login first
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/dashboard$/);

    // Go to policy editor
    await page.click('a[href="/dashboard/policies"]');
    await expect(page.locator("text=Policy Editor")).toBeVisible();

    // Wait for Monaco and type invalid YAML
    const editor = page.locator(".monaco-editor textarea");
    await editor.waitFor({ state: "attached", timeout: 10000 });
    await editor.focus();
    const selectAll = process.platform === "darwin" ? "Meta+a" : "Control+a";
    await page.keyboard.press(selectAll);
    await page.keyboard.type("global:\n  default_action: deny\n", {
      delay: 10,
    });

    // Save should trigger 422
    const saveButton = page.locator("button", { hasText: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    // Should show error alert
    await expect(page.locator('[role="alert"], .bg-red-50')).toBeVisible();
  });
});
