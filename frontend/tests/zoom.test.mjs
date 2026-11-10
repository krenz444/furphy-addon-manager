import test from 'node:test';
import assert from 'node:assert/strict';
import { ZOOM_MIN, ZOOM_MAX, ZOOM_STEP, clampZoom, stepZoom, zoomKeyAction } from '../src/lib/zoom.ts';

const key = (k, mods = {}) => ({ key: k, ctrlKey: false, metaKey: false, altKey: false, ...mods });

test('the limits are 80 to 150 percent in steps of 10', () => {
  assert.equal(ZOOM_MIN, 0.8);
  assert.equal(ZOOM_MAX, 1.5);
  assert.equal(ZOOM_STEP, 0.1);
});

test('clampZoom stays inside the limits and rounds to one decimal', () => {
  assert.equal(clampZoom(0.1), 0.8);
  assert.equal(clampZoom(3), 1.5);
  assert.equal(clampZoom(1), 1);
  assert.equal(clampZoom(1.04), 1);
  assert.equal(clampZoom(1.26), 1.3);
  // 1.15 times ten is exactly 11.5 in floating point, which rounds up to 1.2
  assert.equal(clampZoom(1.15), 1.2);
});

test('clampZoom gives 1 for anything that is not a finite number', () => {
  assert.equal(clampZoom(NaN), 1);
  assert.equal(clampZoom(Infinity), 1);
  assert.equal(clampZoom(undefined), 1);
  assert.equal(clampZoom('1.2'), 1);
  assert.equal(clampZoom(null), 1);
});

test('stepZoom steps in both directions without drift, stops at the limits and resets', () => {
  assert.equal(stepZoom(1, 1), 1.1);
  assert.equal(stepZoom(1.1, 1), 1.2);
  assert.equal(stepZoom(1, -1), 0.9);
  assert.equal(stepZoom(0.9, -1), 0.8);
  assert.equal(stepZoom(0.8, -1), 0.8);
  assert.equal(stepZoom(1.5, 1), 1.5);
  assert.equal(stepZoom(1.3, 0), 1);
  let z = 1;
  for (let i = 0; i < 30; i++) z = stepZoom(z, 1);
  assert.equal(z, 1.5);
  for (let i = 0; i < 30; i++) z = stepZoom(z, -1);
  assert.equal(z, 0.8);
});

test('zoomKeyAction reads Ctrl or Cmd with plus, equals, minus, underscore and zero', () => {
  assert.equal(zoomKeyAction(key('+', { ctrlKey: true })), 1);
  assert.equal(zoomKeyAction(key('=', { ctrlKey: true })), 1);
  assert.equal(zoomKeyAction(key('-', { ctrlKey: true })), -1);
  assert.equal(zoomKeyAction(key('_', { metaKey: true })), -1);
  assert.equal(zoomKeyAction(key('0', { metaKey: true })), 0);
});

test('zoomKeyAction ignores Alt, a missing modifier and other keys', () => {
  assert.equal(zoomKeyAction(key('=', { ctrlKey: true, altKey: true })), null);
  assert.equal(zoomKeyAction(key('=')), null);
  assert.equal(zoomKeyAction(key('0')), null);
  assert.equal(zoomKeyAction(key('a', { ctrlKey: true })), null);
  assert.equal(zoomKeyAction(key('Escape', { ctrlKey: true })), null);
});
