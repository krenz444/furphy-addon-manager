# ADOPT-SPEC.md - honest first-run adoption + honest installer progress

Eric's requests, verbatim:
1. "make a more friendly message in the installer than : taking over x
   addons etc, and provide progress during the installer, the progress bar
   currently doesnt really make any sense in the installer"
2. "make sure that when furphy addon manager installs, none of the users
   existing addon data is corrupted, removed, or anything, it needs to be
   a clean switch over"

This spec covers both. Request 2 is the load-bearing one: today, the
installer's "adopt" step silently **re-downloads and overwrites** every
addon folder it recognizes (install.ps1:2717 `"Taking over $($targets.Count)
addon(s) (reinstalling each from its source)..."`, backed by the CLI's
`-Add`, which always installs). That is not "a clean switch over" - it is
a bulk reinstall the player never explicitly asked for, using whatever
CurseForge/Wago currently serves for that project id, which is not
guaranteed to be byte-identical to what the player already had (a beta
build, a hand-patched file, a slightly older pinned version, a file
CurseForge itself has since replaced). Request 1's UI complaints
(jargon, a Marquee bar that "doesn't make any sense") are downstream of
the same design: the step's real behavior IS scary ("taking over",
"reinstalling") because it genuinely does something invasive, and its
progress genuinely has no accurate percentage to show because it is
bundling an unbounded number of network downloads into one label.

Fixing the wording alone would be dishonest (friendlier words over the
same destructive action). This spec fixes the behavior first, then the
wording and progress bar become straightforward because there is finally
something true and simple to say.

## 0. Scope note - one app, two "adopt" surfaces, only one changes

This codebase already has TWO independent places that turn an untracked
AddOns folder into a managed record:

- **install.ps1's own first-run/upgrade step** ("Looking for existing
  addons to take over", install.ps1:2660-2737). Runs automatically,
  unattended, for every recognizable folder it finds, with no per-addon
  confirmation. **This is the one this spec changes.** Its whole premise
  changes from "reinstall to establish a record" to "record what is
  already there, unchanged."
- **ui/app.js's own "Take over" flow** (Settings > "Folders Furphy
  doesn't manage yet", and the first-run `#dialog-welcome` "Take over
  all" button reached only when `addons.json` still has zero records -
  see app.js:8751-8761, index.html:1524-1542). This is an explicit,
  opt-in, per-click action the player deliberately triggers from inside
  the running app, already correctly and honestly worded per
  UX-SPEC.md's own history (UX-SPEC.md:305: an earlier draft claiming
  "it doesn't touch the files themselves" was found false and removed;
  the shipped tooltip says plainly that the addon is re-downloaded and
  its folder overwritten). **This spec does NOT touch this flow, its
  wording, or its behavior.** It is a different feature (a manual,
  opt-in "get Furphy to manage this and refresh it to the matched
  file", not an unattended installer step) and remains exactly as
  UX-SPEC.md already specifies it. Section 4 below adds one small,
  additive piece of new UI (a one-time "you're already covered" notice)
  that is careful not to collide with it.

Everywhere below, "adopt"/"-Adopt" refers only to the new, non-downloading
mechanism this spec adds for install.ps1's own automatic step.

## 1. Goals and the invariant

**Invariant:** installing, upgrading, or uninstalling Furphy Addon
Manager itself must never create, modify, or delete anything under any
`Interface\AddOns` or `WTF` folder. This covers install.ps1's own file/
registry work AND its "looking for existing addons" step specifically -
that step may only **read** `Interface\AddOns` (list folders, parse
`.toc` files) and **write to `addons.json`**. It may never download,
extract, `Move-Item`, or `Remove-Item` anything under `Interface\AddOns`,
and it must never touch `WTF` at all (nothing under `WTF` is ever within
Furphy's remit - confirmed nowhere in this codebase does any script read
or write `WTF`; this spec keeps it that way and adds a regression test
for it).

**This invariant is about Furphy's own lifecycle, not about the addon-
sync feature Furphy exists to provide.** Once an addon is *managed*
(whether tracked from a real download via `-Add`/`-Only`/a background
sync, or recorded as-is via the new `-Adopt`), the player has opted into
Furphy keeping that addon current - a later real update the player
approves (or the background service performs automatically, per
existing settings) legitimately writes into `Interface\AddOns` exactly as
it already does today via `Install-AddonPackage`. That is Furphy doing
its job, unaffected by this policy. The one thing this spec adds on top
of that ordinary update path: an addon's very **first** real update
after being adopted backs up its pre-existing folders first (section 2),
because until that first update, `Install-AddonPackage`'s destructive
swap would otherwise be the very first time Furphy ever touched files
the player installed themselves, with no local copy of "what they had"
to fall back to.

**"Adopting" an addon** means recording it as managed exactly as it sits
on disk right now - name, source id, its folders, and the version string
its own `.toc` declares - with **no download and no file write** under
`Interface\AddOns`. The record's `fileId` stays `null` (Furphy has not
installed anything for it yet). The first time Furphy's normal freshness
check finds this addon's source has a version newer than what the
player's `.toc` already declared, it is offered like any other pending
update - not silently, not automatically, exactly the same "Update"
pill/one-click flow every other managed addon already uses.

**Folders Furphy cannot identify** (no `## X-Curse-Project-ID` or
`## X-Wago-ID` in the primary `.toc`, or no `.toc` at all) are listed and
left alone, exactly as today - never adopted, never guessed at.

## 2. CLI (addon-sync.ps1)

### 2.1 New `-Adopt` parameter

Add to the `param()` block (addon-sync.ps1:140-173), next to `-Scan`:

```
[string[]]$Adopt,
```

Shape: comma-joined top-level **folder names** under the resolved
`-AddonsPath` (not project ids, not `-Scan` JSON) - e.g.
`-Adopt "Auctionator,Auctionator_Config,DBM-Core"`. Normalized the same
way `-Remove` already is, via the existing `ConvertTo-ExpandedStringArray`
(addon-sync.ps1:3961-3999) - reused verbatim, no new normalizer needed,
since these are plain strings, not CurseForge/Wago target tokens.

Folder names, not ids, because the CLI re-derives everything else
(title/version/curseId/wagoId) itself by reading each named folder's own
primary `.toc` via the existing `Get-FolderTocInfo` (addon-sync.ps1:1579,
the exact function `-Scan` already uses) - this keeps `-Adopt`
independently testable (a test can call it directly against a fixture
folder, no `-Scan` round-trip needed) and keeps the two `install.ps1`
child-process calls (`-Scan` then `-Adopt`) from having to shuttle
structured JSON through command-line args.

### 2.2 How `-Scan` output feeds it

Unchanged `-Scan` (addon-sync.ps1:4595-4636) - still read-only, still
reports `{folder, title, version, hasToc, curseId, wagoId}` per untracked
top-level folder. install.ps1's caller (section 3.4 below) filters
`scan.untracked` for rows where `curseId` or `wagoId` is truthy, takes
their `.folder` values, comma-joins them, and passes that string as
`-Adopt`. Folders with neither id are never passed to `-Adopt` at all -
`install.ps1` prints them under "left alone" directly from the `-Scan`
result, same as today.

### 2.3 Grouping folders that share one source id into one record

Handled entirely inside the new `-Adopt` block (placed right after the
existing `-Add` block, addon-sync.ps1:4792, before `-Unpin`), config-only,
no network, no staging directory use:

