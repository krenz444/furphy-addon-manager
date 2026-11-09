<script lang="ts">
  import { invoke } from '../lib/ipc';
  import type { ActivityRecord } from '../lib/types';

  interface Props {
    activeFlavour: string;
    onOpenDrawer: (addonId: string, tab: string) => void;
  }

  let {
    activeFlavour,
    onOpenDrawer,
  }: Props = $props();

  let selectedFlavour = $state<string>('');
  let activities = $state<ActivityRecord[]>([]);
  let loading = $state<boolean>(false);

  $effect(() => {
    // When activeFlavour prop changes, initialize filter if empty
    if (!selectedFlavour && activeFlavour) {
      selectedFlavour = activeFlavour;
    }
  });

  $effect(() => {
    loadActivities();
  });

  async function loadActivities() {
    loading = true;
    try {
      const records = await invoke<ActivityRecord[]>('list_activity', {
        flavour: selectedFlavour || undefined,
      });
      activities = records || [];
    } catch {
      activities = [];
    } finally {
      loading = false;
    }
  }

  async function handleClear() {
    try {
      await invoke('clear_activity', {
        flavour: selectedFlavour || undefined,
      });
      await loadActivities();
    } catch {
      // ignore
    }
  }

  function getDayHeading(iso: string): string {
    try {
      const d = new Date(iso);
      const now = new Date();
      const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      const itemDay = new Date(d.getFullYear(), d.getMonth(), d.getDate());
      const diffTime = today.getTime() - itemDay.getTime();
      const diffDays = Math.round(diffTime / (1000 * 3600 * 24));
      if (diffDays === 0) return 'Today';
      if (diffDays === 1) return 'Yesterday';
      return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    } catch {
      return iso;
    }
  }

  let dayGroups = $derived.by(() => {
    const groups: { heading: string; items: ActivityRecord[] }[] = [];
    for (const act of activities) {
      const heading = getDayHeading(act.ts);
      let g = groups.find((item) => item.heading === heading);
      if (!g) {
        g = { heading, items: [] };
        groups.push(g);
      }
      g.items.push(act);
    }
    return groups;
  });

  function formatTime(iso: string): string {
    try {
      return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } catch {
      return '';
    }
  }
</script>

<div class="activity-view" data-testid="activity-view">
  <header class="activity-header">
    <div class="header-left">
      <h1 class="view-title">Activity</h1>
      <select
        class="form-select filter-flavour-select"
        data-testid="activity-filter-flavour"
        bind:value={selectedFlavour}
        aria-label="Filter activity by game version"
      >
        <option value="">All Game Versions</option>
        <option value="retail">Retail</option>
        <option value="classic_era">Classic Era</option>
        <option value="classic">Mists Classic</option>
        <option value="forever">WoW Forever</option>
      </select>
    </div>

    {#if activities.length > 0}
      <button
        type="button"
        class="btn-secondary btn-clear"
        data-testid="btn-clear-activity"
        onclick={handleClear}
      >
        Clear Activity
      </button>
    {/if}
  </header>

  <div class="activity-content">
    {#if loading}
      <p class="loading-state">Loading activity history…</p>
    {:else if activities.length === 0}
      <p class="empty-state" data-testid="activity-empty-state">Nothing has changed yet.</p>
    {:else}
      <div class="activity-timeline">
        {#each dayGroups as group (group.heading)}
          <section class="day-group">
            <h2 class="day-heading">{group.heading}</h2>
            <div class="day-items">
              {#each group.items as item (item.id)}
                <div class="activity-row" data-testid="activity-item">
                  <span class="activity-time">{formatTime(item.ts)}</span>
                  <span class="activity-kind-badge kind-{item.kind}">{item.kind}</span>
                  <button
                    type="button"
                    class="activity-name-btn"
                    onclick={() => onOpenDrawer(item.addon_id, 'overview')}
                  >
                    {item.name}
                  </button>
                  <span class="activity-flavour-badge">{item.flavour}</span>
                  {#if item.from_version && item.to_version}
                    <span class="activity-versions">
                      {item.from_version} → {item.to_version}
                    </span>
                  {:else if item.to_version}
                    <span class="activity-versions">
                      v{item.to_version}
                    </span>
                  {/if}
                  {#if item.error}
                    <span class="activity-error">{item.error}</span>
                  {/if}
                </div>
              {/each}
            </div>
          </section>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .activity-view {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
    overflow: hidden;
    background: var(--bg-0);
  }

  .activity-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1rem 1.5rem;
    border-bottom: 1px solid var(--border);
    background: var(--bg-1);
    gap: 1rem;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 1rem;
  }

  .view-title {
    margin: 0;
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--text);
  }

  .filter-flavour-select {
    background: var(--bg-2);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.35rem 0.75rem;
    font-size: 0.875rem;
  }

  .filter-flavour-select:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .activity-content {
    flex: 1;
    overflow-y: auto;
    padding: 1.5rem;
  }

  .loading-state, .empty-state {
    color: var(--text-muted);
    font-size: 0.95rem;
    text-align: center;
    margin-top: 3rem;
  }

  .activity-timeline {
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    max-width: 900px;
  }

  .day-group {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .day-heading {
    font-size: 0.95rem;
    font-weight: 600;
    color: var(--text-muted);
    margin: 0 0 0.25rem 0;
    padding-bottom: 0.25rem;
    border-bottom: 1px solid var(--border-soft);
  }

  .day-items {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }

  .activity-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.5rem 0.75rem;
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    font-size: 0.875rem;
  }

  .activity-time {
    color: var(--text-faint);
    font-size: 0.75rem;
    min-width: 48px;
  }

  .activity-kind-badge {
    padding: 0.15rem 0.5rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
  }

  .kind-updated, .kind-installed {
    color: var(--success);
    border-color: color-mix(in srgb, var(--success) 30%, transparent);
  }

  .kind-removed, .kind-failed {
    color: var(--danger);
    border-color: color-mix(in srgb, var(--danger) 35%, transparent);
  }

  .kind-held {
    color: var(--warning);
    border-color: color-mix(in srgb, var(--warning) 30%, transparent);
  }

  .activity-name-btn {
    background: transparent;
    border: none;
    color: var(--text);
    font-weight: 600;
    font-size: 0.875rem;
    cursor: pointer;
    padding: 0;
    text-align: left;
  }

  .activity-name-btn:hover {
    color: var(--accent);
    text-decoration: underline;
  }

  .activity-name-btn:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .activity-flavour-badge {
    font-size: 0.75rem;
    color: var(--text-muted);
    background: var(--bg-2);
    padding: 0.1rem 0.4rem;
    border-radius: var(--radius-sm, 4px);
  }

  .activity-versions {
    font-size: 0.8125rem;
    color: var(--text-muted);
  }

  .activity-error {
    font-size: 0.8125rem;
    color: var(--danger);
  }

  .btn-secondary {
    padding: 0.4rem 0.85rem;
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast, 150ms), border-color var(--fast, 150ms);
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-secondary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .btn-secondary {
      transition: none;
    }
  }
</style>
