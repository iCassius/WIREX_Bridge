[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
$script:assertionCount = 0

function Assert-UiChannels {
    param([bool]$Condition,[string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw $Message }
}

function Get-BmManagementUiDeviceId { return [string]$script:testBmDeviceId }
function Get-BmManagementUiApiKey { return [string]$script:testBmApiKey }

function Receive-TestQuickCallResult {
    param([Parameter(Mandatory=$true)][object]$Request,[Parameter(Mandatory=$true)][string]$Result,
        [string]$ErrorCode='',[string]$ActivationStatus='',[uint64]$DestinationId=0,[uint64]$Slot=0,
        [uint64]$FramesSent=0,[bool]$Replayed=$false)
    $script:testControlSequence++
    $record=[ordered]@{
        type='control_result';command='network_subscription.quick_call_join';run_id=[string]$Request.run_id
        request_id=[string]$Request.request_id;control_seq=[uint64]$script:testControlSequence
        result=$Result;replayed=$Replayed
    }
    if ($Result -ceq 'ok') {
        $record.activation_status=$ActivationStatus; $record.destination_id=$DestinationId
        $record.slot=$Slot; $record.frames_sent=$FramesSent
    } else { $record.error=$ErrorCode }
    $script:testControlRecord=[pscustomobject]$record
    $script:supervisor.Events=@('{}')
    [void](Process-UiControlEvents)
}

function Get-TestFileHash {
    param([Parameter(Mandatory=$true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))) }
    finally { $sha.Dispose() }
}

function Get-TestUiControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:mainWindow.FindName($Name)
    if (-not $control) { throw "测试窗口缺少控件 $Name。" }
    return $control
}

function Get-TestChannelButton {
    param([Parameter(Mandatory=$true)][string]$ChannelKey,[Parameter(Mandatory=$true)][string]$Action)
    $card=@($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object {
        -not $_.Tag.blank -and [string]$_.Tag.channel_key -ceq $ChannelKey
    }) | Select-Object -First 1
    if (-not $card) { return $null }
    $grid=@($card.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.UniformGrid] }) | Select-Object -First 1
    return @($grid.Children | Where-Object { $_ -is [System.Windows.Controls.Button] -and [string]$_.Tag.action -ceq $Action }) | Select-Object -First 1
}

function New-TestChannelSupervisor {
    param([string]$MediaOwner='rx_active',[bool]$StopAlreadyComplete=$false)
    $commands = New-Object 'System.Collections.Generic.List[object]'
    $stopSource = New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
    if ($StopAlreadyComplete) { [void]$stopSource.TrySetResult(1) }
    $instance = [pscustomobject]@{
        HasExited=$false; ControlVersion=0; ProcessId=4242; ExitCode=0; Commands=$commands
        StopSource=$stopSource; StopCallCount=0; Disposed=$false; RejectCommands=@()
        HasControlEventOverflow=$false; Events=@()
    }
    Add-Member -InputObject $instance -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$ParametersJson='')
        $this.Commands.Add([pscustomobject]@{request_id=$RequestId;command=$Command;parameters_json=$ParametersJson})
        if (@($this.RejectCommands) -ccontains $Command) { return $false }
        return $true
    } | Out-Null
    Add-Member -InputObject $instance -MemberType ScriptMethod -Name StopAsync -Value {
        param([int]$TimeoutMs)
        $this.StopCallCount++
        return $this.StopSource.Task
    } | Out-Null
    Add-Member -InputObject $instance -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed=$true } | Out-Null
    Add-Member -InputObject $instance -MemberType ScriptMethod -Name TryGetExitCode -Value {
        param([ref]$ExitCode)
        $ExitCode.Value = [int]$this.ExitCode
        return $true
    } | Out-Null
    Add-Member -InputObject $instance -MemberType ScriptMethod -Name DrainControlEvents -Value {
        param([int]$Limit)
        $events = @($this.Events)
        $this.Events = @()
        return $events
    } | Out-Null
    if ($script:allTestSupervisors) { $script:allTestSupervisors.Add($instance) }
    return $instance
}

function Open-TestMainWindow {
    $script:mainWindow = Import-WpfWindow -Path $script:mainXamlPath
    $script:mainWindow.Opacity = 0
    $script:mainWindow.Show()
    $script:mainWindow.UpdateLayout()
    Add-UiComboOpenHandlers -Window $script:mainWindow
    if (-not (Initialize-UiChannelInputHandlers)) { throw '频道 ID 下拉框没有可编辑输入区。' }
    (Get-TestUiControl 'AddChannelButton').Add_Click({ Add-UiChannelFromInputs })
    return $script:mainWindow
}

function Invoke-TestPreviewClick {
    param([Parameter(Mandatory=$true)][System.Windows.UIElement]$Element)
    $event = [System.Windows.Input.MouseButtonEventArgs]::new(
        [System.Windows.Input.Mouse]::PrimaryDevice,0,[System.Windows.Input.MouseButton]::Left)
    $event.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
    $event.Source = $Element
    $Element.RaiseEvent($event)
    # Let WPF finish popup ownership/focus work before the assertion reads the
    # resulting state. Background priority can run before popup activation settles.
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
}

function Start-TestPendingChannelRemoval {
    param([switch]$RejectRxSend)
    $script:channels = @(
        (New-UiChannelRecord -Id 12345 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 91 -Kind group -Slot 2)
    )
    $script:txChannelKey = 'group:12345:2'
    $script:mutedChannelKeys = @{}
    $script:portableConfig.channels = [object[]]$script:channels
    $script:portableConfig.tx_channel_id = $script:txChannelKey
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    $originalConfig = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    $script:supervisor = New-TestChannelSupervisor
    if ($RejectRxSend) { $script:supervisor.RejectCommands = @('rx_policy.replace') }
    $script:controlConfirmed = $true; $script:routingCapabilities = $true
    $script:stopTask = $null; $script:closingAfterStop = $false; $script:reconnectAfterStop = $false
    $script:channelMutationSafetyStopPending = $false
    $script:pendingChannelMutation = $null; $script:pendingRoutingMutation = $null
    $script:timedOutRoutingMutations = @{}; $script:resolvedTimedOutRoutingRequests = @{}
    $script:routingMutationFence = $false; $script:pendingControlRequests = @{}
    $script:pendingRoutingStatusRequestId = ''; $script:lastStatusUtc = [DateTime]::MinValue; $script:latestStatus = $null
    $policy = Get-UiNativeRxPolicyForChannels -Channels $script:channels
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]20; tx_policy_revision=[uint64]30
        tx_target=[pscustomobject]@{destination_id=[uint64]12345;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$policy; transmit_enabled=$true
    }
    Remove-UiChannel -Channel $script:channels[0]
    if (-not $script:pendingRoutingMutation -or $script:pendingRoutingMutation.command -cne 'tx_policy.replace') {
        throw '部分应用测试没有启动预期的 TX 更新。'
    }
    return [pscustomobject]@{config_text=$originalConfig;channels=@($script:channels);tx_key=$script:txChannelKey;rx_policy=$policy}
}

function Complete-TestPendingTxAck {
    $mutation = $script:pendingRoutingMutation
    if (-not $mutation -or $mutation.command -cne 'tx_policy.replace') { throw '缺少待确认的 TX 更新。' }
    [void]$script:pendingControlRequests.Remove([string]$mutation.request_id)
    $script:pendingRoutingMutation = $null
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]20; tx_policy_revision=[uint64]31
        tx_target=[pscustomobject]@{destination_id=[uint64]91;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$script:activeRouting.rx_policy; transmit_enabled=$true
    }
    [void](Complete-UiChannelMutation -Mutation $mutation -Routing $script:activeRouting)
    return $script:pendingRoutingMutation
}

