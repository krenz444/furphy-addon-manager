<script lang="ts">
  import type { WholeWtfBackup } from '../../lib/types';

  interface Props {
    activeFlavour: string;
    isGameActive: boolean;
    backups: WholeWtfBackup[];
    onBackupNow: () => void;
    onRestorePreview: (backupId: string) => void;
    onDeleteBackup: (backupId: string) => void;
  }

  let {
    activeFlavour,
    isGameActive,
    backups,
    onBackupNow,
    onRestorePreview,
    onDeleteBackup,
  }: Props = $props();

  let localMockGameRunning = $state<boolean | null>(null);
  let localBackups = $state<WholeWtfBackup[] | null>(null);

  $effect(() => {
    const handleGameRunning = (e: Event) => {
      const customEvent = e as CustomEvent<{ running: boolean }>;
      if (customEvent.detail) {
        localMockGameRunning = customEvent.detail.running;
      }
    };
    const handleBackups = (e: Event) => {
      const customEvent = e as CustomEvent<{ backups: WholeWtfBackup[] }>;
      if (customEvent.detail) {
        localBackups = customEvent.detail.backups;
      }
    };
    window.addEventListener('furphy:game-running', handleGameRunning);
    window.addEventListener('furphy:wtf-backups', handleBackups);
    return () => {
      window.removeEventListener('furphy:game-running', handleGameRunning);
      window.removeEventListener('furphy:wtf-backups', handleBackups);
    };
  });

  let effectiveIsGameActive = $derived(localMockGameRunning !== null ? localMockGameRunning : isGameActive);
  let effectiveBackups = $derived(localBackups !== null ? localBackups : backups);

  function handleRestoreClick(backupId: string) {
    if (effectiveIsGameActive) {
      return;
    }
    onRestorePreview(backupId);
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

<div class="wtf-backup-panel" data-testid="wtf-backup-panel">
  <div class="panel-header">
    <div class="panel-title-group">
      <h4 class="panel-title">Whole-WTF Archives</h4>
      <span class="panel-subtext">Save or restore entire WTF configuration for {activeFlavour}.</span>
    </div>
    <button
      type="button"
      class="btn-primary"
      data-testid="btn-wtf-backup-now"
      onclick={onBackupNow}
    >
      Back up WTF now
    </button>
  </div>

  <p class="privacy-note" data-testid="wtf-privacy-note">
    Archives stay on this PC in the Furphy data folder. They can hold character names and chat history, so check an archive before you share it.
  </p>

  {#if effectiveIsGameActive}
    <div class="warning-callout" data-testid="wtf-wow-running-warning" role="alert">
      <p class="warning-lead">Restore cannot proceed while World of Warcraft is running. Exit the game first.</p>
      <p class="warning-sub">World of Warcraft is running. Settings changed since your last logout or /reload will not be included.</p>
    </div>
  {/if}

  {#if effectiveBackups.length === 0}
    <p class="empty-backups">No WTF archive backups created yet.</p>
  {:else}
    <div class="backups-list">
      {#each effectiveBackups as b (b.id)}
        <div class="backup-item">
          <div class="backup-meta">
            <span class="backup-date">{formatDate(b.created_at)}</span>
            <span class="backup-info">
              {b.file_count} files ({formatBytes(b.total_bytes)})
            </span>
            {#if b.note}
              <span class="backup-note">{b.note}</span>
            {/if}
            {#if b.total_bytes >= 500 * 1024 * 1024}
              <span class="backup-archive-warning">This archive is large (over 500 MB). Restoration may take several seconds.</span>
            {/if}
          </div>
          <div class="backup-actions">
            <button
              type="button"
              class="btn-secondary"
              data-testid="btn-wtf-restore"
              disabled={effectiveIsGameActive}
              onclick={() => handleRestoreClick(b.id)}
            >
              Restore
            </button>
            <button
              type="button"
              class="btn-secondary btn-danger-hover"
              data-testid="btn-wtf-delete"
              onclick={() => onDeleteBackup(b.id)}
            >
              Delete
            </button>
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .wtf-backup-panel {
    display: flex;
    flex-direction: column;
    gap: 1rem;
    padding: 0.5rem 0;
  }

  .panel-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    flex-wrap: wrap;
  }

  .panel-title {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
    color: var(--text);
  }

  .panel-subtext {
    font-size: 0.8125rem;
    color: var(--text-muted);
  }

  .privacy-note {
    margin: 0 0 0.75rem;
    font-size: 0.8125rem;
    color: var(--text-muted);
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

  .warning-lead {
    margin: 0 0 0.25rem 0;
    font-weight: 600;
  }

  .warning-sub {
    margin: 0;
    font-size: 0.8125rem;
    opacity: 0.9;
  }

  .empty-backups {
    font-size: 0.875rem;
    color: var(--text-muted);
    margin: 0.5rem 0;
  }

  .backups-list {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .backup-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.65rem 0.85rem;
    background: var(--bg-2);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    gap: 1rem;
  }

  .backup-meta {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
  }

  .backup-date {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text);
  }

  .backup-info {
    font-size: 0.8125rem;
    color: var(--text-muted);
  }

  .backup-note {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .backup-archive-warning {
    font-size: 0.75rem;
    color: var(--warning);
    font-weight: 500;
  }

  .backup-actions {
    display: flex;
    gap: 0.5rem;
  }

  .btn-primary, .btn-secondary {
    padding: 0.4rem 0.85rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8125rem;
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

  .btn-danger-hover:hover:not(:disabled) {
    color: var(--danger);
    border-color: var(--danger);
  }

  @media (prefers-reduced-motion: reduce) {
    .btn-primary, .btn-secondary {
      transition: none;
    }
  }
</style>
