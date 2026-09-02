<#
=====================================================================
 addon-sync.ps1

 Keeps World of Warcraft retail addons updated from CurseForge.
 Designed to run headless / hidden from a launcher before the game
 starts. Windows PowerShell 5.1 only. No modules, no external
 binaries, pure ASCII.

 LAYOUT (relative to the folder this script lives in):
   addon-sync.ps1   this script
   addons.json      config AND state (JSON array of addon records)
   staging\         scratch folder for downloads/extraction
   sync.log         append-only log
   last-run.txt     overwritten each run with the summary table

 USAGE:
   addon-sync.ps1 [-AddonsPath <path>] [-Add <id[]>] [-Remove <name-or-id[]>]
                  [-Status] [-Force] [-DryRun] [-Quiet] [-Only <id[]>]
                  [-FileId <id>] [-Unpin <id[]>] [-Ignore <id[]>]
                  [-Unignore <id[]>] [-Files <id>] [-Scan] [-Json] [-Launcher]
                  [-Rollback <id[]>]

   No switches            Sync every addon recorded in addons.json.
   -AddonsPath <path>     Interface\AddOns folder. Auto-detected when this
                           script lives in <X>\_retail_\AddonSync ; required
                           otherwise.
   -Add <id> [<id> ...]   CurseForge project id(s) to add and install now.
                           May be combined with -FileId when adding a
                           single id.
   -Remove <x> [<x> ...]  Addon name (case-insensitive) or project id to
                           uninstall and drop from addons.json.
   -Status                Print the recorded addon table and exit. No
                           network access.
   -Force                 Reinstall every synced addon even if the file id
                           on disk already matches CurseForge (pinned
                           records reinstall their pinned file, not the
                           newest).
   -DryRun                Check CurseForge and report what would change.
                           Makes no downloads and no disk writes (sync.log
                           excepted).
   -Quiet                 Suppress all console output. Used by the game
                           launcher; everything still goes to sync.log.
   -Only <id> [<id> ...]  Restrict this sync (or -Force reinstall) to these
                           CurseForge project ids.
   -FileId <id>           Requires exactly one id in -Only or -Add; installs
                           that specific file id instead of the newest and
                           pins the record to it.
   -Unpin <id> [<id> ...] Clear pinnedFileId on these records. No network.
   -Ignore <id> [<id> ...]    Set ignoreUpdates on these records. No network.
   -Unignore <id> [<id> ...]  Clear ignoreUpdates on these records. No network.
   -Files <id>             List available CurseForge files for a project.
                            No install, no config change.
   -Scan                   List top-level AddOns folders not owned by any
                            record. No config change.
   -Json                   Machine-readable mode: print exactly one JSON
                            document to stdout and nothing else.
   -Launcher                Launcher mode: reads settings.json and skips
                            the sync (exit 0, no network) when
                            autoUpdateOnLaunch is false; otherwise behaves
                            like a normal sync.
   -Rollback <id> [<id> ...]  For each project id, reinstalls from the
                            locally archived zip of the version it was on
                            before its last update (ROOT\backups\<id>\
                            <previousFileId>.zip), swaps fileId/version with
                            the previous ones, and pins the restored file so
                            it is not immediately re-updated. No network
                            access. Fails a given id when there is no
                            recorded previous version or its backup zip is
                            missing.

 EXAMPLES:
   addon-sync.ps1 -Quiet
   addon-sync.ps1 -Add 12345,67890
   addon-sync.ps1 -Remove Auctionator,12345
   addon-sync.ps1 -Status
   addon-sync.ps1 -DryRun
   addon-sync.ps1 -Only 12345 -Force -Json
   addon-sync.ps1 -Ignore 12345
   addon-sync.ps1 -Files 12345 -Json
   addon-sync.ps1 -Scan -Json
   addon-sync.ps1 -Rollback 12345 -Json

 EXIT CODES:
   0   Sync/Add/Remove/Status completed (individual addons may have failed;
       the launcher should still start the game).
   2   Unusable configuration: addons.json could not be parsed, or the
       AddOns path is missing/unresolvable.
=====================================================================
#>

param(
    [string]$AddonsPath,
    [string[]]$Add,
    [string[]]$Remove,
    [switch]$Status,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Quiet,
    [string[]]$Only,
    [int64]$FileId,
    [string[]]$Unpin,
    [string[]]$Ignore,
    [string[]]$Unignore,
    [int]$Files,
    [switch]$Scan,
    [switch]$Json,
    [switch]$Launcher,
    [string[]]$Rollback
)

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$script:CfUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

# =====================================================================
# Logging
# =====================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "$timestamp [$Level] $Message"
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never abort the run.
    }
}

# =====================================================================
# HTTP helpers
# =====================================================================

function Get-ExceptionStatusCode {
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

function Invoke-CfRequest {
    <#
      Performs one CurseForge HTTP request (JSON GET, or a file download
      when -OutFile is supplied). Retries once on HTTP 429/403 after a
      5 second wait. Always paces itself with a 300ms sleep so that
      consecutive calls (list or download) never fire back to back.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$OutFile
    )

    $headers = @{
        'Accept'  = 'application/json'
        'Referer' = 'https://www.curseforge.com/'
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
            if ($OutFile) {
                Invoke-WebRequest -Uri $Uri -Headers $headers -UserAgent $script:CfUserAgent -OutFile $OutFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                $result = $null
            } else {
                $result = Invoke-WebRequest -Uri $Uri -Headers $headers -UserAgent $script:CfUserAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            }
        } catch {
            $lastError = $_
            $statusCode = Get-ExceptionStatusCode -ErrorRecord $_
            if (($statusCode -eq 429 -or $statusCode -eq 403) -and ($attempt -lt $maxAttempts)) {
                Write-Log -Level 'WARN' -Message "HTTP $statusCode from $Uri - waiting 5 seconds and retrying"
                $shouldRetry = $true
            }
        }

        Start-Sleep -Milliseconds 300

        if (-not $lastError) {
            return $result
        }
        if (-not $shouldRetry) {
            throw $lastError
        }
        Start-Sleep -Seconds 5
    }

    if ($lastError) {
        throw $lastError
    }
    return $result
}

function Get-CfFiles {
    <#
      Returns a List[object] of file records for a CurseForge project, newest
      first. -MaxReleaseType controls whether alpha builds are requested at
      all: when it is 3 (everything, including alphas) the removeAlphas
      filter is omitted so alpha files are present in the list; otherwise
      removeAlphas=true is sent as before.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [int]$MaxReleaseType = 1
    )

    $removeAlphasPart = '&removeAlphas=true'
    if ($MaxReleaseType -ge 3) {
        $removeAlphasPart = ''
    }
    $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files?pageIndex=0&pageSize=20&sort=dateCreated&sortDescending=true" + $removeAlphasPart
    $response = Invoke-CfRequest -Uri $uri
    if (-not $response) {
        throw "Empty response listing files for project $ProjectId"
    }

    $json = $response.Content | ConvertFrom-Json
    $data = New-Object 'System.Collections.Generic.List[object]'
    if ($json -and $json.data) {
        foreach ($f in $json.data) {
            $data.Add($f)
        }
    }
    Write-Output -NoEnumerate $data
}

function Test-FileHasTypeId {
    param($File, [int]$TypeId)

    if (-not $File.gameVersionTypeIds) {
        return $false
    }
    foreach ($t in $File.gameVersionTypeIds) {
        if ([int64]$t -eq [int64]$TypeId) {
            return $true
        }
    }
    return $false
}

function Test-FileHasGameVersion12 {
    param($File)

    if (-not $File.gameVersions) {
        return $false
    }
    foreach ($g in $File.gameVersions) {
        if ($g -and $g.ToString().StartsWith('12.')) {
            return $true
        }
    }
    return $false
}

function Select-CfFile {
    <#
      Picks the best file from a CurseForge file list:
        1. Retail (517) with releaseType <= MaxReleaseType (the allowed
           channel ceiling: 1 release only, 2 release+beta, 3 everything)
        2. Retail (517), any release type
        3. Any file whose gameVersions has an entry starting with "12."
        4. $null if nothing matches
    #>
    param(
        [Parameter(Mandatory = $true)]$Files,
        [int]$MaxReleaseType = 1
    )

    foreach ($f in $Files) {
        if ((Test-FileHasTypeId -File $f -TypeId 517) -and ($f.releaseType -le $MaxReleaseType)) {
            return $f
        }
    }
    foreach ($f in $Files) {
        if (Test-FileHasTypeId -File $f -TypeId 517) {
            return $f
        }
    }
    foreach ($f in $Files) {
        if (Test-FileHasGameVersion12 -File $f) {
            return $f
        }
    }
    return $null
}

function Get-CfFileById {
    <#
      Fetches a single file record for a project via the endpoint that is
      already scoped to that project id, so a fileId that does not belong
      to the project naturally 404s (caller treats any failure as Failed).
      Returns $null if the response has no data.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)][int64]$FileId
    )

    $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files/$FileId"
    $response = Invoke-CfRequest -Uri $uri
    if (-not $response) {
        return $null
    }

    $json = $response.Content | ConvertFrom-Json
    if (-not $json -or -not $json.data) {
        return $null
    }
    return $json.data
}

