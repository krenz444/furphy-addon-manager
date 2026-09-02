<#
=====================================================================
 addon-server.ps1

 Local HTTP server for the WoW Addon Manager. Serves the ui\ single
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
=====================================================================
#>

param(
    [int]$Port = 0,
    [string]$Root,
    [string]$AddonsPath,
    [int]$IdleMinutes = 20,
    [switch]$OpenBrowser,
    [string]$BuildInfoPath
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
# settings.json
# =====================================================================

function Get-DefaultSettings {
    return [PSCustomObject]@{
        releaseType        = 1
        autoUpdateOnLaunch = $true
        cfApiKey           = ''
        port               = 47831
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
        if ($null -ne $obj.cfApiKey) { $result.cfApiKey = [string]$obj.cfApiKey }
        if ($null -ne $obj.port) { $result.port = [int]$obj.port }
        return $result
    } catch {
        Write-ServerLog "Failed to read settings.json, using defaults: $($_.Exception.Message)"
        return Get-DefaultSettings
    }
}

function Get-SettingsView {
    <# settings.json with cfApiKey masked down to hasApiKey/apiKeyHint. #>
    param($Settings)

    $hasKey = [bool]($Settings.cfApiKey -and $Settings.cfApiKey.Length -gt 0)
    $hint = ''
    if ($hasKey -and $Settings.cfApiKey.Length -ge 4) {
        $hint = $Settings.cfApiKey.Substring($Settings.cfApiKey.Length - 4)
    }

    return [PSCustomObject]@{
        releaseType        = $Settings.releaseType
        autoUpdateOnLaunch = $Settings.autoUpdateOnLaunch
        port               = $Script:Port
        hasApiKey          = $hasKey
        apiKeyHint         = $hint
        addonsPath         = (Resolve-EffectiveAddonsPath)
        wowRoot            = (Get-WowRootPath)
        # E13: read-only info, not a manager setting - WoW's own
        # checkAddonVersion cvar from WTF\Config.wtf. PUT /api/settings never
        # accepts this key; it exists only for Settings > Game to display.
        checkAddonVersion = (Get-CheckAddonVersionSetting)
    }
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
    if ($Script:AddonsPathOverride) {
        return $Script:AddonsPathOverride
    }

    $leaf = Split-Path -Path $Script:Root -Leaf
    $parentDir = Split-Path -Path $Script:Root -Parent
    if (($leaf -eq 'AddonSync') -and $parentDir) {
        $parentLeaf = Split-Path -Path $parentDir -Leaf
        if ($parentLeaf -eq '_retail_') {
            return Join-Path -Path $parentDir -ChildPath 'Interface\AddOns'
        }
    }
    return $null
}

function Get-WowRootPath {
    $addonsPath = Resolve-EffectiveAddonsPath
    if (-not $addonsPath) {
        return $null
    }
    try {
        $interfaceDir = Split-Path -Path $addonsPath -Parent
        $retailDir = Split-Path -Path $interfaceDir -Parent
        return $retailDir
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

# E13: WoW's own checkAddonVersion cvar (WTF\Config.wtf, alongside the game
# root Get-WowRootPath already resolves - "SET checkAddonVersion "0"" means
# out-of-date addons load anyway) - read-only display info for Settings >
# Game, per roadmap E13. Returns the string value ("0"/"1"/whatever WoW
# wrote) or $null when Config.wtf/the setting isn't there yet (a fresh
# install that has never had the option toggled). Never throws.
function Get-CheckAddonVersionSetting {
    $wowRoot = Get-WowRootPath
    if (-not $wowRoot) { return $null }
    $configPath = Join-Path -Path (Join-Path -Path $wowRoot -ChildPath 'WTF') -ChildPath 'Config.wtf'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    try {
        $lines = Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $null
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*SET\s+checkAddonVersion\s+"([^"]*)"') {
            return $Matches[1]
        }
    }
    return $null
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
      Fix pass: duplicate of addon-sync.ps1's identically-named function
      (this script never dot-sources the CLI) - picks the .toc file WoW
      retail actually loads for one installed folder, out of however many
      game-flavor variants a package ships in the same folder (a base
      "<folder>.toc" for one client, often NOT retail, alongside a
      "<folder>_Mainline.toc"/"<folder>-Mainline.toc" specifically for
      retail). Order: "<folder>_Mainline.toc", "<folder>-Mainline.toc",
      "<folder>.toc", else the first .toc found. $null when there is none.
      Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$FolderName
    )

    $tocFiles = Get-ChildItem -LiteralPath $FolderPath -Filter '*.toc' -File -ErrorAction SilentlyContinue
    if (-not $tocFiles) {
        return $null
    }
    # Built with -f, not "$FolderName_Mainline.toc" - PowerShell would parse
    # the latter as ${FolderName_Mainline} (underscore is a valid identifier
    # character), not $FolderName followed by literal text.
    $preferredNames = @(
        ('{0}_Mainline.toc' -f $FolderName),
        ('{0}-Mainline.toc' -f $FolderName),
        ('{0}.toc' -f $FolderName)
    )
    foreach ($preferredName in $preferredNames) {
        foreach ($t in $tocFiles) {
            if ($t.Name -eq $preferredName) { return $t }
        }
    }
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
        [Parameter(Mandatory = $true)][string]$FolderName
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
    $chosen = Get-PrimaryTocFile -FolderPath $folderPath -FolderName $FolderName
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
        if ($line -match '^\s*##\s*Interface-Mainline\s*:\s*(.*)$') {
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
    param($AddonsPath, $Folders)

    $seen = New-Object 'System.Collections.Generic.HashSet[int64]'
    $result = New-Object 'System.Collections.Generic.List[object]'
    # Plain foreach, not @($Folders) - matches the CLI's identical function
    # exactly (see its own note on the machine's List[object]/@() quirk);
    # $Folders is a JSON-parsed record property here (never a List[object]
    # in practice), but there is no reason to risk it.
    foreach ($folderName in $Folders) {
        foreach ($v in (Get-TocInterfaceValues -AddonsPath $AddonsPath -FolderName $folderName)) {
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
    <# Reads .build.info's "wow" (retail) row -> {clientBuild; clientInterface}. See addon-sync.ps1's identical function for the full contract; never throws. #>
    param([string]$BuildInfoPath)

    $result = [PSCustomObject]@{ clientBuild = $null; clientInterface = $null }
    if (-not $BuildInfoPath -or -not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf)) {
        return $result
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
        if ($cols[$productIdx].Trim() -eq 'wow') {
            $versionText = $cols[$versionIdx].Trim()
            $result.clientBuild = $versionText
            $parts = $versionText -split '\.'
            if ($parts.Count -ge 3) {
                $maj = 0
                $min = 0
                $pat = 0
                if ([int]::TryParse($parts[0], [ref]$maj) -and [int]::TryParse($parts[1], [ref]$min) -and [int]::TryParse($parts[2], [ref]$pat)) {
                    $result.clientInterface = ($maj * 10000) + ($min * 100) + $pat
                }
            }
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
            if (-not ($Params -and $Params.projectId)) {
                throw 'projectId is required for kind add'
            }
            $argsList.Add('-Add')
            $argsList.Add([string]$Params.projectId)
            if ($Params.fileId) {
                $argsList.Add('-FileId')
                $argsList.Add([string]$Params.fileId)
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

function New-CliProcessArgs {
    <# Full powershell.exe argument list for one addon-sync.ps1 invocation. #>
    param([System.Collections.Generic.List[object]]$CliArgs)

    $psArgs = New-Object 'System.Collections.Generic.List[object]'
    $psArgs.Add('-NoProfile')
    $psArgs.Add('-ExecutionPolicy')
    $psArgs.Add('Bypass')
    # Start-Process joins -ArgumentList elements with spaces and does NOT quote
    # them, so paths with spaces (C:\Program Files (x86)\...) must be quoted here.
    $psArgs.Add('-File')
    $psArgs.Add('"' + $Script:CliPath + '"')
    foreach ($a in $CliArgs) { $psArgs.Add($a) }
    $psArgs.Add('-Json')
    if ($Script:AddonsPathOverride) {
        $psArgs.Add('-AddonsPath')
        $psArgs.Add('"' + $Script:AddonsPathOverride + '"')
    }
    Write-Output -NoEnumerate $psArgs
}

function Test-JobBusy {
    <#
      True (and, if -Context given, writes a 409 busy response) when a job is
      currently running. Refreshes the current job's state first so a job
      that just finished is not reported busy.
    #>
    param($Context)

    if ($Script:CurrentJob -and $Script:CurrentJob.state -eq 'running') {
        Update-JobStatus -Job $Script:CurrentJob | Out-Null
    }
    if ($Script:CurrentJob -and $Script:CurrentJob.state -eq 'running') {
        if ($Context) {
            Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $Script:CurrentJob.id }
        }
        return $true
    }
    return $false
}

function Start-Job {
    <#
      Starts one job (spec section 2, "Jobs" table). Returns a hashtable:
        Busy  = $true  -> a job is already running (Job holds it)
        Error = <text> -> could not start (bad params, process launch failed)
        Job   = <job>  -> started (or, for launch/no-update, already finished)
    #>
    param(
        [string]$Kind,
        $Params
    )

    if (Test-JobBusy) {
        return @{ Busy = $true; Job = $Script:CurrentJob }
    }

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
            Process       = $null
            OutFile       = $null
            ErrFile       = $null
            SyncLogOffset = 0
            LaunchAfter   = $false
        }
        Add-JobToHistory -Job $job
        $Script:CurrentJob = $job
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
        $Script:CurrentJob = $null
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
        return (Start-ImportJob -JobId $jobId -StartedAt $startedAt -Params $Params)
    }

    # E12: switch-source (uninstall the tracked addon, then add it fresh from
    # the OTHER source) is, like import, a multi-phase job - see
    # Start-SwitchSourceJob/Complete-SwitchSourcePhase.
    if ($Kind -eq 'switch-source') {
        return (Start-SwitchSourceJob -JobId $jobId -StartedAt $startedAt -Params $Params)
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

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs

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
        Process       = $proc
        OutFile       = $outFile
        ErrFile       = $errFile
        SyncLogOffset = $syncLogOffset
        LaunchAfter   = $launchAfter
    }
    Add-JobToHistory -Job $job
    $Script:CurrentJob = $job
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
      projectId,fileId} rows> }.

      -Add is issued ONCE with every not-yet-present projectId comma-joined
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
      per-addon restriction, so every id that wants it - freshly added by
      this import or already on record - is batched into one trailing
      -Ignore phase. releaseType is captured on export for round-tripping
      but is deliberately NOT applied on import: no CLI flag sets a
      record's per-addon releaseType override directly (SPEC.md's addon-
      sync.ps1 contract has no such param), and inventing a direct
      addons.json write here would break the "the CLI owns writes" rule
      this whole file otherwise holds to.

      An imported addon already present with neither pinnedFileId nor
      ignoreUpdates set needs no CLI call at all - its SkipRow mirrors the
      exact shape addon-sync.ps1's own "-Add: already present" path already
      produces (Name/Version/FileId straight from the EXISTING record), so
      the job's results read the same as they would if the underlying add
      job itself had done the skipping.
    #>
    param(
        [Parameter(Mandatory = $true)]$ImportAddons,
        [Parameter(Mandatory = $true)][hashtable]$ExistingById
    )

    $phases = New-Object 'System.Collections.Generic.List[object]'
    $skipRows = New-Object 'System.Collections.Generic.List[object]'

    $seenIds = New-Object 'System.Collections.Generic.HashSet[int64]'
    $toAddIds = New-Object 'System.Collections.Generic.List[object]'
    $pinEntries = New-Object 'System.Collections.Generic.List[object]'
    $ignoreIds = New-Object 'System.Collections.Generic.List[object]'
    $ignoreSeen = New-Object 'System.Collections.Generic.HashSet[int64]'

    foreach ($entry in @($ImportAddons)) {
        if (-not $entry -or ($null -eq $entry.projectId)) { continue }
        # NOTE: named $entryPid, not $pid - $pid (case-insensitively) is
        # PowerShell's own read-only automatic variable holding this
        # process's id, and assigning to it throws "Cannot overwrite
        # variable PID because it is read-only or constant." (caught live
        # during this build's own offline verification).
        $entryPid = [int64]0
        try { $entryPid = [int64]$entry.projectId } catch { continue }
        if (-not $seenIds.Add($entryPid)) { continue }   # dedupe within the import file itself

        $existingRecord = $null
        $isNew = $true
        if ($ExistingById.ContainsKey($entryPid)) {
            $existingRecord = $ExistingById[$entryPid]
            $isNew = $false
        }

        $hasPin = $false
        $fid = [int64]0
        if ($null -ne $entry.pinnedFileId) {
            try { $fid = [int64]$entry.pinnedFileId; $hasPin = $true } catch { $hasPin = $false }
        }
        $hasIgnore = [bool]$entry.ignoreUpdates

        if ($isNew) {
            $toAddIds.Add($entryPid)
        }
        if ($hasPin) {
            $pinEntries.Add([PSCustomObject]@{ ProjectId = $entryPid; FileId = $fid })
        }
        if ($hasIgnore -and $ignoreSeen.Add($entryPid)) {
            $ignoreIds.Add($entryPid)
        }

        if ((-not $isNew) -and (-not $hasPin) -and (-not $hasIgnore)) {
            $skipRows.Add([PSCustomObject]@{
                    status    = 'Skipped'
                    name      = $existingRecord.name
                    version   = $existingRecord.version
                    projectId = $existingRecord.projectId
                    fileId    = $existingRecord.fileId
                })
        }
    }

    if ($toAddIds.Count -gt 0) {
        $idStrings = New-Object 'System.Collections.Generic.List[object]'
        foreach ($id in $toAddIds) { $idStrings.Add([string]$id) }
        $addArgs = New-Object 'System.Collections.Generic.List[object]'
        $addArgs.Add('-Add')
        $addArgs.Add(($idStrings -join ','))
        $phases.Add($addArgs)
    }

    foreach ($pin in $pinEntries) {
        $pinArgs = New-Object 'System.Collections.Generic.List[object]'
        $pinArgs.Add('-Only')
        $pinArgs.Add([string]$pin.ProjectId)
        $pinArgs.Add('-FileId')
        $pinArgs.Add([string]$pin.FileId)
        $phases.Add($pinArgs)
    }

    if ($ignoreIds.Count -gt 0) {
        $ignoreStrings = New-Object 'System.Collections.Generic.List[object]'
        foreach ($id in $ignoreIds) { $ignoreStrings.Add([string]$id) }
        $ignoreArgs = New-Object 'System.Collections.Generic.List[object]'
        $ignoreArgs.Add('-Ignore')
        $ignoreArgs.Add(($ignoreStrings -join ','))
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

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs

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
        $Params
    )

    $importAddons = @()
    if ($Params -and ($null -ne $Params.addons)) { $importAddons = @($Params.addons) }

    $existingById = @{}
    foreach ($r in (Get-AddonRecords)) {
        if ($r.projectId) {
            try { $existingById[[int64]$r.projectId] = $r } catch { }
        }
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
    $Script:CurrentJob = $job

    $started = Start-ImportPhase -Job $job
    if (-not $started) {
        $job.state = 'failed'
        $job.error = 'Failed to start import'
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Script:CurrentJob = $null
        Save-CheckState
    }
    return @{ Busy = $false; Job = $job }
}

