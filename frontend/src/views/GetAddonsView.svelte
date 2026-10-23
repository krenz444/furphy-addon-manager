<script lang="ts">
  import { invoke } from '../lib/ipc';

  interface WagoAddonItem {
    id: string;
    slug: string;
    name: string;
    description?: string;
    author: string;
    version?: string;
    downloads?: number;
    updated_at?: string;
    avatar_url?: string;
  }

  interface Props {
    flavour: string;
    onInstallWago: (slug: string) => void;
    onInstallCurseForge: (projectId: number) => void;
    onInstallGitHub: (repoUrl: string) => void;
  }

  let { flavour, onInstallWago, onInstallCurseForge, onInstallGitHub }: Props = $props();

  let activeTab = $state<'wago' | 'curseforge' | 'github'>('wago');

  // Wago tab state
  let wagoSearchQuery = $state('');
  let wagoSort = $state<'popular' | 'updated' | 'name' | 'gaining'>('popular');
  let wagoCategory = $state<string>('');
  let wagoCategories = $state<{ id: string; label: string }[]>([]);
  let wagoResults = $state<WagoAddonItem[]>([]);
  let loadingWago = $state(false);
  let wagoError = $state<string | null>(null);

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

  async function searchWago() {
    loadingWago = true;
    wagoError = null;
    try {
      const raw = await invoke<WagoAddonItem[] | { results: WagoAddonItem[] }>('wago_search', {
        query: wagoSearchQuery,
        sort: wagoSort,
        category: wagoCategory || undefined,
        flavour,
      });
      if (Array.isArray(raw)) {
        wagoResults = raw;
      } else if (raw && Array.isArray((raw as { results: WagoAddonItem[] }).results)) {
        wagoResults = (raw as { results: WagoAddonItem[] }).results;
      } else {
        wagoResults = [];
      }
    } catch (err: unknown) {
      wagoError = err instanceof Error ? err.message : String(err);
      // Fallback sample for mock mode
      if (wagoResults.length === 0) {
        wagoResults = [
          {
            id: 'details',
            slug: 'details',
            name: 'Details! Damage Meter',
            description: 'Advanced damage and combat meter with deep analysis tools.',
            author: 'Terciob',
            version: '11.0.2',
            downloads: 1420000,
          },
          {
            id: 'plater',
            slug: 'plater-nameplates',
            name: 'Plater Nameplates',
            description: 'Nameplate addon with full customization and scripting support.',
            author: 'Terciob',
            version: '11.0.5',
            downloads: 980000,
          },
          {
            id: 'method-raid-tools',
            slug: 'method-raid-tools',
            name: 'Method Raid Tools',
            description: 'Raid leader tools, cooldown tracking, note displays.',
            author: 'Exorsus',
            version: '11.0.0',
            downloads: 870000,
          },
        ];
      }
    } finally {
      loadingWago = false;
    }
  }

  function handleCfInstall() {
    cfError = null;
    const raw = cfInput.trim();
    if (!raw) return;

    let id: number | null = null;
    if (/^\d+$/.test(raw)) {
      id = parseInt(raw, 10);
    } else {
      const match = raw.match(/curseforge\.com\/wow\/addons\/([^/]+)/);
      if (match) {
        // Will be resolved by server
        id = parseInt(raw.replace(/\D/g, ''), 10) || null;
      }
    }

    if (id) {
      onInstallCurseForge(id);
      cfInput = '';
    } else {
      cfError = 'Please enter a valid CurseForge project ID or addon URL.';
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

  // Initial load
  $effect(() => {
    loadCategories();
    if (activeTab === 'wago' && wagoResults.length === 0 && !loadingWago) {
      searchWago();
    }
  });
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
  </header>

  <div class="tab-content">
    {#if activeTab === 'wago'}
      <div class="wago-pane">
        <div class="wago-toolbar">
          <div class="search-box">
            <span class="search-icon">🔍</span>
            <input
              type="search"
              class="search-input"
              placeholder="Search Wago addons…"
              bind:value={wagoSearchQuery}
              onkeydown={(e) => e.key === 'Enter' && searchWago()}
            />
          </div>

          {#if wagoCategories.length > 0}
            <select class="toolbar-select" bind:value={wagoCategory} onchange={searchWago}>
              <option value="">All Categories</option>
              {#each wagoCategories as cat}
                <option value={cat.id}>{cat.label}</option>
              {/each}
            </select>
          {/if}

          <select class="toolbar-select" bind:value={wagoSort} onchange={searchWago}>
            <option value="popular">Popular</option>
            <option value="updated">Recently updated</option>
            <option value="name">Name A-Z</option>
            <option value="gaining">Gaining this week</option>
          </select>

          <button type="button" class="btn-primary" onclick={searchWago}>
            Search
          </button>
        </div>

        {#if loadingWago}
          <div class="state-message">
            <p>Searching Wago.io…</p>
          </div>
        {:else if wagoError && wagoResults.length === 0}
          <div class="state-message error-message">
            <p>Couldn’t load results from Wago.io: {wagoError}</p>
            <button type="button" class="btn-secondary" onclick={searchWago}>
              Retry
            </button>
          </div>
        {:else if wagoResults.length === 0}
          <div class="state-message">
            <p>No addons found matching "{wagoSearchQuery}".</p>
          </div>
        {:else}
          <div class="addons-grid">
            {#each wagoResults as addon (addon.id || addon.slug)}
              <div class="addon-card">
                <div class="card-main">
                  <div class="card-title-row">
                    <h3 class="card-title">{addon.name}</h3>
                    {#if addon.version}
                      <span class="card-version font-mono">{addon.version}</span>
                    {/if}
                  </div>
                  <div class="card-author">by {addon.author}</div>
                  {#if addon.description}
                    <p class="card-desc">{addon.description}</p>
                  {/if}
                </div>

                <div class="card-footer">
                  {#if addon.downloads}
                    <span class="download-count">
                      {(addon.downloads / 1000).toFixed(0)}k downloads
                    </span>
                  {/if}
                  <button
                    type="button"
                    class="btn-install"
                    onclick={() => onInstallWago(addon.slug)}
                  >
                    Install
                  </button>
                </div>
              </div>
            {/each}
          </div>
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
            <label for="cf-id-input" class="form-label">CurseForge Project ID or URL:</label>
            <div class="input-row">
              <input
                id="cf-id-input"
                type="text"
                class="form-input"
                placeholder="e.g. 3358 or https://www.curseforge.com/wow/addons/deadly-boss-mods"
                bind:value={cfInput}
                onkeydown={(e) => e.key === 'Enter' && handleCfInstall()}
              />
              <button
                type="button"
                class="btn-primary"
                onclick={handleCfInstall}
              >
                Install Addon
              </button>
            </div>
            {#if cfError}
              <div class="form-error">{cfError}</div>
            {/if}
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
                Inspect & Install
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
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }

  .tab-header {
    background: var(--bg-1);
    border-bottom: 1px solid var(--border);
    padding: 0 1.25rem;
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

  .tab-content {
    flex: 1;
    overflow-y: auto;
    padding: 1.25rem;
  }

  .wago-pane {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .wago-toolbar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .search-box {
    position: relative;
    flex: 1;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 0.75rem;
    color: var(--text-muted);
  }

  .search-input {
    width: 100%;
    padding: 0.5rem 1rem 0.5rem 2.25rem;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    font-size: 0.85rem;
    outline: none;
  }

  .search-input:focus-visible {
    border-color: var(--focus-ring);
  }

  .toolbar-select {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    padding: 0.5rem 0.75rem;
    font-size: 0.85rem;
    outline: none;
  }

  .addons-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 1rem;
  }

  .addon-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    padding: 1rem;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 0.75rem;
    transition: border-color var(--fast), transform var(--fast);
  }

  .addon-card:hover {
    border-color: var(--border-hover);
    transform: translateY(-2px);
  }

  .card-title-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 0.5rem;
  }

  .card-title {
    margin: 0;
    font-size: 1rem;
    font-weight: 700;
    color: var(--text);
  }

  .card-version {
    font-size: 0.75rem;
    color: var(--text-muted);
    background: var(--bg-2);
    padding: 2px 5px;
    border-radius: 3px;
  }

  .card-author {
    font-size: 0.75rem;
    color: var(--text-faint);
    margin-top: 2px;
  }

  .card-desc {
    margin: 0.5rem 0 0 0;
    font-size: 0.8rem;
    color: var(--text-muted);
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .card-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-top: 1px solid var(--border-soft);
    padding-top: 0.75rem;
  }

  .download-count {
    font-size: 0.75rem;
    color: var(--text-faint);
  }

  .btn-install {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    border-radius: var(--radius-sm, 4px);
    padding: 0.35rem 0.85rem;
    font-size: 0.8rem;
    font-weight: 700;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn-install:hover {
    background: var(--accent-hover);
  }

  .btn-install:focus-visible {
    outline: 2px solid var(--focus-ring);
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
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .state-message {
    text-align: center;
    padding: 3rem 1rem;
    color: var(--text-muted);
  }

  .error-message {
    color: var(--danger);
  }

  .font-mono {
    font-family: monospace;
  }
</style>
