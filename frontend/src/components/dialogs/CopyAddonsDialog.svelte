<script lang="ts">
  import { tick } from 'svelte';
  import type { Addon, CopyItemResult, Flavour } from '../../lib/types';

  interface Props {
    open: boolean;
    sourceFlavour: string;
    flavours: Flavour[];
    addons: Addon[];
    preselectedIds: string[];
    onClose: () => void;
    onRun: (targetFlavour: string, addonIds: string[]) => Promise<CopyItemResult[]>;
  }

  let { open, sourceFlavour, flavours, addons, preselectedIds, onClose, onRun }: Props = $props();

  let targets = $derived(flavours.filter((f) => f.installed && f.id !== sourceFlavour));
  let sourceLabel = $derived(flavours.find((f) => f.id === sourceFlavour)?.label ?? sourceFlavour);

  let targetId = $state('');
  let selected = $state<Set<string>>(new Set());
  let running = $state(false);
  let results = $state<CopyItemResult[] | null>(null);
  let runError = $state<string | null>(null);
  let cardEl = $state<HTMLDivElement | null>(null);
  let targetEl = $state<HTMLSelectElement | null>(null);
  let opener: HTMLElement | null = null;
  let wasOpen = false;

  let targetLabel = $derived(targets.find((f) => f.id === targetId)?.label ?? targetId);
  let allSelected = $derived(addons.length > 0 && addons.every((a) => selected.has(a.id)));
  let selectedCount = $derived(addons.filter((a) => selected.has(a.id)).length);

  $effect(() => {
    if (open && !wasOpen) {
      wasOpen = true;
      opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      const wanted = preselectedIds.length > 0 ? preselectedIds : addons.map((a) => a.id);
      selected = new Set(wanted.filter((id) => addons.some((a) => a.id === id)));
      targetId = targets[0]?.id ?? '';
      results = null;
      runError = null;
      running = false;
      tick().then(() => targetEl?.focus());
    } else if (!open && wasOpen) {
      wasOpen = false;
      const back = opener;
      opener = null;
      tick().then(() => back?.focus());
    }
  });

  function toggle(id: string, on: boolean) {
    const next = new Set(selected);
    if (on) next.add(id);
    else next.delete(id);
    selected = next;
  }

  function toggleAll() {
    selected = allSelected ? new Set() : new Set(addons.map((a) => a.id));
  }

  async function run() {
    if (running || selectedCount === 0 || !targetId) return;
    running = true;
    results = null;
    runError = null;
    try {
      results = await onRun(
        targetId,
        addons.filter((a) => selected.has(a.id)).map((a) => a.id),
      );
    } catch (err) {
      runError = err instanceof Error ? err.message : String(err);
    } finally {
      running = false;
    }
  }

  function statusWord(status: string): string {
    if (status === 'installed') return 'Installed';
    if (status === 'skipped') return 'Skipped';
    return 'Failed';
  }

  function statusMark(status: string): string {
    if (status === 'installed') return '✓';
    if (status === 'skipped') return '–';
    return '✕';
  }

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      if (!running) onClose();
      return;
    }
    if (e.key === 'Tab' && cardEl) {
      const focusable = Array.from(
        cardEl.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled]), select:not([disabled])'),
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
</script>

<svelte:window onkeydown={handleKeydown} />

