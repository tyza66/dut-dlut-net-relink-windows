# Parses every .ps1 in the repository, so a typo or an unbalanced block never waits
# for the scheduled task to discover it. Also verifies the files stay pure ASCII,
# which matters because Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$fail = 0

$files = @(Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notlike '*\refs\*' } | Sort-Object FullName)

foreach ($file in $files) {
    $errors = $null
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $fail++
        Write-Host ('PARSE-FAIL ' + $file.FullName)
        foreach ($err in $errors) { Write-Host ('            ' + $err.Message + ' at line ' + $err.Extent.StartLineNumber) }
    } else {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
        $note = if ($nonAscii.Count -gt 0) { ' (WARNING: contains ' + $nonAscii.Count + ' non-ASCII bytes)' } else { '' }
        Write-Host ('parse ok   ' + $file.FullName.Substring($repoRoot.Length + 1) + $note)
        if ($nonAscii.Count -gt 0) { $fail++ }
    }
}

Write-Host ('checked ' + $files.Count + ' files')
if ($fail -gt 0) { exit 1 }
exit 0