# =====================================================================
# state.json: persisted check results (E2 - automatic update checks)
# =====================================================================

function Save-CheckState {
    <#
      Persists $Script:UpdatesCheckedAt + $Script:UpdateAvailable (E2) and,
      as of Round 3, $Script:LastRun + the last 20 completed jobs to
      ROOT\state.json, so the "n updates" badge, the My Addons "Last run"
      line (/api/state.lastRun), the rollback tooltip / job history
      (/api/state.job, /api/jobs) all survive a server restart instead of
      resetting to null/empty. Jobs are serialized via Get-JobStatusView -
      plain data (id/kind/params/state/.../log[]/results[]/error), never the
      raw Job objects, which carry a live System.Diagnostics.Process handle
      that cannot be (and must never be) JSON-serialized. Best-effort: a
      write failure is logged, never thrown (must not abort the
      job-completion path that calls this).
    #>
    $jobViews = New-Object 'System.Collections.Generic.List[object]'
    foreach ($j in $Script:Jobs) {
        $jobViews.Add((Get-JobStatusView -Job $j))
    }

    $body = [PSCustomObject]@{
        updatesCheckedAt   = $Script:UpdatesCheckedAt
        updateAvailable    = $Script:UpdateAvailable
        lastRun            = $Script:LastRun
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
      at startup into $Script:UpdatesCheckedAt / $Script:UpdateAvailable /
      $Script:LastRun / $Script:Jobs. Tolerates a missing, empty, or corrupt
      file (leaves the caller's already-initialized defaults/empty list in
      place).

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
        if ($null -ne $obj.updatesCheckedAt) {
            $Script:UpdatesCheckedAt = [string]$obj.updatesCheckedAt
        }
        if ($null -ne $obj.updateAvailable) {
            $map = @{}
            foreach ($p in $obj.updateAvailable.PSObject.Properties) {
                $map[$p.Name] = @{ fileId = $p.Value.fileId; version = $p.Value.version }
            }
            $Script:UpdateAvailable = $map
        }
        if ($null -ne $obj.lastRun) {
            $Script:LastRun = $obj.lastRun
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
        Write-ServerLog "Loaded state.json: updatesCheckedAt=$($Script:UpdatesCheckedAt) updateAvailable entries=$($Script:UpdateAvailable.Count) jobs=$($Script:Jobs.Count)"
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
    #>
    param($Job, $Parsed)

    $action = $null
    if ($Parsed -and $Parsed.action) {
        $action = [string]$Parsed.action
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $Job.results) { $rows.Add($r) }

    if ($action -eq 'check') {
        $Script:UpdatesCheckedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Script:UpdateAvailable = @{}
        foreach ($r in $rows) {
            if ($r.status -eq 'Would-update') {
                # E12: keyed by projectId when present, else "wago:<slug>" -
                # see Get-UpdateAvailableKeyForRow.
                $key = Get-UpdateAvailableKeyForRow -Row $r
                if ($key) {
                    $Script:UpdateAvailable[$key] = @{ fileId = $r.fileId; version = $r.version }
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
                if ($key -and $Script:UpdateAvailable.ContainsKey($key)) {
                    $Script:UpdateAvailable.Remove($key)
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
        $Script:LastRun = [PSCustomObject]@{
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
        if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) { $Script:CurrentJob = $null }
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
            if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) { $Script:CurrentJob = $null }
            Save-CheckState
        }
        return $Job
    }

    $Job.exitCode = 0
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Job.state = 'done'
    Apply-JobCompletionSideEffects -Job $Job -Parsed ([PSCustomObject]@{ action = 'import' })

    if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) { $Script:CurrentJob = $null }
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

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs

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
        $Params
    )

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
    $Script:CurrentJob = $job

    $started = Start-SwitchSourcePhase -Job $job
    if (-not $started) {
        $job.state = 'failed'
        $job.error = 'Failed to start switch-source'
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Script:CurrentJob = $null
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
        if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) { $Script:CurrentJob = $null }
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
            if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) { $Script:CurrentJob = $null }
            Save-CheckState
        }
        return $Job
    }

    $Job.exitCode = 0
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Job.state = 'done'
    Apply-JobCompletionSideEffects -Job $Job -Parsed ([PSCustomObject]@{ action = 'switch-source' })

    if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) { $Script:CurrentJob = $null }
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
    }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    if ($Script:CurrentJob -and $Script:CurrentJob.id -eq $Job.id) {
        $Script:CurrentJob = $null
    }

    # Round 3: persist lastRun + job history to state.json now that this
    # job's final state/results/error are all set (Apply-JobCompletionSideEffects,
    # above, already updated $Script:LastRun/UpdateAvailable/UpdatesCheckedAt
    # for a successful job). Called once here for BOTH the done and failed
    # outcomes - not from inside Apply-JobCompletionSideEffects, which only
    # ever runs on success - so a failed job still lands in the persisted
    # history instead of vanishing on the next restart.
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
    }
}

