import { test, expect, type Page } from '@playwright/test';

// The mock installs window.__furphyMock on its first call; these helpers steer the next check.
type Hook = { __furphyMock: Record<string, (...args: unknown[]) => unknown> & { checkCalls: number } };

const checkCalls = (page: Page) => page.evaluate(() => (window as unknown as Hook).__furphyMock.checkCalls);
const failNext = (page: Page, message: string) =>
  page.evaluate((m) => (window as unknown as Hook).__furphyMock.failNextCheck(m), message);
const busyNext = (page: Page) => page.evaluate(() => (window as unknown as Hook).__furphyMock.busyNextCheck());
const partialNext = (page: Page) =>
  page.evaluate(() => (window as unknown as Hook).__furphyMock.partialFailureNextCheck());
const setCheckedAt = (page: Page, iso: string | null) =>
  page.evaluate((v) => (window as unknown as Hook).__furphyMock.setCheckedAt(v), iso);
const setCheckDelay = (page: Page, ms: number) =>
  page.evaluate((v) => (window as unknown as Hook).__furphyMock.setCheckDelay(v), ms);
const setNoUpdates = (page: Page, on: boolean) =>
  page.evaluate((v) => (window as unknown as Hook).__furphyMock.noUpdates(v), on);
const staleJobOnce = (page: Page, kind: string) =>
  page.evaluate((k) => (window as unknown as Hook).__furphyMock.staleRunningJobOnce(k), kind);

const BUSY = 'Another task is running. Try again when it finishes.';
const NOTHING_TO_CHECK = 'No addons to check yet. Add an addon first.';

