<#
  Unit tests (Pester 3 syntax): WAGO-BROWSE-SPEC.md's parser widening -
  ConvertFrom-WagoSearchCardHtml's four new fields (author/summary/
  downloads/updatedAt), Sort-WagoItemsByUpdated (the "Recently updated"
  tab's page-local re-sort), and a dot-sourced smoke test of
  Handle-WagoBrowse itself against tests\fixtures\wago\browse_retail_props
  .json - a real, live-captured Wago listing page (2026-09-06, retail,
  unfiltered) copied in by WAGO-BROWSE-RESEARCH.md's research pass. No
  network, no disk writes: Get-WagoCached is shadowed (redefined) after
  dot-sourcing, same pattern tests\unit\Server.Handlers.Tests.ps1 already
  uses for Open-InBrowser/Start-Process, so Handle-WagoBrowse's own logic
  runs for real while everything past the HTTP boundary is a fixture.

  Expanded with test suites for pagination edge cases, client switching,
  game version resolution, filter echo handling, and defensive HTML parsing.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

$Script:WagoFixturePath = Join-Path $Script:FurphyBuildRoot 'tests\fixtures\wago\browse_retail_props.json'
$Script:WagoFixtureRaw = Get-Content -LiteralPath $Script:WagoFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
$Script:WagoFixtureProps = $Script:WagoFixtureRaw.props
$Script:WagoFixtureFirstCardHtml = [string]$Script:WagoFixtureProps.addons.data[0]

# ---------------------------------------------------------------------
# ConvertFrom-WagoSearchCardHtml
# ---------------------------------------------------------------------

Describe 'ConvertFrom-WagoSearchCardHtml' {

    It 'parses every field from a real, live-captured card ("Details! Damage Meter")' {
        $card = ConvertFrom-WagoSearchCardHtml -Html $Script:WagoFixtureFirstCardHtml
        $card | Should Not Be $null
        $card.slug | Should Be 'details-damage-meter-standalone'
        $card.name | Should Be 'Details! Damage Meter'
        $card.thumbnail | Should Be 'https://cdn.wago.io/thumbnails/vaG3R9SlPb9XIVqDg6k2IfWGpKyBUPjnFKGf9A9V.png'
        $card.author | Should Be 'Terciob'
        $card.updatedAt | Should Be 'Aug 18, 2026'
        $card.downloads | Should Be 7581560
        $card.downloads.GetType().Name | Should Be 'Int32'
        $card.summary | Should Be 'Famous Combat Analizys addon, compute all sorts of information related to combat, now in a standalone version (without plugins).'
    }

    It 'a card missing the Updated/Downloads/Author block leaves those three $null, the rest intact, and never throws (built by stripping that ONE block from the real fixture card)' {
        $withoutMetaBlock = $Script:WagoFixtureFirstCardHtml -replace '(?s)<div class="flex items-center flex-wrap md:flex-nowrap">.*?</div>', ''
        # Sanity: the strip actually removed something, or this test proves nothing.
        $withoutMetaBlock | Should Not Be $Script:WagoFixtureFirstCardHtml

        { ConvertFrom-WagoSearchCardHtml -Html $withoutMetaBlock } | Should Not Throw
        $card = ConvertFrom-WagoSearchCardHtml -Html $withoutMetaBlock
        $card | Should Not Be $null
        $card.slug | Should Be 'details-damage-meter-standalone'
        $card.name | Should Be 'Details! Damage Meter'
        $card.thumbnail | Should Be 'https://cdn.wago.io/thumbnails/vaG3R9SlPb9XIVqDg6k2IfWGpKyBUPjnFKGf9A9V.png'
        $card.summary | Should Be 'Famous Combat Analizys addon, compute all sorts of information related to combat, now in a standalone version (without plugins).'
        $card.author | Should Be $null
        $card.updatedAt | Should Be $null
        $card.downloads | Should Be $null
    }

    It 'comma-formatted downloads ("7,581,560") still parses to the integer 7581560 (defensive - none observed live as of this round)' {
        $html = '<a href="https://addons.wago.io/addons/comma-test" class="plain-link"><h3>Comma Test</h3><span class="text-sm"><strong>Downloads:</strong> 7,581,560</span></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card.downloads | Should Be 7581560
    }

    It 'HTML-entity name and author are decoded ("Tank &amp; Spank" -> "Tank & Spank")' {
        $html = '<a href="https://addons.wago.io/addons/tank-and-spank" class="plain-link"><h3>Tank &amp; Spank</h3><span><strong>Author:</strong> Foo &amp; Bar</span></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card.name | Should Be 'Tank & Spank'
        $card.author | Should Be 'Foo & Bar'
    }

    It 'the unquoted-thumbnail-src regression case (Wago emits src= with no quotes) stays passing' {
        $html = '<a href="https://addons.wago.io/addons/unquoted-thumb" class="plain-link"><img src=https://cdn.wago.io/thumbnails/abc123.png /><h3>Unquoted Thumb</h3></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card.thumbnail | Should Be 'https://cdn.wago.io/thumbnails/abc123.png'
    }

    It 'a fragment with no matching addon href returns $null, never throws' {
        { ConvertFrom-WagoSearchCardHtml -Html '<div>not a card</div>' } | Should Not Throw
        (ConvertFrom-WagoSearchCardHtml -Html '<div>not a card</div>') | Should Be $null
    }

    It 'an empty or $null Html argument returns $null, never throws' {
        (ConvertFrom-WagoSearchCardHtml -Html $null) | Should Be $null
        (ConvertFrom-WagoSearchCardHtml -Html '') | Should Be $null
    }
}

# ---------------------------------------------------------------------
# ConvertFrom-WagoSearchCardHtml: Defensive Edge Cases
# ---------------------------------------------------------------------

Describe 'ConvertFrom-WagoSearchCardHtml: Defensive Edge Cases' {

    It 'handles cards with whitespace, newlines, and tabs inside <p> summary' {
        $html = "<a href=""https://addons.wago.io/addons/whitespace-test"" class=""plain-link"">`n    <h3>Whitespace Addon</h3>`n    <p class=""summary-text"">`n        This is a multi-line`n        summary with   extra   spaces`n        and tabs.`n    </p>`n    <span><strong>Author:</strong>   Spaced Author   </span>`n    <span><strong>Downloads:</strong> 12,345 </span>`n</a>"
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card | Should Not Be $null
        $card.slug | Should Be 'whitespace-test'
        $card.name | Should Be 'Whitespace Addon'
        $card.author | Should Be 'Spaced Author'
        $card.downloads | Should Be 12345
        $card.summary | Should Match 'This is a multi-line'
    }

    It 'handles cards with HTML entities in summary (<p>)' {
        $html = '<a href="https://addons.wago.io/addons/entities-summary"><h3>Summary Entities</h3><p>Fast &amp; light &lt;combat&gt; meter &quot;pro&quot;</p></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card | Should Not Be $null
        $card.summary | Should Be 'Fast & light <combat> meter "pro"'
    }

    It 'parses downloads with spaces as thousand separators ("1 500 000")' {
        $html = '<a href="https://addons.wago.io/addons/space-downloads"><h3>Space Downloads</h3><span><strong>Downloads:</strong> 1 500 000</span></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card.downloads | Should Be 1500000
    }

    It 'parses downloads with periods as thousand separators ("2.345.678")' {
        $html = '<a href="https://addons.wago.io/addons/period-downloads"><h3>Period Downloads</h3><span><strong>Downloads:</strong> 2.345.678</span></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card.downloads | Should Be 2345678
    }

    It 'card missing <p> tag returns $null summary without throwing' {
        $html = '<a href="https://addons.wago.io/addons/no-p-tag"><h3>No Description</h3><span><strong>Author:</strong> Dev</span></a>'
        $card = ConvertFrom-WagoSearchCardHtml -Html $html
        $card | Should Not Be $null
        $card.summary | Should Be $null
        $card.author | Should Be 'Dev'
    }
}

# ---------------------------------------------------------------------
# Sort-WagoItemsByUpdated
# ---------------------------------------------------------------------

Describe 'Sort-WagoItemsByUpdated' {

    It 'sorts mixed valid dates descending (most recently updated first)' {
        $items = @(
            [PSCustomObject]@{ slug = 'a'; downloads = 100; updatedAt = 'Jan 1, 2026' }
            [PSCustomObject]@{ slug = 'b'; downloads = 100; updatedAt = 'Sep 5, 2026' }
            [PSCustomObject]@{ slug = 'c'; downloads = 100; updatedAt = 'Jun 15, 2026' }
        )
        $sorted = Sort-WagoItemsByUpdated -Items $items
        (($sorted | ForEach-Object { $_.slug }) -join ',') | Should Be 'b,c,a'
    }

    It 'an unparseable or missing updatedAt sorts LAST, never dropped or thrown on' {
        $items = @(
            [PSCustomObject]@{ slug = 'good'; downloads = 100; updatedAt = 'Sep 5, 2026' }
            [PSCustomObject]@{ slug = 'bad'; downloads = 999999; updatedAt = 'not-a-date' }
            [PSCustomObject]@{ slug = 'missing'; downloads = 999999; updatedAt = $null }
        )
        { Sort-WagoItemsByUpdated -Items $items } | Should Not Throw
        $sorted = Sort-WagoItemsByUpdated -Items $items
        $sorted.Count | Should Be 3
        $sorted[0].slug | Should Be 'good'
        # 'bad' and 'missing' both sort last (parsed as MinValue); tied on
        # downloads too, so slug ascending decides: 'bad' before 'missing'.
        $sorted[1].slug | Should Be 'bad'
        $sorted[2].slug | Should Be 'missing'
    }

    It 'an exact date tie is broken by downloads descending, then slug ascending - constructed so a naive stable/input-order-preserving sort would fail' {
        # Input is deliberately in the WRONG final order already.
        $items = @(
            [PSCustomObject]@{ slug = 'zzz'; downloads = 50; updatedAt = 'Sep 5, 2026' }
            [PSCustomObject]@{ slug = 'aaa'; downloads = 50; updatedAt = 'Sep 5, 2026' }
            [PSCustomObject]@{ slug = 'mmm'; downloads = 200; updatedAt = 'Sep 5, 2026' }
        )
        $sorted = Sort-WagoItemsByUpdated -Items $items
        (($sorted | ForEach-Object { $_.slug }) -join ',') | Should Be 'mmm,aaa,zzz'
    }

    It 'does not mutate the caller-supplied input array or its item order' {
        $items = @(
            [PSCustomObject]@{ slug = 'b'; downloads = 1; updatedAt = 'Jan 1, 2026' }
            [PSCustomObject]@{ slug = 'a'; downloads = 1; updatedAt = 'Sep 5, 2026' }
        )
        Sort-WagoItemsByUpdated -Items $items | Out-Null
        $items[0].slug | Should Be 'b'
        $items[1].slug | Should Be 'a'
    }
}

# ---------------------------------------------------------------------
# Handle-WagoBrowse (smoke, against the live-captured fixture, no network)
# ---------------------------------------------------------------------

function Get-WagoCached {
    <# Shadows the real Get-WagoCached (redefined AFTER dot-sourcing, per TESTING.md hook #1's own pattern) - never touches the network, records what it was asked for. #>
    param([Parameter(Mandatory = $true)][string]$PageUri, [switch]$AllowLiveFetch = $true)
    $Script:CapturedWagoUri = $PageUri
    $Script:CapturedAllowLiveFetch = [bool]$AllowLiveFetch
    if ($Script:MockWagoBehavior -eq 'null') { return $null }
    if ($Script:MockWagoCustomProps) { return $Script:MockWagoCustomProps }
    return $Script:WagoFixtureProps
}

Describe 'Handle-WagoBrowse (smoke, against tests\fixtures\wago\browse_retail_props.json)' {

    BeforeEach {
        $Script:MockWagoBehavior = 'fixture'
        $Script:MockWagoCustomProps = $null
        $Script:CapturedWagoUri = $null
        $Script:CapturedAllowLiveFetch = $null
        $Script:CurrentFlavour = 'retail'
        $Script:ClientBuildInfo = [PSCustomObject]@{ clientInterface = $null }
        $Script:WowFakeProcessNameOverride = $null
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue
    }

    It 'default (no sort=) resolves to popular, sends no sort= param, and every widened field is populated from the real fixture' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $body = Get-FakeResponseBody -Context $ctx

        $body.sortApplied | Should Be 'popular'
        $Script:CapturedWagoUri | Should Not Match 'sort='
        $body.items.Count | Should Be 14
        $first = $body.items[0]
        $first.slug | Should Be 'details-damage-meter-standalone'
        $first.name | Should Be 'Details! Damage Meter'
        $first.author | Should Be 'Terciob'
        $first.downloads | Should Be 7581560
        $first.updatedAt | Should Be 'Aug 18, 2026'

        # 29 real categories, server order verbatim - INCLUDING id 5
        # ("Buffs & Debuffs") genuinely sorting second-to-last (index 27),
        # out of numeric sequence, per WAGO-BROWSE-RESEARCH.md section 2/
        # the spec's own 2.2 - id 29 ("Transmog") is the real last entry.
        $body.categories.Count | Should Be 29
        $body.categories[0].id | Should Be 1
        $body.categories[0].displayName | Should Be 'Chat & Communication'
        $body.categories[27].id | Should Be 5
        $body.categories[27].displayName | Should Be 'Buffs & Debuffs'
        $body.categories[28].id | Should Be 29
        $body.categories[28].displayName | Should Be 'Transmog'
    }

    It 'sort=name forwards &sort=name to Wago verbatim' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?sort=name'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $body = Get-FakeResponseBody -Context $ctx
        $body.sortApplied | Should Be 'name'
        $Script:CapturedWagoUri | Should Match '(\?|&)sort=name(&|$)'
    }

    It 'sort=updated fetches the IDENTICAL URI as popular (no sort= sent) and re-sorts the returned page locally' {
        $ctxPopular = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctxPopular -RouteMatch @{}
        $popularUri = $Script:CapturedWagoUri

        $ctxUpdated = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?sort=updated'
        Handle-WagoBrowse -Context $ctxUpdated -RouteMatch @{}
        $updatedUri = $Script:CapturedWagoUri

        $updatedUri | Should Be $popularUri
        $body = Get-FakeResponseBody -Context $ctxUpdated
        $body.sortApplied | Should Be 'updated'
        $body.items.Count | Should Be 14
    }

    It 'an unrecognised/stale sort value ("rising", an old client build) is absorbed to popular - never forwarded upstream' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?sort=rising'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $body = Get-FakeResponseBody -Context $ctx
        $body.sortApplied | Should Be 'popular'
        $Script:CapturedWagoUri | Should Not Match 'sort='
    }

    It 'a numeric categoryId is forwarded as &category=<n>' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?categoryId=4'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $Script:CapturedWagoUri | Should Match '(\?|&)category=4(&|$)'
    }

    It 'a non-numeric categoryId is treated as absent - never forwarded' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?categoryId=abc'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $Script:CapturedWagoUri | Should Not Match 'category='
    }

    It 'while the game is running, still allows a live fetch (never gates on game state) - a null upstream response is just an empty result, no gameActive field' {
        $Script:MockWagoBehavior = 'null'
        $Script:WowFakeProcessNameOverride = (Get-Process -Id $PID).ProcessName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue

        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $body = Get-FakeResponseBody -Context $ctx
        ($body.PSObject.Properties.Name -contains 'gameActive') | Should Be $false
        $body.items.Count | Should Be 0
        $body.total | Should Be 0
        $body.categories.Count | Should Be 0
        $Script:CapturedAllowLiveFetch | Should Be $true
    }
}

