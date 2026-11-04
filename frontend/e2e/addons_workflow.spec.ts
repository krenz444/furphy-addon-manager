import { test, expect } from '@playwright/test';

test.describe('Furphy Addon Manager - Addons Workflow E2E', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to local Vite dev server in mock mode
    await page.goto('/?mock=1');
    // Wait for the app layout to load
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });
  });

  test('1. Addon List Display & Search: filters table to BigWigs', async ({ page }) => {
    // Wait for virtual list rows to appear
    const searchInput = page.getByLabel('Filter addons');
    await expect(searchInput).toBeVisible();

    // Verify initial rows exist
    const rows = page.locator('.addon-row');
    await expect(rows.first()).toBeVisible({ timeout: 5000 });
    const initialCount = await rows.count();
    expect(initialCount).toBeGreaterThan(0);

    // Search for "BigWigs"
    await searchInput.fill('BigWigs');

    // Verify filtered results
    await expect(page.getByText('BigWigs Bossmods')).toBeVisible();
    await expect(page.getByText('Addon Suite Benchmark')).not.toBeVisible();

    // Clear search and verify original list returns
    const clearBtn = page.getByLabel('Clear filter');
    await clearBtn.click();
    await expect(searchInput).toHaveValue('');
    await expect(page.locator('.addon-row').first()).toBeVisible();
  });

  test('2. Filter Tabs: verifies Updates, Needs Deps, Pinned, and Ignored filters', async ({ page }) => {
    // Filter chips container
    const filterChips = page.locator('.filter-chips');
    await expect(filterChips).toBeVisible();

    // 1. Updates Filter
    const updatesTab = filterChips.locator('button[role="tab"]').filter({ hasText: /Updates/ });
    if (await updatesTab.isVisible()) {
      await updatesTab.click();
      await expect(updatesTab).toHaveAttribute('aria-selected', 'true');
      const updatePills = page.locator('.status-pill.pill-update');
      await expect(updatePills.first()).toBeVisible();
      // Verify visible rows have update pills
      const count = await updatePills.count();
      expect(count).toBeGreaterThan(0);
    }

    // 2. Needs Deps Filter
    const needsDepsTab = filterChips.locator('button[role="tab"]').filter({ hasText: /Needs Deps/ });
    if (await needsDepsTab.isVisible()) {
      await needsDepsTab.click();
      await expect(needsDepsTab).toHaveAttribute('aria-selected', 'true');
      // "Details! Damage Meter" has mock missing deps
      await expect(page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' })).toBeVisible();
    }

    // 3. Pinned Filter
    const pinnedTab = filterChips.locator('button[role="tab"]').filter({ hasText: /Pinned/ });
    if (await pinnedTab.isVisible()) {
      await pinnedTab.click();
      await expect(pinnedTab).toHaveAttribute('aria-selected', 'true');
      // Plater is pinned in mock data
      await expect(page.locator('.addon-row').filter({ hasText: 'Plater Nameplates' })).toBeVisible();
      await expect(page.locator('.status-pill.pill-pinned').first()).toBeVisible();
    }

    // 4. Ignored Filter
    const ignoredTab = filterChips.locator('button[role="tab"]').filter({ hasText: /Ignored/ });
    if (await ignoredTab.isVisible()) {
      await ignoredTab.click();
      await expect(ignoredTab).toHaveAttribute('aria-selected', 'true');
      // Deadly Boss Mods is ignored in mock data
      await expect(page.locator('.addon-row').filter({ hasText: 'Deadly Boss Mods (DBM)' })).toBeVisible();
      await expect(page.locator('.status-pill.pill-ignored').first()).toBeVisible();
    }

    // Reset to "All"
    const allTab = filterChips.locator('button[role="tab"]').filter({ hasText: /^All/ });
    await allTab.click();
    await expect(allTab).toHaveAttribute('aria-selected', 'true');
  });

  test('3. Single Addon Update: triggers update, verifies toast and status transition', async ({ page }) => {
    // Search for Details to ensure it is rendered at the top of the virtual list
    const searchInput = page.getByLabel('Filter addons');
    await searchInput.fill('Details');

    // Locate Details! row which has an available update
    const detailsRow = page.locator('.addon-row').filter({ hasText: 'Details! Damage Meter' });
    await expect(detailsRow).toBeVisible();

    const updateBtn = detailsRow.locator('button.pill-update');
    await expect(updateBtn).toBeVisible();

    // Click update
    await updateBtn.click();

    // Verify toast notification appears
    const toast = page.locator('.toast.toast-success');
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast).toContainText('Updated Details! Damage Meter');
  });

  test('4. Update All Button: triggers batch update and shows toast', async ({ page }) => {
    // Look for Update all in the sidebar freshness box
    const updateAllBtn = page.locator('.freshness-box button.update-btn').filter({ hasText: 'Update all' });
    await expect(updateAllBtn).toBeVisible();

    // Click Update all
    await updateAllBtn.click();

    // Verify success toast appears
    const toast = page.locator('.toast.toast-success');
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast).toContainText('All addons updated successfully');
  });

  test('5. Untracked Addons Banner: renders banner and provides Adopt, Ignore, and Remove options', async ({ page }) => {
    // Verify banner renders
    const banner = page.locator('.untracked-banner');
    await expect(banner).toBeVisible();
    await expect(banner).toContainText("Furphy isn't managing yet");

    // Verify banner actions
    const reviewBtn = banner.locator('button', { hasText: 'Review' });
    const manageAllBtn = banner.locator('button', { hasText: 'Manage all' });
    await expect(reviewBtn).toBeVisible();
    await expect(manageAllBtn).toBeVisible();

    // Click Review to navigate to Untracked settings
    await reviewBtn.click();

    // Verify navigation to settings section
    await expect(page.getByRole('heading', { name: /Addons Furphy.*Managing Yet/i })).toBeVisible();

    // Verify unmanaged items are listed
    const untrackedItem = page.locator('.untracked-item').first();
    await expect(untrackedItem).toBeVisible();

    // Verify "Adopt" (Manage button), "Ignore", and "Remove" (Delete button) options exist
    await expect(untrackedItem.locator('button', { hasText: 'Manage' })).toBeVisible();
    await expect(untrackedItem.locator('button', { hasText: 'Ignore' })).toBeVisible();
    await expect(untrackedItem.locator('button', { hasText: 'Delete' })).toBeVisible();
  });

  test('6. Settings Navigation: verifies WoW path display, release channel selector, theme switcher', async ({ page }) => {
    // Navigate to Settings
    const settingsNavItem = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Settings' });
    await settingsNavItem.click();

    // Verify Settings view title
    await expect(page.locator('h1.view-title')).toHaveText('Settings');

    // 1. Verify Release Channel Selector ("Include beta versions for addon checks")
    const betaToggle = page.locator('label.toggle-control').filter({ hasText: 'Include beta versions for addon checks' });
    await expect(betaToggle).toBeVisible();
    const betaCheckbox = betaToggle.locator('input[type="checkbox"]');
    await expect(betaCheckbox).toBeVisible();

    // 2. Verify Theme Switcher
    const themeGrid = page.locator('.theme-grid');
    await expect(themeGrid).toBeVisible();
    const arcaneTheme = themeGrid.locator('button.theme-swatch-card[title="Arcane Library"]');
    await expect(arcaneTheme).toBeVisible();
    await arcaneTheme.click();
    await expect(arcaneTheme).toHaveAttribute('aria-checked', 'true');

    // Verify document theme updated
    const rootTheme = await page.evaluate(() => document.documentElement.dataset.theme);
    expect(rootTheme).toBe('arcane-library');

    // 3. Verify WoW Path Display via Diagnostics
    const advancedToggle = page.locator('button.advanced-toggle');
    await expect(advancedToggle).toBeVisible();
    await advancedToggle.click();

    // Verify "Open WoW Folder" button in App Folders
    await expect(page.locator('button', { hasText: 'Open WoW Folder' })).toBeVisible();

    // Run diagnostics to display WoW root path
    const runDiagBtn = page.locator('button', { hasText: 'Run Diagnostics' });
    await expect(runDiagBtn).toBeVisible();
    await runDiagBtn.click();

    // Verify WoW root path detail is displayed
    const wowRootDiag = page.locator('.diag-row').filter({ hasText: 'World of Warcraft Root' });
    await expect(wowRootDiag).toBeVisible({ timeout: 5000 });
    await expect(wowRootDiag).toContainText('World of Warcraft');

    // Invariant: Verify all diagnostics report PASS (no FAIL statuses on healthy/new install)
    await expect(page.locator('.diag-status.fail')).toHaveCount(0);
    const dbDiag = page.locator('.diag-row').filter({ hasText: 'SQLite Database' });
    await expect(dbDiag).toBeVisible();
    await expect(dbDiag.locator('.diag-status')).toHaveText('PASS');
  });

  test('7. Get Addons - CurseForge Browser Search: verifies open in browser and search callout on CurseForge install page', async ({ page }) => {
    // Navigate to Get Addons view
    const getAddonsNavItem = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Get Addons' });
    await getAddonsNavItem.click();

    // Switch to CurseForge tab
    const cfTab = page.locator('.tab-btn').filter({ hasText: 'CurseForge' });
    await expect(cfTab).toBeVisible();
    await cfTab.click();
    await expect(cfTab).toHaveAttribute('aria-selected', 'true');

    // Verify form input and action buttons
    const cfInput = page.locator('#cf-id-input');
    await expect(cfInput).toBeVisible();
    const installBtn = page.locator('.cf-form button', { hasText: 'Install Addon' });
    await expect(installBtn).toBeVisible();
    const browserSearchBtn = page.locator('.cf-form button', { hasText: 'Search in Browser ↗' });
    await expect(browserSearchBtn).toBeVisible();

    // Verify dedicated browse & search callout box
    const searchCallout = page.locator('.cf-search-callout');
    await expect(searchCallout).toBeVisible();
    await expect(searchCallout).toContainText('Browse & Search on CurseForge');
    const openSearchBtn = searchCallout.locator('button', { hasText: 'Open CurseForge Search ↗' });
    await expect(openSearchBtn).toBeVisible();

    // Test clicking Open CurseForge Search does not crash
    await openSearchBtn.click();

    // Test entering a search query and clicking Search in Browser
    await cfInput.fill('deadly boss mods');
    await browserSearchBtn.click();
  });

  test('8. Get Addons - Wago Browse & Client Switching: verifies default Wago catalog and switching between Retail and Classic/Forever', async ({ page }) => {
    // Navigate to Get Addons view
    const getAddonsNavItem = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Get Addons' });
    await getAddonsNavItem.click();

    // Verify Wago tab is active by default
    const wagoTab = page.locator('.tab-btn').filter({ hasText: 'Wago.io' });
    await expect(wagoTab).toBeVisible();
    await expect(wagoTab).toHaveAttribute('aria-selected', 'true');

    // Verify initial retail addons appear (Plater, Method Raid Tools, Details, Raider.IO)
    await expect(page.locator('.addon-card').first()).toBeVisible({ timeout: 5000 });
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Method Raid Tools' })).toBeVisible();

    // Verify client selector exists in toolbar
    const toolbarClientSelect = page.locator('#wago-target-flavour-select');
    await expect(toolbarClientSelect).toBeVisible();

    // Switch target client to Forever
    await toolbarClientSelect.selectOption('forever');

    // Classic / Forever cards appear, Retail-exclusive cards disappear
    await expect(page.getByRole('heading', { level: 3, name: 'Details! Damage Meter (Classic)' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'TomTom (Classic)' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).not.toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Method Raid Tools' })).not.toBeVisible();

    // Switch back to Retail
    await toolbarClientSelect.selectOption('retail');
    await expect(page.getByRole('heading', { level: 3, name: 'Plater Nameplates' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'TomTom (Classic)' })).not.toBeVisible();
  });

  test('9. Get Addons - Wago Pagination & Category Filtering: pages through multi-page results and verifies pagination boundary', async ({ page }) => {
    // Navigate to Get Addons view
    const getAddonsNavItem = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Get Addons' });
    await getAddonsNavItem.click();

    // Category filter dropdown
    const catSelect = page.getByLabel('Filter by category');
    await expect(catSelect).toBeVisible();

    // Select "Combat" category (mock provides 45 cards across 3 pages of 15)
    await catSelect.selectOption('combat');

    // Verify first page of cards loads (15 cards)
    const cards = page.locator('.addon-card');
    await expect(cards.first()).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Combat Addon 01' })).toBeVisible();

    // If Load More button is present, click it; otherwise scroll container to trigger paging
    const loadMoreBtn = page.getByRole('button', { name: /Load More Addons/ });
    if (await loadMoreBtn.isVisible()) {
      await loadMoreBtn.click();
      await expect(page.getByRole('heading', { level: 3, name: 'Combat Addon 16' })).toBeVisible();
    } else {
      const scrollContainer = page.locator('.tab-content');
      await scrollContainer.evaluate((el) => el.scrollTo(0, el.scrollHeight));
      await expect(page.getByRole('heading', { level: 3, name: 'Combat Addon 16' })).toBeVisible({ timeout: 10000 });
    }
  });

  test('10. Get Addons - Wago Install & Destination Flavour CTA: initiates installation to target client', async ({ page }) => {
    // Navigate to Get Addons view
    const getAddonsNavItem = page.locator('nav.sidebar-nav button.nav-item').filter({ hasText: 'Get Addons' });
    await getAddonsNavItem.click();

    // Ensure Retail is selected
    const toolbarClientSelect = page.locator('#wago-target-flavour-select');
    await toolbarClientSelect.selectOption('retail');

    // Locate Plater Nameplates card and verify install button has destination label
    const platerCard = page.locator('.addon-card').filter({ hasText: 'Plater Nameplates' });
    await expect(platerCard).toBeVisible();

    const installBtn = platerCard.locator('button.btn-install').filter({ hasText: /Install to/ });
    await expect(installBtn).toBeVisible();
    await expect(installBtn).toContainText('Retail');

    // Click install
    await installBtn.click();

    // Verify toast notification appears confirming installation job started/completed
    const toast = page.locator('.toast.toast-success');
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast).toContainText('Installed');
  });
});
