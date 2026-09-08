<#
=====================================================================
 tests\fixtures\wago-stub\WagoStubHelpers.ps1

 Start/Stop/inspect wrapper around WagoStubServer.ps1 (the real
 subprocess in this same folder), for tests\integration\
 Server.WagoBrowse.Tests.ps1. Kept local to this fixture folder (owned
 by Builder C) rather than added to tests\lib\common.ps1, to stay
 additive and avoid touching a file other builders may be editing in
 parallel - dot-source AFTER tests\lib\common.ps1 (needs
 Get-FreeStaticPort/Wait-Port/New-TempRoot from it):

     . (Join-Path $PSScriptRoot '..\lib\common.ps1')
     . (Join-Path $PSScriptRoot '..\fixtures\wago-stub\WagoStubHelpers.ps1')

 A -Routes entry is a hashtable: @{ gameVersion; page; search; category;
 sort; file; status }. gameVersion defaults 'retail', page defaults 1,
 search/category/sort default '' (absent-from-URL, matching
 Handle-WagoBrowse/Handle-WagoSearch's own URL builder - see
 WAGO-BROWSE-SPEC.md section 3.1), file names a fixture under
 tests\fixtures\wago-stub\pages\*.json, status defaults 200 (a
 non-200 short-circuits both the handshake and XHR paths with that
 status - the "stub returns 500 -> Handle-WagoBrowse returns 502" shape).
=====================================================================
#>

$Script:WagoStubScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'WagoStubServer.ps1'
$Script:WagoStubPagesDir = Join-Path -Path $PSScriptRoot -ChildPath 'pages'

function Start-WagoStubServer {
    param(
        [int]$Port,
        # NOT Mandatory, deliberately: PowerShell's binder treats an empty
        # array passed to a Mandatory collection parameter as "nothing was
        # bound" and throws ("...because it is an empty collection") - a
        # real gotcha, not a typo, hit while writing this file's own
        # Gaining-this-week Describes (they legitimately pass -Routes @(),
        # relying purely on -DefaultFile).
        [array]$Routes = @(),
        [string]$DefaultFile,
        [int]$DefaultStatus = 200,
        [string]$Version = 'wago-stub-v1'
    )

    if (-not $Port) { $Port = Get-FreeStaticPort }

    $manifestRoutes = @()
    foreach ($r in $Routes) {
        $manifestRoutes += [PSCustomObject]@{
            gameVersion = $(if ($r.ContainsKey('gameVersion') -and $r.gameVersion) { $r.gameVersion } else { 'retail' })
            page        = [string]$(if ($r.ContainsKey('page') -and $r.page) { $r.page } else { '1' })
            search      = $(if ($r.ContainsKey('search')) { [string]$r.search } else { '' })
            category    = $(if ($r.ContainsKey('category')) { [string]$r.category } else { '' })
            sort        = $(if ($r.ContainsKey('sort')) { [string]$r.sort } else { '' })
            file        = $r.file
            status      = $(if ($r.ContainsKey('status') -and $r.status) { [int]$r.status } else { 200 })
        }
    }
    $manifest = [PSCustomObject]@{
        version       = $Version
        routes        = $manifestRoutes
        defaultFile   = $DefaultFile
        defaultStatus = $DefaultStatus
    }

    $manifestDir = New-TempRoot -Name 'wago-stub-manifest'
    $manifestPath = Join-Path -Path $manifestDir -ChildPath 'manifest.json'
    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.Add('-NoProfile')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($Script:WagoStubScriptPath)
    $argList.Add('-Port'); $argList.Add([string]$Port)
    $argList.Add('-ManifestPath'); $argList.Add($manifestPath)
    $argList.Add('-PagesDir'); $argList.Add($Script:WagoStubPagesDir)

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() -WindowStyle Hidden -PassThru

    if (-not (Wait-Port -Port $Port -TimeoutSec 15)) {
        try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        throw "Start-WagoStubServer: stub did not come up on port $Port within 15s"
    }

    return [PSCustomObject]@{ Process = $proc; Port = $Port; ManifestPath = $manifestPath; BaseUrl = "http://127.0.0.1:$Port" }
}

function Stop-WagoStubServer {
    param($Stub)
    if (-not $Stub) { return }
    try {
        $req = [System.Net.HttpWebRequest]::Create("$($Stub.BaseUrl)/__control/shutdown")
        $req.Method = 'POST'
        $req.Timeout = 2000
        $req.ContentLength = 0
        $req.GetRequestStream().Close()
        $req.GetResponse().Close()
    } catch {
    }
    Start-Sleep -Milliseconds 150
    try {
        if ($Stub.Process -and -not $Stub.Process.HasExited) {
            Stop-Process -Id $Stub.Process.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

function Get-WagoStubRequests {
    <#
      Returns the stub's own request log (array of {method,path,query,
      timeUtc}), oldest first - always as a real array, even when there
      is exactly one entry or zero.

      `return @($resp)` alone is NOT enough here, confirmed live: when a
      function's own pipeline OUTPUT is an array with exactly one
      element, PowerShell unwraps it back to that single bare object for
      a caller doing `$x = Get-WagoStubRequests ...` - a real, classic
      gotcha, distinct from the `@(...)` wrapper itself (which is only
      about the RIGHT-hand value, not about how a function's output
      stream re-flattens what it emits). The unary comma operator
      (`,@($resp)`) forces the ARRAY ITSELF to be the one object written
      to the output stream, so it survives the trip back to the caller
      intact regardless of length - callers may then use
      `.Count`/`.Length` directly with no `@()` of their own required.
    #>
    param($Stub)
    try {
        $resp = Invoke-RestMethod -Uri "$($Stub.BaseUrl)/__control/requests" -Method Get -TimeoutSec 5
        return , @($resp)
    } catch {
        throw "Get-WagoStubRequests: could not reach stub control endpoint: $($_.Exception.Message)"
    }
}

function Get-WagoStubRequestCount {
    param($Stub)
    return @(Get-WagoStubRequests -Stub $Stub).Count
}
