import { test, expect } from '@playwright/test';
import path from 'path';

const OUTPUT_DIR = 'C:/Users/drops/Documents/3d/furphy-site/images';

test.describe('Furphy V2 Authentic Screenshots Capture', () => {
  test.use({
    viewport: { width: 1400, height: 900 },
  });

  test('capture all four authentic 1400x900 screenshots', async ({ page }) => {
    // 1. Navigate to local Vite dev server in mock mode
    await page.goto('/?mock=1');
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 15000 });

    // Wait for virtualized rows and freshness banner to render cleanly
    const rows = page.locator('.addon-row');
    await expect(rows.first()).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.freshness-box')).toBeVisible({ timeout: 5000 });

    // Wait for fonts and styling to settle
    await page.waitForTimeout(1000);

    // Screenshot 1: screenshot-my-addons.png (Tokyo Rain theme, My Addons view)
    const screenshot1Path = path.join(OUTPUT_DIR, 'screenshot-my-addons.png');
    await page.screenshot({ path: screenshot1Path });
    console.log(`Saved screenshot 1 to ${screenshot1Path}`);

    // Screenshot 2: screenshot-wago-browse.png (Get Addons view)
    const getAddonsNav = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Get Addons' });
    await expect(getAddonsNav).toBeVisible();
    await getAddonsNav.click();

    await expect(page.locator('.get-addons-view')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.search-box input.search-input')).toBeVisible({ timeout: 5000 });
    const addonCards = page.locator('.addons-grid .addon-card');
    await expect(addonCards.first()).toBeVisible({ timeout: 10000 });
    await page.waitForTimeout(1000);

    const screenshot2Path = path.join(OUTPUT_DIR, 'screenshot-wago-browse.png');
    await page.screenshot({ path: screenshot2Path });
    console.log(`Saved screenshot 2 to ${screenshot2Path}`);

    // Screenshot 3: screenshot-settings.png (Settings view)
    const settingsNav = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Settings' });
    await expect(settingsNav).toBeVisible();
    await settingsNav.click();

    await expect(page.locator('h1.view-title')).toHaveText('Settings', { timeout: 10000 });
    await expect(page.locator('.theme-grid')).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(1000);

    const screenshot3Path = path.join(OUTPUT_DIR, 'screenshot-settings.png');
    await page.screenshot({ path: screenshot3Path });
    console.log(`Saved screenshot 3 to ${screenshot3Path}`);

    // Screenshot 4: screenshot-my-addons-snow-day.png (Snow Day theme, My Addons view)
    // Click Snow Day theme card
    const snowDaySwatch = page.locator('.theme-grid button.theme-swatch-card[title="Snow Day"]');
    await expect(snowDaySwatch).toBeVisible({ timeout: 5000 });
    await snowDaySwatch.click();
    await expect(snowDaySwatch).toHaveAttribute('aria-checked', 'true');

    // Verify document theme updated
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'snow-day');

    // Navigate back to My Addons view
    const myAddonsNav = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'My Addons' });
    await expect(myAddonsNav).toBeVisible();
    await myAddonsNav.click();

    await expect(rows.first()).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.freshness-box')).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(1000);

    const screenshot4Path = path.join(OUTPUT_DIR, 'screenshot-my-addons-snow-day.png');
    await page.screenshot({ path: screenshot4Path });
    console.log(`Saved screenshot 4 to ${screenshot4Path}`);
  });
});
