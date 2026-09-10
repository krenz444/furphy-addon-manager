<#
=====================================================================
 tests\fixtures\github-release-stub\GitHubReleaseStubServer.ps1

 Package E (APP-UPDATE-SPEC.md sections 12/13, round 42/1.22.0). Extended
 for Round 47 (GITHUB-SOURCE-SPEC.md sections 7.2/7.3, Package D) to also
 serve the "GitHub as a third addon source" feature's own release/asset/
 zipball lookups for an arbitrary owner/repo, with an optional Bearer-
 token gate simulating a private repo. A real, standalone GitHub-
 Releases-API-shaped stub server, started as its own child process
 (mirrors tests\fixtures\wago-stub\WagoStubServer.ps1's own shape exactly
 - a real System.Net.HttpListener, a JSON manifest written by the wrapper
 in tests\lib\common.ps1's Start-GitHubReleaseStubServer, never
 hand-edited). Pointed at via $env:FURPHY_TEST_GITHUB_BASEURL - the same
 seam both addon-server.ps1 (self-update) and addon-sync.ps1 (the GitHub
 addon source) read.

 Every new field/route below defaults to reproducing today's exact
 self-update-fixture behavior when the caller never opts in - no existing
 App-Update test needs any change.

 Routes:
   GET /repos/<owner>/<repoName>/releases/latest
       (owner/repoName default to krenz444/furphy-addon-manager - the
       original self-update fixture's own hardcoded path, so a caller
       that never sets manifest.owner/repoName gets the byte-identical
       route from before this round)
       -> if manifest.requireUserAgent and the request carries no
          User-Agent header at all: 403 (unchanged from before this
          round).
       -> else if manifest.requireToken and the request's Authorization
          does not carry the expected Bearer token (missing OR wrong):
          404 (matches real GitHub's own "can't tell no-access from
          nonexistent" behavior for a private repo - GITHUB-SOURCE-SPEC.md
          3.5). Never triggers when manifest.requireToken is unset/false
          (every pre-Round-47 caller).
       -> else if manifest.releaseStatus -ne 200: that status, with
          Retry-After / X-RateLimit-Reset headers set from the manifest
          when present (the 403/429 rate-limit knob), and a small
          {"message":"..."} JSON body (real GitHub shape).
       -> else: 200, the constructed release JSON (tag_name, html_url,
          assets[] - each asset carries both browser_download_url
          (unauthenticated, points back at this stub's own
          /download/<name> - the self-update path's own download
          mechanism, unchanged) and url (the authenticated asset-by-id
          API endpoint GITHUB-SOURCE-SPEC.md 3.6.1 requires the GitHub
          addon source to use instead of browser_download_url), plus
          zipball_url when manifest.zipballAvailable is set (omitted
          entirely otherwise, so the JSON shape for every existing
          caller is unchanged).
   GET /repos/<owner>/<repoName>/releases/assets/<name>
       -> Round 47: the asset-by-id download path (3.6.1) - same
          User-Agent/token gates as releases/latest, same underlying file
          lookup as /download/<name> below (any name registered via
          -ZipEntries/-ZipSourceDir/-ExtraAssets is reachable here too).
   GET /repos/<owner>/<repoName>/zipball/<tag>
       -> Round 47: only served when manifest.zipballAvailable is true
          (default false - both this route and the release JSON's own
          zipball_url are absent when off, matching 3.6.2's "no zipball
          URL at all" case exactly). Same gates. Serves the exact bytes
          of manifest.zipballFilePath (built by tests\lib\common.ps1's
          New-GitHubZipballFixtureZip, never by this script).
   GET /download/<name>
       -> serves the exact bytes of whichever fixture file the manifest
          registered under that name (the zip, its .sha256 sidecar, or
          an extra/unrelated asset), Content-Type application/octet-
          stream. 404 if <name> was never registered. NEVER token-gated
          - this is the self-update path's own unauthenticated
          browser_download_url endpoint, unchanged from before this
          round.
   GET  /__control/requests  -> JSON array of every non-control request
        seen so far ({method, path, timeUtc, hasUserAgent,
        hasAuthorization, and - only when manifest.requireToken is true -
        authorizationMatched}), oldest first - lets a test assert "the
        release lookup carried Authorization: Bearer <the exact test
        token>" (delivery) separately from a text-search over
        server.log/sync.log/etc for the literal token string (non-leakage)
        - GITHUB-SOURCE-SPEC.md 6.3.
   POST /__control/shutdown  -> stops the listener and exits.

 ASCII only. Windows PowerShell 5.1. Deliberately synchronous
 (GetContext blocks), same reasoning as WagoStubServer.ps1's own header:
 a test stub never needs the main server's async accept-loop pattern.
=====================================================================
#>

param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ManifestPath
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Write-StubLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath (Join-Path (Split-Path -Path $ManifestPath -Parent) 'github-release-stub.log') -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message) -Encoding UTF8
    } catch {
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "GitHubReleaseStubServer: manifest not found: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $manifest.tagName) { throw 'GitHubReleaseStubServer: manifest.tagName is required' }

# Round 47 (7.2): all four fields below are new and optional, defaulting
# to exactly the original self-update fixture's own hardcoded shape.
$Script:Owner = 'krenz444'
if ($manifest.owner) { $Script:Owner = [string]$manifest.owner }
$Script:RepoName = 'furphy-addon-manager'
if ($manifest.repoName) { $Script:RepoName = [string]$manifest.repoName }
$Script:RequireToken = $false
if ($null -ne $manifest.requireToken) { $Script:RequireToken = [bool]$manifest.requireToken }
$Script:ExpectedToken = $null
if ($manifest.expectedToken) { $Script:ExpectedToken = [string]$manifest.expectedToken }
$Script:ZipballAvailable = $false
if ($null -ne $manifest.zipballAvailable) { $Script:ZipballAvailable = [bool]$manifest.zipballAvailable }

$Script:ReleasesLatestPath = "/repos/$Script:Owner/$Script:RepoName/releases/latest"
$Script:AssetByIdPrefix = "/repos/$Script:Owner/$Script:RepoName/releases/assets/"
$Script:ZipballPath = "/repos/$Script:Owner/$Script:RepoName/zipball/$($manifest.tagName)"

# name -> on-disk file path, for every /download/<name> AND
# /repos/.../releases/assets/<name> this stub can actually serve (zip, sha
# sidecar, and any extra assets) - built once at startup, fails fast on a
# missing fixture file rather than a mysterious per-request 500 later.
$Script:DownloadIndex = @{}
foreach ($a in @($manifest.downloadableAssets)) {
    if (-not (Test-Path -LiteralPath $a.filePath -PathType Leaf)) {
        throw "GitHubReleaseStubServer: fixture asset file not found: $($a.filePath)"
    }
    $Script:DownloadIndex[$a.name] = $a.filePath
}

if ($Script:ZipballAvailable) {
    if (-not $manifest.zipballFilePath -or -not (Test-Path -LiteralPath ([string]$manifest.zipballFilePath) -PathType Leaf)) {
        throw "GitHubReleaseStubServer: manifest.zipballAvailable is set but manifest.zipballFilePath is missing or not found: $($manifest.zipballFilePath)"
    }
}

$Script:RequestLog = New-Object 'System.Collections.Generic.List[object]'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-StubLog "listening on port $Port, owner=$Script:Owner, repo=$Script:RepoName, tagName=$($manifest.tagName), releaseStatus=$($manifest.releaseStatus), requireToken=$Script:RequireToken, zipballAvailable=$Script:ZipballAvailable, $($Script:DownloadIndex.Count) downloadable asset(s)"

function Send-StubBytes {
    param($Response, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes, [hashtable]$ExtraHeaders)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) {
            if ($null -ne $ExtraHeaders[$k]) { $Response.Headers.Set([string]$k, [string]$ExtraHeaders[$k]) }
        }
    }
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

