#requires -Version 5.1
Set-StrictMode -Version Latest

$script:WirexPortableConfigMaxBytes = 131072
$script:WirexPortableConfigMaxChannels = 256

function New-WirexPortableConfigDefaults {
    return [pscustomobject][ordered]@{
        schema_version = 1
        connection = [pscustomobject][ordered]@{
            callsign = ''; gateway_id = [uint64]0; source_id = [uint64]0
            master = '43.129.83.124'; master_port = [uint64]62031; color_code = [uint64]1
            password = ''; api_key = ''
        }
        devices = [pscustomobject][ordered]@{
            serial_port = 'auto'; hri_port = 'auto'; cat_port = 'auto'; cat_baud_rate = 38400
            cat_stop_bits = 'Two'; wave_in_endpoint_id = 'auto'; wave_out_endpoint_id = 'auto'
            desired_power_watts = 25
        }
        audio = [pscustomobject][ordered]@{ radio_playback_gain = [decimal]1.0; mic_transmit_gain = [decimal]16.0 }
        channels = [object[]]@([pscustomobject][ordered]@{ id = [uint64]460997; kind = 'private'; slot = 2; name = '460997' })
        tx_channel_id = 'private:460997:2'
        routing = [pscustomobject][ordered]@{ blocked_source_ids = [uint64[]]@() }
        ui = [pscustomobject][ordered]@{ bm_server_selection_id = 'bm-china-4602'; legacy_rx_policy = $null }
        window = [pscustomobject][ordered]@{}
    }
}

function Get-WirexPropertyValue {
    param([Parameter(Mandatory = $true)][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ceq $Name) { return $Object[$key] } }
        return $null
    }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-WirexHasProperty {
    param([Parameter(Mandatory = $true)][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ceq $Name) { return $true } }
        return $false
    }
    $matches = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    return ($matches.Count -gt 0)
}

function Test-WirexObject {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $false }
    return ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject])
}

function Assert-WirexJsonKeysUnique {
    param([Parameter(Mandatory = $true)][string]$JsonText)
    $objectKeys = New-Object System.Collections.ArrayList
    $insideString = $false
    $escaped = $false
    $stringStart = 0
    for ($index = 0; $index -lt $JsonText.Length; $index++) {
        $character = $JsonText[$index]
        if ($insideString) {
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') {
                $insideString = $false
                $rawString = $JsonText.Substring($stringStart, $index - $stringStart)
                $after = $index + 1
                while ($after -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$after])) { $after++ }
                if ($objectKeys.Count -gt 0 -and $after -lt $JsonText.Length -and $JsonText[$after] -eq ':') {
                    if ($rawString.Contains('\')) { throw '配置 JSON 字段名不能使用转义写法。' }
                    $keys = [System.Collections.Generic.HashSet[string]]$objectKeys[$objectKeys.Count - 1]
                    if (-not $keys.Add($rawString)) { throw '配置 JSON 存在重复字段。' }
                }
                continue
            }
            continue
        }
        if ($character -eq '"') { $insideString = $true; $stringStart = $index + 1; continue }
        if ($character -eq '{') {
            [void]$objectKeys.Add((New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)))
        } elseif ($character -eq '}') {
            if ($objectKeys.Count -eq 0) { throw '配置 JSON 对象结构无效。' }
            $objectKeys.RemoveAt($objectKeys.Count - 1)
        }
    }
    if ($insideString -or $objectKeys.Count -ne 0) { throw '配置 JSON 结构无效。' }
}

function Copy-WirexConfigValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [array]) {
        $copy = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $copy.Add((Copy-WirexConfigValue -Value $item)) }
        return ,([object[]]$copy.ToArray())
    }
    if (Test-WirexObject -Value $Value) {
        $copy = [ordered]@{}
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) { $copy[[string]$key] = Copy-WirexConfigValue -Value $Value[$key] }
        } else {
            foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = Copy-WirexConfigValue -Value $property.Value }
        }
        return $copy
    }
    return $Value
}

