# ============================================================
# Smart Power Switch Script v3
# 按时间 + 系统负载自动切换 Windows 电源方案
# ------------------------------------------------------------
# 参数不再写死在本文件里：统一从同目录 power_config.json 读取，
# 可用托盘小工具（PowerSwitchTray.ps1）的「设置…」窗口在线修改。
# 配置文件缺失或某项非法时，自动回落到下面的 ConfigDefaults。
#
# 逻辑：
#   - 白天（非夜间时段）      -> DayMode
#   - 夜间 + 持续低负载 N 分钟 -> NightLowLoadMode
#   - 夜间 + 持续高负载 N 分钟 -> NightHighLoadMode
#   - 防抖动时间靠 power_switch_state.json 跨次运行累计
# ============================================================

# ---------- 路径 ----------
$LogFile    = Join-Path $PSScriptRoot "power_switch.log"
$StateFile  = Join-Path $PSScriptRoot "power_switch_state.json"
$PauseFile  = Join-Path $PSScriptRoot "automation.paused"   # 由托盘/设置窗口创建，存在时暂停自动切换
$ConfigFile = Join-Path $PSScriptRoot "power_config.json"

# ---------- 电源方案 GUID（Windows 标准） ----------
$PowerScheme = @{
    "PowerSaver"          = "a1841308-3541-4fab-bc81-f71556f20b4a"
    "Balanced"            = "381b4222-f694-41f0-9685-ff5bb260df2e"
    "HighPerformance"     = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    "UltimatePerformance" = "e9a42b02-d5df-448d-aa00-03f14749eb61"
}

$SchemeNames = @{
    "PowerSaver"          = "Power Saver"
    "Balanced"            = "Balanced"
    "HighPerformance"     = "High Performance"
    "UltimatePerformance" = "Ultimate Performance"
}

# ---------- 配置默认值（与 PowerSwitchSettings.ps1 保持一致） ----------
$ConfigDefaults = [ordered]@{
    NightStartHour    = 23    # 夜间开始（24 小时制）
    NightEndHour      = 7     # 夜间结束
    AllDayMonitor     = $false # $true = 忽略夜间时段，24 小时都按负载切换
    CpuThreshold      = 20    # CPU 使用率阈值(%)，低于此值视为低负载
    LowLoadDuration   = 5     # 连续低负载满 N 分钟 -> NightLowLoadMode
    HighLoadDuration  = 1     # 连续高负载满 N 分钟 -> NightHighLoadMode
    SampleCount       = 2     # 每次检测的 CPU 采样次数
    SampleIntervalSec = 1     # 采样间隔（秒）
    MaxLogSizeMB      = 5     # 日志超过该大小即轮转（保留一个 .1 归档）
    DayMode           = "Balanced"
    NightLowLoadMode  = "PowerSaver"
    NightHighLoadMode = "Balanced"
}

# ---------- Functions ----------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Write-Host $logLine
    Add-Content -Path $LogFile -Value $logLine
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

function Get-SwitchConfig {
    param([string]$Path = $ConfigFile)
    $cfg = [ordered]@{}
    foreach ($k in $ConfigDefaults.Keys) { $cfg[$k] = $ConfigDefaults[$k] }

    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($ConfigDefaults.Keys)) {
                $p = $raw.PSObject.Properties[$k]
                if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne "") { $cfg[$k] = $p.Value }
            }
        } catch {
            Write-Log "power_config.json 读取失败，全部使用内置默认值: $_" "WARN"
        }
    } else {
        Write-Log "power_config.json 不存在，使用内置默认值（可在托盘「设置…」中保存生成）" "WARN"
    }

    $cfg.NightStartHour    = ConvertTo-IntClamped $cfg.NightStartHour    0   23  $ConfigDefaults.NightStartHour
    $cfg.NightEndHour      = ConvertTo-IntClamped $cfg.NightEndHour      0   23  $ConfigDefaults.NightEndHour
    $cfg.AllDayMonitor     = ConvertTo-Bool $cfg.AllDayMonitor $ConfigDefaults.AllDayMonitor
    $cfg.CpuThreshold      = ConvertTo-IntClamped $cfg.CpuThreshold      1   100 $ConfigDefaults.CpuThreshold
    $cfg.LowLoadDuration   = ConvertTo-IntClamped $cfg.LowLoadDuration   1   180 $ConfigDefaults.LowLoadDuration
    $cfg.HighLoadDuration  = ConvertTo-IntClamped $cfg.HighLoadDuration  1   180 $ConfigDefaults.HighLoadDuration
    $cfg.SampleCount       = ConvertTo-IntClamped $cfg.SampleCount       1   10  $ConfigDefaults.SampleCount
    $cfg.SampleIntervalSec = ConvertTo-IntClamped $cfg.SampleIntervalSec 1   10  $ConfigDefaults.SampleIntervalSec
    $cfg.MaxLogSizeMB      = ConvertTo-IntClamped $cfg.MaxLogSizeMB      1   200 $ConfigDefaults.MaxLogSizeMB

    foreach ($mk in @("DayMode", "NightLowLoadMode", "NightHighLoadMode")) {
        if (-not $PowerScheme.ContainsKey([string]$cfg[$mk])) {
            Write-Log "配置项 $mk 的值 '$($cfg[$mk])' 不是有效电源方案，回落到 $($ConfigDefaults[$mk])" "WARN"
            $cfg[$mk] = $ConfigDefaults[$mk]
        }
    }
    return $cfg
}