function Send-StubJson {
    param($Response, [int]$StatusCode, $Body, [hashtable]$ExtraHeaders)
    $json = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
    if ($null -eq $json) { $json = 'null' }
    Send-StubBytes -Response $Response -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) -ExtraHeaders $ExtraHeaders
}

function Get-ReleaseJsonBody {
    <#
      Round 47: each asset now also carries "url" (the authenticated
      asset-by-id endpoint GITHUB-SOURCE-SPEC.md 3.6.1 requires) alongside
      the pre-existing "browser_download_url" (the self-update path's own
      unauthenticated download, unchanged). "zipball_url" is added only
      when $Script:ZipballAvailable - omitted entirely otherwise, so the
      release JSON shape for every pre-Round-47 caller is unchanged.
    #>
    $assets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in @($manifest.releaseAssets)) {
        $assets.Add([PSCustomObject]@{
                name                 = $a.name
                browser_download_url = "http://127.0.0.1:$Port/download/$($a.name)"
                url                  = "http://127.0.0.1:$Port$Script:AssetByIdPrefix$($a.name)"
            })
    }
    $releaseBody = [PSCustomObject]@{
        tag_name = $manifest.tagName
        html_url = $manifest.htmlUrl
        assets   = @($assets.ToArray())
    }
    if ($Script:ZipballAvailable) {
        Add-Member -InputObject $releaseBody -NotePropertyName 'zipball_url' -NotePropertyValue "http://127.0.0.1:$Port$Script:ZipballPath"
    }
    return $releaseBody
}

