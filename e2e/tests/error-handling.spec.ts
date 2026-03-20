import { test, expect, type Page } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

async function gotoPoliciesPage(page: Page) {
  await page.goto("/dashboard/policies");
  await expect(page).toHaveURL(/\/dashboard\/policies$/);
  await expect(
    page.getByRole("heading", { name: "Policy Editor" }),
  ).toBeVisible();
}

function getErrorAlert(page: Page) {
  return page.locator('div[role="alert"]').filter({ hasText: "API " }).first();
}

async function replaceEditorContent(page: Page, nextValue: string) {
  const editor = page.getByLabel("Policy YAML Editor");
  await expect(editor).toBeVisible({ timeout: 15000 });
  await editor.fill(nextValue);
}

test.describe("Error Handling", () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      (
        window as typeof window & {
          __LUAGATE_FORCE_PLAIN_EDITOR__?: boolean;
        }
      ).__LUAGATE_FORCE_PLAIN_EDITOR__ = true;
    });
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
    await expect(page.getByRole("alert")).toBeVisible({ timeout: 10000 });
  });

  test("invalid YAML submission shows validation error from server", async ({
    page,
  }) => {
    // Login first
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/dashboard$/);

    await gotoPoliciesPage(page);
    await replaceEditorContent(page, "global:\n  default_action: deny\n");

    const saveButton = page.getByRole("button", { name: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    await expect(getErrorAlert(page)).toBeVisible();
  });
});
