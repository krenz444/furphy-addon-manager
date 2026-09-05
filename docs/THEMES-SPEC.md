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
