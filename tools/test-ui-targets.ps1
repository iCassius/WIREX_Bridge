[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-UiTarget {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module -Name (Join-Path $PSScriptRoot 'bridge-user-config.psm1') -Force
$uiScript = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiScript, [ref]$tokens, [ref]$parseErrors)
Assert-UiTarget ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$functionNames = @('Format-ProfileTarget', 'Format-ProfileReceiveTarget', 'Format-ProfileTransmitPermission',
    'New-EffectiveTargetProfile', 'Get-UiReceiveEditorState', 'New-UiSimpleReceivePolicy', 'Copy-UiRxPolicy',
    'New-UiCallTargetProfile', 'New-UiCallTargetFromPreset', 'Get-UiCallTargetSummaryProfile',
    'New-UiCallTargetFromHistoryEntry', 'Get-UiCallHistoryKey', 'Format-UiTxTarget',
    'Test-UiChannelFavorite', 'Get-UiChannelFavoriteKey', 'New-UiChannelFavoriteCandidate', 'Remove-UiChannelFavoriteCandidate',
    'Read-UiChannelFavorites', 'Write-UiChannelFavorites', 'Test-UiIdentityResultMatchesCurrent',
    'Stop-UiIdentityQuery', 'Complete-UiIdentityQueryResources', 'Format-UiRadioIdentityDetails', 'Invoke-UiSetCallTarget')
foreach ($functionName in $functionNames) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
    Assert-UiTarget ($null -ne $functionAst) "缺少 UI 配置处理函数：$functionName"
    Invoke-Expression $functionAst.Extent.Text
}

$legacyConnection = [pscustomobject][ordered]@{
    callsign='BI7KGD'; gateway_id=[uint64]461135501; source_id=[uint64]4611355
    master='43.129.83.124'; master_port=[uint64]62031; destination_id=[uint64]460997
    slot=[uint64]2; color_code=[uint64]0; call_kind='private'
}
$devices = [pscustomobject][ordered]@{ serial_port='COM5'; wave_in_endpoint_id='usb-in'; wave_out_endpoint_id='usb-out' }
$baseProfile = ConvertTo-BridgeUserConnectionProfile -Connection $legacyConnection -Devices $devices
$parrot = New-EffectiveTargetProfile -Profile $baseProfile -Target 'parrot-cn'
Assert-UiTarget ($parrot.tx_target.destination_id -eq 460997 -and $parrot.tx_target.kind -ceq 'private' -and
    $parrot.tx_target.slot -eq 2 -and $parrot.rx_policy.private_mode -ceq 'all_peers_to_local' -and
    $parrot.rx_policy.local_private_routes.Count -eq 1 -and
    $parrot.rx_policy.local_private_routes[0].local_destination_id -eq 4611355 -and
    $parrot.rx_policy.local_private_routes[0].slot -eq 2 -and $parrot.transmit_enabled) `
    '鹦鹉预设应保存本机私呼主路由与私呼目标，不再用旧 connection 目标字段'

$listen91 = New-EffectiveTargetProfile -Profile $parrot -Target 'listen-91'
Assert-UiTarget ($listen91.tx_target.destination_id -eq 460997 -and $listen91.tx_target.kind -ceq 'private' -and
    $listen91.rx_policy.allow_groups.Count -eq 1 -and $listen91.rx_policy.allow_groups[0].destination_id -eq 91 -and
    $listen91.rx_policy.private_mode -ceq 'disabled' -and -not $listen91.transmit_enabled) `
    'TG91 预设应选一个组呼路由并关闭私呼与发射许可'
$receiveSummary = Format-ProfileReceiveTarget -Profile $listen91
Assert-UiTarget ($receiveSummary.Contains('TG 91') -and $receiveSummary.Contains('私呼关闭')) `
    'TG91 预设的显示应与完整 schema 2 策略一致'
Assert-UiTarget ((Format-ProfileTransmitPermission -Profile $listen91) -ceq '发射许可：关闭') `
    '收听预设的界面必须显示发射许可已关闭'

