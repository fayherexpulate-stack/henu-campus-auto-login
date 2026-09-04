$ErrorActionPreference = 'SilentlyContinue'
$taskName = 'HENU Campus Auto Login'
$installDir = Join-Path $env:LOCALAPPDATA 'HenuAutoLogin'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*HenuAutoLogin*Monitor.ps1*' }
$running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.MessageBox]::Show('已移除校园网自动登录任务和本机配置。', '卸载完成', 'OK', 'Information') | Out-Null