function Merge-WirexConfigObjects {
    param([Parameter(Mandatory = $true)][object]$Base, [Parameter(Mandatory = $true)][object]$Override)
    if (-not (Test-WirexObject -Value $Base) -or -not (Test-WirexObject -Value $Override)) {
        return Copy-WirexConfigValue -Value $Override
    }
    $merged = [ordered]@{}
    if ($Base -is [System.Collections.IDictionary]) {
        foreach ($key in $Base.Keys) { $merged[[string]$key] = Copy-WirexConfigValue -Value $Base[$key] }
    } else {
        foreach ($property in $Base.PSObject.Properties) { $merged[$property.Name] = Copy-WirexConfigValue -Value $property.Value }
    }
    $properties = if ($Override -is [System.Collections.IDictionary]) { @($Override.Keys | ForEach-Object { [pscustomobject]@{ Name=[string]$_; Value=$Override[$_] } }) } else { @($Override.PSObject.Properties) }
    foreach ($property in $properties) {
        $name = [string]$property.Name
        $baseName = @($merged.Keys | Where-Object { [string]$_ -ceq $name } | Select-Object -First 1)
        if ($baseName.Count -gt 0 -and (Test-WirexObject -Value $merged[$baseName[0]]) -and (Test-WirexObject -Value $property.Value)) {
            $merged[$baseName[0]] = Merge-WirexConfigObjects -Base $merged[$baseName[0]] -Override $property.Value
        } elseif ($name -ceq 'channels' -and $baseName.Count -gt 0 -and $merged[$baseName[0]] -is [array] -and $property.Value -is [array]) {
            $merged[$baseName[0]] = Merge-WirexChannelArrays -Base @($merged[$baseName[0]]) -Override @($property.Value)
        } else {
            $merged[$name] = Copy-WirexConfigValue -Value $property.Value
        }
    }
    return $merged
}

function Merge-WirexChannelArrays {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Base,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Override)
    $merged = New-Object 'System.Collections.Generic.List[object]'
    foreach ($channel in $Override) {
        $existing = $null
        if ((Test-WirexObject -Value $channel) -and (Test-WirexHasProperty -Object $channel -Name 'id') -and
            (Test-WirexHasProperty -Object $channel -Name 'kind') -and (Test-WirexHasProperty -Object $channel -Name 'slot')) {
            $key = '{0}:{1}:{2}' -f [string](Get-WirexPropertyValue -Object $channel -Name 'kind'),
                [string](Get-WirexPropertyValue -Object $channel -Name 'id'), [string](Get-WirexPropertyValue -Object $channel -Name 'slot')
            foreach ($prior in $Base) {
                if (-not (Test-WirexObject -Value $prior) -or -not (Test-WirexHasProperty -Object $prior -Name 'id') -or
                    -not (Test-WirexHasProperty -Object $prior -Name 'kind') -or -not (Test-WirexHasProperty -Object $prior -Name 'slot')) { continue }
                $priorKey = '{0}:{1}:{2}' -f [string](Get-WirexPropertyValue -Object $prior -Name 'kind'),
                    [string](Get-WirexPropertyValue -Object $prior -Name 'id'), [string](Get-WirexPropertyValue -Object $prior -Name 'slot')
                if ($priorKey -ceq $key) { $existing = $prior; break }
            }
        }
        if ($null -ne $existing) { $merged.Add((Merge-WirexConfigObjects -Base $existing -Override $channel)) }
        else { $merged.Add((Copy-WirexConfigValue -Value $channel)) }
    }
    return ,([object[]]$merged.ToArray())
}

function ConvertTo-WirexUnsigned {
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][uint64]$Maximum,
        [switch]$AllowZero)
    if ($null -eq $Value -or $Value -is [bool]) { throw "$Label 数值无效。" }
    $parsed = [uint64]0
    $text = [string]$Value
    if ($Value -is [string]) {
        if ($text -cnotmatch '^(0|[1-9][0-9]*)$') { throw "$Label 数值无效。" }
    } elseif ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
              $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) {
        throw "$Label 数值无效。"
    }
    if (-not [uint64]::TryParse($text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or
        $parsed -gt $Maximum -or (-not $AllowZero -and $parsed -eq 0)) { throw "$Label 超出允许范围。" }
    return $parsed
}

