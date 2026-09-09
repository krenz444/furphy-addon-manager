# APP-UPDATE-SPEC.md - Furphy Addon Manager self-update

Synthesized design for "the app itself can update" (Eric, 2026-09-08).
ASCII only. Every file:line citation below was re-verified against the
build root at the time of writing; where a candidate design's citation
drifted, the correction is called out explicitly so implementers do not
have to re-derive it.

NOTE ON DASHES: this document follows SETTINGS-SPEC.md's own convention.
Every " - " inside quoted UI copy should ship as a real em dash character.
Do not read the ASCII hyphens in this file as an instruction to use
hyphens in the shipped UI.

===============================================================================
1. GOALS / NON-GOALS
===============================================================================

GOALS
- Furphy checks GitHub Releases (github.com/krenz444/furphy-addon-manager)
  for a newer version and, by default, installs it automatically the next
  time doing so is safe.
- "Safe" means: never while an addon job is
  running, and (for the automatic/silent path only) never while any Furphy
  window is open.
- A user who wants to see what's happening can: see status and a
  "What's new" link in Settings, click "Check now", click "Install now"
  from a Settings row or an in-window banner, and turn automatic install
  off entirely (checking still happens; only auto-install stops).
- Integrity is enforced end to end: HTTPS, TLS 1.2, a sha256 sidecar, a
  VERSION-vs-tag check, and a downgrade refusal - all before any file
  touches disk under the live install.
- A failed install rolls back to the previously-working version and says
  so plainly, in the below-average-tech-savvy player's own words.

NON-GOALS (explicitly out of scope for this feature)
- No code signing (already decided, DISTRIBUTION-SPEC.md section 6.7 -
  "no code signing" - do not revisit).
- No new tray context-menu entry (decided in section 3 below).
- No update mechanism for pre-1.22.0 installs beyond "install 1.22.0 by
  hand once" (section 14).
- No change to the addon-update pipeline (CurseForge/Wago catalogue
  refresh, the existing "Update addons in the background" tray cycle) -
  this feature updates the APP, not addons, and must not be confused with
  either in code or in copy.
- No elevation/UAC, no per-machine install, no service - this ships and
  updates exactly the way Furphy already installs today: per-user, into
  <WoW folder>\<home flavour>\AddonSync, no admin rights required.

===============================================================================
2. FIXED DECISIONS (verbatim from Eric's brief - do not re-open)
===============================================================================

- Update source: GitHub Releases of krenz444/furphy-addon-manager.
- Automatic installation is ON by default, with a Settings toggle to turn
  it off, plus "Check now" and "Install now" controls.
- Never interrupt a running addon job.
- A silent background install happens ONLY when no app window is open.
  When a window is open, the SPA shows an update banner with "Install
  now", which closes and relaunches the app.
- The background tray is relaunched after an install if it was running,
  and no window is ever opened by the updater itself in that case.
- Integrity: HTTPS with TLS 1.2 forced in PowerShell 5.1; a new
  FurphyAddonManager-<ver>.zip.sha256 sidecar asset that package.ps1
  emits and the release step attaches; the zip's VERSION must equal the
  release tag; semantic-version compare; downgrade refusal.
- No code signing (already decided - do not revisit).
- The installer copy that performs the upgrade must run from OUTSIDE the
  app folder (staged extraction) and be detached from the server process
  it replaces.
- Rollback from install.ps1's own backup if the post-install health check
  (/api/ping version) fails.
- All tests use a FURPHY_TEST_GITHUB_BASEURL seam against a local stub
  (fixtures: a fake releases/latest JSON, a fake zip, its .sha256) and
  scratch destinations only - never real GitHub, never the live install.
- 1.22.0 is the first release carrying the updater; it can only update
  FROM 1.22.0 onward. 1.21.x users do one manual install.

===============================================================================
3. USER EXPERIENCE
===============================================================================

3.0 Naming and placement (closes an open question from the mechanics-first
    design)

The existing "Updates" settings-group (ui\index.html:1081, ends before
"Appearance" at ui\index.html:1133) already means ADDON updates - beta
channel, "Update addons in the background", "Start with Windows". The
tray's existing right-click item literally titled "Check for updates
now" (host\FurphyHost.cs:5347 wires the click, MenuCheckNow_Click is
defined at 5454) is also addon-scoped. Two "check for updates" concepts
in the same menu, or two "Updates" groups in Settings, is exactly the
kind of collision a below-average-tech-savvy player cannot parse.

