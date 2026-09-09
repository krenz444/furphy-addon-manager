<#
  Unit tests (Pester 3 syntax): Initialize-WagoGrowthSnapshots' actual
  crawl mechanics (WAGO-BROWSE-SPEC.md sections 4.1-4.3) - the real
  page-fetch/de-dup/Save-WagoGrowthSnapshot/disk-round-trip pipeline, using
  a real single-flavour (retail-only) fixture WoW root
  (tests\lib\common.ps1's Copy-Fixture) and a shadowed Get-WagoCached (no
  network - same TESTING.md hook #1 pattern used throughout this suite).
  Get-WagoGrowthRanking's own math is covered exhaustively in
  Server.WagoGrowthRanking.Tests.ps1; this file is about the CRAWL and
  DISK round-trip around it.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

$Script:WagoCrawlFixturePath = Join-Path $Script:FurphyBuildRoot 'tests\fixtures\wago\browse_retail_props.json'
$Script:WagoCrawlFixtureProps = (Get-Content -LiteralPath $Script:WagoCrawlFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json).props

function New-RetailOnlyWowRoot {
    <# A throwaway fixture WoW root with ONLY _retail_ present (mirrors Server.Flavour.Tests.ps1's own pattern). #>
    $root = Copy-Fixture
    Remove-Item -LiteralPath (Join-Path $root '_classic_') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $root '_classic_era_') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $root '_ptr_') -Recurse -Force
    return $root
}

