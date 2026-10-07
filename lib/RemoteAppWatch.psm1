# RemoteAppWatch - optional keepalive for UU Remote and ToDesk.
# It only detects their well-known process names and starts the configured
# executable again when it is gone. It never changes the remote apps themselves.

function Get-DlutRemoteAppDefinitions {
    param(
        [string]$UuRemotePath = '',
        [string]$ToDeskPath = ''
    )

    $programFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
    $programFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }
    $localPrograms = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' } else { '' }

    $uuCandidates = @(
        (Join-Path $programFiles 'Netease\GameViewer\GameViewer.exe'),
        (Join-Path $programFiles 'Netease\GameViewer\bin\GameViewer.exe'),
        (Join-Path $programFilesX86 'Netease\GameViewer\GameViewer.exe')
    )
    if ($localPrograms) {
        $uuCandidates += @(
            (Join-Path $localPrograms 'Netease\GameViewer\GameViewer.exe'),
            (Join-Path $localPrograms 'Netease\GameViewer\bin\GameViewer.exe')
        )
    }

    $toDeskCandidates = @(
        (Join-Path $programFiles 'ToDesk\ToDesk.exe'),
        (Join-Path $programFilesX86 'ToDesk\ToDesk.exe')
    )
    if ($localPrograms) {
        $toDeskCandidates += (Join-Path $localPrograms 'ToDesk\ToDesk.exe')
    }

    return @(
        [pscustomobject]@{
            Name           = 'UU远程'
            ProcessName    = 'GameViewer'
            ConfiguredPath = $UuRemotePath.Trim()
            CandidatePaths = @($uuCandidates)
        },
        [pscustomobject]@{
            Name           = 'ToDesk'
            ProcessName    = 'ToDesk'
            ConfiguredPath = $ToDeskPath.Trim()
            CandidatePaths = @($toDeskCandidates)
        }
    )
}

function Resolve-DlutRemoteAppExecutable {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $candidates = if ($Definition.ConfiguredPath) {
        @($Definition.ConfiguredPath)
    } else {
        @($Definition.CandidatePaths)
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        } catch {
            Write-Verbose ('cannot inspect remote app path ' + $candidate + ': ' + $_.Exception.Message)
        }
    }
    return ''
}

function Get-DlutRemoteAppStatus {
    param(
        [Parameter(Mandatory = $true)][object[]]$Definitions,
        [scriptblock]$ProcessLookup = $null
    )

    foreach ($definition in $Definitions) {
        $running = $false
        $lookupError = ''
        try {
            if ($ProcessLookup) {
                $processes = @(& $ProcessLookup $definition.ProcessName)
            } else {
                $processes = @(Get-Process -Name $definition.ProcessName -ErrorAction SilentlyContinue)
            }
            $running = ($processes.Count -gt 0)
        } catch {
            $lookupError = $_.Exception.Message
        }

        [pscustomobject]@{
            Name             = $definition.Name
            ProcessName      = $definition.ProcessName
            Running          = $running
            ExecutablePath   = Resolve-DlutRemoteAppExecutable $definition
            LookupError      = $lookupError
        }
    }
}

function Start-DlutRemoteApp {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [scriptblock]$ProcessLookup = $null,
        [scriptblock]$Starter = $null
    )

    $status = @(Get-DlutRemoteAppStatus -Definitions @($Definition) -ProcessLookup $ProcessLookup)[0]
    if ($status.Running) {
        return [pscustomobject]@{
            Started = $true
            AlreadyRunning = $true
            Message = 'already running'
            ExecutablePath = $status.ExecutablePath
        }
    }
    if ($status.LookupError) {
        return [pscustomobject]@{
            Started = $false
            AlreadyRunning = $false
            Message = ('cannot inspect the process: ' + $status.LookupError)
            ExecutablePath = $status.ExecutablePath
        }
    }
    if (-not $status.ExecutablePath) {
        return [pscustomobject]@{
            Started = $false
            AlreadyRunning = $false
            Message = 'executable not found'
            ExecutablePath = ''
        }
    }

    try {
        if (-not $Starter) {
            $Starter = {
                param([string]$ExecutablePath)
                Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath)
            }
        }
        $null = & $Starter $status.ExecutablePath $Definition.Name
        return [pscustomobject]@{
            Started = $true
            AlreadyRunning = $false
            Message = 'started'
            ExecutablePath = $status.ExecutablePath
        }
    } catch {
        return [pscustomobject]@{
            Started = $false
            AlreadyRunning = $false
            Message = ('start failed: ' + $_.Exception.Message)
            ExecutablePath = $status.ExecutablePath
        }
    }
}

