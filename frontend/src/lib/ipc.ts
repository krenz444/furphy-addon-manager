import { isTauri, invoke as tauriInvoke } from '@tauri-apps/api/core';
import { handleMockInvoke } from './mockIpc';

export function isMockMode(): boolean {
  if (typeof window === 'undefined') return true;
  const urlParams = new URLSearchParams(window.location.search);
  if (urlParams.get('mock') === '1' || urlParams.get('test') === '1') {
    return true;
  }
  const w = window as unknown as {
    __TAURI_INTERNALS__?: unknown;
    __TAURI__?: unknown;
    isTauri?: unknown;
  };
  if (
    typeof w.__TAURI_INTERNALS__ !== 'undefined' ||
    typeof w.__TAURI__ !== 'undefined' ||
    Boolean(w.isTauri) ||
    isTauri()
  ) {
    return false;
  }
  return true;
}

export async function invoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  if (isMockMode()) {
    return handleMockInvoke<T>(cmd, args);
  }
  try {
    return await tauriInvoke<T>(cmd, args);
  } catch (err) {
    console.error(`[IPC Error] ${cmd}:`, err);
    throw err;
  }
}