```
$AdoptTargets = ConvertTo-ExpandedStringArray -RawValues $Adopt
$hasAdopt = $AdoptTargets -and ($AdoptTargets.Count -gt 0)
...
if ($hasAdopt) {
    # 1) Build $ownedFolders exactly like -Scan does (addon-sync.ps1:4598-4607).
    # 2) For each named folder (case-insensitive de-duped, in the order given):
    #      - missing on disk                          -> Skipped, reason "folder not found"
    #      - already in $ownedFolders                 -> Skipped, reason "already tracked"
    #      - Get-FolderTocInfo finds neither id        -> Skipped, reason "no recognizable id"
    #      - a curseId IS present but [int64]::TryParse fails on it -> Skipped,
    #        reason "id not usable". Required because Get-FolderTocInfo's
    #        curseId is an unvalidated raw regex-matched string straight off
    #        the player's own (possibly hand-edited/corrupted) .toc
    #        (addon-sync.ps1:1630-1633) - unlike -Add's ids, which
    #        ConvertTo-TargetToken already validates with the same
    #        [int64]::TryParse before this code path is ever reached. This
    #        folder is skipped WITHOUT throwing and WITHOUT aborting the rest
    #        of the batch - every other named folder must still be processed.
    #        (No equivalent guard is needed for wagoId - it is carried as a
    #        free-text string end to end, same as -Add's own `wago:<ref>`
    #        handling, never parsed as a number.)
    #      - otherwise bucket it (in first-seen order) under a group key:
    #          curseId  -> "cf:<the parsed int64 curseId>"
    #          wagoId   -> "wago:<lowercased wagoId>"   (curseId wins if a folder somehow has both)
    # 3) For each group, in first-bucket-seen order:
    #      - build the same target descriptor Test-RecordMatchesTarget already
    #        understands ({IsWago; ProjectId} or {IsWago=$true; WagoRef}),
    #        reusing the int64 already parsed in step 2 (no second parse), and
    #        check it against $config exactly like the -Add block does
    #        (addon-sync.ps1:4767-4773) - a match means this id is ALREADY
    #        tracked (under a different folder name, or a stale record) ->
    #        every folder in this bucket gets Skipped, reason "id already
    #        tracked as <existing.name>".
    #      - otherwise: create ONE new record using the SAME constructor call
    #        shape -Add itself uses for a brand-new target
    #        (addon-sync.ps1:4778-4781) - `New-AddonRecord -ProjectId <the
    #        group's parsed curseId>` for a CurseForge group, or
    #        `New-WagoAddonRecord -Slug <the group's wagoId>` for a Wago
    #        group. NEVER call either constructor with a placeholder/default
    #        value. This constructor argument is the ONLY thing that
    #        populates `.projectId` (CurseForge) / `.slug` (Wago) - the
    #        IDENTITY fields that `Test-RecordMatchesTarget`
    #        (addon-sync.ps1:4071-4072, 4076-4078), `Sync-SingleAddon`'s and
    #        `Sync-SingleWagoAddon`'s own first working line
    #        (addon-sync.ps1:3267, 3601), and `Get-RecordBackupKey`
    #        (addon-sync.ps1:4092-4110) all key on - a SEPARATE pair of
    #        fields from `.curseId`/`.wagoId` below, which is cross-reference/
    #        backfill metadata every record also carries (addon-sync.ps1:
    #        2793-2796) and does NOT feed any of those four functions.
    #        Skipping the constructor argument (leaving `.projectId`/`.slug`
    #        at their un-set default of `$null`/`0`) would make every future
    #        freshness check for this record query CurseForge project 0 (or
    #        Wago with an empty slug), and would collide every adopted
    #        record's backup directory into the same `backups\0\` /
    #        `backups\wago-\` folder - silently skipping section 2.6's
    #        first-update backup for every adopted addon after the first one
    #        synced, since 2.6 no-ops when its zip file already exists. Then
    #        fill the rest of the record's fields straight from what was
    #        scanned:
    #          .name      = the first bucket member's .toc Title, else its folder name
    #          .version   = that same member's .toc Version (may be $null)
    #          .folders   = every folder name in the bucket, in scan order
    #          .curseId / .wagoId = the group's id (string, as scanned)
    #          .adopted   = $true
    #          .adoptedAt = current UTC ISO-8601 timestamp
    #          .fileId stays $null (New-AddonRecord's own default - never set here)
    #        $config.Add($newRecord); this record is NEVER added to $toSync -
    #        see 2.3.1 below. Row: Status 'Adopted'.
}
```

**2.3.1 Never synced.** In the existing `toSync` decision chain
(addon-sync.ps1:4891-4935), `-Adopt` must join the network-free branch:

```
} elseif ($hasRemove -or $hasFlagsOnly -or $hasRollback -or $hasAdopt) {
    # Nothing to add here: remove-only, flags-only, rollback-only and/or
    # adopt-only runs stay network-free.
}
```

This is the entire mechanism that keeps adoption from ever touching
`Interface\AddOns` - a record `-Adopt` just created is never handed to
`Sync-SingleAddon`/`Sync-SingleWagoAddon` in the same run that created
it, so `Install-AddonPackage` never runs for it here at all.

### 2.4 New schema fields

Add to `New-AddonRecord` (addon-sync.ps1:2771-2800), alongside the
existing defaults:

```
adopted   = $false
adoptedAt = $null
```

(`New-WagoAddonRecord` inherits these for free, same as every other
field, since it builds on `New-AddonRecord`.)

Add the matching backfill to `Initialize-AddonRecordFields`
(addon-sync.ps1:2827-2913), same pattern as every other field there:

```
if (-not (Get-Member -InputObject $Record -Name 'adopted' -MemberType NoteProperty)) {
    Add-Member -InputObject $Record -NotePropertyName 'adopted' -NotePropertyValue $false
}
if (-not (Get-Member -InputObject $Record -Name 'adoptedAt' -MemberType NoteProperty)) {
    Add-Member -InputObject $Record -NotePropertyName 'adoptedAt' -NotePropertyValue $null
}
```

No other file needs to know these fields exist to carry them through:
addon-server.ps1's `/api/state` clone loop (addon-server.ps1:7108-7112)
and the CLI's own `-Json`/`-Status` clone (`Add-CompatFieldsToAddonClone`,
addon-sync.ps1:2691-2715) both already copy every property on a record
generically - confirmed by reading both; this is the exact same "free
ride" pattern already documented on `requiredDeps`/`optionalDeps` there.
**No addon-server.ps1 code change is needed for `adopted`/`adoptedAt` to
reach the SPA.**

### 2.5 How the freshness check treats an adopted record

New helper, added near `Get-VersionFromDisplayName`
(addon-sync.ps1:1691-1698):

```
function Get-NormalizedVersionString {
    <#
      Loose, source-agnostic version-string comparison for adopted-record
      freshness (section 2.5) - addon version strings are arbitrary free
      text (toc authors write "10.2.1", "v1.5", "Classic-1.15.2b", a date
      stamp, ...), not semver, so this only strips what varies for
      genuinely-cosmetic reasons (surrounding whitespace, a single
      leading v/V) and lowercases for a case-insensitive compare. Two
      strings that mean the same release but differ in any other way
      (e.g. "1.2" vs "1.2.0") are NOT treated as equal - an unmatched
      comparison always falls through to "update available", never to a
      false "up to date" (see 2.5's own reasoning below).
    #>
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $v = $Version.Trim()
    $v = $v -replace '^[vV](?=[0-9])', ''
    return $v.Trim().ToLowerInvariant()
}
```

In `Sync-SingleAddon` (addon-sync.ps1:3218-3552), insert right after
`$selectedFileId = [int64]$selected.id` (line 3371), before the existing
`$needsInstall` block:

```
if ($Record.adopted -and (-not $currentFileId) -and (-not $Force) -and (-not $usingPin)) {
    $normRecorded = Get-NormalizedVersionString -Version $Record.version
    $latestVersionText = Get-VersionFromDisplayName -DisplayName $selected.displayName
    $normLatest = Get-NormalizedVersionString -Version $latestVersionText

    if ($normRecorded -and $normLatest -and ($normRecorded -eq $normLatest)) {
        # Equal -> up to date. Backfill fileId/metadata so every future run
        # treats this exactly like a normal already-installed record - NO
        # install, NO folder touched. Same DryRun gate as every other
        # metadata-only backfill in this function (CHANGELOG Round 4).
        if (-not $DryRun) {
            $Record.fileId = $selectedFileId
            $Record.fileName = $selected.fileName
            if ($selected.user -and $selected.user.username) { $Record.author = $selected.user.username }
            if ($selected.gameVersions) { $Record.latestGameVersions = $selected.gameVersions } else { $Record.latestGameVersions = @() }
            if ($selected.dateCreated) { $Record.latestFileDate = $selected.dateCreated }
            if ($AddonsPath -and ((-not $Record.wagoId) -or (-not $Record.curseId))) {
                $backfillTocIds = Get-TocCrossSourceIds -AddonsPath $AddonsPath -Folders $Record.folders -Flavor $Flavor -InstalledInterface $InstalledInterface
                if ((-not $Record.curseId) -and $backfillTocIds.curseId) { $Record.curseId = $backfillTocIds.curseId }
                if ((-not $Record.wagoId) -and $backfillTocIds.wagoId) { $Record.wagoId = $backfillTocIds.wagoId }
            }
        }
        Write-Log -Level 'INFO' -Message "Adopted addon confirmed up to date: project $projectId ($displayLabel) matches recorded version '$($Record.version)'"
        return [PSCustomObject]@{ Status = 'Up-to-date'; Name = $displayLabel; Version = $Record.version }
    }

    # Different, or undeterminable (either version string missing/blank) ->
    # falls through to the existing $needsInstall logic below, which
    # already computes $needsInstall = $true here (currentFileId is still
    # null) - no change needed to that block itself. Logged with the exact
    # reason so sync.log/an integration test can tell "genuinely newer"
    # apart from "couldn't tell":
    $reason = 'recorded version does not match the latest available version'
    if (-not $normRecorded) { $reason = 'no recorded .toc version to compare' }
    elseif (-not $normLatest) { $reason = 'could not determine the latest version''s own version string' }
    Write-Log -Level 'INFO' -Message "Adopted addon has an update available: project $projectId ($displayLabel) - $reason"
}
```

Mirror this verbatim in `Sync-SingleWagoAddon` (addon-sync.ps1:3554-3819),
inserted after `$selectedFileId = [string]$selected.id` (line 3684), using
`$versionText = $selected.label` in place of `Get-VersionFromDisplayName`
(matching that function's own existing `$versionText` derivation at line
3725) and `wago:$slug` in the log messages (matching every other message
in that function).

**Why "undeterminable -> update available" and never a silent "up to
date":** a record this unsure about must never claim to be current
without ever having actually verified it - that would leave a genuinely
outdated player-installed addon looking falsely fine forever. Offering
it as a normal pending update is always safe (the player controls
whether/when it actually installs) and matches how a version mismatch is
already handled everywhere else in this function.

### 2.6 First update of an adopted addon backs up the existing folders

New helper, added near `Save-BackupZip` (addon-sync.ps1:1704):

```
function Save-PreAdoptBackupZip {
    <#
      First-update safety net for an adopted record (ADOPT-SPEC.md 2.6):
      Save-BackupZip archives the PACKAGE JUST INSTALLED (moved from
      staging after a successful swap) - useless as a fallback the very
      first time Furphy ever installs anything for a record whose folders
      were never Furphy's own download. Called once, immediately before
      Install-AddonPackage's destructive per-folder swap, only when
      $Record.adopted -and $isNewInstall are both true (i.e. fileId is
      about to go from null to non-null for the first time ever) - zips
      every one of $Folders (the record's OWN folders, exactly as
      -Adopt recorded them; still genuinely on disk here, untouched,
      since nothing has written to them since adoption) into
      ROOT\backups\<key>\adopted-original.zip. A fixed name, not a
      fileId - this is a snapshot of what the PLAYER had, not a
      CurseForge/Wago file, and Save-BackupZip's own pruning (2.6.1
      below) must never delete it. Idempotent: does nothing if that file
      already exists (a retried run must not silently overwrite the
      player's real original with whatever is on disk NOW, which could
      already be Furphy's own first attempt) or if none of $Folders
      exist on disk at all (nothing to back up). Best-effort throughout -
      a backup failure must never block an update the player asked for;
      logged and swallowed, same contract as Save-BackupZip.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)]$Folders,
        [Parameter(Mandatory = $true)][string]$BackupsRoot,
        [Parameter(Mandatory = $true)]$ProjectId
    )
    try {
        $existingFolders = @($Folders | Where-Object { Test-Path -LiteralPath (Join-Path -Path $AddonsPath -ChildPath $_) -PathType Container })
        if ($existingFolders.Count -eq 0) { return }
        $projectDir = Join-Path -Path $BackupsRoot -ChildPath ([string]$ProjectId)
        if (-not (Test-Path -LiteralPath $projectDir)) { New-Item -ItemType Directory -Path $projectDir -Force | Out-Null }
        $destPath = Join-Path -Path $projectDir -ChildPath 'adopted-original.zip'
        if (Test-Path -LiteralPath $destPath) { return }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmpZip = $destPath + '.tmp'
        if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
        $fs = [System.IO.File]::Open($tmpZip, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($folderName in $existingFolders) {
                $folderPath = Join-Path -Path $AddonsPath -ChildPath $folderName
                foreach ($f in (Get-ChildItem -LiteralPath $folderPath -Recurse -File -Force)) {
                    $entryName = ($folderName + '/' + $f.FullName.Substring($folderPath.Length + 1)) -replace '\\', '/'
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entryName) | Out-Null
                }
            }
        } finally {
            $archive.Dispose()
            $fs.Dispose()
        }
        Move-Item -LiteralPath $tmpZip -Destination $destPath -Force
    } catch {
        Write-Log -Level 'WARN' -Message "Could not back up pre-adopt folders for $ProjectId before its first update: $($_.Exception.Message)"
    }
}
```

Call site: `Sync-SingleAddon`, immediately before the existing
`Install-AddonPackage` call (addon-sync.ps1:3454):

```
if ($isNewInstall -and $Record.adopted) {
    Save-PreAdoptBackupZip -AddonsPath $AddonsPath -Folders $Record.folders -BackupsRoot $BackupsPath -ProjectId $projectId
}
$newFolders = Install-AddonPackage -ZipPath $zipPath -ProjectId $projectId -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders
```

Mirror in `Sync-SingleWagoAddon` before its own `Install-AddonPackage`
call (line 3746), passing `-ProjectId (Get-RecordBackupKey -Record $Record)`
(the same `$backupKey` that call site already computes one line above it).

**2.6.1 Save-BackupZip must not prune it away.** `Save-BackupZip`
(addon-sync.ps1:1704-1775) deletes every `*.zip` in the project's backup
folder whose basename is not in `$keepIds` (lines 1753-1771) - the very
next real update of a record that was JUST adopted would otherwise
delete `adopted-original.zip` moments after `Save-PreAdoptBackupZip`
created it, since `"adopted-original"` matches no fileId. One-line fix
at line 1753-1754, right after `$keepIds` is constructed:

```
$keepIds = New-Object 'System.Collections.Generic.HashSet[string]'
[void]$keepIds.Add([string]$FileId)
[void]$keepIds.Add('adopted-original')
```

Harmless (a no-op `Contains` check) for every non-adopted record, whose
backup folder never has a file by that name.

### 2.7 `-Add` is unchanged

`-Add`'s own behavior (download + install for an explicit target, used
by the SPA's "Take over"/"Add addon" flows and by any manual CLI use) is
untouched by this spec - it still creates a fresh `fileId = $null` record
and syncs it in the same run (addon-sync.ps1:4764-4792, 4915-4923), still
installs from the network. Section 0 explains why that is correct to
leave alone.

### 2.8 Help text and JSON output

Update the header comment's USAGE/EXAMPLES (addon-sync.ps1:19-138) to
list `-Adopt <folder[]>` next to `-Scan`, one EXAMPLES line:
`addon-sync.ps1 -Adopt Auctionator,DBM-Core -Flavor retail -Json`.

`$actionLabel` selection (addon-sync.ps1:5049-5060) gains one more
`elseif`, checked after `$hasAdd` and before `$hasRemove` (adoption is
config-only like `-Remove`/flags, so it belongs in that part of the
chain):

```
} elseif ($hasAdopt) {
    $actionLabel = 'adopt'
}
```

`jsonResults` (addon-sync.ps1:5081-5090) gains two additive fields, both
already carried on `$resultsRows` entries by section 2.3's block above
(`.Folders`, `.Reason` - null/empty for every non-adopt row, exactly like
the existing `.WagoSlug` is null for a CurseForge row):

```
$jsonResults.Add([PSCustomObject]@{
        status    = $r.Status
        name      = $r.Name
        version   = $r.Version
        projectId = $r.ProjectId
        fileId    = $r.FileId
        wagoSlug  = $r.WagoSlug
        folders   = $r.Folders
        reason    = $r.Reason
    })
