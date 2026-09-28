<#
.SYNOPSIS
    Installs the DLUT campus network watchdog as a scheduled task.
.DESCRIPTION
    Collects the CAS credentials (stored DPAPI-encrypted in %LOCALAPPDATA%\DutNetRelink\config.json),
    then registers the "DutNetRelink" scheduled task that runs src\DutNetRelink.ps1 hidden in the
    background. Run it again to update credentials or settings; it is idempotent.

    Default mode -Logon starts the watchdog when you log on (no administrator rights needed).
    Mode -Startup starts it as SYSTEM before anyone logs on and needs an elevated shell.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Mode Startup -Interval 30
    powershell -ExecutionPolicy Bypass -File install.ps1 -Username 22019999 -Password (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
    [ValidateSet('Logon', 'Startup', 'RunKey')]
    [string]$Mode = 'Logon',

    [string]$Username = '',

    [object]$Password = $null,

    [int]$Interval = -1,

    [string]$Interface = '',

    [switch]$NoValidate,

    [switch]$NoStart,

    [string]$TaskName = 'DutNetRelink',

    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = if ($RepoRoot) { $RepoRoot } else { $PSScriptRoot }
$script:ScriptPath = Join-Path $script:RepoRoot 'src\DutNetRelink.ps1'
$libPath = Join-Path $script:RepoRoot 'lib'

foreach ($module in @('CasDes.psm1', 'CasAuth.psm1', 'ConfigStore.psm1')) {
    Import-Module (Join-Path $libPath $module) -Force -DisableNameChecking
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('== ' + $Message)
}

function ConvertTo-PlainSecret {
    param([object]$Secret)
    if ($null -eq $Secret) { return '' }
    if ($Secret -is [System.Security.SecureString]) {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret))
    }
    return [string]$Secret
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CanPrompt {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Test-RunKeyWritable {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'DutNetRelinkWriteProbe' -Value 'probe' -ErrorAction Stop
        Remove-ItemProperty -Path $key -Name 'DutNetRelinkWriteProbe' -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

$script:CanPrompt = Test-CanPrompt
$script:TaskName = $TaskName

Write-Host 'DutNetRelink - DLUT campus network auto reconnect'
Write-Host ('repo: ' + $script:RepoRoot)

if (-not (Test-Path -LiteralPath $script:ScriptPath)) { throw ('watchdog script not found: ' + $script:ScriptPath) }

$scope = 'CurrentUser'
$userId = ("$env:USERDOMAIN\$env:USERNAME")
$bootHook = 'task'
if ($Mode -eq 'Startup') {
    $scope = 'LocalMachine'
    $userId = 'SYSTEM'
    if (-not (Test-IsAdministrator)) {
        throw @'
-Mode Startup needs an administrator shell, because the task runs as SYSTEM.
Open PowerShell as administrator and run this script again, or use -Mode RunKey (no rights needed).
'@
    }
} elseif ($Mode -eq 'RunKey') {
    $bootHook = 'runkey'
    if (-not (Test-RunKeyWritable)) {
        throw 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run is not writable for this account.'
    }
    Write-Host 'boot hook: HKCU\...\Run registry entry (no administrator rights needed)'
} else {
    Write-Host 'boot hook: ONLOGON scheduled task'
}

Write-Step 'Credentials'
$config = Read-DlutConfig (Get-DlutConfigPath)
$username = if ($Username) { $Username.Trim() } else { $config.Username }
$plainPassword = ConvertTo-PlainSecret $Password
$promptLoop = 0
$offeredStoredCredentials = $false

while ($true) {
    # Offer what is already on disk once. After a failed login check the user has
    # already been asked to retype, so the loop must not come back to this question.
    if (-not $offeredStoredCredentials -and $config.PasswordProtected -and
        $scope -eq $config.CredentialScope -and
        -not $PSBoundParameters.ContainsKey('Username') -and -not $PSBoundParameters.ContainsKey('Password')) {
        $offeredStoredCredentials = $true
        Write-Host ('credentials for ' + $config.Username + ' are already stored (scope ' + $scope + ')')
        if (-not $script:CanPrompt) {
            Write-Host 'keeping them; pass -Username / -Password to replace them'
            $username = $config.Username
            break
        }
        $keep = Read-Host 'Keep them? [Y/n]'
        if ($keep -notmatch '^[nN]') {
            Write-Host 'keeping the stored credentials'
            $username = $config.Username
            break
        }
        $username = ''
        $plainPassword = ''
    }
    $offeredStoredCredentials = $true

    if (-not $username) {
        if (-not $script:CanPrompt) { throw 'no username: pass -Username or run with an interactive console' }
        $username = (Read-Host 'Username (student ID)').Trim()
    }
    if (-not $plainPassword) {
        # The stored-credentials question is asked once at the top of this loop.
        if (-not $script:CanPrompt) { throw 'no password: pass -Password or run with an interactive console' }
        # Only worth mentioning when the blob really cannot move to the target scope;
        # after the user declined to keep it, the note would say CurrentUser to CurrentUser.
        if ($config.PasswordProtected -and $scope -ne $config.CredentialScope) {
            Write-Host ('the stored password is scoped to ' + $config.CredentialScope + ' and cannot move to ' + $scope + ' by itself')
        }
        $secure = Read-Host 'Password' -AsSecureString
        if ($null -eq $secure -or $secure.Length -eq 0) { throw 'password is required' }
        $plainPassword = ConvertTo-PlainSecret $secure
    }
    if (-not $username -or -not $plainPassword) { throw 'username and password are both required' }

    if ($NoValidate) {
        Write-Host 'skipping the login check (-NoValidate)'
        break
    }

    $ip = Get-PrimaryIPv4 $Interface
    if (-not $ip) { Write-Host 'no IPv4 address yet, skipping the login check'; break }
    Write-Host ('checking the credentials against CAS from ' + $ip + ' ...')
    $check = Invoke-DlutCampusLogin $username $plainPassword $ip
    if ($check.Success) {
        Write-Host 'CAS accepted the credentials.'
        break
    }
    Write-Host ('login check failed: ' + $check.Message)
    if ($check.Message -like 'portal did not issue a challenge*') {
        Write-Host 'the portal did not answer, so the credentials may still be fine; saving anyway'
        break
    }
    if (-not $script:CanPrompt) { break }
    $promptLoop++
    if ($promptLoop -ge 3) { throw 'too many failed logins, stopping' }
    $retry = Read-Host 'Enter a different username and password? [Y/n]'
    if ($retry -match '^[nN]') { break }
    $username = ''
    $plainPassword = ''
}

Write-Step 'Saving settings'
$configPath = Get-DlutConfigPath
$setParams = @{
    Path  = $configPath
    Scope = $scope
}
if ($username) { $setParams['Username'] = $username }
if ($plainPassword) { $setParams['Password'] = $plainPassword }
if ($Interval -gt 0) { $setParams['IntervalSeconds'] = $Interval }
if ($PSBoundParameters.ContainsKey('Interface')) { $setParams['InterfaceName'] = $Interface }

$null = Set-DlutConfig @setParams
$config = Read-DlutConfig $configPath
$credential = Test-DlutCredential $config
if (-not $credential.Ok) { throw ('the saved config is not decryptable: ' + $credential.Error) }
Write-Host ('config: ' + $configPath)
Write-Host ('user  : ' + $config.Username + '   password scope: ' + $config.CredentialScope)
Write-Host ('interval: ' + $config.IntervalSeconds + 's   interface: ' + $(if ($config.InterfaceName) { $config.InterfaceName } else { '(auto)' }))

$host64 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$commandLine = '"' + $host64 + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script:ScriptPath + '"'

if ($bootHook -eq 'task') {
    Write-Step 'Registering the scheduled task'
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'the ScheduledTasks module is unavailable on this Windows edition'
    }

    $action = New-ScheduledTaskAction -Execute $host64 `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:ScriptPath) `
        -WorkingDirectory $script:RepoRoot

    $trigger = if ($Mode -eq 'Startup') { New-ScheduledTaskTrigger -AtStartup } else { New-ScheduledTaskTrigger -AtLogOn }

    $principal = if ($Mode -eq 'Startup') {
        New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable

    $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existing) { Write-Host ('replacing the existing task (state: ' + $existing.State + ')') }

    try {
        $null = Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description 'Keeps the DLUT campus network authenticated for the graduate workstation (Dr.COM portal + CAS SSO).'
    } catch {
        if ($_.CategoryInfo.Category -ne 'PermissionDenied' -and $_.Exception.Message -notlike '*Access is denied*') { throw }
        Write-Host ''
        Write-Host '--- could not register the scheduled task: Access is denied -----------------------------'
        Write-Host ('This machine does not let ' + $userId + ' create scheduled tasks, even at logon.')
        Write-Host 'That is a local policy, not a scripting problem. Two ways out:'
        Write-Host '  1. right-click Windows PowerShell, Run as administrator, then run this script again;'
        Write-Host '     the credentials are already saved, so it will not ask for a password again.'
        Write-Host '  2. run the very same command with -Mode RunKey, which needs no administrator at all.'
        Write-Host '-------------------------------------------------------------------------------------------------'
        exit 6
    }
    Write-Host ('task "' + $script:TaskName + '" -> ' + $(if ($Mode -eq 'Startup') { 'run as SYSTEM at boot' } else { 'run as ' + $userId + ' at logon' }))
}

if ($bootHook -eq 'runkey') {
    Write-Step 'Registering the HKCU Run entry'
    $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKeyPath)) { $null = New-Item -Path $runKeyPath -Force }
    Set-ItemProperty -Path $runKeyPath -Name $script:TaskName -Value $commandLine -Type String -ErrorAction Stop
    Write-Host ('HKCU\Software\Microsoft\Windows\CurrentVersion\Run')
    Write-Host ('    ' + $script:TaskName + ' = ' + $commandLine)
    Write-Host 'the watchdog starts with your logon and stays resident, with no console window.'
    Write-Host 'note: nothing restarts it if it is ever killed. -Mode Logon (scheduled task) does that, if you can run it elevated.'
}

if (-not $NoStart) {
    if ($bootHook -eq 'task') {
        Start-ScheduledTask -TaskName $script:TaskName
        Write-Host 'started the watchdog, giving it a few seconds...'
        Start-Sleep -Seconds 5
    } else {
        $proc = Start-Process -FilePath $host64 `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script:ScriptPath + '"') `
            -WorkingDirectory $script:RepoRoot -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 5
        $proc.Refresh()
        if ($proc.HasExited) {
            if ($proc.ExitCode -eq 3) {
                Write-Host 'another watchdog is already running, so this one stepped aside'
            } else {
                Write-Host ('the watchdog exited immediately with code ' + $proc.ExitCode + '; check the log below')
            }
        } else {
            Write-Host ('watchdog running in the background as pid ' + $proc.Id)
        }
    }
} else {
    Write-Host 'not started yet'
}

Write-Step 'Current status'
& $script:ScriptPath -Status
Write-Host ''
Write-Host ('uninstall with: powershell -ExecutionPolicy Bypass -File "' + (Join-Path $script:RepoRoot 'uninstall.ps1') + '"')
exit 0
