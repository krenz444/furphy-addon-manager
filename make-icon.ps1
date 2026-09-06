# Renders an SVG to PNGs with headless Edge and packs them into a multi-size .ico.
# Usage: .\make-icon.ps1 -Svg <icon.svg> -OutDir <dir> [-Name furphy]
#
# Round 32 (Eric: "the furphy addon manager icon should be the same as the
# one in the app"): frames up to 64 px are now written as classic 32-bit
# BMP (DIB) frames with an AND mask, and only 128/256 px stay PNG-compressed.
# The old all-PNG layout is legal for Explorer, but the C# compiler's
# /win32icon, System.Drawing.Icon (which the tray's NotifyIcon and the
# WinForms title bar use) and several shell consumers mangle or reject
# PNG frames below 256 px - the exe ended up carrying the generic .NET icon
# and Icon.ToBitmap() at 32 px produced noise. Classic frames render
# identically everywhere.
param(
    [Parameter(Mandatory = $true)][string]$Svg,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Name = 'icon',
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
    [int[]]$ExtraPngs = @(192, 512),
    # Frames at or below this size are stored as BMP; larger ones as PNG.
    [int]$BmpUpTo = 64
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
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

# Classic ICO frame: BITMAPINFOHEADER (biHeight doubled), 32-bit BGRA rows
# bottom-up, then a 1-bit AND mask (rows padded to 4 bytes). Alpha stays in
# the colour data; the mask marks fully transparent pixels so consumers
# that ignore alpha still get a clean silhouette.
function ConvertTo-DibFrame([string]$pngPath) {
    $bmp = [System.Drawing.Bitmap]::FromFile($pngPath)
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $maskStride = [int][Math]::Ceiling($w / 32.0) * 4
        $ms = New-Object IO.MemoryStream
        $bw = New-Object IO.BinaryWriter($ms)
        $bw.Write([uint32]40)                  # biSize
        $bw.Write([int32]$w)                   # biWidth
        $bw.Write([int32]($h * 2))             # biHeight (XOR + AND)
        $bw.Write([uint16]1)                   # biPlanes
        $bw.Write([uint16]32)                  # biBitCount
        $bw.Write([uint32]0)                   # biCompression BI_RGB
        $bw.Write([uint32]($w * $h * 4 + $maskStride * $h)) # biSizeImage
        $bw.Write([int32]0); $bw.Write([int32]0)             # biXPelsPerMeter, biYPelsPerMeter
        $bw.Write([uint32]0); $bw.Write([uint32]0)           # biClrUsed, biClrImportant
        for ($y = $h - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $w; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
            }
        }
        for ($y = $h - 1; $y -ge 0; $y--) {
            $row = New-Object byte[] $maskStride
            for ($x = 0; $x -lt $w; $x++) {
                # [int] would round (7/8 -> 1); Floor gives the byte index.
                $bi = [int][Math]::Floor($x / 8)
                if ($bmp.GetPixel($x, $y).A -eq 0) { $row[$bi] = $row[$bi] -bor (0x80 -shr ($x % 8)) }
            }
            $bw.Write($row)
        }
        $bw.Flush()
        # Comma keeps the byte[] intact; a bare return would unroll it into
        # an object[] and BinaryWriter.Write would then pick a wrong overload.
        return ,([byte[]]$ms.ToArray())
    } finally { $bmp.Dispose() }
}

$pngs = @{}
foreach ($s in ($Sizes + $ExtraPngs | Sort-Object -Unique)) {
    $out = Join-Path $OutDir ("$Name-$s.png")
    Render-Png $s $out
    $pngs[$s] = $out
    "rendered $s px -> $out ($((Get-Item -LiteralPath $out).Length) B)"
}

# Pack the ICO: ICONDIR + ICONDIRENTRY[] + frame blobs (BMP up to $BmpUpTo, PNG above).
$icoPath = Join-Path $OutDir "$Name.ico"
$fs = [IO.File]::Create($icoPath)
$bw = New-Object IO.BinaryWriter($fs)
try {
    $entries = @($Sizes | Sort-Object)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    $blobs = @()
    $kinds = @()
    foreach ($s in $entries) {
        if ($s -le $BmpUpTo) { $bytes = [byte[]](ConvertTo-DibFrame $pngs[$s]); $kinds += 'bmp' }
        else { $bytes = [byte[]][IO.File]::ReadAllBytes($pngs[$s]); $kinds += 'png' }
        $blobs += ,$bytes
        $dim = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$bytes.Length); $bw.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($b in $blobs) { $bw.Write([byte[]]$b) }
} finally { $bw.Close(); $fs.Close() }
"ico -> $icoPath ($((Get-Item -LiteralPath $icoPath).Length) B, $($entries.Count) sizes: $(($entries | ForEach-Object { $_ }) -join '/'); frames $($kinds -join '/'))"
