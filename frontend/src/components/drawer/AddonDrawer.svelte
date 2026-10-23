<script lang="ts">
  import { invoke } from '../../lib/ipc';
  import { sanitizeHtml } from '../../lib/sanitize';
  import type { Addon, VersionItem, WtfSnapshot } from '../../lib/types';

  interface Props {
    addon: Addon | null;
    initialTab?: string;
    isGameActive: boolean;
    onClose: () => void;
    onInstallVersion?: (addon: Addon, fileId: string) => void;
    onPinVersion?: (addon: Addon, fileId: string) => void;
    onInstallDeps?: (addonId: string) => void;
    onIgnoreDep?: (addonId: string, depName: string) => void;
    onSearchDep?: (query: string) => void;
  }

  let {
    addon,
    initialTab = 'overview',
    isGameActive,
    onClose,
    onInstallVersion,
    onPinVersion,
    onInstallDeps,
    onIgnoreDep,
    onSearchDep,
  }: Props = $props();

  interface ScreenshotItem {
    url: string;
    title?: string;
  }

  let activeTab = $state<'overview' | 'versions' | 'changelog' | 'screenshots' | 'saved-settings'>('overview');
  let versions = $state<VersionItem[]>([]);
  let snapshots = $state<WtfSnapshot[]>([]);
  let screenshots = $state<ScreenshotItem[]>([]);
  let enrichedDescription = $state<string | null>(null);
  let loadingTab = $state(false);

  // WTF Restore Preview Modal State
  let restoreTarget = $state<WtfSnapshot | null>(null);
  let overwriteFiles = $state<string[]>([]);
  let loadingPreview = $state(false);
  let restoreSuccess = $state(false);
  let restoreError = $state<string | null>(null);

  $effect(() => {
    if (initialTab) {
      activeTab = initialTab as typeof activeTab;
    }
  });

  let lastLoadedAddonId = $state<string | null>(null);

  $effect(() => {
    const currentId = addon?.id ?? null;
    if (currentId !== lastLoadedAddonId) {
      lastLoadedAddonId = currentId;
      screenshots = [];
      enrichedDescription = null;
      versions = [];
      snapshots = [];
      if (addon) {
        fetchEnriched();
        loadTabData(activeTab);
      }
    }
  });

  async function fetchEnriched() {
    if (!addon) return;
    try {
      if (addon.source === 'curseforge' || addon.project_id) {
        const pid = addon.project_id || parseInt(addon.id, 10);
        if (pid && !isNaN(pid)) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const enriched = await invoke<any>('cf_enrich', { addon_id: pid });
          if (enriched?.summary) {
            enrichedDescription = enriched.summary;
          }
          if (Array.isArray(enriched?.screenshots)) {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            screenshots = enriched.screenshots.map((s: any) => ({
              url: s.url || s.thumbnailUrl,
              title: s.title || s.description,
            }));
          }
        }
      } else if (addon.source === 'wago' || addon.wago_slug) {
        const slug = addon.wago_slug || addon.id;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const wagoData = await invoke<any>('wago_addon', { slug_or_id: slug });
        if (wagoData?.description) {
          enrichedDescription = wagoData.description;
        }
        if (Array.isArray(wagoData?.screenshots)) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          screenshots = wagoData.screenshots.map((s: any) => ({
            url: s.url,
            title: s.title,
          }));
        }
      }
    } catch (err) {
      console.warn('Failed loading enriched data:', err);
    }
  }

  async function loadTabData(tab: string) {
    if (!addon) return;
    loadingTab = true;
    try {
      if (tab === 'versions') {
        if (versions.length === 0) {
          versions = await invoke<VersionItem[]>('list_files', { id: addon.id });
        }
      } else if (tab === 'saved-settings') {
        if (snapshots.length === 0) {
          snapshots = await invoke<WtfSnapshot[]>('list_wtf_snapshots', { addon_id: addon.id });
        }
      }
    } catch (err) {
      console.warn('Failed loading tab data:', err);
    } finally {
      loadingTab = false;
    }
  }

  function handleTabChange(tab: typeof activeTab) {
    activeTab = tab;
    loadTabData(tab);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      if (restoreTarget) {
        restoreTarget = null;
      } else {
        onClose();
      }
    }
  }

  async function startRestoreFlow(snap: WtfSnapshot) {
    if (isGameActive) return;
    restoreTarget = snap;
    loadingPreview = true;
    overwriteFiles = [];
    restoreError = null;
    restoreSuccess = false;
    try {
      overwriteFiles = await invoke<string[]>('preview_wtf_restore', {
        snapshot_id: snap.id,
        flavour: addon?.flavour,
      });
    } catch (err) {
      restoreError = String(err);
    } finally {
      loadingPreview = false;
    }
  }

  async function confirmRestore() {
    if (!restoreTarget) return;
    try {
      await invoke('restore_wtf_snapshot', {
        snapshot_id: restoreTarget.id,
        flavour: addon?.flavour,
      });
      restoreSuccess = true;
      setTimeout(() => {
        restoreTarget = null;
        restoreSuccess = false;
        loadTabData('saved-settings');
      }, 1500);
    } catch (err) {
      restoreError = String(err);
    }
  }

  function formatBytes(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  function formatDate(iso: string | null): string {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        month: 'short',
        day: 'numeric',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
      });
    } catch {
      return iso;
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if addon}
  <div class="drawer-backdrop" onclick={onClose} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="drawer-panel"
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-label="Addon details: {addon.name || addon.id}"
      tabindex="-1"
    >
      <header class="drawer-header">
        <div class="header-titles">
          <h2 class="addon-title">{addon.name || addon.id}</h2>
          <div class="meta-row">
            <span class="meta-item">by {addon.author || 'Unknown'}</span>
            <span class="source-tag source-{addon.source || 'cf'}">
              {addon.source || 'curseforge'}
            </span>
            <span class="version-tag">v{addon.version || '—'}</span>
          </div>
        </div>
        <button
          type="button"
          class="close-btn"
          aria-label="Close drawer (Esc)"
          onclick={onClose}
        >
          ✕
        </button>
      </header>

      <div class="drawer-tabs" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'overview'}
          class="tab-btn"
          class:is-active={activeTab === 'overview'}
          onclick={() => handleTabChange('overview')}
        >
          Overview
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'versions'}
          class="tab-btn"
          class:is-active={activeTab === 'versions'}
          onclick={() => handleTabChange('versions')}
        >
          Versions
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'changelog'}
          class="tab-btn"
          class:is-active={activeTab === 'changelog'}
          onclick={() => handleTabChange('changelog')}
        >
          Changelog
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'screenshots'}
          class="tab-btn"
          class:is-active={activeTab === 'screenshots'}
          onclick={() => handleTabChange('screenshots')}
        >
          Screenshots
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={activeTab === 'saved-settings'}
          class="tab-btn"
          class:is-active={activeTab === 'saved-settings'}
          onclick={() => handleTabChange('saved-settings')}
        >
          Saved settings (WTF)
        </button>
      </div>

      <div class="drawer-content">
        {#if activeTab === 'overview'}
          <div class="overview-section">
            {#if addon.missing_deps && addon.missing_deps.length > 0}
              <div class="missing-deps-callout" role="alert" aria-label="Missing dependencies callout">
                <div class="callout-header">
                  <div class="callout-title">
                    <svg viewBox="0 0 16 16" width="16" height="16" fill="currentColor" class="warning-icon">
                      <path d="M8.982 1.566a1.13 1.13 0 0 0-1.96 0L.165 13.233c-.457.778.091 1.767.98 1.767h13.713c.889 0 1.438-.99.98-1.767L8.982 1.566zM8 5c.535 0 .954.462.9.995l-.35 3.507a.552.552 0 0 1-1.1 0L7.1 5.995A.905.905 0 0 1 8 5zm.002 6a1 1 0 1 1 0 2 1 1 0 0 1 0-2z"/>
                    </svg>
                    <strong>Missing Dependencies ({addon.missing_deps.length})</strong>
                  </div>
                  {#if onInstallDeps}
                    <button
                      type="button"
                      class="btn-warning-solid"
                      onclick={() => onInstallDeps?.(addon.id)}
                    >
                      Install Missing Dependencies
                    </button>
                  {/if}
                </div>
                <p class="callout-desc">
                  This addon requires {addon.missing_deps.length === 1 ? 'this missing dependency' : 'these missing dependencies'} to function properly:
                </p>
                <div class="callout-chips">
                  {#each addon.missing_deps as dep}
                    <div class="dep-badge">
                      <span class="dep-label">{dep}</span>
                      <div class="dep-actions">
                        {#if onInstallDeps}
                          <button
                            type="button"
                            class="btn-dep-action btn-dep-install"
                            onclick={() => onInstallDeps?.(addon.id)}
                            title="Install {dep}"
                            aria-label="Install dependency {dep}"
                          >
                            Install
                          </button>
                        {/if}
                        {#if onSearchDep}
                          <button
                            type="button"
                            class="btn-dep-action btn-dep-find"
                            onclick={() => onSearchDep?.(dep)}
                            title="Find {dep} in Browse"
                            aria-label="Find dependency {dep}"
                          >
                            Find
                          </button>
                        {/if}
                        {#if onIgnoreDep}
                          <button
                            type="button"
                            class="btn-dep-action btn-dep-ignore"
                            onclick={() => onIgnoreDep?.(addon.id, dep)}
                            title="Ignore {dep}"
                            aria-label="Ignore dependency {dep}"
                          >
                            Ignore
                          </button>
                        {/if}
                      </div>
                    </div>
                  {/each}
                </div>
              </div>
            {/if}

            <div class="info-card">
              <div class="info-group">
                <span class="info-label">Managed Folders ({addon.folders.length})</span>
                <div class="folder-pills">
                  {#each addon.folders as folder}
                    <code class="folder-code">{folder}</code>
                  {/each}
                </div>
              </div>
              {#if addon.missing_deps && addon.missing_deps.length > 0}
                <div class="info-group">
                  <span class="info-label">Dependencies</span>
                  <div class="dep-chips-list">
                    {#each addon.missing_deps as dep}
                      <div class="dep-chip">
                        <span class="dep-dot-missing"></span>
                        <span class="dep-name">{dep}</span>
                        <span class="dep-tag-missing">missing</span>
                        <div class="dep-actions">
                          {#if onInstallDeps}
                            <button
                              type="button"
                              class="btn-dep-action btn-dep-install btn-dep-sm"
                              onclick={() => onInstallDeps?.(addon.id)}
                              title="Install {dep}"
                              aria-label="Install dependency {dep}"
                            >
                              Install
                            </button>
                          {/if}
                          {#if onSearchDep}
                            <button
                              type="button"
                              class="btn-dep-action btn-dep-find btn-dep-sm"
                              onclick={() => onSearchDep?.(dep)}
                              title="Find {dep} in Browse"
                              aria-label="Find dependency {dep}"
                            >
                              Find
                            </button>
                          {/if}
                          {#if onIgnoreDep}
                            <button
                              type="button"
                              class="btn-dep-action btn-dep-ignore btn-dep-sm"
                              onclick={() => onIgnoreDep?.(addon.id, dep)}
                              title="Ignore {dep}"
                              aria-label="Ignore dependency {dep}"
                            >
                              Ignore
                            </button>
                          {/if}
                        </div>
                      </div>
                    {/each}
                  </div>
                </div>
              {/if}
              <div class="info-grid">
                <div>
                  <span class="info-label">Installed At</span>
                  <span class="info-value">{formatDate(addon.installed_at)}</span>
                </div>
                <div>
                  <span class="info-label">Status</span>
                  <span class="info-value">
                    {addon.pinned_file_id ? 'Pinned' : addon.ignore_updates ? 'Ignoring updates' : addon.missing_deps && addon.missing_deps.length > 0 ? 'Needs dependency' : addon.adopted ? 'Adopted from AddOns' : 'Managed'}
                  </span>
                </div>
              </div>
            </div>

            <div class="description-section">
              <h3 class="section-title">Description</h3>
              <div class="rich-content">
                {#if enrichedDescription}
                  {@html sanitizeHtml(enrichedDescription)}
                {:else}
                  {@html sanitizeHtml(
                    `<p>Addon <strong>${addon.name || addon.id}</strong> installed in <em>${addon.flavour}</em>.</p><p>Package contains ${addon.folders.length} folder(s). Kept up to date via Furphy.</p>`
                  )}
                {/if}
              </div>
            </div>
          </div>
        {:else if activeTab === 'versions'}
          <div class="versions-section">
            {#if loadingTab}
              <p class="loading-state">Loading release versions…</p>
            {:else if versions.length === 0}
              <p class="empty-state">No version history available.</p>
            {:else}
              <div class="version-list">
                {#each versions as ver}
                  <div class="version-row" class:is-current={ver.is_current}>
                    <div class="version-meta">
                      <strong class="ver-string">{ver.version}</strong>
                      {#if ver.is_current}
                        <span class="badge badge-current">Current</span>
                      {/if}
                      {#if ver.is_pinned}
                        <span class="badge badge-pinned">Pinned</span>
                      {/if}
                      <span class="ver-date">{formatDate(ver.date)}</span>
                    </div>
                    <div class="version-actions">
                      {#if !ver.is_current && onInstallVersion}
                        <button
                          type="button"
                          class="btn btn-outline"
                          onclick={() => onInstallVersion?.(addon, ver.file_id)}
                        >
                          Install
                        </button>
                      {/if}
                      {#if onPinVersion}
                        <button
                          type="button"
                          class="btn btn-ghost"
                          onclick={() => onPinVersion?.(addon, ver.file_id)}
                        >
                          {ver.is_pinned ? 'Unpin' : 'Pin'}
                        </button>
                      {/if}
                    </div>
                  </div>
                {/each}
              </div>
            {/if}
          </div>
        {:else if activeTab === 'changelog'}
          <div class="changelog-section">
            <h3 class="section-title">Release Notes</h3>
            <div class="rich-content">
              <p>No release notes provided for this version.</p>
            </div>
          </div>
        {:else if activeTab === 'screenshots'}
          <div class="screenshots-section">
            {#if loadingTab}
              <p class="loading-state">Loading screenshots…</p>
            {:else if screenshots.length === 0}
              <div class="empty-state">
                <p>No screenshots available for this addon.</p>
              </div>
            {:else}
              <div class="gallery-grid">
                {#each screenshots as shot}
                  <div class="screenshot-card">
                    <img src={shot.url} alt={shot.title || 'Addon screenshot'} loading="lazy" />
                    {#if shot.title}
                      <span class="screenshot-caption">{shot.title}</span>
                    {/if}
                  </div>
                {/each}
              </div>
            {/if}
          </div>
        {:else if activeTab === 'saved-settings'}
          <div class="saved-settings-section">
            {#if isGameActive}
              <div class="game-refusal-banner" role="alert">
                <svg viewBox="0 0 20 20" width="16" height="16" fill="currentColor">
                  <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd" />
                </svg>
                <span>
                  <strong>Restoration refused while World of Warcraft is running.</strong>
                  <br />Please close the game before restoring SavedVariables settings.
                </span>
              </div>
            {/if}

            <p class="section-desc">
              Before each folder swap, Furphy archives this addon’s SavedVariables in your WTF folder.
              Restoring safely rewrites only this addon’s files.
            </p>

            {#if loadingTab}
              <p class="loading-state">Loading WTF snapshots…</p>
            {:else if snapshots.length === 0}
              <div class="empty-state">
                <p>No WTF SavedVariables snapshots recorded yet for this addon.</p>
                <small>Snapshots are automatically created during updates and swaps.</small>
              </div>
            {:else}
              <div class="snapshot-list">
                {#each snapshots as snap}
                  <div class="snapshot-card">
                    <div class="snap-info">
                      <strong class="snap-date">{formatDate(snap.created_at)}</strong>
                      <div class="snap-meta">
                        <span>{snap.file_count} file{snap.file_count === 1 ? '' : 's'}</span>
                        <span>·</span>
                        <span>{formatBytes(snap.total_bytes)}</span>
                        <span>·</span>
                        <span class="snap-kind">{snap.kind}</span>
                      </div>
                    </div>
                    <div class="snap-actions">
                      <button
                        type="button"
                        class="btn btn-outline"
                        disabled={isGameActive}
                        title={isGameActive ? 'Cannot restore while WoW runs' : 'Preview and restore'}
                        onclick={() => startRestoreFlow(snap)}
                      >
                        Restore…
                      </button>
                    </div>
                  </div>
                {/each}
              </div>
            {/if}
          </div>
        {/if}
      </div>

      {#if restoreTarget}
        <div class="modal-overlay" role="presentation">
          <div class="modal-card" role="dialog" aria-label="Confirm WTF Restore">
            <h3 class="modal-title">Restore WTF SavedVariables?</h3>
            <p class="modal-desc">
              Restoring snapshot from <strong>{formatDate(restoreTarget.created_at)}</strong>.
              This will overwrite the following files:
            </p>

            <div class="file-list-preview">
              {#if loadingPreview}
                <p>Calculating overwritten files…</p>
              {:else if overwriteFiles.length === 0}
                <p class="faint-text">No existing files will be overwritten (new files created).</p>
              {:else}
                <ul>
                  {#each overwriteFiles as file}
                    <li><code>{file}</code></li>
                  {/each}
                </ul>
              {/if}
            </div>

            {#if restoreError}
              <div class="error-banner">{restoreError}</div>
            {/if}

            {#if restoreSuccess}
              <div class="success-banner">Snapshot successfully restored!</div>
            {/if}

            <div class="modal-actions">
              <button
                type="button"
                class="btn btn-ghost"
                onclick={() => (restoreTarget = null)}
              >
                Cancel
              </button>
              <button
                type="button"
                class="btn btn-danger"
                disabled={loadingPreview || restoreSuccess || isGameActive}
                onclick={confirmRestore}
              >
                Confirm Restore
              </button>
            </div>
          </div>
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .drawer-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(2px);
    z-index: 900;
    display: flex;
    justify-content: flex-end;
  }

  .drawer-panel {
    width: var(--drawer-w);
    max-width: 90vw;
    height: 100%;
    background: var(--bg-1);
    border-left: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    box-shadow: -8px 0 24px rgba(0, 0, 0, 0.5);
    position: relative;
    overflow: hidden;
  }

  .drawer-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: 20px 24px;
    border-bottom: 1px solid var(--border);
  }

  .addon-title {
    margin: 0 0 6px;
    font-size: 18px;
    font-weight: 700;
    color: var(--text);
  }

  .meta-row {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: var(--text-muted);
  }

  .source-tag {
    text-transform: capitalize;
    font-size: 11px;
    padding: 1px 6px;
    border-radius: var(--radius-sm);
    background: var(--bg-2);
  }

  .version-tag {
    font-size: 11px;
    padding: 1px 6px;
    border-radius: var(--radius-sm);
    background: var(--bg-3);
  }

  .close-btn {
    background: transparent;
    border: none;
    color: var(--text-muted);
    font-size: 16px;
    cursor: pointer;
    padding: 6px;
    border-radius: var(--radius-sm);
  }

  .close-btn:hover {
    color: var(--text);
    background: var(--bg-2);
  }

  .close-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .drawer-tabs {
    display: flex;
    gap: 2px;
    padding: 0 20px;
    background: var(--bg-0);
    border-bottom: 1px solid var(--border);
  }

  .tab-btn {
    background: transparent;
    border: none;
    border-bottom: 2px solid transparent;
    padding: 10px 14px;
    color: var(--text-muted);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: color var(--fast), border-color var(--fast);
  }

  .tab-btn:hover {
    color: var(--text);
  }

  .tab-btn.is-active {
    color: var(--accent);
    border-bottom-color: var(--accent);
    font-weight: 600;
  }

  .tab-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: -2px;
  }

  .drawer-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px;
  }

  .info-card {
    background: var(--bg-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 16px;
    margin-bottom: 20px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .info-label {
    display: block;
    font-size: 11.5px;
    font-weight: 600;
    color: var(--text-muted);
    margin-bottom: 6px;
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  .info-value {
    font-size: 13px;
    color: var(--text);
  }

  .folder-pills {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .folder-code {
    font-size: 11.5px;
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 2px 6px;
    color: var(--text);
  }

  .info-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    border-top: 1px solid var(--border-soft);
    padding-top: 12px;
  }

  .section-title {
    font-size: 15px;
    margin: 0 0 10px;
  }

  .section-desc {
    font-size: 12.5px;
    color: var(--text-muted);
    margin: 0 0 16px;
    line-height: 1.45;
  }

  .rich-content {
    font-size: 13px;
    line-height: 1.6;
    color: var(--text);
  }

  .rich-content :global(p) {
    margin: 0 0 10px;
  }

  .rich-content :global(a) {
    color: var(--info);
    text-decoration: underline;
  }

  .game-refusal-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 14px;
    background: var(--danger-tint);
    border: 1px solid var(--danger-border);
    border-radius: var(--radius);
    color: var(--banner-danger-text);
    font-size: 12.5px;
    margin-bottom: 16px;
  }

  .version-list,
  .snapshot-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .version-row,
  .snapshot-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    background: var(--bg-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }

  .version-row.is-current {
    border-color: var(--accent);
  }

  .version-meta {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .ver-string {
    font-size: 13px;
  }

  .ver-date {
    font-size: 11.5px;
    color: var(--text-faint);
  }

  .snap-info {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .snap-date {
    font-size: 13px;
    color: var(--text);
  }

  .snap-meta {
    font-size: 11.5px;
    color: var(--text-muted);
    display: flex;
    gap: 6px;
  }

  .snap-kind {
    text-transform: capitalize;
  }

  .badge {
    font-size: 10.5px;
    padding: 1px 6px;
    border-radius: 999px;
    font-weight: 600;
  }

  .badge-current {
    background: var(--accent-tint);
    color: var(--accent);
  }

  .badge-pinned {
    background: var(--warning-tint);
    color: var(--warning);
  }

  .btn {
    font-size: 12px;
    font-weight: 600;
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid transparent;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-outline {
    background: transparent;
    color: var(--text);
    border-color: var(--border);
  }

  .btn-outline:hover:not(:disabled) {
    background: var(--bg-3);
  }

  .btn-outline:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-ghost {
    background: transparent;
    color: var(--text-muted);
  }

  .btn-ghost:hover {
    color: var(--text);
    background: var(--bg-3);
  }

  .btn-danger {
    background: var(--danger);
    color: var(--danger-text);
  }

  .btn-danger:hover:not(:disabled) {
    background: var(--danger-hover);
  }

  .btn-danger:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .modal-overlay {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    z-index: 1000;
  }

  .modal-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
    width: 100%;
    max-width: 480px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.6);
  }

  .modal-title {
    margin: 0 0 8px;
    font-size: 16px;
  }

  .modal-desc {
    font-size: 12.5px;
    color: var(--text-muted);
    margin: 0 0 12px;
  }

  .file-list-preview {
    max-height: 180px;
    overflow-y: auto;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 8px 12px;
    font-size: 12px;
    margin-bottom: 16px;
  }

  .file-list-preview ul {
    margin: 0;
    padding-left: 18px;
  }

  .file-list-preview li {
    margin-bottom: 4px;
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }

  .error-banner {
    color: var(--danger);
    font-size: 12px;
    margin-bottom: 10px;
  }

  .success-banner {
    color: var(--success);
    font-size: 12px;
    margin-bottom: 10px;
  }

  .loading-state,
  .empty-state {
    text-align: center;
    padding: 32px 16px;
    color: var(--text-muted);
    font-size: 13px;
  }

  .gallery-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 12px;
  }

  .screenshot-card {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .screenshot-card img {
    width: 100%;
    height: 130px;
    object-fit: cover;
    display: block;
  }

  .screenshot-caption {
    padding: 6px 8px;
    font-size: 11.5px;
    color: var(--text-muted);
    border-top: 1px solid var(--border-soft);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* Missing Dependencies Callout & Badges */
  .missing-deps-callout {
    background: var(--bg-1);
    border: 1px solid var(--warning);
    border-radius: var(--radius);
    padding: 12px 16px;
    margin-bottom: 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
  }

  .callout-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
  }

  .callout-title {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--warning);
    font-size: 13.5px;
  }

  .warning-icon {
    flex-shrink: 0;
  }

  .callout-desc {
    margin: 0;
    font-size: 12.5px;
    color: var(--text-muted);
  }

  .callout-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 4px;
  }

  .dep-badge {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    background: var(--bg-2);
    border: 1px solid var(--warning);
    padding: 3px 6px 3px 10px;
    border-radius: var(--radius-sm);
    font-size: 12px;
    color: var(--text);
  }

  .dep-label {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-weight: 500;
  }

  .btn-warning-solid {
    background: var(--warning-tint);
    color: var(--warning);
    border: 1px solid var(--warning);
    font-weight: 600;
    font-size: 12px;
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: background var(--fast), color var(--fast), transform var(--fast);
  }

  .btn-warning-solid:hover {
    background: var(--warning);
    color: var(--bg-0);
    transform: translateY(-1px);
  }

  .btn-warning-solid:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-dep-install {
    background: var(--warning-tint);
    color: var(--warning);
    border: 1px solid var(--warning);
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: background var(--fast), color var(--fast);
  }

  .btn-dep-install:hover {
    background: var(--warning);
    color: var(--bg-0);
  }

  .btn-dep-install:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .dep-chips-list {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 6px;
  }

  .dep-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: var(--bg-2);
    border: 1px solid var(--border);
    padding: 3px 8px;
    border-radius: var(--radius-sm);
    font-size: 12px;
  }

  .dep-dot-missing {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--warning);
  }

  .dep-name {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    color: var(--text);
  }

  .dep-tag-missing {
    font-size: 10.5px;
    color: var(--warning);
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: 0.3px;
  }

  .btn-dep-install-sm {
    background: rgba(255, 179, 71, 0.15);
    color: var(--warning);
    border: 1px solid rgba(255, 179, 71, 0.4);
    font-size: 10.5px;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: background var(--fast), color var(--fast);
  }

  .btn-dep-install-sm:hover {
    background: var(--warning);
    color: #12151f;
  }

  .btn-dep-install-sm:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .dep-actions {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    margin-left: 6px;
  }

  .btn-dep-action {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 500;
    padding: 2px 7px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    line-height: 1.2;
    transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
  }

  .btn-dep-action:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .btn-dep-action.btn-dep-install {
    background: var(--warning-tint);
    color: var(--warning);
    border: 1px solid var(--warning);
    font-weight: 600;
  }

  .btn-dep-action.btn-dep-install:hover {
    background: var(--warning);
    color: var(--bg-0);
  }

  .btn-dep-action.btn-dep-find {
    background: var(--bg-1);
    color: var(--text);
    border: 1px solid var(--border);
  }

  .btn-dep-action.btn-dep-find:hover {
    background: var(--border-hover);
    border-color: var(--text-muted);
  }

  .btn-dep-action.btn-dep-ignore {
    background: transparent;
    color: var(--text-muted);
    border: 1px solid var(--border);
  }

  .btn-dep-action.btn-dep-ignore:hover {
    background: var(--bg-3);
    color: var(--text);
    border-color: var(--border-hover);
  }

  .btn-dep-action.btn-dep-sm {
    font-size: 10px;
    padding: 1px 5px;
  }
</style>