function Get-CurrentOrLastJobSummary {
    if ($Script:CurrentJob) {
        return Get-JobStatusView -Job (Update-JobStatus -Job $Script:CurrentJob)
    }
    if ($Script:Jobs.Count -gt 0) {
        return Get-JobStatusView -Job $Script:Jobs[$Script:Jobs.Count - 1]
    }
    return $null
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
# Invoke-CfApi: CurseForge Core API proxy (key-gated, cached, timed out)
# =====================================================================

function Invoke-CfApi {
    <#
      Proxies one CurseForge Core API call. Returns a hashtable:
        NoKey = $true                          -> no cfApiKey configured
        NoKey = $false; StatusCode; Body(text)  -> upstream response (as-is)
      GET responses are cached in-memory by full URL for 5 minutes.
    #>
    param(
        [string]$Path,
        [hashtable]$Query,
        [string]$Method = 'GET',
        $BodyObject
    )

    $settings = Get-Settings
    if (-not $settings.cfApiKey -or $settings.cfApiKey.Trim().Length -eq 0) {
        return @{ NoKey = $true }
    }

    $base = 'https://api.curseforge.com'
    $qs = ''
    if ($Query -and $Query.Count -gt 0) {
        $parts = New-Object 'System.Collections.Generic.List[object]'
        foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($null -ne $v -and [string]$v -ne '') {
                $parts.Add([System.Uri]::EscapeDataString($k) + '=' + [System.Uri]::EscapeDataString([string]$v))
            }
        }
        if ($parts.Count -gt 0) { $qs = '?' + ($parts -join '&') }
    }
    $uri = $base + $Path + $qs
    $cacheKey = $Method + ' ' + $uri

    if ($Method -eq 'GET' -and $Script:CfCache.ContainsKey($cacheKey)) {
        $entry = $Script:CfCache[$cacheKey]
        $age = (Get-Date) - $entry.Time
        if ($age.TotalSeconds -lt 300) {
            return @{ NoKey = $false; StatusCode = $entry.StatusCode; Body = $entry.Body }
        } else {
            $Script:CfCache.Remove($cacheKey)
        }
    }

    $headers = @{ 'x-api-key' = $settings.cfApiKey; 'Accept' = 'application/json' }
    $statusCode = 0
    $bodyText = ''

    try {
        if ($Method -eq 'POST') {
            $jsonBody = ConvertTo-Json -InputObject $BodyObject -Depth 10 -Compress
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -Method Post -Body $jsonBody -ContentType 'application/json' -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        } else {
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        }
        $statusCode = [int]$resp.StatusCode
        $bodyText = $resp.Content
    } catch {
        $errResp = $null
        try { $errResp = $_.Exception.Response } catch { $errResp = $null }
        if ($errResp) {
            try { $statusCode = [int]$errResp.StatusCode } catch { $statusCode = 502 }
            try {
                $stream = $errResp.GetResponseStream()
                $sr = New-Object System.IO.StreamReader($stream)
                try {
                    $bodyText = $sr.ReadToEnd()
                } finally {
                    # Closes $stream too (StreamReader owns it by default);
                    # in a finally so a ReadToEnd() failure still releases it
                    # instead of leaking the response stream.
                    $sr.Close()
                }
            } catch {
                $bodyText = ConvertTo-Json -InputObject @{ error = $_.Exception.Message } -Compress
            }
        } else {
            $statusCode = 502
            $bodyText = ConvertTo-Json -InputObject @{ error = $_.Exception.Message } -Compress
        }
    }

    if ($Method -eq 'GET' -and $statusCode -ge 200 -and $statusCode -lt 300) {
        # Round 5: bound the cache's growth. An entry is only ever evicted
        # lazily, on a re-request of that SAME key, once its 5-minute TTL has
        # passed (see the read path above) - a long browsing session hitting
        # many distinct search/mod/category URLs would otherwise accumulate
        # entries with no upper bound at all. Before adding a new entry, once
        # the cache is large enough to be worth the scan, drop every already-
        # expired entry (same TTL the read path already enforces); if that
        # still leaves it oversized (many distinct URLs all still fresh),
        # clear it outright rather than add a more complex LRU scheme for
        # what is, worst case, one extra upstream re-fetch per key afterward.
        if ($Script:CfCache.Count -ge 200) {
            $now = Get-Date
            $staleKeys = New-Object 'System.Collections.Generic.List[object]'
            foreach ($k in $Script:CfCache.Keys) {
                $age = $now - $Script:CfCache[$k].Time
                if ($age.TotalSeconds -ge 300) { $staleKeys.Add($k) }
            }
            foreach ($k in $staleKeys) { $Script:CfCache.Remove($k) }
            if ($Script:CfCache.Count -ge 200) {
                $Script:CfCache.Clear()
            }
        }
        $Script:CfCache[$cacheKey] = @{ Time = (Get-Date); StatusCode = $statusCode; Body = $bodyText }
    }

    return @{ NoKey = $false; StatusCode = $statusCode; Body = $bodyText }
}

