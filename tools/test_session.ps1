# Exercises the CAS cookie jar against a temp directory so the real app folder is
# never touched. Nothing here goes to the network.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\CasSession.psm1') -Force -DisableNameChecking

$fail = 0
function Check($Name, $Ok, $Info) {
    if (-not $Ok) { $script:fail++ }
    Write-Host ('{0,-26} {1}  {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Info)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dutsession-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force
$sessionPath = Join-Path $tmp 'session.json'

try {
    $cookies = @(
        [pscustomobject]@{ Name = 'CASTGC'; Value = 'TGT-42-secret'; Domain = '.sso.dlut.edu.cn'; Path = '/cas'; Secure = $true },
        [pscustomobject]@{ Name = 'JSESSIONIDCAS'; Value = 'ABC123'; Domain = '172.20.30.2'; Path = '/Self' },
        [pscustomobject]@{ Name = 'empty'; Value = ''; Domain = 'sso.dlut.edu.cn'; Path = '/' },
        $null
    )

    Check 'SessionSaved' (Save-DlutSession -Cookies $cookies -Path $sessionPath) 'two valid cookies'
    Check 'SessionFileExists' (Test-Path -LiteralPath $sessionPath) $sessionPath
    Check 'NoPlaintextCookie' (-not ((Get-Content -LiteralPath $sessionPath -Raw) -like '*TGT-42-secret*')) 'blob is encrypted'

    $loaded = Get-DlutSession -Path $sessionPath
    Check 'SessionReadBack' ($null -ne $loaded) 'not null'
    Check 'EmptyValueDropped' (@($loaded.Cookies).Count -eq 2) ('kept ' + @($loaded.Cookies).Count)

    $tgt = @($loaded.Cookies | Where-Object { $_.Name -eq 'CASTGC' })[0]
    Check 'CookieValueKept' ($tgt.Value -eq 'TGT-42-secret') $tgt.Value
    Check 'CookieDomainTrimmed' ($tgt.Domain -eq 'sso.dlut.edu.cn') $tgt.Domain
    Check 'CookiePathKept' ($tgt.Path -eq '/cas') $tgt.Path
    Check 'CookieSecureKept' ($tgt.Secure) "$($tgt.Secure)"

    $summary = Get-DlutSessionSummary -Path $sessionPath
    Check 'SummaryShowsCookies' ($summary -like '*, 2 cookies (*CASTGC*') $summary

    # A single cookie (not an array) is still accepted, and the parent folder is
    # created on demand.
    $deep = Join-Path $tmp 'a\b\c\session.json'
    Check 'SingleCookieSaved' (Save-DlutSession -Cookies ([pscustomobject]@{ Name = 'x'; Value = 'y'; Domain = 'example.test' }) -Path $deep) $deep
    Check 'DeepPathReadable' ((Get-DlutSession -Path $deep).Cookies[0].Path -eq '/') 'default path'
    Check 'DeepPathNotSecure' (-not (Get-DlutSession -Path $deep).Cookies[0].Secure) 'default secure'

    Check 'ValuelessCookiesDropped' (-not (Save-DlutSession -Cookies @($null, [pscustomobject]@{ Name = 'blank'; Value = '' }) -Path $sessionPath)) 'refuses valueless'
    Check 'CurrentSessionStillThere' (Test-Path -LiteralPath $sessionPath) 'earlier file untouched'

    Check 'ClearRemovesFile' (Clear-DlutSession -Path $deep) 'removed'
    Check 'ClearMissingIsFalse' (-not (Clear-DlutSession -Path (Join-Path $tmp 'nope.json'))) 'missing file'
    Check 'ClearTwiceIsFalse' (-not (Clear-DlutSession -Path $deep)) 'already gone'

    Check 'MissingSessionIsNull' ($null -eq (Get-DlutSession -Path (Join-Path $tmp 'nope.json'))) 'null'
    Check 'MissingSummary' ((Get-DlutSessionSummary -Path (Join-Path $tmp 'nope.json')) -eq '(none)') '(none)'

    # Corrupt and foreign files have to fall back, never throw.
    Set-Content -LiteralPath $sessionPath -Value '{ not json' -Encoding UTF8
    Check 'BrokenFileIsNull' ($null -eq (Get-DlutSession -Path $sessionPath)) 'null'

    $foreign = @{ Version = 1; SavedUtc = 'x'; Count = 0; Blob = ([Convert]::ToBase64String([byte[]](1..64))) } | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $sessionPath -Value $foreign -Encoding UTF8
    Check 'ForeignBlobIsNull' ($null -eq (Get-DlutSession -Path $sessionPath)) 'not our account'

    Set-Content -LiteralPath $sessionPath -Value '[]' -Encoding UTF8
    Check 'ArrayFileIsNull' ($null -eq (Get-DlutSession -Path $sessionPath)) 'null'

    Check 'DefaultPathPointsAtFile' ((Get-DlutSessionPath) -like '*session.json') (Get-DlutSessionPath)
    Check 'BaseDirOverridesPath' ((Get-DlutSessionPath -BaseDir $tmp) -eq $sessionPath) $sessionPath
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host ('session store: ' + $fail + ' check(s) failed')
    exit 1
}
Write-Host 'session store: all checks passed'
exit 0
