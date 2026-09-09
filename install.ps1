<#
=====================================================================
 install.ps1 - Furphy Addon Manager installer (E18, FLAVORS-SPEC S7.1)

 Finds a WoW installation, copies the app into <home-flavour>\AddonSync
 (Retail when present, else the first-detected flavour - FLAVORS-SPEC
 S2.1 order), creates a single "Furphy Addon Manager" desktop shortcut,
 registers the curseforge:// protocol handler, adopts any addon folders
 already present in each installed flavour's AddOns, and removes any
 launcher files/shortcuts a pre-Round-34 install left behind - all
 without requiring a CurseForge API key. Round 34: this installer no
 longer writes anything that launches or auto-updates-before-launching
 WoW - the background service (addon-server.ps1's tray/scheduled sync)
 already keeps addons updated on its own.

 Windows PowerShell 5.1 only. No modules, no external binaries, pure
 ASCII.

 USAGE:
   install.ps1 [-WowPath <path>] [-NoShortcuts] [-NoProtocol] [-SkipAdopt] [-Uninstall]

   -WowPath <path>   The WoW folder that CONTAINS the client folder(s)
                      (_retail_, _classic_, _classic_era_, etc - not one
                      of those folders itself). Overrides auto-detection.
                      Required when the installer cannot find WoW on its
                      own (a fresh test tree, an unusual drive layout, etc).
   -NoShortcuts      Skip creating desktop shortcuts. With -Uninstall,
                      also skips REMOVING desktop shortcuts (the real
                      Windows Desktop, never scoped to -WowPath - always
                      pass this when testing -Uninstall against a
                      test/scratch -WowPath so the real Desktop is left
                      alone).
   -NoProtocol       Skip registering the curseforge:// install-link handler.
   -SkipAdopt        Skip scanning AddOns and adopting untracked folders.
   -Uninstall        Remove the app files, shortcuts and protocol
                      registration. AddOns and addons.json/settings.json/
                      state.json/logs/backups (including every installed
                      flavour's own flavours\<id>\ subfolder) are left
                      alone. Also removes the "Start with Windows"
                      registration and stops a running background tray
                      (Round 18) before deleting files.

 Exit codes: 0 success, 2 could not find/validate a WoW folder.
=====================================================================
#>
param(
    [string]$WowPath,
    [switch]$NoShortcuts,
    [switch]$NoProtocol,
    [switch]$SkipAdopt,
    [switch]$Uninstall,
    # DISTRIBUTION-SPEC.md section 6.2/fix 6: forces the plain console flow,
    # skipping the WinForms install wizard entirely - never guesses, never
    # attempts Add-Type/Form construction at all. Every automated test in
    # this repo MUST pass this (a wizard run headless would call
    # ShowDialog(), which blocks forever with nothing to click). Also the
    # documented manual escape hatch for a machine where the wizard's
    # automatic construction-failure fallback (section 6.2) doesn't apply
    # cleanly for some other reason.
    [switch]$Console,
    # Round 33 defect fix: suppresses ONLY the final WinForms result
    # MessageBox that -Uninstall now shows by default (see the end of the
    # -Uninstall block below) - unlike -Console this does not force the
    # console install flow, it is meaningful on -Uninstall alone. Every
    # automated -Uninstall test in this repo passes -Console already,
    # which also suppresses the box (a headless test process must never
    # call MessageBox.Show and hang waiting for a click); -Quiet exists as
    # a second, narrower way to say the same thing for a caller that wants
    # console/wizard behavior untouched but still must not show a dialog
    # (none today, but the two are intentionally independent switches).
    [switch]$Quiet,
    # SETUP-SPEC.md section 5.3: NOT a param - an environment variable,
    # $env:FURPHY_INSTALL_LAUNCHED_BY_SETUP, set on this process by
    # FurphySetup.exe (the GUI bootstrapper) only, never by a manual
    # "Install Furphy.cmd" double-click and never by a normal caller.
    # Documented here, next to -Console/-Quiet, because it plays the same
    # "how was this run launched" role they do. Its only effect: gates the
    # Show-InstallConsole call near the end of this file, so a
    # Setup-launched run (started hidden via -WindowStyle Hidden, with
    # nothing waiting on its console the way Install Furphy.cmd's own
    # wrapping cmd.exe does) never un-hides its console right before exit
    # - which would otherwise flash a console window on screen at the very
    # end of an otherwise console-free install.
    # upgrade-1.1.0:upgrade-1.1.0-downgrade-hides-addons fix: bypasses the
    # downgrade guard in Invoke-FurphyInstallSteps (an OLDER installer run
    # over a NEWER on-disk install is refused by default, since the old
    # code cannot see flavours\<id>\addons.json and reports zero tracked
    # addons even though nothing was actually deleted). Never needed for a
    # normal install/upgrade/repair - only to deliberately install an
    # older release on purpose.
    [switch]$Force,
    # APP-UPDATE-SPEC.md section 8.5/11 (fixed command-line shape - never
    # renegotiate): set by the self-updater's own POST /api/app-update/
    # install caller (addon-server.ps1), which launches a STAGED
    # install.ps1 copy over the currently-running app. Backs up the
    # current code before copying (section 8.6), runs a post-install
    # health check, rolls back and relaunches the OLD version on any
    # failure, and relaunches per -Relaunch on success (section 8.7).
    # Never set by a normal manual install/repair.
    [switch]$Upgrade,
    # APP-UPDATE-SPEC.md section 8.7: which of the two run modes to bring
    # back after a passing -Upgrade - "window" (Addon Manager.vbs), "tray"
    # (host\bin\FurphyHost.exe --tray), or "none" (relaunch nothing - the
    # real HTTP route only ever sends "window"/"tray"; "none" exists so a
    # headless verification pass can exercise the file-level upgrade
    # without starting a window or tray on the machine running it). The
    # post-install health check (Invoke-InstallVerifyNewFiles) runs for
    # EVERY value here, "none" included - it uses its own short-lived
    # verification server rather than whatever -Relaunch starts, so it no
    # longer depends on a relaunch happening at all. Meaningless without
    # -Upgrade.
    [string]$Relaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$SourceRoot = $PSScriptRoot
if (-not $SourceRoot) { $SourceRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }

# Round 33 defect fix (item 3): $Script:UninstallLogPath is $null for the
# whole life of a normal install run (and stays $null right up until the
# -Uninstall block below sets it, a few lines into its own flow) - Write-
# InstallLogLine is therefore a silent no-op everywhere except inside an
# actual -Uninstall run, without needing a second parallel set of logging
# calls: hooking it into Write-Step/Write-Info/Write-Warn2 below means
# every existing call site throughout the whole uninstall sequence (the
# process-wait loops, the registry removals, every per-item removal
# failure, the final summary) already writes "every step and every
# failure" into the uninstall log for free, with zero new call sites to
# remember to add and keep in sync as the sequence changes.
$Script:UninstallLogPath = $null
function Write-InstallLogLine {
    param([string]$Message)
    if (-not $Script:UninstallLogPath) { return }
    try {
        $stamped = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $Message
        Add-Content -LiteralPath $Script:UninstallLogPath -Value $stamped -Encoding Ascii
    } catch {
        # Never let logging itself break the uninstall.
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
    Update-WizardProgress -Message $Message
    Write-InstallLogLine "== $Message =="
}
function Write-Info {
    param([string]$Message)
    Write-Host "  $Message"
    Update-WizardProgress -Message $Message
    Write-InstallLogLine "  $Message"
}
function Write-Warn2 {
    param([string]$Message)
    Write-Host "  WARNING: $Message" -ForegroundColor Yellow
    Update-WizardProgress -Message "WARNING: $Message"
    Write-InstallLogLine "  WARNING: $Message"
}

# DISTRIBUTION-SPEC.md section 6.2, fix 6 (chosen progress mechanism):
# every Write-Step/Write-Info/Write-Warn2 call above already runs
# unconditionally throughout the unchanged install steps - piggybacking the
# wizard's progress label + DoEvents() pump onto those exact same call
# sites means the install logic itself needs zero changes to report
# progress into the Form. $Script:WizardActive/$Script:WizardProgressLabel
# are $false/$null for the whole life of a console-only run (this function
# then does nothing beyond the immediate early return), and are set only
# from inside Show-InstallWizard's own Install-button click handler.
$Script:WizardActive = $false
$Script:WizardProgressLabel = $null
function Update-WizardProgress {
    param([string]$Message)
    if (-not $Script:WizardActive) { return }
    try {
        if ($Script:WizardProgressLabel) { $Script:WizardProgressLabel.Text = $Message }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        # Must never block/abort the install itself.
    }
}

# Round 20: independent, code-level heuristic (not caller discipline alone)
# that a given path looks like a scratch/test root rather than a real
# production install/WoW folder. Used only as a defense-in-depth guard
# before -Uninstall's Desktop-shortcut removal (see the CS-F5 incident
# note further down) - never used to change any other behavior.
function Test-LooksLikeScratchRun {
    param([string]$Path)
    if (-not $Path) { return $false }
    $p = $Path.ToLowerInvariant()
    $tempDir = $null
    try { $tempDir = [System.IO.Path]::GetTempPath() } catch { $tempDir = $null }
    if ($tempDir) {
        $tempDir = $tempDir.ToLowerInvariant().TrimEnd('\')
        if ($p.StartsWith($tempDir)) { return $true }
    }
    if ($p -match '\\scratch(\\|$)') { return $true }
    if ($p -match '\\fixtures\\wowroot(\\|$)') { return $true }
    return $false
}

# Security fix (security:security-install-uninstall-wowpath-arg-splitting):
# ported verbatim from addon-server.ps1's own ConvertTo-SafeProcessArg
# (that file's Round 20 adversarial bug pass) - wraps a single command-line
# argument in double quotes using CommandLineToArgvW-compatible backslash/
# quote escaping, so a value containing a literal space (the DEFAULT
# Windows WoW install path, "C:\Program Files (x86)\World of
# Warcraft\_retail_", included) can never be re-split into extra argv
# tokens by the relaunched child. Windows PowerShell 5.1's Start-Process
# -ArgumentList joins array elements with a bare, unquoted space before
# CreateProcess sees them - every element handed to a $relaunchArgs-style
# list in this file must be wrapped with this, not just the ones that used
# to be hand-quoted.
function ConvertTo-SafeProcessArg {
    param([string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2 + 1)) } else { [void]$sb.Append('\') }
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# novice:NOVICE-3 fix: true ONLY when -Path sits directly in the current
# user's %TEMP% AND its filename matches the disposable
# FurphyUninstall-<hex>.ps1 shape every real uninstall trigger copies this
# script to before launching it (the Settings > Uninstall button via
# addon-server.ps1's Handle-Uninstall, the Windows Apps & Features
# UninstallString/QuietUninstallString fallback in
# Get-InstallUninstallString below, this file's own relaunch-safety-net
# further down, and the tray's identical fallback in
# host\FurphyHost.cs's TryTrayUninstall). Used ONLY to gate the trailing
# self-delete step at the end of the -Uninstall block, so a developer
# running install.ps1 -Uninstall directly out of the source/app folder
# during testing is never affected - any other directory, or any other
# filename, always returns $false.
function Test-IsTempUninstallScriptCopy {
    param([string]$Path)
    if (-not $Path) { return $false }
    try {
        $tempDirNorm = [System.IO.Path]::GetTempPath().TrimEnd('\')
        $dirNorm = (Split-Path -Path $Path -Parent).TrimEnd('\')
        $name = Split-Path -Path $Path -Leaf
        return (($dirNorm -ieq $tempDirNorm) -and ($name -match '^FurphyUninstall-[0-9a-fA-F]+\.ps1$'))
    } catch {
        return $false
    }
}

# Round 32 (DISTRIBUTION-SPEC.md section 5.1): the Start-with-Windows value
# name and the tray stop-event name are scoped per install, mirroring the
# server's Get-StartupValueName / Get-TrayStopEventName and the host's
# _startupValueName / TrayProgram.ResolveStopEventName exactly:
#   production port 47831 -> 'FurphyAddonManager' / 'FurphyAddonManager.TrayStop'
#   any other port        -> 'FurphyAddonManager.Test' / 'FurphyAddonManager.TrayStop.<port>'
# A scratch/test root (Test-LooksLikeScratchRun) that still carries the
# default production port owns NEITHER name - the only registration and
# the only tray under the production names belong to the real install -
# so both functions return $null for it and the caller skips the step.
function Get-InstallPort {
    param([string]$AppDest)
    $port = 47831
    if (-not $AppDest) { return $port }
    $settingsFile = Join-Path -Path $AppDest -ChildPath 'settings.json'
    if (Test-Path -LiteralPath $settingsFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($settingsFile)
            if ($raw -match '"port"\s*:\s*(\d{2,5})') {
                $candidate = [int]$Matches[1]
                if ($candidate -ge 1024 -and $candidate -le 65535) { $port = $candidate }
            }
        } catch { }
    }
    return $port
}

function Get-InstallStartupValueName {
    param([string]$AppDest)
    $port = Get-InstallPort -AppDest $AppDest
    if ($port -ne 47831) { return 'FurphyAddonManager.Test' }
    if (Test-LooksLikeScratchRun -Path $AppDest) { return $null }
    return 'FurphyAddonManager'
}

function Get-InstallTrayStopEventName {
    param([string]$AppDest)
    $port = Get-InstallPort -AppDest $AppDest
    if ($port -ne 47831) { return ('FurphyAddonManager.TrayStop.' + $port) }
    if (Test-LooksLikeScratchRun -Path $AppDest) { return $null }
    return 'FurphyAddonManager.TrayStop'
}

# Round 33 (DISTRIBUTION-SPEC.md fix 3/section 5.4): the Installed-Apps
# registry subkey name uses the EXACT SAME literal as the Start-with-Windows
# Run value name computed above ("FurphyAddonManager" / "FurphyAddonManager.
# Test" / $null for a scratch run on the production port) - this is not a
# coincidence, it is fix 3's explicit instruction to reuse Get-
# InstallStartupValueName's scratch/null rule rather than re-deriving the
# same scoping decision a second time in a second function that could drift
# out of sync with it. Kept as its own named function (not just called
# directly at each call site) so both call sites - the writer at the end of
# a normal install and the remover in -Uninstall - read the same one name
# from the same one place, and so a unit test can assert on this specific
# registry-key-name contract by name, independent of the Run-value one ever
# changing for an unrelated reason.
function Get-InstallAppsKeyName {
    param([string]$AppDest)
    return Get-InstallStartupValueName -AppDest $AppDest
}

# DISTRIBUTION-SPEC.md section 5.4: EstimatedSize (KB) for the Installed-Apps
# key - a plain recursive file-size sum, rounded to the nearest KB. Never
# throws (a missing/unreadable path is worth 0, not a fatal install error);
# 0 is also exactly right for "install just started, nothing copied yet"
# callers, if this is ever called that early.
function Get-InstallEstimatedSizeKB {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { return 0 }
        return [int][math]::Round($sum / 1024)
    } catch {
        return 0
    }
}

# DISTRIBUTION-SPEC.md section 5.4: builds the ONE command line used for both
# UninstallString and QuietUninstallString - "try the server, else copy the
# bundled install.ps1 to %TEMP% and launch it" (section 5.3's invariant),
# so Windows' own Settings > Apps entry is a third caller of the identical
# converging mechanism the tray (2.2) and Settings' own button (3.4) already
# use, not a special case. Pure string composition - never touches the
# registry, the filesystem, or the network itself; the caller (Invoke-
# FurphyInstallSteps) is what writes the returned string into the registry.
function Get-InstallUninstallString {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$AppDest,
        [Parameter(Mandatory = $true)][string]$WowRootPath
    )
    # Single-quoted PowerShell string literals throughout the inner
    # -Command body (never double quotes) so the whole thing can be wrapped
    # in one outer -Command "..." with nothing inside it that needs
    # escaping against that outer double-quote - the one exception is a
    # literal single quote that could appear INSIDE a path itself, doubled
    # per PowerShell's own single-quote escaping rule (''), defensively,
    # even though no WoW/Furphy install path is expected to ever contain one.
    $originUrl = "http://localhost:$Port"
    $apiUrl = "http://localhost:$Port/api/uninstall"
    $installPs1 = Join-Path -Path $AppDest -ChildPath 'install.ps1'
    $installPs1Esc = $installPs1.Replace("'", "''")
    $wowRootEsc = $WowRootPath.Replace("'", "''")

    # Security fix (security:security-install-uninstall-wowpath-arg-
    # splitting): the fallback's Start-Process used to build -ArgumentList
    # as a comma-separated PowerShell array literal
    # ('-NoProfile','-ExecutionPolicy',...,'-WowPath','$wowRootEsc',...) -
    # Windows PowerShell 5.1 joins array elements with a bare, unquoted
    # space before CreateProcess sees them, so a WoW root containing a
    # space (the DEFAULT Windows install path, "C:\Program Files
    # (x86)\World of Warcraft\_retail_") got split into multiple argv
    # tokens by the relaunched child, truncating -WowPath. Fixed by having
    # the INNER script (the one that actually runs later, when this
    # returned command line is executed) build ONE pre-quoted argument
    # STRING instead, mirroring host\FurphyHost.cs's RunUninstallSequence
    # which already gets this right for the identical fallback. The inner
    # script builds its double quotes via [char]34 at ITS OWN runtime
    # (never as a literal " character here) so this file's own single-
    # quoted-only convention for the outer -Command "..." wrapper still
    # holds - no new escaping is needed against that outer double-quote.
    $inner = "try { Invoke-RestMethod -Method Post -Uri '$apiUrl' -TimeoutSec 2 -Headers @{Origin='$originUrl'} } catch { `$t = Join-Path `$env:TEMP ('FurphyUninstall-' + [guid]::NewGuid() + '.ps1'); Copy-Item '$installPs1Esc' `$t; `$q = [char]34; `$fArgs = '-NoProfile -ExecutionPolicy Bypass -File ' + `$q + `$t + `$q + ' -WowPath ' + `$q + '$wowRootEsc' + `$q + ' -Uninstall'; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `$fArgs }"

    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $inner + '"'
}

# DISTRIBUTION-SPEC.md fix 9: mirrors host\FurphyHost.cs's AppConstants.
# WindowTitleFor(port) exactly (production port -> the bare literal, any
# other port -> a "[test <port>]"-suffixed title) - duplicated here per the
# codebase's own established "every shared fact lives in each file that
# needs it" convention (the same reasoning already used for
# Test-LooksLikeScratchRun/$Script:FlavourDefs above). Computing this from
# THIS install's own port (never a hardcoded literal) is what makes it safe
# to WM_CLOSE-by-title from inside -Uninstall: a scratch/test install can
# never resolve to the one title a real, live production window would be
# using.
function Get-InstallWindowTitle {
    param([int]$Port)
    if ($Port -eq 47831) { return 'Furphy Addon Manager' }
    return "Furphy Addon Manager [test $Port]"
}

$Script:FurphyWin32Loaded = $false
function Initialize-InstallWin32Type {
    <# Add-Type is not safe to call twice for the same type name in one
       process - guard so both Close-InstallMainWindow and
       Hide-InstallConsole (and a caller that somehow triggers both) never
       double-register it. #>
    if ($Script:FurphyWin32Loaded) { return }
    if (-not ('FurphyInstall.Win32' -as [type])) {
        Add-Type -Namespace FurphyInstall -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);

[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
    }
    $Script:FurphyWin32Loaded = $true
}

function Close-InstallMainWindow {
    <#
      DISTRIBUTION-SPEC.md fix 9/section 5.3 step 3: the ONE WM_CLOSE-by-
      window-title implementation in the whole project - best-effort asks
      any open Furphy MAIN WINDOW carrying THIS install's own port-scoped
      title (Get-InstallWindowTitle) to close, before the existing
      FurphyHost-process wait loop starts waiting. Never throws; a missing
      window (nothing open, or a different port's window) is a silent
      no-op - this must never block or fail the rest of -Uninstall.
    #>
    param([int]$Port)
    try {
        Initialize-InstallWin32Type
        $title = Get-InstallWindowTitle -Port $Port
        # PowerShell marshals a bare $null onto a .NET string parameter as
        # an empty string, not a true null reference - FindWindow then
        # searches for a window with an EMPTY class name and never matches
        # anything real. [NullString]::Value marshals as a genuine null
        # pointer, matching any class name, exactly like C#'s own literal
        # `null` does at the call sites in host\FurphyHost.cs.
        $hwnd = [FurphyInstall.Win32]::FindWindow([NullString]::Value, $title)
        if ($hwnd -ne [IntPtr]::Zero) {
            $WM_CLOSE = 0x0010
            [FurphyInstall.Win32]::PostMessage($hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Write-Info 'Asked the open Furphy window to close.'
        }
    } catch {
        # Best-effort only.
    }
}

function Hide-InstallConsole {
    <# DISTRIBUTION-SPEC.md fix 6: hide THIS process's own console window,
       called only after Show-InstallWizard's Form has been fully
       constructed (never before - see that function's own comment). #>
    try {
        Initialize-InstallWin32Type
        $SW_HIDE = 0
        $hwnd = [FurphyInstall.Win32]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [FurphyInstall.Win32]::ShowWindow($hwnd, $SW_HIDE) | Out-Null
        }
    } catch {
        # Best-effort only - a failure here must never block the install;
        # worst case the console just stays visible behind the Form.
    }
}

function Show-InstallConsole {
    <#
      Undoes Hide-InstallConsole - called once the wizard's own Form has
      closed (success or error screen dismissed), right before this
      process exits. Necessary because powershell.exe -File, launched from
      "Install Furphy.cmd" (a plain .cmd double-click, the documented
      novice path), shares its PARENT cmd.exe's own console window rather
      than owning a private one - hiding it hides that SAME window for the
      wrapping .cmd too, so without this, the .cmd's trailing `pause` line
      would sit waiting for a keypress inside a window nobody can see,
      leaving an orphaned process behind forever. Safe/harmless to call
      even when the console was never hidden in the first place (Console
      mode, or a Form-construction failure that never called Hide-
      InstallConsole at all).
    #>
    try {
        Initialize-InstallWin32Type
        $SW_SHOW = 5
        $hwnd = [FurphyInstall.Win32]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [FurphyInstall.Win32]::ShowWindow($hwnd, $SW_SHOW) | Out-Null
        }
    } catch {
        # Best-effort only.
    }
}

# =====================================================================
# FLAVORS-SPEC S2.1: the same fixed-order table addon-sync.ps1/
# addon-server.ps1 carry as $Script:FlavourDefs, duplicated here per the
# codebase's existing established pattern (every shared fact lives in
# each file that needs it, never a cross-file import). install.ps1 only
# needs the folder/label/first-class facts - never client build numbers,
# never a Battle.net product code (Round 34 removed WoW-launching
# entirely, see REMOVAL-SPEC.md CS-R10) - so this is a deliberately
# smaller table than the CLI/server copies (no Product/.build.info
# field).
#
# FirstClass mirrors S2.1's "First-class in v1?" column: only Retail,
# Classic and Classic Era are eligible for legacy-shortcut cleanup
# naming (Remove-FurphyLegacyLauncherArtifacts below) and are checked
# first when picking the home flavour for the app's own install.
# PTR/XPTR/Beta are still detected (Find-WowRoot,
# Get-InstalledFlavourDefs) so a PTR-only machine can still be found
# and so the adopt step (S7.1) can offer to take over a PTR AddOns
# folder too.
# =====================================================================

$Script:FlavourDefs = @(
    [PSCustomObject]@{ Id = 'retail';      Folder = '_retail_';      Label = 'Retail';      FirstClass = $true }
    [PSCustomObject]@{ Id = 'classic';     Folder = '_classic_';     Label = 'Classic';     FirstClass = $true }
    [PSCustomObject]@{ Id = 'classic_era'; Folder = '_classic_era_'; Label = 'Classic Era'; FirstClass = $true }
    [PSCustomObject]@{ Id = 'ptr';         Folder = '_ptr_';         Label = 'PTR';         FirstClass = $false }
    [PSCustomObject]@{ Id = 'xptr';        Folder = '_xptr_';        Label = 'PTR (2)';     FirstClass = $false }
    [PSCustomObject]@{ Id = 'beta';        Folder = '_beta_';        Label = 'Beta';        FirstClass = $false }
)

function Test-FlavourInstalled {
    <# FLAVORS-SPEC S2.2: installed = <WowRoot>\<folder>\Interface\AddOns
       exists (need not contain any addon yet). No .build.info check here
       - see the file-header note on why install.ps1's table omits it. #>
    param([string]$WowRootPath, [string]$Folder)
    if (-not $WowRootPath -or -not $Folder) { return $false }
    return (Test-Path -LiteralPath (Join-Path -Path $WowRootPath -ChildPath "$Folder\Interface\AddOns") -PathType Container)
}

function Get-InstalledFlavourDefs {
    <# FLAVORS-SPEC S2.3: every known flavour folder under $WowRootPath
       that passes Test-FlavourInstalled, in S2.1's fixed order. Never
       throws; returns an empty list when $WowRootPath itself doesn't
       resolve or nothing is found - callers treat that as "could not
       find WoW", same fatal path as today. #>
    param([string]$WowRootPath)
    $result = New-Object 'System.Collections.Generic.List[object]'
    if ($WowRootPath) {
        foreach ($def in $Script:FlavourDefs) {
            if (Test-FlavourInstalled -WowRootPath $WowRootPath -Folder $def.Folder) {
                $result.Add($def)
            }
        }
    }
    # Round 36: PowerShell unrolls whatever a function writes to the pipeline,
    # so a WoW root with exactly ONE installed client (a retail-only machine -
    # the most common case) used to come back as a bare PSCustomObject whose
    # .Count is empty; Find-WowRoot's `.Count -gt 0` check then failed and a
    # fresh install ended with "Could not find a World of Warcraft
    # installation". The fix lives at the CALL SITES: every caller wraps this
    # in @(...) (0 items -> empty array, 1 -> one-element array, N -> array),
    # the same defensive pattern this file already uses for
    # $script:firstClassInstalled. (Write-Output -NoEnumerate was tried and
    # rejected: an empty array emitted that way arrives as ONE object, so
    # @(...) would count 1 for a root with no clients.) Regression test:
    # tests\integration\Install.SingleFlavour.Tests.ps1.
    return $result.ToArray()
}

# =====================================================================
# 1. Find the WoW folder
#    FLAVORS-SPEC S7.1: generalized from "must contain _retail_" to
#    "must contain any known flavour folder with Interface\AddOns" -
#    reuses Get-InstalledFlavourDefs so this test lives in one place.
#    This directly unblocks a Classic-only or Classic-Era-only machine.
# =====================================================================

function Find-WowRoot {
    param([string]$Override)

    if ($Override -and ($Override.Trim().Length -gt 0)) {
        return $Override
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'

    try {
        $regPaths = @(
            'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
            'HKCU:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
            'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft',
            'HKCU:\SOFTWARE\Blizzard Entertainment\World of Warcraft'
        )
        foreach ($rp in $regPaths) {
            if (Test-Path -LiteralPath $rp) {
                $prop = Get-ItemProperty -LiteralPath $rp -ErrorAction SilentlyContinue
                if ($prop -and $prop.InstallPath) { $candidates.Add([string]$prop.InstallPath) }
            }
        }
    } catch {
        # Registry probing is best-effort; the fixed-path/drive-scan fallbacks below still run.
    }

    $candidates.Add('C:\Program Files (x86)\World of Warcraft')
    $candidates.Add('C:\World of Warcraft')

    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq 'Fixed' -and $drive.IsReady) {
                $candidates.Add((Join-Path -Path $drive.RootDirectory.FullName -ChildPath 'World of Warcraft'))
            }
        }
    } catch {
        # Drive enumeration is best-effort too.
    }

    foreach ($c in $candidates) {
        if ($c -and @(Get-InstalledFlavourDefs -WowRootPath $c).Count -gt 0) {
            return $c
        }
    }

    return $null
}

# Dot-source guard (round 32, same pattern as addon-sync.ps1/addon-server.ps1):
# when this file is dot-sourced by a unit test (". .\install.ps1") only the
# functions above are defined and nothing below runs - no WoW detection, no
# copying, no registry, no uninstall. $MyInvocation.InvocationName is the
# literal "." when dot-sourced; the $MyInvocation.Line check is a fallback.
$script:FurphyDotSourced = ($MyInvocation.InvocationName -eq '.') -or ($MyInvocation.Line -match '^\s*\.\s')
if ($script:FurphyDotSourced) { return }

$wowRoot = Find-WowRoot -Override $WowPath
$installedFlavours = New-Object 'System.Collections.Generic.List[object]'
if ($wowRoot) { $installedFlavours = @(Get-InstalledFlavourDefs -WowRootPath $wowRoot) }
# DISTRIBUTION-SPEC.md section 6.2: a plain install run (not -Uninstall,
# not -Console) no longer exits 2 immediately on "not found" - it falls
# through to Show-InstallWizard further down, whose own folder-picker
# screen is exactly this same recovery path, just graphical instead of a
# console message. -Uninstall and -Console both need a resolved $appDest
# right now (uninstall never shows a wizard at all; -Console is the
# explicit "skip the wizard entirely" escape hatch, including for every
# automated test in this repo - a wizard run headless would call
# ShowDialog() and hang forever with nothing to click), so both still fail
# fast here exactly as before this round.
$wowFound = ($wowRoot -and $installedFlavours.Count -gt 0)
if (-not $wowFound -and ($Uninstall -or $Console)) {
    Write-Host ''
    if (-not $wowRoot) {
        Write-Host 'ERROR: Could not find a World of Warcraft installation.' -ForegroundColor Red
    } else {
        Write-Host "ERROR: No known WoW client folder (with Interface\AddOns) was found under $wowRoot." -ForegroundColor Red
    }
    Write-Host '       Pass -WowPath "<your WoW folder>" (the one that contains _retail_, _classic_, _classic_era_, etc).' -ForegroundColor Red
    exit 2
}

function Set-InstallPathsFromWowRoot {
    <#
      (Re)computes every path derived from $script:wowRoot/
      $script:installedFlavours - $homeFlavour, $homeDir, $addonsPath,
      $appDest, $firstClassInstalled, $multiFlavour - into script scope.
      Called once below for the normal top-to-bottom console/-Uninstall
      flow, and again from Show-InstallWizard's own Browse-folder handler
      if the user picks a WoW folder there (auto-detection found nothing,
      or the user wants a different one) - keeping this computation in one
      function is what lets both callers stay byte-identical instead of
      two copies of the same five lines drifting apart.

      FLAVORS-SPEC S3.1: home flavour = Retail when installed (upgrade
      path, byte-identical to every machine that has it today); otherwise
      the first-detected flavour in S2.1's fixed order
      (Get-InstalledFlavourDefs already returns its list in that order, so
      $installedFlavours[0] IS that first-detected flavour whenever Retail
      is absent). $firstClassInstalled/$multiFlavour (Retail/Classic/
      Classic Era - S2.1's "first-class") drive only the install-message
      wording ("home flavour: X" when more than one is installed) and
      legacy-shortcut cleanup naming now that Round 34 removed the
      per-flavour launcher pair/shortcut this used to gate - PTR/XPTR/
      Beta stay detected-but-quiet here exactly as they do everywhere
      else (S2.5).
    #>
    $script:homeFlavour = $null
    foreach ($f in $script:installedFlavours) { if ($f.Id -eq 'retail') { $script:homeFlavour = $f; break } }
    if (-not $script:homeFlavour) { $script:homeFlavour = $script:installedFlavours[0] }

    $script:homeDir = Join-Path -Path $script:wowRoot -ChildPath $script:homeFlavour.Folder
    $script:addonsPath = Join-Path -Path $script:homeDir -ChildPath 'Interface\AddOns'
    $script:appDest = Join-Path -Path $script:homeDir -ChildPath 'AddonSync'

    $script:firstClassInstalled = @($script:installedFlavours | Where-Object { $_.FirstClass })
    $script:multiFlavour = ($script:firstClassInstalled.Count -gt 1)
}

if ($wowFound) {
    # -Uninstall and -Console both need this resolved right away (see the
    # check above); a plain wizard-eligible run with WoW already
    # auto-detected also resolves it now, purely so Show-InstallWizard has
    # an initial path to show/offer - its Browse handler still calls this
    # again if the user changes it.
    Set-InstallPathsFromWowRoot
}

# =====================================================================
# Round 33 defect fix: WebView2-children-outlive-FurphyHost.exe uninstall
# leftover (DISTRIBUTION-SPEC.md fix 9 follow-up).
#
# Reproduced 2/2 with a REAL scratch host window open: Close-
# InstallMainWindow's WM_CLOSE and the pre-existing $trayExePath-only wait
# loop above both only ever watch the FurphyHost.exe PROCESS - never its
# WebView2 child processes (msedgewebview2.exe renderer/gpu/crashpad/
# network, spawned under host\bin\FurphyHost.exe.WebView2\EBWebView).
# Those children can still be unwinding and holding file/profile-folder
# locks for a short window after FurphyHost.exe itself has already
# exited, which is exactly what made the single Remove-Item -Recurse
# -Force on the whole host\ folder below throw, get swallowed into
# $failedRemovals, and leave ~1 MB of app files (plus a fresh
# host\bin\FurphyHost.exe.WebView2 profile folder) behind on the two most
# common real uninstall paths (from the app, from the tray while the
# window is open).
# =====================================================================

function Get-InstallLiveAppDestProcesses {
    <#
      Every FurphyHost.exe (tray OR a main window - any FurphyHost.exe
      whose own exe path resolves under $AppDest, not just one specific
      known path), every msedgewebview2.exe child spawned FOR this
      install (matched by --user-data-dir on its own command line
      containing $AppDest), AND (fresh-zip:novice-uninstall-orphans-
      addon-server fix) every plain powershell.exe/pwsh.exe process
      whose own command line references THIS install's own
      "$AppDest\addon-server.ps1" - the background HTTP server Addon
      Manager.vbs spawns on first open and (per README) deliberately
      leaves running after the app window closes, so "minimizing the app
      and coming back to it later reconnects on its own". That server is
      a different process image entirely from FurphyHost.exe, so before
      this fix a caller that only ever asked for FurphyHost.exe/
      msedgewebview2.exe here (i.e. every install.ps1 -Uninstall run
      invoked directly, rather than through a live server's own POST
      /api/uninstall self-shutdown) never saw it, never waited for it,
      and left it running indefinitely after deleting its own script
      file out from under it. Read-only - never touches a process whose
      own path/command-line does not resolve under $AppDest, so a real
      production tray/window/server running from an entirely different
      install (or an unrelated powershell.exe elsewhere on the machine,
      this very install.ps1 process included) is never matched here: the
      powershell.exe/pwsh.exe branch requires BOTH "addon-server.ps1"
      AND this exact $AppDestNorm to appear in that process's own
      command line, never a bare "any powershell.exe" match.
    #>
    param([Parameter(Mandatory = $true)][string]$AppDestNorm)
    $found = New-Object 'System.Collections.Generic.List[object]'
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='FurphyHost.exe' OR Name='msedgewebview2.exe' OR Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue
    } catch {
        $procs = $null
    }
    if (-not $procs) { return $found }
    foreach ($p in $procs) {
        try {
            if ($p.Name -eq 'FurphyHost.exe') {
                $exePath = [string]$p.ExecutablePath
                if ($exePath -and $exePath.ToLowerInvariant().Contains($AppDestNorm)) { $found.Add($p) }
            } elseif ($p.Name -eq 'msedgewebview2.exe') {
                $cmd = [string]$p.CommandLine
                if ($cmd -and $cmd.ToLowerInvariant().Contains('--user-data-dir') -and $cmd.ToLowerInvariant().Contains($AppDestNorm)) {
                    $found.Add($p)
                }
            } elseif ($p.Name -eq 'powershell.exe' -or $p.Name -eq 'pwsh.exe') {
                $cmd = [string]$p.CommandLine
                if ($cmd -and $cmd.ToLowerInvariant().Contains('addon-server.ps1') -and $cmd.ToLowerInvariant().Contains($AppDestNorm)) {
                    $found.Add($p)
                }
            }
        } catch {
            # A process that exited between the CIM query and here, or an
            # access-denied read - either way, not something to act on.
        }
    }
    return $found
}

function Invoke-InstallServerShutdown {
    <#
      fresh-zip:novice-uninstall-orphans-addon-server fix - best-effort
      GRACEFUL stop for the background addon-server.ps1 process this
      install owns, tried BEFORE Wait-InstallHostAndWebView2Exit's own
      wait/force-kill loop below ever runs. POSTs the exact same
      /api/shutdown route the tray/Settings/Installed-Apps uninstall
      paths already reach through a live server (Handle-Shutdown,
      addon-server.ps1) - the server answers 200 then sets
      $Script:ShuttingDown and exits its own main loop cleanly on its
      own, same as a graceful in-app close. Same Origin-header pattern
      Get-InstallUninstallString already builds for the Windows Apps &
      Features UninstallString case, reused here rather than
      reinvented.

      Fire-and-forget: a short 2-second timeout, and every failure (no
      server listening on this port, a job genuinely still running
      [409], or any other network hiccup) is swallowed silently -
      Wait-InstallHostAndWebView2Exit's own poll-then-force-kill loop
      immediately after this call is what actually guarantees the
      process is gone either way, so this is only here to give it the
      chance to exit cleanly first, without a hard kill, whenever it
      can. Never throws.
    #>
    param([Parameter(Mandatory = $true)][string]$AppDest)
    try {
        $port = Get-InstallPort -AppDest $AppDest
        $originUrl = "http://localhost:$port"
        $apiUrl = "http://localhost:$port/api/shutdown"
        Invoke-RestMethod -Method Post -Uri $apiUrl -TimeoutSec 2 -Headers @{ Origin = $originUrl } -ErrorAction Stop | Out-Null
    } catch {
        # No server listening on this port, a job genuinely still running
        # (409), or any other network hiccup - the wait/force-kill loop
        # this function's caller runs immediately after is what actually
        # guarantees the process is gone.
    }
}

function Wait-InstallHostAndWebView2Exit {
    <#
      Waits (polling every $PollMs, up to $TimeoutMs total - defaults 300ms/
      20s per the task brief) for every live FurphyHost.exe,
      msedgewebview2.exe, AND (fresh-zip:novice-uninstall-orphans-addon-
      server fix) this install's own addon-server.ps1 process under
      $AppDest (Get-InstallLiveAppDestProcesses) to exit on their own,
      called AFTER Close-InstallMainWindow and the pre-existing
      $trayExePath wait loop above, and BEFORE the file-removal loop
      below ever touches host\ or the app's own script files.

      Starts by giving the background server one graceful, best-effort
      chance to self-shutdown (Invoke-InstallServerShutdown, POST
      /api/shutdown) before falling into the poll loop below - the same
      graceful route a live server's own POST /api/uninstall already
      gets, now also reached by a direct install.ps1 -Uninstall run
      (which has no other way to talk to that already-running process).

      If anything is still alive once the timeout elapses, force-
      terminates ONLY those specific pids (Stop-Process -Force - safe
      because they are Furphy's own child processes for THIS install and
      the user already confirmed the uninstall), then waits once more,
      briefly, for the kill to actually release file handles before
      returning. Never throws - a failure to enumerate or kill is logged
      as a warning and the removal loop's own per-item retry (Remove-
      InstallFileWithRetry/Remove-InstallFolderWithRetry) is what actually
      protects the removal itself if a lock somehow still outlives this.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [int]$TimeoutMs = 20000,
        [int]$PollMs = 300,
        [int]$SettleTimeoutMs = 3000
    )
    $appDestNorm = $AppDest.TrimEnd('\').ToLowerInvariant()

    Invoke-InstallServerShutdown -AppDest $AppDest

    $waitedMs = 0
    $remaining = Get-InstallLiveAppDestProcesses -AppDestNorm $appDestNorm
    while ($remaining.Count -gt 0 -and $waitedMs -lt $TimeoutMs) {
        Start-Sleep -Milliseconds $PollMs
        $waitedMs += $PollMs
        $remaining = Get-InstallLiveAppDestProcesses -AppDestNorm $appDestNorm
    }

    $forceKilled = New-Object 'System.Collections.Generic.List[string]'
    if ($remaining.Count -gt 0) {
        Write-Warn2 "$($remaining.Count) Furphy process(es) under $AppDest still running after $([int]($TimeoutMs/1000))s - closing them:"
        foreach ($p in $remaining) {
            $label = "$($p.Name) (pid $($p.ProcessId))"
            try {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
                Write-Warn2 "  Terminated $label"
                $forceKilled.Add($label)
            } catch {
                Write-Warn2 "  Could not terminate $label - $($_.Exception.Message)"
            }
        }
        $settledMs = 0
        while ($settledMs -lt $SettleTimeoutMs) {
            Start-Sleep -Milliseconds 250
            $settledMs += 250
            if ((Get-InstallLiveAppDestProcesses -AppDestNorm $appDestNorm).Count -eq 0) { break }
        }
    } else {
        Write-Info 'Host window, background server, and any WebView2 child processes have exited.'
    }

    return [PSCustomObject]@{ ForceKilled = $forceKilled }
}

function Remove-InstallFileWithRetry {
    <#
      Removes a single file (or empty directory - Remove-Item -Force works
      on both with no -Recurse needed) with retry+backoff instead of
      failing on the first locked-file error: 5 attempts total, waiting
      300/600/1200/2400/4800 ms between them (item 2 of the fix - a
      WebView2 child's lock is typically released within the first second
      or two of Wait-InstallHostAndWebView2Exit above already having run,
      so this is defense-in-depth for a lock from something else
      entirely, e.g. AV/indexer/OneDrive momentarily opening the file).
      Returns $true once removed, $false if it is still locked after every
      attempt.

      Round-33-fixer-round-2: Remove-Item throwing is NOT proof the target
      is still locked - a WebView2/Chromium profile lockfile (and similar
      delayed/pending-delete files) can vanish on its own, out from under
      us, between our Test-Path-free attempts, in which case Remove-Item
      throws ItemNotFoundException ("Cannot find path ... because it does
      not exist") even though nothing is actually wrong. The real goal is
      "the path is gone", not "we personally deleted it" - so after EVERY
      throw (not just the last), check whether the path has already
      disappeared (by us, by the OS, by whatever else) and treat that as
      success before deciding whether to retry or give up. A path that is
      still genuinely present (still locked) falls through unchanged to
      the existing retry/fail behavior.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $delays = @(300, 600, 1200, 2400, 4800)
    for ($attempt = 0; $attempt -le $delays.Count; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return $true
        } catch {
            if (-not (Test-Path -LiteralPath $Path)) {
                # Already gone - whoever/whatever removed it, the goal is met.
                return $true
            }
            if ($attempt -ge $delays.Count) {
                Write-InstallLogLine "  FAILED to remove after $($delays.Count + 1) attempts: $Path - $($_.Exception.Message)"
                return $false
            }
            Start-Sleep -Milliseconds $delays[$attempt]
        }
    }
    return $false
}

function Remove-InstallFolderWithRetry {
    <#
      Removes a directory tree file-by-file rather than one single
      Remove-Item -Recurse -Force on the whole tree (item 2 of the fix -
      this IS the root cause of the round-33 defect: one file the
      WebView2 loader/a crashpad process still briefly held open under
      host\ made the old single Remove-Item throw and abandon the ENTIRE
      folder, exe/DLLs/lib/sources and all, not just that one file).
      Enumerates every file first and removes each with Remove-
      InstallFileWithRetry, then removes now-empty subdirectories
      deepest-first (also with retry), then the top folder itself.
      Returns the list of paths (files, subfolders, or the top folder)
      that could not be removed - empty means the whole tree is gone.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $leftover = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path)) { return $leftover }

    try {
        $allFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
    } catch {
        $allFiles = @()
    }
    foreach ($f in $allFiles) {
        if (-not (Remove-InstallFileWithRetry -Path $f.FullName)) {
            $leftover.Add($f.FullName)
        }
    }

    try {
        # Deepest-first (longest path first) so a child folder is always
        # attempted, and confirmed empty or added to $leftover, before its
        # own parent is ever attempted.
        $allDirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending)
    } catch {
        $allDirs = @()
    }
    foreach ($d in $allDirs) {
        $stillHasChildren = $false
        try {
            $stillHasChildren = ((Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
        } catch { }
        if ($stillHasChildren) {
            $leftover.Add($d.FullName)
        } elseif (-not (Remove-InstallFileWithRetry -Path $d.FullName)) {
            $leftover.Add($d.FullName)
        }
    }

    if ($leftover.Count -eq 0) {
        if (-not (Remove-InstallFileWithRetry -Path $Path)) {
            $leftover.Add($Path)
        }
    }
    return $leftover
}

# =====================================================================
# Round 34 (REMOVAL-SPEC.md CS-R12): legacy launcher-file/shortcut
# cleanup, shared by BOTH -Uninstall and an ordinary upgrade run.
#
# Before Round 34, install.ps1 wrote a per-flavour launcher pair
# (update-addons-and-launch.cmd / Launch WoW (Updated).vbs) into every
# first-class flavour folder plus a matching Desktop shortcut. Round 34
# removed WoW-launching entirely - this installer no longer writes any
# of that - but the ONLY place that used to clean up a stale pair was
# the -Uninstall branch below. An ordinary upgrade (install.ps1 run
# again with no -Uninstall - exactly what shipping this removal looks
# like) never called that cleanup, so a machine upgraded in place would
# keep its stale launcher files/shortcut forever. This function is that
# same cleanup, factored out so both call sites (the -Uninstall branch
# below and Invoke-FurphyInstallSteps further down) share one file list
# that can never drift apart.
#
# Launcher FILES (inside the WoW flavour folder, never the Desktop) are
# removed unconditionally - they were never gated by -NoShortcuts even
# in the original -Uninstall-only code. Only the DESKTOP SHORTCUT half
# is gated, with the exact same two-layer safety this file already uses
# everywhere else it touches the real Desktop: skipped entirely when
# -NoShortcuts is passed, and skipped with a warning (even without
# -NoShortcuts) when Test-LooksLikeScratchRun flags either path as a
# scratch/test root (see the CS-F5 incident note on the -Uninstall
# branch's own shortcut-removal block for why that second, code-level
# guard exists - this reuses the identical check, not a weaker copy).
#
# Never touches "Furphy Addon Manager.lnk" itself - that shortcut is
# the app's own, still created by every install and removed only by a
# full -Uninstall, never by this legacy-artifact cleanup.
# =====================================================================

function Remove-FurphyLegacyLauncherArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$WowRootPath,
        [Parameter(Mandatory = $true)][string]$AppDestPath
    )
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $failed = New-Object 'System.Collections.Generic.List[string]'

    # Every known flavour folder, not just the ones currently installed/
    # first-class - a stale pair can be left behind under any flavour
    # folder from an older version, a since-removed flavour, or a
    # re-install across versions of this installer.
    foreach ($def in $Script:FlavourDefs) {
        $flavourDir = Join-Path -Path $WowRootPath -ChildPath $def.Folder
        foreach ($name in @('update-addons-and-launch.cmd', 'Launch WoW (Updated).vbs')) {
            $p = Join-Path -Path $flavourDir -ChildPath $name
            if (Test-Path -LiteralPath $p) {
                if (Remove-InstallFileWithRetry -Path $p) {
                    Write-Info "Removed legacy launcher file: $($def.Label)\$name"
                    $removed.Add($p)
                } else {
                    $failed.Add($p)
                    Write-Warn2 "Could not remove legacy launcher file (in use?): $($def.Label)\$name"
                }
            }
        }
    }

    $looksScratch = (Test-LooksLikeScratchRun $WowRootPath) -or (Test-LooksLikeScratchRun $AppDestPath)
    if ($looksScratch -and (-not $NoShortcuts)) {
        Write-Warn2 'Target path looks like a scratch/test root but -NoShortcuts was not passed - skipping legacy Desktop shortcut cleanup for safety. Pass -NoShortcuts explicitly if this really is production.'
    } elseif (-not $NoShortcuts) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shortcutNames = New-Object 'System.Collections.Generic.List[string]'
        $shortcutNames.Add('WoW (auto-update addons).lnk')
        foreach ($def in $Script:FlavourDefs) {
            if ($def.FirstClass) { $shortcutNames.Add("WoW - $($def.Label) (auto-update addons).lnk") }
        }
        foreach ($name in $shortcutNames) {
            $lnk = Join-Path -Path $desktop -ChildPath $name
            if (Test-Path -LiteralPath $lnk) {
                if (Remove-InstallFileWithRetry -Path $lnk) {
                    Write-Info "Removed legacy shortcut: $name"
                    $removed.Add($lnk)
                } else {
                    $failed.Add($lnk)
                    Write-Warn2 "Could not remove legacy shortcut (in use?): $name"
                }
            }
        }
    } else {
        Write-Info 'Skipped legacy Desktop shortcut cleanup (-NoShortcuts).'
    }

    return [PSCustomObject]@{ Removed = $removed; Failed = $failed }
}

