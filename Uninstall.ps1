$ErrorActionPreference='Stop'
$taskName='HENU Campus Auto Login'
$installDir=Join-Path $env:LOCALAPPDATA 'HenuAutoLogin'
$failures=New-Object 'Collections.Generic.List[string]'
function Try-Step([string]$Name,[scriptblock]$Action){try{& $Action}catch{[void]$failures.Add($Name+'：'+$_.Exception.Message)}}
Try-Step '删除开机任务' {
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task){Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw '任务仍然存在。'}
}
Try-Step '关闭校园网助手进程' {
    $scriptNames=@('Monitor.ps1','HenuAutoLogin.ps1','BrowserLogin.ps1')|ForEach-Object{Join-Path $installDir $_}
    $targets=Get-CimInstance Win32_Process|Where-Object{$command=[string]$_.CommandLine;$command -and @($scriptNames|Where-Object{$command.Contains($_)}).Count -gt 0}
    foreach($target in $targets){& taskkill.exe /PID $target.ProcessId /T /F 2>$null|Out-Null;if($LASTEXITCODE -ne 0 -and (Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue)){throw ('无法终止进程 '+$target.ProcessId)}}
}
Try-Step '关闭认证专用 Edge' {
    $profiles=@((Join-Path $installDir 'EdgeProfile'),(Join-Path $installDir 'EdgeSelfTest'))
    $edges=Get-CimInstance Win32_Process -Filter "Name='msedge.exe'"|Where-Object{$command=[string]$_.CommandLine;$command -and @($profiles|Where-Object{$command.Contains($_)}).Count -gt 0}
    foreach($edge in $edges){& taskkill.exe /PID $edge.ProcessId /T /F 2>$null|Out-Null;if($LASTEXITCODE -ne 0 -and (Get-Process -Id $edge.ProcessId -ErrorAction SilentlyContinue)){throw ('无法终止 Edge '+$edge.ProcessId)}}
}
Try-Step '删除本机配置和日志' {if(Test-Path -LiteralPath $installDir){Remove-Item -LiteralPath $installDir -Recurse -Force;if(Test-Path -LiteralPath $installDir){throw '安装目录仍然存在。'}}}
Add-Type -AssemblyName System.Windows.Forms
if($failures.Count -eq 0){[Windows.Forms.MessageBox]::Show('已移除开机任务、助手进程、专用 Edge 资料和本机账号配置。Windows 中的 henu-student Wi-Fi 配置会保留，并保持手动连接模式。','卸载完成','OK','Information')|Out-Null;exit 0}
$message="卸载未完全完成：`r`n`r`n- "+($failures -join "`r`n- ")+"`r`n`r`n为避免误删，henu-student Wi-Fi 配置没有移除。"
[Windows.Forms.MessageBox]::Show($message,'卸载需要处理','OK','Warning')|Out-Null
exit 1
