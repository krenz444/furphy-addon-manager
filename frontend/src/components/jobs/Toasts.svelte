<script lang="ts">
  export interface ToastItem {
    id: string;
    type: 'info' | 'success' | 'warning' | 'error';
    message: string;
  }

  interface Props {
    reloadNeeded: boolean;
    toasts: ToastItem[];
    onDismissReload?: () => void;
    onDismissToast?: (id: string) => void;
  }

  let {
    reloadNeeded,
    toasts,
    onDismissReload,
    onDismissToast,
  }: Props = $props();
</script>

<div class="toast-container" aria-live="polite" aria-atomic="false">
  {#if reloadNeeded}
    <div class="toast reload-toast" role="alert">
      <div class="toast-content">
        <span class="reload-icon">⚠️</span>
        <div>
          <div class="reload-title">WoW is Running</div>
          <div class="reload-msg">Type <code>/reload</code> in your game chat to apply addon updates.</div>
        </div>
      </div>
      {#if onDismissReload}
        <button
          type="button"
          class="btn-toast-close"
          onclick={onDismissReload}
          aria-label="Dismiss reload notification"
        >
          ✕
        </button>
      {/if}
    </div>
  {/if}

  {#each toasts as t (t.id)}
    <div class="toast toast-{t.type}" role="status">
      <div class="toast-content">
        <span class="toast-dot dot-{t.type}"></span>
        <span class="toast-text">{t.message}</span>
      </div>
      {#if onDismissToast}
        <button
          type="button"
          class="btn-toast-close"
          onclick={() => onDismissToast(t.id)}
          aria-label="Dismiss notification"
        >
          ✕
        </button>
      {/if}
    </div>
  {/each}
</div>

<style>
  .toast-container {
    position: fixed;
    bottom: 1.5rem;
    right: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    z-index: 950;
    pointer-events: none;
    max-width: 380px;
    width: 100%;
  }

  .toast {
    pointer-events: auto;
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    padding: 0.75rem 1rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    font-size: 0.85rem;
    color: var(--text);
    transition: transform var(--fast), opacity var(--fast);
  }

  .reload-toast {
    background: var(--bg-2);
    border-color: var(--warning);
    border-left: 4px solid var(--warning);
  }

  .toast-content {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    min-width: 0;
  }

  .reload-icon {
    font-size: 1.1rem;
    flex-shrink: 0;
  }

  .reload-title {
    font-weight: 700;
    color: var(--warning);
    font-size: 0.85rem;
  }

  .reload-msg {
    color: var(--text);
    font-size: 0.8rem;
    margin-top: 2px;
  }

  .reload-msg code {
    background: var(--bg-0);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: monospace;
    font-weight: 600;
    color: var(--accent);
  }

  .toast-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .dot-info { background: var(--info); }
  .dot-success { background: var(--success); }
  .dot-warning { background: var(--warning); }
  .dot-error { background: var(--danger); }

  .toast-text {
    line-height: 1.35;
    word-break: break-word;
  }

  .btn-toast-close {
    background: none;
    border: none;
    color: var(--text-muted);
    cursor: pointer;
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 0.85rem;
    transition: color var(--fast);
  }

  .btn-toast-close:hover {
    color: var(--text);
  }

  .btn-toast-close:focus-visible {
    outline: 2px solid var(--focus-ring);
  }
</style>
