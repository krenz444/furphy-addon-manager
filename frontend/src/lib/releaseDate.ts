// How the Released column shows a release date. Pure: the current time comes in as an argument.

const DAY_MS = 86_400_000;

function parse(iso: string | null | undefined): Date | null {
  if (!iso) return null;
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? null : date;
}

function localDayStart(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

export function formatReleased(iso: string | null | undefined, now: Date = new Date()): { text: string; title: string } {
  const date = parse(iso);
  if (!date) return { text: '-', title: 'Release date unknown' };

  const title = new Intl.DateTimeFormat('en-US', { dateStyle: 'long', timeStyle: 'short' }).format(date);
  const daysAgo = Math.round((localDayStart(now) - localDayStart(date)) / DAY_MS);
  if (daysAgo === 0) return { text: 'Today', title };
  if (daysAgo === 1) return { text: 'Yesterday', title };

  const sameYear = date.getFullYear() === now.getFullYear();
  const text = new Intl.DateTimeFormat('en-US', sameYear ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
  return { text, title };
}

/** Sort order for the Released column: newest first, unknown or unreadable dates last. */
export function compareReleased(a: string | null | undefined, b: string | null | undefined): number {
  const da = parse(a)?.getTime() ?? null;
  const db = parse(b)?.getTime() ?? null;
  if (da === null && db === null) return 0;
  if (da === null) return 1;
  if (db === null) return -1;
  return db - da;
}
