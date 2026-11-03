<script lang="ts">
  interface Props {
    onTrigger: () => void;
    disabled?: boolean;
    rootMargin?: string;
    root?: HTMLElement | null;
  }

  let props: Props = $props();

  let sentinelEl: HTMLDivElement | null = $state(null);

  $effect(() => {
    if (!sentinelEl || props.disabled) return;

    const observer = new IntersectionObserver(
      (entries) => {
        const first = entries[0];
        if (first?.isIntersecting && !props.disabled) {
          props.onTrigger();
        }
      },
      {
        root: props.root || null,
        rootMargin: props.rootMargin || '350px',
        threshold: 0,
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
    height: 8px;
    pointer-events: none;
    opacity: 0;
  }
</style>
