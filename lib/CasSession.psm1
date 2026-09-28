# CasSession - remembers one completed CAS sign-in so the watchdog does not have to
# solve the second factor again and again. The file holds a single DPAPI-encrypted
# JSON blob, so no cookie (in particular the CASTGC ticket-granting cookie) is ever
# written to disk in clear text.
#
# Everything here is best effort. When the blob cannot be written, or decrypts only
# for another account, the caller falls back to a full interactive login.

$script:SessionFileName = 'session.json'
$script:SessionVersion = 1

# ConfigStore owns the app folder; import it when it is reachable so both modules
# always agree on where the state lives.
Import-Module (Join-Path $PSScriptRoot 'ConfigStore.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Get-DlutSessionDir {
    if (Get-Command Get-DlutConfigDir -ErrorAction SilentlyContinue) { return (Get-DlutConfigDir) }
    $local = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local)) { $local = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($local)) { $local = [System.IO.Path]::GetTempPath() }
    return (Join-Path $local 'DutNetRelink')
}

function Get-DlutSessionPath {
    param([string]$BaseDir = '')
    $dir = if ($BaseDir) { $BaseDir } else { Get-DlutSessionDir }
    return (Join-Path $dir $script:SessionFileName)
}

function Get-ItemPropertyValue {
    param([object]$InputObject, [string]$Name, [string]$Default = '')
    if ($null -eq $InputObject) { return $Default }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return [string]$prop.Value
}

function ConvertTo-SessionCookie {
    # Normalises a System.Net.Cookie (or anything shaped like one) into a plain
    # object that survives a ConvertTo-Json round trip.
    param([object]$Cookie)
    if ($null -eq $Cookie) { return $null }
    $name = (Get-ItemPropertyValue $Cookie 'Name').Trim()
    if (-not $name) { return $null }
    # A valueless cookie is a deletion marker, not state worth restoring on the next
    # login; the collector in CasAuth drops them for the same reason.
    if (-not (Get-ItemPropertyValue $Cookie 'Value').Trim()) { return $null }
    $domain = (Get-ItemPropertyValue $Cookie 'Domain').Trim().TrimStart('.')
    $path = (Get-ItemPropertyValue $Cookie 'Path').Trim()
    if (-not $path) { $path = '/' }
    $secure = $false
    try { $secure = [bool]$Cookie.Secure } catch { $secure = $false }
    return [pscustomobject]@{
        Name    = $name
        Value   = Get-ItemPropertyValue $Cookie 'Value'
        Domain  = $domain
        Path    = $path
        Secure  = $secure
    }
}

function Save-DlutSession {
    <#
    Encrypts $Cookies with DPAPI and writes them to session.json. Returns $true when
    the blob is on disk, $false when the session could not be persisted (the caller
    should keep going: a fresh login works without it).
    #>
    param(
        # Not Mandatory: a caller can hand over a list that is empty or holds a null
        # entry, and that has to resolve to "nothing to save" rather than a bind error.
        [object[]]$Cookies,
        [string]$Path = '',
        [string]$Scope = 'CurrentUser'
    )
    $path = if ($Path) { $Path } else { Get-DlutSessionPath }
    $normalised = @()
    foreach ($cookie in @($Cookies)) {
        $item = ConvertTo-SessionCookie $cookie
        if ($item) { $normalised += $item }
    }
    if ($normalised.Count -eq 0) { return $false }

    $payload = @{
        Version  = $script:SessionVersion
        SavedUtc = ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        Cookies  = $normalised
    }
    $plain = ($payload | ConvertTo-Json -Depth 6)
    if ([string]::IsNullOrWhiteSpace($plain)) { return $false }

    if (-not (Get-Command Protect-DlutText -ErrorAction SilentlyContinue)) { return $false }
    $blob = $null
    try { $blob = Protect-DlutText -Text $plain -Scope $Scope } catch { $blob = $null }
    if (-not $blob) { return $false }

    $envelope = [ordered]@{
        Version  = $script:SessionVersion
        SavedUtc = $payload.SavedUtc
        Count    = $normalised.Count
        Blob     = $blob
    }
    try {
        $directory = Split-Path -Parent $path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Set-Content -LiteralPath $path -Value ($envelope | ConvertTo-Json -Depth 3) -Encoding UTF8 -Force
        return $true
    } catch {
        Write-Verbose ('session not saved: ' + $_.Exception.Message)
        return $false
    }
}

function Get-DlutSession {
    <#
    Reads session.json and decrypts it. Returns @{ SavedUtc; Cookies } or $null when
    the file is missing, unreadable, or belongs to another user account.
    #>
    param([string]$Path = '', [string]$Scope = 'CurrentUser')
    $path = if ($Path) { $Path } else { Get-DlutSessionPath }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $envelope = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $envelope) { return $null }
        $blob = (Get-ItemPropertyValue $envelope 'Blob')
        if (-not $blob) { return $null }
        if (-not (Get-Command Unprotect-DlutText -ErrorAction SilentlyContinue)) { return $null }
        $plain = Unprotect-DlutText -Protected $blob -Scope $Scope
        if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
        $payload = $plain | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $payload) { return $null }
        $cookies = @()
        foreach ($cookie in @($payload.Cookies)) {
            $item = ConvertTo-SessionCookie $cookie
            if ($item) { $cookies += $item }
        }
        if ($cookies.Count -eq 0) { return $null }
        return @{
            SavedUtc = (Get-ItemPropertyValue $payload 'SavedUtc')
            Cookies  = $cookies
        }
    } catch {
        Write-Verbose ('session not usable: ' + $_.Exception.Message)
        return $null
    }
}

function Clear-DlutSession {
    param([string]$Path = '')
    $path = if ($Path) { $Path } else { Get-DlutSessionPath }
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Verbose ('session not removed: ' + $_.Exception.Message)
        return $false
    }
}

function Get-DlutSessionSummary {
    <# Human-readable one-liner for -Status, or "(none)" when nothing is stored. #>
    param([string]$Path = '', [string]$Scope = 'CurrentUser')
    $session = Get-DlutSession -Path $Path -Scope $Scope
    if ($null -eq $session) { return '(none)' }
    $saved = if ($session.SavedUtc) { $session.SavedUtc } else { 'unknown time' }
    $names = @()
    foreach ($cookie in $session.Cookies) { $names += $cookie.Name }
    $unique = @($names | Select-Object -Unique)
    return ($saved + ', ' + $session.Cookies.Count + ' cookies (' + ($unique -join ', ') + ')')
}

Export-ModuleMember -Function *
