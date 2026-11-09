import { registerMockCommand } from '../mockIpc';
import type { ActivityRecord } from '../types';

let mockActivityList: ActivityRecord[] = [
  {
    id: 'act-1',
    ts: new Date().toISOString(),
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
];

export function initActivityMock(): void {
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
    const w = window as unknown as { __furphyMock?: Record<string, unknown> };
    if (w.__furphyMock) {
      w.__furphyMock.addMockActivity = (record: ActivityRecord) => {
        mockActivityList.unshift(record);
      };
      w.__furphyMock.clearMockActivity = () => {
        mockActivityList = [];
      };
    }
  }
}
