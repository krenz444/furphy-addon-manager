/**
 * HTML Sanitizer for upstream CurseForge and Wago descriptions/changelogs.
 * Exactly matches v1's whitelist of tags and attributes, enforcing http/https URLs,
 * stripping dangerous tags (script, style, iframe, etc.), and unnesting unknown elements.
 */

const ALLOWED_TAGS: Record<string, boolean> = {
  P: true,
  BR: true,
  B: true,
  STRONG: true,
  I: true,
  EM: true,
  U: true,
  UL: true,
  OL: true,
  LI: true,
  A: true,
  IMG: true,
  H1: true,
  H2: true,
  H3: true,
  H4: true,
  H5: true,
  H6: true,
  BLOCKQUOTE: true,
  CODE: true,
  PRE: true,
  SPAN: true,
  DIV: true,
  TABLE: true,
  THEAD: true,
  TBODY: true,
  TR: true,
  TD: true,
  TH: true,
  HR: true,
  SMALL: true,
  SUP: true,
  SUB: true,
  S: true,
  DEL: true,
  DL: true,
  DT: true,
  DD: true,
};

const ALLOWED_ATTRS: Record<string, string[]> = {
  A: ['href', 'title'],
  IMG: ['src', 'alt', 'title'],
};

export function safeUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const base = typeof window !== 'undefined' ? window.location.href : 'http://localhost';
    const u = new URL(url, base);
    if (u.protocol === 'http:' || u.protocol === 'https:') {
      return u.href;
    }
  } catch {
    // Invalid URL fallback
  }
  return null;
}

function cleanNode(node: Node): void {
  const children = Array.from(node.childNodes);
  for (const child of children) {
    if (child.nodeType === Node.TEXT_NODE) {
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) {
      node.removeChild(child);
      continue;
    }

    const el = child as HTMLElement;
    const tag = el.tagName.toUpperCase();

    // Strip high-risk executable or embedding elements
    if (['SCRIPT', 'STYLE', 'IFRAME', 'OBJECT', 'EMBED', 'LINK', 'META'].includes(tag)) {
      el.remove();
      continue;
    }

    // Unwrap unrecognized tags: clean children first, hoist them, remove wrapper
    if (!ALLOWED_TAGS[tag]) {
      cleanNode(el);
      while (el.firstChild) {
        node.insertBefore(el.firstChild, el);
      }
      el.remove();
      continue;
    }

    // Filter attributes to allowed list
    const keepAttrs = ALLOWED_ATTRS[tag] || [];
    const attrs = Array.from(el.attributes);
    for (const attr of attrs) {
      if (!keepAttrs.includes(attr.name.toLowerCase())) {
        el.removeAttribute(attr.name);
      }
    }

    // Handle <a> attributes safely
    if (tag === 'A') {
      const href = el.getAttribute('href');
      const safe = safeUrl(href);
      if (safe) {
        el.setAttribute('href', safe);
        el.setAttribute('target', '_blank');
        el.setAttribute('rel', 'noopener noreferrer');
      } else {
        el.removeAttribute('href');
      }
    }

    // Handle <img> attributes safely
    if (tag === 'IMG') {
      const src = el.getAttribute('src');
      const safe = safeUrl(src);
      if (safe) {
        el.setAttribute('src', safe);
        el.setAttribute('loading', 'lazy');
      } else {
        el.remove();
        continue;
      }
    }

    // Recursively clean valid subtree
    cleanNode(el);
  }
}

export function sanitizeHtml(html: string): string {
  if (typeof DOMParser === 'undefined') {
    return html.replace(/<[^>]*>/g, '');
  }
  const doc = new DOMParser().parseFromString(html || '', 'text/html');
  cleanNode(doc.body);
  return doc.body.innerHTML;
}
