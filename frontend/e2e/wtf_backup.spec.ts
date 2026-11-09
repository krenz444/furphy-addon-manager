import { test, expect } from '@playwright/test';

test.describe('Whole-WTF Archives Backup and Restore', () => {
  test('privacy note is visible, restore dialog opens with file counts, cancel and escape close it, confirm restores archive, and WoW running guards confirm', async ({ page }) => {
    await page.goto('/');

    const settingsNavBtn = page.locator('.sidebar-nav button').filter({ hasText: 'Settings' });
    await expect(settingsNavBtn).toBeVisible();
    await settingsNavBtn.click();
    await expect(page.locator('.settings-view')).toBeVisible();

    const panel = page.locator('[data-testid="wtf-backup-panel"]');
    if (!await panel.isVisible()) {
      const advancedToggle = page.locator('button, summary').filter({ hasText: /Advanced/i }).first();
      if (await advancedToggle.isVisible()) {
        await advancedToggle.click();
      }
    }
    await expect(panel).toBeVisible();

    const sampleBackups = [
      {
        id: 'wtf-backup-1',
        flavour: 'retail',
        created_at: new Date('2026-01-01T12:00:00Z').toISOString(),
        path: 'C:/mock/backups/retail_wtf_1.zip',
        file_count: 42,
        total_bytes: 1048576,
        note: 'Manual backup',
      },
    ];

    await page.evaluate((backups) => {
      window.dispatchEvent(
        new CustomEvent('furphy:wtf-backups', { detail: { backups } })
      );
    }, sampleBackups);

    const privacyNote = page.locator('[data-testid="wtf-privacy-note"]');
    await expect(privacyNote).toBeVisible();

    const restoreBtn = page.locator('[data-testid="btn-wtf-restore"]').first();
    await expect(restoreBtn).toBeVisible();
    await restoreBtn.click();

    const dialog = page.locator('[data-testid="wtf-restore-dialog"]');
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('42 files');
    await expect(dialog).toContainText('40 files');

    const cancelBtn = page.locator('[data-testid="wtf-restore-cancel"]');
    await expect(cancelBtn).toBeVisible();
    await cancelBtn.click();
    await expect(dialog).not.toBeVisible();

    await restoreBtn.click();
    await expect(dialog).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(dialog).not.toBeVisible();

    await restoreBtn.click();
    await expect(dialog).toBeVisible();
    const confirmBtn = page.locator('[data-testid="wtf-restore-confirm"]');
    await expect(confirmBtn).toBeVisible();

    await page.evaluate(() => {
      window.dispatchEvent(
        new CustomEvent('furphy:game-running', { detail: { running: true } })
      );
    });

    await expect(confirmBtn).toBeDisabled();
    await expect(dialog).toContainText('Restore cannot proceed while World of Warcraft is running. Exit the game first.');

    await page.evaluate(() => {
      window.dispatchEvent(
        new CustomEvent('furphy:game-running', { detail: { running: false } })
      );
    });
    await expect(confirmBtn).toBeEnabled();

    await confirmBtn.click();
    await expect(dialog).not.toBeVisible();
    await expect(page.locator('.toast')).toContainText('WTF restored from the archive');
  });

  test('Back up WTF now creates a new backup entry', async ({ page }) => {
    await page.goto('/');

    const settingsNavBtn = page.locator('.sidebar-nav button').filter({ hasText: 'Settings' });
    await expect(settingsNavBtn).toBeVisible();
    await settingsNavBtn.click();
    await expect(page.locator('.settings-view')).toBeVisible();

    const panel = page.locator('[data-testid="wtf-backup-panel"]');
    if (!await panel.isVisible()) {
      const advancedToggle = page.locator('button, summary').filter({ hasText: /Advanced/i }).first();
      if (await advancedToggle.isVisible()) {
        await advancedToggle.click();
      }
    }
    await expect(panel).toBeVisible();

    const initialCount = await page.locator('.backup-item').count();

    const backupNowBtn = page.locator('[data-testid="btn-wtf-backup-now"]');
    await expect(backupNowBtn).toBeVisible();
    await backupNowBtn.click();

    await expect(page.locator('.toast')).toContainText('WTF backup initiated');
    await expect(page.locator('.backup-item')).toHaveCount(initialCount + 1);
  });
});
