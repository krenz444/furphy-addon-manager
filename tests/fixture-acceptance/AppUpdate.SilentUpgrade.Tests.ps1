<#
=====================================================================
 tests\fixture-acceptance\AppUpdate.SilentUpgrade.Tests.ps1  (Package E)

 Fixture-acceptance coverage for APP-UPDATE-SPEC.md sections 8.5/8.6/8.7
 - install.ps1's own -Upgrade mechanism (stop-running-app fix, backup,
   copy, rollback) - end to end against a REAL scratch install under
 tests\.tmp\, on scratch settings port 47940 (this round's assigned port
 for this file), full-run-only, same layer/lifecycle shape as its
 sibling tests\fixture-acceptance\FlavorsSpec.Section8.Tests.ps1 (a real
 install.ps1 run, incl. a real host\ rebuild, makes this too slow for
 tests\run-all.ps1 -Quick).

 CAPABILITY-GATED, ON PURPOSE, same shape as every other Package-E test
 file this round: written before install.ps1's own -Upgrade switch
 (Package B) existed at all. Greps the REAL install.ps1 source for the
 markers this file's own assertions depend on and skips with a clear
 PENDING message when they are not there yet.

 DELIBERATE DESIGN CHOICE - -Relaunch none, install.ps1 invoked DIRECTLY
 (never through the HTTP route / Package A's server): this build's own
 HARD LIVE-SAFETY RULES for this session forbid ever starting a real
 `--tray` process or opening a real window on this shared, interactive
 desktop, even a properly scratch-scoped one - "a scratch '--tray'
 process is NOT [allowed] (it would add a second tray icon on the
 user's screen)". APP-UPDATE-SPEC.md section 5's own POST
 /api/app-update/install body only ever accepts "window"|"tray" for
 -Relaunch (a FIXED interface - never renegotiated here); "none" is a
 TEST-ONLY value this file expects Package B to add to install.ps1's own
 -Relaunch parameter (never reachable through the HTTP route at all,
 since Handle-AppUpdateInstall's request-body validation never lets
 anything but "window"/"tray" through) meaning "skip any REAL process
 relaunch" - while STILL performing the backup, copy, parse-check, and
 the try/catch-driven rollback-on-COPY-EXCEPTION path (section 8.6's
 OTHER, independent failure mode) exactly as normal. This is a
 coordination note for whoever implements Package B, not a
 renegotiation of anything in sections 4/5/6/8.5's own fixed shapes.

 UPDATED THIS ROUND (the tray-relaunch-race fix, APPUPD-B5/B6 below):
 -Relaunch none no longer ALSO skips the health-check/rollback-on-
 health-check-failure step the way the paragraph above originally read -
 this build's own root-caused incident (a `-Relaunch tray` relaunch not
 starting addon-server.ps1 for up to ~90s, so the OLD health check, which
 only ever polled the RELAUNCHED process itself, always lost that race
 and rolled back every silent background self-update on its own success)
 is fixed by running the health check against a real, short-lived
 VERIFICATION instance of the newly staged code BEFORE any real relaunch
 happens at all, regardless of -Relaunch's own value - so -Relaunch none
 now exercises that same verification/health-check MECHANISM too, still
 without ever starting a real tray/window. Only a REAL tray/window
 relaunch's OWN /api/ping poll remains out of this file's reach (see the
 narrower KNOWN, DELIBERATE GAP below).

 This file therefore invokes install.ps1 -Upgrade DIRECTLY as its own
 child process (mirroring tests\integration\Install.Downgrade.Tests.ps1's
 own "run install.ps1 straight from a prepared source folder" idiom,
 inverted for a newer version), never via POST /api/app-update/install -
 there is no live addon-server.ps1 child under test here at all, and
 therefore nothing in this file ever touches app-update.json's
 SUCCESS-path fields (state="installed" etc.) - those are written by the
 SERVER (Package A) after a successful child exits, which has no part in
 this file's scope. install.ps1 DOES write app-update.json directly on
 its own FAILURE path (section 8.6) - this file's rollback Describes
 assert exactly that.

 KNOWN, DELIBERATE GAP (narrowed this round): section 12 also asks for a
 forced health-check-FAILURE case (as distinct from the copy-failure case
 this file already covered, and the health-check-failure case it now ALSO
 covers via -Relaunch none's own verification instance - see Describes 3/4
 below) - what remains permanently out of THIS file's reach is only a
 REAL tray/window relaunch's OWN /api/ping poll specifically, which by
 construction needs an actual relaunched process on this shared desktop.
 See the dedicated Describe below (still present, still capability-gated)
 for exactly this narrower reasoning stated as its own permanent PENDING
 skip - not silently dropped, not conflated with "package not landed
 yet". A future isolated/CI-only environment (never this session's own
 desktop) is the right place to add real coverage for it.

 Windows PowerShell 5.1, Pester 3 syntax, ASCII only.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# Litter-cleanup cutoff (this round's fixer task) - captured as the very
# first thing this file does, before any Describe below can possibly run
# install.ps1 -Upgrade and create a real %TEMP%\FurphyRollback-<hash>
# backup (section 8.6) or, once APPUPD-B5 lands, a real verification-
# related temp folder of its own. See tests\lib\common.ps1's own
# Remove-AppUpdateTempLitter doc comment for why this cutoff (never a
# blind sweep) is what makes it safe to run this file alongside another
# fixer's own concurrently-running test session on this same shared
# machine.
$Script:LitterCutoffUtc = (Get-Date).ToUniversalTime()

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'
$Script:InstallSourceText = Get-Content -LiteralPath $Script:InstallScript -Raw

