[CmdletBinding()]
param(
    [string]$BridgePath,
    [string]$BodyFile,
    [string]$Port,
    [string]$WaveIn,
    [string]$WaveOut,
    [string]$StatusDirectory,
    [string]$Preset,
    [string]$ConnectionProfilePath,
    [string]$AudioSettingsPath,
    [string]$PasswordFile,
    [string]$RadioPlaybackGain,
    [string]$MicTransmitGain,
    [switch]$ManualPtt,
    [switch]$PrepareOnly,
    [switch]$NoInteractive,
    [switch]$RequirePasswordFile,
    [string]$PreparationOutputPath
)

$ErrorActionPreference = 'Stop'
$script:packageRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:userConfigModule = Join-Path $PSScriptRoot 'bridge-user-config.psm1'
if (-not [System.IO.File]::Exists($script:userConfigModule)) { throw '缺少本机配置模块 bridge-user-config.psm1。' }
Import-Module -Name $script:userConfigModule -Force
$script:expectedBodyLength = 100
$script:expectedBodySha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:nativeInvoked = $false
$script:statusPath = ''
$script:serialSelectionWasManual = $false
$script:waveInSelectionWasManual = $false
$script:waveOutSelectionWasManual = $false

function ConvertTo-GainMilli {
    param([Parameter(Mandatory=$true)][string]$Text, [Parameter(Mandatory=$true)][string]$Label)
    if ($Text -notmatch '^([0-9]+)(?:\.([0-9]{1,3}))?$') {
        throw "$Label 必须是使用小数点的十进制数，最多 3 位小数。"
    }
    $whole = 0
    foreach ($character in $Matches[1].ToCharArray()) {
        $digit = [int]$character - [int][char]'0'
        if ($whole -gt 16 -or ($whole -eq 16 -and $digit -gt 0)) {
            throw "$Label 必须在 0.25 到 16.0 之间。"
        }
        $whole = ($whole * 10) + $digit
    }
    $fractionText = if ($Matches[2]) { $Matches[2].PadRight(3, '0') } else { '000' }
    $fraction = (([int][char]$fractionText[0] - [int][char]'0') * 100) +
        (([int][char]$fractionText[1] - [int][char]'0') * 10) +
        ([int][char]$fractionText[2] - [int][char]'0')
    $milli = ($whole * 1000) + $fraction
    if ($milli -lt 250 -or $milli -gt 16000) {
        throw "$Label 必须在 0.25 到 16.0 之间。"
    }
    return [uint32]$milli
}

function Format-GainDecimal {
    param([Parameter(Mandatory=$true)][uint32]$GainMilli)
    $whole = [math]::Floor($GainMilli / 1000)
    $fraction = $GainMilli % 1000
    if ($fraction -eq 0) { return $whole.ToString([Globalization.CultureInfo]::InvariantCulture) }
    $fractionText = $fraction.ToString('D3', [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0')
    return $whole.ToString([Globalization.CultureInfo]::InvariantCulture) + '.' + $fractionText
}

function Read-AudioSettings {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $null }
    try { $json = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8) }
    catch { throw "无法读取本机音量设置文件：$fullPath" }
    try { $document = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
    catch { throw "本机音量设置 JSON 无效：$fullPath" }
    if ($null -eq $document -or $document -is [array] -or $document -is [string] -or $document -is [bool]) {
        throw '本机音量设置必须是包含三个字段的 JSON 对象。'
    }
    $properties = @($document.PSObject.Properties)
    $expectedNames = @('schema_version', 'radio_playback_gain', 'mic_transmit_gain')
    if ($properties.Count -ne $expectedNames.Count) { throw '本机音量设置必须且只能包含 schema_version、radio_playback_gain、mic_transmit_gain。' }
    foreach ($property in $properties) {
        if ($expectedNames -cnotcontains $property.Name) { throw "本机音量设置包含未知字段：$($property.Name)" }
    }
    foreach ($name in $expectedNames) {
        $property = $document.PSObject.Properties[$name]
        if (-not $property) { throw "本机音量设置缺少字段：$name" }
        $value = $property.Value
        if ($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and
            $value -isnot [int64] -and $value -isnot [single] -and $value -isnot [double] -and
            $value -isnot [decimal]) {
            throw "本机音量设置字段 $name 必须是 JSON 数字。"
        }
    }

    $numberPattern = '(?<value>-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)(?=\s*[,}])'
    $tokens = @{}
    foreach ($name in $expectedNames) {
        $pattern = '"' + [regex]::Escape($name) + '"\s*:\s*' + $numberPattern
        $matches = [regex]::Matches($json, $pattern)
        if ($matches.Count -ne 1) { throw "本机音量设置字段 $name 必须只出现一次并使用 JSON 数字。" }
        $tokens[$name] = [string]$matches[0].Groups['value'].Value
    }
    if ($tokens['schema_version'] -cne '1') { throw '本机音量设置版本不受支持。' }
    return [pscustomobject]@{
        RadioPlaybackGainMilli = ConvertTo-GainMilli -Text $tokens['radio_playback_gain'] -Label 'radio_playback_gain'
        MicTransmitGainMilli = ConvertTo-GainMilli -Text $tokens['mic_transmit_gain'] -Label 'mic_transmit_gain'
    }
}

function Write-AudioSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][uint32]$RadioPlaybackGainMilli,
        [Parameter(Mandatory=$true)][uint32]$MicTransmitGainMilli
    )
    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if (-not [System.IO.Directory]::Exists($directory)) { throw "音量设置目录不存在：$directory" }
    $fullPath = [System.IO.Path]::Combine($directory, [System.IO.Path]::GetFileName($Path))
    $temporaryPath = $fullPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backupPath = $fullPath + '.bak-' + [guid]::NewGuid().ToString('N')
    $content = "{`n  `"schema_version`": 1,`n  `"radio_playback_gain`": $(Format-GainDecimal -GainMilli $RadioPlaybackGainMilli),`n  `"mic_transmit_gain`": $(Format-GainDecimal -GainMilli $MicTransmitGainMilli)`n}`n"
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

function Get-AudioSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [bool]$RadioPlaybackGainWasBound = $false,
        [string]$RadioPlaybackGainValue,
        [bool]$MicTransmitGainWasBound = $false,
        [string]$MicTransmitGainValue
    )
    $settings = Read-AudioSettings -Path $Path
    $save = $false
    if ($null -eq $settings) {
        $settings = [pscustomobject]@{ RadioPlaybackGainMilli = [uint32]1000; MicTransmitGainMilli = [uint32]16000 }
        $save = $true
    }
    if ($RadioPlaybackGainWasBound) {
        $settings.RadioPlaybackGainMilli = ConvertTo-GainMilli -Text $RadioPlaybackGainValue -Label '-RadioPlaybackGain'
        $save = $true
    }
    if ($MicTransmitGainWasBound) {
        $settings.MicTransmitGainMilli = ConvertTo-GainMilli -Text $MicTransmitGainValue -Label '-MicTransmitGain'
        $save = $true
    }
    if ($save) {
        Write-AudioSettings -Path $Path -RadioPlaybackGainMilli $settings.RadioPlaybackGainMilli `
            -MicTransmitGainMilli $settings.MicTransmitGainMilli
    }
    return $settings
}

function Resolve-AudioSettingsPath {
    param([string]$Path)
    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $script:packageRoot 'audio-settings.json'
    } else { $Path }
    try { $fullPath = [System.IO.Path]::GetFullPath($candidate) }
    catch { throw '音量设置文件路径无效。' }
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw "音量设置目录不存在：$directory" }
    return $fullPath
}

