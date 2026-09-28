# ConfigStore - settings and credential persistence for DutNetRelink.
# The password is never written in clear text: config.json holds a base64 DPAPI
# blob scoped to CurrentUser or LocalMachine, so it only decrypts for the account
# the watchdog runs as. LocalMachine is the fallback for a SYSTEM startup task.

$script:ConfigVersion = 1
$script:AppFolderName = 'DutNetRelink'

# Windows PowerShell 5.1 does not load this assembly by default.
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

function Get-DlutConfigDir {
    $local = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local)) { $local = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($local)) { $local = [System.IO.Path]::GetTempPath() }
    return (Join-Path $local $script:AppFolderName)
}

function Get-DlutConfigPath {
    param([string]$BaseDir = '')
    $dir = if ($BaseDir) { $BaseDir } else { Get-DlutConfigDir }
    return (Join-Path $dir 'config.json')
}

function Get-DlutConfigDefaults {
    return [pscustomobject]@{
        Version              = $script:ConfigVersion
        Username             = ''
        PasswordProtected    = ''
        CredentialScope      = 'CurrentUser'
        IntervalSeconds      = 45
        InterfaceName        = ''
        LogRetentionDays     = 14
        MaxAttemptsPerCycle  = 3
        MaxBackoffSeconds    = 1800
    }
}

function Get-JsonValue {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Read-DlutConfigRaw {
    # Returns the parsed config.json as-is, or $null when it is missing or unreadable.
    param([string]$Path = '')
    $path = if ($Path) { $Path } else { Get-DlutConfigPath }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $document = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $document -or $document -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        return $document
    } catch {
        Write-Verbose ('config not usable: ' + $_.Exception.Message)
        return $null
    }
}

function Get-NumberInRange {
    param([object]$Value, [int]$Default, [int]$Min, [int]$Max)
    $number = 0
    if (-not [int]::TryParse(("$Value"), [ref]$number)) { return $Default }
    if ($number -lt $Min) { return $Min }
    if ($number -gt $Max) { return $Max }
    return $number
}

function Read-DlutConfig {
    # Never throws: a missing or broken file yields a usable default configuration.
    param([string]$Path = '')
    $path = if ($Path) { $Path } else { Get-DlutConfigPath }
    $defaults = Get-DlutConfigDefaults
    $raw = Read-DlutConfigRaw $path
    if ($null -eq $raw) { return $defaults }

    $username = Get-JsonValue $raw 'Username'
    $encrypted = Get-JsonValue $raw 'PasswordProtected'
    $scope = Get-JsonValue $raw 'CredentialScope'
    $iface = Get-JsonValue $raw 'InterfaceName'

    return [pscustomobject]@{
        Version              = Get-NumberInRange (Get-JsonValue $raw 'Version') $script:ConfigVersion 1 1000
        Username             = if ($null -eq $username) { '' } else { "$username".Trim() }
        PasswordProtected    = if ($null -eq $encrypted) { '' } else { "$encrypted" }
        CredentialScope      = if ("$scope" -eq 'LocalMachine') { 'LocalMachine' } else { 'CurrentUser' }
        IntervalSeconds      = Get-NumberInRange (Get-JsonValue $raw 'IntervalSeconds') 45 5 3600
        InterfaceName        = if ($null -eq $iface) { '' } else { "$iface".Trim() }
        LogRetentionDays     = Get-NumberInRange (Get-JsonValue $raw 'LogRetentionDays') 14 1 365
        MaxAttemptsPerCycle  = Get-NumberInRange (Get-JsonValue $raw 'MaxAttemptsPerCycle') 3 1 20
        MaxBackoffSeconds    = Get-NumberInRange (Get-JsonValue $raw 'MaxBackoffSeconds') 1800 0 86400
    }
}

function Get-DlutDataProtectionScope {
    param([string]$Scope)
    if ("$Scope" -eq 'LocalMachine') { return [System.Security.Cryptography.DataProtectionScope]::LocalMachine }
    return [System.Security.Cryptography.DataProtectionScope]::CurrentUser
}

function Protect-DlutPassword {
    # Returns a base64 DPAPI blob; the plaintext password is only handled in memory.
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Scope = 'CurrentUser'
    )
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Password)
    $target = Get-DlutDataProtectionScope $Scope
    $blob = $null
    try {
        $blob = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $target)
    } catch {
        $blob = $null
    }
    if ($blob) { return [Convert]::ToBase64String($blob) }

    # Fallback for hosts without that assembly (CurrentUser scope only).
    if ($target -eq [System.Security.Cryptography.DataProtectionScope]::CurrentUser) {
        $secure = ConvertTo-SecureString $Password -AsPlainText -Force
        return (ConvertFrom-SecureString $secure -ErrorAction Stop)
    }
    throw ('cannot protect the password with scope ' + $Scope)
}

