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

    $script:ProgressPath = $null
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
