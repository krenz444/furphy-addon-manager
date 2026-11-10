// Matching for the settings search box. Pure.

/** Lower case, accents removed, runs of white space collapsed, trimmed. */
export function normalizeQuery(q: string): string {
  return String(q ?? '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

/** Every word of the query must appear somewhere in the text. An empty query matches everything. */
export function matchesQuery(query: string, text: string): boolean {
  const words = normalizeQuery(query).split(' ').filter(Boolean);
  if (words.length === 0) return true;
  const haystack = normalizeQuery(text);
  return words.every((word) => haystack.includes(word));
}