function Assert-JsonObjectKeysUnique {
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

function Assert-ExactJsonObject {
    param(
        [Parameter(Mandatory=$true)][object]$Value,
        [Parameter(Mandatory=$true)][string[]]$ExpectedNames,
        [Parameter(Mandatory=$true)][string]$Label
    )
    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or $Value -is [bool] -or
        $Value -is [ValueType]) { throw "$Label 必须是 JSON 对象。" }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -ne $ExpectedNames.Count) { throw "$Label 字段不完整或包含未知字段。" }
    foreach ($property in $properties) {
        if ($ExpectedNames -cnotcontains $property.Name) { throw "$Label 包含未知字段：$($property.Name)" }
    }
    foreach ($name in $ExpectedNames) {
        $matches = @($properties | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -ne 1) { throw "$Label 缺少字段或字段重复：$name" }
    }
}

function ConvertTo-ProfileUnsigned {
    param(
        [Parameter(Mandatory=$true)][object]$Value,
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][uint64]$Maximum,
        [switch]$AllowText
    )
    $integerTypes = @([byte], [uint16], [uint32], [uint64], [int16], [int32], [int64])
    if ($AllowText -and $Value -is [string]) {
        if ($Value -cnotmatch '^(0|[1-9][0-9]*)$') { throw "$Label 必须是十进制非负整数。" }
        $parsed = [uint64]0
        if (-not [uint64]::TryParse([string]$Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            throw "$Label 超出整数范围。"
        }
    } else {
        if (($integerTypes -notcontains $Value.GetType()) -or ($Value -is [bool])) {
            throw "$Label 必须是 JSON 整数。"
        }
        try { $parsed = [uint64]$Value } catch { throw "$Label 必须是非负整数。" }
    }
    if ($parsed -gt $Maximum) { throw "$Label 超出允许范围。" }
    return $parsed
}

