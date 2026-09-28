# CasDes - faithful PowerShell port of sso.dlut.edu.cn/cas/comm/js/des.js (strEnc)
# The upstream DES variant is self-consistent but NOT standard DES: the tables look
# standard, the key schedule and round wiring do not. Ported bit-for-bit and pinned
# to golden vectors in tools/test_des.ps1.
$script:s1 = @(
    @(14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7),
    @(0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8),
    @(4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0),
    @(15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13)
)
$script:s2 = @(
    @(15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10),
    @(3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5),
    @(0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15),
    @(13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9)
)
$script:s3 = @(
    @(10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8),
    @(13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1),
    @(13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7),
    @(1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12)
)
$script:s4 = @(
    @(7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15),
    @(13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9),
    @(10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4),
    @(3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14)
)
$script:s5 = @(
    @(2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9),
    @(14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6),
    @(4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14),
    @(11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3)
)
$script:s6 = @(
    @(12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11),
    @(10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8),
    @(9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6),
    @(4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13)
)
$script:s7 = @(
    @(4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1),
    @(13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6),
    @(1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2),
    @(6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12)
)
$script:s8 = @(
    @(13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7),
    @(1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2),
    @(7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8),
    @(2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11)
)

function Get-Bt4Hex([string]$Binary) {
    if ($Binary -eq '1010') { return 'A' }
    if ($Binary -eq '1011') { return 'B' }
    if ($Binary -eq '1100') { return 'C' }
    if ($Binary -eq '1101') { return 'D' }
    if ($Binary -eq '1110') { return 'E' }
    if ($Binary -eq '1111') { return 'F' }
    return [Convert]::ToString([Convert]::ToInt32($Binary, 2), 16).ToUpper()
}

function ConvertTo-StrBits([string]$Str) {
    # each character becomes 16 bits, big endian; short strings zero padded to 4 chars
    $bt = [int[]]::new(64)
    $leng = $Str.Length
    $limit = if ($leng -lt 4) { $leng } else { 4 }
    for ($i = 0; $i -lt $limit; $i++) {
        $k = [int][char]$Str[$i]
        for ($j = 0; $j -lt 16; $j++) {
            $bt[16 * $i + $j] = ($k -shr (15 - $j)) -band 1
        }
    }
    return $bt
}

function Get-KeyBlocks([string]$Key) {
    # des.js getKeyBytes: key split into 4 char blocks, each block -> 64 bits
    $blocks = [object[]]::new(([int][math]::Floor($Key.Length / 4)) + $(if ($Key.Length % 4 -gt 0) { 1 } else { 0 }))
    $leng = $Key.Length
    $iterator = [int][math]::Floor($leng / 4)
    $i = 0
    for ($i = 0; $i -lt $iterator; $i++) {
        $blocks[$i] = ConvertTo-StrBits $Key.Substring($i * 4, 4)
    }
    if ($leng % 4 -gt 0) {
        $blocks[$i] = ConvertTo-StrBits $Key.Substring($i * 4, $leng - $i * 4)
    }
    Write-Output $blocks -NoEnumerate
}

function ConvertTo-HexBits([int[]]$ByteData) {
    $hex = ''
    for ($i = 0; $i -lt 16; $i++) {
        $hex += (Get-Bt4Hex ('{0}{1}{2}{3}' -f $ByteData[$i*4], $ByteData[$i*4+1], $ByteData[$i*4+2], $ByteData[$i*4+3]))
    }
    return $hex
}

function Invoke-InitPermute([int[]]$OriginalData) {
    $ipByte = [int[]]::new(64)
    for ($i = 0; $i -lt 4; $i++) {
        $m = 2 * $i + 1
        $n = 2 * $i
        $k = 0
        for ($j = 7; $j -ge 0; $j--) {
            $ipByte[$i * 8 + $k] = $OriginalData[$j * 8 + $m]
            $ipByte[$i * 8 + $k + 32] = $OriginalData[$j * 8 + $n]
            $k++
        }
    }
    return $ipByte
}

function Invoke-ExpandPermute([int[]]$RightData) {
    $epByte = [int[]]::new(48)
    for ($i = 0; $i -lt 8; $i++) {
        if ($i -eq 0) { $epByte[0] = $RightData[31] } else { $epByte[$i * 6] = $RightData[$i * 4 - 1] }
        $epByte[$i * 6 + 1] = $RightData[$i * 4]
        $epByte[$i * 6 + 2] = $RightData[$i * 4 + 1]
        $epByte[$i * 6 + 3] = $RightData[$i * 4 + 2]
        $epByte[$i * 6 + 4] = $RightData[$i * 4 + 3]
        if ($i -eq 7) { $epByte[47] = $RightData[0] } else { $epByte[$i * 6 + 5] = $RightData[$i * 4 + 4] }
    }
    return $epByte
}

function Invoke-BitXor([int[]]$ByteOne, [int[]]$ByteTwo) {
    $xorByte = [int[]]::new($ByteOne.Length)
    for ($i = 0; $i -lt $ByteOne.Length; $i++) {
        $xorByte[$i] = $ByteOne[$i] -bxor $ByteTwo[$i]
    }
    return $xorByte
}

