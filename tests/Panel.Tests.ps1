param([string]$SourcePath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'desktop-app'))
# Offline tests for the v2.5 local web panel and shared config helpers.
# Never touches the real config, Wi-Fi, saved passwords or the campus portal.
$ErrorActionPreference='Stop'
. (Join-Path $SourcePath 'Common.ps1')
. (Join-Path $SourcePath 'PanelServer.ps1')
function Assert([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Output "PASS: $Name"
}
function Assert-Throws([scriptblock]$Action,[string]$Name) {
    $thrown=$false
    try { & $Action } catch { $thrown=$true }
    Assert $thrown $Name
}
function Get-Bytes([string]$Text) { return ,([Text.Encoding]::UTF8.GetBytes($Text)) }
function New-Req([string]$Method,[string]$Path,[hashtable]$Headers,[string]$Body='') {
    $h=@{}; foreach($k in $Headers.Keys){$h[$k.ToLowerInvariant()]=$Headers[$k]}
    return [pscustomobject]@{Method=$Method;Path=$Path;Headers=$h;Body=$Body}
}

# ---------- token ----------
$token=New-PanelToken
Assert ($token -cmatch '^[0-9a-f]{64}$') 'token is 256-bit lowercase hex'
Assert ((New-PanelToken) -ne $token) 'tokens differ per launch'
Assert (Test-PanelTokenEqual $token $token) 'token equality'
Assert (-not (Test-PanelTokenEqual ($token.Substring(0,63)+'x') $token)) 'token mismatch rejected'
Assert (-not (Test-PanelTokenEqual '' $token)) 'empty token rejected'
Assert (-not (Test-PanelTokenEqual $token.Substring(1) $token)) 'short token rejected'

# ---------- request parser ----------
Assert ($null -eq (ConvertFrom-PanelRequestBytes (Get-Bytes "GET / HTTP/1.1`r`nHost: a"))) 'incomplete header waits'
$r=ConvertFrom-PanelRequestBytes (Get-Bytes "GET /api/status?x=1 HTTP/1.1`r`nHost: 127.0.0.1:18760`r`nX-Henu-Token: abc`r`n`r`n")
Assert ($r.Method -eq 'GET' -and $r.Path -eq '/api/status' -and $r.Headers['host'] -eq '127.0.0.1:18760' -and $r.Headers['x-henu-token'] -eq 'abc') 'parse GET with query and headers'
$partial="POST /api/config HTTP/1.1`r`nHost: 127.0.0.1:1`r`nContent-Length: 10`r`n`r`n{`"a`":"
Assert ($null -eq (ConvertFrom-PanelRequestBytes (Get-Bytes $partial))) 'incomplete body waits'
$r=ConvertFrom-PanelRequestBytes (Get-Bytes ($partial+'"bc"}'))
Assert ($r.Body -eq '{"a":"bc"}') 'body assembled after more bytes arrive'
$r=ConvertFrom-PanelRequestBytes (Get-Bytes "POST /api/config HTTP/1.1`r`nHost: x`r`nContent-Length: 11`r`n`r`n{`"u`":`"张`"}")
Assert ($r.Body -eq '{"u":"张"}') 'UTF-8 body length counted in bytes'
Assert-Throws { ConvertFrom-PanelRequestBytes (Get-Bytes "GARBAGE`r`n`r`n") } 'malformed request line rejected'
Assert-Throws { ConvertFrom-PanelRequestBytes (Get-Bytes "GET / HTTP/1.1`r`nHost: a`r`nHost: b`r`n`r`n") } 'duplicate Host rejected'
Assert-Throws { ConvertFrom-PanelRequestBytes (Get-Bytes "POST / HTTP/1.1`r`nHost: a`r`nTransfer-Encoding: chunked`r`n`r`n") } 'chunked body rejected'
Assert-Throws { ConvertFrom-PanelRequestBytes (Get-Bytes "POST / HTTP/1.1`r`nHost: a`r`nContent-Length: 99999`r`n`r`n") } 'oversized body rejected'
Assert-Throws { ConvertFrom-PanelRequestBytes (Get-Bytes ("GET / HTTP/1.1`r`nX: "+('a'*9000))) } 'oversized header rejected'
Assert-Throws { ConvertFrom-PanelRequestBytes (Get-Bytes "GET / HTTP/1.1`r`nbad header`r`n`r`n") } 'malformed header rejected'

