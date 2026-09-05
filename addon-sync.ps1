<#
=====================================================================
 addon-sync.ps1

 Keeps World of Warcraft retail addons updated from CurseForge.
 Designed to run headless / hidden from a launcher before the game
 starts. Windows PowerShell 5.1 only. No modules, no external
 binaries, pure ASCII.

 LAYOUT (relative to the folder this script lives in):
   addon-sync.ps1   this script
   flavours\<id>\   per-flavour data: addons.json (config AND state,
                    JSON array of addon records), backups\, and
                    staging\ (scratch folder for downloads/extraction -
                    per flavour so concurrent flavour syncs never share it)
   sync.log         append-only log
   last-run.txt     overwritten each run with the summary table

 USAGE:
   addon-sync.ps1 [-AddonsPath <path>] [-Add <id[]>] [-Remove <name-or-id[]>]
                  [-Status] [-Force] [-DryRun] [-Quiet] [-Only <id[]>]
                  [-FileId <id>] [-Unpin <id[]>] [-Ignore <id[]>]
                  [-Unignore <id[]>] [-Files <id>] [-Scan] [-Json] [-Launcher]
                  [-Rollback <id[]>] [-BuildInfoPath <path>]

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
                            like a normal sync. P1 perf pass: also skips the
                            sync (exit 0, no network) when ROOT\state.json
                            records this flavour's addons as checked within
                            the last 10 minutes, and never lets the whole
                            run take more than ~40 seconds wall-clock -
                            once that budget is spent, remaining addons are
                            reported Skipped (logged by name) rather than
                            checked, so the game is never held up more than
                            the task brief's 45-second cap.
   -LowPriority             Lowers this process's own scheduling priority
                            (BelowNormal) and opts into EcoQoS, the same
                            defense-in-depth addon-server.ps1 always applies
                            to itself at startup - so a background sync
                            never competes with a foreground game for CPU.
                            Applied automatically (no need to pass this)
                            whenever -Json or -Quiet is set, since every
                            non-interactive caller (a server-spawned job,
                            the launcher chain) already passes one of those.
   -Rollback <id> [<id> ...]  For each project id, reinstalls from the
                            locally archived zip of the version it was on
                            before its last update (ROOT\backups\<id>\
                            <previousFileId>.zip), swaps fileId/version with
                            the previous ones, and pins the restored file so
                            it is not immediately re-updated. No network
                            access. Fails a given id when there is no
                            recorded previous version or its backup zip is
                            missing.
   -BuildInfoPath <path>   Overrides the .build.info file read for the
                            client build/compat check (E13). Default: the
                            .build.info sitting next to the resolved AddOns
                            path's game root (three levels up from
                            <AddOns>\Interface\AddOns). Intended for tests -
                            never reads the real WoW folder when given.
   -ProgressPath <path>    Optional. While a sync loop runs, atomically
                            writes a small JSON progress snapshot
                            ({total,index,addon,phase[,bytesDone,
                            bytesTotal,failPhase]}) to this path after every
                            phase change, for a caller (addon-server.ps1) to
                            poll mid-run. Absent -> every write is a no-op.
                            Purely additive telemetry; never changes what
                            gets synced or the final -Json stdout shape.

 WAGO ADDONS (E12): -Add, -Only, -Unpin, -Ignore, -Unignore, -Rollback,
   -Remove and -Files all also accept a Wago target in place of (or mixed
   with, comma-joined) a numeric CurseForge project id: "wago:<slug>",
   "wago:<id>", or a full "https://addons.wago.io/addons/<slug>" URL. -FileId
   accepts a Wago release id (a string like "r6p5g7zQ") the same way it
   accepts a CurseForge file id. Every other behaviour (pin/ignore/rollback/
   dependencies/backups/-Status/-Scan) applies identically regardless of
   source; addons.json records gain source/wagoId/slug/curseId fields.

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
   addon-sync.ps1 -Status -Json -BuildInfoPath C:\Scratch\.build.info

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
    [string]$FileId,
    [string[]]$Unpin,
    [string[]]$Ignore,
    [string[]]$Unignore,
    [string]$Files,
    [switch]$Scan,
    [switch]$Json,
    [switch]$Launcher,
    [switch]$LowPriority,
    [string[]]$Rollback,
    [string]$BuildInfoPath,
    [string]$ProgressPath,
    # FLAVORS-SPEC S4.1: which installed WoW client this run targets.
    # Omitted -> 'retail' when _retail_ is installed (byte-identical to
    # every existing invocation, script, and scheduled task); otherwise the
    # first flavour Get-InstalledFlavours returns (S2.1 order). Validated
    # against the live Get-InstalledFlavours result in Main below - an
    # unrecognized or not-installed value is a clean, existing-style fatal
    # error (exit 2), never a crash.
    [string]$Flavor,
    # FLAVORS-SPEC S2.3/S8: overrides the WoW root Get-InstalledFlavours/
    # Resolve-AddonsPath resolve against, instead of walking up from this
    # script's own folder. Never touches the real WoW folder when given -
    # this is how the synthetic test fixture is pointed at.
    [string]$WowRoot
)

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$script:CfUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

# =====================================================================
# Flavours (FLAVORS-SPEC.md S2.1) - static tables, defined once at script
# scope so every function below (and addon-server.ps1's duplicate) reads
# the exact same fixed order and folder/product mapping. Appending a 7th
# flavour, or a future expansion's progression row (S2.4, in
# Resolve-ClassicProgressionTypeId below), only ever touches this section.
# =====================================================================

# Fixed render order (S2.1) - every list/switcher iterates $Script:FlavourDefs
# directly rather than re-sorting, so this array's order IS the contract.
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

# S4.5's per-era .toc selection table: X-Flavor tag value (point 1,
# authoritative wherever present) + filename-suffix try-order (point 2).
# Bare "<FolderName>.toc" ownership (point 2's caveat) is NOT a per-era
# property - it is determined per-call in Get-PrimaryTocFile from which of
# the three groups (Retail / Classic Era / Classic's rolling progression,
# tbc+wrath+cata+mists collapsed into one group for this purpose) has no
# suffixed file present in that specific folder.
$Script:TocEraSelectors = [ordered]@{
    'retail'      = [PSCustomObject]@{ XFlavorTag = 'Mainline'; Suffixes = @('_Mainline', '-Mainline') }
    'classic_era' = [PSCustomObject]@{ XFlavorTag = 'Vanilla';  Suffixes = @('_Vanilla', '_Classic', '-Classic') }
    'tbc'         = [PSCustomObject]@{ XFlavorTag = 'TBC';      Suffixes = @('_TBC', '-BCC') }
    'wrath'       = [PSCustomObject]@{ XFlavorTag = 'Wrath';    Suffixes = @('_Wrath', '-Wrath', '-WOTLKC') }
    'cata'        = [PSCustomObject]@{ XFlavorTag = 'Cata';     Suffixes = @('_Cata') }
    'mists'       = [PSCustomObject]@{ XFlavorTag = 'Mists';    Suffixes = @('_Mists') }
}

# =====================================================================
# Logging
# =====================================================================

$Script:LogRotationMaxBytes = 2097152

function Invoke-LogRotationIfNeeded {
    <#
      P1 perf pass (item 4): caps sync.log at ~2MB, same convention/limit as
      addon-server.ps1's own Invoke-LogRotationIfNeeded for server.log - a
      background tray running for weeks otherwise grows this file without
      bound (every launch/job appends). Rotates to a single "<path>.1"
      (overwritten, never accumulated). Best-effort: a rotation failure must
      never block the log write itself.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -lt $Script:LogRotationMaxBytes) { return }
        $rotatedPath = "$Path.1"
        try { Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction SilentlyContinue } catch { }
        Move-Item -LiteralPath $Path -Destination $rotatedPath -Force -ErrorAction Stop
    } catch {
        # Rotation must never block logging.
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    # FLAVORS-SPEC S3.1: sync.log is shared across every flavour; lines gain
    # a "[<flavour>]" prefix once Main resolves which flavour this run
    # targets (empty/unset before then - e.g. during Invoke-FlavourMigration,
    # which runs before flavour resolution - so this is never undefined).
    $flavourPrefix = ''
    if ($script:LogFlavourPrefix) { $flavourPrefix = $script:LogFlavourPrefix }
    $line = "$timestamp [$Level] $flavourPrefix$Message"
    try {
        Invoke-LogRotationIfNeeded -Path $script:LogPath
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never abort the run.
    }
}

