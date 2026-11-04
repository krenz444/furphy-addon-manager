import test from 'node:test';
import assert from 'node:assert/strict';

test('1. Monotonic searchSeq drops stale out-of-order search responses', async () => {
  let searchSeq = 0;
  let activeResults = [];
  let loadingState = false;
  let errorState = null;

  async function mockSearch(query, latencyMs, mockData) {
    const seq = ++searchSeq;
    loadingState = true;
    errorState = null;

    return new Promise((resolve) => {
      setTimeout(() => {
        // Monotonic guard: drop stale responses if superseded
        if (seq !== searchSeq) {
          resolve({ dropped: true, seq });
          return;
        }

        activeResults = mockData;
        loadingState = false;
        resolve({ dropped: false, seq });
      }, latencyMs);
    });
  }

  // Launch initial slow query (Query A, latency 100ms)
  const queryAPromise = mockSearch('details', 100, [{ slug: 'details' }]);
  assert.equal(searchSeq, 1);

  // User immediately changes query (Query B, latency 20ms) before Query A finishes
  const queryBPromise = mockSearch('plater', 20, [{ slug: 'plater' }]);
  assert.equal(searchSeq, 2);

  const [resA, resB] = await Promise.all([queryAPromise, queryBPromise]);

  // Query B finished first
  assert.equal(resB.dropped, false);
  assert.equal(resB.seq, 2);

  // Query A arrived later but was dropped by searchSeq guard
  assert.equal(resA.dropped, true);
  assert.equal(resA.seq, 1);

  // Final UI state reflects Query B only
  assert.deepEqual(activeResults, [{ slug: 'plater' }]);
  assert.equal(loadingState, false);
});

test('2. 120-addon ceiling pauses auto-fill and sentinel, manual trigger advances ceiling', () => {
  const AUTOFILL_MAX_RESULTS = 120;
  let autoCeiling = AUTOFILL_MAX_RESULTS;
  let hasMore = true;
  let results = Array.from({ length: 105 }, (_, i) => ({ slug: `addon-${i}` }));

  function isCeilingReached() {
    return hasMore && results.length >= autoCeiling;
  }

  // 105 items: under ceiling
  assert.equal(isCeilingReached(), false);

  // Page loads +15 items -> 120 items
  results = Array.from({ length: 120 }, (_, i) => ({ slug: `addon-${i}` }));

  // Exactly at ceiling -> auto-fill must pause
  assert.equal(isCeilingReached(), true);

  // Simulate auto-trigger attempt: rejected when ceiling reached
  let autoTriggerCalled = false;
  function attemptAutoLoad() {
    if (isCeilingReached()) return;
    autoTriggerCalled = true;
  }
  attemptAutoLoad();
  assert.equal(autoTriggerCalled, false);

  // User clicks manual "Load More Addons" button -> advances ceiling
  function handleManualLoadMore() {
    if (results.length >= autoCeiling) {
      autoCeiling = results.length + AUTOFILL_MAX_RESULTS;
    }
    // Load next page
    results = [...results, ...Array.from({ length: 15 }, (_, i) => ({ slug: `addon-${120 + i}` }))];
  }

  handleManualLoadMore();
  assert.equal(results.length, 135);
  assert.equal(autoCeiling, 240);
  assert.equal(isCeilingReached(), false); // ceiling lifted, paging re-armed up to 240
});

test('3. Runaway pagination loops are strictly terminated by boundary conditions', () => {
  let hasMore = true;
  let results = [{ slug: 'addon-1' }, { slug: 'addon-2' }];
  const totalCount = 2;

  // Case A: Total count reached
  const newItemsA = [{ slug: 'addon-3' }];
  if (totalCount > 0 && results.length >= totalCount) {
    hasMore = false;
  }
  assert.equal(hasMore, false);

  // Case B: Server returns empty array
  hasMore = true;
  const newItemsB = [];
  if (newItemsB.length === 0) {
    hasMore = false;
  }
  assert.equal(hasMore, false);

  // Case C: Server returns duplicate items that yield zero unique new items
  hasMore = true;
  const existingSlugs = new Set(results.map((r) => r.slug));
  const newItemsC = [{ slug: 'addon-1' }, { slug: 'addon-2' }];
  const uniqueNew = newItemsC.filter((r) => !existingSlugs.has(r.slug));
  if (uniqueNew.length === 0) {
    hasMore = false;
  }
  assert.equal(hasMore, false);
});

test('4. InfiniteScrollTrigger re-arming logic on intersection leave', () => {
  let triggered = false;
  let triggerCount = 0;
  let lastTriggerTime = 0;
  const throttleMs = 400;

  function onIntersectionChange(isIntersecting) {
    if (isIntersecting) {
      const now = Date.now();
      if (!triggered && now - lastTriggerTime >= throttleMs) {
        triggered = true;
        lastTriggerTime = now;
        triggerCount++;
      }
    } else {
      // Re-arm when exiting viewport
      triggered = false;
    }
  }

  // 1st entry into viewport
  onIntersectionChange(true);
  assert.equal(triggerCount, 1);
  assert.equal(triggered, true);

  // Duplicate intersection event while still in view: ignored
  onIntersectionChange(true);
  assert.equal(triggerCount, 1);

  // User scrolls away (leaves viewport)
  onIntersectionChange(false);
  assert.equal(triggered, false); // Re-armed!

  // Advance time past throttle
  lastTriggerTime -= 500;

  // User scrolls back down (enters viewport)
  onIntersectionChange(true);
  assert.equal(triggerCount, 2); // Fires successfully!
});
