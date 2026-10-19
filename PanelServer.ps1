# Local web control panel for the monitor (v2.5).
# - Listens on 127.0.0.1 only; never on a LAN address.
# - Non-blocking: Invoke-PanelPump is called from the WinForms timer, so the tray UI never waits on a socket.
# - Every /api/ call needs the per-launch random token (sent as X-Henu-Token). A custom header forces a
#   CORS preflight, which is always refused, so other websites cannot drive the panel.
# - The Host header must be our own loopback origin (DNS-rebinding guard).
$panelMaxHeaderBytes = 8192
$panelMaxBodyBytes = 4096
$panelMaxConnections = 16

function New-PanelToken {
    $bytes=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes|ForEach-Object { $_.ToString('x2') }) -join '')
}
function Test-PanelTokenEqual([string]$Supplied,[string]$Expected) {
    if([string]::IsNullOrEmpty($Supplied) -or [string]::IsNullOrEmpty($Expected) -or $Supplied.Length -ne $Expected.Length){return $false}
    $difference=0
    for($i=0;$i -lt $Expected.Length;$i++){ $difference=$difference -bor ([int][char]$Supplied[$i] -bxor [int][char]$Expected[$i]) }
    return ($difference -eq 0)
}
function Start-PanelServer([int[]]$PreferredPorts=@(18760,18761,18762)) {
    $listener=$null
    foreach($port in (@($PreferredPorts)+@(0))){
        $candidate=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
        try { $candidate.ExclusiveAddressUse=$true } catch {}
        try { $candidate.Start(); $listener=$candidate; break } catch { try{$candidate.Stop()}catch{} }
    }
    if(-not $listener){throw '无法在本机启动控制台端口。'}
    return [pscustomobject]@{
        Listener=$listener
        Port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
        Token=(New-PanelToken)
        Connections=(New-Object Collections.ArrayList)
    }
}
function Stop-PanelServer($Server) {
    if(-not $Server){return}
    foreach($connection in @($Server.Connections)){ try{$connection.Client.Close()}catch{}; try{$connection.Buffer.Dispose()}catch{} }
    $Server.Connections.Clear()
    try { $Server.Listener.Stop() } catch {}
}
function Get-PanelUrl($Server) { return ('http://127.0.0.1:{0}/#t={1}' -f $Server.Port,$Server.Token) }

function ConvertFrom-PanelRequestBytes([byte[]]$Bytes) {
    # Returns $null while the request is still incomplete; throws on malformed or oversized input.
    if(-not $Bytes){return $null}
    $limit=[Math]::Min($Bytes.Length,$panelMaxHeaderBytes)
    $headerEnd=-1
    for($i=3;$i -lt $limit;$i++){
        if($Bytes[$i-3] -eq 13 -and $Bytes[$i-2] -eq 10 -and $Bytes[$i-1] -eq 13 -and $Bytes[$i] -eq 10){$headerEnd=$i+1;break}
    }
    if($headerEnd -lt 0){
        if($Bytes.Length -ge $panelMaxHeaderBytes){throw 'header-too-large'}
        return $null
    }
    $head=[Text.Encoding]::ASCII.GetString($Bytes,0,$headerEnd-4)
    $lines=@($head -split "`r`n")
    if($lines[0] -cnotmatch '^(GET|POST|HEAD|OPTIONS|PUT|DELETE|PATCH) (/[!-~]*) HTTP/1\.[01]$'){throw 'bad-request-line'}
    $method=$Matches[1]; $target=$Matches[2]
    $headers=@{}
    foreach($line in @($lines|Select-Object -Skip 1)){
        if($line -notmatch '^([A-Za-z0-9-]+):[ \t]*(.*?)[ \t]*$'){throw 'bad-header'}
        $name=$Matches[1].ToLowerInvariant(); $value=$Matches[2]
        if($headers.ContainsKey($name)){
            if(@('host','content-length','content-type','origin','x-henu-token') -contains $name){throw 'duplicate-header'}
            $headers[$name]=$headers[$name]+', '+$value
        } else { $headers[$name]=$value }
    }
    if($headers.ContainsKey('transfer-encoding')){throw 'unsupported-transfer-encoding'}
    $length=0
    if($headers.ContainsKey('content-length')){
        if($headers['content-length'] -notmatch '^\d{1,6}$'){throw 'bad-content-length'}
        $length=[int]$headers['content-length']
        if($length -gt $panelMaxBodyBytes){throw 'body-too-large'}
    }
    if($Bytes.Length -lt ($headerEnd+$length)){return $null}
    $body=''
    if($length -gt 0){$body=[Text.Encoding]::UTF8.GetString($Bytes,$headerEnd,$length)}
    return [pscustomobject]@{Method=$method;Path=(($target -split '\?',2)[0]);Headers=$headers;Body=$body}
}

