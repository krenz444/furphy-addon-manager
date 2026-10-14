<#
=====================================================================
 tests\unit\Cli.FolderOwnershipAndSwap.Tests.ps1

 Unit tests (Pester 3 syntax) for the Round 48 audit fixes in
 addon-sync.ps1:

   MEDIUM 5  Install-AddonPackage's folder swap is all-or-nothing: the old
             folder is renamed aside, the new one moved in, and everything
             rolls back when any folder fails - no half-deleted folder, no
             mix of new and old folders. Leftovers of a killed swap are
             recovered/swept (Restore-InterruptedFolderSwap) and never
             offered by -Scan.
   HIGH 2    Folder ownership: CurseForge and Wago installs refuse (before
             touching disk) to install over a folder a DIFFERENT tracked
             record owns; a record's stale-folder cleanup and -Remove never
             delete a folder another record still lists.
   MEDIUM 4  GitHub pin: a pinned GitHub record stays on its tag (no
             network call when already there), is fetched by tag when it is
             not, a rollback pins the tag it restores, and -FileId <tag>
             pins through the CLI.

 Everything runs against temp folders; the GitHub cases use the local
 release stub (never github.com). No real WoW folder, no real network.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$Script:AddonSyncPathR48 = Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1'
. $Script:AddonSyncPathR48

function New-R48Zip {
    <# Builds a zip whose entries are the keys of -Entries (relative path inside the zip) with the values as ASCII content. #>
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][hashtable]$Entries)

    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $archive.CreateEntry([string]$name)
                $es = $entry.Open()
                try {
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$Entries[$name])
                    $es.Write($bytes, 0, $bytes.Length)
                } finally { $es.Close() }
            }
        } finally { $archive.Dispose() }
    } finally { $fs.Dispose() }
}

