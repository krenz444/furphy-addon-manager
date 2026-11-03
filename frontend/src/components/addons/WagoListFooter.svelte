<script lang="ts">
  interface Props {
    loadingMore: boolean;
    hasMore: boolean;
    resultsCount: number;
    error: string | null;
    onLoadMore?: () => void;
    onRetry?: () => void;
  }

  let { loadingMore, hasMore, resultsCount, error, onLoadMore, onRetry }: Props = $props();
</script>

<footer class="wago-list-footer">
  {#if loadingMore}
    <div class="footer-state loading" aria-live="polite">
      <div class="spinner-sm" aria-hidden="true"></div>
      <span>Loading more addons…</span>
    </div>
  {:else if error}
    <div class="footer-state error" role="alert">
      <span>Error loading more addons: {error}</span>
      <button type="button" class="btn-retry" onclick={onRetry || onLoadMore}>Retry</button>
    </div>
  {:else if hasMore}
    <div class="footer-state load-more-action">
      <button type="button" class="btn-load-more" onclick={onLoadMore}>
        Load More Addons ({resultsCount} loaded) ↓
      </button>
    </div>
  {:else if !hasMore && resultsCount > 0}
    <div class="footer-state end-of-list">
      <span>Showing all {resultsCount} addons · End of results</span>
    </div>
  {/if}
</footer>

<style>
  .wago-list-footer {
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 1.5rem 0 2.5rem 0;
    min-height: 4rem;
  }

  .footer-state {
    display: flex;
    align-items: center;
    gap: 0.65rem;
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .btn-load-more {
    background: var(--bg-1);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 0.6rem 1.6rem;
    border-radius: var(--radius-sm, 4px);
    cursor: pointer;
    font-size: 0.85rem;
    font-weight: 600;
    transition: background var(--fast, 150ms), border-color var(--fast, 150ms), color var(--fast, 150ms);
  }

  .btn-load-more:hover {
    background: var(--bg-2);
    border-color: var(--accent);
    color: var(--accent);
  }

  .btn-load-more:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .footer-state.error {
    color: var(--danger, #ef4444);
    background: rgba(239, 68, 68, 0.1);
    padding: 0.5rem 1rem;
    border-radius: var(--radius-sm, 4px);
    border: 1px solid rgba(239, 68, 68, 0.2);
  }

  .btn-retry {
    background: var(--bg-2);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 0.2rem 0.6rem;
    border-radius: var(--radius-sm, 4px);
    cursor: pointer;
    font-size: 0.8rem;
    font-weight: 500;
  }

  .btn-retry:hover {
    background: var(--bg-1);
    color: var(--accent);
  }

  .btn-retry:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .spinner-sm {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(255, 255, 255, 0.15);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .end-of-list {
    font-size: 0.8rem;
    letter-spacing: 0.02em;
    opacity: 0.75;
  }
</style>
