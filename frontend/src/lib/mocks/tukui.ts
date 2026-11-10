import { registerMockCommand, registerMockJob, getMockAddons } from '../mockIpc';
import type { TukuiAddon, Addon, JobRecord } from '../types';
import { getFurphyMock } from './hook';

const DEFAULT_TUKUI_ADDONS: Array<Omit<TukuiAddon, 'compatible' | 'reason' | 'installed'>> = [
  {
    slug: 'elvui',
    name: 'ElvUI',
    author: 'Elv',
    version: '13.78',
    last_update: '2026-11-08',
    supported_patches: ['12.1.5', '1.60.1', '5.5.4', '1.15.9', '2.5.6'],
    summary: 'A complete User Interface replacement addon for World of Warcraft.',
    web_url: 'https://www.tukui.org/welcome.php',
  },
  {
    slug: 'tukui',
    name: 'Tukui',
    author: 'Tukz',
    version: '20.35',
    last_update: '2026-11-03',
    supported_patches: ['11.1.7', '5.5.0', '1.15.7'],
    summary: 'A minimalist World of Warcraft user interface.',
    web_url: 'https://www.tukui.org/welcome.php',
  },
];

let customTukuiList: TukuiAddon[] | null = null;

function getVersionPrefixFor(flavourId: string): string | null {
  switch (flavourId) {
    case 'retail':
    case 'ptr':
    case 'xptr':
    case 'beta':
      return '12.';
    case 'forever':
      return '1.60.';
    case 'classic_era':
    case 'classic_era_ptr':
      return '1.15.';
    case 'classic':
    case 'classic_ptr':
    case 'classic_beta':
    case 'anniversary':
      return '5.5.';
    default:
      return null;
  }
}

function getFlavourLabel(flavourId: string): string {
  switch (flavourId) {
    case 'retail':
      return 'Retail';
    case 'forever':
      return 'WoW Forever';
    case 'classic_era':
      return 'Classic Era';
    case 'classic':
      return 'Mists Classic';
    case 'anniversary':
      return 'Anniversary';
    default:
      return flavourId;
  }
}

function tukuiSupports(addon: { supported_patches: string[] }, versionPrefix: string | null): boolean {
  if (!versionPrefix) return true;
  return addon.supported_patches.some((p) => p.startsWith(versionPrefix));
}

function tukuiUnavailableReason(
  addon: { supported_patches: string[] },
  eraLabel: string,
  versionPrefix: string | null
): string | null {
  if (tukuiSupports(addon, versionPrefix)) return null;
  const patches = addon.supported_patches.join(', ');
  const prefix = versionPrefix ? `${versionPrefix}x` : 'unknown';
  return `Tukui lists ${patches} for this addon, not ${prefix}, the game version of ${eraLabel}.`;
}

