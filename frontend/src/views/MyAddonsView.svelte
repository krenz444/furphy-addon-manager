<script lang="ts">
  import VirtualList from '../components/addons/VirtualList.svelte';
  import StatusPill from '../components/addons/StatusPill.svelte';
  import RowMenu from '../components/addons/RowMenu.svelte';
  import UntrackedAddonsBanner from '../components/banners/UntrackedAddonsBanner.svelte';
  import type { Addon } from '../lib/types';

  interface Props {
    addons: Addon[];
    flavour: string;
    density: 'comfortable' | 'compact';
    untrackedCount: number;
    onUpdateAddon: (addon: Addon) => void;
    onUpdateAll: () => void;
    onUpdateSelected: (addons: Addon[]) => void;
    onUninstallAddon: (addon: Addon) => void;
    onUninstallSelected: (addons: Addon[]) => void;
    onTogglePin: (addon: Addon) => void;
    onToggleIgnore: (addon: Addon) => void;
    onRollbackAddon?: (addon: Addon) => void;
    onOpenAddonDrawer: (addon: Addon, tab?: string) => void;
    onOpenAddDialog: () => void;
    onOpenSource: (addon: Addon) => void;
    onManageAllUntracked: () => void;
    onViewUntracked: () => void;
    onDensityChange: (density: 'comfortable' | 'compact') => void;
    onInstallDeps?: (addonId?: string) => void;
    onIgnoreDeps?: (addon: Addon) => void;
    onIgnoreAllMissing?: () => void;
  }

  let {
    addons,
    flavour,
    density,
    untrackedCount,
    onUpdateAddon,
    onUpdateAll,
    onUpdateSelected,
    onUninstallAddon,
    onUninstallSelected,
    onTogglePin,
    onToggleIgnore,
    onRollbackAddon,
    onOpenAddonDrawer,
    onOpenAddDialog,
    onOpenSource,
    onManageAllUntracked,
    onViewUntracked,
    onDensityChange,
    onInstallDeps,
    onIgnoreDeps,
    onIgnoreAllMissing,
  }: Props = $props();

  let searchQuery = $state('');
  let activeFilter = $state<'all' | 'updates' | 'needs_deps' | 'pinned' | 'ignored' | 'old_patch' | 'failed'>('all');
  let sortBy = $state<'name' | 'status' | 'updated'>('name');
  let selectedIds = $state<Set<string>>(new Set());
  let errorDialogAddon = $state<Addon | null>(null);
  let errorCopied = $state(false);

  function isAddonUpdatable(a: Addon): boolean {
    if (!a.update_version || a.ignore_updates || a.pinned_file_id) return false;
    if (a.update_version === a.version) return false;
    if (a.update_file_id && a.file_id && a.update_file_id === a.file_id) return false;
    return true;
  }

  // Filtered addons
  let filteredAddons = $derived.by(() => {
    let list = addons;

    // Filter chip
    if (activeFilter === 'updates') {
      list = list.filter(isAddonUpdatable);
    } else if (activeFilter === 'needs_deps') {
      list = list.filter(a => !!(a.missing_deps && a.missing_deps.length > 0));
    } else if (activeFilter === 'pinned') {
      list = list.filter(a => !!a.pinned_file_id);
    } else if (activeFilter === 'ignored') {
      list = list.filter(a => a.ignore_updates);
    } else if (activeFilter === 'old_patch') {
      list = list.filter(a => a.is_old_patch);
    } else if (activeFilter === 'failed') {
      list = list.filter(a => !!a.error || a.check_status === 'failed');
    }

    // Search query
    const q = searchQuery.trim().toLowerCase();
    if (q) {
      list = list.filter(a => {
        const nameMatch = a.name?.toLowerCase().includes(q) ?? false;
        const authorMatch = a.author?.toLowerCase().includes(q) ?? false;
        const idMatch = a.id.toLowerCase().includes(q);
        const folderMatch = a.folders.some(f => f.toLowerCase().includes(q));
        return nameMatch || authorMatch || idMatch || folderMatch;
      });
    }

    // Sort
    return [...list].sort((a, b) => {
      if (sortBy === 'name') {
        const nameA = a.name ?? a.id;
        const nameB = b.name ?? b.id;
        return nameA.localeCompare(nameB, undefined, { sensitivity: 'base' });
      } else if (sortBy === 'status') {
        const priority = (item: Addon) => {
          if (item.error || item.check_status === 'failed') return 1;
          if (isAddonUpdatable(item)) return 2;
          if (item.missing_deps && item.missing_deps.length > 0) return 3;
          if (item.is_old_patch) return 4;
          if (item.pinned_file_id) return 5;
          if (item.ignore_updates) return 6;
          return 7;
        };
        return priority(a) - priority(b);
      } else if (sortBy === 'updated') {
        const dateA = a.installed_at ?? '';
        const dateB = b.installed_at ?? '';
        return dateB.localeCompare(dateA);
      }
      return 0;
    });
  });

  // Tallies for filter chips
  let updatesCount = $derived(addons.filter(isAddonUpdatable).length);
  let missingDepsCount = $derived(addons.filter(a => !!(a.missing_deps && a.missing_deps.length > 0)).length);
  let pinnedCount = $derived(addons.filter(a => !!a.pinned_file_id).length);
  let ignoredCount = $derived(addons.filter(a => a.ignore_updates).length);
  let oldPatchCount = $derived(addons.filter(a => a.is_old_patch).length);
  let failedCount = $derived(addons.filter(a => !!a.error || a.check_status === 'failed').length);

  // Selection helpers
  let isAllSelected = $derived(
    filteredAddons.length > 0 && filteredAddons.every(a => selectedIds.has(a.id))
  );

  function toggleSelectAll() {
    if (isAllSelected) {
      selectedIds = new Set();
    } else {
      selectedIds = new Set(filteredAddons.map(a => a.id));
    }
  }

  function toggleSelectOne(id: string, e: MouseEvent) {
    e.stopPropagation();
    const next = new Set(selectedIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
    }
    selectedIds = next;
  }

  function handleBulkUpdate() {
    const selected = addons.filter(a => selectedIds.has(a.id));
    onUpdateSelected(selected);
  }

  function handleBulkUninstall() {
    const selected = addons.filter(a => selectedIds.has(a.id));
    onUninstallSelected(selected);
  }

  let rowHeight = $derived(density === 'compact' ? 38 : 48);

  let isDepsDismissed = $state(false);
  let isUntrackedDismissed = $state(false);

  $effect(() => {
    // Reset banner dismissal when active flavour changes
    flavour;
    isDepsDismissed = false;
    isUntrackedDismissed = false;
  });
