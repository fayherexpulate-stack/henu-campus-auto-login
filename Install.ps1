param(
    [switch]$Silent,
    [ValidateSet('mobile','unicom','telecom','campus')]
    [string]$Operator = 'mobile'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Security
$taskName = 'HENU Campus Auto Login'
$installDir = Join-Path $env:LOCALAPPDATA 'HenuAutoLogin'
$sourceCore = Join-Path $PSScriptRoot 'HenuAutoLogin.ps1'
$sourceMonitor = Join-Path $PSScriptRoot 'Monitor.ps1'
$sourceBrowser = Join-Path $PSScriptRoot 'BrowserLogin.ps1'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Stop-InstalledRuntime {
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task){Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}
    $scripts=@('Monitor.ps1','HenuAutoLogin.ps1','BrowserLogin.ps1')|ForEach-Object{Join-Path $installDir $_}
    $running=Get-CimInstance Win32_Process | Where-Object {
        $command=[string]$_.CommandLine
        $command -and @($scripts|Where-Object{$command.Contains($_)}).Count -gt 0
    }
    foreach($process in $running){
        $stopper=Start-NoConsoleProcess (Join-Path $env:SystemRoot 'System32\taskkill.exe') ('/PID '+$process.ProcessId+' /T /F')
        $stopper.WaitForExit(5000)|Out-Null;$stopper.Dispose()
    }
}

function Ensure-WifiProfile {
    $profiles = (& netsh wlan show profiles 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Windows Wi-Fi 配置。' }
    if ($profiles -notmatch '(?m):\s*henu-student\s*$') {
        $profileXml = @'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>henu-student</name>
  <SSIDConfig><SSID><hex>68656E752D73747564656E74</hex><name>henu-student</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <autoSwitch>false</autoSwitch>
  <MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security></MSM>
</WLANProfile>
'@
        $tempProfile = Join-Path $env:TEMP ('HenuAutoLogin-wifi-'+[Guid]::NewGuid().ToString('N')+'.xml')
        try {
            [IO.File]::WriteAllText($tempProfile, $profileXml, (New-Object Text.UTF8Encoding($false)))
            & netsh wlan add profile filename="$tempProfile" user=current 2>$null | Out-Null
            if($LASTEXITCODE -ne 0){throw '创建 henu-student Wi-Fi 配置失败。'}
        } finally {Remove-Item -LiteralPath $tempProfile -Force -ErrorAction SilentlyContinue}
    }
    # The assistant, not Windows, decides when to connect after the user confirms being at school.
    & netsh wlan set profileparameter name="henu-student" connectionmode=manual 2>$null | Out-Null
    if($LASTEXITCODE -ne 0){throw '无法将 henu-student 设为手动连接模式。'}
}

function Install-Henu([string]$Username, [string]$Password, [string]$SelectedOperator) {
    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        throw '账号和密码不能为空。'
    }
    if ($Username -notmatch '^[a-zA-Z0-9._]+$') { throw '账号只能包含字母、数字、点和下划线。' }
    Stop-InstalledRuntime
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -LiteralPath $sourceCore -Destination (Join-Path $installDir 'HenuAutoLogin.ps1') -Force
    Copy-Item -LiteralPath $sourceMonitor -Destination (Join-Path $installDir 'Monitor.ps1') -Force
    Copy-Item -LiteralPath $sourceBrowser -Destination (Join-Path $installDir 'BrowserLogin.ps1') -Force
    foreach ($extra in @('Common.ps1','PortalAutomation.js')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $extra) -Destination (Join-Path $installDir $extra) -Force
    }
    $passwordBytes = [Text.Encoding]::UTF8.GetBytes($Password)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect($passwordBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $protectedPassword = [Convert]::ToBase64String($protectedBytes)
    } finally {
        if ($passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
    }
    $configuration=[ordered]@{
        version = '2.4'
        ssid = 'henu-student'
        username = $Username.Trim()
        protectedPassword = $protectedPassword
        operator = $SelectedOperator
        loginMode = 'browser'
        portalOrigin = 'http://172.29.35.36:6060'
        defaultAcName = 'HD-SuShe-ME60'
    }
    Set-AtomicJson (Join-Path $installDir 'config.json') $configuration

    Ensure-WifiProfile

    $scriptPath = Join-Path $installDir 'HenuAutoLogin.ps1'
    $monitorPath = Join-Path $installDir 'Monitor.ps1'
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorPath
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $atLogon -Principal $principal -Settings $settings -Description '登录 Windows 后询问是否在学校；确认后自动连接并持续守护 henu-student' -Force | Out-Null

    $startArguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$monitorPath+'" -SkipPrompt -StartMinimized'
    $monitorProcess=Start-NoConsoleProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $startArguments
    $monitorProcess.Dispose()
}

