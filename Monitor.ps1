param([switch]$SkipPrompt,[switch]$StartMinimized,[switch]$OpenPanel)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'PanelServer.ps1')
$panelInfoPath=Join-Path $appDir 'panel.json'
$created=$false
$mutex=New-Object Threading.Mutex($true,'Local\HenuAutoLoginMonitor',[ref]$created)
if (-not $created) {
    # Another monitor already owns the tray. When asked, open its web panel instead of starting a second copy.
    if ($OpenPanel) {
        $deadline=(Get-Date).AddSeconds(20)
        do {
            try {
                $info=Get-Content -LiteralPath $panelInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
                if ([int]$info.port -gt 0 -and [string]$info.token -match '^[0-9a-f]{64}$' -and (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)) {
                    Start-Process ('http://127.0.0.1:{0}/#t={1}' -f [int]$info.port,[string]$info.token)
                    break
                }
            } catch {}
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
    }
    $mutex.Dispose()
    exit 0
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    . (Join-Path $PSScriptRoot 'TrayIcon.ps1')
    Write-Log ('守护程序 '+$henuVersion+' 已启动：托盘状态面板、本机网页控制台、正常关机退出与原子状态写入。')
    if (-not $SkipPrompt) {
        $answer=[Windows.Forms.MessageBox]::Show('今天在学校吗？选“是”后显示状态，自动连接校园网并操作登录网页。','河南大学校园网助手','YesNo','Question')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { Write-Log '用户选择本次不开启守护。'; exit 0 }
    }
    Write-Log '已确认在校，开始守护。'
    Write-State 'checking' '守护已启动，正在检查网络…'
    $script:quitting=$false; $script:worker=$null; $script:nextCheck=[DateTime]::MinValue
    $script:checkNow=$false; $script:lastHeartbeat=[DateTime]::MinValue
    $script:failures=0; $script:firstFailure=[DateTime]::MinValue
    $script:cooldownUntil=[DateTime]::MinValue; $script:attempts=0
    $script:workerMode='probe'; $script:recoverNext=$false
    $script:loginRequested=$false; $script:manualRecovery=$false
    $script:lastCheck=[DateTime]::MinValue; $script:lastError=$null
    $script:lastPhase=''; $script:currentLevel=''; $script:lastErrorNotice=[DateTime]::MinValue
    $script:flyoutHiddenAt=[DateTime]::MinValue
    $script:probeWorker=New-InternetProbeWorker (Join-Path $PSScriptRoot 'Common.ps1')
    $script:lastStatusRead=[DateTime]::MinValue
    $script:levelColor=Get-HenuLevelColor 'idle'
    $script:icons=@{}
    foreach ($level in @('ok','busy','warn','error','idle')) { $script:icons[$level]=New-HenuStatusIcon $level }

    # ---------- bottom-right flyout (the "status bar" window) ----------
    $ink=[Drawing.Color]::FromArgb(31,26,23); $muted=[Drawing.Color]::FromArgb(111,102,96); $line=[Drawing.Color]::FromArgb(214,207,200)
    $form=New-Object Windows.Forms.Form
    $form.Text='河南大学校园网助手'
    $form.FormBorderStyle='None'; $form.ShowInTaskbar=$false; $form.TopMost=$true
    $form.StartPosition='Manual'; $form.ClientSize=New-Object Drawing.Size(340,224)
    $form.BackColor=[Drawing.Color]::White
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $form.Add_Paint({
        param($sender,$e)
        $pen=New-Object Drawing.Pen($line)
        try { $e.Graphics.DrawRectangle($pen,0,0,$form.ClientSize.Width-1,$form.ClientSize.Height-1) } finally { $pen.Dispose() }
    })
    $dot=New-Object Windows.Forms.PictureBox
    $dot.Location=New-Object Drawing.Point(20,23); $dot.Size=New-Object Drawing.Size(14,14)
    $dot.Add_Paint({
        param($sender,$e)
        $e.Graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $brush=New-Object Drawing.SolidBrush($script:levelColor)
        try { $e.Graphics.FillEllipse($brush,1,1,11,11) } finally { $brush.Dispose() }
    })
    $form.Controls.Add($dot)
    $titleLabel=New-Object Windows.Forms.Label
    $titleLabel.Text='检测中'; $titleLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',13,[Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor=$ink; $titleLabel.Location=New-Object Drawing.Point(40,14); $titleLabel.Size=New-Object Drawing.Size(190,30)
    $form.Controls.Add($titleLabel)
    $appLabel=New-Object Windows.Forms.Label
    $appLabel.Text='校园网助手 '+$henuVersion; $appLabel.ForeColor=$muted; $appLabel.TextAlign='TopRight'
    $appLabel.Location=New-Object Drawing.Point(220,21); $appLabel.Size=New-Object Drawing.Size(100,18)
    $form.Controls.Add($appLabel)
    $messageLabel=New-Object Windows.Forms.Label
    $messageLabel.Text='正在检查网络…'; $messageLabel.ForeColor=$ink
    $messageLabel.Location=New-Object Drawing.Point(20,52); $messageLabel.Size=New-Object Drawing.Size(300,40)
    $form.Controls.Add($messageLabel)
    $detailLabel=New-Object Windows.Forms.Label
    $detailLabel.ForeColor=$muted; $detailLabel.Location=New-Object Drawing.Point(20,96); $detailLabel.Size=New-Object Drawing.Size(300,20)
    $form.Controls.Add($detailLabel)
    $errorLabel=New-Object Windows.Forms.Label
    $errorLabel.ForeColor=[Drawing.Color]::FromArgb(200,30,30); $errorLabel.Visible=$false
    $errorLabel.Location=New-Object Drawing.Point(20,118); $errorLabel.Size=New-Object Drawing.Size(300,36)
    $form.Controls.Add($errorLabel)
    $separator=New-Object Windows.Forms.Label
    $separator.BackColor=[Drawing.Color]::FromArgb(236,231,226); $separator.Location=New-Object Drawing.Point(1,162); $separator.Size=New-Object Drawing.Size(338,1)
    $form.Controls.Add($separator)
    function New-FlyoutButton([string]$Text,[int]$X,[int]$Width,[bool]$Primary) {
        $button=New-Object Windows.Forms.Button
        $button.Text=$Text; $button.Location=New-Object Drawing.Point($X,176); $button.Size=New-Object Drawing.Size($Width,34)
        $button.FlatStyle='Flat'; $button.UseVisualStyleBackColor=$false; $button.Cursor=[Windows.Forms.Cursors]::Hand
        if ($Primary) {
            $button.BackColor=Get-HenuLevelColor 'brand'; $button.ForeColor=[Drawing.Color]::White; $button.FlatAppearance.BorderSize=0
        } else {
            $button.BackColor=[Drawing.Color]::White; $button.ForeColor=$ink; $button.FlatAppearance.BorderColor=$line
        }
        $form.Controls.Add($button)
        return $button
    }
    $loginButton=New-FlyoutButton '立即登录' 20 96 $true
    $panelButton=New-FlyoutButton '网页控制台' 124 104 $false
    $logButton=New-FlyoutButton '查看日志' 236 84 $false

    $tray=New-Object Windows.Forms.NotifyIcon
    $tray.Icon=$script:icons['idle']; $tray.Text='校园网助手 · 检测中'; $tray.Visible=$true
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $showItem=$menu.Items.Add('显示状态面板')
    $panelItem=$menu.Items.Add('打开网页控制台（填写账号密码）')
    $loginItem=$menu.Items.Add('立即登录')
    $checkItem=$menu.Items.Add('立即检查网络')
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $logItem=$menu.Items.Add('查看日志')
    $exitItem=$menu.Items.Add('退出本次守护')
    $tray.ContextMenuStrip=$menu

    function Show-Flyout {
        $area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
        $form.Location=New-Object Drawing.Point(($area.Right-$form.Width-12),($area.Bottom-$form.Height-12))
        $form.Opacity=1
        Update-StatusUi
        $form.Show(); $form.Activate()
    }
    function Open-Panel {
        if (-not $script:panel) {
            [Windows.Forms.MessageBox]::Show('网页控制台没有启动成功，请查看日志；也可以重新运行安装程序修改账号。','河南大学校园网助手','OK','Warning')|Out-Null
            return
        }
        Start-Process (Get-PanelUrl $script:panel)
    }
    function Open-Log {
        if (Test-Path -LiteralPath $logPath) { Start-Process -FilePath (Join-Path $env:SystemRoot 'notepad.exe') -ArgumentList ('"'+$logPath+'"') }
    }
    function Show-TrayNotice([string]$Title,[string]$Text,[string]$Kind) {
        if ($form.Visible -or [string]::IsNullOrWhiteSpace($Text)) { return }
        if ($Text.Length -gt 180) { $Text=$Text.Substring(0,180)+'…' }
        $tray.ShowBalloonTip(5000,$Title,$Text,[Windows.Forms.ToolTipIcon]$Kind)
    }
    function Request-Login {
        if (-not (Get-HenuConfigSummary).configured) {
            return [ordered]@{accepted=$false;reason='not-configured';message='请先在网页控制台填写账号和密码。'}
        }
        if ($script:worker -or $script:loginRequested) {
            return [ordered]@{accepted=$false;reason='busy';message='正在处理上一次登录，请稍候。'}
        }
        $script:loginRequested=$true; $script:nextCheck=[DateTime]::MinValue
        # A concurrent reader can briefly block the atomic replace; the queued request must still stand.
        try { Write-State 'queued' '已收到登录请求：先确认网络，确实需要认证时再打开登录页。' } catch {}
        Write-Log '用户请求立即登录（仍会先检查互联网，已联网则不重复认证）。'
        return [ordered]@{accepted=$true;message='已开始：先检查网络，需要认证时会弹出专用 Edge 窗口自动填写并登录。'}
    }
    function Update-StatusUi {
        $state=Read-HenuStatus
        $phase=if($state){[string]$state.phase}else{''}
        $message=if($state -and $state.message){[string]$state.message}else{'正在检查网络…'}
        $info=Get-HenuPhaseInfo $phase
        if ($script:currentLevel -ne $info.level) {
            $script:currentLevel=$info.level
            $tray.Icon=$script:icons[$info.level]
            $script:levelColor=Get-HenuLevelColor $info.level
            $dot.Invalidate()
        }
        $tip='校园网助手 · '+$info.title
        if ($tip.Length -gt 63) { $tip=$tip.Substring(0,63) }
        $tray.Text=$tip
        $titleLabel.Text=$info.title
        $messageLabel.Text=$message
        $summary=Get-HenuConfigSummary
        $parts=@()
        if ($summary.username) { $parts+=('账号 '+$summary.username+' · '+(Get-HenuOperatorName $summary.operator)) } else { $parts+='尚未设置账号' }
        if ($script:lastCheck -gt [DateTime]::MinValue) { $parts+=('上次检测 '+$script:lastCheck.ToString('HH:mm:ss')) }
        $detailLabel.Text=($parts -join '　')
        if ($script:lastError -and $info.level -ne 'ok') {
            $errorLabel.Text='上次失败：'+[string]$script:lastError.message; $errorLabel.Visible=$true
        } else { $errorLabel.Visible=$false }
        $busy=[bool]($script:worker -or $script:loginRequested)
        $loginButton.Enabled=-not $busy
        $loginButton.Text=if(-not $summary.configured){'设置账号'}elseif($busy){'登录中…'}else{'立即登录'}
        $loginItem.Enabled=-not $busy
        if ($phase -ne $script:lastPhase) {
            $loginPhases=@('queued','connecting','opening','waiting','filling','submitted')
            if ($phase -eq 'online' -and $loginPhases -contains $script:lastPhase) { Show-TrayNotice '校园网已连接' $message 'Info' }
            $script:lastPhase=$phase
        }
    }
    function Invoke-LoginAction {
        $result=Request-Login
        if ($result.reason -eq 'not-configured') { Open-Panel; return }
        $script:lastStatusRead=[DateTime]::MinValue
    }

    $tray.Add_MouseClick({
        param($sender,$e)
        if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        if ($form.Visible) { $form.Hide() }
        elseif (((Get-Date)-$script:flyoutHiddenAt).TotalMilliseconds -gt 300) { Show-Flyout }
    })
    $tray.Add_BalloonTipClicked({ Show-Flyout })
    $form.Add_Deactivate({ $form.Hide(); $script:flyoutHiddenAt=Get-Date })
    $showItem.Add_Click({ Show-Flyout })
    $panelItem.Add_Click({ Open-Panel })
    $loginItem.Add_Click({ Invoke-LoginAction })
    $checkItem.Add_Click({ $script:checkNow=$true; $script:nextCheck=[DateTime]::MinValue })
    $logItem.Add_Click({ Open-Log })
    $loginButton.Add_Click({ Invoke-LoginAction })
    $panelButton.Add_Click({ $form.Hide(); Open-Panel })
    $logButton.Add_Click({ $form.Hide(); Open-Log })
    $exitItem.Add_Click({ $script:quitting=$true; $form.Close() })
    $form.Add_FormClosing({
        param($sender,$e)
        if(-not $script:quitting -and $e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing){
            $e.Cancel=$true;$form.Hide()
        } else {
            $script:quitting=$true
        }
    })

    # ---------- local web panel (127.0.0.1 only) ----------
    $script:panel=$null
    $script:panelHandlers=@{
        Page={ $script:panelPage }
        Status={
            $state=Read-HenuStatus
            $phase=if($state){[string]$state.phase}else{''}
            $info=Get-HenuPhaseInfo $phase
            [ordered]@{
                version=$henuVersion; phase=$phase; level=$info.level; title=$info.title
                message=if($state -and $state.message){[string]$state.message}else{'正在检查网络…'}
                time=if($state){[string]$state.time}else{''}
                busy=[bool]($script:worker -or $script:loginRequested)
                lastCheck=if($script:lastCheck -gt [DateTime]::MinValue){$script:lastCheck.ToString('o')}else{''}
                lastError=$script:lastError
                config=(Get-HenuConfigSummary)
            }
        }
        SaveConfig={
            param($username,$password,$operator)
            $summary=Save-HenuConfig -Username $username -Password $password -Operator $operator
            Write-Log ('已通过网页控制台更新账号设置（运营商='+$operator+'）。')
            $script:lastError=$null; $script:lastStatusRead=[DateTime]::MinValue
            $summary
        }
        Login={ $script:lastStatusRead=[DateTime]::MinValue; Request-Login }
        Check={ $script:checkNow=$true; $script:nextCheck=[DateTime]::MinValue; [ordered]@{ok=$true} }
    }
    try {
        $script:panelPage=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Panel.html'),[Text.Encoding]::UTF8)
        $script:panel=Start-PanelServer
        Set-AtomicJson $panelInfoPath ([ordered]@{pid=$PID;port=$script:panel.Port;token=$script:panel.Token;version=$henuVersion})
        Write-Log ('网页控制台已在 127.0.0.1:'+$script:panel.Port+' 启动（仅限本机访问）。')
    } catch {
        Write-Log ('网页控制台启动失败：'+$_.Exception.Message)
        Stop-PanelServer $script:panel; $script:panel=$null
    }
    $panelTimer=New-Object Windows.Forms.Timer
    $panelTimer.Interval=100
    $panelTimer.Add_Tick({
        try { Invoke-PanelPump $script:panel $script:panelHandlers }
        catch { Write-Log ('网页控制台请求处理错误：'+$_.Exception.Message) }
    })

    $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location=New-Object Drawing.Point(($area.Right-$form.Width-12),($area.Bottom-$form.Height-12))
    if ($StartMinimized) { $form.Opacity=0; $form.Add_Shown({$form.Hide()}) }
    Update-StatusUi
    if ($OpenPanel) { Open-Panel }

    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=300
    $timer.Add_Tick({
        try {
            $now=Get-Date
            if (($now-$script:lastHeartbeat).TotalSeconds -ge 10) {
                $heartbeat=@{pid=$PID;time=$now.ToString('o');version=$henuVersion;state='running';failures=$script:failures;mode=$script:workerMode;probeEngine='in-process';cooldownUntil=$script:cooldownUntil.ToString('o');panel=[bool]$script:panel}
                Set-AtomicJson (Join-Path $appDir 'monitor-status.json') $heartbeat
                $script:lastHeartbeat=$now
            }
            if (($now-$script:lastStatusRead).TotalSeconds -ge 1) {
                $script:lastStatusRead=$now
                try { Update-StatusUi } catch {}
            }
            $completed=$false; $code=1
            if ($script:probeWorker.Pending) {
                if ($script:probeWorker.Pending.IsCompleted) {
                    $code=Complete-InternetProbe $script:probeWorker
                    $completed=$true
                } elseif (($now-$script:probeWorker.Started).TotalSeconds -gt 20) {
                    Close-InternetProbeWorker $script:probeWorker
                    $script:probeWorker=$null
                    $script:probeWorker=New-InternetProbeWorker (Join-Path $PSScriptRoot 'Common.ps1')
                    Write-Log '进程内联网检查超时，已重建检测线程，不触发认证。'
                    $completed=$true
                }
            }
            if ($script:worker) {
                $script:worker.Refresh()
                if ($script:worker.HasExited) {
                    $script:worker.WaitForExit()
                    $code=$script:worker.ExitCode
                    $script:worker.Dispose();$script:worker=$null
                    $completed=$true
                } elseif (($now-$script:worker.StartTime).TotalSeconds -gt 150) {
                    # Terminate only the owned recovery tree, never remote-control software.
                    $stopper=Start-NoConsoleProcess (Join-Path $env:SystemRoot 'System32\taskkill.exe') ('/PID '+$script:worker.Id+' /T /F')
                    $stopper.Dispose()
                    Write-State 'error' '认证等待超时，稍后重试。'
                    Write-Log '守护程序终止了超时的认证子任务。'
                }
            }
            if ($completed) {
                    if ($script:workerMode -eq 'probe') { $script:lastCheck=$now }
                    if ($code -eq 0) {
                        $script:failures=0; $script:firstFailure=[DateTime]::MinValue
                        # Retain the last authentication cooldown across a brief online period.
                        # Otherwise intermittent connectivity could open a new login every minute.
                        if ($now -ge $script:cooldownUntil) { $script:attempts=0 }
                        $script:recoverNext=$false
                        if ($script:workerMode -eq 'recover') { $script:lastError=$null; $script:lastCheck=$now }
                        # Already online: a queued manual login has nothing left to do.
                        $script:loginRequested=$false; $script:manualRecovery=$false
                        Write-State 'online' '互联网可用，安静守护中，不重复登录。'
                        $script:nextCheck=$now.AddSeconds(10)
                    } elseif ($script:workerMode -eq 'probe' -and $code -eq 10) {
                        $decision=Get-ConnectivityDecision $false $script:failures $script:firstFailure $now $script:cooldownUntil
                        $script:failures=$decision.Failures; $script:firstFailure=$decision.FirstFailure
                        $script:recoverNext=$decision.Recover
                        if ($script:loginRequested) {
                            Write-State 'queued' '确认需要认证，马上打开登录页…'
                        } elseif ($now -lt $script:cooldownUntil) {
                            Write-State 'cooldown' '暂未恢复互联网，正在后台检查；稍后再尝试认证，避免重复弹窗。'
                        } else {
                            Write-State 'checking' ('所有联网验证暂未通过，正在确认（第 '+$script:failures+' 轮）…')
                        }
                        $script:nextCheck=if($script:recoverNext){$now}else{$now.AddSeconds(5)}
                    } elseif ($script:workerMode -eq 'recover') {
                        # Keep the reason the login task reported instead of a generic message.
                        $state=Read-HenuStatus
                        $reason=if($state -and @('error','absent') -contains [string]$state.phase -and $state.message){[string]$state.message}else{'本轮恢复未成功（退出码 '+$code+'）。'}
                        $script:lastError=[ordered]@{time=$now.ToString('o');message=$reason}
                        Write-Log ('本轮恢复未成功（退出码 '+$code+'），进入冷却，继续后台检测。')
                        Write-State 'cooldown' ('本轮登录未成功，稍后自动重试。原因：'+$reason)
                        if ($script:manualRecovery -or ($now-$script:lastErrorNotice).TotalMinutes -ge 10) {
                            $script:lastErrorNotice=$now
                            Show-TrayNotice '校园网登录没有成功' $reason 'Warning'
                        }
                        $script:manualRecovery=$false
                        $script:failures=0; $script:firstFailure=[DateTime]::MinValue
                        $script:nextCheck=$now.AddSeconds(10)
                    } else {
                        # A broken checker is not evidence of an offline network.
                        Write-Log ('联网检查程序异常（退出码 '+$code+'），不自动打开认证页。')
                        Write-State 'error' '联网检查异常，稍后重试；不会据此重复认证。'
                        $script:failures=0; $script:firstFailure=[DateTime]::MinValue
                        $script:nextCheck=$now.AddSeconds(30)
                    }
                    $script:lastStatusRead=[DateTime]::MinValue
            }
            if (-not $script:worker -and -not $script:probeWorker.Pending -and ($now -ge $script:nextCheck -or $script:checkNow -or $script:loginRequested)) {
                $script:checkNow=$false
                if ($script:recoverNext -or $script:loginRequested) {
                    $script:manualRecovery=$script:loginRequested
                    $script:loginRequested=$false
                    $script:workerMode='recover'; $script:recoverNext=$false
                    $script:attempts++
                    $script:cooldownUntil=$now.AddSeconds((Get-RecoveryDelay $script:attempts))
                    if ($script:manualRecovery) { Write-Log '按用户请求开始登录流程。' }
                    else { Write-Log ('多站点连续失败已确认，尝试恢复；下一次认证至少间隔 '+(Get-RecoveryDelay $script:attempts)+' 秒。') }
                    $arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'HenuAutoLogin.ps1')+'" -Quiet -RecoveryConfirmed'
                    $script:worker=Start-NoConsoleProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $arguments
                } else {
                    $script:workerMode='probe'
                    if(-not $script:probeWorker){$script:probeWorker=New-InternetProbeWorker (Join-Path $PSScriptRoot 'Common.ps1')}
                    Start-InternetProbe $script:probeWorker
                }
                $script:lastStatusRead=[DateTime]::MinValue
            }
        } catch {
            Write-Log ('守护检查错误：'+$_.Exception.Message)
            $messageLabel.Text='检查出错，请查看日志或点击立即登录重试。'
            $script:nextCheck=(Get-Date).AddSeconds(30)
        }
    })
    $timer.Start()
    $panelTimer.Start()
    [Windows.Forms.Application]::Run($form)
} catch {
    Write-Log ('守护启动失败：'+$_.Exception.Message)
    exit 1
} finally {
    if($panelTimer){$panelTimer.Stop();$panelTimer.Dispose()}
    if($timer){$timer.Stop();$timer.Dispose()}
    if($tray){$tray.Visible=$false;$tray.Dispose()}
    Stop-PanelServer $script:panel
    try {
        $info=Get-Content -LiteralPath $panelInfoPath -Raw -Encoding UTF8|ConvertFrom-Json
        if([int]$info.pid -eq $PID){Remove-Item -LiteralPath $panelInfoPath -Force}
    } catch {}
    Close-InternetProbeWorker $script:probeWorker
    if($script:worker -and -not $script:worker.HasExited){
        $stopper=Start-NoConsoleProcess (Join-Path $env:SystemRoot 'System32\taskkill.exe') ('/PID '+$script:worker.Id+' /T /F')
        $stopper.Dispose()
    }
    Write-Log '守护程序已退出。'
    try{$mutex.ReleaseMutex()}catch{}
    $mutex.Dispose()
}
