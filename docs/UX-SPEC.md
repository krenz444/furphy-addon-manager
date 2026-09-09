# Furphy Addon Manager — UX Spec (authoritative)

Base proposal: **task-flow** (highest combined judge score, 152/159). Grafted in: minimal's word budgets, three-group Settings Essentials, and "download progress is a fast-follow" hedge; status-clarity's reused CSS tokens, explicit "Checking…" state, and a non-blank "Up to date" row treatment. Dropped: every idea flagged as a "worst idea" for any proposal (see judge notes) — most notably the double-duty status dot, the literally-blank "Up to date" row, and putting the CurseForge-links toggle in Settings Essentials.

Word budget (visible chrome text, excludes table/row data): My Addons ≤ 25 words · Browse ≤ 20 words before results · Settings Essentials ≤ 60 words total, plus a Round 17 (2026-09-04), Eric-requested exception: exactly two short muted lines (~27 words) under the auto-update toggle explaining how it actually works, not counted against the 60. Anything else over budget moves to Advanced or a per-item menu.

---

## 1. Principles

1. **One fact, one place.** Freshness ("is anything out of date") is computed once and rendered by one component, mounted in exactly two spots (sidebar, My Addons header) — no other element may compute or word it independently.
2. **A label over a sentence, a sentence over a paragraph, nothing over a sentence that states the obvious.** No visible sentence explains a WoW/CurseForge/PowerShell internal the player didn't ask about.
3. **Demote, don't delete.** Every existing capability stays reachable — in a per-row menu, a "Details" disclosure, or the single Advanced settings drawer — nothing is removed except two items that were pure jargon-restating-jargon with zero player value (the Compat hover tooltip, the Indexed/Live-match badge), plus (round 16, 2026-09-04) the CurseForge API key feature itself — Eric asked for that capability GONE, not demoted, so this rule doesn't apply to it (see §6.1/Expansion E23).
4. **One pill per row, no accent-colored action.** Status and Compat merge into a single prioritized pill. (Round 34, 2026-09-07: this principle originally reserved accent color for the sidebar's "Update & Play" button - that button, and every other launch-WoW feature, was removed entirely at Eric's request, see CHANGELOG.md. Nothing replaced it as "the one accent button" - every action in the app is outline/ghost/menu now.)
5. **Progress must be a bar, not a log.** Any operation that touches more than one addon shows a determinate n-of-N bar and a plain current-item line; the raw log is one click away, never the default view.

---

## 2. Freshness model + home screen

### 2.1 States (exactly five; "Checking" is transient, not a resting state)

| State | Headline | Color/dot | Trailing clause |
|---|---|---|---|
| Not checked yet | "Not checked yet" | grey, static | *(none)* |
| Checking | "Checking…" | accent orange, animated ring | *(none — replaces the old headline for the duration of a check/sync job)* |
| Up to date | "Everything's up to date" | green, static | "· checked 5m ago" |
| Updates available | "N updates ready" | amber, static | "· checked 5m ago" |
| Check failed | "Couldn't check — Retry" | red, static | "· last success 2h ago" |

Computed **server-side**, one enum, exposed as one new field on `/api/state`. Client never derives freshness from other fields.

