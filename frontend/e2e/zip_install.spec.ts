import { test, expect, type Page } from '@playwright/test';

async function openZipPane(page: Page) {
  await page.goto('/');
  await page.locator('.sidebar-nav button').filter({ hasText: 'Get Addons' }).click();
  await page.locator('#tab-zip').click();
  await expect(page.locator('.zip-pane')).toBeVisible();
}

test.describe('Install from a zip file or link', () => {
  test('the install button is disabled with a visible reason until something is entered', async ({ page }) => {
    await openZipPane(page);
    await expect(page.locator('[data-testid="zip-install-btn"]')).toBeDisabled();
    await expect(page.locator('.zip-pane')).toContainText('Enter a path or an https link to a .zip file.');
  });

  test('installs a file by path and shows what was installed', async ({ page }) => {
    await openZipPane(page);
    await page.locator('[data-testid="zip-input"]').fill('C:/Downloads/FurphyProbe.zip');
    const button = page.locator('[data-testid="zip-install-btn"]');
    await expect(button).toBeEnabled();
    await expect(button).toContainText('Install to');
    await button.click();

    const result = page.locator('[data-testid="zip-result"]');
    await expect(result).toBeVisible();
    await expect(result).toContainText('Installed');
    await expect(result).toContainText('FurphyProbe');
    await expect(page.locator('[data-testid="zip-input"]')).toHaveValue('');
  });

  test('a failure is shown as text on the pane and the input keeps its value', async ({ page }) => {
    await openZipPane(page);
    await page.evaluate(() => {
      (window as unknown as { __furphyMock: { nextZipError?: string } }).__furphyMock.nextZipError = 'This zip does not contain a World of Warcraft addon: no folder with a .toc file was found.';
    });
    await page.locator('[data-testid="zip-input"]').fill('C:/Downloads/NotAnAddon.zip');
    await page.locator('[data-testid="zip-install-btn"]').click();

    const error = page.locator('[data-testid="zip-error"]');
    await expect(error).toBeVisible();
    await expect(error).toContainText('no folder with a .toc file was found');
    await expect(page.locator('[data-testid="zip-input"]')).toHaveValue('C:/Downloads/NotAnAddon.zip');
  });

  test('a dropped zip file fills the input and does not install by itself', async ({ page }) => {
    await openZipPane(page);
    await page.evaluate(() => {
      window.dispatchEvent(new CustomEvent('furphy:file-drop', { detail: { paths: ['C:/Downloads/notes.txt', 'C:/Downloads/Dropped.zip'] } }));
    });
    await expect(page.locator('[data-testid="zip-input"]')).toHaveValue('C:/Downloads/Dropped.zip');
    await expect(page.locator('[data-testid="zip-result"]')).not.toBeVisible();
  });

  test('the installed zip addon appears in My Addons with the zip source badge', async ({ page }) => {
    await openZipPane(page);
    await page.locator('[data-testid="zip-input"]').fill('C:/Downloads/BadgeProbe.zip');
    await page.locator('[data-testid="zip-install-btn"]').click();
    await expect(page.locator('[data-testid="zip-result"]')).toBeVisible();

    await page.locator('.sidebar-nav button').filter({ hasText: 'My Addons' }).click();
    // The mock list is long and virtualised, so narrow it to the new addon first.
    await page.getByPlaceholder(/Filter addons/i).fill('BadgeProbe');
    await expect(page.locator('.source-badge.source-zip').first()).toBeVisible();
  });
});
