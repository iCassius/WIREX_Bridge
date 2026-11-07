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

    $profilePath = Join-Path $configPath 'connection-profile.json'
    $legacyConnection = [pscustomobject][ordered]@{
        callsign = 'N0CALL'; gateway_id = [uint64]460999901; source_id = [uint64]4609999
        master = '43.129.83.124'; master_port = [uint64]62031; destination_id = [uint64]460997
        slot = [uint64]2; color_code = [uint64]0; call_kind = 'private'
    }
    $profileDevices = [pscustomobject][ordered]@{
        serial_port = 'COM5'; wave_in_endpoint_id = 'usb-in'; wave_out_endpoint_id = 'usb-out'
    }
    $legacyProfile = [pscustomobject][ordered]@{ schema_version=1; connection=$legacyConnection; devices=$profileDevices }
    $legacyOriginal = (ConvertTo-Json -InputObject $legacyProfile -Depth 5) + "`n"
    [System.IO.File]::WriteAllText($profilePath, $legacyOriginal, (New-Object System.Text.UTF8Encoding($false)))
    $legacyOriginalBytes = [System.IO.File]::ReadAllBytes($profilePath)
    $legacyPrivate = Read-BridgeUserConnectionProfile -Path $profilePath
    Assert-True ($legacyPrivate.schema_version -eq 2 -and $legacyPrivate.tx_target.destination_id -eq 460997 -and
        $legacyPrivate.rx_policy.private_mode -ceq 'all_peers_to_local' -and
        $legacyPrivate.rx_policy.local_private_routes.Count -eq 1 -and
        $legacyPrivate.rx_policy.local_private_routes[0].local_destination_id -eq 4609999 -and
        $legacyPrivate.transmit_enabled -and $legacyPrivate.migration_source_schema_version -eq 1) `
        'v1 私呼配置在内存中迁为 schema 2，TX 目标、任意私呼 peer 和本机 ID 均保留'
    Assert-True ([System.IO.File]::ReadAllText($profilePath, [System.Text.Encoding]::UTF8) -ceq $legacyOriginal) `
        '读取 v1 配置只生成内存迁移视图，不写回原文件'
    $legacyRuntime = Get-BridgeLegacyRuntimeProfile -Profile $legacyPrivate
    Assert-True ($legacyRuntime.connection.destination_id -eq 460997 -and
        $legacyRuntime.receive.destination_id -eq 4609999 -and $legacyRuntime.receive.call_kind -ceq 'private') `
        'alpha4投影保留旧私呼 TX 目标与本机私呼接收过滤'
    Write-BridgeUserConnectionProfile -Path $profilePath -Profile $legacyPrivate
    $backupPaths = @(Get-ChildItem -LiteralPath $configPath -Filter 'connection-profile.json.bak-*' | Select-Object -ExpandProperty FullName)
    Assert-True ($backupPaths.Count -eq 1 -and
        [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($backupPaths[0])) -ceq
        [System.Convert]::ToBase64String($legacyOriginalBytes)) '用户明确保存时按原始字节保留 v1 文件备份'
    $savedProfile = Read-BridgeUserConnectionProfile -Path $profilePath
    Assert-True ($savedProfile.schema_version -eq 2 -and $savedProfile.tx_target.kind -ceq 'private' -and
        $savedProfile.rx_policy.local_private_routes.Count -eq 1) '用户保存后写入完整 schema 2 配置'

    $legacyConnection.call_kind = 'group'
    $legacyConnection.destination_id = [uint64]91
    $legacyDocument = [pscustomobject][ordered]@{ schema_version=1; connection=$legacyConnection; devices=$profileDevices }
    [System.IO.File]::WriteAllText($profilePath, (ConvertTo-Json -InputObject $legacyDocument -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))
    $legacyGroup = Read-BridgeUserConnectionProfile -Path $profilePath
    Assert-True ($legacyGroup.rx_policy.group_mode -ceq 'selected' -and $legacyGroup.rx_policy.allow_groups.Count -eq 1 -and
        $legacyGroup.rx_policy.allow_groups[0].destination_id -eq 91 -and $legacyGroup.tx_target.destination_id -eq 91) `
        '旧组呼配置缺少 receive 时迁为 Selected 原组目标'
    $legacyConnection.call_kind = 'private'
    $legacyConnection.destination_id = [uint64]460997
    $legacyDocument.connection = $legacyConnection
    Add-Member -InputObject $legacyDocument -NotePropertyName receive `
        -NotePropertyValue ([pscustomobject][ordered]@{ destination_id=[uint64]456789; slot=[uint64]1; call_kind='private' }) -Force
    [System.IO.File]::WriteAllText($profilePath, (ConvertTo-Json -InputObject $legacyDocument -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-BridgeUserConnectionProfile -Path $profilePath | Out-Null } `
        '旧配置把私呼收件目标设为非本机 Source ID 时拒绝静默改写'
    $legacyDocument.receive.destination_id = [uint64]4609999
    [System.IO.File]::WriteAllText($profilePath, (ConvertTo-Json -InputObject $legacyDocument -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))
    $customPrivate = Read-BridgeUserConnectionProfile -Path $profilePath
    Assert-True ($customPrivate.rx_policy.local_private_routes[0].local_destination_id -eq 4609999 -and
        $customPrivate.rx_policy.local_private_routes[0].slot -eq 1 -and
        $customPrivate.rx_policy.allow_private_peers.Count -eq 1 -and
        $customPrivate.rx_policy.allow_private_peers[0].source_id -eq 460997 -and
        $customPrivate.rx_policy.allow_private_peers[0].local_destination_id -eq 4609999 -and
        $customPrivate.rx_policy.allow_private_peers[0].slot -eq 2) `
        '旧 receive.private 迁为本机任意 peer 路由，并另外保存不在主路由内的精确TX回程'
    $legacyConnection.call_kind = 'private'
    $legacyConnection.destination_id = [uint64]460997
    $legacyDocument.connection = $legacyConnection
    $legacyDocument.receive = [pscustomobject][ordered]@{ destination_id=[uint64]91; slot=[uint64]2; call_kind='group' }
    Add-Member -InputObject $legacyDocument -NotePropertyName transmit_enabled -NotePropertyValue $true -Force
    [System.IO.File]::WriteAllText($profilePath, (ConvertTo-Json -InputObject $legacyDocument -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))
    $groupWithPrivateTx = Read-BridgeUserConnectionProfile -Path $profilePath
    Assert-True ($groupWithPrivateTx.rx_policy.allow_groups.Count -eq 1 -and
        $groupWithPrivateTx.rx_policy.allow_private_peers.Count -eq 1 -and
        $groupWithPrivateTx.rx_policy.allow_private_peers[0].source_id -eq 460997) `
        '旧组呼主路由与开启的TX私呼回程分别保存在RX策略中'
    $groupWithPrivateTxLegacy = Get-BridgeLegacyRuntimeProfile -Profile $groupWithPrivateTx
    Assert-True ($groupWithPrivateTxLegacy.receive.destination_id -eq 91 -and
        $groupWithPrivateTxLegacy.connection.destination_id -eq 460997) `
        'alpha4旧主过滤器和TX私呼精确回程可以被完整表达'

    $v2Connection = [pscustomobject][ordered]@{
        callsign='N0CALL'; gateway_id=[uint64]460999901; source_id=[uint64]4609999
        master='43.129.83.124'; master_port=[uint64]62031; color_code=[uint64]0
    }
    $v2Target = [pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
    $v2Devices = [pscustomobject][ordered]@{ serial_port='COM5'; wave_in_endpoint_id='usb-in'; wave_out_endpoint_id='usb-out' }
    $v2Policy = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='disabled'; allow_groups=@(); allow_private_peers=@()
        local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
    }
    foreach ($invalidProfile in @(
        '{"schema_version":1,"connection":{},"devices":{},"receive":null}',
        '{"schema_version":1,"connection":{},"devices":{},"transmit_enabled":null}',
        '{"schema_version":1,"connection":{},"devices":{},"receive":{"destination_id":91,"slot":2}}',
        '{"schema_version":1,"connection":{},"devices":{},"transmit_enabled":"false"}',
        '{"schema_version":2,"connection":{},"tx_target":{},"devices":{},"rx_policy":{},"transmit_enabled":true,"extra":0}',
        '{"schema_version":2,"connection":{},"tx_target":{},"devices":{},"rx_policy":{},"transmit_enabled":1}'
    )) {
        [System.IO.File]::WriteAllText($profilePath, $invalidProfile, (New-Object System.Text.UTF8Encoding($false)))
        Assert-Throws { Read-BridgeUserConnectionProfile -Path $profilePath | Out-Null } 'v1/v2 配置缺字段、未知字段、空对象或类型错误时拒绝'
    }
    $validV2 = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Target -Devices $v2Devices `
        -RxPolicy ([pscustomobject][ordered]@{
            group_mode='selected'; private_mode='selected_peers'
            allow_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 }, [pscustomobject]@{ destination_id=[uint64]46000; slot=[uint64]1 })
            allow_private_peers=@([pscustomobject]@{ source_id=[uint64]800001; local_destination_id=[uint64]4609999; slot=[uint64]2 })
            local_private_routes=@(); blocked_groups=@([pscustomobject]@{ destination_id=[uint64]46001; slot=[uint64]1 })
            blocked_source_ids=@([uint64]812345)
        }) -TransmitEnabled $false
    Assert-True ($validV2.rx_policy.allow_groups.Count -eq 2 -and $validV2.rx_policy.blocked_source_ids[0] -eq 812345 -and
        -not $validV2.transmit_enabled) 'schema 2 完整接收策略可在内存中加载和预览'
    Assert-Throws { Get-BridgeLegacyRuntimeProfile -Profile $validV2 } '多组、block 与 peer 过滤不能静默截断为 alpha4 单路由'
    $badPairPolicy = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='disabled'; allow_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 })
        allow_private_peers=@(); local_private_routes=@(); blocked_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 }); blocked_source_ids=@()
    }
    Assert-Throws { ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Target -Devices $v2Devices -RxPolicy $badPairPolicy -TransmitEnabled $true } `
        '同一组呼不能同时位于 allow 与 block'
    $selectedPeerWithLocalRoute = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='selected_peers'; allow_groups=@()
        allow_private_peers=@([pscustomobject]@{source_id=[uint64]460997;local_destination_id=[uint64]4609999;slot=[uint64]2})
        local_private_routes=@([pscustomobject]@{local_destination_id=[uint64]4609999;slot=[uint64]2})
        blocked_groups=@(); blocked_source_ids=@()
    }
    Assert-Throws { ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Target `
        -Devices $v2Devices -RxPolicy $selectedPeerWithLocalRoute -TransmitEnabled $true } `
        'selected_peers 不能用 local_private_routes 扩大为任意私呼'
    $allDelivered = [pscustomobject][ordered]@{
        group_mode='all_delivered'; private_mode='disabled'; allow_groups=@(); allow_private_peers=@()
        local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
    }
    $allDeliveredProfile = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Target -Devices $v2Devices -RxPolicy $allDelivered -TransmitEnabled $true
    Assert-Throws { Get-BridgeLegacyRuntimeProfile -Profile $allDeliveredProfile } 'alpha4不能运行 AllDelivered 策略'

    $privateDisabled = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='disabled'; allow_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 })
        allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
    }
    $v2TargetPrivate = [pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
    $privateDisabledProfile = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2TargetPrivate `
        -Devices $v2Devices -RxPolicy $privateDisabled -TransmitEnabled $true
    Assert-Throws { Get-BridgeLegacyRuntimeProfile -Profile $privateDisabledProfile } `
        'private_mode=disabled不能借alpha4自动回程额外接收private call'

    $exactReturn = [pscustomobject][ordered]@{ source_id=[uint64]460997; local_destination_id=[uint64]4609999; slot=[uint64]2 }
    $privatePeerPolicy = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='selected_peers'; allow_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 })
        allow_private_peers=@($exactReturn); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
    }
    $noTransmitPeerProfile = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2TargetPrivate `
        -Devices $v2Devices -RxPolicy $privatePeerPolicy -TransmitEnabled $false
    Assert-Throws { Get-BridgeLegacyRuntimeProfile -Profile $noTransmitPeerProfile } `
        'alpha4停止TX时不会建立secondary return filter，因而不得声称selected peer已生效'

    $bothPrimaryRoutes = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='all_peers_to_local'; allow_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 })
        allow_private_peers=@(); local_private_routes=@([pscustomobject]@{ local_destination_id=[uint64]4609999; slot=[uint64]2 })
        blocked_groups=@(); blocked_source_ids=@()
    }
    $bothPrimaryProfile = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Target `
        -Devices $v2Devices -RxPolicy $bothPrimaryRoutes -TransmitEnabled $true
    Assert-Throws { Get-BridgeLegacyRuntimeProfile -Profile $bothPrimaryProfile } `
        'alpha4只有一个主接收过滤器，不能静默丢弃组呼或本机私呼主路由'

    $allPeersWithPreciseReturn = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='all_peers_to_local'; allow_groups=@()
        allow_private_peers=@($exactReturn); local_private_routes=@([pscustomobject]@{ local_destination_id=[uint64]4609999; slot=[uint64]1 })
        blocked_groups=@(); blocked_source_ids=@()
    }
    $allPeersWithPreciseReturnProfile = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2TargetPrivate `
        -Devices $v2Devices -RxPolicy $allPeersWithPreciseReturn -TransmitEnabled $true
    $allPeersWithPreciseReturnLegacy = Get-BridgeLegacyRuntimeProfile -Profile $allPeersWithPreciseReturnProfile
    Assert-True ($allPeersWithPreciseReturnLegacy.receive.call_kind -ceq 'private' -and
        $allPeersWithPreciseReturnLegacy.receive.slot -eq 1 -and
        $allPeersWithPreciseReturnLegacy.connection.destination_id -eq 460997) `
        'all_peers_to_local可与异时隙精确TX回程并存，迁移视图完整保留两者'

    $savedBytesBeforeFailure = [System.IO.File]::ReadAllBytes($profilePath)
    $blockedPath = Join-Path $configPath 'directory-target.json'
    [System.IO.Directory]::CreateDirectory($blockedPath) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $blockedPath 'sentinel.txt'), 'unchanged')
    Assert-Throws { Write-BridgeUserConnectionProfile -Path $blockedPath -Profile $legacyPrivate } '替换目标是目录时保存应失败'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $blockedPath 'sentinel.txt')) -ceq 'unchanged' -and
        @(Get-ChildItem -LiteralPath $configPath -Filter 'directory-target.json.tmp-*').Count -eq 0) '写入失败时原目标和临时文件保持安全'

    foreach ($invalidProfile in @(
        '{"schema_version":1,"connection":{},"devices":{},"receive":null}',
        '{"schema_version":1,"connection":{},"devices":{},"transmit_enabled":null}',
        '{"schema_version":1,"connection":{},"devices":{},"receive":{"destination_id":91,"slot":2}}',
        '{"schema_version":1,"connection":{},"devices":{},"transmit_enabled":"false"}'
    )) {
        [System.IO.File]::WriteAllText($profilePath, $invalidProfile, (New-Object System.Text.UTF8Encoding($false)))
        Assert-Throws { Read-BridgeUserConnectionProfile -Path $profilePath | Out-Null } `
            '存在的接收对象和发射许可必须完整且类型正确'
    }
    $invalidObject = [pscustomobject]@{ connection = $legacyConnection; devices = $profileDevices; receive = $null }
    Assert-Throws { Write-BridgeUserConnectionProfile -Path $profilePath -Profile $invalidObject } `
        '保存时拒绝显式 receive=null'
    $invalidObject = [pscustomobject]@{ connection = $legacyConnection; devices = $profileDevices; transmit_enabled = $null }
    Assert-Throws { Write-BridgeUserConnectionProfile -Path $profilePath -Profile $invalidObject } `
        '保存时拒绝显式 transmit_enabled=null'

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

    Write-Host '通过：schema 1 到 2 迁移、本机私呼路由、精确TX回程投影、备份写入、音量v1与密码路径检查。未启动核心或访问设备。'
} finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    Remove-Module -Name bridge-user-config -ErrorAction SilentlyContinue
}
