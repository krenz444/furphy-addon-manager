import { registerMockJob, getMockAddons } from '../mockIpc';
import type { CopyItemResult, JobRecord } from '../types';
import { getFurphyMock } from './hook';

export function initCopyAddonsMock(): void {
  const mock = getFurphyMock();
  mock.setCopyPresent = (ids: string[]) => {
    mock.copyPresent = [...ids];
  };
  mock.setCopyFailMessage = (msg: string | null) => {
    mock.copyFailMessage = msg;
  };

  registerMockJob('copy-addons', (_jobKind, flavour, params) => {
    const hook = getFurphyMock();
    if (hook.nextCopyJobError || hook.copyJobError) {
      const errMsg = String(hook.nextCopyJobError || hook.copyJobError);
      hook.nextCopyJobError = null;
      const failedJob: JobRecord = {
        id: `mock-job-${Date.now()}`,
        kind: 'copy-addons',
        flavour: flavour || 'retail',
        params: JSON.stringify(params || {}),
        state: 'failed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: errMsg,
        results: null,
        reload_needed: false,
        log_path: 'mock/copy.log',
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

    const targetFlavour = (parsedParams.target_flavour ?? parsedParams.targetFlavour ?? 'forever') as string;
    const addonIds = ((parsedParams.addon_ids ?? parsedParams.addonIds ?? []) as string[]);

    const copyPresent = (hook.copyPresent as string[] | undefined) || [];
    const copyFailMessage = hook.copyFailMessage;

    const allAddons = getMockAddons();
    const items: CopyItemResult[] = [];

    for (const id of addonIds) {
      const addon = allAddons.find((a) => a.id === id);
      const name = addon?.name || id;

      if (copyPresent.includes(id)) {
        items.push({
          addon_id: id,
          name,
          status: 'skipped',
          message: `Already in ${targetFlavour}`,
        });
        continue;
      }

      let failureText: string | null = null;
      if (typeof copyFailMessage === 'string' && copyFailMessage) {
        failureText = copyFailMessage;
      } else if (copyFailMessage && typeof copyFailMessage === 'object') {
        failureText = (copyFailMessage as Record<string, string>)[id] || null;
      }

      if (failureText) {
        items.push({
          addon_id: id,
          name,
          status: 'failed',
          message: failureText,
        });
        continue;
      }

      items.push({
        addon_id: id,
        name,
        status: 'installed',
        message: `Installed to ${targetFlavour}`,
      });

      if (addon) {
        const targetId = `${addon.id}-${targetFlavour}`;
        const alreadyInTarget = allAddons.some(
          (a) => a.flavour === targetFlavour && (a.id === targetId || a.name === addon.name)
        );
        if (!alreadyInTarget) {
          allAddons.push({
            ...addon,
            id: targetId,
            flavour: targetFlavour,
            installed_at: new Date().toISOString(),
          });
        }
      }
    }

    const anyInstalled = items.some((it) => it.status === 'installed');
    const job: JobRecord = {
      id: `mock-job-${Date.now()}`,
      kind: 'copy-addons',
      flavour: flavour || 'retail',
      params: JSON.stringify(params || {}),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: JSON.stringify({ items }),
      reload_needed: anyInstalled,
      log_path: 'mock/copy.log',
    };
    return job;
  });
}
