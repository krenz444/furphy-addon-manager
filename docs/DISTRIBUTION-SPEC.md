# DISTRIBUTION-SPEC.md - Furphy Addon Manager
## Uninstall, tray/startup controls, and easy distribution

Authoritative build spec, synthesized from DISTRIBUTION-RESEARCH.md,
LIFECYCLE-RESEARCH.md, Designer A ("fewest moving parts"), Designer B
("best first five minutes"), and the judge's decision (B wins, with named
grafts from A and ten required fixes). This document supersedes both
designer drafts - where they differ, this document's text is the one to
build against. ASCII only.

-------------------------------------------------------------------------
## 0. READ THIS FIRST
-------------------------------------------------------------------------

**Tell Eric now, independent of any of this shipping:** LIFECYCLE-RESEARCH.md
section 0 found that `install.ps1 -Uninstall`'s "Start with Windows" removal
(lines 289-300) is unconditional and unscoped - testing it against an
isolated scratch fixture, exactly as this round's rules required, deleted
this machine's real, live `FurphyAddonManager` registry value under
`HKCU:\...\Run` as a side effect. **Eric should check whether "Start with
Windows" is still on in his real Furphy install and turn it back on if not.**
This is a standing fact independent of the build plan below.

**Nothing in section 3, 4, 5, or 6 below may be implemented against
anything but a scratch fixture until fix (1) below has landed and been
verified.** Every test of a new one-click uninstall surface before that fix
lands just repeats the incident above.

STATUS 2026-09-06 15:05 (main session): fixes 1 and 2 are ALREADY APPLIED in the build root - do not redo them. install.ps1 now has Get-InstallPort / Get-InstallStartupValueName / Get-InstallTrayStopEventName (scratch root on the production port -> null -> step skipped; other ports -> .Test / .TrayStop.<port>), the -Uninstall block uses them for BOTH the Run value and the stop event, install.ps1 is in its own $codeFiles and in deploy.ps1's, and a dot-source guard + tests\unit\Install.Scoping.Tests.ps1 (6/6) cover the name computation. Fix 3 must reuse Get-InstallStartupValueName's null/scratch rule for the Installed-Apps key. The incident that motivated fix 1 happened during THIS spec's own research pass: the real Run value was removed and the real tray stopped at 14:45; both were restored by hand.

