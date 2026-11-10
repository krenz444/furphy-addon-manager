<script lang="ts">
  import { tick } from 'svelte';

  interface Props {
    open: boolean;
    mode: 'create' | 'rename';
    initialName?: string;
    error?: string | null;
    onSave: (name: string) => void;
    onCancel: () => void;
  }

  let { open, mode, initialName = '', error = null, onSave, onCancel }: Props = $props();

  let name = $state('');
  let localError = $state<string | null>(null);
  let inputEl = $state<HTMLInputElement | null>(null);
  let cardEl = $state<HTMLDivElement | null>(null);
  let opener: HTMLElement | null = null;
  let wasOpen = false;

  $effect(() => {
    if (open && !wasOpen) {
      wasOpen = true;
      opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      name = initialName ?? '';
      localError = null;
      tick().then(() => {
        inputEl?.focus();
        inputEl?.select();
      });
    } else if (!open && wasOpen) {
      wasOpen = false;
      const target = opener;
      opener = null;
      tick().then(() => target?.focus());
    }
  });

  function save() {
    const trimmed = name.trim();
    if (!trimmed) {
      localError = 'Enter a name';
      inputEl?.focus();
      return;
    }
    localError = null;
    onSave(trimmed);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      onCancel();
      return;
    }
    if (e.key === 'Tab' && cardEl) {
      const focusable = Array.from(
        cardEl.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled])'),
      );
      if (focusable.length === 0) return;
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

  let shownError = $derived(localError ?? error);
</script>

<svelte:window onkeydown={handleKeydown} />

{#if open}
  <div class="dialog-backdrop" onclick={onCancel} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-card"
      bind:this={cardEl}
      data-testid="group-name-dialog"
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-labelledby="group-name-title"
      tabindex="-1"
    >
      <div class="dialog-header">
        <h2 id="group-name-title" class="dialog-title">{mode === 'rename' ? 'Rename group' : 'New group'}</h2>
        <button type="button" class="btn-close" onclick={onCancel} aria-label="Close dialog">✕</button>
      </div>

      <form
        class="dialog-body"
        onsubmit={(e) => {
          e.preventDefault();
          save();
        }}
      >
        <label class="field-label" for="group-name-field">Group name</label>
        <input
          id="group-name-field"
          type="text"
          class="field-input"
          data-testid="group-name-input"
          maxlength="40"
          autocomplete="off"
          bind:this={inputEl}
          bind:value={name}
          aria-invalid={shownError ? 'true' : 'false'}
          aria-describedby={shownError ? 'group-name-error' : undefined}
        />
        <div class="field-hint">Up to 40 characters. Each name can be used once.</div>
        {#if shownError}
          <div id="group-name-error" class="field-error" role="alert">{shownError}</div>
        {/if}
      </form>

      <div class="dialog-footer">
        <button type="button" class="btn-secondary" data-testid="group-name-cancel" onclick={onCancel}>Cancel</button>
        <button type="button" class="btn-primary" data-testid="group-name-save" onclick={save}>
          {mode === 'rename' ? 'Rename' : 'Create group'}
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
    max-width: 420px;
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
  }

  .btn-close:hover {
    color: var(--text);
  }

  .btn-close:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .dialog-body {
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .field-label {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--text);
  }

  .field-input {
    background: var(--bg-0);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.55rem 0.75rem;
    font-size: 0.95rem;
  }

  .field-input:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .field-input[aria-invalid='true'] {
    border-color: var(--danger);
  }

  .field-hint {
    font-size: 0.8rem;
    color: var(--text-muted);
  }

  .field-error {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--danger);
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

  .btn-primary,
  .btn-secondary {
    padding: 0.5rem 1rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: 1px solid transparent;
  }

  .btn-primary:hover {
    background: var(--accent-hover);
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-primary:focus-visible,
  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
