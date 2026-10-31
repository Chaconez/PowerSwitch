$ErrorActionPreference = "Stop"
# 构建根目录 = 本脚本所在目录（build\），不再依赖绝对路径
$B = $PSScriptRoot
$rep = Join-Path $B "_build_result.txt"

# 源码目录：兼容两种布局——src 与 build 同级（本仓库结构），或 src 位于 build 内
$Src = Join-Path $B "src"
if (-not (Test-Path $Src)) { $Src = Join-Path (Split-Path $B -Parent) "src" }
$o = New-Object System.Collections.ArrayList

Import-Module ps2exe -Force

$embed = @{
    '%ProgramData%\PowerSwitch\SmartPowerSwitch.ps1'      = "$Src\SmartPowerSwitch.ps1"
    '%ProgramData%\PowerSwitch\PowerSwitchSettings.ps1'   = "$Src\PowerSwitchSettings.ps1"
    '%ProgramData%\PowerSwitch\PowerSwitchTray.ps1'       = "$Src\PowerSwitchTray.ps1"
    '%ProgramData%\PowerSwitch\使用说明.html'             = "$Src\help.html"
    '%ProgramData%\PowerSwitch\power_config.default.json' = "$Src\power_config.default.json"
    '%ProgramData%\PowerSwitch\icons\icon-saver.ico'      = "$Src\icons\icon-saver.ico"
    '%ProgramData%\PowerSwitch\icons\icon-balanced.ico'   = "$Src\icons\icon-balanced.ico"
    '%ProgramData%\PowerSwitch\icons\icon-high.ico'       = "$Src\icons\icon-high.ico"
    '%ProgramData%\PowerSwitch\icons\icon-paused.ico'     = "$Src\icons\icon-paused.ico"
    '%ProgramData%\PowerSwitch\icons\icon-unknown.ico'    = "$Src\icons\icon-unknown.ico"
}

[void]$o.Add("embed entries: " + $embed.Count)
$missing = @()
foreach ($k in $embed.Keys) { if (-not (Test-Path $embed[$k])) { $missing += $embed[$k] } }
if ($missing.Count -gt 0) {
    [void]$o.Add("MISSING SOURCES: " + ($missing -join ", "))
    $o | Out-File -Encoding utf8 $rep
    exit 1
}

$exe = "$B\PowerSwitch.exe"
if (Test-Path $exe) { Remove-Item $exe -Force }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Invoke-ps2exe -inputFile "$B\Launcher.ps1" -outputFile $exe `
        -iconFile "$B\PowerSwitch.ico" `
        -noConsole -requireAdmin -x64 `
        -title "PowerSwitch" `
        -product "PowerSwitch - Windows power plan automation" `
        -description "Automated Windows power plan switching with tray control" `
        -company "PowerSwitch" `
        -copyright "" `
        -version "1.0.3.0" `
        -embedFiles $embed 2>&1 | ForEach-Object { [void]$o.Add("ps2exe> " + $_) }
    [void]$o.Add("compile finished in " + [int]$sw.Elapsed.TotalSeconds + "s")
} catch {
    [void]$o.Add("COMPILE FAILED: " + $_.Exception.ToString())
}
$sw.Stop()

if (Test-Path $exe) {
    $i = Get-Item $exe
    [void]$o.Add(("exe: {0} bytes  {1}" -f $i.Length, $i.LastWriteTime))
    $vi = $i.VersionInfo
    [void]$o.Add(("  FileVersion={0} Product={1} Desc={2}" -f $vi.FileVersion, $vi.ProductName, $vi.FileDescription))
} else {
    [void]$o.Add("exe NOT produced")
}
$o | Out-File -Encoding utf8 $rep
