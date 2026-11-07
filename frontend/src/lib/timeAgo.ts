const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

// Backend timestamps are RFC3339 UTC; anything unusable reads as never checked rather than a wrong age.
export function formatCheckedAgo(iso: string | null | undefined, nowMs: number): string {
  if (!iso) return 'Not checked yet';
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return 'Not checked yet';

  // A timestamp in the future (clock skew) lands here too.
  const age = nowMs - then;
  if (age < 45 * SECOND) return 'Checked just now';
  if (age < HOUR) return `Checked ${Math.max(1, Math.floor(age / MINUTE))} min ago`;
  if (age < DAY) return `Checked ${Math.floor(age / HOUR)} h ago`;
  return `Checked ${Math.floor(age / DAY)} d ago`;
}
