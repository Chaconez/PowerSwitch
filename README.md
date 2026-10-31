# PowerSwitch

> 按时间与系统负载，自动切换 Windows 电源计划的小工具。纯 PowerShell 5.1 实现，无第三方运行时依赖。

Windows 自带的电源计划切换只有手动入口。PowerSwitch 让它变成自动的：白天保持「平衡」，
夜间持续低负载时降到「节能」，一旦有重负载又立刻升回「平衡」，任务栏托盘图标实时反映当前方案，
随时可以一键接管。

```
   CPU 负载采样（每分钟）
            │
            ▼
   ┌─────────────────┐
   │  当前处于夜间吗？ │
   └────┬───────┬────┘
      是 │       │ 否
        ▼       ▼
  持续低负载？   → DayMode（默认 平衡）
   是 │  否
     ▼    ▼
节能   平衡 / 高性能
```

---

## 特性

- **负载自适应**：按 CPU 使用率判定负载，带防抖动计时（低负载需持续 N 分钟才降档，高负载 N 分钟即升档），避免在阈值附近反复横跳。
- **夜间策略**：可设置夜间时段（默认 23:00–07:00），夜间低负载走节能、有负载走平衡；也可开启「全天监控」忽略时段。
- **托盘常驻**：图标颜色直接表示当前方案 —— 实心绿=节能、实心蓝=平衡、实心红=高性能、空心灰=已暂停。
- **一键接管**：右键菜单可手动切三种模式、暂停/恢复自动切换、立即检查一次、查看日志、打开程序目录。
- **图形化设置**：独立设置窗口修改阈值、时段、模式映射，保存即生效，无需重装或重启任务。
- **纯脚本、可审计**：核心逻辑三个 PowerShell 脚本，全部源码在仓库里，没有隐藏二进制。
- **日志轮转**：主日志超过阈值自动归档为 `.1`，不会无限增长。

## 工作原理

| 组件 | 职责 |
|---|---|
| `SmartPowerSwitch.ps1` | 核心状态机。采样 CPU → 判定负载 → 结合夜间时段与防抖状态 → 调用 `powercfg` 切换方案 |
| `PowerSwitchTray.ps1` | 托盘常驻进程。WinForms `NotifyIcon`，15 秒刷新一次图标，提供右键菜单 |
| `PowerSwitchSettings.ps1` | 设置窗口。读写 `power_config.json` |
| `Launcher.ps1` → `PowerSwitch.exe` | 安装器/启动器。释放嵌入脚本、注册计划任务、拉起托盘 |

两个计划任务驱动一切：

- **`SmartPowerSwitch`** — 每分钟触发一次，跑一次状态机（以 SYSTEM 身份运行，保证有权限改电源方案）。
- **`PowerSwitchTray`** — 登录时触发，拉起托盘进程（以交互式用户身份运行，才能显示托盘图标）。

防抖动状态通过 `power_switch_state.json` 跨次运行累计，因此每次执行都是独立的短进程，不需要常驻守护。

## 快速开始

需要 Windows 10/11 或 Windows Server 2016+，PowerShell 5.1（系统自带）。

1. 以**管理员身份**运行 `PowerSwitch.exe`。
2. 程序会释放脚本到 `C:\ProgramData\PowerSwitch\`、注册两个计划任务、并拉起托盘图标。
3. 任务栏出现彩色圆点图标即安装完成。右键 → **设置…** 可调整策略。

安装是幂等的，重复运行只会刷新文件与任务，不会重置你的配置。

## 命令行参数

| 参数 | 行为 |
|---|---|
| *(无)* / `--install` | 安装或更新，并启动托盘 |
| `--reinstall` | 强制重写计划任务定义 |
| `--settings` | 直接打开设置窗口 |
| `--status` | 打印当前状态 |
| `--uninstall` | 删除计划任务并停止托盘（保留程序文件与配置） |
| `--help` | 显示帮助 |

## 配置说明

配置文件位于 `C:\ProgramData\PowerSwitch\power_config.json`，缺失或某项非法时回落到内置默认值。

| 字段 | 默认值 | 说明 |
|---|---|---|
| `NightStartHour` | `23` | 夜间开始（24 小时制） |
| `NightEndHour` | `7` | 夜间结束，支持跨零点 |
| `AllDayMonitor` | `false` | `true` = 忽略夜间时段，全天按负载切换 |
| `CpuThreshold` | `20` | CPU 使用率阈值（%），低于此值视为低负载 |
| `LowLoadDuration` | `5` | 连续低负载满 N 分钟才降档 |
| `HighLoadDuration` | `1` | 连续高负载满 N 分钟即升档 |
| `SampleCount` | `2` | 每次检测的采样次数 |
| `SampleIntervalSec` | `1` | 采样间隔（秒） |
| `MaxLogSizeMB` | `5` | 主日志超过该大小即轮转 |
| `TrayRefreshSec` | `15` | 托盘图标刷新间隔 |
| `DayMode` | `Balanced` | 白天使用的方案 |
| `NightLowLoadMode` | `PowerSaver` | 夜间低负载使用的方案 |
| `NightHighLoadMode` | `Balanced` | 夜间高负载使用的方案 |

方案取值：`PowerSaver`（节能）、`Balanced`（平衡）、`HighPerformance`（高性能）、`UltimatePerformance`（卓越性能，需系统支持）。

对应 Windows 标准方案 GUID：

| 方案 | GUID |
|---|---|
| 节能 | `a1841308-3541-4fab-bc81-f71556f20b4a` |
| 平衡 | `381b4222-f694-41f0-9685-ff5bb260df2e` |
| 高性能 | `8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c` |
| 卓越性能 | `e9a42b02-d5df-448d-aa00-03f14749eb61` |

## 目录结构

```
PowerSwitch/
├── build/
│   ├── Launcher.ps1            # 安装器/启动器源码（编译为 PowerSwitch.exe）
│   ├── _build.ps1              # 打包脚本（ps2exe）
│   └── PowerSwitch.ico         # 可执行文件图标
├── src/
│   ├── SmartPowerSwitch.ps1    # 核心：负载采样 + 方案切换状态机
│   ├── PowerSwitchTray.ps1     # 托盘常驻进程
│   ├── PowerSwitchSettings.ps1 # 图形化设置窗口
│   ├── help.html               # 内置使用说明
│   ├── power_config.default.json
│   └── icons/                  # 托盘多分辨率图标
└── tools/
    ├── make_icons.py           # 图标生成脚本
    └── test_ico.ps1            # 图标校验
