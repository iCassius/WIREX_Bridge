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
    return $script:mainWindow
}

function Invoke-TestPreviewClick {
    param([Parameter(Mandatory=$true)][System.Windows.UIElement]$Element)
    $event = [System.Windows.Input.MouseButtonEventArgs]::new(
        [System.Windows.Input.Mouse]::PrimaryDevice,0,[System.Windows.Input.MouseButton]::Left)
    $event.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
    $event.Source = $Element
    $Element.RaiseEvent($event)
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
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
$mainTokens = $null; $mainErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$mainTokens,[ref]$mainErrors)
Assert-UiChannels ($mainErrors.Count -eq 0) 'bridge-ui.ps1 解析失败。'
$catTokens = $null; $catErrors = $null
$catAst = [System.Management.Automation.Language.Parser]::ParseFile($radioCatPath,[ref]$catTokens,[ref]$catErrors)
Assert-UiChannels ($catErrors.Count -eq 0) 'RadioCatUi.ps1 解析失败。'
$mainDefinitions = @($mainAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
foreach ($name in @('Import-UiPortableConfig','Save-UiChannelAdvancedSlot','Set-ConnectionButtonState','Set-ConnectionConfigLocked')) {
    $matches = @($mainDefinitions | Where-Object { $_.Name -ceq $name })
    Assert-UiChannels ($matches.Count -eq 1) ("{0} 应只有一个函数定义，实际为 {1}。" -f $name,$matches.Count)
}
$allDefinitions = @($mainDefinitions) + @($catAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
$functionNames = @(
    'Import-WpfWindow','Get-UiControl','Get-SettingsControl','Get-UiChannelKey','Get-UiChannelTarget','Get-UiChannelByKey',
    'New-UiChannelRecord','Get-UiNativeRxPolicyForChannels','Get-UiChannelCurrentCall','Get-UiChannelCallerLabel',
    'ConvertFrom-UiPortableConfigToProfile','Save-UiPortableConfig','Fit-WpfWindowToWorkArea',
    'Set-MainText','Set-UiChannelStatus','New-UiChannelActionButton','Update-UiChannelDisplays','Start-UiChannelMutation',
    'Get-UiChannelTargetFromRouting','Complete-UiChannelMutation','Add-UiChannelFromInputs','Remove-UiChannel','Set-UiChannelMuted',
    'Invoke-UiSetCallTarget','Test-UiControlUnsigned','Test-UiExactControlFields','Test-UiRxPolicy','Copy-UiRxPolicy','Invoke-UiRoutingMutation',
    'Complete-UiChannelMutationFailure','Add-UiComboOpenHandlers','Register-UiRadioCatPortTextInput','Get-UiRadioCatConnectionKey',
    'Get-UiHriPortName','Set-UiRadioCatText','Set-UiRadioCatControlEnabled','Find-UiRadioCatControl','Set-UiRadioCatControls',
    'Set-UiRadioCatPowerSliderRange','Get-UiRadioCatObservedValue','Update-UiRadioCatObservationDisplay','Update-UiRadioCatControls',
    'Initialize-UiSettingsWindow','Initialize-SettingsWindow','Set-UiComboValue','Complete-BridgeStopInternal','Complete-BridgeStop',
    'On-UiTimerTick','Request-UiRoutingStatus','Set-UiControlStatus','Set-UiOfflineDisplay','Set-OfflineDisplay',
    'Set-ConnectionButtonState','Set-ConnectionConfigLocked','Set-UiIdentityRowVisibility','Update-UiPlaybackGainDisplay',
    'Complete-UiRadioCatOperationAndPersist','Complete-UiRadioCatOperation','Invoke-UiRadioCatPollTick','Process-UiControlEvents','Read-StatusUpdates',
    'Set-StaleDisplay','Complete-UiDeviceDiscovery','Complete-BridgePreparation','Clear-UiSessionTemp','Stop-UiRadioCatPolling','Update-RoutingDisplays',
    'Set-RoutingMutationPendingState','Set-RoutingEditorStatus','Add-UiEvent','Update-DynamicGroupControls','Reset-UiControlState',
    'Get-UiSourceIdentityDisplay','Get-UiRadioCatSelectedPort','Get-UiRadioCatStopBits','Get-UiRadioCatBaudRate',
    'Update-UiReceiveMetricsDisplay','Update-UiIdentityActionState','Complete-UiIdentityQuery','Expire-UiNativeIdentityUpdate',
    'Start-UiChannelMutationSafetyStop','Clear-UiChannelMutationSafetyState'
)
# Extract the selected functions by their own AST names; this keeps the test tied to production bodies.
$selected = @($allDefinitions | Where-Object { $functionNames -ccontains $_.Name })
Invoke-Expression (($selected | ForEach-Object { $_.Extent.Text }) -join "`r`n")
Import-Module -Name $portableConfigModulePath -Force

$mainXaml = [System.IO.File]::ReadAllText($mainXamlPath)
$settingsXaml = [System.IO.File]::ReadAllText($settingsXamlPath)
foreach ($forbidden in @('FavoritesPanel','FavoritesList','TransmitEnabledBox','CatStopBitsBox','FavoritesButton')) {
    Assert-UiChannels ($mainXaml -notmatch ('x:Name="' + [regex]::Escape($forbidden) + '"')) ("MainWindow.xaml 仍含已删除控件 {0}。" -f $forbidden)
}
foreach ($required in @('ChannelIdBox','ChannelKindBox','MakeChannelTxTargetCheckBox','AddChannelButton','ChannelListPanel','ChannelCardsPanel','CatPortBox')) {
    Assert-UiChannels ($mainXaml -match ('x:Name="' + [regex]::Escape($required) + '"')) ("MainWindow.xaml 缺少 {0}。" -f $required)
}
Assert-UiChannels ($settingsXaml -match 'x:Name="ChannelSlotBox"') '高级频道窗缺少时隙下拉框。'

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
$script:pendingRoutingMutation = $null; $script:pendingChannelMutation = $null; $script:pendingChannelStopMutation = $null
$script:channelMutationSafetyStopPending = $false
$script:routingMutationFence = $false; $script:activeRouting = $null; $script:activeProfile = $null; $script:storedProfile = $null
$script:supervisor = $null; $script:controlConfirmed = $false; $script:routingCapabilities = $false
$script:pendingControlRequests = @{}; $script:timedOutRoutingMutations = @{}; $script:resolvedTimedOutRoutingRequests = @{}
$script:pendingRoutingStatusRequestId = ''; $script:pendingStatusRequestId = ''; $script:pendingQuickCall = $null
$script:pendingDynamicCallTarget = $null; $script:stopTask = $null; $script:statusStream = $null
$script:nativeExitCleanupPending = $false; $script:nativeExitCleanupStarted = $false
$script:radioModeApplyAfterStop = $null; $script:radioModePreviousHriPortName = ''; $script:closingAfterStop = $false; $script:reconnectAfterStop = $false
$script:sessionTempDirectory = ''; $script:sessionPasswordPath = ''; $script:latestStatus = $null
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

# Offline stubs keep the actual channel functions and WPF callbacks under test without starting external services.
function Update-UiRadioCatControls { $script:testCatControlsUpdated++ }
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
function Update-DynamicGroupControls { return }
function ConvertFrom-UiControlFrame { param([string]$Json,[string]$LockedRunId,[uint64]$LastControlSequence,[int]$ExpectedProcessId) return $script:testControlRecord }
function Set-OfflineDisplay { param([string]$Reason='') return }

try {
    $script:portableConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
    $script:portableConfig.connection.callsign = 'N0TEST'
    $script:portableConfig.connection.gateway_id = [uint64]12345
    $script:portableConfig.connection.source_id = [uint64]123456
    $script:portableConfig.connection.password = 'synthetic-password-7a91'
    $script:portableConfig.connection.api_key = 'synthetic-api-key-42bf'
    $script:portableConfig.channels = [object[]]@()
    $script:portableConfig.tx_channel_id = ''
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    $script:channels = @($script:portableConfig.channels)
    $script:txChannelKey = [string]$script:portableConfig.tx_channel_id

    $script:mainWindow = Open-TestMainWindow
    $script:channelEditorSlot = 1
    $script:channels = @()
    $script:txChannelKey = ''
    $script:mutedChannelKeys = @{}
    $kindBox = Get-TestUiControl 'ChannelKindBox'
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq 'group' })[0]
    (Get-TestUiControl 'ChannelIdBox').Text = '12345'
    Add-UiChannelFromInputs
    Assert-UiChannels ($script:channels.Count -eq 1 -and (Get-UiChannelKey -Channel $script:channels[0]) -ceq 'group:12345:1') '首次加入频道未按明确类型和 TS1 保存。'
    Assert-UiChannels ($script:txChannelKey -ceq 'group:12345:1') '空列表加入首频道后没有将首项设为默认 PTT 目标。'
    Assert-UiChannels ((Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:12345:1') '首次频道和默认 PTT 目标没有保存到临时根目录 config.json。'

    $sameGroupTs2 = New-UiChannelRecord -Id 12345 -Kind group -Slot 2
    $samePrivateTs1 = New-UiChannelRecord -Id 12345 -Kind private -Slot 1
    Assert-UiChannels ((Get-UiChannelKey -Channel $sameGroupTs2) -cne (Get-UiChannelKey -Channel $samePrivateTs1)) 'kind/slot 没有参与频道元组 key。'
    Assert-UiChannels ((Get-UiChannelKey -Channel $sameGroupTs2) -ceq 'group:12345:2' -and
        (Get-UiChannelKey -Channel $samePrivateTs1) -ceq 'private:12345:1') '同 ID 的不同 kind/slot 被混为一个频道。'
    $script:channels = @($script:channels) + @($sameGroupTs2,$samePrivateTs1,
        (New-UiChannelRecord -Id 91 -Kind group -Slot 2),(New-UiChannelRecord -Id 46001 -Kind group -Slot 2))
    $script:txChannelKey = 'group:91:2'
    $script:portableConfig.channels = [object[]]$script:channels
    $script:portableConfig.tx_channel_id = $script:txChannelKey
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    Assert-UiChannels ($script:channels.Count -eq 5 -and (Get-UiChannelKey -Channel $script:channels[0]) -ceq 'group:12345:1' -and
        (Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:91:2') '频道顺序或 91 PTT 目标未保存。'
    $script:portableConfig.tx_channel_id = 'group:46001:2'
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    Assert-UiChannels ((Get-WirexPortableConfig -Path $script:portableConfigPath).tx_channel_id -ceq 'group:46001:2') '46001 作为显式 PTT 目标被配置层拒绝。'

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
    $script:activeRouting = [pscustomobject]@{
        local_source_id=[uint64]123456; media_owner='rx_active'; rx_policy_revision=[uint64]5; tx_policy_revision=[uint64]7
        tx_target=[pscustomobject]@{destination_id=[uint64]91;kind='group';slot=[uint64]2;transmit_enabled=$true}
        rx_policy=$groupPolicy; transmit_enabled=$true
    }
    $script:txChannelKey = 'group:91:2'
    $script:channels = @($script:channels)
    $beforeMute = [System.IO.File]::ReadAllText($script:portableConfigPath,[System.Text.Encoding]::UTF8)
    Set-UiChannelMuted -Channel ($script:channels | Where-Object { $_.kind -ceq 'private' } | Select-Object -First 1)
    Assert-UiChannels ($script:pendingRoutingMutation.command -ceq 'rx_policy.replace' -and
        $script:pendingChannelMutation -and $script:channels.Count -eq 5 -and $script:txChannelKey -ceq 'group:91:2') `
        ('RX 活跃时屏蔽频道未提交 RX 更新，或提前更改列表/PTT。 pending={0}, channelPending={1}, count={2}, tx={3}, status={4}' -f `
            $(if ($script:pendingRoutingMutation) { $script:pendingRoutingMutation.command } else { '<null>' }),[bool]$script:pendingChannelMutation,
            $script:channels.Count,$script:txChannelKey,(Get-TestUiControl 'ChannelStatusText').Text)
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
    (Get-TestUiControl 'RadioCatPanel').Visibility = [System.Windows.Visibility]::Visible
    $script:mainWindow.UpdateLayout()
    Assert-UiChannels ($catPort.IsEditable) 'CAT 端口字段不再是可编辑组合框。'
    Register-UiRadioCatPortTextInput
    $editBox = $catPort.Template.FindName('PART_EditableTextBox',$catPort)
    Assert-UiChannels ($editBox -is [System.Windows.Controls.TextBox]) 'CAT 端口编辑区没有真实 TextBox。'
    [void](Invoke-TestPreviewClick -Element $editBox)
    Assert-UiChannels ($catPort.IsDropDownOpen) '点击 CAT 可编辑文本区没有打开端口候选。'
    [void]$catPort.Focus(); [void]$editBox.Focus(); $editBox.SelectAll(); $editBox.Text = 'COM777'
    Assert-UiChannels ($script:radioCatPortTextEditExplicit -and $script:radioCatPortSelectionExplicit -and $catPort.Text -ceq 'COM777') `
        ('CAT 编辑区输入没有触发实际 TextChanged 选择状态。 edit={0}, explicit={1}, focused={2}/{3}, tag={4}, text={5}' -f `
            $script:radioCatPortTextEditExplicit,$script:radioCatPortSelectionExplicit,$editBox.IsFocused,$editBox.IsKeyboardFocusWithin,$editBox.Tag,$catPort.Text)
    [void]$script:mainWindow.Close()

    $script:mainWindow = Open-TestMainWindow
    $script:settingsWindow = Initialize-SettingsWindow
    $script:settingsWindow.Opacity = 0
    $script:settingsWindow.Show(); $script:settingsWindow.UpdateLayout()
    $slotBox = $script:settingsWindow.FindName('ChannelSlotBox')
    Assert-UiChannels (-not $slotBox.IsEditable) '频道高级时隙下拉框意外允许自由文本。'
    [void](Invoke-TestPreviewClick -Element $slotBox)
    Assert-UiChannels ($slotBox.IsDropDownOpen) '点击频道高级时隙下拉框主体没有打开 TS1/TS2 选项。'

    $commandText = New-Object 'System.Collections.Generic.List[string]'
    foreach ($testSupervisor in $script:allTestSupervisors) {
        foreach ($command in $testSupervisor.Commands) { $commandText.Add([string]$command.parameters_json) }
    }
    $commandJson = [string]::Join("`n",$commandText.ToArray())
    Assert-UiChannels ($commandJson -notmatch 'synthetic-password-7a91|synthetic-api-key-42bf' -and
        [Environment]::CommandLine -notmatch 'synthetic-password-7a91|synthetic-api-key-42bf') '合成密码或 API Key 出现在控制命令或进程命令行。'
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