```

Example `-Adopt -Json` output (two folders bundled under one CurseForge
id, one folder with no recognizable id never even passed in by
install.ps1, one already-tracked id):

```json
{
  "action": "adopt",
  "flavour": "retail",
  "installedFlavours": ["retail"],
  "results": [
    { "status": "Adopted", "name": "Auctionator", "version": "5.20.3", "projectId": 61870, "fileId": null, "wagoSlug": null, "folders": ["Auctionator", "Auctionator_Config"], "reason": null },
    { "status": "Skipped", "name": "OldHelper", "version": "", "projectId": 55555, "fileId": null, "wagoSlug": null, "folders": ["OldHelper"], "reason": "id already tracked as Old Helper" }
  ],
  "addons": [ "...every current addons.json record, generic clone, adopted/adoptedAt included..." ],
  "clientBuild": "...",
  "clientInterface": 120100
}
```

## 3. Installer (install.ps1)

### 3.1 Weighted step table (the "honest, determinate" progress bar)

New script-scope table, defined near the top next to `Update-WizardProgress`
(install.ps1:172-183) - one place, used by both the wizard and (for the
step-key argument shape, even though it never renders a bar) the console
flow:

```
# ADOPT-SPEC.md 3.1: cumulative PERCENT-COMPLETE-BEFORE-THIS-STEP-BEGINS
# for every step Invoke-FurphyInstallSteps/Invoke-InstallCopyAndBuildSteps
# can reach on the ONE path the interactive wizard ever actually runs (a
# plain, non -Upgrade install - -Upgrade is only ever set by the
# self-updater's own silent -Console relaunch, never by a human clicking
# Install; see install.ps1's own -Upgrade param doc comment). Weights are
# relative wall-clock share, not a promise of exact timing - tuned so the
# bar visibly moves at every real step boundary and spends most of its
# span on the two genuinely slow steps (copying+building host\, and the
# app+ui\ file copy), never on the near-instant registry/shortcut steps.
$Script:WizardStepStart = [ordered]@{
    'stop-running'   = 0
    'copy-app'       = 5
    'copy-host'      = 20
    'legacy-cleanup' = 60
    'shortcut'       = 65
    'protocol'       = 70
    'adopt'          = 75
    'installed-apps' = 90
    'done'           = 95
}
```

(`100` is reached only by the success screen itself, section 3.6 - never
inside a step body, so a bar that stops at 95% on a genuine mid-run
failure correctly reads as "did not finish", not "finished".)

### 3.2 `Write-Step`/`Update-WizardProgress` rewrite

`Update-WizardProgress` (install.ps1:174-183) gets a two-line label (a
title label the wizard already has space for, plus a new detail label)
and a real percent, and is now called with named step keys instead of a
single free-text message:

```
$Script:WizardActive = $false
$Script:WizardProgressTitleLabel = $null
$Script:WizardProgressDetailLabel = $null
$Script:WizardProgressBar = $null
$Script:WizardLastPercent = 0
function Update-WizardProgress {
    param(
        [string]$Title,
        [string]$Detail,
        # -1 (default) = do not move the bar - used by a plain Write-Info/
        # Write-Warn2 call that only updates the detail line.
        [int]$Percent = -1
    )
    if (-not $Script:WizardActive) { return }
    try {
        if ($Title -and $Script:WizardProgressTitleLabel) { $Script:WizardProgressTitleLabel.Text = $Title }
        if ($Detail -and $Script:WizardProgressDetailLabel) { $Script:WizardProgressDetailLabel.Text = $Detail }
        if ($Percent -ge 0 -and $Script:WizardProgressBar) {
            # Never a backwards jump, even if a caller passes a stale/lower
            # value by mistake - the bar only ever holds or advances.
            $clamped = [Math]::Max($Script:WizardProgressBar.Value, [Math]::Min(100, $Percent))
            $Script:WizardProgressBar.Value = $clamped
            $Script:WizardLastPercent = $clamped
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        # Must never block/abort the install itself.
    }
}
# Sub-progress within one step's own band, for a step with countable work
# (files copied, folders looked at) - Start/End are that step's own
# entries from $Script:WizardStepStart (End = the NEXT step's Start, or
# 100 for the last step).
function Update-WizardSubProgress {
    param(
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End,
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total,
        [string]$Detail
    )
    if ($Total -le 0) { return }
    $frac = [Math]::Min(1.0, [double]$Current / [double]$Total)
    $pct = $Start + [int][Math]::Round(($End - $Start) * $frac)
    Update-WizardProgress -Detail $Detail -Percent $pct
}
```

`Write-Step`/`Write-Info`/`Write-Warn2` (install.ps1:143-161) become:

```
function Write-Step {
    param([string]$Message, [int]$Percent = -1)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
    Update-WizardProgress -Title $Message -Percent $Percent
    Write-InstallLogLine "== $Message =="
}
function Write-Info {
    param([string]$Message)
    Write-Host "  $Message"
    Update-WizardProgress -Detail $Message
    Write-InstallLogLine "  $Message"
}
function Write-Warn2 {
    param([string]$Message)
    Write-Host "  WARNING: $Message" -ForegroundColor Yellow
    Update-WizardProgress -Detail "WARNING: $Message"
    Write-InstallLogLine "  WARNING: $Message"
}
```

`Write-Info`/`Write-Warn2` never move the bar (`-Percent` omitted/-1) -
only the DETAIL line changes on every existing call site, with zero call-
site edits needed there. Every existing `Write-Step 'text'` call site
gains a `-Percent $Script:WizardStepStart['<key>']` argument matching its
own step (listed in 3.4/3.5). **Console flow automatically mirrors this
one-for-one**: `Write-Host` runs unconditionally inside `Write-Step`/
`Write-Info`/`Write-Warn2` regardless of `$Script:WizardActive`, so the
exact same title/detail text the wizard shows is exactly what `-Console`
prints - there is only one set of strings to get right, not two.

### 3.3 Wizard control changes (`Show-InstallWizard`, install.ps1:2803+)

- `$progressBar.Style` (install.ps1:2902): `Marquee` -> `Continuous`.
  `$progressBar.Minimum = 0; $progressBar.Maximum = 100`. Drop
  `$progressBar.MarqueeAnimationSpeed` (meaningless on `Continuous`).
- Replace the single `$progressLabel` (install.ps1:2906-2911) with two
  labels stacked in the same footprint: `$progressTitleLabel` (bold-ish,
  one line, the current step's own name) directly under the bar, and
  `$progressDetailLabel` (regular weight, up to two lines, the latest
  info/warning text) beneath it. Same `Font`/color contrast this file
  already uses elsewhere - no new color tokens needed, this is a WinForms
  desktop dialog, not an Artifact.
- In `$btnInstall.Add_Click` (install.ps1:2950-3007), right after
  `$Script:WizardActive = $true`, add:
  ```
  $Script:WizardProgressTitleLabel = $progressTitleLabel
  $Script:WizardProgressDetailLabel = $progressDetailLabel
  $Script:WizardProgressBar = $progressBar
  $progressBar.Value = 0
  ```
- On the **error branch** (install.ps1:2999-3006): do not reset the bar
  backwards - leave it exactly where it stopped (an unfinished bar next
  to an error message is itself informative: "it got this far"). No code
  change needed here beyond what 3.2 already guarantees (`Update-
  WizardProgress` never lowers the value).
- On the **success branch** (install.ps1:2957-2970): explicitly set
  `$progressBar.Value = 100` right before building the Close/Open buttons -
  **except when `$Script:DowngradeSkipped` is `$true`** (folded from
  critic review): that path returns out of `Invoke-FurphyInstallSteps`
  after only the `stop-running` (0%) step ever ran (install.ps1:2452-2473
  - the version-compare guard returns before `copy-app` even starts), yet
  the SAME `$btnInstall.Add_Click` success branch runs either way (only
  the label text differs by `$Script:DowngradeSkipped`, per 3.6) and
  Close/Open buttons are built unconditionally in both cases - so without
  this exception the bar would jump 0% -> 100% with zero real work done,
  visually claiming a completed install for a run that copied nothing.
  `100` stays reached in every OTHER case (a genuine install/upgrade that
  ran the real steps) - see 3.1:
  ```
  if (-not $Script:DowngradeSkipped) { $progressBar.Value = 100 }
  ```

### 3.4 Exact step list, weights, and every user-facing string

All of these replace `install.ps1`'s current wording; every line below is
printed **identically** by the wizard's title/detail labels and by the
`-Console` flow's `Write-Host` output (section 3.2's mirroring).

| Step key | Start% | Write-Step title | Notes / sub-progress |
|---|---|---|---|
| `stop-running` | 0 | `Checking for a running copy of Furphy` | New `Write-Step` call added right before the existing `Invoke-InstallStopRunningApp` call in `Invoke-FurphyInstallSteps` (install.ps1:2422) - today that call has no `Write-Step` of its own, so the bar has nothing to show at 0%. No behavior change, just a label. |
| `copy-app` | 5 | `Installing Furphy Addon Manager into <appDest>` (unchanged text, install.ps1:1677/1679) | Sub-progress via `Update-WizardSubProgress -Start 5 -End 20 -Current <n> -Total ($codeFiles.Count)` inside the existing `foreach ($f in $codeFiles)` loop (install.ps1:1687-1694), `-Detail "Copying <f>..."`. The bulk `ui\` copy (install.ps1:1695-1703) is one further jump to 20% once it and settings.json/jobs\ finish - it is a handful of small files copied near-instantly as one `Copy-Item -Recurse`, not worth a second per-file loop. |
| `copy-host` | 20 | `Copying and building the native host` (renamed from `Copying the native host (host\)`, install.ps1:1733 - folded the build phase into the same title since together they are the single slowest step) | Two sub-phases inside the SAME 20-60% band: (a) copying host files - a 20-30% sub-band, itself split into three FIXED, non-overlapping ranges to blend the three structurally different copy operations at install.ps1:1737-1766 honestly rather than guessing at one shared `-Total` (folded from critic review - the original single-`-Total` instruction did not say how): **20-24%** the fixed 3-item named-file loop (install.ps1:1737-1743), `Update-WizardSubProgress -Start 20 -End 24 -Current <n> -Total 3` incremented once per loop iteration regardless of whether that particular file existed to copy; **24-27%** the `host\lib\` copy (install.ps1:1745-1751), which is one non-enumerated `Copy-Item -Recurse` with no per-item count available - `Write-Info 'Copying required files...'` at a flat jump to 27% immediately before that single call (same "no fake interior signal" principle as the build phase below), or straight to 24% with no jump at all if `$libSrc` does not exist (the existing `else` branch); **27-30%** the `host\bin\` loop (install.ps1:1753-1761), `Update-WizardSubProgress -Start 27 -End 30 -Current <n> -Total (Get-ChildItem -LiteralPath $binSrc -File).Count` per file copied when `$binSrc` exists and is non-empty - but because `Update-WizardSubProgress` no-ops when `-Total` is `0` or less (section 3.2), and `host\bin\` is a fallback that can legitimately be empty or absent, the caller must ALSO call a plain `Update-WizardProgress -Percent 30` right after this loop unconditionally (whether or not `$binSrc` existed or had any files) so the band always closes out to exactly 30%, never stalling at 27% on the common case where `host\bin\` is empty; (b) building - `Write-Info 'Building the native host - this can take a few seconds...'` at a flat jump to 30% (install.ps1:1773, right before the `build-host.ps1` call; if step (a) already reached 30% via its own unconditional close-out above, this call is a no-op per the bar's own "only ever holds or advances" clamp, section 3.2) with **no** interior sub-progress, deliberately: `csc.exe` gives no incremental signal, and faking one would be exactly the dishonest bar Eric is complaining about. The band holds at 30% for the build's real duration, then the NEXT step's own Start (60%) closes it out the moment `Invoke-InstallCopyAndBuildSteps` returns. |
| `legacy-cleanup` | 60 | `Cleaning up old files from a previous version` (renamed from `Cleaning up legacy launcher files`, install.ps1:2566 - "legacy launcher" is internal jargon) | No sub-progress - a handful of `Test-Path`/`Remove-Item` calls, effectively instant. |
| `shortcut` | 65 | `Creating your desktop shortcut` (renamed from `Creating desktop shortcut`, install.ps1:2592 - matches the friendlier, second-person tone of the rest of this table) | Skipped-with-reason (`-NoShortcuts`, or the scratch-run guard) keeps today's `Write-Info`/`Write-Warn2` text unchanged - those are already plain. |
| `protocol` | 70 | `Setting up CurseForge install links` (renamed from `Registering the curseforge:// install-link handler`, install.ps1:2628 - drops the raw protocol string from the headline; the existing `Write-Info 'Registered. Clicking Install on a CurseForge addon page now opens here.'` already explains it in plain terms and is unchanged) | No sub-progress - one child-process call. |
| `adopt` | 75 | `Looking for addons you already have` (renamed from `Looking for existing addons to take over`, install.ps1:2661 - see 3.5 for the full rewritten body) | Sub-progress is per FLAVOUR processed, not per addon: `Update-WizardSubProgress -Start 75 -End 90 -Current <flavourIndex> -Total ($script:firstClassInstalled.Count)` after each flavour's iteration of `foreach ($def in $script:firstClassInstalled)` finishes. **`<flavourIndex>` counts EVERY iteration of that loop, including one that hits the existing `continue` at install.ps1:2680 when a flavour's `Interface\AddOns` folder does not exist** (folded from critic review - increment a running counter at the very top of the loop body, BEFORE the `Test-Path`/`continue` check, and call `Update-WizardSubProgress` with that counter once per iteration regardless of which branch the rest of the loop body took; a skipped flavour still counts as one unit of "looked at", it just had nothing to scan). This is the only choice that keeps `-Total = $script:firstClassInstalled.Count` an accurate denominator and guarantees the band reaches exactly 90% on the LAST iteration every time, on every machine - counting only processed (non-skipped) flavours would either stall short of 90% (if the last flavour in the list is skipped) or, worse, silently divide by a `-Total` that no longer matches the denominator the percentages were computed against. (Per-addon granularity is not observable from install.ps1 - both `-Scan`/`-Adopt` calls are separate child processes that only report their JSON result at exit, not incrementally - so per-flavour is the honest, real unit of "countable work" available here. On the overwhelmingly common single-flavour machine this is one jump straight to 90%, same as `protocol`/`shortcut` above - and that is fine, since -Scan/-Adopt are now both purely local, fast, no-network calls, unlike the old -Add-based version of this step.) |
| `installed-apps` | 90 | `Registering with Windows Settings > Apps` (unchanged, install.ps1:2750) | No sub-progress - a handful of `Set-ItemProperty` calls. |
| `done` | 95 | (no further `Write-Step` - the success screen itself, section 3.6, sets the bar to 100) | |

### 3.5 Step 6 (`adopt`) rewritten body - exact strings

Replaces install.ps1:2660-2737 in full. Per first-class installed
flavour (unchanged filter, `$script:firstClassInstalled`, unchanged
multi-flavour `-- <Label> --` header):

```
$scanJson = & powershell.exe ... -AddonsPath $flavourAddonsPath -Flavor $def.Id -Scan -Json
$scan = ... # unchanged parse
if (-not $scan) {
    Write-Info 'Could not check this folder for existing addons - skipped.'
    continue
}
$untracked = @($scan.untracked)
$recognizable = New-Object 'System.Collections.Generic.List[string]'
$unmanaged = New-Object 'System.Collections.Generic.List[string]'
foreach ($u in $untracked) {
    if ($u.curseId -or $u.wagoId) { $recognizable.Add([string]$u.folder) }
    else { $unmanaged.Add([string]$u.folder) }
}

if ($recognizable.Count -eq 0) {
    Write-Info 'No existing addons found here to add.'
} else {
    $folderArg = [string]::Join(',', $recognizable.ToArray())
    $adoptJson = & powershell.exe ... -AddonsPath $flavourAddonsPath -Flavor $def.Id -Adopt $folderArg -Json
    $adoptResult = $null
    try { $adoptResult = $adoptJson | ConvertFrom-Json } catch { $adoptResult = $null }
    if ($adoptResult -and $adoptResult.results) {
        $adoptedNames = @($adoptResult.results | Where-Object { $_.status -eq 'Adopted' } | ForEach-Object { $_.name })
        if ($adoptedNames.Count -gt 0) {
            Write-Info "Found $($adoptedNames.Count) addon(s) already in your AddOns folder - Furphy is now keeping track of them."
            foreach ($name in $adoptedNames) { Write-Info "  $name" }
        } else {
            Write-Info 'No existing addons found here to add.'
        }
        # Fold-through (closes a gap uncovered while folding critic item 3):
        # a folder $recognizable classified as having SOME id (curseId or
        # wagoId truthy, per the loop above) can still come back Skipped
        # from -Adopt itself - most concretely "id not usable" (section
        # 2.3's new non-numeric-curseId guard), since install.ps1's own
        # $recognizable/$unmanaged split only checks id PRESENCE, not
        # VALIDITY, and cannot know a curseId is unparseable without
        # calling -Adopt. Without this, such a folder is neither counted as
        # adopted NOR listed under "left alone" below - it would simply
        # vanish from the wizard's output with no explanation at all. Any
        # 'Skipped' row here (other than "already tracked", which -Scan's
        # own $ownedFolders filtering already makes vanishingly rare on a
        # first-run adopt step, and is not worth a player-facing line) folds
        # into the SAME "left alone" folder list the truly-unrecognizable
        # ones use, so nothing a player's own eyes could count on disk goes
        # unexplained:
        foreach ($skipped in @($adoptResult.results | Where-Object { $_.status -eq 'Skipped' -and $_.reason -notlike '*already tracked*' })) {
            foreach ($f in @($skipped.folders)) { $unmanaged.Add([string]$f) }
        }
    } else {
        Write-Warn2 'Could not read the results of adding your existing addons - check sync.log.'
    }
}

if ($unmanaged.Count -gt 0) {
    Write-Info "Furphy could not tell what $($unmanaged.Count) folder(s) are, so it left them alone:"
    foreach ($name in $unmanaged) { Write-Info "  $name" }
}
```

Everything Eric flagged is gone: no "Taking over", no "reinstalling", no
"untracked", no raw CurseForge/Wago ids anywhere in this block (ids only
ever appeared in the OLD `Write-Info ("  " + $r.status + ": " + $r.name)`
loop, which read internal `-Add` status words like `Installed` - the new
loop only ever prints an addon's own name). `-SkipAdopt`'s existing
behavior/wording (install.ps1:2735-2736, `'Skipped taking over existing
addons (-SkipAdopt).'`) is renamed to match: `'Skipped adding your
existing addons (-SkipAdopt).'` - the flag itself keeps its name
(`-SkipAdopt` is documented CLI surface, not player-facing UI text).

### 3.6 Success / downgrade / error screens

Wizard success (install.ps1:2964-2970), rewritten to state the invariant
plainly and to surface the adopted count when non-zero (requires
`Invoke-FurphyInstallSteps` to stash `$Script:LastAdoptedCount` - a
simple running total the rewritten step 6 body increments per flavour,
reset to 0 at the top of `Invoke-FurphyInstallSteps`):

```
if ($Script:DowngradeSkipped) {
    $lblStatus.Text = 'Nothing was changed - a newer version is already installed there.'
    $progressLabel.Text = "App: $($script:appDest)`r`nThis copy is older than what's already installed, so it was left alone."
} else {
    $lblStatus.Text = 'Furphy Addon Manager is ready to use.'
    $summaryLines = New-Object 'System.Collections.Generic.List[string]'
    $summaryLines.Add("Installed to: $($script:appDest)")
    $summaryLines.Add('Your addons and WoW settings were not changed - Furphy only manages the copy it keeps track of.')
    if ($Script:LastAdoptedCount -gt 0) {
        $summaryLines.Add("Found $($Script:LastAdoptedCount) addon(s) you already had - nothing was downloaded or changed.")
    }
    $progressLabel.Text = [string]::Join("`r`n", $summaryLines.ToArray())
}
```

(`$progressLabel` here is the WinForms label that already exists at this
point in the success screen - not to be confused with the in-progress
`$progressTitleLabel`/`$progressDetailLabel` from section 3.3, which stop
being read once the Close/Open buttons replace `$btnInstall`.)

Error screen (install.ps1:2999-3006): unchanged behavior (still shows
`$_.Exception.Message` plainly); the only change is the progress bar no
longer resets (3.3) so a failure mid-`adopt` visibly stopped at ~75-90%,
not at 0% or a meaningless full bar.

### 3.7 `-SkipAdopt` and every other flag

Untouched. `-SkipAdopt` still skips the whole step (now step key
`adopt`); `-NoShortcuts`/`-NoProtocol`/`-Uninstall`/`-Upgrade`/`-Relaunch`
are unaffected by anything in this spec.

## 4. SPA (ui/app.js, ui/index.html)

### 4.1 Pill for an adopted addon before its first check

`Components.Chip.forStatus` (app.js:3017-3067) needs one new priority,
placed at an EXACT ordinal position, not merely somewhere in a range
(folded from critic review - "after Priority 3 and before the default" as
originally worded also technically permits inserting ahead of Priority 6
"pinned" (app.js:3049-3060) or Priority 7 "ignoreUpdates" (app.js:
3061-3063), either of which would let a freshly-adopted-but-unverified
addon's "Not checked yet" pill silently override a "Pinned" or "Ignoring
updates" state the player deliberately set - exactly the outcome the
"Priority 7.5" label on the code below already implies but the prose
range did not pin down). The new check goes IMMEDIATELY BEFORE the final
default return (app.js:3064-3066) and nowhere else - i.e. strictly AFTER
every other named priority, including Priority 6 (pinned) and Priority 7
(ignoreUpdates), so a pin or an ignored-updates choice always wins over an
unverified "Not checked yet" state, and an unverified adopted record only
ever falls through to this new pill once every other real signal has been
ruled out:

```
// Priority 7.5 (ADOPT-SPEC.md 4.1): adopted, still on fileId=null, and no
// updateAvailable entry has ever been computed for it yet (the periodic
// background check hasn't run since it was adopted) - must not fall
// through to the default "Up to date" pill below without ever having
// actually verified that.
if (addon.adopted && !addon.fileId && !addon.updateAvailable) {
    return build("Not checked yet", "chip-muted", "Furphy hasn't checked this addon for updates yet.");
}
```

No other Chip/pill change needed. Once the CLI's own freshness path
(section 2.5) runs for this record (the existing periodic `check` job,
`addon-sync.ps1 -DryRun` with no filter, already processes every record
including this one - addon-server.ps1:2398-2400, unchanged), one of two
things happens with zero further SPA changes required:
- versions matched -> `fileId` gets backfilled -> this addon now looks
  exactly like any other up-to-date managed addon (falls to the existing
  default pill, Priority 8).
- versions differed -> a `Would-update` row with `FileId` populates the
  existing `updateAvailable` state dictionary exactly like a normal
  pending update does (addon-server.ps1:3558-3589) -> the EXISTING
  Priority 3 "Update" pill (app.js:3038-3040) already fires correctly,
  unmodified.

### 4.2 Welcome dialog copy after an install that adopted N addons

This is a **new, additive** notice, separate from - and never shown at
the same moment as - the existing download-based Welcome dialog (section
0): `maybeShowWelcome()` only ever opens when `Store.state.addons.length
=== 0` (app.js:8752), and this new notice only ever opens when at least
one adopted record exists (`length >= 1`) - the two conditions are
mutually exclusive by construction, so no extra guard is needed between
them.

Reuses the existing `#dialog-welcome` markup and `Components.Welcome`
component (both already generic enough) rather than adding a parallel
dialog. `Components.Welcome.open` (app.js:2740-2769) gains a second,
optional mode:

**Correctness note (folded from critic review):** the title's static
markup (`ui/index.html:1529`) has FOUR child nodes in this order: an
`<svg>` icon, a text node `" Found "`, `<span id="welcome-count">`, then
a text node `" addons in your AddOns folder"`. `titleEl.lastChild` is
ONLY that last text node - assigning through it (as an earlier draft of
this section did) leaves the leading `" Found "` text and the
`#welcome-count` span both in place, so the rendered title in "adopted"
mode became something like "Found 3 Furphy found 3 addon(s) you already
had" (duplicated, garbled text) - and even in "download" mode, once ANY
code assigns through `.lastChild`, a second open() call duplicates text
again. The fix below never targets `.lastChild` directly: it strips every
title child EXCEPT the icon on every call (so repeated opens in either
mode are always idempotent - no leftover node from a previous call can
survive), then rebuilds the sentence for the current mode from scratch.
`#welcome-count` is no longer a separately-addressable span (nothing else
in the codebase queries it by id - confirmed by grep across `ui/` and
`tests/`); the count is folded directly into the rebuilt sentence text
for both modes instead, which is simpler and removes the mid-sentence-
span problem entirely rather than working around it:

```
function open(items, options) {
    const mode = (options && options.mode) || "download";
    const list = Utils.qs("#welcome-list");
    list.innerHTML = "";
    items.forEach(function (u) { list.appendChild(itemRow(u)); });
    const titleEl = Utils.qs("#dialog-welcome-title");
    const iconEl = titleEl.querySelector("svg");
    // Strip every child after the icon (the old " Found "/count-span/
    // trailing text, or whatever a PRIOR open() call in the OTHER mode
    // left behind) before rebuilding - never touch .lastChild alone.
    while (titleEl.lastChild && titleEl.lastChild !== iconEl) {
        titleEl.removeChild(titleEl.lastChild);
    }
    const bodyEl = Utils.qs("#welcome-body");
    const adoptBtn = Utils.qs("#welcome-adopt");
    if (mode === "adopted") {
        titleEl.appendChild(document.createTextNode(" Furphy found " + items.length + " addon(s) you already had"));
        bodyEl.textContent = "They're already the way you like them, so Furphy left the files alone and is just keeping track of them from here. You'll see an Update badge here if a newer version ever comes out.";
        adoptBtn.textContent = "Got it";
        adoptBtn.onclick = function () { Components.Dialogs.closeWelcome(); Actions.acknowledgeAdopted(items); };
    } else {
        titleEl.appendChild(document.createTextNode(" Found " + items.length + " addons in your AddOns folder"));
        bodyEl.textContent = "Furphy can start managing these - it re-downloads each one so it can keep them updated from now on.";
        adoptBtn.textContent = "Take over all (" + items.length + ")";
        adoptBtn.onclick = function () { Actions.adoptAll(items.map(targetFor)); };
    }
    Components.Dialogs.openWelcome();
}
```

`index.html`:1529-1530 needs one `id` added so the body paragraph is
addressable (no visual/markup change otherwise). The static `" Found "`/
`#welcome-count`/trailing-text portion of the `<h3>` is left as-is in the
markup (it is only ever a pre-JS fallback - the dialog itself stays
`hidden` until `open()` runs, and `open()` above rebuilds this content
unconditionally on its first call regardless of which mode fires first):

```html
<h3 id="dialog-welcome-title"><svg class="icon"><use href="#icon-download"></use></svg> Found <span id="welcome-count">0</span> addons in your AddOns folder</h3>
<p class="muted-text" id="welcome-body">Furphy can start managing these &mdash; it re-downloads each one so it can keep them updated from now on.</p>
```

New trigger function in `App` (app.js, alongside `maybeShowWelcome`,
around line 8751), called once from `init()` right next to the existing
`maybeShowWelcome()` call site:

```
const ADOPTED_NOTICE_SEEN_KEY = "addonSync.adoptedNoticeSeen.v1";
async function maybeShowAdoptedNotice() {
    const adopted = Store.state.addons.filter(function (a) { return a.adopted; });
    if (adopted.length === 0) return;
    let seen = [];
    try { seen = JSON.parse(localStorage.getItem(ADOPTED_NOTICE_SEEN_KEY) || "[]"); } catch (err) { seen = []; }
    const seenSet = new Set(seen);
    const keyFor = function (a) { return a.projectId ? ("cf:" + a.projectId) : ("wago:" + a.slug); };
    const unseen = adopted.filter(function (a) { return !seenSet.has(keyFor(a)); });
    if (unseen.length === 0) return;
    const items = unseen.map(function (a) { return { curseId: a.projectId || null, wagoId: a.projectId ? null : a.slug, title: a.name, folder: (a.folders && a.folders[0]) || a.name }; });
    Components.Welcome.open(items, { mode: "adopted" });
    try {
        const merged = adopted.map(keyFor);
        localStorage.setItem(ADOPTED_NOTICE_SEEN_KEY, JSON.stringify(merged));
    } catch (err) { /* best-effort only */ }
}
```

`Actions.acknowledgeAdopted` can be a no-op (`function acknowledgeAdopted() {}`)
- the localStorage write already happened when the dialog opened
(marking every currently-adopted record "seen" up front is intentional:
if the player dismisses without reading, re-showing on next launch would
be more annoying than useful, matching `WELCOME_SKIPPED_KEY`'s own
"skip means skip" precedent).

### 4.3 What is explicitly NOT changed

`Actions.adopt`/`Actions.adoptWago`/`Actions.adoptAll` (app.js:5259-5263,
5167-5168), the Settings "Folders Furphy doesn't manage yet" section, and
every "Take over" string UX-SPEC.md already specifies (UX-SPEC.md:84-93,
305, 392-393, 502) stay exactly as they are - see section 0.

## 5. Uninstall

Already correct - confirmed by reading `Invoke-InstallStopRunningApp`'s
`-Uninstall`-guarded block (install.ps1, the same function starting at
1119): it never touches `Interface\AddOns` or `WTF`, and says so in three
places already shipped:

- `Write-Info "App files removed from $appDest"` (install.ps1:1518)
- `Write-Info "Your addon list, settings, logs and backups are kept: $appDest"` (install.ps1:1519)
- `Write-Info "Your AddOns folder(s) were not touched."` (install.ps1:1552)

No wording or behavior change needed for uninstall. Section 6.1's new
tree-hash test covers uninstall alongside install/upgrade specifically
to make this a standing, enforced guarantee rather than an unverified
read of the current code.

## 6. Tests

### 6.1 Tree-hash invariant test (new)

New file `tests/integration/Install.NoAddonDataChange.Tests.ps1`. Uses
`Copy-Fixture` (tests/lib/common.ps1:89) for a scratch WoW root, then
**seeds a `WTF\` folder by hand** before the first snapshot - the checked-
in `fixtures\wowroot` has no `WTF\` at all (confirmed: `find` over the
fixture tree lists only `_retail_/_classic_/_classic_era_/_ptr_\Interface\
AddOns\...`), so the test must create something like
`_retail_\WTF\Account\ACCOUNTNAME\SavedVariables\SomeAddon.lua` with a
few lines of fake Lua itself, so the invariant is actually exercised, not
vacuously true over an empty folder.

```
function Get-TreeFingerprint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @('<absent>') }
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
        Sort-Object -Property FullName |
        ForEach-Object {
            $rel = $_.FullName.Substring($Path.Length).TrimStart('\')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            "$rel|$hash"
        }
}
```

Flow, all against `-NoShortcuts -NoProtocol -Console` (never the real
Desktop/registry, per the standing scratch-run rules):

1. `Copy-Fixture`; seed `_retail_\WTF\...` by hand.
2. Snapshot `Interface\AddOns` and `WTF` under `_retail_` -> `$before`.
3. Run `install.ps1 -WowPath $wowRoot ...` (fresh install). Snapshot again
   -> `$afterInstall`. `$afterInstall | Should Be $before` for both trees.
4. Re-run the SAME `install.ps1` again over the now-existing `$appDest`
   (this repo's own existing meaning of "upgrade": re-running the
   installer over an install already there, per install.ps1's own header
   comment "Re-running the installer is safe" and the existing "a plain
   upgrade run (no -Uninstall)" Describe in
   `tests\integration\Cli.InstallRollback.Tests.ps1:210` - NOT the
   `-Upgrade` switch's separate staged self-update path, which is already
   covered by `Install.Downgrade.Tests.ps1` and is not reachable from the
   interactive wizard at all, see 3.1's own note). Snapshot -> `$afterUpgrade`.
   `Should Be $before` again.
5. Run `install.ps1 -WowPath $wowRoot -NoShortcuts -Uninstall -Console`.
   Snapshot -> `$afterUninstall`. `Should Be $before` again.

Use a fixture flavour folder that has at least one recognizable-id addon
(the checked-in fixture has none - every `.toc` in `fixtures\wowroot`
omits `X-Curse-Project-ID`/`X-Wago-ID`, confirmed by reading all of
them) so step 3 actually exercises `-Adopt`, not just an empty "no
existing addons found" path. Either add a small dedicated fixture folder
under `_retail_\Interface\AddOns\` with a real `## X-Curse-Project-ID:`
tag (mirroring `Install.AdoptTestRealms.Tests.ps1`'s own
`New-PtrAdoptWowRoot`-style hand-built fixture, tests/integration/
Install.AdoptTestRealms.Tests.ps1:30-42), or reuse that same helper -
either way, entirely offline (no real CurseForge/Wago call, since
`-Adopt` never makes one).

### 6.2 CLI unit/integration tests for `-Adopt` and adopted freshness

New `tests/unit/Cli.Adopt.Tests.ps1` (pure, offline, dot-sourced or
`Invoke-CliJson` against a hand-built AddOns folder - no network tag):

- a single folder with `X-Curse-Project-ID` -> one `Adopted` row,
  `fileId: null`, `adopted: true`, `adoptedAt` a non-empty ISO timestamp,
  `folders: ["<name>"]`.
- **(folded from critic review, item 2 - the actual `addons.json` record
  this produces, not just the `-Json` results row):** that same
  CurseForge-adopted record's `.projectId` on disk equals the scanned
  `X-Curse-Project-ID`, parsed as an int (not `0`, not `$null`) - assert
  this directly against the written `addons.json`, dot-sourcing or
  `-Status`-reading it back, not just the transient `-Adopt -Json`
  results row (which only carries `.curseId`, a different field - see
  section 2.3). Also assert the record's `.curseId` (the separate
  cross-reference field) is likewise populated. Then assert
  `Get-RecordBackupKey -Record <that record>` returns the scanned
  project id's own string, NOT `"0"` - the concrete regression check for
  the backup-directory-collision bug this finding describes.
