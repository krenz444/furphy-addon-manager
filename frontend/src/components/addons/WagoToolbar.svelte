<script lang="ts">
  import type { Flavour, WagoSortOption } from '../../lib/types';

  interface Props {
    searchQuery: string;
    selectedCategory: string;
    selectedSort: WagoSortOption;
    categories: { id: string; label: string }[];
    loading: boolean;
    destinationLabel?: string;
    isClassicOrForever?: boolean;
    selectedFlavour?: string;
    flavours?: Flavour[];
    onFlavourChange?: (flavour: string) => void;
    onQueryChange: (query: string) => void;
    onCategoryChange: (category: string) => void;
    onSortChange: (sort: WagoSortOption) => void;
    onTriggerSearch: () => void;
    onClearQuery: () => void;
  }

  let {
    searchQuery,
    selectedCategory,
    selectedSort,
    categories,
    loading,
    destinationLabel,
    isClassicOrForever = false,
    selectedFlavour,
    flavours = [],
    onFlavourChange,
    onQueryChange,
    onCategoryChange,
    onSortChange,
    onTriggerSearch,
    onClearQuery,
  }: Props = $props();

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      onTriggerSearch();
    }
  }
</script>

<div class="wago-toolbar">
  <div class="search-box">
    <span class="search-icon" aria-hidden="true">🔍</span>
    <input
      type="search"
      class="search-input"
      placeholder="Search Wago addons…"
      value={searchQuery}
      oninput={(e) => onQueryChange((e.target as HTMLInputElement).value)}
      onkeydown={handleKeydown}
      aria-label="Search Wago addons"
    />
    {#if searchQuery.trim().length > 0}
      <button
        type="button"
        class="btn-clear"
        onclick={onClearQuery}
        title="Clear search query"
        aria-label="Clear search query"
      >
        ✕
      </button>
    {/if}
  </div>

  {#if categories.length > 0}
    <select
      class="toolbar-select"
      value={selectedCategory}
      onchange={(e) => onCategoryChange((e.target as HTMLSelectElement).value)}
      aria-label="Filter by category"
    >
      <option value="">All Categories</option>
      {#each categories as cat (cat.id)}
        <option value={cat.id}>{cat.label}</option>
      {/each}
    </select>
  {/if}

  <select
    class="toolbar-select"
    value={selectedSort}
    onchange={(e) => onSortChange((e.target as HTMLSelectElement).value as WagoSortOption)}
    aria-label="Sort by"
  >
    <option value="popular">Most Popular</option>
    <option value="downloads">Most Downloads</option>
    <option value="rating">Highest Rated</option>
    <option value="updated">Recently Updated</option>
    <option value="name">Name A-Z</option>
    <option value="gaining">Gaining this week</option>
  </select>

  <button
    type="button"
    class="btn-primary"
    onclick={onTriggerSearch}
    disabled={loading}
  >
    {loading ? 'Searching…' : 'Search'}
  </button>

  {#if flavours && flavours.length > 0}
    <div class="flavour-selector-wrap" title="Select which game version to browse and install addons for">
      <label for="wago-target-flavour-select" class="flavour-label-badge">
        <span class="indicator-dot" class:classic={isClassicOrForever}></span>
        <span>Game:</span>
      </label>
      <select
        id="wago-target-flavour-select"
        class="toolbar-select flavour-select"
        class:classic={isClassicOrForever}
        value={selectedFlavour}
        onchange={(e) => onFlavourChange?.((e.target as HTMLSelectElement).value)}
        aria-label="Select game client to browse and install addons for"
      >
        {#each flavours as fl (fl.id)}
          <option value={fl.id}>
            {fl.label} {fl.custom_root ? '(Custom)' : `(${fl.folder})`}
          </option>
        {/each}
      </select>
    </div>
  {:else if destinationLabel}
    <div class="target-indicator" class:classic={isClassicOrForever} title={`Browsing addons compatible with ${destinationLabel}`}>
      <span class="indicator-dot" class:classic={isClassicOrForever}></span>
      <span class="indicator-text">{destinationLabel}</span>
    </div>
  {/if}
</div>

<style>
  .flavour-selector-wrap {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    margin-left: auto;
  }

  .flavour-label-badge {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--text-muted);
  }

  .flavour-select {
    font-weight: 600;
  }

  .flavour-select.classic {
    border-color: rgba(245, 158, 11, 0.4);
    color: #f59e0b;
  }

  .target-indicator {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.4rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    background: rgba(59, 130, 246, 0.12);
    border: 1px solid rgba(59, 130, 246, 0.3);
    color: var(--accent);
    font-size: 0.8rem;
    font-weight: 600;
    margin-left: auto;
  }

  .target-indicator.classic {
    background: rgba(245, 158, 11, 0.12);
    border-color: rgba(245, 158, 11, 0.35);
    color: #f59e0b;
  }

  .indicator-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent);
  }

  .indicator-dot.classic {
    background: #f59e0b;
  }

  .indicator-text {
    white-space: nowrap;
  }
  .wago-toolbar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    flex-wrap: wrap;
  }

  .search-box {
    position: relative;
    flex: 1;
    min-width: 200px;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 0.75rem;
    color: var(--text-muted);
    font-size: 0.85rem;
    pointer-events: none;
  }

  .search-input {
    width: 100%;
    background: var(--bg-1);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 0.5rem 2rem 0.5rem 2.2rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
  }

  .search-input:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .btn-clear {
    position: absolute;
    right: 0.6rem;
    background: none;
    border: none;
    color: var(--text-muted);
    font-size: 0.75rem;
    cursor: pointer;
    padding: 0.2rem 0.35rem;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color var(--fast, 150ms), background var(--fast, 150ms);
  }

  .btn-clear:hover {
    color: var(--text);
    background: var(--bg-2);
  }

  .btn-clear:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .toolbar-select {
    background: var(--bg-1);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 0.5rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    cursor: pointer;
  }

  .toolbar-select:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .btn-primary {
    background: var(--accent);
    color: #ffffff;
    border: none;
    padding: 0.5rem 1rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: filter var(--fast, 150ms);
  }

  .btn-primary:hover:not(:disabled) {
    filter: brightness(1.1);
  }

  .btn-primary:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .btn-primary:focus-visible {
    outline: 2px solid var(--focus-ring);
  }
</style>
