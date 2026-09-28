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

function Send-CasRequestBytes {
    <#
    Same as Send-CasRequest but keeps the payload as raw bytes: a PNG decoded through
    ReadAsStringAsync is silently corrupted, which is exactly what the captcha is.
    #>
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
    $body = @($response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    $location = ''
    if ($response.Headers.Location) { $location = $response.Headers.Location.ToString() }
    return [pscustomobject]@{
        Status   = [int]$response.StatusCode
        Location = $location
        Url      = $Url
        Body     = ''
        Bytes    = $body
    }
}

function Get-CasCookieOrigins {
    <#
    Where the flow actually talks to, path included. CookieContainer.GetCookies
    filters by path as well as by host, so asking for a bare host root would
    quietly drop the cookies CAS stores under /cas and the portal stores under
    /Self, which is exactly the CASTGC ticket that makes the silent reuse work.
    #>
    return @(
        ('https://' + $script:CasSsoHost.Replace('https://', '').Replace('http://', '') + '/cas/login'),
        ('https://' + $script:CasSsoHost.Replace('https://', '').Replace('http://', '') + '/cas/'),
        ('http://{0}:{1}/' -f $script:CasPortalHost, $script:CasPortalPort)
        ('http://{0}:{1}/Self/sso_login' -f $script:CasPortalHost, $script:CasPortalPort)
    )
}

function Get-CasSessionCookies {
    <# Pulls every cookie the session holds for the two origins, ready to persist. #>
    param([hashtable]$Session)
    if ($null -eq $Session -or $null -eq $Session.Handler -or $null -eq $Session.Handler.CookieContainer) { return @() }
    $found = @()
    $seen = @{}
    foreach ($origin in (Get-CasCookieOrigins)) {
        try {
            $collection = $Session.Handler.CookieContainer.GetCookies([uri]$origin)
        } catch { continue }
        foreach ($cookie in $collection) {
            $key = $cookie.Name + '|' + $cookie.Domain + '|' + $cookie.Path
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (-not $cookie.Value) { continue }
            $found += $cookie
        }
    }
    return $found
}

function Add-CasSessionCookies {
    <# Seeds a fresh session from a previously saved cookie list. Best effort. #>
    param(
        [hashtable]$Session,
        [object[]]$Cookies
    )
    if ($null -eq $Session -or $null -eq $Session.Handler -or -not $Cookies) { return 0 }
    $added = 0
    foreach ($cookie in @($Cookies)) {
        $name = ("$($cookie.Name)").Trim()
        $domain = ("$($cookie.Domain)").Trim().TrimStart('.')
        $path = ("$($cookie.Path)").Trim()
        if (-not $name -or -not $domain) { continue }
        if (-not $path) { $path = '/' }
        try {
            $netCookie = New-Object System.Net.Cookie($name, "$($cookie.Value)", $path, $domain)
            try { $netCookie.Secure = [bool]$cookie.Secure } catch { }
            $Session.Handler.CookieContainer.Add($netCookie)
            $added++
        } catch {
            Write-Verbose ('cookie ' + $name + ' could not be seeded: ' + $_.Exception.Message)
        }
    }
    return $added
}

function Read-CasCookieValue {
    <# CAS reports the second-factor outcome through a cookie, not a body. #>
    param(
        [hashtable]$Session,
        [string]$Origin,
        [string]$Name
    )
    if ($null -eq $Session -or $null -eq $Session.Handler) { return '' }
    try {
        $collection = $Session.Handler.CookieContainer.GetCookies([uri]$Origin)
        foreach ($cookie in $collection) {
            if ($cookie.Name -eq $Name) { return "$($cookie.Value)" }
        }
    } catch { }
    return ''
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
        $span = [regex]::Match($Html, '(?s)<span[^>]*id="' + $name + '"[^>]*>(.*?)</span>', 'IgnoreCase')
        if ($span.Success) {
            $reason = Remove-CasHtmlTags $span.Groups[1].Value
            if ($reason) { return ('CAS says: ' + $reason) }
        }
    }
    # A genuine captcha challenge is an input field to fill in, not a script include.
    if ($Html -match '<input[^>]*(?:id|name)="[^"]*captcha[^"]*"' -or $Html -match 'id="[^"]*captcha[^"]*"[^>]*<img') {
        return 'CAS wants a captcha; log in once in a browser to clear it'
    }
    # The recheck page is itself a form, so its marker has to be checked before the
    # generic login-form branch below, otherwise a rejected SMS code is reported as
    # a login-form refusal.
    if ($Html -match 'name="PM1"' -or $Html -match '动态验证码') {
        return 'CAS rejected the second factor code'
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

$script:CasSmsCodeMessages = @{
    'success'           = 'SMS code sent to the phone number on file'
    'img_code_error'    = 'the image code was wrong'
    'user_not_exist'    = 'CAS does not know this account'
    'get_times_more'    = 'asked too often, wait a minute'
    'error1'            = 'CAS is limiting this account, try again in about ten minutes'
    'error2'            = 'this account has used up today''s SMS quota'
    'get_session_error' = 'the CAS session expired, start the login again'
    'mobile_reg_error'  = 'the phone number on file cannot be used'
}

function Get-CasAnswerValue {
    <# Reads one field out of whatever shape the prompt scriptblock returned. #>
    param([object]$Answer, [string]$Name)
    if ($null -eq $Answer) { return '' }
    if ($Answer -is [System.Collections.IDictionary]) {
        foreach ($key in $Answer.Keys) {
            if ("$key" -eq $Name) { return ("$($Answer[$key])").Trim() }
        }
        return ''
    }
    $prop = $Answer.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return ("$($prop.Value)").Trim()
}

function Get-DlutSecondFactorInfo {
    <#
    Recognises the CAS recheck page, i.e. the one that asks for an image code plus a
    dynamic SMS code. The marker is the PM1 field: no other CAS page in this flow
    has one, so a healthy first factor never trips this.
    #>
    param(
        [string]$Html,
        [string]$BaseUrl = ''
    )
    $info = [pscustomobject]@{
        Required   = $false
        ActionUrl  = ''
        Execution  = ''
        RelayState = ''
        CaptchaUrl = ''
        SmsUrl     = ''
        PhoneHint  = ''
        Notice     = ''
    }
    if ([string]::IsNullOrWhiteSpace($Html)) { return $info }
    if ($Html -notmatch 'name="PM1"' -and $Html -notmatch 'id="PM1"') { return $info }
    if ($Html -notmatch '动态验证码' -and $Html -notmatch 'recheckcode') { return $info }

    $form = [regex]::Match($Html, '(?s)<form[^>]*id="loginForm"[^>]*>', 'IgnoreCase')
    $action = ''
    if ($form.Success) {
        $actionMatch = [regex]::Match($form.Value, 'action="([^"]*)"', 'IgnoreCase')
        if ($actionMatch.Success) { $action = [System.Net.WebUtility]::HtmlDecode($actionMatch.Groups[1].Value) }
    }

    $captcha = [regex]::Match($Html, '<img[^>]*id="codeImage_mobile"[^>]*>', 'IgnoreCase')
    $captchaSrc = ''
    if ($captcha.Success) {
        $srcMatch = [regex]::Match($captcha.Value, 'src="([^"]*)"', 'IgnoreCase')
        if ($srcMatch.Success) { $captchaSrc = [System.Net.WebUtility]::HtmlDecode($srcMatch.Groups[1].Value) }
    }

    $phoneHint = ''
    $phone = [regex]::Match($Html, '给尾号(\d{3,4})')
    if ($phone.Success) { $phoneHint = ('尾号 ' + $phone.Groups[1].Value + ' 的手机' ) }

    $notice = ''
    $note = [regex]::Match($Html, '系统检测到需要二次认证[^<]*')
    if ($note.Success) { $notice = $note.Value.Trim() }

    $smsUrl = ''
    if ($Html -match 'recheckcode\?code=') { $smsUrl = 'recheckcode' }

    $info.Required   = $true
    $info.Execution  = Get-HtmlHiddenValue $Html 'execution'
    $info.RelayState = Get-HtmlHiddenValue $Html 'RelayState'
    $info.PhoneHint  = $phoneHint
    $info.Notice     = $notice
    $info.SmsUrl     = $smsUrl
    if ($BaseUrl) {
        $info.ActionUrl  = (Resolve-CasRedirect $action $BaseUrl)
        $info.CaptchaUrl = (Resolve-CasRedirect $captchaSrc $BaseUrl)
    }
    if (-not $info.ActionUrl) { $info.ActionUrl = $action }
    if (-not $info.CaptchaUrl) { $info.CaptchaUrl = $captchaSrc }
    return $info
}

function Get-DlutTrustDeviceInfo {
    <#
    Recognises the CAS "trust this device" page that appears after a successful
    SMS second factor. The marker is the hidden check_user_device field.
    #>
    param(
        [string]$Html,
        [string]$BaseUrl = ''
    )
    $info = [pscustomobject]@{
        Required   = $false
        ActionUrl  = ''
        Execution  = ''
        RelayState = ''
    }
    if ([string]::IsNullOrWhiteSpace($Html)) { return $info }
    if ($Html -notmatch 'id="check_user_device"') { return $info }
    if ($Html -notmatch '信任设备') { return $info }

    $form = [regex]::Match($Html, '(?s)<form[^>]*id="loginForm"[^>]*>', 'IgnoreCase')
    $action = ''
    if ($form.Success) {
        $actionMatch = [regex]::Match($form.Value, 'action="([^"]*)"', 'IgnoreCase')
        if ($actionMatch.Success) { $action = [System.Net.WebUtility]::HtmlDecode($actionMatch.Groups[1].Value) }
    }

    $info.Required   = $true
    $info.Execution  = Get-HtmlHiddenValue $Html 'execution'
    $info.RelayState = Get-HtmlHiddenValue $Html 'RelayState'
    if ($BaseUrl) {
        $info.ActionUrl = (Resolve-CasRedirect $action $BaseUrl)
    }
    if (-not $info.ActionUrl) { $info.ActionUrl = $action }
    return $info
}

function Save-CasCaptchaImage {
    <# Writes the captcha PNG somewhere the user can look at it. '' on failure. #>
    param(
        [byte[]]$Bytes,
        [string]$Path
    )
    if (-not $Bytes -or $Bytes.Count -lt 8) { return '' }
    if (-not $Path) { return '' }
    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
        return $Path
    } catch {
        Write-Verbose ('captcha not saved: ' + $_.Exception.Message)
        return ''
    }
}

function ConvertTo-CaptchaAscii {
    <#
    Renders the captcha as ASCII art so the login can happen inside a plain console.
    Returns '' when System.Drawing is unavailable; the caller then just prints the path.
    #>
    param([string]$ImagePath, [int]$Width = 64)
    if (-not $ImagePath -or -not (Test-Path -LiteralPath $ImagePath)) { return '' }
    try { Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue } catch { }
    $bitmap = $null
    try { $bitmap = New-Object System.Drawing.Bitmap($ImagePath) } catch { return '' }
    try {
        if ($bitmap.Width -lt 4 -or $bitmap.Height -lt 4) { return '' }
        $cols = [Math]::Min($Width, $bitmap.Width)
        $rows = [int][Math]::Round($cols * ($bitmap.Height / [double]$bitmap.Width) / 2.0)
        if ($rows -lt 3) { $rows = 3 }
        if ($rows -gt 28) { $rows = 28 }
        $ramp = ' .:-=+*#%@'
        $lines = @()
        for ($row = 0; $row -lt $rows; $row++) {
            $builder = New-Object System.Text.StringBuilder
            for ($col = 0; $col -lt $cols; $col++) {
                $x = [int][Math]::Floor($col * $bitmap.Width / $cols)
                $y = [int][Math]::Floor($row * $bitmap.Height / $rows)
                if ($x -ge $bitmap.Width) { $x = $bitmap.Width - 1 }
                if ($y -ge $bitmap.Height) { $y = $bitmap.Height - 1 }
                $pixel = $bitmap.GetPixel($x, $y)
                $luma = (0.299 * $pixel.R + 0.587 * $pixel.G + 0.114 * $pixel.B) / 255.0
                $index = [int][Math]::Round((1.0 - $luma) * ($ramp.Length - 1))
                if ($index -lt 0) { $index = 0 }
                if ($index -ge $ramp.Length) { $index = $ramp.Length - 1 }
                $null = $builder.Append($ramp[$index])
            }
            $lines += $builder.ToString()
        }
        return ($lines -join [Environment]::NewLine)
    } catch {
        return ''
    } finally {
        try { $bitmap.Dispose() } catch { }
    }
}

function Get-CasWorkDir {
    <# Where the captcha PNG is written; the app folder when we can find it. #>
    if (Get-Command Get-DlutConfigDir -ErrorAction SilentlyContinue) { return (Get-DlutConfigDir) }
    $local = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local)) { $local = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($local)) { $local = [System.IO.Path]::GetTempPath() }
    return (Join-Path $local 'DutNetRelink')
}