{#if open}
  <div class="dialog-backdrop" onclick={() => !running && onClose()} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div
      class="dialog-card"
      bind:this={cardEl}
      data-testid="copy-dialog"
      onclick={(e) => e.stopPropagation()}
      role="dialog"
      aria-modal="true"
      aria-labelledby="copy-title"
      tabindex="-1"
    >
      <div class="dialog-header">
        <h2 id="copy-title" class="dialog-title">Copy addons to another game version</h2>
        <button type="button" class="btn-close" onclick={onClose} disabled={running} aria-label="Close dialog">✕</button>
      </div>

      <div class="dialog-body">
        <p class="note">
          Copies from {sourceLabel}. Addons already in the target are skipped. Settings and saved variables are never copied.
        </p>

        {#if targets.length === 0}
          <p class="empty-text" role="status">No other game version is installed on this PC.</p>
        {:else if results === null}
          <label class="field-label" for="copy-target">Copy to</label>
          <select
            id="copy-target"
            class="field-select"
            data-testid="copy-target-select"
            bind:this={targetEl}
            bind:value={targetId}
            disabled={running}
          >
            {#each targets as f (f.id)}
              <option value={f.id}>{f.label}</option>
            {/each}
          </select>

          <div class="list-header">
            <span class="list-count">{selectedCount} of {addons.length} selected</span>
            <button type="button" class="btn-link" data-testid="copy-select-all" onclick={toggleAll} disabled={running}>
              {allSelected ? 'Select none' : 'Select all'}
            </button>
          </div>

          <ul class="addon-list" aria-label="Addons to copy">
            {#each addons as a (a.id)}
              <li>
                <label class="addon-option">
                  <input
                    type="checkbox"
                    data-testid={`copy-addon-${a.id}`}
                    checked={selected.has(a.id)}
                    disabled={running}
                    onchange={(e) => toggle(a.id, (e.currentTarget as HTMLInputElement).checked)}
                  />
                  <span class="addon-name">{a.name ?? a.id}</span>
                  {#if a.version}<span class="addon-version">{a.version}</span>{/if}
                </label>
              </li>
            {/each}
          </ul>
        {/if}

        {#if running}
          <p class="running-text" role="status">Copying {selectedCount} addons to {targetLabel}...</p>
        {/if}

        {#if runError}
          <p class="error-text" role="alert">{runError}</p>
        {/if}

        {#if results !== null}
          <div data-testid="copy-results" class="results" role="status">
            <p class="results-title">
              {results.filter((r) => r.status === 'installed').length} installed,
              {results.filter((r) => r.status === 'skipped').length} skipped,
              {results.filter((r) => r.status !== 'installed' && r.status !== 'skipped').length} failed
            </p>
            <ul class="result-list">
              {#each results as r (r.addon_id)}
                <li class="result-row" data-testid={`copy-result-${r.addon_id}`}>
                  <span class="result-mark result-{r.status}" aria-hidden="true">{statusMark(r.status)}</span>
                  <span class="result-name">{r.name}</span>
                  <span class="result-status">{statusWord(r.status)}</span>
                  <span class="result-message">{r.message}</span>
                </li>
              {/each}
            </ul>
          </div>
        {/if}
      </div>

      <div class="dialog-footer">
        {#if targets.length > 0 && results === null}
          {#if selectedCount === 0}
            <span class="footer-reason">Tick at least one addon.</span>
          {/if}
          <button type="button" class="btn-secondary" data-testid="copy-close" onclick={onClose} disabled={running}>Cancel</button>
          <button
            type="button"
            class="btn-primary"
            data-testid="copy-run"
            onclick={run}
            disabled={running || selectedCount === 0 || !targetId}
          >
            Copy {selectedCount} {selectedCount === 1 ? 'addon' : 'addons'} to {targetLabel}
          </button>
        {:else}
          <button type="button" class="btn-primary" data-testid="copy-close" onclick={onClose} disabled={running}>Close</button>
        {/if}
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
    max-width: 560px;
    max-height: 86vh;
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

  .btn-close:hover:not(:disabled) {
    color: var(--text);
  }

  .btn-close:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .dialog-body {
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    overflow-y: auto;
    min-height: 0;
  }

  .note,
  .empty-text,
  .running-text {
    margin: 0;
    font-size: 0.88rem;
    color: var(--text-muted);
    line-height: 1.45;
  }

  .field-label {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--text);
  }

  .field-select {
    background: var(--bg-0);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.5rem 0.75rem;
    font-size: 0.9rem;
  }

  .field-select:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .list-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .list-count {
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .btn-link {
    background: none;
    border: none;
    color: var(--accent);
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;
    padding: 2px 6px;
    border-radius: 4px;
  }

  .btn-link:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .addon-list {
    list-style: none;
    margin: 0;
    padding: 0;
    max-height: 260px;
    overflow-y: auto;
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-sm, 4px);
    background: var(--bg-0);
  }

  .addon-option {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.4rem 0.75rem;
    cursor: pointer;
    font-size: 0.9rem;
    color: var(--text);
  }

  .addon-option:hover {
    background: var(--bg-2);
  }

  .addon-version {
    margin-left: auto;
    font-size: 0.78rem;
    color: var(--text-muted);
    font-family: monospace;
  }

  .error-text {
    margin: 0;
    font-size: 0.88rem;
    font-weight: 600;
    color: var(--danger);
  }

  .results-title {
    margin: 0 0 0.5rem;
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text);
  }

  .result-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }

  .result-row {
    display: grid;
    grid-template-columns: 1.2rem minmax(0, 1fr) 4.8rem;
    column-gap: 0.5rem;
    row-gap: 0.1rem;
    align-items: baseline;
    font-size: 0.88rem;
    color: var(--text);
  }

  .result-message {
    grid-column: 2 / 4;
    color: var(--text-muted);
    font-size: 0.82rem;
  }

  .result-status {
    font-weight: 600;
  }

  .result-installed {
    color: var(--success, var(--accent));
  }

  .result-failed {
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

  .footer-reason {
    margin-right: auto;
    font-size: 0.85rem;
    color: var(--text-muted);
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

  .btn-primary:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
  }

  .btn-secondary:hover:not(:disabled) {
    background: var(--border-hover);
  }

  .btn-primary:disabled,
  .btn-secondary:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }

  .btn-primary:focus-visible,
  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
