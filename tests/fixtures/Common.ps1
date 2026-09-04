$configPath=Join-Path $PSScriptRoot 'config.json'
'{"ssid":"henu-student"}' | Set-Content -LiteralPath $configPath
$script:checks=0
function Test-Internet {
    $script:checks++
    if($env:HENU_TEST_CASE -eq 'online'){return $true}
    if($env:HENU_TEST_CASE -eq 'recovered' -and $script:checks -ge 2){return $true}
    return $false
}
function Write-State($Phase,$Message) {}
function Write-Log($Message) {}
function Get-CurrentSsid { return 'henu-student' }
function Test-SsidVisible { throw 'Unexpected Wi-Fi scan' }
function Get-WlanAdapter { throw 'Unexpected network switch' }
