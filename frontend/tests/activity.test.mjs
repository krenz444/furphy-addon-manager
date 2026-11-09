import test from 'node:test';
import assert from 'node:assert/strict';

export function getDayHeading(iso, now = new Date()) {
  try {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const itemDay = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    const diffTime = today.getTime() - itemDay.getTime();
    const diffDays = Math.round(diffTime / (1000 * 3600 * 24));
    if (diffDays === 0) return 'Today';
    if (diffDays === 1) return 'Yesterday';
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
  } catch {
    return iso;
  }
}

export function groupActivitiesByDay(items, now = new Date()) {
  const groups = [];
  for (const act of items) {
    const heading = getDayHeading(act.ts, now);
    let g = groups.find((item) => item.heading === heading);
    if (!g) {
      g = { heading, items: [] };
      groups.push(g);
    }
    g.items.push(act);
  }
  return groups;
}

const REF_DATE = new Date('2026-11-08T15:30:00.000Z');
const ONE_HOUR = 60 * 60 * 1000;
const ONE_DAY = 24 * ONE_HOUR;

test('getDayHeading: returns "Today" for timestamps occurring on reference date', () => {
  const sameDaySameTime = REF_DATE.toISOString();
  const sameDayMorning = new Date(REF_DATE.getTime() - 4 * ONE_HOUR).toISOString();

  assert.equal(getDayHeading(sameDaySameTime, REF_DATE), 'Today');
  assert.equal(getDayHeading(sameDayMorning, REF_DATE), 'Today');
});

test('getDayHeading: returns "Yesterday" for timestamps occurring one day earlier', () => {
  const yesterday = new Date(REF_DATE.getTime() - ONE_DAY).toISOString();
  assert.equal(getDayHeading(yesterday, REF_DATE), 'Yesterday');
});

test('getDayHeading: returns formatted date for older timestamps (e.g. November 5, 2026)', () => {
  const threeDaysAgo = new Date(REF_DATE.getTime() - 3 * ONE_DAY);
  const expected = threeDaysAgo.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });

  assert.equal(getDayHeading(threeDaysAgo.toISOString(), REF_DATE), expected);
});

test('getDayHeading: gracefully handles invalid date strings', () => {
  assert.equal(getDayHeading('invalid-timestamp', REF_DATE), 'invalid-timestamp');
});

test('groupActivitiesByDay: returns empty array for empty activity list', () => {
  assert.deepEqual(groupActivitiesByDay([], REF_DATE), []);
});

test('groupActivitiesByDay: groups multiple entries by day under correct headings', () => {
  const items = [
    {
      id: '1',
      ts: REF_DATE.toISOString(),
      addon_id: 'details',
      name: 'Details!',
      flavour: 'retail',
      kind: 'updated',
    },
    {
      id: '2',
      ts: new Date(REF_DATE.getTime() - 2 * ONE_HOUR).toISOString(),
      addon_id: 'weakauras',
      name: 'WeakAuras',
      flavour: 'retail',
      kind: 'installed',
    },
    {
      id: '3',
      ts: new Date(REF_DATE.getTime() - ONE_DAY).toISOString(),
      addon_id: 'plater',
      name: 'Plater',
      flavour: 'retail',
      kind: 'updated',
    },
    {
      id: '4',
      ts: new Date(REF_DATE.getTime() - 4 * ONE_DAY).toISOString(),
      addon_id: 'bagnon',
      name: 'Bagnon',
      flavour: 'classic',
      kind: 'removed',
    },
  ];

  const groups = groupActivitiesByDay(items, REF_DATE);

  assert.equal(groups.length, 3);
  assert.equal(groups[0].heading, 'Today');
  assert.equal(groups[0].items.length, 2);
  assert.equal(groups[0].items[0].id, '1');
  assert.equal(groups[0].items[1].id, '2');

  assert.equal(groups[1].heading, 'Yesterday');
  assert.equal(groups[1].items.length, 1);
  assert.equal(groups[1].items[0].id, '3');

  const fourDaysAgo = new Date(REF_DATE.getTime() - 4 * ONE_DAY);
  const expectedOldDate = fourDaysAgo.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });
  assert.equal(groups[2].heading, expectedOldDate);
  assert.equal(groups[2].items.length, 1);
  assert.equal(groups[2].items[0].id, '4');
});
