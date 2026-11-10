import type {
  Addon,
  Flavour,
  AppInfo,
  AppState,
  JobRecord,
  WtfSnapshot,
  VersionItem,
  ScannedCandidateGroup,
  PatchCompatStatus,
  DiagnosticItem,
  MigrationBackup,
} from './types';
import { initHoldbackMock } from './mocks/holdback';
import { initUpdateControlMock } from './mocks/updateControl';
import { initIntegrityMock } from './mocks/integrity';
import { initActivityMock } from './mocks/activity';
import { initWtfFullMock } from './mocks/wtfFull';
import { initGroupsMock } from './mocks/groups';
import { initZipInstallMock } from './mocks/zipInstall';
import { initTukuiMock } from './mocks/tukui';
import { initBattlenetMock } from './mocks/battlenet';
import { initCopyAddonsMock } from './mocks/copyAddons';

export type MockCommandHandler = (cmd: string, args: Record<string, unknown>) => Promise<unknown> | unknown;
export type MockJobHandler = (jobKind: string, flavour: string | null, params: Record<string, unknown>) => Promise<unknown> | unknown;

const mockRegistry = new Map<string, MockCommandHandler>();
const mockJobRegistry = new Map<string, MockJobHandler>();

export function registerMockCommand(cmd: string, handler: MockCommandHandler) {
  mockRegistry.set(cmd, handler);
}

export function registerMockJob(jobKind: string, handler: MockJobHandler) {
  mockJobRegistry.set(jobKind, handler);
}

const MOCK_FLAVOURS: Flavour[] = [
  { id: 'retail', folder: '_retail_', label: 'Retail', product: 'wow', installed: true },
  { id: 'classic_era', folder: '_classic_era_', label: 'Classic Era', product: 'wow_classic_era', installed: true },
  { id: 'classic', folder: '_classic_', label: 'Mists Classic', product: 'wow_classic', installed: true },
  { id: 'forever', folder: '_forever_', label: 'WoW Forever', product: 'wowf', installed: true },
];