if ($Silent) {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    Install-Henu -Username ([string]$payload.username) -Password ([string]$payload.password) -SelectedOperator $Operator
    Write-Output 'Installed'
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = '河南大学校园网自动登录助手'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(440, 330)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = 'henu-student 自动连接与认证'
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 15, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(35, 24)
$title.AutoSize = $true
$form.Controls.Add($title)

$hint = New-Object Windows.Forms.Label
$hint.Text = '只需设置一次；密码会用当前 Windows 账户加密保存。'
$hint.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$hint.Location = New-Object Drawing.Point(37, 60)
$hint.AutoSize = $true
$form.Controls.Add($hint)

function Add-Label([string]$Text, [int]$Y) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
    $label.Location = New-Object Drawing.Point(38, $Y)
    $label.Size = New-Object Drawing.Size(80, 28)
    $form.Controls.Add($label)
}

Add-Label '校园网账号' 103
$userBox = New-Object Windows.Forms.TextBox
$userBox.Location = New-Object Drawing.Point(130, 101)
$userBox.Size = New-Object Drawing.Size(265, 28)
$userBox.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$form.Controls.Add($userBox)

Add-Label '校园网密码' 148
$passwordBox = New-Object Windows.Forms.TextBox
$passwordBox.Location = New-Object Drawing.Point(130, 146)
$passwordBox.Size = New-Object Drawing.Size(265, 28)
$passwordBox.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$passwordBox.UseSystemPasswordChar = $true
$form.Controls.Add($passwordBox)

Add-Label '运营商' 193
$operatorBox = New-Object Windows.Forms.ComboBox
$operatorBox.Location = New-Object Drawing.Point(130, 191)
$operatorBox.Size = New-Object Drawing.Size(265, 28)
$operatorBox.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$operatorBox.DropDownStyle = 'DropDownList'
[void]$operatorBox.Items.Add('移动')
[void]$operatorBox.Items.Add('联通')
[void]$operatorBox.Items.Add('电信')
[void]$operatorBox.Items.Add('校园资源（无运营商宽带）')
$operatorBox.SelectedIndex = 0
$form.Controls.Add($operatorBox)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(38, 235)
$status.Size = New-Object Drawing.Size(355, 24)
$status.ForeColor = [Drawing.Color]::DimGray
$status.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.Controls.Add($status)

$installButton = New-Object Windows.Forms.Button
$installButton.Text = '安装并开始守护'
$installButton.Location = New-Object Drawing.Point(130, 270)
$installButton.Size = New-Object Drawing.Size(155, 38)
$installButton.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$form.Controls.Add($installButton)

$cancelButton = New-Object Windows.Forms.Button
$cancelButton.Text = '取消'
$cancelButton.Location = New-Object Drawing.Point(300, 270)
$cancelButton.Size = New-Object Drawing.Size(95, 38)
$cancelButton.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancelButton)

$installButton.Add_Click({
    try {
        $installButton.Enabled = $false
        $status.Text = '正在保存配置并创建开机任务…'
        $form.Refresh()
        $map = @('mobile','unicom','telecom','campus')
        Install-Henu -Username $userBox.Text -Password $passwordBox.Text -SelectedOperator $map[$operatorBox.SelectedIndex]
        $passwordBox.Clear()
        $status.Text = '安装完成，守护程序已在后台启动。'
        [Windows.Forms.MessageBox]::Show('安装成功！本次守护已在后台启动；以后进入 Windows 桌面时会询问是否在学校。henu-student 已设为手动连接，选“否”时 Windows 不会由该配置自动连接。', '安装完成', 'OK', 'Information') | Out-Null
        $form.Close()
    } catch {
        $status.Text = '安装失败：' + $_.Exception.Message
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '安装失败', 'OK', 'Error') | Out-Null
        $installButton.Enabled = $true
    }
})

$form.AcceptButton = $installButton
$form.CancelButton = $cancelButton
[void]$form.ShowDialog()
