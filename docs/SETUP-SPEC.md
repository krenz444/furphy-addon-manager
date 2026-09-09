# SETUP-SPEC.md - One-file GUI installer for Furphy Addon Manager

Synthesized design, round 2026-09-08. Source: Eric's verbatim request ("the
install experience needs to be better, like gui, easy to use, no ps1 or cmd
files, download and install, easy"), the judge's decision between two
independent designs, and a fresh, line-by-line re-check of every cited file
against this build root's actual current content (install.ps1 is 2818 lines
today - noticeably longer than when some of the surrounding specs below were
written, so several of their own embedded line numbers have already drifted;
this document cites only numbers re-verified against the real files during
this pass).

Winning shape (judge, verbatim rationale): **FurphySetup.exe, a small
csc-compiled WinForms bootstrapper** that embeds the existing release zip,
extracts it to a per-run temp folder, and launches the existing,
unmodified `install.ps1` wizard hidden behind its own splash window.
`install.ps1` keeps 100% of the install logic (WoW detection, flavours,
adopt scan, protocol registration, tray, Add/Remove Programs). Grafted in
from the runner-up design: the browser's own separate download-safety
notice as its own journey step, a static regression test guarding against
FurphySetup.cs ever registering its own Add/Remove Programs entry, a dated
"first downloaded, executed binary this project has shipped" framing for
the DISTRIBUTION-SPEC.md reversal (with an explicit no-elevation/no-UAC
callout), and that design's honest "what this costs going forward" writing
style, applied to this design's own real costs.

-------------------------------------------------------------------------
## 1. Goals / non-goals
-------------------------------------------------------------------------

**Goals**

- One downloadable file. A player downloads exactly one thing and runs it;
  nothing named `.ps1` or `.cmd` is ever visible in Explorer, a browser's
  downloads list, or the Desktop during a normal install.
- No visible console window at any point of a normal (non-`/S`) install.
- The existing, already-tested install logic in `install.ps1` - WoW
  detection, flavour handling, adopt scan, `curseforge://` registration,
  tray, the Installed-Apps registry entry - is reused verbatim. Nothing
  about *what* an install does changes, only *how a player gets to it*.
- A silent, scriptable path (`/S`) that does exactly what today's
  `-Console -Quiet` already does, for admins and for this round's own
  automated tests.
- Zero new paid or third-party build-time dependency. The build machine
  needs nothing beyond what it already has (in-box PowerShell 5.1 and
  in-box `csc.exe`).
- Every per-install registry/event scoping rule already in `install.ps1`
  (production port 47831 vs. a test/scratch port, `Test-LooksLikeScratchRun`)
  keeps working unchanged - Setup.exe never bypasses it, never duplicates
  it, and never runs with elevated privileges.

**Non-goals (explicitly out of scope this round)**

- Rewriting any install logic in C#. FurphySetup.cs contains *zero*
  WoW-detection, copy, or registry code - see section 5.
- Code signing. Still "no" this round (DISTRIBUTION-SPEC.md 6.7's existing
  decision is knowingly overridden on the *distribution shape*, not on
  signing - see section 9).
- Changing anything about `-Upgrade`/`-Relaunch` (the self-updater's own
  fixed command line, APP-UPDATE-SPEC.md section 8.5-8.7) or `-Uninstall`.
  Both are untouched - see section 5's last subsection.
- An MSI/MSIX/winget package, or a third-party installer framework
  (Inno Setup, NSIS, WiX). DISTRIBUTION-SPEC.md 6.7 already declined these
  for the same signing-adjacent reasons that make an unsigned EXE the
  minimum viable shape here too; nothing in this round's evaluation found
  a decisive user-facing win large enough to justify the new dependency
  (see section 9's cost write-up).

-------------------------------------------------------------------------
## 2. Fixed decisions (verbatim, from the task brief)
-------------------------------------------------------------------------

> Deliver ONE downloadable file, FurphyAddonManager-Setup.exe (plus a
> versioned copy FurphyAddonManager-Setup-\<ver\>.exe), as the primary
> release asset with a stable link at
> releases/latest/download/FurphyAddonManager-Setup.exe; the zip stays as
> a secondary asset (the self-updater consumes it; power users may use
> it); no visible console, .cmd or .ps1 at any point of a normal install;
> the existing install.ps1 wizard logic (WoW detection, flavours, adopt
> scan, protocol registration, tray, Add/Remove Programs entry) is reused
> as the engine - do not rewrite it in C# unless a design proves it is
> required; a /S (silent) switch maps to install.ps1 -Console -Quiet; no
> code signing (decided; document the SmartScreen 'More info -> Run
> anyway' step with the exact on-screen text instead); no new paid or
> third-party build dependency unless a design shows a decisive
> user-facing win (a framework installer like Inno Setup or NSIS may be
> evaluated on that basis - it must be installable on this build machine
> unattended via winget and buildable from package.ps1); ASCII only in
> anything you write.

Every one of these is satisfied literally by the design in this document,
including `/S` mapping to *exactly* `install.ps1 -Console -Quiet` with zero
extra arguments (section 4.4 adds an *additive* pass-through affordance for
arguments placed after `/S`, which changes nothing about the zero-argument
case).

-------------------------------------------------------------------------
## 3. User journey - every screen and click
-------------------------------------------------------------------------

1. **Landing page.** Player opens `https://krenz444.github.io/furphy-addon-manager/`
   and clicks the one big button, now labeled **"Download Furphy Addon
   Manager"**, linking to
   `https://github.com/krenz444/furphy-addon-manager/releases/latest/download/FurphyAddonManager-Setup.exe`.
   No zip, no "Extract All" step, no `.cmd` at any point in this path.

2. **Browser's own download-safety notice (separate from, and before,
   anything Windows shows).** Most browsers flag a freshly-downloaded,
   low-reputation `.exe` on their own, before the file is ever run - e.g.
   Edge/Chrome's *"This file isn't commonly downloaded and could be
   dangerous"* banner in the downloads tray, with a **Keep** (or **Keep
   anyway**) choice. Exact wording varies by browser and version - unlike
   the SmartScreen text in step 4, this is not one fixed OS string, so the
   site/README copy hedges it the same way DISTRIBUTION-SPEC.md 6.4
   already hedges MOTW propagation ("may show", never "will show"). Worth
   flagging, not asserting as fact (this is a live browser-UI behavior,
   not something re-checkable against this codebase): some browser
   versions require a second click inside a nested overflow/"Actions"
   affordance to reach "Keep anyway" rather than one direct click, so the
   copy's "choose Keep/Keep anyway" wording should stay deliberately vague
   about the exact number of clicks, the same way it already stays vague
   about the exact text. The player dismisses it (Keep/Keep anyway) and
   opens the file from the browser's downloads tray or double-clicks it in
   Explorer.

3. **Windows SmartScreen (the real, fixed OS text - the two clicks).**
   First run of a freshly-downloaded, unrecognized `.exe` shows the full
   blue screen:

   > **Windows protected your PC**
   > Microsoft Defender SmartScreen prevented an unrecognized app from
   > starting. Running this app might put your PC at risk.
   > [More info]

   **Click 1 - "More info".** The box expands in place to show:

   > App: FurphyAddonManager-Setup.exe
   > Publisher: Unknown publisher
   > [Run anyway]   [Don't run]

   **Click 2 - "Run anyway".** This is the scarier, two-step interaction
   DISTRIBUTION-SPEC.md 6.7 originally weighed against and rejected
   (section 9 records why that reversal is now accepted, not refuted).
   Site/README copy for this step: *"Windows may show a blue 'Windows
   protected your PC' screen the first time you run
   FurphyAddonManager-Setup.exe, since it isn't signed with a paid
   certificate - click More info, then Run anyway. Furphy only writes
   inside your WoW folder and never asks for admin access, and Setup never
   needs you to click through a Windows admin (UAC) prompt either."*

4. **FurphySetup.exe's own splash window appears** - small, ~360x140,
   fixed size, titled "Furphy Addon Manager Setup", the app's own icon,
   text "Preparing Furphy Addon Manager Setup...", a moving (Marquee)
   progress bar. Visible for roughly a second while the embedded payload
   extracts to a temp folder and the wizard's own window is starting up
   behind it.

5. **The splash disappears, replaced by the existing install wizard**
   (unchanged, byte-for-byte the same window `Install Furphy.cmd` shows
   today): "Furphy found World of Warcraft in `<path>`" with a single
   **Install** button - or, if auto-detection failed, "Furphy could not
   find World of Warcraft automatically. Choose your WoW folder below."
   with **Browse...**.

6. Player clicks **Install**. The same Marquee progress bar and step text
   play out as today (copying files, building the native host via
   `csc.exe` - a brief, few-second freeze DISTRIBUTION-SPEC.md 6.2 already
   documents as expected). No second SmartScreen prompt appears anywhere
   in this step: the only other `.exe` involved, `host\bin\FurphyHost.exe`,
   is compiled locally on the player's own machine by `install.ps1`,
   exactly as it is today - it is never downloaded.

7. **Success screen** (unchanged): "Furphy Addon Manager is installed."
   with "Nothing in your AddOns folder was touched." and two buttons,
   **Open Furphy Addon Manager** and **Close**.

8. Player clicks **Open Furphy Addon Manager**; the app opens. Behind the
   scenes, FurphySetup.exe's own process has already exited (it waited for
   the wizard's `powershell.exe` child to finish, then exited with its
   code) and its temp extraction folder is deleted. At no point in steps
   4-8 does anything named `install.ps1`, `Install Furphy.cmd`, or any
   other `.ps1`/`.cmd` file appear anywhere a player would see it.

9. **Silent/scripted path.** An admin runs
   `FurphyAddonManager-Setup.exe /S` (optionally with extra arguments, see
   4.4) from an elevated or scripted context. No window, no SmartScreen
   click-through needed if the file is already allow-listed by policy.
   Exit code 0 on success, 2 if no WoW installation could be found (the
   same contract `install.ps1 -Console` already has today).

-------------------------------------------------------------------------
## 4. Setup.exe design
-------------------------------------------------------------------------

FurphySetup.exe is a `/target:winexe` C# 5 WinForms program (same
language subset as `host\FurphyHost.cs:1-9` - no string interpolation, no
`?.`, no `async`/`await`, since Add-Type/CompilerParameters compiles it the
same way). It contains exactly four responsibilities: show a splash,
extract an embedded zip, launch `install.ps1` (hidden or visible per
mode), relay the exit code. **It writes no registry key, no shortcut, and
no Add/Remove Programs entry of its own** - see section 12's static
regression test guarding exactly this.

