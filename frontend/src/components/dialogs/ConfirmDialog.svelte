<script lang="ts">
  interface Props {
    open: boolean;
    title: string;
    message: string;
    detail?: string | null;
    confirmLabel?: string;
    cancelLabel?: string;
    isDanger?: boolean;
    onConfirm: () => void;
    onCancel: () => void;
  }

  let {
    open,
    title,
    message,
    detail = null,
    confirmLabel = 'Confirm',
    cancelLabel = 'Cancel',
    isDanger = false,
    onConfirm,
    onCancel,
  }: Props = $props();

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      onCancel();
    } else if (e.key === 'Enter' && !isDanger) {
      e.preventDefault();
      onConfirm();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if open}
  <div class="dialog-backdrop" onclick={onCancel} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-card"
      onclick={(e) => e.stopPropagation()}
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="confirm-title"
      aria-describedby="confirm-message"
      tabindex="-1"
    >
      <div class="dialog-header">
        <h2 id="confirm-title" class="dialog-title" class:danger-text={isDanger}>
          {title}
        </h2>
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
        <p id="confirm-message" class="confirm-message">{message}</p>
        {#if detail}
          <div class="confirm-detail">
            {detail}
          </div>
        {/if}
      </div>

      <div class="dialog-footer">
        <button
          type="button"
          class="btn-secondary"
          onclick={onCancel}
        >
          {cancelLabel}
        </button>
        <button
          type="button"
          class="btn-confirm"
          class:btn-danger={isDanger}
          class:btn-primary={!isDanger}
          onclick={onConfirm}
        >
          {confirmLabel}
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
    z-index: 1000;
    padding: 1rem;
    backdrop-filter: blur(2px);
  }

  .dialog-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-lg, 12px);
    width: 100%;
    max-width: 440px;
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

  .dialog-title.danger-text {
    color: var(--danger);
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
    gap: 0.75rem;
  }

  .confirm-message {
    margin: 0;
    font-size: 0.95rem;
    color: var(--text);
    line-height: 1.45;
  }

  .confirm-detail {
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-sm, 4px);
    padding: 0.75rem 1rem;
    font-size: 0.85rem;
    color: var(--text-muted);
    font-family: monospace;
    white-space: pre-wrap;
    word-break: break-all;
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

  .btn-confirm, .btn-secondary {
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

  .btn-danger {
    background: var(--danger);
    color: var(--danger-text);
    border: 1px solid transparent;
  }

  .btn-danger:hover {
    background: var(--danger-hover);
  }

  .btn-danger:focus-visible {
    outline: 2px solid var(--danger);
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
