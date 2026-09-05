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

Describe 'Get-LauncherAwareTimeoutSec (Round 26 hardening: launch-chain per-call shrinking timeout)' {
    <#
      Review finding: two-or-more CurseForge/Wago-sourced addons in one
      -Launcher run could each independently cost the full -TimeoutSec 30
      on a hung/black-holed call, compounding past the 45s task-brief cap
      even though Test-LauncherBudgetExceeded (above) never interrupts a
      call already in flight - it only stops STARTING the next addon.
      Get-LauncherAwareTimeoutSec is what every CurseForge/Wago HTTP call
      site now asks for its -TimeoutSec instead of a hard-coded 30, so a
      call itself is bounded to whatever the budget has left in -Launcher
      mode. AfterEach resets $script:LauncherDeadline so one It's state
      never bleeds into the next (it is a plain script-scoped variable,
      not a parameter, per how addon-sync.ps1 arms it in Main).
    #>

    AfterEach {
        $script:LauncherDeadline = $null
    }

    It 'returns the default timeout unchanged when not in -Launcher mode ($script:LauncherDeadline unset)' {
        $script:LauncherDeadline = $null
        (Get-LauncherAwareTimeoutSec -DefaultTimeoutSec 30) | Should Be 30
    }

    It 'returns the default timeout when the full budget is still available' {
        $script:LauncherDeadline = (Get-Date).AddSeconds(40)
        (Get-LauncherAwareTimeoutSec -DefaultTimeoutSec 30) | Should Be 30
    }

    It 'shrinks to whatever is left of the budget once less than -DefaultTimeoutSec remains' {
        $script:LauncherDeadline = (Get-Date).AddSeconds(12)
        $t = Get-LauncherAwareTimeoutSec -DefaultTimeoutSec 30
        ($t -le 13) | Should Be $true
        ($t -ge 11) | Should Be $true
    }

    It 'floors at -MinimumTimeoutSec rather than returning zero/negative once the budget is already spent' {
        $script:LauncherDeadline = (Get-Date).AddSeconds(-5)
        (Get-LauncherAwareTimeoutSec -DefaultTimeoutSec 30 -MinimumTimeoutSec 5) | Should Be 5
    }

    It 'a second addon''s call after the first ate most of the budget gets a visibly smaller timeout than the first' {
        # Mirrors the real per-addon loop: arm the deadline once (Main does
        # this from $script:MainStartTime + LauncherBudgetSeconds), then
        # simulate addon 1's call consuming ~28s of the 40s budget before
        # addon 2's call asks for its own timeout.
        $script:LauncherDeadline = (Get-Date).AddSeconds(40)
        $firstCallTimeout = Get-LauncherAwareTimeoutSec -DefaultTimeoutSec 30
        $script:LauncherDeadline = (Get-Date).AddSeconds(40 - 28)
        $secondCallTimeout = Get-LauncherAwareTimeoutSec -DefaultTimeoutSec 30

        $firstCallTimeout | Should Be 30
        ($secondCallTimeout -lt $firstCallTimeout) | Should Be $true
        ($secondCallTimeout -le 12) | Should Be $true
    }
}

