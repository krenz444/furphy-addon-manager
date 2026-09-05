<#
  Static check: every .ps1 in the shipped root, host\, tests\, and
  fixtures\ parses cleanly under the PowerShell 5.1 language parser
  (Set-StrictMode/Import-Module etc. never even run - this is a pure
  syntax check, so it's safe to run over a script that might otherwise
  have side effects).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:parse-all-scripts'

$rootFiles = @(
    'addon-server.ps1', 'addon-sync.ps1', 'deploy.ps1', 'install.ps1',
    'make-icon.ps1', 'package.ps1', 'register-protocol.ps1'
)
$targets = New-Object 'System.Collections.Generic.List[string]'
foreach ($f in $rootFiles) {
    $p = Join-Path -Path $Script:FurphyBuildRoot -ChildPath $f
    if (Test-Path -LiteralPath $p -PathType Leaf) { $targets.Add($p) }
}
$hostScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\build-host.ps1'
if (Test-Path -LiteralPath $hostScript -PathType Leaf) { $targets.Add($hostScript) }

foreach ($dir in @('tests', 'fixtures')) {
    $full = Join-Path -Path $Script:FurphyBuildRoot -ChildPath $dir
    if (Test-Path -LiteralPath $full -PathType Container) {
        $found = Get-ChildItem -LiteralPath $full -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.tmp\\' }
        foreach ($f in $found) { $targets.Add($f.FullName) }
    }
}

foreach ($path in $targets) {
    $rel = $path.Substring($Script:FurphyBuildRoot.Length).TrimStart('\')
    $errors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $count = 0
        if ($errors) { $count = (@($errors)).Count }
        Add-Result -Collector $results -Name "parse: $rel" -Passed ($count -eq 0) -Message ("$count parse error(s)")
    } catch {
        Add-Result -Collector $results -Name "parse: $rel" -Passed $false -Message $_.Exception.Message
    }
}

exit (Write-ResultsSummary -Collector $results)