function Rotate-LogIfNeeded {
    param([int]$MaxSizeMB = 5)
    if (-not (Test-Path $LogFile)) { return }
    $sizeMB = (Get-Item $LogFile).Length / 1MB
    if ($sizeMB -lt $MaxSizeMB) { return }
    $archive = "$LogFile.1"
    if (Test-Path $archive) { Remove-Item $archive -Force -ErrorAction SilentlyContinue }
    try {
        Move-Item -Path $LogFile -Destination $archive -Force
        Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Log rotated: previous file was $([math]::Round($sizeMB,1)) MB, archived to power_switch.log.1"
    } catch {
        Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] Log rotation failed: $_"
    }
}

function Get-CurrentPowerScheme {
    $result = powercfg /getactivescheme
    if ($result -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        return $Matches[1].ToLower()
    }
    return $null
}

function Get-PowerSchemeKey {
    param([string]$Guid)
    foreach ($key in $PowerScheme.Keys) {
        if ($PowerScheme[$key].ToLower() -eq $Guid.ToLower()) {
            return $key
        }
    }
    return "Unknown"
}

function Set-PowerScheme {
    param([string]$SchemeKey)
    if (-not $PowerScheme.ContainsKey($SchemeKey)) {
        Write-Log "Invalid power scheme: $SchemeKey" "ERROR"
        return $false
    }
    $guid = $PowerScheme[$SchemeKey]
    try {
        powercfg /setactive $guid | Out-Null
        Start-Sleep -Milliseconds 500
        $current = Get-CurrentPowerScheme
        if ($current -eq $guid.ToLower()) {
            Write-Log "Switched to: $($SchemeNames[$SchemeKey])"
            return $true
        } else {
            Write-Log "Switch failed, current: $(Get-PowerSchemeKey $current)" "ERROR"
            return $false
        }
    } catch {
        Write-Log "Switch exception: $_" "ERROR"
        return $false
    }
}

function Get-SystemLoad {
    $cpuSamples = @()
    for ($i = 0; $i -lt $SampleCount; $i++) {
        $cpu = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval $SampleIntervalSec -MaxSamples 1
        $cpuSamples += $cpu.CounterSamples[0].CookedValue
    }
    $avgCpu = [math]::Round(($cpuSamples | Measure-Object -Average).Average, 1)

    $os = Get-CimInstance Win32_OperatingSystem
    $totalMem = $os.TotalVisibleMemorySize
    $freeMem = $os.FreePhysicalMemory
    $memUsage = [math]::Round((($totalMem - $freeMem) / $totalMem) * 100, 1)

    $isLowLoad = ($avgCpu -lt $CpuThreshold)

    return @{
        CpuUsage    = $avgCpu
        MemoryUsage = $memUsage
        IsLowLoad   = $isLowLoad
        LoadState   = if ($isLowLoad) { "Low" } else { "High" }
    }
}

function Is-NightTime {
    $now = Get-Date
    $hour = $now.Hour
    if ($NightStartHour -gt $NightEndHour) {
        return ($hour -ge $NightStartHour -or $hour -lt $NightEndHour)
    } else {
        return ($hour -ge $NightStartHour -and $hour -lt $NightEndHour)
    }
}

