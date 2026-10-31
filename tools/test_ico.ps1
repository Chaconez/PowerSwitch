$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Drawing
$dir = "C:\Users\Administrator\WorkBuddy\2026-10-05-17-32-35\_icons_out"
$rep = "C:\Users\Administrator\WorkBuddy\2026-10-05-17-32-35\_icotest.txt"
$o = New-Object System.Collections.ArrayList

foreach ($f in (Get-ChildItem "$dir\*.ico" | Sort-Object Name)) {
    try {
        $ico  = New-Object System.Drawing.Icon($f.FullName)
        $bmp  = $ico.ToBitmap()
        $cx = [int]($bmp.Width / 2); $cy = [int]($bmp.Height / 2)
        $c  = $bmp.GetPixel($cx, $cy)
        $c2 = $bmp.GetPixel([int]($bmp.Width * 0.28), [int]($bmp.Height * 0.28))
        $cn = $bmp.GetPixel(0, 0)
        [void]$o.Add(("{0}: native={1}x{2} defaultBitmap={3}x{4} center=A{5},R{6},G{7},B{8} | q=A{9}R{10}G{11}B{12} | corner A{13} | ok" -f `
            $f.Name, $ico.Width, $ico.Height, $bmp.Width, $bmp.Height, `
            $c.A, $c.R, $c.G, $c.B, $c2.A, $c2.R, $c2.G, $c2.B, $cn.A))
        $ico.Dispose(); $bmp.Dispose()
    } catch {
        [void]$o.Add(("{0}: LOAD FAIL -> {1}" -f $f.Name, $_.Exception.Message))
    }
}

# 指定尺寸加载（托盘常用 16 / 32）
[void]$o.Add("=== sized load ===")
foreach ($sz in @(16, 32, 48)) {
    try {
        $ico = New-Object System.Drawing.Icon("$dir\icon-balanced.ico", $sz, $sz)
        [void]$o.Add(("requested {0} -> got {1}x{2}" -f $sz, $ico.Width, $ico.Height))
        $ico.Dispose()
    } catch { [void]$o.Add(("requested {0} FAIL: {1}" -f $sz, $_.Exception.Message)) }
}

# 手工解析层目录，确认每层的格式
[void]$o.Add("=== layer directory (raw) ===")
$bytes = [System.IO.File]::ReadAllBytes("$dir\icon-balanced.ico")
$count = [BitConverter]::ToUInt16($bytes, 4)
[void]$o.Add("layers declared: $count")
for ($i = 0; $i -lt $count; $i++) {
    $b = 6 + 16 * $i
    $w = $bytes[$b]; if ($w -eq 0) { $w = 256 }
    $h = $bytes[$b + 1]; if ($h -eq 0) { $h = 256 }
    $bits = [BitConverter]::ToUInt16($bytes, $b + 6)
    $len = [BitConverter]::ToUInt32($bytes, $b + 8)
    $off = [BitConverter]::ToUInt32($bytes, $b + 12)
    $sig = ""
    if ($bytes[$off] -eq 0x89 -and $bytes[$off + 1] -eq 0x50) { $sig = "PNG" }
    elseif ([BitConverter]::ToUInt32($bytes, $off) -eq 40) { $sig = "DIB" }
    [void]$o.Add(("  layer {0}: {1}x{2} bits={3} bytes={4} offset={5} fmt={6}" -f $i, $w, $h, $bits, $len, $off, $sig))
}

$o | Out-File -Encoding utf8 $rep