test.describe('Furphy check for updates', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/?mock=1');
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.addon-row').first()).toBeVisible({ timeout: 5000 });
  });

  test('1 The button is in My Addons and says when the list was last checked', async ({ page }) => {
    const check = page.locator('.btn-check');
    await expect(check).toBeVisible();
    await expect(check).toHaveText('Check for updates');
    await expect(check).toHaveAttribute('aria-disabled', 'false');
    await expect(check).toHaveAttribute('title', 'Check every Retail addon for updates. This does not install anything.');
    await expect(page.locator('.checked-ago')).toHaveText('Checked 2 h ago');
  });

  test('2 Clicking it shows a busy state, reports the result and refreshes the checked time', async ({ page }) => {
    await setCheckDelay(page, 900);
    const check = page.locator('.btn-check');
    await check.click();

    await expect(check).toHaveAttribute('aria-busy', 'true');
    await expect(check).toHaveAttribute('aria-disabled', 'true');
    await expect(check).toHaveText('Checking…');
    await expect(check.locator('.check-spinner')).toBeVisible();
    await expect(page.locator('.freshness-box [role="status"]')).toContainText('Checking for updates…');

    const toast = page.locator('.toast.toast-success');
    await expect(toast).toContainText(/Checked \d+ addons, \d+ ignored or pinned skipped\. \d+ updates? ready\./);

    await expect(check).toHaveText('Check for updates');
    await expect(check).toHaveAttribute('aria-busy', 'false');
    await expect(page.locator('.checked-ago')).toHaveText('Checked just now');
    await expect(page.locator('.checked-line')).toContainText('Checked just now');
    expect(await checkCalls(page)).toBe(1);
  });

  test('3 Repeated clicks, scripted or real, start exactly one check', async ({ page }) => {
    await setCheckDelay(page, 900);
    const check = page.locator('.btn-check');
    // Two clicks in one task: the second must not slip in before the first one's state is visible.
    await check.evaluate((el) => {
      (el as HTMLElement).click();
      (el as HTMLElement).click();
    });
    await expect(check).toHaveAttribute('aria-busy', 'true');
    // A real click while busy (force: Playwright treats aria-disabled as not clickable).
    await check.click({ force: true });

    await expect(page.locator('.toast.toast-success')).toBeVisible();
    expect(await checkCalls(page)).toBe(1);
  });

  test('4 The button works from the keyboard and keeps focus while it runs', async ({ page }) => {
    await setCheckDelay(page, 900);
    const check = page.locator('.btn-check');
    for (let i = 0; i < 80; i++) {
      await page.keyboard.press('Tab');
      if (await check.evaluate((el) => el === document.activeElement)) break;
    }
    await expect(check).toBeFocused();

    const ring = await check.evaluate((el) => {
      const s = getComputedStyle(el);
      return { style: s.outlineStyle, width: parseFloat(s.outlineWidth) };
    });
    expect(ring.style).not.toBe('none');
    expect(ring.width).toBeGreaterThanOrEqual(2);

    await page.keyboard.press('Enter');
    await expect(check).toHaveAttribute('aria-busy', 'true');
    await expect(check).toBeFocused();
    await expect(check).toHaveAttribute('aria-busy', 'false');
    expect(await checkCalls(page)).toBe(1);

    await page.keyboard.press('Space');
    await expect(check).toHaveAttribute('aria-busy', 'true');
    await expect(check).toBeFocused();
    await expect(check).toHaveAttribute('aria-busy', 'false');
    expect(await checkCalls(page)).toBe(2);
  });

  test('5 A failed check shows the error, keeps a retry, and leaves the button usable', async ({ page }) => {
    await failNext(page, 'Provider unreachable');
    const check = page.locator('.btn-check');
    await check.click();

    await expect(page.locator('.toast.toast-error')).toContainText('Check failed: Provider unreachable');
    await expect(check).toHaveText('Check for updates');
    await expect(check).toHaveAttribute('aria-busy', 'false');

    const panel = page.locator('.job-panel');
    await expect(panel).toContainText('Job Failed');
    await expect(panel).toContainText('Provider unreachable');
    await expect(panel).not.toContainText('undefined');

    await panel.getByRole('button', { name: 'Retry' }).click();
    await expect(page.locator('.toast.toast-success')).toBeVisible();
    expect(await checkCalls(page)).toBe(2);
  });

  test('6 A busy runner queues checks cleanly in FIFO order and runs them once free', async ({ page }) => {
    await setCheckDelay(page, 2200);
    await busyNext(page);
    const bar = page.locator('section.job-status-bar');
    await expect(bar).toHaveClass(/is-running/);
    await expect(bar.locator('.status-title')).toHaveText('Updating all game versions');

    const check = page.locator('.btn-check');
    await expect(check).toHaveAttribute('aria-disabled', 'true');
    // aria-disabled="true" remains clickable in the DOM (so queued clicks reach the app),
    // whereas Playwright's default click() waits for aria-disabled to clear.
    await check.click({ force: true });

    await expect(page.locator('.toast.toast-info')).toContainText('Queued behind Updating all game versions');
    const toggle = bar.locator('.queue-toggle-btn');
    await expect(toggle).toHaveText('Queued (1)');
    if ((await toggle.getAttribute('aria-expanded')) !== 'true') {
      await toggle.click();
    }
    await expect(bar.locator('#job-status-queue-list')).toContainText('#1');
    await expect(bar.locator('#job-status-queue-list')).toContainText('Check for updates (Retail)');
    await expect(page.locator('.job-panel')).toHaveCount(0);

    // Speed up the queued check once its queue entry is verified.
    await setCheckDelay(page, 150);

    // Queued check automatically runs right after the background job completes.
    await expect(page.locator('.toast.toast-success')).toContainText(/Checked \d+ addons/, { timeout: 10000 });
    expect(await checkCalls(page)).toBe(1);
    await expect(check).toHaveAttribute('aria-disabled', 'false');
    await expect(bar).toHaveClass(/is-done/);
  });

  test('7 A partial failure names the addons that could not be checked', async ({ page }) => {
    await partialNext(page);
    await page.locator('.btn-check').click();

    const toast = page.locator('.toast.toast-error');
    await expect(toast).toContainText(/Could not check 2 addons: .+\./);
    await expect(toast).not.toContainText('0 addon');

    const panel = page.locator('.job-panel');
    await expect(panel).toContainText('Finished with errors');
    await expect(panel.locator('.failed-row')).toHaveCount(2);
    await expect(panel.locator('.failed-row').first()).toContainText('Provider timed out');
    await expect(page.locator('.btn-check')).toHaveAttribute('aria-disabled', 'false');
  });

  test('8 The sidebar offers Check now after a check has completed', async ({ page }) => {
    const sidebarCheck = page.locator('.freshness-box').getByRole('button', { name: 'Check now' });
    await expect(page.locator('.checked-line')).toContainText('Checked 2 h ago');
    await expect(sidebarCheck).toBeVisible();

    await sidebarCheck.click();
    await expect(page.locator('.freshness-box [role="status"]')).toContainText('Checking for updates…');
    await expect(page.locator('.toast.toast-success')).toBeVisible();
    await expect(page.locator('.checked-line')).toContainText('Checked just now');
    expect(await checkCalls(page)).toBe(1);
  });

  test('9 A clean list reads as up to date, and without a check time it reads as not checked', async ({ page }) => {
    await setNoUpdates(page, true);
    await page.locator('.freshness-box').getByRole('button', { name: 'Check now' }).click();
    await expect(page.locator('.toast.toast-success')).toContainText(/Everything is up to date\./);
    const status = page.locator('.freshness-box [role="status"]');
    await expect(status).toContainText('Everything’s up to date');
    await expect(page.locator('.checked-line')).toContainText('Checked just now');

    // The backend calls a never-checked list "clean"; with no timestamp the sidebar must not claim a verdict.
    await setCheckedAt(page, null);
    await page.locator('.flavour-list').getByRole('tab', { name: /Classic Era/ }).click();
    await page.locator('.flavour-list').getByRole('tab', { name: /Retail/ }).click();
    // Rows and freshness arrive together; waiting for rows keeps the assertions off the empty Classic Era state.
    await expect(page.locator('.addon-row').first()).toBeVisible();
    await expect(status).toContainText('Not checked yet');
    await expect(status).not.toContainText('Everything’s up to date');
    await expect(page.locator('.checked-ago')).toHaveText('Not checked yet');
  });

  test('10 An empty list is not checked: both controls explain why instead', async ({ page }) => {
    // Every game version except Retail has no addons in the mock.
    await page.locator('.flavour-list').getByRole('tab', { name: /Classic Era/ }).click();
    const check = page.locator('.btn-check');
    await expect(check).toHaveAttribute('aria-disabled', 'true');
    await expect(check).toHaveAttribute('title', NOTHING_TO_CHECK);
    const sidebar = page.locator('.freshness-box');
    await expect(sidebar).toContainText('Not checked yet');
    await expect(sidebar).not.toContainText('Everything’s up to date');

    // aria-disabled controls still receive clicks; force past Playwright's enabled check.
    await check.click({ force: true });
    await expect(page.locator('.toast.toast-info')).toContainText(NOTHING_TO_CHECK);
    expect(await checkCalls(page)).toBe(0);

    await sidebar.getByRole('button', { name: 'Check now' }).click();
    await expect(page.locator('.toast.toast-info')).toHaveCount(2);
    expect(await checkCalls(page)).toBe(0);
  });

  test('12 A check that finishes on another game version says which one it was for', async ({ page }) => {
    // Slow enough that the tab switch always lands before the check finishes.
    await setCheckDelay(page, 1500);
    await page.locator('.btn-check').click();
    await page.locator('.flavour-list').getByRole('tab', { name: /Classic Era/ }).click();

    await expect(page.locator('.toast.toast-success')).toContainText(/Retail: Checked \d+ addons/);
    expect(await checkCalls(page)).toBe(1);
  });

  test('17 A failed check that finishes on another game version leaves no panel on the one in view', async ({ page }) => {
    await partialNext(page);
    await setCheckDelay(page, 1500);
    await page.locator('.btn-check').click();
    await page.locator('.flavour-list').getByRole('tab', { name: /Classic Era/ }).click();

    await expect(page.locator('.toast.toast-error')).toContainText(/Retail: Could not check 2 addons/);
    await expect(page.locator('.job-panel')).toHaveCount(0);
    expect(await checkCalls(page)).toBe(1);
  });

  // The UI never polls, so a background job it saw running can finish unseen; the next click must re-read the state.
  for (const kind of ['update-all-flavours', 'check']) {
    test(`13 A stale running ${kind} job does not lock the button for good`, async ({ page }) => {
      const check = page.locator('.btn-check');
      await page.locator('.flavour-list').getByRole('tab', { name: /Classic Era/ }).click();
      // Wait for that refresh to land first, or it would consume the stale job meant for the Retail refresh.
      await expect(page.locator('.empty-state')).toBeVisible();
      await staleJobOnce(page, kind);
      await page.locator('.flavour-list').getByRole('tab', { name: /Retail/ }).click();
      await expect(page.locator('.addon-row').first()).toBeVisible();

      if (kind === 'check') {
        await expect(check).toHaveText('Checking…');
      } else {
        await expect(check).toHaveAttribute('title', BUSY);
      }
      await expect(check).toHaveAttribute('aria-disabled', 'true');
      expect(await checkCalls(page)).toBe(0);

      await check.click({ force: true });
      await expect(page.locator('.toast.toast-success')).toContainText(/Checked \d+ addons/);
      expect(await checkCalls(page)).toBe(1);
      await expect(check).toHaveAttribute('aria-disabled', 'false');
    });
  }

  test('14 A narrow window keeps both actions readable and the bar inside the window', async ({ page }) => {
    await page.setViewportSize({ width: 800, height: 800 });
    const check = page.locator('.btn-check');
    const updateAll = page.locator('.btn-update-all');
    await expect(check).toBeVisible();
    await expect(updateAll).toBeVisible();

    const a = await check.boundingBox();
    const b = await updateAll.boundingBox();
    expect(a).not.toBeNull();
    expect(b).not.toBeNull();
    const overlap =
      a!.x < b!.x + b!.width && b!.x < a!.x + a!.width && a!.y < b!.y + b!.height && b!.y < a!.y + a!.height;
    expect(overlap).toBe(false);

    const barFits = await page.locator('.filter-bar').evaluate((el) => el.scrollWidth <= el.clientWidth);
    expect(barFits).toBe(true);
  });

  test('16 The spinner turns, and stops when the system asks for reduced motion', async ({ page }) => {
    await setCheckDelay(page, 900);
    const check = page.locator('.btn-check');
    const spinnerAnimation = () => check.locator('.check-spinner').evaluate((el) => getComputedStyle(el).animationName);

    await check.click();
    await expect(check.locator('.check-spinner')).toBeVisible();
    expect(await spinnerAnimation()).not.toBe('none');
    await expect(check).toHaveAttribute('aria-busy', 'false');

    await page.emulateMedia({ reducedMotion: 'reduce' });
    await check.click();
    await expect(check.locator('.check-spinner')).toBeVisible();
    expect(await spinnerAnimation()).toBe('none');
  });
});

test.describe('Furphy check for updates, passing time', () => {
  test('15 The age text keeps itself current without a reload', async ({ page }) => {
    await page.clock.install({ time: new Date('2026-11-07T12:00:00Z') });
    await page.goto('/?mock=1');
    await expect(page.locator('.addon-row').first()).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.checked-ago')).toHaveText('Checked 2 h ago');

    await page.clock.fastForward('01:00:00');
    await expect(page.locator('.checked-ago')).toHaveText('Checked 3 h ago');
    await expect(page.locator('.checked-line')).toContainText('Checked 3 h ago');
  });
});