function ConvertTo-WirexGain {
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$Label)
    if ($null -eq $Value -or $Value -is [bool]) { throw "$Label 数值无效。" }
    $text = if ($Value -is [string]) { $Value } else { ([decimal]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($text -cnotmatch '^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?$') { throw "$Label 数值无效。" }
    $gain = [decimal]0
    if (-not [decimal]::TryParse($text, [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$gain) -or
        $gain -lt [decimal]0.25 -or $gain -gt [decimal]16) { throw "$Label 超出允许范围。" }
    return $gain
}

function Get-WirexChannelKey {
    param([Parameter(Mandatory = $true)][object]$Channel)
    return ('{0}:{1}:{2}' -f [string]$Channel.kind, [uint64]$Channel.id, [int]$Channel.slot)
}

function Assert-WirexStoredConfigShape {
    param([Parameter(Mandatory = $true)][object]$Config)
    if (-not (Test-WirexObject -Value $Config)) { throw 'config.json 必须是 JSON 对象；原文件已保留。' }
    foreach ($name in @('schema_version','connection','devices','audio','channels','tx_channel_id','routing','ui','window')) {
        if (-not (Test-WirexHasProperty -Object $Config -Name $name)) { throw 'config.json 缺少必需字段；原文件已保留。' }
    }
    $required = [ordered]@{
        connection=@('callsign','gateway_id','source_id','master','master_port','color_code','password','api_key')
        devices=@('serial_port','hri_port','cat_port','cat_baud_rate','cat_stop_bits','wave_in_endpoint_id','wave_out_endpoint_id','desired_power_watts')
        audio=@('radio_playback_gain','mic_transmit_gain')
        routing=@('blocked_source_ids')
        ui=@('bm_server_selection_id','legacy_rx_policy')
    }
    foreach ($section in $required.Keys) {
        $value = Get-WirexPropertyValue -Object $Config -Name $section
        if (-not (Test-WirexObject -Value $value)) { throw 'config.json 含有不完整字段组；原文件已保留。' }
        foreach ($name in $required[$section]) {
            if (-not (Test-WirexHasProperty -Object $value -Name $name)) { throw 'config.json 含有不完整字段组；原文件已保留。' }
        }
    }
}

function ConvertTo-WirexPortableConfig {
    param([Parameter(Mandatory = $true)][object]$Config)
    if (-not (Test-WirexObject -Value $Config)) { throw '便携配置必须是 JSON 对象。' }
    $defaults = New-WirexPortableConfigDefaults
    $merged = Merge-WirexConfigObjects -Base $defaults -Override $Config
    if ((ConvertTo-WirexUnsigned -Value $merged.schema_version -Label 'schema_version' -Maximum 1) -ne 1) { throw '便携配置版本不受支持。' }

    foreach ($name in @('connection','devices','audio','routing','ui','window')) {
        if (-not (Test-WirexObject -Value $merged[$name])) { throw "便携配置 $name 必须是对象。" }
    }
    foreach ($name in @('channels')) { if ($merged[$name] -isnot [array]) { throw "便携配置 $name 必须是有序数组。" } }

    $connection = $merged.connection
    foreach ($name in @('callsign','gateway_id','source_id','master','master_port','color_code','password','api_key')) {
        if (-not (Test-WirexHasProperty -Object $connection -Name $name)) { throw "connection 缺少字段 $name。" }
    }
    if ($connection.callsign -isnot [string] -or ($connection.callsign -and $connection.callsign -cnotmatch '^[\x20-\x7e]{1,8}$') -or
        $connection.master -isnot [string] -or ($connection.master -and ($connection.master.Length -gt 253 -or $connection.master -match '\s')) -or
        $connection.password -isnot [string] -or $connection.password.Length -gt 4096 -or
        $connection.api_key -isnot [string] -or $connection.api_key.Length -gt 8192) { throw 'connection 字段格式无效。' }
    $connection.gateway_id = ConvertTo-WirexUnsigned -Value $connection.gateway_id -Label 'connection.gateway_id' -Maximum 4294967295 -AllowZero
    $connection.source_id = ConvertTo-WirexUnsigned -Value $connection.source_id -Label 'connection.source_id' -Maximum 16777215 -AllowZero
    $connection.master_port = ConvertTo-WirexUnsigned -Value $connection.master_port -Label 'connection.master_port' -Maximum 65535 -AllowZero
    $connection.color_code = ConvertTo-WirexUnsigned -Value $connection.color_code -Label 'connection.color_code' -Maximum 15 -AllowZero

    $devices = $merged.devices
    foreach ($name in @('serial_port','hri_port','cat_port')) {
        if (-not (Test-WirexHasProperty -Object $devices -Name $name) -or $devices[$name] -isnot [string] -or
            ($devices[$name] -cne 'auto' -and $devices[$name] -cnotmatch '^COM[1-9][0-9]{0,2}$')) { throw "devices.$name 必须是 auto 或 COM1 到 COM999。" }
    }
    $devices.serial_port = [string]$devices.hri_port
    $devices.hri_port = ([string]$devices.hri_port).ToUpperInvariant() -replace '^AUTO$','auto'
    $devices.serial_port = $devices.hri_port
    $devices.cat_port = ([string]$devices.cat_port).ToUpperInvariant() -replace '^AUTO$','auto'
    foreach ($name in @('wave_in_endpoint_id','wave_out_endpoint_id')) {
        if (-not (Test-WirexHasProperty -Object $devices -Name $name) -or $devices[$name] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($devices[$name]) -or $devices[$name].Length -gt 4096) { throw "devices.$name 字段格式无效。" }
    }
    $devices.cat_baud_rate = [int](ConvertTo-WirexUnsigned -Value $devices.cat_baud_rate -Label 'devices.cat_baud_rate' -Maximum 115200)
    if ($devices.cat_baud_rate -notin @(4800,9600,19200,38400,115200) -or $devices.cat_stop_bits -cne 'Two') { throw 'CAT 串口设置无效；停止位固定为 Two。' }
    $devices.desired_power_watts = [int](ConvertTo-WirexUnsigned -Value $devices.desired_power_watts -Label 'devices.desired_power_watts' -Maximum 50)
    if ($devices.desired_power_watts -lt 5) { throw 'devices.desired_power_watts 超出允许范围。' }

    $merged.audio.radio_playback_gain = ConvertTo-WirexGain -Value $merged.audio.radio_playback_gain -Label 'audio.radio_playback_gain'
    $merged.audio.mic_transmit_gain = ConvertTo-WirexGain -Value $merged.audio.mic_transmit_gain -Label 'audio.mic_transmit_gain'

    if ($merged.channels.Count -gt $script:WirexPortableConfigMaxChannels) { throw '频道数量超出允许范围。' }
    $channels = New-Object 'System.Collections.Generic.List[object]'
    $seenChannels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($channel in $merged.channels) {
        if (-not (Test-WirexObject -Value $channel)) { throw '频道项目必须是对象。' }
        foreach ($name in @('id','kind','slot','name')) { if (-not (Test-WirexHasProperty -Object $channel -Name $name)) { throw "频道项目缺少字段 $name。" } }
        $id = ConvertTo-WirexUnsigned -Value $channel.id -Label 'channel.id' -Maximum 16777215
        $slot = ConvertTo-WirexUnsigned -Value $channel.slot -Label 'channel.slot' -Maximum 2
        if ($slot -notin @(1,2) -or $channel.kind -isnot [string] -or $channel.kind -cnotin @('group','private') -or
            $channel.name -isnot [string] -or [string]::IsNullOrWhiteSpace($channel.name) -or $channel.name.Length -gt 40 -or $channel.name -match '\p{C}') {
            throw '频道项目字段格式无效。'
        }
        $normalized = Copy-WirexConfigValue -Value $channel
        $normalized.id = [uint64]$id
        $normalized.kind = [string]$channel.kind
        $normalized.slot = [int]$slot
        $normalized.name = [string]$channel.name
        $key = Get-WirexChannelKey -Channel $normalized
        if (-not $seenChannels.Add($key)) { throw '频道列表存在重复的类型、ID 和时隙。' }
        $channels.Add($normalized)
    }
    $merged.channels = [object[]]$channels.ToArray()
    if ($merged.tx_channel_id -isnot [string]) { throw 'tx_channel_id 必须是频道 tuple key 字符串。' }
    if ($merged.channels.Count -eq 0 -and $merged.tx_channel_id) { throw '频道列表为空时 tx_channel_id 必须为空。' }
    if ($merged.channels.Count -gt 0 -and -not $merged.tx_channel_id) { $merged.tx_channel_id = Get-WirexChannelKey -Channel $merged.channels[0] }
    if ($merged.tx_channel_id -and -not $seenChannels.Contains([string]$merged.tx_channel_id)) { throw 'tx_channel_id 没有对应的频道项目。' }
    if ($merged.tx_channel_id) {
        $txChannel = @($merged.channels | Where-Object { (Get-WirexChannelKey -Channel $_) -ceq [string]$merged.tx_channel_id } | Select-Object -First 1)
        if ($txChannel.Count -ne 1) { throw 'tx_channel_id 没有对应的频道项目。' }
    }

    if ($merged.routing.blocked_source_ids -isnot [array]) { throw 'routing.blocked_source_ids 必须是数组。' }
    $blocked = New-Object 'System.Collections.Generic.List[uint64]'
    $seenBlocked = New-Object 'System.Collections.Generic.HashSet[uint64]'
    foreach ($value in $merged.routing.blocked_source_ids) {
        $id = ConvertTo-WirexUnsigned -Value $value -Label 'routing.blocked_source_ids' -Maximum 16777215
        if (-not $seenBlocked.Add([uint64]$id)) { throw 'routing.blocked_source_ids 存在重复 ID。' }
        $blocked.Add([uint64]$id)
    }
    $merged.routing.blocked_source_ids = [uint64[]]$blocked.ToArray()
    if ($merged.ui.bm_server_selection_id -isnot [string] -or
        ($merged.ui.bm_server_selection_id -and $merged.ui.bm_server_selection_id -cnotmatch '^(custom|bm-[a-z0-9-]+)$')) {
        throw 'ui.bm_server_selection_id 字段格式无效。'
    }
    if ($null -ne $merged.ui.legacy_rx_policy -and -not (Test-WirexObject -Value $merged.ui.legacy_rx_policy)) { throw 'ui.legacy_rx_policy 必须是对象或 null。' }
    Assert-WirexNoCredentialPathProperties -Value $merged
    return $merged
}

function Assert-WirexNoCredentialPathProperties {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [array]) { foreach ($item in $Value) { Assert-WirexNoCredentialPathProperties -Value $item }; return }
    if (-not (Test-WirexObject -Value $Value)) { return }
    $properties = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name=[string]$_; Value=$Value[$_] } }) } else { @($Value.PSObject.Properties) }
    foreach ($property in $properties) {
        $propertyName = [string]$property.Name
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($propertyName, 'password_file_path') -or
            [System.StringComparer]::OrdinalIgnoreCase.Equals($propertyName, 'api_key_file_path') -or
            [System.StringComparer]::OrdinalIgnoreCase.Equals($propertyName, 'apikey_file_path')) {
            throw 'config.json 不能保存凭据文件路径；请把凭据值存入 connection。'
        }
        Assert-WirexNoCredentialPathProperties -Value $property.Value
    }
}

