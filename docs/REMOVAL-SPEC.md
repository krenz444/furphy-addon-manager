# REMOVAL-SPEC.md - Remove WoW launching entirely (Round 34, 1.15.0)

Status: SPEC ONLY. Written during a READ-ONLY round against the build root
(`...\scratchpad\AddonSync2`) while a separate lifecycle-build workflow is
concurrently editing that same tree (tray menu, uninstall, installer
wizard, landing page). Nothing under the build root was created, edited,
or deleted to produce this document. Source material: two exhaustive
read-only inventories (code+tests, docs+artifacts) plus a handful of
direct spot-checks against the live files, all preserved under
`removal-research\` next to this file for traceability.

**URGENT, read this before anything else below:** DISTRIBUTION-SPEC.md
lines 593-596/813-815 and SPEC.md line 945 currently spec a brand-new
installer-wizard success screen with an "Open Furphy Addon Manager" AND a
"**Launch WoW (auto-update addons)**" button. That is exactly the feature
Eric asked to delete, and it is what the OTHER, concurrently-running
lifecycle-build workflow is implementing right this week. Flag this to
that workflow (or whoever owns it) immediately - if it ships first, it
reintroduces the removed feature in a brand new place on day one.

---

## 1. Eric's ask and the binding decisions

Eric (product owner), verbatim, 2026-09-06:

> "ok, we probably dont need to have anything that connects to the game
> at this point, as in, we dont need a button to launch wow, and we dont
> need to have it run auto updates before launching wow, since we now
> have a service running in the background -- get rid of those features
> entirely"

### 1.1 REMOVE (every instance, every file)

1. The "Update & Play" button (sidebar).
2. The "Launch WoW" link/button (sidebar).
3. The "Update addons before WoW starts" setting (`autoUpdateOnLaunch`)
   and its helper text/tooltip.
4. The per-flavour launcher files `install.ps1` writes into the WoW
   folders (`update-addons-and-launch.cmd` / `Launch WoW (Updated).vbs`).
5. The "WoW (auto-update addons)" Desktop shortcut (and its per-flavour
   variant, `WoW - <Label> (auto-update addons).lnk`).
6. The server's launch endpoint(s) - the `launch` job kind, everywhere it
   appears.
7. The CLI's launch mode - `-Launcher`, the Battle.net `--exec`/product
   codes, the 45s launch budget, the 10-minute `updatesCheckedAt` skip
   (the underlying `updatesCheckedAt` value itself is kept - see 1.2).
8. The Battle.net code / Reliable columns of the flavour tables, in every
   file that carries them.
9. The launcher perf/budget tests and fixture-acceptance rows that test
   any of the above.
10. Every doc line about launching WoW.

### 1.2 KEEP (explicit, with reason)

**(SUPERSEDED 2026-09-08, GAME-MODE-SPEC.md: the sentence "the
background service must never update addons while the game is running"
below was, at the time this document was written, a currently-asserted
architectural invariant - it no longer is. Eric's policy is now "addon
browsing, updates and stuff need to happen while wow is running." See
the split KEEP / NO LONGER KEEP lists just below, which replace the
single reason-and-list pair that used to follow this note.)**

**KEEP (detection/signal infra) - still true, unrelated to the
game-mode-update policy either way, and unaffected by the launch-feature
removal:** `Test-GameRunning` (addon-server.ps1), the shared
known-process-name list, the `--wow-fake`/`-WowFakeProcessName`
test-substitution hooks, `gameRunning` on `GET /api/ping` and
`GET /api/state`, `WowDetector` in `host\FurphyHost.cs` and its ~30s
poll pushing `{type:"game"}` to the SPA, and the SPA's
`Store.state.gameRunning` (its CSS render gate and `POLL_GAME_MS`
backoff stay too - both are CPU-only measures, GAME-MODE-SPEC.md
section 1.2).

**NO LONGER KEEP (removed per GAME-MODE-SPEC.md, not by this document -
these were network/functional gates, not detection signal):** the
server-side network gates while playing (catalogue-refresh skip,
enrichment skip), the shortened idle-exit window while WoW runs, the
tray's skip-while-playing dedup (`CompleteCycleSkippedWow`), and the
"WoW is running - background checks paused" line. All four refused or
delayed real work based on game state; none survives the 2026-09-08
policy change regardless of whether this launch-removal round ships.
- `updatesCheckedAt` itself (state.json persistence, `/api/state` field,
  the SPA's freshness-line/staleness/auto-check-on-load feature). Only
  the CLI's launcher-only writer (`Save-LauncherUpdatesCheckedAt`) and
  launcher-only reader/skip-gate (`Get-StateUpdatesCheckedAtMinutesAgo`,
  the 10-minute skip) go away - something else (the SPA's own
  `App.scheduleAutoCheck()`) genuinely reads this value for an unrelated
  feature.
- The "Update All" button for multi-flavour installs (nav toolbar; syncs
  every installed flavour, launches nothing) and the My Addons toolbar's
  "Update all"/"Check now" buttons - none of these ever launched WoW and
  none are touched by this removal.
- `$Script:FlavourDefs`'s `.Product` field (wow/wow_classic/etc.) in
  `addon-sync.ps1`/`addon-server.ps1` - used only to match a flavour
  folder's own build-info Product column for flavour DETECTION, never fed
  to Battle.net. Do not confuse with `install.ps1`'s separate
  `BattleNetCode` column, which IS launch-specific and must go.
- Every "self-relaunch" mechanism that means "run a copy of THIS SCRIPT/
  EXE again" rather than "start WoW": `install.ps1`'s
  self-relaunch-before-uninstall (`FURPHY_INSTALL_RELAUNCHED`), the
  server's uninstall handler copying itself and launching the copy, and
  `host\FurphyHost.cs`'s `ActivateOrLaunch()`/tray click outcome
  `"launch"` (brings Furphy's own window forward, or starts a new
  instance of the app itself).
- `C:\Users\drops\Desktop\Furphy Addon Manager.lnk` - confirmed correct,
  untouched by this round.
- The `.sidebar-bottom` div itself, its freshness line, and its status
  dot/status text - see section 2.

---

## 2. Sidebar bottom: the replacement decision

**Decision: no replacement CTA.** `.sidebar-bottom` keeps only the
freshness line and the status dot/status text. The toolbar's "Update
all"/"Check now" (My Addons view) and the nav's "Update All" (multi-
flavour installs) are already the update actions; nothing needs to fill
the space the two removed buttons leave behind.

### 2.1 Why this is the simplest correct answer

- Every update path Eric actually uses today already lives somewhere
  else in the UI. A sidebar CTA would be the third or fourth way to
  trigger the same "sync addons" action, immediately after removing the
  one thing (launching WoW) that made "Update & Play" a distinct action
  from plain "Update all" in the first place. Once launching is gone,
  "Update & Play" and "Update all" are the same operation with two
  buttons - adding a third label for it would be worse, not better.
- The status dots and freshness line are the one thing in
  `.sidebar-bottom` that is genuinely orientation, not action - they
  answer "is the server up / how stale are my addons", which is exactly
  the kind of always-visible fact a sidebar bottom slot is for.
- It costs zero new code: `.sidebar-bottom` (`ui\style.css:1062`) is
  already a plain flex column sized to its own content, not a fixed-
  height box, so removing the two buttons shrinks it automatically - no
  rule needs to grow or shrink to compensate.

### 2.2 Exact markup/CSS consequence

Verified directly against the live files (see
`removal-research\verification-notes.md` items 3-4 for the full trace):

- `ui\index.html:585-590` - delete `<button id="btn-update-play">` and
  `<button id="btn-launch-wow">`. Keep the surrounding
  `<div class="sidebar-bottom">` wrapper (line 585's opening tag) and
  everything from `#sidebar-freshness` (595) through `#status-dot`/
  `#status-text` (596-600) exactly as-is - they become the div's only
  children.
