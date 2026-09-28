<#
.SYNOPSIS
    Keeps a DLUT graduate workstation authenticated on the campus network.
.DESCRIPTION
    Watches internet reachability and re-runs the Dr.COM + CAS SSO login whenever it
    drops. Meant to be launched by a scheduled task (see install.ps1) so it stays
    resident with no visible console window.
.EXAMPLE
    DutNetRelink.ps1 -Status
    DutNetRelink.ps1 -Once
    DutNetRelink.ps1 -Login
    DutNetRelink.ps1 -CasLogin
    DutNetRelink.ps1 -ClearSession
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Login,
    [switch]$CasLogin,
    [switch]$ClearSession,
    [switch]$Status,
    [switch]$Configure,
    [int]$Interval = 0,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $script:RepoRoot 'lib'
Import-Module (Join-Path $libPath 'CasDes.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'CasAuth.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'ConfigStore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'CasSession.psm1') -Force -DisableNameChecking

if ($ConfigPath) { $script:ConfigFile = $ConfigPath } else { $script:ConfigFile = Get-DlutConfigPath }
$script:LogDir = Join-Path (Split-Path -Parent $script:ConfigFile) 'logs'
$script:SessionPath = Get-DlutSessionPath

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Show-Status {
    $config = Read-DlutConfig $script:ConfigFile
    $ip = Get-PrimaryIPv4 $config.InterfaceName
    $online = Test-InternetOnline
    Write-Host ('config          : ' + $script:ConfigFile)
    Write-Host ('username        : ' + $(if ($config.Username) { $config.Username } else { '(not set)' }))
    Write-Host ('password        : ' + $(if ($config.PasswordProtected) { 'stored (DPAPI ' + $config.CredentialScope + ')' } else { '(not set)' }))
    if ($config.PasswordProtected) {
        $cred = Test-DlutCredential $config
        Write-Host ('credentials     : ' + $(if ($cred.Ok) { 'decryptable for this identity' } else { 'NOT decryptable - ' + $cred.Error }))
    }
    Write-Host ('interval        : ' + $config.IntervalSeconds + ' s')
    Write-Host ('interface       : ' + $(if ($config.InterfaceName) { $config.InterfaceName } else { '(auto)' }))
    Write-Host ('CAS session     : ' + (Get-DlutSessionSummary -Path $script:SessionPath -Scope $config.CredentialScope))
    Write-Host ('active IPv4     : ' + $(if ($ip) { $ip } else { '(none found)' }))
    Write-Host ('internet        : ' + $(if ($online) { 'online' } else { 'offline' }))
    $runEntry = $null
    try { $runEntry = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DutNetRelink' -ErrorAction SilentlyContinue).'DutNetRelink' } catch { }
    $task = Get-ScheduledTask -TaskName 'DutNetRelink' -ErrorAction SilentlyContinue
    $boot = if ($task) { ('scheduled task, ' + $task.State) } elseif ($runEntry) { 'HKCU Run entry (no restart on crash)' } else { '(not installed)' }
    Write-Host ('boot persistence: ' + $boot)
    if (Test-Path $script:LogFile) {
        Write-Host '--- last log lines ---'
        Get-Content $script:LogFile -Tail 12 | ForEach-Object { Write-Host $_ }
    }
    if (-not $config.Username -or -not $config.PasswordProtected) { return 2 }
    return 0
}

function Invoke-RelinkCycle {
    param(
        [object]$Config,
        [string]$Ip,
        [int]$Attempts,
        [object[]]$SessionCookies = $null,
        [scriptblock]$PromptSecondFactor = $null
    )
    # The short path: reuse the CAS session saved by the last successful -CasLogin so
    # CAS hands over a ticket without ever asking for a second factor again.
    $cookies = if ($SessionCookies) { $SessionCookies } else { @() }
    if ($cookies.Count -eq 0) {
        $stored = Get-DlutSession -Path $script:SessionPath -Scope $Config.CredentialScope
        if ($stored) { $cookies = $stored.Cookies }
    }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $ip = if ($Ip) { $Ip } else { Get-PrimaryIPv4 $Config.InterfaceName }
        if (-not $ip) { return @{ Success = $false; Message = 'no IPv4 address on any adapter' } }
        if ($attempt -gt 1) { Start-Sleep -Seconds 5 }
        $loginParams = @{
            Username = $Config.Username
            Password = (Unprotect-DlutPassword $Config)
            IPv4     = $ip
        }
        if ($cookies.Count -gt 0) { $loginParams['SessionCookies'] = $cookies }
        if ($PromptSecondFactor) {
            $loginParams['AllowSecondFactor'] = $true
            $loginParams['PromptSecondFactor'] = $PromptSecondFactor
        }
        $result = Invoke-DlutCampusLogin @loginParams
        if ($result.MfaRequired) {
            return @{
                Success     = $false
                MfaRequired = $true
                Message     = 'CAS is asking for the SMS second factor'
            }
        }
        if (-not $result.Success) {
            Write-Log ('relink ' + $attempt + '/' + $Attempts + ' failed: ' + $result.Message) 'WARN'
            continue
        }
        Start-Sleep -Seconds 3
        if (Test-InternetOnline) { return @{ Success = $true; Message = 'online again' } }
        Write-Log 'login accepted but the internet is still unreachable' 'WARN'
    }
    return @{ Success = $false; Message = 'all attempts exhausted' }
}

function Set-ConsoleUtf8 {
    <# Chinese prompts need a UTF-8 console; leave it alone when it is redirected. #>
    try { if ([Console]::IsOutputRedirected) { return } } catch { return }
    try {
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        }
    } catch { }
}

