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

const MOCK_FLAVOURS: Flavour[] = [
  { id: 'retail', folder: '_retail_', label: 'Retail', product: 'wow', installed: true },
  { id: 'classic_era', folder: '_classic_era_', label: 'Classic Era', product: 'wow_classic_era', installed: true },
  { id: 'classic', folder: '_classic_', label: 'Mists Classic', product: 'wow_classic', installed: true },
];

function generateMockAddons(count: number = 200): Addon[] {
  const addons: Addon[] = [
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

  return addons;
}

const mockAddons = generateMockAddons(200);

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

export async function handleMockInvoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  // Artificial micro-delay for realistic UI feedback
  await new Promise((r) => setTimeout(r, 10));

  switch (cmd) {
    case 'get_app_info':
      return {
        name: 'Furphy Addon Manager',
        version: '2.0.6',
        is_dev: false,
        identifier: 'krenzcreative.furphy.addonmanager',
      } as T;

    case 'get_flavours':
      return MOCK_FLAVOURS as T;

    case 'get_addons': {
      const flv = (args.flavour as string) || 'retail';
      return mockAddons.filter((a) => a.flavour === flv) as T;
    }

    case 'get_state': {
      const flv = (args.flavour as string) || 'retail';
      const filtered = mockAddons.filter((a) => a.flavour === flv);
      const updatesCount = filtered.filter((a) => a.update_version && !a.ignore_updates && !a.pinned_file_id).length;
      const state: AppState = {
        addons: filtered,
        flavours: MOCK_FLAVOURS,
        active_flavour: flv,
        freshness: {
          state: updatesCount > 0 ? 'updates_ready' : 'clean',
          checked_at: new Date().toISOString(),
          updates_count: updatesCount,
          last_error: null,
        },
        running_job: null,
        untracked_count: 2,
        is_game_active: false,
        app_info: {
          name: 'Furphy Addon Manager',
          version: '2.0.6',
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

    case 'wago_search':
      return {
        results: [
          {
            id: 'wa-addon-1',
            name: 'Plater Nameplates',
            author: 'Terciob',
            summary: 'Highly customizable nameplate addon with script and mod support.',
            downloads: 4500200,
            version: '11.0.2',
            categories: ['Unit Frames', 'Combat'],
          },
          {
            id: 'wa-addon-2',
            name: 'Method Raid Tools',
            author: 'Exorsus',
            summary: 'Raid management tools, cooldown tracking, ready checks, and notes.',
            downloads: 3200100,
            version: '11.0.1',
            categories: ['Boss Encounters'],
          },
        ],
        total: 2,
      } as T;

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
        current_version: '2.0.6',
        update_version: '2.0.6',
        release_notes: '• Modernized Svelte 5 frontend with custom Tokyo Rain theme\n• Enhanced WTF SavedVariables snapshot protection\n• Direct CurseForge & Wago updates with rate-limit fallback',
        published_at: '2026-10-23T00:00:00Z',
        has_update: true,
        download_url: 'https://github.com/krenz444/furphy-addon-manager/releases/download/v2.0.6/FurphyAddonManager-2.0.6-setup.exe',
      } as T;

    case 'app_update_install':
      return null as T;

    case 'app_update_status':
      return {
        status: 'idle',
        current_version: '2.0.6',
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
