<#
=====================================================================
 install.ps1 - Furphy Addon Manager installer (E18)

 Finds a WoW retail install, copies the app into <retail>\AddonSync,
 writes the two launcher files into <retail> (rewritten for this
 machine's paths), creates desktop shortcuts, registers the
 curseforge:// protocol handler, and adopts any addon folders already
 present in AddOns - all without requiring a CurseForge API key.

 Windows PowerShell 5.1 only. No modules, no external binaries, pure
 ASCII.

 USAGE:
   install.ps1 [-WowPath <path>] [-NoShortcuts] [-NoProtocol] [-SkipAdopt] [-Uninstall]

   -WowPath <path>   The WoW folder that CONTAINS _retail_ (not _retail_
                      itself). Overrides auto-detection. Required when
                      the installer cannot find WoW on its own (a fresh
                      test tree, an unusual drive layout, etc).
   -NoShortcuts      Skip creating desktop shortcuts.
   -NoProtocol       Skip registering the curseforge:// install-link handler.
   -SkipAdopt        Skip scanning AddOns and adopting untracked folders.
   -Uninstall        Remove the app files, shortcuts and protocol
                      registration. AddOns and addons.json/settings.json/
                      state.json/logs/backups are left alone.

 Exit codes: 0 success, 2 could not find/validate the WoW folder.
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
# 1. Find the WoW retail folder
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
        if ($c -and (Test-Path -LiteralPath (Join-Path -Path $c -ChildPath '_retail_\Interface\AddOns') -PathType Container)) {
            return $c
        }
    }

    return $null
}

$wowRoot = Find-WowRoot -Override $WowPath
if (-not $wowRoot) {
    Write-Host ''
    Write-Host 'ERROR: Could not find a World of Warcraft retail installation.' -ForegroundColor Red
    Write-Host '       Pass -WowPath "<your WoW folder>" (the one that contains _retail_).' -ForegroundColor Red
    exit 2
}
$retail = Join-Path -Path $wowRoot -ChildPath '_retail_'
$addonsPath = Join-Path -Path $retail -ChildPath 'Interface\AddOns'
if (-not (Test-Path -LiteralPath $addonsPath -PathType Container)) {
    Write-Host ''
    Write-Host "ERROR: $addonsPath was not found." -ForegroundColor Red
    Write-Host '       Pass -WowPath "<your WoW folder>" (the one that contains _retail_).' -ForegroundColor Red
    exit 2
}
$appDest = Join-Path -Path $retail -ChildPath 'AddonSync'

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
    Write-Step "Uninstalling Furphy Addon Manager from $retail"

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

    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($name in @('Furphy Addon Manager.lnk', 'WoW (auto-update addons).lnk')) {
        $lnk = Join-Path -Path $desktop -ChildPath $name
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Info "Removed shortcut: $name"
        }
    }

    foreach ($name in @('update-addons-and-launch.cmd', 'Launch WoW (Updated).vbs')) {
        $p = Join-Path -Path $retail -ChildPath $name
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force
            Write-Info "Removed launcher file: $name"
        }
    }

    if (Test-Path -LiteralPath $appDest) {
        $keepFiles = @('addons.json', 'settings.json', 'state.json', 'sync.log', 'server.log', 'last-run.txt', 'server.pid')
        $keepDirs = @('jobs', 'backups', 'cache', 'staging')
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

    Write-Info "Your AddOns folder was not touched: $addonsPath"
    Write-Host ''
    Write-Host 'Uninstall complete.' -ForegroundColor Green
    exit 0
}

# =====================================================================
# 3. Copy the app into <retail>\AddonSync (never overwrite user state)
# =====================================================================

Write-Step "Installing Furphy Addon Manager into $appDest"

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
    '{ "releaseType": 1, "autoUpdateOnLaunch": true, "cfApiKey": "", "port": 47831 }' | Set-Content -LiteralPath $settingsPath -Encoding Ascii
    Write-Info 'Created default settings.json (no API key needed - see Settings for the optional one).'
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
# 5. Launcher pair, rewritten for this machine's paths
# =====================================================================

Write-Step 'Writing launcher files'

