<#
  Unit tests (Pester 3 syntax): F2 (launch-round follow-up) - the new
  test-only base-URL override surface for Save-CfCatalogueIndex's two
  raw.githubusercontent.com fetches ($Script:CfCatalogueBaseUrl /
  $env:FURPHY_TEST_CF_CATALOGUE_BASEURL), mirroring
  tests\unit\Server.WagoBaseUrl.Tests.ps1's own five cases for the
  identical $Script:WagoBaseUrl/FURPHY_TEST_WAGO_BASEURL seam shape.

  $Script:CfCatalogueBaseUrl is declared UNCONDITIONALLY near the very
  top of addon-server.ps1 (above the "safe to define unconditionally"
  dot-source guard, same section as $Script:WagoBaseUrl) specifically so
  this test can dot-source the file and read it back without ever
  reaching the real "start the listener" startup body.

  The second Describe below goes one step further than a plain variable
  check: it points the seam at a REAL local stub
  (tests\lib\common.ps1's Start-CfCatalogueStubServer) and calls
  Save-CfCatalogueIndex directly, proving the seam actually reaches the
  real fetch call sites end-to-end - not just that the variable itself
  gets set. Never makes a real HTTP call to the internet.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:AddonServerPath = Join-Path $Script:FurphyBuildRoot 'addon-server.ps1'

function Import-AddonServerForCfCatalogueBaseUrlTest {
    <# Re-dot-sources addon-server.ps1 so the top-of-script env-var read runs again against whatever $env:FURPHY_TEST_CF_CATALOGUE_BASEURL is set to right now. The dot-source guard means this returns immediately after defining functions/constants - no listener, no disk/network startup work. #>
    . $Script:AddonServerPath
}

Describe 'addon-server.ps1 base-URL override (FURPHY_TEST_CF_CATALOGUE_BASEURL)' {

    AfterEach {
        Remove-Item Env:\FURPHY_TEST_CF_CATALOGUE_BASEURL -ErrorAction SilentlyContinue
    }

    It 'defaults to the real GitHub raw host when the variable is not set' {
        Remove-Item Env:\FURPHY_TEST_CF_CATALOGUE_BASEURL -ErrorAction SilentlyContinue
        Import-AddonServerForCfCatalogueBaseUrlTest

        $Script:CfCatalogueBaseUrl | Should Be 'https://raw.githubusercontent.com'
    }

    It 'a non-empty FURPHY_TEST_CF_CATALOGUE_BASEURL replaces $Script:CfCatalogueBaseUrl, trailing slash trimmed' {
        $env:FURPHY_TEST_CF_CATALOGUE_BASEURL = 'http://127.0.0.1:47960/'
        Import-AddonServerForCfCatalogueBaseUrlTest

        $Script:CfCatalogueBaseUrl | Should Be 'http://127.0.0.1:47960'
    }

    It 'a value with no trailing slash is used as-is' {
        $env:FURPHY_TEST_CF_CATALOGUE_BASEURL = 'http://127.0.0.1:47961'
        Import-AddonServerForCfCatalogueBaseUrlTest

        $Script:CfCatalogueBaseUrl | Should Be 'http://127.0.0.1:47961'
    }

    It 'an EMPTY string is ignored - falls back to the real host' {
        $env:FURPHY_TEST_CF_CATALOGUE_BASEURL = ''
        Import-AddonServerForCfCatalogueBaseUrlTest

        $Script:CfCatalogueBaseUrl | Should Be 'https://raw.githubusercontent.com'
    }

    It 'a WHITESPACE-ONLY value is ignored - falls back to the real host' {
        $env:FURPHY_TEST_CF_CATALOGUE_BASEURL = '   '
        Import-AddonServerForCfCatalogueBaseUrlTest

        $Script:CfCatalogueBaseUrl | Should Be 'https://raw.githubusercontent.com'
    }
}

Describe 'Save-CfCatalogueIndex - the seam actually reaches both real fetch call sites' {
    <#
      Before F2, Save-CfCatalogueIndex's two Invoke-WebRequest calls used
      literal 'https://raw.githubusercontent.com/...' URIs with no
      override at all - the only way to make this deterministic/
      internet-independent was shots\launch\Start-ScratchServer.ps1's own
      trick of shadowing the Invoke-WebRequest FUNCTION, which (per that
      script's own updated header comment) never worked at all once the
      real fetch moved into a separately-spawned -MaintenanceOnly child
      process (env vars propagate to a spawned child; shadowed function
      definitions do not). A real local stub server plus this base-URL
      seam works in both places.
    #>

    It 'fetches both instawow-data and strongbox-catalogue from the stub, merges them (instawow-data wins on id collision), and writes cache\cf-catalogue.json' {
        # Dot-sourced DIRECTLY here (not via the Import-...ForCfCatalogueBaseUrlTest
        # wrapper the first Describe above uses) - that wrapper is a
        # FUNCTION, and dot-sourcing INSIDE a function scopes every
        # `function ... {}` definition it brings in to that function's own
        # local scope, not this It block's - fine for the first Describe
        # (which only ever reads the $Script:-scoped variable back, and
        # $Script: explicitly bypasses normal scope nesting regardless of
        # where the assignment happened), but Save-CfCatalogueIndex itself
        # would not be callable afterward through that wrapper (confirmed
        # live: CommandNotFoundException).
        . $Script:AddonServerPath

        $stub = $null
        try {
            $stub = Start-CfCatalogueStubServer -InstawowEntries @(
                @{ id = '1'; name = 'InstawowOnly'; slug = 'instawow-only'; url = 'https://www.curseforge.com/wow/addons/instawow-only'; source = 'curse'; download_count = 100; last_updated = '2026-01-01T00:00:00Z' }
                @{ id = '2'; name = 'BothSourcesInstawowWins'; slug = 'both-instawow'; url = 'https://www.curseforge.com/wow/addons/both-instawow'; source = 'curse'; download_count = 500; last_updated = '2026-02-01T00:00:00Z' }
            ) -StrongboxEntries @(
                @{ source = 'curseforge'; 'source-id' = '2'; name = 'BothSourcesStrongboxLoses'; url = 'https://www.curseforge.com/wow/addons/both-strongbox'; 'download-count' = 999; 'updated-date' = '2020-01-01T00:00:00Z' }
                @{ source = 'curseforge'; 'source-id' = '3'; name = 'StrongboxOnly'; url = 'https://www.curseforge.com/wow/addons/strongbox-only'; 'download-count' = 50; 'updated-date' = '2022-01-01T00:00:00Z' }
            )
            # Set directly rather than re-dot-sourcing through the env var -
            # $Script:CfCatalogueBaseUrl is a plain variable at this point
            # (already dot-sourced above, in THIS scope), so there is no
            # need to round-trip through FURPHY_TEST_CF_CATALOGUE_BASEURL
            # again; the env-var-read half is already covered by the first
            # Describe above.
            $Script:CfCatalogueBaseUrl = $stub.BaseUrl

            $tempRoot = New-TempRoot -Name 'cf-catalogue-seam'
            $Script:CacheDir = Join-Path $tempRoot 'cache'
            $Script:CfCatalogueCachePath = Join-Path $Script:CacheDir 'cf-catalogue.json'
            # These normally get their first real value at real-server
            # startup (below the dot-source guard, so not present after a
            # plain dot-source) - initialized here so a stub failure's own
            # error-branch fallback (Script:CfCatalogueIndex.Count etc.)
            # has something sane to read rather than throwing a second,
            # more confusing error on top of the real one.
            $Script:CfCatalogueIndex = @()
            $Script:CfCatalogueById = @{}
            $Script:CfCatalogueFetchedAt = $null
            $Script:CfCatalogueSource = $null

            $result = Save-CfCatalogueIndex

            $result.ok | Should Be $true
            $result.source | Should Be 'instawow-data+strongbox'
            $result.count | Should Be 3

            $byId = @{}
            foreach ($e in $Script:CfCatalogueIndex) { $byId[$e.id] = $e }
            $byId.ContainsKey('1') | Should Be $true
            $byId['1'].name | Should Be 'InstawowOnly'
            # instawow-data wins on id collision - strongbox's entry for id 2 is discarded.
            $byId['2'].name | Should Be 'BothSourcesInstawowWins'
            $byId.ContainsKey('3') | Should Be $true
            $byId['3'].name | Should Be 'StrongboxOnly'

            (Test-Path -LiteralPath $Script:CfCatalogueCachePath) | Should Be $true
            $onDisk = Get-Content -LiteralPath $Script:CfCatalogueCachePath -Raw | ConvertFrom-Json
            $onDisk.entries.Count | Should Be 3
        } finally {
            Remove-Item Env:\FURPHY_TEST_CF_CATALOGUE_BASEURL -ErrorAction SilentlyContinue
            if ($stub) {
                Stop-StaticServer -Server $stub
                try { Remove-Item -LiteralPath $stub.Directory -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
}

Remove-TempRoots
