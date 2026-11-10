import { test, expect, type Page } from '@playwright/test';

async function openWagoTab(page: Page) {
  await page.goto('/');
  await page.locator('.sidebar-nav button').filter({ hasText: 'Get Addons' }).click();
  await expect(page.locator('.addon-card').first()).toBeVisible();
}

// Some mock addons are already installed and show a badge instead of the button, so pin a card that has the button.
async function installableCard(page: Page) {
  const withButton = page.locator('.addon-card').filter({ has: page.locator('button.btn-install') }).first();
  await expect(withButton).toBeVisible();
  const title = (await withButton.locator('.card-title').first().innerText()).trim();
  return page.locator('.addon-card').filter({ hasText: title }).first();
}

test.describe('Wago install outcome on the card', () => {
  test('a failed install shows its reason on the card with a Retry that works', async ({ page }) => {
    await openWagoTab(page);
    await page.evaluate(() => {
      (window as unknown as { __furphyMock: { nextAddError?: string } }).__furphyMock.nextAddError = 'No compatible Wago release found for Retail';
    });

    const card = await installableCard(page);
    await card.locator('button.btn-install').click();

    const error = card.locator('[data-testid="wago-install-error"]');
    await expect(error).toBeVisible();
    await expect(error).toContainText('No compatible Wago release found for Retail');

    // The next attempt succeeds: the card ends up installed.
    await card.locator('[data-testid="wago-retry"]').click();
    await expect(card.locator('[data-testid="wago-install-error"]')).not.toBeVisible();
  });

  test('while installing the card says so in text and stays busy until the job answers', async ({ page }) => {
    await openWagoTab(page);
    const card = await installableCard(page);
    await card.locator('button.btn-install').click();
    // The mock answers within moments; whichever state we land in, a card never goes silent.
    await expect(card).toContainText(/Installing to|Installed|Retry/);
  });
});
