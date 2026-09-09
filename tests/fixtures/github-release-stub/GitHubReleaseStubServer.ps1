<#
=====================================================================
 tests\fixtures\github-release-stub\GitHubReleaseStubServer.ps1

 Package E (APP-UPDATE-SPEC.md sections 12/13, round 42/1.22.0). A real,
 standalone GitHub-Releases-API-shaped stub server, started as its own
 child process (mirrors tests\fixtures\wago-stub\WagoStubServer.ps1's own
 shape exactly - a real System.Net.HttpListener, a JSON manifest written
 by the wrapper in tests\lib\common.ps1's Start-GitHubReleaseStubServer,
 never hand-edited). Pointed at via $env:FURPHY_TEST_GITHUB_BASEURL the
 same way FURPHY_TEST_WAGO_BASEURL already works for the Wago stub -
 addon-server.ps1's own $Script:GitHubBaseUrl seam (APP-UPDATE-SPEC.md
 section 8.1) replaces https://api.github.com with this stub's base URL
 for the life of one server process.

 Routes:
   GET /repos/krenz444/furphy-addon-manager/releases/latest
       -> if manifest.requireUserAgent and the request carries no
          User-Agent header at all: 403 (mirrors the real GitHub API's
          own rejection of anonymous-looking requests with no UA -
          APP-UPDATE-SPEC.md section 8.1's "the GitHub API rejects
          requests with none").
       -> else if manifest.releaseStatus -ne 200: that status, with
          Retry-After / X-RateLimit-Reset headers set from the manifest
          when present (the 403/429 rate-limit knob - section 8.1/16 Q2),
          and a small {"message":"..."} JSON body (real GitHub shape).
       -> else: 200, the constructed release JSON (tag_name, html_url,
          assets[] - each asset's browser_download_url points back at
          THIS stub's own /download/<name>, never hand-built by the
          caller - section 8.2's own rule).
   GET /download/<name>
       -> serves the exact bytes of whichever fixture file the manifest
          registered under that name (the zip, its .sha256 sidecar, or
          an extra/unrelated asset), Content-Type application/octet-
          stream. 404 if <name> was never registered.
   GET  /__control/requests  -> JSON array of every non-control request
        seen so far ({method, path, timeUtc, hasUserAgent}), oldest
        first - lets a test assert "no request without a User-Agent" or
        "the on-demand check made exactly one GET, no retry loop"
        (section 8.1's "never retry in a tight loop").
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

# name -> on-disk file path, for every /download/<name> this stub can
# actually serve (zip, sha sidecar, and any extra assets) - built once at
# startup, fails fast on a missing fixture file rather than a mysterious
# per-request 500 later.
$Script:DownloadIndex = @{}
foreach ($a in @($manifest.downloadableAssets)) {
    if (-not (Test-Path -LiteralPath $a.filePath -PathType Leaf)) {
        throw "GitHubReleaseStubServer: fixture asset file not found: $($a.filePath)"
    }
    $Script:DownloadIndex[$a.name] = $a.filePath
}

$Script:RequestLog = New-Object 'System.Collections.Generic.List[object]'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-StubLog "listening on port $Port, tagName=$($manifest.tagName), releaseStatus=$($manifest.releaseStatus), $($Script:DownloadIndex.Count) downloadable asset(s)"

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
    $assets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in @($manifest.releaseAssets)) {
        $assets.Add([PSCustomObject]@{
                name                 = $a.name
                browser_download_url = "http://127.0.0.1:$Port/download/$($a.name)"
            })
    }
    return [PSCustomObject]@{
        tag_name = $manifest.tagName
        html_url = $manifest.htmlUrl
        assets   = @($assets.ToArray())
    }
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
            $Script:RequestLog.Add([PSCustomObject]@{
                    method       = $request.HttpMethod
                    path         = $path
                    timeUtc      = (Get-Date).ToUniversalTime().ToString('o')
                    hasUserAgent = $hasUserAgent
                })
            Write-StubLog "$($request.HttpMethod) $path (UA=$hasUserAgent)"

            if ($path -eq '/repos/krenz444/furphy-addon-manager/releases/latest') {
                $requireUa = $true
                if ($null -ne $manifest.requireUserAgent) { $requireUa = [bool]$manifest.requireUserAgent }
                if ($requireUa -and -not $hasUserAgent) {
                    Send-StubJson -Response $response -StatusCode 403 -Body @{ message = 'Request forbidden by administrative rules. Missing User-Agent header.' }
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
