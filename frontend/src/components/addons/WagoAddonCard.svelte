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

  let isInstalling = $state(false);
  let installTimeout: ReturnType<typeof setTimeout> | null = null;

  $effect(() => {
    if (isInstalled && isInstalling) {
      isInstalling = false;
      if (installTimeout) {
        clearTimeout(installTimeout);
        installTimeout = null;
      }
    }
  });

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

  function handleInstallClick() {
    if (isInstalling || isInstalled) return;
    isInstalling = true;
    onInstall(addon.slug);

    if (installTimeout) clearTimeout(installTimeout);
    installTimeout = setTimeout(() => {
      isInstalling = false;
    }, 45000);
  }
</script>

<article class="addon-card" class:installed={isInstalled}>
  <div class="card-main">
    <div class="card-header">
      {#if addon.avatar_url}
        <img
          src={addon.avatar_url}
          alt={`${addon.name} icon`}
          class="card-avatar"
          loading="lazy"
          onerror={(e) => {
            (e.currentTarget as HTMLElement).style.display = 'none';
          }}
        />
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
              class:progression={['cata', 'wotlk', 'wrath', 'bc', 'tbc', 'mop', 'mists'].includes(addon.game_version ?? '')}
            >
              {#if addon.game_version === 'forever'}
                WoW Forever
              {:else if addon.game_version === 'classic' || addon.game_version === 'classic_era'}
                Classic
              {:else if ['cata', 'wotlk', 'wrath', 'bc', 'tbc', 'mop', 'mists'].includes(addon.game_version ?? '')}
                {addon.game_version.toUpperCase()}
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
        aria-label={`Open ${addon.name} on addons.wago.io in default web browser`}
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
          class:busy={isInstalling}
          disabled={isInstalling}
          onclick={handleInstallClick}
          aria-label={`Install ${addon.name} to ${destinationLabel}`}
          title={`Install ${addon.name} to ${destinationLabel}`}
        >
          {#if isInstalling}
            <span class="btn-spinner" aria-hidden="true"></span>
            <span>Installing…</span>
          {:else}
            <span>Install to {destinationLabel}</span>
          {/if}
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
    background: var(--info-tint);
    color: var(--info);
    border: 1px solid color-mix(in srgb, var(--info) 25%, transparent);
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  .version-tag.classic {
    background: var(--warning-tint);
    color: var(--warning);
    border-color: color-mix(in srgb, var(--warning) 25%, transparent);
  }

  .version-tag.forever {
    background: var(--accent-tint);
    color: var(--accent);
    border-color: color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .version-tag.progression {
    background: color-mix(in srgb, #a855f7 15%, transparent);
    color: #c084fc;
    border-color: color-mix(in srgb, #a855f7 30%, transparent);
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
    flex-wrap: wrap;
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
    opacity: 0.75;
    cursor: wait;
  }

  .btn-install:focus-visible {
    outline: 2px solid var(--focus-ring);
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
</style>