function Complete-TestChannelSafetyStop {
    $supervisor = $script:supervisor
    if (-not $supervisor) { throw '安全停机夹具没有 supervisor。' }
    [void]$supervisor.StopSource.TrySetResult(0)
    $supervisor.HasExited = $true
    $script:stopTask = $supervisor.StopSource.Task
    [void](Complete-BridgeStop)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$radioCatPath = Join-Path $repoRoot 'ui\windows\RadioCatUi.ps1'
$mainXamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
$settingsXamlPath = Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'
$portableConfigModulePath = Join-Path $repoRoot 'ui\windows\PortableConfig.psm1'
$channelActivationStateModulePath = Join-Path $repoRoot 'ui\windows\ChannelActivationState.psm1'
$radioIdentityModulePath = Join-Path $repoRoot 'ui\windows\RadioIdentity.psm1'
$bridgeUserConfigModulePath = Join-Path $repoRoot 'tools\bridge-user-config.psm1'
$mainTokens = $null; $mainErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$mainTokens,[ref]$mainErrors)
Assert-UiChannels ($mainErrors.Count -eq 0) 'bridge-ui.ps1 解析失败。'
$catTokens = $null; $catErrors = $null
$catAst = [System.Management.Automation.Language.Parser]::ParseFile($radioCatPath,[ref]$catTokens,[ref]$catErrors)
Assert-UiChannels ($catErrors.Count -eq 0) 'RadioCatUi.ps1 解析失败。'
$mainDefinitions = @($mainAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
foreach ($name in @('Import-UiPortableConfig','Set-ConnectionButtonState','Set-ConnectionConfigLocked','Update-UiChannelDisplays','Set-UiChannelPage')) {
    $matches = @($mainDefinitions | Where-Object { $_.Name -ceq $name })
    Assert-UiChannels ($matches.Count -eq 1) ("{0} 应只有一个函数定义，实际为 {1}。" -f $name,$matches.Count)
}
$allDefinitions = @($mainDefinitions) + @($catAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
$functionNames = @(
    'Import-WpfWindow','Get-UiControl','Get-SettingsControl','Get-UiChannelKey','Get-UiChannelTarget','Get-UiChannelByKey',
    'New-UiChannelRecord','Get-UiNativeRxPolicyForChannels','Get-UiChannelCurrentCall','Get-UiChannelCardPresentation','Get-UiChannelCallerLabel',
    'ConvertFrom-UiPortableConfigToProfile','Save-UiPortableConfig','Fit-WpfWindowToWorkArea',
    'Set-MainText','Set-UiTransientStatus','Clear-UiTransientStatus','Update-UiTransientStatusExpiry',
    'Set-UiChannelStatus','New-UiChannelActionButton','Update-UiChannelDisplays','Set-UiChannelPage','Start-UiChannelMutation',
    'Get-UiChannelCallerDetails','New-UiDmIdLinkTextBlock','Open-UiDmIdProfile','Get-UiNativeIdentityCallsign',
    'Get-UiChannelTargetFromRouting','Complete-UiChannelMutation','Add-UiChannelFromInputs','Remove-UiChannel','Set-UiChannelMuted',
    'Get-UiKnownChannelName','Get-UiChannelDisplayName','Test-UiBmStaticChannelReadback','Get-UiChannelActivationPresentation',
    'Set-UiChannelPresetFromSelection','Update-UiChannelPresetFromManualText','Initialize-UiChannelInputHandlers','Get-UiSelectedChannelPreset',
    'Add-UiQuickCallDiagnostic','Reset-UiChannelActivationForBmReconnect','Clear-UiChannelActivationAfterGroupPtt',
    'Test-UiMouseOriginWithinElement','Set-DynamicGroupStatus',
    'Save-SettingsFromWindow','Get-UiSafeSettingsSaveErrorText','Copy-UiPortableConfigValue','ConvertTo-UiOptionalUnsigned',
    'Get-UiComboValue','Get-UiComboItemValue','Request-Reconnect','Start-BridgeRun',
    'Get-UiRadioCatPortConflictMessage','Test-UiRadioCatUserActionBusy','Get-UiRadioCatSessionState',
    'Invoke-UiSetCallTarget','Invoke-UiChannelQuickCall','Invoke-UiRoutingDiagnosticChannelQuickCallButton','Open-UiSetupPage','Register-UiSetupLinks',
    'Test-UiControlUnsigned','Test-UiExactControlFields','Test-UiRxPolicy','Copy-UiRxPolicy','Invoke-UiRoutingMutation',
    'Complete-UiChannelMutationFailure','Add-UiComboOpenHandlers','Register-UiRadioCatPortTextInput','Get-UiRadioCatConnectionKey',
    'Get-UiHriPortName','Set-UiRadioCatText','Set-UiRadioCatControlEnabled','Find-UiRadioCatControl','Set-UiRadioCatControls',
    'Set-UiRadioCatPowerSliderRange','Get-UiRadioCatObservedValue','Update-UiRadioCatObservationDisplay','Update-UiRadioCatControls',
    'Initialize-UiSettingsWindow','Initialize-SettingsWindow','Set-UiComboValue','Complete-BridgeStopInternal','Complete-BridgeStop',
    'On-UiTimerTick','Request-UiRoutingStatus','Update-UiBmConnectionPoll','Request-UiControlStatus','Set-UiBmConnectionSnapshot',
    'Set-UiControlStatus','Set-UiOfflineDisplay','Set-OfflineDisplay',
    'Set-ConnectionButtonState','Set-ConnectionConfigLocked','Test-UiBmTransportFieldsLocked','Set-UiIdentityRowVisibility','Update-UiPlaybackGainDisplay',
    'Test-UiAudioGainCapability','Update-UiAudioGainControls','Update-UiAudioGainValueLabels',
    'Convert-UiGainSliderToMilli',
    'Set-UiGatewayIdentityState','Get-UiGatewayIdentityForSave',
    'Complete-UiRadioCatOperationAndPersist','Complete-UiRadioCatOperation','Invoke-UiRadioCatPollTick','Start-UiRadioCatOperation',
    'Test-UiRadioCatHardwareAccessAllowed','Test-UiRadioCatExplicitFakeHook','Test-UiRadioCatPortConflictWithHri',
    'Get-UiRadioCatHriPortForOperation','Process-UiControlEvents','Read-StatusUpdates',
    'Set-StaleDisplay','Complete-UiDeviceDiscovery','Complete-BridgePreparation','Clear-UiSessionTemp','Stop-UiRadioCatPolling','Update-RoutingDisplays',
    'Set-RoutingMutationPendingState','Set-RoutingEditorStatus','Add-UiEvent','Update-DynamicGroupControls','Reset-UiControlState',
    'Expire-UiAudioGainRequest',
    'Get-UiSourceIdentityDisplay','Get-UiRadioCatSelectedPort','Get-UiRadioCatStopBits','Get-UiRadioCatBaudRate',
    'Update-UiReceiveMetricsDisplay','Update-UiIdentityActionState','Complete-UiIdentityQuery','Expire-UiNativeIdentityUpdate',
    'Start-UiChannelMutationSafetyStop','Clear-UiChannelMutationSafetyState','Get-UiVisualTextValues',
    'Test-UiPathWithinDirectory','Test-UiRoutingDiagnosticConfigDirectory'
)
# Extract the selected functions by their own AST names; this keeps the test tied to production bodies.
$selected = @($allDefinitions | Where-Object { $functionNames -ccontains $_.Name })
Invoke-Expression (($selected | ForEach-Object { $_.Extent.Text }) -join "`r`n")
$script:actualStartBridgeRun = (Get-Command Start-BridgeRun -CommandType Function).ScriptBlock
$script:actualCompleteBridgePreparation = (Get-Command Complete-BridgePreparation -CommandType Function).ScriptBlock
Import-Module -Name $portableConfigModulePath -Force
Import-Module -Name $channelActivationStateModulePath -Force
Import-Module -Name $radioIdentityModulePath -Force
Import-Module -Name $bridgeUserConfigModulePath -Force

$mainXaml = [System.IO.File]::ReadAllText($mainXamlPath)
$settingsXaml = [System.IO.File]::ReadAllText($settingsXamlPath)
$bridgeSource = [System.IO.File]::ReadAllText($uiPath)
$radioCatSource = [System.IO.File]::ReadAllText($radioCatPath)
foreach ($forbidden in @('FavoritesPanel','FavoritesList','TransmitEnabledBox','CatStopBitsBox','FavoritesButton')) {
    Assert-UiChannels ($mainXaml -notmatch ('x:Name="' + [regex]::Escape($forbidden) + '"')) ("MainWindow.xaml 仍含已删除控件 {0}。" -f $forbidden)
}
foreach ($required in @('ChannelIdBox','ChannelKindBox','AddChannelButton','ChannelCardsPanel','CatPortBox','DeviceNumberBox','BmApiKeySetupLink','BmPasswordSetupLink')) {
    Assert-UiChannels ($mainXaml -match ('x:Name="' + [regex]::Escape($required) + '"')) ("MainWindow.xaml 缺少 {0}。" -f $required)
}
Assert-UiChannels ($mainXaml -notmatch 'x:Name="GatewayBox"|x:Name="ColorCodeBox"|x:Name="MakeChannelTxTargetCheckBox"' -and
    $bridgeSource -notmatch 'GatewayBox|ColorCodeBox|MakeChannelTxTargetCheckBox') '旧Gateway/色码/自动PTT编辑控件仍被保留或脚本仍引用。'
Assert-UiChannels ($mainXaml -notmatch 'x:Name="ChannelListPanel"') 'MainWindow.xaml 仍有重复频道清单。'
Assert-UiChannels ($mainXaml -notmatch 'ReadRadioButton|读取电台' -and
    @([regex]::Matches($mainXaml,'x:Name="SerialConnectButton"')).Count -eq 1 -and
    $mainXaml -match 'x:Name="SerialConnectButton"[^>]*Content="连接串口"' -and
    $radioCatSource -match '\$button\.Content = ''断开串口''' -and
    $radioCatSource -match '\$button\.Content = ''取消连接''' -and
    $radioCatSource -match 'function Update-UiSerialConnectButton') '电台串口连接未使用单个真实状态 toggle，或仍显示单独读取按钮。'
Assert-UiChannels ($mainXaml -match 'Rows="2" Columns="3"' -and
    $mainXaml -notmatch 'ChannelAdvancedButton|Content="TS1"|Content="TS2"' -and
    $settingsXaml -notmatch 'ChannelSlotBox|TS1|TS2|时隙') '主界面或频道说明窗口仍暴露时隙入口。'
Assert-UiChannels ($mainXaml -match 'ChannelPagePreviousButton' -and $mainXaml -match 'ChannelPageNextButton') '3×2频道面板缺少分页按钮。'
Assert-UiChannels ($bridgeSource -match '\$pagePreviousButton\.Add_Click\(\{ Set-UiChannelPage -Delta -1 \}\)' -and
    $bridgeSource -match '\$pageNextButton\.Add_Click\(\{ Set-UiChannelPage -Delta 1 \}\)') '分页按钮没有绑定到对应的翻页动作。'
Assert-UiChannels ($bridgeSource -match '(?s)if \(-not \$script:isolatedUiMode\)\s*\{\s*if \(\$script:serialConnectCatAfterCoreReady\)\s*\{\s*\[void\]\(Connect-UiRadioCatSession\)\s*\$script:serialConnectCatAfterCoreReady = \$false\s*\}\s*elseif \(-not \$NoAutoConnect\)\s*\{\s*\[void\]\(Connect-UiRadioCatSession -Automatic\)\s*\}\s*\}' -and
    $radioCatSource -match '(?s)if \(\$Automatic -and \$script:NoAutoConnect\) \{ return \$false \}') `
    '串口组合启动没有区分用户显式连接与自动 CAT 连接，或 NoAutoConnect 未阻止自动连接。'
Assert-UiChannels ($bridgeSource -match '(?s)function Start-BridgeRun\s*\{\s*param\(\[switch\]\$BmStartDisconnected\)\s*\$script:bmStartDisconnectedForRun = \[bool\]\$BmStartDisconnected\s*if \(Test-UiRadioCatUserActionBusy\)' -and
    $bridgeSource -match '(?s)function Complete-BridgePreparation\s*\{.*?if \(Test-UiRadioCatUserActionBusy\)') '直接和准备完成的 HRI 启动路径没有检查 CAT 用户动作。'
Assert-UiChannels ($bridgeSource -match '(?s)function Start-BridgeRun\s*\{.*?Get-UiRadioCatPortConflictMessage -HriPortName \$savedHriPort' -and
    $bridgeSource -match '(?s)function Complete-BridgePreparation\s*\{.*?Get-UiRadioCatPortConflictMessage -HriPortName \$preparedRadioPort.*?\.Start\(') `
    'Wires-X 启动前与设备预检完成后没有按各自 HRI 串口检查 CAT 冲突。'
Assert-UiChannels ($mainXaml -notmatch 'BmStaticGroupSlotBox|Content="TS1"|Content="TS2"') 'BM静态组仍定义时隙选择器。'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-ui-channels-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testRoot)
$script:portableConfigPath = Join-Path $testRoot 'config.json'
$script:portableConfigDirectory = $testRoot
$script:mainXamlPath = $mainXamlPath
$script:settingsXamlPath = $settingsXamlPath
$script:mainWindow = $null; $script:settingsWindow = $null
$script:profilePath = ''
$script:bmServerSelectionPreferenceId = 'bm-china-4602'
$script:channels = @(); $script:txChannelKey = ''; $script:mutedChannelKeys = @{}
$script:channelPageIndex = 0; $script:channelEditorSlot=[uint64]2
$script:channelPresetId=''; $script:channelPresetKind=''; $script:channelAutoKind=''; $script:channelKindExplicit=$false; $script:loadingChannelPreset=$false
$script:pendingRoutingMutation = $null; $script:pendingChannelMutation = $null; $script:pendingChannelStopMutation = $null
$script:channelMutationSafetyStopPending = $false
$script:routingMutationFence = $false; $script:activeRouting = $null; $script:activeProfile = $null; $script:storedProfile = $null
$script:supervisor = $null; $script:controlConfirmed = $false; $script:routingCapabilities = $false
$script:pendingControlRequests = @{}; $script:timedOutRoutingMutations = @{}; $script:resolvedTimedOutRoutingRequests = @{}
$script:pendingRoutingStatusRequestId = ''; $script:pendingStatusRequestId = ''; $script:pendingQuickCall = $null
$script:controlRunId=''; $script:controlLastSequence=[uint64]0; $script:channelActivationState=New-WirexChannelActivationState
$script:expiredQuickCallRequests=@{}; $script:quickCallDiagnosticPath=Join-Path $testRoot 'quick-call-requests.jsonl'
$script:controlDiagnostic=$false; $script:isolatedUiMode=$true
$script:pendingDynamicCallTarget = $null; $script:stopTask = $null; $script:statusStream = $null
$script:nativeExitCleanupPending = $false; $script:nativeExitCleanupStarted = $false
$script:radioModeApplyAfterStop = $null; $script:radioModePreviousHriPortName = ''; $script:closingAfterStop = $false; $script:reconnectAfterStop = $false
$script:sessionTempDirectory = ''; $script:sessionPasswordPath = ''; $script:latestStatus = $null
$script:quickCallCapabilities = $false
$script:RoutingDiagnostic = $false; $script:RoutingDiagnosticAutoTest = $false
$script:uiTestHooks = @{}
$script:bmApiKeySettingsUri = 'https://brandmeister.network/#/profile/api'
$script:bmPasswordSettingsUri = 'https://brandmeister.network/#/selfcare'
$script:bmProfileUriTemplate = 'https://brandmeister.network/#/profile/{0}'
$script:lastStatusUtc = [DateTime]::MinValue; $script:radioCatOperationPowerShell = $null
$script:radioCatPowerPreferenceDirty = $false; $script:radioCatPowerNeedsUserChoice = $false
$script:radioCatEditDraft = @{ mode=$null; frequency=$null; power=$null }
$script:radioCatObserved = $null; $script:radioCatResult = $null; $script:radioCatLastOperationStatus = ''
$script:deviceCatalog = $null; $script:activeHriPortName = ''; $script:preparationStarted = $false; $script:prepareStopAsync = $null
$script:maxWindowWidth = 1280; $script:maxWindowHeight = 900
$script:callIdentityCache = @{}; $script:identityQuery = $null; $script:identityNativeInFlight = $null
$script:identityFailureCooldown = @{}; $script:identityNativeQueue = New-Object 'System.Collections.Generic.List[object]'
$script:radioCatPollingActive = $false; $script:radioCatControllerInitialized = $false; $script:radioCatModuleAvailable = $true
$script:radioCatLinkState = 'unknown'; $script:radioCatProgrammaticControlUpdate = $false
$script:radioCatPortSelectionExplicit = $false; $script:radioCatPortTextEditExplicit = $false; $script:radioCatDeviceCatalogSignature = ''
$script:testCatControlsUpdated = 0
$script:allTestSupervisors = New-Object 'System.Collections.Generic.List[object]'
$rootConfigPath = Join-Path $repoRoot 'config.json'
$rootConfigExistedBefore = [System.IO.File]::Exists($rootConfigPath)
$rootConfigHashBefore = ''
if ($rootConfigExistedBefore) {
    $rootConfigHashBefore = Get-TestFileHash -Path $rootConfigPath
}

# RoutingDiagnostic uses PortableDirectory only as a forbidden-root comparison. All paths and canaries below are synthetic.
$diagnosticRoot = Join-Path $testRoot 'routing-isolation'
$diagnosticRuntimeRoot = Join-Path $diagnosticRoot 'runtime'
$diagnosticPortableRoot = Join-Path $diagnosticRoot 'portable'
$diagnosticExternalRoot = Join-Path $diagnosticRoot 'external-fixture'
[void][System.IO.Directory]::CreateDirectory($diagnosticRuntimeRoot)
[void][System.IO.Directory]::CreateDirectory($diagnosticPortableRoot)
[void][System.IO.Directory]::CreateDirectory($diagnosticExternalRoot)
$diagnosticPortableConfig = Join-Path $diagnosticPortableRoot 'config.json'
$diagnosticRuntimeConfig = Join-Path $diagnosticRuntimeRoot 'config.json'
$diagnosticPortableSentinel = '{ invalid portable config fixture'
$diagnosticRuntimeSentinel = '{ invalid runtime config fixture'
[System.IO.File]::WriteAllText($diagnosticPortableConfig,$diagnosticPortableSentinel,[System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($diagnosticRuntimeConfig,$diagnosticRuntimeSentinel,[System.Text.Encoding]::UTF8)
$diagnosticPortableHashBefore = Get-TestFileHash -Path $diagnosticPortableConfig
$diagnosticRuntimeHashBefore = Get-TestFileHash -Path $diagnosticRuntimeConfig
$diagnosticMarker = [pscustomobject][ordered]@{
    schema_version=1; purpose='wirex-routing-diagnostic-test'; fixture_id=[guid]::NewGuid().ToString('N'); source_id=1
}
[System.IO.File]::WriteAllText((Join-Path $diagnosticExternalRoot 'routing-diagnostic-fixture.json'),
    (ConvertTo-Json -InputObject $diagnosticMarker -Compress),(New-Object System.Text.UTF8Encoding($false)))
$acceptedDiagnosticPath = Test-UiRoutingDiagnosticConfigDirectory -Directory $diagnosticExternalRoot `
    -PackageRoot $diagnosticRuntimeRoot -PortableRoot $diagnosticPortableRoot -RequireFixture
Assert-UiChannels ([string]::Equals($acceptedDiagnosticPath,[System.IO.Path]::GetFullPath($diagnosticExternalRoot),[StringComparison]::OrdinalIgnoreCase)) `
    '绝对路径外部隔离目录和有效 fixture marker 被拒绝。'
$relativeDiagnosticRejected = $false
try { [void](Test-UiRoutingDiagnosticConfigDirectory -Directory 'relative-diagnostic-fixture' -PackageRoot $diagnosticRuntimeRoot -PortableRoot $diagnosticPortableRoot) }
catch { $relativeDiagnosticRejected = ($_.Exception.Message -match '绝对路径') }
Assert-UiChannels $relativeDiagnosticRejected '路由诊断接受了相对 UserConfigDirectory。'
$forbiddenDiagnosticPaths = @(
    [pscustomobject]@{ path=$diagnosticPortableRoot; label='PortableDirectory 本身' },
    [pscustomobject]@{ path=(Join-Path $diagnosticPortableRoot 'private\user-config'); label='PortableDirectory 子目录' },
    [pscustomobject]@{ path=$diagnosticRuntimeRoot; label='PackageDirectory/runtime 本身' },
    [pscustomobject]@{ path=(Join-Path $diagnosticRuntimeRoot 'private\user-config\nested'); label='runtime 子目录' }
)
foreach ($forbiddenPath in $forbiddenDiagnosticPaths) {
    $diagnosticRejected = $false
    $diagnosticError = ''
    try {
        [void](Test-UiRoutingDiagnosticConfigDirectory -Directory $forbiddenPath.path -PackageRoot $diagnosticRuntimeRoot `
            -PortableRoot $diagnosticPortableRoot -RequireFixture)
    } catch { $diagnosticError = [string]$_.Exception.Message; $diagnosticRejected = ($diagnosticError -match '不能等于或位于') }
    Assert-UiChannels ($diagnosticRejected -and $diagnosticError -notmatch 'routing-diagnostic-fixture\.json') `
        ('诊断隔离未在 fixture 检查前拒绝 {0}，错误={1}' -f $forbiddenPath.label,$diagnosticError)
}
Assert-UiChannels ((Get-TestFileHash -Path $diagnosticPortableConfig) -ceq $diagnosticPortableHashBefore -and
    (Get-TestFileHash -Path $diagnosticRuntimeConfig) -ceq $diagnosticRuntimeHashBefore) `
    '诊断拒绝路径探测改写了 synthetic portable/runtime config canary。'

# Offline stubs keep the actual channel functions and WPF callbacks under test without starting external services.
function Update-UiRadioCatControls { $script:testCatControlsUpdated++ }
function Format-ProfileTarget { param([object]$Profile) return 'TG 91' }
function Set-MainTargetSummary { param([object]$Profile,[string]$OverallLabel) return }
function Invoke-UiRadioCatPollTick { return $false }
function Complete-UiRadioCatOperationAndPersist { return $false }
function Complete-UiRadioCatOperation { return $false }
function Stop-UiRadioCatPolling { param([string]$Reason='') return $false }
function Read-StatusUpdates { return }
function Set-StaleDisplay { return }
function Complete-UiDeviceDiscovery { return $false }
function Complete-BridgePreparation { return $false }
function Complete-UiIdentityQuery { return }
function Expire-UiNativeIdentityUpdate { return $false }
function Clear-UiSessionTemp { $script:sessionPasswordPath=''; return $true }
function Update-UiIdentityActionState { return }
function Update-UiReceiveMetricsDisplay { param([object]$Record=$null) return }
function Set-UiIdentityRowVisibility { param([string]$Row,[System.Windows.Visibility]$Visibility) return }
function Update-UiPlaybackGainDisplay { param([object]$Record=$null) return }
function Format-BridgeGain { param([uint32]$GainMilli) return ([double]$GainMilli / 1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture) }
function Update-DynamicGroupControls { return }
function ConvertFrom-UiControlFrame { param([string]$Json,[string]$LockedRunId,[uint64]$LastControlSequence,[int]$ExpectedProcessId) return $script:testControlRecord }
function Set-OfflineDisplay { param([string]$Reason='') return }

try {
    $script:portableConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
    $script:portableConfig.connection.callsign = 'N0TEST'
    $script:portableConfig.connection.gateway_id = [uint64]12345
    $script:portableConfig.connection.source_id = [uint64]123456
    $script:portableConfig.connection.color_code = [uint64]7
    $script:portableConfig.connection.password = 'synthetic-password-7a91'
    $script:portableConfig.connection.api_key = 'synthetic-api-key-42bf'
    $script:portableConfig.channels = [object[]]@()
    $script:portableConfig.tx_channel_id = ''
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    [void](Set-UiGatewayIdentityState -Config $script:portableConfig)
    $script:channels = @($script:portableConfig.channels)
    $script:txChannelKey = [string]$script:portableConfig.tx_channel_id

    $script:mainWindow = Open-TestMainWindow
    $script:openedSetupUris = New-Object 'System.Collections.Generic.List[string]'
    $script:uiTestHooks.OpenUri = { param($Uri) $script:openedSetupUris.Add([string]$Uri) }
    Register-UiSetupLinks
    foreach ($linkSpec in @(
        [pscustomobject]@{ Name='BmApiKeySetupLink'; Kind='bm_api_key'; Uri='https://brandmeister.network/#/profile/api' },
        [pscustomobject]@{ Name='BmPasswordSetupLink'; Kind='bm_password'; Uri='https://brandmeister.network/#/selfcare' }
    )) {
        $setupLink = $script:mainWindow.FindName($linkSpec.Name)
        Assert-UiChannels ($setupLink -is [System.Windows.Documents.Hyperlink] -and [string]$setupLink.Tag -ceq $linkSpec.Kind) `
            ("{0} 没有绑定正确的设置入口。" -f $linkSpec.Name)
        $linkEvent = [System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent)
        $setupLink.RaiseEvent($linkEvent)
    }
    Assert-UiChannels ($script:openedSetupUris.Count -eq 2 -and
        $script:openedSetupUris[0] -ceq 'https://brandmeister.network/#/profile/api' -and
        $script:openedSetupUris[1] -ceq 'https://brandmeister.network/#/selfcare') '设置链接没有把官方 HTTPS 地址交给隔离浏览器钩子。'
    $script:uiTestHooks.Remove('OpenUri')
    $script:supervisor = New-TestChannelSupervisor
    Set-ConnectionConfigLocked
    Assert-UiChannels ((Get-TestUiControl 'BmApiKeyBox').IsEnabled -and
        -not (Get-TestUiControl 'PasswordBox').IsEnabled -and (Get-TestUiControl 'SaveSettingsButton').IsEnabled -and
        $script:mainWindow.FindName('BmApiKeySetupLink').IsEnabled -and $script:mainWindow.FindName('BmPasswordSetupLink').IsEnabled -and
        -not (Get-TestUiControl 'CatPortBox').IsEnabled -and -not (Get-TestUiControl 'CatBaudRateBox').IsEnabled) `
        '核心占用期间 API Key 或保存入口被锁定，或串口设备仍可编辑，或BM连接配置状态错误。'
    $script:bmConnectionNativeCapability=$true
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false; revision=[uint64]0; transport_open=$false; resolving=$false; error='none'; bm_state='stopped'
    }
    Set-ConnectionConfigLocked
    Assert-UiChannels ((Get-TestUiControl 'BmApiKeyBox').IsEnabled -and
        (Get-TestUiControl 'MasterBox').IsEnabled -and (Get-TestUiControl 'PasswordBox').IsEnabled -and
        -not (Get-TestUiControl 'CatPortBox').IsEnabled -and -not (Get-TestUiControl 'WaveInEndpointBox').IsEnabled) `
        '串口已连接而BM暂停时，BM传输配置/API Key未解锁，或HRI占用的串口/音频字段被错误解锁。'
    $script:bmConnectionNativeCapability=$false; $script:bmConnectionSnapshot=$null
    $script:supervisor = $null
    $script:channelEditorSlot = 2
    $script:channels = @()
    $script:txChannelKey = ''
    $script:mutedChannelKeys = @{}
    $kindBox = Get-TestUiControl 'ChannelKindBox'
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq 'group' })[0]
    $channelIdBox = Get-TestUiControl 'ChannelIdBox'
    $privatePreset = @($channelIdBox.Items | Where-Object { $_.Tag -and [uint64]$_.Tag.id -eq 460997 }) | Select-Object -First 1
    $channelIdBox.SelectedItem = $privatePreset
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Assert-UiChannels ($channelIdBox.Text -ceq '460997' -and $privatePreset.Tag.kind -ceq 'private' -and
        $privatePreset.Tag.name -ceq '中国鹦鹉' -and [string]$kindBox.SelectedItem.Tag -ceq 'private' -and
        (Get-UiSelectedChannelPreset -Combo $channelIdBox).id -eq 460997) '选择中文单呼预设后，纯ID/类型/name元数据没有保留。'
    (Get-TestUiControl 'AddChannelButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-UiChannels ($script:channels.Count -eq 1 -and (Get-UiChannelKey -Channel $script:channels[0]) -ceq 'private:460997:2' -and
        $script:txChannelKey -ceq 'private:460997:2') '点击加入中文单呼预设后没有从Tag安全读取ID/kind，或没有初始化首个PTT目标。'
    $groupPreset = @($channelIdBox.Items | Where-Object { $_.Tag -and [uint64]$_.Tag.id -eq 46001 }) | Select-Object -First 1
    $channelIdBox.SelectedItem = $groupPreset
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Assert-UiChannels ($channelIdBox.Text -ceq '46001' -and [string]$kindBox.SelectedItem.Tag -ceq 'group' -and
        $groupPreset.Tag.kind -ceq 'group' -and $groupPreset.Tag.name -ceq '全国') '选择全国组呼预设后，纯ID/类型/名称元数据不正确。'
    (Get-TestUiControl 'AddChannelButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-UiChannels ($script:channels.Count -eq 2 -and $script:txChannelKey -ceq 'private:460997:2' -and
        (Get-UiChannelKey -Channel $script:channels[1]) -ceq 'group:46001:2') '加入第二个预设频道时更改了已有PTT目标。'
    $worldPreset = @($channelIdBox.Items | Where-Object { $_.Tag -and [uint64]$_.Tag.id -eq 91 }) | Select-Object -First 1
    $channelIdBox.SelectedItem = $worldPreset
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Assert-UiChannels ($channelIdBox.Text -ceq '91' -and $worldPreset.Tag.name -ceq 'World-wide' -and
        [string]$kindBox.SelectedItem.Tag -ceq 'group') 'World-wide组呼预设没有以纯ID和已知名称呈现。'
    $channelIdBox.SelectedIndex = -1
    $channelIdBox.Text = '765430'
    Assert-UiChannels ($channelIdBox.Text -ceq '765430' -and [string]$kindBox.SelectedItem.Tag -ceq 'unknown' -and
        $null -eq (Get-UiSelectedChannelPreset -Combo $channelIdBox)) '从预设改为手输 ID 后没有清除自动带入的类型。'
    (Get-TestUiControl 'AddChannelButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-UiChannels ($script:channels.Count -eq 2 -and $script:txChannelKey -ceq 'private:460997:2') `
        '从私呼预设改为手输 ID 后，自动填入的单呼类型没有清空为未选择。'
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq 'private' })[0]
    $channelIdBox.Text = '765432'
    Assert-UiChannels ($channelIdBox.Text -ceq '765432' -and [string]$kindBox.SelectedItem.Tag -ceq 'private' -and
        [bool]$script:channelKindExplicit) '用户明确选单呼类型后手动输入没有保留该类型。'
    (Get-TestUiControl 'AddChannelButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-UiChannels ($script:channels.Count -eq 3 -and (Get-UiChannelKey -Channel $script:channels[2]) -ceq 'private:765432:2' -and
        $script:txChannelKey -ceq 'private:460997:2') '手输频道没有保留明确类型，或更改了已有PTT目标。'
    $script:channels = @(); $script:txChannelKey = ''
    $script:portableConfig.channels = [object[]]@(); $script:portableConfig.tx_channel_id = ''
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq 'group' })[0]
    $channelIdBox.SelectedIndex = -1; $channelIdBox.Text = '12345'
    $script:channelKindExplicit = $false
    Add-UiChannelFromInputs
    Assert-UiChannels ($script:channels.Count -eq 1 -and (Get-UiChannelKey -Channel $script:channels[0]) -ceq 'group:12345:2') '新频道没有使用内部默认网络参数。'
    Assert-UiChannels ($script:txChannelKey -ceq 'group:12345:2') '空列表加入首频道后没有将首项设为默认 PTT 目标。'
    Assert-UiChannels ((Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:12345:2') '首次频道和默认 PTT 目标没有保存到临时根目录 config.json。'
    $emptyKeyConfig = $script:portableConfig.PSObject.Copy()
    $emptyKeyConfig.connection = $script:portableConfig.connection.PSObject.Copy()
    $emptyKeyConfig.connection.api_key = ''
    Assert-UiChannels ($null -ne (ConvertFrom-UiPortableConfigToProfile -Config $emptyKeyConfig)) 'BM API Key 为空时连接 Profile 被拒绝。'

    $priorTxAfterAdd = [string]$script:txChannelKey
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq 'group' })[0]
    (Get-TestUiControl 'ChannelIdBox').Text = '23456'
    Add-UiChannelFromInputs
    Assert-UiChannels ($script:channels.Count -eq 2 -and $script:txChannelKey -ceq $priorTxAfterAdd -and
        (Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq $priorTxAfterAdd) `
        '已有呼叫目标时，加入监听频道改动了 PTT 目标或没有保存新频道。'
    Assert-UiChannels ((Get-WirexPortableConfig -Path $script:portableConfigPath).connection.color_code -eq 7) `
        '保存其他配置时色码字段被归零、删除或改写。'

    $script:channels = @()
    $sameGroupTs2 = New-UiChannelRecord -Id 12345 -Kind group -Slot 2
    $sameGroupTs1 = New-UiChannelRecord -Id 12345 -Kind group -Slot 1
    $samePrivateTs1 = New-UiChannelRecord -Id 12345 -Kind private -Slot 1
    Assert-UiChannels ((Get-UiChannelKey -Channel $sameGroupTs2) -cne (Get-UiChannelKey -Channel $samePrivateTs1)) 'kind/slot 没有参与频道元组 key。'
    Assert-UiChannels ((Get-UiChannelKey -Channel $sameGroupTs2) -ceq 'group:12345:2' -and
        (Get-UiChannelKey -Channel $samePrivateTs1) -ceq 'private:12345:1') '同 ID 的不同 kind/slot 被混为一个频道。'
    $script:channels = @($script:channels) + @($sameGroupTs2,$samePrivateTs1,
        (New-UiChannelRecord -Id 91 -Kind group -Slot 2),(New-UiChannelRecord -Id 46001 -Kind group -Slot 2),$sameGroupTs1)
    $script:txChannelKey = 'group:91:2'
    $script:portableConfig.channels = [object[]]$script:channels
    $script:portableConfig.tx_channel_id = $script:txChannelKey
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    Assert-UiChannels ($script:channels.Count -eq 5 -and (Get-UiChannelKey -Channel $script:channels[0]) -ceq 'group:12345:2' -and
        (Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:91:2') '频道顺序或 91 PTT 目标未保存。'
    Update-UiChannelDisplays
    $targetCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'group:46001:2' }) | Select-Object -First 1
    $targetButton = @($targetCard.Child.Children[2].Children | Where-Object { $_ -is [System.Windows.Controls.Button] -and [string]$_.Tag.action -ceq 'tx' }) | Select-Object -First 1
    Assert-UiChannels ($targetButton -and $targetButton.Content -ceq '设为呼叫' -and $targetButton.IsEnabled) `
        ('频道卡没有给未选频道显示可用的“设为呼叫”按钮。 button={0}/{1}, cards={2}, pending={3}/{4}/{5}/{6}, core={7}' -f `
            [string]$targetButton.Content,[bool]$targetButton.IsEnabled,$script:mainWindow.FindName('ChannelCardsPanel').Children.Count,
            [bool]$script:pendingRoutingMutation,[bool]$script:pendingChannelMutation,[bool]$script:pendingChannelStopMutation,[bool]$script:routingMutationFence,[bool]$script:supervisor)
    $targetClick = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
    $targetButton.RaiseEvent($targetClick)
    Assert-UiChannels ($script:txChannelKey -ceq 'group:46001:2' -and
        (Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:46001:2' -and
        $null -eq $script:pendingQuickCall -and -not $script:supervisor) '卡片按钮没有只选择下次呼叫目标，或误发了核心/呼叫命令。'
    $selectedCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'group:46001:2' }) | Select-Object -First 1
    $selectedTargetButton = @($selectedCard.Child.Children[2].Children | Where-Object { $_ -is [System.Windows.Controls.Button] -and [string]$_.Tag.action -ceq 'tx' }) | Select-Object -First 1
    Assert-UiChannels ($selectedTargetButton.Content -ceq '呼叫目标' -and -not $selectedTargetButton.IsEnabled) '选中频道卡没有显示已选呼叫目标状态。'
    $restoreTargetCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'group:91:2' }) | Select-Object -First 1
    $restoreTargetButton = @($restoreTargetCard.Child.Children[2].Children | Where-Object { $_ -is [System.Windows.Controls.Button] -and [string]$_.Tag.action -ceq 'tx' }) | Select-Object -First 1
    $restoreTargetButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-UiChannels ($script:txChannelKey -ceq 'group:91:2') '卡片按钮不能在频道之间切换下次呼叫目标。'

    $script:portableConfig.connection.source_id = [uint64]123456
    $script:portableConfig.routing.blocked_source_ids = [uint64[]]@(7654321)
    $groupPolicy = Get-UiNativeRxPolicyForChannels -Channels @($script:channels | Where-Object { $_.kind -ceq 'group' })
    $privatePolicy = Get-UiNativeRxPolicyForChannels -Channels @($script:channels | Where-Object { $_.kind -ceq 'private' })
    Assert-UiChannels ($groupPolicy.group_mode -ceq 'selected' -and @($groupPolicy.allow_groups | Where-Object { $_.destination_id -eq 91 -and $_.slot -eq 2 }).Count -eq 1) '组呼 RX 策略没有按 destination ID 和 slot 派生。'
    Assert-UiChannels ($privatePolicy.private_mode -ceq 'selected_peers' -and @($privatePolicy.allow_private_peers | Where-Object { $_.source_id -eq 12345 -and $_.local_destination_id -eq 123456 -and $_.slot -eq 1 }).Count -eq 1) '私呼 RX 策略没有按 source ID、本机 destination 和 slot 派生。'
    Assert-UiChannels (@($groupPolicy.blocked_source_ids) -contains [uint64]7654321) '来源屏蔽列表未进入派生 RX 策略。'

    $script:supervisor = New-TestChannelSupervisor
    $script:controlConfirmed = $true
    $script:routingCapabilities = $true
    $script:controlRunId='4242-1730592000123'
    $script:channelActivationState=New-WirexChannelActivationState
    Reset-WirexChannelActivationState -State $script:channelActivationState -RunId $script:controlRunId | Out-Null
    $script:pendingControlRequests=@{}
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]5; tx_policy_revision=[uint64]7
        tx_target=[pscustomobject]@{destination_id=[uint64]91;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$groupPolicy; transmit_enabled=$true
    }
    $script:txChannelKey = 'group:91:2'
    $script:channels = @($script:channels)
    $script:quickCallCapabilities = $true
    $script:latestStatus = [pscustomobject]@{ run_id=$script:controlRunId;bm_state='ready' }
    Update-UiChannelDisplays
    $commandCountBeforeQuickCall = $script:supervisor.Commands.Count
    $groupCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'group:91:2' }) | Select-Object -First 1
    $quickCallButton = @($groupCard.Child.Children[2].Children | Where-Object { $_ -is [System.Windows.Controls.Button] -and [string]$_.Tag.action -ceq 'quick_call' }) | Select-Object -First 1
    Assert-UiChannels ($quickCallButton -and $quickCallButton.Content -ceq '激活组' -and $quickCallButton.IsEnabled) '组呼频道没有直接显示可用的激活组按钮。'
    Invoke-UiRoutingDiagnosticChannelQuickCallButton -Channel ($script:channels | Where-Object {
        (Get-UiChannelKey -Channel $_) -ceq 'group:91:2'
    } | Select-Object -First 1)
    Assert-UiChannels ($script:supervisor.Commands.Count -eq ($commandCountBeforeQuickCall + 1) -and
        $script:supervisor.Commands[-1].command -ceq 'network_subscription.quick_call_join' -and
        $script:pendingQuickCall -and $script:txChannelKey -ceq 'group:91:2') '组呼卡的直接按钮没有通过真实事件触发动态组激活。'
    $privateCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'private:12345:1' }) | Select-Object -First 1
    $privateActions = $privateCard.Child.Children[2]
    Assert-UiChannels ($privateActions.Children.Count -eq 4 -and
        @($privateActions.Children | Where-Object { $_ -is [System.Windows.Controls.Button] }).Count -eq 3) '私呼卡第四个操作格没有留空。'
    $script:pendingQuickCall = $null
    $script:pendingControlRequests = @{}
    Reset-WirexChannelActivationState -State $script:channelActivationState -RunId $script:controlRunId | Out-Null
    $beforeMute = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    Set-UiChannelMuted -Channel ($script:channels | Where-Object { $_.kind -ceq 'private' } | Select-Object -First 1)
    Assert-UiChannels ($script:pendingRoutingMutation.command -ceq 'rx_policy.replace' -and
        $script:pendingChannelMutation -and $script:channels.Count -eq 5 -and $script:txChannelKey -ceq 'group:91:2') `
        ('RX 活跃时屏蔽频道未提交 RX 更新，或提前更改列表/PTT。 pending={0}, channelPending={1}, count={2}, tx={3}, status={4}' -f `
            $(if ($script:pendingRoutingMutation) { $script:pendingRoutingMutation.command } else { '<null>' }),[bool]$script:pendingChannelMutation,
            $script:channels.Count,$script:txChannelKey,(Get-TestUiControl 'TransientStatusText').Text)
    Assert-UiChannels ([System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $beforeMute) '收到核心确认前就把屏蔽状态写入 config.json。'
    $muteCommand = $script:supervisor.Commands[$script:supervisor.Commands.Count - 1]
    Assert-UiChannels ($muteCommand.command -ceq 'rx_policy.replace' -and $muteCommand.parameters_json -notmatch 'synthetic-password|synthetic-api-key') '屏蔽命令不是 RX 更新或把合成凭据送入核心命令。'
    $mutePolicy = Get-UiNativeRxPolicyForChannels -Channels $script:channels -MutedKeys $script:pendingChannelMutation.muted_keys
    Assert-UiChannels ($mutePolicy.allow_private_peers.Count -eq 0 -and $mutePolicy.allow_groups.Count -eq 4) '屏蔽频道后派生 RX 策略仍包含被屏蔽私呼。'
    $muteMutation = $script:pendingRoutingMutation
    $script:pendingRoutingMutation = $null
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]6; tx_policy_revision=[uint64]7
        tx_target=[pscustomobject]@{destination_id=[uint64]91;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$mutePolicy; transmit_enabled=$true
    }
    Assert-UiChannels (Complete-UiChannelMutation -Mutation $muteMutation -Routing $script:activeRouting) 'RX 屏蔽确认没有完成频道事务。'
    Assert-UiChannels ($script:txChannelKey -ceq 'group:91:2' -and $script:mutedChannelKeys.ContainsKey('private:12345:1')) 'RX ACK 后临时屏蔽未生效或意外改动 PTT 目标。'
    Assert-UiChannels ((Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:91:2') 'RX ACK 后保存改写了 TX 目标。'

    $script:mutedChannelKeys = @{}
    $script:channels = @($script:channels | Where-Object { (Get-UiChannelKey -Channel $_) -cne 'group:12345:1' })
    $script:txChannelKey = 'group:91:2'
    $script:activeRouting.tx_target = [pscustomobject]@{destination_id=[uint64]91;kind='group';slot=[uint64]2;transmit_enabled=$true}
    $script:activeRouting.media_owner = 'rx_active'
    $script:activeRouting.rx_policy_revision = [uint64]6
    $script:activeRouting.tx_policy_revision = [uint64]7
    $beforeRemoveTx = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    Remove-UiChannel -Channel ($script:channels | Where-Object { (Get-UiChannelKey -Channel $_) -ceq 'group:91:2' } | Select-Object -First 1)
    Assert-UiChannels ($script:pendingChannelMutation.stage -ceq 'tx' -and $script:pendingRoutingMutation.command -ceq 'tx_policy.replace' -and
        $script:pendingChannelMutation.tx_key -ceq 'group:12345:2' -and $script:channels.Count -eq 4) 'RX 活跃时移除当前 TX 频道没有先选择剩余列表首频道，或提前保存。'
    $txAck = $script:pendingRoutingMutation; $script:pendingRoutingMutation = $null
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]6; tx_policy_revision=[uint64]8
        tx_target=[pscustomobject]@{destination_id=[uint64]12345;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$groupPolicy; transmit_enabled=$true
    }
    Assert-UiChannels (Complete-UiChannelMutation -Mutation $txAck -Routing $script:activeRouting) 'TX ACK 后没有进入 RX 更新阶段。'
    Assert-UiChannels ($script:pendingChannelMutation.stage -ceq 'rx' -and $script:pendingRoutingMutation.command -ceq 'rx_policy.replace' -and
        $script:channels.Count -eq 4 -and [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $beforeRemoveTx) 'TX ACK 后未先更新 RX/提前持久化频道列表。'
    $rxAck = $script:pendingRoutingMutation; $script:pendingRoutingMutation = $null
    $remainingPolicy = Get-UiNativeRxPolicyForChannels -Channels $script:pendingChannelMutation.channels
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]7; tx_policy_revision=[uint64]8
        tx_target=[pscustomobject]@{destination_id=[uint64]12345;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$remainingPolicy; transmit_enabled=$true
    }
    Assert-UiChannels (Complete-UiChannelMutation -Mutation $rxAck -Routing $script:activeRouting) 'RX ACK 后没有完成移除频道事务。'
    Assert-UiChannels ($script:channels.Count -eq 3 -and $script:txChannelKey -ceq 'group:12345:2' -and
        (Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:12345:2') '最终 RX ACK 未保存剩余顺序和首项 TX。'

    # A TX ACK changes native state before the paired RX update. Send failure, NACK,
    # and timeout must all stop the session and preserve the last saved channel list.
    $script:controlRunId = 'synthetic-channel-run'; $script:controlLastSequence = [uint64]0; $script:controlOverflowHandled = $false
    $partialSetup = Start-TestPendingChannelRemoval -RejectRxSend
    $partialRxMutation = Complete-TestPendingTxAck
    $partialSupervisor = $script:supervisor
    $partialCommands = @($partialSupervisor.Commands | Select-Object -ExpandProperty command)
    Assert-UiChannels ($partialCommands[-2] -ceq 'tx_policy.replace' -and $partialCommands[-1] -ceq 'rx_policy.replace') '发送失败夹具没有真实走到 TX ACK 后的 RX 更新。'
    Assert-UiChannels ($partialSupervisor.StopCallCount -eq 1 -and $script:stopTask -and -not $script:stopTask.IsCompleted -and
        $script:channelMutationSafetyStopPending -and -not $script:closingAfterStop -and -not $script:reconnectAfterStop) 'RX 更新发送失败后没有停止核心并锁住连接，或错误地退出/自动重连。'
    Assert-UiChannels ($script:mainWindow.FindName('ConnectButton').IsEnabled -eq $false -and
        $script:mainWindow.FindName('CallsignBox').IsEnabled -eq $false) '核心停止确认前 UI 仍允许修改连接或发起操作。'
    Assert-UiChannels ($script:channels.Count -eq 2 -and $script:txChannelKey -ceq $partialSetup.tx_key -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $partialSetup.config_text) '部分应用故障提前更改频道/起呼目标，或覆写最后确认的 config.json。'
    $script:supervisor.ControlVersion = 2
    $script:testControlRecord = [pscustomobject]@{
        type='control_result'; control_seq=[uint64]1; request_id='synthetic-late-rx-ack'
        command='rx_policy.replace'; result='ok'; routing=$script:activeRouting
    }
    $script:supervisor.Events = @('synthetic-late-rx-ack')
    [void](Process-UiControlEvents)
    Assert-UiChannels ($script:channelMutationSafetyStopPending -and $script:supervisor.StopCallCount -eq 1 -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $partialSetup.config_text) '安全停机前收到的迟到 RX ACK 没有被忽略。'
    Complete-TestChannelSafetyStop
    Assert-UiChannels ($script:supervisor -eq $null -and $script:pendingChannelMutation -eq $null -and
        $script:pendingRoutingMutation -eq $null -and $script:timedOutRoutingMutations.Count -eq 0 -and
        $script:pendingControlRequests.Count -eq 0 -and $script:resolvedTimedOutRoutingRequests.Count -eq 0 -and
        -not $script:routingMutationFence -and -not $script:channelMutationSafetyStopPending -and -not $script:reconnectAfterStop -and
        $script:mainWindow.IsVisible) '发送失败停机后仍残留候选、超时 fence、待重连状态，或窗口意外退出。'
    Assert-UiChannels ([System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $partialSetup.config_text) '发送失败停机收尾保存了未确认候选配置。'

    $txNackSetup = Start-TestPendingChannelRemoval
    $script:supervisor.ControlVersion = 2
    $txNackMutation = $script:pendingRoutingMutation
    $script:testControlRecord = [pscustomobject]@{
        type='control_result'; control_seq=[uint64]1; request_id=[string]$txNackMutation.request_id
        command='tx_policy.replace'; result='rejected'; error='synthetic_rejected'
    }
    $script:supervisor.Events = @('synthetic-tx-nack')
    [void](Process-UiControlEvents)
    Assert-UiChannels ($script:supervisor.StopCallCount -eq 0 -and -not $script:channelMutationSafetyStopPending -and
        $script:pendingChannelMutation -eq $null -and $script:pendingRoutingMutation -eq $null -and
        $script:channels.Count -eq 2 -and $script:txChannelKey -ceq $txNackSetup.tx_key -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $txNackSetup.config_text) 'TX 更新明确遭拒时，界面应清候选并保留旧配置，不能错误停机。'

    $rxNackSetup = Start-TestPendingChannelRemoval
    $rxNackMutation = Complete-TestPendingTxAck
    $rxNackSupervisor = $script:supervisor
    $rxNackSupervisor.ControlVersion = 2
    $script:testControlRecord = [pscustomobject]@{
        type='control_result'; control_seq=[uint64]1; request_id=[string]$rxNackMutation.request_id
        command='rx_policy.replace'; result='rejected'; error='synthetic_rejected'
    }
    $rxNackSupervisor.Events = @('synthetic-rx-nack')
    [void](Process-UiControlEvents)
    Assert-UiChannels ($rxNackSupervisor.StopCallCount -eq 1 -and $script:channelMutationSafetyStopPending -and
        -not $script:closingAfterStop -and -not $script:reconnectAfterStop -and $script:pendingChannelMutation -eq $null -and
        $script:pendingRoutingMutation -eq $null -and $script:channels.Count -eq 2 -and $script:txChannelKey -ceq $rxNackSetup.tx_key -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $rxNackSetup.config_text) 'TX ACK 后 RX NACK 没有停止连接并保留旧频道/配置。'
    Complete-TestChannelSafetyStop
    Assert-UiChannels (-not $script:channelMutationSafetyStopPending -and -not $script:routingMutationFence -and
        $script:timedOutRoutingMutations.Count -eq 0 -and $script:pendingControlRequests.Count -eq 0 -and
        $script:resolvedTimedOutRoutingRequests.Count -eq 0 -and $script:mainWindow.IsVisible -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $rxNackSetup.config_text) 'RX NACK 停机后没有清状态、保留窗口或保持配置。'

    $rxTimeoutSetup = Start-TestPendingChannelRemoval
    $rxTimeoutMutation = Complete-TestPendingTxAck
    $rxTimeoutSupervisor = $script:supervisor
    $rxTimeoutSupervisor.ControlVersion = 2
    $rxTimeoutMutation.started_utc = [DateTime]::UtcNow.AddSeconds(-9)
    $script:pendingRoutingMutation = $rxTimeoutMutation
    [void](On-UiTimerTick)
    Assert-UiChannels ($rxTimeoutSupervisor.StopCallCount -eq 1 -and $script:channelMutationSafetyStopPending -and
        $script:stopTask -and -not $script:closingAfterStop -and -not $script:reconnectAfterStop -and
        $script:pendingChannelMutation -eq $null -and $script:pendingRoutingMutation -eq $null -and
        $script:channels.Count -eq 2 -and $script:txChannelKey -ceq $rxTimeoutSetup.tx_key -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $rxTimeoutSetup.config_text) 'TX ACK 后 RX timeout 没有停止连接并保留旧频道/配置。'
    Complete-TestChannelSafetyStop
    Assert-UiChannels (-not $script:channelMutationSafetyStopPending -and -not $script:routingMutationFence -and
        $script:timedOutRoutingMutations.Count -eq 0 -and $script:pendingControlRequests.Count -eq 0 -and
        $script:resolvedTimedOutRoutingRequests.Count -eq 0 -and $script:mainWindow.IsVisible -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $rxTimeoutSetup.config_text) 'RX timeout 停机后没有清状态、保留窗口或保持配置。'

    # A native process exit before the first channel ACK must run the real timer
    # finalizer, discard the candidate, and leave the old configuration editable.
    $exitBeforeAckSetup = Start-TestPendingChannelRemoval
    $exitSupervisor = $script:supervisor
    Assert-UiChannels ($script:pendingChannelMutation -and $script:pendingRoutingMutation.command -ceq 'tx_policy.replace') '退出夹具没有留下待确认的 TX 频道事务。'
    $exitSupervisor.HasExited = $true
    $script:stopTask = $null
    [void](On-UiTimerTick)
    Assert-UiChannels ($script:supervisor -eq $null -and $script:pendingChannelMutation -eq $null -and
        $script:pendingRoutingMutation -eq $null -and $script:timedOutRoutingMutations.Count -eq 0 -and
        -not $script:routingMutationFence -and -not $script:channelMutationSafetyStopPending -and
        $script:channels.Count -eq 2 -and $script:txChannelKey -ceq $exitBeforeAckSetup.tx_key -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $exitBeforeAckSetup.config_text) 'Native 在频道 ACK 前退出后，退出收尾没有清候选并保留原频道配置。'
    Assert-UiChannels ($script:mainWindow.FindName('ConnectButton').IsEnabled -and
        $script:mainWindow.FindName('CallsignBox').IsEnabled -and $script:mainWindow.FindName('ChannelIdBox').IsEnabled -and
        $script:mainWindow.FindName('ChannelKindBox').IsEnabled) 'Native 退出收尾后，配置或频道控件仍保持锁定。'
    $exitPolicy = Get-UiNativeRxPolicyForChannels -Channels $script:channels
    $script:supervisor = New-TestChannelSupervisor
    $script:controlConfirmed = $true; $script:routingCapabilities = $true
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]21; tx_policy_revision=[uint64]32
        tx_target=[pscustomobject]@{destination_id=[uint64]12345;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$exitPolicy; transmit_enabled=$true
    }
    Set-UiChannelMuted -Channel $script:channels[0]
    Assert-UiChannels ($script:pendingChannelMutation -and $script:pendingRoutingMutation.command -ceq 'rx_policy.replace' -and
        $script:supervisor.Commands[-1].command -ceq 'rx_policy.replace' -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $exitBeforeAckSetup.config_text) '退出后重新连接仍不能提交频道修改，或提前保存了未确认设置。'
    $script:pendingChannelMutation = $null; $script:pendingRoutingMutation = $null
    $script:pendingControlRequests = @{}; $script:supervisor = $null; $script:mutedChannelKeys = @{}

    $script:channels = @((New-UiChannelRecord -Id 12345 -Kind group -Slot 2))
    $script:txChannelKey = 'group:12345:2'; $script:mutedChannelKeys = @{}
    $script:portableConfig.channels = [object[]]$script:channels; $script:portableConfig.tx_channel_id = $script:txChannelKey
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    $script:activeRouting.tx_target = [pscustomobject]@{destination_id=[uint64]12345;kind='group';slot=[uint64]2;transmit_enabled=$true}
    $script:activeRouting.rx_policy_revision = [uint64]9; $script:activeRouting.tx_policy_revision = [uint64]10
    $beforeLast = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    $script:supervisor = New-TestChannelSupervisor -StopAlreadyComplete $true
    Remove-UiChannel -Channel $script:channels[0]
    Assert-UiChannels ($script:pendingChannelStopMutation -and $script:supervisor.StopCallCount -eq 1 -and $script:channels.Count -eq 1) '移除最后一个在线频道没有先要求停止核心。'
    Assert-UiChannels ([System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $beforeLast) '停止确认前已保存空频道列表。'
    $script:stopTask = $script:supervisor.StopSource.Task
    $stopResult = @(Complete-BridgeStop)
    Assert-UiChannels ($script:channels.Count -eq 1 -and -not $script:pendingChannelStopMutation -and
        [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $beforeLast) '核心未退出时移除最后频道没有保留频道和 config.json。'
    $lastStopSupervisor = $script:supervisor
    $script:supervisor.HasExited = $true
    $script:pendingChannelStopMutation = [pscustomobject]@{channels=@();tx_key='';action='remove_last_channel'}
    $script:stopTask = $script:supervisor.StopSource.Task
    $successfulStopOutput = @(Complete-BridgeStop)
    $emptySavedConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-UiChannels ($lastStopSupervisor.Disposed -and $script:supervisor -eq $null -and $script:channels.Count -eq 0 -and $script:txChannelKey -ceq '' -and
        $emptySavedConfig.channels.Count -eq 0 -and $emptySavedConfig.tx_channel_id -ceq '') '停止成功后移除最后一个频道没有保存空频道列表与空 TX key。'

    $script:supervisor = New-TestChannelSupervisor
    $script:controlConfirmed = $true; $script:routingCapabilities = $true
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]11; tx_policy_revision=[uint64]12
        tx_target=[pscustomobject]@{destination_id=[uint64]12345;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$remainingPolicy; transmit_enabled=$true
    }
    $script:pendingRoutingMutation = [pscustomobject]@{
        request_id='synthetic-timeout-request'; command='rx_policy.replace'; expected_revision=[uint64]11
        target=$null; started_utc=[DateTime]::UtcNow.AddSeconds(-9)
    }
    $script:pendingControlRequests = @{ 'synthetic-timeout-request'='rx_policy.replace' }
    $script:pendingRoutingStatusRequestId = ''
    $beforeTimeout = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    [void](On-UiTimerTick)
    Assert-UiChannels ($script:routingMutationFence -and $script:timedOutRoutingMutations.ContainsKey('synthetic-timeout-request') -and
        $script:pendingRoutingMutation -eq $null -and $script:supervisor.Commands[-1].command -ceq 'routing.status') '频道更新超时没有设置 fence 并刷新状态。'
    Assert-UiChannels ([System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8) -ceq $beforeTimeout) '频道更新超时后，未确认的设置被写入 config.json。'

    # WPF preview input must open the controls; the test never assigns IsDropDownOpen.
    [void]$script:mainWindow.Close()
    $script:mainWindow = Open-TestMainWindow
    $kindBox = Get-TestUiControl 'ChannelKindBox'
    Assert-UiChannels (-not $kindBox.IsEditable) '频道类型下拉框意外允许自由文本。'
    [void](Invoke-TestPreviewClick -Element $kindBox)
    Assert-UiChannels ($kindBox.IsDropDownOpen) '点击频道类型下拉框主体没有打开选项。'
    [void]$script:mainWindow.Close()

    $script:mainWindow = Open-TestMainWindow
    $catPort = Get-TestUiControl 'CatPortBox'
    $script:mainWindow.Opacity = 1
    [void]$script:mainWindow.Activate()
    (Get-TestUiControl 'CatOperatingPanel').Visibility = [System.Windows.Visibility]::Visible
    (Get-TestUiControl 'RadioCatPanel').Visibility = [System.Windows.Visibility]::Visible
    $script:mainWindow.UpdateLayout()
    Assert-UiChannels ($catPort.IsEditable) 'CAT 端口字段不再是可编辑组合框。'
    Register-UiRadioCatPortTextInput
    $editBox = $catPort.Template.FindName('PART_EditableTextBox',$catPort)
    Assert-UiChannels ($editBox -is [System.Windows.Controls.TextBox]) 'CAT 端口编辑区没有真实 TextBox。'
    Assert-UiChannels ($catPort.IsEditable -and $editBox.IsEnabled) 'CAT 可编辑文本区不可输入。'
    [void]$catPort.Focus(); [void]$editBox.Focus(); $editBox.SelectAll(); $editBox.Text = 'COM777'
    Assert-UiChannels ($script:radioCatPortTextEditExplicit -and $script:radioCatPortSelectionExplicit -and $catPort.Text -ceq 'COM777') `
        ('CAT 编辑区输入没有触发实际 TextChanged 选择状态。 edit={0}, explicit={1}, focused={2}/{3}, tag={4}, text={5}' -f `
            $script:radioCatPortTextEditExplicit,$script:radioCatPortSelectionExplicit,$editBox.IsFocused,$editBox.IsKeyboardFocusWithin,$editBox.Tag,$catPort.Text)
    [void]$script:mainWindow.Close()

    $script:mainWindow = Open-TestMainWindow
    $script:settingsWindow = Initialize-SettingsWindow
    $script:settingsWindow.Opacity = 1
    $script:settingsWindow.Show(); [void]$script:settingsWindow.Activate(); $script:settingsWindow.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Assert-UiChannels ($null -eq $script:settingsWindow.FindName('ChannelSlotBox')) '频道说明窗口仍显示时隙选择器。'

    $savedCallerChannels = @($script:channels); $savedCallerTxKey = $script:txChannelKey
    $savedCallerStatus = $script:latestStatus; $savedCallerCache = @{} + $script:callIdentityCache
    $script:channels = @((New-UiChannelRecord -Id 460997 -Kind private -Slot 2))
    $script:txChannelKey = ''
    $script:latestStatus = [pscustomobject]@{current_call_valid=$true;current_call_kind='P';current_call_slot=[uint64]2;
        current_call_source_id=[uint64]460997;current_call_destination_id=[uint64]123456}
    $script:callIdentityCache['460997'] = [pscustomobject]@{source_id=[uint32]460997;id=[uint32]460997;callsign='N0TEST';name='Sample Operator';status='found';display_name='N0TEST'}
    Update-UiChannelDisplays
    $callerCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'private:460997:2' }) | Select-Object -First 1
    $callerArea = $callerCard.Child.Children[1]
    Assert-UiChannels ($callerArea -is [System.Windows.Controls.Border] -and [string]$callerArea.Tag -ceq 'ChannelCallArea') '来话显示区域没有保留在卡片主体的第二项。'
    $callerVisualText = @(Get-UiVisualTextValues -Root $callerArea)
    Assert-UiChannels ($callerVisualText -contains 'N0TEST · Sample Operator' -and $callerVisualText -contains 'DMR ID 460997') '来话卡没有放大显示呼号/姓名并在下一行显示 DMR ID。'
    $callerIdText = @($callerArea.Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] }) | Select-Object -Last 1
    $callerIdLink = @($callerIdText.Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] }) | Select-Object -First 1
    Assert-UiChannels ($callerIdLink -and [string]$callerIdLink.Tag.callsign -ceq 'N0TEST') '已解析呼号时 DMR ID 没有连接到对应的 BM profile。'
    $script:openedProfileUris = New-Object 'System.Collections.Generic.List[string]'
    $savedIdentityModuleLoaded = $script:radioIdentityModuleLoaded
    $script:radioIdentityModuleLoaded = $true
    $script:uiTestHooks.OpenUri = { param($Uri) $script:openedProfileUris.Add([string]$Uri) }
    $callerIdLink.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent))
    Assert-UiChannels ($script:openedProfileUris.Count -eq 1 -and $script:openedProfileUris[0] -ceq 'https://brandmeister.network/#/profile/N0TEST') 'DMR ID 链接没有把已验证的呼号 profile URL 交给隔离打开器。'
    $script:uiTestHooks.Remove('OpenUri')
    $script:radioIdentityModuleLoaded = $savedIdentityModuleLoaded
    [void]$script:callIdentityCache.Remove('460997')
    Update-UiChannelDisplays
    $unknownCallerCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object { [string]$_.Tag.channel_key -ceq 'private:460997:2' }) | Select-Object -First 1
    $unknownCallerArea = $unknownCallerCard.Child.Children[1]
    Assert-UiChannels ($unknownCallerArea -is [System.Windows.Controls.Border] -and [string]$unknownCallerArea.Tag -ceq 'ChannelCallArea') '未知来话显示区域没有保留在卡片主体的第二项。'
    $unknownText = @(Get-UiVisualTextValues -Root $unknownCallerArea)
    Assert-UiChannels ($unknownText -contains 'DMR ID 460997' -and $unknownText.Count -eq 1 -and
        @($unknownCallerArea.Child.Children[0].Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] }).Count -eq 0) '未知呼号没有以单一 DMR ID 回退显示，或打开了未经验证的链接。'
    $script:channels = $savedCallerChannels; $script:txChannelKey = $savedCallerTxKey
    $script:latestStatus = $savedCallerStatus; $script:callIdentityCache = $savedCallerCache
    Update-UiChannelDisplays

    $savedPageChannels = @($script:channels); $savedPageTxKey = $script:txChannelKey
    $savedPageMuted = $script:mutedChannelKeys; $savedPageIndex = $script:channelPageIndex
    $script:channels = @((6000..6007 | ForEach-Object { New-UiChannelRecord -Id $_ -Kind group -Slot 2 }))
    $script:txChannelKey = 'group:6000:2'; $script:mutedChannelKeys = @{}; $script:channelPageIndex = 0
    Update-UiChannelDisplays
    Assert-UiChannels ($script:mainWindow.FindName('ChannelPageNav').IsVisible -and
        $script:mainWindow.FindName('ChannelPageText').Text -ceq '1 / 2' -and
        $script:mainWindow.FindName('ChannelCardsPanel').Children.Count -eq 6) '超过六个频道时第一页没有显示六个槽位和紧凑页码。'
    Set-UiChannelPage -Delta 1
    $pageTwoCards = @($script:mainWindow.FindName('ChannelCardsPanel').Children)
    Assert-UiChannels ($script:channelPageIndex -eq 1 -and $script:mainWindow.FindName('ChannelPageText').Text -ceq '2 / 2' -and
        @($pageTwoCards | Where-Object { -not $_.Tag.blank }).Count -eq 2 -and
        @($pageTwoCards | Where-Object { $_.Tag.blank }).Count -eq 4 -and $script:channels.Count -eq 8) '第二页没有保留剩余频道与四个纯空白槽。'
    Set-UiChannelPage -Delta -1
    Assert-UiChannels ($script:channelPageIndex -eq 0 -and $script:channels.Count -eq 8) '翻页返回时没有保留完整监听频道列表。'
    $script:channels = $savedPageChannels; $script:txChannelKey = $savedPageTxKey
    $script:mutedChannelKeys = $savedPageMuted; $script:channelPageIndex = $savedPageIndex
    Update-UiChannelDisplays

    $script:testBridgeRunRequests = 0
    function Start-BridgeRun { $script:testBridgeRunRequests++ }
    $script:radioCatOperationPowerShell = [pscustomobject]@{ fake_query=$true }
    $fakeCatQuery = $script:radioCatOperationPowerShell
    $script:radioCatOperationKind = 'query'
    $script:radioCatQueuedAction = $null
    $script:radioCatPendingModeFrequencyRequest = $null
    $script:radioModeApplyAfterStop = $null
    $script:radioCatSessionRequested = $true
    $script:radioCatSessionConnected = $true
    $script:radioCatPollingActive = $true
    $script:radioCatSessionState = 'polling'
    $script:radioCatSessionShutdown = $false
    $script:radioCatOperationCancelled = $false
    $script:supervisor = $null; $script:preparationStarted = $false; $script:preparePowerShell = $null
    (Get-TestUiControl 'CallsignBox').Text = 'N0TEST'
    (Get-TestUiControl 'SourceBox').Text = '123456'
    (Get-TestUiControl 'MasterBox').Text = '43.129.83.124'
    (Get-TestUiControl 'MasterPortBox').Text = '62031'
    (Get-TestUiControl 'DeviceNumberBox').Text = ''
    (Get-TestUiControl 'PasswordBox').Password = 'synthetic-password-7a91'
    (Get-TestUiControl 'BmApiKeyBox').Password = 'synthetic-api-key-42bf'
    Set-ConnectionButtonState
    Assert-UiChannels ((Get-TestUiControl 'ConnectButton').IsEnabled -and (Get-TestUiControl 'SaveSettingsButton').IsEnabled -and
        -not (Test-UiRadioCatUserActionBusy)) '普通 CAT 查询正在运行时连接或保存按钮被错误锁定。'
    $saveDuringQuery = [bool](Save-SettingsFromWindow)
    Assert-UiChannels ($saveDuringQuery -and [object]::ReferenceEquals($script:radioCatOperationPowerShell,$fakeCatQuery) -and
        -not $script:radioCatOperationCancelled) ('普通 CAT 查询期间保存设置失败，或保存操作取消了 CAT worker。 result={0}, busy={1}, workerSame={2}, cancelled={3}, footer={4}' -f `
            $saveDuringQuery,[bool](Test-UiRadioCatUserActionBusy),[object]::ReferenceEquals($script:radioCatOperationPowerShell,$fakeCatQuery),
            [bool]$script:radioCatOperationCancelled,[string](Get-TestUiControl 'TransientStatusText').Text)
    Request-Reconnect
    Assert-UiChannels ($script:testBridgeRunRequests -eq 1 -and [object]::ReferenceEquals($script:radioCatOperationPowerShell,$fakeCatQuery) -and
        -not $script:radioCatOperationCancelled) '普通 CAT 查询期间启动 Wires-X 被阻止，或连接流程取消了 CAT worker。'

    $script:radioCatOperationKind = 'setPower'
    Set-ConnectionButtonState
    $configBeforeCatWrite = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    $saveDuringCatWrite = Save-SettingsFromWindow
    Request-Reconnect
    $configAfterCatWrite = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    Assert-UiChannels (-not (Get-TestUiControl 'ConnectButton').IsEnabled -and -not (Get-TestUiControl 'SaveSettingsButton').IsEnabled -and
        -not $saveDuringCatWrite -and $configAfterCatWrite -ceq $configBeforeCatWrite -and $script:testBridgeRunRequests -eq 1 -and
        [object]::ReferenceEquals($script:radioCatOperationPowerShell,$fakeCatQuery)) 'CAT 写入期间新 Wires-X 启动/保存没有被暂时阻止，或 CAT worker 被改变。'
    $script:radioCatOperationPowerShell = $null; $script:radioCatOperationKind = ''
    $script:radioCatQueuedAction = $null; $script:radioCatPendingModeFrequencyRequest = $null; $script:radioModeApplyAfterStop = $null
    $script:radioCatSessionRequested = $false; $script:radioCatSessionConnected = $false; $script:radioCatPollingActive = $false
    $script:radioCatSessionState = 'disconnected'; $script:radioCatOperationCancelled = $false
    Set-ConnectionButtonState

    # Keep a fake CAT query in flight while the bridge checks the same saved
    # HRI port. The isolated hook sleeps without importing the hardware module.
    $script:NoAutoConnect = $true
    $script:UiTestFixture = $true
    $script:RoutingDiagnostic = $false
    $script:isolatedUiMode = $true
    $script:deviceCatalog = $null
    $script:radioCatModuleAvailable = $true
    $script:radioCatSessionRequested = $false
    $script:radioCatSessionConnected = $false
    $script:radioCatPollingActive = $false
    $script:radioCatSessionState = 'disconnected'
    $script:radioCatSessionShutdown = $false
    $script:radioCatSessionGeneration = 0
    $script:radioCatManualDisconnect = $false
    $script:radioCatOperationPowerShell = $null
    $script:radioCatOperationAsync = $null
    $script:radioCatOperationKind = ''
    $script:radioCatOperationPortName = ''
    $script:radioCatOperationCancelled = $false
    $script:radioCatQueuedAction = $null
    $script:radioCatPendingModeFrequencyRequest = $null
    $script:radioModeApplyAfterStop = $null
    $script:preparationStarted = $false
    $script:prepareStopAsync = $null
    $script:supervisor = $null
    $script:statusStream = $null
    $script:portableConfig = [pscustomobject]@{ fake_isolated_config=$true }
    $script:storedProfile = [pscustomobject]@{
        devices=[pscustomobject]@{ serial_port='COM5' }
        tx_target=[pscustomobject]@{ destination_id=[uint64]91; kind='group' }
        rx_policy=$null
    }
    $catPortControl = Get-TestUiControl 'CatPortBox'
    $catPortControl.SelectedItem = $null
    $catPortControl.Text = 'COM5'
    $script:radioCatPortSelectionExplicit = $true
    $script:radioCatPortTextEditExplicit = $true
    $catHookMarker = Join-Path $testRoot 'fake-cat-query-started.txt'
    $catHookText = @"
param([object]`$Context)
[System.IO.File]::WriteAllText('$catHookMarker','fake')
Start-Sleep -Seconds 30
return [pscustomobject]@{ operation='query'; status='cancelled'; port_name=[string]`$Context.port }
"@
    $script:uiTestHooks.CatOperation = [scriptblock]::Create($catHookText)
    $fakeCatQueryHook = $script:uiTestHooks.CatOperation
    Start-UiRadioCatOperation -Operation query
    $portGateCatWorker = $script:radioCatOperationPowerShell
    $catHookWait = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not [System.IO.File]::Exists($catHookMarker) -and $catHookWait.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 10 }
    $script:radioCatSessionRequested = $true
    $script:radioCatSessionState = 'polling'
    $script:radioCatPollingActive = $true
    $script:radioCatPollingConnectionKey = 'COM5|38400|Two'
    Assert-UiChannels ((Get-UiRadioCatSessionState).operation -ceq 'query' -and
        -not (Get-UiRadioCatSessionState).user_action_busy -and
        $script:radioCatOperationPowerShell -and $script:radioCatOperationPortName -ceq 'COM5' -and
        (Get-UiRadioCatSelectedPort) -ceq 'COM5' -and $script:deviceCatalog -eq $null -and $script:NoAutoConnect -and
        [System.IO.File]::Exists($catHookMarker)) `
        'NoAutoConnect/无设备目录下的手动 CAT COM5 fake query 未建立为独立会话。'
    $script:uiTestHooks.Remove('CatOperation')
    $script:portGateNativeFactoryCalls = 0
    $script:uiTestHooks.NativeSupervisorFactory = {
        param([object]$Context)
        $script:portGateNativeFactoryCalls++
        return [pscustomobject]@{ HasExited=$false; ProcessId=[uint32]8811; Operation=[string]$Context.operation }
    }
    Set-Item -Path Function:\Start-BridgeRun -Value $script:actualStartBridgeRun
    Start-BridgeRun
    $samePortFooter = [string](Get-TestUiControl 'TransientStatusText').Text
    Assert-UiChannels ($script:portGateNativeFactoryCalls -eq 0 -and $null -eq $script:supervisor -and
        [object]::ReferenceEquals($script:radioCatOperationPowerShell,$portGateCatWorker) -and
        $script:radioCatOperationPortName -ceq 'COM5' -and $samePortFooter -match 'COM5' -and $samePortFooter -match '断开 CAT') `
        ('同一 COM5 上的 CAT query 没有阻止 Wires-X 启动，或丢失了实际端口提示。 factory={0}, supervisor={1}, CAT={2}, footer={3}' -f `
            $script:portGateNativeFactoryCalls,[bool]$script:supervisor,[bool]$script:radioCatOperationPowerShell,$samePortFooter)

    # A disconnected session may still own a frozen operation port until the
    # fake worker releases. That port remains reserved for the final HRI check.
    $script:radioCatSessionRequested = $false
    $script:radioCatSessionConnected = $false
    $script:radioCatPollingActive = $false
    $script:radioCatSessionState = 'disconnecting'
    $script:radioCatManualDisconnect = $true
    Start-BridgeRun
    Assert-UiChannels ($script:portGateNativeFactoryCalls -eq 0 -and $null -eq $script:supervisor -and
        $script:radioCatOperationPowerShell -and $script:radioCatOperationPortName -ceq 'COM5' -and
        ([string](Get-TestUiControl 'TransientStatusText').Text) -match 'COM5') `
        'CAT 已断开但 worker 仍释放期间，Wires-X 未检查冻结的 COM5。'

    $script:storedProfile.devices.serial_port = 'COM6'
    Start-BridgeRun
    Assert-UiChannels ($script:portGateNativeFactoryCalls -eq 1 -and $script:supervisor -and
        [object]::ReferenceEquals($script:radioCatOperationPowerShell,$portGateCatWorker) -and $script:radioCatOperationPortName -ceq 'COM5') `
        'CAT COM5 query 期间不同的 HRI COM6 没有继续启动 fake supervisor。'
    $script:supervisor = $null
    $script:activeHriPortName = ''
    $script:storedProfile.devices.serial_port = 'COM5'

    # The post-preparation gate must use the validated final --port, even when
    # the saved profile was changed after preparation began.
    $script:prepareDirectory = Join-Path $testRoot 'prepared-port-conflict'
    [void][System.IO.Directory]::CreateDirectory($script:prepareDirectory)
    $script:preparedRunDirectory = $script:prepareDirectory
    $script:configDirectory = $testRoot
    $script:nativeExecutable = 'fake-native.exe'
    $script:releaseDirectory = $testRoot
    [System.IO.File]::WriteAllText((Join-Path $script:prepareDirectory 'preparation.json'),'{}',[System.Text.UTF8Encoding]::new($false))
    $script:testValidatedPreparation = [pscustomobject]@{
        Arguments=[string[]]@('--port','COM5'); Executable='fake-native.exe'; StatusPath=(Join-Path $script:prepareDirectory 'status.jsonl')
    }
    function Test-UiPreparationRecord {
        param([object]$Record,[string]$RunDirectory,[string]$RunRoot,[string]$ExpectedExecutable)
        return $script:testValidatedPreparation
    }
    $script:preparePowerShell = [System.Management.Automation.PowerShell]::Create()
    [void]$script:preparePowerShell.AddScript('$null')
    $script:prepareAsync = $script:preparePowerShell.BeginInvoke()
    $prepareWait = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $script:prepareAsync.IsCompleted -and $prepareWait.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 10 }
    Assert-UiChannels ($script:prepareAsync.IsCompleted) 'fake preparation worker did not finish before the final HRI port check.'
    Set-Item -Path Function:\Complete-BridgePreparation -Value $script:actualCompleteBridgePreparation
    Complete-BridgePreparation
    Assert-UiChannels ($null -eq $script:supervisor -and -not $script:preparationStarted -and
        [object]::ReferenceEquals($script:radioCatOperationPowerShell,$portGateCatWorker) -and $script:radioCatOperationPortName -ceq 'COM5' -and
        ([string](Get-TestUiControl 'TransientStatusText').Text) -match 'CAT/HRI 串口冲突取消') `
        ('设备预检最终 --port 与仍释放中的 CAT COM5 冲突时未显示短暂错误或改变 worker。 text={0}, core={1}, prepare={2}, workerSame={3}, catPort={4}' -f `
            [string](Get-TestUiControl 'TransientStatusText').Text,[bool]$script:supervisor,[bool]$script:preparationStarted,
            [object]::ReferenceEquals($script:radioCatOperationPowerShell,$portGateCatWorker),[string]$script:radioCatOperationPortName)

    # The fake worker uses no production CAT module; end it before closing WPF.
    if ($script:radioCatOperationPowerShell) {
        $catStop = $script:radioCatOperationPowerShell.BeginStop($null,$null)
        if ($catStop.AsyncWaitHandle.WaitOne(3000)) { $script:radioCatOperationPowerShell.EndStop($catStop) }
        try { $script:radioCatOperationPowerShell.Dispose() } catch { }
        $script:radioCatOperationPowerShell = $null
        $script:radioCatOperationAsync = $null
        $script:radioCatOperationKind = ''
        $script:radioCatOperationPortName = ''
    }

    $commandText = New-Object 'System.Collections.Generic.List[string]'
    foreach ($testSupervisor in $script:allTestSupervisors) {
        foreach ($command in $testSupervisor.Commands) { $commandText.Add([string]$command.parameters_json) }
    }
    $commandJson = [string]::Join("`n",$commandText.ToArray())
    Assert-UiChannels ($commandJson -notmatch 'synthetic-password-7a91|synthetic-api-key-42bf' -and
        [Environment]::CommandLine -notmatch 'synthetic-password-7a91|synthetic-api-key-42bf') '合成密码或 API Key 出现在控制命令或进程命令行。'

    # Channel labels and activation status must come from scoped local evidence.
    $script:testBmDeviceId='device-fixture-1'; $script:testBmApiKey='api-key-fixture-only'
    $script:bmManagementStatus='loaded'; $script:bmManagementObservedDeviceId=$script:testBmDeviceId
    $script:bmManagementObservedApiKey=$script:testBmApiKey
    $script:bmManagementGroups=@([pscustomobject]@{device_id=$script:testBmDeviceId;talkgroup=[uint64]46001;slot=2;type='static'})
    $script:bmManagementAddContext=[pscustomobject]@{success=$true;device_id=$script:testBmDeviceId;status=2;add_slot=2}
    $script:controlRunId='4242-1730592000123'; $script:controlLastSequence=[uint64]0
    $script:channelActivationState=New-WirexChannelActivationState
    Reset-WirexChannelActivationState -State $script:channelActivationState -RunId $script:controlRunId | Out-Null
    $script:latestStatus=[pscustomobject]@{run_id=$script:controlRunId;bm_state='ready';current_call_valid=$false}
    $script:channels=@(
        (New-UiChannelRecord -Id 12345 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 23456 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 22222 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 46001 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 460997 -Kind private -Slot 2)
    )
    $script:txChannelKey='group:12345:2'; $script:channelPageIndex=0; $script:mutedChannelKeys=@{}
    $script:quickCallCapabilities=$true; $script:controlConfirmed=$true; $script:controlDiagnostic=$false
    $script:isolatedUiMode=$false; $script:quickCallDiagnosticPath=Join-Path $testRoot 'quick-call-requests.jsonl'
    $script:pendingQuickCall=$null; $script:pendingControlRequests=@{}; $script:expiredQuickCallRequests=@{}
    $script:pendingRoutingMutation=$null; $script:pendingChannelMutation=$null; $script:pendingChannelStopMutation=$null
    $script:channelMutationSafetyStopPending=$false; $script:routingMutationFence=$false
    $script:RoutingDiagnostic=$false; $script:RoutingDiagnosticAutoTest=$false
    $script:supervisor=New-TestChannelSupervisor; $script:supervisor.ControlVersion=2
    $script:testControlSequence=[uint64]0

    $staticChannel=$script:channels[3]; $staticPresentation=Get-UiChannelActivationPresentation -Channel $staticChannel
    $dynamicPresentation=Get-UiChannelActivationPresentation -Channel $script:channels[0]
    $privatePresentation=Get-UiChannelActivationPresentation -Channel $script:channels[4]
    Assert-UiChannels ($staticPresentation.is_bm_static -and $staticPresentation.source -ceq '静态组' -and
        $staticPresentation.title -ceq '组呼 46001 · 全国 · 静态组' -and
        [string]$staticPresentation.tooltip -match 'TG 46001 TS2；静态组已读取' -and
        [string]$staticPresentation.tooltip -notmatch 'Native|回读含有' -and
        (Test-UiBmStaticChannelReadback -Channel $staticChannel)) '匹配设备、API 身份、TG和slot的 BM 静态回读没有识别为静态组。'

    $savedStaticTestChannels=@($script:channels)
    $script:bmManagementGroups=@([pscustomobject]@{device_id=$script:testBmDeviceId;talkgroup=[uint64]46001;slot=0;type='static'})
    $script:bmManagementAddContext=[pscustomobject]@{success=$true;device_id=$script:testBmDeviceId;status=4;add_slot=0}
    Assert-UiChannels (Test-UiBmStaticChannelReadback -Channel $staticChannel) `
        'BM slot 0 在同设备 status 4/simplex 回读与唯一软件时隙上没有正确映射。'
    $ambiguousSlotOne=New-UiChannelRecord -Id 46001 -Kind group -Slot 1
    $script:channels=@($savedStaticTestChannels)+@($ambiguousSlotOne)
    Assert-UiChannels (-not (Test-UiBmStaticChannelReadback -Channel $staticChannel) -and
        -not (Test-UiBmStaticChannelReadback -Channel $ambiguousSlotOne)) `
        'BM slot 0 在同 TG 同时配置两个软件slot时被错误映射到任意一个。'
    $script:channels=$savedStaticTestChannels
    $script:bmManagementAddContext=[pscustomobject]@{success=$true;device_id=$script:testBmDeviceId;status=2;add_slot=2}
    Assert-UiChannels (-not (Test-UiBmStaticChannelReadback -Channel $staticChannel)) `
        'BM slot 0 在 duplex/status 2 上下文中被错误解释为软件 slot 2。'
    $slotOneChannel=New-UiChannelRecord -Id 46001 -Kind group -Slot 1
    $script:bmManagementGroups=@([pscustomobject]@{device_id=$script:testBmDeviceId;talkgroup=[uint64]46001;slot=1;type='static'})
    Assert-UiChannels ((Test-UiBmStaticChannelReadback -Channel $slotOneChannel) -and
        -not (Test-UiBmStaticChannelReadback -Channel $staticChannel)) 'BM API slot 1 没有只匹配同 slot 频道。'
    $script:bmManagementGroups=@([pscustomobject]@{device_id=$script:testBmDeviceId;talkgroup=[uint64]46001;slot=2;type='static'})
    Assert-UiChannels (Test-UiBmStaticChannelReadback -Channel $staticChannel) 'BM API slot 2 没有匹配 TS2 频道。'
    $script:bmManagementGroups=@([pscustomobject]@{device_id='other-device';talkgroup=[uint64]46001;slot=2;type='static'})
    Assert-UiChannels (-not (Test-UiBmStaticChannelReadback -Channel $staticChannel)) '错误设备的 BM 静态组记录被用于当前频道。'
    $script:bmManagementGroups=@([pscustomobject]@{device_id=$script:testBmDeviceId;talkgroup=[uint64]46001;slot=0;type='static'})
    $script:bmManagementAddContext=[pscustomobject]@{success=$true;device_id='other-device';status=4;add_slot=0}
    Assert-UiChannels (-not (Test-UiBmStaticChannelReadback -Channel $staticChannel)) 'slot 0 context 设备不匹配时被错误映射。'
    $script:bmManagementAddContext=[pscustomobject]@{success=$true;device_id=$script:testBmDeviceId;status=4;add_slot=0}
    Assert-UiChannels (Test-UiBmStaticChannelReadback -Channel $staticChannel) '恢复当前 simplex context 后 slot 0 静态回读没有匹配唯一软件slot。'
    $script:bmManagementGroups=@([pscustomobject]@{device_id=$script:testBmDeviceId;talkgroup=[uint64]46001;slot=2;type='static'})
    $script:bmManagementAddContext=[pscustomobject]@{success=$true;device_id=$script:testBmDeviceId;status=2;add_slot=2}
    $script:testBmApiKey='different-api-key'
    Assert-UiChannels (-not (Test-UiBmStaticChannelReadback -Channel $staticChannel)) 'BM API 身份变化后仍使用旧静态组回读禁用激活。'
    $script:testBmApiKey='api-key-fixture-only'
    Assert-UiChannels ($dynamicPresentation.source -ceq '' -and $dynamicPresentation.title -ceq '组呼 12345' -and
        $privatePresentation.source -ceq '' -and $privatePresentation.title -ceq '单呼 460997 · 中国鹦鹉') `
        '动态来源未知时出现状态占位文字，或把中国鹦鹉单呼误标为 BM 静态组。'
    Update-UiChannelDisplays
    $staticButton=Get-TestChannelButton -ChannelKey 'group:46001:2' -Action quick_call
    $staticTitle=@($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object {
        -not $_.Tag.blank -and [string]$_.Tag.channel_key -ceq 'group:46001:2'
    } | ForEach-Object { @($_.Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Name -ceq 'ChannelCardTitle' }) }) | Select-Object -First 1
    Assert-UiChannels ($staticButton -and -not $staticButton.IsEnabled -and $staticButton.Content -ceq '静态组' -and
        $staticTitle.Text -ceq '组呼 46001 · 全国 · 静态组' -and
        [string]$staticTitle.ToolTip -match 'TG 46001 TS2；静态组已读取' -and
        [string]$staticTitle.ToolTip -notmatch 'Native|回读含有' -and
        $staticTitle.Tag.id -eq 46001 -and $staticTitle.Tag.kind -ceq 'group' -and $staticTitle.Tag.source -ceq '静态组') `
        '静态组卡片没有显示完整频道身份/证据，或仍允许激活。'

    $script:pendingQuickCall=$null
    $dynamicOne=$script:channels[0]
    $dynamicTwo=$script:channels[1]
    $dynamicThree=$script:channels[2]
    $commandCountBefore=$script:supervisor.Commands.Count
    Assert-UiChannels ((Invoke-UiChannelQuickCall -Channel $dynamicOne) -and
        $script:supervisor.Commands.Count -eq ($commandCountBefore+1) -and
        $script:supervisor.Commands[-1].command -ceq 'network_subscription.quick_call_join') '有效动态组请求没有只发送一个本机 quick_call_join 命令。'
    $failedRequest=$script:pendingQuickCall
    Update-UiChannelDisplays
    $pendingOne=Get-TestChannelButton -ChannelKey 'group:12345:2' -Action quick_call
    $pendingTwo=Get-TestChannelButton -ChannelKey 'group:23456:2' -Action quick_call
    Assert-UiChannels ($pendingOne -and -not $pendingOne.IsEnabled -and $pendingOne.Content -ceq '请求处理中' -and
        $pendingTwo -and -not $pendingTwo.IsEnabled) 'pending quick_call 期间没有禁用同槽和其他槽的激活按钮。'
    $duplicateBlocked=$false
    try { [void](Invoke-UiChannelQuickCall -Channel $dynamicTwo) } catch { $duplicateBlocked = ($_.Exception.Message -match '仍在等待本机结果') }
    Assert-UiChannels ($duplicateBlocked -and $script:supervisor.Commands.Count -eq ($commandCountBefore+1)) `
        '方法层没有拒绝覆盖尚未完成的请求，或重复操作又发送了命令。'
    Receive-TestQuickCallResult -Request $failedRequest -Result rejected -ErrorCode media_busy
    $mediaBusyRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:12345:2' -Slot 2
    $mediaBusyDiagnostic=if([IO.File]::Exists($script:quickCallDiagnosticPath)){[IO.File]::ReadAllText($script:quickCallDiagnosticPath)}else{''}
    Assert-UiChannels ($null -eq $script:pendingQuickCall -and
        $script:transientStatusLastMessage -match '本机 Native 拒绝：media_busy' -and -not $mediaBusyRequestSent) `
        ('media_busy 拒绝没有显示本机具体原因，或失败结果被误记为已发送。 pending={0}, status={1}, sent={2}, stateRun={3}, diag={4}' -f `
            [bool]$script:pendingQuickCall,[string]$script:transientStatusLastMessage,[bool]$mediaBusyRequestSent,
            [string]$script:channelActivationState.run_id,$mediaBusyDiagnostic)

    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $dynamicOne) 'Native 拒绝后没有允许新请求。'
    $shortSendRequest=$script:pendingQuickCall
    Receive-TestQuickCallResult -Request $shortSendRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 12345 -Slot 2 -FramesSent 1
    Assert-UiChannels ($null -eq (Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
            -ChannelKey 'group:12345:2' -Slot 2) -and $script:transientStatusLastMessage -match '未确认两帧已发送') `
        'Native 返回单帧结果时被误记为成功，或没有释放请求以供手动重试。'

    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $dynamicOne) '失败后允许用户手动重试的组呼请求没有提交。'
    $successfulRequest=$script:pendingQuickCall
    Receive-TestQuickCallResult -Request $successfulRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 12345 -Slot 2 -FramesSent 2
    $sentOne=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:12345:2' -Slot 2
    Assert-UiChannels ($sentOne -and $sentOne.activation_status -ceq 'request_sent' -and $sentOne.frames_sent -eq 2 -and
        $script:transientStatusLastMessage -match 'BM持续状态未确认' -and
        -not (Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId '9999-1234567' `
            -ChannelKey 'group:12345:2' -Slot 2)) 'Native 两帧确认后没有按 run ID 标记 request_sent，或界面声称已确认 BM 持续状态。'
    Update-UiChannelDisplays
    $sentButton=Get-TestChannelButton -ChannelKey 'group:12345:2' -Action quick_call
    $sentPresentation=Get-UiChannelActivationPresentation -Channel $dynamicOne
    $sentCard=@($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object {
        -not $_.Tag.blank -and [string]$_.Tag.channel_key -ceq 'group:12345:2'
    } | Select-Object -First 1)
    $sentTitle=@($sentCard.Child.Children | Where-Object {
        $_ -is [System.Windows.Controls.TextBlock] -and [string]$_.Name -ceq 'ChannelCardTitle'
    } | Select-Object -First 1)
    $afterSuccessCount=$script:supervisor.Commands.Count
    Assert-UiChannels ($sentButton -and -not $sentButton.IsEnabled -and $sentButton.Content -ceq '已发送' -and
        $sentPresentation.source -ceq '动态组' -and $sentPresentation.title -ceq '组呼 12345 · 动态组' -and
        [string]$sentPresentation.tooltip -match 'TG 12345 TS2；激活请求已发送' -and
        [string]$sentPresentation.tooltip -notmatch 'Native|回读|request_sent|两帧' -and
        $sentTitle -and $sentTitle.Text -ceq '组呼 12345 · 动态组' -and
        [string]$sentTitle.ToolTip -match '激活请求已发送' -and $sentTitle.Tag.request_sent -and
        -not (Invoke-UiChannelQuickCall -Channel $dynamicOne) -and $script:supervisor.Commands.Count -eq $afterSuccessCount) `
        '本机会话 request_sent 后仍可重复发送，或卡片没有显示本地请求状态。'

    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $dynamicThree) '同槽新组请求没有获准替换旧本地 request_sent 标记。'
    Assert-UiChannels (-not (Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
            -ChannelKey 'group:12345:2' -Slot 2)) '同槽新组请求后旧目标的本地 request_sent 标记没有清除。'
    $supersededRequest=$script:pendingQuickCall
    [void](Set-WirexChannelActivationRequestTimedOut -State $script:channelActivationState `
        -RunId $script:controlRunId -RequestId ([string]$supersededRequest.request_id))
    $script:pendingQuickCall.timed_out=$true
    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $dynamicTwo) '超时后用户不能重试同一 slot 的另一个频道。'
    $newGroupRequest=$script:pendingQuickCall
    Receive-TestQuickCallResult -Request $supersededRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 22222 -Slot 2 -FramesSent 2
    Assert-UiChannels ($script:pendingQuickCall.request_id -ceq $newGroupRequest.request_id -and
        -not (Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
            -ChannelKey 'group:22222:2' -Slot 2)) '超时旧请求的迟到成功覆盖了同槽新请求状态。'
    Receive-TestQuickCallResult -Request $newGroupRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 23456 -Slot 2 -FramesSent 2
    $script:activeRouting=[pscustomobject]@{tx_target=[pscustomobject]@{destination_id=[uint64]23456;kind='group';slot=[uint64]2}}
    $sameTgCleared=Clear-UiChannelActivationAfterGroupPtt -RunId $script:controlRunId -EventName 'tx_started_from_radio_ptt_down'
    Update-UiChannelDisplays
    $sameTgButton=Get-TestChannelButton -ChannelKey 'group:23456:2' -Action quick_call
    $sameTgRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:23456:2' -Slot 2
    Assert-UiChannels (-not $sameTgCleared -and $sameTgRequestSent -and $sameTgButton -and -not $sameTgButton.IsEnabled) `
        '同一 TG、同一 slot 的组呼 PTT 清除了 request_sent 或重新启用了按钮。'

    $script:activeRouting=[pscustomobject]@{tx_target=[pscustomobject]@{destination_id=[uint64]460997;kind='private';slot=[uint64]2}}
    $privatePttCleared=Clear-UiChannelActivationAfterGroupPtt -RunId $script:controlRunId -EventName 'tx_started_from_radio_ptt_down'
    $privatePttRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:23456:2' -Slot 2
    Assert-UiChannels (-not $privatePttCleared -and $privatePttRequestSent) '私呼 PTT 清除了组呼 request_sent。'

    $script:activeRouting=[pscustomobject]@{tx_target=[pscustomobject]@{kind='group';slot=[uint64]2}}
    $unknownPttCleared=Clear-UiChannelActivationAfterGroupPtt -RunId $script:controlRunId -EventName 'tx_started_from_radio_ptt_down'
    $unknownPttRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:23456:2' -Slot 2
    Assert-UiChannels (-not $unknownPttCleared -and $unknownPttRequestSent) '缺少 destination_id 的组呼 PTT 清除了 request_sent。'

    $slotOneGroup=New-UiChannelRecord -Id 33333 -Kind group -Slot 1
    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $slotOneGroup) 'slot 1 测试组请求没有通过正常 quick_call 流程启动。'
    $slotOneRequest=$script:pendingQuickCall
    Receive-TestQuickCallResult -Request $slotOneRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 33333 -Slot 1 -FramesSent 2
    $slotOneRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:33333:1' -Slot 1
    Assert-UiChannels ($slotOneRequestSent -and $slotOneRequestSent.destination_id -eq 33333) 'slot 1 测试请求没有经由本机结果登记 request_sent。'

    $script:activeRouting=[pscustomobject]@{tx_target=[pscustomobject]@{destination_id=[uint64]22222;kind='group';slot=[uint64]2}}
    $pttCleared=Clear-UiChannelActivationAfterGroupPtt -RunId $script:controlRunId -EventName 'tx_started_from_radio_ptt_down'
    $pttRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:23456:2' -Slot 2
    $otherSlotRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:33333:1' -Slot 1
    Assert-UiChannels ($pttCleared -and -not $pttRequestSent -and $otherSlotRequestSent) `
        '不同 TG 的合法同槽组呼 PTT 没有清除旧标记，或误清了另一 slot 的请求标记。'

    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $dynamicOne) 'PTT 清除本地标记后没有允许再次手动请求。'
    $reconnectRequest=$script:pendingQuickCall
    Receive-TestQuickCallResult -Request $reconnectRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 12345 -Slot 2 -FramesSent 2
    $reconnectCleared=Reset-UiChannelActivationForBmReconnect -RunId $script:controlRunId
    $reconnectedRequestSent=Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
        -ChannelKey 'group:12345:2' -Slot 2
    Assert-UiChannels ($reconnectCleared -and -not $reconnectedRequestSent) 'BM 离开 ready 后没有清除本会话请求状态。'
    Assert-UiChannels (Invoke-UiChannelQuickCall -Channel $dynamicOne) '重连清状态后没有允许用户重新请求。'
    $lateRequest=$script:pendingQuickCall
    [void](Reset-UiChannelActivationForBmReconnect -RunId $script:controlRunId)
    Receive-TestQuickCallResult -Request $lateRequest -Result ok -ActivationStatus request_sent `
        -DestinationId 12345 -Slot 2 -FramesSent 2
    Assert-UiChannels (-not (Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $script:controlRunId `
            -ChannelKey 'group:12345:2' -Slot 2) -and $script:expiredQuickCallRequests.Count -eq 0) `
        'BM 重连前发起的迟到响应没有被丢弃，或伪造为新会话成功。'
    $quickCallRows=@([System.IO.File]::ReadAllLines($script:quickCallDiagnosticPath) | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    $quickCallAllowedFields=@('timestamp_utc','run_id','request_id','destination_id','slot','result','error_code','activation_status','frames_sent','replayed')
    $quickCallBadRows=New-Object 'System.Collections.Generic.List[object]'
    foreach($quickCallRow in $quickCallRows){
        $extraFields=@($quickCallRow.PSObject.Properties | Where-Object { $quickCallAllowedFields -cnotcontains $_.Name })
        $missingFields=@($quickCallAllowedFields | Where-Object { $null -eq $quickCallRow.PSObject.Properties[[string]$_] })
        if($extraFields.Count -gt 0 -or $missingFields.Count -gt 0){$quickCallBadRows.Add($quickCallRow)}
    }
    $quickCallDiagnosticIncludesKey=($commandJson -match 'api-key-fixture-only|different-api-key')
    Assert-UiChannels ($quickCallRows.Count -ge 8 -and $quickCallBadRows.Count -eq 0 -and -not $quickCallDiagnosticIncludesKey) `
        ('Quick Call 有界诊断日志缺少结果阶段，或记录了凭据/未授权字段。 count={0}, badRows={1}, keyInEarlierCommands={2}, firstFields={3}' -f `
            $quickCallRows.Count,$quickCallBadRows.Count,$quickCallDiagnosticIncludesKey,(@($quickCallRows[0].PSObject.Properties.Name) -join ','))
    $quickCallCommandJson=[string]::Join("`n",@($script:supervisor.Commands | ForEach-Object { [string]$_.parameters_json }))
    Assert-UiChannels ($quickCallCommandJson -notmatch 'api-key-fixture-only|different-api-key|synthetic-password-7a91' -and
        $script:txChannelKey -ceq 'group:12345:2') 'Quick Call 命令携带了凭据，或激活操作更改了已保存的 PTT 目标。'

    Assert-UiChannels ([System.IO.File]::Exists($script:portableConfigPath) -and
        [System.IO.Path]::GetFullPath($script:portableConfigPath).StartsWith([System.IO.Path]::GetFullPath($testRoot),[StringComparison]::OrdinalIgnoreCase)) '测试配置没有留在唯一临时根目录 config.json。'
    $rootConfigExistedAfter = [System.IO.File]::Exists($rootConfigPath)
    $rootConfigHashAfter = ''
    if ($rootConfigExistedAfter) {
        $rootConfigHashAfter = Get-TestFileHash -Path $rootConfigPath
    }
    Assert-UiChannels ($rootConfigExistedAfter -eq $rootConfigExistedBefore -and $rootConfigHashAfter -ceq $rootConfigHashBefore) `
        '测试运行期间仓库根 config.json 的存在状态或内容发生变化。'
    Write-Output ('通过：频道 tuple/顺序/default TX、group/private RX、RX 活跃 mute/remove 双 ACK、TX NACK、TX ACK 后 RX 发送失败/NACK/超时安全停机、迟到 ACK 丢弃、Native 提前退出后重连可再编辑、原 config 保留和真实 WPF 输入事件（{0} 项断言）。' -f $script:assertionCount)
} finally {
    if ($script:settingsWindow) { try { [void]$script:settingsWindow.Close() } catch { } }
    if ($script:mainWindow) { try { [void]$script:mainWindow.Close() } catch { } }
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + [System.IO.Path]::DirectorySeparatorChar
    $fullTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ($fullTestRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($fullTestRoot) -match '^wirex-ui-channels-[0-9a-f]{32}$' -and
        [System.IO.Directory]::Exists($fullTestRoot)) {
        [System.IO.Directory]::Delete($fullTestRoot,$true)
    }
}