$battleNetExe = Find-BattleNetExe
$cliPath = Join-Path -Path $appDest -ChildPath 'addon-sync.ps1'
$launcherCmdPath = Join-Path -Path $retail -ChildPath 'update-addons-and-launch.cmd'
$launcherVbsPath = Join-Path -Path $retail -ChildPath 'Launch WoW (Updated).vbs'

$cmdLaunchLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$cliPath`" -Launcher -Quiet"
$cmdBattleLine = "start `"`" `"$battleNetExe`" --exec=`"launch WoW`""
$cmdLines = @(
    '@echo off',
    'rem Updates all addons via AddonSync\addon-sync.ps1, then launches WoW retail via Battle.net.',
    'rem Run hidden via "Launch WoW (Updated).vbs" - do not run this directly unless you want a console window.',
    'rem Results: AddonSync\last-run.txt  History: AddonSync\sync.log',
    $cmdLaunchLine,
    $cmdBattleLine
)
Set-Content -LiteralPath $launcherCmdPath -Value $cmdLines -Encoding Ascii

# NOTE: a "'literal' + $var + 'literal'" expression used directly as an
# @(...) array element (as opposed to being assigned to a variable first, as
# above) has been observed on this machine to split into SEPARATE array
# elements instead of concatenating - each interpolated line is therefore
# built into its own named variable first, never inline inside the array
# literal.
$vbsRunLine = "sh.Run ""cmd /c """"$launcherCmdPath"""""", 0, False"
$vbsLines = @(
    "' Silently updates addons via Furphy Addon Manager, then launches WoW retail.",
    "' Window style 0 = fully hidden, no console flash, no focus steal.",
    'Set sh = CreateObject("WScript.Shell")',
    $vbsRunLine
)
Set-Content -LiteralPath $launcherVbsPath -Value $vbsLines -Encoding Ascii
Write-Info "Wrote $launcherCmdPath"
Write-Info "Wrote $launcherVbsPath"
if ($battleNetExe -ne 'C:\Program Files (x86)\Battle.net\Battle.net.exe' -and -not (Test-Path -LiteralPath $battleNetExe)) {
    Write-Warn2 "Battle.net.exe was not found at $battleNetExe - the WoW launch step may not work until it is installed there."
} elseif (-not (Test-Path -LiteralPath $battleNetExe)) {
    Write-Warn2 "Battle.net.exe was not found. Update-and-launch will only update addons until Battle.net is installed."
}

# =====================================================================
# 6. Desktop shortcuts
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

        $sc2 = $wsh.CreateShortcut((Join-Path -Path $desktop -ChildPath 'WoW (auto-update addons).lnk'))
        $sc2.TargetPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wscript.exe'
        $sc2.Arguments = '"' + $launcherVbsPath + '"'
        $sc2.WorkingDirectory = $retail
        $wowExe = Join-Path -Path $retail -ChildPath 'Wow.exe'
        if (Test-Path -LiteralPath $wowExe) {
            $sc2.IconLocation = $wowExe
        } elseif (Test-Path -LiteralPath $iconIco) {
            $sc2.IconLocation = $iconIco
        }
        $sc2.Save()
        Write-Info 'Created shortcut: WoW (auto-update addons)'
    } catch {
        Write-Warn2 "Could not create desktop shortcuts: $($_.Exception.Message)"
    }
} else {
    Write-Info 'Skipped desktop shortcuts (-NoShortcuts).'
}

# =====================================================================
# 7. curseforge:// protocol handler
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
# =====================================================================

if (-not $SkipAdopt) {
    Write-Step 'Looking for existing addons to adopt'
    $scanJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -AddonsPath $addonsPath -Scan -Json
    $scan = $null
    try { $scan = $scanJson | ConvertFrom-Json } catch { $scan = $null }

    if (-not $scan -or -not $scan.untracked) {
        Write-Info 'Could not read scan results - skipped adoption.'
    } else {
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
            $addJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -AddonsPath $addonsPath -Add $idArg -Json
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
Write-Info 'No CurseForge API key is required - Browse and installs both work out of the box.'
Write-Info '(An optional key in Settings adds official CurseForge metadata: descriptions, changelogs, screenshots.)'
exit 0
