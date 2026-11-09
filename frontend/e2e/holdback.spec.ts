import { test, expect, type Page } from '@playwright/test';

async function filterToDetails(page: Page) {
  const searchInput = page.getByLabel('Filter addons');
  await searchInput.fill('Details');
  const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
  await expect(detailsRow).toBeVisible();
  return detailsRow;
}

test.describe('Holdback and HoldDialog E2E', () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      window.sessionStorage.setItem('furphy_mock_held', JSON.stringify({ details: true }));
    });
    await page.goto('/?mock=1');
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.addon-row').first()).toBeVisible({ timeout: 5000 });
  });

  test('1. Row with held update displays "On hold" pill', async ({ page }) => {
    const detailsRow = await filterToDetails(page);

    const pill = detailsRow.locator('.status-pill.pill-held');
    await expect(pill).toBeVisible();
    await expect(pill).toHaveText('On hold');
  });

  test('2. Clicking "On hold" filter chip isolates held addons', async ({ page }) => {
    const heldChip = page.locator('.filter-chip.chip-held');
    await expect(heldChip).toBeVisible();
    await expect(heldChip).toContainText('On hold (1)');

    await heldChip.click();
    await expect(heldChip).toHaveAttribute('aria-selected', 'true');

    const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
    await expect(detailsRow).toBeVisible();

    const visibleRows = page.locator('.addon-row');
    await expect(visibleRows).toHaveCount(1);

    const pill = detailsRow.locator('.status-pill.pill-held');
    await expect(pill).toBeVisible();
    await expect(pill).toHaveText('On hold');
  });

  test('3. Clicking "Update" on a held row opens HoldDialog', async ({ page }) => {
    const detailsRow = await filterToDetails(page);

    const heldPill = detailsRow.locator('.status-pill.pill-held');
    await heldPill.click();

    const dialog = page.locator('[data-testid="hold-dialog"]');
    await expect(dialog).toBeVisible();
    await expect(dialog.locator('#hold-title')).toHaveText('Update held back');
    await expect(dialog.locator('#hold-message')).toHaveText(
      'This update is built for a newer version of World of Warcraft.'
    );
    await expect(dialog.locator('[data-testid="btn-hold-cancel"]')).toBeVisible();
    await expect(dialog.locator('[data-testid="btn-hold-ignore-build"]')).toBeVisible();
    await expect(dialog.locator('[data-testid="btn-hold-update-anyway"]')).toBeVisible();

    // Verify Cancel closes dialog
    await dialog.locator('[data-testid="btn-hold-cancel"]').click();
    await expect(dialog).not.toBeVisible();
  });

  test('4. Keyboard navigation: Escape cancels, Tab traverses buttons in order', async ({ page }) => {
    const detailsRow = await filterToDetails(page);
    const heldPill = detailsRow.locator('.status-pill.pill-held');
    await heldPill.click();

    const dialog = page.locator('[data-testid="hold-dialog"]');
    await expect(dialog).toBeVisible();

    const cancelBtn = dialog.locator('[data-testid="btn-hold-cancel"]');
    const ignoreBtn = dialog.locator('[data-testid="btn-hold-ignore-build"]');
    const updateAnywayBtn = dialog.locator('[data-testid="btn-hold-update-anyway"]');

    // Initial focus on Cancel button
    await expect(cancelBtn).toBeFocused();

    // Tab to Ignore for this WoW version
    await page.keyboard.press('Tab');
    await expect(ignoreBtn).toBeFocused();

    // Tab to Update anyway
    await page.keyboard.press('Tab');
    await expect(updateAnywayBtn).toBeFocused();

    // Escape closes dialog
    await page.keyboard.press('Escape');
    await expect(dialog).not.toBeVisible();
  });

  test('5. Clicking "Ignore for this WoW version" dismisses dialog, sends IPC, and changes pill to normal update', async ({ page }) => {
    const detailsRow = await filterToDetails(page);
    const heldPill = detailsRow.locator('.status-pill.pill-held');
    await heldPill.click();

    const dialog = page.locator('[data-testid="hold-dialog"]');
    await expect(dialog).toBeVisible();

    const ignoreBtn = dialog.locator('[data-testid="btn-hold-ignore-build"]');
    await ignoreBtn.click();

    await expect(dialog).not.toBeVisible();

    // Toast notification
    await expect(page.locator('.toast')).toContainText('Ignored updates for Details! Damage Meter');

    // Status pill changed to normal update
    const updatePill = detailsRow.locator('.status-pill.pill-update');
    await expect(updatePill).toBeVisible();
    await expect(updatePill).toContainText('Update');
  });

  test('6. Clicking "Update anyway" triggers update with override_hold: true', async ({ page }) => {
    const detailsRow = await filterToDetails(page);
    const heldPill = detailsRow.locator('.status-pill.pill-held');
    await heldPill.click();

    const dialog = page.locator('[data-testid="hold-dialog"]');
    await expect(dialog).toBeVisible();

    const updateAnywayBtn = dialog.locator('[data-testid="btn-hold-update-anyway"]');
    await updateAnywayBtn.click();

    await expect(dialog).not.toBeVisible();

    // Toast indicates updating
    await expect(page.locator('.toast')).toContainText('Updating Details! Damage Meter');

    // Check last sync parameters from mock
    const params = await page.evaluate(() => {
      const w = window as unknown as { __furphyMock?: { lastSyncParams?: Record<string, unknown> } };
      return w.__furphyMock?.lastSyncParams;
    });
    expect(params).toBeTruthy();
    expect(params?.override_hold).toBe(true);
    expect(params?.only).toEqual(['details']);
  });
});
