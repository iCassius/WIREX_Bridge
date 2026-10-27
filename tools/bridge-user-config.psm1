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

function Assert-BridgeJsonKeysUnique {
    param([Parameter(Mandatory=$true)][string]$JsonText)
    $objects = New-Object System.Collections.ArrayList
    $index = 0
    while ($index -lt $JsonText.Length) {
        $character = $JsonText[$index]
        if ($character -eq '{') {
            $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            [void]$objects.Add($keys)
            $index++
            continue
        }
        if ($character -eq '}') {
            if ($objects.Count -eq 0) { throw '连接配置 JSON 对象结构无效。' }
            $objects.RemoveAt($objects.Count - 1)
            $index++
            continue
        }
        if ($character -ne '"') { $index++; continue }
        $start = $index + 1
        $cursor = $start
        $escaped = $false
        while ($cursor -lt $JsonText.Length) {
            $part = $JsonText[$cursor]
            if ($escaped) { $escaped = $false; $cursor++; continue }
            if ($part -eq '\') { $escaped = $true; $cursor++; continue }
            if ($part -eq '"') { break }
            $cursor++
        }
        if ($cursor -ge $JsonText.Length) { throw '连接配置 JSON 字符串没有闭合。' }
        $rawString = $JsonText.Substring($start, $cursor - $start)
        $after = $cursor + 1
        while ($after -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$after])) { $after++ }
        if ($objects.Count -gt 0 -and $after -lt $JsonText.Length -and $JsonText[$after] -eq ':') {
            if ($rawString.Contains('\')) { throw '连接配置 JSON 字段名不能使用转义写法。' }
            $keys = [System.Collections.Generic.HashSet[string]]$objects[$objects.Count - 1]
            if (-not $keys.Add($rawString)) { throw "连接配置 JSON 字段重复：$rawString" }
        }
        $index = $cursor + 1
    }
    if ($objects.Count -ne 0) { throw '连接配置 JSON 对象结构无效。' }
}

function Assert-BridgeExactJsonObject {
    param([Parameter(Mandatory=$true)][object]$Value, [Parameter(Mandatory=$true)][string[]]$ExpectedNames, [Parameter(Mandatory=$true)][string]$Label)
    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) {
        throw "$Label 必须是 JSON 对象。"
    }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -ne $ExpectedNames.Count) { throw "$Label 字段不完整或包含未知字段。" }
    foreach ($property in $properties) {
        if ($ExpectedNames -cnotcontains $property.Name) { throw "$Label 包含未知字段：$($property.Name)" }
    }
    foreach ($name in $ExpectedNames) {
        if (@($properties | Where-Object { $_.Name -ceq $name }).Count -ne 1) { throw "$Label 缺少字段或字段重复：$name" }
    }
}

