<#
.SYNOPSIS
    Regenerates the installer artwork in installer\assets\:
      ComponentSuite.ico  - Add/Remove Programs icon (16/32/48/256 px)
      Banner.bmp          - 493x58 strip at the top of the inner setup dialogs
      Dialog.bmp          - 493x312 background of the Welcome / Finish dialogs
    The generated files are committed; run this only to change the design.
    Windows only (System.Drawing).
#>
[CmdletBinding()]
param([string] $OutDir = (Join-Path $PSScriptRoot '..\installer\assets'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$deep  = [Drawing.Color]::FromArgb(255, 22, 58, 110)    # navy
$light = [Drawing.Color]::FromArgb(255, 38, 140, 170)   # teal

function New-Graphics($bmp) {
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode   = 'HighQuality'
    $g
}

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

# The mark: three stacked "layers" (one per tier of components) on a rounded tile.
function Draw-Mark($g, [float]$x, [float]$y, [float]$s, [bool]$tile = $true) {
    if ($tile) {
        $rect  = New-Object Drawing.RectangleF($x, $y, $s, $s)
        $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, $light, $deep, 45.0)
        $g.FillPath($brush, (New-RoundedRect $x $y $s $s ($s * 0.22)))
    }
    $cx = $x + $s / 2; $w = $s * 0.30; $h = $s * 0.13
    $alphas = 150, 200, 255
    for ($i = 0; $i -lt 3; $i++) {
        $cy  = $y + $s * (0.68 - 0.17 * $i)
        $pts = [Drawing.PointF[]]@(
            (New-Object Drawing.PointF($cx, ($cy - $h))),
            (New-Object Drawing.PointF(($cx + $w), $cy)),
            (New-Object Drawing.PointF($cx, ($cy + $h))),
            (New-Object Drawing.PointF(($cx - $w), $cy)))
        $fill = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alphas[$i], 255, 255, 255))
        $g.FillPolygon($fill, $pts)
    }
}

# --- Icon: 16/32/48 as 32-bit DIBs, 256 as PNG (the classic, widely readable layout) ---
$sizes = 16, 32, 48, 256
$pngs  = foreach ($s in $sizes) {
    $bmp = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = New-Graphics $bmp
    $g.Clear([Drawing.Color]::Transparent)
    Draw-Mark $g 0 0 $s
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    if ($s -ge 256) {
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    }
    else {
        # BITMAPINFOHEADER (height doubled for XOR+AND), bottom-up BGRA rows, then an all-zero AND mask.
        $w = New-Object IO.BinaryWriter($ms)
        $w.Write([uint32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2))
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0)
        $w.Write([uint32]($s * $s * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
        for ($y = $s - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $s; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
            }
        }
        $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4)
        $w.Write((New-Object byte[] ($maskRow * $s)))
        $w.Flush()
    }
    $bmp.Dispose()
    , $ms.ToArray()
}
$ico = New-Object IO.MemoryStream
$bw  = New-Object IO.BinaryWriter($ico)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
[IO.File]::WriteAllBytes((Join-Path $OutDir 'ComponentSuite.ico'), $ico.ToArray())

# --- Banner (493x58): white, title text is drawn by setup on the left -----------
$bmp = New-Object Drawing.Bitmap(493, 58, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = New-Graphics $bmp
$g.Clear([Drawing.Color]::White)
Draw-Mark $g 437 7 44
$line = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(0, 55, 493, 3)), $light, $deep, 0.0)
$g.FillRectangle($line, 0, 55, 493, 3)
$g.Dispose()
$bmp.Save((Join-Path $OutDir 'Banner.bmp'), [Drawing.Imaging.ImageFormat]::Bmp); $bmp.Dispose()

# --- Dialog (493x312): coloured panel on the left 164 px, text area stays white --
$bmp = New-Object Drawing.Bitmap(493, 312, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = New-Graphics $bmp
$g.Clear([Drawing.Color]::White)
$panel = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(0, 0, 164, 312)), $light, $deep, 70.0)
$g.FillRectangle($panel, 0, 0, 164, 312)
Draw-Mark $g 22 96 120 $false
$g.Dispose()
$bmp.Save((Join-Path $OutDir 'Dialog.bmp'), [Drawing.Imaging.ImageFormat]::Bmp); $bmp.Dispose()

Get-ChildItem $OutDir | Select-Object Name, Length
