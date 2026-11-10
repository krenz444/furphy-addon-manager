// Shared access to window.__furphyMock for the mock modules. mockIpc.ts creates the hook object after it has run the
// init functions, so the property is made a merging accessor first: whatever a module attaches early survives.
export function getFurphyMock(): Record<string, unknown> {
  if (typeof window === 'undefined') return {};
  const w = window as unknown as Record<string, unknown>;
  const desc = Object.getOwnPropertyDescriptor(w, '__furphyMock');
  if (!desc || (!desc.get && !desc.set)) {
    let currentMock = (w.__furphyMock as Record<string, unknown>) || {};
    Object.defineProperty(w, '__furphyMock', {
      configurable: true,
      enumerable: true,
      get() {
        return currentMock;
      },
      set(val: Record<string, unknown>) {
        if (val && typeof val === 'object') {
          Object.assign(val, currentMock);
          currentMock = val;
        } else {
          currentMock = val || {};
        }
      },
    });
  }
  return w.__furphyMock as Record<string, unknown>;
}
