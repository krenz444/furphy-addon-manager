<script lang="ts">
  import type { Addon } from '../../lib/types';

  interface Props {
    open: boolean;
    addon: Addon | null;
    clientBuild?: string;
    onUpdateAnyway: (addon: Addon) => void;
    onIgnoreForBuild: (addon: Addon, build: string) => void;
    onCancel: () => void;
  }

  let {
    open,
    addon,
    clientBuild = '',
    onUpdateAnyway,
    onIgnoreForBuild,
    onCancel,
  }: Props = $props();

  let dialogCardEl = $state<HTMLDivElement | null>(null);
  let cancelButtonEl = $state<HTMLButtonElement | null>(null);

  $effect(() => {
    if (open) {
      requestAnimationFrame(() => {
        cancelButtonEl?.focus();
      });
    }
  });

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
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
</script>

<svelte:window onkeydown={handleKeydown} />

{#if open && addon}
  <div class="dialog-backdrop" onclick={onCancel} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-card"
      data-testid="hold-dialog"
      bind:this={dialogCardEl}
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-labelledby="hold-title"
      aria-describedby="hold-message"
      tabindex="-1"
    >
      <div class="dialog-header">
        <h2 id="hold-title" class="dialog-title">
          Update held back
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
        <p id="hold-message" class="hold-message">
          This update is built for a newer version of World of Warcraft.
        </p>
        {#if addon.held_reason}
          <div class="hold-detail">
            {addon.held_reason}
          </div>
        {/if}
      </div>

      <div class="dialog-footer">
        <button
          type="button"
          class="btn-secondary"
          data-testid="btn-hold-cancel"
          bind:this={cancelButtonEl}
          onclick={onCancel}
        >
          Cancel
        </button>
        <button
          type="button"
          class="btn-secondary"
          data-testid="btn-hold-ignore-build"
          onclick={() => addon && onIgnoreForBuild(addon, clientBuild)}
        >
          Ignore for this WoW version
        </button>
        <button
          type="button"
          class="btn-primary"
          data-testid="btn-hold-update-anyway"
          onclick={() => addon && onUpdateAnyway(addon)}
        >
          Update anyway
        </button>
      </div>
    </div>
  </div>
{/if}

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
    color: var(--warning);
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

  .hold-message {
    font-size: 0.95rem;
    color: var(--text);
    margin: 0;
    line-height: 1.5;
  }

  .hold-detail {
    font-size: 0.85rem;
    color: var(--text-muted);
    background: var(--bg-2);
    padding: 0.75rem 1rem;
    border-radius: var(--radius-sm, 4px);
    border: 1px solid var(--border);
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

  @media (prefers-reduced-motion: reduce) {
    .btn-primary, .btn-secondary {
      transition: none;
    }
  }
</style>
