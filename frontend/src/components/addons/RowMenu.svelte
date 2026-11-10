<script lang="ts">
  import type { Addon, AddonGroup } from '../../lib/types';
  import ChannelSubmenu from './ChannelSubmenu.svelte';

  interface Props {
    addon: Addon;
    groups?: AddonGroup[];
    groupIds?: string[];
    onToggleGroup?: (groupId: string, member: boolean) => void;
    onNewGroup?: () => void;
    onUpdate?: (addon: Addon) => void;
    onInstallDeps?: (addon: Addon) => void;
    onIgnoreDeps?: (addon: Addon) => void;
    onViewDetails?: (addon: Addon, tab?: string) => void;
    onTogglePin?: (addon: Addon) => void;
    onToggleIgnore?: (addon: Addon) => void;
    onRollback?: (addon: Addon) => void;
    onSwitchSource?: (addon: Addon) => void;
    onOpenSource?: (addon: Addon) => void;
    onUninstall?: (addon: Addon) => void;
    onSetChannel?: (addon: Addon, channel: number) => void;
    onToggleAutoUpdate?: (addon: Addon) => void;
    onShowFolder?: (addon: Addon) => void;
    onReinstall?: (addon: Addon) => void;
  }

  let {
    addon,
    groups = [],
    groupIds,
    onToggleGroup,
    onNewGroup,
    onUpdate,
    onInstallDeps,
    onIgnoreDeps,
    onViewDetails,
    onTogglePin,
    onToggleIgnore,
    onRollback,
    onSwitchSource,
    onOpenSource,
    onUninstall,
    onSetChannel,
    onToggleAutoUpdate,
    onShowFolder,
    onReinstall,
  }: Props = $props();

  let isOpen = $state(false);
  let showChannelSubmenu = $state(false);
  let showGroupSubmenu = $state(false);
  let menuRef = $state<HTMLDivElement | null>(null);
  let channelBtnRef = $state<HTMLButtonElement | null>(null);
  let groupBtnRef = $state<HTMLButtonElement | null>(null);

  let activeGroupIds = $derived(groupIds !== undefined ? groupIds : (addon.group_ids ?? []));

  function toggleMenu(e: MouseEvent) {
    e.stopPropagation();
    isOpen = !isOpen;
    if (!isOpen) {
      showChannelSubmenu = false;
      showGroupSubmenu = false;
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && isOpen) {
      if (showGroupSubmenu) {
        showGroupSubmenu = false;
        groupBtnRef?.focus();
        e.stopPropagation();
        return;
      }
      if (showChannelSubmenu) {
        showChannelSubmenu = false;
        channelBtnRef?.focus();
        e.stopPropagation();
        return;
      }
      closeMenu();
    }
  }

  function closeMenu() {
    isOpen = false;
    showChannelSubmenu = false;
    showGroupSubmenu = false;
  }

  $effect(() => {
    function handleDocClick(e: MouseEvent) {
      if (menuRef && !menuRef.contains(e.target as Node)) {
        closeMenu();
      }
    }
    if (isOpen) {
      document.addEventListener('click', handleDocClick);
      document.addEventListener('keydown', handleKeydown);
    }
    return () => {
      document.removeEventListener('click', handleDocClick);
      document.removeEventListener('keydown', handleKeydown);
    };
  });
</script>