function Get-DlutPlainPassword {
    param([object]$Config)
    if ($null -eq $Config) { return @{ Success = $false; Error = 'no configuration' } }
    $encrypted = "$(Get-JsonValue $Config 'PasswordProtected')"
    if (-not $encrypted) { return @{ Success = $false; Error = 'password not stored' } }
    $target = Get-DlutDataProtectionScope "$(Get-JsonValue $Config 'CredentialScope')"
    try {
        $blob = [Convert]::FromBase64String($encrypted)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $null, $target)
        return @{ Success = $true; Password = [System.Text.Encoding]::Unicode.GetString($plain) }
    } catch {
        return @{ Success = $false; Error = ('cannot decrypt the stored password (' + $_.Exception.Message + ')') }
    }
}

function Unprotect-DlutPassword {
    # Empty string when the credential is missing or cannot be decrypted.
    param([object]$Config)
    $result = Get-DlutPlainPassword $Config
    if (-not $result.Success) {
        Write-Verbose ('password unavailable: ' + $result.Error)
        return ''
    }
    return $result.Password
}

function Test-DlutCredential {
    param([object]$Config)
    $result = Get-DlutPlainPassword $Config
    if (-not $result.Success) { Write-Warning $result.Error }
    return [pscustomobject]@{ Ok = [bool]$result.Success; Error = $result.Error }
}

function Set-DlutConfigInteractive {
    param([string]$Path = '')
    $path = if ($Path) { $Path } else { Get-DlutConfigPath }
    $current = Read-DlutConfig $path

    Write-Host 'DLUT campus network reconnect - credential setup'
    Write-Host ('config file: ' + $path)
    if ($current.Username) { Write-Host ('current username: ' + $current.Username) }

    $username = Read-Host 'Username (student ID)'
    if ([string]::IsNullOrWhiteSpace($username)) { throw 'username is required' }

    $secure = Read-Host 'Password' -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) { throw 'password is required' }

    Write-Host ''
    Write-Host 'Run the watchdog as SYSTEM at boot instead of at your logon?'
    $useSystem = Read-Host 'That stores the password so any SYSTEM program can read it [y/N]'
    $scope = if ($useSystem -match '^(y|yes)$') { 'LocalMachine' } else { 'CurrentUser' }

    # One BSTR, zeroed the same way whether saving succeeds or fails.
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $null = Set-DlutConfig -Path $path -Username $username.Trim() -Password $plain -Scope $scope
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    Write-Host 'saved.'
}

function Set-DlutConfig {
    param(
        [string]$Path = '',
        [string]$Username = '',
        [string]$Password = '',
        [string]$Scope = '',
        [int]$IntervalSeconds = -1,
        [string]$InterfaceName = '',
        [int]$LogRetentionDays = -1,
        [int]$MaxAttemptsPerCycle = -1,
        [int]$BackoffSeconds = -1
    )
    $path = if ($Path) { $Path } else { Get-DlutConfigPath }
    $current = Read-DlutConfig $path

    $username = if ($Username) { $Username.Trim() } else { $current.Username }
    $scope = if ($Scope) { $Scope } else { $current.CredentialScope }
    $iface = if ($PSBoundParameters.ContainsKey('InterfaceName')) { $InterfaceName } else { $current.InterfaceName }
    $interval = if ($IntervalSeconds -ge 0) { $IntervalSeconds } else { $current.IntervalSeconds }
    $retention = if ($LogRetentionDays -ge 0) { $LogRetentionDays } else { $current.LogRetentionDays }
    $attempts = if ($MaxAttemptsPerCycle -ge 0) { $MaxAttemptsPerCycle } else { $current.MaxAttemptsPerCycle }
    $maxBackoff = if ($BackoffSeconds -ge 0) { $BackoffSeconds } else { $current.MaxBackoffSeconds }
    $encrypted = if ($Password) { Protect-DlutPassword -Password $Password -Scope $scope } else { $current.PasswordProtected }

    if (-not $username) { throw 'username is required' }
    if (-not $encrypted) { throw 'a password is required on the first setup' }

    $settings = [ordered]@{
        Version              = $script:ConfigVersion
        Username             = $username
        PasswordProtected    = $encrypted
        CredentialScope      = $scope
        IntervalSeconds      = Get-NumberInRange $interval 45 5 3600
        InterfaceName        = $iface
        LogRetentionDays     = Get-NumberInRange $retention 14 1 365
        MaxAttemptsPerCycle  = Get-NumberInRange $attempts 3 1 20
        MaxBackoffSeconds    = Get-NumberInRange $maxBackoff 1800 0 86400
    }

    $directory = Split-Path -Parent $path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = ($settings | ConvertTo-Json -Depth 3)
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -Force
    return $path
}

function Remove-OldLogs {
    param(
        [string]$LogDir = '',
        [int]$RetentionDays = 14
    )
    if (-not $LogDir -or $RetentionDays -le 0) { return }
    if (-not (Test-Path -LiteralPath $LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $LogDir -Filter 'dutnetrelink-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch { } }
}

Export-ModuleMember -Function *
