<#
  Static check: every .ps1/.cs file the app ships (root, host\, tests\,
  fixtures\) is pure ASCII (no byte >= 128) - a hard PS 5.1/C# 5 project
  rule (SPEC.md: "pure ASCII source files").
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:ascii-scan'

function Test-FileIsAscii {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ge 128) {
            return [PSCustomObject]@{ Ascii = $false; Offset = $i }
        }
    }
    return [PSCustomObject]@{ Ascii = $true; Offset = -1 }
}

$targets = New-Object 'System.Collections.Generic.List[string]'

$rootFiles = @(
    'addon-server.ps1', 'addon-sync.ps1', 'deploy.ps1', 'install.ps1',
    'make-icon.ps1', 'package.ps1', 'register-protocol.ps1'
)
foreach ($f in $rootFiles) {
    $p = Join-Path -Path $Script:FurphyBuildRoot -ChildPath $f
    if (Test-Path -LiteralPath $p -PathType Leaf) { $targets.Add($p) }
}
foreach ($f in @('host\build-host.ps1', 'host\FurphyHost.cs')) {
    $p = Join-Path -Path $Script:FurphyBuildRoot -ChildPath $f
    if (Test-Path -LiteralPath $p -PathType Leaf) { $targets.Add($p) }
}
foreach ($dir in @('tests', 'fixtures')) {
    $full = Join-Path -Path $Script:FurphyBuildRoot -ChildPath $dir
    if (Test-Path -LiteralPath $full -PathType Container) {
        # Bug found live while adding tests\theme-screenshots\*.png (T4):
        # Get-ChildItem's -Include is silently a no-op when combined with
        # -LiteralPath and -Recurse on this PowerShell version - every file
        # under the tree comes back regardless of -Include, not just
        # *.ps1/*.cs. This went unnoticed as long as every non-.ps1/.cs file
        # under tests\/fixtures\ happened to be plain text or an empty stub
        # (fixtures\wowroot's own Wow.exe stubs, .toc files) - a real binary
        # PNG is the first file that actually exposed it. Filtering by
        # .Extension after a plain -Recurse -File (the same reliable pattern
        # install.ps1/package.ps1 already use elsewhere in this repo) is not
        # subject to the same quirk.
        $found = Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.ps1', '.cs' -and $_.FullName -notmatch '\\\.tmp\\' }
        foreach ($f in $found) { $targets.Add($f.FullName) }
    }
}

foreach ($path in $targets) {
    $rel = $path.Substring($Script:FurphyBuildRoot.Length).TrimStart('\')
    try {
        $check = Test-FileIsAscii -Path $path
        Add-Result -Collector $results -Name "ascii: $rel" -Passed $check.Ascii -Message ("first non-ASCII byte at offset {0}" -f $check.Offset)
    } catch {
        Add-Result -Collector $results -Name "ascii: $rel" -Passed $false -Message $_.Exception.Message
    }
}

exit (Write-ResultsSummary -Collector $results)
