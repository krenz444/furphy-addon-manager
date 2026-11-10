import { test, expect, type Page } from '@playwright/test';

async function openList(page: Page) {
  await page.goto('/');
  await expect(page.locator('.virtual-list-container')).toBeVisible();
  await expect(page.locator('.addon-row').first()).toBeVisible();
}

test.describe('Copy addons to another game version', () => {
  test('the button shows when another game version is installed and opens the dialog with the selection ticked', async ({ page }) => {
    await openList(page);
    const boxes = page.locator('.addon-row .col-select input[type="checkbox"]');
    await boxes.nth(0).click();
    await boxes.nth(1).click();

    await page.locator('[data-testid="copy-open"]').click();
    const dialog = page.locator('[data-testid="copy-dialog"]');
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('Settings and saved variables are never copied.');
    await expect(page.locator('[data-testid="copy-target-select"]')).toBeVisible();
    await expect(page.locator('[data-testid="copy-run"]')).toContainText('2 addons');
  });

  test('select all and select none change the count and the button text', async ({ page }) => {
    await openList(page);
    await page.locator('[data-testid="copy-open"]').click();
    await expect(page.locator('[data-testid="copy-dialog"]')).toBeVisible();

    // With nothing selected in the list the dialog starts with every addon ticked.
    const all = (await page.locator('[data-testid="copy-run"]').textContent()) ?? '';
    expect(Number((all.match(/(\d+) addons/) ?? [])[1])).toBeGreaterThan(5);
    await expect(page.locator('[data-testid="copy-select-all"]')).toHaveText('Select none');

    await page.locator('[data-testid="copy-select-all"]').click();
    await expect(page.locator('[data-testid="copy-run"]')).toBeDisabled();
    await expect(page.locator('[data-testid="copy-dialog"]')).toContainText('Tick at least one addon.');

    await page.locator('[data-testid="copy-select-all"]').click();
    await expect(page.locator('[data-testid="copy-run"]')).toBeEnabled();
  });

  test('running shows installed, skipped and failed rows with their messages', async ({ page }) => {
    await openList(page);
    await page.evaluate(() => {
      const mock = (window as unknown as { __furphyMock: Record<string, unknown> }).__furphyMock;
      mock.copyFailMessage = 'No compatible CurseForge file found for WoW Forever';
    });
    const boxes = page.locator('.addon-row .col-select input[type="checkbox"]');
    await boxes.nth(0).click();
    await boxes.nth(1).click();
    await page.locator('[data-testid="copy-open"]').click();
    await page.locator('[data-testid="copy-target-select"]').selectOption({ index: 0 });
    await page.locator('[data-testid="copy-run"]').click();

    const results = page.locator('[data-testid="copy-results"]');
    await expect(results).toBeVisible();
    await expect(results).toContainText(/Installed|Skipped|Failed/);
    await expect(results).toContainText('No compatible CurseForge file found for WoW Forever');

    await page.locator('[data-testid="copy-close"]').click();
    await expect(page.locator('[data-testid="copy-dialog"]')).not.toBeVisible();
  });

  test('Escape closes the dialog and focus returns to the button', async ({ page }) => {
    await openList(page);
    const opener = page.locator('[data-testid="copy-open"]');
    await opener.click();
    await expect(page.locator('[data-testid="copy-dialog"]')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('[data-testid="copy-dialog"]')).not.toBeVisible();
    await expect(opener).toBeFocused();
  });
});
