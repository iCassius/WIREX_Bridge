param(
    [string]$LauncherPath = (Join-Path $PSScriptRoot 'start-bm-radio-bridge.ps1')
)

$ErrorActionPreference = 'Stop'
$selectedFunctions = @(
    'ConvertTo-GainMilli',
    'Format-GainDecimal',
    'Read-AudioSettings',
    'Write-AudioSettings',
    'Get-AudioSettings',
    'Resolve-AudioSettingsPath',
    'Assert-JsonObjectKeysUnique',
    'Assert-ExactJsonObject',
    'ConvertTo-ProfileUnsigned',
    'Test-ValidMasterName',
    'ConvertTo-ValidatedConnectionProfile',
    'Read-ConnectionProfile',
    'Read-ConnectionPrompt',
    'Read-ManualConnectionProfile',
    'Write-ConnectionProfile',
    'Resolve-ConnectionProfilePath',
    'Read-ProfileForPreset',
    'Set-ResolvedProfileDevices',
    'Read-PortSelection',
    'Find-WaveEndpointById',
    'Get-CompatibleAutoAudioPair',
    'Get-ProfileConnectionArgs',
    'Resolve-LocalFile',
    'Resolve-PasswordFileForRun'
)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    [System.IO.Path]::GetFullPath($LauncherPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "启动器 PowerShell 语法错误：$messages"
}
$launcherText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($LauncherPath))
foreach ($requiredText in @('--radio-playback-gain', '--mic-transmit-gain',
        'Resolve-AudioSettingsPath -Path $AudioSettingsPath')) {
    if (-not $launcherText.Contains($requiredText)) { throw "启动器缺少音量配置接线：$requiredText" }
}
$profileLauncherPath = Join-Path (Split-Path -Parent $LauncherPath) 'start-profile.cmd'
if (Test-Path -LiteralPath $profileLauncherPath -PathType Leaf) {
    $profileLauncherText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($profileLauncherPath))
    if ($profileLauncherText -notmatch '-Preset manual\s+%\*' -or $profileLauncherText -notmatch 'exit /b %ERRORLEVEL%') {
        throw '手工 profile 启动器必须固定选择 manual、透传参数并保留退出码。'
    }
}
$ignorePath = Join-Path (Split-Path -Parent (Split-Path -Parent $LauncherPath)) '.gitignore'
if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
    $ignoreText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($ignorePath))
    if (-not $ignoreText.Contains('/tools/connection-profile.json')) { throw '便携连接配置文件必须由 Git 忽略。' }
}
$listenLauncherPath = Join-Path (Split-Path -Parent $LauncherPath) 'start-listen-91.cmd'
if (Test-Path -LiteralPath $listenLauncherPath -PathType Leaf) {
    $listenLauncherText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($listenLauncherPath))
    if ($listenLauncherText -notmatch '-Preset listen-91\s+%\*') { throw 'TG91 启动器没有透传增益命令行参数。' }
}
$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $selectedFunctions -ccontains $node.Name
}, $true))
if ($functionAsts.Count -ne $selectedFunctions.Count) { throw '没有找到全部音量设置函数。' }
foreach ($functionAst in $functionAsts) { Invoke-Expression $functionAst.Extent.Text }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "预期拒绝但操作成功：$Message" }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-audio-settings-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$script:packageRoot = $temporaryRoot
$settingsPath = Join-Path $temporaryRoot 'audio-settings.json'
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    Assert-True ((Resolve-AudioSettingsPath -Path '') -ceq $settingsPath) '没有覆盖路径时继续使用便携目录音量文件'
    $sharedDirectory = Join-Path $temporaryRoot 'shared-config'
    New-Item -ItemType Directory -Path $sharedDirectory | Out-Null
    $sharedSettingsPath = Join-Path $sharedDirectory 'audio-settings.json'
    Assert-True ((Resolve-AudioSettingsPath -Path $sharedSettingsPath) -ceq $sharedSettingsPath) '显式音量路径应支持本机跨版本目录'
    Assert-Throws { Resolve-AudioSettingsPath -Path (Join-Path $temporaryRoot 'missing\audio-settings.json') | Out-Null } `
        '音量配置父目录缺失时应在枚举设备前拒绝'
    $defaults = Get-AudioSettings -Path $settingsPath
    Assert-True ($defaults.RadioPlaybackGainMilli -eq 1000) '缺少配置时回放默认值应为 1x'
    Assert-True ($defaults.MicTransmitGainMilli -eq 16000) '缺少配置时发送默认值应为 16x'
    Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) '缺少配置时应保存默认文件'
    Assert-True (@(Get-ChildItem -LiteralPath $temporaryRoot | Where-Object { $_.Name -match '\.(tmp|bak)-' }).Count -eq 0) '首次保存后不应残留临时文件'

    $playbackOverride = Get-AudioSettings -Path $settingsPath `
        -RadioPlaybackGainWasBound $true -RadioPlaybackGainValue '0.75'
    Assert-True ($playbackOverride.RadioPlaybackGainMilli -eq 750) '播放增益覆盖应精确换算到千分位'
    Assert-True ($playbackOverride.MicTransmitGainMilli -eq 16000) '单项覆盖应保留另一项设置'

    $bothOverrides = Get-AudioSettings -Path $settingsPath `
        -RadioPlaybackGainWasBound $true -RadioPlaybackGainValue '1.25' `
        -MicTransmitGainWasBound $true -MicTransmitGainValue '12.125'
    Assert-True ($bothOverrides.RadioPlaybackGainMilli -eq 1250) '播放参数应支持 1.25x'
    Assert-True ($bothOverrides.MicTransmitGainMilli -eq 12125) '发送参数应支持三位小数'
    $reloaded = Get-AudioSettings -Path $settingsPath
    Assert-True ($reloaded.RadioPlaybackGainMilli -eq 1250 -and $reloaded.MicTransmitGainMilli -eq 12125) '保存值应在下次启动恢复'

    [System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    Write-AudioSettings -Path $settingsPath -RadioPlaybackGainMilli 1250 -MicTransmitGainMilli 12125
    $serialized = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
    Assert-True ($serialized.Contains('"radio_playback_gain": 1.25')) 'JSON 小数点应固定使用 invariant 格式'
    Assert-True (-not $serialized.Contains('1,25')) 'JSON 不应因系统区域设置写出逗号小数'
    $cultureReload = Get-AudioSettings -Path $settingsPath
    Assert-True ($cultureReload.RadioPlaybackGainMilli -eq 1250 -and $cultureReload.MicTransmitGainMilli -eq 12125) '区域设置变化不应影响读取'
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture

    foreach ($invalid in @('0.249', '16.001', '1.0000', '1,5', '1e0', '-1', '.5', '1.')) {
        Assert-Throws { ConvertTo-GainMilli -Text $invalid -Label 'test' | Out-Null } "增益 $invalid"
    }

    $invalidDocuments = @(
        '{"schema_version":1,"radio_playback_gain":1,"mic_transmit_gain":16,"new_field":2}',
        '{"schema_version":2,"radio_playback_gain":1,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1,"radio_playback_gain":2,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1e0,"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":"1","mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":{"radio_playback_gain":1},"mic_transmit_gain":16}',
        '{"schema_version":1,"radio_playback_gain":1}',
        '{broken json'
    )
    foreach ($invalidDocument in $invalidDocuments) {
        [System.IO.File]::WriteAllText($settingsPath, $invalidDocument, (New-Object System.Text.UTF8Encoding($false)))
        Assert-Throws { Get-AudioSettings -Path $settingsPath -RadioPlaybackGainWasBound $true `
            -RadioPlaybackGainValue '2' | Out-Null } '无效配置必须拒绝且不能被覆盖'
        Assert-True ([System.IO.File]::ReadAllText($settingsPath) -ceq $invalidDocument) '拒绝配置时应保留原文件内容'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $temporaryRoot | Where-Object { $_.Name -match '\.(tmp|bak)-' }).Count -eq 0) '拒绝配置后不应残留临时文件'

    $connectionProfilePath = Join-Path $temporaryRoot 'connection-profile.json'
    Assert-True ([System.IO.Path]::IsPathRooted((Resolve-ConnectionProfilePath -Path $connectionProfilePath))) `
        '连接配置路径应解析为绝对路径'
    Assert-Throws { Resolve-ConnectionProfilePath -Path (Join-Path $temporaryRoot 'missing\connection-profile.json') | Out-Null } `
        '连接配置目录缺失时应立即拒绝'
    Assert-True ((Resolve-PasswordFileForRun -SelectedPreset 'manual' -DefaultPath (Join-Path $temporaryRoot 'missing-password.txt')) -ceq '') `
        'manual 默认密码文件不存在时保留隐藏输入路径'
    Assert-Throws { Resolve-PasswordFileForRun -SelectedPreset 'manual' -ExplicitPath (Join-Path $temporaryRoot 'missing-password.txt') `
        -WasExplicit -DefaultPath (Join-Path $temporaryRoot 'missing-password.txt') | Out-Null } `
        '显式指定的密码文件缺失时应立即拒绝'
    Assert-Throws { Resolve-PasswordFileForRun -SelectedPreset 'parrot-cn' `
        -DefaultPath (Join-Path $temporaryRoot 'missing-password.txt') | Out-Null } '固定 preset 的默认密码文件缺失时应拒绝'
    $credentialPathFixture = Join-Path $temporaryRoot 'credential-path-fixture.txt'
    [System.IO.File]::WriteAllText($credentialPathFixture, 'local-test-fixture', (New-Object System.Text.UTF8Encoding($false)))
    Assert-True ([System.IO.Path]::IsPathRooted((Resolve-PasswordFileForRun -SelectedPreset 'manual' `
        -DefaultPath $credentialPathFixture))) 'manual 默认密码文件存在时只解析独立文件路径'
    Assert-True ($null -eq (Read-ConnectionProfile -Path $connectionProfilePath)) '连接配置文件缺失时应触发首次配置流程'
    $firstRunValues = New-Object System.Collections.Queue
    foreach ($entry in @('BI7KGD', '461135501', '4611355', '43.129.83.124', '62031', '460997', '2', '1', 'private')) {
        $firstRunValues.Enqueue($entry)
    }
    $inputReader = { param($prompt) [string]$firstRunValues.Dequeue() }.GetNewClosure()
    $firstRunProfile = Read-ManualConnectionProfile -InputReader $inputReader
    Assert-True ($firstRunProfile.connection.gateway_id -eq 461135501 -and
        $firstRunProfile.connection.destination_id -eq 460997 -and $firstRunProfile.connection.call_kind -ceq 'private') `
        '首次输入应规范化并校验手工连接字段'
    Write-ConnectionProfile -Path $connectionProfilePath -Profile $firstRunProfile
    Assert-True ((Read-ConnectionProfile -Path $connectionProfilePath).connection.source_id -eq 4611355) `
        '首次手工输入保存后应可用于下次启动'
    $profileConnection = [pscustomobject][ordered]@{
        callsign = 'BI7KGD'
        gateway_id = [uint64]4294967295
        source_id = [uint64]16777215
        master = '43.129.83.124'
        master_port = [uint64]62031
        destination_id = [uint64]16777215
        slot = [uint64]2
        color_code = [uint64]15
        call_kind = 'group'
    }
    $profileDevices = [pscustomobject][ordered]@{
        serial_port = 'auto'
        wave_in_endpoint_id = 'auto'
        wave_out_endpoint_id = 'auto'
    }
    $profile = ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices
    Assert-True ($profile.connection.gateway_id -eq 4294967295) 'profile 应接受 Gateway ID 上界'
    Assert-True ($profile.connection.source_id -eq 16777215 -and $profile.connection.destination_id -eq 16777215) 'profile 应接受 Source/目标 ID 上界'
    foreach ($validMaster in @('43.129.83.124', 'localhost', 'radio-master.example.net', 'radio.example.net.')) {
        Assert-True (Test-ValidMasterName -HostName $validMaster) "主机名应接受：$validMaster"
    }
    foreach ($invalidMaster in @('999.1.2.3', '127.1', '127.1.', '2130706433', 'host;xyz', 'foo/bar', 'host:xyz', 'radio..example', '-radio.example', 'radio-.example')) {
        Assert-True (-not (Test-ValidMasterName -HostName $invalidMaster)) "主机名应拒绝：$invalidMaster"
    }
    Write-ConnectionProfile -Path $connectionProfilePath -Profile $profile
    $loadedProfile = Read-ConnectionProfile -Path $connectionProfilePath
    Assert-True ($loadedProfile.connection.call_kind -ceq 'group' -and $loadedProfile.devices.serial_port -ceq 'auto') 'profile 写入后应准确恢复呼叫类型和自动设备选择'
    Assert-True ($loadedProfile.receive.destination_id -eq $loadedProfile.connection.destination_id -and
        $loadedProfile.receive.call_kind -ceq 'group' -and $loadedProfile.receive.slot -eq 2) `
        '旧组呼 profile 缺少接收对象时仍按原发射目标接收'
    $listenProfile = ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices `
        -Receive ([pscustomobject]@{ destination_id = [uint64]91; slot = [uint64]2; call_kind = 'group' }) `
        -TransmitEnabled $false
    $listenArgs = @(Get-ProfileConnectionArgs -Profile $listenProfile)
    Assert-True (($listenArgs -join ' ') -match '--profile-receive-destination-id 91 --profile-receive-slot 2 --profile-receive-call-kind G') `
        '独立 TG91 接收目标必须写入 native 启动参数'
    Assert-True ($listenArgs -ccontains '--listen-only') '只收配置必须向 native 传递 listen-only'
    $legacyPrivateConnection = $profileConnection.PSObject.Copy()
    $legacyPrivateConnection.call_kind = 'private'
    $legacyPrivateConnection.destination_id = [uint64]460997
    $legacyPrivateConnection.source_id = [uint64]4611355
    $legacyPrivateProfile = ConvertTo-ValidatedConnectionProfile -Connection $legacyPrivateConnection -Devices $profileDevices
    Assert-True ($legacyPrivateProfile.receive.destination_id -eq 4611355 -and
        $legacyPrivateProfile.receive.call_kind -ceq 'private') '旧私呼 profile 的默认接收目标应为本机 Source ID'
    $legacyPrivateArgs = @(Get-ProfileConnectionArgs -Profile $legacyPrivateProfile)
    Assert-True (($legacyPrivateArgs -join ' ') -match '--profile-receive-destination-id 4611355 --profile-receive-slot 2 --profile-receive-call-kind P') `
        '本机私呼回声接收目标必须进入 native 启动参数'
    Assert-Throws {
        ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices `
            -Receive ([pscustomobject]@{ destination_id = [uint64]91; slot = [uint64]2 })
    } '接收目标的三个字段必须同时存在'
    Assert-Throws {
        ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices -TransmitEnabled 'false'
    } '发射许可只接受 JSON 布尔值'
    Assert-True (@(Get-ChildItem -LiteralPath $temporaryRoot | Where-Object { $_.Name -match '\.(tmp|bak)-' }).Count -eq 0) 'profile 原子保存后不应残留临时文件'

    $profileJson = [System.IO.File]::ReadAllText($connectionProfilePath, [System.Text.Encoding]::UTF8)
    $duplicateConnectionJson = [regex]::Replace($profileJson, '"callsign"\s*:\s*"BI7KGD"', '"callsign": "BI7KGD", "callsign": "BI7KGD"', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $duplicateConnectionJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } '连接对象内重复字段必须拒绝'
    $duplicateDeviceJson = [regex]::Replace($profileJson, '"serial_port"\s*:\s*"auto"', '"serial_port": "auto", "serial_port": "auto"', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $duplicateDeviceJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } '设备对象内重复字段必须拒绝'
    $credentialJson = [regex]::Replace($profileJson, '"devices"\s*:', '"password": "secret", "devices":', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $credentialJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } 'profile 不得包含凭据字段'
    $nonnumericJson = [regex]::Replace($profileJson, '"source_id"\s*:\s*16777215', '"source_id": "16777215"', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $nonnumericJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } 'profile ID 必须是 JSON 整数'
    $negativeJson = [regex]::Replace($profileJson, '"source_id"\s*:\s*16777215', '"source_id": -1', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $negativeJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } 'profile ID 不得为负数'
    $fractionJson = [regex]::Replace($profileJson, '"source_id"\s*:\s*16777215', '"source_id": 1.5', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $fractionJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } 'profile ID 不得为小数'
    $missingEndpointJson = [regex]::Replace($profileJson, '"wave_out_endpoint_id"\s*:\s*"auto"', '"wave_out_endpoint_id": ""', 1)
    [System.IO.File]::WriteAllText($connectionProfilePath, $missingEndpointJson, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws { Read-ConnectionProfile -Path $connectionProfilePath | Out-Null } '显式设备选择不得为空'

    $badProfilePath = Join-Path $temporaryRoot 'broken-profile.json'
    [System.IO.File]::WriteAllText($badProfilePath, '{broken json', (New-Object System.Text.UTF8Encoding($false)))
    Assert-True ($null -eq (Read-ProfileForPreset -SelectedPreset 'listen-91' -Path $badProfilePath)) 'listen-91 固定 preset 不得读取手工 profile'
    Assert-Throws { Read-ProfileForPreset -SelectedPreset 'manual' -Path $badProfilePath | Out-Null } 'manual preset 必须拒绝损坏 profile'

    $mockDevices = [pscustomobject]@{
        wave_inputs = @([pscustomobject]@{ id = 1; endpoint_id = 'input-endpoint'; pcm_48000_mono_s16_supported = $true })
        wave_outputs = @([pscustomobject]@{ id = 3; endpoint_id = 'output-endpoint'; pcm_48000_mono_s16_supported = $true })
    }
    Assert-True ((Find-WaveEndpointById -Devices $mockDevices -Direction input -EndpointId 'input-endpoint').id -eq 1) '显式 WaveIn endpoint 应映射到本次 WinMM ID'
    Assert-Throws { Find-WaveEndpointById -Devices $mockDevices -Direction output -EndpointId 'removed-endpoint' | Out-Null } 'profile 中显式 endpoint 缺失时必须停止'
    $mockPair = [pscustomobject]@{
        Input = [pscustomobject]@{ endpoint_id = 'input-A' }
        Output = [pscustomobject]@{ endpoint_id = 'output-A' }
    }
    Assert-True ($null -ne (Get-CompatibleAutoAudioPair -AudioPair $mockPair `
        -WaveInSelector 'input-A' -WaveOutSelector 'auto')) '固定 WaveIn 与自动 WaveOut 同属自动发现配对时可复用'
    Assert-True ($null -eq (Get-CompatibleAutoAudioPair -AudioPair $mockPair `
        -WaveInSelector 'input-B' -WaveOutSelector 'auto')) '固定 WaveIn 与发现配对不同时必须重新选择 WaveOut'
    Assert-True ($null -ne (Get-CompatibleAutoAudioPair -AudioPair $mockPair `
        -WaveInSelector 'auto' -WaveOutSelector 'output-A')) '固定 WaveOut 与自动 WaveIn 同属自动发现配对时可复用'
    Assert-True ($null -eq (Get-CompatibleAutoAudioPair -AudioPair $mockPair `
        -WaveInSelector 'auto' -WaveOutSelector 'output-B')) '固定 WaveOut 与发现配对不同时必须重新选择 WaveIn'

    $ordinaryPort = [pscustomobject]@{ PortName = 'COM9'; ProductId = '0000'; IsHri = $false }
    $firstHri = [pscustomobject]@{ PortName = 'COM5'; ProductId = '0030'; IsHri = $true }
    $secondHri = [pscustomobject]@{ PortName = 'COM8'; ProductId = '0031'; IsHri = $true }
    Assert-Throws { Read-PortSelection -Ports @('COM9') -HriDevices @($ordinaryPort) -RequireHri | Out-Null } `
        'profile 自动选择必须拒绝没有 HRI 的普通串口'
    Assert-True ((Read-PortSelection -Ports @('COM9', 'COM8') -HriDevices @($ordinaryPort, $secondHri) -RequireHri) -ceq 'COM8') `
        '唯一 HRI 应被自动选择，即使设备不是 COM5'
    Assert-Throws { Read-PortSelection -Ports @('COM9', 'COM5') -HriDevices @($ordinaryPort, $firstHri) `
        -Requested 'COM9' -RequireHri | Out-Null } 'profile 显式串口必须匹配 HRI 设备'
    $portChoices = New-Object System.Collections.Queue
    $portChoices.Enqueue('COM9')
    $portChoices.Enqueue('COM8')
    $choiceReader = { param($prompt) $portChoices.Dequeue() }.GetNewClosure()
    Assert-True ((Read-PortSelection -Ports @('COM9', 'COM5', 'COM8') -HriDevices @($ordinaryPort, $firstHri, $secondHri) `
        -RequireHri -ChoiceReader $choiceReader) -ceq 'COM8') '多个 HRI 时只能通过交互选取 HRI 串口'
    Assert-Throws { ConvertTo-ProfileUnsigned -Value '-1' -Label 'test' -Maximum 4294967295 -AllowText | Out-Null } '手工数字文本拒绝负数'
    Assert-Throws { ConvertTo-ProfileUnsigned -Value '1.5' -Label 'test' -Maximum 4294967295 -AllowText | Out-Null } '手工数字文本拒绝小数'
    Assert-Throws { ConvertTo-ProfileUnsigned -Value '4294967296' -Label 'test' -Maximum 4294967295 -AllowText | Out-Null } '手工数字文本拒绝上界溢出'

    $autoProfile = ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices
    $newProfile = ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices
    $changed = Set-ResolvedProfileDevices -Profile $newProfile -NewProfile `
        -SelectedPort 'COM8' -WaveInEndpointId 'new-in' -WaveOutEndpointId 'new-out' `
        -PortOverride -WaveInOverride -WaveOutOverride
    Assert-True ($changed -and $newProfile.devices.serial_port -ceq 'COM8' -and
        $newProfile.devices.wave_in_endpoint_id -ceq 'new-in' -and $newProfile.devices.wave_out_endpoint_id -ceq 'new-out') `
        '首次创建 profile 时应保存显式设备选择'
    $changed = Set-ResolvedProfileDevices -Profile $autoProfile -SelectedPort 'COM8' `
        -WaveInEndpointId 'input-selected' -WaveOutEndpointId 'output-selected' `
        -PortOverride -WaveInOverride -WaveOutOverride
    Assert-True (-not $changed -and $autoProfile.devices.serial_port -ceq 'auto' -and
        $autoProfile.devices.wave_in_endpoint_id -ceq 'auto' -and $autoProfile.devices.wave_out_endpoint_id -ceq 'auto') `
        '已有 auto profile 不得被本次显式设备覆盖改写'
    $explicitProfile = ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices `
        ([pscustomobject]@{ serial_port = 'COM5'; wave_in_endpoint_id = 'saved-in'; wave_out_endpoint_id = 'saved-out' })
    $changed = Set-ResolvedProfileDevices -Profile $explicitProfile -SelectedPort 'COM8' `
        -WaveInEndpointId 'temporary-in' -WaveOutEndpointId 'temporary-out' `
        -PortOverride -WaveInOverride -WaveOutOverride
    Assert-True (-not $changed -and $explicitProfile.devices.serial_port -ceq 'COM5' -and
        $explicitProfile.devices.wave_in_endpoint_id -ceq 'saved-in' -and $explicitProfile.devices.wave_out_endpoint_id -ceq 'saved-out') `
        '已有 explicit profile 不得被本次设备覆盖改写'
    $promptedProfile = ConvertTo-ValidatedConnectionProfile -Connection $profileConnection -Devices $profileDevices
    $changed = Set-ResolvedProfileDevices -Profile $promptedProfile -SelectedPort 'COM8' `
        -WaveInEndpointId 'stable-in' -WaveOutEndpointId 'stable-out' -SerialWasPrompted -WaveInWasPrompted -WaveOutWasPrompted
    Assert-True ($changed -and $promptedProfile.devices.serial_port -ceq 'COM8' -and
        $promptedProfile.devices.wave_in_endpoint_id -ceq 'stable-in' -and $promptedProfile.devices.wave_out_endpoint_id -ceq 'stable-out') `
        'auto selector 遇到手工选择后应记住明确设备'
    Write-Output '启动器 AST、音量设置和连接配置离线检查通过。'
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedRoot.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        } else {
            throw '拒绝清理超出系统临时目录的测试路径。'
        }
    }
}