function Send-CfApiResult {
    <# Relays an Invoke-CfApi result to the HTTP response, verbatim status/body, or 409 no-key. #>
    param($Context, $Result)

    if ($Result.NoKey) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'no-key' }
        return
    }

    $response = $Context.Response
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Result.Body)
        $response.StatusCode = $Result.StatusCode
        $response.ContentType = 'application/json; charset=utf-8'
        $response.Headers.Set('Cache-Control', 'no-store')
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Script:LastResponseStatus = $Result.StatusCode
    } finally {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }
}

function Test-CfApiKey {
    <#
      Tests one CurseForge Core API key via GET /v1/games/1 (SPEC.md's "key
      test" endpoint). Returns @{ ok; message } and never throws - every
      failure path already resolves to a message string. E10: shared by
      Handle-SettingsTestKey (Settings > API key > Test) and Handle-Diagnostics's
      "CurseForge API key" check, so the two report identically instead of
      drifting apart.
    #>
    param([string]$Key)

    if (-not $Key -or $Key.Trim().Length -eq 0) {
        return @{ ok = $false; message = 'No API key provided' }
    }

    $headers = @{ 'x-api-key' = $Key; 'Accept' = 'application/json' }
    try {
        $resp = Invoke-WebRequest -Uri 'https://api.curseforge.com/v1/games/1' -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        if ([int]$resp.StatusCode -eq 200) {
            return @{ ok = $true; message = 'Key is valid' }
        }
        return @{ ok = $false; message = "CurseForge returned status $([int]$resp.StatusCode)" }
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            return @{ ok = $false; message = 'Key rejected by CurseForge' }
        }
        return @{ ok = $false; message = $_.Exception.Message }
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
      full page URI - mirrors Invoke-CfApi's $Script:CfCache cache/cleanup
      shape (kept as its own separate hashtable/function rather than sharing
      CfCache, so a bug in one proxy's cache handling can't reach the
      other's).
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

    $uri = 'https://addons.wago.io/?game_version=retail&page=' + [System.Uri]::EscapeDataString($page)
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
            return @{ ok = $true; detail = $mtime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        } catch {
            return @{ ok = $false; detail = $_.Exception.Message }
        }
    }
    if ($Script:LastRun -and $Script:LastRun.timestamp) {
        return @{ ok = $true; detail = [string]$Script:LastRun.timestamp }
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

# =====================================================================
# Route handlers
# =====================================================================

function Handle-Ping {
    param($Context, $RouteMatch)

    $uptime = ((Get-Date) - $Script:StartTime).TotalSeconds
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; version = $Script:Version; uptime = [math]::Round($uptime, 1) }
}

function Handle-State {
    param($Context, $RouteMatch)

    $records = Get-AddonRecords
    # E3: computed once per /api/state call and shared across every record,
    # rather than re-listing the AddOns directory per addon.
    $presentFolders = Get-PresentAddonFolders
    # E13: likewise computed once and shared - each record's own toc parse
    # still happens per addon, but resolving the AddOns path itself does not.
    $compatAddonsPath = Resolve-EffectiveAddonsPath
    $addonsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $records) {
        # E12: updateAvailable is keyed by the numeric CurseForge project id
        # (unchanged) OR, for a Wago-sourced record (no numeric projectId at
        # all), by "wago:<slug>" - see Get-UpdateAvailableKeyForRecord.
        $upd = $null
        $key = Get-UpdateAvailableKeyForRecord -Record $r
        if ($key -and $Script:UpdateAvailable.ContainsKey($key)) {
            $u = $Script:UpdateAvailable[$key]
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
        $tocIfaces = Get-PackageTocInterfaces -AddonsPath $compatAddonsPath -Folders $r.folders
        $compat = Get-AddonCompat -TocInterfaces $tocIfaces -LatestGameVersions $r.latestGameVersions -ClientInterface $Script:ClientBuildInfo.clientInterface
        $clone | Add-Member -MemberType NoteProperty -Name 'tocInterfaces' -Value $tocIfaces.ToArray()
        $clone | Add-Member -MemberType NoteProperty -Name 'compat' -Value $compat
        $addonsOut.Add($clone)
    }

    $settings = Get-Settings
    $body = [PSCustomObject]@{
        addons           = $addonsOut.ToArray()
        settings         = Get-SettingsView -Settings $settings
        lastRun          = $Script:LastRun
        job              = (Get-CurrentOrLastJobSummary)
        updatesCheckedAt = $Script:UpdatesCheckedAt
        # E13: read once at startup (Script:ClientBuildInfo) - see the
        # Startup section - not re-read from disk on every /api/state poll.
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
    $validKinds = @('sync', 'check', 'add', 'remove', 'install', 'launch', 'rollback', 'switch-source')
    if (-not ($validKinds -contains $kind)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = "bad request: unknown kind '$kind'" }
        return
    }
    # E12: a NEW Wago add (no existing record, so no projectId-equivalent key
    # yet) is posted as {source:'wago', slug} instead of projectId - either
    # is accepted here.
    $hasWagoSourceSlug = [bool]($body.source -and $body.slug)
    if ($kind -eq 'add' -and (-not $body.projectId) -and (-not $hasWagoSourceSlug)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
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

    $result = Start-Job -Kind $kind -Params $body
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
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'job not found' }
        return
    }
    $job = Update-JobStatus -Job $job
    Send-Json -Context $Context -StatusCode 200 -Body (Get-JobStatusView -Job $job)
}

function Handle-JobsGetAll {
    param($Context, $RouteMatch)

    if ($Script:CurrentJob) {
        Update-JobStatus -Job $Script:CurrentJob | Out-Null
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
        $rt = [int]$body.releaseType
        if ($rt -lt 1 -or $rt -gt 3) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'releaseType must be 1-3' }
            return
        }
        $settings.releaseType = $rt
    }
    if ($null -ne $body.autoUpdateOnLaunch) {
        $settings.autoUpdateOnLaunch = [bool]$body.autoUpdateOnLaunch
    }
    if ($null -ne $body.cfApiKey) {
        $settings.cfApiKey = [string]$body.cfApiKey
    }
    if ($null -ne $body.port) {
        $settings.port = [int]$body.port
    }

    try {
        Save-Settings -Settings $settings
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body (Get-SettingsView -Settings $settings)
}

