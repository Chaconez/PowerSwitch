# ============================================================
# PowerSwitch.exe 启动器 / 安装器
# ------------------------------------------------------------
# 编译方式（PS2EXE）：
#   Invoke-ps2exe -inputFile Launcher.ps1 -outputFile PowerSwitch.exe `
#       -iconFile build\PowerSwitch.ico -noConsole -requireAdmin `
#       -title "PowerSwitch" -product "电源模式自动切换" -version "1.0.0.0" `
#       -embedFiles @{ '目标路径' = '源文件' ... }
#
# 行为：
#   PowerSwitch.exe             安装/更新 + 启动托盘（幂等，随便重复运行）
#   PowerSwitch.exe --install   同上
#   PowerSwitch.exe --settings  打开设置窗口
#   PowerSwitch.exe --uninstall 删除计划任务并停止托盘（保留程序文件与配置）
#   PowerSwitch.exe --status    显示当前状态
#   PowerSwitch.exe --help      帮助
#
# 说明：
#   * 脚本文件由 PS2EXE 的 -embedFiles 在进程启动时释放到 %ProgramData%\PowerSwitch，
#     因此本脚本只负责「配置模板初始化 + 计划任务注册 + 拉起托盘」。
#   * power_config.json 不在嵌入列表中，避免每次运行覆盖用户配置；
#     它缺失时由本脚本从 power_config.default.json 复制一份。
# ============================================================

$ErrorActionPreference = "Stop"

$Root         = Join-Path $env:ProgramData "PowerSwitch"
$TrayScript   = Join-Path $Root "PowerSwitchTray.ps1"
$SwitchScript = Join-Path $Root "SmartPowerSwitch.ps1"
$SetsScript   = Join-Path $Root "PowerSwitchSettings.ps1"
$ConfigFile   = Join-Path $Root "power_config.json"
$DefaultCfg   = Join-Path $Root "power_config.default.json"
$HelpFile     = Join-Path $Root "使用说明.html"
$LogFile      = Join-Path $Root "launcher.log"
$VerFile      = Join-Path $Root "installed.version"

$TaskSwitch = "SmartPowerSwitch"
$TaskTray   = "PowerSwitchTray"

# --reinstall 时强制重写任务定义
$ForceTasks = $false


# ============================================================
#  基础工具
# ============================================================
function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
        Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
    } catch { }
}

function Show-Info {
    param([string]$Text, [string]$Title = "电源模式工具", [string]$Icon = "Information")
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, "OK", $Icon)
    } catch {
        # -noConsole 编译下没有控制台可写，只能落日志
        Write-Log ("MESSAGEBOX FAIL: {0} | text: {1}" -f $_.Exception.Message, ($Text -replace "`r?`n", " / "))
    }
}

function Get-ExePath {
    try { return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    catch { return "" }
}

function Get-AppVersion {
    try {
        $exe = Get-ExePath
        if ($exe -and (Test-Path $exe)) {
            $v = (Get-Item $exe).VersionInfo.FileVersion
            if ($v) { return $v.Trim() }
        }
    } catch { }
    try {
        $asm = [System.Reflection.Assembly]::GetEntryAssembly()
        if ($asm) { return $asm.GetName().Version.ToString() }
    } catch { }
    return "1.0.0.0"
}

function Get-TrayProcesses {
    # 兜底通道。注意：在 PS2EXE 编译出来的宿主里，CimCmdlets 版本可能返回空，
    # 因此这里再挂一条 System.Management 老通道。主判据仍是互斥量与 tray.pid。
    $list = New-Object System.Collections.ArrayList

    try {
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
            if ($p.CommandLine -and $p.CommandLine -like "*PowerSwitchTray.ps1*") {
                [void]$list.Add([PSCustomObject]@{ ProcessId = [int]$p.ProcessId })
            }
        }
    } catch { }

    if ($list.Count -eq 0) {
        try {
            Add-Type -AssemblyName System.Management -ErrorAction SilentlyContinue
            $q = New-Object System.Management.ManagementObjectSearcher(
                     "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'")
            foreach ($mo in $q.Get()) {
                $cl = $mo["CommandLine"]
                if ($cl -and $cl -like "*PowerSwitchTray.ps1*") {
                    [void]$list.Add([PSCustomObject]@{ ProcessId = [int]$mo["ProcessId"] })
                }
            }
        } catch { }
    }
    return @($list)
}