function Send-DlutSmsCode {
    <#
    Asks CAS to text the dynamic code. CAS answers with a cookie, not a body, so the
    outcome has to be read back out of the container after the request.
    #>
    param(
        [hashtable]$Session,
        [string]$CaptchaCode,
        [string]$BaseUrl
    )
    if ([string]::IsNullOrWhiteSpace($CaptchaCode)) {
        return @{ Success = $false; Code = ''; Message = 'the image code is empty' }
    }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return @{ Success = $false; Code = ''; Message = 'no CAS page to send the request against' }
    }
    $uri = [uri]$BaseUrl
    $origin = ($uri.Scheme + '://' + $uri.Authority + '/cas/')
    $url = ($origin + 'recheckcode?code=' + [uri]::EscapeDataString($CaptchaCode) + '&' + (Get-Random -Minimum 100000 -Maximum 999999))
    try {
        $response = Send-CasRequest $Session $url 'GET'
    } catch {
        return @{ Success = $false; Code = ''; Message = ('could not reach CAS: ' + $_.Exception.Message) }
    }
    if ($response.Status -ne 200) {
        return @{ Success = $false; Code = ''; Message = ('CAS answered HTTP {0} to the SMS request' -f $response.Status) }
    }
    $code = Read-CasCookieValue $Session $origin 'recheck_mobile_error_info'
    if (-not $code) {
        return @{ Success = $true; Code = ''; Message = 'CAS accepted the request; check your phone' }
    }
    $message = ''
    if ($script:CasSmsCodeMessages.ContainsKey($code)) { $message = $script:CasSmsCodeMessages[$code] }
    return @{ Success = ($code -eq 'success'); Code = $code; Message = $message }
}