</script>

<div class="my-addons-view">
  {#if (untrackedCount > 0 && !isUntrackedDismissed) || (missingDepsCount > 0 && !isDepsDismissed)}
    <div class="banners-stack">
      {#if untrackedCount > 0 && !isUntrackedDismissed}
        <UntrackedAddonsBanner
          count={untrackedCount}
          {flavour}
          onManageAll={onManageAllUntracked}
          onViewUntracked={onViewUntracked}
          onDismiss={() => (isUntrackedDismissed = true)}
        />
      {/if}

      {#if missingDepsCount > 0 && !isDepsDismissed}
        <aside class="missing-deps-banner" role="status" aria-label="Missing Dependencies Notice">
          <div class="banner-content">
            <div class="banner-icon-col">
              <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="10" cy="10" r="8" />
                <line x1="10" y1="6" x2="10" y2="10" />
                <line x1="10" y1="14" x2="10.01" y2="14" />
              </svg>
            </div>
            <div class="banner-text-col">
              <strong class="banner-headline">
                {missingDepsCount} {missingDepsCount === 1 ? 'addon has' : 'addons have'} missing dependencies
              </strong>
              <span class="banner-subtext">
                Required dependencies must be installed for these addons to work in {flavour}.
              </span>
            </div>
          </div>
          <div class="banner-actions">
            <button
              type="button"
              class="btn-banner btn-banner-filter"
              onclick={() => (activeFilter = 'needs_deps')}
            >
              View ({missingDepsCount})
            </button>
            {#if onInstallDeps}
              <button
                type="button"
                class="btn-banner btn-banner-install"
                onclick={() => onInstallDeps?.()}
                title="Automatically fetch and install missing dependencies"
              >
                Install Missing
              </button>
            {/if}
            {#if onIgnoreAllMissing}
              <button
                type="button"
                class="btn-banner btn-banner-ignore"
                onclick={() => onIgnoreAllMissing?.()}
                title="Ignore all missing dependency warnings"
              >
                Ignore Missing
              </button>
            {/if}
            <button
              type="button"
              class="dismiss-btn"
              aria-label="Dismiss missing dependencies banner"
              onclick={() => (isDepsDismissed = true)}
            >
              ✕
            </button>
          </div>
        </aside>
      {/if}
    </div>
  {/if}

  <header class="toolbar">
    <div class="search-box">
      <span class="search-icon">🔍</span>
      <input
        type="search"
        class="search-input"
        placeholder="Filter addons by name, author, or folder…"
        bind:value={searchQuery}
        aria-label="Filter addons"
      />
      {#if searchQuery}
        <button
          type="button"
          class="clear-search-btn"
          onclick={() => (searchQuery = '')}
          aria-label="Clear filter"
        >
          ✕
        </button>
      {/if}
    </div>

    <div class="toolbar-actions">
      <div class="select-group">
        <label for="sort-select" class="sr-only">Sort by</label>
        <select
          id="sort-select"
          class="toolbar-select"
          bind:value={sortBy}
          aria-label="Sort addons by"
        >
          <option value="name">Sort: Name (A-Z)</option>
          <option value="status">Sort: Status</option>
          <option value="updated">Sort: Recently Updated</option>
        </select>
      </div>

      <div class="density-group" role="group" aria-label="Row density">
        <button
          type="button"
          class="density-btn"
          class:active={density === 'comfortable'}
          onclick={() => onDensityChange('comfortable')}
          title="Comfortable spacing"
        >
          ≡
        </button>
        <button
          type="button"
          class="density-btn"
          class:active={density === 'compact'}
          onclick={() => onDensityChange('compact')}
          title="Compact spacing"
        >
          ☵
        </button>
      </div>

      <button
        type="button"
        class="btn-primary"
        onclick={onOpenAddDialog}
      >
        + Add Addon
      </button>
    </div>
  </header>

  <div class="filter-bar">
    <div class="filter-chips" role="tablist">
      <button
        type="button"
        role="tab"
        aria-selected={activeFilter === 'all'}
        class="filter-chip"
        class:active={activeFilter === 'all'}
        onclick={() => (activeFilter = 'all')}
      >
        All ({addons.length})
      </button>

      {#if updatesCount > 0}
        <button
          type="button"
          role="tab"
          aria-selected={activeFilter === 'updates'}
          class="filter-chip chip-accent"
          class:active={activeFilter === 'updates'}
          onclick={() => (activeFilter = 'updates')}
        >
          Updates ({updatesCount})
        </button>
      {/if}

      {#if missingDepsCount > 0}
        <button
          type="button"
          role="tab"
          aria-selected={activeFilter === 'needs_deps'}
          class="filter-chip chip-warning"
          class:active={activeFilter === 'needs_deps'}
          onclick={() => (activeFilter = 'needs_deps')}
        >
          Needs Deps ({missingDepsCount})
        </button>
      {/if}

      {#if pinnedCount > 0}
        <button
          type="button"
          role="tab"
          aria-selected={activeFilter === 'pinned'}
          class="filter-chip chip-warning"
          class:active={activeFilter === 'pinned'}
          onclick={() => (activeFilter = 'pinned')}
        >
          Pinned ({pinnedCount})
        </button>
      {/if}

      {#if ignoredCount > 0}
        <button
          type="button"
          role="tab"
          aria-selected={activeFilter === 'ignored'}
          class="filter-chip"
          class:active={activeFilter === 'ignored'}
          onclick={() => (activeFilter = 'ignored')}
        >
          Ignored ({ignoredCount})
        </button>
      {/if}

      {#if oldPatchCount > 0}
        <button
          type="button"
          role="tab"
          aria-selected={activeFilter === 'old_patch'}
          class="filter-chip chip-warning"
          class:active={activeFilter === 'old_patch'}
          onclick={() => (activeFilter = 'old_patch')}
        >
          Old Patch ({oldPatchCount})
        </button>
      {/if}

      {#if failedCount > 0}
        <button
          type="button"
          role="tab"
          aria-selected={activeFilter === 'failed'}
          class="filter-chip chip-failed"
          class:active={activeFilter === 'failed'}
          onclick={() => (activeFilter = 'failed')}
        >
          Failed ({failedCount})
        </button>
      {/if}
    </div>

    <div class="filter-bar-actions">
      {#if updatesCount > 0}
        <button
          type="button"
          class="btn-update-all"
          onclick={onUpdateAll}
        >
          Update all ({updatesCount})
        </button>
      {/if}
    </div>
  </div>

  {#if selectedIds.size > 0}
    <div class="bulk-action-bar">
      <span class="bulk-count">
        <strong>{selectedIds.size}</strong> selected
      </span>
      <div class="bulk-buttons">
        <button
          type="button"
          class="btn-sm btn-accent"
          onclick={handleBulkUpdate}
        >
          Update Selected
        </button>
        <button
          type="button"
          class="btn-sm btn-danger"
          onclick={handleBulkUninstall}
        >
          Uninstall Selected
        </button>
        <button
          type="button"
          class="btn-sm btn-secondary"
          onclick={() => (selectedIds = new Set())}
        >
          Deselect
        </button>
      </div>
    </div>
  {/if}

  <div class="list-wrapper">
    <div class="table-header">
      <div class="col-select">
        <input
          type="checkbox"
          checked={isAllSelected}
          onchange={toggleSelectAll}
          aria-label="Select all addons"
        />
      </div>
      <div class="col-name">Name</div>
      <div class="col-version">Version</div>
      <div class="col-source">Source</div>
      <div class="col-status">Status</div>
      <div class="col-menu"></div>
    </div>

    {#if filteredAddons.length === 0}
      <div class="empty-state">
        {#if addons.length === 0}
          <div class="empty-icon">📦</div>
          <h3>No addons managed in {flavour} yet</h3>
          <p>Add new addons from Wago, CurseForge, or GitHub to get started.</p>
          <button type="button" class="btn-primary" onclick={onOpenAddDialog}>
            + Add your first addon
          </button>
        {:else}
          <div class="empty-icon">🔍</div>
          <h3>No addons match your filter</h3>
          <p>Try searching for a different keyword or resetting filters.</p>
          <button
            type="button"
            class="btn-secondary"
            onclick={() => { searchQuery = ''; activeFilter = 'all'; }}
          >
            Reset Filters
          </button>
        {/if}
      </div>
    {:else}
      <div class="virtual-list-container">
        <VirtualList
          items={filteredAddons}
          itemHeight={rowHeight}
        >
          {#snippet children({ item: addon })}
            <div
              class="addon-row"
              class:selected={selectedIds.has(addon.id)}
              class:compact={density === 'compact'}
              onclick={() => onOpenAddonDrawer(addon)}
              role="button"
              tabindex="0"
              onkeydown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  onOpenAddonDrawer(addon);
                }
              }}
            >
              <div
                class="col-select"
                onclick={(e) => e.stopPropagation()}
                onkeydown={(e) => { if (e.key === ' ' || e.key === 'Enter') e.stopPropagation(); }}
                role="presentation"
              >
                <input
                  type="checkbox"
                  checked={selectedIds.has(addon.id)}
                  onclick={(e) => toggleSelectOne(addon.id, e)}
                  aria-label="Select {addon.name ?? addon.id}"
                />
              </div>

              <div class="col-name">
                <span class="addon-title">{addon.name ?? addon.id}</span>
                {#if addon.error}
                  <button
                    type="button"
                    class="addon-error-badge"
                    title="Error: {addon.error}. Click to view details."
                    onclick={(e) => {
                      e.stopPropagation();
                      errorDialogAddon = addon;
                    }}
                  >
                    <span class="error-badge-icon" aria-hidden="true">⚠</span>
                    <span class="error-badge-text">Error</span>
                  </button>
                {/if}
                {#if addon.author}
                  <span class="addon-author">by {addon.author}</span>
                {/if}
              </div>

              <div class="col-version font-mono">
                {addon.version ?? '—'}
              </div>

              <div class="col-source">
                <span class="source-badge source-{addon.source ?? 'cf'}">
                  {addon.source ?? 'cf'}
                </span>
              </div>

              <div
                class="col-status"
                onclick={(e) => e.stopPropagation()}
                onkeydown={(e) => { if (e.key === ' ' || e.key === 'Enter') e.stopPropagation(); }}
                role="presentation"
              >
                <StatusPill
                  {addon}
                  onUpdate={onUpdateAddon}
                  onUnpin={onTogglePin}
                  onUnignore={onToggleIgnore}
                  onRetry={onUpdateAddon}
                  onViewDetails={onOpenAddonDrawer}
                  onInstallDeps={() => onInstallDeps?.(addon.id)}
                  onShowError={(a) => (errorDialogAddon = a)}
                />
              </div>

              <div
                class="col-menu"
                onclick={(e) => e.stopPropagation()}
                onkeydown={(e) => { if (e.key === ' ' || e.key === 'Enter') e.stopPropagation(); }}
                role="presentation"
              >
                <RowMenu
                  {addon}
                  onUpdate={onUpdateAddon}
                  onInstallDeps={(a) => onInstallDeps?.(a.id)}
                  onIgnoreDeps={onIgnoreDeps}
                  onViewDetails={onOpenAddonDrawer}
                  onTogglePin={onTogglePin}
                  onToggleIgnore={onToggleIgnore}
                  onRollback={onRollbackAddon}
                  onOpenSource={onOpenSource}
                  onUninstall={onUninstallAddon}
                />
              </div>
            </div>
          {/snippet}
        </VirtualList>
      </div>
    {/if}
  </div>

  {#if errorDialogAddon}
    <div
      class="dialog-backdrop"
      onclick={() => (errorDialogAddon = null)}
      role="presentation"
    >
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <div
        class="dialog-card error-dialog-card"
        onclick={(e) => e.stopPropagation()}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="addon-error-modal-title"
        tabindex="-1"
      >
        <div class="dialog-header">
          <span class="dialog-status-icon failed-icon" aria-hidden="true">✕</span>
          <div class="dialog-title-block">
            <h3 id="addon-error-modal-title" class="dialog-title danger-text">
              Addon Operation Failed
            </h3>
            <span class="dialog-subtitle">{errorDialogAddon.name ?? errorDialogAddon.id}</span>
          </div>
          <button
            type="button"
            class="dialog-close-btn"
            onclick={() => (errorDialogAddon = null)}
            aria-label="Close error dialog"
          >
            ✕
          </button>
        </div>

        <div class="dialog-body">
          <p class="dialog-explanation">
            An error occurred while updating, installing, or checking this addon:
          </p>
          <div class="error-detail-box font-mono" role="region" aria-label="Error message">
            {errorDialogAddon.error || 'Update check, download, or installation failed.'}
          </div>
        </div>

        <div class="dialog-actions">
          <button
            type="button"
            class="btn-secondary"
            onclick={() => {
              const err = errorDialogAddon?.error || 'Operation failed';
              navigator.clipboard.writeText(`${errorDialogAddon?.name ?? errorDialogAddon?.id}: ${err}`);
              errorCopied = true;
              setTimeout(() => { errorCopied = false; }, 2000);
            }}
          >
            {errorCopied ? '✓ Copied' : 'Copy Error'}
          </button>
          <button
            type="button"
            class="btn-secondary"
            onclick={() => {
              const target = errorDialogAddon;
              errorDialogAddon = null;
              if (target) onOpenAddonDrawer(target, 'changelog');
            }}
          >
            View in Drawer
          </button>
          <button
            type="button"
            class="btn-primary btn-retry-error"
            onclick={() => {
              const target = errorDialogAddon;
              errorDialogAddon = null;
              if (target) onUpdateAddon(target);
            }}
          >
            Retry
          </button>
        </div>
      </div>
    </div>
  {/if}
</div>

<svelte:window onkeydown={(e) => {
  if (errorDialogAddon && e.key === 'Escape') {
    e.preventDefault();
    errorDialogAddon = null;
  }
}} />

<style>
  .my-addons-view {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }

  .toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.75rem 1.25rem;
    background: var(--bg-1);
    border-bottom: 1px solid var(--border-soft);
  }

  .search-box {
    position: relative;
    flex: 1;
    max-width: 480px;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 0.65rem;
    color: var(--text-muted);
    font-size: 0.85rem;
    pointer-events: none;
  }

  .search-input {
    width: 100%;
    padding: 0.45rem 2rem 0.45rem 2rem;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    font-size: 0.85rem;
    outline: none;
  }

  .search-input:focus-visible {
    border-color: var(--focus-ring);
    box-shadow: 0 0 0 2px var(--focus-ring);
  }

  .clear-search-btn {
    position: absolute;
    right: 0.5rem;
    background: none;
    border: none;
    color: var(--text-muted);
    cursor: pointer;
    font-size: 0.75rem;
    padding: 2px 4px;
  }

  .toolbar-actions {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .toolbar-select {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    padding: 0.45rem 0.65rem;
    font-size: 0.85rem;
    outline: none;
  }

  .toolbar-select:focus-visible {
    border-color: var(--focus-ring);
  }

  .density-group {
    display: flex;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    overflow: hidden;
  }

  .density-btn {
    background: var(--bg-0);
    border: none;
    color: var(--text-muted);
    padding: 0.35rem 0.55rem;
    font-size: 0.9rem;
    cursor: pointer;
  }

  .density-btn.active {
    background: var(--bg-3);
    color: var(--text);
  }

  .density-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .filter-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.5rem 1.25rem;
    background: var(--bg-2);
    border-bottom: 1px solid var(--border-soft);
  }

  .filter-chips {
    display: flex;
    align-items: center;
    gap: 0.4rem;
  }

  .filter-chip {
    background: var(--bg-0);
    border: 1px solid var(--border);
    color: var(--text-muted);
    padding: 0.25rem 0.65rem;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast), color var(--fast);
  }

  .filter-chip:hover {
    color: var(--text);
    background: var(--bg-3);
  }

  .filter-chip.active {
    background: var(--bg-3);
    border-color: var(--accent);
    color: var(--text);
  }

  .chip-accent.active {
    border-color: var(--accent);
    color: var(--accent);
  }

  .chip-warning.active {
    border-color: var(--warning);
    color: var(--warning);
  }

  .filter-bar-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .btn-update-all {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.75rem;
    font-weight: 700;
    padding: 0.3rem 0.75rem;
    cursor: pointer;
  }

  .btn-update-all:hover {
    background: var(--accent-hover);
  }

  /* Banners stack container */
  .banners-stack {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px 1.25rem 4px 1.25rem;
    flex-shrink: 0;
  }

  /* Missing dependencies banner */
  .missing-deps-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 10px 16px;
    min-height: 52px;
    box-sizing: border-box;
    width: 100%;
    margin: 0;
    background: var(--bg-1);
    border: 1px solid var(--warning);
    border-radius: var(--radius);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
    flex-wrap: wrap;
  }

  .missing-deps-banner .banner-content {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
    flex: 1;
  }

  .missing-deps-banner .banner-icon-col {
    color: var(--warning);
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    flex-shrink: 0;
  }

  .missing-deps-banner .banner-text-col {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .missing-deps-banner .banner-headline {
    color: var(--text);
    font-size: 13px;
    font-weight: 600;
    line-height: 1.3;
  }

  .missing-deps-banner .banner-subtext {
    color: var(--text-muted);
    font-size: 12px;
    line-height: 1.3;
  }

  .missing-deps-banner .banner-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .btn-banner {
    font-size: 12px;
    font-weight: 600;
    height: 28px;
    padding: 0 12px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: background var(--fast), color var(--fast), border-color var(--fast);
    box-sizing: border-box;
    white-space: nowrap;
  }

  .btn-banner-filter {
    background: transparent;
    color: var(--text);
    border: 1px solid var(--border);
  }

  .btn-banner-filter:hover {
    background: var(--bg-2);
  }

  .btn-banner-filter:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-banner-install {
    background: var(--warning-tint);
    color: var(--warning);
    border: 1px solid var(--warning);
  }

  .btn-banner-install:hover {
    background: var(--warning);
    color: var(--bg-0);
  }

  .btn-banner-install:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-banner-ignore {
    background: transparent;
    color: var(--text-muted);
    border: 1px solid var(--border);
  }

  .btn-banner-ignore:hover {
    background: var(--bg-2);
    color: var(--text);
  }

  .btn-banner-ignore:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .missing-deps-banner .dismiss-btn {
    background: transparent;
    border: none;
    color: var(--text-faint);
    font-size: 14px;
    width: 28px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    padding: 0;
    border-radius: var(--radius-sm);
    transition: background var(--fast), color var(--fast);
    box-sizing: border-box;
  }

  .missing-deps-banner .dismiss-btn:hover {
    color: var(--text);
    background: var(--bg-2);
  }

  .missing-deps-banner .dismiss-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .bulk-action-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.5rem 1.25rem;
    background: var(--bg-3);
    border-bottom: 1px solid var(--accent);
  }

  .bulk-count {
    font-size: 0.85rem;
    color: var(--text);
  }

  .bulk-buttons {
    display: flex;
    gap: 0.5rem;
  }

  .list-wrapper {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .table-header {
    display: grid;
    grid-template-columns: 40px 1fr 140px 90px 160px 48px;
    align-items: center;
    padding: 0.5rem 1.25rem;
    background: var(--bg-0);
    border-bottom: 1px solid var(--border);
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-faint);
  }

  .virtual-list-container {
    flex: 1;
    overflow: hidden;
  }

  .addon-row {
    display: grid;
    grid-template-columns: 40px 1fr 140px 90px 160px 48px;
    align-items: center;
    padding: 0 1.25rem;
    height: 48px;
    border-bottom: 1px solid var(--border-soft);
    background: var(--bg-1);
    color: var(--text);
    cursor: pointer;
    box-sizing: border-box;
    transition: background var(--fast);
  }

  .addon-row.compact {
    height: 38px;
  }

  .addon-row:hover {
    background: var(--bg-2);
  }

  .addon-row.selected {
    background: rgba(255, 90, 168, 0.08);
  }

  .addon-row:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: -2px;
  }

  .col-select {
    display: flex;
    align-items: center;
  }

  .col-name {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-width: 0;
    padding-right: 1rem;
  }

  .addon-title {
    font-weight: 600;
    font-size: 0.875rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .addon-author {
    font-size: 0.75rem;
    color: var(--text-muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .col-version {
    font-size: 0.8rem;
    color: var(--text-muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .source-badge {
    font-size: 0.7rem;
    font-weight: 700;
    text-transform: uppercase;
    padding: 2px 5px;
    border-radius: 3px;
    letter-spacing: 0.03em;
  }

  .source-cf {
    background: rgba(241, 100, 54, 0.15);
    color: #ff7d52;
  }

  .source-wago {
    background: rgba(196, 30, 58, 0.15);
    color: #ff5277;
  }

  .source-github {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text);
  }

  .col-status {
    display: flex;
    align-items: center;
  }

  .col-menu {
    display: flex;
    align-items: center;
    justify-content: flex-end;
  }

  .empty-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 3rem 1rem;
    text-align: center;
    color: var(--text-muted);
  }

  .empty-icon {
    font-size: 2.5rem;
    margin-bottom: 0.75rem;
  }

  .empty-state h3 {
    margin: 0 0 0.5rem 0;
    font-size: 1.15rem;
    color: var(--text);
  }

  .empty-state p {
    margin: 0 0 1.25rem 0;
    font-size: 0.9rem;
    max-width: 400px;
    line-height: 1.4;
  }

  .btn-primary, .btn-secondary, .btn-sm {
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    padding: 0.45rem 0.85rem;
  }

  .btn-primary:hover {
    background: var(--accent-hover);
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    padding: 0.45rem 0.85rem;
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-sm {
    padding: 0.25rem 0.6rem;
    font-size: 0.75rem;
  }

  .btn-accent {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
  }

  .btn-danger {
    background: var(--danger);
    color: var(--danger-text);
    border: none;
  }

  .font-mono {
    font-family: monospace;
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    border: 0;
  }

  .filter-chip.chip-failed {
    border-color: var(--danger-border);
    color: var(--danger);
  }

  .filter-chip.chip-failed.active {
    border-color: var(--danger);
    background: var(--danger);
    color: var(--danger-text);
  }

  .addon-error-badge {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    background: var(--danger-tint);
    color: var(--danger);
    border: 1px solid var(--danger-border);
    border-radius: var(--radius-sm, 4px);
    font-size: 11px;
    font-weight: 600;
    padding: 1px 6px;
    cursor: pointer;
    vertical-align: middle;
    transition: background var(--fast), border-color var(--fast);
    flex-shrink: 0;
  }

  .addon-error-badge:hover {
    background: rgba(255, 111, 120, 0.25);
    border-color: var(--danger);
  }

  .addon-error-badge:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .error-badge-icon {
    font-size: 11px;
    line-height: 1;
  }

  .error-badge-text {
    line-height: 1.2;
  }

  .dialog-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
    padding: 1rem;
    backdrop-filter: blur(2px);
  }

  .dialog-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-lg, 12px);
    width: 100%;
    max-width: 480px;
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.5);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .dialog-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 1.25rem 1.5rem;
    border-bottom: 1px solid var(--border);
    background: var(--bg-2);
  }

  .dialog-status-icon.failed-icon {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--danger-tint);
    color: var(--danger);
    border: 1px solid var(--danger-border);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    font-size: 14px;
    flex-shrink: 0;
  }

  .dialog-title-block {
    flex: 1;
    min-width: 0;
  }

  .dialog-title {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 700;
    color: var(--text);
  }

  .dialog-title.danger-text {
    color: var(--danger);
  }

  .dialog-subtitle {
    font-size: 0.8rem;
    color: var(--text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    display: block;
    margin-top: 2px;
  }

  .dialog-close-btn {
    background: none;
    border: none;
    color: var(--text-muted);
    font-size: 1.1rem;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: 4px;
    transition: color var(--fast);
  }

  .dialog-close-btn:hover {
    color: var(--text);
  }

  .dialog-close-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .dialog-body {
    padding: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .dialog-explanation {
    margin: 0;
    font-size: 0.85rem;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .error-detail-box {
    background: rgba(0, 0, 0, 0.4);
    border: 1px solid var(--danger-border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.75rem 1rem;
    font-size: 0.8rem;
    color: var(--danger);
    line-height: 1.45;
    max-height: 180px;
    overflow-y: auto;
    white-space: pre-wrap;
    word-break: break-all;
  }

  .dialog-actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 0.65rem;
    padding: 1rem 1.5rem;
    border-top: 1px solid var(--border);
    background: var(--bg-2);
  }

  .btn-retry-error {
    background: var(--danger);
    color: #fff;
    border: 1px solid var(--danger);
  }

  .btn-retry-error:hover {
    background: var(--danger-hover);
  }
</style>