# P1 perf pass (item 3): identical contract/implementation to
# addon-server.ps1's own Set-FurphyLowPriority (duplicated verbatim, per
# this codebase's established pattern for shared logic between the two
# scripts - see e.g. Invoke-FlavourMigration's own doc comment) - lowers
# this process's scheduling priority/QoS so a background sync (a
# server-spawned job, the tray's scheduled cycle, the launcher chain) never
# competes with a foreground game for CPU. Best-effort throughout.
function Set-FurphyLowPriority {
    try {
        [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    } catch {
        # Best-effort only.
    }
    try {
        if (-not ('Furphy.PowerThrottling' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Furphy {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_POWER_THROTTLING_STATE {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }
    public static class PowerThrottling {
        public const int ProcessPowerThrottling = 4;
        public const uint PROCESS_POWER_THROTTLING_CURRENT_VERSION = 1;
        public const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x1;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetProcessInformation(IntPtr hProcess, int ProcessInformationClass, ref PROCESS_POWER_THROTTLING_STATE ProcessInformation, uint ProcessInformationSize);

        public static bool EnableEcoQoS() {
            PROCESS_POWER_THROTTLING_STATE state = new PROCESS_POWER_THROTTLING_STATE();
            state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
            state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
            state.StateMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
            uint size = (uint)Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE));
            return SetProcessInformation(System.Diagnostics.Process.GetCurrentProcess().Handle, ProcessPowerThrottling, ref state, size);
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
        }
        [Furphy.PowerThrottling]::EnableEcoQoS() | Out-Null
    } catch {
        # Best-effort only - older Windows or a blocked API surface must
        # never block startup.
    }
}

function Write-ProgressStep {
    <#
      Mirrors Write-Log's "never abort the run" contract: serializes a small
      progress snapshot to $script:ProgressPath, atomically (temp file +
      Move-Item -Force), so a caller polling that path (addon-server.ps1)
      never reads a half-written file. A complete no-op when $script:ProgressPath
      is empty (the default, unset) - callers pass this on every phase
      change unconditionally, and this function is the single place that
      decides whether that turns into an actual write.

      -Phase is one of: queued, checking, downloading, installing,
      up_to_date, done, failed. -BytesDone/-BytesTotal are the optional
      download-progress fields (omitted from the JSON when not supplied -
      see UX-SPEC.md section 4.4, not implemented yet in this pass).
      -FailPhase is an additive field (not in the original UX-SPEC.md
      example payload - see that doc's CS1 note) carrying which phase a
      failure happened during (checking/downloading/installing), so a
      caller can map it to a plain-language reason without parsing
      exception text.
    #>
    param(
        [int]$Total = 0,
        [int]$Index = 0,
        $Addon = $null,
        [Parameter(Mandatory = $true)][string]$Phase,
        $BytesDone = $null,
        $BytesTotal = $null,
        $FailPhase = $null
    )

    if (-not $script:ProgressPath) {
        return
    }

    try {
        $obj = [ordered]@{
            total = $Total
            index = $Index
            addon = $Addon
            phase = $Phase
        }
        if ($null -ne $BytesDone) { $obj['bytesDone'] = $BytesDone }
        if ($null -ne $BytesTotal) { $obj['bytesTotal'] = $BytesTotal }
        if ($FailPhase) { $obj['failPhase'] = $FailPhase }

        $json = ConvertTo-Json -InputObject $obj -Depth 5
        $tmpPath = "$script:ProgressPath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $script:ProgressPath -Force
    } catch {
        # Progress reporting must never abort the run.
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

function Invoke-HttpDownloadWithProgress {
    <#
      CS6 (UX-SPEC.md section 4.4): downloads $Uri to $OutFile with
      byte-level progress, calling Write-ProgressStep (phase 'downloading',
      bytesDone/bytesTotal) at most every 250ms or 256KB.

      Invoke-WebRequest -OutFile gives no progress callback in PS 5.1, so
      this uses [System.Net.HttpWebRequest] directly and copies the
      response stream into a [System.IO.FileStream] in 64KB chunks. Kept
      as a small, self-contained helper used ONLY by the -OutFile branches
      of Invoke-CfRequest/Invoke-WagoRequest, which still own all retry
      (429/403 for CF, 429/503 for Wago) and pacing logic exactly as
      before -- this function is a drop-in replacement for one
      Invoke-WebRequest -OutFile call, nothing more:
        - Redirects (e.g. the CDN 302) are followed: AllowAutoRedirect
          defaults to $true on HttpWebRequest, same as Invoke-WebRequest.
        - Same UserAgent and the caller's -Headers hashtable (Accept and
          Referer map to their dedicated HttpWebRequest properties since
          HttpWebRequest rejects setting those via the generic Headers
          collection; anything else goes through Headers.Add).
        - Same -TimeoutSec applied to both .Timeout and .ReadWriteTimeout
          (the latter guards a stalled read mid-stream, which .Timeout
          alone does not cover for a slow/dead connection).
        - TLS 1.2 is already forced script-wide via ServicePointManager
          (line ~139), which HttpWebRequest also honors -- no change
          needed here.
        - On a non-2xx response, HttpWebRequest.GetResponse() throws a
          System.Net.WebException whose .Response is an HttpWebResponse
          carrying .StatusCode -- the exact shape Get-ExceptionStatusCode
          already reads, so the 429/403/503 retry branches in
          Invoke-CfRequest/Invoke-WagoRequest see identical status codes
          to before and their error messages/wording are unaffected.
      Every stream/response object is disposed in a finally block even on
      a thrown exception, so a failed attempt never leaks a file handle
      that would block the next retry's FileMode.Create.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$UserAgent,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$TimeoutSec = 30,
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        $ProgressAddon = $null
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.UserAgent = $UserAgent
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.AllowAutoRedirect = $true

    if ($Headers) {
        foreach ($k in $Headers.Keys) {
            switch ($k) {
                'Accept' { $request.Accept = $Headers[$k] }
                'Referer' { $request.Referer = $Headers[$k] }
                default { $request.Headers.Add($k, $Headers[$k]) }
            }
        }
    }

    $response = $null
    $responseStream = $null
    $fileStream = $null
    try {
        $response = $request.GetResponse()

        $bytesTotal = $null
        if ($response.ContentLength -ge 0) {
            $bytesTotal = [int64]$response.ContentLength
        }

        $responseStream = $response.GetResponseStream()
        $fileStream = New-Object System.IO.FileStream($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

        $buffer = New-Object byte[] 65536
        $bytesDone = [int64]0
        $lastWriteAt = Get-Date
        $lastWriteBytes = [int64]0

        while ($true) {
            $read = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }
            $fileStream.Write($buffer, 0, $read)
            $bytesDone += $read

            $now = Get-Date
            $elapsedMs = ($now - $lastWriteAt).TotalMilliseconds
            $sinceBytes = $bytesDone - $lastWriteBytes
            if (($elapsedMs -ge 250) -or ($sinceBytes -ge 262144)) {
                Write-ProgressStep -Total $ProgressTotal -Index $ProgressIndex -Addon $ProgressAddon -Phase 'downloading' -BytesDone $bytesDone -BytesTotal $bytesTotal
                $lastWriteAt = $now
                $lastWriteBytes = $bytesDone
            }
        }

        # Final snapshot so a last sub-threshold chunk (or a file smaller
        # than 256KB/250ms, which never hit the throttle above at all) is
        # still reflected before the caller moves on to phase 'installing'.
        Write-ProgressStep -Total $ProgressTotal -Index $ProgressIndex -Addon $ProgressAddon -Phase 'downloading' -BytesDone $bytesDone -BytesTotal $bytesTotal
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Invoke-CfRequest {
    <#
      Performs one CurseForge HTTP request (JSON GET, or a file download
      when -OutFile is supplied). Retries once on HTTP 429/403 after a
      5 second wait. Always paces itself with a 300ms sleep so that
      consecutive calls (list or download) never fire back to back.

      -ProgressTotal/-ProgressIndex/-ProgressAddon (CS6) are forwarded to
      Invoke-HttpDownloadWithProgress for the -OutFile branch only, so the
      byte-level progress line can carry the same n-of-N context the
      caller's phase writes already use. Unused (and harmless, defaulted)
      for the plain JSON-GET branch.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$OutFile,
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        $ProgressAddon = $null
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
                Invoke-HttpDownloadWithProgress -Uri $Uri -Headers $headers -UserAgent $script:CfUserAgent -OutFile $OutFile -TimeoutSec 30 -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $ProgressAddon
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

function Test-FileHasGameVersionPrefix {
    <#
      FLAVORS-SPEC S4.4: was Test-FileHasGameVersion12 (literal "12."
      only) - now parameterized by -Prefix so the same check serves every
      flavour/era (e.g. "1.15." classic era, "5.5." Mists - S4.4's verified
      TypeId/prefix table). Default preserves the old literal exactly for
      every caller that doesn't pass -Prefix.
    #>
    param($File, [string]$Prefix = '12.')

    if (-not $File.gameVersions) {
        return $false
    }
    foreach ($g in $File.gameVersions) {
        if ($g -and $g.ToString().StartsWith($Prefix)) {
            return $true
        }
    }
    return $false
}

function Select-CfFile {
    <#
      Picks the best file from a CurseForge file list:
        1. The target flavour's TypeId (default 517, retail) with
           releaseType <= MaxReleaseType (the allowed channel ceiling: 1
           release only, 2 release+beta, 3 everything)
        2. The target flavour's TypeId, any release type
        3. Any file whose gameVersions has an entry starting with
           -VersionPrefix (default "12.")
        4. $null if nothing matches

      FLAVORS-SPEC S4.4: -TypeId/-VersionPrefix are resolved per flavour by
      the caller (Get-CfFlavourMapping, static for retail/classic_era,
      dynamic-from-Interface-number for classic via
      Resolve-ClassicProgressionTypeId) - defaults here preserve today's
      retail-only behaviour byte-for-byte for every existing call site.
    #>
    param(
        [Parameter(Mandatory = $true)]$Files,
        [int]$MaxReleaseType = 1,
        [int]$TypeId = 517,
        [string]$VersionPrefix = '12.'
    )

    foreach ($f in $Files) {
        if ((Test-FileHasTypeId -File $f -TypeId $TypeId) -and ($f.releaseType -le $MaxReleaseType)) {
            return $f
        }
    }
    foreach ($f in $Files) {
        if (Test-FileHasTypeId -File $f -TypeId $TypeId) {
            return $f
        }
    }
    foreach ($f in $Files) {
        if (Test-FileHasGameVersionPrefix -File $f -Prefix $VersionPrefix) {
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
    <#
      Downloads and verifies the selected file into staging; returns the
      zip path. -ProgressTotal/-ProgressIndex/-ProgressAddon (CS6) are
      passed straight through to Invoke-CfRequest for the byte-level
      progress writes; all optional/default to no-progress so a caller
      that omits them behaves exactly as before.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [Parameter(Mandatory = $true)]$SelectedFile,
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        $ProgressAddon = $null
    )

    $fileId = [int64]$SelectedFile.id
    $zipPath = Join-Path -Path $StagingPath -ChildPath ("{0}-{1}.zip" -f $ProjectId, $fileId)
    $downloadUri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files/$fileId/download"

    Invoke-CfRequest -Uri $downloadUri -OutFile $zipPath -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $ProgressAddon | Out-Null

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
# Wago Addons (E12) - a second, keyless addon source. Verified facts live
# in SPEC.md's "Wago Addons access facts" section. Mirrors the CurseForge
# HTTP helpers above closely (same pacing/retry shape) but is kept as its
# own self-contained block rather than interleaved with them, since the
# two sites speak genuinely different protocols (a plain files API vs.
# Inertia's version-handshake + X-Inertia-header JSON API).
# =====================================================================

function Invoke-WagoRequest {
    <#
      Performs one Wago HTTP request (a plain page GET, an X-Inertia JSON
      GET, or a file download when -OutFile is supplied). Retries once on
      HTTP 429/503 after a 5 second wait (Wago's documented retry codes -
      CurseForge's Invoke-CfRequest above retries on 429/403 instead).
      Always paces itself with a 300ms sleep, same as Invoke-CfRequest.

      -ProgressTotal/-ProgressIndex/-ProgressAddon (CS6): see the matching
      note on Invoke-CfRequest above; same forwarding, same no-op default.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers,
        [string]$OutFile,
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        $ProgressAddon = $null
    )

    $mergedHeaders = @{ 'Accept' = 'text/html, application/xhtml+xml' }
    if ($Headers) {
        foreach ($k in $Headers.Keys) { $mergedHeaders[$k] = $Headers[$k] }
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
                Invoke-HttpDownloadWithProgress -Uri $Uri -Headers $mergedHeaders -UserAgent $script:CfUserAgent -OutFile $OutFile -TimeoutSec 30 -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $ProgressAddon
                $result = $null
            } else {
                $result = Invoke-WebRequest -Uri $Uri -Headers $mergedHeaders -UserAgent $script:CfUserAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            }
        } catch {
            $lastError = $_
            $statusCode = Get-ExceptionStatusCode -ErrorRecord $_
            if (($statusCode -eq 429 -or $statusCode -eq 503) -and ($attempt -lt $maxAttempts)) {
                Write-Log -Level 'WARN' -Message "HTTP $statusCode from $Uri (Wago) - waiting 5 seconds and retrying"
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

function Get-WagoInertiaVersion {
    <#
      Reads the Inertia asset version out of a Wago page's plain HTML
      response (the #app element's data-page attribute is HTML-entity-
      encoded JSON carrying {version, component, props, url}). Returns
      {version; props} - the props are the SAME payload an X-Inertia
      request to this exact URI would return, so the first caller in a run
      can skip the extra XHR round-trip entirely.
    #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    $response = Invoke-WagoRequest -Uri $PageUri -Headers @{ 'Accept' = 'text/html, application/xhtml+xml' }
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

function Invoke-WagoInertiaRequest {
    <#
      Fetches one Wago page's props as pure JSON via the documented Inertia
      XHR protocol (X-Inertia / X-Inertia-Version / X-Requested-With
      headers). $script:WagoInertiaVersion caches the working version for
      the rest of this script run so repeated calls (e.g. an addon's
      details, then its releases) only pay the plain-HTML handshake once.
      A 409 response means the version changed server-side: re-read it from
      the plain HTML page and retry the Inertia request exactly once more,
      per SPEC's documented behaviour.
    #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    if (-not $script:WagoInertiaVersion) {
        $handshake = Get-WagoInertiaVersion -PageUri $PageUri
        $script:WagoInertiaVersion = $handshake.version
        return $handshake.props
    }

    $headers = @{
        'X-Inertia'         = 'true'
        'X-Inertia-Version' = $script:WagoInertiaVersion
        'X-Requested-With'  = 'XMLHttpRequest'
        'Accept'            = 'text/html, application/xhtml+xml'
    }

    try {
        $response = Invoke-WagoRequest -Uri $PageUri -Headers $headers
    } catch {
        $statusCode = Get-ExceptionStatusCode -ErrorRecord $_
        if ($statusCode -eq 409) {
            Write-Log -Level 'INFO' -Message "Wago Inertia version stale, refreshing ($PageUri)"
            $handshake = Get-WagoInertiaVersion -PageUri $PageUri
            $script:WagoInertiaVersion = $handshake.version
            $headers['X-Inertia-Version'] = $script:WagoInertiaVersion
            $response = Invoke-WagoRequest -Uri $PageUri -Headers $headers
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

function Get-WagoReleasesPage {
    <# One page of a Wago addon's release paginator (props.releases). #>
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [int]$Page = 1
    )

    $uri = "https://addons.wago.io/addons/$Slug/versions?page=$Page"
    $props = Invoke-WagoInertiaRequest -PageUri $uri
    if (-not $props -or -not $props.releases) {
        return $null
    }
    return $props.releases
}

function Get-WagoAllReleases {
    <#
      Walks every page of a Wago addon's release paginator and returns a
      flat List[object], newest first (the site's own default ordering).
      Capped at 10 pages (100 releases at 10/page) - more than enough to
      find any realistically recent file or a -FileId pin target, while
      keeping a single run's Wago request budget bounded.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [int]$MaxPages = 10
    )

    $all = New-Object 'System.Collections.Generic.List[object]'
    $page = 1
    while ($page -le $MaxPages) {
        $paginator = Get-WagoReleasesPage -Slug $Slug -Page $page
        if (-not $paginator -or -not $paginator.data) {
            break
        }
        foreach ($r in $paginator.data) { $all.Add($r) }
        if (-not $paginator.next_page_url) {
            break
        }
        $page++
    }
    Write-Output -NoEnumerate $all
}

function Get-WagoReleaseById {
    <# Finds one release by its (string) id among every page of releases. $null if not found within the page cap. #>
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [Parameter(Mandatory = $true)][string]$ReleaseId
    )

    $releases = Get-WagoAllReleases -Slug $Slug
    foreach ($r in $releases) {
        if ("$($r.id)" -eq $ReleaseId) {
            return $r
        }
    }
    return $null
}

function Get-WagoStabilityRank {
    <# stable=1, beta=2, anything else (alpha, unknown)=3 - mirrors CurseForge's releaseType 1/2/3 channel ceiling. #>
    param([string]$Stability)

    switch (([string]$Stability).ToLowerInvariant()) {
        'stable' { return 1 }
        'beta' { return 2 }
        default { return 3 }
    }
}

function Select-WagoRelease {
    <#
      Picks the newest release (list assumed newest-first, Wago's own
      paginator order) whose stability is allowed by MaxReleaseType (1
      stable, 2 stable+beta, 3 everything) AND whose
      supported_<WagoField>_patches is non-empty; falls back to the newest
      allowed-stability release regardless of patch list when nothing
      satisfies both. $null when nothing is allowed at all.

      FLAVORS-SPEC S4.6: -WagoField (default 'retail', preserving today's
      literal supported_retail_patches check byte-for-byte) is resolved per
      flavour by the caller via $Script:FlavourWagoField / Resolve-
      ClassicProgressionTypeId's WagoValue - 'classic_era' -> 'classic',
      classic's era resolved dynamically -> 'bc'|'wotlk'|'cata'|'mop'. Every
      Wago release object carries all six supported_*_patches keys
      regardless of which flavours it actually ships for - "supported"
      means non-empty array, never key presence alone.
    #>
    param(
        [Parameter(Mandatory = $true)]$Releases,
        [int]$MaxReleaseType = 1,
        [string]$WagoField = 'retail'
    )

    $propName = 'supported_{0}_patches' -f $WagoField
    foreach ($r in $Releases) {
        $patches = $r.$propName
        if (((Get-WagoStabilityRank -Stability $r.stability) -le $MaxReleaseType) -and $patches -and (@($patches).Count -gt 0)) {
            return $r
        }
    }
    foreach ($r in $Releases) {
        if ((Get-WagoStabilityRank -Stability $r.stability) -le $MaxReleaseType) {
            return $r
        }
    }
    return $null
}

function Get-WagoDownloadedZip {
    <#
      Downloads and verifies one Wago release's signed download link into
      staging; returns the zip path. -ProgressTotal/-ProgressIndex/
      -ProgressAddon (CS6): see Get-DownloadedZip's matching note; same
      forwarding, same no-op default.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        $ProgressAddon = $null
    )

    $releaseId = [string]$Release.id
    $safeSlug = ($Slug -replace '[^a-zA-Z0-9-]', '_')
    $zipPath = Join-Path -Path $StagingPath -ChildPath ("wago-{0}-{1}.zip" -f $safeSlug, $releaseId)

    if (-not $Release.download_link) {
        throw "Release $releaseId for wago:$Slug has no download_link"
    }
    Invoke-WagoRequest -Uri $Release.download_link -OutFile $zipPath -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $ProgressAddon | Out-Null

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "Download did not produce a file for wago:$Slug release $releaseId"
    }

    $downloadedItem = Get-Item -LiteralPath $zipPath
    if ($downloadedItem.Length -le 0) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Downloaded file is zero-length for wago:$Slug release $releaseId"
    }

    if ($Release.size) {
        $expectedLength = [int64]$Release.size
        if (($expectedLength -gt 0) -and ($downloadedItem.Length -ne $expectedLength)) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded file size mismatch for wago:$Slug release $releaseId (expected $expectedLength, got $($downloadedItem.Length))"
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
        # E12: an [int] CurseForge project id for a CurseForge record (unchanged
        # from before E12), or a "wago-<slug>" string backup key (Get-RecordBackupKey)
        # for a Wago one - only ever used here to name a scratch subfolder and in
        # log messages, so any value that stringifies sensibly works.
        [Parameter(Mandatory = $true)]$ProjectId,
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

function Get-TocXFlavorTag {
    <#
      FLAVORS-SPEC S4.5 point 1: reads a .toc's "## X-Flavor: <Tag>" line
      (confirmed real and machine-readable - values seen live: Mainline,
      Vanilla, TBC, Wrath, Cata, Mists, e.g. WeakAuras), trimmed, or $null
      when absent/unreadable. Never throws.
    #>
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
    <#
      Maps -Flavor (+, only for 'classic', -InstalledInterface) to one of
      $Script:TocEraSelectors' keys - S2.4's dynamic resolution for the
      rolling Classic client, static lookups for every other flavour.
    #>
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

function Get-PrimaryTocFile {
    <#
      Fix pass: picks the single .toc file WoW retail actually loads for one
      installed folder, out of however many game-flavor variants a package
      ships. Many multi-client addons (BigWigs and its bundled modules are
      the reproduction case that surfaced this) ship one .toc per client
      inside the SAME folder - a base "<folder>.toc" for one flavor (often
      NOT retail - e.g. a Cataclysm-Classic build) plus a "<folder>_Mainline.
      toc" (or "<folder>-Mainline.toc") specifically for retail, alongside
      "_Vanilla"/"_Wrath"/"_Cata"/"_Mists" siblings that are never relevant
      here.

      FLAVORS-SPEC S4.5: gains -Flavor (default 'retail') and
      -InstalledInterface (consulted only when -Flavor is 'classic', to
      resolve which rolling-progression era's .toc to prefer, S2.4).
      Selection order, primary signal first:
        1. Any .toc in the folder carrying "## X-Flavor: <Tag>" whose value
           matches the target flavour/era's tag - authoritative wherever
           present, regardless of filename.
        2. The target flavour/era's filename-suffix table
           ($Script:TocEraSelectors), in try-order.
        3. Bare "<FolderName>.toc" - owned by whichever of the three
           groups (Retail / Classic Era / Classic's rolling progression)
           is the SOLE one with no suffixed file present in this folder;
           bare defaults to Retail whenever that is not exactly one group
           (S4.5's caveat, implemented exactly - see the code comment
           below for the worked-through reasoning).
        4. First .toc file found (today's last-resort, unchanged).
      Returns a FileInfo, or $null when the folder has no .toc file at all.
      Never throws. Byte-identical to the pre-flavour selection for every
      existing retail call site (-Flavor defaults to 'retail', whose
      selector is exactly the old _Mainline/-Mainline/bare try-order).
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
    # Classic Era; Classic's rolling progression - tbc/wrath/cata/mists
    # collapsed into one "Classic" group for this determination, since a
    # package ships one bare/suffixed set regardless of which era is
    # currently live), scan which groups have a matching suffixed file
    # present in THIS folder, and only attribute the bare file to a
    # non-retail group when it is the SOLE unclaimed one of the three -
    # else bare always means retail (today's behaviour, unchanged for the
    # overwhelmingly common case: DBM-Core/Details/WeakAuras/AngryKeystones
    # all ship bare=retail alongside _Classic/_TBC/_Wrath/_Cata/_Mists
    # siblings, never the ambiguous case).
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
    foreach ($t in $tocFiles) {
        return $t
    }
    return $null
}

function Get-TocTitle {
    <#
      Reads the "## Title:" line from the primary .toc of a freshly
      installed addon (the folder whose primary .toc resolves via
      Get-PrimaryTocFile; when several folders qualify, the one with no
      underscore in its name wins). Strips WoW color codes. Returns $null if
      no title is found.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)]$Folders,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $tocByFolder = @{}
    foreach ($folderName in $Folders) {
        $folderPath = Join-Path -Path $AddonsPath -ChildPath $folderName
        $primaryToc = Get-PrimaryTocFile -FolderPath $folderPath -FolderName $folderName -Flavor $Flavor -InstalledInterface $InstalledInterface
        if ($primaryToc) {
            $candidates.Add($folderName)
            $tocByFolder[$folderName] = $primaryToc
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

    $chosenToc = $tocByFolder[$chosen]
    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $chosenToc.FullName -Encoding UTF8 -ErrorAction Stop
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
      own rather than as a group belonging to one known addon). Primary .toc
      selection is Get-PrimaryTocFile's (Mainline-first, else basename
      match, else first .toc found). Never throws; returns hasToc=$false
      when there is none.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    # E12: curseId/wagoId are additive - -Scan reports them per untracked
    # folder (from ## X-Curse-Project-ID / ## X-Wago-ID) so the UI can offer
    # one-click adoption from either source without the user having to look
    # the ids up manually.
    $result = [PSCustomObject]@{ title = $null; version = $null; hasToc = $false; curseId = $null; wagoId = $null }

    $folderLeaf = Split-Path -Path $FolderPath -Leaf
    $chosen = Get-PrimaryTocFile -FolderPath $FolderPath -FolderName $folderLeaf -Flavor $Flavor -InstalledInterface $InstalledInterface
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
        if ((-not $result.curseId) -and ($line -match '^\s*##\s*X-Curse-Project-ID\s*:\s*(.*)$')) {
            $v = $Matches[1].Trim()
            if ($v.Length -gt 0) { $result.curseId = $v }
        }
        if ((-not $result.wagoId) -and ($line -match '^\s*##\s*X-Wago-ID\s*:\s*(.*)$')) {
            $v = $Matches[1].Trim()
            if ($v.Length -gt 0) { $result.wagoId = $v }
        }
    }
    return $result
}

function Get-TocCrossSourceIds {
    <#
      E12: reads "## X-Curse-Project-ID:" and "## X-Wago-ID:" from the
      primary .toc of a freshly installed/updated PACKAGE (every folder of
      it, same Get-PrimaryTocFile selection rule as Get-TocTitle/
      Get-FolderTocInfo) - tried folder by folder, keeping the first
      non-empty value found for each tag, so a package whose main folder
      omits one tag but a library sub-folder carries it still gets it
      recorded. Called regardless of the record's own source: a
      CurseForge-sourced install can reveal it is ALSO on Wago (and vice
      versa) this way, feeding the UI's "Also on CurseForge/Wago"
      cross-link. Returns {curseId; wagoId} (both $null when neither tag is
      present or the folder/.toc is missing/unreadable); never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)]$Folders,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $curseId = $null
    $wagoId = $null
    foreach ($folderName in $Folders) {
        if ($curseId -and $wagoId) { break }
        $folderPath = Join-Path -Path $AddonsPath -ChildPath $folderName
        if (-not (Test-Path -LiteralPath $folderPath)) { continue }
        $chosen = Get-PrimaryTocFile -FolderPath $folderPath -FolderName $folderName -Flavor $Flavor -InstalledInterface $InstalledInterface
        if (-not $chosen) { continue }
        $lines = $null
        try {
            $lines = Get-Content -LiteralPath $chosen.FullName -Encoding UTF8 -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($line in $lines) {
            if ((-not $curseId) -and ($line -match '^\s*##\s*X-Curse-Project-ID\s*:\s*(.*)$')) {
                $v = $Matches[1].Trim()
                if ($v.Length -gt 0) { $curseId = $v }
            }
            if ((-not $wagoId) -and ($line -match '^\s*##\s*X-Wago-ID\s*:\s*(.*)$')) {
                $v = $Matches[1].Trim()
                if ($v.Length -gt 0) { $wagoId = $v }
            }
        }
    }
    return [PSCustomObject]@{ curseId = $curseId; wagoId = $wagoId }
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
        # E12: an [int] CurseForge project id (unchanged), or a "wago-<slug>"
        # backup key (Get-RecordBackupKey) for a Wago record - see
        # Install-AddonPackage's identical -ProjectId note above.
        [Parameter(Mandatory = $true)]$ProjectId,
        # E12: was [int64] - a Wago release id (e.g. "r6p5g7zQ") is a string,
        # not parseable as int64, so this is untyped and stringified below.
        [Parameter(Mandatory = $true)]$FileId,
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
            # E12: was [string][int64]$PreviousFileId - a Wago release id
            # string isn't int64-parseable, and plain [string] round-trips a
            # CurseForge int64 identically (same digits either way), so the
            # cast is simply dropped rather than branched on source.
            [void]$keepIds.Add([string]$PreviousFileId)
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
        [switch]$DryRun,
        # FLAVORS-SPEC S4: which installed client this rollback's re-parsed
        # dependency/cross-source-id reads target (default 'retail'
        # preserves today's only code path byte-for-byte).
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    # E12: source-generic identity key for backup-folder/staging paths and log
    # messages - the numeric CurseForge project id for a CurseForge record
    # (identical to the pre-E12 $projectId in every way, including its string
    # form), or "wago-<slug>" for a Wago one, which has no numeric project id
    # at all.
    $backupKey = Get-RecordBackupKey -Record $Record
    $displayLabel = $Record.name
    if (-not $displayLabel) {
        $displayLabel = "project $backupKey"
    }

    if (-not $Record.previousFileId) {
        Write-Log -Level 'WARN' -Message "Rollback: project $backupKey ($displayLabel) has no previous version on record"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    # E12: was [int64]$Record.previousFileId - a Wago release id string isn't
    # int64-parseable, and this value is only ever used to build a zip
    # filename / assigned back onto the record, neither of which needs the
    # numeric type, so the cast is dropped rather than branched on source.
    $prevFileId = $Record.previousFileId
    $zipPath = Join-Path -Path (Join-Path -Path $BackupsRoot -ChildPath $backupKey) -ChildPath ("{0}.zip" -f $prevFileId)
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Log -Level 'WARN' -Message "Rollback: backup zip missing for project $backupKey ($displayLabel) fileId $prevFileId"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    if ($DryRun) {
        Write-Log -Level 'INFO' -Message "DryRun: would roll back project $backupKey ($displayLabel) to fileId $prevFileId"
        return [PSCustomObject]@{ Status = 'Would-update'; Name = $displayLabel; Version = $Record.previousVersion; FileId = $prevFileId }
    }

    try {
        $newFolders = Install-AddonPackage -ZipPath $zipPath -ProjectId $backupKey -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders
    } catch {
        Write-Log -Level 'ERROR' -Message "Rollback failed installing backup for project $backupKey ($displayLabel) : $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version }
    }

    if ($newFolders.Count -eq 0) {
        Write-Log -Level 'ERROR' -Message "Rollback produced zero usable folders for project $backupKey ($displayLabel)"
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
    $rollbackDeps = Get-PackageDependencies -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
    $Record.requiredDeps = $rollbackDeps.required
    $Record.optionalDeps = $rollbackDeps.optional

    # E12: cross-source ids (curseId/wagoId) are likewise recomputed from the
    # RESTORED folder's .toc rather than left over from the version rolled
    # back from - same "always re-derive from what's actually on disk now"
    # treatment as requiredDeps/optionalDeps just above.
    $rollbackTocIds = Get-TocCrossSourceIds -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
    $Record.curseId = $rollbackTocIds.curseId
    $Record.wagoId = $rollbackTocIds.wagoId

    Write-Log -Level 'INFO' -Message "Rolled back project $backupKey ($displayLabel) to fileId $prevFileId"
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
      Reads dependency tags from one installed folder's primary .toc
      (Get-PrimaryTocFile's Mainline-first selection, same rule as
      Get-FolderTocInfo/Get-TocTitle). "## Dependencies:" and
      "## RequiredDeps:" are treated as synonyms for the required list (both
      are used in the wild for the same purpose); "## OptionalDeps:" feeds
      the optional list. Tag names are matched case-insensitively (-match's
      default). Never throws; returns two empty lists when the folder has no
      .toc, the .toc can't be read, or no matching tag is present.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $result = [PSCustomObject]@{
        required = New-Object 'System.Collections.Generic.List[object]'
        optional = New-Object 'System.Collections.Generic.List[object]'
    }

    $folderPath = Join-Path -Path $AddonsPath -ChildPath $FolderName
    if (-not (Test-Path -LiteralPath $folderPath)) {
        return $result
    }

    $chosen = Get-PrimaryTocFile -FolderPath $folderPath -FolderName $FolderName -Flavor $Flavor -InstalledInterface $InstalledInterface
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
        [Parameter(Mandatory = $true)]$Folders,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
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
        $deps = Get-TocDependencies -AddonsPath $AddonsPath -FolderName $folderName -Flavor $Flavor -InstalledInterface $InstalledInterface
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
# Compatibility audit (E13) - is an installed addon valid for the current
# game patch/season? Two independent, additive evidence sources feed the
# verdict: the installed folders' own declared .toc Interface number(s)
# (live, re-read from disk every time - never stored), and the newest known
# CurseForge/Wago file's declared game-version strings (persisted on the
# record as latestGameVersions/latestFileDate, since getting that requires a
# network call the read-only -Status path never makes). The client's own
# build/Interface number comes from .build.info, read once per run.
# =====================================================================

function Get-TocInterfaceValues {
    <#
      Reads "## Interface:" / "## Interface-Mainline:" tag values from one
      folder's primary .toc (Get-PrimaryTocFile's Mainline-first selection,
      same rule as Get-TocDependencies) into a list of int64s - values are
      comma/space separated (reuses Split-TocDepList), non-numeric tokens
      dropped. Never throws; empty list when the folder/.toc is missing,
      unreadable, or has neither tag.

      Fix pass: a single base .toc can declare BOTH "## Interface:" (its own
      native client - e.g. a Cataclysm-Classic build) and "## Interface-
      Mainline:" (an explicit retail override - WoW's documented
      multi-toc-in-one-file convention). When the CHOSEN file has any
      "## Interface-Mainline:" line(s), those win outright and the plain
      "## Interface:" line(s) in that same file are ignored entirely (they
      describe a different client, not an additional retail value to union
      in) - previously both were unioned together indiscriminately, which
      could report a non-retail Interface number as if it were retail's own.

      FLAVORS-SPEC S4.5: gains -Flavor (default 'retail') and
      -InstalledInterface, threaded into Get-PrimaryTocFile so the correct
      per-flavour file is read. The "## Interface-Mainline:" override tag
      is a documented RETAIL-specific convention - it is only consulted
      when -Flavor is 'retail' (byte-identical to today for every existing
      caller); no confirmed real sample of an equivalent non-retail
      override tag exists (S4.5's own flagged-unconfirmed note), so a
      non-retail request reads that file's own plain "## Interface:" line
      only - already correct, because Get-PrimaryTocFile already picked
      THAT flavour's own file.
    #>
    param(
        # Not Mandatory (unlike Get-TocDependencies' identical-shaped param) -
        # -Status may call this with an unresolvable AddOns path ($null),
        # which a Mandatory [string] parameter would reject outright (a
        # parameter-binding error on an explicit $null argument, distinct
        # from simply omitting it) rather than degrading gracefully.
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
                if ([int64]::TryParse($piece, [ref]$ival)) {
                    $mainlineValues.Add([int64]$ival)
                }
            }
        } elseif ($line -match '^\s*##\s*Interface\s*:\s*(.*)$') {
            foreach ($piece in (Split-TocDepList -Value $Matches[1])) {
                $ival = [int64]0
                if ([int64]::TryParse($piece, [ref]$ival)) {
                    $plainValues.Add([int64]$ival)
                }
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
    <# Unions Get-TocInterfaceValues across every folder of a package, deduped (order preserved, first-seen wins). #>
    param(
        # Not Mandatory - see Get-TocInterfaceValues's own note; this simply
        # forwards whatever it receives (including $null) to that function,
        # which already degrades to an empty result for it.
        [string]$AddonsPath,
        $Folders,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[int64]'
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($folderName in $Folders) {
        $vals = Get-TocInterfaceValues -AddonsPath $AddonsPath -FolderName $folderName -Flavor $Flavor -InstalledInterface $InstalledInterface
        foreach ($v in $vals) {
            if ($seen.Add([int64]$v)) {
                $result.Add([int64]$v)
            }
        }
    }
    Write-Output -NoEnumerate $result
}

function Get-DefaultBuildInfoPath {
    <#
      .build.info sits next to the game's per-version root, one level above
      the retail/classic install it describes - i.e. three levels up from
      <root>\_retail_\Interface\AddOns (AddOns -> Interface -> _retail_ ->
      the WoW folder .build.info actually lives in). $null when
      AddonsPathResolved is $null/empty or too shallow to have three parents.
    #>
    param([string]$AddonsPathResolved)

    if (-not $AddonsPathResolved) {
        return $null
    }
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

function ConvertTo-InterfaceNumber {
    <#
      Shared by Get-ClientBuildInfo and Get-InstalledFlavours: a version
      string "12.1.0.69587" -> Interface number 120100 (major*10000 +
      minor*100 + patch). $null when unparsable or fewer than 3 dot-parts.
    #>
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
    <#
      Parses every data row of a pipe-delimited, typed-header .build.info
      file (S2.2/S8's exact confirmed format) into {Product; Version}
      objects. Empty list when the file is missing, unreadable, has no
      header, or the header lacks Product/Version columns. Never throws.
    #>
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

function Get-FlavourDef {
    <# Looks up one $Script:FlavourDefs entry by id. $null when unrecognized. #>
    param([Parameter(Mandatory = $true)][string]$Id)

    foreach ($def in $Script:FlavourDefs) {
        if ($def.Id -eq $Id) { return $def }
    }
    return $null
}

function Resolve-ClassicProgressionTypeId {
    <#
      FLAVORS-SPEC S2.4: _classic_ is a rolling progression client (Vanilla
      -> TBC -> Wrath -> Cataclysm -> Mists, and it will advance again) -
      never hardcode "Classic = <current expansion>". Resolves the live
      era from the installed client's own Interface number (same
      major*10000+minor*100+patch encoding ConvertTo-InterfaceNumber/
      Get-ClientBuildInfo already produce) against this appendable range
      table - appending one row (new Interface prefix, new TypeId once
      CurseForge assigns one, new Wago value) is the ONLY code change a
      future expansion bump needs. Falls back to Retail's row (517/retail)
      when Interface is $null/0 or matches no known range - the safe
      default S4.4's Resolve-CfTypeId also uses for ptr/xptr/beta.
    #>
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
        # Security-review fix: a REAL, non-zero Interface that matches no
        # known range is NOT the same as a missing/unreadable .build.info -
        # it means a future Classic expansion bump this table simply
        # doesn't cover yet. Returning Retail's TypeId/WagoValue here (as
        # this function used to) let a Classic client's addon installs
        # silently pick/install Retail-tagged files. Callers MUST treat
        # EraKey='unknown' as a hard failure, not a usable mapping.
        return [PSCustomObject]@{ EraKey = 'unknown'; EraLabel = 'Unrecognized Classic client version'; TypeId = $null; WagoValue = $null; VersionPrefix = $null }
    }
    # Unresolvable because the build info itself is missing/unreadable
    # (Interface null or 0) - safe fallback, never a fatal error (S2.2/S4.4).
    return [PSCustomObject]@{ EraKey = 'retail'; EraLabel = 'Retail'; TypeId = 517; WagoValue = 'retail'; VersionPrefix = '12.' }
}

function Resolve-CfTypeId {
    <# FLAVORS-SPEC S4.4's exact resolver. #>
    param([string]$Flavor, $InstalledInterface = $null)

    switch ($Flavor) {
        'retail'      { return 517 }
        'classic_era' { return 67408 }
        'classic'     { return (Resolve-ClassicProgressionTypeId -Interface $InstalledInterface).TypeId }
        default       { return 517 }  # ptr/xptr/beta default to retail's TypeId, unconfirmed but safe (S2.5)
    }
}

function Get-CfFlavourMapping {
    <#
      Centralizes S4.4 (CurseForge TypeId + gameVersions prefix) and S4.6
      (Wago game_version field) for one -Flavor (+, for 'classic', its
      resolved progression era). Returns {TypeId; VersionPrefix; WagoField;
      EraLabel}. Defaults (retail) match today's only code path exactly.
    #>
    param([string]$Flavor = 'retail', $InstalledInterface = $null)

    switch ($Flavor) {
        'retail'      { return [PSCustomObject]@{ TypeId = 517; VersionPrefix = '12.'; WagoField = 'retail'; EraLabel = 'Retail'; EraKey = 'retail' } }
        'classic_era' { return [PSCustomObject]@{ TypeId = 67408; VersionPrefix = '1.15.'; WagoField = 'classic'; EraLabel = 'Classic Era (Vanilla)'; EraKey = 'classic_era' } }
        'classic' {
            # Security-review fix: $prog.EraKey now propagates through
            # (including the 'unknown' sentinel) so every caller can check
            # $mapping.EraKey -eq 'unknown' rather than only inferring
            # failure from a null TypeId.
            $prog = Resolve-ClassicProgressionTypeId -Interface $InstalledInterface
            return [PSCustomObject]@{ TypeId = $prog.TypeId; VersionPrefix = $prog.VersionPrefix; WagoField = $prog.WagoValue; EraLabel = $prog.EraLabel; EraKey = $prog.EraKey }
        }
        default { return [PSCustomObject]@{ TypeId = 517; VersionPrefix = '12.'; WagoField = 'retail'; EraLabel = 'Retail'; EraKey = 'retail' } }
    }
}

function Get-InstalledFlavours {
    <#
      FLAVORS-SPEC S2.3: returns the WoW client flavours actually present
      under $WowRoot, in S2.1's fixed order - {id; folder; label;
      addonsPath; clientBuild; clientInterface; buildInfoRow;
      buildInfoMissing}. "Installed" (S2.2) means <WowRoot>\<folder>\
      Interface\AddOns exists (need not contain any addon yet). .build.info
      is corroboration only, never load-bearing for the installed/not
      decision - a missing/stale/unreadable .build.info, or no row whose
      Product matches, never hides an otherwise-detected flavour;
      buildInfoMissing is set instead. Never throws.

      -WowRoot, when given, is used as-is (CLI/test override - S8's fixture
      path included). Omitted, it is resolved by walking up from
      -ScriptRoot (default $PSScriptRoot) the way Resolve-AddonsPath
      already does, generalized from "parent leaf must be _retail_" to
      "parent leaf must be one of S2.1's known flavour folder names" - this
      is what unblocks a Classic-only machine (no _retail_ at all).
      Returns @() only when $WowRoot can't be resolved at all (caller's
      existing fatal exit-code-2 path is unchanged by this).
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

    # S2.6: generic fallback for an unrecognized folder that still looks
    # like a WoW client (Interface\AddOns present + an unclaimed
    # .build.info Product row) - surfaced as an Unknown flavour. Disabling
    # it by default (S2.5/2.6's toggle) is a UI/server concern; this
    # function only ever reports detection.
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

function Get-ClientBuildInfo {
    <#
      Reads the WoW client's build/version from .build.info (pipe-separated;
      header row names columns including "Product" and "Version"). Returns
      {clientBuild (string, e.g. "12.1.0.69587"); clientInterface (int,
      major*10000 + minor*100 + patch, e.g. 120100)} - both $null when the
      file is missing, unreadable, has no header, no matching row, or an
      unparsable Version. Never throws.

      FLAVORS-SPEC S4.3: gains -Flavor (default 'retail') and -Product; the
      row whose Product matches -Product (or, when omitted, -Flavor's own
      S2.1 mapping - 'wow' for retail, unchanged from today's hardcode) is
      the one that matters. Other rows are ignored.
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
    if (-not $lines -or $lines.Count -lt 2) {
        return $result
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
        return $result
    }

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

function Get-AddonCompat {
    <#
      Classifies one addon's compatibility with the current client build.
      TocInterfaces (int64[], live-parsed from the folders actually on disk)
      and LatestGameVersions (string[] "major.minor.patch" strings, from the
      record's own persisted latest-known-file metadata) are both optional,
      independent evidence sources - either alone can prove "ok".
        ok           - a toc Interface matches ClientInterface exactly, OR a
                       latest-file game-version string equals the client's
                       own major.minor.patch.
        stale-minor  - some evidence shares the client's major version but
                       nothing matches exactly (e.g. 12.0.x when the client
                       is on 12.1.x).
        stale        - there is evidence, but none of it shares the client's
                       major version at all.
        unknown      - ClientInterface is unknown (no .build.info), or there
                       is no evidence at all (no toc Interface tag and no
                       recorded latestGameVersions).
      Never throws; an individual unparsable entry is skipped rather than
      failing the whole classification.
    #>
    param(
        $TocInterfaces,
        $LatestGameVersions,
        $ClientInterface
    )

    if (-not $ClientInterface) {
        return 'unknown'
    }
    $clientInterfaceInt = [int64]$ClientInterface
    $clientMajor = [int]([math]::Floor($clientInterfaceInt / 10000))
    $clientMinor = [int]([math]::Floor(($clientInterfaceInt % 10000) / 100))
    $clientPatch = [int]($clientInterfaceInt % 100)
    $clientVersionText = "$clientMajor.$clientMinor.$clientPatch"

    $hasEvidence = $false
    $sameMajor = $false

    # Plain foreach, not @($TocInterfaces)/@($LatestGameVersions) - the
    # documented machine quirk: @() wrapped around a variable whose runtime
    # type is System.Collections.Generic.List[object] (TocInterfaces is
    # exactly that, from Get-PackageTocInterfaces) throws "Argument types do
    # not match". Plain foreach handles $null (zero iterations), a
    # List[object], and a plain array identically, with no such hazard.
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
            if ([int]::TryParse($gvParts[0], [ref]$gvMajor) -and ($gvMajor -eq $clientMajor)) {
                $sameMajor = $true
            }
        }
    }

    if (-not $hasEvidence) {
        return 'unknown'
    }
    if ($sameMajor) {
        return 'stale-minor'
    }
    return 'stale'
}

function Get-AddonCompatFields {
    <#
      Live per-record decoration for the -Json addons[] array (both -Status's
      and a plain sync/check run's) - tocInterfaces (from the folders
      currently on disk) and compat (from those plus the record's persisted
      latestGameVersions). Never stored back to addons.json; recomputed on
      every call, the same "computed live" contract missingDeps already has.
    #>
    param(
        [Parameter(Mandatory = $true)]$Item,
        # Not Mandatory - see Get-TocInterfaceValues's own note; -Status can
        # reach here with an unresolvable AddOns path ($null).
        [string]$AddonsPath,
        $ClientInterface,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $tocIfaces = Get-PackageTocInterfaces -AddonsPath $AddonsPath -Folders $Item.folders -Flavor $Flavor -InstalledInterface $InstalledInterface
    $compat = Get-AddonCompat -TocInterfaces $tocIfaces -LatestGameVersions $Item.latestGameVersions -ClientInterface $ClientInterface
    return [PSCustomObject]@{ tocInterfaces = $tocIfaces.ToArray(); compat = $compat }
}

function Add-CompatFieldsToAddonClone {
    <#
      Clones one addon record (same generic PSObject.Properties copy pattern
      -Status already uses for missingDeps/missingOptionalDeps) and adds
      tocInterfaces/compat to it. Shared by -Status and the main run's -Json
      "addons" output so both decorate identically.
    #>
    param(
        [Parameter(Mandatory = $true)]$Item,
        # Not Mandatory - see Get-TocInterfaceValues's own note.
        [string]$AddonsPath,
        $ClientInterface,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $compatFields = Get-AddonCompatFields -Item $Item -AddonsPath $AddonsPath -ClientInterface $ClientInterface -Flavor $Flavor -InstalledInterface $InstalledInterface
    $clone = [PSCustomObject]@{}
    foreach ($p in $Item.PSObject.Properties) {
        $clone | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value
    }
    $clone | Add-Member -MemberType NoteProperty -Name 'tocInterfaces' -Value $compatFields.tocInterfaces
    $clone | Add-Member -MemberType NoteProperty -Name 'compat' -Value $compatFields.compat
    return $clone
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
        source            = 'curseforge'
        wagoId            = $null
        slug              = $null
        curseId           = $null
        latestGameVersions = @()
        latestFileDate     = $null
    }
}

function New-WagoAddonRecord {
    <#
      E12: the Wago counterpart to New-AddonRecord above. A Wago addon has no
      numeric CurseForge project id, so projectId stays $null (the field
      every pre-E12 piece of code keys record identity on) and slug becomes
      the record's stable identity instead - it is whatever the user/CLI
      caller supplied ("wago:<slug>", "wago:<id>", or a wago URL's path
      segment - see ConvertTo-TargetToken), used verbatim as the Wago site's
      URL path segment for every subsequent request, with no separate
      slug-vs-id resolution step. Built on New-AddonRecord (ProjectId 0, an
      otherwise-unused placeholder immediately overwritten below) so every
      field this codebase's other 90% assumes every record carries stays in
      sync with it automatically.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Slug
    )

    $rec = New-AddonRecord -ProjectId 0
    $rec.projectId = $null
    $rec.source = 'wago'
    $rec.slug = $Slug
    return $rec
}

function Initialize-AddonRecordFields {
    <#
      Ensures a record (possibly loaded from an older addons.json that
      predates author/ignoreUpdates/pinnedFileId/releaseType/previousFileId/
      previousVersion/previousFileName/requiredDeps/optionalDeps/source/
      wagoId/slug/curseId) has every one of those properties present, adding
      whichever are missing with their null/false/empty-array/'curseforge'
      default and leaving any existing value untouched. PSCustomObject
      dot-assignment throws on a property that does not already exist, so
      every record must be normalized before any code path tries to set
      these fields. source defaults to 'curseforge' (not $null) - a record
      with no source field at all necessarily predates E12, and every record
      that predates E12 is a CurseForge one (Wago did not exist as a source
      before this expansion).
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
    if (-not (Get-Member -InputObject $Record -Name 'source' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'source' -NotePropertyValue 'curseforge'
    }
    if (-not (Get-Member -InputObject $Record -Name 'wagoId' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'wagoId' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'slug' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'slug' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'curseId' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'curseId' -NotePropertyValue $null
    }
    # E13 (compatibility audit): the newest file's declared game-version
    # strings + the date it was seen, captured whenever a real (non-DryRun)
    # sync/check actually fetches file metadata - see Sync-SingleAddon /
    # Sync-SingleWagoAddon. Optional/absence-tolerant like every field above.
    if (-not (Get-Member -InputObject $Record -Name 'latestGameVersions' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'latestGameVersions' -NotePropertyValue @()
    }
    if (-not (Get-Member -InputObject $Record -Name 'latestFileDate' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'latestFileDate' -NotePropertyValue $null
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
            port               = $defaults.port
        }
        if ($null -ne $parsed.releaseType) {
            $result.releaseType = [int]$parsed.releaseType
        }
        if ($null -ne $parsed.autoUpdateOnLaunch) {
            $result.autoUpdateOnLaunch = [bool]$parsed.autoUpdateOnLaunch
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

function Get-StateUpdatesCheckedAtMinutesAgo {
    <#
      P1 perf pass (item 5, launch-chain cap): read-only lookup of "how many
      minutes ago was this flavour's updatesCheckedAt", from the SHARED
      ROOT\state.json addon-server.ps1 writes (see that script's
      Save-CheckState/Load-CheckState) - never written by this script.
      Returns $null when the file is missing/corrupt/has no usable
      timestamp for this flavour (an unresolvable "never checked" answer
      must never be mistaken for "just checked"). Tolerates both the
      current per-flavour object shape ({retail: "...", classic: "..."})
      and the pre-flavour flat-string shape (a bare ISO string, treated as
      the 'retail' bucket) the same way Load-CheckState does. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Flavor
    )

    $statePath = Join-Path -Path $RootPath -ChildPath 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $obj.updatesCheckedAt) { return $null }

        $iso = $null
        if ($obj.updatesCheckedAt -is [string]) {
            if ($Flavor -eq 'retail') { $iso = [string]$obj.updatesCheckedAt }
        } else {
            foreach ($p in $obj.updatesCheckedAt.PSObject.Properties) {
                if ($p.Name -eq $Flavor) { $iso = [string]$p.Value; break }
            }
        }
        if ([string]::IsNullOrWhiteSpace($iso)) { return $null }

        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $checkedAt = [DateTime]::Parse($iso, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return ((Get-Date).ToUniversalTime() - $checkedAt).TotalMinutes
    } catch {
        return $null
    }
}

function Save-LauncherUpdatesCheckedAt {
    <#
      P1 perf pass follow-up: addon-sync.ps1 previously never wrote the
      shared updatesCheckedAt timestamp it reads (Get-Stat-
      eUpdatesCheckedAtMinutesAgo above) - only addon-server.ps1's
      Complete-Job did, so a plain -Launcher run (no tray/server involved)
      got no skip protection on a second launch seconds later, contradicting
      the 10-minute-skip feature's own documented "checked by ANY means"
      justification. This stamps THIS flavour's bucket with the current UTC
      time, read-merge-write against ROOT\state.json so every other field
      addon-server.ps1 owns (updateAvailable/lastRun/jobs/
      wagoInertiaVersion) survives untouched - a concurrent server write
      lost to this last-writer-wins race is the same accepted risk
      Save-Config already carries for addons.json. Tolerates both the
      current per-flavour object shape and the pre-flavour flat-string
      shape (upgrades it to a per-flavour object, preserving the old value
      under 'retail') the same way Load-CheckState does. Best-effort: a
      write failure is logged, never thrown - this must not turn a
      completed -Launcher sync into a launch failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Flavor
    )

    $statePath = Join-Path -Path $RootPath -ChildPath 'state.json'
    try {
        $obj = $null
        if (Test-Path -LiteralPath $statePath) {
            $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            }
        }
        if (-not $obj) {
            $obj = [PSCustomObject]@{}
        }

        $map = @{}
        if ($null -ne $obj.updatesCheckedAt) {
            if ($obj.updatesCheckedAt -is [string]) {
                $map['retail'] = [string]$obj.updatesCheckedAt
            } else {
                foreach ($p in $obj.updatesCheckedAt.PSObject.Properties) {
                    $map[$p.Name] = [string]$p.Value
                }
            }
        }
        $map[$Flavor] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        if (Get-Member -InputObject $obj -Name 'updatesCheckedAt' -MemberType NoteProperty) {
            $obj.updatesCheckedAt = $map
        } else {
            $obj | Add-Member -MemberType NoteProperty -Name 'updatesCheckedAt' -Value $map
        }

        $json = ConvertTo-Json -InputObject $obj -Depth 8
        $tmpPath = "$statePath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $statePath -Force
    } catch {
        Write-Log -Level 'WARN' -Message "Failed to persist updatesCheckedAt to state.json: $($_.Exception.Message)"
    }
}

function Test-LauncherBudgetExceeded {
    <#
      P1 perf pass (item 5, launch-chain cap): pure, deterministic core of
      the -Launcher wall-clock budget check - true once -Now is at least
      -BudgetSeconds past -StartTime. Kept as its own small function
      (rather than inlined into the per-addon loop) specifically so it can
      be unit tested with synthetic timestamps instead of a real 40-second
      wait.
    #>
    param(
        [Parameter(Mandatory = $true)][DateTime]$StartTime,
        [Parameter(Mandatory = $true)][int]$BudgetSeconds,
        [DateTime]$Now = (Get-Date)
    )

    return (($Now - $StartTime).TotalSeconds -ge $BudgetSeconds)
}

# =====================================================================
# Path resolution
# =====================================================================

function Resolve-AddonsPath {
    <#
      Returns the effective AddOns path. If -Provided is set it wins.
      Otherwise, if ScriptRoot looks like <X>\<flavour-folder>\AddonSync,
      returns <X>\<folder-for-Flavor>\Interface\AddOns. Otherwise returns
      $null (caller must treat that as a fatal configuration error).

      FLAVORS-SPEC S4.2: gains -Flavor (default 'retail') and -WowRoot.
      -WowRoot, when given, is used directly (S8's fixture path) instead of
      walking up from -ScriptRoot. The walk-up itself is generalized from
      "parent leaf must equal _retail_" to "parent leaf must be one of
      S2.1's known flavour folder names" (S2.3 point 1) - this machine's
      own default call (-Flavor omitted -> 'retail', -WowRoot omitted)
      resolves byte-identically to before, since _retail_ is one of those
      six names and the folder joined is still the one -Flavor names.
    #>
    param(
        [string]$Provided,
        [string]$ScriptRoot,
        [string]$Flavor = 'retail',
        [string]$WowRoot
    )

    if ($Provided -and ($Provided.Trim().Length -gt 0)) {
        return $Provided
    }

    $def = Get-FlavourDef -Id $Flavor
    if (-not $def) {
        return $null
    }

    $resolvedWowRoot = $WowRoot
    if (-not $resolvedWowRoot -or $resolvedWowRoot.Trim().Length -eq 0) {
        $leaf = Split-Path -Path $ScriptRoot -Leaf
        $parentDir = Split-Path -Path $ScriptRoot -Parent
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

function Get-MigrationHomeFlavour {
    <#
      Which flavours\<id>\ subfolder this AddonSync install's own pre-
      flavour top-level addons.json/state.json/backups belong under -
      derived the same way Resolve-AddonsPath's ScriptRoot walk-up
      resolves a flavour folder name, from $RootPath's OWN parent (RootPath
      IS the AddonSync folder, e.g. <WowRoot>\_retail_\AddonSync - its
      parent is <WowRoot>\_retail_). Falls back to 'retail' when
      unresolvable (e.g. a standalone copy of this folder used for a
      migration-rehearsal test, S8) - matches S3.3's own worked example.
    #>
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
      flavours\<homeFlavour>\. Runs once at CLI/server startup, before any
      path resolution (Main calls this before computing $script:ConfigPath
      etc.). Never throws - every step is best-effort and logged; Main
      wraps this call in its own try/catch as an extra safety net.

      Steps (exactly S3.3):
        1. Read settings.json's schemaVersion. Absent or 1 = pre-flavour;
           >= 2 = already migrated - immediate no-op (this is the primary
           idempotency guard for an already-completed migration).
        2. Create flavours\<homeFlavour>\ if pre-flavour.
        3. BEFORE moving anything, copy (not move) addons.json/state.json/
           backups\ into flavours\_migration-backup-<timestamp>\ - but only
           when no such backup folder already exists. This second,
           independent guard (rather than relying on schemaVersion alone)
           is what keeps a crash-and-retry mid-move from ever creating a
           SECOND backup folder: schemaVersion is only set in step 5,
           AFTER every move succeeds, so a retry after a mid-move crash
           still sees schemaVersion 1 and would otherwise re-copy.
        4. Move each item, guarded individually by Test-Path on the
           DESTINATION - an item already landed in flavours\<homeFlavour>\
           is left untouched (retry-safe: never overwrites an already-
           landed file with stale content, never re-moves what moved fine).
        5. Set schemaVersion: 2 in settings.json only after every move in
           step 4 completed without an exception escaping this far.
        6/7 (list the backup folder in Settings > Advanced; documented
           rollback) are UI/doc concerns, not this function's.
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
            Write-Log -Level 'WARN' -Message "Flavour migration: failed to read settings.json, treating as pre-flavour: $($_.Exception.Message)"
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

    # Step 3: copy-first backup - guarded by "does a backup folder already
    # exist", independent of schemaVersion (see doc comment above for why).
    # Also skipped entirely when there is nothing at the top level to
    # migrate at all (a brand-new install, never previously synced) - no
    # data to protect, so no empty backup-folder cruft is left behind.
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
            Write-Log -Level 'INFO' -Message "Flavour migration: pre-move backup copied to $backupDir"
        } catch {
            Write-Log -Level 'ERROR' -Message "Flavour migration: failed to create pre-move backup: $($_.Exception.Message)"
        }
    }

    # Step 4: move, each item guarded individually by the DESTINATION
    # already existing (retry-safe across a crash mid-move).
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
                Write-Log -Level 'INFO' -Message "Flavour migration: moved $name into $homeFlavourDir"
            } catch {
                $moveOk = $false
                Write-Log -Level 'ERROR' -Message "Flavour migration: failed to move $name into $homeFlavourDir : $($_.Exception.Message)"
            }
        }
    }

    if (-not $moveOk) {
        # Never stamp schemaVersion 2 on a partial migration - the next run
        # retries the still-missing item(s) (step 4's per-item guard makes
        # this safe), never both moving AND still being treated as v1 for
        # some item that already truly landed.
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
        Write-Log -Level 'INFO' -Message 'Flavour migration: schemaVersion set to 2'
    } catch {
        Write-Log -Level 'ERROR' -Message "Flavour migration: failed to write schemaVersion to settings.json: $($_.Exception.Message)"
    }
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
        [switch]$ExplicitTarget,
        # CS1: caller-supplied n-of-N context for Write-ProgressStep. The
        # main loop already knows Total/Index (it owns the loop counter);
        # this function only ever writes the downloading/installing
        # sub-phases for the single addon it is currently processing, so it
        # needs those two numbers handed in rather than recomputing them.
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        # FLAVORS-SPEC S4: which installed client this sync targets (default
        # 'retail' preserves today's only code path byte-for-byte).
        # -InstalledInterface only matters for -Flavor 'classic' (S2.4's
        # dynamic progression resolution).
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    # E12: a Wago-sourced record is processed by its own function rather
    # than threading source-specific branches through the CurseForge logic
    # below - see Sync-SingleWagoAddon's own doc comment for why. Every
    # caller of Sync-SingleAddon (the main sync loop) is unchanged; this
    # dispatch is the only new code path they see.
    if ($Record.source -eq 'wago') {
        return Sync-SingleWagoAddon -Record $Record -AddonsPath $AddonsPath -StagingPath $StagingPath -BackupsPath $BackupsPath -Force:$Force -DryRun:$DryRun -DefaultMaxReleaseType $DefaultMaxReleaseType -FileIdOverride $FileIdOverride -ExplicitTarget:$ExplicitTarget -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -Flavor $Flavor -InstalledInterface $InstalledInterface
    }

    $cfMapping = Get-CfFlavourMapping -Flavor $Flavor -InstalledInterface $InstalledInterface

    $projectId = [int]$Record.projectId
    $displayLabel = $Record.name
    if (-not $displayLabel) {
        $displayLabel = "project $projectId"
    }
    # CS1: tracks the last phase this addon actually reached, so a caught
    # exception below can stamp Write-ProgressStep's -FailPhase without
    # parsing the exception text (UX-SPEC.md section 4.1's "each caught
    # exception... stamps which phase it happened in").
    $currentPhase = 'checking'

    try {
        if ($Record.ignoreUpdates -and (-not $Force) -and (-not $ExplicitTarget)) {
            Write-Log -Level 'INFO' -Message "Ignored: project $projectId ($displayLabel) has ignoreUpdates set"
            return [PSCustomObject]@{ Status = 'Ignored'; Name = $displayLabel; Version = $Record.version }
        }

        # Security-review fix: Resolve-ClassicProgressionTypeId now returns
        # EraKey='unknown' (TypeId/VersionPrefix/WagoField all $null) for a
        # real, non-zero Classic Interface that matches no known
        # progression range - a future expansion bump the table simply
        # doesn't cover yet. This MUST be a hard per-addon failure, never a
        # silent fall-through to Retail's TypeId (which could select and
        # install a Retail-tagged CurseForge file into a Classic folder).
        if ($cfMapping.EraKey -eq 'unknown') {
            Write-Log -Level 'ERROR' -Message "Unrecognized Classic client version for project $projectId ($displayLabel) - Furphy does not yet know this Classic client's expansion era. Update Furphy or file a bug."
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
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
                return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
            }
        } else {
            $maxReleaseType = Get-EffectiveMaxReleaseType -Record $Record -DefaultMax $DefaultMaxReleaseType
            $files = Get-CfFiles -ProjectId $projectId -MaxReleaseType $maxReleaseType
            $selected = Select-CfFile -Files $files -MaxReleaseType $maxReleaseType -TypeId $cfMapping.TypeId -VersionPrefix $cfMapping.VersionPrefix

            if (-not $selected) {
                Write-Log -Level 'WARN' -Message "No $Flavor file found for project $projectId ($displayLabel)"
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
            # Fix pass: wagoId/curseId metadata backfill, same reasoning as
            # the author backfill just above - a record synced before
            # Get-TocCrossSourceIds existed (or before its own last real
            # install) never got these toc-derived fields captured, even
            # though the installed folder's .toc is sitting right there on
            # disk. Reads it directly (no network cost) and only fills
            # whichever of the two is still missing; never overwrites an
            # existing value. Same DryRun gate as author/latestGameVersions.
            if ((-not $DryRun) -and $AddonsPath -and ((-not $Record.wagoId) -or (-not $Record.curseId))) {
                $backfillTocIds = Get-TocCrossSourceIds -AddonsPath $AddonsPath -Folders $Record.folders -Flavor $Flavor -InstalledInterface $InstalledInterface
                if ((-not $Record.curseId) -and $backfillTocIds.curseId) {
                    $Record.curseId = $backfillTocIds.curseId
                }
                if ((-not $Record.wagoId) -and $backfillTocIds.wagoId) {
                    $Record.wagoId = $backfillTocIds.wagoId
                }
            }
            # E13 (compatibility audit): $selected here is the file this run
            # already fetched to determine Up-to-date-ness, so recording its
            # game-version metadata costs no extra network call. Same DryRun
            # gate as the author backfill just above - see CHANGELOG Round 4's
            # pinnedFileId note for why ANY $Record mutation during DryRun
            # would misreport as persisted in the -Json "addons" array even
            # though DryRun's Save-Config never runs.
            if (-not $DryRun) {
                if ($selected.gameVersions) { $Record.latestGameVersions = $selected.gameVersions } else { $Record.latestGameVersions = @() }
                if ($selected.dateCreated) { $Record.latestFileDate = $selected.dateCreated }
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

        $currentPhase = 'downloading'
        Write-ProgressStep -Total $ProgressTotal -Index $ProgressIndex -Addon $displayLabel -Phase 'downloading'
        $zipPath = Get-DownloadedZip -ProjectId $projectId -SelectedFile $selected -StagingPath $StagingPath -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $displayLabel

        $currentPhase = 'installing'
        Write-ProgressStep -Total $ProgressTotal -Index $ProgressIndex -Addon $displayLabel -Phase 'installing'
        $newFolders = Install-AddonPackage -ZipPath $zipPath -ProjectId $projectId -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders

        if ($newFolders.Count -eq 0) {
            Write-Log -Level 'ERROR' -Message "Install produced zero usable folders for project $projectId ($displayLabel)"
            # Install-AddonPackage already ran stale cleanup against the previous
            # record's folders, so the disk no longer has them even though the
            # swap itself failed. Reflect that on the record.
            $Record.folders = $newFolders.ToArray()
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
        }

        $title = Get-TocTitle -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
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

        # E13 (compatibility audit): record the just-selected file's own
        # declared game-version strings + when it was seen, regardless of
        # whether this install used the pin path or the newest-file path -
        # this is what -Status's network-free compat check later compares the
        # client's build against, alongside the live toc Interface parse.
        if ($selected.gameVersions) { $Record.latestGameVersions = $selected.gameVersions } else { $Record.latestGameVersions = @() }
        $Record.latestFileDate = $selected.dateCreated

        # E3 (dependencies): re-parse every installed folder's own .toc for
        # Dependencies/RequiredDeps/OptionalDeps now that the new package is
        # on disk. Always recomputed from scratch (not merged with whatever
        # was there before) since a new version's dependency list replaces
        # the old one outright.
        $deps = Get-PackageDependencies -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
        $Record.requiredDeps = $deps.required
        $Record.optionalDeps = $deps.optional

        # E12 (Wago second source): cross-source ids parsed from the toc
        # regardless of source, so a CurseForge-sourced record can surface
        # "Also on Wago" (and vice versa, for the Wago path below) once the
        # UI has both ids to compare.
        $tocIds = Get-TocCrossSourceIds -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
        $Record.curseId = $tocIds.curseId
        $Record.wagoId = $tocIds.wagoId

        # E1 (rollback): archive the zip just installed so a later -Rollback
        # can reinstall it without any network access. $Record.previousFileId
        # (just set above, or still whatever an earlier update left it as on
        # a fresh install) tells the pruning step which older zip, if any, to
        # keep alongside this new one.
        Save-BackupZip -ZipPath $zipPath -ProjectId $projectId -FileId $selectedFileId -BackupsRoot $BackupsPath -PreviousFileId $Record.previousFileId

        $folderSummary = $newFolders -join ', '
        Write-Log -Level 'INFO' -Message "Installed project $projectId ($finalName) fileId $selectedFileId folders: $folderSummary"

        if ($isNewInstall) {
            $statusText = 'Installed'
        } else {
            $statusText = 'Updated'
        }

        return [PSCustomObject]@{ Status = $statusText; Name = $finalName; Version = $versionText }

    } catch {
        Write-Log -Level 'ERROR' -Message "Failed processing project $projectId ($displayLabel) : $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
    }
}

function Sync-SingleWagoAddon {
    <#
      E12: the Wago counterpart to Sync-SingleAddon above, dispatched to from
      there for any record with source 'wago'. Mirrors it field-for-field -
      ignore/pin handling, needsInstall detection, DryRun's Would-update
      contract, previous-version bookkeeping, dependency parsing and backup
      archiving all behave identically to the CurseForge path (reusing the
      exact same shared functions: Install-AddonPackage, Get-TocTitle,
      Get-PackageDependencies, Get-TocCrossSourceIds, Save-BackupZip) -
      differing only in what "the file to install" means (a Wago release,
      picked by stability via Select-WagoRelease rather than releaseType)
      and how it is fetched (Wago's Inertia JSON API + signed download link
      rather than the CurseForge website API). Kept as its own function
      instead of threading source checks through the well-tested CurseForge
      logic everywhere, the same reasoning already applied to keeping
      addon-server.ps1's small Resolve-EffectiveAddonsPath/
      Get-PresentAddonFolders duplicates instead of dot-sourcing this file.

      Deliberately does NOT fetch Wago addon details (developers/summary)
      during a plain sync - only Get-WagoAllReleases/Get-WagoReleaseById and
      the download itself are called, keeping a routine sync's Wago request
      count to the same shape as a CurseForge one (one list call, one
      download) rather than doubling it for author enrichment. Record.author
      stays $null for a Wago-sourced record in this build; the drawer's
      Overview tab gets developer names straight from the server's
      /api/wago/addons/{slug} proxy instead, which the UI already needs for
      its own display purposes regardless.
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
        [switch]$ExplicitTarget,
        # CS1: see Sync-SingleAddon's identical params for why.
        [int]$ProgressTotal = 0,
        [int]$ProgressIndex = 0,
        # FLAVORS-SPEC S4.6: see Sync-SingleAddon's identical params for why.
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $cfMapping = Get-CfFlavourMapping -Flavor $Flavor -InstalledInterface $InstalledInterface
    $slug = $Record.slug
    $displayLabel = $Record.name
    if (-not $displayLabel) {
        $displayLabel = "wago:$slug"
    }
    # CS1: see Sync-SingleAddon's identical tracker for why.
    $currentPhase = 'checking'

    try {
        if ($Record.ignoreUpdates -and (-not $Force) -and (-not $ExplicitTarget)) {
            Write-Log -Level 'INFO' -Message "Ignored: wago:$slug ($displayLabel) has ignoreUpdates set"
            return [PSCustomObject]@{ Status = 'Ignored'; Name = $displayLabel; Version = $Record.version }
        }

        # Security-review fix: see Sync-SingleAddon's identical check for
        # why - a real, non-zero Classic Interface outside every known
        # progression range must hard-fail rather than silently fall
        # through to Retail's WagoField ('retail'), which could select and
        # install a Retail-tagged Wago release into a Classic folder.
        if ($cfMapping.EraKey -eq 'unknown') {
            Write-Log -Level 'ERROR' -Message "Unrecognized Classic client version for wago:$slug ($displayLabel) - Furphy does not yet know this Classic client's expansion era. Update Furphy or file a bug."
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
        }

        $currentFileId = $null
        if ($Record.fileId) {
            $currentFileId = [string]$Record.fileId
        }

        $pinTarget = $null
        if ($FileIdOverride) {
            $pinTarget = [string]$FileIdOverride
        } elseif ($Record.pinnedFileId) {
            $pinTarget = [string]$Record.pinnedFileId
        }

        $selected = $null
        $usingPin = $false

        if ($pinTarget) {
            $usingPin = $true
            if ((-not $Force) -and $currentFileId -and ($currentFileId -eq $pinTarget)) {
                if (-not $DryRun) {
                    $Record.pinnedFileId = $pinTarget
                }
                Write-Log -Level 'INFO' -Message "Pinned: wago:$slug ($displayLabel) already on release $pinTarget"
                return [PSCustomObject]@{ Status = 'Pinned'; Name = $displayLabel; Version = $Record.version }
            }
            $selected = Get-WagoReleaseById -Slug $slug -ReleaseId $pinTarget
            if (-not $selected) {
                Write-Log -Level 'WARN' -Message "Release id $pinTarget not found for wago:$slug ($displayLabel)"
                return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
            }
        } else {
            $maxReleaseType = Get-EffectiveMaxReleaseType -Record $Record -DefaultMax $DefaultMaxReleaseType
            $releases = Get-WagoAllReleases -Slug $slug
            $selected = Select-WagoRelease -Releases $releases -MaxReleaseType $maxReleaseType -WagoField $cfMapping.WagoField

            if (-not $selected) {
                Write-Log -Level 'WARN' -Message "No allowed release found for wago:$slug ($displayLabel)"
                return [PSCustomObject]@{ Status = 'Skipped'; Name = $displayLabel; Version = $Record.version }
            }
        }

        $selectedFileId = [string]$selected.id

        $needsInstall = $false
        if ($Force) {
            $needsInstall = $true
        } elseif (-not $currentFileId) {
            $needsInstall = $true
        } elseif ($selectedFileId -ne $currentFileId) {
            $needsInstall = $true
        }

        if (-not $needsInstall) {
            # Fix pass: wagoId/curseId metadata backfill - the Wago
            # counterpart of the identical block in Sync-SingleAddon's own
            # Up-to-date branch (see its comment for the full rationale).
            # Reads the installed folder's .toc directly, no network cost;
            # only fills whichever of the two is still missing.
            if ((-not $DryRun) -and $AddonsPath -and ((-not $Record.wagoId) -or (-not $Record.curseId))) {
                $backfillTocIds = Get-TocCrossSourceIds -AddonsPath $AddonsPath -Folders $Record.folders -Flavor $Flavor -InstalledInterface $InstalledInterface
                if ((-not $Record.curseId) -and $backfillTocIds.curseId) {
                    $Record.curseId = $backfillTocIds.curseId
                }
                if ((-not $Record.wagoId) -and $backfillTocIds.wagoId) {
                    $Record.wagoId = $backfillTocIds.wagoId
                }
            }
            # E13 (compatibility audit): mirrors the CurseForge path's
            # identical DryRun-gated capture just above Sync-SingleAddon's own
            # Up-to-date return - $selected here is the release this run
            # already fetched, so recording its supported patches costs
            # nothing extra.
            if (-not $DryRun) {
                $selectedPatches = $selected.('supported_{0}_patches' -f $cfMapping.WagoField)
                if ($selectedPatches) { $Record.latestGameVersions = $selectedPatches } else { $Record.latestGameVersions = @() }
                if ($selected.created_at) { $Record.latestFileDate = $selected.created_at }
            }
            Write-Log -Level 'INFO' -Message "Up-to-date: wago:$slug ($displayLabel) release $currentFileId"
            return [PSCustomObject]@{ Status = 'Up-to-date'; Name = $displayLabel; Version = $Record.version }
        }

        $isNewInstall = (-not $currentFileId)
        $versionText = $selected.label

        if ($DryRun) {
            Write-Log -Level 'INFO' -Message "DryRun: would update wago:$slug ($displayLabel) to release $selectedFileId"
            # FileId here must be the newly SELECTED release (matching
            # Version) not $Record.fileId, for the same reason documented on
            # the CurseForge path above (CHANGELOG Round 1): DryRun never
            # mutates $Record.
            return [PSCustomObject]@{ Status = 'Would-update'; Name = $displayLabel; Version = $versionText; FileId = $selectedFileId }
        }

        $currentPhase = 'downloading'
        Write-ProgressStep -Total $ProgressTotal -Index $ProgressIndex -Addon $displayLabel -Phase 'downloading'
        $zipPath = Get-WagoDownloadedZip -Slug $slug -Release $selected -StagingPath $StagingPath -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $displayLabel

        $currentPhase = 'installing'
        Write-ProgressStep -Total $ProgressTotal -Index $ProgressIndex -Addon $displayLabel -Phase 'installing'
        $backupKey = Get-RecordBackupKey -Record $Record
        $newFolders = Install-AddonPackage -ZipPath $zipPath -ProjectId $backupKey -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders

        if ($newFolders.Count -eq 0) {
            Write-Log -Level 'ERROR' -Message "Install produced zero usable folders for wago:$slug ($displayLabel)"
            $Record.folders = $newFolders.ToArray()
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
        }

        $title = Get-TocTitle -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
        $finalName = $Record.name
        if ($title) {
            $finalName = $title
        } elseif (-not $finalName) {
            $finalName = $slug
        }

        if (-not $isNewInstall) {
            $Record.previousFileId = $currentFileId
            $Record.previousVersion = $Record.version
            $Record.previousFileName = $Record.fileName
        }

        $Record.name = $finalName
        $Record.fileId = $selectedFileId
        $Record.version = $versionText
        # Wago's release shape carries no filename of its own (unlike a
        # CurseForge file's .fileName) - synthesized from the slug + release
        # id, which is unique and stable enough to serve the same
        # informational purpose everywhere fileName is displayed/logged.
        $Record.fileName = '{0}-{1}.zip' -f $slug, $selectedFileId
        $Record.installedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Record.folders = $newFolders.ToArray()
        if ($pinTarget) {
            $Record.pinnedFileId = $pinTarget
        }

        # E13 (compatibility audit): the Wago counterpart of the CurseForge
        # install path's identical capture - supported_retail_patches is
        # Wago's equivalent of a CurseForge file's gameVersions[].
        if ($selected.supported_retail_patches) { $Record.latestGameVersions = $selected.supported_retail_patches } else { $Record.latestGameVersions = @() }
        $Record.latestFileDate = $selected.created_at

        # E12: cross-source ids always re-derived from the just-installed
        # package's own primary .toc (same treatment for both sources - see
        # the identical block on the CurseForge path above). A Wago record's
        # wagoId is not tracked anywhere else in this codebase, so if the
        # installed package's .toc omits ## X-Wago-ID this simply stays/goes
        # $null rather than being guessed at.
        $tocIds = Get-TocCrossSourceIds -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
        $Record.curseId = $tocIds.curseId
        $Record.wagoId = $tocIds.wagoId

        $deps = Get-PackageDependencies -AddonsPath $AddonsPath -Folders $newFolders -Flavor $Flavor -InstalledInterface $InstalledInterface
        $Record.requiredDeps = $deps.required
        $Record.optionalDeps = $deps.optional

        Save-BackupZip -ZipPath $zipPath -ProjectId $backupKey -FileId $selectedFileId -BackupsRoot $BackupsPath -PreviousFileId $Record.previousFileId

        $folderSummary = $newFolders -join ', '
        Write-Log -Level 'INFO' -Message "Installed wago:$slug ($finalName) release $selectedFileId folders: $folderSummary"

        if ($isNewInstall) {
            $statusText = 'Installed'
        } else {
            $statusText = 'Updated'
        }

        return [PSCustomObject]@{ Status = $statusText; Name = $finalName; Version = $versionText }

    } catch {
        Write-Log -Level 'ERROR' -Message "Failed processing wago:$slug ($displayLabel) : $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
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

    # E12: accept a "wago:<slug-or-id>" token or a full Wago URL too, matched
    # against a Wago record's slug/wagoId - additive, falls through to the
    # existing numeric-id-or-name matching unchanged for every other value.
    $wagoRef = $null
    if ($Target -match '(?i)^wago:(.+)$') {
        $wagoRef = $Matches[1].Trim()
    } elseif ($Target -match '(?i)^https?://addons\.wago\.io/addons/([a-z0-9-]+)') {
        $wagoRef = $Matches[1]
    }

    $targetIdValue = 0
    $isNumeric = [int]::TryParse($Target, [ref]$targetIdValue)
    $targetLower = $Target.ToLowerInvariant()

    $match = $null
    foreach ($item in $Config) {
        if ($wagoRef -and ($item.source -eq 'wago')) {
            $refLower = $wagoRef.ToLowerInvariant()
            if (($item.slug -and ($item.slug.ToLowerInvariant() -eq $refLower)) -or ($item.wagoId -and ($item.wagoId.ToLowerInvariant() -eq $refLower))) {
                $match = $item
                break
            }
        }
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

    # E12: a source-generic label for log messages - "project <id>" for a
    # CurseForge record (identical to the pre-E12 wording), or "wago:<slug>"
    # for a Wago one, which has no numeric projectId to interpolate at all
    # (the pre-E12 wording would otherwise print a bare, confusing
    # "project " with nothing after it).
    $matchLabel = if ($match.source -eq 'wago') { "wago:$($match.slug)" } else { "project $($match.projectId)" }

    if (-not $DryRun) {
        foreach ($folderName in $match.folders) {
            $folderPath = Join-Path -Path $AddonsPath -ChildPath $folderName
            if (Test-Path -LiteralPath $folderPath) {
                try {
                    Remove-Item -LiteralPath $folderPath -Recurse -Force
                    Write-Log -Level 'INFO' -Message "Removed folder '$folderName' for $matchLabel"
                } catch {
                    Write-Log -Level 'WARN' -Message "Failed to remove folder '$folderName' for $matchLabel : $($_.Exception.Message)"
                }
            }
        }
    }

    $displayName = $match.name
    if (-not $displayName) {
        $displayName = $matchLabel
    }

    $statusText = 'Removed'
    if ($DryRun) {
        $statusText = 'Would-update'
        Write-Log -Level 'INFO' -Message "DryRun: would remove addon '$displayName' ($matchLabel)"
    } else {
        Write-Log -Level 'INFO' -Message "Removed addon record for '$displayName' ($matchLabel)"
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

function ConvertTo-TargetToken {
    <#
      E12: classifies one already-trimmed CLI token as a CurseForge target
      (a decimal project id) or a Wago target ("wago:<slug-or-id>", or a
      full "https://addons.wago.io/addons/<slug>" URL, both normalized down
      to the bare slug/id reference) - shared by every id-array parameter
      that must accept both sources' targets (-Add, -Only, -Unpin, -Ignore,
      -Unignore, -Rollback). Returns a target descriptor:
      {IsWago; ProjectId (int64, $null for a Wago target); WagoRef (string,
      $null for a CurseForge target)}. Throws for anything else, same as the
      pre-E12 ConvertTo-ExpandedIdArray did for a non-numeric value - a bad
      token is still reported through this script's normal Write-Log/exit-2
      path rather than left to fail confusingly later.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ParamName
    )

    $parsedId = [int64]0
    if ([int64]::TryParse($Token, [ref]$parsedId)) {
        return [PSCustomObject]@{ IsWago = $false; ProjectId = $parsedId; WagoRef = $null }
    }
    if ($Token -match '(?i)^wago:(.+)$') {
        $ref = $Matches[1].Trim()
        if ($ref.Length -eq 0) {
            throw "-$ParamName value '$Token' has an empty wago: reference."
        }
        return [PSCustomObject]@{ IsWago = $true; ProjectId = $null; WagoRef = $ref }
    }
    if ($Token -match '(?i)^https?://addons\.wago\.io/addons/([a-z0-9-]+)') {
        return [PSCustomObject]@{ IsWago = $true; ProjectId = $null; WagoRef = $Matches[1] }
    }
    throw "-$ParamName value '$Token' is not a valid CurseForge project id, a wago:<slug-or-id> reference, or a https://addons.wago.io/addons/<slug> URL."
}

function ConvertTo-ExpandedTargetArray {
    <#
      E12: comma-expands like ConvertTo-ExpandedStringArray, then classifies
      every piece via ConvertTo-TargetToken. Returns a List[object] of
      target descriptors. Replaces ConvertTo-ExpandedIdArray for every
      id-array parameter that must accept a Wago target alongside a
      CurseForge one (-Add, -Only, -Unpin, -Ignore, -Unignore, -Rollback);
      -Remove keeps using ConvertTo-ExpandedStringArray unchanged (it
      already accepted arbitrary strings - names or ids - and
      Remove-AddonByTarget classifies each one itself).
    #>
    param(
        $RawValues,
        [Parameter(Mandatory = $true)][string]$ParamName
    )

    $strings = ConvertTo-ExpandedStringArray -RawValues $RawValues
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $strings) {
        $result.Add((ConvertTo-TargetToken -Token $s -ParamName $ParamName))
    }
    Write-Output -NoEnumerate $result
}

function Test-RecordMatchesTarget {
    <# E12: does $Record (a config entry) match one target descriptor (ConvertTo-TargetToken)? #>
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)]$Target
    )

    if ($Target.IsWago) {
        if ($Record.source -ne 'wago') { return $false }
        $ref = $Target.WagoRef.ToLowerInvariant()
        if ($Record.slug -and ($Record.slug.ToLowerInvariant() -eq $ref)) { return $true }
        if ($Record.wagoId -and ($Record.wagoId.ToLowerInvariant() -eq $ref)) { return $true }
        return $false
    }
    if ($Record.source -eq 'wago') { return $false }
    if (-not $Record.projectId) { return $false }
    try {
        return ([int64]$Record.projectId -eq [int64]$Target.ProjectId)
    } catch {
        return $false
    }
}

function Get-TargetLabel {
    <# E12: a human-readable label for a target descriptor, for log messages and "not found" result rows. #>
    param([Parameter(Mandatory = $true)]$Target)

    if ($Target.IsWago) { return "wago:$($Target.WagoRef)" }
    return "project $($Target.ProjectId)"
}

function Get-RecordBackupKey {
    <#
      E12: the <key> path segment under ROOT\backups\<key>\ and the staging
      extract-dir name for a record - the numeric CurseForge project id for
      a CurseForge record (identical in every way to the pre-E12 behaviour),
      or "wago-<slug>" for a Wago one, which has no numeric project id at
      all. Wago slugs are documented as lowercase-alnum-hyphen, but this
      still sanitizes defensively (a hand-typed "wago:<id>" target could in
      principle carry other characters) so the key is always a safe single
      path segment.
    #>
    param([Parameter(Mandatory = $true)]$Record)

    if ($Record.source -eq 'wago') {
        $safeSlug = ($Record.slug -replace '[^a-zA-Z0-9-]', '_')
        return "wago-$safeSlug"
    }
    return [string][int]$Record.projectId
}

# =====================================================================
# Dot-source guard (TESTING.md hook #1)
#
# Everything above this point (functions + the static $Script:FlavourDefs/
# $Script:TocEraSelectors tables) is safe to define unconditionally - none
# of it has a side effect. Everything below is the real "run the CLI" body:
# it touches disk (sync.log, settings.json, addons.json), may hit the
# network, and calls `exit`. A normal invocation
# (`.\addon-sync.ps1 ...` / `powershell.exe -File addon-sync.ps1 ...`) must
# run it exactly as before - this guard only short-circuits when the
# script is DOT-SOURCED (". .\addon-sync.ps1" or ". $path"), which is how
# tests\unit\*.Tests.ps1 loads these functions into Pester's scope without
# triggering a real sync/exit. $MyInvocation.InvocationName is the literal
# string "." when dot-sourced; the $MyInvocation.Line check is a fallback
# for hosts that report InvocationName differently.
# =====================================================================

$script:FurphyDotSourced = ($MyInvocation.InvocationName -eq '.') -or ($MyInvocation.Line -match '^\s*\.\s')
if ($script:FurphyDotSourced) {
    return
}

# =====================================================================
# Main
# =====================================================================

$scriptRootPath = $PSScriptRoot
if (-not $scriptRootPath) {
    $scriptRootPath = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

$script:LogPath = Join-Path -Path $scriptRootPath -ChildPath 'sync.log'
$script:LastRunPath = Join-Path -Path $scriptRootPath -ChildPath 'last-run.txt'
$script:SettingsPath = Join-Path -Path $scriptRootPath -ChildPath 'settings.json'
$script:LogFlavourPrefix = ''
# CS1: -ProgressPath is an opt-in caller-supplied path (addon-server.ps1
# threads one per job); Write-ProgressStep reads this script-scoped copy so
# every call site just calls it with phase data, never re-threading the
# path itself through every function signature.
$script:ProgressPath = $ProgressPath

# P1 perf pass (item 3): applied automatically whenever -Json or -Quiet is
# set (every existing non-interactive caller already passes one of those -
# a server-spawned job always uses -Json per SPEC, the launcher chain
# always uses -Quiet) or when -LowPriority is passed explicitly. A plain
# interactive run (a person typing addon-sync.ps1 -Status at a console)
# stays at normal priority, unaffected.
if ($LowPriority -or $Json -or $Quiet) {
    Set-FurphyLowPriority
}

# P1 perf pass (item 5, launch-chain cap): wall-clock zero for the whole
# run, used only by -Launcher's own budget/skip-recently checks below - set
# here, as early as possible, so it reflects true elapsed time from process
# start (flavour detection/config load included), not just time spent in
# the per-addon sync loop.
$script:MainStartTime = Get-Date

# ---- FLAVORS-SPEC S3.3: one-time, idempotent migration - before ANY path
#      resolution below. Never fatal: a migration failure logs and this run
#      falls through to whatever paths already exist (today's Retail-only
#      behaviour is unaffected either way, since a from-scratch environment
#      has nothing to migrate). ----
try {
    Invoke-FlavourMigration -RootPath $scriptRootPath
} catch {
    Write-Log -Level 'ERROR' -Message "Flavour migration failed: $($_.Exception.Message)"
}

# ---- FLAVORS-SPEC S2.3/S4.1: detect installed flavours and resolve which
#      one this run targets. -Flavor omitted -> 'retail' when installed
#      (byte-identical to every existing invocation); otherwise the first
#      flavour Get-InstalledFlavours returns. An unresolvable WoW root (no
#      -WowRoot, and this script isn't sitting under a known flavour
#      folder) degrades to the same 'retail' default today's sole code
#      path always used - Resolve-AddonsPath's own fatal exit-2 further
#      down is unchanged for that case. ----
$script:InstalledFlavours = @()
try {
    $script:InstalledFlavours = Get-InstalledFlavours -WowRoot $WowRoot -ScriptRoot $scriptRootPath
} catch {
    Write-Log -Level 'WARN' -Message "Get-InstalledFlavours failed, falling back to retail-only: $($_.Exception.Message)"
}

$effectiveFlavor = 'retail'
if ($Flavor -and $Flavor.Trim().Length -gt 0) {
    $matchedFlavour = $null
    foreach ($f in $script:InstalledFlavours) {
        if ($f.id -eq $Flavor) { $matchedFlavour = $f; break }
    }
    if (-not $matchedFlavour) {
        $installedIdsText = (($script:InstalledFlavours | ForEach-Object { $_.id }) -join ', ')
        $msg = "Flavour '$Flavor' is not installed. Installed flavours: $installedIdsText"
        Write-Log -Level 'ERROR' -Message $msg
        if ($Json) {
            Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
        } elseif (-not $Quiet) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }
    $effectiveFlavor = $Flavor
} else {
    $retailInstalled = $false
    foreach ($f in $script:InstalledFlavours) {
        if ($f.id -eq 'retail') { $retailInstalled = $true; break }
    }
    if ($retailInstalled -or ($script:InstalledFlavours.Count -eq 0)) {
        $effectiveFlavor = 'retail'
    } else {
        $effectiveFlavor = $script:InstalledFlavours[0].id
    }
}
$script:LogFlavourPrefix = "[$effectiveFlavor] "

$effectiveInstalledInterface = $null
foreach ($f in $script:InstalledFlavours) {
    if ($f.id -eq $effectiveFlavor) { $effectiveInstalledInterface = $f.clientInterface; break }
}
# S4.4: resolved once here (TypeId/VersionPrefix/WagoField) for every call
# site in Main that needs it directly (-Files' manual picker) rather than
# threading -Flavor/-InstalledInterface everywhere; Sync-SingleAddon/
# Sync-SingleWagoAddon compute their own copy the same way.
$effectiveCfMapping = Get-CfFlavourMapping -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface

# ---- FLAVORS-SPEC S3.1/S3.5: per-flavour addons.json/state.json/backups/
#      staging nest under flavours\<id>\ - only the target flavour's
#      subfolder is ever created (never every installed flavour's, so a
#      single-flavour machine ends up with exactly one). Shared files
#      (settings.json, sync.log, last-run.txt, cache\, jobs\) stay at
#      $scriptRootPath, unchanged. ----
$script:FlavourDir = Join-Path -Path (Join-Path -Path $scriptRootPath -ChildPath 'flavours') -ChildPath $effectiveFlavor
if (-not (Test-Path -LiteralPath $script:FlavourDir)) {
    try {
        New-Item -ItemType Directory -Path $script:FlavourDir -Force | Out-Null
    } catch {
        Write-Log -Level 'ERROR' -Message "Failed to create flavour data folder ${script:FlavourDir}: $($_.Exception.Message)"
    }
}
$script:ConfigPath = Join-Path -Path $script:FlavourDir -ChildPath 'addons.json'
$script:BackupsPath = Join-Path -Path $script:FlavourDir -ChildPath 'backups'
# CLI-1/security-5: staging is per-flavour (not shared at $scriptRootPath)
# so two concurrent per-flavour syncs (update-all-flavours, the tray's
# scheduled cycle) never race on the same Remove-Item/New-Item or extract
# the same project id into the same folder.
$script:StagingPath = Join-Path -Path $script:FlavourDir -ChildPath 'staging'

try {
    # ---- Load config ----
    $config = $null
    try {
        $config = Read-Config -Path $script:ConfigPath
    } catch {
        $msg = "addons.json could not be parsed: $($_.Exception.Message)"
        Write-Log -Level 'ERROR' -Message $msg
        if ($Json) {
            Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
        } elseif (-not $Quiet) {
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

    # ---- E13 (compatibility audit): resolve the client build/Interface once
    #      per run, before any of the early-exit branches below - -BuildInfoPath
    #      overrides everything (never touches the real WoW folder when given,
    #      per this build's test requirement); otherwise probe whatever AddOns
    #      path can be resolved right now (the same best-effort -Status uses -
    #      a real sync's own AddonsPath validation runs later and does not
    #      block this). Missing/unreadable/unresolvable -> $null/$null, which
    #      Get-AddonCompat already treats as 'unknown' rather than throwing. ----
    $effectiveBuildInfoPath = $BuildInfoPath
    if (-not $effectiveBuildInfoPath) {
        $probeAddonsPath = Resolve-AddonsPath -Provided $AddonsPath -ScriptRoot $scriptRootPath -Flavor $effectiveFlavor -WowRoot $WowRoot
        $effectiveBuildInfoPath = Get-DefaultBuildInfoPath -AddonsPathResolved $probeAddonsPath
    }
    $script:ClientBuildInfo = Get-ClientBuildInfo -BuildInfoPath $effectiveBuildInfoPath -Flavor $effectiveFlavor

    # ---- -Launcher: gate on settings.autoUpdateOnLaunch, no network when disabled ----
    if ($Launcher) {
        $autoUpdateOnLaunch = $true
        if ($settings -and ($null -ne $settings.autoUpdateOnLaunch)) {
            $autoUpdateOnLaunch = [bool]$settings.autoUpdateOnLaunch
        }
        if (-not $autoUpdateOnLaunch) {
            Write-Log -Level 'INFO' -Message 'auto-update disabled'
            if ($Json) {
                $jsonOut = [PSCustomObject]@{ action = 'sync'; flavour = $effectiveFlavor; installedFlavours = @($script:InstalledFlavours | ForEach-Object { $_.id }); results = @(); addons = $config.ToArray(); clientBuild = $script:ClientBuildInfo.clientBuild; clientInterface = $script:ClientBuildInfo.clientInterface }
                Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
            } elseif (-not $Quiet) {
                Write-Host 'Auto-update on launch is disabled; skipping sync.'
            }
            exit 0
        }

        # P1 perf pass (item 5, skip-if-recently-checked): if this flavour's
        # addons were checked (by ANY means - a server-driven Check now, the
        # tray's own scheduled cycle, or a previous -Launcher run - the
        # source doesn't matter, only recency) within the last 10 minutes,
        # trust that and launch immediately rather than paying a fresh
        # network round trip for every single WoW relaunch in a short
        # window (crash recovery, alt-tabbing out and back via the
        # shortcut). Read-only, no network - a missing/corrupt/unreadable
        # state.json (Get-StateUpdatesCheckedAtMinutesAgo's own null return)
        # degrades to "never checked", i.e. proceeds with a normal sync,
        # exactly like today's behavior.
        $recentCheckMinutesAgo = Get-StateUpdatesCheckedAtMinutesAgo -RootPath $scriptRootPath -Flavor $effectiveFlavor
        if (($null -ne $recentCheckMinutesAgo) -and ($recentCheckMinutesAgo -ge 0) -and ($recentCheckMinutesAgo -lt 10)) {
            $recentMsg = "recently checked ($([math]::Round($recentCheckMinutesAgo, 1)) min ago) - skipping update check"
            Write-Log -Level 'INFO' -Message $recentMsg
            if ($Json) {
                $jsonOut = [PSCustomObject]@{ action = 'sync'; flavour = $effectiveFlavor; installedFlavours = @($script:InstalledFlavours | ForEach-Object { $_.id }); results = @(); addons = $config.ToArray(); clientBuild = $script:ClientBuildInfo.clientBuild; clientInterface = $script:ClientBuildInfo.clientInterface }
                Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
            } elseif (-not $Quiet) {
                Write-Host $recentMsg
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
        $statusAddonsPath = Resolve-AddonsPath -Provided $AddonsPath -ScriptRoot $scriptRootPath -Flavor $effectiveFlavor -WowRoot $WowRoot
        $statusPresentFolders = Get-AddonsFolderSet -Path $statusAddonsPath

        # Fix pass: backfill wagoId/curseId toc-derived fields for records
        # that predate Get-TocCrossSourceIds (or whose last real install/
        # sync predated it) - read directly from each record's installed
        # folders on disk, no network needed, so -Status (otherwise fully
        # offline/read-only) can persist this itself rather than waiting for
        # the addon's next real sync/update. Only fills whichever of the two
        # is still missing; never overwrites an existing value. Skipped
        # entirely when the AddOns path can't be resolved (nothing to read).
        $statusConfigChanged = $false
        if ($statusAddonsPath) {
            foreach ($item in $config) {
                if ((-not $item.wagoId) -or (-not $item.curseId)) {
                    $statusTocIds = Get-TocCrossSourceIds -AddonsPath $statusAddonsPath -Folders $item.folders -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface
                    if ((-not $item.curseId) -and $statusTocIds.curseId) {
                        $item.curseId = $statusTocIds.curseId
                        $statusConfigChanged = $true
                    }
                    if ((-not $item.wagoId) -and $statusTocIds.wagoId) {
                        $item.wagoId = $statusTocIds.wagoId
                        $statusConfigChanged = $true
                    }
                }
            }
            if ($statusConfigChanged) {
                try {
                    Save-Config -Path $script:ConfigPath -Items $config
                    Write-Log -Level 'INFO' -Message 'Status: persisted wagoId/curseId backfill'
                } catch {
                    Write-Log -Level 'ERROR' -Message "Status: failed to persist wagoId/curseId backfill: $($_.Exception.Message)"
                }
            }
        }

        $statusAddons = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $config) {
            $missingDeps = Get-MissingDeps -DepNames $item.requiredDeps -PresentFolders $statusPresentFolders
            $missingOptionalDeps = Get-MissingDeps -DepNames $item.optionalDeps -PresentFolders $statusPresentFolders
            # E13 (compatibility audit): tocInterfaces/compat added to the same
            # clone missingDeps/missingOptionalDeps already build - see
            # Add-CompatFieldsToAddonClone's own doc comment.
            $clone = Add-CompatFieldsToAddonClone -Item $item -AddonsPath $statusAddonsPath -ClientInterface $script:ClientBuildInfo.clientInterface -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface
            $clone | Add-Member -MemberType NoteProperty -Name 'missingDeps' -Value $missingDeps.ToArray()
            $clone | Add-Member -MemberType NoteProperty -Name 'missingOptionalDeps' -Value $missingOptionalDeps.ToArray()
            $statusAddons.Add($clone)
        }

        if ($Json) {
            $jsonOut = [PSCustomObject]@{ action = 'status'; flavour = $effectiveFlavor; installedFlavours = @($script:InstalledFlavours | ForEach-Object { $_.id }); results = @(); addons = $statusAddons.ToArray(); clientBuild = $script:ClientBuildInfo.clientBuild; clientInterface = $script:ClientBuildInfo.clientInterface }
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
                        Source      = $(if ($item.source -eq 'wago') { 'Wago' } else { 'CurseForge' })
                        Version     = $item.version
                        FileId      = $item.fileId
                        InstalledAt = $item.installedAt
                        Folders     = ($item.folders -join ', ')
                        Author      = $item.author
                        Pinned      = $pinnedText
                        Ignored     = $ignoredText
                        MissingDeps = ($item.missingDeps -join ', ')
                        Compat      = $item.compat
                    })
            }
            $tableLines = Show-Table -Rows $statusRows -Columns @('Name', 'Source', 'Version', 'FileId', 'InstalledAt', 'Folders', 'Author', 'Pinned', 'Ignored', 'MissingDeps', 'Compat')
            foreach ($line in $tableLines) {
                Write-Host $line
            }
        }
        exit 0
    }

    # ---- -Files: list available files for one project, no config change ----
    if ($Files) {
        # E12: -Files now accepts a Wago target ("wago:<slug-or-id>" or a
        # wago URL) alongside a plain numeric CurseForge project id, same
        # classification -Add/-Only/etc. use.
        $filesTarget = $null
        try {
            $filesTarget = ConvertTo-TargetToken -Token ([string]$Files) -ParamName 'Files'
        } catch {
            $msg = $_.Exception.Message
            Write-Log -Level 'ERROR' -Message $msg
            if ($Json) {
                Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
            } elseif (-not $Quiet) {
                Write-Host "ERROR: $msg"
            }
            exit 2
        }

        if ($filesTarget.IsWago) {
            $slugForFiles = $filesTarget.WagoRef
            Write-Log -Level 'INFO' -Message "Files requested for wago:$slugForFiles"

            $wagoFileRows = New-Object 'System.Collections.Generic.List[object]'
            $wagoFilesError = $null
            try {
                $releases = Get-WagoAllReleases -Slug $slugForFiles
                foreach ($r in $releases) {
                    $hasChangelog = [bool]($r.changelog -and ([string]$r.changelog).Trim().Length -gt 0)
                    $patches = @()
                    if ($r.supported_retail_patches) { $patches = $r.supported_retail_patches }
                    $wagoFileRows.Add([PSCustomObject]@{
                            id                    = [string]$r.id
                            displayName           = $r.label
                            version               = $r.label
                            fileName              = $null
                            dateCreated           = $r.created_at
                            stability             = $r.stability
                            gameVersions          = $patches
                            fileLength            = $r.size
                            downloads             = $null
                            author                = $null
                            retail                = [bool]($patches.Count -gt 0)
                            hasChangelog          = $hasChangelog
                        })
                }
            } catch {
                $wagoFilesError = $_.Exception.Message
                Write-Log -Level 'ERROR' -Message "Failed to list releases for wago:$slugForFiles : $wagoFilesError"
            }

            if ($Json) {
                # Mirrors the base -Files -Json shape ({"action":"files",...})
                # but replaces the CurseForge-only "projectId" key with
                # "source"/"slug", since a Wago target has no numeric project id.
                $jsonOut = [PSCustomObject]@{ action = 'files'; source = 'wago'; slug = $slugForFiles; files = $wagoFileRows.ToArray() }
                Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
            } elseif (-not $Quiet) {
                if ($wagoFilesError) {
                    Write-Host "ERROR: $wagoFilesError"
                } else {
                    $wagoDisplayRows = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($fr in $wagoFileRows) {
                        $dateText = "$($fr.dateCreated)"
                        try {
                            $dateText = ([datetime]$fr.dateCreated).ToString('yyyy-MM-dd')
                        } catch {
                        }
                        $wagoDisplayRows.Add([PSCustomObject]@{
                                Id          = $fr.id
                                Version     = $fr.version
                                Date        = $dateText
                                Stability   = $fr.stability
                                Retail      = $fr.retail
                                Size        = $fr.fileLength
                                Changelog   = $fr.hasChangelog
                            })
                    }
                    $wagoTableLines = Show-Table -Rows $wagoDisplayRows -Columns @('Id', 'Version', 'Date', 'Stability', 'Retail', 'Size', 'Changelog')
                    foreach ($line in $wagoTableLines) {
                        Write-Host $line
                    }
                }
            }
            exit 0
        }

        $filesProjectId = [int]$filesTarget.ProjectId
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
                        retail       = (Test-FileHasTypeId -File $f -TypeId $effectiveCfMapping.TypeId)
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
    $effectiveAddonsPath = Resolve-AddonsPath -Provided $AddonsPath -ScriptRoot $scriptRootPath -Flavor $effectiveFlavor -WowRoot $WowRoot
    if (-not $effectiveAddonsPath) {
        $msg = 'AddonsPath was not specified and could not be inferred from the script location (expected <X>\_retail_\AddonSync). Pass -AddonsPath "<X>\_retail_\Interface\AddOns".'
        Write-Log -Level 'ERROR' -Message $msg
        if ($Json) {
            Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
        } elseif (-not $Quiet) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }
    if (-not (Test-Path -LiteralPath $effectiveAddonsPath -PathType Container)) {
        $msg = "AddOns path does not exist: $effectiveAddonsPath"
        Write-Log -Level 'ERROR' -Message $msg
        if ($Json) {
            Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
        } elseif (-not $Quiet) {
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
            $info = Get-FolderTocInfo -FolderPath $dir.FullName -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface
            $untracked.Add([PSCustomObject]@{
                    folder  = $dir.Name
                    title   = $info.title
                    version = $info.version
                    hasToc  = $info.hasToc
                    curseId = $info.curseId
                    wagoId  = $info.wagoId
                })
        }

        if ($Json) {
            $jsonOut = [PSCustomObject]@{ action = 'scan'; untracked = $untracked.ToArray() }
            Write-Host (ConvertTo-Json -InputObject $jsonOut -Depth 10)
        } elseif (-not $Quiet) {
            $tableLines = Show-Table -Rows $untracked -Columns @('Folder', 'Title', 'Version', 'HasToc', 'CurseId', 'WagoId')
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

    # ---- Normalize array-typed CLI parameters (see ConvertTo-ExpandedTargetArray
    #      / ConvertTo-ExpandedStringArray above for why this is needed).
    #      E12: -Add/-Only/-Unpin/-Ignore/-Unignore/-Rollback now classify into
    #      target DESCRIPTORS (CurseForge id or Wago reference - see
    #      ConvertTo-TargetToken) rather than bare int64s, via
    #      ConvertTo-ExpandedTargetArray. Critically, the result is assigned
    #      to a NEW variable ($AddTargets etc.), never back onto $Add/$Only/
    #      $Unpin/$Ignore/$Unignore/$Rollback themselves: those are declared
    #      [string[]] in this script's own top-level param() block, and
    #      Windows PowerShell 5.1 enforces a script parameter's declared type
    #      on every later assignment within the script's scope, not just the
    #      initial bind - reassigning $Ignore (say) to a List[object] of
    #      PSCustomObject descriptors gets silently coerced right back to a
    #      string[] via each object's .ToString() (e.g. "@{IsWago=True;
    #      ...}"), which then reads as a plain non-numeric, non-"wago:"
    #      string to any later code that reads it - reproduced directly
    #      during this build's own offline verification: `-Ignore
    #      wago:<slug>` unconditionally reported the target "not found" no
    #      matter what, because by the time the -Ignore block runs, $Ignore
    #      had already been silently flattened back into strings. This is
    #      the same class of hazard SPEC.md's List[object]/@() and
    #      Get-AddonRecords-return quirks document, generalized to
    #      reassigning a DECLARED-TYPED script parameter to an incompatible
    #      type rather than an untyped local variable. $Remove keeps
    #      reassigning itself in place (unchanged from before E12): its
    #      normalizer, ConvertTo-ExpandedStringArray, returns strings, which
    #      are exactly $Remove's own declared element type, so no coercion
    #      happens there and nothing is lost. ----
    try {
        $AddTargets = ConvertTo-ExpandedTargetArray -RawValues $Add -ParamName 'Add'
        $Remove = ConvertTo-ExpandedStringArray -RawValues $Remove
        $OnlyTargets = ConvertTo-ExpandedTargetArray -RawValues $Only -ParamName 'Only'
        $UnpinTargets = ConvertTo-ExpandedTargetArray -RawValues $Unpin -ParamName 'Unpin'
        $IgnoreTargets = ConvertTo-ExpandedTargetArray -RawValues $Ignore -ParamName 'Ignore'
        $UnignoreTargets = ConvertTo-ExpandedTargetArray -RawValues $Unignore -ParamName 'Unignore'
        $RollbackTargets = ConvertTo-ExpandedTargetArray -RawValues $Rollback -ParamName 'Rollback'
    } catch {
        $msg = "Invalid command-line value: $($_.Exception.Message)"
        Write-Log -Level 'ERROR' -Message $msg
        if ($Json) {
            Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
        } elseif (-not $Quiet) {
            Write-Host "ERROR: $msg"
        }
        exit 2
    }

    # ---- Compute targeting flags up front (needed to validate -FileId before
    #      any mutation happens, and later to decide toSync and the action label) ----
    $hasRemove = $Remove -and ($Remove.Count -gt 0)
    $hasAdd = $AddTargets -and ($AddTargets.Count -gt 0)
    $hasOnly = $OnlyTargets -and ($OnlyTargets.Count -gt 0)
    $hasUnpin = $UnpinTargets -and ($UnpinTargets.Count -gt 0)
    $hasIgnore = $IgnoreTargets -and ($IgnoreTargets.Count -gt 0)
    $hasUnignore = $UnignoreTargets -and ($UnignoreTargets.Count -gt 0)
    $hasRollback = $RollbackTargets -and ($RollbackTargets.Count -gt 0)
    $hasFlagsOnly = $hasUnpin -or $hasIgnore -or $hasUnignore

    # ---- Validate -FileId usage: requires exactly one target in -Only or -Add ----
    # E12: $fileIdTarget is now a target DESCRIPTOR (see ConvertTo-TargetToken),
    # not a bare int64 - it names either a CurseForge project id or a Wago
    # slug/id, matched against records via Test-RecordMatchesTarget below.
    $fileIdTarget = $null
    if ($FileId) {
        $addCountForFileId = 0
        if ($hasAdd) {
            $addCountForFileId = $AddTargets.Count
        }
        $onlyCountForFileId = 0
        if ($hasOnly) {
            $onlyCountForFileId = $OnlyTargets.Count
        }

        if (($addCountForFileId -eq 1) -and ($onlyCountForFileId -eq 0)) {
            $fileIdTarget = $AddTargets[0]
        } elseif (($onlyCountForFileId -eq 1) -and ($addCountForFileId -eq 0)) {
            $fileIdTarget = $OnlyTargets[0]
        } else {
            $msg = '-FileId requires exactly one project id via -Only or -Add.'
            Write-Log -Level 'ERROR' -Message $msg
            if ($Json) {
                Write-Host (ConvertTo-Json -InputObject @{ error = $msg } -Depth 5)
            } elseif (-not $Quiet) {
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
            $removeWagoSlug = $null
            if ($removeResult.Record) {
                $removeProjectId = $removeResult.Record.projectId
                $removeFileId = $removeResult.Record.fileId
                $removeWagoSlug = $removeResult.Record.slug
            }
            $resultsRows.Add([PSCustomObject]@{ Status = $removeResult.Status; Name = $removeResult.Name; Version = $removeResult.Version; ProjectId = $removeProjectId; FileId = $removeFileId; WagoSlug = $removeWagoSlug })
            if ($removeResult.Removed -and $removeResult.Record) {
                $config.Remove($removeResult.Record) | Out-Null
            }
        }
    }

    # ---- -Add ----
    # E12: $addedRecords holds the actual RECORD OBJECTS created this run
    # (rather than a set of ids) - a Wago record has no numeric projectId to
    # key a HashSet[int64] on, and PowerShell object references compare
    # correctly with -eq/Contains regardless of source, so this sidesteps
    # the identity problem entirely rather than inventing a second parallel
    # id space. Every downstream consumer (toSync, isExplicit, the
    # placeholder-cleanup pass) is updated to use it the same way.
    $addedRecords = New-Object 'System.Collections.Generic.List[object]'
    if ($hasAdd) {
        foreach ($target in $AddTargets) {
            $existing = $null
            foreach ($item in $config) {
                if (Test-RecordMatchesTarget -Record $item -Target $target) {
                    $existing = $item
                    break
                }
            }
            if ($existing) {
                Write-Log -Level 'INFO' -Message "Add skipped: $(Get-TargetLabel $target) is already present in addons.json"
                $existingDisplayName = $existing.name
                if (-not $existingDisplayName) {
                    $existingDisplayName = Get-TargetLabel $target
                }
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = $existingDisplayName; Version = $existing.version; ProjectId = $existing.projectId; FileId = $existing.fileId; WagoSlug = $existing.slug })
                continue
            }
            if ($target.IsWago) {
                $newRecord = New-WagoAddonRecord -Slug $target.WagoRef
            } else {
                $newRecord = New-AddonRecord -ProjectId $target.ProjectId
            }
            $config.Add($newRecord)
            $addedRecords.Add($newRecord)
            Write-Log -Level 'INFO' -Message "Added $(Get-TargetLabel $target) to addons.json"
        }
    }

    # ---- -Unpin / -Ignore / -Unignore: config-only, no network ----
    if ($hasUnpin) {
        foreach ($target in $UnpinTargets) {
            $match = $null
            foreach ($item in $config) {
                if (Test-RecordMatchesTarget -Record $item -Target $target) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $match.pinnedFileId = $null
                $displayName = $match.name
                if (-not $displayName) {
                    $displayName = Get-TargetLabel $target
                }
                Write-Log -Level 'INFO' -Message "Unpinned $(Get-TargetLabel $target) ($displayName)"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Unpinned'; Name = $displayName; Version = $match.version; ProjectId = $match.projectId; FileId = $match.fileId; WagoSlug = $match.slug })
            } else {
                Write-Log -Level 'WARN' -Message "Unpin target $(Get-TargetLabel $target) not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = (Get-TargetLabel $target); Version = ''; ProjectId = $(if (-not $target.IsWago) { $target.ProjectId }); FileId = $null; WagoSlug = $(if ($target.IsWago) { $target.WagoRef }) })
            }
        }
    }

    if ($hasIgnore) {
        foreach ($target in $IgnoreTargets) {
            $match = $null
            foreach ($item in $config) {
                if (Test-RecordMatchesTarget -Record $item -Target $target) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $match.ignoreUpdates = $true
                $displayName = $match.name
                if (-not $displayName) {
                    $displayName = Get-TargetLabel $target
                }
                Write-Log -Level 'INFO' -Message "Ignoring updates for $(Get-TargetLabel $target) ($displayName)"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Ignored'; Name = $displayName; Version = $match.version; ProjectId = $match.projectId; FileId = $match.fileId; WagoSlug = $match.slug })
            } else {
                Write-Log -Level 'WARN' -Message "Ignore target $(Get-TargetLabel $target) not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = (Get-TargetLabel $target); Version = ''; ProjectId = $(if (-not $target.IsWago) { $target.ProjectId }); FileId = $null; WagoSlug = $(if ($target.IsWago) { $target.WagoRef }) })
            }
        }
    }

    if ($hasUnignore) {
        foreach ($target in $UnignoreTargets) {
            $match = $null
            foreach ($item in $config) {
                if (Test-RecordMatchesTarget -Record $item -Target $target) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $match.ignoreUpdates = $false
                $displayName = $match.name
                if (-not $displayName) {
                    $displayName = Get-TargetLabel $target
                }
                Write-Log -Level 'INFO' -Message "Stopped ignoring updates for $(Get-TargetLabel $target) ($displayName)"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Unignored'; Name = $displayName; Version = $match.version; ProjectId = $match.projectId; FileId = $match.fileId; WagoSlug = $match.slug })
            } else {
                Write-Log -Level 'WARN' -Message "Unignore target $(Get-TargetLabel $target) not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = (Get-TargetLabel $target); Version = ''; ProjectId = $(if (-not $target.IsWago) { $target.ProjectId }); FileId = $null; WagoSlug = $(if ($target.IsWago) { $target.WagoRef }) })
            }
        }
    }

    # ---- -Rollback: reinstall from a locally archived zip, no network ----
    if ($hasRollback) {
        foreach ($target in $RollbackTargets) {
            $match = $null
            foreach ($item in $config) {
                if (Test-RecordMatchesTarget -Record $item -Target $target) {
                    $match = $item
                    break
                }
            }
            if ($match) {
                $rollbackResult = Invoke-RollbackForRecord -Record $match -AddonsPath $effectiveAddonsPath -StagingPath $script:StagingPath -BackupsRoot $script:BackupsPath -DryRun:$DryRun -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface
                $rollbackFileId = $match.fileId
                if (Get-Member -InputObject $rollbackResult -Name 'FileId' -MemberType NoteProperty) {
                    $rollbackFileId = $rollbackResult.FileId
                }
                $resultsRows.Add([PSCustomObject]@{ Status = $rollbackResult.Status; Name = $rollbackResult.Name; Version = $rollbackResult.Version; ProjectId = $match.projectId; FileId = $rollbackFileId; WagoSlug = $match.slug })
            } else {
                Write-Log -Level 'WARN' -Message "Rollback target $(Get-TargetLabel $target) not found in addons.json"
                $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = (Get-TargetLabel $target); Version = ''; ProjectId = $(if (-not $target.IsWago) { $target.ProjectId }); FileId = $null; WagoSlug = $(if ($target.IsWago) { $target.WagoRef }) })
            }
        }
    }

    # ---- Decide which records to sync over the network this run ----
    # A plain bare invocation (nothing targeting) syncs everything, exactly
    # as before. -Add restricts to the newly added records; -Only restricts
    # to that explicit id list; a remove-only, flags-only and/or
    # rollback-only run (no add, no -Only) never implies a full sync.
    $toSync = New-Object 'System.Collections.Generic.List[object]'
    # E12: $onlyRecords mirrors the pre-E12 $onlySet, but as actual record
    # references (built by scanning $config in its own order and testing
    # every -Only target against each record) rather than a HashSet[int64] -
    # a Wago record has no numeric projectId to key that on. Iterating
    # $config outer / $Only inner preserves the exact same "config order"
    # toSync always had, rather than "-Only argument order".
    $onlyRecords = New-Object 'System.Collections.Generic.List[object]'
    if ($hasOnly) {
        foreach ($item in $config) {
            foreach ($target in $OnlyTargets) {
                if (Test-RecordMatchesTarget -Record $item -Target $target) {
                    $onlyRecords.Add($item)
                    break
                }
            }
        }
    }

    if ($hasAdd) {
        # $addedRecords is already in the same relative order $config itself
        # holds them in (List[object].Add always appends, and nothing
        # reorders $config between the -Add block above and here), so this
        # matches the pre-E12 "scan $config in order" toSync construction
        # without needing to re-scan it.
        foreach ($r in $addedRecords) {
            $toSync.Add($r)
        }
    } elseif ($hasOnly) {
        foreach ($r in $onlyRecords) {
            $toSync.Add($r)
        }
    } elseif ($hasRemove -or $hasFlagsOnly -or $hasRollback) {
        # Nothing to add here: remove-only, flags-only and/or rollback-only
        # runs stay network-free.
    } else {
        foreach ($item in $config) {
            $toSync.Add($item)
        }
    }

    # CS1: n-of-N progress reporting (UX-SPEC.md section 4.1). $progressIndex
    # is the count of addons already FINISHED (bumped after each one below),
    # so a determinate bar can render index/total at any point mid-run. A
    # complete no-op end to end when -ProgressPath was never supplied
    # (Write-ProgressStep's own guard).
    $progressIndex = 0
    Write-ProgressStep -Total $toSync.Count -Index 0 -Addon $null -Phase 'queued'

    # P1 perf pass (item 5, launch-chain cap): -Launcher must never delay
    # the game more than ~45s total (task brief). Each Sync-SingleAddon call
    # already has its own per-request timeouts (this never interrupts one
    # mid-flight) - this only stops STARTING another addon's check once the
    # budget is spent. 40s (not 45) leaves margin for the small fixed costs
    # around the loop itself (flavour detection, config load, the Battle.net
    # hand-off the launcher .cmd runs immediately after this process exits).
    # Never active outside -Launcher - a manual/server-driven sync or check
    # is never time-boxed this way.
    $Script:LauncherBudgetSeconds = 40
    $Script:LauncherBudgetExceeded = $false

    foreach ($record in $toSync) {
        if ($Launcher -and (-not $Script:LauncherBudgetExceeded)) {
            if (Test-LauncherBudgetExceeded -StartTime $script:MainStartTime -BudgetSeconds $Script:LauncherBudgetSeconds) {
                $Script:LauncherBudgetExceeded = $true
            }
        }
        if ($Launcher -and $Script:LauncherBudgetExceeded) {
            $skipLabel = $record.name
            if (-not $skipLabel) {
                if ($record.source -eq 'wago') {
                    $skipLabel = "wago:$($record.slug)"
                } else {
                    $skipLabel = "project $($record.projectId)"
                }
            }
            Write-Log -Level 'WARN' -Message "Launcher budget ($($Script:LauncherBudgetSeconds)s) exceeded - skipping remaining addon check: $skipLabel"
            $resultsRows.Add([PSCustomObject]@{ Status = 'Skipped'; Name = $record.name; Version = $record.version; ProjectId = $record.projectId; FileId = $record.fileId; WagoSlug = $record.slug })
            $progressIndex = $progressIndex + 1
            Write-ProgressStep -Total $toSync.Count -Index $progressIndex -Addon $skipLabel -Phase 'skipped'
            continue
        }

        # E12: reference-equality membership check replaces the pre-E12
        # int64 HashSet.Contains - toSync is itself already exactly
        # onlyRecords/addedRecords when hasOnly/hasAdd (see above), so every
        # record reaching this loop in either case is trivially explicit;
        # this check is kept (rather than collapsed to a per-run constant)
        # so it stays a faithful, minimal generalization of the original
        # per-record logic instead of an unrelated behavioral shortcut.
        $isExplicit = $false
        foreach ($r in $onlyRecords) {
            if ([object]::ReferenceEquals($record, $r)) { $isExplicit = $true; break }
        }
        if (-not $isExplicit) {
            foreach ($r in $addedRecords) {
                if ([object]::ReferenceEquals($record, $r)) { $isExplicit = $true; break }
            }
        }

        $fileIdOverrideForRecord = $null
        if ($fileIdTarget -and (Test-RecordMatchesTarget -Record $record -Target $fileIdTarget)) {
            $fileIdOverrideForRecord = $FileId
        }

        # CS1: same "name, else a source-appropriate placeholder" fallback
        # Sync-SingleAddon/Sync-SingleWagoAddon each use internally for
        # their own $displayLabel - kept in sync with those on purpose so
        # the "checking" step's addon name matches whatever the "downloading"/
        # "installing" steps written from inside the sync function say next.
        $progressLabel = $record.name
        if (-not $progressLabel) {
            if ($record.source -eq 'wago') {
                $progressLabel = "wago:$($record.slug)"
            } else {
                $progressLabel = "project $($record.projectId)"
            }
        }
        Write-ProgressStep -Total $toSync.Count -Index $progressIndex -Addon $progressLabel -Phase 'checking'

        $rowResult = Sync-SingleAddon -Record $record -AddonsPath $effectiveAddonsPath -StagingPath $script:StagingPath -BackupsPath $script:BackupsPath -Force:$Force -DryRun:$DryRun -DefaultMaxReleaseType $defaultMaxReleaseType -FileIdOverride $fileIdOverrideForRecord -ExplicitTarget:$isExplicit -ProgressTotal $toSync.Count -ProgressIndex $progressIndex -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface

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
        $resultsRows.Add([PSCustomObject]@{ Status = $rowResult.Status; Name = $rowResult.Name; Version = $rowResult.Version; ProjectId = $record.projectId; FileId = $rowFileId; WagoSlug = $record.slug })

        # CS1: bump index (this addon is now finished, one way or another)
        # and write the final per-addon phase, mapped from the same
        # $rowResult.Status the row above was just built from (UX-SPEC.md
        # section 4.1 point 5). A caught failure's FailPhase (set inside
        # Sync-SingleAddon/Sync-SingleWagoAddon's own catch block, or a
        # "file/release id not found"/zero-usable-folders return - see those
        # functions) rides along on the same write so a UI reading
        # progress.json's very last entry for a failed addon still gets which
        # sub-phase it failed during without parsing $rowResult itself.
        $progressIndex = $progressIndex + 1
        switch ($rowResult.Status) {
            'Up-to-date' { $mappedPhase = 'up_to_date' }
            'Failed'     { $mappedPhase = 'failed' }
            'Installed'  { $mappedPhase = 'done' }
            'Updated'    { $mappedPhase = 'done' }
            default      { $mappedPhase = 'done' }
        }
        $rowFailPhase = $null
        if (Get-Member -InputObject $rowResult -Name 'FailPhase' -MemberType NoteProperty) {
            $rowFailPhase = $rowResult.FailPhase
        }
        Write-ProgressStep -Total $toSync.Count -Index $progressIndex -Addon $rowResult.Name -Phase $mappedPhase -FailPhase $rowFailPhase
    }

    # ---- Drop placeholder records for adds that never got an installable file ----
    if ((-not $DryRun) -and ($addedRecords.Count -gt 0)) {
        $placeholders = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in $addedRecords) {
            if (-not $r.fileId) {
                $placeholders.Add($r)
            }
        }
        foreach ($placeholder in $placeholders) {
            $placeholderLabel = if ($placeholder.source -eq 'wago') { "wago:$($placeholder.slug)" } else { "Project $($placeholder.projectId)" }
            Write-Log -Level 'WARN' -Message "$placeholderLabel was not added: no installable file was found, so no record was saved"
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

    # P1 perf pass follow-up: a -Launcher run that reaches here completed a
    # real check (whether or not the budget above skipped some addons partway
    # through - the same "attempted a check" bar addon-server.ps1's own
    # Complete-Job uses, not "everything came back up to date"), so stamp the
    # shared timestamp now - this is the actual write the 10-minute skip rule
    # above has always claimed a "previous -Launcher run" provides. Never
    # runs for -Status/-Files/other read-only paths, which exit long before
    # reaching here.
    if ($Launcher) {
        Save-LauncherUpdatesCheckedAt -RootPath $scriptRootPath -Flavor $effectiveFlavor
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
                    wagoSlug  = $r.WagoSlug
                })
        }
        # E13 (compatibility audit): "every sync/check result" (not just
        # -Status) gains tocInterfaces/compat per addon - decorated the same
        # way -Status's own clone loop does, so a plain sync's addons[] never
        # differs from what -Status would report for the same on-disk state.
        $jsonAddons = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $config) {
            $jsonAddons.Add((Add-CompatFieldsToAddonClone -Item $item -AddonsPath $effectiveAddonsPath -ClientInterface $script:ClientBuildInfo.clientInterface -Flavor $effectiveFlavor -InstalledInterface $effectiveInstalledInterface))
        }
        # FLAVORS-SPEC S5.2: "flavour" (which one this output is scoped to)
        # and "installedFlavours" (ids only - the CLI's own -Json output is
        # not the server's /api/state, so this stays a plain id list rather
        # than S5.2's fuller per-flavour object shape) are additive - every
        # other field is unchanged.
        $jsonOut = [PSCustomObject]@{
            action            = $actionLabel
            flavour           = $effectiveFlavor
            installedFlavours = @($script:InstalledFlavours | ForEach-Object { $_.id })
            results           = $jsonResults.ToArray()
            addons            = $jsonAddons.ToArray()
            clientBuild       = $script:ClientBuildInfo.clientBuild
            clientInterface   = $script:ClientBuildInfo.clientInterface
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
