import { test, expect, type Page } from '@playwright/test';

type MockHook = {
  __furphyMock: {
    failNextCheck(message?: string): void;
    setCheckDelay(ms: number): void;
    setJobDelay(ms: number): void;
    queueBehindActive(kind?: string, flavour?: string | null, delayMs?: number): Promise<unknown>;
    emitBackgroundJob(kind?: string, flavour?: string | null, delayMs?: number): Promise<unknown>;
    readonly checkCalls: number;
  };
};

const statusBar = (page: Page) => page.locator('section.job-status-bar[aria-label="Task runner status"]');

const setCheckDelay = (page: Page, ms: number) =>
  page.evaluate((v) => (window as unknown as MockHook).__furphyMock.setCheckDelay(v), ms);

const setJobDelay = (page: Page, ms: number) =>
  page.evaluate((v) => (window as unknown as MockHook).__furphyMock.setJobDelay(v), ms);

const failNext = (page: Page, message: string) =>
  page.evaluate((m) => (window as unknown as MockHook).__furphyMock.failNextCheck(m), message);

const startBackgroundJob = (page: Page, kind: string, flavour: string | null, delayMs: number) =>
  page.evaluate(
    ({ k, f, d }) => {
      void (window as unknown as MockHook).__furphyMock.emitBackgroundJob(k, f, d);
    },
    { k: kind, f: flavour, d: delayMs },
  );

const enqueueBehindActive = (page: Page, kind: string, flavour: string | null, delayMs: number) =>
  page.evaluate(
    ({ k, f, d }) => {
      void (window as unknown as MockHook).__furphyMock.queueBehindActive(k, f, d);
    },
    { k: kind, f: flavour, d: delayMs },
  );

