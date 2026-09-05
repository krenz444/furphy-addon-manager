<#
=====================================================================
 tests\integration\Server.State.Tests.ps1

 GET /api/ping and GET /api/state: response shape, version-matches-VERSION-
 file, the single-flavour-root vs multi-flavour-root ?flavour= contract
 (FLAVORS-SPEC.md S5.1/Resolve-RequestFlavour), and path-escape rejection.

 IMPORTANT FINDING (see notesForNext): GET /api/state is deliberately
 EXCLUDED from the "flavour required" 400 even on a multi-flavour root
 (Resolve-RequestFlavour's own header comment explains why: it is the
 client's bootstrap/discovery call). This file tests the CODE'S ACTUAL
 behaviour, not the task brief's assumption that /api/state 400s on a
 multi-flavour root without ?flavour= - it does not.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'GET /api/ping' {
    $root = New-TempRoot -Name 'ping'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'VERSION') -Destination (Join-Path $root 'VERSION') -Force
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899
        $expectedVersion = ([IO.File]::ReadAllText((Join-Path $Script:FurphyBuildRoot 'VERSION'))).Trim()

        It 'returns ok/version/uptime and the version matches the VERSION file' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/ping'
            $r.Ok | Should Be $true
            $r.Body.ok | Should Be $true
            $r.Body.version | Should Be $expectedVersion
            ($r.Body.uptime -ge 0) | Should Be $true
            $r.Body.name | Should Be 'Furphy Addon Manager'
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'GET /api/state - single/no-flavour root' {
    $root = New-TempRoot -Name 'state-single'
    $server = $null
    try {
        # No -WowRoot: Root's own leaf is not literally "AddonSync" (New-TempRoot
        # names it e.g. "state-single-<stamp>-<hex>"), so Get-InstalledFlavours
        # resolves nothing - the "<=1 installed" branch, exactly like a real
        # single-flavour machine for every ?flavour= decision that matters here.
        $server = Start-TestServer -Root $root -Port 47899

        It 'never 400s on GET /api/state with no ?flavour=' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state'
            $r.Ok | Should Be $true
        }

        It 'carries every documented additive/base field' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state'
            $names = ($r.Body.PSObject.Properties | ForEach-Object { $_.Name })
            $expected = @('installedFlavours', 'activeFlavour', 'flavour', 'pendingFlavourChoice',
                'addons', 'settings', 'lastRun', 'job', 'updatesCheckedAt', 'freshness',
                'lastCheckFailed', 'lastCheckError', 'clientBuild', 'clientInterface')
            foreach ($name in $expected) {
                ($names -contains $name) | Should Be $true
            }
        }

        It 'rejects an unrecognized ?flavour= value with 400, even at <=1 installed' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=bogus'
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'rejects a path-escape-shaped ?flavour= value with 400 and never reaches the filesystem' {
            $r = Invoke-Api -Port 47899 -Method Get -Path ('/api/state?flavour=' + [System.Uri]::EscapeDataString('..\..\Windows'))
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'GET /api/state and flavour-scoped endpoints - multi-flavour root (fixture)' {
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'state-multi-root'
    $server = $null
    try {
        # fixture has retail/classic/classic_era/ptr installed -> 4 flavours.
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It 'GET /api/state with no ?flavour= still succeeds (bootstrap exception) and reports every installed flavour' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state'
            $r.Ok | Should Be $true
            $r.Body.installedFlavours.Count | Should Be 4
            $r.Body.flavour | Should Be 'retail'
        }

        It 'a flavour-SCOPED endpoint (GET /api/scan) 400s "flavour required" with no ?flavour= on a multi-flavour root' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/scan'
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'flavour required'
        }

        It 'the same scoped endpoint succeeds once ?flavour= is supplied' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/scan?flavour=classic_era'
            $r.Ok | Should Be $true
        }

        It 'an unrecognized ?flavour= on a multi-flavour root is still a clean 400' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=xptr'
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'the flavour alias ?flavor= (no u) is accepted the same way' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavor=classic_era'
            $r.Ok | Should Be $true
            $r.Body.flavour | Should Be 'classic_era'
        }
    } finally {
        Stop-TestServer -Server $server
    }
}