# ---------- authorization ----------
$port=18760
$ok=@{Host="127.0.0.1:$port";'X-Henu-Token'=$token}
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/api/status' $ok) $port $token) -eq 0) 'valid API request allowed'
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/api/status' @{Host="localhost:$port";'X-Henu-Token'=$token}) $port $token) -eq 0) 'localhost host allowed'
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/' @{Host="127.0.0.1:$port";'Sec-Fetch-Site'='none'}) $port $token) -eq 0) 'page itself needs no token'
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/api/status' @{Host="evil.example:$port";'X-Henu-Token'=$token}) $port $token) -eq 421) 'DNS rebinding host rejected'
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/' @{Host="127.0.0.1:9999"}) $port $token) -eq 421) 'wrong port in Host rejected'
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/api/status' @{Host="127.0.0.1:$port"}) $port $token) -eq 401) 'missing token rejected'
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/api/status' @{Host="127.0.0.1:$port";'X-Henu-Token'='0'*64}) $port $token) -eq 401) 'wrong token rejected'
Assert ((Test-PanelRequestAllowed (New-Req 'OPTIONS' '/api/login' $ok) $port $token) -eq 405) 'CORS preflight always refused'
$foreign=$ok.Clone(); $foreign.Origin='https://evil.example'
Assert ((Test-PanelRequestAllowed (New-Req 'POST' '/api/login' $foreign) $port $token) -eq 403) 'foreign Origin rejected'
$cross=@{Host="127.0.0.1:$port";'Sec-Fetch-Site'='cross-site'}
Assert ((Test-PanelRequestAllowed (New-Req 'GET' '/' $cross) $port $token) -eq 403) 'cross-site fetch metadata rejected'
$plain=$ok.Clone(); $plain['Content-Type']='text/plain'
Assert ((Test-PanelRequestAllowed (New-Req 'POST' '/api/login' $plain) $port $token) -eq 415) 'simple-request content type rejected'
$json=$ok.Clone(); $json['Content-Type']='application/json; charset=utf-8'; $json.Origin="http://127.0.0.1:$port"; $json['Sec-Fetch-Site']='same-origin'
Assert ((Test-PanelRequestAllowed (New-Req 'POST' '/api/login' $json) $port $token) -eq 0) 'same-origin JSON POST allowed'

