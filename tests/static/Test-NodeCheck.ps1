<#
  Static check: `node --check` over ui\app.js (the shipped SPA) plus every
  vanilla-JS test harness file under tests\spa\ (T4: harness.js and
  theme-audit.js, per the hard rule "vanilla JS in ui\ and tests\spa\") -
  no npm packages involved, just the syntax checker built into the node
  binary confirmed available on this machine (node v24).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:node-check'

$nodeExe = $null
try { $nodeExe = (Get-Command node -ErrorAction Stop).Source } catch { $nodeExe = $null }
if (-not $nodeExe) {
    Add-Result -Collector $results -Name 'node available' -Passed $false -Message 'node not found on PATH'
    exit (Write-ResultsSummary -Collector $results)
}

$targets = New-Object 'System.Collections.Generic.List[string]'
$appJs = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'ui\app.js'
if (Test-Path -LiteralPath $appJs -PathType Leaf) { $targets.Add($appJs) }

$spaDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'tests\spa'
if (Test-Path -LiteralPath $spaDir -PathType Container) {
    Get-ChildItem -LiteralPath $spaDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.js' } |
        ForEach-Object { $targets.Add($_.FullName) }
}

foreach ($path in $targets) {
    $rel = $path.Substring($Script:FurphyBuildRoot.Length).TrimStart('\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Result -Collector $results -Name "$rel exists" -Passed $false -Message 'file not found'
        continue
    }
    $output = & node --check $path 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    Add-Result -Collector $results -Name "node --check $rel" -Passed $ok -Message ([string]($output -join "`n"))
}

exit (Write-ResultsSummary -Collector $results)
