<script lang="ts" generics="T">
  import type { Snippet } from 'svelte';

  interface Props {
    items: T[];
    itemHeight: number;
    overscan?: number;
    children: Snippet<[{ item: T; index: number }]>;
  }

  let { items, itemHeight, overscan = 6, children }: Props = $props();

  let containerRef = $state<HTMLDivElement | null>(null);
  let scrollTop = $state(0);
  let containerHeight = $state(600);

  let totalHeight = $derived(items.length * itemHeight);

  let startIndex = $derived.by(() => {
    const raw = Math.floor(scrollTop / itemHeight) - overscan;
    return Math.max(0, raw);
  });

  let endIndex = $derived.by(() => {
    const visibleCount = Math.ceil(containerHeight / itemHeight);
    const raw = Math.floor(scrollTop / itemHeight) + visibleCount + overscan;
    return Math.min(items.length, raw);
  });

  let visibleItems = $derived.by(() => {
    return items.slice(startIndex, endIndex).map((item, i) => ({
      item,
      index: startIndex + i,
    }));
  });

  let offsetY = $derived(startIndex * itemHeight);

  function handleScroll(e: Event) {
    const target = e.currentTarget as HTMLDivElement;
    scrollTop = target.scrollTop;
  }

  $effect(() => {
    if (containerRef) {
      containerHeight = containerRef.clientHeight || 600;
      const observer = new ResizeObserver((entries) => {
        for (const entry of entries) {
          containerHeight = entry.contentRect.height;
        }
      });
      observer.observe(containerRef);
      return () => observer.disconnect();
    }
  });
</script>

<div
  class="virtual-container"
  bind:this={containerRef}
  onscroll={handleScroll}
  role="region"
  aria-label="Addon list scrollable area"
>
  <div class="virtual-spacer" style:height="{totalHeight}px">
    <div
      class="virtual-content"
      style:transform="translateY({offsetY}px)"
    >
      {#each visibleItems as { item, index } (index)}
        {@render children({ item, index })}
      {/each}
    </div>
  </div>
</div>

<style>
  .virtual-container {
    width: 100%;
    height: 100%;
    overflow-y: auto;
    position: relative;
    contain: strict;
    outline: none;
  }

  .virtual-container:focus-visible {
    box-shadow: inset 0 0 0 2px var(--focus-ring);
  }

  .virtual-spacer {
    width: 100%;
    position: relative;
    pointer-events: none;
  }

  .virtual-content {
    width: 100%;
    position: absolute;
    top: 0;
    left: 0;
    pointer-events: auto;
    will-change: transform;
  }
</style>
