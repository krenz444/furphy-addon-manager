<#
=====================================================================
 tests\integration\Setup.Build.Tests.ps1

 SETUP-SPEC.md section 12.1: headless build test for setup\build-setup.ps1
 - the one-file GUI installer build script (Package A: setup\FurphySetup.cs
 / setup\build-setup.ps1) that embeds the release zip and, at runtime,
 launches install.ps1 hidden behind its own splash window. Runs the REAL
 build script against this build root's REAL dist\ folder - a build step,
 exactly like tests\host\Host.Tests.ps1 already builds host\bin\
 FurphyHost.exe into the real host\bin\, never a scratch copy - so no
 window, no registry, and no WoW fixture are ever touched here.

 Asserts (SETUP-SPEC.md section 12.1, verbatim):
   - dist\FurphyAddonManager-Setup-<ver>.exe and the stable
     dist\FurphyAddonManager-Setup.exe both exist, are non-trivial size,
     start with the PE header magic bytes "MZ", and are byte-identical to
     each other (section 6.1's "second, identically-named asset" copy).
   - a .sha256 sidecar exists for the VERSIONED exe only (never the
     stable-named copy - package.ps1's own established convention,
     mirrored by setup\build-setup.ps1 per section 6.1) and, after
     lowercasing both sides (Get-FileHash returns uppercase hex; every
     sidecar this project writes is lowercase - package.ps1:177's own
     .ToLowerInvariant(), mirrored here), matches Get-FileHash of the exe.
   - FileVersionInfo on the built exe (ProductName/FileDescription/
     ProductVersion) is non-empty and the ProductVersion names this
     build's real version - the only place in the whole test plan that
     exercises the __FURPHY_SETUP_VERSION__ token substitution and the
     AssemblyProduct/AssemblyTitle/AssemblyDescription attributes at all
     (section 4.8); a silently-failed token swap would pass every other
     check in this file without it.

 $Script:Version is read from the real VERSION file at test time, never
 hardcoded - this file works unchanged across a version bump mid-round
 (confirmed live during this round: VERSION moved under this file's own
 feet while it was being written).

 Reads the real dist\FurphyAddonManager-<ver>.zip package.ps1 already
 built (and its .sha256 sidecar) as the payload input - if that pair is
 missing for the CURRENT VERSION contents, this file builds it itself by
 invoking the real package.ps1 (a normal build step, not an edit to that
 file) so this test works on a fresh checkout too.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:SetupBuildScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'setup\build-setup.ps1'
$Script:DistDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'dist'
$Script:VersionPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'VERSION'
$Script:Version = ''
if (Test-Path -LiteralPath $Script:VersionPath -PathType Leaf) {
    $Script:Version = ([System.IO.File]::ReadAllText($Script:VersionPath)).Trim()
}

Describe 'setup\build-setup.ps1 - prerequisites' {
    It 'setup\build-setup.ps1 is present (Package A)' {
        (Test-Path -LiteralPath $Script:SetupBuildScript -PathType Leaf) | Should Be $true
    }
    It 'VERSION is present and non-empty' {
        $Script:Version | Should Not BeNullOrEmpty
    }
}

$Script:HavePrereqs = (Test-Path -LiteralPath $Script:SetupBuildScript -PathType Leaf) -and [bool]$Script:Version

if ($Script:HavePrereqs) {

    $Script:PayloadZipPath = Join-Path -Path $Script:DistDir -ChildPath ("FurphyAddonManager-{0}.zip" -f $Script:Version)
    $Script:PayloadShaPath = "$Script:PayloadZipPath.sha256"

    # package.ps1 builds the versioned zip (and its sha256 sidecar) that
    # setup\build-setup.ps1 embeds as FurphyPayload.zip (SETUP-SPEC.md
    # section 6.1: "byte-for-byte same dist\...zip package.ps1 already
    # built... never a second, separately-assembled file list"). If a
    # concurrent VERSION bump has outrun the last package.ps1 run, build it
    # now - a normal build invocation, not an edit to package.ps1.
    if (-not ((Test-Path -LiteralPath $Script:PayloadZipPath -PathType Leaf) -and (Test-Path -LiteralPath $Script:PayloadShaPath -PathType Leaf))) {
        $Script:PackageScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'package.ps1'
        Write-Host "  (dist\FurphyAddonManager-$($Script:Version).zip missing - running package.ps1 to build it)"
        $pkgResult = Invoke-CliProcess -ScriptPath $Script:PackageScript -ArgumentList @('-Source', $Script:FurphyBuildRoot, '-DistDir', $Script:DistDir) -TimeoutSec 180
        if ($pkgResult.ExitCode -ne 0) {
            Write-Host "package.ps1 STDOUT:`n$($pkgResult.StdOut)"
            Write-Host "package.ps1 STDERR:`n$($pkgResult.StdErr)"
        }
    }

    $Script:VersionedExePath = Join-Path -Path $Script:DistDir -ChildPath ("FurphyAddonManager-Setup-{0}.exe" -f $Script:Version)
    $Script:StableExePath = Join-Path -Path $Script:DistDir -ChildPath 'FurphyAddonManager-Setup.exe'
    $Script:ShaPath = "$Script:VersionedExePath.sha256"
    $Script:StableShaPath = "$Script:StableExePath.sha256"

    Describe 'setup\build-setup.ps1 - real build against this build root (SETUP-SPEC.md 12.1)' {

        It 'the real payload zip and its sha256 sidecar exist for the current VERSION' {
            (Test-Path -LiteralPath $Script:PayloadZipPath -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath $Script:PayloadShaPath -PathType Leaf) | Should Be $true
        }

        It 'runs to completion (exit 0)' {
            $r = Invoke-CliProcess -ScriptPath $Script:SetupBuildScript -ArgumentList @('-Version', $Script:Version, '-DistDir', $Script:DistDir) -TimeoutSec 180
            if ($r.ExitCode -ne 0) {
                Write-Host "STDOUT:`n$($r.StdOut)"
                Write-Host "STDERR:`n$($r.StdErr)"
            }
            $r.ExitCode | Should Be 0
        }

        It 'produces the versioned exe: exists, non-trivial size, PE header MZ' {
            (Test-Path -LiteralPath $Script:VersionedExePath -PathType Leaf) | Should Be $true
            (Get-Item -LiteralPath $Script:VersionedExePath).Length | Should BeGreaterThan 10KB
            $bytes = [System.IO.File]::ReadAllBytes($Script:VersionedExePath)
            $bytes.Length | Should BeGreaterThan 1
            [char]$bytes[0] | Should Be 'M'
            [char]$bytes[1] | Should Be 'Z'
        }

        It 'produces the stable-named exe: exists, non-trivial size, PE header MZ, byte-identical to the versioned exe' {
            (Test-Path -LiteralPath $Script:StableExePath -PathType Leaf) | Should Be $true
            (Get-Item -LiteralPath $Script:StableExePath).Length | Should BeGreaterThan 10KB
            $bytes = [System.IO.File]::ReadAllBytes($Script:StableExePath)
            [char]$bytes[0] | Should Be 'M'
            [char]$bytes[1] | Should Be 'Z'

            $versionedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Script:VersionedExePath).Hash
            $stableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Script:StableExePath).Hash
            $stableHash | Should Be $versionedHash
        }

        It 'writes a .sha256 sidecar for the VERSIONED exe only, lowercase, matching Get-FileHash' {
            (Test-Path -LiteralPath $Script:ShaPath -PathType Leaf) | Should Be $true
            # Never a sidecar for the stable-named copy - mirrors
            # package.ps1's own established rule (section 6.1): "since
            # nothing needs to verify them by fixed name".
            (Test-Path -LiteralPath $Script:StableShaPath -PathType Leaf) | Should Be $false

            $sidecar = (Get-Content -Raw -LiteralPath $Script:ShaPath).Trim()
            $sidecar | Should Be $sidecar.ToLowerInvariant()

            $real = (Get-FileHash -Algorithm SHA256 -LiteralPath $Script:VersionedExePath).Hash.ToLowerInvariant()
            $sidecar | Should Be $real
        }

        It 'sets real version info on the built exe (section 4.8 token substitution)' {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Script:VersionedExePath)
            $vi.ProductName | Should Not BeNullOrEmpty
            $vi.FileDescription | Should Not BeNullOrEmpty
            $vi.ProductVersion | Should Not BeNullOrEmpty
            # __FURPHY_SETUP_VERSION__ swapped for VERSION's own content
            # (section 4.8) - the ProductVersion string must therefore
            # contain the real version, not the literal placeholder token
            # and not a blank default.
            $vi.ProductVersion | Should Match ([regex]::Escape($Script:Version))
            $vi.ProductVersion | Should Not Match 'FURPHY_SETUP_VERSION'
        }
    }
} else {
    Write-Host 'SKIPPING the real-build Describe: setup\build-setup.ps1 or VERSION missing (see the prerequisites Describe above).'
}
