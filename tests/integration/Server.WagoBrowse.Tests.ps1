<#
=====================================================================
 tests\integration\Server.WagoBrowse.Tests.ps1  (Builder C)

 Integration coverage for WAGO-BROWSE-SPEC.md's new GET /api/wago/browse
 endpoint (Handle-WagoBrowse, the SERVER-1..5 change set) - default
 listing/Popular, categories, categoryId filtering, the four-way sort,
 pagination, the 5-minute cache, the 300ms pacing, the game-running gate,
 the "Gaining this week" snapshot mechanism, the category+gaining
 permanent incompatibility, and CSRF (GET is exempt).

 CAPABILITY-GATED, ON PURPOSE: this file was started while NONE of
 SERVER-1..5 existed yet in addon-server.ps1 (only the pre-round
 Handle-WagoSearch/Handle-WagoCategories - no WagoBaseUrl seam, no
 Handle-WagoBrowse, no /api/wago/browse route, no Get-WagoCached
 -AllowLiveFetch, no Initialize-WagoGrowthSnapshots/Get-WagoGrowthRanking),
 and Builder A's change set landed mid-session. Every Describe below still
 probes addon-server.ps1's own SOURCE TEXT for the specific marker(s) its
 own assertions depend on (a plain grep, not a network call) and, when a
 requirement isn't met, prints a one-line PENDING skip and returns WITHOUT
 starting a server or stub - the same "prerequisite not built yet -> skip
 with a reason" shape tests\perf\Perf.Tests.ps1's own Ensure-PerfHostBuilt
 already uses elsewhere in this suite. Kept deliberately (not deleted now
 that the flags read true) so this file degrades gracefully again if a
 future edit ever reverts one of SERVER-1..5, and so a PENDING report is
 still exactly this precise if this file is ever copied to a REPO in an
 earlier state than the one it was finished against.

 Deliberately NOT included: a legacy-/api/wago/search-alias no-regression
 check (not in this builder's assigned test list; add it alongside a
 unit-level base-URL-override test if a future round wants one).

 Every Describe that DOES run starts its own throwaway stub
 (WagoStubHelpers.ps1's Start-WagoStubServer, this file's own fixture,
 tests\fixtures\wago-stub\) and its own real addon-server.ps1 child
 process (Start-TestServer), and tears both down in a finally block -
 same per-Describe lifecycle already used elsewhere in tests\integration
 (e.g. Server.FreshnessAndFlavours.Tests.ps1).

 Run standalone (this suite's builders never run tests\run-all.ps1):
     Invoke-Pester -Script tests\integration\Server.WagoBrowse.Tests.ps1 -PassThru
 47899 must be free first (this file's own tests never share a server
 across Describes, so nothing here holds the port between blocks).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\fixtures\wago-stub\WagoStubHelpers.ps1')

# ---------------------------------------------------------------------
# Capability probe (static source grep of the REAL addon-server.ps1
# under the build root - never a copy, never a network call). Each flag
# names exactly one SERVER-N change set from WAGO-BROWSE-SPEC.md section
# 6; every Describe below states which flag(s) it needs.
# ---------------------------------------------------------------------

$Script:ServerSourcePath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'addon-server.ps1'
$Script:ServerSourceText = Get-Content -LiteralPath $Script:ServerSourcePath -Raw

# SERVER-1: the $Script:WagoBaseUrl / FURPHY_TEST_WAGO_BASEURL test seam
# (section 3.7) - without this, nothing in addon-server.ps1 can ever be
# pointed at this file's stub instead of the real addons.wago.io.
$Script:CapSeam = [bool]($Script:ServerSourceText -match 'FURPHY_TEST_WAGO_BASEURL')

# SERVER-2: Handle-WagoBrowse defined AND /api/wago/browse registered as
# a route (section 3, section 6).
$Script:CapBrowseRoute = [bool](
    ($Script:ServerSourceText -match 'function\s+Handle-WagoBrowse\b') -and
    ($Script:ServerSourceText -match [regex]::Escape("Pattern = '^/api/wago/browse$'"))
)

# SERVER-3: the parser widened to Author:/Updated:/Downloads:/the <p>
# summary, plus Sort-WagoItemsByUpdated (section 3.3).
$Script:CapParserWidened = [bool](
    ($Script:ServerSourceText -match [regex]::Escape('<strong>Author:</strong>')) -and
    ($Script:ServerSourceText -match 'function\s+Sort-WagoItemsByUpdated\b')
)

# SERVER-4: Get-WagoCached -AllowLiveFetch + the game-mode gate inside
# Handle-WagoBrowse (section 3.5).
$Script:CapAllowLiveFetch = [bool]($Script:ServerSourceText -match 'AllowLiveFetch')

# SERVER-5: the snapshot crawl + growth-ranking pure function (section 4).
$Script:CapGrowthSnapshots = [bool](
    ($Script:ServerSourceText -match 'function\s+Initialize-WagoGrowthSnapshots\b') -and
    ($Script:ServerSourceText -match 'function\s+Get-WagoGrowthRanking\b')
)

# The floor every single Describe below needs just to reach
# Handle-WagoBrowse through the stub at all.
$Script:CapCore = $Script:CapSeam -and $Script:CapBrowseRoute

Write-Host ''
Write-Host 'Wago browse capability probe (static source grep, no network):' -ForegroundColor Cyan
Write-Host "  SERVER-1 WagoBaseUrl seam ............ $Script:CapSeam"
Write-Host "  SERVER-2 Handle-WagoBrowse route ...... $Script:CapBrowseRoute"
Write-Host "  SERVER-3 parser widened ............... $Script:CapParserWidened"
Write-Host "  SERVER-4 -AllowLiveFetch gate .......... $Script:CapAllowLiveFetch"
Write-Host "  SERVER-5 growth snapshots .............. $Script:CapGrowthSnapshots"
Write-Host ''

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function New-FakeWowProcess {
    <#
      Mirrors tests\perf\Perf.Tests.ps1's own fake-WoW recipe exactly: a
      renamed copy of timeout.exe, started hidden with NO stdin
      redirection (redirecting stdin makes timeout.exe exit almost
      immediately - a confirmed gotcha from that file's own P0 baseline
      round), named per Test-GameRunning's -WowFakeProcessName test hook.
      Returns {Process; ProcessName}.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $fakeProcName = 'WowFakeWagoBrowse' + (Get-Random -Maximum 99999)
    $fakeExePath = Join-Path $Root ($fakeProcName + '.exe')
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
    $proc = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '900', '/nobreak') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    return [PSCustomObject]@{ Process = $proc; ProcessName = $fakeProcName }
}

