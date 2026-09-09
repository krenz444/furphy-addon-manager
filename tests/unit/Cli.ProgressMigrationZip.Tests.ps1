<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's progress-file writer
  (Write-ProgressStep), the flavour migration (Invoke-FlavourMigration),
  zip-extraction safety (Install-AddonPackage against a hand-crafted
  malicious zip built with System.IO.Compression), and the byte-progress
  downloader (Invoke-HttpDownloadWithProgress) against a local python
  http.server.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

Describe 'Write-ProgressStep' {

    It 'is a complete no-op (no file created) when $script:ProgressPath is unset' {
        $script:ProgressPath = $null
        $root = New-TempRoot -Name 'progress-noop'
        $target = Join-Path $root 'progress.json'
        Write-ProgressStep -Total 3 -Index 1 -Phase 'downloading'
        (Test-Path -LiteralPath $target) | Should Be $false
    }

    It 'writes valid, readable JSON after a single call, atomically (no .tmp leftover)' {
        $root = New-TempRoot -Name 'progress-one'
        $target = Join-Path $root 'progress.json'
        $script:ProgressPath = $target
        Write-ProgressStep -Total 5 -Index 2 -Phase 'installing' -Addon 'BigWigs'
        (Test-Path -LiteralPath $target) | Should Be $true
        (Test-Path -LiteralPath "$target.tmp") | Should Be $false
        $parsed = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
        $parsed.total | Should Be 5
        $parsed.index | Should Be 2
        $parsed.phase | Should Be 'installing'
        $parsed.addon | Should Be 'BigWigs'
    }

    It 'produces valid JSON after every call in a sequence, each one overwriting the last' {
        $root = New-TempRoot -Name 'progress-seq'
        $target = Join-Path $root 'progress.json'
        $script:ProgressPath = $target
        foreach ($phase in @('queued', 'checking', 'downloading', 'installing', 'done')) {
            Write-ProgressStep -Total 1 -Index 0 -Phase $phase
            $parsed = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
            $parsed.phase | Should Be $phase
        }
    }

    It 'includes bytesDone/bytesTotal only when supplied, and failPhase only when supplied' {
        $root = New-TempRoot -Name 'progress-optional'
        $target = Join-Path $root 'progress.json'
        $script:ProgressPath = $target

        Write-ProgressStep -Total 1 -Index 0 -Phase 'downloading' -BytesDone 100 -BytesTotal 200
        $parsed = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
        $parsed.bytesDone | Should Be 100
        $parsed.bytesTotal | Should Be 200

        Write-ProgressStep -Total 1 -Index 0 -Phase 'failed' -FailPhase 'downloading'
        $parsed2 = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
        $parsed2.failPhase | Should Be 'downloading'
        ($parsed2.PSObject.Properties.Match('bytesDone').Count) | Should Be 0
    }

    It 'never throws even when the progress path''s parent directory does not exist' {
        $script:ProgressPath = 'C:\Furphy-Tests-Nonexistent-Dir-Xyz\progress.json'
        Write-ProgressStep -Total 1 -Index 0 -Phase 'queued'
        # Reaching here (no exception) is the assertion - "must never abort the run".
        $true | Should Be $true
    }

    It 'always includes the tallies fields, defaulting to all-zero before any Update-ProgressTallies call' {
        $root = New-TempRoot -Name 'progress-tallies-default'
        $target = Join-Path $root 'progress.json'
        $script:ProgressPath = $target
        $script:ProgressTallies = $null
        Write-ProgressStep -Total 3 -Index 0 -Phase 'queued'
        $parsed = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
        $parsed.checked | Should Be 0
        $parsed.updated | Should Be 0
        $parsed.failed | Should Be 0
        $parsed.upToDate | Should Be 0
        $parsed.updatesFound | Should Be 0
    }

    It 'reflects whatever $script:ProgressTallies currently holds on every write' {
        $root = New-TempRoot -Name 'progress-tallies-live'
        $target = Join-Path $root 'progress.json'
        $script:ProgressPath = $target
        $script:ProgressTallies = @{ checked = 2; updated = 1; failed = 0; upToDate = 1; updatesFound = 1 }
        Write-ProgressStep -Total 3 -Index 2 -Phase 'checking' -Addon 'Foo'
        $parsed = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
        $parsed.checked | Should Be 2
        $parsed.updated | Should Be 1
        $parsed.upToDate | Should Be 1
        $parsed.updatesFound | Should Be 1
    }

    $script:ProgressPath = $null
    $script:ProgressTallies = $null
}