function New-R48Layout {
    <# A scratch {Root; Staging; Addons; Backups} layout under tests\.tmp. #>
    param([string]$Name = 'r48')

    $root = New-TempRoot -Name $Name
    $l = [PSCustomObject]@{
        Root    = $root
        Staging = (Join-Path $root 'staging')
        Addons  = (Join-Path $root 'addons')
        Backups = (Join-Path $root 'backups')
    }
    foreach ($p in @($l.Staging, $l.Addons, $l.Backups)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $l
}

function Set-R48File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-R48Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Get-R48Asides {
    <# Every ".furphy-old-<hex>" folder directly under $AddonsPath. #>
    param([string]$AddonsPath)
    return , @(Get-ChildItem -LiteralPath $AddonsPath -Directory -Force | Where-Object { $_.Name -match '\.furphy-old-' })
}

function Open-R48Lock {
    <# FileShare.Read: readers ok, no deleters/renamers - the shape of a real AV scanner / cloud-sync / Explorer-preview handle. #>
    param([string]$Path)
    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}

function Initialize-R48SyncState {
    <# See Cli.GithubAssetSelect.Tests.ps1's Initialize-GithubDirectCallState for why a direct Sync-Single* call needs this. #>
    $script:ProgressTallies = New-ProgressTallies
}

# ---------------------------------------------------------------------
# MEDIUM 5 - transactional swap
# ---------------------------------------------------------------------

Describe 'Install-AddonPackage - all-or-nothing swap (Round 48, audit MEDIUM 5)' {

    It 'a locked file leaves EVERY file of the old folder in place, including files that sort before the locked one' {
        # The old per-folder Remove-Item -Recurse deleted whatever it could
        # reach before hitting the lock: with A.lua sorting before the
        # locked Z.lua it was gone when the swap failed - a half-deleted
        # addon. A directory rename fails up front instead, touching nothing.
        $l = New-R48Layout -Name 'swap-allfiles'
        $dest = Join-Path $l.Addons 'BigWigs'
        Set-R48File -Path (Join-Path $dest 'A.lua') -Content 'A-OLD'
        Set-R48File -Path (Join-Path $dest 'BigWigs.toc') -Content 'TOC-OLD'
        $locked = Join-Path $dest 'Z.lua'
        Set-R48File -Path $locked -Content 'Z-OLD'
        $zip = Join-Path $l.Root 'new.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'BigWigs/BigWigs.toc' = 'TOC-NEW' }

        $lock = Open-R48Lock -Path $locked
        $threw = $false
        try {
            try {
                Install-AddonPackage -ZipPath $zip -ProjectId 1 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @('BigWigs') | Out-Null
            } catch { $threw = $true }
        } finally {
            $lock.Close()
            $lock.Dispose()
        }

        $threw | Should Be $true
        (Get-R48Text (Join-Path $dest 'A.lua')) | Should Be 'A-OLD'
        (Get-R48Text (Join-Path $dest 'BigWigs.toc')) | Should Be 'TOC-OLD'
        (Get-R48Text $locked) | Should Be 'Z-OLD'
        (Get-R48Asides -AddonsPath $l.Addons).Count | Should Be 0
    }

    It 'when a LATER folder is locked, folders already swapped are rolled back - the addon is never a mix of new and old' {
        # Replaces the pre-Round-48 expectation ("FolderA made forward
        # progress"): a package's folders are versioned together, so a
        # new core next to an old options folder is worse than all-old.
        $l = New-R48Layout -Name 'swap-rollback'
        foreach ($n in @('FolderA', 'FolderB', 'FolderC')) {
            Set-R48File -Path (Join-Path $l.Addons "$n\$n.toc") -Content "$n-OLD"
        }
        $lockedFile = Join-Path $l.Addons 'FolderC\FolderC.toc'
        $zip = Join-Path $l.Root 'three.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'FolderA/FolderA.toc' = 'FolderA-NEW'; 'FolderB/FolderB.toc' = 'FolderB-NEW'; 'FolderC/FolderC.toc' = 'FolderC-NEW' }

        $lock = Open-R48Lock -Path $lockedFile
        $message = $null
        try {
            try {
                Install-AddonPackage -ZipPath $zip -ProjectId 555 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @('FolderA', 'FolderB', 'FolderC') | Out-Null
            } catch { $message = $_.Exception.Message }
        } finally {
            $lock.Close()
            $lock.Dispose()
        }

        ($null -ne $message) | Should Be $true
        ($message -like '*FolderC*') | Should Be $true
        (Get-R48Text (Join-Path $l.Addons 'FolderA\FolderA.toc')) | Should Be 'FolderA-OLD'
        (Get-R48Text (Join-Path $l.Addons 'FolderB\FolderB.toc')) | Should Be 'FolderB-OLD'
        (Get-R48Text $lockedFile) | Should Be 'FolderC-OLD'
        (Get-R48Asides -AddonsPath $l.Addons).Count | Should Be 0
    }

    It 'a failed fresh install removes the folders it had already placed (nothing new is left behind)' {
        $l = New-R48Layout -Name 'swap-fresh-rollback'
        Set-R48File -Path (Join-Path $l.Addons 'Second\Second.toc') -Content 'SECOND-OLD'
        $lockedFile = Join-Path $l.Addons 'Second\Second.toc'
        $zip = Join-Path $l.Root 'two.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'First/First.toc' = 'FIRST-NEW'; 'Second/Second.toc' = 'SECOND-NEW' }

        $lock = Open-R48Lock -Path $lockedFile
        $threw = $false
        try {
            try {
                Install-AddonPackage -ZipPath $zip -ProjectId 556 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @() | Out-Null
            } catch { $threw = $true }
        } finally {
            $lock.Close()
            $lock.Dispose()
        }

        $threw | Should Be $true
        (Test-Path -LiteralPath (Join-Path $l.Addons 'First')) | Should Be $false
        (Get-R48Text $lockedFile) | Should Be 'SECOND-OLD'
    }

    It 'a normal update replaces the folder completely (no stray old files) and leaves no leftover folder' {
        $l = New-R48Layout -Name 'swap-ok'
        Set-R48File -Path (Join-Path $l.Addons 'BigWigs\BigWigs.toc') -Content 'TOC-OLD'
        Set-R48File -Path (Join-Path $l.Addons 'BigWigs\Removed.lua') -Content 'GONE-IN-NEW'
        $zip = Join-Path $l.Root 'ok.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'BigWigs/BigWigs.toc' = 'TOC-NEW'; 'BigWigs/Core.lua' = 'CORE-NEW' }

        $installed = Install-AddonPackage -ZipPath $zip -ProjectId 2 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @('BigWigs')

        $installed.Count | Should Be 1
        $installed[0] | Should Be 'BigWigs'
        (Get-R48Text (Join-Path $l.Addons 'BigWigs\BigWigs.toc')) | Should Be 'TOC-NEW'
        (Get-R48Text (Join-Path $l.Addons 'BigWigs\Core.lua')) | Should Be 'CORE-NEW'
        (Test-Path -LiteralPath (Join-Path $l.Addons 'BigWigs\Removed.lua')) | Should Be $false
        (Get-R48Asides -AddonsPath $l.Addons).Count | Should Be 0
    }

    It 'a stale previous folder is removed, but one another tracked record owns (-ProtectedFolders) is kept' {
        $l = New-R48Layout -Name 'swap-protected'
        Set-R48File -Path (Join-Path $l.Addons 'Main\Main.toc') -Content 'MAIN-OLD'
        Set-R48File -Path (Join-Path $l.Addons 'Gone\Gone.toc') -Content 'GONE'
        Set-R48File -Path (Join-Path $l.Addons 'SharedLib\SharedLib.toc') -Content 'SHARED'
        $zip = Join-Path $l.Root 'main.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'Main/Main.toc' = 'MAIN-NEW' }

        $protected = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$protected.Add('sharedlib')
        Install-AddonPackage -ZipPath $zip -ProjectId 3 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @('Main', 'Gone', 'SharedLib') -ProtectedFolders $protected | Out-Null

        (Get-R48Text (Join-Path $l.Addons 'Main\Main.toc')) | Should Be 'MAIN-NEW'
        (Test-Path -LiteralPath (Join-Path $l.Addons 'Gone')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $l.Addons 'SharedLib\SharedLib.toc')) | Should Be $true
    }

    It 'a transiently locked file is still retried and the swap succeeds (retry-on-lock unchanged)' {
        $l = New-R48Layout -Name 'swap-transient'
        $existing = Join-Path $l.Addons 'BigWigs\BigWigs.toc'
        Set-R48File -Path $existing -Content 'OLD-VERSION'
        $zip = Join-Path $l.Root 'bw.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'BigWigs/BigWigs.toc' = 'NEW-VERSION' }

        $marker = Join-Path $l.Root 'locked.marker'
        $ps = [PowerShell]::Create()
        $ps.AddScript({
            param($Path, $Marker)
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            [System.IO.File]::WriteAllText($Marker, 'locked')
            Start-Sleep -Milliseconds 100
            $fs.Close()
            $fs.Dispose()
        }).AddArgument($existing).AddArgument($marker) | Out-Null
        $handle = $ps.BeginInvoke()
        try {
            $deadline = (Get-Date).AddSeconds(5)
            while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 10 }
            (Test-Path -LiteralPath $marker) | Should Be $true

            $installed = Install-AddonPackage -ZipPath $zip -ProjectId 4 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @('BigWigs')
            $installed.Count | Should Be 1
        } finally {
            $ps.EndInvoke($handle) | Out-Null
            $ps.Dispose()
        }
        (Get-R48Text $existing) | Should Be 'NEW-VERSION'
    }
}

