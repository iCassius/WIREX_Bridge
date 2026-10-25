[CmdletBinding()]
param(
    [string]$UserConfigDirectory,
    [string]$PasswordFile,
    [string]$RadioPlaybackGain,
    [string]$MicTransmitGain,
    [ValidateSet('manual', 'parrot-cn', 'parrot-global', 'listen-46001', 'listen-91')]
    [string]$Preset = 'manual'
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'bridge-user-config.psm1'
try {
    if (-not [System.IO.File]::Exists($modulePath)) { throw "缺少用户配置模块：$modulePath" }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $configDirectory = Get-BridgeUserConfigDirectory -UserConfigDirectory $UserConfigDirectory -ScriptRoot $PSScriptRoot
    $releaseDirectory = Get-BridgeReleaseDirectory -UserConfigDirectory $configDirectory
    $releaseLauncher = Join-Path $releaseDirectory 'start-bm-radio-bridge.ps1'
    $profilePath = Join-Path $configDirectory 'connection-profile.json'
    $audioSettingsPath = Join-Path $configDirectory 'audio-settings.json'
    $legacyAudioPath = Join-Path $releaseDirectory 'audio-settings.json'

    $audioArguments = @{ Path = $audioSettingsPath; LegacyPath = $legacyAudioPath }
    if ($PSBoundParameters.ContainsKey('RadioPlaybackGain')) { $audioArguments.RadioPlaybackGain = $RadioPlaybackGain }
    if ($PSBoundParameters.ContainsKey('MicTransmitGain')) { $audioArguments.MicTransmitGain = $MicTransmitGain }
    $audio = Get-BridgeAudioSettings @audioArguments
    $passwordPath = Get-BridgePasswordFile -UserConfigDirectory $configDirectory -ExplicitPath $PasswordFile
    if ($Preset -cne 'manual' -and [string]::IsNullOrWhiteSpace($passwordPath)) {
        throw '固定预设需要本机密码文件；请在设置中选择现有密码文件。'
    }

    $childArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $releaseLauncher,
        '-Preset', $Preset,
        '-ConnectionProfilePath', $profilePath,
        '-RadioPlaybackGain', (Format-BridgeGain -GainMilli $audio.RadioPlaybackGainMilli),
        '-MicTransmitGain', (Format-BridgeGain -GainMilli $audio.MicTransmitGainMilli)
    )
    if (-not [string]::IsNullOrWhiteSpace($passwordPath)) {
        $childArguments += @('-PasswordFile', $passwordPath)
    }
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not [System.IO.File]::Exists($powerShellExe)) { throw '找不到 Windows PowerShell 5.1。' }

    Write-Host '启动所选版本并使用本机连接配置。'
    Write-Host ("版本目录：{0}" -f $releaseDirectory)
    Write-Host '音量设置已保存到本机用户配置目录。'
    & $powerShellExe @childArguments
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0) { Write-Host "核心已退出，退出码：$exitCode" -ForegroundColor Yellow }
    exit $exitCode
} catch {
    Write-Host ("启动检查失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 2
}