# ---------------------------------------------------------------------
# Handle-WagoBrowse: Pagination Edge Cases
# ---------------------------------------------------------------------

Describe 'Handle-WagoBrowse: Pagination Edge Cases' {

    BeforeEach {
        $Script:MockWagoBehavior = 'fixture'
        $Script:MockWagoCustomProps = $null
        $Script:CapturedWagoUri = $null
        $Script:CapturedAllowLiveFetch = $null
        $Script:CurrentFlavour = 'retail'
        $Script:ClientBuildInfo = [PSCustomObject]@{ clientInterface = $null }
    }

    It 'forwards numeric page parameter verbatim when greater than 0 (page=2)' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?page=2'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:CapturedWagoUri | Should Match '(\?|&)page=2(&|$)'
    }

    It 'forwards larger page number (page=42) verbatim' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?page=42'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:CapturedWagoUri | Should Match '(\?|&)page=42(&|$)'
    }

    It 'clamps page=0, negative, and non-numeric page values to page=1' {
        foreach ($badPage in @('0', '-1', '-99', 'abc', '', 'NaN', '1.5')) {
            $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query "?page=$badPage"
            Handle-WagoBrowse -Context $ctx -RouteMatch @{}
            $ctx.Response.StatusCode | Should Be 200
            $Script:CapturedWagoUri | Should Match '(\?|&)page=1(&|$)'
            $Script:CapturedWagoUri | Should Not Match 'page=0'
            $Script:CapturedWagoUri | Should Not Match 'page=-'
        }
    }

    It 'correctly projects upstream pagination props (current_page, last_page, total) into response body' {
        $customProps = [PSCustomObject]@{
            addons = [PSCustomObject]@{
                current_page = 3
                last_page    = 7
                total        = 95
                data         = @($Script:WagoFixtureFirstCardHtml)
            }
            allCategories = $Script:WagoFixtureProps.allCategories
        }
        $Script:MockWagoCustomProps = $customProps

        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?page=3'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $body = Get-FakeResponseBody -Context $ctx
        $body.page | Should Be 3
        $body.lastPage | Should Be 7
        $body.total | Should Be 95
        $body.items.Count | Should Be 1
    }

    It 'tolerates an empty data array on a page beyond the end without errors' {
        $emptyProps = [PSCustomObject]@{
            addons = [PSCustomObject]@{
                current_page = 10
                last_page    = 4
                total        = 56
                data         = @()
            }
            allCategories = $Script:WagoFixtureProps.allCategories
        }
        $Script:MockWagoCustomProps = $emptyProps

        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse' -Query '?page=10'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $body = Get-FakeResponseBody -Context $ctx
        $body.page | Should Be 10
        $body.lastPage | Should Be 4
        $body.total | Should Be 56
        $body.items.Count | Should Be 0
    }
}

