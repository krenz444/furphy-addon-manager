<#
  Unit tests (Pester 3 syntax): Initialize-CfCatalogueIndex's own
  $Script:AcceptingRequests guard - a verbatim mirror of
  Initialize-WagoGrowthSnapshots' guard (see
  tests\unit\Server.WagoSnapshotGuard.Tests.ps1), added by the Round 36
  "server" fixer to close a defensive-programming asymmetry: both startup
  routines share the same "must run before the request loop starts
  accepting connections" requirement, but only Wago's had a guard that
  fails loudly instead of silently corrupting every catalogue-backed
  request for the rest of the process's life should a future refactor
  move the call site past that point. Entirely dot-sourced, no listener,
  no disk, no network.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

Describe 'Initialize-CfCatalogueIndex - $Script:AcceptingRequests guard' {

    It 'throws immediately if called while $Script:AcceptingRequests is already $true - never reaches any disk/network logic' {
        $Script:AcceptingRequests = $true

        { Initialize-CfCatalogueIndex } | Should Throw 'before the request loop starts accepting'
    }

    It 'the guard check happens before anything else - a refactor that moved the call site would be caught even with no cache dir/root set up at all' {
        $Script:AcceptingRequests = $true
        # Deliberately leave $Script:CacheDir/$Script:Root/$Script:CfCatalogueCachePath
        # completely unset - if the guard fires FIRST (as required), the
        # function never reaches code that would need them and this still
        # throws cleanly rather than failing on a $null path or similar.
        $Script:CacheDir = $null
        $Script:Root = $null
        $Script:CfCatalogueCachePath = $null

        { Initialize-CfCatalogueIndex } | Should Throw
    }

    It 'does NOT throw when $Script:AcceptingRequests is $false and the on-disk cache is already fresh (<24h) - the real, non-network happy path' {
        $Script:AcceptingRequests = $false
        $Script:SkipCfCatalogueFetch = $false

        $root = New-TempRoot -Name 'cf-guard-fresh-cache'
        $cacheDir = Join-Path $root 'cache'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $cachePath = Join-Path $cacheDir 'cf-catalogue.json'

        $fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $body = [PSCustomObject]@{
            fetchedAt = $fetchedAt
            source    = 'instawow-data'
            entries   = @(
                [PSCustomObject]@{ id = '1'; name = 'Test Addon'; slug = 'test-addon'; url = 'https://www.curseforge.com/wow/addons/test-addon'; downloadCount = 1; lastUpdated = $fetchedAt }
            )
        }
        ($body | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cachePath -Encoding UTF8

        $Script:Root = $root
        $Script:CacheDir = $cacheDir
        $Script:CfCatalogueCachePath = $cachePath

        { Initialize-CfCatalogueIndex } | Should Not Throw

        $Script:CfCatalogueIndex.Count | Should Be 1
    }

    It 'does NOT throw when $Script:AcceptingRequests is $false, the cache is stale/missing, and FURPHY_TEST_SKIP_CF_CATALOGUE is set - no live fetch attempted' {
        $Script:AcceptingRequests = $false
        $Script:SkipCfCatalogueFetch = $true

        $root = New-TempRoot -Name 'cf-guard-skip-fetch'
        $cacheDir = Join-Path $root 'cache'
        $cachePath = Join-Path $cacheDir 'cf-catalogue.json'

        $Script:Root = $root
        $Script:CacheDir = $cacheDir
        $Script:CfCatalogueCachePath = $cachePath

        { Initialize-CfCatalogueIndex } | Should Not Throw

        # No cache file existed (missing => stale), so a real (non-test)
        # run would have called Save-CfCatalogueIndex and made two live
        # HTTPS GETs. Confirm nothing was written to disk, proving the
        # live-fetch branch never ran.
        (Test-Path -LiteralPath $cachePath) | Should Be $false
    }

    It 'GAME-MODE-SPEC.md (2026-09-08): still refreshes from a stale/missing cache while GameRunning is true - no game-state gate any more (new coverage, section 8 item 3)' {
        <#
          New coverage - Initialize-CfCatalogueIndex never had a
          Test-GameRunning test either way before this round (confirmed:
          it never gated the live fetch itself, so there was nothing to
          invert; the OLD gate this closes was `if ($stale -and
          (Test-GameRunning)) { ...skip... }`, removed per GAME-MODE-
          SPEC.md section 2). Uses the same real local stub
          (Start-CfCatalogueStubServer, tests\lib\common.ps1) the sibling
          Server.CfCatalogueBaseUrl.Tests.ps1 file already uses for
          Save-CfCatalogueIndex directly - never real GitHub.
        #>
        $Script:AcceptingRequests = $false
        $Script:SkipCfCatalogueFetch = $false
        $Script:WowFakeProcessNameOverride = (Get-Process -Id $PID).ProcessName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue

        $root = New-TempRoot -Name 'cf-guard-gamerunning-refresh'
        $cacheDir = Join-Path $root 'cache'
        $cachePath = Join-Path $cacheDir 'cf-catalogue.json'
        $Script:Root = $root
        $Script:CacheDir = $cacheDir
        $Script:CfCatalogueCachePath = $cachePath
        $Script:CfCatalogueIndex = @()
        $Script:CfCatalogueById = @{}
        $Script:CfCatalogueFetchedAt = $null
        $Script:CfCatalogueSource = $null

        $stub = $null
        try {
            $stub = Start-CfCatalogueStubServer -InstawowEntries @(
                @{ id = '1'; name = 'GameRunningRefresh'; slug = 'game-running-refresh'; url = 'https://www.curseforge.com/wow/addons/game-running-refresh'; source = 'curse'; download_count = 10; last_updated = '2026-01-01T00:00:00Z' }
            ) -StrongboxEntries @()
            $Script:CfCatalogueBaseUrl = $stub.BaseUrl

            { Initialize-CfCatalogueIndex } | Should Not Throw

            $Script:CfCatalogueIndex.Count | Should Be 1
            (Test-Path -LiteralPath $cachePath) | Should Be $true
        } finally {
            Remove-Item Env:\FURPHY_TEST_CF_CATALOGUE_BASEURL -ErrorAction SilentlyContinue
            if ($stub) {
                Stop-StaticServer -Server $stub
                try { Remove-Item -LiteralPath $stub.Directory -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
}
