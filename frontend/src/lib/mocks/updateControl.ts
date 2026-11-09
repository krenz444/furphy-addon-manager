import { registerMockCommand, getMockAddons } from '../mockIpc';

const mockUpdateModes: Record<string, 'auto' | 'notify'> = {
  retail: 'auto',
  classic_era: 'auto',
  classic: 'auto',
  forever: 'auto',
};

export function initUpdateControlMock(): void {
  registerMockCommand('set_release_channel', (_cmd, args) => {
    const addonId = (args.addon_id ?? args.addonId) as string;
    const releaseType = Number(args.release_type ?? args.releaseType);
    const target = getMockAddons().find((a) => a.id === addonId);
    if (target) {
      target.release_type = releaseType;
    }
    return null;
  });

  registerMockCommand('set_auto_update', (_cmd, args) => {
    const addonId = (args.addon_id ?? args.addonId) as string;
    const autoUpdate = Boolean(args.auto_update ?? args.autoUpdate);
    const target = getMockAddons().find((a) => a.id === addonId);
    if (target) {
      target.auto_update = autoUpdate;
    }
    return null;
  });

  registerMockCommand('set_update_mode', (_cmd, args) => {
    const flavour = (args.flavour as string) || 'retail';
    const mode = ((args.update_mode ?? args.updateMode) as 'auto' | 'notify') || 'auto';
    mockUpdateModes[flavour] = mode;
    return null;
  });

  registerMockCommand('get_update_modes', () => {
    return { ...mockUpdateModes };
  });

  if (typeof window !== 'undefined') {
    const w = window as unknown as { __furphyMock?: Record<string, unknown> };
    if (!w.__furphyMock) {
      w.__furphyMock = {};
    }
    w.__furphyMock.setUpdateMode = (flavour: string, mode: 'auto' | 'notify') => {
      mockUpdateModes[flavour] = mode;
    };
    w.__furphyMock.getUpdateModes = () => ({ ...mockUpdateModes });
  }
}