function Get-DownloadedZip {
    <# Downloads and verifies the selected file into staging; returns the zip path. #>
    param(
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)]$SelectedFile,
        [Parameter(Mandatory = $true)][string]$StagingPath
    )

    $fileId = [int64]$SelectedFile.id
    $zipPath = Join-Path -Path $StagingPath -ChildPath ("{0}-{1}.zip" -f $ProjectId, $fileId)
    $downloadUri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files/$fileId/download"

    Invoke-CfRequest -Uri $downloadUri -OutFile $zipPath | Out-Null

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "Download did not produce a file for project $ProjectId file $fileId"
    }

    $downloadedItem = Get-Item -LiteralPath $zipPath
    if ($downloadedItem.Length -le 0) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Downloaded file is zero-length for project $ProjectId file $fileId"
    }

    if ($SelectedFile.fileLength) {
        $expectedLength = [int64]$SelectedFile.fileLength
        if (($expectedLength -gt 0) -and ($downloadedItem.Length -ne $expectedLength)) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded file size mismatch for project $ProjectId file $fileId (expected $expectedLength, got $($downloadedItem.Length))"
        }
    }

    return $zipPath
}

# =====================================================================
# Install / extraction
# =====================================================================

function Install-AddonPackage {
    <#
      Extracts a downloaded zip, validates it, swaps its top-level folders
      into the AddOns directory, and removes folders that belonged to the
      previous version of this addon but are not part of the new package.
      Returns a List[object] of the folder names actually present in
      AddOns afterwards.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        $PreviousFolders
    )

    $extractDir = Join-Path -Path $StagingPath -ChildPath ([string]$ProjectId)
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extractDir)
    } catch {
        Write-Log -Level 'WARN' -Message "ZipFile.ExtractToDirectory failed for project $ProjectId, falling back to Expand-Archive: $($_.Exception.Message)"
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force
    }

    $topEntries = Get-ChildItem -LiteralPath $extractDir -Force
    $candidateFolders = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $topEntries) {
        if ($entry.PSIsContainer) {
            $tocFiles = Get-ChildItem -LiteralPath $entry.FullName -Filter '*.toc' -File -ErrorAction SilentlyContinue
            $hasToc = $false
            foreach ($t in $tocFiles) {
                $hasToc = $true
            }
            if ($hasToc) {
                $candidateFolders.Add($entry.Name)
            } else {
                Write-Log -Level 'WARN' -Message "Top-level folder '$($entry.Name)' has no .toc file, skipping (project $ProjectId)"
            }
        } else {
            Write-Log -Level 'WARN' -Message "Ignoring top-level file '$($entry.Name)' in package for project $ProjectId"
        }
    }

    if ($candidateFolders.Count -eq 0) {
        throw "No valid addon folders (with a .toc file) found in package for project $ProjectId"
    }

    $installedFolders = New-Object 'System.Collections.Generic.List[object]'
    foreach ($folderName in $candidateFolders) {
        $sourcePath = Join-Path -Path $extractDir -ChildPath $folderName
        $destPath = Join-Path -Path $AddonsPath -ChildPath $folderName
        try {
            if (Test-Path -LiteralPath $destPath) {
                Remove-Item -LiteralPath $destPath -Recurse -Force
            }
            Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
        } catch {
            Write-Log -Level 'ERROR' -Message "Failed to install folder '$folderName' for project $ProjectId : $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $destPath) {
            $installedFolders.Add($folderName)
        }
    }

    foreach ($oldFolder in $PreviousFolders) {
        if (-not $installedFolders.Contains($oldFolder)) {
            $oldPath = Join-Path -Path $AddonsPath -ChildPath $oldFolder
            if (Test-Path -LiteralPath $oldPath) {
                try {
                    Remove-Item -LiteralPath $oldPath -Recurse -Force
                    Write-Log -Level 'INFO' -Message "Removed stale folder '$oldFolder' no longer part of project $ProjectId"
                } catch {
                    Write-Log -Level 'WARN' -Message "Failed to remove stale folder '$oldFolder' for project $ProjectId : $($_.Exception.Message)"
                }
            }
        }
    }

    Write-Output -NoEnumerate $installedFolders
}

function Get-TocTitle {
    <#
      Reads the "## Title:" line from the primary .toc of a freshly
      installed addon (the folder whose .toc basename equals the folder
      name; when several qualify, the one with no underscore in its name
      wins). Strips WoW color codes. Returns $null if no title is found.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)]$Folders
    )

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($folderName in $Folders) {
        $tocPath = Join-Path -Path (Join-Path -Path $AddonsPath -ChildPath $folderName) -ChildPath ("$folderName.toc")
        if (Test-Path -LiteralPath $tocPath) {
            $candidates.Add($folderName)
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $chosen = $null
    foreach ($c in $candidates) {
        if ($c -notmatch '_') {
            $chosen = $c
            break
        }
    }
    if (-not $chosen) {
        $chosen = $candidates[0]
    }

    $tocPath = Join-Path -Path (Join-Path -Path $AddonsPath -ChildPath $chosen) -ChildPath ("$chosen.toc")
    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $tocPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $null
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*##\s*Title\s*:\s*(.*)$') {
            $title = $Matches[1]
            $title = $title -replace '\|c[0-9A-Fa-f]{8}', ''
            $title = $title -replace '\|r', ''
            $title = $title.Trim()
            if ($title.Length -gt 0) {
                return $title
            }
        }
    }
    return $null
}

function Get-FolderTocInfo {
    <#
      Reads title/version from the primary .toc in a single top-level
      AddOns folder (used by -Scan, where each folder is examined on its
      own rather than as a group belonging to one known addon). Prefers a
      .toc whose basename matches the folder name; falls back to the first
      .toc found. Never throws; returns hasToc=$false when there is none.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath
    )

    $result = [PSCustomObject]@{ title = $null; version = $null; hasToc = $false }

    $folderLeaf = Split-Path -Path $FolderPath -Leaf
    $tocFiles = Get-ChildItem -LiteralPath $FolderPath -Filter '*.toc' -File -ErrorAction SilentlyContinue

    $chosen = $null
    foreach ($t in $tocFiles) {
        if ($t.BaseName -eq $folderLeaf) {
            $chosen = $t
            break
        }
    }
    if (-not $chosen) {
        foreach ($t in $tocFiles) {
            $chosen = $t
            break
        }
    }
    if (-not $chosen) {
        return $result
    }
    $result.hasToc = $true

    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $chosen.FullName -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $result
    }

    foreach ($line in $lines) {
        if ((-not $result.title) -and ($line -match '^\s*##\s*Title\s*:\s*(.*)$')) {
            $t = $Matches[1]
            $t = $t -replace '\|c[0-9A-Fa-f]{8}', ''
            $t = $t -replace '\|r', ''
            $t = $t.Trim()
            if ($t.Length -gt 0) {
                $result.title = $t
            }
        }
        if ((-not $result.version) -and ($line -match '^\s*##\s*Version\s*:\s*(.*)$')) {
            $v = $Matches[1].Trim()
            if ($v.Length -gt 0) {
                $result.version = $v
            }
        }
    }
    return $result
}

function Get-VersionFromDisplayName {
    param([string]$DisplayName)

    if (-not $DisplayName) {
        return $DisplayName
    }
    return ($DisplayName -replace '\.zip$', '')
}

# =====================================================================
# Rollback / version history (E1)
# =====================================================================

function Save-BackupZip {
    <#
      Archives a just-installed zip into ROOT\backups\<ProjectId>\<FileId>.zip
      (MOVED out of staging, not copied - staging is wiped at the end of
      every run) so -Rollback always has the exact package that produced a
      given fileId to reinstall from, with no re-download. Prunes that
      project's backup folder down to at most the two zips that matter - the
      file just archived and, when known, the one it replaced
      (Record.previousFileId) - so disk usage never grows unbounded and a
      rollback followed by a normal sync never loses either zip. Best-effort
      throughout: archiving must never fail an otherwise-successful install,
      so every failure is logged and swallowed.

      Round 3 note: an earlier version of this function also wrote a
      "<FileId>.filename.txt" sidecar next to the zip so Invoke-RollbackForRecord
      could recover the original fileName to restore (the record's own
      previousFileId/previousVersion fields covered fileId/version, but not
      fileName). That sidecar is no longer needed or written: the record now
      carries previousFileName the same way, set by Sync-SingleAddon
      alongside previousFileId/previousVersion, so a rollback can swap
      fileName<->previousFileName directly with no out-of-band lookup and no
      risk of a missing/pre-fix sidecar leaving it stale.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)][int64]$FileId,
        [Parameter(Mandatory = $true)][string]$BackupsRoot,
        $PreviousFileId
    )

    try {
        $projectDir = Join-Path -Path $BackupsRoot -ChildPath ([string]$ProjectId)
        if (-not (Test-Path -LiteralPath $projectDir)) {
            New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
        }

        $destName = "{0}.zip" -f $FileId
        $destPath = Join-Path -Path $projectDir -ChildPath $destName
        if (Test-Path -LiteralPath $destPath) {
            Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $ZipPath -Destination $destPath -Force

        $keepIds = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$keepIds.Add([string]$FileId)
        if ($PreviousFileId) {
            [void]$keepIds.Add([string][int64]$PreviousFileId)
        }

        $existingZips = Get-ChildItem -LiteralPath $projectDir -Filter '*.zip' -File -ErrorAction SilentlyContinue
        foreach ($existingZip in $existingZips) {
            if (-not $keepIds.Contains($existingZip.BaseName)) {
                try {
                    Remove-Item -LiteralPath $existingZip.FullName -Force -ErrorAction SilentlyContinue
                } catch {
                }
            }
        }
    } catch {
        Write-Log -Level 'WARN' -Message "Failed to archive backup zip for project $ProjectId fileId $FileId : $($_.Exception.Message)"
    }
}

