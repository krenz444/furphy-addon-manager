<script lang="ts">
  import type { WtfRestorePreview } from '../../lib/types';

  interface Props {
    preview: WtfRestorePreview;
    flavourLabel: string;
    isGameActive: boolean;
    busy: boolean;
    onConfirm: () => void;
    onCancel: () => void;
  }

  let {
    preview,
    flavourLabel,
    isGameActive,
    busy,
    onConfirm,
    onCancel,
  }: Props = $props();

  let dialogCardEl = $state<HTMLDivElement | null>(null);
  let cancelButtonEl = $state<HTMLButtonElement | null>(null);

  $effect(() => {
    const opener = document.activeElement as HTMLElement | null;
    requestAnimationFrame(() => {
      cancelButtonEl?.focus();
    });
    return () => {
      opener?.focus();
    };
  });

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      onCancel();
    } else if (e.key === 'Tab' && dialogCardEl) {
      const focusable = Array.from(
        dialogCardEl.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [tabindex]:not([tabindex="-1"])'
        )
      );
      if (focusable.length > 0) {
        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    }
  }

  function formatBytes(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }

  function formatDate(iso: string): string {
    try {
      return new Date(iso).toLocaleString();
    } catch {
      return iso;
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="dialog-backdrop" onclick={onCancel} role="presentation">
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div
    class="dialog-card"
    data-testid="wtf-restore-dialog"
    bind:this={dialogCardEl}
    onclick={(e) => e.stopPropagation()}
    role="dialog"
    aria-modal="true"
    aria-labelledby="wtf-restore-title"
    aria-describedby="wtf-restore-message"
    tabindex="-1"
  >
    <div class="dialog-header">
      <h2 id="wtf-restore-title" class="dialog-title">
        Restore WTF for {flavourLabel}?
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
      <p id="wtf-restore-message" class="restore-message">
        This puts the {preview.file_count} files saved on {formatDate(preview.created_at)} ({formatBytes(preview.total_bytes)}) back into your live WTF folder, which holds {preview.live_file_count} files ({formatBytes(preview.live_total_bytes)}). Files that are not in the archive are left alone.
      </p>
      <p class="restore-note">
        Furphy copies your live WTF to a safety folder first and puts it back if the restore fails.
      </p>
      {#if preview.warning}
        <div class="warning-callout" role="alert">
          {preview.warning}
        </div>
      {/if}
      {#if isGameActive}
        <div class="warning-callout" role="alert">
          Restore cannot proceed while World of Warcraft is running. Exit the game first.
        </div>
      {/if}
    </div>

    <div class="dialog-footer">
      <button
        type="button"
        class="btn-secondary"
        data-testid="wtf-restore-cancel"
        bind:this={cancelButtonEl}
        onclick={onCancel}
      >
        Cancel
      </button>
      <button
        type="button"
        class="btn-primary"
        data-testid="wtf-restore-confirm"
        disabled={isGameActive || busy}
        onclick={onConfirm}
      >
        {busy ? 'Restoring...' : `Restore ${preview.file_count} files`}
      </button>
    </div>
  </div>
</div>

<style>
  .dialog-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.65);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .dialog-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    width: 90%;
    max-width: 520px;
    box-shadow: 0 16px 36px rgba(0, 0, 0, 0.4);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .dialog-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1.25rem 1.5rem;
    border-bottom: 1px solid var(--border);
  }

  .dialog-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text);
    margin: 0;
  }

  .btn-close {
    background: transparent;
    border: none;
    color: var(--text-muted);
    font-size: 1.25rem;
    cursor: pointer;
    padding: 0.25rem;
    line-height: 1;
    border-radius: var(--radius-sm, 4px);
  }

  .btn-close:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-close:hover {
    color: var(--text);
  }

  .dialog-body {
    padding: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .restore-message {
    font-size: 0.95rem;
    color: var(--text);
    margin: 0;
    line-height: 1.5;
  }

  .restore-note {
    font-size: 0.85rem;
    color: var(--text-muted);
    margin: 0;
    line-height: 1.4;
  }

  .warning-callout {
    background: var(--warning-tint);
    color: var(--warning);
    border: 1px solid color-mix(in srgb, var(--warning) 30%, transparent);
    padding: 0.75rem 1rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    line-height: 1.4;
  }

  .dialog-footer {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    gap: 0.75rem;
    padding: 1rem 1.5rem;
    background: var(--bg-2);
    border-top: 1px solid var(--border);
    flex-wrap: wrap;
  }

  .btn-primary, .btn-secondary {
    padding: 0.5rem 1rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast, 150ms), border-color var(--fast, 150ms);
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: 1px solid transparent;
  }

  .btn-primary:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .btn-primary:disabled {
    opacity: 0.5;
    cursor: not-allowed;
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

  .btn-secondary:hover:not(:disabled) {
    background: var(--border-hover);
  }

  .btn-secondary:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .btn-primary, .btn-secondary {
      transition: none;
    }
  }
</style>