Describe 'Restore-InterruptedFolderSwap / Test-IsSwapAsideName (Round 48)' {

    It 'Test-IsSwapAsideName matches only the "<name>.furphy-old-<8 hex>" shape' {
        (Test-IsSwapAsideName -Name 'BigWigs.furphy-old-0a1b2c3d') | Should Be $true
        (Test-IsSwapAsideName -Name 'BigWigs.furphy-old-0A1B2C3D') | Should Be $true
        (Test-IsSwapAsideName -Name 'BigWigs.furphy-old-0a1b2c3') | Should Be $false
        (Test-IsSwapAsideName -Name 'BigWigs') | Should Be $false
        (Test-IsSwapAsideName -Name '') | Should Be $false
        (Test-IsSwapAsideName -Name $null) | Should Be $false
    }

    It 'when the folder itself is missing, the leftover is put back (it was the only surviving copy)' {
        $l = New-R48Layout -Name 'restore-missing'
        Set-R48File -Path (Join-Path $l.Addons 'Foo.furphy-old-aaaaaaaa\Foo.toc') -Content 'ORIGINAL'

        Restore-InterruptedFolderSwap -AddonsPath $l.Addons -FolderName 'Foo'

        (Get-R48Text (Join-Path $l.Addons 'Foo\Foo.toc')) | Should Be 'ORIGINAL'
        (Get-R48Asides -AddonsPath $l.Addons).Count | Should Be 0
    }

    It 'when the folder exists, leftovers are stale and removed; the folder is untouched' {
        $l = New-R48Layout -Name 'restore-stale'
        Set-R48File -Path (Join-Path $l.Addons 'Foo\Foo.toc') -Content 'CURRENT'
        Set-R48File -Path (Join-Path $l.Addons 'Foo.furphy-old-aaaaaaaa\Foo.toc') -Content 'OLD1'
        Set-R48File -Path (Join-Path $l.Addons 'Foo.furphy-old-bbbbbbbb\Foo.toc') -Content 'OLD2'
        # A different addon's leftover must be left alone.
        Set-R48File -Path (Join-Path $l.Addons 'Bar.furphy-old-cccccccc\Bar.toc') -Content 'OTHER'

        Restore-InterruptedFolderSwap -AddonsPath $l.Addons -FolderName 'Foo'

        (Get-R48Text (Join-Path $l.Addons 'Foo\Foo.toc')) | Should Be 'CURRENT'
        (Test-Path -LiteralPath (Join-Path $l.Addons 'Foo.furphy-old-aaaaaaaa')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $l.Addons 'Foo.furphy-old-bbbbbbbb')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $l.Addons 'Bar.furphy-old-cccccccc')) | Should Be $true
    }

    It 'an install over a folder whose previous swap was killed restores it first and then replaces it cleanly' {
        $l = New-R48Layout -Name 'restore-then-install'
        Set-R48File -Path (Join-Path $l.Addons 'BigWigs.furphy-old-0a1b2c3d\BigWigs.toc') -Content 'ORPHANED-OLD'
        $zip = Join-Path $l.Root 'bw.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'BigWigs/BigWigs.toc' = 'NEW' }

        Install-AddonPackage -ZipPath $zip -ProjectId 5 -StagingPath $l.Staging -AddonsPath $l.Addons -PreviousFolders @('BigWigs') | Out-Null

        (Get-R48Text (Join-Path $l.Addons 'BigWigs\BigWigs.toc')) | Should Be 'NEW'
        (Get-R48Asides -AddonsPath $l.Addons).Count | Should Be 0
    }

    It '-Scan never lists a leftover swap folder as an untracked addon' {
        $wowRoot = Copy-Fixture
        $addons = Join-Path $wowRoot '_retail_\Interface\AddOns'
        Set-R48File -Path (Join-Path $addons 'Ghost.furphy-old-0a1b2c3d\Ghost.toc') -Content '## Interface: 120100'
        $cliPath = Join-Path (New-TempRoot -Name 'r48-scan') 'addon-sync.ps1'
        Copy-Item -LiteralPath $Script:AddonSyncPathR48 -Destination $cliPath -Force

        $r = Invoke-CliJson -ScriptPath $cliPath -ArgumentList @('-Scan', '-Json', '-WowRoot', $wowRoot, '-Flavor', 'retail')

        $r.ExitCode | Should Be 0
        $folders = @($r.Json.untracked | ForEach-Object { $_.folder })
        ($folders -contains 'SingleFlavourAddon') | Should Be $true
        ($folders -contains 'Ghost.furphy-old-0a1b2c3d') | Should Be $false
    }
}

