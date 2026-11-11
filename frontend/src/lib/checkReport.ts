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

export interface FlavourLabelLike {
  id: string;
  label?: string;
}

const DEFAULT_FLAVOUR_LABELS: Record<string, string> = {
  retail: 'Retail',
  classic: 'Classic',
  classic_era: 'Classic Era',
  bcc: 'Classic TBC',
  ptr: 'PTR',
  beta: 'Beta',
};

export function formatFlavourLabel(
  flavour: string | null | undefined,
  flavours?: readonly FlavourLabelLike[],
): string | null {
  if (!flavour) return null;
  const found = flavours?.find((f) => f.id === flavour);
  if (found?.label) return found.label;
  if (DEFAULT_FLAVOUR_LABELS[flavour]) return DEFAULT_FLAVOUR_LABELS[flavour];
  return flavour
    .split(/[_-]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

export function describeJobTitle(
  kind: string,
  flavour: string | null | undefined,
  flavours?: readonly FlavourLabelLike[],
  targetLabel?: string | null,
  mode: 'active' | 'queued' = 'active',
): string {
  const flv = formatFlavourLabel(flavour, flavours);
  const withFlv = (base: string) => (flv ? `${base} (${flv})` : base);

  if (mode === 'queued') {
    switch (kind) {
      case 'check':
        return withFlv('Check for updates');
      case 'update-all-flavours':
        return 'Update all game versions';
      case 'sync':
      case 'update-all':
        return withFlv('Update all');
      case 'update':
        return withFlv(targetLabel ? `Update ${targetLabel}` : 'Update addon');
      case 'install':
      case 'install_zip':
        return withFlv(targetLabel ? `Install ${targetLabel}` : 'Install addon');
      case 'install_dependencies':
        return withFlv(targetLabel ? `Install libraries for ${targetLabel}` : 'Install missing libraries');
      case 'uninstall':
        return withFlv(targetLabel ? `Remove ${targetLabel}` : 'Remove addons');
      case 'rollback':
        return withFlv(targetLabel ? `Rollback ${targetLabel}` : 'Rollback addon');
      case 'copy-addons':
        return withFlv('Copy addons');
      case 'backup-wtf':
        return withFlv('Backup WTF');
      case 'restore-wtf-all':
        return withFlv('Restore WTF');
      default:
        return withFlv(kind.replace(/[_-]+/g, ' '));
    }
  }

  switch (kind) {
    case 'check':
      return flv ? `Checking ${flv} addons` : 'Checking addons';
    case 'update-all-flavours':
      return 'Updating all game versions';
    case 'sync':
    case 'update-all':
      return flv ? `Updating ${flv} addons` : 'Updating addons';
    case 'update':
      return targetLabel ? `Updating ${targetLabel}` : withFlv('Updating addon');
    case 'install':
    case 'install_zip':
      return targetLabel ? `Installing ${targetLabel}` : withFlv('Installing addon');
    case 'install_dependencies':
      return targetLabel ? `Installing libraries for ${targetLabel}` : withFlv('Installing missing libraries');
    case 'uninstall':
      return targetLabel ? `Removing ${targetLabel}` : withFlv('Removing addons');
    case 'rollback':
      return targetLabel ? `Rolling back ${targetLabel}` : withFlv('Rolling back addon');
    case 'copy-addons':
      return flv ? `Copying addons to ${flv}` : 'Copying addons';
    case 'backup-wtf':
      return withFlv('Backing up WTF');
    case 'restore-wtf-all':
      return withFlv('Restoring WTF');
    default:
      return withFlv(kind.replace(/[_-]+/g, ' '));
  }
}

export function describeQueuedBehind(
  activeKind: string | null | undefined,
  activeFlavour: string | null | undefined,
  flavours?: readonly FlavourLabelLike[],
): string {
  if (!activeKind) return 'Queued in task runner';
  return `Queued behind ${describeJobTitle(activeKind, activeFlavour, flavours, null, 'active')}`;
}

export function jobHasActionableErrors(resultsJson: string | null | undefined, state?: string | null, error?: string | null): boolean {
  if (state === 'failed' || (typeof error === 'string' && error.length > 0)) return true;
  if (!resultsJson) return false;
  try {
    const parsed: unknown = JSON.parse(resultsJson);
    const hasRowError = (row: unknown): boolean => {
      if (!isRecord(row)) return false;
      if (typeof row.error === 'string' && row.error.length > 0) return true;
      if (row.success === false) return true;
      return row.status === 'failed' || row.status === 'Failed' || row.status === 'error';
    };
    if (Array.isArray(parsed)) {
      return parsed.some((item) => {
        if (hasRowError(item)) return true;
        if (!isRecord(item)) return false;
        if (Array.isArray(item.failed) && item.failed.length > 0) return true;
        if (Array.isArray(item.results) && item.results.some(hasRowError)) return true;
        return false;
      });
    }
    if (isRecord(parsed)) {
      if (typeof parsed.failed === 'number' && parsed.failed > 0) return true;
      if (typeof parsed.failed_count === 'number' && parsed.failed_count > 0) return true;
      if (Array.isArray(parsed.failed) && parsed.failed.length > 0) return true;
      if (Array.isArray(parsed.failed_items) && parsed.failed_items.length > 0) return true;
      if (Array.isArray(parsed.outcomes) && parsed.outcomes.some(hasRowError)) return true;
      if (Array.isArray(parsed.results) && parsed.results.some(hasRowError)) return true;
      if (Array.isArray(parsed.addons) && parsed.addons.some(hasRowError)) return true;
    }
  } catch {
    return false;
  }
  return false;
}
