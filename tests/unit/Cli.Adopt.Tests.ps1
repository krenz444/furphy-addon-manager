<#
=====================================================================
 tests\unit\Cli.Adopt.Tests.ps1

 ADOPT-SPEC.md section 2 (addon-sync.ps1's new -Adopt mode): pure,
 offline, no network - -Adopt only ever reads .toc files under -AddonsPath
 and writes addons.json, never downloads or touches an AddOns folder
 itself (section 2.3.1's network-free branch). Every scenario below
 builds its own throwaway "WoW root" (just enough of
 <root>\_retail_\Interface\AddOns\<folder>\<folder>.toc for
 Get-InstalledFlavours/Resolve-AddonsPath to recognize retail as
 installed - no Wow.exe, no .build.info needed) and its own copy of
 addon-sync.ps1, so addons.json/settings.json/flavours\ (which live next
 to the script itself, never under -WowRoot) never leak between It
 blocks.

 A second, top-level dot-source of the REAL addon-sync.ps1 (not a per-
 test copy) gives this file direct access to Get-RecordBackupKey for the
 backup-directory-collision regression checks (ADOPT-SPEC.md section
 2.3's Appendix item 2) - the same "dot-source loads functions, never
 runs Main" pattern already proven safe by Cli.BaseUrlOverride.Tests.ps1.

 Depends on the CLI package's -Adopt parameter/block actually existing
 (ADOPT-SPEC.md section 2) - until it lands, every -Adopt invocation
 below fails PowerShell's own parameter binding ("A parameter cannot be
 found that matches parameter name 'Adopt'"), which is the expected,
 pending-another-package failure mode for this whole file.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function New-AdoptCliScratch {
    <# One throwaway <root>\_retail_\Interface\AddOns\ + its own addon-sync.ps1 copy. #>
    param([string]$Name = 'cli-adopt')

    $root = New-TempRoot -Name $Name
    $addonsPath = Join-Path -Path $root -ChildPath '_retail_\Interface\AddOns'
    New-Item -ItemType Directory -Path $addonsPath -Force | Out-Null
    $cliPath = Join-Path -Path $root -ChildPath 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'addon-sync.ps1') -Destination $cliPath -Force

    return [PSCustomObject]@{
        Root       = $root
        AddonsPath = $addonsPath
        CliPath    = $cliPath
        RecordsPath = Join-Path -Path $root -ChildPath 'flavours\retail\addons.json'
    }
}

function New-AdoptFolder {
    <#
      Writes <AddonsPath>\<FolderName>\<FolderName>.toc with whatever tags
      are supplied - $null/omitted tags are simply left out of the file
      (e.g. -CurseId $null writes a .toc with no X-Curse-Project-ID line
      at all, for the "neither id" scenario).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$Title,
        [string]$Version = '1.0.0',
        [string]$CurseId,
        [string]$WagoId
    )

    $dir = Join-Path -Path $AddonsPath -ChildPath $FolderName
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('## Interface: 120100')
    if ($Title) { $lines.Add("## Title: $Title") }
    if ($null -ne $Version) { $lines.Add("## Version: $Version") }
    if ($CurseId) { $lines.Add("## X-Curse-Project-ID: $CurseId") }
    if ($WagoId) { $lines.Add("## X-Wago-ID: $WagoId") }
    ($lines -join "`r`n") | Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath "$FolderName.toc") -Encoding Ascii
}

function Invoke-Adopt {
    param(
        [Parameter(Mandatory = $true)]$Scratch,
        [Parameter(Mandatory = $true)][string]$FolderArg
    )
    return Invoke-CliJson -ScriptPath $Scratch.CliPath -TimeoutSec 30 -ArgumentList @(
        '-WowRoot', $Scratch.Root, '-Flavor', 'retail', '-Adopt', $FolderArg, '-Json')
}

function Get-AdoptedRecords {
    param([Parameter(Mandatory = $true)]$Scratch)
    # Plain assignment first (safe - see Read-JsonRecordsFile's own doc
    # comment), then re-exposed via the SAME ",X" idiom that function uses
    # internally - a plain "return $records" here would re-flatten a
    # single-record array back to a scalar on the way out (pipeline
    # enumeration on `return`), undoing the very thing Read-JsonRecordsFile
    # just fixed. Callers must, in turn, use plain assignment on THIS
    # function too - never `@(Get-AdoptedRecords ...)`.
    $records = Read-JsonRecordsFile -Path $Scratch.RecordsPath
    return , $records
}

