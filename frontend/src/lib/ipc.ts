import { isTauri, invoke as tauriInvoke } from '@tauri-apps/api/core';
import { handleMockInvoke } from './mockIpc';
import type { JobRecord } from './types';

export type JobDto = JobRecord;

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
    if (cmd === 'install_dependencies') {
      const addonId = (args.addon_id as string | null) ?? null;
      const flv = (args.flavour as string) || 'retail';
      return {
        id: `mock-job-${Date.now()}`,
        kind: 'install_dependencies',
        flavour: flv,
        params: JSON.stringify({ addon_id: addonId }),
        state: 'completed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: null,
        results: JSON.stringify([{ addon_id: addonId ?? 'all', installed_deps: ['Ace3', 'LibSharedMedia-3.0'] }]),
        reload_needed: false,
        log_path: 'mock/dependencies.log',
      } as T;
    }

    const res = await handleMockInvoke<T>(cmd, args);

    // Provide missing_deps fixture in mock mode if absent
    if (cmd === 'get_state' && res && typeof res === 'object') {
      const state = res as { addons?: Array<{ id: string; missing_deps?: string[] }> };
      if (Array.isArray(state.addons)) {
        const target = state.addons.find((a) => a.id === 'details');
        if (target && !target.missing_deps) {
          target.missing_deps = ['Ace3', 'LibSharedMedia-3.0'];
        }
      }
    } else if (cmd === 'get_addons' && Array.isArray(res)) {
      const list = res as Array<{ id: string; missing_deps?: string[] }>;
      const target = list.find((a) => a.id === 'details');
      if (target && !target.missing_deps) {
        target.missing_deps = ['Ace3', 'LibSharedMedia-3.0'];
      }
    }

    return res;
  }
  try {
    return await tauriInvoke<T>(cmd, args);
  } catch (err) {
    console.error(`[IPC Error] ${cmd}:`, err);
    throw err;
  }
}

export async function installDependencies(flavour: string, addonId?: string): Promise<JobDto> {
  return invoke<JobDto>('install_dependencies', { flavour, addon_id: addonId ?? null });
}
