import test from 'node:test';
import assert from 'node:assert/strict';
import { formatReleased, compareReleased } from '../src/lib/releaseDate.ts';

// A local noon, so "today" and "yesterday" hold in every time zone.
const now = new Date(2026, 10, 10, 12, 0, 0);

test('unknown, empty and unreadable dates show a dash and say so', () => {
  for (const value of [null, undefined, '', 'not a date']) {
    const out = formatReleased(value, now);
    assert.equal(out.text, '-');
    assert.equal(out.title, 'Release date unknown');
  }
});

test('today and yesterday are named', () => {
  assert.equal(formatReleased(new Date(2026, 10, 10, 8, 30).toISOString(), now).text, 'Today');
  assert.equal(formatReleased(new Date(2026, 10, 9, 23, 0).toISOString(), now).text, 'Yesterday');
});

test('an older date in the same year shows month and day', () => {
  assert.equal(formatReleased(new Date(2026, 9, 29, 15, 0).toISOString(), now).text, 'Oct 29');
});

test('a date in another year shows the year', () => {
  assert.equal(formatReleased(new Date(2025, 10, 8, 15, 0).toISOString(), now).text, 'Nov 8, 2025');
});

test('a date in the future still shows a date, never Today', () => {
  assert.equal(formatReleased(new Date(2026, 11, 24, 15, 0).toISOString(), now).text, 'Dec 24');
});

test('the title holds the full local date and time', () => {
  const out = formatReleased(new Date(2026, 9, 29, 15, 5).toISOString(), now);
  assert.match(out.title, /October 29, 2026/);
  assert.match(out.title, /3:05\s?PM/);
});

test('compareReleased puts the newest first and unknown last', () => {
  const list = ['2026-01-01T00:00:00Z', null, '2026-06-01T00:00:00Z', 'garbage', '2025-01-01T00:00:00Z'];
  const sorted = [...list].sort(compareReleased);
  assert.deepEqual(sorted, ['2026-06-01T00:00:00Z', '2026-01-01T00:00:00Z', '2025-01-01T00:00:00Z', null, 'garbage']);
  assert.equal(compareReleased(null, 'garbage'), 0);
  assert.equal(compareReleased('2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'), 0);
  assert.ok(compareReleased('2026-06-01T00:00:00Z', '2026-01-01T00:00:00Z') < 0);
  assert.ok(compareReleased(null, '2026-01-01T00:00:00Z') > 0);
});