$listen46001 = New-EffectiveTargetProfile -Profile $parrot -Target 'listen-46001'
Assert-UiTarget ($listen46001.rx_policy.allow_groups.Count -eq 1 -and
    $listen46001.rx_policy.allow_groups[0].destination_id -eq 46001 -and
    $listen46001.tx_target.destination_id -eq 460997 -and -not $listen46001.transmit_enabled) `
    'TG46001 预设应保留 TX 目标并设置一个 Selected RX 路由'
$custom = New-EffectiveTargetProfile -Profile $listen91 -Target 'custom'
Assert-UiTarget ($custom.tx_target.destination_id -eq 460997 -and $custom.rx_policy.allow_groups[0].destination_id -eq 91 -and
    -not $custom.transmit_enabled) '使用已保存目标应保留独立保存的 TX、RX 与发射许可'

$v2Connection = [pscustomobject][ordered]@{
    callsign='BI7KGD'; gateway_id=[uint64]461135501; source_id=[uint64]4611355
    master='43.129.83.124'; master_port=[uint64]62031; color_code=[uint64]0
}
$v2Tx = [pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
$v2Policy = [pscustomobject][ordered]@{
    group_mode='selected'; private_mode='disabled'
    allow_groups=@([pscustomobject]@{destination_id=[uint64]91;slot=[uint64]2}, [pscustomobject]@{destination_id=[uint64]46001;slot=[uint64]1})
    allow_private_peers=@(); local_private_routes=@(); blocked_groups=@([pscustomobject]@{destination_id=[uint64]12345;slot=[uint64]1}); blocked_source_ids=@([uint64]71001,[uint64]72001)
}
$multi = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Tx -Devices $devices `
    -RxPolicy $v2Policy -TransmitEnabled $false
$multiView = New-EffectiveTargetProfile -Profile $multi -Target 'custom'
Assert-UiTarget ($multiView.rx_policy.allow_groups.Count -eq 2 -and $multiView.rx_policy.allow_groups[1].destination_id -eq 46001) `
    '自定义目标的 UI 视图必须完整保留多组 schema 2 配置'
$multiEditor = Get-UiReceiveEditorState -Profile $multiView
Assert-UiTarget ($multiEditor.CanEdit -and $multiEditor.Reason -match '完整 schema 2') '完整多组策略必须可以使用独立路由编辑器修改'
Assert-UiTarget ((Format-ProfileReceiveTarget -Profile $multiView).Contains('TG 91') -and
    (Format-ProfileReceiveTarget -Profile $multiView).Contains('TG 46001')) 'UI 预览应显示所有保留的 Selected 组呼'

$settingsXaml = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'), [System.Text.Encoding]::UTF8)
$mainXaml = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ui\windows\MainWindow.xaml'), [System.Text.Encoding]::UTF8)
Assert-UiTarget ($settingsXaml.Contains('x:Name="ProfileMigrationText"') -and
    $settingsXaml.Contains('x:Name="ReceivePolicyPreviewText"')) '设置窗口应显示 schema 来源和接收策略预览'
Assert-UiTarget ($mainXaml.Contains('x:Name="ControlProtocolValue"') -and
    $mainXaml.Contains('x:Name="ControlStatusButton"')) '主面板应显示 v2 控制状态并提供只读 status 查询'
Assert-UiTarget ($settingsXaml.Contains('Tag="bm-china-4602"') -and $settingsXaml.Contains('43.129.83.124:62031')) `
    '设置窗口应列出 BM China 4602 地址和 UDP 端口'

$multiListen91 = New-EffectiveTargetProfile -Profile $multiView -Target 'listen-91'
Assert-UiTarget ($multiListen91.rx_policy.blocked_source_ids.Count -eq 2 -and
    $multiListen91.rx_policy.blocked_source_ids[0] -eq 71001 -and
    $multiListen91.rx_policy.blocked_groups.Count -eq 1 -and $multiListen91.rx_policy.blocked_groups[0].destination_id -eq 12345) `
    '切换收听TG91必须保留无关跨组来源和TG屏蔽。'
$multiListen46001 = New-EffectiveTargetProfile -Profile $multiView -Target 'listen-46001'
Assert-UiTarget ($multiListen46001.rx_policy.blocked_source_ids.Count -eq 2 -and
    $multiListen46001.rx_policy.blocked_groups.Count -eq 1 -and $multiListen46001.rx_policy.blocked_groups[0].destination_id -eq 12345) `
    '切换收听TG46001必须保留无关跨组来源和频道屏蔽。'