# ---------- routing ----------
$calls=@{save=0;login=0;check=0}
$saved=@{}
$handlers=@{
    Page={ '<!doctype html><title>t</title>' }
    Status={ [ordered]@{phase='online';level='ok';title='已联网';config=[ordered]@{configured=$true;username='u1';operator='mobile'}} }
    SaveConfig={ param($u,$p,$o) $calls.save++; $saved.u=$u; $saved.p=$p; $saved.o=$o; if($u -eq 'bad user'){throw '账号只能包含字母、数字、点和下划线（1～64 位）。'}; [ordered]@{configured=$true;username=$u;operator=$o} }
    Login={ $calls.login++; if($calls.login -gt 1){[ordered]@{accepted=$false;reason='busy';message='busy'}}else{[ordered]@{accepted=$true;message='started'}} }
    Check={ $calls.check++; [ordered]@{ok=$true} }
}
function Invoke-Test([string]$Method,[string]$Path,[string]$Body='',[hashtable]$Extra=@{}) {
    $h=$json.Clone(); foreach($k in $Extra.Keys){$h[$k]=$Extra[$k]}
    if($Body){$h['Content-Length']=[string][Text.Encoding]::UTF8.GetByteCount($Body)}
    return Invoke-PanelRequest (New-Req $Method $Path $h $Body) $port $token $handlers
}
$page=Invoke-PanelRequest (New-Req 'GET' '/' @{Host="127.0.0.1:$port"}) $port $token $handlers
Assert ($page.Status -eq 200 -and $page.ContentType -like 'text/html*') 'page served'
$wire=[Text.Encoding]::UTF8.GetString((ConvertTo-PanelResponseBytes $page))
Assert ($wire -match "Content-Security-Policy: default-src 'none'" -and $wire -match 'X-Frame-Options: DENY' -and $wire -match 'Cache-Control: no-store') 'security headers present'
Assert ($wire -notmatch '(?i)Access-Control-Allow') 'no CORS headers are ever sent'
Assert ($wire -match "Content-Length: $($page.Body.Length)\r\n") 'content length matches body bytes'
$status=Invoke-Test 'GET' '/api/status'
$statusJson=[Text.Encoding]::UTF8.GetString($status.Body)|ConvertFrom-Json
Assert ($status.Status -eq 200 -and $statusJson.level -eq 'ok' -and $statusJson.config.username -eq 'u1') 'status JSON returned'
$res=Invoke-Test 'POST' '/api/config' '{"username":"2023001","password":"p@ss","operator":"unicom"}'
Assert ($res.Status -eq 200 -and $calls.save -eq 1 -and $saved.u -eq '2023001' -and $saved.p -eq 'p@ss' -and $saved.o -eq 'unicom') 'config saved through handler'
Assert (-not ([Text.Encoding]::UTF8.GetString($res.Body) -match 'p@ss')) 'password never echoed back'
$res=Invoke-Test 'POST' '/api/config' '{"username":"bad user","password":"x","operator":"mobile"}'
$err=[Text.Encoding]::UTF8.GetString($res.Body)|ConvertFrom-Json
Assert ($res.Status -eq 400 -and $err.error -like '账号*') 'validation error returned as 400 with message'
$res=Invoke-Test 'POST' '/api/config' '{"username":123,"password":"x","operator":"mobile"}'
Assert ($res.Status -eq 400) 'non-string field rejected'
$res=Invoke-Test 'POST' '/api/config' 'not json'
Assert ($res.Status -eq 400) 'invalid JSON rejected'
$res=Invoke-Test 'POST' '/api/config' '[1,2]'
Assert ($res.Status -eq 400) 'JSON array rejected'
$before=$calls.save
$res=Invoke-Test 'POST' '/api/login' '{"username":"2023001","password":"p","operator":"telecom"}'
Assert ($res.Status -eq 200 -and $calls.save -eq $before+1 -and $calls.login -eq 1) 'login saves then starts'
$res=Invoke-Test 'POST' '/api/login' '{}'
Assert ($res.Status -eq 409 -and $calls.save -eq $before+1) 'busy login returns 409 without saving'
$res=Invoke-Test 'POST' '/api/check' '{}'
Assert ($res.Status -eq 200 -and $calls.check -eq 1) 'check endpoint'
Assert ((Invoke-Test 'GET' '/nope').Status -eq 404) 'unknown path 404'
Assert ((Invoke-Test 'PUT' '/api/config' '{}').Status -eq 405) 'unsupported method 405'
$denied=Invoke-PanelRequest (New-Req 'POST' '/api/login' @{Host="127.0.0.1:$port";'Content-Type'='application/json'} '{}') $port $token $handlers
Assert ($denied.Status -eq 401 -and $calls.login -eq 2) 'unauthenticated login never reaches handler'

# ---------- config helpers ----------
$testDir=Join-Path ([IO.Path]::GetTempPath()) ('henu-panel-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$testConfig=Join-Path $testDir 'config.json'
$fake={param($plain) 'CIPHER:'+$plain.Length}
try {
    Assert (-not (Get-HenuConfigSummary $testConfig).configured) 'missing config is unconfigured'
    Assert-Throws { Save-HenuConfig -Username '2023001' -Password '' -Operator 'mobile' -Path $testConfig -Protector $fake } 'first save requires password'
    Assert-Throws { Save-HenuConfig -Username 'a b' -Password 'x' -Operator 'mobile' -Path $testConfig -Protector $fake } 'invalid username rejected'
    Assert-Throws { Save-HenuConfig -Username 'ok' -Password 'x' -Operator 'cmcc' -Path $testConfig -Protector $fake } 'invalid operator rejected'
    $summary=Save-HenuConfig -Username ' 2023001 ' -Password 'secret' -Operator 'mobile' -Path $testConfig -Protector $fake
    $raw=Get-Content -LiteralPath $testConfig -Raw -Encoding UTF8
    $config=$raw|ConvertFrom-Json
    Assert ($summary.configured -and $summary.username -eq '2023001' -and $config.protectedPassword -eq 'CIPHER:6') 'config saved with protected password and trimmed username'
    Assert ($raw -notmatch 'secret') 'plain password never written'
    Assert ($config.portalOrigin -eq 'http://172.29.35.36:6060' -and $config.loginMode -eq 'browser' -and $config.version -eq $henuVersion) 'fixed portal origin and version'
    Assert (-not ($summary.Keys -contains 'protectedPassword')) 'summary excludes ciphertext'
    $config.defaultAcName='HD-JiaoXue-ME60'; Set-AtomicJson $testConfig $config
    $summary=Save-HenuConfig -Username '2023001' -Password '' -Operator 'telecom' -Path $testConfig -Protector { throw 'must not re-encrypt' }
    $config=Get-Content -LiteralPath $testConfig -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($config.protectedPassword -eq 'CIPHER:6' -and $config.operator -eq 'telecom') 'blank password keeps saved one for same account'
    Assert ($config.defaultAcName -eq 'HD-JiaoXue-ME60') 'custom AC name preserved'
    Assert-Throws { Save-HenuConfig -Username '2023002' -Password '' -Operator 'mobile' -Path $testConfig -Protector $fake } 'changing account requires a new password'
    Assert-Throws { Save-HenuConfig -Username '2023002' -Password ('x'*129) -Operator 'mobile' -Path $testConfig -Protector $fake } 'overlong password rejected'
} finally {
    foreach($name in @('config.json')){ $p=Join-Path $testDir $name; if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p} }
    Remove-Item -LiteralPath $testDir
}

