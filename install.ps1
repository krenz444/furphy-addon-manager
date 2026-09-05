<#
=====================================================================
 install.ps1 - Furphy Addon Manager installer (E18, FLAVORS-SPEC S7.1)

 Finds a WoW installation, copies the app into <home-flavour>\AddonSync
 (Retail when present, else the first-detected flavour - FLAVORS-SPEC
 S2.1 order), writes a "Launch WoW (Updated)" launcher pair into every
 installed first-class flavour's own folder (Retail/Classic/Classic Era
 - each carrying that flavour's -Flavor id and Battle.net product code),
 creates desktop shortcuts (one per first-class flavour; today's exact
 single unlabeled shortcut when only one is installed), registers the
 curseforge:// protocol handler, and adopts any addon folders already
 present in each installed flavour's AddOns - all without requiring a
 CurseForge API key.

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
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$SourceRoot = $PSScriptRoot
if (-not $SourceRoot) { $SourceRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
}
function Write-Info {
    param([string]$Message)
    Write-Host "  $Message"
}
function Write-Warn2 {
    param([string]$Message)
    Write-Host "  WARNING: $Message" -ForegroundColor Yellow
}

# =====================================================================
# FLAVORS-SPEC S2.1: the same fixed-order table addon-sync.ps1/
# addon-server.ps1 carry as $Script:FlavourDefs, duplicated here per the
# codebase's existing established pattern (every shared fact lives in
# each file that needs it, never a cross-file import). install.ps1 only
# needs the folder/label/first-class/Battle.net-code facts - never
# client build numbers - so this is a deliberately smaller table than
# the CLI/server copies (no Product/.build.info field).
#
# FirstClass mirrors S2.1's "First-class in v1?" column: only Retail,
# Classic and Classic Era ever get a launcher pair or a desktop
# shortcut (S7.2). PTR/XPTR/Beta are still detected (Find-WowRoot,
# Get-InstalledFlavourDefs) so a PTR-only machine can still be found
# and so the adopt step (S7.1) can offer to take over a PTR AddOns
# folder too, but they never get a shortcut or a launcher pair.
#
# BattleNetCode/Reliable are S4.7's table - Retail's code is proven
# reliable (this machine's own --exec="launch WoW" already works
# today); every other code is community-sourced and NOT proven
# reliable, which the generated launcher's own comment says honestly
# (S4.7, S6.3) rather than promising a silent launch that might not
# happen.
# =====================================================================

$Script:FlavourDefs = @(
    [PSCustomObject]@{ Id = 'retail';      Folder = '_retail_';      Label = 'Retail';      FirstClass = $true;  BattleNetCode = 'WoW';             Reliable = $true }
    [PSCustomObject]@{ Id = 'classic';     Folder = '_classic_';     Label = 'Classic';     FirstClass = $true;  BattleNetCode = 'wow_classic';      Reliable = $false }
    [PSCustomObject]@{ Id = 'classic_era'; Folder = '_classic_era_'; Label = 'Classic Era'; FirstClass = $true;  BattleNetCode = 'wow_classic_era';  Reliable = $false }
    [PSCustomObject]@{ Id = 'ptr';         Folder = '_ptr_';         Label = 'PTR';         FirstClass = $false; BattleNetCode = 'wowt';             Reliable = $false }
    [PSCustomObject]@{ Id = 'xptr';        Folder = '_xptr_';        Label = 'PTR (2)';     FirstClass = $false; BattleNetCode = 'wowxptr';          Reliable = $false }
    [PSCustomObject]@{ Id = 'beta';        Folder = '_beta_';        Label = 'Beta';        FirstClass = $false; BattleNetCode = 'wow_beta';         Reliable = $false }
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
    if (-not $WowRootPath) { return $result }
    foreach ($def in $Script:FlavourDefs) {
        if (Test-FlavourInstalled -WowRootPath $WowRootPath -Folder $def.Folder) {
            $result.Add($def)
        }
    }
    return $result
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
        if ($c -and (Get-InstalledFlavourDefs -WowRootPath $c).Count -gt 0) {
            return $c
        }
    }

    return $null
}

