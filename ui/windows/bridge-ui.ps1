[CmdletBinding()]
param(
    [string]$UserConfigDirectory,
    [string]$PackageDirectory,
    [switch]$OfflinePreview,
    [switch]$NoAutoConnect,
    [switch]$RenderOnly,
    [switch]$RoutingDiagnostic,
    [switch]$RoutingDiagnosticAutoTest,
    [string]$RenderOutputDirectory,
    [string]$RenderWorkArea
)

$ErrorActionPreference = 'Stop'
if ($RoutingDiagnosticAutoTest -and -not $RoutingDiagnostic) { throw '-RoutingDiagnosticAutoTest 必须与 -RoutingDiagnostic 一起使用。' }
if ($RoutingDiagnostic -and (-not $PSBoundParameters.ContainsKey('UserConfigDirectory') -or [string]::IsNullOrWhiteSpace($UserConfigDirectory))) {
    throw '路由诊断必须指定独立的 -UserConfigDirectory。'
}
$script:uiRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:packageDirectoryWasExplicit = $PSBoundParameters.ContainsKey('PackageDirectory') -and
    -not [string]::IsNullOrWhiteSpace($PackageDirectory)
$script:packageRoot = if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    [System.IO.Path]::GetFullPath((Join-Path $script:uiRoot '..\..'))
} else {
    [System.IO.Path]::GetFullPath($PackageDirectory)
}

function Resolve-UiRuntimeDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$UserConfigDirectory,
        [Parameter(Mandatory=$true)][bool]$PackageDirectoryWasExplicit
    )
    $resolvedPackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
    if ($PackageDirectoryWasExplicit) { return $resolvedPackageRoot }
    $releasePointerPath = Join-Path $UserConfigDirectory 'bridge-directory.txt'
    if ([System.IO.File]::Exists($releasePointerPath)) {
        return Get-BridgeReleaseDirectory -UserConfigDirectory $UserConfigDirectory
    }
    return $resolvedPackageRoot
}

function Test-UiRoutingDiagnosticConfigDirectory {
    param([string]$Directory,[string]$PackageRoot,[switch]$RequireFixture)
    if ([string]::IsNullOrWhiteSpace($Directory)) { throw '路由诊断必须指定独立的用户配置目录。' }
    try {
        $resolvedDirectory = [System.IO.Path]::GetFullPath($Directory)
        $canonicalDirectory = [System.IO.Path]::GetFullPath((Join-Path $PackageRoot 'private\user-config'))
    } catch { throw '路由诊断配置目录路径无效。' }
    if ([string]::Equals($resolvedDirectory.TrimEnd('\'),$canonicalDirectory.TrimEnd('\'),[System.StringComparison]::OrdinalIgnoreCase)) {
        throw '路由诊断不能使用便携目录的默认个人配置目录；请传入隔离的 -UserConfigDirectory。'
    }
    if ($RequireFixture) {
        $markerPath = Join-Path $resolvedDirectory 'routing-diagnostic-fixture.json'
        if (-not [System.IO.File]::Exists($markerPath) -or (New-Object System.IO.FileInfo($markerPath)).Length -gt 4096) {
            throw '自动路由验收需要测试脚本在隔离目录中创建routing-diagnostic-fixture.json。'
        }
        try { $marker = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($markerPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop }
        catch { throw '自动路由验收标识文件无效。' }
        $names = @($marker.PSObject.Properties | ForEach-Object { [string]$_.Name })
        $expected = @('schema_version','purpose','fixture_id','source_id')
        $id = [guid]::Empty
        if ($marker -isnot [System.Management.Automation.PSCustomObject] -or $names.Count -ne $expected.Count -or
            @($names | Where-Object { $expected -cnotcontains $_ }).Count -gt 0 -or
            @($expected | Where-Object { $names -cnotcontains $_ }).Count -gt 0 -or
            $marker.schema_version -is [bool] -or [int]$marker.schema_version -ne 1 -or
            $marker.purpose -cne 'wirex-routing-diagnostic-test' -or
            -not [guid]::TryParseExact([string]$marker.fixture_id,'N',[ref]$id) -or
            $marker.source_id -is [bool] -or [uint64]$marker.source_id -ne 1) {
            throw '自动路由验收标识必须匹配隔离测试、schema 1 和 Source ID 1。'
        }
    }
    return $resolvedDirectory
}

$script:modulePath = Join-Path $script:packageRoot 'bridge-user-config.psm1'
if (-not [System.IO.File]::Exists($script:modulePath)) {
    $script:modulePath = Join-Path $script:packageRoot 'tools\bridge-user-config.psm1'
}
if (-not [System.IO.File]::Exists($script:modulePath)) {
    $script:modulePath = Join-Path $script:uiRoot '..\..\tools\bridge-user-config.psm1'
}
if (-not [System.IO.File]::Exists($script:modulePath)) { throw '缺少本机配置模块 bridge-user-config.psm1。' }
$script:supervisorSource = Join-Path $script:uiRoot 'BridgeSupervisor.cs'
$script:mainXamlPath = Join-Path $script:uiRoot 'MainWindow.xaml'
$script:settingsXamlPath = Join-Path $script:uiRoot 'SettingsWindow.xaml'
foreach ($path in @($script:supervisorSource, $script:mainXamlPath, $script:settingsXamlPath)) {
    if (-not [System.IO.File]::Exists($path)) { throw "缺少桌面界面文件：$path" }
}

Import-Module -Name $script:modulePath -Force
$validatedDiagnosticDirectory = if ($RoutingDiagnostic) {
    Test-UiRoutingDiagnosticConfigDirectory -Directory $UserConfigDirectory -PackageRoot $script:packageRoot -RequireFixture:$RoutingDiagnosticAutoTest
} else { $UserConfigDirectory }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if (-not ('WirexBridge.Ui.BridgeSupervisor' -as [type])) { Add-Type -Path $script:supervisorSource }
$script:workAreaWidth = [double][System.Windows.SystemParameters]::WorkArea.Width
$script:workAreaHeight = [double][System.Windows.SystemParameters]::WorkArea.Height
if (-not [string]::IsNullOrWhiteSpace($RenderWorkArea)) {
    if (-not $RenderOnly -or $RenderWorkArea -cnotmatch '^([1-9][0-9]{2,4})x([1-9][0-9]{2,4})$') {
        throw '-RenderWorkArea 只接受 RenderOnly 使用的宽x高测试尺寸。'
    }
    $script:workAreaWidth = [Math]::Min($script:workAreaWidth, [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture))
    $script:workAreaHeight = [Math]::Min($script:workAreaHeight, [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture))
}
$script:maxWindowWidth = [Math]::Max(1, [Math]::Floor($script:workAreaWidth * 0.95))
$script:maxWindowHeight = [Math]::Max(1, [Math]::Floor($script:workAreaHeight * 0.95))

$script:configDirectory = Get-BridgeUserConfigDirectory -UserConfigDirectory $validatedDiagnosticDirectory -ScriptRoot $script:packageRoot
$script:profilePath = Join-Path $script:configDirectory 'connection-profile.json'
$script:audioSettingsPath = Join-Path $script:configDirectory 'audio-settings.json'
$script:identityModulePath = Join-Path $script:uiRoot 'RadioIdentity.psm1'
$script:identityCachePath = Join-Path $script:configDirectory 'radio-identity-cache.json'
$script:channelFavoritesPath = Join-Path $script:configDirectory 'channel-favorites.json'
if ([System.IO.File]::Exists($script:identityModulePath)) {
    Import-Module -Name $script:identityModulePath -Force
    $script:radioIdentityModuleLoaded = $true
    if (Get-Command -Name Get-RadioIdentityCachePath -ErrorAction SilentlyContinue) {
        $script:identityCachePath = Get-RadioIdentityCachePath -UserConfigDirectory $script:configDirectory
    }
}
$script:passwordPointerPath = Join-Path $script:configDirectory 'password-file-path.txt'
$script:releasePointerPath = Join-Path $script:configDirectory 'bridge-directory.txt'
$script:releaseDirectory = Resolve-UiRuntimeDirectory -PackageRoot $script:packageRoot `
    -UserConfigDirectory $script:configDirectory -PackageDirectoryWasExplicit $script:packageDirectoryWasExplicit
$script:releaseLauncher = Join-Path $script:releaseDirectory 'start-bm-radio-bridge.ps1'
$script:nativeExecutable = Join-Path $script:releaseDirectory 'wirex_bridge.exe'
if (-not [System.IO.File]::Exists($script:releaseLauncher) -or -not [System.IO.File]::Exists($script:nativeExecutable)) {
    throw '所选便携目录缺少桥接启动脚本或 native 核心。'
}

$script:application = New-Object System.Windows.Application
$script:application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$script:mainWindow = $null
$script:settingsWindow = $null
$script:supervisor = $null
$script:stopTask = $null
$script:preparePowerShell = $null
$script:prepareAsync = $null
$script:prepareStopAsync = $null
$script:prepareStopStartedUtc = [DateTime]::MinValue
$script:abandonPreparationAtShutdown = $false
$script:deviceDiscoveryPowerShell = $null
$script:deviceDiscoveryAsync = $null
$script:deviceDiscoveryStopAsync = $null
$script:deviceDiscoveryStartedUtc = [DateTime]::MinValue
$script:deviceDiscoveryState = 'not_started'
$script:deviceDiscoveryError = ''
$script:deviceCatalog = $null
$script:deviceAudioQuery = $null
$script:deviceDiscoveryGeneration = [uint64]0
$script:deviceDiscoveryActiveGeneration = [uint64]0
$script:deviceDiscoveryOwnerWindow = $null
$script:deviceDiscoveryRestartPending = $false
$script:deviceDiscoveryStopReason = ''
$script:deviceDiscoveryStopStartedUtc = [DateTime]::MinValue
$script:closingAfterDeviceDiscovery = $false
$script:statusStream = $null
$script:statusPath = ''
$script:preparedRunDirectory = ''
$script:statusOffset = [int64]0
$script:partialStatusLine = ''
$script:currentRunId = ''
$script:lastSequence = [uint64]0
$script:controlRunId = ''
$script:controlLastSequence = [uint64]0
$script:controlConfirmed = $false
$script:controlCapabilities = ''
$script:quickCallCapabilities = $false
$script:pendingQuickCall = $null
$script:pendingDynamicLocalListen = $null
$script:pendingDynamicCallTarget = $null
$script:controlDiagnostic = $false
$script:controlOverflowHandled = $false
$script:pendingControlRequests = @{}
$script:resolvedTimedOutRoutingRequests = @{}
$script:pendingStatusRequestId = ''
$script:pendingRoutingStatusRequestId = ''
$script:routingCapabilities = $false
$script:activeRouting = $null
$script:editRxPolicy = $null
$script:editTxTarget = $null
$script:editTransmitEnabled = $true
$script:txEditorDirty = $false
$script:pendingRoutingMutation = $null
$script:timedOutRoutingMutations = @{}
$script:routingDraftPreservedAfterTimeout = $false
$script:routingDraftAfterTimeout = $null
$script:routingMutationFence = $false
$script:routingLastUpdateUtc = [DateTime]::MinValue
$script:routingDiagnosticAutoTestStarted = $false
$script:routingDiagnosticAutoTestPhase = 0
$script:routingDiagnosticOfflineCancelVerified = $false
$script:routingDiagnosticFenceProbeWaiting = $false
$script:routingDiagnosticFenceProbeVerified = $false
$script:routingDiagnosticDynamicGroupBeforeActivation = ''
$script:routingDiagnosticDynamicGroupBeforeListen = ''
$script:routingDiagnosticDynamicGroupLocalListenCommand = ''
$script:routingDiagnosticDynamicGroupActivationResponse = $null
$script:routingDiagnosticDynamicGroupTest = $null
$script:profileEditable = $true
$script:profileWriteAllowed = $true
$script:receiveEditorState = $null
$script:lastStatusUtc = [DateTime]::MinValue
$script:latestStatus = $null
$script:storedProfile = $null
$script:effectiveProfile = $null
$script:activeProfile = $null
$script:pendingCallTarget = $null
$script:loadingCallTargetSelection = $false
$script:savedPlaybackGainMilli = $null
$script:reportedPlaybackGainMilli = $null
$script:reportedPlaybackClippedSamples = $null
$script:callIdentityCache = @{}
$script:identityQuery = $null
$script:identityQueryQueue = New-Object 'System.Collections.Generic.List[object]'
$script:identityQueuedById = @{}
$script:identityFailureCooldown = @{}
$script:identityQuerySequence = [uint64]0
$script:identityQueueLimit = 16
$script:identityRequestIntervalMs = 1000
$script:identityNextRequestUtc = [DateTime]::MinValue
$script:identityHttpTimeoutSec = 5
$script:identityQueueCooldownSeconds = 30
$script:identityQueueCooldownMaxSeconds = 900
$script:identityApiBaseUri = 'https://radioid.net/api/dmr/user/'
$script:identityDiagnosticPath = Join-Path $script:configDirectory 'identity-query-errors.jsonl'
$script:closingAfterIdentityQuery = $false
$script:channelFavorites = @()
$script:channelFavoritesLoadError = ''
$script:updatingChannelFavorites = $false
$script:callHistoryKeys = @{}
$script:passwordPath = ''
$script:allowWindowClose = $false
$script:closingAfterStop = $false
$script:startupNeedsSettings = $false
$script:preparationStarted = $false
$script:targetLabel = '尚未设置'
$script:activeTargetLabel = ''
$script:activeTargetTag = ''
$script:reconnectAfterStop = $false
$script:lastUiBmState = ''
$script:lastUiHriState = ''
$script:runLogItems = 0
$script:stopButtonActionPending = $false

function Import-WpfWindow {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [Windows.Markup.XamlReader]::Load($stream) }
    finally { $stream.Dispose() }
}

function Fit-WpfWindowToWorkArea {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window)
    $Window.MinWidth = [Math]::Min($Window.MinWidth, $script:maxWindowWidth)
    $Window.MinHeight = [Math]::Min($Window.MinHeight, $script:maxWindowHeight)
    $Window.MaxWidth = $script:maxWindowWidth
    $Window.MaxHeight = $script:maxWindowHeight
    $Window.Width = [Math]::Min($Window.Width, $script:maxWindowWidth)
    $Window.Height = [Math]::Min($Window.Height, $script:maxWindowHeight)
    $eventList = $Window.FindName('EventList')
    if ($null -ne $eventList) {
        $eventList.Height = if ($script:maxWindowHeight -le 720) { 44 } else { 94 }
    }
    if ($null -ne $Window.FindName('StatusCards') -and $script:maxWindowHeight -le 720) {
        $rootGrid = $Window.Content -as [System.Windows.Controls.Grid]
        $rootGrid.Margin = [System.Windows.Thickness]::new(12.0)
        $rootGrid.RowDefinitions[2].Height = [System.Windows.GridLength]::Auto
        $Window.FindName('StatusCards').Margin = [System.Windows.Thickness]::new(0.0, 0.0, 0.0, 5.0)
        foreach ($name in @('CoreStatusCard','RadioStatusCard','AudioStatusCard','BmStatusCard')) {
            $Window.FindName($name).Padding = [System.Windows.Thickness]::new(4.0)
        }
        $dashboard = $Window.FindName('DashboardPanel')
        $dashboard.Padding = [System.Windows.Thickness]::new(10.0)
        $dashboard.Margin = [System.Windows.Thickness]::new(0.0, 0.0, 0.0, 6.0)
        $targetValue = $Window.FindName('TargetValue')
        $targetValue.FontSize = 16
        $targetValue.Margin = [System.Windows.Thickness]::new(0.0, 2.0, 0.0, 0.0)
        foreach ($name in @('ReceiveTargetValue', 'TransmitTargetValue', 'TransmitPermissionValue')) {
            $summary = $Window.FindName($name)
            $summary.FontSize = 11
            $summary.Margin = [System.Windows.Thickness]::new(0.0, 1.0, 0.0, 0.0)
        }
        $Window.FindName('RoutingRevisionValue').Visibility = [Windows.Visibility]::Collapsed
        $activeLease = $Window.FindName('ActiveLeaseValue')
        $activeLease.FontSize = 9
        $activeLease.Margin = [System.Windows.Thickness]::new(0.0, 1.0, 0.0, 0.0)
        $dynamicGroupPanel = $Window.FindName('DynamicGroupPanel')
        $dynamicGroupPanel.Padding = [System.Windows.Thickness]::new(2.0)
        $dynamicGroupPanel.Margin = [System.Windows.Thickness]::new(0.0, 2.0, 0.0, 0.0)
        $Window.FindName('DynamicGroupHelpText').Visibility = [Windows.Visibility]::Collapsed
        $Window.FindName('DynamicGroupSlotBox').Height = 26
        foreach ($name in @('AddListenGroupButton','ActivateDynamicGroupButton')) {
            $Window.FindName($name).Padding = [System.Windows.Thickness]::new(6.0, 3.0, 6.0, 3.0)
        }
        $Window.FindName('DynamicGroupStatus').FontSize = 9
        $Window.FindName('ControlProtocolValue').FontSize = 10
        $Window.FindName('ControlProtocolValue').Margin = [System.Windows.Thickness]::new(0.0, 2.0, 0.0, 2.0)
        $Window.FindName('ControlStatusButton').Height = 23
        $trafficCard = $Window.FindName('TrafficCard')
        $trafficCard.Padding = [System.Windows.Thickness]::new(6.0)
        $trafficValue = $Window.FindName('TrafficValue')
        $trafficValue.FontSize = 17
        $trafficValue.Margin = [System.Windows.Thickness]::new(0.0, 4.0, 0.0, 2.0)
        $Window.FindName('TrafficDetail').FontSize = 11
        $Window.FindName('RadioStateValue').Margin = [System.Windows.Thickness]::new(0.0, 5.0, 0.0, 0.0)
        $Window.FindName('CurrentCallLabel').Margin = [System.Windows.Thickness]::new(0.0, 5.0, 0.0, 0.0)
        $currentCallValue = $Window.FindName('CurrentCallValue')
        $currentCallValue.FontSize = 13
        $currentCallValue.Margin = [System.Windows.Thickness]::new(0.0, 1.0, 0.0, 1.0)
        $Window.FindName('CurrentCallDetail').FontSize = 11
    }
}

function ConvertTo-UiBoundsRecord {
    param([System.Windows.Rect]$Bounds)
    if ($Bounds.IsEmpty) {
        return [pscustomobject][ordered]@{ x = 0.0; y = 0.0; width = 0.0; height = 0.0; right = 0.0; bottom = 0.0 }
    }
    return [pscustomobject][ordered]@{
        x = [double]$Bounds.X; y = [double]$Bounds.Y
        width = [double]$Bounds.Width; height = [double]$Bounds.Height
        right = [double]$Bounds.Right; bottom = [double]$Bounds.Bottom
    }
}

function Get-WpfElementLayoutEvidence {
    param(
        [Parameter(Mandatory=$true)][System.Windows.Window]$Window,
        [Parameter(Mandatory=$true)][System.Windows.FrameworkElement]$Element
    )
    $localBounds = [System.Windows.Rect]::new(0.0, 0.0, [double]$Element.ActualWidth, [double]$Element.ActualHeight)
    $actualBounds = $Element.TransformToAncestor($Window).TransformBounds($localBounds)
    $visibleBounds = $actualBounds
    $ancestor = [System.Windows.Media.VisualTreeHelper]::GetParent($Element)
    while ($null -ne $ancestor) {
        if ($ancestor -is [System.Windows.FrameworkElement]) {
            $ancestorLocalBounds = [System.Windows.Rect]::new(0.0, 0.0, [double]$ancestor.ActualWidth, [double]$ancestor.ActualHeight)
            $ancestorBounds = $ancestor.TransformToAncestor($Window).TransformBounds($ancestorLocalBounds)
            $visibleBounds.Intersect($ancestorBounds)
        }
        if ([object]::ReferenceEquals($ancestor, $Window)) { break }
        if ($ancestor -is [System.Windows.Media.Visual]) {
            $ancestor = [System.Windows.Media.VisualTreeHelper]::GetParent($ancestor)
        } else {
            break
        }
    }
    return [pscustomobject][ordered]@{
        actual = ConvertTo-UiBoundsRecord -Bounds $actualBounds
        visible = ConvertTo-UiBoundsRecord -Bounds $visibleBounds
        fully_visible = (-not $actualBounds.IsEmpty -and -not $visibleBounds.IsEmpty -and
            [Math]::Abs($actualBounds.X - $visibleBounds.X) -le 1.0 -and
            [Math]::Abs($actualBounds.Y - $visibleBounds.Y) -le 1.0 -and
            [Math]::Abs($actualBounds.Right - $visibleBounds.Right) -le 1.0 -and
            [Math]::Abs($actualBounds.Bottom - $visibleBounds.Bottom) -le 1.0)
    }
}

function Get-WpfWindowLayoutInfo {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window, [Parameter(Mandatory=$true)][string[]]$ControlNames)
    $visibility = [ordered]@{}
    $bounds = [ordered]@{}
    foreach ($name in $ControlNames) {
        $control = $Window.FindName($name)
        $visibility[$name] = ($null -ne $control -and $control.IsVisible)
        if ($control -is [System.Windows.FrameworkElement]) {
            if ($control.IsVisible) {
                $evidence = Get-WpfElementLayoutEvidence -Window $Window -Element $control
            } else {
                $evidence = [pscustomobject][ordered]@{ actual=$null; visible=$null; fully_visible=$false }
            }
            if ($control -is [System.Windows.Controls.Button]) {
                $evidence | Add-Member -NotePropertyName content_available_height -NotePropertyValue ([double](
                    $control.ActualHeight - $control.Padding.Top - $control.Padding.Bottom -
                    $control.BorderThickness.Top - $control.BorderThickness.Bottom))
                $evidence | Add-Member -NotePropertyName font_size -NotePropertyValue ([double]$control.FontSize)
                $evidence | Add-Member -NotePropertyName visual_text -NotePropertyValue @(Get-UiVisualTextValues -Root $control)
            }
            if ($control -is [System.Windows.Controls.TextBox]) {
                $evidence | Add-Member -NotePropertyName text -NotePropertyValue ([string]$control.Text)
                if ($control.Background -is [System.Windows.Media.SolidColorBrush]) {
                    $evidence | Add-Member -NotePropertyName background_color -NotePropertyValue $control.Background.Color.ToString()
                }
                if ($control.Foreground -is [System.Windows.Media.SolidColorBrush]) {
                    $evidence | Add-Member -NotePropertyName foreground_color -NotePropertyValue $control.Foreground.Color.ToString()
                }
                if ($control.BorderBrush -is [System.Windows.Media.SolidColorBrush]) {
                    $evidence | Add-Member -NotePropertyName border_color -NotePropertyValue $control.BorderBrush.Color.ToString()
                }
            }
            if ($control -is [System.Windows.Controls.TextBlock]) {
                $evidence | Add-Member -NotePropertyName text -NotePropertyValue ([string]$control.Text)
            }
            if ($control -is [System.Windows.Controls.ComboBox]) {
                $selectedText = if ($control.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) {
                    [string]$control.SelectedItem.Content
                } else { '' }
                $evidence | Add-Member -NotePropertyName selected_text -NotePropertyValue $selectedText
            }
            if ($name -ceq 'DynamicGroupPanel') {
                $evidence | Add-Member -NotePropertyName visual_text -NotePropertyValue @(Get-UiVisualTextValues -Root $control)
            }
            $bounds[$name] = $evidence
        }
    }
    $eventList = $Window.FindName('EventList')
    return [pscustomobject][ordered]@{
        width = [double]$Window.ActualWidth
        height = [double]$Window.ActualHeight
        controls_visible = [pscustomobject]$visibility
        controls_bounds = [pscustomobject]$bounds
        event_list_height = if ($null -ne $eventList) { [double]$eventList.ActualHeight } else { $null }
    }
}

function Get-UiControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:mainWindow.FindName($Name)
    if ($null -eq $control) { throw "主窗口缺少控件 $Name。" }
    return $control
}

function Get-SettingsControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:settingsWindow.FindName($Name)
    if ($null -eq $control) { throw "设置窗口缺少控件 $Name。" }
    return $control
}

function Set-MainText {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $control = Get-UiControl -Name $Name
    $value = ([string]$Text).Trim()
    if ($Name -ceq 'FooterText') {
        if ($value -match '已保存') { $value = '已保存' }
        elseif ($value -notmatch '失败|超时|未能|无效|拒绝|中断|错误|请先|请打开|不能|无法|未退出|需要修正') { $value = '' }
    }
    if ($Name -ceq 'AudioValue' -and $value -ceq '未知') { $value = '' }
    if ($Name -in @('CallTargetStatusValue','ChannelFavoritesStatusValue','FooterText') -and $value.Length -gt 96) {
        $value = $value.Substring(0,93) + '…'
    }
    $control.Text = $value
    if ($Name -in @('ReceiveTargetValue','TransmitTargetValue','TransmitPermissionValue','CallTargetStatusValue','ActiveLeaseValue','ChannelFavoritesStatusValue','FooterText')) {
        $control.Visibility = if ([string]::IsNullOrWhiteSpace($value)) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    }
    $statusCardName = switch ($Name) {
        'CoreValue' { 'CoreStatusCard' }
        'RadioValue' { 'RadioStatusCard' }
        'BmValue' { 'BmStatusCard' }
        default { '' }
    }
    if ($statusCardName -and $script:mainWindow) {
        $card = $script:mainWindow.FindName($statusCardName)
        if ($card) { $card.Visibility = if ($value) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        $statusCards = $script:mainWindow.FindName('StatusCards')
        if ($statusCards) {
            $visibleCount = 0
            foreach ($name in @('CoreStatusCard','RadioStatusCard','BmStatusCard')) {
                $candidate = $script:mainWindow.FindName($name)
                if ($candidate -and $candidate.Visibility -ne [System.Windows.Visibility]::Collapsed) { $visibleCount++ }
            }
            $statusCards.Columns = [Math]::Max(1,[Math]::Min(3,$visibleCount))
        }
    }
}

function Add-UiEvent {
    param([Parameter(Mandatory=$true)][string]$Text)
    $list = Get-UiControl -Name 'EventList'
    $stamp = [DateTime]::Now.ToString('HH:mm:ss')
    [void]$list.Items.Add(($stamp + '  ' + $Text))
    while ($list.Items.Count -gt 12) { $list.Items.RemoveAt(0) }
}

function Get-VisibleUiEventText {
    param([string]$EventName)
    switch -CaseSensitive ($EventName) {
        'preflight_passed' { return '设备选择已核对' }
        'started' { return '桥接已启动' }
        'hri_y0_observed_radio_speaker_ready' { return '电台音频输出已就绪' }
        'tx_started_from_radio_ptt_down' { return '手咪开始发送' }
        'tx_audio_draining_after_radio_ptt_release' { return '手咪已松开，正在完成发送' }
        'hri_t3_observed_playback_enabled' { return '电台开始播放来话' }
        'lcd_source_identity_prepared_for_this_call' { return '本次来话来源标签已准备' }
        'downlink_call_drained_t0_observed' { return '本次来话播放结束' }
        'radio_ptt_call_120s_limit_reached_release_required' { return '单次发送到达时限，请松开手咪后再讲话' }
        'shutdown_requested' { return '正在停止桥接' }
        'stopped' { return '桥接已停止' }
        'stopped_with_failure' { return '桥接因错误停止' }
        'stopped_after_runtime_exception' { return '桥接遇到错误并已停止' }
        'bm_session_never_ready_no_connection_confirmed' { return 'BM 未能建立连接' }
        'downlink_rejected_without_ready_radio_waveout' { return '电台音频输出尚未就绪，来话未播放' }
        'tx_start_rejected_busy_or_endpoint_not_ready' { return '发送未开始，当前设备尚未就绪' }
        'radio_ptt_down_rejected_busy_release_required' { return '本次发送未开始，请松开手咪后重新按下' }
        'downlink_call_bounded_cleanup_incomplete' { return '来话结束清理未完成' }
        'playback_cancelled_and_queue_cleared' { return '来话播放已停止' }
        default { return '' }
    }
}

function Set-ConnectionButtonState {
    $button = Get-UiControl 'ConnectButton'
    if ($OfflinePreview -or $NoAutoConnect) {
        $button.IsEnabled = $false
        $button.Content = '连接'
        return
    }
    if ($script:preparationStarted -or $script:stopTask -or $script:prepareStopAsync) {
        $button.IsEnabled = $false
        $button.Content = '正在处理'
        return
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        $button.IsEnabled = $true
        $button.Content = if ($script:activeTargetTag -and $script:activeTargetTag -cne (Get-SelectedTargetTag)) { '切换目标' } else { '重新连接' }
        return
    }
    $button.IsEnabled = $true
    $button.Content = '连接'
}

function Set-OfflineDisplay {
    param([string]$Reason = '核心尚未启动。')
    Set-MainText -Name 'CoreValue' -Text '未启动'
    Set-MainText -Name 'CoreDetail' -Text ''
    Set-MainText -Name 'RadioValue' -Text ''
    Set-MainText -Name 'RadioDetail' -Text ''
    Set-MainText -Name 'AudioValue' -Text ''
    Set-MainText -Name 'AudioDetail' -Text ''
    Update-UiPlaybackGainDisplay -Record $null
    Set-MainText -Name 'BmValue' -Text ''
    Set-MainText -Name 'BmDetail' -Text ''
    Set-MainText -Name 'RecentCaller' -Text ''
    Set-MainText -Name 'RecentCallDetail' -Text ''
    Set-MainText -Name 'CurrentCallValue' -Text ''
    Set-MainText -Name 'CurrentCallDetail' -Text ''
    Set-UiIdentityRowVisibility -Row 'current' -Visibility ([System.Windows.Visibility]::Collapsed)
    Set-UiIdentityRowVisibility -Row 'recent' -Visibility ([System.Windows.Visibility]::Collapsed)
    Clear-UiIdentityError
    Set-MainText -Name 'HriSourceIdentityValue' -Text ''
    Set-MainText -Name 'RadioDisplayValue' -Text ''
    Set-MainText -Name 'TrafficValue' -Text ''
    Set-MainText -Name 'TrafficDetail' -Text ''
    Set-MainText -Name 'RadioStateValue' -Text ''
    Set-MainText -Name 'FooterText' -Text ''
    Set-MainText -Name 'CallTargetStatusValue' -Text ''
    Set-MainText -Name 'ActiveLeaseValue' -Text ''
    Set-MainText -Name 'RunValue' -Text '未启动'
    Set-MainText -Name 'FreshnessValue' -Text ''
    Update-UiReceiveMetricsDisplay -Record $null
    Update-CallTargetChoices
    Update-UiChannelFavoriteControls
    Update-UiIdentityActionState
}

function Format-ProfileTarget {
    param([object]$Profile)
    if ($null -eq $Profile) { return '尚未设置' }
    $target = $Profile.tx_target
    $slot = [uint64]$target.slot
    if ($target.kind -ceq 'private') {
        return ('单呼目标 {0} · TS{1}' -f $target.destination_id, $slot)
    }
    return ('TG {0} · TS{1}' -f $target.destination_id, $slot)
}

function Format-ProfileReceiveTarget {
    param([object]$Profile)
    if ($null -eq $Profile -or $null -eq $Profile.rx_policy) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    $policy = $Profile.rx_policy
    if ($policy.group_mode -ceq 'all_delivered') { $parts.Add('全部组呼') }
    elseif (@($policy.allow_groups).Count -eq 0) { $parts.Add('未选组呼') }
    else {
        $groupText = @($policy.allow_groups | ForEach-Object { 'TG {0} · TS{1}' -f $_.destination_id, $_.slot }) -join '、'
        $parts.Add($groupText)
    }
    switch -CaseSensitive ([string]$policy.private_mode) {
        'disabled' { $parts.Add('私呼关闭') }
        'selected_peers' {
            if (@($policy.allow_private_peers).Count -gt 0) { $parts.Add('指定私呼') }
            else { $parts.Add('私呼关闭') }
        }
        'all_peers_to_local' {
            $privateRouteCount = @($policy.local_private_routes).Count
            $parts.Add($(if ($privateRouteCount -gt 0) { '私呼转本机' } else { '私呼无路由' }))
        }
    }
    return ($parts -join ' · ')
}

function Format-ProfileTransmitPermission {
    param([object]$Profile)
    if ($null -eq $Profile -or ($null -ne $Profile.PSObject.Properties['transmit_enabled'] -and -not [bool]$Profile.transmit_enabled)) {
        return '发射许可：关闭'
    }
    return '发射许可：开启'
}

function Set-MainTargetSummary {
    param([object]$Profile, [string]$OverallLabel)
    $target = if ($Profile -and $Profile.tx_target) { Format-ProfileTarget -Profile $Profile } else { '' }
    Set-MainText -Name 'TargetValue' -Text ''
    Set-MainText -Name 'ReceiveTargetValue' -Text $(if ($Profile -and $Profile.rx_policy) { Format-ProfileReceiveTarget -Profile $Profile } else { '' })
    Set-MainText -Name 'TransmitTargetValue' -Text $target
    Set-MainText -Name 'TransmitPermissionValue' -Text $(if ($Profile -and $Profile.tx_target) { Format-ProfileTransmitPermission -Profile $Profile } else { '' })
}

function Format-UiTxTarget {
    param([Parameter(Mandatory=$true)][object]$Target)
    $slot = [uint64]$Target.slot
    if ([string]$Target.kind -ceq 'private') { return ('单呼目标 {0} · TS{1}' -f $Target.destination_id,$slot) }
    return ('TG {0} · TS{1}' -f $Target.destination_id,$slot)
}

function New-UiCallTargetProfile {
    param([Parameter(Mandatory=$true)][object]$Profile, [Parameter(Mandatory=$true)][object]$Target)
    $targetCopy = [pscustomobject][ordered]@{
        destination_id=[uint64]$Target.destination_id
        kind=[string]$Target.kind
        slot=[uint64]$Target.slot
    }
    return ConvertTo-BridgeUserConnectionProfile -Connection $Profile.connection -TxTarget $targetCopy `
        -Devices $Profile.devices -RxPolicy (Copy-UiRxPolicy -Policy $Profile.rx_policy) `
        -TransmitEnabled ([bool]$Profile.transmit_enabled) -AllowTextNumbers
}

function New-UiCallTargetFromPreset {
    param([Parameter(Mandatory=$true)][string]$Preset, [object]$Profile)
    if ($Preset -ceq 'parrot-cn') {
        return [pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
    }
    if ($Preset -ceq 'custom') {
        if ($script:pendingCallTarget) {
            return [pscustomobject][ordered]@{
                destination_id=[uint64]$script:pendingCallTarget.destination_id
                kind=[string]$script:pendingCallTarget.kind
                slot=[uint64]$script:pendingCallTarget.slot
            }
        }
        if ($script:activeRouting) { return $script:activeRouting.tx_target }
        if ($Profile) { return $Profile.tx_target }
        return $null
    }
    throw ('未知的呼叫目标预设：' + $Preset)
}

function Get-UiCallTargetSummaryProfile {
    param([Parameter(Mandatory=$true)][object]$Profile, [Parameter(Mandatory=$true)][string]$Preset,
        [AllowNull()][object]$PendingTarget=$null)
    $target = if ($PendingTarget) { $PendingTarget } else { New-UiCallTargetFromPreset -Preset $Preset -Profile $Profile }
    if (-not $target) { $target = $Profile.tx_target }
    return New-UiCallTargetProfile -Profile $Profile -Target $target
}

function Format-UiGainMilli {
    param([object]$GainMilli)
    if ($null -eq $GainMilli -or $GainMilli -is [bool]) { return '未知' }
    $parsed = [uint32]0
    if (-not [uint32]::TryParse([string]$GainMilli,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$parsed) -or $parsed -lt 250 -or $parsed -gt 16000) { return '未知' }
    return (([double]$parsed / 1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture) + 'x')
}

function Update-UiPlaybackGainDisplay {
    param([object]$Record=$null)
    $runtimeText = ''
    $runtimeGain = $null
    $clippedSamples = $null
    $audioSamples = $null
    if ($Record) {
        $gainProperty = $Record.PSObject.Properties['rx_output_gain_milli']
        if ($gainProperty) {
            $gainLabel = Format-UiGainMilli -GainMilli $gainProperty.Value
            if ($gainLabel -cne '未知') {
                $runtimeGain = [uint32]$gainProperty.Value
                $clipProperty = $Record.PSObject.Properties['rx_pcm_clipped_samples']
                if ($clipProperty -and $clipProperty.Value -isnot [bool]) {
                    $parsedClipped = [uint64]0
                    if ([uint64]::TryParse([string]$clipProperty.Value,[Globalization.NumberStyles]::None,
                            [Globalization.CultureInfo]::InvariantCulture,[ref]$parsedClipped)) { $clippedSamples = $parsedClipped }
                }
                $sampleProperty = $Record.PSObject.Properties['rx_audio_samples']
                if ($sampleProperty -and $sampleProperty.Value -isnot [bool]) {
                    $parsedSamples = [uint64]0
                    if ([uint64]::TryParse([string]$sampleProperty.Value,[Globalization.NumberStyles]::None,
                            [Globalization.CultureInfo]::InvariantCulture,[ref]$parsedSamples)) { $audioSamples = $parsedSamples }
                }
                $runtimeText = '增益 ' + $gainLabel
                if ($null -ne $clippedSamples) {
                    $clipValue = [string]$clippedSamples
                    if ($null -ne $audioSamples) { $clipValue += '/' + [string]$audioSamples }
                    $runtimeText += ' · 削波 ' + $clipValue
                }
            }
        }
    }
    $script:reportedPlaybackGainMilli = $runtimeGain
    $script:reportedPlaybackClippedSamples = $clippedSamples
    if ($script:mainWindow) {
        $mainControl = $script:mainWindow.FindName('PlaybackGainStatusValue')
        if ($mainControl) {
            $mainControl.Text = $runtimeText
            $mainControl.Visibility = if ($runtimeText) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
            $mainControl.Foreground = if ($null -eq $clippedSamples) { [Windows.Media.Brushes]::LightGreen } elseif ($clippedSamples -gt 0) { [Windows.Media.Brushes]::IndianRed } else { [Windows.Media.Brushes]::LightGreen }
        }
    }
    if ($script:settingsWindow) {
        $savedControl = $script:settingsWindow.FindName('PlaybackGainSavedValueText')
        if ($savedControl) {
            $savedControl.Text = if ($null -ne $script:savedPlaybackGainMilli) { '已保存：' + (Format-UiGainMilli -GainMilli $script:savedPlaybackGainMilli) } else { '' }
            $savedControl.Visibility = if ($savedControl.Text) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }
        $runtimeControl = $script:settingsWindow.FindName('PlaybackGainRuntimeValueText')
        if ($runtimeControl) {
            $runtimeControl.Text = $runtimeText
            $runtimeControl.Visibility = if ($runtimeText) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
            $runtimeControl.Foreground = if ($null -eq $clippedSamples) { [Windows.Media.Brushes]::LightGreen } elseif ($clippedSamples -gt 0) { [Windows.Media.Brushes]::IndianRed } else { [Windows.Media.Brushes]::LightGreen }
        }
    }
}

function Update-UiCallHistoryActionState {
    if (-not $script:mainWindow) { return }
    $history = $script:mainWindow.FindName('CallHistoryList')
    $button = $script:mainWindow.FindName('SetHistoryCallTargetButton')
    if (-not $history -or -not $button) { return }
    $entry = $history.SelectedItem
    $valid = ($entry -and $entry.PSObject.Properties['source_id'] -and $entry.PSObject.Properties['destination_id'] -and $entry.PSObject.Properties['kind'])
    $isListenOnly = $valid -and [string]$entry.kind -ceq 'group' -and [uint64]$entry.destination_id -in @(91,46001)
    $button.IsEnabled = ($valid -and -not $isListenOnly -and -not $script:pendingRoutingMutation -and -not $script:routingMutationFence)
    $button.ToolTip = if ($isListenOnly) { 'TG91 与 TG46001 用于本机收听。' } else { '设置所选来话的来源或组号为呼叫目标，并沿用记录中的 TS。' }
    $queryButton = $script:mainWindow.FindName('QueryHistoryIdentityButton')
    if ($queryButton) {
        $queryButton.IsEnabled = ($valid -and -not $script:identityQuery -and $script:radioIdentityModuleLoaded)
    }
}

function Get-UiRadioIdentity {
    param([Parameter(Mandatory=$true)][uint64]$RadioId)
    if (-not $script:radioIdentityModuleLoaded -or -not (Get-Command -Name Resolve-RadioIdentity -ErrorAction SilentlyContinue)) { return $null }
    if ($RadioId -lt 1 -or $RadioId -gt 16777215) { return $null }
    $key = $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($script:callIdentityCache.ContainsKey($key)) { return $script:callIdentityCache[$key] }
    try {
        $identity = Resolve-RadioIdentity -RadioId ([uint32]$RadioId) -CachePath $script:identityCachePath
        if ($identity) { $script:callIdentityCache[$key] = $identity; return $identity }
    } catch { }
    return $null
}

function Format-UiRadioIdentity {
    param([Parameter(Mandatory=$true)][uint64]$RadioId)
    $fallback = 'DMR ID ' + $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $identity = Get-UiRadioIdentity -RadioId $RadioId
    if (-not $identity -or [string]$identity.status -cnotin @('found','stale')) { return $fallback }
    $label = [string]$identity.callsign
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$identity.display_name }
    if ([string]::IsNullOrWhiteSpace($label) -or $label -ceq $fallback) { return $fallback }
    return ($label + ' · ' + $fallback)
}

function Format-UiRadioIdentityDetails {
    param([Parameter(Mandatory=$true)][uint64]$RadioId,[AllowNull()][object]$Identity=$null)
    if (-not $Identity) { $Identity = Get-UiRadioIdentity -RadioId $RadioId }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add(('DMR ID {0}' -f $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)))
    if ($Identity) {
        foreach ($field in @(
            [pscustomobject]@{ name='callsign'; label='呼号' },
            [pscustomobject]@{ name='name'; label='姓名' }
        )) {
            $property = $Identity.PSObject.Properties[[string]$field.name]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $lines.Add(([string]$field.label + '：' + [string]$property.Value))
            }
        }
        $location = New-Object 'System.Collections.Generic.List[string]'
        foreach ($field in @(
            [pscustomobject]@{ name='country'; label='国家' },
            [pscustomobject]@{ name='state'; label='州/省' },
            [pscustomobject]@{ name='city'; label='城市' }
        )) {
            $property = $Identity.PSObject.Properties[[string]$field.name]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $location.Add([string]$field.label + ' ' + [string]$property.Value)
            }
        }
        if ($location.Count -gt 0) { $lines.Add('地区：' + ($location -join ' · ')) }
        if ($Identity.PSObject.Properties['source'] -and -not [string]::IsNullOrWhiteSpace([string]$Identity.source)) {
            $sourceText = switch -CaseSensitive ([string]$Identity.source) {
                'radioid-api' { 'Radio ID 单条查询' }
                'local-cache' { '本机缓存' }
                'user-file' { '用户导入文件' }
                default { [string]$Identity.source }
            }
            $lines.Add('资料来源：' + $sourceText)
        }
        $fetchedProperty = $Identity.PSObject.Properties['fetched_at_utc']
        if ($fetchedProperty -and -not [string]::IsNullOrWhiteSpace([string]$fetchedProperty.Value)) {
            $fetched = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$fetchedProperty.Value,[Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$fetched)) {
                $lines.Add('更新时间：' + $fetched.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))
            }
        }
    }
    return ($lines -join "`n")
}

function Update-UiIdentityActionState {
    if (-not $script:mainWindow) { return }
    $queryButton = $script:mainWindow.FindName('QueryCurrentIdentityButton')
    if ($queryButton) {
        $hasCurrentCaller = ($script:supervisor -and -not $script:supervisor.HasExited -and
            $script:lastStatusUtc -ne [DateTime]::MinValue -and ([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3 -and
            $script:latestStatus -and [bool]$script:latestStatus.current_call_valid -and
            [uint64]$script:latestStatus.current_call_source_id -ge 1)
        $queryButton.IsEnabled = ($hasCurrentCaller -and -not $script:identityQuery -and $script:radioIdentityModuleLoaded)
    }
    Update-UiCallHistoryActionState
}

function Add-UiIdentityDiagnostic {
    param([Parameter(Mandatory=$true)][string]$Stage,[Parameter(Mandatory=$true)][string]$ErrorCode,
        [string]$ErrorType='', [string]$Detail='')
    try {
        if ([string]::IsNullOrWhiteSpace($script:identityDiagnosticPath)) { return }
        $directory = [System.IO.Path]::GetDirectoryName($script:identityDiagnosticPath)
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [System.IO.Directory]::Exists($directory)) { return }
        if ([System.IO.File]::Exists($script:identityDiagnosticPath) -and
            (New-Object System.IO.FileInfo($script:identityDiagnosticPath)).Length -ge 262144) { return }
        $safeDetail = [string]$Detail
        $safeDetail = $safeDetail -replace '(?i)https?://[^\s]+','[请求地址]'
        $safeDetail = $safeDetail -replace '(?i)(callsign|name|city|state|country)\s*[:=]\s*[^,;\s]+','$1=[已隐藏]'
        $safeDetail = $safeDetail -replace '(?i)(?:DMR\s*ID\s*)?\b[0-9]{6,9}\b','[ID]'
        $safeDetail = $safeDetail -replace '[\x00-\x1F\x7F]',' '
        if ($safeDetail.Length -gt 240) { $safeDetail = $safeDetail.Substring(0,240) }
        $record = [pscustomobject][ordered]@{
            timestamp_utc = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            stage = $Stage; error_code = $ErrorCode; error_type = $ErrorType; detail = $safeDetail
        }
        $line = ConvertTo-Json -InputObject $record -Compress -Depth 3
        [System.IO.File]::AppendAllText($script:identityDiagnosticPath,$line + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Set-UiIdentityError {
    param([Parameter(Mandatory=$true)][string]$ErrorCode,[string]$Message='',
        [string]$ErrorType='', [string]$Detail='', [string]$Stage='query',[switch]$ShowToUser)
    Add-UiIdentityDiagnostic -Stage $Stage -ErrorCode $ErrorCode -ErrorType $ErrorType -Detail $Detail
    if (-not $ShowToUser -or -not $script:mainWindow) { return }
    $status = $script:mainWindow.FindName('IdentityLookupStatusValue')
    if (-not $status) { return }
    $text = switch -CaseSensitive ($ErrorCode) {
        'timeout' { '查询超时' }
        'network' { '网络查询失败' }
        'invalid_response' { '资料服务响应无效' }
        'cache_write' { '本机资料缓存保存失败' }
        'queue_full' { '资料查询队列已满' }
        'module_missing' { '资料模块不可用' }
        'worker_start' { '资料查询无法启动' }
        'query_contract' { '资料查询结果无效' }
        'cleanup_failed' { '资料查询清理失败' }
        default {
            if ($ErrorCode -match '^http_([0-9]{3})$') { '资料服务返回 HTTP ' + $Matches[1] }
            elseif (-not [string]::IsNullOrWhiteSpace($Message)) { $Message }
            else { '资料查询失败' }
        }
    }
    if ($text.Length -gt 64) { $text = $text.Substring(0,64) }
    $status.Text = $text
    $status.Visibility = [System.Windows.Visibility]::Visible
    Set-UiIdentityRowVisibility -Row 'status'
}

function Clear-UiIdentityError {
    if (-not $script:mainWindow) { return }
    $status = $script:mainWindow.FindName('IdentityLookupStatusValue')
    if (-not $status) { return }
    $status.Text = ''
    $status.Visibility = [System.Windows.Visibility]::Collapsed
}

function Set-UiIdentityRowVisibility {
    param([ValidateSet('current','recent','history','history_actions','status')][string]$Row,
        [System.Windows.Visibility]$Visibility=[System.Windows.Visibility]::Visible)
    if (-not $script:mainWindow) { return }
    $name = switch ($Row) {
        'current' { 'CurrentCallPanel' }
        'recent' { 'RecentCallPanel' }
        'history' { 'HistoryPanel' }
        'history_actions' { 'HistoryActionsPanel' }
        'status' { 'IdentityLookupStatusValue' }
    }
    $control = $script:mainWindow.FindName($name)
    if ($control -and $control.PSObject.Properties['Visibility']) { $control.Visibility = $Visibility }
}

function Get-UiIdentityContextKey {
    param([Parameter(Mandatory=$true)][object]$Context)
    return ('{0}|{1}|{2}|{3}' -f [string]$Context.context_kind,[string]$Context.run_id,
        [uint64]$Context.generation,[string]$Context.history_key)
}

function Add-UiIdentityQueryContext {
    param([Parameter(Mandatory=$true)][object]$Query,[Parameter(Mandatory=$true)][object]$Context)
    $key = Get-UiIdentityContextKey -Context $Context
    if ($Query.context_keys.ContainsKey($key)) { return }
    [void]$Query.contexts.Add($Context)
    $Query.context_keys[$key] = $true
}

function New-UiIdentityQueryContext {
    param([Parameter(Mandatory=$true)][ValidateSet('current','history')][string]$ContextKind,
        [string]$RunId='', [uint64]$Generation=0, [string]$HistoryKey='')
    return [pscustomobject][ordered]@{
        context_kind=$ContextKind; run_id=$RunId; generation=$Generation; history_key=$HistoryKey
    }
}

function Clear-UiIdentityQueryQueue {
    if ($script:identityQueryQueue) { $script:identityQueryQueue.Clear() }
    if ($script:identityQueuedById) { $script:identityQueuedById.Clear() }
}

function Set-UiIdentityFailureCooldown {
    param([Parameter(Mandatory=$true)][uint64]$RadioId)
    $key = $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $count = 1
    if ($script:identityFailureCooldown.ContainsKey($key)) {
        $count = [Math]::Min(8,[int]$script:identityFailureCooldown[$key].failure_count + 1)
    }
    $seconds = [Math]::Min([double]$script:identityQueueCooldownMaxSeconds,
        [double]$script:identityQueueCooldownSeconds * [Math]::Pow(2,($count - 1)))
    $script:identityFailureCooldown[$key] = [pscustomobject]@{
        failure_count=$count; retry_after_utc=[DateTime]::UtcNow.AddSeconds($seconds)
    }
}

function Start-NextUiIdentityQuery {
    if ($script:identityQuery -or -not $script:identityQueryQueue -or $script:identityQueryQueue.Count -eq 0) { return }
    if ([DateTime]::UtcNow -lt $script:identityNextRequestUtc) { return }
    $item = $script:identityQueryQueue[0]
    $script:identityQueryQueue.RemoveAt(0)
    $idKey = ([uint64]$item.radio_id).ToString([Globalization.CultureInfo]::InvariantCulture)
    [void]$script:identityQueuedById.Remove($idKey)
    if (-not $script:radioIdentityModuleLoaded -or -not [System.IO.File]::Exists($script:identityModulePath)) {
        Set-UiIdentityError -ErrorCode module_missing -Stage 'worker_start'
        return
    }

    $runspace = $null
    $powerShell = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $powerShell = [System.Management.Automation.PowerShell]::Create()
        $powerShell.Runspace = $runspace
        $queryScript = @'
param([string]$ModulePath,[string]$CachePath,[uint32]$RadioId,[int]$TimeoutSec,[string]$ApiBaseUri)
Import-Module -Name $ModulePath -Force -ErrorAction Stop
Invoke-RadioIdentityQuery -RadioId $RadioId -CachePath $CachePath -TimeoutSec $TimeoutSec -ApiBaseUri $ApiBaseUri
'@
        [void]$powerShell.AddScript($queryScript).AddArgument($script:identityModulePath).
            AddArgument($script:identityCachePath).AddArgument([uint32]$item.radio_id).
            AddArgument([int]$item.timeout_seconds).AddArgument([string]$item.api_base_uri)
        $asyncHandle = $powerShell.BeginInvoke()
        $script:identityQuerySequence++
        $script:identityQuery = [pscustomobject][ordered]@{
            query_id=$script:identityQuerySequence; radio_id=[uint64]$item.radio_id
            contexts=$item.contexts; context_keys=$item.context_keys
            started_utc=[DateTime]::UtcNow; deadline_seconds=5.5; hard_deadline_seconds=8.0
            power_shell=$powerShell; owned_runspace=$runspace; async_handle=$asyncHandle
            stop_async=$null; stop_reason=''; stop_started_utc=[DateTime]::MinValue
            stop_error=''; stop_attempts=0; stop_complete=$false; end_stop_done=$false
            result_collected=$false; identity_result=$null; result_error=''; error_code=''; error_type=''; error_detail=''
            disposed=$false; terminal_state=''; cleanup_error_reported=$false
        }
        $script:identityNextRequestUtc = [DateTime]::UtcNow.AddMilliseconds([double]$script:identityRequestIntervalMs)
        Update-UiIdentityActionState
    } catch {
        if ($powerShell) { try { $powerShell.Dispose() } catch { } }
        if ($runspace) {
            try { if ($runspace.RunspaceStateInfo.State -ne 'Closed') { $runspace.Close() } } catch { }
            try { $runspace.Dispose() } catch { }
        }
        Set-UiIdentityFailureCooldown -RadioId ([uint64]$item.radio_id)
        Set-UiIdentityError -ErrorCode worker_start -ErrorType $_.Exception.GetType().FullName `
            -Detail $_.Exception.Message -Stage 'worker_start'
    }
}

function Start-UiIdentityQuery {
    param(
        [Parameter(Mandatory=$true)][uint64]$RadioId,
        [Parameter(Mandatory=$true)][ValidateSet('current','history')][string]$ContextKind,
        [string]$RunId='', [uint64]$Generation=0, [string]$HistoryKey='',
        [string]$ApiBaseUri='', [int]$TimeoutSec=0
    )
    if ($RadioId -lt 1 -or $RadioId -gt 16777215) {
        Set-UiIdentityError -ErrorCode 'query_contract' -Message '来源 DMR ID 无效' -Stage 'enqueue'
        return $false
    }
    if ($script:RenderOnly) { return $false }
    if (-not $script:radioIdentityModuleLoaded -or -not [System.IO.File]::Exists($script:identityModulePath)) {
        Set-UiIdentityError -ErrorCode module_missing -Stage 'enqueue'
        return $false
    }
    $key = $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $cached = Get-UiRadioIdentity -RadioId $RadioId
    if ($cached -and [string]$cached.status -cin @('found','not_found')) { return $false }
    if ($script:identityFailureCooldown.ContainsKey($key) -and
        [DateTime]::UtcNow -lt [DateTime]$script:identityFailureCooldown[$key].retry_after_utc) { return $false }
    $context = New-UiIdentityQueryContext -ContextKind $ContextKind -RunId $RunId `
        -Generation $Generation -HistoryKey $HistoryKey
    if ($script:identityQuery -and [uint64]$script:identityQuery.radio_id -eq $RadioId) {
        Add-UiIdentityQueryContext -Query $script:identityQuery -Context $context
        return $true
    }
    if ($script:identityQueuedById.ContainsKey($key)) {
        Add-UiIdentityQueryContext -Query $script:identityQueuedById[$key] -Context $context
        return $true
    }
    if ($script:identityQueryQueue.Count -ge [int]$script:identityQueueLimit) {
        Set-UiIdentityError -ErrorCode queue_full -Stage 'enqueue'
        return $false
    }
    $item = [pscustomobject][ordered]@{
        radio_id=$RadioId; contexts=(New-Object 'System.Collections.Generic.List[object]'); context_keys=@{}
        queued_at_utc=[DateTime]::UtcNow
        timeout_seconds=$(if ($TimeoutSec -ge 1 -and $TimeoutSec -le 5) { $TimeoutSec } else { [int]$script:identityHttpTimeoutSec })
        api_base_uri=$(if ([string]::IsNullOrWhiteSpace($ApiBaseUri)) { [string]$script:identityApiBaseUri } else { $ApiBaseUri })
    }
    Add-UiIdentityQueryContext -Query $item -Context $context
    [void]$script:identityQueryQueue.Add($item)
    $script:identityQueuedById[$key] = $item
    Start-NextUiIdentityQuery
    Update-UiIdentityActionState
    return $true
}

function Update-UiIdentityHistoryEntry {
    param([Parameter(Mandatory=$true)][string]$HistoryKey,[Parameter(Mandatory=$true)][object]$Identity)
    if (-not $script:mainWindow -or [string]::IsNullOrWhiteSpace($HistoryKey)) { return $false }
    $history = $script:mainWindow.FindName('CallHistoryList')
    if (-not $history) { return $false }
    for ($index=0; $index -lt $history.Items.Count; $index++) {
        $entry = $history.Items[$index]
        if ([string]$entry.key -cne $HistoryKey) { continue }
        $entry.source_label = Format-UiRadioIdentity -RadioId ([uint64]$entry.source_id)
        $entry.identity_details = Format-UiRadioIdentityDetails -RadioId ([uint64]$entry.source_id) -Identity $Identity
        $kindText = if ([string]$entry.kind -ceq 'private') { '私呼 至本机 DMR ID ' + $entry.destination_id } else { '组呼 TG ' + $entry.destination_id }
        $entry.text = ('{0} · {1} · TS{2} · 来源 {3}' -f $entry.timestamp.ToString('HH:mm:ss'),$kindText,$entry.slot,$entry.source_label)
        $history.Items[$index] = $entry
        Set-UiIdentityRowVisibility -Row 'history'
        return $true
    }
    return $false
}

function Test-UiIdentityResultMatchesCurrent {
    param(
        [Parameter(Mandatory=$true)][object]$Query,
        [Parameter(Mandatory=$true)][AllowNull()][object]$LatestStatus,
        [Parameter(Mandatory=$true)][bool]$SupervisorAlive,
        [Parameter(Mandatory=$true)][DateTime]$LastStatusUtc,
        [DateTime]$NowUtc=[DateTime]::UtcNow
    )
    if (-not $SupervisorAlive -or $LastStatusUtc -eq [DateTime]::MinValue -or
        ($NowUtc - $LastStatusUtc).TotalSeconds -gt 3 -or -not $LatestStatus -or
        -not $LatestStatus.PSObject.Properties['current_call_valid'] -or -not [bool]$LatestStatus.current_call_valid -or
        -not $LatestStatus.PSObject.Properties['current_call_generation']) { return $false }
    $contexts = New-Object 'System.Collections.Generic.List[object]'
    if ($Query.PSObject.Properties['contexts']) {
        foreach ($contextItem in $Query.contexts) { [void]$contexts.Add($contextItem) }
    } elseif ($Query.PSObject.Properties['context_kind'] -and [string]$Query.context_kind -ceq 'current') {
        [void]$contexts.Add($Query)
    }
    foreach ($context in $contexts) {
        if ([string]$context.context_kind -cne 'current') { continue }
        if ([string]$LatestStatus.run_id -ceq [string]$context.run_id -and
            [uint64]$LatestStatus.current_call_source_id -eq [uint64]$Query.radio_id -and
            [uint64]$LatestStatus.current_call_generation -eq [uint64]$context.generation) { return $true }
    }
    return $false
}

function Complete-UiIdentityQueryResources {
    param([Parameter(Mandatory=$true)][object]$Query)
    if ($Query.disposed) { return $true }
    if (-not $Query.async_handle.IsCompleted) { return $false }
    $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    $state = [string]$Query.power_shell.InvocationStateInfo.State
    if ($state -cnotin @('Completed','Failed','Stopped')) { return $false }
    try { $Query.power_shell.Dispose() }
    catch { [void]$cleanupErrors.Add($_.Exception.Message) }
    $runspace = $Query.owned_runspace
    if ($runspace) {
        try {
            if ([string]$runspace.RunspaceStateInfo.State -cne 'Closed') { $runspace.Close() }
            if ([string]$runspace.RunspaceStateInfo.State -cne 'Closed') { [void]$cleanupErrors.Add('owned runspace did not close') }
        } catch { [void]$cleanupErrors.Add($_.Exception.Message) }
        try { $runspace.Dispose() }
        catch { [void]$cleanupErrors.Add($_.Exception.Message) }
    }
    if ($cleanupErrors.Count -gt 0) {
        $Query.stop_error = ($cleanupErrors -join '; ')
        return $false
    }
    $Query.terminal_state = $state
    $Query.disposed = $true
    return $true
}

function Stop-UiIdentityQuery {
    param([Parameter(Mandatory=$true)][object]$Query,[Parameter(Mandatory=$true)][string]$Reason)
    if ($Query.stop_async -or $Query.stop_complete) { return }
    $Query.stop_reason = $Reason
    if ($Query.stop_started_utc -eq [DateTime]::MinValue) { $Query.stop_started_utc = [DateTime]::UtcNow }
    $Query.stop_attempts++
    try { $Query.stop_async = $Query.power_shell.BeginStop($null,$null) }
    catch {
        $Query.stop_error = $_.Exception.Message
        if ($Query.async_handle -and $Query.async_handle.IsCompleted) { $Query.stop_complete = $true }
        Add-UiIdentityDiagnostic -Stage 'stop' -ErrorCode 'stop_failed' `
            -ErrorType $_.Exception.GetType().FullName -Detail $_.Exception.Message
        if ($Reason -notin @('window_closed','stop_and_exit','shutdown')) {
            Set-UiIdentityError -ErrorCode 'cleanup_failed' -ErrorType $_.Exception.GetType().FullName `
                -Detail $_.Exception.Message -Stage 'stop'
        }
    }
}

function Complete-UiIdentityQuery {
    $query = $script:identityQuery
    if (-not $query) { Start-NextUiIdentityQuery; return }
    if (-not $query.stop_async -and $query.async_handle.IsCompleted -and -not $query.result_collected) {
        try {
            $records = @($query.power_shell.EndInvoke($query.async_handle))
            if ($query.power_shell.HadErrors -or $records.Count -ne 1 -or -not $records[0]) { throw '资料查询没有返回一条有效记录。' }
            $identity = $records[0]
            $sourceIdProperty = $identity.PSObject.Properties['source_id']
            if (-not $sourceIdProperty -or [uint64]$sourceIdProperty.Value -ne [uint64]$query.radio_id) { throw '资料查询返回的来源 ID 与请求不一致。' }
            $idProperty = $identity.PSObject.Properties['id']
            if ($idProperty -and [uint64]$idProperty.Value -ne [uint64]$query.radio_id) { throw '资料查询兼容 ID 与请求不一致。' }
            if ([string]$identity.status -cnotin @('found','not_found','stale','unavailable')) { throw '资料查询状态无效。' }
            $query.identity_result = $identity
            $query.error_code = [string]$identity.error_code
            $query.error_type = [string]$identity.error_type
            $query.error_detail = [string]$identity.error_detail
        } catch {
            $query.result_error = $_.Exception.Message
            $query.error_code = 'query_contract'
            $query.error_type = $_.Exception.GetType().FullName
            $query.error_detail = $_.Exception.Message
        }
        $query.result_collected = $true
    }
    $stopObserved = $false
    if ($query.stop_async -and $query.stop_async.IsCompleted) {
        if (-not $query.end_stop_done) {
            try { $query.power_shell.EndStop($query.stop_async) }
            catch {
                $query.stop_error = $_.Exception.Message
                Add-UiIdentityDiagnostic -Stage 'end_stop' -ErrorCode 'stop_failed' `
                    -ErrorType $_.Exception.GetType().FullName -Detail $_.Exception.Message
            }
            $query.end_stop_done = $true
        }
        $stopObserved = $true
    } elseif ($query.stop_complete) { $stopObserved = $true }
    $canDispose = ($query.async_handle.IsCompleted -and ($query.result_collected -or $stopObserved))
    $resourcesClosed = if ($canDispose) { Complete-UiIdentityQueryResources -Query $query } else { $false }
    if ($resourcesClosed) {
        $identity = $query.identity_result
        $failureCode = [string]$query.error_code
        $failureMessage = if ($identity) { [string]$identity.error_message } else { '' }
        if ($query.stop_reason -ceq 'timeout') { $failureCode = 'timeout'; $failureMessage = '查询超时' }
        elseif ($query.stop_reason -and $query.stop_reason -notin @('window_closed','stop_and_exit','shutdown')) {
            $failureCode = 'cancelled'; $failureMessage = '查询已取消'
        }
        $key = ([uint64]$query.radio_id).ToString([Globalization.CultureInfo]::InvariantCulture)
        $script:identityQuery = $null
        if ($identity) {
            $script:callIdentityCache[$key] = $identity
            if ([string]$identity.status -cin @('found','stale')) { Clear-UiIdentityError }
            foreach ($context in $query.contexts) {
                if (-not [string]::IsNullOrWhiteSpace([string]$context.history_key)) {
                    [void](Update-UiIdentityHistoryEntry -HistoryKey ([string]$context.history_key) -Identity $identity)
                }
            }
            $supervisorAlive = ($script:supervisor -and -not $script:supervisor.HasExited)
            $matchesCurrent = Test-UiIdentityResultMatchesCurrent -Query $query -LatestStatus $script:latestStatus `
                -SupervisorAlive ([bool]$supervisorAlive) -LastStatusUtc $script:lastStatusUtc
            if ($matchesCurrent) {
                Set-UiIdentityRowVisibility -Row 'current'
                Set-MainText -Name 'CurrentCallValue' -Text (Format-UiRadioIdentity -RadioId ([uint64]$query.radio_id))
            }
            $historyList = $script:mainWindow.FindName('CallHistoryList')
            $hasHistory = ($historyList -and $historyList.Items.Count -gt 0)
            if (-not $hasHistory -and $script:latestStatus -and $script:latestStatus.PSObject.Properties['last_rx_header_valid'] -and
                [bool]$script:latestStatus.last_rx_header_valid -and
                [uint64]$script:latestStatus.last_rx_source_id -eq [uint64]$query.radio_id) {
                Set-UiIdentityRowVisibility -Row 'recent'
                Set-MainText -Name 'RecentCaller' -Text (Format-UiRadioIdentity -RadioId ([uint64]$query.radio_id))
            } else {
                Set-UiIdentityRowVisibility -Row 'recent' -Visibility ([System.Windows.Visibility]::Collapsed)
            }
            if ($failureCode) {
                Set-UiIdentityFailureCooldown -RadioId ([uint64]$query.radio_id)
                Set-UiIdentityError -ErrorCode $failureCode -Message $failureMessage -ErrorType $query.error_type `
                    -Detail $query.error_detail -Stage 'lookup_result'
            } else {
                [void]$script:identityFailureCooldown.Remove($key)
                if ($identity.cache_saved -eq $false) {
                    Set-UiIdentityError -ErrorCode cache_write -ErrorType $query.error_type `
                        -Detail $query.error_detail -Stage 'cache_write'
                }
            }
        } elseif ($failureCode -or $query.result_error -or $query.stop_error) {
            if ($failureCode -and $failureCode -notin @('cancelled')) { Set-UiIdentityFailureCooldown -RadioId ([uint64]$query.radio_id) }
            if ($query.stop_reason -notin @('window_closed','stop_and_exit','shutdown')) {
                Set-UiIdentityError -ErrorCode $(if ($failureCode) { $failureCode } else { 'query_contract' }) `
                    -Message $failureMessage -ErrorType $query.error_type `
                    -Detail $(if ($query.result_error) { $query.result_error } else { $query.stop_error }) -Stage 'lookup_result'
            }
        }
        if ($query.stop_error) {
            Add-UiIdentityDiagnostic -Stage 'cleanup' -ErrorCode 'cleanup_failed' `
                -ErrorType 'System.Management.Automation.RuntimeException' -Detail $query.stop_error
        }
        Update-UiIdentityActionState
        if ($script:closingAfterIdentityQuery) {
            $script:closingAfterIdentityQuery = $false
            if (-not $script:supervisor -or $script:supervisor.HasExited) {
                Clear-UiIdentityQueryQueue
                $script:allowWindowClose = $true
                $script:mainWindow.Close()
                return
            }
        }
        Start-NextUiIdentityQuery
        return
    }

    if (-not $query.stop_async -and -not $query.stop_complete -and
        ([DateTime]::UtcNow - $query.started_utc).TotalSeconds -ge [double]$query.deadline_seconds) {
        Stop-UiIdentityQuery -Query $query -Reason 'timeout'
    }
    if (-not $resourcesClosed -and
        ([DateTime]::UtcNow - $query.started_utc).TotalSeconds -ge [double]$query.hard_deadline_seconds) {
        $closeRequested = ($script:closingAfterIdentityQuery -or $script:closingAfterStop)
        $coreCleanupFinished = ((-not $script:supervisor -or $script:supervisor.HasExited) -and
            -not $script:preparationStarted -and -not $script:stopTask)
        if (-not $query.cleanup_error_reported) {
            Add-UiIdentityDiagnostic -Stage 'hard_deadline' -ErrorCode 'cleanup_failed' `
                -ErrorType 'System.TimeoutException' -Detail $query.stop_error
            $query.cleanup_error_reported = $true
        }
        if ($closeRequested -and $coreCleanupFinished) {
            [System.Environment]::Exit(2)
        }
    }
}

function Add-UiCallHistoryRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
    if (-not $script:mainWindow -or -not [bool]$Record.current_call_valid) { return }
    $generationProperty = $Record.PSObject.Properties['current_call_generation']
    if (-not $generationProperty -or $generationProperty.Value -is [bool]) { return }
    $generation = [uint64]0
    if (-not [uint64]::TryParse([string]$generationProperty.Value,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$generation) -or $generation -eq 0) { return }
    $runId = [string]$Record.run_id
    if ([string]::IsNullOrWhiteSpace($runId)) { return }
    $key = Get-UiCallHistoryKey -RunId $runId -Generation $generation
    if ($script:callHistoryKeys.ContainsKey($key)) { return }
    $sourceId = [uint64]$Record.current_call_source_id
    if ($sourceId -lt 1 -or $sourceId -gt 16777215) {
        Add-UiIdentityDiagnostic -Stage 'enqueue' -ErrorCode 'invalid_source_id' -ErrorType 'System.ArgumentOutOfRangeException'
        return
    }
    $destinationId = [uint64]$Record.current_call_destination_id
    $slot = [uint64]$Record.current_call_slot
    $kind = if ([string]$Record.current_call_kind -ceq 'P') { 'private' } else { 'group' }
    $kindText = if ($kind -ceq 'private') { '私呼' } else { '组呼' }
    $timestamp = [DateTime]::Now
    $timestampProperty = $Record.PSObject.Properties['timestamp_utc_ms']
    if ($timestampProperty) {
        $timestampMs = [int64]0
        if ([int64]::TryParse([string]$timestampProperty.Value,[Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$timestampMs)) {
            try { $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds($timestampMs).LocalDateTime } catch { }
        }
    }
    $targetText = if ($kind -ceq 'group') { 'TG ' + $destinationId } else { '本机 DMR ID ' + $destinationId }
    $sourceLabel = Format-UiRadioIdentity -RadioId $sourceId
    $entry = [pscustomobject][ordered]@{
        key=$key; run_id=$runId; generation=$generation; source_id=$sourceId
        destination_id=$destinationId; slot=$slot; kind=$kind; timestamp=$timestamp
        source_label=$sourceLabel
        identity_details=(Format-UiRadioIdentityDetails -RadioId $sourceId)
        text=('{0} · {1} {2} · TS{3} · 来源 {4}' -f $timestamp.ToString('HH:mm:ss'),$kindText,$targetText,$slot,$sourceLabel)
    }
    $script:callHistoryKeys[$key] = $true
    Clear-UiIdentityError
    $history = $script:mainWindow.FindName('CallHistoryList')
    $history.Items.Insert(0,$entry)
    Set-UiIdentityRowVisibility -Row 'current'
    Set-UiIdentityRowVisibility -Row 'history'
    while ($history.Items.Count -gt 50) {
        $oldest = $history.Items[$history.Items.Count - 1]
        if ($oldest -and $oldest.PSObject.Properties['key']) { [void]$script:callHistoryKeys.Remove([string]$oldest.key) }
        $history.Items.RemoveAt($history.Items.Count - 1)
    }
    if ($history.Items.Count -gt 0 -and $null -eq $history.SelectedItem) { $history.SelectedIndex = 0 }
    Set-UiIdentityRowVisibility -Row 'history_actions' -Visibility $(if ($history.Items.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
    Update-UiCallHistoryActionState
    try {
        [void](Start-UiIdentityQuery -RadioId $sourceId -ContextKind current -RunId $runId `
            -Generation $generation -HistoryKey $key)
    } catch {
        Set-UiIdentityError -ErrorCode worker_start -ErrorType $_.Exception.GetType().FullName `
            -Detail $_.Exception.Message -Stage 'incoming_call'
    }
}

function Get-UiCallHistoryKey {
    param([Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][uint64]$Generation)
    if ([string]::IsNullOrWhiteSpace($RunId) -or $Generation -eq 0) { throw '来话历史去重需要有效 run_id 和接收代次。' }
    return ($RunId + '|' + $Generation.ToString([Globalization.CultureInfo]::InvariantCulture))
}

function New-UiCallTargetFromHistoryEntry {
    param([Parameter(Mandatory=$true)][object]$Entry)
    if ([string]$Entry.kind -cnotin @('group','private')) { throw '历史记录呼叫类型无效。' }
    $destination = if ([string]$Entry.kind -ceq 'private') { [uint64]$Entry.source_id } else { [uint64]$Entry.destination_id }
    if ($destination -lt 1 -or $destination -gt 16777215 -or [uint64]$Entry.slot -notin @(1,2)) { throw '历史记录目标或 TS 无效。' }
    return [pscustomobject][ordered]@{ destination_id=$destination; kind=[string]$Entry.kind; slot=[uint64]$Entry.slot }
}

function Set-UiCallTargetSelector {
    param([object]$Target)
    if (-not $script:mainWindow -or -not $Target) { return }
    $tag = if ([string]$Target.kind -ceq 'private' -and [uint64]$Target.destination_id -eq 460997 -and [uint64]$Target.slot -eq 2) { 'parrot-cn' } else { 'custom' }
    $selector = Get-UiControl -Name 'TargetSelector'
    $item = @($selector.Items | Where-Object { $_ -is [System.Windows.Controls.ComboBoxItem] -and [string]$_.Tag -ceq $tag }) | Select-Object -First 1
    if ($item) {
        $script:loadingCallTargetSelection = $true
        try { $selector.SelectedItem = $item } finally { $script:loadingCallTargetSelection = $false }
    }
}

function Get-UiChannelFavoriteKey {
    param([Parameter(Mandatory=$true)][object]$Favorite)
    return ('{0}|{1}|{2}' -f [uint64]$Favorite.destination_id,[string]$Favorite.kind,[uint64]$Favorite.slot)
}

function Test-UiChannelFavorite {
    param([Parameter(Mandatory=$true)][object]$Favorite)
    $id = [uint64]0; $slot = [uint64]0
    $category = [string]$Favorite.category
    $kind = [string]$Favorite.kind
    $label = [string]$Favorite.label
    if (-not [uint64]::TryParse([string]$Favorite.destination_id,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$id) -or
        $id -lt 1 -or $id -gt 16777215 -or
        -not [uint64]::TryParse([string]$Favorite.slot,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$slot) -or
        $slot -notin @(1,2) -or $kind -cnotin @('group','private') -or
        $category -cnotin @('normal','dynamic','static') -or
        [string]::IsNullOrWhiteSpace($label) -or $label.Length -gt 40 -or $label -match '\p{C}' -or
        ($kind -ceq 'group' -and $id -in @(91,46001,4000))) { return $false }
    return $true
}

function Read-UiChannelFavorites {
    if (-not [System.IO.File]::Exists($script:channelFavoritesPath)) { return @() }
    if ((New-Object System.IO.FileInfo($script:channelFavoritesPath)).Length -gt 32768) { throw '本机频道收藏文件超过 32 KiB。' }
    $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:channelFavoritesPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $rootNames = @($document.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($document -isnot [System.Management.Automation.PSCustomObject] -or
        $rootNames.Count -ne 2 -or $rootNames -cnotcontains 'schema_version' -or $rootNames -cnotcontains 'favorites' -or
        $document.schema_version -is [bool] -or [int]$document.schema_version -ne 1 -or
        $document.favorites -isnot [array] -or $document.favorites.Count -gt 64) { throw '本机频道收藏格式无效；文件已保留，未覆盖。' }
    $favorites = New-Object 'System.Collections.Generic.List[object]'
    $keys = @{}
    foreach ($item in $document.favorites) {
        $names = @($item.PSObject.Properties | ForEach-Object { [string]$_.Name })
        $expected = @('destination_id','kind','slot','label','category')
        if ($item -isnot [System.Management.Automation.PSCustomObject] -or $names.Count -ne $expected.Count -or
            @($names | Where-Object { $expected -cnotcontains $_ }).Count -gt 0 -or
            @($expected | Where-Object { $names -cnotcontains $_ }).Count -gt 0 -or
            -not (Test-UiChannelFavorite -Favorite $item)) { throw '本机频道收藏包含无效项目；文件已保留，未覆盖。' }
        $copy = [pscustomobject][ordered]@{
            destination_id=[uint64]$item.destination_id; kind=[string]$item.kind; slot=[uint64]$item.slot
            label=[string]$item.label; category=[string]$item.category
        }
        $key = Get-UiChannelFavoriteKey -Favorite $copy
        if ($keys.ContainsKey($key)) { throw '本机频道收藏存在重复的 ID、呼叫类型和 TS；文件已保留，未覆盖。' }
        $keys[$key] = $true
        $favorites.Add($copy)
    }
    return @($favorites.ToArray())
}

function Write-UiChannelFavorites {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Favorites)
    if ($Favorites.Count -gt 64) { throw '本机收藏最多保存 64 个频道。' }
    foreach ($favorite in $Favorites) { if (-not (Test-UiChannelFavorite -Favorite $favorite)) { throw '本机收藏字段无效。' } }
    $directory = [System.IO.Path]::GetDirectoryName($script:channelFavoritesPath)
    if (-not [System.IO.Directory]::Exists($directory)) { throw '本机用户配置目录不存在；收藏没有保存。' }
    $document = [pscustomobject][ordered]@{ schema_version=1; favorites=@($Favorites) }
    $json = ConvertTo-Json -InputObject $document -Depth 6
    $temporaryPath = $script:channelFavoritesPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backupPath = $script:channelFavoritesPath + '.bak-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporaryPath,$json + "`n",(New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($script:channelFavoritesPath)) {
            [System.IO.File]::Replace($temporaryPath,$script:channelFavoritesPath,$backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath,$script:channelFavoritesPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
        if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
    }
}

function New-UiChannelFavoriteCandidate {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Favorites,[Parameter(Mandatory=$true)][object]$Target,
        [string]$Label='', [Parameter(Mandatory=$true)][ValidateSet('normal','dynamic','static')][string]$Category)
    $savedLabel = ([string]$Label).Trim()
    if ([string]::IsNullOrWhiteSpace($savedLabel)) { $savedLabel = Format-UiTxTarget -Target $Target }
    $favorite = [pscustomobject][ordered]@{
        destination_id=[uint64]$Target.destination_id; kind=[string]$Target.kind; slot=[uint64]$Target.slot
        label=$savedLabel; category=$Category
    }
    if (-not (Test-UiChannelFavorite -Favorite $favorite)) { throw '频道收藏字段无效；TG91、TG46001 与 TG4000 不能作为起呼收藏。' }
    $key = Get-UiChannelFavoriteKey -Favorite $favorite
    $next = New-Object 'System.Collections.Generic.List[object]'
    $updated = $false
    foreach ($existing in $Favorites) {
        if ((Get-UiChannelFavoriteKey -Favorite $existing) -ceq $key) {
            if (-not $updated) { $next.Add($favorite); $updated=$true }
        } else { $next.Add($existing) }
    }
    if (-not $updated) {
        if ($next.Count -ge 64) { throw '本机收藏已满 64 项；请先删除一项再添加。' }
        $next.Insert(0,$favorite)
    }
    return [pscustomobject][ordered]@{ favorites=@($next.ToArray()); favorite=$favorite; was_update=$updated }
}

function Remove-UiChannelFavoriteCandidate {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Favorites,[Parameter(Mandatory=$true)][object]$Favorite)
    $key = Get-UiChannelFavoriteKey -Favorite $Favorite
    return ,([object[]]@($Favorites | Where-Object { (Get-UiChannelFavoriteKey -Favorite $_) -cne $key }))
}

function Get-UiCurrentCallTarget {
    if ($script:activeRouting) { return $script:activeRouting.tx_target }
    if ($script:pendingCallTarget) { return $script:pendingCallTarget }
    $profile = if ($script:activeProfile) { $script:activeProfile } elseif ($script:storedProfile) { $script:storedProfile } else { $null }
    if ($profile) { return $profile.tx_target }
    return $null
}

function Update-UiChannelFavoriteControls {
    if (-not $script:mainWindow) { return }
    $list = $script:mainWindow.FindName('CallFavoritesList')
    if (-not $list) { return }
    if ($script:updatingChannelFavorites) { return }
    $selectedKey = if ($list.SelectedItem) { Get-UiChannelFavoriteKey -Favorite $list.SelectedItem } else { '' }
    $script:updatingChannelFavorites = $true
    try {
        $list.Items.Clear()
        foreach ($favorite in @($script:channelFavorites)) {
            $categoryLabel = switch -CaseSensitive ([string]$favorite.category) { 'static' { '本机静态收藏' } 'dynamic' { '本机动态收藏' } default { '本机普通收藏' } }
            $targetText = Format-UiTxTarget -Target $favorite
            $view = [pscustomobject][ordered]@{
                destination_id=[uint64]$favorite.destination_id; kind=[string]$favorite.kind; slot=[uint64]$favorite.slot
                label=[string]$favorite.label; category=[string]$favorite.category
                text=('{0} · {1} · {2}' -f $categoryLabel,$favorite.label,$targetText)
            }
            [void]$list.Items.Add($view)
        }
        if ($selectedKey) {
            for ($index=0; $index -lt $list.Items.Count; $index++) {
                if ((Get-UiChannelFavoriteKey -Favorite $list.Items[$index]) -ceq $selectedKey) { $list.SelectedIndex=$index; break }
            }
        }
    } finally { $script:updatingChannelFavorites = $false }
    $list.Visibility = if ($list.Items.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    Set-UiChannelFavoriteActionState
}

function Set-UiChannelFavoriteActionState {
    if (-not $script:mainWindow) { return }
    $list = $script:mainWindow.FindName('CallFavoritesList')
    if (-not $list) { return }
    $locked = ([bool]$script:pendingRoutingMutation -or [bool]$script:routingMutationFence)
    $canWrite = [string]::IsNullOrEmpty($script:channelFavoritesLoadError)
    $currentButton = $script:mainWindow.FindName('FavoriteCurrentTargetButton')
    if ($currentButton) { $currentButton.IsEnabled = ($canWrite -and $null -ne (Get-UiCurrentCallTarget)) }
    $manualButton = $script:mainWindow.FindName('FavoriteManualGroupButton')
    $manualTargetValid = $false
    try {
        $manualTarget = Read-DynamicGroupInput
        $manualTargetValid = ([uint64]$manualTarget.destination_id -notin @(91,46001,4000))
    } catch { }
    if ($manualButton) { $manualButton.IsEnabled = ($canWrite -and $manualTargetValid) }
    $selected = $list.SelectedItem
    $apply = $script:mainWindow.FindName('ApplyCallFavoriteButton')
    $remove = $script:mainWindow.FindName('RemoveCallFavoriteButton')
    if ($apply) { $apply.IsEnabled = ($selected -and -not $locked) }
    if ($remove) { $remove.IsEnabled = ($selected -and $canWrite) }
    foreach ($name in @('FavoriteCategorySelector','FavoriteLabelBox')) {
        $control = $script:mainWindow.FindName($name)
        if ($control) { $control.IsEnabled = $canWrite }
    }
    $status = $script:mainWindow.FindName('ChannelFavoritesStatusValue')
    if ($status) {
        $status.Text = if ($script:channelFavoritesLoadError) { '收藏文件读取失败' } else { '' }
        $status.Visibility = if ($status.Text) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

function Add-UiChannelFavorite {
    param([Parameter(Mandatory=$true)][object]$Target)
    if ($script:channelFavoritesLoadError) { throw '收藏文件读取失败；已保留原文件，请先修复文件后再收藏。' }
    $categoryItem = (Get-UiControl 'FavoriteCategorySelector').SelectedItem
    if ($categoryItem -isnot [System.Windows.Controls.ComboBoxItem]) { throw '请选择普通、动态或静态本机分类。' }
    $category = [string]$categoryItem.Tag
    $candidateResult = New-UiChannelFavoriteCandidate -Favorites @($script:channelFavorites) -Target $Target `
        -Label ([string](Get-UiControl 'FavoriteLabelBox').Text) -Category $category
    $favorite = $candidateResult.favorite
    $key = Get-UiChannelFavoriteKey -Favorite $favorite
    $candidate = @($candidateResult.favorites)
    Write-UiChannelFavorites -Favorites $candidate
    $script:channelFavorites = $candidate
    (Get-UiControl 'FavoriteLabelBox').Text = ''
    Update-UiChannelFavoriteControls
    $list = Get-UiControl 'CallFavoritesList'
    for ($index=0; $index -lt $list.Items.Count; $index++) {
        if ((Get-UiChannelFavoriteKey -Favorite $list.Items[$index]) -ceq $key) { $list.SelectedIndex=$index; break }
    }
}

function Remove-UiChannelFavorite {
    $selected = (Get-UiControl 'CallFavoritesList').SelectedItem
    if (-not $selected) { throw '请选择要删除的本机收藏。' }
    if ($script:channelFavoritesLoadError) { throw '收藏文件读取失败；已保留原文件，不能删除。' }
    $key = Get-UiChannelFavoriteKey -Favorite $selected
    $candidate = Remove-UiChannelFavoriteCandidate -Favorites @($script:channelFavorites) -Favorite $selected
    Write-UiChannelFavorites -Favorites $candidate
    $script:channelFavorites = $candidate
    Update-UiChannelFavoriteControls
}

function Update-CallTargetChoices {
    if (-not $script:mainWindow) { return }
    $panel = $script:mainWindow.FindName('CallTargetChoicesPanel')
    if (-not $panel) { return }
    $panel.Children.Clear()
    $profile = if ($script:activeProfile) { $script:activeProfile } elseif ($script:storedProfile) { $script:storedProfile } else { $null }
    $policy = if ($script:activeRouting) { $script:activeRouting.rx_policy } elseif ($profile) { $profile.rx_policy } else { $null }
    $routes = @()
    if ($policy) {
        $routes = @($policy.allow_groups | Where-Object {
            [uint64]$_.destination_id -notin @(91,46001)
        } | Sort-Object destination_id,slot -Unique)
    }
    $routeLabel = $script:mainWindow.FindName('CallTargetChoicesLabel')
    $routeScroll = $script:mainWindow.FindName('CallTargetChoicesScroll')
    if ($routeLabel) { $routeLabel.Visibility = if ($routes.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($routeScroll) { $routeScroll.Visibility = if ($routes.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    foreach ($route in $routes) {
        $target = [pscustomobject][ordered]@{ destination_id=[uint64]$route.destination_id; kind='group'; slot=[uint64]$route.slot }
        $button = New-Object System.Windows.Controls.Button
        $button.Content = ('TG {0} · TS{1}' -f $route.destination_id,$route.slot)
        $button.Tag = [pscustomobject]@{ target=$target; description=('本机已配置组 TG {0} · TS{1}' -f $route.destination_id,$route.slot) }
        $button.FontSize = 9; $button.Padding = [Windows.Thickness]::new(5.0,2.0,5.0,2.0); $button.Margin = [Windows.Thickness]::new(2.0)
        $button.Add_Click({ param($sender,$eventArgs) Invoke-UiSetCallTarget -Target $sender.Tag.target -Description $sender.Tag.description })
        [void]$panel.Children.Add($button)
    }
    $selectorTarget = if ($script:activeRouting) { $script:activeRouting.tx_target } elseif ($script:pendingCallTarget) { $script:pendingCallTarget } elseif ($profile) { $profile.tx_target } else { $null }
    if ($selectorTarget) { Set-UiCallTargetSelector -Target $selectorTarget }
    Update-UiChannelFavoriteControls
}

function Invoke-UiSetCallTarget {
    param([Parameter(Mandatory=$true)][object]$Target, [string]$Description='呼叫目标')
    $destination = [uint64]$Target.destination_id
    $slot = [uint64]$Target.slot
    $kind = [string]$Target.kind
    if ($destination -lt 1 -or $destination -gt 16777215 -or $slot -notin @(1,2) -or $kind -cnotin @('group','private')) {
        throw '呼叫目标需包含有效 ID、呼叫类型和 TS1/TS2。'
    }
    if ($kind -ceq 'group' -and $destination -in @(91,46001)) { throw 'TG91 与 TG46001 用于本机收听。' }
    $targetCopy = [pscustomobject][ordered]@{ destination_id=$destination; kind=$kind; slot=$slot }
    $live = ($script:supervisor -and -not $script:supervisor.HasExited)
    $enabled = if ($script:activeRouting) { [bool]$script:activeRouting.transmit_enabled } elseif ($script:storedProfile) { [bool]$script:storedProfile.transmit_enabled } else { [bool]$script:editTransmitEnabled }
    if ($live) {
        Invoke-UiRoutingMutation -Command 'tx_policy.replace' -PolicyOrTarget $targetCopy -TransmitEnabled $enabled
        Set-MainText -Name 'CallTargetStatusValue' -Text ('已提交起呼目标：' + (Format-UiTxTarget -Target $targetCopy))
        Add-UiEvent ('已提交呼叫目标设置：' + (Format-UiTxTarget -Target $targetCopy))
    } else {
        $script:pendingCallTarget = $targetCopy
        $script:editTxTarget = $targetCopy
        $script:editTransmitEnabled = $enabled
        $profile = if ($script:storedProfile) { $script:storedProfile } elseif ($script:activeProfile) { $script:activeProfile } else { $null }
        if ($profile) {
            $script:effectiveProfile = New-UiCallTargetProfile -Profile $profile -Target $targetCopy
            Set-MainTargetSummary -Profile $script:effectiveProfile -OverallLabel (Format-UiTxTarget -Target $targetCopy)
        } else {
            Set-MainText -Name 'TargetValue' -Text ''
            Set-MainText -Name 'TransmitTargetValue' -Text (Format-UiTxTarget -Target $targetCopy)
            Set-MainText -Name 'TransmitPermissionValue' -Text ''
        }
        Set-UiCallTargetSelector -Target $targetCopy
        Set-MainText -Name 'CallTargetStatusValue' -Text ('已选择起呼目标：' + (Format-UiTxTarget -Target $targetCopy))
        Add-UiEvent ('已选择下次连接呼叫目标：' + (Format-UiTxTarget -Target $targetCopy))
    }
    Update-CallTargetChoices
}

function Invoke-UiSetDynamicCallTarget {
    try {
        Update-DynamicGroupControls
        $button = Get-UiControl 'SetDynamicCallTargetButton'
        $route = Read-DynamicGroupInput
        if ([uint64]$route.destination_id -in @(91,46001)) { throw '此组仅用于收听' }
        if (-not $button.IsEnabled) { throw '当前无法设置起呼目标' }
        $target = [pscustomobject][ordered]@{ destination_id=[uint64]$route.destination_id; kind='group'; slot=[uint64]$route.slot }
        $script:pendingDynamicCallTarget = if ($script:supervisor -and -not $script:supervisor.HasExited) { $target } else { $null }
        Invoke-UiSetCallTarget -Target $target -Description ('动态组 TG {0}' -f $route.destination_id)
        if ($script:supervisor -and -not $script:supervisor.HasExited) {
            Set-DynamicGroupStatus ('已提交 TG {0} · TS{1} 为下一起呼目标；等待核心确认。没有发起呼叫，收听规则未变。' -f $route.destination_id,$route.slot)
        } else {
            Set-DynamicGroupStatus ('已将 TG {0} · TS{1} 设为下次连接的起呼目标；没有发起呼叫，收听规则未变。' -f $route.destination_id,$route.slot)
        }
    } catch {
        $script:pendingDynamicCallTarget = $null
        Set-MainText -Name 'CallTargetStatusValue' -Text $_.Exception.Message
    }
}

function Get-SelectedTargetTag {
    $selector = Get-UiControl -Name 'TargetSelector'
    if ($null -eq $selector.SelectedItem) { return 'custom' }
    return [string]$selector.SelectedItem.Tag
}

function New-EffectiveTargetProfile {
    param([Parameter(Mandatory=$true)][object]$Profile, [Parameter(Mandatory=$true)][string]$Target)
    if ($Target -cne 'custom') {
        $editorState = Get-UiReceiveEditorState -Profile $Profile
        if (-not $editorState.CanEdit) {
            throw ('当前 schema 2 接收策略为只读；无法用 {0} 单路由预设覆盖。请保留“使用已保存目标”，启动时会完整检查策略。' -f $Target)
        }
    }
    $connection = [pscustomobject][ordered]@{
        callsign = [string]$Profile.connection.callsign
        gateway_id = [uint64]$Profile.connection.gateway_id
        source_id = [uint64]$Profile.connection.source_id
        master = [string]$Profile.connection.master
        master_port = [uint64]$Profile.connection.master_port
        color_code = [uint64]$Profile.connection.color_code
    }
    $txTarget = [pscustomobject][ordered]@{
        destination_id=[uint64]$Profile.tx_target.destination_id
        kind=[string]$Profile.tx_target.kind
        slot=[uint64]$Profile.tx_target.slot
    }
    $rxPolicy = [pscustomobject][ordered]@{
        group_mode=[string]$Profile.rx_policy.group_mode
        private_mode=[string]$Profile.rx_policy.private_mode
        allow_groups=[object[]]@($Profile.rx_policy.allow_groups)
        allow_private_peers=[object[]]@($Profile.rx_policy.allow_private_peers)
        local_private_routes=[object[]]@($Profile.rx_policy.local_private_routes)
        blocked_groups=[object[]]@($Profile.rx_policy.blocked_groups)
        blocked_source_ids=[uint64[]]@($Profile.rx_policy.blocked_source_ids)
    }
    $transmitEnabled = [bool]$Profile.transmit_enabled
    switch ($Target) {
        'parrot-cn' {
            $txTarget.destination_id = [uint64]460997
            $txTarget.slot = [uint64]2
            $txTarget.kind = 'private'
            $rxPolicy.group_mode = 'selected'
            $rxPolicy.allow_groups = @()
            $rxPolicy.private_mode = 'all_peers_to_local'
            $rxPolicy.local_private_routes = @([pscustomobject][ordered]@{
                local_destination_id=[uint64]$connection.source_id; slot=[uint64]2
            })
            $transmitEnabled = $true
        }
        'listen-91' {
            $rxPolicy.group_mode = 'selected'
            $rxPolicy.allow_groups = @([pscustomobject][ordered]@{ destination_id=[uint64]91; slot=[uint64]2 })
            $rxPolicy.blocked_groups = @($rxPolicy.blocked_groups | Where-Object { -not ([uint64]$_.destination_id -eq 91 -and [uint64]$_.slot -eq 2) })
            $rxPolicy.private_mode = 'disabled'
            $rxPolicy.allow_private_peers = @()
            $rxPolicy.local_private_routes = @()
            $transmitEnabled = $false
        }
        'listen-46001' {
            $rxPolicy.group_mode = 'selected'
            $rxPolicy.allow_groups = @([pscustomobject][ordered]@{ destination_id=[uint64]46001; slot=[uint64]2 })
            $rxPolicy.blocked_groups = @($rxPolicy.blocked_groups | Where-Object { -not ([uint64]$_.destination_id -eq 46001 -and [uint64]$_.slot -eq 2) })
            $rxPolicy.private_mode = 'disabled'
            $rxPolicy.allow_private_peers = @()
            $rxPolicy.local_private_routes = @()
            $transmitEnabled = $false
        }
        default { }
    }
    return ConvertTo-BridgeUserConnectionProfile -Connection $connection -TxTarget $txTarget -Devices $Profile.devices `
        -RxPolicy $rxPolicy -TransmitEnabled $transmitEnabled
}

function Test-UiSourceIdentityRecord {
    param([Parameter(Mandatory=$true)][object]$Identity, [Parameter(Mandatory=$true)][object]$ParentRecord)
    if ($Identity -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $expectedNames = @('prepared', 'source_id', 'receive_generation', 'label', 'display')
    $actualNames = @($Identity.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actualNames.Count -ne $expectedNames.Count) { return $false }
    foreach ($name in $expectedNames) {
        if ($actualNames -cnotcontains $name) { return $false }
    }
    if ($Identity.prepared -isnot [bool] -or $Identity.label -isnot [string] -or
        $Identity.display -isnot [string] -or $Identity.display -cne 'unknown') { return $false }

    $numberTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    foreach ($name in @('source_id', 'receive_generation')) {
        $property = $Identity.PSObject.Properties[$name]
        if ($null -eq $property) { return $false }
        $isNumber = $false
        foreach ($type in $numberTypes) {
            if ($property.Value -is $type) { $isNumber = $true; break }
        }
        if (-not $isNumber) { return $false }
        $parsed = [uint64]0
        if (-not [uint64]::TryParse([string]$property.Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $false }
        if ($name -eq 'source_id' -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'source_id') { $sourceId = $parsed } else { $generation = $parsed }
    }

    if ($Identity.prepared) {
        if ($sourceId -eq 0 -or $generation -eq 0 -or $Identity.label.Length -ne 10) { return $false }
        $decimalId = $sourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
        $expectedLabel = ('ID' + $decimalId).PadRight(10, [char]' ')
        if ($Identity.label -cne $expectedLabel) { return $false }
        if ($null -ne $ParentRecord.PSObject.Properties['current_call_valid'] -and
            [bool]$ParentRecord.current_call_valid -and
            ($sourceId -ne [uint64]$ParentRecord.current_call_source_id -or
             $generation -ne [uint64]$ParentRecord.current_call_generation)) { return $false }
    } elseif ($sourceId -ne 0 -or $generation -ne 0 -or $Identity.label.Length -ne 0) {
        return $false
    }
    return $true
}

function Get-UiSourceIdentityDisplay {
    param([object]$Identity, [bool]$IdentityPresent = $true, [string]$State = 'status')
    $value = '当前没有已准备的 HRI 来源标签'
    switch -CaseSensitive ($State) {
        'offline' { $value = '等待本次运行报告' }
        'stale' { $value = '状态已过期，旧标签已清除' }
        'exited' { $value = '本次运行已结束' }
        'legacy' { $value = '当前核心未提供来源标签字段' }
        default {
            if (-not $IdentityPresent) {
                $value = '当前核心未提供来源标签字段'
            } elseif ($Identity.prepared) {
                $value = (([string]$Identity.label).TrimEnd([char]' ') + ' · 已准备')
            }
        }
    }
    return [pscustomobject][ordered]@{
        value = $value
        radio_display = 'FTX-1 屏幕：未知'
    }
}

function Get-UiCompletedRunRecord {
    param([Parameter(Mandatory=$true)][string]$RunDirectory)
    $statusPath = Join-Path $RunDirectory 'status.jsonl'
    if (-not [System.IO.File]::Exists($statusPath)) { return $null }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($statusPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        if ($stream.Length -le 0) { return $null }
        $length = [int][Math]::Min([int64]65536, $stream.Length)
        $buffer = New-Object byte[] $length
        $stream.Position = $stream.Length - $length
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        if (-not $text.EndsWith("`n", [System.StringComparison]::Ordinal)) { return $null }
        $lines = $text.Split([char]10)
        $line = ''
        for ($index = $lines.Count - 2; $index -ge 0; $index--) {
            $candidate = ([string]$lines[$index]).TrimEnd([char]13)
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $line = $candidate; break }
        }
        if (-not $line -or $line.Length -gt 65536) { return $null }
        $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop
        if (-not (Test-UiStatusRecord -Record $record) -or
            $record.run_id -isnot [string] -or $record.event -isnot [string] -or
            $record.event -cnotin @('stopped', 'stopped_with_failure', 'stopped_after_runtime_exception')) { return $null }
        if ($record.run_id -cnotmatch '^([1-9][0-9]*)-[0-9]+$') { return $null }
        $processId = [int]0
        if (-not [int]::TryParse($Matches[1], [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$processId) -or $processId -le 0) { return $null }
        $process = $null
        try {
            $process = [System.Diagnostics.Process]::GetProcessById($processId)
            if (-not $process.HasExited) { return $null }
        } catch [System.ArgumentException] {
            # PID 当前不存在，可将带终态记录的目录纳入保留清理。
        } catch {
            # 无法确认 PID 是否仍在运行时，保留该目录。
            return $null
        } finally {
            if ($process) { $process.Dispose() }
        }
        return [pscustomobject][ordered]@{ run_id = [string]$record.run_id; event = [string]$record.event; process_id = $processId }
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-UiRunDirectorySize {
    param([Parameter(Mandatory=$true)][string]$RunDirectory)
    $total = [int64]0
    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    try {
        $root = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($RunDirectory))
        if (-not $root.Exists -or (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { return $null }
        $directories.Push($root.FullName)
        while ($directories.Count -gt 0) {
            $current = New-Object System.IO.DirectoryInfo($directories.Pop())
            foreach ($entry in $current.GetFileSystemInfos()) {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
                if ($entry -is [System.IO.DirectoryInfo]) {
                    $directories.Push($entry.FullName)
                } elseif ($entry -is [System.IO.FileInfo]) {
                    $length = [int64]$entry.Length
                    if ($length -gt ([int64]::MaxValue - $total)) { return $null }
                    $total += $length
                }
            }
        }
        return $total
    } catch {
        return $null
    }
}

function Invoke-UiRunLogRetention {
    param(
        [Parameter(Mandatory=$true)][string]$RunRoot,
        [Parameter(Mandatory=$true)][string]$ConfigRoot,
        [string]$CurrentRunDirectory = '',
        [int]$MaximumCompletedRuns = 10,
        [int64]$MaximumCompletedBytes = 52428800
    )
    $result = [ordered]@{ removed = 0; retained = 0; retained_bytes = [int64]0; cleanup_errors = 0; skipped_unknown = 0 }
    if ($MaximumCompletedRuns -lt 0 -or $MaximumCompletedBytes -lt 0) { throw 'UI 运行日志保留上限必须大于或等于零。' }
    try {
        $configPath = [System.IO.Path]::GetFullPath($ConfigRoot).TrimEnd('\', '/')
        $rootPath = [System.IO.Path]::GetFullPath($RunRoot).TrimEnd('\', '/')
        $rootPrefix = $configPath + [System.IO.Path]::DirectorySeparatorChar
        if (-not $rootPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([System.IO.Path]::GetDirectoryName($rootPath), $configPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($rootPath) -cne 'ui-runs') { throw 'UI 运行目录不在本机配置目录内。' }
        if (-not [System.IO.Directory]::Exists($rootPath)) { return [pscustomobject]$result }
        $rootInfo = [System.IO.DirectoryInfo]::new($rootPath)
        if (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'UI 运行目录是重解析点，拒绝清理。' }
        $currentPath = ''
        if (-not [string]::IsNullOrWhiteSpace($CurrentRunDirectory)) {
            $currentPath = [System.IO.Path]::GetFullPath($CurrentRunDirectory).TrimEnd('\', '/')
        }
        $eligible = New-Object 'System.Collections.Generic.List[object]'
        foreach ($directory in $rootInfo.GetDirectories()) {
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $directory.Name -cnotmatch '^[0-9a-f]{32}$') { $result.skipped_unknown++; continue }
            if ($currentPath -and [string]::Equals($directory.FullName.TrimEnd('\', '/'), $currentPath,
                    [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $terminalRecord = Get-UiCompletedRunRecord -RunDirectory $directory.FullName
            $size = if ($null -ne $terminalRecord) { Get-UiRunDirectorySize -RunDirectory $directory.FullName } else { $null }
            if ($null -eq $terminalRecord -or $null -eq $size) { $result.skipped_unknown++; continue }
            $eligible.Add([pscustomobject]@{ path = $directory.FullName; name = $directory.Name; bytes = [int64]$size; modified = $directory.LastWriteTimeUtc })
        }
        $orderedRuns = @($eligible | Sort-Object -Property @{Expression='modified';Descending=$true}, @{Expression='name';Descending=$false})
        foreach ($run in $orderedRuns) {
            if ($result.retained -lt $MaximumCompletedRuns -and
                $run.bytes -le ($MaximumCompletedBytes - $result.retained_bytes)) {
                $result.retained++
                $result.retained_bytes += [int64]$run.bytes
                continue
            }
            $target = [System.IO.Path]::GetFullPath([string]$run.path).TrimEnd('\', '/')
            $targetPrefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
            if (-not $target.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([System.IO.Path]::GetDirectoryName($target), $rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                [System.IO.Path]::GetFileName($target) -cnotmatch '^[0-9a-f]{32}$') { throw '待清理的 UI 运行目录越界。' }
            try {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                $result.removed++
            } catch {
                $result.cleanup_errors++
            }
        }
    } catch {
        $result.cleanup_errors++
    }
    return [pscustomobject]$result
}

function Test-UiStatusRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
    if ($Record -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $requiredStrings = @('run_id', 'event', 'bm_state', 'bm_failure', 'radio_state', 'hri_phase', 'wavein_state', 'waveout_state', 'last_rx_call_kind')
    foreach ($name in $requiredStrings) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string]) { return $false }
    }
    $requiredBooleans = @('audio_endpoints_validated', 'hri_serial_open', 'hri_ready', 'hri_y_zero_ready', 'last_rx_header_valid')
    foreach ($name in $requiredBooleans) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [bool]) { return $false }
    }
    $currentCallNames = @(
        'current_call_valid', 'current_call_phase', 'current_call_source_id', 'current_call_destination_id',
        'current_call_slot', 'current_call_kind', 'current_call_color_code',
        'current_call_link_control_validated', 'current_call_color_code_known', 'current_call_generation',
        'receive_media_state'
    )
    $currentCallPresent = 0
    foreach ($name in $currentCallNames) {
        if ($null -ne $Record.PSObject.Properties[$name]) { $currentCallPresent++ }
    }
    if ($currentCallPresent -ne 0 -and $currentCallPresent -ne $currentCallNames.Count) { return $false }
    $hasCurrentCallStatus = $currentCallPresent -eq $currentCallNames.Count
    if ($hasCurrentCallStatus) {
        foreach ($name in @('current_call_valid', 'current_call_link_control_validated', 'current_call_color_code_known')) {
            $property = $Record.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [bool]) { return $false }
        }
        foreach ($name in @('current_call_phase', 'current_call_kind', 'receive_media_state')) {
            $property = $Record.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [string]) { return $false }
        }
    }
    $sourceIdentityProperty = $Record.PSObject.Properties['lcd_source_identity']
    if ($null -ne $sourceIdentityProperty -and
        -not (Test-UiSourceIdentityRecord -Identity $sourceIdentityProperty.Value -ParentRecord $Record)) { return $false }
    $numberTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $numberNames = @('seq', 'timestamp_utc_ms', 'elapsed_ms', 'last_rx_source_id', 'last_rx_destination_id', 'last_rx_slot')
    if ($hasCurrentCallStatus) {
        $numberNames += @('current_call_source_id', 'current_call_destination_id', 'current_call_slot',
            'current_call_color_code', 'current_call_generation')
    }
    foreach ($name in $numberNames) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -eq $property) { return $false }
        $isNumber = $false
        foreach ($type in $numberTypes) {
            if ($property.Value -is $type) { $isNumber = $true; break }
        }
        if (-not $isNumber) { return $false }
        $parsed = [uint64]0
        if (-not [uint64]::TryParse([string]$property.Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $false }
        if ($name -eq 'seq' -and $parsed -eq 0) { return $false }
        if ($name -eq 'timestamp_utc_ms' -and $parsed -gt 253402300799999) { return $false }
        if ($name -eq 'last_rx_source_id' -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'last_rx_destination_id' -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'last_rx_slot' -and $parsed -notin @(1, 2)) { return $false }
        if ($name -in @('current_call_source_id', 'current_call_destination_id') -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'current_call_slot' -and $parsed -gt 2) { return $false }
        if ($name -eq 'current_call_color_code' -and $parsed -gt 15) { return $false }
    }
    if ($Record.bm_state -cnotin @('idle', 'waiting_login_ack', 'waiting_auth_ack', 'waiting_config_ack', 'waiting_options_ack', 'ready', 'backoff', 'stopped')) { return $false }
    if ($Record.bm_failure -cnotin @('none', 'invalid_profile', 'login_timeout', 'auth_timeout', 'config_timeout', 'options_timeout',
            'pong_timeout', 'master_rejected', 'master_closed', 'malformed_response', 'unexpected_response', 'wrong_peer_id',
            'authentication_error', 'inbound_queue_full', 'transport_lost', 'outbound_queue_full', 'unknown')) { return $false }
    if ($Record.radio_state -cne 'unknown') { return $false }
    if ($Record.hri_phase -cnotin @('not_started', 'awaiting_version_write', 'awaiting_version', 'waiting_for_y_due', 'exchanging', 'stopped', 'unknown')) { return $false }
    if ($Record.wavein_state -cnotin @('open', 'closed') -or $Record.waveout_state -cnotin @('open', 'closed')) { return $false }
    if ($Record.last_rx_call_kind -cnotin @('G', 'P')) { return $false }
    if ($hasCurrentCallStatus) {
        if ($Record.current_call_kind -cnotin @('none', 'G', 'P')) { return $false }
        if ($Record.current_call_phase -cnotin @('none', 'waiting_for_playback', 'buffering', 'playing')) { return $false }
        if ($Record.receive_media_state -cnotin @('idle', 'filtered', 'waiting_for_playback', 'buffering', 'playing', 'draining', 'stopping')) { return $false }
        $activeMedia = $Record.receive_media_state -cin @('waiting_for_playback', 'buffering', 'playing')
        if ([bool]$Record.current_call_valid -ne $activeMedia) { return $false }
        if ([bool]$Record.current_call_valid) {
            if ($Record.current_call_phase -cne $Record.receive_media_state -or
                [uint64]$Record.current_call_source_id -eq 0 -or
                [uint64]$Record.current_call_destination_id -eq 0 -or
                [uint64]$Record.current_call_slot -notin @(1, 2) -or
                $Record.current_call_kind -cnotin @('G', 'P') -or
                [uint64]$Record.current_call_generation -eq 0 -or
                (-not [bool]$Record.current_call_color_code_known -and [uint64]$Record.current_call_color_code -ne 0)) {
                return $false
            }
        } elseif ($Record.current_call_phase -cne 'none' -or
            [uint64]$Record.current_call_source_id -ne 0 -or
            [uint64]$Record.current_call_destination_id -ne 0 -or
            [uint64]$Record.current_call_slot -ne 0 -or
            $Record.current_call_kind -cne 'none' -or
            [uint64]$Record.current_call_color_code -ne 0 -or
            [bool]$Record.current_call_link_control_validated -or
            [bool]$Record.current_call_color_code_known -or
            [uint64]$Record.current_call_generation -ne 0) {
            return $false
        }
    }
    if ([string]$Record.event -cnotmatch '^[a-z0-9_]{1,96}$') { return $false }
    return $true
}

function Test-UiStatusFreshness {
    param([uint64]$TimestampUtcMs, [int64]$NowUtcMs)
    if ($TimestampUtcMs -gt 253402300799999) { return $false }
    $ageMs = $NowUtcMs - [int64]$TimestampUtcMs
    return ($ageMs -le 3000 -and $ageMs -ge -5000)
}

function Test-UiRunRecordAcceptance {
    param([Parameter(Mandatory=$true)][object]$Record, [Parameter(Mandatory=$true)][uint32]$ExpectedProcessId,
        [string]$LockedRunId, [uint64]$LastSequence = 0, [Parameter(Mandatory=$true)][int64]$NowUtcMs)
    if (-not (Test-UiStatusRecord -Record $Record)) { return $false }
    if ([string]$Record.run_id -cnotmatch ('^' + $ExpectedProcessId.ToString([Globalization.CultureInfo]::InvariantCulture) + '-[0-9]+$')) { return $false }
    if ($LockedRunId -and [string]$Record.run_id -cne $LockedRunId) { return $false }
    $sequence = [uint64]0
    if (-not [uint64]::TryParse([string]$Record.seq, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$sequence) -or $sequence -le $LastSequence) { return $false }
    return (Test-UiStatusFreshness -TimestampUtcMs ([uint64]$Record.timestamp_utc_ms) -NowUtcMs $NowUtcMs)
}

function Test-UiExactControlFields {
    param([object]$Record, [string[]]$Required, [string[]]$Optional = @())
    if ($Record -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $actual = @($Record.PSObject.Properties | ForEach-Object { [string]$_.Name })
    foreach ($name in $Required) { if ($actual -cnotcontains $name) { return $false } }
    foreach ($name in $actual) { if (($Required -cnotcontains $name) -and ($Optional -cnotcontains $name)) { return $false } }
    return $true
}

function Test-UiControlUnsigned {
    param([object]$Value, [uint64]$Minimum = 0, [uint64]$Maximum = [uint64]::MaxValue)
    if ($Value -is [bool] -or $Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and
        $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]) { return $false }
    $parsed = [uint64]0
    if (-not [uint64]::TryParse([string]$Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $false }
    return ($parsed -ge $Minimum -and $parsed -le $Maximum)
}

function Test-UiRxPolicy {
    param([object]$Policy, [uint64]$LocalSourceId)
    $fields = @('group_mode','private_mode','allow_groups','allow_private_peers','local_private_routes','blocked_groups','blocked_source_ids')
    if (-not (Test-UiExactControlFields -Record $Policy -Required $fields) -or
        $Policy.group_mode -isnot [string] -or @('selected','all_delivered') -cnotcontains [string]$Policy.group_mode -or
        $Policy.private_mode -isnot [string] -or @('disabled','selected_peers','all_peers_to_local') -cnotcontains [string]$Policy.private_mode) { return $false }
    foreach ($name in @('allow_groups','allow_private_peers','local_private_routes','blocked_groups','blocked_source_ids')) {
        if ($Policy.$name -isnot [System.Array]) { return $false }
    }
    $groupAllow = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $groupBlock = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $peerKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $localKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $sourceBlocks = New-Object 'System.Collections.Generic.HashSet[uint64]'
    foreach ($route in @($Policy.allow_groups)) {
        if (-not (Test-UiExactControlFields -Record $route -Required @('destination_id','slot')) -or
            -not (Test-UiControlUnsigned -Value $route.destination_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $route.slot -Minimum 1 -Maximum 2) -or
            -not $groupAllow.Add(([string]$route.destination_id + '/' + [string]$route.slot))) { return $false }
    }
    foreach ($route in @($Policy.blocked_groups)) {
        if (-not (Test-UiExactControlFields -Record $route -Required @('destination_id','slot')) -or
            -not (Test-UiControlUnsigned -Value $route.destination_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $route.slot -Minimum 1 -Maximum 2)) { return $false }
        $key = [string]$route.destination_id + '/' + [string]$route.slot
        if (-not $groupBlock.Add($key) -or $groupAllow.Contains($key)) { return $false }
    }
    foreach ($route in @($Policy.allow_private_peers)) {
        if (-not (Test-UiExactControlFields -Record $route -Required @('source_id','local_destination_id','slot')) -or
            -not (Test-UiControlUnsigned -Value $route.source_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $route.local_destination_id -Minimum 1 -Maximum 16777215) -or
            [uint64]$route.local_destination_id -ne $LocalSourceId -or
            -not (Test-UiControlUnsigned -Value $route.slot -Minimum 1 -Maximum 2)) { return $false }
        if (-not $peerKeys.Add(([string]$route.source_id + '/' + [string]$route.local_destination_id + '/' + [string]$route.slot))) { return $false }
    }
    foreach ($route in @($Policy.local_private_routes)) {
        if (-not (Test-UiExactControlFields -Record $route -Required @('local_destination_id','slot')) -or
            -not (Test-UiControlUnsigned -Value $route.local_destination_id -Minimum 1 -Maximum 16777215) -or
            [uint64]$route.local_destination_id -ne $LocalSourceId -or
            -not (Test-UiControlUnsigned -Value $route.slot -Minimum 1 -Maximum 2) -or
            -not $localKeys.Add(([string]$route.local_destination_id + '/' + [string]$route.slot))) { return $false }
    }
    foreach ($sourceId in @($Policy.blocked_source_ids)) {
        if (-not (Test-UiControlUnsigned -Value $sourceId -Minimum 1 -Maximum 16777215) -or
            -not $sourceBlocks.Add([uint64]$sourceId)) { return $false }
    }
    if ($Policy.private_mode -ceq 'disabled' -and ($peerKeys.Count -gt 0 -or $localKeys.Count -gt 0)) { return $false }
    if ($Policy.private_mode -ceq 'selected_peers' -and $localKeys.Count -gt 0) { return $false }
    return $true
}

function Test-UiRoutingSnapshot {
    param([object]$Routing)
    $names = @('local_source_id','rx_policy_revision','tx_policy_revision','rx_policy','tx_target','transmit_enabled',
        'media_owner','active_rx','active_tx_lease','observed_sources')
    if (-not (Test-UiExactControlFields -Record $Routing -Required $names) -or
        -not (Test-UiControlUnsigned -Value $Routing.local_source_id -Minimum 1 -Maximum 16777215) -or
        -not (Test-UiControlUnsigned -Value $Routing.rx_policy_revision) -or
        -not (Test-UiControlUnsigned -Value $Routing.tx_policy_revision) -or
        -not (Test-UiRxPolicy -Policy $Routing.rx_policy -LocalSourceId ([uint64]$Routing.local_source_id)) -or
        $Routing.transmit_enabled -isnot [bool] -or
        $Routing.media_owner -isnot [string] -or @('idle','rx_active','rx_draining','rx_stopping','tx_active','tx_draining','fault') -cnotcontains [string]$Routing.media_owner) { return $false }
    $target = $Routing.tx_target
    if (-not (Test-UiExactControlFields -Record $target -Required @('destination_id','kind','slot')) -or
        -not (Test-UiControlUnsigned -Value $target.destination_id -Minimum 1 -Maximum 16777215) -or
        -not (Test-UiControlUnsigned -Value $target.slot -Minimum 1 -Maximum 2) -or
        $target.kind -isnot [string] -or @('group','private') -cnotcontains [string]$target.kind) { return $false }
    if ($null -ne $Routing.active_rx) {
        $rx = $Routing.active_rx
        if (-not (Test-UiExactControlFields -Record $rx -Required @('source_id','destination_id','slot','kind','generation')) -or
            -not (Test-UiControlUnsigned -Value $rx.source_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $rx.destination_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $rx.slot -Minimum 1 -Maximum 2) -or
            $rx.kind -isnot [string] -or @('group','private') -cnotcontains [string]$rx.kind -or
            -not (Test-UiControlUnsigned -Value $rx.generation -Minimum 1)) { return $false }
    }
    if ($null -ne $Routing.active_tx_lease) {
        $lease = $Routing.active_tx_lease
        if (-not (Test-UiExactControlFields -Record $lease -Required @('lease_id','destination_id','slot','kind')) -or
            -not (Test-UiControlUnsigned -Value $lease.lease_id -Minimum 1) -or
            -not (Test-UiControlUnsigned -Value $lease.destination_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $lease.slot -Minimum 1 -Maximum 2) -or
            $lease.kind -isnot [string] -or @('group','private') -cnotcontains [string]$lease.kind) { return $false }
    }
    if ($Routing.observed_sources -isnot [System.Array] -or @($Routing.observed_sources).Count -gt 64) { return $false }
    $observedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($source in @($Routing.observed_sources)) {
        if (-not (Test-UiExactControlFields -Record $source -Required @('source_id','destination_id','slot','kind','observation_level')) -or
            -not (Test-UiControlUnsigned -Value $source.source_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $source.destination_id -Minimum 1 -Maximum 16777215) -or
            -not (Test-UiControlUnsigned -Value $source.slot -Minimum 1 -Maximum 2) -or
            $source.kind -isnot [string] -or @('group','private') -cnotcontains [string]$source.kind -or
            $source.observation_level -isnot [string] -or
            @('outer_header_seen','link_control_validated','router_reserved','playback_started') -cnotcontains [string]$source.observation_level) { return $false }
        $key = if ($source.kind -ceq 'group') { 'group/' + [string]$source.destination_id + '/' + [string]$source.slot } else { 'private/' + [string]$source.source_id + '/' + [string]$source.destination_id + '/' + [string]$source.slot }
        if (-not $observedKeys.Add($key)) { return $false }
    }
    return $true
}

function Test-UiRoutingCapabilityList {
    param([object]$Commands)
    if ($Commands -isnot [System.Array] -or @($Commands | Where-Object { $_ -isnot [string] }).Count -gt 0) { return $false }
    $joined = @($Commands) -join ','
    return ($joined -ceq 'hello,status,shutdown' -or
        $joined -ceq 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace' -or
        $joined -ceq 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace,network_subscription.quick_call_join')
}

function Test-UiControlSnapshot {
    param([object]$Snapshot)
    $names = @('mode','status','phase','media_seq','diagnostic','bm_state','hri_phase','hri_ready',
        'serial_open','wavein_open','waveout_open','radio_state')
    if (-not (Test-UiExactControlFields -Record $Snapshot -Required $names)) { return $false }
    foreach ($name in @('mode','status','phase','bm_state','hri_phase','radio_state')) {
        if ($Snapshot.PSObject.Properties[$name].Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Snapshot.$name)) { return $false }
    }
    if (-not (Test-UiControlUnsigned -Value $Snapshot.media_seq)) { return $false }
    foreach ($name in @('diagnostic','hri_ready','serial_open','wavein_open','waveout_open')) {
        if ($Snapshot.PSObject.Properties[$name].Value -isnot [bool]) { return $false }
    }
    if ($Snapshot.diagnostic -and ($Snapshot.mode -cne 'diagnostic' -or $Snapshot.status -cne 'running' -or
            $Snapshot.phase -cne 'protocol_diagnostic' -or [uint64]$Snapshot.media_seq -ne 0 -or
            $Snapshot.bm_state -cne 'not_started' -or $Snapshot.hri_phase -cne 'not_started' -or
            $Snapshot.hri_ready -or $Snapshot.serial_open -or $Snapshot.wavein_open -or
            $Snapshot.waveout_open -or $Snapshot.radio_state -cne 'unknown')) { return $false }
    return $true
}

function ConvertFrom-UiControlFrame {
    param([Parameter(Mandatory=$true)][string]$Json, [string]$LockedRunId = '',
        [uint64]$LastControlSequence = 0, [int]$ExpectedProcessId = 0)
    if ([System.Text.Encoding]::UTF8.GetByteCount($Json) -gt 131072) { throw '核心返回的控制消息超过 128 KiB 限制。' }
    try { $record = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch { throw '控制协议 v2 JSON 无法解析。' }
    if ($record -isnot [System.Management.Automation.PSCustomObject] -or
        -not (Test-UiControlUnsigned -Value $record.schema_version -Minimum 2 -Maximum 2) -or
        $record.type -isnot [string]) { throw '控制协议 v2 帧头无效。' }
    if ($record.type -ceq 'routing_state') {
        $names = @('schema_version','type','run_id','control_seq','routing')
        if (-not (Test-UiExactControlFields -Record $record -Required $names) -or
            $record.run_id -isnot [string] -or $record.run_id -cne $LockedRunId -or
            -not (Test-UiControlUnsigned -Value $record.control_seq -Minimum 1) -or
            [uint64]$record.control_seq -le $LastControlSequence -or
            -not (Test-UiRoutingSnapshot -Routing $record.routing)) { throw 'routing_state 字段、run_id、control_seq 或 routing snapshot 无效。' }
        return $record
    }
    if ($record.type -ceq 'control_ready') {
        $names = @('schema_version','type','run_id','control_seq','process_id','control_version','supported_commands','diagnostic')
        if (-not (Test-UiExactControlFields -Record $record -Required $names) -or
            $record.run_id -isnot [string] -or $record.run_id.Length -gt 128 -or
            -not (Test-UiControlUnsigned -Value $record.control_seq -Minimum 1) -or
            -not (Test-UiControlUnsigned -Value $record.process_id -Minimum 1 -Maximum ([uint32]::MaxValue)) -or
            -not (Test-UiControlUnsigned -Value $record.control_version -Minimum 2 -Maximum 2) -or
            $record.diagnostic -isnot [bool] -or -not ($record.supported_commands -is [System.Array]) -or
            -not (Test-UiRoutingCapabilityList -Commands $record.supported_commands)) { throw 'control_ready 字段或支持命令列表无效。' }
        if ([string]$record.run_id -cnotmatch '^[0-9]{1,10}-[0-9]{1,20}$' -or
            ($ExpectedProcessId -gt 0 -and [uint32]$record.process_id -ne [uint32]$ExpectedProcessId) -or
            [uint64]$record.control_seq -le $LastControlSequence -or ($LockedRunId -and $record.run_id -cne $LockedRunId)) {
            throw 'control_ready 的进程、run_id 或 control_seq 与当前子进程不匹配。'
        }
        $runPid = [uint32]0
        $runPidText = ([string]$record.run_id).Split('-')[0]
        if (-not [uint32]::TryParse($runPidText, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$runPid) -or
            $runPid -ne [uint32]$record.process_id) { throw 'control_ready.run_id 的 PID 前缀与 process_id 不符。' }
        return $record
    }
    if ($record.type -cne 'control_result') { throw '控制协议 v2 只接受 control_ready 或 control_result。' }
    $common = @('schema_version','type','run_id','control_seq','request_id','command','result','replayed')
    $validCommands = @('hello','status','shutdown','routing.status','rx_policy.replace','tx_policy.replace','network_subscription.quick_call_join')
    if ($record.command -isnot [string] -or $validCommands -cnotcontains $record.command) { throw 'control_result.command 无效。' }
    $specific = switch -CaseSensitive ([string]$record.command) {
        'hello' { @('supported_commands') }
        'status' { @('snapshot') }
        'shutdown' { @('shutdown_requested') }
        'routing.status' { @('routing') }
        'rx_policy.replace' { @('routing') }
        'tx_policy.replace' { @('routing') }
        'network_subscription.quick_call_join' { @('activation_status','destination_id','slot','frames_sent') }
    }
    if ($record.result -isnot [string] -or @('ok','unsupported','rejected') -cnotcontains $record.result) { throw 'control_result.result 无效。' }
    $requiredResultFields = if ($record.result -ceq 'ok') { $common + $specific } else { $common + @('error') }
    $optionalResultFields = if ($record.result -ceq 'ok') { @('error') } else { @() }
    if (-not (Test-UiExactControlFields -Record $record -Required $requiredResultFields -Optional $optionalResultFields) -or
        $record.run_id -isnot [string] -or $record.request_id -isnot [string] -or
        $record.replayed -isnot [bool] -or -not (Test-UiControlUnsigned -Value $record.control_seq -Minimum 1) -or
        [uint64]$record.control_seq -le $LastControlSequence -or
        [string]::IsNullOrWhiteSpace($LockedRunId) -or $record.run_id -cne $LockedRunId) { throw 'control_result 字段、run_id 或 control_seq 无效。' }
    $requestGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$record.request_id, [ref]$requestGuid)) { throw 'control_result.request_id 无效。' }
    if ($null -ne $record.PSObject.Properties['error'] -and $record.error -isnot [string]) { throw 'control_result.error 必须是字符串。' }
    if ($record.result -cne 'ok' -and [string]::IsNullOrWhiteSpace([string]$record.error)) { throw '拒绝或不支持的响应必须说明 error。' }
    if ($record.result -ceq 'ok') {
        switch -CaseSensitive ([string]$record.command) {
            'hello' {
                if (-not (Test-UiRoutingCapabilityList -Commands $record.supported_commands)) { throw '初始确认返回的命令列表无效。' }
            }
            'status' { if (-not (Test-UiControlSnapshot -Snapshot $record.snapshot)) { throw '状态查询结果无效。' } }
            'shutdown' { if ($record.shutdown_requested -isnot [bool] -or -not $record.shutdown_requested) { throw '停止请求没有得到确认。' } }
            { $_ -in @('routing.status','rx_policy.replace','tx_policy.replace') } {
                if (-not (Test-UiRoutingSnapshot -Routing $record.routing)) { throw '路由设置结果无效。' }
            }
            'network_subscription.quick_call_join' {
                if ($record.activation_status -cne 'request_sent' -or
                    -not (Test-UiControlUnsigned -Value $record.destination_id -Minimum 1 -Maximum 16777215) -or
                    [uint64]$record.destination_id -eq 4000 -or
                    -not (Test-UiControlUnsigned -Value $record.slot -Minimum 1 -Maximum 2) -or
                    -not (Test-UiControlUnsigned -Value $record.frames_sent -Minimum 2 -Maximum 2)) {
                    throw '动态组激活结果字段无效。'
                }
            }
        }
    } elseif ($record.PSObject.Properties['error'] -and $record.error -isnot [string]) { throw '拒绝响应的 error 字段无效。' }
    return $record
}

function Reset-UiControlState {
    param([string]$Text = '本机控制：等待')
    $script:controlRunId = ''
    $script:controlLastSequence = [uint64]0
    $script:controlConfirmed = $false
    $script:controlCapabilities = ''
    $script:routingCapabilities = $false
    $script:quickCallCapabilities = $false
    $script:pendingQuickCall = $null
    $script:pendingDynamicLocalListen = $null
    $script:controlDiagnostic = $false
    $script:controlOverflowHandled = $false
    $script:pendingControlRequests = @{}
    $script:resolvedTimedOutRoutingRequests = @{}
    $script:pendingStatusRequestId = ''
    $script:pendingRoutingStatusRequestId = ''
    $script:pendingRoutingMutation = $null
    $script:timedOutRoutingMutations = @{}
    $script:routingDraftPreservedAfterTimeout = $false
    $script:routingMutationFence = $false
    $script:activeRouting = $null
    if ($script:mainWindow) {
        Set-MainText -Name 'ControlProtocolValue' -Text $Text
        (Get-UiControl 'ControlStatusButton').IsEnabled = $false
        Update-RoutingDisplays
        Set-MainText -Name 'DynamicGroupStatus' -Text '请连接核心与 BM 后操作动态组。'
        Update-DynamicGroupControls
    }
}

function Set-UiControlStatus {
    param([string]$Text, [bool]$Confirmed = $false)
    Set-MainText -Name 'ControlProtocolValue' -Text $Text
    (Get-UiControl 'ControlProtocolValue').Foreground = if ($Confirmed) {
        [Windows.Media.Brushes]::LightGreen
    } else { [Windows.Media.Brushes]::Goldenrod }
    (Get-UiControl 'ControlStatusButton').IsEnabled = ([bool]$Confirmed -and -not [string]::IsNullOrWhiteSpace($script:controlRunId))
}

function Request-UiControlStatus {
    if (-not $script:supervisor -or $script:supervisor.HasExited -or -not $script:controlConfirmed) { return }
    if ($script:pendingStatusRequestId) { return }
    $requestId = [guid]::NewGuid().ToString('D')
    $script:pendingControlRequests[$requestId] = 'status'
    $script:pendingStatusRequestId = $requestId
    if (-not $script:supervisor.SendControlCommand($requestId, 'status')) {
        [void]$script:pendingControlRequests.Remove($requestId)
        $script:pendingStatusRequestId = ''
        Set-UiControlStatus -Text '核心状态查询失败；请检查连接状态。' -Confirmed $false
    }
}

function Process-UiControlEvents {
    if (-not $script:supervisor -or $script:supervisor.ControlVersion -ne 2) { return }
    if ($script:supervisor.HasControlEventOverflow -and -not $script:controlOverflowHandled) {
        $script:controlOverflowHandled = $true
        $script:controlConfirmed = $false
        (Get-UiControl 'ControlStatusButton').IsEnabled = $false
        Set-UiControlStatus -Text '核心返回过多控制消息；当前状态尚未确认。' -Confirmed $false
        Add-UiEvent '控制协议事件队列溢出'
        return
    }
    foreach ($line in @($script:supervisor.DrainControlEvents(32))) {
        try {
            $record = ConvertFrom-UiControlFrame -Json $line -LockedRunId $script:controlRunId `
                -LastControlSequence $script:controlLastSequence -ExpectedProcessId $script:supervisor.ProcessId
        } catch {
            $script:controlConfirmed = $false
            (Get-UiControl 'ControlStatusButton').IsEnabled = $false
            Set-UiControlStatus -Text ('核心控制状态校验失败：' + $_.Exception.Message) -Confirmed $false
            Add-UiEvent '控制协议帧校验失败'
            continue
        }
        $script:controlLastSequence = [uint64]$record.control_seq
        if ($record.type -ceq 'routing_state') {
            if (-not $script:routingCapabilities -or -not $script:controlConfirmed) {
                Set-UiControlStatus -Text '核心在确认设置能力前发送了状态；请重新连接。' -Confirmed $false
                continue
            }
            try {
                $firstRoutingSnapshot = ($null -eq $script:activeRouting -and -not $script:routingDraftPreservedAfterTimeout)
                [void](Set-ActiveRoutingSnapshot -Routing $record.routing -SyncAllEditor:$firstRoutingSnapshot)
                if ($RoutingDiagnosticAutoTest -and -not $script:routingDiagnosticAutoTestStarted) { Start-UiRoutingDiagnosticAutoTest }
            Write-UiRoutingDiagnosticProgress -Message 'routing-state-processed'
            } catch {
                Set-UiControlStatus -Text ('核心设置状态无效：' + $_.Exception.Message) -Confirmed $false
                Add-UiEvent '核心设置状态校验失败'
            }
            continue
        }
        if ($record.type -ceq 'control_ready') {
            if ($script:controlRunId -or -not $script:supervisor.SetControlRunId([string]$record.run_id)) {
                $script:controlConfirmed = $false
                Set-UiControlStatus -Text '无法确认本次核心运行身份' -Confirmed $false
                continue
            }
            $script:controlRunId = [string]$record.run_id
            $script:controlDiagnostic = [bool]$record.diagnostic
            $script:controlCapabilities = @($record.supported_commands) -join ','
            $script:routingCapabilities = ($script:controlCapabilities -ceq 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace' -or
                $script:controlCapabilities -ceq 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace,network_subscription.quick_call_join')
            $script:quickCallCapabilities = ($script:controlCapabilities -ceq 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace,network_subscription.quick_call_join')
            if ($RoutingDiagnosticAutoTest) {
                if ($null -eq $script:settingsWindow) { Initialize-SettingsWindow }
                (Get-SettingsControl 'DestinationBox').Text = '53000'
                $draftSlot = Get-SettingsControl 'SlotBox'
                $draftSlot.SelectedItem = @($draftSlot.Items | Where-Object { [string]$_.Tag -ceq '2' })[0]
                $draftKind = Get-SettingsControl 'CallKindBox'
                $draftKind.SelectedItem = @($draftKind.Items | Where-Object { [string]$_.Tag -ceq 'group' })[0]
                (Get-SettingsControl 'TransmitEnabledBox').IsChecked = $true
                Update-TxTargetButtonState
                $script:settingsWindow.Show()
                Write-UiRoutingDiagnosticProgress -Message 'control-ready-tx-draft-open'
            }
            $requestId = [guid]::NewGuid().ToString('D')
            $script:pendingControlRequests[$requestId] = 'hello'
            Set-UiControlStatus -Text '核心已启动，正在确认本机控制通道' -Confirmed $false
            if (-not $script:supervisor.SendControlCommand($requestId, 'hello')) {
                [void]$script:pendingControlRequests.Remove($requestId)
                Set-UiControlStatus -Text '无法与核心确认设置；请检查连接状态。' -Confirmed $false
            }
            Write-UiRoutingDiagnosticProgress -Message 'hello-sent'
            continue
        }
        if ($record.command -ceq 'shutdown' -and ($script:stopTask -or $script:closingAfterStop)) { continue }
        if (-not $script:pendingControlRequests.ContainsKey([string]$record.request_id) -or
            $script:pendingControlRequests[[string]$record.request_id] -cne [string]$record.command) {
            if ($script:resolvedTimedOutRoutingRequests.ContainsKey([string]$record.request_id) -and
                $script:resolvedTimedOutRoutingRequests[[string]$record.request_id] -ceq [string]$record.command) {
                [void]$script:resolvedTimedOutRoutingRequests.Remove([string]$record.request_id)
                continue
            }
            Set-UiControlStatus -Text '核心返回了未知的控制结果' -Confirmed $false
            continue
        }
        [void]$script:pendingControlRequests.Remove([string]$record.request_id)
        if ($record.command -ceq 'status' -and $script:pendingStatusRequestId -ceq [string]$record.request_id) {
            $script:pendingStatusRequestId = ''
        }
        if ($record.command -ceq 'routing.status' -and $script:pendingRoutingStatusRequestId -ceq [string]$record.request_id) {
            $script:pendingRoutingStatusRequestId = ''
        }
        if ($record.result -cne 'ok') {
            $detail = if ($record.PSObject.Properties['error']) { [string]$record.error } else { [string]$record.result }
            if ($record.command -ceq 'network_subscription.quick_call_join') {
                if ($script:pendingQuickCall -and $script:pendingQuickCall.request_id -ceq [string]$record.request_id) {
                    $script:pendingQuickCall = $null
                }
                if ($RoutingDiagnosticAutoTest) {
                    Fail-UiRoutingDiagnosticDynamicGroupTest -Message ('隔离动态组按钮链失败：' + $detail)
                    continue
                }
                $quickCallError = switch -CaseSensitive ($detail) {
                    'media_busy' { '当前正在收发，请空闲后激活。' }
                    'quick_call_not_ready' { 'BM 或核心未就绪，请检查连接后激活。' }
                    'invalid_or_forbidden_group' { '组号或 TS 无效；TG4000 用于断开动态组。' }
                    'disconnect_group_forbidden' { 'TG4000 用于断开动态组，不能作为激活目标。' }
                    'quick_call_send_failed' { '激活发送失败，请检查 BM 连接后重新激活。' }
                    'quick_call_partial_send' { '激活未完整发送；请重新连接后再尝试激活。' }
                    'quick_call_send_incomplete' { '激活未能完成，请检查 BM 连接后重新激活。' }
                    default { '激活请求未完成：' + $detail }
                }
                Set-DynamicGroupStatus $quickCallError -Failed $true
                Set-UiControlStatus -Text '动态组激活未完成' -Confirmed $script:controlConfirmed
                if ($detail -ceq 'quick_call_partial_send') {
                    Add-UiEvent '动态组激活部分发送：header 已发送，EOT 发送失败；核心没有重试'
                } else {
                    Add-UiEvent ('动态组激活失败：' + $detail)
                }
                Update-DynamicGroupControls
                continue
            }
            Set-UiControlStatus -Text ('设置操作失败：' + $detail) -Confirmed $script:controlConfirmed
            if ($record.command -in @('rx_policy.replace','tx_policy.replace')) {
                if ($record.command -ceq 'rx_policy.replace' -and $script:pendingDynamicLocalListen) {
                    $route = $script:pendingDynamicLocalListen
                    $script:pendingDynamicLocalListen = $null
                    Set-DynamicGroupStatus ('核心拒绝了本机收听规则 TG {0} · TS{1}：{2}' -f $route.destination_id,$route.slot,$detail) -Failed $true
                }
                $failedMutation = $null
                if ($script:pendingRoutingMutation -and $script:pendingRoutingMutation.request_id -ceq [string]$record.request_id) {
                    $failedMutation = $script:pendingRoutingMutation
                    $script:pendingRoutingMutation = $null
                } elseif ($script:timedOutRoutingMutations.ContainsKey([string]$record.request_id)) {
                    $failedMutation = $script:timedOutRoutingMutations[[string]$record.request_id]
                    [void]$script:timedOutRoutingMutations.Remove([string]$record.request_id)
                }
                if ($failedMutation) {
                    $script:routingMutationFence = $true
                    Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                    Set-RoutingEditorStatus -Text ('核心拒绝了这项设置；正在读取当前运行设置。' + $detail) -Failed $true
                    if ($failedMutation.command -ceq 'tx_policy.replace') {
                        Set-MainText -Name 'CallTargetStatusValue' -Text ('核心未接受下一起呼目标设置：' + $detail)
                        if ($script:pendingDynamicCallTarget -and [uint64]$script:pendingDynamicCallTarget.destination_id -eq [uint64]$failedMutation.target.destination_id -and [uint64]$script:pendingDynamicCallTarget.slot -eq [uint64]$failedMutation.target.slot) {
                            Set-DynamicGroupStatus ('核心未接受 TG {0} · TS{1} 起呼目标设置：{2}' -f $failedMutation.target.destination_id,$failedMutation.target.slot,$detail) -Failed $true
                            $script:pendingDynamicCallTarget = $null
                        }
                    }
                    Add-UiEvent '核心拒绝接收路由设置'
                    Request-UiRoutingStatus
                }
            } elseif ($record.command -ceq 'routing.status' -and $script:routingMutationFence) {
                Set-UiControlStatus -Text '当前运行设置无法刷新；路由修改保持锁定，请重新连接。' -Confirmed $false
                Set-RoutingEditorStatus -Text ('当前设置读取失败；没有自动重发任何更改。' + $detail) -Failed $true
            }
            continue
        }
        switch -CaseSensitive ([string]$record.command) {
            'hello' {
                if ((@($record.supported_commands) -join ',') -cne $script:controlCapabilities) {
                    Set-UiControlStatus -Text '核心控制能力与确认结果不一致' -Confirmed $false
                    continue
                }
                $script:controlConfirmed = $true
                Write-UiRoutingDiagnosticProgress -Message 'hello-confirmed'
                $diagLabel = if ($script:controlDiagnostic) { ' · 仅本地诊断' } else { '' }
                if ($script:routingCapabilities) { $diagLabel += ' · 本机路由设置可用' }
                Set-UiControlStatus -Text ('本机控制已确认' + $diagLabel) -Confirmed $true
                Update-DynamicGroupControls
                Add-UiEvent '本机控制已确认'
                if ($script:routingCapabilities) { Request-UiRoutingStatus }
            }
            'network_subscription.quick_call_join' {
                $pendingQuickCall = $script:pendingQuickCall
                $script:pendingQuickCall = $null
                if ($RoutingDiagnosticAutoTest -and $script:routingDiagnosticAutoTestPhase -ne 7) {
                    Fail-UiRoutingDiagnosticDynamicGroupTest -Message '本机收听按钮或测试阶段错误地触发了动态组激活。'
                    continue
                }
                if ($RoutingDiagnosticAutoTest) {
                    if ([uint64]$record.destination_id -ne 46001 -or [uint64]$record.slot -ne 2 -or
                        [uint64]$record.frames_sent -ne 2 -or [string]$record.activation_status -cne 'request_sent' -or
                        [bool]$record.replayed) {
                        Fail-UiRoutingDiagnosticDynamicGroupTest -Message '动态组按钮没有以TG46001/TS2收到新请求的两帧发送结果。'
                        continue
                    }
                    $script:routingDiagnosticDynamicGroupActivationResponse = [pscustomobject][ordered]@{
                        command=[string]$record.command; destination_id=[uint64]$record.destination_id
                        slot=[uint64]$record.slot; frames_sent=[uint64]$record.frames_sent
                        activation_status=[string]$record.activation_status; replayed=[bool]$record.replayed
                    }
                    $script:routingDiagnosticAutoTestPhase = 8
                    Set-DynamicGroupStatus '离线验收：两帧已通过内存接收器；BM 未连接。'
                    Set-UiControlStatus -Text '动态组离线按钮验收已完成' -Confirmed $true
                    Add-UiEvent '离线验收：动态组请求经过内存帧接收器，没有连接 BM'
                    Write-UiRoutingDiagnosticProgress -Message 'dynamic-activation-result-received'
                    Request-UiRoutingStatus
                    Update-DynamicGroupControls
                    continue
                }
                if ($record.replayed) {
                    Set-DynamicGroupStatus ('TG {0} · TS{1}：激活请求已发送，等待该组来话。' -f
                        $record.destination_id,$record.slot)
                } else {
                    Set-DynamicGroupStatus ('TG {0} · TS{1}：激活请求已发送，等待该组来话。' -f
                        $record.destination_id,$record.slot)
                }
                Set-UiControlStatus -Text '动态组激活请求已发送' -Confirmed $true
                Add-UiEvent ('已发送一次动态组激活请求 · TG {0} · TS{1}' -f $record.destination_id,$record.slot)
                if ($record.replayed) { Add-UiEvent '读取已缓存的激活结果；没有再次发送帧' }
                Update-DynamicGroupControls
            }
            'status' {
                $snapshot = $record.snapshot
                if ([bool]$snapshot.diagnostic) {
                    $statusText = '仅本机诊断：未连接 BM、HRI 或音频设备'
                } else {
                    $replayText = if ($record.replayed) { '重放摘要' } else { '状态摘要' }
                    $statusText = ('{0}：{1} / {2} · media_seq {3}' -f $replayText, $snapshot.status, $snapshot.phase, $snapshot.media_seq)
                }
                # This control snapshot never refreshes the v1 media cards or their freshness clock.
                Set-UiControlStatus -Text $statusText -Confirmed $true
            }
            { $_ -in @('routing.status','rx_policy.replace','tx_policy.replace') } {
                if (-not $script:routingCapabilities) {
                    Set-UiControlStatus -Text '核心未提供本机多路由设置' -Confirmed $false
                    continue
                }
                $mutation = $null
                if ($record.command -in @('rx_policy.replace','tx_policy.replace')) {
                    if ($script:pendingRoutingMutation -and $script:pendingRoutingMutation.request_id -ceq [string]$record.request_id -and
                        $script:pendingRoutingMutation.command -ceq [string]$record.command) {
                        $mutation = $script:pendingRoutingMutation
                    } elseif ($script:timedOutRoutingMutations.ContainsKey([string]$record.request_id) -and
                        $script:timedOutRoutingMutations[[string]$record.request_id].command -ceq [string]$record.command) {
                        $mutation = $script:timedOutRoutingMutations[[string]$record.request_id]
                    } else {
                        $script:routingMutationFence = $true
                        Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                        Set-UiControlStatus -Text '收到的设置结果不属于当前请求；正在读取当前设置。' -Confirmed $false
                        Request-UiRoutingStatus
                        continue
                    }
                }
                if ($record.replayed) {
                    if ($mutation) {
                        if ($script:pendingRoutingMutation -and $script:pendingRoutingMutation.request_id -ceq [string]$record.request_id) { $script:pendingRoutingMutation = $null }
                        [void]$script:timedOutRoutingMutations.Remove([string]$record.request_id)
                        $script:routingDraftPreservedAfterTimeout = ($script:timedOutRoutingMutations.Count -gt 0)
                        $script:routingMutationFence = $true
                        Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                        Set-RoutingEditorStatus -Text '该设置请求已处理过；没有再次保存，正在读取当前设置。' -Failed $true
                    }
                    $script:routingMutationFence = $true
                    Request-UiRoutingStatus
                    continue
                }
                try {
                    $matchingPending = ($script:pendingRoutingMutation -and
                        $script:pendingRoutingMutation.request_id -ceq [string]$record.request_id)
                    $syncRxEditor = ($matchingPending -and $record.command -ceq 'rx_policy.replace')
                    $syncTxEditor = ($matchingPending -and $record.command -ceq 'tx_policy.replace')
                    $snapshotAccepted = Set-ActiveRoutingSnapshot -Routing $record.routing -SyncRxEditor:$syncRxEditor -SyncTxEditor:$syncTxEditor
                } catch {
                    Set-UiControlStatus -Text ('核心返回的设置状态无效：' + $_.Exception.Message) -Confirmed $false
                    Request-UiRoutingStatus
                    continue
                }
                if (-not $snapshotAccepted) {
                    $script:routingMutationFence = $true
                    Request-UiRoutingStatus
                    continue
                }
                if ($record.command -ceq 'routing.status') {
                    $wasFenced = $script:routingMutationFence
                    foreach ($timedOutRequestId in @($script:timedOutRoutingMutations.Keys)) {
                        $script:resolvedTimedOutRoutingRequests[$timedOutRequestId] = [string]$script:timedOutRoutingMutations[$timedOutRequestId].command
                        [void]$script:pendingControlRequests.Remove([string]$timedOutRequestId)
                        [void]$script:timedOutRoutingMutations.Remove([string]$timedOutRequestId)
                    }
                    $script:routingDraftPreservedAfterTimeout = $false
                    $script:routingMutationFence = $false
                    Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                    if ($wasFenced) {
                        $script:routingDraftPreservedAfterTimeout = $true
                        Set-RoutingEditorStatus -Text '当前运行设置已刷新；未确认的草稿仍在设置中保留，未自动重发。' -Failed $true
                        Set-UiControlStatus -Text '当前运行设置已刷新，草稿已保留' -Confirmed $true
                    } else { Set-UiControlStatus -Text '当前运行设置已刷新' -Confirmed $true }
                    if ($script:routingDiagnosticFenceProbeWaiting) { Continue-UiRoutingDiagnosticAutoTestAfterFenceRefresh }
                    if ($RoutingDiagnosticAutoTest -and $script:routingDiagnosticAutoTestPhase -eq 8) {
                        Complete-UiRoutingDiagnosticDynamicGroupTest -Routing $record.routing
                    }
                    continue
                }
                if ($script:pendingRoutingMutation -and $script:pendingRoutingMutation.request_id -ceq [string]$record.request_id) { $script:pendingRoutingMutation = $null }
                [void]$script:timedOutRoutingMutations.Remove([string]$record.request_id)
                $script:routingDraftPreservedAfterTimeout = ($script:timedOutRoutingMutations.Count -gt 0)
                if ($script:routingMutationFence -and $script:timedOutRoutingMutations.Count -eq 0) { $script:routingMutationFence = $false }
                Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                Save-UiRoutingMutationAfterAck -Mutation $mutation -Routing $record.routing
                Set-UiControlStatus -Text $(if ($mutation.command -ceq 'tx_policy.replace') { '下一起呼目标设置已确认' } else { '设置已应用' }) -Confirmed $true
                if ($mutation.command -ceq 'tx_policy.replace' -and $script:pendingDynamicCallTarget -and
                    [uint64]$script:pendingDynamicCallTarget.destination_id -eq [uint64]$mutation.target.destination_id -and
                    [uint64]$script:pendingDynamicCallTarget.slot -eq [uint64]$mutation.target.slot) {
                    Set-DynamicGroupStatus ('核心已确认 TG {0} · TS{1} 为下一起呼目标；没有发起呼叫，收听规则未变。' -f $mutation.target.destination_id,$mutation.target.slot)
                    $script:pendingDynamicCallTarget = $null
                }
                if ($record.command -ceq 'rx_policy.replace' -and $script:pendingDynamicLocalListen) {
                    $route = $script:pendingDynamicLocalListen
                    $script:pendingDynamicLocalListen = $null
                    Set-DynamicGroupStatus ('本机收听规则已由核心确认：TG {0} · TS{1}；没有发送动态组激活请求。' -f $route.destination_id,$route.slot)
                }
                if ($RoutingDiagnosticAutoTest) { Complete-UiRoutingDiagnosticAutoTest -Mutation $mutation -Routing $record.routing }
            }
        }
    }
}

function Test-UiRoutingStateFile {
    param([string]$Path,[string]$ExpectedSourceId,[string]$ExpectedDestinationId,[string]$ExpectedSlot,[string]$ExpectedKind)
    if (-not [System.IO.File]::Exists($Path) -or (New-Object System.IO.FileInfo($Path)).Length -gt 65536) { throw '预检 routing-state.json 缺失或超过 64 KiB。' }
    try { $state = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path,[System.Text.Encoding]::UTF8)) -ErrorAction Stop }
    catch { throw '预检 routing-state.json JSON 无效。' }
    if (-not (Test-UiExactControlFields -Record $state -Required @('schema_version','local_source_id','rx_policy','tx_target','transmit_enabled')) -or
        -not (Test-UiControlUnsigned -Value $state.schema_version -Minimum 1 -Maximum 1) -or
        -not (Test-UiControlUnsigned -Value $state.local_source_id -Minimum 1 -Maximum 16777215) -or
        [string]$state.local_source_id -cne $ExpectedSourceId -or
        $state.transmit_enabled -isnot [bool] -or
        -not (Test-UiRxPolicy -Policy $state.rx_policy -LocalSourceId ([uint64]$state.local_source_id))) { throw '预检 routing-state.json schema 1 或 RX 策略无效。' }
    if (-not (Test-UiExactControlFields -Record $state.tx_target -Required @('destination_id','kind','slot')) -or
        -not (Test-UiControlUnsigned -Value $state.tx_target.destination_id -Minimum 1 -Maximum 16777215) -or
        -not (Test-UiControlUnsigned -Value $state.tx_target.slot -Minimum 1 -Maximum 2) -or
        $state.tx_target.kind -isnot [string] -or @('group','private') -cnotcontains [string]$state.tx_target.kind -or
        [string]$state.tx_target.destination_id -cne $ExpectedDestinationId -or
        [string]$state.tx_target.slot -cne $ExpectedSlot -or
        [string]$state.tx_target.kind -cne $(if ($ExpectedKind -ceq 'G') { 'group' } else { 'private' })) {
        throw '预检 routing-state.json 的 TX 目标与本次连接配置不一致。'
    }
    return $state
}

function Test-UiPreparationRecord {
    param(
        [Parameter(Mandatory=$true)][object]$Record,
        [Parameter(Mandatory=$true)][string]$RunDirectory,
        [Parameter(Mandatory=$true)][string]$RunRoot,
        [Parameter(Mandatory=$true)][string]$ExpectedExecutable
    )
    if ($Record -isnot [System.Management.Automation.PSCustomObject] -or
        $Record.schema_version -is [bool] -or
        -not ($Record.schema_version -is [int] -or $Record.schema_version -is [long]) -or
        $Record.schema_version -ne 1 -or
        $Record.executable -isnot [string] -or
        $Record.status_path -isnot [string] -or
        $Record.routing_state_path -isnot [string] -or
        $Record.arguments -isnot [System.Array]) {
        throw '设备预检返回的启动参数结构无效。'
    }

    $runPath = [System.IO.Path]::GetFullPath($RunDirectory)
    $runParent = [System.IO.Path]::GetFullPath($RunRoot)
    $runGuid = [guid]::Empty
    if (-not [guid]::TryParseExact([System.IO.Path]::GetFileName($runPath), 'N', [ref]$runGuid) -or
        -not [string]::Equals([System.IO.Path]::GetDirectoryName($runPath).TrimEnd('\'),
            $runParent.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '本次启动目录不属于 UI 创建的 GUID 运行目录。'
    }

    $expectedExe = [System.IO.Path]::GetFullPath($ExpectedExecutable)
    $recordExe = [System.IO.Path]::GetFullPath($Record.executable)
    if (-not [System.IO.File]::Exists($expectedExe) -or
        -not [string]::Equals($recordExe, $expectedExe, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '设备预检返回的 native 核心与当前所选便携目录不符。'
    }

    $statusPath = [System.IO.Path]::GetFullPath($Record.status_path)
    $statusDirectory = [System.IO.Path]::GetDirectoryName($statusPath)
    $statusName = [System.IO.Path]::GetFileName($statusPath)
    if (-not [string]::Equals($statusDirectory.TrimEnd('\'), $runPath.TrimEnd('\'),
            [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace($statusName) -or
        -not [string]::Equals([System.IO.Path]::GetExtension($statusName), '.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '设备预检返回的状态文件不属于本次启动目录。'
    }
    $routingStatePath = [System.IO.Path]::GetFullPath($Record.routing_state_path)
    if (-not [string]::Equals([System.IO.Path]::GetDirectoryName($routingStatePath).TrimEnd('\'),$runPath.TrimEnd('\'),[System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFileName($routingStatePath),'routing-state.json',[System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'routing-state.json 必须位于本次 GUID 运行目录中。'
    }

    $arguments = @($Record.arguments)
    if ($arguments.Count -lt 20 -or @($arguments | Where-Object { $_ -isnot [string] }).Count -ne 0) {
        throw '设备预检返回的启动参数不完整。'
    }
    $valueOptions = @(
        '--port', '--body-file', '--input', '--output', '--status-file',
        '--expected-wavein-endpoint', '--expected-waveout-endpoint',
        '--radio-playback-gain', '--mic-transmit-gain', '--password-file',
        '--routing-state-file',
        '--ui-control-version',
        '--profile-callsign', '--profile-gateway-id', '--profile-source-id',
        '--profile-master', '--profile-master-port', '--profile-destination-id',
        '--profile-slot', '--profile-color-code', '--profile-call-kind'
    )
    $switchOptions = @('--run', '--ui-pipe', '--listen-only')
    $parsedArguments = @{}
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $name = [string]$arguments[$index]
        if ($parsedArguments.ContainsKey($name) -or
            (($valueOptions -cnotcontains $name) -and ($switchOptions -cnotcontains $name))) {
            throw '设备预检返回了重复或不受支持的启动参数。'
        }
        if ($valueOptions -ccontains $name) {
            if ($index + 1 -ge $arguments.Count -or [string]$arguments[$index + 1] -like '--*') {
                throw '设备预检返回的启动参数缺少值。'
            }
            $parsedArguments[$name] = [string]$arguments[$index + 1]
            $index++
        } else {
            $parsedArguments[$name] = $true
        }
    }
    foreach ($requiredOption in @(
        '--run', '--ui-pipe', '--port', '--body-file', '--input', '--output', '--status-file',
        '--expected-wavein-endpoint', '--expected-waveout-endpoint', '--radio-playback-gain', '--mic-transmit-gain',
        '--password-file', '--ui-control-version', '--profile-callsign', '--profile-gateway-id', '--profile-source-id',
        '--profile-master', '--profile-master-port', '--profile-destination-id', '--profile-slot',
        '--profile-color-code', '--profile-call-kind', '--routing-state-file'
    )) {
        if (-not $parsedArguments.ContainsKey($requiredOption)) { throw '设备预检返回的启动参数不完整。' }
    }
    if ($parsedArguments['--profile-call-kind'] -cnotin @('G', 'P')) {
        throw '设备预检返回的发射呼叫类型无效。'
    }
    if ($parsedArguments['--ui-control-version'] -cne '2') { throw '设备预检必须启用 UI 控制协议 v2。' }
    $pipeCount = 0
    $statusValue = ''
    $statusCount = 0
    $routingStateValue = ''
    $routingStateCount = 0
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        if ($arguments[$index] -ceq '--ui-pipe') { $pipeCount++ }
        if ($arguments[$index] -ceq '--status-file') {
            $statusCount++
            if ($index + 1 -ge $arguments.Count) { throw '设备预检返回的状态参数缺少路径。' }
            $statusValue = [string]$arguments[$index + 1]
        }
        if ($arguments[$index] -ceq '--routing-state-file') {
            $routingStateCount++
            if ($index + 1 -ge $arguments.Count) { throw '设备预检返回的 routing-state-file 参数缺少路径。' }
            $routingStateValue = [string]$arguments[$index + 1]
        }
    }
    if ($pipeCount -ne 1 -or $statusCount -ne 1 -or $routingStateCount -ne 1 -or
        -not [string]::Equals([System.IO.Path]::GetFullPath($statusValue), $statusPath,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath($routingStateValue),$routingStatePath,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw '设备预检返回的启动参数与状态或 routing-state 文件路径不一致。'
    }
    [void](Test-UiRoutingStateFile -Path $routingStatePath -ExpectedSourceId $parsedArguments['--profile-source-id'] `
        -ExpectedDestinationId $parsedArguments['--profile-destination-id'] -ExpectedSlot $parsedArguments['--profile-slot'] `
        -ExpectedKind $parsedArguments['--profile-call-kind'])
    return [pscustomobject]@{
        Executable = $expectedExe
        Arguments = [string[]]$arguments
        StatusPath = $statusPath
        RoutingStatePath = $routingStatePath
    }
}

function Start-UiAudioQuery {
    param([Parameter(Mandatory=$true)][string]$Executable, [string]$Arguments = '--list-audio-json', [int]$TimeoutMilliseconds = 10000)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Arguments
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
        if (-not $process.Start()) { throw '未能启动音频设备查询进程。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        return [pscustomobject]@{
            Process = $process
            StdoutTask = $stdoutTask
            StderrTask = $stderrTask
            StartedUtc = [DateTime]::UtcNow
            TimeoutMilliseconds = $TimeoutMilliseconds
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Request-StopUiAudioQuery {
    param([Parameter(Mandatory=$true)][object]$Query)
    if (-not $Query.Process.HasExited) {
        try { $Query.Process.Kill() }
        catch {
            if (-not $Query.Process.HasExited) { throw '无法停止音频设备查询进程。' }
        }
    }
}

function Test-UiAudioQueryExpired {
    param([Parameter(Mandatory=$true)][object]$Query, [DateTime]$NowUtc = [DateTime]::UtcNow)
    return (($NowUtc - $Query.StartedUtc).TotalMilliseconds -ge $Query.TimeoutMilliseconds)
}

function Read-UiAudioQueryResult {
    param([Parameter(Mandatory=$true)][object]$Query)
    if (-not $Query.Process.HasExited -or -not $Query.StdoutTask.IsCompleted -or -not $Query.StderrTask.IsCompleted) {
        return [pscustomobject]@{ Completed = $false; Audio = $null }
    }
    if ($Query.Process.ExitCode -ne 0) { throw 'native 音频设备查询失败。' }
    $json = $Query.StdoutTask.GetAwaiter().GetResult().Trim().TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($json) -or $json.Contains("`n") -or $json.Contains("`r")) {
        throw 'native 音频设备查询必须只输出一行 JSON。'
    }
    $audio = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    if ($null -eq $audio -or $audio.schema_version -ne 1 -or $audio.type -cne 'audio_devices' -or
        -not $audio.PSObject.Properties['wave_inputs'] -or -not $audio.PSObject.Properties['wave_outputs']) {
        throw 'native 音频设备列表格式无效。'
    }
    foreach ($direction in @('wave_inputs', 'wave_outputs')) {
        $seenIds = @{}
        $seenEndpoints = @{}
        foreach ($device in @($audio.$direction)) {
            if ($null -eq $device -or $device.name -isnot [string] -or
                $device.pcm_48000_mono_s16_supported -isnot [bool] -or
                ($null -ne $device.endpoint_id -and $device.endpoint_id -isnot [string]) -or
                $device.id -is [bool] -or -not ($device.id -is [int] -or $device.id -is [long]) -or $device.id -lt 0) {
                throw 'native 音频设备列表包含无效项目。'
            }
            if ($seenIds.ContainsKey([string]$device.id)) { throw 'native 音频设备列表包含重复 WinMM ID。' }
            $seenIds[[string]$device.id] = $true
            if ($device.endpoint_id -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$device.endpoint_id)) {
                $key = ([string]$device.endpoint_id).ToUpperInvariant()
                if ($seenEndpoints.ContainsKey($key)) { throw 'native 音频设备列表包含重复稳定端点标识。' }
                $seenEndpoints[$key] = $true
            }
        }
    }
    return [pscustomobject]@{ Completed = $true; Audio = $audio }
}

function Test-UiDiscoveryResultOwner {
    param([uint64]$ResultGeneration, [uint64]$CurrentGeneration, [object]$ResultWindow, [object]$CurrentWindow)
    return ($ResultGeneration -eq $CurrentGeneration -and
        [object]::ReferenceEquals($ResultWindow, $CurrentWindow) -and $null -ne $CurrentWindow)
}

function Start-UiDeviceDiscovery {
    if ($RoutingDiagnostic) {
        $script:deviceDiscoveryState = 'diagnostic'
        $script:deviceCatalog = [pscustomobject]@{ serial_ports=@(); hri_ports=@(); wave_inputs=@(); wave_outputs=@() }
        Set-SettingsDeviceControls
        if ($script:settingsWindow) {
            (Get-SettingsControl 'DeviceDiscoveryText').Text = '本地协议测试：设备列表为空（模拟），未查询真实设备。'
            (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
        }
        return
    }
    if ($OfflinePreview -or $RenderOnly) {
        $script:deviceDiscoveryState = 'offline'
        Set-SettingsDeviceControls
        return
    }
    if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) {
        if ($script:settingsWindow -and -not [object]::ReferenceEquals($script:settingsWindow, $script:deviceDiscoveryOwnerWindow)) {
            $script:deviceDiscoveryRestartPending = $true
            (Get-SettingsControl 'DeviceDiscoveryText').Text = '正在结束上次查询，随后重新读取设备列表。'
            (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
        }
        return
    }

    $script:deviceDiscoveryGeneration++
    $script:deviceDiscoveryActiveGeneration = $script:deviceDiscoveryGeneration
    $script:deviceDiscoveryOwnerWindow = $script:settingsWindow
    $script:deviceDiscoveryStopReason = ''
    $script:deviceDiscoveryError = ''
    $script:deviceDiscoveryState = 'loading'
    if ($script:settingsWindow) {
        (Get-SettingsControl 'DeviceDiscoveryText').Text = '正在读取串口与音频设备列表。'
        (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
        Set-SettingsDeviceControls
    }
    try {
        $script:deviceAudioQuery = Start-UiAudioQuery -Executable $script:nativeExecutable
    } catch {
        $script:deviceDiscoveryState = 'failed'
        $script:deviceDiscoveryError = $_.Exception.Message
        Set-SettingsDeviceControls
        if ($script:settingsWindow) { (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $true }
        return
    }
    $catalogScript = {
        $ErrorActionPreference = 'Stop'
        $serialNames = @{}
        $serialKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DEVICEMAP\SERIALCOMM', $false)
        if ($serialKey) {
            try {
                foreach ($valueName in $serialKey.GetValueNames()) {
                    $port = [string]$serialKey.GetValue($valueName)
                    if ($port -match '^COM[1-9][0-9]{0,2}$') { $serialNames[$port.ToUpperInvariant()] = [pscustomobject]@{ PortName = $port.ToUpperInvariant(); FriendlyName = ''; InstanceId = ''; IsHri = $false } }
                }
            } finally { $serialKey.Dispose() }
        }
        $hriPorts = @{}
        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            foreach ($device in @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue)) {
                $instanceId = [string]$device.InstanceId
                $identity = [regex]::Match($instanceId, '^USB\\VID_26AA&PID_([0-9A-F]{4})\\', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $identity.Success -or [Convert]::ToInt32($identity.Groups[1].Value, 16) -lt 0x0030) { continue }
                $busDescription = ''
                if (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue) {
                    $property = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction SilentlyContinue
                    if ($property) { $busDescription = [string]$property.Data }
                }
                $friendlyName = [string]$device.FriendlyName
                $portMatch = [regex]::Match($friendlyName, '\((COM[1-9][0-9]*)\)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $portMatch.Success) { continue }
                $portName = $portMatch.Groups[1].Value.ToUpperInvariant()
                $hriPorts[$portName] = [pscustomobject]@{
                    PortName = $portName
                    FriendlyName = $friendlyName
                    InstanceId = $instanceId
                    IsHri = ($busDescription -match '(?i)\bHRI\b')
                }
            }
        }
        foreach ($portName in @($hriPorts.Keys)) { $serialNames[$portName] = $hriPorts[$portName] }
        return [pscustomobject]@{
            serial_ports = @($serialNames.Values | Sort-Object PortName)
            hri_ports = @($hriPorts.Values | Where-Object { $_.IsHri } | Sort-Object PortName)
        }
    }
    try {
        $script:deviceDiscoveryPowerShell = [System.Management.Automation.PowerShell]::Create()
        [void]$script:deviceDiscoveryPowerShell.AddScript($catalogScript.ToString())
        $script:deviceDiscoveryStartedUtc = [DateTime]::UtcNow
        $script:deviceDiscoveryAsync = $script:deviceDiscoveryPowerShell.BeginInvoke()
    } catch {
        if ($script:deviceDiscoveryPowerShell) {
            try { $script:deviceDiscoveryPowerShell.Dispose() } catch { }
            $script:deviceDiscoveryPowerShell = $null
        }
        $script:deviceDiscoveryAsync = $null
        $script:deviceDiscoveryState = 'stopping'
        $script:deviceDiscoveryStopReason = 'serial_start_error'
        $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
        $script:deviceDiscoveryError = $_.Exception.Message
        if ($script:deviceAudioQuery) {
            try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
            catch { $script:deviceDiscoveryError = $_.Exception.Message }
        }
    }
}

function New-UiDeviceOption {
    param([string]$Label, [string]$Value, [bool]$IsAvailable, [string]$Kind)
    return [pscustomobject]@{ Label = $Label; Value = $Value; IsAvailable = $IsAvailable; Kind = $Kind }
}

function Get-UiEndpointOptions {
    param([object[]]$Devices, [string]$SavedEndpoint, [ValidateSet('input', 'output')][string]$Direction, [switch]$DiscoveryPending)
    $usable = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -eq $true -and $_.endpoint_id -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    $options = New-Object 'System.Collections.Generic.List[object]'
    [void]$options.Add((New-UiDeviceOption -Label '自动：唯一 USB Audio 端点' -Value 'auto' -IsAvailable $true -Kind 'auto'))
    foreach ($device in @($usable | Sort-Object name, endpoint_id)) {
        $label = ('{0} · {1} · ID {2}' -f [string]$device.name, [string]$device.endpoint_id, [string]$device.id)
        [void]$options.Add((New-UiDeviceOption -Label $label -Value ([string]$device.endpoint_id) -IsAvailable $true -Kind $Direction))
    }
    $selected = 'auto'
    if ($SavedEndpoint -and $SavedEndpoint -cne 'auto') {
        $matches = @($usable | Where-Object { [string]::Equals([string]$_.endpoint_id, $SavedEndpoint, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -eq 1) {
            $selected = [string]$matches[0].endpoint_id
        } else {
            $missingLabel = if ($DiscoveryPending) { '正在检查已保存端点 · ' + $SavedEndpoint } else { '已保存端点当前未发现 · ' + $SavedEndpoint }
            $missingKind = if ($DiscoveryPending) { 'pending' } else { 'missing' }
            [void]$options.Add((New-UiDeviceOption -Label $missingLabel -Value $SavedEndpoint -IsAvailable ([bool]$DiscoveryPending) -Kind $missingKind))
            $selected = $SavedEndpoint
        }
    } else {
        $usbMatches = @($usable | Where-Object { [string]$_.name -match '(?i)USB Audio' })
        if ($usbMatches.Count -eq 1) { $selected = [string]$usbMatches[0].endpoint_id }
    }
    return [pscustomobject]@{ Items = $options.ToArray(); SelectedValue = $selected; UsableCount = $usable.Count }
}

function Get-UiSerialOptions {
    param([object[]]$AllPorts, [object[]]$HriPorts, [string]$SavedPort = 'auto', [switch]$DiscoveryPending)
    $options = New-Object 'System.Collections.Generic.List[object]'
    [void]$options.Add((New-UiDeviceOption -Label '自动：唯一 HRI 设备' -Value 'auto' -IsAvailable $true -Kind 'auto'))
    foreach ($port in @($AllPorts | Sort-Object @{Expression={ if ($_.IsHri -and $_.PortName -ceq 'COM5') { 0 } elseif ($_.IsHri) { 1 } else { 2 } }}, PortName)) {
        $identity = if ($port.IsHri) { 'HRI' } elseif ($port.FriendlyName) { '未确认 HRI' } else { '设备信息未确认' }
        $friendly = if ($port.FriendlyName) { [string]$port.FriendlyName } else { [string]$port.PortName }
        [void]$options.Add((New-UiDeviceOption -Label ('{0} · {1} · {2}' -f $friendly, $port.PortName, $identity) `
            -Value ([string]$port.PortName) -IsAvailable ([bool]$port.IsHri) -Kind 'serial'))
    }
    $selected = 'auto'
    if ($SavedPort -and $SavedPort -cne 'auto') {
        $matches = @($HriPorts | Where-Object { $_.PortName -ieq $SavedPort })
        if ($matches.Count -eq 1) { $selected = [string]$matches[0].PortName }
        else {
            $missingLabel = if ($DiscoveryPending) { '正在检查已保存 HRI 串口 · ' + $SavedPort } else { '已保存串口当前未发现为 HRI · ' + $SavedPort }
            $missingKind = if ($DiscoveryPending) { 'pending' } else { 'missing' }
            [void]$options.Add((New-UiDeviceOption -Label $missingLabel -Value $SavedPort -IsAvailable ([bool]$DiscoveryPending) -Kind $missingKind))
            $selected = $SavedPort
        }
    } else {
        $com5 = @($HriPorts | Where-Object { $_.PortName -ceq 'COM5' })
        if ($com5.Count -eq 1) { $selected = 'COM5' }
        elseif ($HriPorts.Count -eq 1) { $selected = [string]$HriPorts[0].PortName }
    }
    return [pscustomobject]@{ Items = $options.ToArray(); SelectedValue = $selected; HriCount = $HriPorts.Count }
}

function Set-UiDeviceComboOptions {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo,
        [Parameter(Mandatory=$true)][object[]]$Options,
        [Parameter(Mandatory=$true)][string]$SelectedValue)
    $Combo.Items.Clear()
    $selectedContainer = $null
    foreach ($option in $Options) {
        if ($null -eq $option -or $option.Label -isnot [string] -or $option.Value -isnot [string] -or $option.IsAvailable -isnot [bool]) {
            throw '设备选项缺少显示标签或稳定值。'
        }
        $container = New-Object System.Windows.Controls.ComboBoxItem
        $container.Content = [string]$option.Label
        $container.Tag = $option
        $container.ToolTip = [string]$option.Label
        [void]$Combo.Items.Add($container)
        if ([string]::Equals([string]$option.Value, $SelectedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            $selectedContainer = $container
        }
    }
    $Combo.SelectedItem = $selectedContainer
    if ($null -eq $selectedContainer) { throw '当前设备选择没有对应的列表项。' }
}

function Set-SettingsDeviceControls {
    if (-not $script:settingsWindow) { return }
    $serialControl = Get-SettingsControl 'SerialBox'
    $inputControl = Get-SettingsControl 'WaveInEndpointBox'
    $outputControl = Get-SettingsControl 'WaveOutEndpointBox'
    $savedSerial = if ($script:storedProfile) { [string]$script:storedProfile.devices.serial_port } else { 'auto' }
    $savedInput = if ($script:storedProfile) { [string]$script:storedProfile.devices.wave_in_endpoint_id } else { 'auto' }
    $savedOutput = if ($script:storedProfile) { [string]$script:storedProfile.devices.wave_out_endpoint_id } else { 'auto' }
    $catalog = $script:deviceCatalog
    $allPorts = if ($catalog) { @($catalog.serial_ports) } else { @() }
    $hriPorts = if ($catalog) { @($catalog.hri_ports) } else { @() }
    $discoveryPending = ($script:deviceDiscoveryState -in @('not_started', 'loading', 'stopping'))
    $serialSetup = Get-UiSerialOptions -AllPorts $allPorts -HriPorts $hriPorts -SavedPort $savedSerial -DiscoveryPending:$discoveryPending
    Set-UiDeviceComboOptions -Combo $serialControl -Options $serialSetup.Items -SelectedValue $serialSetup.SelectedValue

    $inputCatalog = if ($catalog) { @($catalog.wave_inputs) } else { @() }
    $outputCatalog = if ($catalog) { @($catalog.wave_outputs) } else { @() }
    $inputOptions = Get-UiEndpointOptions -Devices $inputCatalog -SavedEndpoint $savedInput -Direction input -DiscoveryPending:$discoveryPending
    $outputOptions = Get-UiEndpointOptions -Devices $outputCatalog -SavedEndpoint $savedOutput -Direction output -DiscoveryPending:$discoveryPending
    Set-UiDeviceComboOptions -Combo $inputControl -Options $inputOptions.Items -SelectedValue $inputOptions.SelectedValue
    Set-UiDeviceComboOptions -Combo $outputControl -Options $outputOptions.Items -SelectedValue $outputOptions.SelectedValue

    $discoveryText = ''
    if ($script:deviceDiscoveryState -eq 'ready') {
        $discoveryText = ('串口 {0} · 输入 {1} · 输出 {2}' -f $allPorts.Count,$inputCatalog.Count,$outputCatalog.Count)
    } elseif ($script:deviceDiscoveryState -eq 'failed') { $discoveryText = '设备读取失败' }
    $discoveryControl = Get-SettingsControl 'DeviceDiscoveryText'
    $discoveryControl.Text = $discoveryText
    $discoveryControl.Visibility = if ($discoveryText) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Complete-UiDeviceDiscovery {
    if (-not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery) { return }
    if (-not $script:deviceDiscoveryStopAsync -and $script:deviceDiscoveryState -eq 'loading') {
        if ($script:deviceAudioQuery -and (Test-UiAudioQueryExpired -Query $script:deviceAudioQuery)) {
            $script:deviceDiscoveryState = 'stopping'
            $script:deviceDiscoveryStopReason = 'audio_timeout'
            $script:deviceDiscoveryError = '音频设备查询超过 10 秒，已请求停止。'
        } elseif (([DateTime]::UtcNow - $script:deviceDiscoveryStartedUtc).TotalSeconds -gt 25) {
            $script:deviceDiscoveryState = 'stopping'
            $script:deviceDiscoveryStopReason = 'timeout'
            $script:deviceDiscoveryError = '本机设备查询超过 25 秒，已请求停止。'
        }
        if ($script:deviceDiscoveryStopReason) {
            $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
            if ($script:deviceAudioQuery) {
                try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
                catch { $script:deviceDiscoveryError = $_.Exception.Message }
            }
            if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted) {
                try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) }
                catch { if (-not $script:deviceDiscoveryAsync.IsCompleted) { $script:deviceDiscoveryError = '串口设备查询未能及时停止。' } }
            }
            if ($script:settingsWindow -and [object]::ReferenceEquals($script:settingsWindow, $script:deviceDiscoveryOwnerWindow)) {
                (Get-SettingsControl 'DeviceDiscoveryText').Text = '正在停止设备查询。'
            }
        }
    }

    $generation = $script:deviceDiscoveryActiveGeneration
    $ownerWindow = $script:deviceDiscoveryOwnerWindow
    $resultBelongsToWindow = Test-UiDiscoveryResultOwner -ResultGeneration $generation `
        -CurrentGeneration $script:deviceDiscoveryGeneration -ResultWindow $ownerWindow -CurrentWindow $script:settingsWindow
    $acceptResult = $resultBelongsToWindow
    $audioDone = ($null -eq $script:deviceAudioQuery)
    $audio = $null
    if ($script:deviceAudioQuery) {
        if ($script:deviceDiscoveryStopReason) {
            $query = $script:deviceAudioQuery
            if ($query.Process.HasExited -and $query.StdoutTask.IsCompleted -and $query.StderrTask.IsCompleted) {
                $query.Process.Dispose()
                $script:deviceAudioQuery = $null
                $audioDone = $true
            }
        } else {
            try {
                $audioResult = Read-UiAudioQueryResult -Query $script:deviceAudioQuery
                if ($audioResult.Completed) {
                    $audio = $audioResult.Audio
                    $script:deviceAudioQuery.Process.Dispose()
                    $script:deviceAudioQuery = $null
                    $audioDone = $true
                }
            } catch {
                $script:deviceDiscoveryError = $_.Exception.Message
                $query = $script:deviceAudioQuery
                if ($query.Process.HasExited -and $query.StdoutTask.IsCompleted -and $query.StderrTask.IsCompleted) {
                    try { $query.Process.Dispose() } catch { }
                    $script:deviceAudioQuery = $null
                    $audioDone = $true
                }
                if (-not $script:deviceDiscoveryStopReason) {
                    $script:deviceDiscoveryState = 'stopping'
                    $script:deviceDiscoveryStopReason = 'audio_error'
                    $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
                    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted) {
                        try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) } catch { }
                    }
                }
            }
        }
    }

    $serialDone = ($null -eq $script:deviceDiscoveryPowerShell)
    $serialRecords = $null
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync) {
        if ($script:deviceDiscoveryStopAsync) {
            $serialDone = $script:deviceDiscoveryStopAsync.IsCompleted
        } elseif ($script:deviceDiscoveryAsync.IsCompleted) {
            $serialDone = $true
            try {
                $serialRecords = $script:deviceDiscoveryPowerShell.EndInvoke($script:deviceDiscoveryAsync)
                if ($script:deviceDiscoveryPowerShell.HadErrors -or $serialRecords.Count -ne 1) {
                    throw '串口设备查询没有返回有效列表。'
                }
            } catch {
                $script:deviceDiscoveryError = $_.Exception.Message
                $script:deviceDiscoveryState = 'failed'
                $script:deviceDiscoveryStopReason = 'serial_error'
            }
        }
    }

    if (-not $audioDone -or -not $serialDone) {
        if ($script:closingAfterDeviceDiscovery -and $script:deviceDiscoveryStopStartedUtc -ne [DateTime]::MinValue -and
            ([DateTime]::UtcNow - $script:deviceDiscoveryStopStartedUtc).TotalSeconds -gt 5) {
            [System.Environment]::Exit(2)
        }
        return
    }

    try {
        if ($script:deviceDiscoveryStopAsync) {
            try { $script:deviceDiscoveryPowerShell.EndStop($script:deviceDiscoveryStopAsync) } catch { }
            $acceptResult = $false
        } elseif ($script:deviceDiscoveryStopReason) {
            $acceptResult = $false
        } elseif ($serialRecords -and $audio) {
            $serialCatalog = $serialRecords[0]
            if ($serialCatalog.serial_ports -isnot [array] -or $serialCatalog.hri_ports -isnot [array]) {
                throw '串口设备列表结构无效。'
            }
            $catalog = [pscustomobject]@{
                serial_ports = @($serialCatalog.serial_ports)
                hri_ports = @($serialCatalog.hri_ports)
                wave_inputs = @($audio.wave_inputs)
                wave_outputs = @($audio.wave_outputs)
            }
            if ($acceptResult) { $script:deviceCatalog = $catalog; $script:deviceDiscoveryState = 'ready' }
        } elseif ($script:deviceDiscoveryState -ne 'failed') {
            throw '设备查询没有返回完整的串口与音频列表。'
        }
    } catch {
        if ($acceptResult) {
            $script:deviceCatalog = $null
            $script:deviceDiscoveryState = 'failed'
            $script:deviceDiscoveryError = $_.Exception.Message
        }
    } finally {
        $finalStopReason = [string]$script:deviceDiscoveryStopReason
        if ($resultBelongsToWindow -and $finalStopReason -and $finalStopReason -cne 'window_closed') {
            $script:deviceCatalog = $null
            $script:deviceDiscoveryState = 'failed'
        }
        if ($script:deviceDiscoveryPowerShell) { $script:deviceDiscoveryPowerShell.Dispose() }
        $script:deviceDiscoveryPowerShell = $null
        $script:deviceDiscoveryAsync = $null
        $script:deviceDiscoveryStopAsync = $null
        $script:deviceDiscoveryOwnerWindow = $null
        $script:deviceDiscoveryStopReason = ''
    }
    if ($resultBelongsToWindow) { Set-SettingsDeviceControls }
    if ($resultBelongsToWindow -and $script:settingsWindow) { (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $true }
    if ($script:closingAfterDeviceDiscovery) {
        $script:closingAfterDeviceDiscovery = $false
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return
    }
    if ($script:deviceDiscoveryRestartPending -and $script:settingsWindow) {
        $script:deviceDiscoveryRestartPending = $false
        Start-UiDeviceDiscovery
    }
}

function Invalidate-UiDeviceDiscoveryForWindow {
    param([Parameter(Mandatory=$true)][object]$Window)
    if (-not [object]::ReferenceEquals($Window, $script:deviceDiscoveryOwnerWindow)) { return }
    $script:deviceDiscoveryGeneration++
    $script:deviceDiscoveryRestartPending = $false
    $script:deviceDiscoveryStopReason = 'window_closed'
    $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
    if ($script:deviceAudioQuery) {
        try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
        catch { $script:deviceDiscoveryError = $_.Exception.Message }
    }
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and
        -not $script:deviceDiscoveryAsync.IsCompleted -and -not $script:deviceDiscoveryStopAsync) {
        try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) }
        catch { $script:deviceDiscoveryError = '串口设备查询未能及时停止。' }
    }
}

function Read-CurrentPasswordPath {
    try { return Get-BridgePasswordFile -UserConfigDirectory $script:configDirectory }
    catch { return '' }
}

function Set-GainValueLabel {
    param([string]$SliderName, [string]$LabelName)
    $value = [double](Get-SettingsControl $SliderName).Value
    $milli = Convert-UiGainSliderToMilli -Value $value
    (Get-SettingsControl $LabelName).Text = ((Format-BridgeGain -GainMilli $milli) + 'x')
}

function Get-UiReceiveEditorState {
    param([object]$Profile)
    if ($null -eq $Profile) {
        return [pscustomobject]@{ CanEdit=$true; Destination=''; Slot='2'; Kind='group'; Reason='新配置' }
    }
    $policy = $Profile.rx_policy
    $firstGroup = @($policy.allow_groups | Select-Object -First 1)
    $firstLocal = @($policy.local_private_routes | Select-Object -First 1)
    $firstPeer = @($policy.allow_private_peers | Select-Object -First 1)
    $destination = if ($firstGroup.Count) { [string]$firstGroup[0].destination_id } elseif ($firstLocal.Count) { [string]$firstLocal[0].local_destination_id } elseif ($firstPeer.Count) { [string]$firstPeer[0].source_id } else { '' }
    $slot = if ($firstGroup.Count) { [string]$firstGroup[0].slot } elseif ($firstLocal.Count) { [string]$firstLocal[0].slot } elseif ($firstPeer.Count) { [string]$firstPeer[0].slot } else { '2' }
    $kind = if ($firstGroup.Count) { 'group' } elseif ($firstLocal.Count -or $firstPeer.Count) { 'private' } else { 'group' }
    return [pscustomobject]@{ CanEdit=$true; Destination=$destination; Slot=$slot; Kind=$kind; Reason='完整 schema 2 多路由策略可编辑。' }
}

function New-UiSimpleReceivePolicy {
    param([Parameter(Mandatory=$true)][object]$Connection, [Parameter(Mandatory=$true)][object]$TxTarget,
        [Parameter(Mandatory=$true)][string]$ReceiveDestination, [Parameter(Mandatory=$true)][uint64]$ReceiveSlot,
        [Parameter(Mandatory=$true)][string]$ReceiveKind, [Parameter(Mandatory=$true)][bool]$TransmitEnabled)
    if ($ReceiveKind -ceq 'group') {
        $policy = [pscustomobject][ordered]@{
            group_mode='selected'; private_mode='disabled'
            allow_groups=@([pscustomobject][ordered]@{ destination_id=[uint64]$ReceiveDestination; slot=$ReceiveSlot })
            allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
        }
    } else {
        if ([uint64]$ReceiveDestination -ne [uint64]$Connection.source_id) {
            throw '私呼接收目标必须等于本机 Source ID；请修正接收 ID。'
        }
        $policy = [pscustomobject][ordered]@{
            group_mode='selected'; private_mode='all_peers_to_local'; allow_groups=@(); allow_private_peers=@()
            local_private_routes=@([pscustomobject][ordered]@{ local_destination_id=[uint64]$Connection.source_id; slot=$ReceiveSlot })
            blocked_groups=@(); blocked_source_ids=@()
        }
    }
    if ($TransmitEnabled -and $TxTarget.kind -ceq 'private') {
        $covered = $ReceiveKind -ceq 'private' -and [uint64]$ReceiveSlot -eq [uint64]$TxTarget.slot
        if (-not $covered) {
            $policy.allow_private_peers = @([pscustomobject][ordered]@{
                source_id=[uint64]$TxTarget.destination_id; local_destination_id=[uint64]$Connection.source_id; slot=[uint64]$TxTarget.slot
            })
            if ($policy.private_mode -ceq 'disabled') { $policy.private_mode='selected_peers' }
        }
    }
    return $policy
}

function Get-UiProfileMigrationSourceSchema {
    param([object]$Profile)
    if ($null -eq $Profile) { return 0 }
    $migration = $Profile.PSObject.Properties['migration_source_schema_version']
    if ($null -ne $migration -and -not ($migration.Value -is [bool])) {
        $parsed = 0
        if ([int]::TryParse([string]$migration.Value, [ref]$parsed) -and $parsed -in @(1,2)) { return $parsed }
    }
    $schema = $Profile.PSObject.Properties['schema_version']
    if ($null -ne $schema -and -not ($schema.Value -is [bool]) -and [int]$schema.Value -eq 1) { return 1 }
    return 2
}

function Convert-UiGainSliderToMilli {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -lt 0.25 -or $Value -gt 16.0) {
        throw '音量增益必须在 0.25x 到 16x 之间。'
    }
    return [uint32][Math]::Round($Value * 1000.0, [MidpointRounding]::AwayFromZero)
}

function Copy-UiRxPolicy {
    param([object]$Policy)
    return [pscustomobject][ordered]@{
        group_mode=[string]$Policy.group_mode
        private_mode=[string]$Policy.private_mode
        allow_groups=[object[]]@($Policy.allow_groups | ForEach-Object { [pscustomobject][ordered]@{ destination_id=[uint64]$_.destination_id; slot=[uint64]$_.slot } })
        allow_private_peers=[object[]]@($Policy.allow_private_peers | ForEach-Object { [pscustomobject][ordered]@{ source_id=[uint64]$_.source_id; local_destination_id=[uint64]$_.local_destination_id; slot=[uint64]$_.slot } })
        local_private_routes=[object[]]@($Policy.local_private_routes | ForEach-Object { [pscustomobject][ordered]@{ local_destination_id=[uint64]$_.local_destination_id; slot=[uint64]$_.slot } })
        blocked_groups=[object[]]@($Policy.blocked_groups | ForEach-Object { [pscustomobject][ordered]@{ destination_id=[uint64]$_.destination_id; slot=[uint64]$_.slot } })
        blocked_source_ids=[uint64[]]@($Policy.blocked_source_ids | ForEach-Object { [uint64]$_ })
    }
}

function Get-UiComboTag {
    param([System.Windows.Controls.ComboBox]$Combo)
    if ($null -eq $Combo.SelectedItem -or $Combo.SelectedItem -isnot [System.Windows.Controls.ComboBoxItem]) { return '' }
    return [string]$Combo.SelectedItem.Tag
}

function Get-UiPolicyLocalSourceId {
    if ($script:activeRouting -and $script:supervisor -and -not $script:supervisor.HasExited) { return [uint64]$script:activeRouting.local_source_id }
    if ($script:storedProfile) { return [uint64]$script:storedProfile.connection.source_id }
    if ($script:settingsWindow) {
        $id = [uint64]0
        if ([uint64]::TryParse([string](Get-SettingsControl 'SourceBox').Text, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$id)) { return $id }
    }
    return [uint64]0
}

function Set-SettingsPolicyLists {
    if (-not $script:settingsWindow -or -not $script:editRxPolicy) { return }
    $wasLoading = $script:loadingSettings
    $script:loadingSettings = $true
    foreach ($name in @('GroupRoutesList','PeerRoutesList','LocalPrivateRoutesList','BlockedGroupsList','BlockedSourcesList')) {
        (Get-SettingsControl $name).Items.Clear()
    }
    foreach ($route in @($script:editRxPolicy.allow_groups)) { [void](Get-SettingsControl 'GroupRoutesList').Items.Add(('TG {0} · TS{1}' -f $route.destination_id,$route.slot)) }
    foreach ($route in @($script:editRxPolicy.allow_private_peers)) { [void](Get-SettingsControl 'PeerRoutesList').Items.Add(('peer {0} → 本机 {1} · TS{2}' -f $route.source_id,$route.local_destination_id,$route.slot)) }
    foreach ($route in @($script:editRxPolicy.local_private_routes)) { [void](Get-SettingsControl 'LocalPrivateRoutesList').Items.Add(('发往本机 {0} · TS{1}' -f $route.local_destination_id,$route.slot)) }
    foreach ($route in @($script:editRxPolicy.blocked_groups)) { [void](Get-SettingsControl 'BlockedGroupsList').Items.Add(('TG {0} · TS{1}' -f $route.destination_id,$route.slot)) }
    foreach ($sourceId in @($script:editRxPolicy.blocked_source_ids)) { [void](Get-SettingsControl 'BlockedSourcesList').Items.Add(('DMR ID {0}' -f $sourceId)) }
    $groupMode = Get-SettingsControl 'GroupModeBox'
    $privateMode = Get-SettingsControl 'PrivateModeBox'
    $groupMode.SelectedItem = @($groupMode.Items | Where-Object { [string]$_.Tag -ceq [string]$script:editRxPolicy.group_mode })[0]
    $privateMode.SelectedItem = @($privateMode.Items | Where-Object { [string]$_.Tag -ceq [string]$script:editRxPolicy.private_mode })[0]
    (Get-SettingsControl 'ReceivePolicyPreviewText').Text = Format-ProfileReceiveTarget -Profile ([pscustomobject]@{ rx_policy=$script:editRxPolicy })
    $script:loadingSettings = $wasLoading
}

function Set-RoutingMutationControls {
    param([bool]$Enabled)
    if ($script:settingsWindow) {
      foreach ($name in @('GroupModeBox','PrivateModeBox','GroupRouteIdBox','GroupRouteSlotBox','BlockedGroupIdBox','BlockedGroupSlotBox',
            'PeerSourceIdBox','PeerLocalDestinationBox','PeerSlotBox','LocalPrivateDestinationBox','LocalPrivateSlotBox','BlockedSourceIdBox',
            'DestinationBox','SlotBox','CallKindBox','TransmitEnabledBox','GroupRoutesList','PeerRoutesList','LocalPrivateRoutesList',
            'BlockedGroupsList','BlockedSourcesList','SaveSettingsButton','AddGroupRouteButton','RemoveGroupRouteButton',
            'AddBlockedGroupButton','RemoveBlockedGroupButton','AddPeerRouteButton','RemovePeerRouteButton',
            'AddLocalPrivateRouteButton','RemoveLocalPrivateRouteButton','AddBlockedSourceButton','RemoveBlockedSourceButton',
            'ApplyNextTxTargetButton')) {
        $control = $script:settingsWindow.FindName($name)
        if ($null -ne $control) { $control.IsEnabled = $Enabled }
      }
      Update-TxTargetButtonState
    }
    if ($script:mainWindow) {
        $callTargetButtonEnabled = $Enabled -and -not $script:pendingRoutingMutation -and -not $script:routingMutationFence
        $targetSelector = $script:mainWindow.FindName('TargetSelector')
        if ($targetSelector) { $targetSelector.IsEnabled = $callTargetButtonEnabled }
        $choicePanel = $script:mainWindow.FindName('CallTargetChoicesPanel')
        if ($choicePanel) {
            foreach ($choiceButton in $choicePanel.Children) {
                if ($choiceButton -is [System.Windows.Controls.Button]) { $choiceButton.IsEnabled = $callTargetButtonEnabled }
            }
        }
        $panel = $script:mainWindow.FindName('ObservedSourcesPanel')
        foreach ($card in $panel.Children) {
            if ($card -isnot [System.Windows.Controls.Border] -or $card.Child -isnot [System.Windows.Controls.StackPanel]) { continue }
            foreach ($bodyChild in $card.Child.Children) {
                if ($bodyChild -isnot [System.Windows.Controls.Primitives.UniformGrid]) { continue }
                foreach ($button in $bodyChild.Children) {
                    if ($button -is [System.Windows.Controls.Button]) { $button.IsEnabled = $Enabled }
                }
            }
        }
        $callButton = $script:mainWindow.FindName('BlockCurrentSourceButton')
        if ($callButton) { $callButton.IsEnabled = ($Enabled -and $script:activeRouting -and $script:latestStatus -and $script:latestStatus.current_call_valid) }
        Update-UiCallHistoryActionState
        Update-UiChannelFavoriteControls
        Update-DynamicGroupControls
    }
}

function Update-TxTargetButtonState {
    if (-not $script:settingsWindow) { return }
    $button = $script:settingsWindow.FindName('ApplyNextTxTargetButton')
    $destination = [uint64]0
    $validId = [uint64]::TryParse([string](Get-SettingsControl 'DestinationBox').Text,[Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,[ref]$destination)
    $isForbidden = $validId -and (Get-UiComboTag -Combo (Get-SettingsControl 'CallKindBox')) -ceq 'group' -and $destination -in @(91,46001)
    $liveReady = (-not ($script:supervisor -and -not $script:supervisor.HasExited)) -or ($script:controlConfirmed -and $script:routingCapabilities -and $script:activeRouting)
    $button.IsEnabled = (-not $script:pendingRoutingMutation -and $liveReady -and -not $isForbidden)
}

function Set-DynamicGroupStatus {
    param([string]$Text, [bool]$Failed=$false)
    if (-not $script:mainWindow) { return }
    $label = Get-UiControl 'DynamicGroupStatus'
    $compactText = ([string]$Text).Trim()
    $sentenceEnd = $compactText.IndexOf('。')
    if (-not $Failed -and $sentenceEnd -gt 0) { $compactText = $compactText.Substring(0,$sentenceEnd) }
    if ($compactText.Length -gt 72) { $compactText = $compactText.Substring(0,69) + '…' }
    $label.Text = $compactText
    $label.Visibility = if ($compactText) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $label.Foreground = if ($Failed) { [Windows.Media.Brushes]::IndianRed } else { [Windows.Media.Brushes]::LightGreen }
}

function Read-DynamicGroupInput {
    $id = [uint64]0
    $idText = [string](Get-UiControl 'DynamicGroupIdBox').Text
    $slotText = Get-UiComboTag -Combo (Get-UiControl 'DynamicGroupSlotBox')
    $slot = [uint64]0
    if (-not [uint64]::TryParse($idText,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$id) -or
        $id -lt 1 -or $id -gt 16777215 -or
        -not [uint64]::TryParse([string]$slotText,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$slot) -or
        $slot -lt 1 -or $slot -gt 2) { throw '组呼 TG 需为 1 到 16777215 的整数，并选择 TS1 或 TS2。' }
    return [pscustomobject][ordered]@{ destination_id=$id; slot=$slot }
}

function Update-DynamicGroupControls {
    if (-not $script:mainWindow) { return }
    $listenButton = Get-UiControl 'AddListenGroupButton'
    $targetButton = Get-UiControl 'SetDynamicCallTargetButton'
    $activateButton = Get-UiControl 'ActivateDynamicGroupButton'
    $groupIdValid = $false
    $groupId = [uint64]0
    $groupIdValid = [uint64]::TryParse([string](Get-UiControl 'DynamicGroupIdBox').Text,
        [Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$groupId) -and
        $groupId -ge 1 -and $groupId -le 16777215
    $runtimeReady = ($script:supervisor -and -not $script:supervisor.HasExited -and
        $script:controlConfirmed -and $script:routingCapabilities -and $script:activeRouting)
    $statusFresh = ($script:latestStatus -and $script:lastStatusUtc -ne [DateTime]::MinValue -and
        ([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3)
    $bmReady = ($statusFresh -and [string]$script:latestStatus.bm_state -ceq 'ready')
    $offlineDiagnosticActionReady = ($RoutingDiagnosticAutoTest -and
        $script:activeTargetTag -ceq 'routing-diagnostic' -and $script:controlDiagnostic -and
        $script:routingDiagnosticAutoTestStarted -and $script:routingDiagnosticAutoTestPhase -ge 6 -and
        $script:routingDiagnosticAutoTestPhase -le 8)
    $actionReady = ($bmReady -or $offlineDiagnosticActionReady)
    $notPending = (-not $script:pendingRoutingMutation -and -not $script:routingMutationFence -and -not $script:pendingQuickCall)
    $callTargetReady = if ($script:supervisor -and -not $script:supervisor.HasExited) {
        [bool]$runtimeReady
    } else { -not $script:preparationStarted }
    $callTargetAllowed = ($groupIdValid -and $groupId -notin @(91,46001))
    $targetButton.IsEnabled = ($callTargetReady -and $callTargetAllowed -and $notPending)
    $listenButton.IsEnabled = ($runtimeReady -and $actionReady -and $groupIdValid -and $notPending)
    $mediaIdle = ($script:activeRouting -and [string]$script:activeRouting.media_owner -ceq 'idle')
    $activateButton.IsEnabled = ($runtimeReady -and $script:quickCallCapabilities -and $actionReady -and
        $groupIdValid -and $groupId -ne 4000 -and $mediaIdle -and $notPending)
    Update-UiChannelFavoriteControls
}

function Invoke-UiDynamicGroupLocalListen {
    try {
        Update-DynamicGroupControls
        $button = Get-UiControl 'AddListenGroupButton'
        $route = Read-DynamicGroupInput
        if (-not $button.IsEnabled) { throw '当前无法加入本机收听' }
        $policy = Copy-UiRxPolicy -Policy $script:activeRouting.rx_policy
        $policy.blocked_groups = @($policy.blocked_groups | Where-Object {
            -not ([uint64]$_.destination_id -eq [uint64]$route.destination_id -and [uint64]$_.slot -eq [uint64]$route.slot)
        })
        if (@($policy.allow_groups | Where-Object {
            [uint64]$_.destination_id -eq [uint64]$route.destination_id -and [uint64]$_.slot -eq [uint64]$route.slot
        }).Count -eq 0) {
            $policy.allow_groups += [pscustomobject][ordered]@{ destination_id=$route.destination_id; slot=$route.slot }
        }
        $script:pendingDynamicLocalListen = $route
        Set-DynamicGroupStatus ('正在把 TG {0} · TS{1} 加入本机收听。' -f $route.destination_id,$route.slot)
        Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $policy
    } catch {
        $script:pendingDynamicLocalListen = $null
        Set-DynamicGroupStatus $_.Exception.Message -Failed $true
    }
}

function Invoke-UiDynamicGroupQuickCall {
    try {
        Update-DynamicGroupControls
        $button = Get-UiControl 'ActivateDynamicGroupButton'
        $route = Read-DynamicGroupInput
        if ([uint64]$route.destination_id -eq 4000) { throw 'TG4000 是断开动态组的控制命令，不能作为激活目标。' }
        if (-not $button.IsEnabled) { throw '当前无法激活动态组' }
        $parameters = [ordered]@{ group=$route }
        $parametersJson = ConvertTo-Json -InputObject $parameters -Depth 4 -Compress
        $requestId = [guid]::NewGuid().ToString('D')
        $script:pendingQuickCall = [pscustomobject]@{
            request_id=$requestId; destination_id=[uint64]$route.destination_id; slot=[uint64]$route.slot
            started_utc=[DateTime]::UtcNow; timed_out=$false
        }
        $script:pendingControlRequests[$requestId] = 'network_subscription.quick_call_join'
        Set-DynamicGroupStatus ('正在发送 TG {0} · TS{1} 动态组激活请求。' -f $route.destination_id,$route.slot)
        Update-DynamicGroupControls
        if (-not $script:supervisor.SendControlCommand($requestId,'network_subscription.quick_call_join',$parametersJson)) {
            [void]$script:pendingControlRequests.Remove($requestId)
            $script:pendingQuickCall = $null
            Set-DynamicGroupStatus '激活请求未送达核心，请检查连接后重新激活。' -Failed $true
            Add-UiEvent '激活请求未送达核心；没有自动重试'
            Update-DynamicGroupControls
            return
        }
    } catch {
        Set-DynamicGroupStatus $_.Exception.Message -Failed $true
        Update-DynamicGroupControls
    }
}

function Set-RoutingEditorStatus {
    param([string]$Text, [bool]$Failed=$false)
    if ($script:settingsWindow) {
        $label = Get-SettingsControl 'RoutingEditorStatus'
        $compactText = ([string]$Text).Trim()
        $sentenceEnd = $compactText.IndexOf('。')
        if (-not $Failed -and $sentenceEnd -gt 0) { $compactText = $compactText.Substring(0,$sentenceEnd) }
        if ($compactText.Length -gt 100) { $compactText = $compactText.Substring(0,97) + '…' }
        $label.Text = $compactText
        $label.Visibility = if ($compactText) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $label.Foreground = if ($Failed) { [Windows.Media.Brushes]::IndianRed } else { [Windows.Media.Brushes]::LightGreen }
    }
}

function Format-UiRouteTarget {
    param([object]$Target)
    if ($null -eq $Target) { return '无' }
    if ([string]$Target.kind -ceq 'private') { return ('私呼 {0} · TS{1}' -f $Target.destination_id,$Target.slot) }
    return ('TG {0} · TS{1}' -f $Target.destination_id,$Target.slot)
}

function Set-ActiveRoutingSnapshot {
    param([object]$Routing, [switch]$Force, [switch]$SyncAllEditor, [switch]$SyncRxEditor, [switch]$SyncTxEditor)
    if (-not (Test-UiRoutingSnapshot -Routing $Routing)) { throw '核心返回的路由设置格式无效。' }
    if ($script:storedProfile -and [uint64]$Routing.local_source_id -ne [uint64]$script:storedProfile.connection.source_id) {
        throw '核心返回的本机 ID 与已保存配置不一致。'
    }
    if (-not $Force -and $script:activeRouting -and
        ([uint64]$Routing.rx_policy_revision -lt [uint64]$script:activeRouting.rx_policy_revision -or
         [uint64]$Routing.tx_policy_revision -lt [uint64]$script:activeRouting.tx_policy_revision)) {
        Add-UiEvent '已忽略会回退策略版本的路由快照'
        return $false
    }
    $script:activeRouting = $Routing
    $script:routingLastUpdateUtc = [DateTime]::UtcNow
    Update-RoutingDisplays
    if ($script:settingsWindow -and -not $script:pendingRoutingMutation -and -not $script:loadingSettings) {
        if ($SyncAllEditor -or $SyncRxEditor) { $script:editRxPolicy = Copy-UiRxPolicy -Policy $Routing.rx_policy; Set-SettingsPolicyLists }
        $syncTxEditorNow = ($SyncTxEditor -or ($SyncAllEditor -and -not $script:txEditorDirty))
        if ($syncTxEditorNow) {
            $wasLoading = $script:loadingSettings
            $script:loadingSettings = $true
            $target = $Routing.tx_target
            (Get-SettingsControl 'DestinationBox').Text = [string]$target.destination_id
            $slotBox = Get-SettingsControl 'SlotBox'
            $slotBox.SelectedItem = @($slotBox.Items | Where-Object { [string]$_.Tag -ceq [string]$target.slot })[0]
            $kindBox = Get-SettingsControl 'CallKindBox'
            $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq [string]$target.kind })[0]
            (Get-SettingsControl 'TransmitEnabledBox').IsChecked = [bool]$Routing.transmit_enabled
            $script:loadingSettings = $wasLoading
            $script:txEditorDirty = $false
        }
    }
    return $true
}

function New-UiSmallTextBlock {
    param([string]$Text, [double]$FontSize=11)
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $FontSize
    $block.TextWrapping = [Windows.TextWrapping]::Wrap
    $block.Margin = [Windows.Thickness]::new(2.0,2.0,2.0,2.0)
    return $block
}

function New-UiActionButton {
    param([string]$Text, [object]$Data)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.Tag = $Data
    $button.Padding = [Windows.Thickness]::new(4.0,2.0,4.0,2.0)
    $button.Margin = [Windows.Thickness]::new(2.0)
    $button.FontSize = 10
    $button.Add_Click({ param($sender,$eventArgs) Invoke-ObservedRoutingAction -Action ([string]$sender.Tag.Action) -Source $sender.Tag.Source })
    return $button
}

function Update-RoutingDisplays {
    if (-not $script:mainWindow) { return }
    $routing = $script:activeRouting
    if ($routing) {
        $profileView = [pscustomobject]@{ rx_policy=$routing.rx_policy; tx_target=$routing.tx_target; transmit_enabled=$routing.transmit_enabled }
        Set-MainTargetSummary -Profile $profileView -OverallLabel (Format-ProfileTarget -Profile $profileView)
        $ownerText = switch -CaseSensitive ([string]$routing.media_owner) {
            'idle' { '空闲' } 'rx_active' { '正在接收' } 'rx_draining' { '接收尾音处理中' }
            'rx_stopping' { '正在停止接收' } 'tx_active' { '正在发射' } 'tx_draining' { '发射收尾处理中' }
            default { '媒体状态需要检查' }
        }
        Set-MainText -Name 'RoutingRevisionValue' -Text ('本机媒体状态：' + $ownerText)
        $leaseText = if ($routing.active_tx_lease) { '活动通话目标：{0}' -f (Format-UiRouteTarget $routing.active_tx_lease) } else { '' }
        Set-MainText -Name 'ActiveLeaseValue' -Text $leaseText
    } else {
        $profileView = if ($script:activeProfile) { $script:activeProfile } elseif ($script:storedProfile) { $script:storedProfile } else { $null }
        if ($profileView) {
            Set-MainTargetSummary -Profile $profileView -OverallLabel (Format-ProfileTarget -Profile $profileView)
            $leaseText = '活动通话锁定目标：等待本次连接状态'
        } else { $leaseText = '活动通话锁定目标：无' }
        Set-MainText -Name 'ActiveLeaseValue' -Text $leaseText
        Set-MainText -Name 'RoutingRevisionValue' -Text '本机媒体状态：等待本次连接'
    }
    $configured = $script:mainWindow.FindName('ConfiguredRoutesPanel')
    $configured.Children.Clear()
    $policy = if ($routing) { $routing.rx_policy } elseif ($script:activeProfile) { $script:activeProfile.rx_policy } elseif ($script:storedProfile) { $script:storedProfile.rx_policy } else { $null }
    if ($policy) {
        $groupListLabel = if ($policy.group_mode -ceq 'selected') { 'Selected · TG' } else { 'AllDelivered 附带列表 · TG' }
        foreach ($route in @($policy.allow_groups)) { [void]$configured.Children.Add((New-UiSmallTextBlock -Text ('{0} {1} · TS{2}' -f $groupListLabel,$route.destination_id,$route.slot))) }
        foreach ($route in @($policy.local_private_routes)) { [void]$configured.Children.Add((New-UiSmallTextBlock -Text ('本机私呼路由 · {0} · TS{1}' -f $route.local_destination_id,$route.slot))) }
        foreach ($route in @($policy.allow_private_peers)) { [void]$configured.Children.Add((New-UiSmallTextBlock -Text ('私呼 peer {0} → {1} · TS{2}' -f $route.source_id,$route.local_destination_id,$route.slot))) }
        foreach ($route in @($policy.blocked_groups)) { [void]$configured.Children.Add((New-UiSmallTextBlock -Text ('本地屏蔽 · TG {0} · TS{1}' -f $route.destination_id,$route.slot))) }
        foreach ($sourceId in @($policy.blocked_source_ids)) { [void]$configured.Children.Add((New-UiSmallTextBlock -Text ('跨组屏蔽 · DMR ID {0}' -f $sourceId))) }
        if (-not $policy.allow_groups.Count -and -not $policy.local_private_routes.Count -and -not $policy.allow_private_peers.Count) {
            [void]$configured.Children.Add((New-UiSmallTextBlock -Text ('{0} · 暂无显式路由' -f $policy.group_mode)))
        }
    } else { [void]$configured.Children.Add((New-UiSmallTextBlock -Text '读取本地配置后显示。')) }
    $observedPanel = $script:mainWindow.FindName('ObservedSourcesPanel')
    $observedPanel.Children.Clear()
    $observedSources = if ($routing -and $routing.PSObject.Properties['observed_sources']) { @($routing.observed_sources) } else { @() }
    if ($observedSources.Count -gt 0) {
        foreach ($source in @($routing.observed_sources)) {
            $card = New-Object System.Windows.Controls.Border
            $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#20252A')
            $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#3A4248')
            $card.BorderThickness = [Windows.Thickness]::new(1.0)
            $card.Padding = [Windows.Thickness]::new(5.0)
            $card.Margin = [Windows.Thickness]::new(0.0,0.0,0.0,4.0)
            $body = New-Object System.Windows.Controls.StackPanel
            $sourceId = [uint64]$source.source_id
            $sourceLabel = 'DMR ID ' + $sourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
            $cacheKey = $sourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
            if ($script:callIdentityCache.ContainsKey($cacheKey)) {
                $cachedIdentity = $script:callIdentityCache[$cacheKey]
                if ($cachedIdentity -and [string]$cachedIdentity.status -cin @('found','stale')) {
                    $cachedCallsign = ([string]$cachedIdentity.callsign).Trim()
                    if (-not $cachedCallsign) { $cachedCallsign = ([string]$cachedIdentity.display_name).Trim() }
                    if ($cachedCallsign -and $cachedCallsign -cne $sourceLabel) { $sourceLabel = $cachedCallsign + ' · ' + $sourceLabel }
                }
            }
            $callKind = switch -CaseSensitive ([string]$source.kind) { 'private' { '私呼' } 'group' { '组呼' } default { '' } }
            $sourcePrefix = if ($callKind) { $callKind + ' · ' } else { '' }
            [void]$body.Children.Add((New-UiSmallTextBlock -Text ($sourcePrefix + $sourceLabel)))
            $targetText = if ([string]$source.kind -ceq 'group') {
                'TG {0} · TS{1}' -f $source.destination_id,$source.slot
            } elseif ([string]$source.kind -ceq 'private') {
                '目标 DMR ID {0} · TS{1}' -f $source.destination_id,$source.slot
            } else {
                '目标 {0} · TS{1}' -f $source.destination_id,$source.slot
            }
            [void]$body.Children.Add((New-UiSmallTextBlock -Text $targetText -FontSize 10))
            $actions = New-Object System.Windows.Controls.Primitives.UniformGrid
            $routeState = Get-UiObservedCardActionState -Source $source -Policy $routing.rx_policy
            if ($routeState.local_action_enabled) {
                [void]$actions.Children.Add((New-UiActionButton -Text $routeState.local_text -Data ([pscustomobject]@{ Action='toggle'; Source=$source })))
            }
            $blockText = if ($routeState.source_blocked) { '恢复来源' } else { '屏蔽此来源' }
            [void]$actions.Children.Add((New-UiActionButton -Text $blockText -Data ([pscustomobject]@{ Action='block'; Source=$source })))
            $txDisabled = ($source.kind -ceq 'group' -and [uint64]$source.destination_id -in @(91,46001))
            if (-not $txDisabled) {
                [void]$actions.Children.Add((New-UiActionButton -Text '设为呼叫目标' -Data ([pscustomobject]@{ Action='tx'; Source=$source })))
            }
            $actions.Columns = [Math]::Max(1,$actions.Children.Count)
            [void]$body.Children.Add($actions)
            $card.Child = $body
            [void]$observedPanel.Children.Add($card)
        }
    }
    $observedExpander = $script:mainWindow.FindName('RadioDetailsExpander')
    if ($observedExpander) {
        $observedExpander.Visibility = if ($observedSources.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    $currentCall = $script:latestStatus
    $blockButton = $script:mainWindow.FindName('BlockCurrentSourceButton')
    $blockButton.IsEnabled = ($currentCall -and $currentCall.PSObject.Properties['current_call_valid'] -and [bool]$currentCall.current_call_valid -and $routing)
    Update-UiCallHistoryActionState
    if ($script:settingsWindow) {
        Update-TxTargetButtonState
        if ($script:pendingRoutingMutation) { Set-RoutingMutationControls -Enabled $false }
    }
    Update-CallTargetChoices
    Update-DynamicGroupControls
    Update-UiChannelFavoriteControls
}

function Get-UiObservedRouteAllowed {
    param([object]$Source,[object]$Policy)
    if ($Source.kind -ceq 'group') {
        $blocked = @($Policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot }).Count -gt 0
        if ($blocked) { return $false }
        if ($Policy.group_mode -ceq 'all_delivered') { return $true }
        return (@($Policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot }).Count -gt 0)
    }
    if ($Policy.private_mode -ceq 'disabled') { return $false }
    if ($Policy.private_mode -ceq 'all_peers_to_local' -and @($Policy.local_private_routes | Where-Object { [uint64]$_.local_destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot }).Count -gt 0) { return $true }
    return (@($Policy.allow_private_peers | Where-Object { [uint64]$_.source_id -eq [uint64]$Source.source_id -and [uint64]$_.local_destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot }).Count -gt 0)
}

function Test-UiLocalPrivateRouteCoversSource {
    param([object]$Source,[object]$Policy)
    if ($Source.kind -cne 'private' -or $Policy.private_mode -cne 'all_peers_to_local') { return $false }
    return (@($Policy.local_private_routes | Where-Object {
        [uint64]$_.local_destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot
    }).Count -gt 0)
}

function Get-UiObservedCardActionState {
    param([object]$Source,[object]$Policy)
    $routeAllowed = Get-UiObservedRouteAllowed -Source $Source -Policy $Policy
    $sourceBlocked = @($Policy.blocked_source_ids | Where-Object { [uint64]$_ -eq [uint64]$Source.source_id }).Count -gt 0
    $localCovered = Test-UiLocalPrivateRouteCoversSource -Source $Source -Policy $Policy
    $tooltip = if ($localCovered) { '本机已接收此时隙的所有私呼；如需只屏蔽该联系人，请使用“屏蔽此来源”，或在设置中改为精确联系人列表。' } else { '只修改这一频道或这一私呼联系人，不修改发话来源屏蔽。' }
    return [pscustomobject]@{
        local_text=if ($localCovered) { '整时隙私呼已接收' } elseif ($routeAllowed) { '停止本地收听' } else { '恢复本地收听' }
        local_action_enabled=(-not $localCovered)
        local_tooltip=$tooltip
        source_blocked=$sourceBlocked
        source_action_text=if ($sourceBlocked) { '恢复来源' } else { '屏蔽此来源' }
    }
}

function Request-UiRoutingStatus {
    if (-not $script:supervisor -or $script:supervisor.HasExited -or -not $script:controlConfirmed -or -not $script:routingCapabilities) { return }
    if ($script:pendingRoutingStatusRequestId) { return }
    $requestId = [guid]::NewGuid().ToString('D')
    $script:pendingControlRequests[$requestId] = 'routing.status'
    $script:pendingRoutingStatusRequestId = $requestId
    if (-not $script:supervisor.SendControlCommand($requestId,'routing.status')) {
        [void]$script:pendingControlRequests.Remove($requestId)
        $script:pendingRoutingStatusRequestId = ''
        Set-UiControlStatus -Text '当前运行设置无法刷新；路由修改已锁定，请重新连接后再试。' -Confirmed $false
        if ($script:routingMutationFence) { Set-RoutingEditorStatus -Text '当前设置未能刷新；为避免覆盖运行状态，路由修改已锁定。请重新连接。' -Failed $true }
    }
}

function Set-RoutingMutationPendingState {
    param([bool]$Pending)
    $locked = ($Pending -or $script:routingMutationFence)
    if ($script:settingsWindow) { Set-RoutingMutationControls -Enabled (-not $locked) }
    if ($script:mainWindow) {
        $settings = Get-UiControl 'SettingsButton'
        $settings.IsEnabled = (-not $script:preparationStarted -and -not $locked)
    }
    Update-DynamicGroupControls
}

function Invoke-UiRoutingMutation {
    param([ValidateSet('rx_policy.replace','tx_policy.replace')][string]$Command,
        [Parameter(Mandatory=$true)][object]$PolicyOrTarget, [bool]$TransmitEnabled=$false)
    if ($script:pendingRoutingMutation) { throw '正在等待应用接收上一项设置；请等它完成或超时后再操作。' }
    if ($script:routingMutationFence) { throw '正在刷新当前运行设置；刷新完成前不能再提交路由更改。' }
    if ($Command -ceq 'rx_policy.replace') {
        $localSource = Get-UiPolicyLocalSourceId
        if ($localSource -eq 0 -or -not (Test-UiRxPolicy -Policy $PolicyOrTarget -LocalSourceId $localSource)) {
            throw 'RX 策略字段、时隙、重复项或本机目的 ID 无效。'
        }
        $script:editRxPolicy = Copy-UiRxPolicy -Policy $PolicyOrTarget
        $script:routingDraftAfterTimeout = [pscustomobject]@{ command=$Command; policy=(Copy-UiRxPolicy -Policy $PolicyOrTarget); target=$null; transmit_enabled=$null }
        $script:routingDraftPreservedAfterTimeout = $true
        if ($script:settingsWindow) { Set-SettingsPolicyLists }
        $payload = [ordered]@{ expected_revision=[uint64]$(if ($script:activeRouting) { $script:activeRouting.rx_policy_revision } else { 0 }); rx_policy=(Copy-UiRxPolicy -Policy $PolicyOrTarget) }
    } else {
        if (-not (Test-UiControlUnsigned -Value $PolicyOrTarget.destination_id -Minimum 1 -Maximum 16777215) -or
            [string]$PolicyOrTarget.kind -cnotin @('group','private') -or
            -not (Test-UiControlUnsigned -Value $PolicyOrTarget.slot -Minimum 1 -Maximum 2)) { throw '下一发射目标 ID、类型或时隙无效。' }
        if ([string]$PolicyOrTarget.kind -ceq 'group' -and [uint64]$PolicyOrTarget.destination_id -in @(91,46001)) {
            throw 'TG91 和 TG46001 只收，不能作为下一发射目标。'
        }
        if ($TransmitEnabled -and [string]$PolicyOrTarget.kind -ceq 'group' -and [uint64]$PolicyOrTarget.destination_id -in @(91,46001)) {
            throw '发射许可不能对 TG91 或 TG46001 开启。'
        }
        $target = [pscustomobject][ordered]@{ destination_id=[uint64]$PolicyOrTarget.destination_id; kind=[string]$PolicyOrTarget.kind; slot=[uint64]$PolicyOrTarget.slot }
        $script:editTxTarget = $target
        $script:editTransmitEnabled = [bool]$TransmitEnabled
        $script:routingDraftAfterTimeout = [pscustomobject]@{ command=$Command; policy=$null; target=$target; transmit_enabled=[bool]$TransmitEnabled }
        $script:routingDraftPreservedAfterTimeout = $true
        $payload = [ordered]@{ expected_revision=[uint64]$(if ($script:activeRouting) { $script:activeRouting.tx_policy_revision } else { 0 }); tx_target=$target; transmit_enabled=[bool]$TransmitEnabled }
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        if (-not $script:controlConfirmed -or -not $script:routingCapabilities -or -not $script:activeRouting) {
            throw '当前连接尚未准备好接收路由设置；请稍后再试。'
        }
        $expectedRevision = [uint64]$payload.expected_revision
        $parametersJson = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
        $requestId = [guid]::NewGuid().ToString('D')
        $mutation = [pscustomobject]@{
            request_id=$requestId; command=$Command; expected_revision=$expectedRevision
            policy=if ($Command -ceq 'rx_policy.replace') { Copy-UiRxPolicy -Policy $PolicyOrTarget } else { $null }
            target=if ($Command -ceq 'tx_policy.replace') { $payload.tx_target } else { $null }
            transmit_enabled=if ($Command -ceq 'tx_policy.replace') { [bool]$TransmitEnabled } else { $null }
            started_utc=[DateTime]::UtcNow
        }
        $script:pendingRoutingMutation = $mutation
        $script:pendingControlRequests[$requestId] = $Command
        Set-RoutingMutationPendingState -Pending $true
        Write-UiRoutingDiagnosticProgress -Message ('mutation-send-' + $Command + '-bytes-' + [WirexBridge.Ui.BridgeSupervisor]::GetControlRequestBodyByteCount($script:controlRunId,$requestId,$Command,$parametersJson))
        Set-RoutingEditorStatus -Text ('等待应用接收{0}；状态卡仍显示本次连接最近确认的实际设置。' -f $(if ($Command -ceq 'rx_policy.replace') { '接收策略' } else { '下一发射目标' }))
        Set-UiControlStatus -Text '等待应用接收设置' -Confirmed $true
        if (-not $script:supervisor.SendControlCommand($requestId,$Command,$parametersJson)) {
            Write-UiRoutingDiagnosticProgress -Message ('mutation-send-failed-' + $Command)
            [void]$script:pendingControlRequests.Remove($requestId)
            $script:pendingRoutingMutation = $null
            Set-RoutingMutationPendingState -Pending $false
            $bodyBytes = [WirexBridge.Ui.BridgeSupervisor]::GetControlRequestBodyByteCount($script:controlRunId,$requestId,$Command,$parametersJson)
            if ($bodyBytes -gt 4096) {
                throw '路由列表太长，本次设置未发送；草稿已保留，请减少项目后再试。'
            }
            throw '命令发送失败，请检查连接状态。'
        }
        return
    }
    if ($Command -ceq 'rx_policy.replace') {
        $script:editRxPolicy = Copy-UiRxPolicy -Policy $PolicyOrTarget
        Set-SettingsPolicyLists
        Update-RoutingDisplays
        Set-RoutingEditorStatus -Text '本机策略已修改；点击“保存设置”后，下次启动会使用它。'
    } else {
        $script:editTxTarget = [pscustomobject][ordered]@{ destination_id=[uint64]$PolicyOrTarget.destination_id; kind=[string]$PolicyOrTarget.kind; slot=[uint64]$PolicyOrTarget.slot }
        $script:editTransmitEnabled = [bool]$TransmitEnabled
        Update-RoutingDisplays
        Set-RoutingEditorStatus -Text '下一发射目标草稿已修改；点击“保存设置”后，下次启动会使用它。'
    }
}

function Save-UiRoutingMutationAfterAck {
    param([object]$Mutation, [object]$Routing)
    if (-not $Mutation -or -not $script:profilePath) { return }
    $script:routingDraftAfterTimeout = $null
    $script:routingDraftPreservedAfterTimeout = $false
    try {
        $profile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if (-not $profile) { throw '本机连接配置文件不存在。' }
        if ($Mutation.command -ceq 'rx_policy.replace') {
            $profile.rx_policy = Copy-UiRxPolicy -Policy $Routing.rx_policy
        } else {
            $profile.tx_target = [pscustomobject][ordered]@{ destination_id=[uint64]$Routing.tx_target.destination_id; kind=[string]$Routing.tx_target.kind; slot=[uint64]$Routing.tx_target.slot }
            $profile.transmit_enabled = [bool]$Routing.transmit_enabled
        }
        Write-BridgeUserConnectionProfile -Path $script:profilePath -Profile $profile
        $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if ($script:activeProfile) {
            if ($Mutation.command -ceq 'rx_policy.replace') { $script:activeProfile.rx_policy = Copy-UiRxPolicy -Policy $Routing.rx_policy }
            else { $script:activeProfile.tx_target = $script:storedProfile.tx_target; $script:activeProfile.transmit_enabled = [bool]$Routing.transmit_enabled }
        }
        if ($Mutation.command -ceq 'rx_policy.replace') {
            $script:editRxPolicy = Copy-UiRxPolicy -Policy $Routing.rx_policy
        } else {
            $script:editTxTarget = $script:storedProfile.tx_target
            $script:editTransmitEnabled = [bool]$Routing.transmit_enabled
        }
        Set-RoutingEditorStatus -Text '设置已在当前运行生效，并已保存到本机配置。'
        Add-UiEvent '设置已生效并保存到本机配置'
    } catch {
        # The runtime ACK remains authoritative even when disk persistence fails.
        if ($Mutation.command -ceq 'rx_policy.replace') { $script:editRxPolicy = Copy-UiRxPolicy -Policy $Routing.rx_policy }
        else { $script:editTxTarget = $Routing.tx_target; $script:editTransmitEnabled = [bool]$Routing.transmit_enabled }
        $message = '已在当前运行生效，但本机保存失败；停止后重启会沿用磁盘上的旧值。' + $_.Exception.Message
        Set-RoutingEditorStatus -Text $message -Failed $true
        Set-MainText -Name 'TrafficDetail' -Text $message
        Add-UiEvent '运行时路由已生效，但本机配置保存失败'
    }
    if ($script:settingsWindow) { Set-SettingsPolicyLists }
    Update-RoutingDisplays
    if ($Mutation.command -ceq 'tx_policy.replace') {
        $script:pendingCallTarget = $null
        $targetText = Format-UiTxTarget -Target $Routing.tx_target
        $activeText = if ($Routing.active_tx_lease) { '活动通话锁定目标仍为 ' + (Format-UiRouteTarget $Routing.active_tx_lease) } else { '当前没有已锁定的活动通话' }
        Set-MainText -Name 'CallTargetStatusValue' -Text ('已确认起呼目标：' + $targetText)
    }
}

function Invoke-ObservedRoutingAction {
    param([string]$Action,[object]$Source)
    if (-not $Source) { return }
    if ($script:pendingRoutingMutation) { Set-RoutingEditorStatus -Text '正在等待应用接收上一项设置。' -Failed $true; return }
    $policy = if ($script:activeRouting) { Copy-UiRxPolicy -Policy $script:activeRouting.rx_policy } elseif ($script:editRxPolicy) { Copy-UiRxPolicy -Policy $script:editRxPolicy } else { return }
    switch -CaseSensitive ($Action) {
        'toggle' {
            if ($Source.kind -ceq 'group') {
                $isAllowed = Get-UiObservedRouteAllowed -Source $Source -Policy $policy
                if ($isAllowed) {
                    $policy.allow_groups = @($policy.allow_groups | Where-Object { -not ([uint64]$_.destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot) })
                    if (@($policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot }).Count -eq 0) {
                        $policy.blocked_groups += [pscustomobject][ordered]@{ destination_id=[uint64]$Source.destination_id; slot=[uint64]$Source.slot }
                    }
                } else {
                    $policy.blocked_groups = @($policy.blocked_groups | Where-Object { -not ([uint64]$_.destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot) })
                    if ($policy.group_mode -ceq 'selected' -and @($policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq [uint64]$Source.destination_id -and [uint64]$_.slot -eq [uint64]$Source.slot }).Count -eq 0) {
                        $policy.allow_groups += [pscustomobject][ordered]@{ destination_id=[uint64]$Source.destination_id; slot=[uint64]$Source.slot }
                    }
                }
            } else {
                if (Test-UiLocalPrivateRouteCoversSource -Source $Source -Policy $policy) {
                    Set-RoutingEditorStatus -Text '该时隙已接收所有私呼；请用“屏蔽此来源”，或在设置中选择精确联系人模式。' -Failed $true
                    return
                }
                $isAllowed = @($policy.allow_private_peers | Where-Object {
                    [uint64]$_.source_id -eq [uint64]$Source.source_id -and
                    [uint64]$_.local_destination_id -eq [uint64]$Source.destination_id -and
                    [uint64]$_.slot -eq [uint64]$Source.slot
                }).Count -gt 0
                if ($isAllowed) {
                    $policy.allow_private_peers = @($policy.allow_private_peers | Where-Object {
                        -not ([uint64]$_.source_id -eq [uint64]$Source.source_id -and
                            [uint64]$_.local_destination_id -eq [uint64]$Source.destination_id -and
                            [uint64]$_.slot -eq [uint64]$Source.slot)
                    })
                } else {
                    if ($policy.private_mode -ceq 'disabled') { $policy.private_mode = 'selected_peers' }
                    $policy.allow_private_peers += [pscustomobject][ordered]@{
                        source_id=[uint64]$Source.source_id; local_destination_id=[uint64]$Source.destination_id; slot=[uint64]$Source.slot
                    }
                }
            }
            Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $policy
        }
        'block' {
            if (@($policy.blocked_source_ids | Where-Object { [uint64]$_ -eq [uint64]$Source.source_id }).Count -gt 0) {
                $policy.blocked_source_ids = @($policy.blocked_source_ids | Where-Object { [uint64]$_ -ne [uint64]$Source.source_id })
            } else { $policy.blocked_source_ids += [uint64]$Source.source_id }
            Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $policy
        }
        'tx' {
            $txKind = if ($Source.kind -ceq 'private') { 'private' } else { 'group' }
            $txDestination = if ($Source.kind -ceq 'private') { [uint64]$Source.source_id } else { [uint64]$Source.destination_id }
            $target = [pscustomobject][ordered]@{ destination_id=$txDestination; kind=$txKind; slot=[uint64]$Source.slot }
            $allow = if ($script:activeRouting) { [bool]$script:activeRouting.transmit_enabled } else { [bool]$script:editTransmitEnabled }
            Invoke-UiRoutingMutation -Command 'tx_policy.replace' -PolicyOrTarget $target -TransmitEnabled $allow
        }
    }
}

function Set-SettingsWindowFields {
    $profileError = ''
    $audioError = ''
    try { $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath }
    catch { $script:storedProfile = $null; $profileError = $_.Exception.Message }
    Update-CallTargetChoices
    try { $audio = Read-BridgeAudioSettings -Path $script:audioSettingsPath }
    catch { $audio = $null; $audioError = $_.Exception.Message }
    if ($null -eq $audio) { $audio = [pscustomobject]@{ RadioPlaybackGainMilli = [uint32]1000; MicTransmitGainMilli = [uint32]16000 } }
    $script:savedPlaybackGainMilli = [uint32]$audio.RadioPlaybackGainMilli
    Update-UiPlaybackGainDisplay -Record $script:latestStatus
    $receiveState = Get-UiReceiveEditorState -Profile $script:storedProfile
    $script:receiveEditorState = $receiveState
    $script:profileEditable = $true
    $sourceSchema = Get-UiProfileMigrationSourceSchema -Profile $script:storedProfile
    $script:profileWriteAllowed = $true
    $liveRouting = ($script:activeRouting -and $script:supervisor -and -not $script:supervisor.HasExited)
    $txTarget = if ($script:routingDraftPreservedAfterTimeout -and $script:routingDraftAfterTimeout -and $script:routingDraftAfterTimeout.target) { $script:routingDraftAfterTimeout.target } elseif ($liveRouting) { $script:activeRouting.tx_target } elseif ($script:pendingCallTarget) { $script:pendingCallTarget } elseif ($script:storedProfile) { $script:storedProfile.tx_target } else { $null }
    $policy = if ($script:routingDraftPreservedAfterTimeout -and $script:routingDraftAfterTimeout -and $script:routingDraftAfterTimeout.policy) { $script:routingDraftAfterTimeout.policy } elseif ($liveRouting) { $script:activeRouting.rx_policy } elseif ($script:storedProfile) { $script:storedProfile.rx_policy } else {
        [pscustomobject][ordered]@{ group_mode='selected'; private_mode='disabled'; allow_groups=@(); allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@() }
    }
    $script:editRxPolicy = Copy-UiRxPolicy -Policy $policy
    $script:editTxTarget = if ($txTarget) { [pscustomobject][ordered]@{ destination_id=[uint64]$txTarget.destination_id; kind=[string]$txTarget.kind; slot=[uint64]$txTarget.slot } } else { [pscustomobject][ordered]@{ destination_id=[uint64]91; kind='group'; slot=[uint64]2 } }
    $script:txEditorDirty = $false
    $fields = @{
        CallsignBox = if ($script:storedProfile) { $script:storedProfile.connection.callsign } else { '' }
        GatewayBox = if ($script:storedProfile) { $script:storedProfile.connection.gateway_id } else { '' }
        SourceBox = if ($script:storedProfile) { $script:storedProfile.connection.source_id } else { '' }
        MasterBox = if ($script:storedProfile) { $script:storedProfile.connection.master } else { '' }
        MasterPortBox = if ($script:storedProfile) { $script:storedProfile.connection.master_port } else { '' }
        DestinationBox = if ($script:storedProfile) { $txTarget.destination_id } else { '' }
        ColorCodeBox = if ($script:storedProfile) { $script:storedProfile.connection.color_code } else { '' }
        PasswordPathBox = Read-CurrentPasswordPath
    }
    $script:loadingSettings = $true
    foreach ($name in @('ProfileMigrationText','ReceivePolicyPreviewText')) {
        $control = Get-SettingsControl $name
        $control.Text = ''
        $control.Visibility = [System.Windows.Visibility]::Collapsed
    }
    foreach ($name in $fields.Keys) { (Get-SettingsControl $name).Text = [string]$fields[$name] }
    (Get-SettingsControl 'PlaybackGainSlider').Value = [double]$audio.RadioPlaybackGainMilli / 1000.0
    (Get-SettingsControl 'TransmitGainSlider').Value = [double]$audio.MicTransmitGainMilli / 1000.0
    Set-GainValueLabel -SliderName 'PlaybackGainSlider' -LabelName 'PlaybackGainValueText'
    Set-GainValueLabel -SliderName 'TransmitGainSlider' -LabelName 'TransmitGainValueText'
    Set-SettingsDeviceControls
    $slotBox = Get-SettingsControl 'SlotBox'
    $slotValue = if ($script:storedProfile) { [string]$txTarget.slot } else { '2' }
    $slotBox.SelectedItem = @($slotBox.Items | Where-Object { [string]$_.Tag -ceq $slotValue })[0]
    $kindBox = Get-SettingsControl 'CallKindBox'
    $kindValue = if ($script:storedProfile) { [string]$txTarget.kind } else { 'private' }
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq $kindValue })[0]
    $transmitEnabled = if ($script:routingDraftPreservedAfterTimeout -and $script:routingDraftAfterTimeout -and $null -ne $script:routingDraftAfterTimeout.transmit_enabled) { [bool]$script:routingDraftAfterTimeout.transmit_enabled } elseif ($liveRouting) { [bool]$script:activeRouting.transmit_enabled } elseif ($script:storedProfile -and $null -ne $script:storedProfile.PSObject.Properties['transmit_enabled']) {
        [bool]$script:storedProfile.transmit_enabled
    } else { $true }
    $script:editTransmitEnabled = [bool]$transmitEnabled
    (Get-SettingsControl 'TransmitEnabledBox').IsChecked = $transmitEnabled
    $localSourceText = if ($liveRouting) { [string]$script:activeRouting.local_source_id } elseif ($script:storedProfile) { [string]$script:storedProfile.connection.source_id } else { [string](Get-SettingsControl 'SourceBox').Text }
    foreach ($name in @('PeerLocalDestinationBox','LocalPrivateDestinationBox')) { (Get-SettingsControl $name).Text = $localSourceText }
    Set-SettingsPolicyLists
    $masterPreset = Get-SettingsControl 'MasterPresetBox'
    $masterPresetTag = if ($script:storedProfile -and
        [string]$script:storedProfile.connection.master -ceq '43.129.83.124' -and
        [uint64]$script:storedProfile.connection.master_port -eq 62031) { 'bm-china-4602' } else { 'custom' }
    $masterPreset.SelectedItem = @($masterPreset.Items | Where-Object { [string]$_.Tag -ceq $masterPresetTag })[0]
    foreach ($name in @('CallsignBox','GatewayBox','SourceBox','MasterBox','MasterPortBox','DestinationBox','ColorCodeBox',
            'SlotBox','CallKindBox','TransmitEnabledBox','MasterPresetBox',
            'SerialBox','WaveInEndpointBox','WaveOutEndpointBox')) {
        (Get-SettingsControl $name).IsEnabled = [bool]$script:profileEditable
    }
    if ($liveRouting) { (Get-SettingsControl 'SourceBox').IsEnabled = $false }
    (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = [bool]$script:profileEditable
    $script:loadingSettings = $false
    if ($profileError -or $audioError) {
        $errorLabels = @()
        if ($profileError) { $errorLabels += '连接设置读取失败' }
        if ($audioError) { $errorLabels += '音量设置读取失败' }
        (Get-SettingsControl 'SettingsErrorText').Text = ($errorLabels -join '；')
        (Get-SettingsControl 'SettingsErrorText').Foreground = [Windows.Media.Brushes]::IndianRed
    } else {
        (Get-SettingsControl 'SettingsErrorText').Text = ''
    }
    (Get-SettingsControl 'SettingsErrorText').Visibility = if ($profileError -or $audioError) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Read-SettingsUnsignedField {
    param([string]$ControlName,[uint64]$Minimum=1,[uint64]$Maximum=16777215)
    $control = Get-SettingsControl $ControlName
    $text = if ($control -is [System.Windows.Controls.ComboBox]) { Get-UiComboTag -Combo $control } else { [string]$control.Text }
    $value = [uint64]0
    if (-not [uint64]::TryParse($text,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or
        $value -lt $Minimum -or $value -gt $Maximum) { throw ('{0} 需要填写 {1} 到 {2} 的整数。' -f $ControlName,$Minimum,$Maximum) }
    return $value
}

function Invoke-SettingsPolicyEditorAction {
    param([string]$Action)
    try {
        if ($script:pendingRoutingMutation) { throw '正在等待应用接收上一项设置。' }
        $policy = Copy-UiRxPolicy -Policy $script:editRxPolicy
        $local = Get-UiPolicyLocalSourceId
        switch -CaseSensitive ($Action) {
            'group-mode' {
                $mode = Get-UiComboTag -Combo (Get-SettingsControl 'GroupModeBox')
                if ($mode -cnotin @('selected','all_delivered')) { throw '请选择有效的组呼接收模式。' }
                $policy.group_mode = $mode
            }
            'private-mode' {
                $mode = Get-UiComboTag -Combo (Get-SettingsControl 'PrivateModeBox')
                if ($mode -cnotin @('disabled','selected_peers','all_peers_to_local')) { throw '请选择有效的私呼接收模式。' }
                $policy.private_mode = $mode
                if ($mode -ceq 'disabled') { $policy.allow_private_peers=@(); $policy.local_private_routes=@() }
                elseif ($mode -ceq 'selected_peers') { $policy.local_private_routes=@() }
            }
            'add-group' {
                $id = Read-SettingsUnsignedField -ControlName 'GroupRouteIdBox'
                $slot = Read-SettingsUnsignedField -ControlName 'GroupRouteSlotBox' -Minimum 1 -Maximum 2
                $policy.blocked_groups = @($policy.blocked_groups | Where-Object { -not ([uint64]$_.destination_id -eq $id -and [uint64]$_.slot -eq $slot) })
                if (@($policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq $id -and [uint64]$_.slot -eq $slot }).Count -eq 0) {
                    $policy.allow_groups += [pscustomobject][ordered]@{ destination_id=$id; slot=$slot }
                }
            }
            'remove-group' {
                $list = Get-SettingsControl 'GroupRoutesList'; $index = [int]$list.SelectedIndex
                if ($index -lt 0 -or $index -ge $policy.allow_groups.Count) { throw '请先选择要停止的 Selected 组呼项。' }
                $route = $policy.allow_groups[$index]
                $policy.allow_groups = @($policy.allow_groups | Where-Object { -not ([uint64]$_.destination_id -eq [uint64]$route.destination_id -and [uint64]$_.slot -eq [uint64]$route.slot) })
                if (@($policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq [uint64]$route.destination_id -and [uint64]$_.slot -eq [uint64]$route.slot }).Count -eq 0) { $policy.blocked_groups += [pscustomobject][ordered]@{ destination_id=[uint64]$route.destination_id; slot=[uint64]$route.slot } }
            }
            'block-group' {
                $id = Read-SettingsUnsignedField -ControlName 'BlockedGroupIdBox'
                $slot = Read-SettingsUnsignedField -ControlName 'BlockedGroupSlotBox' -Minimum 1 -Maximum 2
                $policy.allow_groups = @($policy.allow_groups | Where-Object { -not ([uint64]$_.destination_id -eq $id -and [uint64]$_.slot -eq $slot) })
                if (@($policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq $id -and [uint64]$_.slot -eq $slot }).Count -eq 0) { $policy.blocked_groups += [pscustomobject][ordered]@{ destination_id=$id; slot=$slot } }
            }
            'restore-group' {
                $list = Get-SettingsControl 'BlockedGroupsList'; $index = [int]$list.SelectedIndex
                if ($index -lt 0 -or $index -ge $policy.blocked_groups.Count) { throw '请先选择要恢复的 TG/TS。' }
                $route = $policy.blocked_groups[$index]
                $policy.blocked_groups = @($policy.blocked_groups | Where-Object { -not ([uint64]$_.destination_id -eq [uint64]$route.destination_id -and [uint64]$_.slot -eq [uint64]$route.slot) })
                if ($policy.group_mode -ceq 'selected' -and @($policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq [uint64]$route.destination_id -and [uint64]$_.slot -eq [uint64]$route.slot }).Count -eq 0) { $policy.allow_groups += [pscustomobject][ordered]@{ destination_id=[uint64]$route.destination_id; slot=[uint64]$route.slot } }
            }
            'add-peer' {
                $peer = Read-SettingsUnsignedField -ControlName 'PeerSourceIdBox'
                $localDest = Read-SettingsUnsignedField -ControlName 'PeerLocalDestinationBox'
                $slot = Read-SettingsUnsignedField -ControlName 'PeerSlotBox' -Minimum 1 -Maximum 2
                if ($localDest -ne $local) { throw '精确私呼的本机目的 ID 必须等于本机 Source ID。' }
                if ($policy.private_mode -ceq 'disabled') { $policy.private_mode='selected_peers' }
                if (@($policy.allow_private_peers | Where-Object { [uint64]$_.source_id -eq $peer -and [uint64]$_.local_destination_id -eq $localDest -and [uint64]$_.slot -eq $slot }).Count -eq 0) { $policy.allow_private_peers += [pscustomobject][ordered]@{ source_id=$peer; local_destination_id=$localDest; slot=$slot } }
            }
            'remove-peer' {
                $list = Get-SettingsControl 'PeerRoutesList'; $index = [int]$list.SelectedIndex
                if ($index -lt 0 -or $index -ge $policy.allow_private_peers.Count) { throw '请先选择要移除的精确 peer。' }
                $route = $policy.allow_private_peers[$index]
                $policy.allow_private_peers = @($policy.allow_private_peers | Where-Object { -not ([uint64]$_.source_id -eq [uint64]$route.source_id -and [uint64]$_.local_destination_id -eq [uint64]$route.local_destination_id -and [uint64]$_.slot -eq [uint64]$route.slot) })
            }
            'add-local' {
                $localDest = Read-SettingsUnsignedField -ControlName 'LocalPrivateDestinationBox'
                $slot = Read-SettingsUnsignedField -ControlName 'LocalPrivateSlotBox' -Minimum 1 -Maximum 2
                if ($localDest -ne $local) { throw '本机私呼目的 ID 必须等于本机 Source ID。' }
                if ($policy.private_mode -ne 'all_peers_to_local') { $policy.private_mode='all_peers_to_local' }
                if (@($policy.local_private_routes | Where-Object { [uint64]$_.local_destination_id -eq $localDest -and [uint64]$_.slot -eq $slot }).Count -eq 0) { $policy.local_private_routes += [pscustomobject][ordered]@{ local_destination_id=$localDest; slot=$slot } }
            }
            'remove-local' {
                $list = Get-SettingsControl 'LocalPrivateRoutesList'; $index = [int]$list.SelectedIndex
                if ($index -lt 0 -or $index -ge $policy.local_private_routes.Count) { throw '请先选择要移除的本机私呼路由。' }
                $route = $policy.local_private_routes[$index]
                $policy.local_private_routes = @($policy.local_private_routes | Where-Object { -not ([uint64]$_.local_destination_id -eq [uint64]$route.local_destination_id -and [uint64]$_.slot -eq [uint64]$route.slot) })
            }
            'block-source' {
                $sourceId = Read-SettingsUnsignedField -ControlName 'BlockedSourceIdBox'
                if (@($policy.blocked_source_ids | Where-Object { [uint64]$_ -eq $sourceId }).Count -eq 0) { $policy.blocked_source_ids += $sourceId }
            }
            'restore-source' {
                $list = Get-SettingsControl 'BlockedSourcesList'; $index = [int]$list.SelectedIndex
                if ($index -lt 0 -or $index -ge $policy.blocked_source_ids.Count) { throw '请先选择要恢复的发话来源。' }
                $sourceId = [uint64]$policy.blocked_source_ids[$index]
                $policy.blocked_source_ids = @($policy.blocked_source_ids | Where-Object { [uint64]$_ -ne $sourceId })
            }
        }
        Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $policy
    } catch {
        Write-UiRoutingDiagnosticProgress -Message ('settings-action-failed-' + $Action + '-' + $_.Exception.Message)
        Set-RoutingEditorStatus -Text $_.Exception.Message -Failed $true
    }
}

function Submit-SettingsNextTxTarget {
    try {
        if ($script:pendingRoutingMutation) { throw '正在等待应用接收上一项设置。' }
        $kind = Get-UiComboTag -Combo (Get-SettingsControl 'CallKindBox')
        $slot = Get-UiComboTag -Combo (Get-SettingsControl 'SlotBox')
        if ($kind -cnotin @('group','private') -or $slot -cnotin @('1','2')) { throw '请选择有效的下一发射类型和时隙。' }
        $target = [pscustomobject][ordered]@{ destination_id=(Read-SettingsUnsignedField -ControlName 'DestinationBox'); kind=$kind; slot=[uint64]$slot }
        $transmitEnabled = ((Get-SettingsControl 'TransmitEnabledBox').IsChecked -eq $true)
        Invoke-UiRoutingMutation -Command 'tx_policy.replace' -PolicyOrTarget $target -TransmitEnabled $transmitEnabled
    } catch { Set-RoutingEditorStatus -Text $_.Exception.Message -Failed $true }
}

function Initialize-SettingsWindow {
    $script:settingsWindow = Import-WpfWindow -Path $script:settingsXamlPath
    $script:deviceCatalog = $null
    $script:deviceDiscoveryState = if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) { 'stopping' } else { 'not_started' }
    Fit-WpfWindowToWorkArea -Window $script:settingsWindow
    $script:settingsWindow.Owner = $script:mainWindow
    $script:settingsWindow.ShowInTaskbar = $false
    $script:settingsWindow.Add_Closed({
        $closedSettingsWindow = $script:settingsWindow
        $script:settingsWindow = $null
        if ($closedSettingsWindow) { Invalidate-UiDeviceDiscoveryForWindow -Window $closedSettingsWindow }
    })
    (Get-SettingsControl 'CancelSettingsButton').Add_Click({ Cancel-SettingsWindow })
    (Get-SettingsControl 'MasterPresetBox').Add_SelectionChanged({
        if ($script:loadingSettings) { return }
        $selected = (Get-SettingsControl 'MasterPresetBox').SelectedItem
        if ($selected -isnot [System.Windows.Controls.ComboBoxItem]) { return }
        if ([string]$selected.Tag -ceq 'bm-china-4602') {
            (Get-SettingsControl 'MasterBox').Text = '43.129.83.124'
            (Get-SettingsControl 'MasterPortBox').Text = '62031'
        }
    })
    (Get-SettingsControl 'BrowsePasswordButton').Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择本机 BM 密码文件'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($script:settingsWindow) -eq $true) {
            (Get-SettingsControl 'PasswordPathBox').Text = $dialog.FileName
        }
    })
    (Get-SettingsControl 'PlaybackGainSlider').Add_ValueChanged({ Set-GainValueLabel -SliderName 'PlaybackGainSlider' -LabelName 'PlaybackGainValueText' })
    (Get-SettingsControl 'TransmitGainSlider').Add_ValueChanged({ Set-GainValueLabel -SliderName 'TransmitGainSlider' -LabelName 'TransmitGainValueText' })
    (Get-SettingsControl 'RefreshDevicesButton').Add_Click({
        if ($RoutingDiagnostic) { Start-UiDeviceDiscovery; return }
        if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) { return }
        $script:deviceCatalog = $null
        Start-UiDeviceDiscovery
    })
    (Get-SettingsControl 'GroupModeBox').Add_SelectionChanged({ if (-not $script:loadingSettings) { Invoke-SettingsPolicyEditorAction -Action 'group-mode' } })
    (Get-SettingsControl 'PrivateModeBox').Add_SelectionChanged({ if (-not $script:loadingSettings) { Invoke-SettingsPolicyEditorAction -Action 'private-mode' } })
    foreach ($buttonAction in @(
        @{ Name='AddGroupRouteButton'; Action='add-group' }, @{ Name='RemoveGroupRouteButton'; Action='remove-group' },
        @{ Name='AddBlockedGroupButton'; Action='block-group' }, @{ Name='RemoveBlockedGroupButton'; Action='restore-group' },
        @{ Name='AddPeerRouteButton'; Action='add-peer' }, @{ Name='RemovePeerRouteButton'; Action='remove-peer' },
        @{ Name='AddLocalPrivateRouteButton'; Action='add-local' }, @{ Name='RemoveLocalPrivateRouteButton'; Action='remove-local' },
        @{ Name='AddBlockedSourceButton'; Action='block-source' }, @{ Name='RemoveBlockedSourceButton'; Action='restore-source' }
    )) {
        $capturedAction = [string]$buttonAction.Action
        (Get-SettingsControl ([string]$buttonAction.Name)).Add_Click({ Invoke-SettingsPolicyEditorAction -Action $capturedAction }.GetNewClosure())
    }
    (Get-SettingsControl 'ApplyNextTxTargetButton').Add_Click({ Submit-SettingsNextTxTarget })
    (Get-SettingsControl 'DestinationBox').Add_TextChanged({
        if (-not $script:loadingSettings) { $script:txEditorDirty = $true }
        Update-TxTargetButtonState
    })
    (Get-SettingsControl 'SlotBox').Add_SelectionChanged({ if (-not $script:loadingSettings) { $script:txEditorDirty = $true; Update-TxTargetButtonState } })
    (Get-SettingsControl 'CallKindBox').Add_SelectionChanged({ if (-not $script:loadingSettings) { $script:txEditorDirty = $true; Update-TxTargetButtonState } })
    (Get-SettingsControl 'TransmitEnabledBox').Add_Checked({ if (-not $script:loadingSettings) { $script:txEditorDirty = $true } })
    (Get-SettingsControl 'TransmitEnabledBox').Add_Unchecked({ if (-not $script:loadingSettings) { $script:txEditorDirty = $true } })
    (Get-SettingsControl 'SaveSettingsButton').Add_Click({ Save-SettingsFromWindow })
    Set-SettingsWindowFields
    if ($RoutingDiagnostic) {
        Start-UiDeviceDiscovery
        foreach ($name in @('SerialBox','WaveInEndpointBox','WaveOutEndpointBox','RefreshDevicesButton','SaveSettingsButton')) {
            (Get-SettingsControl $name).IsEnabled = $false
        }
    }
    elseif ($RenderOnly) { (Get-SettingsControl 'DeviceDiscoveryText').Text = '离线渲染；未读取本机设备。' }
    else { Start-UiDeviceDiscovery }
}

function Show-SettingsWindow {
    param([switch]$ScrollToVolume)
    if ($null -eq $script:settingsWindow) { Initialize-SettingsWindow }
    if ($ScrollToVolume) {
        $script:settingsWindow.Add_Loaded({
            $slider = Get-SettingsControl 'PlaybackGainSlider'
            $slider.BringIntoView()
            $slider.Focus()
        }.GetNewClosure())
    }
    [void]$script:settingsWindow.ShowDialog()
}

function Cancel-SettingsWindow {
    $script:txEditorDirty = $false
    if (-not $script:pendingRoutingMutation) {
        $script:routingDraftAfterTimeout = $null
        $script:routingDraftPreservedAfterTimeout = $false
        if ($script:activeRouting) {
            $script:editRxPolicy = Copy-UiRxPolicy -Policy $script:activeRouting.rx_policy
            $script:editTxTarget = [pscustomobject][ordered]@{ destination_id=[uint64]$script:activeRouting.tx_target.destination_id; kind=[string]$script:activeRouting.tx_target.kind; slot=[uint64]$script:activeRouting.tx_target.slot }
            $script:editTransmitEnabled = [bool]$script:activeRouting.transmit_enabled
        } elseif ($script:storedProfile) {
            $script:editRxPolicy = Copy-UiRxPolicy -Policy $script:storedProfile.rx_policy
            $script:editTxTarget = [pscustomobject][ordered]@{ destination_id=[uint64]$script:storedProfile.tx_target.destination_id; kind=[string]$script:storedProfile.tx_target.kind; slot=[uint64]$script:storedProfile.tx_target.slot }
            $script:editTransmitEnabled = [bool]$script:storedProfile.transmit_enabled
        }
    }
    if ($script:settingsWindow) { $script:settingsWindow.Close() }
}

function Test-UiAutoEndpointResolvable {
    param([object[]]$Devices)
    $usable = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -eq $true -and $_.endpoint_id -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    $usb = @($usable | Where-Object { [string]$_.name -match '(?i)USB Audio' })
    return ($usb.Count -eq 1)
}

function Save-SettingsFromWindow {
    try {
        $writeProfile = [bool]$script:profileWriteAllowed
        $profile = $script:storedProfile
        if ($script:profileEditable) {
            $slotItem = (Get-SettingsControl 'SlotBox').SelectedItem
            $kindItem = (Get-SettingsControl 'CallKindBox').SelectedItem
            $serialContainer = (Get-SettingsControl 'SerialBox').SelectedItem
            $waveInContainer = (Get-SettingsControl 'WaveInEndpointBox').SelectedItem
            $waveOutContainer = (Get-SettingsControl 'WaveOutEndpointBox').SelectedItem
            if ($serialContainer -isnot [System.Windows.Controls.ComboBoxItem] -or
                $waveInContainer -isnot [System.Windows.Controls.ComboBoxItem] -or
                $waveOutContainer -isnot [System.Windows.Controls.ComboBoxItem]) {
                throw '请从设备列表中明确选择串口、音频输入和音频输出。'
            }
            $serialItem = $serialContainer.Tag; $waveInItem = $waveInContainer.Tag; $waveOutItem = $waveOutContainer.Tag
            if ($null -eq $serialItem -or $null -eq $waveInItem -or $null -eq $waveOutItem) { throw '设备列表项目缺少内部选择信息；请刷新设备列表。' }
            if (-not $serialItem.IsAvailable -or -not $waveInItem.IsAvailable -or -not $waveOutItem.IsAvailable) { throw '所选设备当前不可用；请从列表中选择已发现的设备。' }
            if ($script:deviceDiscoveryState -eq 'ready') {
                if ([string]$serialItem.Value -ceq 'auto') {
                    $hri = @($script:deviceCatalog.hri_ports); $knownCom5 = @($hri | Where-Object { $_.PortName -ceq 'COM5' })
                    if ($hri.Count -eq 0 -or ($knownCom5.Count -ne 1 -and $hri.Count -ne 1)) { throw '当前有多个或没有已确认的 HRI 串口；请从下拉列表中选择 HRI 设备。' }
                }
                if ([string]$waveInItem.Value -ceq 'auto' -and -not (Test-UiAutoEndpointResolvable -Devices @($script:deviceCatalog.wave_inputs))) { throw '电台音频输入有多个候选设备；请从下拉列表中选择稳定端点。' }
                if ([string]$waveOutItem.Value -ceq 'auto' -and -not (Test-UiAutoEndpointResolvable -Devices @($script:deviceCatalog.wave_outputs))) { throw '电台音频输出有多个候选设备；请从下拉列表中选择稳定端点。' }
            }
            if ($slotItem -isnot [System.Windows.Controls.ComboBoxItem] -or $kindItem -isnot [System.Windows.Controls.ComboBoxItem]) { throw '请选择下一发射目标的时隙和呼叫类型。' }
            $connection = [pscustomobject][ordered]@{
                callsign=(Get-SettingsControl 'CallsignBox').Text; gateway_id=(Get-SettingsControl 'GatewayBox').Text
                source_id=(Get-SettingsControl 'SourceBox').Text; master=(Get-SettingsControl 'MasterBox').Text
                master_port=(Get-SettingsControl 'MasterPortBox').Text; color_code=(Get-SettingsControl 'ColorCodeBox').Text
            }
            $txTarget = [pscustomobject][ordered]@{
                destination_id=(Get-SettingsControl 'DestinationBox').Text
                kind=[string]$kindItem.Tag; slot=[string]$slotItem.Tag
            }
            $devices = [pscustomobject][ordered]@{
                serial_port=[string]$serialItem.Value; wave_in_endpoint_id=[string]$waveInItem.Value
                wave_out_endpoint_id=[string]$waveOutItem.Value
            }
            $liveRouting = ($script:activeRouting -and $script:supervisor -and -not $script:supervisor.HasExited)
            if ($liveRouting) {
                if ($script:pendingRoutingMutation) { throw '请等待当前设置完成或超时后再保存。' }
                $transmitEnabledForm = ((Get-SettingsControl 'TransmitEnabledBox').IsChecked -eq $true)
                if ([uint64]$txTarget.destination_id -ne [uint64]$script:activeRouting.tx_target.destination_id -or
                    [string]$txTarget.kind -cne [string]$script:activeRouting.tx_target.kind -or
                    [uint64]$txTarget.slot -ne [uint64]$script:activeRouting.tx_target.slot -or
                    $transmitEnabledForm -ne [bool]$script:activeRouting.transmit_enabled) {
                    throw '请先应用下一发射目标并等待设置生效。'
                }
                $txTarget = [pscustomobject][ordered]@{ destination_id=[uint64]$script:activeRouting.tx_target.destination_id; kind=[string]$script:activeRouting.tx_target.kind; slot=[uint64]$script:activeRouting.tx_target.slot }
                $rxPolicy = Copy-UiRxPolicy -Policy $script:activeRouting.rx_policy
                $transmitEnabled = [bool]$script:activeRouting.transmit_enabled
            } else {
                $rxPolicy = Copy-UiRxPolicy -Policy $script:editRxPolicy
                $transmitEnabled = ((Get-SettingsControl 'TransmitEnabledBox').IsChecked -eq $true)
            }
            $profile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -TxTarget $txTarget -Devices $devices `
                -RxPolicy $rxPolicy -TransmitEnabled $transmitEnabled -AllowTextNumbers
            $writeProfile = $true
        } elseif (-not $writeProfile) {
            if ($null -eq $profile) { throw '当前没有可保存的连接配置。' }
        }
        $playbackValue = [double](Get-SettingsControl 'PlaybackGainSlider').Value
        $transmitValue = [double](Get-SettingsControl 'TransmitGainSlider').Value
        $playbackMilli = Convert-UiGainSliderToMilli -Value $playbackValue
        $transmitMilli = Convert-UiGainSliderToMilli -Value $transmitValue
        $passwordCandidate = (Get-SettingsControl 'PasswordPathBox').Text.Trim()
        if ($passwordCandidate) {
            $passwordCandidate = [System.IO.Path]::GetFullPath($passwordCandidate)
            if (-not [System.IO.File]::Exists($passwordCandidate)) { throw '所选 BM 密码文件当前不存在。' }
        }

        $saveFiles = if ($writeProfile) { @($script:profilePath, $script:audioSettingsPath, $script:passwordPointerPath) } `
            else { @($script:audioSettingsPath, $script:passwordPointerPath) }
        $transactionId = [guid]::NewGuid().ToString('N')
        $backupRecords = @()
        try {
            foreach ($path in $saveFiles) {
                $existed = [System.IO.File]::Exists($path)
                $backup = $path + '.ui-backup-' + $transactionId
                if ($existed) { [System.IO.File]::Copy($path, $backup, $false) }
                $backupRecords += [pscustomobject]@{ Path = $path; Existed = $existed; Backup = $backup }
            }
            if ($writeProfile) { Write-BridgeUserConnectionProfile -Path $script:profilePath -Profile $profile }
            Write-BridgeAudioSettings -Path $script:audioSettingsPath -RadioPlaybackGainMilli $playbackMilli `
                -MicTransmitGainMilli $transmitMilli
            if ($passwordCandidate) {
                $temporaryPath = $script:passwordPointerPath + '.tmp-' + [guid]::NewGuid().ToString('N')
                $backupPath = $script:passwordPointerPath + '.bak-' + [guid]::NewGuid().ToString('N')
                try {
                    [System.IO.File]::WriteAllText($temporaryPath, $passwordCandidate + "`n", (New-Object System.Text.UTF8Encoding($false)))
                    if ([System.IO.File]::Exists($script:passwordPointerPath)) { [System.IO.File]::Replace($temporaryPath, $script:passwordPointerPath, $backupPath) }
                    else { [System.IO.File]::Move($temporaryPath, $script:passwordPointerPath) }
                } finally {
                    if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
                    if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
                }
            } elseif ([System.IO.File]::Exists($script:passwordPointerPath)) {
                [System.IO.File]::Delete($script:passwordPointerPath)
            }
        } catch {
            $saveError = $_.Exception.Message
            $rollbackErrors = @()
            foreach ($record in $backupRecords) {
                try {
                    if ($record.Existed -and [System.IO.File]::Exists($record.Backup)) {
                        [System.IO.File]::Copy($record.Backup, $record.Path, $true)
                    } elseif (-not $record.Existed -and [System.IO.File]::Exists($record.Path)) {
                        [System.IO.File]::Delete($record.Path)
                    }
                } catch { $rollbackErrors += ($record.Path + ': ' + $_.Exception.Message) }
            }
            if ($rollbackErrors.Count -gt 0) {
                throw ('设置保存失败，部分文件可能仍含有旧值或新值；请重新打开设置核对。' + ($rollbackErrors -join '；'))
            }
            throw ('设置保存失败，已恢复保存前的配置。' + $saveError)
        } finally {
            foreach ($record in $backupRecords) {
                if ([System.IO.File]::Exists($record.Backup)) { [System.IO.File]::Delete($record.Backup) }
            }
        }
        if ($writeProfile) {
            $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
            (Get-SettingsControl 'SettingsErrorText').Text = '设置已保存'
        } else {
            (Get-SettingsControl 'SettingsErrorText').Text = '设置已保存'
        }
        (Get-SettingsControl 'SettingsErrorText').Visibility = [System.Windows.Visibility]::Visible
        $script:savedPlaybackGainMilli = [uint32]$playbackMilli
        Update-UiPlaybackGainDisplay -Record $script:latestStatus
        $pendingProfile = $script:storedProfile
        $script:targetLabel = Format-ProfileTarget -Profile $pendingProfile
        $wasRunning = ($script:supervisor -and -not $script:supervisor.HasExited)
        if ($wasRunning) {
            Set-MainText -Name 'TrafficDetail' -Text ('设置已保存；下一次连接将使用 {0}；发射：{1}；{2}。' -f `
                (Format-ProfileReceiveTarget -Profile $pendingProfile),
                (Format-ProfileTarget -Profile $pendingProfile),
                (Format-ProfileTransmitPermission -Profile $pendingProfile))
            Set-MainTargetSummary -Profile $script:activeProfile -OverallLabel $script:activeTargetLabel
        } elseif ($pendingProfile) {
            Set-MainTargetSummary -Profile $pendingProfile -OverallLabel $script:targetLabel
        }
        $script:settingsWindow.Close()
        if ($script:startupNeedsSettings -and -not $wasRunning -and -not $OfflinePreview -and -not $NoAutoConnect) {
            $script:startupNeedsSettings = $false
            Start-BridgeRun
        } else {
            Set-MainText -Name 'FooterText' -Text '设置已保存'
        }
    } catch {
        (Get-SettingsControl 'SettingsErrorText').Text = '设置保存失败'
        (Get-SettingsControl 'SettingsErrorText').Visibility = [System.Windows.Visibility]::Visible
        (Get-SettingsControl 'SettingsErrorText').Foreground = [Windows.Media.Brushes]::IndianRed
    }
}

function Raise-UiButtonClick {
    param([string]$ControlName)
    $button = $null
    if ($script:settingsWindow) { $button = $script:settingsWindow.FindName($ControlName) }
    if ($null -eq $button -and $script:mainWindow) { $button = $script:mainWindow.FindName($ControlName) }
    if ($null -eq $button -or $button -isnot [System.Windows.Controls.Button]) { throw "找不到自动验收按钮 $ControlName。" }
    $args = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
    $button.RaiseEvent($args)
}

function Invoke-UiRoutingDiagnosticObservedGroupToggle {
    param([uint64]$DestinationId,[uint64]$Slot)
    if (-not $script:activeRouting -or -not $RoutingDiagnosticAutoTest) { throw '观察来源卡片自动动作仅用于本机路由诊断验收。' }
    $script:activeRouting.observed_sources = @([pscustomobject][ordered]@{
        source_id=[uint64]777; destination_id=$DestinationId; slot=$Slot; kind='group'; observation_level='outer_header_seen'
    })
    Update-RoutingDisplays
    $panel = $script:mainWindow.FindName('ObservedSourcesPanel')
    foreach ($card in @($panel.Children)) {
        if ($card -isnot [System.Windows.Controls.Border] -or $card.Child -isnot [System.Windows.Controls.StackPanel]) { continue }
        $actions = @($card.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.UniformGrid] }) | Select-Object -First 1
        if (-not $actions -or $actions.Children.Count -lt 1) { continue }
        $button = $actions.Children[0]
        $source = if ($button.Tag) { $button.Tag.Source } else { $null }
        if ($source -and [uint64]$source.destination_id -eq $DestinationId -and [uint64]$source.slot -eq $Slot) {
            if (-not $button.IsEnabled) { throw '观察来源卡片的组呼动作被禁用。' }
            $eventArgs = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            $button.RaiseEvent($eventArgs)
            return
        }
    }
    throw '没有找到诊断用观察来源卡片的实际界面按钮。'
}

function Start-UiRoutingDiagnosticAutoTest {
    if ($script:routingDiagnosticAutoTestStarted -or -not $RoutingDiagnosticAutoTest -or -not $script:activeRouting) { return }
    $script:routingDiagnosticAutoTestStarted = $true
    Write-UiRoutingDiagnosticProgress -Message 'initial-routing-state-received'
    if (-not $script:storedProfile -or [uint64]$script:storedProfile.connection.source_id -ne 1) {
        Set-MainText -Name 'TrafficDetail' -Text '路由诊断自动验收需要本地测试配置 Source ID 1。'
        Request-StopAndExit
        return
    }
    try {
        if ($null -eq $script:settingsWindow) {
            Write-UiRoutingDiagnosticProgress -Message 'settings-window-initialize-started'
            Initialize-SettingsWindow
            Write-UiRoutingDiagnosticProgress -Message 'settings-window-initialize-completed'
        }
        (Get-SettingsControl 'GroupRouteIdBox').Text = '12345'
        $slot = Get-SettingsControl 'GroupRouteSlotBox'
        $slot.SelectedItem = @($slot.Items | Where-Object { [string]$_.Tag -ceq '1' })[0]
        $script:routingDiagnosticAutoTestPhase = 1
        Write-UiRoutingDiagnosticProgress -Message 'add-group-button-click-started'
        Raise-UiButtonClick -ControlName 'AddGroupRouteButton'
        Write-UiRoutingDiagnosticProgress -Message 'rx-add-group-button-clicked'
        if (-not $script:settingsWindow.IsVisible) {
            Write-UiRoutingDiagnosticProgress -Message 'settings-window-show-started'
            $script:settingsWindow.Show()
        }
        Write-UiRoutingDiagnosticProgress -Message 'settings-window-visible'
    } catch {
        $failure = $_.Exception
        $details = '{0}: {1}{2}{3}' -f $failure.GetType().FullName, $failure.Message,
            [Environment]::NewLine, [string]$_.ScriptStackTrace
        Write-UiRoutingDiagnosticProgress -Message ('auto-test-initialization-failed:' + $details)
        Fail-UiRoutingDiagnosticDynamicGroupTest -Message $details
        return
    }
}

function Invoke-UiRoutingDiagnosticTimeoutFenceProbe {
    if (-not $RoutingDiagnosticAutoTest -or -not $script:settingsWindow -or -not $script:supervisor -or $script:supervisor.HasExited) {
        throw '无法执行本机超时锁定验收。'
    }
    $requestId = [guid]::NewGuid().ToString('D')
    $script:pendingRoutingMutation = [pscustomobject]@{
        request_id=$requestId; command='rx_policy.replace'; expected_revision=[uint64]$script:activeRouting.rx_policy_revision
        policy=(Copy-UiRxPolicy -Policy $script:activeRouting.rx_policy); target=$null; transmit_enabled=$null
        started_utc=[DateTime]::UtcNow.AddSeconds(-9)
    }
    $script:pendingControlRequests[$requestId] = 'rx_policy.replace'
    Set-RoutingMutationPendingState -Pending $true
    On-UiTimerTick
    if (-not $script:routingMutationFence -or $script:pendingRoutingMutation -or
        (Get-SettingsControl 'AddGroupRouteButton').IsEnabled) { throw '等待超时后路由控件没有保持锁定。' }
    $secondMutationWasBlocked = $false
    try { Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $script:activeRouting.rx_policy }
    catch { $secondMutationWasBlocked = ($_.Exception.Message -match '刷新') }
    if (-not $secondMutationWasBlocked -or $script:pendingRoutingMutation) { throw '当前设置刷新完成前仍能提交第二项路由修改。' }
    $script:routingDiagnosticFenceProbeWaiting = $true
}

function Continue-UiRoutingDiagnosticAutoTestAfterFenceRefresh {
    $script:routingDiagnosticFenceProbeWaiting = $false
    if ($script:routingMutationFence -or (Get-SettingsControl 'AddBlockedSourceButton').IsEnabled -ne $true) {
        Write-UiRoutingDiagnosticResult -Passed $false -Message '超时后读取当前设置成功，但路由控件没有解锁。'
        if ($script:settingsWindow) { $script:settingsWindow.Close() }
        Request-StopAndExit
        return
    }
    $script:routingDiagnosticFenceProbeVerified = $true
    (Get-SettingsControl 'BlockedSourceIdBox').Text = '777'
    $script:routingDiagnosticAutoTestPhase = 2
    Raise-UiButtonClick -ControlName 'AddBlockedSourceButton'
}

function Complete-UiRoutingDiagnosticAutoTest {
    param([object]$Mutation,[object]$Routing)
    if ($Mutation.command -ceq 'rx_policy.replace') {
        try {
            Write-UiRoutingDiagnosticProgress -Message ('rx-ack-phase-' + $script:routingDiagnosticAutoTestPhase)
            $saved = Read-BridgeUserConnectionProfile -Path $script:profilePath
            if ($script:routingDiagnosticAutoTestPhase -eq 1) {
                if (-not $saved -or @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 1) { throw 'RX 路由 ACK 后没有写入独立配置。' }
                if ((Get-SettingsControl 'DestinationBox').Text -cne '53000' -or (Get-SettingsControl 'CallKindBox').SelectedItem.Tag -cne 'group' -or
                    (Get-SettingsControl 'SlotBox').SelectedItem.Tag -cne '2' -or (Get-SettingsControl 'TransmitEnabledBox').IsChecked -ne $true) {
                    throw '初始状态推送或 RX 确认覆盖了用户正在编辑的下一发射草稿。'
                }
                Invoke-UiRoutingDiagnosticTimeoutFenceProbe
                return
            }
            if ($script:routingDiagnosticAutoTestPhase -eq 2) {
                if (-not $saved -or @($saved.rx_policy.blocked_source_ids | Where-Object { [uint64]$_ -eq 777 }).Count -ne 1 -or
                    @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 1) { throw '发话来源屏蔽没有独立保存，或覆盖了已允许的频道。' }
                $script:routingDiagnosticAutoTestPhase = 3
                Invoke-UiRoutingDiagnosticObservedGroupToggle -DestinationId 12345 -Slot 1
                return
            }
            if ($script:routingDiagnosticAutoTestPhase -eq 3) {
                if (-not $saved -or @($saved.rx_policy.blocked_source_ids | Where-Object { [uint64]$_ -eq 777 }).Count -ne 1 -or
                    @($saved.rx_policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 1 -or
                    @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 0) { throw '观察来源卡片屏蔽没有原子切换频道规则，或误改了独立发话来源屏蔽。' }
                $script:routingDiagnosticAutoTestPhase = 4
                Invoke-UiRoutingDiagnosticObservedGroupToggle -DestinationId 12345 -Slot 1
                return
            }
            if ($script:routingDiagnosticAutoTestPhase -eq 4) {
                if (-not $saved -or @($saved.rx_policy.blocked_source_ids | Where-Object { [uint64]$_ -eq 777 }).Count -ne 1 -or
                    @($saved.rx_policy.blocked_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 0 -or
                    @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1 }).Count -ne 1) { throw '观察来源卡片恢复频道时没有保留独立发话来源屏蔽。' }
                if ((Get-SettingsControl 'DestinationBox').Text -cne '53000') { throw 'RX 卡片动作覆盖了下一发射草稿。' }
                $script:routingDiagnosticAutoTestPhase = 5
                Raise-UiButtonClick -ControlName 'ApplyNextTxTargetButton'
                return
            }
            if ($script:routingDiagnosticAutoTestPhase -eq 6) {
                if ($Mutation.command -cne 'rx_policy.replace' -or -not $saved -or
                    @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 46001 -and [uint64]$_.slot -eq 2 }).Count -ne 1 -or
                    @($saved.rx_policy.blocked_source_ids | Where-Object { [uint64]$_ -eq 777 }).Count -ne 1 -or
                    [uint64]$Routing.tx_target.destination_id -ne 53000 -or $Routing.tx_target.kind -cne 'group' -or
                    [uint64]$Routing.tx_target.slot -ne 2 -or -not [bool]$Routing.transmit_enabled) {
                    throw '加入本机收听没有只更新RX规则，或动态组动作覆盖了发射状态/来源屏蔽。'
                }
                $beforeListen = ConvertFrom-Json -InputObject $script:routingDiagnosticDynamicGroupBeforeListen -ErrorAction Stop
                if (@($beforeListen.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 46001 -and [uint64]$_.slot -eq 2 }).Count -ne 0 -or
                    (ConvertTo-Json -InputObject $beforeListen.tx_target -Compress -Depth 8) -cne
                        (ConvertTo-Json -InputObject $Routing.tx_target -Compress -Depth 8) -or
                    [bool]$beforeListen.transmit_enabled -ne [bool]$Routing.transmit_enabled) {
                    throw '本机收听按钮没有仅更新接收策略，或改动了下一发射目标/发射许可。'
                }
                $script:routingDiagnosticDynamicGroupLocalListenCommand = [string]$Mutation.command
                $script:routingDiagnosticDynamicGroupBeforeActivation = ConvertTo-Json -InputObject $Routing -Compress -Depth 16
                $script:routingDiagnosticAutoTestPhase = 7
                Update-DynamicGroupControls
                if (-not (Get-UiControl 'ActivateDynamicGroupButton').IsEnabled) {
                    throw '隔离自动验收上下文没有启用动态组按钮。'
                }
                Raise-UiButtonClick -ControlName 'ActivateDynamicGroupButton'
                Write-UiRoutingDiagnosticProgress -Message 'dynamic-activate-button-clicked'
                return
            }
            throw '自动路由验收收到了阶段外的 RX 确认。'
        } catch {
            Write-UiRoutingDiagnosticResult -Passed $false -Message $_.Exception.Message
            if ($script:settingsWindow) { $script:settingsWindow.Close() }
            Request-StopAndExit
            return
        }
    }
    if ($Mutation.command -ceq 'tx_policy.replace') {
        try {
            Write-UiRoutingDiagnosticProgress -Message 'tx-ack-received'
            $saved = Read-BridgeUserConnectionProfile -Path $script:profilePath
            if (-not $saved -or [uint64]$saved.tx_target.destination_id -ne 53000 -or
                $saved.tx_target.kind -cne 'group' -or [uint64]$saved.tx_target.slot -ne 2 -or -not $saved.transmit_enabled) {
                throw 'TX 目标 ACK 后没有写入独立配置。'
            }
            $beforeCancelHash = (Get-FileHash -LiteralPath $script:profilePath -Algorithm SHA256).Hash
            Raise-UiButtonClick -ControlName 'CancelSettingsButton'
            $afterCancelHash = (Get-FileHash -LiteralPath $script:profilePath -Algorithm SHA256).Hash
            if ($beforeCancelHash -cne $afterCancelHash) { throw '运行设置已确认保存后，取消设置窗口又改写了配置。' }
            $script:routingDiagnosticAutoTestPhase = 6
            $script:routingDiagnosticDynamicGroupBeforeListen = ConvertTo-Json -InputObject $Routing -Compress -Depth 16
            (Get-UiControl 'DynamicGroupIdBox').Text = '46001'
            $dynamicSlot = Get-UiControl 'DynamicGroupSlotBox'
            $dynamicSlot.SelectedItem = @($dynamicSlot.Items | Where-Object { [string]$_.Tag -ceq '2' })[0]
            Update-DynamicGroupControls
            if (-not (Get-UiControl 'AddListenGroupButton').IsEnabled) {
                throw '隔离自动验收上下文没有启用本机收听按钮。'
            }
            Raise-UiButtonClick -ControlName 'AddListenGroupButton'
            Write-UiRoutingDiagnosticProgress -Message 'dynamic-local-listen-button-clicked'
            return
        } catch {
            Write-UiRoutingDiagnosticResult -Passed $false -Message $_.Exception.Message -Routing $Routing
        }
        if ($script:settingsWindow) { $script:settingsWindow.Close() }
        Request-StopAndExit
    }
}

function Fail-UiRoutingDiagnosticDynamicGroupTest {
    param([string]$Message)
    $script:routingDiagnosticDynamicGroupTest = [pscustomobject][ordered]@{
        passed=$false; message=$Message; bm_connected=$false; used_memory_sink=$true
    }
    Write-UiRoutingDiagnosticProgress -Message ('dynamic-group-test-failed:' + $Message)
    Write-UiRoutingDiagnosticResult -Passed $false -Message $Message -Routing $script:activeRouting
    Add-UiEvent ('离线动态组按钮验收失败：' + $Message)
    if ($script:settingsWindow) { $script:settingsWindow.Close() }
    Request-StopAndExit
}

function Complete-UiRoutingDiagnosticDynamicGroupTest {
    param([object]$Routing)
    try {
        if ($script:routingDiagnosticAutoTestPhase -ne 8 -or
            [string]::IsNullOrWhiteSpace($script:routingDiagnosticDynamicGroupBeforeActivation) -or
            -not $script:routingDiagnosticDynamicGroupActivationResponse -or
            $script:routingDiagnosticDynamicGroupLocalListenCommand -cne 'rx_policy.replace') {
            throw '动态组按钮链结果缺少本机收听确认、激活结果或比较前状态。'
        }
        $beforeJson = $script:routingDiagnosticDynamicGroupBeforeActivation
        $afterJson = ConvertTo-Json -InputObject $Routing -Compress -Depth 16
        if ($beforeJson -cne $afterJson) {
            throw '激活动作改变了本机RX路由、来源屏蔽、下一发射目标或发射许可。'
        }
        $saved = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if (-not $saved -or
            @($saved.rx_policy.allow_groups | Where-Object { [uint64]$_.destination_id -eq 46001 -and [uint64]$_.slot -eq 2 }).Count -ne 1 -or
            @($saved.rx_policy.blocked_source_ids | Where-Object { [uint64]$_ -eq 777 }).Count -ne 1 -or
            [uint64]$Routing.tx_target.destination_id -ne 53000 -or $Routing.tx_target.kind -cne 'group' -or
            [uint64]$Routing.tx_target.slot -ne 2 -or -not [bool]$Routing.transmit_enabled) {
            throw '动态组离线按钮验收没有保留本机TG46001收听、来源屏蔽或已确认的TX状态。'
        }
        $script:routingDiagnosticDynamicGroupTest = [pscustomobject][ordered]@{
            passed=$true; message='WPF两个动态组按钮经Native Dispatcher分发到不同命令。'
            local_listen_command=$script:routingDiagnosticDynamicGroupLocalListenCommand
            activation_command=[string]$script:routingDiagnosticDynamicGroupActivationResponse.command
            destination_id=[uint64]$script:routingDiagnosticDynamicGroupActivationResponse.destination_id
            slot=[uint64]$script:routingDiagnosticDynamicGroupActivationResponse.slot
            frames_sent=[uint64]$script:routingDiagnosticDynamicGroupActivationResponse.frames_sent
            replayed=[bool]$script:routingDiagnosticDynamicGroupActivationResponse.replayed
            rx_tx_unchanged_after_activation=$true; source_block_preserved=$true
            bm_connected=$false; bm_state='not_started'; used_memory_sink=$true
        }
        Write-UiRoutingDiagnosticProgress -Message 'dynamic-group-action-test-passed'
        Write-UiRoutingDiagnosticResult -Passed $true -Message 'WPF本机收听按钮只更新RX策略；动态组按钮发送一次QuickCall，经内存接收器验证两帧；BM未连接，RX/TX状态未被激活命令改写。' -Routing $Routing
    } catch {
        Fail-UiRoutingDiagnosticDynamicGroupTest -Message $_.Exception.Message
        return
    }
    if ($script:settingsWindow) { $script:settingsWindow.Close() }
    Request-StopAndExit
}

function Write-UiRoutingDiagnosticResult {
    param([bool]$Passed,[string]$Message,[object]$Routing)
    if (-not $script:configDirectory) { return }
    $result = [pscustomobject][ordered]@{
        schema_version=1; passed=$Passed; message=$Message
        dynamic_group_action_test=$script:routingDiagnosticDynamicGroupTest
        offline_cancel_verified=[bool]$script:routingDiagnosticOfflineCancelVerified
        timeout_fence_verified=[bool]$script:routingDiagnosticFenceProbeVerified
        rx_policy=if ($Routing) { $Routing.rx_policy } else { $null }
        tx_target=if ($Routing) { $Routing.tx_target } else { $null }
        transmit_enabled=if ($Routing) { [bool]$Routing.transmit_enabled } else { $false }
        rx_policy_revision=if ($Routing) { [uint64]$Routing.rx_policy_revision } else { [uint64]0 }
        tx_policy_revision=if ($Routing) { [uint64]$Routing.tx_policy_revision } else { [uint64]0 }
    }
    $path = Join-Path $script:configDirectory 'routing-diagnostic-result.json'
    [System.IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $result -Depth 8),(New-Object System.Text.UTF8Encoding($false)))
}

function Write-UiRoutingDiagnosticProgress {
    param([string]$Message)
    if (-not $RoutingDiagnosticAutoTest -or -not $script:configDirectory) { return }
    $path = Join-Path $script:configDirectory 'routing-diagnostic-progress.txt'
    [System.IO.File]::AppendAllText($path,([DateTime]::UtcNow.ToString('o') + ' ' + $Message + "`n"),(New-Object System.Text.UTF8Encoding($false)))
}

function Start-BridgeRun {
    if ($script:preparationStarted -or ($script:supervisor -and -not $script:supervisor.HasExited)) { return }
    Set-OfflineDisplay -Reason '正在检查本次连接配置和设备。'
    Reset-UiControlState
    $script:lastUiBmState = ''
    $script:lastUiHriState = ''
    try {
        if ($script:supervisor) { $script:supervisor.Dispose(); $script:supervisor = $null }
        if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
        $script:statusPath = ''
        $script:latestStatus = $null
        $script:lastStatusUtc = [DateTime]::MinValue
        $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if ($null -eq $script:storedProfile) { $script:startupNeedsSettings = $true; Show-SettingsWindow; return }
        $target = Get-SelectedTargetTag
        if ($RoutingDiagnostic) {
            $script:effectiveProfile = $script:storedProfile
        } else {
            $script:effectiveProfile = Get-UiCallTargetSummaryProfile -Profile $script:storedProfile -Preset $target `
                -PendingTarget $script:pendingCallTarget
        }
        $script:targetLabel = Format-ProfileTarget -Profile $script:effectiveProfile
        $script:preparedTargetTag = $target
        $script:preparedTargetLabel = $script:targetLabel
        if (-not $script:supervisor -or $script:supervisor.HasExited) {
            Set-MainTargetSummary -Profile $script:effectiveProfile -OverallLabel $script:targetLabel
        }
        if ($RoutingDiagnostic) {
            if ([uint64]$script:storedProfile.connection.source_id -ne 1) { throw '本地路由诊断只接受隔离测试配置 Source ID 1。' }
            $script:supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
            Write-UiRoutingDiagnosticProgress -Message 'native-start-requested'
            $script:supervisor.Start($script:nativeExecutable,[string[]]@('--routing-diagnostic','--ui-pipe','--ui-control-version','2'),$script:releaseDirectory,2)
            $script:activeProfile = $script:effectiveProfile
            $script:activeTargetLabel = '本机路由诊断（未连接电台或 BM）'
            $script:activeTargetTag = 'routing-diagnostic'
            $banner = Get-UiControl 'OfflineBanner'
            $banner.Visibility = [Windows.Visibility]::Visible
            (Get-UiControl 'OfflineBannerText').Text = '路由诊断：未连接电台、BM、音频或 RF；以下状态只来自本机核心。'
            Set-MainText -Name 'CoreValue' -Text '本机诊断'
            Set-MainText -Name 'CoreDetail' -Text '正在测试本机路由控制管道。'
            Set-MainText -Name 'BmValue' -Text '未连接'
            Set-MainText -Name 'BmDetail' -Text '本地协议诊断未启动 BrandMeister。'
            Set-MainText -Name 'RadioValue' -Text '未连接'
            Set-MainText -Name 'RadioDetail' -Text '本地协议诊断未打开 HRI 或音频设备。'
            Set-MainText -Name 'FooterText' -Text '路由诊断模式；没有打开串口、音频、BM 或 RF。'
            Set-UiControlStatus -Text '等待本机核心确认' -Confirmed $false
            Set-ConnectionButtonState
            return
        }
        $script:passwordPath = Get-BridgePasswordFile -UserConfigDirectory $script:configDirectory
        if ([string]::IsNullOrWhiteSpace($script:passwordPath)) { $script:startupNeedsSettings = $true; Show-SettingsWindow; return }
        $audio = Get-BridgeAudioSettings -Path $script:audioSettingsPath
        $script:savedPlaybackGainMilli = [uint32]$audio.RadioPlaybackGainMilli
        Update-UiPlaybackGainDisplay -Record $null
        $retention = Invoke-UiRunLogRetention -RunRoot (Join-Path $script:configDirectory 'ui-runs') `
            -ConfigRoot $script:configDirectory
        if ($retention.removed -gt 0) { Add-UiEvent ('已清理 {0} 个已结束运行目录' -f $retention.removed) }
        if ($retention.cleanup_errors -gt 0) { Add-UiEvent '有已结束运行记录未能清理' }
        $script:preparedRunDirectory = Join-Path (Join-Path $script:configDirectory 'ui-runs') ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($script:preparedRunDirectory) | Out-Null
        $temporaryProfilePath = Join-Path $script:preparedRunDirectory 'connection-profile.json'
        Write-BridgeUserConnectionProfile -Path $temporaryProfilePath -Profile $script:effectiveProfile
        $preparationPath = Join-Path $script:preparedRunDirectory 'preparation.json'
        $script:statusPath = ''
        $arguments = @{
            Preset = 'manual'
            ConnectionProfilePath = $temporaryProfilePath
            AudioSettingsPath = $script:audioSettingsPath
            PasswordFile = $script:passwordPath
            StatusDirectory = $script:preparedRunDirectory
            PreparationOutputPath = $preparationPath
            PrepareOnly = $true
            NoInteractive = $true
            RequirePasswordFile = $true
        }
        $script:preparePowerShell = [System.Management.Automation.PowerShell]::Create()
        $prepareBody = {
            param([string]$LauncherPath, [hashtable]$LauncherParameters)
            & $LauncherPath @LauncherParameters
        }
        [void]$script:preparePowerShell.AddScript($prepareBody.ToString()).AddArgument($script:releaseLauncher).AddArgument($arguments)
        $script:prepareAsync = $script:preparePowerShell.BeginInvoke()
        $script:preparationStarted = $true
        Set-MainText -Name 'CoreValue' -Text '正在准备连接'
        Set-MainText -Name 'CoreDetail' -Text '正在枚举本机设备并核对音频端点'
        Set-MainText -Name 'RunValue' -Text '准备中'
        Set-MainText -Name 'FreshnessValue' -Text '连接前设备查询在后台执行'
        Set-MainText -Name 'FooterText' -Text '正在准备连接。'
        (Get-UiControl 'SettingsButton').IsEnabled = $false
        (Get-UiControl 'TargetSelector').IsEnabled = $false
        Set-ConnectionButtonState
    } catch {
        $script:preparationStarted = $false
        Set-OfflineDisplay -Reason ('连接准备失败：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置并检查连接参数、密码文件和设备选择。'
        Set-ConnectionButtonState
        Add-UiEvent '连接准备失败'
    }
}

function Complete-BridgePreparation {
    if ($script:closingAfterStop -or $script:reconnectAfterStop) { return }
    if (-not $script:preparePowerShell -or -not $script:prepareAsync -or -not $script:prepareAsync.IsCompleted) { return }
    try {
        [void]$script:preparePowerShell.EndInvoke($script:prepareAsync)
        if ($script:preparePowerShell.HadErrors) {
            $errorText = @($script:preparePowerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '；'
            throw $(if ($errorText) { $errorText } else { '设备预检失败。' })
        }
        $preparationPath = Join-Path $script:preparedRunDirectory 'preparation.json'
        if (-not [System.IO.File]::Exists($preparationPath)) { throw '设备预检没有生成启动参数。' }
        $preparationText = [System.IO.File]::ReadAllText($preparationPath, [System.Text.Encoding]::UTF8)
        $preparation = ConvertFrom-Json -InputObject $preparationText -ErrorAction Stop
        $validatedPreparation = Test-UiPreparationRecord -Record $preparation `
            -RunDirectory $script:preparedRunDirectory `
            -RunRoot (Join-Path $script:configDirectory 'ui-runs') `
            -ExpectedExecutable $script:nativeExecutable
        $script:statusPath = $validatedPreparation.StatusPath
        $script:supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
        $script:supervisor.Start($validatedPreparation.Executable, $validatedPreparation.Arguments, $script:releaseDirectory, 2)
        Set-UiControlStatus -Text '控制协议：等待 v2 control_ready' -Confirmed $false
        $script:activeTargetTag = $script:preparedTargetTag
        $script:activeTargetLabel = $script:preparedTargetLabel
        $script:activeProfile = $script:effectiveProfile
        $script:targetLabel = $script:activeTargetLabel
        $script:pendingCallTarget = $null
        Set-MainTargetSummary -Profile $script:activeProfile -OverallLabel $script:activeTargetLabel
        $script:statusOffset = 0
        $script:partialStatusLine = ''
        $script:currentRunId = ''
        $script:lastSequence = [uint64]0
        $script:lastStatusUtc = [DateTime]::MinValue
        Set-MainText -Name 'CoreValue' -Text '运行中'
        Set-MainText -Name 'CoreDetail' -Text ''
        Set-MainText -Name 'RunValue' -Text ''
        Set-MainText -Name 'FreshnessValue' -Text ''
        Set-MainText -Name 'FooterText' -Text ''
        Add-UiEvent '核心进程已启动'
    } catch {
        Set-OfflineDisplay -Reason ('连接准备失败：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置检查配置，再重新启动。'
        Set-ConnectionButtonState
        Add-UiEvent '连接准备失败'
    } finally {
        $script:preparationStarted = $false
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        (Get-UiControl 'SettingsButton').IsEnabled = $true
        (Get-UiControl 'TargetSelector').IsEnabled = $true
        Set-ConnectionButtonState
    }
}

function Update-UiReceiveMetricsDisplay {
    param([object]$Record=$null)
    if (-not $script:mainWindow) { return }
    $rttPanel = $script:mainWindow.FindName('BmRttMetric')
    $rttValue = $script:mainWindow.FindName('BmRttValue')
    $lossPanel = $script:mainWindow.FindName('RxNetworkMetric')
    $callLossValue = $script:mainWindow.FindName('RxCallLossValue')
    $sessionLossValue = $script:mainWindow.FindName('RxSessionLossValue')
    foreach ($control in @($rttPanel,$lossPanel)) {
        if ($control) { $control.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    foreach ($control in @($rttValue,$callLossValue,$sessionLossValue)) {
        if ($control) { $control.Text = ''; $control.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    if (-not $Record) { return }

    $rttValidProperty = $Record.PSObject.Properties['bm_rtt_valid']
    $rttLastProperty = $Record.PSObject.Properties['bm_rtt_last_ms']
    $rttCountProperty = $Record.PSObject.Properties['bm_rtt_sample_count']
    if ($rttValidProperty -and [bool]$rttValidProperty.Value -and $rttLastProperty -and $rttCountProperty -and
        $null -ne $rttLastProperty.Value -and $null -ne $rttCountProperty.Value) {
        $lastMs = [double]0
        $sampleCount = [uint64]0
        $lastValid = [double]::TryParse([string]$rttLastProperty.Value,[Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$lastMs)
        $countValid = [uint64]::TryParse([string]$rttCountProperty.Value,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$sampleCount)
        if ($lastValid -and $countValid -and $sampleCount -gt 0) {
            $rttValue.Text = ('{0:0.#} ms · {1} 次' -f $lastMs,$sampleCount)
            $rttValue.Visibility = [System.Windows.Visibility]::Visible
            $rttPanel.Visibility = [System.Windows.Visibility]::Visible
        }
    }

    $usingCall = $false
    $expectedProperty = $null
    $receivedProperty = $null
    $lossProperty = $null
    $completeProperty = $null
    $callValid = $Record.PSObject.Properties['rx_call_dmrd_valid']
    $currentValid = $Record.PSObject.Properties['current_call_valid']
    if ($callValid -and [bool]$callValid.Value -and $currentValid -and [bool]$currentValid.Value) {
        $expectedProperty = $Record.PSObject.Properties['rx_call_dmrd_expected']
        $receivedProperty = $Record.PSObject.Properties['rx_call_dmrd_received']
        $lossProperty = $Record.PSObject.Properties['rx_call_dmrd_loss_pct']
        $completeProperty = $Record.PSObject.Properties['rx_call_dmrd_loss_complete']
        $usingCall = $true
    } else {
        $sessionValid = $Record.PSObject.Properties['rx_session_dmrd_valid']
        if ($sessionValid -and [bool]$sessionValid.Value) {
            $expectedProperty = $Record.PSObject.Properties['rx_session_dmrd_expected']
            $receivedProperty = $Record.PSObject.Properties['rx_session_dmrd_received']
            $lossProperty = $Record.PSObject.Properties['rx_session_dmrd_loss_pct']
        }
    }
    if ($expectedProperty -and $receivedProperty -and $lossProperty -and $null -ne $expectedProperty.Value -and
        $null -ne $receivedProperty.Value -and $null -ne $lossProperty.Value) {
        $expected = [uint64]0
        $received = [uint64]0
        $lossPercent = [double]0
        $expectedValid = [uint64]::TryParse([string]$expectedProperty.Value,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$expected)
        $receivedValid = [uint64]::TryParse([string]$receivedProperty.Value,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$received)
        $lossValid = [double]::TryParse([string]$lossProperty.Value,[Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$lossPercent)
        if ($expectedValid -and $receivedValid -and $lossValid -and $expected -gt 0 -and $received -le $expected -and $lossPercent -ge 0 -and $lossPercent -le 100) {
            $value = ('{0:0.#}%' -f $lossPercent)
            $lossTarget = if ($usingCall) { $callLossValue } else { $sessionLossValue }
            $lossTarget.Text = $value
            $lossTarget.Visibility = [System.Windows.Visibility]::Visible
            $lossPanel.Visibility = [System.Windows.Visibility]::Visible
        }
    }
}

function Apply-StatusRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
    if (-not $script:supervisor -or $script:supervisor.HasExited) { return }
    $nowUtcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not (Test-UiRunRecordAcceptance -Record $Record -ExpectedProcessId ([uint32]$script:supervisor.ProcessId) `
            -LockedRunId $script:currentRunId -LastSequence $script:lastSequence -NowUtcMs $nowUtcMs)) { return }
    $sequence = [uint64]0
    [void][uint64]::TryParse([string]$Record.seq, [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$sequence)
    $recordUtcMs = [int64]$Record.timestamp_utc_ms
    $script:currentRunId = [string]$Record.run_id
    $script:lastSequence = $sequence
    $script:lastStatusUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($recordUtcMs).UtcDateTime
    $script:latestStatus = $Record
    Set-MainText -Name 'CoreValue' -Text '运行中'
    $bm = [string]$Record.bm_state
    if ($script:lastUiBmState -cne $bm) {
        switch -CaseSensitive ($bm) {
            'ready' { Add-UiEvent 'BM 已连接' }
            'recovering' { Add-UiEvent 'BM 正在恢复连接' }
            'backoff' { Add-UiEvent 'BM 正在重试连接' }
            'stopped' { Add-UiEvent 'BM 已停止' }
            'connecting' { Add-UiEvent 'BM 正在连接' }
        }
        $script:lastUiBmState = $bm
    }
    switch ($bm) {
        'ready' { Set-MainText -Name 'BmValue' -Text '已连接' }
        'stopped' { Set-MainText -Name 'BmValue' -Text '已停止' }
        'recovering' { Set-MainText -Name 'BmValue' -Text '恢复中' }
        'backoff' { Set-MainText -Name 'BmValue' -Text '重试中' }
        'connecting' { Set-MainText -Name 'BmValue' -Text '连接中' }
        default { Set-MainText -Name 'BmValue' -Text '' }
    }
    $failure = [string]$Record.bm_failure
    if ($failure -cne 'none') {
        $bmDetail = switch -CaseSensitive ($failure) {
            'login_timeout' { 'BM 登录等待超时' }
            'auth_timeout' { 'BM 认证等待超时' }
            'config_timeout' { 'BM 配置响应超时' }
            'options_timeout' { 'BM 参数响应超时' }
            'pong_timeout' { 'BM 心跳响应超时' }
            'master_rejected' { 'BM 拒绝连接' }
            'master_closed' { 'BM 关闭连接' }
            'malformed_response' { 'BM 响应格式无效' }
            'unexpected_response' { '收到无法识别的 BM 响应' }
            'wrong_peer_id' { 'BM 对端 ID 不匹配' }
            'authentication_error' { 'BM 认证失败' }
            'inbound_queue_full' { 'BM 接收队列已满' }
            'outbound_queue_full' { 'BM 发送队列已满' }
            'transport_lost' { 'BM 网络连接中断' }
            'invalid_profile' { 'BM 连接参数无效' }
            default { 'BM 返回未知错误' }
        }
    } elseif ($bm -ceq 'ready') {
        $bmDetail = '已收到 BM 登录确认。'
    } else {
        $bmDetail = '等待 BM 登录确认。'
    }
    Set-MainText -Name 'BmDetail' -Text $bmDetail

    $serialOpen = [bool]$Record.hri_serial_open
    $hriReady = [bool]$Record.hri_ready
    $yReady = [bool]$Record.hri_y_zero_ready
    if ($hriReady -and $yReady) { Set-MainText -Name 'RadioValue' -Text 'HRI 就绪' }
    elseif ($serialOpen) { Set-MainText -Name 'RadioValue' -Text 'HRI 连接中' }
    else { Set-MainText -Name 'RadioValue' -Text 'HRI 未连接' }
    $hriSummary = if ($hriReady -and $yReady) { 'ready' } elseif ($serialOpen) { 'serial_open' } else { 'closed' }
    if ($script:lastUiHriState -cne $hriSummary) {
        switch -CaseSensitive ($hriSummary) {
            'ready' { Add-UiEvent 'HRI 与电台音频接口已就绪' }
            'serial_open' { Add-UiEvent 'HRI 串口已打开，等待设备就绪' }
            'closed' { Add-UiEvent 'HRI 串口已关闭' }
        }
        $script:lastUiHriState = $hriSummary
    }
    Set-MainText -Name 'RadioDetail' -Text ('串口：{0} · HRI：{1} · 电台音频：{2}' -f `
        $(if ($serialOpen) { '已打开' } else { '未打开' }),
        $(if ($hriReady) { '就绪' } else { '未就绪' }),
        $(if ($yReady) { '已确认' } else { '未确认' }))
    Set-MainText -Name 'RadioStateValue' -Text ''

    $waveIn = [string]$Record.wavein_state
    $waveOut = [string]$Record.waveout_state
    if ([bool]$Record.audio_endpoints_validated) {
        if ($waveIn -ceq 'open' -and $waveOut -ceq 'open') { Set-MainText -Name 'AudioValue' -Text '双向流已打开' }
        elseif ($waveIn -ceq 'open' -or $waveOut -ceq 'open') { Set-MainText -Name 'AudioValue' -Text '单路流已打开' }
        else { Set-MainText -Name 'AudioValue' -Text '端点已核验' }
    } else { Set-MainText -Name 'AudioValue' -Text '' }
    Set-MainText -Name 'AudioDetail' -Text ''
    Update-UiPlaybackGainDisplay -Record $Record
    Update-UiReceiveMetricsDisplay -Record $Record

    $hasCurrentCallFields = $null -ne $Record.PSObject.Properties['current_call_valid']
    if (-not $hasCurrentCallFields) {
        Set-UiIdentityRowVisibility -Row 'current' -Visibility ([System.Windows.Visibility]::Collapsed)
        Set-MainText -Name 'CurrentCallValue' -Text ''
        Set-MainText -Name 'CurrentCallDetail' -Text ''
    } elseif ([bool]$Record.current_call_valid) {
        Set-UiIdentityRowVisibility -Row 'current'
        $callerId = [uint64]$Record.current_call_source_id
        $caller = Format-UiRadioIdentity -RadioId $callerId
        $kind = if ([string]$Record.current_call_kind -ceq 'P') { '私呼' } else { '组呼' }
        $callDetails = [System.Collections.Generic.List[string]]::new()
        $destination = [uint64]$Record.current_call_destination_id
        if ([string]$Record.current_call_kind -ceq 'P') {
            $callDetails.Add($(if ($destination -gt 0) { '私呼 {0}' -f $destination } else { '私呼' }))
        } else {
            $callDetails.Add($(if ($destination -gt 0) { 'TG {0}' -f $destination } else { '组呼' }))
        }
        if ([uint64]$Record.current_call_slot -in @(1,2)) { $callDetails.Add(('TS{0}' -f $Record.current_call_slot)) }
        Set-MainText -Name 'CurrentCallValue' -Text $caller
        Set-MainText -Name 'CurrentCallDetail' -Text ($callDetails -join ' · ')
    } elseif ([string]$Record.receive_media_state -ceq 'draining') {
        Set-UiIdentityRowVisibility -Row 'current' -Visibility ([System.Windows.Visibility]::Collapsed)
        Set-MainText -Name 'CurrentCallValue' -Text ''
        Set-MainText -Name 'CurrentCallDetail' -Text ''
    } else {
        Set-UiIdentityRowVisibility -Row 'current' -Visibility ([System.Windows.Visibility]::Collapsed)
        Set-MainText -Name 'CurrentCallValue' -Text ''
        Set-MainText -Name 'CurrentCallDetail' -Text ''
    }
    Add-UiCallHistoryRecord -Record $Record
    Update-UiIdentityActionState
    $identityProperty = $Record.PSObject.Properties['lcd_source_identity']
    $identityDisplay = if ($null -eq $identityProperty) {
        Get-UiSourceIdentityDisplay -IdentityPresent $false
    } else {
        Get-UiSourceIdentityDisplay -Identity $identityProperty.Value
    }
    Set-MainText -Name 'HriSourceIdentityValue' -Text $identityDisplay.value
    Set-MainText -Name 'RadioDisplayValue' -Text $identityDisplay.radio_display

    $historyList = $null
    if ($script:mainWindow) { $historyList = $script:mainWindow.FindName('CallHistoryList') }
    if ([bool]$Record.last_rx_header_valid -and $historyList -and $historyList.Items.Count -eq 0) {
        Set-UiIdentityRowVisibility -Row 'recent'
        $caller = Format-UiRadioIdentity -RadioId ([uint64]$Record.last_rx_source_id)
        Set-MainText -Name 'RecentCaller' -Text $caller
        Set-MainText -Name 'RecentCallDetail' -Text ('最近来话 · 目标 {0} · TS{1} · {2}' -f `
            $Record.last_rx_destination_id, $Record.last_rx_slot, $Record.last_rx_call_kind)
    } else {
        Set-UiIdentityRowVisibility -Row 'recent' -Visibility ([System.Windows.Visibility]::Collapsed)
    }
    Set-MainText -Name 'TrafficValue' -Text $script:activeTargetLabel
    Set-MainText -Name 'TrafficDetail' -Text '当前连接使用运行会话中显示的目标。'
    Set-MainText -Name 'RunValue' -Text '运行中'
    Set-MainText -Name 'FreshnessValue' -Text ('状态更新于 {0}' -f [DateTime]::Now.ToString('HH:mm:ss'))
    $visibleEvent = Get-VisibleUiEventText -EventName ([string]$Record.event)
    if ($visibleEvent) { Add-UiEvent $visibleEvent }
    Update-DynamicGroupControls
}

function Read-StatusUpdates {
    if (-not $script:statusPath -or -not [System.IO.File]::Exists($script:statusPath)) { return }
    try {
        if ($null -eq $script:statusStream) {
            $script:statusStream = [System.IO.File]::Open($script:statusPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        }
        if ($script:statusStream.Length -lt $script:statusOffset) {
            $script:statusStream.Position = 0
            $script:statusOffset = 0
            $script:partialStatusLine = ''
        }
        $script:statusStream.Position = $script:statusOffset
        $remaining = [Math]::Min([int64]65536, $script:statusStream.Length - $script:statusOffset)
        if ($remaining -le 0) { return }
        $buffer = New-Object byte[] ([int]$remaining)
        $read = $script:statusStream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return }
        $script:statusOffset += $read
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $combined = $script:partialStatusLine + $text
        $lines = $combined.Split([char]10)
        if ($lines.Count -gt 0) { $script:partialStatusLine = [string]$lines[$lines.Count - 1] }
        if ($script:partialStatusLine.Length -gt 65536) { $script:partialStatusLine = ''; Add-UiEvent '状态行超过大小限制，已跳过' }
        for ($index = 0; $index -lt ($lines.Count - 1); $index++) {
            $line = ([string]$lines[$index]).TrimEnd([char]13)
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 65536) { continue }
            try { $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop }
            catch { continue }
            Apply-StatusRecord -Record $record
        }
    } catch {
        Add-UiEvent '读取运行状态失败'
    }
}

function Set-StaleDisplay {
    if ($script:lastStatusUtc -eq [DateTime]::MinValue) { return }
    if (([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3) { return }
    Set-MainText -Name 'CoreValue' -Text '状态过期'
    Set-MainText -Name 'CoreDetail' -Text ''
    Set-MainText -Name 'RadioValue' -Text ''
    Set-MainText -Name 'RadioDetail' -Text ''
    Set-MainText -Name 'AudioValue' -Text ''
    Set-MainText -Name 'AudioDetail' -Text ''
    Update-UiPlaybackGainDisplay -Record $null
    Set-MainText -Name 'BmValue' -Text ''
    Set-MainText -Name 'BmDetail' -Text ''
    Set-MainText -Name 'TrafficValue' -Text ''
    Set-MainText -Name 'TrafficDetail' -Text ''
    Set-MainText -Name 'RadioStateValue' -Text ''
    Set-MainText -Name 'CurrentCallValue' -Text ''
    Set-MainText -Name 'CurrentCallDetail' -Text ''
    Set-MainText -Name 'RecentCaller' -Text ''
    Set-MainText -Name 'RecentCallDetail' -Text ''
    Set-UiIdentityRowVisibility -Row 'current' -Visibility ([System.Windows.Visibility]::Collapsed)
    Set-UiIdentityRowVisibility -Row 'recent' -Visibility ([System.Windows.Visibility]::Collapsed)
    Set-MainText -Name 'HriSourceIdentityValue' -Text ''
    Set-MainText -Name 'RadioDisplayValue' -Text ''
    Set-MainText -Name 'FreshnessValue' -Text ''
    Update-UiReceiveMetricsDisplay -Record $null
    Update-DynamicGroupControls
    Update-UiIdentityActionState
}

function Request-StopAndExit {
    Clear-UiIdentityQueryQueue
    $script:closingAfterStop = $true
    $script:reconnectAfterStop = $false
    if ($script:identityQuery -and -not $script:identityQuery.stop_async) {
        $script:closingAfterIdentityQuery = $true
        Stop-UiIdentityQuery -Query $script:identityQuery -Reason 'stop_and_exit'
    }
    if ($script:stopTask) { return }
    if ($script:preparePowerShell -and $script:preparationStarted) {
        Begin-PreparationStop
        if (-not $script:preparationStarted -or $script:allowWindowClose) { return }
        Set-MainText -Name 'FooterText' -Text '正在取消设备检查并退出。'
        Set-ConnectionButtonState
        return
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        (Get-UiControl 'StopButton').IsEnabled = $false
        Set-MainText -Name 'FooterText' -Text ''
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-ConnectionButtonState
        return
    }
    $script:allowWindowClose = $true
    $script:mainWindow.Close()
}

function Request-Reconnect {
    if ($script:closingAfterStop -or $script:stopTask -or $script:prepareStopAsync) { return }
    if ($script:preparationStarted -and $script:preparePowerShell) {
        $script:reconnectAfterStop = $true
        Begin-PreparationStop
        if (-not $script:preparationStarted) { return }
        Set-MainText -Name 'FooterText' -Text '正在取消当前设备检查并使用所选目标重新连接。'
        Set-ConnectionButtonState
        return
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        $script:reconnectAfterStop = $true
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-MainText -Name 'CoreValue' -Text '正在停止当前连接'
        Set-MainText -Name 'CoreDetail' -Text '设备关闭后将使用所选目标重新连接。'
        Set-MainText -Name 'FooterText' -Text '正在切换连接目标。'
        Set-ConnectionButtonState
        return
    }
    Start-BridgeRun
}

function Complete-PreparedPipelineWithoutLaunch {
    try { if ($script:preparePowerShell -and $script:prepareAsync) { [void]$script:preparePowerShell.EndInvoke($script:prepareAsync) } }
    catch { Add-UiEvent '设备检查已取消' }
    finally {
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        $script:prepareStopAsync = $null
        $script:preparationStarted = $false
        $script:prepareStopStartedUtc = [DateTime]::MinValue
    }
    if ($script:closingAfterStop) {
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
    } elseif ($script:reconnectAfterStop) {
        $script:reconnectAfterStop = $false
        Start-BridgeRun
    }
}

function Begin-PreparationStop {
    if (-not $script:preparePowerShell -or -not $script:preparationStarted) { return }
    if ($script:prepareStopAsync) { return }
    if ($script:prepareAsync -and $script:prepareAsync.IsCompleted) {
        Complete-PreparedPipelineWithoutLaunch
        return
    }
    $script:prepareStopStartedUtc = [DateTime]::UtcNow
    try {
        $script:prepareStopAsync = $script:preparePowerShell.BeginStop($null, $null)
    } catch {
        if ($script:prepareAsync -and $script:prepareAsync.IsCompleted) {
            Complete-PreparedPipelineWithoutLaunch
            return
        }
        throw
    }
}

function Complete-PreparationStop {
    if (-not $script:prepareStopAsync -or -not $script:prepareStopAsync.IsCompleted) {
        if ($script:prepareStopAsync -and
            ([DateTime]::UtcNow - $script:prepareStopStartedUtc).TotalSeconds -ge 5) {
            Add-UiEvent '设备检查停止超时，正在关闭界面'
            $script:abandonPreparationAtShutdown = $true
            $script:allowWindowClose = $true
            $script:mainWindow.Close()
            [System.Environment]::Exit(2)
        }
        return
    }
    $wasClosing = $script:closingAfterStop
    $wasReconnect = $script:reconnectAfterStop
    try { $script:preparePowerShell.EndStop($script:prepareStopAsync) }
    catch { Add-UiEvent '设备检查已取消' }
    finally {
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        $script:prepareStopAsync = $null
        $script:preparationStarted = $false
        $script:prepareStopStartedUtc = [DateTime]::MinValue
    }
    if ($wasClosing) {
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return
    }
    if ($wasReconnect) {
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        Start-BridgeRun
    }
}

function Complete-BridgeStop {
    if (-not $script:stopTask -or -not $script:stopTask.IsCompleted) { return $false }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        Set-MainText -Name 'CoreValue' -Text '停止未完成'
        Set-MainText -Name 'CoreDetail' -Text '核心仍在运行；请再次选择停止并退出。'
        Set-MainText -Name 'FooterText' -Text '桥接核心尚未退出。'
        $script:stopTask = $null
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        (Get-UiControl 'StopButton').IsEnabled = $true
        Set-ConnectionButtonState
        return $true
    }
    if ($script:supervisor) { $script:supervisor.Dispose(); $script:supervisor = $null }
    if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
    $script:stopTask = $null
    if ($script:closingAfterStop) {
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return $true
    }
    if ($script:reconnectAfterStop) {
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        $script:activeTargetLabel = ''
        $script:activeTargetTag = ''
        $script:activeProfile = $null
        $script:lastUiBmState = ''
        $script:lastUiHriState = ''
        Set-OfflineDisplay -Reason '当前连接已停止，正在连接所选目标。'
        Start-BridgeRun
        return $true
    }
    return $true
}

function On-UiTimerTick {
    try { Complete-UiIdentityQuery }
    catch {
        Add-UiIdentityDiagnostic -Stage 'dispatcher' -ErrorCode 'query_contract' `
            -ErrorType $_.Exception.GetType().FullName -Detail $_.Exception.Message
        if ($script:identityQuery) {
            try { Stop-UiIdentityQuery -Query $script:identityQuery -Reason 'dispatcher_error' } catch { }
        }
    }
    if ($script:prepareStopAsync) { Complete-PreparationStop; return }
    Complete-UiDeviceDiscovery
    Complete-BridgePreparation
    if (Complete-BridgeStop) { return }
    if ($script:supervisor) {
        if ($script:supervisor.HasExited) {
            Reset-UiControlState -Text '控制协议：本次进程已退出'
            $exitCode = -1
            [void]$script:supervisor.TryGetExitCode([ref]$exitCode)
            Set-MainText -Name 'CoreValue' -Text '已停止'
            Set-MainText -Name 'CoreDetail' -Text ('核心进程已退出，退出码 {0}' -f $exitCode)
            Set-MainText -Name 'RadioValue' -Text ''
            Set-MainText -Name 'RadioDetail' -Text ''
            Set-MainText -Name 'AudioValue' -Text ''
            Set-MainText -Name 'AudioDetail' -Text ''
            Update-UiPlaybackGainDisplay -Record $null
            Set-MainText -Name 'BmValue' -Text ''
            Set-MainText -Name 'BmDetail' -Text ''
            Set-MainText -Name 'RadioStateValue' -Text ''
            Set-MainText -Name 'CurrentCallValue' -Text ''
            Set-MainText -Name 'CurrentCallDetail' -Text ''
            Set-UiIdentityRowVisibility -Row 'current' -Visibility ([System.Windows.Visibility]::Collapsed)
            Set-UiIdentityRowVisibility -Row 'recent' -Visibility ([System.Windows.Visibility]::Collapsed)
            Update-UiReceiveMetricsDisplay -Record $null
            Update-UiIdentityActionState
            $identityDisplay = Get-UiSourceIdentityDisplay -State 'exited'
            Set-MainText -Name 'HriSourceIdentityValue' -Text $identityDisplay.value
            Set-MainText -Name 'RadioDisplayValue' -Text $identityDisplay.radio_display
            Set-MainText -Name 'RunValue' -Text '已停止'
            Set-MainText -Name 'FreshnessValue' -Text '本次运行已结束'
            if (-not $script:stopTask) {
                $script:activeTargetLabel = ''
                $script:activeTargetTag = ''
                $script:activeProfile = $null
                $script:lastUiBmState = ''
                $script:lastUiHriState = ''
                $selectedProfile = if ($script:storedProfile) { Get-UiCallTargetSummaryProfile -Profile $script:storedProfile `
                    -Preset (Get-SelectedTargetTag) -PendingTarget $script:pendingCallTarget } else { $null }
                Set-MainTargetSummary -Profile $selectedProfile -OverallLabel $script:targetLabel
                Set-MainText -Name 'TrafficDetail' -Text '连接已停止；可按所选目标重新连接。'
                Set-ConnectionButtonState
            }
            if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
        } else {
            Process-UiControlEvents
            if ($script:pendingQuickCall -and -not [bool]$script:pendingQuickCall.timed_out -and
                ([DateTime]::UtcNow - [DateTime]$script:pendingQuickCall.started_utc).TotalSeconds -ge 8) {
                $script:pendingQuickCall.timed_out = $true
                Set-DynamicGroupStatus '尚未收到激活结果；请检查连接，结果确认后再操作。' -Failed $true
                Add-UiEvent '动态组激活等待超时；保留原 request_id，没有自动重发'
            }
            if ($script:pendingRoutingMutation -and
                ([DateTime]::UtcNow - [DateTime]$script:pendingRoutingMutation.started_utc).TotalSeconds -ge 8) {
                $timedOutMutation = $script:pendingRoutingMutation
                $script:timedOutRoutingMutations[[string]$timedOutMutation.request_id] = $timedOutMutation
                $script:pendingRoutingMutation = $null
                $script:routingMutationFence = $true
                Set-RoutingMutationPendingState -Pending $false
                Set-RoutingEditorStatus -Text '等待应用设置超时；正在刷新当前运行设置，不会自动重发。未确认的草稿已保留。' -Failed $true
                Set-UiControlStatus -Text '等待设置超时，正在刷新当前状态' -Confirmed $false
                Add-UiEvent '路由设置等待超时；未自动重发'
                if ($timedOutMutation.command -ceq 'tx_policy.replace') {
                    Set-MainText -Name 'CallTargetStatusValue' -Text '核心确认等待超时；当前确认目标和活动通话保持原状。正在刷新当前策略。'
                    if ($script:pendingDynamicCallTarget -and [uint64]$script:pendingDynamicCallTarget.destination_id -eq [uint64]$timedOutMutation.target.destination_id -and [uint64]$script:pendingDynamicCallTarget.slot -eq [uint64]$timedOutMutation.target.slot) {
                        Set-DynamicGroupStatus '起呼目标请求等待超时；没有发起呼叫。正在刷新核心策略。' -Failed $true
                        $script:pendingDynamicCallTarget = $null
                    }
                }
                Request-UiRoutingStatus
            }
            Read-StatusUpdates
            Set-StaleDisplay
        }
    }
}

function Save-RenderedWindow {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window, [Parameter(Mandatory=$true)][string]$Path)
    $Window.UpdateLayout()
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $Window.UpdateLayout()
    $width = [Math]::Max(1, [int][Math]::Ceiling($Window.ActualWidth))
    $height = [Math]::Max(1, [int][Math]::Ceiling($Window.ActualHeight))
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Get-UiVisualTextValues {
    param([Parameter(Mandatory=$true)][System.Windows.DependencyObject]$Root)
    $values = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if ($current -is [System.Windows.Controls.ContentPresenter] -and $current.Content -is [string] -and
            -not [string]::IsNullOrWhiteSpace($current.Content)) {
            $values.Add([string]$current.Content)
        }
        if ($current -is [System.Windows.Controls.TextBlock] -and -not [string]::IsNullOrWhiteSpace($current.Text)) {
            $values.Add([string]$current.Text)
        }
        if ($current -is [System.Windows.Controls.AccessText] -and -not [string]::IsNullOrWhiteSpace($current.Text)) {
            $values.Add([string]$current.Text)
        }
        if ($current -is [System.Windows.Media.Visual] -or $current -is [System.Windows.Media.Media3D.Visual3D]) {
            $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($current)
            for ($index = 0; $index -lt $childCount; $index++) {
                $child = [System.Windows.Media.VisualTreeHelper]::GetChild($current, $index)
                if ($child -is [System.Windows.DependencyObject]) { $pending.Push($child) }
            }
        }
    }
    return @($values | Select-Object -Unique)
}

function Get-UiComboRenderEvidence {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    [void]$Combo.ApplyTemplate()
    [void]$Combo.UpdateLayout()
    $selectedContainer = $Combo.SelectedItem
    if ($selectedContainer -isnot [System.Windows.Controls.ComboBoxItem] -or $selectedContainer.Content -isnot [string]) {
        throw ('{0} 的选中项没有显示纯文本标签。' -f $Combo.Name)
    }
    $expectedLabel = [string]$selectedContainer.Content
    $selectedMetadata = $selectedContainer.Tag
    if ($null -eq $selectedMetadata -or $selectedMetadata.Label -isnot [string] -or
        $selectedMetadata.Value -isnot [string] -or $selectedMetadata.IsAvailable -isnot [bool] -or
        $selectedMetadata.Label -cne $expectedLabel) {
        throw ('{0} 的选中项没有保留独立的稳定值元数据。' -f $Combo.Name)
    }
    $selectionPresenter = $Combo.Template.FindName('PART_SelectionBoxItem', $Combo)
    if ($selectionPresenter -isnot [System.Windows.Controls.ContentPresenter]) {
        throw ('{0} 的模板缺少选中项文本显示区域。' -f $Combo.Name)
    }
    $selectedTexts = @(Get-UiVisualTextValues -Root $selectionPresenter)
    if (-not ($selectedTexts -ccontains $expectedLabel)) {
        throw ('{0} 选中框视觉树没有显示设备标签。' -f $Combo.Name)
    }

    [void]$Combo.SetCurrentValue([System.Windows.Controls.ComboBox]::IsDropDownOpenProperty, $true)
    [void]$Combo.UpdateLayout()
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $popup = $Combo.Template.FindName('PART_Popup', $Combo)
    if ($null -eq $popup -or $null -eq $popup.Child) { throw ('{0} 下拉列表没有创建视觉树。' -f $Combo.Name) }
    $dropDownTexts = @(Get-UiVisualTextValues -Root $popup.Child)
    foreach ($container in $Combo.Items) {
        if ($container -isnot [System.Windows.Controls.ComboBoxItem] -or $container.Content -isnot [string] -or
            -not ($dropDownTexts -ccontains [string]$container.Content) -or $null -eq $container.Tag -or
            $container.Tag.Label -cne [string]$container.Content) {
            throw ('{0} 下拉项视觉树没有显示纯文本标签。' -f $Combo.Name)
        }
    }
    [void]$Combo.SetCurrentValue([System.Windows.Controls.ComboBox]::IsDropDownOpenProperty, $false)
    [void]$Combo.UpdateLayout()
    $metadataText = @($selectedTexts + $dropDownTexts | Where-Object { $_ -match '@\{(Label|Value|IsAvailable|Kind)=' })
    if ($metadataText.Count -gt 0) { throw ('{0} 视觉树泄漏了 PowerShell 对象元数据。' -f $Combo.Name) }
    return [pscustomobject]@{
        expected_label = $expectedLabel
        stable_value = [string]$selectedMetadata.Value
        available = [bool]$selectedMetadata.IsAvailable
        selected_text = $selectedTexts
        dropdown_text = $dropDownTexts
    }
}

$script:mainWindow = Import-WpfWindow -Path $script:mainXamlPath
Fit-WpfWindowToWorkArea -Window $script:mainWindow
$script:application.MainWindow = $script:mainWindow
try {
    $startupAudio = Read-BridgeAudioSettings -Path $script:audioSettingsPath
    if ($startupAudio) { $script:savedPlaybackGainMilli = [uint32]$startupAudio.RadioPlaybackGainMilli }
} catch { $script:savedPlaybackGainMilli = $null }
try { $script:channelFavorites = @(Read-UiChannelFavorites) }
catch { $script:channelFavoritesLoadError = '本机收藏文件读取失败；原文件已保留，收藏操作已停用。' }
if ($RenderOnly -or $OfflinePreview) { $script:storedProfile = $null }
else {
    try { $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath }
    catch { $script:storedProfile = $null; $startupProfileError = $true }
}
Set-OfflineDisplay
$script:startupNeedsSettings = ($null -eq $script:storedProfile)
if ($script:storedProfile) {
    Set-MainTargetSummary -Profile $script:storedProfile -OverallLabel (Format-ProfileTarget -Profile $script:storedProfile)
} elseif ($startupProfileError) {
    Set-MainText -Name 'FooterText' -Text '连接设置读取失败'
}
$script:mainWindow.FindName('OfflineBanner').Visibility = [Windows.Visibility]::Collapsed
(Get-UiControl 'SettingsButton').Add_Click({ Show-SettingsWindow })
(Get-UiControl 'VolumeSettingsButton').Add_Click({ Show-SettingsWindow -ScrollToVolume })
(Get-UiControl 'ConnectButton').Add_Click({ Request-Reconnect })
(Get-UiControl 'StopButton').Add_Click({ Request-StopAndExit })
(Get-UiControl 'ControlStatusButton').Add_Click({ Request-UiControlStatus })
(Get-UiControl 'DynamicGroupIdBox').Add_TextChanged({ Update-DynamicGroupControls })
(Get-UiControl 'DynamicGroupSlotBox').Add_SelectionChanged({ Update-DynamicGroupControls })
(Get-UiControl 'SetDynamicCallTargetButton').Add_Click({ Invoke-UiSetDynamicCallTarget })
(Get-UiControl 'AddListenGroupButton').Add_Click({ Invoke-UiDynamicGroupLocalListen })
(Get-UiControl 'ActivateDynamicGroupButton').Add_Click({ Invoke-UiDynamicGroupQuickCall })
(Get-UiControl 'BlockCurrentSourceButton').Add_Click({
    if (-not $script:latestStatus -or -not [bool]$script:latestStatus.current_call_valid -or -not $script:activeRouting) { return }
    $call = $script:latestStatus
    $source = [pscustomobject]@{ source_id=[uint64]$call.current_call_source_id; destination_id=[uint64]$call.current_call_destination_id; slot=[uint64]$call.current_call_slot; kind=$(if ([string]$call.current_call_kind -ceq 'P') { 'private' } else { 'group' }) }
    Invoke-ObservedRoutingAction -Action 'block' -Source $source
})
(Get-UiControl 'CallHistoryList').Add_SelectionChanged({ Update-UiCallHistoryActionState })
(Get-UiControl 'CallFavoritesList').Add_SelectionChanged({ if (-not $script:updatingChannelFavorites) { Set-UiChannelFavoriteActionState } })
(Get-UiControl 'FavoriteCurrentTargetButton').Add_Click({
    try {
        $target = Get-UiCurrentCallTarget
        if (-not $target) { throw '当前没有可收藏的起呼目标。' }
        Add-UiChannelFavorite -Target $target
    } catch { Set-MainText -Name 'ChannelFavoritesStatusValue' -Text $_.Exception.Message }
})
(Get-UiControl 'FavoriteManualGroupButton').Add_Click({
    try {
        $route = Read-DynamicGroupInput
        $target = [pscustomobject][ordered]@{ destination_id=[uint64]$route.destination_id; kind='group'; slot=[uint64]$route.slot }
        Add-UiChannelFavorite -Target $target
    } catch { Set-MainText -Name 'ChannelFavoritesStatusValue' -Text $_.Exception.Message }
})
(Get-UiControl 'ApplyCallFavoriteButton').Add_Click({
    $favorite = (Get-UiControl 'CallFavoritesList').SelectedItem
    if (-not $favorite) { return }
    $categoryLabel = switch -CaseSensitive ([string]$favorite.category) { 'static' { '本机静态收藏' } 'dynamic' { '本机动态收藏' } default { '本机普通收藏' } }
    $target = [pscustomobject][ordered]@{ destination_id=[uint64]$favorite.destination_id; kind=[string]$favorite.kind; slot=[uint64]$favorite.slot }
    try { Invoke-UiSetCallTarget -Target $target -Description ($categoryLabel + ' · ' + [string]$favorite.label) }
    catch { Set-MainText -Name 'CallTargetStatusValue' -Text $_.Exception.Message }
})
(Get-UiControl 'RemoveCallFavoriteButton').Add_Click({
    try { Remove-UiChannelFavorite }
    catch { Set-MainText -Name 'ChannelFavoritesStatusValue' -Text $_.Exception.Message }
})
(Get-UiControl 'QueryCurrentIdentityButton').Add_Click({
    try {
        $call = $script:latestStatus
        if (-not $call -or -not [bool]$call.current_call_valid) { throw '当前没有有效来话来源可查询。' }
        $generation = if ($call.PSObject.Properties['current_call_generation']) { [uint64]$call.current_call_generation } else { [uint64]0 }
        Start-UiIdentityQuery -RadioId ([uint64]$call.current_call_source_id) -ContextKind current -RunId ([string]$call.run_id) -Generation $generation
    } catch { Set-UiIdentityError -ErrorCode 'user_action' -Message $_.Exception.Message `
        -Detail $_.Exception.Message -Stage 'manual_query' -ShowToUser }
})
(Get-UiControl 'QueryHistoryIdentityButton').Add_Click({
    try {
        $entry = (Get-UiControl 'CallHistoryList').SelectedItem
        if (-not $entry) { throw '请选择一条来话历史。' }
        Start-UiIdentityQuery -RadioId ([uint64]$entry.source_id) -ContextKind history -RunId ([string]$entry.run_id) -Generation ([uint64]$entry.generation) -HistoryKey ([string]$entry.key)
    } catch { Set-UiIdentityError -ErrorCode 'user_action' -Message $_.Exception.Message `
        -Detail $_.Exception.Message -Stage 'manual_query' -ShowToUser }
})
(Get-UiControl 'SetHistoryCallTargetButton').Add_Click({
    $entry = (Get-UiControl 'CallHistoryList').SelectedItem
    if (-not $entry) { return }
    try {
        $target = New-UiCallTargetFromHistoryEntry -Entry $entry
        Invoke-UiSetCallTarget -Target $target -Description ('来话历史 DMR ID ' + $entry.source_id)
    }
    catch { Set-MainText -Name 'CallTargetStatusValue' -Text $_.Exception.Message }
})
(Get-UiControl 'TargetSelector').Add_SelectionChanged({
    if ($script:loadingCallTargetSelection) { return }
    $selectedTarget = Get-SelectedTargetTag
    try {
        if (-not $script:storedProfile -and [System.IO.File]::Exists($script:profilePath)) {
            $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        }
        $profile = if ($script:activeProfile) { $script:activeProfile } else { $script:storedProfile }
        if ($selectedTarget -ceq 'custom') {
            $script:pendingCallTarget = $null
            $target = if ($script:activeRouting) { $script:activeRouting.tx_target } elseif ($profile) { $profile.tx_target } else { $null }
        } else {
            $target = New-UiCallTargetFromPreset -Preset $selectedTarget -Profile $profile
        }
        if (-not $target) {
            Set-MainText -Name 'CallTargetStatusValue' -Text '请先在设置中保存连接和呼叫目标。'
            Set-UiCallTargetSelector -Target $(if ($script:activeRouting) { $script:activeRouting.tx_target } elseif ($profile) { $profile.tx_target } else { $null })
            return
        }
        Invoke-UiSetCallTarget -Target $target -Description $selectedTarget
    } catch {
        Set-MainText -Name 'CallTargetStatusValue' -Text $_.Exception.Message
        if ($script:activeRouting) { Set-UiCallTargetSelector -Target $script:activeRouting.tx_target }
        elseif ($script:pendingCallTarget) { Set-UiCallTargetSelector -Target $script:pendingCallTarget }
        elseif ($script:storedProfile) { Set-UiCallTargetSelector -Target $script:storedProfile.tx_target }
    }
    Set-ConnectionButtonState
})
$script:mainWindow.Add_Closing({
    param($sender, $eventArgs)
    if ($script:allowWindowClose -and -not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery -and -not $script:identityQuery) { return }
    if ($script:identityQuery) {
        $eventArgs.Cancel = $true
        $script:closingAfterIdentityQuery = $true
        if (-not $script:identityQuery.stop_async) { Stop-UiIdentityQuery -Query $script:identityQuery -Reason 'window_closed' }
        if (($script:supervisor -and -not $script:supervisor.HasExited) -or $script:preparationStarted) { Request-StopAndExit }
        return
    }
    if (($script:supervisor -and -not $script:supervisor.HasExited) -or $script:preparationStarted) {
        $eventArgs.Cancel = $true
        Request-StopAndExit
        return
    }
    if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) {
        $eventArgs.Cancel = $true
        $script:closingAfterDeviceDiscovery = $true
        $script:deviceDiscoveryGeneration++
        $script:deviceDiscoveryRestartPending = $false
        $script:deviceDiscoveryStopReason = 'shutdown'
        $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
        if ($script:deviceAudioQuery) {
            try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
            catch { $script:deviceDiscoveryError = $_.Exception.Message }
        }
        if ($script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted -and -not $script:deviceDiscoveryStopAsync) {
            try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) }
            catch {
                if ($script:deviceDiscoveryAsync.IsCompleted) { Complete-UiDeviceDiscovery }
                else { [System.Environment]::Exit(2) }
            }
        } else {
            Complete-UiDeviceDiscovery
        }
    }
})
$script:mainWindow.Add_Loaded({
    if ($OfflinePreview -or $NoAutoConnect) {
        $banner = Get-UiControl 'OfflineBanner'
        $banner.Visibility = [Windows.Visibility]::Visible
        (Get-UiControl 'OfflineBannerText').Text = if ($RenderOnly) { '离线渲染样例：以下接收路由与观察来源是模拟数据；没有连接设备或网络。' } elseif ($OfflinePreview) { '离线预览：没有连接设备或网络。' } else { '连接已关闭：当前窗口未启动核心。' }
        Set-OfflineDisplay -Reason '当前窗口没有连接核心。'
        Set-MainText -Name 'FooterText' -Text '打开设置可查看本机配置；此窗口没有启动设备或网络连接。'
        (Get-UiControl 'ConnectButton').IsEnabled = $false
        return
    }
    try {
        $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if ($script:storedProfile) {
            Set-MainText -Name 'TargetValue' -Text (Format-ProfileTarget -Profile $script:storedProfile)
            if ($RoutingDiagnosticAutoTest) {
                Initialize-SettingsWindow
                $beforeCancelHash = (Get-FileHash -LiteralPath $script:profilePath -Algorithm SHA256).Hash
                (Get-SettingsControl 'DestinationBox').Text = '44444'
                Raise-UiButtonClick -ControlName 'CancelSettingsButton'
                $afterCancelHash = (Get-FileHash -LiteralPath $script:profilePath -Algorithm SHA256).Hash
                if ($beforeCancelHash -cne $afterCancelHash -or
                    [uint64]$script:editTxTarget.destination_id -ne [uint64]$script:storedProfile.tx_target.destination_id) {
                    throw '离线编辑后取消没有丢弃草稿，或改写了本机配置。'
                }
                $script:routingDiagnosticOfflineCancelVerified = $true
            }
            Start-BridgeRun
        } else {
            $script:startupNeedsSettings = $true
            Set-MainText -Name 'FooterText' -Text '请打开设置填写本机连接参数。'
            Show-SettingsWindow
        }
    } catch {
        Set-OfflineDisplay -Reason ('配置需要修正：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置检查并保存连接参数。'
        Show-SettingsWindow
    }
})

$script:uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:uiTimer.Add_Tick({ On-UiTimerTick })
$script:uiTimer.Start()

if ($RenderOnly) {
    if (-not $RenderOutputDirectory) { throw '-RenderOnly 需要 -RenderOutputDirectory。' }
    $renderDirectory = [System.IO.Path]::GetFullPath($RenderOutputDirectory)
    [System.IO.Directory]::CreateDirectory($renderDirectory) | Out-Null
    $banner = Get-UiControl 'OfflineBanner'
    $banner.Visibility = [Windows.Visibility]::Visible
    (Get-UiControl 'OfflineBannerText').Text = '离线预览样例：以下接收路由与观察来源是模拟数据；没有连接设备或网络。'
    Set-OfflineDisplay -Reason '离线预览，没有连接设备。'
    (Get-UiControl 'DynamicGroupIdBox').Text = '91'
    (Get-UiControl 'DynamicGroupSlotBox').SelectedIndex = 1
    Update-DynamicGroupControls
    $script:savedPlaybackGainMilli = [uint32]5959
    Update-UiPlaybackGainDisplay -Record $null
    $script:mainWindow.Show()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $renderDirectory 'main-window.png')
    Initialize-SettingsWindow
    $serialFixture = New-UiDeviceOption -Label '离线样例 · HRI (COM5)' -Value 'COM5' -IsAvailable $true -Kind 'serial'
    $inputFixture = New-UiDeviceOption -Label '离线样例 · USB Audio 输入' -Value '{render-input}' -IsAvailable $true -Kind 'input'
    $outputFixture = New-UiDeviceOption -Label '离线样例 · USB Audio 输出' -Value '{render-output}' -IsAvailable $true -Kind 'output'
    Set-UiDeviceComboOptions -Combo (Get-SettingsControl 'SerialBox') -Options @($serialFixture) -SelectedValue 'COM5'
    Set-UiDeviceComboOptions -Combo (Get-SettingsControl 'WaveInEndpointBox') -Options @($inputFixture) -SelectedValue '{render-input}'
    Set-UiDeviceComboOptions -Combo (Get-SettingsControl 'WaveOutEndpointBox') -Options @($outputFixture) -SelectedValue '{render-output}'
    (Get-SettingsControl 'DeviceDiscoveryText').Text = '离线渲染样例；没有读取本机设备。'
    $script:savedPlaybackGainMilli = [uint32]5959
    (Get-SettingsControl 'PlaybackGainSlider').Value = 5.959
    Set-GainValueLabel -SliderName 'PlaybackGainSlider' -LabelName 'PlaybackGainValueText'
    $script:settingsWindow.FindName('SettingsScrollViewer').ScrollToTop()
    $script:settingsWindow.Show()
    $script:settingsWindow.UpdateLayout()
    $deviceComboEvidence = [pscustomobject][ordered]@{
        serial = Get-UiComboRenderEvidence -Combo (Get-SettingsControl 'SerialBox')
        wave_input = Get-UiComboRenderEvidence -Combo (Get-SettingsControl 'WaveInEndpointBox')
        wave_output = Get-UiComboRenderEvidence -Combo (Get-SettingsControl 'WaveOutEndpointBox')
    }
    $settingsScroll = $script:settingsWindow.FindName('SettingsScrollViewer')
    $settingsScroll.ScrollToVerticalOffset(0)
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:settingsWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:settingsWindow -Path (Join-Path $renderDirectory 'settings-window.png')
    $layoutInfo = [pscustomobject][ordered]@{
        render_only = [bool]$RenderOnly
        work_area_width = $script:workAreaWidth
        work_area_height = $script:workAreaHeight
        max_window_width = $script:maxWindowWidth
        max_window_height = $script:maxWindowHeight
        device_combo_rendered_text = $deviceComboEvidence
        main = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('ConnectButton', 'SettingsButton', 'StopButton', 'FooterText', 'TargetSelector', 'ReceiveTargetValue', 'TransmitTargetValue', 'TransmitPermissionValue', 'ActiveLeaseValue', 'PlaybackGainStatusValue', 'ListeningHistoryPanel', 'CallChannelPanel', 'CallTargetStatusValue', 'CallTargetChoicesPanel', 'CallFavoritesList', 'FavoriteCurrentTargetButton', 'FavoriteManualGroupButton', 'ApplyCallFavoriteButton', 'RemoveCallFavoriteButton', 'ChannelFavoritesStatusValue', 'CallHistoryList', 'EventList', 'SetHistoryCallTargetButton', 'QueryCurrentIdentityButton', 'QueryHistoryIdentityButton', 'IdentityLookupStatusValue', 'CoreDetail', 'RadioDetail', 'AudioDetail', 'BmDetail', 'CoreStatusCard', 'RadioStatusCard', 'AudioStatusCard', 'BmStatusCard', 'HriSourceIdentityValue', 'RadioDisplayValue', 'CurrentCallLabel', 'CurrentCallValue', 'CurrentCallDetail', 'BlockCurrentSourceButton', 'TrafficCard', 'DynamicGroupPanel', 'DynamicGroupIdBox', 'DynamicGroupSlotBox', 'SetDynamicCallTargetButton', 'AddListenGroupButton', 'ActivateDynamicGroupButton', 'DynamicGroupStatus')
        main_action_controls = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('ConnectButton','SettingsButton','StopButton','TargetSelector','ListeningHistoryPanel','CallChannelPanel','FavoriteCurrentTargetButton','FavoriteManualGroupButton','ApplyCallFavoriteButton','RemoveCallFavoriteButton','DynamicGroupPanel','DynamicGroupIdBox','DynamicGroupSlotBox','SetDynamicCallTargetButton','AddListenGroupButton','ActivateDynamicGroupButton','VolumeSettingsButton')
        settings = Get-WpfWindowLayoutInfo -Window $script:settingsWindow -ControlNames @('CancelSettingsButton', 'SaveSettingsButton', 'SettingsErrorText', 'ProfileMigrationText', 'ReceivePolicyPreviewText', 'MasterPresetBox', 'PasswordPathBox', 'BrowsePasswordButton', 'DeviceDiscoveryText', 'RefreshDevicesButton', 'SerialBox', 'WaveInEndpointBox', 'WaveOutEndpointBox', 'DestinationBox', 'SlotBox', 'CallKindBox', 'TransmitEnabledBox', 'ApplyNextTxTargetButton', 'GroupModeBox', 'PrivateModeBox', 'GroupRouteIdBox', 'GroupRouteSlotBox', 'GroupRoutesList', 'BlockedGroupIdBox', 'BlockedGroupSlotBox', 'BlockedGroupsList', 'PeerSourceIdBox', 'PeerLocalDestinationBox', 'PeerSlotBox', 'PeerRoutesList', 'LocalPrivateDestinationBox', 'LocalPrivateSlotBox', 'LocalPrivateRoutesList', 'BlockedSourceIdBox', 'BlockedSourcesList', 'PlaybackGainSlider', 'PlaybackGainValueText', 'PlaybackGainSavedValueText', 'PlaybackGainRuntimeValueText', 'TransmitGainSlider', 'TransmitGainValueText')
        settings_action_controls = Get-WpfWindowLayoutInfo -Window $script:settingsWindow -ControlNames @('SaveSettingsButton','CancelSettingsButton','PasswordPathBox','BrowsePasswordButton','MasterPresetBox','DestinationBox','SlotBox','CallKindBox','TransmitEnabledBox','ApplyNextTxTargetButton','GroupModeBox','PrivateModeBox','GroupRouteIdBox','GroupRouteSlotBox','AddGroupRouteButton','RemoveGroupRouteButton','GroupRoutesList','BlockedGroupIdBox','BlockedGroupSlotBox','AddBlockedGroupButton','RemoveBlockedGroupButton','BlockedGroupsList','PeerSourceIdBox','PeerLocalDestinationBox','PeerSlotBox','AddPeerRouteButton','PeerRoutesList','LocalPrivateDestinationBox','LocalPrivateSlotBox','AddLocalPrivateRouteButton','LocalPrivateRoutesList','BlockedSourceIdBox','AddBlockedSourceButton','BlockedSourcesList','PlaybackGainSlider','TransmitGainSlider')
        settings_empty_state = Get-WpfWindowLayoutInfo -Window $script:settingsWindow -ControlNames @('ProfileMigrationText','ReceivePolicyPreviewText','SettingsErrorText','RoutingEditorStatus','DeviceDiscoveryText')
        main_empty_state = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('CoreStatusCard','RadioStatusCard','BmStatusCard','AudioStatusCard','CurrentCallPanel','RecentCallPanel','HistoryPanel','HistoryActionsPanel','CallHistoryList','CallFavoritesList','CallTargetChoicesLabel','CallTargetChoicesScroll','BmRttMetric','BmRttValue','RxNetworkMetric','RxCallLossValue','RxSessionLossValue','PlaybackGainStatusValue','HriSourceIdentityValue','RadioDisplayValue','RadioDetailsExpander','ObservedSourcesCard','ObservedSourcesPanel')
        main_source_identity = [pscustomobject][ordered]@{
            value = (Get-UiControl 'HriSourceIdentityValue').Text
            radio_display = (Get-UiControl 'RadioDisplayValue').Text
            visual_text = @(Get-UiVisualTextValues -Root $script:mainWindow)
        }
        radio_details_expanded = [bool](Get-UiControl 'RadioDetailsExpander').IsExpanded
    }
    [System.IO.File]::WriteAllText((Join-Path $renderDirectory 'layout-info.json'), (ConvertTo-Json -InputObject $layoutInfo -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

    $simulatedConnection = [pscustomobject][ordered]@{
        callsign = 'TEST'; gateway_id = [uint64]1; source_id = [uint64]3149876
        master = '43.129.83.124'; master_port = [uint64]62031; destination_id = [uint64]460997
        slot = [uint64]2; color_code = [uint64]0; call_kind = 'private'
    }
    $simulatedDevices = [pscustomobject][ordered]@{
        serial_port = 'auto'; wave_in_endpoint_id = 'auto'; wave_out_endpoint_id = 'auto'
    }
    $simulatedProfile = ConvertTo-BridgeUserConnectionProfile -Connection $simulatedConnection -Devices $simulatedDevices `
        -Receive ([pscustomobject][ordered]@{ destination_id = [uint64]91; slot = [uint64]2; call_kind = 'group' }) `
        -TransmitEnabled $false
    $renderRxPolicy = [pscustomobject][ordered]@{
        group_mode='selected'; private_mode='all_peers_to_local'
        allow_groups=@([pscustomobject][ordered]@{ destination_id=[uint64]91; slot=[uint64]2 })
        allow_private_peers=@([pscustomobject][ordered]@{ source_id=[uint64]460997; local_destination_id=[uint64]3149876; slot=[uint64]2 })
        local_private_routes=@([pscustomobject][ordered]@{ local_destination_id=[uint64]3149876; slot=[uint64]1 })
        blocked_groups=@([pscustomobject][ordered]@{ destination_id=[uint64]46001; slot=[uint64]2 })
        blocked_source_ids=[uint64[]]@(3149877)
    }
    $simulatedProfile.rx_policy = $renderRxPolicy
    $simulatedEffectiveProfile = New-EffectiveTargetProfile -Profile $simulatedProfile -Target 'listen-91'
    $script:callIdentityCache['3149876'] = [pscustomobject]@{
        source_id=[uint32]3149876; id=[uint32]3149876; callsign='TEST'; name='Simulated Operator'; country='Render Sample'; state='Example State'; city='Example City'
        source='local-cache'; fetched_at_utc='2026-10-28T08:00:00Z'; status='found'; display_name='TEST'
    }
    $script:callIdentityCache['3149877'] = [pscustomobject]@{
        source_id=[uint32]3149877; id=[uint32]3149877; callsign=$null; name=$null; country=$null; state=$null; city=$null
        source='none'; fetched_at_utc=$null; status='unavailable'; display_name='DMR ID 3149877'
    }
    $simulatedEffectiveProfile.rx_policy = Copy-UiRxPolicy -Policy $renderRxPolicy
    Set-MainTargetSummary -Profile $simulatedEffectiveProfile -OverallLabel '离线模拟 · 全球收听 TG91'
    Set-MainText -Name 'TrafficValue' -Text '离线模拟 · 正在接收'
    Set-MainText -Name 'TrafficDetail' -Text '离线模拟：收听 TG91，未连接 BM。'
    Set-MainText -Name 'RadioStateValue' -Text '电台状态：未知（离线模拟）'
    Set-MainText -Name 'CurrentCallValue' -Text 'TEST · DMR ID 3149876'
    Set-MainText -Name 'CurrentCallDetail' -Text 'TG 91 · TS2'
    $renderRouting = [pscustomobject][ordered]@{
        local_source_id=[uint64]3149876; rx_policy_revision=[uint64]2; tx_policy_revision=[uint64]1
        rx_policy=(Copy-UiRxPolicy -Policy $renderRxPolicy)
        tx_target=[pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
        transmit_enabled=$true; media_owner='idle'; active_rx=$null
        active_tx_lease=[pscustomobject][ordered]@{ lease_id=[uint64]7; destination_id=[uint64]53000; slot=[uint64]1; kind='group' }
        observed_sources=@(
            [pscustomobject][ordered]@{ source_id=[uint64]3149877; destination_id=[uint64]91; slot=[uint64]2; kind='group'; observation_level='outer_header_seen' },
            [pscustomobject][ordered]@{ source_id=[uint64]460997; destination_id=[uint64]3149876; slot=[uint64]2; kind='private'; observation_level='outer_header_seen' }
        )
    }
    if (-not (Test-UiRoutingSnapshot -Routing $renderRouting)) { throw '离线渲染路由样例无效。' }
    $script:activeRouting = $renderRouting
    $script:activeProfile = $simulatedEffectiveProfile
    $script:editRxPolicy = Copy-UiRxPolicy -Policy $renderRxPolicy
    $script:editTxTarget = [pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
    $script:editTransmitEnabled = $false
    Update-RoutingDisplays
    $script:channelFavorites = @(
        [pscustomobject][ordered]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]1; label='离线样例收藏'; category='static' },
        [pscustomobject][ordered]@{ destination_id=[uint64]54000; kind='group'; slot=[uint64]2; label='离线样例收藏'; category='dynamic' }
    )
    Update-UiChannelFavoriteControls
    $script:latestStatus = [pscustomobject][ordered]@{
        run_id='render-fixture'; current_call_valid=$true; current_call_generation=[uint64]4
        current_call_source_id=[uint64]3149876; current_call_destination_id=[uint64]91
        current_call_slot=[uint64]2; current_call_kind='G'
        bm_rtt_valid=$true; bm_rtt_last_ms=[uint64]42; bm_rtt_sample_count=[uint64]3
        rx_call_dmrd_valid=$true; rx_call_dmrd_received=[uint64]10; rx_call_dmrd_missing=[uint64]0
        rx_call_dmrd_expected=[uint64]10; rx_call_dmrd_loss_pct=[double]0; rx_call_dmrd_loss_complete=$false
        rx_session_dmrd_valid=$true; rx_session_dmrd_received=[uint64]10; rx_session_dmrd_missing=[uint64]0
        rx_session_dmrd_expected=[uint64]10; rx_session_dmrd_loss_pct=[double]0
    }
    Update-UiReceiveMetricsDisplay -Record $script:latestStatus
    $callMetricsLayout = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('BmRttMetric','BmRttValue','RxNetworkMetric','RxCallLossValue','RxSessionLossValue')
    $sessionMetricsFixture = [pscustomobject][ordered]@{
        current_call_valid=$false; rx_call_dmrd_valid=$false
        rx_session_dmrd_valid=$true; rx_session_dmrd_received=[uint64]15; rx_session_dmrd_missing=[uint64]0
        rx_session_dmrd_expected=[uint64]15; rx_session_dmrd_loss_pct=[double]0
    }
    Update-UiReceiveMetricsDisplay -Record $sessionMetricsFixture
    $sessionMetricsLayout = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('RxNetworkMetric','RxCallLossValue','RxSessionLossValue')
    Update-UiReceiveMetricsDisplay -Record $script:latestStatus
    $historyRecord = [pscustomobject][ordered]@{
        run_id='render-fixture'; current_call_valid=$true; current_call_generation=[uint64]3
        current_call_source_id=[uint64]3149877; current_call_destination_id=[uint64]91
        current_call_slot=[uint64]2; current_call_kind='G'; timestamp_utc_ms=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToUnixTimeMilliseconds()
    }
    Add-UiCallHistoryRecord -Record $historyRecord
    $historyRecord.current_call_generation=[uint64]4
    $historyRecord.current_call_source_id=[uint64]3149876
    $historyRecord.timestamp_utc_ms=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds()
    Add-UiCallHistoryRecord -Record $historyRecord
    Add-UiCallHistoryRecord -Record $historyRecord
    (Get-UiControl 'CallHistoryList').SelectedIndex = 0
    Update-UiIdentityActionState
    Update-UiPlaybackGainDisplay -Record ([pscustomobject]@{ rx_output_gain_milli=[uint32]5959; rx_pcm_clipped_samples=[uint64]21684; rx_audio_samples=[uint64]23851566 })
    $script:mainWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $renderDirectory 'main-routing-fixture.png')
    $script:loadingSettings = $true
    (Get-SettingsControl 'CallsignBox').Text = 'TEST'
    (Get-SettingsControl 'GatewayBox').Text = '1'
    (Get-SettingsControl 'SourceBox').Text = '3149876'
    (Get-SettingsControl 'MasterBox').Text = '192.0.2.1'
    (Get-SettingsControl 'MasterPortBox').Text = '62031'
    (Get-SettingsControl 'ColorCodeBox').Text = '1'
    (Get-SettingsControl 'DestinationBox').Text = '460997'
    $renderSlot = Get-SettingsControl 'SlotBox'
    $renderSlot.SelectedItem = @($renderSlot.Items | Where-Object { [string]$_.Tag -ceq '2' })[0]
    $renderKind = Get-SettingsControl 'CallKindBox'
    $renderKind.SelectedItem = @($renderKind.Items | Where-Object { [string]$_.Tag -ceq 'private' })[0]
    (Get-SettingsControl 'TransmitEnabledBox').IsChecked = $false
    (Get-SettingsControl 'GroupRouteIdBox').Text = '91'
    (Get-SettingsControl 'BlockedGroupIdBox').Text = '46001'
    (Get-SettingsControl 'PeerSourceIdBox').Text = '460997'
    (Get-SettingsControl 'PeerLocalDestinationBox').Text = '3149876'
    (Get-SettingsControl 'LocalPrivateDestinationBox').Text = '3149876'
    (Get-SettingsControl 'BlockedSourceIdBox').Text = '3149877'
    (Get-SettingsControl 'ProfileMigrationText').Text = '离线渲染样例：下方路由和观察卡片均为模拟数据，没有连接电台或 BM。'
    $script:loadingSettings = $false
    Set-SettingsPolicyLists
    $script:settingsWindow.FindName('SettingsScrollViewer').ScrollToVerticalOffset(360)
    (Get-SettingsControl 'GroupRoutesList').SelectedIndex = 0
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:settingsWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:settingsWindow -Path (Join-Path $renderDirectory 'settings-routes.png')
    $routeStyleControl = Get-SettingsControl 'GroupRoutesList'
    $routeStyleContainer = $routeStyleControl.ItemContainerGenerator.ContainerFromIndex(0)
    $renderRouteListEvidence = [pscustomobject][ordered]@{
        group_routes=@($routeStyleControl.Items | ForEach-Object { [string]$_ })
        blocked_groups=@((Get-SettingsControl 'BlockedGroupsList').Items | ForEach-Object { [string]$_ })
        private_peers=@((Get-SettingsControl 'PeerRoutesList').Items | ForEach-Object { [string]$_ })
        local_private_routes=@((Get-SettingsControl 'LocalPrivateRoutesList').Items | ForEach-Object { [string]$_ })
        blocked_sources=@((Get-SettingsControl 'BlockedSourcesList').Items | ForEach-Object { [string]$_ })
        group_background=$routeStyleControl.Background.Color.ToString()
        group_foreground=$routeStyleControl.Foreground.Color.ToString()
        selected_route_background=if ($routeStyleContainer -and $routeStyleContainer.Background -is [System.Windows.Media.SolidColorBrush]) { $routeStyleContainer.Background.Color.ToString() } else { '' }
    }
    $activeCallDirectory = Join-Path $renderDirectory 'configured-active-call'
    [System.IO.Directory]::CreateDirectory($activeCallDirectory) | Out-Null
    if ($script:settingsWindow) { $script:settingsWindow.Hide() }
    $script:mainWindow.Show()
    $script:mainWindow.Activate()
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:mainWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $activeCallDirectory 'main-window.png')
    $activeCallDisplayControls = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('CurrentCallPanel','CurrentCallValue','CurrentCallDetail','IdentityLookupStatusValue','RecentCallPanel','HistoryPanel','HistoryActionsPanel','CallHistoryList','BlockCurrentSourceButton','RadioDetailsExpander')
    $activeCallLayout = [pscustomobject][ordered]@{
        render_only = [bool]$RenderOnly
        fixture_label = '模拟数据 · 未连接设备或网络'
        work_area_width = $script:workAreaWidth
        work_area_height = $script:workAreaHeight
        max_window_width = $script:maxWindowWidth
        max_window_height = $script:maxWindowHeight
        device_combo_rendered_text = $deviceComboEvidence
        main = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('ConnectButton', 'SettingsButton', 'StopButton', 'FooterText', 'TargetSelector', 'ReceiveTargetValue', 'TransmitTargetValue', 'TransmitPermissionValue', 'ActiveLeaseValue', 'PlaybackGainStatusValue', 'ListeningHistoryPanel', 'CallChannelPanel', 'CallTargetStatusValue', 'CallTargetChoicesPanel', 'CallFavoritesList', 'FavoriteCurrentTargetButton', 'FavoriteManualGroupButton', 'ApplyCallFavoriteButton', 'RemoveCallFavoriteButton', 'ChannelFavoritesStatusValue', 'CallHistoryList', 'SetHistoryCallTargetButton', 'QueryCurrentIdentityButton', 'QueryHistoryIdentityButton', 'IdentityLookupStatusValue', 'CoreDetail', 'RadioDetail', 'AudioDetail', 'BmDetail', 'CoreStatusCard', 'RadioStatusCard', 'AudioStatusCard', 'BmStatusCard', 'HriSourceIdentityValue', 'RadioDisplayValue', 'CurrentCallLabel', 'CurrentCallValue', 'CurrentCallDetail', 'BlockCurrentSourceButton', 'TrafficCard', 'DynamicGroupPanel', 'DynamicGroupIdBox', 'DynamicGroupSlotBox', 'SetDynamicCallTargetButton', 'AddListenGroupButton', 'ActivateDynamicGroupButton', 'DynamicGroupStatus')
        main_empty_state = $layoutInfo.main_empty_state
        main_action_controls = $layoutInfo.main_action_controls
        main_call_controls = $activeCallDisplayControls
        settings_action_controls = $layoutInfo.settings_action_controls
        settings_empty_state = $layoutInfo.settings_empty_state
        settings = $layoutInfo.settings
        main_source_identity = $layoutInfo.main_source_identity
        radio_details_expanded = [bool](Get-UiControl 'RadioDetailsExpander').IsExpanded
        configured_profile = $simulatedEffectiveProfile
        active_call = [pscustomobject][ordered]@{
            value = (Get-UiControl 'CurrentCallValue').Text
            detail = (Get-UiControl 'CurrentCallDetail').Text
            current_identity_details = Format-UiRadioIdentityDetails -RadioId 3149876
            current_tx_target = (Get-UiControl 'ActiveLeaseValue').Text
            next_tx_target = (Get-UiControl 'TransmitTargetValue').Text
            visual_text = @(Get-UiVisualTextValues -Root $script:mainWindow)
            configured_routes_text = @(Get-UiVisualTextValues -Root $script:mainWindow.FindName('ConfiguredRoutesPanel'))
            history_items = @((Get-UiControl 'CallHistoryList').Items | ForEach-Object { [string]$_.text })
            history_identity_details = @((Get-UiControl 'CallHistoryList').Items | ForEach-Object { [string]$_.identity_details })
            favorite_items = @((Get-UiControl 'CallFavoritesList').Items | ForEach-Object { [string]$_.text })
            playback_gain_status = (Get-UiControl 'PlaybackGainStatusValue').Text
            metrics_call = $callMetricsLayout
            metrics_session = $sessionMetricsLayout
            observed_cards = @(
                foreach ($card in @($script:mainWindow.FindName('ObservedSourcesPanel').Children)) {
                    if ($card -isnot [System.Windows.Controls.Border] -or $card.Child -isnot [System.Windows.Controls.StackPanel]) { continue }
                    $actions = @($card.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.UniformGrid] }) | Select-Object -First 1
                    if (-not $actions -or $actions.Children.Count -eq 0) { continue }
                    $buttons = @($actions.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })
                    $localButton = @($buttons | Where-Object { [string]$_.Tag.Action -ceq 'toggle' }) | Select-Object -First 1
                    $sourceButton = @($buttons | Where-Object { [string]$_.Tag.Action -ceq 'block' }) | Select-Object -First 1
                    $txButton = @($buttons | Where-Object { [string]$_.Tag.Action -ceq 'tx' }) | Select-Object -First 1
                    if (-not $sourceButton) { continue }
                    $source = $sourceButton.Tag.Source
                    [pscustomobject][ordered]@{
                        source_id=[uint64]$source.source_id; destination_id=[uint64]$source.destination_id; slot=[uint64]$source.slot; kind=[string]$source.kind
                        local_action=if ($localButton) { [string]$localButton.Content } else { '' }
                        local_action_enabled=if ($localButton) { [bool]$localButton.IsEnabled } else { $false }
                        local_action_visible=[bool]$localButton
                        source_action=[string]$sourceButton.Content; source_action_enabled=[bool]$sourceButton.IsEnabled
                        tx_action=if ($txButton) { [string]$txButton.Content } else { '' }
                        tx_action_enabled=if ($txButton) { [bool]$txButton.IsEnabled } else { $false }
                        tx_action_visible=[bool]$txButton
                        action_bindings=@($buttons | ForEach-Object { [pscustomobject][ordered]@{ action=[string]$_.Tag.Action; label=[string]$_.Content; source_id=[uint64]$_.Tag.Source.source_id } })
                    }
                }
            )
        }
        route_settings = $renderRouteListEvidence
    }
    [System.IO.File]::WriteAllText((Join-Path $activeCallDirectory 'layout-info.json'),
        (ConvertTo-Json -InputObject $activeCallLayout -Depth 9), (New-Object System.Text.UTF8Encoding($false)))
    $radioDetailsExpander = Get-UiControl 'RadioDetailsExpander'
    $dashboardScrollViewer = Get-UiControl 'DashboardScrollViewer'
    $dashboardScrollViewer.ScrollToEnd()
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:mainWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $renderDirectory 'dashboard-bottom.png')
    $dashboardBottomLayout = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('DynamicGroupPanel','DynamicGroupIdBox','DynamicGroupSlotBox','SetDynamicCallTargetButton','AddListenGroupButton','ActivateDynamicGroupButton','DynamicGroupStatus')
    [System.IO.File]::WriteAllText((Join-Path $renderDirectory 'dashboard-bottom-layout.json'),
        (ConvertTo-Json -InputObject $dashboardBottomLayout -Depth 7), (New-Object System.Text.UTF8Encoding($false)))
    $radioDetailsExpander.IsExpanded = $true
    $dashboardScrollViewer.ScrollToEnd()
    $observedSourcesPanel = Get-UiControl 'ObservedSourcesPanel'
    $observedSourcesScroll = [System.Windows.Media.VisualTreeHelper]::GetParent($observedSourcesPanel)
    while ($observedSourcesScroll -and $observedSourcesScroll -isnot [System.Windows.Controls.ScrollViewer]) {
        $observedSourcesScroll = [System.Windows.Media.VisualTreeHelper]::GetParent($observedSourcesScroll)
    }
    if ($observedSourcesScroll -is [System.Windows.Controls.ScrollViewer]) { $observedSourcesScroll.ScrollToEnd() }
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:mainWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $renderDirectory 'radio-details-expanded.png')
    $expandedRadioDetails = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('RadioDetailsExpander','ObservedSourcesCard','ObservedSourcesPanel','TrafficCard','RunValue','FreshnessValue','ControlProtocolValue','ControlStatusButton','DynamicGroupPanel','DynamicGroupIdBox','DynamicGroupSlotBox','SetDynamicCallTargetButton','AddListenGroupButton','ActivateDynamicGroupButton','DynamicGroupStatus')
    $expandedRadioDetails | Add-Member -NotePropertyName is_expanded -NotePropertyValue ([bool]$radioDetailsExpander.IsExpanded)
    $expandedRadioDetails | Add-Member -NotePropertyName observed_source_text -NotePropertyValue @(Get-UiVisualTextValues -Root $observedSourcesPanel)
    $sourceActionEvidence = @(
        foreach ($card in @($observedSourcesPanel.Children)) {
            if ($card -isnot [System.Windows.Controls.Border] -or $card.Child -isnot [System.Windows.Controls.StackPanel]) { continue }
            $actions = @($card.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.UniformGrid] }) | Select-Object -First 1
            if (-not $actions) { continue }
            foreach ($button in @($actions.Children)) {
                $buttonLayout = if ($button.IsVisible) { Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $button } else { $null }
                [pscustomobject][ordered]@{
                    text=[string]$button.Content; action=[string]$button.Tag.Action
                    source_id=[uint64]$button.Tag.Source.source_id; is_enabled=[bool]$button.IsEnabled
                    is_visible=[bool]$button.IsVisible
                    actual=if ($buttonLayout) { $buttonLayout.actual } else { $null }
                    visible=if ($buttonLayout) { $buttonLayout.visible } else { $null }
                    fully_visible=if ($buttonLayout) { [bool]$buttonLayout.fully_visible } else { $false }
                }
            }
        }
    )
    $expandedRadioDetails | Add-Member -NotePropertyName observed_source_buttons -NotePropertyValue $sourceActionEvidence
    [System.IO.File]::WriteAllText((Join-Path $renderDirectory 'radio-details-expanded-layout.json'),
        (ConvertTo-Json -InputObject $expandedRadioDetails -Depth 7), (New-Object System.Text.UTF8Encoding($false)))
    $dashboardScrollViewer.ScrollToTop()
    $radioDetailsExpander.IsExpanded = $false
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:mainWindow.UpdateLayout()
    $script:settingsWindow.Show()
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $routeSettingsLayout = Get-WpfWindowLayoutInfo -Window $script:settingsWindow -ControlNames @(
        'GroupModeBox','PrivateModeBox','GroupRouteIdBox','GroupRouteSlotBox','AddGroupRouteButton','RemoveGroupRouteButton','GroupRoutesList',
        'BlockedGroupIdBox','BlockedGroupSlotBox','AddBlockedGroupButton','RemoveBlockedGroupButton','BlockedGroupsList',
        'PeerSourceIdBox','PeerLocalDestinationBox','PeerSlotBox','AddPeerRouteButton','RemovePeerRouteButton','PeerRoutesList',
        'LocalPrivateDestinationBox','LocalPrivateSlotBox','AddLocalPrivateRouteButton','RemoveLocalPrivateRouteButton','LocalPrivateRoutesList',
        'BlockedSourceIdBox','AddBlockedSourceButton','RemoveBlockedSourceButton','BlockedSourcesList')
    [System.IO.File]::WriteAllText((Join-Path $renderDirectory 'settings-routes-layout.json'),
        (ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ settings=$routeSettingsLayout; route_settings=$renderRouteListEvidence }) -Depth 7),
        (New-Object System.Text.UTF8Encoding($false)))
    $script:settingsWindow.Show()
    $script:settingsWindow.FindName('SettingsScrollViewer').ScrollToVerticalOffset(850)
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $script:settingsWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:settingsWindow -Path (Join-Path $renderDirectory 'settings-private-routes.png')
    $script:settingsWindow.Close()
    $script:mainWindow.Close()
    $script:uiTimer.Stop()
    $script:application.Shutdown()
    Write-Host '通过：WPF 主窗口和设置窗口已离线渲染；没有启动核心或访问设备。'
    return
}

[void]$script:application.Run($script:mainWindow)
$script:uiTimer.Stop()
if ($script:statusStream) { $script:statusStream.Dispose() }
if ($script:supervisor) { $script:supervisor.Dispose() }
if ($script:preparePowerShell -and -not $script:abandonPreparationAtShutdown) { $script:preparePowerShell.Dispose() }