# ---------- phase mapping ----------
Assert ((Get-HenuPhaseInfo 'online').level -eq 'ok') 'online is green'
Assert ((Get-HenuPhaseInfo 'filling').level -eq 'busy') 'login phases are busy'
Assert ((Get-HenuPhaseInfo 'cooldown').level -eq 'warn') 'cooldown is warning'
Assert ((Get-HenuPhaseInfo 'error').level -eq 'error') 'error is red'
Assert ((Get-HenuPhaseInfo 'whatever').level -eq 'idle') 'unknown phase is neutral'
Assert ((Get-HenuOperatorName 'unicom') -eq '联通' -and (Get-HenuOperatorName '') -eq '未设置') 'operator names'

# ---------- real loopback socket, single-threaded pump ----------
Add-Type -AssemblyName System.Net.Http
$server=Start-PanelServer @()
try {
    Assert ($server.Listener.LocalEndpoint.Address.Equals([Net.IPAddress]::Loopback)) 'listener bound to 127.0.0.1 only'
    Assert ((Get-PanelUrl $server) -eq ('http://127.0.0.1:{0}/#t={1}' -f $server.Port,$server.Token)) 'panel URL carries token in fragment'
    $idle=New-Object Net.Sockets.TcpClient
    $idle.Connect([Net.IPAddress]::Loopback,$server.Port)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    for($i=0;$i -lt 5;$i++){ Invoke-PanelPump $server $handlers; Start-Sleep -Milliseconds 20 }
    Assert ($watch.ElapsedMilliseconds -lt 1500 -and $server.Connections.Count -eq 1) 'idle pre-connection never blocks the UI thread'
    $handler=New-Object Net.Http.HttpClientHandler; $handler.UseProxy=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(10)
    function Invoke-Pumped($Task) {
        $deadline=(Get-Date).AddSeconds(8)
        while(-not $Task.IsCompleted -and (Get-Date) -lt $deadline){ Invoke-PanelPump $server $handlers; Start-Sleep -Milliseconds 10 }
        return $Task.GetAwaiter().GetResult()
    }
    $base='http://127.0.0.1:'+$server.Port
    $resp=Invoke-Pumped ($client.GetAsync($base+'/'))
    Assert ([int]$resp.StatusCode -eq 200) 'socket: page over loopback'
    $resp.Dispose()
    $resp=Invoke-Pumped ($client.GetAsync($base+'/api/status'))
    Assert ([int]$resp.StatusCode -eq 401) 'socket: API without token refused'
    $resp.Dispose()
    $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,($base+'/api/status'))
    [void]$message.Headers.TryAddWithoutValidation('X-Henu-Token',$server.Token)
    $resp=Invoke-Pumped ($client.SendAsync($message))
    $body=$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
    Assert ([int]$resp.StatusCode -eq 200 -and $body.title -eq '已联网') 'socket: status with token (UTF-8 intact)'
    $resp.Dispose()
    $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,($base+'/api/check'))
    [void]$message.Headers.TryAddWithoutValidation('X-Henu-Token',$server.Token)
    $message.Content=[Net.Http.StringContent]::new('{}',[Text.Encoding]::UTF8,'application/json')
    $resp=Invoke-Pumped ($client.SendAsync($message))
    Assert ([int]$resp.StatusCode -eq 200 -and $calls.check -eq 2) 'socket: JSON POST reaches handler'
    $resp.Dispose()
    $client.Dispose(); $idle.Close()
} finally { Stop-PanelServer $server }

Write-Output 'All panel tests passed.'
