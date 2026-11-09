import type { JobRecord } from './types';

export interface CheckFailure {
  name: string;
  error: string;
}

export interface CheckSummary {
  checked: number;
  skipped: number;
  updates: number;
  failed: number;
  failures: CheckFailure[];
  held: number;
}

export const BUSY_MESSAGE = 'Another task is running. Try again when it finishes.';
export const NOTHING_TO_CHECK_MESSAGE = 'No addons to check yet. Add an addon first.';

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function nonEmpty(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function count(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function plural(n: number, one: string): string {
  return `${n} ${n === 1 ? one : `${one}s`}`;
}

// A check job returns its CheckRunReport as a JSON string; sync-shaped results are not a report and give null.
export function summarizeCheck(job: Pick<JobRecord, 'results'> | null | undefined): CheckSummary | null {
  let report: unknown = job?.results;
  if (typeof report === 'string') {
    try {
      report = JSON.parse(report);
    } catch {
      return null;
    }
  }
  if (!isRecord(report) || typeof report.total !== 'number' || !Array.isArray(report.outcomes)) return null;

  const skipped = count(report.ignored_count) + count(report.pinned_count);
  const failures: CheckFailure[] = [];
  for (const outcome of report.outcomes) {
    if (isRecord(outcome) && outcome.status === 'Failed') {
      failures.push({
        name: nonEmpty(outcome.name) ?? nonEmpty(outcome.addon_id) ?? 'Unknown addon',
        error: nonEmpty(outcome.error) ?? 'Unknown error',
      });
    }
  }

  return {
    checked: Math.max(0, count(report.total) - skipped),
    skipped,
    updates: count(report.would_update_count),
    failed: Math.max(count(report.failed_count), failures.length),
    failures,
    held: count(report.held_count),
  };
}

export function checkSuccessMessage(summary: CheckSummary): string {
  const skipped = summary.skipped > 0 ? `, ${summary.skipped} ignored or pinned skipped` : '';
  const updatesPart = summary.updates > 0 ? `${plural(summary.updates, 'update')} ready` : '';
  const heldPart = summary.held > 0 ? `${summary.held} on hold` : '';
  let tail = 'Everything is up to date.';
  if (updatesPart && heldPart) {
    tail = `${updatesPart}, ${heldPart}.`;
  } else if (updatesPart) {
    tail = `${updatesPart}.`;
  } else if (heldPart) {
    tail = `${heldPart}.`;
  }
  return `Checked ${plural(summary.checked, 'addon')}${skipped}. ${tail}`;
}

export function checkFailureMessage(summary: CheckSummary): string {
  const names = summary.failures.map((f) => f.name);
  if (names.length === 1) return `Could not check ${names[0]}: ${summary.failures[0].error}`;
  if (names.length > 1) {
    const shown = names.slice(0, 3).join(', ');
    const more = names.length > 3 ? ` and ${names.length - 3} more` : '';
    return `Could not check ${names.length} addons: ${shown}${more}.`;
  }
  return `Could not check ${plural(summary.failed || 1, 'addon')}.`;
}

// The runner has one lane; this is its rejection text while any other job runs.
export function isRunnerBusyError(message: string): boolean {
  return /another job .*is currently running/i.test(message);
}

// Tauri rejects with the command's error value, normally a string; do not let an object print as "[object Object]".
export function errorText(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === 'string') return err;
  if (isRecord(err) && typeof err.message === 'string') return err.message;
  return 'Unknown error';
}