- two folders sharing the same `X-Curse-Project-ID` -> ONE `Adopted` row
  whose `folders` array contains both names, and whose `.projectId` (not
  just `.curseId`) is the shared id.
- a folder with `X-Wago-ID` only -> one `Adopted` row with `source:
  "wago"`, `wagoSlug` populated, `projectId: null`. **(folded from critic
  review, item 2, Wago side - `Sync-SingleWagoAddon`'s own first working
  line reads `$Record.slug`, addon-sync.ps1:3601, mirroring the
  CurseForge `.projectId` gap exactly):** assert the written record's
  `.slug` equals the scanned `X-Wago-ID` value (not `$null`/empty) and
  that `Get-RecordBackupKey` for it returns `"wago-<that id>"`, not
  `"wago-"`.
- a folder with neither id -> `Skipped`, `reason` mentions "no
  recognizable".
- **(folded from critic review, item 3)** a folder with an `X-Curse-
  Project-ID` value that is present but not parseable as a number (e.g.
  `## X-Curse-Project-ID: not-a-number`, or a value with stray
  whitespace/text a hand-edit could produce) -> that folder alone is
  `Skipped` with `reason` mentioning "id not usable" - and, in the SAME
  `-Adopt` call, an otherwise-normal folder with a valid id listed
  alongside it still comes back `Adopted` (the batch does not abort; no
  uncaught exception/non-zero exit code from this call).
