<script lang="ts">
  import { invoke } from '../../lib/ipc';
  import type { TukuiAddon, InstallOutcome } from '../../lib/types';

  interface Props {
    flavour: string;
    displayLabel: string;
    destinationReason?: string | null;
    onInstallTukui: (slug: string, targetFlavour?: string) => Promise<InstallOutcome>;
  }

  let {
    flavour,
    displayLabel,
    destinationReason = null,
    onInstallTukui,
  }: Props = $props();

  let addons = $state<TukuiAddon[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let installingSlugs = $state<Record<string, boolean>>({});
  let installErrors = $state<Record<string, string>>({});

  async function loadTukuiList() {
    loading = true;
    error = null;
    try {
      const res = await invoke<TukuiAddon[]>('tukui_addons', { flavour });
      addons = res || [];
    } catch (err: unknown) {
      error = err instanceof Error ? err.message : String(err);
      addons = [];
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    // Track flavour so changing the destination reloads the list
    const currentFlavour = flavour;
    loadTukuiList();
  });

  async function handleInstall(slug: string) {
    if (installingSlugs[slug] || Boolean(destinationReason)) return;
    installingSlugs[slug] = true;
    const currentErrors = { ...installErrors };
    delete currentErrors[slug];
    installErrors = currentErrors;

    try {
      const outcome = await onInstallTukui(slug, flavour);
      if (outcome && outcome.ok) {
        addons = addons.map((a) => (a.slug === slug ? { ...a, installed: true } : a));
      } else if (outcome && !outcome.ok) {
        installErrors = { ...installErrors, [slug]: outcome.message };
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      installErrors = { ...installErrors, [slug]: msg };
    } finally {
      const currentBusy = { ...installingSlugs };
      delete currentBusy[slug];
      installingSlugs = currentBusy;
    }
  }

  function openTukuiUrl(url?: string | null) {
    if (!url) return;
    invoke('open_target', { what: 'url', args: [url] }).catch(() => {});
  }
</script>

<div class="tukui-pane">
  {#if loading && addons.length === 0}
    <div class="state-message">
      <div class="spinner" aria-hidden="true"></div>
      <p>Loading Tukui addons...</p>
    </div>
  {:else if error && addons.length === 0}
    <div class="state-message error-message">
      <p>Could not load the Tukui list: {error}</p>
      <button type="button" class="btn-secondary" onclick={loadTukuiList}>
        Retry
      </button>
    </div>
  {:else if !loading && addons.length === 0}
    <div class="state-message">
      <p>No Tukui addons available for {displayLabel}.</p>
    </div>
  {:else}
    <div class="addons-grid">
      {#each addons as addon (addon.slug)}
        {@const isBusy = Boolean(installingSlugs[addon.slug])}
        {@const isDisabled = isBusy || Boolean(destinationReason) || !addon.compatible}
        <article
          class="addon-card"
          class:installed={addon.installed}
          data-testid="tukui-card-{addon.slug}"
        >
          <div class="card-main">
            <div class="card-header">
              <div class="card-title-group">
                <div class="card-title-row">
                  <h3 class="card-title" title={addon.name}>{addon.name}</h3>
                  {#if addon.version}
                    <span class="card-version font-mono">{addon.version}</span>
                  {/if}
                </div>
                <div class="card-subtitle">
                  <span class="card-author">by {addon.author}</span>
                  {#if addon.last_update}
                    <span class="card-updated">Updated {addon.last_update}</span>
                  {/if}
                </div>
              </div>
            </div>

            {#if addon.summary}
              <p class="card-desc">{addon.summary}</p>
            {/if}

            <div class="supported-patches">
              <span class="patches-label">Works with:</span>
              <span class="patches-text">
                {addon.supported_patches && addon.supported_patches.length > 0
                  ? addon.supported_patches.join(', ')
                  : 'all versions'}
              </span>
            </div>
          </div>

          <div class="card-footer">
            <div class="stats-group">
              {#if addon.web_url}
                <button
                  type="button"
                  class="btn-browser-link"
                  onclick={() => openTukuiUrl(addon.web_url)}
                  aria-label={`Open ${addon.name} page on tukui.org in browser`}
                  title="Open on tukui.org in browser"
                >
                  <span aria-hidden="true">↗</span>
                  <span>tukui.org</span>
                </button>
              {/if}
            </div>

            <div class="action-column">
              {#if addon.installed}
                <div class="badge-installed" title={`Already installed in ${displayLabel}`}>
                  <span aria-hidden="true">✓</span>
                  <span>Installed</span>
                </div>
              {:else}
                <button
                  type="button"
                  class="btn-install"
                  data-testid="tukui-install-{addon.slug}"
                  class:busy={isBusy}
                  disabled={isDisabled}
                  onclick={() => handleInstall(addon.slug)}
                  aria-label={`Install ${addon.name} to ${displayLabel}`}
                >
                  {#if isBusy}
                    <span class="btn-spinner" aria-hidden="true"></span>
                    <span>Installing to {displayLabel}...</span>
                  {:else}
                    <span>Install to {displayLabel}</span>
                  {/if}
                </button>
              {/if}

              {#if destinationReason}
                <p class="card-reason" data-testid="tukui-reason-{addon.slug}">
                  {destinationReason}
                </p>
              {:else if !addon.compatible}
                <p class="card-reason" data-testid="tukui-reason-{addon.slug}">
                  {addon.reason || `Not compatible with ${displayLabel}.`}
                </p>
              {/if}

              {#if installErrors[addon.slug]}
                <p class="card-error" role="alert">
                  {installErrors[addon.slug]}
                </p>
              {/if}
            </div>
          </div>
        </article>
      {/each}
    </div>
  {/if}
</div>

<style>
  .tukui-pane {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    min-height: min-content;
    width: 100%;
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
    gap: 0.85rem;
    transition: border-color var(--fast, 150ms), transform var(--fast, 150ms);
  }

  .addon-card:hover {
    border-color: var(--accent);
    transform: translateY(-1px);
  }

  .addon-card.installed {
    border-color: color-mix(in srgb, var(--success) 35%, transparent);
  }

  .card-main {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .card-header {
    display: flex;
    align-items: flex-start;
    gap: 0.75rem;
  }

  .card-title-group {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
    min-width: 0;
    flex: 1;
  }

  .card-title-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .card-title {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .card-version {
    font-size: 0.7rem;
    background: var(--bg-2);
    border: 1px solid var(--border);
    padding: 0.1rem 0.35rem;
    border-radius: var(--radius-sm, 4px);
    color: var(--text-muted);
  }

  .font-mono {
    font-family: monospace;
  }

  .card-subtitle {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.75rem;
    flex-wrap: wrap;
  }

  .card-author {
    color: var(--text-muted);
  }

  .card-updated {
    color: var(--text-faint);
    font-size: 0.7rem;
  }

  .card-desc {
    margin: 0;
    font-size: 0.8rem;
    line-height: 1.35;
    color: var(--text-muted);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .supported-patches {
    display: flex;
    align-items: baseline;
    gap: 0.35rem;
    font-size: 0.75rem;
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-sm, 4px);
    padding: 0.3rem 0.5rem;
  }

  .patches-label {
    font-weight: 600;
    color: var(--text-muted);
    white-space: nowrap;
  }

  .patches-text {
    color: var(--text);
    font-family: monospace;
    font-size: 0.7rem;
    word-break: break-all;
  }

  .card-footer {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    padding-top: 0.65rem;
    border-top: 1px solid var(--border);
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .stats-group {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .btn-browser-link {
    background: none;
    border: none;
    color: var(--text-muted);
    font-size: 0.75rem;
    padding: 0.15rem 0.35rem;
    border-radius: var(--radius-sm, 4px);
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 0.2rem;
    transition: color var(--fast, 150ms), background var(--fast, 150ms);
  }

  .btn-browser-link:hover {
    color: var(--accent);
    background: var(--bg-2);
  }

  .btn-browser-link:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .action-column {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 0.3rem;
  }

  .badge-installed {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--success);
    background: var(--success-tint);
    border: 1px solid color-mix(in srgb, var(--success) 30%, transparent);
    padding: 0.3rem 0.65rem;
    border-radius: var(--radius-sm, 4px);
  }

  .btn-install {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    padding: 0.35rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 600;
    cursor: pointer;
    transition: filter var(--fast, 150ms), transform var(--fast, 150ms);
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
  }

  .btn-install:hover:not(:disabled) {
    filter: brightness(1.1);
  }

  .btn-install:active:not(:disabled) {
    transform: scale(0.98);
  }

  .btn-install:disabled {
    opacity: 0.65;
    cursor: not-allowed;
  }

  .btn-install:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .btn-spinner {
    width: 10px;
    height: 10px;
    border: 2px solid var(--accent-text);
    border-top-color: transparent;
    border-radius: 50%;
    animation: spin 700ms linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .card-reason {
    margin: 0;
    font-size: 0.75rem;
    color: var(--warning);
    text-align: right;
    max-width: 260px;
    line-height: 1.3;
  }

  .card-error {
    margin: 0;
    font-size: 0.75rem;
    color: var(--danger);
    text-align: right;
    max-width: 260px;
    line-height: 1.3;
  }

  .state-message {
    text-align: center;
    padding: 3rem 1rem;
    color: var(--text-muted);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.75rem;
  }

  .error-message {
    color: var(--danger);
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    font-size: 0.85rem;
    font-weight: 600;
    padding: 0.5rem 1rem;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .spinner {
    width: 24px;
    height: 24px;
    border: 3px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 800ms linear infinite;
  }
</style>
