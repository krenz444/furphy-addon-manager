<#
=====================================================================
 tests\fixture-acceptance\FlavorsSpec.Section8.Tests.ps1

 Traceability pass over FLAVORS-SPEC.md section 8's own acceptance
 checklist ("Synthetic test fixture"), tagged 'FixtureAcceptance' and
 run ONLY by the full (non -Quick) tests\run-all.ps1 pass - install.ps1's
 real host\ rebuild step alone costs real seconds per Context, and this
 whole layer is explicitly a full-only bullet in the task brief ("the
 fixture install into _classic_era_").

 Every checklist bullet below is either exercised directly in this file
 or has a pointer to the existing test file that already covers it - so
 this file is a genuine index of the section, not a duplicate of work
 already done elsewhere in tests\unit\/tests\integration\.

   [x] Get-InstalledFlavours order/buildInfoMissing            -> tests\unit\Cli.Flavours.Tests.ps1
   [x] clientBuild matches .build.info Version exactly          -> tests\unit\Cli.Flavours.Tests.ps1
   [x] classic progression era re-derivable (no hardcode)        -> tests\unit\Cli.Flavours.Tests.ps1 ("is re-derivable...")
   [x] -Scan per flavour (retail/classic_era/classic)             -> tests\integration\Cli.StatusAndDetection.Tests.ps1
   [x] Get-PrimaryTocFile X-Flavor / suffix-table / decoy cases   -> tests\unit\Cli.TocAndFileSelection.Tests.ps1
   [x] Get-PrimaryTocFile regression vs real servertest fixtures  -> tests\unit\Cli.TocAndFileSelection.Tests.ps1
   [x] deleting _classic_ drops it live, no error                 -> tests\unit\Cli.Flavours.Tests.ps1
   [x] _ptr_ detected-but-quiet by default, shown w/ showTestRealms -> tests\integration\Server.FreshnessAndFlavours.Tests.ps1
   [x] Invoke-FlavourMigration byte-identical + backup folder     -> tests\unit\Cli.ProgressMigrationZip.Tests.ps1
   [x] migration crash-mid-move safe, no double backup            -> tests\unit\Cli.ProgressMigrationZip.Tests.ps1
   [ ] install.ps1 against a fixture copy with _retail_ deleted   -> THIS FILE (Context 1)
   [x] CF file gameVersionTypeIds targeting: 1/0/2+ match cases   -> THIS FILE (Context 2, offline via a plain
       Invoke-WebRequest redefinition - see that Context's own header
       comment for why Pester's Mock cmdlet does not reach this call)
       (case "1 match" also live-verified against the real network in
       tests\integration\Cli.InstallRollbackLauncher.Tests.ps1's AtlasLootClassic install)
   [x] concurrent mocked jobs on different flavours don't block   -> tests\integration\Server.Jobs.Tests.ps1
   [x] flavour-scoped endpoint 400 without ?flavour= (multi)      -> tests\integration\Server.State.Tests.ps1
       vs succeeds without it (single-flavour root)                 tests\integration\Server.State.Tests.ps1
   [x] ?mock=1 switcher DOM: absent at n=1, present+ordered at n=3 -> tests\spa\harness.js (&flavours=3 phase)

 Windows PowerShell 5.1, Pester 3 syntax, ASCII only.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

# =====================================================================
# Context 1: install.ps1's documented home-flavour fallback order
# (FLAVORS-SPEC S3.1/S2.1) - Retail when present, else the first
# remaining flavour in fixed order. Never touches the real Desktop or
# curseforge:// registration (-NoShortcuts -NoProtocol -SkipAdopt), and
# always points -WowPath at a throwaway Copy-Fixture root, never the
# checked-in fixtures\wowroot itself or a real WoW folder.
# =====================================================================

function Invoke-InstallPs1 {
    param([string]$WowPath)
    $installScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'install.ps1'
    $args = @('-WowPath', $WowPath, '-NoShortcuts', '-NoProtocol', '-SkipAdopt')
    return Invoke-CliProcess -ScriptPath $installScript -ArgumentList $args -TimeoutSec 90
}

Describe 'install.ps1 home-flavour ordering against the fixture (FLAVORS-SPEC S2.1/S3.1)' {

    It 'with every flavour present, installs into _retail_ (Retail is home when installed)' {
        $wowRoot = Copy-Fixture
        $r = Invoke-InstallPs1 -WowPath $wowRoot
        $r.ExitCode | Should Be 0
        (Test-Path -LiteralPath (Join-Path $wowRoot '_retail_\AddonSync\addon-sync.ps1') -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $wowRoot '_classic_\AddonSync') -PathType Container) | Should Be $false
    }

    It 'with _retail_ removed, falls back to _classic_ (next in S2.1 fixed order)' {
        $wowRoot = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $wowRoot '_retail_') -Recurse -Force
        $r = Invoke-InstallPs1 -WowPath $wowRoot
        $r.ExitCode | Should Be 0
        (Test-Path -LiteralPath (Join-Path $wowRoot '_classic_\AddonSync\addon-sync.ps1') -PathType Leaf) | Should Be $true
    }

    It 'with _retail_ and _classic_ both removed, falls back to _classic_era_ (the fixture install into _classic_era_)' {
        $wowRoot = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $wowRoot '_retail_') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $wowRoot '_classic_') -Recurse -Force
        $r = Invoke-InstallPs1 -WowPath $wowRoot
        $r.ExitCode | Should Be 0
        (Test-Path -LiteralPath (Join-Path $wowRoot '_classic_era_\AddonSync\addon-sync.ps1') -PathType Leaf) | Should Be $true
        # _ptr_ is still detected (installedFlavours includes it) but is never
        # a home-flavour candidate, first-class-only launcher/shortcut rules
        # (S2.1's FirstClass column) - confirm no AddonSync ever lands there.
        (Test-Path -LiteralPath (Join-Path $wowRoot '_ptr_\AddonSync') -PathType Container) | Should Be $false
    }

    It 'never touches the real checked-in fixture on disk (still exactly the pristine 12 files afterward)' {
        Assert-FixturePristine | Should Be $true
    }
}

