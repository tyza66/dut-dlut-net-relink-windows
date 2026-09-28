# Read-only probe: fetches a fresh CAS login page and reports where the word
# "captcha" appears, so the error extraction in CasAuth.psm1 cannot be fooled by
# the always-present hidden phone-login block.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\CasAuth.psm1') -Force -DisableNameChecking

$ip = Get-PrimaryIPv4
$session = New-CasHttpSession 30
try {
    $url = Get-DlutPortalChallengeUrl $ip
    $challenge = Send-CasRequest $session $url 'GET'
    Write-Host ('portal: HTTP ' + $challenge.Status)
    $casUrl = Resolve-CasRedirect $challenge.Location $url
    Write-Host ('cas   : ' + $casUrl)
    $page = Send-CasRequest $session $casUrl 'GET'
    Write-Host ('page  : HTTP ' + $page.Status + ', ' + $page.Body.Length + ' bytes')

    $form = Get-CasLoginFormInfo $page.Body
    Write-Host ('lt/execution: ' + $form.Lt + ' / ' + $form.Execution)

    foreach ($name in @('errormsghide', 'errormsg')) {
        $span = [regex]::Match($page.Body, '<span[^>]*id="' + $name + '"[^>]*>([^<]*)</span>', 'IgnoreCase')
        Write-Host ($name.PadRight(13) + ': ' + $(if ($span.Success) { '[' + $span.Groups[1].Value.Trim() + ']' } else { '(absent)' }))
    }

    $hits = [regex]::Matches($page.Body, 'captcha', 'IgnoreCase')
    Write-Host ('captcha mentions: ' + $hits.Count)
    $shown = 0
    foreach ($hit in $hits) {
        if ($shown -ge 4) { break }
        $start = [Math]::Max(0, $hit.Index - 90)
        $len = [Math]::Min(180, $page.Body.Length - $start)
        $snippet = $page.Body.Substring($start, $len) -replace '\s+', ' '
        Write-Host ('  ...' + $snippet)
        $shown++
    }

    # Is the phone/captcha block rendered visible or still a hidden div?
    $phoneBlock = [regex]::Match($page.Body, '<div[^>]*(?:id|class)="[^"]*(?:phone|sms|code)[^"]*"[^>]*>', 'IgnoreCase')
    if ($phoneBlock.Success) { Write-Host ('phone block tag: ' + ($phoneBlock.Value -replace '\s+', ' ')) }
} finally {
    Close-CasHttpSession $session
}
