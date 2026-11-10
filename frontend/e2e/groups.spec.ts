import { test, expect, type Page } from '@playwright/test';

async function openList(page: Page) {
  await page.goto('/');
  await expect(page.locator('.virtual-list-container')).toBeVisible();
  await expect(page.locator('.addon-row').first()).toBeVisible();
}

const rowMenu = (page: Page, index: number) => page.locator('.col-menu .menu-trigger-btn').nth(index);

async function openGroupsMenu(page: Page, rowIndex: number) {
  await rowMenu(page, rowIndex).click();
  await page.locator('[data-testid="row-menu-groups"]').click();
}

async function createGroupFromRow(page: Page, rowIndex: number, name: string) {
  await openGroupsMenu(page, rowIndex);
  await page.locator('[data-testid="group-new"]').click();
  await expect(page.locator('[data-testid="group-name-dialog"]')).toBeVisible();
  await page.locator('[data-testid="group-name-input"]').fill(name);
  await page.locator('[data-testid="group-name-save"]').click();
  await expect(page.locator('[data-testid="group-name-dialog"]')).not.toBeVisible();
}

test.describe('Favourites', () => {
  test('the star toggles, the Favourites chip counts and filters, and the sort puts favourites first', async ({ page }) => {
    await openList(page);
    const stars = page.locator('[data-testid="fav-toggle"]');
    await expect(stars.first()).toHaveAttribute('aria-pressed', 'false');

    await stars.nth(2).click();
    await expect(stars.nth(2)).toHaveAttribute('aria-pressed', 'true');
    await stars.nth(4).click();

    const chip = page.locator('[data-testid="chip-favourites"]');
    await expect(chip).toContainText('2');
    await chip.click();
    await expect(page.locator('.addon-row')).toHaveCount(2);
    await expect(page.locator('[data-testid="fav-toggle"][aria-pressed="true"]')).toHaveCount(2);

    // back to everything and sort by favourites first
    await chip.click();
    const sortSelect = page.locator('select').filter({ has: page.locator('option[value="favourites"]') }).first();
    await sortSelect.selectOption('favourites');
    await expect(page.locator('[data-testid="fav-toggle"]').nth(0)).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('[data-testid="fav-toggle"]').nth(1)).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('[data-testid="fav-toggle"]').nth(2)).toHaveAttribute('aria-pressed', 'false');
  });

  test('every star has an accessible name', async ({ page }) => {
    await openList(page);
    await expect(page.locator('[data-testid="fav-toggle"]').first()).toHaveAttribute('aria-label', /Favourite /);
  });
});

test.describe('Groups', () => {
  test('creates a group from the row menu, adds another addon, filters by the chip, renames and deletes it', async ({ page }) => {
    await openList(page);
    await createGroupFromRow(page, 0, 'Raid');

    const chip = page.locator('[data-testid^="chip-group-"]').first();
    await expect(chip).toContainText('Raid');
    await expect(chip).toContainText('1');

    // add the second row to the same group through the menu checkbox
    await openGroupsMenu(page, 1);
    const option = page.locator('[data-testid^="group-opt-"]').first();
    await expect(option).toHaveAttribute('aria-checked', 'false');
    await option.click();
    await expect(chip).toContainText('2');

    await chip.click();
    await expect(page.locator('.addon-row')).toHaveCount(2);
    await chip.click();

    // rename through the chip menu
    await page.locator('[data-testid^="group-menu-"]').first().click();
    await page.getByRole('menuitem', { name: 'Rename group' }).click();
    await expect(page.locator('[data-testid="group-name-input"]')).toHaveValue('Raid');
    await page.locator('[data-testid="group-name-input"]').fill('Mythic');
    await page.locator('[data-testid="group-name-save"]').click();
    await expect(page.locator('[data-testid^="chip-group-"]').first()).toContainText('Mythic');

    // delete asks first and keeps the addons
    await page.locator('[data-testid^="group-menu-"]').first().click();
    await page.getByRole('menuitem', { name: 'Delete group' }).click();
    await expect(page.getByRole('dialog')).toBeVisible();
    await page.getByRole('dialog').getByRole('button', { name: /delete/i }).click();
    await expect(page.locator('[data-testid^="chip-group-"]')).toHaveCount(0);
    await expect(page.locator('.addon-row').first()).toBeVisible();
  });

  test('the dialog refuses an empty name and a duplicate name with a visible reason', async ({ page }) => {
    await openList(page);
    await createGroupFromRow(page, 0, 'Raid');

    await openGroupsMenu(page, 1);
    await page.locator('[data-testid="group-new"]').click();
    await page.locator('[data-testid="group-name-input"]').fill('   ');
    await page.locator('[data-testid="group-name-save"]').click();
    await expect(page.locator('[data-testid="group-name-dialog"]')).toContainText('Enter a name');

    await page.locator('[data-testid="group-name-input"]').fill('RAID');
    await page.locator('[data-testid="group-name-save"]').click();
    await expect(page.locator('[data-testid="group-name-dialog"]')).toContainText('already exists');

    await page.keyboard.press('Escape');
    await expect(page.locator('[data-testid="group-name-dialog"]')).not.toBeVisible();
  });
});
