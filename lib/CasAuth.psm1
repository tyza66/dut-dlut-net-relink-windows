# CasAuth - DLUT campus network login flow for Windows.
# Flow: portal challenge (Dr.COM) -> CAS SSO form -> rsa-encrypted POST -> ticket -> portal grants access.
# Runs on Windows PowerShell 5.1 and PowerShell 7+.

$script:CasPortalHost = '172.20.30.2'
$script:CasPortalPort = 8080
$script:CasSsoHost = 'https://sso.dlut.edu.cn'

# Windows PowerShell 5.1 does not load System.Net.Http automatically.
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

# Reachability probes. All three are captive-portal detection endpoints: they only
# return their marker when the real internet is reachable without a portal redirect.
$script:OnlineProbes = @(
    @{ Url = 'http://www.msftconnecttest.com/connecttest.txt'; Marker = 'Microsoft Connect Test' },
    @{ Url = 'http://detectportal.firefox.com/success.txt';       Marker = 'success' },
    @{ Url = 'http://captive.apple.com/hotspot-detect.html';      Marker = 'Success' }
)

function Get-DlutPortalChallengeUrl {
    param([string]$IPv4)
    $ip = if ($IPv4) { $IPv4 } else { 'null' }
    return ('http://{0}:{1}/Self/sso_login?type=null&wlan_user_ip={2}&wlan_user_ipv6=null&wlan_ac_ip=null' -f `
        $script:CasPortalHost, $script:CasPortalPort, $ip)
}

function Get-PrimaryIPv4 {
    <#
    Picks the IPv4 the campus portal sees: the address of the adapter that owns the
    default route. Falls back to any operational adapter that has an IPv4 gateway.
    #>
    param([string]$InterfaceName = '')

    if ($InterfaceName) {
        $match = Get-AdapterIPv4 -InterfaceName $InterfaceName
        if ($match) { return $match }
    }

    try {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric)
        foreach ($route in $routes) {
            $candidate = Get-AdapterIPv4 -InterfaceIndex $route.InterfaceIndex
            if ($candidate) { return $candidate }
        }
    } catch { }

    $best = ''
    $bestScore = 999
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }
        $props = $nic.GetIPProperties()
        $hasGateway = $false
        foreach ($gw in $props.GatewayAddresses) {
            if ($gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $gw.Address.ToString() -ne '0.0.0.0') { $hasGateway = $true; break }
        }
        if (-not $hasGateway) { continue }
        $score = 2
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) { $score = 1 }
        foreach ($ua in $props.UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $ip = $ua.Address.ToString()
            if ($ip.StartsWith('169.254.') -or $ip.StartsWith('127.')) { continue }
            if ($score -lt $bestScore) { $best = $ip; $bestScore = $score }
        }
    }
    if ($best) { return $best }
    return $null
}

function Get-AdapterIPv4 {
    param([string]$InterfaceName = '', [int]$InterfaceIndex = 0)
    $rows = $null
    try { $rows = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue } catch { $rows = $null }
    if (-not $rows -or @($rows).Count -eq 0) { $rows = Get-IpConfigAddresses }
    foreach ($row in @($rows)) {
        if ($InterfaceName -and ("$($row.InterfaceAlias)" -notlike $InterfaceName)) { continue }
        if ($InterfaceIndex -gt 0 -and [int]$row.InterfaceIndex -ne $InterfaceIndex) { continue }
        if ("$($row.IPAddress)" -match '^(127\.|169\.254\.)') { continue }
        return "$($row.IPAddress)"
    }
    return $null
}

function Get-IpConfigAddresses {
    $result = @()
    $currentAlias = ''
    foreach ($line in @(& ipconfig.exe)) {
        if ($line -match '^\S[^:]*:') { $currentAlias = ($line -replace ':$', '').Trim() }
        if ($line -match 'IPv4[^:]*:\s*([0-9]{1,3}(\.[0-9]{1,3}){3})') {
            $result += [pscustomobject]@{ InterfaceAlias = $currentAlias; InterfaceIndex = 0; IPAddress = $matches[1] }
        }
    }
    return $result
}

function New-CasHttpSession {
    param([int]$TimeoutSeconds = 30)
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $cookieType = 'System.Net.Http.CookieContainer'
    try { [Type]$cookieType | Out-Null } catch { $cookieType = 'System.Net.CookieContainer' }
    $handler.CookieContainer = New-Object $cookieType
    $handler.UseCookies = $true
    try {
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    } catch { }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36')
    $client.DefaultRequestHeaders.Add('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
    $client.DefaultRequestHeaders.Add('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8')
    return @{ Client = $client; Handler = $handler }
}

function Close-CasHttpSession {
    param([hashtable]$Session)
    if ($null -eq $Session) { return }
    try { $Session.Client.Dispose() } catch { }
    try { $Session.Handler.Dispose() } catch { }
}

function Send-CasRequest {
    param(
        [hashtable]$Session,
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Content = $null
    )
    $message = New-Object System.Net.Http.HttpRequestMessage($Method, [uri]$Url)
    if ($Content) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $message.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
        $message.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/x-www-form-urlencoded')
    }
    $response = $Session.Client.SendAsync($message).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $location = ''
    if ($response.Headers.Location) { $location = $response.Headers.Location.ToString() }
    return [pscustomobject]@{
        Status   = [int]$response.StatusCode
        Location = $location
        Url      = $Url
        Body     = $body
    }
}

function Resolve-CasRedirect {
    param([string]$Location, [string]$BaseUrl)
    if ([string]::IsNullOrWhiteSpace($Location)) { return $null }
    try { return (New-Object System.Uri((New-Object System.Uri($BaseUrl)), $Location)).AbsoluteUri }
    catch { return $null }
}

function Invoke-CasRedirectChain {
    <# Follows 30x responses by hand, because the session has auto-redirect disabled. #>
    param(
        [hashtable]$Session,
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Content = $null,
        [int]$MaxHops = 6
    )
    $currentUrl = $Url
    $currentMethod = $Method
    $currentContent = $Content
    for ($hop = 0; $hop -lt $MaxHops; $hop++) {
        $response = Send-CasRequest $Session $currentUrl $currentMethod $currentContent
        if ($response.Status -ge 300 -and $response.Status -lt 400 -and $response.Location) {
            $target = Resolve-CasRedirect $response.Location $currentUrl
            if (-not $target) { return $response }
            if ($response.Status -eq 303 -or ($currentMethod -eq 'POST' -and $response.Status -ne 307 -and $response.Status -ne 308)) {
                $currentMethod = 'GET'
                $currentContent = $null
            }
            $currentUrl = $target
            continue
        }
        return $response
    }
    return $null
}

function Get-HtmlHiddenValue {
    param([string]$Html, [string]$FieldName)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $pattern = '<input[^>]*(?:id|name)="' + [regex]::Escape($FieldName) + '"[^>]*>'
    $tag = [regex]::Match($Html, $pattern, 'IgnoreCase')
    if (-not $tag.Success) { return '' }
    $value = [regex]::Match($tag.Value, 'value="([^"]*)"', 'IgnoreCase')
    if (-not $value.Success) { return '' }
    return [System.Net.WebUtility]::HtmlDecode($value.Groups[1].Value)
}

function Get-CasLoginFormInfo {
    param([string]$Html)
    $form = [regex]::Match($Html, '<form[^>]*id="loginForm"[^>]*>', 'IgnoreCase')
    $action = ''
    if ($form.Success) {
        $actionMatch = [regex]::Match($form.Value, 'action="([^"]*)"', 'IgnoreCase')
        if ($actionMatch.Success) { $action = [System.Net.WebUtility]::HtmlDecode($actionMatch.Groups[1].Value) }
    }
    return [pscustomobject]@{
        Action    = $action
        Lt        = Get-HtmlHiddenValue $Html 'lt'
        Execution = Get-HtmlHiddenValue $Html 'execution'
    }
}

function Get-CasLoginError {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return 'empty response' }
    # CAS re-renders the login form on a rejected POST and puts the reason into the
    # #errormsghide span. Quote whatever the server says instead of matching loose
    # keywords: every login page also loads the captcha plugin scripts, so a plain
    # "captcha" search matches a perfectly healthy page.
    foreach ($name in @('errormsghide', 'errormsg')) {
        $span = [regex]::Match($Html, '<span[^>]*id="' + $name + '"[^>]*>([^<]*)</span>', 'IgnoreCase')
        if ($span.Success -and $span.Groups[1].Value.Trim()) {
            return ('CAS says: ' + [System.Net.WebUtility]::HtmlDecode($span.Groups[1].Value).Trim())
        }
    }
    # A genuine captcha challenge is an input field to fill in, not a script include.
    if ($Html -match '<input[^>]*(?:id|name)="[^"]*captcha[^"]*"' -or $Html -match 'id="[^"]*captcha[^"]*"[^>]*<img') {
        return 'CAS wants a captcha; log in once in a browser to clear it'
    }
    # Still showing the login form with no reason given: say exactly that instead of
    # reporting the page title as if it were something unexpected.
    if ($Html -match 'id="loginForm"') {
        return 'CAS refused the login without an error message'
    }
    if ($Html -match '<title>([^<]*)</title>' -and $matches[1].Trim()) {
        return ('unexpected page: ' + $matches[1].Trim() + ' (CAS refused the login)')
    }
    return 'CAS refused the login without an error message'
}

function Invoke-DlutCampusLogin {
    <#
    One full login attempt. Returns @{ Success; Message; TicketUrl }.
    Success means the portal accepted the ticket; the caller should still confirm online state.
    #>
    param(
        [string]$Username,
        [string]$Password,
        [string]$IPv4,
        [int]$TimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        return @{ Success = $false; Message = 'username or password missing' }
    }

    $session = New-CasHttpSession $TimeoutSeconds
    try {
        $serviceUrl = Get-DlutPortalChallengeUrl $IPv4
        $challenge = Send-CasRequest $session $serviceUrl 'GET'
        if ($challenge.Status -ne 302 -or -not $challenge.Location) {
            return @{ Success = $false; Message = ('portal did not issue a challenge (HTTP {0})' -f $challenge.Status) }
        }

        $casUrl = Resolve-CasRedirect $challenge.Location $serviceUrl
        if (-not $casUrl -or $casUrl -notlike 'https://sso.dlut.edu.cn/cas/*') {
            return @{ Success = $false; Message = ('unexpected challenge target: {0}' -f $casUrl) }
        }

        $loginPage = Send-CasRequest $session $casUrl 'GET'
        if ($loginPage.Status -ne 200 -or $loginPage.Body -notmatch 'loginForm') {
            return @{ Success = $false; Message = ('CAS login page unavailable (HTTP {0})' -f $loginPage.Status) }
        }

        $form = Get-CasLoginFormInfo $loginPage.Body
        if (-not $form.Lt -or -not $form.Execution) {
            return @{ Success = $false; Message = 'CAS login form missing lt/execution' }
        }

        $postUrl = $casUrl
        if ($form.Action) {
            $resolved = Resolve-CasRedirect $form.Action $casUrl
            if ($resolved) { $postUrl = $resolved }
        }

        Import-Module (Join-Path $PSScriptRoot 'CasDes.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $rsa = Get-CasLoginToken $Username $Password $form.Lt

        $fields = [ordered]@{
            'rsa'       = $rsa
            'ul'        = [string]$Username.Length
            'pl'        = [string]$Password.Length
            'sl'        = '0'
            'lt'        = $form.Lt
            'execution' = $form.Execution
            '_eventId'  = 'submit'
        }
        $parts = foreach ($key in $fields.Keys) {
            ('{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$fields[$key]))
        }
        $body = ($parts -join '&')

        $post = Send-CasRequest $session $postUrl 'POST' $body
        if ($post.Status -ge 300 -and $post.Status -lt 400 -and $post.Location -match '[?&]ticket=') {
            $ticketUrl = Resolve-CasRedirect $post.Location $postUrl
            $final = Invoke-CasRedirectChain $session $ticketUrl 'GET'
            if ($final -and $final.Status -ge 400) {
                return @{ Success = $false; Message = ('portal rejected the ticket (HTTP {0})' -f $final.Status); TicketUrl = $ticketUrl }
            }
            return @{ Success = $true; Message = 'authenticated'; TicketUrl = $ticketUrl }
        }

        if ($post.Status -ge 300 -and $post.Status -lt 400) {
            return @{ Success = $false; Message = ('login returned HTTP {0} to {1}' -f $post.Status, $post.Location) }
        }
        return @{ Success = $false; Message = (Get-CasLoginError $post.Body) }
    } catch {
        return @{ Success = $false; Message = ('login error: ' + $_.Exception.Message) }
    } finally {
        Close-CasHttpSession $session
    }
}

function Test-InternetOnline {
    <# True when a captive-portal probe endpoint returns its expected marker. #>
    param([int]$TimeoutSeconds = 6)
    foreach ($probe in $script:OnlineProbes) {
        try {
            $request = [System.Net.HttpWebRequest]::Create($probe.Url)
            $request.Timeout = $TimeoutSeconds * 1000
            $request.ReadWriteTimeout = $TimeoutSeconds * 1000
            $request.AllowAutoRedirect = $false
            $request.Method = 'GET'
            $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $response = $request.GetResponse()
            try {
                if ("$($response.StatusCode)" -ne 'OK') { continue }
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                $body = $reader.ReadToEnd()
                $reader.Dispose()
                if ($body -match [regex]::Escape($probe.Marker)) { return $true }
            } finally { $response.Close() }
        } catch { }
    }
    return $false
}

Export-ModuleMember -Function *
