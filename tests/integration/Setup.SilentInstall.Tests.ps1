<#
=====================================================================
 tests\integration\Setup.SilentInstall.Tests.ps1

 SETUP-SPEC.md section 12.2: real `FurphyAddonManager-Setup.exe /S`
 scratch install test - end to end through the real, built Setup.exe,
 its real embedded payload, and the real install.ps1 -Console -Quiet
 path it launches as a hidden child.

 SAFETY, read before touching this file (see the build root's own HARD
 RULES): every install this file runs is `/S -WowPath <SCRATCH> -NoShortcuts
 -NoProtocol -SkipAdopt` against a SCRATCH COPY of fixtures\wowroot
 (Copy-Fixture into a fresh tests\.tmp\ root - never the real WoW
 install), with the scratch appDest's own settings.json pre-seeded with
 "port": 47975 (the 47970-47989 reserved range) BEFORE Setup.exe ever
 runs, so per-install scoping (Get-InstallStartupValueName/
 Get-InstallAppsKeyName, install.ps1) yields the shared 'FurphyAddonManager.
 Test' name, never the real production 'FurphyAddonManager' one.
 $env:FURPHY_TEST_SETUP_MUTEX_SUFFIX is set to a fresh GUID for every
 launch (section 4.2 step 3's own re-checked fix: FurphySetup.exe's
 single-instance mutex has no port to scope by on its own - without this
 seam, this file's own launch could collide with a real interactive
 Setup.exe or with another concurrently-running copy of this same test
 and fail on exit code 4 for a reason unrelated to the code under test).
 This file never sets -Upgrade anywhere (that is the self-updater's own,
 separate, fixed command line - SETUP-SPEC.md section 5.5/8 - Setup.exe
 never sets it either); Invoke-FurphyInstallSteps only ever RELAUNCHES a
 process under -Upgrade, so a plain /S run here never starts
 FurphyHost.exe, a tray, or a window of any kind (confirmed against
 install.ps1's own Invoke-FurphyInstallSteps: it builds host\bin\
 FurphyHost.exe via csc, exactly like every other scratch-install test in
 this suite, but never launches it without -Upgrade).

 This file snapshots the REAL production Run value and the REAL
 Installed-Apps key BEFORE and AFTER the whole test and asserts they are
 byte-identical - the same live-safety pattern
 tests\integration\Server.Uninstall.Tests.ps1 already established
 (Get-ProductionRunValue/Get-ProductionInstalledAppsSnapshot, duplicated
 locally here rather than shared via tests\lib\common.ps1, matching how
 tests\fixture-acceptance\AppUpdate.SilentUpgrade.Tests.ps1 already
 duplicates the same two functions rather than centralizing them).

 SETUP-SPEC.md section 12's own opening note (re-checked, still true):
 Get-InstallStartupValueName/Get-InstallAppsKeyName return the literal
 'FurphyAddonManager.Test' for EVERY non-production port, with no port
 number appended - so this shared registry key must never be assumed
 "this test's own"; it is always snapshotted, diffed, and removed in a
 finally block, and this test must never run concurrently with another
 round's own test that also writes it.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Get-ProductionRunValue {
    <# The REAL HKCU Run value's string content, or $null if absent. Never
       writes anything - read-only snapshot for a before/after comparison. #>
    try {
        $prop = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        if ($null -eq $prop) { return $null }
        return [string]$prop.FurphyAddonManager
    } catch {
        return $null
    }
}

function Get-ProductionInstalledAppsSnapshot {
    <# The REAL Installed-Apps key's meaningful fields, or $null if the key
       does not exist. Read-only. #>
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

function Get-FurphyScratchArpEntryNames {
    <#
      Every Add/Remove Programs subkey name under HKCU's Uninstall root
      that starts with "Furphy" EXCEPT the real production
      'FurphyAddonManager' key itself - i.e. anything a scratch/test
      install (or a Setup.exe regression writing its own, differently-
      named entry - SETUP-SPEC.md 12.4's live twin) could have created.
      Read-only.
    #>
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $names = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'Furphy*' -and $_.PSChildName -ne 'FurphyAddonManager' } |
        ForEach-Object { $_.PSChildName })
    return @($names | Sort-Object)
}