# =====================================================================
# APP-UPDATE-SPEC.md section 8.5: REAL GAP FOUND BY READING THE CODE, the
# load-bearing fix the whole self-update feature depends on. Close-
# InstallMainWindow/Invoke-InstallServerShutdown/Wait-InstallHostAndWebView2Exit/
# Get-InstallLiveAppDestProcesses above used to be reachable ONLY from
# inside the -Uninstall block below. Invoke-FurphyInstallSteps's own Step
# 3b (the unguarded host\bin\FurphyHost.exe copy loop, no try/catch,
# $ErrorActionPreference='Stop') throws ERROR_SHARING_VIOLATION and aborts
# the whole install the moment that exact exe (or a WebView2 child) is
# still open when the copy runs - already a latent bug in any plain
# "run install.ps1 again to upgrade" with a window/tray open, and an
# absolute blocker for a self-updater that upgrades while its OWN server
# is, by definition, still running.
#
# Factored out of the exact code the -Uninstall block used to run inline
# (same behavior, same messages) so Invoke-FurphyInstallSteps can call it
# UNCONDITIONALLY at the top of every install/upgrade/repair run. A no-op
# when nothing is running (Get-InstallLiveAppDestProcesses returns empty
# instantly), load-bearing whenever something is.
# =====================================================================

