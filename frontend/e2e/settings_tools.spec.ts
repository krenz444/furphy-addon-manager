import { test, expect, type Page } from '@playwright/test';

async function openSettings(page: Page) {
  await page.goto('/');
  await page.locator('.sidebar-nav button').filter({ hasText: 'Settings' }).click();
  await expect(page.locator('.settings-view')).toBeVisible();
}

test.describe('Settings search', () => {
  test('filters the sections, shows an empty state with Clear, and Escape clears', async ({ page }) => {
    await openSettings(page);
    const search = page.locator('[data-testid="settings-search"]');
    await expect(search).toBeVisible();
    await expect(search).toHaveAttribute('type', 'search');

    const blocks = page.locator('[data-settings-block]:visible');
    const before = await blocks.count();
    expect(before).toBeGreaterThan(3);

    await search.fill('interface size');
    await expect(page.locator('[data-testid="zoom-slider"]')).toBeVisible();
    expect(await blocks.count()).toBeLessThan(before);

    await search.fill('zzzq');
    await expect(page.locator('[data-testid="settings-search-empty"]')).toBeVisible();
    await expect(page.locator('[data-testid="settings-search-empty"]')).toContainText('No settings match');
    await page.locator('[data-testid="settings-search-empty"]').getByRole('button', { name: 'Clear' }).click();
    await expect(search).toHaveValue('');
    expect(await blocks.count()).toBe(before);

    await search.fill('ipv4');
    await expect(page.locator('[data-testid="force-ipv4-toggle"]')).toBeVisible();
    await search.press('Escape');
    await expect(search).toHaveValue('');
  });
});

test.describe('Interface size and IPv4', () => {
  test('the slider, the keyboard shortcuts and Reset stay in step', async ({ page }) => {
    await openSettings(page);
    const value = page.locator('[data-testid="zoom-value"]');
    await expect(value).toHaveText('100%');

    await page.locator('[data-testid="zoom-slider"]').fill('120');
    await expect(value).toHaveText('120%');

    await page.keyboard.press('Control+=');
    await expect(value).toHaveText('130%');
    await page.keyboard.press('Control+-');
    await page.keyboard.press('Control+-');
    await expect(value).toHaveText('110%');

    await page.keyboard.press('Control+0');
    await expect(value).toHaveText('100%');

    await page.locator('[data-testid="zoom-slider"]').fill('150');
    await expect(value).toHaveText('150%');
    await page.locator('[data-testid="zoom-reset"]').click();
    await expect(value).toHaveText('100%');
  });

  test('the zoom never leaves the 80 to 150 percent range', async ({ page }) => {
    await openSettings(page);
    const value = page.locator('[data-testid="zoom-value"]');
    for (let i = 0; i < 12; i++) await page.keyboard.press('Control+=');
    await expect(value).toHaveText('150%');
    for (let i = 0; i < 12; i++) await page.keyboard.press('Control+-');
    await expect(value).toHaveText('80%');
  });

  test('the IPv4 toggle is saved through update_settings', async ({ page }) => {
    await openSettings(page);
    await page.locator('.advanced-toggle').click();
    const toggle = page.locator('[data-testid="force-ipv4-toggle"]');
    await expect(toggle).not.toBeChecked();
    await expect(page.locator('.settings-view')).toContainText('Use IPv4 only for downloads');
    await toggle.check();
    await expect(toggle).toBeChecked();
  });
});

test.describe('Battle.net discovery', () => {
  test('lists the installs it finds with a status, and offers Use only where it makes sense', async ({ page }) => {
    await page.goto('/');
    await page.evaluate(() => {
      const mock = (window as unknown as { __furphyMock: { setMockBattlenet?: (list: unknown[]) => void } }).__furphyMock;
      mock.setMockBattlenet?.([
        { product: 'wow', install_path: 'C:\\Program Files (x86)\\World of Warcraft', flavour: 'retail', flavour_folder_exists: true, current_path: 'C:\\Program Files (x86)\\World of Warcraft' },
        { product: 'wowf', install_path: 'D:\\Games\\World of Warcraft', flavour: 'forever', flavour_folder_exists: true, current_path: 'C:\\Program Files (x86)\\World of Warcraft' },
        { product: 'wow_classic_beta', install_path: 'D:\\Games\\World of Warcraft', flavour: 'classic_beta', flavour_folder_exists: false, current_path: null },
      ]);
    });
    await page.locator('.sidebar-nav button').filter({ hasText: 'Settings' }).click();
    await page.locator('.advanced-toggle').click();
    await expect(page.locator('[data-testid="bnet-panel"]')).toBeVisible();
    await expect(page.locator('[data-testid="bnet-row-wow"]')).toHaveCount(0);

    await page.locator('[data-testid="bnet-detect"]').click();
    await expect(page.locator('[data-testid="bnet-row-wow"]')).toContainText('Already used by Furphy');
    await expect(page.locator('[data-testid="bnet-use-wow"]')).toBeDisabled();

    await expect(page.locator('[data-testid="bnet-row-wowf"]')).toContainText('Different from the folder Furphy uses now');
    await expect(page.locator('[data-testid="bnet-use-wowf"]')).toBeEnabled();

    await expect(page.locator('[data-testid="bnet-use-wow_classic_beta"]')).toBeDisabled();
    await expect(page.locator('[data-testid="bnet-row-wow_classic_beta"]')).toContainText('is not in this install');
  });

  test('says so when Battle.net records no installs', async ({ page }) => {
    await page.goto('/');
    await page.evaluate(() => {
      (window as unknown as { __furphyMock: { setMockBattlenet?: (list: unknown[]) => void } }).__furphyMock.setMockBattlenet?.([]);
    });
    await page.locator('.sidebar-nav button').filter({ hasText: 'Settings' }).click();
    await page.locator('.advanced-toggle').click();
    await page.locator('[data-testid="bnet-detect"]').click();
    await expect(page.locator('[data-testid="bnet-panel"]')).toContainText('Battle.net has no World of Warcraft installs recorded on this PC.');
  });
});
