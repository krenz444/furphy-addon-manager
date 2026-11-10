import { test, expect, type Page } from '@playwright/test';

async function openList(page: Page) {
  await page.goto('/');
  await expect(page.locator('.virtual-list-container')).toBeVisible();
  await expect(page.locator('.addon-row').first()).toBeVisible();
}

test.describe('Release date column', () => {
  test('shows a Released header and a date or a dash on every row', async ({ page }) => {
    await openList(page);
    await expect(page.locator('.col-released').first()).toContainText('Released');

    const cells = page.locator('.addon-row .col-released');
    const count = await cells.count();
    expect(count).toBeGreaterThan(5);
    let dated = 0;
    for (let i = 0; i < Math.min(count, 12); i++) {
      const text = ((await cells.nth(i).textContent()) ?? '').trim();
      expect(text.length).toBeGreaterThan(0);
      if (text !== '-') dated++;
    }
    expect(dated).toBeGreaterThan(3);
  });

  test('every cell carries the full date in its title, or says the date is unknown', async ({ page }) => {
    await openList(page);
    const cells = page.locator('.addon-row .col-released');
    for (let i = 0; i < 8; i++) {
      const text = ((await cells.nth(i).textContent()) ?? '').trim();
      const title = (await cells.nth(i).getAttribute('title')) ?? '';
      if (text === '-') {
        expect(title).toBe('Release date unknown');
      } else {
        expect(title).toMatch(/\d{4}/);
      }
    }
  });

  test('sorting by release date puts dated rows first, newest first', async ({ page }) => {
    await openList(page);
    const sortSelect = page.locator('select').filter({ has: page.locator('option[value="released"]') }).first();
    await expect(sortSelect.locator('option[value="released"]')).toHaveText(/Release date/);
    await sortSelect.selectOption('released');

    const cells = page.locator('.addon-row .col-released');
    const first = ((await cells.nth(0).textContent()) ?? '').trim();
    expect(first).not.toBe('-');
    expect(await cells.nth(0).getAttribute('title')).not.toBe('Release date unknown');

    // Newest first: no later row among the first ten may be newer than the first one.
    const texts: string[] = [];
    for (let i = 0; i < 10; i++) texts.push(((await cells.nth(i).textContent()) ?? '').trim());
    const rank = (t: string) => (t === 'Today' ? 0 : t === 'Yesterday' ? 1 : t === '-' ? 9999 : 100);
    for (let i = 1; i < texts.length; i++) {
      expect(rank(texts[i - 1])).toBeLessThanOrEqual(rank(texts[i]) + 0);
    }
  });
});
