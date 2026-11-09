import test from 'node:test';
import assert from 'node:assert/strict';
import { formatCheckedAgo } from '../src/lib/timeAgo.ts';
import {
  summarizeCheck,
  checkSuccessMessage,
  checkFailureMessage,
  isRunnerBusyError,
  errorText,
} from '../src/lib/checkReport.ts';

const NOW = Date.parse('2026-11-07T12:00:00Z');
const ago = (ms) => new Date(NOW - ms).toISOString();
const SEC = 1000;
const MIN = 60 * SEC;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

test('formatCheckedAgo: missing or unusable timestamps read as never checked', () => {
  assert.equal(formatCheckedAgo(null, NOW), 'Not checked yet');
  assert.equal(formatCheckedAgo(undefined, NOW), 'Not checked yet');
  assert.equal(formatCheckedAgo('', NOW), 'Not checked yet');
  assert.equal(formatCheckedAgo('yesterday-ish', NOW), 'Not checked yet');
});

test('formatCheckedAgo: thresholds and rounding down', () => {
  assert.equal(formatCheckedAgo(ago(0), NOW), 'Checked just now');
  assert.equal(formatCheckedAgo(ago(44 * SEC), NOW), 'Checked just now');
  assert.equal(formatCheckedAgo(ago(45 * SEC), NOW), 'Checked 1 min ago');
  assert.equal(formatCheckedAgo(ago(4 * MIN + 59 * SEC), NOW), 'Checked 4 min ago');
  assert.equal(formatCheckedAgo(ago(59 * MIN + 59 * SEC), NOW), 'Checked 59 min ago');
  assert.equal(formatCheckedAgo(ago(HOUR), NOW), 'Checked 1 h ago');
  assert.equal(formatCheckedAgo(ago(2 * HOUR + 50 * MIN), NOW), 'Checked 2 h ago');
  assert.equal(formatCheckedAgo(ago(23 * HOUR + 59 * MIN), NOW), 'Checked 23 h ago');
  assert.equal(formatCheckedAgo(ago(DAY), NOW), 'Checked 1 d ago');
  assert.equal(formatCheckedAgo(ago(9 * DAY + 3 * HOUR), NOW), 'Checked 9 d ago');
});

test('formatCheckedAgo: a future timestamp (clock skew) reads as just now', () => {
  assert.equal(formatCheckedAgo(ago(-10 * MIN), NOW), 'Checked just now');
});

test('formatCheckedAgo: parses the nanosecond RFC3339 form the backend writes', () => {
  assert.equal(formatCheckedAgo('2026-11-07T11:56:00.837661500+00:00', NOW), 'Checked 3 min ago');
});

function report(overrides = {}) {
  return {
    flavour: 'retail',
    checked_at: '2026-11-07T12:00:00Z',
    total: 35,
    would_update_count: 3,
    up_to_date_count: 28,
    ignored_count: 2,
    pinned_count: 2,
    failed_count: 0,
    held_count: 0,
    outcomes: [],
    ...overrides,
  };
}

test('summarizeCheck: reads a CheckRunReport given as a JSON string or an object', () => {
  const expected = { checked: 31, skipped: 4, updates: 3, failed: 0, failures: [], held: 0 };
  assert.deepEqual(summarizeCheck({ results: JSON.stringify(report()) }), expected);
  assert.deepEqual(summarizeCheck({ results: report() }), expected);
});

test('summarizeCheck: anything that is not a check report gives null', () => {
  assert.equal(summarizeCheck(null), null);
  assert.equal(summarizeCheck({ results: null }), null);
  assert.equal(summarizeCheck({ results: 'not json' }), null);
  assert.equal(summarizeCheck({ results: '[{"flavour":"retail","updated":[],"failed":[]}]' }), null);
  assert.equal(summarizeCheck({ results: JSON.stringify({ total: 3 }) }), null);
});

