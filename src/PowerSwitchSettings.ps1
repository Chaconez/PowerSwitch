# ============================================================
# PowerSwitchSettings.ps1 — 电源模式设置窗口（WinForm）
# ------------------------------------------------------------
# 由 PowerSwitchTray.ps1 以点源方式加载，托盘右键「设置…」打开。
# 本文件自包含：自带配置读写与电源方案操作，不依赖托盘里的函数，
# 因此也可以单独运行来做冒烟测试。
#
# 参数统一存放在同目录 power_config.json，保存后 SmartPowerSwitch.ps1
# 在下次运行（≤1 分钟）时自动采用新参数（按夜间时段、或勾选「全天监控」
# 后 24 小时做负载判定与切换）。
#
# 依赖：Windows PowerShell 5.1 自带组件（WinForms + Drawing）
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 路径 ----------
$script:PSRoot   = if ($PSScriptRoot) { $PSScriptRoot } elseif ($Root) { $Root } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:PSConfig = Join-Path $script:PSRoot "power_config.json"
$script:PSSwitch = Join-Path $script:PSRoot "SmartPowerSwitch.ps1"
$script:PSPause  = Join-Path $script:PSRoot "automation.paused"
$script:PSState  = Join-Path $script:PSRoot "power_switch_state.json"
$script:PSLog    = Join-Path $script:PSRoot "power_switch.log"
$script:PSTrayLog = Join-Path $script:PSRoot "tray.log"
# 「开机自动启动」的实现载体：托盘计划任务（LogonTrigger，随登录启动）
$script:PSTrayTask = "PowerSwitchTray"

# ---------- 配置默认值（必须与 SmartPowerSwitch.ps1 内置默认保持一致） ----------
$script:PSDefaults = [ordered]@{
    NightStartHour    = 23
    NightEndHour      = 7
    AllDayMonitor     = $false
    CpuThreshold      = 20
    LowLoadDuration   = 5
    HighLoadDuration  = 1
    SampleCount       = 2
    SampleIntervalSec = 1
    MaxLogSizeMB      = 5
    TrayRefreshSec    = 15
    DayMode           = "Balanced"
    NightLowLoadMode  = "PowerSaver"
    NightHighLoadMode = "Balanced"
}

# ---------- 电源方案 ----------
$script:PSSchemeGuid = [ordered]@{
    "PowerSaver"      = "a1841308-3541-4fab-bc81-f71556f20b4a"
    "Balanced"        = "381b4222-f694-41f0-9685-ff5bb260df2e"
    "HighPerformance" = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
}
$script:PSModeLabel = @{
    "PowerSaver"      = "节能"
    "Balanced"        = "平衡"
    "HighPerformance" = "高性能"
    "Unknown"         = "未知"
}
$script:PSComboItems = @("节能", "平衡", "高性能")
$script:PSKeyByLabel = @{ "节能" = "PowerSaver"; "平衡" = "Balanced"; "高性能" = "HighPerformance" }
$script:PSLabelByKey = @{ "PowerSaver" = "节能"; "Balanced" = "平衡"; "HighPerformance" = "高性能" }

# ---------- 运行期上下文 ----------
$script:SS = @{
    Form      = $null
    Ctl       = $null
    Cfg       = $null
    Saved     = $false
    AutoTimer = $null
}

# ============================================================
#  基础工具
# ============================================================

