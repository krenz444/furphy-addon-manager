// Interface zoom: the limits, stepping and the keyboard shortcut. Pure; applying the zoom is in zoomControl.ts.

export const ZOOM_MIN = 0.8;
export const ZOOM_MAX = 1.5;
export const ZOOM_STEP = 0.1;

/** Anything that is not a finite number gives 1. Otherwise clamped to the limits and rounded to one decimal. */
export function clampZoom(z: number): number {
  if (typeof z !== 'number' || !Number.isFinite(z)) return 1;
  const clamped = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z));
  return Math.round(clamped * 10) / 10;
}

/** dir 1 zooms in, -1 out, 0 goes back to 100 percent. */
export function stepZoom(z: number, dir: 1 | -1 | 0): number {
  if (dir === 0) return 1;
  return clampZoom(clampZoom(z) + dir * ZOOM_STEP);
}

/** Ctrl or Cmd with plus or equals, minus or underscore, or zero. Alt turns it off so AltGr text input is left alone. */
export function zoomKeyAction(e: { key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean }): 1 | -1 | 0 | null {
  if (e.altKey) return null;
  if (!(e.ctrlKey || e.metaKey)) return null;
  switch (e.key) {
    case '+':
    case '=':
      return 1;
    case '-':
    case '_':
      return -1;
    case '0':
      return 0;
    default:
      return null;
  }
}
