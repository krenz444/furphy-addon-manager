<script lang="ts">
  import type { Addon } from '../../lib/types';

  interface Props {
    addon: Addon;
    onUpdate?: (addon: Addon) => void;
    onViewDetails?: (addon: Addon, tab?: string) => void;
    onTogglePin?: (addon: Addon) => void;
    onToggleIgnore?: (addon: Addon) => void;
    onOpenSource?: (addon: Addon) => void;
    onUninstall?: (addon: Addon) => void;
  }

  let {
    addon,
    onUpdate,
    onViewDetails,
    onTogglePin,
    onToggleIgnore,
    onOpenSource,
    onUninstall,
  }: Props = $props();

  let isOpen = $state(false);
  let menuRef = $state<HTMLDivElement | null>(null);

  function toggleMenu(e: MouseEvent) {
    e.stopPropagation();
    isOpen = !isOpen;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && isOpen) {
      isOpen = false;
    }
  }

  function closeMenu() {
    isOpen = false;
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
