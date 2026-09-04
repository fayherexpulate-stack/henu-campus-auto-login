param([switch]$SkipPrompt,[switch]$StartMinimized)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$created=$false
$mutex=New-Object Threading.Mutex($true,'Local\HenuAutoLoginMonitor',[ref]$created)
if (-not $created) { exit 0 }
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    Write-Log '守护程序 2.2 已启动：多站点检测、连续失败确认、认证冷却。'
    if (-not $SkipPrompt) {
        $answer=[Windows.Forms.MessageBox]::Show('今天在学校吗？选“是”后显示状态，自动连接校园网并操作登录网页。','河南大学校园网助手','YesNo','Question')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { Write-Log '用户选择本次不开启守护。'; exit 0 }
    }
    Write-Log '已确认在校，开始守护。'
    $script:quitting=$false; $script:worker=$null; $script:nextCheck=[DateTime]::MinValue
    $script:checkNow=$false; $script:lastHeartbeat=[DateTime]::MinValue
    $script:failures=0; $script:firstFailure=[DateTime]::MinValue
    $script:cooldownUntil=[DateTime]::MinValue; $script:attempts=0
    $script:workerMode='probe'; $script:recoverNext=$false
    $form=New-Object Windows.Forms.Form
    $form.Text='河南大学校园网助手 · 2.2'
    $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(480,220)
    $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
    $label=New-Object Windows.Forms.Label
    $label.Text='正在检查网络…'; $label.Font=New-Object Drawing.Font('Microsoft YaHei UI',11)
    $label.Location=New-Object Drawing.Point(25,25); $label.Size=New-Object Drawing.Size(430,105)
    $form.Controls.Add($label)
    $retry=New-Object Windows.Forms.Button
    $retry.Text='立即检查并恢复'; $retry.Location=New-Object Drawing.Point(25,155); $retry.Size=New-Object Drawing.Size(155,38)
    $form.Controls.Add($retry)
    $hide=New-Object Windows.Forms.Button
    $hide.Text='隐藏到托盘'; $hide.Location=New-Object Drawing.Point(200,155); $hide.Size=New-Object Drawing.Size(125,38)
    $form.Controls.Add($hide)
    $exitButton=New-Object Windows.Forms.Button
    $exitButton.Text='退出'; $exitButton.Location=New-Object Drawing.Point(345,155); $exitButton.Size=New-Object Drawing.Size(100,38)
    $form.Controls.Add($exitButton)
    $tray=New-Object Windows.Forms.NotifyIcon
    $tray.Icon=[Drawing.SystemIcons]::Information; $tray.Text='校园网助手：检测中'; $tray.Visible=$true
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $showItem=$menu.Items.Add('显示状态'); $retryItem=$menu.Items.Add('立即检查并恢复'); $exitItem=$menu.Items.Add('退出本次守护')
    $tray.ContextMenuStrip=$menu
    $showItem.Add_Click({$form.Show();$form.Activate()})
    $tray.Add_DoubleClick({$form.Show();$form.Activate()})
    $retry.Add_Click({$script:checkNow=$true;$script:nextCheck=[DateTime]::MinValue})
    $retryItem.Add_Click({$script:checkNow=$true;$script:nextCheck=[DateTime]::MinValue;$form.Show()})
    $hide.Add_Click({$form.Hide()})
    $exitButton.Add_Click({$script:quitting=$true;$form.Close()})
    $exitItem.Add_Click({$script:quitting=$true;$form.Close()})
    $form.Add_FormClosing({param($sender,$e) if(-not $script:quitting){$e.Cancel=$true;$form.Hide()}})
    if ($StartMinimized) { $form.Add_Shown({$form.Hide()}) }
    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=300
    $timer.Add_Tick({
        try {
            $now=Get-Date
            if (($now-$script:lastHeartbeat).TotalSeconds -ge 10) {
                @{pid=$PID;time=$now.ToString('o');version='2.2';state='running';failures=$script:failures;mode=$script:workerMode;cooldownUntil=$script:cooldownUntil.ToString('o')}|ConvertTo-Json -Compress|Set-Content (Join-Path $appDir 'monitor-status.json') -Encoding UTF8
                $script:lastHeartbeat=$now
            }
            $statusPath=Join-Path $appDir 'status.json'
            if (Test-Path $statusPath) {
                try {
                    $state=Get-Content $statusPath -Raw -Encoding UTF8|ConvertFrom-Json
                    $label.Text=[string]$state.message
                    $tray.Text='校园网助手：'+[string]$state.phase
                } catch {}
            }
            if ($script:worker) {
                $script:worker.Refresh()
                if ($script:worker.HasExited) {
                    $script:worker.WaitForExit()
                    $code=$script:worker.ExitCode
                    $script:worker.Dispose();$script:worker=$null
                    if ($code -eq 0) {
                        $script:failures=0; $script:firstFailure=[DateTime]::MinValue
                        # Retain the last authentication cooldown across a brief online period.
                        # Otherwise intermittent connectivity could open a new login every minute.
                        if ($now -ge $script:cooldownUntil) { $script:attempts=0 }
                        $script:recoverNext=$false
                        Write-State 'online' '互联网可用，安静守护中，不重复登录。'
                        $script:nextCheck=$now.AddSeconds(10)
                    } elseif ($script:workerMode -eq 'probe' -and $code -eq 10) {
                        $decision=Get-ConnectivityDecision $false $script:failures $script:firstFailure $now $script:cooldownUntil
                        $script:failures=$decision.Failures; $script:firstFailure=$decision.FirstFailure
                        $script:recoverNext=$decision.Recover
                        if ($now -lt $script:cooldownUntil) {
                            Write-State 'cooldown' '暂未恢复互联网，正在后台检查；稍后再尝试认证，避免重复弹窗。'
                        } else {
                            Write-State 'checking' ('所有联网验证暂未通过，正在确认（第 '+$script:failures+' 轮）…')
                        }
                        $script:nextCheck=if($script:recoverNext){$now}else{$now.AddSeconds(5)}
                    } elseif ($script:workerMode -eq 'recover') {
                        Write-Log ('本轮恢复未成功（退出码 '+$code+'），进入冷却，继续后台检测。')
                        Write-State 'cooldown' '本轮恢复未成功，稍后再试。可在日志或认证页面查看原因。'
                        $script:failures=0; $script:firstFailure=[DateTime]::MinValue
                        $script:nextCheck=$now.AddSeconds(10)
                    } else {
                        # A broken checker is not evidence of an offline network.
                        Write-Log ('联网检查程序异常（退出码 '+$code+'），不自动打开认证页。')
                        Write-State 'error' '联网检查异常，稍后重试；不会据此重复认证。'
                        $script:failures=0; $script:firstFailure=[DateTime]::MinValue
                        $script:nextCheck=$now.AddSeconds(30)
                    }
                    $retry.Enabled=$true
                } elseif (($now-$script:worker.StartTime).TotalSeconds -gt $(if($script:workerMode -eq 'probe'){20}else{150})) {
                    # Stop only the worker tree created by this monitor.
                    & taskkill.exe /PID $script:worker.Id /T /F 2>$null | Out-Null
                    Write-State 'error' '检查或认证等待超时，稍后重试。'
                    Write-Log '守护程序终止了超时的认证子任务。'
                }
            }
            if (-not $script:worker -and ($now -ge $script:nextCheck -or $script:checkNow)) {
                $args=@('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $PSScriptRoot 'HenuAutoLogin.ps1')+'"'),'-Quiet')
                $script:checkNow=$false
                if ($script:recoverNext) {
                    $args+='-RecoveryConfirmed'; $script:workerMode='recover'; $script:recoverNext=$false
                    $script:attempts++
                    $script:cooldownUntil=$now.AddSeconds((Get-RecoveryDelay $script:attempts))
                    Write-Log ('多站点连续失败已确认，尝试恢复；下一次认证至少间隔 '+(Get-RecoveryDelay $script:attempts)+' 秒。')
                } else { $args+='-ProbeOnly'; $script:workerMode='probe' }
                $script:worker=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
                $retry.Enabled=$false
            }
        } catch {
            Write-Log ('守护检查错误：'+$_.Exception.Message)
            $label.Text='检查出错，请查看日志或点击重试。'
            $script:nextCheck=(Get-Date).AddSeconds(30)
        }
    })
    $timer.Start()
    [Windows.Forms.Application]::Run($form)
} catch {
    Write-Log ('守护启动失败：'+$_.Exception.Message)
    exit 1
} finally {
    if($timer){$timer.Stop();$timer.Dispose()}
    if($tray){$tray.Visible=$false;$tray.Dispose()}
    if($script:worker -and -not $script:worker.HasExited){& taskkill.exe /PID $script:worker.Id /T /F 2>$null|Out-Null}
    Write-Log '守护程序已退出。'
    try{$mutex.ReleaseMutex()}catch{}
    $mutex.Dispose()
}
