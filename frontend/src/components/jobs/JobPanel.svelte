<script lang="ts">
  import type { JobRecord } from '../../lib/types';

  interface Props {
    job: JobRecord | null;
    activePhase?: string;
    currentAddon?: string;
    progressIndex?: number;
    progressTotal?: number;
    logs?: string[];
    onRetry?: () => void;
    onDismiss?: () => void;
    onOpenLog?: () => void;
  }

  let {
    job,
    activePhase = 'Checking',
    currentAddon = '',
    progressIndex = 0,
    progressTotal = 0,
    logs = [],
    onRetry,
    onDismiss,
    onOpenLog,
  }: Props = $props();

  let expanded = $state(false);

  let isRunning = $derived(job?.state === 'running');
  let isFailed = $derived(job?.state === 'failed');
  let isCompleted = $derived(job?.state === 'completed');

  let percent = $derived.by(() => {
    if (!progressTotal || progressTotal <= 0) return isCompleted ? 100 : 0;
    return Math.min(100, Math.round((progressIndex / progressTotal) * 100));
  });

  function toggleExpand() {
    expanded = !expanded;
  }
</script>

{#if job}
  <aside
    class="job-panel"
    class:running={isRunning}
    class:failed={isFailed}
    class:completed={isCompleted}
    aria-label="Background Job Status"
  >
    <div class="job-bar">
      <div class="job-status-indicator">
        {#if isRunning}
          <span class="spinner" aria-hidden="true"></span>
        {:else if isFailed}
          <span class="status-icon failed-icon">✕</span>
        {:else}
          <span class="status-icon done-icon">✓</span>
        {/if}
      </div>

      <div class="job-info">
        <div class="job-headline">
          {#if isRunning}
            <span class="phase-name">{activePhase}:</span>
            <span class="addon-name">{currentAddon || 'Processing...'}</span>
            {#if progressTotal > 0}
              <span class="tally">({progressIndex} / {progressTotal})</span>
            {/if}
          {:else if isFailed}
            <span class="phase-name failed-text">Job Failed:</span>
            <span class="addon-name">{job.error || 'An unexpected error occurred'}</span>
          {:else}
            <span class="phase-name success-text">Complete:</span>
            <span class="addon-name">{job.kind} finished successfully</span>
          {/if}
        </div>

        {#if isRunning}
          <div
            class="progress-track"
            role="progressbar"
            aria-valuenow={percent}
            aria-valuemin="0"
            aria-valuemax="100"
          >
            <div class="progress-fill" style:width="{percent}%"></div>
          </div>
        {/if}
      </div>

      <div class="job-actions">
        {#if isFailed && onRetry}
          <button
            type="button"
            class="btn-sm btn-retry"
            onclick={onRetry}
          >
            Retry
          </button>
        {/if}

        <button
          type="button"
          class="btn-sm btn-logs"
          onclick={toggleExpand}
          aria-expanded={expanded}
        >
          {expanded ? 'Hide Log' : 'View Log'}
        </button>

        {#if !isRunning && onDismiss}
          <button
            type="button"
            class="btn-sm btn-dismiss"
            onclick={onDismiss}
            aria-label="Dismiss job panel"
          >
            ✕
          </button>
        {/if}
      </div>
    </div>

    {#if expanded}
      <div class="job-log-drawer">
        <div class="log-controls">
          <span class="log-title">Execution Log</span>
          {#if onOpenLog}
            <button
              type="button"
              class="btn-text"
              onclick={onOpenLog}
            >
              Open log file ↗
            </button>
          {/if}
        </div>
        <div class="log-terminal">
          {#if logs.length > 0}
            {#each logs as line, i (i)}
              <div class="log-line">{line}</div>
            {/each}
          {:else}
            <div class="log-line text-muted">No log entries available.</div>
          {/if}
        </div>
      </div>
    {/if}
  </aside>
{/if}

<style>
  .job-panel {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.35);
    overflow: hidden;
    transition: border-color var(--fast), background var(--fast);
    margin: 0.5rem 1rem 0.5rem 1rem;
  }

  .job-panel.running {
    border-color: var(--accent);
  }

  .job-panel.failed {
    border-color: var(--danger-border);
    background: var(--bg-1);
  }

  .job-panel.completed {
    border-color: rgba(47, 230, 167, 0.35);
  }

  .job-bar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.65rem 1rem;
  }

  .job-status-indicator {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    flex-shrink: 0;
  }

  .spinner {
    width: 16px;
    height: 16px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .status-icon {
    font-size: 0.85rem;
    font-weight: 700;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .failed-icon {
    background: var(--danger-tint);
    color: var(--danger);
    border: 1px solid var(--danger-border);
  }

  .done-icon {
    background: var(--success-tint);
    color: var(--success);
    border: 1px solid rgba(47, 230, 167, 0.35);
  }

  .job-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    min-width: 0;
  }

  .job-headline {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.85rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .phase-name {
    font-weight: 600;
    color: var(--text);
  }

  .failed-text {
    color: var(--danger);
  }

  .success-text {
    color: var(--success);
  }

  .addon-name {
    color: var(--text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .tally {
    color: var(--text-faint);
    font-size: 0.8rem;
  }

  .progress-track {
    width: 100%;
    height: 4px;
    background: var(--bg-3);
    border-radius: 2px;
    overflow: hidden;
  }

  .progress-fill {
    height: 100%;
    background: var(--accent);
    transition: width 0.2s ease-out;
  }

  .job-actions {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex-shrink: 0;
  }

  .btn-sm {
    padding: 0.25rem 0.6rem;
    font-size: 0.75rem;
    font-weight: 600;
    border-radius: var(--radius-sm, 4px);
    cursor: pointer;
    border: 1px solid var(--border);
    background: var(--bg-3);
    color: var(--text);
    transition: background var(--fast), border-color var(--fast);
  }

  .btn-sm:hover {
    background: var(--border-hover);
  }

  .btn-sm:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .btn-retry {
    background: var(--danger-tint);
    border-color: var(--danger-border);
    color: var(--danger);
  }

  .btn-retry:hover {
    background: rgba(255, 111, 120, 0.25);
  }

  .btn-dismiss {
    padding: 0.25rem 0.5rem;
  }

  .job-log-drawer {
    border-top: 1px solid var(--border);
    background: var(--bg-0);
    padding: 0.75rem 1rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .log-controls {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .log-title {
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-muted);
  }

  .btn-text {
    background: none;
    border: none;
    color: var(--accent);
    font-size: 0.75rem;
    cursor: pointer;
    padding: 0;
  }

  .btn-text:hover {
    text-decoration: underline;
  }

  .btn-text:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .log-terminal {
    max-height: 160px;
    overflow-y: auto;
    font-family: monospace;
    font-size: 0.75rem;
    background: rgba(0, 0, 0, 0.4);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-sm, 4px);
    padding: 0.5rem 0.75rem;
    color: var(--text);
    line-height: 1.4;
  }

  .log-line {
    white-space: pre-wrap;
    word-break: break-all;
  }

  .text-muted {
    color: var(--text-muted);
  }
</style>
