import { registerMockCommand, getMockAddons } from '../mockIpc';
import type { AddonGroup } from '../types';
import { getFurphyMock } from './hook';

let mockGroups: AddonGroup[] = [];

function generateGroupId(): string {
  const chars = '0123456789abcdef';
  let hex = '';
  for (let i = 0; i < 12; i++) {
    hex += chars[Math.floor(Math.random() * chars.length)];
  }
  return `grp_${hex}`;
}

export function initGroupsMock(): void {
  const mock = getFurphyMock();
  mock.setMockGroups = (groups: AddonGroup[]) => {
    mockGroups = groups.map((g) => ({ ...g }));
  };
  mock.getMockGroups = () => mockGroups.map((g) => ({ ...g }));

  registerMockCommand('set_favourite', (_cmd, args) => {
    const addonId = (args.addon_id ?? args.addonId) as string;
    const favourite = Boolean(args.favourite);
    const addon = getMockAddons().find((a) => a.id === addonId);
    if (addon) {
      addon.favourite = favourite;
    }
    return null;
  });

  registerMockCommand('list_groups', () => {
    const addons = getMockAddons();
    return mockGroups
      .map((g) => ({
        ...g,
        member_count: addons.filter((a) => a.group_ids && a.group_ids.includes(g.id)).length,
      }))
      .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
  });

  registerMockCommand('create_group', (_cmd, args) => {
    const rawName = (args.name as string) ?? '';
    const trimmed = rawName.trim();
    if (!trimmed) {
      throw 'Enter a name';
    }
    if (trimmed.length > 40) {
      throw 'Group name cannot exceed 40 characters';
    }
    const dup = mockGroups.find((g) => g.name.toLowerCase() === trimmed.toLowerCase());
    if (dup) {
      throw `A group called ${trimmed} already exists`;
    }
    const maxSort = mockGroups.reduce((max, g) => Math.max(max, g.sort_order), -1);
    const newGroup: AddonGroup = {
      id: generateGroupId(),
      name: trimmed,
      sort_order: maxSort + 1,
      member_count: 0,
    };
    mockGroups.push(newGroup);
    return newGroup;
  });

  registerMockCommand('rename_group', (_cmd, args) => {
    const groupId = (args.group_id ?? args.groupId) as string;
    const rawName = (args.name as string) ?? '';
    const trimmed = rawName.trim();
    const group = mockGroups.find((g) => g.id === groupId);
    if (!group) {
      throw 'That group no longer exists';
    }
    if (!trimmed) {
      throw 'Enter a name';
    }
    if (trimmed.length > 40) {
      throw 'Group name cannot exceed 40 characters';
    }
    const dup = mockGroups.find((g) => g.id !== groupId && g.name.toLowerCase() === trimmed.toLowerCase());
    if (dup) {
      throw `A group called ${trimmed} already exists`;
    }
    group.name = trimmed;
    return null;
  });

  registerMockCommand('delete_group', (_cmd, args) => {
    const groupId = (args.group_id ?? args.groupId) as string;
    const index = mockGroups.findIndex((g) => g.id === groupId);
    if (index === -1) {
      throw 'That group no longer exists';
    }
    mockGroups.splice(index, 1);
    for (const addon of getMockAddons()) {
      if (addon.group_ids && addon.group_ids.includes(groupId)) {
        addon.group_ids = addon.group_ids.filter((id) => id !== groupId);
      }
    }
    return null;
  });

  registerMockCommand('set_addon_group', (_cmd, args) => {
    const addonId = (args.addon_id ?? args.addonId) as string;
    const groupId = (args.group_id ?? args.groupId) as string;
    const member = Boolean(args.member);
    const group = mockGroups.find((g) => g.id === groupId);
    if (!group) {
      throw 'That group no longer exists';
    }
    const addon = getMockAddons().find((a) => a.id === addonId);
    if (addon) {
      if (!addon.group_ids) {
        addon.group_ids = [];
      }
      if (member) {
        if (!addon.group_ids.includes(groupId)) {
          addon.group_ids.push(groupId);
        }
      } else {
        addon.group_ids = addon.group_ids.filter((id) => id !== groupId);
      }
    }
    return null;
  });
}