function Remove-CasHtmlTags {
    <# Turns CAS error markup such as "Incorrect username and password<br/>" into text. #>
    param([string]$Markup)
    if ([string]::IsNullOrWhiteSpace($Markup)) { return '' }
    $text = [regex]::Replace($Markup, '<br\s*/?>', ' ', 'IgnoreCase')
    $text = [regex]::Replace($text, '<[^>]+>', '')
    return [System.Net.WebUtility]::HtmlDecode($text).Trim()
}

function Invoke-DlutCampusLogin {
    <#
    One full login attempt. Returns @{ Success; Message; TicketUrl; MfaRequired }.
    Success means the portal accepted the ticket; the caller should still confirm online state.
    #>
    param(
        [string]$Username,
        [string]$Password,
        [string]$IPv4,
        [int]$TimeoutSeconds = 30,
        [object[]]$SessionCookies = $null,
        [switch]$AllowSecondFactor,
        [scriptblock]$PromptSecondFactor = $null,
        [string]$SessionPath = '',
        [switch]$NoSession
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        return @{ Success = $false; Message = 'username or password missing' }
    }

    $session = New-CasHttpSession $TimeoutSeconds
    try {
        if ($SessionCookies) { $null = Add-CasSessionCookies $session $SessionCookies }

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
        if ($loginPage.Status -ge 300 -and $loginPage.Status -lt 400 -and $loginPage.Location -match '[?&]ticket=') {
            # A CASTGC that CAS still honours skips the whole form and goes straight
            # to the ticket. That is the path the watchdog rides most of the time.
            return (Complete-DlutCasTicket $session (Resolve-CasRedirect $loginPage.Location $casUrl) $SessionPath $NoSession)
        }
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
            return (Complete-DlutCasTicket $session (Resolve-CasRedirect $post.Location $postUrl) $SessionPath $NoSession)
        }

        if ($post.Status -ge 300 -and $post.Status -lt 400) {
            return @{ Success = $false; Message = ('login returned HTTP {0} to {1}' -f $post.Status, $post.Location) }
        }
        $second = Get-DlutSecondFactorInfo $post.Body $post.Url
        if ($second.Required) {
            if (-not $AllowSecondFactor -or -not $PromptSecondFactor) {
                return @{
                    Success     = $false
                    MfaRequired = $true
                    PhoneHint   = $second.PhoneHint
                    Message     = 'CAS is asking for the SMS second factor'
                }
            }
            return (Invoke-DlutSecondFactorLogin $session $post $second $PromptSecondFactor $SessionPath $NoSession)
        }
        return @{ Success = $false; Message = (Get-CasLoginError $post.Body) }
    } catch {
        return @{ Success = $false; Message = ('login error: ' + $_.Exception.Message) }
    } finally {
        Close-CasHttpSession $session
    }
}