Describe 'a single folder with a CurseForge id is adopted, not downloaded (ADOPT-SPEC.md 2.3)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-solo-cf'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'SoloAddon' -Title 'Solo Addon' -Version '5.20.3' -CurseId '111222'
    $before = Get-TreeFingerprint -Path $scratch.AddonsPath

    $r = Invoke-Adopt -Scratch $scratch -FolderArg 'SoloAddon'

    It 'exits 0 and reports one Adopted row with fileId null and folders [SoloAddon]' {
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { $_.name -eq 'Solo Addon' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Adopted'
        ($null -eq $row[0].fileId -or $row[0].fileId -eq '') | Should Be $true
        @($row[0].folders) | Should Be @('SoloAddon')
    }

    It 'the on-disk record is really adopted=true with a non-empty adoptedAt timestamp' {
        $records = Get-AdoptedRecords -Scratch $scratch
        $mine = @($records | Where-Object { [string]$_.projectId -eq '111222' })
        @($mine).Count | Should Be 1
        $mine[0].adopted | Should Be $true
        ([string]::IsNullOrWhiteSpace($mine[0].adoptedAt)) | Should Be $false
        { [datetime]::Parse($mine[0].adoptedAt) } | Should Not Throw
        $mine[0].version | Should Be '5.20.3'
    }

    It 'the record''s .projectId/.curseId are really the scanned id (never 0/null), and Get-RecordBackupKey keys off it, not "0" (Appendix item 2)' {
        $records = Get-AdoptedRecords -Scratch $scratch
        $mine = @($records | Where-Object { [string]$_.projectId -eq '111222' })[0]
        [int]$mine.projectId | Should Be 111222
        [string]$mine.curseId | Should Be '111222'

        Get-RecordBackupKey -Record $mine | Should Be '111222'
        Get-RecordBackupKey -Record $mine | Should Not Be '0'
    }

    It 'made zero filesystem writes under the AddOns path (config-only, network-free per section 2.3.1)' {
        $after = Get-TreeFingerprint -Path $scratch.AddonsPath
        (Compare-Object -ReferenceObject $before -DifferenceObject $after) | Should BeNullOrEmpty
    }
}

Describe 'two folders sharing one CurseForge id are bundled into a single record (ADOPT-SPEC.md 2.3)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-group-cf'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'GroupMain' -Title 'Group Addon' -Version '2.0.0' -CurseId '555000'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'GroupLib' -CurseId '555000'

    $r = Invoke-Adopt -Scratch $scratch -FolderArg 'GroupMain,GroupLib'

    It 'reports exactly one Adopted row whose folders array holds both names' {
        $r.ExitCode | Should Be 0
        $adopted = @($r.Json.results) | Where-Object { $_.status -eq 'Adopted' }
        @($adopted).Count | Should Be 1
        (@($adopted[0].folders) | Sort-Object) | Should Be (@('GroupLib', 'GroupMain') | Sort-Object)
        $adopted[0].name | Should Be 'Group Addon'
    }

    It 'exactly one record was written, and its .projectId is the shared id' {
        $records = Get-AdoptedRecords -Scratch $scratch
        $mine = @($records | Where-Object { [string]$_.projectId -eq '555000' })
        @($mine).Count | Should Be 1
        (@($mine[0].folders) | Sort-Object) | Should Be (@('GroupLib', 'GroupMain') | Sort-Object)
    }
}

Describe 'a Wago-only folder is adopted with source wago and a real slug (ADOPT-SPEC.md 2.3, Appendix item 2 Wago side)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-wago'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'WagoOnlyAddon' -Title 'Wago Only Addon' -Version '9.9.9' -WagoId 'my-wago-slug'

    $r = Invoke-Adopt -Scratch $scratch -FolderArg 'WagoOnlyAddon'

    It 'the -Json results row has projectId null and wagoSlug populated' {
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { $_.status -eq 'Adopted' }
        @($row).Count | Should Be 1
        ($null -eq $row[0].projectId -or $row[0].projectId -eq '') | Should Be $true
        [string]$row[0].wagoSlug | Should Be 'my-wago-slug'
    }

    It 'the on-disk record has source=wago, .slug and .wagoId both equal to the scanned id, and Get-RecordBackupKey returns wago-my-wago-slug, never wago- alone' {
        $records = Get-AdoptedRecords -Scratch $scratch
        $mine = @($records | Where-Object { $_.name -eq 'Wago Only Addon' })
        @($mine).Count | Should Be 1
        $mine[0].source | Should Be 'wago'
        [string]$mine[0].slug | Should Be 'my-wago-slug'
        [string]$mine[0].wagoId | Should Be 'my-wago-slug'

        Get-RecordBackupKey -Record $mine[0] | Should Be 'wago-my-wago-slug'
        Get-RecordBackupKey -Record $mine[0] | Should Not Be 'wago-'
    }
}