function Invoke-InstallStopRunningApp {
    <#
      -SkipRunValueRemoval: the HKCU "Start with Windows" Run value is a
      REGISTRATION, not a running process - removing it is correct only
      when the app is actually going away (a true -Uninstall). Every
      OTHER caller of this function (a plain repair/reinstall today, and
      -Upgrade per APP-UPDATE-SPEC.md section 8.5's own a/b/c breakdown:
      "(a) remove the Run value - SKIP this one under -Upgrade. The app
      is not going away; deregistering startup would silently break
      'Update addons in the background' at next logon.") must pass this
      switch so existing behavior for every non-uninstall caller is kept
      byte-identical to before this function existed (a plain reinstall
      never touched the Run value either, since none of this code ran
      for it at all). The TrayStop-event signal and its up-to-10s wait -
      "(b)"/"(c)" in that same breakdown - always run regardless of this
      switch: they are the steps that matter most for THIS feature (the
      silent/tray relaunch path is exactly the scenario where a tray IS
      running when the upgrade fires).

      Returns a PSCustomObject:
        TrayWasRunningIndependently - $true if any matched
          FurphyHost.exe process, BEFORE anything here stopped it, had
          '--tray' on its own command line (section 8.7 - tray and a
          main window are not mutually exclusive; this lets a caller
          restore an independently-running tray after a window-triggered
          relaunch, rather than silently killing it and never bringing
          it back until the user's next reboot).
        ForceKilled - list of "<name> (pid <n>)" labels for anything that
          had to be force-terminated after the graceful wait timed out
          (Wait-InstallHostAndWebView2Exit's own return value, passed
          through).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [switch]$SkipRunValueRemoval
    )

    $appDestNorm = $AppDest.TrimEnd('\').ToLowerInvariant()

    # DISTRIBUTION-SPEC.md fix 9/section 5.3 step 3: best-effort ask any
    # open Furphy MAIN WINDOW for THIS install's own port to close, before
    # the FurphyHost-process wait loop below starts waiting - gives that
    # loop something proactive to do besides wait and warn. The ONLY
    # WM_CLOSE-by-window-title implementation in the whole project (do not
    # add a second one in host\FurphyHost.cs).
    Close-InstallMainWindow -Port (Get-InstallPort -AppDest $AppDest)

    # APP-UPDATE-SPEC.md section 8.7: detect BEFORE stopping anything -
    # tray and window are not mutually exclusive, and relaunch is keyed
    # solely to the caller's own -Relaunch intent, never to Win32
    # window-guessing. Read off the exact same live-process snapshot the
    # stop sequence below builds anyway - never a second CIM query just
    # for this.
    $trayWasRunningIndependently = $false
    try {
        foreach ($p in (Get-InstallLiveAppDestProcesses -AppDestNorm $appDestNorm)) {
            if ($p.Name -eq 'FurphyHost.exe') {
                $cmd = [string]$p.CommandLine
                if ($cmd -and $cmd.ToLowerInvariant().Contains('--tray')) { $trayWasRunningIndependently = $true }
            }
        }
    } catch {
        # Best-effort only - a failed read here just means a later
        # window-relaunch will not also restore an independent tray; it
        # must never block the stop/upgrade itself.
    }

    # Round 18 (tray stage B): stop any running tray before touching files -
    # the app files removal/copy below deletes/overwrites host\ (FurphyHost.exe
    # included), which must not happen while that exe is still running out
    # of the folder being deleted/replaced. Order here matters: remove the
    # Run value FIRST when not skipped (so a logon during a slow uninstall
    # can't relaunch the tray), then signal the running instance to exit,
    # then wait for it before any Remove-Item/Copy-Item touches host\.
    $trayExePath = Join-Path -Path $AppDest -ChildPath 'host\bin\FurphyHost.exe'
    if ($SkipRunValueRemoval) {
        Write-Info 'Leaving the "Start with Windows" registration untouched (not an uninstall).'
    } else {
        # Round 32 (DISTRIBUTION-SPEC.md section 0, fixes 1 and 3): both the Run
        # value and the tray stop event are SCOPED to this install - the value
        # name and event name derive from this install's own port, and a
        # scratch/test root on the production port touches neither (there is
        # nothing of its own to remove there). Before this fix an -Uninstall run
        # against a scratch fixture removed the REAL user's "Start with Windows"
        # entry and stopped the REAL user's tray (2026-09-06 14:45, incident
        # during the round-32 research pass).
        $runValueName = Get-InstallStartupValueName -AppDest $AppDest
        if ($null -eq $runValueName) {
            Write-Info 'Scratch/test install on the production port - the real Start-with-Windows entry is left alone.'
        } else {
            try {
                $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
                if (Test-Path -LiteralPath $runKeyPath) {
                    $existing = Get-ItemProperty -LiteralPath $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
                    if ($null -ne $existing) {
                        Remove-ItemProperty -LiteralPath $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
                        Write-Info "Removed ""Start with Windows"" registration ($runValueName)."
                    }
                }
            } catch {
                Write-Warn2 "Could not remove the Start-with-Windows registry value: $($_.Exception.Message)"
            }
        }
    }

    $trayStopEventName = Get-InstallTrayStopEventName -AppDest $AppDest
    $trayStopEvent = $null
    if ($null -ne $trayStopEventName) {
        try {
            $trayStopEvent = [System.Threading.EventWaitHandle]::OpenExisting($trayStopEventName)
            $trayStopEvent.Set() | Out-Null
        } catch {
            # No live tray holds this event - nothing to stop.
            $trayStopEvent = $null
        } finally {
            if ($null -ne $trayStopEvent) { try { $trayStopEvent.Close() } catch { } }
        }
    }

    if (Test-Path -LiteralPath $trayExePath -PathType Leaf) {
        $waitedMs = 0
        $stillRunning = $true
        while ($waitedMs -lt 10000) {
            $procs = Get-Process -Name 'FurphyHost' -ErrorAction SilentlyContinue
            $matched = $false
            if ($procs) {
                foreach ($p in $procs) {
                    try {
                        if ($p.Path -and ([string]$p.Path).Equals($trayExePath, [System.StringComparison]::OrdinalIgnoreCase)) { $matched = $true }
                    } catch { }
                }
            }
            if (-not $matched) { $stillRunning = $false; break }
            Start-Sleep -Milliseconds 500
            $waitedMs += 500
        }
        if ($stillRunning) {
            Write-Warn2 'The background tray (FurphyHost.exe --tray) did not exit within 10 seconds - it may still be holding files open.'
        } else {
            # fresh-zip:novice-uninstall-orphans-addon-server fix: this
            # loop only ever watches the tray's OWN FurphyHost.exe process
            # - it says nothing about the separate background
            # addon-server.ps1 (powershell.exe) process, so deliberately
            # does NOT claim "stopped" here. The one user-facing
            # "stopped" confirmation for both together is printed below,
            # after Wait-InstallHostAndWebView2Exit has actually covered
            # (and confirmed gone) the server too.
            Write-Info 'Background tray process exited.'
        }
    }

    # Round 33 defect fix (item 1): the wait above only ever watched
    # $trayExePath's OWN --tray process. A MAIN WINDOW instance of the
    # exact same exe (opened from the app itself, or from the tray's
    # "Open" - the two most common real uninstall paths Eric asked for)
    # was never waited for at all, and neither was either instance's
    # WebView2 child processes - both can still be exiting/unwinding for a
    # short window after Close-InstallMainWindow's WM_CLOSE, which is what
    # let the Remove-Item below hit a still-locked file under host\ and
    # abandon the whole folder. Always runs (not gated on $trayExePath
    # existing) and covers every FurphyHost.exe under $AppDest, tray and
    # window alike.
    $processWait = Wait-InstallHostAndWebView2Exit -AppDest $AppDest
    if ($processWait.ForceKilled.Count -gt 0) {
        Write-Warn2 "Had to force-close $($processWait.ForceKilled.Count) leftover Furphy process(es) before removing files: $($processWait.ForceKilled -join ', ')"
    }

    # fresh-zip:novice-uninstall-orphans-addon-server fix: this is the ONE
    # user-facing "stopped" confirmation for the tray/window AND the
    # background addon-server.ps1 process together, and it only prints
    # once a fresh check (not just "we didn't throw") actually confirms
    # every one of them is gone - a re-check rather than trusting
    # $processWait alone, since a force-kill whose settle-wait above timed
    # out could in principle still leave something alive.
    $stillLiveAfterWait = Get-InstallLiveAppDestProcesses -AppDestNorm $appDestNorm
    if ($stillLiveAfterWait.Count -eq 0) {
        Write-Info 'Background tray/server stopped.'
    } else {
        Write-Warn2 "$($stillLiveAfterWait.Count) Furphy process(es) under $AppDest may still be running - files may still be locked."
    }

    return [PSCustomObject]@{
        TrayWasRunningIndependently = $trayWasRunningIndependently
        ForceKilled                 = $processWait.ForceKilled
    }
}

# =====================================================================
# -Uninstall path
# =====================================================================

if ($Uninstall) {
    # Self-relaunch safety net: every OTHER uninstall trigger (tray,
    # Settings' own button, Windows' Installed-Apps entry -
    # DISTRIBUTION-SPEC.md section 5.3) already copies install.ps1 to a
    # fresh %TEMP% path BEFORE running -Uninstall, precisely so the copy
    # doing the actual deleting never executes out of the very folder it is
    # about to remove. A user who instead navigates into $appDest and
    # double-clicks/runs install.ps1 -Uninstall directly skips that
    # convention entirely - catch that one remaining case here, the one
    # place all three other triggers already avoid needing to: if THIS copy
    # is running from inside $appDest, hop to a %TEMP% copy of itself
    # first and let that copy do the real work. FURPHY_INSTALL_RELAUNCHED
    # is an explicit, unmissable guard against relaunching more than once
    # (the %TEMP% copy's own $SourceRoot is %TEMP%, never $appDest, so the
    # path comparison below would already read false there on its own -
    # kept anyway rather than relying on that alone).
    $sourceLooksLikeAppDest = $false
    try {
        $normSource = $SourceRoot.TrimEnd('\').ToLowerInvariant()
        $normDest = $appDest.TrimEnd('\').ToLowerInvariant()
        $sourceLooksLikeAppDest = ($normSource -eq $normDest)
    } catch { }

    if ($sourceLooksLikeAppDest -and (-not $env:FURPHY_INSTALL_RELAUNCHED)) {
        Write-Step 'Relaunching from a temporary copy before removing the install folder'
        $tempCopy = Join-Path -Path $env:TEMP -ChildPath ('FurphyUninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Copy-Item -LiteralPath (Join-Path -Path $SourceRoot -ChildPath 'install.ps1') -Destination $tempCopy -Force
            # Security fix (security:security-install-uninstall-wowpath-arg-
            # splitting): every element wrapped in ConvertTo-SafeProcessArg
            # before being added, not just the ones that used to look like
            # they needed it - Start-Process -ArgumentList joins array
            # elements with a bare, unquoted space under PS 5.1, so an
            # unquoted $wowRoot/$tempCopy containing a space (the DEFAULT
            # Windows WoW install path, "C:\Program Files (x86)\World of
            # Warcraft\_retail_") used to get split into extra argv tokens
            # by the relaunched child, truncating -WowPath.
            $relaunchArgs = New-Object 'System.Collections.Generic.List[string]'
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-NoProfile')); $relaunchArgs.Add((ConvertTo-SafeProcessArg '-ExecutionPolicy')); $relaunchArgs.Add((ConvertTo-SafeProcessArg 'Bypass'))
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-File')); $relaunchArgs.Add((ConvertTo-SafeProcessArg $tempCopy))
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-WowPath')); $relaunchArgs.Add((ConvertTo-SafeProcessArg $wowRoot))
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-Uninstall'))
            if ($NoShortcuts) { $relaunchArgs.Add((ConvertTo-SafeProcessArg '-NoShortcuts')) }
            if ($NoProtocol) { $relaunchArgs.Add((ConvertTo-SafeProcessArg '-NoProtocol')) }
            $env:FURPHY_INSTALL_RELAUNCHED = '1'
            # Deliberately NOT -WindowStyle Hidden and NOT detached from
            # this console (-NoNewWindow): unlike the tray/Settings/
            # Installed-Apps triggers (which always run hidden - section
            # 5.3), this specific path exists for a person who ran
            # install.ps1 -Uninstall directly and is watching this same
            # console, so the relaunched copy's own Write-Step/Write-Info
            # output should keep appearing right here, not vanish into a
            # hidden child. -Wait blocks until it finishes so this
            # process's own exit code still reflects the real outcome.
            $relaunchProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs.ToArray() -NoNewWindow -PassThru -Wait
            exit $relaunchProc.ExitCode
        } catch {
            Write-Warn2 "Could not relaunch from a temporary copy, continuing in place: $($_.Exception.Message)"
        }
    }

    # Round 33 defect fix (item 3): open the per-run uninstall log now, so
    # every Write-Step/Write-Info/Write-Warn2 call from here to the end of
    # this block (already the ONLY logging call sites the whole sequence
    # uses) is captured - "every step and every failure" - without a
    # second parallel set of log-writing calls. Never set before this
    # point: the temp-copy relaunch guard above intentionally runs BEFORE
    # this (its own Write-Warn2, if hit, logs to nothing) so the log that
    # actually matters is the one written by the copy that does the real
    # work, not a stub from the process that immediately re-executed
    # itself elsewhere.
    try {
        $logStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $Script:UninstallLogPath = Join-Path -Path $env:TEMP -ChildPath ("FurphyUninstall-$logStamp.log")
        "Furphy Addon Manager uninstall log - $(Get-Date -Format 'u') - target: $appDest" |
            Set-Content -LiteralPath $Script:UninstallLogPath -Encoding Ascii
    } catch {
        $Script:UninstallLogPath = $null
    }

    Write-Step "Uninstalling Furphy Addon Manager from $appDest"

    # APP-UPDATE-SPEC.md section 8.5/11: this exact sequence (close any
    # open main window, remove the Run value, signal+wait for the tray,
    # wait for every FurphyHost.exe/WebView2 child/addon-server.ps1 under
    # $appDest) is now shared with Invoke-FurphyInstallSteps (called
    # there UNCONDITIONALLY, on every install/upgrade/repair, to fix the
    # ERROR_SHARING_VIOLATION Step 3b's unguarded host\bin\ copy hits
    # whenever the app is still running) - factored into
    # Invoke-InstallStopRunningApp, defined above this block, so both
    # callers share one implementation rather than two copies that could
    # drift apart. -Uninstall is a true removal, so the Run value IS
    # removed here (the default - no -SkipRunValueRemoval passed).
    Invoke-InstallStopRunningApp -AppDest $appDest | Out-Null

    if (-not $NoProtocol) {
        $regScript = Join-Path -Path $appDest -ChildPath 'register-protocol.ps1'
        if (Test-Path -LiteralPath $regScript) {
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regScript -Unregister -Json | Out-Null
                Write-Info 'curseforge:// protocol handler unregistered.'
            } catch {
                Write-Warn2 "Could not unregister the protocol handler: $($_.Exception.Message)"
            }
        }
    }

    # Round 20: accumulate any file that could not be removed (locked by
    # another process, e.g. AV/indexer/OneDrive/an open editor) across all
    # three removal loops below, instead of letting $ErrorActionPreference
    # = 'Stop' throw out of the first Remove-Item that hits a locked file
    # and abort the uninstall mid-way, leaving a half-removed app with the
    # game-launcher files already gone but the app's own code still there.
    $failedRemovals = New-Object 'System.Collections.Generic.List[string]'

    # [Environment]::GetFolderPath('Desktop') always resolves the REAL
    # machine Desktop - it is never scoped to -WowPath/$wowRoot. Gate
    # this whole block behind -NoShortcuts (mirroring the creation-side
    # guard further down) so an -Uninstall run against a test/scratch
    # -WowPath (or any caller that wants Desktop left alone) can opt out
    # the same way install already lets them opt out of creation. This
    # exact unscoped removal previously deleted this machine's two real
    # production desktop shortcuts during a scratch-fixture test run -
    # see the CS-F5 build-log incident note.
    #
    # Round 20: -NoShortcuts is still the authoritative opt-out, but it is
    # pure caller discipline - nothing stopped a caller who simply forgot
    # the flag from reproducing the exact CS-F5 incident against a real
    # Desktop. Test-LooksLikeScratchRun is an independent, code-level
    # heuristic (never registry/config-based, no new persisted state) that
    # catches the common case - a $wowRoot/$appDest under %TEMP%, a
    # \scratch\ folder, or fixtures\wowroot - and skips the destructive
    # removal with a warning instead of proceeding, even if -NoShortcuts
    # was forgotten. It changes nothing for a genuine production install,
    # which never sits under any of those paths.
    #
    # Only "Furphy Addon Manager.lnk" itself is removed here - that
    # shortcut is unique to a full -Uninstall (an ordinary upgrade must
    # never delete it, it's the app's own). Round 34 (REMOVAL-SPEC.md
    # CS-R12): every legacy launcher-file/WoW-shortcut this installer
    # used to write (and no longer does) is cleaned up by the shared
    # Remove-FurphyLegacyLauncherArtifacts call just below instead - the
    # SAME function an ordinary upgrade run now also calls, so the file
    # list can never drift between the two paths.
    $looksScratch = (Test-LooksLikeScratchRun $wowRoot) -or (Test-LooksLikeScratchRun $appDest)
    if ($looksScratch -and (-not $NoShortcuts)) {
        Write-Warn2 'Target path looks like a scratch/test root but -NoShortcuts was not passed - skipping Desktop shortcut removal for safety. Pass -NoShortcuts explicitly if this really is production.'
    } elseif (-not $NoShortcuts) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path -Path $desktop -ChildPath 'Furphy Addon Manager.lnk'
        if (Test-Path -LiteralPath $lnk) {
            # Round 33 defect fix (item 2): retry+backoff instead of one
            # attempt, same as every other removal below.
            if (Remove-InstallFileWithRetry -Path $lnk) {
                Write-Info 'Removed shortcut: Furphy Addon Manager.lnk'
            } else {
                $failedRemovals.Add($lnk)
                Write-Warn2 'Could not remove shortcut (in use?): Furphy Addon Manager.lnk'
            }
        }
    } else {
        Write-Info 'Skipped desktop shortcut removal (-NoShortcuts).'
    }

    # Round 34 (REMOVAL-SPEC.md CS-R12): remove any per-flavour launcher
    # file / WoW Desktop shortcut this installer wrote before this round
    # - the same cleanup an ordinary upgrade run now performs too.
    $legacyCleanup = Remove-FurphyLegacyLauncherArtifacts -WowRootPath $wowRoot -AppDestPath $appDest
    foreach ($f in $legacyCleanup.Failed) { $failedRemovals.Add($f) }

    if (Test-Path -LiteralPath $appDest) {
        $keepFiles = @('addons.json', 'settings.json', 'state.json', 'sync.log', 'server.log', 'last-run.txt', 'server.pid')
        # FLAVORS-SPEC S3.1/S10: 'flavours' holds every installed
        # flavour's own addons.json/state.json/backups\ - it is state,
        # exactly like 'backups'/'cache'/'jobs' below, and must never be
        # deleted by an uninstall. (Bug found and fixed here: the
        # pre-flavours version of this list did not know about this new
        # directory, which would have silently deleted every flavour's
        # tracked-addon data on uninstall.)
        $keepDirs = @('jobs', 'backups', 'cache', 'staging', 'flavours')
        Get-ChildItem -LiteralPath $appDest -Force | ForEach-Object {
            # Capture the pipeline item's Name/FullName BEFORE the try/catch:
            # inside a catch block, $_ is rebound to the caught ErrorRecord,
            # so referencing $_.Name/$_.FullName there would silently resolve
            # to nothing rather than the file/folder being removed.
            $itemName = $_.Name
            $itemFullName = $_.FullName
            if ($_.PSIsContainer) {
                if ($keepDirs -notcontains $itemName) {
                    # Round 33 defect fix (item 2): remove the tree
                    # file-by-file with retry, rather than one single
                    # Remove-Item -Recurse -Force that throws (and abandons
                    # the WHOLE folder - this exact 'host' directory is
                    # what the round-33 defect left behind) the moment it
                    # hits even one still-locked file.
                    $folderLeftover = Remove-InstallFolderWithRetry -Path $itemFullName
                    if ($folderLeftover.Count -gt 0) {
                        foreach ($lf in $folderLeftover) { $failedRemovals.Add($lf) }
                        Write-Warn2 "Could not fully remove folder (in use?): $itemName - $($folderLeftover.Count) item(s) still locked"
                    }
                }
            } elseif ($keepFiles -notcontains $itemName) {
                if (-not (Remove-InstallFileWithRetry -Path $itemFullName)) {
                    $failedRemovals.Add($itemFullName)
                    Write-Warn2 "Could not remove file (in use?): $itemName"
                }
            }
        }
        Write-Info "App files removed from $appDest"
        Write-Info "Your addon list, settings, logs and backups are kept: $appDest"
        try {
            $leftoverNote = Join-Path -Path $appDest -ChildPath 'README-leftover.txt'
            "Furphy's addon list and settings are kept here. Safe to delete by hand if you don't plan to reinstall." |
                Set-Content -LiteralPath $leftoverNote -Encoding Ascii
        } catch {
            # Optional/cheap per DISTRIBUTION-SPEC.md section 5.3 - never fatal.
        }
    } else {
        Write-Info "$appDest did not exist - nothing to remove."
    }

    # DISTRIBUTION-SPEC.md section 5.3 step 8/fix 3: the Installed-Apps key
    # is removed with the SAME scoping guard as the Run value above, from
    # its very first commit (Get-InstallAppsKeyName forwards to
    # Get-InstallStartupValueName - see that function's own comment) - a
    # scratch/test root on the production port owns neither name and
    # touches neither key.
    $appsKeyName = Get-InstallAppsKeyName -AppDest $appDest
    if ($null -eq $appsKeyName) {
        Write-Info 'Scratch/test install on the production port - the real Installed-Apps entry is left alone.'
    } else {
        try {
            $appsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $appsKeyName
            if (Test-Path -LiteralPath $appsKeyPath) {
                Remove-Item -LiteralPath $appsKeyPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Info "Removed the Windows Settings > Apps entry ($appsKeyName)."
            }
        } catch {
            Write-Warn2 "Could not remove the Installed-Apps registry entry: $($_.Exception.Message)"
        }
    }

    Write-Info "Your AddOns folder(s) were not touched."
    Write-Host ''
    if ($failedRemovals.Count -gt 0) {
        Write-Warn2 "$($failedRemovals.Count) item(s) could not be removed because they were in use - close any running Furphy/CurseForge window or program holding them open and re-run -Uninstall:"
        foreach ($f in $failedRemovals) { Write-Warn2 "  $f" }
        Write-Host 'Uninstall completed with warnings.' -ForegroundColor Yellow

        # Round 33 defect fix (item 3): fold the leftover list into the
        # README-leftover.txt the removal loop above already wrote, so a
        # user who only ever looks in the folder (never the console/log)
        # still sees exactly what is left and why - not just the generic
        # "your addon list is kept here" note.
        if (Test-Path -LiteralPath $appDest) {
            try {
                $leftoverNote = Join-Path -Path $appDest -ChildPath 'README-leftover.txt'
                $noteLines = New-Object 'System.Collections.Generic.List[string]'
                $noteLines.Add('')
                $noteLines.Add('The following items could not be removed because they were still in use:')
                foreach ($f in $failedRemovals) { $noteLines.Add("  $f") }
                $noteLines.Add('Close any running Furphy/CurseForge window or program holding them open, then delete them by hand or re-run the uninstaller.')
                Add-Content -LiteralPath $leftoverNote -Value $noteLines -Encoding Ascii
            } catch {
                # Optional/cheap - never fatal.
            }
        }
    } else {
        Write-Host 'Uninstall complete.' -ForegroundColor Green
    }

    Write-InstallLogLine ''
    Write-InstallLogLine "Uninstall finished. Failed removals: $($failedRemovals.Count)"
    if ($Script:UninstallLogPath) { Write-Info "Uninstall log: $Script:UninstallLogPath" }

    # Round 33 defect fix (item 3): surface the outcome in plain language,
    # not just the console/log, since both real callers (Handle-Uninstall
    # in addon-server.ps1, the tray's RunUninstallSequence in
    # FurphyHost.cs) run this whole script -WindowStyle Hidden today -
    # every Write-Warn2 line above is otherwise invisible to whoever just
    # asked to uninstall. Shown by default; -Console and -Quiet both
    # suppress it (every automated test in this repo passes -Console
    # already, which must never call MessageBox.Show and hang headless
    # waiting for a click that will never come).
    if (-not $Console -and -not $Quiet) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            if ($failedRemovals.Count -gt 0) {
                $shown = @($failedRemovals | Select-Object -First 10)
                $moreCount = $failedRemovals.Count - $shown.Count
                $msg = "Most of Furphy was removed, but these files were still in use:`r`n`r`n" + ($shown -join "`r`n")
                if ($moreCount -gt 0) { $msg += "`r`n... and $moreCount more (see README-leftover.txt)" }
                $msg += "`r`n`r`nDelete the folder $appDest after a restart to finish."
                [System.Windows.Forms.MessageBox]::Show($msg, 'Furphy Addon Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            } else {
                $msg = "Furphy Addon Manager was removed. Your addons stay installed in WoW; your addon list was kept at $appDest."
                [System.Windows.Forms.MessageBox]::Show($msg, 'Furphy Addon Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        } catch {
            Write-Warn2 "Could not show the uninstall result dialog: $($_.Exception.Message)"
        }
    }

    # novice:NOVICE-3 fix: every real uninstall trigger (the Settings >
    # Uninstall button via addon-server.ps1's Handle-Uninstall, the Windows
    # Apps & Features UninstallString/QuietUninstallString fallback in
    # Get-InstallUninstallString above, this script's own relaunch-safety-
    # net a few hundred lines up, and the tray's identical fallback in
    # host\FurphyHost.cs's TryTrayUninstall) copies this script into a
    # fresh %TEMP%\FurphyUninstall-<guid>.ps1 path and launches THAT copy
    # with -Uninstall - none of them ever deleted it afterward, an
    # unbounded %TEMP% leak (100+ leftover ~90KB copies found on this dev
    # machine alone, purely from this code path being exercised across QA
    # rounds). Since every one of those four triggers ultimately runs THIS
    # SAME -Uninstall block inside the temp copy itself, a single guarded
    # self-delete right here - keyed off $PSCommandPath, the actual
    # running script's own path - covers all four call sites with no
    # changes needed at any of them. Test-IsTempUninstallScriptCopy
    # guarantees this never fires for a developer running install.ps1
    # -Uninstall directly out of the source/app folder. Deletion is
    # scheduled from a separate DETACHED process (never in-process) since
    # this running powershell.exe still has its own script file open.
    #
    # The uninstall log ($Script:UninstallLogPath) is deliberately left in
    # place here even on a clean run: Write-Info just told the user (and
    # this run's own console output) exactly where it is, and this
    # codebase's own end-to-end integration coverage
    # (tests\integration\Server.Uninstall.Tests.ps1) reads it immediately
    # after a real uninstall completes - auto-deleting it here would race
    # that read. The log files are also small, human-readable text, a far
    # smaller and less numerous leak than the ~90KB script copies this fix
    # targets; they are still worth a person clearing out of %TEMP% by hand
    # occasionally, same as any other diagnostic log.
    try {
        $selfPath = $PSCommandPath
        if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
        if (Test-IsTempUninstallScriptCopy -Path $selfPath) {
            $selfDeleteCmd = 'ping -n 2 127.0.0.1 >nul & del "' + $selfPath + '"'
            Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ' + $selfDeleteCmd) -WindowStyle Hidden | Out-Null
        }
    } catch {
        # Best-effort cleanup only - never fail the uninstall over this.
    }

    exit 0
}

function Invoke-InstallCopyAndBuildSteps {
    <#
      DISTRIBUTION-SPEC.md section 6.2/6.3 steps 3/3b/4 (copy the code
      files + ui\, copy/build host\, parse-check the deployed copy) -
      extracted verbatim, unchanged, out of Invoke-FurphyInstallSteps so
      that function can run it either bare (a plain install/repair - the
      existing, unchanged error behavior: a throw here propagates
      straight out) or inside its own try/catch under -Upgrade
      (APP-UPDATE-SPEC.md section 8.6 - a throw here is caught and
      triggers rollback-and-relaunch-the-old-version) without the two
      call sites ever duplicating this code. Reads $wowRoot/$appDest/
      $homeFlavour/$multiFlavour/$SourceRoot from script scope exactly as
      before extraction - nothing here changed, only where it lives.
    #>

# =====================================================================
# 3. Copy the app into <home-flavour>\AddonSync (never overwrite user state)
# =====================================================================

if ($multiFlavour) {
    Write-Step "Installing Furphy Addon Manager into $appDest (home flavour: $($homeFlavour.Label))"
} else {
    Write-Step "Installing Furphy Addon Manager into $appDest"
}

New-Item -ItemType Directory -Force -Path $appDest | Out-Null
# Round 32 (DISTRIBUTION-SPEC.md fix 2): install.ps1 ships INTO the install
# so the installed copy can uninstall itself (tray menu / Settings /
# Installed apps all run "<appDest>\install.ps1 -Uninstall").
$codeFiles = @('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'install.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico', 'VERSION')
foreach ($f in $codeFiles) {
    $s = Join-Path -Path $SourceRoot -ChildPath $f
    if (Test-Path -LiteralPath $s) {
        Copy-Item -LiteralPath $s -Destination (Join-Path -Path $appDest -ChildPath $f) -Force
    } else {
        Write-Warn2 "Source file missing, skipped: $f"
    }
}
$uiSrc = Join-Path -Path $SourceRoot -ChildPath 'ui'
$uiDst = Join-Path -Path $appDest -ChildPath 'ui'
New-Item -ItemType Directory -Force -Path $uiDst | Out-Null
if (Test-Path -LiteralPath $uiDst) {
    Get-ChildItem -LiteralPath $uiDst -File -Recurse | Remove-Item -Force
}
Copy-Item -Path (Join-Path -Path $uiSrc -ChildPath '*') -Destination $uiDst -Recurse -Force
$uiCount = (Get-ChildItem -LiteralPath $uiDst -File -Recurse | Measure-Object).Count
Write-Info "Copied code files and ui\ ($uiCount files)."

$versionSrc = Join-Path -Path $SourceRoot -ChildPath 'VERSION'
if (Test-Path -LiteralPath $versionSrc) {
    Copy-Item -LiteralPath $versionSrc -Destination (Join-Path -Path $appDest -ChildPath 'VERSION') -Force
}

$settingsPath = Join-Path -Path $appDest -ChildPath 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    '{ "releaseType": 1, "port": 47831 }' | Set-Content -LiteralPath $settingsPath -Encoding Ascii
    Write-Info 'Created default settings.json (no account or API key needed).'
} else {
    Write-Info 'settings.json already exists - left as-is.'
}

New-Item -ItemType Directory -Force -Path (Join-Path -Path $appDest -ChildPath 'jobs') | Out-Null

# =====================================================================
# 3b. host\ - the E19 native WebView2 host (Furphy + CurseForge tabs in
#     one window). Copies the source files (and a prebuilt host\bin\, as
#     a fallback for a machine with no compiler at all), then rebuilds
#     FurphyHost.exe fresh at the destination when a C# compiler is
#     present - skipped silently when it is not (every normal Windows
#     box has one; see SPEC E19), in which case the copied prebuilt
#     host\bin\ (if any) or the plain Edge app window (Addon
#     Manager.vbs's existing fallback, unchanged) is what actually runs.
# =====================================================================

$hostSrc = Join-Path -Path $SourceRoot -ChildPath 'host'
if (Test-Path -LiteralPath $hostSrc -PathType Container) {
    Write-Step 'Copying the native host (host\)'
    $hostDst = Join-Path -Path $appDest -ChildPath 'host'
    New-Item -ItemType Directory -Force -Path $hostDst | Out-Null

    foreach ($f in 'adfilter-hosts.txt', 'build-host.ps1', 'FurphyHost.cs') {
        $s = Join-Path -Path $hostSrc -ChildPath $f
        if (Test-Path -LiteralPath $s) {
            Copy-Item -LiteralPath $s -Destination (Join-Path -Path $hostDst -ChildPath $f) -Force
        } else {
            Write-Warn2 "host\$f missing, skipped."
        }
    }

    $libSrc = Join-Path -Path $hostSrc -ChildPath 'lib'
    if (Test-Path -LiteralPath $libSrc -PathType Container) {
        $libDst = Join-Path -Path $hostDst -ChildPath 'lib'
        New-Item -ItemType Directory -Force -Path $libDst | Out-Null
        Copy-Item -Path (Join-Path -Path $libSrc -ChildPath '*') -Destination $libDst -Recurse -Force
    } else {
        Write-Warn2 'host\lib (the WebView2 SDK) is missing - the host cannot be built here.'
    }

    # Prebuilt binaries only (icon.ico, the exe, the three SDK dlls) - never
    # the WebView2Loader-created runtime cache folder a previous run may
    # have left next to them (host\bin\FurphyHost.exe.WebView2\...), which
    # is per-machine junk, not part of the app.
    $binSrc = Join-Path -Path $hostSrc -ChildPath 'bin'
    if (Test-Path -LiteralPath $binSrc -PathType Container) {
        $binDst = Join-Path -Path $hostDst -ChildPath 'bin'
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Get-ChildItem -LiteralPath $binSrc -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path -Path $binDst -ChildPath $_.Name) -Force
        }
    }

    $cscPath = Join-Path -Path $env:WINDIR -ChildPath 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $cscPath)) {
        $cscPath = Join-Path -Path $env:WINDIR -ChildPath 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    if (Test-Path -LiteralPath $cscPath) {
        Write-Info 'C# compiler found - building the native host (host\build-host.ps1)...'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path -Path $hostDst -ChildPath 'build-host.ps1') | Out-Null
            $exeOut = Join-Path -Path $hostDst -ChildPath 'bin\FurphyHost.exe'
            if (Test-Path -LiteralPath $exeOut) {
                Write-Info 'Built host\bin\FurphyHost.exe - Furphy Addon Manager will open with an embedded CurseForge tab.'
            } else {
                Write-Warn2 'build-host.ps1 completed but FurphyHost.exe was not produced - falling back to the Edge app window.'
            }
        } catch {
            Write-Warn2 "Could not build the native host, falling back to the Edge app window: $($_.Exception.Message)"
        }
    }
    # else: no C# compiler found - skip the build silently (see comment
    # above the host\ section; this is expected to be effectively
    # unreachable on a normal Windows install).
}

