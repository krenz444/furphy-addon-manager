<#
=====================================================================
 addon-server.ps1

 Local HTTP server for the Furphy Addon Manager. Serves the ui\ single
 page app and a JSON API, runs addon-sync.ps1 as hidden child
 processes for long operations, and proxies the official CurseForge
 Core API when a key is configured in settings.json.

 Windows PowerShell 5.1 only. No modules, no external binaries, pure
 ASCII. System.Net.HttpListener, single-threaded request loop.

 LAYOUT (relative to -Root):
   addon-server.ps1  this script
   addon-sync.ps1    the CLI this script drives
   addons.json       addon records (read-only from here; the CLI owns it)
   settings.json     shared settings (created with defaults if missing)
   state.json        persisted check results and job history (E2:
                       updatesCheckedAt + updateAvailable; Round 3: lastRun +
                       the last 20 job status views), written after every
                       job completes and reloaded at startup
   ui\               static frontend files
   jobs\             per-job stdout/stderr capture files
   sync.log          CLI log (tailed for job progress)
   server.log        this script's own request/error log

 USAGE:
   addon-server.ps1 [-Port <int>] [-Root <path>] [-AddonsPath <path>]
                     [-IdleMinutes <int>] [-OpenBrowser]

   -Port <int>         Listener port. Default: settings.json port, else 47831.
   -Root <path>        Folder holding the files above. Default: $PSScriptRoot.
   -AddonsPath <path>  Forwarded to every CLI call as -AddonsPath. Default:
                        let the CLI auto-detect from its own location.
   -IdleMinutes <int>  Exit after this many minutes with no request. Default 20.
                        0 or negative disables idle exit.
   -OpenBrowser        After starting, launch Edge in app mode pointed at the
                        server (falls back to the default browser).
   -BuildInfoPath <path>  Overrides the .build.info file read for the client
                        build/compat check (E13), computed once at startup.
                        Default: the .build.info next to the resolved AddOns
                        path's game root. Intended for tests - never reads
                        the real WoW folder when given.
   -WowRoot <path>     FLAVORS-SPEC.md CS-F2: overrides multi-flavour
                        detection's WoW root (Get-InstalledFlavours), the same
                        way addon-sync.ps1's own -WowRoot does - used to point
                        this server at the FLAVORS-SPEC.md section 8 synthetic
                        fixture for local dev/test runs. Default: walk up from
                        -Root the same way Resolve-EffectiveAddonsPath already
                        does (parent leaf must be one of the six known
                        flavour folder names) - never touches the real WoW
                        folder unless -Root's own real deployment path leads
                        there, unchanged from today.
=====================================================================
#>

param(
    [int]$Port = 0,
    [string]$Root,
    [string]$AddonsPath,
    [int]$IdleMinutes = 20,
    [switch]$OpenBrowser,
    [string]$BuildInfoPath,
    [string]$WowRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =====================================================================
# Logging
# =====================================================================

function Write-ServerLog {
    param([string]$Message)

    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    try {
        Add-Content -LiteralPath $Script:ServerLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never abort a request.
    }
}

# =====================================================================
# HTTP response helpers
# =====================================================================

function Get-MimeType {
    param([string]$Extension)

    $ext = $Extension.ToLowerInvariant()
    switch ($ext) {
        '.html' { return 'text/html; charset=utf-8' }
        '.htm' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        '.ico' { return 'image/x-icon' }
        '.woff2' { return 'font/woff2' }
        default { return 'application/octet-stream' }
    }
}

function Send-Json {
    <#
      Writes one JSON response and always closes the response stream.
      -FileName (E4: GET /api/export) additionally sets Content-Disposition
      so the browser offers the response as a download instead of navigating
      to it; omitted (the default) for every other JSON response.
    #>
    param(
        $Context,
        [int]$StatusCode,
        $Body,
        [string]$FileName
    )

    $response = $Context.Response
    try {
        $json = ConvertTo-Json -InputObject $Body -Depth 12 -Compress
        if ($null -eq $json) {
            $json = 'null'
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode = $StatusCode
        $response.ContentType = 'application/json; charset=utf-8'
        $response.Headers.Set('Cache-Control', 'no-store')
        if ($FileName) {
            $response.Headers.Set('Content-Disposition', "attachment; filename=$FileName")
        }
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Script:LastResponseStatus = $StatusCode
    } catch {
        $Script:LastResponseStatus = $StatusCode
        throw
    } finally {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }
}

function Send-File {
    <# Serves one static file with the right MIME type; 404s if missing. #>
    param(
        $Context,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }

    $response = $Context.Response
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ext = [System.IO.Path]::GetExtension($Path)
        $mime = Get-MimeType -Extension $ext
        $response.StatusCode = 200
        $response.ContentType = $mime
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Script:LastResponseStatus = 200
    } finally {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }
}

function Read-Body {
    <# Reads and parses a UTF-8 JSON request body. Returns $null if empty. #>
    param($Context)

    $request = $Context.Request
    if (-not $request.HasEntityBody) {
        return $null
    }

    # Round 20 (adversarial bug pass, security-2): a browser only sends a
    # CORS preflight ahead of a cross-site request whose Content-Type is
    # something other than the three CORS-"simple" values (text/plain,
    # multipart/form-data, application/x-www-form-urlencoded). Requiring
    # exactly application/json here means any cross-site POST/PUT carrying
    # a JSON body now REQUIRES a preflight - which this server never
    # answers with any Access-Control-Allow-* headers, so the browser
    # itself blocks the follow-up request. The SPA (ui/app.js) always sends
    # "application/json; charset=utf-8" for every call with a body, so this
    # is a no-op for every legitimate caller.
    $contentType = $request.ContentType
    if ([string]::IsNullOrEmpty($contentType) -or -not $contentType.ToLowerInvariant().StartsWith('application/json')) {
        throw 'bad request: Content-Type must be application/json'
    }

    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        $text = $reader.ReadToEnd()
    } finally {
        $reader.Close()
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Invalid JSON body: $($_.Exception.Message)"
    }
}

function Get-StaticFilePath {
    <#
      Maps a request path under ui\, blocking traversal outside it.
      Returns $null when the path is unsafe (caller should 404).
    #>
    param([string]$UrlPath)

    $rel = $UrlPath.TrimStart('/')
    if ([string]::IsNullOrEmpty($rel)) {
        $rel = 'index.html'
    }

    if ($rel -match '\.\.' -or $rel -match '^[A-Za-z]:' -or $rel.StartsWith('/') -or $rel.StartsWith('\')) {
        return $null
    }

    $rel = $rel -replace '/', '\'
    $full = Join-Path -Path $Script:UiDir -ChildPath $rel

    $fullResolved = [System.IO.Path]::GetFullPath($full)
    $uiResolved = [System.IO.Path]::GetFullPath($Script:UiDir)
    if (-not $fullResolved.StartsWith($uiResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $fullResolved
}

# =====================================================================
# FLAVORS-SPEC.md CS-F2: multi-flavour detection + resolution tables.
# Duplicated verbatim from addon-sync.ps1 (existing established
# duplication pattern - this script never dot-sources the CLI, same as
# Resolve-EffectiveAddonsPath/Get-PresentAddonFolders/Get-MissingDeps/the
# compat-audit functions already are). Any future edit to one of these
# names in addon-sync.ps1 (a new flavour, a new progression row) must be
# mirrored here in the same change set - see that file's own doc comments
# for the full rationale; kept terse here.
# =====================================================================

$Script:FlavourDefs = @(
    [PSCustomObject]@{ Id = 'retail';      Folder = '_retail_';      Label = 'Retail';      Product = 'wow' }
    [PSCustomObject]@{ Id = 'classic';     Folder = '_classic_';     Label = 'Classic';     Product = 'wow_classic' }
    [PSCustomObject]@{ Id = 'classic_era'; Folder = '_classic_era_'; Label = 'Classic Era'; Product = 'wow_classic_era' }
    [PSCustomObject]@{ Id = 'ptr';         Folder = '_ptr_';         Label = 'PTR';          Product = 'wowt' }
    [PSCustomObject]@{ Id = 'xptr';        Folder = '_xptr_';        Label = 'PTR (2)';      Product = 'wowxptr' }
    [PSCustomObject]@{ Id = 'beta';        Folder = '_beta_';        Label = 'Beta';         Product = 'wow_beta' }
)
$Script:FlavourFolderSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($fd in $Script:FlavourDefs) { [void]$Script:FlavourFolderSet.Add($fd.Folder) }

$Script:TocEraSelectors = [ordered]@{
    'retail'      = [PSCustomObject]@{ XFlavorTag = 'Mainline'; Suffixes = @('_Mainline', '-Mainline') }
    'classic_era' = [PSCustomObject]@{ XFlavorTag = 'Vanilla';  Suffixes = @('_Vanilla', '_Classic', '-Classic') }
    'tbc'         = [PSCustomObject]@{ XFlavorTag = 'TBC';      Suffixes = @('_TBC', '-BCC') }
    'wrath'       = [PSCustomObject]@{ XFlavorTag = 'Wrath';    Suffixes = @('_Wrath', '-Wrath', '-WOTLKC') }
    'cata'        = [PSCustomObject]@{ XFlavorTag = 'Cata';     Suffixes = @('_Cata') }
    'mists'       = [PSCustomObject]@{ XFlavorTag = 'Mists';    Suffixes = @('_Mists') }
}

function Get-FlavourDef {
    <# Looks up one $Script:FlavourDefs entry by id. $null when unrecognized. #>
    param([Parameter(Mandatory = $true)][string]$Id)

    foreach ($def in $Script:FlavourDefs) {
        if ($def.Id -eq $Id) { return $def }
    }
    return $null
}

function ConvertTo-InterfaceNumber {
    <# "12.1.0.69587" -> 120100 (major*10000 + minor*100 + patch). $null when unparsable. #>
    param([string]$VersionText)

    if (-not $VersionText) { return $null }
    $parts = $VersionText -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $maj = 0
    $min = 0
    $pat = 0
    if ([int]::TryParse($parts[0], [ref]$maj) -and [int]::TryParse($parts[1], [ref]$min) -and [int]::TryParse($parts[2], [ref]$pat)) {
        return ($maj * 10000) + ($min * 100) + $pat
    }
    return $null
}

function Get-BuildInfoRows {
    <# Parses every data row of a pipe-delimited, typed-header .build.info file into {Product; Version} objects. Never throws. #>
    param([string]$BuildInfoPath)

    $rows = New-Object 'System.Collections.Generic.List[object]'
    if (-not $BuildInfoPath -or -not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf)) {
        Write-Output -NoEnumerate $rows
        return
    }
    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $BuildInfoPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Output -NoEnumerate $rows
        return
    }
    if (-not $lines -or $lines.Count -lt 2) {
        Write-Output -NoEnumerate $rows
        return
    }

    $headerCols = $lines[0] -split '\|'
    $versionIdx = -1
    $productIdx = -1
    for ($i = 0; $i -lt $headerCols.Count; $i++) {
        $colName = ($headerCols[$i] -split '!')[0].Trim()
        if ($colName -eq 'Version') { $versionIdx = $i }
        if ($colName -eq 'Product') { $productIdx = $i }
    }
    if ($versionIdx -lt 0 -or $productIdx -lt 0) {
        Write-Output -NoEnumerate $rows
        return
    }

    for ($r = 1; $r -lt $lines.Count; $r++) {
        $line = $lines[$r]
        if (-not $line -or $line.Trim().Length -eq 0) { continue }
        $cols = $line -split '\|'
        if ($cols.Count -le $productIdx -or $cols.Count -le $versionIdx) { continue }
        $rows.Add([PSCustomObject]@{ Product = $cols[$productIdx].Trim(); Version = $cols[$versionIdx].Trim() })
    }
    Write-Output -NoEnumerate $rows
}

function Resolve-ClassicProgressionTypeId {
    <# FLAVORS-SPEC S2.4's appendable Interface-range -> TypeId/Wago-value/version-prefix table. Falls back to Retail's row. #>
    param($Interface = $null)

    $ranges = @(
        [PSCustomObject]@{ Min = 11500;  Max = 11599;  EraKey = 'classic_era'; EraLabel = 'Classic Era (Vanilla)';   TypeId = 67408; WagoValue = 'classic'; VersionPrefix = '1.15.' }
        [PSCustomObject]@{ Min = 20500;  Max = 20599;  EraKey = 'tbc';         EraLabel = 'Burning Crusade Classic';  TypeId = 73246; WagoValue = 'bc';      VersionPrefix = '2.5.' }
        [PSCustomObject]@{ Min = 30400;  Max = 30699;  EraKey = 'wrath';       EraLabel = 'Wrath Classic';            TypeId = 73713; WagoValue = 'wotlk';   VersionPrefix = '3.4.' }
        [PSCustomObject]@{ Min = 38000;  Max = 38099;  EraKey = 'wrath';       EraLabel = 'Wrath Classic';            TypeId = 73713; WagoValue = 'wotlk';   VersionPrefix = '3.4.' }
        [PSCustomObject]@{ Min = 40400;  Max = 40499;  EraKey = 'cata';        EraLabel = 'Cataclysm Classic';        TypeId = 77522; WagoValue = 'cata';    VersionPrefix = '4.4.' }
        [PSCustomObject]@{ Min = 50500;  Max = 50599;  EraKey = 'mists';       EraLabel = 'Mists Classic';            TypeId = 79434; WagoValue = 'mop';     VersionPrefix = '5.5.' }
        [PSCustomObject]@{ Min = 120000; Max = 129999; EraKey = 'retail';      EraLabel = 'Retail';                   TypeId = 517;   WagoValue = 'retail';  VersionPrefix = '12.' }
    )

    $ival = $null
    if ($null -ne $Interface) {
        try { $ival = [int]$Interface } catch { $ival = $null }
    }

    if ($null -ne $ival -and $ival -ne 0) {
        foreach ($row in $ranges) {
            if (($ival -ge $row.Min) -and ($ival -le $row.Max)) {
                return [PSCustomObject]@{ EraKey = $row.EraKey; EraLabel = $row.EraLabel; TypeId = $row.TypeId; WagoValue = $row.WagoValue; VersionPrefix = $row.VersionPrefix }
            }
        }
        # Security-review fix (mirrors addon-sync.ps1's copy exactly): a
        # REAL, non-zero Interface matching no known range is a future
        # Classic expansion this table doesn't cover yet - NOT the same as
        # a missing/unreadable .build.info. Return the 'unknown' sentinel
        # rather than silently falling through to Retail's TypeId/WagoValue.
        return [PSCustomObject]@{ EraKey = 'unknown'; EraLabel = 'Unrecognized Classic client version'; TypeId = $null; WagoValue = $null; VersionPrefix = $null }
    }
    return [PSCustomObject]@{ EraKey = 'retail'; EraLabel = 'Retail'; TypeId = 517; WagoValue = 'retail'; VersionPrefix = '12.' }
}

function Get-CfFlavourMapping {
    <# Centralizes S4.4 (CurseForge TypeId + gameVersions prefix) and S4.6 (Wago game_version field) for one -Flavor. #>
    param([string]$Flavor = 'retail', $InstalledInterface = $null)

    switch ($Flavor) {
        'retail'      { return [PSCustomObject]@{ TypeId = 517; VersionPrefix = '12.'; WagoField = 'retail'; EraLabel = 'Retail'; EraKey = 'retail' } }
        'classic_era' { return [PSCustomObject]@{ TypeId = 67408; VersionPrefix = '1.15.'; WagoField = 'classic'; EraLabel = 'Classic Era (Vanilla)'; EraKey = 'classic_era' } }
        'classic' {
            $prog = Resolve-ClassicProgressionTypeId -Interface $InstalledInterface
            return [PSCustomObject]@{ TypeId = $prog.TypeId; VersionPrefix = $prog.VersionPrefix; WagoField = $prog.WagoValue; EraLabel = $prog.EraLabel; EraKey = $prog.EraKey }
        }
        default { return [PSCustomObject]@{ TypeId = 517; VersionPrefix = '12.'; WagoField = 'retail'; EraLabel = 'Retail'; EraKey = 'retail' } }
    }
}

function Resolve-CfInstallFlavour {
    <#
      FLAVORS-SPEC.md CS-F3 S5.5: determines which of -InstalledFlavours a
      CurseForge target actually supports, via its gameVersionTypeIds:
        - -FileId given (the embedded-site/Get-New-Addons "Install" button
          and any fileId-carrying deep link already know the exact file) -
          fetches that ONE file's own gameVersionTypeIds.
        - -FileId omitted (a bare add - Select-CfFile will pick the actual
          file per flavour later, inside the CLI) - fetches the project's
          recent files and unions their gameVersionTypeIds, since the
          question here is only "does this project support installed
          flavour X AT ALL", not "which exact file".
      Keyless (no API key - same as every other CurseForge call in this
      file); headers/user-agent mirror Test-DiagCfReachability's own
      duplicated copy of addon-sync.ps1's Invoke-CfRequest (this script
      never dot-sources the CLI).

      Returns {MatchingFlavourIds = string[]; FetchError = <text-or-null>}.
      FetchError set (network/parse failure) means MatchingFlavourIds is
      meaningless and the caller must not treat an empty array as "case 4,
      zero matches" - that failure mode is reported to the caller as a
      distinct job-start error instead.
    #>
    param(
        [Parameter(Mandatory = $true)][int64]$ProjectId,
        $FileId,
        [Parameter(Mandatory = $true)]$InstalledFlavours
    )

    $headers = @{ 'Accept' = 'application/json'; 'Referer' = 'https://www.curseforge.com/' }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

    $typeIdSet = New-Object 'System.Collections.Generic.HashSet[int64]'
    try {
        if ($FileId) {
            $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files/$FileId"
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $json = $resp.Content | ConvertFrom-Json
            if ($json -and $json.data -and $json.data.gameVersionTypeIds) {
                foreach ($t in $json.data.gameVersionTypeIds) { [void]$typeIdSet.Add([int64]$t) }
            }
        } else {
            $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files?pageIndex=0&pageSize=20&sort=dateCreated&sortDescending=true&removeAlphas=true"
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $json = $resp.Content | ConvertFrom-Json
            if ($json -and $json.data) {
                foreach ($f in $json.data) {
                    if ($f.gameVersionTypeIds) {
                        foreach ($t in $f.gameVersionTypeIds) { [void]$typeIdSet.Add([int64]$t) }
                    }
                }
            }
        }
    } catch {
        return [PSCustomObject]@{ MatchingFlavourIds = @(); FetchError = "Could not check this addon's supported WoW versions: $($_.Exception.Message)" }
    }

    $matching = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $InstalledFlavours) {
        $mapping = Get-CfFlavourMapping -Flavor $f.id -InstalledInterface $f.clientInterface
        if ($typeIdSet.Contains([int64]$mapping.TypeId)) {
            [void]$matching.Add($f.id)
        }
    }
    return [PSCustomObject]@{ MatchingFlavourIds = $matching.ToArray(); FetchError = $null }
}

function Get-TocXFlavorTag {
    <# Reads a .toc's "## X-Flavor: <Tag>" line, trimmed, or $null. Never throws. #>
    param([Parameter(Mandatory = $true)][string]$TocPath)

    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $TocPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $null
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*##\s*X-Flavor\s*:\s*(.+?)\s*$') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Resolve-TocEraKey {
    <# Maps -Flavor (+, for 'classic', -InstalledInterface) to one of $Script:TocEraSelectors' keys. #>
    param([string]$Flavor = 'retail', $InstalledInterface = $null)

    switch ($Flavor) {
        'retail'      { return 'retail' }
        'classic_era' { return 'classic_era' }
        'classic' {
            $ival = 0
            if ($null -ne $InstalledInterface) {
                try { $ival = [int]$InstalledInterface } catch { $ival = 0 }
            }
            return (Resolve-ClassicProgressionTypeId -Interface $ival).EraKey
        }
        default { return 'retail' }
    }
}

function Get-InstalledFlavours {
    <#
      FLAVORS-SPEC S2.3: returns the WoW client flavours actually present
      under $WowRoot, in S2.1's fixed order. "Installed" means
      <WowRoot>\<folder>\Interface\AddOns exists. .build.info is
      corroboration only. Never throws. -WowRoot, when given, is used
      as-is (S8's fixture path included); omitted, it is resolved by
      walking up from -ScriptRoot (default $PSScriptRoot) the same way
      Resolve-EffectiveAddonsPath's own walk-up does, generalized from
      "parent leaf must be _retail_" to "parent leaf must be one of S2.1's
      known flavour folder names."
    #>
    param(
        [string]$WowRoot,
        [string]$ScriptRoot = $PSScriptRoot
    )

    $result = New-Object 'System.Collections.Generic.List[object]'

    $resolvedWowRoot = $WowRoot
    if (-not $resolvedWowRoot -or $resolvedWowRoot.Trim().Length -eq 0) {
        if ($ScriptRoot) {
            $leaf = Split-Path -Path $ScriptRoot -Leaf
            $parentDir = Split-Path -Path $ScriptRoot -Parent
            if (($leaf -eq 'AddonSync') -and $parentDir) {
                $parentLeaf = Split-Path -Path $parentDir -Leaf
                if ($Script:FlavourFolderSet.Contains($parentLeaf)) {
                    $resolvedWowRoot = Split-Path -Path $parentDir -Parent
                }
            }
        }
    }

    if (-not $resolvedWowRoot -or -not (Test-Path -LiteralPath $resolvedWowRoot -PathType Container)) {
        Write-Output -NoEnumerate $result
        return
    }

    $buildInfoPath = Join-Path -Path $resolvedWowRoot -ChildPath '.build.info'
    $buildInfoRows = Get-BuildInfoRows -BuildInfoPath $buildInfoPath

    foreach ($def in $Script:FlavourDefs) {
        $folderPath = Join-Path -Path $resolvedWowRoot -ChildPath $def.Folder
        $addonsPath = Join-Path -Path $folderPath -ChildPath 'Interface\AddOns'
        if (-not (Test-Path -LiteralPath $addonsPath -PathType Container)) {
            continue
        }
        $row = $null
        foreach ($r in $buildInfoRows) {
            if ($r.Product -eq $def.Product) { $row = $r; break }
        }
        $clientBuild = $null
        $clientInterface = $null
        if ($row) {
            $clientBuild = $row.Version
            $clientInterface = ConvertTo-InterfaceNumber -VersionText $row.Version
        }
        $result.Add([PSCustomObject]@{
                id               = $def.Id
                folder           = $def.Folder
                label            = $def.Label
                addonsPath       = $addonsPath
                clientBuild      = $clientBuild
                clientInterface  = $clientInterface
                buildInfoRow     = $row
                buildInfoMissing = ($null -eq $row)
            })
    }

    $claimedProducts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($def in $Script:FlavourDefs) { [void]$claimedProducts.Add($def.Product) }
    try {
        $subDirs = Get-ChildItem -LiteralPath $resolvedWowRoot -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $subDirs) {
            if ($Script:FlavourFolderSet.Contains($dir.Name)) { continue }
            $candidateAddons = Join-Path -Path $dir.FullName -ChildPath 'Interface\AddOns'
            if (-not (Test-Path -LiteralPath $candidateAddons -PathType Container)) { continue }
            $matchRow = $null
            foreach ($r in $buildInfoRows) {
                if (-not $claimedProducts.Contains($r.Product)) { $matchRow = $r; break }
            }
            if ($matchRow) {
                $result.Add([PSCustomObject]@{
                        id               = $matchRow.Product
                        folder           = $dir.Name
                        label            = $matchRow.Product
                        addonsPath       = $candidateAddons
                        clientBuild      = $matchRow.Version
                        clientInterface  = (ConvertTo-InterfaceNumber -VersionText $matchRow.Version)
                        buildInfoRow     = $matchRow
                        buildInfoMissing = $false
                    })
                [void]$claimedProducts.Add($matchRow.Product)
            }
        }
    } catch {
    }

    Write-Output -NoEnumerate $result
}

function Get-MigrationHomeFlavour {
    <# Which flavours\<id>\ subfolder this AddonSync install's own pre-flavour top-level files belong under. Falls back to 'retail'. #>
    param([string]$RootPath)

    try {
        $parentDir = Split-Path -Path $RootPath -Parent
        if ($parentDir) {
            $parentLeaf = Split-Path -Path $parentDir -Leaf
            foreach ($def in $Script:FlavourDefs) {
                if ($def.Folder -eq $parentLeaf) { return $def.Id }
            }
        }
    } catch {
    }
    return 'retail'
}

function Invoke-FlavourMigration {
    <#
      FLAVORS-SPEC S3.3: one-time, idempotent, zero-data-loss migration of a
      pre-flavour install's top-level addons.json/state.json/backups\ into
      flavours\<homeFlavour>\ - duplicated from addon-sync.ps1's identical
      function (logging swapped for Write-ServerLog since this script never
      dot-sources the CLI). Called once at server startup, before any path
      resolution - CS-F1's own notesForNext flagged this file list gap
      explicitly ("a server-only first run would never migrate"); this
      change set closes it by duplicating the call here too, so a server
      that runs before the CLI ever has still migrates the shared folder.
      Never throws - every step is best-effort and logged.
    #>
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $settingsPath = Join-Path -Path $RootPath -ChildPath 'settings.json'
    $schemaVersion = 1
    $settingsObj = $null
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $settingsObj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $settingsObj.schemaVersion) {
                    $schemaVersion = [int]$settingsObj.schemaVersion
                }
            }
        } catch {
            Write-ServerLog "Flavour migration: failed to read settings.json, treating as pre-flavour: $($_.Exception.Message)"
        }
    }

    if ($schemaVersion -ge 2) {
        return
    }

    $homeFlavour = Get-MigrationHomeFlavour -RootPath $RootPath
    $flavoursDir = Join-Path -Path $RootPath -ChildPath 'flavours'
    $homeFlavourDir = Join-Path -Path $flavoursDir -ChildPath $homeFlavour
    if (-not (Test-Path -LiteralPath $homeFlavourDir)) {
        New-Item -ItemType Directory -Path $homeFlavourDir -Force | Out-Null
    }

    $addonsJsonPath = Join-Path -Path $RootPath -ChildPath 'addons.json'
    $stateJsonPath = Join-Path -Path $RootPath -ChildPath 'state.json'
    $backupsDirPath = Join-Path -Path $RootPath -ChildPath 'backups'
    $hasAddonsJson = Test-Path -LiteralPath $addonsJsonPath -PathType Leaf
    $hasStateJson = Test-Path -LiteralPath $stateJsonPath -PathType Leaf
    $hasBackupsDir = Test-Path -LiteralPath $backupsDirPath -PathType Container

    $existingBackups = $null
    if (Test-Path -LiteralPath $flavoursDir -PathType Container) {
        $existingBackups = Get-ChildItem -LiteralPath $flavoursDir -Directory -Filter '_migration-backup-*' -ErrorAction SilentlyContinue
    }
    if (($hasAddonsJson -or $hasStateJson -or $hasBackupsDir) -and (-not $existingBackups -or (@($existingBackups)).Count -eq 0)) {
        try {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupDir = Join-Path -Path $flavoursDir -ChildPath ("_migration-backup-{0}" -f $stamp)
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

            if ($hasAddonsJson) {
                Copy-Item -LiteralPath $addonsJsonPath -Destination (Join-Path -Path $backupDir -ChildPath 'addons.json') -Force
            }
            if ($hasStateJson) {
                Copy-Item -LiteralPath $stateJsonPath -Destination (Join-Path -Path $backupDir -ChildPath 'state.json') -Force
            }
            if ($hasBackupsDir) {
                Copy-Item -LiteralPath $backupsDirPath -Destination (Join-Path -Path $backupDir -ChildPath 'backups') -Recurse -Force
            }
            Write-ServerLog "Flavour migration: pre-move backup copied to $backupDir"
        } catch {
            Write-ServerLog "Flavour migration: failed to create pre-move backup: $($_.Exception.Message)"
        }
    }

    $moveOk = $true
    foreach ($name in @('addons.json', 'state.json', 'backups')) {
        $sourcePath = Join-Path -Path $RootPath -ChildPath $name
        $destPath = Join-Path -Path $homeFlavourDir -ChildPath $name
        if (Test-Path -LiteralPath $destPath) {
            continue
        }
        if (Test-Path -LiteralPath $sourcePath) {
            try {
                Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
                Write-ServerLog "Flavour migration: moved $name into $homeFlavourDir"
            } catch {
                $moveOk = $false
                Write-ServerLog "Flavour migration: failed to move $name into $homeFlavourDir : $($_.Exception.Message)"
            }
        }
    }

    if (-not $moveOk) {
        return
    }

    $newSettings = $settingsObj
    if (-not $newSettings) {
        $newSettings = [PSCustomObject]@{}
    }
    if ($newSettings.PSObject.Properties.Match('schemaVersion').Count -gt 0) {
        $newSettings.schemaVersion = 2
    } else {
        $newSettings | Add-Member -MemberType NoteProperty -Name 'schemaVersion' -Value 2
    }
    try {
        $json = ConvertTo-Json -InputObject $newSettings -Depth 10
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $settingsPath -Force
        Write-ServerLog 'Flavour migration: schemaVersion set to 2'
    } catch {
        Write-ServerLog "Flavour migration: failed to write schemaVersion to settings.json: $($_.Exception.Message)"
    }
}

# =====================================================================
# FLAVORS-SPEC.md CS-F2: per-request flavour resolution.
#
# This server is a single-threaded HttpListener request loop (see the
# file's own header comment) - exactly one request's handler ever runs at
# a time. That makes it safe for Invoke-Route to resolve one flavour per
# incoming request and stash it in $Script:CurrentFlavour /
# $Script:AddonsJsonPath / $Script:BackupsPath / $Script:ClientBuildInfo
# for the DURATION of that one handler call - every addon-scoped function
# below (Get-AddonRecords, Resolve-EffectiveAddonsPath's own default,
# Handle-Open's 'addons'/'backups' cases, etc.) keeps reading those same
# script-scope variables completely unchanged; only the VALUE they hold
# now varies per request instead of being fixed once at startup. A
# long-running background job (Start-Job's actual CLI child process) is
# unaffected by a LATER request changing this context, because its own
# process argument list (New-CliProcessArgs) is built synchronously,
# once, at the moment the job starts - see that function's own comment.
# =====================================================================

