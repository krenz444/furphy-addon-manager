<script lang="ts">
  import {
    describeJobTitle,
    jobHasActionableErrors,
    summarizeCheck,
  } from '../../lib/checkReport';
  import type {
    Flavour,
    JobProgressEvent,
    JobRecord,
    QueuedJobDto,
  } from '../../lib/types';

  interface Props {
    activeJob: JobRecord | null;
    activeProgress: JobProgressEvent | null;
    queuedJobs: QueuedJobDto[];
    flavours?: Flavour[];
    lastFinishedJob?: JobRecord | null;
    onDismissFinished?: () => void;
    onOpenLog?: () => void;
  }

  let {
    activeJob,
    activeProgress,
    queuedJobs,
    flavours = [],
    lastFinishedJob = null,
    onDismissFinished,
    onOpenLog,
  }: Props = $props();

  let queueCollapsed = $state(false);

  $effect(() => {
    if (queuedJobs.length === 0) {
      queueCollapsed = false;
    }
  });

  function extractTargetLabel(job: JobRecord | null): string | null {
    if (!job?.params) return null;
    try {
      const parsed = JSON.parse(job.params) as Record<string, unknown>;
      if (typeof parsed.addon_name === 'string' && parsed.addon_name) return parsed.addon_name;
      if (typeof parsed.addon_id === 'string' && parsed.addon_id) return parsed.addon_id;
      if (typeof parsed.target === 'string' && parsed.target) return parsed.target;
    } catch {
      return null;
    }
    return null;
  }

  function formatPhase(phase: string | null | undefined): string {
    if (!phase) return 'Running';
    const cleaned = phase.replace(/[_-]+/g, ' ').trim();
    if (!cleaned) return 'Running';
    return cleaned.charAt(0).toUpperCase() + cleaned.slice(1);
  }

  let isRunning = $derived(activeJob?.state === 'running');
  let hasQueued = $derived(queuedJobs.length > 0);
  let targetLabel = $derived(extractTargetLabel(activeJob));

  let activeTitle = $derived.by(() => {
    if (!activeJob) return '';
    return describeJobTitle(activeJob.kind, activeJob.flavour, flavours, targetLabel, 'active');
  });

  let progressStep = $derived(
    activeProgress && (!activeJob || activeProgress.job_id === activeJob.id)
      ? activeProgress.step
      : null,
  );

  let isDeterminate = $derived(Boolean(progressStep && progressStep.total > 0));
  let clampedPercent = $derived.by(() => {
    if (!activeProgress || !progressStep || progressStep.total <= 0) return 0;
    const raw =
      Number.isFinite(activeProgress.percent) && activeProgress.percent > 0
        ? activeProgress.percent
        : Math.round((progressStep.index / progressStep.total) * 100);
    return Math.max(0, Math.min(100, raw));
  });

  let phaseLabel = $derived(formatPhase(progressStep?.phase));

  let runningDetail = $derived.by(() => {
    if (!isRunning) return '';
    const parts: string[] = [];
    if (progressStep?.phase) {
      parts.push(phaseLabel);
    }
    if (progressStep?.addon) {
      parts.push(progressStep.addon);
    } else if (activeProgress?.message) {
      parts.push(activeProgress.message);
    } else if (!progressStep) {
      parts.push('Running in the background');
    }
    return parts.join(' - ');
  });

  let tallyBadges = $derived.by(() => {
    const t = progressStep?.tallies;
    if (!t) return [];
    const items: Array<{ label: string; tone: 'info' | 'success' | 'danger' }> = [];
    if (t.updates_found > 0) {
      items.push({
        label: `${t.updates_found} ${t.updates_found === 1 ? 'update' : 'updates'}`,
        tone: 'info',
      });
    }
    if (t.updated > 0) {
      items.push({ label: `${t.updated} updated`, tone: 'success' });
    }
    if (t.failed > 0) {
      items.push({ label: `${t.failed} failed`, tone: 'danger' });
    }
    return items;
  });

  let lastFinishedHasError = $derived(
    lastFinishedJob
      ? jobHasActionableErrors(lastFinishedJob.results, lastFinishedJob.state, lastFinishedJob.error)
      : false,
  );

  let lastFinishedSummary = $derived.by(() => {
    if (!lastFinishedJob) return '';
    const action = describeJobTitle(
      lastFinishedJob.kind,
      lastFinishedJob.flavour,
      flavours,
      extractTargetLabel(lastFinishedJob),
      'queued',
    );
    if (lastFinishedJob.state === 'failed') {
      return `Failed: ${action}`;
    }
    if (lastFinishedHasError) {
      return `Finished with errors: ${action}`;
    }
    if (lastFinishedJob.kind === 'check') {
      const s = summarizeCheck(lastFinishedJob);
      if (s && s.checked > 0) {
        return `Completed: ${action} (${s.updates} ${s.updates === 1 ? 'update' : 'updates'} across ${s.checked} addons)`;
      }
    }
    return `Completed: ${action}`;
  });
