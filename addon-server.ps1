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
=====================================================================
#>

param(
    [int]$Port = 0,
    [string]$Root,
    [string]$AddonsPath,
    [int]$IdleMinutes = 20,
    [switch]$OpenBrowser
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
    <# Writes one JSON response and always closes the response stream. #>
    param(
        $Context,
        [int]$StatusCode,
        $Body
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
    }
}

# =====================================================================
# addons.json (read-only here; addon-sync.ps1 owns writes)
# =====================================================================

function Get-AddonRecords {
    <# Returns a List[object] of addon records. Missing/empty/null file -> empty list. #>
    $list = New-Object 'System.Collections.Generic.List[object]'

    if (-not (Test-Path -LiteralPath $Script:AddonsJsonPath)) {
        return $list
    }

    # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and is
    # never returned/serialized itself, so its PSPath/PSDrive/PSProvider note
    # properties never reach a JSON response (see Update-JobStatus for the
    # pattern that actually hangs Send-Json).
    $raw = Get-Content -LiteralPath $Script:AddonsJsonPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $list
    }

    $tmp = $raw | ConvertFrom-Json -ErrorAction Stop
    $parsed = @($tmp)
    foreach ($item in $parsed) {
        if ($null -ne $item) {
            $list.Add($item)
        }
    }
    return $list
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
            if (-not ($Params -and $Params.projectId)) {
                throw 'projectId is required for kind remove'
            }
            $argsList.Add('-Remove')
            $argsList.Add([string]$Params.projectId)
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

    $cliKind = $Kind
    $launchAfter = $false
    if ($Kind -eq 'launch') {
        $cliKind = 'sync'
        $launchAfter = $true
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
        updatesCheckedAt = $Script:UpdatesCheckedAt
        updateAvailable  = $Script:UpdateAvailable
        lastRun          = $Script:LastRun
        jobs             = $jobViews.ToArray()
    }
    try {
        # -InputObject (not a pipe): piping a single-property object through
        # ConvertTo-Json risks the same single-element unwrap quirk documented
        # for arrays elsewhere in this codebase, and -InputObject sidesteps it.
        $json = ConvertTo-Json -InputObject $body -Depth 12
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
            if ($r.status -eq 'Would-update' -and $r.projectId) {
                $Script:UpdateAvailable[[string]$r.projectId] = @{ fileId = $r.fileId; version = $r.version }
            }
        }
    } elseif ($action -eq 'sync' -or $action -eq 'add' -or $action -eq 'remove' -or $action -eq 'rollback') {
        # E1: a completed rollback pins the addon to the restored file, same
        # as an explicit Pin - it has no update pending against that pin
        # until the next check, so any stale "update available" entry for
        # this project needs clearing the same way Updated/Installed/Pinned
        # already do.
        foreach ($r in $rows) {
            if (($r.status -eq 'Updated' -or $r.status -eq 'Installed' -or $r.status -eq 'Pinned' -or $r.status -eq 'Rolled-back') -and $r.projectId) {
                $key = [string]$r.projectId
                if ($Script:UpdateAvailable.ContainsKey($key)) {
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
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $newText = $reader.ReadToEnd()
                    if ($newText) {
                        $lines = $newText -split "`r`n|`n"
                        foreach ($l in $lines) {
                            if ($l.Length -gt 0) { $Job.log.Add($l) }
                        }
                    }
                    # Advance the offset past what was just consumed so a repeated
                    # poll while still running does not re-read and re-append the
                    # same lines every time.
                    $Job.SyncLogOffset = $fs.Length
                }
            } finally {
                $fs.Close()
            }
        }
    } catch {
        # tolerate transient read failures while the CLI is still writing
    }

    if (-not $Job.Process.HasExited) {
        return $Job
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
                $bodyText = $sr.ReadToEnd()
                $sr.Close()
            } catch {
                $bodyText = ConvertTo-Json -InputObject @{ error = $_.Exception.Message } -Compress
            }
        } else {
            $statusCode = 502
            $bodyText = ConvertTo-Json -InputObject @{ error = $_.Exception.Message } -Compress
        }
    }

    if ($Method -eq 'GET' -and $statusCode -ge 200 -and $statusCode -lt 300) {
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
    $addonsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $records) {
        $upd = $null
        if ($null -ne $r.projectId) {
            $key = [string]$r.projectId
            if ($Script:UpdateAvailable.ContainsKey($key)) {
                $u = $Script:UpdateAvailable[$key]
                $upd = [PSCustomObject]@{ fileId = $u.fileId; version = $u.version }
            }
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
        $addonsOut.Add($clone)
    }

    $settings = Get-Settings
    $body = [PSCustomObject]@{
        addons           = $addonsOut.ToArray()
        settings         = Get-SettingsView -Settings $settings
        lastRun          = $Script:LastRun
        job              = (Get-CurrentOrLastJobSummary)
        updatesCheckedAt = $Script:UpdatesCheckedAt
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
    $validKinds = @('sync', 'check', 'add', 'remove', 'install', 'launch', 'rollback')
    if (-not ($validKinds -contains $kind)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = "bad request: unknown kind '$kind'" }
        return
    }
    if ($kind -eq 'add' -and (-not $body.projectId)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
        return
    }
    if ($kind -eq 'remove' -and (-not $body.projectId)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
        return
    }
    if ($kind -eq 'install' -and ((-not $body.projectId) -or (-not $body.fileId))) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId and fileId required' }
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
    if (-not $key -or $key.Trim().Length -eq 0) {
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $false; message = 'No API key provided' }
        return
    }

    $headers = @{ 'x-api-key' = $key; 'Accept' = 'application/json' }
    try {
        $resp = Invoke-WebRequest -Uri 'https://api.curseforge.com/v1/games/1' -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        if ([int]$resp.StatusCode -eq 200) {
            Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; message = 'Key is valid' }
        } else {
            Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $false; message = "CurseForge returned status $([int]$resp.StatusCode)" }
        }
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $false; message = 'Key rejected by CurseForge' }
        } else {
            Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $false; message = $_.Exception.Message }
        }
    }
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
                if ($body.slug) {
                    $url = "https://www.curseforge.com/wow/addons/$($body.slug)"
                } elseif ($body.projectId) {
                    $url = "https://www.curseforge.com/projects/$($body.projectId)"
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
    @{ Method = 'GET'; Pattern = '^/api/settings$'; Handler = 'Handle-SettingsGet' }
    @{ Method = 'PUT'; Pattern = '^/api/settings$'; Handler = 'Handle-SettingsPut' }
    @{ Method = 'POST'; Pattern = '^/api/settings/test-key$'; Handler = 'Handle-SettingsTestKey' }
    @{ Method = 'GET'; Pattern = '^/api/cf/search$'; Handler = 'Handle-CfSearch' }
    @{ Method = 'GET'; Pattern = '^/api/cf/categories$'; Handler = 'Handle-CfCategories' }
    @{ Method = 'POST'; Pattern = '^/api/cf/mods$'; Handler = 'Handle-CfModsPost' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)/description$'; Handler = 'Handle-CfModDescription' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)/files/(?<fileId>[^/]+)/changelog$'; Handler = 'Handle-CfModChangelog' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)/files$'; Handler = 'Handle-CfModFiles' }
    @{ Method = 'GET'; Pattern = '^/api/cf/mods/(?<id>[^/]+)$'; Handler = 'Handle-CfModGet' }
    @{ Method = 'GET'; Pattern = '^/api/cf/resolve$'; Handler = 'Handle-CfResolve' }
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