function generateMockAddons(count: number = 200): Addon[] {
  const addons: Array<Omit<Addon, 'held' | 'held_reason' | 'auto_update' | 'integrity_status'>> = [
    {
      id: 'details',
      flavour: 'retail',
      name: 'Details! Damage Meter',
      author: 'Terciob',
      source: 'curseforge',
      version: '11.0.2.12840',
      project_id: 61284,
      file_id: '5681920',
      file_name: 'Details.11.0.2.zip',
      folders: ['Details', 'Details_Compare2', 'Details_DataStorage', 'Details_EncounterDetails', 'Details_RaidCheck', 'Details_Streamer', 'Details_TinyThreat', 'Details_Vanguard'],
      installed_at: '2026-10-15T14:30:00Z',
      adopted: false,
      ignore_updates: false,
      pinned_file_id: null,
      release_type: 1,
      update_version: '11.0.2.12900',
      update_file_id: '5710290',
      check_status: 'update_available',
      is_old_patch: false,
      wago_slug: null,
      repo: null,
    },
    {
      id: 'weakauras',
      flavour: 'retail',
      name: 'WeakAuras',
      author: 'The WeakAuras Team',
      source: 'wago',
      version: '5.18.3',
      project_id: null,
      file_id: 'wago_wa_5183',
      file_name: 'WeakAuras-5.18.3.zip',
      folders: ['WeakAuras', 'WeakAurasArchive', 'WeakAurasModelPaths', 'WeakAurasOptions', 'WeakAurasTemplates'],
      installed_at: '2026-10-18T09:12:00Z',
      adopted: false,
      ignore_updates: false,
      pinned_file_id: null,
      release_type: 1,
      update_version: null,
      update_file_id: null,
      check_status: 'up_to_date',
      is_old_patch: false,
      wago_slug: 'weakauras',
      repo: null,
    },
    {
      id: 'plater',
      flavour: 'retail',
      name: 'Plater Nameplates',
      author: 'Terciob',
      source: 'curseforge',
      version: '11.0.2.610',
      project_id: 327424,
      file_id: '5640102',
      file_name: 'Plater-11.0.2.zip',
      folders: ['Plater'],
      installed_at: '2026-10-10T12:00:00Z',
      adopted: false,
      ignore_updates: false,
      pinned_file_id: '5640102',
      release_type: 1,
      update_version: '11.0.2.615',
      update_file_id: '5690120',
      check_status: 'pinned',
      is_old_patch: false,
      wago_slug: null,
      repo: null,
    },
    {
      id: 'bigwigs',
      flavour: 'retail',
      name: 'BigWigs Bossmods',
      author: 'BigWigsMods',
      source: 'github',
      version: 'v340.2',
      project_id: null,
      file_id: 'gh_rel_3402',
      file_name: 'BigWigs-v340.2.zip',
      folders: ['BigWigs', 'BigWigs_Core', 'BigWigs_Plugins'],
      installed_at: '2026-10-19T18:22:00Z',
      adopted: false,
      ignore_updates: false,
      pinned_file_id: null,
      release_type: 1,
      update_version: null,
      update_file_id: null,
      check_status: 'up_to_date',
      is_old_patch: false,
      wago_slug: null,
      repo: 'BigWigsMods/BigWigs',
    },
    {
      id: 'deadly-boss-mods',
      flavour: 'retail',
      name: 'Deadly Boss Mods (DBM)',
      author: 'MysticalOS',
      source: 'curseforge',
      version: '11.0.18',
      project_id: 3358,
      file_id: '5621000',
      file_name: 'DBM-11.0.18.zip',
      folders: ['DBM-Core', 'DBM-GUI', 'DBM-StatusBarTimers'],
      installed_at: '2026-10-01T10:00:00Z',
      adopted: false,
      ignore_updates: true,
      pinned_file_id: null,
      release_type: 1,
      update_version: '11.0.22',
      update_file_id: '5700100',
      check_status: 'ignored',
      is_old_patch: false,
      wago_slug: null,
      repo: null,
    },
    {
      id: 'bagnon',
      flavour: 'retail',
      name: 'Bagnon',
      author: 'Jaliborc',
      source: 'curseforge',
      version: '10.2.7',
      project_id: 618,
      file_id: '5420100',
      file_name: 'Bagnon-10.2.7.zip',
      folders: ['Bagnon', 'Bagnon_Config', 'Bagnon_GuildBank', 'Bagnon_VoidStorage'],
      installed_at: '2026-08-20T11:00:00Z',
      adopted: true,
      ignore_updates: false,
      pinned_file_id: null,
      release_type: 1,
      update_version: null,
      update_file_id: null,
      check_status: 'old_patch',
      is_old_patch: true,
      wago_slug: null,
      repo: null,
    },
  ];

  // Synthesize up to count addons for performance benchmark scroll testing
  for (let i = addons.length + 1; i <= count; i++) {
    const isCf = i % 3 === 0;
    const isWago = i % 3 === 1;
    const hasUpdate = i % 7 === 0;
    const isPinned = i % 13 === 0;
    const isIgnored = i % 17 === 0;
    const isAdopted = i % 19 === 0;

    addons.push({
      id: `addon-bench-${i}`,
      flavour: 'retail',
      name: `Addon Suite Benchmark #${i}`,
      author: `Developer ${((i * 17) % 50) + 1}`,
      source: isCf ? 'curseforge' : isWago ? 'wago' : 'github',
      version: `2.${Math.floor(i / 10)}.${i % 10}`,
      project_id: isCf ? 100000 + i : null,
      file_id: `file_${i}`,
      file_name: `Addon_${i}.zip`,
      folders: [`AddonBench_${i}`, `AddonBench_${i}_Core`],
      installed_at: '2026-10-20T08:00:00Z',
      adopted: isAdopted,
      ignore_updates: isIgnored,
      pinned_file_id: isPinned ? `file_${i}` : null,
      release_type: 1,
      update_version: hasUpdate && !isPinned && !isIgnored ? `2.${Math.floor(i / 10) + 1}.0` : null,
      update_file_id: hasUpdate ? `file_${i}_up` : null,
      check_status: hasUpdate ? 'update_available' : isPinned ? 'pinned' : isIgnored ? 'ignored' : 'up_to_date',
      is_old_patch: i % 23 === 0,
      wago_slug: isWago ? `addon-bench-${i}` : null,
      repo: !isCf && !isWago ? `dev/addon-bench-${i}` : null,
    });
  }

  // Fixed reference day so release dates, and the sorts built on them, are the same on every run.
  const releaseReferenceMs = Date.UTC(2026, 9, 31, 12, 0, 0);
  return addons.map((a, index) => ({
    held: false,
    held_reason: null,
    auto_update: true,
    integrity_status: 'clean' as const,
    favourite: false,
    group_ids: [] as string[],
    released_at: index % 5 === 4 ? null : new Date(releaseReferenceMs - ((index * 37) % 400) * 86400000).toISOString(),
    ...a,
  }));
}