function ConvertTo-SBoxPermute([int[]]$ExpandByte) {
    $sBoxByte = [int[]]::new(32)
    $tables = $script:s1, $script:s2, $script:s3, $script:s4, $script:s5, $script:s6, $script:s7, $script:s8
    for ($m = 0; $m -lt 8; $m++) {
        $i = $ExpandByte[$m * 6] * 2 + $ExpandByte[$m * 6 + 5]
        $j = $ExpandByte[$m * 6 + 1] * 8 + $ExpandByte[$m * 6 + 2] * 4 + $ExpandByte[$m * 6 + 3] * 2 + $ExpandByte[$m * 6 + 4]
        $v = $tables[$m][$i][$j]
        $sBoxByte[$m * 4] = ($v -shr 3) -band 1
        $sBoxByte[$m * 4 + 1] = ($v -shr 2) -band 1
        $sBoxByte[$m * 4 + 2] = ($v -shr 1) -band 1
        $sBoxByte[$m * 4 + 3] = $v -band 1
    }
    return $sBoxByte
}

$script:CasDesPBox = 15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24

function ConvertTo-PPermute([int[]]$SBoxByte) {
    $p = [int[]]::new(32)
    for ($i = 0; $i -lt 32; $i++) { $p[$i] = $SBoxByte[$script:CasDesPBox[$i]] }
    return $p
}

$script:CasDesFpBox = 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24

function ConvertTo-FinallyPermute([int[]]$EndByte) {
    $fp = [int[]]::new(64)
    for ($i = 0; $i -lt 64; $i++) { $fp[$i] = $EndByte[$script:CasDesFpBox[$i]] }
    return $fp
}

$script:CasDesShiftLoop = 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1
$script:CasDesPc2 = 13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31

function New-DesRoundKeys([int[]]$KeyByte) {
    $key = [int[]]::new(56)
    $keys = [object[]]::new(16)
    for ($i = 0; $i -lt 7; $i++) {
        for ($j = 0; $j -lt 8; $j++) {
            $k = 7 - $j
            $key[$i * 8 + $j] = $KeyByte[8 * $k + $i]
        }
    }
    for ($i = 0; $i -lt 16; $i++) {
        for ($j = 0; $j -lt $script:CasDesShiftLoop[$i]; $j++) {
            $tempLeft = $key[0]
            $tempRight = $key[28]
            for ($k = 0; $k -lt 27; $k++) {
                $key[$k] = $key[$k + 1]
                $key[28 + $k] = $key[29 + $k]
            }
            $key[27] = $tempLeft
            $key[55] = $tempRight
        }
        $round = [int[]]::new(48)
        for ($m = 0; $m -lt 48; $m++) { $round[$m] = $key[$script:CasDesPc2[$m]] }
        $keys[$i] = $round
    }
    Write-Output $keys -NoEnumerate
}

function Invoke-DesBlock([int[]]$DataByte, [int[]]$KeyByte) {
    # des.js enc(): single block, 16 Feistel rounds, keys used in order
    $keys = New-DesRoundKeys $KeyByte
    $ipByte = Invoke-InitPermute $DataByte
    $ipLeft = [int[]]::new(32)
    $ipRight = [int[]]::new(32)
    for ($k = 0; $k -lt 32; $k++) {
        $ipLeft[$k] = $ipByte[$k]
        $ipRight[$k] = $ipByte[32 + $k]
    }
    for ($i = 0; $i -lt 16; $i++) {
        $tempLeft = [int[]]$ipLeft.Clone()
        $ipLeft = [int[]]$ipRight.Clone()
        $f = Invoke-BitXor (ConvertTo-PPermute (ConvertTo-SBoxPermute (Invoke-BitXor (Invoke-ExpandPermute $ipRight) $keys[$i]))) $tempLeft
        $ipRight = $f
    }
    $finalData = [int[]]::new(64)
    for ($i = 0; $i -lt 32; $i++) {
        $finalData[$i] = $ipRight[$i]
        $finalData[32 + $i] = $ipLeft[$i]
    }
    return ConvertTo-FinallyPermute $finalData
}

function Get-StrEncHex([string]$Data, [string]$FirstKey, [string]$SecondKey, [string]$ThirdKey) {
    # des.js strEnc(data, firstKey, secondKey, thirdKey) - returns uppercase hex
    $encData = ''
    $firstBt = Get-KeyBlocks $FirstKey
    $secondBt = Get-KeyBlocks $SecondKey
    $thirdBt = Get-KeyBlocks $ThirdKey
    $block = {
        param($Chunk)
        $bt = ConvertTo-StrBits $Chunk
        foreach ($kb in $firstBt) { $bt = Invoke-DesBlock $bt $kb }
        foreach ($kb in $secondBt) { $bt = Invoke-DesBlock $bt $kb }
        foreach ($kb in $thirdBt) { $bt = Invoke-DesBlock $bt $kb }
        return (ConvertTo-HexBits $bt)
    }
    if ($Data.Length -gt 0) {
        if ($Data.Length -lt 4) {
            $encData = & $block $Data
        } else {
            $iterator = [int][math]::Floor($Data.Length / 4)
            for ($i = 0; $i -lt $iterator; $i++) {
                $encData += (& $block $Data.Substring($i * 4, 4))
            }
            $remainder = $Data.Length % 4
            if ($remainder -gt 0) {
                $encData += (& $block $Data.Substring($iterator * 4, $remainder))
            }
        }
    }
    return $encData
}

function Get-CasLoginToken([string]$Username, [string]$Password, [string]$Lt) {
    # the rsa field of the CAS login form: strEnc(user+pass+lt, '1', '2', '3')
    return (Get-StrEncHex ($Username + $Password + $Lt) '1' '2' '3')
}
