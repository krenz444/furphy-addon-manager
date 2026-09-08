<#
=====================================================================
 tests\integration\Install.PackageUiAllowList.Tests.ps1

 upgrade-1.1.0:upgrade-1.1.0-package-ships-stray-dev-log regression test.

 The real dist\FurphyAddonManager-1.1.0.zip shipped ui\server47896.log - a
 leftover Python http.server access log from a developer's local test
 session - because package.ps1's ui\ copy used an unfiltered
 Copy-Item -Recurse with no exclude/allow-list at all. package.ps1 now
 walks ui\ with an explicit file-extension allow-list, mirroring
 $rootFiles' own allow-list philosophy.

 Named Install.* (not Package.*) per this build round's file-scoping rule
 for the installer fixer's test files. Stages a FAKE ui\ source directory
 under tests\.tmp\ - never touches the real ui\ or the real dist\.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:PackageScript = Join-Path $Script:FurphyBuildRoot 'package.ps1'

Describe 'package.ps1 ui\ allow-list (upgrade-1.1.0:upgrade-1.1.0-package-ships-stray-dev-log)' {

    It 'ships every allow-listed ui\ file (subfolders included) but never a stray dev-log or tmp file' {
        $fakeSrc = New-TempRoot -Name 'package-ui-allowlist-src'
        $distDir = New-TempRoot -Name 'package-ui-allowlist-dist'

        New-Item -ItemType Directory -Force -Path (Join-Path $fakeSrc 'ui\icons') | Out-Null
        '1.0.0' | Set-Content -LiteralPath (Join-Path $fakeSrc 'VERSION') -Encoding Ascii -NoNewline
        '<html></html>' | Set-Content -LiteralPath (Join-Path $fakeSrc 'ui\index.html') -Encoding Ascii
        'body{}' | Set-Content -LiteralPath (Join-Path $fakeSrc 'ui\style.css') -Encoding Ascii
        'console.log(1)' | Set-Content -LiteralPath (Join-Path $fakeSrc 'ui\app.js') -Encoding Ascii
        'fake icon bytes' | Set-Content -LiteralPath (Join-Path $fakeSrc 'ui\icons\furphy-32.png') -Encoding Ascii
        # The exact repro shape from the real 1.1.0 leak: a dev http.server
        # access log, plus a generic scratch .tmp file for good measure.
        'GET /?mock=1 200' | Set-Content -LiteralPath (Join-Path $fakeSrc 'ui\server47896.log') -Encoding Ascii
        'scratch notes' | Set-Content -LiteralPath (Join-Path $fakeSrc 'ui\notes.tmp') -Encoding Ascii

        try {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:PackageScript -Source $fakeSrc -DistDir $distDir 2>&1
            $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
            $LASTEXITCODE | Should Be 0

            # Warns about both disallowed files by name.
            $text | Should Match 'server47896\.log'
            $text | Should Match 'notes\.tmp'

            $zipPath = Join-Path $distDir 'FurphyAddonManager-1.0.0.zip'
            (Test-Path -LiteralPath $zipPath) | Should Be $true

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $entries = @($zip.Entries | ForEach-Object { $_.FullName })
            } finally {
                $zip.Dispose()
            }

            # Allow-listed files present, subfolder structure preserved.
            ($entries -contains 'ui\index.html') | Should Be $true
            ($entries -contains 'ui\style.css') | Should Be $true
            ($entries -contains 'ui\app.js') | Should Be $true
            ($entries -contains 'ui\icons\furphy-32.png') | Should Be $true

            # Disallowed files absent from the zip entirely.
            (@($entries | Where-Object { $_ -match 'server47896' }).Count) | Should Be 0
            (@($entries | Where-Object { $_ -match 'notes\.tmp' }).Count) | Should Be 0
        } finally {
            if (Test-Path -LiteralPath $fakeSrc) { Remove-Item -LiteralPath $fakeSrc -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $distDir) { Remove-Item -LiteralPath $distDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