function Handle-SettingsTestKey {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    $key = $null
    if ($body -and $body.cfApiKey) { $key = [string]$body.cfApiKey }
    if (-not $key) {
        $settings = Get-Settings
        $key = $settings.cfApiKey
    }

    # E10: the actual key-test call (GET /v1/games/1 + status interpretation)
    # now lives in the shared Test-CfApiKey, also used by Handle-Diagnostics's
    # "CurseForge API key" check - this handler just supplies the key and
    # relays the result unchanged (always 200, ok/message in the body, exactly
    # as before this refactor).
    Send-Json -Context $Context -StatusCode 200 -Body (Test-CfApiKey -Key $key)
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

    # "official API key valid (only if key configured)" - an unconfigured key
    # is not itself a failure, so this reports ok:true with an explanatory
    # detail rather than being omitted (every /api/diagnostics call always
    # returns the same fixed set of check names).
    $settings = Get-Settings
    if ($settings.cfApiKey -and $settings.cfApiKey.Trim().Length -gt 0) {
        $checks.Add((New-DiagCheckRow -Name 'CurseForge API key' -Result (Test-CfApiKey -Key $settings.cfApiKey)))
    } else {
        $checks.Add((New-DiagCheckRow -Name 'CurseForge API key' -Result @{ ok = $true; detail = 'No API key configured (optional)' }))
    }

    $checks.Add((New-DiagCheckRow -Name 'Disk space' -Result (Test-DiagDiskSpace)))
    $checks.Add((New-DiagCheckRow -Name 'PowerShell version' -Result (Test-DiagPowerShellVersion)))
    $checks.Add((New-DiagCheckRow -Name 'Server uptime' -Result (Test-DiagServerUptime -UptimeSeconds ((Get-Date) - $Script:StartTime).TotalSeconds)))
    $checks.Add((New-DiagCheckRow -Name 'Last sync' -Result (Test-DiagLastSync)))
    # E13: the client build $Script:ClientBuildInfo already resolved once at
    # startup (roadmap: "/api/diagnostics includes the client build").
    $checks.Add((New-DiagCheckRow -Name 'WoW client build' -Result (Test-DiagClientBuild)))

    Send-Json -Context $Context -StatusCode 200 -Body @{ checks = $checks.ToArray() }
}