function Test-PanelRequestAllowed($Request,[int]$Port,[string]$Token) {
    # Returns 0 when allowed, otherwise the HTTP status to answer with.
    $allowedHosts=@("127.0.0.1:$Port","localhost:$Port")
    $hostHeader=([string]$Request.Headers['host']).ToLowerInvariant()
    if($allowedHosts -notcontains $hostHeader){return 421}
    if($Request.Method -eq 'OPTIONS'){return 405}
    $origin=([string]$Request.Headers['origin']).ToLowerInvariant()
    if($origin -and @("http://127.0.0.1:$Port","http://localhost:$Port") -notcontains $origin){return 403}
    $fetchSite=([string]$Request.Headers['sec-fetch-site']).ToLowerInvariant()
    if($fetchSite -and @('same-origin','none') -notcontains $fetchSite){return 403}
    if($Request.Path.StartsWith('/api/')){
        if(-not (Test-PanelTokenEqual ([string]$Request.Headers['x-henu-token']) $Token)){return 401}
        if($Request.Method -eq 'POST' -and ([string]$Request.Headers['content-type']) -notmatch '^application/json[ \t]*(;|$)'){return 415}
    }
    return 0
}

function New-PanelResponse([int]$Status,$Content,[string]$ContentType='application/json; charset=utf-8') {
    if($Content -is [byte[]]){$body=$Content}
    elseif($null -eq $Content){$body=New-Object byte[] 0}
    elseif($Content -is [string]){$body=[Text.Encoding]::UTF8.GetBytes($Content)}
    else{$body=[Text.Encoding]::UTF8.GetBytes(($Content|ConvertTo-Json -Depth 6 -Compress))}
    return [pscustomobject]@{Status=$Status;ContentType=$ContentType;Body=$body}
}
function Get-PanelStatusText([int]$Status) {
    $reasons=@{200='OK';204='No Content';400='Bad Request';401='Unauthorized';403='Forbidden';404='Not Found';405='Method Not Allowed';409='Conflict';415='Unsupported Media Type';421='Misdirected Request';500='Internal Server Error'}
    if($reasons.ContainsKey($Status)){return $reasons[$Status]}
    return 'Status'
}
function ConvertTo-PanelResponseBytes($Response) {
    $csp="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    $lines=@(
        ('HTTP/1.1 {0} {1}' -f $Response.Status,(Get-PanelStatusText $Response.Status)),
        ('Content-Type: '+$Response.ContentType),
        ('Content-Length: '+$Response.Body.Length),
        'Cache-Control: no-store',
        'X-Content-Type-Options: nosniff',
        'X-Frame-Options: DENY',
        'Referrer-Policy: no-referrer',
        'Cross-Origin-Resource-Policy: same-origin',
        'Cross-Origin-Opener-Policy: same-origin',
        ('Content-Security-Policy: '+$csp),
        'Connection: close'
    )
    $head=[Text.Encoding]::ASCII.GetBytes(($lines -join "`r`n")+"`r`n`r`n")
    $all=New-Object byte[] ($head.Length+$Response.Body.Length)
    [Array]::Copy($head,0,$all,0,$head.Length)
    [Array]::Copy($Response.Body,0,$all,$head.Length,$Response.Body.Length)
    return ,$all
}