function Test-ValidMasterName {
    param([Parameter(Mandatory=$true)][string]$HostName)
    if ($HostName.Length -lt 1 -or $HostName.Length -gt 253 -or $HostName -cnotmatch '^[\x21-\x7e]+$') {
        return $false
    }
    if ($HostName -cmatch '^[0-9.]+$' -and $HostName -cnotmatch '^[0-9]+(?:\.[0-9]+){3}$') { return $false }
    if ($HostName -cmatch '^[0-9]+(?:\.[0-9]+){3}$') {
        foreach ($part in $HostName.Split('.')) {
            if ($part.Length -gt 3) { return $false }
            $octet = [uint64]0
            if (-not [uint64]::TryParse($part, [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$octet) -or $octet -gt 255) {
                return $false
            }
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

function ConvertTo-ValidatedConnectionProfile {
    param(
        [Parameter(Mandatory=$true)][object]$Connection,
        [Parameter(Mandatory=$true)][object]$Devices,
        [object]$Receive,
        [object]$TransmitEnabled,
        [switch]$AllowTextNumbers
    )
    Assert-ExactJsonObject -Value $Connection -ExpectedNames @(
        'callsign', 'gateway_id', 'source_id', 'master', 'master_port',
        'destination_id', 'slot', 'color_code', 'call_kind') -Label 'connection'
    Assert-ExactJsonObject -Value $Devices -ExpectedNames @(
        'serial_port', 'wave_in_endpoint_id', 'wave_out_endpoint_id') -Label 'devices'

    $callsign = $Connection.callsign
    $master = $Connection.master
    $callKind = $Connection.call_kind
    if ($callsign -isnot [string] -or $callsign -cnotmatch '^[\x20-\x7e]{1,8}$') {
        throw 'callsign 必须是 1 到 8 个可打印 ASCII 字符。'
    }
    if ($master -isnot [string] -or -not (Test-ValidMasterName -HostName $master)) {
        throw 'master 必须是有效 IPv4 地址或语法正确的 ASCII 主机名。'
    }
    if ($callKind -isnot [string] -or @('group', 'private') -cnotcontains $callKind) {
        throw 'call_kind 只能是 group 或 private。'
    }
    $gatewayId = ConvertTo-ProfileUnsigned -Value $Connection.gateway_id -Label 'gateway_id' `
        -Maximum 4294967295 -AllowText:$AllowTextNumbers
    $sourceId = ConvertTo-ProfileUnsigned -Value $Connection.source_id -Label 'source_id' `
        -Maximum 16777215 -AllowText:$AllowTextNumbers
    $destinationId = ConvertTo-ProfileUnsigned -Value $Connection.destination_id -Label 'destination_id' `
        -Maximum 16777215 -AllowText:$AllowTextNumbers
    $masterPort = ConvertTo-ProfileUnsigned -Value $Connection.master_port -Label 'master_port' `
        -Maximum 65535 -AllowText:$AllowTextNumbers
    $slot = ConvertTo-ProfileUnsigned -Value $Connection.slot -Label 'slot' -Maximum 2 -AllowText:$AllowTextNumbers
    $colorCode = ConvertTo-ProfileUnsigned -Value $Connection.color_code -Label 'color_code' `
        -Maximum 15 -AllowText:$AllowTextNumbers
    if ($gatewayId -eq 0 -or $sourceId -eq 0 -or $destinationId -eq 0 -or
        $masterPort -eq 0 -or $slot -lt 1 -or $colorCode -gt 15) {
        throw '连接配置中的 ID、端口、时隙或 Color Code 超出允许范围。'
    }
    if ($null -eq $Receive) {
        $receiveDestinationId = if ($callKind -ceq 'private') { $sourceId } else { $destinationId }
        $receiveSlot = $slot
        $receiveCallKind = $callKind
    } else {
        Assert-ExactJsonObject -Value $Receive -ExpectedNames @('destination_id', 'slot', 'call_kind') -Label 'receive'
        if ($Receive.call_kind -isnot [string] -or @('group', 'private') -cnotcontains $Receive.call_kind) {
            throw 'receive.call_kind 只能是 group 或 private。'
        }
        $receiveDestinationId = ConvertTo-ProfileUnsigned -Value $Receive.destination_id -Label 'receive.destination_id' `
            -Maximum 16777215 -AllowText:$AllowTextNumbers
        $receiveSlot = ConvertTo-ProfileUnsigned -Value $Receive.slot -Label 'receive.slot' `
            -Maximum 2 -AllowText:$AllowTextNumbers
        $receiveCallKind = [string]$Receive.call_kind
        if ($receiveDestinationId -eq 0 -or $receiveSlot -lt 1) { throw 'receive 目标 ID 或时隙超出允许范围。' }
    }
    if ($null -ne $TransmitEnabled -and $TransmitEnabled -isnot [bool]) {
        throw 'transmit_enabled 必须是 JSON 布尔值。'
    }

    $serialPort = $Devices.serial_port
    $waveInEndpointId = $Devices.wave_in_endpoint_id
    $waveOutEndpointId = $Devices.wave_out_endpoint_id
    if ($serialPort -isnot [string] -or
        ($serialPort -cne 'auto' -and $serialPort -cnotmatch '^COM[1-9][0-9]{0,2}$')) {
        throw 'devices.serial_port 必须是 auto 或 COM1 到 COM999。'
    }
    foreach ($endpoint in @(
        [pscustomobject]@{ Name = 'wave_in_endpoint_id'; Value = $waveInEndpointId },
        [pscustomobject]@{ Name = 'wave_out_endpoint_id'; Value = $waveOutEndpointId })) {
        if ($endpoint.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($endpoint.Value) -or
            $endpoint.Value.Length -gt 4096) { throw "devices.$($endpoint.Name) 必须是 auto 或有效 endpoint ID。" }
    }
    $validated = [ordered]@{
        schema_version = 1
        connection = [pscustomobject][ordered]@{
            callsign = $callsign
            gateway_id = [uint64]$gatewayId
            source_id = [uint64]$sourceId
            master = $master
            master_port = [uint64]$masterPort
            destination_id = [uint64]$destinationId
            slot = [uint64]$slot
            color_code = [uint64]$colorCode
            call_kind = $callKind
        }
        receive = [pscustomobject][ordered]@{
            destination_id = [uint64]$receiveDestinationId
            slot = [uint64]$receiveSlot
            call_kind = $receiveCallKind
        }
        devices = [pscustomobject][ordered]@{
            serial_port = $serialPort.ToUpperInvariant() -replace '^AUTO$', 'auto'
            wave_in_endpoint_id = $waveInEndpointId
            wave_out_endpoint_id = $waveOutEndpointId
        }
    }
    if ($null -ne $TransmitEnabled) { $validated.transmit_enabled = [bool]$TransmitEnabled }
    return ConvertTo-BridgeUserConnectionProfile -Connection $Connection -Devices $Devices `
        -Receive $Receive -TransmitEnabled $TransmitEnabled -AllowTextNumbers:$AllowTextNumbers
}

function ConvertTo-RoutingStatePolicy {
    param(
        [Parameter(Mandatory=$true)][object]$Profile,
        [Parameter(Mandatory=$true)][uint64]$LocalSourceId
    )
    $policy = $Profile.rx_policy
    $expectedNames = @('group_mode', 'private_mode', 'allow_groups', 'blocked_groups',
        'allow_private_peers', 'local_private_routes', 'blocked_source_ids')
    Assert-ExactJsonObject -Value $policy -ExpectedNames $expectedNames -Label 'rx_policy'
    if (@('disabled', 'selected_peers', 'all_peers_to_local') -cnotcontains [string]$policy.private_mode) {
        throw 'rx_policy.private_mode 值无效。'
    }
    if ($policy.private_mode -ceq 'disabled' -and
        (@($policy.allow_private_peers).Count -gt 0 -or @($policy.local_private_routes).Count -gt 0)) {
        throw 'rx_policy.private_mode=disabled 时私呼路由列表必须为空。'
    }
    if ($policy.private_mode -ceq 'selected_peers' -and @($policy.local_private_routes).Count -gt 0) {
        throw 'rx_policy.private_mode=selected_peers 时 local_private_routes 必须为空。'
    }
    if (@('selected', 'all_delivered') -cnotcontains [string]$policy.group_mode) {
        throw 'rx_policy.group_mode 只能是 selected 或 all_delivered。'
    }
    foreach ($name in @('allow_groups', 'blocked_groups', 'allow_private_peers',
            'local_private_routes', 'blocked_source_ids')) {
        $value = $policy.PSObject.Properties[$name].Value
        if ($null -eq $value -or $value -isnot [array]) { throw "rx_policy.$name 必须是 JSON 数组。" }
    }

    $groups = New-Object 'System.Collections.Generic.List[object]'
    $blockedGroups = New-Object 'System.Collections.Generic.List[object]'
    $peers = New-Object 'System.Collections.Generic.List[object]'
    $localRoutes = New-Object 'System.Collections.Generic.List[object]'
    $blockedSources = New-Object 'System.Collections.Generic.List[uint64]'
    $groupKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $blockedGroupKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $peerKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $localRouteKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $blockedSourceKeys = New-Object 'System.Collections.Generic.HashSet[uint64]'

    foreach ($entry in @($policy.allow_groups)) {
        Assert-ExactJsonObject -Value $entry -ExpectedNames @('destination_id', 'slot') -Label 'rx_policy.allow_groups 项'
        $id = ConvertTo-ProfileUnsigned -Value $entry.destination_id -Label 'rx_policy.allow_groups.destination_id' -Maximum 16777215
        $slot = ConvertTo-ProfileUnsigned -Value $entry.slot -Label 'rx_policy.allow_groups.slot' -Maximum 2
        if ($id -eq 0 -or $slot -lt 1) { throw 'rx_policy.allow_groups 中的 ID 或时隙超出允许范围。' }
        $key = "$id/$slot"
        if (-not $groupKeys.Add($key)) { throw "rx_policy.allow_groups 重复项：$key" }
        $groups.Add([pscustomobject][ordered]@{ destination_id=[uint64]$id; slot=[uint64]$slot })
    }
    foreach ($entry in @($policy.blocked_groups)) {
        Assert-ExactJsonObject -Value $entry -ExpectedNames @('destination_id', 'slot') -Label 'rx_policy.blocked_groups 项'
        $id = ConvertTo-ProfileUnsigned -Value $entry.destination_id -Label 'rx_policy.blocked_groups.destination_id' -Maximum 16777215
        $slot = ConvertTo-ProfileUnsigned -Value $entry.slot -Label 'rx_policy.blocked_groups.slot' -Maximum 2
        if ($id -eq 0 -or $slot -lt 1) { throw 'rx_policy.blocked_groups 中的 ID 或时隙超出允许范围。' }
        $key = "$id/$slot"
        if (-not $blockedGroupKeys.Add($key)) { throw "rx_policy.blocked_groups 重复项：$key" }
        $blockedGroups.Add([pscustomobject][ordered]@{ destination_id=[uint64]$id; slot=[uint64]$slot })
    }
    foreach ($entry in @($policy.allow_private_peers)) {
        Assert-ExactJsonObject -Value $entry -ExpectedNames @('source_id', 'local_destination_id', 'slot') -Label 'rx_policy.allow_private_peers 项'
        $peerId = ConvertTo-ProfileUnsigned -Value $entry.source_id -Label 'rx_policy.allow_private_peers.source_id' -Maximum 16777215
        $localId = ConvertTo-ProfileUnsigned -Value $entry.local_destination_id -Label 'rx_policy.allow_private_peers.local_destination_id' -Maximum 16777215
        $slot = ConvertTo-ProfileUnsigned -Value $entry.slot -Label 'rx_policy.allow_private_peers.slot' -Maximum 2
        if ($peerId -eq 0 -or $localId -eq 0 -or $slot -lt 1) { throw 'rx_policy.allow_private_peers 中的 ID 或时隙超出允许范围。' }
        if ($localId -ne $LocalSourceId) { throw 'rx_policy.allow_private_peers.local_destination_id 必须等于 connection.source_id。' }
        $key = "$peerId/$localId/$slot"
        if (-not $peerKeys.Add($key)) { throw "rx_policy.allow_private_peers 重复项：$key" }
        $peers.Add([pscustomobject][ordered]@{ source_id=[uint64]$peerId; local_destination_id=[uint64]$localId; slot=[uint64]$slot })
    }
    foreach ($entry in @($policy.local_private_routes)) {
        Assert-ExactJsonObject -Value $entry -ExpectedNames @('local_destination_id', 'slot') -Label 'rx_policy.local_private_routes 项'
        $localId = ConvertTo-ProfileUnsigned -Value $entry.local_destination_id -Label 'rx_policy.local_private_routes.local_destination_id' -Maximum 16777215
        $slot = ConvertTo-ProfileUnsigned -Value $entry.slot -Label 'rx_policy.local_private_routes.slot' -Maximum 2
        if ($localId -eq 0 -or $slot -lt 1) { throw 'rx_policy.local_private_routes 中的 ID 或时隙超出允许范围。' }
        if ($localId -ne $LocalSourceId) { throw 'rx_policy.local_private_routes.local_destination_id 必须等于 connection.source_id。' }
        $key = "$localId/$slot"
        if (-not $localRouteKeys.Add($key)) { throw "rx_policy.local_private_routes 重复项：$key" }
        $localRoutes.Add([pscustomobject][ordered]@{ local_destination_id=[uint64]$localId; slot=[uint64]$slot })
    }
    foreach ($value in @($policy.blocked_source_ids)) {
        $id = ConvertTo-ProfileUnsigned -Value $value -Label 'rx_policy.blocked_source_ids 项' -Maximum 16777215
        if ($id -eq 0 -or -not $blockedSourceKeys.Add([uint64]$id)) { throw 'rx_policy.blocked_source_ids 含零值或重复 ID。' }
        $blockedSources.Add([uint64]$id)
    }
    foreach ($key in $groupKeys) {
        if ($blockedGroupKeys.Contains($key)) { throw "组呼频道同时位于 allow 和 block：$key" }
    }
    if ($policy.private_mode -ceq 'disabled' -and ($peers.Count -gt 0 -or $localRoutes.Count -gt 0)) {
        throw 'rx_policy.private_mode=disabled 时私呼路由列表必须为空。'
    }
    if ($policy.private_mode -ceq 'selected_peers' -and $localRoutes.Count -gt 0) {
        throw 'rx_policy.private_mode=selected_peers 时 local_private_routes 必须为空。'
    }
    return [pscustomobject][ordered]@{
        group_mode = [string]$policy.group_mode
        private_mode = [string]$policy.private_mode
        allow_groups = [object[]]$groups.ToArray()
        blocked_groups = [object[]]$blockedGroups.ToArray()
        allow_private_peers = [object[]]$peers.ToArray()
        local_private_routes = [object[]]$localRoutes.ToArray()
        blocked_source_ids = [uint64[]]$blockedSources.ToArray()
    }
}

function New-RoutingStateDocument {
    param([Parameter(Mandatory=$true)][object]$Profile)
    if ($null -eq $Profile.connection -or $null -eq $Profile.tx_target -or
        $null -eq $Profile.rx_policy -or $Profile.transmit_enabled -isnot [bool]) {
        throw '手工连接配置没有完整迁移为 schema 2。'
    }
    $sourceId = ConvertTo-ProfileUnsigned -Value $Profile.connection.source_id -Label 'connection.source_id' -Maximum 16777215
    if ($sourceId -eq 0) { throw 'connection.source_id 必须大于零。' }
    Assert-ExactJsonObject -Value $Profile.tx_target -ExpectedNames @('destination_id', 'kind', 'slot') -Label 'tx_target'
    $destinationId = ConvertTo-ProfileUnsigned -Value $Profile.tx_target.destination_id -Label 'tx_target.destination_id' -Maximum 16777215
    $slot = ConvertTo-ProfileUnsigned -Value $Profile.tx_target.slot -Label 'tx_target.slot' -Maximum 2
    if ($destinationId -eq 0 -or $slot -lt 1 -or $Profile.tx_target.kind -isnot [string] -or
        @('group', 'private') -cnotcontains [string]$Profile.tx_target.kind) {
        throw 'tx_target 中的目标、呼叫类型或时隙超出允许范围。'
    }
    return [pscustomobject][ordered]@{
        schema_version = 1
        local_source_id = [uint64]$sourceId
        rx_policy = ConvertTo-RoutingStatePolicy -Profile $Profile -LocalSourceId $sourceId
        tx_target = [pscustomobject][ordered]@{
            destination_id = [uint64]$destinationId
            kind = [string]$Profile.tx_target.kind
            slot = [uint64]$slot
        }
        transmit_enabled = [bool]$Profile.transmit_enabled
    }
}

function Write-RoutingStateFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][object]$Profile
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw "routing-state.json 目录不存在：$directory" }
    if ([System.IO.File]::Exists($fullPath)) { throw "本次运行的 routing-state.json 已存在：$fullPath" }
    $document = New-RoutingStateDocument -Profile $Profile
    $json = (ConvertTo-Json -InputObject $document -Depth 8) + "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($json)
    if ($bytes.Length -gt 65536) { throw 'routing-state.json 超过 64 KiB 上限。' }
    $temporaryPath = $fullPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)
        [System.IO.File]::Move($temporaryPath, $fullPath)
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
    return $fullPath
}

