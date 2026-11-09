import { registerMockCommand, registerMockJob, getMockAddons } from '../mockIpc';
import type { IntegrityReport, JobRecord } from '../types';

export function initIntegrityMock(): void {
  registerMockCommand('show_addon_folder', (_cmd, _args) => {
    return null;
  });

  registerMockCommand('integrity_report', (_cmd, args) => {
    const addonId = (args.addon_id as string) || '';
    const addon = getMockAddons().find((a) => a.id === addonId);
    const report: IntegrityReport = {
      addon_id: addonId,
      status: addon?.integrity_status ?? 'clean',
      diffs: [],
    };
    return report;
  });

  registerMockJob('reinstall', (_jobKind, flavour, params) => {
    const job: JobRecord = {
      id: `mock-reinstall-${Date.now()}`,
      kind: 'reinstall',
      flavour,
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

  if (typeof window !== 'undefined') {
    const w = window as unknown as { __furphyMock?: Record<string, unknown> };
    if (w.__furphyMock) {
      w.__furphyMock.setIntegrityStatus = (addonId: string, status: 'clean' | 'modified' | 'missing' | 'unknown') => {
        const target = getMockAddons().find((a) => a.id === addonId);
        if (target) {
          target.integrity_status = status;
        }
      };
    }
  }
}