function Write-PSSettingsLog {
    param([string]$Message)
    try {
        Add-Content -Path $script:PSTrayLog -Value ("[{0}] [settings] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
    } catch { }
}

function Get-SSFont {
    param([single]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    foreach ($n in @("Microsoft YaHei UI", "Microsoft YaHei", "SimSun")) {
        try { return (New-Object System.Drawing.Font($n, $Size, $Style)) } catch { }
    }
    return (New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericSansSerif, $Size, $Style))
}

function ConvertTo-IntClamped {
    param($Value, [int]$Min, [int]$Max, [int]$Fallback)
    try { $i = [int][double]$Value } catch { return $Fallback }
    if ($i -lt $Min) { return $Min }
    if ($i -gt $Max) { return $Max }
    return $i
}

function ConvertTo-Bool {
    param($Value, [bool]$Fallback = $false)
    if ($null -eq $Value) { return $Fallback }
    if ($Value -is [bool]) { return $Value }
    $s = "$Value".Trim().ToLower()
    if ($s -in @("1", "true", "yes", "on", "是")) { return $true }
    if ($s -in @("0", "false", "no", "off", "否")) { return $false }
    return $Fallback
}

# ---------- 开机自启 ----------
# 真值 = 计划任务「PowerSwitchTray」的启用状态（不是 power_config.json 里的字段）：
# 任务被停用即「不开机自启」，这样用任务计划程序手动改过也不会与界面打架。
# 需要管理员权限；设置窗口由托盘（以最高权限运行）点源加载，天然满足。

function Get-PSAutostartState {
    # $true = 已启用随登录自启；$false = 已停用；$null = 任务不存在 / 查不到（界面禁用该框）
    # ⚠ 判据必须是 Settings.Enabled，不能用 State：托盘正在运行时任务 State 恒为
    #   "Running"，即便已被 Disable-ScheduledTask 停用也不会变成 "Disabled"，
    #   用 State 判断会出现「明明已经停用、勾选框还打着勾」的假象。
    try {
        $t = Get-ScheduledTask -TaskName $script:PSTrayTask -ErrorAction Stop
        if (-not $t) { return $null }
        return [bool]$t.Settings.Enabled
    } catch {
        return $null
    }
}

function Set-PSAutostartState {
    # 返回 $null 表示成功（或本来就一致），返回字符串表示失败原因
    param([bool]$Enable)
    try {
        $t = Get-ScheduledTask -TaskName $script:PSTrayTask -ErrorAction Stop
        if (-not $t) { return "未找到计划任务「$($script:PSTrayTask)」，无法修改开机自启" }
        $cur = [bool]$t.Settings.Enabled
        if ($cur -eq $Enable) { return $null }  # 无变化，别白跑一次
        if ($Enable) {
            Enable-ScheduledTask  -TaskName $script:PSTrayTask -ErrorAction Stop | Out-Null
        } else {
            Disable-ScheduledTask -TaskName $script:PSTrayTask -ErrorAction Stop | Out-Null
        }
        Write-PSSettingsLog ("autostart -> $Enable")
        return $null
    } catch {
        Write-PSSettingsLog "autostart toggle failed: $_"
        return "修改开机自启失败：$($_.Exception.Message)"
    }
}

# ---------- 配置读写 ----------

function Get-PSSwitchConfig {
    param([string]$Path = $script:PSConfig)
    $cfg = [ordered]@{}
    foreach ($k in $script:PSDefaults.Keys) { $cfg[$k] = $script:PSDefaults[$k] }

    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($script:PSDefaults.Keys)) {
                $p = $raw.PSObject.Properties[$k]
                if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne "") { $cfg[$k] = $p.Value }
            }
        } catch { }
    }

    $cfg.NightStartHour    = ConvertTo-IntClamped $cfg.NightStartHour    0   23  $script:PSDefaults.NightStartHour
    $cfg.NightEndHour      = ConvertTo-IntClamped $cfg.NightEndHour      0   23  $script:PSDefaults.NightEndHour
    $cfg.AllDayMonitor     = ConvertTo-Bool $cfg.AllDayMonitor $script:PSDefaults.AllDayMonitor
    $cfg.CpuThreshold      = ConvertTo-IntClamped $cfg.CpuThreshold      1   100 $script:PSDefaults.CpuThreshold
    $cfg.LowLoadDuration   = ConvertTo-IntClamped $cfg.LowLoadDuration   1   180 $script:PSDefaults.LowLoadDuration
    $cfg.HighLoadDuration  = ConvertTo-IntClamped $cfg.HighLoadDuration  1   180 $script:PSDefaults.HighLoadDuration
    $cfg.SampleCount       = ConvertTo-IntClamped $cfg.SampleCount       1   10  $script:PSDefaults.SampleCount
    $cfg.SampleIntervalSec = ConvertTo-IntClamped $cfg.SampleIntervalSec 1   10  $script:PSDefaults.SampleIntervalSec
    $cfg.MaxLogSizeMB      = ConvertTo-IntClamped $cfg.MaxLogSizeMB      1   200 $script:PSDefaults.MaxLogSizeMB
    $cfg.TrayRefreshSec    = ConvertTo-IntClamped $cfg.TrayRefreshSec    3   300 $script:PSDefaults.TrayRefreshSec
    foreach ($mk in @("DayMode", "NightLowLoadMode", "NightHighLoadMode")) {
        if (-not $script:PSSchemeGuid.Contains($cfg[$mk])) { $cfg[$mk] = $script:PSDefaults[$mk] }
    }
    return $cfg
}

function Save-PSSwitchConfig {
    param($Cfg, [string]$Path = $script:PSConfig)
    $json = $Cfg | ConvertTo-Json -Depth 4
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

# ---------- 电源方案操作 ----------

function Get-PSActiveKey {
    try { $out = powercfg /getactivescheme } catch { return "Unknown" }
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $g = $Matches[1].ToLower()
        foreach ($k in $script:PSSchemeGuid.Keys) {
            if ($script:PSSchemeGuid[$k] -eq $g) { return $k }
        }
        return "Unknown"
    }
    return "Unknown"
}

function Set-PSScheme {
    param([string]$Key)
    $guid = $script:PSSchemeGuid[$Key]
    if (-not $guid) { return $false }
    try {
        $list = (powercfg /list) -join "`n"
        if ($list -notmatch [regex]::Escape($guid)) { powercfg /duplicatescheme $guid | Out-Null }
        powercfg /setactive $guid | Out-Null
        Start-Sleep -Milliseconds 400
        return ((Get-PSActiveKey) -eq $Key)
    } catch {
        Write-PSSettingsLog "Set-PSScheme($Key) failed: $_"
        return $false
    }
}

function Get-PSCpuPercent {
    try {
        $v = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
        if ($null -eq $v) { return -1 }
        return [int]$v
    } catch { return -1 }
}

function Get-PSMemPercent {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return [int][math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
    } catch { return -1 }
}

# ============================================================
#  控件工厂
# ============================================================

