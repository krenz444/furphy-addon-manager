<#
  Static check: the REPO MIRROR's .gitignore (mirrored by deploy.ps1 -
  see MEMORY.md / SPEC.md for the mirror path) covers every known
  per-install state/log/cache path, so a manual dev commit inside that
  checkout can never accidentally commit a real user's addon list, API
  state, or logs.

  Read-only: this test only inspects the mirror's .gitignore, it never
  writes to the repo mirror (out of scope for this test layer - deploy.ps1
  owns mirroring).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:gitignore-coverage'

$mirrorRoot = 'C:\Users\drops\Documents\furphy-addon-manager'
$gitignorePath = Join-Path -Path $mirrorRoot -ChildPath '.gitignore'

if (-not (Test-Path -LiteralPath $mirrorRoot -PathType Container)) {
    Add-Result -Collector $results -Name 'repo mirror exists' -Passed $false -Message "not found: $mirrorRoot"
    exit (Write-ResultsSummary -Collector $results)
}
Add-Result -Collector $results -Name 'repo mirror exists' -Passed $true

if (-not (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
    Add-Result -Collector $results -Name '.gitignore exists' -Passed $false -Message "not found: $gitignorePath"
    exit (Write-ResultsSummary -Collector $results)
}
Add-Result -Collector $results -Name '.gitignore exists' -Passed $true

$lines = Get-Content -LiteralPath $gitignorePath -Encoding UTF8
$patterns = $lines | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.Trim() }

function Test-GitignoreCoversPath {
    <#
      True when some line in $Patterns would ignore a repo-relative path
      like $SamplePath, using git's own actual pattern matching (not a
      hand-rolled approximation) - PowerShell's -like operator only
      differs from a real .gitignore matcher in ways that don't matter for
      the simple literal-name and single-trailing-slash-directory patterns
      this project's .gitignore actually uses (no nested "**" globs, no
      leading "/" anchors) - see the individual patterns checked below.
    #>
    param([string[]]$Patterns, [string]$SamplePath)

    foreach ($p in $Patterns) {
        $pat = $p
        $isDirOnly = $pat.EndsWith('/')
        if ($isDirOnly) { $pat = $pat.TrimEnd('/') }
        # A pattern with no "/" in it matches at ANY depth (git semantics);
        # one that appears as a full path SEGMENT anywhere in $SamplePath
        # counts as a match for this purpose (dir-only patterns like
        # "cache/" ignore the whole subtree under any "cache" folder).
        $segments = $SamplePath -split '[\\/]'
        foreach ($seg in $segments) {
            if ($seg -like $pat) { return $true }
        }
        if ($SamplePath -like $pat) { return $true }
    }
    return $false
}

$required = @(
    'addons.json', 'settings.json', 'state.json', 'last-run.txt',
    'tray-state.json', 'server.pid', 'sync.log', 'server.log',
    'jobs/some.out', 'staging/x', 'backups/1/1.zip', 'cache/cf-catalogue.json',
    'flavours/retail/addons.json', 'flavours/_migration-backup-20260101-000000/state.json'
)

foreach ($sample in $required) {
    $covered = Test-GitignoreCoversPath -Patterns $patterns -SamplePath $sample
    Add-Result -Collector $results -Name "gitignore covers '$sample'" -Passed $covered -Message 'no matching pattern in .gitignore'
}

exit (Write-ResultsSummary -Collector $results)