# APPUPD-B1: the -Upgrade/-Relaunch param block entries.
$Script:CapUpgradeSwitch = [bool]($Script:InstallSourceText -match '\[switch\]\s*\$Upgrade\b')

# APPUPD-B2: the load-bearing stop-running-app fix (section 8.5), factored
# and called unconditionally.
$Script:CapStopRunningApp = [bool]($Script:InstallSourceText -match 'function\s+Invoke-InstallStopRunningApp\b')

# APPUPD-B3: backup/rollback (section 8.6).
$Script:CapRollback = [bool](
    ($Script:InstallSourceText -match 'function\s+Backup-InstallCodeForRollback\b') -and
    ($Script:InstallSourceText -match 'function\s+Restore-InstallCodeFromRollback\b')
)

# APPUPD-B4 (test-only ask of Package B - see this file's own header
# comment above): -Relaunch accepts "none" as a value that skips process
# relaunch (and, with it, the health-check/rollback-on-health-check-
# failure step) while the backup/copy/parse-check/rollback-on-copy-
# exception logic still runs exactly as normal.
$Script:CapRelaunchNone = [bool]($Script:InstallSourceText -match "(?i)'none'")

# APPUPD-B5 (this round's fixer task, the health-check-verify fix): the
# tray-relaunch race this build's own root-caused incident report
# describes - Invoke-InstallRelaunch running BEFORE
# Test-InstallHealthCheck, so a `-Relaunch tray` relaunch that has not
# started addon-server.ps1 yet (up to ~90s later) always loses the race
# against a 20s health-check poll and rolls itself back - is fixed by
# running the health check against a real, short-lived VERIFICATION
# instance of the newly staged code BEFORE any real relaunch happens at
# all, regardless of -Relaunch's own value. Grepped as the literal
# 'Health check passed.' console/log line this file's own coordination
# contract (see header note) has the installer fixer commit to emitting
# on a passing check - never a function/variable name, since none was
# ever agreed between these two files.
$Script:CapHealthCheckVerify = [bool]($Script:InstallSourceText -match [regex]::Escape('Health check passed.'))

# APPUPD-B6: the matching FAILED-health-check rollback wording fix -
# 'rolled back to <old> after post-install health check failed',
# replacing the old self-contradictory "rollback FAILED ... rolled back
# to ..." wording this incident's own root-cause report quoted verbatim
# (app-update.json's lastError claiming the rollback both failed AND
# succeeded in the same sentence, even though the restore had in fact
# worked).
$Script:CapHealthCheckRollbackWording = [bool]($Script:InstallSourceText -match [regex]::Escape('rolled back to'))

$Script:CapCore = $Script:CapUpgradeSwitch -and $Script:CapStopRunningApp -and $Script:CapRollback

Write-Host ''
Write-Host 'App-update install.ps1 -Upgrade capability probe (static source grep, no network):' -ForegroundColor Cyan
Write-Host "  APPUPD-B1 -Upgrade/-Relaunch param block .. $Script:CapUpgradeSwitch"
Write-Host "  APPUPD-B2 Invoke-InstallStopRunningApp ..... $Script:CapStopRunningApp"
Write-Host "  APPUPD-B3 backup/rollback functions ........ $Script:CapRollback"
Write-Host "  APPUPD-B4 -Relaunch 'none' literal found .... $Script:CapRelaunchNone (best-effort grep only - see note below)"
Write-Host "  APPUPD-B5 'Health check passed.' literal .... $Script:CapHealthCheckVerify (coordination log line - see note below)"
Write-Host "  APPUPD-B6 'rolled back to' literal ........... $Script:CapHealthCheckRollbackWording (coordination log line - see note below)"
Write-Host ''

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:AppUpdateFixturePort = 47940

# ---------------------------------------------------------------------
# Production-state snapshot guard - mirrors
# tests\integration\Server.Uninstall.Tests.ps1's own Get-ProductionRunValue
# / Get-ProductionInstalledAppsSnapshot / Get-LiveFurphyTrayPids exactly
# (duplicated here rather than dot-sourced from that file, matching this
# suite's existing convention of every integration/fixture file owning
# its own copy of this guard - see that file for the full reasoning).
# ---------------------------------------------------------------------

function Get-ProductionRunValue {
    try {
        $prop = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        if ($null -eq $prop) { return $null }
        return [string]$prop.FurphyAddonManager
    } catch {
        return $null
    }
}

function Get-ProductionInstalledAppsSnapshot {
    try {
        $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $p = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        return [PSCustomObject]@{
            DisplayName          = [string]$p.DisplayName
            DisplayVersion       = [string]$p.DisplayVersion
            Publisher            = [string]$p.Publisher
            InstallLocation      = [string]$p.InstallLocation
            DisplayIcon          = [string]$p.DisplayIcon
            UninstallString      = [string]$p.UninstallString
            QuietUninstallString = [string]$p.QuietUninstallString
        }
    } catch {
        return $null
    }
}