# ---------------------------------------------------------------------
# HIGH 2 - folder ownership
# ---------------------------------------------------------------------

Describe 'Folder ownership helpers (Round 48, audit HIGH 2)' {

    It 'Get-ZipTopLevelFolderNames -TocOnly lists only folders that hold a .toc directly (what Install-AddonPackage installs)' {
        $l = New-R48Layout -Name 'zipnames'
        $zip = Join-Path $l.Root 'mix.zip'
        New-R48Zip -ZipPath $zip -Entries @{
            'Alpha/Alpha.toc'         = 'x'
            'Beta/sub/Nested.toc'     = 'x'
            'Docs/readme.txt'         = 'x'
            'Gamma/Gamma_Mainline.toc' = 'x'
            'loose.txt'               = 'x'
        }
        # The function returns ONE List object (via -NoEnumerate): take its
        # array, then sort - order inside the zip is not part of the contract.
        $all = (Get-ZipTopLevelFolderNames -ZipPath $zip).ToArray() | Sort-Object
        $tocOnly = (Get-ZipTopLevelFolderNames -ZipPath $zip -TocOnly).ToArray() | Sort-Object

        ($all -join ',') | Should Be 'Alpha,Beta,Docs,Gamma'
        ($tocOnly -join ',') | Should Be 'Alpha,Gamma'
    }

    It 'Find-PackageFolderConflicts reports only folders a DIFFERENT record owns, never a record''s own, and never a non-addon folder' {
        $l = New-R48Layout -Name 'conflicts'
        $zip = Join-Path $l.Root 'pkg.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'Alpha/Alpha.toc' = 'x'; 'Beta/Beta.toc' = 'x'; 'Docs/readme.txt' = 'x' }
        $claimed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimed['alpha'] = 'wago:other-addon'
        $claimed['Beta'] = '999'
        $claimed['Docs'] = '123'

        $c = Find-PackageFolderConflicts -ZipPath $zip -OwnFolders @('Beta') -ClaimedFolders $claimed -OwnerIdentity '999'

        $c.Count | Should Be 1
        $c[0].Folder | Should Be 'Alpha'
        $c[0].Owner | Should Be 'wago:other-addon'
    }

    It 'Find-PackageFolderConflicts is empty (never throws) with no claimed map, or an unreadable zip' {
        $l = New-R48Layout -Name 'conflicts-none'
        $zip = Join-Path $l.Root 'pkg.zip'
        New-R48Zip -ZipPath $zip -Entries @{ 'Alpha/Alpha.toc' = 'x' }
        $claimed = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $claimed['Alpha'] = '1'

        (Find-PackageFolderConflicts -ZipPath $zip -OwnFolders @() -ClaimedFolders $null -OwnerIdentity '2').Count | Should Be 0
        (Find-PackageFolderConflicts -ZipPath (Join-Path $l.Root 'missing.zip') -OwnFolders @() -ClaimedFolders $claimed -OwnerIdentity '2').Count | Should Be 0
    }

    It 'Get-FoldersOwnedByOtherRecords unions every other record''s folders (lowercased) and excludes the record itself' {
        $a = [PSCustomObject]@{ name = 'A'; folders = @('A', 'Shared') }
        $b = [PSCustomObject]@{ name = 'B'; folders = @('B', 'shared', 'LibB') }
        $c = [PSCustomObject]@{ name = 'C'; folders = $null }
        $cfg = New-Object 'System.Collections.Generic.List[object]'
        $cfg.Add($a); $cfg.Add($b); $cfg.Add($c)

        $others = Get-FoldersOwnedByOtherRecords -Config $cfg -Record $a

        $others.Contains('b') | Should Be $true
        $others.Contains('libb') | Should Be $true
        $others.Contains('shared') | Should Be $true
        $others.Contains('a') | Should Be $false
    }
}