$multiParrot = New-EffectiveTargetProfile -Profile $multiView -Target 'parrot-cn'
Assert-UiTarget ($multiParrot.rx_policy.blocked_source_ids.Count -eq 2 -and
    $multiParrot.rx_policy.blocked_groups.Count -eq 1 -and $multiParrot.tx_target.kind -ceq 'private') `
    '切换鹦鹉预设必须保留无关跨组来源和频道屏蔽。'

$txOnlyTarget = [pscustomobject][ordered]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]1 }
$txOnlyProfile = New-UiCallTargetProfile -Profile $multiView -Target $txOnlyTarget
Assert-UiTarget ($txOnlyProfile.tx_target.destination_id -eq 53000 -and $txOnlyProfile.tx_target.kind -ceq 'group' -and
    $txOnlyProfile.tx_target.slot -eq 1 -and -not $txOnlyProfile.transmit_enabled -and
    $txOnlyProfile.connection.color_code -eq $multiView.connection.color_code -and
    (ConvertTo-Json -InputObject $txOnlyProfile.rx_policy -Compress -Depth 8) -ceq (ConvertTo-Json -InputObject $multiView.rx_policy -Compress -Depth 8)) `
    '主面板只修改TX目标时必须完整保留RX策略、发射许可和全局Color Code。'
$stoppedParrotSummary = Get-UiCallTargetSummaryProfile -Profile $multiView -Preset 'parrot-cn'
Assert-UiTarget ($stoppedParrotSummary.tx_target.destination_id -eq 460997 -and
    $stoppedParrotSummary.tx_target.kind -ceq 'private' -and $stoppedParrotSummary.tx_target.slot -eq 2 -and
    -not $stoppedParrotSummary.transmit_enabled -and
    (ConvertTo-Json -InputObject $stoppedParrotSummary.rx_policy -Compress -Depth 8) -ceq
        (ConvertTo-Json -InputObject $multiView.rx_policy -Compress -Depth 8)) `
    '核心退出后选择鹦鹉起呼目标的摘要仍须保留原接收规则和发射许可。'

$script:capturedTargetMutations = @()
function Invoke-UiRoutingMutation {
    param([string]$Command,[object]$PolicyOrTarget,[bool]$TransmitEnabled)
    $script:capturedTargetMutations += [pscustomobject]@{
        command=$Command; target=$PolicyOrTarget; transmit_enabled=$TransmitEnabled
    }
}
function Set-MainText { param([string]$Name,[string]$Text,[switch]$Confirmed) }
function Add-UiEvent { param([string]$Message) }
function Update-CallTargetChoices { }
$script:supervisor = [pscustomobject]@{ HasExited=$false }
$script:activeRouting = [pscustomobject]@{
    transmit_enabled=$false
    tx_target=[pscustomobject]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
    active_tx_lease=[pscustomobject]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]1 }
}
$leaseBeforeTargetMutation = ConvertTo-Json -InputObject $script:activeRouting -Compress -Depth 8
Invoke-UiSetCallTarget -Target ([pscustomobject]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]2 }) -Description '测试目标'
$leaseAfterTargetMutation = ConvertTo-Json -InputObject $script:activeRouting -Compress -Depth 8
Assert-UiTarget ($script:capturedTargetMutations.Count -eq 1 -and
    $script:capturedTargetMutations[0].command -ceq 'tx_policy.replace' -and
    $script:capturedTargetMutations[0].target.destination_id -eq 53000 -and
    $script:capturedTargetMutations[0].target.slot -eq 2 -and
    -not $script:capturedTargetMutations[0].transmit_enabled -and
    $leaseBeforeTargetMutation -ceq $leaseAfterTargetMutation) `
    '在线快速目标仅提交一次TX策略、沿用原发射许可并保留活动通话锁定目标。'