function Read-ConnectionProfile {
    param([Parameter(Mandatory=$true)][string]$Path)
    return Read-BridgeUserConnectionProfile -Path $Path
}

function Read-ConnectionPrompt {
    param([Parameter(Mandatory=$true)][string]$Prompt, [scriptblock]$InputReader)
    if ($InputReader) { return & $InputReader $Prompt }
    return Read-Host $Prompt
}

function Read-ManualConnectionProfile {
    param([scriptblock]$InputReader)
    Write-Host '首次使用手工连接配置：请填写一次连接参数。'
    $connection = [pscustomobject]@{
        callsign = (Read-ConnectionPrompt -Prompt '呼号（最多 8 个 ASCII 字符）' -InputReader $InputReader)
        gateway_id = (Read-ConnectionPrompt -Prompt 'Gateway ID（1..4294967295）' -InputReader $InputReader)
        source_id = (Read-ConnectionPrompt -Prompt '本机 DMR Source ID（1..16777215）' -InputReader $InputReader)
        master = (Read-ConnectionPrompt -Prompt 'BM Master IPv4 地址或主机名' -InputReader $InputReader)
        master_port = (Read-ConnectionPrompt -Prompt 'BM Master UDP 端口（1..65535）' -InputReader $InputReader)
        destination_id = (Read-ConnectionPrompt -Prompt '目标 Talkgroup ID 或单呼 Radio ID（1..16777215）' -InputReader $InputReader)
        slot = (Read-ConnectionPrompt -Prompt 'Timeslot（1 或 2）' -InputReader $InputReader)
        color_code = (Read-ConnectionPrompt -Prompt 'Color Code（0..15）' -InputReader $InputReader)
        call_kind = (Read-ConnectionPrompt -Prompt '呼叫类型（group 或 private）' -InputReader $InputReader)
    }
    $devices = [pscustomobject]@{
        serial_port = 'auto'
        wave_in_endpoint_id = 'auto'
        wave_out_endpoint_id = 'auto'
    }
    return ConvertTo-ValidatedConnectionProfile -Connection $connection -Devices $devices -AllowTextNumbers
}

function Write-ConnectionProfile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][object]$Profile)
    Write-BridgeUserConnectionProfile -Path $Path -Profile $Profile
}

function Resolve-ConnectionProfilePath {
    param([string]$Path)
    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $script:packageRoot 'connection-profile.json'
    } else { $Path }
    try { $fullPath = [System.IO.Path]::GetFullPath($candidate) }
    catch { throw '连接配置文件路径无效。' }
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw "连接配置目录不存在：$directory" }
    return $fullPath
}

function Read-ProfileForPreset {
    param([Parameter(Mandatory=$true)][string]$SelectedPreset, [Parameter(Mandatory=$true)][string]$Path)
    if ($SelectedPreset -cne 'manual') { return $null }
    return Read-ConnectionProfile -Path $Path
}

function Set-ResolvedProfileDevices {
    param(
        [Parameter(Mandatory=$true)][object]$Profile,
        [switch]$NewProfile,
        [string]$SelectedPort,
        [string]$WaveInEndpointId,
        [string]$WaveOutEndpointId,
        [switch]$PortOverride,
        [switch]$WaveInOverride,
        [switch]$WaveOutOverride,
        [switch]$SerialWasPrompted,
        [switch]$WaveInWasPrompted,
        [switch]$WaveOutWasPrompted
    )
    if ($NewProfile) {
        $Profile.devices.serial_port = if ($PortOverride -or $SerialWasPrompted) { $SelectedPort } else { 'auto' }
        $Profile.devices.wave_in_endpoint_id = if ($WaveInOverride -or $WaveInWasPrompted) { $WaveInEndpointId } else { 'auto' }
        $Profile.devices.wave_out_endpoint_id = if ($WaveOutOverride -or $WaveOutWasPrompted) { $WaveOutEndpointId } else { 'auto' }
        return $true
    }
    $changed = $false
    if ($Profile.devices.serial_port -ceq 'auto' -and $SerialWasPrompted) {
        $Profile.devices.serial_port = $SelectedPort
        $changed = $true
    }
    if ($Profile.devices.wave_in_endpoint_id -ceq 'auto' -and $WaveInWasPrompted) {
        $Profile.devices.wave_in_endpoint_id = $WaveInEndpointId
        $changed = $true
    }
    if ($Profile.devices.wave_out_endpoint_id -ceq 'auto' -and $WaveOutWasPrompted) {
        $Profile.devices.wave_out_endpoint_id = $WaveOutEndpointId
        $changed = $true
    }
    return $changed
}