Describe 'Remove-AddonByTarget - folders another record still lists are kept (Round 48, audit HIGH 2)' {

    It 'removes the record''s own folders but keeps a folder a second record also lists' {
        $l = New-R48Layout -Name 'remove-shared'
        foreach ($n in @('OnlyA', 'Shared', 'OnlyB')) { Set-R48File -Path (Join-Path $l.Addons "$n\$n.toc") -Content $n }
        $a = [PSCustomObject]@{ name = 'Addon A'; source = 'curseforge'; projectId = 101; version = '1'; folders = @('OnlyA', 'Shared') }
        $b = [PSCustomObject]@{ name = 'Addon B'; source = 'wago'; slug = 'addon-b'; projectId = $null; version = '1'; folders = @('OnlyB', 'Shared') }
        $cfg = New-Object 'System.Collections.Generic.List[object]'
        $cfg.Add($a); $cfg.Add($b)

        $r = Remove-AddonByTarget -Target '101' -Config $cfg -AddonsPath $l.Addons

        $r.Status | Should Be 'Removed'
        $r.Removed | Should Be $true
        (Test-Path -LiteralPath (Join-Path $l.Addons 'OnlyA')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $l.Addons 'Shared\Shared.toc')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $l.Addons 'OnlyB\OnlyB.toc')) | Should Be $true
    }

    It 'with no other record listing a folder, every folder of the record is still removed (unchanged)' {
        $l = New-R48Layout -Name 'remove-plain'
        foreach ($n in @('One', 'Two')) { Set-R48File -Path (Join-Path $l.Addons "$n\$n.toc") -Content $n }
        $a = [PSCustomObject]@{ name = 'Addon A'; source = 'curseforge'; projectId = 202; version = '1'; folders = @('One', 'Two') }
        $cfg = New-Object 'System.Collections.Generic.List[object]'
        $cfg.Add($a)

        $r = Remove-AddonByTarget -Target '202' -Config $cfg -AddonsPath $l.Addons

        $r.Removed | Should Be $true
        (Test-Path -LiteralPath (Join-Path $l.Addons 'One')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $l.Addons 'Two')) | Should Be $false
    }
}