function Get-CurrentInstalledFlavours {
    <#
      Live per-request flavour detection (S8's acceptance bar: "detection is
      live, not cached"). Cheap (a handful of Test-Path calls) - recomputed
      on every request rather than cached at startup, so a flavour that
      appears or disappears mid-session (installing/uninstalling a client)
      is picked up on the very next request.
    #>
    return (Get-InstalledFlavours -WowRoot $Script:WowRootOverride -ScriptRoot $Script:Root)
}

function Get-DefaultFlavourId {
    <#
      FLAVORS-SPEC.md S4.1's default rule, server-side equivalent: 'retail'
      when installed, else the first flavour Get-CurrentInstalledFlavours
      returns, else 'retail' (byte-identical fallback when nothing at all
      can be detected - e.g. a dev checkout with no real WoW folder nearby,
      matching today's single-flavour-only behavior exactly).
    #>
    param($InstalledFlavours)

    foreach ($f in $InstalledFlavours) {
        if ($f.id -eq 'retail') { return 'retail' }
    }
    foreach ($f in $InstalledFlavours) {
        return $f.id
    }
    return 'retail'
}

function Get-QueryFlavour {
    <# Reads ?flavour= (preferred) or ?flavor= (alias, S5.1) from the request, trimmed/lowercased. $null when neither is present. #>
    param($Context)

    $q = $Context.Request.QueryString
    $val = $q['flavour']
    if (-not $val) { $val = $q['flavor'] }
    if (-not $val) { return $null }
    $val = $val.Trim().ToLowerInvariant()
    if ($val.Length -eq 0) { return $null }
    return $val
}

# FLAVORS-SPEC.md S5.1: the small, fixed set of addon-scoped endpoints that
# 400 ("flavour required") when ?flavour= is omitted AND more than one
# flavour is installed. Enumerated once here so the router and this list
# stay the single source of truth, rather than an unenforced per-handler
# convention - a missed call site would otherwise silently serve the wrong
# flavour's data instead of failing loudly in dev. Keyed the same way
# $Script:Routes is (Method + Pattern), so Invoke-Route can match against
# it directly without a second, separately-maintained handler-name list.
#
# POST /api/jobs is deliberately NOT listed here even though it is
# addon-scoped for every OTHER job kind - S5.4's {kind:"update-all-flavours"}
# is a legitimate exception (it targets every installed flavour AT ONCE, by
# definition, so requiring ?flavour= for it would be incoherent) and the
# router cannot see the POST body's own `kind` field before dispatch to
# decide which rule applies. Handle-JobsPost enforces the identical
# "flavour required" 400 itself, for every kind EXCEPT update-all-flavours,
# right after parsing `kind` from the body - see its own comment.
#
# GET /api/state is ALSO deliberately NOT listed here (verification-pass
# fix), even though its addon-list payload is exactly as flavour-scoped as
# every endpoint below it. It is the client's own bootstrap/discovery call:
# a fresh SPA load starts with zero knowledge of which/how-many flavours
# are installed (Store.installedFlavours is []), so it has no correct
# ?flavour= value to send on its very first request - hard-400'ing that
# first call created a permanent chicken-and-egg deadlock on any real (non
# -mock) machine with more than one installed flavour: the client could
# never learn it had multiple flavours because the one call that would
# tell it always failed for omitting a param it did not yet know it needed.
# Falling through to Resolve-RequestFlavour's own settings.activeFlavour-or-
# default fallback (below) resolves this exactly the way principle 5
# already intends for non-flavour-scoped endpoints: a pure UI-continuity
# guess, never load-bearing, and self-correcting immediately - the
# response's own installedFlavours/activeFlavour/flavour fields tell the
# client exactly what flavour it just got, the client adopts that into
# Store.state (see ui/app.js's reloadState), and every SUBSEQUENT call
# (including the next /api/state poll) correctly carries an explicit
# ?flavour= once Store.hasMultipleFlavours() can answer correctly.
$Script:FlavourScopedEndpoints = @(
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/ignore$' }
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/unpin$' }
    @{ Method = 'GET'; Pattern = '^/api/addons/(?<id>[^/]+)/files$' }
    @{ Method = 'GET'; Pattern = '^/api/scan$' }
    @{ Method = 'POST'; Pattern = '^/api/scan/delete$' }
    @{ Method = 'GET'; Pattern = '^/api/export$' }
    @{ Method = 'POST'; Pattern = '^/api/import$' }
    @{ Method = 'GET'; Pattern = '^/api/wago/search$' }
)

function Test-FlavourScopedEndpoint {
    param([string]$Method, [string]$Path)

    foreach ($e in $Script:FlavourScopedEndpoints) {
        if ($e.Method -eq $Method -and $Path -match $e.Pattern) { return $true }
    }
    return $false
}

function Resolve-RequestFlavour {
    <#
      S5.1's explicit-query-param addressing, resolved once per request.
      Returns {Ok; Flavor; StatusCode; Error}. Ok=$false means the caller
      must 400 with Error and never dispatch to the matched handler at all.

      - A ?flavour=/?flavor= value not among the CURRENTLY installed
        flavours is always a clean 400 (whether or not the endpoint is in
        $Script:FlavourScopedEndpoints) - never silently coerced to
        something else.
      - Omitted, with <=1 installed flavour: resolves to that one flavour
        (or the S4.1 default when none at all could be detected) - a
        single-flavour machine NEVER needs to send the param, so today's
        UI/scripts/scheduled tasks work completely unchanged (principle 2).
      - Omitted, with >1 installed: a flavour-scoped endpoint 400s
        ("flavour required"); any other endpoint (this now explicitly
        includes GET /api/state - see $Script:FlavourScopedEndpoints' own
        comment for why the client's bootstrap call cannot be in that list)
        falls back to settings.json's activeFlavour (or the S4.1 default)
        as a pure UI-continuity convenience, never load-bearing for a data
        operation (principle 5) - Get-Settings is cheap (a single small
        JSON read).
    #>
    param($Context, [string]$Method, [string]$Path)

    $installed = Get-CurrentInstalledFlavours
    $requested = Get-QueryFlavour -Context $Context

    if ($requested) {
        # Security-review fix: validate the raw query value's SHAPE before
        # anything else (defense in depth) - this is a raw, attacker-
        # controlled string that Set-CurrentFlavourContext later feeds
        # straight into Join-Path to build $Script:AddonsJsonPath/
        # $Script:BackupsPath. Known flavour ids are always lowercase
        # letters/digits/underscore; reject anything else outright rather
        # than letting a path-traversal-shaped value (e.g. "..\..\Windows")
        # reach that Join-Path call at all.
        if ($requested -notmatch '^[a-z0-9_]+$') {
            return [PSCustomObject]@{ Ok = $false; Flavor = $null; StatusCode = 400; Error = "flavour '$requested' is not installed" }
        }

        $isInstalled = $false
        foreach ($f in $installed) {
            if ($f.id -eq $requested) { $isInstalled = $true; break }
        }
        # Security-review fix: this 400 used to be gated on
        # "(@($installed)).Count -gt 0", so a $requested value was let
        # through UNVALIDATED whenever Get-CurrentInstalledFlavours
        # returned zero flavours (a real, reachable state - a bad/dev
        # -WowRoot override, or detection failing to find a real WoW
        # folder) - Set-CurrentFlavourContext would then Join-Path that raw
        # value straight into the addons.json/backups path with zero
        # sanitization. A requested flavour that isn't in the CURRENTLY
        # installed list must always 400, regardless of how many flavours
        # were detected.
        if (-not $isInstalled) {
            return [PSCustomObject]@{ Ok = $false; Flavor = $null; StatusCode = 400; Error = "flavour '$requested' is not installed" }
        }
        return [PSCustomObject]@{ Ok = $true; Flavor = $requested; StatusCode = 200; Error = $null }
    }

    if ((@($installed)).Count -le 1) {
        return [PSCustomObject]@{ Ok = $true; Flavor = (Get-DefaultFlavourId -InstalledFlavours $installed); StatusCode = 200; Error = $null }
    }

    if (Test-FlavourScopedEndpoint -Method $Method -Path $Path) {
        return [PSCustomObject]@{ Ok = $false; Flavor = $null; StatusCode = 400; Error = 'flavour required' }
    }

    $active = $null
    try { $active = (Get-Settings).activeFlavour } catch { $active = $null }
    if ($active) {
        foreach ($f in $installed) {
            if ($f.id -eq $active) { return [PSCustomObject]@{ Ok = $true; Flavor = $active; StatusCode = 200; Error = $null } }
        }
    }
    return [PSCustomObject]@{ Ok = $true; Flavor = (Get-DefaultFlavourId -InstalledFlavours $installed); StatusCode = 200; Error = $null }
}

function Set-CurrentFlavourContext {
    <#
      Stashes the resolved flavour for the request currently in flight (see
      this section's own header comment for why a script-scope variable is
      safe here). $Script:AddonsJsonPath/$Script:BackupsPath move under
      FLAVORS-SPEC.md S3.1's flavours\<id>\ subfolder - only that one
      subfolder is ever created (by New-CliProcessArgs's underlying CLI
      call, or by this function's own on-demand creation just below), never
      every known flavour's. $Script:ClientBuildInfo is re-resolved against
      THIS flavour's own .build.info row so /api/state's clientBuild/
      clientInterface (and Get-AddonCompat's client-side comparison) are
      always that flavour's own values, not always retail's.
    #>
    param([string]$Flavor)

    if (-not $Flavor) { $Flavor = 'retail' }
    $Script:CurrentFlavour = $Flavor

    $flavourDir = Join-Path -Path (Join-Path -Path $Script:Root -ChildPath 'flavours') -ChildPath $Flavor
    $Script:AddonsJsonPath = Join-Path -Path $flavourDir -ChildPath 'addons.json'
    $Script:BackupsPath = Join-Path -Path $flavourDir -ChildPath 'backups'

    $buildInfoPath = $Script:BuildInfoPathOverride
    if (-not $buildInfoPath) {
        $buildInfoPath = Get-DefaultBuildInfoPath -AddonsPathResolved (Resolve-EffectiveAddonsPath -Flavor $Flavor)
    }
    $Script:ClientBuildInfo = Get-ClientBuildInfo -BuildInfoPath $buildInfoPath -Flavor $Flavor
}

function Get-FlavourUpdateAvailable {
    <# The mutable per-flavour {key: {fileId, version}} hashtable for -Flavor, creating an empty one on first touch. #>
    param([string]$Flavor)

    if (-not $Script:UpdateAvailableByFlavour.ContainsKey($Flavor)) {
        $Script:UpdateAvailableByFlavour[$Flavor] = @{}
    }
    return $Script:UpdateAvailableByFlavour[$Flavor]
}

function Get-FlavourLastRun {
    param([string]$Flavor)
    if ($Script:LastRunByFlavour.ContainsKey($Flavor)) { return $Script:LastRunByFlavour[$Flavor] }
    return $null
}

function Get-FlavourUpdatesCheckedAt {
    param([string]$Flavor)
    if ($Script:UpdatesCheckedAtByFlavour.ContainsKey($Flavor)) { return $Script:UpdatesCheckedAtByFlavour[$Flavor] }
    return $null
}

function Get-FlavourLastCheckFailed {
    param([string]$Flavor)
    if ($Script:LastCheckFailedByFlavour.ContainsKey($Flavor)) { return [bool]$Script:LastCheckFailedByFlavour[$Flavor] }
    return $false
}

function Get-FlavourLastCheckError {
    param([string]$Flavor)
    if ($Script:LastCheckErrorByFlavour.ContainsKey($Flavor)) { return $Script:LastCheckErrorByFlavour[$Flavor] }
    return $null
}

function Get-CurrentJobForFlavour {
    <# The single "current" (in-flight) job for -Flavor, or $null - FLAVORS-SPEC.md CS-F2 S5.4's per-flavour Test-JobBusy scoping. #>
    param([string]$Flavor)
    if ($Script:CurrentJobByFlavour.ContainsKey($Flavor)) { return $Script:CurrentJobByFlavour[$Flavor] }
    return $null
}

function Set-CurrentJobForFlavour {
    param([string]$Flavor, $Job)
    if ($null -eq $Job) {
        if ($Script:CurrentJobByFlavour.ContainsKey($Flavor)) { $Script:CurrentJobByFlavour.Remove($Flavor) }
    } else {
        $Script:CurrentJobByFlavour[$Flavor] = $Job
    }
}

function Clear-CurrentJobIfMatches {
    <# Clears the current-job slot for $Job's OWN flavour, but only if it still holds exactly this job (never clobbers a different, later job that may already have started for that same flavour). #>
    param($Job)
    if (-not $Job) { return }
    $existing = Get-CurrentJobForFlavour -Flavor $Job.flavour
    if ($existing -and $existing.id -eq $Job.id) {
        Set-CurrentJobForFlavour -Flavor $Job.flavour -Job $null
    }
}

# =====================================================================
# settings.json
# =====================================================================

function Get-DefaultSettings {
    return [PSCustomObject]@{
        releaseType        = 1
        autoUpdateOnLaunch = $true
        port               = 47831
        # E19: adFilter is the native host's (host\FurphyHost.exe) CurseForge-
        # tab ad/tracker filter toggle. Originally OFF by default per Eric's
        # explicit decision (SPEC E19); that decision was SUPERSEDED
        # 2026-09-04 by a later explicit Eric request (SPEC E22's "get rid of
        # cookie banner, and the other banner that appears on top, and
        # anything else other than the content, turn on ad block by default")
        # - the default is now ON. Existing installs are unaffected: this
        # only changes what a FRESH settings.json (or one missing the key)
        # gets - Get-Settings only ever falls back to this default when
        # $obj.adFilter is $null, so anyone who already has adFilter written
        # to disk (true or false) keeps that value untouched. hostWindow is
        # the host's last saved window bounds ({x,y,w,h}), written by
        # FurphyHost.cs itself via a direct read-modify-write of
        # settings.json (HostFiles.UpdateJsonObject) - this server only
        # needs to round-trip it through GET/PUT so a Settings PUT from the
        # web UI (releaseType, etc.) never clobbers it.
        adFilter           = $true
        # Round 16 (E22): cfFocus is the native host's CurseForge listing/
        # search "focus view" trim (hide site chrome + the left filter
        # sidebar, keep only the results column) - ON by default per Eric's
        # explicit ask (SPEC E22). Same round-trip pattern as adFilter:
        # read/validated/written the same way, and (as of 2026-09-04) both
        # default ON now.
        cfFocus            = $true
        hostWindow         = $null
        # Round 12 (E19b): the native host's LAST SAVED chrome/title-bar
        # palette - {name, colors:{bg0,bg1,...}} - same round-trip pattern as
        # hostWindow just above (the host writes it directly via
        # HostFiles.UpdateJsonObject, bypassing PUT /api/settings entirely;
        # this server only needs to not lose it on an unrelated settings
        # save). Unlike hostWindow, a PUT through this endpoint DOES validate
        # it - see Test-HostTheme - since unlike hostWindow's host-owned
        # opaque blob, this shape can also be reached by a client sending
        # arbitrary JSON to the API directly.
        hostTheme          = $null
        # Round 18 (tray stage B): the native host's background-updater
        # settings. These three keys are also read directly by
        # host\FurphyHost.cs's own TraySettingsReader (stage A, already
        # shipped) - this server round-trips them through the API/SPA the
        # same way adFilter/cfFocus are round-tripped, with the identical
        # default/clamp values TraySettingsReader already uses so both
        # readers of settings.json always agree. backgroundUpdates OFF by
        # default (Eric never asked for this to run unattended out of the
        # box); backgroundIntervalMinutes defaults to 120 (2 hours), clamped
        # 30..1440 on every write; runAtStartup OFF by default and
        # deliberately independent of backgroundUpdates - see
        # Handle-SettingsPut's comment and SPEC.md's tray section for the
        # "Start with Windows also turns background updates on" rule, which
        # lives in the SPA (ui\app.js), not here.
        backgroundUpdates          = $false
        backgroundIntervalMinutes  = 120
        runAtStartup               = $false
        # FLAVORS-SPEC.md CS-F2 S3.4: schemaVersion 2 is what
        # Invoke-FlavourMigration stamps once every existing top-level
        # addons.json/state.json/backups\ has landed under flavours\<id>\ -
        # a BRAND NEW install (no pre-existing settings.json at all) never
        # needs migrating, so it starts at 2 directly, never 1. activeFlavour
        # is a UI-continuity default only (S3.4 - "never consulted
        # server-side to decide what a data-mutating request means"), read
        # by Resolve-RequestFlavour's own non-flavour-scoped-endpoint
        # fallback and nowhere else; 'retail' here is just the shape's own
        # default value, not a claim that retail is installed - the actual
        # default flavour for an omitted ?flavour= is always computed live
        # (Get-DefaultFlavourId), never read from this field. showTestRealms
        # (S2.5) is the "Show test realms (PTR/Beta)" toggle, off by default.
        schemaVersion              = 2
        activeFlavour              = 'retail'
        showTestRealms             = $false
    }
}

function Save-Settings {
    param($Settings)

    $json = ConvertTo-Json -InputObject $Settings -Depth 5
    $tmpPath = "$Script:SettingsPath.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
    Move-Item -LiteralPath $tmpPath -Destination $Script:SettingsPath -Force
}

function Get-Settings {
    <# Reads settings.json, tolerating missing fields; creates it with defaults if absent. #>
    if (-not (Test-Path -LiteralPath $Script:SettingsPath)) {
        $defaults = Get-DefaultSettings
        try { Save-Settings -Settings $defaults } catch { Write-ServerLog "Failed to create settings.json: $($_.Exception.Message)" }
        return $defaults
    }

    try {
        # Get-Content is safe here: $raw is only ever fed into ConvertFrom-Json
        # below, never returned or JSON-serialized itself, so the PSPath/PSDrive/
        # PSProvider note properties Get-Content attaches to the string never reach
        # a response (ConvertFrom-Json's output is a fresh, undecorated object -
        # see Update-JobStatus for the pattern that actually is hazardous).
        $raw = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $defaults = Get-DefaultSettings
            Save-Settings -Settings $defaults
            return $defaults
        }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $result = Get-DefaultSettings
        if ($null -ne $obj.releaseType) { $result.releaseType = [int]$obj.releaseType }
        if ($null -ne $obj.autoUpdateOnLaunch) { $result.autoUpdateOnLaunch = [bool]$obj.autoUpdateOnLaunch }
        if ($null -ne $obj.port) { $result.port = [int]$obj.port }
        # E19: adFilter/hostWindow - see Get-DefaultSettings. hostWindow is
        # copied through as whatever object shape is on disk (the host owns
        # its contents); this server never inspects x/y/w/h itself.
        if ($null -ne $obj.adFilter) { $result.adFilter = [bool]$obj.adFilter }
        # Round 16 (E22): cfFocus - see Get-DefaultSettings.
        if ($null -ne $obj.cfFocus) { $result.cfFocus = [bool]$obj.cfFocus }
        if ($null -ne $obj.hostWindow) { $result.hostWindow = $obj.hostWindow }
        # Round 12 (E19b): hostTheme is copied through unvalidated on READ,
        # same as hostWindow just above - whatever shape is already on disk
        # (written either by the host directly, or by a prior validated PUT
        # through this server) round-trips as-is. Validation only happens on
        # the WRITE path (Handle-SettingsPut/Test-HostTheme) where it can
        # actually stop a bad value from being saved in the first place.
        if ($null -ne $obj.hostTheme) { $result.hostTheme = $obj.hostTheme }
        # Round 18 (tray stage B): backgroundUpdates/runAtStartup are plain
        # bool coercions, same pattern as adFilter/cfFocus above.
        # backgroundIntervalMinutes is clamped 30..1440 on READ too (not just
        # on the PUT path below) so a value hand-edited into settings.json,
        # or left over from a future build with a wider range, can never
        # reach the tray/SPA unclamped - matches
        # host\FurphyHost.cs's TraySettingsReader, which applies the same
        # clamp on every read for the same reason.
        if ($null -ne $obj.backgroundUpdates) { $result.backgroundUpdates = [bool]$obj.backgroundUpdates }
        if ($null -ne $obj.backgroundIntervalMinutes) {
            $interval = [int]$obj.backgroundIntervalMinutes
            if ($interval -lt 30) { $interval = 30 }
            if ($interval -gt 1440) { $interval = 1440 }
            $result.backgroundIntervalMinutes = $interval
        }
        if ($null -ne $obj.runAtStartup) { $result.runAtStartup = [bool]$obj.runAtStartup }
        # FLAVORS-SPEC.md CS-F2 S3.4: schemaVersion is normally stamped
        # directly by Invoke-FlavourMigration (a raw settings.json read/write,
        # bypassing this function entirely - same reason hostWindow/hostTheme
        # are host-written directly) rather than through Save-Settings, but
        # is still read through here like every other field so GET
        # /api/settings never has to special-case it. activeFlavour/
        # showTestRealms are plain pass-throughs, same pattern as adFilter/
        # cfFocus above.
        if ($null -ne $obj.schemaVersion) { $result.schemaVersion = [int]$obj.schemaVersion }
        if ($null -ne $obj.activeFlavour) { $result.activeFlavour = [string]$obj.activeFlavour }
        if ($null -ne $obj.showTestRealms) { $result.showTestRealms = [bool]$obj.showTestRealms }
        # Round 16 (E22, 2026-09-04, at Eric's explicit request): the
        # CurseForge API key feature is removed entirely. An existing
        # settings.json from before this round may still carry a stored
        # cfApiKey value - $result (built from Get-DefaultSettings, which no
        # longer has that property) never copies it over, so it is already
        # dropped from every in-memory settings object; this just also
        # rewrites the file on disk so it stops sitting there once and for
        # all. The key's value itself is never logged.
        $legacyKeyProp = Get-Member -InputObject $obj -Name 'cfApiKey' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($null -ne $legacyKeyProp) {
            try {
                Save-Settings -Settings $result
                Write-ServerLog 'Removed legacy cfApiKey from settings.json (CurseForge key feature removed 2026-09-04).'
            } catch {
                Write-ServerLog "Failed to rewrite settings.json while dropping legacy cfApiKey: $($_.Exception.Message)"
            }
        }
        return $result
    } catch {
        Write-ServerLog "Failed to read settings.json, using defaults: $($_.Exception.Message)"
        return Get-DefaultSettings
    }
}

function Get-SettingsView {
    <# settings.json, as returned by the settings API - no cfApiKey field
       exists any more (Round 16, E22: the CurseForge key feature was
       removed 2026-09-04 at Eric's explicit request). Round 17 removed
       checkAddonVersion the same way (Eric: "WoW's out-of-date warning...
       get rid of this it doesn't do anything") - see Get-DefaultSettings's
       own note and CHANGELOG.md's Round 17 section. #>
    param($Settings)

    return [PSCustomObject]@{
        releaseType        = $Settings.releaseType
        autoUpdateOnLaunch = $Settings.autoUpdateOnLaunch
        port               = $Script:Port
        addonsPath         = (Resolve-EffectiveAddonsPath)
        wowRoot            = (Get-WowRootPath)
        # E19: pass through unmasked (neither is a secret) - see
        # Get-DefaultSettings.
        adFilter          = $Settings.adFilter
        # Round 16 (E22): pass through unmasked, same as adFilter - not a
        # secret.
        cfFocus           = $Settings.cfFocus
        hostWindow        = $Settings.hostWindow
        # Round 12 (E19b): pass through unmasked, same as hostWindow - not a
        # secret, and the UI never displays it (only the native host reads
        # it, at startup, to paint the right chrome before the page loads).
        hostTheme         = $Settings.hostTheme
        # Round 18 (tray stage B): pass through unmasked, same as adFilter/
        # cfFocus - none of these three are secrets.
        backgroundUpdates         = $Settings.backgroundUpdates
        backgroundIntervalMinutes = $Settings.backgroundIntervalMinutes
        runAtStartup              = $Settings.runAtStartup
        # FLAVORS-SPEC.md CS-F2 S3.4/S5.2: pass through unmasked, same as
        # adFilter/cfFocus - none of these are secrets. schemaVersion is
        # informational only (never drives a client decision - S5.2's
        # installedFlavours/addons already carry everything the UI needs);
        # activeFlavour/showTestRealms are the two client-writable ones (see
        # Handle-SettingsPut).
        schemaVersion     = $Settings.schemaVersion
        activeFlavour     = $Settings.activeFlavour
        showTestRealms    = $Settings.showTestRealms
    }
}

function Test-HostTheme {
    <#
      Validates a hostTheme object per SPEC.md's E19b section: { name,
      colors }. name must be a 1-32 char lowercase-alnum-hyphen string;
      colors must be an object with at most 12 keys, every value a
      "#rrggbb" hex string. Returns $true/$false - used only by
      Handle-SettingsPut's write path (Get-Settings's read path above passes
      hostTheme through unvalidated, same as hostWindow, since by the time
      something is sitting in settings.json it already went through this
      check once, either here or - for the native host's own direct writes -
      was produced by the host's own getComputedStyle read of real CSS
      custom properties, not arbitrary input).
    #>
    param($Theme)

    if ($null -eq $Theme) { return $false }

    if ($null -eq $Theme.name) { return $false }
    $name = [string]$Theme.name
    if ($name.Length -lt 1 -or $name.Length -gt 32) { return $false }
    # -cnotmatch (case-SENSITIVE), not the bare -notmatch every other regex
    # check in this file uses - PowerShell's -match/-notmatch are
    # case-INSENSITIVE by default (confirmed live during this round's own
    # verification: "LofiNight" passed a plain -notmatch '^[a-z0-9-]+$'
    # check and got saved to settings.json), which would silently accept
    # any-case names despite the lowercase-only contract documented above
    # and in SPEC.md's E19b section.
    if ($name -cnotmatch '^[a-z0-9-]+$') { return $false }

    if ($null -eq $Theme.colors) { return $false }
    # Counted by hand (not @($Theme.colors.PSObject.Properties).Count) per
    # this file's standing @()-around-an-enumerable caution (see SPEC.md's
    # hard-constraints line) - a plain foreach never hits that class of
    # quirk regardless of the collection's runtime type.
    $colorCount = 0
    foreach ($p in $Theme.colors.PSObject.Properties) {
        $colorCount = $colorCount + 1
        if ($colorCount -gt 12) { return $false }
        $val = [string]$p.Value
        if ($val -notmatch '^#[0-9a-fA-F]{6}$') { return $false }
    }

    return $true
}

# =====================================================================
# addons.json (read-only here; addon-sync.ps1 owns writes)
# =====================================================================

function Get-AddonRecords {
    <#
      Returns a List[object] of addon records. Missing/empty/null file -> empty list.

      E10 fix (self-caught during this expansion's own offline verification):
      all three exit points used to `return $list` directly. A bare `return`
      of a collection goes through the pipeline, which PowerShell enumerates -
      for an EMPTY list that produces zero pipeline objects (the caller gets
      $null instead of an empty list), and for a list with EXACTLY ONE record
      it unwraps to that single record itself (the caller gets a bare
      PSCustomObject, not a list) - the same hazard class SPEC.md's
      List[object]/@() quirk describes, generalized to plain `return` of any
      enumerable. Every call site already in this file happens to use
      `foreach ($r in (Get-AddonRecords))`, which tolerates both cases by
      accident (foreach over $null runs zero times; foreach over a bare
      scalar runs once, treating it as that one item) - so this had no
      observable effect until Test-DiagAddonsJson's `.Count` usage (E10)
      exposed it directly: a tracked-addon count of exactly 1 produced
      "record.Count" as $null (PSCustomObject has no such property), not 1.
      Write-Output -NoEnumerate keeps the real List[object] intact through
      all three returns, matching the fix already applied to
      Get-PresentAddonFolders/Get-MissingDeps (E3) for the identical pattern.
    #>
    $list = New-Object 'System.Collections.Generic.List[object]'

    if (-not (Test-Path -LiteralPath $Script:AddonsJsonPath)) {
        Write-Output -NoEnumerate $list
        return
    }

    # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and is
    # never returned/serialized itself, so its PSPath/PSDrive/PSProvider note
    # properties never reach a JSON response (see Update-JobStatus for the
    # pattern that actually hangs Send-Json).
    $raw = Get-Content -LiteralPath $Script:AddonsJsonPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Output -NoEnumerate $list
        return
    }

    $tmp = $raw | ConvertFrom-Json -ErrorAction Stop
    $parsed = @($tmp)
    foreach ($item in $parsed) {
        if ($null -ne $item) {
            $list.Add($item)
        }
    }
    Write-Output -NoEnumerate $list
}

# =====================================================================
# Path resolution (mirrors addon-sync.ps1 Resolve-AddonsPath, for display)
# =====================================================================

function Resolve-EffectiveAddonsPath {
    <#
      FLAVORS-SPEC.md S4.2/CS-F2: gains -Flavor (default $Script:CurrentFlavour,
      itself defaulting to 'retail' - see Set-CurrentFlavourContext), mirroring
      addon-sync.ps1's identical Resolve-AddonsPath parameterization. The
      -Root-parent walk-up is generalized from "leaf must equal _retail_" to
      "leaf must be one of the six known flavour folder names"
      ($Script:FlavourFolderSet) - this machine's own default call (-Flavor
      omitted -> 'retail') resolves byte-identically to before, since
      _retail_ is one of those six names. $Script:WowRootOverride (-WowRoot),
      when set, is used directly instead of walking up from -Root at all -
      the same fixture-testing override addon-sync.ps1's own -WowRoot gives.
      -AddonsPathOverride (this script's own -AddonsPath) still wins outright
      over everything, unchanged.
    #>
    param([string]$Flavor)

    if ($Script:AddonsPathOverride) {
        return $Script:AddonsPathOverride
    }

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }
    $def = Get-FlavourDef -Id $Flavor
    if (-not $def) { return $null }

    $resolvedWowRoot = $Script:WowRootOverride
    if (-not $resolvedWowRoot -or $resolvedWowRoot.Trim().Length -eq 0) {
        $leaf = Split-Path -Path $Script:Root -Leaf
        $parentDir = Split-Path -Path $Script:Root -Parent
        if (($leaf -eq 'AddonSync') -and $parentDir) {
            $parentLeaf = Split-Path -Path $parentDir -Leaf
            if ($Script:FlavourFolderSet.Contains($parentLeaf)) {
                $resolvedWowRoot = Split-Path -Path $parentDir -Parent
            }
        }
    }

    if (-not $resolvedWowRoot) {
        return $null
    }

    return Join-Path -Path (Join-Path -Path $resolvedWowRoot -ChildPath $def.Folder) -ChildPath 'Interface\AddOns'
}

function Get-WowRootPath {
    <#
      UNCHANGED return semantics from before this change set - despite the
      name, this returns the FLAVOUR's own folder (e.g. <WowRoot>\_retail_),
      one level above Interface\AddOns's parent - NOT the true grandparent
      <WowRoot> (see Get-FlavourWowRootPath below for that). Kept exactly as
      it was (byte-identical for -Flavor 'retail'/omitted, per this feature's
      non-negotiable "zero behavior change at n=1" bar) - Get-SettingsView's
      existing `wowRoot` field must not change shape for a single-flavour
      machine. Now flavour-aware via Resolve-EffectiveAddonsPath's own
      -Flavor param, for future multi-flavour callers.
    #>
    param([string]$Flavor)

    $addonsPath = Resolve-EffectiveAddonsPath -Flavor $Flavor
    if (-not $addonsPath) {
        return $null
    }
    try {
        $interfaceDir = Split-Path -Path $addonsPath -Parent
        $flavourDir = Split-Path -Path $interfaceDir -Parent
        return $flavourDir
    } catch {
        return $null
    }
}

function Get-FlavourWowRootPath {
    <# The true <WowRoot> (three levels above Interface\AddOns - the folder that would contain _retail_/_classic_/etc side by side). $null when unresolvable. #>
    param([string]$Flavor)

    $flavourDir = Get-WowRootPath -Flavor $Flavor
    if (-not $flavourDir) { return $null }
    try {
        return (Split-Path -Path $flavourDir -Parent)
    } catch {
        return $null
    }
}

# E13 (compatibility audit): mirrors addon-sync.ps1's identical function -
# see its own doc comment for why .build.info sits three levels above
# <root>\_retail_\Interface\AddOns.
function Get-DefaultBuildInfoPath {
    param([string]$AddonsPathResolved)

    if (-not $AddonsPathResolved) { return $null }
    try {
        $interfaceDir = Split-Path -Path $AddonsPathResolved -Parent
        if (-not $interfaceDir) { return $null }
        $retailDir = Split-Path -Path $interfaceDir -Parent
        if (-not $retailDir) { return $null }
        $wowRootDir = Split-Path -Path $retailDir -Parent
        if (-not $wowRootDir) { return $null }
        return Join-Path -Path $wowRootDir -ChildPath '.build.info'
    } catch {
        return $null
    }
}

# =====================================================================
# Dependencies (E3) - live missingDeps for /api/state, mirroring
# addon-sync.ps1's Get-AddonsFolderSet/Get-MissingDeps (this script is
# always launched standalone, never dot-sources the CLI, so the small
# amount of logic is duplicated the same way Resolve-EffectiveAddonsPath
# already mirrors Resolve-AddonsPath above).
# =====================================================================

function Get-PresentAddonFolders {
    <#
      Case-insensitive set of every top-level AddOns folder name currently on
      disk (lowercased). Empty set (never throws) when the AddOns path can't
      be resolved or doesn't exist yet. Uses -NoEnumerate: a HashSet is
      IEnumerable, so a bare "return $set" on an EMPTY set would enumerate to
      zero pipeline objects and the caller's assignment would silently
      receive $null instead of the set itself (the same class of hazard the
      List[object] quirk documents, generalized to any enumerable collection
      type) - reproduced directly: Get-MissingDeps's Mandatory PresentFolders
      parameter threw "Cannot bind argument ... because it is null" the
      moment this ran against an unresolvable AddOns path (empty set).
    #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $addonsPath = Resolve-EffectiveAddonsPath
    if ($addonsPath -and (Test-Path -LiteralPath $addonsPath -PathType Container)) {
        $dirs = Get-ChildItem -LiteralPath $addonsPath -Force -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) { [void]$set.Add($d.Name.ToLowerInvariant()) }
    }
    Write-Output -NoEnumerate $set
}

function Get-MissingDeps {
    <# Entries of $DepNames not present (case-insensitively) in $PresentFolders. #>
    param($DepNames, $PresentFolders)

    $missing = New-Object 'System.Collections.Generic.List[object]'
    foreach ($dep in @($DepNames)) {
        if (-not $dep) { continue }
        if (-not $PresentFolders.Contains(([string]$dep).ToLowerInvariant())) {
            $missing.Add($dep)
        }
    }
    Write-Output -NoEnumerate $missing
}

# =====================================================================
# Compatibility audit (E13) - mirrors addon-sync.ps1's identical functions
# (Split-TocDepList / Get-TocInterfaceValues / Get-PackageTocInterfaces /
# Get-AddonCompat / Get-ClientBuildInfo) - this script never dot-sources the
# CLI, same duplication pattern already used for Resolve-EffectiveAddonsPath/
# Get-PresentAddonFolders/Get-MissingDeps above. See the CLI's own doc
# comments for the full rationale; kept terse here.
# =====================================================================

function Split-TocDepList {
    <# Splits one toc tag's comma- or space-separated value into pieces; blank pieces dropped; tolerates $null/empty. #>
    param([string]$Value)

    $result = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Value) {
        Write-Output -NoEnumerate $result
        return
    }
    $pieces = $null
    if ($Value.IndexOf(',') -ge 0) { $pieces = $Value -split ',' } else { $pieces = $Value -split '\s+' }
    foreach ($piece in $pieces) {
        $trimmed = $piece.Trim()
        if ($trimmed.Length -gt 0) { $result.Add($trimmed) }
    }
    Write-Output -NoEnumerate $result
}

function Get-PrimaryTocFile {
    <#
      Duplicate of addon-sync.ps1's identically-named function (this script
      never dot-sources the CLI) - picks the .toc file one flavour/era
      actually loads for an installed folder, out of however many game-
      flavor variants a package ships in the same folder.

      FLAVORS-SPEC.md S4.5/CS-F2: gains -Flavor (default 'retail') and
      -InstalledInterface (consulted only when -Flavor is 'classic', to
      resolve which rolling-progression era's .toc to prefer, S2.4).
      Selection order, primary signal first:
        1. Any .toc in the folder carrying "## X-Flavor: <Tag>" whose value
           matches the target flavour/era's tag - authoritative wherever
           present, regardless of filename.
        2. The target flavour/era's filename-suffix table
           ($Script:TocEraSelectors), in try-order.
        3. Bare "<FolderName>.toc" - owned by whichever of the three groups
           (Retail / Classic Era / Classic's rolling progression) is the SOLE
           one with no suffixed file present in this folder; bare defaults to
           Retail whenever that is not exactly one group (S4.5's caveat).
        4. First .toc file found (today's last-resort, unchanged).
      Returns a FileInfo, or $null when the folder has no .toc file at all.
      Never throws. Byte-identical to the pre-flavour selection for every
      existing retail call site (-Flavor defaults to 'retail').
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $tocFiles = Get-ChildItem -LiteralPath $FolderPath -Filter '*.toc' -File -ErrorAction SilentlyContinue
    if (-not $tocFiles) {
        return $null
    }

    $eraKey = Resolve-TocEraKey -Flavor $Flavor -InstalledInterface $InstalledInterface
    $selector = $Script:TocEraSelectors[$eraKey]
    if (-not $selector) {
        # No real selector row for this era (e.g. an unrecognized future
        # Classic-progression Interface range) - do NOT fall back to the
        # Retail selector here, or an unrecognized Classic client would
        # silently prefer a Retail-tagged/suffixed file over the correct
        # Classic one in steps 1-2. Use a selector that can never match so
        # selection falls through to step 3's bare-file group logic (which
        # already folds 'unknown' into the 'classic' group correctly) and
        # then step 4's first-found fallback.
        $selector = [PSCustomObject]@{ XFlavorTag = $null; Suffixes = @() }
    }

    # 1. X-Flavor tag - authoritative wherever present.
    foreach ($t in $tocFiles) {
        $tag = Get-TocXFlavorTag -TocPath $t.FullName
        if ($tag -and ($tag -eq $selector.XFlavorTag)) {
            return $t
        }
    }

    # 2. Filename-suffix table for the target flavour/era. Built with -f
    # rather than "$FolderName_Mainline.toc" - PowerShell would parse the
    # latter as the variable ${FolderName_Mainline} (underscore is a valid
    # identifier character), not $FolderName followed by literal text.
    foreach ($suffix in $selector.Suffixes) {
        $preferredName = '{0}{1}.toc' -f $FolderName, $suffix
        foreach ($t in $tocFiles) {
            if ($t.Name -eq $preferredName) {
                return $t
            }
        }
    }

    # 3. Bare "<FolderName>.toc" - S4.5's caveat, implemented exactly: build
    # the suffix-to-flavour map for the THREE first-class groups (Retail;
    # Classic Era; Classic's rolling progression collapsed into one group),
    # scan which groups have a matching suffixed file present in THIS
    # folder, and only attribute the bare file to a non-retail group when it
    # is the SOLE unclaimed one of the three - else bare always means retail.
    $bareGroupClaimed = @{
        'retail'      = $false
        'classic_era' = $false
        'classic'     = $false
    }
    foreach ($otherKey in $Script:TocEraSelectors.Keys) {
        $group = 'classic'
        if ($otherKey -eq 'retail') { $group = 'retail' }
        elseif ($otherKey -eq 'classic_era') { $group = 'classic_era' }
        $otherSelector = $Script:TocEraSelectors[$otherKey]
        foreach ($suffix in $otherSelector.Suffixes) {
            $otherName = '{0}{1}.toc' -f $FolderName, $suffix
            foreach ($t in $tocFiles) {
                if ($t.Name -eq $otherName) { $bareGroupClaimed[$group] = $true }
            }
        }
    }
    $unclaimedGroups = @($bareGroupClaimed.Keys | Where-Object { -not $bareGroupClaimed[$_] })
    $bareOwnerGroup = 'retail'
    if ($unclaimedGroups.Count -eq 1) {
        $bareOwnerGroup = $unclaimedGroups[0]
    }
    $targetGroup = 'classic'
    if ($eraKey -eq 'retail') { $targetGroup = 'retail' }
    elseif ($eraKey -eq 'classic_era') { $targetGroup = 'classic_era' }
    if ($bareOwnerGroup -eq $targetGroup) {
        $bareName = '{0}.toc' -f $FolderName
        foreach ($t in $tocFiles) {
            if ($t.Name -eq $bareName) {
                return $t
            }
        }
    }

    # 4. First .toc found - today's last-resort, unchanged.
    foreach ($t in $tocFiles) { return $t }
    return $null
}

function Get-TocInterfaceValues {
    <#
      Reads "## Interface:"/"## Interface-Mainline:" from one folder's
      primary .toc (Get-PrimaryTocFile's Mainline-first selection) into
      int64s. Never throws; empty list when unavailable. -AddonsPath is not
      Mandatory (Handle-State can reach here with an unresolvable AddOns
      path, $null - a Mandatory [string] parameter rejects an explicit
      $null argument outright, distinct from simply omitting it, rather
      than degrading gracefully).

      Fix pass: when the chosen file has any "## Interface-Mainline:"
      line(s), those win outright and plain "## Interface:" line(s) in that
      same file are ignored (they describe a different client's build, not
      an additional retail value to union in) - see addon-sync.ps1's
      identical function for the full rationale.
    #>
    param(
        [string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $result = New-Object 'System.Collections.Generic.List[object]'
    if (-not $AddonsPath) {
        Write-Output -NoEnumerate $result
        return
    }
    $folderPath = Join-Path -Path $AddonsPath -ChildPath $FolderName
    if (-not (Test-Path -LiteralPath $folderPath)) {
        Write-Output -NoEnumerate $result
        return
    }
    $chosen = Get-PrimaryTocFile -FolderPath $folderPath -FolderName $FolderName -Flavor $Flavor -InstalledInterface $InstalledInterface
    if (-not $chosen) {
        Write-Output -NoEnumerate $result
        return
    }
    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $chosen.FullName -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Output -NoEnumerate $result
        return
    }
    $mainlineValues = New-Object 'System.Collections.Generic.List[object]'
    $plainValues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        if (($Flavor -eq 'retail') -and ($line -match '^\s*##\s*Interface-Mainline\s*:\s*(.*)$')) {
            foreach ($piece in (Split-TocDepList -Value $Matches[1])) {
                $ival = [int64]0
                if ([int64]::TryParse($piece, [ref]$ival)) { $mainlineValues.Add([int64]$ival) }
            }
        } elseif ($line -match '^\s*##\s*Interface\s*:\s*(.*)$') {
            foreach ($piece in (Split-TocDepList -Value $Matches[1])) {
                $ival = [int64]0
                if ([int64]::TryParse($piece, [ref]$ival)) { $plainValues.Add([int64]$ival) }
            }
        }
    }
    if ($mainlineValues.Count -gt 0) {
        foreach ($v in $mainlineValues) { $result.Add($v) }
    } else {
        foreach ($v in $plainValues) { $result.Add($v) }
    }
    Write-Output -NoEnumerate $result
}

function Get-PackageTocInterfaces {
    <# Unions Get-TocInterfaceValues across every folder of a record, deduped. #>
    param($AddonsPath, $Folders, [string]$Flavor = 'retail', $InstalledInterface = $null)

    $seen = New-Object 'System.Collections.Generic.HashSet[int64]'
    $result = New-Object 'System.Collections.Generic.List[object]'
    # Plain foreach, not @($Folders) - matches the CLI's identical function
    # exactly (see its own note on the machine's List[object]/@() quirk);
    # $Folders is a JSON-parsed record property here (never a List[object]
    # in practice), but there is no reason to risk it.
    foreach ($folderName in $Folders) {
        foreach ($v in (Get-TocInterfaceValues -AddonsPath $AddonsPath -FolderName $folderName -Flavor $Flavor -InstalledInterface $InstalledInterface)) {
            if ($seen.Add([int64]$v)) { $result.Add([int64]$v) }
        }
    }
    Write-Output -NoEnumerate $result
}

function Get-AddonCompat {
    <# ok / stale-minor / stale / unknown - see addon-sync.ps1's Get-AddonCompat for the full contract. #>
    param($TocInterfaces, $LatestGameVersions, $ClientInterface)

    if (-not $ClientInterface) { return 'unknown' }
    $clientInterfaceInt = [int64]$ClientInterface
    $clientMajor = [int]([math]::Floor($clientInterfaceInt / 10000))
    $clientMinor = [int]([math]::Floor(($clientInterfaceInt % 10000) / 100))
    $clientPatch = [int]($clientInterfaceInt % 100)
    $clientVersionText = "$clientMajor.$clientMinor.$clientPatch"

    $hasEvidence = $false
    $sameMajor = $false

    # Plain foreach, not @($TocInterfaces) - the machine's documented quirk:
    # @() wrapped around a List[object] (TocInterfaces is exactly that, from
    # Get-PackageTocInterfaces) throws "Argument types do not match".
    foreach ($iface in $TocInterfaces) {
        if ($null -eq $iface) { continue }
        $ifaceInt = [int64]0
        if (-not [int64]::TryParse([string]$iface, [ref]$ifaceInt)) { continue }
        $hasEvidence = $true
        if ($ifaceInt -eq $clientInterfaceInt) { return 'ok' }
        $ifaceMajor = [int]([math]::Floor($ifaceInt / 10000))
        if ($ifaceMajor -eq $clientMajor) { $sameMajor = $true }
    }

    foreach ($gv in $LatestGameVersions) {
        if (-not $gv) { continue }
        $gvText = ([string]$gv).Trim()
        if ($gvText.Length -eq 0) { continue }
        $hasEvidence = $true
        if ($gvText -eq $clientVersionText) { return 'ok' }
        $gvParts = $gvText -split '\.'
        if ($gvParts.Count -ge 1) {
            $gvMajor = 0
            if ([int]::TryParse($gvParts[0], [ref]$gvMajor) -and ($gvMajor -eq $clientMajor)) { $sameMajor = $true }
        }
    }

    if (-not $hasEvidence) { return 'unknown' }
    if ($sameMajor) { return 'stale-minor' }
    return 'stale'
}

function Get-ClientBuildInfo {
    <#
      Reads .build.info's row matching -Product (or, when omitted, -Flavor's
      own S2.1 mapping - 'wow' for retail, unchanged from today's hardcode)
      -> {clientBuild; clientInterface}. FLAVORS-SPEC.md S4.3/CS-F2: gains
      -Flavor (default 'retail') and -Product, mirroring addon-sync.ps1's
      identical function. Never throws.
    #>
    param(
        [string]$BuildInfoPath,
        [string]$Flavor = 'retail',
        [string]$Product
    )

    $result = [PSCustomObject]@{ clientBuild = $null; clientInterface = $null }
    if (-not $BuildInfoPath -or -not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf)) {
        return $result
    }

    $expectedProduct = $Product
    if (-not $expectedProduct) {
        $def = Get-FlavourDef -Id $Flavor
        if ($def) { $expectedProduct = $def.Product } else { $expectedProduct = 'wow' }
    }

    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $BuildInfoPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $result
    }
    if (-not $lines -or $lines.Count -lt 2) { return $result }

    $headerCols = $lines[0] -split '\|'
    $versionIdx = -1
    $productIdx = -1
    for ($i = 0; $i -lt $headerCols.Count; $i++) {
        $colName = ($headerCols[$i] -split '!')[0].Trim()
        if ($colName -eq 'Version') { $versionIdx = $i }
        if ($colName -eq 'Product') { $productIdx = $i }
    }
    if ($versionIdx -lt 0 -or $productIdx -lt 0) { return $result }

    for ($r = 1; $r -lt $lines.Count; $r++) {
        $line = $lines[$r]
        if (-not $line -or $line.Trim().Length -eq 0) { continue }
        $cols = $line -split '\|'
        if ($cols.Count -le $productIdx -or $cols.Count -le $versionIdx) { continue }
        if ($cols[$productIdx].Trim() -eq $expectedProduct) {
            $versionText = $cols[$versionIdx].Trim()
            $result.clientBuild = $versionText
            $result.clientInterface = ConvertTo-InterfaceNumber -VersionText $versionText
            break
        }
    }
    return $result
}

# =====================================================================
# Jobs: CLI process management
# =====================================================================

function New-JobId {
    $Script:JobIdSeq = $Script:JobIdSeq + 1
    return [string]$Script:JobIdSeq
}

function Add-JobToHistory {
    param($Job)

    $Script:Jobs.Add($Job)
    while ($Script:Jobs.Count -gt 20) {
        $Script:Jobs.RemoveAt(0)
    }
}

function Build-CliArgs {
    <# Maps a job kind + params object to addon-sync.ps1 arguments (excluding -Json/-AddonsPath). #>
    param(
        [string]$Kind,
        $Params
    )

    $argsList = New-Object 'System.Collections.Generic.List[object]'
    switch ($Kind) {
        'sync' {
            if ($Params -and $Params.ids -and @($Params.ids).Count -gt 0) {
                # NOTE: addon-sync.ps1 is invoked as a brand-new "powershell.exe
                # -File ..." child process (Start-Process), never in-process. In
                # that external -File invocation mode, Windows PowerShell 5.1's
                # own argument binder does NOT collect multiple space-separated
                # bare tokens into one array-typed parameter the way an
                # in-process call ("& $script -Only 1 2 3") does - only the
                # FIRST token binds to -Only, and any further tokens spill over
                # as positional values for whichever parameter comes next,
                # silently (no error, no log line) instead of being included
                # in the sync. addon-sync.ps1's own -Only/-Add/-Remove/-Unpin/
                # -Ignore/-Unignore parameters are therefore declared
                # [string[]] and re-split on commas internally
                # (ConvertTo-ExpandedStringArray/ConvertTo-ExpandedIdArray) so
                # that a SINGLE comma-joined token like "111,222,333" - which
                # DOES survive -File binding intact as one literal string -
                # works correctly. So multiple ids must be joined into one
                # comma-separated -Only token here, never passed as separate
                # -ArgumentList elements.
                $idStrings = New-Object 'System.Collections.Generic.List[object]'
                foreach ($id in @($Params.ids)) { $idStrings.Add([string]$id) }
                $argsList.Add('-Only')
                $argsList.Add(($idStrings -join ','))
            }
            if ($Params -and $Params.force) {
                $argsList.Add('-Force')
            }
        }
        'check' {
            $argsList.Add('-DryRun')
        }
        'add' {
            # E18: the first-run Welcome dialog's "Adopt all" button (and,
            # equivalently, install.ps1's own bulk adoption of pre-existing
            # untracked folders) posts projectIds - an array of ALREADY
            # fully-formed target tokens (a bare numeric CurseForge id, or a
            # "wago:<slug-or-id>" string; addon-sync.ps1's own -Add
            # classifier tells the two apart) - instead of a single
            # projectId. Same "one comma-joined -Add token" pattern as the
            # 'remove' case's bulk projectIds above (only a single
            # comma-joined token survives -File binding intact - see that
            # case's comment). FileId is meaningless for a multi-target add
            # (which target would it apply to?), so it is only honoured on
            # the single-projectId path below.
            if ($Params -and $Params.projectIds -and @($Params.projectIds).Count -gt 0) {
                $ids = New-Object 'System.Collections.Generic.List[object]'
                foreach ($id in @($Params.projectIds)) { $ids.Add([string]$id) }
                $argsList.Add('-Add')
                $argsList.Add(($ids -join ','))
            } elseif ($Params -and $Params.projectId) {
                $argsList.Add('-Add')
                $argsList.Add([string]$Params.projectId)
                if ($Params.fileId) {
                    $argsList.Add('-FileId')
                    $argsList.Add([string]$Params.fileId)
                }
            } else {
                throw 'projectId or projectIds is required for kind add'
            }
        }
        'remove' {
            # E11 (bulk actions): the My Addons selection bar's "Uninstall
            # selected" posts projectIds (an array, possibly length 1);
            # every existing single-id caller (the per-row kebab menu) still
            # posts the original singular projectId, which keeps working
            # unchanged. Multiple ids are comma-joined into ONE -Remove
            # token here, same reasoning as the 'sync' case above (only a
            # single comma-joined token survives -File binding intact).
            $ids = New-Object 'System.Collections.Generic.List[object]'
            if ($Params -and $Params.projectIds -and @($Params.projectIds).Count -gt 0) {
                foreach ($id in @($Params.projectIds)) { $ids.Add([string]$id) }
            } elseif ($Params -and $Params.projectId) {
                $ids.Add([string]$Params.projectId)
            }
            if ($ids.Count -eq 0) {
                throw 'projectId or projectIds is required for kind remove'
            }
            $argsList.Add('-Remove')
            $argsList.Add(($ids -join ','))
        }
        'install' {
            if (-not ($Params -and $Params.projectId -and $Params.fileId)) {
                throw 'projectId and fileId are required for kind install'
            }
            $argsList.Add('-Only')
            $argsList.Add([string]$Params.projectId)
            $argsList.Add('-FileId')
            $argsList.Add([string]$Params.fileId)
        }
        'rollback' {
            if (-not ($Params -and $Params.projectId)) {
                throw 'projectId is required for kind rollback'
            }
            $argsList.Add('-Rollback')
            $argsList.Add([string]$Params.projectId)
        }
        default {
            throw "Unknown job kind: $Kind"
        }
    }

    Write-Output -NoEnumerate $argsList
}

function ConvertTo-SafeProcessArg {
    <#
      Round 20 (adversarial bug pass, server-1): wraps a single command-line
      argument in double quotes using CommandLineToArgvW-compatible
      backslash/quote escaping, so a value containing a literal space (e.g.
      an attacker-supplied projectId of "1 -Remove 999") can never be
      re-split into extra argv tokens by the child process - Windows
      PowerShell 5.1's Start-Process -ArgumentList joins array elements with
      a bare, unquoted space before handing them to CreateProcess, so an
      un-quoted element containing a space is indistinguishable from two
      separate arguments once it reaches the child. Every element handed to
      New-CliProcessArgs's $psArgs list is now passed through this (not just
      the two or three that used to be hand-quoted for containing paths with
      spaces), closing the same hole for every CLI argument, not just paths.
    #>
    param([string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2 + 1)) } else { [void]$sb.Append('\') }
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function New-CliProcessArgs {
    <#
      Full powershell.exe argument list for one addon-sync.ps1 invocation.
      -ProgressPath (CS1) is optional and, when supplied, threads straight
      through to addon-sync.ps1's own -ProgressPath param - see Start-Job,
      the only caller that ever passes it (sync/check/add/install job kinds
      per UX-SPEC.md section 4.2; every other caller of this function omits
      it, and addon-sync.ps1 already no-ops cleanly when it is absent).

      FLAVORS-SPEC.md CS-F2: gains -Flavor (default $Script:CurrentFlavour,
      the request currently in flight - see Set-CurrentFlavourContext),
      threaded straight through to addon-sync.ps1's own -Flavor param -
      every CLI invocation this server makes (jobs AND the synchronous
      fast-ops via Invoke-Cli) is now flavour-scoped, matching whichever
      flavour the caller resolved via Resolve-RequestFlavour. Also threads
      -WowRoot when this server was itself pointed at a fixture
      ($Script:WowRootOverride, CS-F2's own -WowRoot) so the CLI child
      process resolves against the SAME fixture, never the real WoW folder.
      -Flavor 'retail' is never sent explicitly (it's the CLI's own
      default) so a single-flavour machine's CLI invocations are
      byte-identical to before this change set.
    #>
    param(
        [System.Collections.Generic.List[object]]$CliArgs,
        [string]$ProgressPath,
        [string]$Flavor
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }

    $psArgs = New-Object 'System.Collections.Generic.List[object]'
    $psArgs.Add('-NoProfile')
    $psArgs.Add('-ExecutionPolicy')
    $psArgs.Add('Bypass')
    # Round 20 (adversarial bug pass, server-1): every element below is now
    # quoted via ConvertTo-SafeProcessArg, not just the paths that used to be
    # hand-quoted here - Start-Process joins -ArgumentList elements with a
    # bare, unquoted space, so ANY element containing a space (a path, or an
    # attacker-supplied projectId/fileId flowing through $CliArgs) could
    # otherwise be re-split into extra argv tokens by the child process.
    $psArgs.Add('-File')
    $psArgs.Add((ConvertTo-SafeProcessArg $Script:CliPath))
    foreach ($a in $CliArgs) { $psArgs.Add((ConvertTo-SafeProcessArg ([string]$a))) }
    $psArgs.Add('-Json')
    if ($Script:AddonsPathOverride) {
        $psArgs.Add('-AddonsPath')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:AddonsPathOverride))
    }
    if ($Flavor -and $Flavor -ne 'retail') {
        $psArgs.Add('-Flavor')
        $psArgs.Add((ConvertTo-SafeProcessArg $Flavor))
    }
    if ($Script:WowRootOverride) {
        $psArgs.Add('-WowRoot')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:WowRootOverride))
    }
    if ($ProgressPath) {
        $psArgs.Add('-ProgressPath')
        $psArgs.Add((ConvertTo-SafeProcessArg $ProgressPath))
    }
    Write-Output -NoEnumerate $psArgs
}

function Test-JobBusy {
    <#
      True (and, if -Context given, writes a 409 busy response) when a job is
      currently running FOR -Flavor (default $Script:CurrentFlavour - the
      request currently in flight, per Set-CurrentFlavourContext).
      FLAVORS-SPEC.md CS-F2 S5.4: scoped per flavour, not global - a Retail
      sync and a Classic Era sync may run concurrently; two Retail syncs
      still can't (the per-flavour slot Get-CurrentJobForFlavour reads
      already enforces that on its own). Refreshes the current job's state
      first so a job that just finished is not reported busy.
    #>
    param($Context, [string]$Flavor)

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $current = Get-CurrentJobForFlavour -Flavor $Flavor
    if ($current -and $current.state -eq 'running') {
        Update-JobStatus -Job $current | Out-Null
    }
    $current = Get-CurrentJobForFlavour -Flavor $Flavor
    if ($current -and $current.state -eq 'running') {
        if ($Context) {
            Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $current.id }
        }
        return $true
    }
    return $false
}