function Read-WirexPortableConfigFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    if ((New-Object System.IO.FileInfo($Path)).Length -gt $script:WirexPortableConfigMaxBytes) { throw 'config.json 超过 128 KiB；原文件已保留。' }
    try {
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        Assert-WirexJsonKeysUnique -JsonText $json
        $document = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        Assert-WirexStoredConfigShape -Config $document
        return ConvertTo-WirexPortableConfig -Config $document
    } catch {
        if ($_.Exception.Message -like 'config.json*' -or $_.Exception.Message -like '便携配置*' -or $_.Exception.Message -like 'connection *' -or
            $_.Exception.Message -like 'devices.*' -or $_.Exception.Message -like 'audio.*' -or $_.Exception.Message -like '频道*' -or $_.Exception.Message -like 'tx_channel_id*' -or
            $_.Exception.Message -like 'routing.*' -or $_.Exception.Message -like 'ui.*' -or $_.Exception.Message -like 'CAT *' -or $_.Exception.Message -like 'config.json 不能*') { throw }
        throw 'config.json JSON 无效；原文件已保留。'
    }
}

function Import-WirexLegacyCredential {
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateSet('password','api_key')][string]$Kind)
    if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "旧 $Kind 文件必须使用完整路径；原文件已保留。" }
    if (-not [System.IO.File]::Exists($Path)) { throw "旧 $Kind 指针指向的文件不存在；原文件已保留。" }
    try { $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    catch { throw "旧配置中的 $Kind 文件无法读取；原文件已保留。" }
    if ($Kind -ceq 'password') {
        $value = $content.TrimEnd([char[]]@([char]13,[char]10))
        if ($value.Contains("`r") -or $value.Contains("`n")) { throw '旧密码文件格式无效；原文件已保留。' }
        return $value
    }
    $candidate = $content.Trim()
    if ($candidate -match '(?im)^\s*apikey\s*=\s*(\S+)\s*$') { $candidate = $Matches[1] }
    if ($candidate.Length -lt 200 -or $candidate -cnotmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
        throw '旧 BM API key 文件格式无效；原文件已保留。'
    }
    return $candidate
}

