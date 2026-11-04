<script lang="ts">
  interface Props {
    onTrigger: () => void;
    disabled?: boolean;
    rootMargin?: string;
    root?: HTMLElement | null;
    throttleMs?: number;
  }

  let {
    onTrigger,
    disabled = false,
    rootMargin = '200px',
    root = null,
    throttleMs = 400,
  }: Props = $props();

  let sentinelEl: HTMLDivElement | null = $state(null);
  let lastTriggerTime = 0;

  $effect(() => {
    if (!sentinelEl || disabled) return;
    if (typeof IntersectionObserver === 'undefined') return;

    let triggered = false;
    const observer = new IntersectionObserver(
      (entries) => {
        const first = entries[0];
        if (!first) return;

        if (first.isIntersecting) {
          const now = Date.now();
          if (!disabled && !triggered && now - lastTriggerTime >= throttleMs) {
            triggered = true;
            lastTriggerTime = now;
            onTrigger();
          }
        } else {
          // Re-arm sentinel when leaving the intersection zone so scrolling back re-triggers
          triggered = false;
        }
      },
      {
        root: root || null,
        rootMargin: rootMargin || '200px',
        threshold: 0,
      }
    );

    observer.observe(sentinelEl);

    return () => {
      observer.disconnect();
    };
  });

  /** Synthetic manual fallback trigger for headless environments, unit tests, or boundary assertions */
  export function triggerManually() {
    if (!disabled) {
      lastTriggerTime = Date.now();
      onTrigger();
    }
  }
</script>

<div
  bind:this={sentinelEl}
  class="infinite-scroll-sentinel"
  data-testid="infinite-scroll-sentinel"
  aria-hidden="true"
></div>

<style>
  .infinite-scroll-sentinel {
    width: 100%;
    height: 8px;
    pointer-events: none;
    opacity: 0;
  }
</style>