function Invoke-RollbackForRecord {
    <#
      Reinstalls one addon record from the locally archived zip of the
      version it was on before its last update (no network access at all).
      On success, swaps fileId/version/fileName with
      previousFileId/previousVersion/previousFileName (so the record now
      points at the restored file, and the file it was just rolled back FROM
      becomes the new "previous" - a second rollback undoes the first), and
      pins the restored fileId so a following plain sync does not
      immediately update it away again. Never throws; every failure is
      logged and reported as a Failed row instead.

      -DryRun makes no disk writes at all (matching the rest of this
      script's DryRun contract): it only validates that a previous version
      is on record and its backup zip exists, reporting Would-update.
    #>
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][string]$BackupsRoot,
        [switch]$DryRun
    )

    $projectId = [int]$Record.projectId
    $displayLabel = $Record.name
    if (-not $displayLabel) {
        $displayLabel = "project $projectId"
    }

    if (-not $Record.previousFileId) {
        Write-Log -Level 'WARN' -Message "Rollback: project $projectId ($displayLabel) has no previous version on record"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    $prevFileId = [int64]$Record.previousFileId
    $zipPath = Join-Path -Path (Join-Path -Path $BackupsRoot -ChildPath ([string]$projectId)) -ChildPath ("{0}.zip" -f $prevFileId)
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Log -Level 'WARN' -Message "Rollback: backup zip missing for project $projectId ($displayLabel) fileId $prevFileId"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    if ($DryRun) {
        Write-Log -Level 'INFO' -Message "DryRun: would roll back project $projectId ($displayLabel) to fileId $prevFileId"
        return [PSCustomObject]@{ Status = 'Would-update'; Name = $displayLabel; Version = $Record.previousVersion; FileId = $prevFileId }
    }

    try {
        $newFolders = Install-AddonPackage -ZipPath $zipPath -ProjectId $projectId -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders
    } catch {
        Write-Log -Level 'ERROR' -Message "Rollback failed installing backup for project $projectId ($displayLabel) : $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    if ($newFolders.Count -eq 0) {
        Write-Log -Level 'ERROR' -Message "Rollback produced zero usable folders for project $projectId ($displayLabel)"
        # Install-AddonPackage already ran stale cleanup against the previous
        # folders, so the disk no longer has them even though the swap itself
        # failed. Reflect that on the record, same as a failed normal install.
        $Record.folders = $newFolders.ToArray()
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    $replacedFileId = $Record.fileId
    $replacedVersion = $Record.version
    $replacedFileName = $Record.fileName

    # Round 3 fix: Record.fileName must name the file actually restored, not
    # the one just replaced. previousFileName is set by Sync-SingleAddon
    # right alongside previousFileId/previousVersion (immediately before an
    # update overwrites fileId/version/fileName), so it swaps here the exact
    # same way those two already do - no out-of-band lookup needed (this
    # replaces Round 2's backup-folder ".filename.txt" sidecar approach,
    # which could go missing or predate the fix; a plain record field
    # cannot). A record that predates previousFileName entirely (backfilled
    # to $null by Initialize-AddonRecordFields, e.g. one that was only ever
    # updated before this fix shipped) degrades to leaving fileName exactly
    # as it was before this rollback rather than guessing.
    $restoredFileName = $Record.previousFileName
    if (-not $restoredFileName) {
        $restoredFileName = $replacedFileName
    }

    $Record.fileId = $prevFileId
    $Record.version = $Record.previousVersion
    $Record.fileName = $restoredFileName
    $Record.previousFileId = $replacedFileId
    $Record.previousVersion = $replacedVersion
    $Record.previousFileName = $replacedFileName
    $Record.pinnedFileId = $prevFileId
    $Record.folders = $newFolders.ToArray()

    # E3 (dependencies): the restored package's folders may declare a
    # different dependency list than the version just rolled back from, so
    # re-parse rather than leaving the previous version's deps in place.
    $rollbackDeps = Get-PackageDependencies -AddonsPath $AddonsPath -Folders $newFolders
    $Record.requiredDeps = $rollbackDeps.required
    $Record.optionalDeps = $rollbackDeps.optional

    Write-Log -Level 'INFO' -Message "Rolled back project $projectId ($displayLabel) to fileId $prevFileId"
    return [PSCustomObject]@{ Status = 'Rolled-back'; Name = $displayLabel; Version = $Record.version }
}

# =====================================================================
# Dependencies (E3)
# =====================================================================

function Split-TocDepList {
    <#
      Splits one "## Dependencies:"-style tag value into individual addon/
      folder names. Values are documented as comma- OR space-separated;
      commas win whenever the line has any (the conventional WoW toc style,
      "LibStub, CallbackHandler-1.0"), since a space-separated name never
      itself contains a comma. Blank pieces (double commas, trailing
      whitespace) are dropped. Tolerates $null/empty input.
    #>
    param([string]$Value)

    $result = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Value) {
        Write-Output -NoEnumerate $result
        return
    }

    $pieces = $null
    if ($Value.IndexOf(',') -ge 0) {
        $pieces = $Value -split ','
    } else {
        $pieces = $Value -split '\s+'
    }
    foreach ($piece in $pieces) {
        $trimmed = $piece.Trim()
        if ($trimmed.Length -gt 0) {
            $result.Add($trimmed)
        }
    }
    Write-Output -NoEnumerate $result
}

function Get-TocDependencies {
    <#
      Reads dependency tags from one installed folder's primary .toc (same
      "basename matches the folder name, else first .toc found" rule as
      Get-FolderTocInfo/Get-TocTitle). "## Dependencies:" and
      "## RequiredDeps:" are treated as synonyms for the required list (both
      are used in the wild for the same purpose); "## OptionalDeps:" feeds
      the optional list. Tag names are matched case-insensitively (-match's
      default). Never throws; returns two empty lists when the folder has no
      .toc, the .toc can't be read, or no matching tag is present.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$FolderName
    )

    $result = [PSCustomObject]@{
        required = New-Object 'System.Collections.Generic.List[object]'
        optional = New-Object 'System.Collections.Generic.List[object]'
    }

    $folderPath = Join-Path -Path $AddonsPath -ChildPath $FolderName
    if (-not (Test-Path -LiteralPath $folderPath)) {
        return $result
    }

    $tocFiles = Get-ChildItem -LiteralPath $folderPath -Filter '*.toc' -File -ErrorAction SilentlyContinue
    $chosen = $null
    foreach ($t in $tocFiles) {
        if ($t.BaseName -eq $FolderName) {
            $chosen = $t
            break
        }
    }
    if (-not $chosen) {
        foreach ($t in $tocFiles) {
            $chosen = $t
            break
        }
    }
    if (-not $chosen) {
        return $result
    }

    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $chosen.FullName -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $result
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*##\s*(Dependencies|RequiredDeps)\s*:\s*(.*)$') {
            foreach ($name in (Split-TocDepList -Value $Matches[2])) { $result.required.Add($name) }
        } elseif ($line -match '^\s*##\s*OptionalDeps\s*:\s*(.*)$') {
            foreach ($name in (Split-TocDepList -Value $Matches[1])) { $result.optional.Add($name) }
        }
    }

    return $result
}

function Get-PackageDependencies {
    <#
      Unions required/optional dependency names across every folder of a
      freshly installed/updated package (each folder carries its own
      primary .toc, and any of them may declare deps), excludes any name
      that matches one of the package's OWN folders case-insensitively (a
      dependency on a folder the same package already provides is not an
      external dependency), and deduplicates case-insensitively (first-seen
      casing wins). Returns a PSCustomObject { required; optional } of plain
      string arrays, ready to store on the record via -Depth-safe
      ConvertTo-Json.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)]$Folders
    )

    $ownFolders = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in $Folders) {
        if ($f) { [void]$ownFolders.Add(([string]$f).ToLowerInvariant()) }
    }

    $requiredSeen = New-Object 'System.Collections.Generic.HashSet[string]'
    $optionalSeen = New-Object 'System.Collections.Generic.HashSet[string]'
    $required = New-Object 'System.Collections.Generic.List[object]'
    $optional = New-Object 'System.Collections.Generic.List[object]'

    foreach ($folderName in $Folders) {
        $deps = Get-TocDependencies -AddonsPath $AddonsPath -FolderName $folderName
        foreach ($name in $deps.required) {
            $key = $name.ToLowerInvariant()
            if ($ownFolders.Contains($key) -or $requiredSeen.Contains($key)) { continue }
            [void]$requiredSeen.Add($key)
            $required.Add($name)
        }
        foreach ($name in $deps.optional) {
            $key = $name.ToLowerInvariant()
            if ($ownFolders.Contains($key) -or $optionalSeen.Contains($key)) { continue }
            [void]$optionalSeen.Add($key)
            $optional.Add($name)
        }
    }

    return [PSCustomObject]@{ required = $required.ToArray(); optional = $optional.ToArray() }
}

function Get-AddonsFolderSet {
    <#
      Case-insensitive set of every top-level AddOns folder name currently on
      disk (lowercased), used to compute missingDeps/missingOptionalDeps
      live rather than storing them - a dependency that gets added or
      removed later is reflected immediately without needing a resync.
      Returns an empty set (never throws) when Path can't be resolved or
      doesn't exist. Uses -NoEnumerate: a HashSet is IEnumerable, so a bare
      "return $set" on an EMPTY set would enumerate to zero pipeline objects
      and the caller's assignment would silently receive $null instead of
      the set itself (the same class of hazard the List[object] quirk
      documents, generalized to any enumerable collection type).
    #>
    param([string]$Path)

    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $dirs = Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) { [void]$set.Add($d.Name.ToLowerInvariant()) }
    }
    Write-Output -NoEnumerate $set
}

