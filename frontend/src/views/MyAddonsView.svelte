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
  }: Props = $props();

  let searchQuery = $state('');
  let activeFilter = $state<'all' | 'updates' | 'pinned' | 'ignored' | 'old_patch'>('all');
  let sortBy = $state<'name' | 'status' | 'updated'>('name');
  let selectedIds = $state<Set<string>>(new Set());

  // Filtered addons
  let filteredAddons = $derived.by(() => {
    let list = addons;

    // Filter chip
    if (activeFilter === 'updates') {
      list = list.filter(a => !!a.update_version);
    } else if (activeFilter === 'pinned') {
      list = list.filter(a => !!a.pinned_file_id);
    } else if (activeFilter === 'ignored') {
      list = list.filter(a => a.ignore_updates);
    } else if (activeFilter === 'old_patch') {
      list = list.filter(a => a.is_old_patch);
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
          if (item.update_version) return 1;
          if (item.is_old_patch) return 2;
          if (item.check_status === 'failed') return 3;
          if (item.pinned_file_id) return 4;
          if (item.ignore_updates) return 5;
          return 6;
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
  let updatesCount = $derived(addons.filter(a => !!a.update_version).length);
  let pinnedCount = $derived(addons.filter(a => !!a.pinned_file_id).length);
  let ignoredCount = $derived(addons.filter(a => a.ignore_updates).length);
  let oldPatchCount = $derived(addons.filter(a => a.is_old_patch).length);

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
</script>

<div class="my-addons-view">
  {#if untrackedCount > 0}
    <UntrackedAddonsBanner
      count={untrackedCount}
      {flavour}
      onManageAll={onManageAllUntracked}
      onViewUntracked={onViewUntracked}
    />
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
    </div>

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
</div>

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
</style>