function ConvertTo-BridgeUnsigned {
    param([Parameter(Mandatory=$true)][object]$Value, [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][uint64]$Maximum, [switch]$AllowText)
    $integerTypes = @([byte], [uint16], [uint32], [uint64], [int16], [int32], [int64])
    if ($AllowText -and $Value -is [string]) {
        if ($Value -cnotmatch '^(0|[1-9][0-9]*)$') { throw "$Label 必须是十进制非负整数。" }
        $parsed = [uint64]0
        if (-not [uint64]::TryParse([string]$Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { throw "$Label 超出整数范围。" }
    } else {
        if (($integerTypes -notcontains $Value.GetType()) -or ($Value -is [bool])) { throw "$Label 必须是 JSON 整数。" }
        try { $parsed = [uint64]$Value } catch { throw "$Label 必须是非负整数。" }
    }
    if ($parsed -gt $Maximum) { throw "$Label 超出整数范围。" }
    return $parsed
}

function Test-BridgeMasterName {
    param([Parameter(Mandatory=$true)][string]$HostName)
    if ($HostName.Length -lt 1 -or $HostName.Length -gt 253 -or $HostName -cnotmatch '^[\x21-\x7e]+$') { return $false }
    if ($HostName -cmatch '^[0-9.]+$' -and $HostName -cnotmatch '^[0-9]+(?:\.[0-9]+){3}$') { return $false }
    if ($HostName -cmatch '^[0-9]+(?:\.[0-9]+){3}$') {
        foreach ($part in $HostName.Split('.')) {
            if ($part.Length -gt 3) { return $false }
            $octet = [uint64]0
            if (-not [uint64]::TryParse($part, [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$octet) -or $octet -gt 255) { return $false }
        }
        return $true
    }
    $normalized = if ($HostName.EndsWith('.')) { $HostName.Substring(0, $HostName.Length - 1) } else { $HostName }
    if ([string]::IsNullOrEmpty($normalized)) { return $false }
    foreach ($label in $normalized.Split('.')) {
        if ($label -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') { return $false }
    }
    return $true
}

function ConvertTo-BridgeUserConnectionProfile {
    param([Parameter(Mandatory=$true)][object]$Connection, [Parameter(Mandatory=$true)][object]$Devices,
        [object]$TxTarget, [object]$RxPolicy, [object]$Receive, [object]$TransmitEnabled,
        [switch]$AllowTextNumbers)
    if (($null -eq $TxTarget) -xor ($null -eq $RxPolicy)) { throw 'schema 2 必须同时提供 tx_target 和完整 rx_policy。' }
    if ($null -eq $TxTarget) {
        return ConvertTo-BridgeLegacyConnectionProfile -Connection $Connection -Devices $Devices `
            -Receive $Receive -TransmitEnabled $TransmitEnabled -AllowTextNumbers:$AllowTextNumbers
    }
    return ConvertTo-BridgeV2ConnectionProfile -Connection $Connection -Devices $Devices -TxTarget $TxTarget `
        -RxPolicy $RxPolicy -TransmitEnabled $TransmitEnabled -AllowTextNumbers:$AllowTextNumbers
}

function ConvertTo-BridgeLegacyConnectionProfile {
    param([Parameter(Mandatory=$true)][object]$Connection, [Parameter(Mandatory=$true)][object]$Devices,
        [object]$Receive, [object]$TransmitEnabled, [switch]$AllowTextNumbers)
    Assert-BridgeExactJsonObject -Value $Connection -ExpectedNames @('callsign','gateway_id','source_id','master','master_port','destination_id','slot','color_code','call_kind') -Label 'schema_version 1 connection'
    if ($Connection.call_kind -isnot [string] -or @('group','private') -cnotcontains $Connection.call_kind) { throw 'schema_version 1 connection.call_kind 只能是 group 或 private。' }
    if ($null -ne $Receive) {
        Assert-BridgeExactJsonObject -Value $Receive -ExpectedNames @('destination_id','slot','call_kind') -Label 'schema_version 1 receive'
        if ($Receive.call_kind -isnot [string] -or @('group','private') -cnotcontains $Receive.call_kind) { throw 'schema_version 1 receive.call_kind 只能是 group 或 private。' }
        $receiveDestination = $Receive.destination_id; $receiveSlot = $Receive.slot; $receiveKind = $Receive.call_kind
    } else {
        $receiveDestination = if ($Connection.call_kind -ceq 'private') { $Connection.source_id } else { $Connection.destination_id }
        $receiveSlot = $Connection.slot; $receiveKind = $Connection.call_kind
    }
    $txTarget = [pscustomobject][ordered]@{ destination_id=$Connection.destination_id; kind=$Connection.call_kind; slot=$Connection.slot }
    if ($receiveKind -ceq 'group') {
        $rxPolicy = [pscustomobject][ordered]@{
            group_mode='selected'; private_mode='disabled'
            allow_groups=@([pscustomobject][ordered]@{ destination_id=$receiveDestination; slot=$receiveSlot })
            allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
        }
    } else {
        $rxPolicy = [pscustomobject][ordered]@{
            group_mode='selected'; private_mode='all_peers_to_local'; allow_groups=@(); allow_private_peers=@()
            local_private_routes=@([pscustomobject][ordered]@{ local_destination_id=$receiveDestination; slot=$receiveSlot })
            blocked_groups=@(); blocked_source_ids=@()
        }
    }
    $enabled = if ($null -eq $TransmitEnabled) { $true } else { $TransmitEnabled }
    $sourceId = ConvertTo-BridgeUnsigned $Connection.source_id 'connection.source_id' 16777215 -AllowText:$AllowTextNumbers
    $txDestination = ConvertTo-BridgeUnsigned $Connection.destination_id 'connection.destination_id' 16777215 -AllowText:$AllowTextNumbers
    $txSlot = ConvertTo-BridgeUnsigned $Connection.slot 'connection.slot' 2 -AllowText:$AllowTextNumbers
    if ($enabled -and $Connection.call_kind -ceq 'private' -and
        -not ($receiveKind -ceq 'private' -and [uint64]$receiveDestination -eq [uint64]$sourceId -and
              [uint64]$receiveSlot -eq [uint64]$txSlot)) {
        $rxPolicy.allow_private_peers = @([pscustomobject][ordered]@{
            source_id=[uint64]$txDestination; local_destination_id=[uint64]$sourceId; slot=[uint64]$txSlot
        })
        if ($rxPolicy.private_mode -ceq 'disabled') { $rxPolicy.private_mode='selected_peers' }
    }
    $connectionV2 = [pscustomobject][ordered]@{
        callsign=$Connection.callsign; gateway_id=$Connection.gateway_id; source_id=$Connection.source_id
        master=$Connection.master; master_port=$Connection.master_port; color_code=$Connection.color_code
    }
    return ConvertTo-BridgeV2ConnectionProfile -Connection $connectionV2 -Devices $Devices -TxTarget $txTarget `
        -RxPolicy $rxPolicy -TransmitEnabled $enabled -AllowTextNumbers:$AllowTextNumbers
}

function ConvertTo-BridgeV2ConnectionProfile {
    param([Parameter(Mandatory=$true)][object]$Connection, [Parameter(Mandatory=$true)][object]$Devices,
        [Parameter(Mandatory=$true)][object]$TxTarget, [Parameter(Mandatory=$true)][object]$RxPolicy,
        [Parameter(Mandatory=$true)][object]$TransmitEnabled, [switch]$AllowTextNumbers)
    Assert-BridgeExactJsonObject -Value $Connection -ExpectedNames @('callsign','gateway_id','source_id','master','master_port','color_code') -Label 'connection'
    Assert-BridgeExactJsonObject -Value $Devices -ExpectedNames @('serial_port','wave_in_endpoint_id','wave_out_endpoint_id') -Label 'devices'
    Assert-BridgeExactJsonObject -Value $TxTarget -ExpectedNames @('destination_id','kind','slot') -Label 'tx_target'
    Assert-BridgeExactJsonObject -Value $RxPolicy -ExpectedNames @('group_mode','private_mode','allow_groups','allow_private_peers','local_private_routes','blocked_groups','blocked_source_ids') -Label 'rx_policy'
    if ($Connection.callsign -isnot [string] -or $Connection.callsign -cnotmatch '^[\x20-\x7e]{1,8}$') { throw 'connection.callsign 必须是 1 到 8 个可打印 ASCII 字符。' }
    if ($Connection.master -isnot [string] -or -not (Test-BridgeMasterName -HostName $Connection.master)) { throw 'connection.master 必须是有效 IPv4 地址或语法正确的 ASCII 主机名。' }
    if ($TxTarget.kind -isnot [string] -or @('group','private') -cnotcontains $TxTarget.kind) { throw 'tx_target.kind 只能是 group 或 private。' }
    if ($RxPolicy.group_mode -isnot [string] -or @('selected','all_delivered') -cnotcontains $RxPolicy.group_mode) { throw 'rx_policy.group_mode 只能是 selected 或 all_delivered。' }
    if ($RxPolicy.private_mode -isnot [string] -or @('disabled','selected_peers','all_peers_to_local') -cnotcontains $RxPolicy.private_mode) { throw 'rx_policy.private_mode 值无效。' }
    if ($TransmitEnabled -isnot [bool]) { throw 'transmit_enabled 必须是 JSON 布尔值。' }
    $gateway = ConvertTo-BridgeUnsigned $Connection.gateway_id 'connection.gateway_id' 4294967295 -AllowText:$AllowTextNumbers
    $source = ConvertTo-BridgeUnsigned $Connection.source_id 'connection.source_id' 16777215 -AllowText:$AllowTextNumbers
    $masterPort = ConvertTo-BridgeUnsigned $Connection.master_port 'connection.master_port' 65535 -AllowText:$AllowTextNumbers
    $colorCode = ConvertTo-BridgeUnsigned $Connection.color_code 'connection.color_code' 15 -AllowText:$AllowTextNumbers
    $destination = ConvertTo-BridgeUnsigned $TxTarget.destination_id 'tx_target.destination_id' 16777215 -AllowText:$AllowTextNumbers
    $slot = ConvertTo-BridgeUnsigned $TxTarget.slot 'tx_target.slot' 2 -AllowText:$AllowTextNumbers
    if ($gateway -eq 0 -or $source -eq 0 -or $masterPort -eq 0 -or $destination -eq 0 -or $slot -lt 1) { throw '连接配置中的 ID、端口或时隙超出允许范围。' }
    if ($Devices.serial_port -isnot [string] -or ($Devices.serial_port -cne 'auto' -and $Devices.serial_port -cnotmatch '^COM[1-9][0-9]{0,2}$')) { throw 'devices.serial_port 必须是 auto 或 COM1 到 COM999。' }
    foreach ($endpoint in @($Devices.wave_in_endpoint_id, $Devices.wave_out_endpoint_id)) {
        if ($endpoint -isnot [string] -or [string]::IsNullOrWhiteSpace($endpoint) -or $endpoint.Length -gt 4096) { throw '音频设备选择必须是 auto 或有效 endpoint ID。' }
    }
    foreach ($name in @('allow_groups','allow_private_peers','local_private_routes','blocked_groups','blocked_source_ids')) {
        $property = $RxPolicy.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value -or $property.Value -isnot [array]) { throw "rx_policy.$name 必须是 JSON 数组。" }
    }
    $groups = New-Object 'System.Collections.Generic.List[object]'; $peers = New-Object 'System.Collections.Generic.List[object]'
    $localRoutes = New-Object 'System.Collections.Generic.List[object]'; $blockedGroups = New-Object 'System.Collections.Generic.List[object]'
    $blockedSources = New-Object 'System.Collections.Generic.List[uint64]'
    $groupKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $peerKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $localKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $blockedGroupKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $blockedSourceKeys = New-Object 'System.Collections.Generic.HashSet[uint64]'
    foreach ($item in @($RxPolicy.allow_groups)) {
        Assert-BridgeExactJsonObject -Value $item -ExpectedNames @('destination_id','slot') -Label 'rx_policy.allow_groups 项'
        $id = ConvertTo-BridgeUnsigned $item.destination_id 'rx_policy.allow_groups.destination_id' 16777215 -AllowText:$AllowTextNumbers
        $itemSlot = ConvertTo-BridgeUnsigned $item.slot 'rx_policy.allow_groups.slot' 2 -AllowText:$AllowTextNumbers
        if ($id -eq 0 -or $itemSlot -lt 1) { throw 'rx_policy.allow_groups 中的 ID 或时隙超出允许范围。' }
        $key = "$id/$itemSlot"; if (-not $groupKeys.Add($key)) { throw "rx_policy.allow_groups 重复项：$key" }
        $groups.Add([pscustomobject][ordered]@{ destination_id=[uint64]$id; slot=[uint64]$itemSlot })
    }
    foreach ($item in @($RxPolicy.allow_private_peers)) {
        Assert-BridgeExactJsonObject -Value $item -ExpectedNames @('source_id','local_destination_id','slot') -Label 'rx_policy.allow_private_peers 项'
        $peer = ConvertTo-BridgeUnsigned $item.source_id 'rx_policy.allow_private_peers.source_id' 16777215 -AllowText:$AllowTextNumbers
        $local = ConvertTo-BridgeUnsigned $item.local_destination_id 'rx_policy.allow_private_peers.local_destination_id' 16777215 -AllowText:$AllowTextNumbers
        $itemSlot = ConvertTo-BridgeUnsigned $item.slot 'rx_policy.allow_private_peers.slot' 2 -AllowText:$AllowTextNumbers
        if ($peer -eq 0 -or $local -eq 0 -or $itemSlot -lt 1) { throw 'rx_policy.allow_private_peers 中的 ID 或时隙超出允许范围。' }
        $key = "$peer/$local/$itemSlot"; if (-not $peerKeys.Add($key)) { throw "rx_policy.allow_private_peers 重复项：$key" }
        $peers.Add([pscustomobject][ordered]@{ source_id=[uint64]$peer; local_destination_id=[uint64]$local; slot=[uint64]$itemSlot })
    }
    foreach ($item in @($RxPolicy.local_private_routes)) {
        Assert-BridgeExactJsonObject -Value $item -ExpectedNames @('local_destination_id','slot') -Label 'rx_policy.local_private_routes 项'
        $local = ConvertTo-BridgeUnsigned $item.local_destination_id 'rx_policy.local_private_routes.local_destination_id' 16777215 -AllowText:$AllowTextNumbers
        $itemSlot = ConvertTo-BridgeUnsigned $item.slot 'rx_policy.local_private_routes.slot' 2 -AllowText:$AllowTextNumbers
        if ($local -eq 0 -or $itemSlot -lt 1) { throw 'rx_policy.local_private_routes 中的 ID 或时隙超出允许范围。' }
        $key = "$local/$itemSlot"; if (-not $localKeys.Add($key)) { throw "rx_policy.local_private_routes 重复项：$key" }
        $localRoutes.Add([pscustomobject][ordered]@{ local_destination_id=[uint64]$local; slot=[uint64]$itemSlot })
    }
    foreach ($item in @($RxPolicy.blocked_groups)) {
        Assert-BridgeExactJsonObject -Value $item -ExpectedNames @('destination_id','slot') -Label 'rx_policy.blocked_groups 项'
        $id = ConvertTo-BridgeUnsigned $item.destination_id 'rx_policy.blocked_groups.destination_id' 16777215 -AllowText:$AllowTextNumbers
        $itemSlot = ConvertTo-BridgeUnsigned $item.slot 'rx_policy.blocked_groups.slot' 2 -AllowText:$AllowTextNumbers
        if ($id -eq 0 -or $itemSlot -lt 1) { throw 'rx_policy.blocked_groups 中的 ID 或时隙超出允许范围。' }
        $key = "$id/$itemSlot"; if (-not $blockedGroupKeys.Add($key)) { throw "rx_policy.blocked_groups 重复项：$key" }
        $blockedGroups.Add([pscustomobject][ordered]@{ destination_id=[uint64]$id; slot=[uint64]$itemSlot })
    }
    foreach ($value in @($RxPolicy.blocked_source_ids)) {
        $id = ConvertTo-BridgeUnsigned $value 'rx_policy.blocked_source_ids 项' 16777215 -AllowText:$AllowTextNumbers
        if ($id -eq 0 -or -not $blockedSourceKeys.Add([uint64]$id)) { throw 'rx_policy.blocked_source_ids 含零值或重复 ID。' }
        $blockedSources.Add([uint64]$id)
    }
    foreach ($route in $localRoutes) {
        if ([uint64]$route.local_destination_id -ne [uint64]$source) {
            throw 'rx_policy.local_private_routes.local_destination_id 必须等于 connection.source_id；旧配置使用其它本地目标时需先修正。'
        }
    }
    foreach ($peer in $peers) {
        if ([uint64]$peer.local_destination_id -ne [uint64]$source) {
            throw 'rx_policy.allow_private_peers.local_destination_id 必须等于 connection.source_id。'
        }
    }
    foreach ($key in $groupKeys) { if ($blockedGroupKeys.Contains($key)) { throw "组呼频道同时位于 allow 和 block：$key" } }
    if ($RxPolicy.private_mode -ceq 'disabled' -and ($peers.Count -ne 0 -or $localRoutes.Count -ne 0)) { throw 'private_mode=disabled 时私呼路由列表必须为空。' }
    if ($RxPolicy.private_mode -ceq 'selected_peers' -and $localRoutes.Count -ne 0) { throw 'private_mode=selected_peers 时 local_private_routes 必须为空。' }
    $validated = [ordered]@{
        schema_version=2
        connection=[pscustomobject][ordered]@{ callsign=$Connection.callsign; gateway_id=[uint64]$gateway; source_id=[uint64]$source; master=$Connection.master; master_port=[uint64]$masterPort; color_code=[uint64]$colorCode }
        tx_target=[pscustomobject][ordered]@{ destination_id=[uint64]$destination; kind=$TxTarget.kind; slot=[uint64]$slot }
        devices=[pscustomobject][ordered]@{ serial_port=($Devices.serial_port.ToUpperInvariant() -replace '^AUTO$','auto'); wave_in_endpoint_id=$Devices.wave_in_endpoint_id; wave_out_endpoint_id=$Devices.wave_out_endpoint_id }
        rx_policy=[pscustomobject][ordered]@{ group_mode=$RxPolicy.group_mode; private_mode=$RxPolicy.private_mode; allow_groups=[object[]]$groups.ToArray(); allow_private_peers=[object[]]$peers.ToArray(); local_private_routes=[object[]]$localRoutes.ToArray(); blocked_groups=[object[]]$blockedGroups.ToArray(); blocked_source_ids=[uint64[]]$blockedSources.ToArray() }
        transmit_enabled=[bool]$TransmitEnabled
    }
    return [pscustomobject]$validated
}

function Read-BridgeUserConnectionProfile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) { return $null }
    if ((New-Object System.IO.FileInfo($fullPath)).Length -gt 65536) { throw '连接配置文件超过 64 KiB 上限。' }
    $json = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    Assert-BridgeJsonKeysUnique -JsonText $json
    try { $document = ConvertFrom-Json -InputObject $json -ErrorAction Stop } catch { throw '连接配置 JSON 无效。' }
    if ($null -eq $document -or $document -is [array] -or $document -is [string] -or $document -is [bool]) { throw '连接配置必须是 JSON 对象。' }
    $versionProperty = $document.PSObject.Properties['schema_version']
    if ($null -eq $versionProperty) { throw '连接配置缺少 schema_version。' }
    $version = ConvertTo-BridgeUnsigned $versionProperty.Value 'schema_version' 2
    if ($version -eq 1) {
        $expectedNames = @('schema_version','connection','devices','receive','transmit_enabled')
        $actualNames = @($document.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($actualNames.Count -lt 3 -or $actualNames.Count -gt $expectedNames.Count) { throw 'schema_version 1 配置字段不完整或包含未知字段。' }
        foreach ($name in $actualNames) { if ($expectedNames -cnotcontains $name) { throw "schema_version 1 配置包含未知字段：$name" } }
        foreach ($name in @('schema_version','connection','devices')) { if ($actualNames -cnotcontains $name) { throw "schema_version 1 配置缺少字段：$name" } }
        $arguments = @{ Connection=$document.connection; Devices=$document.devices }
        $receiveProperty = $document.PSObject.Properties['receive']
        if ($null -ne $receiveProperty) {
            if ($null -eq $receiveProperty.Value) { throw 'receive 存在时必须是完整对象。' }
            $arguments.Receive = $receiveProperty.Value
        }
        $transmitProperty = $document.PSObject.Properties['transmit_enabled']
        if ($null -ne $transmitProperty) {
            if ($transmitProperty.Value -isnot [bool]) { throw 'transmit_enabled 必须是 JSON 布尔值。' }
            $arguments.TransmitEnabled = $transmitProperty.Value
        }
        $profile = ConvertTo-BridgeLegacyConnectionProfile @arguments
    } elseif ($version -eq 2) {
        $expectedNames = @('schema_version','connection','tx_target','devices','rx_policy','transmit_enabled')
        $actualNames = @($document.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($actualNames.Count -ne $expectedNames.Count) { throw 'schema_version 2 配置字段不完整或包含未知字段。' }
        foreach ($name in $expectedNames) { if ($actualNames -cnotcontains $name) { throw "schema_version 2 配置缺少字段：$name" } }
        if ($document.transmit_enabled -isnot [bool]) { throw 'schema_version 2 transmit_enabled 必须是 JSON 布尔值。' }
        $profile = ConvertTo-BridgeV2ConnectionProfile -Connection $document.connection -TxTarget $document.tx_target `
            -Devices $document.devices -RxPolicy $document.rx_policy -TransmitEnabled $document.transmit_enabled
    } else { throw '连接配置只支持 schema_version 1 或 2。' }
    Add-Member -InputObject $profile -NotePropertyName migration_source_schema_version -NotePropertyValue ([int]$version) -Force
    return $profile
}

function Write-BridgeUserConnectionProfile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][object]$Profile)
    $validated = ConvertTo-BridgeV2ConnectionProfile -Connection $Profile.connection -TxTarget $Profile.tx_target `
        -Devices $Profile.devices -RxPolicy $Profile.rx_policy -TransmitEnabled $Profile.transmit_enabled
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw '本机连接配置目录不存在。' }
    $temporaryPath = $fullPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backupPath = $fullPath + '.bak-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    try {
        $json = (ConvertTo-Json -InputObject $validated -Depth 8) + "`n"
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($fullPath)) { [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath) }
        else { [System.IO.File]::Move($temporaryPath, $fullPath) }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
}

