import { test, expect } from '@playwright/test';

test.describe('Lane D-INTEGRITY: Addon integrity, ModifiedDialog, and Reinstall UI', () => {
  test.beforeEach(async ({ page }) => {
    // Set Details addon to modified before page loads
    await page.addInitScript(() => {
      const w = window as unknown as {
        __initialIntegrityOverrides?: Record<string, 'clean' | 'modified' | 'missing' | 'unknown'>;
      };
      w.__initialIntegrityOverrides = {
        details: 'modified',
      };
    });

    await page.goto('/?mock=1');
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.addon-row').first()).toBeVisible({ timeout: 5000 });
  });

  test('1. Modified addon displays amber "Modified" pill', async ({ page }) => {
    // Filter search to Details to position it in virtual list viewport
    const searchInput = page.getByLabel('Filter addons');
    await searchInput.fill('Details');

    const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
    await expect(detailsRow).toBeVisible();

    const modifiedPill = detailsRow.locator('.status-pill.pill-modified');
    await expect(modifiedPill).toBeVisible();
    await expect(modifiedPill).toHaveText('Modified');
    await expect(modifiedPill).toHaveAttribute('title', 'Local files modified');

    // Verify accessible role and label
    await expect(modifiedPill).toHaveAttribute('aria-label', /Modified files in Details! Damage Meter/);
  });

  test('2. Clicking "Modified" filter chip isolates modified addons', async ({ page }) => {
    const filterChips = page.locator('.filter-chips');
    await expect(filterChips).toBeVisible();

    const modifiedChip = filterChips.locator('button.filter-chip.chip-modified');
    await expect(modifiedChip).toBeVisible();
    await expect(modifiedChip).toContainText('Modified');

    // Click the Modified filter chip
    await modifiedChip.click();
    await expect(modifiedChip).toHaveAttribute('aria-selected', 'true');

    // Details should be visible in the isolated view
    const visibleRows = page.locator('.addon-row');
    await expect(visibleRows).toHaveCount(1);
    await expect(visibleRows.first()).toContainText('Details! Damage Meter');
    await expect(visibleRows.first().locator('.status-pill.pill-modified')).toBeVisible();

    // Reset filter by clicking All
    const allChip = filterChips.locator('button.filter-chip').filter({ hasText: /^All/ });
    await allChip.click();
    await expect(allChip).toHaveAttribute('aria-selected', 'true');
    await expect(page.locator('.addon-row').count()).resolves.toBeGreaterThan(1);
  });

  test('3. Clicking "Update" on a modified addon opens ModifiedDialog', async ({ page }) => {
    const searchInput = page.getByLabel('Filter addons');
    await searchInput.fill('Details');

    const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
    await expect(detailsRow).toBeVisible();

    // The interactive modified pill triggers the update confirmation dialog
    const updatePill = detailsRow.locator('.status-pill.pill-modified');
    await updatePill.click();

    // ModifiedDialog must open
    const dialog = page.locator('[data-testid="modified-dialog"]');
    await expect(dialog).toBeVisible();
    await expect(dialog.locator('#modified-title')).toHaveText('Local files modified');
    await expect(dialog.locator('#modified-message')).toHaveText(
      'You have edited files in this addon. Updating will overwrite your changes.'
    );

    // Verify all 3 action buttons exist with exact labels
    const btnZip = dialog.locator('[data-testid="btn-modified-update-zip"]');
    const btnAnyway = dialog.locator('[data-testid="btn-modified-update-anyway"]');
    const btnSkip = dialog.locator('[data-testid="btn-modified-skip"]');

    await expect(btnZip).toBeVisible();
    await expect(btnZip).toHaveText('Update and keep my copy as a zip');

    await expect(btnAnyway).toBeVisible();
    await expect(btnAnyway).toHaveText('Update anyway');

    await expect(btnSkip).toBeVisible();
    await expect(btnSkip).toHaveText('Skip');

    // Clicking Skip closes the dialog without updating
    await btnSkip.click();
    await expect(dialog).not.toBeVisible();
  });

  test('4. Selecting "Update and keep my copy as a zip" triggers update with backup_modified: true', async ({ page }) => {
    const searchInput = page.getByLabel('Filter addons');
    await searchInput.fill('Details');

    const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
    await expect(detailsRow).toBeVisible();

    // Open ModifiedDialog
    const updatePill = detailsRow.locator('.status-pill.pill-modified');
    await updatePill.click();

    const dialog = page.locator('[data-testid="modified-dialog"]');
    await expect(dialog).toBeVisible();

    // Click "Update and keep my copy as a zip"
    const btnZip = dialog.locator('[data-testid="btn-modified-update-zip"]');
    await btnZip.click();

    // Dialog must close
    await expect(dialog).not.toBeVisible();

    // Toast notification for update with backup
    const toast = page.locator('.toast');
    await expect(toast).toBeVisible();
    await expect(toast).toContainText('backing up local copy');

    // Verify mock recorded a zip backup with backup_modified: true
    await expect.poll(async () => {
      return page.evaluate(() => {
        const mock = (window as unknown as { __furphyMock?: { getMockZipBackups?: () => Array<{ params: Record<string, unknown> }> } }).__furphyMock;
        return mock?.getMockZipBackups?.() ?? [];
      });
    }).toEqual(expect.arrayContaining([
      expect.objectContaining({
        params: expect.objectContaining({
          backup_modified: true,
          override_modified: true,
        }),
      }),
    ]));

    // Verify addon status transitioned to clean
    await expect(detailsRow.locator('.status-pill.pill-modified')).not.toBeVisible();
  });

  test('5. Row menu shows "Show folder" and "Reinstall"; clicking "Reinstall" starts reinstall job', async ({ page }) => {
    const searchInput = page.getByLabel('Filter addons');
    await searchInput.fill('Details');

    const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
    await expect(detailsRow).toBeVisible();

    // Open row menu
    const menuTrigger = detailsRow.locator('.menu-trigger-btn');
    await menuTrigger.click();

    const dropdown = page.locator('.menu-dropdown');
    await expect(dropdown).toBeVisible();

    // Both Show folder and Reinstall should be present
    const showFolderBtn = dropdown.locator('button', { hasText: 'Show folder' });
    const reinstallBtn = dropdown.locator('button', { hasText: 'Reinstall' });

    await expect(showFolderBtn).toBeVisible();
    await expect(reinstallBtn).toBeVisible();

    // Click Show folder
    await showFolderBtn.click();
    await expect(dropdown).not.toBeVisible();

    await expect.poll(async () => {
      return page.evaluate(() => {
        const mock = (window as unknown as { __furphyMock?: { getShowFolderCalls?: () => Array<{ addon_id: string; flavour: string }> } }).__furphyMock;
        return mock?.getShowFolderCalls?.() ?? [];
      });
    }).toEqual(expect.arrayContaining([
      expect.objectContaining({ addon_id: 'details' }),
    ]));

    // Open row menu again and click Reinstall
    await menuTrigger.click();
    await expect(dropdown).toBeVisible();
    await reinstallBtn.click();

    // Reinstall toast notification appears
    const toast = page.locator('.toast');
    await expect(toast).toBeVisible();
    await expect(toast).toContainText('Reinstalling Details! Damage Meter');

    // Verify mock reinstall job was called
    await expect.poll(async () => {
      return page.evaluate(() => {
        const mock = (window as unknown as { __furphyMock?: { getReinstallCalls?: () => Array<{ params: Record<string, unknown> }> } }).__furphyMock;
        return mock?.getReinstallCalls?.() ?? [];
      });
    }).toEqual(expect.arrayContaining([
      expect.objectContaining({
        params: expect.objectContaining({ addon_id: 'details' }),
      }),
    ]));
  });
});
