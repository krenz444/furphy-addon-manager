<script lang="ts">
  import type { PatchCompatStatus, Addon } from '../lib/types';

  interface Props {
    flavour: string;
    addons: Addon[];
    compatList: PatchCompatStatus[];
    onCheckNow: (addonId: string) => void;
    onUpdate: (addon: Addon) => void;
    onPin: (addon: Addon) => void;
    onOpenWeb: (addon: Addon) => void;
  }

  let {
    flavour,
    addons,
    compatList,
    onCheckNow,
    onUpdate,
    onPin,
    onOpenWeb,
  }: Props = $props();

  // Map compat list with addon records
  let oldPatchRows = $derived.by(() => {
    return compatList.map(status => {
      const match = addons.find(a => a.id === status.addon_id);
      return {
        status,
        addon: match || ({
          id: status.addon_id,
          flavour,
          name: status.name,
          version: status.installed_version,
          folders: [],
          author: null,
          source: 'cf',
          project_id: null,
          file_id: null,
          file_name: null,
          installed_at: null,
          adopted: false,
          ignore_updates: false,
          pinned_file_id: null,
          release_type: null,
        } as Addon),
      };
    });
  });
</script>

<div class="patch-compat-view">
  <header class="view-header">
    <div class="header-content">
      <h2>Not Built for Current Patch</h2>
      <p class="header-desc">
        These addons have not declared compatibility with the current World of Warcraft patch interface. They may continue to work if Blizzard made no breaking API changes, or they may produce Lua errors in-game.
      </p>
    </div>
  </header>

  <div class="view-body">
    {#if oldPatchRows.length === 0}
      <div class="empty-state">
        <div class="empty-icon">✓</div>
        <h3>All addons up to date with game patch</h3>
        <p>None of your installed addons are flagged as outdated for {flavour}.</p>
      </div>
    {:else}
      <div class="table-card">
        <div class="table-header">
          <div class="col-name">Addon Name</div>
          <div class="col-version">Installed Version</div>
          <div class="col-toc">TOC Interface</div>
          <div class="col-client">Client Interface</div>
          <div class="col-actions">Actions</div>
        </div>

        <div class="table-rows">
          {#each oldPatchRows as { status, addon } (status.addon_id)}
            <div class="compat-row">
              <div class="col-name">
                <span class="addon-title">{status.name}</span>
                <span class="addon-id font-mono">({status.addon_id})</span>
              </div>

              <div class="col-version font-mono">
                {status.installed_version ?? '—'}
              </div>

              <div class="col-toc font-mono">
                {status.toc_interface ?? 'Unknown'}
              </div>

              <div class="col-client font-mono">
                {status.client_interface ?? 'Unknown'}
              </div>

              <div class="col-actions">
                <button
                  type="button"
                  class="btn-action"
                  onclick={() => onCheckNow(status.addon_id)}
                  title="Check for newly published updates"
                >
                  Check now
                </button>
                <button
                  type="button"
                  class="btn-action btn-accent"
                  onclick={() => onUpdate(addon)}
                  title="Force update/reinstall newest available version"
                >
                  Update
                </button>
                <button
                  type="button"
                  class="btn-action"
                  onclick={() => onPin(addon)}
                  title="Pin version to silence updates"
                >
                  Pin
                </button>
                <button
                  type="button"
                  class="btn-action"
                  onclick={() => onOpenWeb(addon)}
                  title="Open addon webpage"
                >
                  Web ↗
                </button>
              </div>
            </div>
          {/each}
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  .patch-compat-view {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }

  .view-header {
    background: var(--bg-1);
    border-bottom: 1px solid var(--border);
    padding: 1.25rem;
  }

  .header-content h2 {
    margin: 0 0 0.4rem 0;
    font-size: 1.25rem;
    color: var(--text);
  }

  .header-desc {
    margin: 0;
    font-size: 0.85rem;
    color: var(--text-muted);
    max-width: 680px;
    line-height: 1.45;
  }

  .view-body {
    flex: 1;
    overflow-y: auto;
    padding: 1.25rem;
  }

  .table-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    overflow: hidden;
  }

  .table-header {
    display: grid;
    grid-template-columns: 1fr 140px 120px 120px 240px;
    align-items: center;
    padding: 0.65rem 1rem;
    background: var(--bg-0);
    border-bottom: 1px solid var(--border);
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-faint);
  }

  .compat-row {
    display: grid;
    grid-template-columns: 1fr 140px 120px 120px 240px;
    align-items: center;
    padding: 0.65rem 1rem;
    border-bottom: 1px solid var(--border-soft);
    font-size: 0.85rem;
    color: var(--text);
    transition: background var(--fast);
  }

  .compat-row:last-child {
    border-bottom: none;
  }

  .compat-row:hover {
    background: var(--bg-2);
  }

  .col-name {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    overflow: hidden;
    padding-right: 0.5rem;
  }

  .addon-title {
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .addon-id {
    font-size: 0.75rem;
    color: var(--text-faint);
  }

  .col-actions {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    justify-content: flex-end;
  }

  .btn-action {
    background: var(--bg-3);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    padding: 0.25rem 0.55rem;
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn-action:hover {
    background: var(--border-hover);
  }

  .btn-action:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .btn-action.btn-accent {
    background: var(--accent);
    color: var(--accent-text);
    border-color: transparent;
  }

  .btn-action.btn-accent:hover {
    background: var(--accent-hover);
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 4rem 1rem;
    text-align: center;
    color: var(--text-muted);
  }

  .empty-icon {
    font-size: 2rem;
    color: var(--success);
    margin-bottom: 0.75rem;
  }

  .empty-state h3 {
    margin: 0 0 0.5rem 0;
    color: var(--text);
  }

  .empty-state p {
    margin: 0;
    font-size: 0.9rem;
  }

  .font-mono {
    font-family: monospace;
  }
</style>
