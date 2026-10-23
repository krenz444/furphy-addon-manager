<script lang="ts">
  interface Props {
    isOpen: boolean;
    flavour: string;
    onClose: () => void;
    onExport: (includeWtf: boolean) => Promise<string>;
  }

  let { isOpen, flavour, onClose, onExport }: Props = $props();

  let includeWtf = $state(false);
  let isExporting = $state(false);
  let exportedPath = $state<string | null>(null);
  let errorMsg = $state<string | null>(null);

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && isOpen) {
      onClose();
    }
  }

  async function handleExport() {
    isExporting = true;
    errorMsg = null;
    try {
      exportedPath = await onExport(includeWtf);
    } catch (err) {
      errorMsg = String(err);
    } finally {
      isExporting = false;
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if isOpen}
  <div class="dialog-overlay" onclick={onClose} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-box"
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-label="Export Addon List"
      tabindex="-1"
    >
      <header class="dialog-header">
        <h3 class="dialog-title">Export Addon List ({flavour})</h3>
        <button type="button" class="close-btn" aria-label="Close dialog" onclick={onClose}>✕</button>
      </header>

      <p class="dialog-desc">
        Exports your installed addons in standard <code>wow-addon-manager/2</code> JSON format, including pins and update preferences.
      </p>

      <div class="options-box">
        <label class="checkbox-row">
          <input type="checkbox" bind:checked={includeWtf} />
          <span class="label-text">
            <strong>Bundle SavedVariables (WTF) settings</strong>
          </span>
        </label>

        {#if includeWtf}
          <div class="personal-data-warning" role="note">
            <svg viewBox="0 0 20 20" width="16" height="16" fill="currentColor">
              <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd" />
            </svg>
            <div>
              <strong>Personal Data Notice:</strong> SavedVariables settings files can contain account names, character names, and chat histories. Do not share bundles with untrusted third parties.
            </div>
          </div>
        {/if}
      </div>

      {#if errorMsg}
        <div class="error-banner">{errorMsg}</div>
      {/if}

      {#if exportedPath}
        <div class="success-banner">
          Saved export to: <code>{exportedPath}</code>
        </div>
      {/if}

      <footer class="dialog-footer">
        <button type="button" class="btn btn-ghost" onclick={onClose}>
          {exportedPath ? 'Close' : 'Cancel'}
        </button>
        {#if !exportedPath}
          <button type="button" class="btn btn-accent" onclick={handleExport} disabled={isExporting}>
            {isExporting ? 'Exporting…' : 'Export Now'}
          </button>
        {/if}
      </footer>
    </div>
  </div>
{/if}

<style>
  .dialog-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.65);
    backdrop-filter: blur(2px);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
    padding: 20px;
  }

  .dialog-box {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 24px;
    width: 100%;
    max-width: 520px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.5);
  }

  .dialog-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  .dialog-title {
    margin: 0;
    font-size: 16px;
    font-weight: 700;
  }

  .close-btn {
    background: transparent;
    border: none;
    color: var(--text-muted);
    font-size: 14px;
    cursor: pointer;
    padding: 4px 6px;
    border-radius: var(--radius-sm);
  }

  .close-btn:hover {
    color: var(--text);
    background: var(--bg-2);
  }

  .dialog-desc {
    font-size: 13px;
    color: var(--text-muted);
    margin: 0 0 16px;
    line-height: 1.5;
  }

  .options-box {
    background: var(--bg-2);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 14px;
    margin-bottom: 16px;
  }

  .checkbox-row {
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
  }

  .label-text {
    font-size: 13px;
    color: var(--text);
  }

  .personal-data-warning {
    display: flex;
    gap: 8px;
    margin-top: 12px;
    padding: 10px 12px;
    background: var(--warning-tint);
    border: 1px solid rgba(255, 179, 71, 0.35);
    border-radius: var(--radius-sm);
    color: var(--warning);
    font-size: 12px;
    line-height: 1.45;
  }

  .personal-data-warning svg {
    flex: none;
    margin-top: 2px;
  }

  .error-banner {
    color: var(--danger);
    font-size: 12.5px;
    margin-bottom: 12px;
  }

  .success-banner {
    color: var(--success);
    font-size: 12.5px;
    margin-bottom: 12px;
    word-break: break-all;
  }

  .dialog-footer {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }

  .btn {
    font-size: 13px;
    font-weight: 600;
    padding: 7px 16px;
    border-radius: var(--radius-sm);
    border: 1px solid transparent;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-accent {
    background: var(--accent);
    color: var(--accent-text);
  }

  .btn-accent:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .btn-accent:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-ghost {
    background: transparent;
    color: var(--text-muted);
  }

  .btn-ghost:hover {
    color: var(--text);
    background: var(--bg-2);
  }
</style>
