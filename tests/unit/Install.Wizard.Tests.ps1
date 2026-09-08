<#
  Unit tests (Pester 3 syntax): install.ps1's WinForms wizard
  (Show-InstallWizard, DISTRIBUTION-SPEC.md section 6.2/6.3), covering
  QA-FINDINGS-LENSES-2.md's three confirmed "installer-dpi" findings from
  the 2026-09-06 lens round:

    - installer-no-visual-styles              (MEDIUM)
    - installer-no-progress-bar-control        (MEDIUM)
    - installer-wizard-no-acceptbutton-initial-focus (LOW, also covers
      the Escape/Cancel behaviour called out in the same fix note)

  Show-InstallWizard sits BELOW install.ps1's round-32 dot-source guard
  (line ~607-608: "if ($script:FurphyDotSourced) { return }"), so it is
  never defined just by dot-sourcing the script the way
  Install.Scoping.Tests.ps1/Install.Uninstall.Tests.ps1 test their pure
  helpers - and it ends in $form.ShowDialog(), which would hang forever
  waiting for a click nothing here will ever send. So this file tests it
  two ways, neither of which ever shows a window or blocks:

  1. Static source-text checks (Describe 1) - the exact pattern the QA
     report's own fix notes recommend ("simply assert the two
     Application.* calls are present via a static grep-based test... cheap,
     deterministic, and catches any future regression without needing a
     live screenshot") and the same technique Install.Scoping.Tests.ps1
     already uses for other code below the guard (its
     Remove-FurphyLegacyLauncherArtifacts checks).

  2. A real-object construction check (Describe 2) - the exact prefix of
     Show-InstallWizard's body up to (but NOT including) the first
     Add_Click wiring is extracted as text and evaluated as a standalone
     scriptblock. This builds real Form/Control objects (so AcceptButton/
     CancelButton/ProgressBar.Style/control Bounds can be asserted "by
     reflection" on live objects, not just grepped strings) but never
     calls Hide-InstallConsole or $form.ShowDialog() - both of those, and
     every Add_Click handler body, live textually AFTER the cut point, so
     they are never included and never run. No window is ever shown; the
     Form's handle is never created.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'
$Script:InstallSource = Get-Content -Raw -LiteralPath $Script:InstallScript

# Isolate just the Show-InstallWizard function's source (start-of-function
# to the "if ($Console) {" dispatch line that follows its closing brace)
# so every assertion below is scoped to this one function and can't be
# fooled by an unrelated match elsewhere in a 2000+ line file.
$Script:WizardFuncStart = $Script:InstallSource.IndexOf('function Show-InstallWizard {')
$Script:WizardFuncEnd = $Script:InstallSource.IndexOf("`nif (`$Console) {", $Script:WizardFuncStart)

Describe 'install.ps1 Show-InstallWizard is present and isolable' {
    It 'both source markers used by every test below were found' {
        $Script:WizardFuncStart | Should BeGreaterThan -1
        $Script:WizardFuncEnd | Should BeGreaterThan $Script:WizardFuncStart
    }
}

$Script:WizardFuncBody = $Script:InstallSource.Substring($Script:WizardFuncStart, $Script:WizardFuncEnd - $Script:WizardFuncStart)

Describe 'install.ps1 Show-InstallWizard - static source checks (installer-dpi findings)' {

    It 'installer-no-visual-styles: calls EnableVisualStyles and SetCompatibleTextRenderingDefault(false) exactly once each, in the whole file' {
        ([regex]::Matches($Script:InstallSource, [regex]::Escape('[System.Windows.Forms.Application]::EnableVisualStyles()'))).Count | Should Be 1
        ([regex]::Matches($Script:InstallSource, [regex]::Escape('[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)'))).Count | Should Be 1
    }

    It 'installer-no-visual-styles: both calls happen before the first Form/Control is constructed (ordering matters - EnableVisualStyles throws if called after)' {
        $visualStylesIdx = $Script:WizardFuncBody.IndexOf('EnableVisualStyles()')
        $renderingIdx = $Script:WizardFuncBody.IndexOf('SetCompatibleTextRenderingDefault')
        $firstFormIdx = $Script:WizardFuncBody.IndexOf('New-Object System.Windows.Forms.Form')

        $visualStylesIdx | Should BeGreaterThan -1
        $renderingIdx | Should BeGreaterThan -1
        $firstFormIdx | Should BeGreaterThan -1
        $visualStylesIdx | Should BeLessThan $firstFormIdx
        $renderingIdx | Should BeLessThan $firstFormIdx
    }

    It 'installer-no-progress-bar-control: a real ProgressBar is constructed, added to the form, and set to Marquee style' {
        $Script:WizardFuncBody | Should Match 'New-Object System\.Windows\.Forms\.ProgressBar'
        $Script:WizardFuncBody | Should Match '\$progressBar\.Style\s*=\s*\[System\.Windows\.Forms\.ProgressBarStyle\]::Marquee'
        $Script:WizardFuncBody | Should Match '\$form\.Controls\.Add\(\$progressBar\)'
    }

    It 'installer-no-progress-bar-control: the ProgressBar is added before the progress label, and both are added before the Install button (draw order / tab order sanity)' {
        $barAddIdx = $Script:WizardFuncBody.IndexOf('$form.Controls.Add($progressBar)')
        $labelAddIdx = $Script:WizardFuncBody.IndexOf('$form.Controls.Add($progressLabel)')
        $installAddIdx = $Script:WizardFuncBody.IndexOf('$form.Controls.Add($btnInstall)')

        $barAddIdx | Should BeGreaterThan -1
        $labelAddIdx | Should BeGreaterThan $barAddIdx
        $installAddIdx | Should BeGreaterThan $labelAddIdx
    }

    It 'installer-wizard-no-acceptbutton-initial-focus: AcceptButton is set to the Install button, after it exists, before any click handler runs' {
        $installAddIdx = $Script:WizardFuncBody.IndexOf('$form.Controls.Add($btnInstall)')
        $acceptIdx = $Script:WizardFuncBody.IndexOf('$form.AcceptButton = $btnInstall')
        $firstClickHandlerIdx = $Script:WizardFuncBody.IndexOf('$btnBrowse.Add_Click(')

        $installAddIdx | Should BeGreaterThan -1
        $acceptIdx | Should BeGreaterThan $installAddIdx
        $acceptIdx | Should BeLessThan $firstClickHandlerIdx
    }

    It 'installer-wizard-no-acceptbutton-initial-focus: initial focus is wired via Add_Shown (not a bare .Focus() call, which is unreliable before ShowDialog), landing on Install when a WoW root was detected and Browse otherwise' {
        $Script:WizardFuncBody | Should Match '\$form\.Add_Shown\(\{'
        $Script:WizardFuncBody | Should Match 'if\s*\(\$InitialWowRoot\)\s*\{\s*\$btnInstall\.Focus\(\)\s*\}\s*else\s*\{\s*\$btnBrowse\.Focus\(\)\s*\}'
    }

    It 'installer-wizard-no-acceptbutton-initial-focus (item 2): AcceptButton is reassigned to the Open button on the success screen, after it is added' {
        $successOpenAddIdx = $Script:WizardFuncBody.IndexOf('$form.Controls.Add($btnOpen)')
        $successAcceptIdx = $Script:WizardFuncBody.IndexOf('$form.AcceptButton = $btnOpen')

        $successOpenAddIdx | Should BeGreaterThan -1
        $successAcceptIdx | Should BeGreaterThan $successOpenAddIdx
    }

    It 'installer-wizard-no-acceptbutton-initial-focus (item 4, Escape/Cancel): CancelButton is wired to a control that closes the form' {
        $Script:WizardFuncBody | Should Match '\$form\.CancelButton\s*=\s*\$btnCancelHidden'
        $Script:WizardFuncBody | Should Match '\$btnCancelHidden\.Add_Click\(\{\s*\$form\.Close\(\)\s*\}\)'
    }

    It 'the -Console path is untouched: still the very next dispatch branch, still calls Invoke-FurphyInstallSteps directly with no wizard/WinForms construction' {
        $consoleBlockIdx = $Script:InstallSource.IndexOf('if ($Console) {')
        $consoleBlockIdx | Should Be ($Script:WizardFuncEnd + 1)
        $consoleBlockEnd = $Script:InstallSource.IndexOf('exit 0', $consoleBlockIdx)
        $consoleBlock = $Script:InstallSource.Substring($consoleBlockIdx, $consoleBlockEnd - $consoleBlockIdx)
        $consoleBlock | Should Match 'Invoke-FurphyInstallSteps'
        $consoleBlock | Should Not Match 'New-Object System\.Windows\.Forms'
    }
}

Describe 'install.ps1 Show-InstallWizard - real control construction (never shown, never ShowDialog''d)' {
    # Everything from "param([string]$InitialWowRoot)" up to (not including)
    # the first Add_Click wiring is pure control construction with no side
    # effects beyond building in-memory WinForms objects - Hide-InstallConsole
    # and $form.ShowDialog() both live textually AFTER this cut point inside
    # the same function and are never included here, so this never touches
    # the real console and never shows a window. Run once (not per-It):
    # Application.EnableVisualStyles() throws if called a second time in
    # the same process after controls already exist.
    $Script:WizardConstructionOk = $false
    $Script:WizardForm = $null
    $Script:WizardControls = $null
    $Script:WizardConstructionError = $null

    try {
        $paramIdx = $Script:WizardFuncBody.IndexOf('param([string]$InitialWowRoot)')
        $cutIdx = $Script:WizardFuncBody.IndexOf('$btnBrowse.Add_Click(')
        if ($paramIdx -lt 0 -or $cutIdx -le $paramIdx) {
            throw "could not locate the param(...)/first-Add_Click markers used to isolate the construction-only fragment (paramIdx=$paramIdx cutIdx=$cutIdx) - Show-InstallWizard's source shape changed; update the markers in this test"
        }
        $fragment = $Script:WizardFuncBody.Substring($paramIdx, $cutIdx - $paramIdx)
        $sb = [scriptblock]::Create($fragment)

        # Dot-source into THIS Describe block's scope (not a child scope)
        # so $form/$btn*/$progress* survive into the It blocks below via
        # the $Script:Wizard* copies made right after.
        . $sb -InitialWowRoot 'C:\fake\wow\root'

        $Script:WizardForm = $form
        $Script:WizardControls = [ordered]@{
            CancelHidden  = $btnCancelHidden
            Status        = $lblStatus
            Path          = $txtPath
            Browse        = $btnBrowse
            ProgressBar   = $progressBar
            ProgressLabel = $progressLabel
            Install       = $btnInstall
        }
        $Script:WizardConstructionOk = $true
    } catch {
        $Script:WizardConstructionError = $_.Exception.Message
    }

    AfterAll {
        if ($Script:WizardForm) {
            try { $Script:WizardForm.Dispose() } catch { }
        }
    }

    It 'constructs without throwing (a failure here means the extraction markers or the wizard source itself changed - see the error message)' {
        $Script:WizardConstructionError | Should BeNullOrEmpty
        $Script:WizardConstructionOk | Should Be $true
    }

    It 'installer-no-visual-styles: EnableVisualStyles ran without throwing (it throws if a Control already existed when called - proves ordering is really correct, not just textually before)' {
        $Script:WizardConstructionOk | Should Be $true
    }

    It 'installer-no-progress-bar-control: the constructed ProgressBar is really Marquee-styled and animating' {
        $Script:WizardControls.ProgressBar | Should Not BeNullOrEmpty
        $Script:WizardControls.ProgressBar.Style | Should Be ([System.Windows.Forms.ProgressBarStyle]::Marquee)
        $Script:WizardControls.ProgressBar.MarqueeAnimationSpeed | Should BeGreaterThan 0
    }

    It 'installer-wizard-no-acceptbutton-initial-focus: AcceptButton/CancelButton are really wired to the right controls' {
        $Script:WizardForm.AcceptButton | Should Be $Script:WizardControls.Install
        $Script:WizardForm.CancelButton | Should Be $Script:WizardControls.CancelHidden
    }

    It 'no clipped text at 125%/150%: no two controls overlap at the design-time (100%) logical layout' {
        <#
          installer-dpi:installer-autoscale-mode-inert-on-dpi-unaware-process
          was REJECTED this round (Appendix A) - the wizard is deliberately
          kept DPI-unaware, and Windows' own bitmap-stretch compatibility
          shim uniformly scales the whole window at 125%/150%, which
          preserves relative layout (blurrier, not clipped). So the only
          real clipping risk this progress-bar change could introduce is
          controls overlapping at the base 100% logical layout used here -
          which is exactly what this test checks.
        #>
        $controls = @($Script:WizardControls.Values)
        $overlaps = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0; $i -lt $controls.Count; $i++) {
            for ($j = $i + 1; $j -lt $controls.Count; $j++) {
                $a = $controls[$i]
                $b = $controls[$j]
                if ($a.Size.Width -eq 0 -or $a.Size.Height -eq 0 -or $b.Size.Width -eq 0 -or $b.Size.Height -eq 0) { continue }
                $aBounds = $a.Bounds
                $bBounds = $b.Bounds
                $xOverlap = ($aBounds.Left -lt $bBounds.Right) -and ($bBounds.Left -lt $aBounds.Right)
                $yOverlap = ($aBounds.Top -lt $bBounds.Bottom) -and ($bBounds.Top -lt $aBounds.Bottom)
                if ($xOverlap -and $yOverlap) {
                    $aLabel = if ($a.Name) { $a.Name } else { $a.Text }
                    $bLabel = if ($b.Name) { $b.Name } else { $b.Text }
                    $overlaps.Add("$aLabel overlaps ${bLabel}: $aBounds vs $bBounds")
                }
            }
        }
        ($overlaps -join '; ') | Should BeNullOrEmpty
    }

    It 'no clipped text at 125%/150%: every constructed control fits inside the form''s ClientSize' {
        $clientSize = $Script:WizardForm.ClientSize
        foreach ($entry in $Script:WizardControls.GetEnumerator()) {
            $c = $entry.Value
            if ($c.Size.Width -eq 0 -or $c.Size.Height -eq 0) { continue }
            $b = $c.Bounds
            ($b.Right -le $clientSize.Width) | Should Be $true
            ($b.Bottom -le $clientSize.Height) | Should Be $true
        }
    }
}
