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

**Technique:** `.nav` gives up its `flex: 1` (scoped to this theme only — every other theme's `.nav` is untouched) and a new `.arcane-hero` flex sibling, sitting between `</nav>` and `.arcane-alcove` in the sidebar markup, takes over that role instead, so it — not empty space — owns whatever room a tall window frees up. Its inline `<svg class="arcane-hero-cat">` (`preserveAspectRatio="xMidYMax meet"`, bottom-anchored, centered rather than stretched full-width so it reads as a spotlit pedestal) is sized via `height: clamp(110px, 22vh, 160px)`: the 110px floor keeps the default ≈1056×720 window from feeling starved, the 160px ceiling keeps a very tall window's cat from growing without bound. Below a ≈460px window height there is no longer room for nav + a 110px cat + `.sidebar-bottom` without collision, so — the same "vanish rather than overlap" contract every other theme's sidebar decoration already follows — the whole hero slot collapses to nothing instead of crowding or clipping the nav, the CTAs, the status dots, or the wordmark. Motion is a tail sway, an eye blink every ≈6s, and a slow glow pulse, every one of it gated behind one `@media (prefers-reduced-motion: reduce)` block.

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
