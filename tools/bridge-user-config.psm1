Set-StrictMode -Version Latest

function Get-BridgeUserConfigDirectory {
    param(
        [string]$UserConfigDirectory,
        [Parameter(Mandatory=$true)][string]$ScriptRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
        $candidate = $UserConfigDirectory
    } elseif ([System.IO.Path]::GetFileName($ScriptRoot.TrimEnd('\', '/')) -ieq 'tools') {
        $candidate = Join-Path (Split-Path -Parent $ScriptRoot) 'private\user-config'
    } else {
        $candidate = Join-Path $ScriptRoot 'private\user-config'
    }
    try { $fullPath = [System.IO.Path]::GetFullPath($candidate) }
    catch { throw '本机用户配置目录路径无效。' }
    if (-not [System.IO.Directory]::Exists($fullPath)) {
        [System.IO.Directory]::CreateDirectory($fullPath) | Out-Null
    }
    return $fullPath
}

function Get-BridgeReleaseDirectory {
    param([Parameter(Mandatory=$true)][string]$UserConfigDirectory)
    $pointerPath = Join-Path $UserConfigDirectory 'bridge-directory.txt'
    if (-not [System.IO.File]::Exists($pointerPath)) {
        throw "缺少本机版本目录指针：$pointerPath。请在该文件写入当前便携目录的完整路径。"
    }
    $lines = [System.IO.File]::ReadAllLines($pointerPath, [System.Text.Encoding]::UTF8)
    if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
        throw 'bridge-directory.txt 必须只有一行完整目录路径。'
    }
    $releaseValue = $lines[0].Trim()
    $releaseCandidate = if ([System.IO.Path]::IsPathRooted($releaseValue)) {
        $releaseValue
    } else {
        Join-Path $UserConfigDirectory $releaseValue
    }
    try { $fullPath = [System.IO.Path]::GetFullPath($releaseCandidate) }
    catch { throw 'bridge-directory.txt 中的目录路径无效。' }
    if (-not [System.IO.Directory]::Exists($fullPath)) {
        throw "便携目录不存在：$fullPath。请更新 bridge-directory.txt 后重试。"
    }
    foreach ($requiredFile in @('start-bm-radio-bridge.ps1', 'wirex_bridge.exe')) {
        if (-not [System.IO.File]::Exists((Join-Path $fullPath $requiredFile))) {
            throw "所选便携目录缺少 $requiredFile：$fullPath"
        }
    }
    return $fullPath
}

function Get-BridgePasswordFile {
    param(
        [Parameter(Mandatory=$true)][string]$UserConfigDirectory,
        [string]$ExplicitPath
    )
    $candidate = $ExplicitPath
    $requiredPath = -not [string]::IsNullOrWhiteSpace($ExplicitPath)
    $pathBase = $null
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $pointer = Join-Path $UserConfigDirectory 'password-file-path.txt'
        if ([System.IO.File]::Exists($pointer)) {
            $lines = [System.IO.File]::ReadAllLines($pointer, [System.Text.Encoding]::UTF8)
            if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
                throw 'password-file-path.txt 必须只有一行完整文件路径。'
            }
            $candidate = $lines[0].Trim()
            $requiredPath = $true
            $pathBase = $UserConfigDirectory
        } else {
            $candidate = Join-Path (Split-Path -Parent $UserConfigDirectory) 'bm-device-password.txt'
        }
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }
    $passwordCandidate = if ($pathBase -and -not [System.IO.Path]::IsPathRooted($candidate)) {
        Join-Path $pathBase $candidate
    } else { $candidate }
    try { $fullPath = [System.IO.Path]::GetFullPath($passwordCandidate) }
    catch { throw '本机密码文件路径无效。' }
    if (-not [System.IO.File]::Exists($fullPath)) {
        if (-not $requiredPath) { return '' }
        throw "本机密码文件不存在：$fullPath。请在设置中选择密码文件。"
    }
    return $fullPath
}

