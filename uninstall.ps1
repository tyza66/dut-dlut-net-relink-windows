<#
.SYNOPSIS
    Removes the DutNetRelink watchdog, its boot hook and its background process.
.DESCRIPTION
    Stops the running watchdog, removes whatever boot hook install.ps1 set up (the
    "DutNetRelink" scheduled task and/or the HKCU Run entry) and kills any leftover
    watchdog process. Credentials and logs are kept by default so a later install can
    pick up where you left off; pass -RemoveConfig / -RemoveLogs to delete them too.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveConfig -RemoveLogs
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'DutNetRelink',
    [switch]$RemoveConfig,
    [switch]$RemoveLogs,
    [switch]$Force,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = if ($RepoRoot) { $RepoRoot } else { $PSScriptRoot }
$libPath = Join-Path $script:RepoRoot 'lib'
Import-Module (Join-Path $libPath 'ConfigStore.psm1') -Force -DisableNameChecking

$script:TaskName = $TaskName
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Confirm-Action {
    param([string]$Question)
    if ($Force) { return $true }
    $answer = Read-Host ($Question + ' [y/N]')
    return ($answer -match '^[yY]')
}

Write-Host 'DutNetRelink - uninstall'

$runEntry = (Get-ItemProperty -Path $runKeyPath -Name $script:TaskName -ErrorAction SilentlyContinue).($script:TaskName)
if ($runEntry) {
    Write-Host 'removing the HKCU\...\Run entry...'
    try { Remove-ItemProperty -Path $runKeyPath -Name $script:TaskName -ErrorAction Stop; Write-Host 'Run entry removed.' }
    catch { Write-Host ('could not remove the Run entry: ' + $_.Exception.Message) }
}

$task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') {
        Write-Host 'stopping the running watchdog...'
        try { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop } catch { Write-Host ('could not stop it cleanly: ' + $_.Exception.Message) }
    }
    Write-Host ('unregistering the scheduled task "' + $script:TaskName + '"...')
    $null = Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
    Write-Host 'task removed.'
} else {
    Write-Host ('no scheduled task named "' + $script:TaskName + '" was found.')
}

$scriptPath = (Join-Path $script:RepoRoot 'src\DutNetRelink.ps1')
$watchdogs = @()
try {
    $watchdogs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $scriptPath + '*') -and $_.ProcessId -ne $PID })
} catch { }
foreach ($process in $watchdogs) {
    Write-Host ('stopping leftover watchdog process ' + $process.ProcessId + '...')
    try { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
}
if ($watchdogs.Count -gt 0) { Write-Host ('leftover processes stopped: ' + $watchdogs.Count) }

$configPath = Get-DlutConfigPath
if ($RemoveConfig -and (Test-Path -LiteralPath $configPath)) {
    if (Confirm-Action ('delete the credentials in ' + $configPath)) {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        Write-Host 'credentials removed.'
    } else {
        Write-Host 'credentials kept.'
    }
}

$logDir = Join-Path (Split-Path -Parent $configPath) 'logs'
if ($RemoveLogs -and (Test-Path -LiteralPath $logDir)) {
    if (Confirm-Action ('delete the logs in ' + $logDir)) {
        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'logs removed.'
    } else {
        Write-Host 'logs kept.'
    }
}

Write-Host ''
Write-Host 'done. the watchdog will no longer run on this machine.'
if (-not $RemoveConfig) { Write-Host ('credentials are still stored at ' + $configPath) }
exit 0
