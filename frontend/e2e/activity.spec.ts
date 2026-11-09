import { test, expect } from '@playwright/test';

test.describe('Furphy Addon Manager - Activity Log E2E', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to local Vite dev server in mock mode
    await page.goto('/?mock=1');
    // Wait for the app layout to load
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });
  });

  test('Activity view workflow: navigation, day grouping, flavour filtering, drawer opening, clear history', async ({
    page,
  }) => {
    // 1. Navigates to Activity view via Sidebar navigation item
    const activityNavItem = page.locator('.nav-item').filter({ hasText: 'Activity' });
    await expect(activityNavItem).toBeVisible();
    await activityNavItem.click();

    // Verify activity view is visible
    const activityView = page.getByTestId('activity-view');
    await expect(activityView).toBeVisible();

    // 2. Verifies records are rendered grouped under day headings ("Today")
    const todayHeading = page.locator('h2.day-heading', { hasText: 'Today' });
    await expect(todayHeading).toBeVisible();
    const items = page.getByTestId('activity-item');
    await expect(items.first()).toBeVisible();
    await expect(items.filter({ hasText: 'Details! Damage Meter' })).toBeVisible();

    // 3. Filters entries by flavour using game version filter
    const flavourFilter = page.getByTestId('activity-filter-flavour');
    await expect(flavourFilter).toBeVisible();
    await flavourFilter.selectOption('retail');

    // Retail items remain visible
    await expect(page.getByTestId('activity-item').filter({ hasText: 'Details! Damage Meter' })).toBeVisible();

    // 4. Clicks an entry and verifies that the drawer opens with the Changelog tab
    const detailsItem = page.getByTestId('activity-item').filter({ hasText: 'Details! Damage Meter' });
    await detailsItem.click();

    // Verify AddonDrawer is visible with Changelog active
    const drawerPanel = page.locator('.drawer-panel');
    await expect(drawerPanel).toBeVisible();
    const changelogTab = page.locator('.drawer-tabs button.tab-btn').filter({ hasText: 'Changelog' });
    await expect(changelogTab).toHaveClass(/is-active/);
    await expect(page.locator('.changelog-section')).toBeVisible();

    // Dismiss drawer to ensure clear button is accessible
    const closeBtn = page.getByLabel('Close drawer');
    if (await closeBtn.isVisible()) {
      await closeBtn.click();
      await expect(drawerPanel).not.toBeVisible();
    }

    // 5. Clicks "Clear history", confirms prompt, and verifies empty state text: "Nothing has changed yet."
    const clearBtn = page.getByTestId('btn-clear-activity');
    await expect(clearBtn).toBeVisible();

    // Handle the confirmation prompt
    page.once('dialog', async (dialog) => {
      await dialog.accept();
    });

    await clearBtn.click();

    // Verify empty state is displayed with exact text
    const emptyState = page.getByTestId('activity-empty-state');
    await expect(emptyState).toBeVisible();
    await expect(emptyState.locator('p')).toHaveText('Nothing has changed yet.');
  });
});
