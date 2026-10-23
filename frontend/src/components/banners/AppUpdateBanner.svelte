<script lang="ts">
  interface Props {
    updateVersion: string;
    releaseNotes?: string | null;
    isInstalling?: boolean;
    onInstall: () => void;
    onDismiss: () => void;
  }

  let {
    updateVersion,
    releaseNotes = null,
    isInstalling = false,
    onInstall,
    onDismiss
  }: Props = $props();

  let showNotes = $state(false);
</script>

<div class="app-update-banner" role="status" aria-live="polite">
  <div class="banner-main">
    <div class="banner-icon" aria-hidden="true">
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
        <polyline points="7 10 12 15 17 10" />
        <line x1="12" y1="15" x2="12" y2="3" />
      </svg>
    </div>
    <div class="banner-text">
      <span class="banner-title">
        Furphy Addon Manager v{updateVersion} is ready to install.
      </span>
      {#if releaseNotes}
        <button
          type="button"
          class="notes-toggle-btn"
          onclick={() => (showNotes = !showNotes)}
          aria-expanded={showNotes}
        >
          {showNotes ? "Hide notes" : "What's new"}
        </button>
      {/if}
    </div>
    <div class="banner-actions">
      <button
        type="button"
        class="install-btn"
        disabled={isInstalling}
        onclick={onInstall}
      >
        {isInstalling ? 'Installing...' : 'Install & Relaunch'}
      </button>
      <button
        type="button"
        class="dismiss-btn"
        aria-label="Dismiss update banner"
        onclick={onDismiss}
      >
        Dismiss
      </button>
    </div>
  </div>

  {#if showNotes && releaseNotes}
    <div class="banner-notes">
      <pre>{releaseNotes}</pre>
    </div>
  {/if}
</div>

<style>
  .app-update-banner {
    background: var(--bg-1);
    border-bottom: 1px solid var(--accent);
    color: var(--text);
    padding: 10px 16px;
    font-size: 0.875rem;
    position: relative;
    z-index: 40;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
  }

  .banner-main {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .banner-icon {
    color: var(--accent);
    display: flex;
    align-items: center;
    flex-shrink: 0;
  }

  .banner-text {
    flex: 1;
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .banner-title {
    font-weight: 500;
  }

  .notes-toggle-btn {
    background: none;
    border: none;
    color: var(--accent);
    font-size: 0.8125rem;
    cursor: pointer;
    text-decoration: underline;
    padding: 2px 4px;
    border-radius: 4px;
  }

  .notes-toggle-btn:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  .banner-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .install-btn {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    font-weight: 600;
    font-size: 0.8125rem;
    padding: 6px 14px;
    border-radius: 4px;
    cursor: pointer;
    transition: opacity 0.15s ease;
  }

  .install-btn:hover:not(:disabled) {
    opacity: 0.9;
  }

  .install-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .install-btn:focus-visible {
    outline: 2px solid var(--text);
    outline-offset: 2px;
  }

  .dismiss-btn {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--text-muted);
    font-size: 0.8125rem;
    padding: 5px 10px;
    border-radius: 4px;
    cursor: pointer;
    transition: background-color 0.15s ease, color 0.15s ease;
  }

  .dismiss-btn:hover {
    background: var(--bg-2);
    color: var(--text);
  }

  .dismiss-btn:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  .banner-notes {
    margin-top: 8px;
    padding: 8px 12px;
    background: var(--bg-2);
    border-radius: 4px;
    border: 1px solid var(--border);
    font-size: 0.8125rem;
    max-height: 140px;
    overflow-y: auto;
  }

  .banner-notes pre {
    margin: 0;
    font-family: inherit;
    white-space: pre-wrap;
    word-break: break-word;
    color: var(--text-muted);
  }
</style>
