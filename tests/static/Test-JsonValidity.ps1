<#
  Static check: JSON validity of ui\manifest.json and every fixture .json
  file (fixtures\wowroot itself carries none today - .build.info is
  pipe-delimited, not JSON - so this also proves the sweep itself finds
  ui\manifest.json even when the fixtures side is empty).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:json-validity'

function Test-JsonFileValid {
    param([string]$Path)

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [PSCustomObject]@{ Valid = $false; Message = 'empty file' }
        }
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
        return [PSCustomObject]@{ Valid = $true; Message = '' }
    } catch {
        return [PSCustomObject]@{ Valid = $false; Message = $_.Exception.Message }
    }
}

$targets = New-Object 'System.Collections.Generic.List[string]'

$manifest = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'ui\manifest.json'
if (Test-Path -LiteralPath $manifest -PathType Leaf) { $targets.Add($manifest) }

$fixturesDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'fixtures'
if (Test-Path -LiteralPath $fixturesDir -PathType Container) {
    $found = Get-ChildItem -LiteralPath $fixturesDir -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $found) { $targets.Add($f.FullName) }
}

if ($targets.Count -eq 0) {
    Add-Result -Collector $results -Name 'targets found' -Passed $false -Message 'no JSON files matched (expected at least ui\manifest.json)'
} else {
    foreach ($path in $targets) {
        $rel = $path.Substring($Script:FurphyBuildRoot.Length).TrimStart('\')
        $check = Test-JsonFileValid -Path $path
        Add-Result -Collector $results -Name "json: $rel" -Passed $check.Valid -Message $check.Message
    }
}

exit (Write-ResultsSummary -Collector $results)
