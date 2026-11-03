<script lang="ts">
  import { tick } from 'svelte';
  import { invoke, isMockMode, wagoSearch } from '../lib/ipc';
  import type { Addon, Flavour, WagoAddonItem, WagoSortOption } from '../lib/types';
  import { debounce } from '../lib/hooks/useDebounce';
  import WagoToolbar from '../components/addons/WagoToolbar.svelte';
  import WagoAddonCard from '../components/addons/WagoAddonCard.svelte';
  import WagoCardSkeleton from '../components/addons/WagoCardSkeleton.svelte';
  import WagoListFooter from '../components/addons/WagoListFooter.svelte';
  import InfiniteScrollTrigger from '../components/common/InfiniteScrollTrigger.svelte';

  interface Props {
    flavour: string;
    flavours?: Flavour[];
    flavourLabel?: string;
    initialSearchQuery?: string;
    installedAddons?: Addon[];
    onSelectFlavour?: (flavour: string) => void;
    onInstallWago: (slug: string, targetFlavour?: string) => void;
    onInstallCurseForge: (target: string, targetFlavour?: string) => void;
    onInstallGitHub: (repoUrl: string, targetFlavour?: string) => void;
  }

  let {
    flavour,
    flavours = [],
    flavourLabel,
    initialSearchQuery = '',
    installedAddons = [],
    onSelectFlavour,
    onInstallWago,
    onInstallCurseForge,
    onInstallGitHub,
  }: Props = $props();

  let activeFlavourObj = $derived(
    flavours.find(f => f.id === flavour)
  );

  let displayLabel = $derived(
    flavourLabel || activeFlavourObj?.label || flavour
  );

  let activeTab = $state<'wago' | 'curseforge' | 'github'>('wago');

  // Wago tab state
  let wagoSearchQuery = $state('');
  let wagoSort = $state<WagoSortOption>('popular');
  let wagoCategory = $state<string>('');
  let wagoCategories = $state<{ id: string; label: string }[]>([]);
  let wagoResults = $state<WagoAddonItem[]>([]);
  let wagoPage = $state(1);
  let totalCount = $state(0);
  let hasMore = $state(true);
  let loadingWago = $state(false);
  let loadingMore = $state(false);
  let wagoError = $state<string | null>(null);
  let footerError = $state<string | null>(null);
  let scrollContainerEl = $state<HTMLDivElement | null>(null);

  // CurseForge tab state
  let cfInput = $state('');
  let cfError = $state<string | null>(null);

  // GitHub tab state
  let githubInput = $state('');
  let githubError = $state<string | null>(null);

  async function loadCategories() {
    try {
      const cats = await invoke<{ id: string; label: string }[]>('wago_categories');
      if (cats && Array.isArray(cats)) {
        wagoCategories = cats;
      }
    } catch {
      // Mock fallback
    }
  }

  async function searchWago(isFirstPage: boolean = true) {
    if (isFirstPage) {
      loadingWago = true;
      wagoError = null;
    } else {
      loadingMore = true;
      footerError = null;
    }

    try {
      const raw = await wagoSearch({
        query: wagoSearchQuery,
        sort: wagoSort,
        category: wagoCategory || undefined,
        page: wagoPage,
        flavour,
      });

      const newItems = raw?.results || [];
      totalCount = raw?.total ?? 0;
      hasMore = Boolean(raw?.has_more);

      if (isFirstPage) {
        wagoResults = newItems;
      } else {
        const existingSlugs = new Set(wagoResults.map((r) => r.slug));
        const uniqueNew = newItems.filter((r) => !existingSlugs.has(r.slug));
        wagoResults = [...wagoResults, ...uniqueNew];
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (isFirstPage) {
        wagoError = msg;
        if (isMockMode()) {
          wagoResults = [
            {
              id: 'details',
              slug: 'details-damage-meter-standalone',
              name: 'Details! Damage Meter',
              description: 'Advanced damage and combat meter with deep analysis tools.',
              author: 'Terciob',
              version: '11.0.2',
              downloads: 1420000,
              wago_url: 'https://addons.wago.io/addons/details-damage-meter-standalone',
              game_version: 'retail',
            },
            {
              id: 'plater',
              slug: 'plater-nameplates',
              name: 'Plater Nameplates',
              description: 'Nameplate addon with full customization and scripting support.',
              author: 'Terciob',
              version: '11.0.5',
              downloads: 980000,
              wago_url: 'https://addons.wago.io/addons/plater-nameplates',
              game_version: 'retail',
            },
            {
              id: 'method-raid-tools',
              slug: 'method-raid-tools',
              name: 'Method Raid Tools',
              description: 'Raid leader tools, cooldown tracking, note displays.',
              author: 'Exorsus',
              version: '11.0.0',
              downloads: 870000,
              wago_url: 'https://addons.wago.io/addons/method-raid-tools',
              game_version: 'retail',
            },
          ];
        } else {
          wagoResults = [];
        }
      } else {
        footerError = msg;
      }
    } finally {
      if (isFirstPage) {
        loadingWago = false;
      } else {
        loadingMore = false;
      }
      tick().then(() => {
        checkAutoFill();
      });
    }
  }

  const debouncedSearch = debounce(() => {
    wagoPage = 1;
    wagoResults = [];
    hasMore = true;
    searchWago(true);
  }, 300);

  function handleQueryChange(newQuery: string) {
    wagoSearchQuery = newQuery;
    debouncedSearch();
  }

  function handleTriggerSearch() {
    debouncedSearch.cancel();
    wagoPage = 1;
    wagoResults = [];
    hasMore = true;
    searchWago(true);
  }

  function handleClearQuery() {
    debouncedSearch.cancel();
    wagoSearchQuery = '';
    wagoPage = 1;
    wagoResults = [];
    hasMore = true;
    searchWago(true);
  }

  function handleCategoryChange(newCat: string) {
    wagoCategory = newCat;
    handleTriggerSearch();
  }

  function handleSortChange(newSort: WagoSortOption) {
    wagoSort = newSort;
    handleTriggerSearch();
  }

  function checkAutoFill() {
    if (
      scrollContainerEl &&
      scrollContainerEl.scrollHeight <= scrollContainerEl.clientHeight + 150 &&
      hasMore &&
      !loadingMore &&
      !loadingWago &&
      wagoResults.length > 0 &&
      wagoPage < 10
    ) {
      handleLoadMore();
    }
  }

  function handleContainerScroll() {
    if (!scrollContainerEl || loadingWago || loadingMore || !hasMore) return;
    const { scrollTop, scrollHeight, clientHeight } = scrollContainerEl;
    if (scrollHeight - scrollTop - clientHeight < 400) {
      handleLoadMore();
    }
  }

  function handleRetryLoadMore() {
    if (loadingWago || loadingMore || !hasMore) return;
    searchWago(false);
  }

  function handleLoadMore() {
    if (loadingWago || loadingMore || !hasMore) return;
    wagoPage += 1;
    searchWago(false);
  }

  function isAddonInstalled(slug: string, name: string): boolean {
    if (!installedAddons || installedAddons.length === 0) return false;
    const cleanSlug = slug.toLowerCase().trim();
    const cleanName = name.toLowerCase().trim();
    return installedAddons.some((a) => {
      const aSlug = a.wago_slug?.toLowerCase().trim();
      const aName = a.name?.toLowerCase().trim();
      const aId = a.id?.toLowerCase().trim();
      return (
        (aSlug && aSlug === cleanSlug) ||
        (aName && aName === cleanName) ||
        (aId && aId === cleanSlug)
      );
    });
  }

  // Reactive search controller: reactively triggers search when activeTab, flavour, query, category, or sort changes
  let activeSearchKey = '';

  $effect(() => {
    if (activeTab !== 'wago') return;

    // Track all query dependencies reactively
    const targetFlavour = flavour;
    const query = wagoSearchQuery.trim();
    const category = wagoCategory;
    const sort = wagoSort;
    const key = `${targetFlavour}|${query}|${category}|${sort}`;

    if (key !== activeSearchKey) {
      activeSearchKey = key;
      wagoPage = 1;
      wagoResults = [];
      hasMore = true;
      searchWago(true);
    }
  });

  $effect(() => {
    loadCategories();
  });

  $effect(() => {
    if (initialSearchQuery && initialSearchQuery !== wagoSearchQuery) {
      activeTab = 'wago';
      wagoSearchQuery = initialSearchQuery;
    }
  });

  function handleCfInstall() {
    cfError = null;
    const raw = cfInput.trim();
    if (!raw) return;

    onInstallCurseForge(raw);
    cfInput = '';
  }

  function openCurseForgeBrowser(query?: string) {
    const raw = (query !== undefined ? query : cfInput).trim();
    let targetUrl: string;

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      targetUrl = raw;
    } else if (raw.length > 0 && !/^\d+$/.test(raw)) {
      targetUrl = `https://www.curseforge.com/wow/search?class=addons&search=${encodeURIComponent(raw)}`;
    } else if (/^\d+$/.test(raw)) {
      targetUrl = `https://www.curseforge.com/projects/${raw}`;
    } else {
      targetUrl = 'https://www.curseforge.com/wow/search?class=addons';
    }

    invoke('open_target', { what: 'url', args: [targetUrl] }).catch((err: unknown) => {
      console.error('Failed to open CurseForge search in browser:', err);
    });
  }

  function handleCfKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      const trimmed = cfInput.trim();
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://') || /^\d+$/.test(trimmed)) {
        handleCfInstall();
      } else if (trimmed) {
        openCurseForgeBrowser(trimmed);
      } else {
        handleCfInstall();
      }
    }
  }

  function handleGithubInstall() {
    githubError = null;
    const raw = githubInput.trim();
    if (!raw) return;
    if (!raw.includes('github.com')) {
      githubError = 'Please enter a valid GitHub repository URL (e.g. https://github.com/owner/repo).';
      return;
    }
    onInstallGitHub(raw);
    githubInput = '';
  }