function Show-DlutCaptcha {
    param([string]$ImagePath)
    if (-not $ImagePath -or -not (Test-Path -LiteralPath $ImagePath)) { return }
    $art = ConvertTo-CaptchaAscii -ImagePath $ImagePath -Width 72
    if ($art) {
        Write-Host ''
        Write-Host $art
        Write-Host ''
    }
    Write-Host ('图形验证码的图片在: ' + $ImagePath)
    if (-not $art) { Write-Host '（这个终端不支持把图片画成字符，直接打开上面的图片看）' }
}

function Read-DlutConsoleLine {
    <#
    Read-Host hands back $null once stdin is not a real console (a piped or
    redirected run), and calling .Trim() on that throws. An empty answer is the
    documented way to cancel, so collapse both cases into an empty string.
    #>
    param([string]$Prompt)
    try { $line = Read-Host $Prompt } catch { return '' }
    if ($null -eq $line) { return '' }
    return ("$line").Trim()
}

function Request-DlutSecondFactor {
    <#
    Runs while the user watches: show the image code, have CAS text the dynamic code,
    then hand both back for the module to POST. An empty answer cancels the login.
    #>
    param([hashtable]$Info)
    Set-ConsoleUtf8
    Write-Host ''
    Write-Host '==================== CAS 二次认证 ===================='
    if ($Info.Notice) { Write-Host $Info.Notice }
    if ($Info.PhoneHint) { Write-Host ('验证码会发到' + $Info.PhoneHint) }
    if ($Info.Round -gt 1) {
        Write-Host ''
        Write-Host ('上一次被 CAS 拒绝: ' + $Info.LastError)
        Write-Host '下面换一张新的图形验证码重来'
    }
    Write-Host ''
    Write-Host '（不想现在登，直接回车就能退出）'

    $imageCode = ''
    while (-not $imageCode) {
        Show-DlutCaptcha $Info.CaptchaPath
        $typed = Read-DlutConsoleLine '图形验证码'
        if (-not $typed) { return @{ ImageCode = ''; SmsCode = '' } }
        $sent = & $Info.SendSms $typed
        if ($sent.Success) {
            $imageCode = $typed
            break
        }
        Write-Host ('没能发出短信: ' + $sent.Message + $(if ($sent.Code) { ' [' + $sent.Code + ']' } else { '' }))
        $again = Read-DlutConsoleLine '换一张图形验证码再试一次吗? [Y/n]'
        if ($again -match '^[nN]') { return @{ ImageCode = ''; SmsCode = '' } }
        try {
            $base = if ($Info.CaptchaUrl) { $Info.CaptchaUrl.Split('?')[0] } else { '' }
            if ($base) {
                $fresh = Send-CasRequestBytes $Info.Session ($base + '?' + (Get-Random -Minimum 100000 -Maximum 999999)) 'GET'
                $saved = Save-CasCaptchaImage $fresh.Bytes $Info.CaptchaPath
                if ($saved) { $Info.CaptchaPath = $saved }
            }
        } catch { }
    }

    Write-Host ('短信已发到' + $Info.PhoneHint + '，通常几十秒内到')
    $smsCode = Read-DlutConsoleLine '短信验证码'
    return @{ ImageCode = $imageCode; SmsCode = $smsCode }
}