const mockAddons = generateMockAddons(200);

// Check-for-updates behaviour for browser mock mode, steerable from Playwright through window.__furphyMock.
interface MockCheckOutcome {
  addon_id: string;
  name: string;
  status: 'Up-to-date' | 'Would-update' | 'Pinned' | 'Ignored' | 'Failed';
  current_version: string | null;
  update_version: string | null;
  error: string | null;
}

interface FurphyMockHook {
  failNextCheck(message?: string): void;
  busyNextCheck(): void;
  partialFailureNextCheck(): void;
  setCheckedAt(iso: string | null, flavour?: string): void;
  setCheckDelay(ms: number): void;
  noUpdates(on: boolean): void;
  staleRunningJobOnce(kind: string): void;
  readonly checkCalls: number;
}

// Per game version, like the backend's freshness rows.
const mockCheckedAt: Record<string, string | null> = {
  retail: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(),
};
let mockCheckDelayMs = 400;
let mockCheckCalls = 0;
let mockNextCheck: 'ok' | 'fail' | 'busy' | 'partial' = 'ok';
let mockNextCheckError = 'Provider unreachable';
let mockNoUpdates = false;
let mockStaleJobKind: string | null = null;
let mockHookInstalled = false;

// Installed on the first mock call, so it only exists in mock mode.
function installMockHook(): void {
  if (mockHookInstalled || typeof window === 'undefined') return;
  mockHookInstalled = true;
  initHoldbackMock();
  initUpdateControlMock();
  initIntegrityMock();
  initActivityMock();
  initWtfFullMock();
  initGroupsMock();
  initZipInstallMock();
  initTukuiMock();
  initBattlenetMock();
  initCopyAddonsMock();
  const hook: FurphyMockHook = {
    failNextCheck(message = 'Provider unreachable') {
      mockNextCheck = 'fail';
      mockNextCheckError = message;
    },
    busyNextCheck() {
      mockNextCheck = 'busy';
    },
    partialFailureNextCheck() {
      mockNextCheck = 'partial';
    },
    setCheckedAt(iso, flavour = 'retail') {
      mockCheckedAt[flavour] = iso;
    },
    setCheckDelay(ms) {
      mockCheckDelayMs = ms;
    },
    noUpdates(on) {
      mockNoUpdates = on;
    },
    staleRunningJobOnce(kind) {
      mockStaleJobKind = kind;
    },
    get checkCalls() {
      return mockCheckCalls;
    },
  };
  (window as unknown as { __furphyMock: FurphyMockHook }).__furphyMock = hook;
}

// A background job the next get_state reports as running and then forgets, like one that finished unseen.
function takeStaleJob(flavour: string): JobRecord | null {
  if (!mockStaleJobKind) return null;
  const kind = mockStaleJobKind;
  mockStaleJobKind = null;
  return {
    id: 'mock-bg-1',
    kind,
    flavour,
    params: null,
    state: 'running',
    started_at: new Date().toISOString(),
    finished_at: null,
    error: null,
    results: null,
    reload_needed: false,
    log_path: null,
  };
}

function mockAddonsFor(flavour: string): Addon[] {
  const rows = mockAddons.filter((a) => a.flavour === flavour);
  if (!mockNoUpdates) return rows;
  return rows.map((a) => ({ ...a, update_version: null, update_file_id: null, check_status: 'up_to_date' }));
}

