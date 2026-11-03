<script lang="ts">
  import { onMount } from 'svelte';

  interface Props {
    onTrigger: () => void;
    disabled?: boolean;
    rootMargin?: string;
  }

  let { onTrigger, disabled = false, rootMargin = '250px' }: Props = $props();

  let sentinelEl: HTMLDivElement | null = $state(null);

  onMount(() => {
    if (!sentinelEl) return;

    const observer = new IntersectionObserver(
      (entries) => {
        const first = entries[0];
        if (first?.isIntersecting && !disabled) {
          onTrigger();
        }
      },
      {
        root: null,
        rootMargin,
        threshold: 0.1,
      }
    );

    observer.observe(sentinelEl);

    return () => {
      observer.disconnect();
    };
  });
</script>

<div bind:this={sentinelEl} class="infinite-scroll-sentinel" aria-hidden="true"></div>

<style>
  .infinite-scroll-sentinel {
    width: 100%;
    height: 1px;
    pointer-events: none;
    opacity: 0;
  }
</style>
