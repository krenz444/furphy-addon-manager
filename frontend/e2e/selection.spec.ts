import { test, expect, type Page } from '@playwright/test';

async function openList(page: Page) {
  await page.goto('/');
  await expect(page.locator('.virtual-list-container')).toBeVisible();
  await expect(page.locator('.addon-row .col-select input[type="checkbox"]').first()).toBeVisible();
}

const boxes = (page: Page) => page.locator('.addon-row .col-select input[type="checkbox"]');
const live = (page: Page) => page.locator('[data-testid="selection-live"]');

test.describe('Range selection in My Addons', () => {
  test('Shift+click selects every row between the last clicked row and this one', async ({ page }) => {
    await openList(page);
    await boxes(page).nth(1).click();
    await boxes(page).nth(5).click({ modifiers: ['Shift'] });

    for (let i = 1; i <= 5; i++) await expect(boxes(page).nth(i)).toBeChecked();
    await expect(boxes(page).nth(0)).not.toBeChecked();
    await expect(boxes(page).nth(6)).not.toBeChecked();
    await expect(page.locator('.bulk-action-bar')).toContainText('5 selected');
    await expect(live(page)).toHaveText('5 selected');
  });

  test('Shift+click works upwards and adds to rows that were already selected', async ({ page }) => {
    await openList(page);
    await boxes(page).nth(0).click();
    await boxes(page).nth(6).click();
    await boxes(page).nth(3).click({ modifiers: ['Shift'] });

    // 0, 6 and the range 3..6 (anchor was row 6)
    for (const i of [0, 3, 4, 5, 6]) await expect(boxes(page).nth(i)).toBeChecked();
    await expect(boxes(page).nth(1)).not.toBeChecked();
    await expect(live(page)).toHaveText('5 selected');
  });

  test('A plain click toggles one row and Ctrl+click keeps the others', async ({ page }) => {
    await openList(page);
    await boxes(page).nth(2).click();
    await boxes(page).nth(4).click({ modifiers: ['Control'] });
    await expect(live(page)).toHaveText('2 selected');
    await boxes(page).nth(2).click();
    await expect(live(page)).toHaveText('1 selected');
  });

  test('Ctrl+A in the list selects every visible row and Escape clears the selection', async ({ page }) => {
    await openList(page);
    await page.locator('[aria-label="Addon list"]').focus();
    await page.keyboard.press('Control+a');

    await expect(page.locator('.bulk-action-bar')).toBeVisible();
    const text = (await live(page).textContent()) ?? '';
    const count = Number(text.replace(/\D+/g, ''));
    expect(count).toBeGreaterThan(20);

    await page.keyboard.press('Escape');
    await expect(page.locator('.bulk-action-bar')).not.toBeVisible();
    await expect(live(page)).toHaveText('Selection cleared');
  });

  test('Ctrl+A inside a text field keeps its normal meaning and selects no rows', async ({ page }) => {
    await openList(page);
    const search = page.getByPlaceholder(/Filter addons/i).first();
    await expect(search).toBeVisible();
    await search.fill('details');
    await search.focus();
    await page.keyboard.press('Control+a');
    await expect(page.locator('.bulk-action-bar')).not.toBeVisible();
  });

  test('The range follows the order after the sort changes', async ({ page }) => {
    await openList(page);
    const sortSelect = page.locator('select').filter({ has: page.locator('option[value="released"]') }).first();
    await sortSelect.selectOption('released');
    await boxes(page).nth(0).click();
    await boxes(page).nth(3).click({ modifiers: ['Shift'] });
    await expect(live(page)).toHaveText('4 selected');
    for (let i = 0; i <= 3; i++) await expect(boxes(page).nth(i)).toBeChecked();
  });
});