test.describe('Persistent top JobStatusBar', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/?mock=1');
    await expect(page.locator('.app-layout')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('.addon-row').first()).toBeVisible({ timeout: 5000 });
  });

  test('1 Starts in idle state with Ready headline and zero active styling', async ({ page }) => {
    const bar = statusBar(page);
    await expect(bar).toBeVisible();
    await expect(bar.locator('.status-title')).toHaveText('Ready');
    await expect(bar.locator('.status-detail')).toHaveText('Idle - no tasks running');
    await expect(bar).not.toHaveClass(/is-running/);
    await expect(bar).not.toHaveClass(/is-queued/);
    await expect(bar).not.toHaveClass(/is-error/);
    await expect(bar.getByRole('progressbar')).toHaveCount(0);
  });

  test('2 Displays live progress bar, aria-valuenow progression, addon name, and completion dismiss', async ({ page }) => {
    await setCheckDelay(page, 1400);
    const bar = statusBar(page);

    await page.locator('.btn-check').click();

    await expect(bar).toHaveClass(/is-running/);
    await expect(bar.locator('.status-title')).toHaveText('Checking Retail addons');

    const progress = bar.getByRole('progressbar', { name: 'Checking Retail addons' });
    await expect(progress).toBeVisible();
    await expect(progress).toHaveAttribute('aria-valuemin', '0');
    await expect(progress).toHaveAttribute('aria-valuemax', '100');

    // Wait for step progress updates showing phase + addon name and rising aria-valuenow
    await expect(bar.locator('.status-detail')).toContainText(/Checking - /);
    await expect(bar.locator('.progress-count')).toContainText(/\d+ of \d+ - \d+%/);

    await expect
      .poll(async () => Number((await progress.getAttribute('aria-valuenow')) ?? '0'), { timeout: 5000 })
      .toBeGreaterThanOrEqual(25);

    await expect
      .poll(async () => Number((await progress.getAttribute('aria-valuenow')) ?? '0'), { timeout: 5000 })
      .toBeGreaterThanOrEqual(50);

    await expect(page.locator('.toast.toast-success')).toBeVisible({ timeout: 10000 });
    await expect(bar).toHaveClass(/is-done/);
    await expect(bar.locator('.status-title')).toContainText('Completed: Check for updates (Retail)');

    await bar.getByRole('button', { name: 'Clear finished status' }).click();
    await expect(bar.locator('.status-title')).toHaveText('Ready');
    await expect(bar.locator('.status-detail')).toHaveText('Idle - no tasks running');
  });

  test('3 Shows Queued (2) FIFO ordered list while an active job runs and drains automatically', async ({ page }) => {
    await setCheckDelay(page, 250);
    await setJobDelay(page, 250);
    const bar = statusBar(page);

    await startBackgroundJob(page, 'update-all-flavours', null, 2200);
    await expect(bar).toHaveClass(/is-running/);
    await expect(bar.locator('.status-title')).toHaveText('Updating all game versions');

    await enqueueBehindActive(page, 'check', 'retail', 250);
    await enqueueBehindActive(page, 'backup-wtf', 'classic', 250);

    const toggle = bar.locator('.queue-toggle-btn');
    await expect(toggle).toHaveText('Queued (2)');
    if ((await toggle.getAttribute('aria-expanded')) !== 'true') {
      await toggle.click();
    }

    const items = bar.locator('#job-status-queue-list .queue-item');
    await expect(items).toHaveCount(2);
    await expect(items.nth(0)).toContainText('#1');
    await expect(items.nth(0)).toContainText('Check for updates (Retail)');
    await expect(items.nth(1)).toContainText('#2');
    await expect(items.nth(1)).toContainText('Backup WTF (Mists Classic)');

    // All queued jobs drain in FIFO order
    await expect(bar).not.toHaveClass(/is-running/, { timeout: 10000 });
    await expect(toggle).toHaveCount(0, { timeout: 10000 });
    await expect(bar).toHaveClass(/is-done/);
  });

  test('4 Surfaces failure state with Dismiss and Retry recovery', async ({ page }) => {
    const bar = statusBar(page);

    // First failure -> verify error styling + Dismiss resets bar to idle
    await failNext(page, 'CurseForge mirror unreachable');
    await page.locator('.btn-check').click();

    await expect(bar).toHaveClass(/is-error/);
    await expect(bar.locator('.status-title')).toContainText('Failed:');
    const panel = page.locator('.job-panel');
    await expect(panel).toContainText('Job Failed');
    await expect(panel.getByRole('button', { name: 'Retry' })).toBeVisible();
    await expect(panel.getByRole('button', { name: 'Dismiss' })).toBeVisible();

    await bar.getByRole('button', { name: 'Clear finished status' }).click();
    await expect(bar.locator('.status-title')).toHaveText('Ready');
    await expect(bar).not.toHaveClass(/is-error/);

    // Dismiss the panel and trigger a second failure -> test Retry recovery
    await panel.getByRole('button', { name: 'Dismiss' }).click();
    await failNext(page, 'Temporary DNS failure');
    await page.locator('.btn-check').click();

    await expect(bar).toHaveClass(/is-error/);
    await expect(panel).toContainText('Temporary DNS failure');
    await panel.getByRole('button', { name: 'Retry' }).click();

    await expect(page.locator('.toast.toast-success')).toBeVisible({ timeout: 10000 });
    await expect(bar).toHaveClass(/is-done/);
    await expect(bar).not.toHaveClass(/is-error/);
  });

  test('5 Remains visible and updates live across tab switching', async ({ page }) => {
    const bar = statusBar(page);
    await startBackgroundJob(page, 'update-all-flavours', null, 2000);
    await expect(bar).toHaveClass(/is-running/);
    await expect(bar.locator('.status-title')).toHaveText('Updating all game versions');

    const nav = page.locator('.sidebar-nav');
    for (const label of ['Get Addons', 'Activity', 'Settings', 'My Addons']) {
      await nav.getByRole('button', { name: label }).click();
      await expect(bar).toBeVisible();
      await expect(bar.locator('.status-title')).toHaveText('Updating all game versions');
    }
  });

  test('6 Fits cleanly inside an 800px narrow viewport without horizontal overflow', async ({ page }) => {
    await page.setViewportSize({ width: 800, height: 760 });
    const bar = statusBar(page);

    await setCheckDelay(page, 400);
    await startBackgroundJob(page, 'update-all-flavours', null, 2000);
    await enqueueBehindActive(page, 'check', 'retail', 300);

    await expect(bar).toHaveClass(/is-running/);
    await expect(bar.locator('.queue-toggle-btn')).toHaveText('Queued (1)');

    const metrics = await page.evaluate(() => {
      const barEl = document.querySelector('section.job-status-bar') as HTMLElement | null;
      const docEl = document.documentElement;
      const rect = barEl?.getBoundingClientRect();
      return {
        docScrollWidth: docEl.scrollWidth,
        docClientWidth: docEl.clientWidth,
        barScrollWidth: barEl?.scrollWidth ?? -1,
        barClientWidth: barEl?.clientWidth ?? -1,
        barRight: rect?.right ?? -1,
        barLeft: rect?.left ?? -1,
      };
    });

    expect(metrics.docScrollWidth).toBeLessThanOrEqual(metrics.docClientWidth);
    expect(metrics.barScrollWidth).toBeLessThanOrEqual(metrics.barClientWidth + 1);
    expect(metrics.barLeft).toBeGreaterThanOrEqual(0);
    expect(metrics.barRight).toBeLessThanOrEqual(800);
  });

  test('7 Disables status-dot and progress-bar animations under prefers-reduced-motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    const bar = statusBar(page);

    await startBackgroundJob(page, 'update-all-flavours', null, 1800);
    await expect(bar).toHaveClass(/is-running/);

    const styles = await page.evaluate(() => {
      const dot = document.querySelector('.job-status-bar .status-dot.is-running');
      const fill = document.querySelector('.job-status-bar .progress-fill');
      const dotStyle = dot ? getComputedStyle(dot) : null;
      const fillStyle = fill ? getComputedStyle(fill) : null;
      return {
        dotAnimName: dotStyle?.animationName ?? null,
        fillAnimName: fillStyle?.animationName ?? null,
        fillTransitionDuration: fillStyle?.transitionDuration ?? null,
      };
    });

    expect(styles.dotAnimName).toBe('none');
    expect(styles.fillAnimName).toBe('none');
    expect(Number.parseFloat(styles.fillTransitionDuration ?? '1')).toBeLessThanOrEqual(0.001);
  });

  test('8 Renders properly across both dark (tokyo-rain) and light (snow-day) themes', async ({ page }) => {
    const bar = statusBar(page);

    // Default theme: tokyo-rain
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'tokyo-rain');
    await expect(bar).toBeVisible();
    const darkBg = await bar.evaluate((el) => getComputedStyle(el).backgroundColor);
    const darkColor = await bar.evaluate((el) => getComputedStyle(el).color);
    expect(darkBg).not.toBe('rgba(0, 0, 0, 0)');

    // Switch via Settings UI to snow-day light theme
    await page.locator('.sidebar-nav').getByRole('button', { name: 'Settings' }).click();
    const snowDay = page.getByRole('radio', { name: 'Snow Day' });
    await snowDay.scrollIntoViewIfNeeded();
    await snowDay.click();

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'snow-day');
    await expect(bar).toBeVisible();
    const lightBg = await bar.evaluate((el) => getComputedStyle(el).backgroundColor);
    const lightColor = await bar.evaluate((el) => getComputedStyle(el).color);
    expect(lightBg).not.toBe('rgba(0, 0, 0, 0)');
    expect(lightBg).not.toBe(darkBg);
    expect(lightColor).not.toBe(darkColor);
  });
});
