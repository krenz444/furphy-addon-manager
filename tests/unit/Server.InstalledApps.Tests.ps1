<#
  Unit tests (Pester 3 syntax): addon-server.ps1's round-33 Installed-Apps
  registration-refresh helpers (DISTRIBUTION-SPEC.md section 5.4) - pure
  functions only. Test-LooksLikeScratchRun here is a verbatim duplicate of
  install.ps1's own function of the same name (tests\unit\Install.Scoping.
  Tests.ps1 covers that copy) - this file exercises THIS copy
  independently, since a future edit to one copy drifting from the other
  is exactly the kind of bug duplication risks.

  SAFETY: nothing in this file starts a listener, writes to the registry,
  or ever sets $Script:Port to 47831 - Update-InstalledAppsRegistration's
  own two-line guard (port must be 47831 AND the root must not look like
  scratch) is exercised here ONLY from the side that returns immediately,
  so this file can never reach the Set-ItemProperty calls that would touch
  the real production Installed-Apps key.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

Describe 'addon-server.ps1 Test-LooksLikeScratchRun (round-33 duplicate of install.ps1''s own)' {
    It 'a %TEMP%-rooted path looks like scratch' {
        Test-LooksLikeScratchRun -Path (Join-Path $env:TEMP 'furphy-anything') | Should Be $true
    }
    It 'a \scratch\ path looks like scratch' {
        Test-LooksLikeScratchRun -Path 'C:\builds\scratch\AddonSync' | Should Be $true
    }
    It 'fixtures\wowroot looks like scratch' {
        Test-LooksLikeScratchRun -Path (Join-Path $Script:FurphyBuildRoot 'fixtures\wowroot\_retail_\AddonSync') | Should Be $true
    }
    It 'a real-looking production path is not scratch' {
        Test-LooksLikeScratchRun -Path 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync' | Should Be $false
    }
    It 'an empty or null path is not scratch' {
        Test-LooksLikeScratchRun -Path '' | Should Be $false
        Test-LooksLikeScratchRun -Path $null | Should Be $false
    }
}

Describe 'Get-InstalledAppsSizeKB' {
    $Script:SizeRoot = New-TempRoot -Name 'installedappssize'
    [IO.File]::WriteAllBytes((Join-Path $Script:SizeRoot 'a.bin'), (New-Object byte[] 2048))
    [IO.File]::WriteAllBytes((Join-Path $Script:SizeRoot 'b.bin'), (New-Object byte[] 1024))

    It 'sums file sizes recursively and rounds to the nearest KB' {
        Get-InstalledAppsSizeKB -Path $Script:SizeRoot | Should Be 3
    }
    It 'returns 0 for a missing path (never throws)' {
        Get-InstalledAppsSizeKB -Path (Join-Path $Script:SizeRoot 'does-not-exist') | Should Be 0
    }
    It 'returns 0 for an empty or null path' {
        Get-InstalledAppsSizeKB -Path '' | Should Be 0
        Get-InstalledAppsSizeKB -Path $null | Should Be 0
    }
}

Describe 'Get-InstalledAppsUninstallString (section 5.4: same converged one-liner install.ps1''s own Get-InstallUninstallString builds)' {
    It 'embeds the port, appDest and wowRoot in the documented shape' {
        $cmd = Get-InstalledAppsUninstallString -Port 47831 -AppDest 'C:\WoW\_retail_\AddonSync' -WowRootPath 'C:\WoW'
        $cmd | Should Match '^powershell\.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "'
        $cmd | Should Match ([regex]::Escape('http://localhost:47831/api/uninstall'))
        $cmd | Should Match ([regex]::Escape("Origin='http://localhost:47831'"))
        $cmd | Should Match ([regex]::Escape('C:\WoW\_retail_\AddonSync\install.ps1'))
        $cmd | Should Match ([regex]::Escape("'-WowPath','C:\WoW'"))
    }

    It 'changes when the inputs change' {
        $a = Get-InstalledAppsUninstallString -Port 47831 -AppDest 'C:\A\_retail_\AddonSync' -WowRootPath 'C:\A'
        $b = Get-InstalledAppsUninstallString -Port 47899 -AppDest 'C:\B\_retail_\AddonSync' -WowRootPath 'C:\B'
        $a | Should Not Be $b
    }
}

function New-FakeRunningJob {
    <# Update-JobStatus returns a job unchanged (without touching a real
       process or sync.log) whenever state is already 'running' AND
       .Process is falsy - see that function's own early-return guard
       ("$Job.state -ne 'running' -or -not $Job.Process"). A bare
       PSCustomObject with only 'state' set satisfies both, deterministically
       and instantly, with zero real process/network involved - the same
       fake-job technique tests\unit\Server.Handlers.Tests.ps1 already uses
       for other handlers via its own New-FakeJob. #>
    return [PSCustomObject]@{ state = 'running' }
}

Describe 'Handle-Uninstall (POST /api/uninstall) busy-check - in-process via a fake context, no real process/network/registry' {
    BeforeEach {
        $Script:CurrentJobByFlavour = @{}
    }

    It 'refuses with 409 and the documented plain-language body when ANY flavour has a job running (FLAVORS-SPEC CS-F2 S5.4 rule, reused from Handle-Shutdown)' {
        $Script:CurrentJobByFlavour['classic'] = New-FakeRunningJob
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/uninstall'
        Handle-Uninstall -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 409
        $body = Get-FakeResponseBody -Context $ctx
        $body.error | Should Be 'Furphy is updating an addon right now. Try again in a minute.'
    }

    It 'the busy refusal never gets far enough to copy a temp uninstaller (no stray %TEMP% FurphyUninstall-*.ps1 files)' {
        $before = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'FurphyUninstall-*.ps1' -ErrorAction SilentlyContinue).Count
        $Script:CurrentJobByFlavour['retail'] = New-FakeRunningJob
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/uninstall'
        Handle-Uninstall -Context $ctx -RouteMatch @{}
        $after = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'FurphyUninstall-*.ps1' -ErrorAction SilentlyContinue).Count
        $after | Should Be $before
    }

    It 'a job that is done (not running) does not block uninstall - only "running" refuses' {
        $Script:CurrentJobByFlavour['retail'] = [PSCustomObject]@{ state = 'done' }
        $anyRunning = $false
        foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
            if ($cj) {
                $refreshed = Update-JobStatus -Job $cj
                if ($refreshed -and $refreshed.state -eq 'running') { $anyRunning = $true }
            }
        }
        $anyRunning | Should Be $false
    }
}

Describe 'Update-InstalledAppsRegistration gating - never reaches a registry write off the production port or against a scratch root' {
    It 'returns without throwing for a non-production port, regardless of root' {
        $Script:Port = 47899
        $Script:Root = 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync'
        { Update-InstalledAppsRegistration } | Should Not Throw
    }
    It 'returns without throwing for the production port against a scratch root' {
        $Script:Port = 47831
        $Script:Root = Join-Path $env:TEMP 'furphy-never-really-written-installedapps'
        { Update-InstalledAppsRegistration } | Should Not Throw
    }
}