function New-SSLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20, $Font, $ForeColor, [string]$Align = "MiddleLeft")
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = [System.Drawing.Point]::new($X, $Y)
    $l.Size = [System.Drawing.Size]::new($W, $H)
    $l.AutoSize = $false
    $l.TextAlign = [System.Drawing.ContentAlignment]$Align
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.ForeColor = [System.Drawing.Color]::FromArgb(60, 64, 68)
    if ($Font) { $l.Font = $Font }
    if ($ForeColor) { $l.ForeColor = $ForeColor }
    return $l
}

function New-SSNum {
    param([int]$X, [int]$Y, [int]$W = 72, [int]$Min = 0, [int]$Max = 100, [int]$Val = 0, [int]$Step = 1)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = [System.Drawing.Point]::new($X, $Y)
    $n.Size = [System.Drawing.Size]::new($W, 24)
    $n.Minimum = $Min
    $n.Maximum = $Max
    $n.Increment = $Step
    if ($Val -lt $Min) { $Val = $Min }
    if ($Val -gt $Max) { $Val = $Max }
    $n.Value = $Val
    $n.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $n.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    return $n
}

function New-SSCombo {
    param([int]$X, [int]$Y, [int]$W = 120, [string[]]$Items, [string]$Selected)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = [System.Drawing.Point]::new($X, $Y)
    $c.Size = [System.Drawing.Size]::new($W, 24)
    $c.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    if ($Selected -and $c.Items.Contains($Selected)) { $c.SelectedItem = $Selected }
    elseif ($c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
    return $c
}

function New-SSCheck {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 400, $Font)
    $k = New-Object System.Windows.Forms.CheckBox
    $k.Text = $Text
    $k.Location = [System.Drawing.Point]::new($X, $Y)
    $k.Size = [System.Drawing.Size]::new($W, 24)
    $k.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    if ($Font) { $k.Font = $Font }
    return $k
}

function New-SSButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 32, $Font, $ForeColor)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = [System.Drawing.Point]::new($X, $Y)
    $b.Size = [System.Drawing.Size]::new($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(198, 203, 209)
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = [System.Drawing.Color]::White
    $b.UseVisualStyleBackColor = $false
    if ($Font) { $b.Font = $Font }
    if ($ForeColor) { $b.ForeColor = $ForeColor }
    return $b
}

function New-SSGroup {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font, $BackColor, $ForeColor)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text
    $g.Location = [System.Drawing.Point]::new($X, $Y)
    $g.Size = [System.Drawing.Size]::new($W, $H)
    if ($Font) { $g.Font = $Font }
    if ($BackColor) { $g.BackColor = $BackColor }
    if ($ForeColor) { $g.ForeColor = $ForeColor }
    return $g
}

# ============================================================
#  状态刷新
# ============================================================

function Update-PSStatusView {
    $c = $script:SS.Ctl
    if (-not $c) { return }
    $cfg = $script:SS.Cfg

    $key = Get-PSActiveKey
    $cpu = Get-PSCpuPercent
    $mem = Get-PSMemPercent

    $c.Mode.Text = "当前模式：$($script:PSModeLabel[$key])"
    switch ($key) {
        "PowerSaver"      { $c.Mode.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50) }
        "Balanced"        { $c.Mode.ForeColor = [System.Drawing.Color]::FromArgb(21, 101, 192) }
        "HighPerformance" { $c.Mode.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40) }
        default           { $c.Mode.ForeColor = [System.Drawing.Color]::FromArgb(117, 117, 117) }
    }

    if ($cpu -ge 0) { $c.Cpu.Text = "CPU：$cpu%（阈值 $($cfg.CpuThreshold)%）" } else { $c.Cpu.Text = "CPU：--" }
    if ($mem -ge 0) { $c.Mem.Text = "内存：$mem%（仅记录）" } else { $c.Mem.Text = "内存：--" }

    if (Test-Path $script:PSPause) {
        $c.Auto.Text = "自动切换：已暂停"
        $c.Auto.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
    } else {
        $c.Auto.Text = "自动切换：运行中"
        $c.Auto.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    }

    $st = $null
    try {
        if (Test-Path $script:PSState) { $st = Get-Content $script:PSState -Raw -Encoding UTF8 | ConvertFrom-Json }
    } catch { }

    if ($st -and $st.LastLoadState) {
        if ($st.LastLoadState -eq "Low") {
            $c.Judge.Text = "判定：低负载"
            $since = $st.LowLoadSince
            $need = [int]$cfg.LowLoadDuration
            $target = $script:PSModeLabel[[string]$cfg.NightLowLoadMode]
        } else {
            $c.Judge.Text = "判定：高负载"
            $since = $st.HighLoadSince
            $need = [int]$cfg.HighLoadDuration
            $target = $script:PSModeLabel[[string]$cfg.NightHighLoadMode]
        }
        $c.Judge.ForeColor = [System.Drawing.Color]::FromArgb(60, 64, 68)
        $elapsed = 0.0
        try { if ($since) { $elapsed = ((Get-Date) - [DateTime]::Parse([string]$since)).TotalMinutes } } catch { }
        if ($elapsed -lt 0) { $elapsed = 0 }
        $c.Since.Text = ("持续：{0:N1}/{1} 分钟 → {2}" -f $elapsed, $need, $target)
    } else {
        $c.Judge.Text = "判定：--"
        $c.Since.Text = "持续：--"
    }
}

