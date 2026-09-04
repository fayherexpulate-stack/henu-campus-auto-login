$appDir = Join-Path $env:LOCALAPPDATA 'HenuAutoLogin'
$configPath = Join-Path $appDir 'config.json'
$logPath = Join-Path $appDir 'auto-login.log'

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $logPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message) -Encoding UTF8
}
function Write-State([string]$Phase, [string]$Message) {
    $state = @{ phase=$Phase; message=$Message; time=(Get-Date).ToString('o') }
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $appDir 'status.json') -Encoding UTF8
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
function Get-PlainText([string]$ProtectedText) {
    Add-Type -AssemblyName System.Security
    $cipher = [Convert]::FromBase64String($ProtectedText)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($cipher,0,$cipher.Length); [Array]::Clear($plain,0,$plain.Length) }
}