$privateHistoryTarget = New-UiCallTargetFromHistoryEntry -Entry ([pscustomobject]@{
    kind='private'; source_id=[uint64]3149877; destination_id=[uint64]3149876; slot=[uint64]1
})
$groupHistoryTarget = New-UiCallTargetFromHistoryEntry -Entry ([pscustomobject]@{
    kind='group'; source_id=[uint64]3149877; destination_id=[uint64]53000; slot=[uint64]2
})
Assert-UiTarget ($privateHistoryTarget.destination_id -eq 3149877 -and $privateHistoryTarget.kind -ceq 'private' -and
    $privateHistoryTarget.slot -eq 1 -and $groupHistoryTarget.destination_id -eq 53000 -and
    $groupHistoryTarget.kind -ceq 'group' -and $groupHistoryTarget.slot -eq 2) `
    '歷史私呼必須以來源ID作回呼目標，組呼必須用目的組號，兩者都保留原TS。'
Assert-UiTarget ((Get-UiCallHistoryKey -RunId 'run-a' -Generation 3) -ceq (Get-UiCallHistoryKey -RunId 'run-a' -Generation 3) -and
    (Get-UiCallHistoryKey -RunId 'run-a' -Generation 3) -cne (Get-UiCallHistoryKey -RunId 'run-a' -Generation 4) -and
    (Get-UiCallHistoryKey -RunId 'run-a' -Generation 3) -cne (Get-UiCallHistoryKey -RunId 'run-b' -Generation 3)) `
    '来话历史键必须按run_id与current_call_generation去重。'

$identityQueryFixture = [pscustomobject]@{ context_kind='current'; run_id='run-a'; radio_id=[uint64]3149876; generation=[uint64]7 }
$identityStatusFixture = [pscustomobject]@{
    run_id='run-a'; current_call_valid=$true; current_call_source_id=[uint64]3149876; current_call_generation=[uint64]7
}
$identityNow = [DateTime]::UtcNow
Assert-UiTarget (Test-UiIdentityResultMatchesCurrent -Query $identityQueryFixture -LatestStatus $identityStatusFixture `
    -SupervisorAlive $true -LastStatusUtc $identityNow.AddSeconds(-1) -NowUtc $identityNow) `
    '当前来话查询的run/source/generation与新鲜运行状态一致时可更新当前话者。'
Assert-UiTarget (-not (Test-UiIdentityResultMatchesCurrent -Query $identityQueryFixture -LatestStatus $identityStatusFixture `
    -SupervisorAlive $true -LastStatusUtc $identityNow.AddSeconds(-4) -NowUtc $identityNow) -and
    -not (Test-UiIdentityResultMatchesCurrent -Query $identityQueryFixture -LatestStatus $identityStatusFixture `
    -SupervisorAlive $false -LastStatusUtc $identityNow.AddSeconds(-1) -NowUtc $identityNow)) `
    '相同ID和代次的迟到查询在状态过期或核心已退出时不能覆盖当前话者正文。'
$identityDetailsFixture = [pscustomobject]@{
    status='found'; callsign='N0TEST'; name='Example Operator'; country='United States'; state='CA'; city='San Diego'
    source='radioid-api'; fetched_at_utc='2026-10-29T04:05:06Z'
}
$identityDetailsText = Format-UiRadioIdentityDetails -RadioId 3149876 -Identity $identityDetailsFixture
$staleIdentityDetails = Format-UiRadioIdentityDetails -RadioId 3149876 -Identity ([pscustomobject]@{
    status='stale'; callsign='N0TEST'; name='Example Operator'; country='United States'; city='San Diego'
    source='local-cache'; fetched_at_utc='2026-10-28T04:05:06Z'
})
Assert-UiTarget ($identityDetailsText.Contains('姓名：Example Operator') -and $identityDetailsText.Contains('国家 United States') -and
    $identityDetailsText.Contains('州/省 CA') -and $identityDetailsText.Contains('城市 San Diego') -and
    $identityDetailsText.Contains('资料来源：Radio ID 单条查询') -and $identityDetailsText.Contains('更新时间：') -and
    -not $staleIdentityDetails.Contains('州/省') -and $staleIdentityDetails.Contains('旧资料（缓存）')) `
    '身份详情按实际可用字段显示姓名、国家/州省/城市、来源和更新时间，并明确标记旧缓存。'

$favoriteTarget = [pscustomobject][ordered]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]1 }
$favoriteFirst = New-UiChannelFavoriteCandidate -Favorites @() -Target $favoriteTarget -Label '楼顶' -Category static
$favoriteUpdate = New-UiChannelFavoriteCandidate -Favorites @($favoriteFirst.favorites) -Target $favoriteTarget -Label '常用一' -Category dynamic
$favoriteOtherSlot = New-UiChannelFavoriteCandidate -Favorites @($favoriteUpdate.favorites) `
    -Target ([pscustomobject][ordered]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]2 }) -Label '另一个时隙' -Category normal
Assert-UiTarget ($favoriteFirst.favorites.Count -eq 1 -and $favoriteUpdate.was_update -and $favoriteUpdate.favorites.Count -eq 1 -and
    $favoriteUpdate.favorites[0].label -ceq '常用一' -and $favoriteUpdate.favorites[0].category -ceq 'dynamic' -and
    $favoriteOtherSlot.favorites.Count -eq 2) `
    '收藏按destination_id、kind、slot作键；更新label/category不重复，TS不同保留独立收藏。'