function Apply-AllDayUiState {
    $c = $script:SS.Ctl
    if (-not $c -or -not $c.ChkAllDay) { return }
    $on = [bool]$c.ChkAllDay.Checked

    # 全天监控时，夜间时段不参与判定，直接禁用避免误改
    $c.NudNightStart.Enabled = (-not $on)
    $c.NudNightEnd.Enabled   = (-not $on)

    if ($on) {
        $c.LblLowHint.Text  = "满额后切到「低负载」模式"
        $c.LblHighHint.Text = "满额后切到「高负载」模式"
        $c.LblDayMap.Text   = "白天（当前未启用）"
        $c.LblLowMap.Text   = "低负载持续后"
        $c.LblHighMap.Text  = "高负载持续后"
    } else {
        $c.LblLowHint.Text  = "满额后切到「夜间·低负载」模式"
        $c.LblHighHint.Text = "满额后切到「夜间·高负载」模式"
        $c.LblDayMap.Text   = "白天（非夜间时段）"
        $c.LblLowMap.Text   = "夜间 · 低负载持续后"
        $c.LblHighMap.Text  = "夜间 · 高负载持续后"
    }
}

# ============================================================
#  表单构建 / 载入 / 保存
# ============================================================

function Load-PSConfigIntoForm {
    param($Cfg)
    $c = $script:SS.Ctl
    $c.NudCpu.Value        = ConvertTo-IntClamped $Cfg.CpuThreshold      1   100 $script:PSDefaults.CpuThreshold
    $c.NudLow.Value        = ConvertTo-IntClamped $Cfg.LowLoadDuration   1   180 $script:PSDefaults.LowLoadDuration
    $c.NudHigh.Value       = ConvertTo-IntClamped $Cfg.HighLoadDuration  1   180 $script:PSDefaults.HighLoadDuration
    $c.NudNightStart.Value = ConvertTo-IntClamped $Cfg.NightStartHour    0   23  $script:PSDefaults.NightStartHour
    $c.NudNightEnd.Value   = ConvertTo-IntClamped $Cfg.NightEndHour      0   23  $script:PSDefaults.NightEndHour
    $c.NudSample.Value     = ConvertTo-IntClamped $Cfg.SampleCount       1   10  $script:PSDefaults.SampleCount
    $c.NudInterval.Value   = ConvertTo-IntClamped $Cfg.SampleIntervalSec 1   10  $script:PSDefaults.SampleIntervalSec
    $c.NudLog.Value        = ConvertTo-IntClamped $Cfg.MaxLogSizeMB      1   200 $script:PSDefaults.MaxLogSizeMB
    $c.NudRefresh.Value    = ConvertTo-IntClamped $Cfg.TrayRefreshSec    3   300 $script:PSDefaults.TrayRefreshSec

    $c.CmbDay.SelectedItem       = $script:PSLabelByKey[[string]$Cfg.DayMode]
    $c.CmbNightLow.SelectedItem  = $script:PSLabelByKey[[string]$Cfg.NightLowLoadMode]
    $c.CmbNightHigh.SelectedItem = $script:PSLabelByKey[[string]$Cfg.NightHighLoadMode]

    # ⚠ 复选框必须显式赋值：CheckBox 新建时 Checked 恒为 $false，
    # 不赋值就会出现「关掉窗口再打开，勾选状态回到默认（未勾选）」，更糟的是
    # 用户顺手点「保存并应用」会把生效中的开关静默改掉（全天监控被关掉过好几次）。
    $c.ChkPause.Checked = (Test-Path $script:PSPause)
    $c.ChkAllDay.Checked = ConvertTo-Bool $Cfg.AllDayMonitor $false

    if ($c.ChkAutoStart) {
        $auto = Get-PSAutostartState
        if ($null -eq $auto) {
            $c.ChkAutoStart.Checked = $false
            $c.ChkAutoStart.Enabled = $false
            $c.ChkAutoStart.Text = "开机自动启动（未找到计划任务「$($script:PSTrayTask)」，暂不可用）"
        } else {
            $c.ChkAutoStart.Checked = $auto
            $c.ChkAutoStart.Enabled = $true
            $c.ChkAutoStart.Text = "开机自动启动（登录 Windows 后自动运行托盘）"
        }
    }
    Apply-AllDayUiState
}

