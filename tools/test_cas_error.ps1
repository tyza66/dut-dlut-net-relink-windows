# Offline regression test for the CAS error extraction. Uses the pages captured in
# refs/, so it never invents a reason and never touches the network.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\CasAuth.psm1') -Force -DisableNameChecking

$fail = 0
function Check($Name, $Ok, $Info) {
    if (-not $Ok) { $script:fail++ }
    Write-Host ('{0,-26} {1}  {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Info)
}

$reject = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'refs\cas_reject_page.html')
$clean = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'refs\cas_login_page.html')

$rejectMessage = Get-CasLoginError $reject
Check 'RejectPageQuotesServer' ($rejectMessage -eq 'CAS says: Incorrect username and password') $rejectMessage

$cleanMessage = Get-CasLoginError $clean
Check 'CleanPageNoFalseCaptcha' ($cleanMessage -notlike '*captcha*') $cleanMessage
Check 'CleanPageIsRefusal' ($cleanMessage -like 'CAS refused*') $cleanMessage

Check 'EmptyIsReported' ((Get-CasLoginError '') -eq 'empty response') 'empty response'

$captchaInput = '<html><body><form><input type="text" name="captcha" value=""></form></body></html>'
Check 'CaptchaInputDetected' ((Get-CasLoginError $captchaInput) -like 'CAS wants a captcha*') (Get-CasLoginError $captchaInput)

$scriptOnly = '<html><head><script src="/cas/comm/plugin/captcha/jquery.captcha.js"></script></head><body></body></html>'
$scriptOnlyMessage = Get-CasLoginError $scriptOnly
Check 'ScriptIncludeIsNotCaptcha' ($scriptOnlyMessage -notlike '*captcha*') $scriptOnlyMessage

Check 'TitleFallback' ((Get-CasLoginError '<html><title>Some other page</title></html>') -like 'unexpected page: Some other page*') 'title'

if ($fail -gt 0) { exit 1 }
exit 0