function Handle-CfSearch {
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $query = @{
        gameId            = 1
        classId           = 1
        gameVersionTypeId = 517
        searchFilter      = $q['q']
        categoryId        = $q['categoryId']
        sortField         = (Get-QueryOrDefault -QueryString $q -Name 'sortField' -Default '2')
        sortOrder         = (Get-QueryOrDefault -QueryString $q -Name 'sortOrder' -Default 'desc')
        index             = (Get-QueryOrDefault -QueryString $q -Name 'index' -Default '0')
        pageSize          = (Get-QueryOrDefault -QueryString $q -Name 'pageSize' -Default '20')
    }
    $result = Invoke-CfApi -Path '/v1/mods/search' -Query $query -Method 'GET'
    Send-CfApiResult -Context $Context -Result $result
}

function Handle-CfCategories {
    param($Context, $RouteMatch)

    $result = Invoke-CfApi -Path '/v1/categories' -Query @{ gameId = 1; classId = 1 } -Method 'GET'
    Send-CfApiResult -Context $Context -Result $result
}

function Handle-CfModGet {
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $result = Invoke-CfApi -Path "/v1/mods/$id" -Query $null -Method 'GET'
    Send-CfApiResult -Context $Context -Result $result
}

function Handle-CfModsPost {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.ids) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'ids required' }
        return
    }

    $settings = Get-Settings
    if (-not $settings.cfApiKey -or $settings.cfApiKey.Trim().Length -eq 0) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'no-key' }
        return
    }

    $allIds = @($body.ids)
    $combined = New-Object 'System.Collections.Generic.List[object]'
    $chunk = New-Object 'System.Collections.Generic.List[object]'

    for ($i = 0; $i -lt $allIds.Count; $i++) {
        $chunk.Add([int64]$allIds[$i])
        $isLast = ($i -eq ($allIds.Count - 1))
        if ($chunk.Count -eq 50 -or $isLast) {
            $bodyObj = @{ modIds = $chunk.ToArray() }
            $result = Invoke-CfApi -Path '/v1/mods' -Method 'POST' -BodyObject $bodyObj
            if ($result.NoKey) {
                Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'no-key' }
                return
            }
            if ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300) {
                try {
                    $parsed = $result.Body | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed.data) {
                        foreach ($m in @($parsed.data)) { $combined.Add($m) }
                    }
                } catch {
                    Send-Json -Context $Context -StatusCode 502 -Body @{ error = 'Invalid JSON from CurseForge' }
                    return
                }
            } else {
                Send-Json -Context $Context -StatusCode $result.StatusCode -Body @{ error = "CurseForge returned status $($result.StatusCode)" }
                return
            }
            $chunk = New-Object 'System.Collections.Generic.List[object]'
        }
    }

    Send-Json -Context $Context -StatusCode 200 -Body @{ data = $combined.ToArray() }
}