</script>

<section
  class="job-status-bar"
  class:is-running={isRunning}
  class:is-queued={!isRunning && hasQueued}
  class:is-error={!isRunning && !hasQueued && lastFinishedHasError}
  class:is-done={!isRunning && !hasQueued && Boolean(lastFinishedJob) && !lastFinishedHasError}
  aria-label="Task runner status"
>
  <div class="bar-main">
    <div class="bar-left" aria-live="polite">
      <span
        class="status-dot"
        class:is-running={isRunning}
        class:is-queued={!isRunning && hasQueued}
        class:is-error={!isRunning && !hasQueued && lastFinishedHasError}
        class:is-done={!isRunning && !hasQueued && Boolean(lastFinishedJob) && !lastFinishedHasError}
        aria-hidden="true"
      ></span>

      {#if isRunning}
        <span class="status-title">{activeTitle}</span>
        {#if runningDetail}
          <span class="status-sep" aria-hidden="true">·</span>
          <span class="status-detail" title={runningDetail}>{runningDetail}</span>
        {/if}
        {#if tallyBadges.length > 0}
          <span class="tally-group">
            {#each tallyBadges as badge}
              <span class="tally-pill tone-{badge.tone}">{badge.label}</span>
            {/each}
          </span>
        {/if}
      {:else if hasQueued}
        <span class="status-title">Starting queued task</span>
        <span class="status-sep" aria-hidden="true">·</span>
        <span class="status-detail">
          {describeJobTitle(queuedJobs[0].kind, queuedJobs[0].flavour, flavours, queuedJobs[0].target_label, 'queued')}
        </span>
      {:else if lastFinishedJob}
        <span class="status-title">{lastFinishedSummary}</span>
        {#if lastFinishedJob.state === 'failed' && lastFinishedJob.error}
          <span class="status-sep" aria-hidden="true">·</span>
          <span class="status-detail" title={lastFinishedJob.error}>{lastFinishedJob.error}</span>
        {/if}
      {:else}
        <span class="status-title">Ready</span>
        <span class="status-sep" aria-hidden="true">·</span>
        <span class="status-detail">Idle - no tasks running</span>
      {/if}
    </div>

    <div class="bar-right">
      {#if isRunning}
        {#if isDeterminate && progressStep}
          <span class="progress-count">{progressStep.index} of {progressStep.total} - {clampedPercent}%</span>
        {:else}
          <span class="progress-count">{phaseLabel}</span>
        {/if}
      {/if}

      {#if hasQueued}
        <button
          type="button"
          class="queue-toggle-btn"
          aria-expanded={!queueCollapsed}
          aria-controls="job-status-queue-list"
          onclick={() => (queueCollapsed = !queueCollapsed)}
        >
          Queued ({queuedJobs.length})
          <svg
            class="chevron"
            class:rotated={!queueCollapsed}
            width="12"
            height="12"
            viewBox="0 0 12 12"
            fill="none"
            stroke="currentColor"
            stroke-width="1.6"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M3 4.5L6 7.5L9 4.5" />
          </svg>
        </button>
      {:else if !isRunning && lastFinishedJob}
        {#if lastFinishedJob.log_path && onOpenLog}
          <button type="button" class="status-action-btn" onclick={onOpenLog}>
            View log
          </button>
        {/if}
        {#if onDismissFinished}
          <button
            type="button"
            class="status-action-btn"
            aria-label="Clear finished status"
            onclick={onDismissFinished}
          >
            Dismiss
          </button>
        {/if}
      {/if}
    </div>
  </div>

  {#if isRunning}
    <div
      class="progress-track"
      role="progressbar"
      aria-label={activeTitle}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={isDeterminate ? clampedPercent : undefined}
      aria-valuetext={isDeterminate && progressStep ? `${progressStep.index} of ${progressStep.total} (${clampedPercent}%)` : (runningDetail || activeTitle)}
    >
      {#if isDeterminate}
        <div class="progress-fill" style="width: {clampedPercent}%"></div>
      {:else}
        <div class="progress-fill is-indeterminate"></div>
      {/if}
    </div>
  {/if}

  {#if hasQueued && !queueCollapsed}
    <ol id="job-status-queue-list" class="queue-list" aria-label="Queued tasks in execution order">
      {#each queuedJobs as item (item.queue_id)}
        <li class="queue-item">
          <span class="queue-pos">#{item.position}</span>
          <span class="queue-label">
            {describeJobTitle(item.kind, item.flavour, flavours, item.target_label, 'queued')}
          </span>
        </li>
      {/each}
    </ol>
  {/if}
</section>

<style>
  .job-status-bar {
    flex-shrink: 0;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    box-sizing: border-box;
    background: var(--bg-1);
    border-bottom: 1px solid color-mix(in srgb, var(--text-faint) 75%, var(--bg-1));
    padding: 8px 16px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    font-size: 12.5px;
    line-height: 1.35;
    overflow: hidden;
  }

  .job-status-bar.is-error {
    background: color-mix(in srgb, var(--danger-tint) 60%, var(--bg-1));
  }

  .bar-main {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    min-width: 0;
    flex-wrap: wrap;
  }

  .bar-left {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
    flex: 1 1 260px;
    overflow: hidden;
  }

  .bar-right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
    min-width: 0;
  }

  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    background: var(--text-faint);
  }

  .status-dot.is-running {
    background: var(--info);
    animation: statusPulse 1.6s ease-in-out infinite;
  }

  .status-dot.is-queued {
    background: var(--warning);
  }

  .status-dot.is-done {
    background: var(--success);
  }

  .status-dot.is-error {
    background: var(--danger);
  }

  .status-title {
    color: var(--text);
    font-weight: 600;
    white-space: nowrap;
    flex-shrink: 0;
  }

  .status-sep {
    color: var(--text-faint);
    flex-shrink: 0;
  }

  .status-detail {
    color: var(--text-muted);
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .tally-group {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    flex-shrink: 0;
  }

  .tally-pill {
    padding: 1px 6px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 600;
    background: var(--bg-2);
    border: 1px solid color-mix(in srgb, var(--text-faint) 75%, var(--bg-1));
    white-space: nowrap;
  }

  .tally-pill.tone-info {
    color: var(--info);
  }

  .tally-pill.tone-success {
    color: var(--success);
  }

  .tally-pill.tone-danger {
    color: var(--danger);
  }

  .progress-count {
    color: var(--text-muted);
    font-size: 12px;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .progress-track {
    position: relative;
    width: 100%;
    height: 6px;
    border-radius: 999px;
    background: var(--bg-3);
    border: 1px solid color-mix(in srgb, var(--text-faint) 75%, var(--bg-1));
    overflow: hidden;
  }

  .progress-fill {
    height: 100%;
    background: var(--info);
    border-radius: 999px;
    transition: width 180ms ease;
  }

  .progress-fill.is-indeterminate {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 34%;
    animation: indeterminateSlide 1.3s ease-in-out infinite;
  }

  .queue-toggle-btn,
  .status-action-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    border-radius: 6px;
    background: var(--bg-2);
    border: 1px solid color-mix(in srgb, var(--text-faint) 75%, var(--bg-1));
    color: var(--text);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
  }

  .queue-toggle-btn {
    color: var(--info);
  }

  .queue-toggle-btn:hover,
  .status-action-btn:hover {
    background: var(--bg-3);
  }

  .queue-toggle-btn:focus-visible,
  .status-action-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .chevron {
    transition: transform 150ms ease;
  }

  .chevron.rotated {
    transform: rotate(180deg);
  }

  .queue-list {
    margin: 0;
    padding: 4px 0 0;
    list-style: none;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    min-width: 0;
  }

  .queue-item {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 2px 8px;
    border-radius: 6px;
    background: var(--bg-2);
    border: 1px solid color-mix(in srgb, var(--text-faint) 75%, var(--bg-1));
    color: var(--text);
    font-size: 12px;
    max-width: 100%;
    min-width: 0;
  }

  .queue-pos {
    color: var(--text-muted);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
  }

  .queue-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  @keyframes statusPulse {
    0%, 100% {
      opacity: 1;
    }
    50% {
      opacity: 0.45;
    }
  }

  @keyframes indeterminateSlide {
    0% {
      left: -34%;
    }
    100% {
      left: 100%;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .status-dot.is-running,
    .progress-fill,
    .progress-fill.is-indeterminate,
    .chevron {
      animation: none;
      transition: none;
    }

    .progress-fill.is-indeterminate {
      left: 0;
      width: 100%;
      opacity: 0.72;
    }
  }
</style>
