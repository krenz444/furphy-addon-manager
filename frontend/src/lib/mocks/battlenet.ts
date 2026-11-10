import { registerMockCommand } from '../mockIpc';
import type { BattlenetInstall } from '../types';
import { getFurphyMock } from './hook';

const DEFAULT_BATTLENET_INSTALLS: BattlenetInstall[] = [
  {
    product: 'wow',
    install_path: 'C:/Program Files (x86)/World of Warcraft',
    flavour: 'retail',
    flavour_folder_exists: true,
    current_path: 'C:/Program Files (x86)/World of Warcraft',
  },
  {
    product: 'wowf',
    install_path: 'C:/Program Files (x86)/World of Warcraft',
    flavour: 'forever',
    flavour_folder_exists: true,
    current_path: 'C:/Program Files (x86)/World of Warcraft',
  },
];

let customBattlenetInstalls: BattlenetInstall[] | null = null;

export function initBattlenetMock(): void {
  const mock = getFurphyMock();
  mock.setMockBattlenet = (list: BattlenetInstall[]) => {
    customBattlenetInstalls = [...list];
  };

  registerMockCommand('detect_battlenet_installs', () => {
    const hook = getFurphyMock();
    if (hook.battlenetError || hook.nextBattlenetError) {
      const err = String(hook.nextBattlenetError || hook.battlenetError);
      hook.nextBattlenetError = null;
      throw err;
    }

    if (customBattlenetInstalls !== null) {
      return [...customBattlenetInstalls];
    }

    return [...DEFAULT_BATTLENET_INSTALLS];
  });
}
