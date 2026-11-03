<script lang="ts">
  import type { WagoSortOption } from '../../lib/types';

  interface Props {
    searchQuery: string;
    selectedCategory: string;
    selectedSort: WagoSortOption;
    categories: { id: string; label: string }[];
    loading: boolean;
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
</div>

<style>
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
