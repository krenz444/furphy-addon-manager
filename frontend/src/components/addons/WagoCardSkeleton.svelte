<script lang="ts">
  interface Props {
    count?: number;
  }

  let { count = 6 }: Props = $props();
</script>

<div class="skeleton-grid" aria-busy="true" aria-label="Loading addons">
  {#each Array(count) as _, i (i)}
    <div class="skeleton-card">
      <div class="skeleton-main">
        <div class="skeleton-title shimmer"></div>
        <div class="skeleton-author shimmer"></div>
        <div class="skeleton-desc shimmer"></div>
        <div class="skeleton-desc short shimmer"></div>
      </div>
      <div class="skeleton-footer">
        <div class="skeleton-stats shimmer"></div>
        <div class="skeleton-btn shimmer"></div>
      </div>
    </div>
  {/each}
</div>

<style>
  .skeleton-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 1rem;
    width: 100%;
  }

  .skeleton-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    padding: 1rem;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 0.75rem;
    min-height: 170px;
  }

  .skeleton-main {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .shimmer {
    background: linear-gradient(
      90deg,
      var(--bg-2) 0%,
      rgba(255, 255, 255, 0.05) 50%,
      var(--bg-2) 100%
    );
    background-size: 200% 100%;
    animation: shimmer-anim 1.5s infinite;
    border-radius: var(--radius-sm, 4px);
  }

  @keyframes shimmer-anim {
    0% {
      background-position: 200% 0;
    }
    100% {
      background-position: -200% 0;
    }
  }

  .skeleton-title {
    width: 70%;
    height: 1.25rem;
  }

  .skeleton-author {
    width: 40%;
    height: 0.85rem;
  }

  .skeleton-desc {
    width: 100%;
    height: 0.85rem;
    margin-top: 0.25rem;
  }

  .skeleton-desc.short {
    width: 60%;
  }

  .skeleton-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-top: 0.75rem;
    border-top: 1px solid var(--border);
  }

  .skeleton-stats {
    width: 35%;
    height: 0.85rem;
  }

  .skeleton-btn {
    width: 45%;
    height: 1.85rem;
  }
</style>