test('summarizeCheck: collects failed outcomes with a readable fallback for a missing error', () => {
  const s = summarizeCheck({
    results: JSON.stringify(
      report({
        failed_count: 2,
        outcomes: [
          { addon_id: 'a', name: 'Details', status: 'Failed', error: 'timeout' },
          { addon_id: 'b', status: 'Failed' },
          { addon_id: 'c', name: 'Plater', status: 'Up-to-date' },
        ],
      }),
    ),
  });
  assert.equal(s.failed, 2);
  assert.deepEqual(s.failures, [
    { name: 'Details', error: 'timeout' },
    { name: 'b', error: 'Unknown error' },
  ]);
});

test('summarizeCheck: a failure without a name falls back to the addon id before "Unknown addon"', () => {
  const s = summarizeCheck({
    results: JSON.stringify(
      report({
        failed_count: 3,
        outcomes: [
          { addon_id: 'details-damage-meter', name: '', status: 'Failed', error: 'timeout' },
          { addon_id: 'plater', status: 'Failed', error: 'timeout' },
          { status: 'Failed', error: 'timeout' },
        ],
      }),
    ),
  });
  assert.deepEqual(
    s.failures.map((f) => f.name),
    ['details-damage-meter', 'plater', 'Unknown addon'],
  );
});

test('errorText: strings, Errors, objects with a message, and everything else', () => {
  assert.equal(errorText('Another job (x) is currently running'), 'Another job (x) is currently running');
  assert.equal(errorText(new Error('boom')), 'boom');
  assert.equal(errorText({ message: 'Database locked', code: 500 }), 'Database locked');
  assert.equal(errorText({ code: 500 }), 'Unknown error');
  assert.equal(errorText(null), 'Unknown error');
  assert.equal(errorText(undefined), 'Unknown error');
});

test('checkSuccessMessage: counts, singular forms and the skipped note', () => {
  assert.equal(
    checkSuccessMessage({ checked: 31, skipped: 4, updates: 3, failed: 0, failures: [], held: 0 }),
    'Checked 31 addons, 4 ignored or pinned skipped. 3 updates ready.',
  );
  assert.equal(
    checkSuccessMessage({ checked: 1, skipped: 0, updates: 1, failed: 0, failures: [], held: 0 }),
    'Checked 1 addon. 1 update ready.',
  );
  assert.equal(
    checkSuccessMessage({ checked: 12, skipped: 0, updates: 0, failed: 0, failures: [], held: 0 }),
    'Checked 12 addons. Everything is up to date.',
  );
  assert.equal(
    checkSuccessMessage({ checked: 0, skipped: 5, updates: 0, failed: 0, failures: [], held: 0 }),
    'Checked 0 addons, 5 ignored or pinned skipped. Everything is up to date.',
  );
  assert.equal(
    checkSuccessMessage({ checked: 12, skipped: 0, updates: 3, failed: 0, failures: [], held: 1 }),
    'Checked 12 addons. 3 updates ready, 1 on hold.',
  );
});

test('checkFailureMessage: one name, several names, many names, and no names', () => {
  const f = (name, error = 'boom') => ({ name, error });
  assert.equal(
    checkFailureMessage({ checked: 9, skipped: 0, updates: 0, failed: 1, failures: [f('Details')] }),
    'Could not check Details: boom',
  );
  assert.equal(
    checkFailureMessage({ checked: 9, skipped: 0, updates: 0, failed: 2, failures: [f('A'), f('B')] }),
    'Could not check 2 addons: A, B.',
  );
  assert.equal(
    checkFailureMessage({ checked: 9, skipped: 0, updates: 0, failed: 5, failures: ['A', 'B', 'C', 'D', 'E'].map((n) => f(n)) }),
    'Could not check 5 addons: A, B, C and 2 more.',
  );
  const none = checkFailureMessage({ checked: 9, skipped: 0, updates: 0, failed: 0, failures: [] });
  assert.equal(none, 'Could not check 1 addon.');
  assert.ok(!/0 addon/.test(none));
});

test('isRunnerBusyError: matches the runner rejection and nothing else', () => {
  assert.equal(isRunnerBusyError('Another job (1f2e3d) is currently running'), true);
  assert.equal(isRunnerBusyError('Error: Another job (x) is currently running'), true);
  assert.equal(isRunnerBusyError("Job failed: Flavour 'retail' is not installed"), false);
  assert.equal(isRunnerBusyError('Database error: locked'), false);
});
