#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot,
    [string]$ProfilePath,
    [string]$Port = 'COM5'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-LcdCallsign {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -gt 8) {
        return $false
    }

    $hasLetter = $false
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 0x21 -or $code -gt 0x7e) {
            return $false
        }
        if (($code -ge 0x41 -and $code -le 0x5a) -or
            ($code -ge 0x61 -and $code -le 0x7a)) {
            $hasLetter = $true
        }
    }
    return $hasLetter
}

function Assert-LcdAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$ExpectedLength,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required candidate asset is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $ExpectedLength) {
        throw "Candidate asset length check failed: $Path"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne $ExpectedSha256) {
        throw "Candidate asset SHA-256 check failed: $Path"
    }
}

function Read-ConfiguredCallsign {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $profile = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $property = $profile.PSObject.Properties['callsign']
        if ($null -eq $property) {
            return $null
        }
        $value = [string]$property.Value
        if (Test-LcdCallsign $value) {
            return $value
        }
    } catch {
        # 读取本机配置失败时改为本次控制台输入，不输出配置内容。
    }
    return $null
}

function Resolve-Callsign {
    param([string]$Path)

    $value = Read-ConfiguredCallsign $Path
    if ($null -ne $value) {
        Write-Host '已从本机连接配置读取呼号；脚本不会输出或保存该值。'
        return $value
    }

    Write-Host '没有可用的本机呼号配置；请输入本次测试使用的真实呼号。'
    while ($true) {
        $value = Read-Host '呼号（1..8个无空格可见ASCII字符，至少一个英文字母）'
        if (Test-LcdCallsign $value) {
            return $value
        }
        Write-Host '输入不符合条件，请重新输入。'
    }
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = $PSScriptRoot
}
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
} else {
    $ProfilePath = [IO.Path]::GetFullPath((Join-Path $PackageRoot '..\..\..\private\user-config\connection-profile.json'))
}
if ($Port -notmatch '^COM[1-9][0-9]*$') {
    throw 'Port must be a COM port name such as COM5.'
}

$nativePath = Join-Path $PackageRoot 'wirex_bridge.exe'
$wavPath = Join-Path $PackageRoot 'assets\voice-test.wav'
$yPath = Join-Path $PackageRoot 'private\device-y.bin'
$reportsPath = Join-Path $PackageRoot 'reports'

Assert-LcdAsset $nativePath 782336 '2e1bb14402166fbc101108b2e3bece6448997b90cf807817e40e3daaffa4ce5d'
Assert-LcdAsset $wavPath 695836 '4beaf3d5539084f33ae05ba02112823edb75985d2f9e03668e2bdf28cd75570d'
Assert-LcdAsset $yPath 100 '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'

if (-not (Test-Path -LiteralPath $reportsPath -PathType Container)) {
    New-Item -ItemType Directory -Path $reportsPath | Out-Null
}

$callsign = Resolve-Callsign $ProfilePath
Write-Host ''
Write-Host 'HRI LCD 呼号字段位置候选（单次本地WAV；不启动BM会话）'
Write-Host ("串口：{0}；WAV约7.25秒；Y模板和输入文件校验通过。" -f $Port)
Write-Host '前置条件：FTX-1置于DIRECT，HRI已连接，官方WIRES-X程序已关闭，手咪PTT保持松开。'
Write-Host '每次只选择一个字段；native返回菜单后不会自动执行下一字段。Q退出；Ctrl+C交由native现有清理流程处理。'
Write-Host 'LCD显示结果由操作者观察；运行报告固定写lcd_display=unknown。'

while ($true) {
    Write-Host ''
    Write-Host '[D] destination   [S] source   [L] local   [Q] quit'
    $choice = (Read-Host '选择一个字段').Trim().ToUpperInvariant()
    $field = switch ($choice) {
        'D' { 'destination'; break }
        'S' { 'source'; break }
        'L' { 'local'; break }
        'Q' { 'quit'; break }
        default { 'invalid' }
    }
    if ($field -eq 'quit') {
        break
    }
    if ($field -eq 'invalid') {
        Write-Host '选择无效，请输入 D、S、L 或 Q。'
        continue
    }

    Write-Host ("本次只替换 {0} 的10字节呼号字段；报告不会记录呼号。" -f $field)
    $confirm = Read-Host '确认DIRECT/HRI/官方程序/PTT状态正确后，输入Y开始本次实验'
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host '本次已取消，未启动native。'
        continue
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $reportPath = [IO.Path]::GetFullPath((Join-Path $reportsPath ("lcd-candidate-{0}-{1}.json" -f $stamp, $field)))
    & $nativePath '--hri-lcd-identity-candidate' '--port' $Port '--body-file' $yPath `
        '--file' $wavPath '--report-file' $reportPath '--field' $field '--callsign' $callsign
    $nativeExitCode = $LASTEXITCODE
    Write-Host ("native退出码：{0}；报告：{1}" -f $nativeExitCode, $reportPath)
}

Write-Host '已退出LCD字段候选菜单。'
