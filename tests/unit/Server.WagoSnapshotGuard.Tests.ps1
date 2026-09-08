<#
  Unit tests (Pester 3 syntax): WAGO-BROWSE-SPEC.md section 4.4's
  $Script:AcceptingRequests guard - turns "Initialize-WagoGrowthSnapshots
  must run before the request loop starts accepting connections" from a
  doc-comment-only invariant into something that fails loudly. A fast,
  direct proxy for "the call site didn't move" - the real call site
  ordering (Initialize-WagoGrowthSnapshots called before the request loop
  flips $Script:AcceptingRequests to $true) is exercised for real every
  time the server actually starts; this test exercises the GUARD ITSELF in
  isolation, entirely dot-sourced, no listener, no disk, no network.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

Describe 'Initialize-WagoGrowthSnapshots - $Script:AcceptingRequests guard' {

    It 'throws immediately if called while $Script:AcceptingRequests is already $true - never reaches any of its own crawl logic' {
        $Script:AcceptingRequests = $true

        { Initialize-WagoGrowthSnapshots } | Should Throw 'before the request loop starts accepting'
    }

    It 'the guard check happens before anything else - a refactor that moved the call site would be caught even with no flavours/cache dir set up at all' {
        $Script:AcceptingRequests = $true
        # Deliberately leave $Script:CacheDir/$Script:Root etc. completely
        # unset - if the guard fires FIRST (as required), the function
        # never reaches code that would need them and this still throws
        # cleanly rather than failing on a $null path or similar.
        $Script:CacheDir = $null
        $Script:Root = $null

        { Initialize-WagoGrowthSnapshots } | Should Throw
    }

    It 'does NOT throw when $Script:AcceptingRequests is $false (the correct, real startup ordering)' {
        $Script:AcceptingRequests = $false
        # Point every flavour/game-state dependency at a harmless, empty
        # fixture so the real crawl body can run to completion without
        # touching the network (Get-CurrentInstalledFlavours below finds
        # nothing installed under this fake root, so the flavour loop is
        # simply empty - zero Wago calls either way).
        $Script:WowRootOverride = (New-TempRoot -Name 'wago-guard-empty-root')
        $Script:Root = (New-TempRoot -Name 'wago-guard-approot')
        $Script:CacheDir = Join-Path $Script:Root 'cache'
        $Script:InstalledFlavoursAtStartup = @()

        { Initialize-WagoGrowthSnapshots } | Should Not Throw
    }
}
