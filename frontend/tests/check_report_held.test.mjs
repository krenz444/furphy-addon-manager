import test from 'node:test';
import assert from 'node:assert/strict';
import { summarizeCheck, checkSuccessMessage } from '../src/lib/checkReport.ts';

function createReport(overrides = {}) {
  return {
    flavour: 'retail',
    checked_at: '2026-11-08T12:00:00Z',
    total: 12,
    would_update_count: 3,
    up_to_date_count: 8,
    ignored_count: 0,
    pinned_count: 0,
    failed_count: 0,
    held_count: 1,
    outcomes: [],
    ...overrides,
  };
}

test('test_summarize_check_held_count: parses held_count from JSON string and object', () => {
  const reportObj = createReport({ held_count: 4 });
  const summaryFromObj = summarizeCheck({ results: reportObj });
  assert.ok(summaryFromObj);
  assert.equal(summaryFromObj.held, 4);

  const summaryFromJson = summarizeCheck({ results: JSON.stringify(reportObj) });
  assert.ok(summaryFromJson);
  assert.equal(summaryFromJson.held, 4);

  const zeroReport = createReport({ held_count: 0 });
  const summaryZero = summarizeCheck({ results: zeroReport });
  assert.ok(summaryZero);
  assert.equal(summaryZero.held, 0);

  const missingReport = createReport();
  delete missingReport.held_count;
  const summaryMissing = summarizeCheck({ results: missingReport });
  assert.ok(summaryMissing);
  assert.equal(summaryMissing.held, 0);
});

test('test_check_success_message_with_held: includes N on hold in success text', () => {
  const summaryWithBoth = {
    checked: 12,
    skipped: 0,
    updates: 3,
    failed: 0,
    failures: [],
    held: 1,
  };
  const msgBoth = checkSuccessMessage(summaryWithBoth);
  assert.equal(msgBoth, 'Checked 12 addons. 3 updates ready, 1 on hold.');
  assert.ok(msgBoth.includes('1 on hold'));

  const summaryHeldOnly = {
    checked: 10,
    skipped: 0,
    updates: 0,
    failed: 0,
    failures: [],
    held: 3,
  };
  const msgHeldOnly = checkSuccessMessage(summaryHeldOnly);
  assert.equal(msgHeldOnly, 'Checked 10 addons. 3 on hold.');
  assert.ok(msgHeldOnly.includes('3 on hold'));

  const summaryWithSkipped = {
    checked: 20,
    skipped: 4,
    updates: 2,
    failed: 0,
    failures: [],
    held: 5,
  };
  const msgSkipped = checkSuccessMessage(summaryWithSkipped);
  assert.equal(msgSkipped, 'Checked 20 addons, 4 ignored or pinned skipped. 2 updates ready, 5 on hold.');
  assert.ok(msgSkipped.includes('5 on hold'));
});
