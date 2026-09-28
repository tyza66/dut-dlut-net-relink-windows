# Exercises ConfigStore without touching the real user config.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\ConfigStore.psm1') -Force -DisableNameChecking

$fail = 0
function Check($Name, $Ok, $Info) {
    if (-not $Ok) { $script:fail++ }
    Write-Host ('{0,-24} {1}  {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Info)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dutcfg-' + [guid]::NewGuid().ToString('N'))
$configPath = Join-Path $tmp 'config.json'
$password = 'S3cret-' + [string]::Join('', [char[]]@(0x4E2D, 0x6587, 0x5BC6, 0x7801))

try {
    $null = Set-DlutConfig -Path $configPath -Username '22019999' -Password $password -Scope 'CurrentUser'
    $config = Read-DlutConfig $configPath
    Check 'CurrentUserDecrypt' ((Unprotect-DlutPassword $config) -ceq $password) ('scope ' + $config.CredentialScope)
    Check 'ConfigNeverPlaintext' ($(Get-Content -LiteralPath $configPath -Raw) -notlike ('*' + $password + '*')) 'no plaintext in json'

    $null = Set-DlutConfig -Path $configPath -Username '22019999' -Password $password -Scope 'LocalMachine' -IntervalSeconds 99999 -LogRetentionDays 0 -MaxAttemptsPerCycle 99
    $config = Read-DlutConfig $configPath
    Check 'LocalMachineDecrypt' ((Unprotect-DlutPassword $config) -ceq $password) ('scope ' + $config.CredentialScope)
    Check 'IntervalClamped' ($config.IntervalSeconds -eq 3600) $config.IntervalSeconds
    Check 'RetentionClamped' ($config.LogRetentionDays -eq 1) $config.LogRetentionDays
    Check 'AttemptsClamped' ($config.MaxAttemptsPerCycle -eq 20) $config.MaxAttemptsPerCycle
    Check 'CredentialReportedOk' ((Test-DlutCredential $config).Ok) $true

    # Values survive a partial rewrite (only a new password supplied).
    $null = Set-DlutConfig -Path $configPath -Password 'another-pw'
    $config = Read-DlutConfig $configPath
    Check 'MergeKeepsSettings' ($config.IntervalSeconds -eq 3600 -and $config.Username -eq '22019999') ('interval ' + $config.IntervalSeconds)
    Check 'MergeSwapsPassword' ((Unprotect-DlutPassword $config) -ceq 'another-pw') $true

    # Broken and invalid content must fall back to defaults, not throw.
    Set-Content -LiteralPath $configPath -Value '{ not json' -Encoding UTF8
    $defaults = Get-DlutConfigDefaults
    $broken = Read-DlutConfig $configPath
    Check 'BrokenFileFallsBack' ($broken.IntervalSeconds -eq $defaults.IntervalSeconds -and $broken.Username -eq '') 'defaults used'

    Set-Content -LiteralPath $configPath -Value '["array","not","object"]' -Encoding UTF8
    Check 'ArrayFileFallsBack' ((Read-DlutConfig $configPath).IntervalSeconds -eq 45) 'defaults used'

    Set-Content -LiteralPath $configPath -Value ([Convert]::ToBase64String([byte[]](1..8))) -Encoding UTF8
    Check 'UndecryptableReported' (-not (Test-DlutCredential (Read-DlutConfig $configPath)).Ok) 'reports failure'
    Check 'UndecryptableEmpty' ((Unprotect-DlutPassword (Read-DlutConfig $configPath)) -eq '') 'empty string'

    # Log rotation removes only files past the retention window.
    $logDir = Join-Path $tmp 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $old = Join-Path $logDir 'dutnetrelink-19990101.log'
    $fresh = Join-Path $logDir 'dutnetrelink-20990101.log'
    $other = Join-Path $logDir 'keepme.txt'
    Set-Content -LiteralPath $old -Value 'old' -Encoding UTF8
    Set-Content -LiteralPath $fresh -Value 'fresh' -Encoding UTF8
    Set-Content -LiteralPath $other -Value 'other' -Encoding UTF8
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)
    Remove-OldLogs $logDir 14
    Check 'OldLogRemoved' (-not (Test-Path -LiteralPath $old)) '30d old deleted'
    Check 'FreshLogKept' (Test-Path -LiteralPath $fresh) 'new log kept'
    Check 'OtherFilesKept' (Test-Path -LiteralPath $other) 'unrelated file kept'

    Check 'RawMissingIsNull' ($null -eq (Read-DlutConfigRaw (Join-Path $tmp 'nope.json'))) 'null'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 }
exit 0
