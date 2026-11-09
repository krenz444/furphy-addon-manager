import { registerMockCommand, registerMockJob, getMockAddons } from '../mockIpc';
import type { JobRecord } from '../types';

let lastSyncParams: Record<string, unknown> | null = null;

function saveHeldStorage(addonId: string, held: boolean): void {
  try {
    if (typeof window !== 'undefined' && window.sessionStorage) {
      const raw = window.sessionStorage.getItem('furphy_mock_held');
      const map = raw ? JSON.parse(raw) : {};
      if (held) {
        map[addonId] = true;
      } else {
        delete map[addonId];
      }
      window.sessionStorage.setItem('furphy_mock_held', JSON.stringify(map));
    }
  } catch {}
}

function restoreHeldStorage(): void {
  try {
    if (typeof window !== 'undefined' && window.sessionStorage) {
      const raw = window.sessionStorage.getItem('furphy_mock_held');
      if (raw) {
        const map = JSON.parse(raw);
        const addons = getMockAddons();
        for (const [id, held] of Object.entries(map)) {
          const target = addons.find((a) => a.id === id);
          if (target) {
            target.held = Boolean(held);
            target.held_reason = held ? 'Built for newer game version' : null;
          }
        }
      }
    }
  } catch {}
}

function getFurphyMock(): Record<string, unknown> {
  if (typeof window === 'undefined') return {};
  const w = window as unknown as Record<string, unknown>;
  const desc = Object.getOwnPropertyDescriptor(w, '__furphyMock');
  if (!desc) {
    let currentMock = (w.__furphyMock as Record<string, unknown>) || {};
    Object.defineProperty(w, '__furphyMock', {
      configurable: true,
      enumerable: true,
      get() {
        return currentMock;
      },
      set(val: Record<string, unknown>) {
        if (val && typeof val === 'object') {
          Object.assign(val, currentMock);
          currentMock = val;
        } else {
          currentMock = val || {};
        }
      },
    });
  }
  return w.__furphyMock as Record<string, unknown>;
}

function attachFurphyMockHooks(wMock: Record<string, unknown>): void {
  wMock.setHeldAddon = (addonId: string, held: boolean, reason?: string) => {
    const addons = getMockAddons();
    const target = addons.find((a) => a.id === addonId);
    if (target) {
      target.held = held;
      target.held_reason = held ? (reason ?? 'Built for newer game version') : null;
    }
    saveHeldStorage(addonId, held);
  };

  wMock.setHeldCount = (count: number) => {
    const addons = getMockAddons();
    for (let i = 0; i < addons.length; i++) {
      const isHeld = i < count;
      addons[i].held = isHeld;
      addons[i].held_reason = isHeld ? 'Built for newer game version' : null;
      saveHeldStorage(addons[i].id, isHeld);
    }
  };

  wMock.getLastSyncParams = () => (wMock.lastSyncParams as Record<string, unknown> | null) ?? lastSyncParams;
  wMock.lastSyncParams = lastSyncParams;
}

export function initHoldbackMock(): void {
  restoreHeldStorage();

  registerMockCommand('hold_ignore_for_build', (_cmd, args) => {
    const addonId = args.addon_id as string;
    const target = getMockAddons().find((a) => a.id === addonId);
    if (target) {
      (target as unknown as Record<string, unknown>).ignored_until_build = (args.build as string) ?? '';
      target.held = false;
      target.held_reason = null;
    }
    saveHeldStorage(addonId, false);
    return null;
  });

  registerMockJob('sync', (_jobKind, flavour, params) => {
    lastSyncParams = params;
    const mock = getFurphyMock();
    mock.lastSyncParams = params;
    if (params?.override_hold && Array.isArray(params.only)) {
      const addons = getMockAddons();
      for (const id of params.only) {
        const target = addons.find((a) => a.id === id);
        if (target) {
          target.held = false;
          target.held_reason = null;
          saveHeldStorage(id, false);
        }
      }
    }
    const job: JobRecord = {
      id: `mock-sync-${Date.now()}`,
      kind: 'sync',
      flavour: flavour || 'retail',
      params: JSON.stringify(params || {}),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: JSON.stringify([{ flavour: flavour || 'retail', updated: ['Details! Damage Meter'], failed: [] }]),
      reload_needed: false,
      log_path: 'mock/sync.log',
    };
    return job;
  });

  if (typeof window !== 'undefined') {
    const wMock = getFurphyMock();
    attachFurphyMockHooks(wMock);
  }
}
