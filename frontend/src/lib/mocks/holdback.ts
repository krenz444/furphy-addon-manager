import { registerMockCommand, getMockAddons } from '../mockIpc';

export function initHoldbackMock(): void {
  registerMockCommand('hold_ignore_for_build', (_cmd, args) => {
    const addonId = args.addon_id as string;
    const target = getMockAddons().find((a) => a.id === addonId);
    if (target) {
      target.held = false;
      target.held_reason = null;
    }
    return null;
  });

  if (typeof window !== 'undefined') {
    const w = window as unknown as { __furphyMock?: Record<string, unknown> };
    if (w.__furphyMock) {
      w.__furphyMock.setHeldCount = (count: number) => {
        const addons = getMockAddons();
        for (let i = 0; i < addons.length; i++) {
          if (i < count) {
            addons[i].held = true;
            addons[i].held_reason = 'Built for newer game version';
          } else {
            addons[i].held = false;
            addons[i].held_reason = null;
          }
        }
      };
    }
  }
}