function Get-MissingDeps {
    <# Entries of $DepNames not present (case-insensitively) in $PresentFolders. #>
    param(
        $DepNames,
        [Parameter(Mandatory = $true)]$PresentFolders
    )

    $missing = New-Object 'System.Collections.Generic.List[object]'
    foreach ($dep in $DepNames) {
        if (-not $dep) { continue }
        if (-not $PresentFolders.Contains(([string]$dep).ToLowerInvariant())) {
            $missing.Add($dep)
        }
    }
    Write-Output -NoEnumerate $missing
}

# =====================================================================
# Config (addons.json) persistence
# =====================================================================

function Read-Config {
    <# Returns a List[object] of addon records. Missing/empty/null file -> empty list. #>
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $list = New-Object 'System.Collections.Generic.List[object]'

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Output -NoEnumerate $list
        return
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Output -NoEnumerate $list
        return
    }

    $tmp = $raw | ConvertFrom-Json -ErrorAction Stop
    $parsed = @($tmp)
    if ($null -ne $parsed) {
        foreach ($item in $parsed) {
            if ($null -ne $item) {
                $list.Add($item)
            }
        }
    }

    Write-Output -NoEnumerate $list
}

function Save-Config {
    <# Serializes addon records (a List[object]) to addons.json atomically. #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Items
    )

    $json = ConvertTo-Json -InputObject $Items -Depth 10
    if (-not $json) {
        $json = '[]'
    }

    $tmpPath = "$Path.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
}

function New-AddonRecord {
    param(
        [Parameter(Mandatory = $true)][int]$ProjectId
    )

    return [PSCustomObject]@{
        name          = $null
        projectId     = $ProjectId
        fileId        = $null
        version       = $null
        fileName      = $null
        installedAt   = $null
        folders       = @()
        author            = $null
        ignoreUpdates     = $false
        pinnedFileId      = $null
        releaseType       = $null
        previousFileId    = $null
        previousVersion   = $null
        previousFileName  = $null
        requiredDeps      = @()
        optionalDeps      = @()
    }
}

function Initialize-AddonRecordFields {
    <#
      Ensures a record (possibly loaded from an older addons.json that
      predates author/ignoreUpdates/pinnedFileId/releaseType/previousFileId/
      previousVersion/previousFileName/requiredDeps/optionalDeps) has all
      nine new properties present, adding whichever are missing with their
      null/false/empty-array default and leaving any existing value
      untouched. PSCustomObject dot-assignment throws on a property that
      does not already exist, so every record must be normalized before any
      code path tries to set these fields.
    #>
    param(
        [Parameter(Mandatory = $true)]$Record
    )

    if (-not (Get-Member -InputObject $Record -Name 'author' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'author' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'ignoreUpdates' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'ignoreUpdates' -NotePropertyValue $false
    }
    if (-not (Get-Member -InputObject $Record -Name 'pinnedFileId' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'pinnedFileId' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'releaseType' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'releaseType' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'previousFileId' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'previousFileId' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'previousVersion' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'previousVersion' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'previousFileName' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'previousFileName' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'requiredDeps' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'requiredDeps' -NotePropertyValue @()
    }
    if (-not (Get-Member -InputObject $Record -Name 'optionalDeps' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'optionalDeps' -NotePropertyValue @()
    }
}

# =====================================================================
# settings.json persistence
# =====================================================================

function Get-Settings {
    <#
      Reads ROOT\settings.json, tolerating a missing or unreadable file by
      falling back to (and, when missing, writing out) the documented
      defaults. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $defaults = [PSCustomObject]@{
        releaseType        = 1
        autoUpdateOnLaunch = $true
        cfApiKey           = ''
        port               = 47831
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            $json = ConvertTo-Json -InputObject $defaults -Depth 5
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, $json, $encoding)
        } catch {
            Write-Log -Level 'WARN' -Message "Failed to create settings.json: $($_.Exception.Message)"
        }
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $defaults
        }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

        $result = [PSCustomObject]@{
            releaseType        = $defaults.releaseType
            autoUpdateOnLaunch = $defaults.autoUpdateOnLaunch
            cfApiKey           = $defaults.cfApiKey
            port               = $defaults.port
        }
        if ($null -ne $parsed.releaseType) {
            $result.releaseType = [int]$parsed.releaseType
        }
        if ($null -ne $parsed.autoUpdateOnLaunch) {
            $result.autoUpdateOnLaunch = [bool]$parsed.autoUpdateOnLaunch
        }
        if ($null -ne $parsed.cfApiKey) {
            $result.cfApiKey = [string]$parsed.cfApiKey
        }
        if ($null -ne $parsed.port) {
            $result.port = [int]$parsed.port
        }
        return $result
    } catch {
        Write-Log -Level 'WARN' -Message "Failed to read settings.json, using defaults: $($_.Exception.Message)"
        return $defaults
    }
}

function Get-EffectiveMaxReleaseType {
    <# Per-record releaseType overrides the settings default when set. #>
    param(
        $Record,
        [Parameter(Mandatory = $true)][int]$DefaultMax
    )

    if ($Record -and ($null -ne $Record.releaseType) -and ("$($Record.releaseType)".Length -gt 0)) {
        try {
            return [int]$Record.releaseType
        } catch {
            return $DefaultMax
        }
    }
    return $DefaultMax
}

# =====================================================================
# Path resolution
# =====================================================================

function Resolve-AddonsPath {
    <#
      Returns the effective AddOns path. If -Provided is set it wins.
      Otherwise, if ScriptRoot looks like <X>\_retail_\AddonSync, returns
      <X>\_retail_\Interface\AddOns. Otherwise returns $null (caller must
      treat that as a fatal configuration error).
    #>
    param(
        [string]$Provided,
        [string]$ScriptRoot
    )

    if ($Provided -and ($Provided.Trim().Length -gt 0)) {
        return $Provided
    }

    $leaf = Split-Path -Path $ScriptRoot -Leaf
    $parentDir = Split-Path -Path $ScriptRoot -Parent
    if (($leaf -eq 'AddonSync') -and $parentDir) {
        $parentLeaf = Split-Path -Path $parentDir -Leaf
        if ($parentLeaf -eq '_retail_') {
            return Join-Path -Path $parentDir -ChildPath 'Interface\AddOns'
        }
    }

    return $null
}

# =====================================================================
# Per-addon sync / remove
# =====================================================================