function Stop-FakeWowProcess {
    param($FakeWow)
    if (-not $FakeWow -or -not $FakeWow.Process) { return }
    try { if (-not $FakeWow.Process.HasExited) { Stop-Process -Id $FakeWow.Process.Id -Force -ErrorAction SilentlyContinue } } catch { }
}

function Get-NotRunningFakeWowName {
    <#
      Every Describe below that wants "the game is NOT running" (i.e.
      every one that expects Handle-WagoBrowse to actually reach the
      stub, not the gameActive:true empty-items gate) must still pass
      -WowFakeProcessName to its Start-TestServer child process - without
      it, Test-GameRunning falls back to the REAL
      $Script:KnownWowProcessNames list, and a genuinely running Wow.exe
      on the dev/CI machine (a real play session) makes the child server
      correctly, but here WRONGLY for the test's intent, believe the game
      is running, starving every assertion below the game-mode gate of
      the stub traffic it expects - the exact false failure confirmed in
      the Round 36 verifier report. Returning a fresh, deliberately
      nonexistent name each call (mirroring New-FakeWowProcess's own
      naming scheme, just never actually started as a process) makes
      Test-GameRunning's Get-Process lookup always miss, so "not running"
      holds regardless of the real machine's state.
    #>
    return 'WowFakeNotRunning' + (Get-Random -Maximum 99999)
}