DECISION (adopted from the Settings/banner design, closing the
mechanics-first design's open question rather than leaving it open):
- New, separate settings-group, id="settings-app-updates", titled
  "App updates" - placed directly after #settings-updates and before
  #settings-appearance (i.e. between ui\index.html:1132 and 1133).
- No new tray menu item, ever, in this release. App-self-update lives
  only in Settings plus the in-window banner, the tray balloon, and the
  first-run toast (all below). host\FurphyHost.cs's menu construction
  (~5333-5382) is not touched.
- No id/class prefix shared with #settings-updates / #updates-* / the
  addon-update strings ("Update addons...", "Check for updates now").

3.1 Settings > App updates - exact markup and copy

Follows the existing settings-row idiom byte-for-byte (see the "Update
addons in the background" row, ui\index.html:1101-1109, for the live
pattern this mirrors: settings-row > settings-row-text > label + a
button.info-tip with a data-tooltip attribute, aria-describedby="app-tooltip",
next to a label.switch toggle).

Row 1 (toggle):
```
<div class="settings-row" id="app-update-auto-row">
  <div class="settings-row-text">
    <div class="settings-row-label">Install app updates automatically<button type="button" class="info-tip" tabindex="0" aria-label="More about Install app updates automatically" aria-describedby="app-tooltip" data-tooltip="When a new version of Furphy is ready, it installs on its own the next time no Furphy window is open and no addon job is running. Turn this off to only be asked before installing. On by default."><svg class="icon"><use href="#icon-info"></use></svg></button></div>
  </div>
  <label class="switch">
    <input type="checkbox" id="toggle-app-update-auto">
    <span class="switch-track"><span class="switch-thumb"></span></span>
  </label>
</div>
```
- settings.json key: `appUpdateAutoInstall`, default `true` (section 6).
- Change handler mirrors setBackgroundUpdates (ui\app.js:5368-5382):
  `Utils.qs("#toggle-app-update-auto").addEventListener("change", function (ev) { Actions.saveSettings({ appUpdateAutoInstall: ev.target.checked }); });`
  reusing `saveSettings(patch, toastMessage)` (ui\app.js:5137), which
  already shows "Settings saved." via Components.Toast.show (ui\app.js:5145).

Row 2 (status line + buttons, always visible, mirrors
#updates-background-status, ui\index.html:1130):
```
<div class="settings-row settings-row-col" id="app-update-status-row">
  <p class="muted-text" id="app-update-status-text"></p>
  <div class="settings-row-actions">
    <button type="button" class="btn btn-outline" id="btn-app-update-check">Check now</button>
    <button type="button" class="btn" id="btn-app-update-install" hidden>Install now</button>
    <a href="#" class="link-btn" id="link-app-update-whatsnew" hidden>What's new</a>
  </div>
</div>
```

Status text (`#app-update-status-text`), one of exactly these seven,
selected from GET /api/app-update/status's `state`/`deferredReason`
(section 4/5) - written out in full so no more UX decisions are needed:
- state=idle, no update found: "Furphy is up to date (version 1.22.0)."
- state=checking: "Checking for updates..."
- state=available or ready: "Update ready: version 1.23.0."
- state=installing: "Installing update..." (see section 4's
  stuck-"installing" watchdog for why this state cannot simply be left
  out of this table - a below-average-tech-savvy player CAN see this
  text, briefly under the normal path and for longer if the install
  hangs before the watchdog times it out).
- state=error, lastError set: "Couldn't check for updates - try again later."
- deferredReason="job-running" (install was attempted but deferred):
  "Waiting for an addon job to finish before installing."
- state=error after a failed install/rollback: "Couldn't finish updating - kept your current version (1.22.0)."

Buttons:
- `#btn-app-update-check` ("Check now"): calls POST /api/app-update/check.
  Never disabled for game state - checking for an app update works the
  same whether WoW is running or not.
- `#btn-app-update-install` ("Install now"): hidden unless
  `state` is `ready`. Disabled with `title="An addon job is running"` when
  `deferredReason==="job-running"`. On click: calls POST /api/app-update/install
  `{relaunch:"window"}`, then immediately calls `App.enterUpdatingState()`
  (new, paralleling `enterUninstallingState`, ui\app.js:8235 - see 3.2).
- `#link-app-update-whatsnew` ("What's new"): shown once a `latestVersion`
  newer than `currentVersion` is known (found, or the one just installed).
  `href="#"`, click handler calls
  `Actions.openWhat("url", { url: releaseUrl })` - byte-for-byte the same
  shape as `Actions.openOnWago` (ui\app.js:5035:
  `function openOnWago(slug) { return openWhat("url", { url: "https://addons.wago.io/addons/" + encodeURIComponent(slug) }); }`).
  This POSTs /api/open with `what:"url"`; Handle-Open's existing allow-list
  (`$allowedOpenHosts`, addon-server.ps1:8510, currently
  `@('www.curseforge.com', 'addons.wago.io')`, with the matching error
  string at line 8521) gets one line added:
  `$allowedOpenHosts = @('www.curseforge.com', 'addons.wago.io', 'github.com')`.
  Two more spots in that SAME `'url'` case block go stale the moment a
  third host is added, and must change in the same edit: the 400 error
  string at line 8521
  (`'url must start with https://www.curseforge.com/ or https://addons.wago.io/'`)
  and the doc comment at line 8484 ("Restricted to the two addon
  marketplaces this app ever links to, so this endpoint can never be
  used to open an arbitrary URL...") - both hardcode "two"/the two
  marketplace URLs and would otherwise silently mislead the next reader
  (and mis-inform any caller reading the 400 body) once github.com is a
  valid third target.
  `releaseUrl` is the release's own `html_url` from the GitHub API
  response, persisted in app-update.json (section 4) - never hand-built.

3.2 In-window update banner

Mirrors `#banner-offline` exactly (sibling placement above `<main>`,
ui\index.html:783: `<div id="banner-offline" class="banner" hidden role="alert">`)
so it needs no per-view topbar work:
```
<div id="banner-app-update" class="banner" hidden role="alert">
  Furphy 1.23.0 is ready.
  <button type="button" class="link-btn" id="banner-app-update-install">Install now</button>
  <button type="button" class="link-btn" id="banner-app-update-whatsnew">What's new</button>
  <button type="button" class="link-btn" id="banner-app-update-dismiss">Not now</button>
</div>
```
Shown whenever `Store.state.appUpdate.state === "ready"` and the window
is open (which it definitionally is, since the SPA is the one reading
this from its own /api/state poll - `App.reloadState`, ui\app.js:8053).
- "Install now": same POST /api/app-update/install `{relaunch:"window"}`
  as the Settings button, then `App.enterUpdatingState()`.
- "What's new": same `Actions.openWhat("url", {url: releaseUrl})` as 3.1.
- "Not now": hides the banner for this browser session only (a JS
  in-memory flag, not settings.json) - does not touch
  `appUpdateAutoInstall` and does not delay the silent path if the window
  later closes.

`App.enterUpdatingState()` (new function, ui\app.js, placed next to
`enterUninstallingState` at line 8235): shows a full-window "Updating
Furphy..." overlay (one sentence, no progress bar - the whole cycle
normally takes a few seconds) and stops the idle poll, exactly like
`enterUninstallingState` already does for the analogous uninstall flow.
The window is expected to close (old server exits) and a NEW window
opens on its own (install.ps1 -Upgrade's relaunch, section 8) - there is
no "resume" path from this state; if the new window never appears within
~20s, fall back to the same offline messaging `#banner-offline` already
shows (ui\index.html:785, driven by `markOnline`, ui\app.js:8169), since
at that point this is indistinguishable from any other
can't-reach-the-server case. CORRECTION: an earlier draft quoted this
fallback as "Furthy Addon Manager isn't responding" - that string exists
nowhere in the code. The actual, verified copy is "Server not reachable
- restart from the desktop shortcut." (ui\index.html:785). Flagged for
Eric as open question 4 (section 16): telling the user to manually
"restart from the desktop shortcut" reads oddly right after an update
that was supposed to close and reopen the app by itself - decide whether
the generic message is acceptable here or this case needs its own copy.

3.3 Tray balloon (silent path only)

Reuses `ShowBalloonText` (host\FurphyHost.cs:6782) - the exact plumbing
already used for the "background updates turned off" balloon
(line 5527) and the cycle-complete balloon (`ShowBalloon`, line 6767).
Fired once, after a successful silent install+relaunch, from
`RunCycle` (host\FurphyHost.cs:5763) - see section 8 for exactly where:
`"Furphy updated itself to version 1.23.0."`, `ToolTipIcon.Info`.

No balloon for the in-window path (the banner already told the user) and
none for a deferred or failed silent attempt - failures surface only in
Settings' status line, matching "keep concepts minimal": a background
process popping an error balloon is exactly what alarms a novice.

Durable "fired once" marker (closes a gap the original wording glossed
over): `-Relaunch tray` starts `host\bin\FurphyHost.exe --tray` as a
BRAND NEW OS process (`Start-Process`, section 8.7), not a continuation
of whatever process was running before the upgrade - "fired once ... from
RunCycle" cannot mean "the same long-running process remembers it already
showed this," because after a silent update it is never the same
process. An in-memory flag in the new process would therefore either
never fire (nothing sets it) or, if implemented as a naive
`state=="installed"` check with no persisted marker, re-fire on every
cycle until `Invoke-AppUpdateMaintenance` happens to flip `state` back to
`"idle"` (up to an hour later, section 8.8) - including across an
unrelated reboot in that window. `tray-state.json`
(host\FurphyHost.cs:5196) is the one piece of tray state that DOES
survive a process restart (a file, re-read fresh at startup, never an
in-memory field) and is written atomically every cycle already
(`WriteStateFile`, host\FurphyHost.cs:6817) - add one more field to it,
e.g. `lastAppUpdateAnnouncedInstalledAt`. On every post-cycle
`GET /api/app-update/status` check (section 7/8.7), compare its
`installedAt` against this stored value: fire the balloon only when they
differ, then persist the new `installedAt` via the same `WriteStateFile`
write the cycle is already making - no new file, no new write path.
Comparing against `installedAt` (which only changes on the NEXT
successful install) rather than `state` (which can sit at `"installed"`
for up to an hour) means this neither re-fires every cycle nor re-fires
after an intervening plain reboot with no update involved.

3.4 First run after any update (manual or automatic) - one-time toast

Modeled on the existing `WELCOME_SKIPPED_KEY` localStorage precedent
(declared at ui\app.js:7802 as `const WELCOME_SKIPPED_KEY = "addonSync.welcomeSkipped.v1";`,
read/written at lines 8348 and 8415). New key:
`const APP_UPDATE_SEEN_KEY = "addonSync.appUpdateSeenVersion.v1";`.

On first render after `App.init()` resolves the server's version: if
`localStorage.getItem(APP_UPDATE_SEEN_KEY) !== currentVersion` AND a
value was already stored (never fire on a genuinely fresh browser
profile/first-ever install - only when the stored value differs from a
PRIOR real version), show:
```
Components.Toast.show("Updated to version 1.22.0.", "success", {
  actionLabel: "What's new",
  onAction: function () { Actions.openWhat("url", { url: releaseUrl }); }
});
```
This `opts.actionLabel`/`opts.onAction` shape is not speculative - it is
an existing, already-shipped feature of `Components.Toast.show`
(ui\app.js:2421-2450, the E19 comment: "an optional inline action ...
opt-in, every existing caller that passes no opts.actionLabel is
unaffected"). Then write
`localStorage.setItem(APP_UPDATE_SEEN_KEY, currentVersion)` unconditionally
(including on the very first run, so a fresh profile is seeded silently
without ever showing the toast).

3.5 Turning it off / forcing a check

- Off: the Settings toggle (`appUpdateAutoInstall=false`). Checking keeps
  running either way (it's free and safe); only automatic INSTALLING is
  gated by the toggle. The banner/"Install now" always remain available.
- Force a check: the "Check now" button (3.1). Same trained expectation
  as the addon-side "Check now", in a clearly different, clearly labeled
  section so the two are never confused.

===============================================================================
4. STATE MACHINE
===============================================================================

Persisted in a NEW file, `<Root>\app-update.json` (sibling of
settings.json/state.json - `$Script:SettingsPath` is
`Join-Path -Path $Script:Root -ChildPath 'settings.json'`, addon-server.ps1:8982;
app-update.json is operational state, not a user setting and not
FLAVORS-SPEC per-flavour job history, so it belongs at that same root
tier, its own file, never folded into either). Written atomically the
same way `Save-Settings` already does (`$tmpPath = "$path.tmp"`;
`[System.IO.File]::WriteAllText($tmpPath, ...)`; `Move-Item -Force`) -
Save-Settings itself is at addon-server.ps1:1390-1397, four lines
(1393-1396):
```
$json = ConvertTo-Json -InputObject $Settings -Depth 5
$tmpPath = "$Script:SettingsPath.tmp"
[System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmpPath -Destination $Script:SettingsPath -Force
```

States: `idle -> checking -> {idle | available} -> downloading -> {available(retry) | ready} -> installing -> {installed | error}`

Fields (all in app-update.json):
- `state` (string, one of the above)
- `currentVersion` (mirrors `$Script:Version`, addon-server.ps1:9063 -
  `$Script:Version = '1.21.1'` as of this writing (CORRECTION: an
  earlier draft cited '1.21.0' - the live VERSION file and the hardcoded
  fallback are both '1.21.1'; the value at ship time will be whatever
  1.22.0's own VERSION file says), overridden by the VERSION file's
  content at line 9068 if present)
- `latestVersion`, `releaseTag`, `releaseUrl` (the release's `html_url`),
  `assetUrl`, `shaAssetUrl`
- `checkedAt`, `downloadedAt`, `stagedPath`, `installAttemptedAt`,
  `installedAt` (ISO 8601 UTC strings, `$null` until set)
- `lastError`, `lastErrorAt`
- `windowOpenAt` (see section 7 - the recency marker used for the
  "is a window open" signal; kept in this file, not a bare in-memory
  script variable, so a value survives a maintenance-child's own process
  lifetime the same way every other cross-process signal in this file
  already has to)

No migration needed: a missing app-update.json is read as
`state:"idle", currentVersion:$Script:Version`, everything else `$null` -
the exact same "$null -ne $obj.x" tolerance every settings field already
gets (see section 6).

Stuck-"installing" watchdog: the spawned `install.ps1 -Upgrade` child
(section 5) can die before ever writing back to app-update.json - a
crash, a force-kill by AV, an unexpected early exit anywhere before the
try/catch section 8.6 adds, or install.ps1's own pre-existing top-level
guard (`if (-not $wowFound -and ($Uninstall -or $Console)) { ...; exit 2 }`,
install.ps1:624) firing silently under `-WindowStyle Hidden` if `-WowPath`
somehow fails to resolve even though the parent already resolved it once
(this route always passes `-Console`, per section 5's command line, so
that guard is live for it). With nothing watching for that, app-update.json
sits at `state="installing"` forever, and (per section 3.1's status-text
table) Settings would show "Installing update..." indefinitely with no
way out. Fix: `Invoke-AppUpdateMaintenance` (section 7) - which already
runs hourly and on every on-demand "Check now" - treats a
`state="installing"` whose `installAttemptedAt` is more than 5 minutes
old (a generous multiple of section 8.6's own 20s post-install
health-check timeout) as abandoned: writes `state="error"`,
`lastError="the last update attempt did not finish - try Check now
again."`, `lastErrorAt=now`. This is a read of app-update.json plus one
timestamp comparison - no new process-watching machinery.

===============================================================================
5. HTTP API
===============================================================================

Added to `$Script:Routes` (addon-server.ps1:8749-8800, exact array shape
to mirror - each entry is `@{ Method = '...'; Pattern = '^/api/...$'; Handler = '...' }`,
appended just before the closing `)` at line 8800, right after the
existing `/api/uninstall` entry at line 8799):
```
@{ Method = 'GET'; Pattern = '^/api/app-update/status$'; Handler = 'Handle-AppUpdateStatus' }
@{ Method = 'POST'; Pattern = '^/api/app-update/check$'; Handler = 'Handle-AppUpdateCheck' }
@{ Method = 'POST'; Pattern = '^/api/app-update/install$'; Handler = 'Handle-AppUpdateInstall' }
```
All three inherit CSRF for free: `Invoke-Route` (defined at
addon-server.ps1:8831) gates every non-GET/HEAD method on
`Test-SameOriginRequest` at line 8862 (`if ($method -ne 'GET' -and $method -ne 'HEAD' -and -not (Test-SameOriginRequest -Context $Context)) {`) -
no new CSRF code needed, identical to every existing POST route.

All three also pass through `Invoke-Route`'s `Resolve-RequestFlavour`
call (addon-server.ps1:8872) before dispatch, exactly like every other
route - that call is unconditional in `Invoke-Route`, not limited to
`$Script:FlavourScopedEndpoints` entries, so these three routes cannot
opt out of it. This is harmless here and deliberate: none of the three
new handlers ever reads `$Script:CurrentFlavourContext`
(`Set-CurrentFlavourContext -Flavor $flavourResult.Flavor`, line 8876,
only matters to the addon/build-info paths the new handlers never
touch), and since no caller of these routes ever sends `?flavour=`,
`Resolve-RequestFlavour` always falls through to its own
"omitted, not a flavour-scoped endpoint" branch (settings.json's
`activeFlavour`, or the default - never a 400) rather than the
"omitted, flavour-scoped, >1 installed" branch that DOES 400. Do not add
these three routes to `$Script:FlavourScopedEndpoints`.

GET /api/app-update/status
- No CSRF (GET). Reads app-update.json + `settings.appUpdateAutoInstall`.
- 200 body:
```json
{
  "state": "ready",
  "currentVersion": "1.22.0",
  "latestVersion": "1.23.0",
  "releaseTag": "v1.23.0",
  "releaseUrl": "https://github.com/krenz444/furphy-addon-manager/releases/tag/v1.23.0",
  "checkedAt": "2026-09-08T14:00:00Z",
  "downloadedAt": "2026-09-08T14:00:12Z",
  "installedAt": null,
  "lastError": null,
  "autoInstall": true,
  "deferredReason": null,
  "windowOpen": true
}
```
  `deferredReason` is `null | "job-running"` - set only
  as the immediate result of the last install ATTEMPT (section 4), not
  recomputed live on every status poll (recomputing live would require
  this GET to itself scan jobs on every 5s SPA
  poll, which is unnecessary work for a read that mostly just echoes
  disk state). `windowOpen` IS computed live on every call, from
  `(Get-Date) - (windowOpenAt from app-update.json)` (section 7) - this
  field is informational for the SPA/tray, not itself security-gating
  (POST /api/app-update/install re-checks job state itself,
  authoritatively, at call time - see below).
- Folded into `Handle-State`'s own response too (addon-server.ps1:6986,
  response body assembled through line ~7160 where `gameRunning` is set
  - `gameRunning = (Test-GameRunning)` - and `Send-Json` is called at
  line 7161): add `appUpdate = <same object as above>` next to
  `gameRunning`, so the SPA's existing 5s/idle poll (`App.reloadState`,
  ui\app.js:8053, cadence `POLL_ONLINE_MS = 5000` at ui\app.js:8200) picks
  up update state on the poll it already makes - no new poll loop.

POST /api/app-update/check ("Check now" and any future caller)
- CSRF required (POST, non-GET - inherited automatically, see above).
- If `state` is already `checking` or `downloading`: 200 with the current
  status object (idempotent - no double-spawn, mirroring
  `Test-MaintenanceChildRunning`'s own re-entrancy guard,
  addon-server.ps1:5515).
- Otherwise: writes `state="checking"` to app-update.json, then spawns a
  hidden, detached `-AppUpdateOnly` child of the SAME script (new switch,
  structural sibling of `-MaintenanceOnly` - see section 8's scheduling
  note on WHY this must be a child process, not an inline HTTP call on
  this thread) using the exact `ConvertTo-SafeProcessArg`-quoted
  `List[object]`+`Start-Process -WindowStyle Hidden` idiom
  `Invoke-MaintenanceTick` already uses at addon-server.ps1:5589-5622.
  Responds 202 `{ ok: true, state: "checking" }`.
- The SPA's "Check now" handler polls GET /api/app-update/status (same
  shape as the existing job-poll pattern) until `state` leaves
  `"checking"`.

POST /api/app-update/install ("Install now" and the tray's silent
trigger - both funnel through this ONE handler; the two callers differ
only in the `relaunch` value they pass)
- CSRF required.
- Request body: `{ "relaunch": "window" | "tray" }`.
- 400 `{ error: "nothing staged to install" }` if `state != "ready"`.
- 409 `{ error: "busy: a job is running" }` if any
  `$Script:CurrentJobByFlavour` entry is `running` - the EXACT same loop
  `Handle-Shutdown` already runs (addon-server.ps1:8731-8735:
  `foreach ($cj in @($Script:CurrentJobByFlavour.Values)) { if ($cj) { $refreshed = Update-JobStatus -Job $cj; if ($refreshed -and $refreshed.state -eq 'running') { $anyRunning = $true } } }`,
  followed by the 409 at line 8738) - satisfies "never interrupt a
  running addon job" with reused code, not new logic. Also writes
  `deferredReason="job-running"` to app-update.json before responding, so
  the next status poll's status line shows "Waiting for an addon job to
  finish before installing." without a second round trip.
- On success: resolve `$wowRootPath` via `Get-FlavourWowRootPath -Flavor 'retail'`
  (falling back to the no-arg overload) - the exact call
  `Handle-Uninstall` already makes at addon-server.ps1:8680-8681 (both
  `Get-FlavourWowRootPath` and `Get-WowRootPath` are defined at
  addon-server.ps1:1786 and :1759 respectively). Write
  `state="installing"`, `installAttemptedAt=<now>` to app-update.json
  BEFORE launching the installer (so a crash mid-launch is visible on the
  next poll instead of silently stuck at "ready"). Launch, detached and
  hidden, from the STAGED extraction (never the running install's own
  install.ps1):
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<stagedPath>\install.ps1" -WowPath "<wowRootPath>" -Upgrade -Relaunch <relaunch> -Console -Quiet
```
  built with the same `ConvertTo-SafeProcessArg`+`List[string]`+
  `Start-Process` pattern `Handle-Uninstall` already uses around
  addon-server.ps1:8700-8713. `stagedPath` is always a fresh `%TEMP%\...`
  folder created by the download step (section 8), never under
  `$appDest` - this is what satisfies "runs from OUTSIDE the app folder"
  and "detached from the server process it replaces" by construction.
- Responds 200 `{ ok: true }`, then sets `$Script:ShuttingDown = $true` -
  identical to `Handle-Uninstall`'s own final two steps
  (addon-server.ps1:8719-8720).

Error codes summary: 200 (ok), 202 (check accepted, running in
background), 400 (nothing to install), 409 (job running), 500
(unexpected - installer failed to spawn, disk error, etc, `{ error:
"<message>" }` matching every other handler's error shape in this file).

===============================================================================
6. SETTINGS KEYS AND MIGRATION
===============================================================================

One new settings.json key, mirroring `backgroundUpdates`'s exact
round-trip:
- `Get-DefaultSettings` (addon-server.ps1:1315): add
  `appUpdateAutoInstall = $true` next to `backgroundUpdates = $false`
  (that field is at line 1368 today) - default ON per the fixed decision
  (note: opposite polarity from backgroundUpdates' own OFF default -
  intentional, per Eric's brief).
- `Get-Settings` (addon-server.ps1:1400): add
  `if ($null -ne $obj.appUpdateAutoInstall) { $result.appUpdateAutoInstall = [bool]$obj.appUpdateAutoInstall }`
  next to the identical `backgroundUpdates` line at 1457.
- `Get-SettingsView` (addon-server.ps1:1536): add
  `appUpdateAutoInstall = $Settings.appUpdateAutoInstall` next to
  `backgroundUpdates` at line 1563.
- `Handle-SettingsPut` (addon-server.ps1:7632): add
  `if ($null -ne $body.appUpdateAutoInstall) { $settings.appUpdateAutoInstall = ConvertTo-SettingsBool $body.appUpdateAutoInstall }`
  next to the identical `backgroundUpdates` block (addon-server.ps1:7738:
  `$settings.backgroundUpdates = ConvertTo-SettingsBool $body.backgroundUpdates`),
  using the existing `ConvertTo-SettingsBool` (defined at line 7610).

No migration step: a pre-1.22.0 settings.json simply lacks the key and
every reader above falls through to the `Get-DefaultSettings` value
(`true`) via the same "$null -ne" tolerance every other boolean setting
in this file already uses - identical to how `backgroundUpdates` itself
needed no migration when it shipped.

===============================================================================
7. SCHEDULING AND GATING
===============================================================================

Server start: the very first `-MaintenanceOnly` tick after startup
"always qualifies" per `Invoke-MaintenanceTick`'s own doc comment
(addon-server.ps1:5556-5559: "$Script:LastMaintenanceAttemptAt is at
least that old ($null-initialized to [DateTime]::MinValue, so the very
first tick after startup always qualifies..."), so an app-update check
riding that same child gets a check "shortly after startup" for free -
no separate startup hook needed.

Hourly maintenance child: `Invoke-MaintenanceTick`
(addon-server.ps1:5546) already spawns a hidden, BelowNormal,
`-MaintenanceOnly` child of the same script at most once per
`$Script:MaintenanceIntervalMinutes` (60, set at line 9183), gated on
`Test-MaintenanceChildRunning` and the interval. Add ONE more call
inside the `-MaintenanceOnly` branch (`if ($MaintenanceOnly) {`,
addon-server.ps1:9228), inside the SAME try/finally that already wraps
`Initialize-CfCatalogueIndex`/`Initialize-WagoGrowthSnapshots`
(addon-server.ps1:9256-9265) - a third `try { Invoke-AppUpdateMaintenance } catch { Write-ServerLog "..." }`
block, same shape as the two it sits beside. `Invoke-AppUpdateMaintenance`
is itself self-gated on app-update.json's own `checkedAt` being >= 24h
old (or `state` already `available`/`downloading`/`ready` from an
incomplete prior run, in which case it resumes rather than re-checking) -
this gives "checks roughly daily" with zero new process-spawn machinery.

On-demand check: `POST /api/app-update/check` (section 5) bypasses the
24h gate and spawns a dedicated `-AppUpdateOnly` child immediately - this
is what makes "Check now" feel instant instead of waiting for the next
hourly tick, while reusing every line of `Invoke-AppUpdateMaintenance`
(the `-AppUpdateOnly` early-exit branch, added next to `-MaintenanceOnly`'s
own at line 9228, just calls the same function unconditionally then
exits).

Tray cycle: `RunCycle` (host\FurphyHost.cs:5763), right after its
existing per-cycle addon-sync work, adds ONE more step: `GET /api/app-update/status`;
if `state=="ready"` AND `windowOpen==false` AND `settings.appUpdateAutoInstall`:
`POST /api/app-update/install {relaunch:"tray"}`. This reuses the
existing `PingUrl()/JobsUrl()/JobUrl()` HTTP-helper idiom
(host\FurphyHost.cs:6511-6513, called from RunCycle at lines 5790/5840/5899) -
add one more small helper, `AppUpdateStatusUrl()`/`AppUpdateInstallUrl()`,
same shape.

Running job: enforced only server-side (there is no client button for
the silent path to disable) - `POST /api/app-update/install`'s 409
job-running check (section 5) is the sole gate; both the SPA-initiated
and tray-initiated callers hit the exact same route and therefore the
exact same check, so there is only one place this rule can ever drift.

Open window ("is a window open right now"): the fixed decision needs a
live fact nothing today reports (`MainForm_FormClosing`,
host\FurphyHost.cs:2721, only saves window bounds and stops local
timers - it never tells the server the window closed). Grafted from the
Settings/banner design's NARROWER, self-consistent version rather than
the mechanics-first design's original (which stamped a recency marker on
EVERY request via `Invoke-Route`, and was found to self-poison: the
tray's own routine `PingUrl`/`JobsUrl`/`JobUrl` traffic - and the very
`GET /api/app-update/status` poll used to READ the signal - would keep
re-stamping it, making `windowOpen` read true almost continuously and
suppress the tray-triggered silent path it exists to gate):
- Stamp `windowOpenAt` (app-update.json field, section 4) inside
  `Handle-State` specifically (addon-server.ps1:6986) - a route verified
  to be called only by the SPA's own poll (`App.reloadState`) and by
  `MainForm`'s protocol-link handler (host\FurphyHost.cs:3350, once per
  `curseforge://` navigation) - both cases require a window to be open.
  `TrayForm.RunCycle` is verified to call ONLY `PingUrl()`/`JobsUrl()`/
  `JobUrl()` (host\FurphyHost.cs:6511-6513) and never `/api/state`, so the
  tray's own background traffic cannot re-arm this signal - closing the
  exact self-poisoning gap the mechanics-first design's global
  `Invoke-Route` stamp had.
- `windowOpen` (exposed on GET /api/app-update/status, section 5) is
  `(Get-Date) - windowOpenAt < 15 seconds` - comfortably above the SPA's
  own 5s idle-poll interval (`POLL_ONLINE_MS = 5000`, ui\app.js:8200) so
  a genuinely open window is never misread as closed, and short enough
  that a closed window is noticed well within one maintenance-tick cycle.
  A minimized-but-not-closed window still counts as open under this
  definition (FormClosing has not fired, the SPA keeps polling) -
  deliberate: it is the simpler, already-correct reading of "no window
  is open," and needs no new C#.
- Caveat carried forward from both source designs, stated plainly for
  whoever implements this: this is an inference from existing traffic,
  not an explicit "window closed" event. If a future change adds another
  `/api/state` caller that is not a real user-facing window, re-verify
  this signal against the actual call sites before relying on it.

Idle: no separate idle gate - `windowOpen` already covers "the SPA has
stopped polling," which is the only idle signal this file has.

===============================================================================
8. UPDATE PIPELINE
===============================================================================

8.1 Release lookup

New script-level seam, declared the same way `$Script:WagoBaseUrl`/
`FURPHY_TEST_WAGO_BASEURL` already is (addon-server.ps1:105-107, with the
matching "TEST-ONLY: no real user run ever sets..." comment at line 104):
```
$Script:GitHubBaseUrl = 'https://api.github.com'
if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_GITHUB_BASEURL)) {
    $Script:GitHubBaseUrl = $env:FURPHY_TEST_GITHUB_BASEURL.TrimEnd('/')
}
```
`Invoke-AppUpdateMaintenance` calls
`GET $Script:GitHubBaseUrl + "/repos/krenz444/furphy-addon-manager/releases/latest"`
via `Invoke-RestMethod`, with an explicit `User-Agent` header (the GitHub
API rejects requests with none) - e.g. `-Headers @{ 'User-Agent' = 'FurphyAddonManager/' + $Script:Version }`.
TLS 1.2 needs no new code: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`
is already set process-wide at addon-server.ps1:91, before any handler
runs, so every `Invoke-RestMethod`/`WebClient` call in this file
(including this new one) already inherits it.

Rate-limit handling: unauthenticated GitHub API calls are capped at 60/hr
per source IP. This check runs at most once/hour via the maintenance
child (section 7), so normal usage never approaches that - but the
`-AppUpdateOnly` on-demand path (rate-limited only by "Check now" being a
manual click) should treat an HTTP 403/429 response the same as any
other transient check failure: `state` stays whatever it was (never
regress `ready`/`available` back to `idle` on a failed re-check),
`lastError = "GitHub rate limit reached - try again later."`,
`lastErrorAt = now`. Never retry in a tight loop; the next opportunity is
either the user's next manual click or the next hourly tick.

8.2 Asset selection

Parse `tag_name` (semantic-version compare against `$Script:Version`
using `[System.Version]` objects - the exact idiom already written for
install.ps1's downgrade guard, addon-server.ps1... no, install.ps1:1562:
`[System.Version]::TryParse($destVersionRaw, [ref]$destVersionParsed) -and [System.Version]::TryParse($srcVersionRaw, [ref]$srcVersionParsed)`,
with the guard's own comment on why - "1.9.0" must not sort ahead of
"1.10.0" - reused verbatim, never a string compare) and `assets[]` (find
entries named EXACTLY `FurphyAddonManager-<tag-without-v>.zip` and that
name + `.sha256` - never construct a download URL by hand; always use
each asset's own `browser_download_url`, the same way
`FURPHY_TEST_GITHUB_BASEURL` lets a stub substitute the whole base for
tests). If no newer tag, or no matching pair of assets: `state="idle"`
(or stays as-is on a transient failure - see 8.1), nothing downloaded.

8.3 Download and integrity

Download both assets to `$Script:CacheDir\app-update\` (i.e.
`<Root>\cache\app-update\`, following the existing `$Script:CacheDir`
convention at addon-server.ps1:9028 - this is just a data cache for the
DOWNLOAD, not the eventual extraction/install target, so it living
inside the running app's own tree is fine; see 8.4 for why the
EXTRACTION target must be different). Compute
`Get-FileHash -Algorithm SHA256 -LiteralPath <zip>` and compare its
lowercase hex `.Hash` against the sidecar's trimmed content:
- Mismatch: delete both downloaded files, `state="error"`,
  `lastError="integrity check failed"`, `lastErrorAt=now`. Never extract.
- Match: proceed to 8.4.

8.4 Staged extraction and VERSION check

Extract the verified zip into a NEW folder OUTSIDE `$appDest`:
`%TEMP%\FurphyUpdate-<tag>-<guid>\` (a fresh GUID per attempt, so a
leftover folder from an aborted prior attempt is never reused/collided
with). This is what makes "runs from OUTSIDE the app folder (staged
extraction)" true by construction - the eventual `install.ps1 -Upgrade`
invocation in section 5/8.6 runs FROM this folder, never from
`$appDest`'s own `install.ps1`.

Read the extracted `VERSION` file and require it to equal the release
tag (case-insensitive, leading "v" stripped) - refuse and error exactly
like the sha256 mismatch case otherwise (delete the staging folder,
`state="error"`, `lastError="downloaded package's VERSION did not match the release"`).
Then compare that VERSION against `$Script:Version` with the SAME
`[System.Version]` comparison as 8.2 - refuse (never install
automatically) if not strictly newer; this is redundant with the tag
compare in 8.2 by design (defense-in-depth against a mismatched
release), not dead code.

On success: `state="ready"`, `stagedPath=<the extraction root>`,
`downloadedAt=now`.

8.5 What install.ps1 needs added

New switch on the param block (install.ps1:46-80, alongside the existing
`-Uninstall`/`-Force`/`-Console`/`-Quiet`): `[switch]$Upgrade` and
`[string]$Relaunch` (`"window"` or `"tray"`, passed straight through from
section 5's command line).

REAL GAP FOUND BY READING THE CODE (this is the load-bearing fix the
whole feature depends on, not an optional nicety): `Close-InstallMainWindow`,
`Invoke-InstallServerShutdown`, `Wait-InstallHostAndWebView2Exit`, and
`Get-InstallLiveAppDestProcesses` (install.ps1:402-916) are called ONLY
from inside the `if ($Uninstall) { ... exit 0 }` block, which spans lines
1069-1518 exactly (verified: `exit 0` at line 1518, function closes at
1519). `Invoke-FurphyInstallSteps` (defined at line 1521, the shared
install/upgrade path called from the `-Console` flow at line 2155 and
from the wizard's success path at lines 2089/2176) never calls any of
them. Its Step 3b - the unguarded prebuilt-binary copy loop, confirmed at
lines 1667-1669:
```
Get-ChildItem -LiteralPath $binSrc -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path -Path $binDst -ChildPath $_.Name) -Force
}
```
- has no try/catch, and `$ErrorActionPreference = 'Stop'` is set at
install.ps1:82. Overwriting `host\bin\FurphyHost.exe` while the CURRENTLY
RUNNING copy of that exact exe (and its child `msedgewebview2.exe`
processes) still holds it open throws `ERROR_SHARING_VIOLATION` and
aborts the entire install mid-copy. (package.ps1's own comment at line
119 confirms the release zip ships this prebuilt exe alongside source -
"sources + SDK assemblies + the prebuilt exe" - so this file is
genuinely present in every real update, not a rare fallback case.) This
already silently breaks a manual "download the new zip, run install.ps1
again" upgrade today whenever a window or the tray is open; it is an
absolute blocker for an updater that upgrades while its OWN server is,
by definition, still running.

FIX: factor the existing Uninstall-only sequence into a new function
`Invoke-InstallStopRunningApp`, and call it UNCONDITIONALLY at the very
top of `Invoke-FurphyInstallSteps` (line 1521), immediately before the
downgrade guard (line 1538) or immediately after it - either ordering is
safe since the guard only reads/compares VERSION files and never touches
a live process; placing the stop BEFORE the guard is preferred so a
same-version "repair" install also benefits.

BE PRECISE ABOUT WHAT TO SKIP: the Uninstall-only block bundles three
sub-steps under one comment at install.ps1:1163-1204, and they are NOT
equally skippable for an upgrade:
(a) remove the HKCU "Start with Windows" Run value - SKIP this one under
    `-Upgrade`. The app is not going away; deregistering startup would
    silently break "Update addons in the background" at next logon.
(b) `Set()` the per-install-scoped TrayStop event, signalling any
    running tray to exit gracefully - KEEP this UNCONDITIONALLY under
    `-Upgrade`. This is the step that matters most for this whole
    feature: the silent/tray path (`-Relaunch tray`, no window ever
    open, section 8.7) is exactly the scenario where a tray IS running
    when the upgrade fires.
(c) wait up to 10s for `host\bin\FurphyHost.exe` (the tray's own
    process) to exit after that signal - KEEP this too, immediately
    after (b), for the same reason.
Then `Close-InstallMainWindow` -> `Invoke-InstallServerShutdown` ->
`Wait-InstallHostAndWebView2Exit` run as they do today (unchanged).
Skipping only (a) while keeping (b)/(c) matters concretely: without the
graceful TrayStop signal, a running tray is still eventually caught by
`Wait-InstallHostAndWebView2Exit`'s own generic
`Get-InstallLiveAppDestProcesses` scan (it matches ANY `FurphyHost.exe`
under `$appDest`, tray or window, install.ps1:700-751) - but only after
that function's full 20s poll times out and it then force-terminates the
tray via `Stop-Process`, exactly the slow, rough shutdown (b)/(c) exist
to avoid, landing on precisely the path this whole feature is built
around. An
earlier draft of this fix described (a)/(b)/(c) together as "the
Run-value-conditional stop-tray step" - do not read that as one skippable
unit: only (a) is Run-value work; (b)/(c) are gated on their own
`Get-InstallTrayStopEventName`/`$trayExePath` checks, not on the Run-value
branch, and both must keep running under `-Upgrade`.

It is a no-op when nothing is running (`Get-InstallLiveAppDestProcesses`
returns empty instantly) and load-bearing whenever something is. This is
a correctness fix the auto-updater exposes in EXISTING behavior, not
new-feature code gated behind `-Upgrade` - `-Upgrade`'s own added
responsibilities are only backup/rollback and relaunch, below (8.6/8.7).

8.6 Rollback

No existing precedent: the only "backups\" in this codebase today is the
per-addon zip backup folder (install.ps1:1348/1383) - Furphy's own CODE
has never been backed up before this feature. New, under `-Upgrade` only,
inserted immediately after `Invoke-InstallStopRunningApp` and before
Step 3's copy:
- `Backup-InstallCodeForRollback`: copies the CURRENT `$appDest`'s exact
  code-file set - the same `$codeFiles` allow-list at install.ps1:1590
  (`@('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'install.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico', 'VERSION')`)
  plus `ui\` and `host\` recursively (the same shape Step 3 already
  copies FROM) - into `%TEMP%\FurphyRollback-<oldVersion>-<guid>\`,
  OUTSIDE `$appDest`, so a mid-copy failure can never corrupt the backup
  itself. Keep exactly one prior version (overwrite any earlier
  `FurphyRollback-*` for the same install on every run); never accumulate.
- After Step 3/4's existing copy + parse-check (install.ps1's own
  `foreach ($f in 'addon-sync.ps1', 'addon-server.ps1') { $errs = ... }`
  block right after the host\ section) succeed: relaunch per `-Relaunch`
  (8.7), then poll `GET http://localhost:<port>/api/ping` for up to 20s
  (mirroring `RunCycle`'s own ping-wait pattern, host\FurphyHost.cs:5790-5814)
  and require the response's `version` field to equal the just-installed
  `VERSION` file's content.
- On timeout or mismatch: `Restore-InstallCodeFromRollback` (copy every
  file back from the rollback folder over `$appDest`), relaunch the OLD
  version the same way (8.7), and write `app-update.json` DIRECTLY via
  plain file I/O from install.ps1 (it's just JSON; the server always
  re-reads it fresh on its next access - no new IPC needed):
  `state="error"`, `lastError="post-install health check failed - rolled back to <oldVersion>"`,
  `lastErrorAt=now`. Settings then shows "Couldn't finish updating - kept
  your current version (1.22.0)." on its very next status poll.
- On success: delete nothing else (keep the ONE rollback backup per the
  "never accumulate" rule above - it is overwritten, not deleted, by the
  NEXT successful update's own backup step); return.

GAP AS ORIGINALLY SCOPED ABOVE: every trigger described so far is the
post-relaunch health check's own "timeout or mismatch" branch. Nothing
catches an exception thrown by Step 3/4's own copy loop or VERSION
parse-check itself (disk full, a file `Invoke-InstallStopRunningApp`
failed to unlock, a truncated staged package) -
`$ErrorActionPreference = 'Stop'` is set process-wide (install.ps1:82)
and the `-Console` call site (install.ps1:2155-2156:
`Invoke-FurphyInstallSteps; exit 0`) wraps that call in no try/catch at
all, so such a throw kills the process mid-copy and leaves `$appDest`
with a mix of old and new files, with no automatic recovery - directly
contradicting this feature's own GOALS section ("A failed install rolls
back to the previously-working version") and a concrete "user ends up
with no working app" path.

FIX: under `-Upgrade` only, wrap everything from
`Backup-InstallCodeForRollback` through the end of the existing copy +
parse-check block in one try/catch INSIDE `Invoke-FurphyInstallSteps`
itself (never at the `-Console`/wizard call sites, so a plain
non-`-Upgrade` install's error behavior is unchanged - a manual install
failing loudly and stopping is still correct there). On any caught
exception, run the SAME `Restore-InstallCodeFromRollback` + relaunch-the-
old-version steps the health-check-failure branch above uses, and write
the same `state="error"`/`lastError`/`lastErrorAt` shape to
app-update.json (substituting a message that names the copy failure
rather than the health check, e.g.
`lastError="install failed while copying files - rolled back to
<oldVersion>"`). In practice this means the `-Upgrade` try/catch and the
health-check-failure branch should converge on one shared internal
helper (e.g. `Invoke-InstallRollbackAndRelaunchOld`) rather than
duplicating the restore-and-relaunch steps twice.

This is the single highest-risk, most novel piece of the whole feature
(no code path like it exists today) and needs its own dedicated forced
tests - both a fixture release whose zip's VERSION is deliberately
wrong (exercising the health-check branch) AND a forced failure DURING
the copy itself (exercising the try/catch above) - not just the
happy-path fixture (section 12).

8.7 Relaunch (by caller intent, never by window-guessing)

The caller of `POST /api/app-update/install` (section 5) already knows
which of the two flows this is - it is baked into `-Relaunch` on the
command line, decided server-side by WHO called the route, never by
Win32 window-enumeration. (Win32 `FindWindow`-by-title, which
`Close-InstallMainWindow` uses for the uninstall flow, cannot reliably
see a plain-Edge-fallback app-mode window - `msedge.exe --app` is not
scoped to `$appDest` the way `Get-InstallLiveAppDestProcesses`'s
WebView2-child check is; that function's own doc comment names exactly
three recognized process shapes - `host\bin\FurphyHost.exe`,
`msedgewebview2.exe`, `addon-server.ps1` - and a plain-Edge window is not
one of them.)

TRAY AND WINDOW ARE NOT MUTUALLY EXCLUSIVE - detect both before
stopping either: a user can have the background tray running (Settings
> "Update addons in the background", started via the Run value at
logon) AND a main window open AT THE SAME TIME - nothing in this
codebase makes the two exclusive (the tray's own single-instance mutex,
`TrayProgram.ResolveMutexName`, host\FurphyHost.cs:4864/4880, only ever
guards against a SECOND `--tray`, never against a plain window instance
running alongside one). `Invoke-InstallStopRunningApp` (8.5) stops EVERY
`FurphyHost.exe` under `$appDest` regardless of launch mode
(`Get-InstallLiveAppDestProcesses`, install.ps1:700, matches by exe path
only, not by command line), but relaunch below is keyed SOLELY to the
single `-Relaunch` value the caller passed - there is no branch today
for "both were running." Concretely: a window-triggered install
(`relaunch:"window"`) would silently kill an independently-running tray
and never bring it back, since the Run value is deliberately left
untouched either way (section 2) - it would only return on the user's
next reboot, silently breaking "Update addons in the background" until
then.

FIX: before `Invoke-InstallStopRunningApp` runs, inspect each matched
`FurphyHost.exe`'s own `Win32_Process.CommandLine` for `--tray` (the same
`CommandLine` property the msedgewebview2.exe/powershell.exe branches of
`Get-InstallLiveAppDestProcesses` already read - just not currently read
for the FurphyHost.exe branch) and remember the result as
`$trayWasRunningIndependently`. After a passing health check, if
`-Relaunch` was `"window"` AND `$trayWasRunningIndependently` was true,
ALSO start `host\bin\FurphyHost.exe --tray` (the exact command the
`-Relaunch tray` branch below already uses) in addition to the window
relaunch. The reverse needs no extra code: `-Relaunch tray` already
starts the tray regardless, and section 2's silent-install gate ("ONLY
when no app window is open") means `-Relaunch tray` is never chosen while
a window is open, so there is no independent window instance for that
branch to ever need to restore.

- `-Relaunch window`: after a passing health check, launch
  `Addon Manager.vbs` (`Join-Path $appDest 'Addon Manager.vbs'`) via
  `wscript.exe`, reusing the EXACT idiom the wizard's own post-install
  "Open Furphy Addon Manager" button already uses
  (install.ps1:2116-2118:
  `$vbs = Join-Path -Path $script:appDest -ChildPath 'Addon Manager.vbs'; if (Test-Path -LiteralPath $vbs) { Start-Process -FilePath 'wscript.exe' -ArgumentList @('"' + $vbs + '"') }`).
  Note this exact line is currently reachable only from a GUI button
  click inside `Show-InstallWizard` - the `-Console`/`-Quiet` path
  (install.ps1:2150-2156) does NOT relaunch anything today, so `-Upgrade`
  genuinely adds new (if mechanically trivial) relaunch code, it does not
  just call something that already runs unattended.
- `-Relaunch tray`: after a passing health check, start
  `host\bin\FurphyHost.exe --tray` directly - the exact command line
  `StartupRegistry.BuildRunValue` already builds
  (host\FurphyHost.cs:4440-4442:
  `public static string BuildRunValue(string exePath) { return "\"" + exePath + "\" --tray"; }`) -
  so no window is EVER opened by the updater itself in the silent path,
  satisfying that fixed decision by construction (the relaunch target is
  chosen by which caller asked, never guessed).
- After a successful `-Relaunch tray`, the NEWLY-STARTED tray process
  fires the balloon (section 3.3) from its own first `RunCycle`
  post-cycle check (host\FurphyHost.cs:5763) once its durable
  `tray-state.json` marker (section 3.3) shows this install's
  `installedAt` has not been announced yet. This is deliberately never
  an in-process "next cycle" flag: `-Relaunch tray` starts a brand-new OS
  process (`Start-Process`) with no memory of the install that just
  happened, so anything living only in that process's own memory cannot
  carry the "already shown" fact across the very restart this feature
  depends on.

8.8 Cleanup

On success (either relaunch path, health check passed): delete the
downloaded `cache\app-update\*.zip`/`*.sha256` and the `stagedPath`
extraction folder (it has done its job; keep only the ONE rollback
backup per 8.6). Reset app-update.json to `state="installed"`,
`installedAt=now`, clear `stagedPath`. The next maintenance tick's check
naturally moves `installed -> idle` once `currentVersion` (re-read from
the new VERSION file) matches `latestVersion`.

On failure with rollback (8.6): keep the staged folder and downloaded
assets around for one more tick in case the failure was transient (e.g.
a slow health-check poll on a loaded machine) - only delete them once a
SUBSEQUENT check confirms the same tag is still not newer, or a fresh
newer tag supersedes them.

===============================================================================
9. SECURITY CONSIDERATIONS
===============================================================================

- HTTPS/TLS 1.2: every URL used (`api.github.com`, and every asset's own
  `browser_download_url`, which GitHub always serves over HTTPS) is
  HTTPS by construction; TLS 1.2 is forced process-wide in
  addon-server.ps1 (line 91) before any handler or maintenance child
  logic runs, so no new TLS code is needed on the server side. install.ps1
  itself makes NO network calls (it only extracts/copies/health-checks
  over `http://localhost`) so it needs no TLS setting of its own.
- Pinned repo: the GitHub API path is hardcoded to
  `repos/krenz444/furphy-addon-manager/releases/latest` (only the base
  host is overridable, and only via the TEST-ONLY
  `FURPHY_TEST_GITHUB_BASEURL` seam, which a real user run never sets -
  same contract as `FURPHY_TEST_WAGO_BASEURL`). No user-supplied or
  remotely-supplied value ever changes WHICH repo is queried.
- Sidecar limits: the sha256 sidecar only proves the downloaded zip
  matches what the release step attached - it is NOT a substitute for
  code signing and does not prove the release itself is trustworthy
  (anyone with push/release access to the repo could still ship a bad
  sha256+zip pair). This is an accepted, already-decided limitation (no
  code signing, section 2) - the sidecar's job is transport-integrity
  (catching a truncated/corrupted download or an MITM without valid TLS),
  not authorship-authenticity.
- No code signing: already decided (DISTRIBUTION-SPEC.md section 6.7,
  quoted verbatim: "the only downloaded artifact is a zip of PowerShell
  scripts and a .cmd; FurphyHost.exe is compiled on the player's own PC
  by install.ps1 from the shipped source, so no downloaded executable
  ever meets SmartScreen's reputation check") - do not add a signing step
  to this feature.
- Path safety: the staging extraction path is always a freshly
  `[guid]::NewGuid()`-suffixed folder under `%TEMP%`, never derived from
  any value in the downloaded JSON/zip (tag names/asset names are used
  only for EQUALITY comparisons and logging, never interpolated into a
  filesystem path outside that fixed prefix) - this forecloses a
  malicious tag name like `../../../evil` from ever being used as a path
  component. `Expand-Archive` extracts into that same fixed folder; no
  entry in the zip can escape it (PowerShell's `Expand-Archive` already
  refuses path-traversal entries).
- No privilege elevation: the updater runs at the SAME integrity level as
  the currently-running server (Furphy has never required admin rights
  to install, since it installs entirely under the WoW folder tree the
  user already owns) - `-Upgrade` must not add a UAC prompt or an
  elevated `Start-Process -Verb RunAs` anywhere in this pipeline. If a
  future machine-specific quirk ever seems to require elevation, that is
  a signal something in this design has drifted from "per-user install,"
  not a reason to add elevation.

===============================================================================
10. FAILURE MODES TABLE
===============================================================================

| Condition | Behaviour | User message (Settings status line) | Log line |
|---|---|---|---|
| GitHub API unreachable / DNS failure | state unchanged; lastError set | "Couldn't check for updates - try again later." | "App-update check failed: <exception message>" |
| GitHub API 403/429 (rate limited) | state unchanged; lastError set; no retry loop | "Couldn't check for updates - try again later." | "App-update check rate-limited by GitHub, will retry on the next tick" |
| No release newer than current version | state="idle" | "Furphy is up to date (version 1.22.0)." | "App-update check: already on the latest version" |
| releases/latest missing the zip or .sha256 asset | state="error"; lastError set; never downloads | "Couldn't check for updates - try again later." | "App-update check: release <tag> is missing the expected zip/.sha256 asset" |
| Download fails partway (network drop) | delete partial file; state stays as before; lastError set | (status line unchanged from before the attempt) | "App-update download failed: <exception message>" |
| sha256 mismatch | delete downloaded files; never extract; state="error" | "Couldn't check for updates - try again later." | "App-update integrity check FAILED for <tag> - sha256 mismatch, discarding download" |
| Extracted VERSION != release tag | delete staging folder; state="error" | "Couldn't check for updates - try again later." | "App-update package VERSION (<x>) did not match release tag (<tag>) - discarding" |
| Extracted VERSION not strictly newer than current (downgrade) | delete staging folder; state="idle"; never installs | "Furphy is up to date (version 1.22.0)." | "App-update refused: staged version is not newer than the running version" |
| Install requested while an addon job is running | 409; deferredReason="job-running"; retried by tray next cycle | "Waiting for an addon job to finish before installing." | "App-update install deferred: a job is running" |
| install.ps1 -Upgrade throws before the copy (e.g. disk full) | staged folder left for inspection; state="error" | "Couldn't finish updating - kept your current version (1.22.0)." | "App-update install failed before file copy: <message>" |
| Post-install /api/ping health check times out or returns wrong version | rollback (8.6) runs; old version relaunched | "Couldn't finish updating - kept your current version (1.22.0)." | "App-update health check failed after installing <tag> - rolled back to <oldVersion>" |
| Rollback restore itself fails (backup missing/corrupt) | server left down; nothing further attempted automatically | (app unreachable - `markOnline`'s existing offline banner) | "App-update rollback FAILED - manual reinstall required, backup at <path>" |
| Silent install succeeds, tray relaunch fails to come back up | app stays down until user manually relaunches | (app unreachable) | "App-update: tray relaunch after successful install did not answer /api/ping" |
| Window-initiated install succeeds, new window never opens within ~20s | SPA falls back to offline messaging | offline banner ("Server not reachable - restart from the desktop shortcut.") - see open question 4 | (same log line as the general ping-timeout case above) |

===============================================================================
11. FILES AND FUNCTIONS TO CHANGE
===============================================================================

addon-server.ps1
- New seam near the existing `$Script:WagoBaseUrl`/`FURPHY_TEST_WAGO_BASEURL`
  block (addon-server.ps1:104-107): `$Script:GitHubBaseUrl` +
  `$env:FURPHY_TEST_GITHUB_BASEURL` override.
- `Get-DefaultSettings` (:1315): add `appUpdateAutoInstall = $true`.
- `Get-Settings` (:1400): add the `appUpdateAutoInstall` coercion line.
- `Get-SettingsView` (:1536): add `appUpdateAutoInstall` to the view.
- `Handle-SettingsPut` (:7632): add the `appUpdateAutoInstall` write.
- New param `-AppUpdateOnly` (param block, :77-86, sibling of
  `-MaintenanceOnly`) and its early-exit branch next to `if ($MaintenanceOnly) { ... }`
  (:9228).
- New `Invoke-AppUpdateMaintenance` function (release lookup, download,
  verify, extract, VERSION check - section 8.1-8.4); called from inside
  the existing `-MaintenanceOnly` try/finally (:9256-9265) AND from the
  new `-AppUpdateOnly` branch.
- New `Handle-AppUpdateStatus` / `Handle-AppUpdateCheck` /
  `Handle-AppUpdateInstall` functions + three `$Script:Routes` entries
  (appended after the last entry at :8799, before the closing `)` at
  :8800). Deliberately NOT added to `$Script:FlavourScopedEndpoints`
  (section 5's flavour-routing note).
- `Handle-State` (:6986): stamp `windowOpenAt` in app-update.json; fold
  the app-update status object into its response body next to
  `gameRunning` (:~7159).
- `Handle-Open` (:8319): extend `$allowedOpenHosts` (:8510) with
  `'github.com'`; ALSO update the 400 error string (:8521) and the doc
  comment (:8484) that both currently hardcode "the two" marketplaces
  (section 3.1).
- New `Save-AppUpdateState`/`Get-AppUpdateState` helpers mirroring
  `Save-Settings`/`Get-Settings`'s atomic tmp+Move-Item pattern (:1390-1397).

install.ps1
- New `[switch]$Upgrade` + `[string]$Relaunch` on the param block (:46-80).
- New `Invoke-InstallStopRunningApp` (factored from the Uninstall-only
  sequence at :1163-1204/:402-916), called UNCONDITIONALLY at the top of
  `Invoke-FurphyInstallSteps` (:1521) - the load-bearing fix, section 8.5.
  Only the Run-value removal sub-step is skipped for `-Upgrade`; the
  TrayStop-event signal and its wait are kept unconditionally (section
  8.5's a/b/c breakdown). Also records whether an independent tray
  instance was running (`$trayWasRunningIndependently`, section 8.7) by
  reading each matched FurphyHost.exe's own command line for `--tray`.
- New `Backup-InstallCodeForRollback` / `Restore-InstallCodeFromRollback`,
  called only under `-Upgrade`, bracketing Step 3's copy (section 8.6).
- New try/catch under `-Upgrade` wrapping `Backup-InstallCodeForRollback`
  through the copy + parse-check block, triggering the same
  rollback-and-relaunch-old-version path as a health-check failure on ANY
  exception during the copy itself (section 8.6's gap fix) - shared with
  the health-check-failure branch via one internal helper.
- New post-install health-check + relaunch-by-`-Relaunch` logic
  (section 8.6/8.7), added after the existing parse-check block that
  follows the host\ section (around :1698-1710); when `-Relaunch window`
  and `$trayWasRunningIndependently` was true, also relaunches the tray
  (section 8.7).
- Cross-reference (round 44, SETUP-SPEC.md): FurphyAddonManager-Setup.exe,
  the new one-file GUI installer, is a first-install tool only - it never
  sets `-Upgrade` or `-Relaunch`, is never itself downloaded or launched by
  the self-updater, and its `FURPHY_INSTALL_LAUNCHED_BY_SETUP` environment
  variable is not read anywhere near this code path. The self-updater's
  own fixed `-Upgrade -Relaunch <mode> -Console -Quiet` command line
  (:495) is unchanged and untouched by `/S` or by anything in
  SETUP-SPEC.md. No functional change here.

host\FurphyHost.cs
- `TrayForm.RunCycle` (:5763): one new post-cycle step (GET status, POST
  install {relaunch:"tray"} when eligible) - section 7/8.7.
- One new `ShowBalloonText` call site for the post-silent-install
  notification (reusing :6782), fired from the cycle AFTER a successful
  tray-relaunch install, gated on the new durable `tray-state.json`
  marker below (section 3.3) rather than an in-memory flag.
- `WriteStateFile` (:6817): new `lastAppUpdateAnnouncedInstalledAt` field
  in `tray-state.json`, written atomically alongside every other field
  this function already writes each cycle (section 3.3).
- No changes to menu construction (~5333-5382) - explicitly decided
  against in section 3.0.

ui\index.html
- New `#settings-app-updates` group (between :1132 and :1133, i.e. right
  after `#settings-updates` and before `#settings-appearance`) -
  section 3.1's exact markup.
- New `#banner-app-update` (sibling of `#banner-offline` at :783) -
  section 3.2's exact markup.

ui\app.js
- New `renderAppUpdates(s)` (mirrors `renderBackgroundUpdates`, :6878),
  called from the same settings-render pass right after it (:6751).
- New `Actions.checkAppUpdate` / `Actions.installAppUpdate` (POST calls),
  alongside `setBackgroundUpdates`/`setRunAtStartup` (:5368-5395).
- New `App.enterUpdatingState()` (parallels `enterUninstallingState`,
  :8235).
- Wire `Store.state.appUpdate` off the existing `reloadState` diff
  (:8053) - no new poll loop.
- New `APP_UPDATE_SEEN_KEY` one-time toast (section 3.4), modeled on the
  `WELCOME_SKIPPED_KEY` pattern (declared :7802, used :8348/:8415).
- Mock-mode (`?mock=1`) fixtures for `/api/app-update/*` and a mock
  `appUpdate` object that cycles through states, mirroring how
  `mockSettings.backgroundUpdates` already exercises the Updates section.

package.ps1
- After the existing `Compress-Archive` call and `Write-Host "Built $zipPath..."`
  line (:143/150): emit
  `(Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant() | Set-Content -LiteralPath "$zipPath.sha256" -Encoding Ascii -NoNewline`
  (bare lowercase hex, no trailing newline, ASCII - matching this
  codebase's other `Set-Content -Encoding Ascii` sites). Deliberately NOT
  produced for `FurphyAddonManager-latest.zip` - the updater always
  targets the release's own tag-versioned asset via `browser_download_url`
  (section 8.2), never the floating "latest" name, so latest.zip needs no
  sidecar.
- Extend the printed `gh release create` reminder (:178) to attach the
  new sidecar: `gh release create v$version "$zipPath" "$latestZipPath" "$zipPath.sha256"`.

Documentation (not code, but required for this feature to ship
correctly - section 13):
- DISTRIBUTION-SPEC.md section 6.6: document the third release asset.
- SETTINGS-SPEC.md: new `appUpdateAutoInstall` row (format: key | control
  | default | label | helper line | tooltip | prior location - matching
  every existing row in that file).
- CHANGELOG.md: the 1.22.0 entry.
- README.md/README.txt: mention automatic updates and how to turn them
  off, matching this file's own "no code signing" framing already used
  for the download-warning text (DISTRIBUTION-SPEC.md section 6.8).

===============================================================================
12. TEST PLAN
===============================================================================

Unit (tests\unit\, new files):
- `Server.AppUpdateVersionCompare.Tests.ps1` - `[System.Version]` compare
  cases mirroring the ones the downgrade guard already covers
  (install.ps1:1562): "1.9.0" vs "1.10.0" (must NOT sort the wrong way as
  a string compare would), equal versions, an older candidate, a
  malformed version string (must not throw, must be treated as "not
  newer").
- `Server.AppUpdateReleaseParse.Tests.ps1` - asset-name matching against
  a fixture `releases/latest` JSON body: exact-name match required
  (`FurphyAddonManager-<tag>.zip` / `+ .sha256`), a release missing the
  `.sha256` asset, a release missing the zip asset, a release with EXTRA
  unrelated assets present (must still pick the right two by exact name,
  never by "first .zip found").

Integration (tests\integration\, new file
`Server.AppUpdate.Tests.ps1`), against a REAL scratch server on a
scratch port (never 47831) with `$env:FURPHY_TEST_GITHUB_BASEURL` pointed
at a new local stub helper `Start-GitHubReleaseStubServer` in
tests\lib\common.ps1 - modeled directly on the existing
`Start-CfCatalogueStubServer` (tests\lib\common.ps1:493, itself built on
`Start-StaticServer` at :445, same "environment-variable seam, same as
FURPHY_TEST_WAGO_BASEURL" contract documented at :478-484):
- Check finds a newer fixture release -> `state` becomes `available` then
  `ready` after download+verify.
- Download+verify a GOOD zip+sha256 -> `ready`, `stagedPath` set.
- A TAMPERED sha256 (fixture with a deliberately wrong hash) -> `error`,
  state never advances past the pre-download state, staging folder never
  created.
- A zip whose VERSION does not match the release tag -> `error`, same
  non-advancement.
- `POST /api/app-update/install` while game mode is forced true via the
  real `-WowFakeProcessName <name>` CLI parameter (NOT an environment
  variable - `addon-server.ps1`'s param block declares
  `[string]$WowFakeProcessName` at :85, backed by
  `$Script:WowFakeProcessNameOverride` at :9053) -> 409.
- `POST /api/app-update/install` while a job is deliberately kept running
  (same fixture pattern `Server.Jobs.Tests.ps1` already uses to hold a
  job open) -> 409, `deferredReason="job-running"` on the next status
  poll.
- `GET /api/state` once (to stamp `windowOpenAt`), then immediately
  `POST /api/app-update/install {relaunch:"window"}` -> succeeds (does
  not 409 on a false "no window" reading).
- Confirm the tray's own `PingUrl`/`JobsUrl`/`JobUrl` traffic pattern
  (simulated by hitting `/api/ping`, `/api/jobs` directly, never
  `/api/state`) does NOT advance `windowOpenAt` - i.e. `windowOpen` reads
  false after only that traffic, proving the Handle-State-scoped stamp
  (section 7) does not self-poison the way a global `Invoke-Route` stamp
  would have.

Fixture-acceptance (tests\fixture-acceptance\, new file
`AppUpdate.SilentUpgrade.Tests.ps1`), modeled directly on
`tests\integration\Install.Downgrade.Tests.ps1`'s `New-StaleInstallerSource`
helper (verified to exist at that file's line 32) but INVERTED - a NEWER
fixture source with a bumped VERSION, re-zipped and re-hashed - run
against a scratch install under `tests\.tmp\` on a scratch port (settings
pre-seeded, per the build's standing hard rule of never touching a real
install):
- Stage the newer fixture as the "downloaded+verified" extraction,
  `POST /api/app-update/install` against the scratch server, assert the
  scratch `addons.json`/`settings.json`/`state.json` survive UNTOUCHED.
- Assert the scratch tray (if started on the scratch port) is relaunched
  and reachable again post-upgrade.
- Reuse `Server.Uninstall.Tests.ps1`'s own real-machine-state guard
  (`Get-ProductionRunValue`/`Get-ProductionInstalledAppsSnapshot`,
  verified to exist at that file's lines 31 and 43) as a before/after
  snapshot around the WHOLE test - byte-identical before/after is the
  regression this fixture exists to catch, since this feature's own
  detached-launch mechanism is copied from the exact code shape that
  caused the 2026-09-06 14:45 incident DISTRIBUTION-SPEC.md section 0
  documents (a scratch run that touched the real HKCU Run value and the
  real tray).
- A FORCED health-check-failure case (a fixture release whose extracted
  VERSION is deliberately wrong, or a stub `/api/ping` that returns a
  mismatched version after the swap) -> assert
  `Restore-InstallCodeFromRollback` actually restores the OLD code
  (compare a marker string/byte in a restored file against the
  pre-upgrade original) and the OLD version answers `/api/ping` again
  afterward. This is the dedicated rollback test called out as
  non-negotiable in section 8.6 - do not ship rollback covered only by
  the happy path.
- A FORCED copy-failure case (e.g. a locked file left under `$appDest`'s
  `host\bin\` so `Copy-Item` throws mid-Step-3, simulating the disk-full/
  locked-file scenario section 8.6 now calls out) -> assert the SAME
  rollback path runs (the NEW `-Upgrade`-only try/catch, not just the
  health-check branch) and the OLD version answers `/api/ping` again
  afterward. This is the other half of section 8.6's rollback coverage -
  a failure DURING the copy must roll back exactly like a failure AFTER
  it; do not ship one covered and not the other.

SPA harness (mock mode, `?mock=1`):
- `mockSettings` gains `appUpdateAutoInstall`; a new mock `appUpdate`
  object cycles through `idle`/`checking`/`ready`/`installing`/`installed`/`error`
  the way `mockSettings.backgroundUpdates` already exercises the Updates
  section.
- Assert the banner appears ONLY when `state==="ready"`.
- Assert "Install now" fires `App.enterUpdatingState()`'s overlay
  transition.
- Assert the new Settings toggle round-trips through the existing
  `saveSettings()`/`Actions` pattern with no new plumbing.
- Assert `#link-app-update-whatsnew` and the first-run toast's "What's
  new" action both call `Actions.openWhat("url", ...)` and never build a
  URL string themselves outside that one path.

Live-safety rules for ALL of the above (standing, non-negotiable, same as
every other test in this repo): scratch ports only (never 47831), scratch
`-Root`/`-WowPath` directories only (never the real WoW/AddOns folders,
never `C:\Program Files`), `FURPHY_TEST_GITHUB_BASEURL` pointed at a
local stub for every test that would otherwise reach GitHub - a real
network call to api.github.com or a real download from
github.com/krenz444/furphy-addon-manager is a test bug, not a passing
test. `tests\run-all.ps1` itself is never run as part of implementing or
verifying this design (per this task's own read-only constraint) and
`FurphyHost.exe`/the live Program Files install are never launched or
touched.

===============================================================================
13. RELEASE PROCESS CHANGES
===============================================================================

- `package.ps1`: emit `FurphyAddonManager-<ver>.zip.sha256` (section 11) -
  a permanent, enforced step, not a one-off, matching how
  `FurphyAddonManager-latest.zip` itself became a permanent step per
  DISTRIBUTION-SPEC.md section 6.6 ("Make attaching this second asset a
  permanent, enforced step... print a reminder line in package.ps1's
  console output either way").
- `gh release create` recipe (printed reminder, and the actual command
  whoever runs the release types): `gh release create v$version "$zipPath" "$latestZipPath" "$zipPath.sha256"` -
  three assets total from here on.
- DISTRIBUTION-SPEC.md section 6.6: add a paragraph documenting the third
  asset and its purpose (integrity verification for the self-updater,
  never for SmartScreen/signing purposes - tie back to section 6.7's
  no-signing decision so a future reader does not conflate the two).
- SETTINGS-SPEC.md: add the `appUpdateAutoInstall` row in the same
  "Group: X" / "Row N" format every other row in that file uses.
- CHANGELOG.md: new entry under a new round heading, in this codebase's
  own established voice (state what was verified headlessly vs. not, per
  the 1.21.0 entry's own precedent at the top of the file) - "1.22.0:
  Furphy can now update itself" - list the toggle, Check now/Install now,
  the banner, the tray balloon, the sha256 sidecar, and the explicit
  "1.21.x users: install 1.22.0 by hand once" note (section 14).

===============================================================================
14. ROLLOUT
===============================================================================

Ships in 1.22.0. This is the FIRST version carrying the updater, and per
the fixed decision it can only update installs that are ALREADY at
1.22.0 or newer - a 1.22.0 server is the earliest one that has
`Invoke-AppUpdateMaintenance`/the new API routes/the fixed
`Invoke-InstallStopRunningApp` at all, so there is no version it could
reach backward to.

1.21.x users: no code in this feature ever runs for them. They install
1.22.0 exactly the way every version upgrade has always worked today -
download the zip from the release page (or the existing
`releases/latest/download/FurphyAddonManager-latest.zip` stable link) and
run `Install Furphy.cmd`/`install.ps1` once, by hand. State (addons.json,
settings.json, flavours\) is preserved exactly as every in-place upgrade
already preserves it - this feature changes nothing about that path.
Say this explicitly in the 1.22.0 CHANGELOG.md entry and in README.md's
own "how updates work" section, so a 1.21.x user reading either does not
wonder why nothing auto-updated for them.

Testing the very first self-update end to end, BEFORE publishing 1.22.0
publicly: publish a 1.22.0 PRE-release first (`gh release create v1.22.0 --prerelease ...`)
on the real repo, then run a scratch 1.22.0-minus-one build (e.g. locally
labeled 1.21.99 or a scratch VERSION bump - never the real 1.21.0 install)
pointed at the REAL github.com (no `FURPHY_TEST_GITHUB_BASEURL` override
for this one deliberate pass) on a SCRATCH port/root, and confirm: the
check finds the pre-release (GitHub's `releases/latest` endpoint skips
pre-releases by design, so this either needs a direct
`releases/tags/v1.22.0` lookup for this one verification pass, or
promoting the pre-release to a real release first and testing the whole
pipeline against tests\.tmp\ scratch state only), the sha256 verifies
against the REAL attached sidecar, the VERSION-in-zip check passes, and
the scratch install ends up running real 1.22.0. Only after that scratch
end-to-end pass succeeds should the pre-release be promoted to the real,
public release. This is the one place in this whole feature where
hitting the real GitHub API in a test-like pass is correct and
intentional - everywhere else (section 12) it is a bug.

===============================================================================
15. IMPLEMENTATION PLAN - WORK PACKAGES FOR PARALLEL FIXERS
===============================================================================

Five disjoint packages, no two sharing a file (each package's file list
is exhaustive for that package - nothing in files not listed here should
be touched by that package):

PACKAGE A - Server: state machine, settings, GitHub pipeline
- Files: addon-server.ps1 ONLY.
- Work: sections 4, 5, 6, 7 (server half), 8.1-8.4, 9's server-side
  points, part of 11's addon-server.ps1 list. New seam, new settings
  key's four touch points, `-AppUpdateOnly` switch + branch,
  `Invoke-AppUpdateMaintenance`, the three new `Handle-AppUpdate*`
  functions + routes, `Handle-State`'s `windowOpenAt` stamp and response
  fold-in, `Handle-Open`'s allow-list extension, the new atomic
  save/load helpers for app-update.json.

PACKAGE B - Installer: stop-running-app fix, backup/rollback, relaunch
- Files: install.ps1 ONLY.
- Work: section 8.5 (the load-bearing `Invoke-InstallStopRunningApp` fix
  and its unconditional call site), 8.6 (backup/rollback), 8.7 (relaunch
  by `-Relaunch`), the new `-Upgrade`/`-Relaunch` param block entries.
  This package can and should be built/tested independently of Package A
  - it only needs to accept the SAME command-line shape Package A's
  `Handle-AppUpdateInstall` will eventually construct (agree on that
  shape from section 5 up front; do not renegotiate it mid-implementation).

PACKAGE C - Native host: tray cycle integration + balloon
- Files: host\FurphyHost.cs ONLY.
- Work: section 7's tray-cycle step in `RunCycle`, the new
  `AppUpdateStatusUrl()`/`AppUpdateInstallUrl()` helpers, the one new
  `ShowBalloonText` call site (3.3/8.7). Depends only on the API SHAPE
  from section 5 (GET status / POST install), not on Package A's/B's
  internal implementation - can be built against a hand-written stub
  response while A is in progress.

PACKAGE D - SPA: Settings section, banner, toast, mock fixtures
- Files: ui\index.html and ui\app.js ONLY.
- Work: sections 3.1-3.5 in full (markup, `renderAppUpdates`, the two new
  `Actions`, `enterUpdatingState`, the `Store.state.appUpdate` wiring off
  the existing `reloadState`, the `APP_UPDATE_SEEN_KEY` toast, mock-mode
  fixtures). Depends only on the API response SHAPE from section 5 - can
  be built and demoed entirely against `?mock=1` fixtures before Package
  A ships anything real.

PACKAGE E - Tests, release process, docs
- Files: tests\lib\common.ps1, tests\unit\Server.AppUpdateVersionCompare.Tests.ps1,
  tests\unit\Server.AppUpdateReleaseParse.Tests.ps1,
  tests\integration\Server.AppUpdate.Tests.ps1,
  tests\fixture-acceptance\AppUpdate.SilentUpgrade.Tests.ps1, package.ps1,
  DISTRIBUTION-SPEC.md, SETTINGS-SPEC.md, CHANGELOG.md, README.md,
  README.txt.
- Work: section 12 in full, section 13 in full. The new
  `Start-GitHubReleaseStubServer` helper in common.ps1 should be written
  FIRST (it is the one piece Package A's own integration-test authoring
  will want early) - coordinate that one function's shape with whoever
  starts on Package A, but everything else in this package is otherwise
  independent.

Suggested build order given the dependency notes above: A and B can start
immediately and in parallel (they only share an agreed command-line
contract, not a file). C and D can each start immediately against the
section 5 API shape without waiting for A. E's stub-server helper should
land early (day one) so A's own tests aren't blocked; the rest of E
finishes last, once A/B/C/D are stable enough to write real
integration/fixture-acceptance tests against.

===============================================================================
16. OPEN QUESTIONS FOR ERIC
===============================================================================

1. Pre-release testing (section 14) needs the FIRST real end-to-end self-
   update test to hit the real github.com at least once, deliberately,
   from a scratch install - is Eric comfortable with that one
   intentional exception to "tests never touch real GitHub," done by a
   human running it once by hand rather than by any automated test?
2. The GitHub API's unauthenticated rate limit is 60 requests/hour per
   source IP, shared across EVERY Furphy install behind that IP (e.g. a
   household with several PCs on one router, or a future scenario with
   many installs polling from one NAT'd network). At roughly one check
   per install per hour this is very unlikely to matter, but Eric should
   decide now, not after a support ticket, whether that's an acceptable
   risk to leave unauthenticated, or whether a lightweight fallback
   (e.g. reading the `Retry-After`/rate-limit-reset header and backing
   off further, already partially covered by section 8.1's "treat 403/429
   as transient" handling) is worth adding before 1.22.0 ships.
3. Section 8.6's rollback keeps exactly one prior version's backup,
   overwritten by each successful update. If two updates happen in quick
   succession (e.g. 1.22.0 -> 1.22.1 -> 1.22.2, each auto-installed
   within the same day), only the 1.22.1 backup survives - rolling back
   past that point is not possible. Is a single-version rollback window
   sufficient, or does Eric want more history kept (with the added disk
   usage and cleanup complexity that implies)?
4. Section 3.2's window-relaunch-timeout fallback (the "new window never
   appears within ~20s" case) shows the existing generic `#banner-offline`
   copy verbatim: "Server not reachable - restart from the desktop
   shortcut." Right after an update that was supposed to close and
   reopen the app BY ITSELF, telling the user to manually "restart from
   the desktop shortcut" may read as confusing or contradictory. Is the
   generic copy acceptable for this one case, or does Eric want a
   distinct message here (e.g. "Furphy is finishing an update - if this
   doesn't clear in a minute, restart it yourself from the desktop
   shortcut")?

===============================================================================
APPENDIX: CRITIC ITEMS REJECTED
===============================================================================

None. Every item in this round's completeness-review pass was re-verified
directly against the build root (install.ps1, addon-server.ps1,
host\FurphyHost.cs, ui\index.html, ui\app.js) and found accurate - all
nine were folded into the sections above:
1. Section 8.5's stop-tray fix, now split into explicit (a)/(b)/(c) steps.
2. Section 8.6's rollback, now also covering a copy-phase exception, not
   only a post-install health-check failure (plus a matching section 12
   test).
3. Section 3.1's status-text table (state=installing) and section 4's new
   stuck-"installing" watchdog.
4. Section 8.7's tray/window mutual-exclusivity fix.
5. Section 3.3/8.7's durable tray-state.json balloon marker.
6. Section 3.1/11's Handle-Open error-string and doc-comment updates.
7. Section 3.2/10's corrected offline-banner quote, plus open question 4.
8. Section 5's one-sentence flavour-routing safety note.
9. The five line-number/version citation-drift fixes throughout (section
   4's $Script:Version; section 5/11's Routes-array closing paren;
   section 8.5/11's install.ps1 param-block close; section 3.1's
   #updates-background-status line; section 11's renderBackgroundUpdates
   call-site line).
