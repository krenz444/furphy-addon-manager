import { test, expect } from '@playwright/test';

test.describe('Furphy Wago browse', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to local Vite dev server in browser mock mode
    await page.goto('/?mock=1');
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });

    // Open the Get Addons view from the sidebar navigation
    const getAddonsBtn = page.locator('nav.sidebar-nav').getByRole('button', { name: 'Get Addons' });
    await getAddonsBtn.click();

    // Verify Wago tab is active by default
    const wagoTab = page.getByRole('tab', { name: 'Wago.io' });
    await expect(wagoTab).toBeVisible();
    await expect(wagoTab).toHaveAttribute('aria-selected', 'true');

    // Wait for initial addon cards to be rendered
    await expect(page.locator('.addon-card').first()).toBeVisible({ timeout: 5000 });
  });

  test('1 The sort select offers exactly four options', async ({ page }) => {
    const sortSelect = page.getByLabel('Sort by');
    await expect(sortSelect).toBeVisible();

    const options = sortSelect.locator('option');
    await expect(options).toHaveCount(4);
    await expect(options).toHaveText([
      'Most Popular',
      'Most Downloads',
      'Recently Updated',
      'Name A-Z',
    ]);

    // Ensure unsupported / dropped Wago sort options are absent
    await expect(sortSelect.locator('option', { hasText: 'Highest Rated' })).toHaveCount(0);
    await expect(sortSelect.locator('option', { hasText: 'Gaining this week' })).toHaveCount(0);
  });

  test('2 Typing a query narrows cards after debounce, clearing restores them', async ({ page }) => {
    const searchInput = page.getByLabel('Search Wago addons');
    await expect(searchInput).toBeVisible();

    // Initial retail pool contains 4 cards
    const cards = page.locator('.addon-card');
    await expect(cards).toHaveCount(4);

    // Type query to filter
    await searchInput.fill('Plater');

    // Assert cards narrow to matching item after debounce via expect polling
    await expect(cards).toHaveCount(1);
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Method Raid Tools' })).not.toBeVisible();

    // Clear search query using the clear button
    const clearBtn = page.getByLabel('Clear search query');
    await expect(clearBtn).toBeVisible();
    await clearBtn.click();

    // Assert original card list is restored
    await expect(searchInput).toHaveValue('');
    await expect(cards).toHaveCount(4);
    await expect(page.getByRole('heading', { level: 3, name: 'Method Raid Tools' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
  });

  test('2b Typing character by character ends on the results for the final text', async ({ page }) => {
    const searchInput = page.getByLabel('Search Wago addons');
    await searchInput.pressSequentially('Plater', { delay: 40 });

    await expect(page.locator('.addon-card')).toHaveCount(1);
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
  });

  test('3 Switching target game client re-queries appropriate pool', async ({ page }) => {
    // Retail pool cards are initially visible
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'TomTom (Classic)' })).not.toBeVisible();

    // Switch target game client from Retail to Classic Era in sidebar
    const classicEraTab = page.locator('.flavour-list').getByRole('tab', { name: /Classic Era/ });
    await expect(classicEraTab).toBeVisible();
    await classicEraTab.click();
    await expect(classicEraTab).toHaveAttribute('aria-selected', 'true');

    // Classic-only card appears, retail-only card disappears
    await expect(page.getByRole('heading', { level: 3, name: 'TomTom (Classic)' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).not.toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Deadly Boss Mods (DBM) - Classic' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Method Raid Tools' })).not.toBeVisible();
  });

  test('3b Toolbar client selector re-queries without pressing Search', async ({ page }) => {
    const toolbarClient = page.getByLabel('Select game client to browse and install addons for');
    await expect(toolbarClient).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();

    await toolbarClient.selectOption('forever');

    await expect(page.getByRole('heading', { level: 3, name: 'TomTom (Classic)' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).not.toBeVisible();

    // And back: the retail list returns.
    await toolbarClient.selectOption('retail');
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'TomTom (Classic)' })).not.toBeVisible();
  });

  test('4 Results area scrolls when viewport forces grid overflow', async ({ page }) => {
    // Constrain viewport height to force scroll container overflow
    await page.setViewportSize({ width: 1100, height: 420 });

    const scrollContainer = page.locator('.tab-content');
    await expect(scrollContainer).toBeVisible();
    await expect(page.locator('.addon-card').first()).toBeVisible();

    // Assert container scrollHeight exceeds clientHeight
    await expect.poll(async () => {
      return scrollContainer.evaluate((el) => el.scrollHeight > el.clientHeight);
    }).toBe(true);

    // Initial scroll position should be at top
    const initialScrollTop = await scrollContainer.evaluate((el) => el.scrollTop);
    expect(initialScrollTop).toBe(0);

    // Hover over scroll container and dispatch mouse wheel down
    await scrollContainer.hover();
    await page.mouse.wheel(0, 300);

    // Assert mouse wheel moves scrollTop above 0
    await expect.poll(async () => {
      return scrollContainer.evaluate((el) => el.scrollTop);
    }).toBeGreaterThan(0);
  });

  test('5 Scrolling a large category keeps loading pages instead of stopping at the first', async ({ page }) => {
    // The mock serves "Combat" as 45 different addons in 3 pages of 15.
    await page.setViewportSize({ width: 1100, height: 600 });
    await page.getByLabel('Filter by category').selectOption('combat');

    const cards = page.locator('.addon-card');
    await expect(cards.first()).toBeVisible();
    const scrollContainer = page.locator('.tab-content');

    // Scroll to the bottom repeatedly; every page that loads must add new cards until all 45 are shown.
    await expect
      .poll(
        async () => {
          await scrollContainer.evaluate((el) => el.scrollTo(0, el.scrollHeight));
          return cards.count();
        },
        { timeout: 20000, intervals: [300, 500, 800] },
      )
      .toBe(45);

    await expect(page.getByRole('heading', { level: 3, name: 'Combat Addon 45' })).toBeVisible();
  });

  test('6 A tall window fills itself with addons without scrolling or pressing Load More', async ({ page }) => {
    // 15 cards do not fill a window this tall, so there is nothing to scroll and nothing for a
    // scroll listener to fire on. The list has to keep asking for pages on its own.
    await page.setViewportSize({ width: 1600, height: 3200 });
    await page.getByLabel('Filter by category').selectOption('combat');

    const cards = page.locator('.addon-card');
    await expect(cards.first()).toBeVisible();

    await expect(cards).toHaveCount(45, { timeout: 15000 });
    await expect(page.getByRole('heading', { level: 3, name: 'Combat Addon 45' })).toBeVisible();
    await expect(page.getByRole('button', { name: /Load More Addons/ })).toHaveCount(0);
    await expect(page.getByText('End of results')).toBeVisible();
  });

  test('7 A small window pages on scroll only, and enlarging the window fills it', async ({ page }) => {
    await page.setViewportSize({ width: 1100, height: 600 });
    await page.getByLabel('Filter by category').selectOption('combat');

    const cards = page.locator('.addon-card');
    await expect(cards).toHaveCount(15);
    // The list overflows and the user has not scrolled: nothing may be fetched ahead of need.
    await page.waitForTimeout(1500);
    await expect(cards).toHaveCount(15);

    await page.setViewportSize({ width: 1600, height: 3200 });
    await expect(cards).toHaveCount(45, { timeout: 15000 });
  });
});
