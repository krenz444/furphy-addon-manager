<#
=====================================================================
 tests\integration\Install.AdoptWording.Tests.ps1

 ADOPT-SPEC.md section 6.5: the console flow's own wording for install
 step 8 (ADOPT-SPEC.md section 3.5's rewritten body) - Write-Step/
 Write-Info print identically to both the WinForms wizard and -Console
 (section 3.2's mirroring), so asserting on -Console's plain stdout text
 covers both surfaces with one set of strings.

 Fully offline by design (the new -Adopt mode never makes a network
 call - ADOPT-SPEC.md section 1) - no 'Network' tag. Until the CLI
 package's -Adopt and the Installer package's rewritten step 8 both
 land, install.ps1 still calls the CLI's real -Add for any folder this
 file gives it a fake CurseForge id for, which (a) still prints the OLD
 wording this file's own "does not match" assertions are checking for,
 so those assertions correctly fail either way, and (b) makes one real,
 harmless network call against a fake project id that CurseForge simply
 reports nothing for (mirrors Cli.InstallRollback.Tests.ps1's own "bogus
 project id" Describe) - never a test-breaking condition, just a
 pending-another-package failure on the wording assertions themselves.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'

function New-AdoptWordingWowRoot {
    <#
      A scratch WoW root with three AddOns folders exercising every
      branch ADOPT-SPEC.md 3.5's rewritten step body must word correctly:
        - RecognizableAddon: a real-looking CurseForge id -> adopted,
          "Found N addon(s)..." line.
        - MysteryAddon: no toc tags at all -> "left alone" line.
        - BadIdAddon: a TRUTHY but non-numeric X-Curse-Project-ID -> must
          fold into the SAME "left alone" line via 3.5's fold-through
          fix (Appendix item 3), not vanish from the output entirely.
    #>
    $root = Join-Path -Path $env:TEMP -ChildPath ('furphy-adoptwording-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $addonsPath = Join-Path -Path $root -ChildPath '_retail_\Interface\AddOns'
    New-Item -ItemType Directory -Path $addonsPath -Force | Out-Null

    $recDir = Join-Path -Path $addonsPath -ChildPath 'RecognizableAddon'
    New-Item -ItemType Directory -Path $recDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Recognizable Addon
## Version: 1.0.0
## X-Curse-Project-ID: 778899
'@ | Set-Content -LiteralPath (Join-Path -Path $recDir -ChildPath 'RecognizableAddon.toc') -Encoding Ascii

    $mysteryDir = Join-Path -Path $addonsPath -ChildPath 'MysteryAddon'
    New-Item -ItemType Directory -Path $mysteryDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Mystery Addon
## Version: 1.0.0
'@ | Set-Content -LiteralPath (Join-Path -Path $mysteryDir -ChildPath 'MysteryAddon.toc') -Encoding Ascii

    $badIdDir = Join-Path -Path $addonsPath -ChildPath 'BadIdAddon'
    New-Item -ItemType Directory -Path $badIdDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Bad Id Addon
## Version: 1.0.0
## X-Curse-Project-ID: not-a-number
'@ | Set-Content -LiteralPath (Join-Path -Path $badIdDir -ChildPath 'BadIdAddon.toc') -Encoding Ascii

    return $root
}

function Get-AdoptStepOutput {
    <#
      Isolates just install step 8's own printed block from a full
      -Console transcript - from its own Write-Step title line up to (not
      including) the NEXT step's title line ("Registering with Windows
      Settings > Apps", ADOPT-SPEC.md 3.4 - unchanged wording, the very
      next Write-Step after step 8) - so a "never prints X anywhere in
      THIS step's output" assertion cannot be fooled by X appearing in
      some unrelated earlier/later step.
    #>
    param([Parameter(Mandatory = $true)][string]$StdOut)

    $startIdx = $StdOut.IndexOf('Looking for addons you already have')
    if ($startIdx -lt 0) { return $StdOut }
    $endIdx = $StdOut.IndexOf('Registering with Windows Settings', $startIdx)
    if ($endIdx -lt 0) { $endIdx = $StdOut.Length }
    return $StdOut.Substring($startIdx, $endIdx - $startIdx)
}

Describe 'install.ps1 -Console step 8 wording (ADOPT-SPEC.md 3.4/3.5/6.5)' {
    $wowRoot = New-AdoptWordingWowRoot

    $result = Invoke-CliProcess -ScriptPath $Script:InstallScript -TimeoutSec 120 -ArgumentList @(
        '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console')
    $stepOutput = Get-AdoptStepOutput -StdOut $result.StdOut

    It 'exits 0' {
        $result.ExitCode | Should Be 0
    }

    It 'uses the new step title and success phrasing' {
        $result.StdOut | Should Match ([regex]::Escape('Looking for addons you already have'))
        $stepOutput | Should Match 'Found \d+ addon'
        $stepOutput | Should Match 'is now keeping track of them'
    }

    It 'never uses the old re-download-implying wording anywhere in this step''s output' {
        $stepOutput | Should Not Match '(?i)taking over'
        $stepOutput | Should Not Match '(?i)reinstalling'
        $stepOutput | Should Not Match '(?i)untracked'
    }

    It 'never prints a bare CurseForge project id or a wago: token in this step''s output' {
        $stepOutput | Should Not Match '778899'
        $stepOutput | Should Not Match '(?i)wago:'
    }

    It 'a folder with no recognizable id gets the new friendly "left alone" line, never the old phrasing' {
        $stepOutput | Should Match 'Furphy could not tell what'
        $stepOutput | Should Not Match '(?i)no CurseForge or Wago id found'
    }

    It 'a folder with a truthy but non-numeric X-Curse-Project-ID also folds into the same "left alone" line (Appendix item 3 fold-through regression)' {
        # Both the genuinely-unrecognizable MysteryAddon and the
        # non-numeric-id BadIdAddon must show up somewhere in the step's
        # output - neither should silently vanish from both the "Found N"
        # count and the "left alone" list (the exact gap Appendix item 3
        # describes and 3.5's fold-through fixes).
        $stepOutput | Should Match 'MysteryAddon'
        $stepOutput | Should Match 'BadIdAddon'
    }

    if (Test-Path -LiteralPath $wowRoot) {
        Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'install.ps1 -Console -SkipAdopt wording (ADOPT-SPEC.md 3.5)' {
    $wowRoot = New-AdoptWordingWowRoot

    $result = Invoke-CliProcess -ScriptPath $Script:InstallScript -TimeoutSec 120 -ArgumentList @(
        '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console')

    It 'prints the renamed -SkipAdopt line, matching the new "adding" wording, not the old "taking over" one' {
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match ([regex]::Escape('Skipped adding your existing addons (-SkipAdopt).'))
        $result.StdOut | Should Not Match '(?i)Skipped taking over existing addons'
    }

    if (Test-Path -LiteralPath $wowRoot) {
        Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
