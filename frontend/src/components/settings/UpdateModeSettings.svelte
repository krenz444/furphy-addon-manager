<script lang="ts">
  import type { Flavour } from '../../lib/types';

  interface Props {
    flavours: Flavour[];
    updateModes: Record<string, 'auto' | 'notify'>;
    onChangeMode: (flavourId: string, mode: 'auto' | 'notify') => void;
  }

  let {
    flavours,
    updateModes,
    onChangeMode,
  }: Props = $props();
</script>

<div class="update-mode-settings" data-testid="update-mode-settings">
  <div class="settings-title">When updates are found:</div>
  {#each flavours as flv (flv.id)}
    <div class="mode-row">
      <label for="mode-select-{flv.id}" class="mode-label">
        {flv.label}
      </label>
      <select
        id="mode-select-{flv.id}"
        class="form-select mode-select"
        data-testid="mode-select-{flv.id}"
        value={updateModes[flv.id] || 'auto'}
        onchange={(e) => {
          const mode = (e.currentTarget as HTMLSelectElement).value as 'auto' | 'notify';
          onChangeMode(flv.id, mode);
        }}
      >
        <option value="auto">Install automatically</option>
        <option value="notify">Only notify</option>
      </select>
    </div>
  {/each}
</div>

<style>
  .update-mode-settings {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding: 0.75rem 0;
  }

  .settings-title {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text);
  }

  .mode-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.35rem 0;
  }

  .mode-label {
    font-size: 0.875rem;
    color: var(--text-muted);
  }

  .mode-select {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.35rem 0.75rem;
    font-size: 0.875rem;
  }

  .mode-select:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
