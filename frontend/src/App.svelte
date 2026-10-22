<script lang="ts">
  import { invoke } from '@tauri-apps/api/core';

  interface Addon {
    id: string;
    flavour: string;
    name: string | null;
    author: string | null;
    source: string | null;
    version: string | null;
    project_id: number | null;
    file_id: string | number | null;
    file_name: string | null;
    folders: string[];
    installed_at: string | null;
    adopted: boolean;
    ignore_updates: boolean;
    pinned_file_id: string | number | null;
    release_type: number | null;
  }

  interface Flavour {
    id: string;
    folder: string;
    label: string;
    product: string | null;
    installed: boolean;
  }

  interface AppInfo {
    name: string;
    version: string;
    is_dev: boolean;
    identifier: string;
  }

  let appInfo = $state<AppInfo | null>(null);
  let flavours = $state<Flavour[]>([]);
  let activeFlavour = $state<string>('retail');
  let addons = $state<Addon[]>([]);
  let loading = $state<boolean>(true);
  let error = $state<string | null>(null);

  async function loadData() {
    loading = true;
    error = null;
    try {
      try {
        appInfo = await invoke<AppInfo>('get_app_info');
      } catch {
        appInfo = {
          name: 'Furphy Dev',
          version: '2.0.0-dev',
          is_dev: true,
          identifier: 'krenzcreative.furphy.addonmanager.dev',
        };
      }

      try {
        const res = await invoke<Flavour[]>('get_flavours');
        flavours = res;
        if (flavours.length > 0 && !flavours.some(f => f.id === activeFlavour)) {
          activeFlavour = flavours[0].id;
        }
      } catch {
        flavours = [{ id: 'retail', folder: '_retail_', label: 'Retail', product: null, installed: true }];
      }

      await fetchAddons(activeFlavour);
    } catch (err: unknown) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      loading = false;
    }
  }

  async function fetchAddons(flavourId: string) {
    try {
      addons = await invoke<Addon[]>('get_addons', { flavour: flavourId });
    } catch (err: unknown) {
      console.warn('Could not fetch addons:', err);
      addons = [];
    }
  }

  function handleFlavourChange(flavourId: string) {
    activeFlavour = flavourId;
    fetchAddons(flavourId);
  }

  loadData();
</script>