function Get-TrayPid {
    # 读 tray.pid 并校验进程真的还活着——托盘被强杀时不会执行清理，
    # 直接采信陈旧文件会导致「以为在跑、其实没有」而拒绝启动托盘。
    $f = Join-Path $Root "tray.pid"
    if (-not (Test-Path $f)) { return 0 }
    try {
        $v = (Get-Content $f -Raw).Trim()
        $n = 0
        if (-not [int]::TryParse($v, [ref]$n) -or $n -le 0) { return 0 }
        $p = Get-Process -Id $n -ErrorAction SilentlyContinue
        if (-not $p) { Write-Log ("stale tray.pid {0}: process gone, ignoring" -f $n); return 0 }
        if ($p.ProcessName -ne "powershell") { Write-Log ("stale tray.pid {0}: name is {1}, ignoring" -f $n, $p.ProcessName); return 0 }
        return $n
    } catch { }
    return 0
}

function Test-TrayRunning {
    # 托盘脚本用 Global\PowerSwitchTray 互斥量做单实例保护，这里复用同一机制。
    # 用 OpenExisting 探测，不会夺取所有权、也不会受异常残留影响。
    $m = $null
    try { $m = [System.Threading.Mutex]::OpenExisting("Global\PowerSwitchTray") }
    catch { return $false }          # 对象不存在 => 没有实例在跑

    try {
        $acquired = $false
        try { $acquired = $m.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if ($acquired) {
            try { $m.ReleaseMutex() } catch { }
            return $false             # 能立刻拿到 => 只是残留对象，无人持有
        }
        return $true
    } catch {
        return $false
    } finally {
        try { $m.Dispose() } catch { }
    }
}

function Start-Tray {
    if (-not (Test-Path $TrayScript)) {
        Write-Log "ERROR: tray script missing: $TrayScript"
        Show-Info "托盘脚本未找到：`n$TrayScript`n`n可能没有以管理员身份运行，导致文件未能释放。" "启动失败" "Error"
        return $false
    }

    # 首选经由计划任务启动：托盘由此脱离启动器的进程树，
    # 不会被父进程所在 Job Object 连带终止，且天然获得最高权限。
    # ⚠ 任务被「设置窗口 → 开机自动启动」停用后 Start-ScheduledTask 会直接抛
    #   「任务被禁用。」——那是用户的选择，不要偷偷把它启用回来，走直启兜底即可。
    try {
        $t = Get-ScheduledTask -TaskName $TaskTray -ErrorAction SilentlyContinue
        if ($t -and (-not $t.Settings.Enabled)) {
            Write-Log "tray task is disabled (autostart turned off in settings), using direct launch"
        } else {
            Start-ScheduledTask -TaskName $TaskTray -ErrorAction Stop
            Write-Log "tray started via scheduled task"
            return $true
        }
    } catch {
        Write-Log ("scheduled task start failed, falling back to direct launch: {0}" -f $_.Exception.Message)
    }

    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $TrayScript
    Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Write-Log "tray launched (direct)"
    return $true
}

function Stop-Tray {
    # 目标来源：tray.pid（首选）+ 命令行枚举（兜底），并校验进程名，避免误杀复用的 PID
    $targets = New-Object System.Collections.ArrayList
    $p = Get-TrayPid
    if ($p -gt 0) { [void]$targets.Add($p) }
    foreach ($x in (Get-TrayProcesses)) { [void]$targets.Add([int]$x.ProcessId) }

    $uniq = @($targets | Sort-Object -Unique)
    $hit = 0
    foreach ($procId in $uniq) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { Write-Log ("tray pid {0} already gone" -f $procId); continue }
        if ($proc.ProcessName -ne "powershell") {
            Write-Log ("skip pid {0}: not a powershell process ({1})" -f $procId, $proc.ProcessName); continue
        }
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            Write-Log ("tray stopped (pid {0})" -f $procId)
            $hit++
        } catch {
            Write-Log ("tray stop failed (pid {0}): {1}" -f $procId, $_.Exception.Message)
        }
    }
    if ($hit -gt 0) { Start-Sleep -Seconds 3 }
    Remove-Item (Join-Path $Root "tray.pid") -Force -ErrorAction SilentlyContinue
    return $hit
}


# ============================================================
#  配置
# ============================================================
function Initialize-Config {
    if (-not (Test-Path $ConfigFile)) {
        if (Test-Path $DefaultCfg) {
            Copy-Item $DefaultCfg $ConfigFile -Force
            Write-Log "power_config.json created from default template"
        } else {
            Write-Log "WARN: default config template missing, script will fall back to built-in defaults"
        }
    } else {
        Write-Log "power_config.json present, kept as-is"
    }
}