function Test-StubAuthorization {
    <#
      Round 47: {HasAuthorization; Matched} for the current request.
      Matched is only meaningful when $Script:RequireToken is set - a
      request against a stub with no token requirement is never rejected
      on this basis either way, so Matched being $false there carries no
      meaning and is never consulted.
    #>
    param($Request)
    $authHeader = $Request.Headers['Authorization']
    $hasAuth = -not [string]::IsNullOrWhiteSpace($authHeader)
    $matched = $false
    if ($hasAuth -and $Script:ExpectedToken) {
        $matched = ($authHeader -eq ('Bearer ' + $Script:ExpectedToken))
    }
    return [PSCustomObject]@{ HasAuthorization = $hasAuth; Matched = $matched }
}

function Test-StubTokenGateBlocks {
    <# Round 47: the shared "404 it" decision used by all three token-gated routes. #>
    param($AuthInfo)
    return ($Script:RequireToken -and (-not $AuthInfo.HasAuthorization -or -not $AuthInfo.Matched))
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

            $userAgent = $request.Headers['User-Agent']
            $hasUserAgent = -not [string]::IsNullOrWhiteSpace($userAgent)
            $authInfo = Test-StubAuthorization -Request $request
            $logEntry = [PSCustomObject]@{
                method           = $request.HttpMethod
                path             = $path
                timeUtc          = (Get-Date).ToUniversalTime().ToString('o')
                hasUserAgent     = $hasUserAgent
                hasAuthorization = $authInfo.HasAuthorization
            }
            if ($Script:RequireToken) {
                Add-Member -InputObject $logEntry -NotePropertyName 'authorizationMatched' -NotePropertyValue $authInfo.Matched
            }
            $Script:RequestLog.Add($logEntry)
            Write-StubLog "$($request.HttpMethod) $path (UA=$hasUserAgent, Auth=$($authInfo.HasAuthorization))"

            if ($path -eq $Script:ReleasesLatestPath) {
                $requireUa = $true
                if ($null -ne $manifest.requireUserAgent) { $requireUa = [bool]$manifest.requireUserAgent }
                if ($requireUa -and -not $hasUserAgent) {
                    Send-StubJson -Response $response -StatusCode 403 -Body @{ message = 'Request forbidden by administrative rules. Missing User-Agent header.' }
                    continue
                }

                if (Test-StubTokenGateBlocks -AuthInfo $authInfo) {
                    Send-StubJson -Response $response -StatusCode 404 -Body @{ message = 'Not Found' }
                    continue
                }

                $status = 200
                if ($manifest.releaseStatus) { $status = [int]$manifest.releaseStatus }
                if ($status -ne 200) {
                    $extra = @{}
                    if ($manifest.retryAfterSeconds) { $extra['Retry-After'] = [string]$manifest.retryAfterSeconds }
                    if ($manifest.rateLimitResetEpochSeconds) { $extra['X-RateLimit-Reset'] = [string]$manifest.rateLimitResetEpochSeconds }
                    Send-StubJson -Response $response -StatusCode $status -Body @{ message = 'API rate limit exceeded for this stub.' } -ExtraHeaders $extra
                    continue
                }

                Send-StubJson -Response $response -StatusCode 200 -Body (Get-ReleaseJsonBody)
                continue
            }

            if ($path.StartsWith($Script:AssetByIdPrefix)) {
                if (Test-StubTokenGateBlocks -AuthInfo $authInfo) {
                    Send-StubJson -Response $response -StatusCode 404 -Body @{ message = 'Not Found' }
                    continue
                }
                $name = $path.Substring($Script:AssetByIdPrefix.Length)
                if ($Script:DownloadIndex.ContainsKey($name)) {
                    $bytes = [System.IO.File]::ReadAllBytes($Script:DownloadIndex[$name])
                    Send-StubBytes -Response $response -StatusCode 200 -ContentType 'application/octet-stream' -Bytes $bytes
                } else {
                    Send-StubBytes -Response $response -StatusCode 404 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes("no such asset: $name"))
                }
                continue
            }

            if ($Script:ZipballAvailable -and $path -eq $Script:ZipballPath) {
                if (Test-StubTokenGateBlocks -AuthInfo $authInfo) {
                    Send-StubJson -Response $response -StatusCode 404 -Body @{ message = 'Not Found' }
                    continue
                }
                $bytes = [System.IO.File]::ReadAllBytes([string]$manifest.zipballFilePath)
                Send-StubBytes -Response $response -StatusCode 200 -ContentType 'application/octet-stream' -Bytes $bytes
                continue
            }

            if ($path.StartsWith('/download/')) {
                $name = $path.Substring('/download/'.Length)
                if ($Script:DownloadIndex.ContainsKey($name)) {
                    $bytes = [System.IO.File]::ReadAllBytes($Script:DownloadIndex[$name])
                    Send-StubBytes -Response $response -StatusCode 200 -ContentType 'application/octet-stream' -Bytes $bytes
                } else {
                    Send-StubBytes -Response $response -StatusCode 404 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes("no such asset: $name"))
                }
                continue
            }

            Send-StubBytes -Response $response -StatusCode 404 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('not found'))
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