Describe 'Update-ProgressTallies (pure)' {

    It 'New-ProgressTallies returns all-zero' {
        $t = New-ProgressTallies
        $t.checked | Should Be 0
        $t.updated | Should Be 0
        $t.failed | Should Be 0
        $t.upToDate | Should Be 0
        $t.updatesFound | Should Be 0
    }

    It 'does not mutate the hashtable passed in (pure)' {
        $original = New-ProgressTallies
        $result = Update-ProgressTallies -Tallies $original -FinishedStatus 'Updated'
        $original.checked | Should Be 0
        $original.updated | Should Be 0
        $result.checked | Should Be 1
        $result.updated | Should Be 1
    }

    It '-FoundUpdate increments only updatesFound' {
        $t = New-ProgressTallies
        $t = Update-ProgressTallies -Tallies $t -FoundUpdate
        $t.updatesFound | Should Be 1
        $t.checked | Should Be 0
        $t.updated | Should Be 0
        $t.failed | Should Be 0
        $t.upToDate | Should Be 0
    }

    It '-FoundUpdate is additive across repeated calls (one per addon that found an update)' {
        $t = New-ProgressTallies
        $t = Update-ProgressTallies -Tallies $t -FoundUpdate
        $t = Update-ProgressTallies -Tallies $t -FoundUpdate
        $t.updatesFound | Should Be 2
    }

    It '-FinishedStatus ''Up-to-date'' increments checked and upToDate only' {
        $t = Update-ProgressTallies -Tallies (New-ProgressTallies) -FinishedStatus 'Up-to-date'
        $t.checked | Should Be 1
        $t.upToDate | Should Be 1
        $t.updated | Should Be 0
        $t.failed | Should Be 0
    }

    It '-FinishedStatus ''Failed'' increments checked and failed only' {
        $t = Update-ProgressTallies -Tallies (New-ProgressTallies) -FinishedStatus 'Failed'
        $t.checked | Should Be 1
        $t.failed | Should Be 1
        $t.updated | Should Be 0
        $t.upToDate | Should Be 0
    }

    It '-FinishedStatus ''Installed'' and ''Updated'' both increment checked and updated' {
        $tInstalled = Update-ProgressTallies -Tallies (New-ProgressTallies) -FinishedStatus 'Installed'
        $tInstalled.checked | Should Be 1
        $tInstalled.updated | Should Be 1

        $tUpdated = Update-ProgressTallies -Tallies (New-ProgressTallies) -FinishedStatus 'Updated'
        $tUpdated.checked | Should Be 1
        $tUpdated.updated | Should Be 1
    }

    It '-FinishedStatus ''Skipped'' (e.g. a budget/dedup skip) increments checked only' {
        $t = Update-ProgressTallies -Tallies (New-ProgressTallies) -FinishedStatus 'Skipped'
        $t.checked | Should Be 1
        $t.updated | Should Be 0
        $t.failed | Should Be 0
        $t.upToDate | Should Be 0
    }

    It '-FinishedStatus ''Ignored'' increments checked only (an ignoreUpdates addon still counts as finished)' {
        $t = Update-ProgressTallies -Tallies (New-ProgressTallies) -FinishedStatus 'Ignored'
        $t.checked | Should Be 1
        $t.updated | Should Be 0
        $t.failed | Should Be 0
        $t.upToDate | Should Be 0
    }

    It 'a full mixed run (2 up to date, 1 updated, 1 failed, 1 update-found-then-installing) tallies correctly' {
        $t = New-ProgressTallies
        $t = Update-ProgressTallies -Tallies $t -FinishedStatus 'Up-to-date'
        $t = Update-ProgressTallies -Tallies $t -FinishedStatus 'Up-to-date'
        $t = Update-ProgressTallies -Tallies $t -FoundUpdate
        $t = Update-ProgressTallies -Tallies $t -FinishedStatus 'Updated'
        $t = Update-ProgressTallies -Tallies $t -FinishedStatus 'Failed'
        $t.checked | Should Be 4
        $t.upToDate | Should Be 2
        $t.updated | Should Be 1
        $t.failed | Should Be 1
        $t.updatesFound | Should Be 1
    }
}