Ten required fixes, all binding on whichever agent picks up each file (full
detail under each fix's own section further down; this is the checklist):

1. **BLOCKING.** Scope the Run-value removal (install.ps1:289-300) behind
   `Test-LooksLikeScratchRun` or a port-scoped name (mirror
   `Get-StartupValueName`, addon-server.ps1:6398-6411). See section 5.1.
2. **HARD BLOCKER.** Add `install.ps1` to `$codeFiles` (install.ps1:494) -
   no installed copy can uninstall itself without this. See section 5.2.
3. Apply the *same* scratch-run/port-scoped guard to the new Installed-Apps
   registry key's removal, from the first commit that writes it. See
   section 5.4.
4. Fix `MenuStartup_Click` (host\FurphyHost.cs, tray "Start with Windows"
   click) to also write `runAtStartup` into `settings.json`. See section
   3.1.
5. Define and enforce, in one place, the invariant that makes the
   busy/job-running refusal well-defined even when nothing is running to
   ask: **"no server reachable on this install's port implies no sync job
   can be in progress for it."** See section 5.3.
6. WinForms install wizard: hide the underlying console only after the
   Form is confirmed constructible, keep the tested console path as an
   automatic fallback, and pick one explicit progress-pump mechanism
   (this document picks `DoEvents`, see section 6.2). Test at a non-100%
   DPI setting.
7. Before the GitHub Pages landing page goes live, scrub all copy and
   screenshots of scratch/test artifacts (fixture paths, test port 47899,
   decoy files). See section 6.5 and the acceptance checklist.
8. Make "attach `FurphyAddonManager-latest.zip` to every release" a
   permanent, enforced release-checklist item (ideally checked by
   `package.ps1` itself), and publish one catch-up release before any
   landing page points at "latest" (public Releases stop at v1.1.0 today;
   `dist\`/`VERSION` are far ahead). See section 6.6.
9. **One** WM_CLOSE-by-window-title implementation, inside `install.ps1`'s
   existing wait loop, used identically no matter which trigger spawned
   that copy - do not add a second P/Invoke copy in `host\FurphyHost.cs`.
   See section 5.3.
10. On every public-facing page, state plainly that the install "isn't
    signed with a paid certificate yet" (not merely "may show a prompt") -
    see section 6.4 for the exact sentence used everywhere.

-------------------------------------------------------------------------
## 1. Eric's ask (verbatim) and decisions
-------------------------------------------------------------------------

> "from the taskbar, i need a right click option to uninstall furphy addon
> manager, and a way to disable the auto update service, as well as disable
> running it automatically on startup / from in the app, i need this
> functionality as well, if possible / from outside the app, i want to
> think of the best way to distribute this easily onto other people
> computers from the repo or download link without any difficulty for the
> below average tech savvy wow player."

("taskbar" = the tray icon's right-click menu, confirmed at task start.)
Standing style: plain words, no fluff, confirmations only where something
is destructive, never lie about what a control does.

**Decisions:**

- Uninstall from the tray, from Settings, and from Windows' own
  Settings > Apps list, all converging on one mechanism (section 5).
- Disabling the background-update service and startup-on-boot, from the
  tray AND from in-app, are addressed by ONE new tray checkbox
  ("Update addons in the background", mirroring the existing "Start with
  Windows" checkbox) plus pointing Eric at two rows that **already exist**
  in SETTINGS-SPEC.md this round and need no new code (section 3.3).
- Distribution stays script-based (zip + `Install Furphy.cmd`), gains an
  optional WinForms front end built with the project's own existing
  Add-Type/csc mechanism (no new binary, no signing dependency), plus a
  GitHub Pages landing page and an Installed-Apps registry entry
  (section 6). A compiled, downloaded, unsigned installer EXE is
  explicitly rejected for this round (section 6.7) - not because a
  graphical installer is unsafe, but because a *downloaded, compiled*
  binary trips SmartScreen's app-reputation wall in a way a script
  giving itself a Form never does.
- Chosen design: **Designer B ("best first five minutes")**, because it
  draws the SmartScreen line in the right place (it attaches to a
  compiled, downloaded EXE, not to a script that builds itself a WinForms
  window) and so is the only one of the two that actually closes Eric's
  literal "without any difficulty for the below average tech savvy wow
  player" ask with something better than a landing page in front of an
  otherwise-unchanged console install. Three points are grafted in from
  Designer A (all applied below): the more direct "isn't signed with a
  paid certificate yet" wording (fix 10), citing the IExpress headless
  build as inconclusive rather than "doesn't work" (section 6.7), and A's
  explicit "same converged path, not literally shared code" framing so
  nobody re-adds a second WM_CLOSE implementation in C# later (fix 9).

-------------------------------------------------------------------------
## 2. Tray menu - final spec
-------------------------------------------------------------------------

File: `host\FurphyHost.cs`, class `TrayForm`, `BuildContextMenu`
(today at 4564-4598; **being edited live by another workflow this round -
re-locate these anchors by content, not by line number, before touching
this file**).

Final menu, top to bottom:

```
Open Furphy Addon Manager
<status line - disabled, unchanged>
Check for updates now
-----------------------------
[ ] Start with Windows                          (unchanged label; wiring fixed, see 3.1)
[ ] Update addons in the background              <- NEW (2.1)
-----------------------------
Uninstall Furphy Addon Manager...                <- NEW (2.2)
-----------------------------
Quit
```

Two new lines added to today's five real items; nothing else moves,
renames, or changes meaning.

### 2.1 "Update addons in the background" (new checkbox)

- **Label:** "Update addons in the background" - the exact string
  SETTINGS-SPEC.md Row 2 already uses for this same `backgroundUpdates`
  boolean. Do not invent a second name for the same setting.
- **Checked state:** read fresh from `settings.json` on every
  `Menu_Opening`, the same way "Start with Windows" already re-reads
  `StartupRegistry.Exists` at 4602 - use the tray's existing
  `TraySettingsReader` (3944-3975), no new read path.
- **Always enabled** - a boolean the user can flip regardless of whether a
  cycle is currently running, matching "Start with Windows".
- **Click handler:** write `backgroundUpdates = !current` directly to
  `settings.json` via `HostFiles.UpdateJsonObject` (the tray already reads
  this file directly; this is a symmetric write, no new dependency, no
  HTTP call). If the click turns it **off**, immediately call the exact
  same `_stopEvent.Set()` that `MenuQuit_Click` uses, so the tray icon
  disappears right away instead of waiting up to the existing ~60s
  `WaitForNextCycle` poll slice (4818-4823) to notice on its own.
- **No confirm dialog** - matches the Settings screen's own toggle (none)
  and matches "Start with Windows" sitting next to it on this exact menu.
- **The icon disappearing on toggle-off is correct, not a bug to route
  around.** The icon's whole reason to exist is "background updates are
  on" - this is already documented tray behavior (`WaitForNextCycle`
  already exits the tray when `backgroundUpdates` goes false), and it
  matches Eric's own phrasing ("the auto update service") treating the
  icon and the service as one thing. Ship a one-time balloon using the
  existing balloon plumbing (`_balloonShown`/`_balloonText`, ~5850-5856):
  **"Background updates turned off - Furphy's tray icon will now close."**
  This is not optional in this document (unlike in both designer drafts) -
  a vanishing tray icon with zero explanation reads as "did my click just
  break something?" to exactly the audience this round is written for.

### 2.2 "Uninstall Furphy Addon Manager..." (new item)

Trailing "..." signals (standard Windows convention) that clicking opens a
dialog rather than acting immediately - consistent with every other item on
this menu that pops something.

- **Enabled state:** always enabled by default. Optional, zero-cost
  hardening: bind `Enabled` to the same boolean already computed for
  graying out "Check for updates now" during an active cycle (reuses an
  existing variable, no new state machine) - this narrows, but is not
  the actual safety net for, the busy-uninstall case; the real safety net
  is the invariant in section 5.3.
- **Click handler:** first WinForms `MessageBox.Show` in this file (no
  `MessageBox` call exists anywhere in `host\FurphyHost.cs` today):

  ```
  MessageBox.Show(
    "This removes Furphy's program files, its Start with Windows\n" +
    "setting, and the CurseForge install-link handler.\n\n" +
    "Your addons stay installed in WoW. Your addon list is kept at\n" +
    "<appDest> so reinstalling brings it back.\n\n" +
    "Uninstall now?",
    "Uninstall Furphy Addon Manager?",
    MessageBoxButtons.YesNo,
    MessageBoxIcon.Warning,
    MessageBoxDefaultButton.Button2)   // No is default - an accidental
                                        // Enter/Space must never confirm
  ```

  On **Yes**: run the shared trigger logic in section 5.3 ("try the server,
  fall back to a local copy+launch"), then call the tray's own existing
  `_stopEvent.Set()` so it exits through the normal Quit path - no new exit
  route. On **No / Escape / dialog closed**: do nothing, menu just closes.

  **What the C# code actually does on Yes (deliberately thin, per fix 9):**
  1. Best-effort `POST /api/uninstall` (with the required `Origin` header,
     see section 3.4) to `http://localhost:<thisInstall'sPort>/api/uninstall`
     with a short timeout (~1.5-2s).
  2. If that succeeds (any 2xx), stop here - the server owns the rest
     (section 5.3's server-reachable path). Call `_stopEvent.Set()` and
     return.
  3. If it fails (timeout, connection refused, any error), the server is
     not running - by the section 5.3 invariant, no sync job can be in
     progress. Do a plain `File.Copy` of `install.ps1` (now bundled, fix 2)
     to a fresh GUID-suffixed path under `%TEMP%`, then
     `Process.Start` it detached and hidden with
     `-WowPath "<resolved wowRoot>" -Uninstall` (no `-NoShortcuts`/
     `-NoProtocol` in production). **No WM_CLOSE P/Invoke lives here** -
     that logic lives once, inside the spawned `install.ps1` itself
     (section 5.3), and runs identically no matter who spawned it.
  4. Call `_stopEvent.Set()` and return either way.

  If a sync job IS confirmed running (step 1 succeeded but the server's own
  `Handle-Uninstall` answered "busy"), show a second, plain `MessageBox`
  (OK only): **"Furphy is updating an addon right now. Try Uninstall again
  in a minute."** - never a silent no-op on a novice's click.

### 2.3 Behavior with vs. without a running server

Both new checkboxes never depend on a server - the tray reads/writes
`settings.json` directly today and this design keeps that contract exactly.
Only Uninstall optionally contacts the server, per 2.2's steps 1-3.

-------------------------------------------------------------------------
## 3. In-app Settings - final spec
-------------------------------------------------------------------------

### 3.1 Companion fix: "Start with Windows" tray/JSON drift (fix 4)

`MenuStartup_Click` (host\FurphyHost.cs, ~4640-4654) today calls
`StartupRegistry.Enable`/`Disable` directly against the registry and never
touches `settings.json`'s `runAtStartup` field - only the Settings screen's
own `/api/startup/register|unregister` handlers write that field
(addon-server.ps1:6594-6596, 6617-6619). Fix: `MenuStartup_Click` must also
call `HostFiles.UpdateJsonObject` to set `runAtStartup` to match, mirroring
the exact pattern `MainForm` already uses at its own two
`HostFiles.UpdateJsonObject` call sites (~1245, ~1471). This closes a
silent drift bug, not a user-visible one today (the Settings screen
self-corrects against the live registry on its next poll) - fix it
whenever this menu is touched for section 2's new items, same commit.

### 3.2 New Settings row: Uninstall

Slots into SETTINGS-SPEC.md's Group 8, **"Backup & troubleshooting"**
(SETTINGS-SPEC.md:347-427) exactly where that document's own catch-all
structure already implies it belongs: a new final cluster, after Row 18
Diagnostics, separated by the same thin divider style used between the
other clusters in this group, and still **inside** Group 8's bordered box -
the unboxed About footer line (429-457) stays after it, unchanged,
outside any box.

```
  -- divider --
Row 19
  key: n/a (action button, not a persisted setting)
  control: danger button, same visual weight as Row 17 "Force reinstall
       all", opens Components.Confirm (the existing promise-based
       UI.confirm() modal at app.js:2183-2199, reused verbatim - the same
       component "Force reinstall all addons?" already uses at
       6640-6654 - no new modal plumbing)
  label: "Uninstall Furphy Addon Manager"
  tooltip (Components.Tooltip, same component/shape as every other row
       this round): "Removes Furphy's program files from this PC. Your
       addons and your saved addon list are kept - reinstalling picks up
       right where you left off."
  confirm dialog title: "Uninstall Furphy Addon Manager?"
  confirm dialog message: "This removes Furphy's program files, its
       Start with Windows setting, and the CurseForge install-link
       handler. Your addons stay installed in WoW. Your addon list is
       kept at <appDest> so reinstalling brings it back."
  confirmLabel: "Uninstall", danger: true
  prior location: n/a (new)
```

Bottom-of-a-rarely-opened-Advanced-group placement is deliberate: the
single most destructive control on the whole screen sits in the least
accidentally-clickable spot.

### 3.3 Two asks that already exist - no new code

Two of Eric's three "from in the app" asks need **zero new work** - they
are already fully specified with tooltips this round:

- Disable the auto-update service in-app: SETTINGS-SPEC.md **Row 2**,
  "Update addons in the background" (Essentials > Updates).
- Disable startup in-app: SETTINGS-SPEC.md **Row 3**, "Start with Windows"
  (Essentials > Updates).

Recommend one line in whatever "what's new" surface ships this round
pointing at these two rows, rather than any code change - Eric may simply
not know they're already there.

### 3.4 New wiring

- `ui\app.js`: new action `Actions.uninstallApp` - **deliberately not**
  named `Actions.uninstall`, because that name (app.js:4413) and the
  per-addon "Uninstall" dropdown item (app.js:5333, `danger: true`)
  already exist and mean something unrelated (remove one addon). Keeping
  the whole-app action's name visibly distinct avoids ever confusing the
  two in code or in a future grep. On confirm: `POST /api/uninstall`. On a
  409/busy response, render the existing toast/error pattern with:
  **"Furphy is updating an addon right now. Try again in a minute."** On
  success: render a plain final state, **"Furphy is uninstalling itself
  and will close shortly."** - no redirect; the window will receive its own
  WM_CLOSE moments later as part of the same mechanism (section 5.3), so
  nothing else needs to happen client-side.
- `addon-server.ps1`: new route `POST /api/uninstall`, handler
  `Handle-Uninstall`, shaped almost exactly like `Handle-Shutdown`
  (addon-server.ps1:6927-6939) - reuse its exact
  `$Script:CurrentJobByFlavour` busy-check loop, don't copy it a second
  time. Apply the same CSRF `Origin` header rule every other mutating
  route on this server already applies (matches `/api/shutdown`,
  `/api/settings`, `/api/startup/*` - reject any request whose `Origin`
  doesn't match this server's own origin). Steps:
  1. If any flavour has a job running, respond 409 with a plain-language
     body (`{"error":"Furphy is updating an addon right now. Try again in
     a minute."}`).
  2. Otherwise, copy `$appDest\install.ps1` to a fresh GUID-suffixed
     `%TEMP%` path.
  3. Launch that copy detached, hidden: `-WowPath "<resolved wowRoot>"
     -Uninstall` (no `-NoShortcuts`/`-NoProtocol` in production).
  4. Respond 200 `{"ok":true}` **first** (same "answer before tearing
     down" shape `Handle-Shutdown` already uses).
  5. Set `$Script:ShuttingDown = $true` right after responding - the
     existing main loop already polls this every ~2s and exits, freeing
     the port.
  No changes needed to `/api/settings`, `/api/tray/*`, or `/api/startup/*` -
  already correct and already specified for Rows 2/3.

-------------------------------------------------------------------------
## 4. (folded into sections 2, 3, 5 above/below - kept as a pointer)
-------------------------------------------------------------------------

Eric's four asks map as: tray uninstall -> section 2.2; tray disable-both
-> section 2.1 + existing Rows 2/3; in-app disable-both -> section 3.3
(already shipped); in-app uninstall -> section 3.2/3.4; outside-the-app
uninstall -> section 5.4 (Installed-Apps); distribution -> section 6.

-------------------------------------------------------------------------
## 5. Uninstall mechanism, end to end
-------------------------------------------------------------------------

### 5.1 BLOCKING PREREQUISITE: the Run-value scoping bug (fix 1)

`install.ps1`'s `-Uninstall` path (lines 289-300) removes
`HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\FurphyAddonManager`
unconditionally - no `-WowPath` check, no scratch-run check - unlike the
Desktop-shortcut removal a few lines later, which already learned this
exact lesson (`Test-LooksLikeScratchRun`, install.ps1:78-91, added after
the earlier CS-F5 incident) and checks it before touching anything. This
already fired for real during this round's own research (section 0 above).

**Fix (either is acceptable, pick one and apply it consistently to every
registry write/removal in this file from here on):**

- **(a) Port-scoped name** (preferred - matches
  `addon-server.ps1`'s own `Get-StartupValueName`, 6398-6411): compute the
  Run-value name from the target install's own `settings.json` port -
  production port maps to the literal `FurphyAddonManager`, any other
  port maps to a `.Test`-suffixed name that can never collide with the
  real one. This also sidesteps needing path-based scratch detection at
  all for this specific value.
- **(b) `Test-LooksLikeScratchRun` gate** (simpler, matches the existing
  shortcut-removal precedent exactly): only attempt the removal if this
  check returns false is backwards - actually gate it so the removal is
  attempted **only when NOT a scratch run**, mirroring how the shortcut
  block already guards itself. (Restated precisely: wrap the
  `Remove-ItemProperty` call in `if (-not (Test-LooksLikeScratchRun ...))`.)

Apply whichever is chosen to the new Installed-Apps key removal too
(section 5.4) from its first commit - not after a second incident.

**Verification method that never risks the real key (see section 8's test
plan):** unit-test the value-name/guard **computation** in isolation
(call the function with a handful of fake ports/paths and assert the
returned name or boolean), rather than exercising the real
`Remove-ItemProperty` call against anything that could resolve to the
literal production name.

### 5.2 HARD BLOCKER: install.ps1 must ship itself (fix 2)

`$codeFiles` (install.ps1:494) today is `addon-sync.ps1, addon-server.ps1,
Addon Manager.vbs, curseforge-handler.vbs, register-protocol.ps1,
README.txt, CHANGELOG.md, icon.ico` - `install.ps1` is not in that list.
A running install therefore has no uninstaller inside it at all; the only
copy that exists lives wherever the zip was originally extracted, which a
normal user deletes. **Add `install.ps1` to `$codeFiles`.** Nothing in this
section works without this.

### 5.3 The mechanism itself (identical end state for every trigger)

Applies to all three trigger surfaces - tray menu (2.2), Settings Row 19
(3.2/3.4), and Windows' own Installed Apps entry (5.4) - meaning the same
*sequence of steps and end state*, the way this codebase already treats
the `computeCoreText`/`ComputeCore` JS/C# pair (ui\app.js:6082-6090): not
literally shared code across PowerShell/C#/JS (the project has never done
that), but one converging design.

**INVARIANT (fix 5, state this once and enforce it everywhere below): "No
server reachable on this install's own configured port implies no sync job
can be in progress for it."** A sync job only exists inside a live
`addon-server.ps1` process; if nothing answers on that port, no such
process is running, so no job can be in progress. This is what lets a
trigger with no live app to ask (Installed-Apps' `UninstallString`, and the
tray's fallback branch) skip an explicit busy-check and proceed safely,
while a trigger that DOES have a live server to ask (Settings' `POST
/api/uninstall`, and the tray's server-reachable branch) gets an
authoritative, in-memory, zero-race answer from that server instead.
Concretely:

- **Settings button** -> `POST /api/uninstall` -> `Handle-Uninstall`
  checks `$Script:CurrentJobByFlavour` directly (in-process, instant,
  authoritative) -> spawns the temp copy -> responds -> shuts down.
- **Tray, server reachable** -> same `POST /api/uninstall` path as above
  (section 2.2 steps 1-2) -> identical authoritative check.
- **Tray, server unreachable** -> per the invariant, safe to proceed ->
  local `File.Copy` + `Process.Start` of the temp copy (section 2.2 step
  3) -> **no additional busy-check needed or performed here**.
- **Installed-Apps `UninstallString`** -> a one-liner PowerShell command
  with **no interactive caller at all** -> same invariant applies -> it
  proceeds straight to the copy+launch step (section 5.4) with no
  busy-check of its own.

Because every path that has no live server to ask relies on the invariant
rather than re-implementing a check, **the busy-check exists in exactly
one place** (`Handle-Uninstall`'s in-memory loop) - there is nothing to
keep in sync across three copies.

**What runs inside the spawned temp copy of `install.ps1 -Uninstall`
itself** (this is where fix 9's single WM_CLOSE implementation lives - do
not add a second one in `host\FurphyHost.cs`):

1. Remove the Run value - **now correctly scoped per 5.1**.
2. Best-effort signal the tray to stop: the existing
   `EventWaitHandle.OpenExisting("FurphyAddonManager.TrayStop").Set()`
   pattern `Handle-TrayStop` already uses (addon-server.ps1:6564-6573) -
   ignore failure (no tray running).
3. **NEW, single implementation:** best-effort ask any open MAIN WINDOW to
   close too. Add a small `Add-Type` P/Invoke block to `install.ps1`
   itself (the exact idiom this codebase already uses for
   `Set-FurphyLowPriority` in the `.ps1` files, per the comment at
   host\FurphyHost.cs:3817-3822 - not a new pattern, just a new call
   site) that does `FindWindow` by the exact title
   `AppConstants.WindowTitleFor(port)` computes
   (host\FurphyHost.cs:216-234), then `PostMessage(hwnd, WM_CLOSE, 0, 0)`.
   Run this **before** the existing 10-second `FurphyHost` process-wait
   loop (install.ps1:313-335), so that loop has something proactive to do
   besides wait and warn.
4. Unregister `curseforge://` (unless `-NoProtocol`).
5. Remove the Desktop shortcut (gated by `-NoShortcuts` AND
   `Test-LooksLikeScratchRun`, unchanged).
6. Remove any stale per-flavour launcher-pair file left behind by a
   pre-Round-34 install, from every known flavour folder - legacy-file
   cleanup only as of Round 34, 2026-09-07 (`install.ps1` no longer
   writes these at all; see CHANGELOG.md). This same cleanup step now
   also runs unconditionally on a plain install/upgrade, not only
   `-Uninstall` - see `SPEC.md`'s own install.ps1 section (CS-R12).
7. Remove everything in `$appDest` except the existing keep-list
   (unchanged - see "what's kept" below).
8. Remove the Installed-Apps registry key (section 5.4), **scoped the
   same way as step 1, from day one.**
9. Print a plain-language summary; exit 0 even with warnings (see
   "failure handling" below).

**What's removed:** `ui\`, `host\` (including the compiled
`host\bin\FurphyHost.exe`), every `.ps1`/`.vbs` code file, `VERSION`,
`icon.ico`, `README.txt`, `CHANGELOG.md`, the Installed-Apps registry key,
the (now-correctly-scoped) Run value, and - unless `-NoShortcuts`/
`-NoProtocol` - the desktop shortcut and the `curseforge://` registration.

**What's kept (unchanged from today, no scorched-earth option this
round):** `addons.json`, `settings.json`, `state.json`, `sync.log`,
`server.log`, `last-run.txt`, `server.pid`, and the `jobs\`/`backups\`/
`cache\`/`staging\`/`flavours\` directories (`flavours\<id>\` holds every
installed flavour's own addon list and backups). Rationale: matches how
every other destructive action in this app already works (Force reinstall
all, Delete untracked each get their own separate, narrower confirm) -
"uninstall the app" should not silently also mean "and wipe your data" in
the same click. A future explicit "Also delete my saved addon list and
settings" checkbox inside the same confirm dialog, off by default, is a
reasonable later addition - not this round.

**Failure handling / novice-visible messages** (confirmed live against a
scratch fixture with a real tray+server running - the realistic case, not
a clean-shutdown best case):

- Failures accumulate rather than aborting the run - one locked file never
  leaves a half-removed app.
- `host\bin\FurphyHost.exe` can block deletion for up to 10 seconds
  (WinForms/WebView2 teardown can be slow) - the script warns and
  continues; `.ps1` files delete fine even while actively running
  (PowerShell holds no lock on a script it is interpreting). Re-running
  `-Uninstall` a second time, once the process has actually exited,
  cleanly finishes with zero warnings.
- Console output stays plain-language throughout: `Removed "Start with
  Windows" registration.`, `WARNING: Could not remove folder (in use?):
  host`, `Your addon list, settings and logs are still there: <path>`,
  `Uninstall completed with warnings.` - exit code 0 even with warnings,
  so a novice never sees a scary red PowerShell exception.
- Optional, cheap: drop a short plain-text note into the leftover
  `$appDest` folder at the end of `-Uninstall`: **"Furphy's addon list and
  settings are kept here. Safe to delete by hand if you don't plan to
  reinstall."** - one extra `Set-Content` line, explains the otherwise
  unlabeled leftover folder to a novice who goes looking.

### 5.4 Installed-Apps registration (does not exist today - confirmed by grep)

Write, **at install time** (and re-write on every upgrade), a per-user key
at `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\
FurphyAddonManager` (HKCU only - never HKLM, consistent with everything
else `install.ps1` already does, no admin needed) with:

- `DisplayName` = "Furphy Addon Manager"
- `DisplayVersion` = from `VERSION`
- `Publisher` = (project's chosen publisher string)
- `InstallLocation` = `$appDest`
- `DisplayIcon` = `$appDest\icon.ico`
- `EstimatedSize` (DWORD, KB)
- `NoModify` = 1 (DWORD), `NoRepair` = 1 (DWORD) - no modify/repair concept
  exists here
- `UninstallString` and `QuietUninstallString`, both set to a one-line
  command implementing the "try the server, else copy+launch" logic from
  section 5.3's invariant, e.g. (exact quoting needs verification during
  implementation, see section 8):

  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "try { Invoke-RestMethod -Method Post -Uri 'http://localhost:<port>/api/uninstall' -TimeoutSec 2 -Headers @{Origin='http://localhost:<port>'} } catch { $t = Join-Path $env:TEMP ('FurphyUninstall-' + [guid]::NewGuid() + '.ps1'); Copy-Item '<appDest>\install.ps1' $t; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$t,'-WowPath','<wowRoot>','-Uninstall' }"
  ```

  This makes Windows' own Settings > Apps entry a **third** caller of the
  identical converging mechanism - not a special case - since a user could
  have Furphy's window or tray open the moment they click Uninstall from
  Windows' own list, so it gets the same best-effort teardown as the other
  two triggers via the same invariant.

This key must be **removed** (`Remove-Item -Recurse`) in the `-Uninstall`
path too (5.3 step 8), carrying the **same** scoping guard as the Run value
from the day it is first written (fix 3) - not bolted on after a second
incident.

Mechanically verified feasible this round: the exact field set above was
round-tripped (written, read, deleted) against an isolated test registry
key, confirming Settings > Apps will render it correctly.

-------------------------------------------------------------------------
## 6. Distribution
-------------------------------------------------------------------------

### 6.1 Chosen path

Keep the existing distribution artifact - zip + `Install Furphy.cmd` ->
`install.ps1` - with the same MOTW/SmartScreen profile
DISTRIBUTION-RESEARCH.md already verified. Do **not** wrap it in a
compiled EXE this round (section 6.7 explains why in full). Give
`install.ps1` an **optional WinForms front end**, built with the exact
same `Add-Type -AssemblyName System.Windows.Forms/System.Drawing`
mechanism `host\build-host.ps1` already proves works with zero extra
tooling on a real end-user machine (confirmed live during this round's own
install test: "C# compiler found - building the native host..."). Since
this stays a script run by `powershell.exe` - not a new signed/unsigned
binary - it inherits today's mild-or-absent warning profile, never the
SmartScreen wall.

### 6.2 Novice click sequence (final)

1. Land on a new GitHub Pages landing page (6.5) instead of the bare repo
   file list or the Releases page.
2. Click one big **Download Furphy Addon Manager** button -> downloads the
   newest zip via a stable, unversioned link (6.6).
3. Right-click the zip -> **Extract All...** -> Extract (Explorer's real
   wizard - propagates MOTW, confirmed live; `Expand-Archive` does not,
   also confirmed live, so some novices following different "how to unzip"
   advice may see no prompt at all either way).
4. Open the extracted folder, double-click **Install Furphy.cmd**.
5. Windows may show the mild **"Open File - Security Warning"** box
   (Run/Cancel, Unknown Publisher) - click **Run**. (Never the scary
   full-screen SmartScreen block - that only applies to a compiled EXE,
   see 6.7.)
6. **One small window opens:** "Furphy found World of Warcraft in
   `<path>`" with a single **Install** button - or, if not found, a
   folder picker, with the same one button once a folder is chosen.
7. A progress bar while it copies files and builds the native host.
8. A success screen: "Furphy Addon Manager is installed." with one
   button, **Open Furphy Addon Manager**, plus one reassurance line:
   "Nothing in your AddOns folder was touched." (Round 34, 2026-09-07:
   this screen originally also specced a second **Launch WoW (auto-update
   addons)** button - removed at Eric's request before it ever shipped,
   along with every other launch-WoW feature; see CHANGELOG.md.)

**Fallback (mandatory, not optional):** if the WinForms Form fails to
construct for any reason (old machine, unusual DPI, non-interactive/CI
run), `install.ps1` falls straight through to the existing, already-tested
console-only flow, unchanged. This must never become a second, competing
failure mode on top of a working installer.

**Console-window handling (fix 6, resolves the tension between "hide the
console so there's only one window" and "the console IS the fallback
safety net"):** at the very start of `install.ps1`, before any console
output, wrap the Form construction in try/catch:

- **On success:** hide the console window with a small `Add-Type`
  P/Invoke (`GetConsoleWindow` + `ShowWindow(hwnd, SW_HIDE)` - same idiom
  class already used for `Set-FurphyLowPriority`), then drive the rest of
  the install from inside the Form. All further `Write-Host` calls become
  effectively silent (redirect their content into the Form's own progress
  label instead) since nobody is watching the hidden console.
- **On failure (any exception constructing the Form):** never hide the
  console. Skip straight to the existing, unmodified console flow. The
  tested safety net stays fully visible exactly as it is today.

**Progress-reporting mechanism (fix 6, pick one, do not leave it
unstated):** because `install.ps1` runs its install steps synchronously
top to bottom, the WinForms message loop would otherwise freeze while a
step (like compiling the native host) runs. **Chosen mechanism: periodic
`[System.Windows.Forms.Application]::DoEvents()` calls** between and
during install steps (update the progress label/bar, then `DoEvents()`,
then continue) - this keeps the existing single-threaded, dependency-free
script shape (no new runspace/background-job machinery, consistent with
this project's "fewest moving parts" reuse of existing idioms) at the cost
of a brief, few-second UI freeze during the one genuinely slow step (the
C# compile). If that freeze draws support complaints after ship, the
documented upgrade path is a background runspace + a `System.Windows.
Forms.Timer` polling job state - not required for this round.

**Must test at a non-100%-DPI Windows scaling setting** (e.g. 125% or
150%) before shipping - WinForms layouts drawn without care can clip or
overlap at non-default DPI.

### 6.3 What we build

1. **Installed-Apps registry entry** (section 5.4) - shared plumbing with
   the uninstall mechanism, not a separate distribution feature. Single
   highest-value change for Eric's broader ask: a real Settings > Apps
   entry with a working Uninstall button, for free.
2. **`install.ps1`'s WinForms wizard** (6.2) wrapping the existing,
   already-correct install logic - only how progress/success is
   *presented* changes; the underlying file-system steps are unchanged.
3. **A static `index.html` for GitHub Pages** (6.5) - no build step, no
   framework, no server.
4. **A `package.ps1` tweak** (6.6) attaching a second, unversioned-named
   zip to every release so the landing page's link never goes stale.

### 6.4 SmartScreen / security-prompt handling text (fix 10)

One sentence, used **identically, verbatim**, on the landing page, the
README, and anywhere else this needs explaining - grafted from Designer
A's more direct phrasing per the judge's required fix:

> "Windows may show a small 'Open File - Security Warning' box the first
> time you run Install Furphy.cmd, since it isn't signed with a paid
> certificate yet - click Run. Furphy only writes inside your WoW folder
> and never asks for admin access."

This states plainly that the install isn't signed (not merely "may show a
prompt"), while still not needing to use the words "SmartScreen",
"unsigned", or "Unknown Publisher" on the novice-facing landing page
itself (that vocabulary is fine in the README's more technical section,
where it already appears today via the underlying facts, not the words).
Keep the wording hedged ("may show", not "will show") - MOTW propagation
is genuinely extraction-tool-dependent (confirmed: Explorer's Extract All
propagates it, `Expand-Archive` does not), so an unconditional "will show"
would overstate what was actually verified.

### 6.5 GitHub Pages landing page

Not enabled on this repo today (`has_pages: false`, confirmed via
`gh api`). Enabling it is a one-time repo-settings action (Settings >
Pages > Deploy from branch, or one `gh api` PUT).

```
H1: "Furphy Addon Manager"
Subhead: "Automatic WoW addon updates. No account, no API key, nothing to
configure."
[Download for Windows]  <- big button, links to the stable "latest" asset (6.6)

Three numbered steps, each with a screenshot:
  1. "Download the zip and right-click it -> Extract All."
  2. "Open the extracted folder and double-click Install Furphy.cmd."
  3. "Click Install in the window that opens - Furphy finds your WoW
      folder automatically."

Footnote: the exact sentence from section 6.4.
Footnote: link to the GitHub repo for anyone who wants to read the source
first.
Footnote: "Uninstalling: right-click the tray icon, or Settings inside
Furphy, or Windows Settings > Apps - your addons always stay in WoW
either way."
```

**Fix 7 - mandatory pre-publish step, not optional:** before this page (or
any screenshot on it) goes live, scrub every piece of copy and every
screenshot for anything from this round's own scratch/test environment -
fixture paths (`scratch-wowroot`, `fixtures\wowroot`), the test port
(47899), decoy files (`decoy\Install Furphy.cmd`), or any window title
showing a non-production port. Add this as a standing line item in the
acceptance checklist (section 9) for every future landing-page update,
not a one-time fix.

### 6.6 Release asset naming and the catch-up release (fix 8)

- Keep the existing versioned name, `FurphyAddonManager-<ver>.zip`, as the
  canonical, permanent artifact for that release.
- Add `FurphyAddonManager-latest.zip` as a second, identically-named-every-
  release asset, so GitHub's own
  `/releases/latest/download/FurphyAddonManager-latest.zip` link (used by
  the landing page and README) never goes stale - GitHub's stable-link
  mechanism only works when the asset filename never changes.
- Make attaching this second asset a **permanent, enforced** step, not a
  one-off: add it to `package.ps1`'s own release-assembly logic so it
  cannot be silently skipped on a future release, and print a reminder
  line in `package.ps1`'s console output either way until that's done.
- Separately, one-time housekeeping: the public repo's Releases page
  currently stops at v1.1.0 while local `dist\`/`VERSION` sit at 1.13.0 -
  **publish a catch-up release matching the current build before pointing
  any new landing page at "latest"**, or the button will download a
  version many releases behind.

### 6.7 Explicitly deferred, and why (not built this round)

- **No compiled installer EXE** (IExpress, 7-Zip SFX, or a hand-built
  WinForms `.exe`), unsigned. Today's `.cmd`/`.ps1` path shows either no
  warning at all (MOTW doesn't survive `Expand-Archive`) or, worst case,
  the mild "Open File - Security Warning" (one click, never seen again for
  that file). An **unsigned** EXE is strictly worse: Windows Defender
  SmartScreen's app-reputation check shows the full-screen "Windows
  protected your PC" block, requiring "More info" -> "Run anyway" - a
  scarier, two-step interaction for exactly the audience this round is
  written for. **IExpress's own headless SED build (`/N /Q` and
  `/N /Q:U`) was inconclusive in this round's testing - it did not
  complete within a bounded wait, not "doesn't work"** - a clean, idle-
  machine re-test is still worth doing before anyone relies on IExpress
  for a reproducible/CI build, independent of the signing question. 7-Zip
  was not installed on the research machine and its SFX was never tested
  at all.
- **No code signing this round.** Comparison for Eric's later decision:

  | Option | Cost | What it actually removes |
  |---|---|---|
  | Azure Trusted Signing | ~$10/mo | **Instant** SmartScreen reputation - the only option here that doesn't need to be earned gradually by download volume. Needs an Azure account + identity verification. |
  | SignPath.io | free (OSS-gated) | Removes "Unknown Publisher"; reputation still builds gradually. Requires an application/review, and expects signing inside a CI pipeline - this project currently builds releases locally via `package.ps1`, so adopting this also means standing up CI. |
  | Certum Open Source Code Signing | ~$25-40/yr | Same gradual-reputation profile as SignPath, cheaper up front, doesn't fix the SmartScreen wall on day one. |

  None of this is worth standing up unless the project separately decides
  a true single-double-click, no-console, no-warning experience is worth
  paying for. Name Azure Trusted Signing as the concrete fallback if that
  becomes the ask.
- **No winget/MSIX/MSI.** winget still requires opening a terminal (same
  friction class as a PowerShell one-liner); MSIX/MSI both expect a signed
  package to dodge the same SmartScreen wall. All three are downstream of
  the EXE+signing work just declined above, not independent wins.
- A genuine side-benefit of staying script-based: the only `.exe` that
  ever exists on the user's machine (`host\bin\FurphyHost.exe`) is
  compiled **locally, on their own PC**, via `Add-Type`/csc during
  `install.ps1`'s run - it is never downloaded and never executed as a
  fetched binary, so it never enters SmartScreen's reputation system at
  all. Shipping a downloaded installer EXE would be the first time this
  project ever put a downloaded, executed binary in front of Windows' app-
  reputation check.

### 6.8 README additions

- The exact section 6.4 sentence, next to the existing "Unzip it anywhere,
  then run Install Furphy.cmd" line.
- 2-3 lines noting the installer now opens a small window instead of only
  console text (with the console-fallback behavior mentioned honestly:
  "on some machines you may still see the console instead - that's fine,
  it does the same thing").
- An "Advanced users" one-liner naming the `irm <url>/install.ps1 | iex`
  alternative - explicitly **not** the primary path (requires already
  knowing how to open PowerShell, is opaque to read, and skips the one
  clear signal a novice gets today: the readable console log). This
  advanced path bypasses PowerShell's execution-policy check entirely
  (`iex` runs in-session, not as a file, so the policy gate that blocks
  unsigned downloaded `.ps1` files never applies to it) - worth mentioning
  in the README's advanced section since it is a real difference, not
  worth explaining to the primary audience.
- An "Uninstalling" section naming all three now-available paths:
  Settings > Uninstall Furphy Addon Manager (Backup & troubleshooting),
  right-click the tray icon > Uninstall Furphy Addon Manager..., or
  Windows Settings > Apps > Furphy Addon Manager > Uninstall.

-------------------------------------------------------------------------
## 7. Change sets by file
-------------------------------------------------------------------------

Ordered by dependency - items 1-2 in `install.ps1` are hard prerequisites
for everything else and must land, alone, first.

### install.ps1 (largest change set)

1. **(fix 1, do first, alone)** Scope the Run-value removal (~289-300) -
   see section 5.1. ~30-60 min plus isolated unit-test verification.
2. **(fix 2, hard blocker)** Add `install.ps1` to `$codeFiles` (~494).
   ~10 min.
3. Write the Installed-Apps registry key on install/upgrade; remove it
   (scoped per fix 1's chosen method, from day one - fix 3) in
   `-Uninstall`. ~half a day incl. install/upgrade/uninstall testing.
4. Add the WM_CLOSE-by-title `Add-Type` P/Invoke step to the existing
   10-second wait loop (~313-335), run before that loop starts waiting.
   ~2-3 hrs. **This is the only WM_CLOSE implementation in the whole
   project (fix 9) - do not duplicate it in `host\FurphyHost.cs`.**
5. Add the shared self-uninstall sequence from section 5.3 (steps 1-9),
   invoked whenever `-Uninstall` runs, regardless of who spawned this
   particular copy.
6. Add the WinForms install wizard (`Show-InstallWizard`: detect/browse
   WoW folder, one Install button, `DoEvents`-pumped progress, success
   screen with one Open Furphy Addon Manager button - see 6.2 above for
   why there is no second, Launch-WoW button here), wrapping the existing
   install logic unchanged. Must catch any Form-construction failure and
   fall through to the existing console path untouched (section 6.2).
   Hide the console only after successful construction (fix 6). ~1-1.5
   days incl. testing at a non-100%-DPI setting.
7. Optional/cheap: the "safe to delete" leftover-folder note at the end of
   `-Uninstall` (section 5.3).

### addon-server.ps1

- New `Handle-Uninstall` + `POST /api/uninstall` route (section 3.4):
  reuse `Handle-Shutdown`'s exact busy-check loop, answer 200 first, then
  spawn the temp copy and set `$Script:ShuttingDown = $true`. Apply the
  same `Origin`-header CSRF rule every other mutating route already
  applies. ~2-3 hrs.

### host\FurphyHost.cs

**Being edited live by another workflow this round - re-derive these
anchors against a fresh read before implementing; every line number below
is approximate.**

- `BuildContextMenu`: insert "Update addons in the background" checkbox
  between "Start with Windows" and the following separator; insert
  "Uninstall Furphy Addon Manager..." above "Quit", its own separators
  (section 2).
- New click handler for the background-updates checkbox: direct
  `settings.json` write + conditional immediate `_stopEvent.Set()` +
  one-time balloon on turn-off (section 2.1). ~2-3 hrs.
- New click handler for Uninstall: `MessageBox.Show` (Yes/No, No default)
  with the section 2.2 copy; on Yes, the **thin** try-server-else-copy-
  launch logic from section 2.2 (no WM_CLOSE code here - fix 9), then the
  tray's own `_stopEvent.Set()`. ~half a day.
- Companion fix: `MenuStartup_Click` also writes `runAtStartup` into
  `settings.json` (section 3.1). ~30 min.
- Optional/cheap: bind the new Uninstall item's `Enabled` to the same
  boolean already computed for graying out "Check for updates now".

### ui\app.js + ui\index.html

**Also being edited live this round - same caveat as above.**

- New `Actions.uninstallApp` (section 3.4), wired to Settings' Row 19
  button: `UI.confirm()` reused verbatim with the section 3.2 copy ->
  `POST /api/uninstall` -> render the section 3.4 success/busy states, no
  client-side redirect needed.
- Render Row 19 in Settings' Group 8, after Row 18, before the About
  footer line, per section 3.2 and SETTINGS-SPEC.md's existing wording
  rules (danger button, same weight as Row 17, `Components.Tooltip` per
  the shared component spec). ~2-3 hrs combined.

### package.ps1 (or wherever release assembly lives)

- Attach the second, unversioned `FurphyAddonManager-latest.zip` to every
  GitHub Release alongside the existing versioned zip, as a permanent,
  enforced step (fix 8, section 6.6). <1 hr, plus a standing checklist
  line.

### New static page for GitHub Pages

- `docs/index.html` (or repo root, whichever this repo's Pages source
  setting expects) - static HTML per section 6.5, no build step, no JS
  framework. ~2-4 hrs, plus the one-time repo setting and the one-time
  catch-up release (section 6.6).

### README.md / README.txt

- Section 6.4's exact sentence, the "Advanced users" one-liner, and the
  "Uninstalling" section (section 6.8). <1 hr.

-------------------------------------------------------------------------
## 8. Test plan (scratch-root only - restated rules, no exceptions)
-------------------------------------------------------------------------

This entire round is **read-only for the build root and the repo** -
another workflow is editing `ui\` and `host\FurphyHost.cs` live. Every
test below runs against a **scratch copy** of `fixtures\wowroot`, never the
standing fixture and never the real WoW folder, using
`install.ps1 -WowPath <scratch copy> -NoShortcuts -NoProtocol`.

**Never, under any circumstance, in any test of this spec:**
- Touch `C:\Program Files` or the real Battle.net-installed WoW folder.
- Touch the real Desktop (`-NoShortcuts` stays set for every test this
  round - live shortcut creation/removal on the real Desktop cannot be
  safely exercised in this environment; treat that code path as
  code-reviewed, not live-tested, this round, and flag it to Eric as a
  manual pre-release check).
- Touch `HKCU\Software\Classes\curseforge` (`-NoProtocol` stays set).
- Touch the real production `HKCU\...\Run\FurphyAddonManager` value or the
  real `HKCU\...\Uninstall\FurphyAddonManager` key - test the fix 1/fix 3
  scoping logic by **unit-testing the name-computation function in
  isolation** (assert the returned value-name/guard result for a handful
  of fake ports and paths), not by exercising the real removal call
  against anything that could resolve to the production name.
- Touch port 47831, the live tray, or the live main window. Use a distinct
  scratch test port (e.g. 47899, matching this round's own research
  convention) for every scratch `addon-server.ps1`/`FurphyHost.exe --tray`
  spun up during testing, and make sure the scratch install's own
  `settings.json` points at that scratch port - this is also what makes
  the section 5.3 "server reachable" test path exercisable without any
  chance of hitting the real server.
- Launch the real WoW client.

**What to actually run, in dependency order:**

1. Unit-test the fix 1 name-computation logic (isolated, no registry
   writes) across: production-looking port + scratch-looking path,
   scratch port + scratch path, production port + production-looking
   path (to confirm the "would use the real name" branch is reachable in
   principle, without actually calling it against anything real).
2. Scratch install with `-NoShortcuts -NoProtocol`, then a scratch
   `-Uninstall` with **no** tray/server running - confirm clean removal,
   confirm the scoped Run-value/Installed-Apps logic touched only a
   `.Test`-suffixed or otherwise clearly-scratch name (verify by reading
   back what name was actually used, not by inspecting the real
   production value).
3. Same, but with a scratch tray AND a scratch `addon-server.ps1` (both on
   the scratch test port) actually running first - reproduce the
   "in-use `host\bin\FurphyHost.exe`" warning path from
   LIFECYCLE-RESEARCH.md's own live test, confirm warnings accumulate
   (exit 0, not a crash), confirm a second `-Uninstall` run afterward
   finishes clean.
4. With the scratch server running, exercise the section 5.3
   "server-reachable" path end to end: `POST /api/uninstall` against the
   scratch port -> confirm `Handle-Uninstall`'s busy-check against a
   synthetic in-progress job (fake `$Script:CurrentJobByFlavour` entry)
   correctly returns 409 with the plain-language body, then confirm it
   correctly proceeds and spawns the temp copy once no job is set.
5. With the scratch server **not** running (stopped), exercise the
   "server-unreachable, invariant applies" path: confirm the tray's
   fallback branch (or a scripted stand-in for it during scratch testing)
   proceeds straight to copy+launch with no hang waiting for a response
   that will never come (the ~1.5-2s timeout must actually fire).
6. Exercise the WoW-not-found case (install.ps1's existing exit-2 path)
   both through the console flow and through the new WinForms wizard's
   folder-picker fallback.
7. Construct the WinForms wizard successfully once, and force a Form-
   construction failure once (e.g. temporarily break the `Add-Type` call
   in a throwaway copy) to confirm the console fallback actually engages
   and produces the same, already-tested console output.
8. Test the wizard at a non-100%-DPI scaling setting (125% or 150%) for
   layout clipping/overlap.
9. Confirm the balloon text fires exactly once when "Update addons in the
   background" is toggled off via the tray, on a scratch tray instance.
10. Before publishing the landing page for real: read through every word
    of copy and every screenshot specifically hunting for scratch
    artifacts (fixture paths, port 47899, decoy filenames, any window
    title showing a non-production port) - this is fix 7, and it is a
    manual read-through, not something a script can fully verify.

-------------------------------------------------------------------------
## 9. Acceptance checklist + screenshots to capture
-------------------------------------------------------------------------

**Functional:**
- [ ] Fix 1 (Run-value scoping) verified via isolated unit test, landed
      and reviewed before anything else in this list is tested.
- [ ] Fix 2 (`install.ps1` in `$codeFiles`) verified: a scratch-installed
      copy's own folder actually contains `install.ps1`.
- [ ] Fix 3 (Installed-Apps key removal scoped from day one) verified the
      same way as fix 1.
- [ ] Fix 4 (`MenuStartup_Click` writes `runAtStartup`) verified: toggling
      "Start with Windows" from the tray, then reading `settings.json`,
      shows the field matches the registry state.
- [ ] Fix 5 invariant exercised both ways (section 8, steps 4-5): busy
      correctly refuses; unreachable correctly proceeds without hanging.
- [ ] Fix 6: WinForms wizard tested at non-100% DPI; console-fallback path
      verified by forcing a Form-construction failure.
- [ ] Fix 7: landing page copy/screenshots scrubbed of scratch artifacts
      immediately before publish (standing item, re-check every future
      landing-page edit too).
- [ ] Fix 8: `package.ps1` attaches `FurphyAddonManager-latest.zip` on a
      test release run; catch-up release published before the landing
      page goes live pointing at "latest".
- [ ] Fix 9: confirm exactly one WM_CLOSE implementation exists in the
      codebase (grep for `WM_CLOSE`/`PostMessage` - should match only
      inside `install.ps1`, never in `host\FurphyHost.cs`).
- [ ] Fix 10: the section 6.4 sentence appears verbatim on the landing
      page and in the README.
- [ ] Tray "Update addons in the background" checkbox: state persists
      correctly, icon disappears on turn-off, balloon fires once.
- [ ] Tray "Uninstall Furphy Addon Manager...": No-default confirmed,
      busy case shows the plain-language MessageBox, success path exits
      the tray cleanly.
- [ ] Settings Row 19: renders in Group 8 after Diagnostics, before the
      About footer; confirm dialog text matches section 3.2 exactly;
      busy/success states match section 3.4.
- [ ] Windows Settings > Apps shows "Furphy Addon Manager" with a working
      Uninstall entry, on a scratch-registered test key only.
- [ ] Post-uninstall leftover folder contains the optional explanatory
      note (if implemented).
- [ ] Eric has been told about the section 0 "check your real Start with
      Windows setting" item, independent of ship status.

**Screenshots to capture (all from scratch fixtures, never the real
install - and re-check against fix 7 before any of these reach a public
page):**
- [ ] The new tray menu, both checkboxes in their "on" state.
- [ ] The tray's Uninstall confirm `MessageBox` (No highlighted).
- [ ] The tray's busy-refusal `MessageBox`.
- [ ] Settings Group 8 showing Row 19 in place, light and dark.
- [ ] The Row 19 confirm dialog (`Components.Confirm`).
- [ ] The WinForms install wizard: WoW-found screen, folder-picker
      fallback screen, progress screen, success screen.
- [ ] The existing console fallback flow (for the README/advanced docs).
- [ ] Windows Settings > Apps showing the Furphy entry (from a scratch-
      registered test key, or annotated as a mockup if a real capture
      isn't safe to take this round).
- [ ] The final landing page, desktop width.

-------------------------------------------------------------------------
## 10. Open items for Eric to decide later (not this round)
-------------------------------------------------------------------------

1. Whether a true single-double-click, no-console, no-warning installer
   is worth paying for - if so, Azure Trusted Signing (~$10/mo) is the
   concrete next step (section 6.7).
2. Whether a future "Also delete my saved addon list and settings"
   scorched-earth checkbox belongs inside the uninstall confirm dialog,
   off by default (section 5.3).
3. Whether the background-runspace+Timer upgrade to the install wizard's
   progress reporting is worth the added complexity, if the `DoEvents`
   freeze during the native-host compile draws support complaints
   (section 6.2).