Describe 'a folder with neither id is skipped, not adopted (ADOPT-SPEC.md 2.3)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-neither'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'MysteryFolder' -Title 'Mystery' -Version '1.0.0'

    $r = Invoke-Adopt -Scratch $scratch -FolderArg 'MysteryFolder'

    It 'is Skipped with a reason mentioning "no recognizable"' {
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { $_.folders -contains 'MysteryFolder' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Skipped'
        ([string]$row[0].reason) | Should Match '(?i)no recognizable'
    }

    It 'no record was written for it' {
        $records = Get-AdoptedRecords -Scratch $scratch
        @($records | Where-Object { $_.name -eq 'Mystery' }).Count | Should Be 0
    }
}

Describe 'a folder missing on disk is skipped with "folder not found" (ADOPT-SPEC.md 2.3)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-missing'

    $r = Invoke-Adopt -Scratch $scratch -FolderArg 'DoesNotExistOnDisk'

    It 'is Skipped with a reason mentioning "not found"' {
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { $_.folders -contains 'DoesNotExistOnDisk' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Skipped'
        ([string]$row[0].reason) | Should Match '(?i)not found'
    }
}

Describe 'a truthy but non-numeric X-Curse-Project-ID is skipped alone, without aborting the rest of the batch (ADOPT-SPEC.md 2.3, Appendix item 3)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-badid'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'BadIdAddon' -Title 'Bad Id Addon' -CurseId 'not-a-number'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'GoodIdAddon' -Title 'Good Id Addon' -CurseId '424242'

    $r = Invoke-Adopt -Scratch $scratch -FolderArg 'BadIdAddon,GoodIdAddon'

    It 'exits 0 with no crash; the bad-id folder is Skipped ("id not usable") and the valid one still comes back Adopted' {
        $r.ExitCode | Should Be 0
        $bad = @($r.Json.results) | Where-Object { $_.folders -contains 'BadIdAddon' }
        @($bad).Count | Should Be 1
        $bad[0].status | Should Be 'Skipped'
        ([string]$bad[0].reason) | Should Match '(?i)id not usable'

        $good = @($r.Json.results) | Where-Object { $_.folders -contains 'GoodIdAddon' }
        @($good).Count | Should Be 1
        $good[0].status | Should Be 'Adopted'
    }

    It 'only the valid one was written to addons.json' {
        $records = Get-AdoptedRecords -Scratch $scratch
        @($records | Where-Object { $_.name -eq 'Bad Id Addon' }).Count | Should Be 0
        @($records | Where-Object { [string]$_.projectId -eq '424242' }).Count | Should Be 1
    }
}

Describe 'a folder whose id is already tracked is skipped, and re-running -Adopt never duplicates it (ADOPT-SPEC.md 2.3)' {
    $scratch = New-AdoptCliScratch -Name 'cli-adopt-duplicate'
    New-AdoptFolder -AddonsPath $scratch.AddonsPath -FolderName 'AlreadyTracked' -Title 'Already Tracked' -CurseId '900900'

    # Pre-seed addons.json with an existing record for the same project id,
    # under a DIFFERENT folder name than what is really on disk - proves
    # the "already tracked" check is keyed on id, not on folder name.
    $flavourDir = Join-Path -Path $scratch.Root -ChildPath 'flavours\retail'
    New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
    $existing = [PSCustomObject]@{
        name      = 'Old Helper'
        projectId = 900900
        fileId    = 1234
        version   = '1.0.0'
        folders   = @('OldHelperFolderName')
        source    = 'curseforge'
        curseId   = '900900'
        adopted   = $false
        adoptedAt = $null
    }
    ConvertTo-Json -InputObject @($existing) -Depth 6 | Set-Content -LiteralPath $scratch.RecordsPath -Encoding UTF8

    $r1 = Invoke-Adopt -Scratch $scratch -FolderArg 'AlreadyTracked'

    It 'first call: Skipped with a reason mentioning "already tracked"' {
        $r1.ExitCode | Should Be 0
        $row = @($r1.Json.results) | Where-Object { $_.folders -contains 'AlreadyTracked' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Skipped'
        ([string]$row[0].reason) | Should Match '(?i)already tracked'
    }

    $r2 = Invoke-Adopt -Scratch $scratch -FolderArg 'AlreadyTracked'

    It 'second call (re-run): same folder still Skipped "already tracked", still exactly one record for that id (no duplicate)' {
        $r2.ExitCode | Should Be 0
        $row2 = @($r2.Json.results) | Where-Object { $_.folders -contains 'AlreadyTracked' }
        @($row2).Count | Should Be 1
        $row2[0].status | Should Be 'Skipped'

        $records = Get-AdoptedRecords -Scratch $scratch
        @($records | Where-Object { [string]$_.projectId -eq '900900' }).Count | Should Be 1
    }
}

Remove-TempRoots
