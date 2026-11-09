/**
 * Tauri expects camelCase argument names for Rust parameters (`addon_id` is `addonId` on the JavaScript side).
 * Many call sites in this app pass snake_case keys, which the mock IPC reads, so in the real app each top-level
 * snake_case key also gets its camelCase twin. Nested values (for example the `params` object of a job) are untouched.
 */
export function withCamelAliases(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...args };
  for (const [key, value] of Object.entries(args)) {
    if (!key.includes('_')) continue;
    const camel = key.replace(/_([a-z0-9])/g, (_match, c: string) => c.toUpperCase());
    if (!(camel in out)) out[camel] = value;
  }
  return out;
}
