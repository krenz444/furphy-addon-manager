<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's P1 perf-pass -Launcher
  helpers - Get-StateUpdatesCheckedAtMinutesAgo (the skip-if-recently-
  checked rule's read-only state.json lookup) and Test-LauncherBudgetExceeded
  (the pure/deterministic core of the launch-chain wall-clock budget). The
  full end-to-end -Launcher gate (skip actually firing, or not, for a real
  CLI process) is covered separately in
  tests\integration\Cli.InstallRollbackLauncher.Tests.ps1 - this file is
  just the two small functions those behaviors are built on.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

Describe 'Get-StateUpdatesCheckedAtMinutesAgo' {

    It 'returns $null when state.json does not exist at all' {
        $root = New-TempRoot -Name 'checked-missing'
        (Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail') | Should Be $null
    }

    It 'returns $null when state.json exists but has no updatesCheckedAt at all' {
        $root = New-TempRoot -Name 'checked-empty'
        (ConvertTo-Json -InputObject @{ jobs = @() } -Depth 4) | Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8
        (Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail') | Should Be $null
    }

    It 'returns $null when state.json is corrupt/unparseable' {
        $root = New-TempRoot -Name 'checked-corrupt'
        Set-Content -LiteralPath (Join-Path $root 'state.json') -Value '{ this is not json' -Encoding UTF8
        (Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail') | Should Be $null
    }

    It 'returns approximately the right number of minutes for the current per-flavour object shape' {
        $root = New-TempRoot -Name 'checked-object-shape'
        $iso = (Get-Date).ToUniversalTime().AddMinutes(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
        (ConvertTo-Json -InputObject @{ updatesCheckedAt = @{ retail = $iso; classic_era = '2020-01-01T00:00:00Z' } } -Depth 4) |
            Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8

        $minutesAgo = Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail'
        ($null -eq $minutesAgo) | Should Be $false
        ([math]::Abs($minutesAgo - 7) -lt 1) | Should Be $true
    }

    It 'returns $null for a flavour with no entry in the per-flavour object, even though other flavours have one' {
        $root = New-TempRoot -Name 'checked-object-missing-flavour'
        (ConvertTo-Json -InputObject @{ updatesCheckedAt = @{ classic_era = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } -Depth 4) |
            Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8
        (Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail') | Should Be $null
    }

    It 'tolerates the pre-flavour flat-string shape, treated as the retail bucket' {
        $root = New-TempRoot -Name 'checked-flat-shape'
        $iso = (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
        (ConvertTo-Json -InputObject @{ updatesCheckedAt = $iso } -Depth 4) |
            Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8

        $minutesAgo = Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail'
        ($null -eq $minutesAgo) | Should Be $false
        ([math]::Abs($minutesAgo - 3) -lt 1) | Should Be $true
    }

    It 'the pre-flavour flat-string shape is null for any OTHER flavour (it only ever means retail)' {
        $root = New-TempRoot -Name 'checked-flat-shape-other-flavour'
        (ConvertTo-Json -InputObject @{ updatesCheckedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } -Depth 4) |
            Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8
        (Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'classic_era') | Should Be $null
    }
}

Describe 'Test-LauncherBudgetExceeded' {

    It 'is $false well before the budget (10s elapsed, 40s budget)' {
        $start = (Get-Date).AddSeconds(-10)
        (Test-LauncherBudgetExceeded -StartTime $start -BudgetSeconds 40 -Now (Get-Date)) | Should Be $false
    }

    It 'is $true once elapsed reaches the budget exactly' {
        $now = Get-Date
        $start = $now.AddSeconds(-40)
        (Test-LauncherBudgetExceeded -StartTime $start -BudgetSeconds 40 -Now $now) | Should Be $true
    }

    It 'is $true well past the budget (41s elapsed, 40s budget)' {
        $now = Get-Date
        $start = $now.AddSeconds(-41)
        (Test-LauncherBudgetExceeded -StartTime $start -BudgetSeconds 40 -Now $now) | Should Be $true
    }

    It 'is $false at 39s elapsed against a 40s budget (boundary, one second under)' {
        $now = Get-Date
        $start = $now.AddSeconds(-39)
        (Test-LauncherBudgetExceeded -StartTime $start -BudgetSeconds 40 -Now $now) | Should Be $false
    }
}