function Start-Job {
    <#
      Starts one job (spec section 2, "Jobs" table) for the flavour named by
      -Flavor (default $Script:CurrentFlavour, per FLAVORS-SPEC.md CS-F2
      S5.4's job.flavour field). Returns a hashtable:
        Busy  = $true  -> a job is already running for that flavour (Job holds it)
        Error = <text> -> could not start (bad params, process launch failed)
        Job   = <job>  -> started (or, for launch/no-update, already finished)
    #>
    param(
        [string]$Kind,
        $Params,
        [string]$Flavor,
        # FLAVORS-SPEC.md CS-F3 S5.5: true only when the CALLER'S request
        # named an explicit ?flavour=/?flavor= (Handle-JobsPost's own
        # Get-QueryFlavour read, threaded through here) - NOT whether
        # -Flavor itself is non-empty, since -Flavor is always resolved to
        # something (the request's default/active flavour) by the time
        # Start-Job is called. An explicit flavour always wins outright, no
        # ambiguity re-check (principle 5); an omitted one is what lets the
        # CurseForge install-flavour resolution below engage at all.
        [bool]$FlavourExplicit = $false
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    if (Test-JobBusy -Flavor $Flavor) {
        return @{ Busy = $true; Job = (Get-CurrentJobForFlavour -Flavor $Flavor) }
    }

    # FLAVORS-SPEC.md CS-F3: remembered so the CurseForge install-flavour
    # resolution below (which can reassign $Flavor to the one flavour that
    # actually matches) can re-check Test-JobBusy for the NEW flavour - the
    # busy check just above only ever covered the flavour this request
    # originally defaulted/resolved to.
    $originalRequestFlavor = $Flavor

    $jobId = New-JobId
    $startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # launch with updateFirst=false needs no CLI process: just start the game.
    $updateFirst = [bool]($Params -and $Params.updateFirst)
    if ($Kind -eq 'launch' -and (-not $updateFirst)) {
        $job = [PSCustomObject]@{
            id            = $jobId
            kind          = 'launch'
            params        = $Params
            state         = 'running'
            startedAt     = $startedAt
            finishedAt    = $null
            exitCode      = $null
            log           = New-Object 'System.Collections.Generic.List[object]'
            results       = New-Object 'System.Collections.Generic.List[object]'
            error         = $null
            # FLAVORS-SPEC.md CS-F2 S5.4: every job carries its own flavour.
            flavour       = $Flavor
            Process       = $null
            OutFile       = $null
            ErrFile       = $null
            SyncLogOffset = 0
            LaunchAfter   = $false
        }
        Add-JobToHistory -Job $job
        Set-CurrentJobForFlavour -Flavor $Flavor -Job $job
        try {
            Start-Process -FilePath 'C:\Program Files (x86)\Battle.net\Battle.net.exe' -ArgumentList '--exec="launch WoW"' | Out-Null
            $job.results.Add([PSCustomObject]@{ status = 'Launched'; name = 'World of Warcraft' })
            $job.state = 'done'
            $job.exitCode = 0
        } catch {
            $job.state = 'failed'
            $job.error = $_.Exception.Message
        }
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-CurrentJobForFlavour -Flavor $Flavor -Job $null
        # Round 3: this synchronous launch-without-update path completes
        # entirely within this function and never goes through
        # Update-JobStatus (there is no CLI child process behind it, so
        # nothing to poll/tail), so it needs its own persistence call to
        # land in state.json's job history like every other finished job.
        Save-CheckState
        return @{ Busy = $false; Job = $job }
    }

    # E4: import can take anywhere from zero to several addon-sync.ps1
    # invocations chained in sequence (see Build-ImportPlan) rather than the
    # exactly-one-CLI-call shape every kind below assumes, so it is built and
    # started entirely by its own helper instead of falling through to
    # Build-CliArgs/New-CliProcessArgs here.
    if ($Kind -eq 'import') {
        return (Start-ImportJob -JobId $jobId -StartedAt $startedAt -Params $Params -Flavor $Flavor)
    }

    # E12: switch-source (uninstall the tracked addon, then add it fresh from
    # the OTHER source) is, like import, a multi-phase job - see
    # Start-SwitchSourceJob/Complete-SwitchSourcePhase.
    if ($Kind -eq 'switch-source') {
        return (Start-SwitchSourceJob -JobId $jobId -StartedAt $startedAt -Params $Params -Flavor $Flavor)
    }

    # E19: add-by-slug {slug, fileId?} - the native host's CurseForge-tab
    # install-link interception knows only the URL slug, never the numeric
    # projectId, so resolve it here (an in-memory dictionary/linear-scan
    # lookup against the same keyless catalogue index /api/cf/browse and
    # /api/cf/enrich already use - no network call, so this stays
    # synchronous unlike every CLI-backed job kind) and fall through to the
    # ordinary single-projectId 'add' path below. Unlike a bad-request
    # (caught earlier, in Handle-JobsPost, as a 400 before Start-Job is ever
    # called), an unresolvable slug is a valid request that simply has
    # nothing to install - per SPEC that is reported as a "404-style failed
    # job" (a real job, in state 'failed', with a synthetic 404 exitCode)
    # rather than an HTTP-level error, so the host's blind
    # POST-then-switch-tabs flow always gets a jobId whose progress panel
    # then shows the failure normally, same as any other Failed CLI result.
    if ($Kind -eq 'add-by-slug') {
        $slug = $null
        if ($Params -and $Params.slug) { $slug = [string]$Params.slug }
        if (-not $slug) {
            return @{ Busy = $false; Error = 'slug is required for kind add-by-slug' }
        }
        $entry = Get-CfCatalogueEntryBySlug -Slug $slug
        if (-not $entry) {
            $finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $job = [PSCustomObject]@{
                id            = $jobId
                kind          = 'add-by-slug'
                params        = $Params
                state         = 'failed'
                startedAt     = $startedAt
                finishedAt    = $finishedAt
                exitCode      = 404
                log           = New-Object 'System.Collections.Generic.List[object]'
                results       = New-Object 'System.Collections.Generic.List[object]'
                error         = "No CurseForge addon found for slug '$slug' (404)"
                flavour       = $Flavor
                Process       = $null
                OutFile       = $null
                ErrFile       = $null
                SyncLogOffset = 0
                LaunchAfter   = $false
            }
            Add-JobToHistory -Job $job
            Save-CheckState
            return @{ Busy = $false; Job = $job }
        }
        $Kind = 'add'
        $Params = Add-Member -InputObject $Params -NotePropertyName 'projectId' -NotePropertyValue $entry.id -Force -PassThru
    }

    # FLAVORS-SPEC.md CS-F3 S5.5: CurseForge install-flavour resolution.
    # Only engages for a genuine, SINGLE-target CurseForge add/install
    # (add-by-slug has already been normalized into 'add' with a resolved
    # numeric projectId by this point) when the caller did NOT name an
    # explicit ?flavour= and more than one flavour is installed - a
    # single-flavour machine can never hit this ambiguity (Get-CfFlavourMapping
    # already resolves correctly at n=1, so the count check below is a
    # no-op there - "invisible at one flavour" preserved), and an explicit
    # ?flavour= (including the picker's own resume POST, case 5 below)
    # always wins outright with no re-check (principle 5). Never engages
    # for a Wago target (source=wago+slug, or an already-tracked Wago
    # addon's projectId of the form "wago:<slug>") - Wago's one flavour is
    # already resolved by the search's own game_version param (S6.4), so
    # there is nothing ambiguous to ask about. A bulk add (projectIds[])
    # never reaches here either - $Params.projectId is only ever set for
    # the single-target path, so a bulk add still 400s upstream in
    # Handle-JobsPost exactly as before this change set (silently guessing
    # a flavour for several addons at once is not this feature's job).
    if (($Kind -eq 'add' -or $Kind -eq 'install') -and (-not $FlavourExplicit) -and $Params -and $Params.projectId) {
        $isWagoTarget = [bool](
            ($Params.source -and (([string]$Params.source).ToLowerInvariant() -eq 'wago') -and $Params.slug) -or
            (([string]$Params.projectId).ToLowerInvariant().StartsWith('wago:'))
        )
        if (-not $isWagoTarget) {
            $installedForResolve = Get-CurrentInstalledFlavours
            if ((@($installedForResolve)).Count -gt 1) {
                $numericProjectId = 0L
                $isNumericProjectId = [int64]::TryParse([string]$Params.projectId, [ref]$numericProjectId)
                if ($isNumericProjectId) {
                    $settingsForResolve = Get-Settings
                    $showTestForResolve = [bool]$settingsForResolve.showTestRealms
                    $visibleFlavoursForResolve = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($f in $installedForResolve) {
                        if ((-not $showTestForResolve) -and (@('ptr', 'xptr', 'beta') -contains $f.id)) { continue }
                        $visibleFlavoursForResolve.Add($f)
                    }
                    $resolveFileId = $null
                    if ($Params.fileId) { $resolveFileId = $Params.fileId }
                    $resolution = Resolve-CfInstallFlavour -ProjectId $numericProjectId -FileId $resolveFileId -InstalledFlavours $visibleFlavoursForResolve

                    if ($resolution.FetchError) {
                        # A gameVersionTypeIds fetch failure (network hiccup, bad
                        # projectId/fileId, CurseForge unreachable) - report exactly
                        # like any other job-start failure; no job created.
                        return @{ Busy = $false; Error = $resolution.FetchError }
                    }

                    $matchIds = @($resolution.MatchingFlavourIds)
                    if ($matchIds.Count -eq 0) {
                        # S5.5 case 4: zero matches - a real job, immediately
                        # failed, the same "404-style failed job" pattern the
                        # add-by-slug unresolved-slug branch above uses (a plain
                        # message, not an HTTP-level error, so the panel that
                        # already shows every other failure shows this one too).
                        $finishedAtZero = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        $zeroJob = [PSCustomObject]@{
                            id            = $jobId
                            kind          = $Kind
                            params        = $Params
                            state         = 'failed'
                            startedAt     = $startedAt
                            finishedAt    = $finishedAtZero
                            exitCode      = 422
                            log           = New-Object 'System.Collections.Generic.List[object]'
                            results       = New-Object 'System.Collections.Generic.List[object]'
                            error         = "This addon doesn't support your installed WoW versions."
                            flavour       = $null
                            Process       = $null
                            OutFile       = $null
                            ErrFile       = $null
                            SyncLogOffset = 0
                            LaunchAfter   = $false
                        }
                        Add-JobToHistory -Job $zeroJob
                        Save-CheckState
                        return @{ Busy = $false; Job = $zeroJob }
                    } elseif ($matchIds.Count -eq 1) {
                        # S5.5 case 3: exactly one match - install there
                        # silently, no prompt. Overrides $Flavor to the ONE
                        # matching flavour (which may differ from whatever this
                        # request defaulted to) - the busy re-check just below
                        # this whole block covers the case where that flavour
                        # differs from $originalRequestFlavor.
                        $Flavor = $matchIds[0]
                    } else {
                        # S5.5 case 5: more than one match - create the job in
                        # a new 'awaiting_flavour' state instead of dispatching
                        # to the CLI at all; the SPA's picker (ui/app.js
                        # Components.JobPanel) resumes by re-POSTing the
                        # IDENTICAL body with ?flavour=<chosen> set, which then
                        # carries FlavourExplicit=$true and skips this whole
                        # block outright (case 3's silent path, effectively).
                        $choices = New-Object 'System.Collections.Generic.List[object]'
                        foreach ($mid in $matchIds) {
                            $def = Get-FlavourDef -Id $mid
                            $lbl = $mid
                            if ($def) { $lbl = $def.Label }
                            $choices.Add([PSCustomObject]@{ id = $mid; label = $lbl })
                        }
                        $askJob = [PSCustomObject]@{
                            id            = $jobId
                            kind          = $Kind
                            params        = $Params
                            state         = 'awaiting_flavour'
                            startedAt     = $startedAt
                            finishedAt    = $null
                            exitCode      = $null
                            log           = New-Object 'System.Collections.Generic.List[object]'
                            results       = New-Object 'System.Collections.Generic.List[object]'
                            error         = $null
                            flavour       = $null
                            choices       = $choices.ToArray()
                            Process       = $null
                            OutFile       = $null
                            ErrFile       = $null
                            SyncLogOffset = 0
                            LaunchAfter   = $false
                        }
                        Add-JobToHistory -Job $askJob
                        Save-CheckState
                        return @{ Busy = $false; Job = $askJob }
                    }
                }
            }
        }
    }

    # A case-3 auto-resolution just above may have reassigned $Flavor to a
    # DIFFERENT flavour than the one Test-JobBusy already checked at the top
    # of this function - re-check the new flavour's own busy slot before
    # dispatching to it. When $Flavor never changed (every other path
    # through this function), this is a no-op re-check of the same flavour
    # already known free.
    if ($Flavor -ne $originalRequestFlavor) {
        if (Test-JobBusy -Flavor $Flavor) {
            return @{ Busy = $true; Job = (Get-CurrentJobForFlavour -Flavor $Flavor) }
        }
    }

    $cliKind = $Kind
    $launchAfter = $false
    if ($Kind -eq 'launch') {
        $cliKind = 'sync'
        $launchAfter = $true
    }

    # E12: a NEW Wago add/install (no existing record yet, so no projectId-
    # equivalent key to reuse) is posted as {source:'wago', slug, fileId?}
    # per SPEC rather than a bare projectId. Build-CliArgs's 'add'/'install'
    # cases already just [string]-cast Params.projectId/fileId generically
    # (they always have, even before E12 - see their own comments), so
    # normalizing to the same "wago:<slug>" token addon-sync.ps1's -Add/-Only
    # classifier already accepts lets both cases run completely unchanged
    # below - an ADD/INSTALL targeting an ALREADY-TRACKED Wago addon (e.g.
    # the kebab menu's "Update now"/Versions-tab "Install") instead posts
    # projectId directly as that same "wago:<slug>" string (the addon's own
    # Store.addonKey), which needs no normalization here at all.
    if (($cliKind -eq 'add' -or $cliKind -eq 'install') -and $Params -and $Params.source -and (([string]$Params.source).ToLowerInvariant() -eq 'wago') -and $Params.slug) {
        $Params = Add-Member -InputObject $Params -NotePropertyName 'projectId' -NotePropertyValue ('wago:' + [string]$Params.slug) -Force -PassThru
    }

    try {
        $cliArgs = Build-CliArgs -Kind $cliKind -Params $Params
    } catch {
        return @{ Busy = $false; Error = $_.Exception.Message }
    }

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }

    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "$jobId.out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "$jobId.err"

    $syncLogOffset = 0
    if (Test-Path -LiteralPath $Script:SyncLogPath) {
        $syncLogOffset = (Get-Item -LiteralPath $Script:SyncLogPath).Length
    }

    # CS1: -ProgressPath is threaded only for the job kinds UX-SPEC.md
    # section 4.2 names (sync/check/add/install - $cliKind is already 'sync'
    # for a launch-with-update, which counts). remove/rollback and the
    # multi-phase import/switch-source kinds (built by their own Start-*Job
    # helpers, never reaching this single-phase path) get no progress file -
    # Update-JobStatus's read is likewise gated on $Job.ProgressPath being set.
    $progressPath = $null
    if ($cliKind -eq 'sync' -or $cliKind -eq 'check' -or $cliKind -eq 'add' -or $cliKind -eq 'install') {
        $progressPath = Join-Path -Path $Script:JobsDir -ChildPath "$jobId.progress.json"
    }

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs -ProgressPath $progressPath -Flavor $Flavor

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Force the SafeProcessHandle to materialize now. Without this, reading
        # .ExitCode later (after HasExited) is unreliable on this machine: it can
        # throw "You cannot call a method on a null-valued expression" or silently
        # return $null even though the process actually completed.
        $proc.Handle | Out-Null
    } catch {
        return @{ Busy = $false; Error = "Failed to start CLI process: $($_.Exception.Message)" }
    }

    $job = [PSCustomObject]@{
        id            = $jobId
        kind          = $Kind
        params        = $Params
        state         = 'running'
        startedAt     = $startedAt
        finishedAt    = $null
        exitCode      = $null
        log           = New-Object 'System.Collections.Generic.List[object]'
        results       = New-Object 'System.Collections.Generic.List[object]'
        error         = $null
        # FLAVORS-SPEC.md CS-F2 S5.4: every job carries its own flavour.
        flavour       = $Flavor
        Process       = $proc
        OutFile       = $outFile
        ErrFile       = $errFile
        SyncLogOffset = $syncLogOffset
        LaunchAfter   = $launchAfter
        # CS1: $null for every job kind that gets no -ProgressPath (see
        # above) - Update-JobStatus's best-effort read no-ops on a falsy
        # ProgressPath exactly like Write-ProgressStep itself does CLI-side.
        ProgressPath  = $progressPath
    }
    Add-JobToHistory -Job $job
    Set-CurrentJobForFlavour -Flavor $Flavor -Job $job
    return @{ Busy = $false; Job = $job }
}

# =====================================================================
# Export / Import (E4)
# =====================================================================

function Build-ImportPlan {
    <#
      Computes the sequence of addon-sync.ps1 invocations ("phases") needed
      to apply an imported addons-export.json body, plus any result rows
      that need no CLI call at all. Returns a hashtable (a single object -
      safe to `return` directly, unlike the List[object]s inside it, which
      the caller must never re-wrap in `@()`): @{ Phases = <List[object] of
      CliArgs Lists>; SkipRows = <List[object] of {status,name,version,
      projectId,fileId,wagoSlug} rows> }.

      E12 fix (Round 9): each entry is identified by a TARGET TOKEN -
      Get-UpdateAvailableKeyForRecord's own duplex key, reused verbatim
      since an import entry (post-Handle-Export fix) carries the exact same
      projectId/source/slug shape a real addon record does: the numeric
      CurseForge project id as a string, or "wago:<slug>" for a Wago-sourced
      entry (identifiable only via source/slug - it has no numeric id at
      all). This token is also exactly what addon-sync.ps1's -Add/-Only/
      -Ignore target classifier already accepts, CurseForge or Wago alike,
      so no further translation is needed before it lands in a phase's
      CliArgs. An entry with neither (foreign/malformed data, or a
      CurseForge row missing even a projectId) is unidentifiable and
      skipped outright, same as before.

      -Add is issued ONCE with every not-yet-present target comma-joined
      (SPEC: "one CLI invocation with all ids" - the exact same
      comma-joined-single-token requirement Build-CliArgs's own 'sync' case
      already documents at length, since addon-sync.ps1 is likewise always
      invoked as a brand-new "-File" child process here, never in-process).
      pinnedFileId then needs its own -Only/-FileId phase PER addon (that
      flag pair only ever targets a single project - addon-sync.ps1 itself
      rejects more than one id alongside -FileId), including one for an
      addon this same plan is also adding: the newest file installs first,
      then this phase reinstalls the pinned one, exactly mirroring the
      roadmap's own two-step wording rather than trying to fold both into
      one -Add -FileId call (which only ever supports a single id, so it
      cannot cover a multi-addon import). An ignoreUpdates flag needs no
      per-addon restriction, so every target that wants it - freshly added
      by this import or already on record - is batched into one trailing
      -Ignore phase. releaseType is captured on export for round-tripping
      but is deliberately NOT applied on import: no CLI flag sets a
      record's per-addon releaseType override directly (SPEC.md's addon-
      sync.ps1 contract has no such param), and inventing a direct
      addons.json write here would break the "the CLI owns writes" rule
      this whole file otherwise holds to.

      An imported addon already present with neither pinnedFileId nor
      ignoreUpdates set needs no CLI call at all - its SkipRow mirrors the
      exact shape addon-sync.ps1's own "-Add: already present" path already
      produces (Name/Version/FileId straight from the EXISTING record, plus
      wagoSlug for a Wago one - the same additive field every other -Json
      result row carries per SPEC), so the job's results read the same as
      they would if the underlying add job itself had done the skipping.
    #>
    param(
        [Parameter(Mandatory = $true)]$ImportAddons,
        [Parameter(Mandatory = $true)][hashtable]$ExistingById
    )

    $phases = New-Object 'System.Collections.Generic.List[object]'
    $skipRows = New-Object 'System.Collections.Generic.List[object]'

    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $toAddTargets = New-Object 'System.Collections.Generic.List[object]'
    $pinEntries = New-Object 'System.Collections.Generic.List[object]'
    $ignoreTargets = New-Object 'System.Collections.Generic.List[object]'
    $ignoreSeen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($entry in @($ImportAddons)) {
        if (-not $entry) { continue }
        $key = Get-UpdateAvailableKeyForRecord -Record $entry
        if (-not $key) { continue }   # neither a numeric projectId nor a wago:<slug> pair - unidentifiable
        if (-not $seenKeys.Add($key)) { continue }   # dedupe within the import file itself

        $existingRecord = $null
        $isNew = $true
        if ($ExistingById.ContainsKey($key)) {
            $existingRecord = $ExistingById[$key]
            $isNew = $false
        }

        $hasPin = $false
        $fid = [int64]0
        if ($null -ne $entry.pinnedFileId) {
            try { $fid = [int64]$entry.pinnedFileId; $hasPin = $true } catch { $hasPin = $false }
        }
        $hasIgnore = [bool]$entry.ignoreUpdates

        if ($isNew) {
            $toAddTargets.Add($key)
        }
        if ($hasPin) {
            $pinEntries.Add([PSCustomObject]@{ Target = $key; FileId = $fid })
        }
        if ($hasIgnore -and $ignoreSeen.Add($key)) {
            $ignoreTargets.Add($key)
        }

        if ((-not $isNew) -and (-not $hasPin) -and (-not $hasIgnore)) {
            $skipWagoSlug = $null
            if ($existingRecord.source -eq 'wago') { $skipWagoSlug = $existingRecord.slug }
            $skipRows.Add([PSCustomObject]@{
                    status    = 'Skipped'
                    name      = $existingRecord.name
                    version   = $existingRecord.version
                    projectId = $existingRecord.projectId
                    fileId    = $existingRecord.fileId
                    wagoSlug  = $skipWagoSlug
                })
        }
    }

    if ($toAddTargets.Count -gt 0) {
        $addArgs = New-Object 'System.Collections.Generic.List[object]'
        $addArgs.Add('-Add')
        $addArgs.Add(($toAddTargets -join ','))
        $phases.Add($addArgs)
    }

    foreach ($pin in $pinEntries) {
        $pinArgs = New-Object 'System.Collections.Generic.List[object]'
        $pinArgs.Add('-Only')
        $pinArgs.Add([string]$pin.Target)
        $pinArgs.Add('-FileId')
        $pinArgs.Add([string]$pin.FileId)
        $phases.Add($pinArgs)
    }

    if ($ignoreTargets.Count -gt 0) {
        $ignoreArgs = New-Object 'System.Collections.Generic.List[object]'
        $ignoreArgs.Add('-Ignore')
        $ignoreArgs.Add(($ignoreTargets -join ','))
        $phases.Add($ignoreArgs)
    }

    return @{ Phases = $phases; SkipRows = $skipRows }
}

