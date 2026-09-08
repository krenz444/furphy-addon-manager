<#
=====================================================================
 tests\fixtures\wago-stub\WagoStubServer.ps1

 A real, standalone Wago-shaped stub server (Builder C / integration
 tests). Started as its own child process (mirrors how Start-TestServer
 itself launches addon-server.ps1 - see tests\lib\common.ps1), so it can
 be pointed at via FURPHY_TEST_WAGO_BASEURL exactly the way
 addon-sync.ps1's own FURPHY_TEST_CF_BASEURL/FURPHY_TEST_WAGO_BASEURL
 seam already works, and the way addon-server.ps1's own copy of that
 seam will work once SERVER-1 (WAGO-BROWSE-SPEC.md section 3.7) lands.

 Speaks the real Inertia handshake addon-server.ps1's Wago functions
 already implement (Get-WagoInertiaHandshake / Invoke-WagoInertiaJson):
   - A plain GET (no X-Inertia header) returns an HTML page with
     id="app" data-page="<HTML-encoded JSON of {component,props,url,
     version}>" - this is what the FIRST Wago request of a fresh server
     process reads.
   - A GET carrying "X-Inertia: true" and a matching "X-Inertia-Version"
     header returns that same JSON object directly (Content-Type:
     application/json) - what every request after the first uses.
   - A mismatched X-Inertia-Version returns 409 (empty JSON body) so the
     real re-handshake path (a 409 triggers exactly one re-handshake +
     retry) can be exercised if a test ever wants to.

 Routing is entirely data-driven from -ManifestPath (a JSON file written
 by tests\fixtures\wago-stub\WagoStubHelpers.ps1's Start-WagoStubServer,
 one per test scenario - never hand-edited): an ordered list of routes,
 each matching one exact (game_version, page, search, category, sort)
 combination Handle-WagoBrowse/Handle-WagoSearch's own URL builder can
 produce (WAGO-BROWSE-SPEC.md section 3.1), naming a fixture file under
 -PagesDir (tests\fixtures\wago-stub\pages\*.json - real
 addons.wago.io captures from WAGO-BROWSE-RESEARCH.md, plus two
 synthesized ones: default-retail-page3.json, a page-2-shaped clone with
 current_page patched to 3 and one card's slug swapped so tests can tell
 it apart from page 2; empty-retail.json, a zero-item listing) and an
 optional HTTP status override (used by the "one page fails -> 502"
 style test - any non-200 short-circuits BOTH the handshake and XHR
 paths with that status, matching how a real Wago 5xx would surface
 through Invoke-WagoHttpRequest -> Get-WagoCached -> Handle-WagoBrowse's
 existing 502 translation, no special-casing needed here).

 "page" is normalized to "1" when absent - Handle-WagoCategories's own
 URL never carries &page= at all (WAGO-BROWSE-RESEARCH.md section 1)
 while Handle-WagoBrowse's default-listing URL always sends &page=1;
 both need to resolve to the identical page-1 fixture, so a request with
 no page= behaves exactly like page=1 for matching purposes.

 A second, unrelated URL family under /__control/ (never a path
 addons.wago.io itself could ever serve, so it can never collide with a
 real route) lets the OTHER process (the Pester test) inspect/stop this
 one, since all of this server's own state lives only in its own memory:
   GET  /__control/requests -> JSON array of every non-control request
        received so far, in order: {method, path, query, timeUtc}. query
        is the parsed key/value map (single-valued; this stub only ever
        needs to log what was asked, not a fully general multi-value
        querystring).
   POST /__control/shutdown -> stops the listener and exits 0. Always
        answered before the process actually exits, so a caller's own
        HTTP call completes normally.

 ASCII only. Windows PowerShell 5.1. Deliberately synchronous
 (Get Context blocks) - a test stub never needs the main server's own
 async BeginGetContext pattern, and synchronous is far simpler to keep
 correct here.
=====================================================================
#>

param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$PagesDir
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Write-StubLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath (Join-Path (Split-Path -Path $ManifestPath -Parent) 'wago-stub.log') -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message) -Encoding UTF8
    } catch {
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "WagoStubServer: manifest not found: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $manifest.version) { throw 'WagoStubServer: manifest.version is required' }

# Pre-load every fixture file the manifest references (fail fast, once,
# at startup - a missing fixture is a test-authoring bug, not something
# that should surface as a mysterious per-request 500 later).
$Script:PageCache = @{}
function Get-StubPageObject {
    param([string]$FileName)
    if (-not $FileName) { return $null }
    if ($Script:PageCache.ContainsKey($FileName)) { return $Script:PageCache[$FileName] }
    $path = Join-Path -Path $PagesDir -ChildPath $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "WagoStubServer: fixture file not found: $path"
    }
    $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    # Every served page reports the SAME manifest-controlled version, not
    # whatever version happened to be baked into the real capture - keeps
    # one session's handshake/XHR version checks internally consistent
    # regardless of which real capture a given route reuses.
    $obj | Add-Member -NotePropertyName 'version' -NotePropertyValue $manifest.version -Force
    $Script:PageCache[$FileName] = $obj
    return $obj
}
foreach ($r in @($manifest.routes)) { Get-StubPageObject -FileName $r.file | Out-Null }
if ($manifest.defaultFile) { Get-StubPageObject -FileName $manifest.defaultFile | Out-Null }