function Resolve-LocalFile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Label)
    try { $fullPath = [System.IO.Path]::GetFullPath($Path) }
    catch { throw "$Label 路径无效。" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "找不到$Label：$fullPath" }
    return $fullPath
}

function Resolve-PasswordFileForRun {
    param(
        [Parameter(Mandatory=$true)][string]$SelectedPreset,
        [string]$ExplicitPath,
        [switch]$WasExplicit,
        [Parameter(Mandatory=$true)][string]$DefaultPath
    )
    if ($WasExplicit) { return Resolve-LocalFile -Path $ExplicitPath -Label '本机 BM 私有密码文件' }
    if ($SelectedPreset -cne 'manual' -or [System.IO.File]::Exists($DefaultPath)) {
        return Resolve-LocalFile -Path $DefaultPath -Label '本机 BM 私有密码文件'
    }
    return ''
}

function Resolve-BridgeExecutable {
    if ($BridgePath) { return Resolve-LocalFile -Path $BridgePath -Label 'native bridge 程序' }
    $candidate = Join-Path $script:packageRoot 'wirex_bridge.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "当前便携包目录缺少 wirex_bridge.exe：$candidate；开发运行请传入 -BridgePath。"
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Select-TestPreset {
    param([string]$Requested)
    $allowed = @('parrot-cn', 'parrot-global', 'listen-46001', 'listen-91', 'manual')
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $match = @($allowed | Where-Object { $_ -ieq $Requested.Trim() })
        if ($match.Count -ne 1) { throw '测试预设无效；请使用 parrot-cn、parrot-global、listen-46001、listen-91 或 manual。' }
        return [string]$match[0]
    }
    return 'parrot-cn'
}

function Test-ApprovedBody {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = Resolve-LocalFile -Path $Path -Label '本机 Y 模板'
    $item = Get-Item -LiteralPath $fullPath
    if ($item.Length -ne $script:expectedBodyLength) { throw "Y 模板长度不符：$fullPath（必须为 $($script:expectedBodyLength) 字节）。" }
    $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $script:expectedBodySha256) { throw "Y 模板 SHA-256 不匹配：$fullPath；没有启动 native 核心。" }
    return $fullPath
}

function Invoke-AudioEnumeration {
    param([Parameter(Mandatory=$true)][string]$Executable)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = '--list-audio-json'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动有界音频设备枚举。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            if (-not $process.WaitForExit(2000)) { throw '音频枚举超时，且无法确认枚举进程已退出。' }
            throw '音频设备枚举超过 10 秒；已停止这次枚举进程。'
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) { throw '音频枚举已退出，但输出管道未及时关闭。' }
        if ($process.ExitCode -ne 0) { throw "native 音频枚举失败，退出码 $($process.ExitCode)。" }
        $json = $stdoutTask.GetAwaiter().GetResult().Trim().TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($json) -or $json.Contains("`n") -or $json.Contains("`r")) {
            throw 'native 音频枚举必须只输出一行 JSON。'
        }
        $devices = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($devices.schema_version -ne 1 -or $devices.type -cne 'audio_devices' -or
            -not $devices.PSObject.Properties['wave_inputs'] -or
            -not $devices.PSObject.Properties['wave_outputs']) {
            throw 'native 音频枚举 schema 与预期不符。'
        }
        foreach ($listName in @('wave_inputs', 'wave_outputs')) {
            $ids = @{}
            foreach ($device in @($devices.$listName)) {
                if ($null -eq $device -or $device.id -is [bool] -or
                    -not ($device.id -is [int] -or $device.id -is [long]) -or $device.id -lt 0 -or
                    [string]::IsNullOrWhiteSpace([string]$device.name) -or
                    ($device.PSObject.Properties['endpoint_id'] -and $null -ne $device.endpoint_id -and $device.endpoint_id -isnot [string]) -or
                    $device.pcm_48000_mono_s16_supported -isnot [bool]) {
                    throw "音频枚举的 $listName 含无效记录。"
                }
                if ($ids.ContainsKey([string]$device.id)) { throw "音频枚举的 $listName 含重复设备 ID。" }
                $ids[[string]$device.id] = $true
            }
        }
        return $devices
    } finally {
        $process.Dispose()
    }
}

function Get-CurrentSerialPorts {
    if ($env:OS -ne 'Windows_NT') { throw '本启动器只支持 Windows COM 设备。' }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DEVICEMAP\SERIALCOMM', $false)
    if ($null -eq $key) { return @() }
    try {
        return @($key.GetValueNames() | ForEach-Object { [string]$key.GetValue($_) } |
            Where-Object { $_ -match '^COM[1-9][0-9]*$' } | Sort-Object -Unique)
    } finally { $key.Dispose() }
}

function Get-PnpPropertyData {
    param([Parameter(Mandatory=$true)][string]$InstanceId, [Parameter(Mandatory=$true)][string]$KeyName)
    if (-not (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) { return $null }
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction SilentlyContinue
    if ($null -eq $property) { return $null }
    return $property.Data
}

function Get-HriSerialDevices {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return @() }
    $presentPorts = @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue)
    $devices = @()
    foreach ($device in $presentPorts) {
        $instanceId = [string]$device.InstanceId
        $identity = [regex]::Match($instanceId, '^USB\\VID_26AA&PID_([0-9A-F]{4})\\', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $identity.Success) { continue }
        $productId = [Convert]::ToInt32($identity.Groups[1].Value, 16)
        if ($productId -lt 0x0030) { continue }
        $friendlyName = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_FriendlyName')
        $busDescription = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc')
        $portMatch = [regex]::Match($friendlyName, '\((COM[1-9][0-9]*)\)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $devices += [pscustomobject]@{
            InstanceId = $instanceId
            ProductId = $identity.Groups[1].Value.ToUpperInvariant()
            FriendlyName = $friendlyName
            BusDescription = $busDescription
            PortName = if ($portMatch.Success) { $portMatch.Groups[1].Value.ToUpperInvariant() } else { '' }
            IsHri = ($busDescription -match '(?i)\bHRI\b')
        }
    }
    return @($devices)
}

