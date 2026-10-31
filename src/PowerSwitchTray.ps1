# ============================================================
# PowerSwitchTray.ps1 - 电源模式托盘小工具
# ------------------------------------------------------------
# 托盘图标直接反映当前电源方案：
#     实心绿 = 节能    实心蓝 = 平衡    实心红 = 高性能
#     空心灰 = 已暂停自动切换
#
# 右键菜单：
#     设置…（WinForm 设置窗口）/ 一键切换三种模式
#     暂停或恢复自动切换 / 全天监控（忽略夜间时段）
#     立即检查一次 / 查看日志 / 打开程序目录 / 使用说明 / 退出
#
# 设置窗口实现在同目录 PowerSwitchSettings.ps1，参数写入 power_config.json，
# SmartPowerSwitch.ps1 每次运行都会读取该文件，无需重新注册计划任务。
#
# 依赖：Windows PowerShell 5.1 自带组件（WinForms + Drawing），无需额外安装
# ============================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 路径与配置 ----------
$Root          = $PSScriptRoot
$SwitchScript  = Join-Path $Root "SmartPowerSwitch.ps1"
$SettingsScript = Join-Path $Root "PowerSwitchSettings.ps1"
$ConfigFile    = Join-Path $Root "power_config.json"
$HelpFile      = Join-Path $Root "使用说明.html"
$LogFile       = Join-Path $Root "power_switch.log"
$PauseFile     = Join-Path $Root "automation.paused"
$TrayLog       = Join-Path $Root "tray.log"
$IconDir       = Join-Path $Root "icons"
$TrayLogMaxMB  = 1
$RefreshMs     = 15000

$Schemes = @{
    "PowerSaver"      = "a1841308-3541-4fab-bc81-f71556f20b4a"
    "Balanced"        = "381b4222-f694-41f0-9685-ff5bb260df2e"
    "HighPerformance" = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
}
$GuidToKey = @{}
foreach ($k in $Schemes.Keys) { $GuidToKey[$Schemes[$k]] = $k }

$Label = @{
    "PowerSaver"      = "节能"
    "Balanced"        = "平衡"
    "HighPerformance" = "高性能"
    "Unknown"         = "未知"
}
$DotColor = @{
    "PowerSaver"      = [System.Drawing.Color]::FromArgb(46, 125, 50)
    "Balanced"        = [System.Drawing.Color]::FromArgb(21, 101, 192)
    "HighPerformance" = [System.Drawing.Color]::FromArgb(198, 40, 40)
    "Unknown"         = [System.Drawing.Color]::FromArgb(117, 117, 117)
}
# 状态 -> 图标文件（icons\ 目录，多分辨率 ICO，含 16/20/24/32/40/48/64/128/256 层）
$IconFile = @{
    "PowerSaver"      = "icon-saver.ico"
    "Balanced"        = "icon-balanced.ico"
    "HighPerformance" = "icon-high.ico"
    "Unknown"         = "icon-unknown.ico"
}
$IconFilePaused = "icon-paused.ico"

# ---------- 工具函数 ----------
function Write-TrayLog {
    param([string]$Message)
    try {
        if (Test-Path $TrayLog) {
            if ((Get-Item $TrayLog).Length -ge ($TrayLogMaxMB * 1MB)) {
                $old = "$TrayLog.1"
                if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
                Move-Item $TrayLog $old -Force -ErrorAction SilentlyContinue
            }
        }
        Add-Content -Path $TrayLog -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
    } catch { }
}

function Get-ActiveKey {
    $out = powercfg /getactivescheme
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $g = $Matches[1].ToLower()
        if ($GuidToKey.ContainsKey($g)) { return $GuidToKey[$g] }
        return "Unknown"
    }
    return "Unknown"
}

function Get-CpuPercent {
    try {
        $v = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
        if ($null -eq $v) { return -1 }
        return [int]$v
    } catch { return -1 }
}

function Get-PauseInfo {
    if (-not (Test-Path $PauseFile)) { return $null }
    try { return (Get-Content $PauseFile -Raw | ConvertFrom-Json) }
    catch { return [PSCustomObject]@{ pausedAt = ""; reason = "" } }
}

function Get-TrayRefreshMs {
    $sec = 15
    try {
        if (Test-Path $ConfigFile) {
            $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.TrayRefreshSec) { $sec = [int]$c.TrayRefreshSec }
        }
    } catch { }
    if ($sec -lt 3)   { $sec = 3 }
    if ($sec -gt 300) { $sec = 300 }
    return ($sec * 1000)
}

function Get-AllDayFlag {
    # 返回 $null 表示配置模块不可用（此时菜单项禁用）
    if (-not $script:settingsReady) { return $null }
    try {
        $c = Get-PSSwitchConfig
        return [bool]$c["AllDayMonitor"]
    } catch {
        return $null
    }
}