$wowRoot = Find-WowRoot -Override $WowPath
if (-not $wowRoot) {
    Write-Host ''
    Write-Host 'ERROR: Could not find a World of Warcraft installation.' -ForegroundColor Red
    Write-Host '       Pass -WowPath "<your WoW folder>" (the one that contains _retail_, _classic_, _classic_era_, etc).' -ForegroundColor Red
    exit 2
}

$installedFlavours = Get-InstalledFlavourDefs -WowRootPath $wowRoot
if ($installedFlavours.Count -eq 0) {
    Write-Host ''
    Write-Host "ERROR: No known WoW client folder (with Interface\AddOns) was found under $wowRoot." -ForegroundColor Red
    Write-Host '       Pass -WowPath "<your WoW folder>" (the one that contains _retail_, _classic_, _classic_era_, etc).' -ForegroundColor Red
    exit 2
}

# FLAVORS-SPEC S3.1: home flavour = Retail when installed (upgrade path,
# byte-identical to every machine that has it today); otherwise the
# first-detected flavour in S2.1's fixed order (Get-InstalledFlavourDefs
# already returns its list in that order, so $installedFlavours[0] IS
# that first-detected flavour whenever Retail is absent).
$homeFlavour = $null
foreach ($f in $installedFlavours) { if ($f.Id -eq 'retail') { $homeFlavour = $f; break } }
if (-not $homeFlavour) { $homeFlavour = $installedFlavours[0] }

$homeDir = Join-Path -Path $wowRoot -ChildPath $homeFlavour.Folder
$addonsPath = Join-Path -Path $homeDir -ChildPath 'Interface\AddOns'
$appDest = Join-Path -Path $homeDir -ChildPath 'AddonSync'

# Only Retail/Classic/Classic Era (S2.1's "first-class") ever get a
# launcher pair or a desktop shortcut (S7.2) - PTR/XPTR/Beta stay
# detected-but-quiet here exactly as they do everywhere else (S2.5).
$firstClassInstalled = @($installedFlavours | Where-Object { $_.FirstClass })
$multiFlavour = ($firstClassInstalled.Count -gt 1)

# =====================================================================
# 2. Battle.net.exe detection (best-effort; a default path is always
#    returned so the generated launcher is never left with an empty
#    target, even when detection genuinely can't find it here).
# =====================================================================

function Find-BattleNetExe {
    $default = 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
    if (Test-Path -LiteralPath $default) { return $default }
    $alt = 'C:\Program Files\Battle.net\Battle.net.exe'
    if (Test-Path -LiteralPath $alt) { return $alt }
    try {
        $uninstKeys = @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net'
        )
        foreach ($k in $uninstKeys) {
            if (Test-Path -LiteralPath $k) {
                $prop = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
                if ($prop -and $prop.InstallLocation) {
                    $candidate = Join-Path -Path ([string]$prop.InstallLocation) -ChildPath 'Battle.net.exe'
                    if (Test-Path -LiteralPath $candidate) { return $candidate }
                }
            }
        }
    } catch {
        # Best-effort; fall through to the documented default below.
    }
    return $default
}

# =====================================================================
# -Uninstall path
# =====================================================================

