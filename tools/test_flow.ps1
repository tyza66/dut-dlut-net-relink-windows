# Exercises the pieces of the login flow that need no credentials:
# adapter IP discovery, online detection, portal challenge and CAS form parsing.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\CasAuth.psm1') -Force -DisableNameChecking

$fail = 0
function Check($Name, $Ok, $Info) {
    if (-not $Ok) { $script:fail++ }
    Write-Host ('{0,-22} {1}  {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Info)
}

$ip = Get-PrimaryIPv4
Check 'PrimaryIPv4' ([bool]$ip -and $ip -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') $ip

$online = Test-InternetOnline
Write-Host ('{0,-22} {1}  ' -f 'InternetOnline', $online)

$url = Get-DlutPortalChallengeUrl $ip
Check 'ChallengeUrl' ($url -like 'http://172.20.30.2:8080/Self/sso_login*wlan_user_ip=' + $ip + '*') $url

$session = New-CasHttpSession 30
try {
    $challenge = Send-CasRequest $session $url 'GET'
    $ok = ($challenge.Status -eq 302 -and $challenge.Location -like 'https://sso.dlut.edu.cn/cas/login*')
    Check 'PortalChallenge' $ok ('HTTP ' + $challenge.Status + ' -> ' + $challenge.Location)

    $casUrl = Resolve-CasRedirect $challenge.Location $url
    $page = Send-CasRequest $session $casUrl 'GET'
    Check 'CasLoginPage' ($page.Status -eq 200 -and $page.Body -match 'loginForm') ('HTTP ' + $page.Status)

    $form = Get-CasLoginFormInfo $page.Body
    Check 'CasFormFields' ($form.Lt -like 'LT-*' -and $form.Execution) ('lt=' + $form.Lt)

    $postUrl = if ($form.Action) { Resolve-CasRedirect $form.Action $casUrl } else { $casUrl }
    Check 'CasPostUrl' ($postUrl -like 'https://sso.dlut.edu.cn/cas/login*') $postUrl

    # An empty credential POST must fail without a ticket, proving the form round-trips.
    $fields = 'rsa=X&ul=1&pl=1&sl=0&lt=' + [uri]::EscapeDataString($form.Lt) + '&execution=' + [uri]::EscapeDataString($form.Execution) + '&_eventId=submit'
    $reject = Send-CasRequest $session $postUrl 'POST' $fields
    $noTicket = -not ($reject.Location -match '[?&]ticket=')
    Check 'BadCredentialsRejected' $noTicket ('HTTP ' + $reject.Status)
} finally {
    Close-CasHttpSession $session
}

if ($fail -gt 0) { exit 1 }
exit 0
