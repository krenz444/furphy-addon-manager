import { registerMockCommand, registerMockJob } from '../mockIpc';
import type { WholeWtfBackup, WtfRestorePreview, JobRecord } from '../types';

let mockBackups: WholeWtfBackup[] = [
  {
    id: 'wtf-backup-1',
    flavour: 'retail',
    created_at: new Date().toISOString(),
    path: 'C:/mock/backups/retail_wtf_1.zip',
    file_count: 42,
    total_bytes: 1048576,
    note: 'Manual backup',
  },
];

export function initWtfFullMock(): void {
  registerMockCommand('wtf_backups_list', (_cmd, args) => {
    const flavour = args.flavour as string;
    return mockBackups.filter((b) => !flavour || b.flavour === flavour);
  });

  registerMockCommand('wtf_restore_preview', (_cmd, args) => {
    const backupId = args.backup_id as string;
    const backup = mockBackups.find((b) => b.id === backupId);
    const preview: WtfRestorePreview = {
      backup_id: backupId,
      flavour: backup?.flavour ?? 'retail',
      created_at: backup?.created_at ?? new Date().toISOString(),
      file_count: backup?.file_count ?? 42,
      total_bytes: backup?.total_bytes ?? 1048576,
      live_file_count: 40,
      live_total_bytes: 1000000,
      warning: null,
    };
    return preview;
  });

  registerMockCommand('wtf_backup_delete', (_cmd, args) => {
    const backupId = args.backup_id as string;
    mockBackups = mockBackups.filter((b) => b.id !== backupId);
    return null;
  });

  registerMockJob('backup-wtf', (_jobKind, flavour, params) => {
    const newBackup: WholeWtfBackup = {
      id: `wtf-backup-${Date.now()}`,
      flavour: flavour || 'retail',
      created_at: new Date().toISOString(),
      path: `C:/mock/backups/${flavour || 'retail'}_wtf.zip`,
      file_count: 10,
      total_bytes: 512000,
      note: 'Backup',
    };
    mockBackups.unshift(newBackup);
    const job: JobRecord = {
      id: `mock-job-${Date.now()}`,
      kind: 'backup-wtf',
      flavour,
      params: JSON.stringify(params),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: null,
      reload_needed: false,
      log_path: 'mock/wtf.log',
    };
    return job;
  });

  registerMockJob('restore-wtf-all', (_jobKind, flavour, params) => {
    const job: JobRecord = {
      id: `mock-restore-${Date.now()}`,
      kind: 'restore-wtf-all',
      flavour,
      params: JSON.stringify(params),
      state: 'completed',
      started_at: new Date().toISOString(),
      finished_at: new Date().toISOString(),
      error: null,
      results: null,
      reload_needed: false,
      log_path: 'mock/restore.log',
    };
    return job;
  });

  if (typeof window !== 'undefined') {
    const w = window as unknown as { __furphyMock?: Record<string, unknown> };
    if (w.__furphyMock) {
      w.__furphyMock.setMockBackups = (backups: WholeWtfBackup[]) => {
        mockBackups = [...backups];
      };
    }
  }
}