### 4.1 Window layout

- One `Form`, `FormBorderStyle = FixedDialog`, `MaximizeBox`/`MinimizeBox
  = false`, `ClientSize` ~360x140, `StartPosition = CenterScreen`,
  `Text = "Furphy Addon Manager Setup"` (this exact title doubles as the
  `FindWindow` target for second-instance activation, section 4.5).
- `Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)` - reads
  the icon straight back off the running exe's own resources (embedded at
  compile time, section 4.9), so no separate `.ico` file needs to survive
  in the temp extraction folder or next to the exe.
- A `Label`, text `"Preparing Furphy Addon Manager Setup..."`.
- A `ProgressBar` with `Style = Marquee`, `MarqueeAnimationSpeed = 30` -
  the exact same idiom the wizard itself already uses
  (`install.ps1:2657-2660`, its own comment explaining why a Marquee bar
  was chosen over a determinate one applies identically here).
- No buttons. The splash is purely transient; there is nothing for a
  player to click on it.
- `Application.EnableVisualStyles()` / `SetCompatibleTextRenderingDefault(false)`
  run before any `Form` or `Control` is constructed - the same ordering
  constraint the wizard's own construction (`install.ps1:2612-2613`)
  already enforces, and for the same reason (visual styles must be set
  before the first control handle is created). **Correction, re-checked
  against the actual file:** `host\FurphyHost.cs` is not a same-shape
  precedent for "literal first two statements of `Main`" specifically -
  its real first statement is `DpiAwareness.TryEnable()`
  (`host\FurphyHost.cs:35`), with `EnableVisualStyles()`/
  `SetCompatibleTextRenderingDefault(false)` following at lines 37-38,
  *after* that DPI call (its own comment: "Must run before any Form/
  Control is created - see DpiAwareness below"). This document's own
  wizard-construction citation just above, `install.ps1:2612-2613`, uses
  the same "literal first two statements"/`host\FurphyHost.cs:37-38`
  shorthand in its own pre-existing comment - so the imprecision is
  pre-existing in this codebase, not newly introduced here, but it is
  worth being exact about in a from-scratch design: what actually matters
  for both files is only that visual-styles calls precede the first
  `Control`, not that they are the first two statements of the process.

  This also surfaces a real, unresolved question this design has not
  answered: FurphySetup.exe and the wizard's `powershell.exe` child run
  in two *separate* OS processes with independent DPI-awareness state, and
  this section never picks a DPI-awareness mode for the splash (no
  `DpiAwareness`-equivalent call is listed here at all), while
  `install.ps1`'s own wizard deliberately calls no DPI-awareness API
  either (confirmed: no `SetProcessDpi*`/`DpiAwareness` call anywhere in
  `install.ps1`; it relies only on `AutoScaleMode = 'Font'`). Section 9's
  cost write-up already flags the resulting splash-to-wizard handoff as
  "worth confirming... at both 100% and a non-100% DPI scale" - that
  confirmation is unchanged and still needed, but it is a live open point
  about actual on-screen behavior at non-100% scale, not just an
  unexercised test path.

### 4.2 State machine

1. `EnableVisualStyles`/`SetCompatibleTextRenderingDefault(false)`.
2. Best-effort, wrapped in try/catch: delete any `FurphySetup-*` folder
   under `%TEMP%` older than 24 hours (a light backstop for the rare
   crash/kill that skips step 9's own cleanup - nothing else in this
   project proactively sweeps stray temp folders either, e.g.
   APP-UPDATE-SPEC.md's own rollback folders are only overwritten, never
   swept, section 8.6).
3. Acquire a named `Mutex(<name>, ...)` (no `Global\` prefix - matching
   `host\FurphyHost.cs`'s own established convention: its tray
   single-instance mutex, `ResolveMutexName` (`host\FurphyHost.cs:4894-4897`),
   uses `"FurphyAddonManager.Tray"` with no `Global\` either). **Re-checked
   against the actual code, and corrected from an earlier draft:**
   `ResolveMutexName` does not use that bare literal unconditionally - it
   is port-scoped (`"FurphyAddonManager.Tray"` only at the production port
   47831; `"FurphyAddonManager.Tray.<port>"` for every other port), and its
   own surrounding comment explains why: "round 28" of this project fixed
   exactly the bare-global-name collision class being avoided here, after
   a bare literal let a test-port process and the real production tray
   collide on the same named object. A bare, unscoped
   `Mutex("FurphyAddonManagerSetup", ...)` reintroduces that same
   already-fixed defect for Setup.exe specifically: if Eric is running
   FurphySetup.exe interactively at the same moment a `/S` test (12.2)
   launches another copy, or if two rounds' own copies of
   `Setup.SilentInstall.Tests.ps1` run concurrently (a real possibility
   given this project's own parallel-round structure), the second process
   silently gets "already running" (exit 4, no dialog under `/S`) for a
   reason that has nothing to do with the code under test.

   FurphySetup.exe has no port of its own (it runs before any install
   exists to read a port from), so it cannot reuse `ResolveMutexName`'s
   port-based scoping directly - instead, mirror this codebase's other
   established isolation idiom, the `FURPHY_TEST_*` environment-variable
   seam (e.g. `FURPHY_TEST_APPUPDATE_DRYRUN`, `FURPHY_TEST_WAGO_BASEURL`/
   `FURPHY_TEST_GITHUB_BASEURL`, all in `addon-server.ps1`): the mutex
   name is `"FurphyAddonManagerSetup"` plus, only when
   `$env:FURPHY_TEST_SETUP_MUTEX_SUFFIX` is non-empty, a literal `.` and
   that value appended. A real player's install - interactive or a real
   admin's `/S` - never sets this variable and gets the plain, single
   global name (correct: a player really should only ever have one
   Setup.exe running at a time). Test 12.2 sets it to something
   test-run-unique (its own scratch port, or a GUID) before launching
   `FurphyAddonManager-Setup.exe /S`, so it can never collide with a real
   interactive Setup.exe or with another round's own concurrently-running
   copy of the same test. Not new instance -> section 4.5.
4. Parse arguments. First argument compared case-insensitively to `/S` ->
   silent mode; everything after it is captured verbatim as pass-through
   arguments (section 4.4). No `/S` -> interactive mode, and any arguments
   present are ignored (there is no documented interactive use for them).
5. Interactive mode only: construct and `Show()` (non-modal) the splash
   Form from step 4.1, then drive the rest of this state machine on the
   same thread with periodic `Application.DoEvents()` calls between steps
   - the identical "fewest moving parts, no new runspace/thread" choice
   DISTRIBUTION-SPEC.md 6.2 already made for the wizard's own progress
   pump, applied here for the same reason (keep a single-threaded,
   dependency-free program shape). Silent mode: no Form is ever
   constructed, `Application.DoEvents()` is never called.
6. Extract the embedded `FurphyPayload.zip` resource
   (`System.IO.Compression.ZipFile.ExtractToDirectory`) to
   `%TEMP%\FurphySetup-<ver>-<guid8>\` (naming convention matches the
   existing `%TEMP%\FurphyRollback-<oldVersion>-<guid>\` pattern,
   APP-UPDATE-SPEC.md section 8.6). Failure -> section 4.3, exit 5.
7. Build the child command line (section 5) and `Process.Start` it via
   `ProcessStartInfo` with `EnvironmentVariables["FURPHY_INSTALL_LAUNCHED_BY_SETUP"] = "1"`
   and `WorkingDirectory` set to the extraction folder. Wrapped in
   try/catch(`Win32Exception`) -> section 4.3, exit 3, if `powershell.exe`
   itself cannot be started (relies on PATH, not a hardcoded path - a
   Windows machine missing `powershell.exe` from PATH is broken in far
   worse ways this design does not need to solve).
8. Interactive mode only: poll `Process.MainWindowHandle` (refreshed via
   `Process.Refresh()`, ~150 ms interval) for up to ~5 seconds; hide the
   splash the instant a window appears, or after the timeout, whichever
   comes first. The wizard's own construction (`Show-InstallWizard`,
   `install.ps1:2575` on) does no compiling and is fast, so 5 seconds is a
   generous ceiling, not a typical wait. **Keep polling past the 5-second
   ceiling, at the same interval, for the rest of the run** (cheap - it is
   the same `Process.Refresh()` call already running on a timer - and
   record a single boolean, `sawChildWindow`, the first time a non-zero
   `MainWindowHandle` is ever observed, latched true forever after. This
   is what step 11 below needs to close the gap traced in section 10's new
   "wizard construction fails, WoW found" row: with only the original
   5-second poll, FurphySetup has no way to know, after the child exits,
   whether a window was ever shown at all.
9. `Process.WaitForExit()`.
10. try/finally: delete the extraction folder from step 6, best-effort,
    swallowing any error (the same "cleanup must never break the main
    flow" idiom `Write-InstallLogLine` already uses, `install.ps1:117-126`).
11. Interactive mode only, and only when the child's own exit code is 0
    and `sawChildWindow` (step 8) is still false: show one fallback
    `MessageBox`, caption `"Furphy Addon Manager Setup"`, text `"Furphy
    Addon Manager is installed. Look for the 'Furphy Addon Manager'
    shortcut on your Desktop to open it."`, single OK button. This is the
    fix for the gap traced in section 10: `install.ps1`'s own construction-
    failed-but-WoW-found fallback (`install.ps1:2799-2818`, the `catch`
    branch) runs `Invoke-FurphyInstallSteps` and exits 0 with no console
    and no wizard ever shown - a real install that genuinely succeeded,
    with nothing on screen to tell a Setup-launched player so. FurphySetup
    already knows, from `sawChildWindow`, that this is exactly that case
    (rather than the ordinary case where the wizard's own success screen
    already told the player everything). The message names the Desktop
    shortcut specifically because `Invoke-FurphyInstallSteps` creates it
    unconditionally on this path (Setup's own command line, section 5.1,
    never passes `-NoShortcuts`) - FurphySetup does not know `$appDest`
    and does not need to: it is not opening the app itself, only pointing
    at where the install already put a way to. This keeps FurphySetup's
    "exactly four responsibilities, no install logic of its own" framing
    (section 4) intact - it is a read-only, static fallback message keyed
    off the exit code and a boolean it already had, not new install logic.
12. Exit with the child's own `ExitCode` (relayed verbatim), except where
    an earlier step already chose FurphySetup's own code (1/3/4/5,
    section 4.7).

### 4.3 Error dialogs - exact copy (interactive mode only)

Silent mode (`/S`) **never** shows a `MessageBox`, matching `-Quiet`'s own
contract in `install.ps1` (its param-block comment, lines ~57-65: "a
headless test process must never call MessageBox.Show and hang waiting for
a click"). Every dialog below uses the caption `"Furphy Addon Manager
Setup"`.

| Condition | Text | Exit |
|---|---|---|
| Second instance, and `FindWindow`+`SetForegroundWindow` on the title `"Furphy Addon Manager Setup"` fails to locate/activate the running instance's own window (a narrow race - the running instance is still mid-extraction, before its splash exists) | "Furphy Setup is already running." | 1 |
| `powershell.exe` could not be started | "Furphy Setup could not find PowerShell, which Windows normally includes. Please contact support." | 3 |
| Embedded payload extraction failed | "Furphy Setup could not prepare its installer files. Make sure you have enough free disk space and try again." | 5 |
| Child `install.ps1` exited with any code other than 0 or 2 | "Setup did not finish successfully (code \<N\>). Nothing may have been installed. Try running the downloaded file again, or ask for help and mention this code." | \<N\> (relayed) |

**Copy note, re-checked against this project's own audience framing**
(README.md's own opening line: "for below-average-tech-savvy players"):
a bare numeric code with no next action ("code 3") leaves this dialog's
reader with nothing to do, unlike the PowerShell-missing dialog above it,
which at least says "Please contact support." The added sentence gives a
concrete, low-cost next step (retry, or ask for help and name the code)
without inventing a log file or diagnostic path that does not exist for
this flow - `install.ps1` only writes a log for `-Uninstall`
(`$Script:UninstallLogPath`, `install.ps1:117-126`), not for a normal
install, so pointing a player at "the install log" here would be false.

If `FindWindow`+`SetForegroundWindow` for the second-instance case
*succeeds*, no dialog is shown at all - the existing instance's own window
simply comes to the front, and this instance exits 1 silently. This is
cleaner than always showing a redundant dialog on top of the activated
window, and it is the common case (the narrow-race fallback above is the
exception, not the rule).

Exit code 2 (WoW not found) is deliberately **not** shown by FurphySetup's
own generic non-zero handler above - in the interactive path it should
essentially never reach FurphySetup at all, because a construction-
succeeding wizard's own Browse-folder screen (section 3, step 5) is the
real recovery UI for "WoW not found". The one narrow case where code 2
*does* reach FurphySetup interactively is Form-construction failure
combined with WoW genuinely not being found - `install.ps1`'s own
try/catch around `Show-InstallWizard` (`install.ps1:2799-2814`) falls back
to printing an ERROR to its (hidden, Setup-launched) console and exiting
2, which would otherwise be invisible to a Setup-launched player. Relaying
it through the table's last row (generic non-zero) is what makes that rare
failure visible at all; this is intentional, not an oversight.

### 4.4 `/S` semantics

- With **zero** extra arguments: the child command line is exactly
  `install.ps1 -Console -Quiet` - the fixed decision's literal mapping,
  unchanged.
- Anything after `/S` on FurphySetup's own command line is forwarded
  verbatim, in order, appended **after** `-Console -Quiet`:
  `FurphyAddonManager-Setup.exe /S -WowPath "D:\scratch\wow" -NoShortcuts -NoProtocol -SkipAdopt`
  becomes `install.ps1 -Console -Quiet -WowPath "D:\scratch\wow" -NoShortcuts -NoProtocol -SkipAdopt`.
  This is additive, never a change to the zero-argument mapping, and it is
  what makes the `/S` scratch-install test in section 12 a real end-to-end
  test (a headless caller otherwise has no way to target a non-default WoW
  path through Setup.exe at all).
- Only the literal token `/S` (case-insensitive) as the *first* argument
  triggers silent mode. No other alias (`/SILENT`, `-S`, `/VERYSILENT`) is
  recognized, matching the fixed decision's own specific spelling and
  keeping FurphySetup's argument grammar to exactly what was asked for.

### 4.5 Second-instance handling

Covered by the Mutex in section 4.2 step 3 and the dialog table in 4.3.
Silent mode never shows a dialog on collision; it exits 4 (a code distinct
from the interactive case's exit 1, so a scripted deployment can tell
"another Setup was already running" apart from "a real failure" without
parsing text).

### 4.6 Temp folder and cleanup

`%TEMP%\FurphySetup-<ver>-<guid8>\`, created fresh per run, deleted in a
`finally` block on any orderly exit (including `install.ps1` exiting
non-zero). A hard crash or an external `Process.Kill()` can still strand a
folder - accepted as a bounded, cosmetic risk (nothing else in this
project auto-sweeps stray `%TEMP%` folders either); the 24-hour opportunistic
sweep in section 4.2 step 2 is the only mitigation, and it is best-effort
by design.

### 4.7 Exit codes

| Code | Meaning |
|---|---|
| 0 | `install.ps1` exited 0. This covers three cases: "installed successfully with the wizard shown" (the ordinary path), "the wizard window was closed without clicking Install" - an existing ambiguity in `install.ps1` itself (`Show-InstallWizard` returning normally after `form.Close()` from the hidden Cancel button, `install.ps1:2620-2626`, looks identical to a successful install from the caller's point of view) - and "installed successfully with no wizard ever shown" (the rare construction-failure-but-WoW-found case, section 10's new row), which section 4.2 step 11's fallback dialog now covers so it is not silently indistinguishable from the first case to the player. FurphySetup does not change or paper over the wizard-closed-without-Install ambiguity; it is documented here so a future editor does not "fix" it inside FurphySetup by mistake. |
| 1 | Second instance detected (interactive) - existing window activated, or the fallback dialog shown. |
| 2 | WoW not found, relayed verbatim from `install.ps1`'s own exit-2 contract (`install.ps1:641-650` for `-Console`/`-Uninstall`; the try/catch fallback at `install.ps1:2810-2814` for a construction-failed wizard with no WoW found). |
| 3 | Could not launch `powershell.exe`. |
| 4 | Second instance detected (silent `/S`) - no dialog. |
| 5 | Could not extract the embedded payload. |
| other | Relayed verbatim from `install.ps1`'s own exit code. Should not occur beyond 0/2 in the code as it stands today, but is relayed rather than swallowed in case a future `install.ps1` change adds one. |

### 4.8 Version info

`setup\build-setup.ps1` performs a single text substitution of a
`__FURPHY_SETUP_VERSION__` token inside `FurphySetup.cs` for the real
`AssemblyVersion`/`AssemblyFileVersion` (VERSION's own content plus a
literal `.0` fourth part, e.g. `1.22.0` -> `1.22.0.0`) **before** handing
the source text to `Add-Type` - a compiled assembly cannot re-open an
external file at its own runtime to learn its version, so this is a
build-time-only step, exactly like `package.ps1` already reads `VERSION`
once at build time for the zip's own name. `AssemblyProduct`/
`AssemblyTitle`/`AssemblyCompany`/`AssemblyDescription` attributes are
also set (`"Furphy Addon Manager"` / `"Furphy Addon Manager Setup"` /
`"krenz444"` / `"Installs Furphy Addon Manager. Extracts a bundled copy of
the app; makes no network connections of its own."`) so Explorer's own
Properties > Details tab shows a real, reassuring name instead of a blank
one - a small thing, but the exact audience this round is written for
(and any AV/EDR analyst who opens Properties on the file) benefits from it
existing at all.

### 4.9 Icon

`/win32icon:"<repo root>\icon.ico"` at compile time - the same file, same
`/win32icon` idiom, `host\build-host.ps1:80` already proves works with
zero extra tooling. At runtime the splash Form's own icon comes back off
the exe's own resources (section 4.1), so no `.ico` file needs to travel
inside the embedded payload separately from the app's own copy (which is
already in there, since `icon.ico` is one of `package.ps1`'s `$rootFiles`).

-------------------------------------------------------------------------
## 5. Engine hand-off
-------------------------------------------------------------------------

### 5.1 Interactive mode - exact command line

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<extractDir>\install.ps1"
```

No `-WowPath` (auto-detection runs, identical to today's `Install Furphy.cmd`
double-click, `Install Furphy.cmd:6`, with no flags). Environment variable
`FURPHY_INSTALL_LAUNCHED_BY_SETUP=1` is set on the child process (section
5.3). `WorkingDirectory` is the extraction folder so `$PSScriptRoot`
resolves correctly inside `install.ps1`.

This lands in `install.ps1`'s existing non-`-Console` branch
(`install.ps1:2789` on): it tries `Show-InstallWizard`
(`install.ps1:2575`), which is the exact same window a manual
`Install Furphy.cmd` double-click already shows - **nothing about the
wizard itself changes for a Setup-launched run.**

### 5.2 Silent mode - exact command line

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<extractDir>\install.ps1" -Console -Quiet [<pass-through args, section 4.4>]
```

Lands in `install.ps1`'s `if ($Console) { Invoke-FurphyInstallSteps; exit 0 }`
block (`install.ps1:2789-2795`) - the exact same headless path every
automated test in this repo, and the self-updater's own `-Upgrade`
command line, already exercise. `FURPHY_INSTALL_LAUNCHED_BY_SETUP=1` is
still set here too, though it has no effect on this branch (see 5.3 - the
one gated call site is unreachable from `-Console` regardless).

### 5.3 The one `install.ps1` change this design requires

`Show-InstallConsole` (`install.ps1:468-493`) is called from exactly one
place: `install.ps1:2806`, right after `Show-InstallWizard` returns
(success or the hidden Cancel button), immediately before `exit 0`. Its
own comment explains why it exists: `Install Furphy.cmd` shares its
wrapping `cmd.exe`'s own console window, and un-hiding it lets that
`.cmd`'s trailing `pause` (line 8 of `Install Furphy.cmd`) work instead of
sitting invisibly forever.

A Setup-launched `install.ps1` has no such wrapper - it was started with
`-WindowStyle Hidden` directly by FurphySetup.exe, and nothing is waiting
on its console. `GetConsoleWindow()` still returns a real (hidden) HWND
for that child process either way (`powershell.exe` is a console-subsystem
executable regardless of who launches it), so calling
`ShowWindow(hwnd, SW_SHOW)` right before exit would make a console flash
briefly on screen at the very end of an otherwise console-free install -
violating "no visible console... at any point of a normal install."

**Fix - the one line this design changes in `install.ps1`:**

```powershell
if (-not $env:FURPHY_INSTALL_LAUNCHED_BY_SETUP) { Show-InstallConsole }
```

replacing the bare `Show-InstallConsole` call at line 2806. Nothing else
in `install.ps1` needs to change:

- `-WowPath` needs no special-casing - Setup omits it exactly like
  today's plain `Install Furphy.cmd` double-click already does.
- "Open Furphy Addon Manager" needs no change - the wizard's own
  `$btnOpen` click handler (`install.ps1:2754-2763`) already launches
  `Addon Manager.vbs` from `$script:appDest`, and a Setup-launched wizard
  is the exact same wizard code running the exact same handler.
- `Hide-InstallConsole` (`install.ps1:2785`, called just before
  `ShowDialog()`) is untouched - it already only fires once Form
  construction has fully succeeded (fix 6's own mandatory ordering), which
  is correct in the Setup-launched case too.

### 5.4 Why not rewrite the install logic in C#

DISTRIBUTION-SPEC.md 6.1 (lines 564-577) already evaluated and chose
"keep `install.ps1`, add an optional WinForms front end" over a compiled
EXE for the install logic itself, and confirmed live that
`Add-Type`/`csc` works with zero extra tooling on a real machine. Nothing
about "ship one downloadable file" changes that calculus for the install
*logic* - only for the delivery *wrapper*. FurphySetup.cs contains no
`Find-WowRoot`, no flavour table, no registry write, no shortcut creation
- all of it stays exactly where it already lives and has already been
tested.

Worth stating precisely rather than glossing over: "no visible console,
`.cmd` or `.ps1` at any point of a normal install" means the `.ps1` still
*runs* - it is simply never *seen* (a hidden `powershell.exe`, the wizard
Form on top of it) - which is a materially different claim from "no `.ps1`
is involved at all." Nothing in this design pretends otherwise.

### 5.5 `-Upgrade` / `-Relaunch` / `-Uninstall` / per-install scoping - untouched

- **`-Upgrade -Relaunch <mode>`**: the self-updater's own fixed command
  line (APP-UPDATE-SPEC.md section 8.5, quoted at its line 508; built at
  `addon-server.ps1:9704-9731` via `ConvertTo-SafeProcessArg`+
  `List[string]`+`Start-Process` - re-verified against the file during
  this synthesis pass, since the prior draft's citation (9658-9669) had
  already drifted onto an unrelated busy-check loop; see section 13 for
  why this file is a moving target right now) is untouched. Setup.exe
  never sets
  `-Upgrade` or `-Relaunch`, is never itself launched by the self-updater,
  and `FURPHY_INSTALL_LAUNCHED_BY_SETUP` is not read anywhere near that
  code path. Setup.exe is a **first-install** tool only (section 8).
- **`-Uninstall`**: unaffected for a second, independent reason beyond
  "Setup.exe never passes it" - `Get-InstallUninstallString`
  (`install.ps1:338-370`) builds the registry `UninstallString`/
  `QuietUninstallString` around `Join-Path $appDest 'install.ps1'`, i.e.
  the **installed, on-disk copy** under `<WoW>\_retail_\AddonSync\`,
  never anything from FurphySetup's own disposable temp extraction
  folder (which is long gone by the time anyone clicks Uninstall). The
  Installed-Apps registry entry itself
  (`install.ps1:2519-2549`) is written by `Invoke-FurphyInstallSteps`
  exactly as it always was - FurphySetup neither writes nor influences it.
- **Per-install scoping** (`Get-InstallPort` at `install.ps1:262-277`,
  `Get-InstallStartupValueName` at `install.ps1:279-285`,
  `Get-InstallAppsKeyName` at `install.ps1:308-311` (it is a thin
  1-line forward to the former, not a separate implementation - the two
  are not contiguous in the file; `Get-InstallTrayStopEventName` sits
  between them, see next), `Get-InstallTrayStopEventName` at
  `install.ps1:287-293`, `Test-LooksLikeScratchRun` at
  `install.ps1:175-188`) is pure `install.ps1` logic keyed off
  `$appDest`'s own `settings.json` port and path shape. FurphySetup passes
  no port and reads none of these functions - a Setup-launched install
  scopes exactly the same way a manual double-click install already does.
  Section 12 records one real asymmetry in this existing scoping worth
  knowing before writing new tests against it (it is not something this
  design changes, but it does affect how the new tests in section 12/13
  must be written).

-------------------------------------------------------------------------
## 6. Build
-------------------------------------------------------------------------

### 6.1 `setup\build-setup.ps1` (new)

**Correction worth stating plainly:** the task brief's own phrasing
("csc discovery reused from build-host.ps1") slightly overstates what
`host\build-host.ps1` actually does. It performs **no manual csc.exe path
lookup at all** - its compile script goes straight to
`Add-Type -TypeDefinition $src -CompilerParameters $cp`
(`host\build-host.ps1:71-82`), relying entirely on .NET Framework's own
`CSharpCodeProvider`/CodeDom machinery to locate `csc.exe` on its own. The
*only* place in this codebase that manually probes for `csc.exe` by path
is `install.ps1:1753-1756` (`Microsoft.NET\Framework64\v4.0.30319\csc.exe`,
falling back to `Microsoft.NET\Framework\v4.0.30319\csc.exe`), and that
probe is a **pre-flight existence gate on the end user's own machine**
("should I even attempt to build the native host") - it is never passed
into the actual compile, which happens inside a *separately launched*
`host\build-host.ps1` child process that does its own `Add-Type` call with
no csc path of its own either.

`setup\build-setup.ps1` therefore mirrors `host\build-host.ps1`'s real
approach (no manual csc discovery needed for the compile itself), plus one
fail-loud pre-flight check on the **build machine** - reusing
`install.ps1`'s own two candidate paths as the probe, since that is the
one place in the codebase such a probe already exists - so a build machine
silently missing the C# compiler produces a clear `throw`, matching
`package.ps1`'s own established "fail loudly if missing" philosophy
(`package.ps1:200-210`'s own zip/latest.zip existence checks), rather than
a `csc.exe not found` error buried inside `Add-Type`'s own exception text.

Structure (line-for-line, the same shape as `host\build-host.ps1`):

- `CompilerParameters`: `$cp.OutputAssembly`, `$cp.GenerateExecutable = $true`,
  `$cp.GenerateInMemory = $false`, `$cp.TreatWarningsAsErrors = $false` -
  identical to `host\build-host.ps1:71-82`.
- References: `System.dll`, `System.Drawing.dll`, `System.Windows.Forms.dll`,
  `System.IO.Compression.dll`, `System.IO.Compression.FileSystem.dll` - the
  last two ship with every .NET Framework 4.5+ install (already a floor on
  this build machine, since the WebView2 SDK build already assumes it) -
  no new machine dependency.
- `CompilerOptions`: `/target:winexe /win32icon:"<repo root>\icon.ico" /resource:"<dist>\FurphyAddonManager-<ver>.zip",FurphyPayload.zip`
  - same `/win32icon` idiom as `host\build-host.ps1:80`, same `icon.ico`
    file the app itself already uses.
- Same child-`powershell.exe` indirection as `host\build-host.ps1:84-99`
  (including its `$q` quote-wrapper) - required here for the identical
  reason its own comment gives (`host\build-host.ps1:54-58`): `Add-Type`
  cannot recompile the same `TypeDefinition` text twice in one process, and
  `package.ps1` may run more than once in a build/test session.
- Version substitution: the `__FURPHY_SETUP_VERSION__` token swap described
  in section 4.8, performed on the source text (a plain
  `$src.Replace(...)`) before it is written to the temp compile script.
- Output: `dist\FurphyAddonManager-Setup-<ver>.exe`. Copied to the stable
  `dist\FurphyAddonManager-Setup.exe` (the exact same "second,
  identically-named asset" pattern `package.ps1` already uses for
  `FurphyAddonManager-latest.zip`, `package.ps1:196-198`, for the same
  GitHub stable-link reason DISTRIBUTION-SPEC.md 6.6 already documents).
- `.sha256` sidecar for the **versioned** exe only, never the stable-named
  copy - mirroring `package.ps1`'s own established rule
  (`package.ps1:176-186`: bare lowercase hex, no filename, no trailing
  newline, `-Encoding Ascii -NoNewline`; sidecar only for the versioned
  asset, "since nothing needs to verify them by fixed name"). Note this
  bare-hex format is `package.ps1`'s **actual, current, tested** sidecar
  shape - DISTRIBUTION-SPEC.md section 6.6's own prose still describes an
  older two-column `sha256sum`-style format that `package.ps1`'s own
  comment (lines 152-172) records was found live-breaking and fixed before
  1.22.0 shipped; that prose drift in 6.6 is pre-existing and outside this
  round's scope to fix, but this design's own sidecar must follow the
  real, current code, not the stale doc text.

Payload identity: the embedded `FurphyPayload.zip` resource is the
byte-for-byte same `dist\FurphyAddonManager-<ver>.zip` `package.ps1`
already built and integrity-checked (`package.ps1:200-210`) earlier in the
same run - never a second, separately-assembled file list. This is what
keeps "what does a fresh install contain" a single source of truth, and it
is also what section 12's static payload-contents test verifies.

### 6.2 `package.ps1` integration

Add, after the existing zip/latest.zip/sha256 block (through
`package.ps1:210`) and before its final release-reminder lines
(`package.ps1:212-214`):

1. Invoke `setup\build-setup.ps1` (passing `-Version $version -DistDir $DistDir`
   or equivalent), which performs the fail-loud csc pre-flight check from
   6.1 and throws if the compiler is missing - matching this file's own
   established philosophy for a missing external tool.
2. Confirm the versioned exe, the stable-named exe, and the versioned
   exe's `.sha256` sidecar all exist and are non-empty, same shape as the
   existing zip-pair checks at `package.ps1:200-210`.
3. Extend the final `Write-Host` reminder block to name **all six**
   assets:

```
Write-Host ''
Write-Host 'Release step (manual, on demand) - ATTACH ALL SIX ASSETS, every release:'
Write-Host "  gh release create v$version `"$zipPath`" `"$latestZipPath`" `"$shaPath`" `"$setupVersionedPath`" `"$setupStablePath`" `"$setupShaPath`""
```

### 6.3 Full `gh release` recipe

```
gh release create v<version> \
  "dist\FurphyAddonManager-<version>.zip" \
  "dist\FurphyAddonManager-latest.zip" \
  "dist\FurphyAddonManager-<version>.zip.sha256" \
  "dist\FurphyAddonManager-Setup-<version>.exe" \
  "dist\FurphyAddonManager-Setup.exe" \
  "dist\FurphyAddonManager-Setup-<version>.exe.sha256"
```

Six assets, matching `Get-AppUpdateAssetsFromRelease`'s own exact-name
matching (section 8) so the self-updater never has to change.

-------------------------------------------------------------------------
## 7. Download page and docs
-------------------------------------------------------------------------

### 7.1 `site\index.html`

Replace the download button's `href` (currently
`https://github.com/krenz444/furphy-addon-manager/releases/latest/download/FurphyAddonManager-latest.zip`)
with:

```
https://github.com/krenz444/furphy-addon-manager/releases/latest/download/FurphyAddonManager-Setup.exe
```

Replace the `<ol class="steps">` block's five `<li>` items with three.
**Re-checked against the real markup and corrected from an earlier
draft:** `site\index.html`'s step numbers (`site\index.html:114-143` for
the CSS, `197-211` for the current items) come entirely from a CSS
counter (`ol.steps{counter-reset:step}` /
`li::before{content:counter(step)}`) - each `<li>` itself carries no
"1."/"2." text of any kind, only a `<div class="step-body">...</div>`
with plain sentence text. The replacement below must match that shape
(no leading digits in the text) - pasting a plain numbered list here, as
an earlier draft of this section did, would render a visible double
number (the CSS badge's "1" next to literal text "1. Click Download
above."). This is a different content style from README.md/README.txt
(section 7.2/7.3), where literal "1."/"2." text is correct, since those
really are plain numbered-text lists with no CSS counter behind them -
do not copy this HTML block's wording pattern into those files, or
vice versa.

```html
<ol class="steps">
  <li>
    <div class="step-body">Click <strong>Download</strong> above.</div>
  </li>
  <li>
    <div class="step-body">Your browser may show a mild download-safety
    notice first (wording varies) - choose <strong>Keep</strong>/<strong>Keep
    anyway</strong>. Then open the file.</div>
  </li>
  <li>
    <div class="step-body">Windows may show a blue "Windows protected your
    PC" screen since it isn't signed with a paid certificate - click
    <strong>More info</strong>, then <strong>Run anyway</strong>. A small
    window opens - click <strong>Install</strong>. Furphy finds your WoW
    folder automatically. When it's done, click <strong>Open Furphy Addon
    Manager</strong>.</div>
  </li>
</ol>
```

Replace the `.safety-note` paragraph text with:

```
Windows may show a blue "Windows protected your PC" screen the first time
you run FurphyAddonManager-Setup.exe, since it isn't signed with a paid
certificate - click More info, then Run anyway. Furphy only writes inside
your WoW folder and never asks for admin access, and Setup never shows a
Windows admin (UAC) prompt either.
```

Add one line under the safety note (new, not a replacement) naming the
zip as the secondary/advanced path, matching the fixed decision's own
"the zip stays as a secondary asset... power users may use it":

```
Prefer the zip? A power-user zip (Install Furphy.cmd/install.ps1 inside)
is also available from the Releases page.
```

with `Releases page` linking to
`https://github.com/krenz444/furphy-addon-manager/releases/latest`.

### 7.2 `README.md`

**Re-checked against the real file and corrected from an earlier draft:**
`README.md`'s current `## Install` section (`README.md:20-26`) has
**five** numbered steps, not four - step 5 is "On most machines, one
small window opens... On some machines you may see the console-only flow
instead of that window - that's fine, it does exactly the same thing,
just as plain text." Replacing only steps 1-4, as an earlier draft of
this section said, leaves step 5 behind: the new step 4 below already
describes the same install-window moment step 5 also describes, and step
5's "you may see the console-only flow instead" clause becomes false
under Setup.exe (the console is always hidden on this path) - the result
is a broken, duplicated numbered list.

Replace the `## Install` section's steps **1-5** (currently the
download-zip/Extract-All/double-click-cmd/security-warning/install-window
sequence, all five of `README.md:20-26`) with:

```
1. Download FurphyAddonManager-Setup.exe from the project's [Releases
   page](https://github.com/krenz444/furphy-addon-manager/releases/latest)
   (or the download button on the [landing
   page](https://krenz444.github.io/furphy-addon-manager/), if it's live).
2. Your browser may show a mild download-safety notice first (wording
   varies by browser) - choose Keep/Keep anyway, then open the file.
3. Windows may show a blue "Windows protected your PC" screen the first
   time you run it, since it isn't signed with a paid certificate - click
   More info, then Run anyway. Furphy only writes inside your WoW folder
   and never asks for admin access, and Setup never shows a Windows admin
   (UAC) prompt either.
4. A small window opens: "Furphy found World of Warcraft in `<path>`"
   with a single **Install** button (or a folder picker if it can't find
   WoW - point it at your WoW folder and click Install). A progress bar
   shows while it copies files and builds the native host, then a success
   screen offers **Open Furphy Addon Manager**.
```

Keep the existing "Either way, the installer:" bullet list and the
command-line-options line unchanged (they describe `install.ps1` itself,
still accurate). Add one line after the command-line-options line:

```
Prefer the old zip (Install Furphy.cmd / install.ps1 by hand)? It's still
published on every release, for power users and for the auto-updater -
see the Releases page.
```

**Re-checked against the real file and corrected from an earlier draft:**
"after the silent-install mention" has no anchor - `README.md`'s
`## Install` section, and the whole file, contains no existing mention of
silent install, `-Console`, or `-Quiet` at all (confirmed by search; the
file's only other uses of the word "silent" are the unrelated
"silent background addon updates" feature line near the top and the
self-updater's "silent update finishes" line, section-56-area - neither
is an install-silent-mode mention to anchor after). Add the new `/S` line
immediately after the "Prefer the old zip" line just added above instead
(a real, existing anchor in this same edit):

```
Scripted/silent install: `FurphyAddonManager-Setup.exe /S` (optionally
followed by any install.ps1 flag, e.g. `-WowPath "<path>"`).
```

The `irm ... | iex` "Advanced users" line stays as-is (it is a documented
alternative to the zip's `install.ps1`, not to Setup.exe, and remains
accurate).

### 7.3 `README.txt`

Mirror 7.2's changes in the plain-text `NEW INSTALL` section, same
content, no markdown:

```
NEW INSTALL
  Download FurphyAddonManager-Setup.exe from the Releases page (or the
  download button on the landing page). Your browser may show a mild
  download-safety notice first - choose Keep/Keep anyway, then open the
  file. Windows may show a blue "Windows protected your PC" screen since
  it isn't signed with a paid certificate - click More info, then Run
  anyway. Furphy only writes inside your WoW folder and never asks for
  admin access, and Setup never shows a Windows admin (UAC) prompt either.
  A small window then opens with a single Install button (or a folder
  picker if it can't find WoW). It finds your WoW folder, copies the app
  into <WoW>\_retail_\AddonSync, creates the desktop shortcut, registers
  curseforge:// install links, registers Furphy in Windows' own Settings >
  Apps list, and adopts any addons already in your AddOns folder. Safe to
  re-run any time.

  Scripted/silent install: FurphyAddonManager-Setup.exe /S (optionally
  followed by any install.ps1 flag, e.g. -WowPath "<path>").

  Prefer the old zip (Install Furphy.cmd / install.ps1)? Still published
  on every release for power users and the auto-updater - see the
  Releases page. Advanced: "irm <url>/install.ps1 | iex" also works from
  PowerShell with that zip's install.ps1 if you'd rather skip the
  downloaded file.
```

### 7.4 `DISTRIBUTION-SPEC.md`

Add a new, explicitly dated section immediately after 6.8 (re-verified:
`DISTRIBUTION-SPEC.md` already has a "6.8 README additions" subsection
right after 6.7, ending right before "## 7. Change sets by file" - the
new section must go after 6.8, not between 6.7 and 6.8, or the document
numbers out of order as 6.7/6.9/6.8/7). Do not silently edit 6.7's own
text - it correctly documents what was decided *at the time*; the
reversal belongs in its own dated entry, the same style 6.7's own
trailing signing decision already uses:

```
### 6.9 2026-09-08: reversing the "no compiled installer EXE" decision

Eric's request, verbatim: "the install experience needs to be better,
like gui, easy to use, no ps1 or cmd files, download and install, easy."
This explicitly and knowingly reverses 6.7's "no compiled installer EXE"
call - not because 6.7's reasoning was wrong (it wasn't: an unsigned EXE
does trip Windows Defender SmartScreen's full-screen "Windows protected
your PC" block, which is strictly scarier than today's mild "Open File -
Security Warning"), but because Eric weighed that cost against "no ps1 or
cmd files, ever" and chose the latter. See SETUP-SPEC.md for the full
design (FurphySetup.exe, a small csc-compiled WinForms bootstrapper that
embeds the existing release zip and launches the existing, unmodified
install.ps1 wizard).

This is the first downloaded, executed binary this project has ever
shipped. Everything before this - the zip, install.ps1, Install
Furphy.cmd - is script text a player's own machine interprets; the only
compiled .exe that has ever existed on a player's machine
(host\bin\FurphyHost.exe) has always been built locally, from source,
during install.ps1's own run, and has never been downloaded pre-built.
FurphyAddonManager-Setup.exe changes that property for the first time.

Two things worth stating plainly, since they are exactly the properties
this decision most needed to preserve: FurphySetup.exe never requests
elevation (no UAC prompt, ever - same PrivilegesRequired=lowest guarantee
install.ps1 itself already has, HKCU-only registry writes throughout,
install.ps1:2518's own comment), and it never touches the network itself
(section 9) - it only extracts a payload already embedded in its own file
and launches a local install.ps1.

Signing itself is still declined this round (6.7's comparison table
stands). Revisit only if download volume/SmartScreen friction becomes a
real support burden - Azure Trusted Signing (~$10/mo, instant reputation)
remains the concrete pick if that day comes (see section 14 of
SETUP-SPEC.md for the open question on timing this).
```

-------------------------------------------------------------------------
## 8. Self-updater interaction
-------------------------------------------------------------------------

**The self-updater needs zero code changes.** `Get-AppUpdateAssetsFromRelease`
(`addon-server.ps1:8957-8990`) matches release assets by **exact name
only** - `"FurphyAddonManager-<version>.zip"` and
`"FurphyAddonManager-<version>.zip.sha256"` - never "first .zip found" (its
own comment is explicit about this, and `Server.AppUpdateReleaseParse.Tests.ps1`
already exercises a release with extra unrelated assets present to prove
it). Adding `FurphyAddonManager-Setup.exe`, `FurphyAddonManager-Setup-<ver>.exe`,
and `FurphyAddonManager-Setup-<ver>.exe.sha256` as additional release
assets is invisible to this matching logic - it simply never looks at
them.

Facts the updater's own maintainers should know, restated here so nothing
about this round is a surprise later:

- **Setup.exe is a first-install tool only.** It is never downloaded,
  never referenced, and never run by `Invoke-AppUpdateMaintenanceCore`
  (`addon-server.ps1:9182` on) - that function always downloads the
  **zip**, over HTTPS, verifies its sha256 sidecar, and drives
  `install.ps1 -Upgrade -Relaunch <mode> -Console -Quiet` from a staged
  extraction folder (section 5.5). None of that changes.
- The zip **must keep shipping** every release, unchanged in content and
  name - it is the self-updater's only payload, and it is also the
  documented power-user/advanced path (section 7).
- `FURPHY_INSTALL_LAUNCHED_BY_SETUP` (section 5.3) is never set anywhere
  near the self-updater's own launch - it is Setup-specific, and the
  self-updater's own `-Upgrade` path does not touch the one gated call
  site (`Show-InstallConsole` is unreachable from `-Console` regardless of
  that variable, since `-Console` never calls it at all).

-------------------------------------------------------------------------
## 9. Security and SmartScreen
-------------------------------------------------------------------------

- **Mark of the web / SmartScreen.** A browser-downloaded
  `FurphyAddonManager-Setup.exe` carries the zone-identifier MOTW
  reliably (unlike `Expand-Archive` on a zip, browsers consistently tag a
  direct file download) - so unlike today's zip path, this one is *not*
  hedged with "may show"; it reliably triggers SmartScreen's app-
  reputation check on a fresh build/hash with low download volume. Exact
  text: section 3, step 3.
- **Unsigned, deliberately (this round).** No Authenticode signature.
  Section 7.4's DISTRIBUTION-SPEC.md addition records this as a knowing
  reversal of 6.7's prior "no compiled EXE" call, not a re-litigation of
  the separate "no signing" call (6.7's own signing comparison table -
  Azure Trusted Signing / SignPath / Certum - is unchanged and still
  applicable if signing is revisited later, section 14).
- **No elevation, ever.** FurphySetup.exe requests no UAC elevation
  (default `asInvoker` manifest behavior - no explicit `requireAdministrator`
  manifest is added, and no `/win32manifest` override of any kind is
  needed). This is not an unverified assumption about csc's defaults:
  **empirically confirmed** against this exact build root during this
  synthesis pass by extracting the embedded manifest from the already-
  built `host\bin\FurphyHost.exe` (compiled by the identical
  `Add-Type -TypeDefinition ... -CompilerParameters $cp` /
  `/target:winexe` mechanism section 6.1 says `setup\build-setup.ps1`
  will mirror, with no `/win32manifest` or `/nowin32manifest` flag passed
  either way in `host\build-host.ps1`) - its embedded manifest reads
  `<requestedExecutionLevel level="asInvoker" uiAccess="false"/>`,
  present automatically, with zero extra compiler flags. FurphySetup.exe,
  built the same way, inherits the identical default manifest. This also
  settles a real question worth naming rather than leaving assumed:
  Windows' Installer Detection heuristic (auto-elevation for an unsigned,
  *manifest-less* exe whose filename contains "setup"/"install"/etc.)
  does not apply here, precisely because condition (b) of that heuristic
  - no embedded manifest - is false for any exe built this way, filename
  notwithstanding. Every registry write anywhere in this system is
  HKCU-only (`install.ps1:2518`'s own comment: "HKCU only, never HKLM - no
  admin needed"). A player never sees a Windows admin/UAC prompt at any
  point of a Setup-driven install.
- **Temp paths.** The only filesystem location FurphySetup.exe writes
  outside the extraction target is its own `%TEMP%\FurphySetup-<ver>-<guid8>\`
  working folder (section 4.6) - never `Program Files`, never anywhere
  requiring elevated write access.
- **No network calls in Setup.exe itself.** FurphySetup.exe makes zero
  network requests of its own - it extracts an already-embedded resource
  and launches a local `install.ps1`. Precisely stated, not overclaimed:
  the **launched `install.ps1`** may still make network calls during its
  own adopt-scan step ("reinstalling each from its source", README.md's
  own Install section) exactly as it already does today on a manual
  install - this is unchanged, pre-existing `install.ps1` behavior, not
  something Setup.exe adds or removes.
- **What this costs going forward (honest accounting, matching the
  runner-up design's own writing style for this section).**
  1. SmartScreen reputation resets on every release, not just once - a new
     zip embedded means a new file hash means a new exe means the
     full-screen block recurs every version, indefinitely, until enough
     downloads accumulate per-release (which, for a project this size,
     may never fully happen). Only paid signing removes this repeatably;
     documenting "More info -> Run anyway" makes it survivable, not gone.
  2. The extract-embedded-zip-then-launch-hidden-`powershell.exe`-with-
     `-ExecutionPolicy Bypass` shape is a documented heuristic pattern for
     malware droppers. The behavior is fully benign and open-source-
     reviewable, but an occasional AV/EDR false-positive flag on some
     endpoint product is a real, foreseeable possibility, not a
     hypothetical one (section 14 raises whether to pre-submit for review).
  3. This is the first time a compiled binary a player runs was never
     built on their own machine - a genuine, permanent departure from the
     property DISTRIBUTION-SPEC.md 6.7 (line ~789) used to call out as a
     benefit ("the only .exe that ever exists on the user's machine is
     compiled locally"). `host\bin\FurphyHost.exe` still holds that
     property; `FurphyAddonManager-Setup.exe` now does not, and never will
     under this design.
  4. Foreground-window handoff from the splash to the wizard (section 4.2
     step 8) is expected to work reliably (FurphySetup.exe is the active
     foreground app when it spawns the child) but is worth confirming on
     the real build/test machine at both 100% and a non-100% DPI scale -
     the same DPI testing DISTRIBUTION-SPEC.md 6.2 already mandates for
     the wizard itself applies here too.

-------------------------------------------------------------------------
## 10. Failure modes table
-------------------------------------------------------------------------

| Condition | Behavior | User message |
|---|---|---|
| Setup already running (interactive) | Existing window activated if found; else dialog | "Furphy Setup is already running." (only if activation itself failed) |
| Setup already running (`/S`) | No dialog, exit 4 | (none - silent by design) |
| `powershell.exe` cannot be started | Dialog, exit 3 (interactive); silent exit 3 (`/S`) | "Furphy Setup could not find PowerShell, which Windows normally includes. Please contact support." |
| Embedded payload fails to extract (disk full, corrupt build) | Dialog, exit 5 (interactive); silent exit 5 (`/S`) | "Furphy Setup could not prepare its installer files. Make sure you have enough free disk space and try again." |
| WoW not found, wizard shown successfully | Existing wizard Browse-folder screen (unchanged) | "Furphy could not find World of Warcraft automatically. Choose your WoW folder below." |
| WoW not found, `-Console`/`-Quiet` (`/S`, no `-WowPath` given) | `install.ps1` exits 2, relayed | (silent - no dialog; caller reads exit code 2) |
| WoW not found, wizard *construction itself* fails (rare) | `install.ps1`'s own fallback prints to its hidden console, exits 2; FurphySetup relays via its generic non-zero dialog | "Setup did not finish successfully (code 2). Nothing may have been installed. Try running the downloaded file again, or ask for help and mention this code." |
| **WoW found, wizard *construction itself* fails (rare)** | Newly traced, re-checked against `install.ps1:2789-2818`: this lands in the *same* `catch` block as the row above, but since `$wowFound` is true, `install.ps1` skips straight to `Invoke-FurphyInstallSteps; exit 0` - a real, complete install, with no console (never shown - Setup launches `-WindowStyle Hidden` and `Show-InstallConsole` is only ever called from the *success* path, `install.ps1:2806`, never this `catch` branch) and no wizard ever shown. Without section 4.2 step 11's fallback, a Setup-launched player would see the splash flash for up to ~5 seconds and then nothing - no success screen, no Open button, no sign the install (which genuinely succeeded) ever finished. Today's `Install Furphy.cmd` path is at least visible here (console inherited, never hidden, plus a trailing `pause`); a bare Setup.exe port of that same rare fallback would be silently *worse* than today, not equivalent. | Section 4.2 step 11's fallback `MessageBox`: "Furphy Addon Manager is installed. Look for the 'Furphy Addon Manager' shortcut on your Desktop to open it." |
| Install succeeds | Wizard's own success screen (unchanged); FurphySetup exits 0 | "Furphy Addon Manager is installed." |
| Wizard closed without clicking Install | `install.ps1` exits 0 (existing ambiguity, section 4.7) | (none - window simply closes) |
| Child `install.ps1` throws before reaching its own try/catch (very rare) | Non-zero, non-2 exit relayed via generic dialog | "Setup did not finish successfully (code \<N\>). Nothing may have been installed. Try running the downloaded file again, or ask for help and mention this code." |
| SmartScreen blocks the very first run | Standard OS dialog (section 3, step 3) - outside FurphySetup's own control | (OS text, not app text) |

-------------------------------------------------------------------------
## 11. Files and functions to change
-------------------------------------------------------------------------

**New files**

- `setup\FurphySetup.cs` - the bootstrapper (section 4).
- `setup\build-setup.ps1` - build script (section 6.1).
- `tests\integration\Setup.Build.Tests.ps1` - headless build test (12.1).
- `tests\integration\Setup.SilentInstall.Tests.ps1` - real `/S` scratch
  install test (12.2).
- `tests\integration\Setup.PayloadContents.Tests.ps1` - static embedded-
  payload identity check (12.3).
- `tests\unit\Setup.NoArpWrite.Tests.ps1` - static regression guard: no
  registry/shortcut-writing API surfaces inside `FurphySetup.cs` (12.4,
  the graft from the runner-up design's "exactly one ARP entry" idea,
  adapted to this design's own architecture - see 12.4 for why).

**Edited files**

- `install.ps1` - one line changed at 2806 (section 5.3): gate
  `Show-InstallConsole` on `$env:FURPHY_INSTALL_LAUNCHED_BY_SETUP`. One
  new comment near the existing `-Console`/`-Quiet` param-block comments
  (around line 60-88) documenting `FURPHY_INSTALL_LAUNCHED_BY_SETUP`'s
  meaning and that it is set by FurphySetup.exe only.
- `package.ps1` - Setup.exe build step, stable-name copy, sha256 sidecar,
  six-asset release reminder (section 6.2).
- `site\index.html` - primary download link, 3-step copy, safety-note text
  (section 7.1).
- `README.md` - Install section steps 1-4, `/S` line, zip-as-advanced-path
  line (section 7.2).
- `README.txt` - plain-text twin of the above (section 7.3).
- `DISTRIBUTION-SPEC.md` - new dated section 6.9 (section 7.4).
- `APP-UPDATE-SPEC.md` - one short cross-reference note in section 11
  ("FILES AND FUNCTIONS TO CHANGE"), under its existing `install.ps1`
  subsection (line ~1093 on, which already lists file:line-cited edits in
  this exact style) confirming the self-updater's own fixed
  `-Upgrade -Relaunch` command line (its own line 508) is unchanged and
  untouched by `/S` or by anything in this document; no functional
  change. (An earlier draft of this document said "near section 8.5 or
  11" - genuinely ambiguous between two different places; re-verified and
  resolved to section 11 specifically, since that section is the
  established home for exactly this kind of file:line-cited note.)

-------------------------------------------------------------------------
## 12. Test plan
-------------------------------------------------------------------------

**Important, newly-found fact affecting every test below that performs a
real, non-`-Uninstall` install at a non-production port:**
`Get-InstallStartupValueName` (`install.ps1:279-285`) - which
`Get-InstallAppsKeyName` (`install.ps1:308-311`) forwards to unchanged -
returns the literal `'FurphyAddonManager.Test'` for **every** non-production
port, with **no port number appended** and **no `Test-LooksLikeScratchRun`
path check at all** once the port is non-production (that path check only
runs at port 47831). This differs from `Get-InstallTrayStopEventName`
(`install.ps1:287-293`), which *does* append the port
(`'FurphyAddonManager.TrayStop.' + $port`). In plain terms: **two
concurrent scratch installs on two different test ports (say 47971 and
47975) still collide on the exact same HKCU Run value name and the exact
same Installed-Apps registry subkey name** - port allocation alone does
not isolate this one specific key. This is not new to this round - it is
already-known, pre-existing behavior (an incident dated 2026-09-06 14:45
in `tests\unit\Install.Scoping.Tests.ps1`'s own header comment describes
exactly this class of bug being fixed for the *production* key; the
existing mitigation for the *test* key across the whole suite today is
"only one test touches it at a time, with before/after snapshot diffing
against the real production key and immediate cleanup," e.g.
`tests\integration\Server.Uninstall.Tests.ps1:174-187`, never true
per-port isolation of `'FurphyAddonManager.Test'` itself). Any new test in
this section that reaches that code path must follow the same
established pattern - it does not get its own isolated key just by
picking a port in the 47970-47989 range, and it must not run concurrently
with another round's own test that also writes real values there.

### 12.1 Headless build test - `tests\integration\Setup.Build.Tests.ps1`

Runs `setup\build-setup.ps1` (or `package.ps1`'s Setup step directly) and
asserts: `dist\FurphyAddonManager-Setup-<ver>.exe` and
`dist\FurphyAddonManager-Setup.exe` both exist, are non-trivial size, and
start with the PE header magic bytes `MZ`; a `.sha256` sidecar exists for
the **versioned** exe only (mirroring `package.ps1`'s own established
convention, section 6.1) and, **after lowercasing both sides**
(`.ToLowerInvariant()`) before comparing, its content matches
`(Get-FileHash -Algorithm SHA256 -LiteralPath <exe>).Hash` of the exe.
The lowercasing is not optional boilerplate: `Get-FileHash`'s `.Hash`
property returns uppercase hex, but every sidecar this project writes is
lowercase (`package.ps1:177`'s own `.ToLowerInvariant()`, mirrored at
`tests\lib\common.ps1:678` and `addon-server.ps1:9472` - every hash
comparison site in this codebase normalizes case before comparing; a test
written without this line fails on every real run, permanently, for a
reason that has nothing to do with the build itself). Also assert, via
`[System.Diagnostics.FileVersionInfo]::GetVersionInfo(<exe path>)` on the
built exe, that `.ProductName`, `.FileDescription`, and `.ProductVersion`
are non-empty and match section 4.8's intended values - this is the only
place in the test plan that exercises the `AssemblyProduct`/
`AssemblyTitle`/`AssemblyDescription`/`__FURPHY_SETUP_VERSION__` token
substitution at all; without it, a silently-failed token swap or mangled
`Assembly*` attribute set (a genuinely new, unprecedented-in-this-codebase
technique - `host\FurphyHost.cs`/`build-host.ps1` set none of these,
confirmed by grep) would still pass every other check in this section. No
window opens, no registry touched, no WoW fixture needed. Safe to run any
time, on any machine, including while Eric is at the PC or in WoW.

### 12.2 `/S` scratch install test - `tests\integration\Setup.SilentInstall.Tests.ps1`

Before launching, set `$env:FURPHY_TEST_SETUP_MUTEX_SUFFIX` to a
test-run-unique value (its own scratch port or a fresh GUID) - see
section 4.2 step 3's re-check: FurphySetup.exe's own single-instance
mutex has no port to scope by on its own, and without this seam this
test's own launch can collide with a real interactive Setup.exe run or
with another round's own concurrently-running copy of this same test,
failing on an exit code (4) that has nothing to do with the code under
test.

Runs `FurphyAddonManager-Setup.exe /S -WowPath "<scratch fixture>" -NoShortcuts -NoProtocol -SkipAdopt`
against a scratch WoW-root fixture, on a port in the reserved
**47970-47989** range (via the fixture's own `settings.json`, same
mechanism every existing scratch-install test already uses - see
`Get-InstallPort`, `install.ps1:262-277`). Two isolation layers matter
here, and both need to hold:

1. **Path-based**: place the fixture under a path
   `Test-LooksLikeScratchRun` recognizes (`%TEMP%\...`, a `\scratch\`
   segment, or `\fixtures\wowroot\`) - this is *only* a safety net at
   production port 47831 (it makes the Run value and Installed-Apps key
   return `$null`/skip entirely, even on the production port, if the path
   looks like scratch) and is good hygiene regardless.
2. **Port-based**: use a port from 47970-47989 so the TrayStop event name
   and window title (which *are* port-scoped) never collide with the real
   production instance or with another round's own tests running on a
   different port.

Because of the fact called out at the top of this section, the ARP/Run-
value assertions in this test must reuse the codebase's own existing
before/after pattern: snapshot the **real** production Run value and
Installed-Apps key first (`Get-ProductionRunValue`/
`Get-ProductionInstalledAppsSnapshot`, `tests\lib\common.ps1`, already used
by `Server.Uninstall.Tests.ps1`), assert they are byte-identical after the
test, and clean up the shared `'FurphyAddonManager.Test'` key itself in a
`finally` block whether the test passes or fails - never assume it is
exclusively "this test's own" key.

Assert: exit code 0; `$appDest` tree matches the shape `-Console -Quiet`
already produces today (same files, same `VERSION`); the temp extraction
folder is gone afterward; the Setup process itself never showed a window
(no `Process.MainWindowHandle` poll matters for `/S` - none is attempted).
**Must run only when nothing else in this or another round's session is
concurrently exercising `'FurphyAddonManager.Test'`** - a live-safety rule
this section adds on top of the orchestrator's own existing rules, because
it was not true before this design and is not obvious from the port range
alone.

### 12.3 Static payload-contents check - `tests\integration\Setup.PayloadContents.Tests.ps1`

Headless, no execution of the exe at all. Load the built
`FurphyAddonManager-Setup-<ver>.exe` via
`[System.Reflection.Assembly]::LoadFrom` (from a **copy** in a scratch
temp path, never the `dist\` original, to avoid a file lock on a build
artifact another process may want to overwrite), call
`GetManifestResourceStream('FurphyPayload.zip')`, hash its bytes with
`Get-FileHash -Algorithm SHA256`, lowercase the result
(`.Hash.ToLowerInvariant()` - see 12.1's note: `Get-FileHash` returns
uppercase, every sidecar in this codebase is lowercase, and this
comparison fails every time without the conversion), and assert it equals
the (already-lowercase) content of
`dist\FurphyAddonManager-<ver>.zip.sha256` - proving the embedded payload
is byte-identical to the already-integrity-checked release zip, without
ever extracting or running anything. No window, no registry, no WoW
fixture.

### 12.4 Static "no ARP entry of its own" regression guard - `tests\unit\Setup.NoArpWrite.Tests.ps1`

The runner-up design's graft here was "assert exactly one Add/Remove
Programs entry exists after a real install/upgrade cycle" - a live
fixture-acceptance test appropriate to *that* design, where a third-party
installer framework's own default behavior is to register its own ARP
entry (making a live double-check the right-strength guard). **This
design's architecture makes that specific live test the wrong strength
tool**: FurphySetup.cs registers nothing of its own by construction (it
contains no `Registry`/`RegistryKey` or `WScript.Shell`/`CreateShortcut`
API calls at all), and reaching for a live install-and-count test would
mean taking on the exact registry-collision risk documented at the top of
this section for zero extra protection over a much cheaper alternative.

Adapted, correctly-strength version: a plain source-text regression test
against `setup\FurphySetup.cs` asserting it contains **no** occurrence of
`Registry.CurrentUser`, `RegistryKey`, `CreateSubKey`,
`Uninstall\\` (the ARP registry path fragment), or `CreateShortcut` /
`WshShell` (the shortcut-creation APIs `install.ps1` itself uses at line
2369-ish). If a future edit ever adds ARP or shortcut registration
directly to FurphySetup.cs - which would create exactly the "two entries"
risk the runner-up design's graft was guarding against - this test fails
immediately, with zero registry writes, zero window, and zero WoW fixture
needed. This is the adapted, correctly-scoped form of that graft for this
design.

### 12.5 Checks that need a real window - host layer only, idle-PC only

Two things in this design genuinely cannot be verified headlessly and
must not be attempted from an automated test at all, matching the
orchestrator's own live-safety rule ("never open a window from a test"):

- The splash-to-wizard **foreground handoff** (section 4.2 step 8, section
  9's DPI note) - requires a real interactive desktop session and visual
  confirmation.
- The **SmartScreen block itself** (section 3, step 3) - cannot be
  triggered or dismissed by any script; it is entirely OS/browser
  reputation-driven and requires a human clicking "More info" -> "Run
  anyway" on a real, freshly-downloaded copy.

Both belong only in a manual acceptance pass on a real machine when Eric
is available and the PC is otherwise idle (matching this project's
existing "Gates are manual now" policy) - never in any automated test
file, and never scripted around with a synthetic window-message injection
that would defeat the point of testing the real OS behavior.

-------------------------------------------------------------------------
## 13. Work packages for parallel fixers
-------------------------------------------------------------------------

**Concurrent-editing collision warning (not hypothetical - true right now
as this document is written):** a separate, simultaneously-running round
is actively editing `addon-server.ps1`, `install.ps1`, `host\FurphyHost.cs`,
`ui\`, `tests\`, and `package.ps1` in this same build root (self-update/
`-Upgrade`/`-Relaunch` work - see the drifted `addon-server.ps1` citation
fixed in section 5.5 as live proof: `install.ps1` was 2818 lines and
already contained that round's `Invoke-InstallStopRunningApp` (:1104),
`Invoke-InstallRelaunch` (:2010), and `Invoke-InstallRollbackAndRelaunchOld`
(:2061) at the moment this document was re-verified). Three of the five
packages below land in exactly those shared files:

- **Package B** edits `package.ps1`.
- **Package C** edits `install.ps1`.
- **Package E** edits `tests\...`.

The disjointness table below only proves these five packages don't
collide *with each other* - it says nothing about colliding with that
other, concurrent round. Every fixer on B, C, or E must re-read its
target file immediately before editing (not rely on line numbers already
in this document, which can drift again between this pass and when a
fixer actually opens the file), expect merge conflicts or an
already-moved line target, and treat a diff that doesn't match this
section's description as a signal to re-check the live file rather than
force the change through. This is in addition to, not a replacement for,
the live-safety/no-window rules below, which are unaffected by this risk.

Disjoint file sets, safe to run in parallel (see the warning above before
touching B, C, or E):

| Package | Files | Depends on |
|---|---|---|
| A - Setup bootstrapper | `setup\FurphySetup.cs`, `setup\build-setup.ps1` | Nothing else in this list (self-contained; needs only `icon.ico` and `VERSION`, both already read-only inputs). New files only - no collision with the concurrent round. |
| B - Packaging + release | `package.ps1` (Setup step, 6.2), the `gh release` recipe (6.3) | Package A's output file names (agree on `dist\FurphyAddonManager-Setup-<ver>.exe` naming up front; no need to wait for A's C# to be finished, only its output contract). Also shares `package.ps1` with the concurrent self-update round - re-read before editing. |
| C - Engine hand-off | `install.ps1` (the single line at 2806, section 5.3, plus one param-block comment) | Nothing else in *this* document's own package set - but `install.ps1` is the concurrent round's single most-edited file (see warning above); re-read line 2806 and the surrounding dispatch block immediately before editing, since the "one-line, self-contained" framing describes this document's own dependency graph, not the file's real-world edit traffic right now. |
| D - Docs and site | `site\index.html`, `README.md`, `README.txt`, `DISTRIBUTION-SPEC.md`, `APP-UPDATE-SPEC.md` (the one cross-reference note, placed in section 11 "FILES AND FUNCTIONS TO CHANGE" -> `install.ps1` subsection - resolves the "8.5 or 11" ambiguity from an earlier draft) | Nothing functionally, but should be written last so the exact copy in section 7 (already final in this document) doesn't need revising if A/B/C shift a detail |
| E - Tests | `tests\integration\Setup.Build.Tests.ps1`, `Setup.SilentInstall.Tests.ps1`, `Setup.PayloadContents.Tests.ps1`, `tests\unit\Setup.NoArpWrite.Tests.ps1` | Needs Package A's real output to exist for 12.1-12.3 to run meaningfully; 12.4 only needs `FurphySetup.cs`'s source text and can be written the moment Package A has a first draft. `tests\` is also being written into by the concurrent round (its own new Setup-adjacent and self-update test files) - use new, distinctly-named files only (as already planned) and re-read `tests\lib\common.ps1` before relying on any helper signature cited in section 12. |

**Live-safety / no-window rules, restated for every package (Eric may be
at the PC or in WoW at any time):**

- Never launch `FurphyAddonManager-Setup.exe` interactively (no `/S`) from
  any test or build script - that shows a real window and a real
  SmartScreen-adjacent flow. Interactive verification is manual-only
  (section 12.5).
- Never run `tests\run-all.ps1`. Never launch `FurphyHost.exe` or open any
  window from a test, per the orchestrator's standing rule.
- New tests use ports **47970-47989** only - and still must not assume
  that range alone isolates the shared `'FurphyAddonManager.Test'` HKCU
  key (section 12's opening note) from another concurrently-running
  round's own tests.
- Every real (non-static) test that reaches a registry write must use the
  existing before/after production-key-snapshot pattern
  (`tests\lib\common.ps1`'s `Get-ProductionRunValue`/
  `Get-ProductionInstalledAppsSnapshot`), never a bare "assert my own key
  exists" check.
- Package A/B/C/E may all touch `dist\` (build output) - coordinate on
  build-output file names (already fixed in this document, section 6) so
  no two packages fight over regenerating the same file mid-round.

-------------------------------------------------------------------------
## 14. Open questions for Eric
-------------------------------------------------------------------------

Only the two below are genuinely open - everything else this design
needed a call on (real version info baked into the exe, `/S` argument
pass-through, the zip's placement as a secondary/advanced link, the ARP
regression test's shape) has been decided directly in this document,
since each was an engineering-only call with a clearly correct answer
given the fixed decisions already handed down.

1. **Reopen paid signing now, or record "no signing" as settled?**
   DISTRIBUTION-SPEC.md 6.7's signing comparison table (Azure Trusted
   Signing ~$10/mo for instant reputation; SignPath.io free but
   CI-gated; Certum ~$25-40/yr, gradual reputation) was written when the
   only signable artifact would have been a hypothetical future EXE. That
   EXE now ships as of this round, and SmartScreen friction recurs on
   every release (section 9). Worth noting explicitly (re-checked against
   the file, same day, `DISTRIBUTION-SPEC.md:789`): 6.7's own decision
   text already named this exact trigger - "Revisit only if a downloaded
   EXE installer is ever shipped - Azure Trusted Signing is the pick
   then." This round's own design is precisely that trigger condition,
   not a fresh, unrelated question; this is not itself a reason to answer
   it "yes" (Eric may still prefer to hold at "no signing" a while longer
   and see whether SmartScreen friction becomes a real support burden in
   practice), only a reason not to pose it as though 6.7 never anticipated
   it. Should the new DISTRIBUTION-SPEC.md 6.9 entry (section 7.4) treat
   "no signing" as settled indefinitely, or flag Azure Trusted Signing as
   a near-term follow-up decision now that the cost of *not* signing is
   concrete and recurring rather than hypothetical?

2. **Pre-submit the built exe for an AV/EDR false-positive review before
   the first public release?** Section 9's cost write-up names the
   extract-embedded-zip-then-launch-hidden-`powershell.exe`-with-
   `-ExecutionPolicy Bypass` shape as a documented dropper heuristic
   pattern. A one-time submission to Microsoft Defender's file-submission
   portal (and optionally one or two other major AV vendors) before the
   very first release is a low-cost mitigation, but it does mean holding
   the release until a verdict comes back (typically same-day to a few
   days). Worth doing before the first ship, or accept the small
   false-positive risk and address it reactively only if it actually
   happens?

-------------------------------------------------------------------------
## 15. Appendix: second-pass critic items reviewed and rejected
-------------------------------------------------------------------------

This synthesis pass folded in every critic item that survived a fresh,
independent re-check against the actual files (concurrent-editing risk,
five file:line citation corrections, the hash-case test bug, the
unscoped-Mutex collision risk, the missing FileVersionInfo test coverage,
the silent-success dead-end user-journey gap and its fix, the two
README.md replacement-instruction bugs, the site/index.html
double-numbering bug, the DISTRIBUTION-SPEC.md 6.7 cross-reference, the
Edge multi-click hedge, the APP-UPDATE-SPEC.md location ambiguity, the
generic-error-dialog copy gap, and the DPI-awareness reconciliation gap -
see the sections above, each edited in place). One item did not survive
re-checking and is rejected below, with the evidence.

**Rejected: "no manifest is embedded, and the filename itself is a
documented UAC-elevation trigger" (the claim that section 4's design
lacks a `/win32manifest`/`requestedExecutionLevel` and is therefore
exposed to Windows' Installer Detection auto-elevation heuristic).**

This is empirically false for a build produced the way this design
already builds it, not merely unlikely. During this pass,
`host\bin\FurphyHost.exe` - already built in this repo, by the identical
mechanism (`Add-Type -TypeDefinition $src -CompilerParameters $cp` with
`/target:winexe`, no `/win32manifest` or `/nowin32manifest` flag either
way, `host\build-host.ps1:71-82`) that section 6.1 says
`setup\build-setup.ps1` will mirror for FurphySetup.exe - was inspected
directly for its embedded manifest. It contains one, automatically, with
no compiler flag requesting it:

```
<requestedExecutionLevel level="asInvoker" uiAccess="false"/>
```

This is `csc`'s own documented default behavior for a `winexe`/`exe`
target (a default manifest requesting `asInvoker`, embedded unless
`/nowin32manifest` explicitly suppresses it) - not something this design
opted into and not something it is missing. Windows' Installer Detection
heuristic requires *all three* of (a) unsigned, (b) no embedded
application manifest, and (c) a suspicious filename before it
auto-elevates; condition (b) is false by construction for any exe built
via this project's own established `Add-Type`/`CompilerParameters`
toolchain, filename notwithstanding, so the heuristic does not apply
regardless of `FurphyAddonManager-Setup.exe`'s name. The critic's broader
instinct - verify this rather than leave it assumed - was right and is
now satisfied with direct evidence rather than reasoning about compiler
defaults from memory; the specific technical claim and its proposed fix
(adding an explicit `/win32manifest`) are both rejected as unnecessary,
since section 9 already asserts the correct default-manifest behavior
and now cites this proof directly. See section 9's "No elevation, ever"
bullet for where this evidence now lives in the design itself.