function Sync-SingleAddon {
    <#
      Processes exactly one addon record: checks CurseForge, installs or
      updates when needed, and mutates $Record in place on success. Never
      throws; every failure is logged and reported as a row instead.

      -FileIdOverride (from -FileId, resolved by the caller to the single
      targeted project) pins the record to that exact file id. Absent an
      override, a record with pinnedFileId already set stays pinned to
      that id instead of following the channel-based newest selection.
      -ExplicitTarget means this record was named directly via -Only or
      -Add this run, which (together with -Force) overrides ignoreUpdates.
    #>
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][string]$BackupsPath,
        [switch]$Force,
        [switch]$DryRun,
        [int]$DefaultMaxReleaseType = 1,
        $FileIdOverride = $null,
        [switch]$ExplicitTarget
    )

    $projectId = [int]$Record.projectId
    $displayLabel = $Record.name
    if (-not $displayLabel) {
        $displayLabel = "project $projectId"
    }

    try {
        if ($Record.ignoreUpdates -and (-not $Force) -and (-not $ExplicitTarget)) {
            Write-Log -Level 'INFO' -Message "Ignored: project $projectId ($displayLabel) has ignoreUpdates set"
            return [PSCustomObject]@{ Status = 'Ignored'; Name = $displayLabel; Version = $Record.version }
        }

        $currentFileId = $null
        if ($Record.fileId) {
            $currentFileId = [int64]$Record.fileId
        }

        $pinTarget = $null
        if ($FileIdOverride) {
            $pinTarget = [int64]$FileIdOverride
        } elseif ($Record.pinnedFileId) {
            $pinTarget = [int64]$Record.pinnedFileId
        }

        $selected = $null
        $usingPin = $false

        if ($pinTarget) {
            $usingPin = $true
            if ((-not $Force) -and $currentFileId -and ($currentFileId -eq $pinTarget)) {
                # Persist the pin even on this no-op-install shortcut: a
                # -FileId request whose target already matches what is on
                # disk must still record pinnedFileId so future syncs keep
                # honoring the pin (this is a config write, not a network
                # action or download, so it is safe here for a real run).
                # Gated on -not $DryRun: the main loop always includes
                # $config (this same $Record) verbatim as the -Json output's
                # "addons" array regardless of DryRun, so mutating the
                # in-memory record here would misreport a pin as persisted
                # in that JSON even though DryRun's Save-Config never runs to
                # actually write it to addons.json (see CHANGELOG Round 4).
                if (-not $DryRun) {
                    $Record.pinnedFileId = $pinTarget
                }
                Write-Log -Level 'INFO' -Message "Pinned: project $projectId ($displayLabel) already on fileId $pinTarget"
                return [PSCustomObject]@{ Status = 'Pinned'; Name = $displayLabel; Version = $Record.version }
            }
            $selected = Get-CfFileById -ProjectId $projectId -FileId $pinTarget
            if (-not $selected) {
                Write-Log -Level 'WARN' -Message "File id $pinTarget not found for project $projectId ($displayLabel)"
                return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
            }
        } else {
            $maxReleaseType = Get-EffectiveMaxReleaseType -Record $Record -DefaultMax $DefaultMaxReleaseType
            $files = Get-CfFiles -ProjectId $projectId -MaxReleaseType $maxReleaseType
            $selected = Select-CfFile -Files $files -MaxReleaseType $maxReleaseType

            if (-not $selected) {
                Write-Log -Level 'WARN' -Message "No retail file found for project $projectId ($displayLabel)"
                return [PSCustomObject]@{ Status = 'Skipped'; Name = $displayLabel; Version = $Record.version }
            }
        }

        $selectedFileId = [int64]$selected.id

        $needsInstall = $false
        if ($Force) {
            $needsInstall = $true
        } elseif (-not $currentFileId) {
            $needsInstall = $true
        } elseif ($selectedFileId -ne $currentFileId) {
            $needsInstall = $true
        }

        if (-not $needsInstall) {
            # Metadata-only author backfill: records saved before the author
            # field existed have $Record.author = $null even though they are
            # already on the correct file. $selected here is guaranteed to be
            # the file matching the installed fileId (that equality is exactly
            # what made $needsInstall false), so this is safe to backfill from
            # without any extra network call. DryRun must stay fully read-only,
            # so this mutation (and the Save-Config it depends on downstream)
            # only happens for a real run.
            if ((-not $DryRun) -and (-not $Record.author) -and $selected.user -and $selected.user.username) {
                $Record.author = $selected.user.username
                Write-Log -Level 'INFO' -Message "Backfilled author for project $projectId ($displayLabel): $($Record.author)"
            }
            Write-Log -Level 'INFO' -Message "Up-to-date: project $projectId ($displayLabel) fileId $currentFileId"
            return [PSCustomObject]@{ Status = 'Up-to-date'; Name = $displayLabel; Version = $Record.version }
        }

        $isNewInstall = (-not $currentFileId)
        $versionText = Get-VersionFromDisplayName -DisplayName $selected.displayName

        if ($DryRun) {
            Write-Log -Level 'INFO' -Message "DryRun: would update project $projectId ($displayLabel) to fileId $selectedFileId"
            $dryRunStatus = 'Would-update'
            # FileId here must be the newly SELECTED file (the one Version
            # above was derived from), not $Record.fileId -- DryRun never
            # mutates $Record, so the caller cannot get this value from the
            # record itself. Omitting/mismatching this field would pair a
            # NEW version string with the OLD installed fileId in every
            # Would-update row (see CHANGELOG Round 1).
            return [PSCustomObject]@{ Status = $dryRunStatus; Name = $displayLabel; Version = $versionText; FileId = $selectedFileId }
        }

        $zipPath = Get-DownloadedZip -ProjectId $projectId -SelectedFile $selected -StagingPath $StagingPath

        $newFolders = Install-AddonPackage -ZipPath $zipPath -ProjectId $projectId -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders

        if ($newFolders.Count -eq 0) {
            Write-Log -Level 'ERROR' -Message "Install produced zero usable folders for project $projectId ($displayLabel)"
            # Install-AddonPackage already ran stale cleanup against the previous
            # record's folders, so the disk no longer has them even though the
            # swap itself failed. Reflect that on the record.
            $Record.folders = $newFolders.ToArray()
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
        }

        $title = Get-TocTitle -AddonsPath $AddonsPath -Folders $newFolders
        $finalName = $Record.name
        if ($title) {
            $finalName = $title
        } elseif (-not $finalName) {
            $finalName = [System.IO.Path]::GetFileNameWithoutExtension($selected.fileName)
        }

        $authorName = $null
        if ($selected.user -and $selected.user.username) {
            $authorName = $selected.user.username
        }

        # E1 (rollback): before overwriting fileId/version/fileName, remember
        # what they were so -Rollback can restore this exact file/version
        # later. Only set on an actual UPDATE (isNewInstall false, so
        # $currentFileId/$Record.version/$Record.fileName already describe
        # something real that is about to be replaced) - a fresh install has
        # no "previous" to record. previousFileName is written the same way
        # as previousFileId/previousVersion (a plain addons.json field) so a
        # rollback can restore fileName exactly by swapping it back, rather
        # than needing any out-of-band lookup (Round 2's now-superseded
        # backup-folder sidecar file approach - see Invoke-RollbackForRecord).
        if (-not $isNewInstall) {
            $Record.previousFileId = $currentFileId
            $Record.previousVersion = $Record.version
            $Record.previousFileName = $Record.fileName
        }

        $Record.name = $finalName
        $Record.fileId = $selectedFileId
        $Record.version = $versionText
        $Record.fileName = $selected.fileName
        $Record.installedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Record.folders = $newFolders.ToArray()
        $Record.author = $authorName
        if ($pinTarget) {
            $Record.pinnedFileId = $pinTarget
        }

        # E3 (dependencies): re-parse every installed folder's own .toc for
        # Dependencies/RequiredDeps/OptionalDeps now that the new package is
        # on disk. Always recomputed from scratch (not merged with whatever
        # was there before) since a new version's dependency list replaces
        # the old one outright.
        $deps = Get-PackageDependencies -AddonsPath $AddonsPath -Folders $newFolders
        $Record.requiredDeps = $deps.required
        $Record.optionalDeps = $deps.optional

        # E1 (rollback): archive the zip just installed so a later -Rollback
        # can reinstall it without any network access. $Record.previousFileId
        # (just set above, or still whatever an earlier update left it as on
        # a fresh install) tells the pruning step which older zip, if any, to
        # keep alongside this new one.
        Save-BackupZip -ZipPath $zipPath -ProjectId $projectId -FileId $selectedFileId -BackupsRoot $BackupsPath -PreviousFileId $Record.previousFileId

        $folderSummary = $newFolders -join ', '
        Write-Log -Level 'INFO' -Message "Installed project $projectId ($finalName) fileId $selectedFileId folders: $folderSummary"

        $statusText = 'Updated'
        if ($usingPin -and (-not $isNewInstall)) {
            $statusText = 'Updated'
        } elseif ($isNewInstall) {
            $statusText = 'Installed'
        }

        return [PSCustomObject]@{ Status = $statusText; Name = $finalName; Version = $versionText }

    } catch {
        Write-Log -Level 'ERROR' -Message "Failed processing project $projectId ($displayLabel) : $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }
}

function Remove-AddonByTarget {
    <#
      Finds a record in $Config by name (case-insensitive) or project id,
      deletes its recorded folders from AddOns, and reports the outcome.
      Does not mutate $Config itself; the caller removes the returned
      Record from the list.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [switch]$DryRun
    )

    $targetIdValue = 0
    $isNumeric = [int]::TryParse($Target, [ref]$targetIdValue)
    $targetLower = $Target.ToLowerInvariant()

    $match = $null
    foreach ($item in $Config) {
        if ($isNumeric -and $item.projectId -and ([int64]$item.projectId -eq [int64]$targetIdValue)) {
            $match = $item
            break
        }
        if ($item.name -and ($item.name.ToString().ToLowerInvariant() -eq $targetLower)) {
            $match = $item
            break
        }
    }

    if (-not $match) {
        Write-Log -Level 'WARN' -Message "Remove target '$Target' not found in addons.json"
        return [PSCustomObject]@{ Status = 'Skipped'; Name = $Target; Version = ''; Removed = $false; Record = $null }
    }

    if (-not $DryRun) {
        foreach ($folderName in $match.folders) {
            $folderPath = Join-Path -Path $AddonsPath -ChildPath $folderName
            if (Test-Path -LiteralPath $folderPath) {
                try {
                    Remove-Item -LiteralPath $folderPath -Recurse -Force
                    Write-Log -Level 'INFO' -Message "Removed folder '$folderName' for project $($match.projectId)"
                } catch {
                    Write-Log -Level 'WARN' -Message "Failed to remove folder '$folderName' for project $($match.projectId) : $($_.Exception.Message)"
                }
            }
        }
    }

    $displayName = $match.name
    if (-not $displayName) {
        $displayName = "project $($match.projectId)"
    }

    $statusText = 'Removed'
    if ($DryRun) {
        $statusText = 'Would-update'
        Write-Log -Level 'INFO' -Message "DryRun: would remove addon '$displayName' (project $($match.projectId))"
    } else {
        Write-Log -Level 'INFO' -Message "Removed addon record for '$displayName' (project $($match.projectId))"
    }

    return [PSCustomObject]@{ Status = $statusText; Name = $displayName; Version = $match.version; Removed = (-not $DryRun); Record = $match }
}

# =====================================================================
# Console / report output
# =====================================================================

function Show-Table {
    <# Formats $Rows into a List[object] of aligned "col | col | col" text lines. #>
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns
    )

    $widths = @{}
    foreach ($c in $Columns) {
        $widths[$c] = $c.Length
    }
    foreach ($r in $Rows) {
        foreach ($c in $Columns) {
            $val = "$($r.$c)"
            if ($val.Length -gt $widths[$c]) {
                $widths[$c] = $val.Length
            }
        }
    }

    $lines = New-Object 'System.Collections.Generic.List[object]'

    $headerParts = New-Object 'System.Collections.Generic.List[object]'
    $sepParts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in $Columns) {
        $headerParts.Add($c.PadRight($widths[$c]))
        $sepParts.Add(('-' * $widths[$c]))
    }
    $lines.Add(($headerParts -join ' | '))
    $lines.Add(($sepParts -join ' | '))

    foreach ($r in $Rows) {
        $rowParts = New-Object 'System.Collections.Generic.List[object]'
        foreach ($c in $Columns) {
            $val = "$($r.$c)"
            $rowParts.Add($val.PadRight($widths[$c]))
        }
        $lines.Add(($rowParts -join ' | '))
    }

    Write-Output -NoEnumerate $lines
}