Describe 'Sync-SingleAddon / Sync-SingleWagoAddon - refuse to install over another record''s folder (Round 48, audit HIGH 2)' {

    BeforeEach {
        Initialize-R48SyncState
        $script:R48CfFile = [PSCustomObject]@{
            id = 9001; releaseType = 1; gameVersionTypeIds = @(517); gameVersions = @('12.1.0')
            displayName = 'ConflictAddon v2'; fileName = 'ConflictAddon-v2.zip'; fileLength = 0; user = $null; dateCreated = '2026-10-01T00:00:00Z'
        }
        $script:R48WagoRelease = [PSCustomObject]@{
            id = 'r9001'; label = 'v2'; stability = 'stable'; supported_retail_patches = @('12.1.0'); created_at = '2026-10-01T00:00:00Z'
        }
    }

    It 'CurseForge: a package containing a folder another record owns is refused BEFORE any disk change (FailPhase installing-folder-conflict)' {
        $l = New-R48Layout -Name 'cf-conflict'
        Set-R48File -Path (Join-Path $l.Addons 'Shared\Shared.toc') -Content 'OWNED-BY-OTHER'
        $script:R48ZipPath = Join-Path $l.Root 'conflict.zip'
        New-R48Zip -ZipPath $script:R48ZipPath -Entries @{ 'ConflictAddon/ConflictAddon.toc' = 'NEW'; 'Shared/Shared.toc' = 'OVERWRITE-ATTEMPT' }
        Mock Get-CfFiles { return @($script:R48CfFile) }
        Mock Get-DownloadedZip { return $script:R48ZipPath }
        $claimed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimed['Shared'] = 'wago:the-other-addon'
        $rec = New-AddonRecord -ProjectId 555001
        $rec.name = 'ConflictAddon'

        $r = Sync-SingleAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups -Flavor 'retail' -ClaimedFolders $claimed

        $r.Status | Should Be 'Failed'
        $r.FailPhase | Should Be 'installing-folder-conflict'
        (Test-Path -LiteralPath (Join-Path $l.Addons 'ConflictAddon')) | Should Be $false
        (Get-R48Text (Join-Path $l.Addons 'Shared\Shared.toc')) | Should Be 'OWNED-BY-OTHER'
        $rec.fileId | Should BeNullOrEmpty
    }

    It 'CurseForge: the same package installs normally when nobody else owns its folders (control)' {
        $l = New-R48Layout -Name 'cf-noconflict'
        $script:R48ZipPath = Join-Path $l.Root 'ok.zip'
        New-R48Zip -ZipPath $script:R48ZipPath -Entries @{ 'ConflictAddon/ConflictAddon.toc' = "## Interface: 120100`r`n## Title: Conflict Addon`r`n## Version: 2`r`n" }
        Mock Get-CfFiles { return @($script:R48CfFile) }
        Mock Get-DownloadedZip { return $script:R48ZipPath }
        $claimed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimed['SomethingElse'] = '42'
        $rec = New-AddonRecord -ProjectId 555002
        $rec.name = 'ConflictAddon'

        $r = Sync-SingleAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups -Flavor 'retail' -ClaimedFolders $claimed

        $r.Status | Should Be 'Installed'
        (Test-Path -LiteralPath (Join-Path $l.Addons 'ConflictAddon\ConflictAddon.toc')) | Should Be $true
    }

    It 'CurseForge: an UPDATE of a record that already lists the folder is not a conflict (a pre-existing duplicate keeps working)' {
        $l = New-R48Layout -Name 'cf-ownfolder'
        Set-R48File -Path (Join-Path $l.Addons 'ConflictAddon\ConflictAddon.toc') -Content 'OLD'
        $script:R48ZipPath = Join-Path $l.Root 'upd.zip'
        New-R48Zip -ZipPath $script:R48ZipPath -Entries @{ 'ConflictAddon/ConflictAddon.toc' = "## Interface: 120100`r`n## Title: Conflict Addon`r`n## Version: 2`r`n" }
        Mock Get-CfFiles { return @($script:R48CfFile) }
        Mock Get-DownloadedZip { return $script:R48ZipPath }
        $claimed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimed['ConflictAddon'] = '555003'
        $rec = New-AddonRecord -ProjectId 555003
        $rec.name = 'ConflictAddon'
        $rec.fileId = 1
        $rec.folders = @('ConflictAddon')

        $r = Sync-SingleAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups -Flavor 'retail' -ClaimedFolders $claimed

        $r.Status | Should Be 'Updated'
        ((Get-R48Text (Join-Path $l.Addons 'ConflictAddon\ConflictAddon.toc')) -like '*Version: 2*') | Should Be $true
    }

    It 'Wago: the same guard applies (FailPhase installing-folder-conflict, disk untouched)' {
        $l = New-R48Layout -Name 'wago-conflict'
        Set-R48File -Path (Join-Path $l.Addons 'Shared\Shared.toc') -Content 'OWNED-BY-OTHER'
        $script:R48ZipPath = Join-Path $l.Root 'wago.zip'
        New-R48Zip -ZipPath $script:R48ZipPath -Entries @{ 'WagoThing/WagoThing.toc' = 'NEW'; 'Shared/Shared.toc' = 'OVERWRITE-ATTEMPT' }
        Mock Get-WagoAllReleases { return @($script:R48WagoRelease) }
        Mock Get-WagoDownloadedZip { return $script:R48ZipPath }
        $claimed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimed['Shared'] = '2382'
        $rec = New-WagoAddonRecord -Slug 'wago-thing'
        $rec.name = 'WagoThing'

        $r = Sync-SingleAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups -Flavor 'retail' -ClaimedFolders $claimed

        $r.Status | Should Be 'Failed'
        $r.FailPhase | Should Be 'installing-folder-conflict'
        (Test-Path -LiteralPath (Join-Path $l.Addons 'WagoThing')) | Should Be $false
        (Get-R48Text (Join-Path $l.Addons 'Shared\Shared.toc')) | Should Be 'OWNED-BY-OTHER'
    }
}

