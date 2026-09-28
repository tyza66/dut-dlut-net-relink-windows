<#
.SYNOPSIS
    Walks the CAS SMS second factor without a console attached.
.DESCRIPTION
    "DutNetRelink.ps1 -CasLogin" draws the image code in a real console and waits on
    Read-Host. That needs somebody sitting in front of the window. This variant keeps
    the same HTTP session but hands the two answers over as files, so a remote
    helper - or an assistant driving the machine through a tool channel - can finish
    the login across separate commands:

        status.txt      progress, one timestamped line per event
        captcha.png     the image code to read
        image_code.txt  put the image code here (one line, trimmed)
        sms_code.txt    put the SMS code here (one line, trimmed)
        result.txt      the final outcome, written once

    Both answers belong to one CAS dialog, so the process has to stay alive while it
    waits. Launch it detached (Start-Process -WindowStyle Hidden) and poll status.txt;
    a wrong image code is retried with a fresh image, a wrong SMS code is reported in
    status.txt and can be answered again.

    The connection details come from the same config.json as the watchdog, so the
    saved CAS session lands in the file the watchdog already reads (DPAPI, the
    account that ran the login).
.EXAMPLE
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',
        'D:\Projects\dut-dlut-net-relink-windows\tools\assisted_mfa_login.ps1'
    )
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP 'DutNetRelinkMfa'),
    [int]$AnswerTimeoutSeconds = 1800,
    [int]$PollSeconds = 2,
    [int]$ImageAttempts = 5,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $script:RepoRoot 'lib'
Import-Module (Join-Path $libPath 'CasDes.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'CasAuth.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'ConfigStore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $libPath 'CasSession.psm1') -Force -DisableNameChecking

$configFile = if ($ConfigPath) { $ConfigPath } else { Get-DlutConfigPath }
$sessionPath = Get-DlutSessionPath

if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$statusFile = Join-Path $WorkDir 'status.txt'
$resultFile = Join-Path $WorkDir 'result.txt'
$imageAnswerFile = Join-Path $WorkDir 'image_code.txt'
$smsAnswerFile = Join-Path $WorkDir 'sms_code.txt'
$captchaFile = Join-Path $WorkDir 'captcha.png'

foreach ($stale in @($resultFile, $imageAnswerFile, $smsAnswerFile, $captchaFile)) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
}

function Write-Status {
    param([string]$Text)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Add-Content -LiteralPath $statusFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Wait-AnswerFile {
    <# Polls for a non-empty answer file; '' means the human never answered. #>
    param([string]$Path, [string]$What)
    $deadline = (Get-Date).AddSeconds($AnswerTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $text = ''
            try { $text = "$(Get-Content -LiteralPath $Path -Raw -Encoding UTF8)".Trim() } catch { $text = '' }
            if ($text) {
                Write-Status ("got the $What")
                return $text
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Status ("nobody wrote $Path within $AnswerTimeoutSeconds s")
    return ''
}

function Publish-Captcha {
    <# Copies (or re-fetches) the image so the helper always reads the live one. #>
    param([hashtable]$Info, [switch]$Fresh)
    if ($Fresh -and $Info.CaptchaUrl) {
        $base = $Info.CaptchaUrl.Split('?')[0]
        $url = ($base + '?' + (Get-Random -Minimum 100000 -Maximum 999999))
        try {
            $image = Send-CasRequestBytes $Info.Session $url 'GET'
            $saved = Save-CasCaptchaImage $image.Bytes $captchaFile
            if ($saved) { return $saved }
        } catch {
            Write-Status ('could not refresh the image code: ' + $_.Exception.Message)
        }
    }
    if ($Info.CaptchaPath -and (Test-Path -LiteralPath $Info.CaptchaPath)) {
        try {
            Copy-Item -LiteralPath $Info.CaptchaPath -Destination $captchaFile -Force
            return $captchaFile
        } catch {
            Write-Status ('could not copy the image code: ' + $_.Exception.Message)
        }
    }
    return ''
}

$prompt = {
    param($Info)
    if ($Info.PhoneHint) { Write-Status ('CAS wants the SMS second factor for ' + $Info.PhoneHint) }
    if ($Info.Notice) { Write-Status ('CAS notice: ' + $Info.Notice) }
    if ($Info.Round -gt 1) { Write-Status ('CAS refused the previous codes: ' + $Info.LastError) }

    $imageCode = ''
    for ($attempt = 1; $attempt -le $ImageAttempts; $attempt++) {
        $captcha = Publish-Captcha $Info -Fresh:($attempt -gt 1 -or $Info.Round -gt 1)
        if ($captcha) { Write-Status ('image code is ready: ' + $captcha) } else { Write-Status 'no image code available' }
        $imageCode = Wait-AnswerFile $imageAnswerFile 'image code'
        if (-not $imageCode) { return @{ ImageCode = ''; SmsCode = '' } }
        Remove-Item -LiteralPath $imageAnswerFile -Force -ErrorAction SilentlyContinue

        Write-Status ('asking CAS to text the SMS code with image code ' + $imageCode)
        $sent = & $Info.SendSms $imageCode
        if ($sent.Success) {
            Write-Status ('CAS accepted the image code: ' + $sent.Message)
            break
        }
        Write-Status ('CAS rejected the image code: ' + $sent.Message + $(if ($sent.Code) { ' [' + $sent.Code + ']' } else { '' }))
        $imageCode = ''
    }
    if (-not $imageCode) { return @{ ImageCode = ''; SmsCode = '' } }

    Write-Status 'the SMS should arrive shortly; waiting for the code'
    $smsCode = Wait-AnswerFile $smsAnswerFile 'SMS code'
    if ($smsCode) { Remove-Item -LiteralPath $smsAnswerFile -Force -ErrorAction SilentlyContinue }
    return @{ ImageCode = $imageCode; SmsCode = $smsCode }
}

$exitCode = 1
try {
    $config = Read-DlutConfig $configFile
    $credential = Get-DlutPlainPassword $config
    if (-not $credential.Success) {
        Write-Status ('cannot read the stored password: ' + $credential.Error)
        Write-Status ('config ' + $configFile + '; running as ' + $env:USERDOMAIN + '\' + $env:USERNAME)
        Set-Content -LiteralPath $resultFile -Value ('password unavailable: ' + $credential.Error) -Encoding UTF8
        exit 4
    }
    $ip = Get-PrimaryIPv4 $config.InterfaceName
    if (-not $ip) {
        Write-Status 'no IPv4 address on any adapter'
        Set-Content -LiteralPath $resultFile -Value 'no IPv4 address' -Encoding UTF8
        exit 5
    }

    Write-Status ('logging in as ' + $config.Username + ' from ' + $ip)
    $result = Invoke-DlutCampusLogin $config.Username $credential.Password $ip -AllowSecondFactor -PromptSecondFactor $prompt -SessionPath $sessionPath
    $summary = if ($result.Success) {
        'authenticated' + $(if ($result.SessionSaved) { '; CAS session saved to ' + $sessionPath } else { '; the CAS session was not saved' })
    } else {
        'failed: ' + $result.Message
    }
    Write-Status $summary
    Set-Content -LiteralPath $resultFile -Value $summary -Encoding UTF8
    if ($result.Success) { $exitCode = 0 }
} catch {
    Write-Status ('driver error: ' + $_.Exception.Message)
    Set-Content -LiteralPath $resultFile -Value ('driver error: ' + $_.Exception.Message) -Encoding UTF8
    $exitCode = 1
}
exit $exitCode
