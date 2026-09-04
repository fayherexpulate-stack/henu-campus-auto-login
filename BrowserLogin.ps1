param([switch]$DryRun, [switch]$SelfTest, [switch]$KeepTestWindow, [ValidateSet('mobile','unicom','telecom')][string]$TestOperator='mobile', [string]$TestUrl='http://127.0.0.1:8769/portal.html')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')
$created=$false
$mutex=New-Object Threading.Mutex($true,'Local\HenuBrowserLogin',[ref]$created)
if (-not $created) { exit 2 }

function Send-Cdp($Socket,[int]$Id,[string]$Method,$Params) {
    $cancel=New-Object Threading.CancellationTokenSource
    $cancel.CancelAfter(8000)
    try {
        $payload=@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Depth 12 -Compress
        $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
        [void]$Socket.SendAsync([ArraySegment[byte]]::new($bytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,$cancel.Token).GetAwaiter().GetResult()
        while ($true) {
            $memory=New-Object IO.MemoryStream
            try {
                do {
                    $buffer=New-Object byte[] 65536
                    $received=$Socket.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cancel.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw '浏览器窗口已关闭。' }
                    $memory.Write($buffer,0,$received.Count)
                    if ($memory.Length -gt 2097152) { throw '浏览器返回异常数据。' }
                } until ($received.EndOfMessage)
                $message=[Text.Encoding]::UTF8.GetString($memory.ToArray())|ConvertFrom-Json
                if ($message.id -eq $Id) {
                    if ($message.error) { throw ('浏览器控制错误：'+$message.error.code) }
                    if ($message.result.exceptionDetails) { throw '网页操作脚本执行失败。' }
                    return $message
                }
            } finally { $memory.Dispose() }
        }
    } finally { $cancel.Dispose() }
}
function Read-DebugPages([int]$Port) {
    return Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/json/list' -f $Port) -TimeoutSec 2
}
try {
    if ($SelfTest) {
        Write-Log ('开始模拟网页测试（虚拟账号）：'+$TestOperator)
        if (([uri]$TestUrl).Host -ne '127.0.0.1') { throw '自检只能连接本机测试页。' }
        $config=[pscustomobject]@{operator=$TestOperator;username='fixture-user'}
        $portalUrl=$TestUrl
        $profileDir=Join-Path $appDir 'EdgeSelfTest'
    } else {
        if (-not $DryRun -and (Test-Internet)) { Write-State 'online' '互联网可用，已取消打开登录页。'; exit 0 }
        $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
        if ([string]$config.portalOrigin -ne 'http://172.29.35.36:6060') { throw '认证地址不在允许列表，已停止发送账号密码。' }
        $ip=Get-WlanIPv4
        if (-not $ip) { throw 'Wi-Fi 尚未获取地址。' }
        $portalUrl='{0}/portalReceiveAction.do?wlanuserip={1}&wlanacname={2}' -f $config.portalOrigin,[uri]::EscapeDataString($ip),[uri]::EscapeDataString($config.defaultAcName)
        $profileDir=Join-Path $appDir 'EdgeProfile'
    }
    $edgePath=@((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')) | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
    if (-not $edgePath) { throw '未找到 Microsoft Edge。' }
    $port=0
    # Reuse the debugging port belonging to our dedicated profile only.
    $existing=Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profileDir) -and $_.CommandLine -notmatch '--type=' } | Select-Object -First 1
    if ($existing -and $existing.CommandLine -match '--remote-debugging-port=(\d+)') {
        $port=[int]$Matches[1]
        try { $pages=Read-DebugPages $port } catch { throw '专用认证窗口无法响应；请关闭该窗口后点立即重连。' }
    } else {
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $listener.Start(); $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
        $edgeArgs=@("--user-data-dir=`"$profileDir`"","--remote-debugging-port=$port",'--remote-debugging-address=127.0.0.1','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-sync','--disable-features=msEdgeFirstRunExperience','--app=about:blank')
        Start-Process -FilePath $edgePath -ArgumentList $edgeArgs -WindowStyle Normal | Out-Null
    }
    Write-State 'opening' '正在连接专用 Edge 认证窗口…'
    Write-Log '浏览器认证启动：等待控制连接。'
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    $page=$null
    do {
        try {
            $pages=Read-DebugPages $port
            foreach ($candidate in $pages) {
                if ($candidate.type -eq 'page') { $page=$candidate; break }
            }
        } catch {}
        if (-not $page) { Start-Sleep -Milliseconds 250 }
    } until ($page -or [DateTime]::UtcNow -gt $deadline)
    if (-not $page) { throw '专用浏览器控制连接超时。' }
    $socket=[Net.WebSockets.ClientWebSocket]::new()
    $cancel=New-Object Threading.CancellationTokenSource
    $cancel.CancelAfter(8000)
    try { [void]$socket.ConnectAsync([uri]([string]$page.webSocketDebuggerUrl),$cancel.Token).GetAwaiter().GetResult() }
    finally { $cancel.Dispose() }
    [void](Send-Cdp $socket 1 'Page.navigate' @{url=$portalUrl})
    $map=@{mobile='yd';unicom='lt';telecom='dx';campus='xnzy'}
    $op=$map[[string]$config.operator]
    if (-not $op) { throw '运营商配置无效。' }
    $automation=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PortalAutomation.js') -Raw -Encoding UTF8
    $cfg=@{action='ready';operator=$op;origin=([uri]$portalUrl).GetLeftPart([UriPartial]::Authority)}
    $id=10
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    Write-State 'waiting' '等待账号框、运营商及登录按钮加载完成…'
    do {
        $json=$cfg|ConvertTo-Json -Compress
        $result=Send-Cdp $socket $id 'Runtime.evaluate' @{expression=($automation+'('+$json+')');returnByValue=$true}
        $id++
        $ready=$result.result.result.value.ok
        if ($DryRun -and $id -eq 11) { $result.result.result.value | ConvertTo-Json -Compress }
        if (-not $ready) { Start-Sleep -Milliseconds 350 }
    } until ($ready -or [DateTime]::UtcNow -gt $deadline)
    if (-not $ready) {
        Write-Log ('页面就绪检查：'+($result.result.result.value | ConvertTo-Json -Compress))
        throw '登录页未准备就绪（控件或按钮事件未加载），未提交账号。'
    }
    Write-Log '登录页及按钮事件已就绪。'
    if (-not $DryRun) {
        if (-not $SelfTest -and (Test-Internet)) {
            Write-State 'online' '互联网已恢复，取消重复认证。'
            try { [void](Send-Cdp $socket 999 'Browser.close' @{}) } catch {}
            exit 0
        }
        $cfg.action='submit'; $cfg.username=[string]$config.username
        $cfg.password=if($SelfTest){'fixture-pass'}else{Get-PlainText ([string]$config.protectedPassword)}
        Write-State 'filling' '正在填写账号密码并选择运营商…'
        $json=$cfg|ConvertTo-Json -Compress
        $result=Send-Cdp $socket $id 'Runtime.evaluate' @{expression=($automation+'('+$json+')');returnByValue=$true}
        $id++
        $cfg.password=$null; $json=$null
        if (-not $result.result.result.value.submitted) { throw '网页填写或运营商选择检查失败，未确认登录点击。' }
        Write-Log ('网页操作已核对：账号密码已填入，运营商='+$op+'，登录按钮已执行。')
        Write-State 'submitted' '已点击登录，正在验证联网结果…'
    }
    if ($SelfTest) {
        $result=Send-Cdp $socket $id 'Runtime.evaluate' @{expression='({result:document.body.dataset.result, clicks:document.body.dataset.clicks, selected:document.querySelector(".on input").value})';returnByValue=$true}
        $value=$result.result.result.value
        if ($value.result -ne ('ok-'+$op) -or $value.clicks -ne '1') { throw '模拟页端到端测试失败。' }
        $value|ConvertTo-Json -Compress
    } elseif (-not $DryRun) {
        $deadline=[DateTime]::UtcNow.AddSeconds(35)
        $online=$false
        do { $online=Test-Internet; if(-not $online){Start-Sleep -Milliseconds 750} } until ($online -or [DateTime]::UtcNow -gt $deadline)
        if (-not $online) { throw '已经自动点击登录，但尚未联网；请查看校园网页的错误提示。' }
        Write-Log '浏览器登录操作完成，外网检测通过（不等同于断网恢复实测）。'
        Write-State 'online' '网页已操作，联网检查通过。'
    } else { Write-Output 'READINESS_OK' }
    if (-not ($SelfTest -and $KeepTestWindow)) {
        try { [void](Send-Cdp $socket 999 'Browser.close' @{}) } catch {}
    }
    exit 0
} catch {
    Write-Log ('浏览器认证失败：'+$_.Exception.Message)
    Write-State 'error' $_.Exception.Message
    exit 1
} finally {
    if ($socket) { $socket.Dispose() }
    try {$mutex.ReleaseMutex()} catch {}
    $mutex.Dispose()
}