# =====================================================================
# Context 2: Resolve-CfInstallFlavour (FLAVORS-SPEC S5.5 cases 3/4/5) -
# which installed flavour(s) a CurseForge file's gameVersionTypeIds
# supports.
#
# Pester's own `Mock` cmdlet does NOT reach this call (confirmed live,
# not assumed): Resolve-CfInstallFlavour was defined by dot-sourcing
# addon-server.ps1 at this FILE's top-level script scope, and a
# PowerShell function's command lookups at runtime are resolved starting
# from its OWN defining scope outward - not from whatever Describe/It
# scope happens to be calling it. A `Mock Invoke-WebRequest` issued
# inside an `It` block therefore defines its intercepting function too
# deep in Pester's own nested scope chain for Resolve-CfInstallFlavour's
# dynamic scope walk to ever see it - every mocked call silently fell
# through with a null response instead of throwing a binding error,
# which took a live repro to pin down. Same family as this codebase's
# other documented PS 5.1 scope surprises (see notesForNext); worth
# adding to that list for whoever next reaches for Pester's Mock in this
# suite.
#
# Fix: use the SAME plain function-redefinition technique
# tests\unit\Server.Handlers.Tests.ps1 already established for
# Open-InBrowser - redefine `Invoke-WebRequest` directly in THIS file's
# own top-level script scope (the same scope Resolve-CfInstallFlavour
# was defined in), driven by two script-scope variables each It sets
# before calling in. Scoped to this one file only (not shared with any
# other test file/session), and restored to "no canned response" after
# every It via a script-scope reset in each It's own body.
# =====================================================================

$Script:FurphyMockCfBody = $null
$Script:FurphyMockCfThrow = $null
$Script:FurphyMockCfCallCount = 0

