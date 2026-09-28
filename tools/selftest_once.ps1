# End-to-end smoke test of the main watchdog script with throwaway credentials.
# Verifies: config load, IP discovery, a real (rejected) CAS login attempt, online
# probing, log writing and the single-instance mutex. Nothing is left behind.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'src\DutNetRelink.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dutrelink-once-' + [guid]::NewGuid().ToString('N'))
$configPath = Join-Path $tmp 'config.json'
$logDir = Join-Path $tmp 'logs'

function Invoke-Watchdog {
    param([string[]]$Arguments)
    $host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $host51 -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments | Out-Host
    return $LASTEXITCODE
}

try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Import-Module (Join-Path $repoRoot 'lib\ConfigStore.psm1') -Force -DisableNameChecking
    $null = Set-DlutConfig -Path $configPath -Username 'relink-selftest' -Password 'deliberately-wrong' -IntervalSeconds 300

    Write-Host '--- first run: rejected credentials must still exit 0 ---'
    $first = Invoke-Watchdog @('-Once', '-ConfigPath', $configPath)
    Write-Host ('exit code: ' + $first)
    if ($first -ne 0) { throw ('the one-shot run should exit 0 (got ' + $first + ')') }

    Write-Host '--- forced login run with wrong credentials ---'
    $forced = Invoke-Watchdog @('-Login', '-ConfigPath', $configPath)
    Write-Host ('exit code: ' + $forced)
    if ($forced -ne 0) { throw ('the forced login run should exit 0 (got ' + $forced + ')') }

    Write-Host '--- second run while another instance holds the mutex ---'
    $background = Start-Job -ScriptBlock {
        $host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $host51 -NoProfile -ExecutionPolicy Bypass -File $using:scriptPath -ConfigPath $using:configPath | Out-Host
    }
    Start-Sleep -Seconds 4
    $second = Invoke-Watchdog @('-ConfigPath', $configPath)
    Wait-Job $background -Timeout 15 | Out-Null
    Stop-Job $background -ErrorAction SilentlyContinue
    Remove-Job $background -Force -ErrorAction SilentlyContinue
    Write-Host ('exit code: ' + $second)
    if ($second -ne 3) { throw ('the second instance should exit 3 while the mutex is held (got ' + $second + ')') }

    Write-Host '--- log contents ---'
    $log = Get-ChildItem -LiteralPath $logDir -Filter 'dutnetrelink-*.log' -File | Select-Object -First 1
    if (-not $log) { throw 'no log file was written' }
    Get-Content -LiteralPath $log.FullName | ForEach-Object { Write-Host ('  ' + $_) }
    $text = Get-Content -LiteralPath $log.FullName -Raw
    if ($text -notmatch 'watchdog started') { throw 'the startup line is missing from the log' }
    if ($text -notmatch 'another watchdog instance is already running') { throw 'the mutex guard line is missing from the log' }
    if ($text -notmatch 'forced login failed') { throw 'the forced login did not record a CAS rejection' }
    Write-Host '--- OK ---'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