# ============================================================
#  计划任务
# ============================================================
function Get-SwitchTaskXml {
    $script = $SwitchScript.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
    # Interval 无 Duration 即为「无限重复」
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>电源模式自动切换：按负载与时段在节能/平衡/高性能之间切换电源方案（配合 PowerSwitch 托盘工具）</Description>
    <URI>\$TaskSwitch</URI>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$script"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Get-TrayTaskXml {
    $script  = $TrayScript.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>电源模式托盘小工具：随登录启动，图标显示当前电源方案，可手动切换与调整策略</Description>
    <URI>\$TaskTray</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$script"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-Tasks {
    # 幂等：任务已存在且指向正确的脚本时跳过注册。
    # 反复 Register 会替换任务定义、重置运行统计，甚至打断正在运行的实例，
    # 所以「双击 exe」必须做到无副作用。需要强制重写时用 --reinstall。
    $ok = $true
    $force = ($script:ForceTasks -eq $true)

    foreach ($pair in @(@($TaskSwitch, (Get-SwitchTaskXml), $SwitchScript),
                        @($TaskTray,   (Get-TrayTaskXml),   $TrayScript))) {
        $name = $pair[0]; $xml = $pair[1]; $want = $pair[2]

        if (-not $force) {
            $cur = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            $act = $null
            if ($cur) { $act = $cur.Actions | Select-Object -First 1 }
            if ($act -and $act.Arguments -like "*$want*" -and $act.Execute -like "*powershell*") {
                Write-Log ("task up-to-date: {0}" -f $name)
                continue
            }
        }

        try {
            Register-ScheduledTask -TaskName $name -Xml $xml -Force -ErrorAction Stop | Out-Null
            Write-Log ("task registered: {0}" -f $name)
        } catch {
            $ok = $false
            Write-Log ("task register FAILED ({0}): {1}" -f $name, $_.Exception.Message)
        }
    }
    return $ok
}

function Test-TasksPresent {
    $a = Get-ScheduledTask -TaskName $TaskSwitch -ErrorAction SilentlyContinue
    $b = Get-ScheduledTask -TaskName $TaskTray   -ErrorAction SilentlyContinue
    return ($null -ne $a -and $null -ne $b)
}


# ============================================================
#  动作
# ============================================================
function Do-Install {
    Initialize-Config

    $ver = Get-AppVersion
    $old = ""
    if (Test-Path $VerFile) { try { $old = (Get-Content $VerFile -Raw).Trim() } catch { } }

    if (-not (Register-Tasks)) {
        Show-Info "计划任务注册失败。`n`n本程序需要以管理员身份运行才能创建计划任务。`n请右键 → 以管理员身份运行。`n`n详细原因见：`n$LogFile" "安装失败" "Error"
        return
    }
    try { Set-Content -Path $VerFile -Value $ver -Encoding UTF8 } catch { }

    # 探测通道结果全量入日志，方便日后排查
    $byMutex = Test-TrayRunning
    $byPid   = Get-TrayPid
    $byCim   = @(Get-TrayProcesses).Count
    Write-Log ("probe: mutex={0} pidfile={1} cim={2}" -f $byMutex, $byPid, $byCim)

    $running = ($byMutex -or $byPid -gt 0 -or $byCim -gt 0)

    # 版本变化 => 正在跑的托盘仍是旧脚本，重启它以加载新逻辑
    if ($running -and $old -ne $ver) {
        Write-Log ("version changed '{0}' -> '{1}', restarting tray" -f $old, $ver)
        [void](Stop-Tray)
        $running = $false
    }

    if ($running) {
        Write-Log "tray already running, install refreshed"
    } else {
        [void](Start-Tray)
    }
    Write-Log ("install done (version {0})" -f $ver)
}

function Do-OpenSettings {
    if (-not (Test-Path $SetsScript)) {
        Show-Info "找不到设置脚本：`n$SetsScript" "打开失败" "Error"
        return
    }
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }
    Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $SetsScript) | Out-Null
    Write-Log "settings window launched"
}

function Do-Uninstall {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $r = [System.Windows.Forms.MessageBox]::Show(
        "将从本机移除电源模式工具：`n`n  · 删除计划任务「$TaskSwitch」（每分钟自动切换）`n  · 删除计划任务「$TaskTray」（托盘随登录启动）`n  · 停止正在运行的托盘`n`n程序文件与配置会保留在：`n$Root`n`n确定要继续吗？",
        "卸载电源模式工具", "YesNo", "Warning")
    if ($r -ne "Yes") { Write-Log "uninstall cancelled"; return }

    foreach ($n in @($TaskSwitch, $TaskTray)) {
        try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop; Write-Log ("task removed: {0}" -f $n) }
        catch { Write-Log ("task remove skipped ({0}): {1}" -f $n, $_.Exception.Message) }
    }
    $n2 = Stop-Tray
    Remove-Item $VerFile -Force -ErrorAction SilentlyContinue
    Show-Info "已卸载。`n`n程序文件与配置仍保留在：`n$Root`n`n如需彻底清理，手动删除该目录即可。" "卸载完成" "Information"
}

