$ErrorActionPreference = "Stop"
# 构建根目录 = 本脚本所在目录（build\），不再依赖绝对路径
$B = $PSScriptRoot
$rep = Join-Path $B "_build_result.txt"
$o = New-Object System.Collections.ArrayList

Import-Module ps2exe -Force

$embed = @{
    '%ProgramData%\PowerSwitch\SmartPowerSwitch.ps1'      = "$B\src\SmartPowerSwitch.ps1"
    '%ProgramData%\PowerSwitch\PowerSwitchSettings.ps1'   = "$B\src\PowerSwitchSettings.ps1"
    '%ProgramData%\PowerSwitch\PowerSwitchTray.ps1'       = "$B\src\PowerSwitchTray.ps1"
    '%ProgramData%\PowerSwitch\使用说明.html'             = "$B\src\help.html"
    '%ProgramData%\PowerSwitch\power_config.default.json' = "$B\src\power_config.default.json"
    '%ProgramData%\PowerSwitch\icons\icon-saver.ico'      = "$B\src\icon-saver.ico"
    '%ProgramData%\PowerSwitch\icons\icon-balanced.ico'   = "$B\src\icon-balanced.ico"
    '%ProgramData%\PowerSwitch\icons\icon-high.ico'       = "$B\src\icon-high.ico"
    '%ProgramData%\PowerSwitch\icons\icon-paused.ico'     = "$B\src\icon-paused.ico"
    '%ProgramData%\PowerSwitch\icons\icon-unknown.ico'    = "$B\src\icon-unknown.ico"
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
        -version "1.0.2.0" `
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