function Initialize-WagoCrawlTestState {
    <#
      Common per-test setup: a fresh retail-only WoW root and app root,
      $Script:AcceptingRequests $false, game not running.

      $Script:WowFakeProcessNameOverride is set to a deliberately
      nonexistent process name here (NOT $null) so "game not running" is
      true regardless of whatever is actually running on the dev/CI
      machine this test executes on - a bare $null leaves
      Test-GameRunning checking the REAL $Script:KnownWowProcessNames
      list, which a genuinely running Wow.exe (a dev's own game session)
      would match, silently skipping the crawl and starving
      $Script:WagoCachedCallCount - exactly the false failure confirmed
      in the Round 36 verifier report. The one It that wants "game IS
      running" (below) overrides this again right after calling this
      function, so it is unaffected.
    #>
    $Script:WowRootOverride = New-RetailOnlyWowRoot
    $Script:Root = New-TempRoot -Name 'wago-crawl'
    $Script:CacheDir = Join-Path $Script:Root 'cache'
    $Script:AcceptingRequests = $false
    Set-CurrentFlavourContext -Flavor 'retail'
    $Script:InstalledFlavoursAtStartup = Get-CurrentInstalledFlavours
    $Script:WowFakeProcessNameOverride = 'WowFakeNotRunningSnapshotCrawl' + (Get-Random -Maximum 99999)
    $Script:GameRunningCache = $false
    $Script:GameRunningCacheAt = [DateTime]::MinValue
    $Script:WagoCachedCallCount = 0
    $Script:WagoCachedUris = New-Object 'System.Collections.Generic.List[string]'
}

Describe 'Initialize-WagoGrowthSnapshots - crawl, de-dup, and disk round-trip' {

    It 'captures items across pages, de-dupes by slug (keep first occurrence), writes the snapshot file, and restores $Script:CurrentFlavour afterward' {
        Initialize-WagoCrawlTestState

        function Get-WagoCached {
            param([Parameter(Mandatory = $true)][string]$PageUri, [switch]$AllowLiveFetch = $true)
            $Script:WagoCachedCallCount++
            $Script:WagoCachedUris.Add($PageUri)
            # Serve the SAME 14-slug fixture page twice (page 1 and page 2)
            # - a real crawl would never see identical pages, but this is
            # exactly the shape that proves de-dup is working: without it,
            # the saved snapshot would have 28 items, not 14.
            $clone = $Script:WagoCrawlFixtureProps | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            if ($PageUri -match 'page=1(&|$)') {
                $clone.addons.current_page = 1
                $clone.addons.last_page = 2
            } else {
                $clone.addons.current_page = 2
                $clone.addons.last_page = 2
            }
            return $clone
        }

        Initialize-WagoGrowthSnapshots

        $Script:WagoCachedCallCount | Should Be 2
        $Script:CurrentFlavour | Should Be 'retail'

        $snapPath = Get-WagoGrowthSnapshotPath -GameVersion 'retail'
        (Test-Path -LiteralPath $snapPath) | Should Be $true

        $onDisk = Read-WagoGrowthSnapshotFile -Path $snapPath
        $onDisk.gameVersion | Should Be 'retail'
        $onDisk.snapshots.Count | Should Be 1
        # De-duped down to 14 (the real fixture's card count) - NOT 28,
        # proving the crawl's slug de-dup actually ran.
        $onDisk.snapshots[0].items.Count | Should Be 14
        $first = $onDisk.snapshots[0].items[0]
        $first.slug | Should Be 'details-damage-meter-standalone'
        $first.downloads | Should Be 7581560
        $first.rank | Should Be 1
    }

    It 'the 20-hour freshness gate skips a game_version whose last snapshot is under 20h old - zero live calls, file untouched' {
        Initialize-WagoCrawlTestState

        # Pre-seed a snapshot file with a single, recent (2h old) entry.
        $recentCapturedAt = (Get-Date).ToUniversalTime().AddHours(-2)
        New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
        Save-WagoGrowthSnapshot -GameVersion 'retail' -Items @([PSCustomObject]@{ slug = 'preexisting'; name = 'Preexisting'; thumbnail = $null; downloads = 42; rank = 1 }) -CapturedAtUtc $recentCapturedAt
        $beforeContent = Get-Content -LiteralPath (Get-WagoGrowthSnapshotPath -GameVersion 'retail') -Raw

        function Get-WagoCached {
            param([Parameter(Mandatory = $true)][string]$PageUri, [switch]$AllowLiveFetch = $true)
            $Script:WagoCachedCallCount++
            throw 'Get-WagoCached must not be called - the 20h freshness gate should have skipped this game_version entirely'
        }

        { Initialize-WagoGrowthSnapshots } | Should Not Throw
        $Script:WagoCachedCallCount | Should Be 0

        $afterContent = Get-Content -LiteralPath (Get-WagoGrowthSnapshotPath -GameVersion 'retail') -Raw
        $afterContent | Should Be $beforeContent
    }

    It 'the crawl proceeds normally while GameRunning is true - live calls happen, snapshot file is written (no game-state gate any more)' {
        <#
          GAME-MODE-SPEC.md (2026-09-08), section 8: INVERTED from
          "Test-GameRunning at the very top skips the entire crawl - zero
          live calls, no file written". Initialize-WagoGrowthSnapshots'
          own game-running gate (and the per-flavour/per-page TOCTOU abort
          that used to re-check it mid-crawl) is gone - Wago's daily
          growth crawl now runs on its normal per-game_version 20h
          freshness cadence (the OTHER, UNCHANGED It just above this one)
          regardless of WoW's process state, same as everything else this
          round.
        #>
        Initialize-WagoCrawlTestState
        $Script:WowFakeProcessNameOverride = (Get-Process -Id $PID).ProcessName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue

        function Get-WagoCached {
            param([Parameter(Mandatory = $true)][string]$PageUri, [switch]$AllowLiveFetch = $true)
            $Script:WagoCachedCallCount++
            $clone = $Script:WagoCrawlFixtureProps | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $clone.addons.current_page = 1
            $clone.addons.last_page = 1
            return $clone
        }

        { Initialize-WagoGrowthSnapshots } | Should Not Throw
        $Script:WagoCachedCallCount | Should BeGreaterThan 0

        $snapPath = Get-WagoGrowthSnapshotPath -GameVersion 'retail'
        (Test-Path -LiteralPath $snapPath) | Should Be $true
        $onDisk = Read-WagoGrowthSnapshotFile -Path $snapPath
        $onDisk.gameVersion | Should Be 'retail'
        $onDisk.snapshots[0].items.Count | Should Be 14
    }

    It 'PARTIAL rule: a page-fetch failure mid-crawl still saves whatever was already captured (never discards a partial success)' {
        Initialize-WagoCrawlTestState

        function Get-WagoCached {
            param([Parameter(Mandatory = $true)][string]$PageUri, [switch]$AllowLiveFetch = $true)
            $Script:WagoCachedCallCount++
            if ($PageUri -match 'page=1(&|$)') {
                $clone = $Script:WagoCrawlFixtureProps | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $clone.addons.current_page = 1
                $clone.addons.last_page = 5   # claims more pages exist
                return $clone
            }
            throw 'simulated network failure on page 2'
        }

        { Initialize-WagoGrowthSnapshots } | Should Not Throw
        $Script:WagoCachedCallCount | Should Be 2   # attempted page 1 (succeeded) and page 2 (failed) - stopped there

        $onDisk = Read-WagoGrowthSnapshotFile -Path (Get-WagoGrowthSnapshotPath -GameVersion 'retail')
        $onDisk | Should Not Be $null
        $onDisk.snapshots[0].items.Count | Should Be 14   # page 1's 14 items were kept despite page 2 failing
    }

    It 'zero pages succeeding writes NOTHING - never persists an empty-items snapshot' {
        Initialize-WagoCrawlTestState

        function Get-WagoCached {
            param([Parameter(Mandatory = $true)][string]$PageUri, [switch]$AllowLiveFetch = $true)
            $Script:WagoCachedCallCount++
            throw 'simulated network failure on the very first page'
        }

        { Initialize-WagoGrowthSnapshots } | Should Not Throw
        (Test-Path -LiteralPath (Get-WagoGrowthSnapshotPath -GameVersion 'retail')) | Should Be $false
    }
}
