import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeQuery, matchesQuery } from '../src/lib/settingsSearch.ts';

test('normalizeQuery lowers case, drops accents and collapses white space', () => {
  assert.equal(normalizeQuery('  Café   AU  Lait '), 'cafe au lait');
  assert.equal(normalizeQuery('\tIPv4\n'), 'ipv4');
  assert.equal(normalizeQuery(''), '');
});

test('an empty or blank query matches everything', () => {
  assert.equal(matchesQuery('', 'Appearance'), true);
  assert.equal(matchesQuery('   ', 'anything'), true);
});

test('matching ignores case and accents', () => {
  assert.equal(matchesQuery('cafe', 'Café settings'), true);
  assert.equal(matchesQuery('APPEAR', 'appearance'), true);
});

test('every word must be present, in any order', () => {
  assert.equal(matchesQuery('download ipv4', 'Use IPv4 only for downloads'), true);
  assert.equal(matchesQuery('ipv4 download', 'Use IPv4 only for downloads'), true);
  assert.equal(matchesQuery('ipv4 backup', 'Use IPv4 only for downloads'), false);
});

test('no match gives false and extra white space does not matter', () => {
  assert.equal(matchesQuery('zzzq', 'Appearance Advanced'), false);
  assert.equal(matchesQuery('  zoom   size ', 'Interface size and zoom'), true);
});