# ---------------------------------------------------------------------
# MEDIUM 4 - GitHub pin / rollback
# ---------------------------------------------------------------------

Describe 'GitHub pin (Round 48, audit MEDIUM 4)' {

    AfterEach {
        Remove-Item Env:\FURPHY_TEST_GITHUB_BASEURL -ErrorAction SilentlyContinue
    }

    function Get-R48Paths {
        param($Stub)
        return @(Get-GitHubReleaseStubRequests -Stub $Stub | ForEach-Object { $_.path })
    }

    It 'a record already on its pinned tag is "Pinned" with NO network call, even though a newer release exists' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v2.0.0' -Owner 'acme' -RepoName 'PinMe' -ZipEntries @{ 'PinMe/PinMe.toc' = "## Interface: 110000`r`n## Title: PinMe`r`n## Version: v2.0.0`r`n" }
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathR48
            Initialize-R48SyncState
            $l = New-R48Layout -Name 'ghpin-noop'
            $rec = New-GithubAddonRecord -Repo 'acme/PinMe'
            $rec.installedTag = 'v1.0.0'
            $rec.version = 'v1.0.0'
            $rec.folders = @('PinMe')
            $rec.pinnedFileId = 'v1.0.0'

            $r = Sync-SingleGithubAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups

            $r.Status | Should Be 'Pinned'
            $rec.installedTag | Should Be 'v1.0.0'
            (Get-R48Paths -Stub $stub).Count | Should Be 0
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'a pinned record NOT on its tag fetches that tag''s release (releases/tags/<tag>), never "latest", and keeps the pin' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'PinMe' -ZipEntries @{ 'PinMe/PinMe.toc' = "## Interface: 110000`r`n## Title: PinMe`r`n## Version: v1.0.0`r`n" }
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathR48
            Initialize-R48SyncState
            $l = New-R48Layout -Name 'ghpin-fetch'
            $rec = New-GithubAddonRecord -Repo 'acme/PinMe'
            $rec.installedTag = 'v2.0.0'
            $rec.version = 'v2.0.0'
            $rec.folders = @('PinMe')
            $rec.pinnedFileId = 'v1.0.0'

            $r = Sync-SingleGithubAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups

            $r.Status | Should Be 'Updated'
            $rec.installedTag | Should Be 'v1.0.0'
            $rec.pinnedFileId | Should Be 'v1.0.0'
            $paths = Get-R48Paths -Stub $stub
            ($paths -contains '/repos/acme/PinMe/releases/tags/v1.0.0') | Should Be $true
            ($paths -contains '/repos/acme/PinMe/releases/latest') | Should Be $false
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'an UNPINNED record still follows "latest" (control)' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v3.0.0' -Owner 'acme' -RepoName 'FollowMe' -ZipEntries @{ 'FollowMe/FollowMe.toc' = "## Interface: 110000`r`n## Title: FollowMe`r`n## Version: v3.0.0`r`n" }
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathR48
            Initialize-R48SyncState
            $l = New-R48Layout -Name 'ghpin-latest'
            $rec = New-GithubAddonRecord -Repo 'acme/FollowMe'
            $rec.installedTag = 'v2.0.0'
            $rec.version = 'v2.0.0'
            $rec.folders = @('FollowMe')

            $r = Sync-SingleGithubAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups

            $r.Status | Should Be 'Updated'
            $rec.installedTag | Should Be 'v3.0.0'
            ($null -eq $rec.pinnedFileId) | Should Be $true
            ((Get-R48Paths -Stub $stub) -contains '/repos/acme/FollowMe/releases/latest') | Should Be $true
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It '-FileIdOverride (the "Pin current version" / install-this-tag job) pins the installed tag; a tag with no release is Failed, not a crash' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'PinMe' -ZipEntries @{ 'PinMe/PinMe.toc' = "## Interface: 110000`r`n## Title: PinMe`r`n## Version: v1.0.0`r`n" }
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathR48
            Initialize-R48SyncState
            $l = New-R48Layout -Name 'ghpin-override'
            $rec = New-GithubAddonRecord -Repo 'acme/PinMe'
            $rec.installedTag = 'v1.0.0'
            $rec.version = 'v1.0.0'
            $rec.folders = @('PinMe')

            $ok = Sync-SingleGithubAddon -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups -FileIdOverride 'v1.0.0'
            $ok.Status | Should Be 'Pinned'
            $rec.pinnedFileId | Should Be 'v1.0.0'

            $rec2 = New-GithubAddonRecord -Repo 'acme/PinMe'
            $rec2.installedTag = 'v1.0.0'
            $rec2.version = 'v1.0.0'
            $rec2.folders = @('PinMe')
            $bad = Sync-SingleGithubAddon -Record $rec2 -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsPath $l.Backups -FileIdOverride 'v9.9.9'
            $bad.Status | Should Be 'Failed'
            $rec2.installedTag | Should Be 'v1.0.0'
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'a rollback pins the tag it restores, so the next sync does not undo it' {
        $l = New-R48Layout -Name 'ghpin-rollback'
        $rec = New-GithubAddonRecord -Repo 'acme/RollMe'
        $rec.installedTag = 'v2.0.0'
        $rec.version = 'v2.0.0'
        $rec.folders = @('RollMe')
        $rec.previousFileId = 'v1.0.0'
        $rec.previousVersion = 'v1.0.0'
        $key = Get-RecordBackupKey -Record $rec
        $zip = Join-Path (Join-Path $l.Backups $key) 'v1.0.0.zip'
        New-Item -ItemType Directory -Path (Split-Path -Path $zip -Parent) -Force | Out-Null
        New-R48Zip -ZipPath $zip -Entries @{ 'RollMe/RollMe.toc' = "## Interface: 110000`r`n## Title: RollMe`r`n## Version: v1.0.0`r`n" }
        Set-R48File -Path (Join-Path $l.Addons 'RollMe\RollMe.toc') -Content "## Version: v2.0.0"

        $r = Invoke-RollbackForRecord -Record $rec -AddonsPath $l.Addons -StagingPath $l.Staging -BackupsRoot $l.Backups

        $r.Status | Should Be 'Rolled-back'
        $rec.installedTag | Should Be 'v1.0.0'
        $rec.pinnedFileId | Should Be 'v1.0.0'
        $rec.previousFileId | Should Be 'v2.0.0'
        ((Get-R48Text (Join-Path $l.Addons 'RollMe\RollMe.toc')) -like '*v1.0.0*') | Should Be $true
    }

    It 'CLI: -Add github:owner/repo -FileId <tag> installs that tag and records it as the pin' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'CliPin' -ZipEntries @{ 'CliPin/CliPin.toc' = "## Interface: 120100`r`n## Title: CliPin`r`n## Version: v1.0.0`r`n" }
        try {
            $wowRoot = Copy-Fixture
            $cliPath = Join-Path (New-TempRoot -Name 'r48-clipin') 'addon-sync.ps1'
            Copy-Item -LiteralPath $Script:AddonSyncPathR48 -Destination $cliPath -Force

            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl } `
                -ArgumentList @('-Add', 'github:acme/CliPin', '-FileId', 'v1.0.0', '-Json', '-WowRoot', $wowRoot, '-Flavor', 'retail')

            $r.ExitCode | Should Be 0
            $row = @($r.Json.results) | Where-Object { $_.repo -eq 'acme/CliPin' }
            $row.status | Should Be 'Installed'
            $rec = @($r.Json.addons) | Where-Object { $_.repo -eq 'acme/CliPin' }
            $rec.installedTag | Should Be 'v1.0.0'
            $rec.pinnedFileId | Should Be 'v1.0.0'
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }
}

Remove-TempRoots
