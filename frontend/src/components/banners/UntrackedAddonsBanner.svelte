<script lang="ts">
  interface Props {
    count: number;
    flavour: string;
    onManageAll?: () => void;
    onViewUntracked?: () => void;
    onDismiss?: () => void;
  }

  let { count, flavour, onManageAll, onViewUntracked, onDismiss }: Props = $props();
  let isDismissed = $state(false);

  function handleDismiss() {
    isDismissed = true;
    onDismiss?.();
  }
</script>

{#if count > 0 && !isDismissed}
  <aside class="untracked-banner" role="status" aria-label="Untracked Addons Notice">
    <div class="banner-content">
      <div class="banner-icon-col">
        <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="10" cy="10" r="8" />
          <line x1="10" y1="6" x2="10" y2="10" />
          <line x1="10" y1="14" x2="10.01" y2="14" />
        </svg>
      </div>
      <div class="banner-text-col">
        <strong class="banner-headline">
          {count} addon{count === 1 ? '' : 's'} Furphy isn’t managing yet
        </strong>
        <span class="banner-subtext">
          Found unmanaged addons in your {flavour} AddOns folder. Furphy can track and update them.
        </span>
      </div>
    </div>
    <div class="banner-actions">
      {#if onViewUntracked}
        <button type="button" class="btn btn-outline" onclick={onViewUntracked}>
          Review
        </button>
      {/if}
      {#if onManageAll}
        <button type="button" class="btn btn-accent" onclick={onManageAll}>
          Manage all
        </button>
      {/if}
      <button
        type="button"
        class="dismiss-btn"
        aria-label="Dismiss banner"
        onclick={handleDismiss}
      >
        ✕
      </button>
    </div>
  </aside>
{/if}

<style>
  .untracked-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 10px 16px;
    background: var(--bg-1);
    border: 1px solid var(--accent);
    border-radius: var(--radius);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
    margin-bottom: 14px;
    flex-wrap: wrap;
  }

  .banner-content {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .banner-icon-col {
    color: var(--accent);
    display: flex;
    align-items: center;
  }

  .banner-text-col {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .banner-headline {
    color: var(--text);
    font-size: 13px;
  }

  .banner-subtext {
    color: var(--text-muted);
    font-size: 12px;
  }

  .banner-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .btn {
    font-size: 12px;
    font-weight: 600;
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    border: 1px solid transparent;
    transition: background var(--fast);
  }

  .btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-accent {
    background: var(--accent);
    color: var(--accent-text);
  }

  .btn-accent:hover {
    background: var(--accent-hover);
  }

  .btn-outline {
    background: transparent;
    color: var(--text);
    border-color: var(--border);
  }

  .btn-outline:hover {
    background: var(--bg-2);
  }

  .dismiss-btn {
    background: transparent;
    border: none;
    color: var(--text-faint);
    font-size: 13px;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
  }

  .dismiss-btn:hover {
    color: var(--text);
    background: var(--bg-2);
  }

  .dismiss-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }
</style>