$removedFavorites = Remove-UiChannelFavoriteCandidate -Favorites @($favoriteOtherSlot.favorites) -Favorite $favoriteUpdate.favorite
Assert-UiTarget ($removedFavorites.Count -eq 1 -and $removedFavorites[0].slot -eq 2) `
    '删除收藏候选应只移除匹配的ID、呼叫类型和TS。'
$removedLastCandidate = Remove-UiChannelFavoriteCandidate -Favorites @($favoriteFirst.favorites) -Favorite $favoriteFirst.favorite
Assert-UiTarget ($removedLastCandidate.Count -eq 0) `
    '删除最后一条收藏后候选列表应为空，调用方可先写入磁盘再更新界面。'
$sixtyFourFavorites = @()
for ($index=0; $index -lt 64; $index++) {
    $target = [pscustomobject][ordered]@{ destination_id=[uint64](100000+$index); kind='group'; slot=[uint64]1 }
    $sixtyFourFavorites = (New-UiChannelFavoriteCandidate -Favorites $sixtyFourFavorites -Target $target `
        -Label ('频道 ' + $index) -Category normal).favorites
}
$favoriteCapRejected = $false
try {
    $target = [pscustomobject][ordered]@{ destination_id=[uint64]200000; kind='group'; slot=[uint64]1 }
    [void](New-UiChannelFavoriteCandidate -Favorites $sixtyFourFavorites -Target $target -Label '超限' -Category normal)
} catch { $favoriteCapRejected = $_.Exception.Message -match '64' }
Assert-UiTarget ($sixtyFourFavorites.Count -eq 64 -and $favoriteCapRejected) '收藏达到64项后应明确拒绝第65项，不静默丢弃记录。'

$favoriteTestDirectory = Join-Path $env:TEMP ('wirex-channel-favorites-test-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($favoriteTestDirectory) | Out-Null
try {
    $script:channelFavoritesPath = Join-Path $favoriteTestDirectory 'channel-favorites.json'
    $missingFavorites = @(Read-UiChannelFavorites)
    Assert-UiTarget ($missingFavorites.Count -eq 0 -and -not [System.IO.File]::Exists($script:channelFavoritesPath)) `
        '初次读取收藏不得创建channel-favorites.json。'
    Write-UiChannelFavorites -Favorites @($favoriteFirst.favorites)
    $favoriteDocument = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:channelFavoritesPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $favoriteRoundTrip = @(Read-UiChannelFavorites)
    Assert-UiTarget ($favoriteDocument.schema_version -eq 1 -and $favoriteDocument.favorites.Count -eq 1 -and
        $favoriteRoundTrip.Count -eq 1 -and $favoriteRoundTrip[0].destination_id -eq 53000 -and
        $favoriteRoundTrip[0].category -ceq 'static') '收藏JSON schema 1应保留ID、呼叫类型、TS、名称和本机分类。'
    $savedBeforeLastDelete = @(Read-UiChannelFavorites)
    $deleteLastCandidate = Remove-UiChannelFavoriteCandidate -Favorites $savedBeforeLastDelete -Favorite $savedBeforeLastDelete[0]
    Write-UiChannelFavorites -Favorites $deleteLastCandidate
    $emptyDocument = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:channelFavoritesPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $emptyRoundTrip = @(Read-UiChannelFavorites)
    Assert-UiTarget ($emptyDocument.favorites -is [array] -and $emptyDocument.favorites.Count -eq 0 -and $emptyRoundTrip.Count -eq 0) `
        '删除最后一项后应持久化可读的空数组。'
} finally {
    if ([System.IO.Directory]::Exists($favoriteTestDirectory)) { [System.IO.Directory]::Delete($favoriteTestDirectory,$true) }
}

$cancelPowerShell = [System.Management.Automation.PowerShell]::Create()
[void]$cancelPowerShell.AddScript('Start-Sleep -Seconds 30; "late"')
$cancelHandle = $cancelPowerShell.BeginInvoke()
$cancelQuery = [pscustomobject]@{
    power_shell=$cancelPowerShell; async_handle=$cancelHandle; stop_async=$null; stop_reason='';
    stop_started_utc=[DateTime]::MinValue; stop_error=''; stop_attempts=0; stop_complete=$false;
    disposed=$false; terminal_state=''
}
Stop-UiIdentityQuery -Query $cancelQuery -Reason 'test_cancel'
$firstStopTime = $cancelQuery.stop_started_utc
Stop-UiIdentityQuery -Query $cancelQuery -Reason 'test_cancel_again'
Assert-UiTarget ($cancelQuery.stop_async -and $cancelQuery.stop_started_utc -eq $firstStopTime) `
    '异步查询取消必须调用BeginStop，并且重复请求不能重置首次停止时间。'
for ($wait=0; $wait -lt 120 -and -not $cancelQuery.stop_async.IsCompleted; $wait++) { Start-Sleep -Milliseconds 25 }
Assert-UiTarget ($cancelQuery.stop_async.IsCompleted -and $cancelQuery.async_handle.IsCompleted) 'BeginStop应在有限时间内结束测试runspace管线。'
try { $cancelPowerShell.EndStop($cancelQuery.stop_async) } catch { }
Assert-UiTarget ((Complete-UiIdentityQueryResources -Query $cancelQuery) -and $cancelQuery.disposed -and
    [string]$cancelPowerShell.Runspace.RunspaceStateInfo.State -ceq 'Closed') `
    '取消收尾必须等管线终止并Dispose到runspace Closed状态。'

$throwingPipeline = New-Object PSObject
$throwingPipeline | Add-Member -MemberType ScriptMethod -Name BeginStop -Value { param($callback,$state) throw 'stop failure fixture' }
$throwingQuery = [pscustomobject]@{
    power_shell=$throwingPipeline; async_handle=[pscustomobject]@{IsCompleted=$false}; stop_async=$null; stop_reason='';
    stop_started_utc=[DateTime]::MinValue; stop_error=''; stop_attempts=0; stop_complete=$false
}
Stop-UiIdentityQuery -Query $throwingQuery -Reason 'test_failure'
$failedStopTime = $throwingQuery.stop_started_utc
Stop-UiIdentityQuery -Query $throwingQuery -Reason 'test_failure_retry'
Assert-UiTarget ($throwingQuery.stop_error -match 'stop failure fixture' -and $throwingQuery.stop_attempts -eq 2 -and
    $throwingQuery.stop_started_utc -eq $failedStopTime) `
    'BeginStop异常必须可见，有限重试不能重置关闭期限。'

$uiSourceText = [System.IO.File]::ReadAllText($uiScript,[System.Text.Encoding]::UTF8)
Assert-UiTarget ($uiSourceText.Contains('Get-UiCallTargetSummaryProfile -Profile $script:storedProfile') -and
    -not $uiSourceText.Contains("New-EffectiveTargetProfile -Profile `$script:storedProfile -Target (Get-SelectedTargetTag)")) `
    '快速目标复用真实tx_policy.replace并沿用发射许可，不写入RX命令。'
Assert-UiTarget ($uiSourceText.Contains('Invoke-RadioIdentityQuery -RadioId $RadioId -CachePath $CachePath -TimeoutSec 5') -and
    $uiSourceText.Contains('BeginInvoke()') -and $uiSourceText.Contains('EndStop(') -and
    $uiSourceText.Contains("Runspace.RunspaceStateInfo.State")) `
    '资料查询须在后台runspace调用5秒HTTP模块，并观察Stop与runspace关闭状态。'
Assert-UiTarget ($uiSourceText.Contains('cache_saved') -and $uiSourceText.Contains('本机缓存保存失败') -and
    $mainXaml.Contains('分类由本机用户维护；本版未读取服务器绑定列表')) `
    '查询缓存写入失败与本机收藏分类必须按真实状态说明。'

Write-Output '通过：TX目标与RX/许可隔离、来话去重与历史目标映射、收藏64项原子读回/更新/删除、身份新鲜度保护和runspace取消收尾已校验。'

Write-Output '通过：schema 2 预设、完整多组策略可编辑、跨组来源屏蔽保留、迁移与控制协议 UI 字段已校验。'