function Read-PortSelection {
    param(
        [Parameter(Mandatory=$true)][string[]]$Ports,
        [Parameter(Mandatory=$true)][object[]]$HriDevices,
        [string]$Requested,
        [switch]$RequireHri,
        [switch]$NoInteractive,
        [scriptblock]$ChoiceReader
    )
    if ($Ports.Count -eq 0) { throw '当前没有枚举到 Windows COM 端口。' }
    $current = @($Ports | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $presentHri = @($HriDevices | Where-Object { $_.IsHri -and $_.PortName -and $current -contains $_.PortName })
    if ($RequireHri -and $presentHri.Count -eq 0) { throw '当前枚举的串口中没有可确认的 HRI 设备。' }
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $selected = $Requested.Trim().ToUpperInvariant()
        if ($selected -notmatch '^COM[1-9][0-9]{0,2}$' -or @($current | Where-Object { $_ -ieq $selected }).Count -ne 1) {
            throw "所选串口 $selected 当前没有枚举到。"
        }
        $hriMatches = @($presentHri | Where-Object { $_.PortName -ieq $selected })
        if ($RequireHri -and $hriMatches.Count -ne 1) { throw "连接配置指定的 $selected 未匹配到唯一 HRI 设备。" }
        return $selected
    }
    if ($RequireHri -and $presentHri.Count -eq 1) {
        Write-Host ("已识别唯一 HRI 串口 {0} · VID_26AA&PID_{1}" -f $presentHri[0].PortName, $presentHri[0].ProductId)
        return $presentHri[0].PortName
    }
    $com5Matches = @($presentHri | Where-Object { $_.PortName -ieq 'COM5' })
    if ($current -contains 'COM5' -and $presentHri.Count -eq 1 -and $com5Matches.Count -eq 1) {
        Write-Host ("已识别电台串口 COM5 · VID_26AA&PID_{0}" -f $com5Matches[0].ProductId)
        return 'COM5'
    }

    if ($presentHri.Count -gt 1) {
        Write-Host '请选择本次使用的 HRI 串口：'
        foreach ($device in $presentHri) {
            Write-Host ("  {0} · VID_26AA&PID_{1}" -f $device.PortName, $device.ProductId)
        }
    } else {
        Write-Host '请选择本次使用的 HRI 串口：'
        foreach ($item in $current) {
            $matches = @($HriDevices | Where-Object { $_.PortName -ieq $item })
            if ($matches.Count -eq 1) {
                Write-Host ("  {0} · VID_26AA&PID_{1}" -f $item, $matches[0].ProductId)
            } else {
                Write-Host "  $item"
            }
        }
    }
    if ($NoInteractive) {
        throw 'HRI COM 端口无法唯一自动确定；请在设置中指定串口或检查 HRI 设备。'
    }
    $restrictToHri = ($presentHri.Count -gt 1)
    while ($true) {
        $script:serialSelectionWasManual = $true
        $selectionText = if ($ChoiceReader) { & $ChoiceReader '输入本次 HRI COM 端口' } else { Read-Host '输入本次 HRI COM 端口' }
        $selected = ([string]$selectionText).Trim().ToUpperInvariant()
        $isCurrent = @($current | Where-Object { $_ -ieq $selected }).Count -eq 1
        $isHriCandidate = @($presentHri | Where-Object { $_.PortName -ieq $selected }).Count -eq 1
        if ($isCurrent -and (-not $restrictToHri -or $isHriCandidate)) {
            $selectedDevice = @($presentHri | Where-Object { $_.PortName -ieq $selected })
            if ($selectedDevice.Count -eq 1) {
                Write-Host ("已选择 HRI 串口 {0}" -f $selected)
            } else {
                Write-Host ("已选择串口 {0}" -f $selected)
            }
            return $selected
        } else {
            Write-Host '所选 COM 端口不在本次枚举中；请重新输入。' -ForegroundColor Yellow
        }
    }
}

function Read-WaveInSelection {
    param([Parameter(Mandatory=$true)][object[]]$Devices, [switch]$NoInteractive)
    $available = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -and -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    if ($available.Count -eq 0) { throw '没有可用的 48 kHz WaveIn 端点；请检查电台 USB 音频连接后重试。' }
    if ($NoInteractive -and -not $WaveIn) { throw 'WaveIn endpoint 无法按 USB Audio 关键词唯一确定；请在设置中选择稳定 endpoint ID。' }
    Write-Host '请选择电台音频输入：'
    foreach ($device in $available) {
        Write-Host ("  ID {0}: {1} · 48 kHz PCM 可用" -f $device.id, $device.name)
    }
    while ($true) {
        if ($WaveIn) { $text = $WaveIn } else {
            $script:waveInSelectionWasManual = $true
            $text = Read-Host '输入本次枚举得到的 Radio WaveIn ID'
        }
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($available | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1) { return $matches[0] }
        }
        Write-Host '请输入列表中的 WaveIn ID。' -ForegroundColor Yellow
        $WaveIn = ''
    }
}

function Read-WaveOutSelection {
    param([Parameter(Mandatory=$true)][object[]]$Devices, [switch]$NoInteractive)
    $available = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -and -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    if ($available.Count -eq 0) { throw '没有可用的 48 kHz WaveOut 端点；请检查电台 USB 音频连接后重试。' }
    if ($NoInteractive -and -not $WaveOut) { throw 'WaveOut endpoint 无法按 USB Audio 关键词唯一确定；请在设置中选择稳定 endpoint ID。' }
    Write-Host '请选择电台音频输出：'
    foreach ($device in $available) {
        Write-Host ("  ID {0}: {1} · 48 kHz PCM 可用" -f $device.id, $device.name)
    }
    while ($true) {
        if ($WaveOut) { $text = $WaveOut } else {
            $script:waveOutSelectionWasManual = $true
            $text = Read-Host '输入本次枚举得到的 Radio WaveOut ID'
        }
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($available | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1) { return $matches[0] }
        }
        Write-Host '请输入列表中的 WaveOut ID。' -ForegroundColor Yellow
        $WaveOut = ''
    }
}