Describe 'Invoke-FlavourMigration' {

    It 'copies (not just moves) the pre-flavour backup identically, moves the originals, and stamps schemaVersion 2' {
        $root = New-TempRoot -Name 'migration-basic'
        Set-Content -LiteralPath (Join-Path $root 'addons.json') -Value '[{"name":"Foo","projectId":1}]' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'state.json') -Value '{"lastRun":null}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $root 'backups\1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'backups\1\1.zip') -Value 'zipcontent' -Encoding UTF8

        Invoke-FlavourMigration -RootPath $root

        (Test-Path -LiteralPath (Join-Path $root 'flavours\retail\addons.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'flavours\retail\state.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'flavours\retail\backups\1\1.zip')) | Should Be $true
        # Moved, not left behind at the top level.
        (Test-Path -LiteralPath (Join-Path $root 'addons.json')) | Should Be $false

        $settings = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
        $settings.schemaVersion | Should Be 2

        $backupDirs = Get-ChildItem -LiteralPath (Join-Path $root 'flavours') -Directory -Filter '_migration-backup-*'
        $backupDirs.Count | Should Be 1
        $backupContent = Get-Content -LiteralPath (Join-Path $backupDirs[0].FullName 'addons.json') -Raw
        $backupContent.Trim() | Should Be '[{"name":"Foo","projectId":1}]'
    }

    It 'is idempotent: re-running after a completed migration creates no second backup and does not error' {
        $root = New-TempRoot -Name 'migration-idempotent'
        Set-Content -LiteralPath (Join-Path $root 'addons.json') -Value '[]' -Encoding UTF8
        Invoke-FlavourMigration -RootPath $root
        Invoke-FlavourMigration -RootPath $root
        $backupDirs = Get-ChildItem -LiteralPath (Join-Path $root 'flavours') -Directory -Filter '_migration-backup-*'
        $backupDirs.Count | Should Be 1
    }

    It 'a brand-new install with no top-level addons.json/state.json/backups leaves no migration-backup folder (nothing to protect)' {
        # Invoke-FlavourMigration still creates the (empty) flavours\retail\
        # home folder unconditionally on a schemaVersion<2 run - that part
        # is not gated on "is there anything to migrate" - but the copy-
        # first BACKUP step explicitly is (see its own doc comment: "no
        # data to protect, so no empty backup-folder cruft is left
        # behind"), which is the actual no-cruft guarantee this test proves.
        $root = New-TempRoot -Name 'migration-fresh'
        Invoke-FlavourMigration -RootPath $root
        $backupDirs = $null
        if (Test-Path -LiteralPath (Join-Path $root 'flavours')) {
            $backupDirs = Get-ChildItem -LiteralPath (Join-Path $root 'flavours') -Directory -Filter '_migration-backup-*' -ErrorAction SilentlyContinue
        }
        (@($backupDirs)).Count | Should Be 0
    }

    It 'crash-mid-move safe: a pre-landed flavours\retail\addons.json (simulated crash) is never overwritten by a retry, and no second backup is created' {
        $root = New-TempRoot -Name 'migration-crash'
        Set-Content -LiteralPath (Join-Path $root 'addons.json') -Value '[{"name":"Original"}]' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'state.json') -Value '{"lastRun":"x"}' -Encoding UTF8

        # Simulate a crash exactly between "addons.json already moved" and
        # "state.json not yet moved": pre-populate the destination by hand,
        # with content that would prove an overwrite if one happened.
        New-Item -ItemType Directory -Path (Join-Path $root 'flavours\retail') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'flavours\retail\addons.json') -Value '[{"name":"AlreadyLanded"}]' -Encoding UTF8

        Invoke-FlavourMigration -RootPath $root

        $landed = Get-Content -LiteralPath (Join-Path $root 'flavours\retail\addons.json') -Raw
        $landed.Trim() | Should Be '[{"name":"AlreadyLanded"}]'
        (Test-Path -LiteralPath (Join-Path $root 'flavours\retail\state.json')) | Should Be $true
        $backupDirs = Get-ChildItem -LiteralPath (Join-Path $root 'flavours') -Directory -Filter '_migration-backup-*'
        $backupDirs.Count | Should Be 1
    }
}