function Do-Status {
    $ver = Get-AppVersion
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("程序版本：$ver")
    [void]$lines.Add("程序目录：$Root")
    [void]$lines.Add("")

    $t1 = Get-ScheduledTask -TaskName $TaskSwitch -ErrorAction SilentlyContinue
    if ($t1) {
        $i1 = Get-ScheduledTaskInfo -TaskName $TaskSwitch
        [void]$lines.Add("自动切换任务：已注册（状态 $($t1.State)）")
        [void]$lines.Add("  上次运行 $($i1.LastRunTime)  返回码 $($i1.LastTaskResult)")
    } else { [void]$lines.Add("自动切换任务：未注册") }

    $t2 = Get-ScheduledTask -TaskName $TaskTray -ErrorAction SilentlyContinue
    if ($t2) { [void]$lines.Add("托盘自启任务：已注册（状态 $($t2.State)）") }
    else { [void]$lines.Add("托盘自启任务：未注册") }

    if (Test-TrayRunning) {
        $pids = New-Object System.Collections.ArrayList
        $p0 = Get-TrayPid
        if ($p0 -gt 0) { [void]$pids.Add($p0) }
        foreach ($x in (Get-TrayProcesses)) { [void]$pids.Add([int]$x.ProcessId) }
        $plist = @($pids | Sort-Object -Unique)
        [void]$lines.Add("托盘进程：运行中" + $(if ($plist.Count -gt 0) { "（pid " + ($plist -join ",") + "）" } else { "" }))
    } else {
        [void]$lines.Add("托盘进程：未运行")
    }

    try {
        $out = (powercfg /getactivescheme) -join ""
        if ($out -match '\((.+?)\)') { [void]$lines.Add("当前电源方案：" + $Matches[1]) }
    } catch { }

    [void]$lines.Add("")
    [void]$lines.Add("自动切换：" + $(if (Test-Path (Join-Path $Root "automation.paused")) { "已暂停" } else { "运行中" }))
    if (Test-Path $ConfigFile) {
        try {
            $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            [void]$lines.Add("全天监控：" + $(if ($c.AllDayMonitor) { "开" } else { "关" }))
            [void]$lines.Add("CPU 阈值：< $($c.CpuThreshold)%　低负载 $($c.LowLoadDuration)min / 高负载 $($c.HighLoadDuration)min")
            if (-not $c.AllDayMonitor) { [void]$lines.Add("夜间时段：$($c.NightStartHour):00 - $($c.NightEndHour):00") }
        } catch { [void]$lines.Add("配置读取失败：" + $_.Exception.Message) }
    }
    Show-Info ($lines -join "`r`n") "电源模式工具 · 状态" "Information"
}

function Show-Help {
    $txt = @"
电源模式工具 PowerSwitch

用法：
  PowerSwitch.exe              安装/更新并启动托盘（重复运行安全）
  PowerSwitch.exe --install    同上
  PowerSwitch.exe --reinstall  强制重写计划任务定义
  PowerSwitch.exe --settings   打开设置窗口
  PowerSwitch.exe --uninstall  卸载（删除计划任务并停止托盘）
  PowerSwitch.exe --status     查看当前状态
  PowerSwitch.exe --help       显示本帮助

提示：
  · 首次运行会创建两个计划任务，并将脚本释放到
    $Root
  · 托盘图标颜色即当前电源方案：
      绿＝节能　蓝＝平衡　橙红＝高性能　灰色带斜杠＝自动切换已暂停
  · 双击托盘图标或右键「设置…」可打开设置窗口
"@
    Show-Info $txt "电源模式工具 · 帮助" "Information"
}


# ============================================================
#  入口
# ============================================================
try {
    if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

    $cmd = ""
    # 用 GetCommandLineArgs 取参，避免依赖 PS2EXE host 对 $args 的处理方式
    $argv = [Environment]::GetCommandLineArgs()
    if ($argv.Count -gt 1) { $cmd = ([string]$argv[1]).TrimStart("-", "/").ToLower() }

    Write-Log ("launcher invoked: cmd='{0}' version={1} admin={2}" -f `
        $cmd, (Get-AppVersion), ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))

    switch ($cmd) {
        "uninstall" { Do-Uninstall }
        "settings"  { Do-OpenSettings }
        "status"    { Do-Status }
        "help"      { Show-Help }
        "install"   { Do-Install }
        "reinstall" { $script:ForceTasks = $true; Do-Install }
        ""          { Do-Install }
        default {
            Write-Log ("unknown command '{0}', falling back to install" -f $cmd)
            Do-Install
        }
    }
    exit 0
} catch {
    Write-Log ("UNHANDLED: " + $_.Exception.ToString())
    Show-Info ("启动器出错：`n`n" + $_.Exception.Message + "`n`n详见日志：`n$LogFile") "电源模式工具" "Error"
    exit 1
}
