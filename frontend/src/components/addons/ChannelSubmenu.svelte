<script lang="ts">
  interface Props {
    selectedChannel: number;
    onSelectChannel: (channel: number) => void;
    onClose: () => void;
  }

  let {
    selectedChannel,
    onSelectChannel,
    onClose,
  }: Props = $props();

  const channels = [
    { id: 1, label: 'Stable', testId: 'channel-opt-stable' },
    { id: 2, label: 'Beta', testId: 'channel-opt-beta' },
    { id: 3, label: 'Alpha', testId: 'channel-opt-alpha' },
  ];

  let focusedIndex = $state(
    Math.max(0, channels.findIndex((c) => c.id === selectedChannel))
  );
  let buttonEls = $state<(HTMLButtonElement | null)[]>([]);

  $effect(() => {
    buttonEls[focusedIndex]?.focus();
  });

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      focusedIndex = (focusedIndex + 1) % channels.length;
      buttonEls[focusedIndex]?.focus();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      focusedIndex = (focusedIndex - 1 + channels.length) % channels.length;
      buttonEls[focusedIndex]?.focus();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      onClose();
    }
  }
</script>

<div
  class="channel-submenu"
  data-testid="channel-submenu"
  role="menu"
  tabindex="-1"
  onkeydown={handleKeydown}
>
  {#each channels as ch, idx (ch.id)}
    <button
      type="button"
      role="menuitemradio"
      aria-checked={selectedChannel === ch.id}
      class="channel-option"
      class:selected={selectedChannel === ch.id}
      data-testid={ch.testId}
      bind:this={buttonEls[idx]}
      onclick={(e) => {
        e.stopPropagation();
        onSelectChannel(ch.id);
      }}
    >
      <span class="channel-check" aria-hidden="true">
        {selectedChannel === ch.id ? '✓' : ''}
      </span>
      <span class="channel-label">{ch.label}</span>
    </button>
  {/each}
</div>

<style>
  .channel-submenu {
    display: flex;
    flex-direction: column;
    padding: 0.25rem 0;
    min-width: 140px;
    background: var(--bg-2);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }

  .channel-option {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.4rem 0.75rem;
    background: transparent;
    border: none;
    color: var(--text);
    font-size: 0.8125rem;
    text-align: left;
    cursor: pointer;
    width: 100%;
    transition: background var(--fast, 150ms);
  }

  .channel-option:hover {
    background: var(--border-hover);
  }

  .channel-option:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: -2px;
    background: var(--bg-3);
  }

  .channel-check {
    width: 14px;
    display: inline-block;
    color: var(--accent);
    font-weight: bold;
  }

  .channel-label {
    flex: 1;
  }

  @media (prefers-reduced-motion: reduce) {
    .channel-option {
      transition: none;
    }
  }
</style>
