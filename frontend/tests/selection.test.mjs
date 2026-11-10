import test from 'node:test';
import assert from 'node:assert/strict';
import { selectRange, nextSelection, isEditableTarget } from '../src/lib/selection.ts';

const ids = ['a', 'b', 'c', 'd', 'e', 'f'];

test('selectRange goes forward and backward in list order', () => {
  assert.deepEqual(selectRange(ids, 'b', 'e'), ['b', 'c', 'd', 'e']);
  assert.deepEqual(selectRange(ids, 'e', 'b'), ['b', 'c', 'd', 'e']);
  assert.deepEqual(selectRange(ids, 'c', 'c'), ['c']);
});

test('selectRange without a usable anchor gives the target, without a target gives nothing', () => {
  assert.deepEqual(selectRange(ids, null, 'd'), ['d']);
  assert.deepEqual(selectRange(ids, 'zzz', 'd'), ['d']);
  assert.deepEqual(selectRange(ids, 'b', 'zzz'), []);
  assert.deepEqual(selectRange([], null, 'a'), []);
});

test('a plain click toggles one row and moves the anchor', () => {
  const first = nextSelection(new Set(), ids, null, 'c', { shift: false, ctrl: false });
  assert.deepEqual([...first.selected], ['c']);
  assert.equal(first.anchor, 'c');
  const second = nextSelection(first.selected, ids, first.anchor, 'c', { shift: false, ctrl: false });
  assert.equal(second.selected.size, 0);
  assert.equal(second.anchor, 'c');
});

test('ctrl click toggles like a plain click and keeps the rest', () => {
  const result = nextSelection(new Set(['a']), ids, 'a', 'd', { shift: false, ctrl: true });
  assert.deepEqual([...result.selected].sort(), ['a', 'd']);
  assert.equal(result.anchor, 'd');
});

test('shift click adds the range to the current selection and moves the anchor', () => {
  const result = nextSelection(new Set(['a']), ids, 'b', 'e', { shift: true, ctrl: false });
  assert.deepEqual([...result.selected].sort(), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(result.anchor, 'e');
});

test('shift click without a usable anchor acts as a plain click', () => {
  const result = nextSelection(new Set(), ids, null, 'c', { shift: true, ctrl: false });
  assert.deepEqual([...result.selected], ['c']);
  const stale = nextSelection(new Set(), ids, 'gone', 'c', { shift: true, ctrl: false });
  assert.deepEqual([...stale.selected], ['c']);
});

test('nextSelection never changes its input and keeps ids that are not in the list', () => {
  const current = new Set(['x', 'b']);
  const result = nextSelection(current, ids, 'a', 'c', { shift: true, ctrl: false });
  assert.deepEqual([...current].sort(), ['b', 'x']);
  assert.deepEqual([...result.selected].sort(), ['a', 'b', 'c', 'x']);
  assert.notEqual(result.selected, current);
});

test('isEditableTarget is true for text fields, textareas, selects and contenteditable', () => {
  assert.equal(isEditableTarget({ tagName: 'INPUT', type: 'text' }), true);
  assert.equal(isEditableTarget({ tagName: 'input', type: 'search' }), true);
  assert.equal(isEditableTarget({ tagName: 'INPUT' }), true);
  assert.equal(isEditableTarget({ tagName: 'TEXTAREA' }), true);
  assert.equal(isEditableTarget({ tagName: 'select' }), true);
  assert.equal(isEditableTarget({ tagName: 'DIV', isContentEditable: true }), true);
});

test('isEditableTarget is false for checkboxes, buttons and everything else', () => {
  for (const type of ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color']) {
    assert.equal(isEditableTarget({ tagName: 'INPUT', type }), false, type);
  }
  assert.equal(isEditableTarget({ tagName: 'DIV' }), false);
  assert.equal(isEditableTarget({ tagName: 'BUTTON' }), false);
  assert.equal(isEditableTarget(null), false);
  assert.equal(isEditableTarget(undefined), false);
});