if ($Uninstall) {
    Write-Step "Uninstalling Furphy Addon Manager from $appDest"

    # Round 18 (tray stage B): stop any running tray before touching files -
    # the app files removal below deletes host\ (FurphyHost.exe included,
    # since 'host' is not in $keepDirs further down), which must not happen
    # while that exe is still running out of the folder being deleted. Order
    # here matters: remove the Run value FIRST (so a logon during a slow
    # uninstall can't relaunch the tray), then signal the running instance to
    # exit, then wait for it before any Remove-Item touches host\.
    $trayExePath = Join-Path -Path $appDest -ChildPath 'host\bin\FurphyHost.exe'
    try {
        $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Test-Path -LiteralPath $runKeyPath) {
            $existing = Get-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Remove-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
                Write-Info 'Removed "Start with Windows" registration.'
            }
        }
    } catch {
        Write-Warn2 "Could not remove the Start-with-Windows registry value: $($_.Exception.Message)"
    }

    $trayStopEvent = $null
    try {
        $trayStopEvent = [System.Threading.EventWaitHandle]::OpenExisting('FurphyAddonManager.TrayStop')
        $trayStopEvent.Set() | Out-Null
    } catch {
        # No live tray holds this event - nothing to stop.
        $trayStopEvent = $null
    } finally {
        if ($null -ne $trayStopEvent) { try { $trayStopEvent.Close() } catch { } }
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
            Write-Info 'Background tray stopped.'
        }
    }

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

    # FLAVORS-SPEC S7.2: remove every possible shortcut name (today's
    # single unlabeled name plus every flavour's labeled variant) rather
    # than trying to infer which naming convention was used when this
    # copy was installed - harmless no-ops for names that don't exist.
    #
    # [Environment]::GetFolderPath('Desktop') always resolves the REAL
    # machine Desktop - it is never scoped to -WowPath/$wowRoot. Gate
    # this whole block behind -NoShortcuts (mirroring the creation-side
    # guard further down) so an -Uninstall run against a test/scratch
    # -WowPath (or any caller that wants Desktop left alone) can opt out
    # the same way install already lets them opt out of creation. This
    # exact unscoped removal previously deleted this machine's two real
    # production desktop shortcuts during a scratch-fixture test run -
    # see the CS-F5 build-log incident note.
    if (-not $NoShortcuts) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shortcutNames = New-Object 'System.Collections.Generic.List[string]'
        $shortcutNames.Add('Furphy Addon Manager.lnk')
        $shortcutNames.Add('WoW (auto-update addons).lnk')
        foreach ($def in $Script:FlavourDefs) {
            if ($def.FirstClass) { $shortcutNames.Add("WoW - $($def.Label) (auto-update addons).lnk") }
        }
        foreach ($name in $shortcutNames) {
            $lnk = Join-Path -Path $desktop -ChildPath $name
            if (Test-Path -LiteralPath $lnk) {
                Remove-Item -LiteralPath $lnk -Force
                Write-Info "Removed shortcut: $name"
            }
        }
    } else {
        Write-Info 'Skipped desktop shortcut removal (-NoShortcuts).'
    }

    # Remove a launcher pair from every known flavour folder that might
    # hold one (a machine could have been installed, had a flavour
    # added/removed, or been re-installed across versions of this
    # installer) - not just $firstClassInstalled, so a stale pair left
    # behind in a since-removed flavour folder still gets cleaned up.
    foreach ($def in $Script:FlavourDefs) {
        $flavourDir = Join-Path -Path $wowRoot -ChildPath $def.Folder
        foreach ($name in @('update-addons-and-launch.cmd', 'Launch WoW (Updated).vbs')) {
            $p = Join-Path -Path $flavourDir -ChildPath $name
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force
                Write-Info "Removed launcher file: $($def.Label)\$name"
            }
        }
    }

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
            if ($_.PSIsContainer) {
                if ($keepDirs -notcontains $_.Name) {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force
                }
            } elseif ($keepFiles -notcontains $_.Name) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
        Write-Info "App files removed from $appDest"
        Write-Info "Your addon list, settings and logs are still there: $appDest"
    } else {
        Write-Info "$appDest did not exist - nothing to remove."
    }

    Write-Info "Your AddOns folder(s) were not touched."
    Write-Host ''
    Write-Host 'Uninstall complete.' -ForegroundColor Green
    exit 0
}

# =====================================================================
# 3. Copy the app into <home-flavour>\AddonSync (never overwrite user state)
# =====================================================================

if ($multiFlavour) {
    Write-Step "Installing Furphy Addon Manager into $appDest (home flavour: $($homeFlavour.Label))"
} else {
    Write-Step "Installing Furphy Addon Manager into $appDest"
}

New-Item -ItemType Directory -Force -Path $appDest | Out-Null
$codeFiles = @('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico')
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
    '{ "releaseType": 1, "autoUpdateOnLaunch": true, "port": 47831 }' | Set-Content -LiteralPath $settingsPath -Encoding Ascii
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

# =====================================================================
# 5. Launcher pair(s), rewritten for this machine's paths
#    FLAVORS-SPEC S7.2: one pair per installed first-class flavour, each
#    written into THAT flavour's own folder (so no filename collision -
#    every flavour has its own <WowRoot>\<folder>\ to live in) and
#    carrying that flavour's -Flavor id and Battle.net product code
#    (S4.7). The single-flavour case's file content is byte-identical to
#    every pre-flavours install (no -Flavor argument, no reliability
#    comment line, Retail-only wording) - the "invisible at n=1" promise
#    (principle 2) applies to these generated files too, not just the
#    live app's own UI/API.
# =====================================================================