function Handle-CfModDescription {
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $result = Invoke-CfApi -Path "/v1/mods/$id/description" -Query $null -Method 'GET'
    Send-CfApiResult -Context $Context -Result $result
}

function Handle-CfModFiles {
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $q = $Context.Request.QueryString
    $query = @{
        gameVersionTypeId = 517
        index             = $q['index']
        pageSize          = $q['pageSize']
    }
    $result = Invoke-CfApi -Path "/v1/mods/$id/files" -Query $query -Method 'GET'
    Send-CfApiResult -Context $Context -Result $result
}

function Handle-CfModChangelog {
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $fileId = $RouteMatch['fileId']
    $result = Invoke-CfApi -Path "/v1/mods/$id/files/$fileId/changelog" -Query $null -Method 'GET'
    Send-CfApiResult -Context $Context -Result $result
}

function Handle-CfResolve {
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $urlOrSlug = $q['url']
    if ([string]::IsNullOrWhiteSpace($urlOrSlug)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
        return
    }

    $slug = $urlOrSlug.Trim()
    if ($slug -match '/wow/addons/([^/?#]+)') {
        $slug = $Matches[1]
    }

    $result = Invoke-CfApi -Path '/v1/mods/search' -Query @{ gameId = 1; classId = 1; slug = $slug } -Method 'GET'
    if ($result.NoKey) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'no-key' }
        return
    }
    if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
        Send-Json -Context $Context -StatusCode $result.StatusCode -Body @{ error = "CurseForge returned status $($result.StatusCode)" }
        return
    }

    try {
        $parsed = $result.Body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = 'Invalid JSON from CurseForge' }
        return
    }

    $items = @()
    if ($parsed.data) { $items = @($parsed.data) }
    if ($items.Count -eq 0) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }

    $first = $items[0]
    Send-Json -Context $Context -StatusCode 200 -Body @{ projectId = $first.id; name = $first.name }
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
                # "break URL parsing". EscapeDataString (the same encoder
                # Invoke-CfApi already uses for its own query values) percent-
                # encodes quotes/spaces/slashes/etc., closing that off for what
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
                $backupsPath = Join-Path -Path $Script:Root -ChildPath 'backups'
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
            'url' {
                # E3: drawer's "Search CurseForge" button for a missing dependency,
                # used only when no API key is configured (a keyed session switches
                # to Browse client-side instead). Restricted to the two addon
                # marketplaces this app ever links to, so this endpoint can never be
                # used to open an arbitrary URL in the user's default browser.
                $url = $null
                if ($body.url) { $url = [string]$body.url }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
                    return
                }
                $allowedPrefixes = @('https://www.curseforge.com/', 'https://addons.wago.io/')
                $allowed = $false
                foreach ($prefix in $allowedPrefixes) {
                    if ($url.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $allowed = $true
                        break
                    }
                }
                if (-not $allowed) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url must start with https://www.curseforge.com/ or https://addons.wago.io/' }
                    return
                }
                Open-InBrowser -Url $url
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

    if ($Script:CurrentJob) {
        Update-JobStatus -Job $Script:CurrentJob | Out-Null
    }
    if ($Script:CurrentJob -and $Script:CurrentJob.state -eq 'running') {
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
    @{ Method = 'POST'; Pattern = '^/api/settings/test-key$'; Handler = 'Handle-SettingsTestKey' }
    @{ Method = 'GET'; Pattern = '^/api/diagnostics$'; Handler = 'Handle-Diagnostics' }
    @{ Method = 'GET'; Pattern = '^/api/cf/search$'; Handler = 'Handle-CfSearch' }
    @{ Method = 'GET'; Pattern = '^/api/cf/categories$'; Handler = 'Handle-CfCategories' }
    @{ Method = 'POST'; Pattern = '^/api/cf/mods$'; Handler = 'Handle-CfModsPost' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)/description$'; Handler = 'Handle-CfModDescription' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)/files/(?<fileId>[^/]+)/changelog$'; Handler = 'Handle-CfModChangelog' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)/files$'; Handler = 'Handle-CfModFiles' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)$'; Handler = 'Handle-CfModGet' }
    @{ Method = 'GET'; Pattern = '^/api/cf/resolve$'; Handler = 'Handle-CfResolve' }
    @{ Method = 'GET'; Pattern = '^/api/wago/search$'; Handler = 'Handle-WagoSearch' }
    @{ Method = 'GET'; Pattern = '^/api/wago/categories$'; Handler = 'Handle-WagoCategories' }
    @{ Method = 'GET'; Pattern = '^/api/wago/resolve$'; Handler = 'Handle-WagoResolve' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)/releases$'; Handler = 'Handle-WagoAddonReleases' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)/gallery$'; Handler = 'Handle-WagoAddonGallery' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)$'; Handler = 'Handle-WagoAddonDetails' }
    @{ Method = 'POST'; Pattern = '^/api/open$'; Handler = 'Handle-Open' }
    @{ Method = 'POST'; Pattern = '^/api/shutdown$'; Handler = 'Handle-Shutdown' }
)

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
            & $matchedHandler $Context $routeMatch
        } elseif ($method -eq 'GET' -and (-not $path.StartsWith('/api/'))) {
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
$Script:SyncLogPath = Join-Path -Path $Script:Root -ChildPath 'sync.log'
$Script:CliPath = Join-Path -Path $Script:Root -ChildPath 'addon-sync.ps1'
$Script:AddonsPathOverride = $AddonsPath
$Script:IdleMinutes = $IdleMinutes
$Script:BuildInfoPathOverride = $BuildInfoPath
$Script:Version = '1.0.0'
$Script:StartTime = Get-Date
$Script:ShuttingDown = $false
$Script:LastResponseStatus = $null

$Script:Jobs = New-Object 'System.Collections.Generic.List[object]'
$Script:JobIdSeq = 0
$Script:CurrentJob = $null
$Script:CfCache = @{}
$Script:UpdateAvailable = @{}
$Script:LastRun = $null
$Script:UpdatesCheckedAt = $null
$Script:LastRequestTime = Get-Date
# E12: Wago Addons proxy state - WagoCache mirrors CfCache (5-minute
# response cache, same size-gated cleanup pattern); WagoInertiaVersion
# caches the site's Inertia asset version for the life of the process (and
# is persisted to/reloaded from state.json per SPEC's "cache the version in
# state.json" instruction, since this server, unlike the per-run CLI, stays
# up for a long time and would otherwise pay the plain-HTML handshake on
# every single Wago request).
$Script:WagoCache = @{}
$Script:WagoInertiaVersion = $null

# E13 (compatibility audit): resolved once at server startup, not re-read
# from disk on every /api/state or /api/diagnostics call - -BuildInfoPath
# overrides everything (never touches the real WoW folder when given, per
# this build's test requirement); otherwise the .build.info sitting next to
# whatever AddOns path resolves at startup. A server restart is required to
# pick up a changed patch's .build.info, which is an acceptable tradeoff for
# not hitting the filesystem on every poll (this app's own game-launch flow
# already restarts the server on every "Update & Play" desktop-shortcut run).
$Script:ClientBuildInfo = Get-ClientBuildInfo -BuildInfoPath $(
    if ($Script:BuildInfoPathOverride) { $Script:BuildInfoPathOverride }
    else { Get-DefaultBuildInfoPath -AddonsPathResolved (Resolve-EffectiveAddonsPath) }
)

# E2/Round 3: reload the last check results, last run summary, and job
# history (if any) so the "n updates" badge, the My Addons "Last run" line,
# and the rollback tooltip / job list all survive a server restart instead
# of going blank until the next check/job.
Load-CheckState

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
$prefix = "http://localhost:$Script:Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-ServerLog "FATAL: could not start listener on $prefix : $($_.Exception.Message)"
    throw
}

Write-ServerLog "Listening on $prefix"

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
                    Write-ServerLog "Idle for $($Script:IdleMinutes) minutes - shutting down"
                    break
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
