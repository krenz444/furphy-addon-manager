<#
=====================================================================
 tests\unit\Setup.NoArpWrite.Tests.ps1

 SETUP-SPEC.md section 12.4: static "no Add/Remove Programs entry (or
 shortcut) of its own" regression guard for setup\FurphySetup.cs.

 FurphySetup.exe has exactly four responsibilities (SETUP-SPEC.md
 section 4): show a splash, extract the embedded payload, launch
 install.ps1, relay its exit code. It must never itself write a
 registry key, a shortcut, or an Add/Remove Programs entry - all of
 that stays install.ps1's job (Get-InstallAppsKeyName /
 Invoke-FurphyInstallSteps' own "9. Installed-Apps registration" step),
 exactly as it already is for a manual double-click install.

 A live, fixture-acceptance-style "assert exactly one ARP entry after a
 real install/upgrade" test is the WRONG-strength tool for THIS design
 (SETUP-SPEC.md section 12.4's own reasoning): that graft fits an
 architecture where a third-party installer framework's own default
 behavior is to register its own ARP entry. FurphySetup.cs registers
 nothing of its own by construction, so the correctly-scoped guard is a
 plain source-text regression test - zero registry writes, zero window,
 zero WoW fixture, and it fails the instant a future edit ever adds
 direct ARP/shortcut registration to FurphySetup.cs (the live,
 end-to-end twin of this check - "exactly one Add/Remove entry" after a
 real install and a real re-install/upgrade - lives in
 tests\integration\Setup.SilentInstall.Tests.ps1, since that one
 legitimately needs a real scratch install to mean anything).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:FurphySetupCsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'setup\FurphySetup.cs'
$Script:FurphySetupSource = ''
if (Test-Path -LiteralPath $Script:FurphySetupCsPath -PathType Leaf) {
    $Script:FurphySetupSource = Get-Content -Raw -LiteralPath $Script:FurphySetupCsPath
}

Describe 'setup\FurphySetup.cs is present and readable (Package A)' {
    It 'setup\FurphySetup.cs exists' {
        (Test-Path -LiteralPath $Script:FurphySetupCsPath -PathType Leaf) | Should Be $true
    }
    It 'setup\FurphySetup.cs is non-empty' {
        $Script:FurphySetupSource.Length | Should BeGreaterThan 0
    }
}

Describe 'setup\FurphySetup.cs never writes an Add/Remove Programs entry or a shortcut of its own (SETUP-SPEC.md 12.4)' {

    It 'contains no Registry.CurrentUser (no registry hive access at all)' {
        $Script:FurphySetupSource.Contains('Registry.CurrentUser') | Should Be $false
    }

    It 'contains no RegistryKey (no registry key type usage at all)' {
        $Script:FurphySetupSource.Contains('RegistryKey') | Should Be $false
    }

    It 'contains no CreateSubKey (no registry key creation)' {
        $Script:FurphySetupSource.Contains('CreateSubKey') | Should Be $false
    }

    It 'contains no "Uninstall\" ARP registry path fragment' {
        # Written as it would appear in C# source text (one logical
        # backslash is two characters, \\, in a C# string literal) -
        # install.ps1's own Add/Remove Programs path is
        # 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
        # <key name>; this fragment is the tell-tale substring of that
        # path appearing anywhere in FurphySetup.cs.
        $Script:FurphySetupSource.Contains('Uninstall\\') | Should Be $false
    }

    It 'contains no CreateShortcut (no .lnk creation API)' {
        $Script:FurphySetupSource.Contains('CreateShortcut') | Should Be $false
    }

    It 'contains no WshShell (no WScript.Shell COM shortcut API)' {
        $Script:FurphySetupSource.Contains('WshShell') | Should Be $false
    }
}