function Read-WirexLegacyPointerCredential {
    param([Parameter(Mandatory = $true)][string]$PointerPath, [ValidateSet('password','api_key')][string]$Kind)
    if (-not [System.IO.File]::Exists($PointerPath)) { return '' }
    try { $lines = [System.IO.File]::ReadAllLines($PointerPath, [System.Text.Encoding]::UTF8) }
    catch { throw "旧 $Kind 指针无法读取；原文件已保留。" }
    if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0]) -or -not [System.IO.Path]::IsPathRooted($lines[0].Trim())) {
        throw "旧 $Kind 指针必须是单行完整文件路径；原文件已保留。"
    }
    return Import-WirexLegacyCredential -Path $lines[0].Trim() -Kind $Kind
}

function Add-WirexMigratedChannel {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Channels,
        [Parameter(Mandatory = $true)][uint64]$Id, [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][uint64]$Slot)
    if ($Id -lt 1 -or $Id -gt 16777215 -or $Slot -notin @(1,2) -or $Kind -cnotin @('group','private')) { return }
    $channel = [pscustomobject][ordered]@{ id=[uint64]$Id; kind=$Kind; slot=[int]$Slot; name=[string]$Id }
    $key = Get-WirexChannelKey -Channel $channel
    foreach ($existing in $Channels) { if ((Get-WirexChannelKey -Channel $existing) -ceq $key) { return } }
    $Channels.Add($channel)
}