# =====================================================================
# CLI argument normalization
# =====================================================================

function ConvertTo-ExpandedStringArray {
    <#
      Windows PowerShell 5.1's own "powershell.exe -File script.ps1 ..."
      argument binding (the exact invocation this script is deployed
      under everywhere - the launcher and addon-server.ps1's job dispatch
      both use it) does not split a single comma-joined token, e.g.
      "1521253,911525" (quoted or not), into separate array elements the
      way a direct in-process call ("& $script -Remove 1521253,911525")
      does; it arrives as ONE element containing the literal comma. Since
      that comma-joined token DOES survive -File binding intact, every
      raw element handed to a multi-value parameter is re-split on commas
      here so the comma-separated usage this script's own help text
      documents as canonical ("-Add 12345,67890") actually works under
      the way the script is really invoked. Tolerates $null input (an
      omitted parameter) and blank/whitespace-only pieces (dropped).
    #>
    param(
        $RawValues
    )

    $result = New-Object 'System.Collections.Generic.List[object]'
    if (-not $RawValues) {
        Write-Output -NoEnumerate $result
        return
    }
    foreach ($raw in $RawValues) {
        if ($null -eq $raw) {
            continue
        }
        $pieces = ([string]$raw) -split ','
        foreach ($piece in $pieces) {
            $trimmed = $piece.Trim()
            if ($trimmed.Length -gt 0) {
                $result.Add($trimmed)
            }
        }
    }
    Write-Output -NoEnumerate $result
}

function ConvertTo-ExpandedIdArray {
    <#
      Same comma-expansion as ConvertTo-ExpandedStringArray, then parses
      each piece as an int64 CurseForge project id. This is why -Add,
      -Only, -Unpin, -Ignore and -Unignore are declared [string[]] in the
      param() block rather than [int[]]: an [int[]] parameter's own
      conversion runs during PowerShell's parameter binding, before the
      script body executes at all, so a comma-joined token like
      "1521253,911525" (which -File binding hands over as one literal
      string) makes PowerShell itself throw a native, uncatchable
      "Cannot convert value ... to type System.Int32[]" error - the
      script never even reaches its own try block. Parsing manually here,
      after the raw strings have already been accepted and split, lets a
      bad value be reported through this script's normal
      Write-Log/exit-2 path instead.
    #>
    param(
        $RawValues,
        [Parameter(Mandatory = $true)][string]$ParamName
    )

    $strings = ConvertTo-ExpandedStringArray -RawValues $RawValues
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $strings) {
        $parsedId = [int64]0
        if (-not [int64]::TryParse($s, [ref]$parsedId)) {
            throw "-$ParamName value '$s' is not a valid integer project id."
        }
        $result.Add($parsedId)
    }
    Write-Output -NoEnumerate $result
}

# =====================================================================
# Main
# =====================================================================