Write-Step 'Writing launcher files'

$battleNetExe = Find-BattleNetExe
$cliPath = Join-Path -Path $appDest -ChildPath 'addon-sync.ps1'
$launcherWritten = New-Object 'System.Collections.Generic.List[object]'

foreach ($def in $firstClassInstalled) {
    $flavourDir = Join-Path -Path $wowRoot -ChildPath $def.Folder
    $launcherCmdPath = Join-Path -Path $flavourDir -ChildPath 'update-addons-and-launch.cmd'
    $launcherVbsPath = Join-Path -Path $flavourDir -ChildPath 'Launch WoW (Updated).vbs'
    $cmdBattleLine = "start `"`" `"$battleNetExe`" --exec=`"launch $($def.BattleNetCode)`""

    if (-not $multiFlavour -and $def.Id -eq 'retail') {
        # Byte-identical to every pre-flavours install.ps1's exact output.
        $cmdLaunchLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$cliPath`" -Launcher -Quiet"
        $cmdLines = @(
            '@echo off',
            'rem Updates all addons via AddonSync\addon-sync.ps1, then launches WoW retail via Battle.net.',
            'rem Run hidden via "Launch WoW (Updated).vbs" - do not run this directly unless you want a console window.',
            'rem Results: AddonSync\last-run.txt  History: AddonSync\sync.log',
            $cmdLaunchLine,
            $cmdBattleLine
        )
        # NOTE: a "'literal' + $var + 'literal'" expression used directly as
        # an @(...) array element (as opposed to being assigned to a
        # variable first, as above) has been observed on this machine to
        # split into SEPARATE array elements instead of concatenating -
        # each interpolated line is therefore built into its own named
        # variable first, never inline inside the array literal.
        $vbsRunLine = "sh.Run ""cmd /c """"$launcherCmdPath"""""", 0, False"
        $vbsLines = @(
            "' Silently updates addons via Furphy Addon Manager, then launches WoW retail.",
            "' Window style 0 = fully hidden, no console flash, no focus steal.",
            'Set sh = CreateObject("WScript.Shell")',
            $vbsRunLine
        )
    } else {
        # Multiple flavours installed, or a non-retail flavour: name the
        # flavour explicitly and, per S4.7/S6.3, say honestly when the
        # Battle.net launch itself isn't proven reliable (addons still
        # update regardless - only the auto-launch step is in question).
        $cmdLaunchLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$cliPath`" -Launcher -Flavor $($def.Id) -Quiet"
        $reliabilityLine = if ($def.Reliable) {
            "rem $($def.Label) launch via Battle.net is proven reliable."
        } else {
            "rem $($def.Label) launch via Battle.net is NOT proven reliable (community reports a flaky silent-launch for this product code) - addons still update either way; you may need to press Play yourself in Battle.net."
        }
        $cmdLines = @(
            '@echo off',
            "rem Updates all addons via AddonSync\addon-sync.ps1, then launches WoW ($($def.Label)) via Battle.net.",
            'rem Run hidden via "Launch WoW (Updated).vbs" - do not run this directly unless you want a console window.',
            'rem Results: AddonSync\last-run.txt  History: AddonSync\sync.log',
            $reliabilityLine,
            $cmdLaunchLine,
            $cmdBattleLine
        )
        $vbsRunLine = "sh.Run ""cmd /c """"$launcherCmdPath"""""", 0, False"
        $vbsLines = @(
            "' Silently updates addons via Furphy Addon Manager, then launches WoW ($($def.Label)).",
            "' Window style 0 = fully hidden, no console flash, no focus steal.",
            'Set sh = CreateObject("WScript.Shell")',
            $vbsRunLine
        )
    }

    Set-Content -LiteralPath $launcherCmdPath -Value $cmdLines -Encoding Ascii
    Set-Content -LiteralPath $launcherVbsPath -Value $vbsLines -Encoding Ascii
    Write-Info "Wrote $launcherCmdPath"
    Write-Info "Wrote $launcherVbsPath"
    $launcherWritten.Add([PSCustomObject]@{ Def = $def; CmdPath = $launcherCmdPath; VbsPath = $launcherVbsPath; FlavourDir = $flavourDir })
}

if ($battleNetExe -ne 'C:\Program Files (x86)\Battle.net\Battle.net.exe' -and -not (Test-Path -LiteralPath $battleNetExe)) {
    Write-Warn2 "Battle.net.exe was not found at $battleNetExe - the WoW launch step may not work until it is installed there."
} elseif (-not (Test-Path -LiteralPath $battleNetExe)) {
    Write-Warn2 "Battle.net.exe was not found. Update-and-launch will only update addons until Battle.net is installed."
}

# =====================================================================
# 6. Desktop shortcuts
#    FLAVORS-SPEC S7.2: single first-class flavour installed -> today's
#    exact unlabeled shortcut name, zero visible change. More than one
#    -> one labeled shortcut per flavour ("WoW - Classic (auto-update
#    addons)"), each pointing at that flavour's own launcher pair.
# =====================================================================

if (-not $NoShortcuts) {
    Write-Step 'Creating desktop shortcuts'
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

        foreach ($lw in $launcherWritten) {
            $def = $lw.Def
            $shortcutName = if ($multiFlavour) { "WoW - $($def.Label) (auto-update addons).lnk" } else { 'WoW (auto-update addons).lnk' }
            $sc2 = $wsh.CreateShortcut((Join-Path -Path $desktop -ChildPath $shortcutName))
            $sc2.TargetPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wscript.exe'
            $sc2.Arguments = '"' + $lw.VbsPath + '"'
            $sc2.WorkingDirectory = $lw.FlavourDir
            $wowExe = Join-Path -Path $lw.FlavourDir -ChildPath 'Wow.exe'
            if (Test-Path -LiteralPath $wowExe) {
                $sc2.IconLocation = $wowExe
            } elseif (Test-Path -LiteralPath $iconIco) {
                $sc2.IconLocation = $iconIco
            }
            $sc2.Save()
            Write-Info "Created shortcut: $shortcutName"
        }
    } catch {
        Write-Warn2 "Could not create desktop shortcuts: $($_.Exception.Message)"
    }
} else {
    Write-Info 'Skipped desktop shortcuts (-NoShortcuts).'
}

# =====================================================================
# 7. curseforge:// protocol handler
#    FLAVORS-SPEC S5.5/S7.3: unchanged, verbatim - one app, one server,
#    one port, one registration regardless of flavour count.
# =====================================================================

if (-not $NoProtocol) {
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
    Write-Step 'Looking for existing addons to adopt'
    $showFlavourHeader = ($installedFlavours.Count -gt 1)

    foreach ($def in $installedFlavours) {
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
            Write-Info 'Could not read scan results - skipped adoption.'
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
            Write-Info 'No untracked folders with a recognizable CurseForge or Wago id - nothing to adopt.'
        } else {
            $idArg = [string]::Join(',', $targets.ToArray())
            Write-Info "Adopting $($targets.Count) addon(s) (reinstalling each from its source)..."
            $addJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -AddonsPath $flavourAddonsPath -Flavor $def.Id -Add $idArg -Json
            $addResult = $null
            try { $addResult = $addJson | ConvertFrom-Json } catch { $addResult = $null }
            if ($addResult -and $addResult.results) {
                foreach ($r in @($addResult.results)) {
                    Write-Info ("  " + $r.status + ": " + $r.name)
                }
            } else {
                Write-Warn2 'Could not parse the adopt step''s results - check sync.log.'
            }
        }

        if ($unmanaged.Count -gt 0) {
            Write-Info 'Left unmanaged (no CurseForge or Wago id found in their .toc):'
            foreach ($name in $unmanaged) { Write-Info ("  - " + $name) }
        }
    }
} else {
    Write-Info 'Skipped adoption (-SkipAdopt).'
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
Write-Info 'No CurseForge API key is required - Browse and installs both work out of the box.'
Write-Info '(An optional key in Settings adds official CurseForge metadata: descriptions, changelogs, screenshots.)'
exit 0