function Get-LiveFurphyTrayPids {
    <# Real, live-PRODUCTION FurphyHost.exe --tray pids only (Program Files, non-test port) - same split as Server.Uninstall.Tests.ps1's own copy. #>
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'FurphyHost.exe'" -ErrorAction SilentlyContinue
        $found = New-Object 'System.Collections.Generic.List[int]'
        foreach ($p in @($procs)) {
            $cl = [string]$p.CommandLine
            $ep = [string]$p.ExecutablePath
            if (-not ($cl -and ($cl -match '(^|\s)--tray(\s|$)'))) { continue }
            $isTestPort = $cl -match '--port\s+4789\d|--port\s+479[34]\d'
            $isProdPath = $ep -and ($ep -like '*\Program Files*')
            if ($isProdPath -and -not $isTestPort) { $found.Add([int]$p.ProcessId) }
        }
        return @($found | Sort-Object)
    } catch {
        return @()
    }
}

function Assert-ProductionUnchanged {
    param($Before, $After)
    $After.RunValue | Should Be $Before.RunValue
    $After.Uninstall.DisplayVersion | Should Be $Before.Uninstall.DisplayVersion
    (@($After.TrayPids) -join ',') | Should Be (@($Before.TrayPids) -join ',')
}

function Get-ProductionSnapshot {
    return [PSCustomObject]@{
        RunValue  = (Get-ProductionRunValue)
        Uninstall = (Get-ProductionInstalledAppsSnapshot)
        TrayPids  = (Get-LiveFurphyTrayPids)
    }
}

function Get-ProcessesReferencingPath {
    <#
      Live Win32_Process rows whose own CommandLine contains -PathNeedle
      (case-insensitive substring match) - used by the health-check-verify
      Describes below to prove a short-lived verification instance
      install.ps1's own -Upgrade path may spawn against the newly staged
      code (APPUPD-B5) is genuinely gone again once install.ps1 itself has
      exited, without this file needing to know that instance's own
      process name or port (Package B's own implementation detail, never
      coordinated with this file beyond the three log lines named in this
      file's own header). -PathNeedle is always one of THIS TEST's own
      freshly-generated scratch paths (New-TempRoot's timestamp+random
      suffix makes every call unique), so this can never mistake some
      OTHER, unrelated process (a real production tray, another fixer's
      own concurrently-running scratch install) for one of ours.
      Best-effort: an inaccessible/already-gone process row is simply not
      counted, never a reason to throw.
    #>
    param([Parameter(Mandatory = $true)][string]$PathNeedle)
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
    } catch {
        return @()
    }
    $found = New-Object 'System.Collections.Generic.List[int]'
    foreach ($p in @($procs)) {
        $cl = [string]$p.CommandLine
        if ($cl -and $cl.ToLowerInvariant().Contains($PathNeedle.ToLowerInvariant())) {
            $found.Add([int]$p.ProcessId)
        }
    }
    return @($found.ToArray())
}

function Wait-PathGone {
    <#
      Polls until -Path no longer exists, or -TimeoutSec elapses. Used by
      the health-check Describes below: install.ps1's own
      Remove-InstallStagedUpdateFolder (found live while reading its
      source for this task) deletes -SourceDir (this file's own $newerSrc
      - the folder install.ps1 itself is RUNNING FROM under -Upgrade) via
      a DETACHED, DELAYED self-delete (`ping -n 3 ... & rd /s /q`, since a
      running script cannot synchronously delete its own containing
      folder) on every -Upgrade outcome (success AND rollback alike) - so
      "the staged folder is gone" is only ever true a couple of seconds
      AFTER Invoke-CliProcess has already returned, never immediately.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return -not (Test-Path -LiteralPath $Path)
}

# ---------------------------------------------------------------------
# Scratch install + newer-fixture-source builders.
# ---------------------------------------------------------------------

function New-AppUpdateScratchInstall {
    <#
      Copies fixtures\wowroot into a fresh scratch root, pre-seeds
      _retail_\AddonSync\settings.json with the round's assigned port
      (47940 - never 47831, never another file's own port), runs
      install.ps1 -WowPath <scratch> -NoShortcuts -NoProtocol -SkipAdopt
      -Console (the console flow - a headless wizard would hang).
      Returns {WowRoot; AppDest; ExitCode; StdOut}.
    #>
    $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'appupdate-upgrade-wowroot')
    $appDest = Join-Path -Path $wowRoot -ChildPath '_retail_\AddonSync'
    New-Item -ItemType Directory -Path $appDest -Force | Out-Null
    ('{{ "releaseType": 1, "port": {0} }}' -f $Script:AppUpdateFixturePort) |
        Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

    $r = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console') -TimeoutSec 180

    return [PSCustomObject]@{ WowRoot = $wowRoot; AppDest = $appDest; ExitCode = $r.ExitCode; StdOut = $r.StdOut; StdErr = $r.StdErr }
}

function Get-AppUpdateRollbackBackupPath {
    <#
      Reproduces install.ps1's own Backup-InstallCodeForRollback naming
      EXACTLY (confirmed live by reading that function): a deterministic
      SHA256 hash of $AppDest's own normalized (trailing-backslash-
      trimmed, lowercased) path, first 16 hex chars, prefixed
      "FurphyRollback-", under %TEMP% - NOT the
      "FurphyRollback-<oldVersion>-<guid>" shape an earlier draft of
      this file assumed APP-UPDATE-SPEC.md section 8.6's own literal
      example meant; the real implementation is deliberately
      version/guid-free so the SAME install always lands on the SAME
      backup folder (open question 3's "keep exactly one prior-version
      backup" resolved by natural overwrite, never accumulation, rather
      than by a separate cleanup step).
    #>
    param([Parameter(Mandatory = $true)][string]$AppDest)
    $appDestNorm = $AppDest.TrimEnd('\').ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($appDestNorm))
    } finally {
        $sha256.Dispose()
    }
    $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('FurphyRollback-' + $hashHex.Substring(0, 16))
}