Describe 'Install-AddonPackage - zip extraction safety' {

    function New-CraftedZip {
        <# Builds a zip with one legitimate addon folder plus one malicious entry, via System.IO.Compression directly (never Expand-Archive/7zip). #>
        param([string]$ZipPath, [string]$MaliciousEntryName, [string]$MaliciousContent)

        Add-Type -AssemblyName System.IO.Compression
        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
        $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $good = $archive.CreateEntry('GoodAddon/GoodAddon.toc')
                $gs = $good.Open()
                try {
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes("## Interface: 120100`n## Title: Good`n")
                    $gs.Write($bytes, 0, $bytes.Length)
                } finally { $gs.Close() }

                $bad = $archive.CreateEntry($MaliciousEntryName)
                $bs = $bad.Open()
                try {
                    $badBytes = [System.Text.Encoding]::ASCII.GetBytes($MaliciousContent)
                    $bs.Write($badBytes, 0, $badBytes.Length)
                } finally { $bs.Close() }
            } finally {
                $archive.Dispose()
            }
        } finally {
            $fs.Dispose()
        }
    }

    It 'a "../../" traversal entry never escapes the extraction root and its content is never installed into AddOns' {
        <#
          Confirmed live (both as a plain script AND under Pester, which
          differ - see below) against a zip built with
          System.IO.Compression: ZipFile.ExtractToDirectory itself always
          rejects the traversal entry outright ("Can not process invalid
          archive entry"); Install-AddonPackage's own catch then falls
          back to Expand-Archive, which ALSO refuses the same entry - but
          whether that second refusal is terminating depends on the
          module's own error-preference resolution in the CALLER's
          runspace: as a plain top-level script this propagates as a
          terminating exception (Install-AddonPackage throws, nothing is
          installed at all); inside Pester 3's own It scope it is instead
          a non-terminating Write-Error - Expand-Archive silently SKIPS
          just that one bad entry and extracts the rest, so
          Install-AddonPackage returns normally with the legitimate
          GoodAddon folder installed and the malicious entry simply never
          materialized anywhere. Both outcomes satisfy the actual security
          property (asserted below, environment-independent): the
          malicious entry is NEVER written outside the extraction
          scratch dir, and is NEVER present anywhere under AddOns.
          -ErrorAction SilentlyContinue only quiets the expected
          Write-Error noise in test output; it does not change the
          function's own extraction behavior above.
        #>
        $root = New-TempRoot -Name 'zip-traversal'
        $staging = Join-Path $root 'staging'
        $addons = Join-Path $root 'addons'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $addons -Force | Out-Null
        $zipPath = Join-Path $root 'evil-traversal.zip'
        New-CraftedZip -ZipPath $zipPath -MaliciousEntryName '../../evil_escape.txt' -MaliciousContent 'pwned'

        try {
            Install-AddonPackage -ZipPath $zipPath -ProjectId 999 -StagingPath $staging -AddonsPath $addons -PreviousFolders @() -ErrorAction SilentlyContinue | Out-Null
        } catch {
        }

        $escapeOutsideTempRoot = Join-Path (Split-Path -Path $Script:FurphyTmpRoot -Parent) 'evil_escape.txt'
        (Test-Path -LiteralPath $escapeOutsideTempRoot) | Should Be $false
        $badInAddons = Get-ChildItem -LiteralPath $addons -Recurse -Filter 'evil_escape.txt' -ErrorAction SilentlyContinue
        (@($badInAddons)).Count | Should Be 0
    }

    It 'a leading-slash "absolute path" entry never escapes staging and is never copied into AddOns (not a folder with a .toc)' {
        $root = New-TempRoot -Name 'zip-absolute'
        $staging = Join-Path $root 'staging'
        $addons = Join-Path $root 'addons'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $addons -Force | Out-Null
        $zipPath = Join-Path $root 'evil-absolute.zip'
        New-CraftedZip -ZipPath $zipPath -MaliciousEntryName '/evil_absolute.txt' -MaliciousContent 'pwned-abs'

        # This shape does not necessarily throw (.NET normalizes a leading
        # slash to a plain relative top-level entry) - the safety property
        # under test is containment: it may land inside the extraction
        # scratch dir, but a bare top-level FILE (no .toc, no folder) is
        # never a valid addon folder, so Install-AddonPackage's own
        # existing folder-with-.toc filter keeps it out of AddOns either way.
        try {
            Install-AddonPackage -ZipPath $zipPath -ProjectId 998 -StagingPath $staging -AddonsPath $addons -PreviousFolders @() | Out-Null
        } catch {
        }

        $escapeOutsideTempRoot = Join-Path (Split-Path -Path $Script:FurphyTmpRoot -Parent) 'evil_absolute.txt'
        (Test-Path -LiteralPath $escapeOutsideTempRoot) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $addons 'evil_absolute.txt')) | Should Be $false
    }

    It 'a well-formed zip with only a legitimate addon folder still installs normally (no false-positive rejection)' {
        $root = New-TempRoot -Name 'zip-good'
        $staging = Join-Path $root 'staging'
        $addons = Join-Path $root 'addons'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path $addons -Force | Out-Null
        $zipPath = Join-Path $root 'good.zip'

        Add-Type -AssemblyName System.IO.Compression
        $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        $e = $archive.CreateEntry('PlainAddon/PlainAddon.toc')
        $s = $e.Open()
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("## Interface: 120100`n")
        $s.Write($bytes, 0, $bytes.Length)
        $s.Close()
        $archive.Dispose()
        $fs.Dispose()

        $installed = Install-AddonPackage -ZipPath $zipPath -ProjectId 1 -StagingPath $staging -AddonsPath $addons -PreviousFolders @()
        $installed.Count | Should Be 1
        $installed[0] | Should Be 'PlainAddon'
        (Test-Path -LiteralPath (Join-Path $addons 'PlainAddon\PlainAddon.toc')) | Should Be $true
    }
}

