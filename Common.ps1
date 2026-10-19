$appDir = Join-Path $env:LOCALAPPDATA 'HenuAutoLogin'
$configPath = Join-Path $appDir 'config.json'
$logPath = Join-Path $appDir 'auto-login.log'
$henuVersion = '2.5'
$henuOperators = @('mobile','unicom','telecom','campus')
$henuPortalOrigin = 'http://172.29.35.36:6060'

function Write-Log([string]$Message) {
    $logMutex=New-Object Threading.Mutex($false,'Local\HenuAutoLoginLog')
    $locked=$false
    try {
        $locked=$logMutex.WaitOne(2000)
        if(-not $locked){return}
        if((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1048576){
            $previous=$logPath+'.1'
            Remove-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $logPath -Destination $previous -Force
        }
        Add-Content -LiteralPath $logPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message) -Encoding UTF8
    } finally {
        if($locked){$logMutex.ReleaseMutex()}
        $logMutex.Dispose()
    }
}
function Set-AtomicUtf8File([string]$Path,[string]$Content) {
    $directory=Split-Path -Parent $Path
    if(-not (Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $temporary=$Path+'.tmp.'+$PID+'.'+[Guid]::NewGuid().ToString('N')
    $backup=$Path+'.bak.'+$PID+'.'+[Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary,$Content,[Text.UTF8Encoding]::new($true))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,$backup,$true)}
        else{[IO.File]::Move($temporary,$Path)}
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}
function Set-AtomicJson([string]$Path,$Value,[int]$Depth=8) {
    Set-AtomicUtf8File $Path ($Value|ConvertTo-Json -Depth $Depth -Compress)
}
function Write-State([string]$Phase, [string]$Message) {
    $state = @{ phase=$Phase; message=$Message; time=(Get-Date).ToString('o') }
    Set-AtomicJson (Join-Path $appDir 'status.json') $state
}
function Get-CurrentSsid {
    foreach ($line in (& netsh wlan show interfaces 2>$null)) {
        if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}
function Test-SsidVisible([string]$Ssid) {
    foreach ($line in (& netsh wlan show networks mode=bssid 2>$null)) {
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.+?)\s*$' -and $Matches[1] -eq $Ssid) { return $true }
    }
    return $false
}
function Get-WlanAdapter {
    $wlan = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.NdisPhysicalMedium -eq 1 } | Sort-Object @{Expression={ $_.Status -eq 'Up' };Descending=$true} | Select-Object -First 1
    if (-not $wlan) { $wlan = Get-NetAdapter -Name 'WLAN','Wi-Fi' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $wlan) { throw '没有找到无线网卡。' }
    return $wlan
}
function Get-WlanIPv4 {
    $adapter = Get-WlanAdapter
    return Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 -ExpandProperty IPAddress
}
function Get-PortalContextFromLocation([string]$Location,[string]$ExpectedOrigin,[string]$FallbackIp,[string]$FallbackAc) {
    $fallback=[pscustomobject]@{Ip=$FallbackIp;AcName=$FallbackAc;Source='fallback'}
    try {
        $uri=[uri]$Location
        if(-not $uri.IsAbsoluteUri -or $uri.GetLeftPart([UriPartial]::Authority) -ne $ExpectedOrigin){return $fallback}
        Add-Type -AssemblyName System.Web
        $query=[Web.HttpUtility]::ParseQueryString($uri.Query)
        $ipText=[string]$query['wlanuserip'];$ac=[string]$query['wlanacname']
        $parsedIp=$null
        if(-not [Net.IPAddress]::TryParse($ipText,[ref]$parsedIp) -or $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $fallback}
        if($ac -notmatch '^[A-Za-z0-9._:-]{1,128}$'){return $fallback}
        return [pscustomobject]@{Ip=$ipText;AcName=$ac;Source='redirect'}
    } catch {return $fallback}
}
function Get-PortalContext([string]$ExpectedOrigin,[string]$FallbackIp,[string]$FallbackAc) {
    $response=$null
    try {
        $request=[Net.HttpWebRequest]::Create('http://www.baidu.com/?henu-captive-check=1')
        $request.Proxy=$null;$request.AllowAutoRedirect=$false;$request.Timeout=3000;$request.ReadWriteTimeout=3000
        $response=$request.GetResponse()
        $location=[string]$response.Headers['Location']
        return Get-PortalContextFromLocation $location $ExpectedOrigin $FallbackIp $FallbackAc
    } catch {return [pscustomobject]@{Ip=$FallbackIp;AcName=$FallbackAc;Source='fallback'}}
    finally {if($response){$response.Dispose()}}
}
function Test-ProbeContent([string]$Kind, [int]$StatusCode, [string]$Body) {
    if ($StatusCode -ne 200) { return $false }
    # HTTPS certificate validation stays enabled; captive portal HTML is not internet access.
    return ($Kind -eq 'robots' -and $Body -notmatch '(?i)<(?:html|form|!doctype)' -and
        $Body -match '(?im)^\s*User-agent\s*:' -and $Body -match '(?im)^\s*(?:Disallow|Allow)\s*:')
}
function Test-Internet {
    param($TestHandler = $null)
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($null -eq $TestHandler) {
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
    } else { $handler = $TestHandler } # In-memory transport injection for offline regression tests only.
    # Respect the Windows proxy: working internet via a proxy needs no new campus login.
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(4)
    $client.MaxResponseContentBufferSize = 65536
    $client.DefaultRequestHeaders.CacheControl = [Net.Http.Headers.CacheControlHeaderValue]::new()
    $client.DefaultRequestHeaders.CacheControl.NoCache = $true
    $client.DefaultRequestHeaders.CacheControl.NoStore = $true
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $probes = @(
        @{kind='robots';url="https://www.baidu.com/robots.txt?t=$stamp"},
        @{kind='robots';url="https://www.qq.com/robots.txt?t=$stamp"},
        @{kind='robots';url="https://www.163.com/robots.txt?t=$stamp"}
    )
    try {
        foreach ($probe in $probes) { $probe.task = $client.GetAsync($probe.url); $probe.done = $false }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            foreach ($probe in $probes) {
                if (-not $probe.done -and $probe.task.IsCompleted) {
                    $probe.done = $true
                    if ($probe.task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
                        $response = $probe.task.Result
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        if (Test-ProbeContent $probe.kind ([int]$response.StatusCode) $body) { return $true }
                    }
                }
            }
            if (@($probes | Where-Object { -not $_.done }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 80
        } while ($watch.Elapsed.TotalSeconds -lt 4.5)
        return $false
    } finally {
        $client.CancelPendingRequests()
        foreach ($probe in $probes) {
            if ($probe.task -and $probe.task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $probe.task.Result.Dispose() }
        }
        $client.Dispose()
    }
}
function Get-ConnectivityDecision([bool]$Online, [int]$Failures, [DateTime]$FirstFailure, [DateTime]$Now, [DateTime]$CooldownUntil) {
    if ($Online) { return [pscustomobject]@{Failures=0;FirstFailure=[DateTime]::MinValue;Recover=$false} }
    if ($Failures -eq 0) { $FirstFailure=$Now }
    $Failures++
    return [pscustomobject]@{
        Failures=$Failures;FirstFailure=$FirstFailure
        Recover=($Failures -ge 3 -and ($Now-$FirstFailure).TotalSeconds -ge 15 -and $Now -ge $CooldownUntil)
    }
}
function Get-RecoveryDelay([int]$Attempts) { return [Math]::Min(300, 120 * [Math]::Max(1,$Attempts)) }
function New-InternetProbeWorker([string]$CommonPath) {
    # A reusable in-process thread: regular probes create no powershell.exe or console window.
    $runspace=[RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState='MTA'
    $runspace.ThreadOptions='ReuseThread'
    $shell=[PowerShell]::Create()
    try {
        $runspace.Open()
        $shell.Runspace=$runspace
        [void]$shell.AddScript('param($path) $ErrorActionPreference="Stop"; . $path').AddArgument($CommonPath)
        [void]$shell.Invoke()
        if($shell.HadErrors){throw '无法初始化后台联网检测。'}
        $shell.Commands.Clear()
        return [pscustomobject]@{Shell=$shell;Runspace=$runspace;Pending=$null;Started=[DateTime]::MinValue}
    } catch { $shell.Dispose();$runspace.Dispose();throw }
}
function Start-InternetProbe($Worker) {
    if($Worker.Pending){throw '上一轮联网检查尚未完成。'}
    $Worker.Shell.Commands.Clear();$Worker.Shell.Streams.Error.Clear()
    [void]$Worker.Shell.AddScript('Test-Internet')
    $Worker.Started=Get-Date
    $Worker.Pending=$Worker.Shell.BeginInvoke()
}
function Complete-InternetProbe($Worker) {
    if(-not $Worker.Pending -or -not $Worker.Pending.IsCompleted){throw '联网检查尚未完成。'}
    try {
        $result=$Worker.Shell.EndInvoke($Worker.Pending)
        if($Worker.Shell.HadErrors -or $result.Count -ne 1 -or $result[0] -isnot [bool]){return 1}
        if($result[0]){return 0}
        return 10
    } catch { return 1 }
    finally { $Worker.Pending=$null }
}
function Close-InternetProbeWorker($Worker) {
    if($Worker){
        try { if($Worker.Pending){$Worker.Shell.Stop()} }
        finally {$Worker.Shell.Dispose();$Worker.Runspace.Dispose()}
    }
}
function Start-NoConsoleProcess([string]$FilePath,[string]$Arguments) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$FilePath;$info.Arguments=$Arguments
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    return [Diagnostics.Process]::Start($info)
}
function Test-HenuUsername([string]$Username) { return ([string]$Username -cmatch '^[A-Za-z0-9._]{1,64}$') }
function Protect-HenuSecret([string]$PlainText) {
    Add-Type -AssemblyName System.Security
    $bytes=[Text.Encoding]::UTF8.GetBytes($PlainText)
    try { return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)) }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}
