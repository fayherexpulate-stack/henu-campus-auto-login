param([switch]$ForceLogin,[switch]$Quiet,[switch]$ProbeOnly,[switch]$RecoveryConfirmed)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')
try {
    # Compatibility: ForceLogin no longer bypasses actual internet verification.
    if (Test-Internet) { Write-State 'online' '互联网可用，安静守护中，不重复登录。'; exit 0 }
    if ($ProbeOnly) { exit 10 }
    if (-not $RecoveryConfirmed) {
        Write-State 'checking' '网络检测暂未通过，正在多轮确认，不会立即弹出登录页。'
        foreach ($round in 1..2) {
            Start-Sleep -Seconds 8
            if (Test-Internet) { Write-State 'online' '互联网已恢复，无需登录。'; exit 0 }
        }
    }
    $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
    $ssid=[string]$config.ssid
    if ((Get-CurrentSsid) -ne $ssid) {
        if (-not (Test-SsidVisible $ssid)) { Write-State 'absent' '附近未发现 henu-student，保留当前网络。'; exit 2 }
        Write-Log ('正在连接 '+$ssid)
        Write-State 'connecting' '正在连接 henu-student…'
        $adapter=Get-WlanAdapter
        & netsh wlan connect name="$ssid" ssid="$ssid" interface="$($adapter.Name)" | Out-Null
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        do { Start-Sleep -Milliseconds 500 } until ((Get-CurrentSsid) -eq $ssid -or [DateTime]::UtcNow -gt $deadline)
        if ((Get-CurrentSsid) -ne $ssid) { throw '连接 henu-student 超时。' }
    }
    if (Test-Internet) { Write-State 'online' '互联网已恢复，无需登录。'; exit 0 }
    Write-Log '需要认证：启动可视化网页自动操作。'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'BrowserLogin.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
    if (-not (Test-Internet)) { throw '网页登录后外网检测未通过。' }
    Write-State 'online' 'henu-student 已联网，后台守护中。'
    exit 0
} catch {
    Write-Log ('连接失败：'+$_.Exception.Message)
    Write-State 'error' $_.Exception.Message
    exit 1
}
