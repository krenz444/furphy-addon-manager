<#
=====================================================================
 tests\integration\Server.CfEnrich.Tests.ps1

 GET /api/cf/enrich/{projectId}'s keyless Wago-auto-match fallback
 (Get-CfEnrichmentNoKey -> Get-WagoAutoMatch), specifically
 multi-client:wago-automatch-hardcoded-retail-game-version: a CurseForge-
 tracked record under a NON-Retail flavour, with no toc-derived wagoId,
 must probe Wago's search under THAT flavour's own game_version (via
 Get-CfFlavourMapping), never a hardcoded 'retail'.

 Run standalone:
     Invoke-Pester -Script tests\integration\Server.CfEnrich.Tests.ps1 -PassThru
 47899 must be free first.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\fixtures\wago-stub\WagoStubHelpers.ps1')

function Wait-ForWagoStubRequest {
    <#
      Polls -Condition (a scriptblock returning the current matching-request
      count against $stub) until it reaches -ExpectedCount or -TimeoutSec
      elapses. Mirrors Server.WagoBrowse.Tests.ps1's own Wait-
      ForWagoCrawlPages, mostly as defense in depth: Handle-CfEnrich's own
      HTTP response only returns after Get-WagoAutoMatch's own call to the
      stub has already completed, so in practice the matching request is
      already present the instant the enrich API call returns - but this
      still costs nothing to poll for explicitly, and protects this test
      against a future change that makes any part of that chain
      asynchronous, the same way Server.WagoBrowse.Tests.ps1's Round-37
      maintenance-child crawl already needed exactly this pattern for a
      genuinely async case.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$ExpectedCount = 1,
        [int]$TimeoutSec = 20,
        [int]$PollMs = 200
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $count = 0
    while ((Get-Date) -lt $deadline) {
        $count = & $Condition
        if ($count -ge $ExpectedCount) { return $count }
        Start-Sleep -Milliseconds $PollMs
    }
    return (& $Condition)
}

function New-BareAddonRecord {
    <#
      A minimal-but-complete tracked record (every field New-AddonRecord
      sets, mirroring Server.FreshnessAndFlavours.Tests.ps1's own
      hand-crafted-record pattern) for a flavour whose addons.json Get-
      CfEnrichmentNoKey/Get-AddonRecords will read directly - no live
      CurseForge -Add call needed. wagoId is deliberately $null so
      Get-CfEnrichmentNoKey's step 1 falls through to the
      Get-WagoAutoMatch probe under test, rather than a toc-derived id.
    #>
    param([int]$ProjectId, [string]$Name, [string]$Author)
    return [PSCustomObject]@{
        name               = $Name
        projectId          = $ProjectId
        fileId             = 1
        version            = '1.0.0'
        fileName           = 'fake.zip'
        installedAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        folders            = @("Fake$ProjectId")
        author             = $Author
        ignoreUpdates      = $false
        pinnedFileId       = $null
        releaseType        = $null
        previousFileId     = $null
        previousVersion    = $null
        previousFileName   = $null
        requiredDeps       = @()
        optionalDeps       = @()
        source             = 'curseforge'
        wagoId             = $null
        slug               = $null
        curseId            = $null
        latestGameVersions = @()
        latestFileDate     = $null
    }
}

