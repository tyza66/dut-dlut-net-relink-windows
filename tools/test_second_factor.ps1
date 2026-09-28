# Offline regression test for the CAS second-factor path.
#
# The recheck page comes from refs/, and the HTTP layer is shadowed inside the
# CasAuth module, so the suite never opens a socket, never sends an SMS, and never
# writes into the real app folder.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\CasAuth.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'lib\CasSession.psm1') -Force -DisableNameChecking

$fail = 0
function Check($Name, $Ok, $Info) {
    if (-not $Ok) { $script:fail++ }
    Write-Host ('{0,-28} {1}  {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Info)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dutmfa-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force
$sessionPath = Join-Path $tmp 'session.json'

$mfaHtml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'refs\cas_mfa_page.html')
$cleanHtml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'refs\cas_login_page.html')
$rejectHtml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'refs\cas_reject_page.html')
$global:DZMfaHtml = $mfaHtml

try {
    # ---------------------------------------------------------------- page parsing
    $info = Get-DlutSecondFactorInfo -Html $mfaHtml -BaseUrl 'https://sso.dlut.edu.cn'
    Check 'RecheckPageDetected' ($info.Required) ('Required=' + $info.Required)
    Check 'RecheckActionUrl' ($info.ActionUrl -like 'https://sso.dlut.edu.cn/cas/login?service=*') $info.ActionUrl
    Check 'RecheckCaptchaUrl' ($info.CaptchaUrl -like '*/cas/code') $info.CaptchaUrl
    Check 'RecheckExecution' ($info.Execution -eq 'e1s2') $info.Execution
    Check 'RecheckRelayState' ($info.RelayState -eq 'e1s2') $info.RelayState
    Check 'RecheckSmsEndpoint' ($info.SmsUrl -eq 'recheckcode') $info.SmsUrl
    Check 'RecheckPhoneHint' ($info.PhoneHint -eq '尾号 1234 的手机') $info.PhoneHint
    Check 'RecheckNotice' ($info.Notice -like '系统检测到需要二次认证*') $info.Notice

    Check 'LoginPageNotRecheck' (-not (Get-DlutSecondFactorInfo -Html $cleanHtml -BaseUrl 'https://sso.dlut.edu.cn').Required) 'first factor'
    Check 'RejectPageNotRecheck' (-not (Get-DlutSecondFactorInfo -Html $rejectHtml -BaseUrl 'https://sso.dlut.edu.cn').Required) 'wrong password'
    Check 'EmptyPageNotRecheck' (-not (Get-DlutSecondFactorInfo -Html '').Required) 'empty'
    $relative = Get-DlutSecondFactorInfo -Html $mfaHtml
    Check 'RecheckRelativeUrls' ($relative.ActionUrl -like '/cas/login?*') $relative.ActionUrl

    # ------------------------------------------------------------------ error text
    # The recheck page is itself a form, so the SMS-failure marker has to be checked
    # before the generic login-form branch, otherwise a wrong SMS code is reported
    # as if the first factor had failed.
    Check 'RecheckPageIsSmsError' ((Get-CasLoginError $mfaHtml) -eq 'CAS rejected the second factor code') (Get-CasLoginError $mfaHtml)
    Check 'RecheckNotCaptcha' ((Get-CasLoginError $mfaHtml) -notlike 'CAS wants a captcha*') 'no false captcha'
    Check 'RejectPageQuoted' ((Get-CasLoginError $rejectHtml) -eq 'CAS says: Incorrect username and password') (Get-CasLoginError $rejectHtml)
    # CAS puts its rejection into the span when it has one, exactly as with the
    # first factor, so the reason is still quoted verbatim.
    $smsReject = '<html><body><span id="errormsghide">动态验证码错误</span><input name="PM1"></body></html>'
    Check 'SmsErrorSpanQuoted' ((Get-CasLoginError $smsReject) -eq 'CAS says: 动态验证码错误') (Get-CasLoginError $smsReject)

    # Without an error span the recheck page itself is the whole reason: say that,
    # and never fall through to the generic login-form wording.
    $smsPlain = '<html><body id="loginForm"><input type="text" id="PM1" name="PM1" placeholder="动态验证码"></body></html>'
    Check 'SmsRejectNamed' ((Get-CasLoginError $smsPlain) -eq 'CAS rejected the second factor code') (Get-CasLoginError $smsPlain)

    Check 'HtmlLineBreakIsSpace' ((Remove-CasHtmlTags 'Incorrect username and password<br/>') -eq 'Incorrect username and password') (Remove-CasHtmlTags 'Incorrect username and password<br/>')
    Check 'HtmlEntitiesDecoded' ((Remove-CasHtmlTags 'a&amp;b<br/>c') -eq 'a&b c') (Remove-CasHtmlTags 'a&amp;b<br/>c')

    # ---------------------------------------------------------------- prompt shapes
    $fromHash = Get-CasAnswerValue @{ ImageCode = ' abc '; SmsCode = $null } 'ImageCode'
    Check 'AnswerFromHashtable' ($fromHash -eq 'abc') $fromHash
    Check 'AnswerMissingKey' ((Get-CasAnswerValue @{ ImageCode = 'abc' } 'SmsCode') -eq '') 'empty'
    Check 'AnswerFromObject' ((Get-CasAnswerValue ([pscustomobject]@{ SmsCode = '654321' }) 'SmsCode') -eq '654321') '654321'
    Check 'AnswerFromNull' ((Get-CasAnswerValue $null 'ImageCode') -eq '') 'null'

    # ------------------------------------------------------------------ captcha bits
    Check 'CaptchaGuardEmptyBytes' ((Save-CasCaptchaImage -Bytes @() -Path (Join-Path $tmp 'x.png')) -eq '') 'no bytes'
    Check 'CaptchaGuardNoPath' ((Save-CasCaptchaImage -Bytes ([byte[]](1..16)) -Path '') -eq '') 'no path'
    Check 'AsciiGuardMissingFile' ((ConvertTo-CaptchaAscii (Join-Path $tmp 'nope.png')) -eq '') 'missing file'

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $pngPath = Join-Path $tmp 'fake.png'
    $bitmap = $null
    try { $bitmap = New-Object System.Drawing.Bitmap(32, 16) } catch { }
    if ($bitmap) {
        try {
            $null = $bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $saved = Save-CasCaptchaImage -Bytes ([System.IO.File]::ReadAllBytes($pngPath)) -Path (Join-Path $tmp 'sub\captcha.png')
            Check 'CaptchaSaved' ($saved -like '*captcha.png' -and (Test-Path -LiteralPath $saved)) $saved
            $art = ConvertTo-CaptchaAscii $pngPath
            Check 'CaptchaAsciiDrawn' (($art -split [Environment]::NewLine).Count -ge 3) (($art -split [Environment]::NewLine).Count)
        } catch {
            Check 'CaptchaRoundTrip' $false $_.Exception.Message
        } finally {
            $null = $bitmap.Dispose()
        }
    } else {
        Write-Host 'SKIP   captcha drawing (System.Drawing unavailable)'
    }

    # ---------------------------------------------------------------- SMS guard rails
    # CAS answers recheckcode with a cookie, so a missing image code must fail before
    # any request is made.
    Check 'SmsNeedsImageCode' (-not (Send-DlutSmsCode @{} '' '').Success) (Send-DlutSmsCode @{} '' '').Message

    # --------------------------------------------------------------- shadowed HTTP
    # Everything below runs with the network replaced by a scriptblock, so the
    # recheck page is served back over and over until the codes are right.
    $global:DZState = @{ Posts = 0; TicketAfter = 2; AlwaysRecheck = $false }
    $global:DZPrompts = @()
    $mockRequest = {
        param($Session, $Url, $Method, $Content)
        $state = $global:DZState
        if ($Method -eq 'POST') {
            $state.Posts++
            $satisfied = if ($state.AlwaysRecheck) { $false } else { $state.Posts -ge $state.TicketAfter }
            if ($satisfied) {
                return [pscustomobject]@{
                    Status = 302; Location = '/cas/serviceValidate?ticket=ST-42'
                    Url = $Url;  Body = ''
                }
            }
            return [pscustomobject]@{ Status = 200; Location = ''; Url = $Url; Body = $global:DZMfaHtml }
        }
        if ($Url -like '*/cas/code*') {
            return [pscustomobject]@{ Status = 200; Location = ''; Url = $Url; Body = ''; Bytes = [byte[]](1..16) }
        }
        return [pscustomobject]@{ Status = 200; Location = ''; Url = $Url; Body = 'redeemed' }
    }

    $prompt = {
        param($PromptInfo)
        $global:DZPrompts += $PromptInfo
        if ($PromptInfo.Round -ge 2) { return @{ ImageCode = 'abcde'; SmsCode = '654321' } }
        return @{ ImageCode = 'abcde'; SmsCode = '111111' }
    }

    $session = @{ Handler = @{ CookieContainer = (New-Object 'System.Net.CookieContainer') }; Client = $null }
    # These two are what the watchdog stores and replays, so they have to be in the
    # jar for the round trip below to observe them.
    $null = $session.Handler.CookieContainer.Add((New-Object System.Net.Cookie('CASTGC', 'TGT-42-abcdef', '/cas', 'sso.dlut.edu.cn')))
    $null = $session.Handler.CookieContainer.Add((New-Object System.Net.Cookie('PHPSESSID', 'p1', '/Self', '172.20.30.2')))
    $page = [pscustomobject]@{ Url = 'https://sso.dlut.edu.cn/cas/login?service=http%3A%2F%2F172.20.30.2%3A8080%2FSelf%2Fsso_login'; Status = 200; Body = $mfaHtml }

    # A function defined inside & (Get-Module ...) lives only for that one invocation,
    # so the HTTP mock and the call under test have to sit in the same block.
    function Invoke-DzFlow {
        param($Prompt, $SessionPath)
        return (& (Get-Module CasAuth) {
            param($Session, $Page, $Info, $Prompt, $SessionPath)
            function Send-CasRequest { param($S, $U, $M, $C) return (& $global:DZRequest $S $U $M $C) }
            function Send-CasRequestBytes { param($S, $U, $M, $C) return (& $global:DZRequest $S $U $M $C) }
            function Get-CasWorkDir { return $global:DZWorkDir }
            return (Invoke-DlutSecondFactorLogin -Session $Session -Page $Page -Info $Info -PromptSecondFactor $Prompt -SessionPath $SessionPath)
        } $session $page $info $Prompt $SessionPath)
    }

    function Invoke-DzSms {
        param($RequestSession)
        return (& (Get-Module CasAuth) {
            param($RequestSession)
            function Send-CasRequest { param($S, $U, $M, $C) return (& $global:DZRequest $S $U $M $C) }
            return (Send-DlutSmsCode -Session $RequestSession -CaptchaCode 'abcde' -BaseUrl 'https://sso.dlut.edu.cn/cas/login?service=x')
        } $RequestSession)
    }

    $global:DZRequest = $mockRequest
    $global:DZWorkDir = $tmp

    # Wrong SMS code once, then the right one: the flow should carry on and store the
    # session the watchdog will reuse.
    $global:DZState.Posts = 0
    $global:DZState.AlwaysRecheck = $false
    $global:DZState.TicketAfter = 2
    $global:DZPrompts = @()
    $result = Invoke-DzFlow $prompt $sessionPath
    Check 'SecondFactorSucceeds' ($result.Success) $result.Message
    Check 'SessionStored' ($result.SessionSaved -and (Test-Path -LiteralPath $sessionPath)) ('SessionSaved=' + $result.SessionSaved)
    Check 'PromptAskedTwice' ($global:DZPrompts.Count -eq 2) $global:DZPrompts.Count

    $second = @($global:DZPrompts)[1]
    Check 'RetryRoundNumbered' ($second.Round -eq 2) $second.Round
    Check 'RetryCarriesLastError' ($second.LastError -eq 'CAS rejected the second factor code') $second.LastError
    Check 'RetryCarriesPhoneHint' ($second.PhoneHint -eq '尾号 1234 的手机') $second.PhoneHint
    Check 'RetryOffersSmsButton' ($null -ne $second.SendSms) 'SendSms scriptblock present'
    # The button the prompt offers goes through the same mock: CAS reports the result
    # in a cookie, so seed the one it would set on success.
    $null = $session.Handler.CookieContainer.Add((New-Object System.Net.Cookie('recheck_mobile_error_info', 'success', '/cas', 'sso.dlut.edu.cn')))
    $viaPrompt = & (Get-Module CasAuth) {
        param($Provide)
        function Send-CasRequest { param($S, $U, $M, $C) return (& $global:DZRequest $S $U $M $C) }
        return (& $Provide 'abcde')
    } $second.SendSms
    Check 'PromptSendsSms' ($viaPrompt.Code -eq 'success') $viaPrompt.Message

    $saved = Get-DlutSession -Path $sessionPath
    Check 'StoredSessionReadable' ($null -ne $saved -and $saved.Cookies.Count -eq 2) ('cookies ' + @($saved.Cookies).Count)

    # A cancelled prompt must stop the login cleanly.
    $global:DZState.Posts = 0
    $global:DZPrompts = @()
    $cancelled = Invoke-DzFlow { param($P) return $null } $sessionPath
    Check 'CancelIsClean' (-not $cancelled.Success -and $cancelled.Message -eq 'the second factor was cancelled') $cancelled.Message

    # CAS refusing every attempt has to give up instead of looping forever.
    $global:DZState.AlwaysRecheck = $true
    $global:DZPrompts = @()
    $exhausted = Invoke-DzFlow $prompt $sessionPath
    Check 'GivesUpAfterFourRounds' ($exhausted.Message -like 'CAS kept refusing*' -and $global:DZState.Posts -eq 4) ('posts ' + $global:DZState.Posts + ': ' + $exhausted.Message)
    $global:DZState.AlwaysRecheck = $false

    # The SMS request result really is read out of the cookie CAS sets.
    $container = New-Object 'System.Net.CookieContainer'
    $null = $container.Add((New-Object System.Net.Cookie('recheck_mobile_error_info', 'success', '/cas', 'sso.dlut.edu.cn')))
    $smsSession = @{ Handler = @{ CookieContainer = $container }; Client = $null }
    $sent = Invoke-DzSms $smsSession
    Check 'SmsCookieReported' ($sent.Success -and $sent.Code -eq 'success') $sent.Message
    $null = $container.Add((New-Object System.Net.Cookie('recheck_mobile_error_info', 'img_code_error', '/cas', 'sso.dlut.edu.cn')))
    $denied = Invoke-DzSms $smsSession
    Check 'SmsErrorMessage' (-not $denied.Success -and $denied.Message -eq 'the image code was wrong') $denied.Message

    # ------------------------------------------------------------- trust device page
    # After a correct SMS code CAS sometimes shows the "trust this device" page once
    # more before it issues the ticket. It is recognised by the hidden
    # check_user_device field plus the visible wording.
    $trustHtml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'refs\cas_trust_device_page.html')
    $trust = Get-DlutTrustDeviceInfo -Html $trustHtml -BaseUrl 'https://sso.dlut.edu.cn'
    Check 'TrustPageDetected' ($trust.Required) ('Required=' + $trust.Required)
    Check 'TrustPageActionUrl' ($trust.ActionUrl -like 'https://sso.dlut.edu.cn/cas/login?service=*') $trust.ActionUrl
    Check 'TrustPageExecution' ($trust.Execution -eq 'e5s9') $trust.Execution
    Check 'TrustPageRelayState' ($trust.RelayState -eq 'e5s9') $trust.RelayState

    Check 'TrustNotOnMfa' (-not (Get-DlutTrustDeviceInfo -Html $mfaHtml -BaseUrl 'https://sso.dlut.edu.cn').Required) 'mfa page'
    Check 'TrustNotOnLogin' (-not (Get-DlutTrustDeviceInfo -Html $cleanHtml -BaseUrl 'https://sso.dlut.edu.cn').Required) 'login page'
    Check 'TrustNotOnEmpty' (-not (Get-DlutTrustDeviceInfo -Html '').Required) 'empty'
    # The wording alone is not enough; the marker field has to be there too.
    Check 'TrustNeedsMarker' (-not (Get-DlutTrustDeviceInfo -Html '<html>信任设备</html>' -BaseUrl 'https://sso.dlut.edu.cn').Required) 'no marker'

    # The confirm POST has to carry check_user_device=true plus the page's own
    # execution and RelayState.
    $trustBody = & (Get-Module CasAuth) {
        param($Info)
        function Send-CasRequest { param($S, $U, $M, $C) $global:DZTrustBody = $C; return [pscustomobject]@{ Status = 200; Location = ''; Url = $U; Body = '' } }
        $null = Submit-DlutTrustDevice -Session @{} -PostUrl 'https://sso.dlut.edu.cn/cas/login?service=x' -Info $Info -TrustDevice $true
        return $global:DZTrustBody
    } $trust
    Check 'TrustSubmitMarker' ($trustBody -match 'check_user_device=true') $trustBody
    Check 'TrustSubmitExecution' ($trustBody -match 'execution=e5s9') $trustBody
    Check 'TrustSubmitRelayState' ($trustBody -match 'RelayState=e5s9') $trustBody
    Check 'TrustSubmitEvent' ($trustBody -match '_eventId=submit') $trustBody

    # ----------------------------------------------------------- trust device in flow
    # The SMS POST comes back as the trust page, then the confirm POST finally yields
    # the ticket. The flow has to follow that detour and still store the session the
    # watchdog will reuse.
    $global:DZTrustPosts = 0
    $global:DZTrustHtml = $trustHtml
    $global:DZTrustRequest = {
        param($Session, $Url, $Method, $Content)
        if ($Method -eq 'POST') {
            $global:DZTrustPosts++
            if ($global:DZTrustPosts -eq 1) {
                return [pscustomobject]@{ Status = 200; Location = ''; Url = $Url; Body = $global:DZTrustHtml }
            }
            return [pscustomobject]@{ Status = 302; Location = '/cas/serviceValidate?ticket=ST-77'; Url = $Url; Body = '' }
        }
        if ($Url -like '*/cas/code*') {
            return [pscustomobject]@{ Status = 200; Location = ''; Url = $Url; Body = ''; Bytes = [byte[]](1..16) }
        }
        return [pscustomobject]@{ Status = 200; Location = ''; Url = $Url; Body = 'redeemed' }
    }
    $trustSessionPath = Join-Path $tmp 'trust-session.json'
    $trustSession = @{ Handler = @{ CookieContainer = (New-Object 'System.Net.CookieContainer') }; Client = $null }
    $null = $trustSession.Handler.CookieContainer.Add((New-Object System.Net.Cookie('CASTGC', 'TGT-77', '/cas', 'sso.dlut.edu.cn')))
    $trustPage = [pscustomobject]@{ Url = 'https://sso.dlut.edu.cn/cas/login?service=x'; Status = 200; Body = $mfaHtml }
    $trustResult = (& (Get-Module CasAuth) {
        param($Session, $Page, $Info, $Prompt, $SessionPath)
        function Send-CasRequest { param($S, $U, $M, $C) return (& $global:DZTrustRequest $S $U $M $C) }
        function Send-CasRequestBytes { param($S, $U, $M, $C) return (& $global:DZTrustRequest $S $U $M $C) }
        function Get-CasWorkDir { return $global:DZWorkDir }
        return (Invoke-DlutSecondFactorLogin -Session $Session -Page $Page -Info $Info -PromptSecondFactor $Prompt -SessionPath $SessionPath)
    } $trustSession $trustPage $info $prompt $trustSessionPath)
    Check 'TrustFlowSucceeds' ($trustResult.Success) $trustResult.Message
    Check 'TrustFlowPosts' ($global:DZTrustPosts -eq 2) ('posts ' + $global:DZTrustPosts)
    Check 'TrustFlowSessionStored' ($trustResult.SessionSaved -and (Test-Path -LiteralPath $trustSessionPath)) ('SessionSaved=' + $trustResult.SessionSaved)
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name DZMfaHtml -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZState -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZPrompts -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZRequest -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZWorkDir -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZTrustBody -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZTrustHtml -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZTrustRequest -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name DZTrustPosts -Scope Global -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host ('second factor: ' + $fail + ' check(s) failed')
    exit 1
}
Write-Host 'second factor: all checks passed'
exit 0
