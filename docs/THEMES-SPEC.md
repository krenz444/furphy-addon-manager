# Furphy Addon Manager — Theme Expansion Spec

Eric's request: make Vaporwave the main (default) theme again, and add 10 new creative, CSS-only themes alongside the existing four (Dark, Light, Vaporwave, Lofi Night). This document is the synthesized, buildable spec from the Map → Design → Judge pipeline. It is the only file that pipeline is permitted to write.

Total theme count after this change: **14** — Vaporwave, Lofi Night, Dark, Light, plus the 10 chosen below.

---

## 0. Selection method

15 candidate themes were designed and scored by 3 judges (distinctiveness / coherence / contrast / feasibility / delight, 1–10 each, summed to a 50-max total per judge, 150-max tally across 3 judges).

**Rejected outright** (do not ship, not reconsidered for the ten):
- `parchment-ink` — token block omitted `--accent-active` (required by the contract; flagged by all 3 judges).
- `console-pastel` — same omission (flagged by all 3 judges).
- `coral-reef` — `--accent` (#ff9686) and `--danger` (#ff8a8a) are near-identical coral-red hues; a danger pill would not read as distinct from ordinary accent-colored UI (flagged by all 3 judges as a status-color-meaning failure, the one hard reject criterion in the brief).

**Tally, rejects removed, highest first:**

| slug | tally |
|---|---|
| terminal-green | 132 |
| arctic-ice | 130 |
| art-deco-gold | 127 |
| alpine-dawn | 126 |
| matcha | 126 |
| desert-night | 122 |
| tokyo-rain | 122 |
| brushed-steel | 122 |
| aurora-sky | 121 |
| strawberry-cream | 119 |
| autumn-orchard | 118 |
| midnight-jazz | 115 |

**Variety check** (no two chosen themes may share the same dominant hue family for BOTH `--bg-0` AND `--accent`; at most 3 light themes): computed approximate HSL hue angle for every top-10 candidate's `--bg-0` and `--accent`. No pair matches on both axes simultaneously — e.g. `desert-night` and `alpine-dawn` both lean orange on accent but sit in different bg-0 families (indigo-black vs. blue-gray-black); `tokyo-rain` and `aurora-sky` share a blue-black bg-0 family but diverge on accent (magenta-pink vs. violet). Light themes in the top 10: `arctic-ice`, `matcha`, `strawberry-cream` = exactly 3, at the cap. **No swap was required** — the top 10 by tally already satisfies both constraints.

**Final ten (in tally order):**

1. Terminal Green (`terminal-green`)
2. Arctic Ice (`arctic-ice`)
3. Art Deco (`art-deco-gold`)
4. Alpine Dawn (`alpine-dawn`)
5. Matcha (`matcha`)
6. Desert Night (`desert-night`)
7. Tokyo Rain (`tokyo-rain`)
8. Brushed Steel (`brushed-steel`)
9. Aurora Sky (`aurora-sky`)
10. Strawberry Cream (`strawberry-cream`)

Not chosen (ranked but cut at 10, or rejected): `autumn-orchard`, `midnight-jazz`, `parchment-ink`, `console-pastel`, `coral-reef`. None of the final ten required a judge-mandated contrast fix — every token value below is unchanged from its reviewed candidate.

---

## 1. The ten themes

Each entry: concept, restated contrast ratios (as verified/accepted by the judges), the complete verbatim token block (CSS custom properties, `color-scheme`, geometry if overridden), its required select-chevron override, its signature-touch spec, and the 8-color palette `Host.reportTheme()` will send to the native title bar.

### 1. Terminal Green — `terminal-green`

**Concept:** A CRT monitor glowing alone in a dark server room — near-black background, phosphor-green text and accent, amber/red/cyan status lights like an old diagnostic console.

**Contrast (verified):** text/bg-0 15.56:1, text/bg-1 14.87:1, muted/bg-1 9.57:1, muted/bg-2 8.87:1, faint/bg-1 6.34:1, faint/bg-3 5.26:1, accent-text/accent 14.18:1 (independently re-derived by 2 of 3 judges, exact match). Chip text-on-tint over bg-1 (a=.14): success 10.64:1, warning 9.59:1, danger 5.44:1, info 9.71:1. banner-danger-text/danger-tint-over-bg-0 10.32:1, form-error-text/danger-tint-over-bg-1 9.69:1, danger-text/danger 6.18:1. Widest margins of the whole set. Known, accepted quirk: `--success` and `--accent` are the identical hex (#39ff88) — a single-hue CRT concept, not a contrast defect; flagged by all judges as worth a maintainer's eyes-open sign-off, not a blocker.

```css
:root[data-theme="terminal-green"] {
  color-scheme: dark;
  --bg-0: #050806;
  --bg-1: #0a100c;
  --bg-2: #101a13;
  --bg-3: #17251b;
  --border: #1f3524;
  --border-soft: #132015;
  --border-hover: #2c4a34;

  --text: #5affa0;
  --text-muted: #3fcf82;
  --text-faint: #2fa869;

  --accent: #39ff88;
  --accent-hover: #6dffa8;
  --accent-active: #1fdb6c;
  --accent-text: #04150a;

  --success: #39ff88;
  --warning: #ffcc33;
  --danger: #ff5c5c;
  --info: #59e6ff;

  --success-tint: rgba(57, 255, 136, .14);
  --warning-tint: rgba(255, 204, 51, .14);
  --danger-tint: rgba(255, 92, 92, .14);
  --info-tint: rgba(89, 230, 255, .14);
  --accent-tint: rgba(57, 255, 136, .16);
  --muted-tint: rgba(63, 207, 130, .12);

  --banner-danger-text: #ffb3b3;
  --form-error-text: #ff9d9d;

  --danger-hover: #ff7d7d;
  --danger-text: #2a0505;
  --danger-border: rgba(255, 92, 92, .35);
  --danger-outline-border: rgba(255, 92, 92, .4);

  --focus-ring: var(--accent);

  --radius-sm: 2px;
  --radius: 4px;
  --radius-lg: 6px;
}

:root[data-theme="terminal-green"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%233fcf82' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** CRT scanlines — `.app-shell::before`, fixed, pointer-events:none, `repeating-linear-gradient(180deg, rgba(0,0,0,.09) 0 1px, transparent 1px 3px)` over the whole viewport; explicitly set `z-index:0` on this layer and confirm all interactive/text elements have `position:relative` (or higher stacking context) so the scanlines never sit above hit targets — this is the one signature layer in the set that isn't sidebar-scoped, so it needs its own explicit z-index check during build, unlike the sidebar-confined layers on every other theme. Phosphor glow on brand name and `.nav-item.is-active`/`.btn-accent`: `text-shadow:0 0 6px rgba(57,255,136,.55)` / matching `box-shadow`, always on. Optional flicker: 3s `opacity .94→1→.94` pulse on that glow, wrapped in `@media (prefers-reduced-motion: no-preference)` (i.e. the pulse itself is the thing gated *on*; reduced-motion users get the static glow with no pulse — verify this reads correctly at build time, it's the one theme in the set phrased as an inclusion-gate rather than the usual `reduce{ animation:none }` exclusion-gate).

**Host palette:** bg0 `#050806` bg1 `#0a100c` bg2 `#101a13` bg3 `#17251b` border `#1f3524` text `#5affa0` muted `#3fcf82` accent `#39ff88`

---

### 2. Arctic Ice — `arctic-ice`

**Concept:** A glacier field at noon — white snow-glare, pale blue shadow in the crevasses, one deep teal meltwater pool. Crisp, minimal, cold-bright — the calm, motion-free anchor of the set.

**Contrast (verified):** text/bg-0 14.48:1, text/bg-1 16.07:1, muted/bg-1 6.65:1, muted/bg-2 5.59:1, faint/bg-1 6.47:1, faint/bg-3 4.91:1, accent-text/accent 5.63:1 (independently re-derived twice, exact match). Chip text-on-tint over bg-1/bg-2 (a=.10): success 5.39/4.58, warning 5.50/4.66, danger 5.81/4.92, info 5.92/5.02. banner-danger-text/danger-tint-over-bg-0 5.25:1. All pairs clear 4.5:1 with real margin.

```css
:root[data-theme="arctic-ice"] {
  color-scheme: light;
  --bg-0: #eef4f7;
  --bg-1: #ffffff;
  --bg-2: #e2edf3;
  --bg-3: #d2e3ec;
  --border: #c3d7e2;
  --border-soft: #dbe8ef;
  --border-hover: #a9c4d4;

  --text: #14232c;
  --text-muted: #47606c;
  --text-faint: #48626e;

  --accent: #0c6c8f;
  --accent-hover: #0a5977;
  --accent-active: #084a63;
  --accent-text: #f2fbff;

  --success: #0a6e4c;
  --warning: #7d5900;
  --danger: #a92c26;
  --info: #215e8f;

  --success-tint: rgba(10, 110, 76, .10);
  --warning-tint: rgba(125, 89, 0, .10);
  --danger-tint: rgba(169, 44, 38, .10);
  --info-tint: rgba(33, 94, 143, .10);
  --accent-tint: rgba(12, 108, 143, .12);
  --muted-tint: rgba(71, 96, 108, .10);

  --banner-danger-text: #a92c26;
  --form-error-text: #a92c26;

  --danger-hover: #8f231e;
  --danger-text: #fff5f4;
  --danger-border: rgba(169, 44, 38, .35);
  --danger-outline-border: rgba(169, 44, 38, .4);

  --focus-ring: var(--accent);
}

:root[data-theme="arctic-ice"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%2347606c' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** None — deliberately. Two static `radial-gradient(rgba(255,255,255,.5) 0%, transparent 60%)` frost-glows at the top-left/top-right corners behind `.sidebar`. Zero keyframes, nothing to gate under `prefers-reduced-motion`.

**Host palette:** bg0 `#eef4f7` bg1 `#ffffff` bg2 `#e2edf3` bg3 `#d2e3ec` border `#c3d7e2` text `#14232c` muted `#47606c` accent `#0c6c8f`

---

### 3. Art Deco — `art-deco-gold`

**Concept:** A 1920s lobby at closing time — matte black surfaces, warm ivory text, one disciplined gold accent standing in for brass fittings. Geometric and restrained.

**Contrast (verified):** text/bg-0 15.77:1, text/bg-1 14.84:1, muted/bg-1 7.90:1, muted/bg-2 7.30:1, faint/bg-1 5.54:1, faint/bg-3 4.54:1 (faint was lifted from a failing #8f8262/3.98 to #998c6c), accent-text/accent 8.70:1. Chip text-on-tint over bg-1: success 5.33:1 (a=.14), warning 5.60:1 (a=.14), danger 5.71:1 (a=.12 — danger lifted from a failing #e0483f/3.96 to #ff6e5f and its tint alpha eased .14→.12), info 4.65:1 (a=.14). banner-danger-text/danger-tint-over-bg-0 10.90:1, form-error-text/danger-tint-over-bg-1 10.05:1, danger-text/danger 6.74:1. All clear 4.5:1.

*Judge note (non-blocking):* `--accent` gold (#d4af37) and `--warning` (#e08a2e) sit close in hue — in a one-hero-color theme, a warning pill risks reading as "more brass trim." Two of three judges flagged this as worth a future nudge; not required to ship, token values below are the accepted, verbatim-passing set.

```css
:root[data-theme="art-deco-gold"] {
  color-scheme: dark;
  --bg-0: #0c0c0d;
  --bg-1: #141416;
  --bg-2: #1c1c1f;
  --bg-3: #262629;
  --border: #33302a;
  --border-soft: #201f1c;
  --border-hover: #4a4438;

  --text: #f2e6c9;
  --text-muted: #b8a97e;
  --text-faint: #998c6c;

  --accent: #d4af37;
  --accent-hover: #e6c65c;
  --accent-active: #b8932a;
  --accent-text: #1a1408;

  --success: #2fae6c;
  --warning: #e08a2e;
  --danger: #ff6e5f;
  --info: #4f8fe0;

  --success-tint: rgba(47, 174, 108, .14);
  --warning-tint: rgba(224, 138, 46, .14);
  --danger-tint: rgba(255, 110, 95, .12);
  --info-tint: rgba(79, 143, 224, .14);
  --accent-tint: rgba(212, 175, 55, .16);
  --muted-tint: rgba(184, 169, 126, .12);

  --banner-danger-text: #ffc0b6;
  --form-error-text: #ffaa9c;

  --danger-hover: #ff8b7e;
  --danger-text: #2a0805;
  --danger-border: rgba(255, 110, 95, .35);
  --danger-outline-border: rgba(255, 110, 95, .4);

  --focus-ring: var(--accent);

  --radius-sm: 2px;
  --radius: 4px;
  --radius-lg: 8px;
}

:root[data-theme="art-deco-gold"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%23b8a97e' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** `.sidebar::after`, same masked-fade-upward/pointer-events:none/sidebar-children-z-index:1 pattern as Vaporwave's grid — two overlaid `repeating-linear-gradient`s at 45°/-45°, `rgba(212,175,55,.06)` hairlines every 22px, a faint sunburst lattice. `.nav-item.is-active` and the top edge of `.settings-group` get a double gold hairline frame (`box-shadow:0 0 0 1px rgba(212,175,55,.5), 0 2px 0 rgba(212,175,55,.25)`). Entirely static — nothing to gate.

**Host palette:** bg0 `#0c0c0d` bg1 `#141416` bg2 `#1c1c1f` bg3 `#262629` border `#33302a` text `#f2e6c9` muted `#b8a97e` accent `#d4af37`

---

### 4. Alpine Dawn — `alpine-dawn`

**Concept:** Blue hour on a snowfield, five minutes before sunrise — icy shadow still on the ridgeline while the first coral-gold band lights the peaks. A quiet cold-to-warm gradient rather than a saturated one.

**Contrast (verified):** text/bg-0 16.28:1, text/bg-1 15.05:1, muted/bg-1 8.26:1, muted/bg-2 7.26:1, faint/bg-1 6.69:1, faint/bg-3 4.93:1 (faint lifted from a failing #8393a2/3.96 to #95a5b1), accent-text/accent 7.71:1. Chip text-on-tint over bg-1/bg-2: success 6.97/6.10, warning 8.15/7.07, danger 5.41/4.77 (danger lifted from #ff6b6f, 4.44 on bg-2, to #ff7a7d), info 6.72/5.88, accent 5.80/5.11. banner-danger-text/danger-tint-over-bg-0 9.94:1, form-error-text/danger-tint-over-bg-1 7.87:1, danger-text/danger 7.14:1. All clear 4.5:1, tightest margin faint/bg-3 at 4.93.

```css
:root[data-theme="alpine-dawn"] {
  color-scheme: dark;
  --bg-0: #10151c;
  --bg-1: #161d27;
  --bg-2: #1f2833;
  --bg-3: #2a3540;
  --border: #33404c;
  --border-soft: #1f2833;
  --border-hover: #44525f;

  --text: #eef2f5;
  --text-muted: #a8b7c4;
  --text-faint: #95a5b1;

  --accent: #ff8c5a;
  --accent-hover: #ffa478;
  --accent-active: #e8703c;
  --accent-text: #2a1206;

  --success: #5ed6a0;
  --warning: #ffcb61;
  --danger: #ff7a7d;
  --info: #6ec6ff;

  --secondary: #ffb0c8;

  --success-tint: rgba(94, 214, 160, .14);
  --warning-tint: rgba(255, 203, 97, .14);
  --danger-tint: rgba(255, 122, 125, .14);
  --info-tint: rgba(110, 198, 255, .14);
  --accent-tint: rgba(255, 140, 90, .14);
  --muted-tint: rgba(168, 183, 196, .14);

  --banner-danger-text: #ffc4c6;
  --form-error-text: #ffb0b5;

  --danger-hover: #ff9698;
  --danger-text: #2a0e0e;
  --danger-border: rgba(255, 122, 125, .35);
  --danger-outline-border: rgba(255, 122, 125, .4);

  --focus-ring: var(--secondary);

  --radius-sm: 4px;
  --radius: 8px;
  --radius-lg: 12px;
}

:root[data-theme="alpine-dawn"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%23a8b7c4' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** Static inline-SVG ridgeline silhouette behind `.sidebar` (same masked/fade-upward/pointer-events:none/z-index pattern as the other themes' art layer): one jagged polyline filled `--bg-3`, one thin horizontal band above it (`linear-gradient(--accent → --secondary → transparent)`, opacity .10) for first light on the peaks. Optionally one small static "morning star" dot, `--secondary` at .5 opacity. No animation at all — nothing to gate.

**Host palette:** bg0 `#10151c` bg1 `#161d27` bg2 `#1f2833` bg3 `#2a3540` border `#33404c` text `#eef2f5` muted `#a8b7c4` accent `#ff8c5a`

---

### 5. Matcha — `matcha`

**Concept:** A quiet tea-ceremony room at midday — whisked green matcha, unbleached washi paper, warm wood in soft daylight. Calm, low-saturation, grounded — the antidote to Vaporwave's neon buzz, and the most distinct light theme of the whole set.

**Contrast (verified, tint alpha .10 semantic / .12 accent):** text/bg-0 11.98:1, text/bg-1 13.10:1, muted/bg-1 6.35:1, muted/bg-2 5.35:1, faint/bg-1 6.19:1, faint/bg-3 4.52:1, accent-text/accent 4.71:1 (independently re-derived twice — 4.719 and 4.71 — the single tightest margin of the whole 15-candidate field; passes, flagged for a hover/active-state spot-check before ship, not a blocker). success/tint-bg-1 5.33, /bg-2 4.54. warning/tint-bg-1 5.74, /bg-2 4.88. danger/tint-bg-1 5.45, /bg-2 4.63. info/tint-bg-1 6.58, /bg-2 5.60. banner-danger-text/danger-tint-over-bg-0 4.99:1. All clear 4.5:1.

```css
:root[data-theme="matcha"] {
  color-scheme: light;
  --bg-0: #f1efe1;
  --bg-1: #faf9f0;
  --bg-2: #eae6d3;
  --bg-3: #ddd7bd;
  --border: #cec5a0;
  --border-soft: #e2ddc7;
  --border-hover: #b3a878;

  --text: #24301f;
  --text-muted: #52604a;
  --text-faint: #556150;

  --accent: #4f7942;
  --accent-hover: #3e6333;
  --accent-active: #345228;
  --accent-text: #f5f8ee;

  --success: #1f6b40;
  --warning: #7d4f00;
  --danger: #a5342a;
  --info: #1f5570;

  --success-tint: rgba(31, 107, 64, .10);
  --warning-tint: rgba(125, 79, 0, .10);
  --danger-tint: rgba(165, 52, 42, .10);
  --info-tint: rgba(31, 85, 112, .10);
  --accent-tint: rgba(79, 121, 66, .12);
  --muted-tint: rgba(82, 96, 74, .10);

  --banner-danger-text: #a5342a;
  --form-error-text: #a5342a;

  --danger-hover: #8a2921;
  --danger-text: #fff5f3;
  --danger-border: rgba(165, 52, 42, .35);
  --danger-outline-border: rgba(165, 52, 42, .4);

  --focus-ring: var(--accent);
}

:root[data-theme="matcha"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%2352604a' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** One small inline-SVG teacup (~40×36) low in the sidebar, below the nav list (pointer-events:none, z-index below sidebar content). Two thin steam-wisp `<path>`s curl from the rim, each animating `opacity .5→.15` + `translateY(0→-6px)` over 4s ease-in-out infinite alternate, offset 1.5s apart. Under `prefers-reduced-motion: reduce`, both wisps sit static at opacity .3. Placement (bottom of sidebar, below nav) means it can never occlude a control.

**Host palette:** bg0 `#f1efe1` bg1 `#faf9f0` bg2 `#eae6d3` bg3 `#ddd7bd` border `#cec5a0` text `#24301f` muted `#52604a` accent `#4f7942`

---

### 6. Desert Night — `desert-night`

**Concept:** A cold, star-strung desert well after sunset — indigo dunes rolling to the dark, lit only by a campfire's amber glow and a streak of far-off magenta on the horizon.

**Contrast (verified):** text/bg-0 16.21:1, text/bg-1 15.29:1, muted/bg-1 7.33:1, muted/bg-2 6.65:1, faint/bg-1 5.77:1, faint/bg-3 4.57:1 (faint lifted from a failing #8c7c99/3.70 to #9c8caa), accent-text/accent 8.84:1. Chip text-on-tint over bg-1/bg-2: success 7.87/7.09, warning 8.75/7.77, danger 5.44/4.86 (danger lifted from a near-failing #ff5c72/4.47 to #ff6f82), info 5.66/5.07, accent 7.09/6.31. banner-danger-text/danger-tint-over-bg-0 10.48:1, form-error-text/danger-tint-over-bg-1 8.27:1, danger-text/danger 6.70:1. All clear 4.5:1.

```css
:root[data-theme="desert-night"] {
  color-scheme: dark;
  --bg-0: #120e1a;
  --bg-1: #1a1424;
  --bg-2: #251c31;
  --bg-3: #302640;
  --border: #3a2e4d;
  --border-soft: #251c31;
  --border-hover: #4d3d63;

  --text: #f3ece0;
  --text-muted: #b0a0b8;
  --text-faint: #9c8caa;

  --accent: #ffa552;
  --accent-hover: #ffb873;
  --accent-active: #e88c38;
  --accent-text: #2a1608;

  --success: #8ed966;
  --warning: #ffcc66;
  --danger: #ff6f82;
  --info: #6fa8dc;

  --secondary: #d876c9;

  --success-tint: rgba(142, 217, 102, .14);
  --warning-tint: rgba(255, 204, 102, .14);
  --danger-tint: rgba(255, 111, 130, .14);
  --info-tint: rgba(111, 168, 220, .14);
  --accent-tint: rgba(255, 165, 82, .14);
  --muted-tint: rgba(176, 160, 184, .14);

  --banner-danger-text: #ffc4cd;
  --form-error-text: #ffadb8;

  --danger-hover: #ff8998;
  --danger-text: #2a0e14;
  --danger-border: rgba(255, 111, 130, .35);
  --danger-outline-border: rgba(255, 111, 130, .4);

  --focus-ring: var(--secondary);

  --radius-sm: 4px;
  --radius: 8px;
  --radius-lg: 12px;
}

:root[data-theme="desert-night"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%23b0a0b8' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** Static inline-SVG dune-ridge silhouette (`--bg-3`) behind `.sidebar`, same masked/pointer-events pattern as the family. 3–4 tiny circular stars in `--text-faint`, low opacity, above the ridge, each with its own staggered slow (3–5s) twinkle keyframe (opacity .2→.6) — a distinct count/shape from Lofi Night's stars, not a re-skin. One star carries a warm `--accent` tint to read as "ember light." All twinkles wrapped in `@media (prefers-reduced-motion: reduce){ animation:none }`.

**Host palette:** bg0 `#120e1a` bg1 `#1a1424` bg2 `#251c31` bg3 `#302640` border `#3a2e4d` text `#f3ece0` muted `#b0a0b8` accent `#ffa552`

---

### 7. Tokyo Rain — `tokyo-rain`

**Concept:** A crosswalk at 1am after the rain has stopped — magenta shop signage and a single cyan streetlight bleeding into wet asphalt. Cool neutral blue-blacks keep it grounded as a real city street rather than a synth dreamscape.

**Contrast (verified):** text/bg-0 16.40:1 (independently re-derived twice, exact match), text/bg-1 15.40:1, muted/bg-1 7.22:1, muted/bg-2 6.57:1, faint/bg-1 5.86:1, faint/bg-3 4.72:1, accent-text/accent 6.50:1 (independently re-derived, exact match). Chip text-on-tint over bg-1/bg-2: success 8.46/7.54, warning 7.79/6.95, danger 5.31/4.77, info 8.26/7.34, accent 5.26/4.78. banner-danger-text/danger-tint-over-bg-0 10.13:1, form-error-text/danger-tint-over-bg-1 8.06:1, danger-text/danger 6.39:1. All clear 4.5:1 — danger was deliberately nudged from #ff5470 to #ff6478 and accent from #ff3d9a to #ff5aa8 to clear the historically-tight chip-over-bg-2 case with margin, not sit at the edge.

*Judge note (non-blocking):* the magenta-accent/cyan-secondary palette on near-black sits close to Vaporwave's own register — an intentional risk given Vaporwave is the returning flagship. Distinguish clearly by name/thumbnail in the picker; the palette itself (cooler, blue-black rather than purple-black, and a distinct pink rather than Vaporwave's hot-pink/cyan pairing) is different enough to keep.

```css
:root[data-theme="tokyo-rain"] {
  color-scheme: dark;
  --bg-0: #0b0d14;
  --bg-1: #12151f;
  --bg-2: #1a1e2c;
  --bg-3: #232838;
  --border: #2c3244;
  --border-soft: #1a1e2c;
  --border-hover: #3a4258;

  --text: #e8ecf5;
  --text-muted: #9aa3ba;
  --text-faint: #8892ac;

  --accent: #ff5aa8;
  --accent-hover: #ff7ab8;
  --accent-active: #e8409e;
  --accent-text: #1a0e18;

  --success: #2fe6a7;
  --warning: #ffb347;
  --danger: #ff6478;
  --info: #4dd9ff;

  --secondary: #4dd9ff;

  --success-tint: rgba(47, 230, 167, .14);
  --warning-tint: rgba(255, 179, 71, .14);
  --danger-tint: rgba(255, 100, 120, .14);
  --info-tint: rgba(77, 217, 255, .14);
  --accent-tint: rgba(255, 90, 168, .14);
  --muted-tint: rgba(154, 163, 186, .14);

  --banner-danger-text: #ffb8c4;
  --form-error-text: #ffa3b3;

  --danger-hover: #ff8494;
  --danger-text: #2a0a10;
  --danger-border: rgba(255, 100, 120, .35);
  --danger-outline-border: rgba(255, 100, 120, .4);

  --focus-ring: var(--secondary);

  --radius-sm: 4px;
  --radius: 8px;
  --radius-lg: 12px;
}

:root[data-theme="tokyo-rain"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%239aa3ba' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** Behind `.sidebar` (masked-fade-upward/pointer-events:none/z-index-1-on-children, same pattern as Vaporwave/Lofi): two soft blurred radial-gradient blobs (one `--accent`, one `--secondary`, ~60px falloff, opacity .08) bottom-left/bottom-right like neon signs reflected in a puddle, plus 4–5 thin diagonal `repeating-linear-gradient` hairlines in `--text-faint` at .05 opacity crossing the lower third as rain streaks. The accent blob pulses opacity .06↔.12 over 6s ease-in-out, wrapped in `@media (prefers-reduced-motion: reduce){ animation:none }`.

**Host palette:** bg0 `#0b0d14` bg1 `#12151f` bg2 `#1a1e2c` bg3 `#232838` border `#2c3244` text `#e8ecf5` muted `#9aa3ba` accent `#ff5aa8`

---

### 8. Brushed Steel — `brushed-steel`

**Concept:** A machine-shop workbench at night — cool gunmetal panels, a bright indicator-LED blue accent, safety-amber/teal status lights. Industrial and precise rather than moody.

**Contrast (verified):** text/bg-0 14.00:1, text/bg-1 12.43:1, muted/bg-1 6.39:1, muted/bg-2 5.50:1, faint/bg-1 5.82:1, faint/bg-3 4.65:1, accent-text/accent 6.37:1. Chip text-on-tint over bg-1: success 5.21:1 (a=.14), warning 5.93:1 (a=.14), danger 4.87:1 (a=.12 — deliberately dropped from .14 to clear the floor, per the dark/light review-comment methodology), info 5.41:1 (a=.14). banner-danger-text/danger-tint-over-bg-0 8.48:1, form-error-text/danger-tint-over-bg-1 7.50:1, danger-text/danger 7.26:1, accent-hover/bg-1 7.11:1. All clear 4.5:1.

```css
:root[data-theme="brushed-steel"] {
  color-scheme: dark;
  --bg-0: #1b1d21;
  --bg-1: #24272c;
  --bg-2: #2e3238;
  --bg-3: #323740;
  --border: #3f454d;
  --border-soft: #2c3036;
  --border-hover: #545c66;

  --text: #e8eaed;
  --text-muted: #a3aab3;
  --text-faint: #9ba2ac;

  --accent: #4fa8e0;
  --accent-hover: #6ebbea;
  --accent-active: #2f8ac2;
  --accent-text: #08202f;

  --success: #4cc38a;
  --warning: #f2b134;
  --danger: #ff7a6b;
  --info: #4fc3c7;

  --success-tint: rgba(76, 195, 138, .14);
  --warning-tint: rgba(242, 177, 52, .14);
  --danger-tint: rgba(255, 122, 107, .12);
  --info-tint: rgba(79, 195, 199, .14);
  --accent-tint: rgba(79, 168, 224, .16);
  --muted-tint: rgba(163, 170, 179, .12);

  --banner-danger-text: #ffb8ac;
  --form-error-text: #ffa599;

  --danger-hover: #ff9686;
  --danger-text: #2a0805;
  --danger-border: rgba(255, 122, 107, .35);
  --danger-outline-border: rgba(255, 122, 107, .4);

  --focus-ring: var(--accent);

  --radius-sm: 3px;
  --radius: 6px;
  --radius-lg: 10px;
}

:root[data-theme="brushed-steel"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%23a3aab3' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** Faint brushed-aluminum grain — `.sidebar::before`/`.app-shell::before`, fixed, pointer-events:none, `repeating-linear-gradient(115deg, rgba(255,255,255,.035) 0 1px, transparent 1px 3px)` behind content, masked to fade toward the edges like the family's grid layers. Four small 3px "rivet" dots (`::before`/`::after` radial-gradient circles, `rgba(0,0,0,.25)` with a 1px highlight) in the corners of `.settings-group` only. Entirely static, nothing to gate.

**Host palette:** bg0 `#1b1d21` bg1 `#24272c` bg2 `#2e3238` bg3 `#323740` border `#3f454d` text `#e8eaed` muted `#a3aab3` accent `#4fa8e0`

---

### 9. Aurora Sky — `aurora-sky`

**Concept:** A black arctic sky torn open by ribbons of green and violet light, with a cold rose hush where the aurora catches the snow below. The most saturated and otherworldly of the ten — the same "glowing signature ribbon" role for this family that Vaporwave's grid plays for the synth family.

**Contrast (verified):** text/bg-0 17.70:1, text/bg-1 16.73:1, muted/bg-1 8.45:1, muted/bg-2 7.70:1 (independently re-derived, exact match), faint/bg-1 5.70:1, faint/bg-3 4.57:1 (independently re-derived, matches to 3 decimals), accent-text/accent 6.99:1. Chip text-on-tint over bg-1/bg-2: success 8.83/7.89, warning 9.43/8.34, danger 5.49/4.93, info 7.83/6.99, accent 5.85/5.21. banner-danger-text/danger-tint-over-bg-0 10.98:1, form-error-text/danger-tint-over-bg-1 8.66:1, danger-text/danger 6.39:1. Passed on first color draft — no rework needed, tightest margin faint/bg-3 at 4.57.

*Judge note (non-blocking):* pitched explicitly as filling the "glowing ribbon on black" role that Vaporwave already owns as the returning flagship — the theme most likely to be mistaken for a Vaporwave variant. Kept because its concept (aurora, not synth-grid) and green/violet/pink triad are visually distinct once seen; keep to at most one theme from this exact "loud neon ribbon on black" register if a future round adds more candidates.

```css
:root[data-theme="aurora-sky"] {
  color-scheme: dark;
  --bg-0: #070b12;
  --bg-1: #0d131c;
  --bg-2: #141d29;
  --bg-3: #1c2836;
  --border: #233040;
  --border-soft: #141d29;
  --border-hover: #324256;

  --text: #eef4f2;
  --text-muted: #9fb3ad;
  --text-faint: #7d938c;

  --accent: #b98cf7;
  --accent-hover: #caa4ff;
  --accent-active: #a06ef0;
  --accent-text: #1c1030;

  --success: #4ce8a3;
  --warning: #ffcf6b;
  --danger: #ff6478;
  --info: #5ad1e0;

  --secondary: #ff7ad1;

  --success-tint: rgba(76, 232, 163, .14);
  --warning-tint: rgba(255, 207, 107, .14);
  --danger-tint: rgba(255, 100, 120, .14);
  --info-tint: rgba(90, 209, 224, .14);
  --accent-tint: rgba(185, 140, 247, .14);
  --muted-tint: rgba(159, 179, 173, .14);

  --banner-danger-text: #ffc0c9;
  --form-error-text: #ffa9b4;

  --danger-hover: #ff8494;
  --danger-text: #2a0a10;
  --danger-border: rgba(255, 100, 120, .35);
  --danger-outline-border: rgba(255, 100, 120, .4);

  --focus-ring: var(--secondary);

  --radius-sm: 4px;
  --radius: 8px;
  --radius-lg: 12px;
}

:root[data-theme="aurora-sky"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%239fb3ad' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** Behind `.sidebar` (identical z-index/pointer-events/fade-mask placement as Vaporwave's grid): 2–3 large, soft, wavy horizontal bands from stacked radial-gradients in `--success` (green), `--accent` (violet), `--secondary` (pink), each opacity .06–.10, generous gradient falloff instead of `filter:blur` to stay cheap — curtains of light, not stripes. Only motion: a slow (16–20s ease-in-out infinite) ±8px horizontal drift plus a gentle opacity breathe on the middle band. Under `prefers-reduced-motion: reduce`, renders as a static three-band glow with no gradient shift, same fallback pattern as Lofi Night's stars/tail.

**Host palette:** bg0 `#070b12` bg1 `#0d131c` bg2 `#141d29` bg3 `#1c2836` border `#233040` text `#eef4f2` muted `#9fb3ad` accent `#b98cf7`

---

### 10. Strawberry Cream — `strawberry-cream`

**Concept:** A dessert-shop counter — pale cream backdrop, a swirl of strawberry pink, a dusting of berry-red sprinkles. Soft, warm, sweet without tipping into pastel-illegible.

**Contrast (verified, tint alpha .10 semantic / .12 accent):** text/bg-0 13.21:1, text/bg-1 14.29:1, muted/bg-1 7.75:1, muted/bg-2 6.39:1, faint/bg-1 6.94:1, faint/bg-3 4.95:1, accent-text/accent 4.72:1 (independently re-derived, exact match — the single tightest non-Matcha margin in the whole field; passes with no rework, flagged for a hover/active-state spot-check before ship). success/tint-bg-1 5.49, /bg-2 4.55. warning/tint-bg-1 5.62, /bg-2 4.69. danger/tint-bg-1 5.59, /bg-2 4.68. info/tint-bg-1 5.67, /bg-2 4.73. banner-danger-text/danger-tint-over-bg-0 5.20:1. All clear 4.5:1, including the bg-2 hover-state checks the brief doesn't strictly require.

```css
:root[data-theme="strawberry-cream"] {
  color-scheme: light;
  --bg-0: #faf1ee;
  --bg-1: #fffbfa;
  --bg-2: #f5e2e0;
  --bg-3: #efd0ce;
  --border: #e3bcb8;
  --border-soft: #f0d9d6;
  --border-hover: #d1a09b;

  --text: #3a2220;
  --text-muted: #6b4844;
  --text-faint: #754e4a;

  --accent: #c43d59;
  --accent-hover: #ab304a;
  --accent-active: #93273f;
  --accent-text: #fff5f6;

  --success: #166b45;
  --warning: #7d5400;
  --danger: #a5342a;
  --info: #2c5f8a;

  --secondary: #e8a0b0;

  --success-tint: rgba(22, 107, 69, .10);
  --warning-tint: rgba(125, 84, 0, .10);
  --danger-tint: rgba(165, 52, 42, .10);
  --info-tint: rgba(44, 95, 138, .10);
  --accent-tint: rgba(196, 61, 89, .12);
  --muted-tint: rgba(107, 72, 68, .10);

  --banner-danger-text: #a5342a;
  --form-error-text: #a5342a;

  --danger-hover: #8a2921;
  --danger-text: #fff5f4;
  --danger-border: rgba(165, 52, 42, .35);
  --danger-outline-border: rgba(165, 52, 42, .4);

  --focus-ring: var(--accent);
}

:root[data-theme="strawberry-cream"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%236b4844' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

**Signature touch:** A small static scatter of 6 inline-SVG "sprinkle" dots/short rounded rects (`--accent`, `--secondary`, `--warning`, alpha ~.3) behind the sidebar's top area — no motion. One small ~3px sparkle on the brand icon pulses opacity .6→1 over 3s ease-in-out infinite as the only moving element. Under `prefers-reduced-motion: reduce`, the sparkle animation is removed and it sits at fixed opacity .8; the sprinkle scatter is static regardless.

**Host palette:** bg0 `#faf1ee` bg1 `#fffbfa` bg2 `#f5e2e0` bg3 `#efd0ce` border `#e3bcb8` text `#3a2220` muted `#6b4844` accent `#c43d59`

---

## 2. Vaporwave becomes the default again

**Round 19 update — superseded, kept as history, do not delete:** Vaporwave's run as default ends in round 19. Eric asked for a cats-mixed-with-Warcraft theme, made the new default, dark by default, focused on readability. **Arcane Library (`arcane-library`) is now the default theme** — see §7 for the full spec, the round-19 change points (§7.9, which supersede rows 1–5 and 7 below the same way this section's own rows superseded round 11's Lofi-Night default), and the updated 15-theme picker order (§7.8: Arcane Library, then Vaporwave, Lofi Night, Dark, Light, then the ten). Vaporwave remains fully intact as the #2 entry in the picker; nothing in this section's history is invalidated, only superseded as current behavior.

Every place the literal fallback theme currently reads `"lofi"` (flipped from Vaporwave in round 11) must change to `"vaporwave"`. The Vaporwave and Lofi Night token blocks themselves are untouched — this is purely a default/fallback change, per Eric's request.

| # | File | Location | Change |
|---|---|---|---|
| 1 | `ui/index.html` | line 2, `<html data-theme="lofi">` seed attribute | → `data-theme="vaporwave"` |
| 2 | `ui/app.js` | `readTheme()` fallback literal (~line 35) | `"lofi"` → `"vaporwave"` |
| 3 | `ui/app.js` | `applyTheme()` invalid-value fallback literal (~line 42) | `"lofi"` → `"vaporwave"` |
| 4 | `ui/app.js` | `setTheme()` fallback literal (~line 57) | `"lofi"` → `"vaporwave"` |
| 5 | `ui/app.js` | `isKnownTheme(v)` (~line 32) | flat `v === "light" \|\| v === "vaporwave" \|\| v === "dark" \|\| v === "lofi"` → membership check against the full 14-slug `THEMES` array (see §4) |
| 6 | `ui/manifest.json` | `background_color`, `theme_color` | `"#0f1226"` (Lofi's bg-0) → `"#12081f"` (Vaporwave's bg-0) |
| 7 | `host/FurphyHost.cs` | `InitializeDefaultTheme()` (~lines 987-1002) | hardcoded Lofi Night palette + `_themeName = "lofi"` → Vaporwave's 8-color palette (below) + `_themeName = "vaporwave"` |
| 8 | `SPEC.md` | default-theme decision record (~lines 95, 97) | append a new dated entry ("round 12", 2026-09-04): "Vaporwave is the default again (Eric's decision, round 12), superseding round 11's flip to Lofi Night. Round 7's original Vaporwave-default call-out and round 11's Lofi Night call-out both remain below as history, per this file's own established pattern — **do not delete either.**" |
| 9 | `README.md` / `README.txt` | any line naming the default theme | update to Vaporwave, mention Lofi Night, Dark, Light + the 10 new themes are all available via the theme picker in Settings |

**Vaporwave's 8-color host palette** (for #7, verbatim from the existing, unmodified Vaporwave token block): bg0 `#12081f` bg1 `#1a0b2e` bg2 `#241640` bg3 `#2d1b4e` border `#3a2a5c` text `#f3e9ff` muted `#b9a6d6` accent `#ff71ce`.

**Not a bug, don't "fix":** `LoadPersistedTheme()` in `FurphyHost.cs` overlays a returning user's `settings.json` `hostTheme` after the new default is seeded — a user who already has Lofi Night persisted keeps seeing Lofi Night chrome even after the default flips, exactly mirroring the page's own localStorage-first behavior. Do not force-migrate existing `settings.json` files.

---

## 3. The swatch-grid picker

Judge consensus across all 3 panels: **build on Proposal 2's architecture** (it's the only one of the three that identifies and correctly solves the real constraint — a swatch for a theme that isn't currently active on `<html>` cannot read that theme's `--bg-1`/`--accent`/`--text` via `var()`, because those custom properties only exist inside that theme's own `[data-theme="X"]` scope; the fix is a small set of hardcoded preview-only custom properties per theme, attached via a plain attribute selector on the swatch button itself, kept in `style.css` right next to that theme's `:root[data-theme="X"]` block — one source of truth, not a parallel JS color table). Selection ring uses the **live** app's `--accent`/`--bg-1` (not the swatched theme's colors) so it stays visible regardless of which theme is currently active — a real bug in a naive implementation that Proposals 1 and 3 miss.

**But** graft on the interaction fix both Judge 1 and Judge 2 raised against Proposal 2 as submitted: **arrow keys move focus only; the theme is applied only on Enter/Space/click.** Committing the theme (and re-coloring the whole app) on every arrow tap across 14 swatches would be a flicker storm and the opposite of "calm."

### 3.1 Markup (`ui/index.html`, replacing the current `.segmented` block, lines ~501-519)

```html
<div class="theme-grid" id="theme-grid" role="radiogroup" aria-label="Color theme">
  <!-- rendered by app.js from the THEMES array — see §4. One button per theme: -->
  <button type="button" class="theme-swatch" role="radio"
          aria-checked="true" tabindex="0" data-theme-value="vaporwave">
    <span class="theme-swatch-preview" aria-hidden="true">
      <span class="theme-swatch-accent"></span>
      <span class="theme-swatch-text">Aa</span>
      <svg class="theme-swatch-check" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
        <path d="M2 6l3 3 5-6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </span>
    <span class="theme-swatch-name">Vaporwave</span>
  </button>
  <!-- ...14 total, in the order given in §3.4... -->
</div>
```

`data-theme-value` stays on each button so the existing click-wiring pattern (`Utils.qsa(...).forEach(btn => btn.addEventListener("click", ...))`) survives with only a selector change; the `.is-active` class toggle is replaced by `aria-checked` (see §3.3).

### 3.2 CSS (new block, Settings > Appearance, `ui/style.css`)

```css
.theme-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(88px, 1fr));
  gap: 10px;
}
.theme-swatch {
  display: flex; flex-direction: column; align-items: center; gap: 6px;
  padding: 8px 6px; border: 1px solid var(--border); border-radius: var(--radius);
  background: var(--bg-1); cursor: pointer; transition: var(--fast);
}
.theme-swatch:hover { border-color: var(--border-hover); }
.theme-swatch:focus-visible { outline: 2px solid var(--focus-ring); outline-offset: 2px; }
.theme-swatch-preview {
  width: 100%; height: 40px; border-radius: var(--radius-sm);
  background: linear-gradient(135deg, var(--sw-bg) 0 60%, var(--sw-bg2, var(--sw-bg)) 60% 100%);
  border: 1px solid rgba(0,0,0,.18);
  position: relative; overflow: hidden;
}
.theme-swatch-accent {
  position: absolute; left: 6px; bottom: 6px; width: 12px; height: 12px;
  border-radius: 50%; background: var(--sw-accent); box-shadow: 0 0 0 2px var(--sw-bg);
}
.theme-swatch-text {
  position: absolute; right: 7px; top: 5px; font: 700 11px system-ui, sans-serif; color: var(--sw-text);
}
.theme-swatch-check {
  position: absolute; right: 5px; bottom: 5px; color: var(--sw-accent);
  opacity: 0; transition: var(--fast);
}
.theme-swatch-name { font-size: 12px; color: var(--text-muted); text-align: center; }
.theme-swatch[aria-checked="true"] {
  border-color: var(--accent);
  box-shadow: 0 0 0 1px var(--bg-1), 0 0 0 3px var(--accent);
}
.theme-swatch[aria-checked="true"] .theme-swatch-name { color: var(--text); font-weight: 600; }
.theme-swatch[aria-checked="true"] .theme-swatch-check { opacity: 1; }
```

Plus one 4-property rule per theme (14 total — the only per-theme CSS the picker needs), co-located with that theme's `:root[data-theme="X"]` block so a palette update and its swatch preview never drift apart:

```css
.theme-swatch[data-theme-value="vaporwave"]        { --sw-bg:#1a0b2e; --sw-bg2:#12081f; --sw-accent:#ff71ce; --sw-text:#f3e9ff; }
.theme-swatch[data-theme-value="lofi"]              { --sw-bg:#161b34; --sw-bg2:#0f1226; --sw-accent:#ffb86b; --sw-text:#f2eee6; }
.theme-swatch[data-theme-value="dark"]              { --sw-bg:#1c1d21; --sw-bg2:#141518; --sw-accent:#f16436; --sw-text:#e7e7ea; }
.theme-swatch[data-theme-value="light"]             { --sw-bg:#ffffff; --sw-bg2:#f4f5f7; --sw-accent:#d9531f; --sw-text:#1b1c1f; }
.theme-swatch[data-theme-value="terminal-green"]    { --sw-bg:#0a100c; --sw-bg2:#050806; --sw-accent:#39ff88; --sw-text:#5affa0; }
.theme-swatch[data-theme-value="arctic-ice"]        { --sw-bg:#ffffff; --sw-bg2:#eef4f7; --sw-accent:#0c6c8f; --sw-text:#14232c; }
.theme-swatch[data-theme-value="art-deco-gold"]     { --sw-bg:#141416; --sw-bg2:#0c0c0d; --sw-accent:#d4af37; --sw-text:#f2e6c9; }
.theme-swatch[data-theme-value="alpine-dawn"]       { --sw-bg:#161d27; --sw-bg2:#10151c; --sw-accent:#ff8c5a; --sw-text:#eef2f5; }
.theme-swatch[data-theme-value="matcha"]            { --sw-bg:#faf9f0; --sw-bg2:#f1efe1; --sw-accent:#4f7942; --sw-text:#24301f; }
.theme-swatch[data-theme-value="desert-night"]      { --sw-bg:#1a1424; --sw-bg2:#120e1a; --sw-accent:#ffa552; --sw-text:#f3ece0; }
.theme-swatch[data-theme-value="tokyo-rain"]        { --sw-bg:#12151f; --sw-bg2:#0b0d14; --sw-accent:#ff5aa8; --sw-text:#e8ecf5; }
.theme-swatch[data-theme-value="brushed-steel"]     { --sw-bg:#24272c; --sw-bg2:#1b1d21; --sw-accent:#4fa8e0; --sw-text:#e8eaed; }
.theme-swatch[data-theme-value="aurora-sky"]        { --sw-bg:#0d131c; --sw-bg2:#070b12; --sw-accent:#b98cf7; --sw-text:#eef4f2; }
.theme-swatch[data-theme-value="strawberry-cream"]  { --sw-bg:#fffbfa; --sw-bg2:#faf1ee; --sw-accent:#c43d59; --sw-text:#3a2220; }
```

Each preview reads as a 2-tone card (bg-1/bg-0 diagonal split) with an accent dot and a live "Aa" text sample in that theme's own text color — bg/accent/text all visible at a glance, at rest, with no need to switch themes to preview them. `[data-density="compact"]` needs no new rule — it already tightens gap/padding globally.

### 3.3 Keyboard behaviour (ARIA `radiogroup`/`radio`, roving tabindex)

- Only the checked swatch has `tabindex="0"`; every other swatch has `tabindex="-1"` — Tab enters/exits the whole grid in one stop.
- **ArrowRight/ArrowDown** moves focus to the next swatch in DOM order, **ArrowLeft/ArrowUp** to the previous, wrapping at the ends. **Home/End** jump to first/last. Arrow movement **moves focus only** — it does not select or re-theme the app.
- **Enter or Space** on the focused swatch commits the selection: calls `Prefs.setTheme(btn.dataset.themeValue)`, then re-renders — updates `aria-checked`/`tabindex` on all swatches and the visual ring.
- **Click** on any swatch commits immediately (same commit path as Enter/Space).
- Each swatch's `aria-checked` is kept in sync on every commit; the grid carries `role="radiogroup" aria-label="Color theme"`. No separate live region is needed — the checked swatch's own state change is what a screen reader announces.

### 3.4 Ordering and labels

Vaporwave, Lofi Night, Dark, Light, then the ten new themes in tally order:

1. **Vaporwave** (`vaporwave`)
2. **Lofi Night** (`lofi`)
3. **Dark** (`dark`)
4. **Light** (`light`)
5. **Terminal Green** (`terminal-green`)
6. **Arctic Ice** (`arctic-ice`)
7. **Art Deco** (`art-deco-gold`)
8. **Alpine Dawn** (`alpine-dawn`)
9. **Matcha** (`matcha`)
10. **Desert Night** (`desert-night`)
11. **Tokyo Rain** (`tokyo-rain`)
12. **Brushed Steel** (`brushed-steel`)
13. **Aurora Sky** (`aurora-sky`)
14. **Strawberry Cream** (`strawberry-cream`)

At `minmax(88px,1fr)` this wraps to roughly 4-5 swatches per row at the Settings panel's typical width — 3-4 rows for 14 themes, no scrolling drawer, no dropdown, no pagination. Reads as one calm grid.

---

## 4. Theme list as a single source of truth (`ui/app.js`)

Add one array near the top of the Prefs/Views module so **adding theme #15 is a one-entry change**:

```js
const THEMES = [
  { slug: "vaporwave",         name: "Vaporwave" },
  { slug: "lofi",              name: "Lofi Night" },
  { slug: "dark",              name: "Dark" },
  { slug: "light",             name: "Light" },
  { slug: "terminal-green",    name: "Terminal Green" },
  { slug: "arctic-ice",        name: "Arctic Ice" },
  { slug: "art-deco-gold",     name: "Art Deco" },
  { slug: "alpine-dawn",       name: "Alpine Dawn" },
  { slug: "matcha",            name: "Matcha" },
  { slug: "desert-night",      name: "Desert Night" },
  { slug: "tokyo-rain",        name: "Tokyo Rain" },
  { slug: "brushed-steel",     name: "Brushed Steel" },
  { slug: "aurora-sky",        name: "Aurora Sky" },
  { slug: "strawberry-cream",  name: "Strawberry Cream" },
];
const DEFAULT_THEME = "vaporwave";
const isKnownTheme = (v) => THEMES.some(t => t.slug === v);
```

`renderAppearance()` builds the 14 `.theme-swatch` buttons from `THEMES` (order = array order = §3.4), sets `data-theme-value` and label text from each entry, and marks the current one via `aria-checked = (t.slug === Prefs.getTheme())` + roving `tabindex`. The swatch's own preview colors (`--sw-bg`/`--sw-bg2`/`--sw-accent`/`--sw-text`) live in `style.css` (§3.2), keyed by the same `slug` via the attribute selector — JS never needs to know a theme's actual color values, only its slug and label. Adding a theme is: one `THEMES` entry (slug + name), one `:root[data-theme="X"]` CSS block, one `.select` chevron override, one `.theme-swatch[data-theme-value="X"]` preview rule.

---

## 5. Implementation change sets (one agent each)

### Set A — Theme CSS blocks
**Scope:** `ui/style.css` — add the 10 new `:root[data-theme="X"]` blocks (§1) plus their 10 `.select` chevron overrides, plus each theme's signature-touch CSS (art layers, keyframes, reduced-motion gates). Do not touch the existing Dark/Light/Vaporwave/Lofi Night blocks.
**Verification:**
1. Serve `ui/` (`python -m http.server <port>` from `ui/`, ports 47890-47897) and open `?mock=1` in your own browser tab.
2. Run a contrast script against the **live computed styles** (not the spec's hand-math) for all 14 themes: for each `data-theme` value, set it on `<html>`, read `getComputedStyle` for every token pair listed in the Status-Chip Surface Inventory (text/bg-0..3, muted/bg-1..2, faint/bg-1..3, accent-text/accent, each chip color vs its own tint composited over bg-1 and bg-2), compute WCAG contrast, assert ≥4.5:1. Fail the set if any pairing regresses below what §1 reports.
3. Screenshot My Addons (table + chips + progress bar), Get New Addons (cards + embedded toolbar), Settings (toggles + segmented controls), a dialog, and a toast — in each of the 10 new themes. Confirm signature-touch art never overlaps a clickable control and that every animated touch visibly stops under emulated `prefers-reduced-motion: reduce`.
4. Verify `Host.reportTheme()`'s regex (`/^#[0-9a-fA-F]{6}$/`) passes for all 8 relayed tokens (`--bg-0/1/2/3`, `--border`, `--text`, `--text-muted`, `--accent`) on every new theme — all are literal 6-digit hex per §1, but confirm nothing was pasted as `rgba(...)` by mistake.

### Set B — Picker
**Scope:** `ui/index.html` (markup, §3.1), `ui/style.css` (grid/swatch CSS + 14 preview rules, §3.2), `ui/app.js` (`THEMES` array §4, rewritten `renderAppearance()`, click + keyboard wiring §3.3, replacing the old `#theme-toggle` segmented-control code entirely).
**Verification:**
1. Load Settings > Appearance. Confirm 14 swatches render in the §3.4 order, each preview shows a distinct bg/accent/text combination, and the currently active theme's swatch carries the ring + checkmark.
2. Keyboard test: Tab into the grid (single stop), Arrow keys move focus without changing the theme, Home/End jump to first/last, Enter and Space each commit the focused swatch, click commits immediately. Confirm `aria-checked` and roving `tabindex` update correctly after each commit.
3. Screenshot the grid in light and dark host themes, and at both default and compact density.
4. Confirm `Prefs.setTheme()` + `applyTheme()` still fire exactly as before (theme actually changes, `Host.reportTheme()` still posts) — this set changes only the picker's markup/wiring, not the Prefs module's public behavior.

### Set C — Defaults & host
**Scope:** `ui/index.html` (seed `data-theme`), `ui/app.js` (three fallback literals + `isKnownTheme`, §2 rows 2-5), `ui/manifest.json` (§2 row 6), `host/FurphyHost.cs` `InitializeDefaultTheme()` (§2 row 7).
**Verification:**
1. Clear `localStorage` and delete/rename any `settings.json` `hostTheme` key, reload `?mock=1` — page must render Vaporwave (`data-theme="vaporwave"` on `<html>`, all Vaporwave signature art visible) with no flash of another theme.
2. Launch the native host fresh (no persisted `hostTheme`) and confirm the title bar seeds Vaporwave's palette before the page loads.
3. Confirm a profile with an existing `hostTheme: {name:"lofi", ...}` in `settings.json` still shows Lofi Night on both the page and the title bar after the default flips — this is expected, not a regression.
4. Confirm `isKnownTheme` accepts all 14 slugs and rejects anything else (falls back to `"vaporwave"` per the updated fallback literals).

### Set D — Docs
**Scope:** `SPEC.md` (§2 row 8 — new dated decision entry, preserving both prior entries), `README.md`/`README.txt` (§2 row 9).
**Verification:** Diff review only — confirm the round-7 and round-11 history entries are still present verbatim and the new round-12 entry is appended, not inserted in place of them; confirm the README lists all 14 themes and states Vaporwave as current default.

---

## 6. Acceptance checklist

- [ ] All 10 new `:root[data-theme="X"]` blocks present in `ui/style.css`, each defining the complete token contract (every token dark/light/vaporwave/lofi define — see §1 blocks) with no inherited/missing tokens.
- [ ] Every theme sets `color-scheme` explicitly (`dark` or `light`, matching §1).
- [ ] Every theme has its own `.select` chevron override keyed to its own `--text-muted` hex.
- [ ] `--bg-0/1/2/3`, `--border`, `--text`, `--text-muted`, `--accent` are literal 6-digit hex (not `var()`/`rgba()`) on all 10 new themes, so `Host.reportTheme()`'s regex passes for every one.
- [ ] Live-computed contrast script (Set A, verification #2) passes ≥4.5:1 for every pairing in the Status-Chip Surface Inventory, on all 14 themes.
- [ ] Every animated signature touch is wrapped in a `prefers-reduced-motion: reduce` gate and visibly stops when emulated; no signature touch overlaps a clickable control at any viewport width tested.
- [ ] My Addons (table/chips/progress bar), Get New Addons (cards/embedded toolbar), Settings (toggles/segmented controls), a dialog, and a toast all screenshot cleanly (legible, no clipped/overlapping art) in all 10 new themes.
- [ ] Lofi Night's and Vaporwave's existing blocks and signature art are byte-for-byte unchanged.
- [ ] Swatch-grid picker renders all 14 themes in the §3.4 order, each preview visually distinct, current theme ring-marked.
- [ ] Keyboard behavior matches §3.3 exactly (roving tabindex, arrow-moves-focus-only, Enter/Space/click commits).
- [ ] `THEMES` array in `app.js` is the sole source of slug+label ordering; `isKnownTheme` derives from it.
- [ ] Fresh profile (no localStorage, no persisted `hostTheme`) loads Vaporwave on both the page and the native title bar; an existing Lofi Night user's persisted preference is undisturbed.
- [ ] `manifest.json` background/theme colors match Vaporwave's `--bg-0` (`#12081f`).
- [ ] `SPEC.md` carries the new round-12 decision entry with both prior (round 7, round 11) entries intact.
- [ ] README reflects 14 themes and Vaporwave as default.
- [ ] No new theme introduces a network font, external asset, or anything that breaks the app running fully offline.

---

## 7. The default theme: Arcane Library (`arcane-library`)

Round 19. Eric's request, verbatim: *"make a cats theme mixed with warcraft, change the icon for the app to be a cat in this theme, make it the default focus on readability and clarity in the app with it"*, followed by *"make it dark by default"*. Three candidates (Ember Keep, Tavern Hearth, Arcane Library) were designed and scored by 3 judges against this round's brief (readability floors stricter than the standing per-theme contract — see §7.4 — plus a hard reject on any Blizzard/Warcraft IP and a cat-legibility-at-16px requirement on the icon). This is the 15th theme; every one of the 14 existing theme blocks (§1, plus Dark/Light/Vaporwave/Lofi Night) is unchanged.

### 7.0 Selection

| slug | judge 1 | judge 2 | judge 3 | tally (of 150) | trademark issues |
|---|---|---|---|---|---|
| **arcane-library** | 45 | 42 | 41 | **128** | none |
| ember-keep | 43 | 39 | 42 | 124 | none |
| tavern-hearth | 39 | 36 | 38 | 113 | none |

**Winner: Arcane Library** — highest tally, zero trademark issues (tied with the other two on that count, but wins outright on score). All three judges independently recomputed the candidate's self-reported contrast numbers from scratch and found no misreported figures in any of the three submissions; Arcane Library was the only one of the three where every judge's independent recheck also confirmed no pairing sat close to its floor (its tightest value, 5.30 on `text-faint/bg-3`, still beats both other candidates' tightest values — 5.08 for Ember Keep, 5.06 for Tavern Hearth — by a comfortable margin), and the only one where an independent pixel-level render of the icon at 16px (done separately by two of the three judges, not just trusted from the candidate's own writeup) confirmed a clean, unambiguous cat read. Tavern Hearth's icon, by contrast, was independently pixel-dumped by Judge 3 and found to *not* hold up at 16px despite its own rationale's contrary claim — the ear notches wash out to a solid gold blob with a blurred dot, which is why no synthesis step should trust a candidate's self-reported icon legibility without redoing the render (this synthesis step redid it — see §7.7).

### 7.1 Concept

A hushed archive deep beneath the keep: midnight-indigo stone shelves rising into torchlight, gold-leafed tome spines lining the walls in careful rows, motes of arcane blue drifting past a wall sconce. A study cat has claimed a leaning stack of tomes at the reading nook's edge — ears up, one eye left open as a faint blue rune-glow — keeping watch through the small hours. Cool mana-blue accent, warm gold trim, the calmest and highest-contrast reading experience of any theme in the set (per Eric's "focus on readability and clarity"), dark by default.

### 7.2 Grafts applied (post-judging synthesis pass)

All three judge panels converged on Arcane Library as the winner and each proposed grafts from the two runners-up. Applied here, in order of judge consensus:

1. **Tavern Hearth's "propped adventuring gear beside the cat" idea (Judge 1 & Judge 2, independently)** — Judge 2 specifically named "a small dagger or buckler leaning against the tome-stack near the cat" as a low-risk way to raise catWarcraftMood (Arcane Library's one consistently soft score across all three judges, 7/7/7) without touching tokens or the icon. **Applied:** a small flat-color dagger, propped against the left edge of the foreground tome stack, added to the `.arcane-alcove` signature scene (markup in §7.5). It is static (no new motion budget), built from colors already in the palette (`--border-hover` for the blade, `--secondary` for the hilt/pommel — no new hex introduced), and sits at `y ≥ 88`, well clear of the nav list and every other element's established layout.
2. **Ember Keep's flat, two-layer (no-gradient) flame technique (Judge 2)** — flagged as worth grafting "anywhere Arcane Library's own sconce flame might otherwise be tempted to use a gradient." **Verified, not changed:** the existing `.arcane-flame` in the candidate's own markup is already two flat `<rect>` fills (`--warning` outer, `--danger` inner, no gradient) — it already satisfies this graft as submitted. No edit was needed; confirmed by re-reading the markup before append.
3. **Ember Keep's "sidebar cat asleep / brand-mark cat on watch" duality, and Arcane Library's own equivalent (Judge 1 & Judge 3)** — both judges called this out as worth *preserving*, not flattening: Arcane Library's brand cat already uses two open glowing eyes (matching the icon's legibility-first choice) while the larger sidebar cat uses one literal rune eye (taking Eric's "a cat with a glowing rune eye" brief at its word where there's room to). **Applied: left untouched, verbatim** — this is a "don't regress it" graft, not a new addition.
4. **Process discipline (Judge 1)** — keep palette/icon draft files as an audit trail. **Applied:** this synthesis step's independent icon re-render (`al-icon.svg`, `al-icon-out/al-{16,32,256}.png` plus a nearest-neighbor 16x zoom, and `al-contrast.js` for the independent contrast recheck) are kept in the scratch folder alongside this spec's append, following the same audit-trail convention Tavern Hearth's own candidate writeup used.

No graft altered any CSS custom-property value — the token block in §7.3 is byte-for-byte identical to the judged candidate. §7.4 re-verifies contrast anyway, by independent computation, as the synthesis step requires.

### 7.3 Final token block (verbatim)

```css
/* ==========================================================================
   Arcane Library theme - the round-19 default (cats mixed with Warcraft-
   flavored fantasy, dark by default, readability-first per Eric's request).
   Applied via [data-theme="arcane-library"] exactly like every other theme
   block in this file. Direction: midnight indigo stone, mana-blue accent
   with gold trim, a cat perched on a stack of tomes with a glowing rune eye.
   Every token the base :root defines is redefined here (nothing falls
   through), plus:
     --secondary  - the gold trim itself (ear-tips/collar in the signature
       art, focus ring, chip/card gilt hairlines). Deliberately near-identical
       in hue to --warning (contrast 1.05 between them) - both are "the
       gold" in a Warcraft-flavored palette; a warning pill reads as brass,
       not a defect (same non-blocking-note tradition as Art Deco's own gold
       accent/warning proximity).
     --focus-ring - pointed at --secondary rather than --accent, so every
       shared :focus-visible rule draws a gilded ring instead of a blue one -
       "gold trim" made literal on every interactive control.
   Geometry (--radius-sm/--radius/--radius-lg) is overridden to slightly
   tighter, more architectural corners than the shared default - carved
   stone blocks and gilt frames read squarer than a soft glassy dark theme.
   Contrast (independently re-verified twice - once by all 3 judges against
   the candidate's own report, once more by this synthesis step's own
   al-contrast.js after grafting - see §7.4): text/bg-0 17.08, text/bg-1
   16.14, text/bg-2 14.85, text/bg-3 13.37 (floor 7, target 10+ - all
   comfortably clear it); muted/bg-1 8.45, muted/bg-2 7.78 (floor 5); faint/
   bg-1 6.40, faint/bg-2 5.89, faint/bg-3 5.30 (floor 4.5, the tightest
   margin in the theme and still the widest "tightest margin" of the three
   judged candidates); accent-text/accent 8.58 (floor 4.5, "prefer 7"). Chip
   text-on-tint over bg-1/bg-2 (floor 5): success 6.67/6.01, warning 6.96/
   6.27, danger 6.04/5.46, info 7.19/6.48, accent 6.49/5.84. banner-danger-
   text/danger-tint-over-bg-0 11.00, form-error-text/danger-tint-over-bg-1
   8.78, danger-text/danger 7.26. ALL PASS with real margin.
   Host palette (8-color, for Host.reportTheme() and FurphyHost.cs's
   InitializeDefaultTheme()): bg0 #0a0912 bg1 #121022 bg2 #1b1830 bg3
   #242040 border #332c54 text #f4eedd muted #b3a8d6 accent #88afff.
   ========================================================================== */
:root[data-theme="arcane-library"] {
  color-scheme: dark;

  --bg-0: #0a0912;
  --bg-1: #121022;
  --bg-2: #1b1830;
  --bg-3: #242040;
  --border: #332c54;
  --border-soft: #1b1830;
  --border-hover: #453c70;

  --text: #f4eedd;
  --text-muted: #b3a8d6;
  --text-faint: #9992bb;

  --accent: #88afff;
  --accent-hover: #a3c1ff;
  --accent-active: #5f8ef0;
  --accent-text: #071224;

  --success: #5fc17a;
  --warning: #e0a83c;
  --danger: #ff7a7a;
  --info: #4fc3e8;

  --secondary: #d9a441;
  --focus-ring: var(--secondary);

  --success-tint: rgba(95, 193, 122, 0.14);
  --warning-tint: rgba(224, 168, 60, 0.14);
  --danger-tint: rgba(255, 122, 122, 0.14);
  --info-tint: rgba(79, 195, 232, 0.14);
  --accent-tint: rgba(136, 175, 255, 0.16);
  --muted-tint: rgba(179, 168, 214, 0.12);

  --banner-danger-text: #ffc4c4;
  --form-error-text: #ffb0b0;

  --danger-hover: #ff9494;
  --danger-text: #2a0a0a;
  --danger-border: rgba(255, 122, 122, 0.35);
  --danger-outline-border: rgba(255, 122, 122, 0.4);

  --radius-sm: 3px;
  --radius: 6px;
  --radius-lg: 10px;
}

:root[data-theme="arcane-library"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' stroke='%23b3a8d6' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}

/* THEMES-SPEC.md §3.2: this theme's own swatch-preview rule for the picker
   grid, colocated with its token block per that section's rule. */
.theme-swatch[data-theme-value="arcane-library"] { --sw-bg:#121022; --sw-bg2:#0a0912; --sw-accent:#88afff; --sw-text:#f4eedd; }
```

### 7.4 Final contrast table (re-verified by independent computation, post-graft)

Recomputed from scratch with a fresh WCAG relative-luminance + alpha-composite script (`al-contrast.js`, not reused from any candidate's own report) against the token block in §7.3, unchanged after grafting since no graft touched a token value:

| pairing | ratio | floor | verdict |
|---|---|---|---|
| text/bg-0 | 17.08 | 7 | PASS |
| text/bg-1 | 16.14 | 7 | PASS |
| text/bg-2 | 14.85 | 7 | PASS |
| text/bg-3 | 13.37 | 7 | PASS |
| text-muted/bg-1 | 8.45 | 5 | PASS |
| text-muted/bg-2 | 7.78 | 5 | PASS |
| text-faint/bg-1 | 6.40 | 4.5 | PASS |
| text-faint/bg-2 | 5.89 | 4.5 | PASS |
| text-faint/bg-3 | 5.30 | 4.5 | PASS |
| accent-text/accent | 8.58 | 4.5 (prefer 7) | PASS |
| chip-success text/tint over bg-1 | 6.68 | 5 | PASS |
| chip-success text/tint over bg-2 | 6.04 | 5 | PASS |
| chip-warning text/tint over bg-1 | 6.95 | 5 | PASS |
| chip-warning text/tint over bg-2 | 6.27 | 5 | PASS |
| chip-danger text/tint over bg-1 | 6.04 | 5 | PASS |
| chip-danger text/tint over bg-2 | 5.47 | 5 | PASS |
| chip-info text/tint over bg-1 | 7.19 | 5 | PASS |
| chip-info text/tint over bg-2 | 6.48 | 5 | PASS |
| chip-accent text/tint over bg-1 | 6.47 | 5 | PASS |
| chip-accent text/tint over bg-2 | 5.82 | 5 | PASS |
| banner-danger-text / danger-tint-over-bg-0 | 11.00 | 4.5 | PASS |
| form-error-text / danger-tint-over-bg-1 | 8.79 | 4.5 | PASS |
| danger-text/danger | 7.26 | 4.5 | PASS |
| secondary/warning (disclosed near-duplicate hue) | 1.05 | — (intentional, non-blocking) | n/a |

**ALL 23 required pairings PASS**, matching the judged candidate's and all three judges' independently-recomputed numbers to within floating-point rounding (max observed delta ±0.02, from tint-alpha rounding in the two different scripts). This is the widest safety margin of the three round-19 candidates on every metric class in the brief, and clears every floor in this round's stricter brief (body text ≥7:1, muted ≥5:1, faint ≥4.5:1, accent-text ≥4.5:1 prefer 7, chip-over-tint ≥5:1) with room to spare. Status-hue separation: success (nature green, #5fc17a), warning (gold, #e0a83c), danger (health-red, #ff7a7a), info (mana-blue, #4fc3e8), accent (blue-violet, #88afff) — the only one of the three candidates whose accent sits far outside the warm success/warning/danger cluster instead of crowding into it, per Judge 2's independent hue check.

### 7.5 Signature touch — sidebar hero cat (`.arcane-hero-cat`) + backdrop (`.arcane-alcove`)

**Follow-up round update — the sizing/layout in this section is superseded by §7.13, kept here as history, do not delete:** round 20's `.arcane-hero-cat` sizing (`clamp(110px, 22vh, 160px)`, `.arcane-alcove` a separate fixed-140px flex sibling) shipped, passed the single-flavour mock/theme-audit harness, then failed verification against a real multi-flavour install (Eric's own real setup) - the flavour pills + Update All button make `.nav` tall enough that `.arcane-hero`'s real flex-computed box shrinks well below the cat's `22vh`-sized rendering, and since the box clips overflow, the cat's own head got clipped off at the DEFAULT 1056×720 window - reproducing Eric's original "can't see the cats" complaint on a configuration the build's own verification never tested. §7.13 has the root cause, the fix (the cat and alcove both now live inside `.arcane-hero`, sized against ITS OWN real height rather than the viewport), and the brand-cat ear/crown redraw from the same pass. The **concept** (hero cat + ledge + sleeping cat + dagger, alcove as the wider room) is unchanged; only the CSS sizing mechanics below are superseded.

**Verdict on the round-19 scene (superseded here):** shipped, then Eric's reaction on the real app, verbatim: *"CANT ACTUALLY SEE THE CATS OR WHATEVER."* He was right. The round-19 `.arcane-alcove` cat lived inside a fixed 140px strip at the very bottom of the sidebar — comparable in size to Lofi Night's own `.lofi-cityscape` cats, which *do* read fine — but Lofi Night's sidebar has no long stretch of dead space above that strip pulling the eye away first. Arcane Library's `.nav { flex: 1 }` left 500-1000px of unused flex space on a tall/high-DPI window (Eric's real window: 2530×1591 @125% DPI, ≈232 CSS px sidebar) that the old strip's cat never had a chance to fill or draw attention into — on his window it rendered as a short strip of bookshelf bars with a ≈20px pale blob, and the brand mark beside the wordmark was a few pixels. Replaced below by a round-20 hero cat sized to actually fill that space, judged the same way round 19's three candidates were (multi-artist bake-off, judged, then a synthesis pass applying the judge's tweaks).

**Concept:** the freed flex space between the nav and `.sidebar-bottom` becomes a lit pedestal for one large cat — sitting upright, three-step tapered ears, a gold helm nested between them, open filled rune-blue eye squares, whiskers, a cream chest blaze, crossed front paws, a curled tail — anchored on a low stone ledge that carries a faint dashed rune-circle underfoot and a second, smaller cat curled asleep beside a tiny dagger prop. The round-19 bookshelf/torch/motes scene (`.arcane-alcove`) is unchanged and keeps its own slot below the hero, now read as the wider room the ledge sits in rather than the theme's primary cat-bearing scene.

**Technique:** `.nav` gives up its `flex: 1` (scoped to this theme only — every other theme's `.nav` is untouched) and a new `.arcane-hero` flex sibling, sitting between `</nav>` and `.arcane-alcove` in the sidebar markup, takes over that role instead, so it — not empty space — owns whatever room a tall window frees up. Its inline `<svg class="arcane-hero-cat">` (`preserveAspectRatio="xMidYMax meet"`, bottom-anchored, centered rather than stretched full-width so it reads as a spotlit pedestal) is sized via `height: clamp(110px, 22vh, 160px)`: the 110px floor keeps the default ≈1056×720 window from feeling starved, the 160px ceiling keeps a very tall window's cat from growing without bound. Below a ≈460px window height there is no longer room for nav + a 110px cat + `.sidebar-bottom` without collision, so — the same "vanish rather than overlap" contract every other theme's sidebar decoration already follows — the whole hero slot collapses to nothing instead of crowding or clipping the nav, the status dot, or the wordmark. (Round 34, 2026-09-07: this originally said "the CTAs" - the sidebar had two buttons, "Update & Play"/"Launch WoW", at the time this was written; both are gone now, see CHANGELOG.md, and this section's own pixel numbers need the same live re-measurement flagged at the top of section 9.5.) Motion is a tail sway, an eye blink every ≈6s, and a slow glow pulse, every one of it gated behind one `@media (prefers-reduced-motion: reduce)` block.

**CSS** (`ui/style.css`, appended after the §7.3 token block):

```css
:root[data-theme="arcane-library"] .nav { flex: 0 0 auto; }

.arcane-hero { display: none; }
:root[data-theme="arcane-library"] .arcane-hero {
  display: flex;
  flex: 1 1 auto;
  min-height: 0;
  align-items: flex-end;
  justify-content: center;
  overflow: hidden;
  pointer-events: none;
}
:root[data-theme="arcane-library"] .arcane-hero-cat {
  width: 100%;
  height: clamp(110px, 22vh, 160px);
  display: block;
}
@media (max-height: 460px) {
  :root[data-theme="arcane-library"] .arcane-hero { display: none; }
}

@keyframes arcane-hero-tail-sway { 0%, 100% { transform: rotate(-4deg); } 50% { transform: rotate(4deg); } }
.arcane-hero-tail { animation: arcane-hero-tail-sway 4.6s ease-in-out infinite; }

@keyframes arcane-hero-blink { 0%, 92%, 100% { transform: scaleY(1); } 95% { transform: scaleY(0.12); } }
.arcane-hero-eye-l, .arcane-hero-eye-r {
  animation: arcane-hero-blink 6.2s ease-in-out infinite;
  transform-box: fill-box;
  transform-origin: center;
}
.arcane-hero-eye-r { animation-delay: .05s; }

@keyframes arcane-hero-glow-pulse { 0%, 100% { opacity: .5; } 50% { opacity: .8; } }
.arcane-hero-glow { animation: arcane-hero-glow-pulse 3.6s ease-in-out infinite; }

@media (prefers-reduced-motion: reduce) {
  .arcane-hero-tail, .arcane-hero-eye-l, .arcane-hero-eye-r, .arcane-hero-glow {
    animation: none;
  }
}

/* .arcane-alcove itself (the bookshelf/torch/motes backdrop below the hero)
   is unchanged from round 19 - its own flex:0 0 140px rule, and the
   arcane-flame/arcane-mote-1/2/3 keyframes, still stand as documented
   below; only its old study-cat + propped-dagger groups were removed from
   its markup (§ below) since the hero now carries the theme's cat and
   dagger. */
:root[data-theme="arcane-library"] .arcane-alcove {
  display: block;
  flex: 0 0 140px;
  width: 100%;
  height: 140px;
  pointer-events: none;
}

@keyframes arcane-flame-flicker { 0%, 100% { opacity: .85; } 45% { opacity: 1; } 60% { opacity: .55; } }
.arcane-flame { animation: arcane-flame-flicker 2.2s ease-in-out infinite; }

@keyframes arcane-mote-drift {
  0%, 100% { opacity: .4; transform: translateY(0); }
  50% { opacity: .85; transform: translateY(-5px); }
}
.arcane-mote-1 { animation: arcane-mote-drift 5.5s ease-in-out infinite; }
.arcane-mote-2 { animation: arcane-mote-drift 6.5s ease-in-out infinite 1.2s; }
.arcane-mote-3 { animation: arcane-mote-drift 6s ease-in-out infinite 2.4s; }

@media (prefers-reduced-motion: reduce) {
  .arcane-flame, .arcane-mote-1, .arcane-mote-2, .arcane-mote-3 { animation: none; }
}
```

**Markup** (`ui/index.html`, inside `.sidebar`, `.arcane-hero` sits between `</nav>` and `.arcane-alcove`, the same slot the round-19 scene used to open at):

```html
<div class="arcane-hero">
<svg class="arcane-hero-cat" viewBox="0 0 116 158" preserveAspectRatio="xMidYMax meet" shape-rendering="crispEdges" aria-hidden="true" focusable="false">
  <defs>
    <radialGradient id="arcaneHeroGlow" cx="50%" cy="55%" r="55%">
      <stop offset="0%" stop-color="#88afff" stop-opacity="0.55"/>
      <stop offset="65%" stop-color="#88afff" stop-opacity="0.16"/>
      <stop offset="100%" stop-color="#88afff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <ellipse class="arcane-hero-glow" cx="60" cy="96" rx="56" ry="62" fill="url(#arcaneHeroGlow)"/>
  <g fill="#1c1832"><rect x="0" y="140" width="116" height="18"/></g>
  <rect fill="#d9b45a" x="0" y="140" width="116" height="2"/>
  <g fill="#2a2447">
    <rect x="2" y="144" width="9" height="14"/><rect x="13" y="146" width="7" height="12"/>
    <rect x="99" y="145" width="8" height="13"/><rect x="108" y="147" width="7" height="11"/>
  </g>
  <!-- graft: faint dashed rune-circle on the ledge, under/behind the sitting cat -->
  <ellipse class="arcane-hero-runecircle" cx="58" cy="148" rx="46" ry="7" fill="none" stroke="#8fc4ff" stroke-width="1" stroke-dasharray="3 3" opacity="0.35"/>
  <!-- second, smaller cat: curled and asleep on the ledge -->
  <g class="arcane-hero-sleeping-cat" fill="#4d4478">
    <rect x="4" y="150" width="20" height="7"/><rect x="6" y="146" width="14" height="5"/>
    <rect x="7" y="143" width="4" height="4"/><rect x="16" y="143" width="4" height="4"/>
  </g>
  <rect fill="#f4eedd" x="10" y="147" width="1.6" height="1.6"/>
  <!-- graft: small dagger prop lying beside the sleeping cat -->
  <g transform="rotate(3 34 152)">
    <rect x="27" y="150" width="14" height="3" fill="#453c70"/>
    <path d="M41,150 L49,151.5 L41,153 Z" fill="#453c70"/>
    <rect x="24" y="149.5" width="4" height="4" fill="#d9a441"/>
    <circle cx="23" cy="151.5" r="2" fill="#d9a441"/>
  </g>
  <!-- tail: curls from the right hip around to the front paws -->
  <g class="arcane-hero-tail" fill="#a99adf" style="transform-origin:101px 112px;">
    <rect x="94" y="104" width="15" height="16"/><rect x="99" y="119" width="15" height="15"/>
    <rect x="87" y="130" width="17" height="12"/><rect x="68" y="134" width="18" height="10"/>
  </g>
  <rect fill="#f4eedd" x="65" y="136" width="7" height="7"/>
  <!-- body: sitting trapezoid, three stacked bands widening toward the base -->
  <g fill="#c9bdf0">
    <rect x="30" y="80" width="56" height="17"/><rect x="21" y="97" width="74" height="20"/>
    <rect x="11" y="117" width="94" height="24"/>
  </g>
  <g fill="#a99adf">
    <rect x="70" y="80" width="16" height="17"/><rect x="80" y="97" width="15" height="20"/>
    <rect x="90" y="117" width="15" height="24"/>
  </g>
  <rect fill="#f4eedd" x="46" y="82" width="24" height="42"/>
  <g fill="#f4eedd">
    <rect x="43" y="124" width="15" height="15"/><rect x="59" y="124" width="15" height="15"/>
  </g>
  <rect fill="#c9bdf0" x="57" y="124" width="3" height="15"/>
  <!-- head: three-step tapered ears for a clean point -->
  <g fill="#c9bdf0">
    <rect x="33" y="42" width="17" height="8"/><rect x="36" y="35" width="11" height="7"/><rect x="39" y="29" width="5" height="6"/>
    <rect x="66" y="42" width="17" height="8"/><rect x="69" y="35" width="11" height="7"/><rect x="72" y="29" width="5" height="6"/>
    <rect x="26" y="48" width="64" height="30"/>
  </g>
  <rect fill="#a99adf" x="26" y="72" width="64" height="6"/>
  <g fill="#d9b45a"><rect x="37" y="38" width="42" height="11"/><rect x="53" y="31" width="10" height="9"/></g>
  <rect fill="#b8923f" x="37" y="47" width="42" height="3"/>
  <rect fill="#f0d98c" x="56" y="33" width="4" height="4"/>
  <rect fill="#f4eedd" x="44" y="66" width="28" height="12"/>
  <rect class="arcane-hero-eye-l" fill="#88afff" x="39" y="57" width="11" height="11"/>
  <rect class="arcane-hero-eye-r" fill="#88afff" x="66" y="57" width="11" height="11"/>
  <rect fill="#453c70" x="54" y="70" width="8" height="5"/>
  <g fill="#f4eedd" opacity="0.75">
    <rect x="4" y="63" width="20" height="2"/><rect x="2" y="69" width="22" height="2"/>
    <rect x="92" y="63" width="20" height="2"/><rect x="92" y="69" width="22" height="2"/>
  </g>
</svg>
</div>
```

`.arcane-alcove`'s own markup (`ui/index.html`, unchanged wall/sconce/shelves/motes/foreground-tomes from round 19) loses only its old study-cat group and its old propped-dagger `<g>` — both retired in favor of the hero cat and the ledge's own dagger above; nothing else in that scene moved.

Placement/motion discipline: `.arcane-hero` is a `pointer-events:none` flex item that vanishes outright under 460px window height rather than ever overlapping the nav, the CTAs, the status dots, or the wordmark; `.arcane-alcove` keeps its round-19 discipline (cropped to the sidebar's own bottom 140px, `pointer-events:none`). Every animated element across both — hero tail/eyes/glow, alcove flame/three motes — is gated behind `@media (prefers-reduced-motion: reduce)`, leaving a fully static scene when the OS asks for it.

### 7.6 Brand cat (`.arcane-brand-cat`, 27×22, beside the wordmark)

**Follow-up round update — the artwork in this section is superseded by §7.13, kept here as history, do not delete:** the round-20 redraw below shipped, then verification at the true 27×22px render size found the gold crown band (y 3.2-6.4) sitting directly over the ear-taper rects (y 1-5.6), visually capping the ears into a row of castle crenellations rather than two points - it read as a small purple box with a gold stripe, not a cat head. §7.13 has the redraw: ears occupy their own clear band above the head, the gold trim is a slim headband entirely inside the head block, and the two shapes never touch.

**Verdict on the round-19 mark (superseded here):** at 18×14 it held up in isolation but dissolved into a handful of pixels on Eric's real window — part of the same "can't see the cats" complaint. Redrawn at 27×22 (same two-step ear taper and open filled rune-blue eyes as the round-20 hero cat's own head, just smaller) so the ears and eyes read as a cat head at a glance instead of a blur; still absolute-positioned outside the `.brand` flex row (same reasoning as `.lofi-brand-cat`: at the app's 1000px floor there are no spare pixels to give the wordmark), so the size increase cannot push or truncate `.brand-name` — verified in-browser at both 1056×720 and 1400×900 with `brand-name.scrollWidth <= clientWidth` (no ellipsis) at each.

```css
.arcane-brand-cat { display: none; }
:root[data-theme="arcane-library"] .arcane-brand-cat {
  display: block; position: absolute;
  width: 27px; height: 22px; left: 22px; bottom: -2px;
  pointer-events: none;
}
```

```html
<!-- inside .brand, right after <img class="brand-icon">, mirroring .lofi-brand-cat -->
<svg class="arcane-brand-cat" viewBox="0 0 16 13" aria-hidden="true" focusable="false" shape-rendering="crispEdges">
  <g fill="#b3a8d6">
    <rect x="1.5" y="3" width="4" height="2.6"/>
    <rect x="2.6" y="1" width="2" height="2.4"/>
    <rect x="10.5" y="3" width="4" height="2.6"/>
    <rect x="11.4" y="1" width="2" height="2.4"/>
    <rect x="2" y="5" width="12" height="7"/>
  </g>
  <g fill="#d9a441">
    <rect x="4.5" y="3.2" width="7" height="3.2"/>
    <rect x="7" y="1.4" width="2" height="2.2"/>
  </g>
  <rect fill="#8fc4ff" x="4.2" y="7" width="2.4" height="2.4"/>
  <rect fill="#8fc4ff" x="9.4" y="7" width="2.4" height="2.4"/>
</svg>
```

Still no animation on the brand mark — same reasoning as round 19: it sits right next to legible wordmark text, so it stays still. Verified with an isolated 16x-zoom render (viewBox scaled to 256px) that the two-step ears rise clearly clear of the head block before the gold band starts, the way the hero cat's own three-step ears clear its head.

### 7.7 App icon (`ui/icon.svg`) — "Helm Cat"

**Follow-up round update — superseded, kept as history, do not delete:** a later judged icon round picked **`bold-facecrest` v2** over "Helm Cat" — see §7.11 for the winner, the applied tweaks, and the judge's line on why both this icon and the original flat-emoji icon it replaced were weak at 16px. `ui/icon.svg`, `ui/icons/*.png`, `icon.ico`, and `host/bin/icon.ico` all now carry §7.11's markup. Note for the audit trail: a script error in that round's install step briefly wrote "Helm Cat" (this section's SVG) into those same live files before the mistake was caught and corrected to `bold-facecrest` v2 — "Helm Cat" itself was never a build-script bug, only its accidental installation was.

**Verdict on the previous icon (shipped 2026-09-05, superseded here):** a generic flat-emoji cat face — gold ear-tips and a plain collar bar were its only motif, so at 16px (its most common real-world size, the taskbar) it collapsed into a nearly featureless pale-purple blob with no distinct silhouette or personality. Replaced below.

The replacement gives the cat a fantasy identity — an open-face knight's helm — rather than costume-jewelry trim on an otherwise blank head: lavender ears and cheek fur peek out from under a gold forehead band and rounded-rect cheek flaps, a darker-gold crest ridge runs up the center topped by a small red plume, and the open face shows glowing rune-blue eyes with dark vertical slit pupils so the glow reads as an expression (attitude), not a soft dot. 7 flat colors, no gradients, one soft highlight (the helm shine strip), on the same deep-indigo `#121022` badge (rounded-square, holds up on light and dark taskbars).

Iterated twice before judging (curvy cheek-guards/soft ellipse eyes → muddy blobs at 16px in v1; v2 switched to crisp rounded-rect cheek flaps, a straight forehead band, an enlarged head filling more of the badge, and slit pupils), then given one more polish pass applying the judge's four small-size legibility notes:

1. **Ears** — were the one element almost merging into the dark badge at 16px. Lightened (`#b9a6d9` → `#d4bfe8`) and given a thicker dark outline (`stroke="#2a2140" stroke-width="1.6"`) so the silhouette separates from the badge instead of blending into it.
2. **Small top-of-head accent** — the judge's note named a "blue orb pip" that doesn't exist as a literal element in this design (its only top-of-head accent is the crest ridge + plume, both warm-toned, not blue); treated as the same underlying complaint — a small top accent nearly disappearing below 32px — and enlarged that assembly ~30% (`transform="translate(32,20) scale(1.3) translate(-32,-20)"`) around the forehead anchor.
3. **Nose** — the small gold diamond was washing out against the fur at 16px. Enlarged (7×4 → 8×6) and given a more saturated gold (`#caa348` → `#e8b93a`) so it reads as a nose rather than disappearing.
4. **Fur** — nudged one notch warmer toward the theme's lavender family (`#b9a6d9` → `#c2a8d6`, inner-ear shadow `#8f7ab8` → `#987cb5`), since the original read slightly cool/gray next to the parchment-and-gold palette used elsewhere in the app.

```html
<svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg">
  <title>Helm Cat</title>
  <defs>
    <clipPath id="badge"><rect x="0" y="0" width="64" height="64" rx="14" ry="14"/></clipPath>
  </defs>
  <g clip-path="url(#badge)">
    <rect x="0" y="0" width="64" height="64" fill="#121022"/>

    <!-- ears (lightened + thicker outline) -->
    <polygon points="9,28 18,6 29,27" fill="#d4bfe8" stroke="#2a2140" stroke-width="1.6" stroke-linejoin="round"/>
    <polygon points="35,27 46,6 55,28" fill="#d4bfe8" stroke="#2a2140" stroke-width="1.6" stroke-linejoin="round"/>
    <polygon points="15,22 18,11 23,23" fill="#a88cc4"/>
    <polygon points="41,23 46,11 49,22" fill="#a88cc4"/>

    <!-- face (fur warmed one notch toward lavender) -->
    <ellipse cx="32" cy="43" rx="20" ry="18" fill="#c2a8d6"/>

    <!-- helm cheek flaps -->
    <rect x="8" y="27" width="12" height="24" rx="6" fill="#caa348"/>
    <rect x="44" y="27" width="12" height="24" rx="6" fill="#caa348"/>

    <!-- helm forehead band -->
    <rect x="13" y="19" width="38" height="11" rx="5.5" fill="#caa348"/>

    <!-- crest ridge + plume, enlarged ~30% for small-size legibility -->
    <g transform="translate(32,20) scale(1.3) translate(-32,-20)">
      <rect x="28.5" y="6" width="7" height="17" rx="2.5" fill="#9c7a2e"/>
      <path d="M32 7 Q26 -4 40 -2 Q48 0 44 8 Q39 3 34 6 Q33 7 32 7 Z" fill="#b0455a"/>
    </g>

    <!-- eyes: rune-blue glow with slit pupil -->
    <ellipse cx="23.5" cy="43" rx="5.2" ry="6.2" fill="#88afff"/>
    <ellipse cx="40.5" cy="43" rx="5.2" ry="6.2" fill="#88afff"/>
    <rect x="22.3" y="39" width="2.4" height="9" rx="1.2" fill="#121022"/>
    <rect x="39.3" y="39" width="2.4" height="9" rx="1.2" fill="#121022"/>

    <!-- nose (enlarged + more saturated gold) -->
    <polygon points="32,51 28,57 36,57" fill="#e8b93a"/>

    <!-- helm shine -->
    <rect x="16" y="21" width="32" height="3" rx="1.5" fill="#ffffff" fill-opacity="0.2"/>
  </g>
</svg>
```

**Rendering notes:** rendered through the project's own `make-icon.ps1` (headless Edge) to fresh 16px, 32px, and 256px PNGs, then the 16px and 32px PNGs were upscaled with nearest-neighbor interpolation and read back pixel-by-pixel, both before and after the four polish tweaks above:

- **16px:** reads clearly as a helmed cat head — the gold forehead band and cheek flaps frame two crisp glowing rune-blue slit-pupil eyes; after the tweaks the lightened, outlined ears now separate cleanly from the dark badge instead of nearly merging into it, and the enlarged, more saturated gold nose is a visible dot rather than washing out against the fur.
- **32px:** same composition one step crisper — the ear outline and the larger red plume/crest assembly at the crown are both unambiguous at this size, with no muddying between adjacent fills.
- **256px:** trivially clean — confirms the icon holds one consistent silhouette across the full `make-icon.ps1` render range (16..512), with the warmed fur tone reading as intentional rather than washed out against the parchment-and-gold palette used elsewhere in the app.

### 7.8 Picker order (15 themes)

New theme first, then Vaporwave, Lofi Night, Dark, Light, then the existing ten in tally order (§1) — unchanged from each other, only prepended:

1. **Arcane Library** (`arcane-library`) — new default
2. Vaporwave (`vaporwave`)
3. Lofi Night (`lofi`)
4. Dark (`dark`)
5. Light (`light`)
6. Terminal Green (`terminal-green`)
7. Arctic Ice (`arctic-ice`)
8. Art Deco (`art-deco-gold`)
9. Alpine Dawn (`alpine-dawn`)
10. Matcha (`matcha`)
11. Desert Night (`desert-night`)
12. Tokyo Rain (`tokyo-rain`)
13. Brushed Steel (`brushed-steel`)
14. Aurora Sky (`aurora-sky`)
15. Strawberry Cream (`strawberry-cream`)

```js
const THEMES = [
  { slug: "arcane-library",    name: "Arcane Library" },
  { slug: "vaporwave",         name: "Vaporwave" },
  { slug: "lofi",              name: "Lofi Night" },
  { slug: "dark",              name: "Dark" },
  { slug: "light",             name: "Light" },
  { slug: "terminal-green",    name: "Terminal Green" },
  { slug: "arctic-ice",        name: "Arctic Ice" },
  { slug: "art-deco-gold",     name: "Art Deco" },
  { slug: "alpine-dawn",       name: "Alpine Dawn" },
  { slug: "matcha",            name: "Matcha" },
  { slug: "desert-night",      name: "Desert Night" },
  { slug: "tokyo-rain",        name: "Tokyo Rain" },
  { slug: "brushed-steel",     name: "Brushed Steel" },
  { slug: "aurora-sky",        name: "Aurora Sky" },
  { slug: "strawberry-cream",  name: "Strawberry Cream" },
];
const DEFAULT_THEME = "arcane-library";
```

At `minmax(88px,1fr)` (§3.2) 15 swatches still wraps cleanly with no scrolling drawer, dropdown, or pagination — one calm grid, one more row than the 14-theme layout.

### 7.9 Default change points

Mirrors §2's table format; these rows supersede §2's rows 1–5 and 7 (Vaporwave-as-default) the same way §2's rows themselves superseded round 11's Lofi-Night-as-default — history preserved, not deleted, per the standing pattern in this file and in `SPEC.md`.

| # | File | Location | Change |
|---|---|---|---|
| 1 | `ui/index.html` | line 2, `<html data-theme="vaporwave">` seed attribute | → `data-theme="arcane-library"` |
| 2 | `ui/index.html` | inside `.brand`, right after `<img class="brand-icon">` (the `.lofi-brand-cat` slot) | add `.arcane-brand-cat` markup verbatim (§7.6) |
| 3 | `ui/index.html` | inside `.sidebar`, after `<nav id="nav">`, before `.sidebar-bottom` (the `.lofi-cityscape` slot) | add `.arcane-alcove` markup verbatim, including the grafted dagger prop (§7.5) |
| 4 | `ui/app.js` | `THEMES` array (~line 27) | prepend `{ slug: "arcane-library", name: "Arcane Library" }` as the first entry (§7.8) |
| 5 | `ui/app.js` | `DEFAULT_THEME` (~line 43) | `"vaporwave"` → `"arcane-library"` |
| 6 | `ui/app.js` | `isKnownTheme(v)` | no logic change — it already derives from `THEMES` (§2 row 5's fix); it now accepts 15 slugs automatically once row 4 lands |
| 7 | `ui/style.css` | new block | add the §7.3 token block, `.select` chevron override, and swatch-preview rule; add the §7.5 signature-touch CSS (base-control accents, keyframes, reduced-motion gate) and the §7.6 brand-cat CSS |
| 8 | `ui/manifest.json` | `background_color`, `theme_color` | `"#12081f"` (Vaporwave's bg-0) → `"#0a0912"` (Arcane Library's bg-0) |
| 9 | `ui/icon.svg` | whole file | replaced with §7.7's markup verbatim — the sidebar `<img class="brand-icon">` source, the favicon, and `make-icon.ps1`'s input |
| 10 | `ui/icons/furphy-<size>.png` (16..512), `icon.ico` | regenerated | run `make-icon.ps1 -Svg ui/icon.svg -OutDir <dir> -Name furphy` per the icon pipeline note; copy the resulting `icon.ico` to the live folder root and `host/bin/icon.ico` **only on a real deploy** — this synthesis step does not deploy (hard rule) |
| 11 | `host/FurphyHost.cs` | `InitializeDefaultTheme()` (~lines 1235-1245) | Vaporwave's 8-color palette + `_themeName = "vaporwave"` → Arcane Library's 8-color palette (§7.3's comment block) + `_themeName = "arcane-library"`; rebuild via `host/build-host.ps1` |
| 12 | `SPEC.md` | default-theme decision record | append a new dated round-19 entry: "Arcane Library (cats mixed with Warcraft-flavored fantasy, Eric's decision, round 19) is the default, superseding round 12's Vaporwave-default call-out. Rounds 7, 11, and 12's entries remain below as history, per this file's established pattern — do not delete any." |
| 13 | `README.md` / `README.txt` | default-theme line, theme count | update to 15 themes; state Arcane Library as the current default; Vaporwave, Lofi Night, Dark, Light, and the ten remain listed as available via the picker |
| 14 | `tests/spa/harness.js` | asserted default-theme slug | `"vaporwave"` → `"arcane-library"` |
| 15 | `tests/spa/harness.js` | asserted picker order array | 14-entry order → the 15-entry order in §7.8 |
| 16 | `tests/Run-ThemeAudit.ps1` (or equivalent audit driver) | iterated theme list / count | 14 → 15; add `arcane-library` with the §7.4 contrast floors so the audit does not skip the new default |

**Arcane Library's 8-color host palette** (for row 11, verbatim from §7.3): bg0 `#0a0912` bg1 `#121022` bg2 `#1b1830` bg3 `#242040` border `#332c54` text `#f4eedd` muted `#b3a8d6` accent `#88afff`.

### 7.10 Acceptance checklist

- [ ] `:root[data-theme="arcane-library"]` block present in `ui/style.css`, byte-identical to §7.3, defining the complete token contract with no inherited/missing tokens.
- [ ] `color-scheme: dark` set explicitly.
- [ ] `.select` chevron override present, keyed to `#b3a8d6` (`--text-muted`).
- [ ] `--bg-0/1/2/3`, `--border`, `--text`, `--text-muted`, `--accent` are literal 6-digit hex (not `var()`/`rgba()`), so `Host.reportTheme()`'s regex passes.
- [ ] Live-computed contrast script (per §5 Set A's methodology, extended to this round's stricter floors) passes every pairing in §7.4 on `arcane-library`, and all 14 existing themes still pass unchanged.
- [ ] Every animated signature touch (`arcane-flame`, `arcane-rune-eye`, `arcane-cat-tail`, three `arcane-mote-*`) is wrapped in the `prefers-reduced-motion: reduce` gate and visibly stops when emulated.
- [ ] `.arcane-alcove` and `.arcane-brand-cat` never overlap a clickable control at any viewport width tested; the grafted dagger prop sits within the scene's existing bounds with no new overflow.
- [ ] My Addons (table/chips/progress bar), Get New Addons (cards/embedded toolbar), Settings (toggles/segmented controls, including the 15-swatch picker grid), a dialog, and a toast all screenshot cleanly in `arcane-library`.
- [ ] `ui/icon.svg` replaced with §7.7's markup; `ui/icons/furphy-*.png` and `icon.ico` regenerated via `make-icon.ps1` and verified legible at 16px by an actual pixel-level render (not eyeballed) — do not trust a candidate's or a prior pass's own legibility claim without redoing this.
- [ ] Every one of the 14 existing theme blocks (§1 plus Dark/Light/Vaporwave/Lofi Night) is byte-for-byte unchanged.
- [ ] Swatch-grid picker renders all 15 themes in the §7.8 order, Arcane Library first and ring-marked by default on a fresh profile.
- [ ] `THEMES` array in `app.js` is the sole source of slug+label ordering; `isKnownTheme` and `DEFAULT_THEME` derive from/agree with it.
- [ ] Fresh profile (no `localStorage`, no persisted `hostTheme`) loads Arcane Library on both the page and the native title bar; an existing user's persisted theme preference (Vaporwave, Lofi Night, or any other) is undisturbed, per §2's "not a bug" note.
- [ ] `manifest.json` background/theme colors match Arcane Library's `--bg-0` (`#0a0912`).
- [ ] `SPEC.md` carries the new round-19 decision entry with rounds 7, 11, and 12's entries intact.
- [ ] README reflects 15 themes and Arcane Library as default.
- [ ] `tests/spa/harness.js`'s default-theme assertion and picker-order assertion are updated to match §7.8, not weakened or skipped.
- [ ] `tests/Run-ThemeAudit.ps1` (or equivalent) audits all 15 themes, including `arcane-library`'s own contrast floors from §7.4.
- [ ] No trademarked name (Warcraft, Azeroth, Horde, Alliance, Hearthstone, Blizzard, or any class/race name) appears anywhere in the theme's name, code comments, or user-facing copy; no Blizzard emblem or logo shape is reproduced.
- [ ] No new theme introduces a network font, external asset, or anything that breaks the app running fully offline.

### 7.11 App icon (`ui/icon.svg`) — "Bold Facecrest" v3 (supersedes "Helm Cat"; supersedes and reverts an overshot v2-tweak round)

A follow-up judged icon round ran three `bold-facecrest`-family iterations (plus sibling `bold-curl`, `rogue-hood`, and `rogue-mage` candidates, kept in `shots/icons/` as the audit trail per §7.2 point 4's process-discipline precedent) against the round-19 16px-legibility bar. **`bold-facecrest` v2 won** — a plainer lavender-grey cat face filling a dark rounded-square badge with a gold ring, rather than a costume motif: two huge rune-blue eyes with white glints and slit pupils, a small gold diamond nose, a gold collar arc with a rune gem, a subtle forehead diamond mark, and one notched ear. v2 already passed the 16px cat test as originally drawn.

**Installation note (script error, not a judging outcome):** an earlier install step briefly wrote the wrong candidate — "Helm Cat" (§7.7) — into `ui/icon.svg`, `ui/icons/*.png`, `icon.ico`, and `host/bin/icon.ico`. That was caught before shipping and corrected to `bold-facecrest` v2. "Helm Cat" itself remains a valid, previously-shipped icon design (§7.7, kept as history) — only its installation here was a mistake.

**An intervening tweak round overshot and was reverted.** A pass after v2 tried to punch up the ears and forehead mark: it redrew the ears as light outlined triangles pasted on *top* of the head (instead of v2's clean two-path layering integrated behind/within the head silhouette) and enlarged the forehead mark into a blue ball. At 256px this read as shards glued onto the face rather than ears, and the judge's silhouette check failed it against v2. That ear/orb rework has been fully reverted — v3 restores v2's original ear paths and forehead-diamond mark byte-for-byte, z-order included. Only the two changes below (both already validated as improvements, independent of the ear mistake) were kept and carried onto the v2 base:

1. **Nose.** The gold diamond was enlarged ~25% (roughly 8×7 → 10×9 units: `M32 43.5 L36 47.5 L32 50.5 L28 47.5 Z` → `M32 42.5 L37 47.5 L32 51.5 L27 47.5 Z`) and given a more saturated gold (`#d9b45a` → `#e8b93a`).
2. **Fur.** Nudged one notch warmer toward the theme's lavender (`#7a6b95` → `#8878a3`, roughly a fifth of the way to `#c2a8d6`), applied to the head fill, ear fill, and cheek fluff — every fill that shared the old tone. Eye contrast (`#88afff` glow on `#0a0912` pupil, `#f4eedd` glints) is untouched and stays the dominant read at every size.

The optional third tweak offered alongside these two — lightening the ear fill a little further, independent of the fur-wide warm — was evaluated at 16px and **not applied**: v3's ears already read exactly as legibly as v2's original (same shapes, same relative fill/outline contrast, only the shared fur tone shifted), so an extra ear-only lighten would have been change for its own sake rather than a fix for a real 16px problem.

```html
<svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg">
  <!-- badge -->
  <rect x="1" y="1" width="62" height="62" rx="15" fill="#121022"/>
  <rect x="1.5" y="1.5" width="61" height="61" rx="14.5" fill="none" stroke="#d9b45a" stroke-width="1.6" opacity="0.6"/>

  <!-- ears (thick outline) -->
  <!-- left ear: normal point -->
  <path d="M13 25 L8 5 L28 18 Z" fill="#241a33"/>
  <path d="M15 22 L11.5 9 L24 18 Z" fill="#8878a3"/>

  <!-- right ear: notched/torn -->
  <path d="M51 25 L60 7 L46 16 L53 13 L45 19 Z" fill="#241a33"/>
  <path d="M49 22 L56 10 L46.5 16.5 L51 14.5 L44.5 20 Z" fill="#8878a3"/>

  <!-- head, thick outline, filling badge -->
  <path d="M32 9
           C17 9 8 20 8 33.5
           C8 47.5 18.5 57 32 57
           C45.5 57 56 47.5 56 33.5
           C56 20 47 9 32 9 Z"
        fill="#241a33"/>
  <path d="M32 12.5
           C19.5 12.5 11.5 22 11.5 33.5
           C11.5 45.5 20.5 53.5 32 53.5
           C43.5 53.5 52.5 45.5 52.5 33.5
           C52.5 22 44.5 12.5 32 12.5 Z"
        fill="#8878a3"/>

  <!-- cheek fluff -->
  <path d="M9 34 C4.5 35.5 3 40.5 5.5 46 C9 43.5 12.5 40 13.5 35.5 Z" fill="#241a33"/>
  <path d="M10.5 34.5 C7.5 36 6.5 39.5 8 42.5 C10.5 40.5 12.5 38 13 35.5 Z" fill="#8878a3"/>
  <path d="M55 34 C59.5 35.5 61 40.5 58.5 46 C55 43.5 51.5 40 50.5 35.5 Z" fill="#241a33"/>
  <path d="M53.5 34.5 C56.5 36 57.5 39.5 56 42.5 C53.5 40.5 51.5 38 51 35.5 Z" fill="#8878a3"/>

  <!-- forehead rune-scar mark -->
  <path d="M29.6 15.5 L34.4 15.5 L32.7 24.5 L31.3 24.5 Z" fill="#4a3d63"/>

  <!-- eyes: huge, glowing rune-blue -->
  <ellipse cx="22" cy="33" rx="9.4" ry="10.4" fill="#0a0912"/>
  <ellipse cx="42" cy="33" rx="9.4" ry="10.4" fill="#0a0912"/>
  <ellipse cx="22" cy="33.5" rx="7.6" ry="8.6" fill="#88afff"/>
  <ellipse cx="42" cy="33.5" rx="7.6" ry="8.6" fill="#88afff"/>
  <path d="M22 26 C19.8 29.3 19.8 38 22 41.3 C24.2 38 24.2 29.3 22 26 Z" fill="#12101c"/>
  <path d="M42 26 C39.8 29.3 39.8 38 42 41.3 C44.2 38 44.2 29.3 42 26 Z" fill="#12101c"/>
  <circle cx="18.8" cy="29.6" r="2.1" fill="#f4eedd"/>
  <circle cx="38.8" cy="29.6" r="2.1" fill="#f4eedd"/>

  <!-- nose + muzzle (enlarged ~25% + more saturated gold) -->
  <path d="M32 42.5 L37 47.5 L32 51.5 L27 47.5 Z" fill="#e8b93a"/>
  <path d="M32 50.5 C29 52.2 26 52.2 24 51" stroke="#241a33" stroke-width="2" fill="none" stroke-linecap="round"/>
  <path d="M32 50.5 C35 52.2 38 52.2 40 51" stroke="#241a33" stroke-width="2" fill="none" stroke-linecap="round"/>

  <!-- gold collar with rune gem -->
  <path d="M11 50 C18 57 46 57 53 50 L53 54.5 C46 60 18 60 11 54.5 Z" fill="#d9b45a"/>
  <path d="M28.5 53.5 L32 50 L35.5 53.5 L32 57 Z" fill="#88afff"/>
  <path d="M28.5 53.5 L32 50 L35.5 53.5 L32 57 Z" fill="none" stroke="#f4eedd" stroke-width="0.8" opacity="0.7"/>
</svg>
```

**Rendering/verification notes for this v3 pass**, one iteration through `make-icon.ps1` (headless Edge) against `shots/icons/facecrest-v3/`, `-Name furphy`:

- **16px** (`furphy-16.png`, confirmed via a 12x nearest-neighbour upscale `furphy-16-up.png`): both eyes and white glints are unambiguous; the forehead diamond survives as a small dark mark rather than washing out; the ears show at each top corner exactly as they did in v2 — a soft integrated patch rather than a crisp point, the same realistic ceiling for a feature this small at 16px, with no shard/paste-on artifact from the reverted ear rework. The gold nose is a touch more visible than v2's at this size, which is the intended effect of the saturation bump.
- **32px** (`furphy-32.png`): both ears read as pointed shapes, the forehead diamond and gold nose are both clean and separated, fur reads visibly warmer/lighter than v2's cooler grey-purple without muddying any edge.
- **256px** (`furphy-256.png`) vs. `shots/icons/bold-facecrest/v2-256.png`: pixel diff bbox is `(29,36)-(227,214)` — entirely inside the head/nose region, confirming the ear/corner silhouette is untouched from v2. The only visible differences are the warmer lavender fur and the larger, more saturated gold nose; ear shapes, positions, z-order, eyes, forehead mark, and collar are identical to v2.

**Change points (mirrors §7.9's table format):**

| # | File | Location | Change |
|---|---|---|---|
| 1 | `ui/icon.svg` | whole file | replaced with this section's markup verbatim (previously held the overshot ear/orb-rework tweak, itself built on `bold-facecrest` v2) |
| 2 | `ui/icons/furphy-<size>.png` (16, 24, 32, 48, 64, 128, 192, 256, 512) | regenerated | via `make-icon.ps1 -Svg ui/icon.svg -OutDir <dir> -Name furphy`, copied over the overshot-round PNGs |
| 3 | `icon.ico`, `host/bin/icon.ico` | regenerated | same `make-icon.ps1` output's `.ico`; both copies verified byte-identical (`sha256`) and containing 7 `ICONDIR` entries |
| 4 | `ui/index.html`, `ui/manifest.json` | favicon links / manifest icon paths | unchanged — both already pointed at `icon.svg` / `icons/furphy-{32,192,512}.png`, so no edit was needed, only the files at those paths |

### 7.12 Acceptance checklist (icon round follow-up)

- [ ] `ui/icon.svg` is byte-for-byte this section's markup (v3: v2's ears/forehead mark + the nose and fur tweaks only — not the reverted ear/orb rework, and not "Helm Cat," §7.7).
- [ ] `ui/icons/furphy-{16,24,32,48,64,128,192,256,512}.png`, `icon.ico`, and `host/bin/icon.ico` all regenerated from that SVG via `make-icon.ps1`; `icon.ico` and `host/bin/icon.ico` are byte-identical (`sha256`) and each contains 7 `ICONDIR` entries.
- [ ] 16px, 32px, and 256px renders re-checked by an actual pixel-level render (not eyeballed or trusted from a prior pass) — ears match v2's silhouette exactly, nose and fur read as the only intentional differences from v2, no size loses the silhouette.
- [ ] `ui/index.html`'s favicon links (`icon.svg`, `icons/furphy-32.png`, `icons/furphy-192.png`) and `ui/manifest.json`'s icon entries (`icons/furphy-192.png`, `icons/furphy-512.png`) still resolve to real files — neither file was edited, only the assets they already pointed at.
- [ ] No live install under `C:\Program Files (x86)` or the running tray process was touched; this pass did not deploy or commit.

## 7.13 Round-21 verification fix — hero-cat clipping, dead sidebar space, and the brand-cat crown

**Eric's reaction, verbatim, to the round-20 hero cat:** *"CANT ACTUALLY SEE THE CATS OR WHATEVER."* Verification against a real native window (`FurphyHost.exe`, `PrintWindow`/`PW_RENDERFULLCONTENT=2` capture) reproduced the complaint at the DEFAULT 1056×720 window on a real 3-flavour install (retail + classic + classic_era pills, matching Eric's own real setup) - a configuration the round-20 build's own verification never exercised, since its only test fixture was single-flavour.

**Root cause:** `.arcane-hero-cat`'s height was `clamp(110px, 22vh, 160px)` - sized off the *viewport*, not off `.arcane-hero`'s own real, flex-computed box. On a real multi-flavour machine the flavour-switcher pills + Update All button make `.nav` render far taller than the single-flavour fixture (measured: 213px vs. a short single-flavour nav), squeezing `.arcane-hero`'s real flex slot down to ~63px of the ~681px real content-viewport height while the SVG still rendered at its `22vh` size (~150px) - and since `.arcane-hero` clips its overflow, the SVG's own head/face content landed outside the shrunk box and was clipped away, leaving only a fragment of the cat visible. Separately, at Eric's large window (2024×1273 CSS px) the cat stayed capped at the clamp's fixed 160px ceiling while `.arcane-hero`'s real flex box was 753px tall, leaving ~590px of dead, unused sidebar space above it - contrary to the "use the large empty sidebar space for a hero cat" direction. A third, unrelated finding: at true 27×22px scale the brand-cat's gold crown band overlapped its own ear-taper rects, reading as a small crenellated box rather than a cat head.

**Fix - hero cat + alcove backdrop (`ui/index.html`, `ui/style.css`):** `.arcane-alcove` (the torchlit bookshelf scene) moved from being a *separate* flex sibling with its own fixed `flex: 0 0 140px` slot to living *inside* `.arcane-hero`, absolutely positioned (`inset: 0; width: 100%; height: 100%`) so it always exactly fills `.arcane-hero`'s real box at any window height, with nothing left over to clip - and frees the 140px it used to reserve for itself back to the hero's own flex:1 slot. `.arcane-hero-cat` moved from being sized by flex/`align-items` to being absolutely positioned (`left/right/bottom: 0`) inside `.arcane-hero` (now `position: relative; overflow: hidden`) and sized with `height: clamp(110px, 100%, 280px)` - a **percentage of `.arcane-hero`'s own real height** (resolvable because an absolutely-positioned element's percentage height resolves against its positioned containing block's real size) instead of `vh`. The box and its content can now never disagree about how tall the box is, so nothing clips, ever - verified by DOM measurement (`.arcane-hero-cat`'s rect always falls entirely within `.arcane-hero`'s rect, at every window size tested) and by re-running the exact 3-flavour, 1056×720 scenario that failed: the freed 140px plus the percentage-based sizing puts the real available height comfortably above the 110px floor, so the cat renders whole. The clamp's ceiling rises from 160px to 280px (≈`.arcane-hero`'s own 207px content width × the artwork's 116:158 aspect ratio - the real point past which the cat can't get taller without also getting wider than the sidebar), so a genuinely tall window like Eric's now renders a visibly bigger cat, with `.arcane-alcove`'s bookshelf (not blank space) filling whatever room is left above it - literally using the freed space rather than stopping short of it.

```css
:root[data-theme="arcane-library"] .arcane-hero {
  display: block;
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  pointer-events: none;
}
:root[data-theme="arcane-library"] .arcane-alcove {
  display: block;
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  pointer-events: none;
}
:root[data-theme="arcane-library"] .arcane-hero-cat {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  width: 100%;
  height: clamp(110px, 100%, 280px);
  display: block;
}
```

`ui/index.html`: `.arcane-alcove`'s `<svg>` markup (unchanged internally - wall gradient, stone blocks, sconce/flame, two shelves of tomes, drifting motes, foreground tome stack) now sits as the *first* child of `<div class="arcane-hero">`, immediately before `.arcane-hero-cat`'s own `<svg>`, instead of as a separate element after `.arcane-hero`'s closing `</div>`. Nothing inside either `<svg>`'s own markup changed - the fix is entirely in how the two elements are sized and nested, not in the artwork itself. The `@media (max-height: 460px)` vanish rule on `.arcane-hero` is untouched and still the hard backstop for genuinely short windows.

**Fix - brand cat (`ui/index.html`):** redrawn so the ears occupy their own clear band (two-step taper, y 0-5) entirely above the head block, and the gold trim is a slim headband sitting fully inside the head (y 5.6-7.6, a clear 0.6 gap below where the ears end) - the two shapes never touch at any pixel, so the ears always read as ears regardless of the gold trim:

```html
<svg class="arcane-brand-cat" viewBox="0 0 16 13" aria-hidden="true" focusable="false" shape-rendering="crispEdges">
  <g fill="#b3a8d6">
    <rect x="2" y="1.4" width="3.4" height="3.6"/>
    <rect x="2.8" y="0" width="1.8" height="2"/>
    <rect x="10.6" y="1.4" width="3.4" height="3.6"/>
    <rect x="11.4" y="0" width="1.8" height="2"/>
    <rect x="2" y="5" width="12" height="8"/>
  </g>
  <rect fill="#d9a441" x="3.5" y="5.6" width="9" height="2"/>
  <rect fill="#8fc4ff" x="4.3" y="8.4" width="2.4" height="2.4"/>
  <rect fill="#8fc4ff" x="9.3" y="8.4" width="2.4" height="2.4"/>
</svg>
```

The CSS box (`.arcane-brand-cat`: `27px × 22px`, absolute, `left: 22px; bottom: -2px`, outside the `.brand` flex row) is unchanged from §7.6 - only the internal artwork moved.

**Verification performed this pass:**
- `node --check ui/app.js` - untouched file, syntax OK.
- `tests\run-all.ps1 -Quick` - static/unit/integration/spa layers all green (the one `host` layer failure, a tray-click-outcome assertion in `Host.Tests.ps1` unrelated to any file this pass touched, is a pre-existing environment-dependent result, not a regression from this change).
- `tests\spa\Run-ThemeAudit.ps1` - **469/469 passed**, all 15 themes including `arcane-library`'s own contrast/token checks and its screenshot.
- DOM measurement (via a `python -m http.server` static serve of `ui/` and the app's own `?mock=1&flavours=N` fixture, browser tab, own tab/port per the task's browser-isolation rule) at the default 1056×720 window with `?flavours=3` (the exact failing scenario): `.arcane-hero-cat`'s rect now falls entirely inside `.arcane-hero`'s rect (no clipping), and at 2024×1273 (Eric's window, CSS px) the cat renders at the new 280px ceiling with `.arcane-alcove` filling the full ~811px box behind it (no dead space). Screenshots at both sizes and of the isolated brand-cat SVG (at 8x and true-scale renders) confirm a cat recognizable at a glance in both cases, and a brand-cat head with ears and eyes clearly distinct from the crown.
- Short-window vanish rule (`max-height: 460px`) re-checked - still hides `.arcane-hero` outright, unaffected by this pass.

### 7.14 Acceptance checklist (round-21 verification fix)

- [ ] `.arcane-alcove` is a child of `.arcane-hero` in `ui/index.html` (not a separate flex sibling after it), absolutely positioned to fill `.arcane-hero` at `width/height: 100%`.
- [ ] `.arcane-hero-cat` is absolutely positioned inside `.arcane-hero`, sized `height: clamp(110px, 100%, 280px)` (a percentage of `.arcane-hero`'s own height, not `vh`).
- [ ] `.arcane-hero` is `position: relative; overflow: hidden` so nothing inside it can ever bleed into `.nav` above or `.sidebar-bottom` below.
- [ ] At the default 1056×720 window with a real 2-3 flavour fixture (`?mock=1&flavours=3` or a real multi-flavour `fixtures/wowroot`), `.arcane-hero-cat`'s rendered rect falls entirely within `.arcane-hero`'s rect - no clipping, whole cat visible.
- [ ] At a large window (Eric's ≈2024×1273 CSS px), the cat renders near the 280px ceiling and `.arcane-alcove` fills the remaining freed space - no large blank gap above the cat.
- [ ] The brand-cat's ears (y 0-5) and gold headband (y 5.6-7.6) never overlap at any pixel; a true-scale (27×22) or zoomed render reads as a cat head with distinct ears and eyes, not a crenellated box.
- [ ] `node --check ui/app.js` passes (file untouched by this fix).
- [ ] `tests\run-all.ps1 -Quick` and `tests\spa\Run-ThemeAudit.ps1` both run clean for every one of the 15 themes (any pre-existing, unrelated failure outside `ui/index.html`/`ui/style.css` is called out explicitly, not silently ignored).
- [ ] No token (`--bg-*`, `--text*`, `--accent*`, etc.) changed; no file outside `ui/index.html`, `ui/style.css`, and this spec was edited; nothing was deployed, committed, or touched under `C:\Program Files (x86)`.

## 7.15 Round-22 verification fix — the clamp's own floor was still overflowing the box

Re-verification against a **real** 3-flavour install (retail + classic + classic_era pills, an Update All button, and real tracked CurseForge addons - the same shape of setup as Eric's own, not the round-21 pass's own single-flavour `Run-ThemeAudit.ps1` screenshot fixture) at the project's established default window reproduced the clipped-cat complaint again, byte-for-byte: `.arcane-hero`'s real flex-computed height was **76px**, but `.arcane-hero-cat` still rendered at **110px** and had its top 34px (ears, crown, head) clipped off by `.arcane-hero`'s own `overflow: hidden`. Independently reproduced with no native app or DPI involved: a static `ui\` serve opened to `?mock=1&theme=arcane-library&flavours=3&addons=2` at an 845×539 CSS viewport shows identical numbers.

**Root cause the round-21 fix missed:** `height: clamp(110px, 100%, 280px)` has `100%` as its *preferred* value but **110px as a hard minimum** - CSS `clamp(MIN, VAL, MAX)` is defined as `max(MIN, min(VAL, MAX))`, so the result can never fall below `MIN` regardless of what `VAL` (`100%` of `.arcane-hero`'s real height) actually resolves to. Round-21's own fix note asserted "the box and its content can now never disagree about how tall the box is" - true only when `.arcane-hero`'s real height happens to be ≥110px. A real multi-flavour `.nav` (measured 213px, vs. a short single-flavour nav) at the default 1056×720 window leaves `.arcane-hero` only ~76px - 34px under the clamp's own floor - and the 110px floor is exactly what got forced past the box's own edge and then clipped by `overflow: hidden`. The round-21 pass's own verification never caught this because its multi-flavour DOM check used `?flavours=3` without also confirming `.arcane-hero`'s real height stayed above 110px, and `Run-ThemeAudit.ps1`'s screenshot fixture is single-flavour only.

**Fix (`ui/style.css`):** `.arcane-hero` becomes a CSS size-query container (`container-type: size; container-name: arcane-hero`) - safe because `flex: 1 1 auto` already gives it a height independent of its own children's size, so containment adds no new constraint. `.arcane-hero-cat`'s height drops the floor entirely, `height: min(100%, 280px)` - it can now never be forced taller than the real box, so there is nothing left for `overflow: hidden` to clip. Below the same 110px recognizability floor, a container query hides the cat and its `.arcane-alcove` backdrop outright instead of showing a shrunk or clipped fragment:

```css
:root[data-theme="arcane-library"] .arcane-hero {
  display: block;
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  pointer-events: none;
  container-type: size;
  container-name: arcane-hero;
}
:root[data-theme="arcane-library"] .arcane-hero-cat {
  position: absolute;
  left: 0; right: 0; bottom: 0;
  width: 100%;
  height: min(100%, 280px);
  display: block;
}
@container arcane-hero (max-height: 109px) {
  :root[data-theme="arcane-library"] .arcane-hero-cat,
  :root[data-theme="arcane-library"] .arcane-alcove {
    display: none;
  }
}
```

This is the same "vanish rather than crowd or clip" contract the theme already uses for genuinely short windows (`@media (max-height: 460px)`, left in place unchanged as a coarser backstop for browsers without container-query support) - just correctly scoped to `.arcane-hero`'s own *real* freed space, which depends on how many flavour pills `.nav` has, not only on raw window height. Net visual effect: at the exact failing scenario (default window, real 3-flavour install) the sidebar now shows nav → an empty gap → the bottom controls, with no broken or partial cat art, instead of a clipped fragment; at the project's default window with 1 flavour, and at any taller window regardless of flavour count, the full hero cat renders exactly as round-21 intended (verified: `.arcane-hero-cat`'s rect stays entirely within `.arcane-hero`'s rect at every size tested, including Eric's ≈2024×1273 CSS window where the cat still caps at the 280px ceiling with `.arcane-alcove` filling the rest).

**Verification performed this pass:**
- `node --check ui/app.js` - untouched file, syntax OK.
- `tests\run-all.ps1 -Quick` - static (7/7), unit (174/174), integration (68/68), and spa (1/1) layers all green; the only failure is the pre-existing `host` layer tray-click-outcome assertion in `Host.Tests.ps1` (`clickOutcome` expected `'launch'`, got `'activate:foreground'`) - unrelated to `ui/index.html`/`ui/style.css`, matches the same pre-existing, environment-dependent failure the round-21 pass called out, not a regression from this change. Port 47899 confirmed free by hand before trusting the run (per this project's own known sandbox quirk: the hygiene sweep's force-kill can't always reap a stray listener here).
- `tests\spa\Run-ThemeAudit.ps1` - **469/469 passed**, all 15 themes including `arcane-library`, 15/15 screenshots written.
- Browser DOM measurement (static `ui\` serve, own tab/port, closed after use) at 845×539 CSS with `?mock=1&theme=arcane-library&flavours=3&addons=2` (the exact failing scenario): `.arcane-hero` real height 76.4px, `.arcane-hero-cat` and `.arcane-alcove` both `display: none` - no clipped fragment, clean vanish. At 1040×700 CSS with the same 3-flavour params (approximating the default window's real content viewport), `.arcane-hero` real height 237px and the cat's rect (top 304 / bottom 541.2) sits entirely inside `.arcane-hero`'s own rect - whole cat, no clipping - confirmed visually in a screenshot (pointed ears, gold helm, sitting posture, legible at a glance). At 2024×1273 CSS (Eric's window), the cat renders at the 280px ceiling, fully contained.

## 7.16 Acceptance checklist (round-22 verification fix)

- [ ] `.arcane-hero-cat`'s height has no forced minimum (`min(100%, 280px)`, not `clamp(110px, 100%, 280px)`) - it can never be sized taller than `.arcane-hero`'s own real box.
- [ ] `.arcane-hero` is a CSS size-query container (`container-type: size; container-name: arcane-hero`) so its children can query its own real height directly.
- [ ] Below a real `.arcane-hero` height of 110px, a `@container arcane-hero (max-height: 109px)` rule hides both `.arcane-hero-cat` and `.arcane-alcove` outright - no shrunk-past-recognizable or clipped fragment ever renders.
- [ ] At the default window with a **real** multi-flavour (2-3 pill) install and real tracked addons - not just `?mock=1&flavours=N` or `Run-ThemeAudit.ps1`'s single-flavour fixture - the sidebar shows either the whole cat or nothing, never a partial one.
- [ ] At the default window with 1 flavour, and at any taller window regardless of flavour count (including Eric's ≈2024×1273 CSS window), the full hero cat renders within the 110-280px range, entirely inside `.arcane-hero`'s rect.
- [ ] `@media (max-height: 460px)` (the pre-existing coarse backstop) is untouched.
- [ ] `node --check ui/app.js` passes (file untouched by this fix).
- [ ] `tests\run-all.ps1 -Quick` and `tests\spa\Run-ThemeAudit.ps1` both run clean for every one of the 15 themes (the pre-existing, unrelated `Host.Tests.ps1` tray-click-outcome failure is called out explicitly, not silently ignored; port 47899 confirmed free by hand first).
- [ ] No token (`--bg-*`, `--text*`, `--accent*`, etc.) changed; no file outside `ui/index.html`, `ui/style.css`, and this spec was edited; nothing was deployed, committed, or touched under `C:\Program Files (x86)`.

---

## 8. Tokyo Rain becomes the default

**Round 31, Eric's verbatim request:** "keep the icon make a snowy theme make the rainy theme default, fix the icon on my desktop." Three separate asks: the app icon is untouched (not this section's concern - see `ui/icon.svg`'s own history in section 7.7/7.11, unchanged this round), a new snowy 16th theme is added (a separate change set, not covered here), and **Tokyo Rain (`tokyo-rain`) becomes the default theme**, superseding round 19's flip to Arcane Library the same way round 19's own table (section 7.9) superseded round 12's Vaporwave-default rows - history preserved below, not deleted, per this file's and `SPEC.md`'s established pattern. The desktop-shortcut icon Eric also mentions is a separate, unrelated fix (Explorer's shortcut-icon cache, not anything under `ui/` or `host/`) and is out of scope for this theme round.

Tokyo Rain keeps its existing concept and token block (section 7) unchanged except for the one failing token the stricter default floors below required - see "Contrast floor fix" further down. Arcane Library remains fully intact, byte-for-byte, as the picker's new #2 entry; nothing about its own token block, signature touches, or icon changed.

### 8.1 Picker order (15 themes)

Rule: the default is always first in the picker. Tokyo Rain moves to position 1; Arcane Library (the previous default) drops to position 2; every other theme keeps its prior relative order unchanged (this just closes the gap Tokyo Rain leaves behind at its old position 12 - nothing between Arcane Library and Strawberry Cream reshuffles beyond that).

1. **Tokyo Rain** (`tokyo-rain`) - new default
2. Arcane Library (`arcane-library`)
3. Vaporwave (`vaporwave`)
4. Lofi Night (`lofi`)
5. Dark (`dark`)
6. Light (`light`)
7. Terminal Green (`terminal-green`)
8. Arctic Ice (`arctic-ice`)
9. Art Deco (`art-deco-gold`)
10. Alpine Dawn (`alpine-dawn`)
11. Matcha (`matcha`)
12. Desert Night (`desert-night`)
13. Brushed Steel (`brushed-steel`)
14. Aurora Sky (`aurora-sky`)
15. Strawberry Cream (`strawberry-cream`)

```js
const THEMES = [
  { slug: "tokyo-rain",        name: "Tokyo Rain" },
  { slug: "arcane-library",    name: "Arcane Library" },
  { slug: "vaporwave",         name: "Vaporwave" },
  { slug: "lofi",              name: "Lofi Night" },
  { slug: "dark",              name: "Dark" },
  { slug: "light",             name: "Light" },
  { slug: "terminal-green",    name: "Terminal Green" },
  { slug: "arctic-ice",        name: "Arctic Ice" },
  { slug: "art-deco-gold",     name: "Art Deco" },
  { slug: "alpine-dawn",       name: "Alpine Dawn" },
  { slug: "matcha",            name: "Matcha" },
  { slug: "desert-night",      name: "Desert Night" },
  { slug: "brushed-steel",     name: "Brushed Steel" },
  { slug: "aurora-sky",        name: "Aurora Sky" },
  { slug: "strawberry-cream",  name: "Strawberry Cream" },
];
const DEFAULT_THEME = "tokyo-rain";
```

(A 16th entry - the new snowy theme - is added by a separate change set, appended after Strawberry Cream per section 4's "adding a theme is a one-entry change" rule; it does not reorder anything above.)

### 8.2 Contrast floor fix

Tokyo Rain must clear the same stricter "default theme" floors Arcane Library was held to in round 19 (section 7.4's brief, carried forward): text vs bg-0..3 >=7:1, muted vs bg-1..2 >=5:1, chip text-on-tint vs bg-1..2 >=5:1, faint >=4.5:1 (unchanged from the generic floor), accent-text/accent >=4.5:1 (unchanged from the generic floor).

Computed with node, straight from Tokyo Rain's existing token block (section 7.3), before any change:

| Pairing | Ratio | Floor | Result |
|---|---|---|---|
| text/bg-0 | 16.40 | 7 | pass |
| text/bg-1 | 15.40 | 7 | pass |
| text/bg-2 | 14.02 | 7 | pass |
| text/bg-3 | 12.39 | 7 | pass |
| muted/bg-1 | 7.22 | 5 | pass |
| muted/bg-2 | 6.57 | 5 | pass |
| faint/bg-1 | 5.86 | 4.5 | pass |
| faint/bg-2 | 5.33 | 4.5 | pass |
| faint/bg-3 | 4.72 | 4.5 | pass |
| accent-text/accent | 6.50 | 4.5 | pass |
| chip-success vs bg-1 / bg-2 | 8.43 / 7.53 | 5 | pass |
| chip-warning vs bg-1 / bg-2 | 7.78 / 6.96 | 5 | pass |
| chip-info vs bg-1 / bg-2 | 8.21 / 7.32 | 5 | pass |
| chip-muted vs bg-1 / bg-2 | 5.76 / 5.16 | 5 | pass |
| chip-danger vs bg-1 / bg-2 | 5.31 / **4.78** | 5 | **fail (bg-2)** |

Only one pairing fails: `.chip-danger`'s text (`--danger`) over its own tint (`--danger-tint`, alpha .14) composited on `--bg-2` measured 4.78:1, under the 5:1 default floor (it already cleared the generic 4.5:1 floor every non-default theme is held to, which is why this never surfaced before Tokyo Rain became the default).

**Fix (smallest hex change found by exhaustive search over +-30 on each channel, minimizing total per-channel delta, requiring both bg-1 and bg-2 stay >=5:1):** `--danger` `#ff6478` -> `#ff6f78` - green channel only, `0x64` -> `0x6f` (+11 decimal), red and blue untouched. `--danger-tint`/`--danger-border`/`--danger-outline-border` updated to the matching rgb (255, 111, 120) so the tint stays keyed to the solid color, per this file's existing convention (every other theme's tint literals mirror their solid token's rgb).

| Pairing | Before | After | Floor |
|---|---|---|---|
| chip-danger vs bg-1 | 5.31 | 5.56 | 5 |
| chip-danger vs bg-2 | 4.78 | **5.01** | 5 |
| danger-text (#2a0a10) vs danger | 6.39 | 6.78 | n/a (not floor-gated) |
| banner-danger-text vs danger-tint-over-bg-0 | 10.13 | 10.01 | n/a |
| form-error-text vs danger-tint-over-bg-1 | 8.06 | 7.95 | n/a |

All other Tokyo Rain tokens are untouched. The theme's character (a cool blue-black street at night, magenta signage, cyan streetlight) is unaffected - `#ff6f78` reads as the same coral-red danger color as `#ff6478` at a glance; the shift is 11/255 on one channel.

### 8.3 Change points

| # | File | Location | Change |
|---|---|---|---|
| 1 | `ui/index.html` | line 2, `<html data-theme="arcane-library">` seed attribute | -> `data-theme="tokyo-rain"` |
| 2 | `ui/app.js` | `THEMES` array (~line 27) | reorder: `tokyo-rain` first, `arcane-library` second, everything else keeps prior relative order (section 8.1) |
| 3 | `ui/app.js` | `DEFAULT_THEME` (~line 47) | `"arcane-library"` -> `"tokyo-rain"` |
| 4 | `ui/app.js` | `isKnownTheme(v)` | no logic change - already derives from `THEMES`; accepts the reordered 15 slugs automatically |
| 5 | `ui/style.css` | `:root[data-theme="tokyo-rain"]` block (section 7.3's location) | `--danger` `#ff6478` -> `#ff6f78`; `--danger-tint`/`--danger-border`/`--danger-outline-border` rgb updated to match (section 8.2) - the only pixel-level change this round makes to any token |
| 6 | `ui/manifest.json` | `background_color`, `theme_color` | `"#0a0912"` (Arcane Library's bg-0) -> `"#0b0d14"` (Tokyo Rain's bg-0) |
| 7 | `host/FurphyHost.cs` | `InitializeDefaultTheme()` | Arcane Library's 8-color palette + `_themeName = "arcane-library"` -> Tokyo Rain's 8-color palette (below) + `_themeName = "tokyo-rain"`; rebuild via `host/build-host.ps1` |
| 8 | `SPEC.md` | default-theme decision record (section 3's opening paragraph) | append a new dated entry (2026-09-06, round 31): "Tokyo Rain is the default (Eric's decision, round 31), superseding round 19's flip to Arcane Library. Rounds 7, 11, 12, and 19's entries remain below as history, per this file's established pattern - do not delete any." |
| 9 | `README.txt` | default-theme line, if any | checked - `README.txt` names no default theme or theme count today, so this round leaves it unchanged; `README.md` (out of this round's file scope) still says Arcane Library and should be corrected in a future pass |
| 10 | `CHANGELOG.md` | top of file | new `## Round 31 (1.12.0: Tokyo Rain default, new Snowy theme)` entry, Eric's verbatim request quoted, this section's default-flip summary (the new snowy theme's own paragraph is appended by the change set that adds it) |
| 11 | `tests/spa/harness.js` | asserted default-theme slug + picker-order array (~line 559) | `"arcane-library"` -> `"tokyo-rain"`; 15-entry order updated to section 8.1; the phase-4 comment referencing the fresh-profile default (~line 632) updated to match |
| 12 | `tests/spa/theme-audit.js` | `THEME_SLUGS` order | updated to section 8.1's order |
| 13 | `tests/spa/theme-audit.js` | `CONTRAST_FLOOR_OVERRIDES` | add `"tokyo-rain": { text: 7, muted: 5, chip: 5 }`; **keep** `"arcane-library"` at the same strict floors - it still passes them and nothing asked to relax it |
| 14 | `tests/spa/Run-ThemeAudit.ps1` | `$Script:ThemeSlugs` | updated to section 8.1's order |

**Tokyo Rain's 8-color host palette** (for row 7, verbatim from section 7.3, unaffected by the section 8.2 `--danger` fix - none of these eight tokens changed): bg0 `#0b0d14` bg1 `#12151f` bg2 `#1a1e2c` bg3 `#232838` border `#2c3244` text `#e8ecf5` muted `#9aa3ba` accent `#ff5aa8`.

**Not a bug, don't "fix" (same rule as section 2 and section 7.9's row 11 comment):** `LoadPersistedTheme()` in `FurphyHost.cs` overlays a returning user's `settings.json` `hostTheme` after the new default is seeded - a user who already has Arcane Library (or Vaporwave, or Lofi Night, or any other theme) persisted keeps seeing that theme's chrome even after the default flips, exactly mirroring the page's own localStorage-first behavior (`Prefs.readTheme()` only falls back to `DEFAULT_THEME` when nothing valid is stored). Do not force-migrate existing `settings.json` files or `localStorage` values.

### 8.4 Acceptance checklist

- [ ] `ui/app.js`'s `THEMES` array has `tokyo-rain` first, `arcane-library` second, and the remaining 13 slugs in their prior relative order (section 8.1); `DEFAULT_THEME === "tokyo-rain"`.
- [ ] `isKnownTheme` and the swatch-grid picker derive from `THEMES` with no separate hardcoded list (unchanged mechanism from section 4/7.9 row 6).
- [ ] `ui/index.html`'s `<html data-theme>` seed reads `tokyo-rain`.
- [ ] `ui/manifest.json`'s `background_color`/`theme_color` equal Tokyo Rain's `--bg-0` (`#0b0d14`).
- [ ] `host/FurphyHost.cs`'s `InitializeDefaultTheme()` paints Tokyo Rain's 8-color palette and sets `_themeName = "tokyo-rain"`; `host/build-host.ps1` builds clean.
- [ ] `:root[data-theme="tokyo-rain"]`'s only token change is `--danger` (`#ff6478` -> `#ff6f78`) and its three dependent `rgba(...)` literals (`--danger-tint`, `--danger-border`, `--danger-outline-border`) updated to the matching rgb; every other Tokyo Rain token, its signature touch, and its `.select` chevron override are byte-for-byte unchanged.
- [ ] Live-computed contrast audit passes Tokyo Rain against the stricter default floors (text >=7, muted >=5, chip >=5, faint/accent-text >=4.5) - specifically `chip-danger vs bg-2` now clears 5:1 - and Arcane Library still passes the same strict floors unchanged.
- [ ] Every one of the other 13 existing theme blocks is byte-for-byte unchanged.
- [ ] Swatch-grid picker renders 15 themes in the section 8.1 order, Tokyo Rain first and ring-marked by default on a fresh profile.
- [ ] Fresh profile (no `localStorage`, no persisted `hostTheme`) loads Tokyo Rain on both the page and the native title bar; an existing user's persisted theme preference (Arcane Library or any other) is undisturbed, per section 8.3's "not a bug" note.
- [ ] `tests/spa/harness.js`'s default-theme assertion, picker-order array, and the phase-4 comment all say `tokyo-rain`, not `arcane-library`.
- [ ] `tests/spa/theme-audit.js`'s `THEME_SLUGS` order matches section 8.1; `CONTRAST_FLOOR_OVERRIDES` keys both `tokyo-rain` and `arcane-library` at the strict floors.
- [ ] `tests/spa/Run-ThemeAudit.ps1`'s `$Script:ThemeSlugs` order matches section 8.1; the audit reports 15/15 themes passing.
- [ ] `SPEC.md` carries the new round-31 decision entry with rounds 7, 11, 12, and 19's entries intact.
- [ ] The app icon (`ui/icon.svg`, `icon.ico`, `host/bin/icon.ico`, `ui/icons/*`) is untouched - Eric explicitly asked to keep it.
- [ ] The new snowy 16th theme is NOT added by this change set - that is a separate pass.
- [ ] No new theme introduces a network font, external asset, or anything that breaks the app running fully offline.

## 9. Snowy theme: Snow Day (snow-day)

**Round 31, second half of Eric's verbatim request** (section 8's opening quote): "...make a snowy theme..." A new, 16th theme, added to the picker in last position after Strawberry Cream. This does **not** change the app's default theme - that stays Tokyo Rain per section 8 - Snow Day is simply theme #16 in the list.

### 9.1 Selection

Three candidate directions were designed independently and judged blind, then each one's contrast was independently recomputed against this round's stricter floors (the same "default theme" floors section 8.2 uses - text >=7:1, muted >=5:1, faint >=4.5:1, accent-text >=4.5:1, chip-vs-tint >=5:1 - applied uniformly to all three candidates for this round's judging, not just to whichever one shipped as default):

- **A - Snow Day** (winner, shipped, this section). A bright, overcast snow-morning palette: flat low-chroma grey-blue sky/ground tones plus one warm, human accent (cocoa-brown, "a mug of hot chocolate carried out into the cold"). Signature touch: a full-slot snowfall-over-pines scene filling the sidebar's freed space below the nav (redone post-launch - see section 9.5 for the original too-subtle touch and its replacement). Softened 6/10/16px corner radii ("snow-rounded" geometry) - the only candidate to touch the radius tokens.
- **B - Snowglow.** A similar cool-neutral/warm-accent family, distinguished by its signature touch: true seamless-loop falling snow (`translateY(0 -> 50%)` on a 200%-tall tiled background) rather than a bounded drift, so its flakes read as continuously falling. Independently verified all-pass against the stricter floors; tightest margin `chip-danger vs bg-2` at 5.34 (floor 5).
- **C - Snowbound Cabin.** A "looking outside" concept built around a window/muntin motif (frosted panes, a view out rather than a view of the snow itself). Independently verified all-pass against the stricter floors; tightest margin `chip-danger vs bg-2` at 5.16 (floor 5) - the single thinnest margin of the three candidates, though it still clears its floor.

**Judge's verdict:** Snow Day (A) won - it clears every floor and every craft requirement as submitted, with no mandatory grafts needed to ship it. Its concept (outdoors, in the snow, holding something warm) reads as the most immediately "snowy" of the three at a glance, and it is the only candidate of the three - and the only theme in the full 16-theme set - to soften all three corner-radius tokens for a deliberately rounded, snow-drift feel.

**Distinctness check (the judge's own verification, not just "by eye"):** Snow Day's `--bg-0` (`#eef1f2`, H195 S13% L94%) sits at far lower chroma than Arctic Ice's `--bg-0` (`#eef4f7`, H200 S36% L95%) - Arctic Ice reads as bright icy-blue "glacier glare," Snow Day reads as flat overcast sky. Its accent (`#8f5a2e`, H27 S51% L37%, warm cocoa-brown) is the opposite temperature from Arctic Ice's cool deep-teal accent (`#0c6c8f`, H196) and shares no hue family with any other theme's accent in the other 15: Matcha's green (H106), Strawberry Cream's raspberry-pink (H348), Alpine Dawn/Desert Night's oranges (H18/H29), Brushed Steel's steel-blue (H203), Aurora Sky's violet (H265). No existing theme pairs a cool, low-chroma neutral base with a warm, desaturated brown accent.

**Grafts:** None were mandatory - Snow Day shipped verbatim, no hex changes required by the winning submission. Two optional, non-blocking ideas were flagged for a possible future polish pass (not part of this round, and not acted on here):

1. Port Snowglow's (B) true seamless-loop tiling technique onto Snow Day's existing `.nav::after` box (without touching its kill-switch/mask/z-index safety net), if a future iteration wants a more literal "continuously falling" read than Snow Day's own bounded ping-pong drift. *(Overtaken by events: the signature-touch redo in section 9.5 replaced the `.nav::after` box entirely with the `.snow-scene` slot, whose three `.snow-layer` tiles already loop as true continuous falling snow via `linear infinite` translate animations - this idea's goal is satisfied, just via a different box than the one this note named.)*
2. A contrast-headroom note (not a defect, same non-blocking tradition as Matcha's and Strawberry Cream's own accent-text notes elsewhere in this file): Snow Day's two thinnest margins - `text-faint vs bg-3` (4.75, floor 4.5) and `chip-info vs bg-2` (5.21, floor 5) - pass cleanly but sit closer to their floor than the rest of the set, worth a maintainer's eyes if there's appetite for a follow-up.

Nothing from Snowbound Cabin (C) was worth grafting - its window/muntin, "looking outside" motif doesn't fit Snow Day's "outdoors, in the snow" concept.

### 9.2 Concept

A bright, overcast snow morning right after a fresh fall: a flat, quiet grey-blue sky (not sunny, not glaring), fresh snow-white ground and cards, and cool grey-blue "packed snow" shadow tones with almost no chroma. Against that cool neutrality sits one warm, human accent - a cocoa-brown (a mug of hot chocolate carried out into the cold) - used for every interactive/accent surface, with a muted forest-green success, warm amber-olive warning, brick-red danger, and slate-blue info rounding out the status set. Geometry is softened (6/10/16px radii, versus the shared default's tighter corners) so cards and buttons read as gently snow-rounded rather than crisp glacier-cut. `color-scheme: light` - Snow Day is a light theme, the fourth in the set alongside Light, Arctic Ice, and Matcha.

### 9.3 Token block (verbatim, `ui/style.css`)

```css
:root[data-theme="snow-day"] {
  color-scheme: light;
  --bg-0: #eef1f2;
  --bg-1: #ffffff;
  --bg-2: #e6ebed;
  --bg-3: #d7dfe2;
  --border: #c9d3d8;
  --border-soft: #dde6ea;
  --border-hover: #aab8c0;

  --text: #1c2b33;
  --text-muted: #435862;
  --text-faint: #4c626c;

  --accent: #8f5a2e;
  --accent-hover: #764a26;
  --accent-active: #613c1f;
  --accent-text: #fff8f0;

  --success: #0f5f37;
  --warning: #6b4c00;
  --danger: #922f24;
  --info: #1f5e86;

  --secondary: #5b7b93;

  --success-tint: rgba(15, 95, 55, .08);
  --warning-tint: rgba(107, 76, 0, .08);
  --danger-tint: rgba(146, 47, 36, .08);
  --info-tint: rgba(31, 94, 134, .08);
  --accent-tint: rgba(143, 90, 46, .12);
  --muted-tint: rgba(67, 88, 98, .10);

  --banner-danger-text: #922f24;
  --form-error-text: #922f24;

  --danger-hover: #7a2620;
  --danger-text: #fff5f3;
  --danger-border: rgba(146, 47, 36, .35);
  --danger-outline-border: rgba(146, 47, 36, .4);

  --focus-ring: var(--accent);

  --radius-sm: 6px;
  --radius: 10px;
  --radius-lg: 16px;
}

:root[data-theme="snow-day"] .select {
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%23435862' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/></svg>");
}
```

Swatch preview rule (`ui/style.css`, colocated with the token block per this file's own convention, section 3.2):

```css
.theme-swatch[data-theme-value="snow-day"] { --sw-bg:#ffffff; --sw-bg2:#eef1f2; --sw-accent:#8f5a2e; --sw-text:#1c2b33; }
```

Snow Day is the only theme in the set to override `--radius-sm`/`--radius`/`--radius-lg` (default: 6px/10px/16px are actually the shared base values already used by most other themes - Snow Day matches them here rather than diverging; the note is that it is the one theme block that states them explicitly, as a deliberate "snow-rounded" design decision rather than an inherited fallthrough).

### 9.4 Contrast table (recomputed independently with node against this section's token block, same formula as `tests/spa/theme-audit.js`: sRGB -> linear, 0.2126/0.7152/0.0722 weights, `(L1+.05)/(L2+.05)`; chip pairs composite the `*-tint` rgba onto the stated `--bg` hex, then take the solid chip-text color's contrast against that composite)

Snow Day is not the default theme, so the generic WCAG AA floor (4.5:1 for text, chips held to the same 4.5 in `theme-audit.js`'s `DEFAULT_FLOORS`) is what `tests/spa/theme-audit.js` actually enforces for it - shown below is the fuller table the judge computed against this round's stricter default-theme floors, which Snow Day also clears with no override needed:

| Pairing | Ratio | Floor | Result |
|---|---|---|---|
| text/bg-0 | 12.82 | 7 | pass |
| text/bg-1 | 14.56 | 7 | pass |
| text/bg-2 | 12.11 | 7 | pass |
| text/bg-3 | 10.77 | 7 | pass |
| muted/bg-1 | 7.47 | 5 | pass |
| muted/bg-2 | 6.22 | 5 | pass |
| faint/bg-1 | 6.42 | 4.5 | pass |
| faint/bg-2 | 5.34 | 4.5 | pass |
| faint/bg-3 | 4.75 | 4.5 | pass (tightest margin in the set) |
| accent-text/accent | 5.43 | 4.5 | pass |
| chip-success vs bg-1 / bg-2 | 6.83 / 5.73 | 5 | pass |
| chip-warning vs bg-1 / bg-2 | 6.99 / 5.83 | 5 | pass |
| chip-danger vs bg-1 / bg-2 | 6.92 / 5.81 | 5 | pass |
| chip-info vs bg-1 / bg-2 | 6.20 / 5.21 | 5 | pass (second-tightest margin) |
| chip-muted vs bg-1 / bg-2 | 6.42 / 5.39 | 5 | pass |

All 20 pairs clear their floor; no hex change was required. This document's own independent node recompute (separate from the judge's) landed within 0.01-0.02 on every row (e.g. chip-danger vs bg-2: 5.81 both times; chip-info vs bg-2: 5.20 here vs 5.21 above) - rounding noise only, no pass/fail disagreement.

### 9.5 Signature touch: sidebar snowfall (`ui/index.html`, `ui/style.css`)

**STALE GEOMETRY FLAG (Round 34, 2026-09-07):** every pixel height/overlap
number in this section (9.5.5's slot mechanics and its geometry table, the
acceptance-checklist line near the end of this file) was measured against
`.sidebar-bottom` while it still held the "Update & Play"/"Launch WoW"
buttons Eric asked removed this round (see CHANGELOG.md's Round 34 entry).
Removing those two buttons (~40-44px each, `btn-lg`/`btn`, plus their 8px
gap) frees roughly 90-110px that `.snow-scene`'s `flex: 1 1 auto` slot
absorbs directly (9.5.5's own mechanics below need no code change - the
layout math already does the right thing); the single most consequential
stale number is the 845x539/flavours=3 row, predicted to newly clear the
109px "vanish rather than clip" floor and become visible at a size it was
never reviewed at before. This is an arithmetic prediction, not a live
measurement - CS-R21 in the Round 34 removal spec calls for
re-measuring every table below with `getBoundingClientRect` against the
real running app once the button removal (CS-R4/CS-R5) has landed, and
getting a design sign-off on the newly-visible case if it does turn out
visible. Not done as part of this pass - tests/docs work only, no live
browser measurement.

#### 9.5.1 Original touch - superseded

Snow Day originally shipped (this round, before the redo below) with soft, out-of-focus snowflakes drifting in the naturally-empty lower portion of the sidebar's `.nav` column: a fixed 88px band of five faint radial-gradient dots pinned to `.nav`'s own bottom edge via `.nav::after`, gated by a `@container snow-day-nav (max-height: 220px)` kill switch and animated with a bounded `translate`/`opacity` ping-pong. No markup changes were needed for that version - it was pure `.nav::after` decoration.

**Verdict: rejected.** A real capture of the shipped build at 2530x1591 (Eric's own window) showed, in Eric's own words when he saw the equivalent problem on Arcane Library's first cat art, the same failure mode: "CANT ACTUALLY SEE THE CATS OR WHATEVER." For Snow Day specifically, the capture showed a blank light column with a faint grey smudge - nothing read as snow. Two compounding causes: (1) the five dots were near-white (`rgba(255,255,255,.7-.9)`) sitting directly on this theme's own near-white sidebar (`--bg-1` `#ffffff`), so they had essentially no backdrop to read against; and (2) the band was a fixed 88px strip pinned to `.nav`, while a real multi-flavour window like Eric's leaves 500-1000px of genuinely free `flex:1` space below the nav - the decoration occupied a small fraction of the space actually available, so even where it was visible it read as a sliver, not a scene.

#### 9.5.2 Redo: judged concepts

Two pixel artists were asked to redesign the signature touch using the same "dedicated flex slot owns the freed sidebar space" technique Arcane Library's `.arcane-hero` already uses (sections 7.5-7.6, 7.13, 7.15-7.16) rather than a `.nav::after` decoration, so the art gets the real freed space instead of a fixed strip:

- **A - Snowfall over pines** (winner, shipped, this section). A `.snow-scene` flex slot filling the entire gap between the nav and the bottom CTA: a soft, never-quite-white overcast-sky wash (`.snow-scene-sky`) behind everything so near-white flakes always have contrast, three parallax layers of falling snow (`.snow-layer-far/-mid/-near`, CSS-only repeating radial-gradient tiles, transform-only drift loops) spanning the whole box, over a bottom-anchored pixel-art horizon (`.snow-scene-ground`): snow-capped pine silhouettes, a rolling white drift with its own soft shadow line, and a small cocoa-scarfed snowman as the one warm focal object.
- **B - Frosted window.** A pixel-art window frame silhouette with small tree icons visible through the panes and a cocoa mug on the sill, plus an ambient flurry of flakes above the frame.

**Judge's verdict: A won.** At 845x539/single-flavour (the `.snow-scene` box renders 207x173) it reads as a complete snow diorama in well under a second: snow-capped pine silhouettes with tapering branch-shelf snow, a rolling white drift with a visible shadow line, and a small cocoa-scarfed snowman as the one warm touch, all against the overcast-sky wash that finally gives the near-white flakes something to read against - the actual fix for the original white-on-white bug. At 2024x1273 (Eric's real proportions, a 907px box) the falling-snow layers scale to fill the whole freed height, staying a dense, evenly-distributed field top to bottom, anchored by the pine/snowman horizon at the very bottom - unmistakably "it's snowing" even glanced at from across the room. At flavours=3/845x539 the box drops to 74px and the whole scene correctly vanishes below the 109px container-query floor, matching `.arcane-hero`'s own "vanish, don't clip" contract.

B's window silhouette itself was instantly recognizable, but as "a window," not "snow" - the one-second read had to travel past the frame to small tree icons before landing on winter, and the judge found two contrast bugs reproducing the exact failure class this redo exists to eliminate: the snow-drift mounds in the lower glass panes were indistinguishable from the pane's own near-white fill at 5x zoom, and - most damaging for this brief specifically - B's own crop at 2024x1273 showed roughly 500px of near-blank ambient-flurry space above the window frame, materially the same "blank light column with a faint grey smudge" bug the redo was triggered by. Nothing from B was worth grafting onto A.

**Judge's tweaks (both verified during implementation, no code changes needed):**

1. *Spot-check the `.snow-scene-ground` rendering at an in-between slot height (~130-150px), between the 210px ground cap and the 109px hide-floor, to confirm the snowman's head isn't awkwardly sliced.* Verified at a live 845x506 window (single flavour), which produces a `.snow-scene` box of exactly 140px: `.snow-scene-ground`'s `viewBox="0 0 208 158"` with `preserveAspectRatio="xMidYMax meet"` means the entire viewBox is always scaled to fit the box - "meet" never crops, it only shrinks - so the snowman, pines, and drift all render smaller but complete at 140px, with no slicing at any height between the 109px floor and the 210px cap.
2. *Confirm `.snow-scene-sky`'s hardcoded gradient stops (`#e7edef`/`#e1e8ea`/`#d9e2e6`) are actually in the theme's own palette family before shipping.* Computed HSL for both sets: the theme's own `--bg-0`/`--bg-2`/`--bg-3`/`--border-soft` (section 9.3) land at H195-200 S13-24% L82-94%; the three sky stops land at H193-198 S18-21% L88-92% - the same cool, low-chroma grey-blue family, confirmed rather than assumed.

#### 9.5.3 Final markup (`ui/index.html`, verbatim)

Inserted immediately after `</nav>` and before the Lofi Night `.lofi-cityscape` block (`.snow-scene` is `display:none` on every other theme, exactly like `.lofi-cityscape` and `.arcane-hero`):

```html
<div class="snow-scene">
  <div class="snow-scene-sky" aria-hidden="true"></div>
  <div class="snow-layer snow-layer-far" aria-hidden="true"></div>
  <svg class="snow-scene-ground" viewBox="0 0 208 158" preserveAspectRatio="xMidYMax meet" shape-rendering="crispEdges" aria-hidden="true" focusable="false">
    <g fill="#93a7b4">
      <path d="M56,86 L70,118 L42,118 Z"/>
      <path d="M108,78 L124,116 L92,116 Z"/>
      <path d="M158,88 L171,118 L145,118 Z"/>
    </g>
    <g fill="#ffffff" opacity="0.9">
      <rect x="59" y="98" width="8" height="2.5"/>
      <rect x="112" y="90" width="8" height="2.5"/>
      <rect x="161" y="100" width="8" height="2.5"/>
    </g>
    <g fill="#3a4f60">
      <path d="M27,58 L46,132 L4,132 Z"/>
      <path d="M186,52 L207,132 L162,132 Z"/>
    </g>
    <g fill="#ffffff">
      <rect x="8" y="120" width="30" height="3"/><rect x="12" y="104" width="20" height="3"/><rect x="16" y="90" width="12" height="3"/><rect x="20" y="76" width="6" height="3"/>
      <rect x="166" y="120" width="30" height="3"/><rect x="170" y="104" width="22" height="3"/><rect x="175" y="90" width="13" height="3"/><rect x="180" y="76" width="6" height="3"/>
    </g>
    <g fill="#aab8c0" opacity="0.55">
      <ellipse cx="34" cy="149" rx="52" ry="24"/>
      <ellipse cx="112" cy="153" rx="58" ry="25"/>
      <ellipse cx="190" cy="149" rx="46" ry="24"/>
    </g>
    <g fill="#ffffff">
      <ellipse cx="34" cy="145" rx="52" ry="22"/>
      <ellipse cx="112" cy="149" rx="58" ry="23"/>
      <ellipse cx="190" cy="145" rx="46" ry="22"/>
      <rect x="0" y="148" width="208" height="10"/>
    </g>
    <g>
      <rect x="126.5" y="127" width="14" height="2.4" fill="#764a26" transform="rotate(-18 126.5 128.2)"/>
      <rect x="152" y="127" width="14" height="2.4" fill="#764a26" transform="rotate(18 152 128.2)"/>
      <ellipse cx="146" cy="140" rx="19" ry="16" fill="#ffffff"/>
      <ellipse cx="152" cy="146" rx="11" ry="8" fill="#e3eaed"/>
      <ellipse cx="146" cy="115" rx="13" ry="12" fill="#ffffff"/>
      <path d="M133,117 L159,117 L155,124 L137,124 Z" fill="#8f5a2e"/>
      <rect x="150" y="122" width="6" height="13" rx="1.5" fill="#8f5a2e" transform="rotate(14 150 122)"/>
      <circle cx="141" cy="112" r="1.7" fill="#1c2b33"/>
      <circle cx="151" cy="112" r="1.7" fill="#1c2b33"/>
      <path d="M144,116 L149,117.5 L144,119 Z" fill="#8f5a2e"/>
      <circle cx="146" cy="128" r="1.6" fill="#1c2b33"/>
      <circle cx="146" cy="136" r="1.6" fill="#1c2b33"/>
    </g>
  </svg>
  <div class="snow-layer snow-layer-mid" aria-hidden="true"></div>
  <div class="snow-layer snow-layer-near" aria-hidden="true"></div>
</div>
```

Reading order top to bottom: `.snow-scene-sky` (backdrop), `.snow-layer-far` (behind the horizon), `.snow-scene-ground` (pines/drift/snowman), `.snow-layer-mid` and `.snow-layer-near` (in front of the horizon, for parallax depth). `aria-hidden` throughout - purely decorative, never conveys state, same convention as `.lofi-cityscape` and `.arcane-alcove`/`.arcane-hero-cat`.

#### 9.5.4 Final CSS (`ui/style.css`, verbatim)

Same location as the superseded 9.5.1 block: after Strawberry Cream's signature-touch block, before the Arcane Library theme's own token block.

```css
:root[data-theme="snow-day"] .nav { flex: 0 0 auto; }

.snow-scene { display: none; }
:root[data-theme="snow-day"] .snow-scene {
  display: block;
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  pointer-events: none;
  border-radius: var(--radius);
  container-type: size;
  container-name: snow-scene;
}
:root[data-theme="snow-day"] .snow-scene-sky {
  position: absolute;
  inset: 0;
  background: linear-gradient(to bottom, #e7edef 0%, #e1e8ea 55%, #d9e2e6 100%);
}
:root[data-theme="snow-day"] .snow-scene-ground {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  width: 100%;
  height: min(100%, 210px);
  display: block;
}
:root[data-theme="snow-day"] .snow-layer {
  position: absolute;
  inset: -140px;
  background-repeat: repeat;
}
:root[data-theme="snow-day"] .snow-layer-far {
  background-image:
    radial-gradient(circle clamp(2px, .7cqh, 3.5px) at 20% 30%, rgba(255,255,255,.8) 0%, transparent 100%),
    radial-gradient(circle clamp(2px, .7cqh, 3.5px) at 70% 65%, rgba(255,255,255,.75) 0%, transparent 100%);
  background-size: 64px 108px;
  opacity: .85;
  animation: snow-day-fall-far 24s linear infinite;
}
:root[data-theme="snow-day"] .snow-layer-mid {
  background-image:
    radial-gradient(circle clamp(2.6px, .9cqh, 4.5px) at 35% 20%, rgba(255,255,255,.9) 0%, transparent 100%),
    radial-gradient(circle clamp(2.6px, .9cqh, 4.5px) at 80% 60%, rgba(255,255,255,.85) 0%, transparent 100%),
    radial-gradient(circle clamp(2.6px, .9cqh, 4.5px) at 10% 75%, rgba(255,255,255,.9) 0%, transparent 100%);
  background-size: 58px 96px;
  opacity: .92;
  animation: snow-day-fall-mid 16s linear infinite;
}
:root[data-theme="snow-day"] .snow-layer-near {
  background-image:
    radial-gradient(circle clamp(3.5px, 1.2cqh, 6.5px) at 25% 25%, rgba(255,255,255,1) 0%, transparent 100%),
    radial-gradient(circle clamp(3.5px, 1.2cqh, 6.5px) at 68% 55%, rgba(255,255,255,.95) 0%, transparent 100%);
  background-size: 52px 88px;
  opacity: 1;
  animation: snow-day-fall-near 11s linear infinite;
}
@keyframes snow-day-fall-far  { from { transform: translate(0,0); } to { transform: translate(-64px, 108px); } }
@keyframes snow-day-fall-mid  { from { transform: translate(0,0); } to { transform: translate(58px, 96px); } }
@keyframes snow-day-fall-near { from { transform: translate(0,0); } to { transform: translate(-52px, 88px); } }
@media (prefers-reduced-motion: reduce) {
  :root[data-theme="snow-day"] .snow-layer { animation: none; }
}
@container snow-scene (max-height: 109px) {
  :root[data-theme="snow-day"] .snow-scene-sky,
  :root[data-theme="snow-day"] .snow-scene-ground,
  :root[data-theme="snow-day"] .snow-layer {
    display: none;
  }
}
@media (max-height: 460px) {
  :root[data-theme="snow-day"] .snow-scene { display: none; }
}
```

#### 9.5.5 Slot/container mechanics

Identical technique to `.arcane-hero` (sections 7.15-7.16): `:root[data-theme="snow-day"] .nav { flex: 0 0 auto; }` scopes `.nav` back to its own content height for this theme only (the shared base rule is `.nav { flex: 1; }`), and `.snow-scene` - a new flex sibling between `</nav>` and `.sidebar-bottom` in the markup - takes over the freed `flex: 1 1 auto` role instead, so it always gets exactly whatever room a real `.nav` (however many flavour pills it currently has) leaves free. `position: relative; overflow: hidden` on `.snow-scene` keeps every child (the sky wash, the ground SVG, all three snow layers, each inset well past the box's own edges) clipped to the box's real rectangle, so nothing can ever bleed into `.nav` above or `.sidebar-bottom` below regardless of window size. `.snow-scene` is also its own CSS size container (`container-type: size; container-name: snow-scene`), and `@container snow-scene (max-height: 109px)` hides the sky/ground/snow-layers entirely below that recognizability floor rather than showing a squeezed or clipped fragment - the same 109px threshold and "vanish, don't clip" contract as `.arcane-hero-cat`. A coarser `@media (max-height: 460px)` rule is the second line of defence for browsers without container-query support, mirroring `.arcane-hero`'s own backstop. The ground SVG's `height: min(100%, 210px)` (no floor, matching the round-22 `.arcane-hero-cat` fix) means it can never be forced taller than the box actually is, and `preserveAspectRatio="xMidYMax meet"` means the whole scene scales down instead of clipping at any height above the 109px floor (verified at a spot-checked 140px box - section 9.5.2, tweak 1).

**Verification (measured with `getBoundingClientRect` against the live mock app, all four required configurations, matching the pattern already established for `.arcane-hero` in section 7.16):**

- 845x539, single flavour: `.nav` `{top:75, bottom:191, height:116}`; `.snow-scene` `{top:207, bottom:380, height:173, display:block}` (16px gap to `.nav`); `.sidebar-bottom` `{top:396, bottom:523}` (16px gap to the scene). Scene visible (173px > 109px floor) - reads as a complete snow diorama.
- 845x539, flavours=3 (the tallest nav configuration in the set): `.nav` `{top:75, bottom:290, height:215}`; `.snow-scene` box computes to `{top:306, bottom:380, height:74}` - below the 109px floor, so `.snow-scene-sky`/`.snow-scene-ground`/`.snow-layer` are all `display:none` via the container query (confirmed live, not just by inspection); `.sidebar-bottom` unchanged at `{top:396, bottom:523}` (16px gap to the scene box regardless). Zero overlap, zero clipping - the scene vanishes cleanly rather than showing a fragment.
- 2024x1273, single flavour: `.nav` `{top:75, bottom:191}`; `.snow-scene` `{top:207, bottom:1114, height:907}` (16px gap to `.nav`); `.sidebar-bottom` `{top:1130, bottom:1257}` (16px gap to the scene). Fully visible - the falling-snow layers fill the entire freed height, reading as "it's snowing" at a glance.
- 2024x1273, flavours=3 (Eric's own real setup): `.nav` `{top:75, bottom:290}`; `.snow-scene` `{top:306, bottom:1114, height:808}` (16px gap to `.nav`); `.sidebar-bottom` `{top:1130, bottom:1257}` (16px gap to the scene). Fully visible, no overlap with the flavour pills/Update All button above or the status dot below. (Round 34, 2026-09-07: the "Update & Play" button this line used to also name is gone - see CHANGELOG.md - these specific pixel numbers predate its removal and need live re-measurement; see the section 9.5 note near the top of this file.)

In every configuration `.snow-scene`'s `left`/`right` exactly match `.nav`'s own (`12`/`219`) - never wider than the sidebar's content column - and `overflow: hidden` plus each `.snow-layer`'s oversized `-140px` inset guarantee nothing bleeds past those bounds even mid-animation. `.arcane-hero` (Arcane Library) and `.lofi-cityscape` (Lofi Night) were spot-checked at 845x539 in the same session and render pixel-identical to their pre-existing geometry - `.snow-scene` stays `display: none` on both themes, exactly like `.arcane-hero` and `.lofi-cityscape` stay `display: none` on every theme that isn't their own.

### 9.6 Picker order (16 themes)

Snow Day is appended in the last position - nothing above it reorders.

```js
const THEMES = [
  { slug: "tokyo-rain",        name: "Tokyo Rain" },
  { slug: "arcane-library",    name: "Arcane Library" },
  { slug: "vaporwave",         name: "Vaporwave" },
  { slug: "lofi",              name: "Lofi Night" },
  { slug: "dark",              name: "Dark" },
  { slug: "light",             name: "Light" },
  { slug: "terminal-green",    name: "Terminal Green" },
  { slug: "arctic-ice",        name: "Arctic Ice" },
  { slug: "art-deco-gold",     name: "Art Deco" },
  { slug: "alpine-dawn",       name: "Alpine Dawn" },
  { slug: "matcha",            name: "Matcha" },
  { slug: "desert-night",      name: "Desert Night" },
  { slug: "brushed-steel",     name: "Brushed Steel" },
  { slug: "aurora-sky",        name: "Aurora Sky" },
  { slug: "strawberry-cream",  name: "Strawberry Cream" },
  { slug: "snow-day",          name: "Snow Day" },
];
const DEFAULT_THEME = "tokyo-rain";
```

### 9.7 Change points

| # | File | Location | Change |
|---|---|---|---|
| 1 | `ui/style.css` | after Strawberry Cream's token block/`.select` override/swatch line (~line 899) | new `:root[data-theme="snow-day"]` token block (section 9.3), numbered "16." in the file's own comment style |
| 2 | `ui/style.css` | after Strawberry Cream's token block | `:root[data-theme="snow-day"] .select` chevron override (section 9.3) |
| 3 | `ui/style.css` | colocated with the token block | `.theme-swatch[data-theme-value="snow-day"]` preview rule (section 9.3) |
| 4 | `ui/style.css` | after Strawberry Cream's sidebar/brand-icon signature-touch block, before the Arcane Library theme's token block | **superseded, then redone same round:** originally the `:root[data-theme="snow-day"] .nav`/`.nav::after` band (section 9.5.1); replaced in place by the `.snow-scene`/`.snow-scene-sky`/`.snow-scene-ground`/`.snow-layer-*` slot rules (section 9.5.4) after Eric's real-capture rejection - old rules fully removed, no dead CSS left behind |
| 4b | `ui/index.html` | immediately after `</nav>`, before the Lofi Night `.lofi-cityscape` block | new: the `.snow-scene` markup (section 9.5.3) - the original touch needed no markup change; the redo does, since it moved from a `.nav::after` decoration to a dedicated flex-slot sibling (same technique as `.arcane-hero`) |
| 5 | `ui/app.js` | `THEMES` array, last position | append `{ slug: "snow-day", name: "Snow Day" }` (section 9.6) - `DEFAULT_THEME` unchanged (`tokyo-rain`, section 8) |
| 6 | `ui/app.js` | `isKnownTheme(v)` | no logic change - already derives from `THEMES` |
| 7 | `ui/index.html` | swatch markup / any hardcoded theme list | none found for the theme picker itself - it is fully driven by `THEMES` via `Views.settings.buildThemeGrid()` (section 4), confirmed by inspection (the `.snow-scene` markup added per row 4b is signature art, not picker markup) |
| 8 | `tests/spa/harness.js` | fresh-profile theme-grid assertion (~line 559) | tile count 15 -> 16; expected order array gains `"snow-day"` at the end |
| 9 | `tests/spa/theme-audit.js` | `THEME_SLUGS` | gains `"snow-day"` at the end; header comment "15 themes" -> "16 themes". No `CONTRAST_FLOOR_OVERRIDES` entry added - Snow Day is not a default theme, so it is correctly held to the generic 4.5 floor `DEFAULT_FLOORS` already applies, which section 9.4 shows it clears by a wide margin even against the stricter floors |
| 10 | `tests/spa/Run-ThemeAudit.ps1` | `$Script:ThemeSlugs`, header comments, the `contrast pass: all N themes audited` result name | gains `'snow-day'` at the end; "15" -> "16" throughout |
| 11 | `THEMES-SPEC.md` | this section | new section 9 |
| 12 | `CHANGELOG.md` | Round 31 entry (section 8's entry, already opened by the round's first change set) | append the Snow Day paragraph |
| 13 | `VERSION` / `addon-server.ps1` `$Script:Version` | version string | `1.12.0` |

### 9.8 Acceptance checklist

- [ ] `ui/app.js`'s `THEMES` array has `snow-day` appended after `strawberry-cream`, nothing else reordered; `DEFAULT_THEME` is still `"tokyo-rain"`.
- [ ] `isKnownTheme` and the swatch-grid picker derive from `THEMES` with no separate hardcoded list needing an update (confirmed - none exists).
- [ ] `ui/style.css` carries the section 9.3 token block verbatim and the `.select` chevron override, scoped to `:root[data-theme="snow-day"]`; the section 9.5.4 `.snow-scene` signature touch is present and the superseded 9.5.1 `.nav`/`.nav::after` rules (and their `snow-day-nav` container and `snow-day-drift` keyframes) are fully removed, not left as dead CSS.
- [ ] `ui/index.html` carries the section 9.5.3 `.snow-scene` markup immediately after `</nav>`, before the Lofi Night block; `.snow-scene` is `display: none` on every other theme (confirmed on `arcane-library` and `lofi`).
- [ ] `.theme-swatch[data-theme-value="snow-day"]` renders the correct preview colors in Settings > Appearance.
- [ ] Live-computed contrast audit passes Snow Day against the generic 4.5:1 floor `tests/spa/theme-audit.js` applies to non-default themes (section 9.4 shows it in fact clears the stricter default-theme floors too, with no hex change needed).
- [ ] The snowfall signature touch never overlaps the status dot, the nav buttons, or the wordmark, at 845x539 and 2024x1273, both single-flavour and `flavours=3` (section 9.5.5 - four configurations, all verified). (Round 34, 2026-09-07: this checklist line originally also named the "Update & Play" button - removed entirely at Eric's request along with every launch-WoW feature, see CHANGELOG.md; the pixel geometry throughout this section's own tables needs live re-measurement against the button-free sidebar - see CS-R21 in the removal spec - not yet done as of this pass.)
- [ ] The scene disappears cleanly (no partial/clipped remnant) when `.snow-scene`'s own real height drops below the `@container snow-scene (max-height: 109px)` threshold (verified live at flavours=3/845x539, where the box is 74px).
- [ ] Only `transform`/`opacity` are animated in the signature touch (the three `.snow-layer` drift loops); it is static under `prefers-reduced-motion: reduce`.
- [ ] `.arcane-hero` (Arcane Library) and `.lofi-cityscape` (Lofi Night) render pixel-identical to their pre-existing geometry at 845x539 - unaffected by the `.snow-scene` addition.
- [ ] Every one of the other 15 existing theme blocks (including Tokyo Rain and Arcane Library from section 8) is byte-for-byte unchanged.
- [ ] Swatch-grid picker renders 16 themes, Snow Day last, in the section 9.6 order.
- [ ] `tests/spa/harness.js`'s theme-grid assertion expects 16 radios in the section 9.6 order.
- [ ] `tests/spa/theme-audit.js`'s `THEME_SLUGS` includes `snow-day` last; `CONTRAST_FLOOR_OVERRIDES` is unchanged (still only `tokyo-rain`/`arcane-library`).
- [ ] `tests/spa/Run-ThemeAudit.ps1`'s `$Script:ThemeSlugs` includes `snow-day` last; the audit reports 16/16 themes passing and writes `tests/theme-screenshots/theme-snow-day.png`.
- [ ] `CHANGELOG.md`'s Round 31 entry carries this section's paragraph alongside section 8's default-flip summary.
- [ ] `VERSION` and `addon-server.ps1`'s `$Script:Version` both read `1.12.0`.
- [ ] The app icon, the host, the server, the CLI, and the CurseForge/tray code are untouched by this change set.
- [ ] The app's default theme is still Tokyo Rain (section 8) - Snow Day does not change it.

## 10. Round perf fix — decorative animation CPU (2026-09-08, perf-remeasure:webview2-gpu-cpu-4-anim-elements)

Follow-up to round 3's decorative-animation-gating fix (section 3611 of `ui/style.css`, "Decorative animation gating"), which stops every theme's signature-touch animation while the window is unfocused/backgrounded or WoW is running, but never addressed the cost of those same animations while the window IS focused and no game runs. A same-session measurement pass (scratch `addon-server.ps1` on port 47902, fixture wowroot, no fake/real WoW, default 1056x720 window, 20s warm-up, 40s foreground sample via `tests/perf/Measure-Furphy.ps1`) found all 9 animated themes well over Eric's 1.5 CPU-s/60s target, driven by two things: (1) themes running several independently-timed CSS animations concurrently on the same inline `<svg>` (Arcane Library: 8; Lofi Night: 5) cost far more than their per-animation share, since each instance triggers its own per-frame style-recalc/paint-invalidation pass; (2) Strawberry Cream's `sc-sparkle` animated `filter: drop-shadow()` directly, the one animated property in this file with no compositor-only fast path. This section's fix, applied to every one of the 9 animated themes, keeps the gating above completely untouched (still the primary defence) and changes only the animation's *cost* while it legitimately plays — never its keyframe values, colors, or art — so the at-rest look is unaffected: verified with a static `python -m http.server` serve of `ui/` at 845x539 in all 9 themes, before vs after, pixel-identical in every case (screenshots not checked in — a live re-run reproduces them from this note).

**What changed, every theme (steps() holds most frames flat instead of interpolating every vsync — a flicker/twinkle/breathe already reads as discrete beats, so this costs nothing visually; `will-change` promotes each animated element once up front instead of promote/demote churn across concurrent instances):**

| Theme | File:line (`ui/style.css` unless noted) | Change |
|---|---|---|
| Lofi Night | :2746-2765 | `lofi-twinkle` (4 stars) `ease-in-out` → `steps(6)`; `will-change: opacity` added to all 4 stars. `lofi-tail-sway` left on smooth easing (a sway reads mechanical if stepped) but gained `will-change: transform`. |
| Arcane Library | :3618-3625 (flame/motes), :3755-3773 (tail/eyes/glow), :3595-3608 (`.arcane-alcove` cap) | `arcane-flame-flicker` → `steps(6)`; `arcane-mote-drift` (×3) → `steps(8)`; `will-change` added to all 8 animated selectors (flame, 3 motes, tail, 2 eyes, glow) — tail/eyes/glow keep smooth easing, only `will-change` added. `.arcane-alcove` height changed from `inset:0`/`height:100%` to bottom-anchored `height: min(100%, 280px)` (same ceiling/technique `.arcane-hero-cat` already used), closing the asymmetry the round-21 fix left open — a genuinely tall `.arcane-hero` (500-1000px on Eric's real window per this file's own history comments) can no longer scale the animated flame/motes' own render area past what was measured. Verified at rest: 845x539 real height 263px (below the 280px cap — no visual change); 1400x900 (`tests/spa/Run-ThemeAudit.ps1`'s own screenshot-pass window) real height 624px — the cap *does* engage there, same accepted "art stops growing rather than scale unboundedly" tradeoff already used for `.arcane-hero-cat` and Snow Day's own layers, not a new pattern. |
| Terminal Green | :2830-2840 | `terminal-flicker` → `steps(4)`; `will-change: opacity` on the 3 synced targets (brand-name, active nav item, accent buttons). Lowest priority — already the cheapest animated theme measured. |
| Matcha | :2961-2969 | `matcha-steam` → `steps(8)`; `will-change: opacity, transform` on `.sidebar::after`. |
| Desert Night | :3018-3026 | `desert-twinkle` → `steps(8)`; `will-change: opacity` on `.sidebar::before`. |
| Tokyo Rain | :3053-3100 | Split the single animated `.sidebar::after` (rain-streak grid + 2 neon blobs, both masked, whole layer pulsing) into a static `.sidebar::before` (the streak grid only, `opacity: .7` baked in — matches the old layer's own 0%/100% keyframe value exactly, scoped inside the same `no-preference` media query so `reduced-motion` still falls back to the pseudo-element's own default `opacity:1`, unchanged) and an animated `.sidebar::after` (the 2 blobs only, `tokyo-pulse` → `steps(8)`, `will-change: opacity`) — the compositor now only has to re-touch the small blob region each frame, not the full-width streak grid too. The finding's own confirmed regression driver (`tests/spa/harness.js`'s dedicated "tokyo-rain's .sidebar::after ... is specifically covered" check) still passes — the gated element is unchanged, just narrower content. |
| Aurora Sky | :3158-3205 | Same split technique: the outer green/pink ellipses move to a static `.sidebar::before` with the old animation's own 0%/100% keyframe (`transform: translateX(-8px); opacity: .85`) baked in as a static value *inside* the `no-preference` media query (so `reduced-motion` still falls back to the pseudo-element's own default `transform:none; opacity:1`, matching the old single-layer fallback exactly); only the middle violet "breathing" ellipse keeps animating, alone, on `.sidebar::after` (`aurora-drift` → `steps(8)`, `will-change: opacity, transform`). |
| Strawberry Cream | `ui/index.html` :54-70 (markup), `ui/style.css` :1037-1040 (`.brand-icon-wrap`), :3230-3270 (`.sc-icon-glow`/`sc-sparkle`) | Replaced the animated `filter: drop-shadow()` on `.brand-icon` itself with the same technique `.arcane-hero-glow` already uses elsewhere in this file: a small pre-blurred glow shape (`.sc-icon-glow`, a `radial-gradient` circle sized/positioned once at rest via a new `.brand-icon-wrap` positioning wrapper — net-zero layout change, same 26x26 slot) layered behind `.brand-icon`, animated via `opacity` only (0 → 1 → 0, `steps(6)`) instead of the blur radius. At rest both old and new sit fully invisible (old: drop-shadow alpha 0; new: `opacity:0`) — pixel-identical. The gating rule (section 3896) and `tests/spa/harness.js`'s CSSOM coverage check both moved from `.brand-icon` to `.sc-icon-glow` accordingly. |
| Snow Day | :3298-3401 | `.snow-scene` gained `max-height: 280px` (same ceiling/reasoning as `.arcane-alcove` above — closes the same latent risk this file's own section 9.5.5 history already flagged, a real tall window's freed flex space reaching 500-1000px). Below the cap nothing changes (verified: 845x539 real height 263px, unaffected; 1400x900 real height 624px, capped). `snow-day-fall-far/mid/near` (`linear`, 24s/16s/11s) → `steps(14)`/`steps(12)`/`steps(10)` respectively — "falling in discrete steps" reads as legitimate pixel-snow on this `shape-rendering:crispEdges` theme. `will-change: transform` added to all 3 layers. |

**Before/after CPU, webview2Sum (sum of every `msedgewebview2.exe` child, the dominant cost per the original finding), 40s foreground sample, this session's own shared-desktop environment (not a clean bench rig — see caveat below):**

| Theme | Before (webview2Sum/40s) | After (webview2Sum/40s) | Change | Re-measured this pass? |
|---|---|---|---|---|
| Lofi Night | 11.98 | 7.64 | −36% | yes |
| Strawberry Cream | 11.08 | 0.86 | **−92%** | yes |
| Arcane Library | 11.03 | 6.47 | −41% | yes |
| Matcha | 7.58 | — | — | no (steps()/will-change only, same mechanism proven on the themes above) |
| Tokyo Rain | 6.73 | — | — | no |
| Desert Night | 6.16 | — | — | no |
| Snow Day | 5.34 | — | — | no |
| Terminal Green | 5.02 | — | — | no |
| Aurora Sky | 4.50 | — | — | no |
| *(static floor, this session, for reference)* | ~0 | 0.08 (`dark`, re-measured this pass) | — | — |

**Honest result against Eric's 1.5 CPU-s/60s target:** Strawberry Cream now sits essentially at this session's own static floor (0.86 vs a 0.08 floor) — comfortably clears the target on any hardware. Lofi Night and Arcane Library are meaningfully improved (36-41% CPU reduction, exactly the mechanism the fix plan called for) but **still measure well above the literal target even after this fix** — their after-numbers (6.47-7.64 CPU-s/40s, ≈9.7-11.5 CPU-s/60s-equivalent) remain roughly 80-95x this session's own static floor, a far larger gap than the ~10x headroom the static themes show elsewhere, so extrapolating to Eric's cleaner hardware does not obviously close it. This matches the original driver analysis: `steps()`/`will-change` reduce the per-frame compositing cost of each animation instance, but do not reduce the *number* of concurrently-running animation instances (8 for Arcane Library, 5 for Lofi Night), which the original measurement identified as the primary cost driver for exactly these two themes. Closing the remaining gap for Lofi Night/Arcane Library would need a further, out-of-scope structural change (e.g. consolidating the staggered stars/motes into fewer independently-composited layers) beyond steps()/will-change/the height cap the fix plan specified; not attempted here since it was not part of the plan handed to this pass. The other 6 animated themes (Matcha, Tokyo Rain, Desert Night, Snow Day, Terminal Green, Aurora Sky) were not independently re-measured this pass — each received only the same steps()/will-change treatment already verified effective on Strawberry Cream/Lofi Night/Arcane Library's single-instance selectors, so a proportionally similar improvement is expected but unconfirmed.

**Environment caveat (matches the original measurement's own note):** this is a shared interactive desktop, not a clean bench rig, so absolute numbers here (including the 0.08 CPU-s/40s static floor) run several times the numbers Eric's own hardware would show for the same CSS — the relative story (before vs after, same session) is the trustworthy part.

**Verification:** `node --check` clean on `tests/spa/harness.js` (the only JS file touched — two assertions updated: the `:is([data-game-active],[data-window-inactive])` CSSOM-coverage list swapped `.brand-icon` for `.sc-icon-glow`, matching the markup/CSS change above); `tests/spa/Run-ThemeAudit.ps1` 500/500 checks passed (16/16 themes, every contrast pair, all 16 screenshots written — contrast reads CSS custom-property tokens only, untouched by this change set); `tests/spa/Run-SpaHarness.ps1` standalone 236/236 passed, including the updated decorative-gating and reduced-motion CSSOM phases; before/after pixel comparison at 845x539 in all 9 touched themes, identical in every case; Lofi Night/Strawberry Cream/Arcane Library re-measured live per the table above. `tests/run-all.ps1` was never run (its hygiene sweep would have killed the concurrent 2-hour soak on port 47908 — out of scope for this pass regardless).

### 10.1 Round-2 verification-pass follow-up (2026-09-08, fixer round 1) — element-count correction, arcane consolidation, and an honest miss on Lofi Night

An independent verifier's own 60s-duration re-measurement (per the task's own `-DurationSec 60` instruction, not this file's own 40s samples) confirmed none of the 6 measured themes cleared the 1.5 CPU-s/60s target after section 10's fix, and made one precise factual correction: `ui/index.html` (then lines 242-255) had **14** independently-animated `<rect class="lofi-star-N">` elements, not the 4 section 10 and the original driver analysis both describe (4 timing classes, reused across 14 positions — every element sharing a class already ran the *identical* animation-duration/delay, so nothing about the twinkle's actual look depended on there being 14 separate elements). Arcane Library's documented 8-element count was independently re-verified as accurate.

**What changed:**

| Theme | File:line | Change |
|---|---|---|
| Lofi Night | `ui/index.html` (stars), `ui/style.css` :2733-2755 | The 14 `<rect>`s, grouped by the verifier's fix into 4 `<g class="lofi-star-N">` wrappers (14→4 animated elements) as a first pass — live-measured, this barely moved the number (~5% CPU reduction). A second attempt gave all 4 groups the identical timeline (same duration, no delay) — also barely moved it, ruling out "distinct concurrent timelines" as the driver too. **Final fix:** merged all 4 groups into one `<g class="lofi-star-1 lofi-star-2 lofi-star-3 lofi-star-4">` (all 4 legacy classes on one element, so the existing CSS rules/gate/reduced-motion query need no selector-text changes) — 14 real animated elements become 1, plus the separate tail-sway = 2 total, down from 15. Only visual change: all 14 stars now twinkle in unison instead of staggered (still alive, just less staggered — an explicitly sanctioned tradeoff per this round's own brief). |
| Arcane Library | `ui/index.html` (motes, eyes), `ui/style.css` :3606-3627, :3762-3781, :3927-3937 | The plan's own suggested "consolidate staggered motes/eyes into fewer layers": 3 independently-timed `.arcane-mote-1/-2/-3` rects merged into one `.arcane-motes` group (one shared `arcane-mote-drift` instance, motes now drift in sync instead of independently); 2 independently-timed `.arcane-hero-eye-l/-r` rects merged into one `.arcane-hero-eyes` group. The eye merge is provably lossless even mid-animation, not just at rest: both eyes already share identical `y`/`height` (57/11), so the group's own `transform-box:fill-box` center lands at the exact vertical midpoint each eye's own per-element center did, and the blink keyframe only scales Y — pixel-identical squash, just losing the two lids' imperceptible 0.05s offset. Takes this theme from 8 concurrently-animated elements to 5. `tests/spa/harness.js`'s CSSOM-coverage list updated to match the renamed classes (same technique the Strawberry Cream fix used for `.sc-icon-glow` in section 10 above) — net 236→233 checks (5 individual selector checks replaced by 2 group ones), all passing. |

**Live re-measurement (this pass, `-DurationSec 60`, no WoW, My Addons, focused, foreground — same repro shape as the verifier's own):**

| Theme | Before (this session's repro) | After this fix | Change |
|---|---|---|---|
| Arcane Library | ~13.55 total / ~12.44 webviewSum (verifier's own number, this session) | **2.094 total / 1.047 webviewSum** (1 run) | **≈85% cut** — webviewSum now clears the 1.5 target outright; total is close |
| Lofi Night | ~13.34 total / ~12.28 webviewSum (verifier's own number, this session) | 12.032-12.609 total / 10.72-11.42 webviewSum (3 runs, consistent) | **No material improvement** despite the structural fix being real, verified via CDP (`document.getAnimations()` showed exactly 2 running instances after the fix vs 15 before) |

**Honest assessment — Lofi Night's fix did not deliver, and this session does not fully know why.** The element-count correction was real and the consolidation is structurally sound (verified via live `document.getAnimations()` count, not inferred), but three separate live A/B measurements taken while isolating variables gave results that do not fit a simple "cost scales with concurrently-animating element count" model at all: 1 star-group animating with the tail forced off measured ~2.9 CPU-s/60s (right in line with the other single-instance themes' own ~2.9-3.5 range); the *same single element* with the tail also on jumped to ~12; the tail *alone* (stars fully off) measured ~18.8 — higher than either the 1-element or the fully-merged 2-element state, which cannot be explained by any per-instance-cost model. Arcane Library's fix, by contrast, behaved exactly as the concurrent-instance-count theory predicts (8→5 instances, cost cut by 85%). The two themes' animated SVGs differ in one obvious way worth investigating next: Lofi Night's merged star group's children are scattered across nearly the full 232×140 cityscape viewBox (a wide bounding box), while Arcane Library's consolidated groups (3 motes, 2 eyes) each cover a small region — if `opacity` on a `<g>` forces the renderer to isolate that group into an offscreen buffer sized to its full bounding box before compositing, a near-full-canvas group would cost far more to raster/recomposite per frame than a small one, independent of child count. Not confirmed live this pass (out of time — a real WoW client started on this machine partway through this investigation, which stops all further native-window measurement per this round's hard rule) — flagged as the most promising lead for whoever picks this up next, along with a genuinely useful, *this session's own* single-instance reference point (~2.9-3.5 CPU-s/60s across three different themes' own single animated elements) worth checking any further Lofi Night fix against.

**Environment note, sharper than section 10's own caveat:** this session discovered mid-investigation that the mandated 2-hour soak (`tests/perf/Soak-Furphy.ps1 -Minutes 120 -Port 47908`, plus a `WagoStubServer.ps1` it depends on) was actively running throughout every measurement in this pass (confirmed via live `Win32_Process` inspection, not inferred) — a known, named, identified source of background CPU/GPU contention on this shared desktop, not just generic "other stuff running." The soak's own periodic sampling (`-SampleIntervalMinutes 5`) is a plausible source of the bursty, non-monotonic swings this session's own A/B tests hit (e.g. the tail-alone-costs-more-than-everything-together result above). The verifier's own before-numbers this section compares against were measured under the same concurrent soak (overlapping timestamps), so the large before/after deltas (Arcane Library's 85% cut) are probably still trustworthy — the soak's noise is common to both sides of that comparison — but small deltas (Lofi Night's ~5-10% swings between structurally-different variants) should not be trusted at all from this session's data alone. Recommend re-measuring both themes again once the soak completes, or on genuinely idle hardware, before drawing further conclusions.

**Verification:** `node --check` clean on `ui/app.js` and `tests/spa/harness.js`; `tests/spa/Run-SpaHarness.ps1` standalone 233/233 passed (236 minus 3, from collapsing 5 individual arcane mote/eye selector checks into 2 group ones — expected, not a regression); `tests/spa/Run-ThemeAudit.ps1` 500/500 passed, 16/16 screenshots written, Lofi Night and Arcane Library screenshots visually inspected directly (Read tool) against the pre-fix versions — pixel-identical at rest in both. Live CPU re-measurement via a scratch `addon-server.ps1`/`FurphyHost.exe` pair on port 47902 (this round's assigned fixer port), `tests/perf/Measure-Furphy.ps1 -ScopeRoot` restricted to each run's own scratch root, 20s warm-up + 60s sample, no fake/real WoW, cleaned up via each script's own `finally` block (confirmed: no scratch process or `tests\.tmp` directory left behind by this session). Live-safety snapshot (Run key, live `FurphyHost.exe` pids, production install file count, Installed-Apps registry key) taken before and after this pass: identical in every field — the live install and its running tray (pid unchanged) were never touched. Stopped all further native-window testing the moment a real `Wow.exe` process was observed on this machine, per this round's hard rule.

### 10.2 Round-2 fixer follow-up (2026-09-08) - bbox-split experiment for Lofi Night, the webviewSum-vs-Total question resolved, and a second blocked measurement pass

Handed 4 verifier failures. Root-cause work below; live re-measurement on all 4 remained blocked the entire session by the same hard rule as the prior round: a real Wow.exe (pid 43312, started 9/8 11:31 AM) was running at session start and was STILL running, same pid, at every recheck through session end - never launched a native scratch FurphyHost.exe window, per the rule ("never launch a window while WoW is running - defer and say so").

**Failure 1 (Lofi Night, primary) - bbox-split experiment implemented, structurally verified, NOT live-measured.**

Section 10.1's own leading hypothesis (a `<g>` opacity animation forcing an offscreen compositing buffer sized to its bounding box) was never tested live because WoW started mid-investigation last round. Re-reading that section's full data with the bbox variable specifically in mind actually resolves an apparent contradiction in its own numbers and gives this a stronger theoretical footing than "untested hypothesis":

- The ORIGINAL pre-round-2 markup (14 separate `<rect class="lofi-star-N">` leaf elements, each individually animated, each with a tiny ~2x2px own bbox) cost ~12.3-13.3 CPU-s/60s - the worst measured state.
- The FINAL round-2 fix (all 14 rects merged into ONE `<g>`, one animation instance, but that group's bbox is the union of all 14 scattered positions - x=14 to x=188 of a 232-wide viewBox, 81% of the width) cost 12.03-12.61 CPU-s/60s - essentially unchanged.
- The one clean single-instance reference point (one of the four intermediate timing-class groups, isolated, others forced off) cost ~2.9 CPU-s/60s, in line with other themes' single-instance baseline.

Many concurrent small-bbox instances (14) and one concurrent huge-bbox instance (1) both measured badly, at almost the same magnitude, while one small-bbox instance measured well. That is exactly consistent with cost having two additive components - a per-animating-instance overhead (dominates when instance count is high) and a bbox-driven raster/composite cost (dominates when any single instance's bbox is large) - rather than either factor alone. Neither section 10 nor 10.1 isolated a state with BOTH few instances AND small bbox per instance; that is the untested cell this round targets.

**Change made (`ui/index.html`, the `.lofi-star-1/-2/-3/-4` group, ~line 281-341; `ui/style.css` unchanged - no selector text changed, same 4 rules/gate/reduced-motion query apply):** split the single merged `<g>` back into 3 `<g>` elements grouped by spatial position (not by the old timing-class assignment), each carrying the same 4 legacy class names and therefore the exact same shared timeline (3.6s, `steps(6)`, no delay - still a perfect-unison flash, zero staggering, matching the current look frame-for-frame). Measured bbox via `getBBox()` in an isolated headless Chromium instance (this session's own browser tooling, serving `ui/` statically on 127.0.0.1 - NOT WebView2, NOT touching WoW or any Furphy process, purely a DOM/CSS geometry check):

| Group | Children | x range | bbox width | bbox height |
|---|---|---|---|---|
| Old (merged) | 14 | 14-188 | 176px (81% of 232) | 28px |
| New group 1 | 6 | 14-74 | 60px | 26px |
| New group 2 | 5 | 92-148 | 56px | 23px |
| New group 3 | 3 | 158-190 | 32px | 22px |

Each new group's bbox is 3-5.5x narrower than the old merged group's, while instance count goes from 1 to 3 (plus the separate tail = 4 total concurrently-animating elements, up from 2). This is a genuine, honest tradeoff, not a free win: if the theory above is right, the bbox reduction should cut cost substantially; if concurrent-instance-count is the dominant term after all (as section 10.1's own literal conclusion argued, before this round's re-reading), going 1->3 instances could partly offset that gain. Back-of-envelope, this could land anywhere in the range of the ~2.9 single-instance baseline times 3 (about 8.7) down to something close to the target if bbox dominates more strongly than instance count - genuinely unknown without a live sample, and stated as such rather than claimed as a fix.

**Verification performed without a live scratch window:** `node --check` clean (`ui/app.js`, `tests/spa/harness.js` - neither touched, listed for completeness); `tests/spa/Run-SpaHarness.ps1` standalone 233/233 passed (unchanged from pre-edit baseline - selector-text coverage, not element count, so the split needed no test changes); `tests/spa/Run-ThemeAudit.ps1` standalone 500/500 passed, 16/16 screenshots written, `theme-lofi.png` visually inspected - cityscape, stars, moon, both cats render intact, no layout breakage from the group split; `document.getAnimations()` in the same isolated headless Chromium instance confirmed exactly 4 running instances (3 star groups + tail) post-change, all 4 at `currentTime: 0` in lockstep (confirms the synchronized-timeline design held - no staggering was introduced). ASCII-only confirmed (grep for non-ASCII bytes in the touched file found only one pre-existing unrelated line, untouched by this change).

**What this is NOT:** a live CPU number. The headless Chromium instance used above is this session's own isolated browser tooling, not WebView2/FurphyHost, and produces no comparable CPU-seconds figure - it was used strictly for DOM/CSS geometry and animation-count verification, not performance measurement. The only way to get a real number is `tests/perf/Measure-Furphy.ps1` against a live scratch FurphyHost.exe window, which remains blocked on WoW. **Next step for whoever measures next:** 20s warm-up + 60s foreground sample, Lofi Night, this build. If it lands under 1.5, done. If it's improved but still over, the two data points above (14-tiny-instances-bad, 1-huge-instance-bad, 1-small-instance-good) suggest going further in the same direction - fewer than 3 groups (2, each covering roughly half the width) or tighter spatial clustering - before concluding the theory is wrong.

**Failure 2 (Arcane Library) - the webviewSum-vs-Total ambiguity is resolved, by code, not judgment call.**

`tests/perf/Perf.Tests.ps1` lines 86-87 settle this definitively - it is the project's own existing, already-shipped perf-regression-test threshold, not something either fixer round invented:

```
$Script:TotalCpuMaxSec = 1.0             # minimized steady-state It: total across EVERY Furphy-scoped process (server+tray+host-window+webview2 children), not just server/tray
$Script:ForegroundTotalCpuMaxSec = 1.5   # foreground It, 60s window: fixNote's own verified after-fix number is 0.312 CPU-s and the historical pre-regression P0-P2 baseline is 0.516 CPU-s/60s - ...
```

Both constants are asserted against `$result.TotalCpuSeconds` (line 274/279, 379/382), which `tests/perf/Measure-Furphy.ps1` (lines 346-372) computes as the sum of `CpuSeconds` across every row it collects - server, tray, host-window, AND every `msedgewebview2.exe` child - i.e. exactly "Total" in the verifier's own terminology, not "webviewSum" (a webview-children-only subset). The comment explicitly ties the historical 0.516 baseline the round's own brief cites to this same Total-style number. **This confirms the round's target is Total, not webviewSum.** Arcane Library's single unconfirmed run (2.094 total / 1.047 webviewSum) has therefore genuinely NOT cleared the bar yet - webviewSum clearing 1.5 does not mean the theme passes. This needed no live measurement to resolve, only reading the test file the target itself was presumably meant to match; it should have been checked before either prior round treated Arcane Library as fixed. A confirming live run (Total, 60s, focused, no WoW) is still needed and still blocked.

**Failures 3 and 4 (six unmeasured themes; the WoW blocker itself) - unchanged, reconfirmed blocked.** Matcha, Tokyo Rain, Desert Night, Snow Day, Terminal Green, and Aurora Sky received only the section-10 steps()/will-change treatment and still have zero post-fix live measurement, by anyone. Wow.exe pid 43312 (same pid the prior round observed) was checked at this round's start, mid-session, and again at end (via Get-Process) - running throughout, no gap wide enough to safely open a scratch window. No code change was made or was needed for these two items; they are pure measurement debt, explicitly the process/logistics item the task itself flagged as "not a code defect."

**Live-safety snapshot, before vs after this round:** identical in every field, checked at both ends via Get-ItemProperty/Get-Process/Get-ChildItem. HKCU Run value: "C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync\host\bin\FurphyHost.exe" --tray, unchanged. Live FurphyHost.exe: only pid 38288 (the live tray, started 9/8 9:15 AM), both times - no other FurphyHost.exe process ever observed or started by this session. Production install folder (...\_retail_\AddonSync) file count: 1260, unchanged. Installed-Apps (HKCU\...\Uninstall\FurphyAddonManager): DisplayVersion 1.20.1, InstallLocation unchanged. No file under Program Files, no HKCU key, and no live process was touched by this session. The only process this session started and stopped was a scratch `python -m http.server` on port 47960 serving this build root's own ui/ directory read-only (for the headless-Chromium bbox/animation-count check above) - confirmed stopped (connection refused) before this report was written.

**Not attempted, flagged for whoever measures next (not out-of-scope, just needs a live window this round never got):** a direct CSS-containment/clip-path experiment as an alternative or complement to the group-split above - e.g. `contain: strict` or an explicit `clip-path` matching each group's real bbox, to see whether that changes the compositor's buffer-sizing decision independent of the DOM split. Also worth trying if the group-split above measures as only a partial win: replacing the `<g>`-level `opacity` animation with per-`rect` `fill-opacity` (visually identical for a plain solid-fill rect with no stroke) - `fill-opacity` is a paint-time property, not a compositor-layer property, so it may sidestep the offscreen-buffer cost entirely at the cost of a small per-frame repaint (14 rects x 4px^2 = 56px^2 total, likely cheap) instead of a GPU composite. Not implemented this round: it is a larger, less conservative change than the task's own suggested next step, and stacking two unverified structural changes in one round with no ability to measure either would make it impossible for whoever measures next to attribute the result to either change.

### 10.3 Round-3 fixer (2026-09-09) - the real driver was never SVG structure: `transform` on an SVG element vs an HTML element, plus a second, smaller "smooth vs stepped" redraw-frequency issue

Handed a fresh live measurement (this session's own MEASURE pass, floor F=0.946, pass line 2.446 CPU-s/60s) confirming Lofi Night (11.296) and Arcane Library (11.25) both still failed by a wide margin, essentially unchanged in kind from every prior round's numbers despite three different structural attempts (14 rects -> 4 groups -> 1 merged group -> 3 spatially-narrow groups for Lofi's stars; 8 -> 5 concurrent instances for Arcane). Also handed an unverified patch (`lofi-arcane-motion-layer-unverified.patch`, saved by an interrupted earlier fixer) implementing section 10.2's own next-step suggestion in spirit but going further: splitting each theme's animated elements out of their big static `<svg>` into a second, small, purely-animated `<svg>` layer stacked on top, so the animated content's own compositing surface never has to share paint work with ~150 (Lofi) or ~30-90 (Arcane) static shapes. Applied and live-measured it first, per this round's own "measure it; keep it only if it moves the number" instruction.

**Step 1 result: the motion-layer split did not move the number.** Lofi Night measured 11.094 total (vs 11.296 before, within noise) and Arcane Library 10.469 total (vs 11.25 before, also within noise) - a fourth structural variant, and a fourth non-result. This directly falsified the leading hypothesis every round since section 10.1 had converged on (shared-compositing-surface / bounding-box size as the cost driver): moving the animated `<g>`s into their own dedicated, small `<svg>` sibling - genuinely isolating their paint surface from the ~150 static shapes - changed nothing measurable. The kept-but-ineffective split (still in the tree; see `ui/index.html`'s `.lofi-motion-layer`, `.arcane-alcove-motion-layer`, `.arcane-hero-glow-layer`, `.arcane-hero-motion-layer`) turned out to matter for a completely different reason below (it is what made the real fix's DOM surgery straightforward), but on its own merits as a perf fix it was a dead end.

**Step 2: live CDP tracing (not more structural guessing) found the actual driver.** Rather than trying a fifth structural variant blind, this round attached Chrome DevTools Protocol directly to a live scratch `FurphyHost.exe` (`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=...`, a standard WebView2 env var requiring no host code change) and used the `Tracing` domain to capture real 3-4 second traces while toggling individual animations on/off via injected `<style>` overrides (Runtime.evaluate) - the same live scratch app this round's own measurements otherwise used, never a separate/unscoped instance. First finding: with every Arcane/Lofi animation forced off, `Document::recalcStyle`/`UpdateLayoutTree`/`PaintArtifactCompositor::Update` dropped from ~660 occurrences per 4s (one full style+layout+paint+commit pass on essentially every vsync, ~165Hz on this machine) to 0-1 - a ~200x reduction, and RunTask's own summed duration fell from 4.7s to 0.02s over the same 4s window. Turning animations back on ONE AT A TIME then isolated the actual variable no prior round had tested: **`opacity` animations on an SVG element (`arcane-flame`, `arcane-hero-glow`, the Lofi stars) get the normal, cheap compositor-only path (0-1 layout passes even over a multi-second sample) - `transform` animations on an SVG element (`arcane-motes`' `translateY`, `arcane-hero-tail`'s `rotate`, `arcane-hero-eyes`' `scaleY`) force a full main-thread style+layout+paint pass on literally every frame, regardless of instance count, bounding-box size, or which `<svg>` document they live in.** This explains every prior round's non-result at once: section 10.1's instance-count reduction (14->1) never touched WHICH property was animated; section 10.2's bbox-split never touched it either; this round's own motion-layer split (step 1 above) didn't either - all four rounds optimized a dimension that was never the actual cost driver for the `transform`-animated elements specifically (the pure-`opacity` elements were cheap all along, confirmed directly this round for the first time - `arcane-flame` and `arcane-hero-glow` alone measured 0-1 layout passes even before any of this round's fixes).

**Step 3: the fix - `<div>` inside an SVG `<foreignObject>`, not a bigger/smaller/differently-grouped `<g>`.** A real HTML element's `transform`/`opacity` animation is unconditionally compositor-fast in this WebView2 build (confirmed live: injecting a test `<div>` inside a `<foreignObject>`, animated the same way the SVG `<g>`s were, measured 1 layout pass in a 3-second trace). `foreignObject` was chosen over "wrap in an HTML div positioned via CSS over the whole SVG's box" specifically because it sidesteps a real geometry problem the latter would have introduced: `.arcane-hero-cat`/`.arcane-hero-motion-layer` use `preserveAspectRatio="xMidYMax meet"` (uniform scale, but frequently letterboxed - the 116x158 viewBox rarely matches a real sidebar's aspect ratio, so there is real empty space on one axis) - an HTML wrapper positioned via plain CSS over the SVG's own absolute-fill box would rotate/scale around a point expressed as a percentage of the WRONG box (the letterboxed canvas, not the actual content), visibly shifting the pivot. A `<foreignObject>`, by contrast, is positioned via the SVG's own x/y/width/height attributes in the SAME coordinate system as every sibling shape - the ambient scale AND any letterbox offset are inherited automatically, not something this fix has to compute, so choosing the `foreignObject`'s own box to tightly bound just the moving part (not the whole canvas) and then using percentage-based `transform-origin`/`translateY` against THAT box is an exact conversion, not an approximation, for every "meet"-scaled element (`.arcane-hero-tail`, `.arcane-hero-eyes`) - uniform scale commutes with rotation and with same-axis scaling, so this holds regardless of the ambient scale or letterbox at any real window size.

**Elements converted from an animated SVG `<g>`/`<ellipse>` to a `<div>` inside a `<foreignObject>` (`ui/index.html`), CSS animation rules unchanged except as noted below (`ui/style.css`):**

| Element | Old target / property | New foreignObject box (viewBox units) | Origin/exactness notes |
|---|---|---|---|
| `.lofi-cat-tail` | SVG `<g>`, `transform: rotate()`, origin `178px 80px` | `x=176 y=63 w=10 h=21` | `.lofi-cityscape`/`.lofi-motion-layer` use `preserveAspectRatio="none"` with a FIXED `height:140px` (matches the 140-tall viewBox exactly, so the y-scale is always exactly 1) and a variable x-scale (`width:100%` of the sidebar). Percentage-origin conversion (`20% 80.95%`) is exact for the origin POINT; the one honestly-disclosed, minor imprecision is that rotating a `<div>` (post ambient x-scale) is not bit-identical to rotating a `<g>` (pre ambient x-scale) under a NON-uniform (anisotropic) scale - the two orders only coincide exactly when x-scale equals y-scale. Since y-scale is pinned at 1 and the sidebar's real width is normally close to the 232px reference width, this is a small, likely-imperceptible warp-order difference on a tiny (+-5deg) sway, not a change to color/shape/position/size/duration. |
| `.arcane-motes` | SVG `<g>`, `opacity` + `transform: translateY(-5px)` | `x=30 y=8 w=122 h=94` (padded 10 units above the motes' own resting position so the upward keyframe travel never reaches the box edge) | `.arcane-alcove`/`.arcane-alcove-motion-layer` also use `preserveAspectRatio="none"`, but this is a pure translation, not a rotation - `translateY(-5px)` became `translateY(-5.3191%)` (`-5/94*100`), and a percentage `translateY` resolves against the element's OWN border box, which is an EXACT restatement of the same 5-unit motion regardless of the ambient scale (scale-then-translate-by-a-percentage-of-the-scaled-size is mathematically identical to translate-then-scale, for a pure translation - unlike rotation, order doesn't matter here). |
| `.arcane-hero-tail` | SVG `<g>`, `transform: rotate()`, origin `101px 112px` | `x=66 y=102 w=50 h=44` | `.arcane-hero-cat` uses `preserveAspectRatio="xMidYMax meet"` (uniform scale) - exact conversion, see Step 3 above. Origin restated as `70% 22.7%` of the new box. |
| `.arcane-hero-eyes` | SVG `<g>`, `transform: scaleY()`, `transform-box:fill-box; transform-origin:center` | `x=38 y=56 w=40 h=13` (padded 1 unit on every side past the eyes' own tight bbox) | Uniform scale, exact. The EXISTING CSS rule (`transform-box:fill-box; transform-origin:center`) needed no change at all - per spec, `fill-box` on a non-SVG element falls back to `border-box`, and the padded box's own center is, by construction, the same point `fill-box`'s bounding-box center used to be. |

**Elements left unchanged (already confirmed cheap - pure `opacity` on an SVG element):** `.lofi-star-1..4`, `.arcane-flame`, `.arcane-hero-glow` (the last one's *timing*, not its target, changed - see below).

**Step 4, a second live-traced finding on top of the first: a smooth (non-`steps()`) transform/opacity animation, even once safely on the HTML compositor path, still forces a real draw+raster+present pass on literally every vsync (496 draws/3s on this machine's high-refresh monitor) because the animated value is never bit-identical two frames in a row.** This is a DIFFERENT cost dimension than Step 2-3's main-thread layout issue - it is pure compositor/GPU redraw work, and it explains why Lofi Night's `total` still measured 5.297 (not near-zero) immediately after the foreignObject fix alone: `.lofi-cat-tail`'s own `lofi-tail-sway` was left on smooth `ease-in-out` in every prior round ("a sway reads mechanical if stepped" - section 10's own words, written when the open question was concurrent-instance count, not per-frame draw cost). Live-measured (`TileManager::PrepareTiles`, `LayerTreeHostImpl::DidNotProduceFrame` counts, 3s traces): forcing the tail to `steps(12)` cut `ProxyImpl::ScheduledActionDraw`'s own duration ~4.5x and let the compositor skip ~95% of frames outright (`DidNotProduceFrame`), while still reading as a fluid sway at 12 steps over a 3.6s/4.6s cycle (~0.3-0.38s per step - about 3x finer than the stars' own already-accepted `steps(6)`/3.6s twinkle). Applied to `.lofi-cat-tail` (`steps(12)`) and `.arcane-hero-tail` (`steps(12)`, same technique). A separate live check confirmed `.arcane-hero-eyes`' own blink keyframe (`0%,92%,100%` all held at the same `scaleY(1)` value, only a brief 92%-95%-100% transition) already gets this same frame-skipping for free, no `steps()` needed - most of its cycle is a genuinely CONSTANT interpolated value, not merely "looks flat." Isolating Arcane Library's remaining 5 elements together (all now on the fast path) still showed every-frame redraws until `.arcane-hero-glow`'s own `arcane-hero-glow-pulse` (the one animation among the five left on smooth `ease-in-out`, continuously changing with no flat span) was found and confirmed, live, as the last always-redraw driver - switching it to `steps()` alone (verified by live-patching just that one rule) took the whole theme's `TileManager::PrepareTiles` count from ~497/3s back down to the ~50-60/3s level the other four already showed. Applied `steps(6)` to `.arcane-hero-glow-pulse` (down from an initial `steps(8)`, matching `.arcane-flame`'s own cadence) and, since 5 independently-timed step cadences running at once still add up to a non-trivial combined "something changed" rate even with none of them individually expensive, also coarsened `.arcane-mote-drift` from `steps(8)` to `steps(6)`. No keyframe VALUES, colors, shapes, positions, sizes, or durations changed anywhere in this step - only timing functions, an explicitly allowed technique.

**Live CPU measurement (`tests\perf\Measure-Furphy.ps1 -DurationSec 60`, this session's own scratch `addon-server.ps1`/`FurphyHost.exe` on port 47921, idle-gated, WoW-checked, focus-confirmed at start/mid/end on every run, zero aborted samples in the rounds reported below):**

| Round | light (F component) | dark (F component) | F = mean | Pass line (F+1.5) | Lofi Night total | Verdict | Arcane Library total | Verdict |
|---|---|---|---|---|---|---|---|---|
| This session's MEASURE pass (before this round's work) | 0.813 | 1.079 | 0.946 | 2.446 | 11.296 | FAIL (4.6x) | 11.25 | FAIL (4.6x) |
| After motion-layer split alone (step 1, kept but ineffective) | - | - | (unchanged) | (unchanged) | 11.094 | FAIL | 10.469 | FAIL |
| After foreignObject fix, before steps() tuning (step 2-3) | 0.531 | 1.469 | 1.000 | 2.500 | 5.297 | FAIL (2.1x) | 3.750 | FAIL (1.5x) |
| After steps(12) tail-sway fix (step 4, Lofi/Arcane tails; Arcane glow still smooth) | 0.531 | 0.766 | 0.649 | 2.149 | 2.265 | FAIL, margin +0.116 (~5% over) | 3.750 *(not re-measured this row; tails-only fix confirmed live via CDP frame-count, not yet via a full 60s CPU sample)* | - |
| After glow/motes `steps(6)` coarsening (final code state), run 2 | 0.703 | 0.734 | 0.7185 | 2.2185 | 1.844 | **PASS, margin -0.375** | *(session ended here - see below)* | - |

**Honest final status - Lofi Night: right at the pass line, best read as a pass.** Two independent 60s live samples of the SAME final code straddle the line in both directions (2.265/FAIL by +0.116 one run, 1.844/PASS by -0.375 the next) against their own runs' own F - averaging both Lofi samples (2.055) against the average of their own pass lines (2.184) puts it comfortably under. Given this file's own repeated caveat about session-to-session noise on a shared desktop (the two `F` values above differ by 0.35, roughly 25% of the pass-line's own 1.5 CPU-s margin), a single-run "FAIL by 5%" next to a same-code "PASS by 17%" is not a real regression between runs - it is noise, and the honest read is "passes, with a margin that is thin enough to want one more confirming sample before calling it fully closed." Compared to session start (11.296, a ~4.6x overshoot), this is an 80-84% reduction.

**Honest final status - Arcane Library: dramatically improved (67% cut, 11.25 -> 3.750) but not re-confirmed at the FINAL code state, and the last live sample available (3.750) still fails by 1.5x.** The foreignObject fix plus the FIRST round of `steps()` tuning (tail only) is what that 3.750 number reflects. The SECOND round of tuning (glow `steps(8)->steps(6)`, motes `steps(8)->steps(6)`) was verified structurally sound the same way every other change in this section was (headless `Run-SpaHarness.ps1` 233/233 and `Run-ThemeAudit.ps1` 500/500 both green after the change, and a live CDP frame-count check - live-patching just the glow rule to `steps(6)` while the real, unpatched app was running dropped `TileManager::PrepareTiles` from ~497/3s back to ~50-60/3s, matching the level the other four already-fixed elements showed) but a live 60s `Measure-Furphy.ps1` CPU-seconds sample of this exact final code was never completed: the attempt aborted cleanly and safely (per this round's own idle-gate contract - the abort discarded the sample and closed the window by pid the moment idle time dropped below the seconds elapsed since launch, confirmed via the live-safety snapshot below, zero processes leaked) when the user returned to the keyboard mid-measurement, and no further native window was opened afterward. **Next step for whoever measures next: one 20s-warmup + 60s-sample live run of Arcane Library against this exact code (no further edits needed) is very likely to land close to or under the pass line given the live-traced mechanism, but is not yet a confirmed number - treat 3.750 as the honest last-confirmed figure for this theme, not the number this section's own code should be judged against.**

**Verification, every step in this round:** `tests\spa\Run-SpaHarness.ps1` standalone 233/233 passed and `tests\spa\Run-ThemeAudit.ps1` standalone 500/500 passed (16/16 screenshots written) after EVERY file edit in this section, no exceptions. Pixel parity at rest verified three separate times with a byte-level diff (Python/Pillow `ImageChops.difference` -> `getbbox()`, not a visual spot-check) between `tests\theme-screenshots\theme-lofi.png`/`theme-arcane-library.png` (1400x900, `Run-ThemeAudit.ps1`'s own window) and the ORIGINAL pre-this-round `ui\style.css`/`ui\index.html` (not merely the previous round's intermediate state) - `getbbox()` returned `None` (zero-byte, zero-pixel difference) for both themes on all three checks, including the final one taken after every change in this section including the `steps()` timing edits (which cannot affect a `t=0` screenshot's own keyframe values, but was re-verified anyway since the underlying markup/CSS also changed). `document.getAnimations()` on the live app confirmed exactly 5 running Arcane instances and 4 running Lofi instances post-fix (same counts as section 10.1 left them at - this round changed WHERE/HOW each animates, never re-touched instance count).

**Idle-gate and WoW-check notes, this round:** every native window launch (4 diagnostic CDP sessions plus 12 `Measure-Furphy.ps1` sampling runs across the "MEASURE", motion-layer-split, foreignObject-fix, and steps()-tuning passes) found the idle gate already satisfied (the machine had been idle 1855s-5916s at each check, growing monotonically until the final aborted run) and zero WoW processes, so the gate never had to actually wait. The ONE exception - the final Arcane Library re-measurement attempt - is the case the idle-gate machinery exists for: it caught real user activity 71 seconds into the window (idle dropped from >5900s to 0s) and reacted exactly per the hard rule, discarding the sample and closing the window by pid before this report was written; no other run in this round or the "MEASURE" pass that preceded it needed the abort path.

**Live-safety snapshot, before this round's work vs after (checked via the same `Get-ItemProperty`/`Get-Process`/`Get-ChildItem` recipe every prior round used, both live via a small PowerShell/C# `GetLastInputInfo` P/Invoke helper written for this round's own idle-gate machinery):** identical in every field. HKCU Run value: `"C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync\host\bin\FurphyHost.exe" --tray`, unchanged both times. Live `FurphyHost.exe`: only pid 23892 (the live tray), both times - no other `FurphyHost.exe` process was ever left running by this round; every scratch instance this round launched (13 native windows total across all passes) was closed by pid, scoped strictly to this round's own scratch root path (`...\measure41d\fix\`), in the launcher script's own `finally` block, confirmed via a full-machine `Win32_Process` sweep for any stray `FurphyHost.exe`/`msedgewebview2.exe` referencing that path after the session's last window closed - none found. Production install folder (`...\_retail_\AddonSync`) file count: 1262 both times, unchanged (this round observed 1262, not the 1261 the task briefing suggested nor the 1397 a same-day sibling session reported - a discrepancy already flagged in that sibling session's own notes as never affecting either session's safety logic, since neither session's process management ever depended on the briefed number, only on what each verified directly; this round's own before/after values agreeing with each other, even though they differ from the briefing, is the property that actually matters). Installed-Apps (`HKCU\...\Uninstall\FurphyAddonManager`): DisplayVersion 1.21.0, unchanged. The scratch server (port 47921, this round's own assigned port) was stopped gracefully via its own `/api/shutdown` endpoint and confirmed exited before this report was written. Nothing under Program Files, no HKCU key, and no live process was touched by this round.

### 10.4 Round-4 fixer, pass 2 (2026-09-09) - no code change; blocked on the idle gate the whole session, machine continuously in active use

Handed VERIFY2's three open items: (1) get a live number for all 11 themes this round, (2) Lofi Night needs one more confirming 60s sample of the exact final code (section 10.3's own two runs straddled the pass line: 2.265 FAIL by +0.116, then 1.844 PASS by -0.375), (3) Arcane Library needs a first live sample of the FINAL code state (last confirmed number, 3.750, predates the glow/motes steps(8)->steps(6) edit, which was only verified structurally).

**Code review first, before touching anything.** Read the current `ui/style.css` and `ui/index.html` end to end against section 10.3's own table. Confirmed the tree already contains the exact final state that section describes: all four foreignObject conversions (`.lofi-cat-tail`, `.arcane-motes`, `.arcane-hero-tail`, `.arcane-hero-eyes`), `.lofi-cat-tail`/`.arcane-hero-tail` at `steps(12)`, and both `.arcane-hero-glow-pulse` and `.arcane-mote-drift` at `steps(6)` (grep-verified line by line, matches section 10.3's table exactly). No further sound idea presented itself beyond what section 10.3's own live-CDP-traced investigation already converged on (that investigation found and fixed the actual mechanism - `transform` on an SVG element forcing full main-thread layout on every frame - not a symptom of instance count or bbox size, so there is no obvious fifth structural variant left to try blind). Given the outstanding work is confirmation, not new engineering, **no edit was made to `ui/style.css` or `ui/index.html` this round.**

**Headless verification of the unchanged code, run fresh this round (not reused from section 10.3's own report):** `tests\spa\Run-SpaHarness.ps1` 233/233 passed. `tests\spa\Run-ThemeAudit.ps1` 500/500 passed, 16/16 screenshots written. Both green, no regression, exit code 0 on both.

**Scratch root readiness check:** `measure41d\fix\ui\style.css` and `measure41d\fix\ui\index.html` diffed byte-for-byte against the build root's current `ui\style.css`/`ui\index.html` - zero differing lines, both files. `measure41d\fix\host\bin\FurphyHost.exe` is the same size as the build root's copy. `measure41d\fix\flavours\retail\addons.json` present (1333 lines). `measure41d\fix\wowroot` present with `_retail_`/`_classic_`/`_classic_era_`/`_ptr_` folders. The three pid files left over from section 10.3's session (`diag.pid`=14256, `diag2.pid`=19672, `server.pid`=19216) were all checked via `Get-Process -Id` and confirmed NOT running - stale, safe, no cleanup needed. A full-machine sweep for `FurphyHost.exe` and for any `msedgewebview2.exe` referencing a scratch path found nothing - the only `FurphyHost.exe` process anywhere on the machine, at every check this round, was pid 23892 (the live tray). The scratch root was fully ready to launch from the start of this round; it was never used to start a server or open a window, for the reason below.

**Idle-gate: blocked for the entire round, not a brief wait.** Idle time was checked at four separate points spanning the session: at start (0.36s), shortly after (0.156s), again after further prep (0.015s), then a dedicated poll loop ran for 481 seconds (8 minutes, 10-second intervals, matching the task's own "log each 5 minutes of waiting" instruction) and idle read exactly 0 for the ENTIRE window with no exception - meaning the user was providing continuous keyboard/mouse input with no gap wider than the poll interval, the whole time. A final check taken after all other work in this round, at the very end of the session, still read idle=0. WoW.exe/WowClassic/etc. were confirmed absent at every one of these checks, so the WoW-check was never the blocker - only the idle gate was. Per the hard safety rule, this means **zero native windows were launched this round.** Not one scratch `FurphyHost.exe` process was started, so there was no live CPU measurement of any kind - not the two controls (light, dark), not Lofi Night, not Arcane Library, not any of the other eight themes.

**Consequence: VERIFY2's items (2) and (3) remain exactly where they were, unchanged by this round - not because of a code problem, but because the desktop was never observed idle long enough to safely open a window.** No new Total60/webview60 number exists for any theme this round. Section 10.3's own last-confirmed figures (Lofi Night 1.844 PASS / 2.265 FAIL straddling the line across two runs; Arcane Library 3.750, predating its own final `steps(6)` edit) are still the most current numbers available for these two themes.

**Live-safety snapshot, before this round's checking vs after (Get-ItemProperty/Get-Process/Get-ChildItem, same recipe as every prior round):** identical in every field, both ends. HKCU Run value: `"C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync\host\bin\FurphyHost.exe" --tray`, unchanged. Live `FurphyHost.exe`: only pid 23892 (the live tray), both times - no other instance was ever running, since none was ever started. Production install folder (`...\_retail_\AddonSync`) file count: 1262, unchanged, matching section 10.3's own observed value (not the 1261 the task briefing states - a discrepancy already flagged in section 10.3 and reconfirmed here, still never affecting safety since this round's own checks, like every prior round's, never depended on the briefed figure). Installed-Apps (`HKCU\...\Uninstall\FurphyAddonManager`): DisplayVersion 1.21.0, InstallLocation unchanged. Nothing under Program Files, no HKCU key, and no live process was touched this round - there was nothing to stop, since nothing scratch was ever started.

**For whoever measures next:** the code needs no further changes on current evidence - `measure41d\fix\` is fully prepped and byte-verified against the current build root, so the next attempt can skip straight to the idle-gate poll and, once it clears, the launch step. All three remaining open items (a confirming Lofi Night sample, a first final-code Arcane Library sample, and a fresh light/dark F to pair with both) can likely be closed in one sitting once the machine is genuinely idle for 120+ seconds with no WoW process running - this round never got that window.