function Start-ImportPhase {
    <#
      Launches the next not-yet-run phase of a multi-phase 'import' job
      (see Build-ImportPlan) as a hidden addon-sync.ps1 child process -
      exactly like the single-phase kinds below, since Update-JobStatus's
      sync.log tailing and Process/HasExited polling don't care how many
      phases a job has, only whether $Job.Process is currently running.
      Only the process-launch and phase-advance bookkeeping here is
      import-specific. Returns $true once a process is running, $false on
      failure (the caller fails the whole job).
    #>
    param($Job)

    $Job.PhaseIndex = $Job.PhaseIndex + 1
    $cliArgs = $Job.Phases[$Job.PhaseIndex]

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).err"

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs -Flavor $Job.flavour

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # See Start-Job: force the SafeProcessHandle to materialize now so
        # that reading .ExitCode later is reliable on this machine.
        $proc.Handle | Out-Null
    } catch {
        Write-ServerLog "Failed to start import phase $($Job.PhaseIndex) for job $($Job.id): $($_.Exception.Message)"
        return $false
    }

    $Job.Process = $proc
    $Job.OutFile = $outFile
    $Job.ErrFile = $errFile
    return $true
}

function Start-ImportJob {
    <#
      Builds and starts (or, when there is nothing at all to do, finishes
      immediately) a multi-phase 'import' job. Split out of Start-Job so
      every single-CLI-invocation job kind there is completely untouched by
      this addition; called only from there, after its own Test-JobBusy
      check has already passed.
    #>
    param(
        [string]$JobId,
        [string]$StartedAt,
        $Params,
        [string]$Flavor
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $importAddons = @()
    if ($Params -and ($null -ne $Params.addons)) { $importAddons = @($Params.addons) }

    # E12 fix (Round 9): keyed the same duplex way Get-UpdateAvailableKeyForRecord
    # already keys $Script:UpdateAvailable - the numeric projectId (as a
    # string) for a CurseForge record, or "wago:<slug>" for a Wago-sourced
    # one (which has no numeric projectId at all and was previously omitted
    # from this map entirely, making every already-tracked Wago addon look
    # brand-new to Build-ImportPlan).
    $existingById = @{}
    foreach ($r in (Get-AddonRecords)) {
        $key = Get-UpdateAvailableKeyForRecord -Record $r
        if ($key) { $existingById[$key] = $r }
    }

    $plan = Build-ImportPlan -ImportAddons $importAddons -ExistingById $existingById

    $job = [PSCustomObject]@{
        id            = $JobId
        kind          = 'import'
        params        = $Params
        state         = 'running'
        startedAt     = $StartedAt
        finishedAt    = $null
        exitCode      = $null
        log           = New-Object 'System.Collections.Generic.List[object]'
        results       = New-Object 'System.Collections.Generic.List[object]'
        error         = $null
        flavour       = $Flavor
        Process       = $null
        OutFile       = $null
        ErrFile       = $null
        SyncLogOffset = 0
        LaunchAfter   = $false
        Phases        = $plan.Phases
        PhaseIndex    = -1
    }
    foreach ($row in $plan.SkipRows) { $job.results.Add($row) }

    if ($job.Phases.Count -eq 0) {
        # Every imported addon was already present with no pinnedFileId/
        # ignoreUpdates to (re)apply - SkipRows above already covered every
        # row, so there is no CLI process to run at all (same immediate-
        # finish shape as the launch-without-updateFirst case above).
        $job.state = 'done'
        $job.exitCode = 0
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-JobToHistory -Job $job
        Apply-JobCompletionSideEffects -Job $job -Parsed ([PSCustomObject]@{ action = 'import' })
        Save-CheckState
        return @{ Busy = $false; Job = $job }
    }

    if (Test-Path -LiteralPath $Script:SyncLogPath) {
        $job.SyncLogOffset = (Get-Item -LiteralPath $Script:SyncLogPath).Length
    }

    Add-JobToHistory -Job $job
    Set-CurrentJobForFlavour -Flavor $Flavor -Job $job

    $started = Start-ImportPhase -Job $job
    if (-not $started) {
        $job.state = 'failed'
        $job.error = 'Failed to start import'
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-CurrentJobForFlavour -Flavor $Flavor -Job $null
        Save-CheckState
    }
    return @{ Busy = $false; Job = $job }
}

# =====================================================================
# state.json: persisted check results (E2 - automatic update checks)
# =====================================================================

function Save-CheckState {
    <#
      Persists $Script:UpdatesCheckedAtByFlavour + $Script:UpdateAvailable-
      ByFlavour (E2, made per-flavour by FLAVORS-SPEC.md CS-F2 S5.3) and, as
      of Round 3, $Script:LastRunByFlavour + the last 20 completed jobs
      (shared across every flavour, each carrying its own .flavour field per
      S5.4) to ROOT\state.json, so the "n updates" badge, the My Addons
      "Last run" line (/api/state.lastRun), the rollback tooltip / job
      history (/api/state.job, /api/jobs) all survive a server restart
      instead of resetting to null/empty. Jobs are serialized via
      Get-JobStatusView - plain data (id/kind/params/state/.../log[]/
      results[]/error/flavour), never the raw Job objects, which carry a
      live System.Diagnostics.Process handle that cannot be (and must never
      be) JSON-serialized. Best-effort: a write failure is logged, never
      thrown (must not abort the job-completion path that calls this).

      CS-F2 deliberately keeps ONE state.json at the shared root rather than
      splitting it under flavours\<id>\ the way FLAVORS-SPEC.md S3.1's
      literal file-tree diagram shows addons.json/backups\ - job history is
      one shared, flavour-tagged list by S5.4's own description ("a flavour
      badge... only when more than one flavour installed", implying one
      list, not N), and splitting the freshness bookkeeping too would need a
      materially larger restart-time merge across N per-flavour files for no
      behavioral gain this change set's verify bar calls for. Flagged
      explicitly in this change set's notesForNext for whoever next touches
      this area.
    #>
    $jobViews = New-Object 'System.Collections.Generic.List[object]'
    foreach ($j in $Script:Jobs) {
        $jobViews.Add((Get-JobStatusView -Job $j))
    }

    $body = [PSCustomObject]@{
        updatesCheckedAt   = $Script:UpdatesCheckedAtByFlavour
        updateAvailable    = $Script:UpdateAvailableByFlavour
        lastRun            = $Script:LastRunByFlavour
        jobs               = $jobViews.ToArray()
        # E12: persists the Wago Inertia asset version across a restart, per
        # SPEC's documented "cache the version in state.json" - saves the
        # very first Wago proxy call after a restart the plain-HTML
        # handshake round-trip it would otherwise need to pay again.
        wagoInertiaVersion = $Script:WagoInertiaVersion
    }
    try {
        # -InputObject (not a pipe): piping a single-property object through
        # ConvertTo-Json risks the same single-element unwrap quirk documented
        # for arrays elsewhere in this codebase, and -InputObject sidesteps it.
        $json = ConvertTo-Json -InputObject $body -Depth 8
        $tmpPath = "$Script:StatePath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $Script:StatePath -Force
    } catch {
        Write-ServerLog "Failed to write state.json: $($_.Exception.Message)"
    }
}

function Load-CheckState {
    <#
      Loads updatesCheckedAt/updateAvailable/lastRun/jobs from ROOT\state.json
      at startup into the per-flavour ...ByFlavour dictionaries and
      $Script:Jobs. Tolerates a missing, empty, or corrupt file (leaves the
      caller's already-initialized defaults/empty list in place).

      FLAVORS-SPEC.md CS-F2: also tolerates a PRE-flavour state.json (one
      written before this change set - updatesCheckedAt/updateAvailable/
      lastRun as flat scalars/objects, no per-flavour nesting, jobs with no
      .flavour field) by detecting the old flat shape and adopting it as the
      'retail' flavour's own bucket - a restart right after upgrading to
      this build never loses a pre-existing single-flavour install's
      freshness/job history. A job loaded with no .flavour field at all
      (same pre-upgrade file) defaults to 'retail', matching S4.1's own
      "existing single-flavour behavior, unchanged" bar.

      Round 3: a persisted job can never be reloaded as 'running' - the
      System.Diagnostics.Process behind it belonged to the PREVIOUS server
      instance and is gone the moment this one starts, so any job whose
      saved state is not already 'done'/'failed' (i.e. the server was killed
      mid-job) is forced to 'failed' on load, and every loaded job gets
      Process/OutFile/ErrFile = $null (nothing left to reattach to or clean
      up - Update-JobStatus's own state-!='running' guard means these are
      never touched again for a loaded job anyway). $Script:JobIdSeq is
      advanced past the highest loaded job id so New-JobId can never reissue
      an id a client might already be polling.
    #>
    if (-not (Test-Path -LiteralPath $Script:StatePath)) {
        return
    }
    try {
        # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and is
        # never returned/serialized itself, so its PSPath/PSDrive/PSProvider note
        # properties never reach a JSON response (see Update-JobStatus for the
        # pattern that actually hangs Send-Json).
        $raw = Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return
        }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop

        # updatesCheckedAt: new shape is an object keyed by flavour id; the
        # pre-flavour shape was a bare string - a string has no
        # .PSObject.Properties worth iterating (Get-Member would show only
        # String's own members), so this old-shape check is simply "is it a
        # string at all".
        if ($null -ne $obj.updatesCheckedAt) {
            if ($obj.updatesCheckedAt -is [string]) {
                $Script:UpdatesCheckedAtByFlavour = @{ retail = [string]$obj.updatesCheckedAt }
            } else {
                $map = @{}
                foreach ($p in $obj.updatesCheckedAt.PSObject.Properties) {
                    $map[$p.Name] = [string]$p.Value
                }
                $Script:UpdatesCheckedAtByFlavour = $map
            }
        }
        if ($null -ne $obj.updateAvailable) {
            # New shape: {flavour: {key: {fileId, version}}}. Old shape:
            # {key: {fileId, version}} directly - distinguished by whether
            # any top-level property's own value looks like an
            # updateAvailable entry (has a fileId or version member) rather
            # than another nested flavour bucket (which would not).
            $looksOldShape = $false
            foreach ($p in $obj.updateAvailable.PSObject.Properties) {
                if ($null -ne $p.Value -and (($null -ne $p.Value.fileId) -or ($null -ne $p.Value.version))) {
                    $looksOldShape = $true
                }
                break
            }
            if ($looksOldShape) {
                $map = @{}
                foreach ($p in $obj.updateAvailable.PSObject.Properties) {
                    $map[$p.Name] = @{ fileId = $p.Value.fileId; version = $p.Value.version }
                }
                $Script:UpdateAvailableByFlavour = @{ retail = $map }
            } else {
                $outer = @{}
                foreach ($fp in $obj.updateAvailable.PSObject.Properties) {
                    $inner = @{}
                    foreach ($p in $fp.Value.PSObject.Properties) {
                        $inner[$p.Name] = @{ fileId = $p.Value.fileId; version = $p.Value.version }
                    }
                    $outer[$fp.Name] = $inner
                }
                $Script:UpdateAvailableByFlavour = $outer
            }
        }
        if ($null -ne $obj.lastRun) {
            # New shape: {flavour: {timestamp, summary, rows}}. Old shape:
            # {timestamp, summary, rows} directly - distinguished by the
            # presence of a .timestamp member (a per-flavour bucket's OWN
            # entries are further-nested objects, none of which is itself
            # named "timestamp" at this level).
            if ($null -ne $obj.lastRun.timestamp) {
                $Script:LastRunByFlavour = @{ retail = $obj.lastRun }
            } else {
                $map = @{}
                foreach ($p in $obj.lastRun.PSObject.Properties) { $map[$p.Name] = $p.Value }
                $Script:LastRunByFlavour = $map
            }
        }
        if ($null -ne $obj.wagoInertiaVersion) {
            $Script:WagoInertiaVersion = [string]$obj.wagoInertiaVersion
        }
        if ($null -ne $obj.jobs) {
            $loadedJobs = New-Object 'System.Collections.Generic.List[object]'
            $maxId = 0
            foreach ($jv in @($obj.jobs)) {
                $jobState = [string]$jv.state
                if ($jobState -ne 'done' -and $jobState -ne 'failed') {
                    $jobState = 'failed'
                }
                $log = New-Object 'System.Collections.Generic.List[object]'
                foreach ($l in @($jv.log)) { $log.Add([string]$l) }
                $results = New-Object 'System.Collections.Generic.List[object]'
                foreach ($r in @($jv.results)) { $results.Add($r) }

                $jobFlavour = 'retail'
                if ($jv.flavour) { $jobFlavour = [string]$jv.flavour }

                $job = [PSCustomObject]@{
                    id            = [string]$jv.id
                    kind          = $jv.kind
                    params        = $jv.params
                    state         = $jobState
                    startedAt     = $jv.startedAt
                    finishedAt    = $jv.finishedAt
                    exitCode      = $jv.exitCode
                    log           = $log
                    results       = $results
                    error         = $jv.error
                    flavour       = $jobFlavour
                    Process       = $null
                    OutFile       = $null
                    ErrFile       = $null
                    SyncLogOffset = 0
                    LaunchAfter   = $false
                    # E4: a reloaded job's saved state is never 'running'
                    # (the block above forces that), so Phases/PhaseIndex are
                    # never read for one - present here only so every Job
                    # object in $Script:Jobs carries the same property shape.
                    Phases        = $null
                    PhaseIndex    = 0
                }
                $loadedJobs.Add($job)

                $idNum = 0
                if ([int]::TryParse($job.id, [ref]$idNum) -and $idNum -gt $maxId) {
                    $maxId = $idNum
                }
            }
            $Script:Jobs = $loadedJobs
            while ($Script:Jobs.Count -gt 20) {
                $Script:Jobs.RemoveAt(0)
            }
            if ($maxId -gt $Script:JobIdSeq) {
                $Script:JobIdSeq = $maxId
            }
        }
        Write-ServerLog "Loaded state.json: flavours=$($Script:UpdatesCheckedAtByFlavour.Count) jobs=$($Script:Jobs.Count)"
    } catch {
        Write-ServerLog "Failed to read state.json, ignoring: $($_.Exception.Message)"
    }
}

function Get-UpdateAvailableKeyForRecord {
    <#
      E12: the key $Script:UpdateAvailable is keyed by for one addon record -
      the numeric CurseForge project id (unchanged from before E12) when
      present, else "wago:<slug>" for a Wago-sourced record (which has no
      numeric projectId at all). $null when neither is available (should not
      happen for a well-formed record, but never throws).
    #>
    param($Record)

    if ($null -ne $Record.projectId) {
        return [string]$Record.projectId
    }
    if ($Record.source -eq 'wago' -and $Record.slug) {
        return 'wago:' + $Record.slug
    }
    return $null
}

