# Exercises the optional UU Remote / ToDesk keepalive without launching either app.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\RemoteAppWatch.psm1') -Force -DisableNameChecking

$fail = 0
function Check($Name, $Ok, $Info) {
    if (-not $Ok) { $script:fail++ }
    Write-Host ('{0,-28} {1}  {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Info)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dutremote-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    $defaults = @(Get-DlutRemoteAppDefinitions)
    Check 'DefaultDefinitions' ($defaults.Count -eq 2 -and $defaults[0].ProcessName -eq 'GameViewer' -and $defaults[1].ProcessName -eq 'ToDesk') 'UU Remote + ToDesk'

    $fakeExe = Join-Path $tmp 'FakeRemote.exe'
    Set-Content -LiteralPath $fakeExe -Value 'fixture' -Encoding ASCII
    $definition = [pscustomobject]@{
        Name           = 'Test Remote'
        ProcessName    = 'DutRemoteWatchTest'
        ConfiguredPath = $fakeExe
        CandidatePaths = @()
    }
    Check 'ConfiguredPathResolved' ((Resolve-DlutRemoteAppExecutable $definition) -eq $fakeExe) $fakeExe

    $running = @{ DutRemoteWatchTest = $true }
    $started = $false
    $lookup = { param($name) if ($running[$name]) { [pscustomobject]@{ Id = 101 } } }
    $starter = { param($path, $name) $script:started = $true }
    $state = @{}
    $now = [datetime]'2026-10-07T12:00:00'

    $health = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State $state -AllowStart `
        -ProcessLookup $lookup -Starter $starter -Now $now)[0]
    Check 'RunningDoesNotStart' ($health.Action -eq 'healthy' -and -not $started) $health.Action

    $running.DutRemoteWatchTest = $false
    $startedPath = ''
    $starter = { param($path, $name) $script:startedPath = $path }
    $started = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State $state -AllowStart `
        -ProcessLookup $lookup -Starter $starter -Now $now.AddSeconds(60))[0]
    Check 'MissingProcessStarts' ($started.Action -eq 'started' -and $startedPath -eq $fakeExe) $started.Action

    $running.DutRemoteWatchTest = $true
    $recovered = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State $state -AllowStart `
        -ProcessLookup $lookup -Starter $starter -Now $now.AddSeconds(120))[0]
    Check 'RecoveryReported' ($recovered.Action -eq 'recovered' -and $recovered.Notify) $recovered.Action

    $running.DutRemoteWatchTest = $false
    $startCount = 0
    $countingStarter = { param($path, $name) $script:startCount++ }
    $startedAgain = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State $state -AllowStart `
        -ProcessLookup $lookup -Starter $countingStarter -Now $now.AddSeconds(180))[0]
    $cooldown = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State $state -AllowStart `
        -CooldownSeconds 60 -ProcessLookup $lookup -Starter $countingStarter -Now $now.AddSeconds(190))[0]
    Check 'StartCooldownHonored' ($startedAgain.Action -eq 'started' -and $cooldown.Action -eq 'cooldown' -and $startCount -eq 1) ('starts ' + $startCount)

    $badDefinition = [pscustomobject]@{
        Name           = 'Missing Remote'
        ProcessName    = 'DutRemoteWatchMissing'
        ConfiguredPath = (Join-Path $tmp 'does-not-exist.exe')
        CandidatePaths = @()
    }
    $missing = @(Invoke-DlutRemoteAppWatch -Definitions @($badDefinition) -State @{} -AllowStart `
        -ProcessLookup $lookup -Starter $countingStarter -Now $now)[0]
    Check 'MissingExecutableReported' ($missing.Action -eq 'missing' -and $missing.Notify -and $missing.FailureCount -eq 1) $missing.Action

    $failed = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State @{} -AllowStart `
        -ProcessLookup $lookup -Starter { param($path, $name) throw 'denied by test' } -Now $now)[0]
    Check 'StartFailureReported' ($failed.Action -eq 'start-failed' -and $failed.Notify -and $failed.Message -like '*denied by test*') $failed.Message

    $blocked = @(Invoke-DlutRemoteAppWatch -Definitions @($definition) -State @{} `
        -ProcessLookup $lookup -Starter $countingStarter -Now $now)[0]
    Check 'SystemModeCanBlockStart' ($blocked.Action -eq 'blocked' -and $blocked.Notify) $blocked.Action
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 }
exit 0