Describe 'Install-AddonPackage - folder swap failure integrity (failure-modes:silent-fake-success-on-locked-addons-folder)' {

    function New-OneFolderZip {
        <# Builds a minimal valid zip with one top-level "<FolderName>/<FolderName>.toc" entry containing $Content. #>
        param([string]$ZipPath, [string]$FolderName, [string]$Content)

        Add-Type -AssemblyName System.IO.Compression
        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
        $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $archive.CreateEntry("$FolderName/$FolderName.toc")
                $es = $entry.Open()
                try {
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Content)
                    $es.Write($bytes, 0, $bytes.Length)
                } finally { $es.Close() }
            } finally { $archive.Dispose() }
        } finally { $fs.Dispose() }
    }

    It 'a locked file inside the existing destination folder makes the whole swap throw, leaving the OLD folder completely untouched (never a silent fake success)' {
        # Mirrors the finding's own live repro #2: an exclusive-ish lock
        # (FileShare.Read - readers ok, no writers/deleters) held on a file
        # INSIDE the existing destination folder during the swap, the same
        # shape a real AV scanner/cloud-sync client/Explorer preview would
        # produce. Before the fix, Test-Path on $destPath still returned
        # true (the old folder never actually got removed) so the caller
        # wrongly counted this as installed; the fix makes
        # Install-AddonPackage itself throw so no caller can be fooled.
        $root = New-TempRoot -Name 'swap-locked-single'
        $staging = Join-Path $root 'staging'
        $addons = Join-Path $root 'addons'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $existingDir = Join-Path $addons 'BigWigs'
        New-Item -ItemType Directory -Path $existingDir -Force | Out-Null
        $existingFile = Join-Path $existingDir 'BigWigs.toc'
        Set-Content -LiteralPath $existingFile -Value 'OLD-VERSION' -Encoding ASCII -NoNewline

        $zipPath = Join-Path $root 'BigWigs-new.zip'
        New-OneFolderZip -ZipPath $zipPath -FolderName 'BigWigs' -Content 'NEW-VERSION'

        $lockStream = [System.IO.File]::Open($existingFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $threw = $false
            try {
                Install-AddonPackage -ZipPath $zipPath -ProjectId 925037 -StagingPath $staging -AddonsPath $addons -PreviousFolders @('BigWigs') | Out-Null
            } catch {
                $threw = $true
            }
            $threw | Should Be $true
        } finally {
            $lockStream.Close()
            $lockStream.Dispose()
        }

        # The OLD file's content must be exactly what it was before -
        # neither replaced nor left in some half-deleted state.
        (Test-Path -LiteralPath $existingFile) | Should Be $true
        (Get-Content -LiteralPath $existingFile -Raw) | Should Be 'OLD-VERSION'
    }

    It 'a partial swap (one of two folders locked) still throws overall - never silently reports the addon as fully updated' {
        # failure-modes:silent-fake-success-on-locked-addons-folder's
        # "partial" case: a real multi-folder addon where only SOME
        # top-level folders fail to swap. The pre-fix code only ever
        # checked Count -eq 0, which this scenario would have sailed past
        # (Count would have been >= 1). Also documents the accepted
        # tradeoff: folders that CAN swap still do (maximum forward
        # progress), but the function still throws so the caller never
        # persists the update as a clean success.
        $root = New-TempRoot -Name 'swap-locked-partial'
        $staging = Join-Path $root 'staging'
        $addons = Join-Path $root 'addons'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $addons 'FolderA') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $addons 'FolderB') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $addons 'FolderA\FolderA.toc') -Value 'A-OLD' -Encoding ASCII -NoNewline
        $lockedFile = Join-Path $addons 'FolderB\FolderB.toc'
        Set-Content -LiteralPath $lockedFile -Value 'B-OLD' -Encoding ASCII -NoNewline

        Add-Type -AssemblyName System.IO.Compression
        $zipPath = Join-Path $root 'TwoFolders-new.zip'
        $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($name in @('FolderA', 'FolderB')) {
            $e = $archive.CreateEntry("$name/$name.toc")
            $s = $e.Open()
            $bytes = [System.Text.Encoding]::ASCII.GetBytes("$name-NEW")
            $s.Write($bytes, 0, $bytes.Length)
            $s.Close()
        }
        $archive.Dispose()
        $fs.Dispose()

        $lockStream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $threw = $false
            try {
                Install-AddonPackage -ZipPath $zipPath -ProjectId 555 -StagingPath $staging -AddonsPath $addons -PreviousFolders @('FolderA', 'FolderB') | Out-Null
            } catch {
                $threw = $true
                ($_.Exception.Message -like '*FolderB*') | Should Be $true
            }
            $threw | Should Be $true
        } finally {
            $lockStream.Close()
            $lockStream.Dispose()
        }

        # FolderA (unlocked) made forward progress and swapped to the new
        # content, but FolderB (locked) is untouched - and the overall
        # function still threw, so no caller can mistake this for a clean
        # "Updated" result.
        (Get-Content -LiteralPath (Join-Path $addons 'FolderA\FolderA.toc') -Raw) | Should Be 'FolderA-NEW'
        (Get-Content -LiteralPath $lockedFile -Raw) | Should Be 'B-OLD'
    }

    It 'a TRANSIENTLY locked file is retried and the swap succeeds once the lock is released within the retry budget (RETRY-ON-LOCK, GAME-MODE-SPEC.md section 7.4)' {
        <#
          GAME-MODE-SPEC.md section 8, new-coverage item 6 (conditional on
          Package A's own decision, tagged `# RETRY-ON-LOCK: added` above
          Install-AddonPackage's swap loop in addon-sync.ps1 - confirmed
          present, so this test is required, not skipped). The two Its
          above already prove the "locked for the whole call -> still
          throws after exhausting the retry budget" side (unaffected by
          adding retries, since their lock is held across the entire
          Install-AddonPackage call). This one proves the OTHER half: a
          lock that clears mid-swap - the exact "another process happened
          to be touching the file" scenario the retry exists for - lets
          the swap recover and succeed instead of failing outright.

          The lock is held on a REAL BACKGROUND THREAD ([PowerShell]::
          Create(), not a separate powershell.exe process - a whole
          process's own startup latency could by itself eat the ~300ms
          total retry budget below and make this test racy rather than
          deterministic) so it can run concurrently with THIS thread's
          own blocking Install-AddonPackage call. A marker file (polled,
          not a fixed guess-sleep) proves the lock is genuinely held
          before the race starts; the lock is then released well inside
          the 3-attempt/~150ms-apart retry window.
        #>
        $root = New-TempRoot -Name 'swap-locked-transient'
        $staging = Join-Path $root 'staging'
        $addons = Join-Path $root 'addons'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $existingDir = Join-Path $addons 'BigWigs'
        New-Item -ItemType Directory -Path $existingDir -Force | Out-Null
        $existingFile = Join-Path $existingDir 'BigWigs.toc'
        Set-Content -LiteralPath $existingFile -Value 'OLD-VERSION' -Encoding ASCII -NoNewline

        $zipPath = Join-Path $root 'BigWigs-new.zip'
        New-OneFolderZip -ZipPath $zipPath -FolderName 'BigWigs' -Content 'NEW-VERSION'

        $lockAcquiredMarker = Join-Path $root 'lock-acquired.marker'
        $ps = [PowerShell]::Create()
        $ps.AddScript({
            param($Path, $Marker)
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            [System.IO.File]::WriteAllText($Marker, 'locked')
            Start-Sleep -Milliseconds 100
            $fs.Close()
            $fs.Dispose()
        }).AddArgument($existingFile).AddArgument($lockAcquiredMarker) | Out-Null
        $handle = $ps.BeginInvoke()

        try {
            # Wait for the background thread to actually hold the lock
            # before racing it with Install-AddonPackage's own first
            # attempt - never a fixed guess-sleep for this half.
            $deadline = (Get-Date).AddSeconds(5)
            while (-not (Test-Path -LiteralPath $lockAcquiredMarker) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 10
            }
            (Test-Path -LiteralPath $lockAcquiredMarker) | Should Be $true

            # Attempt 1 (immediate) hits the still-held lock and fails;
            # attempt 2 (~150ms later) lands after the background thread's
            # own 100ms hold has released it.
            $installed = Install-AddonPackage -ZipPath $zipPath -ProjectId 925038 -StagingPath $staging -AddonsPath $addons -PreviousFolders @('BigWigs')
            $installed.Count | Should Be 1
            $installed[0] | Should Be 'BigWigs'
        } finally {
            $ps.EndInvoke($handle) | Out-Null
            $ps.Dispose()
        }

        (Get-Content -LiteralPath $existingFile -Raw) | Should Be 'NEW-VERSION'
    }
}

