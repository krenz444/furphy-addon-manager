GITHUB-SOURCE-SPEC.md
Round 47 (targeting 1.27.0) - GitHub as a third addon source

ASCII only. No code in this file is final implementation - it is the
contract four disjoint work packages build against (section 9). Every
file:line anchor below was read from the live build at
<build root>
on 2026-09-09 (VERSION 1.26.0) - re-check line numbers before editing if the
file has moved since.

=====================================================================
1. Goals
=====================================================================

Eric's guild ships two addons as PRIVATE GitHub releases:
  - github.com/bart-dev-wow/AuraUpdater
  - github.com/bart-dev-wow/TimelineReminders
A shared Patreon-tier GitHub personal access token (rotated occasionally)
is required to read either repo's releases. A one-off script Eric already
trusts does this today (config file with the token + a repo list, GET
/repos/<owner>/<repo>/releases/latest with Bearer auth, first .zip asset,
Expand-Archive, top-level-folder swap into Interface\AddOns).

Goal: fold "GitHub release" in as a first-class addon source, dispatched
and installed through Furphy's EXISTING CurseForge/Wago machinery (staging,
backup, rollback, adopt-in-place, /api/state, the SPA's My Addons list,
drawer, Versions tab) rather than a bolted-on parallel path. A player who
never touches GitHub sees nothing new except one more card in Settings and
one more badge color. Eric specifically gets: paste a token once, add his
two repos by link, and Furphy checks/updates/rolls them back exactly like
a CurseForge or Wago addon.

Non-goals (deliberately out of scope for this round): browsing/searching
GitHub repos, a rich release-history/changelog tab for GitHub addons,
GitHub App/OAuth flows, org-wide token management, per-repo tokens, webhook
push notifications. The two guild repos are NOT pre-added by code - Eric
adds them and pastes his token himself (FIXED DECISION 5).

=====================================================================
2. Record schema and exact JSON
=====================================================================

2.1 New fields on an addon record (addons.json entry)

Every record already carries the generic fields New-AddonRecord defines
(addon-sync.ps1:2874-2909) and Initialize-AddonRecordFields backfills onto
older records (addon-sync.ps1:2936-3032). A GitHub-sourced record reuses
every generic field (name, folders, installedAt, ignoreUpdates,
pinnedFileId, releaseType, previousFileId, previousVersion,
previousFileName, requiredDeps, optionalDeps, latestGameVersions,
latestFileDate, adopted, adoptedAt) and adds exactly FOUR new ones (revised
after fold-in review - see 3.4a below for why a fourth field was added
alongside the three originally specced), mirroring how E12 added
wagoId/slug/curseId for Wago (addon-sync.ps1:2896-2900):

    source                = 'github'    (existing field, third accepted value)
    repo                  = 'owner/name' (new; e.g. "bart-dev-wow/AuraUpdater")
    installedTag          = <string|null> (new; the installed release's
                                            tag_name, or the literal string
                                            "unknown" - see 3.5/3.7)
    assetName             = <string|null> (new; the .zip asset's own "name"
                                            field that was actually installed,
                                            or the literal string "zipball"
                                            when the release had no usable
                                            .zip asset and the source zipball
                                            was used instead, or $null when
                                            adopted-in-place with nothing
                                            downloaded)
    githubRateLimitedUntil = <string|null> (new, added per review finding
                                            "D" below; an ISO-8601 UTC
                                            timestamp - see 3.4a - $null
                                            until this specific repo's check
                                            first gets a 403/429 that survives
                                            Invoke-GithubRequest's own bounded
                                            retry)

Deliberately NOT added: wagoId, slug, curseId stay $null/unset on a GitHub
record (they mean something else entirely); projectId stays $null (no
numeric CurseForge id); fileId stays $null FOREVER on a GitHub record -
installedTag is the version-identity field for this source (see 2.2), the
same way slug is Wago's identity field instead of projectId. author stays
$null (GitHub's release API gives no addon-author concept worth capturing;
out of scope, matches Wago's own author=$null precedent, addon-sync.ps1:
3749).

2.2 Why no fileId: installedTag does its job

CurseForge keys on numeric fileId; Wago keys on a release id string stored
in the SAME fileId field (E12 deliberately widened fileId to accept either
shape - addon-sync.ps1:3798-3801 casts it as [string], not [int64]).
GitHub tags are the natural, stable version identity (Eric's two real
addons: TimelineReminders.toc "## Version: v454", AuraUpdater.toc
"## Version: 164") - decision 1 makes installedTag, not fileId, the
comparison key ("check = compare latest tag_name against installedTag").
Rather than stuffing the tag into the ALREADY-overloaded fileId field a
third way, GitHub gets its own field and fileId is simply never set for
this source. Every place that keys backup/rollback zips on "FileId"
(Save-BackupZip, Install-AddonPackage, Get-RecordBackupKey - all already
untyped/stringified, see 3.6) is called with $Record.installedTag standing
in for what fileId means elsewhere. $Record.version is kept IDENTICAL to
$Record.installedTag on every write (both set together, never one without
the other) purely so every existing generic UI/CLI code path that already
reads ".version" for display (My Addons table, mock fixtures, Show-Table)
needs no source branch at all to show something sensible for a GitHub row.

2.3 New-GithubAddonRecord (addon-sync.ps1, new function next to
    New-WagoAddonRecord at addon-sync.ps1:2911-2934)

    function New-GithubAddonRecord {
        param(
            [Parameter(Mandatory = $true)][string]$Repo
        )
        $rec = New-AddonRecord -ProjectId 0
        $rec.projectId = $null
        $rec.source = 'github'
        $rec.repo = $Repo
        return $rec
    }

New-AddonRecord itself (addon-sync.ps1:2874-2909) gains the four new
properties in its literal, defaulted $null (repo, installedTag, assetName,
githubRateLimitedUntil), placed after curseId/latestGameVersions/
latestFileDate and before the adopted/adoptedAt pair - same "append new
fields at the end" discipline E12 already used there.

