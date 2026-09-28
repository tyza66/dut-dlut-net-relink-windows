# Rewrites every script in the repo as UTF-8 with a byte order mark.
#
# Windows PowerShell 5.1 reads a BOM-less .ps1 through the machine's ANSI code page,
# so any Chinese comment or message turns into mojibake and can even break the
# parser. A BOM removes the guessing: 5.1 then decodes the file as UTF-8. Run this
# after adding a non-ASCII string to a script, and again after any bulk edit.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$targets = @(Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
    Where-Object { $_.FullName -notlike '*\refs\*' -and $_.FullName -notlike '*\\.git\\*' } |
    Sort-Object FullName)

$converted = 0
$skipped = 0

foreach ($file in $targets) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    $text = $null
    $asIs = $false
    if ($hasBom) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        $asIs = $true
    } else {
        # A BOM-less file holding bytes above 0x7F was almost certainly meant to be
        # UTF-8, which is exactly the case 5.1 mangles. Treat it as UTF-8, otherwise
        # the file is plain ASCII and needs the BOM more than a rewrite.
        $hasHigh = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
        $encoding = if ($hasHigh) { [System.Text.Encoding]::UTF8 } else { [System.Text.Encoding]::ASCII }
        try { $text = $encoding.GetString($bytes) } catch { $text = $null }
    }

    if ($null -eq $text) {
        Write-Host ('SKIP  ' + $file.FullName.Substring($repoRoot.Length + 1) + ' (not decodable as UTF-8 or ASCII)')
        $skipped++
        continue
    }

    $utf8 = New-Object System.Text.UTF8Encoding($true)
    $payload = $utf8.GetBytes($text)
    $bom = [byte[]]@(0xEF, 0xBB, 0xBF)
    $output = New-Object byte[] ($bom.Length + $payload.Length)
    [System.Array]::Copy($bom, 0, $output, 0, $bom.Length)
    [System.Array]::Copy($payload, 0, $output, $bom.Length, $payload.Length)

    if ($asIs) {
        $same = ($output.Length -eq $bytes.Length)
        if ($same) {
            for ($i = 0; $i -lt $output.Length; $i++) {
                if ($output[$i] -ne $bytes[$i]) { $same = $false; break }
            }
        }
        if ($same) {
            Write-Host ('ok    ' + $file.FullName.Substring($repoRoot.Length + 1))
            continue
        }
    }

    [System.IO.File]::WriteAllBytes($file.FullName, $output)
    $converted++
    Write-Host ('bom   ' + $file.FullName.Substring($repoRoot.Length + 1))
}

Write-Host ('rewrote ' + $converted + ' file(s), ' + ($targets.Count - $converted - $skipped) + ' already correct, ' + $skipped + ' skipped')
if ($skipped -gt 0) { exit 1 }
exit 0