function Get-StubQueryValue {
    param($QueryString, [string]$Name, [string]$Default = '')
    $v = $QueryString[$Name]
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

function Get-StubRouteKey {
    param([string]$GameVersion, [string]$Page, [string]$Search, [string]$Category, [string]$Sort)
    $gv = if ($GameVersion) { $GameVersion } else { 'retail' }
    $pg = if ($Page) { $Page } else { '1' }
    return "$gv|$pg|$Search|$Category|$Sort"
}

# Index manifest routes by key for O(1) lookup.
$Script:RouteIndex = @{}
foreach ($r in @($manifest.routes)) {
    $key = Get-StubRouteKey -GameVersion $r.gameVersion -Page ([string]$r.page) -Search $r.search -Category $r.category -Sort $r.sort
    $Script:RouteIndex[$key] = $r
}

$Script:RequestLog = New-Object 'System.Collections.Generic.List[object]'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-StubLog "listening on port $Port, $($Script:RouteIndex.Count) route(s), default=$($manifest.defaultFile)"

function Send-StubBytes {
    param($Response, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

function Send-StubJson {
    param($Response, [int]$StatusCode, $Body)
    # -InputObject, never piped: `$Body | ConvertTo-Json` unrolls a
    # zero-element array into ZERO pipeline items, so ConvertTo-Json gets
    # called with nothing and returns $null - confirmed live (the
    # /__control/requests endpoint 500'd with "GetBytes: Array cannot be
    # null" the first time this file's own request log was empty).
    # -InputObject binds the array as a single object, no unrolling.
    $json = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
    if ($null -eq $json) { $json = 'null' }
    Send-StubBytes -Response $Response -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))
}

$Script:ShuttingDown = $false

try {
    while (-not $Script:ShuttingDown) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            $path = $request.Url.AbsolutePath

            if ($path -eq '/__control/requests') {
                Send-StubJson -Response $response -StatusCode 200 -Body @($Script:RequestLog.ToArray())
                continue
            }
            if ($path -eq '/__control/shutdown') {
                Send-StubJson -Response $response -StatusCode 200 -Body @{ ok = $true }
                $Script:ShuttingDown = $true
                continue
            }

            $q = $request.QueryString
            $gv = Get-StubQueryValue -QueryString $q -Name 'game_version' -Default 'retail'
            $page = Get-StubQueryValue -QueryString $q -Name 'page' -Default '1'
            $search = Get-StubQueryValue -QueryString $q -Name 'search'
            $category = Get-StubQueryValue -QueryString $q -Name 'category'
            $sort = Get-StubQueryValue -QueryString $q -Name 'sort'

            $queryMap = @{ game_version = $gv; page = $page; search = $search; category = $category; sort = $sort }
            $Script:RequestLog.Add([PSCustomObject]@{
                    method  = $request.HttpMethod
                    path    = $path
                    query   = $queryMap
                    timeUtc = (Get-Date).ToUniversalTime().ToString('o')
                })
            Write-StubLog "$($request.HttpMethod) $($request.Url.PathAndQuery)"

            $key = Get-StubRouteKey -GameVersion $gv -Page $page -Search $search -Category $category -Sort $sort
            $route = $Script:RouteIndex[$key]
            $fileName = $null
            $status = 200
            if ($route) {
                $fileName = $route.file
                if ($route.status) { $status = [int]$route.status }
            } elseif ($manifest.defaultFile) {
                $fileName = $manifest.defaultFile
                if ($manifest.defaultStatus) { $status = [int]$manifest.defaultStatus }
            }

            if (-not $fileName) {
                Send-StubBytes -Response $response -StatusCode 404 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('no stub route or default configured'))
                continue
            }

            if ($status -ne 200) {
                Send-StubBytes -Response $response -StatusCode $status -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes("stub-configured failure ($status)"))
                continue
            }

            $pageObj = Get-StubPageObject -FileName $fileName
            $isInertiaXhr = ($request.Headers['X-Inertia'] -eq 'true')

            if ($isInertiaXhr) {
                $clientVersion = $request.Headers['X-Inertia-Version']
                if ($clientVersion -ne $manifest.version) {
                    Send-StubBytes -Response $response -StatusCode 409 -ContentType 'application/json' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('{}'))
                    continue
                }
                Send-StubJson -Response $response -StatusCode 200 -Body $pageObj
                continue
            }

            # Plain-HTML Inertia handshake: HTML-encode the same JSON object
            # into an id="app" data-page="..." attribute, matching the real
            # site's own markup (WAGO-BROWSE-RESEARCH.md section 2/"How the
            # app currently calls Wago") closely enough for
            # Get-WagoInertiaHandshake's regex to find it.
            $json = $pageObj | ConvertTo-Json -Depth 30 -Compress
            $encoded = [System.Net.WebUtility]::HtmlEncode($json)
            $html = '<!doctype html><html><head><title>stub</title></head><body><div id="app" data-page="' + $encoded + '"></div></body></html>'
            Send-StubBytes -Response $response -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Bytes ([System.Text.Encoding]::UTF8.GetBytes($html))
        } catch {
            Write-StubLog "ERROR handling request: $($_.Exception.Message)"
            try {
                Send-StubBytes -Response $response -StatusCode 500 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('stub internal error'))
            } catch {
            }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-StubLog 'stopped'
}
