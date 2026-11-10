import { test, expect, type Page } from '@playwright/test';

async function openTukuiPane(page: Page) {
  await page.goto('/');
  await page.locator('.sidebar-nav button').filter({ hasText: 'Get Addons' }).click();
  await page.locator('#tab-tukui').click();
  await expect(page.locator('.tukui-pane')).toBeVisible();
}

test.describe('Tukui tab', () => {
  test('lists ElvUI and Tukui with their version and supported game versions', async ({ page }) => {
    await openTukuiPane(page);
    const elvui = page.locator('[data-testid="tukui-card-elvui"]');
    await expect(elvui).toBeVisible();
    await expect(elvui).toContainText('ElvUI');
    await expect(elvui).toContainText('Works with');
    await expect(page.locator('[data-testid="tukui-card-tukui"]')).toBeVisible();
  });

  test('a compatible addon installs through the add job and then shows as installed', async ({ page }) => {
    await openTukuiPane(page);
    const button = page.locator('[data-testid="tukui-install-elvui"]');
    await expect(button).toBeEnabled();
    await button.click();
    await expect(page.locator('[data-testid="tukui-card-elvui"]')).toContainText('Installed');
  });

  test('an addon that does not list the target game version is disabled with the reason as text', async ({ page }) => {
    await page.goto('/');
    await page.evaluate(() => {
      const mock = (window as unknown as { __furphyMock: { setMockTukui?: (list: unknown[]) => void } }).__furphyMock;
      mock.setMockTukui?.([
        {
          slug: 'elvui', name: 'ElvUI', author: 'Elv', version: '12.1.5', last_update: '2026-11-09',
          supported_patches: ['12.1.5'], summary: 'A complete UI', web_url: null,
          compatible: false, reason: 'Tukui lists 12.1.5 for this addon, not 1.60.x, the game version of WoW Forever.', installed: false,
        },
      ]);
    });
    await page.locator('.sidebar-nav button').filter({ hasText: 'Get Addons' }).click();
    await page.locator('#tab-tukui').click();

    await expect(page.locator('[data-testid="tukui-install-elvui"]')).toBeDisabled();
    await expect(page.locator('[data-testid="tukui-reason-elvui"]')).toContainText('not 1.60.x');
  });
});
