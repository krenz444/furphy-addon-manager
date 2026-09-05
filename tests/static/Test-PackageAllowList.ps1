<#
  Static check: package.ps1's $rootFiles allow-list (the exact set of
  root-level files it stages into a shipped zip) never names a state,
  log, profile, or tests path - it must ship only source/launcher files,
  never per-install data or dev scratch.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:package-allowlist'

$packagePath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'package.ps1'
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    Add-Result -Collector $results -Name 'package.ps1 exists' -Passed $false -Message 'file not found'
    exit (Write-ResultsSummary -Collector $results)
}

$raw = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8
$match = [System.Text.RegularExpressions.Regex]::Match($raw, '\$rootFiles\s*=\s*@\((.*?)\)', 'Singleline')
if (-not $match.Success) {
    Add-Result -Collector $results -Name 'rootFiles array located' -Passed $false -Message 'could not find $rootFiles = @( ... ) in package.ps1'
    exit (Write-ResultsSummary -Collector $results)
}
Add-Result -Collector $results -Name 'rootFiles array located' -Passed $true

$itemMatches = [System.Text.RegularExpressions.Regex]::Matches($match.Groups[1].Value, "'([^']*)'")
$items = New-Object 'System.Collections.Generic.List[string]'
foreach ($m in $itemMatches) { $items.Add($m.Groups[1].Value) }

Add-Result -Collector $results -Name 'rootFiles is non-empty' -Passed ($items.Count -gt 0) -Message ("found {0} entries" -f $items.Count)

# Substrings that would mean "this entry is per-install state, a log, a
# profile/browser-cache path, or a tests path" - none may appear anywhere
# in any entry.
$bannedSubstrings = @(
    'addons.json', 'settings.json', 'state.json', 'tray-state.json',
    'server.pid', '.log', 'staging', 'backups', 'cache',
    'jobs', 'flavours', 'tests', '.tmp', 'profile', '.pid'
)

foreach ($item in $items) {
    $lower = $item.ToLowerInvariant()
    $hitBanned = $null
    foreach ($b in $bannedSubstrings) {
        if ($lower.Contains($b)) { $hitBanned = $b; break }
    }
    Add-Result -Collector $results -Name "rootFiles entry '$item'" -Passed (-not $hitBanned) -Message ("contains banned substring '$hitBanned'")
}

exit (Write-ResultsSummary -Collector $results)
