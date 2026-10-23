import { isTauri, invoke as tauriInvoke } from '@tauri-apps/api/core';
import { handleMockInvoke } from './mockIpc';
import type { JobRecord } from './types';

export type JobDto = JobRecord;

const IGNORED_DEPS_KEY = 'furphy_ignored_dependencies';
const IGNORED_UNTRACKED_KEY_PREFIX = 'furphy_ignored_untracked_';

let inMemoryIgnoredDeps: Record<string, string[]> | null = null;
let inMemoryIgnoredUntracked: Record<string, string[]> = {};

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

async function loadIgnoredDeps(): Promise<Record<string, string[]>> {
  if (inMemoryIgnoredDeps !== null) return inMemoryIgnoredDeps;
  try {
    const settings = await invoke<Record<string, unknown>>('get_settings');
    if (settings && typeof settings === 'object' && IGNORED_DEPS_KEY in settings) {
      const val = settings[IGNORED_DEPS_KEY];
      const parsed = typeof val === 'string' ? JSON.parse(val) : val;
      if (parsed && typeof parsed === 'object') {
        inMemoryIgnoredDeps = parsed as Record<string, string[]>;
        return inMemoryIgnoredDeps;
      }
    }
  } catch {
    // fallback
  }
  if (typeof localStorage !== 'undefined') {
    try {
      const local = localStorage.getItem(IGNORED_DEPS_KEY);
      if (local) {
        inMemoryIgnoredDeps = JSON.parse(local);
        return inMemoryIgnoredDeps!;
      }
    } catch {}
  }
  inMemoryIgnoredDeps = {};
  return inMemoryIgnoredDeps;
}

async function saveIgnoredDeps(map: Record<string, string[]>): Promise<void> {
  inMemoryIgnoredDeps = map;
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(IGNORED_DEPS_KEY, JSON.stringify(map));
    } catch {}
  }
  try {
    await invoke('update_settings', { key: IGNORED_DEPS_KEY, value: map });
  } catch {}
}

async function loadIgnoredUntracked(flavour: string): Promise<string[]> {
  if (inMemoryIgnoredUntracked[flavour]) return inMemoryIgnoredUntracked[flavour];
  const key = `${IGNORED_UNTRACKED_KEY_PREFIX}${flavour}`;
  try {
    const settings = await invoke<Record<string, unknown>>('get_settings');
    if (settings && typeof settings === 'object' && key in settings) {
      const val = settings[key];
      const parsed = typeof val === 'string' ? JSON.parse(val) : val;
      if (Array.isArray(parsed)) {
        inMemoryIgnoredUntracked[flavour] = parsed;
        return inMemoryIgnoredUntracked[flavour];
      }
    }
  } catch {}
  if (typeof localStorage !== 'undefined') {
    try {
      const local = localStorage.getItem(key);
      if (local) {
        inMemoryIgnoredUntracked[flavour] = JSON.parse(local);
        return inMemoryIgnoredUntracked[flavour];
      }
    } catch {}
  }
  inMemoryIgnoredUntracked[flavour] = [];
  return inMemoryIgnoredUntracked[flavour];
}

async function saveIgnoredUntracked(flavour: string, list: string[]): Promise<void> {
  inMemoryIgnoredUntracked[flavour] = list;
  const key = `${IGNORED_UNTRACKED_KEY_PREFIX}${flavour}`;
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(key, JSON.stringify(list));
    } catch {}
  }
  try {
    await invoke('update_settings', { key, value: list });
  } catch {}
}

export async function ignoreDependency(addonId: string, depName: string): Promise<void> {
  const map = await loadIgnoredDeps();
  const current = map[addonId] ?? [];
  const normalized = depName.trim();
  if (!current.some((d) => d.toLowerCase() === normalized.toLowerCase())) {
    map[addonId] = [...current, normalized];
    await saveIgnoredDeps(map);
  }
}

export async function unignoreDependency(addonId: string, depName: string): Promise<void> {
  const map = await loadIgnoredDeps();
  const current = map[addonId] ?? [];
  const normalized = depName.trim().toLowerCase();
  map[addonId] = current.filter((d) => d.toLowerCase() !== normalized);
  await saveIgnoredDeps(map);
}

export async function ignoreUntrackedAddon(flavour: string, folders: string[]): Promise<void> {
  const list = await loadIgnoredUntracked(flavour);
  const set = new Set(list.map((f) => f.toLowerCase()));
  const additions: string[] = [];
  for (const f of folders) {
    const trimmed = f.trim();
    if (trimmed && !set.has(trimmed.toLowerCase())) {
      set.add(trimmed.toLowerCase());
      additions.push(trimmed);
    }
  }
  if (additions.length > 0) {
    await saveIgnoredUntracked(flavour, [...list, ...additions]);
  }
}

export async function unignoreUntrackedFolder(flavour: string, folder: string): Promise<void> {
  const list = await loadIgnoredUntracked(flavour);
  const normalized = folder.trim().toLowerCase();
  const next = list.filter((f) => f.toLowerCase() !== normalized);
  await saveIgnoredUntracked(flavour, next);
}

export async function listIgnoredUntracked(flavour: string): Promise<string[]> {
  return await loadIgnoredUntracked(flavour);
}

export async function deleteUntrackedAddon(flavour: string, folders: string[]): Promise<void> {
  for (const folder of folders) {
    await invoke('delete_untracked_folder', { flavour, folder });
    await unignoreUntrackedFolder(flavour, folder);
  }
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

  // Intercept and filter ignored dependencies from get_state and get_addons
  if ((cmd === 'get_state' || cmd === 'get_addons') && res && typeof res === 'object') {
    const ignoredMap = inMemoryIgnoredDeps ?? {};
    const applyFilter = (addon: { id: string; missing_deps?: string[] }) => {
      const ignored = ignoredMap[addon.id];
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

  // Intercept and filter ignored untracked folders from scan_untracked
  if (cmd === 'scan_untracked' && Array.isArray(res)) {
    const flv = (args.flavour as string) || 'retail';
    const ignoredList = inMemoryIgnoredUntracked[flv] ?? [];
    if (ignoredList.length > 0) {
      const ignoredLower = new Set(ignoredList.map((f) => f.toLowerCase()));
      res = (res as Array<{ folders: string[] }>).filter(
        (group) => !group.folders.some((f) => ignoredLower.has(f.toLowerCase()))
      ) as T;
    }
  }

  return res;
}

export async function installDependencies(flavour: string, addonId?: string): Promise<JobDto> {
  return invoke<JobDto>('install_dependencies', { flavour, addon_id: addonId ?? null });
}