```

运行时文件（不纳入版本管理）：`power_switch.log`、`tray.log`、`power_switch_state.json`、
`tray.pid`、`automation.paused`、`power_config.json`、`installed.version`。

## 从源码构建

```powershell
# 1. 安装打包模块
Install-Module ps2exe -Scope CurrentUser

# 2. 在 build/ 目录下执行，产物为 build/PowerSwitch.exe
.\build\_build.ps1
```

`_build.ps1` 以脚本所在目录为构建根，通过 `-embedFiles` 把 `src\` 下的脚本与图标嵌进 exe，
程序运行时自动释放到 `%ProgramData%\PowerSwitch\`。构建结果写入 `_build_result.txt`。

## 常见问题

**托盘图标不见了，但电源还在自动切换。**
说明托盘进程挂了、核心状态机还活着（两者独立）。检查 `C:\ProgramData\PowerSwitch\tray.log` 与
`power_switch.log` 的最后几行；双击 `PowerSwitch.exe` 可立即重新拉起托盘。

**托盘进程退出码 `3221225786`（`0xC000013A`）。**
这是 `STATUS_CONTROL_C_EXIT`，含义是进程的控制台收到 CTRL+C / 控制台关闭事件后被**强制结束**，
不是崩溃、不是内存不足、也不是正常退出。典型诱因是某个脚本执行了不带 `/F` 的
`taskkill /IM powershell.exe`，或者它的隐藏控制台被关闭。判据：托盘脚本末尾的 `finally`
会写一行 `tray stopped`，如果日志里没有这行，就是被硬杀。

**改了策略不生效？**
`SmartPowerSwitch` 每次运行都会重新读取 `power_config.json`，保存后下一分钟即生效，不需要重装。
若菜单里显示"已暂停"，检查 `automation.paused` 文件是否存在。

**双击 exe 没有任何反应？**
先看 `launcher.log` 最后几行。1.0.2.0 及更早版本存在一个静默失败缺陷：`Start-ScheduledTask`
在"任务被拒绝执行"时不会抛异常，失败只体现在任务的 `LastTaskResult` 里，启动器却直接记下
`tray started via scheduled task` 并返回成功，导致兜底逻辑永不执行，而 `-noConsole` 编译又没有
窗口可以报错 —— 表现就是双击后毫无反应。1.0.3.0 起启动器会实测托盘是否真的起来，失败则依次
降级到 WMI 分离启动、普通直启，全部失败时弹出提示框。

**托盘起来了但几秒后又消失？**
说明它是被父进程的 Job Object 连带终止的。用 `Start-Process` 拉起的托盘是启动器的子进程，
启动器退出时如果所在 Job 设置了 kill-on-close，子进程会被一起杀掉，且日志里不会留下
`tray stopped`。1.0.3.0 起优先通过 WMI `Win32_Process.Create` 创建托盘进程，其父进程变为
`WmiPrvSE.exe`，已脱离原进程树，因此不受影响。

**为什么两个任务身份不同？**
`SmartPowerSwitch` 用 SYSTEM，因为 `powercfg /setactive` 需要管理员权限且不需要交互桌面；
`PowerSwitchTray` 用交互式用户，因为托盘图标必须画在用户会话里。部分环境（如远程会话）下
交互式计划任务无法启动（报 `0x800710E0 操作员或系统管理员拒绝了请求`），此时启动器会自动
降级为分离直启；若希望登录时也不依赖计划任务，可在启动文件夹放置一个隐藏窗口的启动脚本兜底。

## 卸载

```powershell
PowerSwitch.exe --uninstall
```

删除两个计划任务并停止托盘进程，`C:\ProgramData\PowerSwitch\` 下的程序文件与配置会保留，
需要彻底清除时手动删除该目录即可。

## 更新记录

**1.0.3.0**
- 修复：启动器把 `Start-ScheduledTask` 的"假成功"当成真成功，导致托盘启动失败被静默吞掉、
  兜底逻辑永不执行（表现为双击 exe 毫无反应）。现在启动后会实测互斥量/进程，确认托盘真的起来。
- 修复：直启的托盘作为启动器子进程，会被父进程 Job Object 的 kill-on-close 连带终止。
  改用 WMI `Win32_Process.Create` 分离启动，托盘父进程变为 `WmiPrvSE.exe`，不再受牵连。
- 改进：两条启动路径都失败时弹出提示框并写日志，不再静默退出。
- 改进：`_build.ps1` 去掉硬编码绝对路径，自动兼容 `src` 与 `build` 同级或嵌套两种布局。

**1.0.2.0**
- 托盘单实例改用全局互斥量 + `tray.pid` 双判据，修复陈旧 pid 文件导致的"以为在跑"。
- 设置窗口支持多开防护。

## 兼容性

- Windows 10 / 11，Windows Server 2016 及以上
- Windows PowerShell 5.1（不使用 PowerShell 7 特性）
- 无需 .NET SDK、无需 Python（`tools/make_icons.py` 仅在重新生成图标时需要）
