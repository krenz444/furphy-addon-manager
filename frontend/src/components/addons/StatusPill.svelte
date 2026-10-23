<script lang="ts">
  import type { Addon } from '../../lib/types';

  interface Props {
    addon: Addon;
    onUpdate?: (addon: Addon) => void;
    onUnpin?: (addon: Addon) => void;
    onUnignore?: (addon: Addon) => void;
    onRetry?: (addon: Addon) => void;
    onViewDetails?: (addon: Addon) => void;
    onInstallDeps?: (addon?: Addon) => void;
  }

  let { addon, onUpdate, onUnpin, onUnignore, onRetry, onViewDetails, onInstallDeps }: Props = $props();

  let hasMissingDeps = $derived((addon.missing_deps && addon.missing_deps.length > 0) ?? false);

  let statusType = $derived.by(() => {
    if (addon.pinned_file_id) return 'pinned';
    if (addon.ignore_updates) return 'ignored';
    if (addon.update_version) return 'update';
    if (hasMissingDeps) return 'needs_dep';
    if (addon.is_old_patch) return 'old_patch';
    if (addon.check_status === 'failed') return 'failed';
    return 'up_to_date';
  });

  function handleClick(e: MouseEvent) {
    e.stopPropagation();
    if (statusType === 'update' && onUpdate) {
      onUpdate(addon);
    } else if (statusType === 'pinned' && onUnpin) {
      onUnpin(addon);
    } else if (statusType === 'ignored' && onUnignore) {
      onUnignore(addon);
    } else if (statusType === 'failed' && onRetry) {
      onRetry(addon);
    } else if (statusType === 'needs_dep') {
      if (onInstallDeps) {
        onInstallDeps(addon);
      } else if (onViewDetails) {
        onViewDetails(addon);
      }
    } else if (statusType === 'old_patch' && onViewDetails) {
      onViewDetails(addon);
    }
  }
</script>

{#if statusType === 'update'}
  <button
    type="button"
    class="status-pill pill-update"
    onclick={handleClick}
    title="Update to {addon.update_version}"
  >
    <span class="pill-dot"></span>
    Update {addon.update_version ? `(${addon.update_version})` : ''}
  </button>
{:else if statusType === 'pinned'}
  <button
    type="button"
    class="status-pill pill-pinned"
    onclick={handleClick}
    title="Pinned to this version. Click to unpin."
  >
    Pinned
  </button>
{:else if statusType === 'ignored'}
  <button
    type="button"
    class="status-pill pill-ignored"
    onclick={handleClick}
    title="Ignoring updates. Click to resume updates."
  >
    Ignored
  </button>
{:else if statusType === 'needs_dep'}
  {#if onInstallDeps}
    <button
      type="button"
      class="status-pill pill-needs-dep interactive"
      onclick={(e) => {
        e.stopPropagation();
        onInstallDeps(addon);
      }}
      aria-label="Install missing dependencies for {addon.name ?? addon.id}: {addon.missing_deps?.join(', ') || 'Unknown'}"
      title="Needs dependency: {addon.missing_deps?.join(', ') || 'Unknown'}. Click to install."
    >
      <span class="pill-dot"></span>
      Install deps ({addon.missing_deps?.length ?? 1})
    </button>
  {:else}
    <button
      type="button"
      class="status-pill pill-needs-dep"
      onclick={handleClick}
      title="Needs dependency: {addon.missing_deps?.join(', ') || 'Unknown'}. Click to view details."
    >
      Needs a dependency
    </button>
  {/if}
{:else if statusType === 'old_patch'}
  <button
    type="button"
    class="status-pill pill-old-patch"
    onclick={handleClick}
    title="Not built for current game client patch. Click to view compatibility."
  >
    Old patch
  </button>
{:else if statusType === 'failed'}
  <button
    type="button"
    class="status-pill pill-failed"
    onclick={handleClick}
    title="Update check failed. Click to retry."
  >
    Couldn’t update · Retry
  </button>
{:else}
  <span class="status-pill pill-up-to-date">
    Up to date
  </span>
{/if}

<style>
  .status-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 11.5px;
    font-weight: 600;
    padding: 3px 9px;
    border-radius: 999px;
    border: 1px solid transparent;
    cursor: default;
    white-space: nowrap;
    user-select: none;
    transition: background var(--fast), border-color var(--fast), transform var(--fast);
  }

  button.status-pill {
    cursor: pointer;
  }

  button.status-pill:hover {
    transform: translateY(-1px);
  }

  button.status-pill:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .pill-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: currentColor;
  }

  .pill-update {
    background: var(--accent);
    color: var(--accent-text);
  }

  .pill-update:hover {
    background: var(--accent-hover);
  }

  .pill-up-to-date {
    background: var(--success-tint);
    color: var(--success);
    border-color: rgba(47, 230, 167, 0.25);
  }

  .pill-pinned {
    background: var(--warning-tint);
    color: var(--warning);
    border-color: rgba(255, 179, 71, 0.25);
  }

  .pill-pinned:hover {
    background: rgba(255, 179, 71, 0.25);
  }

  .pill-ignored {
    background: var(--muted-tint);
    color: var(--text-muted);
    border-color: var(--border);
  }

  .pill-ignored:hover {
    background: var(--bg-3);
  }

  .pill-needs-dep {
    background: var(--warning-tint);
    color: var(--warning);
    border-color: var(--warning);
  }

  .pill-needs-dep:hover {
    background: var(--warning-tint);
    border-color: var(--warning);
  }

  .pill-needs-dep.interactive {
    cursor: pointer;
  }

  .pill-needs-dep.interactive:hover {
    background: var(--warning);
    color: var(--bg-0);
    border-color: var(--warning);
  }

  .pill-old-patch {
    background: var(--warning-tint);
    color: var(--warning);
    border-color: var(--warning);
  }

  .pill-old-patch:hover {
    background: var(--warning-tint);
  }

  .pill-failed {
    background: var(--danger-tint);
    color: var(--danger);
    border-color: var(--danger-border);
  }

  .pill-failed:hover {
    background: rgba(255, 111, 120, 0.25);
  }
</style>