function New-AppUpdateNewerFixtureSource {
    <#
      A COMPLETE copy of the current build root's own app files - the
      same four Copy-FurphyAppFiles copies (addon-sync.ps1,
      addon-server.ps1, ui\, host\bin\) PLUS the remaining top-level
      files a real release zip also carries (install.ps1 itself -
      load-bearing: THIS is the copy that actually gets executed, from
      OUTSIDE $appDest, per section 8.4/8.5 - Addon Manager.vbs,
      curseforge-handler.vbs, register-protocol.ps1, README.txt,
      CHANGELOG.md, icon.ico, VERSION) - with VERSION overwritten to
      -NewVersion. Mirrors Install.Downgrade.Tests.ps1's own
      New-StaleInstallerSource, extended with host\ (that file's own
      scenario never needed a real host\ rebuild; this one does, since
      section 8.5's whole point is the host\bin\ prebuilt-exe overwrite).
    #>
    param([Parameter(Mandatory = $true)][string]$NewVersion)

    $dest = New-TempRoot -Name 'appupdate-newer-fixture'
    Copy-FurphyAppFiles -Destination $dest | Out-Null
    foreach ($f in @('install.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico')) {
        $s = Join-Path $Script:FurphyBuildRoot $f
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $dest $f) -Force }
    }
    $NewVersion | Set-Content -LiteralPath (Join-Path $dest 'VERSION') -Encoding Ascii -NoNewline
    return $dest
}

function Get-BumpedVersion {
    param([Parameter(Mandatory = $true)][string]$Current)
    $v = [System.Version]$Current
    return '{0}.{1}.{2}' -f $v.Major, $v.Minor, ($v.Build + 1)
}

