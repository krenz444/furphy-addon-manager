<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's Round 26 (hardening, item 2)
  test-only base-URL override surface (FURPHY_TEST_CF_BASEURL/
  FURPHY_TEST_WAGO_BASEURL). Each It sets the environment variable(s) it
  needs BEFORE dot-sourcing addon-sync.ps1 (the assignment that reads them
  runs unconditionally near the top of the file, before the dot-source
  guard), then reads back $script:CfBaseUrl/$script:WagoBaseUrl - never
  makes a real HTTP call itself.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:AddonSyncPath = Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1'

function Import-AddonSyncForBaseUrlTest {
    <# Re-dot-sources addon-sync.ps1 so the top-of-script env-var read runs again against whatever $env:FURPHY_TEST_* is set to right now. #>
    . $Script:AddonSyncPath
}

Describe 'addon-sync.ps1 base-URL override (FURPHY_TEST_CF_BASEURL / FURPHY_TEST_WAGO_BASEURL)' {

    AfterEach {
        Remove-Item Env:\FURPHY_TEST_CF_BASEURL -ErrorAction SilentlyContinue
        Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue
    }

    It 'defaults to the real CurseForge/Wago hosts when neither variable is set' {
        Remove-Item Env:\FURPHY_TEST_CF_BASEURL -ErrorAction SilentlyContinue
        Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue
        Import-AddonSyncForBaseUrlTest

        $script:CfBaseUrl | Should Be 'https://www.curseforge.com'
        $script:WagoBaseUrl | Should Be 'https://addons.wago.io'
    }

    It 'a non-empty FURPHY_TEST_CF_BASEURL replaces $script:CfBaseUrl, trailing slash trimmed' {
        $env:FURPHY_TEST_CF_BASEURL = 'http://127.0.0.1:47955/'
        Import-AddonSyncForBaseUrlTest

        $script:CfBaseUrl | Should Be 'http://127.0.0.1:47955'
    }

    It 'a non-empty FURPHY_TEST_WAGO_BASEURL replaces $script:WagoBaseUrl, trailing slash trimmed' {
        $env:FURPHY_TEST_WAGO_BASEURL = 'http://127.0.0.1:47956/'
        Import-AddonSyncForBaseUrlTest

        $script:WagoBaseUrl | Should Be 'http://127.0.0.1:47956'
    }

    It 'an EMPTY string FURPHY_TEST_CF_BASEURL is ignored - falls back to the real host' {
        $env:FURPHY_TEST_CF_BASEURL = ''
        Import-AddonSyncForBaseUrlTest

        $script:CfBaseUrl | Should Be 'https://www.curseforge.com'
    }

    It 'a WHITESPACE-ONLY FURPHY_TEST_CF_BASEURL is ignored - falls back to the real host' {
        $env:FURPHY_TEST_CF_BASEURL = '   '
        Import-AddonSyncForBaseUrlTest

        $script:CfBaseUrl | Should Be 'https://www.curseforge.com'
    }

    It 'an EMPTY string FURPHY_TEST_WAGO_BASEURL is ignored - falls back to the real host' {
        $env:FURPHY_TEST_WAGO_BASEURL = ''
        Import-AddonSyncForBaseUrlTest

        $script:WagoBaseUrl | Should Be 'https://addons.wago.io'
    }

    It 'setting one override does not disturb the other (independent variables)' {
        $env:FURPHY_TEST_CF_BASEURL = 'http://127.0.0.1:47957'
        Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue
        Import-AddonSyncForBaseUrlTest

        $script:CfBaseUrl | Should Be 'http://127.0.0.1:47957'
        $script:WagoBaseUrl | Should Be 'https://addons.wago.io'
    }
}