Describe 'GET /api/cf/enrich - Wago auto-match resolves game_version from the CURRENT flavour, not a hardcoded retail (multi-client:wago-automatch-hardcoded-retail-game-version)' {
    <#
      Before this round's fix, Get-WagoAutoMatch's search URI hardcoded
      game_version=retail unconditionally, even though the record it is
      probing for is already resolved from the CURRENT flavour's own
      addons.json - so a CurseForge-tracked addon legitimately listed on
      Wago under a Classic/Classic Era game_version (with no toc
      X-Wago-ID tag) could never be found under a non-Retail flavour.
      classic_era's own Get-CfFlavourMapping WagoField is the static
      value 'classic' (FLAVORS-SPEC.md S4.6) - chosen here over the
      rolling 'classic' flavour specifically so this test needs no
      .build.info manipulation at all.
    #>
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'cf-enrich-automatch'
    $stub = $null
    $server = $null
    try {
        $flavourDir = Join-Path $root 'flavours\classic_era'
        New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
        $record = New-BareAddonRecord -ProjectId 900000021 -Name 'StubMatchAddon' -Author 'StubAuthor'
        (ConvertTo-Json -InputObject @($record) -Depth 10) | Set-Content -LiteralPath (Join-Path $flavourDir 'addons.json') -Encoding UTF8

        # Only game_version=classic (classic_era's WagoField) is mapped -
        # if a regression reintroduces the hardcoded 'retail' literal, the
        # stub's own default (empty-retail.json, zero cards either way)
        # answers instead, so this test would still need to positively
        # assert the REQUEST's own game_version param below to actually
        # catch that regression, not just the fact that a response came
        # back at all.
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'classic'; page = '1'; search = 'StubMatchAddon'; file = 'empty-retail.json' }
        ) -DefaultFile 'empty-retail.json'

        $fakeProcName = 'WowFakeCfEnrichNotRunning' + (Get-Random -Maximum 99999)
        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try {
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeProcName)
        } finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'the outbound Wago auto-match search carries game_version=classic (classic_era''s own WagoField), never retail' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/cf/enrich/900000021?flavour=classic_era'
            $r.Ok | Should Be $true

            # Filtered on search=StubMatchAddon (not a bare total count):
            # this fixture has 4 installed flavours, so the background Wago
            # growth-snapshot crawl (a separate, unrelated mechanism this
            # test does not pre-seed/block against, unlike most Describes
            # in Server.WagoBrowse.Tests.ps1) independently hits this same
            # stub around the same time - a real, harmless detail of this
            # fixture, not something this assertion should be fragile to.
            # The auto-match search is the only request this stub ever sees
            # carrying &search=, so filtering on it isolates exactly the
            # mechanism under test.
            #
            # IMPORTANT: Get-WagoStubRequests's own `return ,@($resp)` (its
            # own doc comment explains why: without it, a caller doing
            # `$x = Get-WagoStubRequests ...` gets the array silently
            # unwrapped to a bare single object whenever there happens to
            # be exactly one request logged) has a real, confirmed-live
            # side effect on the OTHER end of that fix: piping its call
            # DIRECTLY into Where-Object (`Get-WagoStubRequests -Stub $stub
            # | Where-Object {...}`) delivers the WHOLE comma-wrapped array
            # as a single $_ to Where-Object's predicate in ONE invocation,
            # rather than one element at a time - PowerShell's member
            # access then auto-vectorizes ($_.query.search on an array
            # returns an array of each element's value) and `-eq` on that
            # array returns the FILTERED SUBSET rather than a boolean,
            # which is truthy whenever anything at all matches - so the
            # ENTIRE unsplit array silently passes the filter as a single
            # "item" instead of being split into its real per-request
            # members. Assigning to a plain variable FIRST, then piping
            # THAT variable, avoids this - matching how every existing
            # Get-WagoStubRequests caller in Server.WagoBrowse.Tests.ps1
            # already does it.
            $getMatchCount = {
                $all = Get-WagoStubRequests -Stub $stub
                $n = 0
                foreach ($x in $all) { if ($x.query.search -eq 'StubMatchAddon') { $n++ } }
                return $n
            }
            Wait-ForWagoStubRequest -Condition $getMatchCount -ExpectedCount 1 -TimeoutSec 20 | Out-Null

            $allReqs = Get-WagoStubRequests -Stub $stub
            $reqs = New-Object 'System.Collections.Generic.List[object]'
            foreach ($x in $allReqs) { if ($x.query.search -eq 'StubMatchAddon') { $reqs.Add($x) } }
            $reqs.Count | Should Be 1
            $reqs[0].query.game_version | Should Be 'classic'
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}
