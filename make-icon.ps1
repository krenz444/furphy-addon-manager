# Renders an SVG to PNGs with headless Edge and packs them into a multi-size PNG .ico (Vista+ format).
# Usage: .\make-icon.ps1 -Svg <icon.svg> -OutDir <dir> [-Name furphy]
param(
    [Parameter(Mandatory = $true)][string]$Svg,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Name = 'icon',
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
    [int[]]$ExtraPngs = @(192, 512)
)
$ErrorActionPreference = 'Stop'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path -LiteralPath $edge)) { throw "Edge not found at $edge" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$svgUri = 'file:///' + ((Resolve-Path -LiteralPath $Svg).Path -replace '\\', '/')

function Render-Png([int]$size, [string]$outPng) {
    $html = Join-Path $OutDir ("render-$size.html")
    $content = "<!doctype html><html><head><meta charset='utf-8'><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}img{display:block;width:${size}px;height:${size}px}</style></head><body><img src='$svgUri'></body></html>"
    [IO.File]::WriteAllText($html, $content, (New-Object System.Text.UTF8Encoding($false)))
    $htmlUri = 'file:///' + ($html -replace '\\', '/')
    if (Test-Path -LiteralPath $outPng) { Remove-Item -LiteralPath $outPng -Force }
    $args = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--default-background-color=00000000', "--window-size=$size,$size", "--screenshot=$outPng", $htmlUri)
    $p = Start-Process -FilePath $edge -ArgumentList $args -PassThru -WindowStyle Hidden
    $null = $p.WaitForExit(30000)
    if (-not $p.HasExited) { $p.Kill() }
    if (-not (Test-Path -LiteralPath $outPng)) { throw "Edge did not produce $outPng" }
    Remove-Item -LiteralPath $html -Force -ErrorAction SilentlyContinue
}

$pngs = @{}
foreach ($s in ($Sizes + $ExtraPngs | Sort-Object -Unique)) {
    $out = Join-Path $OutDir ("$Name-$s.png")
    Render-Png $s $out
    $pngs[$s] = $out
    "rendered $s px -> $out ($((Get-Item -LiteralPath $out).Length) B)"
}

# Pack the ICO: ICONDIR + ICONDIRENTRY[] + PNG blobs.
$icoPath = Join-Path $OutDir "$Name.ico"
$fs = [IO.File]::Create($icoPath)
$bw = New-Object IO.BinaryWriter($fs)
try {
    $entries = @($Sizes | Sort-Object)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    $blobs = @()
    foreach ($s in $entries) {
        $bytes = [IO.File]::ReadAllBytes($pngs[$s])
        $blobs += ,$bytes
        $dim = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$bytes.Length); $bw.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($b in $blobs) { $bw.Write($b) }
} finally { $bw.Close(); $fs.Close() }
"ico -> $icoPath ($((Get-Item -LiteralPath $icoPath).Length) B, $($entries.Count) sizes)"
