<script lang="ts">
  import type { Freshness } from '../../lib/types';
  import { formatCheckedAgo } from '../../lib/timeAgo';

  interface Props {
    freshness: Freshness | null;
    checking?: boolean;
    onCheckNow?: () => void;
    onUpdateAll?: () => void;
    dotOnly?: boolean;
  }

  let { freshness, checking = false, onCheckNow, onUpdateAll, dotOnly = false }: Props = $props();

  // The backend calls a list that was never checked "clean"; without a timestamp that is not a verdict.
  let freshState = $derived.by(() => {
    if (checking) return 'checking';
    const reported = freshness?.state ?? 'not_checked';
    if ((reported === 'clean' || reported === 'up_to_date') && !freshness?.checked_at) return 'not_checked';
    return reported;
  });
  let updatesCount = $derived(freshness?.updates_count ?? 0);
  let errorMsg = $derived(freshness?.last_error ?? null);

  let now = $state(Date.now());
  $effect(() => {
    const timer = setInterval(() => (now = Date.now()), 30_000);
    return () => clearInterval(timer);
  });

  let showCheckedLine = $derived(
    !dotOnly &&
      !!onCheckNow &&
      freshState !== 'checking' &&
      (freshState === 'updates_ready' || updatesCount > 0 || freshState === 'clean' || freshState === 'up_to_date')
  );
</script>

<div class="freshness-row" class:dot-only={dotOnly} role="status">
  {#if freshState === 'checking'}
    <span class="freshness-dot is-checking" aria-label="Checking"></span>
    {#if !dotOnly}
      <span class="freshness-text">Checking for updates…</span>
    {/if}
  {:else if freshState === 'updates_ready' || updatesCount > 0}
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
  {:else if freshState === 'clean' || freshState === 'up_to_date'}
    <span class="freshness-dot is-success" aria-label="Up to date"></span>
    {#if !dotOnly}
      <span class="freshness-text">Everything’s up to date</span>
    {/if}
  {:else if freshState === 'failed' || freshState === 'error'}
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

{#if showCheckedLine}
  <!-- Outside the status region: the age changes every minute and must not be announced each time. -->
  <div class="checked-line">
    <span>{formatCheckedAgo(freshness?.checked_at, now)}</span>
    <span aria-hidden="true">·</span>
    <button type="button" class="inline-link" onclick={onCheckNow}>Check now</button>
  </div>
{/if}

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

  .checked-line {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 6px;
    font-size: 11.5px;
    color: var(--text-muted);
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

  @media (prefers-reduced-motion: reduce) {
    .is-checking {
      animation: none;
    }
  }
</style>
