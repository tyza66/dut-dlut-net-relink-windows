# Parses every .ps1 and .psm1 in the repository, so a typo or an unbalanced block
# never waits for the scheduled task to discover it. Every script must also be
# valid UTF-8 carrying a byte order mark: Windows PowerShell 5.1 reads a BOM-less
# file through the machine's ANSI code page, which turns a Chinese string into
# mojibake and can even break the parser. tools\encode_utf8_bom.ps1 maintains that.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$fail = 0

$files = @(Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
    Where-Object { $_.FullName -notlike '*\refs\*' -and $_.FullName -notlike '*\\.git\\*' } |
    Sort-Object FullName)

foreach ($file in $files) {
    $errors = $null
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $fail++
        Write-Host ('PARSE-FAIL ' + $file.FullName)
        foreach ($err in $errors) {
            Write-Host ('            ' + $err.Message + ' at line ' + $err.Extent.StartLineNumber)
        }
        continue
    }

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $relative = $file.FullName.Substring($repoRoot.Length + 1)
    $notes = @()
    $decoded = ''

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $fail++
        $notes += 'no UTF-8 BOM'
    } else {
        $strict = New-Object System.Text.UTF8Encoding($true, $true)
        try {
            $decoded = $strict.GetString($bytes, 3, $bytes.Length - 3)
        } catch {
            $fail++
            $notes += 'not valid UTF-8 after the BOM'
        }
    }

    if ($decoded) {
        # Re-encoding must give the bytes back unchanged, and the text must not
        # contain the replacement character: both are how a file saved in another
        # code page shows up after it has been decoded as UTF-8.
        $roundTrip = [System.Text.Encoding]::UTF8.GetBytes($decoded)
        $same = ($roundTrip.Length -eq $bytes.Length - 3)
        if ($same) {
            for ($i = 0; $i -lt $roundTrip.Length; $i++) {
                if ($roundTrip[$i] -ne $bytes[$i + 3]) { $same = $false; break }
            }
        }
        if (-not $same) {
            $fail++
            $notes += 'does not survive a UTF-8 round trip'
        }
        if ($decoded.Contains([char]0xFFFD)) {
            $fail++
            $notes += 'contains the U+FFFD replacement character'
        }
    }

    $suffix = if ($notes.Count -gt 0) { '  <-- ' + ($notes -join '; ') } else { '' }
    Write-Host ('parse ok   ' + $relative + $suffix)
}

Write-Host ('checked ' + $files.Count + ' files')
if ($fail -gt 0) { exit 1 }
exit 0