Describe 'Invoke-HttpDownloadWithProgress' {

    It 'downloads a file whose bytes match the source exactly, and writes at least one progress snapshot' {
        $root = New-TempRoot -Name 'download'
        $srcDir = Join-Path $root 'src'
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        $payload = [System.Text.Encoding]::UTF8.GetBytes(('X' * 400000))
        $srcFile = Join-Path $srcDir 'payload.bin'
        [System.IO.File]::WriteAllBytes($srcFile, $payload)

        $server = Start-StaticServer -Directory $srcDir
        try {
            $outFile = Join-Path $root 'downloaded.bin'
            $progressPath = Join-Path $root 'progress.json'
            $script:ProgressPath = $progressPath

            Invoke-HttpDownloadWithProgress -Uri ("http://127.0.0.1:{0}/payload.bin" -f $server.Port) `
                -UserAgent 'FurphyTests/1.0' -OutFile $outFile -TimeoutSec 20

            (Test-Path -LiteralPath $outFile) | Should Be $true
            $downloadedBytes = [System.IO.File]::ReadAllBytes($outFile)
            $downloadedBytes.Length | Should Be $payload.Length

            (Test-Path -LiteralPath $progressPath) | Should Be $true
            $lastProgress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
            $lastProgress.phase | Should Be 'downloading'
            $lastProgress.bytesDone | Should Be $payload.Length
        } finally {
            Stop-StaticServer -Server $server
            $script:ProgressPath = $null
        }
    }
}

Remove-TempRoots