function Invoke-DlutCasLogin {
    <#
    One human login that trades an SMS code for a reusable CAS session. Afterwards
    the watchdog reconnects on its own until that session expires.
    #>
    param([object]$Config)
    Set-ConsoleUtf8
    # The stored password is only readable by the account that saved it, so say
    # which window this is instead of blaming the credentials.
    $credential = Get-DlutPlainPassword $Config
    if (-not $credential.Success) {
        Write-Host '密码读不出来，先跑 install.ps1 或 DutNetRelink.ps1 -Configure 重新存一次'
        Write-Host ''
        Write-Host ('配置文件    : ' + $script:ConfigFile + $(if (Test-Path -LiteralPath $script:ConfigFile) { ' (存在)' } else { ' (不存在，所以读到的是默认配置)' }))
        Write-Host ('当前用户    : ' + $env:USERDOMAIN + '\' + $env:USERNAME)
        Write-Host ('存进去的账号 : ' + $(if ($Config.Username) { $Config.Username + '，按 ' + $Config.CredentialScope + ' 作用域加密' } else { '(没有)' }))
        Write-Host ('读不出的原因 : ' + $credential.Error)
        Write-Host ''
        if ($Config.CredentialScope -eq 'CurrentUser') {
            Write-Host '密码是按“只有当初存它的那个 Windows 账户才能解开”的方式加密的。'
            Write-Host '如果这个窗口是“以管理员身份运行”或者你换了个账户登录，就会读不出来。'
            Write-Host '用当初跑 install.ps1 的那个账户，开一个普通（非管理员）窗口再跑一次就行。'
        }
        return 4
    }
    $plain = $credential.Password
    $ip = Get-PrimaryIPv4 $Config.InterfaceName
    if (-not $ip) {
        Write-Host '没找到可用的 IPv4 地址，先确认连上了校园网'
        return 5
    }
    Write-Host ''
    Write-Host ('账号: ' + $Config.Username)
    Write-Host ('本机 IPv4: ' + $ip)
    Write-Host '正在打开 CAS 登录页...'
    Write-Host ''

    for ($round = 1; $round -le 3; $round++) {
        # No session is seeded here on purpose: the point of this run is to walk the
        # second factor and replace whatever is on disk with a fresh one.
        $result = Invoke-DlutCampusLogin $Config.Username $plain $ip -AllowSecondFactor -PromptSecondFactor $script:SecondFactorPrompt
        if ($result.Success) {
            Write-Host ''
            Write-Host '登录成功，CAS 会话已经加密存到 ' + $script:SessionPath
            Write-Host '之后掉线由后台进程自己重连，不用再输验证码，直到这个会话过期。'
            Write-Host '会话过期的时候，再跑一次 -CasLogin 就行。'
            return 0
        }
        Write-Host ('这次没成功: ' + $result.Message)
        if ($result.Message -like '*cancelled*' -or $result.Message -like '*prompt failed*') { return 6 }
        if ($round -lt 3) {
            $more = Read-DlutConsoleLine '再试一次吗? [Y/n]'
            if ($more -match '^[nN]') { return 7 }
        }
    }
    return 7
}

$script:LogFile = Join-Path $script:LogDir ('dutnetrelink-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$config = Read-DlutConfig $script:ConfigFile
Remove-OldLogs $script:LogDir $config.LogRetentionDays

# The interactive second-factor callback, kept as a scriptblock so the login module
# can call back into this file without knowing anything about the console.
$script:SecondFactorPrompt = ${function:Request-DlutSecondFactor}

if ($Configure) { Set-DlutConfigInteractive $script:ConfigFile; exit 0 }
if ($ClearSession) {
    $removed = Clear-DlutSession $script:SessionPath
    Write-Host $(if ($removed) { '已删除保存的 CAS 会话: ' + $script:SessionPath } else { '本来就没有保存的 CAS 会话' })
    exit 0
}
if ($Status) { exit (Show-Status) }
if ($CasLogin) { exit (Invoke-DlutCasLogin $config) }

if (-not $config.Username -or -not $config.PasswordProtected) {
    Write-Log 'no credentials configured; run install.ps1 or DutNetRelink.ps1 -Configure' 'ERROR'
    exit 4
}
if ($Interval -gt 0) { $config.IntervalSeconds = $Interval }

$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\DutNetRelinkWatchdog', [ref]$mutexCreated)
if (-not $mutexCreated) {
    Write-Log 'another watchdog instance is already running; exiting' 'WARN'
    exit 3
}

try {
    Write-Log ('watchdog started (pid ' + $PID + ', interval ' + $config.IntervalSeconds + 's, user ' + $env:USERNAME + ')')
    $wasOnline = $null
    $backoff = 0
    while ($true) {
        $cycleStart = Get-Date
        $online = Test-InternetOnline
        if ($Login) {
            $result = Invoke-RelinkCycle $config (Get-PrimaryIPv4 $config.InterfaceName) 1
            if ($result.Success) { Write-Log 'forced login succeeded' } else { Write-Log ('forced login failed: ' + $result.Message) 'ERROR' }
        } elseif ($online) {
            if ($wasOnline -eq $false) { Write-Log 'internet reachable again' }
            $backoff = 0
        } else {
            if ($wasOnline -ne $false) { Write-Log 'internet unreachable, reconnecting' 'WARN' }
            $result = Invoke-RelinkCycle $config '' $config.MaxAttemptsPerCycle
            if ($result.Success) {
                Write-Log ('reconnected (' + $result.Message + ')')
                $backoff = 0
            } elseif ($result.MfaRequired) {
                # A second factor cannot be answered by a background process, and the
                # first factor is already known good. Stop hammering CAS and wait for
                # the longest configured gap, then ask again in case the stored
                # session has been refreshed by a human in the meantime.
                if ($config.MaxBackoffSeconds -gt 0) { $backoff = $config.MaxBackoffSeconds }
                Write-Log ('CAS is asking for the SMS second factor; run "DutNetRelink.ps1 -CasLogin" once to renew the session; retrying in ' + ($config.IntervalSeconds + $backoff) + 's') 'WARN'
            } else {
                # A wrong password or a CAS captcha wall would otherwise hammer the
                # auth server every cycle, so widen the gap a little each time.
                if ($config.MaxBackoffSeconds -gt 0) {
                    $backoff = if ($backoff -le 0) { 60 } else { [Math]::Min($config.MaxBackoffSeconds, $backoff * 3) }
                }
                Write-Log ('relink gave up: ' + $result.Message + '; next try in ' + ($config.IntervalSeconds + $backoff) + 's') 'ERROR'
            }
        }
        $wasOnline = $online
        if ($Once -or $Login) { break }
        $nextCheck = $cycleStart.AddSeconds($config.IntervalSeconds + $backoff)
        while ((Get-Date) -lt $nextCheck) { Start-Sleep -Milliseconds 500 }
        $drift = ((Get-Date) - $nextCheck).TotalSeconds
        if ($drift -gt 30) {
            Write-Log ('resumed from sleep after ' + [int]$drift + 's idle, checking now')
            Start-Sleep -Seconds 5
        }
    }
} catch {
    Write-Log ('watchdog error: ' + $_.Exception.Message) 'ERROR'
    exit 5
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
exit 0