Describe 'Save-LauncherUpdatesCheckedAt (Round 26 hardening, item 4)' {
    <#
      Loose-end (4): the skip-if-recently-checked rule (above) reads
      state.json's updatesCheckedAt, but for the rule to actually trigger on
      a real SECOND -Launcher invocation with no tray/server involved,
      -Launcher itself must be the one writing it after a completed check -
      confirmed present in Main (the call site right after Save-Config,
      "P1 perf pass follow-up" - grep addon-sync.ps1 for
      "Save-LauncherUpdatesCheckedAt" to see it wired in). These are direct
      unit tests of the write function itself; the real end-to-end proof
      (two actual -Launcher child processes, second one skipping because of
      the first one's own write, zero manually-seeded state) is
      tests\integration\Cli.InstallRollbackLauncher.Tests.ps1's
      "-Launcher's own second launch skips because ITS OWN first launch
      wrote updatesCheckedAt" Describe.
    #>

    It 'creates state.json from scratch and stamps the given flavour when no file exists yet' {
        $root = New-TempRoot -Name 'launcher-checkedat-missing'
        $statePath = Join-Path $root 'state.json'
        (Test-Path -LiteralPath $statePath) | Should Be $false

        Save-LauncherUpdatesCheckedAt -RootPath $root -Flavor 'retail'

        (Test-Path -LiteralPath $statePath) | Should Be $true
        $obj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        ([string]::IsNullOrWhiteSpace($obj.updatesCheckedAt.retail)) | Should Be $false
        $minutesAgo = Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail'
        ($null -eq $minutesAgo) | Should Be $false
        ($minutesAgo -lt 1) | Should Be $true
    }

    It 'merges into an existing state.json, preserving fields it does not own (jobs/lastRun/other flavours)' {
        $root = New-TempRoot -Name 'launcher-checkedat-merge'
        $statePath = Join-Path $root 'state.json'
        $existing = @{
            jobs = @(@{ id = 1; state = 'done' })
            lastRun = @{ summary = 'ok' }
            updatesCheckedAt = @{ classic_era = '2020-01-01T00:00:00Z' }
        }
        (ConvertTo-Json -InputObject $existing -Depth 6) | Set-Content -LiteralPath $statePath -Encoding UTF8

        Save-LauncherUpdatesCheckedAt -RootPath $root -Flavor 'retail'

        $obj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $obj.jobs.Count | Should Be 1
        $obj.jobs[0].state | Should Be 'done'
        $obj.lastRun.summary | Should Be 'ok'
        $obj.updatesCheckedAt.classic_era | Should Be '2020-01-01T00:00:00Z'
        ([string]::IsNullOrWhiteSpace($obj.updatesCheckedAt.retail)) | Should Be $false
    }

    It 'upgrades the pre-flavour flat-string shape to a per-flavour object, preserving the old value under retail' {
        $root = New-TempRoot -Name 'launcher-checkedat-upgrade'
        $statePath = Join-Path $root 'state.json'
        (ConvertTo-Json -InputObject @{ updatesCheckedAt = '2021-06-15T12:00:00Z' } -Depth 4) |
            Set-Content -LiteralPath $statePath -Encoding UTF8

        Save-LauncherUpdatesCheckedAt -RootPath $root -Flavor 'classic'

        $obj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $obj.updatesCheckedAt.retail | Should Be '2021-06-15T12:00:00Z'
        ([string]::IsNullOrWhiteSpace($obj.updatesCheckedAt.classic)) | Should Be $false
    }

    It 'a second call for a different flavour does not clobber the first flavour''s stamp' {
        $root = New-TempRoot -Name 'launcher-checkedat-two-flavours'
        Save-LauncherUpdatesCheckedAt -RootPath $root -Flavor 'retail'
        Start-Sleep -Milliseconds 50
        Save-LauncherUpdatesCheckedAt -RootPath $root -Flavor 'classic_era'

        $retailMinutesAgo = Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'retail'
        $ceMinutesAgo = Get-StateUpdatesCheckedAtMinutesAgo -RootPath $root -Flavor 'classic_era'
        ($null -eq $retailMinutesAgo) | Should Be $false
        ($null -eq $ceMinutesAgo) | Should Be $false
        ($retailMinutesAgo -lt 1) | Should Be $true
        ($ceMinutesAgo -lt 1) | Should Be $true
    }

    It 'never throws when RootPath does not exist (best-effort, logged not thrown)' {
        $bogusRoot = Join-Path (New-TempRoot -Name 'launcher-checkedat-badroot') 'does\not\exist'
        { Save-LauncherUpdatesCheckedAt -RootPath $bogusRoot -Flavor 'retail' } | Should Not Throw
    }
}