export function initTukuiMock(): void {
  const mock = getFurphyMock();
  mock.setMockTukui = (list: TukuiAddon[]) => {
    customTukuiList = [...list];
  };

  registerMockCommand('tukui_addons', (_cmd, args) => {
    const hook = getFurphyMock();
    if (hook.tukuiError || hook.nextTukuiError) {
      const err = String(hook.nextTukuiError || hook.tukuiError);
      hook.nextTukuiError = null;
      throw err;
    }

    const flavour = (args.flavour as string) || null;
    const baseList = customTukuiList ?? DEFAULT_TUKUI_ADDONS;
    const prefix = flavour ? getVersionPrefixFor(flavour) : null;
    const eraLabel = flavour ? getFlavourLabel(flavour) : '';
    const addons = getMockAddons();

    return baseList.map((item) => {
      const compatible = flavour ? tukuiSupports(item, prefix) : true;
      const reason = flavour ? tukuiUnavailableReason(item, eraLabel, prefix) : null;
      const installed = addons.some(
        (a) =>
          (!flavour || a.flavour === flavour) &&
          (a.tukui_slug === item.slug || a.id === `tukui:${flavour}:${item.slug}`)
      );
      return {
        slug: item.slug,
        name: item.name,
        author: item.author,
        version: item.version,
        last_update: item.last_update,
        supported_patches: [...item.supported_patches],
        summary: item.summary,
        web_url: item.web_url,
        compatible,
        reason,
        installed,
      };
    });
  });

  registerMockJob('add', (_jobKind, flavour, params) => {
    let parsedParams: Record<string, unknown> = {};
    if (typeof params === 'string') {
      try {
        parsedParams = JSON.parse(params);
      } catch {
        parsedParams = {};
      }
    } else if (params && typeof params === 'object') {
      parsedParams = params;
    }

    const target = (parsedParams.target as string) || '';
    const hook = getFurphyMock();
    const targetFlavour = flavour || 'retail';

    if (target.startsWith('tukui:')) {
      const slug = target.slice('tukui:'.length).trim().toLowerCase();
      const baseList = customTukuiList ?? DEFAULT_TUKUI_ADDONS;
      const item = baseList.find((t) => t.slug === slug);
      if (!item) {
        return {
          id: `mock-job-${Date.now()}`,
          kind: 'add',
          flavour: targetFlavour,
          params: JSON.stringify(params || {}),
          state: 'failed',
          started_at: new Date().toISOString(),
          finished_at: new Date().toISOString(),
          error: `Tukui does not list an addon called ${slug}`,
          results: null,
          reload_needed: false,
          log_path: 'mock/sync.log',
        };
      }

      const prefix = getVersionPrefixFor(targetFlavour);
      const eraLabel = getFlavourLabel(targetFlavour);
      if (!tukuiSupports(item, prefix)) {
        const reason = tukuiUnavailableReason(item, eraLabel, prefix) || 'Incompatible game version';
        return {
          id: `mock-job-${Date.now()}`,
          kind: 'add',
          flavour: targetFlavour,
          params: JSON.stringify(params || {}),
          state: 'failed',
          started_at: new Date().toISOString(),
          finished_at: new Date().toISOString(),
          error: reason,
          results: null,
          reload_needed: false,
          log_path: 'mock/sync.log',
        };
      }

      const addonId = `tukui:${targetFlavour}:${slug}`;
      const folders = slug === 'elvui' ? ['ElvUI', 'ElvUI_Libraries', 'ElvUI_Options'] : ['Tukui'];
      const addons = getMockAddons();
      const existing = addons.find(
        (a) => a.id === addonId || (a.flavour === targetFlavour && a.tukui_slug === slug)
      );

      if (existing) {
        existing.version = item.version;
        existing.source = 'tukui';
        existing.tukui_slug = slug;
        existing.installed_at = new Date().toISOString();
        existing.check_status = 'up_to_date';
      } else {
        const newAddon: Addon = {
          id: addonId,
          flavour: targetFlavour,
          name: item.name,
          author: item.author,
          source: 'tukui',
          version: item.version,
          project_id: null,
          file_id: item.version,
          file_name: `${slug}-${item.version}.zip`,
          folders,
          installed_at: new Date().toISOString(),
          adopted: false,
          ignore_updates: false,
          pinned_file_id: null,
          release_type: 1,
          update_version: null,
          update_file_id: null,
          check_status: 'up_to_date',
          is_old_patch: false,
          wago_slug: null,
          repo: null,
          held: false,
          held_reason: null,
          auto_update: true,
          integrity_status: 'clean',
          favourite: false,
          group_ids: [],
          released_at: item.last_update ? new Date(item.last_update).toISOString() : new Date().toISOString(),
          tukui_slug: slug,
        };
        addons.push(newAddon);
      }

      return {
        id: `mock-job-${Date.now()}`,
        kind: 'add',
        flavour: targetFlavour,
        params: JSON.stringify(params || {}),
        state: 'completed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: null,
        results: JSON.stringify([{ flavour: targetFlavour, updated: [item.name], failed: [] }]),
        reload_needed: true,
        log_path: 'mock/sync.log',
      };
    }

    const failure = typeof hook.nextAddError === 'string' ? hook.nextAddError : '';
    if (failure) {
      hook.nextAddError = '';
      return {
        id: `mock-job-${Date.now()}`,
        kind: 'add',
        flavour: targetFlavour,
        params: JSON.stringify(params || {}),
        state: 'failed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: failure,
        results: JSON.stringify([{ flavour: targetFlavour, updated: [], failed: [{ name: 'Addon', error: failure }] }]),
        reload_needed: false,
        log_path: 'mock/sync.log',
      };
    }

    return {
      id: `mock-job-${Date.now()}`,
      kind: 'add',
      flavour: targetFlavour,
      params: JSON.stringify(params || {}),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: JSON.stringify([{ flavour: targetFlavour, updated: ['Details! Damage Meter'], failed: [] }]),
      reload_needed: false,
      log_path: 'mock/sync.log',
    };
  });
}
