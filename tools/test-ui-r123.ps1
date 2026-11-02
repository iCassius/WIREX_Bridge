#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw '请使用 Windows PowerShell 5.1 运行此回归。' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw '请使用 -STA 运行此 WPF 回归。' }
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase -ErrorAction Stop
$script:assertionCount = 0

function Assert-R123 {
    param([bool]$Condition,[string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-R123Color {
    param([object]$Element)
    if ($Element.Background -is [System.Windows.Media.SolidColorBrush]) { return $Element.Background.Color.ToString() }
    return [string]$Element.Background
}

function Get-R123Card {
    param([string]$Key)
    return @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { -not $_.Tag.blank -and [string]$_.Tag.channel_key -ceq $Key }) | Select-Object -First 1
}

function Start-UiChannelMutation {
    param([object[]]$Channels,[string]$TxKey,[hashtable]$MutedKeys=@{},[string]$Action='更新频道')
    $script:lastChannelMutation = [pscustomobject]@{ channels=@($Channels); tx_key=$TxKey; muted_keys=$MutedKeys; action=$Action }
    return $true
}

function Set-ConnectionConfigLocked { return }
function Test-UiRadioCatUserActionBusy { return $false }
function Update-UiSerialConnectButton { return }
function Request-UiControlStatus { return $false }
function Update-UiAudioGainControls { return }
function Connect-UiBmFromButton { return [bool](Set-UiBmConnectionEnabled -Enabled $true) }

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridgePath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$bmUiPath = Join-Path $repoRoot 'ui\windows\BmManagementUi.ps1'
$xamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
foreach ($path in @($PSCommandPath,$bridgePath,$bmUiPath,$xamlPath)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-R123 ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ("{0} 缺少 UTF-8 BOM" -f [IO.Path]::GetFileName($path))
}
foreach ($path in @($bridgePath,$bmUiPath)) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    Assert-R123 ($parseErrors.Count -eq 0) ("{0} PowerShell 语法解析失败" -f [IO.Path]::GetFileName($path))
    $definitions = @($tokens)
    $ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$true))
    Invoke-Expression (($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n")
}

# Override only external action boundaries after loading the production function bodies.
function Start-UiChannelMutation {
    param([object[]]$Channels,[string]$TxKey,[hashtable]$MutedKeys=@{},[string]$Action='更新频道')
    $script:lastChannelMutation = [pscustomobject]@{ channels=@($Channels); tx_key=$TxKey; muted_keys=$MutedKeys; action=$Action }
    return $true
}
function Set-ConnectionConfigLocked { return }
function Test-UiRadioCatUserActionBusy { return $false }
function Update-UiSerialConnectButton { return }
function Request-UiControlStatus { return $false }
function Update-UiAudioGainControls { return }
function Connect-UiBmFromButton { return [bool](Set-UiBmConnectionEnabled -Enabled $true) }

$script:mainWindow = Import-WpfWindow -Path $xamlPath
$script:mainWindow.Opacity = 0
$script:mainWindow.Show()
$script:mainWindow.UpdateLayout()
$script:mainXamlPath = $xamlPath
$script:settingsXamlPath = Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'
$script:channels = @()
$script:txChannelKey = ''
$script:mutedChannelKeys = @{}
$script:channelPageIndex = 0
$script:channelEditorSlot = 2
$script:channelPresetId = ''
$script:channelPresetKind = ''
$script:loadingChannelPreset = $false
$script:channelMutationSafetyStopPending = $false
$script:pendingRoutingMutation = $null
$script:pendingChannelMutation = $null
$script:pendingChannelStopMutation = $null
$script:routingMutationFence = $false
$script:supervisor = $null
$script:activeRouting = $null
$script:latestStatus = $null
$script:lastStatusUtc = [DateTime]::MinValue
$script:portableConfig = [pscustomobject][ordered]@{ connection=[pscustomobject][ordered]@{ source_id=[uint64]123456; api_key='' }; channels=@(); tx_channel_id='' }
$script:callIdentityCache = @{}
$script:transientStatusText = ''
$script:transientStatusLastMessage = ''
$script:transientStatusFailed = $false
$script:transientStatusDeadlineUtc = [DateTime]::MinValue

try {
    # Transient text is visible only until its first deadline; an old repeated poll cannot renew it.
    Set-UiTransientStatus -Message '测试提示'
    $firstDeadline = $script:transientStatusDeadlineUtc
    Assert-R123 ($script:mainWindow.FindName('TransientStatusText').IsVisible -and $script:mainWindow.FindName('TransientStatusText').Text -ceq '测试提示') 'transient 状态没有显示在顶部'
    Set-UiTransientStatus -Message '测试提示'
    Assert-R123 ($script:transientStatusDeadlineUtc -eq $firstDeadline) '重复设置旧消息延长了 TTL'
    $script:transientStatusDeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
    Update-UiTransientStatusExpiry
    Assert-R123 (-not $script:mainWindow.FindName('TransientStatusText').IsVisible -and -not $script:transientStatusText) 'TTL 到期后没有清空 transient 状态'
    for ($tick=0; $tick -lt 4; $tick++) {
        Set-UiTransientStatus -Message '测试提示'
        Update-UiTransientStatusExpiry
    }
    Assert-R123 (-not $script:transientStatusText -and -not $script:mainWindow.FindName('TransientStatusText').IsVisible) '重复旧消息或 tick 在到期后恢复了 transient 状态'
    Set-UiTransientStatus -Message '测试提示' -Restart
    Assert-R123 ($script:mainWindow.FindName('TransientStatusText').IsVisible -and $script:transientStatusDeadlineUtc -gt [DateTime]::UtcNow) '显式 Restart 没有重新显示同一事件'
    [void](Clear-UiTransientStatus)
    $longMessage = '临时事件详情' * 30
    Set-UiTransientStatus -Message $longMessage -Restart
    Assert-R123 ($script:mainWindow.FindName('TransientStatusText').Text.Length -le 180 -and $script:mainWindow.FindName('TransientStatusText').ToolTip -ceq $longMessage) '长 transient 提示没有保留完整 Tooltip 原文'
    [void](Clear-UiTransientStatus)

    # Presets synchronize type, while manually edited IDs lose preset semantics.
    $inputHandlerResult = @(Initialize-UiChannelInputHandlers)
    Assert-R123 ($inputHandlerResult -contains $true) '可编辑频道 ComboBox 没有取得内部文本框'
    $channelId = $script:mainWindow.FindName('ChannelIdBox')
    $channelKind = $script:mainWindow.FindName('ChannelKindBox')
    [void](Set-UiChannelPresetFromSelection -SelectedItem $channelId.Items[0])
    Assert-R123 ([string]$channelId.Text -ceq '460997' -and [string]$channelKind.SelectedItem.Tag -ceq 'private' -and $script:channelPresetId -ceq '460997') '460997 预设没有选择单呼'
    $editable = $channelId.Template.FindName('PART_EditableTextBox',$channelId)
    $editable.Text = '12345'
    [void](Update-UiChannelPresetFromManualText)
    Assert-R123 ([string]$channelKind.SelectedItem.Tag -ceq 'unknown' -and -not $script:channelPresetKind) '手输 ID 没有清除旧的 private 预设类型'
    [void](Set-UiChannelPresetFromSelection -SelectedItem $channelId.Items[1])
    Assert-R123 ([string]$channelId.Text -ceq '46001' -and [string]$channelKind.SelectedItem.Tag -ceq 'group' -and $script:channelPresetId -ceq '46001') '46001 预设没有选择组呼'
    $editable = $channelId.Template.FindName('PART_EditableTextBox',$channelId); $editable.Text = '12346'; [void](Update-UiChannelPresetFromManualText)
    Assert-R123 ([string]$channelKind.SelectedItem.Tag -ceq 'unknown') '手输 ID 没有清除旧的 group 预设类型'
    [void](Set-UiChannelPresetFromSelection -SelectedItem $channelId.Items[2])
    Assert-R123 ([string]$channelId.Text -ceq '91' -and [string]$channelKind.SelectedItem.Tag -ceq 'group' -and $script:channelPresetId -ceq '91') '91 预设没有选择组呼'
    $editable = $channelId.Template.FindName('PART_EditableTextBox',$channelId); $editable.Text = '460997'; [void](Update-UiChannelPresetFromManualText)
    Assert-R123 ([string]$channelKind.SelectedItem.Tag -ceq 'unknown') '手输预设相同数字时错误地自动选择了 private'
    $channelKind.SelectedIndex = 2
    $editable.Text = '12347'
    [void](Update-UiChannelPresetFromManualText)
    Assert-R123 ([string]$channelKind.SelectedItem.Tag -ceq 'group') '手输字段覆盖了用户显式选择的呼叫类型'

    # The listener add callback preserves an existing PTT destination and initializes only an empty target.
    $script:channels = @((New-UiChannelRecord -Id 91 -Kind group -Slot 2))
    $script:txChannelKey = 'group:91:2'
    $script:mutedChannelKeys = @{}
    $channelId.SelectedIndex = -1; $editable.Text = '12345'; [void](Update-UiChannelPresetFromManualText); $channelKind.SelectedIndex = 2
    [void](Add-UiChannelFromInputs)
    Assert-R123 ($script:lastChannelMutation.tx_key -ceq 'group:91:2') '加入第二个监听频道改变了现有 PTT 目标'
    $script:channels = @(); $script:txChannelKey = ''
    $channelId.SelectedIndex = -1; $editable.Text = '12345'; [void](Update-UiChannelPresetFromManualText); $channelKind.SelectedIndex = 2
    [void](Add-UiChannelFromInputs)
    Assert-R123 ($script:lastChannelMutation.tx_key -ceq 'group:12345:2') '空 PTT 目标没有被第一个频道初始化'

    # Receive call details never color the entire card as TX; only a selected active TX target turns red.
    $script:channels = @(
        (New-UiChannelRecord -Id 91 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 46001 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 460997 -Kind private -Slot 2)
    )
    $script:txChannelKey = 'group:91:2'
    $script:mutedChannelKeys = @{}
    $script:activeRouting = $null
    $script:callIdentityCache['1234'] = [pscustomobject]@{ status='found'; callsign='TEST'; name='Operator' }
    $script:latestStatus = [pscustomobject]@{
        current_call_valid=$true; current_call_kind='G'; current_call_slot=[uint64]2
        current_call_source_id=[uint64]1234; current_call_destination_id=[uint64]46001
    }
    Update-UiChannelDisplays
    $selected = Get-R123Card -Key 'group:91:2'
    $received = Get-R123Card -Key 'group:46001:2'
    $receivedTexts = @(Get-UiVisualTextValues -Root $received) -join ' '
    Assert-R123 ((Get-R123Color $selected) -ceq '#FF28583C' -and (Get-R123Color $received) -ceq '#FF1D2529' -and $receivedTexts.Contains('TEST')) '接收来话没有保持中性卡色或呼号未显示'
    Assert-R123 ([string]$selected.BorderBrush.Color.ToString() -ceq '#FF46545B' -and [string]$received.BorderBrush.Color.ToString() -ceq '#FF46545B') '频道卡边框不是统一中性色'
    $script:mutedChannelKeys['group:91:2'] = $true
    Assert-R123 ((Get-UiChannelCardPresentation -Channel $script:channels[0]).background -ceq '#28583C') '屏蔽频道改变了 PTT 目标绿色背景'
    foreach ($owner in @('tx_active','tx_draining')) {
        $script:activeRouting = [pscustomobject]@{
            media_owner=$owner; tx_target=[pscustomobject]@{ destination_id=[uint64]91; kind='group'; slot=[uint64]2 }
        }
        Assert-R123 ((Get-UiChannelCardPresentation -Channel $script:channels[0]).background -ceq '#713237') ("$owner 没有使实际 TX 目标变红")
    }
    $script:activeRouting = [pscustomobject]@{ media_owner='idle'; tx_target=$null }
    Assert-R123 ((Get-UiChannelCardPresentation -Channel $script:channels[0]).background -ceq '#28583C') 'PTT 结束后选中目标没有恢复绿色背景'

    # BM UI stays fixed and empty without a key; supplying a key restores the existing local readiness gates only.
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ gateway_id=[uint64]12345678 } }
    $script:activeProfile = $null
    $script:portableConfig.connection.api_key = ''
    $script:bmManagementModulePath = Join-Path $repoRoot 'ui\windows\BmManagement.psm1'
    $script:bmManagementModuleAvailable = $false
    $script:bmManagementOperationPowerShell = $null
    $script:bmManagementStatus = 'unavailable'
    $script:bmManagementGroups = @()
    $script:bmManagementTransientStatusText = ''
    Initialize-BmManagementUi -Window $script:mainWindow
    $staticPanel = $script:mainWindow.FindName('BmStaticGroupPanel')
    $staticOverlay = $script:mainWindow.FindName('StaticApiRequiredOverlay')
    $staticList = $script:mainWindow.FindName('BmStaticGroupsList')
    Assert-R123 ($staticPanel.IsVisible -and $staticOverlay.IsVisible -and $staticList.IsVisible -and -not $staticList.IsEnabled -and $staticList.Items.Count -eq 0) '无 API key 时静态组固定区没有显示空列表和提示覆盖层'
    foreach ($name in @('BmStaticGroupIdBox','AddBmStaticGroupButton','RemoveBmStaticGroupButton','RefreshBmStaticGroupsButton','BmStaticGroupPagePreviousButton','BmStaticGroupPageNextButton')) {
        Assert-R123 (-not $script:mainWindow.FindName($name).IsEnabled) ("无 API key 时 $name 仍可操作")
    }
    Assert-R123 ($null -eq $script:bmManagementOperationPowerShell -and @($script:bmManagementGroups).Count -eq 0) '无 API key 时启动了后台静态组操作或保留了假数据'
    $staticList.ItemsSource = $null; $staticList.Items.Clear()
    $script:bmManagementModuleAvailable = $true
    $script:bmManagementStatus = 'loaded'
    $script:bmManagementObservedDeviceId = '12345678'
    $script:bmManagementObservedApiKey = 'fake-test-key'
    $script:bmManagementUiControls['BmApiKeyBox'].Password = 'fake-test-key'
    $script:bmManagementAddContext = [pscustomobject]@{ success=$true; device_id='12345678'; add_slot='2' }
    $script:bmManagementGroups = @([pscustomobject]@{ device_id='12345678'; talkgroup=[uint64]91; slot=2; type='static'; text='TG 91' })
    Update-BmManagementUiVisiblePage
    Set-BmManagementUiControlState
    Assert-R123 (-not $staticOverlay.IsVisible -and $staticList.IsEnabled -and $staticList.Items.Count -eq 1 -and $script:mainWindow.FindName('RefreshBmStaticGroupsButton').IsEnabled) '填入测试 key 后没有恢复已加载静态组操作控件'
    Assert-R123 ($null -eq $script:bmManagementOperationPowerShell) '恢复本地 UI gate 时启动了实际 BM API 请求'

    # BM connection toggle invokes the existing core command path and preserves retry/busy state gates.
    $commands = New-Object 'System.Collections.Generic.List[object]'
    $supervisor = [pscustomobject]@{ HasExited=$false; RejectNext=$false; Commands=$commands }
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$ParametersJson='')
        $this.Commands.Add([pscustomobject]@{ request_id=$RequestId; command=$Command; parameters_json=$ParametersJson })
        if ($this.RejectNext) { $this.RejectNext=$false; return $false }
        return $true
    }
    $script:supervisor = $supervisor
    $script:controlConfirmed = $true
    $script:bmConnectionNativeCapability = $true
    $script:controlDiagnostic = $false
    $script:bmConnectionRevision = [uint64]10
    $script:bmConnectionPendingRequest = $null
    $script:pendingControlRequests = @{}
    $script:bmConnectAfterCoreReady = $false
    $script:latestStatus = [pscustomobject]@{ hri_ready=$true; hri_y_zero_ready=$true }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $script:bmConnectionSnapshot = [pscustomobject]@{ requested_enabled=$false; resolving=$false; transport_open=$false; bm_state='stopped'; revision=[uint64]10 }
    Assert-R123 (Toggle-UiBmConnection) 'BM toggle 没有提交现有连接请求'
    Assert-R123 ($commands.Count -eq 1 -and $commands[0].command -ceq 'bm.connection.set' -and (ConvertFrom-Json $commands[0].parameters_json).enabled) '连接BM 没有复用 bm.connection.set 命令'
    $script:bmConnectionPendingRequest.ack_received = $true
    $script:bmConnectionSnapshot = [pscustomobject]@{ requested_enabled=$true; resolving=$false; transport_open=$true; bm_state='ready'; revision=[uint64]11 }
    Set-ConnectionButtonState
    Assert-R123 ($script:mainWindow.FindName('ConnectButton').Content -ceq '断开BM' -and $script:mainWindow.FindName('ConnectButton').IsEnabled) 'BM ready 后 toggle 没有显示可用的断开操作'
    Assert-R123 (-not (Toggle-UiBmConnection) -or $commands.Count -eq 2) 'BM 断开 toggle 没有走现有关闭状态路径'
    Assert-R123 ($commands.Count -eq 2 -and -not (ConvertFrom-Json $commands[1].parameters_json).enabled) '断开BM 没有提交 disabled 请求'
    $script:bmConnectionPendingRequest = $null
    $script:bmConnectionRevision = [uint64]12
    $script:bmConnectionSnapshot = [pscustomobject]@{ requested_enabled=$false; resolving=$false; transport_open=$false; bm_state='stopped'; revision=[uint64]12 }
    $supervisor.RejectNext = $true
    Assert-R123 (-not (Toggle-UiBmConnection)) '核心拒绝请求后 toggle 报告成功'
    Assert-R123 ($null -eq $script:bmConnectionPendingRequest -and $script:mainWindow.FindName('ConnectButton').Content -ceq '连接BM' -and $script:mainWindow.FindName('ConnectButton').IsEnabled) '发送失败后没有清理 pending 或保留重试入口'
    $script:bmConnectionPendingRequest = [pscustomobject]@{ enabled=$true; revision=[uint64]13; ack_received=$false }
    $script:bmConnectionSnapshot = [pscustomobject]@{ requested_enabled=$true; resolving=$true; transport_open=$false; bm_state='resolving'; revision=[uint64]13 }
    Set-ConnectionButtonState
    $sentBeforeBusyClick = $commands.Count
    Assert-R123 ($script:mainWindow.FindName('ConnectButton').Content -ceq '正在连接BM' -and -not $script:mainWindow.FindName('ConnectButton').IsEnabled) 'BM busy 状态没有禁用 toggle 按钮'
    Assert-R123 (-not (Toggle-UiBmConnection) -and $commands.Count -eq $sentBeforeBusyClick) 'BM busy 状态接受了第二个连接请求'

    # Layout contract: 3×2 cards, 5-row history and removed status controls are represented directly in XAML.
    $xamlText = [IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8)
    Assert-R123 ($xamlText -match 'Rows="2" Columns="3"' -and $xamlText -match 'x:Name="CallHistoryList"[^>]*Height="82"') 'XAML 没有固定3×2频道卡或五行历史高度'
    foreach ($removed in @('FooterText','ChannelStatusText','BmStaticGroupStatus','PlaybackGainStatusValue','DisconnectBmButton','SerialDisconnectButton')) {
        Assert-R123 ($xamlText -notmatch ('x:Name="' + [regex]::Escape($removed) + '"')) ("XAML 保留了已移除的状态控件 $removed")
    }
    Write-Output ("PASS: test-ui-r123.ps1 ({0} assertions; PowerShell 5.1 STA; no device or BM request)" -f $script:assertionCount)
} finally {
    if ($script:mainWindow -and $script:mainWindow.IsVisible) { $script:mainWindow.Close() }
}