function Get-FurphySetupTempEntries {
    <#
      Every %TEMP% entry (file or directory) matching FurphySetup's own
      naming convention for the given exe version - the extraction folder
      "FurphySetup-<ver>-<guid8>" (section 4.6) and its short-lived sibling
      payload zip "FurphySetup-<ver>-<guid8>-payload.zip" (deleted in
      ExtractPayload's own finally block regardless of success). Read-only
      - used only for a before/after diff, never to delete anything itself.
    #>
    param([Parameter(Mandatory = $true)][string]$Version)
    $tempDir = [System.IO.Path]::GetTempPath()
    $pattern = "FurphySetup-$Version-*"
    $entries = New-Object 'System.Collections.Generic.List[string]'
    try {
        Get-ChildItem -LiteralPath $tempDir -Filter $pattern -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $entries.Add($_.FullName) }
    } catch { }
    return @($entries.ToArray() | Sort-Object)
}

function Invoke-SetupSilentProcess {
    <#
      Launches FurphyAddonManager-Setup.exe directly (not via
      Invoke-CliProcess, which is powershell.exe -File specific) with the
      given argument list and environment-variable overrides, waits for it
      to exit (bounded), and returns its exit code + captured stdout/
      stderr. Same deadlock-safe "start async reads, then WaitForExit"
      shape as Invoke-CliProcess (tests\lib\common.ps1) - duplicated
      locally rather than extended into common.ps1 (outside this
      package's own edit scope this round). Arguments are pre-quoted via
      ConvertTo-Win32QuotedArg (common.ps1, already dot-sourced above)
      into ONE .Arguments string, exactly like Invoke-CliProcess already
      does and for the identical reason (this environment's own
      [ProcessStartInfo]::ArgumentList is confirmed $null by default,
      per that function's own doc comment).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 240,
        [hashtable]$EnvironmentOverrides = @{}
    )

    $quotedArgs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in $ArgumentList) { $quotedArgs.Add((ConvertTo-Win32QuotedArg -Value $a)) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = ($quotedArgs.ToArray() -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($key in $EnvironmentOverrides.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$EnvironmentOverrides[$key]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stdout = ''
    $stderr = ''
    $exitCode = $null
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "Invoke-SetupSilentProcess: '$ExePath' did not exit within ${TimeoutSec}s"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

# ---------------------------------------------------------------------
# Prerequisites: a real, current dist\FurphyAddonManager-Setup.exe.
# Rebuilds it (a normal build invocation, never an edit to package.ps1 or
# setup\build-setup.ps1) if missing or stale relative to the current
# VERSION file - mirrors tests\host\Host.Tests.ps1's own Ensure-HostBuilt
# staleness check, so a version bump mid-session (observed live during
# this round) can never silently test an old binary.
# ---------------------------------------------------------------------

$Script:SetupBuildScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'setup\build-setup.ps1'
$Script:PackageScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'package.ps1'
$Script:DistDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'dist'
$Script:VersionPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'VERSION'
$Script:Version = ''
if (Test-Path -LiteralPath $Script:VersionPath -PathType Leaf) {
    $Script:Version = ([System.IO.File]::ReadAllText($Script:VersionPath)).Trim()
}
$Script:SetupExePath = Join-Path -Path $Script:DistDir -ChildPath 'FurphyAddonManager-Setup.exe'

Describe 'Setup.SilentInstall - prerequisites' {
    It 'setup\build-setup.ps1 is present (Package A)' {
        (Test-Path -LiteralPath $Script:SetupBuildScript -PathType Leaf) | Should Be $true
    }
    It 'VERSION is present and non-empty' {
        $Script:Version | Should Not BeNullOrEmpty
    }
}

$Script:HavePrereqs = (Test-Path -LiteralPath $Script:SetupBuildScript -PathType Leaf) -and [bool]$Script:Version

if ($Script:HavePrereqs) {
    $needsBuild = $true
    if (Test-Path -LiteralPath $Script:SetupExePath -PathType Leaf) {
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Script:SetupExePath)
            if ($vi.ProductVersion -eq $Script:Version) { $needsBuild = $false }
        } catch { }
    }
    if ($needsBuild) {
        $payloadZipPath = Join-Path -Path $Script:DistDir -ChildPath ("FurphyAddonManager-{0}.zip" -f $Script:Version)
        $payloadShaPath = "$payloadZipPath.sha256"
        if (-not ((Test-Path -LiteralPath $payloadZipPath -PathType Leaf) -and (Test-Path -LiteralPath $payloadShaPath -PathType Leaf))) {
            Write-Host "  (dist\FurphyAddonManager-$($Script:Version).zip missing - running package.ps1 to build it)"
            Invoke-CliProcess -ScriptPath $Script:PackageScript -ArgumentList @('-Source', $Script:FurphyBuildRoot, '-DistDir', $Script:DistDir) -TimeoutSec 180 | Out-Null
        }
        Write-Host "  (dist\FurphyAddonManager-Setup.exe missing or stale - running setup\build-setup.ps1)"
        Invoke-CliProcess -ScriptPath $Script:SetupBuildScript -ArgumentList @('-Version', $Script:Version, '-DistDir', $Script:DistDir) -TimeoutSec 180 | Out-Null
    }
}

if ($Script:HavePrereqs -and (Test-Path -LiteralPath $Script:SetupExePath -PathType Leaf)) {

    Describe 'FurphyAddonManager-Setup.exe /S - real scratch silent install (SETUP-SPEC.md 12.2, port 47975)' {

        It 'installs cleanly via /S pass-through args, cleans up its own temp folder, writes exactly one Add/Remove entry (the ''.Test'' one), a re-run leaves still exactly one, and the REAL production Run value / Installed-Apps key are byte-identical before and after' {

            $exeVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Script:SetupExePath)
            $exeVersion = $exeVersionInfo.ProductVersion
            $exeVersion | Should Not BeNullOrEmpty

            # ---- live-safety snapshot BEFORE ----
            $runBefore = Get-ProductionRunValue
            $appsBefore = Get-ProductionInstalledAppsSnapshot
            Write-Host "  [live-safety BEFORE] Run value present: $([bool]$runBefore) | Installed-Apps key present: $([bool]$appsBefore)"

            $tempBefore = Get-FurphySetupTempEntries -Version $exeVersion

            $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'setup-silentinstall-wowroot')
            $appDest = Join-Path -Path $wowRoot -ChildPath '_retail_\AddonSync'
            New-Item -ItemType Directory -Path $appDest -Force | Out-Null
            # Pre-seeded BEFORE Setup.exe ever runs - Invoke-InstallCopyAndBuildSteps
            # only writes a default settings.json when one is not already
            # present, so this port (47970-47989 range) is what
            # Get-InstallPort/Get-InstallStartupValueName actually see.
            '{ "releaseType": 1, "port": 47975 }' | Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

            $arpKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'
            $setupArgs = @('/S', '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt')

            try {
                # ---- first run: fresh install ----
                $mutexSuffix1 = [Guid]::NewGuid().ToString('N')
                $r1 = Invoke-SetupSilentProcess -ExePath $Script:SetupExePath -ArgumentList $setupArgs -TimeoutSec 240 -EnvironmentOverrides @{ FURPHY_TEST_SETUP_MUTEX_SUFFIX = $mutexSuffix1 }
                if ($r1.ExitCode -ne 0) {
                    Write-Host "Setup.exe /S (install) STDOUT:`n$($r1.StdOut)"
                    Write-Host "Setup.exe /S (install) STDERR:`n$($r1.StdErr)"
                }
                $r1.ExitCode | Should Be 0

                # ---- files present: same shape a plain -Console -Quiet install already produces ----
                (Test-Path -LiteralPath $appDest) | Should Be $true
                foreach ($expected in @('install.ps1', 'addon-server.ps1', 'addon-sync.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'icon.ico', 'VERSION', 'README.txt', 'CHANGELOG.md', 'settings.json')) {
                    (Test-Path -LiteralPath (Join-Path $appDest $expected) -PathType Leaf) | Should Be $true
                }
                (Test-Path -LiteralPath (Join-Path $appDest 'ui') -PathType Container) | Should Be $true
                (Test-Path -LiteralPath (Join-Path $appDest 'ui\index.html') -PathType Leaf) | Should Be $true
                (Test-Path -LiteralPath (Join-Path $appDest 'host') -PathType Container) | Should Be $true
                $installedVersion = (Get-Content -Raw -LiteralPath (Join-Path $appDest 'VERSION')).Trim()
                $installedVersion | Should Be $exeVersion

                # ---- FurphySetup.exe's own temp extraction folder is gone ----
                $tempAfterInstall = Get-FurphySetupTempEntries -Version $exeVersion
                $newLeftovers1 = @($tempAfterInstall | Where-Object { $tempBefore -notcontains $_ })
                if ($newLeftovers1.Count -gt 0) { Write-Host "  leftover temp entries: $($newLeftovers1 -join ', ')" }
                $newLeftovers1.Count | Should Be 0

                # Setup /S never attempts a Process.MainWindowHandle poll at all
                # (SETUP-SPEC.md 12.2's own text: "no window - no
                # Process.MainWindowHandle poll matters for /S, none is
                # attempted") - nothing to assert here beyond the exit code
                # and file-system/registry effects already covered above and
                # below.

                # ---- exactly one Add/Remove entry, and it is the '.Test' one ----
                $scratchArpNames1 = Get-FurphyScratchArpEntryNames
                ($scratchArpNames1 -join ',') | Should Be 'FurphyAddonManager.Test'
                (Test-Path -LiteralPath $arpKeyPath) | Should Be $true

                # ---- re-run (repair/upgrade) over the same scratch install: the
                #      spec's own grafted regression - still exactly one entry,
                #      never a second, differently-named one from Setup.exe itself ----
                $mutexSuffix2 = [Guid]::NewGuid().ToString('N')
                $r2 = Invoke-SetupSilentProcess -ExePath $Script:SetupExePath -ArgumentList $setupArgs -TimeoutSec 240 -EnvironmentOverrides @{ FURPHY_TEST_SETUP_MUTEX_SUFFIX = $mutexSuffix2 }
                if ($r2.ExitCode -ne 0) {
                    Write-Host "Setup.exe /S (re-run) STDOUT:`n$($r2.StdOut)"
                    Write-Host "Setup.exe /S (re-run) STDERR:`n$($r2.StdErr)"
                }
                $r2.ExitCode | Should Be 0

                $tempAfterRerun = Get-FurphySetupTempEntries -Version $exeVersion
                $newLeftovers2 = @($tempAfterRerun | Where-Object { $tempBefore -notcontains $_ })
                if ($newLeftovers2.Count -gt 0) { Write-Host "  leftover temp entries after re-run: $($newLeftovers2 -join ', ')" }
                $newLeftovers2.Count | Should Be 0

                $scratchArpNames2 = Get-FurphyScratchArpEntryNames
                ($scratchArpNames2 -join ',') | Should Be 'FurphyAddonManager.Test'
            } finally {
                # No process to stop first: Setup.exe blocks on its own child's
                # WaitForExit() before it exits itself (section 4.2 step 9), and
                # this test has already waited for Setup.exe's own exit above -
                # nothing from this run is still running by this point.
                if (Test-Path -LiteralPath $arpKeyPath) {
                    Remove-Item -LiteralPath $arpKeyPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                if ($wowRoot -and (Test-Path -LiteralPath $wowRoot)) {
                    Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            # ---- live-safety snapshot AFTER - must be byte-identical to BEFORE ----
            $runAfter = Get-ProductionRunValue
            $appsAfter = Get-ProductionInstalledAppsSnapshot
            Write-Host "  [live-safety AFTER]  Run value present: $([bool]$runAfter) | Installed-Apps key present: $([bool]$appsAfter)"
            $runAfter | Should Be $runBefore
            (ConvertTo-Json -InputObject $appsAfter -Compress) | Should Be (ConvertTo-Json -InputObject $appsBefore -Compress)
        }
    }
} else {
    Write-Host 'SKIPPING the real /S install Describe: setup\build-setup.ps1, VERSION, or a built FurphyAddonManager-Setup.exe is missing (see the prerequisites Describe above).'
}