<div class="menu-container" bind:this={menuRef}>
  <button
    type="button"
    class="menu-trigger-btn"
    aria-label="Actions for {addon.name || addon.id}"
    aria-haspopup="true"
    aria-expanded={isOpen}
    onclick={toggleMenu}
  >
    <svg viewBox="0 0 16 16" width="16" height="16" fill="currentColor">
      <circle cx="8" cy="3" r="1.5" />
      <circle cx="8" cy="8" r="1.5" />
      <circle cx="8" cy="13" r="1.5" />
    </svg>
  </button>

  {#if isOpen}
    <div class="menu-dropdown" role="menu">
      {#if addon.missing_deps && addon.missing_deps.length > 0 && onInstallDeps}
        <button
          type="button"
          class="menu-item item-warning"
          role="menuitem"
          onclick={(e) => { e.stopPropagation(); closeMenu(); onInstallDeps?.(addon); }}
        >
          Install missing dependencies ({addon.missing_deps.length})
        </button>
      {/if}

      {#if addon.missing_deps && addon.missing_deps.length > 0 && onIgnoreDeps}
        <button
          type="button"
          class="menu-item"
          role="menuitem"
          onclick={(e) => { e.stopPropagation(); closeMenu(); onIgnoreDeps?.(addon); }}
        >
          Ignore missing dependencies
        </button>
      {/if}

      {#if addon.update_version && onUpdate}
        <button
          type="button"
          class="menu-item item-accent"
          role="menuitem"
          onclick={(e) => { e.stopPropagation(); closeMenu(); onUpdate?.(addon); }}
        >
          Update now
        </button>
      {/if}

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onViewDetails?.(addon, 'versions'); }}
      >
        View versions
      </button>

      <div class="submenu-container">
        <button
          type="button"
          class="menu-item has-submenu"
          role="menuitem"
          aria-haspopup="true"
          aria-expanded={showChannelSubmenu}
          bind:this={channelBtnRef}
          onclick={(e) => {
            e.stopPropagation();
            showGroupSubmenu = false;
            showChannelSubmenu = !showChannelSubmenu;
          }}
        >
          <span>Release channel</span>
          <span class="submenu-arrow">◀</span>
        </button>
        {#if showChannelSubmenu}
          <div class="submenu-popover">
            <ChannelSubmenu
              selectedChannel={addon.release_type ?? 1}
              onSelectChannel={(ch) => {
                showChannelSubmenu = false;
                onSetChannel?.(addon, ch);
                closeMenu();
              }}
              onClose={() => {
                showChannelSubmenu = false;
                channelBtnRef?.focus();
              }}
            />
          </div>
        {/if}
      </div>

      <div class="submenu-container">
        <button
          type="button"
          class="menu-item has-submenu"
          role="menuitem"
          data-testid="row-menu-groups"
          aria-haspopup="true"
          aria-expanded={showGroupSubmenu}
          bind:this={groupBtnRef}
          onclick={(e) => {
            e.stopPropagation();
            showChannelSubmenu = false;
            showGroupSubmenu = !showGroupSubmenu;
          }}
          onkeydown={(e) => {
            if (e.key === 'ArrowLeft') {
              e.preventDefault();
              showGroupSubmenu = true;
            }
          }}
        >
          <span>Add to group</span>
          <span class="submenu-arrow">◀</span>
        </button>
        {#if showGroupSubmenu}
          <div
            class="submenu-popover group-submenu-popover"
            role="menu"
            tabindex="-1"
            onkeydown={(e) => {
              if (e.key === 'ArrowRight') {
                e.preventDefault();
                showGroupSubmenu = false;
                groupBtnRef?.focus();
              }
            }}
          >
            {#each groups as grp (grp.id)}
              {@const isMember = activeGroupIds.includes(grp.id)}
              <button
                type="button"
                class="menu-item group-option"
                role="menuitemcheckbox"
                data-testid="group-opt-{grp.id}"
                aria-checked={isMember}
                onclick={(e) => {
                  e.stopPropagation();
                  closeMenu();
                  onToggleGroup?.(grp.id, !isMember);
                }}
              >
                <span class="checkbox-indicator">{isMember ? '✓ ' : '  '}</span>
                <span class="group-name">{grp.name}</span>
              </button>
            {/each}
            {#if groups.length > 0}
              <div class="menu-divider" role="separator"></div>
            {/if}
            <button
              type="button"
              class="menu-item"
              role="menuitem"
              data-testid="group-new"
              onclick={(e) => {
                e.stopPropagation();
                closeMenu();
                onNewGroup?.();
              }}
            >
              New group...
            </button>
          </div>
        {/if}
      </div>

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => {
          e.stopPropagation();
          closeMenu();
          onToggleAutoUpdate?.(addon);
        }}
      >
        {addon.auto_update ?? true ? '✓ Install automatically' : 'Install automatically'}
      </button>

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onTogglePin?.(addon); }}
      >
        {addon.pinned_file_id ? 'Unpin version' : 'Pin to this version'}
      </button>

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onToggleIgnore?.(addon); }}
      >
        {addon.ignore_updates ? 'Stop ignoring updates' : 'Ignore updates'}
      </button>

      {#if onRollback}
        <button
          type="button"
          class="menu-item"
          role="menuitem"
          onclick={(e) => { e.stopPropagation(); closeMenu(); onRollback?.(addon); }}
        >
          Roll back…
        </button>
      {/if}

      {#if onSwitchSource && (addon.source === 'curseforge' || addon.source === 'wago')}
        <button
          type="button"
          class="menu-item"
          role="menuitem"
          onclick={(e) => { e.stopPropagation(); closeMenu(); onSwitchSource?.(addon); }}
        >
          Switch to {addon.source === 'curseforge' ? 'Wago' : 'CurseForge'}…
        </button>
      {/if}

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onViewDetails?.(addon, 'saved-settings'); }}
      >
        Saved settings (WTF)
      </button>

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onOpenSource?.(addon); }}
      >
        Open on {addon.source === 'wago' ? 'Wago' : addon.source === 'github' ? 'GitHub' : 'CurseForge'}
      </button>

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onShowFolder?.(addon); }}
      >
        Show folder
      </button>

      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onReinstall?.(addon); }}
      >
        Reinstall
      </button>

      <div class="menu-divider" role="separator"></div>

      <button
        type="button"
        class="menu-item item-danger"
        role="menuitem"
        onclick={(e) => { e.stopPropagation(); closeMenu(); onUninstall?.(addon); }}
      >
        Uninstall…
      </button>
    </div>
  {/if}