# ---------------------------------------------------------------------
# Handle-WagoBrowse: Client Switching & Game Version Resolution
# ---------------------------------------------------------------------

Describe 'Handle-WagoBrowse: Client Switching & Game Version Resolution' {

    BeforeEach {
        $Script:MockWagoBehavior = 'fixture'
        $Script:MockWagoCustomProps = $null
        $Script:CapturedWagoUri = $null
        $Script:CapturedAllowLiveFetch = $null
        $Script:ClientBuildInfo = [PSCustomObject]@{ clientInterface = $null }
    }

    It 'forwards game_version=retail when CurrentFlavour is retail' {
        $Script:CurrentFlavour = 'retail'
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:CapturedWagoUri | Should Match '(\?|&)game_version=retail(&|$)'
    }

    It 'forwards game_version=classic when CurrentFlavour is classic_era' {
        $Script:CurrentFlavour = 'classic_era'
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:CapturedWagoUri | Should Match '(\?|&)game_version=classic(&|$)'
    }

    It 'forwards game_version=classic when CurrentFlavour is classic with a Classic Era interface (11502)' {
        $Script:CurrentFlavour = 'classic'
        $Script:ClientBuildInfo = [PSCustomObject]@{ clientInterface = '11502' }
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:CapturedWagoUri | Should Match '(\?|&)game_version=classic(&|$)'
    }

    It 'returns 422 Unprocessable Entity when Classic version has unknown interface' {
        $Script:CurrentFlavour = 'classic'
        # An unrecognized interface version that resolves EraKey='unknown'
        $Script:ClientBuildInfo = [PSCustomObject]@{ clientInterface = '999999' }
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/wago/browse'
        Handle-WagoBrowse -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 422
        $body = Get-FakeResponseBody -Context $ctx
        $body.error | Should Match "Furphy doesn't recognize this Classic version yet"
    }
}
