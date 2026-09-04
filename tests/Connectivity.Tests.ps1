param([string]$SourcePath=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourcePath 'Common.ps1')
function Assert([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Output "PASS: $Name"
}
Add-Type -AssemblyName System.Net.Http
Add-Type -ReferencedAssemblies 'System.Net.Http','System' -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class ProbeFixtureHandler : HttpMessageHandler {
    public string Mode;
    public int Calls;
    public ProbeFixtureHandler(string mode) { Mode=mode; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Calls++;
        string host=request.RequestUri.Host;
        if (Mode == "timeout") {
            var pending=new TaskCompletionSource<HttpResponseMessage>();
            token.Register(() => pending.TrySetCanceled());
            return pending.Task;
        }
        if (Mode == "baidu-only" && host != "www.baidu.com" || Mode == "qq-only" && host != "www.qq.com" || Mode == "163-only" && host != "www.163.com") {
            var failed=new TaskCompletionSource<HttpResponseMessage>();
            failed.SetException(new HttpRequestException("simulated endpoint failure"));
            return failed.Task;
        }
        string content = (Mode == "baidu-only" || Mode == "qq-only" || Mode == "163-only") ? "User-agent: *\nDisallow: /private" :
            "<!doctype html><html><form>Campus login</form></html>";
        var response=new HttpResponseMessage(Mode == "redirect" ? HttpStatusCode.Found : HttpStatusCode.OK);
        response.Content=new StringContent(content);
        return Task.FromResult(response);
    }
}
'@
foreach ($mode in @('baidu-only','qq-only','163-only')) {
    $handler=[ProbeFixtureHandler]::new($mode)
    Assert (Test-Internet -TestHandler $handler) "one valid endpoint is sufficient: $mode"
    Assert ($handler.Calls -eq 3) "three endpoints started: $mode"
}
foreach ($mode in @('captive','redirect','timeout')) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Assert (-not (Test-Internet -TestHandler ([ProbeFixtureHandler]::new($mode)))) "reject $mode"
    Assert ($watch.Elapsed.TotalSeconds -lt 6) "bounded wait: $mode"
}
Assert (-not (Test-ProbeContent 'robots' 200 '<html>User-agent: * Disallow: /</html>')) 'reject HTML masquerading as robots'
Assert (-not (Test-ProbeContent 'robots' 200 'Login required')) 'reject portal HTTP 200'
Assert (-not (Test-ProbeContent 'robots' 503 "User-agent: *`nDisallow: /")) 'reject failed HTTP status'
$t=[DateTime]::UtcNow
$none=[DateTime]::MinValue
$d=Get-ConnectivityDecision $false 0 $none $t $none
Assert (-not $d.Recover) 'single failed round does not authenticate'
$d=Get-ConnectivityDecision $false $d.Failures $d.FirstFailure ($t.AddSeconds(5)) $none
Assert (-not $d.Recover) 'two failed rounds do not authenticate'
$early=Get-ConnectivityDecision $false $d.Failures $d.FirstFailure ($t.AddSeconds(10)) $none
Assert (-not $early.Recover) 'three rounds under 15 seconds do not authenticate'
$d=Get-ConnectivityDecision $false $d.Failures $d.FirstFailure ($t.AddSeconds(16)) $none
Assert $d.Recover 'sustained confirmed outage requests recovery'
$reset=Get-ConnectivityDecision $true $d.Failures $d.FirstFailure ($t.AddSeconds(17)) $none
Assert ($reset.Failures -eq 0 -and -not $reset.Recover) 'internet success clears outage streak'
$d=Get-ConnectivityDecision $false $reset.Failures $reset.FirstFailure ($t.AddSeconds(18)) $none
Assert (-not $d.Recover -and $d.Failures -eq 1) 'intermittent failure starts a new streak'
$d=Get-ConnectivityDecision $false 8 $t ($t.AddSeconds(60)) ($t.AddSeconds(120))
Assert (-not $d.Recover) 'cooldown blocks repeated authentication'
$d=Get-ConnectivityDecision $false 8 $t ($t.AddSeconds(121)) ($t.AddSeconds(120))
Assert $d.Recover 'persistent outage may retry after cooldown'
Assert ((Get-RecoveryDelay 1) -eq 120 -and (Get-RecoveryDelay 2) -eq 240 -and (Get-RecoveryDelay 10) -eq 300) 'bounded authentication backoff'

# Execute the shipped core with a fake shared module in an isolated directory.
# Never disconnect real Wi-Fi, read saved passwords, or open the real login page.
$testDir=Join-Path ([IO.Path]::GetTempPath()) ('henu-connectivity-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
Copy-Item -LiteralPath (Join-Path $SourcePath 'HenuAutoLogin.ps1') -Destination $testDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\Common.ps1') -Destination $testDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\BrowserLogin.ps1') -Destination $testDir
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    foreach ($case in @(
        @{name='online';args=@();code=0;login=$false},
        @{name='online';args=@('-ForceLogin');code=0;login=$false},
        @{name='offline';args=@('-ProbeOnly');code=10;login=$false},
        @{name='recovered';args=@('-RecoveryConfirmed');code=0;login=$false},
        @{name='offline';args=@('-RecoveryConfirmed');code=1;login=$true}
    )) {
        $env:HENU_TEST_CASE=$case.name
        $marker=Join-Path $testDir 'browser-called'
        if(Test-Path $marker){Remove-Item -LiteralPath $marker}
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $testDir 'HenuAutoLogin.ps1'))+$case.args
        & $ps @arguments
        Assert ($LASTEXITCODE -eq $case.code) ('core exit: '+$case.name+' '+($case.args -join ' '))
        Assert ((Test-Path $marker) -eq $case.login) ('browser guard: '+$case.name+' '+($case.args -join ' '))
    }
} finally {
    Remove-Item Env:\HENU_TEST_CASE -ErrorAction SilentlyContinue
    # Delete only this test's known generated files; do not recursively remove a broad path.
    foreach($name in @('Common.ps1','HenuAutoLogin.ps1','BrowserLogin.ps1','config.json','browser-called')) {
        $path=Join-Path $testDir $name
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    }
    Remove-Item -LiteralPath $testDir
}
Write-Output 'All connectivity regression tests passed.'