function New-DotIcon {
    # 回退方案：icons\ 目录缺失或 ICO 加载失败时，用代码画一个圆点
    param([System.Drawing.Color]$Color, [bool]$Hollow = $false)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $pen = New-Object System.Drawing.Pen $Color, 5
    if ($Hollow) { $g.DrawEllipse($pen, 5, 5, 22, 22) }
    else { $g.FillEllipse($brush, 3, 3, 26, 26) }
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    return $icon
}

function New-TrayIcon {
    # 优先加载 icons\ 下的多分辨率 ICO；失败则回退到代码绘制，保证托盘永远有图标
    param([string]$File, [System.Drawing.Color]$Fallback, [bool]$Hollow = $false)
    if ($File) {
        $path = Join-Path $IconDir $File
        if (Test-Path $path) {
            try { return (New-Object System.Drawing.Icon($path)) }
            catch { Write-TrayLog "icon load failed ($File): $_" }
        }
    }
    return (New-DotIcon -Color $Fallback -Hollow $Hollow)
}

function Set-PowerMode {
    param([string]$Key)
    $guid = $Schemes[$Key]
    if (-not $guid) { return $false }
    try {
        $list = (powercfg /list) -join "`n"
        if ($list -notmatch [regex]::Escape($guid)) {
            powercfg /duplicatescheme $guid | Out-Null
        }
        powercfg /setactive $guid | Out-Null
        Start-Sleep -Milliseconds 400
        return ((Get-ActiveKey) -eq $Key)
    } catch {
        Write-TrayLog "Set-PowerMode($Key) failed: $_"
        return $false
    }
}

# ---------- 单实例保护 ----------
$mutex = New-Object System.Threading.Mutex($false, "Global\PowerSwitchTray")
if (-not $mutex.WaitOne(0)) {
    Write-TrayLog "another instance is already running, exiting"
    exit 0
}

# ---------- 图标 ----------
# 四态各一枚多分辨率 ICO：节能绿 / 平衡蓝 / 高性能橙红 / 暂停灰（禁止斜杠）
$script:icons = @{}
foreach ($k in $DotColor.Keys) {
    $script:icons[$k] = New-TrayIcon -File $IconFile[$k] -Fallback $DotColor[$k] -Hollow $false
}
$script:iconPaused = New-TrayIcon -File $IconFilePaused -Fallback ([System.Drawing.Color]::FromArgb(117, 117, 117)) -Hollow $true

# ---------- 加载设置窗口模块（失败不影响托盘其他功能） ----------
$script:settingsReady = $false
$script:settingsBusy  = $false
if (Test-Path $SettingsScript) {
    try {
        . $SettingsScript
        if (Get-Command Show-PowerSwitchSettings -ErrorAction SilentlyContinue) {
            $script:settingsReady = $true
        } else {
            Write-TrayLog "settings module loaded but entry point missing"
        }
    } catch {
        Write-TrayLog "settings module load failed: $_"
    }
} else {
    Write-TrayLog "settings module not found: $SettingsScript"
}

