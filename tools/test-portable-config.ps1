#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0

function Assert-PortableConfig {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Utf8Bom {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-PortableConfig -Condition ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        -Message ("UTF-8 BOM missing from {0}" -f [System.IO.Path]::GetFileName($Path))
}

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui\windows\PortableConfig.psm1'
Assert-Utf8Bom -Path $PSCommandPath
Assert-Utf8Bom -Path $modulePath
Import-Module $modulePath -Force -ErrorAction Stop

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDirectory = Join-Path $tempRoot ('wirex-portable-config-' + [guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($tempDirectory)
$configPath = Join-Path $tempDirectory 'portable\config.json'
$portableDirectory = [System.IO.Path]::GetDirectoryName($configPath)
$legacyDirectory = Join-Path $tempDirectory 'legacy-user-config'
$null = [System.IO.Directory]::CreateDirectory($portableDirectory)
$null = [System.IO.Directory]::CreateDirectory($legacyDirectory)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$fakeToken = ('a' * 100) + '.' + ('b' * 100) + '.' + ('c' * 100)
$fakePassword = 'synthetic-password-only'

try {
    $defaults = Get-WirexPortableConfig -Path $configPath
    Assert-PortableConfig ($defaults.channels.Count -eq 1) 'a missing config should return one default channel'
    Assert-PortableConfig ($defaults.channels[0].id -eq 460997 -and $defaults.channels[0].kind -ceq 'private' -and $defaults.channels[0].slot -eq 2) 'the default channel should be private 460997 TS2'
    Assert-PortableConfig ($defaults.tx_channel_id -ceq 'private:460997:2') 'default TX should use the tuple key'
    Assert-PortableConfig ($defaults.connection.master -ceq '43.129.83.124' -and $defaults.ui.bm_server_selection_id -ceq 'bm-china-4602') 'the default Master and selector should match the current BM catalog'
    Assert-PortableConfig (-not [System.IO.File]::Exists($configPath)) 'reading defaults must not create config.json'

    $defaults.connection.PSObject.Properties['callsign'].Value = 'N0CALL'
    $defaults.connection.PSObject.Properties['password'].Value = $fakePassword
    $defaults.connection.PSObject.Properties['api_key'].Value = $fakeToken
    $defaults.devices.PSObject.Properties['hri_port'].Value = 'COM5'
    $defaults.audio.PSObject.Properties['radio_playback_gain'].Value = [decimal]1.25
    $defaults.channels = [object[]]@(
        [pscustomobject][ordered]@{ id=[uint64]12345; kind='group'; slot=1; name='工作组' },
        [pscustomobject][ordered]@{ id=[uint64]460997; kind='private'; slot=2; name='测试目标' }
    )
    Add-Member -InputObject $defaults.channels[1] -NotePropertyName future_channel_field -NotePropertyValue 'preserve-channel'
    $defaults.tx_channel_id = 'private:460997:2'
    $defaults.routing.PSObject.Properties['blocked_source_ids'].Value = [uint64[]]@(3456789,4567890)
    Add-Member -InputObject $defaults -NotePropertyName future_section -NotePropertyValue ([pscustomobject][ordered]@{ value='keep-me' })
    Add-Member -InputObject $defaults.connection -NotePropertyName future_identity_field -NotePropertyValue 'keep-too'
    $saved = Save-WirexPortableConfig -Path $configPath -Config $defaults
    Assert-PortableConfig ([System.IO.File]::Exists($configPath)) 'save should create config.json in the chosen portable directory'
    Assert-PortableConfig ($saved.devices.hri_port -ceq 'COM5' -and $saved.devices.serial_port -ceq 'COM5') 'HRI aliases should normalize to the same COM port'
    Assert-PortableConfig ($saved.channels[0].id -eq 12345 -and $saved.channels[1].id -eq 460997) 'channel ordering should be preserved'
    Assert-PortableConfig ($saved.routing.blocked_source_ids.Count -eq 2) 'blocked source IDs should be preserved'
    Assert-PortableConfig (@(Get-ChildItem -LiteralPath $portableDirectory -Filter 'config.json.backup-tmp-*').Count -eq 0) 'atomic save should leave no temporary file'
    Assert-PortableConfig (@(Get-ChildItem -LiteralPath $portableDirectory -Filter 'config.json.backup-*').Count -eq 0) 'atomic save should clean its transient backup'

    $freshDefaults = Get-WirexPortableConfig -Path $configPath
    $freshDefaults.connection.master = 'bm.example.test'
    $freshDefaults.channels = [object[]]@(
        [pscustomobject][ordered]@{ id=[uint64]12345; kind='group'; slot=1; name='工作组-更新' },
        [pscustomobject][ordered]@{ id=[uint64]460997; kind='private'; slot=2; name='测试目标-更新' }
    )
    $savedAgain = Save-WirexPortableConfig -Path $configPath -Config $freshDefaults
    Assert-PortableConfig ($savedAgain.future_section.value -ceq 'keep-me' -and $savedAgain.connection.future_identity_field -ceq 'keep-too') 'unknown root and nested fields should survive a later save'
    Assert-PortableConfig ($savedAgain.channels[1].future_channel_field -ceq 'preserve-channel') 'unknown fields on an edited channel should survive by tuple key'
    Assert-PortableConfig ($savedAgain.connection.password -ceq $fakePassword -and $savedAgain.connection.api_key -ceq $fakeToken) 'credential values should stay in the same config document'
    Assert-PortableConfig ($savedAgain.devices.serial_port -ceq 'COM5') 'saving through the HRI field should keep the native serial alias in sync'

    $pathFieldRejected = $false
    $freshDefaults['api_key_file_path'] = 'C:\private\key.txt'
    try { [void](Save-WirexPortableConfig -Path $configPath -Config $freshDefaults) }
    catch { $pathFieldRejected = -not $_.Exception.Message.Contains($fakeToken) }
    Assert-PortableConfig $pathFieldRejected 'config.json must reject API credential file paths without echoing secret values'
    $onDiskAfterRejectedSave = Get-WirexPortableConfig -Path $configPath
    Assert-PortableConfig ($onDiskAfterRejectedSave.connection.master -ceq 'bm.example.test') 'a rejected save must leave the current config intact'

    $beforeCaseVariantSave = [System.IO.File]::ReadAllBytes($configPath)
    $caseVariantConfig = Get-WirexPortableConfig -Path $configPath
    $caseVariantConfig['API_KEY_FILE_PATH'] = 'synthetic-only-key-path'
    $caseVariantSaveRejected = $false
    try { [void](Save-WirexPortableConfig -Path $configPath -Config $caseVariantConfig) }
    catch { $caseVariantSaveRejected = $true }
    Assert-PortableConfig $caseVariantSaveRejected 'credential file path keys must be rejected without regard to letter case during save'
    Assert-PortableConfig ([System.Linq.Enumerable]::SequenceEqual([byte[]]$beforeCaseVariantSave,[byte[]][System.IO.File]::ReadAllBytes($configPath))) `
        'case-variant credential path rejection must leave the existing config bytes unchanged'

    $caseVariantReadPath = Join-Path $portableDirectory 'case-variant-path.json'
    $caseVariantDocument = Get-WirexPortableConfig -Path $configPath
    $caseVariantDocument['API_KEY_FILE_PATH'] = 'synthetic-only-key-path'
    $caseVariantBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $caseVariantDocument -Depth 16))
    [System.IO.File]::WriteAllBytes($caseVariantReadPath, $caseVariantBytes)
    $caseVariantReadRejected = $false
    try { [void](Get-WirexPortableConfig -Path $caseVariantReadPath) } catch { $caseVariantReadRejected = $true }
    Assert-PortableConfig $caseVariantReadRejected 'reading a config with an uppercase credential path key must fail'
    Assert-PortableConfig ([System.Linq.Enumerable]::SequenceEqual([byte[]]$caseVariantBytes,[byte[]][System.IO.File]::ReadAllBytes($caseVariantReadPath))) `
        'reading a case-variant credential path must leave the original file bytes unchanged'

    $badTargetBytes = [System.Text.Encoding]::UTF8.GetBytes('{ broken-json')
    [System.IO.File]::WriteAllBytes($configPath, $badTargetBytes)
    $badReadRejected = $false
    try { [void](Get-WirexPortableConfig -Path $configPath) }
    catch { $badReadRejected = $true; Assert-PortableConfig (-not $_.Exception.Message.Contains($fakeToken)) 'bad config errors must not echo credentials' }
    Assert-PortableConfig $badReadRejected 'damaged config.json should be rejected'
    Assert-PortableConfig ([System.Linq.Enumerable]::SequenceEqual([byte[]]$badTargetBytes,[byte[]][System.IO.File]::ReadAllBytes($configPath))) 'reading damaged config must not change its bytes'
    $badSaveRejected = $false
    try { [void](Save-WirexPortableConfig -Path $configPath -Config $defaults) } catch { $badSaveRejected = $true }
    Assert-PortableConfig $badSaveRejected 'saving over damaged config.json should be rejected'
    Assert-PortableConfig ([System.Linq.Enumerable]::SequenceEqual([byte[]]$badTargetBytes,[byte[]][System.IO.File]::ReadAllBytes($configPath))) 'saving over damaged config must not change its bytes'

    $missingShape = Get-WirexPortableConfig -Path (Join-Path $portableDirectory 'missing-shape-source.json')
    $null = $missingShape.connection.PSObject.Properties.Remove('api_key')
    $missingShapeBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $missingShape -Depth 12))
    [System.IO.File]::WriteAllBytes($configPath, $missingShapeBytes)
    $missingShapeReadRejected = $false
    try { [void](Get-WirexPortableConfig -Path $configPath) } catch { $missingShapeReadRejected = $true }
    Assert-PortableConfig $missingShapeReadRejected 'a stored config missing a required nested field should be rejected'
    Assert-PortableConfig ([System.Linq.Enumerable]::SequenceEqual([byte[]]$missingShapeBytes,[byte[]][System.IO.File]::ReadAllBytes($configPath))) 'reading a config with a missing field must preserve its bytes'
    $missingShapeSaveRejected = $false
    try { [void](Save-WirexPortableConfig -Path $configPath -Config $defaults) } catch { $missingShapeSaveRejected = $true }
    Assert-PortableConfig $missingShapeSaveRejected 'saving must not fill missing source fields with defaults and overwrite the source'
    Assert-PortableConfig ([System.Linq.Enumerable]::SequenceEqual([byte[]]$missingShapeBytes,[byte[]][System.IO.File]::ReadAllBytes($configPath))) 'saving over an incomplete config must preserve its bytes'

    $emptyChannelsPath = Join-Path $portableDirectory 'empty-channels.json'
    $emptyChannels = Get-WirexPortableConfig -Path $emptyChannelsPath
    $emptyChannels.channels = [object[]]@()
    $emptyChannels.tx_channel_id = ''
    $emptySaved = Save-WirexPortableConfig -Path $emptyChannelsPath -Config $emptyChannels
    Assert-PortableConfig ($emptySaved.channels.Count -eq 0 -and $emptySaved.tx_channel_id -ceq '') 'an explicitly empty channel list should remain empty and have no TX target'

    $listenOnlyPath = Join-Path $portableDirectory 'listen-only-channels.json'
    $listenOnly = Get-WirexPortableConfig -Path $listenOnlyPath
    $listenOnly.channels = [object[]]@(
        [pscustomobject][ordered]@{ id=[uint64]460997; kind='private'; slot=2; name='460997' },
        [pscustomobject][ordered]@{ id=[uint64]91; kind='group'; slot=2; name='TG91' },
        [pscustomobject][ordered]@{ id=[uint64]46001; kind='group'; slot=1; name='TG46001' },
        [pscustomobject][ordered]@{ id=[uint64]4000; kind='group'; slot=2; name='TG4000' }
    )
    $listenOnly.tx_channel_id = 'group:46001:1'
    $listenSaved = Save-WirexPortableConfig -Path $listenOnlyPath -Config $listenOnly
    Assert-PortableConfig ($listenSaved.channels.Count -eq 4) 'TG91, TG46001, and TG4000 should remain configurable channel IDs'
    Assert-PortableConfig ($listenSaved.tx_channel_id -ceq 'group:46001:1') 'a listen group ID can be selected as a stored TX target'
    $listenSaved.tx_channel_id = 'group:4000:2'
    $controlTargetSaved = Save-WirexPortableConfig -Path $listenOnlyPath -Config $listenSaved
    Assert-PortableConfig ($controlTargetSaved.tx_channel_id -ceq 'group:4000:2') 'config storage should not impose a new TG4000 blacklist'
    Assert-PortableConfig ($null -eq $controlTargetSaved.PSObject.Properties['transmit_enabled']) 'storing a TX target must not create a transmit request or enabled state'

    $profile = [ordered]@{
        schema_version=2
        connection=[ordered]@{ callsign='N0CALL'; gateway_id=461135501; source_id=4611355; master='43.129.83.124'; master_port=62031; color_code=1 }
        tx_target=[ordered]@{ destination_id=460997; kind='private'; slot=2 }
        devices=[ordered]@{ serial_port='COM5'; wave_in_endpoint_id='auto'; wave_out_endpoint_id='auto' }
        rx_policy=[ordered]@{
            group_mode='selected'; private_mode='selected_peers'
            allow_groups=@([ordered]@{ destination_id=12345; slot=1 })
            allow_private_peers=@([ordered]@{ source_id=2345678; local_destination_id=4611355; slot=2 })
            local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@(3456789)
        }
        transmit_enabled=$true
    }
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'connection-profile.json'), (ConvertTo-Json -InputObject $profile -Depth 12), $utf8NoBom)
    $oldAudio = [ordered]@{ schema_version=1; radio_playback_gain=1.25; mic_transmit_gain=12 }
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'audio-settings.json'), (ConvertTo-Json -InputObject $oldAudio), $utf8NoBom)
    $oldRadio = [ordered]@{ schema_version=1; cat_port='COM7'; baud_rate=38400; stop_bits='One'; desired_power_watts=30 }
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'radio-control-preferences.json'), (ConvertTo-Json -InputObject $oldRadio), $utf8NoBom)
    $oldServer = [ordered]@{ schema_version=1; bm_server_selection_id='bm-4602' }
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'bm-server-preferences.json'), (ConvertTo-Json -InputObject $oldServer), $utf8NoBom)
    $oldApiPreference = [ordered]@{ schema_version=1; api_key_file_path=(Join-Path $tempDirectory 'synthetic-api-key.txt') }
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'bm-management-preferences.json'), (ConvertTo-Json -InputObject $oldApiPreference), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $tempDirectory 'synthetic-api-key.txt'), "[key]`napikey=$fakeToken`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $tempDirectory 'synthetic-password.txt'), "$fakePassword`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'password-file-path.txt'), (Join-Path $tempDirectory 'synthetic-password.txt'), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'channel-favorites.json'), '{"schema_version":1,"favorites":[]}', $utf8NoBom)

    $configPath = Join-Path $portableDirectory 'migrated-config.json'
    $migrated = Get-WirexPortableConfig -Path $configPath -LegacyDirectory $legacyDirectory
    Assert-PortableConfig ($migrated.connection.api_key -ceq $fakeToken -and $migrated.connection.password -ceq $fakePassword) 'migration should read only credentials named by explicit legacy pointers'
    Assert-PortableConfig ($migrated.audio.radio_playback_gain -eq [decimal]1.25 -and $migrated.audio.mic_transmit_gain -eq [decimal]12) 'legacy audio gains should be merged'
    Assert-PortableConfig ($migrated.devices.hri_port -ceq 'COM5' -and $migrated.devices.cat_port -ceq 'COM7' -and $migrated.devices.cat_baud_rate -eq 38400) 'legacy HRI and CAT preferences should be merged'
    Assert-PortableConfig ($migrated.devices.cat_stop_bits -ceq 'Two') 'legacy stop bits should use the current fixed Two setting'
    Assert-PortableConfig ($migrated.ui.bm_server_selection_id -ceq 'bm-4602') 'legacy BM server selection should migrate'
    Assert-PortableConfig ($migrated.routing.blocked_source_ids.Count -eq 1 -and $migrated.routing.blocked_source_ids[0] -eq 3456789) 'legacy blocked source IDs should become the routing field'
    Assert-PortableConfig ($migrated.ui.legacy_rx_policy.allow_groups.Count -eq 1) 'legacy route policy should be preserved for review, not applied as the channel list'
    Assert-PortableConfig ($migrated.channels.Count -eq 3 -and $migrated.channels[0].id -eq 460997 -and $migrated.channels[1].id -eq 12345 -and $migrated.channels[2].id -eq 2345678) 'the explicit TX target should be first, followed by group and private peer channels'
    Assert-PortableConfig ($migrated.tx_channel_id -ceq 'private:460997:2') 'legacy TX target should map to the tuple key'
    $emptyLegacyRoutes = [object[]]@()
    $localRouteProfile = [ordered]@{
        schema_version=2
        connection=$profile.connection
        tx_target=$profile.tx_target
        devices=$profile.devices
        rx_policy=[ordered]@{
            group_mode='selected'; private_mode='all_peers_to_local'
            allow_groups=@([ordered]@{ destination_id=12345; slot=1 })
            allow_private_peers=$emptyLegacyRoutes
            local_private_routes=@([ordered]@{ local_destination_id=4611355; slot=2 })
            blocked_groups=$emptyLegacyRoutes; blocked_source_ids=@(3456789)
        }
        transmit_enabled=$true
    }
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'connection-profile.json'), (ConvertTo-Json -InputObject $localRouteProfile -Depth 12), $utf8NoBom)
    $localRouteMigrated = Get-WirexPortableConfig -Path (Join-Path $portableDirectory 'local-route-config.json') -LegacyDirectory $legacyDirectory
    Assert-PortableConfig ($localRouteMigrated.channels.Count -eq 2 -and $localRouteMigrated.channels[0].id -eq 460997 -and $localRouteMigrated.channels[1].id -eq 12345) 'a migrated local private destination must not become a peer channel and TX must remain first'
    Assert-PortableConfig ($localRouteMigrated.ui.legacy_rx_policy.local_private_routes.Count -eq 1 -and $localRouteMigrated.ui.legacy_rx_policy.local_private_routes[0].local_destination_id -eq 4611355 -and $localRouteMigrated.ui.legacy_rx_policy.local_private_routes[0].slot -eq 2) 'legacy local private routes must remain unchanged in the archived RX policy'
    Assert-PortableConfig ($null -eq $migrated.PSObject.Properties['favorites']) 'legacy favorites should not be copied into new channels or preferences'
    Assert-PortableConfig (-not [System.IO.File]::Exists($configPath)) 'migration read should not write either old or new config files'
    Assert-PortableConfig ([System.IO.File]::Exists((Join-Path $legacyDirectory 'channel-favorites.json'))) 'migration should leave the old favorites file untouched'

    $implicit = Get-WirexPortableConfig -Path (Join-Path $portableDirectory 'implicit.json')
    Assert-PortableConfig ($implicit.connection.password -ceq '' -and $implicit.connection.api_key -ceq '') 'legacy values must not be read unless the caller supplies LegacyDirectory'

    $migrationFailurePath = Join-Path $portableDirectory 'bad-legacy-config.json'
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory 'connection-profile.json'), '{ bad-profile', $utf8NoBom)
    $legacyRejected = $false
    try { [void](Get-WirexPortableConfig -Path $migrationFailurePath -LegacyDirectory $legacyDirectory) }
    catch { $legacyRejected = $true; Assert-PortableConfig (-not $_.Exception.Message.Contains($fakeToken)) 'migration errors must not echo key material' }
    Assert-PortableConfig $legacyRejected 'damaged legacy profile should stop migration'
    Assert-PortableConfig (-not [System.IO.File]::Exists($migrationFailurePath)) 'failed migration should not create config.json'

    Write-Output ("PASS: test-portable-config.ps1 ({0} assertions; PowerShell {1})" -f $script:assertionCount, $PSVersionTable.PSVersion)
} finally {
    $fullTemp = [System.IO.Path]::GetFullPath($tempDirectory)
    if (-not $fullTemp.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Test temporary directory escaped the OS temporary directory.' }
    if ([System.IO.Directory]::Exists($fullTemp)) { Remove-Item -LiteralPath $fullTemp -Recurse -Force }
}