</div>

<style>
  .menu-container {
    position: relative;
    display: inline-block;
  }

  .menu-trigger-btn {
    background: transparent;
    border: none;
    color: var(--text-muted);
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: background var(--fast), color var(--fast);
  }

  .menu-trigger-btn:hover {
    background: var(--bg-3);
    color: var(--text);
  }

  .menu-trigger-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .menu-dropdown {
    position: absolute;
    right: 0;
    top: 100%;
    margin-top: 4px;
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 4px;
    min-width: 190px;
    z-index: 1000;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .submenu-container {
    position: relative;
    width: 100%;
  }

  .has-submenu {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .submenu-arrow {
    font-size: 0.65rem;
    color: var(--text-muted);
  }

  /* The row menu sits at the right edge of the window, so submenus open to the left. */
  .submenu-popover {
    position: absolute;
    right: 100%;
    top: 0;
    margin-right: 4px;
    z-index: 1001;
  }

  .group-submenu-popover {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 4px;
    min-width: 170px;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .group-option {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .checkbox-indicator {
    width: 14px;
    display: inline-block;
    color: var(--accent);
    font-weight: 600;
    text-align: center;
    flex-shrink: 0;
  }

  .group-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .menu-item {
    background: transparent;
    border: none;
    color: var(--text);
    text-align: left;
    padding: 7px 10px;
    font-size: 12.5px;
    border-radius: calc(var(--radius) - 3px);
    cursor: pointer;
    transition: background var(--fast), color var(--fast);
  }

  .menu-item:hover {
    background: var(--bg-2);
    color: var(--text);
  }

  .menu-item:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: -1px;
  }

  .item-warning {
    color: var(--warning);
    font-weight: 600;
  }

  .item-warning:hover {
    background: var(--warning-tint);
  }

  .item-accent {
    color: var(--accent);
    font-weight: 600;
  }

  .item-accent:hover {
    background: var(--accent-tint);
  }

  .item-danger {
    color: var(--danger);
  }

  .item-danger:hover {
    background: var(--danger-tint);
  }

  .menu-divider {
    height: 1px;
    background: var(--border-soft);
    margin: 4px 0;
  }
</style>