function Open-Settings {
    if (-not $script:settingsReady) {
        $ni.ShowBalloonTip(4000, "设置窗口不可用", "未找到或无法加载 PowerSwitchSettings.ps1，详见 tray.log", [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    # ⚠ 防重入：设置窗口是模态的（ShowDialog 会跑嵌套消息循环），用户在托盘上连点
    #   「设置…」时，排队的菜单点击会在那个嵌套循环里被派发，于是又进来一次、
    #   再叠一个窗口。多个窗口共用同一份 $script:SS 状态，会导致「在旧窗口里改值、
    #   点保存，写进去的却是最上层窗口的旧值」——表现就是「点了保存，配置没变」。
    #   设置模块自己也有单实例守卫，这里是第一道闸。
    if ($script:settingsBusy) {
        Write-TrayLog "settings window already open, ignoring duplicate click"
        return
    }
    $script:settingsBusy = $true
    try {
        Write-TrayLog "settings window opened"
        $applied = Show-PowerSwitchSettings
        if ($applied) {
            $timer.Interval = Get-TrayRefreshMs
            Write-TrayLog "config saved from settings window; tray refresh = $([int]($timer.Interval / 1000))s"
        }
    } catch {
        Write-TrayLog "settings window error: $_"
        $ni.ShowBalloonTip(4000, "设置窗口出错", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Warning)
    } finally {
        $script:settingsBusy = $false
    }
    $script:lastKey = $null
    Update-Tray | Out-Null
}

# ---------- 菜单 ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$miStatus.Enabled = $false
$null = $menu.Items.Add($miStatus)
$null = $menu.Items.Add("-")

$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem "设置…"
if (-not $script:settingsReady) { $miSettings.Enabled = $false }
$null = $menu.Items.Add($miSettings)
$null = $menu.Items.Add("-")

$miSaver    = New-Object System.Windows.Forms.ToolStripMenuItem "切换到节能模式"
$miBalanced = New-Object System.Windows.Forms.ToolStripMenuItem "切换到平衡模式"
$miHigh     = New-Object System.Windows.Forms.ToolStripMenuItem "切换到高性能模式"
foreach ($mi in @($miSaver, $miBalanced, $miHigh)) { $null = $menu.Items.Add($mi) }
$null = $menu.Items.Add("-")

$miPause = New-Object System.Windows.Forms.ToolStripMenuItem "暂停自动切换"
$miAllDay = New-Object System.Windows.Forms.ToolStripMenuItem "全天监控（忽略时段）"
if (-not $script:settingsReady) { $miAllDay.Enabled = $false }
$null = $menu.Items.Add($miPause)
$null = $menu.Items.Add($miAllDay)
$null = $menu.Items.Add("-")

$miRun  = New-Object System.Windows.Forms.ToolStripMenuItem "立即检查一次"
$miLog  = New-Object System.Windows.Forms.ToolStripMenuItem "查看日志"
$miDir  = New-Object System.Windows.Forms.ToolStripMenuItem "打开程序目录"
$miHelp = New-Object System.Windows.Forms.ToolStripMenuItem "使用说明"
foreach ($mi in @($miRun, $miLog, $miDir, $miHelp)) { $null = $menu.Items.Add($mi) }
$null = $menu.Items.Add("-")

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem "退出"
$null = $menu.Items.Add($miExit)

# ---------- 托盘图标 ----------
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.ContextMenuStrip = $menu
$ni.Icon = $script:icons["Unknown"]
$ni.Text = "电源模式托盘"
$ni.Visible = $true

$script:lastKey = $null

function Update-Tray {
    $key   = Get-ActiveKey
    $cpu   = Get-CpuPercent
    $pause = Get-PauseInfo
    $paused = ($null -ne $pause)
    $allDay = Get-AllDayFlag

    $miSaver.Checked    = ($key -eq "PowerSaver")
    $miBalanced.Checked = ($key -eq "Balanced")
    $miHigh.Checked     = ($key -eq "HighPerformance")
    $miPause.Checked    = $paused
    if ($paused) { $miPause.Text = "恢复自动切换" } else { $miPause.Text = "暂停自动切换" }

    if ($null -eq $allDay) {
        $miAllDay.Checked = $false
        $miAllDay.Enabled = $false
    } else {
        $miAllDay.Checked = $allDay
        $miAllDay.Enabled = $true
    }

    if ($cpu -ge 0) { $cpuText = "CPU $cpu%" } else { $cpuText = "CPU --" }
    if ($paused)    { $autoText = "自动: 已暂停" } else { $autoText = "自动: 运行中" }
    if ($allDay)    { $dayText = "  监控: 全天" } else { $dayText = "" }

    $miStatus.Text = "当前: $($Label[$key])　$cpuText　$autoText$dayText"

    if ($paused) { $ni.Icon = $script:iconPaused } else { $ni.Icon = $script:icons[$key] }

    $tip = "电源模式: $($Label[$key])　$cpuText　$autoText$dayText"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $ni.Text = $tip

    if ($script:lastKey -and $key -ne $script:lastKey) {
        $ni.ShowBalloonTip(4000, "电源模式已切换", "$($Label[$script:lastKey]) → $($Label[$key])", [System.Windows.Forms.ToolTipIcon]::Info)
        Write-TrayLog "detected switch: $($script:lastKey) -> $key"
    }
    $script:lastKey = $key
    return $key
}

# ---------- 事件 ----------
$miSettings.add_Click({ Open-Settings })

$miSaver.add_Click({
    if (Set-PowerMode "PowerSaver") {
        Write-TrayLog "manual switch -> PowerSaver"
        $ni.ShowBalloonTip(3000, "已切换到节能模式", "自动逻辑若已暂停，该设置会保持", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $ni.ShowBalloonTip(3000, "切换失败", "请查看 tray.log", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    $script:lastKey = $null
    Update-Tray | Out-Null
})

$miBalanced.add_Click({
    if (Set-PowerMode "Balanced") {
        Write-TrayLog "manual switch -> Balanced"
        $ni.ShowBalloonTip(3000, "已切换到平衡模式", "自动逻辑若已暂停，该设置会保持", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $ni.ShowBalloonTip(3000, "切换失败", "请查看 tray.log", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    $script:lastKey = $null
    Update-Tray | Out-Null
})

$miHigh.add_Click({
    if (Set-PowerMode "HighPerformance") {
        Write-TrayLog "manual switch -> HighPerformance"
        $ni.ShowBalloonTip(3000, "已切换到高性能模式", "自动逻辑若已暂停，该设置会保持", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $ni.ShowBalloonTip(3000, "切换失败", "请查看 tray.log", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    $script:lastKey = $null
    Update-Tray | Out-Null
})

$miPause.add_Click({
    if (Test-Path $PauseFile) {
        Remove-Item $PauseFile -Force -ErrorAction SilentlyContinue
        Write-TrayLog "manual override cleared"
        $ni.ShowBalloonTip(3000, "已恢复自动切换", "计划任务下次检查（1 分钟内）重新接管", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $obj = [PSCustomObject]@{
            pausedAt = (Get-Date).ToString("o")
            reason   = "manual (tray)"
            until    = $null
        }
        $obj | ConvertTo-Json | Set-Content -Path $PauseFile -Encoding UTF8
        Write-TrayLog "manual override set"
        $ni.ShowBalloonTip(5000, "已暂停自动切换", "图标变空心即为暂停中。手动选的模式会被保持，再次点击本项恢复", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    Update-Tray | Out-Null
})

$miAllDay.add_Click({
    $cur = Get-AllDayFlag
    if ($null -eq $cur) {
        $ni.ShowBalloonTip(4000, "全天监控不可用", "配置模块未加载，详见 tray.log", [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    try {
        $cfg = Get-PSSwitchConfig
        $newVal = -not $cur
        $cfg["AllDayMonitor"] = $newVal
        Save-PSSwitchConfig -Cfg $cfg
        Write-TrayLog "all-day monitoring -> $newVal"
        $lowKey  = [string]($cfg["NightLowLoadMode"])
        $highKey = [string]($cfg["NightHighLoadMode"])
        if ($newVal) {
            $msg = "24 小时按负载切换：低负载满额 => " + $Label[$lowKey] + "，高负载满额 => " + $Label[$highKey] + "；白天固定模式已停用"
            $ni.ShowBalloonTip(5000, "已开启全天监控", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $msg = "白天固定 " + $Label[[string]($cfg["DayMode"])] + "，仅在 " + $cfg["NightStartHour"] + ":00-" + $cfg["NightEndHour"] + ":00 做负载切换"
            $ni.ShowBalloonTip(5000, "已关闭全天监控", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } catch {
        Write-TrayLog "all-day toggle failed: $_"
        $ni.ShowBalloonTip(4000, "切换失败", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    $script:lastKey = $null
    Update-Tray | Out-Null
})

$miRun.add_Click({
    try {
        Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$SwitchScript`""
        )
        Write-TrayLog "manual run of SmartPowerSwitch.ps1"
    } catch {
        Write-TrayLog "manual run failed: $_"
    }
    Start-Sleep -Seconds 6
    $script:lastKey = $null
    Update-Tray | Out-Null
    $ni.ShowBalloonTip(3000, "已完成一次检查", "详见 power_switch.log", [System.Windows.Forms.ToolTipIcon]::Info)
})

$miLog.add_Click({ try { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" } catch { } })
$miDir.add_Click({ try { Start-Process explorer.exe -ArgumentList "/select,`"$SwitchScript`"" } catch { } })
$miHelp.add_Click({ try { Start-Process "`"$HelpFile`"" } catch { } })

$miExit.add_Click({
    Write-TrayLog "tray exiting"
    $ni.Visible = $false
    $ni.Dispose()
    $mutex.ReleaseMutex()
    [System.Windows.Forms.Application]::Exit()
})

$ni.add_MouseDoubleClick({ Open-Settings })

# ---------- 定时刷新 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = Get-TrayRefreshMs
$timer.add_Tick({ Update-Tray | Out-Null })
$timer.Start()

$menu.add_Opening({ Update-Tray | Out-Null })

# ---------- 启动 ----------
[System.Windows.Forms.Application]::EnableVisualStyles()

# 写 PID 文件：让 PowerSwitch.exe 启动器能准确定位并停止本进程
# （比枚举命令行可靠——ps2exe 宿主里 CIM 查询可能不可用）
$PidFile = Join-Path $Root "tray.pid"
try { Set-Content -Path $PidFile -Value $PID -Encoding UTF8 } catch { Write-TrayLog "pid file write failed: $_" }

Write-TrayLog "tray started (pid $PID), settings module ready: $script:settingsReady"
$current = Update-Tray
$ni.ShowBalloonTip(3000, "电源托盘已启动", "当前模式: $($Label[$current])　右键或双击打开设置", [System.Windows.Forms.ToolTipIcon]::Info)

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    try { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue } catch { }
    Write-TrayLog "tray stopped"
}
