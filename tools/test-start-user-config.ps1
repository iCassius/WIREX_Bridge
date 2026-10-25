param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'bridge-user-config.psm1'
Import-Module -Name $modulePath -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "预期拒绝但操作成功：$Message" }
}

$commandPath = Join-Path $PSScriptRoot 'start-user-config.cmd'
$commandBytes = [System.IO.File]::ReadAllBytes($commandPath)
Assert-True ($commandBytes.Length -gt 3 -and
    -not ($commandBytes[0] -eq 0xef -and $commandBytes[1] -eq 0xbb -and $commandBytes[2] -eq 0xbf)) `
    'CMD 启动器不带 UTF-8 BOM'
Assert-True (@($commandBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'CMD 启动器只包含 ASCII 字节'
for ($index = 0; $index -lt $commandBytes.Length; $index++) {
    if ($commandBytes[$index] -eq 10) {
        Assert-True ($index -gt 0 -and $commandBytes[$index - 1] -eq 13) 'CMD 启动器每个换行都使用 CRLF'
    }
}
$commandText = [System.Text.Encoding]::ASCII.GetString($commandBytes)
Assert-True ($commandText.Contains('exit /b %_wirex_exit%') -and $commandText.Contains('pause')) `
    'CMD 启动器保留失败退出码并在错误路径暂停'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-user-config-' + [guid]::NewGuid().ToString('N'))
$packagePath = Join-Path $temporaryRoot 'release'
$configPath = Join-Path $temporaryRoot 'private\user-config'
[System.IO.Directory]::CreateDirectory($packagePath) | Out-Null
[System.IO.Directory]::CreateDirectory($configPath) | Out-Null
try {
    $scriptDefault = Get-BridgeUserConfigDirectory -ScriptRoot (Join-Path $temporaryRoot 'tools')
    Assert-True ($scriptDefault -ceq [System.IO.Path]::GetFullPath((Join-Path $temporaryRoot 'private\user-config'))) `
        '源码工具目录默认配置应指向仓库 private/user-config'
    $packageDefault = Get-BridgeUserConfigDirectory -ScriptRoot $packagePath
    Assert-True ($packageDefault -ceq [System.IO.Path]::GetFullPath((Join-Path $packagePath 'private\user-config'))) `
        '便携包默认配置应位于包内 private/user-config'
    Assert-True ([System.IO.Directory]::Exists($packageDefault)) '便携包默认配置目录应自动创建'

    foreach ($required in @('start-bm-radio-bridge.ps1', 'wirex_bridge.exe')) {
        [System.IO.File]::WriteAllText((Join-Path $packagePath $required), 'stub')
    }
    [System.IO.File]::WriteAllText((Join-Path $configPath 'bridge-directory.txt'), '..\..\release')
    $selectedRelease = Get-BridgeReleaseDirectory -UserConfigDirectory $configPath
    Assert-True ($selectedRelease -ceq [System.IO.Path]::GetFullPath($packagePath)) `
        '相对版本路径应以 user-config 目录为基准解析'
    [System.IO.File]::WriteAllText((Join-Path $configPath 'bridge-directory.txt'), "..\..\release`n..\..\release")
    Assert-Throws { Get-BridgeReleaseDirectory -UserConfigDirectory $configPath } '版本指针不接受多行'

    $audioPath = Join-Path $configPath 'audio-settings.json'
    $defaultAudio = Get-BridgeAudioSettings -Path $audioPath
    Assert-True ($defaultAudio.RadioPlaybackGainMilli -eq 1000 -and $defaultAudio.MicTransmitGainMilli -eq 16000) `
        '缺少跨版本音量文件时使用 1x/16x 默认值'
    Assert-True ([System.IO.File]::Exists($audioPath)) '默认音量应保存在 user-config 目录'
    $changedAudio = Get-BridgeAudioSettings -Path $audioPath -RadioPlaybackGain '1.25' -MicTransmitGain '2.5'
    Assert-True ($changedAudio.RadioPlaybackGainMilli -eq 1250 -and $changedAudio.MicTransmitGainMilli -eq 2500) `
        '两路音量可分别保存为小数'
    $loadedAudio = Read-BridgeAudioSettings -Path $audioPath
    Assert-True ($loadedAudio.RadioPlaybackGainMilli -eq 1250 -and $loadedAudio.MicTransmitGainMilli -eq 2500) `
        '下一次启动会从同一用户配置恢复两路音量'
    Assert-True ((Format-BridgeGain -GainMilli 1250) -ceq '1.25') '增益参数使用 invariant 小数点格式'

    $legacyAudio = Join-Path $packagePath 'audio-settings.json'
    [System.IO.File]::WriteAllText($legacyAudio, '{"schema_version":1,"radio_playback_gain":0.75,"mic_transmit_gain":4}')
    Remove-Item -LiteralPath $audioPath -Force
    $migratedAudio = Get-BridgeAudioSettings -Path $audioPath -LegacyPath $legacyAudio
    Assert-True ($migratedAudio.RadioPlaybackGainMilli -eq 750 -and $migratedAudio.MicTransmitGainMilli -eq 4000) `
        '首次使用时迁移所选旧便携目录中的音量值'

    foreach ($invalid in @(
        '{"schema_version":1,"radio_playback_gain":1,"mic_transmit_gain":16,"unknown":0}',
        '{"schema_version":1,"radio_playback_gain":1,"radio_playback_gain":2,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1e0,"mic_transmit_gain":16}',
        '{"schema_version":2,"radio_playback_gain":1,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":0.1,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":"1","mic_transmit_gain":16}'
    )) {
        [System.IO.File]::WriteAllText($audioPath, $invalid)
        Assert-Throws { Read-BridgeAudioSettings -Path $audioPath } '音量 JSON 的重复、未知、指数、版本、范围和类型错误应拒绝'
    }
    Assert-Throws { ConvertTo-BridgeGainMilli -Value '1,25' -Label 'gain' } '本机增益参数使用 invariant 小数点'
    Assert-Throws { ConvertTo-BridgeGainMilli -Value '16.001' -Label 'gain' } '增益超范围应拒绝'

    $legacyPassword = Join-Path $temporaryRoot 'private\bm-device-password.txt'
    $passwordPath = Get-BridgePasswordFile -UserConfigDirectory $configPath
    Assert-True ([string]::IsNullOrWhiteSpace($passwordPath)) '缺少默认凭据时 manual 路径保留隐藏输入流程'
    [System.IO.File]::WriteAllText($legacyPassword, 'fixture')
    $passwordPath = Get-BridgePasswordFile -UserConfigDirectory $configPath
    Assert-True ($passwordPath -ceq $legacyPassword) '仅返回同目录父层的密码文件路径'
    [System.IO.File]::WriteAllText((Join-Path $configPath 'password-file-path.txt'), '..\missing.txt')
    Assert-Throws { Get-BridgePasswordFile -UserConfigDirectory $configPath } '显式保存的相对凭据路径缺失时应提示修复'

    Write-Host '通过：本机配置目录、相对版本指针、跨版本音量与密码路径检查。未启动核心或访问设备。'
} finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    Remove-Module -Name bridge-user-config -ErrorAction SilentlyContinue
}