function Test-PowerSchemeAvailable {
    param([string]$SchemeKey)
    $guid = $PowerScheme[$SchemeKey]
    $list = powercfg /list
    return ($list -match [regex]::Escape($guid))
}

function Ensure-PowerScheme {
    param([string]$SchemeKey)
    if (-not $PowerScheme.ContainsKey($SchemeKey)) { return }
    if (-not (Test-PowerSchemeAvailable $SchemeKey)) {
        Write-Log "Power scheme '$($SchemeNames[$SchemeKey])' not found, enabling..."
        $guid = $PowerScheme[$SchemeKey]
        powercfg /duplicatescheme $guid | Out-Null
    }
}

function Get-State {
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            return $state
        } catch {
            Write-Log "Failed to read state file, resetting state" "WARN"
        }
    }
    return [PSCustomObject]@{
        LowLoadSince  = $null
        HighLoadSince = $null
        LastLoadState = $null
        LastCheckTime = $null
        CurrentMode   = $null
    }
}

function Save-State {
    param([PSCustomObject]$State)
    $State | ConvertTo-Json | Set-Content $StateFile
}

# ============================================================
#  Main
# ============================================================

# ---- 载入配置 ----
$Cfg = Get-SwitchConfig
$NightStartHour   = [int]$Cfg.NightStartHour
$NightEndHour     = [int]$Cfg.NightEndHour
$AllDayMonitor    = [bool]$Cfg.AllDayMonitor
$CpuThreshold     = [int]$Cfg.CpuThreshold
$LowLoadDuration  = [int]$Cfg.LowLoadDuration
$HighLoadDuration = [int]$Cfg.HighLoadDuration
$SampleCount      = [int]$Cfg.SampleCount
$SampleIntervalSec = [int]$Cfg.SampleIntervalSec
$MaxLogSizeMB     = [int]$Cfg.MaxLogSizeMB
$DayMode          = [string]$Cfg.DayMode
$NightLowLoadMode = [string]$Cfg.NightLowLoadMode
$NightHighLoadMode = [string]$Cfg.NightHighLoadMode

Rotate-LogIfNeeded -MaxSizeMB $MaxLogSizeMB

# Manual override: PowerSwitchTray.ps1 / 设置窗口 放这个文件即暂停自动化
if (Test-Path $PauseFile) {
    $paused = $true
    $untilText = ""
    try {
        $p = Get-Content $PauseFile -Raw | ConvertFrom-Json
        if ($p.until) {
            $until = [DateTime]::Parse($p.until)
            if ((Get-Date) -ge $until) {
                Remove-Item $PauseFile -Force
                $paused = $false
                Write-Log "Manual override expired - resuming automatic switching"
            } else {
                $untilText = " (until $($until.ToString('HH:mm')))"
            }
        }
    } catch { }
    if ($paused) {
        Write-Log "Automation paused by manual override$untilText - skipping"
        exit 0
    }
}

Write-Log "========== Smart Power Switch v4 =========="
Write-Log "Script path: $PSScriptRoot"
Write-Log "Config source: $ConfigFile"
Write-Log "Params: CPU<$CpuThreshold% | low ${LowLoadDuration}min->$NightLowLoadMode | high ${HighLoadDuration}min->$NightHighLoadMode | day->$DayMode | window $(if ($AllDayMonitor) { 'all-day' } else { 'night ' + $NightStartHour + '-' + $NightEndHour }) | log>${MaxLogSizeMB}MB"

$now = Get-Date
$currentScheme = Get-CurrentPowerScheme
$currentKey = Get-PowerSchemeKey $currentScheme

Write-Log "Current scheme: $($SchemeNames[$currentKey])"
Write-Log "Current time: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"

$isNight = Is-NightTime
$useLoadLogic = ($AllDayMonitor -or $isNight)
if ($AllDayMonitor) {
    Write-Log "Is night time: $isNight (night window ${NightStartHour}:00-${NightEndHour}:00) - IGNORED (all-day monitoring ON)"
} else {
    Write-Log "Is night time: $isNight (Night: ${NightStartHour}:00 - ${NightEndHour}:00)"
}