function Get-UpdateAvailableKeyForRow {
    <#
      E12: the same key, derived from a JOB RESULT ROW instead of a full
      record - a row carries `projectId` (unchanged) and, additively,
      `wagoSlug` (see SPEC's addon-sync.ps1 -Json contract) rather than the
      full record shape Get-UpdateAvailableKeyForRecord reads.
    #>
    param($Row)

    if ($Row.projectId) {
        return [string]$Row.projectId
    }
    if ($Row.wagoSlug) {
        return 'wago:' + $Row.wagoSlug
    }
    return $null
}

function Apply-JobCompletionSideEffects {
    <#
      Updates in-memory updateAvailable / lastRun bookkeeping from a
      finished job's parsed output. Does NOT persist state.json itself -
      Update-JobStatus (the sole caller) does that once, after this returns,
      so the save always picks up both this function's updateAvailable/
      lastRun changes AND the job's own final state/results in a single
      write, regardless of whether the job ultimately succeeded or failed.

      CS1 (UX-SPEC.md section 4.2): Update-JobStatus now calls this on BOTH
      of its outcomes, not just success - the failure branch immediately
      below is what runs on the failed call ($Job.state is already 'failed'
      and $Job.error already set by the caller before it calls in). It
      returns before touching updateAvailable/lastRun/UpdatesCheckedAt at
      all, so a failed job's effect here is scoped to exactly the two new
      freshness fields - mirrors how a successful 'check' job already sets
      $Script:UpdatesCheckedAt below, just for the failure side of that same
      "did the freshness picture just change" question. Every successful
      call clears both fields first (a later success after an earlier
      failure must un-stick the freshness headline from check_failed).

      Review fix (post-CS6): the failure branch only records
      LastCheckFailed/LastCheckError for the kinds that actually touch
      CurseForge/Wago (the same 'sync','check','add','install','launch'
      list Get-ComputedFreshness's own 'checking' condition already uses)
      - a failed 'remove'/'rollback'/other job no longer flips the
      app-wide freshness headline to "Couldn't check - Retry", since that
      headline's own Retry action only re-runs a check and has nothing to
      do with an uninstall/rollback failure. Those failures still surface
      through their own job-panel/toast error, unaffected by this gate.

      FLAVORS-SPEC.md CS-F2 S5.3: every field this function touches is now
      keyed by $Job.flavour (defaulting to 'retail' for a pre-CS-F2 job
      object with no such field) instead of one global scalar/hashtable -
      so a Classic Era job's completion never updates Retail's own
      freshness bookkeeping, or vice versa.
    #>
    param($Job, $Parsed)

    $flavor = $Job.flavour
    if (-not $flavor) { $flavor = 'retail' }

    if ($Job.state -eq 'failed') {
        if (@('sync', 'check', 'add', 'install', 'launch') -contains $Job.kind) {
            $Script:LastCheckFailedByFlavour[$flavor] = $true
            $errMsg = $Job.error
            if (-not $errMsg) { $errMsg = 'Unknown error' }
            $Script:LastCheckErrorByFlavour[$flavor] = $errMsg
        }
        return
    }

    $Script:LastCheckFailedByFlavour[$flavor] = $false
    $Script:LastCheckErrorByFlavour[$flavor] = $null

    $action = $null
    if ($Parsed -and $Parsed.action) {
        $action = [string]$Parsed.action
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $Job.results) { $rows.Add($r) }

    $updateAvailable = Get-FlavourUpdateAvailable -Flavor $flavor

    if ($action -eq 'check') {
        $Script:UpdatesCheckedAtByFlavour[$flavor] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $updateAvailable.Clear()
        foreach ($r in $rows) {
            if ($r.status -eq 'Would-update') {
                # E12: keyed by projectId when present, else "wago:<slug>" -
                # see Get-UpdateAvailableKeyForRow.
                $key = Get-UpdateAvailableKeyForRow -Row $r
                if ($key) {
                    $updateAvailable[$key] = @{ fileId = $r.fileId; version = $r.version }
                }
            }
        }
    } elseif ($action -eq 'sync' -or $action -eq 'add' -or $action -eq 'remove' -or $action -eq 'rollback' -or $action -eq 'import' -or $action -eq 'switch-source') {
        # E1: a completed rollback pins the addon to the restored file, same
        # as an explicit Pin - it has no update pending against that pin
        # until the next check, so any stale "update available" entry for
        # this project needs clearing the same way Updated/Installed/Pinned
        # already do. E4: an import's Updated/Installed/Pinned rows (from
        # its -Add / -Only+-FileId phases) need exactly the same clearing -
        # this branch already keys off $rows (built from the caller's own
        # $Job.results, not $Parsed.action-specific data), so 'import' only
        # needed adding to this condition, nothing else. E12: 'switch-source'
        # (uninstall-then-add-from-the-other-source) joins the same way, for
        # the same reason.
        foreach ($r in $rows) {
            if ($r.status -eq 'Updated' -or $r.status -eq 'Installed' -or $r.status -eq 'Pinned' -or $r.status -eq 'Rolled-back') {
                $key = Get-UpdateAvailableKeyForRow -Row $r
                if ($key -and $updateAvailable.ContainsKey($key)) {
                    $updateAvailable.Remove($key)
                }
            }
        }
    }

    if ($action -ne 'check' -and $action -ne 'files' -and $action -ne 'scan') {
        $counts = @{}
        foreach ($r in $rows) {
            $st = [string]$r.status
            if (-not $counts.ContainsKey($st)) { $counts[$st] = 0 }
            $counts[$st] = $counts[$st] + 1
        }
        $summaryParts = New-Object 'System.Collections.Generic.List[object]'
        foreach ($k in $counts.Keys) {
            $summaryParts.Add("$k`: $($counts[$k])")
        }
        $Script:LastRunByFlavour[$flavor] = [PSCustomObject]@{
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            summary   = ($summaryParts -join '  ')
            rows      = $rows.ToArray()
        }
    }
}

function Complete-ImportPhase {
    <#
      Finalizes one phase of a multi-phase 'import' job once its CLI process
      has exited: merges that phase's results into the job's CUMULATIVE
      $Job.results (never replaced the way a single-phase job's one-shot
      $Job.results assignment does - each phase adds to what earlier phases
      already produced), then either starts the next phase (job stays
      'running') or finalizes the whole job (state done/failed) once every
      phase has run. A single failed phase fails the entire job outright -
      later phases are never attempted - the same all-or-nothing failure
      shape every other job kind already has.

      Called only from Update-JobStatus, once its own tailing/HasExited
      check confirms this job's current phase process has exited; keeping
      this entirely separate from that function's own finalize logic below
      means every other job kind's behavior there is completely untouched
      by import's existence.
    #>
    param($Job)

    $exitCode = $Job.Process.ExitCode

    # Read with ReadAllText, NOT Get-Content - see Update-JobStatus for why
    # (Get-Content's PSPath/PSDrive/PSProvider note properties can hang
    # ConvertTo-Json if the string ever ends up in a response).
    $stdout = ''
    try {
        if (Test-Path -LiteralPath $Job.OutFile) {
            $stdout = [System.IO.File]::ReadAllText($Job.OutFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stdout = '' }

    $stderr = ''
    try {
        if (Test-Path -LiteralPath $Job.ErrFile) {
            $stderr = [System.IO.File]::ReadAllText($Job.ErrFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stderr = '' }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    $parsed = $null
    $parseError = $null
    if ($stdout -and $stdout.Trim().Length -gt 0) {
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    if ($exitCode -ne 0 -or -not $parsed) {
        $Job.exitCode = $exitCode
        $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Job.state = 'failed'
        $errMsg = $stderr
        if (-not $errMsg -and $parseError) { $errMsg = "Could not parse CLI output as JSON: $parseError" }
        if (-not $errMsg) { $errMsg = "CLI exited with code $exitCode" }
        $Job.error = "Import phase $($Job.PhaseIndex + 1) of $($Job.Phases.Count) failed: $errMsg"
        Clear-CurrentJobIfMatches -Job $Job
        Save-CheckState
        return $Job
    }

    if ($parsed.results) {
        foreach ($r in @($parsed.results)) { $Job.results.Add($r) }
    }

    $hasMorePhases = ($Job.PhaseIndex + 1) -lt $Job.Phases.Count
    if ($hasMorePhases) {
        $started = Start-ImportPhase -Job $Job
        if (-not $started) {
            $Job.exitCode = $exitCode
            $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $Job.state = 'failed'
            $Job.error = "Failed to start import phase $($Job.PhaseIndex + 1) of $($Job.Phases.Count)"
            Clear-CurrentJobIfMatches -Job $Job
            Save-CheckState
        }
        return $Job
    }

    $Job.exitCode = 0
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Job.state = 'done'
    Apply-JobCompletionSideEffects -Job $Job -Parsed ([PSCustomObject]@{ action = 'import' })

    Clear-CurrentJobIfMatches -Job $Job
    Save-CheckState
    return $Job
}

# =====================================================================
# switch-source (E12): "Reinstall from Wago/CurseForge" - uninstalls the
# tracked addon and adds it fresh from the OTHER source, as one job. Built
# as its own small two-phase job (mirroring Start-ImportJob/Start-ImportPhase/
# Complete-ImportPhase's shape exactly, but kept as a separate, dedicated set
# of functions rather than generalizing those - a switch is always exactly
# two phases, known up front, with no per-addon plan-building step import's
# Build-ImportPlan needs) rather than trying to fold two CLI invocations into
# Build-CliArgs's single-invocation-per-kind contract.
# =====================================================================

function Start-SwitchSourcePhase {
    <# Launches phase 0 (-Remove) or phase 1 (-Add) of a switch-source job. Mirrors Start-ImportPhase. #>
    param($Job)

    $Job.PhaseIndex = $Job.PhaseIndex + 1
    $cliArgs = $Job.Phases[$Job.PhaseIndex]

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).err"

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs -Flavor $Job.flavour

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $proc.Handle | Out-Null
    } catch {
        Write-ServerLog "Failed to start switch-source phase $($Job.PhaseIndex) for job $($Job.id): $($_.Exception.Message)"
        return $false
    }

    $Job.Process = $proc
    $Job.OutFile = $outFile
    $Job.ErrFile = $errFile
    return $true
}

function Start-SwitchSourceJob {
    <#
      Builds the two-phase plan (-Remove <current>, then -Add <target on the
      other source>) and starts phase 0. Params: {projectId (the addon's
      CURRENT key - a numeric CurseForge id, or the "wago:<slug>" string
      Store.addonKey already uses for a Wago row), toSource ('wago'|
      'curseforge'), toTarget (a numeric CurseForge project id, or a Wago
      slug/id string - NOT pre-prefixed with "wago:", this function adds
      that)}.
    #>
    param(
        [string]$JobId,
        [string]$StartedAt,
        $Params,
        [string]$Flavor
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $currentTarget = [string]$Params.projectId
    $toSource = ([string]$Params.toSource).ToLowerInvariant()
    $toTargetRaw = [string]$Params.toTarget
    $newTarget = if ($toSource -eq 'wago') { 'wago:' + $toTargetRaw } else { $toTargetRaw }

    $removeArgs = New-Object 'System.Collections.Generic.List[object]'
    $removeArgs.Add('-Remove')
    $removeArgs.Add($currentTarget)

    $addArgs = New-Object 'System.Collections.Generic.List[object]'
    $addArgs.Add('-Add')
    $addArgs.Add($newTarget)

    $phases = New-Object 'System.Collections.Generic.List[object]'
    $phases.Add($removeArgs)
    $phases.Add($addArgs)

    $job = [PSCustomObject]@{
        id            = $JobId
        kind          = 'switch-source'
        params        = $Params
        state         = 'running'
        startedAt     = $StartedAt
        finishedAt    = $null
        exitCode      = $null
        log           = New-Object 'System.Collections.Generic.List[object]'
        results       = New-Object 'System.Collections.Generic.List[object]'
        error         = $null
        flavour       = $Flavor
        Process       = $null
        OutFile       = $null
        ErrFile       = $null
        SyncLogOffset = 0
        LaunchAfter   = $false
        Phases        = $phases
        PhaseIndex    = -1
    }

    if (Test-Path -LiteralPath $Script:SyncLogPath) {
        $job.SyncLogOffset = (Get-Item -LiteralPath $Script:SyncLogPath).Length
    }

    Add-JobToHistory -Job $job
    Set-CurrentJobForFlavour -Flavor $Flavor -Job $job

    $started = Start-SwitchSourcePhase -Job $job
    if (-not $started) {
        $job.state = 'failed'
        $job.error = 'Failed to start switch-source'
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-CurrentJobForFlavour -Flavor $Flavor -Job $null
        Save-CheckState
    }
    return @{ Busy = $false; Job = $job }
}

function Complete-SwitchSourcePhase {
    <# Finalizes one phase's exited process; mirrors Complete-ImportPhase. #>
    param($Job)

    $exitCode = $Job.Process.ExitCode

    $stdout = ''
    try {
        if (Test-Path -LiteralPath $Job.OutFile) {
            $stdout = [System.IO.File]::ReadAllText($Job.OutFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stdout = '' }

    $stderr = ''
    try {
        if (Test-Path -LiteralPath $Job.ErrFile) {
            $stderr = [System.IO.File]::ReadAllText($Job.ErrFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stderr = '' }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    $parsed = $null
    $parseError = $null
    if ($stdout -and $stdout.Trim().Length -gt 0) {
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    if ($exitCode -ne 0 -or -not $parsed) {
        $Job.exitCode = $exitCode
        $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Job.state = 'failed'
        $errMsg = $stderr
        if (-not $errMsg -and $parseError) { $errMsg = "Could not parse CLI output as JSON: $parseError" }
        if (-not $errMsg) { $errMsg = "CLI exited with code $exitCode" }
        $phaseName = if ($Job.PhaseIndex -eq 0) { 'Remove' } else { 'Add' }
        $Job.error = "Switch-source phase $phaseName ($($Job.PhaseIndex + 1) of $($Job.Phases.Count)) failed: $errMsg"
        Clear-CurrentJobIfMatches -Job $Job
        Save-CheckState
        return $Job
    }

    if ($parsed.results) {
        foreach ($r in @($parsed.results)) { $Job.results.Add($r) }
    }

    $hasMorePhases = ($Job.PhaseIndex + 1) -lt $Job.Phases.Count
    if ($hasMorePhases) {
        $started = Start-SwitchSourcePhase -Job $Job
        if (-not $started) {
            $Job.exitCode = $exitCode
            $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $Job.state = 'failed'
            $Job.error = "Failed to start switch-source phase $($Job.PhaseIndex + 1) of $($Job.Phases.Count)"
            Clear-CurrentJobIfMatches -Job $Job
            Save-CheckState
        }
        return $Job
    }

    $Job.exitCode = 0
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Job.state = 'done'
    Apply-JobCompletionSideEffects -Job $Job -Parsed ([PSCustomObject]@{ action = 'switch-source' })

    Clear-CurrentJobIfMatches -Job $Job
    Save-CheckState
    return $Job
}

function Update-JobStatus {
    <#
      Refreshes one job: while it is still running, tails sync.log since the
      job's last-consumed offset; once the backing process has exited,
      finalizes state/results/error from its output files. Safe to call
      repeatedly.

      Round 3 fix: tailing now only happens while $Job.state is 'running'.
      It used to run unconditionally on every call, including polls of an
      already-finished job (e.g. GET /api/jobs/{id} against an old job id
      after a later job has since run) - since sync.log is shared across
      every CLI invocation, that kept pulling in whatever a NEWER job had
      since appended and attaching it to this OLDER, already-done job's
      log. The state check now sits first, before any tailing happens, so a
      finished job's log is frozen at whatever it held the moment its
      process was found to have exited: the tail below still runs one more
      time on the very poll that discovers HasExited (state is still
      'running' at that point), capturing the CLI's last lines, and then
      state flips to done/failed afterward - every poll after that returns
      immediately here without touching sync.log at all.
    #>
    param($Job)

    if (-not $Job) {
        return $Job
    }

    if ($Job.state -ne 'running' -or -not $Job.Process) {
        return $Job
    }

    try {
        if (Test-Path -LiteralPath $Script:SyncLogPath) {
            $fs = New-Object System.IO.FileStream($Script:SyncLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($fs.Length -gt $Job.SyncLogOffset) {
                    $fs.Seek($Job.SyncLogOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                    # Captured before the reader is closed below: closing the
                    # StreamReader also closes $fs (it owns the stream by
                    # default), so $fs.Length is no longer readable afterward.
                    $newLength = $fs.Length
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    try {
                        $newText = $reader.ReadToEnd()
                    } finally {
                        $reader.Close()
                    }
                    if ($newText) {
                        $lines = $newText -split "`r`n|`n"
                        foreach ($l in $lines) {
                            if ($l.Length -gt 0) { $Job.log.Add($l) }
                        }
                    }
                    # Advance the offset past what was just consumed so a repeated
                    # poll while still running does not re-read and re-append the
                    # same lines every time.
                    $Job.SyncLogOffset = $newLength
                }
            } finally {
                # Already closed via $reader.Close() above when that path ran;
                # closing an already-closed FileStream is a documented no-op,
                # and this still covers the case where $reader was never
                # created (fs.Length was <= SyncLogOffset).
                $fs.Close()
            }
        }
    } catch {
        # tolerate transient read failures while the CLI is still writing
    }

    # CS1: best-effort read of the CLI's progress.json (UX-SPEC.md section
    # 4.2) - same shape/reasoning as the sync.log tail just above: the CLI
    # may be mid-write (Write-ProgressStep's own Move-Item -Force makes each
    # individual write atomic, but nothing stops this read from landing
    # between two writes), so a parse failure here is tolerated exactly like
    # a transient log-read failure is, never surfaced to the caller. Only
    # ever set for a job kind Start-Job actually threaded -ProgressPath for;
    # $Job.ProgressPath is $null (falsy) for every other kind, same guard
    # shape Write-ProgressStep itself uses CLI-side.
    if ($Job.ProgressPath) {
        try {
            if (Test-Path -LiteralPath $Job.ProgressPath) {
                $progressText = [System.IO.File]::ReadAllText($Job.ProgressPath, [System.Text.Encoding]::UTF8)
                if ($progressText -and $progressText.Trim().Length -gt 0) {
                    $progressObj = $progressText | ConvertFrom-Json -ErrorAction Stop
                    Add-Member -InputObject $Job -MemberType NoteProperty -Name 'progress' -Value $progressObj -Force
                }
            }
        } catch {
            # tolerate transient read/parse failures while the CLI is mid-write
        }
    }

    if (-not $Job.Process.HasExited) {
        return $Job
    }

    # E4: an 'import' job's process is one PHASE of a possibly-multi-step
    # sequence (see Build-ImportPlan/Complete-ImportPhase) rather than the
    # whole job, so its own finalize/advance logic is entirely separate from
    # the single-phase logic below, which every other job kind still uses
    # completely unchanged.
    if ($Job.kind -eq 'import') {
        return (Complete-ImportPhase -Job $Job)
    }
    # E12: switch-source is likewise a multi-phase job (see Start-SwitchSourceJob).
    if ($Job.kind -eq 'switch-source') {
        return (Complete-SwitchSourcePhase -Job $Job)
    }

    $exitCode = $Job.Process.ExitCode
    $Job.exitCode = $exitCode
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Read with ReadAllText, NOT Get-Content: Get-Content decorates the returned
    # string with PSPath/PSDrive/PSProvider note properties, and ConvertTo-Json
    # then walks the whole provider object graph (effectively hanging the server)
    # when that string ends up in a response.
    $stdout = ''
    try {
        if (Test-Path -LiteralPath $Job.OutFile) {
            $stdout = [System.IO.File]::ReadAllText($Job.OutFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stdout = '' }

    $stderr = ''
    try {
        if (Test-Path -LiteralPath $Job.ErrFile) {
            $stderr = [System.IO.File]::ReadAllText($Job.ErrFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stderr = '' }

    $parsed = $null
    $parseError = $null
    if ($stdout -and $stdout.Trim().Length -gt 0) {
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    if ($exitCode -eq 0 -and $parsed) {
        $Job.results = New-Object 'System.Collections.Generic.List[object]'
        if ($parsed.results) {
            foreach ($r in @($parsed.results)) { $Job.results.Add($r) }
        }
        $Job.state = 'done'

        Apply-JobCompletionSideEffects -Job $Job -Parsed $parsed

        if ($Job.LaunchAfter) {
            $Job.results.Add([PSCustomObject]@{ status = 'Launched'; name = 'World of Warcraft' })
            try {
                Start-Process -FilePath 'C:\Program Files (x86)\Battle.net\Battle.net.exe' -ArgumentList '--exec="launch WoW"' | Out-Null
            } catch {
                $Job.error = "Sync completed but failed to launch WoW: $($_.Exception.Message)"
            }
        }
    } else {
        $Job.state = 'failed'
        $errMsg = $stderr
        if (-not $errMsg -and $parseError) { $errMsg = "Could not parse CLI output as JSON: $parseError" }
        if (-not $errMsg) { $errMsg = "CLI exited with code $exitCode" }
        $Job.error = $errMsg

        # CS1 (UX-SPEC.md section 4.2): mirrors the success branch's own
        # Apply-JobCompletionSideEffects call just above - $Job.state/.error
        # are already set to their final failed values on the lines just
        # above, so the function's failure branch (see its own doc comment)
        # has everything it needs.
        Apply-JobCompletionSideEffects -Job $Job -Parsed $parsed
    }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    Clear-CurrentJobIfMatches -Job $Job

    # Round 3: persist lastRun + job history to state.json now that this
    # job's final state/results/error are all set (Apply-JobCompletionSideEffects,
    # above, already updated $Script:LastRun/UpdateAvailable/UpdatesCheckedAt
    # for a successful job, or $Script:LastCheckFailed/LastCheckError for a
    # failed one - see its own updated doc comment). Called once here for
    # BOTH the done and failed outcomes; CS1 changed
    # Apply-JobCompletionSideEffects itself to also run on both outcomes
    # (previously success-only), but this call still needs to stay right
    # here regardless, since it's this Save-CheckState that actually writes
    # either branch's bookkeeping to state.json - without it, a failed job
    # would still vanish from the persisted history on the next restart.
    Save-CheckState

    return $Job
}

function Get-JobStatusView {
    param($Job)

    if (-not $Job) {
        return $null
    }
    return [PSCustomObject]@{
        id         = $Job.id
        kind       = $Job.kind
        params     = $Job.params
        state      = $Job.state
        startedAt  = $Job.startedAt
        finishedAt = $Job.finishedAt
        exitCode   = $Job.exitCode
        log        = $Job.log.ToArray()
        results    = $Job.results.ToArray()
        error      = $Job.error
        # FLAVORS-SPEC.md CS-F2 S5.4: reading a NoteProperty that was never
        # added (a job created before this change set - see Load-CheckState's
        # own back-compat default) is always safe in PowerShell and returns
        # $null; the job-panel/switcher UI (CS-F4) treats a $null flavour the
        # same as 'retail'.
        flavour    = $Job.flavour
        # CS1 (UX-SPEC.md section 4.2): whatever Update-JobStatus's
        # best-effort progress.json read last parsed, or $null - reading a
        # NoteProperty that was never added (a job kind with no
        # -ProgressPath, or one never polled while running) is always safe
        # in PowerShell, unlike writing one.
        progress   = $Job.progress
        # FLAVORS-SPEC.md CS-F3 S5.5 case 5: {id,label} pairs for a job in
        # state 'awaiting_flavour' - $null (safe NoteProperty read) for
        # every other job, exactly like .progress above.
        choices    = $Job.choices
    }
}

function Get-CurrentOrLastJobSummary {
    <#
      FLAVORS-SPEC.md CS-F2 S5.4: -Flavor (default $Script:CurrentFlavour)
      scopes both halves of "current OR last job" to that one flavour - the
      in-flight slot (Get-CurrentJobForFlavour) and, when nothing is
      currently running for it, the most recent HISTORY entry that ALSO
      belongs to that flavour (never an unrelated flavour's more-recent
      job) - this is what makes /api/state's per-flavour `job`/freshness
      correct on a multi-flavour machine.
    #>
    param([string]$Flavor)

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $current = Get-CurrentJobForFlavour -Flavor $Flavor
    if ($current) {
        return Get-JobStatusView -Job (Update-JobStatus -Job $current)
    }
    for ($i = $Script:Jobs.Count - 1; $i -ge 0; $i--) {
        $j = $Script:Jobs[$i]
        # FLAVORS-SPEC.md CS-F3: an 'awaiting_flavour' job is, by
        # construction, NOT resolved to any one flavour yet (its own
        # .flavour is $null for exactly that reason) - skipped here rather
        # than falling into the "no .flavour -> defaults to retail"
        # back-compat rule just below, which exists for a pre-CS-F2 job
        # loaded with no .flavour field at all and would otherwise
        # incorrectly attribute this still-ambiguous job to Retail's own
        # "last job" summary.
        if ($j.state -eq 'awaiting_flavour') { continue }
        $jFlavour = $j.flavour
        if (-not $jFlavour) { $jFlavour = 'retail' }
        if ($jFlavour -eq $Flavor) {
            return Get-JobStatusView -Job $j
        }
    }
    return $null
}

function Get-PendingFlavourChoiceJob {
    <#
      Security-review fix: a job in state 'awaiting_flavour' is, by design,
      never attributed to (or surfaced through) any one flavour's own
      /api/state.job field - Get-CurrentOrLastJobSummary explicitly skips
      it (see its own comment) because it does not belong to any flavour
      yet. That left a real gap: curseforge-handler.vbs (invoked by the
      OS-registered curseforge:// protocol handler from the user's regular
      browser, entirely separate from this SPA) POSTs /api/jobs and only
      ever inspects the HTTP status code - never the response body's jobId
      - so when the target addon matches more than one installed flavour
      and the server creates an 'awaiting_flavour' job, NOTHING in this
      codebase ever surfaced it: no picker, no toast, no error, the job
      just sat unresolved forever while the user stared at a Furphy window
      that appeared to do nothing.

      This surfaces that same job machine-wide (regardless of the
      request's own ?flavour=/active flavour) so the SPA's existing
      /api/state polling (ui/app.js reloadState) can discover it and
      render the already-built awaiting_flavour picker (Components.
      JobPanel) no matter which flavour happens to be active. Deliberately
      conservative about WHEN it reports one: only while that job is still
      the very last entry in $Script:Jobs. Resuming it (Actions.
      resumeJobWithFlavour re-POSTs the identical body with an explicit
      ?flavour=, which always creates a BRAND NEW job per Start-Job's own
      comment - there is no "resume this exact job" endpoint) appends a
      newer job right after it, so this stops reporting the old one
      automatically the moment it's acted on (or superseded by any other
      job) - it can never resurface a resolved/abandoned ask indefinitely.
    #>
    if (-not $Script:Jobs -or $Script:Jobs.Count -eq 0) { return $null }
    $last = $Script:Jobs[$Script:Jobs.Count - 1]
    if ($last.state -eq 'awaiting_flavour') {
        return Get-JobStatusView -Job $last
    }
    return $null
}

function Get-ComputedFreshness {
    <#
      CS1 (UX-SPEC.md sections 2.1/4.2): the one freshness enum, computed
      server-side so the client "never derives freshness from other
      fields" per that spec's own rule. One new value each call - never
      cached - from the existing check state plus whichever job is current:
        checking          - a sync/check/add/install job (the kinds that
                             actually touch CurseForge/Wago) is running now.
        check_failed       - the most recent such job ended in $Job.state
                             'failed' (Apply-JobCompletionSideEffects' new
                             failure branch is what sets this).
        not_checked        - nothing has ever completed a check/sync.
        updates_available  - $Script:UpdateAvailable has at least one entry.
        up_to_date          - none of the above.
      -CurrentJobView is the same Get-JobStatusView-shaped object
      Handle-State already computes for its own "job" field - passed in
      rather than recomputed here so a single /api/state call never polls
      the running job's Update-JobStatus twice.

      FLAVORS-SPEC.md CS-F2 S5.3: gains -Flavor (default
      $Script:CurrentFlavour) - every field below is read from that ONE
      flavour's own bucket, so a Retail sync running concurrently with a
      Classic Era job never makes Classic Era's own freshness read
      "checking" (or vice versa).
    #>
    param($CurrentJobView, [string]$Flavor)

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    if ($CurrentJobView -and $CurrentJobView.state -eq 'running' -and (@('sync', 'check', 'add', 'install', 'launch') -contains $CurrentJobView.kind)) {
        return 'checking'
    }
    if (Get-FlavourLastCheckFailed -Flavor $Flavor) {
        return 'check_failed'
    }
    if (-not (Get-FlavourUpdatesCheckedAt -Flavor $Flavor)) {
        return 'not_checked'
    }
    $upd = Get-FlavourUpdateAvailable -Flavor $Flavor
    if ($upd -and $upd.Count -gt 0) {
        return 'updates_available'
    }
    return 'up_to_date'
}

# =====================================================================
# Invoke-Cli: synchronous CLI call, used by the fast/inline operations
# =====================================================================

function Invoke-Cli {
    <# Runs addon-sync.ps1 with the given args, waits (up to TimeoutSec), and returns the parsed -Json output. Throws on failure. #>
    param(
        [string[]]$CliArgs,
        [int]$TimeoutSec = 60
    )

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }

    $token = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "sync-$token.out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "sync-$token.err"

    $argsList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in $CliArgs) { $argsList.Add($a) }
    $psArgs = New-CliProcessArgs -CliArgs $argsList

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # See Start-Job: force the SafeProcessHandle to materialize now so that
        # reading .ExitCode below is reliable.
        $proc.Handle | Out-Null
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "CLI call timed out after $TimeoutSec seconds"
        }

        $exitCode = $proc.ExitCode
        # ReadAllText, not Get-Content (see Update-JobStatus): the text may end up in a JSON error response.
        $stdout = ''
        if (Test-Path -LiteralPath $outFile) {
            try { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } catch { $stdout = '' }
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            try { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } catch { $stderr = '' }
        }

        if ($exitCode -ne 0) {
            $msg = $stderr
            if (-not $msg) { $msg = "CLI exited with code $exitCode" }
            throw $msg
        }
        if (-not $stdout -or $stdout.Trim().Length -eq 0) {
            throw 'CLI produced no output'
        }

        try {
            return ($stdout | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            throw "Could not parse CLI output as JSON: $($_.Exception.Message)"
        }
    } finally {
        try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

# =====================================================================
# Invoke-ProtocolScript: synchronous register-protocol.ps1 call (E19)
# =====================================================================

function Invoke-ProtocolScript {
    <#
      Runs E17's existing, unchanged register-protocol.ps1 (the curseforge://
      handler registration script - see SPEC "register-protocol.ps1") with
      -Json and one of -Status/-Register/-Unregister, waits (up to
      TimeoutSec), and returns the parsed JSON status object. Same
      hidden-child-process / redirected-output / parsed-JSON / quoted-path
      shape as Invoke-Cli above (the space-containing ROOT path is quoted the
      same way); throws on failure or timeout - callers
      (Handle-ProtocolStatus/Register/Unregister) catch and turn that into a
      500, matching every other route handler's contract.
    #>
    param(
        [string]$Switch,
        [int]$TimeoutSec = 30
    )

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }

    $token = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "protocol-$token.out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "protocol-$token.err"

    $psArgs = New-Object 'System.Collections.Generic.List[object]'
    $psArgs.Add('-NoProfile')
    $psArgs.Add('-ExecutionPolicy')
    $psArgs.Add('Bypass')
    # Start-Process joins -ArgumentList elements with spaces and does NOT
    # quote them, so paths with spaces (C:\Program Files (x86)\... /
    # $Script:Root itself) must be quoted here - same reasoning as
    # New-CliProcessArgs above.
    $psArgs.Add('-File')
    $psArgs.Add('"' + $Script:RegisterProtocolPath + '"')
    $psArgs.Add('-' + $Switch)
    $psArgs.Add('-Json')

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # See Invoke-Cli/Start-Job: force the SafeProcessHandle to
        # materialize now so that reading .ExitCode later is reliable.
        $proc.Handle | Out-Null
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "register-protocol.ps1 -$Switch timed out after $TimeoutSec seconds"
        }

        $exitCode = $proc.ExitCode
        $stdout = ''
        if (Test-Path -LiteralPath $outFile) {
            try { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } catch { $stdout = '' }
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            try { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } catch { $stderr = '' }
        }

        if ($exitCode -ne 0) {
            $msg = $stderr
            if (-not $msg) { $msg = "register-protocol.ps1 -$Switch exited with code $exitCode" }
            throw $msg
        }
        if (-not $stdout -or $stdout.Trim().Length -eq 0) {
            throw 'register-protocol.ps1 produced no output'
        }

        try {
            return ($stdout | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            throw "Could not parse register-protocol.ps1 output as JSON: $($_.Exception.Message)"
        }
    } finally {
        try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

# =====================================================================
# Wago Addons proxy (E12) - keyless. Mirrors addon-sync.ps1's own Wago
# functions closely (same Inertia handshake/pacing/retry shape), duplicated
# here rather than dot-sourced - this script is always launched standalone
# and never dot-sources the CLI, the same pattern already used for
# Resolve-EffectiveAddonsPath/Get-PresentAddonFolders elsewhere in this file.
# Verified facts live in SPEC.md's "Wago Addons access facts" section.
# =====================================================================

function Get-WagoExceptionStatusCode {
    param($ErrorRecord)
    $code = 0
    try {
        if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
            $code = [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch {
        $code = 0
    }
    return $code
}

function Invoke-WagoHttpRequest {
    <# Server-side counterpart to addon-sync.ps1's Invoke-WagoRequest - same 300ms pacing, same 429/503 retry-once-after-5s. #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers
    )

    $mergedHeaders = @{ 'Accept' = 'text/html, application/xhtml+xml' }
    if ($Headers) {
        foreach ($k in $Headers.Keys) { $mergedHeaders[$k] = $Headers[$k] }
    }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

    $maxAttempts = 2
    $attempt = 0
    $lastError = $null
    $result = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $shouldRetry = $false
        $lastError = $null
        try {
            $result = Invoke-WebRequest -Uri $Uri -Headers $mergedHeaders -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        } catch {
            $lastError = $_
            $statusCode = Get-WagoExceptionStatusCode -ErrorRecord $_
            if (($statusCode -eq 429 -or $statusCode -eq 503) -and ($attempt -lt $maxAttempts)) {
                Write-ServerLog "HTTP $statusCode from $Uri (Wago) - waiting 5 seconds and retrying"
                $shouldRetry = $true
            }
        }
        Start-Sleep -Milliseconds 300
        if (-not $lastError) { return $result }
        if (-not $shouldRetry) { throw $lastError }
        Start-Sleep -Seconds 5
    }
    if ($lastError) { throw $lastError }
    return $result
}

function Get-WagoInertiaHandshake {
    <# Plain-HTML handshake: reads #app's data-page JSON, returns {version; props}. #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    $response = Invoke-WagoHttpRequest -Uri $PageUri -Headers @{ 'Accept' = 'text/html, application/xhtml+xml' }
    if (-not $response -or -not $response.Content) {
        throw "Empty response reading Wago page $PageUri"
    }
    if ($response.Content -notmatch 'id="app"[^>]*data-page="([^"]*)"') {
        throw "Could not find #app data-page attribute on Wago page $PageUri"
    }
    $decoded = [System.Net.WebUtility]::HtmlDecode($Matches[1])
    $page = $decoded | ConvertFrom-Json -ErrorAction Stop
    if (-not $page.version) {
        throw "Wago page data-page JSON had no version field ($PageUri)"
    }
    return [PSCustomObject]@{ version = $page.version; props = $page.props }
}

function Invoke-WagoInertiaJson {
    <#
      Fetches one Wago page's props via the X-Inertia XHR protocol.
      $Script:WagoInertiaVersion caches the working version for the life of
      this server process (persisted to/reloaded from state.json - see
      Save-CheckState/Load-CheckState) so only the FIRST Wago request this
      process ever makes pays the plain-HTML handshake; a 409 (version
      changed server-side) refreshes it and retries once, per SPEC.
    #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    if (-not $Script:WagoInertiaVersion) {
        $handshake = Get-WagoInertiaHandshake -PageUri $PageUri
        $Script:WagoInertiaVersion = $handshake.version
        return $handshake.props
    }

    $headers = @{
        'X-Inertia'         = 'true'
        'X-Inertia-Version' = $Script:WagoInertiaVersion
        'X-Requested-With'  = 'XMLHttpRequest'
        'Accept'            = 'text/html, application/xhtml+xml'
    }

    try {
        $response = Invoke-WagoHttpRequest -Uri $PageUri -Headers $headers
    } catch {
        $statusCode = Get-WagoExceptionStatusCode -ErrorRecord $_
        if ($statusCode -eq 409) {
            Write-ServerLog "Wago Inertia version stale, refreshing ($PageUri)"
            $handshake = Get-WagoInertiaHandshake -PageUri $PageUri
            $Script:WagoInertiaVersion = $handshake.version
            $headers['X-Inertia-Version'] = $Script:WagoInertiaVersion
            $response = Invoke-WagoHttpRequest -Uri $PageUri -Headers $headers
        } else {
            throw
        }
    }

    if (-not $response -or -not $response.Content) {
        throw "Empty response from Wago Inertia request $PageUri"
    }
    $json = $response.Content | ConvertFrom-Json -ErrorAction Stop
    return $json.props
}

function Get-WagoCached {
    <#
      5-minute in-memory cache around Invoke-WagoInertiaJson, keyed by the
      full page URI - its own separate hashtable/cleanup logic, distinct
      from the other on-disk/in-memory caches this server keeps (e.g.
      $Script:CfCatalogueIndex), so a bug in one can't reach another's.
    #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    if ($Script:WagoCache.ContainsKey($PageUri)) {
        $entry = $Script:WagoCache[$PageUri]
        $age = (Get-Date) - $entry.Time
        if ($age.TotalSeconds -lt 300) {
            return $entry.Props
        }
        $Script:WagoCache.Remove($PageUri)
    }

    $props = Invoke-WagoInertiaJson -PageUri $PageUri

    if ($Script:WagoCache.Count -ge 200) {
        $now = Get-Date
        $staleKeys = New-Object 'System.Collections.Generic.List[object]'
        foreach ($k in $Script:WagoCache.Keys) {
            $age = $now - $Script:WagoCache[$k].Time
            if ($age.TotalSeconds -ge 300) { $staleKeys.Add($k) }
        }
        foreach ($k in $staleKeys) { $Script:WagoCache.Remove($k) }
        if ($Script:WagoCache.Count -ge 200) { $Script:WagoCache.Clear() }
    }
    $Script:WagoCache[$PageUri] = @{ Time = (Get-Date); Props = $props }
    return $props
}

function ConvertFrom-WagoSearchCardHtml {
    <#
      SPEC's verified Wago facts document /?search=... as returning
      props.addons.data[] items that are server-rendered HTML CARD SNIPPETS,
      not plain objects - parsed here with regexes for the addon URL (slug),
      the <h3> title, and a cdn.wago.io thumbnail <img src>, per SPEC's own
      description of what to look for. Never throws: a card whose markup
      doesn't match a given piece just leaves that field $null.

      Fix pass: the thumbnail regex used to require a quoted src="..."
      attribute, but Wago's actual server-rendered card markup emits it
      UNQUOTED on its own line (e.g. "src=https://cdn.wago.io/thumbnails/
      xyz.png") - verified live, every card's thumbnail came back $null.
      Quotes are now optional around the URL, matched non-greedily against
      whitespace/">"/a matching quote so it still stops at the right place
      whichever style a given card uses.
    #>
    param([string]$Html)

    if (-not $Html) { return $null }
    $slug = $null
    $name = $null
    $thumb = $null
    if ($Html -match 'href="https://addons\.wago\.io/addons/([a-z0-9-]+)"') { $slug = $Matches[1] }
    if ($Html -match '<h3[^>]*>([^<]*)</h3>') { $name = [System.Net.WebUtility]::HtmlDecode($Matches[1]).Trim() }
    if ($Html -match 'src=["'']?(https://cdn\.wago\.io/thumbnails/[^"''\s>]+)') { $thumb = $Matches[1] }
    if (-not $slug) { return $null }
    return [PSCustomObject]@{ slug = $slug; name = $name; thumbnail = $thumb }
}

function Handle-WagoSearch {
    <#
      GET /api/wago/search?q=&categoryId=&sort=&page= -> {items, page, lastPage, total}.

      Verified live defect (fixed here): Wago's own site only recognises
      sort=name. Sending ANY other sort value (popular/downloads/recent/
      newest/likes/trending/latest/top, etc.) makes it silently IGNORE the
      search parameter entirely and return the plain popularity listing;
      sort=updated returns an empty list outright. Omitting sort altogether
      is what actually gives relevance/popularity-ordered search results.
      So: sort=name is passed through verbatim (the only value Wago
      accepts), and every other value - including the UI's own
      popular/relevance/empty defaults and any unrecognised value - is
      simply never sent upstream at all.
    #>
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $search = $q['q']
    $categoryId = $q['categoryId']
    $sort = $q['sort']
    $page = Get-QueryOrDefault -QueryString $q -Name 'page' -Default '1'

    # FLAVORS-SPEC.md CS-F2 S4.6/S6.4: game_version is resolved from this
    # request's own flavour (Set-CurrentFlavourContext, via Invoke-Route)
    # instead of the hardcoded 'retail' literal - Get-CfFlavourMapping's
    # WagoField already centralizes the static retail/classic_era values and
    # 'classic''s dynamic per-Interface resolution (S2.4). Byte-identical to
    # today on a Retail-only machine (WagoField resolves to 'retail').
    $wagoMapping = Get-CfFlavourMapping -Flavor $Script:CurrentFlavour -InstalledInterface $Script:ClientBuildInfo.clientInterface
    $wagoGameVersion = $wagoMapping.WagoField
    if (-not $wagoGameVersion) { $wagoGameVersion = 'retail' }

    $uri = 'https://addons.wago.io/?game_version=' + [System.Uri]::EscapeDataString($wagoGameVersion) + '&page=' + [System.Uri]::EscapeDataString($page)
    if ($search) { $uri += '&search=' + [System.Uri]::EscapeDataString($search) }
    if ($categoryId) { $uri += '&category=' + [System.Uri]::EscapeDataString($categoryId) }
    if ($sort -eq 'name') { $uri += '&sort=name' }

    try {
        $props = Get-WagoCached -PageUri $uri
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }

    $items = New-Object 'System.Collections.Generic.List[object]'
    $paginator = $props.addons
    if ($paginator -and $paginator.data) {
        foreach ($cardHtml in @($paginator.data)) {
            $card = ConvertFrom-WagoSearchCardHtml -Html ([string]$cardHtml)
            if ($card) { $items.Add($card) }
        }
    }

    $body = [PSCustomObject]@{
        items    = $items.ToArray()
        page     = $(if ($paginator -and $paginator.current_page) { [int]$paginator.current_page } else { 1 })
        lastPage = $(if ($paginator -and $paginator.last_page) { [int]$paginator.last_page } else { 1 })
        total    = $(if ($paginator -and $paginator.total) { [int]$paginator.total } else { $items.Count })
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Handle-WagoCategories {
    <# GET /api/wago/categories -> props.allCategories from the search page. #>
    param($Context, $RouteMatch)

    try {
        $props = Get-WagoCached -PageUri 'https://addons.wago.io/?game_version=retail'
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    $cats = @()
    if ($props.allCategories) { $cats = $props.allCategories }
    Send-Json -Context $Context -StatusCode 200 -Body @{ data = $cats }
}

function Handle-WagoAddonDetails {
    <# GET /api/wago/addons/{slug} -> {addon, description, metadata}. #>
    param($Context, $RouteMatch)

    $slug = $RouteMatch['slug']
    try {
        $props = Get-WagoCached -PageUri ('https://addons.wago.io/addons/' + [System.Uri]::EscapeDataString($slug))
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    if (-not $props -or -not $props.addon) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ addon = $props.addon; description = $props.description; metadata = $props.metadata }
}

function Handle-WagoAddonReleases {
    <# GET /api/wago/addons/{slug}/releases?page= -> the props.releases paginator, as-is. #>
    param($Context, $RouteMatch)

    $slug = $RouteMatch['slug']
    $q = $Context.Request.QueryString
    $page = Get-QueryOrDefault -QueryString $q -Name 'page' -Default '1'
    $uri = 'https://addons.wago.io/addons/' + [System.Uri]::EscapeDataString($slug) + '/versions?page=' + [System.Uri]::EscapeDataString($page)

    try {
        $props = Get-WagoCached -PageUri $uri
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    if (-not $props -or -not $props.releases) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ data = $props.releases }
}

function Handle-WagoAddonGallery {
    <#
      GET /api/wago/addons/{slug}/gallery. SPEC's verified facts leave this
      page's exact prop shape as "inspect and document" (unlike every other
      Wago endpoint here, which SPEC nails down precisely) - relayed as-is
      under a {gallery: <props>} wrapper rather than reshaped into a
      specific documented shape this build cannot verify against the live
      site (no Wago requests were made during this build - see SPEC/
      CHANGELOG's Wago Addons access facts note).
    #>
    param($Context, $RouteMatch)

    $slug = $RouteMatch['slug']
    $uri = 'https://addons.wago.io/addons/' + [System.Uri]::EscapeDataString($slug) + '/gallery'
    try {
        $props = Get-WagoCached -PageUri $uri
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ gallery = $props }
}

function Handle-WagoResolve {
    <#
      GET /api/wago/resolve?url=<wago url or slug> -> {slug}. Unlike CF's
      resolve (which needs a search API call to turn a slug into a numeric
      id), a Wago addon's identity already IS its slug - this is pure string
      parsing, no network call, no cache entry.
    #>
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $raw = $q['url']
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
        return
    }
    $value = $raw.Trim()
    $slug = $null
    if ($value -match '(?i)^https?://addons\.wago\.io/addons/([a-z0-9-]+)') {
        $slug = $Matches[1]
    } elseif ($value -match '^[a-zA-Z0-9-]+$') {
        $slug = $value
    }
    if (-not $slug) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ slug = $slug }
}

# =====================================================================
# Keyless CurseForge enrichment (E16) - three new, independently-verified,
# purely additive metadata sources for a CurseForge-sourced record when no
# API key is configured: an offline catalogue index (instawow-data, with
# strongbox-catalogue as coverage insurance), a live addon-radar.com mirror
# (paced/cached like the CurseForge-website and Wago proxies above), and
# E12's own Wago Addons integration (a toc-derived cross-id first, then a
# conservative name+author auto-match). None of this can install anything -
# read-only enrichment only, consulted ONLY when no key is configured; the
# key-gated /api/cf/* proxy above is completely untouched, including its
# 409 {error:"no-key"} contract. Verified facts live in SPEC.md's "Keyless
# enrichment sources" section.
# =====================================================================

function Load-CfCatalogueIndexFromDisk {
    <# Loads ROOT\cache\cf-catalogue.json into $Script:CfCatalogueIndex/$Script:CfCatalogueById/$Script:CfCatalogueFetchedAt/$Script:CfCatalogueSource. Returns $true on success, $false if the file is missing/empty/corrupt (never throws). #>
    if (-not (Test-Path -LiteralPath $Script:CfCatalogueCachePath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $Script:CfCatalogueCachePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $entries = New-Object 'System.Collections.Generic.List[object]'
        $byId = @{}
        foreach ($e in @($obj.entries)) {
            $id = [string]$e.id
            if (-not $id) { continue }
            $entries.Add($e)
            $byId[$id] = $e
        }
        $Script:CfCatalogueIndex = $entries.ToArray()
        $Script:CfCatalogueById = $byId
        $Script:CfCatalogueFetchedAt = [string]$obj.fetchedAt
        $Script:CfCatalogueSource = [string]$obj.source
        return $true
    } catch {
        Write-ServerLog "Failed to read cf-catalogue.json cache, ignoring: $($_.Exception.Message)"
        return $false
    }
}

function Save-CfCatalogueIndex {
    <#
      Forces a fresh fetch+merge+write of the CurseForge catalogue index:
      instawow-data's base-catalogue-v8.compact.json (100% coverage, the
      primary source - filtered to source:"curse" entries), then - paced
      >=1s after it, per SPEC's verified facts - strongbox-catalogue's
      curseforge-catalogue.json (54% coverage, frozen since 2022-01-22,
      consulted only as insurance for an id instawow-data might miss;
      instawow-data wins on any id collision). Updates the in-memory index
      and writes ROOT\cache\cf-catalogue.json (temp file + Move-Item,
      matching Save-CheckState's atomic-write pattern). Returns
      @{ ok; fetchedAt; count; source; error }. A strongbox failure is not
      fatal (instawow-data alone already has near-total coverage); an
      instawow-data failure IS fatal to this refresh and leaves whatever
      index was already loaded (possibly empty) untouched.
    #>
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
    $byId = @{}
    $source = 'instawow-data'

    try {
        $resp1 = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/layday/instawow-data/data/base-catalogue-v8.compact.json' -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data1 = $resp1.Content | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in @($data1.entries)) {
            if ([string]$entry.source -ne 'curse') { continue }
            $id = [string]$entry.id
            if (-not $id) { continue }
            $downloads = 0
            if ($entry.download_count) { $downloads = [int64]$entry.download_count }
            $byId[$id] = [PSCustomObject]@{
                id            = $id
                name          = [string]$entry.name
                slug          = [string]$entry.slug
                url           = [string]$entry.url
                downloadCount = $downloads
                lastUpdated   = [string]$entry.last_updated
            }
        }
    } catch {
        Write-ServerLog "CurseForge catalogue refresh: instawow-data fetch failed: $($_.Exception.Message)"
        return @{ ok = $false; fetchedAt = $Script:CfCatalogueFetchedAt; count = $Script:CfCatalogueIndex.Count; source = $Script:CfCatalogueSource; error = $_.Exception.Message }
    }

    Start-Sleep -Milliseconds 1000

    try {
        $resp2 = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/ogri-la/strongbox-catalogue/master/curseforge-catalogue.json' -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data2 = $resp2.Content | ConvertFrom-Json -ErrorAction Stop
        $list2 = $data2.'addon-summary-list'
        foreach ($entry in @($list2)) {
            if ([string]$entry.source -ne 'curseforge') { continue }
            $id = [string]$entry.'source-id'
            if (-not $id) { continue }
            if ($byId.ContainsKey($id)) { continue }   # instawow-data wins on collision
            $slug = $null
            $url = [string]$entry.url
            if ($url -match '/wow/addons/([^/?#]+)') { $slug = $Matches[1] }
            $name = [string]$entry.name
            if (-not $name) { $name = [string]$entry.label }
            $downloads = 0
            if ($entry.'download-count') { $downloads = [int64]$entry.'download-count' }
            $byId[$id] = [PSCustomObject]@{
                id            = $id
                name          = $name
                slug          = $slug
                url           = $url
                downloadCount = $downloads
                lastUpdated   = [string]$entry.'updated-date'
            }
        }
        $source = 'instawow-data+strongbox'
    } catch {
        Write-ServerLog "CurseForge catalogue refresh: strongbox-catalogue fetch failed (continuing with instawow-data only): $($_.Exception.Message)"
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $byId.Keys) { $entries.Add($byId[$k]) }

    $fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $cacheBody = [PSCustomObject]@{ fetchedAt = $fetchedAt; source = $source; entries = $entries.ToArray() }
    try {
        if (-not (Test-Path -LiteralPath $Script:CacheDir)) {
            New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
        }
        $json = ConvertTo-Json -InputObject $cacheBody -Depth 6
        $tmpPath = "$Script:CfCatalogueCachePath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $Script:CfCatalogueCachePath -Force
    } catch {
        Write-ServerLog "Failed to write cf-catalogue.json cache: $($_.Exception.Message)"
    }

    $Script:CfCatalogueIndex = $entries.ToArray()
    $Script:CfCatalogueById = $byId
    $Script:CfCatalogueFetchedAt = $fetchedAt
    $Script:CfCatalogueSource = $source

    Write-ServerLog "CurseForge catalogue refreshed: $($entries.Count) entries from $source"
    return @{ ok = $true; fetchedAt = $fetchedAt; count = $entries.Count; source = $source; error = $null }
}

function Initialize-CfCatalogueIndex {
    <#
      Called once at server startup. Loads ROOT\cache\cf-catalogue.json when
      present and fresh (<24h); fetches a new one when missing or stale.
      Best-effort: a fetch failure at startup leaves the index empty (or
      whatever stale copy is already on disk, loaded first as a fallback)
      rather than blocking the server from starting - Search-CfCatalogue/
      Get-CfCatalogueEntry both tolerate an empty index (no matches), which
      just means /api/cf/browse and /api/cf/enrich fall straight through to
      their next fallback (addon-radar / catalogue-only) until a refresh
      succeeds (automatically past the 24h mark, or via Settings >
      Maintenance > "Refresh CurseForge catalogue now").
    #>
    $loaded = Load-CfCatalogueIndexFromDisk
    $stale = $true
    if ($loaded -and $Script:CfCatalogueFetchedAt) {
        try {
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            $fetched = [DateTime]::ParseExact($Script:CfCatalogueFetchedAt, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
            $ageHours = ((Get-Date).ToUniversalTime() - $fetched).TotalHours
            $stale = ($ageHours -ge 24)
        } catch {
            $stale = $true
        }
    }
    if ($stale) {
        $result = Save-CfCatalogueIndex
        if (-not $result.ok) {
            Write-ServerLog "CurseForge catalogue index unavailable at startup (will retry on next restart or manual refresh): $($result.error)"
        }
    } else {
        Write-ServerLog "CurseForge catalogue loaded from disk cache: $($Script:CfCatalogueIndex.Count) entries, fetched $($Script:CfCatalogueFetchedAt)"
    }
}

function Search-CfCatalogue {
    <# Case-insensitive match against name: exact, then starts-with, then contains - each tier ordered by downloadCount descending. Returns at most $Limit entries. Never throws; empty on no index/no query/no match. #>
    param([string]$Query, [int]$Limit = 30)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Query) -or -not $Script:CfCatalogueIndex -or $Script:CfCatalogueIndex.Count -eq 0) {
        return Write-Output -NoEnumerate $out.ToArray()
    }
    $needle = $Query.Trim().ToLowerInvariant()
    $scored = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $Script:CfCatalogueIndex) {
        if (-not $e.name) { continue }
        $n = ([string]$e.name).ToLowerInvariant()
        $tier = -1
        if ($n -eq $needle) { $tier = 0 }
        elseif ($n.StartsWith($needle)) { $tier = 1 }
        elseif ($n.Contains($needle)) { $tier = 2 }
        if ($tier -ge 0) {
            $scored.Add([PSCustomObject]@{ Tier = $tier; Entry = $e; Downloads = [double]$e.downloadCount })
        }
    }
    $sorted = $scored | Sort-Object -Property Tier, @{ Expression = 'Downloads'; Descending = $true }
    foreach ($s in $sorted) {
        if ($out.Count -ge $Limit) { break }
        $out.Add($s.Entry)
    }
    return Write-Output -NoEnumerate $out.ToArray()
}

function Get-CfCatalogueEntry {
    <# O(1) lookup by CurseForge project id (string or number, compared as a string). $null when not indexed. #>
    param($ProjectId)
    if (-not $ProjectId) { return $null }
    $key = [string]$ProjectId
    if ($Script:CfCatalogueById.ContainsKey($key)) { return $Script:CfCatalogueById[$key] }
    return $null
}

function Get-CfCatalogueEntryBySlug {
    <#
      E19: exact, case-insensitive slug match against the same keyless
      catalogue index /api/cf/browse and Get-CfCatalogueEntry already use -
      the job kind 'add-by-slug' (the native host's CurseForge-tab install-
      link interception, host\FurphyHost.cs HandleSlugInstall) resolves a
      curseforge.com URL slug to a projectId through this before behaving
      like a normal 'add'. Linear scan (a few thousand entries, called at
      most once per add-by-slug job - never per-request, so no separate
      slug index is worth maintaining). $null when not found, the index is
      empty, or Slug is blank.
    #>
    param([string]$Slug)
    if ([string]::IsNullOrWhiteSpace($Slug)) { return $null }
    foreach ($e in $Script:CfCatalogueIndex) {
        if ($e.slug -and ([string]$e.slug).Equals($Slug, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $e
        }
    }
    return $null
}

function ConvertFrom-DevalueJson {
    <#
      addon-radar.com's __data.json responses are SvelteKit's "devalue" wire
      format, not plain JSON: a flat array where a value's fields can be
      integers that are themselves indices back into that SAME array (so a
      repeated/nested value only appears once in the payload). This is a
      purpose-built index-walking decoder.

      VERIFIED LIVE (this build) against both
      https://addon-radar.com/addon/{slug}/__data.json and
      https://addon-radar.com/search/__data.json: the JSON root is NOT the
      flat devalue array itself - it is a SvelteKit envelope object,
      {"type":"data","nodes":[null,{"type":"data","data":[<flat array>]}]}.
      "nodes" holds one entry per matched route segment (an earlier segment
      with no load function contributes $null); the real flat devalue array
      to index into is the "data" array carried by the last node that has
      one (the deepest/most specific route segment - the page itself). This
      function unwraps to that array before resolving any index. If the
      root does not look like that envelope (no PSCustomObject/'nodes', or
      no node carries a 'data' array) it falls back to treating the parsed
      root itself as the flat array, for resilience against a differently-
      shaped payload.

      Beyond the envelope unwrap, the exact field names inside the
      resolved objects were only spot-checked (id/name/slug/etc.) so
      callers (ConvertTo-AddonRadarDetail, Get-AddonRadarSearchRows) still
      treat the result defensively rather than assuming every field is
      present. Given the resolved flat array, this resolves every integer
      field/array-element that IS a valid in-range index into the node it
      points to, recursively, with cycle protection. A field that is
      genuinely just small integer DATA (not a reference) cannot be told
      apart from a real index by shape alone, so a value out of range (or
      inside the wrong array) is always left as literal data rather than
      guessed at.
      Never throws - returns $null on any parse failure or empty input.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        $parsed = $Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $parsed) { return $null }

    # Unwrap the SvelteKit {type,nodes:[...]} envelope to the real flat
    # devalue array (the 'data' array of the last node that carries one)
    # before any index resolution - see the function comment above.
    $arr = $null
    if (($parsed -is [System.Management.Automation.PSCustomObject]) -and ($parsed.PSObject.Properties.Name -contains 'nodes') -and $parsed.nodes) {
        foreach ($node in @($parsed.nodes)) {
            if ($node -and ($node.PSObject.Properties.Name -contains 'data') -and ($node.data -is [System.Array])) {
                $arr = @($node.data)
            }
        }
    }
    if (-not $arr) { $arr = @($parsed) }
    if ($arr.Count -eq 0) { return $null }

    $cache = @{}
    $resolving = New-Object 'System.Collections.Generic.HashSet[int]'

    function Resolve-DevalueValue {
        param($Node)
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            $result = [PSCustomObject]@{}
            foreach ($p in $Node.PSObject.Properties) {
                Add-Member -InputObject $result -NotePropertyName $p.Name -NotePropertyValue (Resolve-DevalueField -Value $p.Value)
            }
            return $result
        }
        if ($Node -is [System.Array]) {
            $out = New-Object 'System.Collections.Generic.List[object]'
            foreach ($item in $Node) { $out.Add((Resolve-DevalueField -Value $item)) }
            return Write-Output -NoEnumerate $out.ToArray()
        }
        return $Node
    }

    function Resolve-DevalueField {
        param($Value)
        # ConvertFrom-Json on Windows PowerShell 5.1 (.NET Framework, not
        # .NET 7+) deserializes a JSON integer as Int32/Int64 and only falls
        # back to Double for a value that overflows Int64 or carries a
        # fractional/exponent part - neither of which is a plausible devalue
        # array index - so only the integer types are ever treated as a
        # reference here; a genuine Double is always literal data.
        if ($Value -is [int] -or $Value -is [long]) {
            $i = [int]$Value
            if ($i -ge 0 -and $i -lt $arr.Count) { return (Resolve-DevalueIndex -Idx $i) }
            return $Value
        }
        return (Resolve-DevalueValue -Node $Value)
    }

    function Resolve-DevalueIndex {
        param([int]$Idx)
        if ($cache.ContainsKey($Idx)) { return $cache[$Idx] }
        if ($Idx -lt 0 -or $Idx -ge $arr.Count) { return $null }
        if ($resolving.Contains($Idx)) { return $null }   # cycle guard
        [void]$resolving.Add($Idx)
        $value = Resolve-DevalueValue -Node $arr[$Idx]
        [void]$resolving.Remove($Idx)
        $cache[$Idx] = $value
        return $value
    }

    return (Resolve-DevalueIndex -Idx 0)
}

function ConvertTo-AddonRadarDetail {
    <#
      Normalizes a devalue-decoded addon-radar.com detail payload into
      {id,name,slug,summary,descriptionHtml,authorName,logoUrl,downloadCount,
      gameVersions,lastUpdated,screenshots}. Round 9: a real captured
      /addon/{slug}/__data.json payload (catalogue-probe\bigwigs-data.json)
      showed the resolved root is a stats wrapper -
      {addon:<detail object>, dailyHistory, hourlyHistory, rankHistory,
      relatedAddons, authorAddons, dataHints} - with every field this
      function reads (id/name/slug/summary/description_html/screenshots/...)
      one level down, under .addon; the un-probed root has none of those
      names, so every real response fell through to the null/"unrecognized
      payload shape" case (confirmed against the diagnostics disk cache,
      cache\addon-radar\bigwigs.json, which held a cached $null detail from
      exactly this miss). .addon is checked first as the now-verified real
      shape; the decoded value itself, then .data, then .props, then
      .result remain as defensive fallbacks for a differently-shaped
      response, still returning $null (a total miss, handled by the caller
      falling through to catalogue-only) rather than guessing wrong. Never
      throws.
    #>
    param($Decoded)

    if ($null -eq $Decoded) { return $null }

    $candidate = $null
    foreach ($probe in @($Decoded.addon, $Decoded, $Decoded.data, $Decoded.props, $Decoded.result)) {
        if (-not $probe) { continue }
        $names = $probe.PSObject.Properties.Name
        if ($names -contains 'slug' -or $names -contains 'id') { $candidate = $probe; break }
    }
    if (-not $candidate) { return $null }

    $shots = New-Object 'System.Collections.Generic.List[object]'
    if ($candidate.screenshots) {
        foreach ($s in @($candidate.screenshots)) {
            $thumb = $s.thumbnail_url
            if (-not $thumb) { $thumb = $s.thumbnailUrl }
            $full = $s.url
            if (-not $full) { $full = $s.image }
            $shots.Add([PSCustomObject]@{ id = $s.id; title = $s.title; description = $s.description; thumbnail = $thumb; url = $full })
        }
    }
    $gameVersions = New-Object 'System.Collections.Generic.List[object]'
    if ($candidate.game_versions) { foreach ($v in @($candidate.game_versions)) { $gameVersions.Add([string]$v) } }

    return [PSCustomObject]@{
        id              = $candidate.id
        name            = $candidate.name
        slug            = $candidate.slug
        summary         = $candidate.summary
        descriptionHtml = $candidate.description_html
        authorName      = $candidate.author_name
        logoUrl         = $candidate.logo_url
        downloadCount   = $candidate.download_count
        gameVersions    = $gameVersions.ToArray()
        lastUpdated     = $candidate.last_updated_at
        screenshots     = $shots.ToArray()
    }
}

function Get-AddonRadarSearchRows {
    <#
      Defensively finds the results array within a devalue-decoded search
      payload - SPEC describes the shape as reachable via the decoded
      root's own .results.data path; a couple of other plausible roots are
      also tried since this build could not verify a live payload (see
      ConvertFrom-DevalueJson's own note). Never throws - empty array on
      any shape it doesn't recognize.
    #>
    param($Decoded)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Decoded) { return Write-Output -NoEnumerate $out.ToArray() }

    foreach ($c in @($Decoded.results, $Decoded.data, $Decoded)) {
        if (-not $c) { continue }
        $arr = $null
        if ($c.data) { $arr = $c.data }
        elseif ($c -is [System.Array]) { $arr = $c }
        if ($arr) {
            foreach ($row in @($arr)) {
                if ($row -and ($row.PSObject.Properties.Name -contains 'slug')) { $out.Add($row) }
            }
            if ($out.Count -gt 0) { break }
        }
    }
    return Write-Output -NoEnumerate $out.ToArray()
}

function Invoke-AddonRadarRequest {
    <# Paced (>=600ms between live requests) + retry-once-on-429/503 GET, mirroring Invoke-WagoHttpRequest's shape - same generic Get-WagoExceptionStatusCode helper (despite its Wago-specific name) reused here since both proxies live in this same process/file. #>
    param([Parameter(Mandatory = $true)][string]$Uri)

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
    $elapsed = ((Get-Date) - $Script:LastAddonRadarRequestTime).TotalMilliseconds
    if ($elapsed -lt 600) {
        Start-Sleep -Milliseconds ([int](600 - $elapsed))
    }

    $maxAttempts = 2
    $attempt = 0
    $lastError = $null
    $result = $null
    while ($attempt -lt $maxAttempts) {
        $attempt++
        $shouldRetry = $false
        $lastError = $null
        try {
            $result = Invoke-WebRequest -Uri $Uri -Headers @{ 'Accept' = 'application/json' } -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        } catch {
            $lastError = $_
            $statusCode = Get-WagoExceptionStatusCode -ErrorRecord $_
            if (($statusCode -eq 429 -or $statusCode -eq 503) -and ($attempt -lt $maxAttempts)) {
                Write-ServerLog "HTTP $statusCode from $Uri (addon-radar) - waiting 5 seconds and retrying"
                $shouldRetry = $true
            }
        }
        $Script:LastAddonRadarRequestTime = Get-Date
        if (-not $lastError) { return $result }
        if (-not $shouldRetry) { throw $lastError }
        Start-Sleep -Seconds 5
    }
    if ($lastError) { throw $lastError }
    return $result
}

function Get-AddonRadarDetail {
    <#
      addon-radar.com's per-addon detail (capability source #3, behind
      Wago, for descriptions/logos/screenshots). Cached both in-memory
      ($Script:AddonRadarCache) and on disk (ROOT\cache\addon-radar\
      <slug>.json) for 24h - checked before any live request, which is what
      keeps live addon-radar traffic bounded to first-time-viewed addons
      rather than growing with catalogue size or repeat views. Returns a
      normalized PSCustomObject (see ConvertTo-AddonRadarDetail) or $null
      (missing/unreachable/undecodable, INCLUDING a definitive miss - which
      is cached too, so a Wago-less/unmatched addon is not re-fetched on
      every drawer open). Never throws.
    #>
    param([Parameter(Mandatory = $true)][string]$Slug)

    $slugKey = $Slug.ToLowerInvariant()
    if ($Script:AddonRadarCache.ContainsKey($slugKey)) {
        $entry = $Script:AddonRadarCache[$slugKey]
        if (((Get-Date) - $entry.Time).TotalHours -lt 24) { return $entry.Detail }
    }

    $diskPath = Join-Path -Path $Script:AddonRadarCacheDir -ChildPath ($slugKey + '.json')
    if (Test-Path -LiteralPath $diskPath) {
        try {
            $raw = Get-Content -LiteralPath $diskPath -Raw -Encoding UTF8 -ErrorAction Stop
            $cached = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($cached.fetchedAt) {
                $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                $fetched = [DateTime]::ParseExact([string]$cached.fetchedAt, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
                if (((Get-Date).ToUniversalTime() - $fetched).TotalHours -lt 24) {
                    $detail = $cached.detail
                    $Script:AddonRadarCache[$slugKey] = @{ Time = (Get-Date); Detail = $detail }
                    return $detail
                }
            }
        } catch {
            # Corrupt/unreadable disk cache entry - fall through to a live fetch.
        }
    }

    $detail = $null
    try {
        $uri = 'https://addon-radar.com/addon/' + [System.Uri]::EscapeDataString($Slug) + '/__data.json'
        $resp = Invoke-AddonRadarRequest -Uri $uri
        $decoded = ConvertFrom-DevalueJson -Text $resp.Content
        $detail = ConvertTo-AddonRadarDetail -Decoded $decoded
    } catch {
        Write-ServerLog "addon-radar detail fetch failed for slug '$Slug': $($_.Exception.Message)"
        $detail = $null
    }

    $Script:AddonRadarCache[$slugKey] = @{ Time = (Get-Date); Detail = $detail }
    try {
        if (-not (Test-Path -LiteralPath $Script:AddonRadarCacheDir)) {
            New-Item -ItemType Directory -Path $Script:AddonRadarCacheDir -Force | Out-Null
        }
        $cacheBody = [PSCustomObject]@{ fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); detail = $detail }
        $json = ConvertTo-Json -InputObject $cacheBody -Depth 8
        $tmpPath = "$diskPath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $diskPath -Force
    } catch {
        Write-ServerLog "Failed to write addon-radar disk cache for slug '$Slug': $($_.Exception.Message)"
    }

    return $detail
}

function Search-AddonRadar {
    <#
      Free-text addon-radar.com search - supplemental to the offline
      catalogue when it returns few/no hits for a query (Handle-CfBrowse's
      own threshold). NOT an id lookup - SPEC's own verified facts warn
      against ever treating result #1 as authoritative for a specific known
      id; this is for free-text discovery only. Cached 24h per lowercased
      query, in-memory only. Never throws - empty array on any failure.
    #>
    param([string]$Query, [int]$Limit = 30)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Query)) { return Write-Output -NoEnumerate $out.ToArray() }

    $cacheKey = $Query.Trim().ToLowerInvariant()
    if ($Script:AddonRadarSearchCache.ContainsKey($cacheKey)) {
        $entry = $Script:AddonRadarSearchCache[$cacheKey]
        if (((Get-Date) - $entry.Time).TotalHours -lt 24) {
            foreach ($it in @($entry.Items)) {
                if ($out.Count -ge $Limit) { break }
                $out.Add($it)
            }
            return Write-Output -NoEnumerate $out.ToArray()
        }
    }

    $normalizedItems = New-Object 'System.Collections.Generic.List[object]'
    try {
        $uri = 'https://addon-radar.com/search/__data.json?q=' + [System.Uri]::EscapeDataString($Query)
        $resp = Invoke-AddonRadarRequest -Uri $uri
        $decoded = ConvertFrom-DevalueJson -Text $resp.Content
        $rows = Get-AddonRadarSearchRows -Decoded $decoded
        foreach ($row in $rows) {
            $normalizedItems.Add([PSCustomObject]@{
                id            = $row.id
                name          = $row.name
                slug          = $row.slug
                downloadCount = $row.download_count
                lastUpdated   = $row.last_updated_at
                logoUrl       = $row.logo_url
            })
        }
    } catch {
        Write-ServerLog "addon-radar search failed for '$Query': $($_.Exception.Message)"
    }

    $Script:AddonRadarSearchCache[$cacheKey] = @{ Time = (Get-Date); Items = $normalizedItems.ToArray() }

    foreach ($it in $normalizedItems) {
        if ($out.Count -ge $Limit) { break }
        $out.Add($it)
    }
    return Write-Output -NoEnumerate $out.ToArray()
}

function Get-WagoAutoMatchNormalizedName {
    <# Lowercased, trimmed, with a trailing parenthetical/subtitle stripped (e.g. "BigWigs (Boss Timers & Tools)" -> "bigwigs") so a Wago listing's own subtitle style doesn't defeat an otherwise-exact name match. #>
    param([string]$Value)
    if (-not $Value) { return '' }
    $v = [regex]::Replace($Value, '\s*\([^)]*\)\s*$', '')
    return $v.Trim().ToLowerInvariant()
}

function Get-WagoAutoMatch {
    <#
      A conservative "is this CurseForge-tracked addon also on Wago"
      probe, used only when the record's own toc has no X-Wago-ID tag at
      all (Get-CfEnrichmentNoKey's caller-side guard). Reuses E12's own
      Wago search/detail machinery (Get-WagoCached) rather than duplicating
      it. A candidate is accepted ONLY when its search-card name equals the
      queried name case-insensitively (trailing parenthetical stripped on
      both sides) AND at least one of its detail page's developer names
      equals (or is a substring, either direction, of) the queried author
      case-insensitively - never on name similarity alone, never assuming
      result #1 is the match, per SPEC's verified matching rule. Result
      (including a definitive miss) cached 24h per (name,author) pair.
      Returns @{ slug } or $null. Never throws.
    #>
    param([string]$Name, [string]$Author)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $cacheKey = $Name.Trim().ToLowerInvariant() + '|' + (([string]$Author).Trim().ToLowerInvariant())
    if ($Script:WagoAutoMatchCache.ContainsKey($cacheKey)) {
        $entry = $Script:WagoAutoMatchCache[$cacheKey]
        if (((Get-Date) - $entry.Time).TotalHours -lt 24) { return $entry.Match }
    }

    $match = $null
    try {
        $uri = 'https://addons.wago.io/?game_version=retail&search=' + [System.Uri]::EscapeDataString($Name)
        $props = Get-WagoCached -PageUri $uri
        $normName = Get-WagoAutoMatchNormalizedName -Value $Name
        if ($props -and $props.addons -and $props.addons.data) {
            foreach ($cardHtml in @($props.addons.data)) {
                $card = ConvertFrom-WagoSearchCardHtml -Html ([string]$cardHtml)
                if (-not $card -or -not $card.name) { continue }
                if ((Get-WagoAutoMatchNormalizedName -Value $card.name) -ne $normName) { continue }
                try {
                    $detailProps = Get-WagoCached -PageUri ('https://addons.wago.io/addons/' + [System.Uri]::EscapeDataString($card.slug))
                    $authorOk = [string]::IsNullOrWhiteSpace($Author)
                    if (-not $authorOk -and $detailProps -and $detailProps.metadata -and $detailProps.metadata.developers) {
                        $authorLower = $Author.ToLowerInvariant()
                        foreach ($dev in @($detailProps.metadata.developers)) {
                            if (-not $dev.name) { continue }
                            $devLower = ([string]$dev.name).ToLowerInvariant()
                            if ($devLower.Contains($authorLower) -or $authorLower.Contains($devLower)) { $authorOk = $true; break }
                        }
                    }
                    if ($authorOk) { $match = [PSCustomObject]@{ slug = $card.slug }; break }
                } catch {
                    # Could not confirm this one candidate's author - try the next, if any.
                }
            }
        }
    } catch {
        Write-ServerLog "Wago auto-match search failed for '$Name': $($_.Exception.Message)"
    }

    $Script:WagoAutoMatchCache[$cacheKey] = @{ Time = (Get-Date); Match = $match }
    return $match
}

function Get-CfEnrichmentNoKey {
    <#
      The keyless fallback chain behind GET /api/cf/enrich/{projectId} -
      the only chain there is, now that Round 16 (E22) removed the
      key-gated official-API path this used to try first: (1) a Wago
      match - the tracked record's own toc-derived wagoId first, else
      (only when there is none at all) a conservative Get-WagoAutoMatch
      probe; (2) addon-radar.com, via the catalogue-resolved slug; (3)
      catalogue-only (or nothing at all, for an id neither catalogue has
      and no Wago match). Never
      throws - every branch already degrades to the next on its own
      failure, and this function's own try/catch around the Wago path
      guards against a live network hiccup there specifically.
    #>
    param([string]$ProjectId)

    $records = Get-AddonRecords
    $rec = $null
    foreach ($r in $records) {
        if ($r.projectId -and ([string]$r.projectId -eq $ProjectId)) { $rec = $r; break }
    }

    $catalogueEntry = Get-CfCatalogueEntry -ProjectId $ProjectId

    # 1) Wago match.
    $wagoRef = $null
    if ($rec -and $rec.wagoId) {
        $wagoRef = [string]$rec.wagoId
    } elseif ($rec -and $rec.name) {
        $auto = Get-WagoAutoMatch -Name $rec.name -Author $rec.author
        if ($auto) { $wagoRef = $auto.slug }
    }
    if ($wagoRef) {
        try {
            $props = Get-WagoCached -PageUri ('https://addons.wago.io/addons/' + [System.Uri]::EscapeDataString($wagoRef))
            if ($props -and $props.addon) {
                $downloadCount = $null
                $lastUpdated = $null
                if ($props.metadata) { $downloadCount = $props.metadata.download_count; $lastUpdated = $props.metadata.last_update }
                return [PSCustomObject]@{
                    source          = 'wago-match'
                    name            = $props.addon.display_name
                    slug            = $props.addon.slug
                    summary         = $props.addon.summary
                    descriptionMarkdown = $props.description
                    logoUrl         = $props.addon.thumbnail_image
                    screenshots     = @()
                    downloadCount   = $downloadCount
                    lastUpdated     = $lastUpdated
                    gameVersions    = @()
                    wagoSlug        = $props.addon.slug
                }
            }
        } catch {
            Write-ServerLog "Wago-match lookup failed for project $ProjectId (ref '$wagoRef'): $($_.Exception.Message)"
        }
    }

    # 2) addon-radar.com, via the catalogue-resolved slug.
    if ($catalogueEntry -and $catalogueEntry.slug) {
        $detail = Get-AddonRadarDetail -Slug ([string]$catalogueEntry.slug)
        if ($detail) {
            return [PSCustomObject]@{
                source          = 'addon-radar'
                name            = $detail.name
                slug            = $detail.slug
                summary         = $detail.summary
                descriptionHtml = $detail.descriptionHtml
                logoUrl         = $detail.logoUrl
                screenshots     = $detail.screenshots
                downloadCount   = $detail.downloadCount
                lastUpdated     = $detail.lastUpdated
                gameVersions    = $detail.gameVersions
            }
        }
    }

    # 3) catalogue-only, or nothing at all.
    $name = $null
    if ($rec -and $rec.name) { $name = $rec.name } elseif ($catalogueEntry -and $catalogueEntry.name) { $name = $catalogueEntry.name }
    $downloadCount = $null
    $lastUpdated = $null
    $slug = $null
    if ($catalogueEntry) { $downloadCount = $catalogueEntry.downloadCount; $lastUpdated = $catalogueEntry.lastUpdated; $slug = $catalogueEntry.slug }
    return [PSCustomObject]@{
        source        = 'catalogue-only'
        name          = $name
        slug          = $slug
        summary       = $null
        downloadCount = $downloadCount
        lastUpdated   = $lastUpdated
        gameVersions  = @()
    }
}

function Handle-CfEnrich {
    <#
      GET /api/cf/enrich/{projectId} - keyless (the only CurseForge fetch
      path there is now, Round 16/E22 having removed the key-gated official-
      API mod/description proxy this used to try first). Walks
      Get-CfEnrichmentNoKey's fallback chain. Response shape:
      {source,name,slug,summary,descriptionHtml?,descriptionMarkdown?,
      logoUrl?,screenshots?[],downloadCount?,lastUpdated?,gameVersions?[],
      wagoSlug?}.
    #>
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $body = Get-CfEnrichmentNoKey -ProjectId $id
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Handle-CfBrowse {
    <#
      GET /api/cf/browse?q=&limit= - keyless. Search-CfCatalogue runs
      first, and Search-AddonRadar is additionally consulted only when
      that returns fewer than 5 hits, merging in anything not already
      present by id (SPEC's own documented threshold).
    #>
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $query = [string]$q['q']
    $limit = 30
    $limitRaw = Get-QueryOrDefault -QueryString $q -Name 'limit' -Default '30'
    $parsedLimit = 0
    if ([int]::TryParse($limitRaw, [ref]$parsedLimit) -and $parsedLimit -gt 0) { $limit = $parsedLimit }

    $items = New-Object 'System.Collections.Generic.List[object]'
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($e in (Search-CfCatalogue -Query $query -Limit $limit)) {
        $items.Add([PSCustomObject]@{ id = $e.id; name = $e.name; slug = $e.slug; downloadCount = $e.downloadCount; lastUpdated = $e.lastUpdated; source = 'catalogue'; logoUrl = $null })
        [void]$seenIds.Add([string]$e.id)
    }

    if ($items.Count -lt 5 -and -not [string]::IsNullOrWhiteSpace($query)) {
        foreach ($r in (Search-AddonRadar -Query $query -Limit $limit)) {
            $ridStr = [string]$r.id
            if ($seenIds.Contains($ridStr)) { continue }
            $items.Add([PSCustomObject]@{ id = $r.id; name = $r.name; slug = $r.slug; downloadCount = $r.downloadCount; lastUpdated = $r.lastUpdated; source = 'addon-radar'; logoUrl = $r.logoUrl })
            [void]$seenIds.Add($ridStr)
        }
    }

    $body = [PSCustomObject]@{
        items        = $items.ToArray()
        catalogueAge = $Script:CfCatalogueFetchedAt
        total        = $items.Count
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

# Round 17 - removed: Handle-CfCatalogueRefresh (POST
# /api/cf/catalogue/refresh) and the "Refresh the addon list from
# CurseForge" button that was its only caller (Settings > Troubleshooting).
# Save-CfCatalogueIndex itself is unchanged and still called automatically
# at startup/once-per-24h by Initialize-CfCatalogueIndex - only the manual,
# on-demand trigger is gone.

# =====================================================================
# Diagnostics (E10) - GET /api/diagnostics: a fixed battery of quick health
# checks, each returning @{ ok; detail }. Every Test-Diag* function below is
# self-contained (its own try/catch, never throws), so Handle-Diagnostics
# itself needs no try/catch around any individual check - one bad check
# degrades to a single failed row, never a 500 for the whole endpoint.
# =====================================================================

function New-DiagCheckRow {
    param([string]$Name, [hashtable]$Result)
    return [PSCustomObject]@{ name = $Name; ok = [bool]$Result.ok; detail = [string]$Result.detail }
}

function Test-DiagAddonsFolder {
    <#
      AddOns path exists AND is writable - proven by creating and deleting a
      small temp file in it, not just a Test-Path (SPEC/roadmap: "AddOns path
      exists and writable (create+delete temp file)").
    #>
    $addonsPath = Resolve-EffectiveAddonsPath
    if (-not $addonsPath) {
        return @{ ok = $false; detail = 'AddOns path could not be resolved (not running from inside a _retail_\AddonSync install and no -AddonsPath override)' }
    }
    if (-not (Test-Path -LiteralPath $addonsPath -PathType Container)) {
        return @{ ok = $false; detail = "Does not exist: $addonsPath" }
    }
    $probeName = '.addonsync-diag-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    $probePath = Join-Path -Path $addonsPath -ChildPath $probeName
    try {
        Set-Content -LiteralPath $probePath -Value 'diagnostic probe' -Encoding UTF8 -ErrorAction Stop
        Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
        return @{ ok = $true; detail = $addonsPath }
    } catch {
        return @{ ok = $false; detail = "Not writable: $($_.Exception.Message)" }
    } finally {
        if (Test-Path -LiteralPath $probePath) { try { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Test-DiagSettingsJson {
    <# settings.json parses. A missing file is fine (Get-Settings creates it with defaults on next use) - only a PRESENT-but-corrupt file fails this check. #>
    if (-not (Test-Path -LiteralPath $Script:SettingsPath)) {
        return @{ ok = $true; detail = 'not yet created (defaults will be used)' }
    }
    try {
        # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and
        # is discarded right after, never returned/serialized itself (see
        # Update-JobStatus for the pattern that actually is hazardous).
        $raw = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{ ok = $true; detail = 'empty (defaults will be used)' }
        }
        $raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
        return @{ ok = $true; detail = 'valid' }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagAddonsJson {
    <# addons.json parses, plus the record count. Get-AddonRecords itself throws uncaught on corrupt JSON (see its own comments) - exactly the failure this check needs to surface. #>
    try {
        $records = Get-AddonRecords
        $count = $records.Count
        $label = '{0} record{1}' -f $count, $(if ($count -eq 1) { '' } else { 's' })
        return @{ ok = $true; detail = $label }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagCfReachability {
    <#
      One keyless CurseForge "files" request for project 1521253
      (BonusRollConfirm - SPEC.md's designated small test project), exactly
      as roadmap item E10 calls for. Headers/user-agent mirror addon-sync.ps1's
      Invoke-CfRequest (this script never dot-sources the CLI, so the few
      lines needed are duplicated here - the same pattern already used for
      Resolve-EffectiveAddonsPath/Get-PresentAddonFolders elsewhere in this
      file). Single attempt, no 403/429 retry: a transient block IS the
      "not reachable right now" signal this check exists to surface, not
      something to paper over with the retry a real sync's Invoke-CfRequest
      performs.
    #>
    $uri = 'https://www.curseforge.com/api/v1/mods/1521253/files?pageIndex=0&pageSize=1&sort=dateCreated&sortDescending=true&removeAlphas=true'
    $headers = @{ 'Accept' = 'application/json'; 'Referer' = 'https://www.curseforge.com/' }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        if ([int]$resp.StatusCode -eq 200) {
            return @{ ok = $true; detail = 'Reachable (HTTP 200)' }
        }
        return @{ ok = $false; detail = "HTTP $([int]$resp.StatusCode)" }
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
        if ($statusCode -gt 0) {
            return @{ ok = $false; detail = "HTTP $statusCode" }
        }
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagDiskSpace {
    <# Free disk space (GB) on the drive holding the AddOns folder (falls back to -Root's drive if that can't be resolved). Flags red under 1 GB free - not enough headroom for even a small addon download/extract. #>
    $path = Resolve-EffectiveAddonsPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { $path = $Script:Root }
    try {
        $driveRoot = [System.IO.Path]::GetPathRoot($path)
        $info = New-Object System.IO.DriveInfo($driveRoot)
        $freeGb = [math]::Round($info.AvailableFreeSpace / 1GB, 1)
        return @{ ok = ($freeGb -ge 1); detail = "$freeGb GB free on $driveRoot" }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagPowerShellVersion {
    <# This whole app requires Windows PowerShell 5.1 (SPEC.md's hard constraint) - flags red if somehow running under anything older. #>
    $v = $PSVersionTable.PSVersion
    $ok = ($v.Major -gt 5) -or ($v.Major -eq 5 -and $v.Minor -ge 1)
    return @{ ok = $ok; detail = $v.ToString() }
}

function Test-DiagServerUptime {
    param([double]$UptimeSeconds)
    $detail = $null
    if ($UptimeSeconds -lt 60) {
        $detail = "$([math]::Round($UptimeSeconds, 0))s"
    } elseif ($UptimeSeconds -lt 3600) {
        $detail = "$([math]::Floor($UptimeSeconds / 60))m"
    } else {
        $hours = [math]::Floor($UptimeSeconds / 3600)
        $mins = [math]::Floor(($UptimeSeconds % 3600) / 60)
        $detail = "${hours}h ${mins}m"
    }
    return @{ ok = $true; detail = $detail }
}

function Format-DiagTimestamp {
    <#
      Renders one of this script's own ISO-8601 UTC timestamps
      ("yyyy-MM-ddTHH:mm:ssZ", the format every $Script:LastRun.timestamp/
      startedAt/finishedAt already uses) as local-time human text, matching
      the convention every OTHER Test-Diag* check's detail already follows
      within this same endpoint - Server uptime's "2h 3m", CurseForge
      reachability's "Reachable (HTTP 200)" - finished display text, never
      raw data left for the client to reformat. Confirmed against ui\app.js:
      diagRow() renders c.detail verbatim with no date parsing of its own,
      unlike the addons table's Updated column (Utils.relativeTime), so an
      un-formatted ISO string here was the one diagnostics row showing raw
      machine-readable text next to eight rows of finished prose. Falls back
      to the raw input string on any parse failure - never throws, matching
      every Test-Diag* function's own no-throw contract.
    #>
    param([string]$Iso)

    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $dt = [DateTime]::ParseExact($Iso, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return $dt.ToLocalTime().ToString('MMM d, yyyy, hh:mm tt')
    } catch {
        return $Iso
    }
}

function Test-DiagLastSync {
    <#
      Timestamp of the most recent completed sync, read from last-run.txt's
      own mtime (written by addon-sync.ps1 on every non-DryRun run, whether
      launched through this server or the desktop shortcut's -Launcher path)
      - a more universal signal than $Script:LastRun, which only ever
      reflects a job run through THIS server instance. Falls back to
      $Script:LastRun.timestamp (in-memory, or reloaded from state.json at
      startup) when last-run.txt is not there yet, then to "never".
    #>
    $lastRunPath = Join-Path -Path $Script:Root -ChildPath 'last-run.txt'
    if (Test-Path -LiteralPath $lastRunPath) {
        try {
            $mtime = (Get-Item -LiteralPath $lastRunPath).LastWriteTimeUtc
            return @{ ok = $true; detail = $mtime.ToLocalTime().ToString('MMM d, yyyy, hh:mm tt') }
        } catch {
            return @{ ok = $false; detail = $_.Exception.Message }
        }
    }
    $lastRun = Get-FlavourLastRun -Flavor $Script:CurrentFlavour
    if ($lastRun -and $lastRun.timestamp) {
        return @{ ok = $true; detail = (Format-DiagTimestamp -Iso ([string]$lastRun.timestamp)) }
    }
    return @{ ok = $true; detail = 'never' }
}

function Test-DiagClientBuild {
    <#
      E13: reports whatever $Script:ClientBuildInfo resolved at startup (from
      .build.info, or -BuildInfoPath's override) - ok:false with an
      explanatory detail when it could not be read, so a missing/unreadable
      .build.info shows up as a visible diagnostic instead of every addon
      silently reporting compat "unknown" with no obvious cause.
    #>
    if ($Script:ClientBuildInfo -and $Script:ClientBuildInfo.clientBuild) {
        return @{ ok = $true; detail = $Script:ClientBuildInfo.clientBuild }
    }
    return @{ ok = $false; detail = 'Could not read .build.info (missing, unreadable, or no "wow" row found)' }
}

function Test-DiagCfCatalogue {
    <#
      E16: the offline CurseForge catalogue index (instawow-data +
      strongbox-catalogue) that /api/cf/browse and /api/cf/enrich fall back
      to when no key is configured. ok:false when never fetched at all
      (fresh install, or every fetch attempt has failed so far) or when the
      on-disk copy is over 48h stale (double the normal 24h refresh window -
      a generous allowance before flagging red, since a single missed daily
      refresh is not itself a problem).
    #>
    if (-not $Script:CfCatalogueFetchedAt) {
        return @{ ok = $false; detail = 'No catalogue cache yet (fetched automatically on first use)' }
    }
    $ageHours = $null
    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $fetched = [DateTime]::ParseExact($Script:CfCatalogueFetchedAt, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        $ageHours = ((Get-Date).ToUniversalTime() - $fetched).TotalHours
    } catch {
        return @{ ok = $false; detail = "Cache timestamp unreadable ($Script:CfCatalogueFetchedAt)" }
    }
    $count = 0
    if ($Script:CfCatalogueIndex) { $count = $Script:CfCatalogueIndex.Count }
    $detail = "$count entries, $([math]::Round($ageHours, 1))h old ($Script:CfCatalogueSource)"
    return @{ ok = ($ageHours -lt 48); detail = $detail }
}

function Test-DiagAddonRadar {
    <#
      E16: one cheap, cached-if-possible addon-radar.com request - the same
      allowance E10 already gives CurseForge's own reachability check.
      "bigwigs" is a real, small, always-present addon-radar slug (SPEC's
      own verified facts were gathered against it) so a cache hit from an
      earlier drawer/browse view is common; a cold cache pays one live
      request, paced/retried exactly like every other Get-AddonRadarDetail
      call.
    #>
    try {
        $detail = Get-AddonRadarDetail -Slug 'bigwigs'
        if ($detail) { return @{ ok = $true; detail = 'Reachable' } }
        return @{ ok = $false; detail = 'No response or unrecognized payload shape' }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Get-QueryOrDefault {
    param($QueryString, [string]$Name, [string]$Default)

    $v = $QueryString[$Name]
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

function Open-InBrowser {
    param([string]$Url)

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgePath) {
        Start-Process -FilePath $edgePath -ArgumentList $Url
    } else {
        Start-Process $Url
    }
}

function Open-CfSideWindow {
    <#
      Round 12 (E19b): the 'cf-window' /api/open target's Edge-app fallback
      path - opens $Url in a chromeless Edge window beside this app, rather
      than a normal browser tab (Open-InBrowser above) or the native host's
      embedded CurseForge tab (which, when present, ui\app.js's
      Host.openCurseForge intercepts before this endpoint is ever reached -
      see SPEC.md's E19b). Same msedge.exe path + Test-Path/Start-Process
      fallback as Open-InBrowser and the $OpenBrowser startup block further
      down this file - there is no registry/App Paths lookup anywhere in
      this codebase (grepped addon-server.ps1, Addon Manager.vbs and
      curseforge-handler.vbs; all three hardcode this same default-install
      path) to reuse instead.
    #>
    param([string]$Url)

    # Adversarial-review fix (round 2): the first fix here only rejected
    # '"'/CR/LF, but Windows PowerShell 5.1's Start-Process -ArgumentList
    # does NOT quote each array element - it joins them with a plain SPACE
    # before CreateProcess sees them, so a literal space in $Url (e.g.
    # "https://www.curseforge.com/x --app=http://evil.example/phish") also
    # splits into extra msedge.exe argv tokens and defeats the
    # curseforge.com-only allowlist, exactly like the quote/CRLF case.
    # Blocklisting characters is fragile (whatever's missed next is the
    # next bypass), so validate structurally instead: parse $Url as an
    # absolute URI and require scheme https + host www.curseforge.com
    # (case-insensitive), then rebuild the msedge.exe argument from the
    # PARSED $parsedUri.AbsoluteUri, never from the raw client string -
    # AbsoluteUri is guaranteed free of spaces/quotes/control characters
    # (Uri encodes them), so it cannot inject additional argv tokens
    # regardless of what the caller sent.
    $parsedUri = $null
    $isValid = [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsedUri)
    if (-not $isValid -or
        $parsedUri.Scheme -ne 'https' -or
        -not $parsedUri.Host.Equals('www.curseforge.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ServerLog "Open-CfSideWindow: rejected url that failed structural validation"
        return $false
    }
    $safeUrl = $parsedUri.AbsoluteUri

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgePath) {
        Start-Process -FilePath $edgePath -ArgumentList @("--app=$safeUrl", '--window-size=1100,900')
    } else {
        Start-Process $safeUrl
    }
    return $true
}

# =====================================================================
# Route handlers
# =====================================================================

function Handle-Ping {
    param($Context, $RouteMatch)

    $uptime = ((Get-Date) - $Script:StartTime).TotalSeconds
    # E19: $Script:HostKind starts 'edge-app' and flips (stickily - see
    # Invoke-Route's static-file branch) to 'webview2' the moment a GET / or
    # GET /index.html arrives with ?host=webview2, which only
    # host\FurphyHost.cs's Furphy-tab navigation ever sends.
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; name = $Script:AppName; version = $Script:Version; uptime = [math]::Round($uptime, 1); host = $Script:HostKind }
}

function Handle-State {
    param($Context, $RouteMatch)

    $flavor = $Script:CurrentFlavour
    if (-not $flavor) { $flavor = 'retail' }
    $installedFlavours = Get-CurrentInstalledFlavours
    $updateAvailable = Get-FlavourUpdateAvailable -Flavor $flavor

    $records = Get-AddonRecords
    # E3: computed once per /api/state call and shared across every record,
    # rather than re-listing the AddOns directory per addon.
    $presentFolders = Get-PresentAddonFolders
    # E13: likewise computed once and shared - each record's own toc parse
    # still happens per addon, but resolving the AddOns path itself does not.
    $compatAddonsPath = Resolve-EffectiveAddonsPath -Flavor $flavor
    $addonsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $records) {
        # E12: updateAvailable is keyed by the numeric CurseForge project id
        # (unchanged) OR, for a Wago-sourced record (no numeric projectId at
        # all), by "wago:<slug>" - see Get-UpdateAvailableKeyForRecord.
        $upd = $null
        $key = Get-UpdateAvailableKeyForRecord -Record $r
        if ($key -and $updateAvailable.ContainsKey($key)) {
            $u = $updateAvailable[$key]
            $upd = [PSCustomObject]@{ fileId = $u.fileId; version = $u.version }
        }
        $clone = [PSCustomObject]@{}
        foreach ($p in $r.PSObject.Properties) {
            $clone | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value
        }
        $clone | Add-Member -MemberType NoteProperty -Name 'updateAvailable' -Value $upd
        # E3: requiredDeps/optionalDeps reach this response for free via the
        # generic property clone above (once the CLI starts writing them, same
        # free ride documented for E1's previousFileId/previousVersion);
        # missingDeps/missingOptionalDeps are computed live here instead,
        # since SPEC documents them as "computed live, not stored".
        $missingDeps = Get-MissingDeps -DepNames $r.requiredDeps -PresentFolders $presentFolders
        $missingOptionalDeps = Get-MissingDeps -DepNames $r.optionalDeps -PresentFolders $presentFolders
        $clone | Add-Member -MemberType NoteProperty -Name 'missingDeps' -Value $missingDeps.ToArray()
        $clone | Add-Member -MemberType NoteProperty -Name 'missingOptionalDeps' -Value $missingOptionalDeps.ToArray()
        # E13: tocInterfaces/compat computed live the same way missingDeps
        # just above is - never stored, recomputed every /api/state call.
        # FLAVORS-SPEC.md CS-F2: -Flavor/-InstalledInterface thread through so
        # a package's toc selection matches THIS flavour's own era.
        $tocIfaces = Get-PackageTocInterfaces -AddonsPath $compatAddonsPath -Folders $r.folders -Flavor $flavor -InstalledInterface $Script:ClientBuildInfo.clientInterface
        $compat = Get-AddonCompat -TocInterfaces $tocIfaces -LatestGameVersions $r.latestGameVersions -ClientInterface $Script:ClientBuildInfo.clientInterface
        $clone | Add-Member -MemberType NoteProperty -Name 'tocInterfaces' -Value $tocIfaces.ToArray()
        $clone | Add-Member -MemberType NoteProperty -Name 'compat' -Value $compat
        $addonsOut.Add($clone)
    }

    $settings = Get-Settings
    $currentJobView = Get-CurrentOrLastJobSummary -Flavor $flavor

    # FLAVORS-SPEC.md CS-F2 S5.2: installedFlavours/activeFlavour are the
    # only two fields present regardless of ?flavour= - they describe the
    # MACHINE, not one flavour's data. Built from Get-CurrentInstalledFlavours
    # (live detection) rather than cached, per S8's own "detection is live,
    # not cached" acceptance bar.
    $installedFlavoursOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $installedFlavours) {
        $installedFlavoursOut.Add([PSCustomObject]@{
                id               = $f.id
                label            = $f.label
                addonsPath       = $f.addonsPath
                clientBuild      = $f.clientBuild
                clientInterface  = $f.clientInterface
                buildInfoMissing = $f.buildInfoMissing
            })
    }

    $body = [PSCustomObject]@{
        # S5.2: additive-only fields, present on every response regardless of
        # ?flavour= - a single-flavour machine's payload differs from before
        # this change set ONLY by these three top-level fields, per the
        # feature's own "zero behavior change at n=1" bar.
        installedFlavours = $installedFlavoursOut.ToArray()
        activeFlavour     = $flavor
        flavour           = $flavor
        # Security-review fix (curseforge-handler.vbs gap): a machine-wide,
        # not-yet-flavour-attributed 'awaiting_flavour' job, if one is
        # still outstanding - see Get-PendingFlavourChoiceJob's own comment.
        # $null on every request when none is pending (the common case).
        pendingFlavourChoice = (Get-PendingFlavourChoiceJob)
        addons           = $addonsOut.ToArray()
        settings         = Get-SettingsView -Settings $settings
        lastRun          = (Get-FlavourLastRun -Flavor $flavor)
        job              = $currentJobView
        updatesCheckedAt = (Get-FlavourUpdatesCheckedAt -Flavor $flavor)
        # CS1 (UX-SPEC.md sections 2.1/4.2): the one computed freshness enum
        # (see Get-ComputedFreshness) plus the two raw fields it (and a
        # failed-check Retry flow) read from - lastCheckFailed/lastCheckError
        # persist across polls in-memory only (Apply-JobCompletionSideEffects'
        # failure branch sets them; a later success clears them), so a failed
        # check stays visible after reload instead of being silently
        # overwritten by the old "checked X ago" timestamp. FLAVORS-SPEC.md
        # CS-F2 S5.3: all scoped to THIS flavour only - see Get-ComputedFreshness.
        freshness        = (Get-ComputedFreshness -CurrentJobView $currentJobView -Flavor $flavor)
        lastCheckFailed  = [bool](Get-FlavourLastCheckFailed -Flavor $flavor)
        lastCheckError   = (Get-FlavourLastCheckError -Flavor $flavor)
        # E13: re-resolved per request now (Set-CurrentFlavourContext, called
        # from Invoke-Route before this handler runs) rather than once at
        # server startup - see that function's own doc comment.
        clientBuild      = $Script:ClientBuildInfo.clientBuild
        clientInterface  = $Script:ClientBuildInfo.clientInterface
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Handle-JobsPost {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.kind) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: missing kind' }
        return
    }

    $kind = [string]$body.kind
    $validKinds = @('sync', 'check', 'add', 'remove', 'install', 'launch', 'rollback', 'switch-source', 'add-by-slug', 'update-all-flavours')
    if (-not ($validKinds -contains $kind)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = "bad request: unknown kind '$kind'" }
        return
    }

    # FLAVORS-SPEC.md S5.1: whether THIS request named an explicit
    # ?flavour=/?flavor= - read once, here, since both the gate below and
    # the Start-Job call at the end of this function need it (Start-Job's
    # own S5.5 CurseForge install-flavour resolution must never engage when
    # the caller already made an explicit choice - see its own comment).
    $flavourGiven = [bool](Get-QueryFlavour -Context $Context)

    # E12: a NEW Wago add (no existing record, so no projectId-equivalent key
    # yet) is posted as {source:'wago', slug} instead of projectId - either
    # is accepted here.
    $hasWagoSourceSlug = [bool]($body.source -and $body.slug)
    # E18: bulk adopt (the Welcome dialog's "Adopt all") posts projectIds
    # (array of already-normalized tokens) instead of a single projectId -
    # same three-way either/or as 'remove' below.
    $hasMultiAdd = $body.projectIds -and (@($body.projectIds).Count -gt 0)

    # FLAVORS-SPEC.md CS-F2 S5.1 (narrowed by CS-F3 S5.5): POST /api/jobs is
    # addon-scoped for every kind EXCEPT update-all-flavours (see
    # $Script:FlavourScopedEndpoints' own comment for why that one kind is
    # excluded from the router-level check) - so this handler enforces the
    # identical "flavour required" 400 itself, here, on a multi-flavour
    # machine that omitted ?flavour=/?flavor=. A request naming an
    # unrecognized/not-installed flavour has already been rejected by
    # Invoke-Route's own Resolve-RequestFlavour call before this handler
    # ever ran, regardless of any of this.
    #
    # CS-F3 carves out one exception: a genuine, SINGLE-target CurseForge
    # add/install/add-by-slug (never a bulk add, never a Wago target) skips
    # this blanket 400 and falls through to Start-Job's own S5.5
    # auto/refuse/ask resolution instead - the protocol handler and the
    # embedded CurseForge site's Install button have no concept of Furphy's
    # flavours at all, so they can never send ?flavour=, and 400ing them
    # outright on a multi-flavour machine would make CurseForge installs
    # simply not work there. A bulk add (projectIds[]) and every Wago
    # add/install still 400 here exactly as before this change set - Wago
    # already names its one flavour through the search's own game_version
    # param (S6.4), and silently guessing a flavour for several addons at
    # once is not this feature's job.
    $bodyHasSingleProjectId = [bool]$body.projectId
    $isSingleCfInstallKind = (
        ($kind -eq 'add' -and $bodyHasSingleProjectId -and (-not $hasMultiAdd)) -or
        ($kind -eq 'install') -or
        ($kind -eq 'add-by-slug')
    )
    $targetsWago = $false
    if ($isSingleCfInstallKind) {
        $bodyProjectIdText = [string]$body.projectId
        $targetsWago = $hasWagoSourceSlug -or ($bodyProjectIdText -and $bodyProjectIdText.ToLowerInvariant().StartsWith('wago:'))
    }
    $skipFlavourGate = ($isSingleCfInstallKind -and (-not $targetsWago))
    if ($kind -ne 'update-all-flavours' -and (-not $skipFlavourGate)) {
        $installedForThisJob = Get-CurrentInstalledFlavours
        if ((@($installedForThisJob)).Count -gt 1 -and (-not $flavourGiven)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'flavour required' }
            return
        }
    }

    # FLAVORS-SPEC.md CS-F2 S5.4/S5.6: a bulk sync fanning out into one
    # per-flavour 'sync' job (reusing the ordinary per-flavour update-all
    # logic, looped) - what the tray's scheduled tick (S5.6, once built)
    # posts, and what CS-F4's "Update All" button (S6.3) fires. Excludes
    # PTR/XPTR/Beta unless Settings' "Show test realms" (S2.5/S3.4) is on.
    # This kind never uses ?flavour= (it targets every installed flavour at
    # once, by definition) - Resolve-RequestFlavour's own default handling
    # for a non-flavour-scoped POST /api/jobs is irrelevant here since this
    # branch returns before Start-Job's own single-flavour Params dispatch.
    if ($kind -eq 'update-all-flavours') {
        $installedForBulk = Get-CurrentInstalledFlavours
        $bulkSettings = Get-Settings
        $showTestRealms = [bool]$bulkSettings.showTestRealms
        $hiddenIds = @('ptr', 'xptr', 'beta')
        $jobsOut = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in $installedForBulk) {
            if ((-not $showTestRealms) -and ($hiddenIds -contains $f.id)) { continue }
            $r = Start-Job -Kind 'sync' -Params ([PSCustomObject]@{}) -Flavor $f.id
            if ($r.Busy) {
                $jobsOut.Add([PSCustomObject]@{ flavour = $f.id; jobId = $r.Job.id; busy = $true })
            } elseif ($r.Error) {
                $jobsOut.Add([PSCustomObject]@{ flavour = $f.id; error = $r.Error })
            } else {
                $jobsOut.Add([PSCustomObject]@{ flavour = $f.id; jobId = $r.Job.id })
            }
        }
        Send-Json -Context $Context -StatusCode 202 -Body @{ kind = 'update-all-flavours'; jobs = $jobsOut.ToArray() }
        return
    }

    # E19: the native host's CurseForge-tab install-link interception
    # (host\FurphyHost.cs HandleSlugInstall, for /wow/addons/<slug>/install/
    # <fileId> links, which carry a slug but no numeric projectId) - see
    # Start-Job for slug -> projectId resolution against the same catalogue
    # /api/cf/browse uses.
    if ($kind -eq 'add-by-slug' -and (-not $body.slug)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: slug required' }
        return
    }
    # $hasWagoSourceSlug/$hasMultiAdd were already computed above, alongside
    # the flavour-gate skip decision that also needs them.
    if ($kind -eq 'add' -and (-not $body.projectId) -and (-not $hasWagoSourceSlug) -and (-not $hasMultiAdd)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId or projectIds required' }
        return
    }
    if ($kind -eq 'switch-source') {
        if ((-not $body.projectId) -or (-not $body.toSource) -or (-not $body.toTarget)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId, toSource and toTarget required' }
            return
        }
        if (([string]$body.toSource).ToLowerInvariant() -notin @('wago', 'curseforge')) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: toSource must be wago or curseforge' }
            return
        }
    }
    if ($kind -eq 'remove') {
        # E11: bulk uninstall posts projectIds (array); the per-row kebab
        # menu still posts a single projectId - either satisfies this check.
        $hasSingle = [bool]$body.projectId
        $hasMulti = $body.projectIds -and (@($body.projectIds).Count -gt 0)
        if (-not $hasSingle -and -not $hasMulti) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId or projectIds required' }
            return
        }
    }
    if ($kind -eq 'install' -and ((-not $body.projectId) -and (-not $hasWagoSourceSlug))) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
        return
    }
    if ($kind -eq 'install' -and (-not $body.fileId)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: fileId required' }
        return
    }
    if ($kind -eq 'rollback' -and (-not $body.projectId)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
        return
    }

    $result = Start-Job -Kind $kind -Params $body -FlavourExplicit $flavourGiven
    if ($result.Busy) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $result.Job.id }
        return
    }
    if ($result.Error) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $result.Error }
        return
    }
    Send-Json -Context $Context -StatusCode 202 -Body @{ jobId = $result.Job.id }
}

function Handle-JobsGetOne {
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $job = $null
    foreach ($j in $Script:Jobs) {
        if ($j.id -eq $id) { $job = $j; break }
    }
    if (-not $job) {
        # Round 20 (adversarial bug pass, server-6): $Script:Jobs is a
        # 20-item rolling history (Add-JobToHistory evicts the oldest entry
        # with no exemption for one still running), so a long-running job's
        # own record can fall out of it while 20+ other jobs complete on
        # other flavours - even though the SAME job object is still reachable
        # via $Script:CurrentJobByFlavour the whole time. Fall back to that
        # (the same source of truth Handle-JobsGetAll/Handle-Shutdown already
        # use) before declaring 404, so the SPA's live-progress poll for a
        # genuinely still-running job never loses it.
        foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
            if ($cj -and $cj.id -eq $id) { $job = $cj; break }
        }
    }
    if (-not $job) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'job not found' }
        return
    }
    $job = Update-JobStatus -Job $job
    Send-Json -Context $Context -StatusCode 200 -Body (Get-JobStatusView -Job $job)
}

function Handle-JobsGetAll {
    param($Context, $RouteMatch)

    # FLAVORS-SPEC.md CS-F2 S5.4: this listing is shared across every
    # flavour (each job carries its own .flavour field), so every flavour's
    # currently-running job (not just the request's own resolved flavour)
    # needs a fresh poll before the listing below is built.
    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
        if ($cj) { Update-JobStatus -Job $cj | Out-Null }
    }
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($j in $Script:Jobs) {
        $out.Add((Get-JobStatusView -Job $j))
    }
    Send-Json -Context $Context -StatusCode 200 -Body $out.ToArray()
}

function Handle-AddonIgnore {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $projectId = $RouteMatch['id']
    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    $ignore = $true
    if ($body -and ($null -ne $body.ignore)) { $ignore = [bool]$body.ignore }

    $flag = '-Ignore'
    if (-not $ignore) { $flag = '-Unignore' }

    $cliArgs = @($flag, $projectId)
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    $addonsArr = @()
    if ($parsed -and $parsed.addons) { $addonsArr = @($parsed.addons) }
    Send-Json -Context $Context -StatusCode 200 -Body @{ addons = $addonsArr }
}

function Handle-AddonUnpin {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $projectId = $RouteMatch['id']
    $cliArgs = @('-Unpin', $projectId)
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    $addonsArr = @()
    if ($parsed -and $parsed.addons) { $addonsArr = @($parsed.addons) }
    Send-Json -Context $Context -StatusCode 200 -Body @{ addons = $addonsArr }
}

function Handle-AddonFiles {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $projectId = $RouteMatch['id']
    $cliArgs = @('-Files', $projectId)
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body $parsed
}

function Handle-ScanGet {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $cliArgs = @('-Scan')
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body $parsed
}

function Handle-ScanDelete {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.folder) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'folder required' }
        return
    }
    $folder = [string]$body.folder
    if ($folder -match '[\\/]' -or $folder -match '\.\.' -or $folder.Trim().Length -eq 0) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'invalid folder name' }
        return
    }

    $records = Get-AddonRecords
    foreach ($r in $records) {
        if ($r.folders) {
            foreach ($f in $r.folders) {
                if ([string]$f -eq $folder) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'folder is owned by a tracked addon' }
                    return
                }
            }
        }
    }

    $addonsPath = Resolve-EffectiveAddonsPath
    if (-not $addonsPath) {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = 'AddOns path could not be resolved' }
        return
    }

    $target = Join-Path -Path $addonsPath -ChildPath $folder
    $targetFull = [System.IO.Path]::GetFullPath($target)
    $addonsFull = [System.IO.Path]::GetFullPath($addonsPath)
    if (-not $targetFull.StartsWith($addonsFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'invalid folder path' }
        return
    }

    if (Test-Path -LiteralPath $targetFull -PathType Container) {
        try {
            Remove-Item -LiteralPath $targetFull -Recurse -Force
        } catch {
            Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
            return
        }
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
}

function Handle-Export {
    <# E4: GET /api/export - the whole tracked addon list, portable enough to hand to POST /api/import later or on another machine. #>
    param($Context, $RouteMatch)

    $records = Get-AddonRecords
    $addonsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $records) {
        $addonsOut.Add([PSCustomObject]@{
                projectId     = $r.projectId
                name          = $r.name
                pinnedFileId  = $r.pinnedFileId
                ignoreUpdates = [bool]$r.ignoreUpdates
                releaseType   = $r.releaseType
                # E12 fix (Round 9): additive identification fields. A
                # Wago-sourced record's projectId is always $null - without
                # these, Build-ImportPlan's Get-UpdateAvailableKeyForRecord
                # keying has nothing to identify it by and the addon is
                # silently dropped on import. source/slug are what the key
                # is actually built from; wagoId/curseId round-trip for
                # completeness (both are toc-derived and re-populated by the
                # CLI on the next real sync regardless).
                source        = $r.source
                slug          = $r.slug
                wagoId        = $r.wagoId
                curseId       = $r.curseId
            })
    }
    $body = [PSCustomObject]@{
        format     = 'wow-addon-manager/1'
        exportedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        addons     = $addonsOut.ToArray()
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body -FileName 'addons-export.json'
}

function Handle-Import {
    <#
      E4: POST /api/import - body is the same shape GET /api/export produces
      (format/exportedAt/addons). Starts job kind 'import' (Start-ImportJob);
      the format field is validated here so a wrong/foreign file 400s before
      any job is ever created, per SPEC.
    #>
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: empty body' }
        return
    }
    if ([string]$body.format -ne 'wow-addon-manager/1') {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: unsupported format' }
        return
    }
    if ($null -eq $body.addons) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: addons required' }
        return
    }

    $result = Start-Job -Kind 'import' -Params $body
    if ($result.Busy) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $result.Job.id }
        return
    }
    if ($result.Error) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $result.Error }
        return
    }
    Send-Json -Context $Context -StatusCode 202 -Body @{ jobId = $result.Job.id }
}