</script>

<div class="get-addons-view">
  <header class="tab-header">
    <div class="tabs" role="tablist">
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === 'wago'}
        class="tab-btn"
        class:active={activeTab === 'wago'}
        onclick={() => (activeTab = 'wago')}
      >
        Wago.io
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === 'curseforge'}
        class="tab-btn"
        class:active={activeTab === 'curseforge'}
        onclick={() => (activeTab = 'curseforge')}
      >
        CurseForge
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === 'github'}
        class="tab-btn"
        class:active={activeTab === 'github'}
        onclick={() => (activeTab = 'github')}
      >
        GitHub Link
      </button>
    </div>

    <div class="target-client-bar">
      <span class="target-client-label">Target:</span>
      {#if flavours && flavours.length > 1}
        <select
          class="target-client-select"
          value={flavour}
          onchange={(e) => onSelectFlavour?.((e.target as HTMLSelectElement).value)}
          title="Select game version to install addons for"
        >
          {#each flavours as fl (fl.id)}
            <option value={fl.id}>
              {fl.label} {fl.custom_root ? '(Custom Path)' : `(${fl.folder})`}
            </option>
          {/each}
        </select>
      {:else}
        <span class="target-client-pill">
          {displayLabel}
          {#if activeFlavourObj?.custom_root}
            <span class="custom-tag">Custom</span>
          {/if}
        </span>
      {/if}
    </div>
  </header>

  {#if activeTab === 'wago'}
    <div class="wago-toolbar-strip">
      <WagoToolbar
        searchQuery={wagoSearchQuery}
        selectedCategory={wagoCategory}
        selectedSort={wagoSort}
        categories={wagoCategories}
        loading={loadingWago}
        destinationLabel={displayLabel}
        isClassicOrForever={flavour === 'forever' || flavour === 'classic' || flavour === 'classic_era'}
        onQueryChange={handleQueryChange}
        onCategoryChange={handleCategoryChange}
        onSortChange={handleSortChange}
        onTriggerSearch={handleTriggerSearch}
        onClearQuery={handleClearQuery}
      />
    </div>
  {/if}

  <div class="tab-content" bind:this={scrollContainerEl} onscroll={handleContainerScroll}>
    {#if activeTab === 'wago'}
      <div class="wago-pane">
        {#if loadingWago && wagoResults.length === 0}
          <WagoCardSkeleton count={8} />
        {:else if wagoError && wagoResults.length === 0}
          <div class="state-message error-message">
            <p>Couldn’t load results from Wago.io: {wagoError}</p>
            <button type="button" class="btn-secondary" onclick={handleTriggerSearch}>Retry</button>
          </div>
        {:else if !loadingWago && wagoResults.length === 0}
          <div class="state-message">
            <p>No addons found matching "{wagoSearchQuery}" for {displayLabel}.</p>
          </div>
        {:else}
          <div class="addons-grid">
            {#each wagoResults as addon (addon.id || addon.slug)}
              <WagoAddonCard
                {addon}
                destinationLabel={displayLabel}
                isInstalled={isAddonInstalled(addon.slug, addon.name)}
                onInstall={(slug) => onInstallWago(slug, flavour)}
              />
            {/each}
          </div>

          <InfiniteScrollTrigger
            onTrigger={handleLoadMore}
            disabled={!hasMore || loadingMore || loadingWago}
            root={scrollContainerEl}
          />

          <WagoListFooter
            {loadingMore}
            {hasMore}
            resultsCount={wagoResults.length}
            error={footerError}
            onLoadMore={handleLoadMore}
            onRetry={handleRetryLoadMore}
          />
        {/if}
      </div>

    {:else if activeTab === 'curseforge'}
      <div class="cf-pane">
        <div class="cf-card">
          <h2>Install from CurseForge</h2>
          <p class="cf-desc">
            Enter a CurseForge project ID or paste an addon URL directly. Furphy will download and install it safely without needing third-party desktop wrappers.
          </p>

          <div class="cf-form">
            <label for="cf-id-input" class="form-label">CurseForge Project ID, URL, or Search:</label>
            <div class="input-row">
              <input
                id="cf-id-input"
                type="text"
                class="form-input"
                placeholder="e.g. 3358, addon URL, or search term"
                bind:value={cfInput}
                onkeydown={handleCfKeydown}
              />
              <button
                type="button"
                class="btn-primary"
                onclick={handleCfInstall}
              >
                Install to {displayLabel}
              </button>
              <button
                type="button"
                class="btn-secondary"
                title="Open search page on CurseForge in your default web browser"
                onclick={() => openCurseForgeBrowser()}
              >
                Search in Browser ↗
              </button>
            </div>
            {#if cfError}
              <div class="form-error">{cfError}</div>
            {/if}
          </div>

          <div class="cf-search-callout">
            <div class="callout-content">
              <h4>Browse & Search on CurseForge</h4>
              <p>
                Browse addons directly on CurseForge's search page in your browser. Click <strong>Install</strong> on any addon page to send it to Furphy, or copy the URL back here.
              </p>
            </div>
            <button
              type="button"
              class="btn-secondary btn-open-search"
              onclick={() => openCurseForgeBrowser()}
            >
              Open CurseForge Search ↗
            </button>
          </div>

          <div class="cf-tips">
            <h4>Direct Browser Integration</h4>
            <p>
              You can also browse <code>curseforge.com</code> in any browser and click <strong>Install</strong> on any addon page. Furphy will intercept the link with your permission.
            </p>
          </div>
        </div>
      </div>

    {:else if activeTab === 'github'}
      <div class="github-pane">
        <div class="github-card">
          <h2>Install from GitHub</h2>
          <p class="github-desc">
            Furphy can install addons published directly on GitHub releases or zipballs.
          </p>

          <div class="github-form">
            <label for="gh-url-input" class="form-label">GitHub Repository URL:</label>
            <div class="input-row">
              <input
                id="gh-url-input"
                type="url"
                class="form-input"
                placeholder="https://github.com/owner/repository"
                bind:value={githubInput}
                onkeydown={(e) => e.key === 'Enter' && handleGithubInstall()}
              />
              <button
                type="button"
                class="btn-primary"
                onclick={handleGithubInstall}
              >
                Inspect & Install to {displayLabel}
              </button>
            </div>
            {#if githubError}
              <div class="form-error">{githubError}</div>
            {/if}
          </div>

          <div class="github-note">
            <p>
              Note: For private repositories or to avoid GitHub API rate limits, configure a personal access token under <strong>Settings → Advanced → GitHub Addons</strong>.
            </p>
          </div>
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  .get-addons-view {
    flex: 1;
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
    overflow: hidden;
  }

  .tab-header {
    flex-shrink: 0;
    background: var(--bg-1);
    border-bottom: 1px solid var(--border);
    padding: 0 1.25rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.5rem;
  }

  .target-client-bar {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .target-client-label {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-muted);
  }

  .target-client-select {
    background: var(--bg-2);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 0.25rem 0.6rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 500;
  }

  .target-client-select:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .target-client-pill {
    background: var(--bg-2);
    border: 1px solid var(--border);
    padding: 0.25rem 0.6rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--text);
    display: flex;
    align-items: center;
    gap: 0.35rem;
  }

  .custom-tag {
    font-size: 0.65rem;
    padding: 0.05rem 0.3rem;
    border-radius: 3px;
    background: rgba(59, 130, 246, 0.15);
    color: var(--accent);
    text-transform: uppercase;
  }

  .tabs {
    display: flex;
    gap: 0.5rem;
  }

  .tab-btn {
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    color: var(--text-muted);
    font-size: 0.875rem;
    font-weight: 600;
    padding: 0.85rem 1rem;
    cursor: pointer;
    transition: color var(--fast), border-color var(--fast);
  }

  .tab-btn:hover {
    color: var(--text);
  }

  .tab-btn.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
  }

  .tab-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .wago-toolbar-strip {
    flex-shrink: 0;
    background: var(--bg-0);
    border-bottom: 1px solid var(--border);
    padding: 0.75rem 1.25rem;
  }

  .tab-content {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 1.25rem;
    scrollbar-gutter: stable;
  }

  .wago-pane {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    min-height: min-content;
  }

  .addons-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 1rem;
  }

  .cf-pane, .github-pane {
    display: flex;
    justify-content: center;
    padding: 2rem 1rem;
  }

  .cf-card, .github-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-lg, 12px);
    padding: 2rem;
    max-width: 580px;
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
  }

  .cf-card h2, .github-card h2 {
    margin: 0;
    font-size: 1.25rem;
    color: var(--text);
  }

  .cf-desc, .github-desc {
    margin: 0;
    font-size: 0.9rem;
    color: var(--text-muted);
    line-height: 1.45;
  }

  .form-label {
    display: block;
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--text);
    margin-bottom: 0.5rem;
  }

  .input-row {
    display: flex;
    gap: 0.75rem;
  }

  .form-input {
    flex: 1;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.55rem 0.85rem;
    color: var(--text);
    font-size: 0.9rem;
    outline: none;
  }

  .form-input:focus-visible {
    border-color: var(--focus-ring);
  }

  .form-error {
    color: var(--danger);
    font-size: 0.8rem;
    margin-top: 0.4rem;
  }

  .cf-tips, .github-note {
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius, 8px);
    padding: 1rem;
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .cf-tips h4 {
    margin: 0 0 0.4rem 0;
    color: var(--text);
    font-size: 0.9rem;
  }

  .cf-tips p, .github-note p {
    margin: 0;
    line-height: 1.4;
  }

  .cf-tips code {
    background: var(--bg-2);
    padding: 1px 4px;
    border-radius: 3px;
    color: var(--accent);
  }

  .cf-search-callout {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    padding: 1.25rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1.25rem;
  }

  .cf-search-callout .callout-content h4 {
    margin: 0 0 0.35rem 0;
    color: var(--text);
    font-size: 0.95rem;
    font-weight: 600;
  }

  .cf-search-callout .callout-content p {
    margin: 0;
    font-size: 0.85rem;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .btn-open-search {
    flex-shrink: 0;
  }

  @media (max-width: 600px) {
    .cf-search-callout {
      flex-direction: column;
      align-items: flex-start;
    }
  }

  .btn-primary, .btn-secondary {
    border-radius: var(--radius-sm, 4px);
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;
    padding: 0.55rem 1rem;
    transition: background var(--fast);
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    white-space: nowrap;
  }

  .btn-primary:hover {
    background: var(--accent-hover);
  }

  .btn-primary:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    white-space: nowrap;
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .state-message {
    text-align: center;
    padding: 3rem 1rem;
    color: var(--text-muted);
  }

  .error-message {
    color: var(--danger);
  }
</style>
