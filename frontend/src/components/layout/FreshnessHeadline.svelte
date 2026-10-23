<script lang="ts">
  import type { Freshness } from '../../lib/types';

  interface Props {
    freshness: Freshness | null;
    onCheckNow?: () => void;
    onUpdateAll?: () => void;
    dotOnly?: boolean;
  }

  let { freshness, onCheckNow, onUpdateAll, dotOnly = false }: Props = $props();

  let state = $derived(freshness?.state ?? 'not_checked');
  let updatesCount = $derived(freshness?.updates_count ?? 0);
  let errorMsg = $derived(freshness?.last_error ?? null);
</script>

<div class="freshness-row" class:dot-only={dotOnly} role="status">
  {#if state === 'checking'}
    <span class="freshness-dot is-checking" aria-label="Checking"></span>
    {#if !dotOnly}
      <span class="freshness-text">Checking for updates…</span>
    {/if}
  {:else if state === 'updates_ready' || updatesCount > 0}
    <span class="freshness-dot is-accent" aria-label="Updates available"></span>
    {#if !dotOnly}
      <span class="freshness-text">
        <strong>{updatesCount}</strong> update{updatesCount === 1 ? '' : 's'} ready
      </span>
      {#if onUpdateAll}
        <button type="button" class="action-btn update-btn" onclick={onUpdateAll}>
          Update all
        </button>
      {/if}
    {/if}
  {:else if state === 'clean' || state === 'up_to_date'}
    <span class="freshness-dot is-success" aria-label="Up to date"></span>
    {#if !dotOnly}
      <span class="freshness-text">Everything’s up to date</span>
    {/if}
  {:else if state === 'failed' || state === 'error'}
    <span class="freshness-dot is-danger" aria-label="Failed check"></span>
    {#if !dotOnly}
      <span class="freshness-text error-text">
        Couldn’t check
        {#if onCheckNow}
          · <button type="button" class="inline-link" onclick={onCheckNow}>Retry</button>
        {/if}
      </span>
      {#if errorMsg}
        <span class="error-detail" title={errorMsg}>{errorMsg}</span>
      {/if}
    {/if}
  {:else}
    <span class="freshness-dot is-muted" aria-label="Not checked yet"></span>
    {#if !dotOnly}
      <span class="freshness-text">
        Not checked yet
        {#if onCheckNow}
          · <button type="button" class="inline-link" onclick={onCheckNow}>Check now</button>
        {/if}
      </span>
    {/if}
  {/if}
</div>

<style>
  .freshness-row {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12.5px;
    flex-wrap: wrap;
  }

  .freshness-row.dot-only {
    gap: 0;
  }

  .freshness-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex: none;
  }

  .is-checking {
    background: var(--accent);
    box-shadow: 0 0 0 3px var(--accent-tint);
    animation: pulse 1.2s ease-in-out infinite;
  }

  .is-accent {
    background: var(--accent);
    box-shadow: 0 0 0 3px var(--accent-tint);
  }

  .is-success {
    background: var(--success);
    box-shadow: 0 0 0 3px var(--success-tint);
  }

  .is-danger {
    background: var(--danger);
    box-shadow: 0 0 0 3px var(--danger-tint);
  }

  .is-muted {
    background: var(--text-faint);
  }

  .freshness-text {
    color: var(--text);
  }

  .error-text {
    color: var(--danger);
    font-weight: 600;
  }

  .error-detail {
    font-size: 11px;
    color: var(--text-faint);
    max-width: 200px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .inline-link {
    background: none;
    border: none;
    padding: 0;
    margin: 0;
    color: var(--accent);
    text-decoration: underline;
    cursor: pointer;
    font: inherit;
    font-weight: 600;
  }

  .inline-link:hover {
    color: var(--accent-hover);
  }

  .inline-link:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .action-btn {
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: var(--radius-sm);
    border: none;
    cursor: pointer;
    transition: background var(--fast);
  }

  .update-btn {
    background: var(--accent);
    color: var(--accent-text);
  }

  .update-btn:hover {
    background: var(--accent-hover);
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.5; transform: scale(0.9); }
  }
</style>