function Handle-SettingsGet {
    param($Context, $RouteMatch)

    $settings = Get-Settings
    Send-Json -Context $Context -StatusCode 200 -Body (Get-SettingsView -Settings $settings)
}

function ConvertTo-SettingsBool {
    <#
      Round 20 (adversarial bug pass): a bare [bool] cast treats ANY
      non-empty string as truthy, so a JSON STRING "false" (a client bug,
      not a real JSON boolean - the SPA itself always sends a real boolean)
      silently coerced to $true, inverting the caller's intent. This keeps
      the settings API's documented "no invalid boolean, always coerce"
      permissiveness (SPEC.md 556/630 - these fields are never rejected with
      a 400) for every other input shape, while recognizing the common
      falsy-string spellings so "false"/"0"/etc. behave the way any
      reasonable caller would expect instead of flipping the setting on.
    #>
    param($Value)
    if ($Value -is [string]) {
        $trimmed = $Value.Trim().ToLowerInvariant()
        if ($trimmed -eq 'false' -or $trimmed -eq '0' -or $trimmed -eq 'no' -or $trimmed -eq 'off' -or $trimmed -eq '') {
            return $false
        }
    }
    return [bool]$Value
}

function Handle-SettingsPut {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: empty body' }
        return
    }

    $settings = Get-Settings
    if ($null -ne $body.releaseType) {
        # Round 20 (adversarial bug pass, security-4/cli-2/server-4): a
        # non-numeric value (e.g. the string "abc") used to hit the bare
        # [int] cast below unguarded, throwing a FormatException that
        # Invoke-Route's catch-all turned into a raw 500 with the internal
        # .NET exception text as the body - a clean 400 is used instead,
        # matching the out-of-range check just below it.
        $rt = 0
        if (-not [int]::TryParse([string]$body.releaseType, [ref]$rt)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'releaseType must be a number' }
            return
        }
        if ($rt -lt 1 -or $rt -gt 3) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'releaseType must be 1-3' }
            return
        }
        $settings.releaseType = $rt
    }
    if ($null -ne $body.autoUpdateOnLaunch) {
        $settings.autoUpdateOnLaunch = ConvertTo-SettingsBool $body.autoUpdateOnLaunch
    }
    if ($null -ne $body.port) {
        # Round 20: same guarded-cast treatment as releaseType above.
        $p = 0
        if (-not [int]::TryParse([string]$body.port, [ref]$p)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'port must be a number' }
            return
        }
        $settings.port = $p
    }
    # E19: adFilter (the CurseForge-tab ad/tracker filter toggle) and
    # hostWindow (the native host's window bounds) - see Get-DefaultSettings.
    # Settings > Browsing's toggle is the normal caller for adFilter;
    # hostWindow is set almost exclusively by FurphyHost.exe writing
    # settings.json directly (HostFiles.UpdateJsonObject, bypassing this
    # endpoint entirely), but is still accepted here for completeness/so a
    # round-trip through the API never loses it.
    if ($null -ne $body.adFilter) {
        $settings.adFilter = ConvertTo-SettingsBool $body.adFilter
    }
    # Round 16 (E22): cfFocus (the CurseForge listing/search focus-view
    # trim toggle) - see Get-DefaultSettings. Settings > Advanced's
    # "Show only search results on CurseForge" toggle is the normal caller,
    # in both the native host and the plain Edge window (unlike adFilter,
    # which only does anything inside the host - cfFocus still saves here so
    # it applies next time the desktop window is used).
    if ($null -ne $body.cfFocus) {
        $settings.cfFocus = ConvertTo-SettingsBool $body.cfFocus
    }
    if ($null -ne $body.hostWindow) {
        $settings.hostWindow = $body.hostWindow
    }
    # Round 12 (E19b): hostTheme (the native host's chrome/title-bar palette,
    # relayed from the page via a postMessage the host then PUTs here the
    # same way it round-trips hostWindow) - VALIDATED unlike hostWindow's
    # total pass-through above, since this shape can also be reached by a
    # client sending arbitrary JSON straight to the API. Rejects (400) and
    # saves nothing else from this request either, rather than silently
    # dropping just the bad field - consistent with releaseType's own
    # out-of-range 400 just above.
    if ($null -ne $body.hostTheme) {
        if (-not (Test-HostTheme -Theme $body.hostTheme)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'hostTheme invalid: name must be 1-32 chars matching ^[a-z0-9-]+$, colors must be an object of <=12 "#rrggbb" values' }
            return
        }
        $settings.hostTheme = $body.hostTheme
    }
    # Round 18 (tray stage B): backgroundUpdates/runAtStartup save exactly
    # like adFilter/cfFocus above - bool coercion, no rejection possible.
    # backgroundIntervalMinutes is CLAMPED (not rejected with a 400) into
    # 30..1440, matching the "int clamped 30..1440" pattern the task brief
    # calls for and the read-path clamp in Get-Settings above - a client
    # sending 5 or 999999 silently ends up at 30 or 1440 rather than erroring,
    # consistent with there being no invalid integer here, only an
    # out-of-range one. The SPA's own interval <select> only ever offers the
    # five clamp-safe values (60/120/240/480/1440) so this path is a
    # defense-in-depth backstop, not something the normal UI can trigger.
    if ($null -ne $body.backgroundUpdates) {
        $settings.backgroundUpdates = ConvertTo-SettingsBool $body.backgroundUpdates
    }
    if ($null -ne $body.backgroundIntervalMinutes) {
        # Round 20: same guarded-cast treatment as releaseType/port above -
        # a non-numeric value now 400s instead of throwing a raw 500.
        $interval = 0
        if (-not [int]::TryParse([string]$body.backgroundIntervalMinutes, [ref]$interval)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'backgroundIntervalMinutes must be a number' }
            return
        }
        if ($interval -lt 30) { $interval = 30 }
        if ($interval -gt 1440) { $interval = 1440 }
        $settings.backgroundIntervalMinutes = $interval
    }
    if ($null -ne $body.runAtStartup) {
        $settings.runAtStartup = ConvertTo-SettingsBool $body.runAtStartup
    }
    # FLAVORS-SPEC.md CS-F2 S3.4: activeFlavour is a pure UI-continuity
    # default (S5.1's principle 5 - "never load-bearing for a data
    # operation") - validated against the CURRENTLY installed flavours so a
    # stale/bogus value can never get written, but never rejected as a 400
    # the way releaseType's out-of-range check is, since getting this one
    # wrong only affects which flavour's view loads after a reload, nothing
    # destructive. showTestRealms (S2.5) is a plain bool, same pattern as
    # adFilter/cfFocus. schemaVersion is intentionally NOT accepted here -
    # it is migration-owned (Invoke-FlavourMigration writes it directly) and
    # must never be client-settable.
    if ($null -ne $body.activeFlavour) {
        $candidateFlavour = ([string]$body.activeFlavour).Trim().ToLowerInvariant()
        if ($candidateFlavour.Length -gt 0) {
            $installedForActiveFlavour = Get-CurrentInstalledFlavours
            $isKnownFlavour = $false
            foreach ($f in $installedForActiveFlavour) {
                if ($f.id -eq $candidateFlavour) { $isKnownFlavour = $true; break }
            }
            if ($isKnownFlavour) {
                $settings.activeFlavour = $candidateFlavour
            }
        }
    }
    if ($null -ne $body.showTestRealms) {
        $settings.showTestRealms = ConvertTo-SettingsBool $body.showTestRealms
    }

    try {
        Save-Settings -Settings $settings
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body (Get-SettingsView -Settings $settings)
}