# =====================================================================
# 4. Parse check on the deployed copy
# =====================================================================

foreach ($f in 'addon-sync.ps1', 'addon-server.ps1') {
    $errs = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath (Join-Path -Path $appDest -ChildPath $f)), [ref]$errs) | Out-Null
    if ($errs -and $errs.Count -gt 0) {
        throw "Parse errors in the deployed copy of $f : $($errs[0].Message)"
    }
}
Write-Info 'Parse check ok.'
}

# =====================================================================
# APP-UPDATE-SPEC.md section 8.6/8.7/8.8: backup/rollback, relaunch by
# caller intent, and post-success cleanup for -Upgrade. Used only from
# Invoke-FurphyInstallSteps below, under -Upgrade.
# =====================================================================

function Get-InstallUtcNowIso {
    <# ISO 8601 UTC, matching every other timestamp APP-UPDATE-SPEC.md
       section 4 describes for app-update.json. #>
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Set-InstallAppUpdateJsonFields {
    <#
      APP-UPDATE-SPEC.md section 4/8.6: app-update.json
      (<AppDest>\app-update.json, sibling of settings.json/state.json) is
      operational state owned primarily by addon-server.ps1 (its own
      Save-AppUpdateState/Get-AppUpdateState helpers) - install.ps1
      writes to it DIRECTLY via plain file I/O (section 8.6's own words:
      "it's just JSON; the server always re-reads it fresh on its next
      access - no new IPC needed"), and ONLY for the specific result
      fields sections 8.6/8.8 assign to the installer. This is a
      READ-MERGE-WRITE, never a full overwrite: fields like
      currentVersion/latestVersion/checkedAt/releaseUrl are the server's
      own and must survive an installer write untouched. A missing or
      unreadable existing file starts from an empty object (section 4:
      "No migration needed"). Same atomic tmp+Move-Item pattern
      Save-Settings already uses (addon-server.ps1:1390-1397) - never
      partially-written JSON, even if this process is killed mid-write.
      Best-effort: a failure to write is logged, never thrown - this must
      never turn an otherwise-successful (or already-failed) install into
      a harder failure just because a status file couldn't be updated.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [Parameter(Mandatory = $true)][hashtable]$Fields
    )
    $path = Join-Path -Path $AppDest -ChildPath 'app-update.json'
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = [System.IO.File]::ReadAllText($path)
            if ($raw -and $raw.Trim().Length -gt 0) {
                $parsed = $raw | ConvertFrom-Json
                if ($parsed) {
                    foreach ($prop in $parsed.PSObject.Properties) { $obj[$prop.Name] = $prop.Value }
                }
            }
        } catch {
            # Corrupt/unreadable existing file - start fresh rather than
            # fail the install over a status-file read.
            $obj = [ordered]@{}
        }
    }
    foreach ($key in $Fields.Keys) { $obj[$key] = $Fields[$key] }

    try {
        $json = ConvertTo-Json -InputObject $obj -Depth 5
        $tmpPath = "$path.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmpPath -Destination $path -Force
    } catch {
        Write-Warn2 "Could not write app-update.json: $($_.Exception.Message)"
    }
}

