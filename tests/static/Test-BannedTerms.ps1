<#
  Static check: UX-SPEC.md section 11's banned-visible-term sweep.

  This is a best-effort STATIC approximation, not a live-DOM inspection -
  a full "no visible UI text contains X" proof needs an actual rendered
  page (a later test layer drives ?mock=1 through a real/headless browser
  and reads only rendered text - THAT is the authoritative check; UX-SPEC
  11's own acceptance line is written against a live session). Two
  precision problems specific to a static sweep of ui\, worked out by
  inspecting this app's actual source before writing the allow-list below
  (not guessed):

    1. ui\index.html's `id="..."`/`class="..."` attribute values are DOM
       hooks, never rendered text (e.g. id="welcome-adopt", a button
       whose actual visible label is "Take over all") - stripped before
       matching, alongside the usual `<!-- -->` comment strip.
    2. ui\app.js uses several of these exact words as INTERNAL enum/state
       values that are always mapped to different, compliant display text
       before render (e.g. `compat: "stale-minor"` is later turned into
       the label "Old patch" - see renderStatusChip's compat switch) -
       scanning every JS string literal would flag the internal code, not
       the UI. This scans only string literals assigned to a small,
       deliberately conservative set of copy-shaped property names/DOM
       setters (label/title/textContent/placeholder/heading/hint/
       message/summary) - the same shape this codebase's own copy
       actually takes wherever it defines a chip/toast/dialog string.
       innerHTML/template-literal-built copy is NOT covered here (real
       interpolation makes it unsafe to regex) - left to the live-DOM
       layer.
    3. "Port" (visible-About rule) and raw HTTP status codes are
       INTENTIONALLY present in ui\app.js's Copy-report text builder
       (UX-SPEC.md 6.2/11: "kept in Copy report only") - a static regex
       cannot tell "on-screen" apart from "copy-report-only" text, so
       these two checks run against ui\index.html (static markup, always
       on-screen) only, never ui\app.js; the on-screen-vs-copy-report
       split itself is the live-DOM layer's job.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$results = New-ResultsCollector -Suite 'static:banned-terms'

$bannedPhrases = @(
    'project id', 'file id', 'release type', 'interface version',
    'stale-minor', 'adopting', 'untracked', 'keyless',
    'instawow-data', 'addon-radar.com'
)
$bannedWords = @('toc', 'compat', 'stale', 'adopt', 'digest', 'indexed')

function Remove-HtmlNoise {
    param([string]$Text)

    $noComments = [System.Text.RegularExpressions.Regex]::Replace($Text, '<!--.*?-->', '', 'Singleline')
    $noIds = [System.Text.RegularExpressions.Regex]::Replace($noComments, 'id\s*=\s*"[^"]*"', 'id=""')
    $noClasses = [System.Text.RegularExpressions.Regex]::Replace($noIds, 'class\s*=\s*"[^"]*"', 'class=""')
    return $noClasses
}

function Get-JsCopyLiteralBlob {
    <# Extracts only the copy-shaped string literals described in the header comment above. #>
    param([string]$Text)

    $noBlockComments = [System.Text.RegularExpressions.Regex]::Replace($Text, '/\*.*?\*/', '', 'Singleline')
    $lines = $noBlockComments -split "`n"
    $codeOnly = ($lines | Where-Object { -not $_.TrimStart().StartsWith('//') }) -join "`n"

    $propNames = 'label|title|textContent|placeholder|heading|hint|message|summary'
    $pattern = '(?:' + $propNames + ')\s*[:=]\s*(?:"([^"]*)"|''([^'']*)'')'
    $matches = [System.Text.RegularExpressions.Regex]::Matches($codeOnly, $pattern)
    $parts = foreach ($m in $matches) {
        if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    }
    return ($parts -join ' | ')
}

# ---- ui\index.html: full markup (minus comments/id/class), so phrase,
# word, HTTP-status, and "Port" checks all apply. ----
$indexPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'ui\index.html'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    Add-Result -Collector $results -Name 'exists: ui\index.html' -Passed $false -Message 'file not found'
} else {
    $htmlBlob = Remove-HtmlNoise -Text (Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8)

    foreach ($phrase in $bannedPhrases) {
        $hit = $htmlBlob.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        Add-Result -Collector $results -Name "index.html: '$phrase'" -Passed (-not $hit) -Message 'banned phrase found in visible markup'
    }
    foreach ($word in $bannedWords) {
        $pattern = '\b' + [System.Text.RegularExpressions.Regex]::Escape($word) + '\b'
        $hit = [System.Text.RegularExpressions.Regex]::IsMatch($htmlBlob, $pattern, 'IgnoreCase')
        Add-Result -Collector $results -Name "index.html: word '$word'" -Passed (-not $hit) -Message 'banned word found in visible markup'
    }
    $httpCodeHit = [System.Text.RegularExpressions.Regex]::IsMatch($htmlBlob, '\bHTTP[ /]?\d{3}\b', 'IgnoreCase')
    Add-Result -Collector $results -Name 'index.html: raw HTTP status code' -Passed (-not $httpCodeHit) -Message 'e.g. "HTTP 200" found in visible markup'
    $portHit = [System.Text.RegularExpressions.Regex]::IsMatch($htmlBlob, '\bPort\b')
    Add-Result -Collector $results -Name "index.html: word 'Port'" -Passed (-not $portHit) -Message 'capitalized "Port" found in visible markup'
}

# ---- ui\app.js: copy-shaped string literals only (see header comment). ----
$appJsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'ui\app.js'
if (-not (Test-Path -LiteralPath $appJsPath -PathType Leaf)) {
    Add-Result -Collector $results -Name 'exists: ui\app.js' -Passed $false -Message 'file not found'
} else {
    $jsBlob = Get-JsCopyLiteralBlob -Text (Get-Content -LiteralPath $appJsPath -Raw -Encoding UTF8)
    Add-Result -Collector $results -Name 'app.js: copy literals extracted' -Passed ($jsBlob.Length -gt 0) -Message 'found zero label/title/textContent-shaped string literals - extraction pattern may be stale'

    foreach ($phrase in $bannedPhrases) {
        $hit = $jsBlob.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        Add-Result -Collector $results -Name "app.js: '$phrase'" -Passed (-not $hit) -Message 'banned phrase found in a copy-shaped string literal'
    }
    foreach ($word in $bannedWords) {
        $pattern = '\b' + [System.Text.RegularExpressions.Regex]::Escape($word) + '\b'
        $hit = [System.Text.RegularExpressions.Regex]::IsMatch($jsBlob, $pattern, 'IgnoreCase')
        Add-Result -Collector $results -Name "app.js: word '$word'" -Passed (-not $hit) -Message 'banned word found in a copy-shaped string literal'
    }
}

# ---- ui\style.css: CSS has no visible text of its own except a literal
# `content:` value (a rare pseudo-element trick) - class/id selectors are
# code, not UI copy, so they are deliberately never scanned. ----
$cssPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'ui\style.css'
if (-not (Test-Path -LiteralPath $cssPath -PathType Leaf)) {
    Add-Result -Collector $results -Name 'exists: ui\style.css' -Passed $false -Message 'file not found'
} else {
    $cssRaw = Get-Content -LiteralPath $cssPath -Raw -Encoding UTF8
    $contentValues = [System.Text.RegularExpressions.Regex]::Matches($cssRaw, 'content\s*:\s*"([^"]*)"')
    $cssBlob = (($contentValues | ForEach-Object { $_.Groups[1].Value }) -join ' | ')
    foreach ($word in ($bannedWords + $bannedPhrases)) {
        $hit = $cssBlob.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        Add-Result -Collector $results -Name "style.css: content: '$word'" -Passed (-not $hit) -Message 'banned term found in a CSS content: value'
    }
}

exit (Write-ResultsSummary -Collector $results)