# =====================================================================
# Tray + start-with-Windows (Round 18, tray stage B)
#
# Stage A (already shipped, host\FurphyHost.cs) is the actual --tray
# process: a NotifyIcon-only run mode guarded by the "FurphyAddonManager.Tray"
# Mutex, exited by setting the "FurphyAddonManager.TrayStop" EventWaitHandle
# or by backgroundUpdates going false (checked every <=60s), writing
# tray-state.json next to settings.json on every cycle. This section is the
# SERVER's half of stage B: start/stop that process, report its state, and
# register/unregister the HKCU Run value - the SPA (ui\app.js) never touches
# the registry or spawns FurphyHost.exe directly, only these endpoints do.
# =====================================================================

function Get-TrayExePath {
    <# host\bin\FurphyHost.exe under the app root - built by host\build-host.ps1. #>
    return Join-Path -Path (Join-Path -Path $Script:Root -ChildPath 'host\bin') -ChildPath 'FurphyHost.exe'
}

function Get-TrayStatePath {
    <# tray-state.json sits next to settings.json - host\FurphyHost.cs's
       TrayForm writes it there (Path.Combine(logDir, "tray-state.json") where
       logDir is settings.json's own directory), so this just mirrors that. #>
    return Join-Path -Path $Script:Root -ChildPath 'tray-state.json'
}

function Get-TrayRunValue {
    <#
      The exact HKCU Run value string this app's tray contract uses:
      "<quoted exe path>" --tray (quoted path, one space, --tray). Must stay
      byte-identical to host\FurphyHost.cs's own
      StartupRegistry.BuildRunValue, since either side may write it and both
      sides need to recognize what the other wrote.
    #>
    return '"' + (Get-TrayExePath) + '" --tray'
}

function Read-TrayState {
    <# Parsed tray-state.json, or $null if missing/empty/unreadable - never throws. #>
    $path = Get-TrayStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Test-TrayProcessAlive {
    <#
      True only if $ProcId is a LIVE process that is actually a --tray
      instance of FurphyHost - guards against a stale tray-state.json (left
      behind by a crash or a `taskkill`) reporting "running" just because
      some unrelated process has since reused the same pid.

      A ProcessName match alone is NOT enough here: the tray and the normal
      foreground app window are the exact same executable
      (host\bin\FurphyHost.exe), so a crashed/killed tray's pid can be
      reused by an ordinary (non-tray) launch of that same exe and still
      pass a name-only check. Cross-checking the live process's own command
      line for the "--tray" argument (the exact way Handle-TrayStart itself
      launches it - see Start-Process -ArgumentList '--tray' above) is what
      actually distinguishes the two.
    #>
    param([int]$ProcId)

    if ($ProcId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcId -ErrorAction Stop
        if ($proc.ProcessName -ne 'FurphyHost') { return $false }
    } catch {
        return $false
    }
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + $ProcId) -ErrorAction Stop
        if ($null -eq $cim -or [string]::IsNullOrEmpty($cim.CommandLine)) { return $false }
        return ($cim.CommandLine.TrimEnd() -like '*--tray')
    } catch {
        # Get-CimInstance failing (WMI hiccup, access denied, etc.) should
        # not be treated as "definitely not a tray process" OR "definitely
        # is one" - fall back to the name-only signal rather than blocking
        # every tray status check on a transient WMI error.
        return $true
    }
}

function Test-StartupRegistered {
    <# True only if the HKCU Run value exists AND matches Get-TrayRunValue
       exactly - a value some other tool wrote under the same name, or a
       stale one pointing at a moved exe, correctly reads as "not registered"
       by Furphy's own contract. #>
    try {
        $prop = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        if ($null -eq $prop) { return $false }
        return ([string]$prop.FurphyAddonManager -ceq (Get-TrayRunValue))
    } catch {
        return $false
    }
}

function Get-TrayStatusView {
    <# GET /api/tray/status body. `running` is true only if tray-state.json
       says running AND that pid is alive AND is actually FurphyHost.exe -
       see Test-TrayProcessAlive. #>
    $state = Read-TrayState
    $running = $false
    if ($null -ne $state -and $null -ne $state.running -and [bool]$state.running -and $null -ne $state.pid) {
        $running = Test-TrayProcessAlive -ProcId ([int]$state.pid)
    }
    return @{
        running           = $running
        state             = $state
        startupRegistered = (Test-StartupRegistered)
    }
}

function Handle-TrayStatus {
    <# GET /api/tray/status #>
    param($Context, $RouteMatch)

    try {
        Send-Json -Context $Context -StatusCode 200 -Body (Get-TrayStatusView)
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-TrayStart {
    <#
      POST /api/tray/start - Start-Process host\bin\FurphyHost.exe --tray
      (a GUI exe; no window-hiding flag needed). 409 if a live tray already
      holds the job; 501 if the exe was never built.
    #>
    param($Context, $RouteMatch)

    try {
        $status = Get-TrayStatusView
        if ($status.running) {
            Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'tray already running'; state = $status.state }
            return
        }
        $exePath = Get-TrayExePath
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
            Send-Json -Context $Context -StatusCode 501 -Body @{ error = 'FurphyHost.exe not found - the native host was not built' }
            return
        }
        $hostBinDir = Split-Path -Path $exePath -Parent
        Start-Process -FilePath $exePath -ArgumentList '--tray' -WorkingDirectory $hostBinDir | Out-Null
        Send-Json -Context $Context -StatusCode 202 -Body @{ ok = $true }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-TrayStop {
    <#
      POST /api/tray/stop - signals the "FurphyAddonManager.TrayStop"
      EventWaitHandle a live --tray process is waiting on. OpenExisting
      throws (caught, not a 500) when no tray currently holds that name -
      that is the normal "nothing to stop" case, not a server error, so it
      still returns 200 with ok:false per the stage-B contract. Reset() is
      deliberately not called: the contract has the tray exit on this
      signal, not loop back around waiting for another one.
    #>
    param($Context, $RouteMatch)

    $ev = $null
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting('FurphyAddonManager.TrayStop')
        $ev.Set() | Out-Null
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $false; reason = 'not running' }
    } finally {
        if ($null -ne $ev) { try { $ev.Close() } catch { } }
    }
}