function Backup-InstallCodeForRollback {
    <#
      APP-UPDATE-SPEC.md section 8.6: copies the CURRENT $AppDest's exact
      code-file set (the same $codeFiles allow-list Step 3 copies FROM)
      plus ui\ and host\ recursively into a folder OUTSIDE $AppDest, so a
      mid-copy failure during the upgrade itself can never corrupt the
      backup. The folder name is a deterministic SHA256 hash of
      $AppDest's own normalized path (never a fresh guid) - open
      question 3's decision, "keep exactly one prior-version backup":
      the NEXT call for this SAME install lands on the SAME folder name,
      so it is naturally overwritten rather than accumulated, and a
      different install (a different $AppDest, e.g. a scratch port vs
      production) never collides with this one's backup. Throws on
      failure - the caller decides what an unbackupable upgrade means
      (currently: abort before copying anything, per Invoke-
      FurphyInstallSteps below).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest
    )
    $tempDir = [System.IO.Path]::GetTempPath()
    $appDestNorm = $AppDest.TrimEnd('\').ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($appDestNorm))
    } finally {
        $sha256.Dispose()
    }
    $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    $backupPath = Join-Path -Path $tempDir -ChildPath ('FurphyRollback-' + $hashHex.Substring(0, 16))

    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $backupPath | Out-Null

    $codeFiles = @('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'install.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico', 'VERSION')
    foreach ($f in $codeFiles) {
        $s = Join-Path -Path $AppDest -ChildPath $f
        if (Test-Path -LiteralPath $s) {
            Copy-Item -LiteralPath $s -Destination (Join-Path -Path $backupPath -ChildPath $f) -Force
        }
    }
    foreach ($dirName in 'ui', 'host') {
        $srcDir = Join-Path -Path $AppDest -ChildPath $dirName
        if (Test-Path -LiteralPath $srcDir -PathType Container) {
            $dstDir = Join-Path -Path $backupPath -ChildPath $dirName
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
            Copy-Item -Path (Join-Path -Path $srcDir -ChildPath '*') -Destination $dstDir -Recurse -Force
        }
    }
    return $backupPath
}