$scriptRootPath = $PSScriptRoot
if (-not $scriptRootPath) {
    $scriptRootPath = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

$script:ConfigPath = Join-Path -Path $scriptRootPath -ChildPath 'addons.json'
$script:StagingPath = Join-Path -Path $scriptRootPath -ChildPath 'staging'
$script:LogPath = Join-Path -Path $scriptRootPath -ChildPath 'sync.log'
$script:LastRunPath = Join-Path -Path $scriptRootPath -ChildPath 'last-run.txt'
$script:SettingsPath = Join-Path -Path $scriptRootPath -ChildPath 'settings.json'
$script:BackupsPath = Join-Path -Path $scriptRootPath -ChildPath 'backups'

try {
    # ---- Load config ----
    $config = $null
    try {
        $config = Read-Config -Path $script:ConfigPath
    } catch {
        $msg = "addons.json could not be parsed: $($_.Exception.Message)"
        Write-Log -Level 'ERROR' -Message $msg
        if ((-not $Quiet) -and (-not $Json)) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }

    # Backfill author/ignoreUpdates/pinnedFileId/releaseType on every record
    # loaded from an older addons.json so later dot-assignment never hits a
    # missing property.
    foreach ($item in $config) {
        Initialize-AddonRecordFields -Record $item
    }

    # ---- Settings (creates settings.json with defaults if missing) ----
    $settings = Get-Settings -Path $script:SettingsPath
    $defaultMaxReleaseType = 1
    if ($settings -and $settings.releaseType) {
        try {
            $defaultMaxReleaseType = [int]$settings.releaseType
        } catch {
            $defaultMaxReleaseType = 1
        }
    }

    # ---- -Launcher: gate on settings.autoUpdateOnLaunch, no network when disabled ----
    if ($Launcher) {
        $autoUpdateOnLaunch = $true
        if ($settings -and ($null -ne $settings.autoUpdateOnLaunch)) {
            $autoUpdateOnLaunch = [bool]$settings.autoUpdateOnLaunch
        }
        if (-not $autoUpdateOnLaunch) {
            Write-Log -Level 'INFO' -Message 'auto-update disabled'
            if ($Json) {
                $jsonOut = [PSCustomObject]@{ action = 'sync'; results = @(); addons = $config.ToArray() }
                Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
            } elseif (-not $Quiet) {
                Write-Host 'Auto-update on launch is disabled; skipping sync.'
            }
            exit 0
        }
    }

    # ---- -Status: read-only, no network ----
    if ($Status) {
        Write-Log -Level 'INFO' -Message 'Status requested'

        # E3 (dependencies): missingDeps/missingOptionalDeps are computed live
        # against the current AddOns directory listing every time -Status
        # runs, never stored on the record - a dependency that gets installed
        # or removed later is reflected immediately with no resync needed.
        # -Status has never required a resolvable AddOns path (unlike a real
        # sync, which exits 2 without one further down); resolving it here
        # the same way a sync would, but degrading to "every requiredDep
        # counts as missing" instead of erroring when it can't be resolved
        # or doesn't exist, keeps that no-path-required contract intact.
        $statusAddonsPath = Resolve-AddonsPath -Provided $AddonsPath -ScriptRoot $scriptRootPath
        $statusPresentFolders = Get-AddonsFolderSet -Path $statusAddonsPath

        $statusAddons = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $config) {
            $missingDeps = Get-MissingDeps -DepNames $item.requiredDeps -PresentFolders $statusPresentFolders
            $missingOptionalDeps = Get-MissingDeps -DepNames $item.optionalDeps -PresentFolders $statusPresentFolders
            $clone = [PSCustomObject]@{}
            foreach ($p in $item.PSObject.Properties) {
                $clone | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value
            }
            $clone | Add-Member -MemberType NoteProperty -Name 'missingDeps' -Value $missingDeps.ToArray()
            $clone | Add-Member -MemberType NoteProperty -Name 'missingOptionalDeps' -Value $missingOptionalDeps.ToArray()
            $statusAddons.Add($clone)
        }

        if ($Json) {
            $jsonOut = [PSCustomObject]@{ action = 'status'; results = @(); addons = $statusAddons.ToArray() }
            Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
        } elseif (-not $Quiet) {
            $statusRows = New-Object 'System.Collections.Generic.List[object]'
            foreach ($item in $statusAddons) {
                $pinnedText = ''
                if ($item.pinnedFileId) {
                    $pinnedText = "$($item.pinnedFileId)"
                }
                $ignoredText = ''
                if ($item.ignoreUpdates) {
                    $ignoredText = 'Yes'
                }
                $statusRows.Add([PSCustomObject]@{
                        Name        = $item.name
                        Version     = $item.version
                        FileId      = $item.fileId
                        InstalledAt = $item.installedAt
                        Folders     = ($item.folders -join ', ')
                        Author      = $item.author
                        Pinned      = $pinnedText
                        Ignored     = $ignoredText
                        MissingDeps = ($item.missingDeps -join ', ')
                    })
            }
            $tableLines = Show-Table -Rows $statusRows -Columns @('Name', 'Version', 'FileId', 'InstalledAt', 'Folders', 'Author', 'Pinned', 'Ignored', 'MissingDeps')
            foreach ($line in $tableLines) {
                Write-Host $line
            }
        }
        exit 0
    }

    # ---- -Files: list available files for one project, no config change ----
    if ($Files) {
        $filesProjectId = [int]$Files
        Write-Log -Level 'INFO' -Message "Files requested for project $filesProjectId"

        $fileRows = New-Object 'System.Collections.Generic.List[object]'
        $filesError = $null
        try {
            $rawFiles = Get-CfFiles -ProjectId $filesProjectId -MaxReleaseType 3
            foreach ($f in $rawFiles) {
                $authorName = $null
                if ($f.user -and $f.user.username) {
                    $authorName = $f.user.username
                }
                $gv = @()
                if ($f.gameVersions) {
                    $gv = $f.gameVersions
                }
                $fileRows.Add([PSCustomObject]@{
                        id           = [int64]$f.id
                        displayName  = $f.displayName
                        version      = Get-VersionFromDisplayName -DisplayName $f.displayName
                        fileName     = $f.fileName
                        dateCreated  = $f.dateCreated
                        releaseType  = $f.releaseType
                        gameVersions = $gv
                        fileLength   = $f.fileLength
                        downloads    = $f.totalDownloads
                        author       = $authorName
                        retail       = (Test-FileHasTypeId -File $f -TypeId 517)
                    })
            }
        } catch {
            $filesError = $_.Exception.Message
            Write-Log -Level 'ERROR' -Message "Failed to list files for project $filesProjectId : $filesError"
        }

        if ($Json) {
            # SPEC.md line 55 documents this shape exactly as
            # {"action":"files","projectId":N,"files":[...]} with no error
            # field; an earlier ad-hoc "error" property was already added
            # and then deliberately removed for this same reason (see
            # CHANGELOG Round 1). The failure is still logged to sync.log
            # and surfaced in the non-JSON table path below.
            $jsonOut = [PSCustomObject]@{ action = 'files'; projectId = $filesProjectId; files = $fileRows.ToArray() }
            Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
        } elseif (-not $Quiet) {
            if ($filesError) {
                Write-Host "ERROR: $filesError"
            } else {
                $displayRows = New-Object 'System.Collections.Generic.List[object]'
                foreach ($fr in $fileRows) {
                    $channel = 'Release'
                    if ($fr.releaseType -eq 2) {
                        $channel = 'Beta'
                    } elseif ($fr.releaseType -eq 3) {
                        $channel = 'Alpha'
                    }
                    $dateText = "$($fr.dateCreated)"
                    try {
                        $dateText = ([datetime]$fr.dateCreated).ToString('yyyy-MM-dd')
                    } catch {
                    }
                    $displayRows.Add([PSCustomObject]@{
                            Id        = $fr.id
                            Version   = $fr.version
                            FileName  = $fr.fileName
                            Date      = $dateText
                            Channel   = $channel
                            Retail    = $fr.retail
                            Size      = $fr.fileLength
                            Downloads = $fr.downloads
                            Author    = $fr.author
                        })
                }
                $tableLines = Show-Table -Rows $displayRows -Columns @('Id', 'Version', 'FileName', 'Date', 'Channel', 'Retail', 'Size', 'Downloads', 'Author')
                foreach ($line in $tableLines) {
                    Write-Host $line
                }
            }
        }
        exit 0
    }

    # ---- Resolve and validate the AddOns path ----
    $effectiveAddonsPath = Resolve-AddonsPath -Provided $AddonsPath -ScriptRoot $scriptRootPath
    if (-not $effectiveAddonsPath) {
        $msg = 'AddonsPath was not specified and could not be inferred from the script location (expected <X>\_retail_\AddonSync). Pass -AddonsPath "<X>\_retail_\Interface\AddOns".'
        Write-Log -Level 'ERROR' -Message $msg
        if ((-not $Quiet) -and (-not $Json)) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }
    if (-not (Test-Path -LiteralPath $effectiveAddonsPath -PathType Container)) {
        $msg = "AddOns path does not exist: $effectiveAddonsPath"
        Write-Log -Level 'ERROR' -Message $msg
        if ((-not $Quiet) -and (-not $Json)) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }

    # ---- -Scan: list untracked top-level AddOns folders, no config change ----
    if ($Scan) {
        Write-Log -Level 'INFO' -Message 'Scan requested'

        $ownedFolders = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($item in $config) {
            if ($item.folders) {
                foreach ($f in $item.folders) {
                    if ($f) {
                        [void]$ownedFolders.Add(([string]$f).ToLowerInvariant())
                    }
                }
            }
        }

        $untracked = New-Object 'System.Collections.Generic.List[object]'
        $topDirs = Get-ChildItem -LiteralPath $effectiveAddonsPath -Force -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $topDirs) {
            if ($ownedFolders.Contains($dir.Name.ToLowerInvariant())) {
                continue
            }
            $info = Get-FolderTocInfo -FolderPath $dir.FullName
            $untracked.Add([PSCustomObject]@{
                    folder  = $dir.Name
                    title   = $info.title
                    version = $info.version
                    hasToc  = $info.hasToc
                })
        }

        if ($Json) {
            $jsonOut = [PSCustomObject]@{ action = 'scan'; untracked = $untracked.ToArray() }
            Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
        } elseif (-not $Quiet) {
            $tableLines = Show-Table -Rows $untracked -Columns @('Folder', 'Title', 'Version', 'HasToc')
            foreach ($line in $tableLines) {
                Write-Host $line
            }
        }
        exit 0
    }

    # ---- Staging: clean at the start of the run (skipped in DryRun) ----
    if (-not $DryRun) {
        if (Test-Path -LiteralPath $script:StagingPath) {
            Remove-Item -LiteralPath $script:StagingPath -Recurse -Force
        }
        New-Item -ItemType Directory -Path $script:StagingPath -Force | Out-Null
    }

    $resultsRows = New-Object 'System.Collections.Generic.List[object]'

    # ---- Normalize array-typed CLI parameters (see ConvertTo-ExpandedIdArray
    #      / ConvertTo-ExpandedStringArray above for why this is needed) ----
    try {
        $Add = ConvertTo-ExpandedIdArray -RawValues $Add -ParamName 'Add'
        $Remove = ConvertTo-ExpandedStringArray -RawValues $Remove
        $Only = ConvertTo-ExpandedIdArray -RawValues $Only -ParamName 'Only'
        $Unpin = ConvertTo-ExpandedIdArray -RawValues $Unpin -ParamName 'Unpin'
        $Ignore = ConvertTo-ExpandedIdArray -RawValues $Ignore -ParamName 'Ignore'
        $Unignore = ConvertTo-ExpandedIdArray -RawValues $Unignore -ParamName 'Unignore'
        $Rollback = ConvertTo-ExpandedIdArray -RawValues $Rollback -ParamName 'Rollback'
    } catch {
        $msg = "Invalid command-line value: $($_.Exception.Message)"
        Write-Log -Level 'ERROR' -Message $msg
        if ((-not $Quiet) -and (-not $Json)) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }

    # ---- Compute targeting flags up front (needed to validate -FileId before
    #      any mutation happens, and later to decide toSync and the action label) ----
    $hasRemove = $Remove -and ($Remove.Count -gt 0)
    $hasAdd = $Add -and ($Add.Count -gt 0)
    $hasOnly = $Only -and ($Only.Count -gt 0)
    $hasUnpin = $Unpin -and ($Unpin.Count -gt 0)
    $hasIgnore = $Ignore -and ($Ignore.Count -gt 0)
    $hasUnignore = $Unignore -and ($Unignore.Count -gt 0)
    $hasRollback = $Rollback -and ($Rollback.Count -gt 0)
    $hasFlagsOnly = $hasUnpin -or $hasIgnore -or $hasUnignore

    $onlySet = New-Object 'System.Collections.Generic.HashSet[int64]'
    if ($hasOnly) {
        foreach ($id in $Only) {
            [void]$onlySet.Add([int64]$id)
        }
    }

    # ---- Validate -FileId usage: requires exactly one id in -Only or -Add ----
    $fileIdTargetId = $null
    if ($FileId) {
        $addCountForFileId = 0
        if ($hasAdd) {
            $addCountForFileId = $Add.Count
        }
        $onlyCountForFileId = 0
        if ($hasOnly) {
            $onlyCountForFileId = $Only.Count
        }

        if (($addCountForFileId -eq 1) -and ($onlyCountForFileId -eq 0)) {
            $fileIdTargetId = [int64]$Add[0]
        } elseif (($onlyCountForFileId -eq 1) -and ($addCountForFileId -eq 0)) {
            $fileIdTargetId = [int64]$Only[0]
        } else {
            $msg = '-FileId requires exactly one project id via -Only or -Add.'
            Write-Log -Level 'ERROR' -Message $msg
            if ((-not $Quiet) -and (-not $Json)) {
                Write-Host "ERROR: $msg"
            }
            exit 2
        }
    }

    # ---- -Remove ----
    if ($hasRemove) {
        foreach ($target in $Remove) {
            $removeResult = Remove-AddonByTarget -Target $target -Config $config -AddonsPath $effectiveAddonsPath -DryRun:$DryRun
            $removeProjectId = $null
            $removeFileId = $null
            if ($removeResult.Record) {
                $removeProjectId = $removeResult.Record.projectId
                $removeFileId = $removeResult.Record.fileId
            }
            $resultsRows.Add([PSCustomObject]@{ Status = $removeResult.Status; Name = $removeResult.Name; Version = $removeResult.Version; ProjectId = $removeProjectId; FileId = $removeFileId })
            if ($removeResult.Removed -and $removeResult.Record) {
                $config.Remove($removeResult.Record) | Out-Null
            }
        }
    }

    # ---- -Add ----
    $addedIds = New-Object 'System.Collections.Generic.List[object]'
    if ($hasAdd) {
        foreach ($id in $Add) {
            $existing = $null
            foreach ($item in $config) {
                if ($item.projectId -and ([int64]$item.projectId -eq [int64]$id)) {
                    $existing = $item
                    break
                }
            }
            if ($existing) {
                Write-Log -Level 'INFO' -Message "Add skipped: project $id is already present in addons.json"
                $existingDisplayName = $existing.name
                if (-not $existingDisplayName) {
                    $existingDisplayName = "project $id"
                }
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = $existingDisplayName; Version = $existing.version; ProjectId = $existing.projectId; FileId = $existing.fileId })
                continue
            }
            $newRecord = New-AddonRecord -ProjectId $id
            $config.Add($newRecord)
            $addedIds.Add([int64]$id)
            Write-Log -Level 'INFO' -Message "Added project $id to addons.json"
        }
    }

    # ---- -Unpin / -Ignore / -Unignore: config-only, no network ----
    if ($hasUnpin) {
        foreach ($id in $Unpin) {
            $match = $null
            foreach ($item in $config) {
                if ($item.projectId -and ([int64]$item.projectId -eq [int64]$id)) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $match.pinnedFileId = $null
                $displayName = $match.name
                if (-not $displayName) {
                    $displayName = "project $id"
                }
                Write-Log -Level 'INFO' -Message "Unpinned project $id ($displayName)"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Unpinned'; Name = $displayName; Version = $match.version; ProjectId = $match.projectId; FileId = $match.fileId })
            } else {
                Write-Log -Level 'WARN' -Message "Unpin target $id not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = "project $id"; Version = ''; ProjectId = $id; FileId = $null })
            }
        }
    }

    if ($hasIgnore) {
        foreach ($id in $Ignore) {
            $match = $null
            foreach ($item in $config) {
                if ($item.projectId -and ([int64]$item.projectId -eq [int64]$id)) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $match.ignoreUpdates = $true
                $displayName = $match.name
                if (-not $displayName) {
                    $displayName = "project $id"
                }
                Write-Log -Level 'INFO' -Message "Ignoring updates for project $id ($displayName)"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Ignored'; Name = $displayName; Version = $match.version; ProjectId = $match.projectId; FileId = $match.fileId })
            } else {
                Write-Log -Level 'WARN' -Message "Ignore target $id not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = "project $id"; Version = ''; ProjectId = $id; FileId = $null })
            }
        }
    }

    if ($hasUnignore) {
        foreach ($id in $Unignore) {
            $match = $null
            foreach ($item in $config) {
                if ($item.projectId -and ([int64]$item.projectId -eq [int64]$id)) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $match.ignoreUpdates = $false
                $displayName = $match.name
                if (-not $displayName) {
                    $displayName = "project $id"
                }
                Write-Log -Level 'INFO' -Message "Stopped ignoring updates for project $id ($displayName)"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Unignored'; Name = $displayName; Version = $match.version; ProjectId = $match.projectId; FileId = $match.fileId })
            } else {
                Write-Log -Level 'WARN' -Message "Unignore target $id not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = "project $id"; Version = ''; ProjectId = $id; FileId = $null })
            }
        }
    }

    # ---- -Rollback: reinstall from a locally archived zip, no network ----
    if ($hasRollback) {
        foreach ($id in $Rollback) {
            $match = $null
            foreach ($item in $config) {
                if ($item.projectId -and ([int64]$item.projectId -eq [int64]$id)) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $rollbackResult = Invoke-RollbackForRecord -Record $match -AddonsPath $effectiveAddonsPath -StagingPath $script:StagingPath -BackupsRoot $script:BackupsPath -DryRun:$DryRun
                $rollbackFileId = $match.fileId
                if (Get-Member -InputObject $rollbackResult -Name 'FileId' -MemberType NoteProperty) {
                    $rollbackFileId = $rollbackResult.FileId
                }
                $resultsRows.Add([PSCustomObject]@{ Status = $rollbackResult.Status; Name = $rollbackResult.Name; Version = $rollbackResult.Version; ProjectId = $match.projectId; FileId = $rollbackFileId })
            } else {
                Write-Log -Level 'WARN' -Message "Rollback target $id not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = "project $id"; Version = ''; ProjectId = $id; FileId = $null })
            }
        }
    }

    # ---- Decide which records to sync over the network this run ----
    # A plain bare invocation (nothing targeting) syncs everything, exactly
    # as before. -Add restricts to the newly added records; -Only restricts
    # to that explicit id list; a remove-only, flags-only and/or
    # rollback-only run (no add, no -Only) never implies a full sync.
    $toSync = New-Object 'System.Collections.Generic.List[object]'

    if ($hasAdd) {
        foreach ($item in $config) {
            if ($item.projectId -and $addedIds.Contains([int64]$item.projectId)) {
                $toSync.Add($item)
            }
        }
    } elseif ($hasOnly) {
        foreach ($item in $config) {
            if ($item.projectId -and $onlySet.Contains([int64]$item.projectId)) {
                $toSync.Add($item)
            }
        }
    } elseif ($hasRemove -or $hasFlagsOnly -or $hasRollback) {
        # Nothing to add here: remove-only, flags-only and/or rollback-only
        # runs stay network-free.
    } else {
        foreach ($item in $config) {
            $toSync.Add($item)
        }
    }

    foreach ($record in $toSync) {
        $isExplicit = $false
        if ($record.projectId -and $onlySet.Contains([int64]$record.projectId)) {
            $isExplicit = $true
        }
        if ($record.projectId -and $addedIds.Contains([int64]$record.projectId)) {
            $isExplicit = $true
        }

        $fileIdOverrideForRecord = $null
        if ($fileIdTargetId -and $record.projectId -and ([int64]$record.projectId -eq $fileIdTargetId)) {
            $fileIdOverrideForRecord = $FileId
        }

        $rowResult = Sync-SingleAddon -Record $record -AddonsPath $effectiveAddonsPath -StagingPath $script:StagingPath -BackupsPath $script:BackupsPath -Force:$Force -DryRun:$DryRun -DefaultMaxReleaseType $defaultMaxReleaseType -FileIdOverride $fileIdOverrideForRecord -ExplicitTarget:$isExplicit

        # For a real (non-DryRun) Installed/Updated row, Sync-SingleAddon
        # mutates $record.fileId in place before returning, so $record.fileId
        # already reflects the resulting file. A DryRun Would-update row never
        # touches $record (DryRun makes no writes), so it carries its own
        # FileId (the newly SELECTED, target file) that must win here instead
        # -- otherwise the row would pair the NEW target Version with the OLD
        # installed FileId. Every other status object has no FileId property,
        # so this naturally falls back to $record.fileId unchanged for them.
        $rowFileId = $record.fileId
        if (Get-Member -InputObject $rowResult -Name 'FileId' -MemberType NoteProperty) {
            $rowFileId = $rowResult.FileId
        }
        $resultsRows.Add([PSCustomObject]@{ Status = $rowResult.Status; Name = $rowResult.Name; Version = $rowResult.Version; ProjectId = $record.projectId; FileId = $rowFileId })
    }

    # ---- Drop placeholder records for adds that never got an installable file ----
    if ((-not $DryRun) -and ($addedIds.Count -gt 0)) {
        $placeholders = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $config) {
            if ($item.projectId -and $addedIds.Contains([int64]$item.projectId) -and (-not $item.fileId)) {
                $placeholders.Add($item)
            }
        }
        foreach ($placeholder in $placeholders) {
            Write-Log -Level 'WARN' -Message "Project $($placeholder.projectId) was not added: no installable file was found, so no record was saved"
            $config.Remove($placeholder) | Out-Null
        }
    }

    # ---- Persist config (skipped entirely in DryRun) ----
    if (-not $DryRun) {
        try {
            Save-Config -Path $script:ConfigPath -Items $config
        } catch {
            Write-Log -Level 'ERROR' -Message "Failed to save addons.json: $($_.Exception.Message)"
        }
    }

    # ---- Determine the action label for -Json reporting ----
    $actionLabel = 'sync'
    if ($DryRun) {
        $actionLabel = 'check'
    } elseif ($hasAdd) {
        $actionLabel = 'add'
    } elseif ($hasRemove) {
        $actionLabel = 'remove'
    } elseif ($hasRollback) {
        $actionLabel = 'rollback'
    } elseif ($hasFlagsOnly -and (-not $hasOnly)) {
        $actionLabel = 'flags'
    }

    # ---- Report ----
    $counts = @{}
    foreach ($r in $resultsRows) {
        if (-not $counts.ContainsKey($r.Status)) {
            $counts[$r.Status] = 0
        }
        $counts[$r.Status] = $counts[$r.Status] + 1
    }
    $countParts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $counts.Keys) {
        $countParts.Add("$key`: $($counts[$key])")
    }
    $countSummary = $countParts -join '  '
    $timestampUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $headerLine = "Addon Sync run $timestampUtc  Total: $($resultsRows.Count)  $countSummary"

    $tableLines = Show-Table -Rows $resultsRows -Columns @('Status', 'Name', 'Version')

    if ($Json) {
        $jsonResults = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in $resultsRows) {
            $jsonResults.Add([PSCustomObject]@{
                    status    = $r.Status
                    name      = $r.Name
                    version   = $r.Version
                    projectId = $r.ProjectId
                    fileId    = $r.FileId
                })
        }
        $jsonOut = [PSCustomObject]@{
            action  = $actionLabel
            results = $jsonResults.ToArray()
            addons  = $config.ToArray()
        }
        Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
    } elseif (-not $Quiet) {
        Write-Host $headerLine
        foreach ($line in $tableLines) {
            Write-Host $line
        }
    }

    if (-not $DryRun) {
        $outLines = New-Object 'System.Collections.Generic.List[object]'
        $outLines.Add($headerLine)
        $outLines.Add('')
        foreach ($line in $tableLines) {
            $outLines.Add($line)
        }
        try {
            Set-Content -LiteralPath $script:LastRunPath -Value $outLines -Encoding UTF8
        } catch {
            Write-Log -Level 'WARN' -Message "Failed to write last-run.txt: $($_.Exception.Message)"
        }
    }

    exit 0

} finally {
    if (Test-Path -LiteralPath $script:StagingPath) {
        try {
            Remove-Item -LiteralPath $script:StagingPath -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
}