function Read-HenuConfig([string]$Path=$configPath) {
    if(-not (Test-Path -LiteralPath $Path)){return $null}
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json) } catch { return $null }
}
function Get-HenuConfigSummary([string]$Path=$configPath) {
    # Never returns the password or its ciphertext; safe to show in the tray or the local panel.
    $config=Read-HenuConfig $Path
    if(-not $config -or [string]::IsNullOrWhiteSpace([string]$config.username)){
        return [ordered]@{configured=$false;username='';operator=''}
    }
    return [ordered]@{
        configured=(-not [string]::IsNullOrWhiteSpace([string]$config.protectedPassword))
        username=[string]$config.username;operator=[string]$config.operator
    }
}
function Save-HenuConfig {
    param(
        [string]$Username,[string]$Password,[string]$Operator,
        [string]$Path=$configPath,
        [scriptblock]$Protector={param($plain) Protect-HenuSecret $plain}
    )
    $Username=([string]$Username).Trim()
    if(-not (Test-HenuUsername $Username)){throw '账号只能包含字母、数字、点和下划线（1～64 位）。'}
    if($henuOperators -notcontains $Operator){throw '请选择运营商。'}
    $existing=Read-HenuConfig $Path
    if([string]::IsNullOrEmpty($Password)){
        # An empty password keeps the saved one, but only for the same account.
        if(-not $existing -or [string]::IsNullOrWhiteSpace([string]$existing.protectedPassword)){throw '请输入校园网密码。'}
        if([string]$existing.username -ne $Username){throw '更换账号时需要重新输入密码。'}
        $protected=[string]$existing.protectedPassword
    } else {
        if($Password.Length -gt 128){throw '密码长度超出范围。'}
        $protected=[string](& $Protector $Password)
        if([string]::IsNullOrWhiteSpace($protected)){throw '无法加密保存密码。'}
    }
    $acName='HD-SuShe-ME60'
    if($existing -and [string]$existing.defaultAcName -match '^[A-Za-z0-9._:-]{1,128}$'){$acName=[string]$existing.defaultAcName}
    $configuration=[ordered]@{
        version=$henuVersion;ssid='henu-student';username=$Username;protectedPassword=$protected
        operator=$Operator;loginMode='browser';portalOrigin=$henuPortalOrigin;defaultAcName=$acName
    }
    Set-AtomicJson $Path $configuration
    return (Get-HenuConfigSummary $Path)
}
function Get-HenuOperatorName([string]$Operator) {
    $names=@{mobile='移动';unicom='联通';telecom='电信';campus='校园资源'}
    if($names.ContainsKey($Operator)){return $names[$Operator]}
    return '未设置'
}
function Read-HenuStatus {
    $path=Join-Path $appDir 'status.json'
    if(-not (Test-Path -LiteralPath $path)){return $null}
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json) } catch { return $null }
}
function Get-HenuPhaseInfo([string]$Phase) {
    # One mapping shared by the tray icon, the flyout and the web panel.
    switch -Exact ($Phase) {
        'online'     { return [ordered]@{level='ok';title='已联网'} }
        'checking'   { return [ordered]@{level='busy';title='正在检测'} }
        'queued'     { return [ordered]@{level='busy';title='准备登录'} }
        'connecting' { return [ordered]@{level='busy';title='正在连接 Wi-Fi'} }
        'opening'    { return [ordered]@{level='busy';title='正在打开认证页'} }
        'waiting'    { return [ordered]@{level='busy';title='等待认证页'} }
        'filling'    { return [ordered]@{level='busy';title='正在登录'} }
        'submitted'  { return [ordered]@{level='busy';title='验证联网结果'} }
        'cooldown'   { return [ordered]@{level='warn';title='稍后重试'} }
        'absent'     { return [ordered]@{level='idle';title='未发现 henu-student'} }
        'error'      { return [ordered]@{level='error';title='需要处理'} }
        default      { return [ordered]@{level='idle';title='检测中'} }
    }
}
function Get-PlainText([string]$ProtectedText) {
    Add-Type -AssemblyName System.Security
    $cipher = [Convert]::FromBase64String($ProtectedText)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($cipher,0,$cipher.Length); [Array]::Clear($plain,0,$plain.Length) }
}
