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
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Login,
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

if ($ConfigPath) { $script:ConfigFile = $ConfigPath } else { $script:ConfigFile = Get-DlutConfigPath }
$script:LogDir = Join-Path (Split-Path -Parent $script:ConfigFile) 'logs'

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
    param([object]$Config, [string]$Ip, [int]$Attempts)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $ip = if ($Ip) { $Ip } else { Get-PrimaryIPv4 $Config.InterfaceName }
        if (-not $ip) { return @{ Success = $false; Message = 'no IPv4 address on any adapter' } }
        if ($attempt -gt 1) { Start-Sleep -Seconds 5 }
        $result = Invoke-DlutCampusLogin $Config.Username (Unprotect-DlutPassword $Config) $ip
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

$script:LogFile = Join-Path $script:LogDir ('dutnetrelink-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$config = Read-DlutConfig $script:ConfigFile
Remove-OldLogs $script:LogDir $config.LogRetentionDays

if ($Configure) { Set-DlutConfigInteractive $script:ConfigFile; exit 0 }
if ($Status) { exit (Show-Status) }

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
