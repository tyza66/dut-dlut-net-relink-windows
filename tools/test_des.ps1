Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\CasDes.psm1') -Force -DisableNameChecking

$ErrorActionPreference = 'Stop'
$utf = [string]::Join('', [char[]]@(0x4E2D, 0x6587, 0x5B57, 0x7B26))

$cases = @(
    @{ Data = 'abcd';  Expected = 'A9CF2704230383D1' },
    @{ Name = 'abc';  Data = 'abc';  Expected = '39644174795FB4D0' },
    @{ Name = 'a';    Data = 'a';    Expected = 'A62B4F77D5F8C6C7' },
    @{ Name = 'x';    Data = 'x';    Expected = '4B4072F73C901FDD' },
    @{ Name = 'cjk';  Data = $utf;   Expected = 'C7CAD5F0F075E7DB' },
    @{ Name = 'long'; Data = 'user123passwordLT-244927-lOnu'; Expected = 'EB6D16D13160C8DCF32E38B457F938979A6B87FE327C3EE9C05209A71D3D408986A9D89CA09B24C63A7903888F65236AD42273CEFFE9B5DCE7402C5658720677' }
)

$fail = 0
foreach ($c in $cases) {
    $got = Get-StrEncHex $c.Data '1' '2' '3'
    $ok = ($got -ceq $c.Expected)
    if (-not $ok) { $fail++ }
    Write-Host ('{0,-6} {1}  got={2}' -f $c.Name, $(if ($ok) { 'PASS' } else { 'FAIL' }), $got)
    if (-not $ok) { Write-Host ('            want=' + $c.Expected) }
}

if ($fail -gt 0) { exit 1 }
exit 0