function Complete-DlutCasTicket {
    <#
    Redeems the service ticket against the Dr.COM portal and, on the way out, keeps
    the CAS cookies so the next attempt can start from a ticket instead of a form.
    #>
    param(
        [hashtable]$Session,
        [string]$TicketUrl,
        [string]$SessionPath = '',
        [switch]$NoSession
    )
    if (-not $TicketUrl) { return @{ Success = $false; Message = 'CAS did not return a service ticket' } }
    $sessionSaved = $false
    if (-not $NoSession -and (Get-Command Save-DlutSession -ErrorAction SilentlyContinue)) {
        try {
            $sessionSaved = Save-DlutSession -Cookies (Get-CasSessionCookies $Session) -Path $SessionPath
        } catch {
            Write-Verbose ('session cookies not stored: ' + $_.Exception.Message)
        }
    }
    $final = Invoke-CasRedirectChain $Session $TicketUrl 'GET'
    if ($final -and $final.Status -ge 400) {
        return @{ Success = $false; Message = ('portal rejected the ticket (HTTP {0})' -f $final.Status); TicketUrl = $TicketUrl; SessionSaved = $sessionSaved }
    }
    return @{ Success = $true; Message = 'authenticated'; TicketUrl = $TicketUrl; SessionSaved = $sessionSaved }
}