if (-not $useLoadLogic) {
    # 白天：固定使用 DayMode
    Write-Log "Daytime - enforcing $($SchemeNames[$DayMode]) mode"

    if ($currentKey -ne $DayMode) {
        Ensure-PowerScheme $DayMode
        $switched = Set-PowerScheme $DayMode
        if ($switched) {
            $state = Get-State
            $state.LowLoadSince = $null
            $state.HighLoadSince = $null
            $state.LastLoadState = $null
            $state.CurrentMode = $DayMode
            $state.LastCheckTime = $now.ToString("o")
            Save-State $state
        }
    } else {
        Write-Log "Already in $($SchemeNames[$DayMode]) mode"
        $state = Get-State
        $state.LowLoadSince = $null
        $state.HighLoadSince = $null
        $state.LastLoadState = $null
        $state.CurrentMode = $DayMode
        $state.LastCheckTime = $now.ToString("o")
        Save-State $state
    }

    Write-Log "========== Done =========="
    Write-Log ""
    exit 0
}

# 负载监控分支（夜间时段，或已开启全天监控）
if ($AllDayMonitor) {
    Write-Log "All-day monitoring - checking system load..."
} else {
    Write-Log "Night time - checking system load..."
}

$load = Get-SystemLoad
Write-Log "CPU: $($load.CpuUsage)% (threshold: ${CpuThreshold}%)"
Write-Log "Memory: $($load.MemoryUsage)% (informational only)"
Write-Log "Load state: $($load.LoadState)"

$state = Get-State

if ($load.IsLowLoad) {
    if ($state.LastLoadState -ne "Low") {
        Write-Log "Entering LOW load state, starting timer (${LowLoadDuration} min required for $NightLowLoadMode)"
        $state.LowLoadSince = $now.ToString("o")
        $state.HighLoadSince = $null
        $state.LastLoadState = "Low"
    } else {
        $lowSince = [DateTime]::Parse($state.LowLoadSince)
        $elapsed = ($now - $lowSince).TotalMinutes
        Write-Log "Low load for $([math]::Round($elapsed, 1)) min (need ${LowLoadDuration} min)"

        if ($elapsed -ge $LowLoadDuration -and $currentKey -ne $NightLowLoadMode) {
            Write-Log "Low load sustained for ${LowLoadDuration}+ minutes, switching to $($SchemeNames[$NightLowLoadMode])..."
            Ensure-PowerScheme $NightLowLoadMode
            $switched = Set-PowerScheme $NightLowLoadMode
            if ($switched) { $state.CurrentMode = $NightLowLoadMode }
        } elseif ($currentKey -eq $NightLowLoadMode) {
            Write-Log "Already in $($SchemeNames[$NightLowLoadMode]) mode"
            $state.CurrentMode = $NightLowLoadMode
        }
    }
} else {
    if ($state.LastLoadState -ne "High") {
        Write-Log "Entering HIGH load state, starting timer (${HighLoadDuration} min required for $NightHighLoadMode)"
        $state.HighLoadSince = $now.ToString("o")
        $state.LowLoadSince = $null
        $state.LastLoadState = "High"
    } else {
        $highSince = [DateTime]::Parse($state.HighLoadSince)
        $elapsed = ($now - $highSince).TotalMinutes
        Write-Log "High load for $([math]::Round($elapsed, 1)) min (need ${HighLoadDuration} min)"

        if ($elapsed -ge $HighLoadDuration -and $currentKey -ne $NightHighLoadMode) {
            Write-Log "High load sustained for ${HighLoadDuration}+ minutes, switching to $($SchemeNames[$NightHighLoadMode])..."
            Ensure-PowerScheme $NightHighLoadMode
            $switched = Set-PowerScheme $NightHighLoadMode
            if ($switched) { $state.CurrentMode = $NightHighLoadMode }
        } elseif ($currentKey -eq $NightHighLoadMode) {
            Write-Log "Already in $($SchemeNames[$NightHighLoadMode]) mode"
            $state.CurrentMode = $NightHighLoadMode
        }
    }
}

$state.LastCheckTime = $now.ToString("o")
if (-not $state.CurrentMode) { $state.CurrentMode = $currentKey }
Save-State $state

Write-Log "State saved to: $StateFile"
Write-Log "========== Done =========="
Write-Log ""
