// Applies and remembers the interface zoom. The pure rules are in zoom.ts.
import { invoke, isMockMode } from './ipc';
import { clampZoom, stepZoom, zoomKeyAction } from './zoom';

let current = 1;
const listeners = new Set<(z: number) => void>();

export function getZoom(): number {
  return current;
}

/** Calls back after every change; returns a function that stops the calls. */
export function onZoomChange(cb: (z: number) => void): () => void {
  listeners.add(cb);
  return () => {
    listeners.delete(cb);
  };
}

function notify(): void {
  for (const cb of listeners) {
    try {
      cb(current);
    } catch {
      // a listener must not break the others
    }
  }
}

// The real app zooms the webview itself (needs the capability core:webview:allow-set-webview-zoom);
// the browser mock used by the tests has no webview, so it zooms the document.
async function applyToWebview(z: number): Promise<void> {
  try {
    if (isMockMode()) {
      document.documentElement.style.zoom = String(z);
      return;
    }
    const { getCurrentWebview } = await import('@tauri-apps/api/webview');
    await getCurrentWebview().setZoom(z);
  } catch (err) {
    console.warn('Could not apply the interface zoom:', err);
  }
}

/** At start: reads settings.uiZoom (a number), applies it and remembers it. */
export async function initZoomFromSettings(settings: Record<string, unknown>): Promise<number> {
  const stored = settings?.uiZoom;
  current = clampZoom(typeof stored === 'number' ? stored : Number(stored ?? 1));
  await applyToWebview(current);
  notify();
  return current;
}

/** Clamps, applies, saves and announces a new zoom. A failed save is logged and never undoes the zoom. */
export async function setZoom(z: number): Promise<number> {
  current = clampZoom(z);
  await applyToWebview(current);
  notify();
  try {
    await invoke('update_settings', { key: 'uiZoom', value: current });
  } catch (err) {
    console.warn('Could not save the interface zoom:', err);
  }
  return current;
}

/** Window keydown handler body: true when the key was a zoom key (the caller then calls preventDefault). */
export function handleZoomKey(e: KeyboardEvent): boolean {
  const action = zoomKeyAction(e);
  if (action === null) return false;
  void setZoom(stepZoom(current, action));
  return true;
}
