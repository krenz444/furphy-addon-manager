<script lang="ts">
  import type { Flavour } from '../../lib/types';

  interface Props {
    open: boolean;
    url: string;
    addonId: number;
    fileId?: number | null;
    addonName?: string | null;
    flavours: Flavour[];
    selectedFlavour: string;
    onConfirm: (flavour: string, addonId: number, fileId?: number | null) => void;
    onCancel: () => void;
  }

  let {
    open,
    url,
    addonId,
    fileId = null,
    addonName = null,
    flavours,
    selectedFlavour = $bindable(),
    onConfirm,
    onCancel,
  }: Props = $props();

  let targetFlavour = $state(selectedFlavour);

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      onCancel();
    } else if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleConfirm();
    }
  }

  function handleConfirm() {
    onConfirm(targetFlavour, addonId, fileId);
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if open}
  <div class="dialog-backdrop" onclick={onCancel} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-card"
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-labelledby="consent-title"
      tabindex="-1"
    >
      <div class="dialog-header">
        <h2 id="consent-title" class="dialog-title">Install Addon Request</h2>
        <button
          type="button"
          class="btn-close"
          onclick={onCancel}
          aria-label="Close dialog"
        >
          ✕
        </button>
      </div>

      <div class="dialog-body">
        <p class="dialog-description">
          An external link requested to install the following addon into World of Warcraft:
        </p>

        <div class="details-box">
          <div class="detail-row">
            <span class="detail-label">Addon:</span>
            <span class="detail-value font-bold">{addonName || `CurseForge Project #${addonId}`}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Project ID:</span>
            <span class="detail-value">{addonId}</span>
          </div>
          {#if fileId}
            <div class="detail-row">
              <span class="detail-label">Specific File ID:</span>
              <span class="detail-value">{fileId}</span>
            </div>
          {/if}
          <div class="detail-row">
            <span class="detail-label">Requested URL:</span>
            <span class="detail-value font-mono break-all">{url}</span>
          </div>
        </div>

        {#if flavours && flavours.length > 1}
          <div class="flavour-choice">
            <label for="flavour-select" class="form-label">Install into Flavour:</label>
            <select
              id="flavour-select"
              class="form-select"
              bind:value={targetFlavour}
            >
              {#each flavours as fl (fl.id)}
                <option value={fl.id}>{fl.label} ({fl.folder})</option>
              {/each}
            </select>
          </div>
        {/if}

        <p class="dialog-note">
          Furphy will verify the file and install it directly into your AddOns directory.
        </p>
      </div>

      <div class="dialog-footer">
        <button
          type="button"
          class="btn-secondary"
          onclick={onCancel}
        >
          Cancel
        </button>
        <button
          type="button"
          class="btn-primary"
          onclick={handleConfirm}
        >
          Install Addon
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .dialog-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 999;
    padding: 1rem;
    backdrop-filter: blur(2px);
  }

  .dialog-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-lg, 12px);
    width: 100%;
    max-width: 480px;
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.5);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .dialog-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1.25rem 1.5rem;
    border-bottom: 1px solid var(--border);
    background: var(--bg-2);
  }

  .dialog-title {
    margin: 0;
    font-size: 1.15rem;
    font-weight: 700;
    color: var(--text);
  }

  .btn-close {
    background: none;
    border: none;
    color: var(--text-muted);
    font-size: 1.1rem;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: 4px;
    transition: color var(--fast);
  }

  .btn-close:hover {
    color: var(--text);
  }

  .btn-close:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .dialog-body {
    padding: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .dialog-description {
    margin: 0;
    font-size: 0.9rem;
    color: var(--text);
    line-height: 1.4;
  }

  .details-box {
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius, 8px);
    padding: 0.85rem 1rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    font-size: 0.85rem;
  }

  .detail-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 1rem;
  }

  .detail-label {
    color: var(--text-muted);
    min-width: 90px;
  }

  .detail-value {
    color: var(--text);
    text-align: right;
  }

  .font-bold {
    font-weight: 600;
  }

  .font-mono {
    font-family: monospace;
    font-size: 0.8rem;
  }

  .break-all {
    word-break: break-all;
  }

  .flavour-choice {
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
  }

  .form-label {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--text-muted);
  }

  .form-select {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    padding: 0.5rem 0.75rem;
    font-size: 0.9rem;
    outline: none;
  }

  .form-select:focus-visible {
    border-color: var(--focus-ring);
    box-shadow: 0 0 0 2px var(--focus-ring);
  }

  .dialog-note {
    margin: 0;
    font-size: 0.8rem;
    color: var(--text-muted);
    font-style: italic;
  }

  .dialog-footer {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    gap: 0.75rem;
    padding: 1rem 1.5rem;
    background: var(--bg-2);
    border-top: 1px solid var(--border);
  }

  .btn-primary, .btn-secondary {
    padding: 0.5rem 1rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast), border-color var(--fast);
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: 1px solid transparent;
  }

  .btn-primary:hover {
    background: var(--accent-hover);
  }

  .btn-primary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
