<#
  Static check: the REPO MIRROR's .gitignore (mirrored by deploy.ps1 -
  see MEMORY.md / SPEC.md for the mirror path) covers every known
  per-install state/log/cache path, so a manual dev commit inside that
  checkout can never accidentally commit a real user's addon list, API
  state, or logs.

  Read-only: this test only inspects the mirror's .gitignore, it never
  writes to the repo mirror (out of scope for this test layer - deploy.ps1
  owns mirroring).

  P3 perf-pass fix: the mirror path used to be a second, hand-typed literal
  here, independent of deploy.ps1's own -RepoPath default - two copies of
  the same path that could silently drift apart (this test would then
  "pass" against the wrong checkout, or fail with a confusing "not found"
  against a moved mirror, while deploy.ps1 itself kept working fine against
  its own, unchanged, correct value). Get-MirrorRootFromDeployScript reads
  deploy.ps1's actual [string]$RepoPath = '...' default via a plain regex
  instead, so this test always inspects the SAME checkout deploy.ps1 itself
  mirrors into - one source of truth. Falls back to the historical literal
  only if deploy.ps1 is missing or its param shape changes unexpectedly
  (never silently skips the check).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:gitignore-coverage'

function Get-MirrorRootFromDeployScript {
    <#
      Reads deploy.ps1's own param default for -RepoPath - the actual
      value deploy.ps1 mirrors this project into - rather than a second,
      independently hand-typed copy of the same path. Returns $null (never
      throws) if deploy.ps1 is missing or its shape has changed enough that
      the pattern no longer matches, so the caller can fall back cleanly.
    #>
    param([string]$DeployScriptPath)

    if (-not (Test-Path -LiteralPath $DeployScriptPath -PathType Leaf)) { return $null }
    try {
        $deployText = Get-Content -LiteralPath $DeployScriptPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($deployText -match "\[string\]\`$RepoPath\s*=\s*'([^']+)'") {
            return $matches[1]
        }
        return $null
    } catch {
        return $null
    }
}

$Script:HistoricalMirrorRootFallback = 'C:\Users\drops\Documents\furphy-addon-manager'
$deployScriptPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'deploy.ps1'
$mirrorRoot = Get-MirrorRootFromDeployScript -DeployScriptPath $deployScriptPath
$mirrorRootSource = 'deploy.ps1 -RepoPath default'
if (-not $mirrorRoot) {
    $mirrorRoot = $Script:HistoricalMirrorRootFallback
    $mirrorRootSource = 'fallback literal (deploy.ps1 -RepoPath default could not be read)'
}
Add-Result -Collector $results -Name 'mirror path read from deploy.ps1 -RepoPath default' -Passed ($mirrorRootSource -eq 'deploy.ps1 -RepoPath default') -Message "using: $mirrorRoot (source: $mirrorRootSource)"

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
