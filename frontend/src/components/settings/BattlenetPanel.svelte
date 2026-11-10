<script lang="ts">
  import { invoke } from '../../lib/ipc';
  import type { BattlenetInstall, Flavour } from '../../lib/types';

  interface Props {
    flavours?: Flavour[];
    onUseRoot: (flavour: string, rootPath: string) => Promise<void>;
  }

  let { flavours = [], onUseRoot }: Props = $props();

  let installs = $state<BattlenetInstall[] | null>(null);
  let isDetecting = $state(false);
  let detectError = $state<string | null>(null);
  let isUsing = $state<Record<string, boolean>>({});
  let confirmations = $state<Record<string, string>>({});
  let actionErrors = $state<Record<string, string>>({});

  function normalizePath(p: string | null | undefined): string {
    if (!p) return '';
    return p.replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
  }

  function getFlavourLabel(item: BattlenetInstall): string {
    if (item.flavour) {
      const flv = flavours.find((f) => f.id === item.flavour);
      if (flv?.label) return flv.label;
    }
    return item.product;
  }

  function getRowStatus(item: BattlenetInstall): { statusText: string; canUse: boolean } {
    if (!item.flavour) {
      return {
        statusText: 'Furphy has no game version for this product',
        canUse: false,
      };
    }

    const flv = flavours.find((f) => f.id === item.flavour);
    const folderName = flv?.folder || `_${item.flavour}_`;

    if (!item.flavour_folder_exists) {
      return {
        statusText: `The folder ${folderName} is not in this install`,
        canUse: false,
      };
    }

    const normInstall = normalizePath(item.install_path);
    const normCurrent = normalizePath(item.current_path);

    if (normCurrent && normInstall === normCurrent) {
      return {
        statusText: 'Already used by Furphy',
        canUse: false,
      };
    }

    const currentDesc = item.current_path ? ` (${item.current_path})` : '';
    return {
      statusText: `Different from the folder Furphy uses now${currentDesc}`,
      canUse: true,
    };
  }

  async function handleDetect() {
    isDetecting = true;
    detectError = null;
    confirmations = {};
    actionErrors = {};

    try {
      const res = await invoke<BattlenetInstall[]>('detect_battlenet_installs');
      installs = res || [];
    } catch (err: unknown) {
      detectError = err instanceof Error ? err.message : String(err);
      installs = null;
    } finally {
      isDetecting = false;
    }
  }

  async function handleUse(item: BattlenetInstall) {
    if (!item.flavour) return;
    const prod = item.product;
    isUsing = { ...isUsing, [prod]: true };
    const currentErrors = { ...actionErrors };
    delete currentErrors[prod];
    actionErrors = currentErrors;

    const currentConfirms = { ...confirmations };
    delete currentConfirms[prod];
    confirmations = currentConfirms;

    try {
      await onUseRoot(item.flavour, item.install_path);
      const label = getFlavourLabel(item);
      confirmations = {
        ...confirmations,
        [prod]: `Using folder ${item.install_path} for ${label}.`,
      };
      // Mark current path locally so row status updates immediately to 'Already used by Furphy'
      if (installs) {
        installs = installs.map((row) =>
          row.product === prod ? { ...row, current_path: item.install_path } : row
        );
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      actionErrors = { ...actionErrors, [prod]: msg };
    } finally {
      const busy = { ...isUsing };
      delete busy[prod];
      isUsing = busy;
    }
  }
</script>

<div class="bnet-panel" data-testid="bnet-panel">
  <div class="bnet-header">
    <div>
      <h3 class="bnet-title">Find installs from Battle.net</h3>
      <p class="bnet-desc">
        Detect World of Warcraft installations recorded by Battle.net on this PC.
      </p>
    </div>
    <button
      type="button"
      class="btn-secondary"
      data-testid="bnet-detect"
      disabled={isDetecting}
      onclick={handleDetect}
    >
      {#if isDetecting}
        <span>Detecting installs...</span>
      {:else}
        <span>Find installs from Battle.net</span>
      {/if}
    </button>
  </div>

  {#if detectError}
    <div class="bnet-error" role="alert">
      {detectError}
    </div>
  {/if}

  {#if installs !== null && installs.length === 0 && !detectError}
    <div class="bnet-empty" role="status">
      Battle.net has no World of Warcraft installs recorded on this PC.
    </div>
  {/if}

  {#if installs && installs.length > 0}
    <div class="bnet-list">
      {#each installs as item (item.product)}
        {@const status = getRowStatus(item)}
        {@const label = getFlavourLabel(item)}
        {@const isItemBusy = Boolean(isUsing[item.product])}
        <div class="bnet-row" data-testid="bnet-row-{item.product}">
          <div class="bnet-row-header">
            <div class="bnet-title-row">
              <span class="bnet-product-name">{label}</span>
              <span class="bnet-product-code font-mono">({item.product})</span>
              {#if status.statusText === 'Already used by Furphy'}
                <span class="bnet-used-badge">Active</span>
              {/if}
            </div>

            <div class="bnet-actions">
              <button
                type="button"
                class="btn-secondary btn-sm"
                data-testid="bnet-use-{item.product}"
                disabled={!status.canUse || isItemBusy}
                onclick={() => handleUse(item)}
              >
                {#if isItemBusy}
                  <span>Updating...</span>
                {:else}
                  <span>Use this folder</span>
                {/if}
              </button>
            </div>
          </div>

          <div class="bnet-path font-mono" title={item.install_path}>
            📁 {item.install_path}
          </div>

          <div class="bnet-status-row">
            <span
              class="bnet-status-text"
              class:text-success={status.statusText === 'Already used by Furphy'}
              class:text-warning={status.canUse}
            >
              {status.statusText}
            </span>
          </div>

          {#if confirmations[item.product]}
            <div class="bnet-confirm text-success" role="status">
              {confirmations[item.product]}
            </div>
          {/if}

          {#if actionErrors[item.product]}
            <div class="bnet-action-error text-danger" role="alert">
              {actionErrors[item.product]}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .bnet-panel {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .bnet-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.75rem;
  }

  .bnet-title {
    margin: 0;
    font-size: 0.95rem;
    color: var(--text);
  }

  .bnet-desc {
    margin: 0.25rem 0 0 0;
    font-size: 0.85rem;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .bnet-list {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    margin-top: 0.5rem;
  }

  .bnet-row {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.75rem 0.85rem;
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
  }

  .bnet-row-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.5rem;
  }

  .bnet-title-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .bnet-product-name {
    font-weight: 600;
    font-size: 0.9rem;
    color: var(--text);
  }

  .bnet-product-code {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .bnet-used-badge {
    font-size: 0.7rem;
    color: var(--success);
    background: var(--success-tint);
    padding: 0.1rem 0.4rem;
    border-radius: 3px;
    font-weight: 600;
  }

  .bnet-actions {
    display: flex;
    align-items: center;
    gap: 0.35rem;
  }

  .bnet-path {
    font-size: 0.75rem;
    color: var(--text-muted);
    background: var(--bg-1);
    padding: 0.25rem 0.5rem;
    border-radius: 3px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .font-mono {
    font-family: monospace;
  }

  .bnet-status-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
  }

  .bnet-status-text {
    font-size: 0.8rem;
    color: var(--text-muted);
  }

  .bnet-confirm {
    font-size: 0.8rem;
    margin-top: 0.2rem;
  }

  .bnet-action-error {
    font-size: 0.8rem;
    margin-top: 0.2rem;
  }

  .bnet-empty {
    background: var(--bg-0);
    border: 1px dashed var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 1rem;
    text-align: center;
    color: var(--text-muted);
    font-size: 0.85rem;
  }

  .bnet-error {
    color: var(--danger);
    background: var(--danger-tint);
    border: 1px solid color-mix(in srgb, var(--danger) 30%, transparent);
    padding: 0.45rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.85rem;
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 600;
    cursor: pointer;
    padding: 0.45rem 0.85rem;
    transition: background var(--fast);
  }

  .btn-secondary:hover:not(:disabled) {
    background: var(--border-hover);
  }

  .btn-secondary:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .btn-sm {
    padding: 0.25rem 0.55rem;
    font-size: 0.75rem;
  }

  .text-success {
    color: var(--success);
  }

  .text-warning {
    color: var(--warning);
  }

  .text-danger {
    color: var(--danger);
  }
</style>