function Restore-InstallCodeFromRollback {
    <# The inverse of Backup-InstallCodeForRollback - copies every file
       back from the backup folder over $AppDest. Throws if the backup
       folder itself is missing/unreadable (the caller's own catch is
       what produces the failure-modes table's "Rollback restore itself
       FAILED" case). #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
        throw "Rollback backup not found at $BackupPath"
    }
    $codeFiles = @('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'install.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico', 'VERSION')
    foreach ($f in $codeFiles) {
        $s = Join-Path -Path $BackupPath -ChildPath $f
        if (Test-Path -LiteralPath $s) {
            Copy-Item -LiteralPath $s -Destination (Join-Path -Path $AppDest -ChildPath $f) -Force
        }
    }
    foreach ($dirName in 'ui', 'host') {
        $srcDir = Join-Path -Path $BackupPath -ChildPath $dirName
        if (Test-Path -LiteralPath $srcDir -PathType Container) {
            $dstDir = Join-Path -Path $AppDest -ChildPath $dirName
            if (Test-Path -LiteralPath $dstDir) {
                Get-ChildItem -LiteralPath $dstDir -File -Recurse | Remove-Item -Force
            } else {
                New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
            }
            Copy-Item -Path (Join-Path -Path $srcDir -ChildPath '*') -Destination $dstDir -Recurse -Force
        }
    }
}

function Test-InstallHealthCheck {
    <#
      APP-UPDATE-SPEC.md section 8.6: poll GET /api/ping for up to
      $TimeoutMs (default 20s, mirroring host\FurphyHost.cs's own
      ping-wait pattern), requiring the response's "version" field to
      equal $ExpectedVersion. Never throws - any request failure (not
      up yet, wrong port, network hiccup) is treated as "not healthy
      yet" and the loop just keeps polling until the timeout.

      Tracks REAL elapsed wall-clock time via a Stopwatch, not a naive
      counter incremented by $PollMs per iteration - found and fixed
      during this round's own headless verification: against an
      unreachable port, a single failed Invoke-RestMethod call can
      itself take close to its own -TimeoutSec before throwing, and a
      counter that only ever adds $PollMs per loop (ignoring how long
      the request itself actually took) can let this function run for
      several times its intended $TimeoutMs before giving up - directly
      undermining the "up to 20s" contract section 8.6 promises callers
      (a real caller waiting on this before deciding whether to roll
      back). -TimeoutSec 2 per attempt (not 3) bounds the worst-case
      overrun past $TimeoutMs to about one attempt's own timeout, mirroring
      the existing 2-second "fire and forget" idiom Invoke-InstallServerShutdown
      already uses for the same kind of best-effort localhost call.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [int]$TimeoutMs = 20000,
        [int]$PollMs = 500
    )
    $uri = "http://localhost:$Port/api/ping"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $resp = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 2 -ErrorAction Stop
            if ($resp -and ([string]$resp.version) -eq $ExpectedVersion) { return $true }
        } catch {
            # Not up yet, or answering with something unexpected - keep polling.
        }
        if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Wait-InstallPortStopsAnswering {
    <#
      The inverse of Test-InstallHealthCheck's poll loop: waits, with the
      same real-elapsed-time Stopwatch bounding (not a naive counter - see
      that function's own comment for why that matters), for GET /api/ping
      on -Port to STOP answering. Returns $true once nothing answers
      within one -PollMs-spaced attempt, $false if something is still
      answering when -TimeoutMs elapses. Never throws. Used by Invoke-
      InstallVerifyNewFiles both to confirm a stale pre-existing listener
      has actually let go of the port before it binds its own verification
      server, and to confirm its OWN verification server's listener has
      actually closed after asking it to shut down.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 10000,
        [int]$PollMs = 300
    )
    $uri = "http://localhost:$Port/api/ping"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 1 -ErrorAction Stop | Out-Null
        } catch {
            return $true
        }
        if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Invoke-InstallVerifyNewFiles {
    <#
      APP-UPDATE-SPEC.md section 8.6 (the self-relaunch-dependent-health-
      check fix): the OLD health check waited on WHOEVER Invoke-
      InstallRelaunch had just started to answer /api/ping - fine for
      -Relaunch window (the launcher starts addon-server.ps1 itself, right
      away), but -Relaunch tray starts host\bin\FurphyHost.exe --tray
      directly, and THAT process does not start addon-server.ps1 until its
      own first background cycle (~90s later, confirmed live) - so the 20s
      health check found no server, declared a perfectly good upgrade
      unhealthy, and rolled it back every single time -Relaunch tray was
      used. -Relaunch none (the test-only value) never answered /api/ping
      at all, so the OLD code skipped the health check for it entirely.

      The fix: verify the NEW files ourselves, with our OWN short-lived
      addon-server.ps1 child pointed at $AppDest, BEFORE Invoke-
      InstallRelaunch ever runs and regardless of $Relaunch's value - the
      health check no longer depends on who (if anyone) is about to
      relaunch, or how soon they start a server of their own. Same command
      line shape deploy.ps1's own section-5 verify step and tests\lib\
      common.ps1's Start-TestServer already use to do exactly this for a
      fresh build/a test root; this is that same idea for a live -Upgrade.
      Reuses Test-InstallHealthCheck for the poll-for-version loop and
      Invoke-InstallServerShutdown for the CSRF-safe POST /api/shutdown
      rather than reimplementing either.

      Runs for -Relaunch none too, on purpose (see the caller) - a
      headless run now exercises the exact same health check every real
      -Relaunch window/tray run does.

      Defensive: if something is ALREADY listening on $AppDest's own port
      before this runs (the stop step at the top of Invoke-
      FurphyInstallSteps missed it - e.g. a server that ignored its own
      graceful shutdown request), that stale listener is shut down first
      (logged) so our own verification server's HttpListener bind never
      collides with it.

      Always stops the verification server itself before returning,
      whether the health check passed or failed - via the same graceful
      POST /api/shutdown, waited out with a bounded poll, with a
      by-PID-only Stop-Process fallback (never by name, never any other
      process) if it somehow does not exit on its own - so neither a
      passing nor a failing health check ever leaves an extra server bound
      to the install's port, or still holding a handle on addon-server.ps1
      itself, once this function returns. The caller's very next step is
      either Restore-InstallCodeFromRollback or Invoke-InstallRelaunch,
      both of which touch or replace files under $AppDest.

      Never throws - a failure anywhere in here (the server failing to
      start, the port refusing to close) is reported as Healthy=$false and
      best-effort logged, exactly like Test-InstallHealthCheck's own
      "never throws" contract, so a verification problem always reads as a
      failed health check (-> rollback) rather than an unhandled exception
      escaping the -Upgrade try/catch with a less specific error message.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [string]$WowRoot
    )

    $port = Get-InstallPort -AppDest $AppDest

    $preExisting = $false
    try {
        $probe = Invoke-RestMethod -Method Get -Uri "http://localhost:$port/api/ping" -TimeoutSec 2 -ErrorAction Stop
        if ($probe) { $preExisting = $true }
    } catch {
        # Nothing answering yet - the port is already free, as expected.
    }
    if ($preExisting) {
        Write-Warn2 "A server was already listening on port $port before verification (the stop step missed it) - shutting it down first."
        Invoke-InstallServerShutdown -AppDest $AppDest
        if (-not (Wait-InstallPortStopsAnswering -Port $port -TimeoutMs 5000)) {
            Write-Warn2 "Port $port was still answering 5s after asking the stale server to shut down - starting the verification server anyway."
        }
    }

    $serverScript = Join-Path -Path $AppDest -ChildPath 'addon-server.ps1'
    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.Add((ConvertTo-SafeProcessArg '-NoProfile'))
    $argList.Add((ConvertTo-SafeProcessArg '-ExecutionPolicy')); $argList.Add((ConvertTo-SafeProcessArg 'Bypass'))
    $argList.Add((ConvertTo-SafeProcessArg '-File')); $argList.Add((ConvertTo-SafeProcessArg $serverScript))
    $argList.Add((ConvertTo-SafeProcessArg '-Root')); $argList.Add((ConvertTo-SafeProcessArg $AppDest))
    $argList.Add((ConvertTo-SafeProcessArg '-IdleMinutes')); $argList.Add((ConvertTo-SafeProcessArg '2'))
    if ($WowRoot) {
        $argList.Add((ConvertTo-SafeProcessArg '-WowRoot')); $argList.Add((ConvertTo-SafeProcessArg $WowRoot))
    }

    $proc = $null
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() -WindowStyle Hidden -PassThru
    } catch {
        Write-Warn2 "Could not start the verification server: $($_.Exception.Message)"
        return [PSCustomObject]@{ Healthy = $false }
    }

    $healthy = Test-InstallHealthCheck -Port $port -ExpectedVersion $ExpectedVersion -TimeoutMs 30000
    if ($healthy) {
        Write-Info "Verification server on port $port answered with version $ExpectedVersion."
    } else {
        Write-Warn2 "Verification server on port $port did not answer with version $ExpectedVersion within 30s."
    }

    if ($proc -and $proc.HasExited) {
        Write-Warn2 "Verification server process had already exited (exit code $($proc.ExitCode)) - the new addon-server.ps1 likely failed to start."
    } else {
        Invoke-InstallServerShutdown -AppDest $AppDest
        $closed = Wait-InstallPortStopsAnswering -Port $port -TimeoutMs 10000
        if ($proc -and -not $proc.HasExited) {
            if ($closed) {
                try { $proc.WaitForExit(3000) | Out-Null } catch { }
            }
            if (-not $proc.HasExited) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                    Write-Warn2 'Verification server did not exit on its own after being asked to shut down - stopped it by PID.'
                } catch {
                    Write-Warn2 "Could not stop the verification server (pid $($proc.Id)): $($_.Exception.Message)"
                }
            }
        }
        if ($healthy) { Write-Info 'Verification server shut down.' }
    }

    return [PSCustomObject]@{ Healthy = $healthy }
}

function Invoke-InstallStartTray {
    <# Starts host\bin\FurphyHost.exe --tray directly - the exact
       command line StartupRegistry.BuildRunValue already builds
       (host\FurphyHost.cs:4440-4442) - so no window is ever opened by
       the updater itself on this path. Best-effort: logs and returns
       rather than throwing, since a caller mid-rollback must not have
       ITS OWN error swallowed by a relaunch failure here. #>
    param([Parameter(Mandatory = $true)][string]$AppDest)
    try {
        $trayExe = Join-Path -Path $AppDest -ChildPath 'host\bin\FurphyHost.exe'
        if (Test-Path -LiteralPath $trayExe -PathType Leaf) {
            Start-Process -FilePath $trayExe -ArgumentList @('--tray') | Out-Null
            Write-Info 'Relaunched the background tray.'
        } else {
            Write-Warn2 'Could not relaunch the tray - host\bin\FurphyHost.exe was not found.'
        }
    } catch {
        Write-Warn2 "Could not relaunch the tray: $($_.Exception.Message)"
    }
}

function Invoke-InstallRelaunch {
    <#
      APP-UPDATE-SPEC.md section 8.7: relaunch by CALLER INTENT, never by
      window-guessing - $Relaunch is decided server-side by who called
      POST /api/app-update/install, baked straight into this command
      line. "window" reuses the EXACT idiom the wizard's own post-install
      "Open Furphy Addon Manager" button already uses
      (Start-Process wscript.exe against Addon Manager.vbs). "tray"
      starts host\bin\FurphyHost.exe --tray directly. "none" is the
      test-only value (section 11/param block) - relaunches nothing.

      TRAY AND WINDOW ARE NOT MUTUALLY EXCLUSIVE (section 8.7): when
      $Relaunch is "window" and $TrayWasRunningIndependently was true (an
      independent tray was running BEFORE this upgrade stopped
      everything - detected by Invoke-InstallStopRunningApp before it
      stopped anything), ALSO start the tray, so a window-triggered
      install never silently kills an independently-running tray and
      leaves it dead until the user's next reboot. The reverse needs no
      code: -Relaunch tray is only ever chosen while no window is open
      (section 2's silent-install gate), so there is never an
      independent window instance for that branch to restore.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [Parameter(Mandatory = $true)][string]$Relaunch,
        [bool]$TrayWasRunningIndependently
    )
    if ($Relaunch -eq 'window') {
        try {
            $vbs = Join-Path -Path $AppDest -ChildPath 'Addon Manager.vbs'
            if (Test-Path -LiteralPath $vbs) {
                Start-Process -FilePath 'wscript.exe' -ArgumentList @('"' + $vbs + '"') | Out-Null
                Write-Info 'Relaunched Furphy Addon Manager.'
            } else {
                Write-Warn2 'Could not relaunch - Addon Manager.vbs was not found.'
            }
        } catch {
            Write-Warn2 "Could not relaunch Furphy Addon Manager: $($_.Exception.Message)"
        }
        if ($TrayWasRunningIndependently) {
            Invoke-InstallStartTray -AppDest $AppDest
        }
    } elseif ($Relaunch -eq 'tray') {
        Invoke-InstallStartTray -AppDest $AppDest
    } elseif ($Relaunch -eq 'none') {
        Write-Info 'Relaunch skipped (-Relaunch none).'
    } else {
        Write-Warn2 "Unrecognized -Relaunch value '$Relaunch' - nothing relaunched."
    }
}

function Remove-InstallStagedUpdateFolder {
    <#
      Shared by Invoke-InstallAppUpdateCleanup's success path AND (this
      round - previously missing) both Invoke-InstallRollbackAndRelaunchOld
      outcomes: deletes -StagedRoot (the %TEMP%\FurphyUpdate-* folder this
      install.ps1 process is itself running FROM under -Upgrade - it has
      done its job, whether the upgrade ended in success, a successful
      rollback, or a failed rollback) via a DELAYED, DETACHED self-delete
      (this running process's own script file lives inside that folder, so
      this can never be synchronous). No-op when -StagedRoot is empty or
      already gone. Never throws - a leftover staged folder is disk
      clutter, not a failed upgrade/rollback.
    #>
    param([string]$StagedRoot)
    if (-not $StagedRoot) { return }
    if (-not (Test-Path -LiteralPath $StagedRoot -PathType Container)) { return }
    try {
        $stagedRootEsc = $StagedRoot.Replace('"', '')
        $selfDeleteCmd = 'ping -n 3 127.0.0.1 >nul & rd /s /q "' + $stagedRootEsc + '"'
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ' + $selfDeleteCmd) -WindowStyle Hidden | Out-Null
    } catch {
        # Best-effort - a leftover staged folder is disk clutter, not a failed upgrade.
    }
}

