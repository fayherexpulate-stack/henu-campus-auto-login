# Windows-only drawing helpers (System.Drawing) for the tray icon, flyout dot and shortcut icon.
function Get-HenuLevelColor([string]$Level) {
    switch -Exact ($Level) {
        'ok'    { return [Drawing.Color]::FromArgb(21,128,61) }
        'busy'  { return [Drawing.Color]::FromArgb(29,78,216) }
        'warn'  { return [Drawing.Color]::FromArgb(196,110,8) }
        'error' { return [Drawing.Color]::FromArgb(200,30,30) }
        'brand' { return [Drawing.Color]::FromArgb(163,31,52) }
        default { return [Drawing.Color]::FromArgb(107,114,128) }
    }
}
function New-HenuRoundPath([single]$X,[single]$Y,[single]$Width,[single]$Height,[single]$Radius) {
    $path=New-Object Drawing.Drawing2D.GraphicsPath
    $d=[single](2*$Radius)
    $path.AddArc($X,$Y,$d,$d,180,90)
    $path.AddArc(($X+$Width-$d),$Y,$d,$d,270,90)
    $path.AddArc(($X+$Width-$d),($Y+$Height-$d),$d,$d,0,90)
    $path.AddArc($X,($Y+$Height-$d),$d,$d,90,90)
    $path.CloseFigure()
    return $path
}
function New-HenuGlyphBitmap([int]$Size,[Drawing.Color]$Color) {
    # Rounded square in the status colour with a white Wi-Fi mark.
    $bitmap=New-Object Drawing.Bitmap($Size,$Size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $brush=New-Object Drawing.SolidBrush($Color)
    $white=New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $pen=New-Object Drawing.Pen([Drawing.Color]::White,[single][Math]::Max(1.6,$Size*0.11))
    $path=New-HenuRoundPath 0 0 ([single]($Size-1)) ([single]($Size-1)) ([single]($Size*0.22))
    try {
        $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.FillPath($brush,$path)
        $pen.StartCap=[Drawing.Drawing2D.LineCap]::Round; $pen.EndCap=[Drawing.Drawing2D.LineCap]::Round
        $cx=[single]($Size/2); $cy=[single]($Size*0.72)
        foreach($radius in @(($Size*0.40),($Size*0.23))){
            $r=[single]$radius
            $graphics.DrawArc($pen,[single]($cx-$r),[single]($cy-$r),[single](2*$r),[single](2*$r),[single]225,[single]90)
        }
        $dot=[single][Math]::Max(2.2,$Size*0.15)
        $graphics.FillEllipse($white,[single]($cx-$dot/2),[single]($cy-$dot/2),$dot,$dot)
    } finally { $path.Dispose();$pen.Dispose();$white.Dispose();$brush.Dispose();$graphics.Dispose() }
    return $bitmap
}
function New-HenuStatusIcon([string]$Level) {
    $size=[Math]::Max(16,[Windows.Forms.SystemInformation]::SmallIconSize.Width)
    $bitmap=New-HenuGlyphBitmap $size (Get-HenuLevelColor $Level)
    try { return [Drawing.Icon]::FromHandle($bitmap.GetHicon()) } finally { $bitmap.Dispose() }
}
function Save-HenuIconFile([string]$Path) {
    # Multi-size .ico with PNG-compressed frames (supported since Windows Vista).
    $sizes=@(16,24,32,48,256)
    $frames=New-Object 'Collections.Generic.List[byte[]]'
    foreach($size in $sizes){
        $bitmap=New-HenuGlyphBitmap $size (Get-HenuLevelColor 'brand')
        $memory=New-Object IO.MemoryStream
        try { $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png); $frames.Add($memory.ToArray()) }
        finally { $memory.Dispose(); $bitmap.Dispose() }
    }
    $output=New-Object IO.MemoryStream
    $writer=New-Object IO.BinaryWriter($output)
    try {
        $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$sizes.Count)
        $offset=6+16*$sizes.Count
        for($i=0;$i -lt $sizes.Count;$i++){
            $dimension=if($sizes[$i] -ge 256){0}else{$sizes[$i]}
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension); $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([UInt16]1); $writer.Write([UInt16]32)
            $writer.Write([UInt32]$frames[$i].Length); $writer.Write([UInt32]$offset)
            $offset+=$frames[$i].Length
        }
        foreach($frame in $frames){ $writer.Write($frame) }
        $writer.Flush()
        [IO.File]::WriteAllBytes($Path,$output.ToArray())
    } finally { $writer.Dispose(); $output.Dispose() }
}
