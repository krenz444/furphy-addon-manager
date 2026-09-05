<#
=====================================================================
 tests\integration\Cli.StatusAndDetection.Tests.ps1

 addon-sync.ps1 -Status -Json's exact top-level key set, flavour detection
 order against the fixture, and -Scan per flavour - driven as a REAL child
 process (Invoke-CliJson/Invoke-CliProcess), never dot-sourced/in-process.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe '-Status -Json exact key set' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-status') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    It 'returns exactly {action, flavour, installedFlavours, results, addons, clientBuild, clientInterface}' {
        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Status', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $names = @($r.Json.PSObject.Properties.Name)
        $expected = @('action', 'flavour', 'installedFlavours', 'results', 'addons', 'clientBuild', 'clientInterface')
        # Order-independent set equality, both directions.
        foreach ($n in $expected) { ($names -contains $n) | Should Be $true }
        foreach ($n in $names) { ($expected -contains $n) | Should Be $true }
        $names.Count | Should Be $expected.Count
        $r.Json.action | Should Be 'status'
    }
}

Describe 'flavour detection order on the fixture' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-detect') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    It 'installedFlavours is retail, classic, classic_era, ptr - in that fixed order (xptr/beta absent from the fixture)' {
        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Status', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $ids = @($r.Json.installedFlavours)
        $ids.Count | Should Be 4
        $ids[0] | Should Be 'retail'
        $ids[1] | Should Be 'classic'
        $ids[2] | Should Be 'classic_era'
        $ids[3] | Should Be 'ptr'
    }

    It 'the default (omitted -Flavor) run resolves to retail, since retail is installed' {
        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Status', '-Json', '-WowRoot', $wowRoot)
        $r.Json.flavour | Should Be 'retail'
    }
}

Describe '-Scan per flavour' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-scan') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    It 'retail: SingleFlavourAddon is untracked (no addons.json exists yet)' {
        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Scan', '-Json', '-WowRoot', $wowRoot, '-Flavor', 'retail')
        $r.ExitCode | Should Be 0
        $r.Json.action | Should Be 'scan'
        $folders = @($r.Json.untracked | ForEach-Object { $_.folder })
        ($folders -contains 'SingleFlavourAddon') | Should Be $true
    }

    It 'classic_era: both MultiFlavourAddon and PreExistingEraAddon are untracked, with parsed toc title/version' {
        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Scan', '-Json', '-WowRoot', $wowRoot, '-Flavor', 'classic_era')
        $r.ExitCode | Should Be 0
        $rows = @($r.Json.untracked)
        $byFolder = @{}
        foreach ($row in $rows) { $byFolder[$row.folder] = $row }

        ($byFolder.ContainsKey('MultiFlavourAddon')) | Should Be $true
        $byFolder['MultiFlavourAddon'].hasToc | Should Be $true
        ([string]::IsNullOrEmpty($byFolder['MultiFlavourAddon'].title)) | Should Be $false

        ($byFolder.ContainsKey('PreExistingEraAddon')) | Should Be $true
        $byFolder['PreExistingEraAddon'].hasToc | Should Be $true
    }

    It 'classic (no addons installed there beyond the fixture default): FakeAddon is untracked' {
        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Scan', '-Json', '-WowRoot', $wowRoot, '-Flavor', 'classic')
        $r.ExitCode | Should Be 0
        $folders = @($r.Json.untracked | ForEach-Object { $_.folder })
        ($folders -contains 'FakeAddon') | Should Be $true
    }
}