- `ui\style.css:1062` (`.sidebar-bottom { display:flex; flex-direction:
  column; gap:8px; padding-top:8px; border-top:1px solid var(--border);
  }`) - **no edit needed.** This rule has no fixed or flex-grown height;
  it already sizes to whatever its children need, so it gets visibly
  shorter the moment the two buttons are gone.
- `ui\style.css:1201-1210` (`#btn-update-play` rule and its "a taller
  button here just pushes Launch WoW down a few px" comment) - delete
  the whole rule and comment; nothing else selects `#btn-update-play`
  once the button is gone.
- `ui\style.css:1125-1128` (`.status-dot` and its `[data-state]`
  variants) - **keep, unedited.**

### 2.3 What each theme's bottom-of-sidebar art assumes about
`.sidebar-bottom`, and what actually changes

Two genuinely different mechanisms are in play here, with opposite
consequences. Screenshot verification (section 5) must cover both kinds,
not just re-measure one and assume the other behaves the same way.

**Arcane Library (`.arcane-hero`, style.css:3410-3422) and Snow Day
(`.snow-scene`, style.css:3099-3110) - flex-sibling technique, CSS
unchanged, numbers stale.** Both themes set `.nav { flex: 0 0 auto }`
(instead of the base `.nav { flex: 1 }`) and give their own hero-art
element `flex: 1 1 auto` as a DOM sibling sitting between `</nav>` and
`.sidebar-bottom`. Because `.sidebar-bottom`'s height is pure content
height (2.2 above), whatever height it stops needing is automatically
absorbed by the theme's `flex: 1 1 auto` slot. **No CSS rule needs to
change for either theme - the layout mechanics already do the right
thing.** What DOES need attention: THEMES-SPEC.md's own geometry tables
(section 9.5, ~lines 2089-2092 for Snow Day; the equivalent Arcane
Library table cross-referenced at line 2085) hardcode pixel heights
measured against the OLD, button-containing `.sidebar-bottom`. Every
number in both tables is stale the moment the buttons are deleted.

The single most consequential stale number: at **845x539, flavours=3**
(the tallest `.nav` configuration in the existing test matrix),
`.snow-scene` currently computes to **74px** - below the `@container
snow-scene (max-height: 109px)` / `@container arcane-hero (max-height:
109px)` "vanish rather than clip" floor (style.css:3197, 3483), so the
art is hidden today at that exact size. Removing two buttons
(~40-44px each, `btn-lg`/`btn`) plus their 8px gap frees roughly
90-110px from `.sidebar-bottom`, which the flex slot absorbs directly -
predicted new height roughly **164-184px**, comfortably clear of the
109px floor. **This is an arithmetic prediction, not a live
measurement** - a scene that newly becomes visible at a size it was
never designed or reviewed at is a real regression risk (see section
5's screenshot requirement, which targets this exact case).

**Lofi Night (`.lofi-cityscape`, style.css:2633-2651) and Tokyo Rain
(`.sidebar::after`, style.css:2921-2941) - fixed-size absolute band, no
flex dependency, but less gets covered.** Both themes use a completely
different mechanism: a constant-height (140px Lofi, 150px Tokyo Rain),
`position: absolute; bottom: 0; z-index: 0` decorative band painted
*behind* the sidebar's real content (`.sidebar > *:not(...) { position:
relative; z-index: 1 }` promotes everything else above it). The band's
size never depends on `.sidebar-bottom`'s height - there is no
`flex: 1 1 auto` sibling here, so nothing "grows" to fill freed space,
and **no CSS/markup change is predicted for either theme.** What DOES
change: `.sidebar-bottom` has no background-color of its own, and its
two removed buttons were the only opaque content that used to sit in
the lower ~90-110px of that 140-150px band, physically occluding most of
it. With the buttons gone, more of the existing artwork will show
through behind the now much-shorter freshness-line/status-line - a real
visual change with zero code behind it. Verify with a live before/after
screenshot (section 5), specifically checking the status dot still has
enough contrast against whatever of the scene is now visible behind it.

### 2.4 The multi-flavour per-version launcher UI's fate

`ui\app.js:7084-7153` currently computes per-flavour sidebar CTA text -
`"Update & Play <Flavour>"` for a reliable flavour, `"Update & Open
Battle.net <Flavour>"` for one whose Battle.net launch code isn't proven
reliable - and writes it into `#btn-update-play`'s label. This entire
mechanism disappears along with the button itself (change set CS-R8
below); nothing replaces it, because the concept it existed to express
("launching this specific flavour might not work") no longer applies to
anything Furphy does. `FLAVORS-SPEC.md` section 6.3's always-visible
"Update All" button (syncs every installed flavour, launches nothing) is
untouched and becomes the sole surviving multi-flavour bulk-action entry
point in the nav, alongside the My Addons toolbar's per-list actions.

---

## 3. Change sets by file, dependency order

Each change set is scoped to one file (or one tightly-coupled pair) and
sized for one agent. Do the CLI first (server and installer both invoke
it and mirror its settings shape), then the server (SPA's contract),
then the SPA, then host (verification only), then installer/deploy, then
tests (they assert on all of the above), then docs (describe the final
state - but see the URGENT flag at the top for one doc item that cannot
wait).

### CS-R1 - `addon-sync.ps1` (CLI): remove `-Launcher` mode entirely

- `6, 23, 37-90, 144` - header/help-text describing `-Launcher`, the 45s
  budget, "the launcher chain" terminology. Remove.
- `166` - `[switch]$Launcher` parameter declaration. Remove.
- `199-202` - comment about the fake-hosts test server proving the
  launcher budget cap. Remove.
- `2860-2864, 2884-2898` - `Get-Settings` default object and parse logic
  for `autoUpdateOnLaunch`. Remove.
- `2922-2964` - `Get-StateUpdatesCheckedAtMinutesAgo` (single caller: the
  `-Launcher` skip-if-recently-checked gate). Remove.
- `2966-3031` - `Save-LauncherUpdatesCheckedAt` (single caller: end-of-run
  `-Launcher` block). Remove.
- `3032-3049` - `Test-LauncherBudgetExceeded`. Remove.
- `3050-3090` - `Get-LauncherAwareTimeoutSec`. Remove.
- `676, 935` - `$timeoutSec = Get-LauncherAwareTimeoutSec -DefaultTimeoutSec
  30` call sites inside `Sync-SingleAddon`/`Sync-SingleWagoAddon`. Change:
  replace with the plain literal `30`.
- `4223-4243` - comment block plus `$script:LauncherDeadline = $null`.
  Remove.
- `4236` - `$script:MainStartTime = Get-Date`. Remove (its only three
  readers are lines 5087/5092, both launcher-only - reconfirm with
  `grep -n MainStartTime addon-sync.ps1` before deleting in case the
  concurrent lifecycle build has since added a second reader).
- `4383-4430` - the whole "-Launcher: gate on `autoUpdateOnLaunch`, no
  network when disabled" block, including the disabled-exit-0 path and
  the 10-minute skip-if-recently-checked path. Remove.
- `5066-5111` - `$Script:LauncherBudgetSeconds`/`LauncherBudgetExceeded`
  setup, the deadline arming, and the per-addon "skip remaining addons on
  budget exceeded" block. Remove. **Keep** the surrounding `foreach
  ($record in $toSync)` loop and the generic `Skipped` result-row
  mechanism (other, unrelated skip paths write the same status - see
  `addon-sync.ps1` lines 3450/3744/3934/4901/4935/4959/4983/5007, none of
  which are touched here).
- `5217-5226` - end-of-run `if ($Launcher) { Save-LauncherUpdatesCheckedAt
  ... }`. Remove.
- Keep, unedited: `228-230` (`$Script:FlavourDefs.Product` - flavour
  detection, not launching).

Verify after: `[System.Management.Automation.PSParser]::Tokenize` on the
file returns zero errors; `grep -in "launcher\|battle\.net\|--exec"
addon-sync.ps1` returns nothing outside a renamed/updated comment.

### CS-R2 - `addon-server.ps1`: settings key + migration

- `1190, 1296, 1374` - `Get-Settings`/`Save-Settings` default and parse/
  passthrough of `autoUpdateOnLaunch`. Remove from the defaults object
  and the parse branch.
- **Migration** (new code, right next to the existing pattern): mirror
  the `cfApiKey` removal migration at `addon-server.ps1:1342-1353`
  exactly. That code, inside `Get-Settings`, uses `Get-Member -InputObject
  $obj -Name 'cfApiKey' -MemberType NoteProperty -ErrorAction
  SilentlyContinue` to detect a legacy property on every read regardless
  of its value, and if found, writes the in-memory settings object (which
  already lacks the field, since it comes from the new
  `Get-DefaultSettings`) back to disk via the normal atomic `Save-
  Settings` path, plus one `Write-ServerLog` line recording the drop.
  Add the identical check for `'autoUpdateOnLaunch'` immediately
  alongside it (same function, same read, one extra `Get-Member`/rewrite/
  log-line - do not invent a separate migration pass). This is what
  actually cleans Eric's live `settings.json` (see section 4) without
  ever hand-editing a file the running server also writes to.
- `6236-6238` - `PUT /api/settings` handling of `body.autoUpdateOnLaunch`.
  Remove.
- Keep, unedited: `37, 59, 142, 164` (WowDetector test hook / WowT label);
  `419-423` (`.Product` field); `155-201` and every game-mode consumer
  listed in section 1.2; `7055-7130` (self-relaunch-before-uninstall).

### CS-R3 - `addon-server.ps1`: remove the launch job kind and its wiring

Do this after CS-R2 (same file, but logically separate - settings vs.
job machinery).

- `2295-2337` - `Start-Job`'s synchronous "launch with `updateFirst=
  false`" branch (builds a `kind='launch'` job, `Start-Process
  Battle.net.exe --exec="launch WoW"`, synthetic "Launched" result row).
  Remove the whole branch.
- `2394, 2475, 2520, 2867, 3104, 3477, 2624` - `LaunchAfter = $false` /
  `$launchAfter` field set on every other job object. Remove the field
  from every job object once the launch-after-sync feature is gone.
- `2544-2548` - `if ($Kind -eq 'launch') { $cliKind = 'sync'; $launchAfter
  = $true }` mapping inside `Start-Job`. Remove.
- `3728-3735` - `Update-JobStatus`'s `if ($Job.LaunchAfter) { ...
  Start-Process Battle.net.exe ... }` post-sync launch. Remove.
- `3193, 3213, 3917` - job-kind arrays like `@('sync','check','add',
  'install','launch')` used for "counts as checking for updates". Change:
  drop `'launch'` from each array.
- `5755` - `$validKinds = @('sync','check','add','remove','install',
  'launch','rollback','switch-source','add-by-slug','update-all-
  flavours')` in the `/api/job` POST handler. Change: remove `'launch'`.
- `5456` - comment on `Test-DiagLastSync` referencing "...or the desktop
  shortcut's `-Launcher` path". Reword; the function itself stays.

Verify after: `grep -in "launch\b" addon-server.ps1` (word-boundary) turns
up only game-mode/self-relaunch/WowT hits from section 1.2's keep list.

### CS-R4 - `ui\index.html`

Do after CS-R2/CS-R3 land conceptually (so the SPA change sets below have
a stable server contract to match), but this file has no server
dependency itself and can be edited in parallel.

- `585-590` - delete `#btn-update-play` and `#btn-launch-wow`. Keep the
  `<div class="sidebar-bottom">` wrapper and everything at 591-601
  (freshness line, status line/dot/text) exactly as-is. See section 2.2.
- `625-627` - comment: `"Update & Play" (sidebar) is the only accent
  button in the app`. Reword: once this button is gone there is no
  sidebar accent button; state plainly that My Addons' Update all/Check
  now stay `btn-outline`/`btn-ghost` and nothing in the app is
  accent-colored any more (or name whichever element, if any, keeps that
  treatment after the concurrent lifecycle build's own changes land -
  re-check before writing this comment).
- `691-694` - comment referencing "the persistent sidebar 'Update & Play'
  CTA (`#btn-update-play`, itself never hidden at zero addons)". Remove
  or reword - the referenced element no longer exists.
- `856-874` - entire Settings row for "Update addons before WoW starts"
  (`#toggle-autoupdate` checkbox, its two `<p class="muted-text">` helper
  lines, and the Round-17 comment explaining why this row breaks the
  zero-prose rule). Remove the whole block.

Verify after: `grep -in "update.*play\|launch.*wow\|toggle-autoupdate"
ui\index.html` returns nothing.

### CS-R5 - `ui\style.css`

- `1201-1210` - `#btn-update-play` rule and its adjoining comment.
  Remove.
- `1062, 1125-1128` - `.sidebar-bottom`, `.status-dot`. Keep, unedited
  (see section 2.2).
- `3085-3520` range comments describing how each theme's hero art
  computes height against `.nav + .sidebar-bottom` - the CSS rules
  themselves need no edit (section 2.3); update a comment's wording only
  if it becomes actively misleading after the geometry re-measurement in
  CS-R21, otherwise leave alone.

### CS-R6 - `ui\app.js`, part 1: settings, fixtures, progress-kind arrays

- `225` - `mockSettings.autoUpdateOnLaunch` in the `?mock=1` fixture.
  Remove.
- `1076, 1230` - mock server's PUT/GET handling of
  `settings.autoUpdateOnLaunch`. Remove.
- `432-462` - `PROGRESS_KINDS = [...,'launch']` array and
  `buildProgressPlan`'s `kind==='launch'` branch. Remove `'launch'` from
  the array; delete the branch.
- `3698-3706` - a second `PROGRESS_KINDS`-shaped array/comment block
  later in the file. **Read the surrounding function scope at both
  locations first** to confirm this is a genuine second definition (not
  the same array read from two closures) - then drop `'launch'` from
  this one too.
- `776` - `hasInstallPhases = kind==='sync' || ... || kind==='launch'`.
  Drop the launch clause.
- `1988` - `if (j.kind === "launch") return true;` inside the
  job-is-progress-relevant helper. Remove.
- `871, 1662, 3893` - comments listing job kinds including `launch`.
  Reword to drop it.
- `5978, 6600` - Settings view: `#toggle-autoupdate` checked-state read
  and its change-listener `Actions.saveSettings({autoUpdateOnLaunch:
  ...})`. Remove both (the control itself is gone per CS-R4).
- Keep, unedited: `254-268, 356-367` (freshness fixtures), `914-931`
  (`?mock=1&game=1` wiring), `1819, 1829-1833` (Store defaults),
  `5694-5700, 6880-6963, 6998, 7434-7489, 7669-7670` (game-detection/
  freshness), `6058` ("launch this client once" - refers to the player
  manually starting WoW so Furphy can read `.build.info`, not to a
  Furphy feature).

### CS-R7 - `ui\app.js`, part 2: result rendering and status/toast maps

- `574-611` - `finalizeJobResults`' `kind==='launch'` branch (synthetic
  "Launched" row + "...then launched" summary). Remove.
- `730-737` - second `kind==='launch'` branch (`updateFirst:false` path).
  Remove.
- `2011, 4029` - comments referencing the synthetic "Launched" row / a
  "launchOnly launch job" having no `job.progress`. Remove or reword.
- `2594` - status-chip class map entry `"Launched": "chip-success"`.
  Remove.
- `3819-3893` - `order[]`/`labels{}` status maps including `'Launched'`/
  `'Rolled-back'`, the kind-to-label map's `launch:'Launching World of
  Warcraft'` entry, and the two toast-collapsing regexes
  `[/^Updating & launching/,'Updated & launched']` and
  `[/^Launching/,'Launched']`. Remove every launch-specific entry.
- `7258-7264` - post-job toast copy for `kind==='launch'` (the honest-
  caveat toast and "Addons updated. Check Battle.net...you may need to
  press Play." toast). Remove.
- Keep, unedited: `7284-7350` (`/api/state` poll handler - freshness and
  gameRunning fields, no launch code mixed in).

### CS-R8 - `ui\app.js`, part 3: the sidebar CTA functions and listeners

- `7084-7153` - per-flavour sidebar CTA logic (button label text for
  reliable vs. not-proven-reliable flavours, `#btn-update-play` lookup/
  span update). Remove the update-play/launch-wow-specific pieces. The
  shared busy-state id-list at line 7153 also disables/enables
  `btn-check-updates`, `btn-add-addon`, `myaddons-bulk-update`,
  `myaddons-bulk-uninstall` during a running job - **subtract only
  `'btn-update-play'`/`'btn-launch-wow'` from that array; do not rewrite
  it wholesale**, the other four ids must keep working exactly as
  before.
- `4661-4662` - `function updateAndPlay()` and `function launchOnly()`.
  Remove both entirely.
- `4988` - `Actions` export object's `updateAndPlay`/`launchOnly` entries.
  Remove both.
- `7537-7538` - `#btn-update-play`/`#btn-launch-wow` click listeners.
  Remove both.

Verify after (all three `app.js` change sets together):
`node --check ui\app.js` passes clean; `grep -in "launch\|update.*play"
ui\app.js` turns up only game-mode/freshness/comment hits explicitly
kept above.

### CS-R9 - `host\FurphyHost.cs`

No change. Grepped exhaustively for launch/Battle.net/bnet - every
"launch" hit is either `ActivateOrLaunch()` (the app's own window) or
`WowDetector`'s poll of whether `WoW.exe` is running. Nothing to remove.
Re-run the same grep once the concurrent lifecycle build's tray/uninstall
work has settled, purely as a sanity check that it didn't introduce
anything launch-related while this round was in flight.

### CS-R10 - `install.ps1`, part 1: flavour table and Battle.net probe

- `371-378` (verified directly - the inventory's "325-350" is the
  surrounding comment block) - `$Script:FlavourDefs` table: remove the
  `BattleNetCode` and `Reliable` columns from all six rows, keep
  `Id`/`Folder`/`Label`/`FirstClass`.
- `355-368` - the comment block above the table explaining
  `BattleNetCode`/`Reliable` (S4.7). Remove or fold into a shorter note
  that the table now only carries detection/first-class facts.
- `486` (FirstClass comment) - reword: FirstClass now governs which
  flavours get AddonSync installed and are eligible for the app's own
  shortcut concept, not "gets a launcher pair".
- `544` (`function Find-BattleNetExe`) - remove entirely; its only
  consumer is the launcher-writing section deleted in CS-R11.
- `1-9` (header comment: "writes a 'Launch WoW (Updated)' launcher pair
  into every...") - remove/rewrite to describe the actual current
  behavior once CS-R11/CS-R12 land.
- Keep, unedited: `547-594` (self-relaunch-before-uninstall - unrelated,
  see section 1.2).

### CS-R11 - `install.ps1`, part 2: stop writing launcher files/shortcuts

- `1030-1119` (verified: header comment 1030-1041, `Write-Step 'Writing
  launcher files'` at 1042, `$battleNetExe = Find-BattleNetExe` at 1044,
  the `foreach ($def in $firstClassInstalled)` loop 1048-~1119 writing
  `update-addons-and-launch.cmd` + `Launch WoW (Updated).vbs` per
  first-class flavour, ending with the two Battle.net-not-found
  `Write-Warn2` lines) - remove the entire "5. Launcher pair(s)" section.
- `1121-1163` ("6. Desktop shortcuts") - **keep** shortcut #1 (`Furphy
  Addon Manager.lnk`, the `$sc1 = ...` block) exactly as-is; **remove**
  the `foreach ($lw in $launcherWritten) { ... }` loop that creates
  `WoW (auto-update addons).lnk` / `WoW - <Label> (auto-update
  addons).lnk`. Since `$launcherWritten` is populated only by the
  section just deleted, initialize it as an always-empty list (or delete
  the loop and the now-unreachable variable together) rather than
  leaving a dangling reference.
- `910` - default settings.json literal `'{ "releaseType": 1,
  "autoUpdateOnLaunch": true, "port": 47831 }'`. Remove the
  `autoUpdateOnLaunch` field: `'{ "releaseType": 1, "port": 47831 }'`.

Verify after: a fresh install run (fixture WowPath) writes no `.cmd`/
`.vbs` file in the flavour folder and creates exactly one Desktop
shortcut, `Furphy Addon Manager.lnk`.

### CS-R12 - `install.ps1`, part 3: legacy-file cleanup on every run, not
just `-Uninstall` (fixes the confirmed upgrade-path gap)

**This is new work, not just a deletion - read this one carefully.**
Verified directly (`removal-research\verification-notes.md` item 1): the
`if ($Uninstall) { ... }` block runs from line 573 to its `exit 0` at
line 878, and the existing legacy-launcher-removal loop (inventory's
"752-767") lives entirely inside it. Immediately after that block closes,
`function Invoke-FurphyInstallSteps { ... }` begins (line 880) - the
plain install/upgrade path, shared by the console flow and the wizard,
with **no cleanup call in it at all**. Concretely: running
`install.ps1` again over an existing install (an ordinary upgrade, no
`-Uninstall` flag - exactly what shipping this removal to Eric's machine
is) leaves his stale `update-addons-and-launch.cmd`, `Launch WoW
(Updated).vbs`, and Desktop shortcut in place forever, because nothing
in the upgrade path ever looks for them.

Fix: add a new step near the top of `Invoke-FurphyInstallSteps` (where
the deleted "5. Launcher pair(s)" section used to sit is a natural slot),
that runs **unconditionally on every install/upgrade, first-class or
not, `-Uninstall` or not** (call it once, before the `-Uninstall`
early-return AND from inside `Invoke-FurphyInstallSteps`, or factor the
existing uninstall-path loop into a shared function called from both
places - either is acceptable, a shared function is preferred to avoid
the two copies drifting):

```
foreach flavour folder under $wowRoot (all six known flavours, not just
first-class - a stale file could exist under any of them from an older
version):
    remove <flavour>\update-addons-and-launch.cmd if present
    remove <flavour>\Launch WoW (Updated).vbs if present
remove <Desktop>\WoW (auto-update addons).lnk if present
remove <Desktop>\WoW - <Label> (auto-update addons).lnk for every known
    flavour Label, if present
```

This mirrors, and can reuse, the existing `-Uninstall`-path loop
verbatim - it is the exact same file list, just called from one more
place. Respect the existing `-NoShortcuts`/scratch-run safety checks
(`Test-LooksLikeScratchRun`) already guarding shortcut removal in the
`-Uninstall` branch; do not add a second, less careful copy.

Verify after: seed a fixture WoW tree with a stale launcher pair and
Desktop shortcut (mimicking a pre-2026-09-06 install), run `install.ps1`
WITHOUT `-Uninstall` against it, and confirm both are gone afterward.
This is exactly the new test to add in CS-R15.

### CS-R13 - `deploy.ps1`

- `122` - default settings.json literal with `autoUpdateOnLaunch:true`.
  Remove the field (mirrors CS-R11's install.ps1 edit).
- `163` - `New-Item ... (Join-Path $RepoPath 'launcher')` directory
  creation. Remove - the repo no longer needs a `launcher\` folder.
- `170-173` - foreach loop copying `update-addons-and-launch.cmd`/
  `Launch WoW (Updated).vbs` into the repo's `launcher\` directory.
  Remove entirely. Before deleting, `grep -n '\$retail\b' deploy.ps1` to
  confirm the `$retail` variable (defined earlier, consumed only by this
  block per the inventory) has no other reader - if it's now unused,
  remove its assignment too rather than leaving dead code.

### CS-R14 - Tests: delete whole files

- `tests\integration\Cli.LauncherBudgetOverride.Tests.ps1` - delete
  (entirely about the `-Launcher` wall-clock budget).
- `tests\unit\Cli.LauncherPerf.Tests.ps1` - delete (unit tests for the
  four functions removed in CS-R1).
- `tests\perf\Run-StateG.ps1` - delete (measures `-Launcher -Flavor
  retail` as "the exact command update-addons-and-launch.cmd runs"). Flag
  its corresponding row in `tests\perf\bench\BASELINE.md` for a follow-up
  edit (out of this round's line-numbered scope).

### CS-R15 - Tests: edit in place

- `tests\integration\Cli.InstallRollbackLauncher.Tests.ps1` - keep lines
  1-124 (three unrelated Describes: real CurseForge install/update,
  bogus project id, rollback-with-no-backup); rewrite the header comment
  at 1-11 (currently also describes `-Launcher`'s dry behaviour); delete
  the four `-Launcher`-only Describe blocks at 126-339 (dry behaviour,
  skip-if-recently-checked, does-NOT-skip-when-stale, two-real-child-
  processes race). Rename the file to `Cli.InstallRollback.Tests.ps1`
  since "Launcher" no longer describes anything left in it, and update
  its one cross-reference at `tests\integration\
  Server.FreshnessAndFlavours.Tests.ps1:191` and the two mentions in
  `tests\fixture-acceptance\FlavorsSpec.Section8.Tests.ps1:32,86`.
  **Add the new CS-R12 upgrade-path test here** (or in a new adjacent
  file if that reads cleaner): seed stale launcher files + shortcut,
  run install.ps1 without `-Uninstall`, assert both are gone.
- `tests\perf\Perf.Tests.ps1` - remove `$Script:LauncherFreshCheckMaxSec
  =3` (line 71), the settings fixture's `autoUpdateOnLaunch=true` (120),
  and the Describe "-Launcher with a fresh updatesCheckedAt finishes in
  under 3 seconds (launch-chain budget...)" (336-373). Leave the rest of
  the perf suite, including the fake-WoW steady-state scenarios, alone.
- `tests\perf\Measure-Furphy.ps1:117` - remove the `-launcher` command-
  line classifier branch (dead once nothing ever passes `-Launcher`).
- `tests\unit\Server.Handlers.Tests.ps1:168-183` - drop `'launch'` from
  the expected-kind test cases for `Get-ComputedFreshness`. Keep line 116
  (`/api/open` negative test, unrelated string) and lines 187-207
  (`updatesCheckedAt` freshness tests) untouched.
- `tests\integration\Server.Settings.Tests.ps1:25, 95-105` - remove the
  `autoUpdateOnLaunch===true` default-settings assertion and the
  `autoUpdateOnLaunch`-specific COERCE `It`; if that `It` also exercises
  another bool field (`adFilter`/`cfFocus`), keep the rest of it using
  that field, otherwise remove the whole `It`. **Add the new assertion
  the task calls for here**: after `Get-Settings`/`GET /api/settings`,
  the returned object has no `autoUpdateOnLaunch` property at all
  (mirror whatever pattern the equivalent `cfApiKey`-gone assertion
  uses, per E23, if one exists in this file).
- `tests\host\Host.Tests.ps1:173` - drop `autoUpdateOnLaunch=$true` from
  the fixture settings.json literal. Keep 455-463/575/647 (`clickOutcome
  | Should Be 'launch'` - the app's own window, unrelated).
- `tests\unit\Cli.ProgressMigrationZip.Tests.ps1:165` - reword the `It`
  description ("launcher-budget skip") since that framing no longer
  applies; the test and the `Skipped`-status function it covers both
  stay, they are not launch-specific.
- `tests\perf\Setup-Baseline.ps1:48` - remove `autoUpdateOnLaunch=$true`
  from the baseline settings fixture.
- `tests\run-all.ps1:14, 22-23` - reword the comments describing the
  perf layer's "-Launcher fresh-check budget" coverage, now that that
  Describe/constant/script are gone.
- `tests\lib\common.ps1:397-398` - reword the one comment mentioning "a
  real launch chain" (generic server-startup-timeout language, false
  positive on the word "launch"/"budget" - no functional change).
- Keep, unedited, no action: `tests\unit\Server.GameState.Tests.ps1`
  (whole file - required game-mode coverage), `tests\integration\
  Server.State.Tests.ps1:59`, `tests\integration\
  Server.FreshnessAndFlavours.Tests.ps1:44,55` (freshness, unrelated to
  launching), `tests\static\Test-BannedTerms.ps1`, `tests\static\
  Test-PackageAllowList.ps1`.

**Add the two remaining new assertions the task calls for:**

- "No launch strings in the DOM": extend `tests\static\
  Test-BannedTerms.ps1`'s banned-phrase list with `"Update & Play"`,
  `"Launch WoW"`, `"update-addons-and-launch"`, `"Update & Open
  Battle.net"` so this sweep (already run over `index.html`/`app.js`/
  `style.css`) fails the build if any of them ever reappear.
- "Install writes no launcher files": add to the renamed
  `Cli.InstallRollback.Tests.ps1` (or its own new file) an assertion that
  a fresh install run against a fixture WoW tree produces no `*.cmd`/
  `*.vbs` file anywhere under the flavour folder, and exactly one Desktop
  shortcut (`Furphy Addon Manager.lnk`) - this is the CS-R11 companion
  to CS-R12's upgrade-cleanup test above.

### CS-R16 through CS-R23 - Docs

Do these after the code/tests change sets land, except the URGENT item
flagged at the top of this document, which cannot wait for that.

**CS-R16 - `SPEC.md`** (heaviest doc file, ~20 line ranges):
`14` (drop the Battle.net launch-command clause from "Game facts");
`30, 32, 583` (drop `autoUpdateOnLaunch` from all three settings.json
literals - note line 583 is itself the "CS-R11 default literal" fact,
keep it accurate to the new literal); `50` (remove the whole `-Launcher`
param bullet); `75` (remove the whole `launch` job-kind bullet); `79, 89`
(drop `autoUpdateOnLaunch` from the documented `/api/state`/`PUT
/api/settings` shapes); `104` (replace the sidebar-layout description
per section 2 of this spec: bottom holds only the status line, no CTA);
`118` (drop the toggle clause, keep the release-channel clause on the
same line); `124` (drop "Launching WoW" from the example job-title
list); `125` (remove the whole Update & Play/Launch WoW mapping line);
`126` (keep - Furphy's own shortcut restart, unrelated); `130-131` (drop
the game-launcher `.cmd` sentence, keep the Addon Manager.vbs
description, consider renaming the section heading); `167-170, 174`
(keep - updatesCheckedAt persistence, still read by the SPA's own
auto-check feature); `222` ("sync/launch job" -> "sync job"); `232`
(remove the Mock-launch-job bullet); `283` (drop the `-Launcher`/
desktop-shortcut clause from the "Last sync" diagnostic description);
`390, 397` (drop both `-Launcher`-specific clauses); `402` (replace the
now-false "Update & Play already restarts the server" rationale with one
not tied to the removed feature - e.g. server restarts are simply
infrequent); `477` (remove the launcher-writing paragraph, but first
copy its general PS 5.1 "`+`-inside-`@()` array literal splits into
separate elements" lesson into the Hard Constraints list at line 12 -
that is reusable knowledge independent of the launcher feature); `478`
(drop the WoW-shortcut `.CreateShortcut()` bullet, keep Furphy Addon
Manager.lnk); `481` (reword to singular shortcut; keep a cleanup-step
mention, and make clear per CS-R12 that it now also runs on upgrade, not
uninstall-only); `496` (strike through per this doc's own `~~text~~` -
**removed, Round 34** house style, matching the pattern already used at
lines 119/404/415/449/458 - do not just delete the stale assertion
silently); `612` (update the Settings-row anchor reference once "Update
addons before WoW starts" is gone); `628` (drop the "...launcher/
installer changes..." clause); `666, 668` (drop "launch-chain budget"/
"launch-chain time cap" from the E28 title/intro, keep the gameRunning-
gating and process-priority parts); `670-696` (SUPERSEDED 2026-09-08,
GAME-MODE-SPEC.md - was "keep verbatim - this is the game-mode/
background-mode machinery required by section 1.2": keep only the
CPU/priority/decorative-gating parts of `670-696`; remove the
network-skip-while-playing and tray-cycle-skip content per the
2026-09-08 policy, GAME-MODE-SPEC.md); `687-
690` (remove the entire "Launch-chain cap" subsection); `698` (remove
just the launcher-budget perf scenario, keep the steady-state/WoW-
closed-resume scenarios in the same paragraph); `704` (remove the
launcher-budget-specific ACCEPTANCE clauses, keep the gameRunning/
background-mode ones); `920` (keep the Round-33 uninstall bullet as
legacy-file cleanup, but add a note that CS-R12 makes the same logic run
on upgrade too); `945` - **see the URGENT flag at the top of this
document.**

**CS-R17 - `FLAVORS-SPEC.md`** (~15-20% of the document; be surgical -
multi-flavour switcher/badge/Update-All content in the same sections
must survive untouched): remove principle 6 (line 16, "Honest about what
actually works" - launch reliability); remove line 82 (the
`wow_classic_anniversary` product-code recon note); change line 90
("shortcuts" -> singular); change line 137 (drop `autoUpdateOnLaunch`
from the settings.json fields list); remove section 4.7 entirely (lines
238-251, per-flavour `-Launcher` handoff + product-code table); remove
line 335 (Update & Play accent-color bullet); in section "6.3 Update &
Play / Update All" (345-360), remove the per-flavour button copy and the
"Launch product code override" advanced setting, **keep the "Update
All" button description verbatim**; remove the copy-table rows at
370-380 (Update & Play, non-retail play button, launch toasts, product-
code override, About-panel launch clause); remove section "7. Launchers,
installer, shortcuts" / "7.2 Shortcuts + Battle.net product codes"
entirely (389-404); change CS-F4's bullet at 499 (drop "Update & Play /",
keep "Update All"); change CS-F5 (502-505) - keep the `Find-WowRoot`
generalization and adopt-existing-folders loop, remove shortcut-
generation/product-code content, rename the change-set away from
"...+ launchers"; change CS-F7's bullet at 513 (drop the non-retail
launch-reliability CHANGELOG clause); change the backward-compat
assertion at 526 (launcher filenames/toast wording byte-identical claim
is now moot - rewrite or delete).

**CS-R18 - `SETTINGS-SPEC.md`**: remove the entire Row 2 block (72-87 -
key, label, both Round-17-locked helper lines, no-tooltip rule); renumber
every following row up by one; change line 462-463 (drop "sidebar Update
& Play / Launch WoW" from the "confirmed fine as-is" list). Leave line
754 (Battle.net as a capitalization example) - harmless, low priority.

**CS-R19 - `UX-SPEC.md`**: rewrite principle 4 and its state-table echo
(14, 64) - no element is "the one accent button" any more; state plainly
that every action is outline/ghost/menu (or name whichever element, if
any, keeps accent treatment after the concurrent lifecycle build's
changes - re-check before finalizing this wording). Remove the ASCII
wireframe row and matching bullet at 44/61 (redraw the home-screen mockup
per section 2 of this spec). Change line 93 (drop the Update & Play
cross-reference, keep the flavour-switcher/Update-All description).
Remove the "Update addons before WoW starts" bullet at 271. Keep line
299 (already self-corrected doc note about the never-shipped "Launch
product code override" row). Remove the copy-table rows at 364, 389-398.

**CS-R20 - `DISTRIBUTION-SPEC.md`**: **593-596 and 813-815 are the
URGENT items flagged at the top of this document - fix these first,
independent of this change set's ordering.** Drop the "Launch WoW
(auto-update addons)" button from the success-screen spec (593-596) and
from the build task-list item (813-815) - the success screen gets one
button, "Open Furphy Addon Manager", plus the reassurance line. Keep
465-467 as legacy-file cleanup, but add the CS-R12 note that this logic
now also runs on every upgrade, not uninstall-only. Change 478-479
(singular "the desktop shortcut"). Keep 893-898, 916 (harmless residual
"this round will never launch the real WoW client" caution).

**CS-R21 - `THEMES-SPEC.md`**: this is a live-measurement task, not a
text edit - re-measure `.snow-scene` (section 9.5, ~2089-2092) and
`.arcane-hero` (cross-referenced at 2085, its own table at "7.15-7.16")
with `getBoundingClientRect` against the real running app, at every size
and flavour-count combination the existing tables cover, AFTER CS-R4/
CS-R5 land. Pay special attention to 845x539/flavours=3 - predicted to
newly clear the 109px hide floor (section 2.3 above); confirm live
whether the art actually becomes visible there, and if so, get a design
sign-off that it looks right at that specific height (it was never
reviewed there before). Update every number in both tables to match.
Change the acceptance-checklist line at 2149 (drop "the Update & Play
button" from the never-overlaps list).

**CS-R22 - `README.txt`**: change 13-14 (drop "the launcher pair", singular
"the desktop shortcut"); remove 30, 32 (the WoW-shortcut bullet under
"TWO WAYS IN"; rewrite that section as a single way in - the Furphy Addon
Manager shortcut - once the second bullet is gone); remove the "Update &
Play" clause at 44; change 48 (drop "auto-update on launch" from the
Essentials list); change 55 (drop "and the launcher" - only the app/
server invoke addon-sync.ps1 now); change 60 (drop or repoint the
"auto-update flag" mention - point at `backgroundUpdates` if a flag needs
naming there at all).

**CS-R23 - `CHANGELOG.md`**: add the entry:

```
## Round 34 (1.15.0: no more game launching)

Removed every feature that launched or auto-updated-before-launching
World of Warcraft: the "Update & Play" and "Launch WoW" sidebar buttons,
the "Update addons before WoW starts" setting, the per-flavour launcher
files the installer used to write into each WoW client folder, the
matching Desktop shortcut(s), the server's launch job kind, and the
CLI's -Launcher mode (including its Battle.net product-code table and
45-second launch budget). The background update service already updates
addons on its own schedule, so a launch-time update path is redundant.
(SUPERSEDED 2026-09-08, GAME-MODE-SPEC.md - this template line used to
read "game-mode detection (never updating while WoW is running) is
unchanged": detection itself (Test-GameRunning/WowDetector/gameRunning)
stays, but addons now DO update while WoW is running - drop the
"never updating while WoW is running" claim if this entry is still
unadded to CHANGELOG.md when the game-mode round ships.)
Existing installs have their stale launcher files and shortcut removed
automatically the next time the installer runs, and a stale
autoUpdateOnLaunch key is dropped from settings.json automatically the
next time the server reads it.
```

---

## 4. By-hand deploy checklist for Eric's machine

Do this once, in this order, never via an automated test:

1. **Ship the code first.** Deploy the updated `install.ps1`,
   `addon-server.ps1`, `addon-sync.ps1`, and `ui\` to Eric's install the
   normal way (an install.ps1 upgrade run, per CS-R11/CS-R12). This is
   what makes CS-R12's new cleanup step actually run and CS-R2's
   migration actually fire - do the manual deletions below only after
   this step, not before, so nothing has to be re-created if the
   deployed code turns out to still need a file you already deleted by
   hand.
2. **Confirm the settings.json migration fired.** Restart Furphy's
   server/tray (the upgrade in step 1 should already have done this).
   Check `C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync\
   settings.json` no longer has an `autoUpdateOnLaunch` key. Do **not**
   hand-edit this file directly - it is actively read/written by the
   running server; let CS-R2's `Get-Settings` migration remove the key
   on its own next read, exactly like the `cfApiKey` removal did.
3. **Confirm CS-R12 already removed the legacy files.** If step 1's
   upgrade ran CS-R12 correctly, the two files below and the shortcut
   are already gone - check first before deleting anything by hand.
   Delete only what's still there:
   - `C:\Program Files (x86)\World of Warcraft\_retail_\
     update-addons-and-launch.cmd`
   - `C:\Program Files (x86)\World of Warcraft\_retail_\
     Launch WoW (Updated).vbs`
   - `C:\Users\drops\Desktop\WoW (auto-update addons).lnk`
   (This machine has only `_retail_` under the WoW root - confirmed, no
   other flavour folder to check here. If Eric ever installs a second
   flavour before this ships, its folder would carry its own copy of the
   first two files and its shortcut would instead be named
   `WoW - <Label> (auto-update addons).lnk`.)
4. **Confirm what stays.** `C:\Users\drops\Desktop\
   Furphy Addon Manager.lnk` must still exist and still open Furphy
   correctly - do not touch it.
5. **Smoke-test.** Open Furphy from its shortcut, confirm Settings no
   longer shows an "Update addons before WoW starts" row, confirm the
   sidebar bottom shows only the status dot (no buttons), and confirm a
   normal sync/update still works. (SUPERSEDED 2026-09-08,
   GAME-MODE-SPEC.md - this step used to also say "confirm the
   background service still skips updates while WoW is actually running
   (start WoW, confirm the tray/status line says so)": the background
   service no longer skips updates while WoW runs, so confirm the
   opposite instead - start WoW, run a sync/update, and confirm it
   completes normally with the reload/relog reminder shown per
   GAME-MODE-SPEC.md section 3.)

---

## 5. Acceptance checklist and screenshots

### 5.1 Functional acceptance

- [ ] `grep -rni "launch\|battle\.net\|--exec\|update.*play"` across
      `addon-sync.ps1`, `addon-server.ps1`, `ui\app.js`, `ui\index.html`,
      `ui\style.css`, `install.ps1`, `deploy.ps1` returns only hits
      explicitly kept in section 1.2 (game-mode detection, self-relaunch,
      the app's own window activation, WowT/`.Product` flavour-detection
      constants).
- [ ] `[System.Management.Automation.PSParser]::Tokenize` on
      `addon-sync.ps1`/`addon-server.ps1`/`install.ps1`/`deploy.ps1`
      returns zero errors. `node --check ui\app.js` passes.
- [ ] A fresh install writes no `*.cmd`/`*.vbs` launcher file anywhere
      under the WoW root, and creates exactly one Desktop shortcut
      (`Furphy Addon Manager.lnk`).
- [ ] Running `install.ps1` (no `-Uninstall`) over a fixture tree seeded
      with a legacy launcher pair + Desktop shortcut removes both (the
      CS-R12 regression test).
- [ ] `GET /api/settings` and `GET /api/state` never return an
      `autoUpdateOnLaunch` field; `PUT /api/settings` silently ignores
      one if a stale client sends it.
- [ ] A settings.json on disk carrying a stale `autoUpdateOnLaunch` key
      has it dropped, and the drop logged, on the server's very next
      read - verified with a fixture file, not by hand-editing Eric's
      live one.
- [ ] (SUPERSEDED 2026-09-08, GAME-MODE-SPEC.md - this item used to
      require that starting WoW, or the `--wow-fake`/
      `-WowFakeProcessName` substitute, still prevents the background
      service from updating: it no longer does. Detection itself
      (`Test-GameRunning`/`WowDetector`/`gameRunning`) is unchanged, but
      the background service now updates addons normally while WoW
      runs; confirm a job started with the fake-WoW substitute active
      completes and reports `reloadNeeded` instead.)
- [ ] `tests\static\Test-BannedTerms.ps1` fails if "Update & Play",
      "Launch WoW", "update-addons-and-launch", or "Update & Open
      Battle.net" ever reappears in `index.html`/`app.js`/`style.css`.
- [ ] `tests\run-all.ps1` (all layers) passes clean.

### 5.2 Screenshots to capture (Browser pane, `?mock=1`, both explicit
light and dark where the theme supports it is not required - match each
theme's own default)

Sidebar, full height, at **1056x720** and **2530x1591** (Eric's real
window proportions), for each of:

- [ ] `arcane-library` - confirm `.arcane-hero` renders at its new,
      taller height with no clipped/broken cat art at any flavour count
      tested (1 and 3 installed flavours, per CS-R21's re-measurement).
- [ ] `snow-day` - confirm `.snow-scene` at both flavour counts; pay
      specific attention to whether it is now visible at the previously-
      hidden 845x539/flavours=3 configuration (or the nearest reachable
      size to it within these two targets), and if so, that it looks
      complete, not squeezed or clipped.
- [ ] `lofi` - confirm the cityscape band behind the shorter
      `.sidebar-bottom` still reads cleanly, the status dot has enough
      contrast against whatever of the scene now shows through.
- [ ] `tokyo-rain` - same check as Lofi for its `::after` rain band.

Other screenshots:

- [ ] Settings > Updates group, both before/after diff or just after:
      confirm the removed row is gone and the group has no leftover gap
      or awkward spacing where it used to sit.
- [ ] Multi-flavour nav (2+ installed flavours, `?mock=1` fixture):
      confirm "Update All" still renders and works, and no per-flavour
      "Update & Play"/"Update & Open Battle.net" button exists anywhere
      in the nav or sidebar.

---

## Summary (12 lines)

Eric: no more anything that launches or auto-updates-before-launching
WoW, since the background service already covers updates. Remove the
Update & Play / Launch WoW sidebar buttons, the autoUpdateOnLaunch
setting, the CLI's -Launcher mode (Battle.net codes, 45s budget, 10-min
skip), the server's launch job kind, install.ps1's per-flavour launcher
files and WoW shortcut, and every doc line about launching. Keep game-
mode detection (Test-GameRunning/WowDetector/gameRunning) verbatim -
(SUPERSEDED 2026-09-08, GAME-MODE-SPEC.md - this summary line used to
end "the background service must never update while WoW runs": that
trailing clause is wrong now, the background service DOES update while
WoW runs; only the detection signal itself is kept verbatim) - and keep
updatesCheckedAt (the SPA's freshness feature still reads it). Sidebar
bottom keeps only the status dot/freshness line, no replacement CTA;
Arcane Library/Snow Day's hero art auto-grows into the freed flex space
(CSS unchanged, THEMES-SPEC geometry needs live re-measurement, the
845x539/flavours=3 Snow Day case likely newly clears its 109px hide
floor); Lofi/Tokyo Rain's fixed-height decorative bands are unaffected
by the flex change but will show more of themselves now that shorter
opaque buttons no longer cover part of them. Confirmed a real gap:
install.ps1's legacy-launcher cleanup runs only under -Uninstall today,
so CS-R12 adds it to the plain upgrade path too - this is what actually
cleans Eric's machine when the code ships, before the three remaining
files get deleted by hand. URGENT: DISTRIBUTION-SPEC.md's in-progress
installer-wizard success screen currently specs a brand-new "Launch WoW"
button - flag this to the concurrent lifecycle-build workflow now.

File: REMOVAL-SPEC.md
