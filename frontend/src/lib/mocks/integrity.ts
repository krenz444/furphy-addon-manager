import { registerMockCommand, registerMockJob, getMockAddons } from '../mockIpc';
import type { IntegrityReport, JobRecord, FileIntegrityDiff } from '../types';

interface MockZipBackup {
  id: string;
  flavour: string;
  addon_ids: string[];
  created_at: string;
  params: Record<string, unknown>;
}

let mockZipBackups: MockZipBackup[] = [];
let lastSyncParams: Record<string, unknown> | null = null;
let mockShowFolderCalls: Array<{ flavour: string; addon_id: string }> = [];
let mockReinstallCalls: Array<{ flavour: string | null; params: Record<string, unknown> }> = [];

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

function attachIntegrityHooks(target: Record<string, unknown>): void {
  target.setAddonIntegrityStatus = (
    addonId: string,
    status: 'clean' | 'modified' | 'missing' | 'unknown'
  ) => {
    const addon = getMockAddons().find((a) => a.id === addonId);
    if (addon) {
      addon.integrity_status = status;
    }
  };
  target.setIntegrityStatus = target.setAddonIntegrityStatus;
  target.getMockZipBackups = () => [...mockZipBackups];
  target.clearMockZipBackups = () => {
    mockZipBackups = [];
  };
  target.getLastSyncParams = () => (target.lastSyncParams as Record<string, unknown> | null) ?? lastSyncParams;
  target.lastSyncParams = lastSyncParams;
  target.getShowFolderCalls = () => [...mockShowFolderCalls];
  target.getReinstallCalls = () => [...mockReinstallCalls];
}

export function initIntegrityMock(): void {
  if (typeof window !== 'undefined') {
    const overrides = (window as unknown as {
      __initialIntegrityOverrides?: Record<string, 'clean' | 'modified' | 'missing' | 'unknown'>;
    }).__initialIntegrityOverrides;
    if (overrides) {
      for (const [id, status] of Object.entries(overrides)) {
        const target = getMockAddons().find((a) => a.id === id);
        if (target) {
          target.integrity_status = status;
        }
      }
    }
  }

  registerMockCommand('show_addon_folder', (_cmd, args) => {
    mockShowFolderCalls.push({
      flavour: (args.flavour as string) || 'retail',
      addon_id: (args.addon_id as string) || '',
    });
    return null;
  });

  registerMockCommand('integrity_report', (_cmd, args) => {
    const addonId = (args.addon_id as string) || '';
    const addon = getMockAddons().find((a) => a.id === addonId);
    const status = addon?.integrity_status ?? 'clean';
    const diffs: FileIntegrityDiff[] = [];
    if (status === 'modified') {
      diffs.push({
        rel_path: 'mock_file.lua',
        expected_hash: 'abcdef1234567890',
        actual_hash: '1234567890abcdef',
        reason: 'hash_mismatch',
      });
    } else if (status === 'missing') {
      diffs.push({
        rel_path: 'core.lua',
        expected_hash: 'abcdef1234567890',
        actual_hash: null,
        reason: 'file_missing',
      });
    }
    const report: IntegrityReport = {
      addon_id: addonId,
      status,
      diffs,
    };
    return report;
  });

  registerMockJob('reinstall', (_jobKind, flavour, params) => {
    mockReinstallCalls.push({ flavour, params });
    const addonId = (params?.addon_id as string) || (params?.id as string) || '';
    if (addonId) {
      const target = getMockAddons().find((a) => a.id === addonId);
      if (target) {
        target.integrity_status = 'clean';
      }
    }
    const job: JobRecord = {
      id: `mock-reinstall-${Date.now()}`,
      kind: 'reinstall',
      flavour: flavour || 'retail',
      params: JSON.stringify(params),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: null,
      reload_needed: false,
      log_path: 'mock/reinstall.log',
    };
    return job;
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
        }
      }
    }

    if (params?.backup_modified === true) {
      mockZipBackups.push({
        id: `mock-zip-${Date.now()}`,
        flavour: flavour || 'retail',
        addon_ids: (params.only as string[]) || (params.addon_ids as string[]) || [],
        created_at: new Date().toISOString(),
        params,
      });
    }

    const targetIds: string[] = (params?.only as string[]) || (params?.addon_ids as string[]) || [];
    const addons = getMockAddons();
    for (const addon of addons) {
      if (targetIds.length > 0 && !targetIds.includes(addon.id)) continue;
      if (addon.update_version) {
        addon.version = addon.update_version;
        addon.update_version = null;
        addon.update_file_id = null;
        addon.check_status = 'up_to_date';
      }
      addon.integrity_status = 'clean';
    }

    const job: JobRecord = {
      id: `mock-sync-${Date.now()}`,
      kind: 'sync',
      flavour: flavour || 'retail',
      params: JSON.stringify(params),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: JSON.stringify([{ flavour: flavour || 'retail', updated: targetIds.length > 0 ? targetIds : ['all'], failed: [] }]),
      reload_needed: false,
      log_path: 'mock/sync.log',
    };
    return job;
  });

  if (typeof window !== 'undefined') {
    const currentMock = getFurphyMock();
    attachIntegrityHooks(currentMock);
  }
}
