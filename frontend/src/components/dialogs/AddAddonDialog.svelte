<script lang="ts">
  interface Props {
    isOpen: boolean;
    onClose: () => void;
    onAdd: (target: string) => Promise<void>;
  }

  let { isOpen, onClose, onAdd }: Props = $props();

  let inputVal = $state('');
  let isSubmitting = $state(false);
  let errorMsg = $state<string | null>(null);

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && isOpen) {
      onClose();
    }
  }

  async function handleSubmit(e: SubmitEvent) {
    e.preventDefault();
    const trimmed = inputVal.trim();
    if (!trimmed) return;
    isSubmitting = true;
    errorMsg = null;
    try {
      await onAdd(trimmed);
      inputVal = '';
      onClose();
    } catch (err) {
      errorMsg = String(err);
    } finally {
      isSubmitting = false;
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
      aria-label="Add an Addon"
      tabindex="-1"
    >
      <header class="dialog-header">
        <h3 class="dialog-title">Add an Addon</h3>
        <button type="button" class="close-btn" aria-label="Close dialog" onclick={onClose}>✕</button>
      </header>

      <form onsubmit={handleSubmit}>
        <p class="dialog-desc">
          Paste a <strong>CurseForge</strong> project URL or ID, a <strong>wago.io</strong> link, or a <strong>GitHub</strong> repository link:
        </p>

        <div class="input-group">
          <input
            type="text"
            bind:value={inputVal}
            placeholder="e.g. https://www.curseforge.com/wow/addons/details or 61284 or https://github.com/..."
            class="dialog-input"
            required
            disabled={isSubmitting}
          />
        </div>

        {#if errorMsg}
          <div class="error-banner" role="alert">{errorMsg}</div>
        {/if}

        <footer class="dialog-footer">
          <button type="button" class="btn btn-ghost" onclick={onClose} disabled={isSubmitting}>
            Cancel
          </button>
          <button type="submit" class="btn btn-accent" disabled={isSubmitting || !inputVal.trim()}>
            {isSubmitting ? 'Adding…' : 'Add Addon'}
          </button>
        </footer>
      </form>
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

  .dialog-input {
    width: 100%;
    box-sizing: border-box;
    background: var(--bg-2);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 10px 12px;
    border-radius: var(--radius-sm);
    font-size: 13px;
  }

  .dialog-input:focus {
    border-color: var(--accent);
    outline: none;
  }

  .dialog-input:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .error-banner {
    color: var(--danger);
    font-size: 12.5px;
    margin-top: 10px;
  }

  .dialog-footer {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 20px;
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