- a folder whose id already matches an existing `addons.json` record ->
  `Skipped`, `reason` mentions "already tracked".
- re-running the exact same `-Adopt` call twice -> second run reports the
  same folders `Skipped` ("already tracked"), `addons.json` still has
  exactly one record for that id (no duplicate).
- confirm **zero** filesystem writes under the AddOns path across all of
  the above (snapshot the folder's own `Get-TreeFingerprint`
  before/after `-Adopt`, identical) - the direct CLI-level version of
  6.1's installer-level check.

New `tests/integration/Cli.AdoptFreshness.Tests.ps1` (tagged `'Network'`
where a real CurseForge/Wago call is unavoidable, matching this
project's existing convention in `Cli.InstallRollback.Tests.ps1`) or,
preferably, built entirely against the existing stub seams
(`FURPHY_TEST_CF_BASEURL`/`FURPHY_TEST_WAGO_BASEURL`, the CF catalogue
seam, `Start-WagoStubServer` - all already used elsewhere in `tests\`) so
it needs no `'Network'` tag at all:

- an adopted record whose `.version` (hand-set in a crafted
  `addons.json`) matches the stub's latest file's normalized version
  string -> a plain (non-`-DryRun`) sync reports `Up-to-date`, `fileId`
  gets backfilled on disk, **and the AddOns folder's own tree fingerprint
  is unchanged** (no install happened).
- same setup but the stub's latest version differs -> `-DryRun` reports
  `Would-update` with a real `FileId`; a real (non-`-DryRun`) run installs
  it, `isNewInstall`/`Installed` semantics aside, ends with `fileId` set
  and folders replaced.
- an adopted record with `.version = $null` (or blank) -> always reports
  `Would-update`/installs on a real run, never silently `Up-to-date`
  (covers the "undeterminable" path from 2.5).
- `Get-NormalizedVersionString` unit-tested directly (dot-sourced) for:
  `"v1.2.3"`/`"1.2.3"` equal; `"  1.2.3  "`/`"1.2.3"` equal;
  `"1.2"`/`"1.2.0"` NOT equal (documents the deliberately-loose-but-not-
  numeric comparison); `$null`/`""`/`"   "` all normalize to `$null`.

### 6.3 First-update backup test

Extends the existing backup/rollback suite
(`tests/integration/Cli.InstallRollback.Tests.ps1`) or a new adjacent
`Describe` in `Cli.AdoptFreshness.Tests.ps1`:

- hand-craft an adopted record + a real folder with real file content
  under the fixture AddOns path; drive its first real (version-mismatch)
  update via the stub seam.
- assert `flavours\<id>\backups\<key>\adopted-original.zip` exists after
  that run and, extracted, contains byte-identical content to what was on
  disk **before** the update ran (snapshot the folder's bytes/hash first).
- run a SECOND real update afterward (stub now serving a newer version
  again) - `adopted-original.zip` must still exist and be byte-identical
  to the ORIGINAL content (never overwritten by the second update; only
  the normal `<fileId>.zip` pair changes) - this is the regression test
  for 2.6.1's `Save-BackupZip` prune fix specifically.
- a record that is NOT adopted never gets an `adopted-original.zip` at
  any point (confirms the guard is `$isNewInstall -and $Record.adopted`,
  not just `$isNewInstall`).

### 6.4 Wizard static tests

Extends `tests/unit/Install.Wizard.Tests.ps1` (same static-source-text +
real-control-construction techniques already used there, lines 61-245):

- `$progressBar.Style` is `Continuous`, not `Marquee`; `Minimum`/`Maximum`
  are `0`/`100` (mirrors the existing Marquee-specific assertions at
  app.js... i.e. install.ps1 lines 80-84/192-196 of that test file,
  updated in place rather than duplicated).
- both `$progressTitleLabel` and `$progressDetailLabel` are constructed
  and added to the form (replacing the single `$progressLabel` assertions
  at lines 168-169/193 of that test file).
- `$Script:WizardStepStart` exists, is non-empty, and its values are
  non-decreasing in the fixed key order `'stop-running','copy-app',
  'copy-host','legacy-cleanup','shortcut','protocol','adopt',
  'installed-apps','done'` (a cheap static assertion against accidental
  reordering/typos in the weight table, same "grep-based, deterministic"
  philosophy the existing installer-dpi tests in that file already use).
- `Update-WizardProgress`'s source never lowers `$Script:WizardProgressBar.Value`
  (grep for the `[Math]::Max(` clamp - a textual regression guard, same
  technique already used for other findings in this file).

### 6.5 Console-flow wording tests

New `Describe` blocks (either a new `tests/integration/Install.
AdoptWording.Tests.ps1`, or added to the existing
`Install.AdoptTestRealms.Tests.ps1`, which already exercises this exact
step end-to-end offline): run `install.ps1 -Console` against a fixture
with at least one recognizable-id folder, assert `$result.StdOut`:

- **matches** `'Looking for addons you already have'`, `'Found \d+ addon'`,
  `'is now keeping track of them'`.
- **does not match** (case-insensitive) any of: `'taking over'`,
  `'reinstalling'`, `'untracked'`, and never prints a bare numeric
  CurseForge project id or a `wago:` token anywhere in this step's output
  (the OLD per-row `status: name` loop was the only place ids could leak
  into stdout; the new loop only prints addon names, section 3.5).
- a folder with no recognizable id still gets a friendly line (assert on
  `'Furphy could not tell what'`), never the old `'no CurseForge or Wago
  id found'` phrasing.
- **(folded from critic review, item 3's fold-through gap)** a folder
  with a truthy but non-numeric `X-Curse-Project-ID` also ends up under
  the SAME `'Furphy could not tell what'` line (via section 3.5's
  fold-through of non-"already tracked" `Skipped` rows into `$unmanaged`)
  rather than silently missing from BOTH the "Found N addon(s)" count and
  the "left alone" list - the regression test for that fold-through
  specifically.

## 7. Docs

| File | Change |
|---|---|
| `README.md` | Line 45: replace `- scans your existing \`AddOns\` folder and adopts anything it recognizes (CurseForge or Wago), so addons you already had become managed - reinstalling each from its source, so give it a minute; skip with \`-SkipAdopt\`` with `- finds addons you already have in your \`AddOns\` folder and starts keeping track of them, exactly as they are - nothing is downloaded or changed; skip with \`-SkipAdopt\``. Line 47: replace `Re-running the installer is safe: it upgrades the app in place and adopts anything new, without touching your addon list, settings, or an addon it already manages.` with the same sentence, unchanged (already accurate - "adopts" here already means the new, non-destructive sense once this ships). |
| `README.txt` | Line 18-19: replace `adopts any addons already in your AddOns folder. Safe to` with `starts keeping track of any addons already in your AddOns folder - nothing is downloaded or changed. Safe to` (continuing into the existing line 19 `re-run any time.`). Line 81: unchanged (`one-click take over` there describes the SPA's Settings section, section 0/4.3 of this spec - correctly left alone). |
| `SPEC.md` | Line 476 (the `install.ps1` "Adopt" paragraph): rewrite to describe the new `-Scan` + `-Adopt` two-call flow (section 3.5) in place of the old `-Scan` + one bulk `-Add` description - state explicitly that no download/install happens. Line 48 (`-Scan` reference doc): add one line documenting the new `-Adopt <folder[]>` mode directly below it, matching this file's own section 2.1/2.8. Everywhere else `Adopt`/`adopt` appears in SPEC.md in the context of the SPA's Settings/Welcome flow (lines 118, 368, 484-488) is describing the OTHER surface (section 0) and stays unchanged. |
| `UX-SPEC.md` | No change to any existing rule - this file's "Adopt" -> "Take over" rename (lines 84-93, 305, 392-393, 502) governs the SPA surface only (section 0/4.3) and is unaffected. Optionally add one new short subsection cross-referencing this spec, noting install.ps1's own first-run step uses plain, un-jargoned wording of its own (section 3.5) that is deliberately NOT "Take over" (install.ps1 is a console/WinForms surface, not the SPA, so UX-SPEC's SPA-string checklist at line 524 does not apply to it either way). |
| `CHANGELOG.md` | New entry at the top, `## Round 45 (1.25.0: honest adoption)`, summarizing: Eric's two verbatim requests (section header of this file), the CLI's new `-Adopt` mode and adopted-record freshness check (section 2), the installer's rewritten step 6 wording and weighted `Continuous` progress bar (section 3), the SPA's new adopted-record pill + one-time notice (section 4), and the new tree-hash invariant test (section 6.1) as the standing regression guard for request 2. |
| `VERSION` | `1.24.0` -> `1.25.0` (no trailing newline, matching the existing file's exact byte shape - confirmed via `cat VERSION` producing no newline before the shell prompt). |
| `addon-server.ps1:10282` | `$Script:Version = '1.24.0'` -> `$Script:Version = '1.25.0'` (the single literal this file's own header already documents as needing to move in lock-step with `VERSION`). |

## 8. Work packages (disjoint file lists)

- **CLI**: `addon-sync.ps1` only. Sections 2.1-2.8.
- **Installer**: `install.ps1` only. Section 3 (all).
- **SPA**: `ui/app.js`, `ui/index.html`, `tests/spa/harness.js`. Section 4,
  plus a new `harness.js` coverage block exercising `Components.Chip.
  forStatus` on a mock `{adopted:true, fileId:null, updateAvailable:null}`
  addon (asserts "Not checked yet") and `Components.Welcome.open(items,
  {mode:"adopted"})` (asserts the title/body/button text from 4.2),
  following the same `win.__furphyTest.Components.*` direct-invocation
  pattern this file already uses for `Components.Welcome.open` at
  `tests/spa/harness.js:1591`.
- **Tests**: everything under `tests\` EXCEPT `tests/spa/harness.js`
  (owned by the SPA package above). Sections 6.1-6.5, i.e. the new
  `Install.NoAddonDataChange.Tests.ps1`, `Cli.Adopt.Tests.ps1`,
  `Cli.AdoptFreshness.Tests.ps1`, the extensions to `Install.Wizard.
  Tests.ps1`, `Cli.InstallRollback.Tests.ps1`, and `Install.
  AdoptTestRealms.Tests.ps1` (or a new `Install.AdoptWording.Tests.ps1`).
- **Docs**: `README.md`, `README.txt`, `SPEC.md`, `UX-SPEC.md`,
  `CHANGELOG.md`, `VERSION`, and `addon-server.ps1`'s single
  `$Script:Version` literal (line 10282 only - no other line of
  `addon-server.ps1` is in scope for this feature at all, per section 2.4's
  "no addon-server.ps1 code change is needed" finding).

Every package above lists disjoint files - any two can be implemented and
reviewed in parallel with no merge collision, PROJECT's own stated
constraint.

**Caveat (folded from critic review):** disjoint FILES is not the same
claim as fully independent WORK. The **Tests** package has a hard
*functional* dependency on CLI + Installer + SPA landing first - most of
its new tests (6.1's tree-hash test needs `-Adopt` to exist at all;
6.2/6.3 need the CLI's new `-Adopt`/freshness/backup behavior; 6.4/6.5
need the installer's rewritten wizard/console wording) will genuinely
FAIL, not merely sit unreviewed, until those other packages' code exists.
This does not change section 8's own claim (true as written: no two
packages ever touch the same file, so implementing/reviewing them
side-by-side never produces a merge conflict) - it only means build/CI
ordering should land CLI+Installer+SPA before treating a red Tests-package
run as a real regression.

## Appendix: Round 45 critic review disposition

Every item in the Round 45 completeness critique was independently
re-verified against the live codebase (not taken on the critic's word)
before folding. All six substantive items held up and are folded in
above - none rejected:

- **Item 2** (`.projectId` never assigned on an adopted CurseForge
  record) - confirmed by direct read of `Test-RecordMatchesTarget`
  (addon-sync.ps1:4061-4082), `Sync-SingleAddon`'s `$projectId =
  [int]$Record.projectId` (line 3267), `Get-RecordBackupKey`
  (4092-4110), and `New-AddonRecord`'s mandatory `-ProjectId`
  (2771-2800). Folded into section 2.3, plus 6.2's tests. **Extended
  while re-checking:** the identical bug exists on the Wago side -
  `Sync-SingleWagoAddon`'s own first working line reads `$Record.slug`
  (line 3601) and `Get-RecordBackupKey`'s wago branch keys off `.slug`,
  not `.wagoId` (confirmed by reading `New-WagoAddonRecord`,
  2802-2824, and the `-Add` block's own `New-WagoAddonRecord -Slug
  $target.WagoRef` call at line 4778) - the critic did not call this
  out, but it is the same gap on the sibling code path, so it is folded
  in alongside the CurseForge fix rather than left half-fixed.
- **Item 3** (unguarded non-numeric `X-Curse-Project-ID`) - confirmed:
  `Get-FolderTocInfo`'s `curseId` is an unvalidated raw regex capture
  (addon-sync.ps1:1630-1633), unlike `-Add`'s ids, which
  `ConvertTo-TargetToken` (4001-4034) already TryParse-guards. Folded
  into section 2.3's skip-reason list and 6.2's tests. **Extended while
  re-checking:** fixing this inside the CLI alone left a gap in
  install.ps1's own reporting (section 3.5) - a folder in that state
  would vanish from the wizard's output entirely (counted in neither the
  "Found N addon(s)" nor the "left alone" list), since install.ps1's
  `$recognizable`/`$unmanaged` split only checks id PRESENCE, not
  validity. Folded into section 3.5 and 6.5.
- **Item 4** (`titleEl.lastChild` welcome-dialog bug) - confirmed by
  direct read of the current, unmodified `Components.Welcome.open`
  (app.js:2754-2764, which never touches title text at all) against the
  static markup's real child-node order (ui/index.html:1529). Folded
  into section 4.2 with a rewritten `open()` that never targets
  `.lastChild`.
- **Item 5** (three under-specified progress bands) - all three
  confirmed against the cited line ranges (install.ps1:1737-1766,
  2680, 2452-2473/2957-2970). Folded into sections 3.3 and 3.4.
- **Item 6** (chip-priority range ambiguity) - confirmed against
  `Components.Chip.forStatus` (app.js:3010-3067). Folded into section
  4.1 with an exact ordinal position.
- **Item 8** (Tests package's functional, non-file dependency) -
  confirmed as an accurate caveat on section 8's own claim. Folded in
  above as a caveat, not a correction (section 8's original claim was
  true as written).

Items 1 and 7 reported no gap found by the critic itself and needed no
spec change.
