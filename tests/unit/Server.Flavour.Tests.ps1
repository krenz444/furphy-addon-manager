<#
  Unit tests (Pester 3 syntax): addon-server.ps1's Resolve-RequestFlavour
  (FLAVORS-SPEC.md section 5.1's explicit-query-param addressing). Points
  $Script:WowRootOverride at a fresh copy of the checked-in fixture (never
  the fixture itself) so Get-CurrentInstalledFlavours' live detection sees
  exactly the flavours the test wants.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

# A flavour-scoped endpoint (from $Script:FlavourScopedEndpoints, defined by
# addon-server.ps1 itself) and a non-scoped one, for the omitted-param tests.
$ScopedMethod = 'GET'
$ScopedPath = '/api/scan'
$NonScopedMethod = 'GET'
$NonScopedPath = '/api/ping'

function New-SettingsFile {
    param([string]$Root, $ActiveFlavour)
    $settings = Get-DefaultSettings
    if ($null -ne $ActiveFlavour) { $settings.activeFlavour = $ActiveFlavour }
    $path = Join-Path $Root 'settings.json'
    (ConvertTo-Json -InputObject $settings -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

Describe 'Resolve-RequestFlavour' {

    It 'a single-flavour machine resolves to that flavour with no ?flavour= needed at all' {
        $wowRoot = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $wowRoot '_classic_') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $wowRoot '_classic_era_') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $wowRoot '_ptr_') -Recurse -Force
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $NonScopedMethod -Path $NonScopedPath
        $r = Resolve-RequestFlavour -Context $ctx -Method $NonScopedMethod -Path $NonScopedPath
        $r.Ok | Should Be $true
        $r.Flavor | Should Be 'retail'
    }

    It 'a multi-flavour machine, ?flavour= omitted, on a FLAVOUR-SCOPED endpoint: 400 "flavour required"' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $ScopedMethod -Path $ScopedPath
        $r = Resolve-RequestFlavour -Context $ctx -Method $ScopedMethod -Path $ScopedPath
        $r.Ok | Should Be $false
        $r.StatusCode | Should Be 400
        $r.Error | Should Be 'flavour required'
    }

    It 'a multi-flavour machine, ?flavour= omitted, on a NON-scoped endpoint: falls back to settings.activeFlavour when it is installed' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour 'classic_era'

        $ctx = New-FakeHttpContext -Method $NonScopedMethod -Path $NonScopedPath
        $r = Resolve-RequestFlavour -Context $ctx -Method $NonScopedMethod -Path $NonScopedPath
        $r.Ok | Should Be $true
        $r.Flavor | Should Be 'classic_era'
    }

    It 'a multi-flavour machine, ?flavour= omitted, non-scoped endpoint, with no usable activeFlavour: falls back to the S4.1 default (retail)' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        # activeFlavour left at Get-DefaultSettings' own default ('retail'),
        # which IS installed here - still exercises the "read settings,
        # find it valid" path, distinctly from the previous test's
        # non-default value.
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $NonScopedMethod -Path $NonScopedPath
        $r = Resolve-RequestFlavour -Context $ctx -Method $NonScopedMethod -Path $NonScopedPath
        $r.Ok | Should Be $true
        $r.Flavor | Should Be 'retail'
    }

    It 'an explicit ?flavour= for an installed flavour is honored exactly, even on a scoped endpoint' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $ScopedMethod -Path $ScopedPath -Query '?flavour=classic'
        $r = Resolve-RequestFlavour -Context $ctx -Method $ScopedMethod -Path $ScopedPath
        $r.Ok | Should Be $true
        $r.Flavor | Should Be 'classic'
    }

    It 'the "flavor" alias (no u) is accepted identically to "flavour"' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $ScopedMethod -Path $ScopedPath -Query '?flavor=ptr'
        $r = Resolve-RequestFlavour -Context $ctx -Method $ScopedMethod -Path $ScopedPath
        $r.Ok | Should Be $true
        $r.Flavor | Should Be 'ptr'
    }

    It 'an explicit ?flavour= for a flavour that is NOT installed on this machine is a clean 400, never silently coerced' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $ScopedMethod -Path $ScopedPath -Query '?flavour=xptr'
        $r = Resolve-RequestFlavour -Context $ctx -Method $ScopedMethod -Path $ScopedPath
        $r.Ok | Should Be $false
        $r.StatusCode | Should Be 400
        $r.Flavor | Should Be $null
    }

    It 'a path-traversal-shaped ?flavour= value is rejected by shape alone, before the installed-list check even runs' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        $ctx = New-FakeHttpContext -Method $ScopedMethod -Path $ScopedPath -Query ('?flavour=' + [System.Uri]::EscapeDataString('../../Windows'))
        $r = Resolve-RequestFlavour -Context $ctx -Method $ScopedMethod -Path $ScopedPath
        $r.Ok | Should Be $false
        $r.StatusCode | Should Be 400
    }

    It 'an uppercase ?flavour= value is rejected by the same lowercase-only shape check' {
        $wowRoot = Copy-Fixture
        $Script:WowRootOverride = $wowRoot
        $settingsRoot = New-TempRoot -Name 'settings'
        $Script:SettingsPath = New-SettingsFile -Root $settingsRoot -ActiveFlavour $null

        # Note: Get-QueryFlavour lowercases the raw value BEFORE the shape
        # check runs, so "RETAIL" becomes "retail" (a real, installed
        # flavour) rather than being rejected - this proves that
        # normalization, not a false claim that case is rejected.
        $ctx = New-FakeHttpContext -Method $ScopedMethod -Path $ScopedPath -Query '?flavour=RETAIL'
        $r = Resolve-RequestFlavour -Context $ctx -Method $ScopedMethod -Path $ScopedPath
        $r.Ok | Should Be $true
        $r.Flavor | Should Be 'retail'
    }
}

Remove-TempRoots