<main class="app-container">
  <header class="app-header">
    <div class="brand-group">
      <h1 class="app-title">{appInfo?.name ?? 'Furphy'}</h1>
      <span class="badge version-badge">{appInfo?.version ?? '2.0.0'}</span>
      {#if appInfo?.is_dev}
        <span class="badge dev-badge">DEV</span>
      {/if}
    </div>
    <div class="header-meta">
      <span class="identifier-text">{appInfo?.identifier ?? ''}</span>
    </div>
  </header>

  <div class="flavour-bar">
    <div class="flavour-pills" role="tablist">
      {#each flavours as fl (flavour.id)}
        <button
          type="button"
          role="tab"
          aria-selected={activeFlavour === fl.id}
          class="flavour-pill"
          class:active={activeFlavour === fl.id}
          onclick={() => handleFlavourChange(fl.id)}
        >
          {fl.label}
        </button>
      {/each}
    </div>
    <div class="addon-count">
      <strong>{addons.length}</strong> addons installed
    </div>
  </div>

  <section class="addons-content">
    {#if loading}
      <div class="status-panel">
        <p>Loading addons from database...</p>
      </div>
    {:else if error}
      <div class="status-panel error-panel">
        <p>Error: {error}</p>
      </div>
    {:else if addons.length === 0}
      <div class="status-panel empty-panel">
        <h3>No addons managed in {activeFlavour} yet</h3>
        <p>Import from v1 or add new addons to get started.</p>
      </div>
    {:else}
      <div class="table-container">
        <table class="addon-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Version</th>
              <th>Author</th>
              <th>Source</th>
              <th>Folders</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {#each addons as addon (addon.id)}
              <tr>
                <td class="name-col">
                  <strong>{addon.name ?? addon.id}</strong>
                </td>
                <td class="version-col">{addon.version ?? '—'}</td>
                <td class="author-col">{addon.author ?? '—'}</td>
                <td class="source-col">
                  <span class="source-tag source-{addon.source ?? 'cf'}">
                    {addon.source ?? 'curseforge'}
                  </span>
                </td>
                <td class="folders-col">
                  <span class="folders-count" title={addon.folders.join(', ')}>
                    {addon.folders.length} folder{addon.folders.length === 1 ? '' : 's'}
                  </span>
                </td>
                <td class="status-col">
                  {#if addon.pinned_file_id}
                    <span class="status-pill pill-pinned">Pinned</span>
                  {:else if addon.ignore_updates}
                    <span class="status-pill pill-ignored">Ignored</span>
                  {:else if addon.adopted}
                    <span class="status-pill pill-adopted">Adopted</span>
                  {:else}
                    <span class="status-pill pill-managed">Managed</span>
                  {/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>
</main>

<style>
  :global(:root) {
    --bg-base: #120e1a;
    --bg-surface: #1a1424;
    --bg-subtle: #251c31;
    --border-subtle: #3a2e4d;
    --text-primary: #f3ece0;
    --text-muted: #b0a0b8;
    --accent: #ffa552;
    --accent-glow: rgba(255, 165, 82, 0.15);
  }

  :global(body) {
    margin: 0;
    padding: 0;
    background-color: var(--bg-base);
    color: var(--text-primary);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    user-select: none;
  }

  .app-container {
    display: flex;
    flex-direction: column;
    height: 100vh;
    box-sizing: border-box;
  }

  .app-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem 1.5rem;
    background: var(--bg-surface);
    border-bottom: 1px solid var(--border-subtle);
  }

  .brand-group {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .app-title {
    margin: 0;
    font-size: 1.25rem;
    font-weight: 700;
    letter-spacing: -0.01em;
  }

  .badge {
    font-size: 0.75rem;
    padding: 0.15rem 0.5rem;
    border-radius: 9999px;
    font-weight: 600;
  }

  .version-badge {
    background: var(--bg-subtle);
    color: var(--text-muted);
  }

  .dev-badge {
    background: rgba(255, 75, 75, 0.2);
    color: #ff6b6b;
    border: 1px solid rgba(255, 75, 75, 0.4);
  }

  .identifier-text {
    font-size: 0.8rem;
    color: var(--text-muted);
    font-family: monospace;
  }

  .flavour-bar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.75rem 1.5rem;
    background: var(--bg-surface);
    border-bottom: 1px solid var(--border-subtle);
  }

  .flavour-pills {
    display: flex;
    gap: 0.5rem;
  }

  .flavour-pill {
    background: var(--bg-subtle);
    color: var(--text-muted);
    border: 1px solid transparent;
    padding: 0.35rem 0.85rem;
    border-radius: 6px;
    cursor: pointer;
    font-size: 0.85rem;
    font-weight: 500;
    transition: all 0.15s ease;
  }

  .flavour-pill:hover {
    color: var(--text-primary);
    background: var(--border-subtle);
  }

  .flavour-pill.active {
    background: var(--accent);
    color: #100b16;
    font-weight: 600;
  }

  .addon-count {
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .addons-content {
    flex: 1;
    overflow-y: auto;
    padding: 1.5rem;
  }

  .table-container {
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    overflow: hidden;
  }

  .addon-table {
    width: 100%;
    border-collapse: collapse;
    text-align: left;
    font-size: 0.9rem;
  }

  .addon-table th {
    background: var(--bg-subtle);
    padding: 0.75rem 1rem;
    font-weight: 600;
    color: var(--text-muted);
    border-bottom: 1px solid var(--border-subtle);
  }

  .addon-table td {
    padding: 0.75rem 1rem;
    border-bottom: 1px solid var(--border-subtle);
  }

  .addon-table tr:last-child td {
    border-bottom: none;
  }

  .source-tag {
    font-size: 0.75rem;
    padding: 0.15rem 0.45rem;
    border-radius: 4px;
    background: var(--bg-subtle);
    text-transform: capitalize;
  }

  .status-pill {
    font-size: 0.75rem;
    padding: 0.2rem 0.5rem;
    border-radius: 9999px;
  }

  .pill-managed {
    background: rgba(80, 200, 120, 0.15);
    color: #50c878;
  }

  .pill-pinned {
    background: rgba(255, 165, 0, 0.15);
    color: #ffa500;
  }

  .pill-ignored {
    background: rgba(160, 160, 160, 0.15);
    color: #a0a0a0;
  }

  .pill-adopted {
    background: rgba(100, 149, 237, 0.15);
    color: #6495ed;
  }

  .status-panel {
    text-align: center;
    padding: 3rem 1rem;
    color: var(--text-muted);
  }
</style>