function Import-WirexLegacyConfig {
    param([Parameter(Mandatory = $true)][string]$LegacyDirectory)
    $config = New-WirexPortableConfigDefaults
    $legacyRoot = [System.IO.Path]::GetFullPath($LegacyDirectory)
    if (-not [System.IO.Directory]::Exists($legacyRoot)) { throw '指定的旧配置目录不存在；没有改动配置文件。' }
    $profilePath = Join-Path $legacyRoot 'connection-profile.json'
    if ([System.IO.File]::Exists($profilePath)) {
        $bridgeConfigModule = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\tools\bridge-user-config.psm1'))
        if (-not [System.IO.File]::Exists($bridgeConfigModule)) { throw '迁移所需的旧连接配置读取模块缺失。' }
        Import-Module -Name $bridgeConfigModule -Force -ErrorAction Stop
        try { $profile = Read-BridgeUserConnectionProfile -Path $profilePath }
        catch { throw '旧连接配置无效；旧配置文件已保留，没有迁移。' }
        if ($null -ne $profile) {
            foreach ($name in @('callsign','gateway_id','source_id','master','master_port','color_code')) {
                $config.connection.PSObject.Properties[$name].Value = $profile.connection.$name
            }
            $config.devices.serial_port = [string]$profile.devices.serial_port
            $config.devices.hri_port = [string]$profile.devices.serial_port
            $config.devices.wave_in_endpoint_id = [string]$profile.devices.wave_in_endpoint_id
            $config.devices.wave_out_endpoint_id = [string]$profile.devices.wave_out_endpoint_id
            $routes = $profile.rx_policy
            $channels = New-Object 'System.Collections.Generic.List[object]'
            foreach ($route in @($routes.allow_groups)) { Add-WirexMigratedChannel -Channels $channels -Id ([uint64]$route.destination_id) -Kind group -Slot ([uint64]$route.slot) }
            foreach ($route in @($routes.allow_private_peers)) { Add-WirexMigratedChannel -Channels $channels -Id ([uint64]$route.source_id) -Kind private -Slot ([uint64]$route.slot) }
            foreach ($route in @($routes.local_private_routes)) { Add-WirexMigratedChannel -Channels $channels -Id ([uint64]$route.local_destination_id) -Kind private -Slot ([uint64]$route.slot) }
            Add-WirexMigratedChannel -Channels $channels -Id ([uint64]$profile.tx_target.destination_id) -Kind ([string]$profile.tx_target.kind) -Slot ([uint64]$profile.tx_target.slot)
            if ($channels.Count -eq 0) { Add-WirexMigratedChannel -Channels $channels -Id 460997 -Kind private -Slot 2 }
            $config.channels = [object[]]$channels.ToArray()
            $config.tx_channel_id = Get-WirexChannelKey -Channel ([pscustomobject]@{ id=[uint64]$profile.tx_target.destination_id; kind=[string]$profile.tx_target.kind; slot=[int]$profile.tx_target.slot })
            $config.routing.blocked_source_ids = [uint64[]]@($routes.blocked_source_ids)
            $config.ui.legacy_rx_policy = Copy-WirexConfigValue -Value $routes
        }
    }

    $audioPath = Join-Path $legacyRoot 'audio-settings.json'
    if ([System.IO.File]::Exists($audioPath)) {
        if (-not (Get-Command -Name Read-BridgeAudioSettings -ErrorAction SilentlyContinue)) {
            $bridgeConfigModule = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\tools\bridge-user-config.psm1'))
            Import-Module -Name $bridgeConfigModule -Force -ErrorAction Stop
        }
        try { $oldAudio = Read-BridgeAudioSettings -Path $audioPath }
        catch { throw '旧音量设置无效；旧配置文件已保留，没有迁移。' }
        if ($null -ne $oldAudio) {
            $config.audio.radio_playback_gain = [decimal]::Parse((Format-BridgeGain -GainMilli ([uint32]$oldAudio.RadioPlaybackGainMilli)), [Globalization.CultureInfo]::InvariantCulture)
            $config.audio.mic_transmit_gain = [decimal]::Parse((Format-BridgeGain -GainMilli ([uint32]$oldAudio.MicTransmitGainMilli)), [Globalization.CultureInfo]::InvariantCulture)
        }
    }

    $radioPreferencesPath = Join-Path $legacyRoot 'radio-control-preferences.json'
    if ([System.IO.File]::Exists($radioPreferencesPath)) {
        try { $radio = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($radioPreferencesPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop }
        catch { throw '旧电台控制偏好 JSON 无效；旧配置文件已保留，没有迁移。' }
        $radioNames = @($radio.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($radio -isnot [System.Management.Automation.PSCustomObject] -or $radioNames.Count -ne 5 -or
            @($radioNames | Where-Object { $_ -cnotin @('schema_version','cat_port','baud_rate','stop_bits','desired_power_watts') }).Count -gt 0 -or
            [int]$radio.schema_version -ne 1 -or $radio.cat_port -isnot [string] -or $radio.baud_rate -is [bool] -or
            [int]$radio.baud_rate -notin @(4800,9600,19200,38400,115200) -or $radio.desired_power_watts -is [bool] -or
            [int]$radio.desired_power_watts -lt 5 -or [int]$radio.desired_power_watts -gt 50) {
            throw '旧电台控制偏好字段无效；旧配置文件已保留，没有迁移。'
        }
        $config.devices.cat_port = if ([string]$radio.cat_port -ceq 'auto') { 'auto' } else { ([string]$radio.cat_port).ToUpperInvariant() }
        $config.devices.cat_baud_rate = [int]$radio.baud_rate
        $config.devices.cat_stop_bits = 'Two'
        $config.devices.desired_power_watts = [int]$radio.desired_power_watts
    }

    $serverPath = Join-Path $legacyRoot 'bm-server-preferences.json'
    if ([System.IO.File]::Exists($serverPath)) {
        try { $server = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($serverPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop }
        catch { throw '旧 BM 服务器偏好 JSON 无效；旧配置文件已保留，没有迁移。' }
        $serverNames = @($server.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($server -isnot [System.Management.Automation.PSCustomObject] -or $serverNames.Count -ne 2 -or
            @($serverNames | Where-Object { $_ -cnotin @('schema_version','bm_server_selection_id') }).Count -gt 0 -or
            [int]$server.schema_version -ne 1 -or $server.bm_server_selection_id -isnot [string]) {
            throw '旧 BM 服务器偏好字段无效；旧配置文件已保留，没有迁移。'
        }
        $config.ui.bm_server_selection_id = [string]$server.bm_server_selection_id
    }

    $managementPath = Join-Path $legacyRoot 'bm-management-preferences.json'
    if ([System.IO.File]::Exists($managementPath)) {
        try { $management = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($managementPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop }
        catch { throw '旧 BM API 偏好 JSON 无效；旧配置文件已保留，没有迁移。' }
        $managementNames = @($management.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($management -isnot [System.Management.Automation.PSCustomObject] -or $managementNames.Count -ne 2 -or
            @($managementNames | Where-Object { $_ -cnotin @('schema_version','api_key_file_path') }).Count -gt 0 -or
            [int]$management.schema_version -ne 1 -or $management.api_key_file_path -isnot [string]) {
            throw '旧 BM API 偏好字段无效；旧配置文件已保留，没有迁移。'
        }
        if ($management.api_key_file_path) {
            $config.connection.api_key = Import-WirexLegacyCredential -Path ([string]$management.api_key_file_path) -Kind api_key
        }
    }

    $passwordPath = Join-Path $legacyRoot 'password-file-path.txt'
    if ([System.IO.File]::Exists($passwordPath)) { $config.connection.password = Read-WirexLegacyPointerCredential -PointerPath $passwordPath -Kind password }
    return ConvertTo-WirexPortableConfig -Config $config
}

function Get-WirexPortableConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][AllowEmptyString()][string]$LegacyDirectory)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $document = Read-WirexPortableConfigFile -Path $fullPath
    if ($null -ne $document) { return $document }
    if (-not [string]::IsNullOrWhiteSpace($LegacyDirectory)) { return Import-WirexLegacyConfig -LegacyDirectory $LegacyDirectory }
    return New-WirexPortableConfigDefaults
}

function Save-WirexPortableConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true)][object]$Config)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw 'config.json 所在目录不存在；没有写入配置。' }
    $existing = Read-WirexPortableConfigFile -Path $fullPath
    $base = if ($null -ne $existing) { $existing } else { New-WirexPortableConfigDefaults }
    $merged = Merge-WirexConfigObjects -Base $base -Override $Config
    $validated = ConvertTo-WirexPortableConfig -Config $merged
    $temporaryPath = $fullPath + '.backup-tmp-' + [guid]::NewGuid().ToString('N')
    $backupPath = $fullPath + '.backup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    try {
        $json = (ConvertTo-Json -InputObject $validated -Depth 24) + "`n"
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt $script:WirexPortableConfigMaxBytes) { throw 'config.json 超过 128 KiB；没有写入配置。' }
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($fullPath)) { [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath) }
        else { [System.IO.File]::Move($temporaryPath, $fullPath) }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
        if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
    }
    return $validated
}

Export-ModuleMember -Function Get-WirexPortableConfig, Save-WirexPortableConfig
