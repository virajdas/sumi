# Renders the Sumi icon (paper squircle + ink ensō) at several sizes and packs them into assets\sumi.ico
param([string]$Out = "$PSScriptRoot\..\assets\sumi.ico")

Add-Type -AssemblyName System.Drawing

function New-Frame([int]$size, [double]$padRatio = 0.06) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded "squircle" tile
    $pad = [Math]::Max(1, $size * $padRatio)
    $s = $size - 2 * $pad
    $r = $s * 0.24
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($pad, $pad, 2*$r, 2*$r, 180, 90)
    $path.AddArc($pad + $s - 2*$r, $pad, 2*$r, 2*$r, 270, 90)
    $path.AddArc($pad + $s - 2*$r, $pad + $s - 2*$r, 2*$r, 2*$r, 0, 90)
    $path.AddArc($pad, $pad + $s - 2*$r, 2*$r, 2*$r, 90, 90)
    $path.CloseFigure()
    $rect = New-Object System.Drawing.RectangleF $pad, $pad, $s, $s
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect,
        ([System.Drawing.Color]::FromArgb(255, 251, 249, 244)),
        ([System.Drawing.Color]::FromArgb(255, 233, 227, 214)), 90
    $g.FillPath($grad, $path)
    if ($size -ge 32) {
        $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(40, 120, 100, 70)), ([Math]::Max(1, $size/128))
        $g.DrawPath($edge, $path)
    }

    # Ensō: a brush circle that swells and tapers, leaving a gap
    $cx = $size / 2; $cy = $size / 2 + $size * 0.01
    $R = $size * 0.25
    $maxW = [Math]::Max(1.6, $size * 0.075)
    $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 44, 42, 38))
    $start = -60.0; $sweep = 315.0
    $steps = [int]([Math]::Max(120, $size * 6))
    for ($i = 0; $i -le $steps; $i++) {
        $t = $i / $steps
        $a = ($start + $t * $sweep) * [Math]::PI / 180
        $w = $maxW * (0.28 + 0.72 * [Math]::Pow([Math]::Sin([Math]::PI * [Math]::Pow($t, 0.8)), 0.55))
        $rr = $R * (1 + 0.025 * [Math]::Sin($t * 9))
        $x = $cx + $rr * [Math]::Cos($a); $y = $cy + $rr * [Math]::Sin($a)
        $g.FillEllipse($ink, [single]($x - $w/2), [single]($y - $w/2), [single]$w, [single]$w)
    }
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$frames = foreach ($sz in $sizes) { ,(New-Frame $sz) }

New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$frames[$i].Length); $bw.Write([UInt32]$offset)
    $offset += $frames[$i].Length
}
foreach ($f in $frames) { $bw.Write($f) }
$bw.Close()

# Also keep a large PNG preview
[System.IO.File]::WriteAllBytes((Join-Path (Split-Path $Out) "sumi-256.png"), $frames[-1])
# The Mac icon: larger, with the margin macOS icons conventionally have
[System.IO.File]::WriteAllBytes((Join-Path (Split-Path $Out) "sumi-1024.png"), (New-Frame 1024 0.1))
Write-Host "Wrote $Out"