async function runMockCheck(flavour: string): Promise<JobRecord> {
  mockCheckCalls += 1;
  const behaviour = mockNextCheck;
  mockNextCheck = 'ok';
  // Long enough for a test to observe the busy state.
  await new Promise((r) => setTimeout(r, mockCheckDelayMs));
  // Tauri rejects with a plain string, so the mock does too. The real runner is busy because a job is
  // running, and the refresh that follows reports that job.
  if (behaviour === 'busy') {
    mockStaleJobKind = 'update-all-flavours';
    throw 'Another job (mock-bg-1) is currently running';
  }
  if (behaviour === 'fail') throw mockNextCheckError;

  let toFail = behaviour === 'partial' ? 2 : 0;
  const outcomes: MockCheckOutcome[] = mockAddonsFor(flavour).map((a) => {
    let status: MockCheckOutcome['status'] = 'Up-to-date';
    if (a.ignore_updates) status = 'Ignored';
    else if (a.pinned_file_id) status = 'Pinned';
    else if (toFail > 0) {
      status = 'Failed';
      toFail -= 1;
    } else if (a.update_version) status = 'Would-update';
    return {
      addon_id: a.id,
      name: a.name ?? a.id,
      status,
      current_version: a.version,
      update_version: status === 'Would-update' ? a.update_version ?? null : null,
      error: status === 'Failed' ? 'Provider timed out' : null,
    };
  });
  const tally = (s: MockCheckOutcome['status']) => outcomes.filter((o) => o.status === s).length;
  const failed = outcomes.filter((o) => o.status === 'Failed');
  const now = new Date().toISOString();
  mockCheckedAt[flavour] = now;

  return {
    id: `mock-check-${Date.now()}`,
    kind: 'check',
    flavour,
    params: '{}',
    state: 'completed',
    started_at: now,
    finished_at: now,
    error: failed.length
      ? `${failed.length} addon(s) failed: ${failed.map((o) => `${o.name}: ${o.error}`).join('; ')}`
      : null,
    results: JSON.stringify({
      flavour,
      checked_at: now,
      total: outcomes.length,
      would_update_count: tally('Would-update'),
      up_to_date_count: tally('Up-to-date'),
      ignored_count: tally('Ignored'),
      pinned_count: tally('Pinned'),
      failed_count: failed.length,
      outcomes,
    }),
    reload_needed: false,
    log_path: 'mock/sync.log',
  };
}

let mockSettings: Record<string, unknown> = {
  hostTheme: 'tokyo-rain',
  density: 'comfortable',
  backgroundUpdates: true,
  backgroundIntervalMinutes: 120,
  runAtStartup: true,
  includeBeta: false,
  includeAlpha: false,
  hasGithubToken: true,
  autoUpdateApp: true,
  cfAdFilter: true,
  cfFocus: true,
};

export function getMockAddons(): Addon[] {
  return mockAddons;
}

export function setMockAddons(addons: Addon[]): void {
  mockAddons.length = 0;
  mockAddons.push(...addons);
}

export function getMockFlavours(): Flavour[] {
  return MOCK_FLAVOURS;
}

export function getMockSettings(): Record<string, unknown> {
  return mockSettings;
}

export function getMockState(flavour: string = 'retail'): AppState {
  const filtered = mockAddonsFor(flavour);
  const updatesCount = filtered.filter((a) => a.update_version && !a.ignore_updates && !a.pinned_file_id).length;
  return {
    addons: filtered,
    flavours: MOCK_FLAVOURS,
    active_flavour: flavour,
    freshness: {
      state: filtered.length === 0 ? 'not_checked' : updatesCount > 0 ? 'updates_ready' : 'clean',
      checked_at: filtered.length === 0 ? null : (mockCheckedAt[flavour] ?? null),
      updates_count: updatesCount,
      last_error: null,
    },
    running_job: takeStaleJob(flavour),
    untracked_count: 2,
    is_game_active: false,
    app_info: {
      name: 'Furphy Addon Manager',
      version: '2.0.25',
      is_dev: false,
      identifier: 'krenzcreative.furphy.addonmanager',
    },
  };
}

