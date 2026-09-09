WAGO-BROWSE-SPEC.md
Wago category browse - authoritative build spec (Round 32 / Expansion E29)
Synthesized 2026-09-06. Status: ready to build. This document supersedes
nothing on its own authority - section 5 below spells out exactly which
lines of UX-SPEC.md / SPEC.md this build round supersedes, with dated
notes in the existing house style (E22/E23 precedent), so a future audit
sees a recorded decision, not a silent contradiction.

Inputs synthesized: WAGO-BROWSE-RESEARCH.md (live-verified Wago facts),
UI design A ("Store front", the judge's winner) and UI design B ("Browse
by purpose", grafts only), the DATA design (server/snapshot contract),
and the judge's UI review + adversarial data review. All four are
reconciled below; every place this document overrides one of those four
inputs is called out explicitly with the reason, because this file - not
any of the four - is what the build works from.

No file under the build root was modified to produce this document. Five
polite, paced, GET-only live requests were made against addons.wago.io
while writing it, solely to re-confirm behavior already documented in
WAGO-BROWSE-RESEARCH.md (nothing new was discovered that changes that
research's conclusions).

================================================================================
1. ERIC'S ASK AND THE HONESTY DECISIONS
================================================================================

Eric, verbatim: "for wago, i need a really good category based interactive
browsing experience, i want users to be able to sort by popular, new,
categories, rising in popularity, installs during the current season, etc."

| Eric's word          | Verdict                          | Ships as                     |
|-----------------------|-----------------------------------|-------------------------------|
| Popular               | Directly supported, zero extra cost | "Popular" tab (default)     |
| Categories             | Directly supported                | Persistent category chip strip, 29 real categories + All |
| New                    | Not directly supported - no creation date exists anywhere on Wago | "Recently updated" tab (honest substitute) |
| Rising in popularity   | Not available from Wago at any affordable cost | No Wago-backed tab. "Gaining this week" - a Furphy-owned measurement, clearly labeled as such |
| Installs this season   | Not available from Wago in any form (lifetime totals only, no season concept exists) | Not shipped under any label. Never appears as a tab, a meta line, or a tooltip anywhere |

Exact sentences the UI must use wherever something is Furphy-measured or
unavailable (final wording; supersedes any earlier draft in A's, B's, or
DATA's own text where they differ from this - this is the version that
ships):

- Recently-updated scope caveat (tooltip on the tab label, `title`
  attribute, same lightweight pattern the row meta line already uses):
  "Sorted by each addon's own last-updated date, within the current
  results." (graft from B - A's spec only had this in engineering
  prose, never surfaced to the player; UX-SPEC.md's own precedent for
  "explain the mechanism at the point where it matters" backs putting it
  on the control itself, not just in a doc.)
- Gaining-this-week tab tooltip (title attribute): "Furphy's own
  measurement, not a number Wago publishes."
- Gaining-this-week not-ready state - see section 4's "Not-ready copy"
  (this document deliberately REWRITES A's mockup-3 copy; see that
  section for why "Day N of 4" does not survive synthesis).
- Gaining-this-week ready state, page-level currency line (REQUIRED FIX
  from the judge's grafts list, item 5 - neither A's nor B's populated
  mockup rendered this, and it is the cheapest defense against a stale
  figure reading as live): "Based on downloads Furphy measured through
  <asOf, formatted> - looking only at Wago's current top ~150 popular
  addons." (The second clause is a NEW addition over the judge's
  suggested line - see data-review finding 6, "undisclosed scope limit."
  Folding the scope disclosure into the same sentence as the currency
  line means one honest line does both jobs instead of two.)
- Gaining-this-week per-row delta: "+<deltaDownloads formatted> since
  <baselineAsOf, formatted>" next to a leading rank number (graft from B,
  item 4).
- Gaining-this-week category/search non-scoping note (REQUIRED FIX,
  judge item 6, WIDENED - see section 2's states/copy for why this
  covers the search box too, not only category chips): "Gaining this
  week shows Furphy's own top movers across Wago's popular list - it
  isn't split by category or search yet."

Nothing in this build ever uses the words "new," "rising," "trending,"
or "this season" as a label, a tooltip, or a tab name. "Gaining this
week" is the only new-data-adjacent string anywhere in the design, and
every one of its surfaces (tab label tooltip, not-ready copy, ready
copy, per-row tag) says outright that it is a Furphy measurement, not a
Wago one.

================================================================================
2. FINAL UI (winner + grafts + required fixes)
================================================================================

