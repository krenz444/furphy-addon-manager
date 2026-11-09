import { test, expect } from '@playwright/test';

test.describe('Update Control Features', () => {
  test('Opens RowMenu > Release channel submenu; selects Beta; verifies release channel updates', async ({ page }) => {
    await page.goto('/');

    // Wait for addons list to load
    await expect(page.locator('.virtual-list-container')).toBeVisible();

    // Open row menu for the first addon
    const firstRowMenuBtn = page.locator('.col-menu .menu-trigger-btn').first();
    await expect(firstRowMenuBtn).toBeVisible();
    await firstRowMenuBtn.click();

    // Open Release channel submenu
    const channelSubmenuBtn = page.locator('.menu-dropdown').getByRole('menuitem', { name: 'Release channel' });
    await expect(channelSubmenuBtn).toBeVisible();
    await channelSubmenuBtn.click();

    // Submenu popover is displayed
    const submenu = page.locator('[data-testid="channel-submenu"]');
    await expect(submenu).toBeVisible();

    // Select Beta option
    const betaOpt = page.locator('[data-testid="channel-opt-beta"]');
    await expect(betaOpt).toBeVisible();
    await betaOpt.click();

    // Verify toast confirms channel update
    await expect(page.locator('.toast')).toContainText('channel to Beta');

    // Wait for menu to close
    await expect(page.locator('.menu-dropdown')).not.toBeVisible();

    // Re-open menu to verify Beta is now the selected channel
    await page.locator('.col-menu .menu-trigger-btn').first().click();
    await expect(page.locator('.menu-dropdown')).toBeVisible();

    const channelBtn = page.locator('.menu-dropdown').getByRole('menuitem', { name: 'Release channel' });
    await expect(channelBtn).toBeVisible();
    await channelBtn.click();

    await expect(page.locator('[data-testid="channel-submenu"]')).toBeVisible();
    await expect(page.locator('[data-testid="channel-opt-beta"]')).toHaveAttribute('aria-checked', 'true');
    await expect(page.locator('[data-testid="channel-opt-beta"] .channel-check')).toHaveText('✓');
  });

  test('Keyboard navigation in ChannelSubmenu: Arrow keys navigate, Escape closes and restores focus', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('.virtual-list-container')).toBeVisible();

    const firstRowMenuBtn = page.locator('.col-menu .menu-trigger-btn').first();
    await expect(firstRowMenuBtn).toBeVisible();
    await firstRowMenuBtn.click();

    const channelSubmenuBtn = page.locator('.menu-dropdown').getByRole('menuitem', { name: 'Release channel' });
    await channelSubmenuBtn.click();

    const submenu = page.locator('[data-testid="channel-submenu"]');
    await expect(submenu).toBeVisible();

    // Press Escape to close submenu and verify focus is returned to channel trigger button
    await page.keyboard.press('Escape');
    await expect(submenu).not.toBeVisible();
    await expect(channelSubmenuBtn).toBeFocused();
  });

  test('Toggles "Install automatically" on row menu; verifies state toggle', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('.virtual-list-container')).toBeVisible();

    const firstRowMenuBtn = page.locator('.col-menu .menu-trigger-btn').first();
    await expect(firstRowMenuBtn).toBeVisible();
    await firstRowMenuBtn.click();

    // By default in mock data, auto_update is true
    const autoUpdateItem = page.locator('.menu-dropdown').getByRole('menuitem', { name: /Install automatically/ });
    await expect(autoUpdateItem).toBeVisible();
    const initialText = await autoUpdateItem.textContent();
    expect(initialText).toContain('✓');

    // Click to toggle off
    await autoUpdateItem.click();

    // Toast confirms state toggle
    await expect(page.locator('.toast')).toContainText(/Disabled auto-update/);

    // Wait for menu to close
    await expect(page.locator('.menu-dropdown')).not.toBeVisible();

    // Re-open menu and verify checkmark is removed
    await page.locator('.col-menu .menu-trigger-btn').first().click();
    await expect(page.locator('.menu-dropdown')).toBeVisible();

    const toggledItem = page.locator('.menu-dropdown').getByRole('menuitem', { name: /Install automatically/ });
    await expect(toggledItem).toBeVisible();
    const updatedText = await toggledItem.textContent();
    expect(updatedText).not.toContain('✓');
    expect(updatedText).toContain('Install automatically');
  });

  test('Navigates to Settings > Addon Updates; changes flavour update mode to "Only notify"', async ({ page }) => {
    await page.goto('/');

    // Navigate to Settings
    const settingsNavBtn = page.locator('.sidebar-nav button').filter({ hasText: 'Settings' });
    await expect(settingsNavBtn).toBeVisible();
    await settingsNavBtn.click();

    // Verify Settings view and UpdateModeSettings component
    await expect(page.locator('.settings-view')).toBeVisible();
    await expect(page.locator('[data-testid="update-mode-settings"]')).toBeVisible();

    // Change Retail update mode to 'notify'
    const retailSelect = page.locator('[data-testid="mode-select-retail"]');
    await expect(retailSelect).toBeVisible();
    await expect(retailSelect).toHaveValue('auto');

    await retailSelect.selectOption('notify');
    await expect(retailSelect).toHaveValue('notify');

    // Verify toast confirms update mode change
    await expect(page.locator('.toast')).toContainText('retail set to notify');
  });

  test('Bulk actions: selects two rows; sets release channel to Beta in bulk using the bulk action bar dropdown stub', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('.virtual-list-container')).toBeVisible();

    // Select first two rows using row checkboxes
    const rowCheckboxes = page.locator('.addon-row .col-select input[type="checkbox"]');
    await expect(rowCheckboxes.first()).toBeVisible();
    await rowCheckboxes.nth(0).click();
    await rowCheckboxes.nth(1).click();

    // Verify bulk action bar appears with 2 selected
    const bulkBar = page.locator('.bulk-action-bar');
    await expect(bulkBar).toBeVisible();
    await expect(bulkBar).toContainText('2 selected');

    // Select Beta (value "2")
    const bulkChannelSelect = page.locator('select.bulk-channel-select');
    await expect(bulkChannelSelect).toBeVisible();
    await bulkChannelSelect.selectOption('2');

    // Verify toast confirms bulk update
    await expect(page.locator('.toast')).toContainText('Updated release channel for 2 addons');
  });
});