function Invoke-InstallRollbackAndRelaunchOld {
    <#
      APP-UPDATE-SPEC.md section 8.6: shared by BOTH rollback triggers -
      a failing post-install health check, and an exception thrown
      during the copy/backup itself (the "gap" section 8.6 calls out by
      name: "the -Upgrade try/catch and the health-check-failure branch
      should converge on one shared internal helper"). Restores the old
      code from $BackupPath (skipped, as a no-op, when $BackupPath is
      $null/missing - i.e. the backup step itself never got far enough to
      produce one, in which case $AppDest was never touched and there is
      nothing to restore), relaunches the OLD version per the same
      $Relaunch intent, and records the outcome in app-update.json. If
      the restore ITSELF fails, per the failure-modes table this is
      "server left down; nothing further attempted automatically" - no
      relaunch is attempted in that case, since the code on disk is now
      in an unknown state.

      Wording fix (this round, found live - the self-contradicting
      lastError a real upgrade produced: "rollback FAILED after
      post-install health check failed - rolled back to 1.21.9 - manual
      reinstall required" even though the restore had, in fact, succeeded):
      -Reason is ONLY the trigger ("post-install health check failed" /
      "install failed while copying files") - never the outcome - so the
      two outcome messages below can never collide with each other.
      "rolled back to <OldVersion> after <Reason>" is written ONLY once
      the restore has actually succeeded; "rollback FAILED after <Reason>
      - manual reinstall required (backup at <BackupPath>)" is written
      ONLY when Restore-InstallCodeFromRollback itself threw - exactly one
      of the two is ever true for a given call. Invoke-InstallRelaunch
      (the RESTORED files) is likewise only ever reached on the successful
      branch - a failed restore leaves the code on disk in an unknown
      state and relaunches nothing, per the failure-modes table above.

      Also (this round): deletes the staged -Upgrade source folder
      (-StagedRoot, the caller's own $SourceRoot) on EITHER outcome, via
      Remove-InstallStagedUpdateFolder (shared with Invoke-
      InstallAppUpdateCleanup's success path, defined just above) - a
      rollback used to leave that %TEMP%\FurphyUpdate-* folder behind
      forever, since only the success path ever cleaned it up.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$Relaunch,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$OldVersion,
        [bool]$TrayWasRunningIndependently,
        [string]$StagedRoot
    )
    Write-Warn2 "$Reason"

    $restoreAttempted = ($BackupPath -and (Test-Path -LiteralPath $BackupPath -PathType Container))
    $restoreOk = $true
    if ($restoreAttempted) {
        try {
            Restore-InstallCodeFromRollback -AppDest $AppDest -BackupPath $BackupPath
            Write-Info "Restored the previous version ($OldVersion)."
        } catch {
            $restoreOk = $false
            Write-Warn2 "Rollback restore itself failed: $($_.Exception.Message)"
        }
    }

    $nowIso = Get-InstallUtcNowIso
    Remove-InstallStagedUpdateFolder -StagedRoot $StagedRoot

    if (-not $restoreOk) {
        $lastError = "rollback FAILED after $Reason - manual reinstall required (backup at $BackupPath)"
        Set-InstallAppUpdateJsonFields -AppDest $AppDest -Fields @{
            state       = 'error'
            lastError   = $lastError
            lastErrorAt = $nowIso
        }
        Write-InstallLogLine "App-update rollback FAILED - manual reinstall required, backup at $BackupPath"
        return [PSCustomObject]@{ Restored = $false }
    }

    $lastError = "rolled back to $OldVersion after $Reason"
    Set-InstallAppUpdateJsonFields -AppDest $AppDest -Fields @{
        state       = 'error'
        lastError   = $lastError
        lastErrorAt = $nowIso
    }
    Write-InstallLogLine "App-update: $lastError"

    Invoke-InstallRelaunch -AppDest $AppDest -Relaunch $Relaunch -TrayWasRunningIndependently $TrayWasRunningIndependently

    return [PSCustomObject]@{ Restored = $true }
}

function Invoke-InstallAppUpdateCleanup {
    <#
      APP-UPDATE-SPEC.md section 8.8, success path only: deletes the
      downloaded cache\app-update\*.zip/*.sha256 (best-effort - never
      fails an otherwise-successful upgrade over this), marks
      app-update.json state="installed" with a fresh installedAt and a
      cleared stagedPath, and schedules a DELAYED, DETACHED removal of
      $StagedRoot (the staged extraction folder this install.ps1 process
      is itself running FROM under -Upgrade - it has done its job, per
      section 8.8) - never synchronous, since this running process's own
      script file lives inside that folder, mirroring the existing
      delayed self-delete idiom this file already uses for the temp
      -Uninstall script copy. $StagedRoot is expected to be $SourceRoot
      and ONLY ever passed when $Upgrade is set - a normal manual install
      must never have its source folder (wherever the user unzipped it)
      scheduled for deletion. The actual delete is Remove-
      InstallStagedUpdateFolder (defined further below, alongside Invoke-
      InstallRollbackAndRelaunchOld, which shares it for its own two
      rollback outcomes) - factored out this round so a rollback can call
      the exact same delete logic instead of only this success path ever
      cleaning up.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppDest,
        [string]$StagedRoot
    )
    try {
        $cacheDir = Join-Path -Path $AppDest -ChildPath 'cache\app-update'
        if (Test-Path -LiteralPath $cacheDir -PathType Container) {
            Get-ChildItem -LiteralPath $cacheDir -File -Filter '*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $cacheDir -File -Filter '*.sha256' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Best-effort only - never fail an otherwise-successful upgrade over cache cleanup.
    }

    Set-InstallAppUpdateJsonFields -AppDest $AppDest -Fields @{
        state       = 'installed'
        installedAt = (Get-InstallUtcNowIso)
        stagedPath  = $null
        lastError   = $null
    }

    Remove-InstallStagedUpdateFolder -StagedRoot $StagedRoot
}

function Invoke-FurphyInstallSteps {
    <#
      DISTRIBUTION-SPEC.md section 6.2/6.3: steps 3-8 of the installer,
      unchanged from before this round - wrapped in a function purely so
      BOTH the plain console flow and Show-InstallWizard's Install-button
      click handler can call the exact same code (the spec's own promise:
      "only how progress/success is presented changes; the underlying
      file-system steps are unchanged"). Every Write-Step/Write-Info/
      Write-Warn2 call inside already doubles as the wizard's progress-pump
      (Update-WizardProgress, defined near the top of this file) with zero
      changes needed here. Reads $wowRoot/$appDest/$homeFlavour/etc from
      script scope (set by Set-InstallPathsFromWowRoot before this is ever
      called) rather than taking parameters, since a console run and a
      wizard run both already share that same script-scoped state.

      APP-UPDATE-SPEC.md section 8.5: also now unconditionally stops any
      running Furphy process (window or tray) under $appDest before Step
      3 ever copies/overwrites a file - the load-bearing fix a
      self-updater's own upgrade absolutely requires (Step 3b's
      unguarded host\bin\FurphyHost.exe copy throws
      ERROR_SHARING_VIOLATION if that exe is still open) and a
      correctness fix for the EXISTING plain reinstall/repair path too
      (this bug pre-dates this feature). Sections 8.6/8.7/8.8 add
      backup/rollback/relaunch/cleanup, but only when $Upgrade is set.
    #>

$Script:StopRunningAppResult = Invoke-InstallStopRunningApp -AppDest $appDest -SkipRunValueRemoval
$trayWasRunningIndependently = [bool]$Script:StopRunningAppResult.TrayWasRunningIndependently

$oldVersionRaw = 'unknown'
try {
    $existingVersionFile = Join-Path -Path $appDest -ChildPath 'VERSION'
    if (Test-Path -LiteralPath $existingVersionFile -PathType Leaf) {
        $oldVersionRaw = ([System.IO.File]::ReadAllText($existingVersionFile)).Trim()
    }
} catch {
    # Best-effort only - used solely for rollback log/status messages
    # below; a read failure here must never block the install itself.
}

# =====================================================================
# 2b. Downgrade guard (upgrade-1.1.0:upgrade-1.1.0-downgrade-hides-addons):
#     refuse to copy an OLDER installer's code over a NEWER on-disk
#     install. An old install.ps1 (e.g. a stale cached zip or shortcut)
#     copied over a current, already-migrated install leaves
#     settings.json's schemaVersion untouched (old code has no idea
#     flavours\<id>\addons.json exists) but overwrites addon-sync.ps1/
#     addon-server.ps1/ui\ with pre-flavour code that hardcodes a
#     top-level addons.json path - the app then reports the user has ZERO
#     tracked addons, even though nothing was actually deleted on disk.
#     Compared as [version] objects (major.minor.patch as integers), never
#     as strings, so "1.9.0" does not sort ahead of "1.10.0". Bypassed
#     only by an explicit -Force switch; a same-version repair or a
#     genuinely newer installer (the normal upgrade path) is unaffected.
# =====================================================================

$Script:DowngradeSkipped = $false
try {
    $destVersionFile = Join-Path -Path $appDest -ChildPath 'VERSION'
    $srcVersionFile = Join-Path -Path $SourceRoot -ChildPath 'VERSION'
    if ((-not $Force) -and (Test-Path -LiteralPath $destVersionFile -PathType Leaf) -and (Test-Path -LiteralPath $srcVersionFile -PathType Leaf)) {
        $destVersionRaw = ([System.IO.File]::ReadAllText($destVersionFile)).Trim()
        $srcVersionRaw = ([System.IO.File]::ReadAllText($srcVersionFile)).Trim()
        $destVersionParsed = $null
        $srcVersionParsed = $null
        if ([System.Version]::TryParse($destVersionRaw, [ref]$destVersionParsed) -and [System.Version]::TryParse($srcVersionRaw, [ref]$srcVersionParsed)) {
            if ($destVersionParsed -gt $srcVersionParsed) {
                Write-Warn2 "This copy of Furphy Addon Manager ($srcVersionRaw) is older than what's already installed ($destVersionRaw) at $appDest. Installing it would replace the newer app with an older one, and your addon list could look empty until you reinstall the newer version instead. Nothing was changed."
                $Script:DowngradeSkipped = $true
            }
        }
    }
} catch {
    # Best-effort only - if the VERSION files can't be read/parsed, fall
    # through to the normal install rather than blocking a real install
    # over a comparison failure.
}
if ($Script:DowngradeSkipped) { return }

# =====================================================================
# 3/3b/4. Copy the app + host\ + parse-check (Invoke-InstallCopyAndBuild
#         Steps, defined above - extracted unchanged so both this plain
#         path and the -Upgrade path below share one implementation).
#         APP-UPDATE-SPEC.md sections 8.6/8.7/8.8: under -Upgrade only,
#         wraps that same copy in backup/health-check/rollback/relaunch/
#         cleanup. A plain install/repair (no -Upgrade) runs Invoke-
#         InstallCopyAndBuildSteps bare, exactly as before this feature -
#         a throw there still propagates straight out, unchanged error
#         behavior.
#         This round: the health check (Invoke-InstallVerifyNewFiles) now
#         runs BEFORE Invoke-InstallRelaunch, using its own short-lived
#         verification server rather than whatever Invoke-InstallRelaunch
#         just started - it no longer depends on who relaunches or how
#         soon they start a server of their own (see that function's own
#         doc comment), and it now runs for -Relaunch none too, not only
#         window/tray.
# =====================================================================

if ($Upgrade) {
    $upgradeRelaunch = $Relaunch
    if ($upgradeRelaunch -notin @('window', 'tray', 'none')) {
        Write-Warn2 "Unrecognized -Relaunch value '$Relaunch' - treating as 'none' (nothing will be relaunched)."
        $upgradeRelaunch = 'none'
    }

    Write-Step 'Backing up the current version before upgrading'
    $backupPath = $null
    try {
        $backupPath = Backup-InstallCodeForRollback -AppDest $appDest
    } catch {
        Write-Warn2 "Could not create a rollback backup before upgrading - nothing was changed: $($_.Exception.Message)"
        Set-InstallAppUpdateJsonFields -AppDest $appDest -Fields @{
            state       = 'error'
            lastError   = "could not create a rollback backup before upgrading - nothing was changed: $($_.Exception.Message)"
            lastErrorAt = (Get-InstallUtcNowIso)
        }
        Invoke-InstallRelaunch -AppDest $appDest -Relaunch $upgradeRelaunch -TrayWasRunningIndependently $trayWasRunningIndependently
        return
    }

    # APP-UPDATE-SPEC.md section 8.6 (the gap fix): everything from the
    # backup above through the end of the copy + parse-check block runs
    # inside ONE try/catch, under -Upgrade only - a disk-full/locked-file
    # exception during the copy itself is caught here and rolls back
    # exactly like a failed post-install health check does, converging on
    # the same Invoke-InstallRollbackAndRelaunchOld helper.
    try {
        Invoke-InstallCopyAndBuildSteps

        $newVersionRaw = 'unknown'
        try {
            $newVersionFile = Join-Path -Path $appDest -ChildPath 'VERSION'
            if (Test-Path -LiteralPath $newVersionFile -PathType Leaf) {
                $newVersionRaw = ([System.IO.File]::ReadAllText($newVersionFile)).Trim()
            }
        } catch { }

        Write-Step 'Verifying the new version before relaunching'
        $verifyResult = Invoke-InstallVerifyNewFiles -AppDest $appDest -ExpectedVersion $newVersionRaw -WowRoot $wowRoot
        if (-not $verifyResult.Healthy) {
            Invoke-InstallRollbackAndRelaunchOld -AppDest $appDest -BackupPath $backupPath -Relaunch $upgradeRelaunch -Reason 'post-install health check failed' -OldVersion $oldVersionRaw -TrayWasRunningIndependently $trayWasRunningIndependently -StagedRoot $SourceRoot
            return
        }
        Write-Info 'Health check passed.'

        Write-Step 'Relaunching Furphy'
        Invoke-InstallRelaunch -AppDest $appDest -Relaunch $upgradeRelaunch -TrayWasRunningIndependently $trayWasRunningIndependently

        Invoke-InstallAppUpdateCleanup -AppDest $appDest -StagedRoot $SourceRoot
        Write-Info "Upgrade to $newVersionRaw complete."
    } catch {
        Invoke-InstallRollbackAndRelaunchOld -AppDest $appDest -BackupPath $backupPath -Relaunch $upgradeRelaunch -Reason 'install failed while copying files' -OldVersion $oldVersionRaw -TrayWasRunningIndependently $trayWasRunningIndependently -StagedRoot $SourceRoot
        return
    }
} else {
    Invoke-InstallCopyAndBuildSteps
}

# =====================================================================
# 5. Legacy launcher cleanup (Round 34, REMOVAL-SPEC.md CS-R12)
#    This installer no longer writes a per-flavour launcher pair or a
#    WoW Desktop shortcut - Round 34 removed WoW-launching entirely,
#    since the background service already keeps addons updated on its
#    own. An ordinary upgrade run (this is exactly that - no -Uninstall
#    flag) previously never looked for a STALE pair/shortcut left behind
#    by an older install, so this step (shared with the -Uninstall path
#    above) runs unconditionally here to actually clean up an existing
#    machine the moment its install is upgraded to this version.
# =====================================================================

Write-Step 'Cleaning up legacy launcher files'
Remove-FurphyLegacyLauncherArtifacts -WowRootPath $wowRoot -AppDestPath $appDest | Out-Null

$cliPath = Join-Path -Path $appDest -ChildPath 'addon-sync.ps1'

# =====================================================================
# 6. Desktop shortcut
#    One shortcut, "Furphy Addon Manager.lnk", regardless of how many
#    flavours are installed. Round 34 removed the per-flavour WoW
#    launcher shortcut(s) along with WoW-launching itself.
# =====================================================================

# Round 42 defense-in-depth: this step writes to the REAL Windows Desktop.
# -NoShortcuts is the authoritative opt-out, but it is pure caller
# discipline - until now a scratch/test run that forgot the flag created
# a real "Furphy Addon Manager.lnk" pointing at a temp folder. Mirror the
# exact two-layer guard Remove-FurphyLegacyLauncherArtifacts and the
# -Uninstall block's shortcut removal already use: Test-LooksLikeScratchRun
# (a $wowRoot/$appDest under %TEMP%, a \scratch\ folder, or
# fixtures\wowroot) skips with a warning even when -NoShortcuts was
# forgotten. Changes nothing for a genuine production install, which
# never sits under any of those paths.
$looksScratchStep6 = (Test-LooksLikeScratchRun $wowRoot) -or (Test-LooksLikeScratchRun $appDest)
if ($looksScratchStep6 -and (-not $NoShortcuts)) {
    Write-Warn2 'Target path looks like a scratch/test root but -NoShortcuts was not passed - skipping Desktop shortcut creation for safety. Pass -NoShortcuts explicitly for scratch runs; a production install never lives under a temp or scratch path.'
} elseif (-not $NoShortcuts) {
    Write-Step 'Creating desktop shortcut'
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $wsh = New-Object -ComObject WScript.Shell

        $sc1 = $wsh.CreateShortcut((Join-Path -Path $desktop -ChildPath 'Furphy Addon Manager.lnk'))
        $sc1.TargetPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wscript.exe'
        $sc1.Arguments = '"' + (Join-Path -Path $appDest -ChildPath 'Addon Manager.vbs') + '"'
        $sc1.WorkingDirectory = $appDest
        $iconIco = Join-Path -Path $appDest -ChildPath 'icon.ico'
        if (Test-Path -LiteralPath $iconIco) { $sc1.IconLocation = $iconIco }
        $sc1.Save()
        Write-Info 'Created shortcut: Furphy Addon Manager'
    } catch {
        Write-Warn2 "Could not create the desktop shortcut: $($_.Exception.Message)"
    }
} else {
    Write-Info 'Skipped desktop shortcut (-NoShortcuts).'
}

# =====================================================================
# 7. curseforge:// protocol handler
#    FLAVORS-SPEC S5.5/S7.3: unchanged, verbatim - one app, one server,
#    one port, one registration regardless of flavour count.
# =====================================================================

# Round 42 defense-in-depth (same reasoning as Step 6 above):
# register-protocol.ps1 -Register writes the REAL
# HKCU:\Software\Classes\curseforge key (its -KeyPath override is a
# test hook this call site never passes), so a scratch/test run that
# forgot -NoProtocol repointed the user's real install-link handler at a
# temp folder. Same Test-LooksLikeScratchRun warn-and-skip guard.
$looksScratchStep7 = (Test-LooksLikeScratchRun $wowRoot) -or (Test-LooksLikeScratchRun $appDest)
if ($looksScratchStep7 -and (-not $NoProtocol)) {
    Write-Warn2 'Target path looks like a scratch/test root but -NoProtocol was not passed - skipping curseforge:// protocol registration for safety (it would rewrite the real HKCU\Software\Classes\curseforge key). Pass -NoProtocol explicitly for scratch runs.'
} elseif (-not $NoProtocol) {
    Write-Step 'Registering the curseforge:// install-link handler'
    $regScript = Join-Path -Path $appDest -ChildPath 'register-protocol.ps1'
    if (Test-Path -LiteralPath $regScript) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regScript -Register -Json | Out-Null
            Write-Info 'Registered. Clicking Install on a CurseForge addon page now opens here.'
        } catch {
            Write-Warn2 "Could not register the protocol handler: $($_.Exception.Message)"
        }
    } else {
        Write-Warn2 'register-protocol.ps1 was not found in the deployed app - skipped.'
    }
} else {
    Write-Info 'Skipped protocol registration (-NoProtocol).'
}

# =====================================================================
# 8. Adopt existing addon folders
#    FLAVORS-SPEC S7.1: runs once per INSTALLED flavour (not just the
#    app's home flavour) - a first-time install on a Retail+Classic
#    machine offers to take over both AddOns folders' existing contents
#    in the same first-run flow, one independent yes/no decision per
#    flavour. Each call passes -Flavor explicitly (not just -AddonsPath)
#    so the scanned/adopted records land in that flavour's own
#    flavours\<id>\addons.json - -AddonsPath alone would resolve the
#    right folder to scan but NOT the right addons.json to write to
#    (Resolve-AddonsPath honors -AddonsPath directly, but which
#    flavours\<id>\ subfolder Main writes into is driven entirely by
#    -Flavor, independent of -AddonsPath - passing one without the other
#    would silently file a Classic addon's record under flavours\retail\).
# =====================================================================

if (-not $SkipAdopt) {
    Write-Step 'Looking for existing addons to take over'
    # multi-client:install-adopt-loop-includes-hidden-ptr-flavour fix:
    # FLAVORS-SPEC.md S2.5 says PTR/XPTR/Beta stay "detected but excluded
    # from the switcher and from tray background sync by default" until
    # the player turns on Settings > Advanced > "Show test realms" - every
    # other multi-flavour surface (ui/app.js's Store.visibleFlavours(),
    # addon-server.ps1's update-all-flavours fan-out) already filters
    # accordingly, but this loop used to iterate the UNFILTERED
    # $installedFlavours list (every FLAVORS-SPEC S2.1 folder detected,
    # PTR/XPTR/Beta included). $script:firstClassInstalled (computed by
    # Set-InstallPathsFromWowRoot, already in scope here) is the same
    # first-class-only filter those other surfaces use - a first-time
    # install on a machine with a live PTR client must not scan/offer to
    # take over PTR addons before the player has ever opted into
    # seeing/managing PTR anywhere else in the app.
    $showFlavourHeader = ($script:firstClassInstalled.Count -gt 1)

    foreach ($def in $script:firstClassInstalled) {
        $flavourAddonsPath = Join-Path -Path (Join-Path -Path $wowRoot -ChildPath $def.Folder) -ChildPath 'Interface\AddOns'
        if (-not (Test-Path -LiteralPath $flavourAddonsPath -PathType Container)) { continue }
        if ($showFlavourHeader) { Write-Info "-- $($def.Label) --" }

        $scanJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -AddonsPath $flavourAddonsPath -Flavor $def.Id -Scan -Json
        $scan = $null
        try { $scan = $scanJson | ConvertFrom-Json } catch { $scan = $null }

        # Bug fix found during CS-F5 verification (pre-existing, not
        # introduced by flavours): "-not $scan.untracked" is also true for
        # a genuinely-empty (but successfully parsed) untracked array -
        # PowerShell treats an empty collection as falsy - which wrongly
        # printed "Could not read scan results" for any flavour whose
        # AddOns folder has nothing untracked in it (exercised live by the
        # S8 fixture's empty _ptr_\Interface\AddOns). Check $scan itself
        # (did ConvertFrom-Json actually produce an object) instead.
        if (-not $scan) {
            Write-Info 'Could not read scan results - skipped taking over.'
            continue
        }

        $untracked = @($scan.untracked)
        $targets = New-Object 'System.Collections.Generic.List[string]'
        $unmanaged = New-Object 'System.Collections.Generic.List[string]'
        foreach ($u in $untracked) {
            if ($u.curseId) {
                $targets.Add([string]$u.curseId)
            } elseif ($u.wagoId) {
                $targets.Add('wago:' + [string]$u.wagoId)
            } else {
                $unmanaged.Add([string]$u.folder)
            }
        }

        if ($targets.Count -eq 0) {
            Write-Info 'No untracked folders with a recognizable CurseForge or Wago id - nothing to take over.'
        } else {
            $idArg = [string]::Join(',', $targets.ToArray())
            Write-Info "Taking over $($targets.Count) addon(s) (reinstalling each from its source)..."
            $addJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -AddonsPath $flavourAddonsPath -Flavor $def.Id -Add $idArg -Json
            $addResult = $null
            try { $addResult = $addJson | ConvertFrom-Json } catch { $addResult = $null }
            if ($addResult -and $addResult.results) {
                foreach ($r in @($addResult.results)) {
                    Write-Info ("  " + $r.status + ": " + $r.name)
                }
            } else {
                Write-Warn2 'Could not parse the take-over step''s results - check sync.log.'
            }
        }

        if ($unmanaged.Count -gt 0) {
            Write-Info 'Left unmanaged (no CurseForge or Wago id found):'
            foreach ($name in $unmanaged) { Write-Info ("  - " + $name) }
        }
    }
} else {
    Write-Info 'Skipped taking over existing addons (-SkipAdopt).'
}

# =====================================================================
# 9. Installed-Apps registration (DISTRIBUTION-SPEC.md section 5.4) -
#    written at install time AND re-written on every upgrade (this
#    function runs on every install.ps1 call that reaches here, upgrade or
#    fresh), scoped the SAME way as the Run value (fix 3: Get-
#    InstallAppsKeyName forwards to Get-InstallStartupValueName) - a
#    scratch/test root on the production port owns neither name and
#    writes neither key. HKCU only, never HKLM - no admin needed, matching
#    every other registry write this file already makes.
# =====================================================================

Write-Step 'Registering with Windows Settings > Apps'
$installAppsKeyName = Get-InstallAppsKeyName -AppDest $appDest
if ($null -eq $installAppsKeyName) {
    Write-Info 'Scratch/test install on the production port - skipped (nothing of its own to register).'
} else {
    try {
        $installVersion = '0.0.0'
        $versionFile = Join-Path -Path $appDest -ChildPath 'VERSION'
        if (Test-Path -LiteralPath $versionFile) {
            $vt = ([IO.File]::ReadAllText($versionFile)).Trim()
            if ($vt.Length -gt 0) { $installVersion = $vt }
        }
        $installPort = Get-InstallPort -AppDest $appDest
        $installAppsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $installAppsKeyName
        if (-not (Test-Path -LiteralPath $installAppsKeyPath)) {
            New-Item -Path $installAppsKeyPath -Force | Out-Null
        }
        $uninstallCmd = Get-InstallUninstallString -Port $installPort -AppDest $appDest -WowRootPath $wowRoot
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'DisplayName' -Value 'Furphy Addon Manager' -Type String
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'DisplayVersion' -Value $installVersion -Type String
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'Publisher' -Value 'krenz444' -Type String
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'InstallLocation' -Value $appDest -Type String
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'DisplayIcon' -Value (Join-Path -Path $appDest -ChildPath 'icon.ico') -Type String
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'EstimatedSize' -Value (Get-InstallEstimatedSizeKB -Path $appDest) -Type DWord
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'NoModify' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'NoRepair' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'UninstallString' -Value $uninstallCmd -Type String
        Set-ItemProperty -LiteralPath $installAppsKeyPath -Name 'QuietUninstallString' -Value $uninstallCmd -Type String
        Write-Info 'Windows Settings > Apps now lists Furphy Addon Manager with a working Uninstall entry.'
    } catch {
        Write-Warn2 "Could not write the Installed-Apps registry entry: $($_.Exception.Message)"
    }
}

# =====================================================================
# Done
# =====================================================================

Write-Host ''
Write-Host 'Install complete.' -ForegroundColor Green
Write-Info "App:      $appDest"
Write-Info "AddOns:   $addonsPath"
if ($installedFlavours.Count -gt 1) {
    Write-Info ("Flavours: " + (($installedFlavours | ForEach-Object { $_.Label }) -join ', '))
}
Write-Info 'No CurseForge API key needed - Get new addons and installs both work out of the box.'
}

# =====================================================================
# Dispatch: console flow vs. the optional WinForms wizard
# (DISTRIBUTION-SPEC.md section 6.2)
# =====================================================================

function Show-InstallWizard {
    <#
      DISTRIBUTION-SPEC.md section 6.2/6.3: optional WinForms front end,
      built with the exact same Add-Type -AssemblyName System.Windows.
      Forms/System.Drawing mechanism host\build-host.ps1 already proves
      works with zero extra tooling on a real end-user machine (E19).
      Wraps the EXISTING, unchanged install logic (Invoke-
      FurphyInstallSteps) - only how progress/success is PRESENTED changes
      here, never the underlying file-system steps.

      Throws if the Form itself cannot be constructed (old machine, unusual
      DPI, non-interactive/CI session) - the caller (the dispatch block
      below) catches that and falls straight through to the existing,
      unmodified console flow (fix 6's MANDATORY fallback). The console is
      hidden (Hide-InstallConsole) only once construction has fully
      succeeded, per fix 6 - never before. Once past construction, any
      error from Invoke-FurphyInstallSteps itself is caught INSIDE the
      click handler below and shown as a plain-language error screen, not
      re-thrown - so a mid-install failure never triggers the console
      fallback a SECOND time; only a genuine construction failure does.
    #>
    param([string]$InitialWowRoot)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # installer-dpi:installer-no-visual-styles fix: must run before the
    # first Form/Control is constructed (same ordering constraint as
    # host\FurphyHost.cs:37-38's Application.EnableVisualStyles() /
    # SetCompatibleTextRenderingDefault(false) as its first two
    # statements) so the wizard - the very first thing a novice sees -
    # renders with the current Windows visual style instead of flat
    # classic-Windows buttons and the legacy default font.
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Furphy Addon Manager - Install'
    $form.ClientSize = New-Object System.Drawing.Size(480, 250)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.AutoScaleMode = 'Font'

    # installer-dpi:installer-wizard-no-acceptbutton-initial-focus fix
    # (Escape/Cancel behaviour): a small invisible button gives Escape a
    # real, safe action - close the wizard - on every screen this one
    # Form ever shows (initial picker, success, error), without adding a
    # visible Cancel control the initial screen doesn't otherwise need
    # (see the fix note: no explicit Cancel action exists today, only
    # Browse/Install).
    $btnCancelHidden = New-Object System.Windows.Forms.Button
    $btnCancelHidden.Size = New-Object System.Drawing.Size(0, 0)
    $btnCancelHidden.TabStop = $false
    $btnCancelHidden.Visible = $false
    $btnCancelHidden.Add_Click({ $form.Close() })
    $form.Controls.Add($btnCancelHidden)
    $form.CancelButton = $btnCancelHidden

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $false
    $lblStatus.Size = New-Object System.Drawing.Size(440, 40)
    $lblStatus.Location = New-Object System.Drawing.Point(20, 16)
    if ($InitialWowRoot) {
        $lblStatus.Text = "Furphy found World of Warcraft in $InitialWowRoot"
    } else {
        $lblStatus.Text = 'Furphy could not find World of Warcraft automatically. Choose your WoW folder below.'
    }
    $form.Controls.Add($lblStatus)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(20, 60)
    $txtPath.Size = New-Object System.Drawing.Size(340, 24)
    $txtPath.Text = [string]$InitialWowRoot
    $txtPath.ReadOnly = $true
    $form.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(370, 58)
    $btnBrowse.Size = New-Object System.Drawing.Size(90, 26)
    $form.Controls.Add($btnBrowse)

    # installer-dpi:installer-no-progress-bar-control fix: a real,
    # always-visible ProgressBar (Marquee - the install steps aren't
    # counted/weighted anywhere today, so a determinate bar has nothing
    # accurate to report) so every step, including the multi-second
    # csc.exe compile DISTRIBUTION-SPEC.md's fix-6 text already accepts
    # as "a brief, few-second UI freeze", shows visible motion instead of
    # a static label that can read as "did this hang?" to a
    # below-average-tech user (DISTRIBUTION-SPEC.md line 597 step 7 /
    # SPEC.md E19). No extra wiring needed: Update-WizardProgress's
    # existing Application.DoEvents() pump (called from every
    # Write-Step/Write-Info/Write-Warn2 during Invoke-FurphyInstallSteps)
    # already animates it between steps.
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Size = New-Object System.Drawing.Size(340, 16)
    $progressBar.Location = New-Object System.Drawing.Point(20, 100)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 30
    $form.Controls.Add($progressBar)

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.AutoSize = $false
    $progressLabel.Size = New-Object System.Drawing.Size(340, 60)
    $progressLabel.Location = New-Object System.Drawing.Point(20, 122)
    $progressLabel.Text = ''
    $form.Controls.Add($progressLabel)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = 'Install'
    $btnInstall.Location = New-Object System.Drawing.Point(370, 192)
    $btnInstall.Size = New-Object System.Drawing.Size(90, 32)
    $btnInstall.Enabled = [bool]$InitialWowRoot
    $form.Controls.Add($btnInstall)

    # installer-dpi:installer-wizard-no-acceptbutton-initial-focus fix
    # (item 1): Enter now does the obvious thing on the very first
    # screen, and initial focus lands on whichever control is actually
    # usable next (Install when a WoW root was auto-detected, Browse
    # when it wasn't - AcceptButton alone doesn't move focus, so both
    # are needed). Wired via Add_Shown rather than a bare .Focus() call
    # here, since the form's handle isn't created/visible yet at
    # construction time - a bare call before ShowDialog() is unreliable.
    $form.AcceptButton = $btnInstall
    $form.Add_Shown({
        if ($InitialWowRoot) { $btnInstall.Focus() } else { $btnBrowse.Focus() }
    })

    $btnBrowse.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = 'Select your World of Warcraft folder (the one containing _retail_, _classic_, etc)'
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:wowRoot = $fbd.SelectedPath
            $script:installedFlavours = @(Get-InstalledFlavourDefs -WowRootPath $script:wowRoot)
            if ($script:installedFlavours.Count -gt 0) {
                Set-InstallPathsFromWowRoot
                $txtPath.Text = $script:wowRoot
                $btnInstall.Enabled = $true
                $lblStatus.Text = "Furphy found World of Warcraft in $($script:wowRoot)"
            } else {
                [System.Windows.Forms.MessageBox]::Show('No WoW client folder was found there. Pick the folder that contains _retail_, _classic_, etc.', 'Furphy Addon Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        }
    })

    $btnInstall.Add_Click({
        $btnInstall.Enabled = $false
        $btnBrowse.Enabled = $false
        $Script:WizardActive = $true
        $Script:WizardProgressLabel = $progressLabel
        try {
            $Script:DowngradeSkipped = $false
            Invoke-FurphyInstallSteps
            $Script:WizardActive = $false
            # upgrade-1.1.0:upgrade-1.1.0-downgrade-hides-addons fix: the
            # downgrade guard inside Invoke-FurphyInstallSteps returns
            # early (nothing copied) rather than throwing, so this success
            # branch runs either way - show an honest, distinct message
            # instead of claiming an install happened when it didn't.
            if ($Script:DowngradeSkipped) {
                $lblStatus.Text = 'Nothing was changed - a newer version is already installed there.'
                $progressLabel.Text = "App: $($script:appDest)`r`nThis copy is older than what's already installed, so it was left alone."
            } else {
                $lblStatus.Text = 'Furphy Addon Manager is installed.'
                $progressLabel.Text = "App: $($script:appDest)`r`nNothing in your AddOns folder was touched."
            }
            $btnInstall.Visible = $false
            $btnClose = New-Object System.Windows.Forms.Button
            $btnClose.Text = 'Close'
            $btnClose.Location = New-Object System.Drawing.Point(370, 192)
            $btnClose.Size = New-Object System.Drawing.Size(90, 32)
            $btnClose.Add_Click({ $form.Close() })
            $form.Controls.Add($btnClose)
            $btnOpen = New-Object System.Windows.Forms.Button
            $btnOpen.Text = 'Open Furphy Addon Manager'
            $btnOpen.Location = New-Object System.Drawing.Point(20, 192)
            $btnOpen.Size = New-Object System.Drawing.Size(220, 32)
            $btnOpen.Add_Click({
                try {
                    $vbs = Join-Path -Path $script:appDest -ChildPath 'Addon Manager.vbs'
                    if (Test-Path -LiteralPath $vbs) {
                        Start-Process -FilePath 'wscript.exe' -ArgumentList @('"' + $vbs + '"')
                    }
                } catch { }
                $form.Close()
            })
            $form.Controls.Add($btnOpen)
            # installer-dpi:installer-wizard-no-acceptbutton-initial-focus
            # fix (item 2): Enter on the success screen now triggers the
            # same primary action DISTRIBUTION-SPEC.md 6.2 describes
            # ("Open Furphy Addon Manager"). The error branch below reuses
            # $btnInstall (already AcceptButton from construction, per
            # item 3 of the fix note - no reassignment needed there).
            $form.AcceptButton = $btnOpen
        } catch {
            $Script:WizardActive = $false
            $lblStatus.Text = 'Something went wrong during install:'
            $progressLabel.Text = $_.Exception.Message
            $btnInstall.Text = 'Close'
            $btnInstall.Enabled = $true
            $btnInstall.Add_Click({ $form.Close() })
        }
    })

    # Fix 6: construction succeeded up to here - hide the console ONLY now,
    # then hand control to the Form's own message loop. If ANYTHING above
    # this line throws, the caller's catch block runs instead and the
    # console was never touched.
    Hide-InstallConsole
    [void]$form.ShowDialog()
}

if ($Console) {
    # The explicit skip-the-wizard escape hatch (also what every automated
    # test in this repo passes - a wizard run headless would call
    # ShowDialog() and hang forever with nothing to click). WoW-not-found
    # with -Console already exited 2 earlier, so $wowFound is guaranteed
    # true here and Set-InstallPathsFromWowRoot already ran above.
    Invoke-FurphyInstallSteps
    exit 0
}

try {
    $initialPathForWizard = $null
    if ($wowFound) { $initialPathForWizard = $wowRoot }
    Show-InstallWizard -InitialWowRoot $initialPathForWizard
    # The wizard's Form has closed (success or error screen dismissed) -
    # un-hide the console before exiting, see Show-InstallConsole's own
    # comment for why this matters even though nothing here writes to it.
    # SETUP-SPEC.md section 5.3: skip this when FurphySetup.exe launched
    # this run (env marker documented next to -Console/-Quiet above) -
    # such a run has no wrapping cmd.exe waiting on its console, so
    # un-hiding it here would only flash a console window on screen at
    # the very end of an otherwise console-free install.
    if (-not $env:FURPHY_INSTALL_LAUNCHED_BY_SETUP) { Show-InstallConsole }
    exit 0
} catch {
    Write-Warn2 "Could not show the install wizard, falling back to the console flow: $($_.Exception.Message)"
    if (-not $wowFound) {
        Write-Host ''
        Write-Host 'ERROR: Could not find a World of Warcraft installation.' -ForegroundColor Red
        Write-Host '       Pass -WowPath "<your WoW folder>" (the one that contains _retail_, _classic_, _classic_era_, etc).' -ForegroundColor Red
        exit 2
    }
    Invoke-FurphyInstallSteps
    exit 0
}