function Add-WagoBrowsePath {
    <#
      Every /api/wago/browse call in this file needs an explicit
      ?flavour=retail: Copy-Fixture's wowroot fixture has FOUR flavours
      installed (retail/classic/classic_era/ptr - see
      Assert-FixturePristine's own file list in tests\lib\common.ps1), and
      Resolve-RequestFlavour (addon-server.ps1 ~L1037) 400s
      ("flavour required") any FlavourScopedEndpoints call that omits
      ?flavour= while more than one flavour is installed - confirmed live
      while writing this file (every existing flavour-scoped integration
      test already does the same, e.g.
      Server.FreshnessAndFlavours.Tests.ps1's own "?flavour=retail").
      /api/wago/categories is NOT flavour-scoped (not in
      $Script:FlavourScopedEndpoints) and must NOT go through this.
    #>
    param([string]$Path)
    # NOT "$Path?flavour=retail": PowerShell 5.1's unbraced double-quoted
    # interpolation tokenizes "?" as a valid (extended) variable-name
    # character, so "$Path?flavour=retail" parses as ONE variable
    # reference literally named "Path?flavour" (nonexistent -> empty),
    # leaving only "=retail" behind - confirmed live while writing this
    # file. "${Path}" (braced) stops the token at the closing brace and
    # is what actually works; "$Path&..." (used just above) is fine as-is
    # since "&" is not one of the extended characters.
    if ($Path -match '\?') { return "$Path&flavour=retail" }
    return "${Path}?flavour=retail"
}

function Wait-ForWagoCrawlPages {
    <#
      Round 37 (server perf pass) moved Initialize-WagoGrowthSnapshots off
      the pre-accept startup path and into Invoke-MaintenanceTick's own
      asynchronously-spawned -MaintenanceOnly child (addon-server.ps1
      ~L5378-5455) - so unlike before this round, the crawl has NOT
      necessarily finished (or even started) the instant Start-TestServer
      returns; it now takes real wall-clock time for that child to spawn,
      fetch, and write the snapshot file. Polls -Condition (a scriptblock
      returning the current matching-request count) until it reaches
      -ExpectedCount or -TimeoutSec elapses, then returns whatever the
      last count was so the caller's own assertion produces a normal,
      readable Pester failure (actual N, expected -ExpectedCount) instead
      of this helper throwing.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$ExpectedCount = 10,
        [int]$TimeoutSec = 30,
        [int]$PollMs = 300
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

function Block-WagoGrowthCrawl {
    <#
      Pre-seeds a just-captured (now) snapshot file for every WagoField
      value this fixture's installed flavours can resolve to (confirmed
      live: retail, classic, mop - the rolling Classic client's current
      era per FLAVORS-SPEC.md S2.4 - plus bc/wotlk/cata defensively), so
      Initialize-WagoGrowthSnapshots' own 20-hour staleness gate
      (WAGO-BROWSE-SPEC.md section 4.1 gate 2) skips every flavour at this
      server's startup. Without this, the startup crawl runs for real
      (SERVER-5 already lands unconditionally whenever WoW isn't
      "running" and no fresh snapshot exists) and silently both (a) adds
      extra, unplanned requests to this Describe's own stub - corrupting
      any exact stub-request-COUNT assertion (cache/pacing/pagination) -
      and (b) can pre-warm Get-WagoCached's shared in-memory cache for the
      exact retail/page1/no-filter URI a Describe's own "first call is a
      genuine cache miss" assertion depends on. Not used by the three
      Describes that either want the crawl itself under test (9c) or
      already keep a fake WoW process running for their entire duration
      (9a/9b/10/game-mode), which already skips the crawl via gate 1.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $cacheDir = Join-Path $Root 'cache'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $nowStr = Get-Date -Date ((Get-Date).ToUniversalTime()) -Format 'yyyy-MM-ddTHH:mm:ssZ'
    foreach ($gv in @('retail', 'classic', 'bc', 'wotlk', 'cata', 'mop')) {
        $snap = [PSCustomObject]@{
            gameVersion     = $gv
            firstCapturedAt = $nowStr
            snapshots       = @(
                [PSCustomObject]@{
                    capturedAt = $nowStr
                    items      = @([PSCustomObject]@{ slug = 'gate-seed'; name = 'gate seed'; thumbnail = ''; downloads = 1; rank = 1 })
                }
            )
        }
        ($snap | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $cacheDir "wago-growth-$gv.json") -Encoding UTF8
    }
}

function ConvertTo-RoundedUtcSeconds {
    <# Round-trips a timestamp (string or [datetime]) to UTC, second precision, for tolerant equality checks against the server's own ISO8601 formatting. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    $dt = [datetime]$Value
    $dt = $dt.ToUniversalTime()
    return (Get-Date -Date $dt -Format 'yyyy-MM-ddTHH:mm:ssZ')
}

# =====================================================================
# 1) Default listing (Popular)
# =====================================================================

Describe 'Wago browse: default listing (Popular)' {
    if (-not ($Script:CapCore -and $Script:CapParserWidened)) {
        It 'GET /api/wago/browse with no params sends no sort=, returns sortApplied=popular with author/downloads/updatedAt/summary populated on every row, and 29 categories folded in' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam), SERVER-2 (Handle-WagoBrowse / /api/wago/browse route), and SERVER-3 (parser widened to author/summary/downloads/updatedAt)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-default'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'GET /api/wago/browse with no params sends no sort=, returns sortApplied=popular with author/downloads/updatedAt/summary populated on every row, and 29 categories folded in' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $r.Ok | Should Be $true
            $r.Body.sortApplied | Should Be 'popular'
            $r.Body.page | Should Be 1
            $r.Body.lastPage | Should Be 67
            $r.Body.total | Should Be 1000
            @($r.Body.items).Count | Should BeGreaterThan 0

            $first = $r.Body.items[0]
            $first.slug | Should Be 'details-damage-meter-standalone'
            $first.name | Should Be 'Details! Damage Meter'
            $first.author | Should Be 'Terciob'
            [int]$first.downloads | Should Be 7581560
            $first.updatedAt | Should Be 'Aug 18, 2026'
            ([string]::IsNullOrEmpty($first.summary)) | Should Be $false

            foreach ($item in @($r.Body.items)) {
                ([string]::IsNullOrEmpty($item.author)) | Should Be $false
                ([string]::IsNullOrEmpty($item.updatedAt)) | Should Be $false
                ($item.downloads -is [int]) -or ($item.downloads -is [long]) | Should Be $true
            }

            @($r.Body.categories).Count | Should Be 29
            $r.Body.categories[27].id | Should Be 5
            $r.Body.categories[27].displayName | Should Be 'Buffs & Debuffs'

            $reqs = Get-WagoStubRequests -Stub $stub
            @($reqs | Where-Object { -not [string]::IsNullOrEmpty($_.query.sort) }).Count | Should Be 0
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 2) Categories folded in, /api/wago/categories still works
# =====================================================================

Describe 'Wago browse: categories' {
    if (-not $Script:CapCore) {
        It '/api/wago/browse categories and /api/wago/categories agree exactly, id-for-id, in the server''s own order' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-categories'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It '/api/wago/browse categories and /api/wago/categories agree exactly, id-for-id, in the server''s own order' {
            $rBrowse = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $rCats = Invoke-Api -Port 47899 -Method Get -Path '/api/wago/categories'
            $rBrowse.Ok | Should Be $true
            $rCats.Ok | Should Be $true

            @($rBrowse.Body.categories).Count | Should Be 29
            @($rCats.Body.data).Count | Should Be 29
            for ($i = 0; $i -lt 29; $i++) {
                $rBrowse.Body.categories[$i].id | Should Be $rCats.Body.data[$i].id
                $rBrowse.Body.categories[$i].displayName | Should Be $rCats.Body.data[$i].display_name
            }
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 3) categoryId filtering (+ hardening on a non-numeric value)
# =====================================================================

Describe 'Wago browse: categoryId filtering' {
    if (-not $Script:CapCore) {
        It 'categoryId=4 forwards category=4 and returns the filtered total; categoryId=abc is dropped entirely' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-categoryid'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' },
            @{ gameVersion = 'retail'; page = '1'; category = '4'; file = 'category-4-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'categoryId=4 forwards category=4 to Wago and returns the real filtered total/lastPage' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?categoryId=4')
            $r.Ok | Should Be $true
            $r.Body.total | Should Be 116
            $r.Body.lastPage | Should Be 8

            $reqs = Get-WagoStubRequests -Stub $stub
            $last = $reqs[$reqs.Count - 1]
            $last.query.category | Should Be '4'
        }

        It 'categoryId=abc (non-numeric) is dropped - stub receives no category param, falls back to the unfiltered default listing' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?categoryId=abc')
            $r.Ok | Should Be $true
            $r.Body.total | Should Be 1000

            $reqs = Get-WagoStubRequests -Stub $stub
            $last = $reqs[$reqs.Count - 1]
            ([string]::IsNullOrEmpty($last.query.category)) | Should Be $true
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 4) Sort handling: name / updated / unknown-value absorption
# =====================================================================

Describe 'Wago browse: sort handling' {
    if (-not ($Script:CapCore -and $Script:CapParserWidened)) {
        It 'sort=name forwards; sort=updated re-sorts client-side with zero extra requests; sort=rising is absorbed to popular' {
            Write-PendingSkip 'needs SERVER-1/SERVER-2 (route) and SERVER-3 (Sort-WagoItemsByUpdated)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-sort'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' },
            @{ gameVersion = 'retail'; page = '1'; sort = 'name'; file = 'sort-name-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'sort=name forwards sort=name to Wago, sortApplied=name, alphabetical first item' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=name')
            $r.Ok | Should Be $true
            $r.Body.sortApplied | Should Be 'name'
            $r.Body.items[0].slug | Should Be 'bang'
            $r.Body.items[0].name | Should Be '!bang'

            $reqs = Get-WagoStubRequests -Stub $stub
            $last = $reqs[$reqs.Count - 1]
            $last.query.sort | Should Be 'name'
        }

        It 'sort=updated re-sorts the SAME popular page client-side (shares its cache slot, zero extra stub requests), never forwards sort=updated upstream' {
            $rPopular = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $rPopular.Ok | Should Be $true
            $countAfterPopular = (Get-WagoStubRequests -Stub $stub).Count

            $rUpdated = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=updated')
            $rUpdated.Ok | Should Be $true
            $rUpdated.Body.sortApplied | Should Be 'updated'
            $countAfterUpdated = (Get-WagoStubRequests -Stub $stub).Count

            # Same underlying URL as popular for this page -> Get-WagoCached
            # hit, no new upstream request at all.
            $countAfterUpdated | Should Be $countAfterPopular

            # Same item SET as popular (a page-local re-sort, not a
            # different fetch) - just re-ordered.
            @($rUpdated.Body.items).Count | Should Be @($rPopular.Body.items).Count
            ($rUpdated.Body.items | ForEach-Object { $_.slug } | Sort-Object) -join ',' |
                Should Be (($rPopular.Body.items | ForEach-Object { $_.slug } | Sort-Object) -join ',')

            # Genuinely re-sorted by date, descending, monotonic.
            $dates = $rUpdated.Body.items | ForEach-Object {
                [datetime]::ParseExact($_.updatedAt, 'MMM d, yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            for ($i = 1; $i -lt $dates.Count; $i++) {
                ($dates[$i - 1] -ge $dates[$i]) | Should Be $true
            }

            $reqs = Get-WagoStubRequests -Stub $stub
            @($reqs | Where-Object { $_.query.sort -eq 'updated' }).Count | Should Be 0
        }

        It 'sort=rising (a stale/unknown client value) is absorbed to popular - stub receives no sort param at all' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=rising')
            $r.Ok | Should Be $true
            $r.Body.sortApplied | Should Be 'popular'

            $reqs = Get-WagoStubRequests -Stub $stub
            $last = $reqs[$reqs.Count - 1]
            ([string]::IsNullOrEmpty($last.query.sort)) | Should Be $true
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 5) Pagination
# =====================================================================

Describe 'Wago browse: pagination' {
    if (-not $Script:CapCore) {
        It 'page=2 forwards page=2 and returns Wago''s own current_page/last_page/total' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-page'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' },
            @{ gameVersion = 'retail'; page = '2'; file = 'default-retail-page2.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'page=2 forwards page=2 to Wago and returns page 2''s own paginator/first item' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?page=2')
            $r.Ok | Should Be $true
            $r.Body.page | Should Be 2
            $r.Body.lastPage | Should Be 67
            $r.Body.total | Should Be 1000
            $r.Body.items[0].slug | Should Be 'tomtom'

            $reqs = Get-WagoStubRequests -Stub $stub
            $last = $reqs[$reqs.Count - 1]
            $last.query.page | Should Be '2'
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 6) Cache: second identical call makes zero stub requests
# =====================================================================

Describe 'Wago browse: cache' {
    if (-not $Script:CapCore) {
        It 'an identical second call within 5 minutes makes zero additional stub requests' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-cache'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'an identical second call within 5 minutes makes zero additional stub requests' {
            $r1 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $r1.Ok | Should Be $true
            $countAfter1 = (Get-WagoStubRequests -Stub $stub).Count
            $countAfter1 | Should Be 1

            $r2 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $r2.Ok | Should Be $true
            $countAfter2 = (Get-WagoStubRequests -Stub $stub).Count
            $countAfter2 | Should Be $countAfter1

            $r2.Body.total | Should Be $r1.Body.total
            $r2.Body.items[0].slug | Should Be $r1.Body.items[0].slug
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 7) Pacing: N sequential distinct calls take >= (N-1)*300ms
# =====================================================================

Describe 'Wago browse: pacing' {
    if (-not $Script:CapCore) {
        It '3 sequential DISTINCT calls (cache misses) take at least (N-1)*300ms combined' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-pacing'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' },
            @{ gameVersion = 'retail'; page = '1'; category = '4'; file = 'category-4-page1.json' },
            @{ gameVersion = 'retail'; page = '1'; sort = 'name'; file = 'sort-name-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It '3 sequential DISTINCT calls (cache misses) take at least (N-1)*300ms combined' {
            $n = 3
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r1 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $r2 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?categoryId=4')
            $r3 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=name')
            $sw.Stop()

            $r1.Ok | Should Be $true
            $r2.Ok | Should Be $true
            $r3.Ok | Should Be $true
            (Get-WagoStubRequests -Stub $stub).Count | Should Be $n

            $sw.Elapsed.TotalMilliseconds | Should BeGreaterThan (($n - 1) * 300)
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 8) Game mode: gameActive, zero stub requests
# =====================================================================

Describe 'Wago browse: game mode (no cache warm yet)' {
    if (-not ($Script:CapCore -and $Script:CapAllowLiveFetch)) {
        It 'with a fake WoW process running and no prior cache entry, browse returns gameActive:true, items:[], and the stub sees zero requests' {
            Write-PendingSkip 'needs SERVER-1/SERVER-2 (route) and SERVER-4 (Get-WagoCached -AllowLiveFetch / the game-mode gate)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-gamemode'
    $stub = $null
    $server = $null
    $fakeWow = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        # Fake WoW BEFORE the server, same ordering rationale
        # tests\perf\Perf.Tests.ps1 documents for its own steady-state
        # test - Test-GameRunning's own startup probe/cache should see it
        # running from the server's very first read.
        $fakeWow = New-FakeWowProcess -Root $root

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try {
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)
        } finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'with a fake WoW process running and no prior cache entry, browse returns gameActive:true, items:[], and the stub sees zero requests' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse')
            $r.Ok | Should Be $true
            $r.Body.gameActive | Should Be $true
            @($r.Body.items).Count | Should Be 0
            $r.Body.total | Should Be 0
            $r.Body.page | Should Be 1
            $r.Body.lastPage | Should Be 1

            (Get-WagoStubRequests -Stub $stub).Count | Should Be 0
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
        Stop-FakeWowProcess -FakeWow $fakeWow
    }
}

# =====================================================================
# 9a) Gaining this week: not-ready before any snapshot exists
#     (fake WoW running so gate 1 guarantees zero snapshot file - a
#     deterministic way to reach the "no file yet" state without racing
#     the crawl's own startup timing.)
# =====================================================================

Describe 'Wago browse: Gaining this week - not ready (no snapshot file yet)' {
    if (-not ($Script:CapCore -and $Script:CapGrowthSnapshots)) {
        It 'sort=gaining before any snapshot file exists returns ready:false, items:[], since:null, snapshotCount:0 - and answers even while WoW is running (pure disk read)' {
            Write-PendingSkip 'needs SERVER-1/SERVER-2 (route) and SERVER-5 (Initialize-WagoGrowthSnapshots / Get-WagoGrowthRanking)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-gaining-notready'
    $stub = $null
    $server = $null
    $fakeWow = $null
    try {
        $stub = Start-WagoStubServer -Routes @() -DefaultFile 'empty-retail.json'
        $fakeWow = New-FakeWowProcess -Root $root

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try {
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)
        } finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'sort=gaining before any snapshot file exists returns ready:false, items:[], since:null, snapshotCount:0 - and answers even while WoW is running (pure disk read)' {
            (Test-Path -LiteralPath (Join-Path $root 'cache\wago-growth-retail.json')) | Should Be $false

            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=gaining')
            $r.Ok | Should Be $true
            $r.Body.sortApplied | Should Be 'gaining'
            $r.Body.ready | Should Be $false
            @($r.Body.items).Count | Should Be 0
            $r.Body.since | Should Be $null
            $r.Body.snapshotCount | Should Be 0

            # sort=gaining is a pure disk read - never blocked by game state.
            $r.StatusCode | Should Be 200
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
        Stop-FakeWowProcess -FakeWow $fakeWow
    }
}

# =====================================================================
# 9b) Gaining this week: ready, seeded 2 snapshots 7 days apart
# =====================================================================

Describe 'Wago browse: Gaining this week - ready (2 snapshots, 7 days apart)' {
    if (-not ($Script:CapCore -and $Script:CapGrowthSnapshots)) {
        It 'ready:true with the expected delta-ranked order once two snapshots 7 days apart exist' {
            Write-PendingSkip 'needs SERVER-1/SERVER-2 (route) and SERVER-5 (Initialize-WagoGrowthSnapshots / Get-WagoGrowthRanking)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-gaining-ready'
    $stub = $null
    $server = $null
    $fakeWow = $null
    try {
        # Pre-seed the snapshot file directly, in the exact format
        # WAGO-BROWSE-SPEC.md section 4.6 documents - no crawl needed
        # (and fake WoW below guarantees the real startup crawl, if it
        # ran, could never overwrite/append to this seeded file).
        $now = (Get-Date).ToUniversalTime()
        $baselineAt = $now.AddDays(-7)
        $cacheDir = Join-Path $root 'cache'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

        $snapshotFile = [PSCustomObject]@{
            gameVersion      = 'retail'
            firstCapturedAt  = (Get-Date -Date $baselineAt -Format 'yyyy-MM-ddTHH:mm:ssZ')
            snapshots        = @(
                [PSCustomObject]@{
                    capturedAt = (Get-Date -Date $baselineAt -Format 'yyyy-MM-ddTHH:mm:ssZ')
                    items      = @(
                        [PSCustomObject]@{ slug = 'addon-a'; name = 'Addon A'; thumbnail = 'https://cdn.wago.io/thumbnails/a.png'; downloads = 1000; rank = 1 }
                        [PSCustomObject]@{ slug = 'addon-b'; name = 'Addon B'; thumbnail = 'https://cdn.wago.io/thumbnails/b.png'; downloads = 2000; rank = 2 }
                        [PSCustomObject]@{ slug = 'addon-c'; name = 'Addon C'; thumbnail = 'https://cdn.wago.io/thumbnails/c.png'; downloads = 500; rank = 3 }
                    )
                }
                [PSCustomObject]@{
                    capturedAt = (Get-Date -Date $now -Format 'yyyy-MM-ddTHH:mm:ssZ')
                    items      = @(
                        [PSCustomObject]@{ slug = 'addon-a'; name = 'Addon A'; thumbnail = 'https://cdn.wago.io/thumbnails/a.png'; downloads = 1500; rank = 1 }
                        [PSCustomObject]@{ slug = 'addon-b'; name = 'Addon B'; thumbnail = 'https://cdn.wago.io/thumbnails/b.png'; downloads = 2100; rank = 2 }
                        [PSCustomObject]@{ slug = 'addon-c'; name = 'Addon C'; thumbnail = 'https://cdn.wago.io/thumbnails/c.png'; downloads = 500; rank = 3 }
                        [PSCustomObject]@{ slug = 'addon-d'; name = 'Addon D (new entrant, no baseline)'; thumbnail = 'https://cdn.wago.io/thumbnails/d.png'; downloads = 300; rank = 4 }
                    )
                }
            )
        }
        ($snapshotFile | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $cacheDir 'wago-growth-retail.json') -Encoding UTF8

        $stub = Start-WagoStubServer -Routes @() -DefaultFile 'empty-retail.json'
        $fakeWow = New-FakeWowProcess -Root $root

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try {
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)
        } finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'ready:true, snapshotCount:2, since/asOf/baselineAsOf match the seeded timestamps, items ranked delta-desc/downloads-desc/slug-asc, flat and baseline-absent entries excluded' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=gaining')
            $r.Ok | Should Be $true
            $r.Body.sortApplied | Should Be 'gaining'
            $r.Body.ready | Should Be $true
            $r.Body.snapshotCount | Should Be 2

            (ConvertTo-RoundedUtcSeconds $r.Body.since) | Should Be (ConvertTo-RoundedUtcSeconds $baselineAt)
            (ConvertTo-RoundedUtcSeconds $r.Body.asOf) | Should Be (ConvertTo-RoundedUtcSeconds $now)
            (ConvertTo-RoundedUtcSeconds $r.Body.baselineAsOf) | Should Be (ConvertTo-RoundedUtcSeconds $baselineAt)

            # addon-c is flat (0 delta) and addon-d has no baseline entry -
            # both excluded, never shown as "gaining".
            @($r.Body.items).Count | Should Be 2
            $r.Body.items[0].slug | Should Be 'addon-a'
            $r.Body.items[0].deltaDownloads | Should Be 500
            $r.Body.items[0].downloads | Should Be 1500
            $r.Body.items[1].slug | Should Be 'addon-b'
            $r.Body.items[1].deltaDownloads | Should Be 100
            $r.Body.items[1].downloads | Should Be 2100

            # Different, smaller shape than the other three sort modes -
            # never author/summary/updatedAt on a gaining item.
            $props = $r.Body.items[0].PSObject.Properties.Name
            ($props -contains 'author') | Should Be $false
            ($props -contains 'summary') | Should Be $false
            ($props -contains 'updatedAt') | Should Be $false

            (Get-WagoStubRequests -Stub $stub).Count | Should Be 0
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
        Stop-FakeWowProcess -FakeWow $fakeWow
    }
}

# =====================================================================
# 9c) Snapshot crawl: at most 10 pages, writes a spec-shaped file,
#     de-dups by slug (all 10 pages point at the SAME 15-card fixture,
#     so a working de-dup collapses the crawl to exactly those 15).
# =====================================================================

Describe 'Wago browse: snapshot crawl at startup (<=10 pages, spec-shaped file, de-dup)' {
    if (-not ($Script:CapCore -and $Script:CapGrowthSnapshots)) {
        It 'a fresh server (no fake WoW, empty cache dir) crawls at most 10 pages and writes a spec-shaped wago-growth-retail.json, de-duped by slug' {
            Write-PendingSkip 'needs SERVER-1/SERVER-2 (route) and SERVER-5 (Initialize-WagoGrowthSnapshots)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-crawl'
    $stub = $null
    $server = $null
    try {
        # Every one of pages 1-10 resolves to the SAME 15-card fixture
        # (last_page:67 in that fixture, so the crawl won't stop early on
        # last_page) - this pins the "<=10 pages" cap at exactly 10 and,
        # since the 15 slugs repeat on every page, doubles as a direct
        # exercise of the crawl's own defensive de-dup-by-slug rule
        # (WAGO-BROWSE-SPEC.md section 4.2).
        $routes = @()
        for ($p = 1; $p -le 10; $p++) {
            $routes += @{ gameVersion = 'retail'; page = [string]$p; file = 'default-retail-page1.json' }
        }
        $stub = Start-WagoStubServer -Routes $routes -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try {
            # No -WowFakeProcessName here at all (game genuinely not
            # running) and a fresh -Root (no pre-existing snapshot file,
            # so the 20h-staleness gate has nothing to skip against) - the
            # crawl should run for real during this server's own startup.
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName))
        } finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'crawls at most 10 pages for the one installed flavour and writes a spec-shaped, de-duped snapshot file' {
            # The crawl now runs inside Invoke-MaintenanceTick's own
            # asynchronously-spawned child (Round 37), so it has not
            # necessarily finished - or even started - the instant
            # Start-TestServer above returned. Poll for the crawl to
            # actually reach its <=10-page cap before asserting on it,
            # instead of asserting immediately against whatever partial
            # (possibly zero) request count had landed by this point.
            $getCrawlReqCount = {
                @(Get-WagoStubRequests -Stub $stub | Where-Object { $_.query.game_version -eq 'retail' -and [string]::IsNullOrEmpty($_.query.search) -and [string]::IsNullOrEmpty($_.query.category) -and [string]::IsNullOrEmpty($_.query.sort) }).Count
            }
            Wait-ForWagoCrawlPages -Condition $getCrawlReqCount -ExpectedCount 10 -TimeoutSec 30 | Out-Null

            $reqs = Get-WagoStubRequests -Stub $stub
            $crawlReqs = @($reqs | Where-Object { $_.query.game_version -eq 'retail' -and [string]::IsNullOrEmpty($_.query.search) -and [string]::IsNullOrEmpty($_.query.category) -and [string]::IsNullOrEmpty($_.query.sort) })
            $crawlReqs.Count | Should Be 10
            ($crawlReqs | ForEach-Object { $_.query.page } | Sort-Object -Unique).Count | Should Be 10

            $snapshotPath = Join-Path $root 'cache\wago-growth-retail.json'
            # The 10th page REQUEST landing at the stub (just confirmed
            # above) only means the crawl's for-loop body has started
            # running for that page - Save-WagoGrowthSnapshot itself still
            # has to happen afterward in the same maintenance child (parse
            # the response, then write the file). A short extra poll on the
            # file itself closes that small remaining race instead of
            # asserting immediately.
            Wait-ForWagoCrawlPages -Condition { if (Test-Path -LiteralPath $snapshotPath) { 1 } else { 0 } } -ExpectedCount 1 -TimeoutSec 10 | Out-Null
            (Test-Path -LiteralPath $snapshotPath) | Should Be $true
            $file = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
            $file.gameVersion | Should Be 'retail'
            ([string]::IsNullOrEmpty($file.firstCapturedAt)) | Should Be $false
            @($file.snapshots).Count | Should Be 1
            # default-retail-page1.json's real WAGO-BROWSE-RESEARCH.md
            # capture carries 14 parseable cards (per_page=15 is Wago's
            # page SIZE, not a promise every page returns exactly that
            # many) - all 10 crawled pages point at this same fixture, so
            # a working de-dup-by-slug collapses the crawl to exactly
            # those 14 unique slugs.
            @($file.snapshots[0].items).Count | Should Be 14
            @($file.snapshots[0].items).Count | Should BeLessThan 151

            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=gaining')
            $r.Body.snapshotCount | Should Be 1
            $r.Body.ready | Should Be $false
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 10) category + gaining: permanent incompatibility
# =====================================================================

Describe 'Wago browse: category + gaining incompatibility' {
    if (-not ($Script:CapCore -and $Script:CapGrowthSnapshots)) {
        It 'sort=gaining&categoryId=<n> returns identical items/order to sort=gaining alone, and never touches the stub' {
            Write-PendingSkip 'needs SERVER-1/SERVER-2 (route) and SERVER-5 (Get-WagoGrowthRanking)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-gaining-category'
    $stub = $null
    $server = $null
    $fakeWow = $null
    try {
        $now = (Get-Date).ToUniversalTime()
        $baselineAt = $now.AddDays(-7)
        $cacheDir = Join-Path $root 'cache'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $snapshotFile = [PSCustomObject]@{
            gameVersion     = 'retail'
            firstCapturedAt = (Get-Date -Date $baselineAt -Format 'yyyy-MM-ddTHH:mm:ssZ')
            snapshots       = @(
                [PSCustomObject]@{ capturedAt = (Get-Date -Date $baselineAt -Format 'yyyy-MM-ddTHH:mm:ssZ'); items = @([PSCustomObject]@{ slug = 'addon-a'; name = 'Addon A'; thumbnail = ''; downloads = 1000; rank = 1 }) }
                [PSCustomObject]@{ capturedAt = (Get-Date -Date $now -Format 'yyyy-MM-ddTHH:mm:ssZ'); items = @([PSCustomObject]@{ slug = 'addon-a'; name = 'Addon A'; thumbnail = ''; downloads = 1500; rank = 1 }) }
            )
        }
        ($snapshotFile | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $cacheDir 'wago-growth-retail.json') -Encoding UTF8

        $stub = Start-WagoStubServer -Routes @() -DefaultFile 'empty-retail.json'
        $fakeWow = New-FakeWowProcess -Root $root

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try {
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)
        } finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'sort=gaining&categoryId=<n> returns identical items/order to sort=gaining alone, and never touches the stub' {
            $r1 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=gaining')
            $r2 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?sort=gaining&categoryId=4')
            $r1.Ok | Should Be $true
            $r2.Ok | Should Be $true

            (@($r1.Body.items) | ConvertTo-Json -Depth 10 -Compress) | Should Be (@($r2.Body.items) | ConvertTo-Json -Depth 10 -Compress)
            $r1.Body.ready | Should Be $r2.Body.ready
            $r1.Body.snapshotCount | Should Be $r2.Body.snapshotCount

            (Get-WagoStubRequests -Stub $stub).Count | Should Be 0
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
        Stop-FakeWowProcess -FakeWow $fakeWow
    }
}

# =====================================================================
# 11) CSRF: GET is exempt, untouched by this round
# =====================================================================

Describe 'Wago browse: CSRF (GET is exempt)' {
    if (-not $Script:CapCore) {
        It 'GET /api/wago/browse succeeds with no Origin/Referer header at all' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-csrf'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'GET /api/wago/browse succeeds with no Origin/Referer header at all (CSRF guard is POST/PUT/DELETE only)' {
            $r = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse') -NoOrigin
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 200
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 12) Unrecognized Classic era refuses instead of silently falling back
#     to Retail (multi-client:wago-browse-unknown-classic-era-silently-
#     shows-retail)
# =====================================================================

Describe 'Wago browse: unrecognized Classic client version refuses instead of silently showing Retail' {
    <#
      Before this round's fix, an EraKey='unknown' Classic client (a
      future expansion Resolve-ClassicProgressionTypeId's table doesn't
      cover yet) silently substituted 'retail' for the unresolved
      game_version - the exact class of bug addon-sync.ps1's own
      Sync-SingleAddon/Sync-SingleWagoAddon already hard-fail on for the
      identical sentinel. A below-average-tech player on that client
      would see real Retail-track Wago addons in their Classic search
      results with zero indication anything was wrong.
    #>
    if (-not $Script:CapCore) {
        It 'a Classic .build.info Interface outside every known progression range returns a clear error, never a silent Retail listing' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-unknown-era'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        # ConvertTo-InterfaceNumber: "6.6.0.12345" -> 60600 - outside every
        # row of Resolve-ClassicProgressionTypeId's table (mists tops out at
        # 50599, retail starts at 120000), matching the finding's own live
        # repro exactly. Plain literal string replace (not regex) - the
        # fixture's own wow_classic row Version ("5.5.4.61180") is a unique
        # literal in this file, so this can't accidentally touch the
        # separate classic_era row.
        $buildInfoPath = Join-Path $wowRoot '.build.info'
        $buildInfoText = Get-Content -LiteralPath $buildInfoPath -Raw
        if (-not $buildInfoText.Contains('|5.5.4.61180||wow_classic')) {
            throw "fixture .build.info no longer contains the expected wow_classic row - update this test's literal Version match"
        }
        $buildInfoText = $buildInfoText.Replace('|5.5.4.61180||wow_classic', '|6.6.0.12345||wow_classic')
        Set-Content -LiteralPath $buildInfoPath -Value $buildInfoText -Encoding UTF8 -NoNewline

        # Only game_version=retail is mapped at the stub - anything else
        # (including a genuine bug that still forwards a request) falls to
        # the empty default, so a regression back to the old silent-
        # fallback behavior would still surface as an assertion failure
        # below (real items back on a listing that should be an error),
        # not a false pass.
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; file = 'default-retail-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'GET /api/state confirms the unresolved Interface reached the server' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=classic'
            $r.Ok | Should Be $true
            $r.Body.clientInterface | Should Be 60600
        }

        It 'GET /api/wago/browse?flavour=classic returns a clear error (not 200 with items), and never sends game_version=retail for this client' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/wago/browse?flavour=classic'
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 422
            ([string]::IsNullOrEmpty($r.Body.error)) | Should Be $false

            $reqs = Get-WagoStubRequests -Stub $stub
            @($reqs | Where-Object { $_.query.game_version -eq 'retail' }).Count | Should Be 0
            @($reqs).Count | Should Be 0
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}

# =====================================================================
# 13) Regression guard (Round-2-QA regression-guards:wago-search-stale-
#     response-no-guard-test, component: tests): distinct search queries
#     must never cross-contaminate each other's response.
#
#     ui\app.js's fetchWago carries a `wagoFetchSeq` sequence counter
#     (ui/app.js:5763/5774/5792) that makes the SPA ignore a browse/search
#     response that comes back after the user has already moved on to a
#     different query - the Round 20 live fix this guards. That guard
#     lives entirely client-side (ui/app.js and tests/spa/harness.js are
#     the SPA fixer's files, not this suite's), so this Describe covers
#     the piece actually reachable from here: the SERVER-side half of the
#     guarantee that guard depends on being safe at all. If Handle-
#     WagoBrowse/Get-WagoCached/Invoke-WagoInertiaJson ever grew a bit of
#     shared mutable state one request could read/overwrite while another
#     was still in flight (a caching-key collision, a stray script-scope
#     "last search" variable, etc.), the "stale" response the client-side
#     guard discards would no longer just be LATE - it would be WRONG,
#     which the sequence-number guard alone cannot detect or fix. This
#     test proves that never happens: a response for query Q is always
#     actually query Q's own data, whether the immediately-adjacent
#     request was for a different query moments before/after, or was
#     genuinely concurrent with it on the wire.
#
#     addon-server.ps1's own request loop is fully sequential (one
#     EndGetContext -> Invoke-Route -> BeginGetContext at a time - see
#     that loop's own comment near the bottom of addon-server.ps1), so
#     this suite cannot force a real network-level "later response
#     overtakes an earlier one" the way a slow real Wago upstream
#     occasionally can in production. Firing both requests truly
#     concurrently (Invoke-ApiConcurrentPair, tests\lib\common.ps1) is
#     still a meaningful, deterministic regression guard: whichever of
#     the two the server happens to finish first, each response must
#     carry only its own query's data - proving no shared state leaks
#     between concurrently-in-flight requests, today or after some future
#     change to this request path.
# =====================================================================

Describe 'Wago browse: distinct search queries never cross-contaminate (Round 20 regression guard)' {
    if (-not $Script:CapCore) {
        It 'two different q= searches, run back-to-back and genuinely concurrently, never swap or blend results' {
            Write-PendingSkip 'needs SERVER-1 (WagoBaseUrl seam) and SERVER-2 (Handle-WagoBrowse / /api/wago/browse route)'
        }
        return
    }

    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'wago-browse-race'
    Block-WagoGrowthCrawl -Root $root
    $stub = $null
    $server = $null
    try {
        # Two existing, already-distinct fixtures (search-bigwigs-page1 /
        # sort-name-page1 - neither used together by any earlier Describe
        # in this file) mapped to two arbitrary, deliberately unrelated
        # -q= values, so a response containing the WRONG fixture's data is
        # unambiguous - there is no realistic way a correct implementation
        # could confuse the two.
        $stub = Start-WagoStubServer -Routes @(
            @{ gameVersion = 'retail'; page = '1'; search = 'race-query-a'; file = 'search-bigwigs-page1.json' },
            @{ gameVersion = 'retail'; page = '1'; search = 'race-query-b'; file = 'sort-name-page1.json' }
        ) -DefaultFile 'empty-retail.json'

        $env:FURPHY_TEST_WAGO_BASEURL = $stub.BaseUrl
        try { $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        finally { Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue }

        It 'sequential: query A, then query B, then query A again - A''s result is identical both times and never picks up B''s data' {
            $rA1 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?q=race-query-a')
            $rA1.Ok | Should Be $true
            $rA1.Body.items[0].slug | Should Be 'bigwigs'
            $rA1.Body.total | Should Be 27

            $rB = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?q=race-query-b')
            $rB.Ok | Should Be $true
            $rB.Body.items[0].slug | Should Be 'bang'
            $rB.Body.total | Should Be 1000

            # Re-issued right after a DIFFERENT query answered in between -
            # a shared/stale-state bug would most plausibly show up here,
            # either as A silently returning B's data or as a cache-key
            # collision serving A's own now-wrong cached entry for B.
            $rA2 = Invoke-Api -Port 47899 -Method Get -Path (Add-WagoBrowsePath '/api/wago/browse?q=race-query-a')
            $rA2.Ok | Should Be $true
            $rA2.Body.items[0].slug | Should Be 'bigwigs'
            $rA2.Body.total | Should Be 27
        }

        It 'concurrent: query A and query B fired truly simultaneously on the wire never swap results, whichever the server finishes first' {
            $pair = Invoke-ApiConcurrentPair -Port 47899 `
                -PathA (Add-WagoBrowsePath '/api/wago/browse?q=race-query-a') `
                -PathB (Add-WagoBrowsePath '/api/wago/browse?q=race-query-b')

            $pair.A.Ok | Should Be $true
            $pair.B.Ok | Should Be $true

            # Each response must carry ONLY its own query's data, never
            # the other's - regardless of which one the server's own
            # strictly-sequential loop happened to service first (visible
            # via .CompletedAtUtc on each result if this ever needs
            # debugging; the correctness assertion below does not depend
            # on which order won).
            $pair.A.Body.items[0].slug | Should Be 'bigwigs'
            $pair.A.Body.total | Should Be 27
            $pair.B.Body.items[0].slug | Should Be 'bang'
            $pair.B.Body.total | Should Be 1000
        }
    } finally {
        Stop-TestServer -Server $server
        Stop-WagoStubServer -Stub $stub
    }
}