function Save-PSConfigFromForm {
    # 每次保存尝试都先把「上次成功过」的标记清掉：否则先成功后失败时，
    # 窗口仍按成功渲染（绿字 + 刷新状态），托盘也会误判这次也存上了。
    $script:SS.Saved = $false

    $c = $script:SS.Ctl
    $nightStart = [int]$c.NudNightStart.Value
    $nightEnd   = [int]$c.NudNightEnd.Value
    $allDay     = [bool]$c.ChkAllDay.Checked

    # 全天监控时不看夜间时段，因此只有未勾选时才要求起止不同
    if ((-not $allDay) -and ($nightStart -eq $nightEnd)) {
        return "夜间开始与结束时间不能相同，未保存"
    }

    $new = [ordered]@{
        NightStartHour    = $nightStart
        NightEndHour      = $nightEnd
        AllDayMonitor     = $allDay
        CpuThreshold      = [int]$c.NudCpu.Value
        LowLoadDuration   = [int]$c.NudLow.Value
        HighLoadDuration  = [int]$c.NudHigh.Value
        SampleCount       = [int]$c.NudSample.Value
        SampleIntervalSec = [int]$c.NudInterval.Value
        MaxLogSizeMB      = [int]$c.NudLog.Value
        TrayRefreshSec    = [int]$c.NudRefresh.Value
        DayMode           = $script:PSKeyByLabel[[string]$c.CmbDay.SelectedItem]
        NightLowLoadMode  = $script:PSKeyByLabel[[string]$c.CmbNightLow.SelectedItem]
        NightHighLoadMode = $script:PSKeyByLabel[[string]$c.CmbNightHigh.SelectedItem]
    }

    try {
        Save-PSSwitchConfig -Cfg $new
    } catch {
        return "保存失败：$($_.Exception.Message)"
    }

    # 暂停开关：与托盘共用 automation.paused
    try {
        if ($c.ChkPause.Checked) {
            if (-not (Test-Path $script:PSPause)) {
                $obj = [PSCustomObject]@{ pausedAt = (Get-Date).ToString("o"); reason = "manual (settings window)"; until = $null }
                $obj | ConvertTo-Json | Set-Content -Path $script:PSPause -Encoding UTF8
                Write-PSSettingsLog "pause flag created from settings window"
            }
        } else {
            if (Test-Path $script:PSPause) {
                Remove-Item $script:PSPause -Force -ErrorAction SilentlyContinue
                Write-PSSettingsLog "pause flag removed from settings window"
            }
        }
    } catch {
        Write-PSSettingsLog "pause toggle failed: $_"
    }

    # 开机自启：真值在计划任务上，不在 JSON 里，所以单独应用一次
    $autoMsg = ""
    if ($c.ChkAutoStart -and $c.ChkAutoStart.Enabled) {
        $autoWant   = [bool]$c.ChkAutoStart.Checked
        $autoBefore = Get-PSAutostartState
        $autoErr    = Set-PSAutostartState -Enable $autoWant
        if ($autoErr) {
            $autoMsg = "；$autoErr"
        } elseif (($null -ne $autoBefore) -and ($autoBefore -ne $autoWant)) {
            $autoMsg = "；开机自启已" + $(if ($autoWant) { "启用" } else { "停用" })
        }
    }

    $script:SS.Cfg = Get-PSSwitchConfig
    $script:SS.Saved = $true
    Write-PSSettingsLog ("config saved: cpu=$($new.CpuThreshold)% allDay=$allDay night=${nightStart}-${nightEnd} low=$($new.LowLoadDuration)min -> $($new.NightLowLoadMode)$autoMsg")

    # 把实际写进文件的关键参数回显出来。以前只回一句「已保存」，用户没法核对到底存了
    # 什么 —— 真出问题时（例如存进去的是另一个窗口的旧值）根本看不出来。
    $windowText = "夜间 ${nightStart}-${nightEnd} 点"
    if ($allDay) { $windowText = "全天监控 开" }
    $okMsg  = "已保存：CPU 阈值 $($new.CpuThreshold)% · 低负载 $($new.LowLoadDuration) 分钟 · 高负载 $($new.HighLoadDuration) 分钟 · $windowText"
    $okMsg += "；后台将在 ≤1 分钟内按新参数运行$autoMsg"
    return $okMsg
}