Base design: A, "Store front" (judge's winner, total 8.5 vs B's 5.3).
Grafted from B per the judge's instructions: (1) context-aware search
placeholder, (2) inline tooltip on Recently-updated, (3) "See Popular
instead" escape hatch, (4) leading rank number on Gaining rows. Two
required fixes applied per the judge's data review, plus one additional
fix found during this synthesis pass (widening the category-disable note
to also cover search). One inaccurate citation dropped (the "Versions-tab
Load more precedent" - verified false, see below).

(Superseded 2026-09-08: an earlier revision of this document also listed
a "game-running blocked state" as a second additional fix here. Per
GAME-MODE-SPEC.md, Wago browsing now works fully while a WoW client is
running - that state never existed as shipped behavior for long and is
removed from this document; see section 2's states/copy and section 3.5
below.)

Everything below is scoped to `#browse-wago-panel` inside the existing
`[Wago | CurseForge]` `.source-switch` (`ui\index.html` L651-701). That
switch, `#browse-cf-panel`, the Install/Installing/Installed button, and
`.browse-row`'s DOM/CSS/click-and-keyboard behavior are UNCHANGED by this
round - nothing below touches them.

--------------------------------------------------------------------------------
2.1 Layout, top to bottom
--------------------------------------------------------------------------------

1. Search field - unchanged position/id (`#browse-search`), placeholder
   now context-aware (GRAFT 1 from B): "Search Wago addons..." when "All"
   is the active category, "Search in <Category>..." once a category
   chip is picked (e.g. "Search in Boss Encounters..."). Disabled with
   placeholder "Not available on Gaining this week" whenever the Gaining
   tab is active (see 2.4 "Non-scoping note" - NEW fix, not in any of the
   three inputs, see rationale there).

2. Sort control, `.segmented.wago-sort` (new modifier class on the
   existing `.segmented`/`.segmented-btn` component already shipping for
   Settings > Appearance > Density, `ui\style.css` around the
   `.segmented`/`.segmented-btn` rules) - four segments, exactly one
   `.is-active`, "Popular" first/default:
   Popular | Recently updated | Name (A-Z) | Gaining this week

3. Category chip strip, directly under the sort control. "All" first,
   then one chip per `props.allCategories` entry (29, server order
   verbatim - see 2.2). Collapsed by default (default window: a curated
   subset + "More categories +N"; Eric's window: effectively the whole
   set already fits). During the Gaining-this-week tab, every chip is
   rendered `aria-disabled="true"` and visually muted (no hover lift, no
   pointer cursor) with the non-scoping note shown once above the strip
   (2.4) - this is REQUIRED FIX item 6 from the judge, applied to the
   actual chip markup, not just documented.

4. Result count line - the existing `#browse-summary`/`.list-summary`
   element, copy per 2.5.

5. Results - the existing `.browse-list`/`#browse-grid`/`.browse-row`
   family, completely unchanged DOM/CSS/click/keyboard behavior. Newly
   populated for every row (all four sort tabs): `.browse-row-author`,
   `.browse-row-summary`, `.browse-row-meta` (downloads + updated). On
   the Gaining tab only, two more things appear on the row, both new:
   a leading rank number (GRAFT 4 from B) and a `.chip.chip-success`
   delta badge (A's own choice, reusing an existing class - see 2.6).

6. Load more - one centered `.btn.btn-outline` button under the list,
   text "Load more". Bumps `page` by one, appends 15 rows, hidden once
   `page >= lastPage`. NOTE: earlier drafts of both A's and B's specs
   justified this pattern by citing a "Versions-tab Load more
   precedent." Verified against `ui\app.js` L3229-3230 during this
   synthesis pass: the actual comment there says the OPPOSITE - "the
   Versions tab has no 'load more' affordance of its own anywhere in the
   base spec." That citation is dropped per the judge's grafts item 7.
   "Load more" is a new pattern this round introduces on its own merits
   (avoids scroll-position restoration headaches on a sort/category
   change, matches the plain-button precedent the research doc itself
   recommended) - it does not need a precedent that does not exist.

7. The existing `.browse-fallback` block ("Not on Wago? Try CurseForge" /
   "Or type an addon's CurseForge ID number") - unchanged, unmoved.

--------------------------------------------------------------------------------
2.2 Categories
--------------------------------------------------------------------------------

One chip per `allCategories` entry (29, fixed, `{id, displayName}` only -
no icons, no counts, matching the brief and matching what the API can
actually supply in bulk). Order matches the server's own array order
verbatim, INCLUDING the one out-of-numeric-sequence entry (id 5 "Buffs &
Debuffs" genuinely sorts after id 28 upstream - confirmed live, not a
mockup typo). Exactly one selectable at a time (`category=<id>`, no
multi-select UI, matches the API).

Visual language (icon-free): resting = `var(--bg-2)` fill / `var(--border)`
outline / `var(--text-muted)` label; hover = `var(--bg-3)` fill /
`var(--text)` label / `var(--border-hover)` border / 1px lift; selected =
solid `var(--accent)` fill / `var(--accent-text)` label. This is a NEW
class, `.wago-chip` (A's own CSS, `wago-browse-design.css` L44-62) - it
is deliberately NOT the same as the app's existing `.filter-chip`
component (My Addons' own status filter chips, `ui\style.css` L1354-1381),
which uses a lighter tint-fill selected state (`var(--accent-tint)` +
`var(--accent)` border) appropriate for a secondary table filter. The
category strip is closer to primary navigation for this screen, so a
confident solid fill is the right call and is still built entirely from
existing tokens - no new color anywhere, just a different existing
component to model against. Disabled state (Gaining tab active): `opacity:
0.5`, `pointer-events: none`, `aria-disabled="true"`, no active/hover
transitions.

Overflow: capped subset + trailing "More categories +N" chip
(`.wago-chip-toggle`, dashed border, `var(--text-faint)`, the EXISTING
`#icon-chevron-down` sprite symbol rotated 180deg via `.is-open` - no new
icon asset needed, reuses `ui\index.html` L29's existing symbol) that
expands the rest inline (`.wago-cat-expanded`, plain wrap, hairline
separator), flipping to "Show fewer categories" to collapse. This is
deliberately NOT the existing `.filter-chip-more` popover pattern used in
My Addons (`ui\app.js` L4862-4873, which opens a `Components.Dropdown`) -
categories need to stay visible as clickable pills for "interactive
browsing," not hidden behind a menu; the two overflow patterns coexisting
in the app for two different jobs is fine and not a consistency problem
(My Addons' filters are a lookup; this is primary navigation).

--------------------------------------------------------------------------------
2.3 Sort tabs
--------------------------------------------------------------------------------

- Popular (default) - no `sort=` sent to Wago at all; this IS Wago's own
  default order (download-count descending, verified live).
- Recently updated - honest substitute for "New." Tooltip (GRAFT 2):
  "Sorted by each addon's own last-updated date, within the current
  results." Implementer note carried from the data design: this is a
  PAGE-LOCAL re-sort of whichever page Wago's popularity order already
  returned, not a true global recency sort - the tooltip's wording is
  written to be true under that limitation, not to oversell it.
- Name (A-Z) - forwards `sort=name` unchanged (already correct today).
- Gaining this week - a Furphy-only measurement, never forwarded to
  Wago. Composes with NOTHING except paging - see 2.4.

All four are a discrete click, not free text - no debounce needed,
triggers the same skeleton-then-results sequence a fresh search already
does today.

--------------------------------------------------------------------------------
2.4 States (loading / empty / error / not-ready)
--------------------------------------------------------------------------------

Loading - existing `#browse-skeleton`, now also triggered by a sort or
category click.

Empty (Popular/Recently-updated/Name tabs) - existing `#browse-empty`,
context-aware copy: "No addons in <Category> yet" for a category with
zero matches; unchanged generic copy for an empty free-text search.

Error - existing `#browse-error`/`#browse-error-msg` ("Couldn't reach
Wago right now."), unchanged; a failed sort/category change fails
through this same surface.

(Superseded 2026-09-08: this used to list a fifth "Game-running" state
reusing `#browse-empty` with "Wago browsing pauses while a WoW client is
running" copy, blocking Popular/Recently-updated/Name while WoW ran. Per
GAME-MODE-SPEC.md, Wago browsing works fully while a WoW client is
running - live and cached fetches are always allowed and that state can
no longer occur. Only the four states above remain.)

Gaining this week - non-scoping note (REQUIRED FIX 6, widened): whenever
this tab is active, ONE line appears above the result-count line (reuses
`.chip-info`, `ui\style.css` L1551 - an existing token-only class, no new
color): "Gaining this week shows Furphy's own top movers across Wago's
popular list - it isn't split by category or search yet." The search
field is disabled and the category strip is greyed (2.1/2.2/2.3) for the
same reason - DATA's own contract states sort=gaining "Ignores q and
categoryId" (a hard non-goal, ~29x the request budget to fix); leaving
either control live while it silently does nothing would repeat the
exact class of bug ("a control that quietly does nothing truthful") this
codebase's own principles already forbid elsewhere (UX-SPEC.md section 1).
The judge's review only flagged the category half of this; the search
half follows from the identical contract line and is fixed here too.

Gaining this week - not-ready (REWRITTEN from A's mockup-3; see
rationale below):
  Heading: "Still gathering data"
  Body: "Furphy started measuring daily download changes on Wago on
  <since, formatted>. It needs two snapshots taken 5 to 9 days apart
  before it can show what's gaining - the earliest that could happen is
  <since + 5 days, formatted>."
  Provenance line: "<snapshotCount> snapshot(s) captured so far."
  Button (GRAFT 3 from B): "See Popular instead" - switches the active
  sort tab to Popular, same panel, no navigation.

  WHY THIS REPLACES A's COPY: A's mockup-3 showed a fixed "Day N of 4"
  counter and a 4-dot progress readout. The data design's own readiness
  rule (section 4) is opportunistic and restart-gated - snapshots are
  captured only when the server happens to (re)start, at least 20 hours
  after the last one, and only when WoW is not running - so there is no
  guaranteed daily tick and no fixed "4" to count against. A hard-coded
  countdown would imply a schedule the mechanism cannot promise, which
  is exactly the kind of overclaim section 1's honesty rules exist to
  prevent. The replacement copy states an honest earliest-possible date
  (a lower bound, never a promise) and a real, current snapshot count
  instead. This requires one small additive field on the endpoint
  contract, `snapshotCount` (see section 3) - not present in the
  original data design, added here because the honest not-ready copy
  needs something true to say about progress.

Gaining this week - ready: normal `.browse-row` list, each row gets a
leading rank number (GRAFT 4) and a `.chip.chip-success` delta badge
"+<deltaDownloads> since <baselineAsOf>" (A's own field/class choice,
`wago-browse-design.css` L118-125). Page-level currency + scope line sits
where the result-count line normally goes (see section 1's exact
sentence - REQUIRED FIX 5, widened with the scope clause per data-review
finding 6). Tab label itself carries the tooltip from section 1.

--------------------------------------------------------------------------------
2.5 Copy - result count line
--------------------------------------------------------------------------------

- "<N> results" - unfiltered/searched, N not the capped default.
- "<N>+ results" - the capped unfiltered default (Wago reports total:1000
  as a cap, not an exact count).
- "<N> results in <Category>" - a category is selected (real, uncapped
  total).
- Gaining tab: replaced entirely by the currency/scope line (section 1)
  once ready, or absent during not-ready (the not-ready card replaces the
  whole list area, see 2.4).

--------------------------------------------------------------------------------
2.6 Row fields
--------------------------------------------------------------------------------

`.browse-row-author`, `.browse-row-summary`, `.browse-row-meta` render
whenever the server supplies them (never a blank slot) - these already
exist in `ui\app.js`'s `resultCard` (L5393-5399) and have simply never
received non-null Wago values before (`normalizeWagoEntry`, L5311-5317,
hardcodes them null today - this is the line that changes, see section
6). Meta line: "<N> downloads" (`Utils.formatNumber`, L1312-1315) and
"updated <relative time>" (`Utils.relativeTime`, L1278-1296, with a
`title` tooltip via `Utils.fullDate`, L1298-1303). Both already call
JavaScript's native `Date` parser against whatever string they're given;
confirmed during this synthesis pass that V8 (the WebView2/Edge runtime
this app requires) parses Wago's own "MMM D, YYYY" date strings (e.g.
"Aug 18, 2026") correctly with no reformatting needed - so keeping
`updatedAt` as Wago's raw human string (the data design's own choice,
"display what the source gave us") works with these two existing
helpers unmodified, zero new date-parsing code needed client-side.

Gaining-tab-only additions: leading rank number (plain `<span>`, no new
class needed beyond a small layout rule) and the `.chip.chip-success`
delta badge. The row's own "<N> downloads / updated X ago" meta line
stays underneath, untouched - the real all-time Wago figures are never
displaced by the estimate, on any tab.

--------------------------------------------------------------------------------
2.7 Sizes / mockups
--------------------------------------------------------------------------------

A's three existing mockups remain the visual reference for the shipped
layout at both required window sizes:

- C:\...\scratchpad\specs\wago-design\A\mockup-1-default-popular.png
  (845x539 CSS px - Popular, All categories, collapsed strip)
- C:\...\scratchpad\specs\wago-design\A\mockup-2-eric-window.png
  (2024x1273 CSS px - Popular, categories expanded, PvP selected, live
  "116 results in PvP")
- C:\...\scratchpad\specs\wago-design\A\mockup-3-gaining-this-week.png
  (845x539 CSS px - Gaining tab's not-ready state; COPY IN THIS PNG IS
  SUPERSEDED by 2.4's rewritten not-ready copy above - the layout shape
  is still the reference, the "Day N of 4" text and 4-dot readout are
  not; whoever implements this screen should build to the copy in this
  document, not to the pixels in this one PNG)

No new mockup PNGs were produced by this synthesis pass (out of scope for
a spec-writing round; the deltas from A's mockups are small and are
fully specified in prose above - context-aware placeholder, one tooltip,
one currency/scope line, one non-scoping note, disabled chips/search on
the Gaining tab, rank number + delta badge, and the rewritten not-ready
copy). The build agent should treat 2.1-2.6 above as authoritative over
any pixel that conflicts with it.

Note carried forward for whoever finalizes copy: this design supersedes
UX-SPEC.md 5.1's "no category filter, no sort dropdown, no pagination on
the Wago segment" line and section 11's matching checklist item - see
section 5 for the exact dated supersession text.

================================================================================
3. SERVER: /api/wago/browse CONTRACT
================================================================================

Route: evolves `Handle-WagoSearch` (`addon-server.ps1` L4273-4334) into
`Handle-WagoBrowse` (rename the function; keep every existing line of
logic it already has, add to it per below). Register BOTH patterns
against the renamed function so `/api/wago/search` keeps working
byte-for-byte for any existing caller/mock fixture (additive, matches
this codebase's own "supersede, never silently break" pattern, E22/E23):

  $Script:Routes (L6981-6982 today):
    @{ Method='GET'; Pattern='^/api/wago/search$';  Handler='Handle-WagoBrowse' }
    @{ Method='GET'; Pattern='^/api/wago/browse$';  Handler='Handle-WagoBrowse' }

  $Script:FlavourScopedEndpoints (L995-1003 today, wago/search already
  present at L1003):
    @{ Method='GET'; Pattern='^/api/wago/search$' }
    @{ Method='GET'; Pattern='^/api/wago/browse$' }

Both tables must be updated together - the startup self-check at
L7150-7156 (`STARTUP SELF-CHECK FAILED: FlavourScopedEndpoints entry ...
matches no registered route`) already exists specifically to catch a
mismatch here; a test asserting it never fires is in section 7.
`/api/wago/categories` (`Handle-WagoCategories`, L4336-4349) is
UNCHANGED.

--------------------------------------------------------------------------------
3.1 Params
--------------------------------------------------------------------------------

- `q` - unchanged, forwarded to `search=` when non-empty.
- `categoryId` - forwarded as `category=` ONLY if it matches `^[0-9]+$`;
  anything else is treated as absent (hardening over today's
  verbatim-forward). Never forwarded when `sort=gaining`.
- `sort` - four-way enum, never trusted verbatim: omitted / empty / any
  unrecognized value (including stale client values like `rising` or
  `trending`) -> treated as "popular," no `sort=` sent (absorbs old
  client builds exactly as `Handle-WagoSearch` already does - regression
  test required, see section 7). `name` -> forwarded verbatim. `updated`
  -> see 3.2. `gaining` -> see section 4, zero live calls.
- `page` - `[int]::TryParse`; non-numeric or <=0 clamps to 1 (hardening
  over today's blank-only substitution). For live-fetch sorts, forwarded
  to Wago's `page=`. For `gaining`, indexes the local ranked array; a
  page past the local last page returns an empty `items` array with
  `total`/`lastPage` still correct - not an error.
- `flavour`/`flavor` - NOT read here; resolved once per request by the
  existing `Resolve-RequestFlavour`/`Set-CurrentFlavourContext` pair
  before `Handle-WagoBrowse` ever runs (identical to `Handle-WagoSearch`
  today) - no new code needed in the handler for this.

--------------------------------------------------------------------------------
3.2 Response shape
--------------------------------------------------------------------------------

Additive over today's `{items, page, lastPage, total}` - old-shape-only
callers keep working.

    {
      "items": [
        // popular / name / updated:
        { "slug","name","thumbnail","author","summary",
          "downloads": <int|null>, "updatedAt": "<raw Wago string>|null" }
        // gaining:
        { "slug","name","thumbnail","downloads": <int>,
          "deltaDownloads": <int>, "rank": <int|null> }
      ],
      "page": <int>, "lastPage": <int>, "total": <int>,
      "sortApplied": "popular"|"name"|"updated"|"gaining",
      "categories": [ { "id": <int>, "displayName": "<string>" }, ... ],

      // gaining only:
      "ready": true|false,
      "since": "<ISO8601 UTC>"|null,
      "asOf": "<ISO8601 UTC>"|null,
      "baselineAsOf": "<ISO8601 UTC>"|null,
      "snapshotCount": <int>           // NEW - added in this synthesis,
                                        // not in the original data design;
                                        // powers the honest not-ready copy
                                        // in section 2.4 without implying
                                        // a fixed schedule. Present
                                        // whenever sortApplied=="gaining",
                                        // both ready and not-ready.

      // "gameActive" (popular/name/updated only, present when the live
      // fetch was skipped because WoW was running) is SUPERSEDED
      // 2026-09-08 and no longer sent - see 3.5. Live fetches are never
      // skipped for game state any more.
    }

`author`/`summary`/`downloads`/`updatedAt` are omitted (not
null-padded) on gaining items - a different, smaller shape; client code
must branch on `sortApplied`, not on field presence.

--------------------------------------------------------------------------------
3.3 Parser widening
--------------------------------------------------------------------------------

`ConvertFrom-WagoSearchCardHtml` (L4243-4271) gains four new optional,
never-throw regex extractions against the same single-card HTML
fragment already scoped to one addon:

    summary:    <p[^>]*>([^<]*)</p>                       (first <p> in the card - the truncated description, immediately after <h3>, one per card)
    author:     <strong>Author:</strong>\s*([^<]*)</span>
    updatedAt:  <strong>Updated:</strong>\s*([^<]*)</span>  (kept as Wago's raw human string, e.g. "Aug 18, 2026" - never re-parsed for display; see 2.6 for why this works unmodified with the existing UI date helpers)
    downloads:  <strong>Downloads:</strong>\s*([^<]*)</span> (strip non-digits first, then [int]::Parse - defensive against a future thousands-separator, though none observed live)

Each is independent; a miss leaves that field `$null`, never aborts the
parse (same style as the existing slug/name/thumbnail extraction). All
four fields confirmed present on every probed game_version/category/
search combination in the research capture - zero new upstream requests.

New pure helper `Sort-WagoItemsByUpdated` (used by `sort=updated`):
parse each item's `updatedAt` via `[DateTime]::ParseExact(...,
'MMM d, yyyy', InvariantCulture)` in try/catch (failure -> sorts last),
then `Sort-Object` on three EXPLICIT keys - parsed date descending,
downloads descending, slug ascending - never relying on incidental
input-order stability.

--------------------------------------------------------------------------------
3.4 sort=updated - the page-local limitation
--------------------------------------------------------------------------------

Fetches the IDENTICAL popular URL for the same q/categoryId/page (Wago's
own `sort=updated` returns `props.addons: null` - never send it
upstream). The up-to-15 items that page returns are re-sorted
server-side by `Sort-WagoItemsByUpdated`. Because the underlying URL is
byte-identical to "popular" for the same params, this SHARES the exact
same `Get-WagoCached` entry - switching Popular <-> Recently-updated on
the same page costs zero extra live requests. This is a page-local
re-sort of Wago's popularity-ordered page N, NOT a true global recency
ordering across all matching addons; the UI tooltip (section 1/2.3) is
written to be true under this limitation.

--------------------------------------------------------------------------------
3.5 Game-mode rule - SUPERSEDED 2026-09-08 by GAME-MODE-SPEC.md
--------------------------------------------------------------------------------

Historical context, kept because it explains where the (now-removed)
`gameActive` field and `Get-WagoCached`'s `-AllowLiveFetch` parameter
came from: the original data design stated "this endpoint does not add
a new Test-GameRunning gate on individual requests... unchanged for the
three live-fetch sort modes," on the stated assumption that "today's
Handle-WagoSearch live-fetch path is already exempt from the no-network-
while-WoW-runs rule." The judge's own adversarial review (finding 10)
flagged this as an unverified assumption and asked for it to be checked
rather than taken on faith.

VERIFIED AT THE TIME: `Handle-WagoSearch` (L4273-4334) called
`Test-GameRunning` nowhere at all - it always attempted a live/cached
fetch regardless of game state. The design at the time read this as a
live, ungated hole in the "no network while WoW runs" rule and had
`Handle-WagoBrowse` add a matching `Test-GameRunning` gate
(`-AllowLiveFetch:(-not (Test-GameRunning))`) so the new endpoint would
not "inherit and amplify" the gap.

CORRECTED 2026-09-08 (GAME-MODE-SPEC.md): Eric's policy is now "addon
browsing, updates and stuff need to happen while wow is running" - the
"no network while WoW runs" rule itself is gone, everywhere, not just
for Wago browse. In hindsight, `Handle-WagoSearch`'s original ungated
behavior was the CORRECT one and always had been; the "hole" this
section used to describe closing was actually the one part of the Wago
surface that was already right. `Handle-WagoBrowse` now matches
`Handle-WagoSearch` by dropping its own gate, not the other way around:
`Get-WagoCached` is always called with `-AllowLiveFetch:$true` (or the
switch is simply omitted) for all four sort modes, the `$gameIsRunning`
variable is removed from `Handle-WagoBrowse` entirely, and the
`gameActive` response field (previously documented here as returned on
a gated cold miss) is dropped from the response rather than kept as
always-`$false` - there is no reason for a client to ask "was this
empty because the game was running" when that can no longer happen. See
GAME-MODE-SPEC.md section 2 (the `addon-server.ps1` `Handle-WagoBrowse`
row) for the exact diff.

The enrichment prefetch's own `Test-GameRunning` gate
(`Get-CfEnrichmentNoKey`, `addon-server.ps1`) is removed by the same
policy change - see GAME-MODE-SPEC.md section 2 for that site.

`sort=gaining` was always unaffected by any of this - it is a pure disk
read with zero network/cache interaction, answerable regardless of game
state, unchanged by this correction.

`/api/wago/categories` (`Handle-WagoCategories`) never had a
`Test-GameRunning` gate in the first place, so this policy change is a
non-event for that endpoint.

--------------------------------------------------------------------------------
3.6 Cache, pacing, flavours
--------------------------------------------------------------------------------

Cache: unchanged `Get-WagoCached`, 5-minute in-memory, keyed by full
upstream URI - a category+sort+page combination is a different URI and
gets its own cache slot for free. `sort=gaining` never touches this
cache (its own on-disk daily-cadence store, section 4).

Pacing: unchanged `Invoke-WagoHttpRequest` (300ms after every live call,
retry once after 5s on 429/503). `sort=gaining` makes no live call, so
it never counts against pacing.

Flavours: every live call resolves `game_version` through the existing
`Get-CfFlavourMapping -> .WagoField` machinery (`FLAVORS-SPEC.md` S2.4/
S4.6), exactly as `Handle-WagoSearch` does today - `classic` resolves
dynamically per-Interface via `Resolve-ClassicProgressionTypeId`, never
a literal. Zero new code needed in `Handle-WagoBrowse` beyond what
already exists at L4302-4304; `sort=gaining` reads the SAME
`$Script:CurrentFlavour`-derived `WagoField` to pick which
`wago-growth-<gv>.json` file to read.

(Round 38, 2026-09-08: a QA pass found the original build of this
handler left one case of that "resolve through Get-CfFlavourMapping"
rule unguarded - when a Classic client's Interface falls outside every
row of `Resolve-ClassicProgressionTypeId`'s table (a future Classic
expansion Furphy doesn't cover yet), `WagoField` comes back `$null` with
`EraKey='unknown'`, and the handler fell back to `game_version=retail`
with no indication anything was wrong, showing a Classic player Retail's
own catalog. This directly contradicted the hard-fail convention
`addon-sync.ps1`'s `Sync-SingleAddon`/`Sync-SingleWagoAddon` already
enforce for the identical `EraKey -eq 'unknown'` case on the
tracked-addon sync paths - the browse/search endpoint, added later, was
never given the equivalent guard. Fixed: `Handle-WagoBrowse` (and every
sibling `Handle-Wago*` handler that resolves `game_version` the same
way) now checks for `EraKey -eq 'unknown'` and returns a clear
client-facing error instead of ever falling through to the
`game_version=retail` line - see CHANGELOG.md's Round 38 entry.)

--------------------------------------------------------------------------------
3.7 Prerequisite: WagoBaseUrl test seam
--------------------------------------------------------------------------------

`addon-server.ps1` currently hardcodes `'https://addons.wago.io'` as a
literal at five call sites: L4306 (`Handle-WagoSearch`/`Handle-WagoBrowse`),
L4341 (`Handle-WagoCategories`), L4357 (`Handle-WagoAddonDetails`), L4376
(`Handle-WagoAddonReleases`), L4404 (`Handle-WagoAddonGallery`), plus
L5084/L5093/L5160 (keyless-enrichment paths) and L6861 (open-URL
allowlist - leave this one as a literal, it is a UI-safety allowlist, not
an HTTP call site).

`addon-sync.ps1` ALREADY has the exact seam needed (confirmed live at
L211-213):

    $script:WagoBaseUrl = 'https://addons.wago.io'
    if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_WAGO_BASEURL)) {
        $script:WagoBaseUrl = $env:FURPHY_TEST_WAGO_BASEURL.TrimEnd('/')
    }

Port this exact pattern into `addon-server.ps1` as `$Script:WagoBaseUrl`,
defined once near the other `$Script:CacheDir`-style startup constants
(L7170 area), and replace every one of the eight literal call sites
above with `$Script:WagoBaseUrl` (except L6861, per above). This is a
HARD PREREQUISITE - none of section 3 or 4's new behavior is testable
without live-hitting real Wago until this seam exists. `Start-TestServer`
(`tests\lib\common.ps1`) needs no code change - it uses `Start-Process`,
which inherits the calling test process's environment, so a test sets
`$env:FURPHY_TEST_WAGO_BASEURL` before calling `Start-TestServer` and
removes it in `AfterEach`/`finally`, exactly like
`Cli.BaseUrlOverride.Tests.ps1` already does for the CLI's copy.

================================================================================
4. SNAPSHOTS AND "GAINING THIS WEEK"
================================================================================

All of the original data design's mechanics are kept (crawl shape,
storage format, growth formula, retention) with the judge's required
fixes applied below, plus the two additional fixes from this synthesis
pass (the `$Script:AcceptingRequests` guard's exact mechanism, and the
`snapshotCount` field feeding the rewritten honest copy in section 2.4).

--------------------------------------------------------------------------------
4.1 Trigger and gates
--------------------------------------------------------------------------------

One new function, `Initialize-WagoGrowthSnapshots`, called once at
server startup immediately after `Initialize-CfCatalogueIndex`
(`addon-server.ps1` L7429) - i.e. insert the call at the new L7430,
still strictly before the listener's first `BeginGetContext`
(currently L7448). This is the ONLY periodic-refresh precedent in this
file (there is no other timer); "daily" means "checked once whenever
this long-lived process happens to (re)start."

Gates, checked cheaply before any network call:
1. Per resolved game_version, look at that file's LAST entry's
   `capturedAt`: if `(Get-Date).ToUniversalTime() - lastCapturedAt < 20
   hours`, skip just that game_version (log once) - per-file, not
   global, so one flavour's freshness never blocks a newly-installed
   sibling flavour.

(Superseded 2026-09-08: this list used to open with a `Test-GameRunning`
gate - skip the whole crawl whenever WoW was running (mirroring
`Initialize-CfCatalogueIndex`'s own log line/reasoning), re-checked
before every page inside the crawl per 4.2 below. Per GAME-MODE-SPEC.md,
the "no network while WoW runs" invariant this gate enforced is gone;
the crawl now runs purely on the 20-hour freshness gate above,
regardless of game state. See GAME-MODE-SPEC.md section 2, the
`Initialize-WagoGrowthSnapshots` row.)

--------------------------------------------------------------------------------
4.2 Crawl - historical: FIX for data-review finding 1 (game-mode TOCTOU),
    SUPERSEDED 2026-09-08 by GAME-MODE-SPEC.md
--------------------------------------------------------------------------------

Per game_version that passes the freshness gate: fetch
`$Script:WagoBaseUrl + '/?game_version=<gv>&page=<n>'` for `n = 1..10`
via the SAME `Get-WagoCached`/`Invoke-WagoHttpRequest` path (always
`-AllowLiveFetch:$true`). Stop early at `current_page >= last_page`, or
the first request/parse failure (PARTIAL rule below).

Kept for history: the judge's data-review finding 1 (TOCTOU) noted the
ORIGINAL design checked `Test-GameRunning` exactly once before the
entire multi-flavour run - a worst case of up to 6 flavours x 10 pages
could keep firing live requests for ~20-30 seconds after WoW actually
launched mid-crawl, a direct violation of the "no network while any WoW
client runs" invariant that stood at the time. The fix re-checked
`Test-GameRunning` immediately before every single page fetch (widened
past the judge's own "per flavour" suggestion to "per page," since a
page fetch plus its 300ms pacing tax is the real per-request cost the
rule was protecting against) and aborted the ENTIRE run the instant it
went true mid-crawl, logging "Wago growth snapshot crawl aborted
mid-run: WoW started."

SUPERSEDED 2026-09-08 (GAME-MODE-SPEC.md): the invariant this TOCTOU fix
protected no longer exists. All three `Test-GameRunning` checks (the
top-of-run gate in 4.1, the per-flavour re-check, and the per-page
re-check described above) and the `$abortAll` machinery are removed -
there is nothing left to re-check per page and no mid-run abort case.
The crawl simply runs every page of every stale flavour to completion,
gated only by the 20-hour per-`game_version` freshness check (4.1) and
the `$Script:AcceptingRequests` startup-ordering guard (4.4).

Defensive de-dup by slug (keep first/lowest-rank occurrence) - observed
live single-digit download-count drift between near-simultaneous
requests can occasionally shuffle an addon across a page boundary
mid-crawl; immaterial to weekly-delta math, already handled by this
rule.

--------------------------------------------------------------------------------
4.3 Partial results and exception safety - FIX for data-review finding 3
--------------------------------------------------------------------------------

If zero pages succeeded for a game_version: write nothing today (log,
retry at the next gated opportunity) - never persist an empty-items
snapshot (would corrupt "closest snapshot" math and the readiness rule).
If 1+ pages succeeded before a later page failed: still write the
snapshot with whatever was captured. (The "or the game-running abort
fired" clause this line used to carry is gone along with the abort case
itself - see 4.2.)

REQUIRED FIX (judge's data-review finding 3, no exception safety): the
ORIGINAL design had no stated try/catch per flavour iteration and no
try/finally around the final flavour-context restore - an unexpected
throw mid-loop (flavour 2 of 3, say) could leave `$Script:CurrentFlavour`
stuck on a non-default flavour for the server's ENTIRE remaining
lifetime, silently corrupting every flavour-scoped request (not just
Wago's) until restart. FIXED, exact structure:

    function Initialize-WagoGrowthSnapshots {
        try {
            foreach ($flavourId in $installedFlavours) {
                try {
                    Set-CurrentFlavourContext -Flavor $flavourId
                    # ... crawl this flavour's game_version (4.2) ...
                } catch {
                    Write-ServerLog "Wago growth snapshot crawl failed for flavour '$flavourId': $($_.Exception.Message)"
                    # log-and-continue to the next flavour, matching this
                    # file's existing never-throw style elsewhere
                }
            }
        } finally {
            # ALWAYS restore, even if something above threw past its own
            # catch (a bug in the catch handler itself, say) - this
            # finally is the actual safety net, not the inner catch.
            Set-CurrentFlavourContext -Flavor (Get-DefaultFlavourId -InstalledFlavours $Script:InstalledFlavoursAtStartup)
        }
    }

--------------------------------------------------------------------------------
4.4 The AcceptingRequests guard - FIX for data-review finding 2
--------------------------------------------------------------------------------

The original design's safety argument for repeatedly mutating
`$Script:CurrentFlavour`/`$Script:ClientBuildInfo` via
`Set-CurrentFlavourContext` before restoring the default lived ENTIRELY
in a doc comment ("this is safe because it all happens before the
request loop's first BeginGetContext wait... a future refactor could
silently break this without noticing" - the design's own risk #2,
correctly self-flagged but not actually fixed).

REQUIRED FIX (judge's data-review finding 2): make the invariant
self-enforcing, not just documented.

- Add `$Script:AcceptingRequests = $false` once, alongside the other
  `$Script:`-scoped state declared near L7445 (right before
  `$Script:LastRequestTime = Get-Date`).
- Set `$Script:AcceptingRequests = $true` as the FIRST statement inside
  the request loop's `try` block, i.e. immediately after the existing
  `$pending = $listener.BeginGetContext($null, $null)` at L7448 -
  concretely, the very next line.
- At the top of `Initialize-WagoGrowthSnapshots` (and, for symmetry,
  worth adding to `Initialize-CfCatalogueIndex` too, though that is a
  pre-existing function outside this round's required scope - flag it,
  don't block on it):

      if ($Script:AcceptingRequests) {
          throw "Initialize-WagoGrowthSnapshots must run before the " +
                "request loop starts accepting connections - a refactor " +
                "moved this call past that point without updating it."
      }

  This turns a doc-comment-only invariant into something that fails
  loudly (a startup crash, impossible to miss in `server.log`) instead
  of silently corrupting flavour-scoped requests for every user of a
  future build.
- Regression test (unit, no disk/network): dot-source the server, set
  `$Script:AcceptingRequests = $true`, call `Initialize-WagoGrowthSnapshots`,
  assert it throws. This is a fast, direct proxy for "the call site
  didn't move" - see section 7.

--------------------------------------------------------------------------------
4.5 Startup latency - decision for data-review finding 4
--------------------------------------------------------------------------------

The judge's data review correctly noted the crawl runs before the
request-accept loop starts, so ANY server start landing on the ~20h
capture window adds the crawl's full wall-clock time (single-digit
seconds for one flavour, tens of seconds worst-case for six) before the
app answers ANY request - not just Wago's.

DECISION (this synthesis pass, not deferred as an open question):
KEEP IT SYNCHRONOUS, matching the one existing precedent
(`Initialize-CfCatalogueIndex`) rather than introducing PowerShell 5.1
runspace/background-thread machinery into a single-threaded
`HttpListener` app for the first time in this codebase - that
architecture change carries its own real risk (the exact kind of
locking/concurrency hazard the judge's finding 2 already flags as
fragile even for the SIMPLER synchronous case) and is disproportionate
to a cost that only bites ~once per 20 hours and is bounded (6 flavours
is the theoretical ceiling; the overwhelmingly common case is 1
flavour, matching FLAVORS-SPEC.md's own "invisible at one flavour"
principle). MITIGATION instead: log the crawl's own start/end
timestamps and total elapsed time to `server.log` on every run
(cheap, one line), so the added startup cost is measured and visible in
practice, not just theorized - if it proves to be a real problem on a
multi-flavour machine, that log line is exactly what a future round
would need to justify the bigger architecture change. This satisfies
the judge's "at minimum" alternative explicitly.

--------------------------------------------------------------------------------
4.6 Storage, growth ranking, readiness - unchanged from the data design, plus snapshotCount
--------------------------------------------------------------------------------

One file per Wago game_version actually encountered:
`<CacheDir>\wago-growth-<gameVersion>.json`, atomic write (tmp file +
`Move-Item -Force`, matching `Save-CfCatalogueIndex`'s own pattern,
L4483).

    {
      "gameVersion": "retail",
      "firstCapturedAt": "2026-09-06T04:00:00Z",   // set once, never overwritten
      "snapshots": [
        { "capturedAt": "...", "items": [ {slug,name,thumbnail,downloads,rank}, ... up to 150 ] },
        ...
      ]
    }

Retention: most recent 21 entries kept (roughly three weeks of daily
captures allowing for gaps); `firstCapturedAt` persists regardless of
pruning. Bounded at ~315KB/file, ~1.9MB worst case across all six
possible game_version values.

`Get-WagoGrowthRanking($SnapshotFile, $NowUtc)` - pure function, zero
disk/network, unit-testable:
1. Missing/corrupt/empty file, or zero snapshot entries -> `{ ready=$false;
   since=$null; asOf=$null; baselineAsOf=$null; items=@();
   snapshotCount=0 }`.
2. `latest` = max-`capturedAt` entry (re-sort defensively, never trust
   array order).
3. `targetAge` = `latest.capturedAt - 7 days`. Search all OTHER
   snapshots in the inclusive window `[latest.capturedAt - 9 days,
   latest.capturedAt - 5 days]`; pick the one numerically closest to
   `targetAge` (ties broken toward the OLDER candidate, deterministic).
   None found (including "only latest exists") -> `{ ready=$false;
   since=firstCapturedAt; asOf=null; baselineAsOf=null; items=@();
   snapshotCount=<total entries in file> }` - NEW field vs. the original
   data design, needed for section 2.4's honest not-ready copy.
4. `baseline` = chosen snapshot; build slug->downloads dictionary.
5. For every `latest.items` entry present in `baseline` with
   `delta = latest.downloads - baseline.downloads > 0`: keep. Flat,
   declining, or baseline-absent (new top-150 entrant this week, no
   honest baseline) entries are EXCLUDED, never shown as "gaining."
6. Sort qualifying entries: delta descending, then latest-downloads
   descending, then slug ascending (explicit three-key, no reliance on
   incidental stability).
7. Return `{ ready=$true; since=firstCapturedAt; asOf=latest.capturedAt;
   baselineAsOf=baseline.capturedAt; snapshotCount=<total entries in
   file>; items=[...] }`.

Readiness rule stated once, for whoever writes final copy: ready as soon
as Furphy holds two real captures for that game_version at least 5 and
at most 9 days apart (closest-to-7 wins) - NOT "7 calendar days since
install," because captures are opportunistic. The first real week can
legitimately take longer; section 2.4's not-ready copy is written to
never promise a date it cannot guarantee.

--------------------------------------------------------------------------------
4.7 Flavours
--------------------------------------------------------------------------------

Unchanged from the data design: `Handle-WagoBrowse` (per-request) reads
`$Script:CurrentFlavour`/`$Script:ClientBuildInfo.clientInterface`
exactly as `Handle-WagoSearch` does today - zero new code beyond what
exists. `Initialize-WagoGrowthSnapshots` (once at startup, no "current"
flavour to lean on) calls `Get-CurrentInstalledFlavours` (L915) for
every INSTALLED flavour, temporarily `Set-CurrentFlavourContext`-s into
each (L1094), reads `Get-CfFlavourMapping -> .WagoField` (L542),
collects DISTINCT WagoField values in first-seen order (hard ceiling of
6, collapses to exactly 1 on the overwhelmingly common Retail-only
machine), then restores the true default via `Set-CurrentFlavourContext
-Flavor (Get-DefaultFlavourId -InstalledFlavours
$Script:InstalledFlavoursAtStartup)` (L7324's own existing call,
mirrored) inside the `finally` block from 4.3. PTR/XPTR/Beta (hidden by
default, WagoField defaults to 'retail') dedupe into the already-present
'retail' entry automatically - no special-casing needed.

--------------------------------------------------------------------------------
4.8 Named constraints for the endpoint's own doc comment - FIX for data-review finding 5
--------------------------------------------------------------------------------

REQUIRED (judge's data-review finding 5): the category+gaining
incompatibility must be a named, loud constraint, not just buried in a
request-budget aside - because BOTH submitted UI designs already assumed
it worked, and B's mockups drew it outright as a real feature. Add this
exact comment to the top of the `sort=gaining` branch in
`Handle-WagoBrowse`:

    # CONSTRAINT (permanent, not a TODO): sort=gaining ignores q and
    # categoryId entirely and always will under this design - a
    # category- or search-scoped "gaining" would require per-category
    # daily snapshots (~29x today's request budget) and the growth
    # snapshot format never records which category an addon belongs to.
    # Do not silently fake a category label onto this global list. If
    # this is ever wanted for real, it is a new snapshot format and a
    # new crawl budget, not a filter added to this function.

And the required test (section 7): `sort=gaining&categoryId=<n>` must
return the IDENTICAL global ranking regardless of `categoryId`.

================================================================================
5. UX-SPEC.md / SPEC.md SUPERSESSION TEXT
================================================================================

--------------------------------------------------------------------------------
5.1 UX-SPEC.md section 5.1 (currently line 240)
--------------------------------------------------------------------------------

Current text (leave in place, struck through in spirit per this
codebase's own E23 convention - do not delete it outright):

    - **No category filter, no sort dropdown, no pagination** on the Wago
      segment - unchanged reasoning from CS3 (Wago's own sort is
      constrained upstream to two usable values); the CurseForge segment
      needs none of this either, since it's the real site with its own
      full search/sort/categories.

Add immediately after it (new paragraph, dated, matching the exact
convention already used at line 257 for E23):

    **Round 32 (2026-09-06, Expansion E29): SUPERSEDED.** Eric's explicit
    new request - "for wago, i need a really good category based
    interactive browsing experience, i want users to be able to sort by
    popular, new, categories, rising in popularity, installs during the
    current season, etc" - directly reverses this line. The Wago segment
    now has a persistent category chip strip (29 categories + All) and a
    four-way sort control (Popular / Recently updated / Name (A-Z) /
    Gaining this week) plus "Load more" pagination - see
    `WAGO-BROWSE-SPEC.md` for the full design. The CurseForge segment is
    unaffected by this change and still needs none of this, for the same
    reason stated above. A future audit should read this as the new
    standing decision for the Wago segment specifically, not a
    regression against the line above it.

--------------------------------------------------------------------------------
5.2 UX-SPEC.md section 11 (currently line 474)
--------------------------------------------------------------------------------

Current text:

    - [ ] Browse has no visible sort dropdown, category filter, or
      pagination control on the default results view.

Replace with (same line, updated in place - this is a checklist item, not
historical prose, so it is corrected rather than struck through, with a
footnote explaining why):

    - [ ] The CurseForge segment of Browse has no visible sort dropdown,
      category filter, or pagination control (unchanged reasoning:
      it's the real site with its own full search/sort/categories). The
      Wago segment DELIBERATELY has all three as of Round 32 (Expansion
      E29, WAGO-BROWSE-SPEC.md) - this is not a regression, see section
      5.1's superseded note.

--------------------------------------------------------------------------------
5.3 SPEC.md - new section
--------------------------------------------------------------------------------

Add a new `## Expansion E29 - Wago category browse (round 32)` section,
placed after `## Expansion E28` (currently ending around line 705,
immediately before the `## Tray experience (round 28)` heading -
insert the new section between them, or after the Tray section if that
reads better chronologically; either is fine, this codebase already
mixes E-numbered expansions and Round-numbered feature sections in
roughly chronological order). Contents: a condensed version of sections
2-4 above - the endpoint contract, the parser widening, the snapshot
mechanism and its readiness rule, and the four sort tabs/category strip
in the UI - written in this file's own third-person documentation voice
(not imperative build instructions, which is what this spec document
itself is). Cross-reference `WAGO-BROWSE-SPEC.md` and
`WAGO-BROWSE-RESEARCH.md` by name for full detail rather than
duplicating every field name.

Also update the one-line "Wago Addons access facts (verified)" section
(currently L318 area) with a pointer: "See also Expansion E29 for the
category/sort/Gaining-this-week browse redesign built on top of these
facts (round 32)."

================================================================================
6. CHANGE SETS (small enough for one agent each)
================================================================================

Ordering matters: SERVER-1 must land before SERVER-2/3; TESTS-1 (the
WagoBaseUrl seam) must land before any of TESTS-2/3/4; SPA-* changes
should NOT start until whatever workflow is currently editing `ui\`
finishes and this round is no longer read-only (see the coordination
note in section 7).

SERVER-1 - WagoBaseUrl seam (prerequisite, section 3.7)
  Files: addon-server.ps1
  Anchors: L4306, L4341, L4357, L4376, L4404, L5084, L5093, L5160
  (replace literal with $Script:WagoBaseUrl); new declaration near L7170.
  No behavior change on a machine without FURPHY_TEST_WAGO_BASEURL set.

SERVER-2 - Handle-WagoBrowse rename + route registration + hardening
  Files: addon-server.ps1
  Anchors: L4273 (rename function + widen param handling per 3.1),
  L995-1003 (FlavourScopedEndpoints), L6981-6982 (Routes).
  Depends on: SERVER-1 not required for this one specifically, but land
  after it for a clean diff.

SERVER-3 - Parser widening + Sort-WagoItemsByUpdated
  Files: addon-server.ps1
  Anchors: L4243-4271 (ConvertFrom-WagoSearchCardHtml), new helper
  function placed immediately after it.

SERVER-4 - Get-WagoCached -AllowLiveFetch + game-mode gate in
  Handle-WagoBrowse (section 3.5 - the correction to the original data
  design)
  Files: addon-server.ps1
  Anchors: L4209-4241 (Get-WagoCached), the live-fetch branch inside the
  renamed Handle-WagoBrowse from SERVER-2.
  Depends on: SERVER-1, SERVER-2.

SERVER-5 - Snapshot crawl + Get-WagoGrowthRanking + AcceptingRequests
  guard (sections 4.1-4.6)
  Files: addon-server.ps1
  Anchors: new functions near L4585 (Initialize-CfCatalogueIndex's
  neighborhood) or wherever the implementer groups new Wago functions;
  call site at new L7430; $Script:AcceptingRequests declared near L7445,
  set true at new line after L7448.
  Depends on: SERVER-1, SERVER-4 (reuses the same live-fetch machinery
  for the crawl's own page fetches).

SPA-1 - normalizeWagoEntry + resultCard field wiring (NEXT ROUND, once
  ui\ is unblocked)
  Files: ui\app.js
  Anchors: L5311-5317 (normalizeWagoEntry - stop hardcoding author/
  summary/downloadCount/updatedAt to null), L5371-5399 (resultCard -
  already has the rendering code, just needs live data; add rank number
  + delta badge for the gaining shape).

SPA-2 - Sort control + category strip + Store.state.browse additions
  Files: ui\app.js, ui\index.html, ui\style.css
  Anchors: ui\app.js L1812-1821 (Store.state.browse - add sort/
  categoryId/page fields), L5269-5288 (searchWago - key the fetch by
  sort/categoryId/page too), ui\index.html L651-701 (insert the new
  markup inside #browse-wago-panel per section 2.1), ui\style.css (new
  .wago-sort/.wago-chip/.wago-chip-toggle/.wago-cat-expanded/
  .wago-loadmore rules per A's wago-browse-design.css, adapted with the
  disabled-chip state from section 2.2/2.4).

SPA-3 - Gaining-this-week tab: not-ready/ready states, non-scoping
  note, currency/scope line, "See Popular instead"
  Files: ui\app.js, ui\index.html, ui\style.css
  Anchors: new render function alongside renderWagoResults (L5327-5362),
  new .wago-gain-card/.wago-gain-progress/.wago-gain-delta rules.

SPA-4 - SUPERSEDED 2026-09-08 (GAME-MODE-SPEC.md): was "Game-running
  blocked state," branching renderWagoResults (L5327-5362) on a
  `gameActive` response field. That field no longer exists (3.5) and
  Wago browsing never blocks on game state, so this work item is
  dropped - there is nothing left for the SPA to branch on.

TESTS-1 - Server-side WagoBaseUrl override test (mirrors
  Cli.BaseUrlOverride.Tests.ps1)
  Files: tests\unit\Server.BaseUrlOverride.Tests.ps1 (new)

TESTS-2 - Parser + sort-by-updated + growth-ranking unit tests
  Files: tests\unit\Wago.ParserFixtures.Tests.ps1,
  tests\unit\Wago.SortByUpdated.Tests.ps1,
  tests\unit\Wago.GrowthRanking.Tests.ps1 (all new)

TESTS-3 - AcceptingRequests guard regression test
  Files: tests\unit\Server.Handlers.Tests.ps1 (add to existing file) or
  a new tests\unit\Wago.SnapshotStartupGuard.Tests.ps1

TESTS-4 - Integration: Start-WagoStubServer + full endpoint/game-mode/
  snapshot/multi-flavour suite (section 7)
  Files: tests\lib\common.ps1 (add Start-WagoStubServer, modeled on
  Start-BlackHoleListener), tests\integration\Wago.Browse.Tests.ps1 (new)

DOCS-1 - UX-SPEC.md supersession notes (section 5.1/5.2)
DOCS-2 - SPEC.md Expansion E29 section (section 5.3)
DOCS-3 - CHANGELOG.md Round 32 entry (standard practice for every round
  in this file; not itself part of the four inputs but consistent with
  every prior round documented there)

================================================================================
7. TEST PLAN
================================================================================

COORDINATION NOTE (carried from the data design, still true): this
round's server-side test fixtures and any UI-side mock JSON for
`/api/wago/search|browse` will need updating once SPA-1..3 land, to the
new response shape (author/summary/downloads/updatedAt/categories/
sortApplied/ready/since/asOf/baselineAsOf/snapshotCount - `gameActive`
dropped per 3.5, SUPERSEDED 2026-09-08).
`tests\spa\harness.js`'s `?mock=1&view=get-new-addons&tab=wago` fixture
is the specific file to check. Out of scope for the server-only change
sets above.

--------------------------------------------------------------------------------
7.1 Unit (Pester 3, tests\unit\, no disk/network)
--------------------------------------------------------------------------------

- Wago.ParserFixtures.Tests.ps1: ConvertFrom-WagoSearchCardHtml against
  the live-captured "Details! Damage Meter" fixture (slug
  details-damage-meter-standalone, Updated "Aug 18, 2026", Downloads
  7581560, Author Terciob - WAGO-BROWSE-RESEARCH.md section 2). Cases:
  (1) full fixture -> all 7 fields, downloads is [int] not [string];
  (2) Updated/Downloads/Author block removed -> those three null, rest
  intact, no throw; (3) comma-formatted downloads ("7,581,560") -> still
  parses to 7581560; (4) HTML-entity name/author ("Tank &amp; Spank")
  decoded; (5) existing unquoted-thumbnail-src regression case stays
  passing.
- Wago.SortByUpdated.Tests.ps1: mixed valid dates sort descending; one
  unparseable date sorts last; an exact-tie pair asserts the explicit
  three-key order (date, then downloads, then slug) - constructed so a
  naive stable-sort-only implementation would fail.
- Wago.GrowthRanking.Tests.ps1: the seven cases from the original data
  design (exact ordering; 5.2/6.6-day window-edge selection; tie-break;
  intra-snapshot slug dedup; single-snapshot not-ready; missing-file
  not-ready) PLUS: (8) not-ready case asserts `snapshotCount` equals the
  actual entry count in the constructed fixture (NEW, for section 4.6's
  added field).
- Server.BaseUrlOverride.Tests.ps1: default/override/empty/whitespace
  behavior for `$Script:WagoBaseUrl`, mirroring
  Cli.BaseUrlOverride.Tests.ps1's own four cases, dot-sourcing
  addon-server.ps1's top section the same way that test dot-sources
  addon-sync.ps1.
- AcceptingRequests guard test (section 4.4): dot-source the server, set
  `$Script:AcceptingRequests = $true`, call
  `Initialize-WagoGrowthSnapshots`, assert it throws with a message
  matching "before the request loop starts accepting".

--------------------------------------------------------------------------------
7.2 Integration (tests\integration\, real child-process server via
Start-TestServer, $env:FURPHY_TEST_WAGO_BASEURL pointed at a new
Start-WagoStubServer)
--------------------------------------------------------------------------------

Start-WagoStubServer (new, modeled on `Start-BlackHoleListener` in
tests\lib\common.ps1 but with a real responder): speaks the real Inertia
handshake - plain HTML GET returns `id="app" data-page="<encoded JSON,
fixed version>"`; subsequent `X-Inertia:true` requests with a matching
`X-Inertia-Version` return the JSON props directly; a version mismatch
returns 409 once to exercise the re-handshake path; logs every received
URI (including full querystring) so tests can assert exactly what was
sent upstream.

- Endpoint end-to-end: stub serves 10 fixture pages for
  `game_version=retail` with known author/downloads/updatedAt per card
  -> `GET /api/wago/browse?sort=popular` returns those fields populated,
  `sortApplied:"popular"`.
- `sort=name` -> stub RECEIVED `&sort=name`; response reflects the
  stub's alphabetical fixture.
- `sort=rising` (stale client value) -> stub received NO `sort=` param
  at all (identical URI to sort omitted); `sortApplied:"popular"` in the
  response - regression-guards the absorption rule.
- `sort=updated` -> reused the SAME cache entry as a prior `sort=popular`
  call for the same page (stub's received-request count does not
  increase); response items re-ordered by Updated date.
- `categoryId=4` -> stub receives `&category=4`; `categoryId=abc` ->
  stub receives NO `category=` param.
- `sort=gaining&categoryId=4` (data-review finding 5's required test) ->
  identical ranked order/items as `sort=gaining` with no `categoryId` at
  all, against the same seeded snapshot fixture.
- Stub returns HTTP 500 for one page -> `/api/wago/browse?sort=popular`
  returns 502 with `{error:"Wago request failed: ..."}`.
- `/api/wago/categories` still returns the same ids/names as the inline
  `categories` array on `/api/wago/browse`'s response for the same
  request (data-review finding 8 - the two representations must never
  silently drift).
- GAME-RUNNING, BROWSE STILL WORKS (SUPERSEDED 2026-09-08, GAME-MODE-
  SPEC.md - was "GAME-MODE GATE"; inverted per section 8's
  Server.WagoBrowse.Tests.ps1 rewrite): start the test server with
  `-WowFakeProcessName` set to a name that IS running -> `GET
  /api/wago/browse?sort=popular` with NO prior cache entry for that URI
  -> the request reaches the stub and returns 200 with real items (not
  `items:[]`), `gameActive` absent from the response, stub received
  request count > 0. WoW running never suppresses a live fetch any more
  - there is no cache-priming precondition left to set up first.
- SNAPSHOT CRAWL RUNS WHILE GAME IS RUNNING (SUPERSEDED 2026-09-08,
  GAME-MODE-SPEC.md - was "SNAPSHOT GAME-MODE GATE"; inverted per
  section 8's Server.WagoSnapshotCrawl.Tests.ps1 rewrite, matching the
  unrelated 20h-freshness gate test which stays unchanged): start the
  test server with `-WowFakeProcessName` set to a fake process that IS
  running -> the crawl proceeds normally (`WagoCachedCallCount` > 0,
  `wago-growth-*.json` written) for every stale flavour, exactly as it
  would with no fake process running at all. There is no mid-crawl abort
  case left to exercise - a stub serving pages slowly no longer needs to
  interleave a "WoW started" flip, because that flip no longer stops
  anything.
- 20h STALENESS GATE: pre-seed `<Root>\cache\wago-growth-retail.json`
  with a single snapshot 2 hours old -> restart -> snapshots array
  unchanged length, stub received zero requests for this run.
- `sort=gaining` before any snapshot file exists -> 200, `ready:false`,
  `items:[]`, `since:null`, `snapshotCount:0`.
- Pre-seed two synthetic snapshots exactly 7 days apart with known
  deltas (bypassing the live crawl - integration tests must not wait
  real days) -> restart pointed at that seeded cache dir -> `GET
  /api/wago/browse?sort=gaining` returns `ready:true` with the exact
  expected ranked order and `since`/`asOf`/`baselineAsOf` matching the
  seeded timestamps, `snapshotCount:2`.
- STARTUP SELF-CHECK: grep the server's own `server.log` after startup
  for "STARTUP SELF-CHECK FAILED" and assert it never fires - guards
  against forgetting to register `/api/wago/browse` in both
  `$Script:Routes` and `$Script:FlavourScopedEndpoints`.
- `/api/wago/search` (legacy alias) still answers with the old
  three-field-minimum shape - no-regression check.
- STARTUP LATENCY LOG (section 4.5's mitigation): assert `server.log`
  contains a line reporting the crawl's elapsed time whenever the crawl
  actually ran (not when it was gated out).
- MULTI-FLAVOUR: two installed flavours whose WagoField both resolve to
  'classic' (reuses FLAVORS-SPEC.md section 8's synthetic classic-client
  fixture) -> assert only ONE crawl/one file (`wago-growth-classic.json`),
  and the stub's total received-request count for that run matches ONE
  game_version's worth of pages, not two.

--------------------------------------------------------------------------------
7.3 SPA harness checks (tests\spa\harness.js, next round once ui\ is
unblocked)
--------------------------------------------------------------------------------

- Category chips render (29 + All), correct order including the id-5
  out-of-sequence entry; selecting one re-fetches and updates the
  result-count line and search placeholder.
- Sort tabs render, exactly one `.is-active`; clicking each triggers the
  skeleton-then-results sequence.
- "Load more" appends 15 rows and hides once `page >= lastPage`.
- "Gaining this week" not-ready state renders the rewritten copy from
  section 2.4 (not "Day N of 4"), the snapshot count, and the "See
  Popular instead" button switches the active tab to Popular.
- "Gaining this week" ready state (mocked) renders rank + delta badge +
  currency/scope line; category chips are visually disabled and the
  search field is disabled with the non-scoping note visible.
- (Superseded 2026-09-08: this used to check that a game-running blocked
  state rendered when the mock response carried `gameActive:true`. Per
  GAME-MODE-SPEC.md, Wago browsing works fully while WoW runs - that
  state and its mock branch are removed; the Wago grid renders normally
  under `?game=1` instead, per section 8's harness.js inversion.)
- Banned-term grep (UX-SPEC.md section 11) returns zero matches across
  every new string in this round - `?mock=1&view=get-new-addons&tab=wago`
  loaded, full text read via `get_page_text`, checked against the
  existing banned list plus a project-specific check that "new,"
  "rising," "trending," and "this season" never appear as a label
  anywhere in the DOM.

================================================================================
8. ACCEPTANCE CHECKLIST AND SCREENSHOTS
================================================================================

--------------------------------------------------------------------------------
8.1 Acceptance checklist
--------------------------------------------------------------------------------

- [ ] Popular tab sends no `sort=` param; matches today's implicit
      default ordering byte-for-byte for a user who never touches any
      new control.
- [ ] All 29 categories are reachable at both required window sizes
      (collapsed+overflow at 845x539, fits without collapsing at
      2024x1273), in the server's own order including id 5's
      out-of-sequence position.
- [ ] Selecting a category updates the search placeholder, the
      result-count line, and re-fetches - composes correctly with an
      active search query and with each of the four sort tabs.
- [ ] Recently-updated tab's tooltip text matches section 1 exactly;
      the underlying re-sort is verified page-local (not a fabricated
      global sort) by the integration test in 7.2.
- [ ] Author/summary/downloads/updated-date render on every row, every
      tab, whenever Wago's card supplied them - never a blank slot,
      never invented.
- [ ] "Load more" works and disables/hides at the last page; no
      false citation to a nonexistent Versions-tab precedent survives
      anywhere in shipped code comments.
- [ ] Gaining-this-week: not-ready copy matches section 2.4 exactly
      (no "Day N of 4"); ready copy includes BOTH the currency line and
      the top-~150-only scope disclosure in one sentence; "See Popular
      instead" works.
- [ ] Gaining-this-week: category chips are visibly disabled AND the
      search field is disabled, both with the shared non-scoping note
      visible, for the entire time that tab is active.
- [ ] `sort=gaining&categoryId=<n>` returns identical results to
      `sort=gaining` alone (automated test, 7.2).
- [ ] A user who opens Get New Addons -> Wago while a WoW client is
      running sees real, live Wago results, never a blocked-state
      message (SUPERSEDED 2026-09-08, GAME-MODE-SPEC.md - inverted from
      the original "honest game-running message, never a live network
      request" checklist item; verified via the stub's
      requests-received-count-greater-than-zero assertion, 7.2).
- [ ] (Superseded 2026-09-08: this used to require the multi-flavour
      snapshot crawl to abort immediately when game state flipped true
      mid-crawl. Per GAME-MODE-SPEC.md the crawl is never gated on game
      state, so there is no abort case left to verify - the crawl simply
      runs every page of every stale flavour to completion regardless of
      WoW state.)
- [ ] `$Script:CurrentFlavour` is provably restored to the real default
      after `Initialize-WagoGrowthSnapshots` runs, even when a
      mid-crawl exception is injected for one flavour.
- [ ] `Initialize-WagoGrowthSnapshots` throws immediately if called
      after `$Script:AcceptingRequests` is true (guard test, 7.1).
- [ ] No visible string anywhere in the Wago segment contains "new,"
      "rising," "trending," or "this season" as a label - grep-verified
      per UX-SPEC.md section 11's existing methodology, extended with
      this round's four words.
- [ ] UX-SPEC.md 5.1 and section 11's checklist item both carry the
      dated Round 32/E29 supersession text from section 5 - not a
      silent contradiction.
- [ ] SPEC.md has a new Expansion E29 section cross-referencing this
      document and the research doc.
- [ ] `/api/wago/search` (legacy) still answers with its original
      three-field-minimum shape - zero regression for any existing
      caller.
- [ ] The server's own startup self-check never fires
      "STARTUP SELF-CHECK FAILED" after this round's route registration
      changes.

--------------------------------------------------------------------------------
8.2 Screenshots to capture (both 845x539 and 2024x1273 CSS px unless
noted "one size is enough")
--------------------------------------------------------------------------------

1. Default landing: Popular, All categories, collapsed strip (845) /
   fits-without-collapsing (2024).
2. Category selected (e.g. PvP), populated rows with author/summary/
   meta, both sizes.
3. Category strip overflow: "More categories +N" collapsed (845) and
   expanded second row (845, after clicking) - one size is enough, the
   behavior doesn't change at 2024 since nothing needs to collapse
   there.
4. Recently-updated tab active, tooltip visible on hover (one size is
   enough).
5. Name (A-Z) tab active (one size is enough).
6. Gaining-this-week not-ready state: rewritten copy, snapshot count,
   "See Popular instead" button, both sizes.
7. Gaining-this-week ready state (mocked data): rank numbers, delta
   badges, currency/scope line, disabled category chips + disabled
   search + non-scoping note, both sizes.
8. Category-specific empty state ("No addons in <Category> yet") - one
   size is enough.
9. Error state (unchanged) - one size is enough, included only to
   confirm it still renders correctly alongside the new chrome above it.
10. (Superseded 2026-09-08: "Game-running blocked state" screenshot
    dropped - that state no longer exists per GAME-MODE-SPEC.md.)
11. Loading skeleton triggered by a category or sort click (not just a
    fresh search) - one size is enough.
12. "Load more" before/after click, showing 15 additional rows appended
    and the button's hidden state at the last page - one size is enough.

================================================================================
END OF WAGO-BROWSE-SPEC.md
================================================================================

DECISION 2026-09-08 (Eric, verbatim: 'don't add a wagon name filter'): no content or profanity filter on Wago addon names or descriptions. Furphy shows Wago's catalogue as Wago publishes it. Recorded so future reviews do not re-open it.
