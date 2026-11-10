// Range and toggle logic for the addon list. Pure: nothing here touches the DOM.

/** Ids from the anchor to the target inclusive, in list order. A missing anchor gives just the target. */
export function selectRange(orderedIds: string[], anchorId: string | null, targetId: string): string[] {
  const targetIndex = orderedIds.indexOf(targetId);
  if (targetIndex < 0) return [];
  const anchorIndex = anchorId === null ? -1 : orderedIds.indexOf(anchorId);
  if (anchorIndex < 0) return [targetId];
  const from = Math.min(anchorIndex, targetIndex);
  const to = Math.max(anchorIndex, targetIndex);
  return orderedIds.slice(from, to + 1);
}

export interface SelectionModifiers {
  shift: boolean;
  ctrl: boolean;
}

/**
 * A click on a row checkbox. Shift with a usable anchor adds the whole range to the selection; anything else toggles
 * the clicked row. The clicked row becomes the anchor either way. `current` is never changed.
 */
export function nextSelection(
  current: Set<string>,
  orderedIds: string[],
  anchorId: string | null,
  clickedId: string,
  mods: SelectionModifiers,
): { selected: Set<string>; anchor: string } {
  const selected = new Set(current);
  if (mods.shift && anchorId !== null && orderedIds.includes(anchorId) && orderedIds.includes(clickedId)) {
    for (const id of selectRange(orderedIds, anchorId, clickedId)) selected.add(id);
    return { selected, anchor: clickedId };
  }
  if (selected.has(clickedId)) selected.delete(clickedId);
  else selected.add(clickedId);
  return { selected, anchor: clickedId };
}

const NOT_TEXT_INPUT_TYPES = new Set(['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color']);

/** True for elements where Ctrl+A and Escape belong to the field: text inputs, textareas, selects, contenteditable. */
export function isEditableTarget(target: EventTarget | null | undefined): boolean {
  if (!target || typeof target !== 'object') return false;
  const el = target as { tagName?: unknown; type?: unknown; isContentEditable?: unknown };
  if (el.isContentEditable === true) return true;
  const tag = typeof el.tagName === 'string' ? el.tagName.toUpperCase() : '';
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag === 'INPUT') {
    const type = typeof el.type === 'string' ? el.type.toLowerCase() : 'text';
    return !NOT_TEXT_INPUT_TYPES.has(type);
  }
  return false;
}
