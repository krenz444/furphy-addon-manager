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

  wMock.getLastSyncParams = () => lastSyncParams;

  Object.defineProperty(wMock, 'lastSyncParams', {
    get() {
      return lastSyncParams;
    },
    configurable: true,
    enumerable: true,
  });
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
    const w = window as unknown as Record<string, unknown>;
    let currentMock = w.__furphyMock as Record<string, unknown> | undefined;
    if (currentMock) {
      attachFurphyMockHooks(currentMock);
    }
    Object.defineProperty(window, '__furphyMock', {
      configurable: true,
      enumerable: true,
      get() {
        return currentMock;
      },
      set(val: Record<string, unknown>) {
        currentMock = val;
        if (currentMock) {
          attachFurphyMockHooks(currentMock);
        }
      },
    });
  }
}