function ConvertTo-BridgeGainMilli {
    param([Parameter(Mandatory=$true)][object]$Value, [Parameter(Mandatory=$true)][string]$Label)
    $text = if ($Value -is [string]) { $Value } else {
        ([decimal]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($text -cnotmatch '^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?$') {
        throw "$Label 必须是使用小数点的十进制数，最多 3 位小数。"
    }
    $gain = [decimal]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
    if ($gain -lt [decimal]0.25 -or $gain -gt [decimal]16) {
        throw "$Label 必须在 0.25 到 16.0 之间。"
    }
    return [uint32]($gain * 1000)
}

function Format-BridgeGain {
    param([Parameter(Mandatory=$true)][uint32]$GainMilli)
    $whole = [math]::Floor($GainMilli / 1000)
    $fraction = $GainMilli % 1000
    if ($fraction -eq 0) { return $whole.ToString([Globalization.CultureInfo]::InvariantCulture) }
    return $whole.ToString([Globalization.CultureInfo]::InvariantCulture) + '.' +
        $fraction.ToString('D3', [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0')
}

function Read-BridgeAudioSettings {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) { return $null }
    if ((New-Object System.IO.FileInfo($fullPath)).Length -gt 4096) { throw '本机音量设置超过 4 KiB。' }
    $json = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    $expectedNames = @('schema_version', 'radio_playback_gain', 'mic_transmit_gain')
    $keyMatches = [regex]::Matches($json, '"(?<key>[^"\\]+)"\s*:')
    if ($keyMatches.Count -ne $expectedNames.Count) { throw '本机音量设置必须且只能包含三个已知字段。' }
    foreach ($name in $expectedNames) {
        if (@($keyMatches | Where-Object { $_.Groups['key'].Value -ceq $name }).Count -ne 1) {
            throw "本机音量设置字段 $name 缺失、重复或大小写不正确。"
        }
    }
    foreach ($match in $keyMatches) {
        if ($expectedNames -cnotcontains $match.Groups['key'].Value) { throw '本机音量设置包含未知字段。' }
    }
    try { $document = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
    catch { throw '本机音量设置 JSON 无效。' }
    if ($null -eq $document -or $document -is [array] -or $document -is [string] -or $document -is [bool]) {
        throw '本机音量设置必须是 JSON 对象。'
    }
    $schema = [regex]::Matches($json, '"schema_version"\s*:\s*(?<value>[^,}\s]+)')
    $radio = [regex]::Matches($json, '"radio_playback_gain"\s*:\s*(?<value>[^,}\s]+)')
    $mic = [regex]::Matches($json, '"mic_transmit_gain"\s*:\s*(?<value>[^,}\s]+)')
    if ($schema.Count -ne 1 -or $schema[0].Groups['value'].Value -cne '1') { throw '本机音量设置版本不受支持。' }
    if ($radio.Count -ne 1 -or $mic.Count -ne 1) { throw '本机音量设置数字字段无效。' }
    return [pscustomobject]@{
        SchemaVersion = 1
        RadioPlaybackGainMilli = ConvertTo-BridgeGainMilli -Value $radio[0].Groups['value'].Value -Label 'radio_playback_gain'
        MicTransmitGainMilli = ConvertTo-BridgeGainMilli -Value $mic[0].Groups['value'].Value -Label 'mic_transmit_gain'
    }
}

function Write-BridgeAudioSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][uint32]$RadioPlaybackGainMilli,
        [Parameter(Mandatory=$true)][uint32]$MicTransmitGainMilli
    )
    if ($RadioPlaybackGainMilli -lt 250 -or $RadioPlaybackGainMilli -gt 16000 -or
        $MicTransmitGainMilli -lt 250 -or $MicTransmitGainMilli -gt 16000) {
        throw '音量设置必须在 0.25 到 16.0 之间。'
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw "音量设置目录不存在：$directory" }
    $temporaryPath = $fullPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backupPath = $fullPath + '.bak-' + [guid]::NewGuid().ToString('N')
    $content = "{`n  `"schema_version`": 1,`n  `"radio_playback_gain`": $(Format-BridgeGain -GainMilli $RadioPlaybackGainMilli),`n  `"mic_transmit_gain`": $(Format-BridgeGain -GainMilli $MicTransmitGainMilli)`n}`n"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $content, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
        if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
    }
}

function Get-BridgeAudioSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$LegacyPath,
        [string]$RadioPlaybackGain,
        [string]$MicTransmitGain
    )
    $settings = Read-BridgeAudioSettings -Path $Path
    $save = $false
    if ($null -eq $settings -and $LegacyPath -and [System.IO.File]::Exists($LegacyPath)) {
        $settings = Read-BridgeAudioSettings -Path $LegacyPath
        $save = $true
    }
    if ($null -eq $settings) {
        $settings = [pscustomobject]@{ SchemaVersion = 1; RadioPlaybackGainMilli = [uint32]1000; MicTransmitGainMilli = [uint32]16000 }
        $save = $true
    }
    if ($PSBoundParameters.ContainsKey('RadioPlaybackGain')) {
        $settings.RadioPlaybackGainMilli = ConvertTo-BridgeGainMilli -Value $RadioPlaybackGain -Label '-RadioPlaybackGain'
        $save = $true
    }
    if ($PSBoundParameters.ContainsKey('MicTransmitGain')) {
        $settings.MicTransmitGainMilli = ConvertTo-BridgeGainMilli -Value $MicTransmitGain -Label '-MicTransmitGain'
        $save = $true
    }
    if ($save) {
        Write-BridgeAudioSettings -Path $Path -RadioPlaybackGainMilli $settings.RadioPlaybackGainMilli `
            -MicTransmitGainMilli $settings.MicTransmitGainMilli
    }
    return $settings
}

Export-ModuleMember -Function Get-BridgeUserConfigDirectory, Get-BridgeReleaseDirectory, Get-BridgePasswordFile, `
    ConvertTo-BridgeGainMilli, Format-BridgeGain, Read-BridgeAudioSettings, Write-BridgeAudioSettings, Get-BridgeAudioSettings