Connectivity (can the UI reach the local server at all) is a **separate fact**, never folded into the freshness dot (folding these together was the #1 flagged risk of the losing proposals). Render it as a small dot in the sidebar that is colored grey/green at all times (so it never reads as "missing" or broken) but only carries visible text in the two problem states: "Connecting…" and the existing offline banner "Server not reachable — restart from the desktop shortcut." When connected and nothing is wrong, the dot shows with no label — silence, not absence.

### 2.2 Home screen (My Addons) — text wireframe

```
┌ Furphy ───────────────────────────────────────────────────┐
│ [cat/cityscape header art — unchanged]                     │
│                                                              │
│  My Addons (6)     Browse     Settings                     │
│                                                              │
│  ●  Everything's up to date · checked 5m ago                │
│                                                              │
├──────────────────────────────────────────────────────────┤
│  Search addons...              [Check now]  [+ Add addon]  │
│                                                              │
│  All 6   Updates 3   ⋯ More (only if a count > 0)           │
│                                                              │
│  ☐ Addon               Version              Status      ⋮  │
│  ☐ Auctionator          5.20.0 → 5.21.0     Update      ⋮  │
│  ☐ BigWigs Bossmods     Pinned · 424.3      Pinned      ⋮  │
│  ☐ Details! Damage...   1.9.2               Up to date  ⋮  │
│  ☐ Simple Damage Meter  —                   Retry       ⋮  │
└──────────────────────────────────────────────────────────┘
```
(Round 34, 2026-09-07: this mockup originally showed a sidebar row here with
"Update & Play"/"Launch WoW" buttons directly under the freshness headline -
removed at Eric's request along with every launch-WoW feature, see
CHANGELOG.md. The sidebar bottom now holds only the freshness headline and
status dot; no replacement button fills the space.)

### 2.3 State-by-state headline + button behavior

- **Not checked yet** — headline "Not checked yet", no trailing clause; toolbar "Check now" is the natural next action.
- **Checking** — headline "Checking…", animated ring where the dot sits. The n-of-N progress row (§4) appears directly under the headline when it's a multi-addon check; the toolbar "Check now"/"Update all" buttons disable for the duration.
- **Up to date** — headline "Everything's up to date · checked 5m ago". Toolbar "Update all" is **hidden entirely** (nothing to update — no dead/disabled button sitting there). Only "Check now" remains next to Add addon.
- **N updates ready** — headline "N updates ready · checked 5m ago", amber. Toolbar shows "Update all" (outline button - nothing in the app is accent-colored any more, see principle 4).
- **Check failed** — headline "Couldn't check — Retry · last success 2h ago", red. The word "Retry" is itself the clickable action (re-runs Check now); no separate button needed.
- **Updating (job running)** — headline row is replaced in place by the progress panel (§4): bar, n-of-N, current addon + phase line. Table rows for in-flight addons show "Installing…" in their own Status cell live, at the same time — this single duplication is intentional (it's spatially useful, not a contradiction, since both locations use identical wording).
- **Done, all succeeded** — panel collapses to "Updated N · checked just now" for ~4 seconds then reverts to the "Up to date" headline. No permanent "last run" line survives — this was found duplicated in 3 places today and is deleted outright, folded into the transient headline text.
- **Done, with failures** — panel stays open (does not auto-dismiss); each failed row shows a plain-language reason + inline **Retry** (§4). Headline behind the panel already reflects the new freshness state (e.g. "2 updates ready" if some rows still need it) so closing the panel never shows stale text.
- **No addons yet** — see §2.4.

### 2.4 Empty / first-run states

**True empty (nothing installed, nothing found in the AddOns folder):**
```
        No addons yet
   Add one by name, link, or ID.
        [ Add addon ]   [ Browse addons ]
```

**Found existing addon folders on first run** (the "take-over" dialog — renamed from "adopt"):
```
   Found 6 addons in your AddOns folder
   Furphy can start managing these — it re-downloads
   each one so it can keep them updated from now on.
   No CurseForge key needed.

        [ Skip ]              [ Take over all (6) ]
```
"Adopt"/"Adopting" is renamed to "Take over" in every visible string and button (internal function/variable names may keep "adopt" — only display text changes).

### 2.5 Multi-flavour switcher (Round 19, 2026-09-05)

`FLAVORS-SPEC.md` section 6 is the authoritative design for this addition — full detail, mechanics and copy live there; this entry documents only how it sits inside the layout above. A compact pill row — `[ Retail ] [ Classic ] [ Classic Era ]` — mounts directly under the `My Addons | Get new addons | Settings` nav row, above the freshness headline, only when more than one flavour is installed. It is **entirely absent from the DOM** (not `display:none`) below two installed flavours — principle 2 applies here exactly as everywhere else: this machine's header is byte-for-byte what it is today. Clicking a pill re-fetches that flavour's state and swaps every downstream fact (freshness headline, addon table, updated button labels) in place, no full reload. A separate, always-visible **"Update All"** button sits at the end of the pill row (only rendered alongside the switcher, same visibility gate) and syncs every installed, non-hidden flavour in one action without launching anything.

---

## 3. Installed addon row, per-row menu, detail drawer

### 3.1 Table columns (7 → 5)

`[checkbox] | Addon | Version | Status | ⋮`

- **Addon** — name, click opens the detail drawer.
- **Version** — `installed → latest` when an update exists (e.g. `5.20.0 → 5.21.0`); just `5.21.0` when current. Replaces the old separate "Installed" and "Latest" columns. This cell is purely informational (what version); the Status cell is the actionable one (what to do).
- **Status** — exactly one pill per row (see §3.2). When the pill is actionable, it doubles as the button (clicking "Update" on the pill starts that one addon's update; clicking "Retry" retries just that one).
- **⋮ kebab menu** — everything else (§3.3), unchanged from today's already-good pattern.

"Compat" is deleted as its own column — its information is folded into Status. "Updated [date]" (last-installed date) moves into the kebab menu as an info line — not a daily-glance fact.

### 3.2 Status pill vocabulary (priority order — a row shows exactly one)

| Priority | Pill text | Color | Meaning / when shown |
|---|---|---|---|
| 1 | **Couldn't update — Retry** | red | last attempt for this addon failed; Retry re-runs just this one |
| 2 | **Needs: [Addon Name]** | red | a required dependency isn't installed; names it directly, no hover needed |
| 3 | **Update** | amber, button | a newer version exists and the player hasn't chosen to ignore updates for it (the Version cell already shows the diff; this pill is the one-click fix) |
| 4 | **Old patch** | amber | installed version predates the player's WoW patch, and no newer file exists to fix it |
| 5 | **Won't work this patch** | red | addon has no version compatible with the client at all |
| 6 | **Pinned · 424.3** | blue-grey | won't auto-update; version shown inline, no second pill |
| 7 | **Ignoring updates** | grey | update exists but the player chose to skip it |
| 8 (default) | **Up to date** | grey, low-weight text (not fully blank — a truly empty cell reads as a rendering bug) | nothing to do |

The old hidden hover tooltip ("Toc Interface: 12.1.0 (120100) · Newest known file supports…") is **deleted outright, no replacement** — it restated the visible pill in raw jargon and helped nobody decide anything.

### 3.3 Kebab (⋮) menu — unchanged set, unchanged order

Update now · Versions… · Pin current version / Unpin · Ignore updates / Stop ignoring · Installed [date] (info line) · Open on CurseForge/Wago · Uninstall.

### 3.4 Filter chips

Only **All** and **Updates** are permanent. Every other status (Pinned, Ignored, "Couldn't update", "Needs another addon") appears as a chip **only when its count is > 0**, grouped under a single **"⋯ More"** popover once there is more than one extra chip to show. A clean install shows just "All 6".

### 3.5 Detail drawer

```
┌ Auctionator ───────────────────────── [×] ┐
│ by Sylvanaar · CurseForge                  │
│              [ Update now ]                │
│  Overview | Versions | Changelog | Screenshots │
│  Built for patch 12.1                      │
│  ⚠ Add a free API key in Settings to see    │
│    descriptions, changelogs and screenshots. │
└───────────────────────────────────────────┘
```

**Bug fix, required, not optional:** the header must render the addon's real tracked name/author from `Store.state.addons` (already known locally the instant a row is clicked) — it must never fall back to the raw catalogue placeholder ("Project 68304 / by Sylvanaar / via catalogue"). Only the metadata-dependent parts (description, changelog, screenshots) may show their own loading/keyless state while the name is already correct. This was independently flagged by every judge as the single worst functional defect in the app and ships as part of this same change set (see CS2).

- "via catalogue" badge — deleted; source shown as a plain "CurseForge"/"Wago" chip, same as everywhere else.
- Overview compatibility line shown once, in the same plain words as the table Status pill ("Built for 12.1" / "Old patch" / "Won't work this patch") — no separate restatement, no raw interface-version numbers.
- Changelog (keyless): "Add a free API key to see changelogs." (drop the Wago-matching parenthetical aside).
- Versions tab — unchanged, already a good example of appropriately-detailed, one-click-deep power info.

---

## 4. Update progress mechanism (exact)

### 4.1 `addon-sync.ps1` — writes `progress.json`

- New param `-ProgressPath <path>`. If absent, every write below is a no-op (fully backward compatible with any manual/external invocation).
- New helper `Write-ProgressStep` (mirrors `Write-Log`, line 139): serializes a small object to a **temp file**, then `Move-Item -Force` over `-ProgressPath` — atomic, PS 5.1-safe, so the server never reads a half-written file.
- JSON shape written each time:
  ```json
  { "total": 5, "index": 2, "addon": "Auctionator", "phase": "downloading",
    "bytesDone": 812000, "bytesTotal": 1270000 }
  ```
  `phase` is one of: `queued` · `checking` · `downloading` · `installing` · `up_to_date` · `done` · `failed`. `bytesDone`/`bytesTotal` are present only during `downloading` when the byte-progress enhancement (§4.4) is live; otherwise omitted.
  - **Implemented (CS1) — one field added beyond the example above, not anticipated by the original draft:** a `failed` write additionally carries `"failPhase"`, one of `checking`/`downloading`/`installing` (never `failed` itself) — the phase this particular addon was in when it failed, e.g. `{ "total": 5, "index": 3, "addon": "Auctionator", "phase": "failed", "failPhase": "downloading" }`. Populated from a local `$currentPhase` tracker inside `Sync-SingleAddon`/`Sync-SingleWagoAddon` (starts `'checking'`, advances right before the `downloading`/`installing` writes), returned on the function's `Failed`-status result object as a `FailPhase` NoteProperty (mirrors the existing `FileId`-on-`Would-update` pattern), and forwarded into the final per-addon write by the main loop (point 5 below) — never overwrites the CLI's `-Json` stdout row shape, which stays `{status,name,version,projectId,fileId,wagoSlug}` exactly as before. This is what §4.3's "map `failPhase` to a plain sentence" is meant to read.
- Call sites inside the existing main loop (~line 3574, shifted from the pre-CS1 estimate by earlier additions) and `Sync-SingleAddon`/`Sync-SingleWagoAddon` (~line 2046+):
  1. Once, before the loop starts: `{total, index:0, addon:null, phase:"queued"}`.
  2. Immediately before calling `Sync-SingleAddon`/`Sync-SingleWagoAddon` for each addon: `phase:"checking"`.
  3. Inside `Sync-SingleAddon`, right before `Get-DownloadedZip`: `phase:"downloading"`.
  4. Right before `Install-AddonPackage`: `phase:"installing"`.
  5. After the addon's result is known: bump `index`, write the mapped final phase from the already-computed `$rowResult.Status` (`Up-to-date`→`up_to_date`, `Failed`→`failed`, `Installed`/`Updated`→`done`; every other status — `Ignored`/`Pinned`/`Skipped`/`Would-update`/`Unignored` — was not called out explicitly here, so CS1 defaults them to `done` too: processing for that addon is over, without asserting a success/failure it didn't earn). A `Failed` row's write also carries `failPhase` (see above) when the function set one.
- **The final `-Json` stdout contract (`Write-Host (ConvertTo-Json …)`, ~line 3699) is untouched.** This is purely additive telemetry the server reads mid-run. Verified (CS1): a live `-Status -Json` run's top-level key set is exactly `action, addons, clientBuild, clientInterface, results` — no `progress`/`failPhase` leakage — and a real forced-failure row's shape is still bare `{status,name,version,projectId,fileId,wagoSlug}`.
- Each caught exception at a failure site also stamps which `phase` it happened in (already known from the call site), so the server/UI can map it to a plain sentence (§4.3) without parsing exception text. **Implemented (CS1) as `failPhase` — see above.**

### 4.2 `addon-server.ps1` — exposes `job.progress`

- `Build-CliArgs`/`Start-Job` (~lines 821, 976): thread `-ProgressPath (Join-Path $Script:JobsDir "$jobId.progress.json")` for `sync`/`check`/`add`/`install` job kinds.
- `Update-JobStatus` (~line 1987, inside the existing `state -eq 'running'` branch, alongside the current sync.log tail at 2018-2052): add a **read-only, best-effort** read of that file (`Test-Path` + `ReadAllText` + `ConvertFrom-Json`, wrapped in try/catch exactly like the log-tail block, since the CLI may be mid-write) and stash the parsed object as `$Job.progress`.
- `Get-JobStatusView` (~line 2152): add `progress = $Job.progress` to the returned object — one new field, every existing field unchanged.
- Freshness persistence fix: `Apply-JobCompletionSideEffects` (~lines 1660-1700) gains a failure branch that sets `$Script:LastCheckFailed = $true` / `$Script:LastCheckError = <message>` (mirrors how `$Script:UpdatesCheckedAt` is already set on success), so a failed check is visible in the freshness headline after reload, not silently overwritten by the old "checked X ago" timestamp. `/api/state` exposes `lastCheckFailed`/`lastCheckError` alongside `updatesCheckedAt` and the computed `freshness` enum.
  - **Implemented (CS1) — mechanics not spelled out above:** `Update-JobStatus` now calls `Apply-JobCompletionSideEffects` on **both** outcomes (previously success-only) — the function's new failure branch checks `$Job.state -eq 'failed'` first and `return`s immediately after setting the two script vars, before touching `updateAvailable`/`lastRun`/`updatesCheckedAt`, so a failed job's effect stays scoped to exactly those two fields (no unrelated finalize-path behavior changes). A successful call clears both vars first (so a later success un-sticks the headline from `check_failed`). `$Script:LastCheckFailed`/`$Script:LastCheckError` are **in-memory only**, initialized `$false`/`$null` at startup near `$Script:UpdatesCheckedAt` — never added to `Save-CheckState`'s persisted body, per the "no changes to `Save-CheckState`" rule above, so a server restart forgets a stale failure rather than resurrecting one from a previous run. `freshness` is computed by a new `Get-ComputedFreshness` helper (next to `Get-CurrentOrLastJobSummary`): `checking` when the current/last job is `running` and its `kind` is one of `sync`/`check`/`add`/`install`; else `check_failed` when `$Script:LastCheckFailed`; else `not_checked` when `$Script:UpdatesCheckedAt` is unset; else `updates_available` when `$Script:UpdateAvailable` is non-empty; else `up_to_date`. `Get-JobStatusView`'s new `progress` field (previous bullet) is populated via `Add-Member -Force` on the live `$Job` object rather than a field declared at every job-creation site, since PowerShell lets a `PSCustomObject` gain a new NoteProperty that way but throws on a plain `$obj.newProp = x` when the property was never declared; `$Job.ProgressPath` (which call site's progress file to poll, `$null` for every job kind that gets none) *is* declared at Start-Job's single job-creation call site for the same reason, since every other kind's Job object never needs writing to it.
- No changes to `Test-JobBusy`, `Add-JobToHistory`, `Save-CheckState`, or the finalize/done path structure.
- **Verified (CS1) against a real server on port 47899** (see this change set's own verification notes): a real `sync` job's `progress.json` sequence for one real addon was `checking` (275ms) → `downloading` (687ms) → `installing` (1449ms) → `done`/index bumped (1559ms); a forced failure (`-Only <real project>` with a nonexistent `-FileId`) produced `checking` → `{"phase":"failed","failPhase":"checking"}`; corrupting `addons.json` (forcing CLI exit code 2) flipped `/api/state`'s `freshness` to `check_failed` with `lastCheckError` set, and a subsequent successful job reverted it to `up_to_date`/`updates_available` as appropriate.

### 4.3 UI — what it polls and renders

- `pollJob` (app.js ~line 5187): interval `800ms` → `500ms`.
- `Components.JobPanel.update(job)` (app.js ~2840-2926): primary view becomes a determinate `<progress>` (or styled bar) driven by `job.progress.index/total`, a label "Updating {index} of {total} addons…" (or "Checking…" for a check-only job, indeterminate style), and one current-item line: "{Phase word} {addon}" — Checking / Downloading (+ `%` from `bytesDone/bytesTotal` when present) / Installing.
- The raw `job.log` (today's `#job-log` scrolling text) moves behind a **closed-by-default "Details ▾" disclosure** in the same panel — never deleted, never the default view.
- **Done state**: one clean per-addon list only (delete the old triple-duplication of raw log + pill list + live table). Failed rows get a plain-language reason mapped from the `phase` the failure occurred in, plus an inline **Retry** scoped to that single addon (re-posts the job with the server's existing single-target `sync`/`add`/`install` param — no new server logic needed):
  - failed during `downloading` → "Couldn't download the update"
  - failed during `installing` → "Couldn't install the update"
  - no compatible file found → "No matching version found"
  - CurseForge/Wago outage while checking (`failPhase: "checking-network"`, Round 38 - a thrown network/parse error while fetching the file list, distinct from the deliberate "no compatible file" result above so a transient outage never reads as a permanent incompatibility) -> "Couldn't check for updates - CurseForge might be having trouble"
  - network/connectivity error → "Couldn't reach CurseForge — check your connection"
  - anything else → "Something went wrong" (generic fallback)
  - Raw exception text stays available behind that row's own "Details", never shown by default.
- Table rows for in-flight addons show the identical phase word in their own Status cell live (§2.3) — same wording, same source data, intentionally kept.
- **Round 19 (multi-flavour)** — the job panel gains a small flavour-label badge next to a job's title (reusing the switcher's own pill styling, §2.5), shown only when more than one flavour is installed — a Retail-only machine's panel is unchanged. A job the server can't yet assign to one flavour (an ambiguous CurseForge install, §5's install-flavour picker) shows no badge and instead renders the picker in place of the normal progress view until the player answers it.

### 4.4 Download byte-progress — feasibility note (fast-follow, not a blocker)

`Invoke-WebRequest -OutFile` (used by `Get-DownloadedZip`/`Invoke-CfRequest`, ~lines 118-124, 349, 361) gives no progress callback in PS 5.1, and the script explicitly sets `$ProgressPreference = 'SilentlyContinue'` to suppress its native bar. Getting `bytesDone/bytesTotal` requires swapping that one call for `[System.Net.HttpWebRequest]` + a buffered `[System.IO.FileStream]` read loop, throttled to ~250ms/~256KB per `Write-ProgressStep` call, with the existing 429/403 retry and pacing logic in `Invoke-CfRequest` wrapped around it unchanged. **This is optional for the first ship.** The phase-only bar (no byte percentage, per-addon n-of-N and a "Downloading…" label with no `%`) is fully correct and ships first; the byte-level rewrite is a self-contained follow-up limited to one function, done whenever there's room in the schedule.

---

## 5. Get new addons (was "Browse")

Rewritten round 15 at Eric's request, verbatim: *"i dont like the weird tab thing on the left with furphy and curseforge - get rid of that. rename browse to get new addons. at the top of get new addons screen, let user switch between wago in app search, and curseforge, which browses the site contained in the area that the wago search was in, one unified experience."*

This supersedes §5.1's CS3-era merged CurseForge+Wago grid entirely. Two changes, together: (1) the native host's left tab strip (Furphy/CurseForge WinForms panel) is deleted outright — the native window is the SPA, edge to edge, and the CurseForge site is instead an embedded pane the *page* places inside this screen; (2) "Browse" is renamed "Get new addons" everywhere visible (nav item, headings, empty-state buttons, dialogs, hints — internal identifiers, `?view=browse`, and the `Views.browse` module name are all unchanged, per principle 3's demote-don't-delete spirit applied to code, not just UI).

### 5.1 Layout — a segmented switch, not a merged grid

```
┌──────────────────────────────────────────────────────────┐
│  [ Wago | CurseForge ]                                     │
│                                                              │
│  🔍 Search Wago addons...                                   │
│                                                              │
│  [logo] Auc Advanced      [logo] Tidy Bags     [logo] ...   │
│  Wago                      Wago                  Wago       │
│  [Install]                 [Install]              [Installed]│
│                                                              │
│  Not on Wago? Try CurseForge                                │
│  Or paste an addon's CurseForge page link or number         │
└──────────────────────────────────────────────────────────┘
```

- **One segmented switch, two segments, top of screen.** Replaces both CS3's single merged search box *and* the native host's own left-side Furphy/CurseForge tab strip — there is now exactly one place in the whole app where the player chooses a source, and it lives inside the content area, not the window chrome. The choice persists across reloads (`localStorage`, default **Wago**) and is deep-linkable (`?view=get-new-addons&tab=wago|curseforge`; `?view=browse` keeps working as an alias, `?tab=` alongside it too).
- **Wago segment** — the pre-existing in-app search box + results grid, unchanged in mechanics (debounced input, relevance-tiered results, the existing Install → Installing… → Installed state machine, the existing Wago source badge on every card) but **Wago-only now** — the CurseForge half of CS3's merged search is gone from this screen. CurseForge's `/api/cf/*` endpoints are untouched server-side and keep backing add-by-link resolution and the detail drawer's keyless enrichment (§3.5/§6.1) — they're simply not queried for in-app search results here any more.
  - Fallback area under the results grid (unchanged placement, reworded): **"Not on Wago? Try CurseForge"** replaces the old "Not finding it? Search CurseForge.com directly" — in the native host it switches to the CurseForge segment; everywhere else it opens the existing chromeless side window directly (the `'cf-window'` `/api/open` target), since switching segments there would only land on that segment's own "browsing happens in the desktop window" panel. **"Or paste an addon's CurseForge page link or number"** is unchanged, reusing the existing Add-addon dialog.
  - The old keyless-CurseForge nudge ("Search results are limited without a CurseForge key") is deleted outright — Wago search never needed a key, so nothing about this segment is affected by one being missing.
- **CurseForge segment (native host, `cf-pane` capability)** — the real curseforge.com website, rendered by a WebView2 overlay the *native host* positions over this segment's content area (where the Wago results used to sit), edge-to-edge. The page draws an HTML toolbar above it — Back, Forward, Reload, Home (curseforge.com/wow/addons), a "Search CurseForge..." field (Enter navigates to CurseForge's own search results page), and the current page title, muted, sourced from the host. Toasts, while this segment is showing, render over the sidebar (bottom-left) instead of their usual top-right spot, since a native child window always paints above ordinary HTML regardless of z-index and would otherwise cover them there; any dialog/drawer/popover opening on top of the pane tells the host to hide it (re-shown, page still loaded, once the last one closes) for the same reason. The job progress panel (§4), while this segment is active, renders **inline** between the toolbar and the site instead of floating — a CurseForge Install click shows progress right above the page it was clicked on, and the site area shrinks to make room automatically. **Round 17 (2026-09-04)** — Eric: "make the curseforge search contained in the app go to the bottom of the window content." The pane (toolbar + optional inline job panel + placeholder) now fills the content area exactly down to its bottom edge on this segment, with the page itself not scrolling (the site scrolls inside the pane) — replacing an earlier fixed-height guess that could leave a gap or overshoot depending on window size. My Addons, Settings, and the Wago segment are unaffected and keep ordinary page scrolling.
  - **Focus view (round 16, SPEC.md's "E22")** — on a CurseForge addons-listing or search-results page, the pane shows only the results column: it starts at the row carrying the page counter/project count/sort control ("1 of 500" / "10,000+ Projects" / "Relevancy") and runs through the result cards and the pagination beneath them. Everything above and around that — the promo banner, CurseForge's own global header/nav and sign-in, the game hero/title block, the in-site Discover/Browse-All tab + search box, the left filter sidebar, and the site footer — is hidden, since the app's own toolbar (above) already offers search, home, and back/forward, and nothing is lost by trimming CurseForge's copies of them. A CurseForge addon/project detail page is unaffected beyond the same global chrome (banner/header/footer) — its own content, sidebar, and download button are untouched; this is deliberately not the same "sidebar" Eric asked to hide. On by default; a Settings > Advanced > Browsing toggle ("Show only search results on CurseForge," §6.2) turns it off for anyone who wants CurseForge's page as-is. If the host can't confirm the results column is actually there, it shows the page untrimmed rather than risk an empty-looking pane.
- **CurseForge segment (plain Edge-window install, or an older host without `cf-pane`)** — a compact panel: "CurseForge browsing happens inside the Furphy desktop window.", a button "Open CurseForge in a window" (the existing chromeless side window, `'cf-window'` target), and the same "Or paste an addon's CurseForge page link or number" fallback. The one-time "Install links aren't set up to open in Furphy" note (unchanged copy) can still appear here after that window is opened, same as before — the embedded pane has no such OS-level protocol handoff to fail.
- **Result card fields (Wago segment)** — unchanged from CS3: name + logo (may be absent) + source badge + Install button always present; summary/author/downloads omitted entirely (never blanked) since Wago cards never carry them.
- **Round 17 layout change (2026-09-04)** — Eric: "change the wago results to a curseforge style listing, they go the whole distance horizontally instead of little tiles." The Wago segment's results grid becomes a single-column list of full-width rows in CurseForge's own listing shape: a ~56-64px logo on the left (letter-tile fallback unchanged), name (bold) with the Wago source badge beside it and author underneath when known, a one-line summary when supplied, a small meta row (downloads/updated when present), and the Install/Installing…/Installed button right-aligned and vertically centered. Hover and keyboard-focus states are new (the old tile cards had neither); the row still opens the drawer on click or Enter/Space, and the Install button's own click still stops that from also firing. `.browse-card`/`.browse-grid` are renamed `.browse-row`/`.browse-list` (style.css) — no dead tile CSS left behind.
- **No category filter, no sort dropdown, no pagination** on the Wago segment — unchanged reasoning from CS3 (Wago's own sort is constrained upstream to two usable values); the CurseForge segment needs none of this either, since it's the real site with its own full search/sort/categories.

  **Round 35 (2026-09-07, Expansion E29): SUPERSEDED.** Eric's explicit new request - "for wago, i need a really good category based interactive browsing experience, i want users to be able to sort by popular, new, categories, rising in popularity, installs during the current season, etc" - directly reverses this line. The Wago segment now has a persistent category chip strip (29 categories + All) and a four-way sort control (Popular / Recently updated / Name (A-Z) / Gaining this week) plus "Load more" pagination - see `WAGO-BROWSE-SPEC.md` for the full design. The CurseForge segment is unaffected by this change and still needs none of this, for the same reason stated above. A future audit should read this as the new standing decision for the Wago segment specifically, not a regression against the line above it.

  **What ships.** The search box's placeholder is context-aware - "Search Wago addons..." on "All", "Search in <Category>..." once a category chip is picked - and reads "Not available on Gaining this week" (disabled) whenever that tab is active. Sort tabs, left to right: **Popular** (default - Wago's own order, no `sort=` sent at all), **Recently updated** (tooltip: "Sorted by each addon's own last-updated date, within the current results." - a page-local re-sort of whichever page Wago's own popularity order already returned, never a fabricated global recency sort), **Name (A-Z)**, and **Gaining this week**. The category strip lists all 29 of Wago's own categories plus All, in the server's own order verbatim (including category id 5's genuinely out-of-numeric-sequence position), collapsed by default to a curated subset with a "More categories +N" toggle that expands the rest inline. Every row shows author, summary, downloads, and updated-date whenever Wago's own card actually supplied them - never invented, never left blank where Wago gave something.

  **Honesty, stated once, binding everywhere in this segment.** Eric asked for "new," "rising in popularity," and "installs during the current season" alongside Popular and Categories. Wago exposes no creation date, no rising/trending signal, and no season concept at any price, so none of those three ship under their own name. "New" ships honestly as "Recently updated." "Rising in popularity" and "installs this season" ship as **"Gaining this week"** - a measurement Furphy takes itself from its own daily snapshots of Wago's popular list, not a number Wago publishes - and every surface that shows it says so out loud: the tab's own tooltip ("Furphy's own measurement, not a number Wago publishes."), the not-ready state ("Still gathering data" plus an honest earliest-possible date, never a promised schedule, plus the real snapshot count so far), the ready state's page-level currency line ("Based on downloads Furphy measured through <date> - looking only at Wago's current top ~150 popular addons."), and each row's own delta ("+<N> since <date>" beside a leading rank number). Gaining this week ignores the search box and every category chip - both are visibly disabled while that tab is active, with one shared note above the list: "Gaining this week shows Furphy's own top movers across Wago's popular list - it isn't split by category or search yet." "Installs during the current season" never ships under any label anywhere - there is no such number to show honestly, so it is simply not shown. Banned terms: the unchanged section 11 list, plus this round's own addition - "new," "rising," "trending," and "this season" never appear as a label, a tab name, or a tooltip anywhere in the Wago segment; "Gaining this week" is the only new-data-adjacent string in the whole design, and every one of its surfaces states outright that it is a Furphy measurement, not a Wago one.

  **Game state (2026-09-08, superseded).** Wago browsing now works fully while a WoW client is running - real, live results and real network calls, exactly the same as when WoW is closed. There is no blocked-state banner any more (see CHANGELOG.md's Round 43 entry). Gaining this week was never affected by game state either way - it's a disk read of Furphy's own snapshots, never a live Wago call.

- **`curseforge://` protocol toggle** — still not on this screen at all. Its one home stays Settings > Advanced (§6).

### 5.2 Native host chrome — what round 15 removes

The native host (`host\FurphyHost.cs`) previously showed a left-side WinForms panel with two tabs ("Furphy"/"CurseForge") and its own toolbar (back/forward/home/search) for the CurseForge `WebView2`. Round 15 deletes all of it: the native window becomes the SPA only, edge to edge — no tab strip, no WinForms toolbar. The CurseForge `WebView2` still exists inside the host, but it is now a plain positioned child control the *page* controls entirely (SPEC.md's new "E21" section has the full page↔host message contract: `cf-show`/`cf-rect`/`cf-hide`/`cf-nav` from the page, `host-ready`/`cf-state`/`cf-job` from the host). Everything else about the host — the ad filter, `curseforge://` link interception, theme/title-bar sync, DPI awareness, window-bounds persistence — is unchanged, just no longer anchored to a tab strip that no longer exists.

### 5.3 Install-flavour picker (Round 19, 2026-09-05)

On a multi-flavour machine, an ambiguous CurseForge install (a file that supports more than one installed flavour) surfaces a small modal reusing the switcher's own pill styling, title **"Which version of WoW?"**, one pill per matching flavour — picking one resumes the install for that flavour. A file supporting only one installed flavour installs there silently, no prompt; a file supporting none fails immediately with **"This addon doesn't support your installed WoW versions."** — full resolution logic in `FLAVORS-SPEC.md` section 5.5. This is the **only** new dialog this whole feature introduces anywhere in the install flow, and it never appears at all on a single-flavour machine.

---

## 6. Unified Settings

One page, two tiers: **Essentials** (always expanded, 2 groups, <= 60 words total) and one collapsed **Advanced** disclosure holding everything else. No more 10 flat equal-weight cards.

**Round 16 (2026-09-04, Expansion E23):** Essentials originally had a third group here, "CurseForge key (optional)" (below, struck through) - it is REMOVED, not collapsed or relocated, per Eric's explicit request that the CurseForge API key be cleared and removed as a feature entirely. There is no key row anywhere in Settings any more, Essentials or Advanced.

**Round 17 (2026-09-04):** the word budget below is revised from "zero helper prose" to allow exactly two short muted lines under the auto-update toggle, at Eric's explicit request - see the Updates group below and principle 2's own carve-out.

**Round 18 (2026-09-04):** the Updates group gains three more rows (background updates, its interval, start-with-Windows) plus one muted status line - a SEPARATE, narrower carve-out from Round 17's: this new status line is the ONLY prose these three rows get, no explainer sentence on any of them (unlike the auto-update toggle's own two-line exception just above, which is unchanged and stays exactly as wide as Round 17 left it). Appearance's Theme control is replaced by a swatch-grid picker - see below.

**Round 33 (2026-09-06, uninstall + distribution) - adds one new row to 6.2's "Backup & troubleshooting" group, everything else below is unchanged.** Eric's verbatim ask, in relevant part: "from the taskbar, i need a right click option to uninstall furphy addon manager ... / from in the app, i need this functionality as well." `DISTRIBUTION-SPEC.md` (new this round, shipped in this same folder) is the authoritative source for the full uninstall/tray/distribution design; this file only carries the one Settings-facing change it produces. New Row 19, "Uninstall Furphy Addon Manager," slots into Group 8 as a new final cluster - after Row 18 Diagnostics, separated by the same thin border-top divider already used between this group's other clusters, still inside Group 8's bordered box (the unboxed About footer line stays after it, outside any box, unchanged). (Row numbers here match `SETTINGS-SPEC.md` as of Round 34, 2026-09-07, which renumbered every row after removing its old Row 2 - see CHANGELOG.md.) See the Backup & troubleshooting bullet below for the row's own copy.

**Round 32 (2026-09-06, Settings simplification + tooltips) - SUPERSEDES 6.1 and 6.2 below with the row-by-row structure that follows.** Two verbatim asks from Eric drove this round. The broad one: "after these do a full settings ui/ux audit, make it as simple and easy to understand as possible for everything, add tooltips with more details." The narrow, named one: "this setting CurseForge install links / Let CurseForge.com's Install buttons open here - On / also that setting is worded weirdly." A four-lens audit with adversarial confirmation produced the full row-by-row spec - `SETTINGS-SPEC.md`, shipped in this same folder alongside this file - which is the source of truth for exact tooltip copy, the tooltip component's markup/CSS/JS, and the full record of every rejected alternative; 6.1/6.2 below are this file's own summary of the structure that document settled on. Three things change everywhere at once this round: (1) a brand-new tooltip component (6.3 below), used on nearly every row, where a control's effect, scope, or a hidden coupling with another control was not obvious from its label alone - it never duplicates a permanently-visible sentence (the auto-update toggle's two locked lines, the ad-filter rationale) and never removes visible copy that was already there; (2) the CurseForge install-links row (the one Eric named) drops its baked-in "- On/Off" suffix entirely, so the switch alone carries state like every other toggle on this screen, with a new conditional helper line and an explicit checkbox `aria-label` taking over the suffix's old job as the only accessible state text; (3) 9 separate bordered Advanced boxes consolidate into 5 groups (6 on a PTR/Beta machine) plus one unboxed About footer line, with zero capability removed - see `SETTINGS-SPEC.md` section 2's "Explicit accounting of the rest of the screen" for the full removed-vs-relocated ledger (the only text actually deleted, not just relocated, is the now-redundant "CurseForge install links" `<h3>` and the "About" `<h3>`/box). No `settings.json` key is renamed anywhere in this round - every label change below is copy-only. A related host-side fix ships the same round: `host/FurphyHost.cs`'s `MinimumSize` grows from a too-small 900x600 (a real, reproducible bug - dragging the native window down to it pushed every Settings toggle off the visible right edge with no scroll escape) to give real headroom over this file's own 1000px layout floor; see `SPEC.md`'s dated decision paragraph for the exact numbers and verification method.

### 6.1 Essentials

**Updates**
- "Include beta versions" - toggle, off by default (`releaseType` 1/2/3, checked when >= 2; unchanged mechanism). New tooltip: what a beta version is, plus that turning this off also turns off "Also include experimental versions" in Advanced.
- (Round 34, 2026-09-07: the "Update addons before WoW starts" toggle (`autoUpdateOnLaunch`) that used to sit here, with its two Round-17 locked helper lines, was removed entirely at Eric's request along with every launch-WoW feature - see CHANGELOG.md.)
- "Update addons in the background" (`backgroundUpdates`, unchanged mechanism) - toggle, off by default, still zero permanent explainer sentence. New tooltip covers the facts that used to live nowhere on-screen: it runs as a separate process that keeps going after Furphy's window closes. While on, "How often" (`backgroundIntervalMinutes`, select, unchanged options and default) appears beneath it with its own new tooltip explaining the check cadence.
- "Start with Windows" (`runAtStartup`, unchanged mechanism) - toggle, off by default. New tooltip states the one coupled case plainly: turning this on also turns on "Update addons in the background" above, since a startup entry that starts nothing running would have nothing to do.
- The muted status line stays exactly where Round 18 left it, below all three rows - a confirmed finding to move it under only the background-updates rows was checked and rejected this round, see `SETTINGS-SPEC.md` section 7. Its live text contract is unchanged except one wording fix: the "done_updated" branch now reads "Updated N addon(s) at HH:MM: names" for every N, not "Updated 1 at HH:MM: names" when N=1. This string is the same `computeCoreText()`/`ComputeCore()` contract shared with the tray tooltip, tray context-menu line, and balloon notification (SPEC.md section I) - the fix ships identically in `ui/app.js` and `host/FurphyHost.cs`, never in only one, or the four surfaces drift out of sync.

**Appearance**
- "Spacing" (renamed from "Density" this round; `density`, unchanged segmented control/options/default) - the control's own `aria-label` is renamed too, from "Table density" to "Spacing," since the control was always app-wide, not table-scoped. New tooltip: purely visual, doesn't change what anything does.
- "Theme" (`theme`, unchanged 16-swatch grid, unchanged default) - the grid itself still gets zero visible text; a proposed "does clicking a tile need a Save step" reassurance tooltip was checked and rejected this round (live testing already gives a stronger, instant signal - the whole app repaints on click). Only the "Theme" label itself gets a new tooltip, a one-line scope disclaimer: changes Furphy's own window only, no effect on WoW or in-game addons.

### 6.2 Advanced (single collapsed disclosure, closed by default; 5 groups this round, 6 when WoW versions shows, plus one unboxed footer line)

The `<summary>` itself gets a new tooltip previewing what is inside: "Less commonly needed settings, such as CurseForge install links, extra version options, game folders, ad filtering, and troubleshooting tools."

- **"CurseForge"** (renamed from "Browsing" this round; absorbs the former standalone "CurseForge install links" box - its own redundant `<h3>` is deleted, subsumed into this group's own heading). Three rows, in this order:
  - The install-links row (live OS protocol-handler state, read via `register-protocol.ps1`, not a `settings.json` field) - **the row Eric named as worded weirdly.** Label is now fixed across every state, "Open CurseForge install links in Furphy," with no more baked-in "- On/Off" suffix; the switch alone carries state, matching every other toggle on this screen. A conditional helper line, "Currently handled by another program on this PC," shows only when off and another program already owns the handler - no helper line in the other two states. The underlying checkbox gets its own explicit `aria-label` ("Open CurseForge install links in Furphy") so removing the text suffix doesn't remove the only accessible state indicator. New tooltip explains the CurseForge.com green Install button in plain terms and what turning this off means for the player; it never names the underlying protocol scheme.
  - "Filter ads and trackers in the CurseForge tab" (`adFilter`, unchanged, ON by default) - its locked helper sentence is tightened only to drop the circular "in Settings" phrase (the reader is already looking at this exact toggle); the row's own label gets no new tooltip since the visible sentence already covers it, but its plain-Edge-mode fallback line ("Available in the Furphy desktop window.") gets a new one: "There's no CurseForge tab here to filter - only the Furphy desktop window has one."
  - "Show only search results on CurseForge" (`cfFocus`, unchanged, ON by default) - still zero helper sentence, per this row's own locked rule. New tooltip covers the corrected claim: on an addon's own CurseForge page, only ads/upsells/unrelated extras are hidden (title, description and files stay) - not the older, factually wrong draft that claimed an addon's own page is "never trimmed."
- **"Also include experimental versions"** (renamed from "Also include alpha/experimental versions" this round, dropping the unexplained "alpha/" prefix; `releaseType`, shared with the Essentials "Include beta versions" toggle, unchanged position, still a separate ungrouped row from the CurseForge group above) - off by default. New tooltip states the coupling with corrected, non-backwards causality: turning this on also turns on "Include beta versions" above, since experimental is a further step past beta, not a separate, possibly-older option.
- **"Game folders"** (unchanged heading, unchanged multi-flavour behavior per section 2.5) - "World of Warcraft folder" row's button is renamed from "Open folder" to "Open," now matching the "AddOns folder" row's own button text; both rows get new tooltips that deliberately avoid promising specific Explorer/Notepad behavior, since a separately-flagged wiring bug (SPEC.md's dated decision paragraph) means these buttons may not yet open what their labels promise - the World of Warcraft folder button today actually opens the AddOns folder, and the AddOns folder button opens `addons.json` in Notepad. Fixing that wiring is its own, separate task, not part of this round. **Round 33 (2026-09-06): fixed.** Each button now opens the path shown beside it - "World of Warcraft folder" › "Open" opens that folder (new `'wowfolder'` `/api/open` target), "AddOns folder" › "Open" opens the AddOns folder in Explorer, and each multi-flavour row's "Open" opens *that* flavour's AddOns folder (the flavour was being sent in the POST body, which the server never reads - it goes in `?flavour=` now). Labels and tooltips unchanged.
- **"Show test realms (PTR/Beta)"** (unchanged label including its parenthetical - spec-locked, do not drop the parenthetical; unchanged PTR/XPTR/Beta-machine-only gating, off by default) - gets a new tooltip this round describing what toggling this specific Furphy setting does (adds the test realm as another tracked WoW version), not what PTR/Beta are in general - everyone who ever sees this row already has that client installed, so the real gap was the Furphy-specific effect, not the jargon.
- **"Folders Furphy doesn't manage yet"** (unchanged heading, sentence, and Scan/Take-over/Delete behavior) - the group heading and the Scan button each get a new tooltip; per-result "Take over" tooltips are corrected to say plainly that the addon is re-downloaded and its folder overwritten from the matched source (CurseForge or Wago) - an earlier draft claiming "it doesn't touch the files themselves" was false and is not shipped.
- **"Backup & troubleshooting"** (new, Round 32 - merges the former "Save / load your addon list," "Troubleshooting," and "Diagnostics" boxes into one Advanced group with two thin border-top dividers, the same divider style already used between rows elsewhere on this screen):
  - Save/load (unchanged sentence and button text: "Save your addon list to a file, or load one you saved before." / "Save addon list" / "Load addon list") gets ONE heading-level tooltip covering why you'd do this (reinstalling Windows, a new PC, or just a backup) plus what's included (pinned version, ignored-updates choice, release channel) and the "not the addon files themselves" clarification - deliberately no separate per-button tooltips, to avoid three tooltip icons stacked over a two-button row.
  - "Open logs folder" (unchanged) gets a new tooltip that includes "and backups," since the folder holds both. "Force reinstall all" (unchanged label and confirm dialog) gets a new tooltip stating the missing "when" (corrupted or hand-deleted files) without repeating the confirm dialog's own "what" sentence. **Round 33 (2026-09-06):** one more plain button beside "Open logs folder", with its own tooltip: **"Open addon list file"** (the active flavour's raw `addons.json`, in Notepad) - the capability the Game folders "AddOns folder" › "Open" button had been mis-wired to, demoted here rather than dropped (§1.3).
  - "Diagnostics" demotes from its own `<h3>`/bordered box to a plain row-label - same 13px treatment as every toggle name on this screen, no box, no heading weight - but the word itself stays on screen as the anchor a support conversation refers to. Its two near-duplicate intro sentences collapse to one ("Quick check that your files and CurseForge connection are working."); the itemized detail that used to live in the removed second sentence moves onto the Run button's own new tooltip. Each result row (AddOns folder, CurseForge, Disk space) and the Copy report button gets its own new tooltip; the live pass/fail phrases themselves are unchanged and never get a static tooltip, since a static string could drift out of sync with a live result.
  - **"Uninstall Furphy Addon Manager"** (new, Round 33 - a new final cluster after Diagnostics, its own thin border-top divider, still inside this group's box): a danger button, same visual weight as "Force reinstall all" above, opening the existing `Components.Confirm` modal verbatim (the same one "Force reinstall all addons?" already uses - no new modal plumbing). New tooltip: "Removes Furphy's program files from this PC. Your addons and your saved addon list are kept - reinstalling picks up right where you left off." Confirm dialog title "Uninstall Furphy Addon Manager?", message "This removes Furphy's program files, its Start with Windows setting, and the CurseForge install-link handler. Your addons stay installed in WoW. Your addon list is kept at `<appDest>` so reinstalling brings it back.", confirm button labeled "Uninstall." On confirm: `POST /api/uninstall`; a 409/busy response renders the existing toast/error pattern with "Furphy is updating an addon right now. Try again in a minute."; success renders a plain final state, "Furphy is uninstalling itself and will close shortly." - no redirect, since the window receives its own close request moments later as part of the same mechanism. Deliberately bottom-of-group placement: the single most destructive control on the whole screen sits in the least accidentally-clickable spot. See `DISTRIBUTION-SPEC.md` sections 2.2/3.2/3.4/5 for the full end-to-end mechanism (tray menu, Windows Settings > Apps, and this row all converge on the same design) and `SPEC.md`'s Round 33 section for the day-to-day summary.
- **About footer** (demoted this round from its own bordered `<h3>` box to a plain unboxed line directly below the Advanced disclosure - three items separated by " . ", each its own span so a tooltip can still attach per item): "Version" keeps no tooltip (already the clearest row in About, a proposed tooltip there was rejected as filler). "WoW client build ..." is renamed from "Client build" (adds "WoW" so it can't be misread as Furphy's own build) and gets a new tooltip disambiguating it from Furphy's own Version, shown just above. "Running for ..." is renamed from "Server uptime" (drops backend-server jargon that raises an unnecessary "what server?" question in a desktop app) and gets a new tooltip stating the corrected fact that Furphy's background helper survives window close and keeps running across app opens, ending only after sitting idle for a while or on a PC restart - not "it restarts each time you open Furphy," which an earlier draft got backwards. `ui/app.js`'s Diagnostics panel gets its own `plainDiagRow` label updated from "Server uptime" to "Running for" so both panels describe the same fact with the same words.

What is NOT touched this round: no `settings.json` key is renamed (every label rename above is copy-only, same DOM ids and internal variable names); nothing relocates outside Settings - a confirmed finding to move Scan (Folders Furphy doesn't manage yet) or Save/Load to the My Addons screen was checked and rejected, per Eric's own "unified settings ... all in one" standing brief; My Addons' status pills get no new tooltips - a proposal to reuse this round's tooltip mechanism there was rejected as the wrong call site, and it would have resurrected the Compat hover tooltip this file's own acceptance checklist (section 11) requires stay permanently deleted, not just hidden. A stale planned-but-never-built row from Round 19's original draft of this section, "Launch product code override," is dropped from this rewrite: it traces to no `settings.json` key, no server route, and no DOM anywhere in `ui/`, so it never actually shipped - nothing is being removed here, only a documentation error corrected.

### 6.3 Tooltip component + wording rules (new, Round 32, 2026-09-06)

No tooltip mechanism existed anywhere in Settings before this round (confirmed live: zero `title` attributes, zero `.tooltip`/`.hint`/`.help` CSS, only bare native `title=""` on a handful of unrelated icon buttons like Back/Forward/Close - those are left exactly as they are, not converted). One new component, `Components.Tooltip`, backs every tooltip in 6.1/6.2 above, plus two tooltips outside Settings that ship the same round: the "Get new addons" pane's own outside-the-native-host fallback line, and Settings' own ad-filter fallback line - both get the same "no CurseForge tab here" style message, for consistency between the two analogous not-available-outside-the-native-host cases.

**Markup:** a small, focusable info-icon button (`.info-tip`, reusing the existing `#icon-info` sprite symbol already rendered once in the first-run welcome dialog) sits right after the label text it belongs to - a row label, a group heading, or the Advanced `<summary>` itself. Never a bare `title=` attribute on a label for a new tooltip - it has no visual affordance (nothing tells a mouse user hovering does anything) and a plain non-focusable `<div>` is unreachable by keyboard.

**Behavior:** exactly one tooltip bubble node exists at a time (constant id `app-tooltip`), created on open and removed on close, portalled to `document.body` with `position:fixed`, modeled on `Components.Dropdown`'s own portalled-menu lifecycle. It opens after a ~400ms hover/focus delay (cancelled if the pointer leaves first, so incidental mouse travel across a row doesn't flash tooltips constantly), closes immediately on mouseleave/blur, toggles open/closed on click/tap (reusing the existing document-level click-outside-closes pattern), and closes on Escape without moving focus - wired as the FIRST, highest-priority branch of the existing global Escape dispatcher, ahead of Dropdown/Lightbox/Dialog/Drawer, since a tooltip can render on top of any of them. Opening a new tooltip closes any other one already open. Placement reuses `Components.Dropdown`'s own `reposition()`/clamp/flip algorithm verbatim (8px viewport margin, opens below the trigger by default with a 6px gap, flips above when there isn't room, re-runs on scroll/resize). `Tooltip.open()`/`close()` call `OverlayTracker.open()`/`close()` exactly like `Components.Dropdown` already does, since a WebView2 child window (the embedded CurseForge pane) always paints above ordinary HTML regardless of z-index - this matters because this same component is reused on "Get new addons," where that pane is visible. ARIA: the trigger carries `aria-describedby="app-tooltip"` plus its own `aria-label="More about {row label}"`; the bubble itself carries `role="tooltip"`. Reduced motion collapses the default 120ms opacity/slide-in to an instant show under `prefers-reduced-motion: reduce`.

**Wording rules** (every new tooltip in this round follows this fixed shape, no exceptions):
1. What it does - one plain clause, no jargon.
2. When/why it matters, or a coupling with another control - only if not already obvious from (1).
3. For a toggle only, its default, always the last clause, always literally "On by default." or "Off by default." A select, path row, Spacing/Theme picker, or action button ends after clause (2) instead - never force a boolean-default sentence onto a control that has none.
Target length ~30 words; a genuinely coupled control (Beta/Experimental, Start with Windows/Background updates) may run to ~40-45 words rather than compress the coupling fact into incomprehensibility. No bullet lists, no bold text, no "Note:"/"Warning:" prefixes, never a wall of text.

**Voice and capitalization** (same house style as the rest of this app, restated here since it now governs tooltip copy too): plain, direct, second person where natural ("you"/"your"); Furphy refers to itself in first person by name ("Furphy checks...", "Furphy reads and writes..."), matching existing copy like "Folders Furphy doesn't manage yet." Sentence case everywhere - only proper nouns are capitalized (CurseForge, WoW, Furphy, Windows, Battle.net, World of Warcraft, Wago), never a common noun capitalized mid-sentence for emphasis. Punctuation: an em dash connects a two-clause sentence, matching this screen's own established house style (the ad-filter row's own locked sentence, the background-updates status line).

**Banned terms:** the unchanged section 11 list, plus one addition specific to this round - never write the literal string "curseforge://" or any other raw protocol/scheme identifier in any tooltip or helper line; this was a real leak caught and reverted once already on the install-links row.

**Full component CSS/JS and every exact tooltip string ship in `SETTINGS-SPEC.md` section 3 (component spec) and section 2 (per-row copy) - this subsection is the summary contract, that document is the copy source of truth.**

~~**CurseForge key (optional)**~~ - REMOVED 2026-09-04 (Expansion E23, Eric's explicit request: "I want the curse api key cleared, I want that removed as a feature"). Everything below is historical record of what USED to be here, kept only so a future pass doesn't reinvent it by accident:
- ~~One line: "Not required - everything works without it. A free key adds CurseForge's own search and addon descriptions."~~
- ~~Collapsed by default to a single row "Add a CurseForge key" that expands the field + Show/Hide + Test + Save + Clear in place when clicked.~~
- ~~Status line ("Key configured (...edf0)" / "No key configured") stays visible even collapsed, as the row's own subtitle.~~

~~**WoW's out-of-date warning**~~ - **REMOVED Round 17** (2026-09-04, Eric: "WoW's out-of-date warning ... get rid of this it doesn't do anything"). Not demoted further, deleted outright - the section, its read-only row, and the server-side `checkAddonVersion` field behind it are all gone. Kept here only as a historical record of what used to occupy this spot, same convention as the struck-through CurseForge key group above.

~~"Refresh the addon list from CurseForge"~~ - **REMOVED Round 17** (2026-09-04); the catalogue it manually refreshed still refreshes itself automatically at most once/24h, and its age is still reported by the diagnostics "CurseForge catalogue cache" row - only the manual on-demand button was ever gone, not the auto-refresh behind it.

---

## 7. Copy table (old → new / DELETE)

| Area | Old | New |
|---|---|---|
| Sidebar status | "Server OK — checked 5 min ago" | DELETE — replaced by the Freshness Headline (§2.1); connectivity dot carries no text when healthy |
| My Addons status | "6 addons · 3 updates available · checked 5 min ago · Client 12.1.0.69587 · 1 addon needs attention" | DELETE — replaced by the one headline; client build moves to Settings > About only |
| Last-run line | "Last run: 1 updated, 3 up to date, 1 ignored · 5 min ago" + Details | DELETE as a permanent line — folds into the headline's transient "Updated N · checked just now" for ~4s |
| Toolbar button | "Check for updates" | "Check now" |
| Toolbar button | "Update all (3)" | Kept, outline/secondary style, hidden entirely when nothing needs updating |
| Filter chip | "Missing deps N" | "Needs another addon (N)" — only shown when N > 0, inside "⋯ More" |
| Filter chip | "Stale N" | DELETE as a separate chip — folded into the Status pill vocabulary ("Old patch") |
| Table header | "Installed" + "Latest" | Merge into one "Version" header |
| Table header | "Compat" | DELETE — merged into "Status" |
| Status pill | "Missing: 1" (+ hover "Missing dependencies: DetailsFramework") | "Needs: DetailsFramework" — visible, no hover |
| Compat pill | "Built for 12.1" / "Older patch (12.0.7)" / "Unknown" | Folded into Status: "Up to date" / "Old patch" / "Won't work this patch" |
| Hidden tooltip | "Toc Interface: 12.1.0 (120100) · Newest known file supports…" | DELETE entirely, no replacement |
| Empty state | "No addons tracked yet" / "Add your first addon by CurseForge Project ID or link." | "No addons yet" / "Add one by name, link, or ID." |
| Drawer header | "Project 68304 / by Sylvanaar / via catalogue" (placeholder leak) | Real tracked addon name, always — **bug fix**, not a copy change |
| Drawer badge | "via catalogue" | DELETE |
| Drawer Overview (keyless) | "⚠ Add a free CurseForge API key in Settings to see descriptions, changelogs and screenshots." | "Add a free API key in Settings to see descriptions, changelogs and screenshots." |
| Drawer Changelog (keyless) | "⚠ Changelogs for CurseForge addons need a free API key (or a matching Wago Addons listing, which this one doesn't have)." | "Add a free API key to see changelogs." |
| Browse hint | "Opens CurseForge in a side window; installs still happen here by Project ID for now." | "Opens CurseForge in a side window. To install, come back here and paste the link." |
| Browse | "Not registered"/"Registered" pill + "CurseForge.com's own Install buttons open its own picker instead of Furphy." | DELETE from Browse entirely — control lives only in Settings > Advanced |
| Browse keyless banner | "Showing a keyless index via community mirrors (instawow-data, addon-radar.com), not CurseForge's own search. Add a free API key in Settings for full official search, sorting and categories." | "Search results are limited without a CurseForge key." (shown only on thin/zero results) |
| Browse card badge | "Indexed" / "Live match" | DELETE |
| Browse install-by-id card | "Install by Project ID" / "Works without a key. Find the Project ID in the right-hand 'About Project' box on any CurseForge addon page." | Folded into the fallback line: "Or paste an addon's CurseForge page link/number" |
| Browse | Source tab switch (CurseForge / Wago Addons) | DELETE as a pre-search gate — one box, per-card source badges instead |
| Settings heading | "Optional: CurseForge API key (adds official CurseForge metadata)" | "CurseForge key (optional)" |
| Settings API key intro | "Installing, updating, pinning and rolling back addons already work fully without a key. Adding one unlocks CurseForge's own search/sort/categories, plus descriptions, changelogs and screenshots for CurseForge-sourced addons." | "Not required — everything works without it. A free key adds CurseForge's own search and addon descriptions." |
| Settings > Game | "Out-of-date addon loading (checkAddonVersion)" + 4-sentence paragraph | "Load out-of-date addons at character select" / "Off (they'll load anyway)" / "This is a WoW setting — change it in-game, not here." — **whole row removed Round 17**, see §6.2. |
| Settings > Game | "CurseForge install links (curseforge://)" + "Not registered" + explainer sentence | "Let CurseForge.com's Install buttons open here" — On/Off label only, no sentence |
| Settings > Updates | 3-way radio: Release only / Release + Beta / Everything (incl. Alpha) | "Include beta versions" toggle (Essentials) + "Also include alpha/experimental versions" toggle (Advanced) |
| Settings > Untracked | "Folders in AddOns that aren't tracked by the manager." | "Folders in your AddOns folder that Furphy doesn't manage yet." |
| Settings > Backup | "Export your addon list (pins, ignored updates, release channel) to a file, or restore one you exported earlier." | "Save your addon list to a file, or load one you saved before." |
| Settings > Backup buttons | "Export addon list" / "Import addon list" | "Save addon list" / "Load addon list" |
| Settings > Maintenance | "Open sync log" / "Open last run report" / "Open server log" / "Open backups folder" (4 buttons) | "Open logs folder" (1 button) |
| Settings > Maintenance | "Refresh CurseForge catalogue now" | "Refresh the addon list from CurseForge" — **removed Round 17**, see §6.2 (catalogue still refreshes itself automatically). |
| Settings > Maintenance heading | "Maintenance" | "Troubleshooting" |
| Diagnostics result | `settings.json: valid` | "Your addon settings look fine" |
| Diagnostics result | `addons.json: 6 records` | "6 addons tracked" |
| Diagnostics result | `Reachable (HTTP 200)` | "Reached CurseForge OK" |
| Diagnostics result | `PowerShell version: 5.1.19041.4291` | DELETE from visible list — kept in Copy report |
| Diagnostics result | raw ISO timestamp `2026-09-04T05:19:41.479Z` | DELETE from visible list — kept in Copy report |
| Diagnostics result | `2 entries, 0.1h old (instawow-data+strongbox)` | DELETE from visible list — kept in Copy report |
| Settings > About | "Port" row | DELETE from visible About — kept in Copy report only |
| First-run dialog title | "Found addons in your AddOns folder" | "Found N addons in your AddOns folder" |
| First-run dialog body | "Furphy found {n} addon(s) it can manage. Adopting reinstalls each one from its source (CurseForge or Wago) so Furphy can keep it updated from here on." | "Furphy can start managing these — it re-downloads each one so it can keep them updated from now on." |
| First-run dialog button | "Adopt all (n)" | "Take over all (n)" |
| Job panel title | "Working…" | "Updating N of M addons…" / "Checking…" (kind-specific, plain) |
| Job panel body (default) | raw `sync.log` tail dump | DELETE from default view → behind closed "Details ▾" disclosure |
| Job result row (failure) | raw exception message | Plain phase-mapped sentence + inline Retry (§4.3) |
| Job toast (failure) | "Failed: " + job.error | Same plain-language sentence, shown in the panel (persists), not just a transient toast |
| Add addon dialog | "Enter a numeric CurseForge Project ID, a CurseForge addon URL (needs an API key), or a Wago addon URL / wago:<slug> (no key needed)." | "Paste an addon link (CurseForge or Wago), or type its ID number." |
| Switcher pill — Round 19, new, multi-flavour only | — | "Retail" / "Classic" / "Classic Era" / "PTR" |
| Switcher tooltip — Round 19, new | — | Classic Era pill only: "Includes Hardcore & Anniversary realms" |
| Bulk sync button — Round 19, new, multi-flavour only | — | "Update All" |
| Settings > Advanced toggle — Round 19, new, multi-flavour only | — | "Show test realms (PTR/Beta)" |
| Settings > Advanced > Game folders row — Round 19, multi-flavour only | "WoW folder" / "AddOns folder" (single row) | "Retail: `<path>` [ Open ]" (one row per installed flavour) |
| About, per-flavour build row — Round 19, multi-flavour only | one `<dd>` (single build number) | "Retail — 12.1.0.69587" (one row per installed flavour) |
| About, missing build info — Round 19, new | — | "— version unknown (launch this client once)" |
| Install-flavour picker title — Round 19, new | — | "Which version of WoW?" |
| Install-flavour picker, no match — Round 19, new | — | "This addon doesn't support your installed WoW versions." |
| First-run take-over dialog, per flavour — Round 19, multi-flavour only | "Found 6 addons in your AddOns folder" | "Found 4 addons in your Classic Era AddOns folder" (flavour name inserted only when more than one flavour's dialog shows in sequence) |
| Wago drawer table header — Round 19, renamed regardless of flavour count (data source touched anyway) | "Retail Patches" | "Patches" |
| Job panel flavour badge — Round 19, multi-flavour only | — | flavour label only, reuses the switcher pill style (§4.3) |
| WebView2 Runtime missing dialog - Round 38, new (host only, native `MessageBox`, not in the SPA) | (none - silent, the app just never opened) | "Furphy Addon Manager needs the Microsoft Edge WebView2 Runtime, which is missing or broken on this PC. Install it and try again." with a link to the Microsoft installer page |
| Job row failure reason - Round 38, new (see section 4.3) | (shared the "No matching version found" text with a genuine incompatibility) | "Couldn't check for updates - CurseForge might be having trouble" (a CurseForge/Wago outage during the check itself, kept distinct from a real incompatibility) |
| My Addons corrupt-list notice - Round 38, new | (raw .NET parser exception text in the error box) | Addon list falls back to empty with a server log entry; no raw exception text reaches the client |
| Get new addons (Wago) unrecognized Classic client - Round 38, new, non-Retail only | (silently showed Retail's own listings with no indication anything was wrong) | "Furphy doesn't recognize this Classic version yet - update Furphy to browse new addons for it." |
| Installer console/wizard, older installer over a newer install - Round 38, new | (silently copied the older app over the newer one; no warning of any kind) | "This copy of Furphy Addon Manager is older than what's already installed - installing it would replace the newer app with an older one, and your addon list could look empty until you reinstall the newer version instead." |

---

## 8. Removal list — what disappears from the default view, and where the capability still lives

| Removed from default view | Still reachable at |
|---|---|
| Raw CLI/sync log during and after an update | "Details ▾" disclosure on the job panel; full file via Settings > Advanced > Troubleshooting > "Open logs folder" |
| Compat as its own table column | Merged into the Status pill; exact patch numbers in the drawer's Overview tab |
| Hidden Compat hover tooltip (raw Toc-Interface numbers) | Nowhere — deleted outright, judged to carry zero player value even as an Advanced item |
| "Client build number" on My Addons | Settings > About |
| Sidebar "Server OK" text | Folded into the Freshness Headline; connectivity dot stays, silent when healthy |
| "Last run" line | Folded into the Freshness Headline's transient post-update text |
| `curseforge://` toggle + explainer on Browse | Settings > Advanced > "CurseForge install links" (single home) |
| Keyless-mode banner (shown permanently) | Same message, shown only when a search is thin/empty |
| "Indexed"/"Live match" provenance badge | Nowhere — deleted, source badge already covers this |
| Source tabs (CurseForge/Wago) on Browse | Both search simultaneously; per-card source badge replaces the tab |
| Sort dropdown, category filter, pagination on Browse | Not present on the default merged search; full CurseForge search/sort/categories reachable via "Search CurseForge.com directly" |
| "Install by Project ID" permanent card | Demoted to a link inside the same fallback area as "Search CurseForge.com directly" |
| WoW/AddOns folder paths, ad filter, untracked folders, backup/restore, maintenance buttons, diagnostics, About | Settings > Advanced (collapsed by default, one click away) |
| Release channel 3-way radio | Two toggles: "Include beta" (Essentials) + "Include alpha" (Advanced) — same underlying setting |
| Filter chips beyond All/Updates when count is 0 | Auto-hidden; reappear the instant count > 0 |
| "Port" in About | Copy report only |

Nothing in this table loses capability — every row is a relocation or a merge, per the demote-don't-delete rule (§1.3). The two true deletions (Compat hover tooltip, provenance badge) were judged by every proposal and every judge to add zero value even as an Advanced item.

---

## 9. Do-not-change list

- **Vaporwave** default theme (Round 17, 2026-09-04, Eric: "make vaporwave the main theme again" — supersedes round 11's "Lofi Night is the default/first in the list" entry, which this line replaces rather than appends to; do not flag the flip itself as a defect). **Superseded - kept as history, do not delete:** Round 19 moved the default to Arcane Library, and Round 31 moved it again to Tokyo Rain (see the checklist item in section 11); do not flag Vaporwave no longer being default as a regression.
- **Lofi Night's own art/tokens** — its pixel-art cityscape, cats and full token set are untouched; it's simply no longer first/default.
- **Dark / Light / Lofi Night** — all stay fully selectable, unchanged.
- **Works fully without a CurseForge API key** — every flow in this spec (install, update, pin, rollback, search) assumes keyless is the default, fully functional path; the key only ever added richer metadata/search, never gated a capability. As of 2026-09-04 (Expansion E23) this is no longer "the default path" but the ONLY path — the key feature was removed entirely, so there is nothing left to fall back from.
- **Both sources** — CurseForge and Wago Addons stay fully supported.
- **Native WebView2 host window**, `curseforge://` link handling, and the ad filter (ON by default as of 2026-09-04, see §6.2) — all stay, only relocated/deduplicated per §5 and §6.
- **No shutdown beacon** — untouched, not part of this pass.
- **PowerShell 5.1 + vanilla JS** — no framework introduced; every change is a restructuring of existing `Components.*`/`Views.*` functions and `index.html` sections.
- **Existing job/API contracts** stay as-is except the additive fields named in §4: `job.progress` and `/api/state`'s `freshness`/`lastCheckFailed`/`lastCheckError`. The CLI's final `-Json` stdout contract is untouched.
- **Confirm-dialog wording** (uninstall single/bulk, delete-untracked-folder, import, force-reinstall) — already plain and consequence-first per every Map pass; left as-is. (The "clear-key" dialog listed here in earlier rounds no longer exists — its whole feature was removed 2026-09-04, Expansion E23.)
- **Kebab-menu contents and order**, the Versions tab, and the existing Install-button state machine (Install → Installing… → Installed) — already correct patterns, reused as-is, not rebuilt.
- **Multi-flavour switcher, badges, per-flavour Game-folders/About rows, and "Update All"** (Round 19, `FLAVORS-SPEC.md`) — all render **zero DOM**, not `display:none`, on any machine with exactly one installed flavour, this one included; do not flag their absence there as a defect, and do not add a hidden-but-present container "for consistency" — the acceptance bar is genuine DOM absence, verified by inspecting the tree directly.

---

## 10. Implementation plan — ordered change sets

Each change set is sized for one focused agent. Verify with the Browser pane against `?mock=1` (built-in mock API; add `&host=webview2` for native-host mode) during development, and against a real running server on port 47899 (or the project's configured test port) before considering a change set done. Never touch the live install under `C:\Program Files (x86)`.

### CS1 — Progress mechanism (CLI + server)
**Files:** `addon-sync.ps1`, `addon-server.ps1`.
- Add `Write-ProgressStep` helper + `-ProgressPath` param + the 5 call sites in the main sync loop (§4.1).
- Add `-ProgressPath` threading in `Build-CliArgs`/`Start-Job`, the best-effort read in `Update-JobStatus`, and the new `progress` field in `Get-JobStatusView` (§4.2).
- Add `$Script:LastCheckFailed`/`$Script:LastCheckError` persistence in `Apply-JobCompletionSideEffects`'s failure branch; add `freshness`/`lastCheckFailed`/`lastCheckError` to `Handle-State`'s response.
- **Verify:** run a real `sync` job against the test server (port 47899); tail `jobs/<id>.progress.json` while it runs and confirm `index`/`phase`/`addon` advance addon-by-addon; kill network mid-download and confirm `phase:"failed"` lands with the job; hit `/api/state` and confirm `freshness` flips to `check_failed` after a forced failure and back after a success. Confirm the final CLI stdout JSON (`-Json` contract) is byte-identical in shape to before the change (diff against a pre-change run).

### CS2 — Home / Freshness / Row / Progress UI
**Files:** `ui/app.js`, `ui/index.html`, `ui/style.css`.
- New `Components.Freshness` module rendering the 5-state headline (§2.1); mount it in the sidebar (replacing `App.renderStatusLine`, ~app.js 5093-5143) and at the top of My Addons (replacing the summary sentence, ~app.js 3856-3871, and the last-run line, index.html 261-264).
- Merge table columns: delete `Installed`/`Latest`/`Compat` `<th>`s, add one `Version` `<th>`; implement the single-priority Status pill function (§3.2) replacing the separate Status+Compat pill renderers and deleting the hover-tooltip title-attribute construction.
- Rework `Components.JobPanel.update`/`summarize` (~app.js 2840-2926): determinate bar + current-item line driven by `job.progress`; move `#job-log` behind a closed `<details>`; add the plain-language failure map + per-row Retry wired to the server's existing single-target sync/add/install params; drop `pollJob`'s interval to 500ms.
- Fix the detail-drawer header bug: source name/author from `Store.state.addons` at open time, never from the enrichment/catalogue placeholder.
- Filter chips: reduce `FILTER_DEFS` to All/Updates always-visible + a "⋯ More" popover for non-zero extras.
- Reuse existing per-theme CSS tokens (`--success`/`--warning`/`--danger`/`--accent`, `.chip-*` classes, `.status-dot[data-state]`) for every new color need — do not invent new palette entries, so all four themes (including Lofi Night) stay correct automatically.
- **Verify (Browser pane, `?mock=1`):** load My Addons and confirm exactly one freshness headline is visible (sidebar dot carries no duplicate text); trigger a mock update and confirm a determinate bar + current-item line renders, the raw log is collapsed by default, and the done panel shows one result list (not three); open a row before its metadata has loaded and confirm the drawer shows the real name immediately, never a "Project NNN" placeholder; switch to Dark/Light/Vaporwave/Lofi Night and confirm the new pills/bar render correctly in each; confirm `Update all` is hidden when mock state has zero updates and reappears when updates exist.

### CS3 — Search (Browse)
**Files:** `ui/app.js` (`Views.browse`, ~4030-4441), `ui/index.html` (~336-461).
- Remove the source-tab switch, sort/category selects, pagination controls, and the permanent keyless banner from the default render path.
- Make `search()` fire CF and Wago searches concurrently; merge results into one interleaved, source-badged grid (extend the existing Wago badge style to CF cards); delete the Indexed/Live-match pill.
- Add the thin-results-only keyless nudge line; demote "Install by Project ID" and "Search CurseForge.com directly" into one fallback area under the results grid.
- Remove the `curseforge://` protocol-control mount from Browse (keep the one instance in Settings).
- **Verify (`?mock=1`):** type a query and confirm cards from both sources appear in one grid, each with a visible source badge, with no tab to switch first; confirm a card with only `name`+`slug` (simulated Wago-shape) renders with no blank space where author/summary/downloads would go; confirm the fallback line appears at the bottom of results, not as a second top search box.

### CS4 — Settings
**Files:** `ui/app.js` (`Views.settings`, ~4444-4970), `ui/index.html` (~464-649).
- Restructure the 10 flat sections into `essentialsSections` (Updates, Appearance, CurseForge key) rendered always-expanded, and `advancedSections` (everything else, §6.2) rendered inside one collapsed `<details>`.
- Split the release-channel radio into two independent toggles bound to the same `releaseType` value.
- Collapse the 4 maintenance "Open X" buttons into one "Open logs folder" button.
- Rewrite diagnostics result-row templates to the plain pass/fail strings (§7); keep the existing "Copy report" raw-value serialization unchanged.
- Remove the "Port" row from visible About.
- **Verify (`?mock=1`):** load Settings and count visible running-prose words in the Essentials view (must be ≤ 60, per the word budget); confirm Advanced starts collapsed and expands on click; run Diagnostics and confirm on-screen rows contain no raw filenames, HTTP codes, PowerShell version strings, or ISO timestamps, while "Copy report" still contains all of it (copy to clipboard and inspect).

### CS5 — Copy sweep + CSS pruning + doc updates
**Files:** all remaining string literals in `ui/index.html`/`ui/app.js` not already touched by CS2-4 (first-run dialog, add-addon dialog, drawer keyless/changelog messages, Browse hint text); `ui/style.css` (remove now-dead rules for deleted elements: old Compat column, old provenance badge, old source-tab switch, old 4-button maintenance row); `SPEC.md`, `CHANGELOG.md`, `README.md` (add a round entry documenting this pass).
- Apply every remaining row of the copy table (§7) not already covered.
- Rename "Adopt"/"Adopting" to "Take over" in all display strings (first-run dialog, Settings > Untracked-folders row actions).
- **Verify:** grep the full `ui/` tree for the banned-term list in §11 and confirm zero matches in visible strings (title/aria-label/placeholder/innerHTML — not internal JS identifiers or code comments); load every view (`My Addons`, drawer, `Browse`, `Settings`, first-run dialog, job panel done/failed states) in the Browser pane at `?mock=1` and `?mock=1&host=webview2` and read the full text with `get_page_text` to catch any missed string.

---

## 11. Acceptance checklist

- [ ] Home screen shows exactly one freshness headline (sidebar shows a connectivity dot only, with text only in the Connecting/Not-reachable states).
- [ ] The old My Addons summary sentence, the old "Last run" line, and the old sidebar "Server OK" text no longer exist anywhere in `ui/index.html`/`ui/app.js`.
- [ ] "checked X ago" appears in at most one place on screen at any time.
- [ ] Every installed-addon row shows exactly one Status pill (no row ever shows two colored badges).
- [ ] The My Addons table has exactly 5 columns (checkbox, Addon, Version, Status, ⋮) — no "Compat" column, no separate "Installed"/"Latest" columns.
- [ ] The Compat hover tooltip and the Indexed/Live-match provenance badge do not exist anywhere in the codebase (not just hidden — removed).
- [ ] A running update shows a determinate progress bar (n of N) and a current-item phase line by default; the raw log is present only inside a closed-by-default "Details" disclosure.
- [ ] A completed update with a failure shows exactly one results list with a plain-language reason and an inline Retry per failed row — no raw exception text visible without expanding Details.
- [ ] Opening any addon's detail drawer before its metadata has loaded shows the addon's real name immediately — the string "Project " followed by a number never appears as a drawer title.
- [ ] Browse shows one search box with no source-tab switch; results from CurseForge and Wago appear in one grid, each card carrying a visible source badge.
- [ ] The CurseForge segment of Browse has no visible sort dropdown, category filter, or pagination control (unchanged reasoning: it's the real site with its own full search/sort/categories). The Wago segment DELIBERATELY has all three as of Round 35 (Expansion E29, `WAGO-BROWSE-SPEC.md`) - this is not a regression, see section 5.1's superseded note.
- [ ] Settings Essentials (Updates, Appearance, CurseForge key) contains ≤ 60 words of running prose total, verified by copy-pasting the visible section text and counting.
- [ ] Settings Advanced is collapsed by default on page load and contains every item from §6.2.
- [ ] The `curseforge://` protocol toggle appears in exactly one place in the entire app (Settings > Advanced) — not in Browse.
- [ ] Diagnostics on-screen results contain no filenames (`settings.json`, `addons.json`), no HTTP status codes, no PowerShell version string, and no raw ISO-8601 timestamp; "Copy report" still contains all of them verbatim.
- [ ] No visible UI text (labels, buttons, chips, toasts, dialog copy, empty states, tooltips) contains any of: "project id", "file id", "release type", "toc", "interface version", "compat" (as a header/label — the word "compatible"/"compatibility" in plain sentences is fine), "digest", "stale", "stale-minor", "adopt"/"adopting" (renamed to "take over"), "untracked" (renamed to "doesn't manage yet"), "keyless", "indexed" (search badge), "instawow-data", "addon-radar.com", "HTTP 200" or any other raw status code, "Port" (in visible About). (`checkAddonVersion` dropped from this list Round 17 — the field/section it named no longer exists anywhere in the app, so there's nothing left for the term to leak from.)
- [ ] Tokyo Rain is the default theme (Round 31, superseding Round 19's Arcane Library-default, which itself superseded Round 17's Vaporwave-default); Arcane Library's, Vaporwave's and Lofi Night's own art/tokens are unchanged, just no longer default; all 16 themes remain individually selectable; every pill/bar/badge renders correctly (readable contrast, correct color) in every theme.
- [ ] Every capability listed in §8's "still reachable at" column is actually reachable by following that path in a live `?mock=1` session (manually click through each one).
- [ ] The app works end-to-end (install, update, pin, rollback, search, install-by-link) with no CurseForge API key configured.
- [ ] (Round 19) On a mocked single-flavour `/api/state`, the flavour switcher's DOM node does not exist anywhere in the page (inspect the tree directly, not just visual hiding) — every pixel and API shape stays byte-identical to today's Retail-only app.
- [ ] (Round 19) On a mocked multi-flavour `/api/state`, the switcher shows exactly the mocked flavours in `FLAVORS-SPEC.md` section 2.1's fixed order; clicking a pill swaps My Addons' list/freshness without a full reload, and the active pill's highlight matches the flavour actually shown.
- [ ] (Round 19) An ambiguous CurseForge install (mocked to match more than one installed flavour) shows the "Which version of WoW?" picker, never a silent install to the wrong flavour; a file matching zero installed flavours fails with the plain no-support message; a file matching exactly one installs silently, no prompt.
- [ ] The final CLI `-Json` stdout contract is unchanged in shape (diff a pre-change and post-change run's JSON output for the same fixture).
- [ ] (Round 35) No visible string in the Wago segment of Browse contains "new," "rising," "trending," or "this season" as a label, a tab name, or a tooltip - "Gaining this week" is the only new-data-adjacent string anywhere in the design, and every one of its surfaces (tab tooltip, not-ready copy, ready copy, per-row delta) says outright that it is a Furphy measurement, not a Wago one.
- [ ] (Round 35, inverted 2026-09-08) A user who opens Get New Addons > Wago while a WoW client is running sees real, live Wago results, never a blocked-state message; Gaining this week is unaffected either way, since it never makes a live request.