2.4 Initialize-AddonRecordFields (addon-sync.ps1:2936-3032) gains four
    Get-Member/Add-Member guarded backfills, same shape as every existing
    one there:

    if (-not (Get-Member -InputObject $Record -Name 'repo' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'repo' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'installedTag' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'installedTag' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'assetName' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'assetName' -NotePropertyValue $null
    }
    if (-not (Get-Member -InputObject $Record -Name 'githubRateLimitedUntil' -MemberType NoteProperty)) {
        Add-Member -InputObject $Record -NotePropertyName 'githubRateLimitedUntil' -NotePropertyValue $null
    }

(source already defaults to 'curseforge' via the existing check at
addon-sync.ps1:2991-2993 - untouched; a record with no source field
predates every third-party source and is correctly assumed CurseForge.)

2.5 Exact addons.json entry for an installed GitHub addon (illustrative,
    matching the shape New-AddonRecord/New-GithubAddonRecord produce):

    {
      "name": "TimelineReminders",
      "projectId": null,
      "fileId": null,
      "version": "v454",
      "fileName": null,
      "installedAt": "2026-09-09T18:04:00Z",
      "folders": ["TimelineReminders"],
      "author": null,
      "ignoreUpdates": false,
      "pinnedFileId": null,
      "releaseType": null,
      "previousFileId": null,
      "previousVersion": null,
      "previousFileName": null,
      "requiredDeps": [],
      "optionalDeps": [],
      "source": "github",
      "wagoId": null,
      "slug": null,
      "curseId": null,
      "latestGameVersions": [],
      "latestFileDate": "2026-09-01T00:00:00Z",
      "adopted": true,
      "adoptedAt": "2026-09-09T18:04:00Z",
      "repo": "bart-dev-wow/TimelineReminders",
      "installedTag": "v454",
      "assetName": null,
      "githubRateLimitedUntil": null
    }

(adopted/adoptedAt true here because this specific record was adopted in
place per 3.7 - a freshly downloaded GitHub add has adopted=false,
assetName set to whatever asset was actually installed, fileName still
null since GitHub assets are not tracked by fileName the way CurseForge
files are - fileName is a CurseForge-only concept New-AddonRecord already
leaves null for Wago too.)

2.6 Server-side generic clone (addon-server.ps1) already forwards these

Handle-State (addon-server.ps1:7097 on) builds each addon's response row
via a fully generic property clone - not a hand-picked field list:

    $clone = [ordered]@{}
    foreach ($p in $r.PSObject.Properties) {
        $clone[$p.Name] = $p.Value
    }
    (addon-server.ps1:7174-7177)

The CLI's own -Json "addons" output goes through the identical pattern in
Add-CompatFieldsToAddonClone (addon-sync.ps1:2794-2818, "same generic
PSObject.Properties copy pattern -Status already uses"). Net effect:
repo/installedTag/assetName/githubRateLimitedUntil reach GET /api/state and
the CLI's own -Json output FOR FREE the moment they exist on the record -
no new field-mapping code needed in either place (githubRateLimitedUntil
carries no secret and is harmless to expose this way - it is bookkeeping
about GitHub's own rate limiter, not the token itself; the SPA is not
specced to render it anywhere, it is read only by the CLI, see 3.4a). Only
two lookup helpers key OFF specific fields by name and need a GitHub branch
each - see 4.6.

=====================================================================
3. CLI (addon-sync.ps1)
=====================================================================

3.1 URL/token parsing - accepted forms

One shared classifier accepts a GitHub target everywhere a Wago target is
already accepted today (-Add, -Only, -Unpin, -Ignore, -Unignore,
-Rollback, and Remove-AddonByTarget's separate -Remove matcher) - extend
ConvertTo-TargetToken (addon-sync.ps1:4211-4245), which currently returns
{IsWago; ProjectId; WagoRef}, to a fourth branch and a widened shape
{IsWago; ProjectId; WagoRef; IsGithub; GithubRepo} (every existing branch
gets the two new fields explicitly set, matching how WagoRef=$null is
already explicit on the numeric-id branch):

    $ownerPattern = '[A-Za-z0-9][A-Za-z0-9-]{0,38}'   # 1-39 chars, GitHub username shape (close enough - not a full validator)
    $repoPattern  = '[A-Za-z0-9._-]{1,100}'            # GitHub repo-name shape

    # REVIEW FOLD-IN, finding A ("owner/.." and "owner/." pass every
    # validator unsanitized"): $repoPattern's character class allows '.'
    # and '-', so a repo segment made ENTIRELY of dots or hyphens (".",
    # "..", "---") matches it cleanly. $repoNameOnly (3.6.1/3.6.3/3.7) later
    # derives a bare filesystem path SEGMENT from this same string via
    # `-replace '^.*/', ''` and feeds it straight into Join-Path against
    # $AddonsPath/$StagingPath with no further check - Join-Path does not
    # resolve/collapse ".." itself, but every consumer that actually TOUCHES
    # the resulting path (Test-Path, Remove-Item, Move-Item) resolves it at
    # the OS level, so a repo of "x/.." makes that later Join-Path resolve
    # to the PARENT of $AddonsPath (verified empirically against this exact
    # Windows/PowerShell 5.1 build: Join-Path "...\AddOns" ".." + Test-Path/
    # Remove-Item -Recurse -Force resolves to and would delete the FOLDER
    # THAT CONTAINS AddOns, i.e. Interface itself). A repo of "x/." resolves
    # to $AddonsPath itself instead (deletes/replaces the whole AddOns
    # folder). Reject this at the SOURCE - the shared classifier - so no
    # downstream code (3.6.3, 3.7) ever has to reason about it:
    $repoTraversalPattern = '^\.+$'   # matches ".", "..", "...", etc. - an all-dots segment, the only shape in $repoPattern's own character class that can resolve outside its parent directory

    # bare owner/repo
    if ($Token -match "(?i)^($ownerPattern)/($repoPattern)$") {
        if ($Matches[2] -match $repoTraversalPattern) { throw "-$ParamName value '$Token' is not a valid GitHub repo (the repo name cannot be '.' or '..')" }
        return [PSCustomObject]@{ IsWago = $false; ProjectId = $null; WagoRef = $null; IsGithub = $true; GithubRepo = "$($Matches[1])/$($Matches[2])" }
    }
    # github:owner/repo
    if ($Token -match "(?i)^github:($ownerPattern)/($repoPattern)$") {
        if ($Matches[2] -match $repoTraversalPattern) { throw "-$ParamName value '$Token' is not a valid GitHub repo (the repo name cannot be '.' or '..')" }
        return [PSCustomObject]@{ IsWago = $false; ProjectId = $null; WagoRef = $null; IsGithub = $true; GithubRepo = "$($Matches[1])/$($Matches[2])" }
    }
    # github.com/owner/repo, with or without scheme/www, trailing slash, .git, or a subpath
    if ($Token -match "(?i)^(?:https?://)?(?:www\.)?github\.com/($ownerPattern)/($repoPattern)(?:\.git)?(?:[/?#].*)?$") {
        if ($Matches[2] -match $repoTraversalPattern) { throw "-$ParamName value '$Token' is not a valid GitHub repo (the repo name cannot be '.' or '..')" }
        return [PSCustomObject]@{ IsWago = $false; ProjectId = $null; WagoRef = $null; IsGithub = $true; GithubRepo = "$($Matches[1])/$($Matches[2])" }
    }

Placed AFTER the existing numeric-id check and BEFORE the final throw (so
a bare "owner/repo" is tried only once the token has already failed to
parse as an int64 project id - a repo name can never collide with a
decimal number, so ordering is safe either way, but this keeps the
existing wago: -> url -> throw fallthrough order intact and just appends
github: -> url -> bare-owner/repo as three more rungs before the same
final throw). The existing wago:/https://addons.wago.io branches gain
`IsGithub = $false; GithubRepo = $null` explicitly, same discipline.

The identical $repoTraversalPattern guard is REQUIRED in the two other
places that parse the same owner/repo text from a different trust boundary
- the server's Handle-JobsPost validation (4.5) and the SPA's
parseGithubRepoInput (5.3) - both already say "must match... exactly" for
the base regex; that sentence now also covers this guard. All three
existing tests for malformed input (7.1's
CLI.GithubUrlParse.Tests.ps1) gain "owner/.." and "owner/." as explicit
rejection cases alongside "-bad" and the 101-char repo name.

Test-RecordMatchesTarget (addon-sync.ps1:4271-4292) gains a matching
top branch:

    if ($Target.IsGithub) {
        if ($Record.source -ne 'github') { return $false }
        if (-not $Record.repo) { return $false }
        return ($Record.repo.ToLowerInvariant() -eq $Target.GithubRepo.ToLowerInvariant())
    }

Get-TargetLabel (addon-sync.ps1:4294-4300) gains:

    if ($Target.IsGithub) { return "github:$($Target.GithubRepo)" }

Get-RecordBackupKey (addon-sync.ps1:4302-4320) gains a branch BEFORE the
final `return [string][int]$Record.projectId`:

    if ($Record.source -eq 'github') {
        $safeRepo = ($Record.repo -replace '[^a-zA-Z0-9-]', '_')
        return "github-$safeRepo"
    }

(mirrors the wago-<slug> sanitization exactly; "bart-dev-wow/AuraUpdater"
becomes backup key "github-bart-dev-wow_AuraUpdater".)

Remove-AddonByTarget (addon-sync.ps1:4031-4118) gains a github matcher
alongside the existing wagoRef block (lines 4048-4053) and label branch
(line 4088):

    $githubRef = $null
    if ($Target -match '(?i)^github:(.+)$') {
        $githubRef = $Matches[1].Trim()
    } elseif ($Target -match "(?i)^(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100})") {
        $githubRef = $Matches[1]
    }
    ...
    if ($githubRef -and ($item.source -eq 'github') -and $item.repo -and ($item.repo.ToLowerInvariant() -eq $githubRef.ToLowerInvariant())) {
        $match = $item; break
    }
    ...
    $matchLabel = if ($match.source -eq 'wago') { "wago:$($match.slug)" } elseif ($match.source -eq 'github') { "github:$($match.repo)" } else { "project $($match.projectId)" }

3.2 Sync-SingleAddon dispatch

Sync-SingleAddon (addon-sync.ps1:3337-3382) gains a second dispatch branch
right after the existing Wago one (line 3380-3382):

    if ($Record.source -eq 'github') {
        return Sync-SingleGithubAddon -Record $Record -AddonsPath $AddonsPath -StagingPath $StagingPath -BackupsPath $BackupsPath -Force:$Force -DryRun:$DryRun -ExplicitTarget:$ExplicitTarget -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -Flavor $Flavor -InstalledInterface $InstalledInterface -GithubToken $GithubToken -ClaimedFolders $ClaimedFolders
    }

Sync-SingleAddon itself gains TWO new parameters: `$GithubToken = $null`
and `$ClaimedFolders = $null` (a [System.Collections.Generic.Dictionary
[string,string]], see 3.3a below), both threaded straight through (neither
consumed by the CurseForge body below it - CurseForge/Wago records never
auto-adopt a folder during a plain sync, see 3.3a's own note on why this
guard is GitHub-only for now). The main sync loop's single call site
(addon-sync.ps1:5338) gains `-GithubToken $settings.githubToken
-ClaimedFolders $claimedFolders` (see 3.9 for $settings.githubToken; see
3.3a for where $claimedFolders is built, ONCE, before the loop starts).
DefaultMaxReleaseType/FileIdOverride are accepted but IGNORED by the GitHub
path (GitHub has no release-type/alpha-beta concept and no per-file pin id
- a GitHub record's own -Ignore/-Unpin generic handling at the config-only
layer, section 3.1, is unaffected either way).

3.3 Sync-SingleGithubAddon (new function, placed after Sync-SingleWagoAddon,
    addon-sync.ps1 ~4029)

Signature (mirrors Sync-SingleWagoAddon's exactly, addon-sync.ps1:3755-3771,
minus DefaultMaxReleaseType/FileIdOverride which GitHub has no use for,
plus GithubToken):

    function Sync-SingleGithubAddon {
        param(
            [Parameter(Mandatory = $true)]$Record,
            [Parameter(Mandatory = $true)][string]$AddonsPath,
            [Parameter(Mandatory = $true)][string]$StagingPath,
            [Parameter(Mandatory = $true)][string]$BackupsPath,
            [switch]$Force,
            [switch]$DryRun,
            [switch]$ExplicitTarget,
            [int]$ProgressTotal = 0,
            [int]$ProgressIndex = 0,
            [string]$Flavor = 'retail',
            $InstalledInterface = $null,
            [string]$GithubToken = $null,
            # REVIEW FOLD-IN, finding C ("folder-ownership collision"): a
            # lowercased-folder-name -> owning-record-identity-string map
            # built ONCE per run over every OTHER record's .folders (see
            # 3.3a) - lets step 2 and step 8 below refuse to adopt/install
            # over a folder a DIFFERENT tracked addon already owns, the
            # same protection -Adopt's own $ownedFoldersForAdopt gives the
            # general adopt flow (addon-sync.ps1 ~5013-5018/5049-5050).
            $ClaimedFolders = $null
        )
        ...
    }

Body outline (each numbered step below is one contiguous block, matching
Sync-SingleWagoAddon's own try/catch/$currentPhase shape,
addon-sync.ps1:3782-4028):

  1. ignoreUpdates short-circuit - identical to the Wago path (line
     3783-3786), label "github:$($Record.repo)".
  2. Adopt-in-place fast path (see 3.7) - runs ONLY when
     $Record.installedTag is still $null (never checked/installed by
     Furphy yet) AND a folder named exactly $Record.repo's own repo-name
     segment already exists on disk under $AddonsPath AND (REVIEW FOLD-IN,
     finding C) that folder name is NOT already present as a key in
     $ClaimedFolders under a DIFFERENT owning identity than
     "github:$($Record.repo)" - see 3.3a/3.7 for the exact check and what
     happens on a collision (never silently adopts OR silently installs
     over another record's folder). On a clean hit, returns
     'Adopted'/'Up-to-date' with NO network call at all and skips straight
     to end of function.
  3. Release lookup: GET $script:GitHubBaseUrl + "/repos/$($Record.repo)/releases/latest"
     via Invoke-GithubRequest (3.4/3.6). $currentPhase = 'checking' before
     the call, 'checking-needs-token' or 'checking-network-github' set
     right before returning Failed on the specific failure branches (3.5).
     REVIEW FOLD-IN, finding D (persisted rate-limit backoff): BEFORE this
     call, if $Record.githubRateLimitedUntil is set and still in the
     future, skip the network call entirely - see 3.4a.
  4. Asset selection (3.6) against the parsed release JSON.
  5. installedTag string-compare: if $Record.installedTag -and
     (-not $Force) -and ($Record.installedTag -eq $selectedTag) -> return
     'Up-to-date' (no download). This is a plain -eq, never
     Get-NormalizedVersionString's loose compare - GitHub tags are exact,
     stable identifiers by construction (decision 1: "compare latest
     tag_name against installedTag").
  6. DryRun -> 'Would-update' with Version=$selectedTag, same contract as
     the CF/Wago paths (never mutates $Record). $currentPhase = 'checking'
     still (unchanged from step 3/4 - DryRun never reaches downloading/
     installing, matching every other source's own DryRun contract).
  7. $currentPhase = 'downloading' (matching UX-SPEC.md's existing
     checking/downloading/installing bucket set - a failure from here
     through the end of step 8 must land on 'downloading' or 'installing',
     never stay stamped 'checking', so failureReason() never shows the
     misleading "No matching version found" bucket for what is actually a
     failed download or corrupt zip - REVIEW FOLD-IN, finding G/8). Download
     the chosen asset or zipball to $StagingPath via Invoke-GithubRequest
     -OutFile (3.4), then normalize a zipball into an
     Install-AddonPackage-ready zip when needed (3.6.3).
  8. $currentPhase = 'installing' (see step 7's own note - set BEFORE the
     Install-AddonPackage call below, since that call can throw).
     REVIEW FOLD-IN, finding C: before calling Install-AddonPackage, check
     every folder name the chosen zip's own top level actually contains
     (for the .zip-asset path, whatever the real zip's top-level entries
     are; for the zipball path, the normalized zip's - see 3.6.3) against
     $ClaimedFolders, excluding this record's OWN currently-tracked
     folders (an update re-claiming its own existing folder is not a
     collision). Any match owned by a DIFFERENT record -> same refusal as
     step 2's collision case (3.3a) - Install-AddonPackage is never called
     at all, so no other addon's on-disk folder is ever touched.
     $backupKey = Get-RecordBackupKey -Record $Record (3.1's new branch).
     Save-PreAdoptBackupZip when $isNewInstall -and $Record.adopted (same
     call shape as the Wago path, addon-sync.ps1:3953-3955).
     $newFolders = Install-AddonPackage -ZipPath $normalizedZipPath -ProjectId $backupKey -StagingPath $StagingPath -AddonsPath $AddonsPath -PreviousFolders $Record.folders
     (Install-AddonPackage itself, addon-sync.ps1:1203-1351, is UNCHANGED -
     see 3.6.3 for why the zipball case never needs it to change.)
  9. On $newFolders.Count -eq 0: same 'Failed' shape as CF/Wago
     (addon-sync.ps1:3958-3962 mirror), $currentPhase stays 'installing'
     (set in step 8 above).
  10. name = Get-TocTitle (addon-sync.ps1:1531-1592) over $newFolders, else
      the repo's own name segment (never the full "owner/repo").
  11. previousFileId/previousVersion/previousFileName bookkeeping - for
      GitHub, previousFileId is set to the OLD $Record.installedTag (a
      string, exactly like Wago already stores a non-numeric release id in
      this generically-typed field), previousVersion to the old
      $Record.version, previousFileName stays $null (GitHub tracks no
      fileName).
  12. $Record.name/.version/.installedTag/.folders/.assetName/.installedAt
      set. $Record.fileId is NEVER touched (stays whatever it already was
      - $null on every real GitHub record, see 2.2). A successful release
      lookup this far also means GitHub is not currently rate-limiting this
      repo's token, so $Record.githubRateLimitedUntil is reset to $null
      here too (REVIEW FOLD-IN, finding D/3.4a) - it is only ever SET on
      the specific 403/429-after-retries catch path in step 3/3.5, never
      left stale once a check has actually gone through.
  13. latestGameVersions = @() (GitHub gives no game-version metadata -
      Get-AddonCompat, addon-server.ps1:2213, already treats an empty list
      as "unknown" without any GitHub-specific change there);
      latestFileDate = the release's own published_at string, straight
      from the GitHub JSON (informational parity with CF's dateCreated/
      Wago's created_at - costs nothing extra, already fetched).
  14. requiredDeps/optionalDeps: same Get-PackageDependencies call as every
      other source (addon-sync.ps1's existing helper - unchanged).
  15. Save-BackupZip -ZipPath $normalizedZipPath -ProjectId $backupKey -FileId $selectedTag -BackupsRoot $BackupsPath -PreviousFileId $Record.previousFileId
      ($FileId here is $selectedTag, a string - Save-BackupZip's -FileId
      param, addon-sync.ps1:1830, is already untyped for exactly this
      reason; the resulting backup path is
      backups\github-<owner>_<repo>\<tag>.zip).
  16. Return 'Installed'/'Updated', same shape as every other source.
  17. catch block: Write-Log ERROR "Failed processing github:$($Record.repo) ($displayLabel) : $($_.Exception.Message)" (redacted per 6.2), return
      'Failed' with $currentPhase as FailPhase - identical shape to
      Sync-SingleWagoAddon's own catch (addon-sync.ps1:4025-4028).

3.3a Folder-ownership collision guard (added in review - finding C)

Round 45's general -Adopt verb never lets a folder already claimed by
ANOTHER tracked record get silently re-adopted: it builds
$ownedFoldersForAdopt from every existing record's own .folders array
(addon-sync.ps1 ~5013-5018) and returns 'Skipped'/'already tracked'
(~5049-5050) for any candidate that collides. Sync-SingleGithubAddon's
step 2 (adopt-in-place, 3.7) and step 8 (a fresh install/update whose zip's
own top-level folder names happen to collide with another record - e.g.
two different repos that both unpack to a folder named "Bagnon", the
existing mock fixture's own CurseForge-tracked folder, ui\app.js:415) had
NO equivalent check as first specced - a silent takeover, with whichever
record syncs next calling Install-AddonPackage's unconditional
Remove-Item -Recurse -Force on the other's folder. Fixed as follows:

  - $claimedFolders (a case-insensitive [System.Collections.Generic.
    Dictionary[string,string]], StringComparer.OrdinalIgnoreCase) is built
    ONCE by the main sync loop, BEFORE it starts iterating $config, not
    per-addon: for every record in $config, for every folder name in
    $record.folders, set $claimedFolders[$folderName] = <that record's own
    identity string> ("github:$($record.repo)" / "wago:$($record.slug)" /
    "$($record.projectId)", i.e. exactly what Get-TargetLabel already
    produces for that record's own source). Rebuilding this once per run
    (not once per addon) keeps the O(addons x folders) cost the same
    "-Adopt already pays this way every time it runs" order of magnitude -
    negligible for Eric's handful of addons and unnoticeable at any
    realistic addon count.
  - Threaded into Sync-SingleAddon/Sync-SingleGithubAddon as $ClaimedFolders
    per 3.2/3.3's own new parameter.
  - Step 2 (3.7): before adopting, check
    $ClaimedFolders.TryGetValue($repoNameOnly, [ref]$owner); if it returns
    true AND $owner -ne "github:$($Record.repo)" (i.e. claimed, and not by
    this same record - a re-run over an already-adopted record must still
    succeed), do NOT adopt. Instead: Write-Log ERROR
    "GitHub addon $($Record.repo) ($displayLabel): folder '$repoNameOnly'
    is already tracked by $owner - rename or remove that addon in Furphy
    first." and return [PSCustomObject]@{ Status = 'Failed'; Name =
    $displayLabel; Version = $Record.version; FailPhase = 'checking' } -
    this record is left exactly as it was ($Record.installedTag still
    $null), so the SAME collision message repeats on every future check
    until Eric resolves it by hand (matching -Adopt's own "the player, not
    Furphy, decides who really owns a contested folder" precedent) rather
    than either silently taking over the folder or silently giving up on
    tracking this repo forever.
  - Step 8: the equivalent check runs against whatever folder names the
    chosen zip's own top level actually contains (not just $repoNameOnly -
    a .zip-asset install can unpack to any folder name(s) at all, per
    3.6.1/3.6.4), EXCLUDING names already in $Record.folders itself (this
    record updating its own previously-installed folder is never a
    collision). Any remaining match against $ClaimedFolders owned by a
    DIFFERENT identity aborts BEFORE Install-AddonPackage is called at all
    - same log line shape as step 2's, substituting the actual colliding
    folder name - so a first-time GitHub install can never silently stomp
    a CurseForge/Wago/other-GitHub addon's files, and an update to an
    ALREADY-tracked GitHub record can never silently annex a folder some
    other record grew to own in between checks.
  - This guard is GitHub-specific for now (only Sync-SingleGithubAddon
    consults $ClaimedFolders) because GitHub is the only source with an
    automatic "adopt if the folder already exists" step inside a plain
    sync (3.7) - CurseForge/Wago records only ever adopt via the explicit,
    already-guarded -Adopt verb. If a future round adds an equivalent
    auto-adopt fast path to another source, it should consult the same
    $claimedFolders map rather than reinventing this.

3.4 Invoke-GithubRequest (new function, placed after Invoke-WagoRequest,
    addon-sync.ps1 ~995)

Mirrors Invoke-CfRequest (addon-sync.ps1:644-711) almost exactly - same
300ms pace, same retry-once-after-a-wait shape - but retries on 403 OR 429
(GitHub's two "back off" codes, matching addon-server.ps1's own
Invoke-AppUpdateMaintenanceCore precedent at addon-server.ps1:9586) and
honors a Retry-After header when present, capped at 10 seconds (this runs
synchronously inside a user-facing sync job covering possibly many addons
- unlike the App-Update maintenance path's own hours-long persistent
backoff, addon-server.ps1:9586-9618, a per-addon check inside a live sync
must never block the whole run for anywhere near that long; 10s is a
firm, generous-enough single retry window, floored at 5s when the header
is absent or unparsable, matching Invoke-CfRequest's own fixed 5s wait):

    $script:GithubUserAgent = 'FurphyAddonManager-AddonSync'
    # FURPHY_TEST_GITHUB_BASEURL - same env var addon-server.ps1 already
    # reads (addon-server.ps1:136-141) for the self-updater's own GitHub
    # lookup - one seam configures both processes in a test.
    # REVIEW FOLD-IN, finding I/11 (naming nit): spelled $script:GitHubBaseUrl
    # (capital Hub), matching the existing server-side seam's own casing
    # (addon-server.ps1:138/140, $Script:GitHubBaseUrl) exactly - the two
    # variables live in separate script-scoped processes so there was never
    # a functional collision either way, but a consistent spelling is one
    # less thing to trip up anyone grepping both files together.
    $script:GitHubBaseUrl = 'https://api.github.com'
    if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_GITHUB_BASEURL)) {
        $script:GitHubBaseUrl = $env:FURPHY_TEST_GITHUB_BASEURL.TrimEnd('/')
    }

    function Invoke-GithubRequest {
        param(
            [Parameter(Mandatory = $true)][string]$Uri,
            [string]$Accept = 'application/vnd.github+json',
            [string]$GithubToken = $null,
            [string]$OutFile,
            [int]$ProgressTotal = 0,
            [int]$ProgressIndex = 0,
            $ProgressAddon = $null
        )
        $headers = @{ 'Accept' = $Accept }
        if (-not [string]::IsNullOrWhiteSpace($GithubToken)) {
            $headers['Authorization'] = 'Bearer ' + $GithubToken
        }
        $maxAttempts = 2
        $attempt = 0
        $lastError = $null
        $result = $null
        while ($attempt -lt $maxAttempts) {
            $attempt++
            $shouldRetry = $false
            $lastError = $null
            $waitSeconds = 5
            try {
                if ($OutFile) {
                    Invoke-HttpDownloadWithProgress -Uri $Uri -Headers $headers -UserAgent $script:GithubUserAgent -OutFile $OutFile -TimeoutSec 60 -ProgressTotal $ProgressTotal -ProgressIndex $ProgressIndex -ProgressAddon $ProgressAddon
                    $result = $null
                } else {
                    $result = Invoke-WebRequest -Uri $Uri -Headers $headers -UserAgent $script:GithubUserAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                }
            } catch {
                $lastError = $_
                $statusCode = Get-ExceptionStatusCode -ErrorRecord $_
                if ($statusCode -eq 404) {
                    # 404 is never retried - see 3.5, it means "no access
                    # right now", not "transient".
                }
                elseif (($statusCode -eq 403 -or $statusCode -eq 429) -and ($attempt -lt $maxAttempts)) {
                    try {
                        $retryAfterHeader = $_.Exception.Response.Headers['Retry-After']
                        if ($retryAfterHeader) {
                            $ras = 0
                            if ([int]::TryParse([string]$retryAfterHeader, [ref]$ras) -and $ras -gt 0) { $waitSeconds = [Math]::Min($ras, 10) }
                        }
                    } catch { }
                    Write-Log -Level 'WARN' -Message "HTTP $statusCode from GitHub - waiting $waitSeconds seconds and retrying"
                    $shouldRetry = $true
                }
            }
            Start-Sleep -Milliseconds 300
            if (-not $lastError) { return $result }
            if (-not $shouldRetry) { throw $lastError }
            Start-Sleep -Seconds $waitSeconds
        }
        if ($lastError) { throw $lastError }
        return $result
    }

(Get-ExceptionStatusCode and Invoke-HttpDownloadWithProgress are the same
existing shared helpers Invoke-CfRequest already uses - no changes needed
to either.)

3.4a Cross-run rate-limit backoff (added in review - finding D)

Invoke-GithubRequest's own bounded retry (3.4) is a same-call safety net
for one transient 403/429 - it was never meant to be the ONLY defense, the
same way Invoke-AppUpdateMaintenanceCore's own in-call handling
(addon-server.ps1:9582-9612) is backed by a PERSISTED $state.rateLimitedUntil
that makes the NEXT tick (hours later) skip the lookup entirely rather than
re-hammering. The GitHub source's token is explicitly shared across an
entire guild's separate Furphy installations (task brief) - each running
its own background-check interval PLUS manual "Check for updates" clicks -
so a real secondary-rate-limit hit is not a one-shot event without this:

  - Sync-SingleGithubAddon step 3 (3.3), BEFORE calling Invoke-GithubRequest
    for the release lookup: if $Record.githubRateLimitedUntil is set and
    (Get-Date).ToUniversalTime() is still before it, skip the network call
    entirely - Write-Log INFO "GitHub addon $($Record.repo) ($displayLabel):
    still rate-limited until $($Record.githubRateLimitedUntil), skipping
    this check" and return [PSCustomObject]@{ Status = 'Failed'; Name =
    $displayLabel; Version = $Record.version; FailPhase =
    'checking-network-github' } - reuses the EXISTING bucket text from
    3.6.5 ("Couldn't check for updates - GitHub might be having trouble"),
    no new UI-visible string needed.
  - When Invoke-GithubRequest's own bounded retry (3.4) is exhausted and
    the final attempt still throws a 403/429 (i.e. the `throw $lastError`
    at the end of its while loop is reached with a 403/429 $lastError),
    Sync-SingleGithubAddon's own catch around the release lookup (3.5)
    computes a backoff exactly like Invoke-AppUpdateMaintenanceCore already
    does (addon-server.ps1:9586-9603: Retry-After preferred, else
    X-RateLimit-Reset, capped at 6 hours, floored at 60 seconds - same
    numbers, same reasoning, reused verbatim rather than inventing new
    ones) and sets $Record.githubRateLimitedUntil = that UTC timestamp
    (ISO-8601, 'yyyy-MM-ddTHH:mm:ssZ') before returning 'Failed' with
    FailPhase 'checking-network-github'.
  - Cleared (set back to $null) on the next release lookup that actually
    succeeds - step 12's own new note above.
  - Deliberately PER-RECORD, not a single shared value keyed on the token
    itself: GitHub's real rate limit is per-token, so in principle one
    repo hitting it means every repo sharing that token is ALSO limited.
    A single shared value would need a new file or a settings.json field
    (githubToken already lives there, but settings.json is a config file
    Handle-SettingsPut round-trips on every PUT, not a natural home for a
    frequently-rewritten runtime fact) - out of proportion for Eric's two
    real repos. Storing it per-record instead means each repo's own next
    check independently discovers and backs off from the SAME limit at
    worst one extra request later than a perfectly shared value would -
    acceptable given addons.json is already the natural, existing,
    per-record persistence layer every other new field in this round uses
    (2.1), and this keeps the fix entirely inside the "append one more
    field, same discipline as the other three" shape the rest of section 2
    already establishes, rather than introducing a new file/format.

3.5 Release lookup - headers, auth, 404-with-token vs without,
    rate-limit backoff, redirects

    $releaseUri = "$script:GitHubBaseUrl/repos/$($Record.repo)/releases/latest"
    try {
        $resp = Invoke-GithubRequest -Uri $releaseUri -Accept 'application/vnd.github+json' -GithubToken $GithubToken
        $release = $resp.Content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $statusCode = Get-ExceptionStatusCode -ErrorRecord $_
        if ($statusCode -eq 404) {
            # GitHub returns 404 (never 403) for a private repo whether the
            # request carried no token, an EXPIRED/rotated token, or a
            # token with no access - and for a genuinely nonexistent repo.
            # Furphy cannot tell these apart from the response alone, so
            # every 404 gets the SAME actionable message pointing at the
            # one thing the player can actually go fix.
            $currentPhase = 'checking-needs-token'
            Write-Log -Level 'ERROR' -Message "GitHub addon $($Record.repo) ($displayLabel): GitHub returned 404 for the release lookup (no access with the token currently in Settings, or none is set). Paste a current token in Settings > GitHub addons."
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
        }
        # REVIEW FOLD-IN, finding D/3.4a: Invoke-GithubRequest's own bounded
        # retry already tried once; if it still threw a 403/429 this far,
        # persist the backoff onto the record so the NEXT tick skips the
        # lookup instead of re-hammering a currently-limited shared token.
        if ($statusCode -eq 403 -or $statusCode -eq 429) {
            $Record.githubRateLimitedUntil = Get-GithubRateLimitBackoffUntil -ErrorRecord $_ -NowUtc (Get-Date).ToUniversalTime()
            $currentPhase = 'checking-network-github'
            Write-Log -Level 'WARN' -Message "GitHub addon $($Record.repo) ($displayLabel): rate-limited (HTTP $statusCode), backing off until $($Record.githubRateLimitedUntil)"
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
        }
        $currentPhase = 'checking-network-github'
        Write-Log -Level 'ERROR' -Message "GitHub addon $($Record.repo) ($displayLabel): release lookup failed: $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = $currentPhase }
    }

(Get-GithubRateLimitBackoffUntil is a small new helper factoring out the
exact Retry-After/X-RateLimit-Reset/6-hour-cap/60-second-floor arithmetic
3.4a describes, so it can also be unit-tested directly against hand-built
header values the same way CLI.GithubAssetSelect.Tests.ps1 already tests
other pure-function pieces of this design - see 7.1.)

Redirects for asset/zipball downloads (REVISED in review - finding B/2;
the original text here was factually wrong about both the mechanism and
one of the two hosts involved, corrected below after reading
Invoke-HttpDownloadWithProgress, addon-sync.ps1:532-642, and verifying the
actual behavior empirically against this exact build's PowerShell 5.1
runtime): asset-by-id and zipball downloads BOTH go through
Invoke-GithubRequest's -OutFile branch (3.4), which calls
Invoke-HttpDownloadWithProgress - NOT Invoke-WebRequest. That helper uses
[System.Net.HttpWebRequest] with AllowAutoRedirect=$true and adds
Authorization via the generic Headers.Add path (addon-sync.ps1:586-593).
Empirically verified (two local HttpListeners, one 302-redirecting to the
other on a different port so the redirect is genuinely cross-origin, a
custom Authorization header added via .Headers.Add on the initial request):
HttpWebRequest's default AllowAutoRedirect behavior does NOT resend a
Headers.Add-added Authorization header to a cross-host redirect target -
the request to the SECOND host arrives with no Authorization header at
all, even though the client transparently follows the redirect and reads
the body successfully. This is NOT a bug in this design to work around; it
is why the flow works at all without any extra code: GitHub's own
asset-by-id/zipball-url endpoints respond to an authenticated request with
a 302 to a PRE-SIGNED, time-limited URL (the signature IS the auth for that
one request - no Authorization header is required or expected there), and
.NET's own redirect handling already declines to leak the Bearer token to
that second host, whichever one it is. Two hosts can legitimately appear
as that redirect target depending on which asset path fired: asset-by-id
downloads (3.6.1, the expected case for Eric's two real addons) redirect to
objects.githubusercontent.com; the zipball_url fallback (3.6.2) redirects
to codeload.github.com instead - a DIFFERENT host the original text never
named at all. Both are corrected into 6.1's threat model below. Net effect:
no runtime host-allowlist check is needed around the download call (there
is nothing for one to catch - the token is never sent to either host in
the first place, verified above, not merely trusted not to be), but the
non-leakage claim is exactly the kind of thing that must be PROVEN by a
test rather than asserted by a doc comment - 7.2/7.3 gain a specific
assertion for it (see there).

3.6 Asset selection rule, zipball handling, exact error strings

3.6.1 Selection order, given the parsed $release JSON's .assets[] array:

    $zipAssets = @($release.assets | Where-Object { $_.name -match '(?i)\.zip$' })
    $repoNameOnly = $Record.repo -replace '^.*/', ''
    $chosenAsset = $null
    if ($zipAssets.Count -gt 0) {
        $nameMatch = $zipAssets | Where-Object { $_.name -match [regex]::Escape($repoNameOnly) } | Select-Object -First 1
        if ($nameMatch) { $chosenAsset = $nameMatch } else { $chosenAsset = $zipAssets[0] }
    }

(REVIEW FOLD-IN, finding F/7: with 2+ zip assets all matching the repo-name
substring test, `Select-Object -First 1` after `Where-Object` is
deterministic, not random - it takes the first match in $release.assets'
own order, which GitHub returns in a stable, consistent order (creation
order on the release). Not a security issue either way, and irrelevant for
Eric's two real repos, which each ship exactly one .zip asset - noted here
only so a future reader does not mistake "first match" for "arbitrary
match".)

If $chosenAsset is set: download it via its OWN "url" field (the API asset
endpoint, e.g. https://api.github.com/repos/<owner>/<repo>/releases/assets/<id> -
NEVER browser_download_url, which does not accept a Bearer token for a
private repo) with Accept 'application/octet-stream' - this is the exact
header/field pair Eric's existing one-off script already uses (task
brief), kept byte-identical here so behavior for his two real addons does
not change at all:

    $assetName = $chosenAsset.name
    Invoke-GithubRequest -Uri $chosenAsset.url -Accept 'application/octet-stream' -GithubToken $GithubToken -OutFile $rawZipPath

3.6.2 No .zip asset at all: fall back to the release's own zipball_url
(present on every GitHub release unconditionally):

    if (-not $chosenAsset) {
        if (-not $release.zipball_url) {
            $currentPhase = 'checking'
            Write-Log -Level 'ERROR' -Message "GitHub addon $($Record.repo) ($displayLabel): release $($release.tag_name) has no .zip asset and no zipball URL."
            return [PSCustomObject]@{ Status = 'Skipped'; Name = $displayLabel; Version = $Record.version }
        }
        $assetName = 'zipball'
        Invoke-GithubRequest -Uri $release.zipball_url -Accept 'application/vnd.github+json' -GithubToken $GithubToken -OutFile $rawZipPath
    }

3.6.3 Zipball normalization (only when $assetName -eq 'zipball')

A GitHub zipball's ONE top-level entry is always a single directory named
"<owner>-<repo>-<short-sha>" (e.g. "bart-dev-wow-TimelineReminders-a1b2c3d").
Install-AddonPackage (addon-sync.ps1:1203-1351) expects the zip's OWN
top-level entries to already be the addon folders themselves (each
containing a .toc) - feeding it a raw zipball would make it see exactly
ONE top-level folder named after a commit sha, with no .toc directly
inside it (the .toc is one level deeper), so it would find zero valid
addon folders and throw. Rather than touch Install-AddonPackage (a
heavily-relied-on, already-well-tested function every other source also
depends on), a new helper REWRITES the zipball into an
Install-AddonPackage-ready zip BEFORE calling it - Install-AddonPackage
itself needs ZERO changes for GitHub:

    function ConvertTo-NormalizedGithubZip {
        <#
          Given a raw GitHub zipball zip (one top-level "owner-repo-sha"
          directory) and the record's own repo name, produces a NEW zip in
          $StagingPath whose top-level entries are exactly what
          Install-AddonPackage expects: one folder per .toc-bearing
          subdirectory of the wrapper, OR - when the wrapper's OWN root
          holds a .toc directly, with no subdirectory at all - a single
          folder renamed to the repo name wrapping everything (decision 1:
          "if the archive root itself holds a .toc, the folder is named
          after the repo").
        #>
        param(
            [Parameter(Mandatory = $true)][string]$RawZipPath,
            [Parameter(Mandatory = $true)][string]$RepoName,
            [Parameter(Mandatory = $true)][string]$StagingPath
        )
        # REVIEW FOLD-IN, finding A/1, defense-in-depth: $RepoName is
        # re-derived from $Record.repo at the call site via the same
        # `-replace '^.*/', ''` 3.7 also uses, so this guard catches a
        # future caller that ever builds $Record.repo through a path other
        # than today's three validated entry points (3.1/4.5/5.3), not just
        # a hypothetical hole in those. Verified empirically (this exact
        # PowerShell 5.1 build): Join-Path does NOT resolve ".."/"." itself,
        # but Move-Item's DESTINATION resolution does, at the OS level, the
        # moment the call actually runs - a $RepoName of ".." here silently
        # relocates the wrapper directory to $StagingPath's own PARENT
        # (moving it out from under this function's cleanup entirely - a
        # leaked directory, not a deleted one, since $rebuiltDir has no
        # dependency on $AddonsPath at this point in the flow) rather than
        # renaming it in place; a $RepoName of "." collapses onto
        # $rebuiltDir itself. Neither is safe to let through unexamined -
        # reject before any filesystem operation below ever runs:
        if ([string]::IsNullOrWhiteSpace($RepoName) -or ($RepoName -match '^\.+$') -or ($RepoName -match '[\\/]')) {
            throw "Refusing to build a zip using an unsafe repo-derived folder name ('$RepoName')"
        }
        $scratchDir = Join-Path -Path $StagingPath -ChildPath ("_ghzip_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($RawZipPath, $scratchDir)
            $topEntries = @(Get-ChildItem -LiteralPath $scratchDir -Force)
            if ($topEntries.Count -ne 1 -or -not $topEntries[0].PSIsContainer) {
                throw "Unexpected zipball shape (expected exactly one top-level directory)"
            }
            $wrapperPath = $topEntries[0].FullName
            $wrapperHasOwnToc = @(Get-ChildItem -LiteralPath $wrapperPath -Filter '*.toc' -File -ErrorAction SilentlyContinue).Count -gt 0

            $rebuiltDir = Join-Path -Path $StagingPath -ChildPath ("_ghrebuild_" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $rebuiltDir -Force | Out-Null
            if ($wrapperHasOwnToc) {
                Move-Item -LiteralPath $wrapperPath -Destination (Join-Path -Path $rebuiltDir -ChildPath $RepoName)
            } else {
                foreach ($child in (Get-ChildItem -LiteralPath $wrapperPath -Force)) {
                    Move-Item -LiteralPath $child.FullName -Destination (Join-Path -Path $rebuiltDir -ChildPath $child.Name)
                }
            }
            $normalizedZipPath = Join-Path -Path $StagingPath -ChildPath ("_ghnorm_" + [Guid]::NewGuid().ToString('N') + ".zip")
            [System.IO.Compression.ZipFile]::CreateFromDirectory($rebuiltDir, $normalizedZipPath)
            return $normalizedZipPath
        } finally {
            Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $rebuiltDir) { Remove-Item -LiteralPath $rebuiltDir -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $RawZipPath -Force -ErrorAction SilentlyContinue
        }
    }

Sync-SingleGithubAddon calls this ONLY when $assetName -eq 'zipball', then
passes the returned $normalizedZipPath to Install-AddonPackage exactly
like any other source's zip. When $chosenAsset was used instead (the
normal, expected case for Eric's two addons, whose releases already ship a
proper .zip), $normalizedZipPath is just $rawZipPath unchanged - no
rewrite step runs at all.

3.6.4 Folder discovery: entirely Install-AddonPackage's own existing logic
(addon-sync.ps1:1258-1275) - "a top-level entry is a candidate folder iff
it is a directory containing at least one .toc file" - completely
unchanged, reused as-is by construction of 3.6.3 above.

3.6.5 The complete, exact error strings this section introduces (every one
      ASCII, no jargon, no ids):

    "This addon needs a GitHub token - paste it in Settings > GitHub addons."
        - the UI-visible bucket text (ui\app.js, section 5.6) for FailPhase
          'checking-needs-token'. VERBATIM per the fixed decision. Covers
          BOTH "no token configured" and "token configured but GitHub
          still 404s" - see 3.5's own comment for why these are not
          distinguished.
    "Couldn't check for updates - GitHub might be having trouble"
        - the UI-visible bucket text for FailPhase 'checking-network-github'
          (mirrors the existing CurseForge-specific line at ui\app.js:4430
          exactly, source-specific the same way that one already is).

Every OTHER message in this section (3.5, 3.6.2, 3.7's own log lines) is
sync.log-only (Write-Log), never surfaced verbatim to the UI - same
precedent as the existing "Unrecognized Classic client version..." message
(addon-sync.ps1:3411), which is also log-only while the UI shows a fixed
bucket ("No matching version found").

3.7 Adopt-in-place when folders already exist (Round 45 semantics)

Runs inside Sync-SingleGithubAddon, step 2 (3.3), BEFORE any network call,
ONLY when $Record.installedTag is $null (this record has never been
checked/installed by Furphy) and is not gated by -Force/-DryRun the way a
real sync is - it always fires first for a never-touched GitHub record.
REVISED in review to add two guards the original version lacked (finding
A/1's traversal check and finding C/3.3a's folder-ownership check - both
run BEFORE Test-Path ever touches disk, and BEFORE any adoption happens):

    $repoNameOnly = $Record.repo -replace '^.*/', ''
    # REVIEW FOLD-IN, finding A/1: reject a repo whose last segment is
    # empty, all-dots, or contains a path separator BEFORE it is ever used
    # to build a filesystem path. Verified empirically (this exact
    # PowerShell 5.1 build): Join-Path itself does not resolve ".."/"." in
    # its ChildPath, but the very next line's Test-Path DOES resolve it at
    # the OS level - a repo of "x/.." makes $candidatePath's Test-Path (and
    # every other consumer of that same path string) resolve to the PARENT
    # of $AddonsPath (i.e. Interface itself); "x/." collapses onto
    # $AddonsPath. Neither is reachable today ONLY because 3.1/4.5/5.3
    # already reject this shape at the input layer - this is the
    # belt-and-suspenders check at the one place that would otherwise do
    # something dangerous with it if that ever changed.
    if ([string]::IsNullOrWhiteSpace($repoNameOnly) -or ($repoNameOnly -match '^\.+$') -or ($repoNameOnly -match '[\\/]')) {
        Write-Log -Level 'ERROR' -Message "GitHub addon $($Record.repo) ($displayLabel): repo name is not a safe folder name, refusing to adopt or install"
        return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = 'checking' }
    }
    $candidatePath = Join-Path -Path $AddonsPath -ChildPath $repoNameOnly
    if ((-not $Record.installedTag) -and (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        # REVIEW FOLD-IN, finding C/3.3a: a folder that already exists on
        # disk under the repo's own name might already be CLAIMED by a
        # different tracked record (a coincidentally-matching CurseForge/
        # Wago/other-GitHub addon folder name) - Round 45's own -Adopt verb
        # never lets this happen silently (its $ownedFoldersForAdopt guard,
        # addon-sync.ps1 ~5013-5050), and this automatic fast path must not
        # either. $ClaimedFolders is the map built once per run in 3.3a.
        $ownerOfCandidate = $null
        $isClaimedByOther = $ClaimedFolders -and $ClaimedFolders.TryGetValue($repoNameOnly, [ref]$ownerOfCandidate) -and ($ownerOfCandidate -ne "github:$($Record.repo)")
        if ($isClaimedByOther) {
            Write-Log -Level 'ERROR' -Message "GitHub addon $($Record.repo) ($displayLabel): folder '$repoNameOnly' is already tracked by $ownerOfCandidate - rename or remove that addon in Furphy first."
            return [PSCustomObject]@{ Status = 'Failed'; Name = $displayLabel; Version = $Record.version; FailPhase = 'checking' }
        }
        $tocInfo = Get-FolderTocInfo -FolderPath $candidatePath -Flavor $Flavor -InstalledInterface $InstalledInterface
        if ($tocInfo.hasToc) {
            $rawVersion = $tocInfo.version
            $looksLikeTag = ($rawVersion -and ($rawVersion.Trim() -match '^[vV]?[0-9][\w.\-]*$'))
            $tagValue = if ($looksLikeTag) { $rawVersion.Trim() } else { 'unknown' }
            if (-not $DryRun) {
                $Record.folders = @($repoNameOnly)
                $Record.installedTag = $tagValue
                $Record.version = $tagValue
                $Record.name = $(if ($tocInfo.title) { $tocInfo.title } else { $repoNameOnly })
                $Record.adopted = $true
                $Record.adoptedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            Write-Log -Level 'INFO' -Message "Adopted github:$($Record.repo) ($($Record.name)) folder: $repoNameOnly, installedTag=$tagValue"
            return [PSCustomObject]@{ Status = 'Adopted'; Name = $Record.name; Version = $tagValue }
        }
    }

Get-FolderTocInfo (addon-sync.ps1:1594-1655) already returns exactly
{title; version; hasToc; curseId; wagoId} from a single folder's primary
.toc - reused verbatim, zero changes to that function. Its ## Version
regex (addon-sync.ps1:1639, `^\s*##\s*Version\s*:\s*(.*)$`) is what
produces $tocInfo.version here.

"Looks like a tag" regex: `^[vV]?[0-9][\w.\-]*$` (optional leading v/V,
then a digit, then word/dot/hyphen characters) - deliberately accepts a
BARE number with no v prefix, since both of Eric's real addons use exactly
that shape (TimelineReminders "v454" matches via the v-branch; AuraUpdater
"164" matches via the bare-digit branch). Anything else (empty, a
sentence, "dev", a date stamp with slashes) falls through to the literal
string "unknown", which the very next real check will always see as
different from any real tag_name - triggering "update available"
immediately, per decision 3's own parenthetical.

Never runs when a folder of that exact name does NOT already exist
(the record proceeds to a normal first-time install, step 3 onward) - this
adoption path is scoped exactly to the two folders Eric already has
(TimelineReminders, AuraUpdater), both of which match their own repo name
exactly, and to any other repo whose release happens to name its addon
folder identically to the repo (the common case for single-folder addons).
A repo whose package unpacks to a DIFFERENT folder name (or several) never
matches here and simply installs normally the first time, same as any
CurseForge/Wago add of a not-yet-installed addon.

3.8 Adding a GitHub record (the -Add path)

No new code needed in the -Add block (addon-sync.ps1:4970-5006) beyond
what 3.1's ConvertTo-TargetToken/Test-RecordMatchesTarget changes already
provide - it already dispatches on $target.IsWago vs the CurseForge
default; gains one more branch:

    if ($target.IsGithub) {
        $newRecord = New-GithubAddonRecord -Repo $target.GithubRepo
    } elseif ($target.IsWago) {
        $newRecord = New-WagoAddonRecord -Slug $target.WagoRef
    } else {
        $newRecord = New-AddonRecord -ProjectId $target.ProjectId
    }

The newly-added record's installedTag is $null at this point - the very
next sync pass (the SAME run, since -Add falls through into the normal
toSync loop exactly like a CurseForge/Wago add already does) runs
Sync-SingleGithubAddon on it, which is where 3.7's adopt-in-place check or
3.3's first real install actually happens. No separate "check for existing
folder" step is needed at -Add time itself.

3.9 How the CLI gets the token - settings.json only

Get-Settings (addon-sync.ps1:3038-3086) gains one field, read the same
tolerant way as releaseType/port:

    $defaults = [PSCustomObject]@{
        releaseType = 1
        port        = 47831
        githubToken = $null
    }
    ...
    $result = [PSCustomObject]@{
        releaseType = $defaults.releaseType
        port        = $defaults.port
        githubToken = $defaults.githubToken
    }
    ...
    if ($null -ne $parsed.githubToken) {
        $result.githubToken = [string]$parsed.githubToken
    }

The main script body's existing single call site (addon-sync.ps1:4489)
needs no change to the call itself - $settings.githubToken is simply now
available on the same $settings object already in scope, threaded into
the one Sync-SingleAddon call site (addon-sync.ps1:5338) per 3.2. The CLI
NEVER accepts a token via any command-line parameter - there is no -Token/
-GithubToken CLI switch anywhere in this design, only the in-process
$settings.githubToken value read straight from ROOT\settings.json at
startup, matching FIXED DECISION 2 exactly ("the CLI reads it from
settings.json, never from the command line"). This also means a GitHub
job's `params` (visible via GET /api/jobs/<id>, and persisted to
jobs\<id>.json) never contains the token at all - it is never on the
command line the server builds for the CLI child process, so there is
nothing to redact there (see 6.1).

=====================================================================
4. Server (addon-server.ps1)
=====================================================================

4.1 Settings key githubToken - default, migration, read

Get-DefaultSettings (addon-server.ps1:1354-1436) gains, appended after
showTestRealms:

    # Round 47: the shared GitHub personal access token some guilds hand
    # out for private-release addons (GITHUB-SOURCE-SPEC.md). Plain text on
    # disk, same as every other settings.json field - this is the SAME
    # trust boundary the old one-off script already used (a config file on
    # the player's own PC). Never returned by GET /api/settings - see
    # Get-SettingsView. $null (not "") when never set.
    githubToken = $null

Get-Settings (addon-server.ps1:1448 on) gains, alongside the other plain
pass-throughs (same spot as showTestRealms's own line, addon-server.ps1:
1530):

    if ($null -ne $obj.githubToken) { $result.githubToken = [string]$obj.githubToken }

No migration rewrite is needed (unlike the cfApiKey/autoUpdateOnLaunch
removals at addon-server.ps1:1531-1564, which actively strip a REMOVED
field) - githubToken is additive-only, so a pre-1.27.0 settings.json simply
lacks the key and falls through to the $null default via the same
"$null -ne" tolerance every other field here already uses.

4.2 View fields: hasGithubToken / githubTokenHint

Get-SettingsView (addon-server.ps1:1591-1634) gains, appended after
showTestRealms - NEVER the raw token itself:

    # Round 47: githubToken is the one settings.json field that IS a
    # secret - unlike every other field returned above unmasked, the raw
    # value never leaves this process. hasGithubToken/githubTokenHint let
    # the SPA show "a token is saved, ending in ...ab12" without ever
    # round-tripping the real value back to the browser.
    hasGithubToken  = [bool](-not [string]::IsNullOrWhiteSpace($Settings.githubToken))
    githubTokenHint = $(
        $t = $Settings.githubToken
        if ([string]::IsNullOrWhiteSpace($t)) { $null }
        elseif ($t.Length -le 4) { $t }
        else { $t.Substring($t.Length - 4) }
    )

githubTokenHint is exactly the last 4 characters (or the whole token when
it happens to be 4 characters or fewer - a defensive edge case, never hit
by a real GitHub PAT, which is always well over 4 characters). $null when
no token is set. This is the ONLY place any part of the token value is
ever exposed outside settings.json, and it is deliberately the SHORTEST
possible slice that still lets Eric recognize "yes, that's the token I
pasted" without meaningfully weakening it if somehow observed.

4.3 PUT semantics, including clearing

Handle-SettingsPut (addon-server.ps1:7797-7967) gains, alongside the other
plain-value branches (right before the final Save-Settings call, after the
showTestRealms branch at addon-server.ps1:7949-7951):

    # Round 47: githubToken is the one settings field with CLEAR semantics
    # - every other field here can only ever be overwritten, never unset,
    # because none of them has an "absent" state distinct from a default
    # value. A secret needs an explicit way to go back to "not set" without
    # inventing a new null-vs-absent JSON convention: an EMPTY string
    # clears it (the Settings card's Remove button PUTs {githubToken:""}),
    # a non-empty string sets it, and OMITTING the field (as every normal
    # PUT that only touches OTHER settings already does) leaves it
    # untouched - identical to every other field's own "only present
    # fields are read" contract, just with one more meaningful value
    # (empty string) inside that already-present case.
    if ($null -ne $body.githubToken) {
        $tok = [string]$body.githubToken
        if ($tok.Trim().Length -eq 0) {
            $settings.githubToken = $null
        } elseif ($tok.Length -gt 512) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'githubToken is too long' }
            return
        } else {
            $settings.githubToken = $tok
        }
    }

512 is a generous defense-in-depth cap (a real GitHub PAT is well under
100 characters either format) - matches the spirit of hostTheme's own
12-color/32-char caps (addon-server.ps1:1654-1676) rather than any real
GitHub-side limit. No format validation beyond length (no ghp_/github_pat_
prefix check) - GitHub has shipped more than one token format historically
and a wrong/expired token already fails cleanly at the API with the exact
message in 3.5; over-validating the shape here would only risk rejecting a
real future format.

Get-SettingsView is called on the way out exactly like every other PUT
branch (addon-server.ps1:7966) - the response to a successful PUT still
never contains the raw token, only the refreshed hasGithubToken/
githubTokenHint.

4.4 Token redaction helper, applied to every log/error path it could reach

New function, placed near Write-ServerLog (addon-server.ps1 ~219):

    function Get-RedactedLogText {
        <#
          Round 47: defense-in-depth scrub applied at the log/error CHOKE
          POINTS (Write-ServerLog here; Write-Log in addon-sync.ps1) so an
          accidental future interpolation of a raw githubToken value into
          any message string - not something this design intentionally
          does anywhere, see 3.5/3.6/3.7's own messages, none of which ever
          include the token - still never reaches disk. Matches both real
          GitHub PAT formats (github_pat_... fine-grained, ghp_... classic)
          plus their close variants (gho_, ghu_, ghs_, ghr_ - GitHub's other
          OAuth/app token prefixes, redacted the same way even though this
          app never issues or stores those shapes, since a player could in
          principle paste one into the same field).
        #>
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
        # REVIEW FOLD-IN, finding E/5: the hard project rule mandates every
        # test/fixture token look like "github_pat_TESTONLY_0000" - the
        # suffix "TESTONLY_0000" is 13 characters, which a {20,} floor would
        # NOT catch (a real fine-grained PAT's suffix is 82+ characters, a
        # classic ghp_ token's is 36 - both comfortably clear either floor,
        # so lowering it costs nothing against a real leaked token). Floor
        # lowered to {8,} here so the project's OWN canonical fixture
        # literal is provably caught by this same defense-in-depth net,
        # which matters because Server.GithubTokenRedaction.Tests.ps1 (7.1)
        # is specced to use exactly this kind of literal to prove the
        # regex works - a floor the mandated fixture text itself fails
        # would make that test either misleading (asserting redaction of a
        # literal chosen SPECIFICALLY to be too short) or force every test
        # file to invent its own longer, non-canonical fake token instead.
        $Text = $Text -replace '\bgithub_pat_[A-Za-z0-9_]{8,}', 'github_pat_***REDACTED***'
        $Text = $Text -replace '\bgh[pousr]_[A-Za-z0-9]{8,}', 'gh?_***REDACTED***'
        return $Text
    }

Write-ServerLog (addon-server.ps1:219-229) gains one line, right before
the Add-Content call:

    $line = Get-RedactedLogText ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Message)

The CLI's own Write-Log (addon-sync.ps1 - the equivalent single choke
point every ERROR/WARN/INFO line in this file already funnels through)
gets the identical treatment, plus the CLI needs its OWN copy of
Get-RedactedLogText (addon-sync.ps1 has no dependency on addon-server.ps1,
by design - each file is a standalone script) - same function body,
duplicated once, same comment pointing at this section.

*** FILE OWNERSHIP (REVIEW FOLD-IN, finding H/9): this paragraph is an
addon-sync.ps1 edit, even though it lives under this section's "Server"
heading. It belongs to Package A's file list in section 9, not Package
B's - see section 9's own revised text, which now says so explicitly.
This callout exists so implementing this paragraph is never contingent on
someone reading all of section 4 despite owning only addon-sync.ps1. ***

Every Send-Json error body in this file that could ever carry
$_.Exception.Message text from a GitHub-related catch block also runs it
through Get-RedactedLogText before use, same defense-in-depth reasoning -
in practice this affects zero NEW call sites this round (Handle-SettingsPut
never echoes $body.githubToken back in an error string; no other GitHub-
touching endpoint in section 4 re-surfaces exception text at all), but the
helper existing and being the documented required treatment for "any
message that touches this text" covers it going forward.

4.5 The add-from-GitHub job request shape and validation

New addon add, no existing record yet - mirrors the EXISTING Wago
new-add shape ({source:'wago', slug}, addon-server.ps1:2871-2884)
byte-for-byte, just with 'github'/'repo' instead of 'wago'/'slug':

    POST /api/jobs
    { "kind": "add", "source": "github", "repo": "bart-dev-wow/AuraUpdater" }

Handle-JobsPost (addon-server.ps1:7287 on) gains, alongside the existing
$hasWagoSourceSlug computation (addon-server.ps1:7319):

    $hasGithubSourceRepo = [bool]($body.source -and $body.repo -and (([string]$body.source).ToLowerInvariant() -eq 'github'))

...OR'd into every place $hasWagoSourceSlug already gates the "missing
projectId" 400 (addon-server.ps1:7408) and the "$hasMultiAdd" three-way
either/or, so `{kind:'add', source:'github', repo:'...'}` is accepted on
its own without also requiring a projectId.

Validation - "only github.com/owner/repo or owner/repo" - happens in TWO
places that must stay in lockstep:
  - The SPA parses whatever the player pasted (a full github.com link OR a
    bare owner/repo) into a normalized "owner/repo" string CLIENT-SIDE
    before ever posting (section 5.3) - the wire shape above only ever
    carries the already-normalized form, never a raw pasted URL.
  - The server still validates that normalized string, defensively (a
    hand-crafted request, or a future non-SPA caller):

    if ($hasGithubSourceRepo) {
        $repoText = [string]$body.repo
        if ($repoText -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/([A-Za-z0-9._-]{1,100})$') {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: repo must look like owner/repo' }
            return
        }
        # REVIEW FOLD-IN, finding A/1: identical $repoTraversalPattern guard
        # as 3.1/5.3 - see 3.1 for the full "why" (a repo segment of "." or
        # ".." passes the regex above cleanly and later resolves outside
        # $AddonsPath once it reaches a filesystem path on the CLI side).
        if ($Matches[1] -match '^\.+$') {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: repo must look like owner/repo' }
            return
        }
    }

(same regex AND traversal guard as the CLI's own owner/repo shape in 3.1 -
kept textually identical in both files, called out in each file's own
comment as "must match addon-sync.ps1's ConvertTo-TargetToken /
addon-server.ps1's Handle-JobsPost exactly, guard included" so a future
edit to one is a visible prompt to check the other.)

4.6 Normalizing into the existing 'add'/'install' Params.projectId path

Start-Job (addon-server.ps1:2869-2884) gains a github branch immediately
after the existing wago one:

    if (($cliKind -eq 'add' -or $cliKind -eq 'install') -and $Params -and $Params.source -and (([string]$Params.source).ToLowerInvariant() -eq 'github') -and $Params.repo) {
        $Params = Add-Member -InputObject $Params -NotePropertyName 'projectId' -NotePropertyValue ('github:' + [string]$Params.repo) -Force -PassThru
    }

From this point on, Build-CliArgs's existing 'add'/'install' cases
(addon-server.ps1:2401-2429/2450-2458) need NO changes at all - they
already just [string]-cast Params.projectId/fileId generically, exactly
the comment at addon-server.ps1:2873-2877 already notes for why the wago:
normalization works this way. The resulting -Add/-Only token
("github:bart-dev-wow/AuraUpdater") is parsed by ConvertTo-TargetToken's
new github: branch (3.1) exactly like any other CLI invocation.

An ADD/INSTALL targeting an ALREADY-TRACKED GitHub addon (the kebab menu's
"Update now", say) instead posts projectId directly as "github:owner/repo"
(the record's own identity string, mirroring how an already-tracked Wago
addon's own Store.addonKey already does this, addon-server.ps1:2879-2881)
- needs no normalization branch at all, already covered by the generic
[string]-cast.

4.7 Two lookup helpers that key off record fields by name

Get-UpdateAvailableKeyForRecord (addon-server.ps1:3472-3489) gains, before
the final `return $null`:

    if ($Record.source -eq 'github' -and $Record.repo) {
        return 'github:' + $Record.repo.ToLowerInvariant()
    }

Get-UpdateAvailableKeyForRow (addon-server.ps1:3491-3507) gains, mirroring
its own wagoSlug branch:

    if ($Row.repo) {
        return 'github:' + ([string]$Row.repo).ToLowerInvariant()
    }

The CLI's own -Json result-row shape (addon-sync.ps1:5442-5454) gains one
field in the same object literal, appended after wagoSlug:

    repo = $r.Repo

...which requires every $resultsRows.Add(...) call site that already
carries a WagoSlug field (addon-sync.ps1 lines 4963, 4994, 5046, 5050,
5055, 5064, 5112, 5142, 5163, 5166, 5187, 5190, 5211, 5214, 5235, 5238,
5352 - re-verified against the live build: exactly these 17 lines, no
more, no fewer) to ALSO carry a `Repo =` value alongside it, mirroring
WagoSlug's own value at each site 1:1 (e.g. line 4963's
`WagoSlug = $removeResult.Record.slug` gains
`Repo = $removeResult.Record.repo` right next to it; line 5352's
`WagoSlug = $record.slug` gains `Repo = $record.repo`). Every row that is
not GitHub-sourced simply carries Repo=$null, same as WagoSlug already
does for a non-Wago row.

*** FILE OWNERSHIP (REVIEW FOLD-IN, finding H/9): this whole paragraph -
the -Json shape's new `repo` field AND all 17 `Repo =` call-site edits - is
entirely addon-sync.ps1, same callout as 4.4's above. Belongs to Package
A's file list in section 9, not Package B's, despite living under this
section's "Server" heading. Get-UpdateAvailableKeyForRecord/
Get-UpdateAvailableKeyForRow just above (still addon-server.ps1) stay
Package B's, as specced. ***

4.8 $Script:Version bump

addon-server.ps1:10380 - `$Script:Version = '1.26.0'` becomes
`$Script:Version = '1.27.0'`. Every consumer of $Script:Version already
reads it live (the Uninstall registry's DisplayVersion at
addon-server.ps1:8219, the /api/health body at addon-server.ps1:7028, the
user-agent string in Invoke-AppUpdateMaintenanceCore at
addon-server.ps1:9573/9683) - none of those call sites need a separate
edit.

=====================================================================
5. SPA (ui\app.js, ui\index.html, ui\style.css)
=====================================================================

5.1 Settings card layout - "GitHub addons"

New `<section class="settings-group" id="settings-github">` in
ui\index.html, placed inside the SAME `<details class="settings-advanced"
id="settings-advanced">` block the existing "settings-curseforge" section
already lives in (ui\index.html:1196-1237ish) - a token field is exactly
the kind of thing that belongs behind Advanced, matching where the
now-removed CurseForge API key field used to live, and where the
protocol-handler control (#settings-protocol-control) sits today.

    <section class="settings-group" id="settings-github">
      <h3>GitHub addons</h3>
      <p class="muted-text">Some guilds share addons as private GitHub releases and give you a token. It stays on this PC and is only ever sent to GitHub.</p>
      <div class="settings-row settings-row-col">
        <div class="settings-row-label">Token<button type="button" class="info-tip" tabindex="0" aria-label="More about Token" aria-describedby="app-tooltip" data-tooltip="Some guilds share addons as private GitHub releases and give you a token. It stays on this PC and is only ever sent to GitHub."><svg class="icon"><use href="#icon-info"></use></svg></button></div>
        <div class="token-input-row">
          <input type="password" id="github-token-input" placeholder="Paste your token" autocomplete="off">
          <button type="button" class="btn btn-ghost btn-icon" id="github-token-show" aria-label="Show token" aria-pressed="false"><svg class="icon"><use href="#icon-eye"></use></svg></button>
        </div>
        <p class="muted-text" id="github-token-status"></p>
        <div class="settings-row-actions">
          <button type="button" class="btn btn-outline" id="github-token-save">Save</button>
          <button type="button" class="btn btn-ghost" id="github-token-remove" hidden>Remove</button>
        </div>
      </div>
      <div class="settings-row settings-row-col">
        <div class="settings-row-label">Add an addon from GitHub</div>
        <div class="token-input-row">
          <input type="text" id="github-add-input" placeholder="github.com/owner/repo" autocomplete="off">
          <button type="button" class="btn btn-outline" id="github-add-submit">Add</button>
        </div>
        <p class="form-msg" id="github-add-error" hidden></p>
      </div>
    </section>

(#icon-eye needs adding to index.html's shared <svg><symbol> icon sheet if
not already present - a plain open-eye glyph, matching the existing
#icon-info/#icon-download line-icon style; a closed-eye variant is not
needed - the show/hide toggle only changes the input's type attribute and
the button's own icon can stay the same single eye glyph with aria-pressed
communicating state, matching how #density-toggle's segmented buttons
already use aria state rather than swapping icons.)

Tooltip text (verbatim, used both on the info-tip and as the card's own
intro paragraph per FIXED DECISION 4): "Some guilds share addons as private
GitHub releases and give you a token. It stays on this PC and is only ever
sent to GitHub."

5.2 Views.settings wiring (ui\app.js, alongside renderBrowsing/
    renderBackgroundUpdates at ui\app.js:7074-7077)

New `renderGithub(s)` called from `render()` (ui\app.js:7047-7098) right
after `renderBrowsing(s)`:

    function renderGithub(s) {
      const hasToken = !!s.hasGithubToken;
      Utils.qs("#github-token-status").textContent = hasToken
        ? ("Token saved, ending in " + (s.githubTokenHint || "----") + ".")
        : "No token saved.";
      Utils.qs("#github-token-remove").hidden = !hasToken;
      Utils.qs("#github-token-input").value = "";
      Utils.qs("#github-token-input").placeholder = hasToken ? "Paste a new token to replace it" : "Paste your token";
    }

Show/hide toggle (bindOnce, alongside the other static Settings button
wiring around ui\app.js:8856-8862):

    Utils.qs("#github-token-show").addEventListener("click", function () {
      const input = Utils.qs("#github-token-input");
      const showing = input.type === "text";
      input.type = showing ? "password" : "text";
      this.setAttribute("aria-pressed", String(!showing));
    });

Save (never sends an empty string unless the field is genuinely empty -
Save with an empty field is a no-op with an inline nudge, not a silent
clear; clearing is Remove's job alone, keeping the two actions unambiguous):

    Utils.qs("#github-token-save").addEventListener("click", async function () {
      const val = Utils.qs("#github-token-input").value;
      if (!val) { Components.Toast.show("Paste a token first, or use Remove.", "warning"); return; }
      await Actions.saveSettings({ githubToken: val }, "Token saved.");
    });
    Utils.qs("#github-token-remove").addEventListener("click", async function () {
      await Actions.saveSettings({ githubToken: "" }, "Token removed.");
    });

(Actions.saveSettings already exists, ui\app.js:5426-5434 - `await
Api.putSettings(patch)` then re-renders Settings and toasts - reused
verbatim, no changes to that function.)

5.3 The add flow - parsing, shared by both entry points

New shared function (ui\app.js, near submitAddInput at ui\app.js:5507):

    const GITHUB_OWNER_RE = "[A-Za-z0-9][A-Za-z0-9-]{0,38}";
    const GITHUB_REPO_RE = "[A-Za-z0-9._-]{1,100}";
    function parseGithubRepoInput(raw) {
      const value = (raw || "").trim();
      let m = value.match(new RegExp("^(?:https?://)?(?:www\\.)?github\\.com/(" + GITHUB_OWNER_RE + ")/(" + GITHUB_REPO_RE + ")(?:\\.git)?/?(?:[?#].*)?$", "i"));
      if (!m) m = value.match(new RegExp("^" + GITHUB_OWNER_RE.replace(")", ")") + "$", "i")); // placeholder never matches alone - see next line
      if (!m) m = value.match(new RegExp("^(" + GITHUB_OWNER_RE + ")/(" + GITHUB_REPO_RE + ")$", "i"));
      if (!m) return null;
      // REVIEW FOLD-IN, finding A/1: identical traversal guard as 3.1/4.5 -
      // a repo segment of "." or ".." matches GITHUB_REPO_RE cleanly but
      // is not a safe folder name once it reaches the CLI's filesystem
      // code (3.6.3/3.7) - reject it here too, at the earliest point.
      if (/^\.+$/.test(m[2])) return null;
      return m[1] + "/" + m[2];
    }

    async function submitGithubAddInput(raw) {
      const errorBox = Utils.qs("#github-add-error");
      function fail(msg) { errorBox.textContent = msg; errorBox.hidden = false; errorBox.className = "form-msg is-error"; }
      const repo = parseGithubRepoInput(raw);
      if (!repo) { fail("Paste a github.com/owner/repo link, or type owner/repo."); return; }
      Components.Dialogs.closeGithubAdd();
      await Actions.startJob("add", { source: "github", repo: repo });
    }

(the placeholder line above is a documentation artifact of hand-writing
regex alternation for this spec - the actual implementation is simply the
two real patterns, full-URL-form then bare-owner/repo-form, tried in that
order, exactly as shown in the CLI's own ConvertTo-TargetToken in 3.1;
strip the placeholder line when implementing.) Actions.startJob is this
codebase's existing generic "post a job, track it, show the progress
panel" entry point (used by every other add flow already) - reused as-is,
no changes to it.

5.4 Two entry points, one dialog

New Components.Dialogs.openGithubAdd()/closeGithubAdd(), same show/hide
pattern as openAdd()/closeAdd() (ui\app.js:2704-2711), dialog id
"dialog-github-add":

New markup in ui\index.html, alongside dialog-add (ui\index.html:
1509-1523):

    <div class="dialog" id="dialog-github-add" hidden role="dialog" aria-modal="true" aria-labelledby="dialog-github-add-title">
      <h3 id="dialog-github-add-title">Add an addon from GitHub</h3>
      <p class="muted-text">Paste a github.com/owner/repo link, or type owner/repo.</p>
      <form id="github-add-form">
        <input type="text" id="github-add-dialog-input" placeholder="github.com/owner/repo" autocomplete="off">
        <p class="form-msg" id="github-add-dialog-error" hidden></p>
        <div class="dialog-footer">
          <button type="button" class="btn btn-ghost" id="github-add-dialog-cancel">Cancel</button>
          <button type="submit" class="btn btn-outline" id="github-add-dialog-submit">Add</button>
        </div>
      </form>
    </div>

show(name)/hide(name) (ui\app.js:2659-2702) already work for any dialog id
by construction (they read "#dialog-" + name generically) - openGithubAdd
just needs to reset the input/error and call show("github-add"), same
shape as openAdd(). backdropClicked()/escPressed()/trapTab (ui\app.js:
2753-2791) each gain one more `else if (openName === "github-add")` arm,
mirroring the existing "add"/"welcome" arms exactly.

Entry point 1 - Settings card's own "Add" button (5.1) calls
submitGithubAddInput directly on its OWN inline input (#github-add-input),
no dialog at all - it already lives on a page, not in a modal.

Entry point 2 - "Get new addons" (Views.browse) gains a small link/button
near the existing "Add addon" entry point (ui\app.js:6964-6965,
ui\index.html wherever #btn-browse-add-link lives):

    <button type="button" class="link-btn" id="btn-browse-add-github-link">From a GitHub link</button>

wired to `Components.Dialogs.openGithubAdd()` - literally "opens the same
add flow" (FIXED DECISION 4's own words): the dialog's submit handler
calls the SAME submitGithubAddInput function the Settings card's inline
Add button calls, just reading from #github-add-dialog-input instead of
#github-add-input.

5.5 Source badge

ui\app.js:2810 and :6076 (the two existing `source-badge` builders) each
gain a third branch:

    const badgeClass = a.source === "wago" ? "is-wago" : (a.source === "github" ? "is-github" : "is-cf");
    const badgeLabel = a.source === "wago" ? "Wago Addons" : (a.source === "github" ? "GitHub" : "CurseForge");
    const badgeText  = a.source === "wago" ? "Wago" : (a.source === "github" ? "GitHub" : "CF");
    const badge = Utils.el("span", { class: "source-badge " + badgeClass, title: badgeLabel }, [badgeText]);

("GitHub" spelled out, matching "Wago" rather than the abbreviated "CF" -
short enough to fit the same pill without truncation.) ui\style.css:
1509-1515 gains one rule, reusing the ALREADY-EXISTING neutral tint pair
every theme in this file already defines (ui\style.css:73-78 and its
per-theme redefinitions) - no new CSS variable, no per-theme edits needed:

    .source-badge.is-github { background: var(--muted-tint); color: var(--muted); }

The "Get new addons" grid's own separate badge builder (ui\app.js:6641-6645)
gets the identical third branch (that badge only ever shows CF/Wago today
because GitHub addons are never something you "browse" into existence per
this round's non-goals - see 1 - so in practice this branch is dead code
there today, added anyway for consistency and because Entry point 2 in 5.4
DOES live in that same view).

5.6 failureReason() bucket additions (ui\app.js:4407-4434)

Two new lines in the existing if/else chain, placed alongside the existing
`checking-network` line (ui\app.js:4430), same "most specific phase first"
ordering:

    if (failPhase === "checking-needs-token") return "This addon needs a GitHub token - paste it in Settings > GitHub addons.";
    if (failPhase === "checking-network-github") return "Couldn't check for updates - GitHub might be having trouble";

No other line in that function changes. wholeJobFailureReason (ui\app.js:
4459 on) needs no change - per its own existing doc comment (ui\app.js:
4447-4457), a per-addon FailPhase (this one included) never reaches that
whole-job path; it is fully handled by failureReason() alone, same
reasoning already documented there for checking-network.

5.7 Versions tab behavior for tags

REVISED in review (finding I/10 - the critic's own writeup, and this
spec's original text, both under-scoped this fix; re-reading the actual
code below turned up a DEEPER, wider break than either described, fixed in
full here rather than patched at just the one call site originally named).

The original plan patched ONLY Store.addonKey (the forward direction: given
an addon object, produce its key string) and assumed
Store.addonByProjectId (the REVERSE direction: given a key string, find the
addon object) would "already work... for free" once addonKey did. It does
not. Reading addonByProjectId directly (ui\app.js:2446-2454): its only
non-numeric special case is a hardcoded `key.toLowerCase().indexOf("wago:")
=== 0` branch; anything else - including a "github:owner/repo" key -
falls through to `state.addons.find(a => a.projectId === key)`, which can
NEVER match a GitHub record (projectId is always null there, 2.1) or a
string key. Patching addonKey alone leaves addonByProjectId returning
undefined for every GitHub addon.

This is not merely a Versions-tab bug. Components.Drawer.open() itself
(ui\app.js:3438-3462, the function that runs on EVERY "View" / "Versions..."
click, not something section 5 originally covered at all) calls
`Store.addonByProjectId(key)` to compute `tracked` and derives `source`
from a hardcoded `isWago` check alone:

    const isWago = opts.source === "wago" || (typeof key === "string" && key.toLowerCase().indexOf("wago:") === 0);
    const addon = Store.addonByProjectId(key);
    ...
    const source = isWago ? "wago" : "cf-keyless";
    ...
    Store.set({ drawer: { open: true, projectId: key, source: source, ..., tracked: !!addon, lastKnownFileId: addon ? addon.fileId : null, ... } });
    ...
    if (isWago) { loadWagoAddon(); } else { loadEnrich(); }

For a GitHub addon, BEFORE any fix: `addon` is undefined (per the
addonByProjectId gap above), so `tracked` is FALSE and `lastKnownFileId` is
null; `source` falls all the way to `"cf-keyless"` (wrong - not
CurseForge); and because isWago is false, `loadEnrich()` - the
CurseForge-keyless-enrichment network call - fires for a GitHub addon,
which has no CurseForge project to enrich. Every drawer tab gated on
`d.tracked` (renderOverview at ui\app.js:3700/3774, renderChangelog/
renderScreenshots at 4057/4125, and renderGithubVersions itself at 3952/
3979) sees tracked=false and shows an untracked/empty state for a fully
installed, checked GitHub addon - not just a Versions tab that fails to
render Update, but the WHOLE drawer misrepresenting the addon as
untracked, plus one wasted/nonsensical network request per open. The fix
has to land in Store.addonByProjectId and Drawer.open, not only in
renderGithubVersions/addonKey:

  - Store.addonKey (ui\app.js:2441-2444) gains the mirrored branch exactly
    as originally specced: `if (addon && addon.source === "github") return
    "github:" + addon.repo;` right next to the existing wago branch.
  - Store.addonByProjectId (ui\app.js:2446-2454) gains a MATCHING reverse
    branch, mirroring the existing wago one 1:1 (this is the actual fix -
    the original plan never touched this function at all):

        function addonByProjectId(id) {
          const key = Utils.normalizeId(id);
          if (typeof key === "string" && key.toLowerCase().indexOf("wago:") === 0) {
            const ref = key.slice(5).toLowerCase();
            return state.addons.find(function (a) {
              return a.source === "wago" && (((a.slug || "").toLowerCase() === ref) || ((a.wagoId || "").toLowerCase() === ref));
            });
          }
          if (typeof key === "string" && key.toLowerCase().indexOf("github:") === 0) {
            const ref = key.slice(7).toLowerCase();
            return state.addons.find(function (a) { return a.source === "github" && (a.repo || "").toLowerCase() === ref; });
          }
          return state.addons.find(function (a) { return a.projectId === key; });
        }

  - Components.Drawer.open() (ui\app.js:3438-3462) gains an `isGithub`
    companion to the existing `isWago` check, and `source`/the
    isWago-vs-loadEnrich dispatch both gain a third arm:

        const isGithub = opts.source === "github" || (typeof key === "string" && key.toLowerCase().indexOf("github:") === 0);
        ...
        const source = isWago ? "wago" : (isGithub ? "github" : "cf-keyless");
        ...
        if (isWago) { loadWagoAddon(); } else if (isGithub) { /* GitHub gives no author/description to enrich - 2.1 - so no network call at all, same as Wago's own dedicated branch skips loadEnrich */ } else { loadEnrich(); }

    With this fix, `tracked` (`!!addon`) is correctly true for a tracked
    GitHub addon (addonByProjectId now resolves it), `d.source` is
    correctly `"github"` (not `"cf-keyless"`), and no CurseForge-keyless
    enrichment call fires for a repo that has no CurseForge project id.
  - renderVersions() (ui\app.js:4101-4136) gains a third source branch,
    right after the existing Wago one (ui\app.js:4104), UNCHANGED from the
    original plan (this part was always correctly scoped):

        if (d.source === "github") { renderGithubVersions(); return; }

renderGithubVersions() itself is DELIBERATELY MINIMAL - no release-history
browse (non-goal, section 1). It shows exactly what is known without a new
network call the drawer does not already make, and now correctly resolves
`addon` thanks to the addonByProjectId fix above:

    function renderGithubVersions() {
      const panel = Utils.qs("#drawer-panel-versions");
      panel.textContent = "";
      const addon = d.tracked ? Store.addonByProjectId(d.projectId) : null;
      const rows = [];
      const installedTag = addon ? addon.installedTag : null;
      rows.push(Utils.el("div", { class: "settings-row" }, [
        Utils.el("div", { class: "settings-row-text" }, [
          Utils.el("div", { class: "settings-row-label" }, ["Installed"]),
          Utils.el("div", { class: "settings-row-value" }, [installedTag || "-"])
        ])
      ]));
      if (addon && addon.updateAvailable && addon.updateAvailable.version) {
        rows.push(Utils.el("div", { class: "settings-row" }, [
          Utils.el("div", { class: "settings-row-text" }, [
            Utils.el("div", { class: "settings-row-label" }, ["Latest"]),
            Utils.el("div", { class: "settings-row-value" }, [addon.updateAvailable.version])
          ]),
          Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.startJob("sync", { ids: [Store.addonKey(addon)] }); } }, ["Update"])
        ]));
      }
      panel.appendChild(Utils.el("div", { class: "versions-simple-list" }, rows));
      panel.appendChild(Utils.el("p", { class: "rich-content muted-text" }, ["Furphy shows the installed and latest release tag for GitHub addons - full release history isn't browsable here."]));
    }

(Store.addonKey and Actions.startJob are this codebase's existing generic
helpers, unchanged beyond the addonKey branch above; the server-side
addon-key-derivation site addon-server.ps1 already mirrors at 4.7/2.4's
Get-UpdateAvailable* functions - that side needed no fix, only the SPA's
own reverse lookup did.)

7.4's SPA harness checks (below) must open the mock GitHub addon's drawer
via Components.Drawer.open (not call renderGithubVersions directly) so
this whole chain - addonKey, addonByProjectId, Drawer.open's own
isGithub/source/tracked derivation, THEN renderVersions/renderGithubVersions
- is exercised end to end, the same way the original bug would only ever
have shown up in an actual drawer open, never in a renderGithubVersions
unit-style check alone.

renderChangelog()/renderScreenshots() need NO github branch - their
existing fallthrough (renderKeylessChangelog, ui\app.js:4232-4247; the
generic no-gallery empty state) already renders a plain "nothing here,
here's a link out" state for anything that is not specifically Wago, and
that is the CORRECT behavior for GitHub too (GitHub gives Furphy no
changelog text or screenshot gallery at all) - the only adjustment is the
generic empty-state's own "View on CurseForge.com" link
(ui\app.js:4245), which must NOT show for a GitHub-sourced addon (it would
be wrong - there is no CurseForge page for it). Guard it:

    if (d.source !== "github") {
      panel.appendChild(Utils.el("div", { class: "btn-row" }, [ /* the existing CurseForge link button */ ]));
    }

5.8 Mock fixtures (?mock=1)

mockSettings (ui\app.js:278) gains two fields, appended:

    const mockSettings = { releaseType: 1, port: 47831, adFilter: true, cfFocus: true, hostWindow: null, backgroundUpdates: false, backgroundIntervalMinutes: 120, runAtStartup: false, activeFlavour: "retail", showTestRealms: false, appUpdateAutoInstall: true, hasGithubToken: false, githubTokenHint: null };

New mock addon entry appended to the `addons` array (ui\app.js:392-416),
immediately after the existing Wago entry (ui\app.js:415), same
"exercises the badge/drawer branches without a real server" comment
pattern as that entry's own (ui\app.js:411-414):

    // Round 47 (GitHub third source): a GitHub-sourced tracked addon,
    // exercising the My Addons source badge, the drawer's GitHub branches,
    // and the minimal Versions tab tag display without the real server.
    { name: "TimelineReminders", projectId: null, fileId: null, version: "v454", fileName: null, installedAt: new Date(Date.now() - 1 * 24 * 3600e3).toISOString(), folders: ["TimelineReminders"], author: null, ignoreUpdates: false, pinnedFileId: null, releaseType: null, source: "github", repo: "bart-dev-wow/TimelineReminders", installedTag: "v454", assetName: null, updateAvailable: { fileId: null, version: "v455" } }

=====================================================================
6. Security
=====================================================================

6.1 Threat model

Asset: the shared guild GitHub personal access token, plain text in
ROOT\settings.json (the player's own PC - this is the SAME trust boundary
the old one-off script already used; this design changes NOTHING about
where the token lives at rest, only how it flows once loaded).

  - At rest: settings.json on the player's own disk, no different from
    any other locally-installed app's config file. Not encrypted (matches
    every other field in this file - there is no secrets-at-rest story
    anywhere else in Furphy either, e.g. the removed cfApiKey was also
    plain text). Out of scope to change this round.
  - In transit: the `Authorization: Bearer <token>` header is sent ONLY to
    api.github.com - the release lookup, and the INITIAL request for an
    asset-by-id or zipball download (REVISED in review, finding B/2; the
    original text here claimed PowerShell resends this header to
    objects.githubusercontent.com on redirect, which is both incomplete
    and backwards - corrected mechanics, and the reasoning behind them,
    are in 3.5). GitHub answers those download requests on a private repo
    with a 302 to a pre-signed, time-limited URL - objects.githubuser
    content.com for an asset-by-id download, codeload.github.com for the
    zipball_url fallback (3.6.2) - and empirically, THIS build's
    Invoke-HttpDownloadWithProgress (the [System.Net.HttpWebRequest]-based
    helper that actually performs every asset/zipball download, 3.4) does
    NOT resend a Headers.Add-added Authorization header across that
    cross-host redirect at all: the signed URL is its own auth, no Bearer
    token is required or sent for that second request, to EITHER host.
    So the token's real reach is narrower than originally documented, not
    wider: api.github.com only. NEVER sent to CurseForge
    (www.curseforge.com) or Wago (addons.wago.io) - those two sources' own
    request-building code (Invoke-CfRequest, addon-sync.ps1:644;
    Invoke-WagoRequest, addon-sync.ps1:901) is untouched by this design and
    has no path to ever receive $GithubToken as a parameter.
  - In logs: sync.log (CLI, via Write-Log) and server.log (server, via
    Write-ServerLog) - covered by the Get-RedactedLogText choke point
    (4.4), AND by the discipline that no message string this design writes
    ever interpolates the raw token (every message in 3.5/3.6/3.7/4
    references $Record.repo, $displayLabel, or fixed text - never
    $GithubToken/$body.githubToken/$settings.githubToken).
  - In state/API responses: state.json never carries settings at all (it
    is the addon-state cache, a wholly separate file); GET /api/settings
    exposes only hasGithubToken/githubTokenHint (4.2); GET /api/state
    never touches settings.json's githubToken (Handle-State reads addon
    records, not settings); job objects (GET /api/jobs/<id>, jobs\<id>.json
    on disk) never carry the token because it is never placed on the CLI
    child process's command line or in Params at all (3.9) - the CLI reads
    it directly from settings.json in its own process.
  - In tests: FURPHY_TEST_GITHUB_BASEURL points BOTH the CLI's and the
    server's GitHub calls at a local stub for the life of one test process
    - no test ever sets a real token, and every test fixture token is an
    obviously-fake literal like "github_pat_TESTONLY_0000" (matching the
    existing "obviously fake" convention this build's own hard rules
    already require).

6.2 Redaction

Get-RedactedLogText (4.4, duplicated once in each of addon-server.ps1 and
addon-sync.ps1, since the two files share no dependency) is the ONE piece
of active defense - a regex scrub at the two Write-*Log choke points,
catching `github_pat_...` and `gh[pousr]_...` shaped substrings in ANY
message, regardless of how they got there. This is explicitly
DEFENSE-IN-DEPTH, not the primary control - the primary control is that no
code path in this entire design ever builds a message string containing
the raw token in the first place (verified per call site across sections
3/4 above). A future contributor who adds a new GitHub-touching log line
and accidentally interpolates the raw token still gets caught by the
regex before it reaches disk.

6.3 What the stub must exercise

The extended stub (7.2) must let a test PROVE every claim in 6.1 - not
just that the feature works, but that the token specifically never leaks
to the wrong place. Concretely, the stub's own `/__control/requests` log
(already present, GitHubReleaseStubServer.ps1:36-40/136-154) must be
extended to also record whether Authorization was present and, when the
manifest's -RequireToken is set, whether it matched the expected value -
so a test can assert "the release lookup carried Authorization: Bearer
<the exact test token>" (positive proof the token reaches api.github.com)
and, separately, a filesystem/regex assertion over server.log/sync.log
after a run can assert "the literal test token string never appears
anywhere in this file" (positive proof of 6.2). Both assertions are
required together - one proves delivery, the other proves non-leakage;
neither alone is sufficient.

REVIEW FOLD-IN, finding B/2 (redirect non-leakage): the stub's own
`/__control/requests` log already records a generic `hasAuthorization`
field per entry, across every route including the new zipball one (7.2) -
this is enough, AS LONG AS a test actually reads it for the zipball
request specifically. Github.AssetVsZipball.Tests.ps1 (7.3) must assert
`hasAuthorization` is true for the ORIGINAL request to
/repos/.../zipball/<tag> (proving the token reached api.github.com's own
zipball endpoint) - this stub is a single-process HttpListener with no
real cross-host redirect to observe, so it cannot directly reproduce 3.5's
empirical claim about what happens AFTER a redirect; that claim is instead
verified once, structurally, against Invoke-HttpDownloadWithProgress
itself (3.5's own footnote) rather than re-derived per test run. What the
integration test CAN and must still prove end-to-end is 6.2's actual
guarantee regardless of mechanism: the fixture token string never appears
in server.log/sync.log/job files/API responses after a full add-and-update
run through the zipball path specifically (folding this zipball case into
Github.PrivateRepoNeedsToken.Tests.ps1's or
Github.TokenNeverInStateOrSettings.Tests.ps1's existing 5-way leak check,
7.3, rather than inventing a 6th assertion site).

REVIEW FOLD-IN, finding E/6 (screenshot hygiene, process note, no code):
this repo already has doc-screenshot tooling (shots\*, crop-zoom.ps1) -
any screenshot of the new Settings > GitHub addons card (5.1) must be
taken with the token field EMPTY or the show/hide toggle left at its
default (hidden) state. A captured screenshot with "show" left on on a PC
with a real token pasted in would be a genuine leak path outside every
control this section otherwise covers (logs, API responses, tests) -
purely a doc-authoring/support-screenshot discipline, not a code change,
but worth stating here since nothing else in this design would catch it.

=====================================================================
7. Tests
=====================================================================

7.1 Unit

New test files (each a standalone Pester file under tests\unit\, following
this repo's existing one-concern-per-file convention):

  - CLI.GithubUrlParse.Tests.ps1 - dot-sources addon-sync.ps1 (past its
    dot-source guard, addon-sync.ps1:4322 on, per TESTING.md hook #1) and
    exercises ConvertTo-TargetToken directly against every accepted form
    from 3.1 (bare owner/repo, github:owner/repo, github.com/owner/repo
    with/without scheme/www/.git/trailing slash/subpath) plus rejection
    cases (a bare number still parses as CurseForge, not GitHub; a
    malformed owner like "-bad" or a 101-char repo name throws the same
    "-$ParamName value ... is not a valid ..." shape the existing wago
    rejection already throws, extended to mention the github: form too;
    REVIEW FOLD-IN, finding A/1 - "owner/.." and "owner/." in EACH of the
    three accepted forms (bare, github:, github.com/) MUST throw the new
    $repoTraversalPattern message from 3.1, never silently parse into a
    GithubRepo value).
  - CLI.GithubFolderSafety.Tests.ps1 (REVIEW FOLD-IN, finding A/1, new
    test file) - exercises ConvertTo-NormalizedGithubZip's own defense-in-
    depth guard (3.6.3) directly by calling it with -RepoName values of
    "..", ".", "", "sub/dir" and asserting each throws BEFORE any
    filesystem operation runs (assert via a $StagingPath that is a
    read-only/nonexistent directory - the throw must happen on the guard,
    not on a later Join-Path/Move-Item failure that would look similar);
    a normal -RepoName like "AuraUpdater" still proceeds normally
    (regression guard against the new check being too strict).
  - CLI.GithubAssetSelect.Tests.ps1 - exercises the asset-selection rule
    (3.6.1) against hand-built release-JSON fixtures: one .zip asset (that
    one wins); several .zip assets, one matching the repo name (that one
    wins over an earlier-listed non-matching one - proves "prefer" is not
    just "first"); zero .zip assets but a zipball_url present (zipball
    path chosen, assetName recorded as "zipball"); zero .zip assets AND no
    zipball_url (Skipped, not Failed - matches 3.6.2's exact branch).
  - CLI.GithubZipballNormalize.Tests.ps1 - exercises
    ConvertTo-NormalizedGithubZip (3.6.3) against two hand-built zipball
    fixtures: one where the wrapper directory holds ONE subfolder with a
    .toc (normal case - output zip's top-level entry is that subfolder,
    unchanged name); one where the wrapper directory's OWN root holds the
    .toc directly with no subfolder (root-.toc case - output zip's single
    top-level entry is renamed to the repo name, per decision 1's own
    parenthetical). Asserts the OUTPUT zip, fed straight into the real
    unmodified Install-AddonPackage, produces exactly the expected folder
    name(s) - proving 3.6.3's claim that Install-AddonPackage itself needs
    no changes.
  - CLI.GithubAdoptFolderTocLooksLikeTag.Tests.ps1 - exercises the "looks
    like a tag" regex from 3.7 directly against real values: "v454" and
    "164" (Eric's own two real .toc Version values - MUST both match),
    plus rejection cases ("", "dev build", "2026-09-01", "Season 2").
  - CLI.GithubFolderClaimGuard.Tests.ps1 (REVIEW FOLD-IN, finding C/3.3a,
    new test file) - builds a small in-memory $config with a CurseForge
    record already owning folder "Bagnon" (mirroring the mock fixture,
    ui\app.js:415) and a not-yet-installed GitHub record whose repo name
    is also "Bagnon"; builds $claimedFolders per 3.3a's own recipe and
    calls Sync-SingleGithubAddon's adopt-in-place step directly against a
    real on-disk "Bagnon" folder with a .toc in it - asserts Status
    'Failed' (never 'Adopted'), the GitHub record's installedTag stays
    $null, and the on-disk "Bagnon" folder's content is byte-for-byte
    unchanged afterward (proving no takeover happened). A second case with
    NO existing claim on that folder name asserts the SAME adopt succeeds
    normally - regression guard against the new check being too strict.
  - CLI.GithubRateLimitBackoff.Tests.ps1 (REVIEW FOLD-IN, finding D/3.4a,
    new test file) - exercises Get-GithubRateLimitBackoffUntil directly
    against hand-built exception/header shapes: a Retry-After of "120"
    seconds yields a timestamp ~120s in the future; an X-RateLimit-Reset
    unix-epoch header with no Retry-After yields a timestamp matching that
    epoch; neither header present falls back to the documented default;
    a huge Retry-After (say 999999) is capped at 6 hours; a tiny/zero one
    is floored at 60 seconds - same boundary values
    Invoke-AppUpdateMaintenanceCore's own precedent already exercises for
    the self-update path, applied here to the new shared helper.
  - Server.GithubTokenRedaction.Tests.ps1 - exercises Get-RedactedLogText
    (both copies) against strings containing a fake github_pat_/ghp_
    token embedded mid-sentence, asserting the token substring is gone
    from the output and a surrounding sentence is preserved unmangled;
    also a plain string with no token passes through byte-for-byte
    unchanged (no over-eager mangling of ordinary log lines). REVIEW
    FOLD-IN, finding E/5: MUST include the project's own mandated fixture
    literal "github_pat_TESTONLY_0000" as one of the embedded-token cases
    (its 13-character suffix clears the revised {8,} floor - this is the
    test that would have caught the original {20,} floor's gap against
    the project's own canonical fake-token shape).
  - Server.GithubSettingsView.Tests.ps1 - Get-DefaultSettings/Get-Settings/
    Get-SettingsView/Handle-SettingsPut round-trip: PUT a token, assert GET
    returns hasGithubToken=true and githubTokenHint equal to its last 4
    chars and NEVER the raw value anywhere in the response body text; PUT
    an empty string, assert it clears (hasGithubToken=false,
    githubTokenHint=null) and a FOLLOW-UP GET still shows cleared; PUT
    omitting githubToken entirely leaves a previously-set token untouched.

7.2 Integration - extending the GitHub release stub

tests\fixtures\github-release-stub\GitHubReleaseStubServer.ps1 (currently
hardwired to the one pinned self-update repo path, lines 17/156) needs
generalizing WITHOUT breaking any existing App-Update test that already
depends on its current fixed-repo behavior:

  - New manifest fields (all optional, all defaulting to today's exact
    behavior when omitted): `owner`/`repoName` (default 'krenz444'/
    'furphy-addon-manager' - the existing pinned path, so every existing
    caller that never sets these gets byte-identical routing);
    `requireToken` (bool, default $false); `expectedToken` (string,
    default $null); `zipballAvailable` (bool, default $false, since the
    existing self-update fixture never used one); `zipballShaSuffix` (a
    short fake sha to embed in the synthesized wrapper directory name).
  - Route generalized from the literal
    '/repos/krenz444/furphy-addon-manager/releases/latest' to
    "/repos/$($manifest.owner)/$($manifest.repoName)/releases/latest" -
    since the default owner/repoName reproduce the old literal exactly,
    every existing test that never sets -Owner/-Repo is unaffected.
  - Token gate, checked ONLY when manifest.requireToken is true, applied
    to the releases/latest route, the asset-by-id route, AND a new
    zipball route (all three, since a private repo's assets/zipball need
    the same auth as its release metadata does on the real API):
      - No Authorization header at all -> 404 (never 403 - matches real
        GitHub private-repo behavior, and is exactly what 3.5's own "404
        is never retried" contract depends on being told apart from a
        429/403 rate-limit response).
      - Authorization present but its Bearer value != manifest.expectedToken
        -> 404 (same status, same body shape - GitHub does not
        distinguish "wrong token" from "no token" from "does not exist";
        neither does this stub).
      - Authorization present and matching -> normal 200 response.
  - New route, added alongside the existing /repos/.../releases/latest and
    /download/<name>: `/repos/<owner>/<repo>/zipball/<tag>` - served only
    when manifest.zipballAvailable is true, subject to the SAME token gate
    as above; returns a synthesized zip whose single top-level entry is a
    directory named "<owner>-<repo>-<zipballShaSuffix>", built by a new
    helper New-GitHubZipballFixtureZip (tests\lib\common.ps1, mirroring
    New-GitHubReleaseFixtureZip's own existing shape) with either a
    subfolder-with-.toc layout or a root-.toc layout (a `-ZipballRootToc`
    switch selects which, so both of 7.1's zipball-normalization scenarios
    have a real, network-shaped fixture to exercise end-to-end too, not
    just the unit test's hand-built zips).
  - The release JSON body (Get-ReleaseJsonBody, GitHubReleaseStubServer.ps1:
    111-124) gains `zipball_url` (pointing at the new route above) only
    when manifest.zipballAvailable is true - omitted entirely otherwise, so
    every existing test's release JSON shape is unchanged when it never
    opts in.
  - The `/__control/requests` log (GitHubReleaseStubServer.ps1:136-154)
    gains two fields per entry: `hasAuthorization` (bool) and, only when
    manifest.requireToken is true, `authorizationMatched` (bool) - lets a
    test assert both "the request carried Authorization" (delivery, 6.3)
    and, separately, that server.log/sync.log text-search finds no trace
    of the literal fixture token value anywhere (non-leakage, 6.3).

Start-GitHubReleaseStubServer (tests\lib\common.ps1:771-906) gains
matching new parameters (-Owner, -RepoName, -RequireToken, -ExpectedToken,
-ZipballAvailable, -ZipballRootToc), all optional with the same
today-unchanged defaults, threaded into the manifest object it writes
(tests\lib\common.ps1:863-872) and into the returned descriptor object
(adding `Owner`/`RepoName` alongside the existing `TagName`/`ZipPath`
etc.) so a caller building the addon-sync.ps1 side of a test never
hand-builds a repo string that could drift from what the stub actually
serves.

7.3 Integration scenarios against the extended stub

New Pester files under tests\integration\ (or wherever this repo's
existing CF/Wago end-to-end tests already live - mirror that location):

  - Github.PublicRepoAddAndUpdate.Tests.ps1 - Copy-Fixture WoW root +
    Copy-FurphyAppFiles app root (per this build's own scratch-server
    convention), stub with requireToken=$false, add "owner/repo" via the
    CLI's own -Add, assert the folder lands with a .toc, installedTag set
    to the stub's TagName; bump the stub's tag, re-check, assert
    Would-update/Updated with the new tag; assert backups\github-owner_repo\
    <oldtag>.zip exists after the update and a -Rollback restores it with
    NO network call (assert via the stub's own request log staying at the
    same count across the rollback).
  - Github.PrivateRepoNeedsToken.Tests.ps1 - stub with requireToken=$true;
    with NO githubToken in the test's settings.json, assert the resulting
    job/record shows FailPhase 'checking-needs-token' and sync.log contains
    the exact 3.5 log line (repo name and all) - and does NOT contain any
    substring of a token (there isn't one configured, but this also guards
    against a future regression that starts interpolating something token-
    shaped by accident); then write a WRONG token, assert the SAME
    FailPhase/message (proving GitHub's 404-either-way is handled
    uniformly, 3.5); then write the CORRECT (obviously-fake,
    "github_pat_TESTONLY_0000"-shaped) token, assert success, AND assert
    that exact fixture token string appears NOWHERE in server.log, sync.log,
    the job's .out/.err files, GET /api/state's raw response body, or GET
    /api/settings's raw response body (5 separate greps/asserts - this is
    the single most important test in this whole feature).
  - Github.AssetVsZipball.Tests.ps1 - one scenario with a proper .zip asset
    (assetName recorded as that asset's real name); one with zipballAvailable
    and no .zip asset at all, `-ZipballRootToc` OFF (subfolder case) and ON
    (root-toc case) as two sub-cases - assert the installed folder name in
    each (repo-name-derived only in the root-toc case, per 3.6.3).
  - Github.AdoptInPlace.Tests.ps1 - Copy-Fixture a WoW root that ALREADY has
    a folder named exactly the repo's own name, containing a .toc with
    "## Version: v454" (mirrors Eric's real TimelineReminders.toc exactly);
    -Add the repo with NO stub server running at all reachable for the
    release lookup (or a stub configured to fail every request) - assert
    the add still succeeds (Adopted), installedTag becomes "v454", and the
    stub's own request log (when a stub IS running) stays at zero requests
    for this repo - proving 3.7's "no download" claim directly, not just by
    absence of an error.
  - Github.TokenNeverInStateOrSettings.Tests.ps1 - with a real token
    configured, hit GET /api/state and GET /api/settings directly (raw
    HTTP, not through any UI) and assert neither response body contains
    the token substring anywhere - the direct-API counterpart to the last
    assertion in Github.PrivateRepoNeedsToken.Tests.ps1, kept as its own
    file since it needs no job/sync activity at all to prove, just the two
    GETs.

Every one of these runs on a scratch server on ports 47950-47969 against a
Copy-Fixture WoW root and Copy-FurphyAppFiles app root, per this build's
existing hard rules - never the real WoW install, never a real token
(every fixture token used across every test above is the literal
"github_pat_TESTONLY_0000" or an equally obvious fake), and
FURPHY_TEST_GITHUB_BASEURL points at the extended stub for the life of
each test process, exactly as it already does for the existing App-Update
tests.

7.4 SPA harness checks

New checks added to tests\spa\ (wherever the existing headless-Edge
harness's own Settings/drawer checks live - tests\spa\harness.js per the
work-package split in section 9):

  - The GitHub addons card renders with the exact tooltip/intro text from
    5.1, the token input starts type=password, and the show/hide button
    toggles its type attribute and aria-pressed.
  - Typing into #github-token-input and clicking Save calls PUT
    /api/settings with body.githubToken equal to exactly what was typed
    (asserted against the mock/intercepted request, never against any
    real network call - this harness never touches a real server per its
    own existing convention).
  - Clicking Remove (only visible when mockSettings.hasGithubToken is
    true) PUTs {githubToken: ""} exactly.
  - Pasting each of the accepted forms from 5.3 into #github-add-input
    (and separately into the dialog's #github-add-dialog-input) and
    clicking Add posts {kind:"add", source:"github", repo:"owner/repo"}
    with the SAME normalized "owner/repo" string for every input form
    (proving parseGithubRepoInput's forms all converge) - and that a
    garbage input (including, per REVIEW FOLD-IN finding A/1,
    "github.com/someuser/.." and "someuser/..") shows the exact 5.3 error
    text inline, with NO job posted.
  - The mock GitHub addon entry (5.8) renders a "GitHub" source badge with
    class is-github, and its drawer's Versions tab shows exactly the
    minimal Installed/Latest rows from 5.7 with no console error and no
    attempt to fetch /api/addons/.../files (the CF/Wago-only endpoint
    renderVersions() otherwise calls) - proving the d.source === "github"
    branch short-circuits before that fetch, not just that it renders
    something.
  - REVIEW FOLD-IN, finding I/10 (the deeper fix in 5.7): open the mock
    GitHub addon's drawer via the SAME click path a player would use (the
    My Addons row's "View"/kebab-menu click that calls Components.Drawer.
    open, not a direct renderGithubVersions() call) and assert THREE
    things together, since any one alone would have missed the original
    bug: (1) Store.state.drawer.tracked is true (not false - the
    addonByProjectId regression this section's fix targets), (2)
    Store.state.drawer.source is exactly "github" (not "cf-keyless"), and
    (3) no request to the CurseForge-keyless-enrichment endpoint
    (loadEnrich's own network call) fires for this addon. Then, with the
    drawer already open, switching to the Versions tab shows the
    Installed "v454" / Latest "v455" / Update-button rows from 5.7 -
    this ordering (open via the real path, THEN check the tab) is what
    actually exercises the addonKey -> addonByProjectId -> Drawer.open ->
    renderVersions chain end to end, rather than only the last link.

=====================================================================
8. Docs per file
=====================================================================

  - README.md / README.txt: one new short paragraph under whatever section
    already introduces CurseForge/Wago as sources, naming GitHub as a
    third one and pointing at Settings > GitHub addons - no deep-dive,
    same depth as this pair's existing Wago mention.
  - SPEC.md: a new numbered section (following this file's own existing
    per-source sections' numbering pattern - find the Wago source's own
    section number and insert GitHub's immediately after it, renumbering
    nothing before it) covering the record schema (2), the CLI dispatch
    (3.2/3.3), and the server job-shape (4.5/4.6) - this is the CANONICAL
    cross-reference; GITHUB-SOURCE-SPEC.md (this file) is the design
    rationale, SPEC.md is the terse "what is true" reference the way it
    already is for every other feature.
  - SETTINGS-SPEC.md: a new subsection under wherever the settings-field
    table already lists releaseType/port/adFilter/etc., adding
    githubToken with its default/migration/view/PUT-clearing contract
    (4.1-4.3) in this doc's own existing table format.
  - UX-SPEC.md: a new subsection alongside wherever CS2's failPhase table
    (the source for ui\app.js:4407-4434's own doc comment) already lists
    checking/checking-network/downloading/installing, adding
    checking-needs-token/checking-network-github with their exact bucket
    text (5.6) - and a short note under wherever Settings' card layout is
    catalogued, describing the GitHub addons card (5.1).
  - CHANGELOG.md: new entry at the TOP (newest-first, per this file's own
    established convention - Round 46/1.26.0 currently leads,
    CHANGELOG.md:3) - "## Round 47 (1.27.0: guild addons on GitHub update
    like everything else)" with the same terse bullet-list style every
    other Round entry already uses, covering the four work packages'
    user-visible surface (GitHub addons card, add-from-link, source badge,
    the two guild addons Eric can now add himself).
  - VERSION: "1.26.0" (6 bytes, no trailing newline) becomes "1.27.0" (6
    bytes, no trailing newline) - exact same format, just the three
    changed characters.

=====================================================================
9. Work packages - disjoint files
=====================================================================

  A. CLI - addon-sync.ps1 only.
     Sections 2.1-2.4 (record schema/constructor/backfill), 3 in full
     (URL parsing, Sync-SingleGithubAddon, Invoke-GithubRequest, asset
     selection, zipball normalization, adopt-in-place, settings read,
     3.3a's folder-ownership guard, 3.4a's rate-limit persistence), PLUS
     (REVIEW FOLD-IN, finding H/9 - moved here from where they were
     originally described, under section 4's "Server" heading, purely
     because they are addon-sync.ps1 edits and section 9's split is by
     FILE, not by which numbered section happens to describe something):
       - 4.4's two addon-sync.ps1-only paragraphs: the CLI's OWN duplicated
         copy of Get-RedactedLogText, and the Write-Log edit to call it.
       - 4.7's addon-sync.ps1-only paragraph: the -Json result-row shape's
         new `repo` field and the 17 `Repo =` call-site additions (the
         exact line list is in 4.7 itself).
     Touches ONLY addon-sync.ps1. (4.4's OTHER paragraphs - the function
     itself as conceptually shared prose, Write-ServerLog's edit, the
     Send-Json defense-in-depth note - and 4.7's Get-UpdateAvailableKeyFor
     Record/Row helpers stay Package B's, unchanged from the original
     split; only the two addon-sync.ps1-touching paragraphs moved.)

  B. Server - addon-server.ps1 only.
     Section 4 EXCEPT the two addon-sync.ps1-only paragraphs called out
     above and now owned by Package A (settings key/view/PUT/redaction on
     the SERVER side, job request shape, the two lookup-key helpers,
     $Script:Version bump to 1.27.0). Touches ONLY addon-server.ps1.
     Depends on package A only for the AGREED record-field names/JSON
     shape (2.1/2.5) and the AGREED job Params shape (4.5/4.6) - no shared
     code, no shared file. (REVIEW FOLD-IN, finding H/9: this is the fix -
     the original split assigned "Section 4 in full... Touches ONLY
     addon-server.ps1" to this package while section 4 itself contained
     two addon-sync.ps1-only paragraphs under that same heading. Whoever
     built B under the literal "Touches ONLY addon-server.ps1" instruction
     had no mandate to write those two paragraphs, and whoever built A
     under "Touches ONLY addon-sync.ps1" was never told section 4 held
     anything for them to read - the CLI-side redaction control and the
     repo field on every CLI result row could each have silently never
     shipped. Fixed by moving the two paragraphs into A's list above,
     rather than by re-splitting section 4's own numbering.)

  C. SPA - ui\app.js, ui\index.html, ui\style.css, tests\spa\harness.js.
     Section 5 in full (Settings card, add flow/dialog, badge,
     failureReason buckets, Versions tab, mock fixtures) plus 7.4 (harness
     checks, since the harness is SPA-shaped test code that exercises only
     ui\ files and never starts a real server). Depends on packages A/B
     only for the AGREED field names (2.1) and the AGREED
     hasGithubToken/githubTokenHint/FailPhase-string contract (4.2/5.6) -
     no shared code, no shared file.

  D. Tests + docs - everything under tests\ EXCEPT tests\spa\harness.js
     (owned by C), plus tests\fixtures\github-release-stub\, plus
     README.md, README.txt, SPEC.md, SETTINGS-SPEC.md, UX-SPEC.md,
     CHANGELOG.md, VERSION.
     Section 7.1-7.3 (unit tests, the stub extension, integration
     scenarios) plus section 8 in full. Depends on packages A/B/C's
     AGREED contracts (this spec) for what to assert against, but touches
     none of their files - every test file this package writes is NEW,
     and every doc edit is additive prose in files packages A/B/C never
     touch.

No two packages write the same file. Package boundaries were chosen so
each can be implemented, reviewed, and landed independently once this
spec's field names/JSON shapes/error strings (sections 2-6) are treated as
FIXED across all four - a change to any of those after work starts must be
re-broadcast to every package, not patched locally in one.

=====================================================================
10. Review fold-in log (2026-09-09)
=====================================================================

A security/completeness review (9 lettered sections, A-I, covering 11
numbered findings - two sections, E and I, each covered two numbered
findings) was folded into this spec after re-reading the cited code
directly (addon-sync.ps1, addon-server.ps1, ui\app.js) and, for two
findings, running small empirical PowerShell tests against this exact
build to verify the actual runtime behavior rather than trust either the
review's or the original spec's prose. Every finding below was at least
partially valid; none were rejected outright, but two needed a CORRECTED
mechanism before folding - see 10.2. Referenced below as "letter/number"
(e.g. "E/5") matching the review's own section-letter/finding-number pairs.

10.1 Findings folded, with where

  A (1, path traversal via "owner/.."/"owner/.") - CONFIRMED and fixed at
    FOUR layers: the shared $repoTraversalPattern guard added to
    ConvertTo-TargetToken (3.1), the identical guard in Handle-JobsPost
    (4.5) and parseGithubRepoInput (5.3), PLUS a defense-in-depth guard at
    the two places a repo-derived string still becomes a filesystem path
    segment (ConvertTo-NormalizedGithubZip, 3.6.3; the adopt-in-place
    fast path, 3.7) in case $Record.repo is ever set through a future path
    that skips all three validators. New test coverage: 7.1's
    CLI.GithubUrlParse.Tests.ps1 (extended) and new
    CLI.GithubFolderSafety.Tests.ps1; 7.4's garbage-input SPA check
    (extended).
  B (2, redirect/codeload host safety) - CONFIRMED the documentation gap
    (codeload.github.com was never named) but the PROPOSED FIX (a runtime
    host-allowlist check around the redirect) turned out to be unnecessary
    - see 10.2 for why. Folded as a corrected 3.5/6.1 threat-model
    rewrite plus a 6.3/7.3 test requirement that actually proves the
    revised, verified claim.
  C (3, folder-ownership collision) - CONFIRMED by reading Round 45's own
    -Adopt guard (addon-sync.ps1 ~5013-5050) and confirming
    Sync-SingleGithubAddon (3.3/3.7) had no equivalent. Folded as new
    section 3.3a (the $ClaimedFolders map, threaded via 3.2/3.3, consulted
    in both the adopt-in-place step and the pre-install step). New test:
    CLI.GithubFolderClaimGuard.Tests.ps1 (7.1).
  D (4, no cross-run rate-limit backoff) - CONFIRMED by comparing against
    Invoke-AppUpdateMaintenanceCore's own persisted $state.rateLimitedUntil
    (addon-server.ps1:9586-9612). Folded as a fourth record field
    (githubRateLimitedUntil, 2.1/2.3/2.4/2.5) and new section 3.4a,
    consulted/set/cleared at three specific points in 3.3/3.5. New test:
    CLI.GithubRateLimitBackoff.Tests.ps1 (7.1).
  E (5, redaction regex floor vs. mandated fixture literal) - CONFIRMED by
    counting characters ("TESTONLY_0000" is 13, under the original {20,}
    floor). Folded as a floor change to {8,} in 4.4, plus a note requiring
    Server.GithubTokenRedaction.Tests.ps1 (7.1) to actually use the
    project's own mandated literal.
  F (7, asset-selection determinism) - CONFIRMED the observation but it
    was already correctly low-severity; folded as a one-paragraph
    clarifying note in 3.6.1 (deterministic first-match, not random -
    nothing to fix in behavior).
  G (8, phase-transition documentation gap) - CONFIRMED steps 6-9 of 3.3's
    outline never explicitly stated $currentPhase transitions the way
    step 3 does. Folded as explicit statements added to steps 6, 7, and 8
    (step 9 already referenced 'installing' but nothing upstream set it
    until now).
  H (9, package-split drops CLI-side requirements) - CONFIRMED exactly:
    re-grepped WagoSlug in the live build and got the identical 17-line
    list the review named. This is the highest-severity confirmed finding
    after A - folded by moving 4.4's CLI-redaction paragraphs and 4.7's
    repo-field/17-call-site paragraph into Package A's file list in
    section 9 (with explicit *** FILE OWNERSHIP *** callouts left at each
    paragraph's original location in section 4, so a reader following
    section 4 top-to-bottom still sees the redirect), rather than
    renumbering section 4 itself.
  E (6, screenshot hygiene) - accepted as a valid process note; folded as
    one short paragraph in 6.3. No code implication.
  I (10, Versions tab non-functional for GitHub addons) - CONFIRMED, and
    WORSE than described: the review's own fix (patching addonKey only)
    would not have worked, because addonByProjectId - the reverse lookup
    renderGithubVersions and Components.Drawer.open BOTH depend on - has
    no github: branch either, and Drawer.open's OWN tracked/source
    derivation (never mentioned in the review or the original spec at
    all) breaks for every drawer tab, not just Versions. Folded as a full
    rewrite of 5.7 fixing addonByProjectId AND Drawer.open, plus a
    corrected, deeper 7.4 harness check that opens the drawer via the real
    click path instead of calling renderGithubVersions directly.
  I (11, GitHubBaseUrl/GithubBaseUrl casing) - CONFIRMED by grepping both
    files (server: $Script:GitHubBaseUrl, addon-server.ps1:138/140; the
    CLI's own proposed seam in 3.4 originally spelled it
    $script:GithubBaseUrl). No functional collision either way (separate
    script-scoped processes), but folded as a one-line rename in 3.4
    (and every place 3.3's outline referenced the same variable) purely
    for grep-consistency between the two files, plus an explanatory
    comment at the definition site.

10.2 Two corrected mechanisms (not rejections - the underlying findings
     were real; the specific technical claim quoted from the review, or
     its proposed code fix, did not hold up against the actual code and
     was replaced rather than folded as written)

  On finding A (1)'s exact causal chain: the review's own narrative traces
  section 3.7's adopt-in-place path (via $candidatePath) DIRECTLY into
  Install-AddonPackage's "Remove-Item -Recurse -Force on Interface itself."
  Re-reading 3.7 as specced shows the adopt-in-place path never calls
  Install-AddonPackage at all - it returns immediately on a hit, with no
  zip and no install step. The review conflated two independent code
  paths (3.7's local Test-Path/Get-FolderTocInfo read, and 3.6.3's
  zip-normalize step, which DOES eventually reach Install-AddonPackage but
  through $RepoName, a different variable, in a different function). The
  underlying defect - an unsanitized repo-derived path segment reaching
  Join-Path/Move-Item/Test-Path with no guard - is real and was fixed
  comprehensively (10.1's finding A), including empirically confirming
  (via two isolated PowerShell tests against this exact build) that
  Join-Path itself does not resolve ".."/"." but Test-Path/Move-Item DO
  resolve them at the point of use, and tracing the ACTUAL consequence for
  each of the two real code paths (3.7: a leaked/unsafe candidatePath that
  never reaches Install-AddonPackage in the same call, but WOULD become
  dangerous on a LATER sync if it were ever allowed to set
  $Record.folders = @(".."); 3.6.3: a silently orphaned staging directory
  and a clean "no valid addon folders" failure, not a deletion, given the
  wrapperHasOwnToc branch's exact Move-Item destination semantics). The
  fix (reject the input at four layers, 10.1's finding A) makes the exact
  mechanics moot either way, which is why it was worth re-deriving
  correctly rather than copying the review's own chain into the spec.

  On finding B (2)'s proposed remediation: the review recommended adding
  runtime verification (e.g. checking $response.ResponseUri.Host against
  an allowlist) "before resending the Bearer token" on a redirect, framing
  the current design as relying on trust rather than verification. Two
  isolated-HttpListener PowerShell tests against this exact build's
  .NET/PowerShell 5.1 runtime showed AllowAutoRedirect's default behavior
  already does not resend a Headers.Add-added Authorization header across
  a cross-host redirect - there is no token-forwarding event for a host
  check to guard, so the proposed code would be dead defense against
  something that structurally cannot happen via this call path. The
  actually-valid parts of the finding (codeload.github.com was
  undocumented; the mechanism as originally WRITTEN in this spec was
  factually backwards about which function is used and what it does) were
  folded as a corrected 3.5/6.1 rewrite instead, plus a test requirement
  that proves the verified behavior (6.3/7.3) rather than code that
  guards against a non-issue.