function Invoke-DlutRemoteAppWatch {
    param(
        [Parameter(Mandatory = $true)][object[]]$Definitions,
        [hashtable]$State = $null,
        [int]$CooldownSeconds = 60,
        [switch]$AllowStart,
        [scriptblock]$ProcessLookup = $null,
        [scriptblock]$Starter = $null,
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $State) { $State = @{} }
    if ($CooldownSeconds -lt 0) { $CooldownSeconds = 0 }

    foreach ($definition in $Definitions) {
        $key = $definition.ProcessName
        $previous = if ($State.ContainsKey($key)) { $State[$key] } else { $null }
        $status = @(Get-DlutRemoteAppStatus -Definitions @($definition) -ProcessLookup $ProcessLookup)[0]
        $action = 'healthy'
        $notify = $false
        $message = 'running'
        $executablePath = $status.ExecutablePath

        if ($status.Running) {
            if ($null -ne $previous -and -not $previous.Running) { $action = 'recovered' }
            $notify = ($action -eq 'recovered')
            $State[$key] = @{
                Running     = $true
                LastAttempt = $null
                Failures    = 0
                LastAction  = $action
                LastMessage = $message
            }
        } elseif (-not $AllowStart) {
            $action = 'blocked'
            $message = 'auto-start is unavailable in this identity'
            $notify = ($null -eq $previous -or $previous.LastAction -ne $action)
            $State[$key] = @{
                Running     = $false
                LastAttempt = if ($null -ne $previous) { $previous.LastAttempt } else { $null }
                Failures    = if ($null -ne $previous) { [int]$previous.Failures } else { 0 }
                LastAction  = $action
                LastMessage = $message
            }
        } else {
            $lastAttempt = if ($null -ne $previous) { $previous.LastAttempt } else { $null }
            $waiting = ($null -ne $lastAttempt -and $CooldownSeconds -gt 0 -and
                (($Now - $lastAttempt).TotalSeconds -lt $CooldownSeconds))
            if ($waiting) {
                $action = 'cooldown'
                $message = ('waiting ' + [Math]::Ceiling($CooldownSeconds - ($Now - $lastAttempt).TotalSeconds) + 's before the next start attempt')
                $State[$key] = @{
                    Running     = $false
                    LastAttempt = $lastAttempt
                    Failures    = if ($null -ne $previous) { [int]$previous.Failures } else { 0 }
                    LastAction  = $action
                    LastMessage = $message
                }
            } else {
                $attempt = Start-DlutRemoteApp -Definition $definition -ProcessLookup $ProcessLookup -Starter $Starter
                $executablePath = $attempt.ExecutablePath
                $failures = if ($null -ne $previous) { [int]$previous.Failures } else { 0 }
                if ($attempt.Started) {
                    $action = 'started'
                    $message = if ($attempt.AlreadyRunning) { 'already running' } else { 'started' }
                    $failures = 0
                } else {
                    $action = if ($attempt.Message -eq 'executable not found') { 'missing' } else { 'start-failed' }
                    $message = $attempt.Message
                    $failures++
                }
                $notify = $true
                $State[$key] = @{
                    Running     = $false
                    LastAttempt = $Now
                    Failures    = $failures
                    LastAction  = $action
                    LastMessage = $message
                }
            }
        }

        [pscustomobject]@{
            Name           = $definition.Name
            ProcessName    = $definition.ProcessName
            Running        = $status.Running
            Action         = $action
            Notify         = $notify
            Message        = $message
            ExecutablePath = $executablePath
            FailureCount   = if ($State.ContainsKey($key)) { [int]$State[$key].Failures } else { 0 }
        }
    }
}

Export-ModuleMember -Function *