function ConvertFrom-PanelJsonBody([string]$Body) {
    if([string]::IsNullOrWhiteSpace($Body)){return [pscustomobject]@{}}
    try { $value=$Body|ConvertFrom-Json } catch { throw '请求格式错误。' }
    if($value -isnot [Management.Automation.PSCustomObject]){throw '请求格式错误。'}
    foreach($name in @('username','password','operator')){
        $field=$value.PSObject.Properties[$name]
        if($field -and $null -ne $field.Value -and $field.Value -isnot [string]){throw '请求格式错误。'}
    }
    return $value
}
function Invoke-PanelRequest($Request,[int]$Port,[string]$Token,[hashtable]$Handlers) {
    # Handlers: Page, Status, SaveConfig(username,password,operator), Login, Check — all scriptblocks.
    $denied=Test-PanelRequestAllowed $Request $Port $Token
    if($denied -ne 0){return (New-PanelResponse $denied @{error='请求被拒绝。';code=$denied})}
    try {
        switch -Exact ($Request.Method+' '+$Request.Path) {
            'GET /'            { return (New-PanelResponse 200 (& $Handlers.Page) 'text/html; charset=utf-8') }
            'GET /favicon.ico' { return (New-PanelResponse 204 $null 'image/x-icon') }
            'GET /api/status'  { return (New-PanelResponse 200 (& $Handlers.Status)) }
            'POST /api/config' {
                $payload=ConvertFrom-PanelJsonBody $Request.Body
                $summary=& $Handlers.SaveConfig ([string]$payload.username) ([string]$payload.password) ([string]$payload.operator)
                return (New-PanelResponse 200 @{ok=$true;config=$summary})
            }
            'POST /api/login'  {
                $payload=ConvertFrom-PanelJsonBody $Request.Body
                if(-not [string]::IsNullOrWhiteSpace([string]$payload.username)){
                    [void](& $Handlers.SaveConfig ([string]$payload.username) ([string]$payload.password) ([string]$payload.operator))
                }
                $result=& $Handlers.Login
                $status=if($result.accepted){200}else{409}
                return (New-PanelResponse $status $result)
            }
            'POST /api/check'  { return (New-PanelResponse 200 (& $Handlers.Check)) }
        }
        if(@('GET','POST') -notcontains $Request.Method){return (New-PanelResponse 405 @{error='不支持的请求方法。'})}
        return (New-PanelResponse 404 @{error='未找到。'})
    } catch {
        # Validation messages are user-facing Chinese text; never echo request bodies.
        return (New-PanelResponse 400 @{error=[string]$_.Exception.Message})
    }
}

function Invoke-PanelPump($Server,[hashtable]$Handlers,[int]$MaxAccept=8) {
    if(-not $Server){return}
    $now=[DateTime]::UtcNow
    $accepted=0
    while($accepted -lt $MaxAccept -and $Server.Listener.Pending()){
        $client=$Server.Listener.AcceptTcpClient(); $accepted++
        if($Server.Connections.Count -ge $panelMaxConnections){$client.Close();continue}
        $client.NoDelay=$true
        $client.SendTimeout=2000
        [void]$Server.Connections.Add([pscustomobject]@{Client=$client;Buffer=(New-Object IO.MemoryStream);Accepted=$now})
    }
    for($index=$Server.Connections.Count-1;$index -ge 0;$index--){
        $connection=$Server.Connections[$index]
        $finished=$false
        try {
            $stream=$connection.Client.GetStream()
            # Read only bytes already received: browsers keep idle pre-connections open and we must never block.
            while($connection.Client.Available -gt 0 -and $connection.Buffer.Length -le ($panelMaxHeaderBytes+$panelMaxBodyBytes)){
                $chunk=New-Object byte[] ([Math]::Min(4096,$connection.Client.Available))
                $read=$stream.Read($chunk,0,$chunk.Length)
                if($read -le 0){break}
                $connection.Buffer.Write($chunk,0,$read)
            }
            $response=$null
            if($connection.Buffer.Length -gt 0){
                try {
                    $request=ConvertFrom-PanelRequestBytes $connection.Buffer.ToArray()
                    if($request){$response=Invoke-PanelRequest $request $Server.Port $Server.Token $Handlers}
                } catch { $response=New-PanelResponse 400 @{error='请求格式错误。'} }
            }
            if($response){
                $bytes=ConvertTo-PanelResponseBytes $response
                $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
                $finished=$true
            } elseif(($now-$connection.Accepted).TotalSeconds -gt 10){ $finished=$true }
        } catch { $finished=$true }
        if($finished){
            try{$connection.Client.Close()}catch{}
            try{$connection.Buffer.Dispose()}catch{}
            $Server.Connections.RemoveAt($index)
        }
    }
}