function Invoke-AppUpdateUpgrade {
    <#
      install.ps1 -Upgrade run DIRECTLY from -SourceDir (never $appDest's
      own copy), -Relaunch none per this file's own header note.

      LIVE-SAFETY FINDING, load-bearing, found live while writing this
      file: Invoke-FurphyInstallSteps's steps 6/7/8 (desktop shortcut,
      curseforge:// protocol registration, adopt-scan) run AFTER the
      -Upgrade block unconditionally, gated only on -NoShortcuts/
      -NoProtocol/-SkipAdopt - install.ps1 DOES have a
      Test-LooksLikeScratchRun defense-in-depth guard on steps 6/7 (a
      %TEMP%/\scratch\/fixtures\wowroot path skips even without the
      flag), but this suite's own New-TempRoot-based scratch paths live
      under <BuildRoot>\tests\.tmp\, which that guard does NOT recognize
      (it is not %TEMP% itself, not \scratch\, not fixtures\wowroot) -
      so without these three flags, a call from THIS file would create a
      REAL "Furphy Addon Manager.lnk" on the REAL Windows Desktop and
      register the REAL HKCU\Software\Classes\curseforge key pointing at
      a scratch temp path, directly violating this session's own hard
      live-safety rules. APP-UPDATE-SPEC.md section 5's own real
      Handle-AppUpdateInstall command line does NOT pass these three
      flags either (a separate, out-of-scope observation for whoever
      reviews Package A/B - flagged, not fixed here, since it never runs
      against a scratch path in production and this file cannot edit
      addon-server.ps1/install.ps1 to change it) - this test file must
      still pass them regardless, since ITS OWN paths are exactly the
      scratch case that guard does not fully cover.

      SECOND LIVE-SAFETY FINDING, load-bearing, found live while
      verifying THIS ROUND's own APPUPD-B5 fix: Invoke-InstallVerifyNewFiles
      (install.ps1) starts its own short-lived verification addon-server.ps1
      via a bare Start-Process, with NONE of tests\lib\common.ps1's own
      Start-TestServer safety net (FURPHY_TEST_GITHUB_BASEURL/
      FURPHY_TEST_SKIP_WAGO_GROWTH/FURPHY_TEST_SKIP_CF_CATALOGUE) - and that
      verification instance's own NORMAL startup self-spawns a
      "-MaintenanceOnly" child exactly like a real production server does
      (confirmed live: its own server.log showed a REAL CurseForge catalogue
      fetch, a REAL Wago growth crawl, AND a REAL api.github.com app-update
      check, all fired from what this file believed was a fully offline
      -Relaunch none run). -Relaunch none newly reaching this verification
      step at all (APPUPD-B5, this round) means every EXISTING Describe in
      this file that calls -Upgrade - not only the two new health-check
      Describes below - started making these same real calls the moment
      that fix landed, a direct violation of this session's own "never
      touch real GitHub" rule this file's own header names explicitly.
      Fixed here, the same way Start-TestServer fixes it for its own child:
      -EnvironmentOverrides sets the identical three vars on install.ps1's
      OWN process, which Start-Process (both install.ps1's call to spawn
      its verification server, and that server's own further self-spawn)
      inherits by default - closing this off for every caller of this
      function, not just the two Describes that exposed it. A separate,
      out-of-scope observation for whoever reviews Package B: production
      use of a real -Upgrade has no reason to skip this same real work
      (a live user's machine has real internet, and it may be the point),
      so this fix belongs here, in the test-only caller, never in
      install.ps1 itself.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$WowRoot,
        [int]$TimeoutSec = 180
    )
    $upgradeScript = Join-Path -Path $SourceDir -ChildPath 'install.ps1'
    $envOverrides = @{
        FURPHY_TEST_GITHUB_BASEURL     = 'http://127.0.0.1:1'
        FURPHY_TEST_SKIP_WAGO_GROWTH   = '1'
        FURPHY_TEST_SKIP_CF_CATALOGUE  = '1'
    }
    return Invoke-CliProcess -ScriptPath $upgradeScript -ArgumentList @('-WowPath', $WowRoot, '-Upgrade', '-Relaunch', 'none', '-Console', '-Quiet', '-NoShortcuts', '-NoProtocol', '-SkipAdopt') -TimeoutSec $TimeoutSec -EnvironmentOverrides $envOverrides
}

# =====================================================================
# 1) Happy path: a genuinely newer fixture, -Relaunch none - state
#    preserved, backup present, version bumped, production untouched
#    (section 12's fixture-acceptance list, items 1/3; orchestrator's
#    explicit -Relaunch none instruction for this file).
# =====================================================================

Describe 'install.ps1 -Upgrade (silent, -Relaunch none): a real newer release upgrades a scratch install in place' {
    if (-not $Script:CapCore) {
        It 'VERSION bumps, addons.json/settings.json/state.json survive untouched, a rollback backup exists, production HKCU/tray are unchanged' {
            Write-PendingSkip 'needs APPUPD-B1 (-Upgrade/-Relaunch param block), APPUPD-B2 (Invoke-InstallStopRunningApp) and APPUPD-B3 (backup/rollback functions) in install.ps1 - none of them exist yet'
        }
        return
    }

    $before = Get-ProductionSnapshot
    $installed = $null
    $newerSrc = $null
    try {
        $installed = New-AppUpdateScratchInstall
        $installed.ExitCode | Should Be 0

        $currentVersion = (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim()
        $newVersion = Get-BumpedVersion -Current $currentVersion
        $newerSrc = New-AppUpdateNewerFixtureSource -NewVersion $newVersion

        # Seed a little real state worth diffing (addons.json otherwise
        # has nothing meaningful to compare byte-for-byte) - bogus,
        # never-resolving ids so this stays offline; not asserted on for
        # success/failure. Found live: addon-sync.ps1 does not necessarily
        # create addons.json at all when EVERY -Add id fails outright (a
        # real, fast-404 network round-trip, still offline w.r.t. GitHub) -
        # so this only captures a "before" snapshot when the file actually
        # exists, exactly like the pre-existing state.json handling below,
        # rather than assuming the seed attempt always produces one.
        Invoke-CliJson -ScriptPath (Join-Path $installed.AppDest 'addon-sync.ps1') `
            -ArgumentList @('-Add', '900000031,900000032', '-Json', '-WowRoot', $installed.WowRoot, '-Flavor', 'retail') | Out-Null

        $beforeAddonsPath = Join-Path $installed.AppDest 'addons.json'
        $beforeAddons = if (Test-Path -LiteralPath $beforeAddonsPath) { Get-Content -Raw -LiteralPath $beforeAddonsPath } else { $null }
        $beforeSettings = Get-Content -Raw -LiteralPath (Join-Path $installed.AppDest 'settings.json')
        $beforeStatePath = Join-Path $installed.AppDest 'state.json'
        $beforeState = if (Test-Path -LiteralPath $beforeStatePath) { Get-Content -Raw -LiteralPath $beforeStatePath } else { $null }

        It 'VERSION bumps to the new fixture''s own version' {
            $upgrade = Invoke-AppUpdateUpgrade -SourceDir $newerSrc -WowRoot $installed.WowRoot
            $upgrade.ExitCode | Should Be 0
            (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim() | Should Be $newVersion
        }

        It 'addons.json / settings.json / state.json survive UNTOUCHED (byte-identical to before the upgrade)' {
            if ($null -ne $beforeAddons) {
                (Get-Content -Raw -LiteralPath $beforeAddonsPath) | Should Be $beforeAddons
            }
            (Get-Content -Raw -LiteralPath (Join-Path $installed.AppDest 'settings.json')) | Should Be $beforeSettings
            if ($null -ne $beforeState) {
                (Get-Content -Raw -LiteralPath $beforeStatePath) | Should Be $beforeState
            }
        }

        It 'the rollback backup for this install exists (kept, not deleted, on a successful upgrade) and holds the OLD version''s own VERSION file' {
            $backupPath = Get-AppUpdateRollbackBackupPath -AppDest $installed.AppDest
            (Test-Path -LiteralPath $backupPath -PathType Container) | Should Be $true
            (Get-Content -LiteralPath (Join-Path $backupPath 'VERSION')).Trim() | Should Be $currentVersion
            Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'production Run value, Uninstall DisplayVersion and live tray pids are byte-identical before/after' {
            $after = Get-ProductionSnapshot
            Assert-ProductionUnchanged -Before $before -After $after
        }
    } finally {
        if ($installed -and (Test-Path -LiteralPath $installed.WowRoot)) { Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($newerSrc -and (Test-Path -LiteralPath $newerSrc)) { Remove-Item -LiteralPath $newerSrc -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =====================================================================
# 2) Forced COPY-failure rollback (section 8.6's gap fix, section 12's
#    "a FORCED copy-failure case ... assert the SAME rollback path runs
#    ... the OLD version answers again afterward" - restated here
#    file-for-file, since -Relaunch none never re-answers /api/ping;
#    see this file's own header note).
# =====================================================================

Describe 'install.ps1 -Upgrade (silent, -Relaunch none): a locked destination file forces a copy-phase rollback' {
    if (-not $Script:CapCore) {
        It 'a locked host\bin\FurphyHost.exe makes Copy-Item throw mid-copy; the OLD code is restored, VERSION reverts, app-update.json records the failure' {
            Write-PendingSkip 'needs APPUPD-B1 (-Upgrade/-Relaunch param block), APPUPD-B2 (Invoke-InstallStopRunningApp) and APPUPD-B3 (backup/rollback functions) in install.ps1 - none of them exist yet'
        }
        return
    }

    $before = Get-ProductionSnapshot
    $installed = $null
    $newerSrc = $null
    $lockStream = $null
    try {
        $installed = New-AppUpdateScratchInstall
        $installed.ExitCode | Should Be 0
        $currentVersion = (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim()
        $newVersion = Get-BumpedVersion -Current $currentVersion
        $newerSrc = New-AppUpdateNewerFixtureSource -NewVersion $newVersion

        $lockedFile = Join-Path $installed.AppDest 'host\bin\FurphyHost.exe'
        $beforeServerHash = (Get-FileHash -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1') -Algorithm SHA256).Hash

        It 'the copy throws, rollback restores the pre-upgrade code, VERSION stays at the OLD version, app-update.json shows a copy-failure error' {
            if (-not (Test-Path -LiteralPath $lockedFile)) {
                # A fresh scratch install with no csc.exe on this machine
                # may legitimately have no prebuilt exe at all - without a
                # real file to lock, this exact repro cannot fire. Note it
                # plainly rather than asserting a false pass.
                Set-TestInconclusive -Message "host\bin\FurphyHost.exe was not present in this scratch install (no local C# compiler?) - cannot force a locked-file copy failure"
                return
            }
            $lockStream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

            # NOTE: found live while writing this file - install.ps1's own
            # -Upgrade try/catch treats a caught copy-phase exception as a
            # GRACEFULLY HANDLED outcome (restore old code, log, write
            # app-update.json, return) rather than a hard script failure,
            # so $upgrade.ExitCode is 0 here even though a rollback ran -
            # asserting a non-zero exit code would be testing something
            # install.ps1 was never designed to do. The real assertions
            # are the file-level ones below: VERSION reverted, code hash
            # unchanged, app-update.json recording the failure.
            $upgrade = Invoke-AppUpdateUpgrade -SourceDir $newerSrc -WowRoot $installed.WowRoot

            (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim() | Should Be $currentVersion
            (Get-FileHash -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1') -Algorithm SHA256).Hash | Should Be $beforeServerHash

            $appUpdateJsonPath = Join-Path $installed.AppDest 'app-update.json'
            (Test-Path -LiteralPath $appUpdateJsonPath) | Should Be $true
            $appUpdateJson = Get-Content -Raw -LiteralPath $appUpdateJsonPath | ConvertFrom-Json
            $appUpdateJson.state | Should Be 'error'
            ([string]::IsNullOrEmpty($appUpdateJson.lastError)) | Should Be $false
        }

        It 'production Run value, Uninstall DisplayVersion and live tray pids are byte-identical before/after' {
            $after = Get-ProductionSnapshot
            Assert-ProductionUnchanged -Before $before -After $after
        }
    } finally {
        if ($lockStream) { try { $lockStream.Dispose() } catch { } }
        # Targeted cleanup ONLY - the exact deterministic path this
        # SCRATCH AppDest's own backup would use (Get-AppUpdateRollbackBackupPath),
        # never a blind "FurphyRollback-*" sweep of %TEMP%: a wildcard
        # sweep could delete a REAL production rollback backup if Eric's
        # own live install has ever used this feature (its own backup
        # folder lives under the same %TEMP%, named from a hash of the
        # real AppDest) - deleting that would reduce his own rollback
        # safety net, which this build's live-safety rules treat as
        # touching production-related state even though it is "only" a
        # backup, not the live install itself.
        if ($installed) {
            $backupPath = Get-AppUpdateRollbackBackupPath -AppDest $installed.AppDest
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($installed -and (Test-Path -LiteralPath $installed.WowRoot)) { Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($newerSrc -and (Test-Path -LiteralPath $newerSrc)) { Remove-Item -LiteralPath $newerSrc -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =====================================================================
# 3) Health-check PASS (this round's fixer task, item 2): the
#    tray-relaunch-race fix (APPUPD-B5) - a real, short-lived
#    VERIFICATION instance of the newly staged code answers /api/ping
#    with the NEW version, and is shut down again, BEFORE install.ps1
#    ever relaunches anything real - now runs even under -Relaunch none,
#    since the verification step no longer depends on a real tray/window
#    relaunch actually happening (that is what root-caused this build's
#    own incident: -Relaunch tray's own real relaunch does not start
#    addon-server.ps1 for up to ~90s, so the OLD health check, which
#    only ever polled the RELAUNCHED process, always lost that race).
#    This Describe therefore covers the health-check MECHANISM itself
#    without ever opening a real tray/window on this shared desktop -
#    the still-permanent, still out-of-scope gap that remains is a real
#    tray/window relaunch's OWN /api/ping poll specifically, covered by
#    Describe 5 below, unchanged from before this round.
# =====================================================================

Describe 'install.ps1 -Upgrade (silent, -Relaunch none): the post-copy health check passes against the newly staged code' {
    if (-not ($Script:CapCore -and $Script:CapRelaunchNone -and $Script:CapHealthCheckVerify)) {
        It 'stdout logs a passing health check, VERSION stays at the NEW version (no rollback), and no verification process is left running' {
            Write-PendingSkip 'needs APPUPD-B5 (the "Health check passed." health-check-verify fix landing in install.ps1''s -Upgrade path) - not landed yet, or this file''s own grep marker text does not match'
        }
        return
    }

    $before = Get-ProductionSnapshot
    $installed = $null
    $newerSrc = $null
    try {
        $installed = New-AppUpdateScratchInstall
        $installed.ExitCode | Should Be 0
        $currentVersion = (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim()
        $newVersion = Get-BumpedVersion -Current $currentVersion
        $newerSrc = New-AppUpdateNewerFixtureSource -NewVersion $newVersion

        It 'VERSION bumps to the new version and stdout shows the health check passing' {
            $upgrade = Invoke-AppUpdateUpgrade -SourceDir $newerSrc -WowRoot $installed.WowRoot
            $upgrade.ExitCode | Should Be 0
            (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim() | Should Be $newVersion
            $upgrade.StdOut | Should Match ([regex]::Escape('Health check passed.'))
        }

        It 'no process referencing this scratch install''s own AppDest path is left running once install.ps1 has exited' {
            # A real verification instance, if install.ps1's own -Upgrade
            # path started one against $installed.AppDest to run this
            # check, must be shut down again before install.ps1 itself
            # exits (Invoke-CliProcess above already waited for that exit)
            # - a lingering match here means something was left running.
            # Polled, not a single instantaneous read: found live while
            # verifying this file - Stop-Process -Force (TerminateProcess)
            # is not synchronous (same real quirk tests\lib\common.ps1's
            # own Wait-ProcessReallyGone doc comment already documents), so
            # a check made immediately after install.ps1's own process has
            # exited can still observe its OWN verification child for a
            # short window even though nothing is actually stuck.
            $deadline = (Get-Date).AddSeconds(5)
            $leftover = @(Get-ProcessesReferencingPath -PathNeedle $installed.AppDest)
            while (($leftover.Count -gt 0) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 250
                $leftover = @(Get-ProcessesReferencingPath -PathNeedle $installed.AppDest)
            }
            (@($leftover).Count) | Should Be 0
        }

        It 'the staged source folder ($newerSrc) is gone - a successful upgrade cleans up after itself, never leaving it behind' {
            (Wait-PathGone -Path $newerSrc -TimeoutSec 15) | Should Be $true
        }

        It 'production Run value, Uninstall DisplayVersion and live tray pids are byte-identical before/after' {
            $after = Get-ProductionSnapshot
            Assert-ProductionUnchanged -Before $before -After $after
        }
    } finally {
        # This Describe never breaks the copy, so no rollback backup
        # should exist at all - best-effort cleanup only, matching the
        # same targeted (never blind-swept), single-deterministic-path
        # convention as the two Describes above, in case a bug DOES
        # create one.
        if ($installed) {
            $backupPath = Get-AppUpdateRollbackBackupPath -AppDest $installed.AppDest
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($installed -and (Test-Path -LiteralPath $installed.WowRoot)) { Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($newerSrc -and (Test-Path -LiteralPath $newerSrc)) { Remove-Item -LiteralPath $newerSrc -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =====================================================================
# 4) Health-check FAIL -> rollback (this round's fixer task, item 2): a
#    deliberately BROKEN staged addon-server.ps1 (the newly staged code
#    fails to answer /api/ping at all) must fail APPUPD-B5's own
#    verification step and trigger the SAME rollback machinery Describe 2
#    above already covers for a copy-phase exception - restated here for
#    a health-check-phase failure specifically, with the NON-
#    contradictory lastError wording (APPUPD-B6) this incident's own
#    root-cause report called out by name: the OLD wording claimed
#    "rollback FAILED ... rolled back to <old>" in the same sentence even
#    though the restore had in fact succeeded; the fix commits to
#    'rolled back to <old> after post-install health check failed' for
#    exactly this (successful-rollback) outcome, reserving "rollback
#    FAILED" for a genuinely failed restore (a different, not-covered-
#    here scenario) - never both in one message again.
# =====================================================================

Describe 'install.ps1 -Upgrade (silent, -Relaunch none): a broken staged addon-server.ps1 fails the health check and rolls back' {
    if (-not ($Script:CapCore -and $Script:CapRelaunchNone -and $Script:CapHealthCheckVerify -and $Script:CapHealthCheckRollbackWording)) {
        It 'the health check fails, code is rolled back, VERSION stays at the OLD version, lastError is the non-contradictory wording, and no more than one rollback backup exists for this dest' {
            Write-PendingSkip 'needs APPUPD-B5 (health-check-verify) AND APPUPD-B6 (non-contradictory rollback wording) landing in install.ps1''s -Upgrade path - not landed yet, or this file''s own grep marker text does not match'
        }
        return
    }

    $before = Get-ProductionSnapshot
    $installed = $null
    $newerSrc = $null
    try {
        $installed = New-AppUpdateScratchInstall
        $installed.ExitCode | Should Be 0
        $currentVersion = (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim()
        $newVersion = Get-BumpedVersion -Current $currentVersion
        $newerSrc = New-AppUpdateNewerFixtureSource -NewVersion $newVersion
        $beforeServerHash = (Get-FileHash -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1') -Algorithm SHA256).Hash

        # Deliberately break the STAGED (newer-fixture) copy of
        # addon-server.ps1 so that whatever install.ps1 starts to answer
        # its own verification /api/ping poll fails outright rather than
        # ever binding a listener - a fast, deterministic health-check
        # failure, never a slow hang.
        $brokenServerPath = Join-Path $newerSrc 'addon-server.ps1'
        "throw 'FURPHY-TEST: deliberately broken addon-server.ps1 (health-check-failure fixture, AppUpdate.SilentUpgrade.Tests.ps1)'" |
            Set-Content -LiteralPath $brokenServerPath -Encoding Ascii

        It 'the health check fails; the OLD code is restored; VERSION stays at the OLD version; app-update.json carries the non-contradictory rollback wording, never "rollback FAILED"' {
            $upgrade = Invoke-AppUpdateUpgrade -SourceDir $newerSrc -WowRoot $installed.WowRoot

            (Get-Content -LiteralPath (Join-Path $installed.AppDest 'VERSION')).Trim() | Should Be $currentVersion
            (Get-FileHash -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1') -Algorithm SHA256).Hash | Should Be $beforeServerHash

            $appUpdateJsonPath = Join-Path $installed.AppDest 'app-update.json'
            (Test-Path -LiteralPath $appUpdateJsonPath) | Should Be $true
            $appUpdateJson = Get-Content -Raw -LiteralPath $appUpdateJsonPath | ConvertFrom-Json
            $appUpdateJson.state | Should Be 'error'
            $appUpdateJson.lastError | Should Match ('rolled back to.*' + [regex]::Escape($currentVersion) + '.*after post-install health check failed')
            $appUpdateJson.lastError | Should Not Match ([regex]::Escape('rollback FAILED'))
        }

        It 'at most one FurphyRollback backup folder exists for this dest, and it is the exact deterministic one' {
            $backupPath = Get-AppUpdateRollbackBackupPath -AppDest $installed.AppDest
            $tempPath = [System.IO.Path]::GetTempPath()
            $hashPrefix = (Split-Path -Path $backupPath -Leaf)
            $matches = @(Get-ChildItem -LiteralPath $tempPath -Directory -Filter ($hashPrefix + '*') -Force -ErrorAction SilentlyContinue)
            (@($matches).Count) | Should Be 1
            $matches[0].FullName | Should Be $backupPath
        }

        It 'the staged source folder ($newerSrc) is gone - a rollback cleans up after itself too, never leaving it behind' {
            (Wait-PathGone -Path $newerSrc -TimeoutSec 15) | Should Be $true
        }

        It 'production Run value, Uninstall DisplayVersion and live tray pids are byte-identical before/after' {
            $after = Get-ProductionSnapshot
            Assert-ProductionUnchanged -Before $before -After $after
        }
    } finally {
        # Targeted cleanup ONLY - see Describe 2's own finally block above
        # for the full "never a blind FurphyRollback-* sweep" reasoning;
        # identical here.
        if ($installed) {
            $backupPath = Get-AppUpdateRollbackBackupPath -AppDest $installed.AppDest
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($installed -and (Test-Path -LiteralPath $installed.WowRoot)) { Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($newerSrc -and (Test-Path -LiteralPath $newerSrc)) { Remove-Item -LiteralPath $newerSrc -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =====================================================================
# 5) Forced HEALTH-CHECK-failure rollback via a REAL tray/window relaunch
#    - PERMANENTLY, DELIBERATELY not exercised in this file. See the
#    header comment's "KNOWN, DELIBERATE GAP" for why: this scenario, by
#    construction, needs a real relaunch + a real /api/ping poll cycle
#    against the RELAUNCHED process itself (a real window or tray process
#    actually starting), which this build's own hard live-safety rules
#    forbid on this shared, interactive desktop for THIS session. This is
#    now narrower than it used to be: Describes 3/4 above already cover
#    the health-check MECHANISM itself (APPUPD-B5/B6) via -Relaunch none's
#    own verification instance, added this round specifically so every
#    OTHER Describe in this file never needs a real relaunch - what
#    remains permanently out of scope here is only the REAL tray/window
#    relaunch's own /api/ping poll. This is not a capability gate (it
#    stays pending even once install.ps1 fully supports -Upgrade) - it is
#    a standing, environment-scoped skip, same shape as this suite's own
#    host/perf layers being excluded from a normal run for an analogous
#    "would touch the real desktop" reason (see TESTING.md).
# =====================================================================

Describe 'install.ps1 -Upgrade: forced health-check-failure rollback via a REAL tray/window relaunch (section 8.6/12)' {
    It 'a real relaunch answers /api/ping with the WRONG version -> rollback restores the old version and it answers /api/ping again' {
        Write-PendingSkip 'PERMANENT, environment-scoped skip (not "package not landed") - this scenario needs a real window/tray relaunch + /api/ping poll cycle against the RELAUNCHED process itself, which this session''s hard live-safety rules forbid starting on this shared desktop. Add real coverage only in an isolated/CI-only environment that is never this interactive desktop; see this file''s own header comment for the full reasoning. (The health-check MECHANISM itself is covered without a real relaunch by Describes 3/4 above.)'
    }
}

Remove-AppUpdateTempLitter -Prefix 'FurphyRollback-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
Remove-TempRoots
