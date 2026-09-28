# Runs every test in sequence under Windows PowerShell 5.1 (the host the scheduled
# task uses) and prints one summary per suite. The network suites talk to the real
# portal with deliberately wrong credentials, which CAS is expected to reject.
# Join-Path below is nested on purpose: the multi-argument form needs PowerShell 6+.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$toolsDir = Join-Path $repoRoot 'tools'

$tests = @(
    @{ Name = 'syntax';       File = 'check_syntax.ps1' },
    @{ Name = 'des vectors';  File = 'test_des.ps1' },
    @{ Name = 'cas errors';   File = 'test_cas_error.ps1' },
    @{ Name = 'second factor'; File = 'test_second_factor.ps1' },
    @{ Name = 'session store'; File = 'test_session.ps1' },
    @{ Name = 'config store'; File = 'test_config.ps1' },
    @{ Name = 'login flow';   File = 'test_flow.ps1' },
    @{ Name = 'one cycle';    File = 'selftest_once.ps1' }
)

# The one-cycle suite has to own the single-instance mutex to test its guard, so it steps
# aside on a machine where the installed watchdog is already running. A watchdog holds
# that mutex for its whole life, so a mutex that exists means one is alive.
$needsSoleMutex = @('selftest_once.ps1')

function Test-WatchdogRunning {
    $mutex = $null
    try {
        if (-not [System.Threading.Mutex]::TryOpenExisting('Local\DutNetRelinkWatchdog', [ref]$mutex)) { return $false }
        return $true
    } catch {
        return $false
    } finally {
        if ($mutex) { try { $mutex.Dispose() } catch { } }
    }
}

$fail = 0
foreach ($test in $tests) {
    Write-Host ('=== ' + $test.Name + ' ===')
    $testPath = Join-Path $toolsDir $test.File
    if (-not (Test-Path -LiteralPath $testPath)) {
        Write-Host ('--> ' + $test.Name + ': FAIL (missing file ' + $testPath + ')')
        Write-Host ''
        $fail++
        continue
    }
    if ($needsSoleMutex -contains $test.File -and (Test-WatchdogRunning)) {
        Write-Host ('--> ' + $test.Name + ': SKIP (a watchdog is already running and holds the single-instance mutex)')
        Write-Host ''
        continue
    }
    & $host51 -NoProfile -ExecutionPolicy Bypass -File $testPath | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { $fail++ }
    Write-Host ('--> ' + $test.Name + ': ' + $(if ($code -eq 0) { 'PASS' } else { 'FAIL (exit ' + $code + ')' }))
    Write-Host ''
}

Write-Host ('suites failed: ' + $fail + ' / ' + $tests.Count)
if ($fail -gt 0) { exit 1 }
exit 0