function Get-BridgeLegacyRuntimeProfile {
    param([Parameter(Mandatory=$true)][object]$Profile)
    $validated = ConvertTo-BridgeV2ConnectionProfile -Connection $Profile.connection -TxTarget $Profile.tx_target `
        -Devices $Profile.devices -RxPolicy $Profile.rx_policy -TransmitEnabled $Profile.transmit_enabled
    $policy = $validated.rx_policy
    if ($policy.group_mode -cne 'selected') { throw '当前alpha4运行链不支持 AllDelivered；此配置已保留并可预览，但现在不能启动。' }
    if ($policy.blocked_groups.Count -gt 0 -or $policy.blocked_source_ids.Count -gt 0) { throw '当前alpha4运行链不能完整执行组呼或发话源屏蔽；此配置已保留并可预览，但现在不能启动。' }
    if ($policy.allow_groups.Count -gt 1) { throw '当前alpha4运行链只支持一个 Selected 组呼；此配置已保留并可预览，但现在不能启动。' }
    if ($policy.local_private_routes.Count -gt 1) { throw '当前alpha4运行链只支持一个本机私呼接收路由；此配置已保留并可预览，但现在不能启动。' }
    if ([int]$policy.allow_groups.Count + [int]$policy.local_private_routes.Count -ne 1) {
        throw '当前alpha4运行链需要一个可表达的 Selected 组呼或本机私呼主接收路由；此配置现在不能启动。'
    }
    $tx = $validated.tx_target
    $returnIsCoveredByMainRoute = $false
    if ($tx.kind -ceq 'private' -and $validated.transmit_enabled) {
        if ($policy.private_mode -ceq 'all_peers_to_local' -and $policy.local_private_routes.Count -eq 1 -and
            [uint64]$policy.local_private_routes[0].local_destination_id -eq [uint64]$validated.connection.source_id -and
            [uint64]$policy.local_private_routes[0].slot -eq [uint64]$tx.slot) {
            $returnIsCoveredByMainRoute = $true
        }
        if (-not $returnIsCoveredByMainRoute -and $policy.allow_private_peers.Count -eq 0) {
            throw 'TX 私呼目标已启用，但 rx_policy 未明确允许精确回程；请加入发往本机 Source ID、来自当前 TX 目标且同一时隙的 peer 路由。'
        }
    }
    if ($policy.allow_private_peers.Count -gt 0) {
        $peer = $policy.allow_private_peers[0]
        if ($policy.allow_private_peers.Count -ne 1 -or $tx.kind -cne 'private' -or -not $validated.transmit_enabled -or
            [uint64]$peer.source_id -ne [uint64]$tx.destination_id -or
            [uint64]$peer.local_destination_id -ne [uint64]$validated.connection.source_id -or
            [uint64]$peer.slot -ne [uint64]$tx.slot) {
            throw '当前alpha4运行链只会额外接收发往本机 Source ID、来自当前私呼 TX 目标且同一时隙的精确回程；其它私呼 peer 此时不能启动。'
        }
    }
    if ($policy.allow_groups.Count -eq 1) {
        $route = [pscustomobject][ordered]@{ destination_id=$policy.allow_groups[0].destination_id; slot=$policy.allow_groups[0].slot; call_kind='group' }
    } else {
        $route = [pscustomobject][ordered]@{ destination_id=$policy.local_private_routes[0].local_destination_id; slot=$policy.local_private_routes[0].slot; call_kind='private' }
    }
    $connection = [pscustomobject][ordered]@{
        callsign=$validated.connection.callsign; gateway_id=$validated.connection.gateway_id; source_id=$validated.connection.source_id
        master=$validated.connection.master; master_port=$validated.connection.master_port
        destination_id=$validated.tx_target.destination_id; slot=$validated.tx_target.slot
        color_code=$validated.connection.color_code; call_kind=$validated.tx_target.kind
    }
    return [pscustomobject][ordered]@{
        schema_version=1; connection=$connection; devices=$validated.devices; receive=$route
        transmit_enabled=$validated.transmit_enabled
    }
}

Export-ModuleMember -Function Get-BridgeUserConfigDirectory, Get-BridgeReleaseDirectory, Get-BridgePasswordFile, `
    ConvertTo-BridgeGainMilli, Format-BridgeGain, Read-BridgeAudioSettings, Write-BridgeAudioSettings, Get-BridgeAudioSettings, `
    Read-BridgeUserConnectionProfile, Write-BridgeUserConnectionProfile, ConvertTo-BridgeUserConnectionProfile, Get-BridgeLegacyRuntimeProfile