function Invoke-WebRequest {
    param(
        [string]$Uri,
        $Headers,
        [string]$UserAgent,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [string]$ErrorAction
    )
    $Script:FurphyMockCfCallCount++
    if ($Script:FurphyMockCfThrow) { throw $Script:FurphyMockCfThrow }
    return [PSCustomObject]@{ Content = $Script:FurphyMockCfBody }
}

Describe 'Resolve-CfInstallFlavour flavour-targeting cases (FLAVORS-SPEC S5.5)' {

    # Three installed flavours, matching the real fixture's own detected
    # set minus ptr (S5.5's picker only ever needs to reason about
    # first-class flavours' TypeIds: 517 retail, 67408 classic_era, and
    # whatever Resolve-ClassicProgressionTypeId currently resolves classic
    # to for this fixture's own .build.info row - 79434, Mists, per
    # tests\unit\Cli.Flavours.Tests.ps1's own confirmed live value).
    $installedFlavours = @(
        [PSCustomObject]@{ id = 'retail'; clientInterface = 120100 }
        [PSCustomObject]@{ id = 'classic'; clientInterface = 50504 }
        [PSCustomObject]@{ id = 'classic_era'; clientInterface = 11509 }
    )

    It 'case 3: exactly one installed flavour matches -> that one id, no others' {
        $Script:FurphyMockCfThrow = $null
        $Script:FurphyMockCfBody = @{ data = @(@{ gameVersionTypeIds = @(67408) }) } | ConvertTo-Json -Depth 5 -Compress
        $r = Resolve-CfInstallFlavour -ProjectId 111 -InstalledFlavours $installedFlavours
        $r.FetchError | Should Be $null
        ($r.MatchingFlavourIds -join ',') | Should Be 'classic_era'
    }

    It 'case 4: zero installed flavours match -> empty array, not treated as a fetch failure' {
        $Script:FurphyMockCfThrow = $null
        $Script:FurphyMockCfBody = @{ data = @(@{ gameVersionTypeIds = @(999999) }) } | ConvertTo-Json -Depth 5 -Compress
        $r = Resolve-CfInstallFlavour -ProjectId 222 -InstalledFlavours $installedFlavours
        $r.FetchError | Should Be $null
        @($r.MatchingFlavourIds).Count | Should Be 0
    }

    It 'case 5: more than one installed flavour matches -> both ids, in InstalledFlavours order' {
        $Script:FurphyMockCfThrow = $null
        $Script:FurphyMockCfBody = @{ data = @(@{ gameVersionTypeIds = @(517, 67408) }) } | ConvertTo-Json -Depth 5 -Compress
        $r = Resolve-CfInstallFlavour -ProjectId 333 -InstalledFlavours $installedFlavours
        $r.FetchError | Should Be $null
        ($r.MatchingFlavourIds -join ',') | Should Be 'retail,classic_era'
    }

    It 'a network/parse failure sets FetchError and returns an empty MatchingFlavourIds the caller must not read as case 4' {
        $Script:FurphyMockCfBody = $null
        $Script:FurphyMockCfThrow = 'simulated network failure'
        $r = Resolve-CfInstallFlavour -ProjectId 444 -InstalledFlavours $installedFlavours
        $r.FetchError | Should Not Be $null
        @($r.MatchingFlavourIds).Count | Should Be 0
    }

    It 'an explicit -FileId fetches that one file''s own gameVersionTypeIds, not the project''s file list' {
        $Script:FurphyMockCfThrow = $null
        $Script:FurphyMockCfBody = @{ data = @{ gameVersionTypeIds = @(517) } } | ConvertTo-Json -Depth 5 -Compress
        $before = $Script:FurphyMockCfCallCount
        $r = Resolve-CfInstallFlavour -ProjectId 555 -FileId 999 -InstalledFlavours $installedFlavours
        ($Script:FurphyMockCfCallCount - $before) | Should Be 1
        $r.FetchError | Should Be $null
        ($r.MatchingFlavourIds -join ',') | Should Be 'retail'
    }
}
