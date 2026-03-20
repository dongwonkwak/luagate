import { test, expect, type Page } from "@playwright/test";
import { setupAdminMock, VALID_TOKEN } from "../fixtures/admin-server";

async function gotoPoliciesPage(page: Page) {
  await page.goto("/dashboard/policies");
  await expect(page).toHaveURL(/\/dashboard\/policies$/);
  await expect(
    page.getByRole("heading", { name: "Policy Editor" }),
  ).toBeVisible();
}

async function getPolicyEditor(page: Page) {
  const editor = page
    .locator('textarea[aria-label="Policy YAML Editor"]')
    .first();
  await expect(editor).toBeVisible({ timeout: 15000 });
  return editor;
}

function getErrorAlert(page: Page) {
  return page.locator('div[role="alert"]').filter({ hasText: "API " }).first();
}

async function replaceEditorContent(page: Page, nextValue: string) {
  const editor = await getPolicyEditor(page);
  await editor.fill(nextValue);
}

test.describe("Policy Editor", () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      (
        window as typeof window & {
          __LUAGATE_FORCE_PLAIN_EDITOR__?: boolean;
        }
      ).__LUAGATE_FORCE_PLAIN_EDITOR__ = true;
    });
    await setupAdminMock(page);

    // Login first
    await page.goto("/dashboard/login");
    await page.fill('input[id="token"]', VALID_TOKEN);
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/\/dashboard$/);
  });

  test("loads and displays policy YAML in editor", async ({ page }) => {
    await gotoPoliciesPage(page);
    await getPolicyEditor(page);
    await expect(page.getByText("ETag:")).toBeVisible();
  });

  test("save button is disabled when no changes", async ({ page }) => {
    await gotoPoliciesPage(page);
    const saveButton = page.getByRole("button", { name: "Save" });
    await expect(saveButton).toBeDisabled();
  });

  test("shows success message after saving valid policy", async ({ page }) => {
    await gotoPoliciesPage(page);
    await replaceEditorContent(
      page,
      'version: "1.0"\nglobal:\n  default_action: allow\n',
    );

    const saveButton = page.getByRole("button", { name: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    await expect(page.getByText("Policy saved successfully.")).toBeVisible();
  });

  test("shows error message for invalid YAML (missing version)", async ({
    page,
  }) => {
    await gotoPoliciesPage(page);
    await replaceEditorContent(page, "global:\n  default_action: deny\n");

    const saveButton = page.getByRole("button", { name: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    await expect(getErrorAlert(page)).toBeVisible();
  });

  test("consecutive saves use updated ETag", async ({ page }) => {
    await gotoPoliciesPage(page);

    await replaceEditorContent(
      page,
      'version: "1.0"\nglobal:\n  default_action: allow\n',
    );
    const saveButton = page.getByRole("button", { name: "Save" });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();
    await expect(page.getByText("Policy saved successfully.")).toBeVisible();

    await replaceEditorContent(
      page,
      'version: "1.0"\nglobal:\n  default_action: deny\n',
    );
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    await expect(page.getByText("Policy saved successfully.")).toBeVisible();
  });

  test("accepts unquoted If-Match when policy version matches", async ({
    page,
  }) => {
    const result = await page.evaluate(async (token) => {
      const versionResponse = await fetch("/api/v1/policies/version", {
        headers: { Authorization: `Bearer ${token}` },
      });
      const version = await versionResponse.json();

      const saveResponse = await fetch("/api/v1/policies", {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/x-yaml",
          "If-Match": version.etag,
        },
        body: 'version: "1.0"\nglobal:\n  default_action: allow\n',
      });

      return {
        status: saveResponse.status,
        body: await saveResponse.json(),
      };
    }, VALID_TOKEN);

    expect(result.status).toBe(200);
    expect(result.body.http_result).toBe("committed");
  });

  test("reload button triggers hot reload", async ({ page }) => {
    await gotoPoliciesPage(page);

    const reloadButton = page.getByRole("button", { name: "Reload" });
    await reloadButton.click();

    await expect(page.getByText("Policy reloaded successfully.")).toBeVisible();
  });
});
