import { test, expect } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

test.describe("Policy Editor", () => {
  test.beforeEach(async ({ page }) => {
    await setupAdminMock(page);

    // Login first
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/dashboard$/);
  });

  test("loads and displays policy YAML in editor", async ({ page }) => {
    // Navigate to policies page
    await page.click('a[href="/dashboard/policies"]');
    await expect(page).toHaveURL(/\/dashboard\/policies/);

    // Should show Policy Editor heading
    await expect(page.locator("text=Policy Editor")).toBeVisible();

    // Should display ETag
    await expect(page.locator("text=ETag:")).toBeVisible();
  });

  test("save button is disabled when no changes", async ({ page }) => {
    await page.click('a[href="/dashboard/policies"]');
    await expect(page.locator("text=Policy Editor")).toBeVisible();

    // Save button should be disabled (no changes)
    const saveButton = page.locator("button", { hasText: "Save" });
    await expect(saveButton).toBeDisabled();
  });

  test("shows success message after saving valid policy", async ({ page }) => {
    await page.click('a[href="/dashboard/policies"]');
    await expect(page.locator("text=Policy Editor")).toBeVisible();

    // Wait for Monaco editor to load and type in it
    const editor = page.locator(".monaco-editor textarea");
    await editor.waitFor({ state: "attached", timeout: 10000 });

    // Modify editor content by selecting all and typing
    await editor.focus();
    const selectAll = process.platform === "darwin" ? "Meta+a" : "Control+a";
    await page.keyboard.press(selectAll);
    await page.keyboard.type(
      'version: "1.0"\nglobal:\n  default_action: allow\n',
      { delay: 10 },
    );

    // Save button should be enabled now
    const saveButton = page.locator("button", { hasText: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    // Should show success message
    await expect(
      page.locator("text=Policy saved successfully"),
    ).toBeVisible();
  });

  test("shows error message for invalid YAML (missing version)", async ({
    page,
  }) => {
    await page.click('a[href="/dashboard/policies"]');
    await expect(page.locator("text=Policy Editor")).toBeVisible();

    // Wait for Monaco editor
    const editor = page.locator(".monaco-editor textarea");
    await editor.waitFor({ state: "attached", timeout: 10000 });

    // Type invalid YAML (no version key)
    await editor.focus();
    const selectAll = process.platform === "darwin" ? "Meta+a" : "Control+a";
    await page.keyboard.press(selectAll);
    await page.keyboard.type("global:\n  default_action: deny\n", {
      delay: 10,
    });

    // Click Save
    const saveButton = page.locator("button", { hasText: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    // Should show error (422 from mock)
    await expect(page.locator('[role="alert"], .bg-red-50')).toBeVisible();
  });

  test("reload button triggers hot reload", async ({ page }) => {
    await page.click('a[href="/dashboard/policies"]');
    await expect(page.locator("text=Policy Editor")).toBeVisible();

    // Click Reload
    const reloadButton = page.locator("button", { hasText: "Reload" });
    await reloadButton.click();

    // Should show success
    await expect(
      page.locator("text=Policy reloaded successfully"),
    ).toBeVisible();
  });
});