function Handle-StartupRegister {
    <#
      POST /api/startup/register - writes HKCU Run "FurphyAddonManager" =
      Get-TrayRunValue and sets runAtStartup=true. Deliberately does NOT
      touch backgroundUpdates here - the "turning Start with Windows on also
      turns background updates on" rule (task brief) is a single-PUT,
      single-toast SPA-side decision (Actions.setRunAtStartup, ui\app.js),
      not something this endpoint imposes on every caller.
    #>
    param($Context, $RouteMatch)

    try {
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path -LiteralPath $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $keyPath -Name 'FurphyAddonManager' -Value (Get-TrayRunValue) -Type String

        $settings = Get-Settings
        $settings.runAtStartup = $true
        Save-Settings -Settings $settings

        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; settings = (Get-SettingsView -Settings $settings) }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-StartupUnregister {
    <# POST /api/startup/unregister - removes the Run value (if present) and sets runAtStartup=false. #>
    param($Context, $RouteMatch)

    try {
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Test-Path -LiteralPath $keyPath) {
            $existing = Get-ItemProperty -LiteralPath $keyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Remove-ItemProperty -LiteralPath $keyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
            }
        }

        $settings = Get-Settings
        $settings.runAtStartup = $false
        Save-Settings -Settings $settings

        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; settings = (Get-SettingsView -Settings $settings) }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-StartupStatus {
    <# GET /api/startup/status #>
    param($Context, $RouteMatch)

    try {
        Send-Json -Context $Context -StatusCode 200 -Body @{ registered = (Test-StartupRegistered) }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

# =====================================================================
# curseforge:// protocol handler status (E19; script itself is E17's)
# =====================================================================

function Handle-ProtocolStatus {
    <# GET /api/protocol/status -> register-protocol.ps1 -Status -Json, unchanged. #>
    param($Context, $RouteMatch)

    try {
        $status = Invoke-ProtocolScript -Switch 'Status'
        Send-Json -Context $Context -StatusCode 200 -Body $status
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-ProtocolRegister {
    <# POST /api/protocol/register -> register-protocol.ps1 -Register -Json, then its resulting status. #>
    param($Context, $RouteMatch)

    try {
        $status = Invoke-ProtocolScript -Switch 'Register'
        Send-Json -Context $Context -StatusCode 200 -Body $status
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-ProtocolUnregister {
    <# POST /api/protocol/unregister -> register-protocol.ps1 -Unregister -Json, then its resulting status. #>
    param($Context, $RouteMatch)

    try {
        $status = Invoke-ProtocolScript -Switch 'Unregister'
        Send-Json -Context $Context -StatusCode 200 -Body $status
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-Diagnostics {
    <#
      E10: GET /api/diagnostics - runs the fixed battery of Test-Diag* checks
      defined above and returns {checks:[{name,ok,detail}]}. Every check
      function is self-contained and never throws, so nothing here needs (or
      gets) a try/catch of its own.
    #>
    param($Context, $RouteMatch)

    $checks = New-Object 'System.Collections.Generic.List[object]'
    $checks.Add((New-DiagCheckRow -Name 'AddOns folder' -Result (Test-DiagAddonsFolder)))
    $checks.Add((New-DiagCheckRow -Name 'settings.json' -Result (Test-DiagSettingsJson)))
    $checks.Add((New-DiagCheckRow -Name 'addons.json' -Result (Test-DiagAddonsJson)))
    $checks.Add((New-DiagCheckRow -Name 'CurseForge reachability' -Result (Test-DiagCfReachability)))
    $checks.Add((New-DiagCheckRow -Name 'Disk space' -Result (Test-DiagDiskSpace)))
    $checks.Add((New-DiagCheckRow -Name 'PowerShell version' -Result (Test-DiagPowerShellVersion)))
    $checks.Add((New-DiagCheckRow -Name 'Server uptime' -Result (Test-DiagServerUptime -UptimeSeconds ((Get-Date) - $Script:StartTime).TotalSeconds)))
    $checks.Add((New-DiagCheckRow -Name 'Last sync' -Result (Test-DiagLastSync)))
    # E13: the client build $Script:ClientBuildInfo already resolved once at
    # startup (roadmap: "/api/diagnostics includes the client build").
    $checks.Add((New-DiagCheckRow -Name 'WoW client build' -Result (Test-DiagClientBuild)))
    # E16: the two keyless-enrichment checks its own roadmap item calls for.
    $checks.Add((New-DiagCheckRow -Name 'CurseForge catalogue cache' -Result (Test-DiagCfCatalogue)))
    $checks.Add((New-DiagCheckRow -Name 'addon-radar reachability' -Result (Test-DiagAddonRadar)))

    Send-Json -Context $Context -StatusCode 200 -Body @{ checks = $checks.ToArray() }
}

function Handle-Open {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.what) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'what required' }
        return
    }

    $what = [string]$body.what
    try {
        switch ($what) {
            'log' {
                # Start-Process joins -ArgumentList elements with spaces and does NOT
                # quote them (see New-CliProcessArgs), so paths with spaces/parens
                # (e.g. the production "C:\Program Files (x86)\...\AddonSync" root)
                # must be quoted here or notepad receives a broken multi-arg command line.
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Script:SyncLogPath + '"')
            }
            'serverlog' {
                # Round 5: SPEC.md's Maintenance list (section 3) names three
                # distinct actions - "Open sync log", "Open last run report",
                # "Open server log" - but the documented /api/open `what` enum
                # only ever had one log target ('log', opening sync.log), so
                # "Open server log" had no server-side target to call at all.
                # Same quoting requirement as 'log' above (spaces/parens in ROOT).
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Script:ServerLogPath + '"')
            }
            'folder' {
                $addonsPath = Resolve-EffectiveAddonsPath
                if ($addonsPath -and (Test-Path -LiteralPath $addonsPath)) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $addonsPath + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'AddOns folder not found' }
                    return
                }
            }
            'addons' {
                if (Test-Path -LiteralPath $Script:AddonsJsonPath) {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Script:AddonsJsonPath + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'addons.json not found' }
                    return
                }
            }
            'curseforge' {
                $url = $null
                # Round 5: slug/projectId are POST-body-supplied strings, and
                # Open-InBrowser hands the finished URL to Start-Process
                # -ArgumentList as ONE unquoted string - a slug containing a
                # literal quote+space could break out of that single argument
                # and inject extra msedge.exe command-line switches, not just
                # "break URL parsing". EscapeDataString percent-encodes
                # quotes/spaces/slashes/etc., closing that off for what
                # is meant to be a single opaque path segment; well-formed
                # slugs/ids (lowercase-alnum-hyphen / digits) round-trip
                # unchanged.
                if ($body.slug) {
                    $url = 'https://www.curseforge.com/wow/addons/' + [System.Uri]::EscapeDataString([string]$body.slug)
                } elseif ($body.projectId) {
                    $url = 'https://www.curseforge.com/projects/' + [System.Uri]::EscapeDataString([string]$body.projectId)
                }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'slug or projectId required' }
                    return
                }
                Open-InBrowser -Url $url
            }
            'lastrun' {
                $lastRunPath = Join-Path -Path $Script:Root -ChildPath 'last-run.txt'
                if (Test-Path -LiteralPath $lastRunPath) {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $lastRunPath + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'last-run.txt not found' }
                    return
                }
            }
            'backups' {
                # E7: Settings > Maintenance > "Open backups folder". The folder is
                # entirely owned by this app (populated by the rollback expansion, if
                # present) rather than something external whose absence is an error
                # condition, so - unlike 'folder'/'addons'/'lastrun' above - a missing
                # backups\ is created on the spot instead of failing the request.
                # FLAVORS-SPEC.md CS-F2: backups\ moved under
                # flavours\<flavour>\ (S3.1/S3.5) - $Script:BackupsPath is
                # already scoped to the request's own resolved flavour by
                # Set-CurrentFlavourContext.
                $backupsPath = $Script:BackupsPath
                if (-not (Test-Path -LiteralPath $backupsPath)) {
                    try {
                        New-Item -ItemType Directory -Path $backupsPath -Force | Out-Null
                    } catch {
                        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not create backups folder: $($_.Exception.Message)" }
                        return
                    }
                }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $backupsPath + '"')
            }
            'logs' {
                # CS4 (UX-SPEC.md 6.2): Settings > Advanced > Troubleshooting's
                # single "Open logs folder" button, replacing the four
                # separate "Open sync log / Open last run report / Open
                # server log / Open backups folder" buttons. Rather than pick
                # one of those four files, this opens the app's own root
                # folder in Explorer - sync.log, server.log, last-run.txt and
                # backups\ all already live there side by side. Allow-listed
                # to exactly $Script:Root (no user-suppliable path here at
                # all, unlike 'url'/'curseforge' below). Created first if
                # somehow missing - mirrors 'backups' above, the app owns
                # this directory outright.
                if (-not (Test-Path -LiteralPath $Script:Root)) {
                    try {
                        New-Item -ItemType Directory -Path $Script:Root -Force | Out-Null
                    } catch {
                        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not create app folder: $($_.Exception.Message)" }
                        return
                    }
                }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Script:Root + '"')
            }
            'url' {
                # E3: drawer's "Search CurseForge" button for a missing dependency,
                # used only when no API key is configured (a keyed session switches
                # to Browse client-side instead). Restricted to the two addon
                # marketplaces this app ever links to, so this endpoint can never be
                # used to open an arbitrary URL in the user's default browser.
                #
                # Round 20 (adversarial bug pass, server-3): a plain
                # StartsWith prefix check on the raw string is not enough -
                # Open-InBrowser hands the whole string to Start-Process
                # -ArgumentList as ONE unquoted argument, and Windows
                # PowerShell 5.1 does not quote/escape it, so a URL like
                # "https://www.curseforge.com/x --app=http://evil/phish"
                # passes the StartsWith check yet still smuggles an extra
                # msedge.exe command-line switch past the allowlist. Validate
                # structurally instead (same pattern Open-CfSideWindow
                # already uses): parse as an absolute URI and require an
                # exact scheme+host match, then pass only the reparsed
                # AbsoluteUri onward - it is guaranteed free of spaces/quotes/
                # control characters, so it cannot inject extra argv tokens
                # regardless of what the caller sent.
                $url = $null
                if ($body.url) { $url = [string]$body.url }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
                    return
                }
                $parsedOpenUrl = $null
                $isValidOpenUrl = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsedOpenUrl)
                $allowedOpenHosts = @('www.curseforge.com', 'addons.wago.io')
                $allowed = $false
                if ($isValidOpenUrl -and $parsedOpenUrl.Scheme -eq 'https') {
                    foreach ($allowedHost in $allowedOpenHosts) {
                        if ($parsedOpenUrl.Host.Equals($allowedHost, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $allowed = $true
                            break
                        }
                    }
                }
                if (-not $allowed) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url must start with https://www.curseforge.com/ or https://addons.wago.io/' }
                    return
                }
                Open-InBrowser -Url $parsedOpenUrl.AbsoluteUri
            }
            'cf-window' {
                # Round 12 (E19b): the UI has posted this 'what' since round
                # 9 (Browse's "Search on CurseForge.com" box,
                # Actions.searchCurseForgeWebsite) but this server had no
                # case for it at all until now - every call landed on the
                # 'default: unknown what' branch below and toasted "Couldn't
                # open that: unknown what: cf-window". This is the
                # Edge-app-fallback path only: when running inside the
                # native host, ui\app.js's Host.openCurseForge intercepts
                # before this endpoint is ever called and routes into the
                # host's own embedded CurseForge tab instead (see the
                # 'open-curseforge' postMessage in SPEC.md's E19b section).
                # Narrower allowlist than 'url' above: curseforge.com ONLY,
                # not also wago.io - opening a side window for Wago never
                # made sense (Wago has no in-app tab to feed either).
                $url = $null
                if ($body.url) { $url = [string]$body.url }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
                    return
                }
                if (-not $url.StartsWith('https://www.curseforge.com/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url must start with https://www.curseforge.com/' }
                    return
                }
                if (-not (Open-CfSideWindow -Url $url)) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url contains invalid characters' }
                    return
                }
            }
            default {
                Send-Json -Context $Context -StatusCode 400 -Body @{ error = "unknown what: $what" }
                return
            }
        }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
}

function Handle-Shutdown {
    param($Context, $RouteMatch)

    # FLAVORS-SPEC.md CS-F2 S5.4: refuse shutdown while ANY flavour has a job
    # running, not just the request's own resolved flavour - a background
    # Classic Era sync must still block a shutdown triggered from a Retail
    # browser tab.
    $anyRunning = $false
    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
        if ($cj) {
            $refreshed = Update-JobStatus -Job $cj
            if ($refreshed -and $refreshed.state -eq 'running') { $anyRunning = $true }
        }
    }
    if ($anyRunning) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy: a job is running' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
    $Script:ShuttingDown = $true
}

# =====================================================================
# Route table and dispatcher
# =====================================================================

$Script:Routes = @(
    @{ Method = 'GET'; Pattern = '^/api/ping$'; Handler = 'Handle-Ping' }
    @{ Method = 'GET'; Pattern = '^/api/state$'; Handler = 'Handle-State' }
    @{ Method = 'POST'; Pattern = '^/api/jobs$'; Handler = 'Handle-JobsPost' }
    @{ Method = 'GET'; Pattern = '^/api/jobs/(?<id>[^/]+)$'; Handler = 'Handle-JobsGetOne' }
    @{ Method = 'GET'; Pattern = '^/api/jobs$'; Handler = 'Handle-JobsGetAll' }
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/ignore$'; Handler = 'Handle-AddonIgnore' }
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/unpin$'; Handler = 'Handle-AddonUnpin' }
    @{ Method = 'GET'; Pattern = '^/api/addons/(?<id>[^/]+)/files$'; Handler = 'Handle-AddonFiles' }
    @{ Method = 'GET'; Pattern = '^/api/scan$'; Handler = 'Handle-ScanGet' }
    @{ Method = 'POST'; Pattern = '^/api/scan/delete$'; Handler = 'Handle-ScanDelete' }
    @{ Method = 'GET'; Pattern = '^/api/export$'; Handler = 'Handle-Export' }
    @{ Method = 'POST'; Pattern = '^/api/import$'; Handler = 'Handle-Import' }
    @{ Method = 'GET'; Pattern = '^/api/settings$'; Handler = 'Handle-SettingsGet' }
    @{ Method = 'PUT'; Pattern = '^/api/settings$'; Handler = 'Handle-SettingsPut' }
    # E19 (script itself is E17's, unchanged)
    @{ Method = 'GET'; Pattern = '^/api/protocol/status$'; Handler = 'Handle-ProtocolStatus' }
    @{ Method = 'POST'; Pattern = '^/api/protocol/register$'; Handler = 'Handle-ProtocolRegister' }
    @{ Method = 'POST'; Pattern = '^/api/protocol/unregister$'; Handler = 'Handle-ProtocolUnregister' }
    # Round 18 (tray stage B)
    @{ Method = 'GET'; Pattern = '^/api/tray/status$'; Handler = 'Handle-TrayStatus' }
    @{ Method = 'POST'; Pattern = '^/api/tray/start$'; Handler = 'Handle-TrayStart' }
    @{ Method = 'POST'; Pattern = '^/api/tray/stop$'; Handler = 'Handle-TrayStop' }
    @{ Method = 'POST'; Pattern = '^/api/startup/register$'; Handler = 'Handle-StartupRegister' }
    @{ Method = 'POST'; Pattern = '^/api/startup/unregister$'; Handler = 'Handle-StartupUnregister' }
    @{ Method = 'GET'; Pattern = '^/api/startup/status$'; Handler = 'Handle-StartupStatus' }
    @{ Method = 'GET'; Pattern = '^/api/diagnostics$'; Handler = 'Handle-Diagnostics' }
    # Round 16 (E22): the only CurseForge routes left, both keyless - every
    # key-gated /api/cf/* route (search/categories/mods/description/files/
    # changelog/resolve) was removed with the key feature itself. Round 17
    # removed the third, POST /api/cf/catalogue/refresh, with the manual
    # "Refresh the addon list from CurseForge" button that was its only
    # caller - the catalogue still refreshes itself automatically.
    @{ Method = 'GET'; Pattern = '^/api/cf/browse$'; Handler = 'Handle-CfBrowse' }
    @{ Method = 'GET'; Pattern = '^/api/cf/enrich/(?<id>[^/]+)$'; Handler = 'Handle-CfEnrich' }
    @{ Method = 'GET'; Pattern = '^/api/wago/search$'; Handler = 'Handle-WagoSearch' }
    @{ Method = 'GET'; Pattern = '^/api/wago/categories$'; Handler = 'Handle-WagoCategories' }
    @{ Method = 'GET'; Pattern = '^/api/wago/resolve$'; Handler = 'Handle-WagoResolve' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)/releases$'; Handler = 'Handle-WagoAddonReleases' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)/gallery$'; Handler = 'Handle-WagoAddonGallery' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)$'; Handler = 'Handle-WagoAddonDetails' }
    @{ Method = 'POST'; Pattern = '^/api/open$'; Handler = 'Handle-Open' }
    @{ Method = 'POST'; Pattern = '^/api/shutdown$'; Handler = 'Handle-Shutdown' }
)

function Test-SameOriginRequest {
    <#
      Round 20 (adversarial bug pass, security-2): CSRF guard for every
      state-changing (non-GET/HEAD) request. Modern browsers send an
      Origin header on such requests even when same-origin (falls back to
      Referer if Origin is somehow absent, e.g. an older client) - this
      requires it to resolve to this server's own http://localhost:<port>
      or http://127.0.0.1:<port> origin, so a page loaded from any other
      site cannot drive a state-changing endpoint (including a bare
      auto-submitting HTML form, which sends no body at all and so never
      goes through Read-Body's Content-Type check). The SPA's own
      same-origin fetch() calls always carry a matching Origin header, so
      this is a no-op for every legitimate caller.
    #>
    param($Context)

    $request = $Context.Request
    $candidate = $request.Headers['Origin']
    if ([string]::IsNullOrEmpty($candidate)) { $candidate = $request.Headers['Referer'] }
    if ([string]::IsNullOrEmpty($candidate)) { return $false }

    $parsedOrigin = $null
    if (-not [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$parsedOrigin)) { return $false }
    if ($parsedOrigin.Scheme -ne 'http') { return $false }
    if ($parsedOrigin.Port -ne $Script:Port) { return $false }
    $originHost = $parsedOrigin.Host.ToLowerInvariant()
    return ($originHost -eq 'localhost' -or $originHost -eq '127.0.0.1')
}

function Invoke-Route {
    <# Dispatches one request; never throws (every path returns a JSON response and always closes it). #>
    param($Context)

    $request = $Context.Request
    $method = $request.HttpMethod.ToUpperInvariant()
    $path = $request.Url.AbsolutePath

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $Script:LastResponseStatus = $null

    try {
        $matchedHandler = $null
        $routeMatch = @{}
        foreach ($route in $Script:Routes) {
            if ($route.Method -ne $method) { continue }
            if ($path -match $route.Pattern) {
                $matchedHandler = $route.Handler
                foreach ($key in $Matches.Keys) {
                    if ($key -ne '0') { $routeMatch[$key] = $Matches[$key] }
                }
                break
            }
        }

        if ($matchedHandler) {
            # Round 20 (adversarial bug pass, security-2): every matched
            # route past this point can change state (every GET route is
            # read-only) - gate non-GET/HEAD methods on Test-SameOriginRequest
            # before the handler ever runs, so no CSRF/foreign-origin request
            # reaches a state-changing endpoint regardless of what it sends.
            if ($method -ne 'GET' -and $method -ne 'HEAD' -and -not (Test-SameOriginRequest -Context $Context)) {
                Send-Json -Context $Context -StatusCode 403 -Body @{ error = 'forbidden: origin not allowed' }
            } else {
            # FLAVORS-SPEC.md CS-F2 S5.1: resolve this ONE request's flavour
            # before the handler ever runs, and stash it script-scope for the
            # handler to read (see that section's own header comment for why
            # this is safe on a single-threaded request loop). A resolution
            # failure (missing ?flavour= on a flavour-scoped endpoint while
            # >1 flavour is installed, or an unrecognized/not-installed
            # value) 400s here and never reaches the handler at all.
            $flavourResult = Resolve-RequestFlavour -Context $Context -Method $method -Path $path
            if (-not $flavourResult.Ok) {
                Send-Json -Context $Context -StatusCode $flavourResult.StatusCode -Body @{ error = $flavourResult.Error }
            } else {
                Set-CurrentFlavourContext -Flavor $flavourResult.Flavor
                & $matchedHandler $Context $routeMatch
            }
            }
        } elseif ($method -eq 'GET' -and (-not $path.StartsWith('/api/'))) {
            # E19: the native host (host\FurphyHost.cs) navigates its Furphy
            # tab to "http://localhost:<port>/?host=webview2" on first load;
            # the Edge --app window (Addon Manager.vbs's fallback) never adds
            # that query param. Sticky by design - once set, $Script:HostKind
            # stays 'webview2' for the life of the process (a later plain GET
            # / with no query, e.g. a manual reload, must not revert it) -
            # /api/ping (Handle-Ping) reports whichever value this settled on.
            if (($path -eq '/' -or $path -eq '/index.html') -and $request.QueryString['host'] -eq 'webview2') {
                $Script:HostKind = 'webview2'
            }
            $filePath = Get-StaticFilePath -UrlPath $path
            if (-not $filePath) {
                Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
            } else {
                Send-File -Context $Context -Path $filePath
            }
        } else {
            Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        }
    } catch {
        try {
            Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        } catch {
            $Script:LastResponseStatus = 500
        }
        Write-ServerLog "ERROR $method $path : $($_.Exception.Message)"
    }

    $sw.Stop()
    $statusForLog = $Script:LastResponseStatus
    if ($null -eq $statusForLog) { $statusForLog = 0 }
    Write-ServerLog "$method $path $statusForLog $($sw.ElapsedMilliseconds)ms"
}

# =====================================================================
# Dot-source guard (TESTING.md hook #1)
#
# Everything above this point (functions + static script-scope tables) is
# safe to define unconditionally - none of it has a side effect. Everything
# below is the real "run the server" body: it touches disk, binds an
# HttpListener socket, and blocks in the request loop. A normal invocation
# (`.\addon-server.ps1 ...` / `powershell.exe -File addon-server.ps1 ...`)
# must run it exactly as before - this guard only short-circuits when the
# script is DOT-SOURCED (". .\addon-server.ps1" or ". $path"), which is how
# tests\unit\*.Tests.ps1 loads these functions into Pester's scope without
# starting a real listener. $MyInvocation.InvocationName is the literal
# string "." when dot-sourced; the $MyInvocation.Line check is a fallback
# for hosts that report InvocationName differently.
# =====================================================================

$script:FurphyDotSourced = ($MyInvocation.InvocationName -eq '.') -or ($MyInvocation.Line -match '^\s*\.\s')
if ($script:FurphyDotSourced) {
    return
}

# =====================================================================
# Startup
# =====================================================================

if (-not $Root) {
    $Root = $PSScriptRoot
    if (-not $Root) { $Root = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
}

$Script:Root = $Root
$Script:UiDir = Join-Path -Path $Script:Root -ChildPath 'ui'
$Script:JobsDir = Join-Path -Path $Script:Root -ChildPath 'jobs'
$Script:SettingsPath = Join-Path -Path $Script:Root -ChildPath 'settings.json'
$Script:StatePath = Join-Path -Path $Script:Root -ChildPath 'state.json'
$Script:AddonsJsonPath = Join-Path -Path $Script:Root -ChildPath 'addons.json'
$Script:ServerLogPath = Join-Path -Path $Script:Root -ChildPath 'server.log'

# FLAVORS-SPEC.md CS-F2 S5.1: startup self-check - every entry in
# $Script:FlavourScopedEndpoints (defined above, alongside $Script:Routes)
# must match a REAL registered route, so a typo'd Method/Pattern here (or a
# route renamed/removed without updating this list) fails loudly at startup
# instead of silently never 400ing a flavour-scoped call. Logged (now that
# $Script:ServerLogPath is finally set), not thrown - a startup log line a
# developer will actually see beats a hard crash for what is fundamentally a
# dev-time consistency check, not a user-facing failure mode.
foreach ($fse in $Script:FlavourScopedEndpoints) {
    $matched = $false
    foreach ($route in $Script:Routes) {
        if ($route.Method -eq $fse.Method -and $route.Pattern -eq $fse.Pattern) { $matched = $true; break }
    }
    if (-not $matched) {
        Write-ServerLog "STARTUP SELF-CHECK FAILED: FlavourScopedEndpoints entry '$($fse.Method) $($fse.Pattern)' matches no registered route in `$Script:Routes"
    }
}

$Script:SyncLogPath = Join-Path -Path $Script:Root -ChildPath 'sync.log'
$Script:CliPath = Join-Path -Path $Script:Root -ChildPath 'addon-sync.ps1'
# E19 (script itself is E17's, unchanged) - Invoke-ProtocolScript's target.
$Script:RegisterProtocolPath = Join-Path -Path $Script:Root -ChildPath 'register-protocol.ps1'
# E16: on-disk caches for the keyless CurseForge enrichment sources - the
# catalogue index (refreshed at most once/24h) and per-slug addon-radar.com
# detail pages (cached 24h each). Both directories are created lazily by
# their own writers (Save-CfCatalogueIndex / Get-AddonRadarDetail), the same
# "app owns this folder, create on first use" pattern already used for
# backups\ (E7's Handle-Open 'backups' case).
$Script:CacheDir = Join-Path -Path $Script:Root -ChildPath 'cache'
$Script:CfCatalogueCachePath = Join-Path -Path $Script:CacheDir -ChildPath 'cf-catalogue.json'
$Script:AddonRadarCacheDir = Join-Path -Path $Script:CacheDir -ChildPath 'addon-radar'
$Script:AddonsPathOverride = $AddonsPath
$Script:IdleMinutes = $IdleMinutes
$Script:BuildInfoPathOverride = $BuildInfoPath
# FLAVORS-SPEC.md CS-F2: overrides Get-InstalledFlavours'/Resolve-
# EffectiveAddonsPath's own WoW-root detection (S8's fixture path), the same
# way addon-sync.ps1's own -WowRoot does.
$Script:WowRootOverride = $WowRoot
$Script:AppName = 'Furphy Addon Manager'
# E18: the shipped version lives in one place - ROOT\VERSION (a bare string,
# e.g. "1.0.0") - so package.ps1's zip name and this server's own /api/ping
# report can never drift apart. Falls back to the last-known default when the
# file is missing (a dev checkout that predates E18) or unreadable.
$Script:Version = '1.8.0'
$Script:VersionPath = Join-Path -Path $Script:Root -ChildPath 'VERSION'
if (Test-Path -LiteralPath $Script:VersionPath) {
    try {
        $verText = [IO.File]::ReadAllText($Script:VersionPath).Trim()
        if ($verText.Length -gt 0) { $Script:Version = $verText }
    } catch {
        # Keep the fallback above; this must never block startup.
    }
}
$Script:StartTime = Get-Date
$Script:ShuttingDown = $false
$Script:LastResponseStatus = $null

$Script:Jobs = New-Object 'System.Collections.Generic.List[object]'
$Script:JobIdSeq = 0
# FLAVORS-SPEC.md CS-F2 S5.4: Test-JobBusy's single-job-at-a-time guard
# becomes PER-FLAVOUR scoped (a Retail sync and a Classic Era sync may run
# concurrently; two Retail syncs still can't) - $Script:CurrentJob (a single
# scalar) becomes a dictionary keyed by flavour id. $Script:Jobs (the shared
# rolling 20-job HISTORY, above) stays ONE list across every flavour, each
# job object now carrying its own .flavour field (S5.4) - only the "is a
# job currently running FOR THIS FLAVOUR" tracking is split out.
$Script:CurrentJobByFlavour = @{}
# FLAVORS-SPEC.md CS-F2 S5.3: freshness is computed "exactly the way today's
# single headline is, once per flavour" - so the bookkeeping that headline
# reads from becomes per-flavour too (keyed by flavour id), rather than one
# global scalar/hashtable shared across every flavour's addons.json.
$Script:UpdateAvailableByFlavour = @{}
$Script:LastRunByFlavour = @{}
$Script:UpdatesCheckedAtByFlavour = @{}
# CS1 (UX-SPEC.md section 4.2): in-memory only, never persisted to
# state.json (Save-CheckState is intentionally untouched by this pass) - a
# server restart forgets a stale failure, which is the right default: the
# freshness headline should reflect "have we actually seen a failure since
# this server came up", not resurrect one from a previous run. Per-flavour
# for the same S5.3 reason as the three dictionaries just above.
$Script:LastCheckFailedByFlavour = @{}
$Script:LastCheckErrorByFlavour = @{}
$Script:LastRequestTime = Get-Date
# E19: see Invoke-Route's static-file branch / Handle-Ping - flips to
# 'webview2' the first time the native host's Furphy tab loads.
$Script:HostKind = 'edge-app'
# E12: Wago Addons proxy state - WagoCache is a 5-minute response cache
# with a size-gated cleanup pattern; WagoInertiaVersion
# caches the site's Inertia asset version for the life of the process (and
# is persisted to/reloaded from state.json per SPEC's "cache the version in
# state.json" instruction, since this server, unlike the per-run CLI, stays
# up for a long time and would otherwise pay the plain-HTML handshake on
# every single Wago request).
$Script:WagoCache = @{}
$Script:WagoInertiaVersion = $null

# E16: keyless CurseForge enrichment state. CfCatalogueIndex/CfCatalogueById/
# CfCatalogueFetchedAt/CfCatalogueSource are populated by Initialize-
# CfCatalogueIndex below (disk cache load, or a fresh fetch when missing/
# stale); AddonRadarCache/AddonRadarSearchCache/WagoAutoMatchCache are
# in-memory 24h caches (the first also backed by an on-disk per-slug cache -
# see Get-AddonRadarDetail); LastAddonRadarRequestTime paces live
# addon-radar.com requests the same way LastRequestTime-style throttles are
# already used for Wago/CurseForge above.
$Script:CfCatalogueIndex = @()
$Script:CfCatalogueById = @{}
$Script:CfCatalogueFetchedAt = $null
$Script:CfCatalogueSource = $null
$Script:AddonRadarCache = @{}
$Script:AddonRadarSearchCache = @{}
$Script:WagoAutoMatchCache = @{}
$Script:LastAddonRadarRequestTime = [DateTime]::MinValue

# FLAVORS-SPEC.md CS-F2 S3.3: runs once, before any addons.json/state.json/
# backups\ path is resolved - moves a pre-flavour install's top-level files
# into flavours\<homeFlavour>\ (copy-first, idempotent - see the function's
# own doc comment). CS-F1's own notesForNext flagged this file explicitly
# ("a server-only first run would never migrate") - this closes that gap by
# duplicating the same call addon-sync.ps1's Main makes. Never throws on its
# own (see its doc comment) - wrapped anyway as an extra safety net, per
# that same note, since nothing here may ever block startup.
try {
    Invoke-FlavourMigration -RootPath $Script:Root
} catch {
    Write-ServerLog "Flavour migration failed: $($_.Exception.Message)"
}

# FLAVORS-SPEC.md CS-F2: Invoke-FlavourMigration (shared, duplicated
# verbatim from addon-sync.ps1 per the established pattern - see that
# function's own doc comment) moves a pre-flavour install's top-level
# state.json into flavours\<homeFlavour>\ along with addons.json/backups\,
# per S3.1's literal file-tree diagram. This server deliberately keeps
# state.json at the SHARED root instead (see Save-CheckState's own doc
# comment for why) - so on an upgrade from a pre-CS-F2 install, the
# just-migrated flavours\<home>\state.json is adopted back up as the shared
# root's state.json, exactly once (guarded on the shared file not already
# existing), before Load-CheckState ever reads it - otherwise an existing
# user's lastRun/updatesCheckedAt/job history would silently vanish behind
# a file this server's own Load-CheckState never looks at. Never touches
# the pre-move backup Invoke-FlavourMigration already made.
if (-not (Test-Path -LiteralPath $Script:StatePath)) {
    $homeFlavourForState = Get-MigrationHomeFlavour -RootPath $Script:Root
    $migratedStatePath = Join-Path -Path (Join-Path -Path (Join-Path -Path $Script:Root -ChildPath 'flavours') -ChildPath $homeFlavourForState) -ChildPath 'state.json'
    if (Test-Path -LiteralPath $migratedStatePath -PathType Leaf) {
        try {
            Move-Item -LiteralPath $migratedStatePath -Destination $Script:StatePath -Force
            Write-ServerLog "Flavour migration: adopted migrated flavours\$homeFlavourForState\state.json as the shared state.json"
        } catch {
            Write-ServerLog "Flavour migration: failed to adopt migrated state.json: $($_.Exception.Message)"
        }
    }
}

# FLAVORS-SPEC.md CS-F2: seeds $Script:CurrentFlavour/$Script:AddonsJsonPath/
# $Script:BackupsPath/$Script:ClientBuildInfo with the S4.1 default flavour
# (retail when installed, else the first detected, else 'retail') before the
# first request ever arrives - every later request re-resolves and
# re-stashes its OWN flavour via Invoke-Route/Set-CurrentFlavourContext (see
# that function's own doc comment), so this seed only matters for whatever
# runs between here and the first request (Load-CheckState's per-flavour
# state.json read, immediately below). $Script:ClientBuildInfo itself is
# still resolved fresh per request thereafter, not cached across the
# process's lifetime the way the old single-flavour code path was - E13's
# "server restart required to pick up a changed .build.info" tradeoff no
# longer applies once multiple flavours exist, since a request for a
# DIFFERENT flavour must never return the STARTUP flavour's stale build info.
$Script:InstalledFlavoursAtStartup = Get-CurrentInstalledFlavours
Set-CurrentFlavourContext -Flavor (Get-DefaultFlavourId -InstalledFlavours $Script:InstalledFlavoursAtStartup)

# E2/Round 3: reload the last check results, last run summary, and job
# history (if any) so the "n updates" badge, the My Addons "Last run" line,
# and the rollback tooltip / job list all survive a server restart instead
# of going blank until the next check/job.
Load-CheckState

# E16: loads (or, when missing/stale, fetches) the offline CurseForge
# catalogue index that /api/cf/browse and /api/cf/enrich fall back to when
# no key is configured. Best-effort - see the function's own doc comment;
# a failure here never blocks the server from starting.
Initialize-CfCatalogueIndex

if (-not (Test-Path -LiteralPath $Script:Root)) {
    throw "Root path does not exist: $Script:Root"
}
if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
    New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
}

if (-not $Port -or $Port -le 0) {
    $settingsForPort = Get-Settings
    if ($settingsForPort.port -and $settingsForPort.port -gt 0) {
        $Port = $settingsForPort.port
    } else {
        $Port = 47831
    }
}
$Script:Port = $Port

function Remove-OldJobFiles {
    <# Deletes job\*.out/*.err files older than 1 day, run once at startup. #>
    if (-not (Test-Path -LiteralPath $Script:JobsDir)) { return }
    $cutoff = (Get-Date).AddDays(-1)
    try {
        $files = Get-ChildItem -LiteralPath $Script:JobsDir -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.LastWriteTime -lt $cutoff) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
}
Remove-OldJobFiles

Write-ServerLog "Starting addon-server on port $Script:Port, root $Script:Root"

$listener = New-Object System.Net.HttpListener
# Round 20 (adversarial bug pass, security-1): a bare "localhost" prefix
# does not actually restrict http.sys to the loopback interface - it binds
# 0.0.0.0/[::] and dispatches purely on the request's Host header text,
# so any LAN client could reach this API by spoofing "Host: localhost"
# against the machine's real IP. An IP-literal prefix (127.0.0.1) makes
# http.sys bind and dispatch strictly on the loopback interface itself,
# closing that off. $appUrl below (used only to launch a local browser)
# is unaffected and deliberately left as "localhost".
$prefix = "http://127.0.0.1:$Script:Port/"
$listener.Prefixes.Add($prefix)
# Round 20 follow-up: Windows resolves "localhost" to the IPv6 loopback
# (::1) FIRST, so with only the 127.0.0.1 prefix every client that says
# "localhost" (the SPA, the host window, the tray, the handler, deploy.ps1)
# paid a refused-IPv6-connect fallback of 1-2 s per connection and health
# checks with short timeouts failed outright. Listen on the IPv6 loopback
# literal as well - still strictly loopback, the LAN stays closed. If the
# stack has no IPv6 the extra prefix is simply skipped.
$prefix6 = "http://[::1]:$Script:Port/"
try {
    if ([System.Net.Sockets.Socket]::OSSupportsIPv6) { $listener.Prefixes.Add($prefix6) }
} catch {
    Write-ServerLog "IPv6 loopback prefix not added: $($_.Exception.Message)"
}

try {
    $listener.Start()
} catch {
    Write-ServerLog "FATAL: could not start listener on $prefix : $($_.Exception.Message)"
    throw
}

Write-ServerLog "Listening on $(($listener.Prefixes | ForEach-Object { $_ }) -join ' and ')"

if ($OpenBrowser) {
    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    $appUrl = "http://localhost:$Script:Port/"
    try {
        if (Test-Path -LiteralPath $edgePath) {
            Start-Process -FilePath $edgePath -ArgumentList @("--app=$appUrl", '--window-size=1320,900')
        } else {
            Start-Process $appUrl
        }
    } catch {
        Write-ServerLog "Failed to open browser: $($_.Exception.Message)"
    }
}

$Script:LastRequestTime = Get-Date

try {
    $pending = $listener.BeginGetContext($null, $null)
    while ($true) {
        if ($Script:ShuttingDown) { break }

        $signaled = $pending.AsyncWaitHandle.WaitOne(2000)
        if (-not $signaled) {
            if ($Script:IdleMinutes -gt 0) {
                $idleSpan = (Get-Date) - $Script:LastRequestTime
                if ($idleSpan.TotalMinutes -ge $Script:IdleMinutes) {
                    # Round 20 (adversarial bug pass, server-2): unlike
                    # Handle-Shutdown (the explicit POST /api/shutdown),
                    # this idle-exit path used to only look at wall-clock
                    # time, never at whether a job was still running - a
                    # long sync left unattended past -IdleMinutes could get
                    # the whole server (and the listener) torn down out
                    # from under it, orphaning the CLI child process with
                    # no owner. Mirror Handle-Shutdown's own check: skip
                    # this idle break (re-checked every 2s regardless) while
                    # any flavour still has a job running.
                    $anyJobRunning = $false
                    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
                        if ($cj) {
                            $refreshedJob = Update-JobStatus -Job $cj
                            if ($refreshedJob -and $refreshedJob.state -eq 'running') { $anyJobRunning = $true }
                        }
                    }
                    if (-not $anyJobRunning) {
                        Write-ServerLog "Idle for $($Script:IdleMinutes) minutes - shutting down"
                        break
                    }
                }
            }
            continue
        }

        $context = $null
        try {
            $context = $listener.EndGetContext($pending)
        } catch {
            Write-ServerLog "EndGetContext failed: $($_.Exception.Message)"
            $pending = $listener.BeginGetContext($null, $null)
            continue
        }

        $Script:LastRequestTime = Get-Date

        try {
            Invoke-Route -Context $context
        } catch {
            Write-ServerLog "FATAL request handler error: $($_.Exception.Message)"
            try { $context.Response.Close() } catch { }
        }

        if ($Script:ShuttingDown) { break }
        $pending = $listener.BeginGetContext($null, $null)
    }
} finally {
    Write-ServerLog 'Stopping listener'
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-ServerLog 'Server stopped'
}
