<script lang="ts">
  import type { Addon } from '../../lib/types';

  interface Props {
    open: boolean;
    addon: Addon | null;
    onUpdateAndZip: (addon: Addon) => void;
    onUpdateAnyway: (addon: Addon) => void;
    onSkip: () => void;
  }

  let {
    open,
    addon,
    onUpdateAndZip,
    onUpdateAnyway,
    onSkip,
  }: Props = $props();

  let skipButtonEl = $state<HTMLButtonElement | null>(null);

  $effect(() => {
    if (open) {
      requestAnimationFrame(() => {
        skipButtonEl?.focus();
      });
    }
  });

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      onSkip();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if open && addon}
  <div class="dialog-backdrop" onclick={onSkip} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-card"
      data-testid="modified-dialog"
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-labelledby="modified-title"
      aria-describedby="modified-message"
      tabindex="-1"
    >
      <div class="dialog-header">
        <h2 id="modified-title" class="dialog-title">
          Local files modified
        </h2>
        <button
          type="button"
          class="btn-close"
          onclick={onSkip}
          aria-label="Close dialog"
        >
          ✕
        </button>
      </div>

      <div class="dialog-body">
        <p id="modified-message" class="modified-message">
          You have edited files in this addon. Updating will overwrite your changes.
        </p>
      </div>

      <div class="dialog-footer">
        <button
          type="button"
          class="btn-secondary"
          data-testid="btn-modified-skip"
          bind:this={skipButtonEl}
          onclick={onSkip}
        >
          Skip
        </button>
        <button
          type="button"
          class="btn-secondary"
          data-testid="btn-modified-update-anyway"
          onclick={() => addon && onUpdateAnyway(addon)}
        >
          Update anyway
        </button>
        <button
          type="button"
          class="btn-primary"
          data-testid="btn-modified-update-zip"
          onclick={() => addon && onUpdateAndZip(addon)}
        >
          Update and keep my copy as a zip
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
    max-width: 540px;
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

  .modified-message {
    font-size: 0.95rem;
    color: var(--text);
    margin: 0;
    line-height: 1.5;
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
