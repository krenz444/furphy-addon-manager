<script lang="ts">
  import type { WagoAddonItem } from '../../lib/types';
  import { invoke } from '../../lib/ipc';

  interface Props {
    addon: WagoAddonItem;
    destinationLabel: string;
    isInstalled: boolean;
    onInstall: (slug: string) => void;
  }

  let { addon, destinationLabel, isInstalled, onInstall }: Props = $props();

  function formatDownloads(count?: number): string {
    if (!count) return '';
    if (count >= 1_000_000) {
      return (count / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
    }
    if (count >= 1_000) {
      return (count / 1_000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return count.toLocaleString();
  }

  function openWagoPage(e: MouseEvent) {
    e.stopPropagation();
    const url = addon.wago_url || `https://addons.wago.io/addons/${addon.slug}`;
    invoke('open_target', { what: 'url', args: [url] }).catch((err) => {
      console.error('Failed opening Wago page:', err);
    });
  }
</script>

<article class="addon-card" class:installed={isInstalled}>
  <div class="card-main">
    <div class="card-header">
      {#if addon.avatar_url}
        <img src={addon.avatar_url} alt="" class="card-avatar" loading="lazy" />
      {/if}
      <div class="card-title-group">
        <div class="card-title-row">
          <h3 class="card-title" title={addon.name}>{addon.name}</h3>
          {#if addon.version}
            <span class="card-version font-mono">{addon.version}</span>
          {/if}
        </div>
        <div class="card-subtitle">
          <span class="card-author">by {addon.author}</span>
          {#if addon.game_version}
            <span
              class="version-tag"
              class:forever={addon.game_version === 'forever'}
              class:classic={addon.game_version === 'classic' || addon.game_version === 'classic_era'}
            >
              {#if addon.game_version === 'forever'}
                WoW Forever
              {:else if addon.game_version === 'classic' || addon.game_version === 'classic_era'}
                Classic
              {:else}
                Retail
              {/if}
            </span>
          {/if}
        </div>
      </div>
    </div>

    {#if addon.description}
      <p class="card-desc">{addon.description}</p>
    {/if}
  </div>

  <div class="card-footer">
    <div class="stats-group">
      {#if addon.downloads}
        <span class="stat-pill" title={`${addon.downloads.toLocaleString()} total downloads`}>
          <span class="stat-icon" aria-hidden="true">⬇</span>
          <span>{formatDownloads(addon.downloads)}</span>
        </span>
      {/if}
      <button
        type="button"
        class="btn-browser-link"
        onclick={openWagoPage}
        title="Open addon page on addons.wago.io in default web browser"
      >
        <span aria-hidden="true">↗</span>
        <span>wago.io</span>
      </button>
    </div>

    <div class="action-group">
      {#if isInstalled}
        <div class="badge-installed" title={`Already installed in ${destinationLabel}`}>
          <span aria-hidden="true">✓</span>
          <span>Installed</span>
        </div>
      {:else}
        <button
          type="button"
          class="btn-install"
          onclick={() => onInstall(addon.slug)}
          title={`Install ${addon.name} to ${destinationLabel}`}
        >
          Install to {destinationLabel}
        </button>
      {/if}
    </div>
  </div>
</article>

<style>
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
    border-color: rgba(34, 197, 94, 0.35);
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

  .card-avatar {
    width: 44px;
    height: 44px;
    border-radius: var(--radius-sm, 4px);
    object-fit: cover;
    background: var(--bg-2);
    border: 1px solid var(--border);
    flex-shrink: 0;
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

  .card-subtitle {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.75rem;
  }

  .card-author {
    color: var(--text-muted);
  }

  .version-tag {
    font-size: 0.65rem;
    padding: 0.05rem 0.35rem;
    border-radius: 3px;
    background: rgba(56, 189, 248, 0.15);
    color: #38bdf8;
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  .version-tag.classic {
    background: rgba(245, 158, 11, 0.15);
    color: #f59e0b;
  }

  .version-tag.forever {
    background: rgba(168, 85, 247, 0.15);
    color: #c084fc;
    border: 1px solid rgba(168, 85, 247, 0.3);
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

  .card-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-top: 0.65rem;
    border-top: 1px solid var(--border);
    gap: 0.5rem;
  }

  .stats-group {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .stat-pill {
    display: flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.75rem;
    color: var(--text-muted);
    font-weight: 500;
  }

  .stat-icon {
    font-size: 0.7rem;
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

  .action-group {
    display: flex;
    align-items: center;
  }

  .badge-installed {
    display: flex;
    align-items: center;
    gap: 0.3rem;
    font-size: 0.75rem;
    font-weight: 600;
    color: #22c55e;
    background: rgba(34, 197, 94, 0.12);
    border: 1px solid rgba(34, 197, 94, 0.25);
    padding: 0.3rem 0.65rem;
    border-radius: var(--radius-sm, 4px);
  }

  .btn-install {
    background: var(--accent);
    color: #ffffff;
    border: none;
    padding: 0.35rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 600;
    cursor: pointer;
    transition: filter var(--fast, 150ms), transform var(--fast, 150ms);
    white-space: nowrap;
  }

  .btn-install:hover {
    filter: brightness(1.1);
  }

  .btn-install:active {
    transform: scale(0.98);
  }

  .btn-install:focus-visible {
    outline: 2px solid var(--focus-ring);
  }
</style>
