' PowerSwitch - 登录自启兜底脚本（可选）
'
' 适用场景：某些环境下以「交互式用户」身份的计划任务无法启动
' （任务结果 0x800710E0 操作员或系统管理员拒绝了请求），
' 此时托盘不会随登录自动出现。把本文件放到启动文件夹即可绕开计划任务：
'
'   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
'
' 用 wscript 运行，窗口完全隐藏，不会闪控制台。
' 托盘脚本自身有全局互斥量做单实例保护，与计划任务同时生效也不会出现两个图标。

Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\PowerSwitch\PowerSwitchTray.ps1""", 0, False
