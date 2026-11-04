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
    onShowError?: (addon: Addon) => void;
  }

  let { addon, onUpdate, onUnpin, onUnignore, onRetry, onViewDetails, onInstallDeps, onShowError }: Props = $props();

  let hasMissingDeps = $derived((addon.missing_deps && addon.missing_deps.length > 0) ?? false);

  let statusType = $derived.by(() => {
    if (addon.error || addon.check_status === 'failed') return 'failed';
    if (addon.pinned_file_id) return 'pinned';
    if (addon.ignore_updates) return 'ignored';
    let hasActualUpdate = addon.update_version &&
      addon.update_version !== addon.version &&
      !(addon.update_file_id && addon.update_file_id === addon.file_id);
    if (hasActualUpdate) return 'update';
    if (hasMissingDeps) return 'needs_dep';
    if (addon.is_old_patch) return 'old_patch';
    return 'up_to_date';
  });

  function handleClick(e: MouseEvent) {
    e.stopPropagation();
    if (statusType === 'failed') {
      if (onShowError) {
        onShowError(addon);
      } else if (onViewDetails) {
        onViewDetails(addon);
      } else if (onRetry) {
        onRetry(addon);
      } else if (onUpdate) {
        onUpdate(addon);
      }
    } else if (statusType === 'update' && onUpdate) {
      onUpdate(addon);
    } else if (statusType === 'pinned' && onUnpin) {
      onUnpin(addon);
    } else if (statusType === 'ignored' && onUnignore) {
      onUnignore(addon);
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

{#if statusType === 'failed'}
  {#if onShowError}
    <button
      type="button"
      class="status-pill pill-failed"
      onclick={handleClick}
      aria-label={`Failed update for ${addon.name ?? addon.id}: ${addon.error || 'Update check failed. Click to view error.'}`}
      title={addon.error || "Update check failed. Click to retry."}
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Failed · View error
    </button>
  {:else}
    <span
      class="status-pill pill-failed"
      title={addon.error || "Update check failed."}
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Failed
    </span>
  {/if}
{:else if statusType === 'update'}
  {#if onUpdate}
    <button
      type="button"
      class="status-pill pill-update"
      onclick={handleClick}
      aria-label={`Update ${addon.name ?? addon.id} to ${addon.update_version}`}
      title="Update to {addon.update_version}"
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Update {addon.update_version ? `(${addon.update_version})` : ''}
    </button>
  {:else}
    <span
      class="status-pill pill-update"
      title="Update to {addon.update_version}"
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Update {addon.update_version ? `(${addon.update_version})` : ''}
    </span>
  {/if}
{:else if statusType === 'pinned'}
  {#if onUnpin}
    <button
      type="button"
      class="status-pill pill-pinned"
      onclick={handleClick}
      aria-label={`Pinned version for ${addon.name ?? addon.id}. Click to unpin.`}
      title="Pinned to this version. Click to unpin."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Pinned
    </button>
  {:else}
    <span
      class="status-pill pill-pinned"
      title="Pinned to this version."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Pinned
    </span>
  {/if}
{:else if statusType === 'ignored'}
  {#if onUnignore}
    <button
      type="button"
      class="status-pill pill-ignored"
      onclick={handleClick}
      aria-label={`Updates ignored for ${addon.name ?? addon.id}. Click to resume updates.`}
      title="Ignoring updates. Click to resume updates."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Ignored
    </button>
  {:else}
    <span
      class="status-pill pill-ignored"
      title="Ignoring updates."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Ignored
    </span>
  {/if}
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
      <span class="pill-dot" aria-hidden="true"></span>
      Install deps ({addon.missing_deps?.length ?? 1})
    </button>
  {:else if onViewDetails}
    <button
      type="button"
      class="status-pill pill-needs-dep"
      onclick={handleClick}
      aria-label="Needs dependency for {addon.name ?? addon.id}: {addon.missing_deps?.join(', ') || 'Unknown'}. Click to view details."
      title="Needs dependency: {addon.missing_deps?.join(', ') || 'Unknown'}. Click to view details."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Needs a dependency
    </button>
  {:else}
    <span
      class="status-pill pill-needs-dep"
      title="Needs dependency: {addon.missing_deps?.join(', ') || 'Unknown'}."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Needs a dependency
    </span>
  {/if}
{:else if statusType === 'old_patch'}
  {#if onViewDetails}
    <button
      type="button"
      class="status-pill pill-old-patch"
      onclick={handleClick}
      aria-label={`${addon.name ?? addon.id} is not built for current game client patch. Click to view compatibility.`}
      title="Not built for current game client patch. Click to view compatibility."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Old patch
    </button>
  {:else}
    <span
      class="status-pill pill-old-patch"
      title="Not built for current game client patch."
    >
      <span class="pill-dot" aria-hidden="true"></span>
      Old patch
    </span>
  {/if}
{:else}
  <span class="status-pill pill-up-to-date" title="Addon is up to date with latest release.">
    <span class="pill-dot" aria-hidden="true"></span>
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
    transition: background var(--fast, 150ms), border-color var(--fast, 150ms), transform var(--fast, 150ms);
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
    flex-shrink: 0;
  }

  .pill-update {
    background: var(--accent);
    color: var(--accent-text);
    border-color: color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .pill-update:hover {
    background: var(--accent-hover);
  }

  .pill-up-to-date {
    background: var(--success-tint);
    color: var(--success);
    border-color: color-mix(in srgb, var(--success) 30%, transparent);
  }

  .pill-pinned {
    background: var(--warning-tint);
    color: var(--warning);
    border-color: color-mix(in srgb, var(--warning) 30%, transparent);
  }

  button.pill-pinned:hover {
    background: color-mix(in srgb, var(--warning) 22%, transparent);
  }

  .pill-ignored {
    background: var(--muted-tint);
    color: var(--text-muted);
    border-color: var(--border);
  }

  button.pill-ignored:hover {
    background: var(--bg-3);
  }

  .pill-needs-dep {
    background: var(--warning-tint);
    color: var(--warning);
    border-color: color-mix(in srgb, var(--warning) 35%, transparent);
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
    border-color: color-mix(in srgb, var(--warning) 30%, transparent);
  }

  button.pill-old-patch:hover {
    background: color-mix(in srgb, var(--warning) 22%, transparent);
  }

  .pill-failed {
    background: var(--danger-tint);
    color: var(--danger);
    border-color: color-mix(in srgb, var(--danger) 35%, transparent);
  }

  button.pill-failed:hover {
    background: color-mix(in srgb, var(--danger) 22%, transparent);
  }
</style>