function New-PowerSwitchSettingsForm {
    $cfg = Get-PSSwitchConfig
    $script:SS.Cfg = $cfg

    $cCard  = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $cBg    = [System.Drawing.Color]::FromArgb(245, 246, 248)
    $cMain  = [System.Drawing.Color]::FromArgb(33, 33, 33)
    $cSub   = [System.Drawing.Color]::FromArgb(117, 117, 117)
    $cGreen = [System.Drawing.Color]::FromArgb(46, 125, 50)
    $cBlue  = [System.Drawing.Color]::FromArgb(21, 101, 192)
    $cRed   = [System.Drawing.Color]::FromArgb(198, 40, 40)

    $fN = Get-SSFont 9
    $fB = Get-SSFont 9  ([System.Drawing.FontStyle]::Bold)
    $fH = Get-SSFont 10.5 ([System.Drawing.FontStyle]::Bold)
    $fG = Get-SSFont 8.5 ([System.Drawing.FontStyle]::Bold)
    $fS = Get-SSFont 8

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "电源模式设置"
    $form.ClientSize = [System.Drawing.Size]::new(560, 726)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.BackColor = $cBg
    $form.Font = $fN
    $form.ForeColor = $cMain

    # ---- 当前状态 ----
    $gb1 = New-SSGroup "当前状态" 14 10 532 96 $fG $cCard $cSub
    $form.Controls.Add($gb1)

    $lMode  = New-SSLabel "当前模式：--" 16 22 170 22 $fH $cMain
    $lCpu   = New-SSLabel "CPU：--"      196 22 158 22 $fN $cMain
    $lMem   = New-SSLabel "内存：--"     356 22 160 22 $fN $cMain
    $lAuto  = New-SSLabel "自动切换：--" 16 54 170 22 $fN $cMain
    $lJudge = New-SSLabel "判定：--"     196 54 158 22 $fN $cMain
    $lSince = New-SSLabel "持续：--"     356 54 160 22 $fN $cMain
    foreach ($x in @($lMode, $lCpu, $lMem, $lAuto, $lJudge, $lSince)) { $gb1.Controls.Add($x) }

    # ---- 手动切换 ----
    $btnSaver    = New-SSButton "节能"          14 114 100 32 $fN $cGreen
    $btnBalanced = New-SSButton "平衡"          122 114 100 32 $fN $cBlue
    $btnHigh     = New-SSButton "高性能"        230 114 100 32 $fN $cRed
    $btnCheck    = New-SSButton "立即检查一次"  346 114 200 32 $fN $cBlue
    foreach ($b in @($btnSaver, $btnBalanced, $btnHigh, $btnCheck)) { $form.Controls.Add($b) }

    # ---- 切换条件 ----
    $gb2 = New-SSGroup "切换条件" 14 154 532 186 $fG $cCard $cSub
    $form.Controls.Add($gb2)

    $gb2.Controls.Add((New-SSLabel "CPU 阈值（%）" 16 28 150 22 $fN))
    $nudCpu = New-SSNum 176 26 72 1 100 $cfg.CpuThreshold
    $gb2.Controls.Add($nudCpu)
    $gb2.Controls.Add((New-SSLabel "低于该值判定为低负载" 258 28 250 22 $fS $cSub))

    $gb2.Controls.Add((New-SSLabel "低负载持续（分钟）" 16 60 150 22 $fN))
    $nudLow = New-SSNum 176 58 72 1 180 $cfg.LowLoadDuration
    $gb2.Controls.Add($nudLow)
    $lblLowHint = New-SSLabel "满额后切到「夜间·低负载」模式" 258 60 250 22 $fS $cSub
    $gb2.Controls.Add($lblLowHint)

    $gb2.Controls.Add((New-SSLabel "高负载持续（分钟）" 16 92 150 22 $fN))
    $nudHigh = New-SSNum 176 90 72 1 180 $cfg.HighLoadDuration
    $gb2.Controls.Add($nudHigh)
    $lblHighHint = New-SSLabel "满额后切到「夜间·高负载」模式" 258 92 250 22 $fS $cSub
    $gb2.Controls.Add($lblHighHint)

    $gb2.Controls.Add((New-SSLabel "夜间时段（小时）" 16 124 150 22 $fN))
    $nudNightStart = New-SSNum 176 122 72 0 23 $cfg.NightStartHour
    $gb2.Controls.Add($nudNightStart)
    $gb2.Controls.Add((New-SSLabel "点 至" 254 124 40 22 $fN))
    $nudNightEnd = New-SSNum 300 122 64 0 23 $cfg.NightEndHour
    $gb2.Controls.Add($nudNightEnd)
    $gb2.Controls.Add((New-SSLabel "点" 370 124 40 22 $fN))

    $chkAllDay = New-SSCheck "全天监控（忽略上面的时段，24 小时都按负载切换）" 16 156 500 24 $fN
    $gb2.Controls.Add($chkAllDay)

    # ---- 模式映射 ----
    $gb3 = New-SSGroup "模式映射（各场景使用的电源方案）" 14 348 532 118 $fG $cCard $cSub
    $form.Controls.Add($gb3)

    $lblDayMap = New-SSLabel "白天（非夜间时段）" 16 26 170 24 $fN
    $gb3.Controls.Add($lblDayMap)
    $cmbDay = New-SSCombo 196 26 130 $script:PSComboItems $script:PSLabelByKey[[string]$cfg.DayMode]
    $gb3.Controls.Add($cmbDay)

    $lblLowMap = New-SSLabel "夜间 · 低负载持续后" 16 58 170 24 $fN
    $gb3.Controls.Add($lblLowMap)
    $cmbNightLow = New-SSCombo 196 58 130 $script:PSComboItems $script:PSLabelByKey[[string]$cfg.NightLowLoadMode]
    $gb3.Controls.Add($cmbNightLow)

    $lblHighMap = New-SSLabel "夜间 · 高负载持续后" 16 90 170 24 $fN
    $gb3.Controls.Add($lblHighMap)
    $cmbNightHigh = New-SSCombo 196 90 130 $script:PSComboItems $script:PSLabelByKey[[string]$cfg.NightHighLoadMode]
    $gb3.Controls.Add($cmbNightHigh)

    # ---- 高级 ----
    $gb4 = New-SSGroup "高级" 14 474 532 152 $fG $cCard $cSub
    $form.Controls.Add($gb4)

    $gb4.Controls.Add((New-SSLabel "采样次数" 16 28 100 24 $fN))
    $nudSample = New-SSNum 120 26 60 1 10 $cfg.SampleCount
    $gb4.Controls.Add($nudSample)

    $gb4.Controls.Add((New-SSLabel "采样间隔（秒）" 200 28 116 24 $fN))
    $nudInterval = New-SSNum 320 26 60 1 10 $cfg.SampleIntervalSec
    $gb4.Controls.Add($nudInterval)

    $gb4.Controls.Add((New-SSLabel "日志上限（MB）" 16 58 100 24 $fN))
    $nudLog = New-SSNum 120 56 60 1 200 $cfg.MaxLogSizeMB
    $gb4.Controls.Add($nudLog)

    $gb4.Controls.Add((New-SSLabel "托盘刷新（秒）" 200 58 116 24 $fN))
    $nudRefresh = New-SSNum 320 56 60 3 300 $cfg.TrayRefreshSec
    $gb4.Controls.Add($nudRefresh)

    $chkAutoStart = New-SSCheck "开机自动启动（登录 Windows 后自动运行托盘）" 16 86 460 $fN
    $gb4.Controls.Add($chkAutoStart)

    $chkPause = New-SSCheck "暂停自动切换（保持手动选择的模式，图标变空心）" 16 116 460 $fN
    $gb4.Controls.Add($chkPause)

    # ---- 底部按钮 ----
    $btnSave    = New-SSButton "保存并应用" 14 634 140 36 $fB $cBlue
    $btnDefault = New-SSButton "恢复默认"   162 634 110 36 $fN
    $btnLog     = New-SSButton "打开日志"   280 634 110 36 $fN
    $btnClose   = New-SSButton "关闭"       446 634 100 36 $fN
    foreach ($b in @($btnSave, $btnDefault, $btnLog, $btnClose)) { $form.Controls.Add($b) }

    $lblHint = New-SSLabel "" 16 678 530 40 $fS $cSub
    $lblHint.Text = "配置文件：$script:PSConfig"
    $lblHint.ForeColor = $cSub
    $form.Controls.Add($lblHint)

    # ⚠ 每建一个新窗口都会覆盖 $script:SS，而所有窗口的按钮事件读的都是 $script:SS.Ctl
    #   —— 也就是「最后创建」的那个表单。若同时存在两个窗口，用户在旧窗口里改值、
    #   点「保存并应用」，写进去的其实是新窗口里的旧值，提示还照样显示「已保存」。
    #   （托盘连点「设置…」时真会发生：模态窗口的嵌套消息循环仍会派发排队的菜单点击。）
    #   正常路径由 Show-PowerSwitchSettings 的单实例守卫挡住，这里再留一条日志，
    #   万一将来又有别的路径叠出窗口，能一眼定位。
    if ($script:SS.Form -and (-not $script:SS.Form.IsDisposed)) {
        Write-PSSettingsLog "WARN: a settings form is already open; the older window's buttons will read the NEW form's controls"
    }

    $script:SS.Form = $form
    $script:SS.Ctl = @{
        Mode = $lMode; Cpu = $lCpu; Mem = $lMem; Auto = $lAuto; Judge = $lJudge; Since = $lSince
        NudCpu = $nudCpu; NudLow = $nudLow; NudHigh = $nudHigh
        NudNightStart = $nudNightStart; NudNightEnd = $nudNightEnd
        NudSample = $nudSample; NudInterval = $nudInterval; NudLog = $nudLog; NudRefresh = $nudRefresh
        CmbDay = $cmbDay; CmbNightLow = $cmbNightLow; CmbNightHigh = $cmbNightHigh
        ChkPause = $chkPause; ChkAllDay = $chkAllDay; ChkAutoStart = $chkAutoStart
        LblLowHint = $lblLowHint; LblHighHint = $lblHighHint
        LblDayMap = $lblDayMap; LblLowMap = $lblLowMap; LblHighMap = $lblHighMap
        Save = $btnSave; Default = $btnDefault; Log = $btnLog; Close = $btnClose
        Hint = $lblHint
    }

    # ---- 事件 ----
    $chkAllDay.Add_CheckedChanged({ Apply-AllDayUiState })
    # 构建末尾用「配置文件 + 哨兵文件 + 计划任务」的真实状态统一渲染一遍：
    # 复选框新建时 Checked 恒为 $false，只靠上面构造参数里的 $cfg 是覆盖不到的。
    Load-PSConfigIntoForm $cfg
    $btnSaver.Add_Click({
        if (Set-PSScheme "PowerSaver") { $script:SS.Ctl.Hint.Text = "已手动切换到节能模式" }
        else { $script:SS.Ctl.Hint.Text = "切换到节能模式失败，请查看 tray.log" }
        Update-PSStatusView
    })
    $btnBalanced.Add_Click({
        if (Set-PSScheme "Balanced") { $script:SS.Ctl.Hint.Text = "已手动切换到平衡模式" }
        else { $script:SS.Ctl.Hint.Text = "切换到平衡模式失败，请查看 tray.log" }
        Update-PSStatusView
    })
    $btnHigh.Add_Click({
        if (Set-PSScheme "HighPerformance") { $script:SS.Ctl.Hint.Text = "已手动切换到高性能模式" }
        else { $script:SS.Ctl.Hint.Text = "切换到高性能模式失败，请查看 tray.log" }
        Update-PSStatusView
    })

    $btnCheck.Add_Click({
        try {
            $script:SS.Ctl.Hint.Text = "已触发一次检查，结果稍后写入 power_switch.log…"
            Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$script:PSSwitch`""
            )
            Write-PSSettingsLog "manual check requested from settings window"
        } catch {
            $script:SS.Ctl.Hint.Text = "触发检查失败：$($_.Exception.Message)"
        }
    })

    $btnSave.Add_Click({
        $msg = Save-PSConfigFromForm
        $ctl = $script:SS.Ctl
        $ctl.Hint.Text = $msg
        if ($script:SS.Saved) {
            $ctl.Hint.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
            Update-PSStatusView
        } else {
            # 保存失败必须一眼看出来：以前失败也只是灰字提示，用户会以为存上了。
            $ctl.Hint.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
        }
    })

    $btnDefault.Add_Click({
        Load-PSConfigIntoForm $script:PSDefaults
        $script:SS.Ctl.Hint.Text = "已填入默认值，点「保存并应用」后生效"
    })

    $btnLog.Add_Click({
        try { Start-Process notepad.exe -ArgumentList "`"$script:PSLog`"" } catch { }
    })

    $btnClose.Add_Click({ $script:SS.Form.Close() })

    return $form
}

# ============================================================
#  对外入口
# ============================================================

function Show-PowerSwitchSettings {
    param([int]$AutoCloseMs = 0, [switch]$SaveForTest)

    # ---------- 单实例守卫（重要）----------
    # ⚠ 托盘的「设置…」菜单项在模态窗口的嵌套消息循环里仍可能被再次派发
    #   （用户连点几次、或菜单点击消息排队），于是叠出好几个设置窗口。
    #   而 $script:SS 全局只有一份，每建一个窗口就被覆盖一次，$script:SS.Ctl 永远
    #   指向「最后创建」的那个表单 —— 用户在第 2 个窗口里改值、点「保存并应用」，
    #   实际读到的是最上层窗口的旧值：窗口提示「已保存」，配置却纹丝不动，
    #   重新打开还是原配置。这个坑必须从源头堵死，不能指望用户别连点。
    if ($script:SS -and $script:SS.Form -and (-not $script:SS.Form.IsDisposed)) {
        try {
            if ($script:SS.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $script:SS.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
            $script:SS.Form.Activate()
            $script:SS.Form.BringToFront()
            Write-PSSettingsLog "settings window already open, activating the existing one"
        } catch {
            Write-PSSettingsLog "activate existing settings window failed: $_"
        }
        return $false
    }

    $form = New-PowerSwitchSettingsForm
    $script:SS.Saved = $false

    if ($SaveForTest) {
        $msg = Save-PSConfigFromForm
        $form.Dispose()
        return $msg
    }

    $script:SS.Ctl.Hint.Text = "配置文件：$script:PSConfig"
    Update-PSStatusView

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 3000
    $t.add_Tick({ Update-PSStatusView })
    $t.Start()
    $script:SS.AutoTimer = $t

    if ($AutoCloseMs -gt 0) {
        $ct = New-Object System.Windows.Forms.Timer
        $ct.Interval = $AutoCloseMs
        $ct.add_Tick({
            $ct.Stop()
            try { $script:SS.Form.Close() } catch { }
        })
        $ct.Start()
        $script:SS.AutoCloseTimer = $ct
    }

    try {
        [void]$form.ShowDialog()
    } finally {
        try { $t.Stop(); $t.Dispose() } catch { }
        try { if ($script:SS.AutoCloseTimer) { $script:SS.AutoCloseTimer.Stop(); $script:SS.AutoCloseTimer.Dispose() } } catch { }
        try { $form.Dispose() } catch { }
        # 窗口关掉后必须把共享状态清空：既让下次「设置…」能正常开新窗口，
        # 也避免残留的定时器（每 3 秒刷状态）去访问已释放的控件而抛异常。
        $script:SS.Form = $null
        $script:SS.Ctl  = $null
        Write-PSSettingsLog ("settings window closed (saved=$($script:SS.Saved))")
    }
    return $script:SS.Saved
}

# ============================================================
#  独立运行入口
# ------------------------------------------------------------
# 只有「本文件被当作脚本直接执行」时才自动打开设置窗口，其余加载方式一律安静返回，
# 否则托盘启动或任何工具加载本模块时都会莫名弹出一个窗口。
#
# $MyInvocation.InvocationName 实测取值（PS 5.1）：
#   powershell -File PowerSwitchSettings.ps1  -> 完整路径   => 是入口，弹窗
#   & .\PowerSwitchSettings.ps1               -> "&"        => 是入口，弹窗
#   . .\PowerSwitchSettings.ps1  （托盘点源）  -> "."        => 不是入口
#   Import-Module .\PowerSwitchSettings.ps1   -> ""（空串）  => 不是入口
#
# ⚠ 别只判 `-ne "."`：Import-Module 时该值是空字符串而不是 "."，只判点号会让
#   「把本文件当模块加载」这条路径也弹出窗口（实测会卡住调用方，因为 ShowDialog 是模态的）。
# ============================================================
$invName = $MyInvocation.InvocationName
$isEntryPoint = (-not [string]::IsNullOrEmpty($invName)) -and ($invName -ne '.')
if ($isEntryPoint) {
    [void](Show-PowerSwitchSettings)
}
