import { isTauri, invoke as tauriInvoke } from '@tauri-apps/api/core';
import { handleMockInvoke } from './mockIpc';
import type { JobRecord } from './types';

export type JobDto = JobRecord;

let mockIgnoredDeps: Record<string, string[]> = {};
let mockIgnoredUntracked: Record<string, string[]> = {};

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

export async function ignoreDependency(addonId: string, depName: string): Promise<void> {
  if (isMockMode()) {
    const current = mockIgnoredDeps[addonId] ?? [];
    if (!current.some((d) => d.toLowerCase() === depName.trim().toLowerCase())) {
      mockIgnoredDeps[addonId] = [...current, depName.trim()];
    }
    return;
  }
  await invoke('ignore_dependency', {
    addonId,
    depName,
    addon_id: addonId,
    dep_name: depName,
  });
}

export async function unignoreDependency(addonId: string, depName: string): Promise<void> {
  if (isMockMode()) {
    const current = mockIgnoredDeps[addonId] ?? [];
    mockIgnoredDeps[addonId] = current.filter((d) => d.toLowerCase() !== depName.trim().toLowerCase());
    return;
  }
  await invoke('unignore_dependency', {
    addonId,
    depName,
    addon_id: addonId,
    dep_name: depName,
  });
}

export async function ignoreUntrackedAddon(flavour: string, folders: string[]): Promise<void> {
  if (isMockMode()) {
    const current = mockIgnoredUntracked[flavour] ?? [];
    const set = new Set(current.map((f) => f.toLowerCase()));
    for (const f of folders) {
      if (!set.has(f.toLowerCase())) current.push(f);
    }
    mockIgnoredUntracked[flavour] = current;
    return;
  }
  await invoke('ignore_untracked_addon', { flavour, folders });
}

export async function unignoreUntrackedFolder(flavour: string, folder: string): Promise<void> {
  if (isMockMode()) {
    const current = mockIgnoredUntracked[flavour] ?? [];
    mockIgnoredUntracked[flavour] = current.filter((f) => f.toLowerCase() !== folder.toLowerCase());
    return;
  }
  await invoke('unignore_untracked_folder', { flavour, folder });
}

export async function listIgnoredUntracked(flavour: string): Promise<string[]> {
  if (isMockMode()) {
    return mockIgnoredUntracked[flavour] ?? [];
  }
  return await invoke<string[]>('list_ignored_untracked', { flavour });
}

export async function deleteUntrackedAddon(flavour: string, folders: string[]): Promise<void> {
  if (isMockMode()) {
    return;
  }
  await invoke('delete_untracked_addon', { flavour, folders });
}

export async function invoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  let res: T;
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

    res = await handleMockInvoke<T>(cmd, args);

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
  } else {
    try {
      res = await tauriInvoke<T>(cmd, args);
    } catch (err) {
      console.error(`[IPC Error] ${cmd}:`, err);
      throw err;
    }
  }

  // In mock mode only, filter ignored dependencies and untracked folders
  if (isMockMode()) {
    if ((cmd === 'get_state' || cmd === 'get_addons') && res && typeof res === 'object') {
      const applyFilter = (addon: { id: string; missing_deps?: string[] }) => {
        const ignored = mockIgnoredDeps[addon.id];
        if (ignored && Array.isArray(ignored) && Array.isArray(addon.missing_deps)) {
          const ignoredLower = new Set(ignored.map((d) => d.toLowerCase()));
          addon.missing_deps = addon.missing_deps.filter((d) => !ignoredLower.has(d.toLowerCase()));
        }
      };

      if (cmd === 'get_state') {
        const state = res as { addons?: Array<{ id: string; missing_deps?: string[] }> };
        if (Array.isArray(state.addons)) {
          state.addons.forEach(applyFilter);
        }
      } else if (Array.isArray(res)) {
        (res as Array<{ id: string; missing_deps?: string[] }>).forEach(applyFilter);
      }
    }

    if (cmd === 'scan_untracked' && Array.isArray(res)) {
      const flv = (args.flavour as string) || 'retail';
      const ignoredList = mockIgnoredUntracked[flv] ?? [];
      if (ignoredList.length > 0) {
        const ignoredLower = new Set(ignoredList.map((f) => f.toLowerCase()));
        res = (res as Array<{ folders: string[] }>).filter(
          (group) => !group.folders.some((f) => ignoredLower.has(f.toLowerCase()))
        ) as T;
      }
    }
  }

  return res;
}

export async function installDependencies(flavour: string, addonId?: string): Promise<JobDto> {
  return invoke<JobDto>('install_dependencies', {
    flavour,
    addonId: addonId ?? null,
    addon_id: addonId ?? null,
  });
}
