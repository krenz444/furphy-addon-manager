import { registerMockCommand } from '../mockIpc';
import type { ActivityRecord } from '../types';

export function createDefaultActivities(): ActivityRecord[] {
  const now = Date.now();
  const ONE_DAY = 24 * 60 * 60 * 1000;
  return [
    {
      id: 'act-1',
      ts: new Date(now - 1000 * 60 * 2).toISOString(),
      flavour: 'retail',
      addon_id: 'details',
      name: 'Details! Damage Meter',
      kind: 'updated',
      from_version: '11.0.2.12840',
      to_version: '11.0.2.12900',
      source: 'curseforge',
      job_id: 'job-1',
      error: null,
    },
    {
      id: 'act-2',
      ts: new Date(now - ONE_DAY).toISOString(),
      flavour: 'retail',
      addon_id: 'weakauras',
      name: 'WeakAuras',
      kind: 'installed',
      from_version: null,
      to_version: '5.18.3',
      source: 'wago',
      job_id: 'job-2',
      error: null,
    },
    {
      id: 'act-3',
      ts: new Date(now - ONE_DAY * 3).toISOString(),
      flavour: 'classic_era',
      addon_id: 'plater',
      name: 'Plater Nameplates',
      kind: 'removed',
      from_version: '11.0.2.610',
      to_version: null,
      source: 'curseforge',
      job_id: 'job-3',
      error: null,
    },
  ];
}

let mockActivityList: ActivityRecord[] = createDefaultActivities();

export function initActivityMock(): void {
  mockActivityList = createDefaultActivities();

  registerMockCommand('list_activity', (_cmd, args) => {
    const flavour = args.flavour as string | undefined;
    if (flavour) {
      return mockActivityList.filter((a) => a.flavour === flavour);
    }
    return [...mockActivityList];
  });

  registerMockCommand('clear_activity', (_cmd, args) => {
    const flavour = args.flavour as string | undefined;
    if (flavour) {
      mockActivityList = mockActivityList.filter((a) => a.flavour !== flavour);
    } else {
      mockActivityList = [];
    }
    return null;
  });

  if (typeof window !== 'undefined') {
    const attachHooks = (target: Record<string, unknown>) => {
      target.setMockActivities = (records: ActivityRecord[]) => {
        mockActivityList = [...records];
      };
      target.clearMockActivities = () => {
        mockActivityList = [];
      };
      target.addMockActivity = (record: ActivityRecord) => {
        mockActivityList.unshift(record);
      };
      target.clearMockActivity = () => {
        mockActivityList = [];
      };
    };

    const win = window as unknown as { __furphyMock?: Record<string, unknown> };
    if (win.__furphyMock) {
      attachHooks(win.__furphyMock);
    }
  }
}
