<script lang="ts">
  import type { Flavour, Freshness, AppInfo } from '../../lib/types';
  import FreshnessHeadline from './FreshnessHeadline.svelte';

  interface Props {
    activeView: 'my_addons' | 'get_addons' | 'not_built_for_patch' | 'settings';
    activeFlavour: string;
    flavours: Flavour[];
    freshness: Freshness | null;
    updatesCount: number;
    notBuiltCount: number;
    isGameActive: boolean;
    appInfo: AppInfo | null;
    onSelectView: (view: 'my_addons' | 'get_addons' | 'not_built_for_patch' | 'settings') => void;
    onSelectFlavour: (flavour: string) => void;
    onCheckNow: () => void;
    onUpdateAll: () => void;
  }

  let {
    activeView,
    activeFlavour,
    flavours,
    freshness,
    updatesCount,
    notBuiltCount,
    isGameActive,
    appInfo,
    onSelectView,
    onSelectFlavour,
    onCheckNow,
    onUpdateAll,
  }: Props = $props();
</script>

<aside class="app-sidebar" aria-label="Main Navigation">
  <div class="sidebar-header">
    <div class="brand">
      <svg class="brand-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
      </svg>
      <div class="brand-text">
        <div class="brand-title-row">
          <span class="brand-name">{appInfo?.name ?? 'Furphy'}</span>
          {#if appInfo?.is_dev}
            <span class="dev-tag">DEV</span>
          {/if}
        </div>
        <span class="version-label">v{appInfo?.version ?? '2.0.0'}</span>
      </div>
    </div>
  </div>

  {#if flavours && flavours.length > 1}
    <div class="flavour-section">
      <div class="section-label">Game Version</div>
      <div class="flavour-list" role="tablist">
        {#each flavours as fl (fl.id)}
          <button
            type="button"
            role="tab"
            aria-selected={activeFlavour === fl.id}
            class="flavour-btn"
            class:active={activeFlavour === fl.id}
            onclick={() => onSelectFlavour(fl.id)}
          >
            <span class="flavour-label">{fl.label}</span>
            <span class="flavour-folder">{fl.folder}</span>
          </button>
        {/each}
      </div>
    </div>
  {/if}

  <div class="freshness-box">
    <FreshnessHeadline
      {freshness}
      {onCheckNow}
      {onUpdateAll}
    />
  </div>

  <nav class="sidebar-nav">
    <button
      type="button"
      class="nav-item"
      class:active={activeView === 'my_addons'}
      onclick={() => onSelectView('my_addons')}
    >
      <span class="nav-icon">📦</span>
      <span class="nav-text">My Addons</span>
      {#if updatesCount > 0}
        <span class="nav-badge badge-accent">{updatesCount}</span>
      {/if}
    </button>

    <button
      type="button"
      class="nav-item"
      class:active={activeView === 'get_addons'}
      onclick={() => onSelectView('get_addons')}
    >
      <span class="nav-icon">🔍</span>
      <span class="nav-text">Get Addons</span>
    </button>

    <button
      type="button"
      class="nav-item"
      class:active={activeView === 'not_built_for_patch'}
      onclick={() => onSelectView('not_built_for_patch')}
    >
      <span class="nav-icon">⚠️</span>
      <span class="nav-text">Not Built for Patch</span>
      {#if notBuiltCount > 0}
        <span class="nav-badge badge-warning">{notBuiltCount}</span>
      {/if}
    </button>

    <button
      type="button"
      class="nav-item"
      class:active={activeView === 'settings'}
      onclick={() => onSelectView('settings')}
    >
      <span class="nav-icon">⚙️</span>
      <span class="nav-text">Settings</span>
    </button>
  </nav>

  <div class="sidebar-footer">
    {#if isGameActive}
      <div class="game-active-badge" title="World of Warcraft is running. Animations paused to save CPU.">
        <span class="game-dot"></span>
        <span>WoW Running</span>
      </div>
    {:else}
      <div class="game-idle-label">
        <span>WoW Closed</span>
      </div>
    {/if}
  </div>
</aside>

<style>
  .app-sidebar {
    width: var(--sidebar-w, 240px);
    background: var(--bg-1);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    height: 100%;
    user-select: none;
    flex-shrink: 0;
  }

  .sidebar-header {
    padding: 1.25rem 1rem 1rem 1rem;
    border-bottom: 1px solid var(--border-soft);
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .brand-icon {
    width: 28px;
    height: 28px;
    color: var(--accent);
    flex-shrink: 0;
  }

  .brand-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .brand-title-row {
    display: flex;
    align-items: center;
    gap: 0.4rem;
  }

  .brand-name {
    font-weight: 700;
    font-size: 1.1rem;
    color: var(--text);
    letter-spacing: -0.02em;
  }

  .dev-tag {
    background: var(--danger-tint);
    color: var(--danger);
    border: 1px solid var(--danger-border);
    font-size: 0.65rem;
    font-weight: 700;
    padding: 1px 4px;
    border-radius: 3px;
    letter-spacing: 0.05em;
  }

  .version-label {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .flavour-section {
    padding: 0.75rem 1rem 0.5rem 1rem;
    border-bottom: 1px solid var(--border-soft);
  }

  .section-label {
    font-size: 0.7rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-faint);
    margin-bottom: 0.4rem;
  }

  .flavour-list {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }

  .flavour-btn {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.4rem 0.6rem;
    border-radius: var(--radius-sm, 4px);
    background: var(--bg-2);
    border: 1px solid transparent;
    color: var(--text-muted);
    font-size: 0.8rem;
    cursor: pointer;
    transition: background var(--fast), color var(--fast);
  }

  .flavour-btn:hover {
    background: var(--bg-3);
    color: var(--text);
  }

  .flavour-btn.active {
    background: var(--bg-3);
    border-color: var(--accent);
    color: var(--accent);
    font-weight: 600;
  }

  .flavour-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .flavour-folder {
    font-size: 0.7rem;
    color: var(--text-faint);
    font-family: monospace;
  }

  .freshness-box {
    padding: 0.85rem 1rem;
    border-bottom: 1px solid var(--border-soft);
  }

  .sidebar-nav {
    flex: 1;
    padding: 0.75rem 0.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    overflow-y: auto;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.65rem 0.75rem;
    border-radius: var(--radius, 8px);
    background: none;
    border: 1px solid transparent;
    color: var(--text-muted);
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    text-align: left;
    transition: background var(--fast), color var(--fast);
  }

  .nav-item:hover {
    background: var(--bg-2);
    color: var(--text);
  }

  .nav-item.active {
    background: var(--bg-3);
    border-color: var(--border);
    color: var(--accent);
    font-weight: 600;
  }

  .nav-item:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .nav-icon {
    font-size: 1rem;
  }

  .nav-text {
    flex: 1;
  }

  .nav-badge {
    font-size: 0.7rem;
    font-weight: 700;
    padding: 2px 7px;
    border-radius: 999px;
  }

  .badge-accent {
    background: var(--accent);
    color: var(--accent-text);
  }

  .badge-warning {
    background: var(--warning-tint);
    color: var(--warning);
    border: 1px solid rgba(255, 179, 71, 0.35);
  }

  .sidebar-footer {
    padding: 0.75rem 1rem;
    border-top: 1px solid var(--border-soft);
    background: var(--bg-0);
  }

  .game-active-badge {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--warning);
    background: var(--warning-tint);
    padding: 0.35rem 0.6rem;
    border-radius: var(--radius-sm, 4px);
    border: 1px solid rgba(255, 179, 71, 0.3);
  }

  .game-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--warning);
    box-shadow: 0 0 6px var(--warning);
  }

  .game-idle-label {
    font-size: 0.75rem;
    color: var(--text-faint);
  }
</style>