function Submit-DlutSecondFactorCode {
    <#
    POSTs one image code plus one SMS code. The recheck page does no encryption, so
    the plain fields go out exactly as the browser sends them.
    #>
    param(
        [hashtable]$Session,
        [string]$PostUrl,
        [pscustomobject]$Info,
        [string]$ImageCode,
        [string]$SmsCode
    )
    $fields = [ordered]@{
        'PM1'        = $SmsCode
        'code'       = $ImageCode
        'RelayState' = $Info.RelayState
        'execution'  = $Info.Execution
        '_eventId'   = 'submit'
    }
    $parts = foreach ($key in $fields.Keys) {
        ('{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$fields[$key]))
    }
    return (Send-CasRequest $Session $PostUrl 'POST' ($parts -join '&'))
}

function Submit-DlutTrustDevice {
    <# Confirms the "trust this device" page so CAS finally issues the ticket. #>
    param(
        [hashtable]$Session,
        [string]$PostUrl,
        [pscustomobject]$Info,
        [bool]$TrustDevice = $true
    )
    $fields = [ordered]@{
        'check_user_device' = $(if ($TrustDevice) { 'true' } else { 'false' })
        'RelayState'        = $Info.RelayState
        'execution'         = $Info.Execution
        '_eventId'          = 'submit'
    }
    $parts = foreach ($key in $fields.Keys) {
        ('{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$fields[$key]))
    }
    return (Send-CasRequest $Session $PostUrl 'POST' ($parts -join '&'))
}

function Invoke-DlutSecondFactorLogin {
    <#
    Drives the recheck page with a human in the loop: fetch the image code, ask for
    the SMS code, POST, and re-ask when CAS pushes the same page back. Each round
    re-reads execution and RelayState, because CAS renumbers them after a failure.
    #>
    param(
        [hashtable]$Session,
        [pscustomobject]$Page,
        [pscustomobject]$Info,
        [scriptblock]$PromptSecondFactor,
        [string]$SessionPath = '',
        [switch]$NoSession
    )
    $workDir = Get-CasWorkDir
    $captchaFile = Join-Path $workDir 'captcha.png'
    $current = $Info
    $postUrl = $Info.ActionUrl
    if (-not $postUrl) { $postUrl = $Page.Url }
    $lastError = ''

    for ($round = 1; $round -le 4; $round++) {
        $captchaUrl = $current.CaptchaUrl
        if ($captchaUrl -and $round -gt 1) {
            $fresh = $captchaUrl.Split('?')[0]
            $captchaUrl = ($fresh + '?' + (Get-Random -Minimum 100000 -Maximum 999999))
        }
        if ($captchaUrl) {
            try {
                $image = Send-CasRequestBytes $Session $captchaUrl 'GET'
                $null = Save-CasCaptchaImage $image.Bytes $captchaFile
            } catch {
                Write-Verbose ('captcha could not be fetched: ' + $_.Exception.Message)
            }
        }
        $promptInfo = @{
            PhoneHint   = $current.PhoneHint
            Notice      = $current.Notice
            CaptchaUrl  = $captchaUrl
            CaptchaPath = $(if (Test-Path -LiteralPath $captchaFile) { $captchaFile } else { '' })
            LastError   = $lastError
            Round       = $round
            Session     = $Session
            SendSms     = {
                param($ImageCode)
                Send-DlutSmsCode -Session $Session -CaptchaCode $ImageCode -BaseUrl $Page.Url
            }
        }
        $answer = $null
        try { $answer = & $PromptSecondFactor $promptInfo } catch {
            return @{ Success = $false; Message = ('second factor prompt failed: ' + $_.Exception.Message) }
        }
        $imageCode = Get-CasAnswerValue $answer 'ImageCode'
        $smsCode = Get-CasAnswerValue $answer 'SmsCode'
        if (-not $imageCode -or -not $smsCode) {
            return @{ Success = $false; Message = 'the second factor was cancelled' }
        }

        try {
            $submitted = Submit-DlutSecondFactorCode $Session $postUrl $current $imageCode $smsCode
        } catch {
            return @{ Success = $false; Message = ('second factor submit failed: ' + $_.Exception.Message) }
        }
        if ($submitted.Status -ge 300 -and $submitted.Status -lt 400 -and $submitted.Location -match '[?&]ticket=') {
            return (Complete-DlutCasTicket $Session (Resolve-CasRedirect $submitted.Location $postUrl) $SessionPath $NoSession)
        }
        if ($submitted.Status -ge 300 -and $submitted.Status -lt 400) {
            return @{ Success = $false; Message = ('second factor returned HTTP {0} to {1}' -f $submitted.Status, $submitted.Location) }
        }
        $trust = Get-DlutTrustDeviceInfo $submitted.Body $submitted.Url
        if ($trust.Required) {
            $trustUrl = $trust.ActionUrl
            if (-not $trustUrl) { $trustUrl = $submitted.Url }
            try {
                $confirmed = Submit-DlutTrustDevice $Session $trustUrl $trust $true
            } catch {
                return @{ Success = $false; Message = ('trust device submit failed: ' + $_.Exception.Message) }
            }
            if ($confirmed.Status -ge 300 -and $confirmed.Status -lt 400 -and $confirmed.Location -match '[?&]ticket=') {
                return (Complete-DlutCasTicket $Session (Resolve-CasRedirect $confirmed.Location $trustUrl) $SessionPath $NoSession)
            }
            if ($confirmed.Status -ge 300 -and $confirmed.Status -lt 400) {
                return @{ Success = $false; Message = ('trust device returned HTTP {0} to {1}' -f $confirmed.Status, $confirmed.Location) }
            }
            $submitted = $confirmed
        }
        $lastError = Get-CasLoginError $submitted.Body
        $again = Get-DlutSecondFactorInfo $submitted.Body $submitted.Url
        if (-not $again.Required) {
            return @{ Success = $false; Message = $lastError }
        }
        $current = $again
        if ($again.ActionUrl) { $postUrl = $again.ActionUrl }
    }
    return @{ Success = $false; Message = ('CAS kept refusing the second factor: ' + $lastError) }
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