export async function handleMockInvoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  installMockHook();
  // Artificial micro-delay for realistic UI feedback
  await new Promise((r) => setTimeout(r, 10));

  if (cmd === 'start_job') {
    const kind = args?.kind as string;
    if (mockJobRegistry.has(kind)) {
      return (await mockJobRegistry.get(kind)!(
        kind,
        (args?.flavour as string) || null,
        (args?.params as Record<string, unknown>) || {}
      )) as T;
    }
  }

  if (mockRegistry.has(cmd)) {
    return (await mockRegistry.get(cmd)!(cmd, args || {})) as T;
  }

  switch (cmd) {
    case 'get_app_info':
      return {
        name: 'Furphy Addon Manager',
        version: '2.0.25',
        is_dev: false,
        identifier: 'krenzcreative.furphy.addonmanager',
      } as T;

    case 'get_flavours':
      return MOCK_FLAVOURS as T;

    case 'get_addons': {
      const flv = (args.flavour as string) || 'retail';
      return mockAddonsFor(flv) as T;
    }

    case 'get_state': {
      const flv = (args.flavour as string) || 'retail';
      const filtered = mockAddonsFor(flv);
      const updatesCount = filtered.filter((a) => a.update_version && !a.ignore_updates && !a.pinned_file_id).length;
      const state: AppState = {
        addons: filtered,
        flavours: MOCK_FLAVOURS,
        active_flavour: flv,
        freshness: {
          state: filtered.length === 0 ? 'not_checked' : updatesCount > 0 ? 'updates_ready' : 'clean',
          checked_at: filtered.length === 0 ? null : (mockCheckedAt[flv] ?? null),
          updates_count: updatesCount,
          last_error: null,
        },
        running_job: takeStaleJob(flv),
        untracked_count: 2,
        is_game_active: false,
        app_info: {
          name: 'Furphy Addon Manager',
          version: '2.0.25',
          is_dev: false,
          identifier: 'krenzcreative.furphy.addonmanager',
        },
      };
      return state as T;
    }

    case 'set_ignore': {
      const id = args.id as string;
      const ignore = Boolean(args.ignore);
      const target = mockAddons.find((a) => a.id === id);
      if (target) {
        target.ignore_updates = ignore;
        target.check_status = ignore ? 'ignored' : target.update_version ? 'update_available' : 'up_to_date';
      }
      return undefined as T;
    }

    case 'unpin': {
      const id = args.id as string;
      const target = mockAddons.find((a) => a.id === id);
      if (target) {
        target.pinned_file_id = null;
        target.check_status = target.update_version ? 'update_available' : 'up_to_date';
      }
      return undefined as T;
    }

    case 'pin_version': {
      const id = args.id as string;
      const fileId = args.file_id as string;
      const target = mockAddons.find((a) => a.id === id);
      if (target) {
        target.pinned_file_id = fileId;
        target.check_status = 'pinned';
      }
      return undefined as T;
    }

    case 'list_files': {
      const id = args.id as string;
      const target = mockAddons.find((a) => a.id === id);
      const currentVer = target?.version || '1.0.0';
      const files: VersionItem[] = [
        { file_id: 'v_latest', version: target?.update_version || currentVer, kind: 'release', date: '2026-10-21T10:00:00Z', is_current: !target?.update_version, is_pinned: false },
        { file_id: 'v_curr', version: currentVer, kind: 'release', date: '2026-10-15T12:00:00Z', is_current: true, is_pinned: target?.pinned_file_id !== null },
        { file_id: 'v_prev', version: '1.0.9', kind: 'backup', date: '2026-09-30T09:00:00Z', is_current: false, is_pinned: false },
      ];
      return files as T;
    }

    case 'scan_untracked': {
      const untracked: ScannedCandidateGroup[] = [
        {
          name: 'HandyNotes',
          source: 'curseforge',
          project_id: 14190,
          wago_id: null,
          version: 'v1.6.18',
          author: 'Xinhuan',
          folders: ['HandyNotes'],
        },
        {
          name: 'RareScanner',
          source: 'curseforge',
          project_id: 279936,
          wago_id: null,
          version: '11.0.2.4',
          author: 'marceoc',
          folders: ['RareScanner'],
        },
      ];
      return untracked as T;
    }

    case 'delete_untracked_folder': {
      return undefined as T;
    }

    case 'adopt_untracked':
    case 'adopt_all_untracked': {
      return 2 as T;
    }

    case 'start_job': {
      const kind = args.kind as string;
      if (kind === 'check') return (await runMockCheck((args.flavour as string) || 'retail')) as T;
      if (kind === 'add') {
        // Steerable from Playwright: the next add fails with this text, then it is cleared.
        const hook = (typeof window !== 'undefined' ? (window as unknown as { __furphyMock?: { nextAddError?: unknown } }).__furphyMock : undefined);
        const failure = typeof hook?.nextAddError === 'string' ? hook.nextAddError : '';
        if (hook && failure) {
          hook.nextAddError = '';
          const failed: JobRecord = {
            id: `mock-job-${Date.now()}`,
            kind,
            flavour: (args.flavour as string) || 'retail',
            params: JSON.stringify(args.params || {}),
            state: 'failed',
            started_at: new Date().toISOString(),
            finished_at: new Date().toISOString(),
            error: failure,
            results: JSON.stringify([{ flavour: (args.flavour as string) || 'retail', updated: [], failed: [{ name: 'Addon', error: failure }] }]),
            reload_needed: false,
            log_path: 'mock/sync.log',
          };
          return failed as T;
        }
      }
      const job: JobRecord = {
        id: `mock-job-${Date.now()}`,
        kind,
        flavour: (args.flavour as string) || 'retail',
        params: JSON.stringify(args.params || {}),
        state: 'completed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: null,
        results: JSON.stringify([{ flavour: 'retail', updated: ['Details! Damage Meter'], failed: [] }]),
        reload_needed: false,
        log_path: 'mock/sync.log',
      };
      return job as T;
    }

    case 'list_jobs':
      return [] as T;

    case 'get_job':
      return null as T;

    case 'list_wtf_snapshots': {
      const addonId = args.addon_id as string;
      const snapshots: WtfSnapshot[] = [
        {
          id: 'snap-1',
          addon_id: addonId,
          kind: 'pre-update',
          path: 'C:/Users/drops/AppData/Local/furphy/wtf_snapshots/snap_1.zip',
          file_count: 8,
          total_bytes: 148200,
          created_at: '2026-10-20T14:32:00Z',
          restored_at: null,
        },
        {
          id: 'snap-2',
          addon_id: addonId,
          kind: 'pre-update',
          path: 'C:/Users/drops/AppData/Local/furphy/wtf_snapshots/snap_2.zip',
          file_count: 8,
          total_bytes: 142100,
          created_at: '2026-10-15T09:10:00Z',
          restored_at: null,
        },
      ];
      return snapshots as T;
    }

    case 'preview_wtf_restore':
      return [
        'Account/12345678#1/SavedVariables/Details.lua',
        'Account/12345678#1/SavedVariables/Details.lua.bak',
        'Account/12345678#1/SavedVariables/Details_DataStorage.lua',
      ] as T;

    case 'restore_wtf_snapshot':
      return undefined as T;

    case 'list_not_built_for_patch': {
      const notBuilt: PatchCompatStatus[] = mockAddons
        .filter((a) => a.is_old_patch)
        .map((a) => ({
          addon_id: a.id,
          name: a.name || a.id,
          installed_version: a.version,
          client_interface: 110002,
          toc_interface: 100207,
          is_old_patch: true,
        }));
      return notBuilt as T;
    }

    case 'get_settings':
      return { ...mockSettings } as T;

    case 'update_settings': {
      const key = args.key as string;
      mockSettings[key] = args.value;
      return undefined as T;
    }

    case 'set_flavour_install_path': {
      const flvId = args.flavour as string;
      const targetPath = args.path as string;
      const flv = MOCK_FLAVOURS.find((f) => f.id === flvId);
      if (flv) {
        flv.custom_root = targetPath;
        flv.addons_path = `${targetPath}/Interface/AddOns`;
        flv.installed = true;
        return { ...flv } as T;
      }
      return {
        id: flvId,
        folder: `_${flvId}_`,
        label: flvId,
        product: null,
        installed: true,
        custom_root: targetPath,
        addons_path: `${targetPath}/Interface/AddOns`,
      } as T;
    }

    case 'reset_flavour_install_path': {
      const flvId = args.flavour as string;
      const flv = MOCK_FLAVOURS.find((f) => f.id === flvId);
      if (flv) {
        flv.custom_root = null;
        flv.addons_path = null;
        return { ...flv } as T;
      }
      return {
        id: flvId,
        folder: `_${flvId}_`,
        label: flvId,
        product: null,
        installed: false,
        custom_root: null,
        addons_path: null,
      } as T;
    }

    case 'open_target':
      return undefined as T;

    case 'run_diagnostics': {
      const diagnostics: DiagnosticItem[] = [
        { name: 'World of Warcraft Root', ok: true, detail: 'C:\\Program Files (x86)\\World of Warcraft' },
        { name: 'Data Directory', ok: true, detail: 'C:\\Users\\drops\\AppData\\Local\\krenzcreative.furphy.addonmanager.dev' },
        { name: 'SQLite Database', ok: true, detail: 'furphy.db (WAL mode, foreign keys active)' },
        { name: 'CurseForge Policy', ok: true, detail: 'Standard policy active (2 requests in flight, 100ms pacing)' },
        { name: 'Host Breakers', ok: true, detail: 'CurseForge: online, Wago: online, GitHub: online' },
        { name: 'Application Mode', ok: true, detail: 'Development (Furphy Dev)' },
      ];
      return diagnostics as T;
    }

    case 'export_list':
      return 'C:/Users/drops/Documents/furphy-addons-export.json' as T;

    case 'import_list':
      return 5 as T;

    case 'list_migration_backups': {
      const backups: MigrationBackup[] = [
        { name: 'v1_migration_20261022.zip', path: 'C:/.../v1_migration_20261022.zip', size_bytes: 4520100 },
      ];
      return backups as T;
    }

    case 'delete_migration_backups':
      return undefined as T;

    case 'quit_app':
      return undefined as T;

    case 'set_window_theme':
      mockSettings.hostTheme = args.theme;
      return undefined as T;

    case 'autostart_status':
      return { enabled: true, dev_build: true, effective_state: true } as T;

    case 'autostart_enable':
      mockSettings.runAtStartup = true;
      return undefined as T;

    case 'autostart_disable':
      mockSettings.runAtStartup = false;
      return undefined as T;

    case 'protocol_status':
      return { registered: true, scheme: 'furphy-dev', dev_build: true } as T;

    case 'protocol_register':
    case 'protocol_unregister':
      return undefined as T;

    case 'get_tray_status':
    case 'tray_status':
      return {
        status: 'idle',
        core_text: 'Idle - all addons checked',
        tooltip: 'Furphy - Idle',
        icon_variant: 'normal',
        next_run_at: new Date(Date.now() + 3600000).toISOString(),
        balloon: null,
      } as T;

    case 'set_background_updates':
      mockSettings.backgroundUpdates = Boolean(args.enabled);
      return undefined as T;

    case 'is_game_active':
      return false as T;

    case 'wago_categories':
      return [
        { id: 'action-bars', label: 'Action Bars' },
        { id: 'auction-economy', label: 'Auction & Economy' },
        { id: 'bags-inventory', label: 'Bags & Inventory' },
        { id: 'boss-encounters', label: 'Boss Encounters' },
        { id: 'chat-communication', label: 'Chat & Communication' },
        { id: 'class', label: 'Class' },
        { id: 'combat', label: 'Combat' },
        { id: 'map-minimap', label: 'Map & Minimap' },
        { id: 'professions', label: 'Professions' },
        { id: 'quests-leveling', label: 'Quests & Leveling' },
        { id: 'unit-frames', label: 'Unit Frames' },
      ] as T;

    case 'wago_search': {
      const page = Number(args?.page) || 1;
      const flv = String(args?.flavour || 'retail');
      const isClassicOrForever = flv === 'classic' || flv === 'classic_era' || flv === 'forever';
      const mockPool = isClassicOrForever
        ? [
            { id: 'wa-details-c', slug: 'details-damage-meter-standalone', name: 'Details! Damage Meter (Classic)', author: 'Terciob', description: 'Advanced combat meter for Classic & WoW Forever.', downloads: 3500000, version: '1.15.2', game_version: 'classic', wago_url: 'https://addons.wago.io/addons/details-damage-meter-standalone' },
            { id: 'wa-dbm-c', slug: 'deadly-boss-mods-dbm', name: 'Deadly Boss Mods (DBM) - Classic', author: 'MysticalOS', description: 'Raid & dungeon alerts for Vanilla/Classic.', downloads: 4100000, version: '1.15.0', game_version: 'classic', wago_url: 'https://addons.wago.io/addons/deadly-boss-mods-dbm' },
            { id: 'wa-bigwigs-c', slug: 'bigwigs', name: 'BigWigs Bossmods', author: 'BigWigsMods', description: 'Modular boss encounter warnings.', downloads: 2800000, version: 'v12.1.2', game_version: 'classic', wago_url: 'https://addons.wago.io/addons/bigwigs' },
            { id: 'wa-tomtom', slug: 'tomtom', name: 'TomTom (Classic)', author: 'Cladhaire', description: 'Personal navigation assistant with coordinate waypoints.', downloads: 2100000, version: 'v1.15.1', game_version: 'classic', wago_url: 'https://addons.wago.io/addons/tomtom' },
          ]
        : [
            { id: 'wa-plater', slug: 'plater-nameplates', name: 'Plater Nameplates', author: 'Terciob', description: 'Highly customizable nameplate addon with script and mod support.', downloads: 4500200, version: '11.0.2', game_version: 'retail', wago_url: 'https://addons.wago.io/addons/plater-nameplates' },
            { id: 'wa-mrt', slug: 'method-raid-tools', name: 'Method Raid Tools', author: 'Exorsus', description: 'Raid management tools, cooldown tracking, ready checks, and notes.', downloads: 3200100, version: '11.0.1', game_version: 'retail', wago_url: 'https://addons.wago.io/addons/method-raid-tools' },
            { id: 'wa-details', slug: 'details-damage-meter-standalone', name: 'Details! Damage Meter', author: 'Terciob', description: 'Advanced damage and combat meter with deep analysis tools.', downloads: 7707383, version: '11.0.2', game_version: 'retail', wago_url: 'https://addons.wago.io/addons/details-damage-meter-standalone' },
            { id: 'wa-raiderio', slug: 'raiderio-mythic-plus-raid-progress-and-recruitment', name: 'Raider.IO Mythic Plus & Raid', author: 'RaiderIO', description: 'Inspect mythic plus scores, raid progression, and profiles.', downloads: 6200000, version: 'v20261102', game_version: 'retail', wago_url: 'https://addons.wago.io/addons/raiderio-mythic-plus-raid-progress-and-recruitment' },
          ];

      // A large category (3 pages of 15 different addons, like Wago's own pagination) so the UI's
      // infinite scroll can be exercised for real; the small pools above fit on one page.
      if (String(args?.category || '') === 'combat') {
        const perPage = 15;
        const all = Array.from({ length: 45 }, (_, i) => {
          const n = String(i + 1).padStart(2, '0');
          return {
            id: `wa-combat-${n}`,
            slug: `combat-addon-${n}`,
            name: `Combat Addon ${n}`,
            author: 'Mock Author',
            description: `Mock combat addon number ${n}.`,
            downloads: 1000000 - i * 1000,
            version: '1.0.0',
            game_version: isClassicOrForever ? 'classic' : 'retail',
            wago_url: `https://addons.wago.io/addons/combat-addon-${n}`,
          };
        });
        const start = (page - 1) * perPage;
        return {
          results: all.slice(start, start + perPage),
          total: all.length,
          page,
          has_more: start + perPage < all.length,
        } as T;
      }

      const q = String(args?.query || '').trim().toLowerCase();
      const filtered = q
        ? mockPool.filter((a) => a.name.toLowerCase().includes(q) || a.slug.toLowerCase().includes(q))
        : mockPool;

      return {
        results: page > 2 ? [] : filtered,
        total: filtered.length,
        page,
        has_more: page === 1 && filtered.length > 2,
      } as T;
    }

    case 'cf_browse':
      return {
        data: [
          {
            id: 61284,
            name: 'Details! Damage Meter',
            authors: [{ name: 'Terciob' }],
            summary: 'Definitive damage meter for World of Warcraft.',
            downloadCount: 154000000,
          },
          {
            id: 3358,
            name: 'Deadly Boss Mods (DBM)',
            authors: [{ name: 'MysticalOS' }],
            summary: 'The original and most popular boss mod for raids and dungeons.',
            downloadCount: 420000000,
          },
        ],
        pagination: { totalCount: 2 },
      } as T;

    case 'cf_enrich':
      return {
        id: args.addon_id,
        summary: 'Enriched addon details from CurseForge.',
        screenshots: [
          { url: 'https://media.forgecdn.net/attachments/mock1.png', title: 'Main Interface' },
          { url: 'https://media.forgecdn.net/attachments/mock2.png', title: 'Configuration Panel' },
        ],
      } as T;

    case 'wago_addon':
      return {
        id: args.slug_or_id,
        description: 'Enriched addon description from Wago.',
        screenshots: [
          { url: 'https://media.wago.io/addons/mock1.png', title: 'In-game Display' },
        ],
      } as T;

    case 'app_update_check':
      return {
        status: 'available',
        current_version: '2.0.25',
        update_version: '2.0.25',
        release_notes: '• Modernized Svelte 5 frontend with custom Tokyo Rain theme\n• Enhanced WTF SavedVariables snapshot protection\n• Direct CurseForge & Wago updates with rate-limit fallback',
        published_at: '2026-10-23T00:00:00Z',
        has_update: true,
        download_url: 'https://github.com/krenz444/furphy-addon-manager/releases/download/v2.0.25/FurphyAddonManager-2.0.25-setup.exe',
      } as T;

    case 'app_update_install':
      return null as T;

    case 'app_update_status':
      return {
        status: 'idle',
        current_version: '2.0.25',
        update_version: null,
        release_notes: null,
        published_at: null,
        has_update: false,
      } as T;

    default:
      console.warn(`[MockIPC] Unhandled command: ${cmd}`);
      return undefined as T;
  }
}