function Find-UsbAudioNamePair {
    param([Parameter(Mandatory=$true)][object]$Devices)
    $inputMatches = @($Devices.wave_inputs | Where-Object {
        $_.name -match '(?i)USB Audio' -and $_.pcm_48000_mono_s16_supported -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    $outputMatches = @($Devices.wave_outputs | Where-Object {
        $_.name -match '(?i)USB Audio' -and $_.pcm_48000_mono_s16_supported -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    if ($inputMatches.Count -ne 1 -or $outputMatches.Count -ne 1) { return $null }
    return [pscustomobject]@{ Input = $inputMatches[0]; Output = $outputMatches[0] }
}

function Get-CompatibleAutoAudioPair {
    param(
        [object]$AudioPair,
        [Parameter(Mandatory=$true)][string]$WaveInSelector,
        [Parameter(Mandatory=$true)][string]$WaveOutSelector
    )
    if ($null -eq $AudioPair -or ($WaveInSelector -cne 'auto' -and $WaveOutSelector -cne 'auto')) { return $null }
    if ($WaveInSelector -cne 'auto' -and -not [string]::Equals(
            [string]$AudioPair.Input.endpoint_id, $WaveInSelector, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if ($WaveOutSelector -cne 'auto' -and -not [string]::Equals(
            [string]$AudioPair.Output.endpoint_id, $WaveOutSelector, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $AudioPair
}

function Find-WaveEndpointById {
    param(
        [Parameter(Mandatory=$true)][object]$Devices,
        [Parameter(Mandatory=$true)][ValidateSet('input', 'output')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$EndpointId
    )
    $list = if ($Direction -eq 'input') { @($Devices.wave_inputs) } else { @($Devices.wave_outputs) }
    $matches = @($list | Where-Object {
        $_.pcm_48000_mono_s16_supported -and
        -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id) -and
        [string]::Equals([string]$_.endpoint_id, $EndpointId, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -ne 1) { throw "连接配置指定的 Wave$($Direction) endpoint 当前未唯一枚举到；请检查设备后重试。" }
    return $matches[0]
}

function Get-ProfileConnectionArgs {
    param(
        [Parameter(Mandatory=$true)][object]$Profile,
        [Parameter(Mandatory=$true)][string]$RoutingStatePath
    )
    $connection = $Profile.connection
    $txTarget = $Profile.tx_target
    if ([string]::IsNullOrWhiteSpace($RoutingStatePath)) { throw '手工连接启动必须指定 routing-state.json。' }
    $arguments = @(
        '--profile-callsign', [string]$connection.callsign,
        '--profile-gateway-id', ([uint64]$connection.gateway_id).ToString([Globalization.CultureInfo]::InvariantCulture),
        '--profile-source-id', ([uint64]$connection.source_id).ToString([Globalization.CultureInfo]::InvariantCulture),
        '--profile-master', [string]$connection.master,
        '--profile-master-port', ([uint64]$connection.master_port).ToString([Globalization.CultureInfo]::InvariantCulture),
        '--profile-destination-id', ([uint64]$txTarget.destination_id).ToString([Globalization.CultureInfo]::InvariantCulture),
        '--profile-slot', ([uint64]$txTarget.slot).ToString([Globalization.CultureInfo]::InvariantCulture),
        '--profile-color-code', ([uint64]$connection.color_code).ToString([Globalization.CultureInfo]::InvariantCulture),
        '--profile-call-kind', $(if ($txTarget.kind -ceq 'group') { 'G' } else { 'P' }),
        '--routing-state-file', [System.IO.Path]::GetFullPath($RoutingStatePath)
    )
    if (-not [bool]$Profile.transmit_enabled) {
        $arguments += '--listen-only'
    }
    return $arguments
}
function Test-StatusDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    $directory = [System.IO.Path]::GetFullPath($Path)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $probe = Join-Path $directory ('.bm-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'ok', (New-Object System.Text.UTF8Encoding($false)))
    } finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force }
    }
    return $directory
}

try {
    $hasDevelopmentOverride = (-not [string]::IsNullOrWhiteSpace($BridgePath)) -or
        (-not [string]::IsNullOrWhiteSpace($BodyFile))
    if ($hasDevelopmentOverride -and [string]::IsNullOrWhiteSpace($StatusDirectory)) {
        throw '显式指定 -BridgePath 或 -BodyFile 时也必须显式指定 -StatusDirectory，避免运行报告落到源码目录。'
    }
    if ($PrepareOnly -and (-not $NoInteractive -or -not $RequirePasswordFile -or
        [string]::IsNullOrWhiteSpace($PreparationOutputPath) -or [string]::IsNullOrWhiteSpace($StatusDirectory) -or $ManualPtt)) {
        throw '-PrepareOnly 必须与 -NoInteractive、-RequirePasswordFile、-PreparationOutputPath 和 -StatusDirectory 一起使用，且不能启用键盘诊断输入。'
    }
    if ([bool]$WaveIn -xor [bool]$WaveOut) { throw '手工指定音频设备时必须同时传入 -WaveIn 和 -WaveOut。' }
    if ($Port -and $Port.Trim() -notmatch '^COM[1-9][0-9]{0,2}$') { throw '-Port 必须是 COM1 到 COM999。' }
    $selectedPreset = Select-TestPreset -Requested $Preset
    $executable = Resolve-BridgeExecutable
    $defaultPasswordPath = Join-Path $script:packageRoot 'private\bm-device-password.txt'
    $passwordPath = Resolve-PasswordFileForRun -SelectedPreset $selectedPreset `
        -ExplicitPath $PasswordFile -WasExplicit:($PSBoundParameters.ContainsKey('PasswordFile')) `
        -DefaultPath $defaultPasswordPath
    if ($RequirePasswordFile -and [string]::IsNullOrWhiteSpace($passwordPath)) {
        throw 'UI 自动连接需要本机密码文件；请在设置中选择现有密码文件。'
    }
    if ($BodyFile) { $bodySource = $BodyFile } else { $bodySource = Join-Path $script:packageRoot 'private\device-y.bin' }
    $body = Test-ApprovedBody -Path $bodySource
    $manualProfile = $null
    $manualProfilePath = ''
    $manualProfileWasCreated = $false
    if ($selectedPreset -eq 'manual') {
        $manualProfilePath = Resolve-ConnectionProfilePath -Path $ConnectionProfilePath
        $manualProfile = Read-ProfileForPreset -SelectedPreset $selectedPreset -Path $manualProfilePath
        if ($null -eq $manualProfile) {
            if ($NoInteractive) { throw '本机连接配置尚未填写；请先打开设置并保存连接参数。' }
            $manualProfile = Read-ManualConnectionProfile
            $manualProfileWasCreated = $true
        }
    }
    $audioSettingsPath = Resolve-AudioSettingsPath -Path $AudioSettingsPath
    $radioPlaybackGainWasBound = $PSBoundParameters.ContainsKey('RadioPlaybackGain')
    $micTransmitGainWasBound = $PSBoundParameters.ContainsKey('MicTransmitGain')
    $audioSettings = Get-AudioSettings -Path $audioSettingsPath `
        -RadioPlaybackGainWasBound $radioPlaybackGainWasBound `
        -RadioPlaybackGainValue $RadioPlaybackGain `
        -MicTransmitGainWasBound $micTransmitGainWasBound `
        -MicTransmitGainValue $MicTransmitGain
    $devices = Invoke-AudioEnumeration -Executable $executable
    $serialPorts = @(Get-CurrentSerialPorts)
    $hriDevices = @(Get-HriSerialDevices)
    $requestedPort = $Port
    $profileRequiresHri = ($selectedPreset -eq 'manual')
    if ($selectedPreset -eq 'manual' -and -not $Port -and $manualProfile.devices.serial_port -cne 'auto') {
        $requestedPort = [string]$manualProfile.devices.serial_port
    }
    $portName = Read-PortSelection -Ports $serialPorts -HriDevices $hriDevices `
        -Requested $requestedPort -RequireHri:$profileRequiresHri -NoInteractive:$NoInteractive
    $radioSerialMatches = @($hriDevices | Where-Object { $_.IsHri -and $_.PortName -ieq $portName })
    $radioSerial = if ($radioSerialMatches.Count -eq 1) { $radioSerialMatches[0] } else { $null }

    $inputSelector = 'auto'
    $outputSelector = 'auto'
    if ($selectedPreset -eq 'manual') {
        $inputSelector = [string]$manualProfile.devices.wave_in_endpoint_id
        $outputSelector = [string]$manualProfile.devices.wave_out_endpoint_id
    }
    $audioPair = $null
    if ($radioSerial) { $audioPair = Find-UsbAudioNamePair -Devices $devices }
    $radioInput = $null
    $radioOutput = $null
    if ($WaveIn -or $WaveOut) {
        $audioPair = $null
        $radioInput = Read-WaveInSelection -Devices @($devices.wave_inputs)
        $radioOutput = Read-WaveOutSelection -Devices @($devices.wave_outputs)
    } else {
        $audioPair = Get-CompatibleAutoAudioPair -AudioPair $audioPair `
            -WaveInSelector $inputSelector -WaveOutSelector $outputSelector
        if ($inputSelector -cne 'auto') {
            $radioInput = Find-WaveEndpointById -Devices $devices -Direction input -EndpointId $inputSelector
        } elseif ($audioPair) {
            $radioInput = $audioPair.Input
        } else {
            $radioInput = Read-WaveInSelection -Devices @($devices.wave_inputs) -NoInteractive:$NoInteractive
        }
        if ($outputSelector -cne 'auto') {
            $radioOutput = Find-WaveEndpointById -Devices $devices -Direction output -EndpointId $outputSelector
        } elseif ($audioPair) {
            $radioOutput = $audioPair.Output
        } else {
            $radioOutput = Read-WaveOutSelection -Devices @($devices.wave_outputs) -NoInteractive:$NoInteractive
        }
        if ($audioPair -and $inputSelector -ceq 'auto' -and $outputSelector -ceq 'auto') {
            Write-Host '已选择名称含 USB Audio 的唯一 WaveIn 和 WaveOut。'
        }
    }
    $waveinEndpointId = [string]$radioInput.endpoint_id
    $waveoutEndpointId = [string]$radioOutput.endpoint_id
    if ([string]::IsNullOrWhiteSpace($waveinEndpointId) -or
        [string]::IsNullOrWhiteSpace($waveoutEndpointId)) {
        throw '本机 WinMM 未返回所选 WaveIn/WaveOut 的 endpoint ID；请检查 Windows 音频端点后重试。'
    }
    if ($selectedPreset -eq 'manual') {
        $profileChanged = Set-ResolvedProfileDevices -Profile $manualProfile `
            -NewProfile:$manualProfileWasCreated -SelectedPort $portName `
            -WaveInEndpointId $waveinEndpointId -WaveOutEndpointId $waveoutEndpointId `
            -PortOverride:($PSBoundParameters.ContainsKey('Port')) `
            -WaveInOverride:($PSBoundParameters.ContainsKey('WaveIn')) `
            -WaveOutOverride:($PSBoundParameters.ContainsKey('WaveOut')) `
            -SerialWasPrompted:$script:serialSelectionWasManual `
            -WaveInWasPrompted:$script:waveInSelectionWasManual `
            -WaveOutWasPrompted:$script:waveOutSelectionWasManual
        if ($profileChanged -and $manualProfileWasCreated) {
            Write-ConnectionProfile -Path $manualProfilePath -Profile $manualProfile
        }
    }
    if ($StatusDirectory) { $statusDirectoryPath = $StatusDirectory }
    else { $statusDirectoryPath = Join-Path $script:packageRoot 'logs' }
    $statusDirectory = Test-StatusDirectory -Path $statusDirectoryPath
    if ($selectedPreset -eq 'manual' -and -not $PrepareOnly) {
        $manualRunDirectoryName = 'bm-run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' +
            [guid]::NewGuid().ToString('N').Substring(0, 8)
        $statusDirectory = Test-StatusDirectory -Path (Join-Path $statusDirectory $manualRunDirectoryName)
    }
    $statusPath = Join-Path $statusDirectory ('bm-bridge-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    $script:statusPath = $statusPath
    $preparationPath = ''
    if ($PrepareOnly) {
        $preparationPath = [System.IO.Path]::GetFullPath($PreparationOutputPath)
        $preparationDirectory = [System.IO.Path]::GetDirectoryName($preparationPath)
        if (-not [System.IO.Directory]::Exists($preparationDirectory)) { throw '启动参数输出目录不存在。' }
        if ([System.IO.File]::Exists($preparationPath)) {
            throw '启动参数输出文件已存在；请为每次启动创建独立 run 目录。'
        }
    }
    $routingStatePath = ''
    if ($selectedPreset -eq 'manual') {
        $routingStatePath = Join-Path $statusDirectory 'routing-state.json'
        $routingStatePath = Write-RoutingStateFile -Path $routingStatePath -Profile $manualProfile
    }

    Write-Host ''
    $audioSummary = if ($audioPair) { 'USB Audio' } else { '已选择音频输入和输出' }
    $presetSummary = switch ($selectedPreset) {
        'parrot-cn' { '鹦鹉 460997' }
        'parrot-global' { '全球回声 9990' }
        'listen-46001' { '46001 组呼收听' }
        'listen-91' { 'TG91 组呼收听' }
        default { '手工 BM 配置' }
    }
    Write-Host ("请确认本次设备：{0} · {1} · {2}" -f $portName, $audioSummary, $presetSummary)
    Write-Host '等待 BM 和电台连接。'
    Write-Host ("电台回放增益：{0}x · 手咪发送增益：{1}x" -f `
        (Format-GainDecimal -GainMilli $audioSettings.RadioPlaybackGainMilli),
        (Format-GainDecimal -GainMilli $audioSettings.MicTransmitGainMilli))
    if ($selectedPreset -eq 'listen-91') {
        Write-Host '请在 BM SelfCare 为 Gateway 461135501 的 TS2 添加 TG91 静态订阅。连接后在电台扬声器收听，按 Q 停止并退出。'
    } elseif ($selectedPreset -eq 'listen-46001') {
        Write-Host '连接后在电台扬声器收听 BM 组呼，按 Q 停止并退出。'
    } elseif ($selectedPreset -eq 'parrot-cn' -or $selectedPreset -eq 'parrot-global') {
        Write-Host '连接后按住手咪讲话；松开后等待 BM 回声。按 Q 停止并退出。'
    } else {
        $txSummary = if ($manualProfile.tx_target.kind -ceq 'group') { '组呼' } else { '私呼' }
        $receiveGroupCount = @($manualProfile.rx_policy.allow_groups).Count
        $receivePrivateRouteCount = @($manualProfile.rx_policy.allow_private_peers).Count + @($manualProfile.rx_policy.local_private_routes).Count
        Write-Host ("TX: {0} {1} · RX策略：{2}个组呼允许项、{3}个私呼路由项；按 Q 停止并退出。" -f `
            $txSummary, $manualProfile.tx_target.destination_id, $receiveGroupCount, $receivePrivateRouteCount)
    }
    Write-Host ("COM: {0} · Radio WaveIn: ID {1} · {2}" -f $portName, $radioInput.id, $radioInput.name)
    Write-Host ("Radio WaveOut: ID {0} · {1}" -f $radioOutput.id, $radioOutput.name)
    if ($ManualPtt -and $selectedPreset -notin @('listen-46001', 'listen-91')) {
        Write-Host '诊断模式已启用：按 T 开始或结束 BM 上行。'
    }
    Write-Host ("状态报告：{0}" -f $statusPath)
    if ($routingStatePath) { Write-Host ("接收策略文件：{0}" -f $routingStatePath) }
    Write-Host ''
    $arguments = @('--run', '--port', $portName, '--body-file', $body,
        '--input', [string]$radioInput.id, '--output', [string]$radioOutput.id,
        '--status-file', $statusPath,
        '--expected-wavein-endpoint', $waveinEndpointId,
        '--expected-waveout-endpoint', $waveoutEndpointId,
        '--radio-playback-gain', (Format-GainDecimal -GainMilli $audioSettings.RadioPlaybackGainMilli),
        '--mic-transmit-gain', (Format-GainDecimal -GainMilli $audioSettings.MicTransmitGainMilli))
    if ($selectedPreset -ne 'manual') {
        $arguments += @('--test-preset', $selectedPreset, '--password-file', $passwordPath)
    } else {
        $arguments += Get-ProfileConnectionArgs -Profile $manualProfile -RoutingStatePath $routingStatePath
        if ($passwordPath) { $arguments += @('--password-file', $passwordPath) }
    }
    if ($ManualPtt) { $arguments += '--manual-ptt' }
    if ($PrepareOnly) {
        if ($selectedPreset -ne 'manual') { throw '桌面 UI 只接受完整手工连接配置，不使用固定测试预设。' }
        $arguments += @('--ui-pipe', '--ui-control-version', '2')
        $preparation = [ordered]@{
            schema_version = 1
            executable = [System.IO.Path]::GetFullPath($executable)
            arguments = @($arguments)
            status_path = $statusPath
            routing_state_path = $routingStatePath
            port = $portName
            wavein_id = [int]$radioInput.id
            waveout_id = [int]$radioOutput.id
            wavein_endpoint_id = $waveinEndpointId
            waveout_endpoint_id = $waveoutEndpointId
        }
        $preparationJson = ConvertTo-Json -InputObject $preparation -Depth 4
        $temporaryPreparationPath = $preparationPath + '.tmp-' + [guid]::NewGuid().ToString('N')
        try {
            [System.IO.File]::WriteAllText($temporaryPreparationPath, $preparationJson, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::Move($temporaryPreparationPath, $preparationPath)
        } finally {
            if ([System.IO.File]::Exists($temporaryPreparationPath)) { [System.IO.File]::Delete($temporaryPreparationPath) }
        }
        return
    }
    $script:nativeInvoked = $true
    & $executable @arguments
    $exitCode = [int]$LASTEXITCODE
    Write-Host "程序已退出，退出码：$exitCode"
    Write-Host "状态报告：$statusPath"
    exit $exitCode
} catch {
    if ($PrepareOnly) { throw }
    if ($script:nativeInvoked) {
        Write-Host "运行失败：$($_.Exception.Message)" -ForegroundColor Red
        if ($script:statusPath) { Write-Host "请检查状态报告：$($script:statusPath)" }
    } else {
        Write-Host "启动检查失败：$($_.Exception.Message)；请修正后重新启动。" -ForegroundColor Red
    }
    exit 2
}
