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

  let isSwitching = $state(false);
  let pendingFlavour = $state<string | null>(null);
  let switchTimeout: ReturnType<typeof setTimeout> | null = null;

  // Derive human-readable target client label for explicit feedback
  let targetFlavourLabel = $derived.by(() => {
    if (!pendingFlavour) return '';
    const match = flavours?.find((f) => f.id === pendingFlavour);
    return match ? match.label : pendingFlavour;
  });

  // Synchronize state when selectedFlavour prop updates from parent
  $effect(() => {
    if (pendingFlavour && selectedFlavour === pendingFlavour && !loading) {
      isSwitching = false;
      pendingFlavour = null;
      if (switchTimeout) {
        clearTimeout(switchTimeout);
        switchTimeout = null;
      }
    }
  });

  function handleFlavourChangeInternal(e: Event) {
    const select = e.target as HTMLSelectElement;
    const newFlavour = select.value;
    if (!newFlavour || newFlavour === selectedFlavour) return;

    // Prevent race conditions: do not allow initiating a client switch during an active browse query
    if (loading || isSwitching) {
      select.value = selectedFlavour || '';
      return;
    }

    isSwitching = true;
    pendingFlavour = newFlavour;

    // Safety timeout in case parent fails to acknowledge the switch
    if (switchTimeout) clearTimeout(switchTimeout);
    switchTimeout = setTimeout(() => {
      isSwitching = false;
      pendingFlavour = null;
    }, 6000);

    onFlavourChange?.(newFlavour);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !loading) {
      onTriggerSearch();
    }
  }
</script>

<div class="wago-toolbar" role="region" aria-label="Wago browsing controls">
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
      disabled={loading && isSwitching}
    />
    {#if searchQuery.trim().length > 0}
      <button
        type="button"
        class="btn-clear"
        onclick={onClearQuery}
        title="Clear search query"
        aria-label="Clear search query"
        disabled={loading && isSwitching}
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
      disabled={loading}
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
    disabled={loading}
  >
    <option value="popular">Most Popular</option>
    <option value="downloads">Most Downloads</option>
    <option value="updated">Recently Updated</option>
    <option value="name">Name A-Z</option>
  </select>

  <button
    type="button"
    class="btn-primary"
    onclick={onTriggerSearch}
    disabled={loading || isSwitching}
    aria-busy={loading}
  >
    {loading && !isSwitching ? 'Searching…' : 'Search'}
  </button>

  {#if flavours && flavours.length > 0}
    <div
      class="flavour-selector-wrap"
      title="Select which game version to browse and install addons for"
    >
      <label for="wago-target-flavour-select" class="flavour-label-badge">
        <span
          class="indicator-dot"
          class:classic={isClassicOrForever}
          class:pulsing={loading || isSwitching}
          aria-hidden="true"
        ></span>
        <span>Game:</span>
      </label>

      <select
        id="wago-target-flavour-select"
        class="toolbar-select flavour-select"
        class:classic={isClassicOrForever}
        value={selectedFlavour}
        disabled={loading || isSwitching}
        onchange={handleFlavourChangeInternal}
        aria-label="Select game client to browse and install addons for"
        aria-busy={loading || isSwitching}
      >
        {#each flavours as fl (fl.id)}
          <option value={fl.id}>
            {fl.label} {fl.custom_root ? '(Custom)' : `(${fl.folder})`}
          </option>
        {/each}
      </select>

      {#if isSwitching && targetFlavourLabel}
        <span class="flavour-feedback" role="status" aria-live="polite">
          <span class="feedback-spinner" aria-hidden="true"></span>
          Switching to {targetFlavourLabel}…
        </span>
      {/if}
    </div>
  {:else if destinationLabel}
    <div
      class="target-indicator"
      class:classic={isClassicOrForever}
      title={`Browsing addons compatible with ${destinationLabel}`}
    >
      <span
        class="indicator-dot"
        class:classic={isClassicOrForever}
        class:pulsing={loading}
        aria-hidden="true"
      ></span>
      <span class="indicator-text">{destinationLabel}</span>
    </div>
  {/if}
</div>

<style>
  .wago-toolbar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    flex-wrap: wrap;
    width: 100%;
  }

  .search-box {
    position: relative;
    flex: 1 1 220px;
    min-width: 180px;
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

  .btn-clear:hover:not(:disabled) {
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
    transition: opacity var(--fast, 150ms), border-color var(--fast, 150ms);
  }

  .toolbar-select:disabled {
    opacity: 0.65;
    cursor: not-allowed;
  }

  .toolbar-select:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    padding: 0.5rem 1rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: filter var(--fast, 150ms);
    white-space: nowrap;
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

  .flavour-selector-wrap {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    margin-left: auto;
    flex-wrap: wrap;
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
    border-color: color-mix(in srgb, var(--warning) 40%, transparent);
    color: var(--warning);
  }

  .flavour-feedback {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--accent);
    background: var(--accent-tint);
    border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
    padding: 0.25rem 0.5rem;
    border-radius: var(--radius-sm, 4px);
    white-space: nowrap;
    animation: fadeIn 150ms ease-out;
  }

  .feedback-spinner {
    width: 9px;
    height: 9px;
    border: 2px solid var(--accent);
    border-top-color: transparent;
    border-radius: 50%;
    animation: spin 700ms linear infinite;
  }

  .target-indicator {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.4rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    background: var(--accent-tint);
    border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
    color: var(--accent);
    font-size: 0.8rem;
    font-weight: 600;
    margin-left: auto;
  }

  .target-indicator.classic {
    background: var(--warning-tint);
    border-color: color-mix(in srgb, var(--warning) 35%, transparent);
    color: var(--warning);
  }

  .indicator-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent);
    transition: transform var(--fast, 150ms);
  }

  .indicator-dot.classic {
    background: var(--warning);
  }

  .indicator-dot.pulsing {
    animation: pulseDot 1s ease-in-out infinite alternate;
  }

  .indicator-text {
    white-space: nowrap;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  @keyframes fadeIn {
    from {
      opacity: 0;
      transform: translateY(-2px);
    }
    to {
      opacity: 1;
      transform: translateY(0);
    }
  }

  @keyframes pulseDot {
    from {
      opacity: 0.4;
      transform: scale(0.85);
    }
    to {
      opacity: 1;
      transform: scale(1.25);
    }
  }

  /* Responsive reflow */
  @media (max-width: 860px) {
    .flavour-selector-wrap,
    .target-indicator {
      margin-left: 0;
    }
  }

  @media (max-width: 640px) {
    .wago-toolbar {
      gap: 0.5rem;
    }

    .search-box {
      flex: 1 1 100%;
      min-width: 100%;
    }

    .toolbar-select {
      flex: 1 1 calc(50% - 0.25rem);
      min-width: 120px;
    }

    .btn-primary {
      flex: 0 0 auto;
    }

    .flavour-selector-wrap {
      flex: 1 1 100%;
      justify-content: flex-start;
      margin-left: 0;
      padding-top: 0.25rem;
    }

    .flavour-select {
      flex: 1 1 auto;
    }
  }
</style>
