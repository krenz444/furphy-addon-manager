import { registerMockJob, getMockAddons } from '../mockIpc';
import type { Addon, JobRecord } from '../types';
import { getFurphyMock } from './hook';

function parseSourceFileName(source: string): { fileName: string; stem: string } {
  const clean = source.trim().replace(/^"(.*)"$/, '$1');
  const urlOrPath = clean.split('?')[0];
  const fileName = urlOrPath.split(/[/\\]/).pop() || 'addon.zip';
  const stem = fileName.replace(/\.zip$/i, '');
  return { fileName, stem };
}

function parseStem(stem: string): { name: string; version: string | null; primary: string } {
  const match = stem.match(/^([a-zA-Z0-9_]+)[-_.v](\d+(?:\.\d+)*)$/);
  if (match) {
    return { name: match[1], version: match[2], primary: match[1] };
  }
  return { name: stem, version: '1.0.0', primary: stem };
}

export function initZipInstallMock(): void {
  registerMockJob('install-zip', (_jobKind, flavour, params) => {
    const mock = getFurphyMock();
    if (mock.nextZipError) {
      const errMsg = String(mock.nextZipError);
      mock.nextZipError = null;
      const failedJob: JobRecord = {
        id: `mock-job-${Date.now()}`,
        kind: 'install-zip',
        flavour: flavour || 'retail',
        params: JSON.stringify(params || {}),
        state: 'failed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: errMsg,
        results: null,
        reload_needed: false,
        log_path: 'mock/zip.log',
      };
      return failedJob;
    }

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

    const rawSource = (parsedParams.source as string) || '';
    if (!rawSource.trim()) {
      const failedJob: JobRecord = {
        id: `mock-job-${Date.now()}`,
        kind: 'install-zip',
        flavour: flavour || 'retail',
        params: JSON.stringify(params || {}),
        state: 'failed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: 'Enter a path or an https link to a .zip file.',
        results: null,
        reload_needed: false,
        log_path: 'mock/zip.log',
      };
      return failedJob;
    }

    const targetFlavour = flavour || 'retail';
    const { fileName, stem } = parseSourceFileName(rawSource);
    const { name, version, primary } = parseStem(stem);
    const primaryFolder = primary || 'Addon';
    const addonId = `zip:${targetFlavour}:${primaryFolder.toLowerCase()}`;

    const addons = getMockAddons();
    const existingIndex = addons.findIndex(
      (a) => a.id === addonId || (a.flavour === targetFlavour && a.folders.includes(primaryFolder))
    );
    const replaced = existingIndex !== -1;
    const folders =
      replaced && addons[existingIndex].folders.length > 0
        ? addons[existingIndex].folders
        : [primaryFolder];

    if (replaced) {
      const existing = addons[existingIndex];
      existing.version = version;
      existing.installed_at = new Date().toISOString();
      existing.source = 'zip';
      existing.check_status = 'up_to_date';
      existing.file_name = fileName;
    } else {
      const newAddon: Addon = {
        id: addonId,
        flavour: targetFlavour,
        name,
        author: 'Zip Package',
        source: 'zip',
        version,
        project_id: null,
        file_id: null,
        file_name: fileName,
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
        auto_update: false,
        integrity_status: 'clean',
        favourite: false,
        group_ids: [],
        released_at: new Date().toISOString(),
        tukui_slug: null,
      };
      addons.push(newAddon);
    }

    const report = {
      addon_id: addonId,
      name,
      version,
      folders,
      replaced,
    };

    const completedJob: JobRecord = {
      id: `mock-job-${Date.now()}`,
      kind: 'install-zip',
      flavour: targetFlavour,
      params: JSON.stringify(params || {}),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: JSON.stringify(report),
      reload_needed: true,
      log_path: 'mock/zip.log',
    };
    return completedJob;
  });
}
