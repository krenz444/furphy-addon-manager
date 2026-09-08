<#
  Unit tests (Pester 3 syntax): addon-server.ps1's WAGO-BROWSE-SPEC.md
  section 3.7 test-only base-URL override surface for the Wago proxy
  ($Script:WagoBaseUrl / $env:FURPHY_TEST_WAGO_BASEURL), mirroring
  tests\unit\Cli.BaseUrlOverride.Tests.ps1's own four cases for
  addon-sync.ps1's independent copy of the same seam.

  $Script:WagoBaseUrl is declared UNCONDITIONALLY near the very top of
  addon-server.ps1 (above the "safe to define unconditionally" dot-source
  guard, same section as every function definition) specifically so this
  test can dot-source the file and read it back without ever reaching the
  real "start the listener" startup body - each It sets the environment
  variable BEFORE dot-sourcing, then reads $Script:WagoBaseUrl back. Never
  makes a real HTTP call.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:AddonServerPath = Join-Path $Script:FurphyBuildRoot 'addon-server.ps1'

function Import-AddonServerForBaseUrlTest {
    <# Re-dot-sources addon-server.ps1 so the top-of-script env-var read runs again against whatever $env:FURPHY_TEST_WAGO_BASEURL is set to right now. The dot-source guard means this returns immediately after defining functions/constants - no listener, no disk/network startup work. #>
    . $Script:AddonServerPath
}

Describe 'addon-server.ps1 base-URL override (FURPHY_TEST_WAGO_BASEURL)' {

    AfterEach {
        Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue
    }

    It 'defaults to the real Wago host when the variable is not set' {
        Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue
        Import-AddonServerForBaseUrlTest

        $Script:WagoBaseUrl | Should Be 'https://addons.wago.io'
    }

    It 'a non-empty FURPHY_TEST_WAGO_BASEURL replaces $Script:WagoBaseUrl, trailing slash trimmed' {
        $env:FURPHY_TEST_WAGO_BASEURL = 'http://127.0.0.1:47958/'
        Import-AddonServerForBaseUrlTest

        $Script:WagoBaseUrl | Should Be 'http://127.0.0.1:47958'
    }

    It 'a value with no trailing slash is used as-is' {
        $env:FURPHY_TEST_WAGO_BASEURL = 'http://127.0.0.1:47959'
        Import-AddonServerForBaseUrlTest

        $Script:WagoBaseUrl | Should Be 'http://127.0.0.1:47959'
    }

    It 'an EMPTY string is ignored - falls back to the real host' {
        $env:FURPHY_TEST_WAGO_BASEURL = ''
        Import-AddonServerForBaseUrlTest

        $Script:WagoBaseUrl | Should Be 'https://addons.wago.io'
    }

    It 'a WHITESPACE-ONLY value is ignored - falls back to the real host' {
        $env:FURPHY_TEST_WAGO_BASEURL = '   '
        Import-AddonServerForBaseUrlTest

        $Script:WagoBaseUrl | Should Be 'https://addons.wago.io'
    }
}
