<#
=====================================================================
 tests\integration\Setup.PayloadContents.Tests.ps1

 SETUP-SPEC.md section 12.3: static embedded-payload identity check.
 Headless, no execution of the built FurphyAddonManager-Setup-<ver>.exe
 at all - never runs it, no window, no registry, no WoW fixture.

 Loads the built exe via [System.Reflection.Assembly]::LoadFrom, reads
 its embedded FurphyPayload.zip manifest resource, hashes those bytes,
 and asserts the hash equals the already-lowercase content of
 dist\FurphyAddonManager-<ver>.zip.sha256 - proving the embedded payload
 is byte-identical to the already-integrity-checked release zip
 (SETUP-SPEC.md section 6.1: "byte-for-byte same... never a second,
 separately-assembled file list"), without ever extracting anything.

 Loaded from a COPY under tests\.tmp\ (New-TempRoot), never the dist\
 original directly - Assembly.LoadFrom locks the file for the life of
 this process, and dist\ is a real build artifact another process (a
 concurrent package.ps1/setup\build-setup.ps1 run) may want to
 overwrite. The copy itself is left in tests\.tmp\ afterward (Assembly
 load locks prevent deleting it from inside the same process on Windows
 PowerShell 5.1 - there is no AppDomain unload available here); harmless
 scratch, swept the same way every other tests\.tmp\ leftover is.

 Depends on Setup.Build.Tests.ps1 having produced a real
 dist\FurphyAddonManager-Setup-<ver>.exe - builds it itself (a normal
 build invocation of setup\build-setup.ps1, not an edit to it) if
 missing, so this file also works run on its own.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:SetupBuildScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'setup\build-setup.ps1'
$Script:DistDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'dist'
$Script:VersionPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'VERSION'
$Script:Version = ''
if (Test-Path -LiteralPath $Script:VersionPath -PathType Leaf) {
    $Script:Version = ([System.IO.File]::ReadAllText($Script:VersionPath)).Trim()
}

Describe 'Setup.PayloadContents - prerequisites' {
    It 'setup\build-setup.ps1 is present (Package A)' {
        (Test-Path -LiteralPath $Script:SetupBuildScript -PathType Leaf) | Should Be $true
    }
    It 'VERSION is present and non-empty' {
        $Script:Version | Should Not BeNullOrEmpty
    }
}

$Script:HavePrereqs = (Test-Path -LiteralPath $Script:SetupBuildScript -PathType Leaf) -and [bool]$Script:Version

if ($Script:HavePrereqs) {

    $Script:VersionedExePath = Join-Path -Path $Script:DistDir -ChildPath ("FurphyAddonManager-Setup-{0}.exe" -f $Script:Version)
    $Script:PayloadZipPath = Join-Path -Path $Script:DistDir -ChildPath ("FurphyAddonManager-{0}.zip" -f $Script:Version)
    $Script:PayloadShaPath = "$Script:PayloadZipPath.sha256"

    if (-not ((Test-Path -LiteralPath $Script:PayloadZipPath -PathType Leaf) -and (Test-Path -LiteralPath $Script:PayloadShaPath -PathType Leaf))) {
        $Script:PackageScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'package.ps1'
        Write-Host "  (dist\FurphyAddonManager-$($Script:Version).zip missing - running package.ps1 to build it)"
        Invoke-CliProcess -ScriptPath $Script:PackageScript -ArgumentList @('-Source', $Script:FurphyBuildRoot, '-DistDir', $Script:DistDir) -TimeoutSec 180 | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Script:VersionedExePath -PathType Leaf)) {
        Write-Host "  (dist\FurphyAddonManager-Setup-$($Script:Version).exe missing - running setup\build-setup.ps1 to build it)"
        Invoke-CliProcess -ScriptPath $Script:SetupBuildScript -ArgumentList @('-Version', $Script:Version, '-DistDir', $Script:DistDir) -TimeoutSec 180 | Out-Null
    }

    Describe 'FurphyAddonManager-Setup-<ver>.exe embedded payload identity (SETUP-SPEC.md 12.3)' {

        It 'the built Setup.exe and the payload zip + sha256 sidecar all exist' {
            (Test-Path -LiteralPath $Script:VersionedExePath -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath $Script:PayloadZipPath -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath $Script:PayloadShaPath -PathType Leaf) | Should Be $true
        }

        It 'the embedded FurphyPayload.zip resource is byte-identical to dist\FurphyAddonManager-<ver>.zip (matches its own already-verified sha256 sidecar)' {
            $copyRoot = New-TempRoot -Name 'setup-payload-check'
            $exeCopy = Join-Path -Path $copyRoot -ChildPath (Split-Path -Path $Script:VersionedExePath -Leaf)
            Copy-Item -LiteralPath $Script:VersionedExePath -Destination $exeCopy -Force

            $asm = [System.Reflection.Assembly]::LoadFrom($exeCopy)
            $names = @($asm.GetManifestResourceNames())
            # The /resource:<file>,FurphyPayload.zip compiler syntax (section
            # 6.1) names the manifest resource exactly "FurphyPayload.zip"
            # with no namespace prefix - try that literal name first, and
            # fall back to a suffix match only so a minor, still-correct
            # naming difference in the real build doesn't false-fail this
            # test for the wrong reason.
            $resourceName = $null
            if ($names -contains 'FurphyPayload.zip') {
                $resourceName = 'FurphyPayload.zip'
            } else {
                $resourceName = @($names | Where-Object { $_ -like '*FurphyPayload.zip' } | Select-Object -First 1)
            }
            $resourceName | Should Not BeNullOrEmpty

            $stream = $asm.GetManifestResourceStream($resourceName)
            $stream | Should Not BeNullOrEmpty
            try {
                $embeddedHash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
            } finally {
                $stream.Dispose()
            }

            $expected = (Get-Content -Raw -LiteralPath $Script:PayloadShaPath).Trim().ToLowerInvariant()
            $embeddedHash | Should Be $expected

            # Belt-and-suspenders: also confirm the sidecar itself is
            # actually right about the real zip on disk right now (catches
            # a stale/mismatched sidecar making this test pass for the
            # wrong reason).
            $realZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Script:PayloadZipPath).Hash.ToLowerInvariant()
            $expected | Should Be $realZipHash
        }
    }
} else {
    Write-Host 'SKIPPING the payload-identity Describe: setup\build-setup.ps1 or VERSION missing (see the prerequisites Describe above).'
}
