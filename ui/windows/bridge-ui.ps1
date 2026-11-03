[CmdletBinding()]
param(
    [string]$UserConfigDirectory,
    [string]$PackageDirectory,
    [string]$PortableDirectory,
    [switch]$OfflinePreview,
    [switch]$NoAutoConnect,
    [switch]$RenderOnly,
    [switch]$UiTestFixture,
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
$script:portableDirectoryWasExplicit = $PSBoundParameters.ContainsKey('PortableDirectory') -and
    -not [string]::IsNullOrWhiteSpace($PortableDirectory)
$script:portableRoot = if ($script:portableDirectoryWasExplicit) {
    [System.IO.Path]::GetFullPath($PortableDirectory)
} else { $script:packageRoot }
$script:isolatedUiMode = [bool]($RenderOnly -or $OfflinePreview -or $UiTestFixture -or $RoutingDiagnostic)

function Test-UiPathWithinDirectory {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Directory)
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([char[]]@('\','/'))
        if ([string]::Equals($fullPath,$fullDirectory,[StringComparison]::OrdinalIgnoreCase)) { return $true }
        $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-UiRoutingDiagnosticConfigDirectory {
    param([string]$Directory,[string]$PackageRoot,[string]$PortableRoot='',[switch]$RequireFixture)
    if ([string]::IsNullOrWhiteSpace($Directory)) { throw '路由诊断必须指定独立的用户配置目录。' }
    if (-not [System.IO.Path]::IsPathRooted($Directory)) { throw '路由诊断的 -UserConfigDirectory 必须使用绝对路径。' }
    try {
        $resolvedDirectory = [System.IO.Path]::GetFullPath($Directory)
        $canonicalDirectory = [System.IO.Path]::GetFullPath((Join-Path $PackageRoot 'private\user-config'))
    } catch { throw '路由诊断配置目录路径无效。' }
    if ([string]::Equals($resolvedDirectory.TrimEnd('\'),$canonicalDirectory.TrimEnd('\'),[System.StringComparison]::OrdinalIgnoreCase)) {
        throw '路由诊断不能使用便携目录的默认个人配置目录；请传入隔离的 -UserConfigDirectory。'
    }
    if (($PortableRoot -and (Test-UiPathWithinDirectory -Path $resolvedDirectory -Directory $PortableRoot)) -or
        (Test-UiPathWithinDirectory -Path $resolvedDirectory -Directory $PackageRoot)) {
        throw '路由诊断的 -UserConfigDirectory 不能等于或位于 PortableDirectory/PackageDirectory；请传入外部隔离目录。'
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

$validatedDiagnosticDirectory = if ($RoutingDiagnostic) {
    Test-UiRoutingDiagnosticConfigDirectory -Directory $UserConfigDirectory -PackageRoot $script:packageRoot `
        -PortableRoot $script:portableRoot -RequireFixture:$RoutingDiagnosticAutoTest
} else { $UserConfigDirectory }

$script:modulePath = Join-Path $script:packageRoot 'bridge-user-config.psm1'
if (-not [System.IO.File]::Exists($script:modulePath)) {
    $script:modulePath = Join-Path $script:packageRoot 'tools\bridge-user-config.psm1'
}
if (-not [System.IO.File]::Exists($script:modulePath)) {
    $script:modulePath = Join-Path $script:uiRoot '..\..\tools\bridge-user-config.psm1'
}
if (-not [System.IO.File]::Exists($script:modulePath)) { throw '缺少本机配置模块 bridge-user-config.psm1。' }
$script:portableConfigModulePath = Join-Path $script:uiRoot 'PortableConfig.psm1'
if (-not [System.IO.File]::Exists($script:portableConfigModulePath)) { throw '缺少统一配置模块 PortableConfig.psm1。' }
Import-Module -Name $script:portableConfigModulePath -Force
foreach ($commandName in @('Get-WirexPortableConfig','Save-WirexPortableConfig')) {
    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) { throw "统一配置模块缺少 $commandName。" }
}
$script:channelActivationStateModulePath = Join-Path $script:uiRoot 'ChannelActivationState.psm1'
if (-not [System.IO.File]::Exists($script:channelActivationStateModulePath)) { throw '缺少频道激活状态模块。' }
$script:supervisorSource = Join-Path $script:uiRoot 'BridgeSupervisor.cs'
$script:mainXamlPath = Join-Path $script:uiRoot 'MainWindow.xaml'
$script:settingsXamlPath = Join-Path $script:uiRoot 'SettingsWindow.xaml'
$script:bmApiKeySettingsUri = 'https://brandmeister.network/#/profile/api'
$script:bmPasswordSettingsUri = 'https://brandmeister.network/#/selfcare'
$script:bmProfileUriTemplate = 'https://brandmeister.network/#/profile/{0}'
$script:radioCatModulePath = Join-Path $script:uiRoot 'RadioCat.psm1'
$script:radioDevicesModulePath = Join-Path $script:uiRoot 'RadioDevices.psm1'
$script:bmManagementModulePath = Join-Path $script:uiRoot 'BmManagement.psm1'
$script:bmServersModulePath = Join-Path $script:uiRoot 'BmServers.psm1'
$script:radioCatModuleAvailable = [System.IO.File]::Exists($script:radioCatModulePath)
$script:radioCatModuleLoadError = ''
$script:bmManagementModuleAvailable = [System.IO.File]::Exists($script:bmManagementModulePath)
$script:bmServersModuleAvailable = [System.IO.File]::Exists($script:bmServersModulePath)
foreach ($path in @($script:supervisorSource, $script:mainXamlPath, $script:settingsXamlPath)) {
    if (-not [System.IO.File]::Exists($path)) { throw "缺少桌面界面文件：$path" }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if ($script:isolatedUiMode) {
    if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
        $script:portableConfigDirectory = [System.IO.Path]::GetFullPath($UserConfigDirectory)
    } else {
        $script:portableConfigDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-ui-isolated-' + [guid]::NewGuid().ToString('N'))
    }
    [System.IO.Directory]::CreateDirectory($script:portableConfigDirectory) | Out-Null
    $script:portableConfigPath = Join-Path $script:portableConfigDirectory 'config.json'
    $script:configDirectory = $script:portableConfigDirectory
} else {
    try {
        if (-not [System.IO.Directory]::Exists($script:packageRoot)) { throw 'Runtime 目录不存在。' }
        if (-not [System.IO.Directory]::Exists($script:portableRoot)) { throw '便携程序根目录不存在。' }
        $script:portableConfigDirectory = $script:portableRoot
        $script:configDirectory = Join-Path $script:packageRoot 'private\runtime'
        [System.IO.Directory]::CreateDirectory($script:configDirectory) | Out-Null
        if (-not (Get-Command -Name Initialize-PortableConfig -ErrorAction SilentlyContinue)) {
            throw '配置模块缺少 Initialize-PortableConfig。'
        }
        $resolvedConfigPath = [System.IO.Path]::GetFullPath([string](Initialize-PortableConfig -PortableDirectory $script:portableRoot))
        $expectedConfigPath = [System.IO.Path]::GetFullPath((Join-Path $script:portableRoot 'config.json'))
        if (-not [System.IO.Path]::IsPathRooted($resolvedConfigPath) -or
            -not [string]::Equals($resolvedConfigPath,$expectedConfigPath,[StringComparison]::OrdinalIgnoreCase)) {
            throw '配置模块返回的 config.json 路径与 PortableDirectory 不一致。'
        }
        if ($script:portableDirectoryWasExplicit -and
            (Test-UiPathWithinDirectory -Path $resolvedConfigPath -Directory $script:packageRoot)) {
            throw 'PortableDirectory 返回的 config.json 落在 Runtime 目录内。'
        }
        $script:portableConfigPath = $resolvedConfigPath
    } catch {
        $startupConfigError = '无法创建或读取便携配置 config.json：' + [string]$_.Exception.Message
        try { [void][System.Windows.MessageBox]::Show($startupConfigError,'WIREX Bridge',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) } catch { }
        throw $startupConfigError
    }
}

Import-Module -Name $script:modulePath -Force
Import-Module -Name $script:channelActivationStateModulePath -Force
if ($script:radioCatModuleAvailable) {
    try {
        Import-Module -Name $script:radioCatModulePath -Force
        foreach ($commandName in @('Invoke-Ftx1CatOperation','New-Ftx1CatModeCommand','New-Ftx1CatFrequencyCommand',
                'New-Ftx1CatPowerCommand','ConvertFrom-Ftx1CatFrame')) {
            if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) { throw "CAT 模块缺少 $commandName。" }
        }
    } catch {
        $script:radioCatModuleAvailable = $false
        $script:radioCatModuleLoadError = $_.Exception.Message
    }
}
if ($script:bmManagementModuleAvailable) {
    try {
        Import-Module -Name $script:bmManagementModulePath -Force
        foreach ($commandName in @('Get-BmStaticGroups','Add-BmStaticGroup','Remove-BmStaticGroup')) {
            if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) { throw "BM 管理模块缺少 $commandName。" }
        }
    } catch { $script:bmManagementModuleAvailable = $false }
}
if ($script:bmServersModuleAvailable) {
    try {
        Import-Module -Name $script:bmServersModulePath -Force
        foreach ($commandName in @('Get-BmServerCatalog','Resolve-BmServerSelection','New-BmServerSelectionValues')) {
            if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) { throw "BM 服务器目录缺少 $commandName。" }
        }
    } catch { $script:bmServersModuleAvailable = $false }
}
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

$script:audioSettingsPath = ''
$script:identityModulePath = Join-Path $script:uiRoot 'RadioIdentity.psm1'
$script:identityCachePath = Join-Path $script:configDirectory 'radio-identity-cache.json'
if ([System.IO.File]::Exists($script:identityModulePath)) {
    Import-Module -Name $script:identityModulePath -Force
    $script:radioIdentityModuleLoaded = $true
    if (Get-Command -Name Get-RadioIdentityCachePath -ErrorAction SilentlyContinue) {
        $script:identityCachePath = Get-RadioIdentityCachePath -UserConfigDirectory $script:configDirectory
    }
}
$script:releasePointerPath = ''
$script:releaseDirectory = $script:packageRoot
$script:releaseLauncher = Join-Path $script:releaseDirectory 'start-bm-radio-bridge.ps1'
$script:nativeExecutable = Join-Path $script:releaseDirectory 'wirex_bridge.exe'
if (-not [System.IO.File]::Exists($script:releaseLauncher) -or -not [System.IO.File]::Exists($script:nativeExecutable)) {
    if (-not $UiTestFixture) { throw '所选便携目录缺少桥接启动脚本或 native 核心。' }
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
$script:radioControlPreferencesPath = ''
$script:bmServerSelectionPreferenceId = ''
$script:bmServerSelectionDirty = $false
$script:bmServerSelectionLoadedId = ''
$script:loadingBmServerSelection = $false
$script:bmManagementPreferences = [pscustomobject][ordered]@{ schema_version=1; api_key_file_path='' }
$script:bmManagementPreferencesError = ''
$script:bmManagementOperationPowerShell = $null
$script:bmManagementOperationAsync = $null
$script:bmManagementOperationStopAsync = $null
$script:bmManagementCancellationSource = $null
$script:bmManagementOperation = ''
$script:bmManagementOperationStartedUtc = [DateTime]::MinValue
$script:bmManagementOperationResult = $null
$script:bmManagementOperationErrorCode = ''
$script:bmManagementOperationGeneration = [uint64]0
$script:bmManagementActiveGeneration = [uint64]0
$script:bmManagementDeviceId = ''
$script:bmManagementStatus = 'unavailable'
$script:bmManagementGroups = @()
$script:bmManagementObservedDeviceId = ''
$script:bmManagementLastErrorCode = ''
$script:bmManagementLastWriteAccepted = $false
$script:bmManagementLastReadbackStatus = ''
$script:bmManagementUiInitialized = $false
$script:bmManagementUiDisposed = $false
$script:bmCloseWhenDisposed = $false
$script:deviceSerialState = 'not_started'
$script:deviceAudioState = 'not_started'
$script:deviceSerialError = ''
$script:deviceAudioError = ''
$script:deviceSerialResult = $null
$script:deviceAudioResult = $null
$script:deviceSerialStopPending = $false
$script:deviceAudioStopPending = $false
$script:uiTestHooks = if ($script:uiTestHooks -is [hashtable]) { $script:uiTestHooks } else { @{} }
$script:uiTestDiscoveryResult = $null
$script:radioCatPollIntervalMs = 1000
$script:radioCatPollNextUtc = [DateTime]::MinValue
$script:radioCatLastSuccessfulQueryUtc = [DateTime]::MinValue
$script:radioCatEditDraft = @{ mode=$null; frequency=$null; power=$null }
$script:radioCatProgrammaticControlUpdate = $false
$script:radioCatPortSelectionExplicit = $false
$script:radioCatPendingModeFrequencyRequest = $null
$script:radioCatWorkerTestOverride = $null
$script:radioControlPreferences = [pscustomobject][ordered]@{
    schema_version = 1
    cat_port = 'auto'
    baud_rate = 38400
    stop_bits = 'Two'
    desired_power_watts = 25
}
$script:radioControlPreferencesError = ''
$script:radioCatOperationPowerShell = $null
$script:radioCatOperationAsync = $null
$script:radioCatOperationStopAsync = $null
$script:radioCatOperationStartedUtc = [DateTime]::MinValue
$script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
$script:radioCatOperationOwnerWindow = $null
$script:radioCatOperationKind = ''
$script:radioCatOperationPortName = ''
$script:radioCatOperationBaudRate = 0
$script:radioCatOperationStopBits = ''
$script:radioCatObservedConnectionKey = ''
$script:radioCatObservedPortName = ''
$script:radioCatOperationCancelled = $false
$script:radioCatOperationCancelReason = ''
$script:radioCatCloseSettingsAfterOperation = $false
$script:radioCatCloseMainAfterOperation = $false
$script:radioCatResult = $null
$script:radioCatObserved = $null
$script:radioCatLastOperationStatus = ''
$script:radioCatPowerPreferenceDirty = $false
$script:radioCatPowerNeedsUserChoice = $false
$script:loadingRadioCatSettings = $false
$script:activeHriPortName = ''
$script:radioModeApplyAfterStop = $null
$script:radioModePreviousHriPortName = ''
$script:statusStream = $null
$script:statusPath = ''
$script:preparedRunDirectory = ''
$script:sessionTempDirectory = ''
$script:sessionPasswordPath = ''
$script:statusOffset = [int64]0
$script:partialStatusLine = ''
$script:currentRunId = ''
$script:lastSequence = [uint64]0
$script:controlRunId = ''
$script:controlLastSequence = [uint64]0
$script:controlConfirmed = $false
$script:controlCapabilities = ''
$script:bmConnectionNativeCapability = $false
$script:bmConnectionSnapshot = $null
$script:bmConnectionRevision = [uint64]0
$script:bmConnectionPendingRequest = $null
$script:bmConnectAfterCoreReady = $false
$script:bmStatusNextRequestUtc = [DateTime]::MinValue
$script:lastBmSnapshotUtc = [DateTime]::MinValue
$script:bmStatusRecoveryStartedUtc = [DateTime]::MinValue
$script:bmStatusRecoveryCount = 0
$script:serialDisconnectPending = $false
$script:serialDisconnectCoreStopIssued = $false
$script:serialDisconnectCatStopRequested = $false
$script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
$script:quickCallCapabilities = $false
$script:pendingQuickCall = $null
$script:queuedQuickCall = $null
$script:quickCallQueueTimeoutSeconds = 60
$script:channelActivationState = New-WirexChannelActivationState
$script:pendingDynamicLocalListen = $null
$script:pendingDynamicCallTarget = $null
$script:controlDiagnostic = $false
$script:identityNativeCapability = $false
$script:identityNativeRunId = ''
$script:identityNativeRevision = [uint64]0
$script:identityNativeQueue = New-Object 'System.Collections.Generic.List[object]'
$script:identityNativeInFlight = $null
$script:identityNativeDeferredBySource = @{}
$script:identityNativeDeferredOrder = New-Object 'System.Collections.Generic.List[string]'
$script:expiredIdentityNativeRequests = @{}
$script:identityNativeCallRefreshKeys = @{}
$script:identityNativeCallRefreshOrder = New-Object 'System.Collections.Generic.List[string]'
$script:controlOverflowHandled = $false
$script:pendingControlRequests = @{}
$script:expiredQuickCallRequests = @{}
$script:resolvedTimedOutRoutingRequests = @{}
$script:pendingStatusRequestId = ''
$script:pendingRoutingStatusRequestId = ''
$script:routingCapabilities = $false
$script:activeRouting = $null
$script:editRxPolicy = $null
$script:editTxTarget = $null
$script:txEditorDirty = $false
$script:pendingRoutingMutation = $null
$script:timedOutRoutingMutations = @{}
$script:routingDraftPreservedAfterTimeout = $false
$script:routingDraftAfterTimeout = $null
$script:routingMutationFence = $false
$script:routingLastUpdateUtc = [DateTime]::MinValue
$script:routingDiagnosticAutoTestStarted = $false
$script:routingDiagnosticAutoTestPhase = 0
$script:routingDiagnosticChannelFlowTest = [pscustomobject][ordered]@{
    passed=$false;channel_key='group:12345:1';tx_command='';rx_command='';ptt_unchanged_after_add=$false;root_config_saved=$false
    quick_call_command='';frames_sent=[uint64]0;bm_connected=$false;used_memory_sink=$true
    routing_unchanged_after_activation=$false;normal_shutdown_requested=$false
}
$script:routingDiagnosticRoutingBeforeQuickCall = ''
$script:routingDiagnosticQuickCallResponse = $null
$script:profileEditable = $true
$script:profileWriteAllowed = $true
$script:receiveEditorState = $null
$script:lastStatusUtc = [DateTime]::MinValue
$script:latestStatus = $null
$script:transientStatusText = ''
$script:transientStatusLastMessage = ''
$script:transientStatusFailed = $false
$script:transientStatusDeadlineUtc = [DateTime]::MinValue
$script:storedProfile = $null
$script:effectiveProfile = $null
$script:activeProfile = $null
$script:pendingCallTarget = $null
$script:loadingCallTargetSelection = $false
$script:loadingChannelPreset = $false
$script:channelPresetId = ''
$script:channelPresetKind = ''
$script:channelAutoKind = ''
$script:channelKindExplicit = $false
$script:savedPlaybackGainMilli = $null
$script:savedTransmitGainMilli = $null
$script:reportedPlaybackGainMilli = $null
$script:reportedPlaybackClippedSamples = $null
$script:audioGainNativeCapability = $false
$script:audioGainCommandRejected = $false
$script:audioGainRunId = ''
$script:audioGainRevision = [uint64]0
$script:audioGainActual = $null
$script:audioGainRuntimeReady = $false
$script:audioGainProgrammaticUpdate = $false
$script:audioGainDraftRevision = [uint64]0
$script:audioGainResolvedDraftRevision = [uint64]0
$script:audioGainDraft = $null
$script:audioGainPendingRequest = $null
$script:audioGainExpiredRequests = @{}
$script:audioGainAwaitingStatus = $false
$script:audioGainTimedOutDraftRevision = [uint64]0
$script:audioGainDebounceReady = $false
$script:audioGainDebounceTimer = $null
$script:audioGainStatusText = ''
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
$script:quickCallDiagnosticPath = Join-Path $script:configDirectory 'quick-call-requests.jsonl'
$script:closingAfterIdentityQuery = $false
$script:portableConfig = $null
$script:gatewayIdentityState = $null
$script:channels = @()
$script:channelPageIndex = 0
$script:txChannelKey = ''
$script:mutedChannelKeys = @{}
$script:pendingChannelMutation = $null
$script:pendingChannelStopMutation = $null
$script:channelMutationSafetyStopPending = $false
$script:channelEditorSlot = [uint64]2
$script:callHistoryKeys = @{}
$script:callHistoryModel = New-Object 'System.Collections.Generic.List[object]'
$script:callHistoryPageIndex = 0
$script:selectedCallHistoryKey = ''
$script:historyPageRendering = $false
$script:bmLossValid = $false
$script:bmStartDisconnectedForRun = $false
$script:serialConnectCatAfterCoreReady = $false
$script:reconnectAfterStopBmStartDisconnected = $false
$script:activeBmTransportConfig = $null
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
    # 主窗口尺寸与最小尺寸由 XAML 固定，避免窄屏分支改变仪表盘比例或引入滚动条。
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

function Get-WpfWindowScrollEvidence {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window)
    $scrollableViewerCount = 0
    $visibleScrollbarCount = 0
    $pending = New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
    $pending.Push($Window)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if ($current -is [System.Windows.Controls.ScrollViewer] -and $current.IsVisible) {
            $vertical = [System.Windows.Controls.ScrollViewer]::GetVerticalScrollBarVisibility($current)
            $horizontal = [System.Windows.Controls.ScrollViewer]::GetHorizontalScrollBarVisibility($current)
            if (($vertical -notin @([System.Windows.Controls.ScrollBarVisibility]::Disabled,[System.Windows.Controls.ScrollBarVisibility]::Hidden) -and $current.ScrollableHeight -gt 0.5) -or
                ($horizontal -notin @([System.Windows.Controls.ScrollBarVisibility]::Disabled,[System.Windows.Controls.ScrollBarVisibility]::Hidden) -and $current.ScrollableWidth -gt 0.5)) {
                $scrollableViewerCount++
            }
        }
        if ($current -is [System.Windows.Controls.Primitives.ScrollBar] -and $current.IsVisible -and
            ($current.ActualWidth -gt 0.5 -or $current.ActualHeight -gt 0.5)) { $visibleScrollbarCount++ }
        if ($current -is [System.Windows.Media.Visual] -or $current -is [System.Windows.Media.Media3D.Visual3D]) {
            $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($current)
            for ($index=0; $index -lt $childCount; $index++) {
                $pending.Push([System.Windows.Media.VisualTreeHelper]::GetChild($current,$index))
            }
        }
    }
    return [pscustomobject][ordered]@{
        area_scrollviewer_count=$scrollableViewerCount
        non_popup_scrollbar_count=$visibleScrollbarCount
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
                $evidence | Add-Member -NotePropertyName is_enabled -NotePropertyValue ([bool]$control.IsEnabled)
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
                $evidence | Add-Member -NotePropertyName is_enabled -NotePropertyValue ([bool]$control.IsEnabled)
            }
            if ($control -is [System.Windows.Controls.Slider]) {
                $evidence | Add-Member -NotePropertyName value -NotePropertyValue ([double]$control.Value)
                $evidence | Add-Member -NotePropertyName minimum -NotePropertyValue ([double]$control.Minimum)
                $evidence | Add-Member -NotePropertyName maximum -NotePropertyValue ([double]$control.Maximum)
                $evidence | Add-Member -NotePropertyName is_enabled -NotePropertyValue ([bool]$control.IsEnabled)
            }
            if ($name -ceq 'DynamicGroupPanel') {
                $evidence | Add-Member -NotePropertyName visual_text -NotePropertyValue @(Get-UiVisualTextValues -Root $control)
            }
            $bounds[$name] = $evidence
        }
    }
    $eventList = $Window.FindName('EventList')
    $scrollEvidence = Get-WpfWindowScrollEvidence -Window $Window
    return [pscustomobject][ordered]@{
        width = [double]$Window.ActualWidth
        height = [double]$Window.ActualHeight
        controls_visible = [pscustomobject]$visibility
        controls_bounds = [pscustomobject]$bounds
        area_scrollviewer_count = [int]$scrollEvidence.area_scrollviewer_count
        non_popup_scrollbar_count = [int]$scrollEvidence.non_popup_scrollbar_count
        event_list_height = if ($null -ne $eventList) { [double]$eventList.ActualHeight } else { $null }
    }
}

function Get-UiControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:mainWindow.FindName($Name)
    if ($null -eq $control) { throw "主窗口缺少控件 $Name。" }
    return $control
}

function Open-UiSetupPage {
    param([Parameter(Mandatory=$true)][ValidateSet('bm_api_key','bm_password')][string]$Kind)
    $address = if ($Kind -ceq 'bm_api_key') { $script:bmApiKeySettingsUri } else { $script:bmPasswordSettingsUri }
    $uri = [System.Uri]$address
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'brandmeister.network') {
        throw '设置页面地址无效。'
    }
    if ($script:uiTestHooks.ContainsKey('OpenUri') -and $script:uiTestHooks.OpenUri -is [scriptblock]) {
        & $script:uiTestHooks.OpenUri $uri.AbsoluteUri
        return $true
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $uri.AbsoluteUri
    $startInfo.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($startInfo)
    return $true
}

function Open-UiDmIdProfile {
    param([Parameter(Mandatory=$true)][string]$DmrId,[Parameter(Mandatory=$true)][string]$Callsign)
    $id = [uint64]0
    if (-not [uint64]::TryParse($DmrId,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$id) -or $id -lt 1) {
        throw 'DMR ID 无效。'
    }
    $normalizedCallsign = Get-UiNativeIdentityCallsign -Value $Callsign
    if ([string]::IsNullOrWhiteSpace($normalizedCallsign)) { throw '呼号尚未解析。' }
    $encodedCallsign = [System.Uri]::EscapeDataString($normalizedCallsign)
    $address = [string]$script:bmProfileUriTemplate -f $encodedCallsign
    $uri = [System.Uri]$address
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'brandmeister.network') {
        throw '资料页面地址无效。'
    }
    if ($script:uiTestHooks.ContainsKey('OpenUri') -and $script:uiTestHooks.OpenUri -is [scriptblock]) {
        & $script:uiTestHooks.OpenUri $uri.AbsoluteUri
        return $uri.AbsoluteUri
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $uri.AbsoluteUri
    $startInfo.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($startInfo)
    return $uri.AbsoluteUri
}

function Get-UiCallsignProfileUri {
    param([Parameter(Mandatory=$true)][string]$Callsign)
    $normalizedCallsign = Get-UiNativeIdentityCallsign -Value $Callsign
    if ([string]::IsNullOrWhiteSpace($normalizedCallsign)) { throw '呼号无效，无法打开 QRZ 资料页。' }
    $address = 'https://www.qrz.com/db/' + [System.Uri]::EscapeDataString($normalizedCallsign)
    $uri = [System.Uri]$address
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'www.qrz.com') {
        throw 'QRZ 资料页面地址无效。'
    }
    return $uri.AbsoluteUri
}

function Open-UiCallsignProfile {
    param([Parameter(Mandatory=$true)][string]$Callsign)
    $address = Get-UiCallsignProfileUri -Callsign $Callsign
    if ($script:uiTestHooks.ContainsKey('OpenUri') -and $script:uiTestHooks.OpenUri -is [scriptblock]) {
        & $script:uiTestHooks.OpenUri $address
        return $address
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $address
    $startInfo.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($startInfo)
    return $address
}

function Set-UiChannelPage {
    param([Parameter(Mandatory=$true)][int]$Delta)
    $pageCount = [Math]::Max(1,[int][Math]::Ceiling(@($script:channels).Count / 6.0))
    $script:channelPageIndex = [Math]::Max(0,[Math]::Min($pageCount - 1,([int]$script:channelPageIndex + $Delta)))
    Update-UiChannelDisplays
}

function Register-UiSetupLinks {
    if (-not $script:mainWindow) { return }
    foreach ($linkName in @('BmApiKeySetupLink','BmPasswordSetupLink')) {
        $setupLink = $script:mainWindow.FindName($linkName)
        if ($setupLink -is [System.Windows.Documents.Hyperlink]) {
            $setupLink.Add_Click({
                param($sender,$eventArgs)
                try { Open-UiSetupPage -Kind ([string]$sender.Tag) | Out-Null }
                catch { Set-MainText -Name 'FooterText' -Text '无法打开设置页面。' }
            })
        }
    }
}

function Get-SettingsControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = if ($script:mainWindow) { $script:mainWindow.FindName($Name) } else { $null }
    if ($null -eq $control -and $script:settingsWindow) { $control = $script:settingsWindow.FindName($Name) }
    if ($null -eq $control) { throw "界面缺少控件 $Name。" }
    return $control
}

function Initialize-UiConsoleTestFixture {
    if (-not $script:mainWindow) { throw '主控制台尚未创建。' }
    if (-not $script:mainWindow.IsVisible) { $script:mainWindow.Show() }
    if (-not $script:settingsWindow) { Initialize-SettingsWindow | Out-Null }
    $script:mainWindow.UpdateLayout()
    return $script:mainWindow
}

function Get-UiChannelKey {
    param([Parameter(Mandatory=$true)][object]$Channel)
    return ('{0}:{1}:{2}' -f [string]$Channel.kind,[uint64]$Channel.id,[int]$Channel.slot)
}

function Get-UiChannelTarget {
    param([Parameter(Mandatory=$true)][object]$Channel)
    return [pscustomobject][ordered]@{
        destination_id=[uint64]$Channel.id; kind=[string]$Channel.kind; slot=[uint64]$Channel.slot
    }
}

function Get-UiChannelByKey {
    param([string]$Key,[object[]]$Channels=@($script:channels))
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    foreach ($channel in $Channels) {
        if ((Get-UiChannelKey -Channel $channel) -ceq $Key) { return $channel }
    }
    return $null
}

function Get-UiNativeRxPolicyForChannels {
    param([object[]]$Channels=@($script:channels),[hashtable]$MutedKeys=$script:mutedChannelKeys)
    $active = @($Channels | Where-Object { -not $MutedKeys.ContainsKey((Get-UiChannelKey -Channel $_)) })
    $groups = @($active | Where-Object { [string]$_.kind -ceq 'group' } | ForEach-Object {
        [pscustomobject][ordered]@{ destination_id=[uint64]$_.id; slot=[uint64]$_.slot }
    })
    $peers = @($active | Where-Object { [string]$_.kind -ceq 'private' } | ForEach-Object {
        [pscustomobject][ordered]@{
            source_id=[uint64]$_.id; local_destination_id=[uint64]$script:portableConfig.connection.source_id; slot=[uint64]$_.slot
        }
    })
    $blocked = @()
    if ($script:portableConfig -and $script:portableConfig.routing) { $blocked = @($script:portableConfig.routing.blocked_source_ids) }
    return [pscustomobject][ordered]@{
        group_mode='selected'; private_mode=$(if ($peers.Count -gt 0) { 'selected_peers' } else { 'disabled' })
        allow_groups=$groups; allow_private_peers=$peers; local_private_routes=@(); blocked_groups=@(); blocked_source_ids=$blocked
    }
}

function ConvertFrom-UiPortableConfigToProfile {
    param([Parameter(Mandatory=$true)][object]$Config)
    if (@($Config.channels).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$Config.tx_channel_id)) { return $null }
    $channel = Get-UiChannelByKey -Key ([string]$Config.tx_channel_id) -Channels @($Config.channels)
    if (-not $channel) { return $null }
    $connection = [pscustomobject][ordered]@{
        callsign=[string]$Config.connection.callsign; gateway_id=[string]$Config.connection.gateway_id
        source_id=[string]$Config.connection.source_id; master=[string]$Config.connection.master
        master_port=[string]$Config.connection.master_port; color_code=[string]$Config.connection.color_code
    }
    $devices = [pscustomobject][ordered]@{
        serial_port=[string]$Config.devices.hri_port
        wave_in_endpoint_id=[string]$Config.devices.wave_in_endpoint_id
        wave_out_endpoint_id=[string]$Config.devices.wave_out_endpoint_id
    }
    return ConvertTo-BridgeUserConnectionProfile -Connection $connection -TxTarget (Get-UiChannelTarget -Channel $channel) `
        -Devices $devices -RxPolicy (Get-UiNativeRxPolicyForChannels -Channels @($Config.channels)) `
        -TransmitEnabled $true -AllowTextNumbers
}

function Save-UiPortableConfig {
    if (-not $script:portableConfig) { throw '统一配置尚未加载。' }
    $script:portableConfig.channels = [object[]]@($script:channels)
    $script:portableConfig.tx_channel_id = [string]$script:txChannelKey
    $script:portableConfig.ui.bm_server_selection_id = [string]$script:bmServerSelectionPreferenceId
    $script:portableConfig.devices.cat_stop_bits = 'Two'
    $saved = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    if ($saved) { $script:portableConfig = $saved }
    $script:storedProfile = $null
    $connection = $script:portableConfig.connection
    if (@($script:channels).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$script:txChannelKey) -and
        -not [string]::IsNullOrWhiteSpace([string]$connection.callsign) -and
        [uint64]$connection.gateway_id -gt 0 -and [uint64]$connection.source_id -gt 0 -and [uint64]$connection.color_code -le 15) {
        try { $script:storedProfile = ConvertFrom-UiPortableConfigToProfile -Config $script:portableConfig } catch { $script:storedProfile = $null }
    }
    Update-UiChannelDisplays
    return $true
}

function Clear-UiTransientStatus {
    param([AllowEmptyString()][string]$IfMessageContains='',[AllowEmptyString()][string]$IfMessagePattern='')
    if ($IfMessageContains -and -not ([string]$script:transientStatusText).Contains($IfMessageContains)) { return $false }
    if ($IfMessagePattern -and [string]$script:transientStatusText -cnotmatch $IfMessagePattern) { return $false }
    $script:transientStatusText = ''
    $script:transientStatusFailed = $false
    $script:transientStatusDeadlineUtc = [DateTime]::MinValue
    $control = if ($script:mainWindow) { $script:mainWindow.FindName('TransientStatusText') } else { $null }
    if ($control) {
        $control.Text = ''
        $control.ToolTip = ''
        $control.Visibility = [System.Windows.Visibility]::Collapsed
    }
    return $true
}

function Set-UiTransientStatus {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
        [bool]$Failed=$false,
        [switch]$Restart
    )
    $originalMessage = ([string]$Message).Trim() -replace 'CAT-1','电台控制'
    $value = $originalMessage
    if (-not $value) { [void](Clear-UiTransientStatus); return }
    if ($value.Length -gt 180) { $value = $value.Substring(0,177) + '…' }
    $now = [DateTime]::UtcNow
    $isNewMessage = ($value -cne [string]$script:transientStatusLastMessage)
    if (-not $isNewMessage -and -not $Restart -and [string]$script:transientStatusText -cne $value) { return }
    if ($isNewMessage -or $Restart) { $script:transientStatusLastMessage = $value }
    $script:transientStatusText = $value
    $script:transientStatusFailed = [bool]$Failed
    if ($isNewMessage -or $Restart) { $script:transientStatusDeadlineUtc = $now.AddSeconds(5) }
    $control = if ($script:mainWindow) { $script:mainWindow.FindName('TransientStatusText') } else { $null }
    if ($control) {
        $control.Text = $value
        $control.ToolTip = $originalMessage
        $control.Foreground = if ($Failed) { [Windows.Media.Brushes]::IndianRed } else { [Windows.Media.Brushes]::LightGreen }
        $control.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Update-UiTransientStatusExpiry {
    if ($script:transientStatusText -and [DateTime]::UtcNow -ge $script:transientStatusDeadlineUtc) {
        [void](Clear-UiTransientStatus)
    }
}

function Set-MainText {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $value = ([string]$Text).Trim()
    if ($Name -ceq 'AudioValue' -and $value -ceq '未知') { $value = '' }
    if ($Name -cin @('FooterText','ChannelStatusText','BmStaticGroupStatus','PlaybackGainStatusValue')) {
        Set-UiTransientStatus -Message $value
        return
    }
    $control = if ($script:mainWindow) { $script:mainWindow.FindName($Name) } else { $null }
    if (-not $control) { return }
    $control.Text = $value
    if ($Name -ceq 'BmValue' -and $script:mainWindow) {
        $card = $script:mainWindow.FindName('BmStatusCard')
        if ($card) { $card.Visibility = if ($value) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    }
}

function Add-UiEvent {
    param([Parameter(Mandatory=$true)][string]$Text)
    if (-not $script:mainWindow) { return }
    Set-UiTransientStatus -Message $Text -Restart
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

function Set-OfflineDisplay {
    param([string]$Reason = '核心尚未启动。')
    $script:latestStatus = $null
    $script:lastStatusUtc = [DateTime]::MinValue
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
    Set-MainText -Name 'FooterText' -Text $Reason
    Set-MainText -Name 'CallTargetStatusValue' -Text ''
    Set-MainText -Name 'ActiveLeaseValue' -Text ''
    Set-MainText -Name 'RunValue' -Text '未启动'
    Set-MainText -Name 'FreshnessValue' -Text ''
    Update-UiReceiveMetricsDisplay -Record $null
    Update-CallTargetChoices
    Update-UiIdentityActionState
}

function Format-ProfileTarget {
    param([object]$Profile)
    if ($null -eq $Profile) { return '尚未设置' }
    $target = $Profile.tx_target
    if ($target.kind -ceq 'private') {
        return ('单呼目标 {0}' -f $target.destination_id)
    }
    return ('TG {0}' -f $target.destination_id)
}

function Format-ProfileReceiveTarget {
    param([object]$Profile)
    if ($null -eq $Profile -or $null -eq $Profile.rx_policy) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    $policy = $Profile.rx_policy
    if ($policy.group_mode -ceq 'all_delivered') { $parts.Add('全部组呼') }
    elseif (@($policy.allow_groups).Count -eq 0) { $parts.Add('未选组呼') }
    else {
        $groupText = @($policy.allow_groups | ForEach-Object { 'TG {0}' -f $_.destination_id }) -join '、'
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

function Set-MainTargetSummary {
    param([object]$Profile, [string]$OverallLabel)
    return
}

function Format-UiTxTarget {
    param([Parameter(Mandatory=$true)][object]$Target)
    if ([string]$Target.kind -ceq 'private') { return ('单呼目标 {0}' -f $Target.destination_id) }
    return ('TG {0}' -f $Target.destination_id)
}

function Format-UiRouteTarget {
    param([object]$Target)
    if ($null -eq $Target) { return '无' }
    if ([string]$Target.kind -ceq 'private') { return ('私呼 {0}' -f $Target.destination_id) }
    return ('TG {0}' -f $Target.destination_id)
}

function Format-UiGainMilli {
    param([object]$GainMilli)
    if ($null -eq $GainMilli -or $GainMilli -is [bool]) { return '未知' }
    $parsed = [uint32]0
    if (-not [uint32]::TryParse([string]$GainMilli,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$parsed) -or $parsed -lt 1000 -or $parsed -gt 16000 -or ($parsed % 1000) -ne 0) { return '未知' }
    return (([double]$parsed / 1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture) + 'x')
}

function Convert-UiGainSliderToMilli {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -lt 1.0 -or $Value -gt 16.0 -or
        [Math]::Abs($Value - [Math]::Round($Value,0,[MidpointRounding]::AwayFromZero)) -gt 0.000001) {
        throw '音量增益必须是 1x 到 16x 的整数。'
    }
    return [uint32]([Math]::Round($Value,0,[MidpointRounding]::AwayFromZero) * 1000)
}

function Convert-UiStoredGainToMilli {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -lt 0.25 -or $Value -gt 16.0) {
        throw '已保存的音量增益超出可读取范围。'
    }
    $integerValue = [Math]::Max(1,[Math]::Min(16,[Math]::Round($Value,0,[MidpointRounding]::AwayFromZero)))
    return Convert-UiGainSliderToMilli -Value ([double]$integerValue)
}

function Copy-UiRxPolicy {
    param([Parameter(Mandatory=$true)][object]$Policy)
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

function Get-UiDefaultRadioControlPreferences {
    $config = $script:portableConfig
    if (-not $config) {
        try {
            $defaultProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-default-config-' + [guid]::NewGuid().ToString('N') + '.json')
            $config = Get-WirexPortableConfig -Path $defaultProbe
        } catch { $config = $null }
    }
    return [pscustomobject][ordered]@{
        schema_version=1
        cat_port=$(if ($config) { [string]$config.devices.cat_port } else { 'auto' })
        baud_rate=$(if ($config) { [int]$config.devices.cat_baud_rate } else { 38400 })
        stop_bits='Two'
        desired_power_watts=$(if ($config) { [int]$config.devices.desired_power_watts } else { 25 })
    }
}

function Update-UiPlaybackGainDisplay {
    param([object]$Record=$null)
    $runtimeText = ''
    $runtimeGain = $null
    if ($script:audioGainNativeCapability -and $script:audioGainActual) {
        $playback = Format-UiGainMilli -GainMilli $script:audioGainActual.radio_playback_gain_milli
        $transmit = Format-UiGainMilli -GainMilli $script:audioGainActual.mic_transmit_gain_milli
        $runtimeGain = [uint32]$script:audioGainActual.radio_playback_gain_milli
        $runtimeText = ('播放 {0} · 发送 {1}' -f $playback,$transmit)
    } elseif ($Record) {
        $gainProperty = $Record.PSObject.Properties['rx_output_gain_milli']
        if ($gainProperty) {
            $gainLabel = Format-UiGainMilli -GainMilli $gainProperty.Value
            if ($gainLabel -cne '未知') {
                $runtimeGain = [uint32]$gainProperty.Value
                $runtimeText = '增益 ' + $gainLabel
            }
        }
    }
    $script:reportedPlaybackGainMilli = $runtimeGain
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
            $runtimeControl.Foreground = [Windows.Media.Brushes]::LightGreen
        }
    }
}

function Get-UiCallHistoryModel {
    if ($null -eq $script:callHistoryModel) {
        $script:callHistoryModel = New-Object 'System.Collections.Generic.List[object]'
    }
    return ,$script:callHistoryModel
}

function Get-UiCallHistorySelectedKey {
    if (-not $script:mainWindow) { return [string]$script:selectedCallHistoryKey }
    $history = $script:mainWindow.FindName('CallHistoryList')
    if ($history -and $history.SelectedItem -and $history.SelectedItem.PSObject.Properties['key']) {
        $script:selectedCallHistoryKey = [string]$history.SelectedItem.key
    }
    return [string]$script:selectedCallHistoryKey
}

function Update-UiCallHistoryPageControls {
    if (-not $script:mainWindow) { return }
    $model = Get-UiCallHistoryModel
    $pageSize = 5
    $pageCount = [Math]::Max(1,[int][Math]::Ceiling($model.Count / [double]$pageSize))
    $script:callHistoryPageIndex = [Math]::Max(0,[Math]::Min([int]$script:callHistoryPageIndex,$pageCount - 1))
    $previous = $script:mainWindow.FindName('CallHistoryPagePreviousButton')
    $next = $script:mainWindow.FindName('CallHistoryPageNextButton')
    $label = $script:mainWindow.FindName('CallHistoryPageText')
    if ($previous) { $previous.IsEnabled = ($pageCount -gt 1 -and $script:callHistoryPageIndex -gt 0) }
    if ($next) { $next.IsEnabled = ($pageCount -gt 1 -and $script:callHistoryPageIndex -lt $pageCount - 1) }
    if ($label) { $label.Text = ('{0} / {1}' -f ($script:callHistoryPageIndex + 1),$pageCount) }
}

function Render-UiCallHistoryPage {
    if (-not $script:mainWindow) { return }
    $history = $script:mainWindow.FindName('CallHistoryList')
    if (-not $history) { return }
    $model = Get-UiCallHistoryModel
    $pageSize = 5
    Update-UiCallHistoryPageControls
    $start = [int]$script:callHistoryPageIndex * $pageSize
    $end = [Math]::Min($model.Count,$start + $pageSize)
    $script:historyPageRendering = $true
    try {
        $history.Items.Clear()
        for ($index=$start; $index -lt $end; $index++) { [void]$history.Items.Add($model[$index]) }
        if ($script:selectedCallHistoryKey) {
            for ($index=0; $index -lt $history.Items.Count; $index++) {
                if ([string]$history.Items[$index].key -ceq [string]$script:selectedCallHistoryKey) {
                    $history.SelectedIndex = $index
                    break
                }
            }
        }
    } finally { $script:historyPageRendering = $false }
    Update-UiCallHistoryPageControls
    Update-UiCallHistoryActionState
}

function Set-UiCallHistoryPage {
    param([Parameter(Mandatory=$true)][int]$Delta)
    if (-not $script:mainWindow) { return }
    [void](Get-UiCallHistorySelectedKey)
    $script:callHistoryPageIndex += $Delta
    Render-UiCallHistoryPage
}

function Set-UiCallHistoryPageForKey {
    param([AllowEmptyString()][string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { $script:callHistoryPageIndex = 0; return }
    $model = Get-UiCallHistoryModel
    for ($index=0; $index -lt $model.Count; $index++) {
        if ([string]$model[$index].key -ceq $Key) {
            $script:callHistoryPageIndex = [int][Math]::Floor($index / 5.0)
            return
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
    $isListenOnly = $false
    $button.IsEnabled = ($valid -and -not $script:pendingRoutingMutation -and -not $script:routingMutationFence)
    $button.ToolTip = '仅当该ID和类型已经在频道列表中时，才能设为PTT目标。'
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

function Get-UiNativeIdentityCallsign {
    param([Parameter()][AllowNull()][object]$Value)
    if (-not $script:radioIdentityModuleLoaded -or
        -not (Get-Command -Name ConvertTo-RadioIdentityNativeCallsign -ErrorAction SilentlyContinue)) { return $null }
    return ConvertTo-RadioIdentityNativeCallsign -Value $Value
}

function Save-UiNativeIdentityDeferredMapping {
    param([Parameter(Mandatory=$true)][object]$Mapping)
    if (-not $script:identityNativeDeferredBySource) { $script:identityNativeDeferredBySource = @{} }
    if ($null -eq $script:identityNativeDeferredOrder) {
        $script:identityNativeDeferredOrder = New-Object 'System.Collections.Generic.List[string]'
    }
    if (-not $Mapping -or -not $Mapping.PSObject.Properties['source_id'] -or
        -not $Mapping.PSObject.Properties['callsign']) { return $false }
    $sourceId = [uint64]$Mapping.source_id
    if ($sourceId -lt 1 -or $sourceId -gt 16777215) { return $false }
    $key = $sourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $normalizedCallsign = if ($null -eq $Mapping.callsign) { $null } else { Get-UiNativeIdentityCallsign -Value $Mapping.callsign }
    if ($null -ne $Mapping.callsign -and $null -eq $normalizedCallsign) { return $false }
    $stored = [pscustomobject][ordered]@{ source_id=$sourceId; callsign=$normalizedCallsign }
    if ($script:identityNativeDeferredBySource.ContainsKey($key)) {
        [void]$script:identityNativeDeferredOrder.Remove($key)
    } elseif ($script:identityNativeDeferredOrder.Count -ge 128) {
        $evictedKey = $script:identityNativeDeferredOrder[0]
        $script:identityNativeDeferredOrder.RemoveAt(0)
        [void]$script:identityNativeDeferredBySource.Remove($evictedKey)
    }
    $script:identityNativeDeferredBySource[$key] = $stored
    $script:identityNativeDeferredOrder.Add($key)
    return $true
}

function Test-AndMarkUiNativeIdentityCallRefresh {
    param([Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][uint64]$Generation,
        [Parameter(Mandatory=$true)][uint64]$SourceId)
    if ($Generation -eq 0 -or $SourceId -lt 1 -or $SourceId -gt 16777215 -or
        [string]::IsNullOrWhiteSpace($RunId)) { return $false }
    if (-not $script:identityNativeCallRefreshKeys) { $script:identityNativeCallRefreshKeys = @{} }
    if ($null -eq $script:identityNativeCallRefreshOrder) {
        $script:identityNativeCallRefreshOrder = New-Object 'System.Collections.Generic.List[string]'
    }
    $key = '{0}|{1}|{2}' -f $RunId,$Generation.ToString([Globalization.CultureInfo]::InvariantCulture),
        $SourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($script:identityNativeCallRefreshKeys.ContainsKey($key)) { return $false }
    if ($script:identityNativeCallRefreshOrder.Count -ge 128) {
        $oldestKey = $script:identityNativeCallRefreshOrder[0]
        $script:identityNativeCallRefreshOrder.RemoveAt(0)
        [void]$script:identityNativeCallRefreshKeys.Remove($oldestKey)
    }
    $script:identityNativeCallRefreshKeys[$key] = $true
    $script:identityNativeCallRefreshOrder.Add($key)
    return $true
}

function Add-UiNativeIdentityMappingToQueue {
    param([Parameter(Mandatory=$true)][uint64]$SourceId,[Parameter()][AllowNull()][object]$Callsign,[switch]$Remove)
    if ($SourceId -lt 1 -or $SourceId -gt 16777215) { return $false }
    $normalizedCallsign = if ($Remove) { $null } else { Get-UiNativeIdentityCallsign -Value $Callsign }
    if (-not $Remove -and $null -eq $normalizedCallsign) { return $false }
    $mapping = [pscustomobject][ordered]@{ source_id=$SourceId; callsign=$normalizedCallsign }
    if ([string]::IsNullOrWhiteSpace($script:identityNativeRunId)) {
        return Save-UiNativeIdentityDeferredMapping -Mapping $mapping
    }
    if (-not $script:identityNativeCapability -or $script:identityNativeRunId -cne $script:controlRunId) {
        [void](Save-UiNativeIdentityDeferredMapping -Mapping $mapping)
        return $false
    }
    for ($index = 0; $index -lt $script:identityNativeQueue.Count; $index++) {
        if ([uint64]$script:identityNativeQueue[$index].source_id -eq $SourceId) {
            $script:identityNativeQueue[$index] = $mapping
            return $true
        }
    }
    if ($script:identityNativeQueue.Count -ge 128) { $script:identityNativeQueue.RemoveAt(0) }
    $script:identityNativeQueue.Add($mapping)
    [void](Start-NextUiNativeIdentityUpdate)
    return $true
}

function Initialize-UiNativeIdentitySync {
    if (-not $script:identityNativeCapability -or -not $script:controlConfirmed -or
        [string]::IsNullOrWhiteSpace($script:controlRunId)) { return $false }
    if ($script:identityNativeRunId -ceq $script:controlRunId) { return $true }
    $script:identityNativeRunId = [string]$script:controlRunId
    $script:identityNativeRevision = [uint64]0
    $script:identityNativeQueue.Clear()
    $script:identityNativeInFlight = $null
    $script:expiredIdentityNativeRequests = @{}
    if ($script:radioIdentityModuleLoaded -and
        (Get-Command -Name Get-RadioIdentityNativeMappings -ErrorAction SilentlyContinue)) {
        try {
            foreach ($mapping in @(Get-RadioIdentityNativeMappings -CachePath $script:identityCachePath -Limit 128)) {
                [void](Add-UiNativeIdentityMappingToQueue -SourceId ([uint64]$mapping.source_id) -Callsign ([string]$mapping.callsign))
            }
        } catch {
            Add-UiIdentityDiagnostic -Stage 'native_cache_load' -ErrorCode 'cache_read' `
                -ErrorType $_.Exception.GetType().FullName -Detail $_.Exception.Message
        }
    }
    foreach ($key in $script:identityNativeDeferredOrder.ToArray()) {
        if (-not $script:identityNativeDeferredBySource.ContainsKey($key)) { continue }
        $mapping = $script:identityNativeDeferredBySource[$key]
        [void](Add-UiNativeIdentityMappingToQueue -SourceId ([uint64]$mapping.source_id) -Callsign $mapping.callsign `
            -Remove:($null -eq $mapping.callsign))
    }
    $script:identityNativeDeferredBySource = @{}
    $script:identityNativeDeferredOrder.Clear()
    [void](Start-NextUiNativeIdentityUpdate)
    return $true
}

function Start-NextUiNativeIdentityUpdate {
    if (-not $script:identityNativeCapability -or -not $script:controlConfirmed -or
        [string]::IsNullOrWhiteSpace($script:identityNativeRunId) -or
        $script:identityNativeRunId -cne $script:controlRunId -or
        -not $script:supervisor -or $script:supervisor.HasExited -or
        $script:identityNativeInFlight -or $script:identityNativeQueue.Count -eq 0) { return $false }
    if ($script:identityNativeRevision -eq [uint64]::MaxValue) {
        $script:identityNativeQueue.Clear()
        return $false
    }
    $mapping = $script:identityNativeQueue[0]
    $script:identityNativeQueue.RemoveAt(0)
    $revision = [uint64]($script:identityNativeRevision + [uint64]1)
    $requestId = 'radioid-' + $revision.ToString([Globalization.CultureInfo]::InvariantCulture)
    $parametersJson = ConvertTo-Json -InputObject ([ordered]@{
        source_id=[uint64]$mapping.source_id; revision=$revision; callsign=$mapping.callsign
    }) -Depth 4 -Compress
    $pending = [pscustomobject][ordered]@{
        request_id=$requestId; run_id=[string]$script:identityNativeRunId
        revision=$revision; source_id=[uint64]$mapping.source_id; callsign=$mapping.callsign
        sent_utc=[DateTime]::UtcNow
    }
    $script:pendingControlRequests[$requestId] = 'radio_identity.cache_upsert'
    $script:identityNativeInFlight = $pending
    if (-not $script:supervisor.SendControlCommand($requestId,'radio_identity.cache_upsert',$parametersJson)) {
        [void]$script:pendingControlRequests.Remove($requestId)
        $script:identityNativeInFlight = $null
        [void](Save-UiNativeIdentityDeferredMapping -Mapping $mapping)
        foreach ($queuedMapping in $script:identityNativeQueue.ToArray()) {
            [void](Save-UiNativeIdentityDeferredMapping -Mapping $queuedMapping)
        }
        $script:identityNativeQueue.Clear()
        $script:identityNativeCapability = $false
        return $false
    }
    $script:identityNativeRevision = $revision
    return $true
}

function Complete-UiNativeIdentityUpdate {
    param([Parameter(Mandatory=$true)][object]$Record)
    $pending = $script:identityNativeInFlight
    if (-not $pending -or [string]$Record.command -cne 'radio_identity.cache_upsert' -or
        [string]$Record.request_id -cne [string]$pending.request_id -or
        [string]$Record.run_id -cne [string]$pending.run_id -or
        [string]$Record.run_id -cne [string]$script:identityNativeRunId) { return $false }
    $script:identityNativeInFlight = $null
    if ([string]$Record.result -cne 'ok') {
        $errorCode = if ($Record.PSObject.Properties['error']) { [string]$Record.error } else { 'native_rejected' }
        Add-UiIdentityDiagnostic -Stage 'native_cache_update' -ErrorCode $errorCode
        [void](Save-UiNativeIdentityDeferredMapping -Mapping ([pscustomobject][ordered]@{
            source_id=[uint64]$pending.source_id; callsign=$pending.callsign
        }))
        foreach ($queuedMapping in $script:identityNativeQueue.ToArray()) {
            [void](Save-UiNativeIdentityDeferredMapping -Mapping $queuedMapping)
        }
        $script:identityNativeCapability = $false
        $script:identityNativeQueue.Clear()
        return $true
    }
    [void](Start-NextUiNativeIdentityUpdate)
    return $true
}

function Expire-UiNativeIdentityUpdate {
    $pending = $script:identityNativeInFlight
    if (-not $pending -or -not $pending.PSObject.Properties['sent_utc'] -or
        ([DateTime]::UtcNow - [DateTime]$pending.sent_utc).TotalSeconds -lt 5) { return $false }
    $requestKey = ([string]$pending.run_id + '|' + [string]$pending.request_id)
    $script:expiredIdentityNativeRequests[$requestKey] = $true
    if ($script:expiredIdentityNativeRequests.Count -gt 128) {
        $oldestExpired = @($script:expiredIdentityNativeRequests.Keys | Select-Object -First 1)
        if ($oldestExpired.Count -gt 0) { [void]$script:expiredIdentityNativeRequests.Remove([string]$oldestExpired[0]) }
    }
    [void]$script:pendingControlRequests.Remove([string]$pending.request_id)
    [void](Save-UiNativeIdentityDeferredMapping -Mapping ([pscustomobject][ordered]@{
        source_id=[uint64]$pending.source_id; callsign=$pending.callsign
    }))
    foreach ($queuedMapping in $script:identityNativeQueue.ToArray()) {
        [void](Save-UiNativeIdentityDeferredMapping -Mapping $queuedMapping)
    }
    $script:identityNativeQueue.Clear()
    $script:identityNativeInFlight = $null
    $script:identityNativeCapability = $false
    Add-UiIdentityDiagnostic -Stage 'native_cache_update' -ErrorCode 'ack_timeout'
    return $true
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

function Add-UiQuickCallDiagnostic {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory=$true)][uint64]$DestinationId,
        [Parameter(Mandatory=$true)][ValidateRange(1,2)][int]$Slot,
        [Parameter(Mandatory=$true)][ValidateSet('clicked','queued','cancelled','submitted','ok','rejected','unsupported','timeout','stale')][string]$Result,
        [Parameter()][AllowEmptyString()][string]$ErrorCode='',
        [Parameter()][AllowEmptyString()][string]$ActivationStatus='',
        [Parameter()][AllowNull()][object]$FramesSent,
        [Parameter()][bool]$Replayed=$false
    )
    try {
        if ($script:isolatedUiMode -or $script:controlDiagnostic -or [string]::IsNullOrWhiteSpace($script:quickCallDiagnosticPath)) { return $false }
        $requestGuid = [guid]::Empty
        if (($RunId -and $RunId -cnotmatch '^[0-9]{1,10}-[0-9]{1,20}$') -or
            ($RequestId -and -not [guid]::TryParse($RequestId,[ref]$requestGuid)) -or
            $DestinationId -lt 1 -or $DestinationId -gt 16777215 -or $DestinationId -eq 4000) { return $false }
        $directory = [System.IO.Path]::GetDirectoryName($script:quickCallDiagnosticPath)
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [System.IO.Directory]::Exists($directory)) { return $false }
        $safeError = if (-not $ErrorCode) { '' } elseif ($ErrorCode -cmatch '^[a-z0-9_]{1,64}$') { $ErrorCode } else { 'unknown_error' }
        $safeActivation = if ($ActivationStatus -ceq 'request_sent') { 'request_sent' } else { '' }
        $safeFrames = $null
        if ($FramesSent -is [byte] -or $FramesSent -is [int16] -or $FramesSent -is [uint16] -or
            $FramesSent -is [int32] -or $FramesSent -is [uint32] -or $FramesSent -is [int64] -or $FramesSent -is [uint64]) {
            $safeFrames = [uint64]$FramesSent
        }
        $record = [pscustomobject][ordered]@{
            timestamp_utc=[DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            run_id=$RunId; request_id=$RequestId; destination_id=$DestinationId; slot=$Slot
            result=$Result; error_code=$safeError; activation_status=$safeActivation; frames_sent=$safeFrames; replayed=[bool]$Replayed
        }
        $line = ConvertTo-Json -InputObject $record -Compress -Depth 3
        $encodedLine = $line + [Environment]::NewLine
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $addedBytes = $encoding.GetByteCount($encodedLine)
        $existingBytes = if ([System.IO.File]::Exists($script:quickCallDiagnosticPath)) {
            (New-Object System.IO.FileInfo($script:quickCallDiagnosticPath)).Length
        } else { [int64]0 }
        if ($existingBytes + $addedBytes -gt 262144) { return $false }
        [System.IO.File]::AppendAllText($script:quickCallDiagnosticPath,$encodedLine,$encoding)
        return $true
    } catch { return $false }
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
    $model = Get-UiCallHistoryModel
    for ($index=0; $index -lt $model.Count; $index++) {
        $entry = $model[$index]
        if ([string]$entry.key -cne $HistoryKey) { continue }
        $entry.source_label = Format-UiRadioIdentity -RadioId ([uint64]$entry.source_id)
        $entry.identity_details = Format-UiRadioIdentityDetails -RadioId ([uint64]$entry.source_id) -Identity $Identity
        $kindText = if ([string]$entry.kind -ceq 'private') { '私呼 至本机 DMR ID ' + $entry.destination_id } else { '组呼 TG ' + $entry.destination_id }
        $entry.text = ('{0} · {1} · 来源 {2}' -f $entry.timestamp.ToString('HH:mm:ss'),$kindText,$entry.source_label)
        $model[$index] = $entry
        Render-UiCallHistoryPage
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
            Update-UiChannelDisplays
            if ([string]$identity.status -ceq 'found') {
                $nativeCallsign = Get-UiNativeIdentityCallsign -Value $identity.callsign
                if ($null -eq $nativeCallsign) {
                    [void](Add-UiNativeIdentityMappingToQueue -SourceId ([uint64]$query.radio_id) -Remove)
                } else {
                    [void](Add-UiNativeIdentityMappingToQueue -SourceId ([uint64]$query.radio_id) -Callsign $nativeCallsign)
                }
            } elseif ([string]$identity.status -ceq 'not_found') {
                [void](Add-UiNativeIdentityMappingToQueue -SourceId ([uint64]$query.radio_id) -Remove)
            }
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
            $hasHistory = ((Get-UiCallHistoryModel).Count -gt 0)
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
    if (Test-AndMarkUiNativeIdentityCallRefresh -RunId $runId -Generation $generation -SourceId $sourceId) {
        $cachedIdentity = $null
        if ($script:radioIdentityModuleLoaded -and
            (Get-Command -Name Resolve-RadioIdentity -ErrorAction SilentlyContinue)) {
            try { $cachedIdentity = Resolve-RadioIdentity -RadioId ([uint32]$sourceId) -CachePath $script:identityCachePath }
            catch { $cachedIdentity = $null }
        }
        if ($cachedIdentity -and [string]$cachedIdentity.status -ceq 'found') {
            $nativeCallsign = Get-UiNativeIdentityCallsign -Value $cachedIdentity.callsign
            if ($null -eq $nativeCallsign) {
                [void](Add-UiNativeIdentityMappingToQueue -SourceId $sourceId -Remove)
            } else {
                [void](Add-UiNativeIdentityMappingToQueue -SourceId $sourceId -Callsign $nativeCallsign)
            }
        } elseif ($cachedIdentity -and [string]$cachedIdentity.status -ceq 'not_found') {
            [void](Add-UiNativeIdentityMappingToQueue -SourceId $sourceId -Remove)
        }
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
        text=('{0} · {1} {2} · 来源 {3}' -f $timestamp.ToString('HH:mm:ss'),$kindText,$targetText,$sourceLabel)
    }
    $model = Get-UiCallHistoryModel
    $selectedKey = Get-UiCallHistorySelectedKey
    $script:callHistoryKeys[$key] = $true
    Clear-UiIdentityError
    $model.Insert(0,$entry)
    Set-UiIdentityRowVisibility -Row 'current'
    Set-UiIdentityRowVisibility -Row 'history'
    while ($model.Count -gt 50) {
        $oldest = $model[$model.Count - 1]
        if ($oldest -and $oldest.PSObject.Properties['key']) { [void]$script:callHistoryKeys.Remove([string]$oldest.key) }
        $model.RemoveAt($model.Count - 1)
    }
    if ($selectedKey -and -not $script:callHistoryKeys.ContainsKey($selectedKey)) { $selectedKey = '' }
    if (-not $selectedKey) { $script:selectedCallHistoryKey = $key; $script:callHistoryPageIndex = 0 }
    else {
        $script:selectedCallHistoryKey = $selectedKey
        Set-UiCallHistoryPageForKey -Key $selectedKey
    }
    Render-UiCallHistoryPage
    Set-UiIdentityRowVisibility -Row 'history_actions' -Visibility $(if ($model.Count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
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
    Update-UiChannelDisplays
}

function Set-UiChannelStatus {
    param([string]$Text,[bool]$Failed=$false)
    Set-UiTransientStatus -Message $Text -Failed $Failed -Restart
}

function New-UiChannelRecord {
    param([object]$Id,[string]$Kind,[uint64]$Slot,[string]$Name='')
    $idValue = [uint64]0
    if (-not [uint64]::TryParse([string]$Id,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$idValue) -or
        $idValue -lt 1 -or $idValue -gt 16777215 -or $Kind -cnotin @('group','private') -or $Slot -notin @(1,2)) {
        throw '频道网络参数无效。'
    }
    $label = ([string]$Name).Trim()
    if (-not $label) {
        $label = Get-UiKnownChannelName -Id $idValue -Kind $Kind
        if (-not $label) { $label = $idValue.ToString([Globalization.CultureInfo]::InvariantCulture) }
    }
    return [pscustomobject][ordered]@{ id=$idValue; kind=$Kind; slot=[int]$Slot; name=$label }
}

function Get-UiKnownChannelName {
    param([Parameter(Mandatory=$true)][uint64]$Id,[Parameter(Mandatory=$true)][string]$Kind)
    if ($Kind -ceq 'group' -and $Id -eq 91) { return 'World-wide' }
    if ($Kind -ceq 'group' -and $Id -eq 46001) { return '全国' }
    if ($Kind -ceq 'private' -and $Id -eq 460997) { return '中国鹦鹉' }
    return ''
}

function Get-UiChannelDisplayName {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $name = ([string]$Channel.name).Trim()
    if ($name -and $name -cne [string]$Channel.id) { return $name }
    return Get-UiKnownChannelName -Id ([uint64]$Channel.id) -Kind ([string]$Channel.kind)
}

function Test-UiBmStaticChannelReadback {
    param([Parameter(Mandatory=$true)][object]$Channel)
    if ([string]$Channel.kind -cne 'group' -or [string]$script:bmManagementStatus -cne 'loaded' -or
        -not (Get-Command -Name Get-BmManagementUiDeviceId -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name Get-BmManagementUiApiKey -ErrorAction SilentlyContinue)) { return $false }
    try {
        $deviceId = [string](Get-BmManagementUiDeviceId)
        $apiKey = [string](Get-BmManagementUiApiKey)
    } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($deviceId) -or [string]::IsNullOrWhiteSpace($apiKey) -or
        [string]$script:bmManagementObservedDeviceId -cne $deviceId -or
        [string]$script:bmManagementObservedApiKey -cne $apiKey) { return $false }
    $currentGroups = @($script:bmManagementGroups | Where-Object {
        [string]$_.type -ceq 'static' -and [string]$_.device_id -ceq $deviceId -and
        [uint64]$_.talkgroup -eq [uint64]$Channel.id
    })
    if (@($currentGroups | Where-Object { [int]$_.slot -eq [int]$Channel.slot }).Count -gt 0) { return $true }
    if (@($currentGroups | Where-Object { [int]$_.slot -eq 0 }).Count -eq 0) { return $false }

    # BM API slot 0 is specific to a simplex device profile. The current UI
    # channel list must identify exactly one software TS for this TG before
    # that API row can label a channel card; a duplicate TS is ambiguous.
    $context = $script:bmManagementAddContext
    if (-not $context -or -not [bool]$context.success -or [string]$context.device_id -cne $deviceId -or
        [int]$context.status -ne 4 -or [int]$context.add_slot -ne 0) { return $false }
    $softwareChannels = @($script:channels | Where-Object {
        [string]$_.kind -ceq 'group' -and [uint64]$_.id -eq [uint64]$Channel.id
    })
    return ($softwareChannels.Count -eq 1 -and [int]$softwareChannels[0].slot -eq [int]$Channel.slot)
}

function Get-UiChannelActivationPresentation {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $name = Get-UiChannelDisplayName -Channel $Channel
    $kindLabel = if ([string]$Channel.kind -ceq 'group') { '组呼' } else { '单呼' }
    $title = '{0} {1}' -f $kindLabel,[uint64]$Channel.id
    if ($name) { $title += ' · ' + $name }
    $request = $null
    $source = ''
    $sourceTooltip = ''
    if ([string]$Channel.kind -ceq 'group') {
        if (Test-UiBmStaticChannelReadback -Channel $Channel) {
            $source = '静态组'
            $sourceTooltip = ('TG {0} TS{1}；静态组已读取。' -f [uint64]$Channel.id,[int]$Channel.slot)
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:controlRunId) -and
            [string]$script:latestStatus.run_id -ceq [string]$script:controlRunId) {
            $request = Get-WirexChannelActivationRequestSent -State $script:channelActivationState `
                -RunId ([string]$script:controlRunId) -ChannelKey (Get-UiChannelKey -Channel $Channel) -Slot ([int]$Channel.slot)
            if ($request) {
                $source = '动态组'
                $sourceTooltip = ('TG {0} TS{1}；本机已发送上一条激活请求，BM 当前动态组状态未知。' -f [uint64]$Channel.id,[int]$Channel.slot)
            }
        }
    }
    if ($source) { $title += ' · ' + $source }
    $tooltip = $title
    if ($sourceTooltip) { $tooltip += "`n" + $sourceTooltip }
    return [pscustomobject][ordered]@{
        title=$title; tooltip=$tooltip; name=$name; source=$source
        is_bm_static=($source -ceq '静态组'); request_sent=($null -ne $request); request=$request
        channel_key=(Get-UiChannelKey -Channel $Channel); id=[uint64]$Channel.id; kind=[string]$Channel.kind; slot=[int]$Channel.slot
    }
}

function Get-UiChannelCurrentCall {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $record = $script:latestStatus
    if (-not $record -or -not [bool]$record.current_call_valid) { return $null }
    $channelKey = Get-UiChannelKey -Channel $Channel
    if ($script:mutedChannelKeys.ContainsKey($channelKey)) { return $null }
    $kind = if ([string]$record.current_call_kind -ceq 'P') { 'private' } else { 'group' }
    if ($kind -cne [string]$Channel.kind -or [uint64]$record.current_call_slot -ne [uint64]$Channel.slot) { return $null }
    if ($kind -ceq 'private') {
        if ([uint64]$record.current_call_source_id -ne [uint64]$Channel.id -or
            [uint64]$record.current_call_destination_id -ne [uint64]$script:portableConfig.connection.source_id) { return $null }
    } elseif ([uint64]$record.current_call_destination_id -ne [uint64]$Channel.id) { return $null }
    return $record
}

function Get-UiChannelCardPresentation {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $channelKey = Get-UiChannelKey -Channel $Channel
    $isSelectedTx = ([string]$script:txChannelKey -ceq $channelKey)
    $mediaOwner = if ($script:activeRouting) { [string]$script:activeRouting.media_owner } else { 'idle' }
    $activeTarget = if ($script:activeRouting -and $script:activeRouting.tx_target) { $script:activeRouting.tx_target } else { $null }
    $isActiveTx = $false
    if ($isSelectedTx -and @('tx_active','tx_draining') -ccontains $mediaOwner -and $activeTarget) {
        $activeKey = Get-UiChannelKey -Channel ([pscustomobject]@{
            id=[uint64]$activeTarget.destination_id; kind=[string]$activeTarget.kind; slot=[int]$activeTarget.slot
        })
        $isActiveTx = ($activeKey -ceq $channelKey)
    }
    $isMuted = $script:mutedChannelKeys.ContainsKey($channelKey)
    $background = if ($isActiveTx) { '#713237' }
        elseif ($isSelectedTx) { '#28583C' }
        elseif ($isMuted) { '#1A2023' }
        else { '#1D2529' }
    $callBackground = if ($isActiveTx) { '#60272D' }
        elseif ($isSelectedTx) { '#244C35' }
        elseif (Get-UiChannelCurrentCall -Channel $Channel) { '#17241D' }
        else { '#151C20' }
    return [pscustomobject][ordered]@{
        is_selected_tx=[bool]$isSelectedTx; is_active_tx=[bool]$isActiveTx; is_muted=[bool]$isMuted
        background=$background; border='#46545B'; call_background=$callBackground
    }
}

function Get-UiChannelCallerLabel {
    param([uint64]$RadioId)
    $key = $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $callsign = ''
    $personName = ''
    if ($script:callIdentityCache.ContainsKey($key)) {
        $identity = $script:callIdentityCache[$key]
        if ($identity -and [string]$identity.status -cin @('found','stale')) {
            $callsign = ([string]$identity.callsign).Trim()
            $personName = ([string]$identity.name).Trim()
        }
    }
    if ($callsign -and $personName -and $callsign -cne $personName) { return ($callsign + ' · ' + $personName) }
    if ($callsign) { return ($callsign + ' · DMR ID ' + $key) }
    if ($personName) { return ($personName + ' · DMR ID ' + $key) }
    return ('DMR ID ' + $key)
}

function Get-UiChannelCallerDetails {
    param([Parameter(Mandatory=$true)][uint64]$RadioId)
    $key = $RadioId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $callsign = ''
    $personName = ''
    if ($script:callIdentityCache.ContainsKey($key)) {
        $identity = $script:callIdentityCache[$key]
        if ($identity -and [string]$identity.status -cin @('found','stale')) {
            $callsign = ([string]$identity.callsign).Trim()
            $personName = ([string]$identity.name).Trim()
        }
    }
    $known = [bool]($callsign -or $personName)
    $primary = if ($callsign -and $personName -and $callsign -cne $personName) { $callsign + ' · ' + $personName }
        elseif ($callsign) { $callsign }
        elseif ($personName) { $personName }
        else { 'DMR ID ' + $key }
    return [pscustomobject][ordered]@{ primary=$primary; dmr_id=$key; callsign=$callsign; person_name=$personName; known=$known }
}

function New-UiDmIdLinkTextBlock {
    param([Parameter(Mandatory=$true)][string]$DmrId,[string]$Callsign='',[double]$FontSize=13)
    $textBlock = New-Object System.Windows.Controls.TextBlock
    $textBlock.FontSize = $FontSize
    $textBlock.Foreground = [Windows.Media.Brushes]::LightSkyBlue
    $textBlock.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    if (-not [string]::IsNullOrWhiteSpace($Callsign)) {
        $link = New-Object System.Windows.Documents.Hyperlink
        $profileBlue = [Windows.Media.BrushConverter]::new().ConvertFromString('#78B8FF')
        $link.Foreground = $profileBlue
        $link.Inlines.Add(('DMR ID ' + $DmrId))
        $link.Tag = [pscustomobject]@{ dmr_id=$DmrId; callsign=$Callsign }
        $link.Add_MouseEnter({ param($sender,$eventArgs) $sender.Foreground = [Windows.Media.Brushes]::White })
        $link.Add_MouseLeave({ param($sender,$eventArgs) $sender.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#78B8FF') })
        $link.Add_Click({
            param($sender,$eventArgs)
            try { Open-UiDmIdProfile -DmrId ([string]$sender.Tag.dmr_id) -Callsign ([string]$sender.Tag.callsign) | Out-Null }
            catch { Set-MainText -Name 'FooterText' -Text '无法打开电台资料页面。' }
        })
        [void]$textBlock.Inlines.Add($link)
    } else {
        [void]$textBlock.Inlines.Add(('DMR ID ' + $DmrId))
    }
    return $textBlock
}

function New-UiChannelActionButton {
    param([string]$Text,[object]$Channel,[ValidateSet('tx','remove','mute','quick_call')][string]$Action)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.Tag = [pscustomobject]@{ channel=$Channel; action=$Action }
    $button.Padding = [Windows.Thickness]::new(2.0,1.0,2.0,1.0)
    $button.Margin = [Windows.Thickness]::new(1.0)
    $button.FontSize = 13
    $button.Add_Click({
        param($sender,$eventArgs)
        $channel = $sender.Tag.channel
        switch ([string]$sender.Tag.action) {
            'tx' { try { Invoke-UiSetCallTarget -Target (Get-UiChannelTarget -Channel $channel) } catch { Set-UiChannelStatus -Text $_.Exception.Message -Failed $true } }
            'remove' { Remove-UiChannel -Channel $channel }
            'mute' { Set-UiChannelMuted -Channel $channel }
            'quick_call' {
                try { [void](Invoke-UiChannelQuickCall -Channel $channel) }
                catch {
                    Set-DynamicGroupStatus -Text ([string]$_.Exception.Message) -Failed $true
                    Update-DynamicGroupControls
                }
            }
        }
    })
    return $button
}

function Update-UiChannelDisplays {
    if (-not $script:mainWindow) { return }
    $callCards = $script:mainWindow.FindName('ChannelCardsPanel')
    if (-not $callCards) { return }
    $callCards.Children.Clear()
    $pageSize = 6
    $channelCount = @($script:channels).Count
    $pageCount = [Math]::Max(1,[int][Math]::Ceiling($channelCount / [double]$pageSize))
    $script:channelPageIndex = [Math]::Max(0,[Math]::Min($pageCount - 1,[int]$script:channelPageIndex))
    $pageNav = $script:mainWindow.FindName('ChannelPageNav')
    $pagePrevious = $script:mainWindow.FindName('ChannelPagePreviousButton')
    $pageNext = $script:mainWindow.FindName('ChannelPageNextButton')
    $pageText = $script:mainWindow.FindName('ChannelPageText')
    if ($pageNav) { $pageNav.Visibility = if ($pageCount -gt 1) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($pagePrevious) { $pagePrevious.IsEnabled = ($script:channelPageIndex -gt 0) }
    if ($pageNext) { $pageNext.IsEnabled = ($script:channelPageIndex -lt ($pageCount - 1)) }
    if ($pageText) { $pageText.Text = ('{0} / {1}' -f ($script:channelPageIndex + 1),$pageCount) }
    $mutationUnlocked = (-not $script:channelMutationSafetyStopPending -and -not $script:pendingRoutingMutation -and -not $script:pendingChannelStopMutation -and
        -not $script:pendingChannelMutation -and -not $script:routingMutationFence)
    $coreConnected = ($script:supervisor -and -not $script:supervisor.HasExited)
    $canReceiveMutation = ($mutationUnlocked -and (-not $coreConnected -or
        ($script:controlConfirmed -and $script:routingCapabilities -and $script:activeRouting)))
    $canTxMutation = ($canReceiveMutation -and (-not $coreConnected -or
        @('idle','rx_active','rx_draining','rx_stopping') -ccontains [string]$script:activeRouting.media_owner))
    $pageChannels = @($script:channels | Select-Object -Skip ($script:channelPageIndex * $pageSize) -First $pageSize)
    foreach ($channel in $pageChannels) {
        $key = Get-UiChannelKey -Channel $channel
        $presentation = Get-UiChannelCardPresentation -Channel $channel
        $isMuted = [bool]$presentation.is_muted
        $isTx = [bool]$presentation.is_selected_tx
        $activationPresentation = Get-UiChannelActivationPresentation -Channel $channel
        $call = Get-UiChannelCurrentCall -Channel $channel
        $card = New-Object System.Windows.Controls.Border
        $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString([string]$presentation.background)
        $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString([string]$presentation.border)
        $card.BorderThickness = [Windows.Thickness]::new(1.0)
        $card.Padding = [Windows.Thickness]::new(5.0,4.0,5.0,4.0)
        $card.Margin = [Windows.Thickness]::new(2.0)
        $card.MinHeight = 109
        $card.Tag = [pscustomobject]@{ channel_key=$key; call_active=[bool]$call; blank=$false }
        $cardBody = New-Object System.Windows.Controls.Grid
        $headerRow = New-Object System.Windows.Controls.RowDefinition
        $headerRow.Height = [Windows.GridLength]::new(24)
        $contentRow = New-Object System.Windows.Controls.RowDefinition
        $contentRow.Height = [Windows.GridLength]::new(75)
        [void]$cardBody.RowDefinitions.Add($headerRow)
        [void]$cardBody.RowDefinitions.Add($contentRow)
        $leftColumn = New-Object System.Windows.Controls.ColumnDefinition
        $leftColumn.Width = [Windows.GridLength]::new(1.5,[Windows.GridUnitType]::Star)
        $buttonColumn = New-Object System.Windows.Controls.ColumnDefinition
        $buttonColumn.Width = [Windows.GridLength]::new(0.7,[Windows.GridUnitType]::Star)
        [void]$cardBody.ColumnDefinitions.Add($leftColumn)
        [void]$cardBody.ColumnDefinitions.Add($buttonColumn)
        $cardTitle = New-Object System.Windows.Controls.TextBlock
        $cardTitle.Name = 'ChannelCardTitle'
        $cardTitle.Text = [string]$activationPresentation.title
        $cardTitle.ToolTip = [string]$activationPresentation.tooltip
        $cardTitle.Tag = $activationPresentation
        $cardTitle.FontSize = 14
        $cardTitle.Height = 22
        $cardTitle.FontWeight = [Windows.FontWeights]::Bold
        $cardTitle.Foreground = if ($isMuted) { [Windows.Media.Brushes]::DarkGray } else { [Windows.Media.Brushes]::White }
        $cardTitle.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
        $cardTitle.Margin = [Windows.Thickness]::new(0.0,0.0,5.0,0.0)
        [Windows.Controls.Grid]::SetRow($cardTitle,0)
        [Windows.Controls.Grid]::SetColumn($cardTitle,0)
        [Windows.Controls.Grid]::SetColumnSpan($cardTitle,2)
        [void]$cardBody.Children.Add($cardTitle)
        $callArea = New-Object System.Windows.Controls.Border
        $callArea.Tag = 'ChannelCallArea'
        $callArea.Height = 75
        $callArea.MinHeight = 75
        $callArea.MaxHeight = 75
        $callArea.Padding = [Windows.Thickness]::new(5.0,4.0,5.0,4.0)
        $callArea.Background = [Windows.Media.BrushConverter]::new().ConvertFromString([string]$presentation.call_background)
        $callArea.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#35434A')
        $callArea.BorderThickness = [Windows.Thickness]::new(1.0)
        $callArea.Margin = [Windows.Thickness]::new(0.0,0.0,5.0,0.0)
        $callPanel = New-Object System.Windows.Controls.StackPanel
        if ($call) {
            $caller = Get-UiChannelCallerDetails -RadioId ([uint64]$call.current_call_source_id)
            if ($caller.known) {
                $callSource = New-Object System.Windows.Controls.TextBlock
                $callSource.FontSize = 22
                $callSource.Height = 31
                $callSource.FontWeight = [Windows.FontWeights]::Bold
                $callSource.Foreground = if ($presentation.is_active_tx) { [Windows.Media.Brushes]::White } else { [Windows.Media.Brushes]::LightGreen }
                $callSource.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
                $normalizedCallsign = Get-UiNativeIdentityCallsign -Value ([string]$caller.callsign)
                if ($normalizedCallsign) {
                    $callsignLink = New-Object System.Windows.Documents.Hyperlink
                    $callsignLink.Foreground = [Windows.Media.Brushes]::LightGreen
                    $callsignLink.Inlines.Add($normalizedCallsign)
                    $callsignLink.Tag = $normalizedCallsign
                    $callsignLink.Add_MouseEnter({ param($sender,$eventArgs) $sender.Foreground = [Windows.Media.Brushes]::White })
                    $callsignLink.Add_MouseLeave({ param($sender,$eventArgs) $sender.Foreground = [Windows.Media.Brushes]::LightGreen })
                    $callsignLink.Add_Click({
                        param($sender,$eventArgs)
                        try { Open-UiCallsignProfile -Callsign ([string]$sender.Tag) | Out-Null }
                        catch { Set-MainText -Name 'FooterText' -Text '无法打开 QRZ 呼号资料页。' }
                    })
                    [void]$callSource.Inlines.Add($callsignLink)
                    if ($caller.person_name -and [string]$caller.person_name -cne [string]$normalizedCallsign) {
                        [void]$callSource.Inlines.Add((' · ' + [string]$caller.person_name))
                    }
                } else {
                    $callSource.Text = [string]$caller.primary
                }
                [void]$callPanel.Children.Add($callSource)
                [void]$callPanel.Children.Add((New-UiDmIdLinkTextBlock -DmrId ([string]$caller.dmr_id) -Callsign ([string]$normalizedCallsign) -FontSize 18))
            } else {
                [void]$callPanel.Children.Add((New-UiDmIdLinkTextBlock -DmrId ([string]$caller.dmr_id) -FontSize 22))
            }
        }
        $callArea.Child = $callPanel
        [Windows.Controls.Grid]::SetRow($callArea,1)
        [Windows.Controls.Grid]::SetColumn($callArea,0)
        [void]$cardBody.Children.Add($callArea)

        $actionGrid = New-Object System.Windows.Controls.Primitives.UniformGrid
        $actionGrid.Columns = 2
        $actionGrid.Rows = 2
        $actionGrid.Height = 75
        $actionGrid.MinHeight = 75
        $actionGrid.MaxHeight = 75
        $actionGrid.VerticalAlignment = [Windows.VerticalAlignment]::Top
        $actionGrid.Margin = [Windows.Thickness]::new(0.0)
        [Windows.Controls.Grid]::SetRow($actionGrid,1)
        [Windows.Controls.Grid]::SetColumn($actionGrid,1)
        $txButton = New-UiChannelActionButton -Text $(if ($isTx) { '呼叫目标' } else { '设为呼叫' }) -Channel $channel -Action tx
        $txButton.IsEnabled = ($canTxMutation -and -not $isTx)
        $txButton.ToolTip = if ($isTx) { '已选为下次 PTT 呼叫目标' } else { '选择此频道作为下次 PTT 目标' }
        $txButton.Height = 36
        [void]$actionGrid.Children.Add($txButton)
        $removeButton = New-UiChannelActionButton -Text '取消监听' -Channel $channel -Action remove
        $removeButton.IsEnabled = $canReceiveMutation
        $removeButton.Height = 36
        [void]$actionGrid.Children.Add($removeButton)
        $muteButton = New-UiChannelActionButton -Text $(if ($isMuted) { '恢复收听' } else { '临时屏蔽' }) -Channel $channel -Action mute
        $muteButton.IsEnabled = $canReceiveMutation
        $muteButton.Height = 36
        [void]$actionGrid.Children.Add($muteButton)
        if ([string]$channel.kind -ceq 'group' -and [uint64]$channel.id -ne 4000) {
            $runId = [string]$script:controlRunId
            $quickCallPending = ($runId -and (Test-WirexChannelActivationPending -State $script:channelActivationState -RunId $runId))
            if ($script:pendingQuickCall -and -not [bool]$script:pendingQuickCall.timed_out) { $quickCallPending = $true }
            $quickCallQueued = [bool]$script:queuedQuickCall
            $queuedForChannel = ($quickCallQueued -and [string]$script:queuedQuickCall.channel_key -ceq $key)
            $buttonText = if ($activationPresentation.is_bm_static) { '静态组' }
                elseif ($queuedForChannel) { '取消排队' }
                elseif ($quickCallPending -and $script:pendingQuickCall -and
                    [string]$script:pendingQuickCall.channel_key -ceq $key -and -not [bool]$script:pendingQuickCall.timed_out) { '请求处理中' }
                elseif ($activationPresentation.request_sent) { '再次激活' }
                else { '激活组' }
            $fourthButton = New-UiChannelActionButton -Text $buttonText -Channel $channel -Action quick_call
            if ($activationPresentation.is_bm_static) {
                $fourthButton.ToolTip = [string]$activationPresentation.tooltip
            } elseif ($queuedForChannel) {
                $fourthButton.ToolTip = '当前通话结束前暂存的激活请求；点击可取消，最多等待 60 秒。'
            } elseif ($activationPresentation.request_sent) {
                $fourthButton.ToolTip = ("{0}`n本机上次请求已发送；BM 当前动态组状态未知。点击可再次激活。" -f [string]$activationPresentation.tooltip)
            } elseif ($quickCallPending) {
                $fourthButton.ToolTip = '一项激活请求正在等待本机结果；结果返回或等待超时后可再次操作。'
            } elseif ($quickCallQueued) {
                $fourthButton.ToolTip = '另一频道已有激活请求排队；请取消或等待该请求结束。'
            } else {
                $fourthButton.ToolTip = '向本机 Native 请求发送一次动态组 Quick Call；本机只报告发送结果，不回读 BM 当前动态组。'
            }
            $fourthButton.IsEnabled = (-not $activationPresentation.is_bm_static -and
                ($queuedForChannel -or (-not $quickCallQueued -and -not $quickCallPending)))
            $fourthButton.Height = 36
            [void]$actionGrid.Children.Add($fourthButton)
        } else {
            $emptyAction = New-Object System.Windows.Controls.Border
            $emptyAction.Margin = [Windows.Thickness]::new(2.0)
            $emptyAction.IsHitTestVisible = $false
            [void]$actionGrid.Children.Add($emptyAction)
        }
        [void]$cardBody.Children.Add($actionGrid)
        $card.Child = $cardBody
        [void]$callCards.Children.Add($card)
    }
    $visibleCardCount = [Math]::Min($pageSize,[Math]::Max(0,$channelCount - ($script:channelPageIndex * $pageSize)))
    for ($blankIndex = $visibleCardCount; $blankIndex -lt $pageSize; $blankIndex++) {
        $emptySlot = New-Object System.Windows.Controls.Border
        $emptySlot.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#151C20')
        $emptySlot.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#303B40')
        $emptySlot.BorderThickness = [Windows.Thickness]::new(1.0)
        $emptySlot.Margin = [Windows.Thickness]::new(2.0)
        $emptySlot.IsHitTestVisible = $false
        $emptySlot.Tag = [pscustomobject]@{ blank=$true }
        [void]$callCards.Children.Add($emptySlot)
    }
}

function Update-CallTargetChoices { Update-UiChannelDisplays }

function Set-UiQuickCallFailure {
    param([Parameter(Mandatory=$true)][object]$Channel,[AllowEmptyString()][string]$RunId='',
        [Parameter(Mandatory=$true)][string]$ErrorCode,[Parameter(Mandatory=$true)][string]$Message,
        [AllowEmptyString()][string]$RequestId='')
    [void](Add-UiQuickCallDiagnostic -RunId $RunId -RequestId $RequestId -DestinationId ([uint64]$Channel.id) `
        -Slot ([int]$Channel.slot) -Result rejected -ErrorCode $ErrorCode)
    Set-UiControlStatus -Text '动态组激活失败' -Confirmed $script:controlConfirmed
    Set-DynamicGroupStatus -Text $Message -Failed $true
    Add-UiEvent ('动态组激活失败：' + $ErrorCode)
    throw $Message
}

function Clear-UiQueuedQuickCall {
    param([ValidateSet('cancelled','timeout','rejected','stale')][string]$Result='cancelled',
        [Parameter(Mandatory=$true)][string]$ErrorCode,[Parameter(Mandatory=$true)][string]$Message)
    $queued = $script:queuedQuickCall
    if (-not $queued) { return $false }
    $script:queuedQuickCall = $null
    [void](Add-UiQuickCallDiagnostic -RunId ([string]$queued.run_id) -RequestId '' `
        -DestinationId ([uint64]$queued.destination_id) -Slot ([int]$queued.slot) -Result $Result -ErrorCode $ErrorCode)
    Set-DynamicGroupStatus -Text $Message -Failed:($Result -in @('timeout','rejected','stale'))
    Update-DynamicGroupControls
    return $true
}

function Send-UiChannelQuickCallRequest {
    param([Parameter(Mandatory=$true)][object]$Channel,[Parameter(Mandatory=$true)][string]$RunId)
    $channelKey = Get-UiChannelKey -Channel $Channel
    $diagnosticAutoTest = ($RoutingDiagnostic -and $RoutingDiagnosticAutoTest)
    if ([string]::IsNullOrWhiteSpace($RunId) -or [string]$script:controlRunId -cne $RunId -or
        -not $script:supervisor -or $script:supervisor.HasExited -or -not $script:quickCallCapabilities -or -not $script:controlConfirmed) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode control_not_ready `
            -Message '本机控制通道尚未确认；未发送激活请求。'
    }
    if ($script:pendingChannelStopMutation -or $script:stopTask -or $script:closingAfterStop -or
        $script:reconnectAfterStop -or $script:preparationStarted -or $script:nativeExitCleanupPending -or
        $script:serialDisconnectPending) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode run_changing `
            -Message '本机正在停止或切换运行会话；未发送激活请求。'
    }
    if ($script:bmConnectionPendingRequest -and $script:bmConnectionPendingRequest.PSObject.Properties['enabled'] -and
        -not [bool]$script:bmConnectionPendingRequest.enabled) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode bm_disconnect_pending `
            -Message '正在断开 BM；未发送激活请求。'
    }
    $currentChannel = Get-UiChannelByKey -Key $channelKey
    if (-not $currentChannel -or [string]$currentChannel.kind -cne 'group' -or
        [uint64]$currentChannel.id -ne [uint64]$Channel.id -or [int]$currentChannel.slot -ne [int]$Channel.slot -or
        ($script:mutedChannelKeys -and $script:mutedChannelKeys.ContainsKey($channelKey))) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode channel_no_longer_rx `
            -Message '该频道已从本机监听列表移除或屏蔽；未发送激活请求。'
    }
    if (Test-UiBmStaticChannelReadback -Channel $currentChannel) {
        Set-UiQuickCallFailure -Channel $currentChannel -RunId $RunId -ErrorCode static_group `
            -Message '该组已由当前 BM 设备静态组列表确认；无需发送激活请求。'
    }
    if (-not $diagnosticAutoTest) {
        $statusFresh = ($script:latestStatus -and [string]$script:latestStatus.run_id -ceq $RunId -and
            $script:lastStatusUtc -ne [DateTime]::MinValue -and ([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3)
        if (-not $statusFresh) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode media_status_stale `
                -Message '本机媒体状态已超过 3 秒；未发送激活请求。'
        }
        if ([string]$script:latestStatus.bm_state -cne 'ready') {
            Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode bm_not_ready `
                -Message 'BM 尚未确认 ready；未发送激活请求。'
        }
        if ([string]$script:latestStatus.media_owner -cne 'idle') {
            Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode media_busy `
                -Message '本机媒体仍忙；本次激活没有发送。'
        }
        if ($script:channelMutationSafetyStopPending -or $script:pendingRoutingMutation -or
            $script:pendingChannelMutation -or $script:routingMutationFence) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode channel_update_pending `
                -Message '频道设置仍在处理；未发送激活请求。'
        }
        if (Test-WirexChannelActivationPending -State $script:channelActivationState -RunId $RunId) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode native_request_pending `
                -Message '上一项激活请求仍在等待本机结果。'
        }
    }
    if ($script:pendingQuickCall -and -not [bool]$script:pendingQuickCall.timed_out) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode native_request_pending `
            -Message '上一项激活请求仍在等待本机结果。'
    }

    $requestId = [guid]::NewGuid().ToString('D')
    if (-not $diagnosticAutoTest -and -not (Start-WirexChannelActivationRequest -State $script:channelActivationState -RunId $RunId `
            -RequestId $requestId -ChannelKey $channelKey -DestinationId ([uint64]$Channel.id) -Slot ([int]$Channel.slot))) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -ErrorCode activation_state_busy `
            -Message '本机仍在处理另一项激活请求；未发送本次请求。'
    }
    $script:pendingQuickCall = [pscustomobject][ordered]@{
        run_id=$RunId; request_id=$requestId; channel_key=$channelKey; destination_id=[uint64]$Channel.id
        slot=[int]$Channel.slot; started_utc=[DateTime]::UtcNow; timed_out=$false
    }
    $script:pendingControlRequests[$requestId] = 'network_subscription.quick_call_join'
    $parameters = [ordered]@{ group=[pscustomobject][ordered]@{ destination_id=[uint64]$Channel.id; slot=[uint64]$Channel.slot } }
    $parametersJson = ConvertTo-Json -InputObject $parameters -Depth 4 -Compress
    if (-not $script:supervisor.SendControlCommand($requestId,'network_subscription.quick_call_join',$parametersJson)) {
        [void]$script:pendingControlRequests.Remove($requestId)
        $script:pendingQuickCall = $null
        if (-not $diagnosticAutoTest) {
            [void](Complete-WirexChannelActivationRequest -State $script:channelActivationState -RunId $RunId `
                -RequestId $requestId -Result rejected)
        }
        Set-UiQuickCallFailure -Channel $Channel -RunId $RunId -RequestId $requestId -ErrorCode control_send_failed `
            -Message '动态组激活请求没有送达本机 Native。'
    }
    if (-not $diagnosticAutoTest) {
        [void](Add-UiQuickCallDiagnostic -RunId $RunId -RequestId $requestId -DestinationId ([uint64]$Channel.id) `
            -Slot ([int]$Channel.slot) -Result submitted)
    }
    Set-UiChannelStatus -Text ('TG {0} TS{1} 激活请求已提交。' -f [uint64]$Channel.id,[int]$Channel.slot)
    Update-DynamicGroupControls
    return $true
}

function Process-UiQueuedQuickCall {
    $queued = $script:queuedQuickCall
    if (-not $queued) { return $false }
    if ($script:pendingChannelStopMutation -or $script:stopTask -or $script:closingAfterStop -or
        $script:reconnectAfterStop -or $script:preparationStarted -or $script:nativeExitCleanupPending -or
        $script:serialDisconnectPending) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode run_changing `
            -Message '本机正在停止或切换运行会话；排队取消，没有发送激活请求。'
    }
    if ($script:bmConnectionPendingRequest -and $script:bmConnectionPendingRequest.PSObject.Properties['enabled'] -and
        -not [bool]$script:bmConnectionPendingRequest.enabled) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode bm_disconnect_pending `
            -Message '正在断开 BM；排队取消，没有发送激活请求。'
    }
    if ([DateTime]::UtcNow -ge [DateTime]$queued.expires_utc) {
        return Clear-UiQueuedQuickCall -Result timeout -ErrorCode queue_timeout `
            -Message ('TG {0} TS{1} 等待当前通话结束超时；没有发送激活请求。' -f $queued.destination_id,$queued.slot)
    }
    if (-not $script:supervisor -or $script:supervisor.HasExited -or
        [string]$script:controlRunId -cne [string]$queued.run_id) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode run_changed `
            -Message 'Native 运行会话已变化；排队取消，没有发送激活请求。'
    }
    if (-not $script:controlConfirmed -or -not $script:quickCallCapabilities) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode control_not_ready `
            -Message 'Native 控制能力已不可用；排队取消，没有发送激活请求。'
    }
    if ($script:latestStatus -and [string]$script:latestStatus.run_id -cne [string]$queued.run_id) {
        return Clear-UiQueuedQuickCall -Result stale -ErrorCode run_changed `
            -Message '本机状态已切换到另一运行会话；排队取消，没有发送激活请求。'
    }
    if ($script:latestStatus -and [string]$script:latestStatus.bm_state -cne 'ready') {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode bm_not_ready `
            -Message 'BM 连接离开 ready；排队取消，没有发送激活请求。'
    }
    if ($script:channelMutationSafetyStopPending -or $script:pendingRoutingMutation -or
        $script:pendingChannelMutation -or $script:routingMutationFence) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode channel_update_pending `
            -Message '频道设置开始更新；排队取消，没有发送激活请求。'
    }
    if (-not $script:latestStatus -or [string]$script:latestStatus.run_id -cne [string]$queued.run_id -or
        $script:lastStatusUtc -eq [DateTime]::MinValue -or ([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -gt 3) {
        return $false
    }
    $mediaOwner = [string]$script:latestStatus.media_owner
    if ($mediaOwner -in @('rx_active','rx_draining','rx_stopping','tx_active','tx_draining')) { return $false }
    if ($mediaOwner -cne 'idle') {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode media_state_unavailable `
            -Message '本机媒体状态无法确认空闲；排队取消，没有发送激活请求。'
    }
    $channelKey = [string]$queued.channel_key
    $channel = Get-UiChannelByKey -Key $channelKey
    if (-not $channel -or [string]$channel.kind -cne 'group' -or
        [uint64]$channel.id -ne [uint64]$queued.destination_id -or [int]$channel.slot -ne [int]$queued.slot -or
        ($script:mutedChannelKeys -and $script:mutedChannelKeys.ContainsKey($channelKey))) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode channel_no_longer_rx `
            -Message '该频道已从本机监听列表移除或屏蔽；排队取消，没有发送激活请求。'
    }
    if (Test-UiBmStaticChannelReadback -Channel $channel) {
        return Clear-UiQueuedQuickCall -Result cancelled -ErrorCode static_group `
            -Message '该组已由当前 BM 设备静态组列表确认；排队取消，无需发送激活请求。'
    }
    $script:queuedQuickCall = $null
    try {
        [void](Send-UiChannelQuickCallRequest -Channel $channel -RunId ([string]$queued.run_id))
    } catch {
        Update-DynamicGroupControls
        return $true
    }
    return $true
}

function Invoke-UiChannelQuickCall {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $runId = [string]$script:controlRunId
    if ([string]$Channel.kind -cne 'group') { throw '只有组呼频道可激活动态组。' }
    [void](Add-UiQuickCallDiagnostic -RunId $runId -RequestId '' -DestinationId ([uint64]$Channel.id) `
        -Slot ([int]$Channel.slot) -Result clicked -ErrorCode user_click)
    if (Test-UiBmStaticChannelReadback -Channel $Channel) {
        [void](Add-UiQuickCallDiagnostic -RunId $runId -RequestId '' -DestinationId ([uint64]$Channel.id) `
            -Slot ([int]$Channel.slot) -Result rejected -ErrorCode static_group)
        Set-DynamicGroupStatus ('TG {0} TS{1} 已由当前 BM 设备的静态组列表确认；无需激活。' -f [uint64]$Channel.id,[int]$Channel.slot)
        Update-DynamicGroupControls
        return $false
    }
    if ($script:queuedQuickCall) {
        if ([string]$script:queuedQuickCall.channel_key -ceq (Get-UiChannelKey -Channel $Channel)) {
            [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode user_cancelled `
                -Message ('已取消 TG {0} TS{1} 的排队；没有发送激活请求。' -f [uint64]$Channel.id,[int]$Channel.slot))
            return $false
        }
        Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode queue_pending `
            -Message '另一频道已有激活请求排队；请先取消或等待该请求结束。'
    }
    if ([string]::IsNullOrWhiteSpace($runId) -or [string]$script:controlRunId -cne $runId -or
        -not $script:supervisor -or $script:supervisor.HasExited -or -not $script:quickCallCapabilities -or -not $script:controlConfirmed) {
        Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode control_not_ready `
            -Message '本机控制通道尚未确认；未发送激活请求。'
    }
    $diagnosticAutoTest = ($RoutingDiagnostic -and $RoutingDiagnosticAutoTest)
    if (-not $diagnosticAutoTest) {
        $statusFresh = ($script:latestStatus -and [string]$script:latestStatus.run_id -ceq $runId -and
            $script:lastStatusUtc -ne [DateTime]::MinValue -and ([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3)
        if (-not $statusFresh) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode media_status_stale `
                -Message '本机媒体状态已超过 3 秒；未发送激活请求。'
        }
        if ([string]$script:latestStatus.bm_state -cne 'ready') {
            Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode bm_not_ready `
                -Message 'BM 尚未确认 ready；未发送激活请求。'
        }
        if ($script:channelMutationSafetyStopPending -or $script:pendingRoutingMutation -or
            $script:pendingChannelMutation -or $script:routingMutationFence) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode channel_update_pending `
                -Message '频道设置仍在处理；未发送激活请求。'
        }
        if (Test-WirexChannelActivationPending -State $script:channelActivationState -RunId $runId) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode native_request_pending `
                -Message '上一项激活请求仍在等待本机结果。'
        }
        if ($script:pendingQuickCall -and -not [bool]$script:pendingQuickCall.timed_out) {
            Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode native_request_pending `
                -Message '上一项激活请求仍在等待本机结果。'
        }
        $mediaOwner = [string]$script:latestStatus.media_owner
        if ($mediaOwner -ne 'idle') {
            if ($mediaOwner -notin @('rx_active','rx_draining','rx_stopping','tx_active','tx_draining')) {
                Set-UiQuickCallFailure -Channel $Channel -RunId $runId -ErrorCode media_state_unavailable `
                    -Message '本机媒体状态无法确认安全排队；未发送激活请求。'
            }
            $script:queuedQuickCall = [pscustomobject][ordered]@{
                run_id=$runId; queue_id=[guid]::NewGuid().ToString('D'); channel_key=(Get-UiChannelKey -Channel $Channel)
                destination_id=[uint64]$Channel.id; slot=[int]$Channel.slot
                channel=[pscustomobject]@{id=[uint64]$Channel.id;kind='group';slot=[int]$Channel.slot}
                queued_utc=[DateTime]::UtcNow; expires_utc=[DateTime]::UtcNow.AddSeconds([double]$script:quickCallQueueTimeoutSeconds)
            }
            [void](Add-UiQuickCallDiagnostic -RunId $runId -RequestId '' -DestinationId ([uint64]$Channel.id) `
                -Slot ([int]$Channel.slot) -Result queued -ErrorCode media_busy)
            Set-DynamicGroupStatus ('TG {0} TS{1} 等待当前通话结束。' -f [uint64]$Channel.id,[int]$Channel.slot)
            Update-DynamicGroupControls
            return $true
        }
    }
    return (Send-UiChannelQuickCallRequest -Channel $Channel -RunId $runId)
}

function Start-UiChannelMutation {
    param([object[]]$Channels,[string]$TxKey,[hashtable]$MutedKeys=@{},[string]$Action='更新频道')
    if ($script:channelMutationSafetyStopPending) { throw '频道目标状态未确认；停止完成前不能修改频道。' }
    if ($script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode channel_update_pending `
            -Message '频道设置开始更新；排队已取消，没有发送激活请求。')
    }
    $candidateChannels = @($Channels)
    $candidateMuted = @{} + $MutedKeys
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        if ($script:pendingRoutingMutation -or $script:pendingChannelMutation -or $script:routingMutationFence) {
            throw '上一项频道设置仍在处理中。'
        }
        if (-not $script:activeRouting) { throw '核心尚未报告当前频道状态。' }
        $txChannel = Get-UiChannelByKey -Key $TxKey -Channels $candidateChannels
        if ($candidateChannels.Count -gt 0 -and -not $txChannel) { throw '频道列表中的PTT目标无效。' }
        $change = [pscustomobject]@{
            channels=$candidateChannels; tx_key=$TxKey; muted_keys=$candidateMuted; stage='rx'; tx_applied=$false; action=$Action
        }
        $currentTx = Get-UiChannelTargetFromRouting -Routing $script:activeRouting
        $targetChanged = $txChannel -and ($null -eq $currentTx -or [string](Get-UiChannelKey -Channel ([pscustomobject]@{
            id=[uint64]$currentTx.destination_id; kind=[string]$currentTx.kind; slot=[int]$currentTx.slot
        })) -cne $TxKey)
        if ($targetChanged) {
            if (@('tx_active','tx_draining','fault') -ccontains [string]$script:activeRouting.media_owner) {
                throw '请等待当前发射与清理结束后再切换 PTT 目标。'
            }
            $change.stage = 'tx'
            $script:pendingChannelMutation = $change
            try { Invoke-UiRoutingMutation -Command 'tx_policy.replace' -PolicyOrTarget (Get-UiChannelTarget -Channel $txChannel) }
            catch {
                $script:pendingChannelMutation = $null
                Update-UiChannelDisplays
                throw
            }
        } else {
            $script:pendingChannelMutation = $change
            $policy = Get-UiNativeRxPolicyForChannels -Channels $candidateChannels -MutedKeys $candidateMuted
            try { Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $policy }
            catch {
                $script:pendingChannelMutation = $null
                Update-UiChannelDisplays
                throw
            }
        }
        Set-UiChannelStatus -Text ('正在{0}；等待核心确认当前频道设置。' -f $Action)
        return
    }
    $script:channels = $candidateChannels
    $script:txChannelKey = $TxKey
    $script:mutedChannelKeys = $candidateMuted
    Save-UiPortableConfig | Out-Null
    Set-UiChannelStatus -Text ($Action + '已保存。')
}

function Clear-UiChannelMutationSafetyState {
    if (-not $script:channelMutationSafetyStopPending) { return $false }
    foreach ($requestId in @($script:pendingControlRequests.Keys)) {
        $command = [string]$script:pendingControlRequests[$requestId]
        if ($command -in @('routing.status','rx_policy.replace','tx_policy.replace')) {
            $script:resolvedTimedOutRoutingRequests[[string]$requestId] = $command
            [void]$script:pendingControlRequests.Remove([string]$requestId)
        }
    }
    foreach ($requestId in @($script:timedOutRoutingMutations.Keys)) {
        $command = [string]$script:timedOutRoutingMutations[$requestId].command
        $script:resolvedTimedOutRoutingRequests[[string]$requestId] = $command
    }
    $script:timedOutRoutingMutations.Clear()
    $script:pendingRoutingMutation = $null
    $script:pendingChannelMutation = $null
    $script:pendingRoutingStatusRequestId = ''
    $script:resolvedTimedOutRoutingRequests.Clear()
    $script:routingMutationFence = $false
    $script:routingDraftAfterTimeout = $null
    $script:routingDraftPreservedAfterTimeout = $false
    $script:pendingDynamicCallTarget = $null
    $script:pendingDynamicLocalListen = $null
    $script:channelMutationSafetyStopPending = $false
    Update-UiChannelDisplays
    Set-ConnectionButtonState
    return $true
}

function Start-UiChannelMutationSafetyStop {
    param([string]$Reason='频道目标状态未能确认')
    if ($script:channelMutationSafetyStopPending) { return $false }
    if ($script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode run_changing `
            -Message '本机正在安全停止；排队取消，没有发送激活请求。')
    }
    $script:channelMutationSafetyStopPending = $true
    $script:closingAfterStop = $false
    $script:reconnectAfterStop = $false
    $script:pendingChannelMutation = $null
    $script:controlConfirmed = $false
    $script:routingMutationFence = $true
    foreach ($requestId in @($script:pendingControlRequests.Keys)) {
        $command = [string]$script:pendingControlRequests[$requestId]
        if ($command -in @('routing.status','rx_policy.replace','tx_policy.replace')) {
            $script:resolvedTimedOutRoutingRequests[[string]$requestId] = $command
            [void]$script:pendingControlRequests.Remove([string]$requestId)
        }
    }
    foreach ($requestId in @($script:timedOutRoutingMutations.Keys)) {
        $command = [string]$script:timedOutRoutingMutations[$requestId].command
        $script:resolvedTimedOutRoutingRequests[[string]$requestId] = $command
    }
    $script:timedOutRoutingMutations.Clear()
    $script:pendingRoutingMutation = $null
    $script:pendingRoutingStatusRequestId = ''
    $script:routingDraftAfterTimeout = $null
    $script:routingDraftPreservedAfterTimeout = $false
    $script:pendingDynamicCallTarget = $null
    $script:pendingDynamicLocalListen = $null
    $script:pendingChannelStopMutation = $null
    $script:routingMutationFence = $true
    Set-UiChannelStatus -Text ($Reason + '；正在停止连接，原频道和 PTT 配置会保留。') -Failed $true
    Set-MainText -Name 'CoreValue' -Text '正在安全停止'
    Set-MainText -Name 'CoreDetail' -Text '频道目标未能确认；停止完成后可手动重新连接。'
    Set-MainText -Name 'FooterText' -Text '正在停止连接；不会自动重连。'
    if ($script:supervisor -and $script:supervisor.HasExited) {
        Set-MainText -Name 'FooterText' -Text '核心已退出；正在清理本次连接后保留原频道配置。'
        Set-ConnectionButtonState
        Update-UiChannelDisplays
        return $true
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        try {
            if (-not $script:stopTask) { $script:stopTask = $script:supervisor.StopAsync(5000) }
            (Get-UiControl 'StopButton').IsEnabled = $false
            Set-ConnectionButtonState
            Update-UiChannelDisplays
            return $true
        } catch {
            $script:stopTask = $null
            (Get-UiControl 'StopButton').IsEnabled = $true
            Set-MainText -Name 'FooterText' -Text '无法确认核心已停止；频道操作保持锁定，请重试停止。'
            Set-ConnectionButtonState
            Update-UiChannelDisplays
            return $false
        }
    }
    [void](Clear-UiChannelMutationSafetyState)
    Set-MainText -Name 'FooterText' -Text '核心已停止；原频道配置保留，可手动重新连接。'
    Set-UiChannelStatus -Text ($Reason + '；原频道和 PTT 配置已保留。') -Failed $true
    return $true
}

function Get-UiChannelTargetFromRouting {
    param([object]$Routing)
    if (-not $Routing -or -not $Routing.tx_target) { return $null }
    return [pscustomobject][ordered]@{
        destination_id=[uint64]$Routing.tx_target.destination_id
        kind=[string]$Routing.tx_target.kind; slot=[uint64]$Routing.tx_target.slot
    }
}

function Complete-UiChannelMutation {
    param([Parameter(Mandatory=$true)][object]$Mutation,[Parameter(Mandatory=$true)][object]$Routing)
    if (-not $script:pendingChannelMutation) { return $false }
    if ($script:pendingChannelMutation.stage -ceq 'tx') {
        $script:pendingChannelMutation.stage = 'rx'
        $script:pendingChannelMutation.tx_applied = $true
        $policy = Get-UiNativeRxPolicyForChannels -Channels @($script:pendingChannelMutation.channels) `
            -MutedKeys $script:pendingChannelMutation.muted_keys
        try { Invoke-UiRoutingMutation -Command 'rx_policy.replace' -PolicyOrTarget $policy }
        catch {
            [void](Start-UiChannelMutationSafetyStop -Reason 'PTT目标已应用，但新的监听频道未能提交')
        }
        return $true
    }
    $change = $script:pendingChannelMutation
    $script:channels = @($change.channels)
    $script:txChannelKey = [string]$change.tx_key
    $script:mutedChannelKeys = @{} + $change.muted_keys
    if ($script:activeProfile) {
        $script:activeProfile.rx_policy = Copy-UiRxPolicy -Policy $Routing.rx_policy
        if ($Routing.tx_target) { $script:activeProfile.tx_target = $Routing.tx_target }
        $script:activeProfile.transmit_enabled = $true
    }
    $saveError = ''
    try { if ($script:portableConfig) { Save-UiPortableConfig | Out-Null } }
    catch { $saveError = [string]$_.Exception.Message }
    if ($script:portableConfig) {
        try { $script:storedProfile = ConvertFrom-UiPortableConfigToProfile -Config $script:portableConfig }
        catch { $script:storedProfile = $null }
    }
    $script:pendingChannelMutation = $null
    if ($saveError) {
        Set-UiChannelStatus -Text ('核心已确认新的频道与 PTT 目标，界面已更新；本机配置文件保存失败：' + $saveError) -Failed $true
    } else {
        Set-UiChannelStatus -Text ($change.action + '已在当前连接生效并保存。')
        Add-UiEvent ($change.action + '已确认并保存')
    }
    Update-UiChannelDisplays
    return $true
}

function Add-UiChannelFromInputs {
    try {
        $channelIdCombo = Get-UiControl 'ChannelIdBox'
        $preset = Get-UiSelectedChannelPreset -Combo $channelIdCombo
        $idText = if ($preset) { [string]$preset.id } else { [string]$channelIdCombo.Text }
        $kindBox = Get-UiControl 'ChannelKindBox'
        $kind = if ($kindBox.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$kindBox.SelectedItem.Tag } else { '' }
        if ($kind -cnotin @('group','private')) {
            throw '请选择组呼或单呼类型。'
        }
        $slot = if ($preset -and $kind -ceq [string]$preset.kind) { [uint64]$preset.slot } else { [uint64]$script:channelEditorSlot }
        $name = if ($preset -and $kind -ceq [string]$preset.kind) { [string]$preset.name } else { '' }
        $channel = New-UiChannelRecord -Id $idText -Kind $kind -Slot $slot -Name $name
        $key = Get-UiChannelKey -Channel $channel
        if ($null -ne (Get-UiChannelByKey -Key $key)) { throw '频道列表已包含相同网络目标。' }
        if (@($script:channels).Count -ge 256) { throw '频道列表已达256项上限。' }
        $candidate = @($script:channels) + @($channel)
        # Adding a listener never replaces an existing PTT target. The first
        # configured channel initializes an otherwise empty target.
        $makeTx = [string]::IsNullOrWhiteSpace($script:txChannelKey)
        $txKey = if ($makeTx) { $key } else { [string]$script:txChannelKey }
        Start-UiChannelMutation -Channels $candidate -TxKey $txKey -MutedKeys $script:mutedChannelKeys -Action '加入频道'
        $script:loadingChannelPreset = $true
        $channelIdCombo.SelectedIndex = -1
        $channelIdCombo.Text = ''
        $script:channelPresetId = ''; $script:channelPresetKind = ''
        $script:channelAutoKind = ''
        $script:channelKindExplicit = $false
        $kindBox.SelectedIndex = 0
        $script:loadingChannelPreset = $false
    } catch { $script:loadingChannelPreset = $false; Set-UiChannelStatus -Text $_.Exception.Message -Failed $true }
}

function Set-UiChannelPresetFromSelection {
    param([object]$SelectedItem)
    if ($script:loadingChannelPreset) { return }
    $metadata = $null
    if ($SelectedItem -is [System.Windows.Controls.ComboBoxItem] -and $SelectedItem.Tag -and
        $SelectedItem.Tag.PSObject.Properties['id'] -and $SelectedItem.Tag.PSObject.Properties['kind'] -and
        $SelectedItem.Tag.PSObject.Properties['slot'] -and $SelectedItem.Tag.PSObject.Properties['name']) {
        $metadata = $SelectedItem.Tag
    }
    if ($metadata -and [string]$metadata.kind -cin @('group','private') -and
        [uint64]$metadata.id -ge 1 -and [uint64]$metadata.id -le 16777215 -and [int]$metadata.slot -in @(1,2)) {
        $presetId = ([uint64]$metadata.id).ToString([Globalization.CultureInfo]::InvariantCulture)
        $presetKind = [string]$metadata.kind
        $script:loadingChannelPreset = $true
        try {
            $combo = Get-UiControl 'ChannelIdBox'
            $combo.Text = $presetId
            $script:channelPresetId = $presetId; $script:channelPresetKind = $presetKind
            $script:channelAutoKind = $presetKind
            $script:channelKindExplicit = $false
            (Get-UiControl 'ChannelKindBox').SelectedIndex = $(if ($presetKind -ceq 'private') { 1 } else { 2 })
        } finally { $script:loadingChannelPreset = $false }
        return $true
    }
    $script:channelPresetId = ''; $script:channelPresetKind = ''
    return $false
}

function Update-UiChannelPresetFromManualText {
    $combo = Get-UiControl 'ChannelIdBox'
    if ($script:loadingChannelPreset) { return $false }
    $selectedPreset = Get-UiSelectedChannelPreset -Combo $combo
    if ($selectedPreset -and [string]$combo.Text -ceq ([uint64]$selectedPreset.id).ToString([Globalization.CultureInfo]::InvariantCulture)) {
        return $false
    }
    $kindBox = Get-UiControl 'ChannelKindBox'
    $selectedKind = if ($kindBox.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$kindBox.SelectedItem.Tag } else { '' }
    $script:channelPresetId = ''; $script:channelPresetKind = ''
    $automaticKind = [string]$script:channelAutoKind
    $script:channelAutoKind = ''
    if ($automaticKind -and $selectedKind -ceq $automaticKind -and -not [bool]$script:channelKindExplicit) {
        $script:loadingChannelPreset = $true
        try { $kindBox.SelectedIndex = 0; $script:channelKindExplicit = $false }
        finally { $script:loadingChannelPreset = $false }
    }
    if ($combo.SelectedIndex -ge 0) {
        $script:loadingChannelPreset = $true
        try { $combo.SelectedIndex = -1 } finally { $script:loadingChannelPreset = $false }
    }
    return $true
}

function Initialize-UiChannelInputHandlers {
    $channelIdCombo = Get-UiControl 'ChannelIdBox'
    foreach ($item in @($channelIdCombo.Items)) {
        if ($item -isnot [System.Windows.Controls.ComboBoxItem] -or $null -eq $item.Tag) { continue }
        if ($item.Tag.PSObject.Properties['id'] -and $item.Tag.PSObject.Properties['kind']) { continue }
        if ([string]$item.Tag -cnotmatch '^([0-9]{1,8})\|(group|private)$') { continue }
        $id = [uint64]0
        if (-not [uint64]::TryParse([string]$Matches[1],[Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$id)) { continue }
        $kind = [string]$Matches[2]
        $item.Tag = [pscustomobject][ordered]@{
            id=$id; kind=$kind; slot=[int]$script:channelEditorSlot
            name=(Get-UiKnownChannelName -Id $id -Kind $kind)
        }
    }
    $channelIdCombo.Add_SelectionChanged({
        $combo = Get-UiControl 'ChannelIdBox'
        [void](Set-UiChannelPresetFromSelection -SelectedItem $combo.SelectedItem)
    })
    $kindBox = Get-UiControl 'ChannelKindBox'
    $kindBox.Add_SelectionChanged({
        if (-not $script:loadingChannelPreset) { $script:channelKindExplicit = $true; $script:channelAutoKind = '' }
    })
    foreach ($kindItem in @($kindBox.Items | Where-Object { $_ -is [System.Windows.Controls.ComboBoxItem] })) {
        $kindItem.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent,
            [System.Windows.Input.MouseButtonEventHandler]{
                if (-not $script:loadingChannelPreset) { $script:channelKindExplicit = $true; $script:channelAutoKind = '' }
            },$true)
    }
    [void]$channelIdCombo.ApplyTemplate()
    $channelIdTextBox = $channelIdCombo.Template.FindName('PART_EditableTextBox',$channelIdCombo)
    if (-not $channelIdTextBox) { return $false }
    $channelIdTextBox.Add_TextChanged({
        [void](Update-UiChannelPresetFromManualText)
    })
    return $true
}

function Get-UiSelectedChannelPreset {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    $item = $Combo.SelectedItem
    if ($item -isnot [System.Windows.Controls.ComboBoxItem] -or $null -eq $item.Tag -or
        -not $item.Tag.PSObject.Properties['id'] -or -not $item.Tag.PSObject.Properties['kind'] -or
        -not $item.Tag.PSObject.Properties['slot']) { return $null }
    $id = [uint64]0
    if (-not [uint64]::TryParse([string]$item.Tag.id,[Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$id) -or $id -lt 1 -or $id -gt 16777215 -or
        [string]$item.Tag.kind -cnotin @('group','private') -or [int]$item.Tag.slot -notin @(1,2)) { return $null }
    $textId = $id.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ([string]$Combo.Text -cne $textId) { return $null }
    return $item.Tag
}

function Remove-UiChannel {
    param([Parameter(Mandatory=$true)][object]$Channel)
    if ($script:pendingChannelStopMutation) { return }
    $key = Get-UiChannelKey -Channel $Channel
    $candidate = @($script:channels | Where-Object { (Get-UiChannelKey -Channel $_) -cne $key })
    if ($candidate.Count -eq @($script:channels).Count) { return }
    $txKey = [string]$script:txChannelKey
    if ($txKey -ceq $key) { $txKey = if ($candidate.Count -gt 0) { Get-UiChannelKey -Channel $candidate[0] } else { '' } }
    if ($script:supervisor -and -not $script:supervisor.HasExited -and $candidate.Count -eq 0) {
        if ($script:stopTask) { return }
        if ($script:queuedQuickCall) {
            [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode last_channel_removed `
                -Message '正在移除最后一个频道；排队取消，没有发送激活请求。')
        }
        $script:pendingChannelStopMutation = [pscustomobject]@{ channels=@(); tx_key=''; action='remove_last_channel' }
        Set-UiChannelStatus -Text '正在停止连接以移除最后一个频道。'
        $script:stopTask = $script:supervisor.StopAsync(5000)
        (Get-UiControl 'StopButton').IsEnabled = $false
        Update-UiChannelDisplays
        return
    }
    try { Start-UiChannelMutation -Channels $candidate -TxKey $txKey -MutedKeys $script:mutedChannelKeys -Action '取消监听' }
    catch { Set-UiChannelStatus -Text $_.Exception.Message -Failed $true }
}

function Set-UiChannelMuted {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $key = Get-UiChannelKey -Channel $Channel
    $candidateMuted = @{} + $script:mutedChannelKeys
    if ($candidateMuted.ContainsKey($key)) { [void]$candidateMuted.Remove($key); $action='恢复收听' }
    else { $candidateMuted[$key] = $true; $action='临时屏蔽' }
    try {
        if ($script:supervisor -and -not $script:supervisor.HasExited) {
            Start-UiChannelMutation -Channels @($script:channels) -TxKey $script:txChannelKey -MutedKeys $candidateMuted -Action $action
        } else {
            $script:mutedChannelKeys = $candidateMuted
            Update-UiChannelDisplays
            Set-UiChannelStatus -Text ($action + '仅对当前界面会话生效。')
        }
    } catch { Set-UiChannelStatus -Text $_.Exception.Message -Failed $true }
}

function Invoke-UiSetCallTarget {
    param([Parameter(Mandatory=$true)][object]$Target, [string]$Description='呼叫目标')
    $destination = [uint64]$Target.destination_id
    $slot = [uint64]$Target.slot
    $kind = [string]$Target.kind
    if ($destination -lt 1 -or $destination -gt 16777215 -or $slot -notin @(1,2) -or $kind -cnotin @('group','private')) {
        throw 'PTT频道参数无效。'
    }
    $matchingChannel = @($script:channels | Where-Object {
        [uint64]$_.id -eq $destination -and [string]$_.kind -ceq $kind -and [uint64]$_.slot -eq $slot
    }) | Select-Object -First 1
    if (-not $matchingChannel) { throw 'PTT目标必须是当前频道列表中的频道。' }
    $newKey=Get-UiChannelKey -Channel $matchingChannel
    if ($newKey -ceq $script:txChannelKey) { return }
    Start-UiChannelMutation -Channels @($script:channels) -TxKey $newKey -MutedKeys $script:mutedChannelKeys -Action '切换PTT目标'
}

function Get-SelectedTargetTag {
    return 'channel-list'
}

function Test-UiSourceIdentityRecord {
    param([Parameter(Mandatory=$true)][object]$Identity, [Parameter(Mandatory=$true)][object]$ParentRecord)
    if ($Identity -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $legacyNames = @('prepared', 'source_id', 'receive_generation', 'label', 'display')
    $currentNames = @('prepared', 'source_id', 'receive_generation', 'label', 'display',
        'label_kind', 'cache_revision', 'serial_write_state')
    $actualNames = @($Identity.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $isCurrentSchema = $actualNames.Count -eq $currentNames.Count
    $expectedNames = if ($isCurrentSchema) { $currentNames } else { $legacyNames }
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

    $labelKind = 'dmr_id'
    if ($isCurrentSchema) {
        if ($Identity.label_kind -isnot [string] -or $Identity.serial_write_state -isnot [string]) { return $false }
        $revisionProperty = $Identity.PSObject.Properties['cache_revision']
        if ($null -eq $revisionProperty) { return $false }
        $isRevisionNumber = $false
        foreach ($type in $numberTypes) {
            if ($revisionProperty.Value -is $type) { $isRevisionNumber = $true; break }
        }
        if (-not $isRevisionNumber) { return $false }
        $revision = [uint64]0
        if (-not [uint64]::TryParse([string]$revisionProperty.Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$revision)) { return $false }
        $labelKind = [string]$Identity.label_kind
        if ($Identity.serial_write_state -cnotin @('not_sent','pending','attempted','sent','failed')) { return $false }
    }

    if ($Identity.prepared) {
        if ($sourceId -eq 0 -or $generation -eq 0 -or $Identity.label.Length -ne 10) { return $false }
        $decimalId = $sourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
        $expectedLabel = ('ID' + $decimalId).PadRight(10, [char]' ')
        if ($isCurrentSchema) {
            if ($Identity.serial_write_state -ceq 'not_sent' -or $labelKind -ceq 'none') { return $false }
            if ($labelKind -ceq 'dmr_id') {
                if ($revision -ne 0 -or $Identity.label -cne $expectedLabel) { return $false }
            } elseif ($labelKind -ceq 'callsign') {
                $callsign = $Identity.label.TrimEnd([char]' ')
                if ($revision -eq 0 -or $callsign.Length -lt 1 -or $callsign.Length -gt 10 -or
                    $Identity.label -cne $callsign.PadRight(10, [char]' ') -or
                    $callsign -cnotmatch '^[A-Z0-9/-]+$' -or $callsign -cnotmatch '[A-Z]') { return $false }
            } else { return $false }
        } elseif ($Identity.label -cne $expectedLabel) { return $false }
        if ($null -ne $ParentRecord.PSObject.Properties['current_call_valid'] -and
            [bool]$ParentRecord.current_call_valid -and
            ($sourceId -ne [uint64]$ParentRecord.current_call_source_id -or
             $generation -ne [uint64]$ParentRecord.current_call_generation)) { return $false }
    } elseif ($sourceId -ne 0 -or $generation -ne 0 -or $Identity.label.Length -ne 0) {
        return $false
    } elseif ($isCurrentSchema -and ($labelKind -cne 'none' -or $revision -ne 0 -or
            $Identity.serial_write_state -cne 'not_sent')) {
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
    $bmConnectionFields = @('bm_connection','bm_resolving','bm_connection_error')
    $bmConnectionPresent = 0
    foreach ($name in $bmConnectionFields) { if ($null -ne $Record.PSObject.Properties[$name]) { $bmConnectionPresent++ } }
    if ($bmConnectionPresent -ne 0 -and $bmConnectionPresent -ne $bmConnectionFields.Count) { return $false }
    if ($bmConnectionPresent -eq $bmConnectionFields.Count -and
        ($Record.bm_resolving -isnot [bool] -or $Record.bm_connection_error -isnot [string] -or
            -not (Test-UiBmConnectionState -Connection $Record.bm_connection -BmState ([string]$Record.bm_state) `
                -Resolving ([bool]$Record.bm_resolving) -Error ([string]$Record.bm_connection_error)))) { return $false }
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

function Test-UiAudioGainsValue {
    param([object]$Gains)
    return ((Test-UiExactControlFields -Record $Gains -Required @('revision','radio_playback_gain_milli','mic_transmit_gain_milli')) -and
        (Test-UiControlUnsigned -Value $Gains.revision) -and
        (Test-UiControlUnsigned -Value $Gains.radio_playback_gain_milli -Minimum 1000 -Maximum 16000) -and
        ([uint64]$Gains.radio_playback_gain_milli % 1000 -eq 0) -and
        (Test-UiControlUnsigned -Value $Gains.mic_transmit_gain_milli -Minimum 1000 -Maximum 16000) -and
        ([uint64]$Gains.mic_transmit_gain_milli % 1000 -eq 0))
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
    $items = @($Commands)
    if ($items.Count -lt 3 -or $items[0] -cne 'hello' -or $items[1] -cne 'status' -or $items[2] -cne 'shutdown') { return $false }
    $allowed = @('hello','status','shutdown','routing.status','rx_policy.replace','tx_policy.replace',
        'network_subscription.quick_call_join','radio_identity.cache_upsert','audio.gains.set','bm.connection.set')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($command in $items) {
        if ($allowed -cnotcontains [string]$command -or -not $seen.Add([string]$command)) { return $false }
    }
    $routingCount = @('routing.status','rx_policy.replace','tx_policy.replace' | Where-Object { $seen.Contains($_) }).Count
    if ($routingCount -ne 0 -and $routingCount -ne 3) { return $false }
    if ($seen.Contains('network_subscription.quick_call_join') -and $routingCount -ne 3) { return $false }
    return $true
}

function Test-UiHasCapability {
    param([AllowEmptyString()][string]$Capabilities,[Parameter(Mandatory=$true)][string]$Command)
    return (@($Capabilities -split ',' | Where-Object { $_ -ceq $Command }).Count -eq 1)
}

function Test-UiBmConnectionState {
    param([Parameter(Mandatory=$true)][object]$Connection,[Parameter(Mandatory=$true)][string]$BmState,
        [Parameter(Mandatory=$true)][bool]$Resolving,[Parameter(Mandatory=$true)][string]$Error,
        [switch]$RequirePositiveRevision)
    if (-not (Test-UiExactControlFields -Record $Connection -Required @('requested_enabled','revision','transport_open')) -or
        $Connection.requested_enabled -isnot [bool] -or $Connection.transport_open -isnot [bool] -or
        -not (Test-UiControlUnsigned -Value $Connection.revision -Minimum $(if ($RequirePositiveRevision) { 1 } else { 0 })) -or
        $BmState -cnotin @('idle','waiting_login_ack','waiting_auth_ack','waiting_config_ack','waiting_options_ack','ready','backoff','stopped') -or
        $Error -cnotin @('none','password_required','master_resolution_failed','master_resolution_timeout',
            'resolver_cancel_timeout','profile_invalid','transport_open_failed','media_cleanup_timeout')) { return $false }
    if ($Resolving) {
        if ([bool]$Connection.transport_open -or $BmState -cne 'stopped') { return $false }
        if ([bool]$Connection.requested_enabled) {
            if ($Error -cne 'none') { return $false }
        } elseif ($Error -cnotin @('none','master_resolution_timeout','resolver_cancel_timeout')) {
            return $false
        }
    }
    if ($Error -cin @('password_required','master_resolution_failed','profile_invalid','transport_open_failed') -and
        ([bool]$Connection.requested_enabled -or [bool]$Connection.transport_open -or $Resolving -or $BmState -cne 'stopped')) { return $false }
    if ($Error -cin @('master_resolution_timeout','resolver_cancel_timeout') -and -not $Resolving -and
        ([bool]$Connection.requested_enabled -or [bool]$Connection.transport_open -or $BmState -cne 'stopped')) { return $false }
    if ($Error -ceq 'media_cleanup_timeout' -and ([bool]$Connection.requested_enabled -or $Resolving -or
            (-not [bool]$Connection.transport_open -and $BmState -cne 'stopped'))) { return $false }
    if ($Error -ceq 'none' -and $BmState -cin @('waiting_login_ack','waiting_auth_ack','waiting_config_ack','waiting_options_ack','ready','backoff') -and
        -not [bool]$Connection.transport_open) { return $false }
    return $true
}

function Test-UiControlSnapshot {
    param([object]$Snapshot)
    $names = @('mode','status','phase','media_seq','diagnostic','bm_state','hri_phase','hri_ready',
        'serial_open','wavein_open','waveout_open','radio_state')
    $gainAdvertised = Test-UiAudioGainCapability -Capabilities ([string]$script:controlCapabilities)
    $bmConnectionAdvertised = Test-UiHasCapability -Capabilities ([string]$script:controlCapabilities) -Command 'bm.connection.set'
    if ($bmConnectionAdvertised) { $names += @('bm_connection','bm_resolving','bm_connection_error') }
    if ($gainAdvertised) {
        if (-not (Test-UiExactControlFields -Record $Snapshot -Required ($names + @('audio_gains'))) -or
            -not (Test-UiAudioGainsValue -Gains $Snapshot.audio_gains)) { return $false }
    } elseif (-not (Test-UiExactControlFields -Record $Snapshot -Required $names)) { return $false }
    foreach ($name in @('mode','status','phase','bm_state','hri_phase','radio_state')) {
        if ($Snapshot.PSObject.Properties[$name].Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Snapshot.$name)) { return $false }
    }
    if (-not (Test-UiControlUnsigned -Value $Snapshot.media_seq)) { return $false }
    foreach ($name in @('diagnostic','hri_ready','serial_open','wavein_open','waveout_open')) {
        if ($Snapshot.PSObject.Properties[$name].Value -isnot [bool]) { return $false }
    }
    if ($bmConnectionAdvertised) {
        if ($Snapshot.bm_resolving -isnot [bool] -or $Snapshot.bm_connection_error -isnot [string]) { return $false }
        $validBmConnection = Test-UiBmConnectionState -Connection $Snapshot.bm_connection -BmState ([string]$Snapshot.bm_state) `
            -Resolving ([bool]$Snapshot.bm_resolving) -Error ([string]$Snapshot.bm_connection_error)
        if (-not $validBmConnection) { return $false }
    }
    if ($Snapshot.diagnostic -and $bmConnectionAdvertised) { return $false }
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
        if ($record.diagnostic -and @($record.supported_commands | Where-Object { $_ -ceq 'bm.connection.set' }).Count -gt 0) {
            throw '隔离控制运行不得声明 BM 连接命令。'
        }
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
    $validCommands = @('hello','status','shutdown','routing.status','rx_policy.replace','tx_policy.replace',
        'network_subscription.quick_call_join','radio_identity.cache_upsert','audio.gains.set','bm.connection.set')
    if ($record.command -isnot [string] -or $validCommands -cnotcontains $record.command) { throw 'control_result.command 无效。' }
    $specific = switch -CaseSensitive ([string]$record.command) {
        'hello' { @('supported_commands') }
        'status' { @('snapshot') }
        'shutdown' { @('shutdown_requested') }
        'routing.status' { @('routing') }
        'rx_policy.replace' { @('routing') }
        'tx_policy.replace' { @('routing') }
        'network_subscription.quick_call_join' { @('activation_status','destination_id','slot','frames_sent') }
        'radio_identity.cache_upsert' { @() }
        'audio.gains.set' { @('audio_gains') }
        'bm.connection.set' { @('bm_connection','bm_resolving','bm_connection_error','bm_state') }
    }
    if ($record.result -isnot [string] -or @('ok','accepted','unsupported','rejected') -cnotcontains $record.result -or
        ($record.result -ceq 'accepted' -and $record.command -cne 'bm.connection.set') -or
        ($record.command -ceq 'bm.connection.set' -and $record.result -cnotin @('accepted','rejected','unsupported'))) { throw 'control_result.result 无效。' }
    $bmRejected = ($record.command -ceq 'bm.connection.set' -and $record.result -ceq 'rejected')
    $bmUnsupported = ($record.command -ceq 'bm.connection.set' -and $record.result -ceq 'unsupported')
    $bmResultSnapshot = ($record.command -ceq 'bm.connection.set' -and $record.result -cin @('accepted','rejected','unsupported'))
    $hasResultSnapshot = ($record.result -ceq 'ok' -or $record.result -ceq 'accepted' -or $bmResultSnapshot)
    $requiredResultFields = if ($hasResultSnapshot) { $common + $specific + $(if ($bmRejected -or $bmUnsupported) { @('error') } else { @() }) } else { $common + @('error') }
    $optionalResultFields = if ($hasResultSnapshot -and -not $bmRejected -and -not $bmUnsupported) { @('error') } else { @() }
    if (-not (Test-UiExactControlFields -Record $record -Required $requiredResultFields -Optional $optionalResultFields) -or
        $record.run_id -isnot [string] -or $record.request_id -isnot [string] -or
        $record.replayed -isnot [bool] -or -not (Test-UiControlUnsigned -Value $record.control_seq -Minimum 1) -or
        [uint64]$record.control_seq -le $LastControlSequence -or
        [string]::IsNullOrWhiteSpace($LockedRunId) -or $record.run_id -cne $LockedRunId) { throw 'control_result 字段、run_id 或 control_seq 无效。' }
    $requestGuid = [guid]::Empty
    if ($record.command -ceq 'radio_identity.cache_upsert') {
        $identityRevision = [uint64]0
        if ([string]$record.request_id -cnotmatch '^radioid-([1-9][0-9]*)$' -or
            -not [uint64]::TryParse($Matches[1],[Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$identityRevision) -or $identityRevision -eq 0) {
            throw 'radio_identity.cache_upsert 的 request_id 无效。'
        }
    } elseif ($record.command -ceq 'audio.gains.set') {
        $gainRevision = [uint64]0
        if ([string]$record.request_id -cnotmatch '^audio-gains-([1-9][0-9]*)$' -or
            -not [uint64]::TryParse($Matches[1],[Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$gainRevision) -or $gainRevision -eq 0) {
            throw 'audio.gains.set 的 request_id 无效。'
        }
    } elseif (-not [guid]::TryParse([string]$record.request_id, [ref]$requestGuid)) {
        throw 'control_result.request_id 无效。'
    }
    if ($null -ne $record.PSObject.Properties['error'] -and $record.error -isnot [string]) { throw 'control_result.error 必须是字符串。' }
    if ($record.command -ceq 'bm.connection.set') {
        if ($record.result -ceq 'accepted' -and $null -ne $record.PSObject.Properties['error']) { throw 'BM accepted 响应不得包含 error。' }
        if ($record.result -ceq 'rejected' -and [string]::IsNullOrWhiteSpace([string]$record.error)) { throw 'BM rejected 响应必须说明 error。' }
    } elseif ($record.result -cne 'ok' -and [string]::IsNullOrWhiteSpace([string]$record.error)) { throw '拒绝或不支持的响应必须说明 error。' }
    if ($hasResultSnapshot) {
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
            'audio.gains.set' {
                if (-not (Test-UiAudioGainsValue -Gains $record.audio_gains) -or
                    [uint64]$record.audio_gains.revision -ne [uint64]$gainRevision) {
                    throw '音量增益应用结果字段无效。'
                }
            }
            'bm.connection.set' {
                if ($record.bm_resolving -isnot [bool] -or $record.bm_connection_error -isnot [string] -or
                    -not (Test-UiBmConnectionState -Connection $record.bm_connection -BmState ([string]$record.bm_state) `
                        -Resolving ([bool]$record.bm_resolving) -Error ([string]$record.bm_connection_error) `
                        -RequirePositiveRevision:($record.result -ceq 'accepted')) -or
                    ($record.result -ceq 'accepted' -and $record.error)) { throw 'BM连接响应状态字段无效。' }
                if ($record.result -ceq 'rejected' -and [string]$record.error -cnotin @(
                        'bm_revision_stale','bm_revision_conflict','bm_transition_busy',
                        'bm_password_required','bm_master_resolution_failed','bm_profile_invalid','bm_transport_open_failed',
                        'hello_required','invalid_bm_connection_parameters')) {
                    throw 'BM连接拒绝原因无效。'
                }
                if ($record.result -ceq 'unsupported' -and [string]$record.error -cne 'command_not_supported') {
                    throw 'BM连接不支持响应原因无效。'
                }
            }
        }
    } elseif ($record.PSObject.Properties['error'] -and $record.error -isnot [string]) { throw '拒绝响应的 error 字段无效。' }
    return $record
}

function Reset-UiChannelActivationForBmReconnect {
    param([Parameter(Mandatory=$true)][string]$RunId)
    if ([string]::IsNullOrWhiteSpace($RunId) -or -not $script:channelActivationState) { return $false }
    if ($script:queuedQuickCall -and [string]$script:queuedQuickCall.run_id -ceq $RunId) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode bm_not_ready `
            -Message 'BM 连接离开 ready；排队取消，没有发送激活请求。')
    }
    foreach ($pending in @($script:channelActivationState.pending_by_request.Values)) {
        if ([string]$pending.run_id -cne $RunId) { continue }
        $requestId = [string]$pending.request_id
        [void](Add-UiQuickCallDiagnostic -RunId $RunId -RequestId $requestId `
            -DestinationId ([uint64]$pending.destination_id) -Slot ([int]$pending.slot) -Result stale -ErrorCode bm_session_reconnected)
        $script:expiredQuickCallRequests[($RunId + '|' + $requestId)] = $true
        if ($script:expiredQuickCallRequests.Count -gt 128) {
            $oldestKey = [string]@($script:expiredQuickCallRequests.Keys)[0]
            [void]$script:expiredQuickCallRequests.Remove($oldestKey)
        }
        [void]$script:pendingControlRequests.Remove($requestId)
    }
    $script:pendingQuickCall = $null
    Reset-WirexChannelActivationState -State $script:channelActivationState -RunId $RunId | Out-Null
    Add-UiEvent 'BM 连接离开 ready；本机会话的组呼请求标记已清除'
    Update-DynamicGroupControls
    return $true
}

function Clear-UiChannelActivationAfterGroupPtt {
    param([Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][string]$EventName)
    if ($EventName -cnotin @('tx_started_from_radio_ptt_down','tx_started_explicitly_by_t_key') -or
        -not $script:activeRouting -or -not $script:activeRouting.tx_target) { return $false }
    $target = $script:activeRouting.tx_target
    if (-not $target.PSObject.Properties['kind'] -or [string]$target.kind -cne 'group' -or
        -not $target.PSObject.Properties['slot'] -or
        -not (Test-UiControlUnsigned -Value $target.slot -Minimum 1 -Maximum 2) -or
        -not $target.PSObject.Properties['destination_id'] -or
        -not (Test-UiControlUnsigned -Value $target.destination_id -Minimum 1 -Maximum 16777215)) { return $false }
    $destinationId = [uint64]$target.destination_id
    if ($destinationId -eq 4000) { return $false }
    $slotNumber = [int]$target.slot
    $hasDifferentRequestSent = $false
    foreach ($candidate in @($script:channelActivationState.request_sent_by_target.Values)) {
        if (-not $candidate -or [string]$candidate.run_id -cne $RunId -or [int]$candidate.slot -ne $slotNumber) { continue }
        $sent = Get-WirexChannelActivationRequestSent -State $script:channelActivationState -RunId $RunId `
            -ChannelKey ([string]$candidate.channel_key) -Slot $slotNumber
        if (-not $sent) { continue }
        if ([uint64]$sent.destination_id -eq $destinationId) { return $false }
        $hasDifferentRequestSent = $true
    }
    if (-not $hasDifferentRequestSent) { return $false }
    if (-not (Clear-WirexChannelActivationSlot -State $script:channelActivationState -RunId $RunId -Slot $slotNumber)) { return $false }
    Update-DynamicGroupControls
    return $true
}

function Reset-UiControlState {
    param([string]$Text = '本机控制：等待')
    if (-not $script:identityNativeDeferredBySource) { $script:identityNativeDeferredBySource = @{} }
    if ($null -eq $script:identityNativeDeferredOrder) {
        $script:identityNativeDeferredOrder = New-Object 'System.Collections.Generic.List[string]'
    }
    if ($null -eq $script:identityNativeQueue) {
        $script:identityNativeQueue = New-Object 'System.Collections.Generic.List[object]'
    }
    if ($script:identityNativeInFlight) {
        $pendingMapping = [pscustomobject][ordered]@{
            source_id=[uint64]$script:identityNativeInFlight.source_id
            callsign=$script:identityNativeInFlight.callsign
        }
        [void](Save-UiNativeIdentityDeferredMapping -Mapping $pendingMapping)
    }
    foreach ($mapping in $script:identityNativeQueue.ToArray()) {
        if ($mapping -and $mapping.PSObject.Properties['source_id'] -and $mapping.PSObject.Properties['callsign']) {
            [void](Save-UiNativeIdentityDeferredMapping -Mapping $mapping)
        }
    }
    if ($script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode run_changed `
            -Message 'Native 运行会话已结束；排队取消，没有发送激活请求。')
    }
    $script:controlRunId = ''
    $script:controlLastSequence = [uint64]0
    $script:controlConfirmed = $false
    $script:controlCapabilities = ''
    $script:bmConnectionNativeCapability = $false
    $script:bmConnectionSnapshot = $null
    $script:bmConnectionRevision = [uint64]0
    $script:bmConnectionPendingRequest = $null
    $script:bmStatusNextRequestUtc = [DateTime]::MinValue
    $script:lastBmSnapshotUtc = [DateTime]::MinValue
    $script:bmStatusRecoveryStartedUtc = [DateTime]::MinValue
    $script:bmStatusRecoveryCount = 0
    $script:identityNativeCapability = $false
    $script:identityNativeRunId = ''
    $script:identityNativeRevision = [uint64]0
    $script:expiredIdentityNativeRequests = @{}
    if ($script:identityNativeQueue) { $script:identityNativeQueue.Clear() }
    $script:identityNativeInFlight = $null
    $script:routingCapabilities = $false
    $script:quickCallCapabilities = $false
    if (Get-Command -Name Reset-UiAudioGainRun -ErrorAction SilentlyContinue) {
        Reset-UiAudioGainRun -RunId '' -Capability:$false -RestoreSavedValues
    } else {
        $script:audioGainNativeCapability = $false
        $script:audioGainCommandRejected = $false
        $script:audioGainRunId = ''
        $script:audioGainRevision = [uint64]0
        $script:audioGainActual = $null
        $script:audioGainRuntimeReady = $false
        $script:audioGainPendingRequest = $null
    }
    $script:pendingQuickCall = $null
    $script:queuedQuickCall = $null
    $script:expiredQuickCallRequests = @{}
    if ($script:channelActivationState) { Reset-WirexChannelActivationState -State $script:channelActivationState -RunId '' | Out-Null }
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
        Update-RoutingDisplays
        Set-MainText -Name 'DynamicGroupStatus' -Text '请连接核心与 BM 后操作动态组。'
        Update-DynamicGroupControls
    }
}

function Set-UiControlStatus {
    param([string]$Text, [bool]$Confirmed = $false)
    if (-not $Confirmed -and $Text -match '失败|错误|超时|拒绝|未确认') {
        Set-UiTransientStatus -Message $Text -Failed $true -Restart
    }
}

function Get-UiBmConnectionErrorText {
    param([AllowEmptyString()][string]$ErrorCode)
    switch -CaseSensitive ($ErrorCode) {
        'password_required' { return 'BM 连接失败：请先填写 BM 密码并保存配置。' }
        'master_resolution_failed' { return 'BM 主站地址解析失败，请检查地址或网络。' }
        'master_resolution_timeout' { return 'BM 主站解析超时，请检查地址或网络。' }
        'resolver_cancel_timeout' { return 'BM 主站解析取消超时。' }
        'profile_invalid' { return 'BM 连接参数无效；请检查主机、UDP 端口、呼号和 ID。' }
        'transport_open_failed' { return 'BM UDP 传输未能打开；请检查端口和本机网络。' }
        'media_cleanup_timeout' { return 'BM 断开超时，正在清理语音。' }
        default { return '' }
    }
}

function Get-UiBmConnectionRejectText {
    param([Parameter(Mandatory=$true)][string]$ErrorCode)
    switch -CaseSensitive ($ErrorCode) {
        'bm_revision_stale' { return 'BM 状态已更新，请重试。' }
        'bm_revision_conflict' { return 'BM 状态已更新，请重试。' }
        'bm_transition_busy' { return 'BM 正在切换或收发，请稍后重试。' }
        'bm_password_required' { return 'BM 密码未填写；请填写并保存后重新连接。' }
        'bm_master_resolution_failed' { return 'BM 主站地址解析失败；请检查服务器地址和网络后重试。' }
        'bm_profile_invalid' { return 'BM 连接参数无效；请检查呼号、ID、主站和端口。' }
        'bm_transport_open_failed' { return 'BM UDP 连接未能打开；请检查端口和本机网络。' }
        default { return 'BM 连接失败，请检查配置后重试。' }
    }
}

function Set-UiBmConnectionSnapshot {
    param([Parameter(Mandatory=$true)][object]$Connection,[Parameter(Mandatory=$true)][string]$BmState,
        [Parameter(Mandatory=$true)][bool]$Resolving,[Parameter(Mandatory=$true)][string]$ErrorCode,
        [string]$Source='status')
    if (-not (Test-UiBmConnectionState -Connection $Connection -BmState $BmState -Resolving $Resolving -Error $ErrorCode)) { return $false }
    $revision = [uint64]$Connection.revision
    if ($revision -lt [uint64]$script:bmConnectionRevision) { return $false }
    $prior = $script:bmConnectionSnapshot
    $script:bmConnectionSnapshot = [pscustomobject][ordered]@{
        requested_enabled=[bool]$Connection.requested_enabled; revision=$revision
        transport_open=[bool]$Connection.transport_open; resolving=$Resolving; error=$ErrorCode; bm_state=$BmState
    }
    $script:bmConnectionRevision = $revision
    $now = [DateTime]::UtcNow
    $script:lastBmSnapshotUtc = $now
    if ($Source -ceq 'status_jsonl') {
        # 只有持续状态流的新鲜快照才能重新开启恢复查询预算。
        # ACK 和一次性 status 回包不能反复重置预算，否则长期缺少 JSONL 时会耗尽请求缓存。
        $script:bmStatusRecoveryCount = 0
        $script:bmStatusRecoveryStartedUtc = [DateTime]::MinValue
    }
    if ($script:bmConnectionPendingRequest -and $Source -cin @('status_jsonl','control_status') -and
        [bool]$script:bmConnectionPendingRequest.enabled -eq [bool]$Connection.requested_enabled -and
        [uint64]$script:bmConnectionPendingRequest.revision -eq $revision) {
        # 实际状态已反映本次目标时，可继续等待状态完成，不依赖可能丢失的 ACK。
        $script:bmConnectionPendingRequest.ack_received = $true
    }
    $completeDisconnected = (-not [bool]$Connection.requested_enabled -and -not $Resolving -and
        -not [bool]$Connection.transport_open -and $BmState -ceq 'stopped')
    $text = if ($Resolving) { '正在解析 BM 主站' }
        elseif ($completeDisconnected) { '已断开' }
        elseif (-not [bool]$Connection.requested_enabled) { '正在断开' }
        elseif ($ErrorCode -cne 'none') { '连接失败' }
        elseif ($BmState -ceq 'ready') { '已连接' }
        else { '正在连接' }
    if ($BmState -ceq 'backoff' -and [bool]$Connection.requested_enabled -and -not $Resolving) { $text='正在重试' }
    Set-MainText -Name 'BmValue' -Text $text
    $errorText = Get-UiBmConnectionErrorText -ErrorCode $ErrorCode
    if ($errorText) { $detail=$errorText }
    elseif ($completeDisconnected) { $detail='BM 已断开。' }
    elseif ($Resolving) { $detail='正在查找 BM 主站。' }
    elseif ($ErrorCode -ceq 'media_cleanup_timeout') { $detail=$errorText }
    elseif (-not [bool]$Connection.requested_enabled) { $detail=if ($BmState -ceq 'ready' -or [bool]$Connection.transport_open) { '正在断开 BM 并清理语音。' } else { '正在断开 BM。' } }
    elseif ($BmState -ceq 'ready') { $detail='BM 已连接。' }
    elseif ([bool]$Connection.requested_enabled) { $detail='正在连接 BM。' }
    else { $detail='正在断开 BM。' }
    Set-MainText -Name 'BmDetail' -Text $detail
    if ($BmState -ceq 'ready') { [void](Clear-UiTransientStatus -IfMessagePattern '连接\s*BM|BM\s*连接') }
    if ($prior -and ($prior.bm_state -cne $BmState -or [bool]$prior.resolving -ne $Resolving -or
            [bool]$prior.requested_enabled -ne [bool]$Connection.requested_enabled -or
            [bool]$prior.transport_open -ne [bool]$Connection.transport_open)) {
        if ($Resolving) { Add-UiEvent 'BM 主站名称解析中' }
        elseif ($completeDisconnected) { Add-UiEvent 'BM 网络会话已停止并关闭 UDP' }
        elseif ($BmState -ceq 'ready') { Add-UiEvent 'BM 已收到登录确认' }
        elseif (-not [bool]$Connection.requested_enabled) { Add-UiEvent 'BM 正在断开并清理网络媒体' }
    }
    if ($ErrorCode -cne 'none' -and (-not $prior -or [string]$prior.error -cne $ErrorCode)) {
        $errorEventText = Get-UiBmConnectionErrorText -ErrorCode $ErrorCode
        Add-UiEvent $(if ($errorEventText) { $errorEventText } else { 'BM 连接失败，请检查连接设置。' })
    }
    if ($script:bmConnectionPendingRequest -and [bool]$script:bmConnectionPendingRequest.enabled -eq [bool]$Connection.requested_enabled -and
        [uint64]$script:bmConnectionPendingRequest.revision -eq $revision) {
        $requestCompleted = $false
        if ([bool]$script:bmConnectionPendingRequest.enabled) {
            $requestCompleted = ([bool]$Connection.requested_enabled -and -not $Resolving -and $BmState -ceq 'ready') -or
                (-not [bool]$Connection.requested_enabled -and $ErrorCode -cin @('password_required','master_resolution_failed',
                    'master_resolution_timeout','resolver_cancel_timeout','profile_invalid','transport_open_failed'))
        } else {
            $requestCompleted = $completeDisconnected
        }
        if ($requestCompleted) {
            $script:bmConnectionPendingRequest = $null
            $script:bmStatusNextRequestUtc = [DateTime]::MinValue
            $script:bmStatusRecoveryStartedUtc = [DateTime]::MinValue
            $script:bmStatusRecoveryCount = 0
        }
    }
    if ($script:bmConnectAfterCoreReady -and $script:bmConnectionNativeCapability -and
        $script:latestStatus -and [bool]$script:latestStatus.hri_ready -and [bool]$script:latestStatus.hri_y_zero_ready -and
        -not [bool]$Connection.requested_enabled -and $completeDisconnected) {
        $script:bmConnectAfterCoreReady = $false
        [void](Set-UiBmConnectionEnabled -Enabled $true)
    }
    if ($script:serialDisconnectPending -and $script:bmConnectionNativeCapability -and
        [bool]$Connection.requested_enabled -and
        (-not $script:bmConnectionPendingRequest -or
            ([bool]$script:bmConnectionPendingRequest.ack_received -and [bool]$script:bmConnectionPendingRequest.enabled))) {
        [void](Set-UiBmConnectionEnabled -Enabled $false)
    }
    if ($script:serialDisconnectPending -and $completeDisconnected) {
        Complete-UiSerialDisconnectAfterBm
    }
    Set-ConnectionButtonState
    return $true
}

function Set-UiBmConnectionEnabled {
    param([Parameter(Mandatory=$true)][bool]$Enabled)
    if (-not $script:supervisor -or $script:supervisor.HasExited -or -not $script:controlConfirmed -or
        -not $script:bmConnectionNativeCapability -or $script:controlDiagnostic) {
        Set-MainText -Name 'FooterText' -Text '当前无法单独连接 BM，请先断开串口后重连。'
        return $false
    }
    if ($script:bmConnectionPendingRequest -and -not [bool]$script:bmConnectionPendingRequest.ack_received) {
        Set-MainText -Name 'FooterText' -Text '正在确认上一项 BM 连接请求。'
        return $false
    }
    if (-not $script:bmConnectionSnapshot) {
        Request-UiControlStatus
        Set-MainText -Name 'FooterText' -Text '正在读取 BM 当前连接状态。'
        return $false
    }
    if ([bool]$script:bmConnectionSnapshot.requested_enabled -eq $Enabled) {
        if ($Enabled -and [string]$script:bmConnectionSnapshot.bm_state -ceq 'ready' -and -not [bool]$script:bmConnectionSnapshot.resolving) { return $true }
        if (-not $Enabled -and [string]$script:bmConnectionSnapshot.bm_state -ceq 'stopped' -and
            -not [bool]$script:bmConnectionSnapshot.resolving -and -not [bool]$script:bmConnectionSnapshot.transport_open) { return $true }
    }
    $hriReady = ($script:latestStatus -and $script:lastStatusUtc -ne [DateTime]::MinValue -and
        ([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3 -and
        [bool]$script:latestStatus.hri_ready -and [bool]$script:latestStatus.hri_y_zero_ready)
    if ($Enabled -and -not $hriReady) {
        $script:bmConnectAfterCoreReady = $true
        Request-UiControlStatus
        Set-MainText -Name 'FooterText' -Text 'BM 连接请求已排队，等待 HRI 就绪。'
        return $true
    }
    if ([uint64]$script:bmConnectionRevision -eq [uint64]::MaxValue) {
        Set-MainText -Name 'FooterText' -Text 'BM 连接状态异常，请重新连接串口。'
        return $false
    }
    $revision = [uint64]($script:bmConnectionRevision + [uint64]1)
    $requestId = [guid]::NewGuid().ToString('D')
    $payload = [ordered]@{ enabled=$Enabled; revision=$revision }
    $json = ConvertTo-Json -InputObject $payload -Compress
    $pending = [pscustomobject][ordered]@{
        request_id=$requestId; enabled=$Enabled; revision=$revision
        started_utc=[DateTime]::UtcNow; ack_received=$false
    }
    $script:bmConnectionPendingRequest = $pending
    $script:pendingControlRequests[$requestId] = 'bm.connection.set'
    $script:bmStatusNextRequestUtc = [DateTime]::UtcNow.AddSeconds(1)
    $script:bmStatusRecoveryStartedUtc = [DateTime]::UtcNow
    $script:bmStatusRecoveryCount = 0
    if (-not $Enabled -and $script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode bm_disconnect_requested `
            -Message '正在断开 BM；排队取消，没有发送激活请求。')
    }
    if (-not $script:supervisor.SendControlCommand($requestId,'bm.connection.set',$json)) {
        [void]$script:pendingControlRequests.Remove($requestId)
        $script:bmConnectionPendingRequest = $null
        Set-MainText -Name 'FooterText' -Text '核心没有接收 BM 连接请求；当前连接状态保持不变。'
        Set-ConnectionButtonState
        return $false
    }
    Set-MainText -Name 'FooterText' -Text $(if ($Enabled) { '正在连接 BM；等待核心状态确认。' } else { '正在断开 BM；HRI 与 CAT 保持运行。' })
    Set-ConnectionButtonState
    return $true
}

function Update-UiBmConnectionPoll {
    if (-not $script:bmConnectionNativeCapability -or (-not $script:bmConnectionPendingRequest -and -not $script:serialDisconnectPending) -or
        -not $script:controlConfirmed -or -not $script:supervisor -or $script:supervisor.HasExited) { return }
    $now = [DateTime]::UtcNow
    $snapshot = $script:bmConnectionSnapshot
    $completeDisconnected = ($snapshot -and -not [bool]$snapshot.requested_enabled -and -not [bool]$snapshot.resolving -and
        -not [bool]$snapshot.transport_open -and [string]$snapshot.bm_state -ceq 'stopped')
    if ($script:serialDisconnectPending -and $script:serialDisconnectDeadlineUtc -ne [DateTime]::MinValue -and
        $now -ge $script:serialDisconnectDeadlineUtc -and -not $completeDisconnected) {
        $script:serialDisconnectPending = $false
        $script:serialDisconnectCoreStopIssued = $false
        $script:serialDisconnectCatStopRequested = $false
        $script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
        $script:bmConnectAfterCoreReady = $false
        $message = if ($snapshot -and [bool]$snapshot.resolving) { 'BM 主站仍在解析，串口保持连接。' }
            elseif ($snapshot -and ([bool]$snapshot.transport_open -or [string]$snapshot.bm_state -cne 'stopped')) { 'BM 网络仍在清理，串口保持连接。' }
            elseif (-not $snapshot) { 'BM 状态未确认，串口保持连接。' }
            else { 'BM 会话仍未停止，串口保持连接。' }
        Set-MainText -Name 'FooterText' -Text $message
        Add-UiEvent '串口断开等待超时；HRI 和 CAT 仍保持连接'
        Set-ConnectionButtonState
        return
    }
    if ($script:lastBmSnapshotUtc -ne [DateTime]::MinValue -and
        ($now - $script:lastBmSnapshotUtc).TotalSeconds -le 3) { return }
    if ($script:bmStatusNextRequestUtc -gt $now -or $script:pendingStatusRequestId) { return }
    if ($script:bmStatusRecoveryStartedUtc -eq [DateTime]::MinValue) { $script:bmStatusRecoveryStartedUtc=$now }
    if ($script:bmStatusRecoveryCount -ge 3 -or ($now - $script:bmStatusRecoveryStartedUtc).TotalSeconds -ge 12) {
        if ($script:bmConnectionPendingRequest -and -not [bool]$script:bmConnectionPendingRequest.ack_received) {
            Add-UiEvent 'BM 连接状态尚未更新；请检查当前连接状态后重试。'
        } elseif ($script:serialDisconnectPending) {
            Add-UiEvent 'BM 状态尚未更新；串口保持连接等待关闭确认。'
        }
        $script:bmStatusNextRequestUtc = [DateTime]::MaxValue
        return
    }
    Request-UiControlStatus
    if ($script:pendingStatusRequestId) {
        $script:bmStatusRecoveryCount++
        $script:bmStatusNextRequestUtc=$now.AddSeconds(2)
    }
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
        return
    }
}

function Process-UiControlEvents {
    if (-not $script:supervisor -or $script:supervisor.ControlVersion -ne 2) { return }
    if ($script:supervisor.HasControlEventOverflow -and -not $script:controlOverflowHandled) {
        $script:controlOverflowHandled = $true
        $script:controlConfirmed = $false
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
            Set-UiControlStatus -Text ('核心控制状态校验失败：' + $_.Exception.Message) -Confirmed $false
            Add-UiEvent '控制协议帧校验失败'
            continue
        }
        $script:controlLastSequence = [uint64]$record.control_seq
        if ($script:channelMutationSafetyStopPending -and
            ($record.type -ceq 'routing_state' -or $record.command -in @('routing.status','rx_policy.replace','tx_policy.replace'))) {
            continue
        }
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
            Reset-WirexChannelActivationState -State $script:channelActivationState -RunId $script:controlRunId | Out-Null
            $script:controlDiagnostic = [bool]$record.diagnostic
            $script:controlCapabilities = @($record.supported_commands) -join ','
            $gainCapability = Test-UiAudioGainCapability -Capabilities $script:controlCapabilities
            $script:bmConnectionNativeCapability = Test-UiHasCapability -Capabilities $script:controlCapabilities -Command 'bm.connection.set'
            if (Get-Command -Name Reset-UiAudioGainRun -ErrorAction SilentlyContinue) {
                Reset-UiAudioGainRun -RunId $script:controlRunId -Capability:$gainCapability -RestoreSavedValues
            } else {
                $script:audioGainNativeCapability = $gainCapability
                $script:audioGainCommandRejected = $false
                $script:audioGainRunId = $script:controlRunId
                $script:audioGainRevision = [uint64]0
                $script:audioGainActual = $null
                $script:audioGainRuntimeReady = $false
                $script:audioGainPendingRequest = $null
            }
            $script:routingCapabilities = ((Test-UiHasCapability -Capabilities $script:controlCapabilities -Command 'routing.status') -and
                (Test-UiHasCapability -Capabilities $script:controlCapabilities -Command 'rx_policy.replace') -and
                (Test-UiHasCapability -Capabilities $script:controlCapabilities -Command 'tx_policy.replace'))
            $script:quickCallCapabilities = (Test-UiHasCapability -Capabilities $script:controlCapabilities -Command 'network_subscription.quick_call_join')
            $script:identityNativeCapability = (Test-UiHasCapability -Capabilities $script:controlCapabilities -Command 'radio_identity.cache_upsert')
            $script:bmConnectionSnapshot = $null
            $script:bmConnectionRevision = [uint64]0
            $script:bmConnectionPendingRequest = $null
            $script:bmStatusNextRequestUtc = [DateTime]::MinValue
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
        if ($record.command -ceq 'radio_identity.cache_upsert') {
            $expiredIdentityKey = ([string]$record.run_id + '|' + [string]$record.request_id)
            if ($script:expiredIdentityNativeRequests.ContainsKey($expiredIdentityKey)) {
                [void]$script:expiredIdentityNativeRequests.Remove($expiredIdentityKey)
                continue
            }
        }
        if ($record.command -ceq 'audio.gains.set' -and $script:audioGainExpiredRequests.ContainsKey([string]$record.request_id)) {
            [void](Consume-UiAudioGainExpiredResult -Record $record)
            continue
        }
        if ($record.command -ceq 'network_subscription.quick_call_join') {
            $expiredQuickCallKey = ([string]$record.run_id + '|' + [string]$record.request_id)
            if ($script:expiredQuickCallRequests.ContainsKey($expiredQuickCallKey)) {
                [void]$script:expiredQuickCallRequests.Remove($expiredQuickCallKey)
                continue
            }
        }
        if ($record.command -ceq 'audio.gains.set' -and $script:audioGainPendingRequest -and
            [string]$script:audioGainPendingRequest.request_id -ceq [string]$record.request_id -and
            [string]$script:audioGainPendingRequest.run_id -ceq [string]$record.run_id -and
            ([DateTime]::UtcNow - [DateTime]$script:audioGainPendingRequest.started_utc).TotalSeconds -ge 8) {
            [void](Expire-UiAudioGainRequest)
            [void](Consume-UiAudioGainExpiredResult -Record $record)
            continue
        }
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
        if ($record.command -ceq 'radio_identity.cache_upsert') {
            if (-not (Complete-UiNativeIdentityUpdate -Record $record)) {
                Set-UiControlStatus -Text '核心返回了不匹配的身份缓存确认' -Confirmed $false
            }
            continue
        }
        if ($record.command -ceq 'bm.connection.set') {
            $bmPending = $script:bmConnectionPendingRequest
            if (-not $bmPending -or [string]$bmPending.request_id -cne [string]$record.request_id) {
                Set-UiControlStatus -Text '核心返回了不匹配的 BM 连接确认' -Confirmed $false
                Request-UiControlStatus
                continue
            }
            if ($record.result -ceq 'accepted') {
                if ([uint64]$record.bm_connection.revision -ne [uint64]$bmPending.revision -or
                    [bool]$record.bm_connection.requested_enabled -ne [bool]$bmPending.enabled) {
                    $script:bmConnectionPendingRequest = $null
                    Set-UiControlStatus -Text 'BM 连接确认与请求版本不一致；正在读取核心实际状态。' -Confirmed $false
                    Request-UiControlStatus
                    continue
                }
                $bmPending.ack_received = $true
                [void](Set-UiBmConnectionSnapshot -Connection $record.bm_connection -BmState ([string]$record.bm_state) `
                    -Resolving ([bool]$record.bm_resolving) -ErrorCode ([string]$record.bm_connection_error) -Source ack)
                Set-UiControlStatus -Text $(if ([bool]$bmPending.enabled) { '正在连接 BM。' } else { '正在断开 BM。' }) -Confirmed $true
            } else {
                [void](Set-UiBmConnectionSnapshot -Connection $record.bm_connection -BmState ([string]$record.bm_state) `
                    -Resolving ([bool]$record.bm_resolving) -ErrorCode ([string]$record.bm_connection_error) -Source rejected)
                $script:bmConnectionPendingRequest = $null
                Set-MainText -Name 'FooterText' -Text (Get-UiBmConnectionRejectText -ErrorCode ([string]$record.error))
                Set-UiControlStatus -Text 'BM 连接切换遭核心拒绝；当前实际状态已刷新。' -Confirmed $true
            }
            Set-ConnectionButtonState
            continue
        }
        if ($record.result -cne 'ok') {
            $detail = if ($record.PSObject.Properties['error']) { [string]$record.error } else { [string]$record.result }
            if ($record.command -ceq 'audio.gains.set') {
                Complete-UiAudioGainFailure -Record $record
                continue
            }
            if ($record.command -ceq 'network_subscription.quick_call_join') {
                if ($RoutingDiagnosticAutoTest) {
                    if ($script:pendingQuickCall -and $script:pendingQuickCall.request_id -ceq [string]$record.request_id -and
                        $script:pendingQuickCall.run_id -ceq [string]$record.run_id) { $script:pendingQuickCall = $null }
                    Fail-UiRoutingDiagnosticAutoTest -Message '本地频道诊断中的组呼激活请求未获确认。'
                    continue
                }
                $completion = Complete-WirexChannelActivationRequest -State $script:channelActivationState `
                    -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) `
                    -Result ([string]$record.result)
                if (-not $completion.matched) {
                    if ($script:pendingQuickCall -and $script:pendingQuickCall.request_id -ceq [string]$record.request_id -and
                        $script:pendingQuickCall.run_id -ceq [string]$record.run_id) {
                        [void](Add-UiQuickCallDiagnostic -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) `
                            -DestinationId ([uint64]$script:pendingQuickCall.destination_id) -Slot ([int]$script:pendingQuickCall.slot) `
                            -Result stale -ErrorCode unmatched_result)
                    }
                    Update-DynamicGroupControls
                    continue
                }
                if ($script:pendingQuickCall -and $script:pendingQuickCall.request_id -ceq [string]$record.request_id -and
                    $script:pendingQuickCall.run_id -ceq [string]$record.run_id) { $script:pendingQuickCall = $null }
                if (-not $completion.current) {
                    [void](Add-UiQuickCallDiagnostic -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) `
                        -DestinationId ([uint64]$completion.request.destination_id) -Slot ([int]$completion.request.slot) `
                        -Result stale -ErrorCode superseded_result)
                    Update-DynamicGroupControls
                    continue
                }
                [void](Add-UiQuickCallDiagnostic -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) `
                    -DestinationId ([uint64]$completion.request.destination_id) -Slot ([int]$completion.request.slot) `
                    -Result ([string]$record.result) -ErrorCode $detail)
                $quickCallError = switch -CaseSensitive ($detail) {
                    'media_busy' { '激活失败：本机媒体仍忙。' }
                    'quick_call_not_ready' { '激活失败：本机控制、BM连接或传输未就绪。' }
                    'invalid_or_forbidden_group' { '激活失败：组号或时隙无效。' }
                    'disconnect_group_forbidden' { 'TG 4000 是断开组，不能激活。' }
                    'quick_call_send_failed' { '激活失败：本机没有发出完整请求。' }
                    'quick_call_partial_send' { '激活失败：请求只发送了一部分；本机没有重试。' }
                    'quick_call_send_incomplete' { '激活失败：本机没有确认完整发送。' }
                    default { '激活失败：' + $detail }
                }
                Set-UiControlStatus -Text '动态组激活未完成' -Confirmed $script:controlConfirmed
                if ($detail -ceq 'quick_call_partial_send') {
                    Add-UiEvent '动态组激活部分发送：header 已发送，EOT 发送失败；核心没有重试'
                } else {
                    Add-UiEvent ('动态组激活失败：' + $detail)
                }
                Set-DynamicGroupStatus $quickCallError -Failed $true
                Update-DynamicGroupControls
                continue
            }
            Set-UiControlStatus -Text ('设置操作失败：' + $detail) -Confirmed $script:controlConfirmed
            if ($record.command -in @('rx_policy.replace','tx_policy.replace')) {
                if ($record.command -ceq 'rx_policy.replace' -and $script:pendingDynamicLocalListen) {
                    $route = $script:pendingDynamicLocalListen
                    $script:pendingDynamicLocalListen = $null
                    Set-DynamicGroupStatus ('核心拒绝了本机收听规则 TG {0}：{1}' -f $route.destination_id,$detail) -Failed $true
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
                    $channelMutation = $script:pendingChannelMutation
                    if ($channelMutation -and $failedMutation.command -ceq 'tx_policy.replace' -and
                        [string]$channelMutation.stage -ceq 'tx') {
                        $script:pendingChannelMutation = $null
                        Set-UiChannelStatus -Text ('核心明确拒绝新的 PTT 目标；原频道和配置保留：' + $detail) -Failed $true
                        Update-UiChannelDisplays
                    } elseif ($channelMutation -and $failedMutation.command -ceq 'rx_policy.replace' -and
                        [string]$channelMutation.stage -ceq 'rx' -and [bool]$channelMutation.tx_applied) {
                        [void](Start-UiChannelMutationSafetyStop -Reason ('PTT目标已应用，但监听频道更新遭到拒绝：' + $detail))
                        continue
                    } elseif ($channelMutation -and $failedMutation.command -ceq 'rx_policy.replace' -and
                        [string]$channelMutation.stage -ceq 'rx') {
                        $script:pendingChannelMutation = $null
                        Set-UiChannelStatus -Text ('核心明确拒绝新的监听频道；原频道和配置保留：' + $detail) -Failed $true
                        Update-UiChannelDisplays
                    }
                    $script:routingMutationFence = $true
                    Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                    Set-RoutingEditorStatus -Text ('核心拒绝了这项设置；正在读取当前运行设置。' + $detail) -Failed $true
                    if ($failedMutation.command -ceq 'tx_policy.replace') {
                        Set-MainText -Name 'CallTargetStatusValue' -Text ('核心未接受下一起呼目标设置：' + $detail)
                        if ($script:pendingDynamicCallTarget -and [uint64]$script:pendingDynamicCallTarget.destination_id -eq [uint64]$failedMutation.target.destination_id -and [uint64]$script:pendingDynamicCallTarget.slot -eq [uint64]$failedMutation.target.slot) {
                            Set-DynamicGroupStatus ('核心未接受 TG {0} 起呼目标设置：{1}' -f $failedMutation.target.destination_id,$detail) -Failed $true
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
            if ($RoutingDiagnosticAutoTest -and $record.command -in @('rx_policy.replace','tx_policy.replace')) {
                Fail-UiRoutingDiagnosticAutoTest -Message '本机频道更新命令遭到核心拒绝。'
                continue
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
                if ($script:identityNativeCapability) { [void](Initialize-UiNativeIdentitySync) }
                if ($script:audioGainNativeCapability -or $script:bmConnectionNativeCapability) { Request-UiControlStatus }
                if ($script:bmConnectAfterCoreReady -and $script:bmConnectionNativeCapability) {
                    Set-MainText -Name 'FooterText' -Text 'BM 连接请求将在 HRI 就绪后发送。'
                }
                Set-ConnectionButtonState
            }
            'network_subscription.quick_call_join' {
                $pendingQuickCall = $script:pendingQuickCall
                if ($RoutingDiagnosticAutoTest -and $script:routingDiagnosticAutoTestPhase -ne 3) {
                    Fail-UiRoutingDiagnosticAutoTest -Message '频道添加流程触发了意外组呼激活。'
                    continue
                }
                if ($RoutingDiagnosticAutoTest) {
                    if ($script:routingDiagnosticAutoTestPhase -ne 3 -or [uint64]$record.destination_id -ne 12345 -or [uint64]$record.slot -ne 1 -or
                        [uint64]$record.frames_sent -ne 2 -or [string]$record.activation_status -cne 'request_sent' -or
                        [bool]$record.replayed) {
                        Fail-UiRoutingDiagnosticAutoTest -Message '频道动态组激活没有返回预期的两帧内存发送结果。'
                        continue
                    }
                    $script:routingDiagnosticQuickCallResponse = [pscustomobject][ordered]@{
                        command=[string]$record.command; destination_id=[uint64]$record.destination_id
                        slot=[uint64]$record.slot; frames_sent=[uint64]$record.frames_sent
                        activation_status=[string]$record.activation_status; replayed=[bool]$record.replayed
                    }
                    $script:routingDiagnosticAutoTestPhase = 4
                    Set-UiControlStatus -Text '本机频道与组呼诊断已完成，正在复读状态。' -Confirmed $true
                    Write-UiRoutingDiagnosticProgress -Message 'channel-quick-call-result-received'
                    Request-UiRoutingStatus
                    Update-DynamicGroupControls
                    continue
                }
                $completion = Complete-WirexChannelActivationRequest -State $script:channelActivationState `
                    -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) -Result ok `
                    -ActivationStatus ([string]$record.activation_status) -DestinationId $record.destination_id `
                    -Slot $record.slot -FramesSent $record.frames_sent -Replayed ([bool]$record.replayed)
                if ($pendingQuickCall -and $pendingQuickCall.request_id -ceq [string]$record.request_id -and
                    $pendingQuickCall.run_id -ceq [string]$record.run_id) { $script:pendingQuickCall = $null }
                if (-not $completion.matched -or -not $completion.current -or -not $completion.sent) {
                    if ($completion.matched) {
                        $nativeResultError = if ($completion.current) { 'invalid_native_result' } else { 'superseded_result' }
                        [void](Add-UiQuickCallDiagnostic -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) `
                            -DestinationId ([uint64]$completion.request.destination_id) -Slot ([int]$completion.request.slot) `
                            -Result $(if ($completion.current) { 'rejected' } else { 'stale' }) -ErrorCode $nativeResultError `
                            -ActivationStatus ([string]$record.activation_status) `
                            -FramesSent $record.frames_sent -Replayed ([bool]$record.replayed))
                        if ($completion.current) {
                            Set-DynamicGroupStatus ('TG {0} TS{1}：本机 Native 结果未确认两帧已发送；请检查连接后手动重试。' -f `
                                $completion.request.destination_id,$completion.request.slot) -Failed $true
                        }
                    }
                    Update-DynamicGroupControls
                    continue
                }
                [void](Add-UiQuickCallDiagnostic -RunId ([string]$record.run_id) -RequestId ([string]$record.request_id) `
                    -DestinationId ([uint64]$completion.request.destination_id) -Slot ([int]$completion.request.slot) `
                    -Result ok -ActivationStatus ([string]$record.activation_status) -FramesSent $record.frames_sent `
                    -Replayed ([bool]$record.replayed))
                Set-UiControlStatus -Text '激活请求已发送' -Confirmed $true
                Add-UiEvent ('Native 确认激活请求已发送两帧 · TG {0} TS{1}' -f `
                    $completion.request.destination_id,$completion.request.slot)
                Set-DynamicGroupStatus ('TG {0} TS{1} 激活请求已发送。' -f `
                    $completion.request.destination_id,$completion.request.slot)
                if ($record.replayed) { Add-UiEvent '读取本机缓存的发送结果；没有再次发送帧' }
                Update-DynamicGroupControls
            }
            'status' {
                $snapshot = $record.snapshot
                if ($script:audioGainNativeCapability) { [void](Complete-UiAudioGainStatus -Snapshot $snapshot) }
                if ($script:bmConnectionNativeCapability) {
                    [void](Set-UiBmConnectionSnapshot -Connection $snapshot.bm_connection -BmState ([string]$snapshot.bm_state) `
                        -Resolving ([bool]$snapshot.bm_resolving) -ErrorCode ([string]$snapshot.bm_connection_error) -Source control_status)
                    $script:bmStatusNextRequestUtc = [DateTime]::UtcNow.AddSeconds(1)
                }
                if ([bool]$snapshot.diagnostic) {
                    $statusText = '仅本机诊断：未连接 BM、HRI 或音频设备'
                } else {
                    $replayText = if ($record.replayed) { '重放摘要' } else { '状态摘要' }
                    $statusText = ('{0}：{1} / {2} · media_seq {3}' -f $replayText, $snapshot.status, $snapshot.phase, $snapshot.media_seq)
                }
                # This control snapshot never refreshes the v1 media cards or their freshness clock.
                Set-UiControlStatus -Text $statusText -Confirmed $true
            }
            'audio.gains.set' {
                if (-not (Complete-UiAudioGainResult -Record $record)) {
                    Set-UiControlStatus -Text '核心返回了不匹配的增益确认' -Confirmed $false
                }
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
                        if ($mutation.command -ceq 'tx_policy.replace' -or
                            ($mutation.command -ceq 'rx_policy.replace' -and $script:pendingChannelMutation -and
                                [bool]$script:pendingChannelMutation.tx_applied)) {
                            [void](Start-UiChannelMutationSafetyStop -Reason '频道路由返回重复结果，无法确认本次目标状态')
                            continue
                        }
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
                    if ($record.command -ceq 'tx_policy.replace' -or
                        ($record.command -ceq 'rx_policy.replace' -and $script:pendingChannelMutation -and
                            [bool]$script:pendingChannelMutation.tx_applied)) {
                        [void](Start-UiChannelMutationSafetyStop -Reason '核心返回的频道目标状态无效')
                        continue
                    }
                    Set-UiControlStatus -Text ('核心返回的设置状态无效：' + $_.Exception.Message) -Confirmed $false
                    Request-UiRoutingStatus
                    continue
                }
                if (-not $snapshotAccepted) {
                    if ($record.command -ceq 'tx_policy.replace' -or
                        ($record.command -ceq 'rx_policy.replace' -and $script:pendingChannelMutation -and
                            [bool]$script:pendingChannelMutation.tx_applied)) {
                        [void](Start-UiChannelMutationSafetyStop -Reason '核心返回的频道目标状态未能应用')
                        continue
                    }
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
                    if ($RoutingDiagnosticAutoTest -and $script:routingDiagnosticAutoTestPhase -eq 4) {
                        Complete-UiRoutingDiagnosticAutoTest -Mutation $null -Routing $record.routing
                    }
                    continue
                }
                if ($script:pendingRoutingMutation -and $script:pendingRoutingMutation.request_id -ceq [string]$record.request_id) { $script:pendingRoutingMutation = $null }
                [void]$script:timedOutRoutingMutations.Remove([string]$record.request_id)
                $script:routingDraftPreservedAfterTimeout = ($script:timedOutRoutingMutations.Count -gt 0)
                if ($script:routingMutationFence -and $script:timedOutRoutingMutations.Count -eq 0) { $script:routingMutationFence = $false }
                Set-RoutingMutationPendingState -Pending ([bool]$script:pendingRoutingMutation)
                Save-UiRoutingMutationAfterAck -Mutation $mutation -Routing $record.routing
                if ($script:channelMutationSafetyStopPending) { continue }
                Set-UiControlStatus -Text $(if ($mutation.command -ceq 'tx_policy.replace') { '下一起呼目标设置已确认' } else { '设置已应用' }) -Confirmed $true
                if ($mutation.command -ceq 'tx_policy.replace' -and $script:pendingDynamicCallTarget -and
                    [uint64]$script:pendingDynamicCallTarget.destination_id -eq [uint64]$mutation.target.destination_id -and
                    [uint64]$script:pendingDynamicCallTarget.slot -eq [uint64]$mutation.target.slot) {
                    Set-DynamicGroupStatus ('核心已确认 TG {0} 为下一起呼叫目标；没有发起呼叫，收听规则未变。' -f $mutation.target.destination_id)
                    $script:pendingDynamicCallTarget = $null
                }
                if ($record.command -ceq 'rx_policy.replace' -and $script:pendingDynamicLocalListen) {
                    $route = $script:pendingDynamicLocalListen
                    $script:pendingDynamicLocalListen = $null
                    Set-DynamicGroupStatus ('本机收听规则已由核心确认：TG {0}；没有发送动态组激活请求。' -f $route.destination_id)
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
        [Parameter(Mandatory=$true)][string]$ExpectedExecutable,
        [switch]$BmStartDisconnected
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
    $switchOptions = @('--run', '--ui-pipe', '--listen-only', '--bm-start-disconnected')
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
        '--ui-control-version', '--profile-callsign', '--profile-gateway-id', '--profile-source-id',
        '--profile-master', '--profile-master-port', '--profile-destination-id', '--profile-slot',
        '--profile-color-code', '--profile-call-kind', '--routing-state-file'
    )) {
        if (-not $parsedArguments.ContainsKey($requiredOption)) { throw '设备预检返回的启动参数不完整。' }
    }
    if (-not $BmStartDisconnected -and -not $parsedArguments.ContainsKey('--password-file')) {
        throw '设备预检缺少 BM 密码文件参数。'
    }
    if ([bool]$parsedArguments.ContainsKey('--bm-start-disconnected') -ne [bool]$BmStartDisconnected) {
        throw '设备预检的 BM 启动模式与本次连接请求不一致。'
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
    param([switch]$UseProductionOrchestration)
    if ($RoutingDiagnostic) {
        $script:deviceDiscoveryState = 'diagnostic'
        $script:deviceCatalog = [pscustomobject]@{ serial_ports=@(); hri_ports=@(); wave_inputs=@(); wave_outputs=@() }
        Set-SettingsDeviceControls
        if ($script:mainWindow) {
            (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
            Set-UiTransientStatus -Message '本地协议诊断：未查询真实串口或音频设备。' -Restart
        }
        return
    }
    if ($OfflinePreview -or $RenderOnly) {
        $script:deviceDiscoveryState = 'offline'
        Set-SettingsDeviceControls
        return
    }
    if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery -or $script:uiTestDiscoveryResult -or
        $null -ne $script:deviceSerialResult -or $null -ne $script:deviceAudioResult) {
        if ($script:mainWindow -and -not [object]::ReferenceEquals($script:mainWindow, $script:deviceDiscoveryOwnerWindow)) {
            $script:deviceDiscoveryRestartPending = $true
            (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
            Set-MainText -Name 'FooterText' -Text '正在停止上次设备查询，随后刷新串口和音频列表。'
        }
        return
    }

    $script:deviceDiscoveryGeneration++
    $script:deviceDiscoveryActiveGeneration = $script:deviceDiscoveryGeneration
    $script:deviceDiscoveryOwnerWindow = $script:mainWindow
    $script:deviceDiscoveryStopReason = ''
    $script:deviceDiscoveryError = ''
    $script:deviceDiscoveryState = 'loading'
    $script:deviceSerialState = 'loading'
    $script:deviceAudioState = 'loading'
    if ($script:mainWindow) {
        (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
        Set-MainText -Name 'FooterText' -Text '正在读取串口与音频设备列表。'
        Set-SettingsDeviceControls
    }
    if ($UiTestFixture -and -not $UseProductionOrchestration) {
        $context = [pscustomobject]@{ generation=[uint64]$script:deviceDiscoveryActiveGeneration; user_config_directory=[string]$script:configDirectory }
        $serialResult = $null
        $audioResult = $null
        foreach ($hookName in @('SerialEnumerator','AudioQuery')) {
            $hookResult = $null
            $hookError = ''
            try {
                if ($script:uiTestHooks.ContainsKey($hookName)) { $hookResult = & $script:uiTestHooks[$hookName] $context }
                else { $hookResult = [pscustomobject]@{ status='error'; error='missing_test_hook' } }
                if ($null -eq $hookResult -or $hookResult.status -notin @('success','error','timeout')) { throw '测试设备 Hook 返回了无效状态。' }
            } catch { $hookError = $_.Exception.Message; $hookResult = [pscustomobject]@{ status='error'; error=$hookError } }
            if ($hookName -ceq 'SerialEnumerator') { $serialResult = $hookResult } else { $audioResult = $hookResult }
        }
        $script:uiTestDiscoveryResult = [pscustomobject]@{ generation=$script:deviceDiscoveryActiveGeneration; owner=$script:deviceDiscoveryOwnerWindow; serial=$serialResult; audio=$audioResult }
        return
    }
    $script:deviceSerialResult = $null
    $script:deviceAudioResult = $null
    $script:deviceSerialStopPending = $false
    $script:deviceAudioStopPending = $false
    $hookContext = [pscustomobject]@{ generation=[uint64]$script:deviceDiscoveryActiveGeneration; user_config_directory=[string]$script:configDirectory }
    $hasSerialHook = $script:uiTestHooks.ContainsKey('SerialEnumerator') -and $script:uiTestHooks.SerialEnumerator -is [scriptblock]
    $hasAudioHook = $script:uiTestHooks.ContainsKey('AudioQuery') -and $script:uiTestHooks.AudioQuery -is [scriptblock]
    if ($hasSerialHook) {
        try {
            $hookSerial = & $script:uiTestHooks.SerialEnumerator $hookContext
            if ($null -eq $hookSerial -or [string]$hookSerial.status -notin @('success','error','timeout')) { throw '串口枚举 Hook 返回了无效结果。' }
            $script:deviceSerialResult = $hookSerial
            $script:deviceSerialState = if ($hookSerial.status -ceq 'success') { 'ready' } else { [string]$hookSerial.status }
            $script:deviceSerialError = [string]$hookSerial.error
        } catch {
            $script:deviceSerialState = 'error'
            $script:deviceSerialError = $_.Exception.Message
            $script:deviceSerialResult = [pscustomobject]@{ status='error'; error=$script:deviceSerialError; serial_ports=@(); hri_ports=@() }
        }
    }
    try {
        if ($hasAudioHook) {
            $hookAudio = & $script:uiTestHooks.AudioQuery $hookContext
            if ($null -eq $hookAudio -or [string]$hookAudio.status -notin @('success','error','timeout')) { throw '音频查询 Hook 返回了无效结果。' }
            if ($hookAudio.status -ceq 'success' -and ($hookAudio.wave_inputs -isnot [array] -or $hookAudio.wave_outputs -isnot [array])) { throw '音频查询 Hook 缺少 wave_inputs 或 wave_outputs 数组。' }
            $script:deviceAudioResult = $hookAudio
            $script:deviceAudioState = if ($hookAudio.status -ceq 'success') { 'ready' } else { [string]$hookAudio.status }
            $script:deviceAudioError = [string]$hookAudio.error
        } else {
            $script:deviceAudioQuery = Start-UiAudioQuery -Executable $script:nativeExecutable
        }
    } catch {
        $script:deviceAudioQuery = $null
        $script:deviceAudioState = 'error'
        $script:deviceAudioError = $_.Exception.Message
        $script:deviceAudioResult = [pscustomobject]@{ status='error'; error=$script:deviceAudioError; wave_inputs=@(); wave_outputs=@() }
    }
    $catalogScript = {
        param([Parameter(Mandatory=$true)][string]$RadioDevicesModulePath)
        $ErrorActionPreference = 'Stop'
        Import-Module -Name $RadioDevicesModulePath -Force -ErrorAction Stop
        Get-RadioDeviceCatalog
    }
    if (-not $hasSerialHook) { try {
        $script:deviceDiscoveryPowerShell = [System.Management.Automation.PowerShell]::Create()
        [void]$script:deviceDiscoveryPowerShell.AddScript($catalogScript.ToString()).AddArgument($script:radioDevicesModulePath)
        $script:deviceDiscoveryStartedUtc = [DateTime]::UtcNow
        $script:deviceDiscoveryAsync = $script:deviceDiscoveryPowerShell.BeginInvoke()
    } catch {
        if ($script:deviceDiscoveryPowerShell) {
            try { $script:deviceDiscoveryPowerShell.Dispose() } catch { }
            $script:deviceDiscoveryPowerShell = $null
        }
        $script:deviceDiscoveryAsync = $null
        $script:deviceSerialState = 'error'
        $script:deviceSerialError = $_.Exception.Message
        $script:deviceSerialResult = [pscustomobject]@{ status='error'; error=$script:deviceSerialError; serial_ports=@(); hri_ports=@() }
    } }
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
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SelectedValue)
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
    if (-not $script:mainWindow) { return }
    $serialControl = Get-SettingsControl 'SerialBox'
    $inputControl = Get-SettingsControl 'WaveInEndpointBox'
    $outputControl = Get-SettingsControl 'WaveOutEndpointBox'
    $savedSerial = if ($script:portableConfig) { [string]$script:portableConfig.devices.hri_port } else { 'auto' }
    $savedInput = if ($script:portableConfig) { [string]$script:portableConfig.devices.wave_in_endpoint_id } else { 'auto' }
    $savedOutput = if ($script:portableConfig) { [string]$script:portableConfig.devices.wave_out_endpoint_id } else { 'auto' }
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

    if ($script:deviceDiscoveryState -eq 'failed') { Set-UiTransientStatus -Message '串口与音频设备读取失败。' -Failed $true -Restart }
    Set-UiRadioCatDeviceControls
}

function Publish-UiDeviceDiscoveryResults {
    param([Parameter(Mandatory=$true)][object]$SerialResult,[Parameter(Mandatory=$true)][object]$AudioResult,[bool]$AcceptResult=$true)
    if (-not $AcceptResult) { return $false }
    $catalog = if ($script:deviceCatalog) { $script:deviceCatalog } else { [pscustomobject]@{ serial_ports=@(); hri_ports=@(); cat_ports=@(); wave_inputs=@(); wave_outputs=@() } }
    $serialStatus = [string]$SerialResult.status
    if (-not $serialStatus -and $SerialResult.PSObject.Properties['discovery_status']) {
        $serialStatus = if ([bool]$SerialResult.serial_ready) { 'success' } else { 'error' }
    }
    $hasSerialCatalog = $SerialResult.serial_ports -is [array] -and $SerialResult.hri_ports -is [array]
    if ($hasSerialCatalog) {
        $catalog.serial_ports = @($SerialResult.serial_ports)
        $catalog.hri_ports = @($SerialResult.hri_ports)
        $catalog.cat_ports = if ($SerialResult.PSObject.Properties['cat_ports'] -and $SerialResult.cat_ports -is [array]) { @($SerialResult.cat_ports) } else { @($catalog.serial_ports | Where-Object { -not [bool]$_.IsHri }) }
        if ($SerialResult.PSObject.Properties['source_status']) {
            if ($catalog.PSObject.Properties['source_status']) { $catalog.source_status = $SerialResult.source_status }
            else { $catalog | Add-Member -NotePropertyName source_status -NotePropertyValue $SerialResult.source_status }
        }
        if ($SerialResult.PSObject.Properties['discovery_status']) {
            if ($catalog.PSObject.Properties['discovery_status']) { $catalog.discovery_status = [string]$SerialResult.discovery_status }
            else { $catalog | Add-Member -NotePropertyName discovery_status -NotePropertyValue ([string]$SerialResult.discovery_status) }
        }
    } elseif ($serialStatus -ne 'success') {
        $catalog.serial_ports = @(); $catalog.hri_ports = @(); $catalog.cat_ports = @()
    } else { throw '串口设备结果缺少 serial_ports 或 hri_ports 数组。' }
    if ($serialStatus -ceq 'success') {
        $script:deviceSerialState = if ($SerialResult.PSObject.Properties['discovery_status'] -and [string]$SerialResult.discovery_status -ceq 'empty') { 'empty' } else { 'ready' }
        $script:deviceSerialError = [string]$SerialResult.error
    } else {
        $script:deviceSerialState = if ($serialStatus -in @('error','timeout')) { $serialStatus } else { 'error' }
        $script:deviceSerialError = [string]$SerialResult.error
    }
    $audioStatus = [string]$AudioResult.status
    if ($audioStatus -ceq 'success') {
        if ($AudioResult.wave_inputs -isnot [array] -or $AudioResult.wave_outputs -isnot [array]) { throw '音频设备结果缺少 wave_inputs 或 wave_outputs 数组。' }
        $catalog.wave_inputs = @($AudioResult.wave_inputs)
        $catalog.wave_outputs = @($AudioResult.wave_outputs)
        $script:deviceAudioState = 'ready'
        $script:deviceAudioError = ''
    } else {
        $script:deviceAudioState = if ($audioStatus -in @('error','timeout')) { $audioStatus } else { 'error' }
        $script:deviceAudioError = [string]$AudioResult.error
    }
    $script:deviceCatalog = $catalog
    $script:deviceDiscoveryState = if ($script:deviceSerialState -ceq 'ready' -or $script:deviceAudioState -ceq 'ready') { 'ready' } else { 'failed' }
    Set-SettingsDeviceControls
    $parts = @()
    if ($script:deviceSerialState -ceq 'ready') { $parts += ('串口 {0}' -f @($catalog.serial_ports).Count) } else { $parts += '串口不可用' }
    if ($script:deviceAudioState -ceq 'ready') { $parts += ('音频 {0}/{1}' -f @($catalog.wave_inputs).Count,@($catalog.wave_outputs).Count) } else { $parts += '音频不可用' }
    $discoveryFailure = @()
    if ($script:deviceSerialState -notin @('ready','empty')) { $discoveryFailure += '串口设备查询失败' }
    if ($script:deviceAudioState -notin @('ready','empty')) { $discoveryFailure += '音频设备查询失败' }
    Set-MainText -Name 'FooterText' -Text $(if ($discoveryFailure.Count -gt 0) { $discoveryFailure -join '；' } else { '' })
    (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $true
    Set-ConnectionConfigLocked
    return $true
}

function Complete-UiDeviceDiscovery {
    if ($script:uiTestDiscoveryResult) {
        $pending = $script:uiTestDiscoveryResult
        $script:uiTestDiscoveryResult = $null
        if ($pending.generation -ne $script:deviceDiscoveryGeneration -or -not [object]::ReferenceEquals($pending.owner,$script:deviceDiscoveryOwnerWindow)) { return $false }
        return (Publish-UiDeviceDiscoveryResults -SerialResult $pending.serial -AudioResult $pending.audio)
    }
    if (-not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery -and
        $null -eq $script:deviceSerialResult -and $null -eq $script:deviceAudioResult) { return }

    $generation = $script:deviceDiscoveryActiveGeneration
    $ownerWindow = $script:deviceDiscoveryOwnerWindow
    $belongsToCurrentWindow = Test-UiDiscoveryResultOwner -ResultGeneration $generation `
        -CurrentGeneration $script:deviceDiscoveryGeneration -ResultWindow $ownerWindow -CurrentWindow $script:mainWindow
    $closing = [bool]$script:closingAfterDeviceDiscovery -or $script:deviceDiscoveryStopReason -in @('shutdown','window_closed')
    if ($closing -and $script:deviceDiscoveryStopStartedUtc -eq [DateTime]::MinValue) {
        $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
        if ($script:deviceAudioQuery -and -not $script:deviceAudioStopPending) {
            $script:deviceAudioStopPending = $true
            try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery } catch { $script:deviceAudioError = $_.Exception.Message }
        }
        if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and
            -not $script:deviceDiscoveryAsync.IsCompleted -and -not $script:deviceDiscoveryStopAsync) {
            try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null,$null); $script:deviceSerialStopPending = $true }
            catch { $script:deviceSerialError = '串口设备查询未能及时停止。' }
        }
    }

    if ($script:deviceAudioQuery) {
        $query = $script:deviceAudioQuery
        if (-not $closing -and -not $script:deviceAudioStopPending -and (Test-UiAudioQueryExpired -Query $query)) {
            $script:deviceAudioStopPending = $true
            $script:deviceAudioState = 'timeout'
            $script:deviceAudioError = '音频设备查询超过 10 秒。'
            try { Request-StopUiAudioQuery -Query $query } catch { $script:deviceAudioError = $_.Exception.Message }
        }
        if ($query.Process.HasExited -and $query.StdoutTask.IsCompleted -and $query.StderrTask.IsCompleted) {
            if (-not $script:deviceAudioStopPending -and -not $closing) {
                try {
                    $read = Read-UiAudioQueryResult -Query $query
                    if ($read.Completed) {
                        $script:deviceAudioResult = [pscustomobject]@{ status='success'; wave_inputs=@($read.Audio.wave_inputs); wave_outputs=@($read.Audio.wave_outputs); error='' }
                        $script:deviceAudioState = 'ready'
                    }
                } catch {
                    $script:deviceAudioState = 'error'
                    $script:deviceAudioError = $_.Exception.Message
                    $script:deviceAudioResult = [pscustomobject]@{ status='error'; error=$script:deviceAudioError; wave_inputs=@(); wave_outputs=@() }
                }
            } elseif (-not $closing) {
                $status = if ($script:deviceAudioState -ceq 'timeout') { 'timeout' } else { 'error' }
                $script:deviceAudioResult = [pscustomobject]@{ status=$status; error=$script:deviceAudioError; wave_inputs=@(); wave_outputs=@() }
            }
            try { $query.Process.Dispose() } catch { }
            $script:deviceAudioQuery = $null
        }
    }

    $serialWorkerCompletionObserved = $false
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync) {
        $elapsed = ([DateTime]::UtcNow - $script:deviceDiscoveryStartedUtc).TotalSeconds
        if (-not $closing -and -not $script:deviceSerialStopPending -and -not $script:deviceDiscoveryAsync.IsCompleted -and $elapsed -gt 25) {
            $script:deviceSerialStopPending = $true
            $script:deviceSerialState = 'timeout'
            $script:deviceSerialError = '串口设备查询超过 25 秒。'
            try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null,$null) }
            catch { if (-not $script:deviceDiscoveryAsync.IsCompleted) { $script:deviceSerialError = '串口设备查询未能及时停止。' } }
        }
        if ($script:deviceDiscoveryStopAsync) {
            if ($script:deviceDiscoveryStopAsync.IsCompleted) {
                try { $script:deviceDiscoveryPowerShell.EndStop($script:deviceDiscoveryStopAsync) } catch { }
                $status = if ($closing) { 'error' } else { 'timeout' }
                $errorText = if ($closing) { '查询已取消。' } else { $script:deviceSerialError }
                $script:deviceSerialResult = [pscustomobject]@{ status=$status; error=$errorText; serial_ports=@(); hri_ports=@() }
                $script:deviceDiscoveryStopAsync = $null
                $serialWorkerCompletionObserved = $true
            }
        }
        if (-not $script:deviceSerialResult -and $script:deviceDiscoveryAsync.IsCompleted) {
            try {
                $records = $script:deviceDiscoveryPowerShell.EndInvoke($script:deviceDiscoveryAsync)
                if ($script:deviceDiscoveryPowerShell.HadErrors -or $records.Count -ne 1) { throw '串口设备查询没有返回有效列表。' }
                $serial = $records[0]
                if ($serial.serial_ports -isnot [array] -or $serial.hri_ports -isnot [array]) { throw '串口设备列表结构无效。' }
                $serialStatus = if ([string]$serial.discovery_status -in @('ready','empty')) { 'success' } else { 'error' }
                $script:deviceSerialResult = [pscustomobject]@{
                    status=$serialStatus; error=$(if ($serialStatus -ceq 'error') { '串口数据源均未能读取。' } else { '' })
                    discovery_status=[string]$serial.discovery_status; source_status=$serial.source_status
                    serial_ports=@($serial.serial_ports); hri_ports=@($serial.hri_ports); cat_ports=@($serial.cat_ports)
                }
                $script:deviceSerialState = if ($serialStatus -ceq 'success') { [string]$serial.discovery_status } else { 'error' }
            } catch {
                $script:deviceSerialState = 'error'
                $script:deviceSerialError = $_.Exception.Message
                $script:deviceSerialResult = [pscustomobject]@{ status='error'; error=$script:deviceSerialError; serial_ports=@(); hri_ports=@() }
            }
            $serialWorkerCompletionObserved = $true
        }
    }

    # EndInvoke/EndStop completes the pipeline, but the PowerShell object must be
    # disposed here before the completion gate checks for a null worker. Keeping
    # it alive until the later finally block would make that gate return forever.
    if ($serialWorkerCompletionObserved -and $script:deviceDiscoveryPowerShell) {
        try { $script:deviceDiscoveryPowerShell.Dispose() } catch { }
        $script:deviceDiscoveryPowerShell = $null
        $script:deviceDiscoveryAsync = $null
        $script:deviceDiscoveryStopAsync = $null
    }

    $audioDone = ($null -eq $script:deviceAudioQuery)
    $serialDone = ($null -eq $script:deviceDiscoveryPowerShell)
    if (-not $audioDone -or -not $serialDone) {
        if ($closing -and $script:deviceDiscoveryStopStartedUtc -ne [DateTime]::MinValue -and
            ([DateTime]::UtcNow - $script:deviceDiscoveryStopStartedUtc).TotalSeconds -gt 5) { [System.Environment]::Exit(2) }
        return
    }
    if (-not $script:deviceAudioResult) { $script:deviceAudioResult = [pscustomobject]@{ status='error'; error='音频查询未返回结果。'; wave_inputs=@(); wave_outputs=@() } }
    if (-not $script:deviceSerialResult) { $script:deviceSerialResult = [pscustomobject]@{ status='error'; error='串口查询未返回结果。'; serial_ports=@(); hri_ports=@() } }

    try {
        if ($belongsToCurrentWindow -and -not $closing) {
            Publish-UiDeviceDiscoveryResults -SerialResult $script:deviceSerialResult -AudioResult $script:deviceAudioResult | Out-Null
        }
    } finally {
        if ($script:deviceDiscoveryPowerShell) { try { $script:deviceDiscoveryPowerShell.Dispose() } catch { } }
        $script:deviceDiscoveryPowerShell = $null
        $script:deviceDiscoveryAsync = $null
        $script:deviceDiscoveryStopAsync = $null
        $script:deviceAudioQuery = $null
        $script:deviceDiscoveryOwnerWindow = $null
        $script:deviceDiscoveryStopReason = ''
        $script:deviceSerialStopPending = $false
        $script:deviceAudioStopPending = $false
        $script:deviceSerialResult = $null
        $script:deviceAudioResult = $null
    }
    if ($belongsToCurrentWindow) {
        Set-SettingsDeviceControls
        (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $true
    }
    if ($script:closingAfterDeviceDiscovery) {
        $script:closingAfterDeviceDiscovery = $false
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return
    }
    if ($script:deviceDiscoveryRestartPending) {
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

function Set-GainValueLabel {
    param([string]$SliderName, [string]$LabelName)
    $value = [double](Get-SettingsControl $SliderName).Value
    $milli = Convert-UiGainSliderToMilli -Value $value
    (Get-SettingsControl $LabelName).Text = ((Format-BridgeGain -GainMilli $milli) + 'x')
}

function Update-UiAudioGainValueLabels {
    if (-not $script:mainWindow) { return }
    foreach ($pair in @(@('PlaybackGainSlider','PlaybackGainValueText'),@('TransmitGainSlider','TransmitGainValueText'))) {
        $slider = $script:mainWindow.FindName($pair[0])
        $label = $script:mainWindow.FindName($pair[1])
        if ($slider -and $label) {
            $milli = Convert-UiGainSliderToMilli -Value ([double]$slider.Value)
            $label.Text = (Format-BridgeGain -GainMilli $milli) + 'x'
        }
    }
}

function Set-UiAudioGainStatus {
    param([AllowEmptyString()][string]$Text,[switch]$Failed)
    $oldStatus = [string]$script:audioGainStatusText
    $script:audioGainStatusText = $Text
    if ($Text) { Set-UiTransientStatus -Message $Text -Failed ([bool]$Failed) -Restart }
    elseif ($oldStatus -and [string]$script:transientStatusText -ceq $oldStatus) { [void](Clear-UiTransientStatus) }
}

function Test-UiAudioGainCapability {
    param([AllowEmptyString()][string]$Capabilities)
    return (Test-UiHasCapability -Capabilities $Capabilities -Command 'audio.gains.set')
}

function Set-UiAudioGainSliders {
    param([Parameter(Mandatory=$true)][object]$Gains)
    if (-not (Test-UiAudioGainsValue -Gains $Gains) -or -not $script:mainWindow) { return $false }
    $wasUpdating = [bool]$script:audioGainProgrammaticUpdate
    $script:audioGainProgrammaticUpdate = $true
    try {
        $play = $script:mainWindow.FindName('PlaybackGainSlider')
        $mic = $script:mainWindow.FindName('TransmitGainSlider')
        $play.Value = [double]([decimal]$Gains.radio_playback_gain_milli / [decimal]1000)
        $mic.Value = [double]([decimal]$Gains.mic_transmit_gain_milli / [decimal]1000)
    } finally { $script:audioGainProgrammaticUpdate = $wasUpdating }
    Update-UiAudioGainValueLabels
    return $true
}

function Update-UiAudioGainControls {
    if (-not $script:mainWindow) { return }
    $connected = ($script:supervisor -and -not $script:supervisor.HasExited)
    $blocked = [bool]($script:preparationStarted -or $script:stopTask -or $script:nativeExitCleanupPending -or
        $script:channelMutationSafetyStopPending)
    $editable = if ($connected) {
        ($script:audioGainNativeCapability -and -not $script:audioGainCommandRejected -and
            $script:controlConfirmed -and $script:audioGainRuntimeReady -and -not $blocked)
    } else { -not $blocked }
    foreach ($name in @('PlaybackGainSlider','TransmitGainSlider')) {
        $control = $script:mainWindow.FindName($name)
        if ($control) { $control.IsEnabled = [bool]$editable }
    }
    Update-UiAudioGainValueLabels
}

function Reset-UiAudioGainRun {
    param([string]$RunId='',[bool]$Capability=$false,[switch]$RestoreSavedValues)
    if ($script:audioGainDebounceTimer) { $script:audioGainDebounceTimer.Stop() }
    $script:audioGainNativeCapability = [bool]$Capability
    $script:audioGainCommandRejected = $false
    $script:audioGainRunId = $RunId
    $script:audioGainRevision = [uint64]0
    $script:audioGainActual = $null
    $script:audioGainRuntimeReady = $false
    $script:audioGainDraftRevision = [uint64]0
    $script:audioGainResolvedDraftRevision = [uint64]0
    $script:audioGainDraft = $null
    $script:audioGainPendingRequest = $null
    $script:audioGainExpiredRequests = @{}
    $script:audioGainAwaitingStatus = $false
    $script:audioGainTimedOutDraftRevision = [uint64]0
    $script:audioGainDebounceReady = $false
    if ($RestoreSavedValues -and $script:portableConfig -and $script:mainWindow) {
        $values = [pscustomobject]@{
            revision=[uint64]0
            radio_playback_gain_milli=(Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.radio_playback_gain))
            mic_transmit_gain_milli=(Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.mic_transmit_gain))
        }
        [void](Set-UiAudioGainSliders -Gains $values)
    }
    Set-UiAudioGainStatus -Text $(if ($Capability) { '正在读取当前增益' } else { '' })
    Update-UiAudioGainControls
}

function Save-UiAudioGainsFromReadback {
    param([Parameter(Mandatory=$true)][object]$Gains)
    if (-not $script:portableConfig -or -not (Test-UiAudioGainsValue -Gains $Gains)) { return $false }
    try {
        $candidate = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $script:portableConfig -Depth 24 -Compress) -ErrorAction Stop
        $candidate.audio.radio_playback_gain = [decimal]$Gains.radio_playback_gain_milli / [decimal]1000
        $candidate.audio.mic_transmit_gain = [decimal]$Gains.mic_transmit_gain_milli / [decimal]1000
        $saved = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $candidate
        $script:portableConfig = $saved
        $script:savedPlaybackGainMilli = [uint32]$Gains.radio_playback_gain_milli
        $script:savedTransmitGainMilli = [uint32]$Gains.mic_transmit_gain_milli
        return $true
    } catch {
        return $false
    }
}

function Apply-UiAudioGainReadback {
    param([Parameter(Mandatory=$true)][object]$Gains,[switch]$Persist)
    if (-not (Test-UiAudioGainsValue -Gains $Gains)) { return $false }
    if ($script:audioGainActual -and [uint64]$Gains.revision -lt [uint64]$script:audioGainActual.revision) { return $false }
    $script:audioGainActual = [pscustomobject][ordered]@{
        revision=[uint64]$Gains.revision
        radio_playback_gain_milli=[uint32]$Gains.radio_playback_gain_milli
        mic_transmit_gain_milli=[uint32]$Gains.mic_transmit_gain_milli
    }
    if ([uint64]$Gains.revision -gt $script:audioGainRevision) { $script:audioGainRevision = [uint64]$Gains.revision }
    $script:audioGainRuntimeReady = $true
    if ($Persist -and -not (Save-UiAudioGainsFromReadback -Gains $Gains)) {
        Set-UiAudioGainStatus -Text '运行增益已确认；本机配置保存失败。' -Failed
    }
    Update-UiPlaybackGainDisplay -Record $null
    Update-UiAudioGainControls
    return $true
}

function Start-UiAudioGainDebounce {
    if (-not $script:audioGainDebounceTimer) {
        $script:audioGainDebounceTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:audioGainDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:audioGainDebounceTimer.Add_Tick({
            $script:audioGainDebounceTimer.Stop()
            $script:audioGainDebounceReady = $true
            [void](Start-UiAudioGainSet)
        })
    }
    if ($script:audioGainDebounceTimer.IsEnabled) { return }
    $script:audioGainDebounceReady = $false
    $script:audioGainDebounceTimer.Start()
}

function Get-UiAudioGainDraft {
    if (-not $script:mainWindow) { return $null }
    return [pscustomobject][ordered]@{
        radio_playback_gain_milli=[uint32](Convert-UiGainSliderToMilli -Value ([double]$script:mainWindow.FindName('PlaybackGainSlider').Value))
        mic_transmit_gain_milli=[uint32](Convert-UiGainSliderToMilli -Value ([double]$script:mainWindow.FindName('TransmitGainSlider').Value))
    }
}

function Start-UiAudioGainSet {
    if (-not $script:audioGainDebounceReady -or $script:audioGainPendingRequest -or $script:audioGainAwaitingStatus -or
        -not $script:audioGainNativeCapability -or -not $script:controlConfirmed -or -not $script:audioGainRuntimeReady -or
        -not $script:supervisor -or $script:supervisor.HasExited -or $script:controlRunId -cne $script:audioGainRunId) { return $false }
    $draft = Get-UiAudioGainDraft
    if (-not $draft) { return $false }
    if ($script:audioGainActual -and [uint32]$draft.radio_playback_gain_milli -eq [uint32]$script:audioGainActual.radio_playback_gain_milli -and
        [uint32]$draft.mic_transmit_gain_milli -eq [uint32]$script:audioGainActual.mic_transmit_gain_milli) {
        $script:audioGainResolvedDraftRevision = $script:audioGainDraftRevision
        $script:audioGainDraft = $null
        $script:audioGainDebounceReady = $false
        Set-UiAudioGainStatus -Text '已应用'
        return $true
    }
    $revisionBase = [uint64]$script:audioGainRevision
    if ($script:audioGainActual -and [uint64]$script:audioGainActual.revision -gt $revisionBase) {
        $revisionBase = [uint64]$script:audioGainActual.revision
    }
    if ($revisionBase -eq [uint64]::MaxValue) { throw '运行增益 revision 已达上限；请重新连接。' }
    $revision = [uint64]($revisionBase + 1)
    $requestId = 'audio-gains-' + $revision.ToString([Globalization.CultureInfo]::InvariantCulture)
    $parameters = [ordered]@{
        revision=$revision
        radio_playback_gain_milli=[uint32]$draft.radio_playback_gain_milli
        mic_transmit_gain_milli=[uint32]$draft.mic_transmit_gain_milli
    }
    $parametersJson = ConvertTo-Json -InputObject $parameters -Depth 3 -Compress
    $pending = [pscustomobject][ordered]@{
        request_id=$requestId; run_id=$script:controlRunId; revision=$revision
        radio_playback_gain_milli=[uint32]$draft.radio_playback_gain_milli
        mic_transmit_gain_milli=[uint32]$draft.mic_transmit_gain_milli
        draft_revision=[uint64]$script:audioGainDraftRevision; started_utc=[DateTime]::UtcNow
    }
    $script:audioGainRevision = $revision
    $script:audioGainPendingRequest = $pending
    $script:audioGainDraft = $draft
    $script:audioGainDebounceReady = $false
    $script:pendingControlRequests[$requestId] = 'audio.gains.set'
    Set-UiAudioGainStatus -Text '正在应用'
    if (-not $script:supervisor.SendControlCommand($requestId,'audio.gains.set',$parametersJson)) {
        [void]$script:pendingControlRequests.Remove($requestId)
        $script:audioGainPendingRequest = $null
        $script:audioGainAwaitingStatus = $true
        $script:audioGainTimedOutDraftRevision = [uint64]$pending.draft_revision
        Set-UiAudioGainStatus -Text '增益命令未送达；正在读取当前值。' -Failed
        Request-UiControlStatus
        return $false
    }
    return $true
}

function On-UiAudioGainValueChanged {
    if ($script:audioGainProgrammaticUpdate -or $script:loadingSettings -or -not $script:mainWindow) { return }
    Update-UiAudioGainValueLabels
    $connected = ($script:supervisor -and -not $script:supervisor.HasExited)
    if (-not $connected) {
        [void](Save-UiAudioSettings)
        Update-UiAudioGainControls
        return
    }
    if (-not $script:audioGainNativeCapability -or -not $script:controlConfirmed -or -not $script:audioGainRuntimeReady) { return }
    $script:audioGainDraftRevision++
    $script:audioGainDraft = Get-UiAudioGainDraft
    Start-UiAudioGainDebounce
    Set-UiAudioGainStatus -Text '等待应用'
}

function Complete-UiAudioGainResult {
    param([Parameter(Mandatory=$true)][object]$Record)
    $pending = $script:audioGainPendingRequest
    $matchingRequest = ($pending -and [string]$pending.request_id -ceq [string]$Record.request_id -and
        [string]$pending.run_id -ceq [string]$Record.run_id -and [string]$pending.run_id -ceq $script:controlRunId)
    if ($matchingRequest -and ([DateTime]::UtcNow - [DateTime]$pending.started_utc).TotalSeconds -ge 8) {
        [void](Expire-UiAudioGainRequest)
        return $false
    }
    if (-not $matchingRequest -or [uint64]$Record.audio_gains.revision -ne [uint64]$pending.revision) {
        if ($matchingRequest) {
            $script:audioGainTimedOutDraftRevision = [uint64]$pending.draft_revision
            $script:audioGainPendingRequest = $null
            $script:audioGainAwaitingStatus = $true
        }
        Set-UiAudioGainStatus -Text '增益确认与当前请求不匹配；正在读取当前值。' -Failed
        Request-UiControlStatus
        return $false
    }
    $newerDraft = ([uint64]$script:audioGainDraftRevision -gt [uint64]$pending.draft_revision)
    $script:audioGainPendingRequest = $null
    $script:audioGainAwaitingStatus = $false
    $script:audioGainResolvedDraftRevision = [uint64]$pending.draft_revision
    $applied = Apply-UiAudioGainReadback -Gains $Record.audio_gains -Persist
    if (-not $applied) { return $false }
    if (-not $newerDraft) {
        [void](Set-UiAudioGainSliders -Gains $Record.audio_gains)
        $script:audioGainDraft = $null
    }
    if ($script:audioGainStatusText -cne '运行增益已确认；本机配置保存失败。') {
        Set-UiAudioGainStatus -Text $(if ($newerDraft) { '已确认上一组增益' } else { '已应用' })
    }
    if ($newerDraft -and $script:audioGainDebounceReady) { [void](Start-UiAudioGainSet) }
    Update-UiAudioGainControls
    return $applied
}

function Complete-UiAudioGainFailure {
    param([Parameter(Mandatory=$true)][object]$Record)
    if ($script:audioGainPendingRequest -and [string]$script:audioGainPendingRequest.request_id -ceq [string]$Record.request_id -and
        [string]$script:audioGainPendingRequest.run_id -ceq [string]$Record.run_id) {
        $script:audioGainTimedOutDraftRevision = [uint64]$script:audioGainPendingRequest.draft_revision
    }
    $script:audioGainPendingRequest = $null
    $script:audioGainAwaitingStatus = $true
    $script:audioGainDebounceReady = $false
    if ([string]$Record.result -ceq 'unsupported') { $script:audioGainCommandRejected = $true }
    Set-UiAudioGainStatus -Text '增益命令未应用；正在读取当前值。' -Failed
    Update-UiAudioGainControls
    Request-UiControlStatus
}

function Complete-UiAudioGainStatus {
    param([Parameter(Mandatory=$true)][object]$Snapshot)
    if (-not $script:audioGainNativeCapability -or -not (Test-UiAudioGainsValue -Gains $Snapshot.audio_gains)) { return $false }
    $wasAwaitingStatus = [bool]$script:audioGainAwaitingStatus
    $readback = $Snapshot.audio_gains
    if (-not (Apply-UiAudioGainReadback -Gains $readback)) { return $false }
    if ($wasAwaitingStatus) {
        $script:audioGainAwaitingStatus = $false
        if ([uint64]$script:audioGainDraftRevision -le [uint64]$script:audioGainTimedOutDraftRevision) {
            [void](Set-UiAudioGainSliders -Gains $readback)
            $script:audioGainResolvedDraftRevision = [uint64]$script:audioGainDraftRevision
            $script:audioGainDraft = $null
            $script:audioGainDebounceReady = $false
            Set-UiAudioGainStatus -Text '已读取当前增益'
        } else {
            if (-not $script:audioGainDebounceReady) { Start-UiAudioGainDebounce }
            else { [void](Start-UiAudioGainSet) }
        }
    } elseif (-not $script:audioGainPendingRequest -and
        [uint64]$script:audioGainDraftRevision -le [uint64]$script:audioGainResolvedDraftRevision) {
        [void](Set-UiAudioGainSliders -Gains $readback)
        Set-UiAudioGainStatus -Text ''
    }
    Update-UiAudioGainControls
    return $true
}

function Consume-UiAudioGainExpiredResult {
    param([Parameter(Mandatory=$true)][object]$Record)
    if ([string]$Record.command -cne 'audio.gains.set' -or
        -not $script:audioGainExpiredRequests.ContainsKey([string]$Record.request_id)) { return $false }
    [void]$script:audioGainExpiredRequests.Remove([string]$Record.request_id)
    return $true
}

function Remember-UiAudioGainExpiredRequest {
    param([Parameter(Mandatory=$true)][object]$Pending)
    $script:audioGainExpiredRequests[[string]$Pending.request_id] = $Pending
    if ($script:audioGainExpiredRequests.Count -gt 32) {
        $oldest = @($script:audioGainExpiredRequests.GetEnumerator() | Sort-Object { [DateTime]$_.Value.started_utc } | Select-Object -First 1)
        if ($oldest.Count -gt 0) { [void]$script:audioGainExpiredRequests.Remove([string]$oldest[0].Key) }
    }
}

function Expire-UiAudioGainRequest {
    if (-not $script:audioGainPendingRequest -or
        ([DateTime]::UtcNow - [DateTime]$script:audioGainPendingRequest.started_utc).TotalSeconds -lt 8) { return $false }
    $pending = $script:audioGainPendingRequest
    [void]$script:pendingControlRequests.Remove([string]$pending.request_id)
    Remember-UiAudioGainExpiredRequest -Pending $pending
    $script:audioGainPendingRequest = $null
    $script:audioGainAwaitingStatus = $true
    $script:audioGainTimedOutDraftRevision = [uint64]$pending.draft_revision
    Set-UiAudioGainStatus -Text '增益确认超时；正在读取当前值。' -Failed
    Request-UiControlStatus
    return $true
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

function Save-UiRoutingMutationAfterAck {
    param([object]$Mutation, [object]$Routing)
    if ($script:pendingChannelMutation) {
        [void](Complete-UiChannelMutation -Mutation $Mutation -Routing $Routing)
        return
    }
    if (-not $Mutation) { return }
    $script:routingDraftAfterTimeout = $null
    $script:routingDraftPreservedAfterTimeout = $false
    if ($script:activeProfile) {
        if ($Mutation.command -ceq 'rx_policy.replace') { $script:activeProfile.rx_policy = Copy-UiRxPolicy -Policy $Routing.rx_policy }
        else { $script:activeProfile.tx_target = $Routing.tx_target; $script:activeProfile.transmit_enabled = $true }
    }
    Set-UiChannelStatus -Text '核心已确认频道状态。'
    Update-UiChannelDisplays
}

function Invoke-UiRoutingDiagnosticChannelQuickCallButton {
    param([Parameter(Mandatory=$true)][object]$Channel)
    $key=Get-UiChannelKey -Channel $Channel
    $panel=$script:mainWindow.FindName('ChannelCardsPanel')
    foreach($card in @($panel.Children)){
        if($card -isnot [System.Windows.Controls.Border] -or $card.Child -isnot [System.Windows.Controls.Grid]){continue}
        $actionGrids=@($card.Child.Children | Where-Object {
            $_ -is [System.Windows.Controls.Primitives.UniformGrid]
        })
        foreach($actions in $actionGrids){
            foreach($candidate in @($actions.Children)){
                if($candidate -isnot [System.Windows.Controls.Button] -or -not $candidate.Tag -or
                    [string]$candidate.Tag.action -cne 'quick_call' -or -not $candidate.Tag.channel){continue}
                if((Get-UiChannelKey -Channel $candidate.Tag.channel) -cne $key){continue}
                if(-not $candidate.IsEnabled){throw '频道激活组按钮未启用。'}
                $eventArgs=[System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
                $candidate.RaiseEvent($eventArgs)
                return
            }
        }
    }
    throw '没有找到本机诊断频道的激活组按钮。'
}

function Start-UiRoutingDiagnosticAutoTest {
    if($script:routingDiagnosticAutoTestStarted -or -not $RoutingDiagnosticAutoTest -or -not $script:activeRouting){return}
    $script:routingDiagnosticAutoTestStarted=$true
    try{
        if(-not $script:storedProfile -or [uint64]$script:storedProfile.connection.source_id -ne 1){throw 'source'}
        if(Get-UiChannelByKey -Key 'group:12345:1'){throw 'duplicate'}
        $script:routingDiagnosticAutoTestPhase=1
        $script:channelEditorSlot=1
        (Get-UiControl 'ChannelIdBox').Text='12345'
        $kindBox=Get-UiControl 'ChannelKindBox'
        $kindBox.SelectedItem=@($kindBox.Items|Where-Object {[string]$_.Tag -ceq 'group'})[0]
        $script:routingDiagnosticOriginalTxKey=[string]$script:txChannelKey
        if(-not $script:routingDiagnosticOriginalTxKey -and $script:storedProfile -and $script:storedProfile.PSObject.Properties['tx_channel_id']){
            $script:routingDiagnosticOriginalTxKey=[string]$script:storedProfile.tx_channel_id
        }
        if([string]::IsNullOrWhiteSpace($script:routingDiagnosticOriginalTxKey) -or
            -not (Get-UiChannelByKey -Key $script:routingDiagnosticOriginalTxKey)) { throw 'original-tx' }
        $button=Get-UiControl 'AddChannelButton'
        $eventArgs=[System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
        $button.RaiseEvent($eventArgs)
        $pendingStage=if($script:pendingChannelMutation){[string]$script:pendingChannelMutation.stage}else{''}
        $pendingCommand=if($script:pendingRoutingMutation){[string]$script:pendingRoutingMutation.command}else{''}
        $pendingTxTargetKey=''
        if($script:pendingRoutingMutation -and $script:pendingRoutingMutation.target){
            $target=$script:pendingRoutingMutation.target
            $pendingTxTargetKey=Get-UiChannelKey -Channel ([pscustomobject]@{
                id=[uint64]$target.destination_id;kind=[string]$target.kind;slot=[int]$target.slot
            })
        }
        $validRxStart=($pendingStage -ceq 'rx' -and $pendingCommand -ceq 'rx_policy.replace')
        $validTxStart=($pendingStage -ceq 'tx' -and $pendingCommand -ceq 'tx_policy.replace' -and
            $pendingTxTargetKey -ceq $script:routingDiagnosticOriginalTxKey)
        if(-not $script:pendingChannelMutation -or -not $script:pendingRoutingMutation -or
            (-not $validRxStart -and -not $validTxStart) -or
            [string]$script:pendingChannelMutation.tx_key -cne $script:routingDiagnosticOriginalTxKey){
            throw 'add-channel'
        }
        Write-UiRoutingDiagnosticProgress -Message $(if($validTxStart){'channel-add-clicked-tx-sync-sent'}else{'channel-add-clicked-listen-update-sent'})
    }catch{
        Write-UiRoutingDiagnosticProgress -Message 'channel-add-initialization-failed'
        Fail-UiRoutingDiagnosticAutoTest -Message '隔离频道诊断无法通过主窗口频道添加流程启动。'
    }
}

function Complete-UiRoutingDiagnosticAutoTest {
    param([AllowNull()][object]$Mutation,[Parameter(Mandatory=$true)][object]$Routing)
    try{
        $actualTxKey=''
        if ($Routing.tx_target) { $actualTxKey = Get-UiChannelKey -Channel ([pscustomobject]@{
                id=[uint64]$Routing.tx_target.destination_id; kind=[string]$Routing.tx_target.kind; slot=[int]$Routing.tx_target.slot
            }) }
        if($script:routingDiagnosticAutoTestPhase -eq 1 -and $Mutation -and
            [string]$Mutation.command -ceq 'tx_policy.replace'){
            $mutationTxKey=''
            if($Mutation.target){$mutationTxKey=Get-UiChannelKey -Channel ([pscustomobject]@{
                id=[uint64]$Mutation.target.destination_id;kind=[string]$Mutation.target.kind;slot=[int]$Mutation.target.slot
            })}
            if($mutationTxKey -cne $script:routingDiagnosticOriginalTxKey -or
                $actualTxKey -cne $script:routingDiagnosticOriginalTxKey -or
                -not $script:pendingChannelMutation -or [string]$script:pendingChannelMutation.stage -cne 'rx' -or
                -not [bool]$script:pendingChannelMutation.tx_applied -or
                -not $script:pendingRoutingMutation -or [string]$script:pendingRoutingMutation.command -cne 'rx_policy.replace'){
                throw 'tx-ack'
            }
            $script:routingDiagnosticChannelFlowTest.tx_command='tx_policy.replace'
            $script:routingDiagnosticAutoTestPhase=2
            Write-UiRoutingDiagnosticProgress -Message 'original-tx-target-confirmed-listen-update-sent'
            return
        }
        if($script:routingDiagnosticAutoTestPhase -in @(1,2)){
            $expectedGroup=@($Routing.rx_policy.allow_groups|Where-Object {[uint64]$_.destination_id -eq 12345 -and [uint64]$_.slot -eq 1}).Count -eq 1
            if(-not $Mutation -or [string]$Mutation.command -cne 'rx_policy.replace' -or -not $expectedGroup -or
                $actualTxKey -cne $script:routingDiagnosticOriginalTxKey){throw 'rx-ack'}
            $saved=Get-WirexPortableConfig -Path $script:portableConfigPath
            if([string]$saved.tx_channel_id -cne $script:routingDiagnosticOriginalTxKey -or
                @($saved.channels|Where-Object {[string]$_.kind -ceq 'group' -and [uint64]$_.id -eq 12345 -and [uint64]$_.slot -eq 1}).Count -ne 1){throw 'root-config'}
            if($script:routingDiagnosticAutoTestPhase -eq 1){$script:routingDiagnosticChannelFlowTest.tx_command='unchanged'}
            $script:routingDiagnosticChannelFlowTest.rx_command=[string]$Mutation.command
            $script:routingDiagnosticChannelFlowTest.ptt_unchanged_after_add=$true
            $script:routingDiagnosticChannelFlowTest.root_config_saved=$true
            $script:routingDiagnosticRoutingBeforeQuickCall=ConvertTo-Json -InputObject $Routing -Compress -Depth 16
            $script:routingDiagnosticAutoTestPhase=3
            $channel=Get-UiChannelByKey -Key 'group:12345:1'
            if(-not $channel){throw 'channel-not-visible'}
            Update-UiChannelDisplays
            Invoke-UiRoutingDiagnosticChannelQuickCallButton -Channel $channel
            Write-UiRoutingDiagnosticProgress -Message 'channel-quick-call-button-clicked'
            return
        }
        if($script:routingDiagnosticAutoTestPhase -eq 4){
            if(-not $script:routingDiagnosticQuickCallResponse -or
                [string]$script:routingDiagnosticQuickCallResponse.command -cne 'network_subscription.quick_call_join' -or
                [uint64]$script:routingDiagnosticQuickCallResponse.destination_id -ne 12345 -or
                [uint64]$script:routingDiagnosticQuickCallResponse.slot -ne 1 -or
                [uint64]$script:routingDiagnosticQuickCallResponse.frames_sent -ne 2 -or
                [string]$script:routingDiagnosticQuickCallResponse.activation_status -cne 'request_sent' -or
                [bool]$script:routingDiagnosticQuickCallResponse.replayed){throw 'quick-call-ack'}
            $before=$script:routingDiagnosticRoutingBeforeQuickCall
            $after=ConvertTo-Json -InputObject $Routing -Compress -Depth 16
            if([string]::IsNullOrWhiteSpace($before) -or $before -cne $after){throw 'routing-changed'}
            $saved=Get-WirexPortableConfig -Path $script:portableConfigPath
            if([string]$saved.tx_channel_id -cne $script:routingDiagnosticOriginalTxKey -or
                @($saved.channels|Where-Object {[string]$_.kind -ceq 'group' -and [uint64]$_.id -eq 12345 -and [uint64]$_.slot -eq 1}).Count -ne 1){throw 'root-config-readback'}
            $script:routingDiagnosticChannelFlowTest.passed=$true
            $script:routingDiagnosticChannelFlowTest.quick_call_command='network_subscription.quick_call_join'
            $script:routingDiagnosticChannelFlowTest.frames_sent=[uint64]$script:routingDiagnosticQuickCallResponse.frames_sent
            $script:routingDiagnosticChannelFlowTest.bm_connected=$false
            $script:routingDiagnosticChannelFlowTest.used_memory_sink=$true
            $script:routingDiagnosticChannelFlowTest.routing_unchanged_after_activation=$true
            $script:routingDiagnosticChannelFlowTest.normal_shutdown_requested=$true
            Write-UiRoutingDiagnosticProgress -Message 'channel-flow-test-passed'
            Write-UiRoutingDiagnosticResult -Passed $true -Message '本地Native IPC确认添加监听频道后原PTT目标保持不变，并验证组呼激活仅通过内存接收器。' -Routing $Routing
            Request-StopAndExit
            return
        }
        throw 'unexpected-phase'
    }catch{
        Fail-UiRoutingDiagnosticAutoTest -Message '隔离频道诊断未能完成Native状态确认。'
    }
}

function Fail-UiRoutingDiagnosticAutoTest {
    param([Parameter(Mandatory=$true)][string]$Message)
    $script:routingDiagnosticAutoTestPhase=-1
    $script:routingDiagnosticChannelFlowTest=[pscustomobject][ordered]@{
        passed=$false;message=$Message;phase=$script:routingDiagnosticAutoTestPhase;ptt_unchanged_after_add=$false
        channel_key='group:12345:1';bm_connected=$false;used_memory_sink=$true
    }
    Write-UiRoutingDiagnosticProgress -Message 'channel-flow-test-failed'
    Write-UiRoutingDiagnosticResult -Passed $false -Message $Message -Routing $script:activeRouting
    Set-UiControlStatus -Text $Message -Confirmed $false
    Request-StopAndExit
}

function Write-UiRoutingDiagnosticResult {
    param([bool]$Passed,[string]$Message,[object]$Routing)
    if(-not $script:configDirectory){return}
    $result=[pscustomobject][ordered]@{
        schema_version=2;passed=$Passed;message=$Message
        channel_flow_test=$script:routingDiagnosticChannelFlowTest
        rx_policy=if($Routing){$Routing.rx_policy}else{$null}
        tx_target=if($Routing){$Routing.tx_target}else{$null}
        transmit_enabled=if($Routing){[bool]$Routing.transmit_enabled}else{$false}
        rx_policy_revision=if($Routing){[uint64]$Routing.rx_policy_revision}else{[uint64]0}
        tx_policy_revision=if($Routing){[uint64]$Routing.tx_policy_revision}else{[uint64]0}
    }
    $path=Join-Path $script:configDirectory 'routing-diagnostic-result.json'
    [System.IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $result -Depth 10),(New-Object System.Text.UTF8Encoding($false)))
}

function Write-UiRoutingDiagnosticProgress {
    param([string]$Message)
    if (-not $RoutingDiagnosticAutoTest -or -not $script:configDirectory) { return }
    $path = Join-Path $script:configDirectory 'routing-diagnostic-progress.txt'
    [System.IO.File]::AppendAllText($path,([DateTime]::UtcNow.ToString('o') + ' ' + $Message + "`n"),(New-Object System.Text.UTF8Encoding($false)))
}

function Start-BridgeRun {
    param([switch]$BmStartDisconnected)
    $script:bmStartDisconnectedForRun = [bool]$BmStartDisconnected
    if (Test-UiRadioCatUserActionBusy) {
        Set-MainText -Name 'FooterText' -Text 'CAT 设置未完成，请稍后再启动 Wires-X。'
        Set-ConnectionButtonState
        return
    }
    if ($script:preparationStarted -or $script:nativeExitCleanupPending -or ($script:supervisor -and -not $script:supervisor.HasExited)) { return }
    Set-OfflineDisplay -Reason '正在检查本次连接配置和设备。'
    Reset-UiControlState
    $script:lastUiBmState = ''
    $script:lastUiHriState = ''
    try {
        if ($script:sessionTempDirectory -and -not (Clear-UiSessionTemp)) {
            throw '上一次连接的临时材料尚未清理，不能覆盖后重新连接。'
        }
        if ($script:supervisor) { $script:supervisor.Dispose(); $script:supervisor = $null }
        if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
        $script:statusPath = ''
        $script:latestStatus = $null
        $script:lastStatusUtc = [DateTime]::MinValue
        if (-not $script:portableConfig) { [void](Import-UiPortableConfig) }
        if ($null -eq $script:storedProfile) { $script:startupNeedsSettings = $true; Set-MainText -Name 'FooterText' -Text '请填写有效的连接信息，并至少加入一个频道。'; return }
        $target = 'channel-list'
        if ($RoutingDiagnostic) {
            $script:effectiveProfile = $script:storedProfile
        } else {
            $script:effectiveProfile = $script:storedProfile
        }
        if (-not $RoutingDiagnostic -and $script:effectiveProfile -and $script:effectiveProfile.devices) {
            $savedHriPort = [string]$script:effectiveProfile.devices.serial_port
            $portConflictMessage = Get-UiRadioCatPortConflictMessage -HriPortName $savedHriPort
            if ($portConflictMessage) {
                Set-OfflineDisplay -Reason $portConflictMessage
                Set-MainText -Name 'FooterText' -Text $portConflictMessage
                Set-ConnectionButtonState
                return
            }
        }
        $script:targetLabel = Format-ProfileTarget -Profile $script:effectiveProfile
        $script:preparedTargetTag = $target
        $script:preparedTargetLabel = $script:targetLabel
        if (-not $script:supervisor -or $script:supervisor.HasExited) {
            Set-MainTargetSummary -Profile $script:effectiveProfile -OverallLabel $script:targetLabel
        }
        if ($UiTestFixture) {
            if (-not $script:uiTestHooks.ContainsKey('NativeSupervisorFactory') -or
                $script:uiTestHooks.NativeSupervisorFactory -isnot [scriptblock]) {
                throw 'UiTestFixture 禁止启动真实核心；测试需注入 NativeSupervisorFactory。'
            }
            $factoryContext = [pscustomobject]@{
                profile=$script:effectiveProfile; target=$script:targetLabel; operation='connect'
                bm_start_disconnected=[bool]$script:bmStartDisconnectedForRun
            }
            $fakeSupervisor = & $script:uiTestHooks.NativeSupervisorFactory $factoryContext
            if ($null -eq $fakeSupervisor -or -not $fakeSupervisor.PSObject.Properties['HasExited']) {
                throw 'NativeSupervisorFactory 必须返回包含 HasExited 属性的对象。'
            }
            $script:supervisor = $fakeSupervisor
            $script:activeProfile = $script:effectiveProfile
            $script:activeTargetLabel = $script:targetLabel
            $script:activeTargetTag = $target
            $script:activeHriPortName = [string]$script:effectiveProfile.devices.serial_port
            Set-MainText -Name 'CoreValue' -Text '测试连接'
            Set-MainText -Name 'CoreDetail' -Text '隔离 WPF 测试会话'
            Set-MainText -Name 'FooterText' -Text ''
            Set-ConnectionButtonState
            if ($script:uiTestHooks.CatOperation -is [scriptblock]) { [void](Start-UiRadioCatPolling) }
            return
        }
        if ($RoutingDiagnostic) {
            if ([uint64]$script:storedProfile.connection.source_id -ne 1) { throw '本地路由诊断只接受隔离测试配置 Source ID 1。' }
            $script:supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
            Write-UiRoutingDiagnosticProgress -Message 'native-start-requested'
            $script:supervisor.Start($script:nativeExecutable,[string[]]@('--routing-diagnostic','--ui-pipe','--ui-control-version','2'),$script:releaseDirectory,2)
            $script:activeProfile = $script:effectiveProfile
            $script:activeTargetLabel = '本机路由诊断（未连接电台或 BM）'
            $script:activeTargetTag = 'routing-diagnostic'
            Set-UiTransientStatus -Message '路由诊断：未连接电台、BM、音频或 RF；以下状态只来自本机核心。' -Restart
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
        if (-not $script:bmStartDisconnectedForRun -and
            [string]::IsNullOrWhiteSpace([string]$script:portableConfig.connection.password)) {
            $script:startupNeedsSettings = $true
            Set-MainText -Name 'FooterText' -Text '请在 BM 密码框中输入密码后保存。'
            return
        }
        $script:savedPlaybackGainMilli = Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.radio_playback_gain)
        Update-UiPlaybackGainDisplay -Record $null
        $retention = Invoke-UiRunLogRetention -RunRoot (Join-Path $script:configDirectory 'ui-runs') `
            -ConfigRoot $script:configDirectory
        if ($retention.removed -gt 0) { Add-UiEvent ('已清理 {0} 个已结束运行目录' -f $retention.removed) }
        if ($retention.cleanup_errors -gt 0) { Add-UiEvent '有已结束运行记录未能清理' }
        $script:preparedRunDirectory = Join-Path (Join-Path $script:configDirectory 'ui-runs') ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($script:preparedRunDirectory) | Out-Null
        $tempRoot=[System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $script:sessionTempDirectory=Join-Path $tempRoot ('wirex-bridge-session-' + [guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($script:sessionTempDirectory) | Out-Null
        $temporaryProfilePath = Join-Path $script:sessionTempDirectory 'connection-profile.json'
        $temporaryAudioPath = Join-Path $script:sessionTempDirectory 'audio-settings.json'
        $script:sessionPasswordPath = ''
        Write-BridgeUserConnectionProfile -Path $temporaryProfilePath -Profile $script:effectiveProfile
        Write-BridgeAudioSettings -Path $temporaryAudioPath `
            -RadioPlaybackGainMilli (Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.radio_playback_gain)) `
            -MicTransmitGainMilli (Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.mic_transmit_gain))
        $passwordValue = [string]$script:portableConfig.connection.password
        $script:sessionPasswordPath = Write-UiSessionPasswordFile -Directory $script:sessionTempDirectory -Password $passwordValue
        $preparationPath = Join-Path $script:preparedRunDirectory 'preparation.json'
        $script:statusPath = ''
        $arguments = @{
            Preset = 'manual'
            ConnectionProfilePath = $temporaryProfilePath
            AudioSettingsPath = $temporaryAudioPath
            StatusDirectory = $script:preparedRunDirectory
            PreparationOutputPath = $preparationPath
            PrepareOnly = $true
            NoInteractive = $true
        }
        if ($script:sessionPasswordPath) {
            $arguments.PasswordFile = $script:sessionPasswordPath
            $arguments.RequirePasswordFile = $true
        }
        if ($script:bmStartDisconnectedForRun) { $arguments.BmStartDisconnected = $true }
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
        Set-ConnectionButtonState
    } catch {
        $script:preparationStarted = $false
        Clear-UiSessionTemp
        Set-OfflineDisplay -Reason ('连接准备失败：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置并检查连接参数、密码文件和设备选择。'
        Set-ConnectionButtonState
        Add-UiEvent '连接准备失败'
    }
}

function Write-UiSessionPasswordFile {
    param([Parameter(Mandatory=$true)][string]$Directory,[AllowEmptyString()][string]$Password)
    if ([string]::IsNullOrWhiteSpace($Password)) { return '' }
    $directoryPath = [System.IO.Path]::GetFullPath($Directory)
    if (-not [System.IO.Directory]::Exists($directoryPath)) { throw '本次连接的临时目录不存在。' }
    $path = Join-Path $directoryPath 'bm-device-password.txt'
    [System.IO.File]::WriteAllText($path,$Password + "`n",(New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Complete-BridgePreparation {
    if ($script:closingAfterStop -or $script:reconnectAfterStop) { return }
    if (-not $script:preparePowerShell -or -not $script:prepareAsync -or -not $script:prepareAsync.IsCompleted) { return }
    if (Test-UiRadioCatUserActionBusy) {
        $script:reconnectAfterStop = $false
        Set-MainText -Name 'FooterText' -Text 'CAT 设置未完成，本次 Wires-X 启动已取消。'
        try { Begin-PreparationStop } catch { Set-MainText -Name 'FooterText' -Text 'CAT 设置未完成，设备准备未能取消。' }
        return
    }
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
            -ExpectedExecutable $script:nativeExecutable `
            -BmStartDisconnected:$script:bmStartDisconnectedForRun
        $radioPortArgumentIndex = [Array]::IndexOf([string[]]$validatedPreparation.Arguments,'--port')
        $preparedRadioPort = ''
        if ($radioPortArgumentIndex -ge 0 -and $radioPortArgumentIndex + 1 -lt $validatedPreparation.Arguments.Count) {
            $preparedRadioPort = [string]$validatedPreparation.Arguments[$radioPortArgumentIndex + 1]
        }
        $portConflictMessage = Get-UiRadioCatPortConflictMessage -HriPortName $preparedRadioPort
        if ($portConflictMessage) {
            $script:activeHriPortName = ''
            Clear-UiSessionTemp
            Set-OfflineDisplay -Reason $portConflictMessage
            Set-MainText -Name 'FooterText' -Text $portConflictMessage
            Set-ConnectionButtonState
            Add-UiEvent 'Wires-X 启动因 CAT/HRI 串口冲突取消'
            return
        }
        $script:statusPath = $validatedPreparation.StatusPath
        $script:supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
        $nativeArguments = [System.Collections.Generic.List[string]]::new()
        foreach ($argument in [string[]]$validatedPreparation.Arguments) { $nativeArguments.Add([string]$argument) }
        $script:supervisor.Start($validatedPreparation.Executable, [string[]]$nativeArguments.ToArray(), $script:releaseDirectory, 2)
        $script:activeHriPortName = if ($preparedRadioPort -match '^COM[1-9][0-9]{0,2}$') { $preparedRadioPort.ToUpperInvariant() } else { '' }
        if (-not $script:isolatedUiMode) {
            if ($script:serialConnectCatAfterCoreReady) {
                [void](Connect-UiRadioCatSession)
                $script:serialConnectCatAfterCoreReady = $false
            } elseif (-not $NoAutoConnect) {
                [void](Connect-UiRadioCatSession -Automatic)
            }
        }
        $script:activeBmTransportConfig = Get-UiBmTransportConfigValue -Config $script:portableConfig
        $script:bmStartDisconnectedForRun = $false
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
        $script:activeHriPortName = ''
        Clear-UiSessionTemp
        Set-OfflineDisplay -Reason ('连接准备失败：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置检查配置，再重新启动。'
        Set-ConnectionButtonState
        Add-UiEvent '连接准备失败'
    } finally {
        $script:preparationStarted = $false
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        Set-ConnectionButtonState
    }
}

function Update-UiReceiveMetricsDisplay {
    param([object]$Record=$null)
    if (-not $script:mainWindow) { return }
    $rttPanel = $script:mainWindow.FindName('BmRttMetric')
    $rttValue = $script:mainWindow.FindName('BmRttValue')
    $bmLossPanel = $script:mainWindow.FindName('BmLossMetric')
    $bmLossValue = $script:mainWindow.FindName('BmLossValue')
    $lossPanel = $script:mainWindow.FindName('RxNetworkMetric')
    $callLossValue = $script:mainWindow.FindName('RxCallLossValue')
    $sessionLossValue = $script:mainWindow.FindName('RxSessionLossValue')
    foreach ($control in @($rttPanel,$lossPanel)) {
        if ($control) { $control.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    foreach ($control in @($rttValue,$callLossValue,$sessionLossValue)) {
        if ($control) { $control.Text = ''; $control.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    $script:bmLossValid = $false
    if ($bmLossValue) { $bmLossValue.Text = ''; $bmLossValue.Visibility = [System.Windows.Visibility]::Collapsed }
    if ($bmLossPanel) { $bmLossPanel.Visibility = [System.Windows.Visibility]::Collapsed }
    if (-not $Record) { return }

    $bmReady = ([string]$Record.bm_state -ceq 'ready')
    $rttValidProperty = $Record.PSObject.Properties['bm_rtt_valid']
    $rttLastProperty = $Record.PSObject.Properties['bm_rtt_last_ms']
    $rttCountProperty = $Record.PSObject.Properties['bm_rtt_sample_count']
    if ($bmReady -and $rttValidProperty -and [bool]$rttValidProperty.Value -and $rttLastProperty -and $rttCountProperty -and
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
    if ($bmReady -and $expectedProperty -and $receivedProperty -and $lossProperty -and $null -ne $expectedProperty.Value -and
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
            if ($lossTarget) { $lossTarget.Text = $value; $lossTarget.Visibility = [System.Windows.Visibility]::Visible }
            if ($lossPanel) { $lossPanel.Visibility = [System.Windows.Visibility]::Visible }
            if ($bmLossValue) { $bmLossValue.Text = $value; $bmLossValue.Visibility = [System.Windows.Visibility]::Visible }
            if ($bmLossPanel) { $bmLossPanel.Visibility = [System.Windows.Visibility]::Visible }
            $script:bmLossValid = $true
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
    $previousBmState = [string]$script:lastUiBmState
    if ($previousBmState -ceq 'ready' -and $bm -cne 'ready') {
        [void](Reset-UiChannelActivationForBmReconnect -RunId ([string]$Record.run_id))
    }
    [void](Clear-UiChannelActivationAfterGroupPtt -RunId ([string]$Record.run_id) -EventName ([string]$Record.event))
    if ($Record.PSObject.Properties['bm_connection']) {
        [void](Set-UiBmConnectionSnapshot -Connection $Record.bm_connection -BmState $bm `
            -Resolving ([bool]$Record.bm_resolving) -ErrorCode ([string]$Record.bm_connection_error) -Source status_jsonl)
        $script:lastUiBmState = $bm
    } else {
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
        } elseif ($bm -ceq 'ready') { $bmDetail = '已收到 BM 登录确认。' }
        else { $bmDetail = '等待 BM 登录确认。' }
        Set-MainText -Name 'BmDetail' -Text $bmDetail
    }

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
    Update-UiChannelDisplays
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
        Set-MainText -Name 'RecentCallDetail' -Text ('最近来话 · 目标 {0} · {1}' -f `
            $Record.last_rx_destination_id, $Record.last_rx_call_kind)
    } else {
        Set-UiIdentityRowVisibility -Row 'recent' -Visibility ([System.Windows.Visibility]::Collapsed)
    }
    Set-MainText -Name 'TrafficValue' -Text $script:activeTargetLabel
    Set-MainText -Name 'TrafficDetail' -Text '当前连接使用运行会话中显示的目标。'
    Set-MainText -Name 'RunValue' -Text '运行中'
    Set-MainText -Name 'FreshnessValue' -Text ('状态更新于 {0}' -f [DateTime]::Now.ToString('HH:mm:ss'))
    $visibleEvent = Get-VisibleUiEventText -EventName ([string]$Record.event)
    if ($visibleEvent) { Add-UiEvent $visibleEvent }
    if ($script:queuedQuickCall) { [void](Process-UiQueuedQuickCall) }
    Update-DynamicGroupControls
    if ($script:settingsWindow) {
        if ($script:radioCatOperationKind -ceq 'setPower' -and -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
            try { Request-StopUiRadioCatOperation -Reason 'core_no_longer_idle' | Out-Null } catch { }
            Set-UiTransientStatus -Message '核心状态不再空闲，已请求取消电台功率设置；读回确认前结果未知。' -Failed $true -Restart
        }
        Update-UiRadioCatControls
    }
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
    if ($script:radioCatOperationKind -ceq 'setPower' -and -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
        if (-not $script:radioCatOperationCancelled) {
            try { Request-StopUiRadioCatOperation -Reason 'core_status_stale' | Out-Null }
            catch { Add-UiEvent '核心状态过期，取消 CAT 功率操作失败' }
            Set-UiTransientStatus -Message '核心空闲状态已过期，已请求取消电台功率设置；读回确认前结果未知。' -Failed $true -Restart
        }
    }
    $script:latestStatus = $null
    $script:lastStatusUtc = [DateTime]::MinValue
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
    Update-UiChannelDisplays
    Update-UiIdentityActionState
    Update-UiRadioCatControls
}

function Request-StopAndExit {
    Clear-UiIdentityQueryQueue
    if ($script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode stop_requested `
            -Message '正在停止连接；排队取消，没有发送激活请求。')
    }
    $script:closingAfterStop = $true
    $script:reconnectAfterStop = $false
    $script:radioModeApplyAfterStop = $null
    $script:radioModePreviousHriPortName = ''
    if (Get-Command -Name Stop-UiRadioCatSession -ErrorAction SilentlyContinue) {
        [void](Stop-UiRadioCatSession -Reason app_shutdown)
    }
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
    if ($script:radioCatOperationPowerShell) {
        $script:radioCatCloseMainAfterOperation = $true
        return
    }
    $script:allowWindowClose = $true
    Clear-UiSessionTemp
    $script:mainWindow.Close()
}

function Request-Reconnect {
    if ($script:channelMutationSafetyStopPending -or $script:closingAfterStop -or $script:stopTask -or $script:prepareStopAsync) { return }
    if (Test-UiRadioCatUserActionBusy) {
        Set-MainText -Name 'FooterText' -Text 'CAT 设置未完成，请稍后再启动 Wires-X。'
        Set-ConnectionButtonState
        return
    }
    if ($script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode reconnect_requested `
            -Message '正在切换运行会话；排队取消，没有发送激活请求。')
    }
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
    Clear-UiSessionTemp
    if ($script:closingAfterStop) {
        if ($script:radioCatOperationPowerShell) {
            $script:radioCatCloseMainAfterOperation = $true
            return
        }
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
    } elseif ($script:reconnectAfterStop) {
        $script:reconnectAfterStop = $false
        $startDisconnected = [bool]$script:reconnectAfterStopBmStartDisconnected
        $script:reconnectAfterStopBmStartDisconnected = $false
        if ($startDisconnected) { Start-BridgeRun -BmStartDisconnected } else { Start-BridgeRun }
    } elseif ($script:serialDisconnectPending) {
        $script:serialDisconnectPending = $false
        $script:serialDisconnectCoreStopIssued = $false
        $script:serialDisconnectCatStopRequested = $false
        $script:activeBmTransportConfig = $null
        Set-OfflineDisplay -Reason '核心准备已取消；串口保持断开。'
        Set-ConnectionButtonState
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
    Clear-UiSessionTemp
    if ($wasClosing) {
        if ($script:radioCatOperationPowerShell) {
            $script:radioCatCloseMainAfterOperation = $true
            return
        }
        $script:allowWindowClose = $true
        Clear-UiSessionTemp
        $script:mainWindow.Close()
        return
    }
    if ($wasReconnect) {
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        $startDisconnected = [bool]$script:reconnectAfterStopBmStartDisconnected
        $script:reconnectAfterStopBmStartDisconnected = $false
        if ($startDisconnected) { Start-BridgeRun -BmStartDisconnected } else { Start-BridgeRun }
        return
    }
    if ($script:serialDisconnectPending) {
        $script:serialDisconnectPending = $false
        $script:serialDisconnectCoreStopIssued = $false
        $script:serialDisconnectCatStopRequested = $false
        $script:activeBmTransportConfig = $null
        $script:activeProfile = $null
        $script:activeHriPortName = ''
        $script:lastUiBmState = ''
        $script:lastUiHriState = ''
        Set-OfflineDisplay -Reason 'Wires-X/HRI 与 CAT 串口均已断开。'
        Set-ConnectionButtonState
        Update-UiRadioCatControls
        return
    }
}

function Complete-BridgeStopInternal {
    if (-not $script:stopTask -or -not $script:stopTask.IsCompleted) { return $false }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        Set-MainText -Name 'CoreValue' -Text '停止未完成'
        Set-MainText -Name 'CoreDetail' -Text '核心仍在运行；请再次选择停止并退出。'
        Set-MainText -Name 'FooterText' -Text '桥接核心尚未退出。'
        $script:stopTask = $null
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        if ($script:serialDisconnectPending) {
            $script:serialDisconnectPending = $false
            $script:serialDisconnectCoreStopIssued = $false
            $script:serialDisconnectCatStopRequested = $false
            Set-MainText -Name 'FooterText' -Text 'HRI 核心没有退出；CAT 已断开，串口核心仍保持运行。'
        }
        $script:radioModeApplyAfterStop = $null
        $script:radioModePreviousHriPortName = ''
        (Get-UiControl 'StopButton').IsEnabled = $true
        Set-ConnectionButtonState
        if ($script:settingsWindow) {
            Set-UiTransientStatus -Message 'HRI 核心没有退出；取消本次 MAIN 调制/频率设置。' -Failed $true -Restart
            Update-UiRadioCatControls
        }
        return $true
    }
    if ($script:supervisor) { $script:supervisor.Dispose(); $script:supervisor = $null }
    if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
    if ($script:radioModeApplyAfterStop -and $script:radioCatOperationPowerShell) {
        Set-MainText -Name 'FooterText' -Text '核心已停止；等待旧 CAT 查询收尾后再读取新状态。'
        if ($script:settingsWindow) {
            Set-UiTransientStatus -Message '旧电台查询仍在收尾；完成前不会发送 MAIN 设置。'
        }
        Update-UiRadioCatControls
        return $false
    }
    $script:stopTask = $null
    if ($script:closingAfterStop) {
        $script:radioModeApplyAfterStop = $null
        $script:radioModePreviousHriPortName = ''
        if ($script:radioCatOperationPowerShell) {
            $script:radioCatCloseMainAfterOperation = $true
            return $true
        }
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return $true
    }
    if ($script:radioModeApplyAfterStop) {
        $request = $script:radioModeApplyAfterStop
        $script:radioModeApplyAfterStop = $null
        $script:closingAfterStop = $false
        $script:reconnectAfterStop = $false
        $script:activeHriPortName = ''
        $script:activeTargetLabel = ''
        $script:activeTargetTag = ''
        $script:activeProfile = $null
        $script:lastUiBmState = ''
        $script:lastUiHriState = ''
        Set-OfflineDisplay -Reason 'HRI 会话已停止；正在验证 CAT 状态。'
        try {
            if ($request.operation -ceq 'setMode') {
                $script:radioCatPendingModeFrequencyRequest = $request
            } elseif ($request.operation -ceq 'setFrequency') {
                $script:radioCatPendingModeFrequencyRequest = $request
            } else {
                throw '断开后的 CAT 请求类型无效。'
            }
            Start-UiRadioCatOperation -Operation 'query' `
                -HriPortNameOverride ([string]$request.hri_port) -PortNameOverride ([string]$request.cat_port) `
                -BaudRateOverride ([int]$request.baud_rate) -StopBitsOverride ([string]$request.stop_bits)
            Set-UiTransientStatus -Message 'HRI 保持断开；先读取电台状态，再应用 MAIN VFO 设置。' -Restart
        } catch {
            $script:radioModePreviousHriPortName = ''
            if ($script:settingsWindow) {
                Set-UiTransientStatus -Message ('HRI 已断开；没有执行 CAT 设置：' + $_.Exception.Message) -Failed $true -Restart
            }
            Set-MainText -Name 'FooterText' -Text 'HRI 已停止；MAIN VFO 设置未完成，可在设置中核对 CAT-1 状态。'
            Update-UiRadioCatControls
        }
        return $true
    }
    if ($script:reconnectAfterStop) {
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        $script:activeTargetLabel = ''
        $script:activeTargetTag = ''
        $script:activeProfile = $null
        $script:activeHriPortName = ''
        $script:lastUiBmState = ''
        $script:lastUiHriState = ''
        Set-OfflineDisplay -Reason '当前连接已停止，正在连接所选目标。'
        $startDisconnected = [bool]$script:reconnectAfterStopBmStartDisconnected
        $script:reconnectAfterStopBmStartDisconnected = $false
        if ($startDisconnected) { Start-BridgeRun -BmStartDisconnected } else { Start-BridgeRun }
        return $true
    }
    if ($script:serialDisconnectPending) {
        $script:serialDisconnectPending = $false
        $script:serialDisconnectCoreStopIssued = $false
        $script:serialDisconnectCatStopRequested = $false
        $script:activeBmTransportConfig = $null
        $script:activeHriPortName = ''
        $script:activeTargetLabel = ''
        $script:activeTargetTag = ''
        $script:activeProfile = $null
        $script:lastUiBmState = ''
        $script:lastUiHriState = ''
        Set-OfflineDisplay -Reason 'Wires-X/HRI 与 CAT 串口均已断开。'
        Set-ConnectionButtonState
        Update-UiRadioCatControls
        return $true
    }
    $script:activeHriPortName = ''
    $script:activeTargetLabel = ''
    $script:activeTargetTag = ''
    $script:activeProfile = $null
    $script:lastUiBmState = ''
    $script:lastUiHriState = ''
    Set-OfflineDisplay -Reason 'HRI 会话已停止；没有待执行的 MAIN VFO 设置。'
    Set-MainText -Name 'FooterText' -Text '连接已停止；可按所选目标重新连接。'
    Set-ConnectionButtonState
    Update-UiRadioCatControls
    return $true
}

function Complete-BridgeStop {
    $completed = [bool](Complete-BridgeStopInternal)
    if (-not $completed) { return $false }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        if ($script:channelMutationSafetyStopPending) {
            Set-UiChannelStatus -Text '核心仍在运行；频道和 PTT 操作保持锁定，请重试停止。' -Failed $true
            Update-UiChannelDisplays
            Set-ConnectionButtonState
            return $true
        }
        if ($script:pendingChannelStopMutation) {
            $script:pendingChannelStopMutation=$null
            Set-UiChannelStatus -Text '核心仍在运行；最后一个频道没有删除。' -Failed $true
            Update-UiChannelDisplays
        }
        return $true
    }
    Clear-UiSessionTemp
    if ($script:channelMutationSafetyStopPending) {
        [void](Clear-UiChannelMutationSafetyState)
        Set-UiChannelStatus -Text '频道更新没有完整确认；连接已停止，原频道和 PTT 配置保留。可手动重新连接。' -Failed $true
        Set-MainText -Name 'FooterText' -Text '连接已停止；原频道配置保留，可手动重新连接。'
    }
    if ($script:pendingChannelStopMutation) {
        $script:channels=@(); $script:txChannelKey=''; $script:mutedChannelKeys=@{}
        $script:pendingChannelStopMutation=$null
        try { Save-UiPortableConfig | Out-Null; Set-UiChannelStatus -Text '已停止连接并移除最后一个频道。' }
        catch { Set-UiChannelStatus -Text ('连接已停止，但保存频道列表失败：' + $_.Exception.Message) -Failed $true }
        Update-UiChannelDisplays
    }
    return $true
}

function On-UiTimerTick {
    Update-UiTransientStatusExpiry
    if ($script:supervisor -and $script:supervisor.HasExited -and -not $script:stopTask) {
        if (-not $script:nativeExitCleanupPending) {
            $script:nativeExitCleanupPending=$true
            $script:nativeExitCleanupStarted=$true
        }
        try { [void](Complete-UiRadioCatOperationAndPersist) } catch { }
        if ($script:radioCatOperationPowerShell) { return }
        $exitCode=-1; [void]$script:supervisor.TryGetExitCode([ref]$exitCode)
        try { $script:supervisor.Dispose() } catch { }; $script:supervisor=$null
        if ($script:statusStream) { try { $script:statusStream.Dispose() } catch { }; $script:statusStream=$null }
        Clear-UiSessionTemp
        Reset-UiControlState -Text '控制协议：本次进程已退出'
        $script:activeProfile=$null; $script:activeTargetLabel=''; $script:activeTargetTag=''; $script:activeHriPortName=''
        $script:lastUiBmState=''; $script:lastUiHriState=''; $script:nativeExitCleanupPending=$false; $script:nativeExitCleanupStarted=$false
        $channelMutationSafetyStopped = [bool]$script:channelMutationSafetyStopPending
        $channelMutationAborted = [bool]$script:pendingChannelMutation
        if ($channelMutationSafetyStopped) {
            [void](Clear-UiChannelMutationSafetyState)
        } else {
            $script:pendingChannelMutation = $null
            $script:pendingRoutingMutation = $null
            $script:pendingRoutingStatusRequestId = ''
            $script:timedOutRoutingMutations = @{}
            $script:resolvedTimedOutRoutingRequests = @{}
            $script:routingMutationFence = $false
            $script:routingDraftAfterTimeout = $null
            $script:routingDraftPreservedAfterTimeout = $false
            $script:pendingDynamicCallTarget = $null
            $script:pendingDynamicLocalListen = $null
        }
        Set-OfflineDisplay -Reason ('核心进程已退出，退出码 {0}。CAT会话已收尾。' -f $exitCode)
        Set-MainText -Name 'CoreValue' -Text '已停止'; Set-MainText -Name 'CoreDetail' -Text ('核心进程已退出，退出码 {0}' -f $exitCode)
        if ($script:serialDisconnectPending) {
            $script:serialDisconnectPending=$false
            $script:serialDisconnectCoreStopIssued=$false
            $script:serialDisconnectCatStopRequested=$false
            $script:activeBmTransportConfig=$null
        }
        $script:bmConnectAfterCoreReady=$false
        Set-MainText -Name 'RunValue' -Text '已停止'; Set-MainText -Name 'FreshnessValue' -Text '本次运行已结束'
        if ($channelMutationSafetyStopped) {
            Set-UiChannelStatus -Text '频道更新没有完整确认；连接已停止，原频道和 PTT 配置保留。可手动重新连接。' -Failed $true
            Set-MainText -Name 'FooterText' -Text '连接已停止；原频道配置保留，可手动重新连接。'
        } elseif ($channelMutationAborted) {
            Set-UiChannelStatus -Text '核心在频道设置确认前退出；未确认的变更已丢弃，原频道配置保留。' -Failed $true
            Set-MainText -Name 'FooterText' -Text '频道更新未确认；原配置保留，可手动重新连接。'
        }
        Update-UiChannelDisplays; Set-ConnectionButtonState
        if ($script:closingAfterStop) { $script:allowWindowClose=$true; $script:mainWindow.Close(); return }
        if ($script:reconnectAfterStop) { $script:reconnectAfterStop=$false; Start-BridgeRun }
        return
    }
    if ($script:nativeExitCleanupPending) {
        try { [void](Complete-UiRadioCatOperationAndPersist) } catch { }
        if (-not $script:radioCatOperationPowerShell -and $script:supervisor -and $script:supervisor.HasExited) {
            # The next dispatcher turn runs the one-time finalizer above.
            $script:nativeExitCleanupPending=$false
        }
        return
    }
    try { Complete-UiIdentityQuery }
    catch {
        Add-UiIdentityDiagnostic -Stage 'dispatcher' -ErrorCode 'query_contract' `
            -ErrorType $_.Exception.GetType().FullName -Detail $_.Exception.Message
        if ($script:identityQuery) {
            try { Stop-UiIdentityQuery -Query $script:identityQuery -Reason 'dispatcher_error' } catch { }
        }
    }
    try { [void](Complete-UiRadioCatOperationAndPersist) }
    catch {
        if ($script:settingsWindow) { Set-UiTransientStatus -Message ('电台控制操作收尾失败：' + $_.Exception.Message) -Failed $true -Restart }
        Add-UiEvent 'CAT-1 操作清理失败'
    }
    try { [void](Invoke-UiRadioCatPollTick) }
    catch {
        if ($script:mainWindow) { Set-UiTransientStatus -Message ('电台状态轮询失败：' + $_.Exception.Message) -Failed $true -Restart }
    }
    if (Get-Command -Name Poll-BmManagementUi -ErrorAction SilentlyContinue) {
        try {
            if (Poll-BmManagementUi) { $script:bmManagementUiDisposed = $true }
        } catch { Set-MainText -Name 'FooterText' -Text 'BM 静态组请求收尾失败。' }
    }
    if ($script:bmCloseWhenDisposed -and $script:bmManagementUiDisposed) {
        $script:bmCloseWhenDisposed = $false
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return
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
                Set-MainTargetSummary -Profile $script:storedProfile -OverallLabel $script:targetLabel
                Set-MainText -Name 'TrafficDetail' -Text '连接已停止；可按所选目标重新连接。'
                Set-ConnectionButtonState
            }
            if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
        } else {
            Process-UiControlEvents
            if ($script:channelMutationSafetyStopPending) { return }
            Update-UiBmConnectionPoll
            if ($script:serialDisconnectPending -and -not $script:serialDisconnectCoreStopIssued -and
                (-not $script:bmConnectionNativeCapability -or
                    ($script:bmConnectionSnapshot -and -not [bool]$script:bmConnectionSnapshot.requested_enabled -and
                        -not [bool]$script:bmConnectionSnapshot.resolving -and -not [bool]$script:bmConnectionSnapshot.transport_open -and
                        [string]$script:bmConnectionSnapshot.bm_state -ceq 'stopped'))) {
                [void](Complete-UiSerialDisconnectAfterBm)
            }
            [void](Expire-UiNativeIdentityUpdate)
            [void](Expire-UiAudioGainRequest)
            if ($script:queuedQuickCall) { [void](Process-UiQueuedQuickCall) }
            if ($script:pendingQuickCall -and -not [bool]$script:pendingQuickCall.timed_out -and
                ([DateTime]::UtcNow - [DateTime]$script:pendingQuickCall.started_utc).TotalSeconds -ge 8) {
                $script:pendingQuickCall.timed_out = $true
                [void](Set-WirexChannelActivationRequestTimedOut -State $script:channelActivationState `
                    -RunId ([string]$script:pendingQuickCall.run_id) -RequestId ([string]$script:pendingQuickCall.request_id))
                [void](Add-UiQuickCallDiagnostic -RunId ([string]$script:pendingQuickCall.run_id) `
                    -RequestId ([string]$script:pendingQuickCall.request_id) -DestinationId ([uint64]$script:pendingQuickCall.destination_id) `
                    -Slot ([int]$script:pendingQuickCall.slot) -Result timeout -ErrorCode control_result_timeout)
                Set-DynamicGroupStatus '等待本机 Native 结果超时；没有确认是否发送，请检查状态后手动重试。' -Failed $true
                Add-UiEvent '动态组激活等待超时；保留原 request_id，没有自动重发'
                Update-DynamicGroupControls
            }
            if ($script:pendingRoutingMutation -and
                ([DateTime]::UtcNow - [DateTime]$script:pendingRoutingMutation.started_utc).TotalSeconds -ge 8) {
                $timedOutMutation = $script:pendingRoutingMutation
                $script:timedOutRoutingMutations[[string]$timedOutMutation.request_id] = $timedOutMutation
                $script:pendingRoutingMutation = $null
                if ($timedOutMutation.command -ceq 'tx_policy.replace' -or
                    ($timedOutMutation.command -ceq 'rx_policy.replace' -and $script:pendingChannelMutation -and
                        [string]$script:pendingChannelMutation.stage -ceq 'rx' -and [bool]$script:pendingChannelMutation.tx_applied)) {
                    $reason = if ($timedOutMutation.command -ceq 'tx_policy.replace') {
                        'PTT目标等待核心确认超时'
                    } else { 'PTT目标已应用，但监听频道等待核心确认超时' }
                    [void](Start-UiChannelMutationSafetyStop -Reason $reason)
                    return
                }
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
    Update-UiRadioCatControls
}

function Save-RenderedWindow {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window, [Parameter(Mandatory=$true)][string]$Path)
    $Window.UpdateLayout()
    Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
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

function Invoke-UiDispatcherPriority {
    param([System.Windows.Threading.DispatcherPriority]$Priority=[System.Windows.Threading.DispatcherPriority]::Render)
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $finishFrame = { $frame.Continue = $false }.GetNewClosure()
    [void]$dispatcher.BeginInvoke([System.Action]$finishFrame,$Priority)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Save-RenderedVisual {
    param([Parameter(Mandatory=$true)][System.Windows.Media.Visual]$Visual,[Parameter(Mandatory=$true)][string]$Path)
    $width = [Math]::Max(1,[int][Math]::Ceiling($Visual.RenderSize.Width))
    $height = [Math]::Max(1,[int][Math]::Ceiling($Visual.RenderSize.Height))
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Visual)
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
        if ($current -is [System.Windows.Controls.TextBlock] -and $current.Inlines.Count -gt 0) {
            $inlineText = ([System.Windows.Documents.TextRange]::new($current.ContentStart,$current.ContentEnd)).Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($inlineText)) { $values.Add($inlineText) }
            $inlineStack=New-Object 'System.Collections.Generic.Stack[object]'
            for($inlineIndex=$current.Inlines.Count-1;$inlineIndex -ge 0;$inlineIndex--){$inlineStack.Push($current.Inlines[$inlineIndex])}
            $completeInlineText=New-Object System.Text.StringBuilder
            while($inlineStack.Count -gt 0){
                $inline=$inlineStack.Pop()
                if($inline -is [System.Windows.Documents.Run]){[void]$completeInlineText.Append([string]$inline.Text)}
                elseif($inline -is [System.Windows.Documents.Span]){
                    for($nestedIndex=$inline.Inlines.Count-1;$nestedIndex -ge 0;$nestedIndex--){$inlineStack.Push($inline.Inlines[$nestedIndex])}
                }
            }
            $completeInlineValue=$completeInlineText.ToString().Trim()
            if(-not [string]::IsNullOrWhiteSpace($completeInlineValue)){$values.Add($completeInlineValue)}
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

function Get-UiCallHistoryVisualPageProbe {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window)
    $list=$Window.FindName('CallHistoryList')
    if (-not $list) { return [pscustomobject][ordered]@{ list_bounds=$null; rows=@() } }
    [void]$list.UpdateLayout()
    $listEvidence=Get-WpfElementLayoutEvidence -Window $Window -Element $list
    $rows=New-Object 'System.Collections.Generic.List[object]'
    for ($index=0; $index -lt $list.Items.Count; $index++) {
        $container=$list.ItemContainerGenerator.ContainerFromIndex($index)
        if ($container -isnot [System.Windows.FrameworkElement]) { continue }
        $containerEvidence=Get-WpfElementLayoutEvidence -Window $Window -Element $container
        $textElement=$null
        $pending=New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
        $pending.Push($container)
        while ($pending.Count -gt 0 -and -not $textElement) {
            $current=$pending.Pop()
            if ($current -is [System.Windows.Controls.TextBlock] -and -not [string]::IsNullOrWhiteSpace([string]$current.Text)) {
                $textElement=$current
                break
            }
            if ($current -is [System.Windows.Media.Visual] -or $current -is [System.Windows.Media.Media3D.Visual3D]) {
                $childCount=[System.Windows.Media.VisualTreeHelper]::GetChildrenCount($current)
                for ($childIndex=0; $childIndex -lt $childCount; $childIndex++) {
                    $child=[System.Windows.Media.VisualTreeHelper]::GetChild($current,$childIndex)
                    if ($child -is [System.Windows.DependencyObject]) { $pending.Push($child) }
                }
            }
        }
        $textEvidence=$null
        $insideList=$false
        if ($textElement) {
            $textEvidence=Get-WpfElementLayoutEvidence -Window $Window -Element $textElement
            $textRect=$textEvidence.actual; $listRect=$listEvidence.actual
            $insideList=($textRect.x -ge ($listRect.x - 1) -and $textRect.y -ge ($listRect.y - 1) -and
                $textRect.right -le ($listRect.right + 1) -and $textRect.bottom -le ($listRect.bottom + 1))
        }
        $rows.Add([pscustomobject][ordered]@{
            index=$index; key=[string]$list.Items[$index].key; text=if($textElement){[string]$textElement.Text}else{''}
            container_actual=$containerEvidence.actual; container_visible=$containerEvidence.visible
            container_fully_visible=[bool]$containerEvidence.fully_visible
            text_actual=if($textEvidence){$textEvidence.actual}else{$null}
            text_visible=if($textEvidence){$textEvidence.visible}else{$null}
            text_fully_visible=if($textEvidence){[bool]$textEvidence.fully_visible}else{$false}
            text_inside_list_bounds=$insideList
        })
    }
    return [pscustomobject][ordered]@{ list_bounds=$listEvidence.actual; rows=@($rows.ToArray()) }
}

function Get-UiVisualButtonTexts {
    param([Parameter(Mandatory=$true)][System.Windows.DependencyObject]$Root)
    $values=New-Object 'System.Collections.Generic.List[string]'
    $pending=New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
    $pending.Push($Root)
    while($pending.Count -gt 0){
        $current=$pending.Pop()
        if($current -is [System.Windows.Controls.Button] -and $null -ne $current.Content){$values.Add([string]$current.Content)}
        if($current -is [System.Windows.Media.Visual] -or $current -is [System.Windows.Media.Media3D.Visual3D]){
            $childCount=[System.Windows.Media.VisualTreeHelper]::GetChildrenCount($current)
            for($index=0;$index -lt $childCount;$index++){
                $child=[System.Windows.Media.VisualTreeHelper]::GetChild($current,$index)
                if($child -is [System.Windows.DependencyObject]){$pending.Push($child)}
            }
        }
    }
    return @($values)
}

function Test-UiComboMouseOpen {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo,[switch]$UseEditableTextBox)
    [void]$Combo.ApplyTemplate();[void]$Combo.UpdateLayout()
    $source=[System.Windows.UIElement]$Combo
    if($UseEditableTextBox){
        $textBox=$Combo.Template.FindName('PART_EditableTextBox',$Combo)
        if($textBox -isnot [System.Windows.Controls.TextBox]){return [pscustomobject]@{opened=$false;handled=$true;editable_text_preserved=$false}}
        $source=[System.Windows.UIElement]$textBox
    }
    $Combo.IsDropDownOpen=$false
    $eventArgs=New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[System.Windows.Input.MouseButton]::Left)
    $eventArgs.RoutedEvent=[System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
    $source.RaiseEvent($eventArgs)
    [void]$Combo.UpdateLayout()
    $opened=[bool]$Combo.IsDropDownOpen
    $handled=[bool]$eventArgs.Handled
    $Combo.IsDropDownOpen=$false
    return [pscustomobject]@{opened=$opened;handled=$handled;editable_text_preserved=$true}
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
    Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
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

function Get-UiComboContrastEvidence {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    [void]$Combo.ApplyTemplate()
    [void]$Combo.UpdateLayout()
    $selected = if ($Combo.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$Combo.SelectedItem.Content } else { [string]$Combo.Text }
    $background = if ($Combo.Background) { $Combo.Background.ToString() } else { '' }
    $foreground = if ($Combo.Foreground) { $Combo.Foreground.ToString() } else { '' }
    $Combo.IsDropDownOpen = $true
    [void]$Combo.UpdateLayout()
    Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
    $popup = $Combo.Template.FindName('PART_Popup',$Combo)
    $popupBackground = if ($popup -and $popup.Child -is [System.Windows.Controls.Border]) { $popup.Child.Background.ToString() } else { '' }
    $popupText = if ($popup -and $popup.Child) { @(Get-UiVisualTextValues -Root $popup.Child) } else { @() }
    $Combo.IsDropDownOpen = $false
    [void]$Combo.UpdateLayout()
    return [pscustomobject][ordered]@{ name=$Combo.Name; selected_text=$selected; background=$background; foreground=$foreground; popup_background=$popupBackground; popup_text=$popupText }
}

function Import-UiPortableConfig {
    try {
        $script:portableConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
        $script:channels = @($script:portableConfig.channels)
        $script:txChannelKey = [string]$script:portableConfig.tx_channel_id
        $script:mutedChannelKeys = @{}
        $script:bmServerSelectionPreferenceId = [string]$script:portableConfig.ui.bm_server_selection_id
        $script:radioControlPreferences = [pscustomobject][ordered]@{
            schema_version=1; cat_port=[string]$script:portableConfig.devices.cat_port
            baud_rate=[int]$script:portableConfig.devices.cat_baud_rate; stop_bits='Two'
            desired_power_watts=[int]$script:portableConfig.devices.desired_power_watts
        }
        $script:savedPlaybackGainMilli = Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.radio_playback_gain)
        $script:storedProfile = $null
        $c = $script:portableConfig.connection
        if (-not [string]::IsNullOrWhiteSpace([string]$c.callsign) -and [uint64]$c.gateway_id -gt 0 -and
            [uint64]$c.source_id -gt 0 -and [uint64]$c.color_code -le 15 -and @($script:channels).Count -gt 0) {
            try { $script:storedProfile = ConvertFrom-UiPortableConfigToProfile -Config $script:portableConfig } catch { $script:storedProfile = $null }
        }
        $script:portableConfigError = ''
        return $true
    } catch {
        $script:portableConfig = $null; $script:gatewayIdentityState = $null; $script:channels = @(); $script:txChannelKey = ''; $script:storedProfile = $null
        $script:portableConfigError = '统一配置无法读取；请检查 config.json。'
        return $false
    }
}

function Get-UiComboItemValue {
    param([AllowNull()][object]$Item)
    if ($null -eq $Item) { return '' }
    $tag = $null
    if ($Item -is [System.Windows.Controls.ComboBoxItem]) { $tag = $Item.Tag }
    elseif ($Item.PSObject.Properties['Value']) { return [string]$Item.Value }
    elseif ($Item.PSObject.Properties['Tag']) { $tag = $Item.Tag }
    else { return [string]$Item }
    if ($null -ne $tag -and $tag.PSObject.Properties['Value']) { return [string]$tag.Value }
    return [string]$tag
}

function Get-UiComboValue {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    return Get-UiComboItemValue -Item $Combo.SelectedItem
}

function Set-UiComboValue {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo,[string]$Value)
    foreach ($item in @($Combo.Items)) {
        $candidate = Get-UiComboItemValue -Item $item
        if ($candidate -ceq $Value) { $Combo.SelectedItem=$item; return $true }
    }
    return $false
}

function Set-UiGatewayIdentityState {
    param([Parameter(Mandatory=$true)][object]$Config)
    $connection = $Config.connection
    $sourceId = [uint64]$connection.source_id
    $gatewayId = [uint64]$connection.gateway_id
    $deviceNumber = ''
    $state = 'legacy_unmatched'
    if ($sourceId -eq 0 -and $gatewayId -eq 0) {
        # A new, empty profile can start with the common two-digit suffix.
        # It is not written as a Gateway until a DMR ID is supplied.
        $deviceNumber = '01'
        $state = 'new_empty'
    } elseif ($sourceId -gt 0 -and $gatewayId -eq $sourceId) {
        # Older profiles sometimes stored only the bare DMR ID in Gateway.
        # Keep it intact until the user explicitly chooses a suffix.
        $state = 'legacy_bare_id'
    } elseif ($sourceId -gt 0) {
        $base = [uint64]($sourceId * [uint64]100)
        $upper = [uint64]($base + [uint64]100)
        if ($gatewayId -ge $base -and $gatewayId -lt $upper) {
            $deviceNumber = ([uint64]($gatewayId - $base)).ToString('D2',[Globalization.CultureInfo]::InvariantCulture)
            $state = 'split_gateway'
        }
    }
    $script:gatewayIdentityState = [pscustomobject][ordered]@{
        source_id=$sourceId; gateway_id=$gatewayId; device_number=$deviceNumber; state=$state
    }
    return $script:gatewayIdentityState
}

function Get-UiGatewayIdentityForSave {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceText,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$DeviceNumberText,
        [Parameter(Mandatory=$true)][object]$State
    )
    $sourceId = ConvertTo-UiOptionalUnsigned -Text $SourceText -Maximum 16777215 -Label '本机 DMR ID'
    $deviceNumber = ([string]$DeviceNumberText).Trim()
    $sourceChanged = ($sourceId -ne [uint64]$State.source_id)
    $deviceNumberChanged = ($deviceNumber -cne [string]$State.device_number)

    if ($sourceId -eq 0 -and [uint64]$State.source_id -eq 0 -and [uint64]$State.gateway_id -eq 0) {
        if ($deviceNumberChanged) { throw '请先填写本机 DMR ID，再选择设备编号。' }
        return [pscustomobject][ordered]@{ source_id=[uint64]0; gateway_id=[uint64]0; device_number=[string]$State.device_number }
    }

    if (-not $deviceNumber) {
        if ($sourceChanged -or $deviceNumberChanged) { throw '请填写两位设备编号（00–99），再保存本机 DMR ID。' }
        return [pscustomobject][ordered]@{
            source_id=$sourceId; gateway_id=[uint64]$State.gateway_id; device_number=''
        }
    }
    if ($deviceNumber -cnotmatch '^(?:[0-9]{2})$') { throw '设备编号必须是两位数字（00–99）。' }
    if ($sourceId -eq 0) { throw '请先填写本机 DMR ID，再选择设备编号。' }

    $suffix = [uint64]::Parse($deviceNumber,[Globalization.CultureInfo]::InvariantCulture)
    $gatewayId = [uint64]($sourceId * [uint64]100 + $suffix)
    return [pscustomobject][ordered]@{
        source_id=$sourceId; gateway_id=$gatewayId; device_number=$deviceNumber
    }
}

function Apply-UiPortableConfigToControls {
    if (-not $script:portableConfig -or -not $script:mainWindow) { return }
    $c=$script:portableConfig.connection
    $identityState = Set-UiGatewayIdentityState -Config $script:portableConfig
    foreach ($pair in @(@('CallsignBox',[string]$c.callsign),@('SourceBox',[string]$c.source_id),
            @('MasterBox',[string]$c.master),@('MasterPortBox',[string]$c.master_port))) {
        $control=$script:mainWindow.FindName($pair[0]); if ($control) { $control.Text=$pair[1] }
    }
    $deviceNumberBox=$script:mainWindow.FindName('DeviceNumberBox')
    if ($deviceNumberBox) { $deviceNumberBox.Text=[string]$identityState.device_number }
    $preset=$script:mainWindow.FindName('MasterPresetBox'); if ($preset -and -not (Set-UiComboValue -Combo $preset -Value ([string]$script:portableConfig.ui.bm_server_selection_id))) { [void](Set-UiComboValue -Combo $preset -Value 'custom') }
    $password=$script:mainWindow.FindName('PasswordBox'); if ($password) { $password.Password=[string]$c.password }
    $api=$script:mainWindow.FindName('BmApiKeyBox'); if ($api) { $api.Password=[string]$c.api_key }
    $inBox=$script:mainWindow.FindName('WaveInEndpointBox'); if ($inBox) { [void](Set-UiComboValue -Combo $inBox -Value ([string]$script:portableConfig.devices.wave_in_endpoint_id)) }
    $outBox=$script:mainWindow.FindName('WaveOutEndpointBox'); if ($outBox) { [void](Set-UiComboValue -Combo $outBox -Value ([string]$script:portableConfig.devices.wave_out_endpoint_id)) }
    $serial=$script:mainWindow.FindName('SerialBox'); if ($serial) { [void](Set-UiComboValue -Combo $serial -Value ([string]$script:portableConfig.devices.hri_port)) }
    $cat=$script:mainWindow.FindName('CatPortBox'); if ($cat) { $cat.Text=[string]$script:portableConfig.devices.cat_port }
    $baud=$script:mainWindow.FindName('CatBaudRateBox'); if ($baud) { [void](Set-UiComboValue -Combo $baud -Value ([string]$script:portableConfig.devices.cat_baud_rate)) }
    $play=$script:mainWindow.FindName('PlaybackGainSlider'); if ($play) { $play.Value=[double]$script:portableConfig.audio.radio_playback_gain }
    $mic=$script:mainWindow.FindName('TransmitGainSlider'); if ($mic) { $mic.Value=[double]$script:portableConfig.audio.mic_transmit_gain }
    $script:savedPlaybackGainMilli=Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.radio_playback_gain)
    $script:savedTransmitGainMilli=Convert-UiStoredGainToMilli -Value ([double]$script:portableConfig.audio.mic_transmit_gain)
    Update-UiAudioGainValueLabels
    Update-UiChannelDisplays
}

function Copy-UiPortableConfigValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [array]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((Copy-UiPortableConfigValue -Value $item)) }
        return ,([object[]]$items.ToArray())
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = Copy-UiPortableConfigValue -Value $Value[$key] }
        return $copy
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = Copy-UiPortableConfigValue -Value $property.Value }
        return [pscustomobject]$copy
    }
    return $Value
}

function Get-UiSafeSettingsSaveErrorText {
    param([Parameter(Mandatory=$true)][System.Exception]$Exception)
    $message = [string]$Exception.Message
    if ($message -ceq '请等待当前设备操作结束后再保存。') { return $message }
    if ($message -ceq '统一配置尚未加载。') { return '配置尚未加载；请关闭并重新打开设置窗口后重试。' }
    if ($message -match '^(Gateway ID|本机 DMR ID|UDP 端口|色码) (必须是有效的无符号整数|超出允许范围)\。$') { return $message }
    if ($message -match '^devices\.(hri_port|serial_port|cat_port) 必须是 auto 或 COM1 到 COM999。$') {
        $field = switch -Regex ($message) {
            '^devices\.(hri_port|serial_port) ' { 'Wires-X HRI 串口' }
            '^devices\.cat_port ' { 'CAT 串口' }
        }
        return ($field + '选择无效；请刷新设备列表并重新选择。')
    }
    if ($message -match '^devices\.(wave_in_endpoint_id|wave_out_endpoint_id) 字段格式无效。$') {
        $field = if ($message -match 'wave_in_endpoint_id') { '音频输入' } else { '音频输出' }
        return ($field + '端点选择无效；请刷新设备列表并重新选择。')
    }
    if ($message -ceq 'connection 字段格式无效。') { return '呼号、BM 服务器或认证字段格式无效；请检查对应输入框。' }
    if ($message -ceq 'CAT 串口设置无效；停止位固定为 Two。') { return 'CAT 波特率设置无效；请选择列表中的波特率。' }
    if ($message -match '^(config\.json|便携配置|频道|tx_channel_id|audio\.|routing\.|ui\.)') {
        return '配置内容无效；当前文件未被覆盖，请检查连接、设备和频道设置。'
    }
    if ($Exception -is [System.UnauthorizedAccessException]) { return '无法写入配置；请检查用户配置目录的访问权限。' }
    if ($Exception -is [System.IO.IOException]) { return '无法写入配置文件；请检查目录权限和磁盘空间。' }
    return ('设置未保存（{0}）；现有配置已保留，请检查输入字段或配置目录。' -f $Exception.GetType().Name)
}

function Get-UiRadioCatPortConflictMessage {
    param([AllowEmptyString()][string]$HriPortName)
    $port = ([string]$HriPortName).Trim().ToUpperInvariant()
    if ($port -notmatch '^COM[1-9][0-9]{0,2}$' -or
        -not (Get-Command -Name 'Test-UiRadioCatPortConflictWithHri' -ErrorAction SilentlyContinue)) { return '' }
    if (Test-UiRadioCatPortConflictWithHri -HriPortName $port) {
        return ('CAT 串口 {0} 正在使用或释放中，不能同时启动 Wires-X。请断开 CAT 或更换 HRI 串口。' -f $port)
    }
    return ''
}

function Test-UiRadioCatUserActionBusy {
    if (-not (Get-Command -Name Get-UiRadioCatSessionState -ErrorAction SilentlyContinue)) { return $false }
    try {
        $state = Get-UiRadioCatSessionState
        if (-not $state -or -not $state.PSObject.Properties['user_action_busy']) { return $true }
        return [bool]$state.user_action_busy
    } catch {
        return $true
    }
}

function Test-UiBmTransportFieldsLocked {
    $coreActive = [bool]($script:supervisor -and -not $script:supervisor.HasExited)
    if (-not $coreActive) { return $false }
    if (-not $script:bmConnectionNativeCapability -or -not $script:bmConnectionSnapshot) { return $true }
    $state = $script:bmConnectionSnapshot
    return ([bool]$state.requested_enabled -or [bool]$state.resolving -or [bool]$state.transport_open -or
        [string]$state.bm_state -cne 'stopped')
}

function Get-UiBmTransportConfigValue {
    param([Parameter(Mandatory=$true)][object]$Config)
    return [pscustomobject][ordered]@{
        callsign=[string]$Config.connection.callsign
        gateway_id=[string]$Config.connection.gateway_id
        source_id=[string]$Config.connection.source_id
        master=([string]$Config.connection.master).Trim()
        master_port=[string]$Config.connection.master_port
        color_code=[string]$Config.connection.color_code
    }
}

function Test-UiBmTransportConfigMatchesCore {
    if (-not $script:activeBmTransportConfig -or -not $script:portableConfig) { return $false }
    $current = Get-UiBmTransportConfigValue -Config $script:portableConfig
    foreach ($name in @('callsign','gateway_id','source_id','master','master_port','color_code')) {
        if ([string]$current.$name -cne [string]$script:activeBmTransportConfig.$name) { return $false }
    }
    if (-not $script:sessionPasswordPath -or -not [System.IO.File]::Exists($script:sessionPasswordPath)) { return $false }
    try {
        $sessionPassword = [System.IO.File]::ReadAllText($script:sessionPasswordPath,[System.Text.Encoding]::UTF8).TrimEnd([char[]]@([char]13,[char]10))
        return [string]::Equals($sessionPassword,[string]$script:portableConfig.connection.password,[StringComparison]::Ordinal)
    } catch { return $false }
}

function Connect-UiSerialCombo {
    if ($script:preparationStarted -or $script:stopTask -or $script:serialDisconnectPending -or
        (Test-UiRadioCatUserActionBusy)) { return $false }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        if ($script:radioCatSessionRequested) { return $true }
        $connected = [bool](Connect-UiRadioCatSession)
        Set-ConnectionButtonState
        return $connected
    }
    if (-not (Save-SettingsFromWindow)) { return $false }
    if (-not $script:storedProfile) {
        Set-MainText -Name 'FooterText' -Text '配置尚未通过校验；请检查呼号、Gateway ID、本机 ID 和频道。'
        return $false
    }
    $script:bmConnectAfterCoreReady = $false
    $script:serialConnectCatAfterCoreReady = $true
    Start-BridgeRun -BmStartDisconnected
    return $true
}

function Connect-UiBmFromButton {
    if ([string]::IsNullOrWhiteSpace([string](Get-UiControl 'PasswordBox').Password)) {
        Set-MainText -Name 'FooterText' -Text '请先填写并保存 BM 密码，再连接 BM。'
        Add-UiEvent 'BM 密码未填写，未发起连接。'
        Set-ConnectionButtonState
        return $false
    }
    if ($script:preparationStarted -or $script:stopTask -or $script:serialDisconnectPending -or
        (Test-UiRadioCatUserActionBusy)) { return $false }
    if (-not (Save-SettingsFromWindow)) { return $false }
    if (-not $script:storedProfile) {
        Set-MainText -Name 'FooterText' -Text '配置尚未通过校验；请检查 BM 参数、呼号、Gateway ID 和本机 ID。'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:portableConfig.connection.password)) {
        Set-MainText -Name 'FooterText' -Text '请先填写并保存 BM 密码，再连接 BM。'
        Set-ConnectionButtonState
        return $false
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        if (-not $script:bmConnectionNativeCapability -or -not $script:controlConfirmed) {
            Set-MainText -Name 'FooterText' -Text '当前核心不支持 BM 独立连接；请更新核心后重试。'
            return $false
        }
        if ($script:bmConnectionSnapshot -and -not [bool]$script:bmConnectionSnapshot.requested_enabled -and
            -not [bool]$script:bmConnectionSnapshot.resolving -and -not [bool]$script:bmConnectionSnapshot.transport_open -and
            [string]$script:bmConnectionSnapshot.bm_state -ceq 'stopped' -and
            -not (Test-UiBmTransportConfigMatchesCore)) {
            $script:bmConnectAfterCoreReady = $true
            $script:reconnectAfterStop = $true
            $script:reconnectAfterStopBmStartDisconnected = $true
            if ($script:queuedQuickCall) {
                [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode reconnect_requested `
                    -Message '正在应用新的 BM 连接配置；排队取消，没有发送激活请求。')
            }
            Set-MainText -Name 'FooterText' -Text '正在应用新的 BM 连接配置；CAT 保持连接。'
            $script:stopTask = $script:supervisor.StopAsync(5000)
            Set-ConnectionButtonState
            return $true
        }
        if (-not $script:bmConnectionSnapshot) {
            Request-UiControlStatus
            Set-MainText -Name 'FooterText' -Text '正在读取当前 BM 配置状态。'
            return $true
        }
        return [bool](Set-UiBmConnectionEnabled -Enabled $true)
    }
    $script:bmConnectAfterCoreReady = $true
    $script:serialConnectCatAfterCoreReady = $true
    Start-BridgeRun -BmStartDisconnected
    return $true
}

function Toggle-UiBmConnection {
    $state = $script:bmConnectionSnapshot
    if ($script:supervisor -and -not $script:supervisor.HasExited -and $state -and $script:bmConnectionNativeCapability -and $script:controlConfirmed) {
        $isStopped = (-not [bool]$state.requested_enabled -and -not [bool]$state.resolving -and
            -not [bool]$state.transport_open -and [string]$state.bm_state -ceq 'stopped')
        $canReverseAcceptedConnect = ($script:bmConnectionPendingRequest -and [bool]$script:bmConnectionPendingRequest.ack_received -and
            [bool]$script:bmConnectionPendingRequest.enabled)
        if (-not $isStopped -or $canReverseAcceptedConnect) {
            return [bool](Set-UiBmConnectionEnabled -Enabled $false)
        }
    }
    return [bool](Connect-UiBmFromButton)
}

function Complete-UiSerialDisconnectAfterBm {
    if (-not $script:serialDisconnectPending -or $script:serialDisconnectCoreStopIssued) { return $false }
    if (-not $script:serialDisconnectCatStopRequested -and
        (Get-Command -Name Disconnect-UiRadioCatSession -ErrorAction SilentlyContinue)) {
        $script:serialDisconnectCatStopRequested = $true
        [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    }
    if ($script:radioCatOperationPowerShell -or $script:radioCatSessionRequested) { return $false }
    if ($script:preparationStarted) {
        $script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
        if (-not $script:prepareStopAsync) { Begin-PreparationStop }
        return $true
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        $script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
        $script:serialDisconnectCoreStopIssued = $true
        if ($script:queuedQuickCall) {
            [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode stop_requested `
                -Message '正在停止核心；排队取消，没有发送激活请求。')
        }
        Set-MainText -Name 'FooterText' -Text 'BM 已断开；正在停止 HRI 核心，CAT 串口已收尾。'
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-ConnectionButtonState
        return $true
    }
    $script:serialDisconnectPending = $false
    $script:serialDisconnectCoreStopIssued = $false
    $script:serialDisconnectCatStopRequested = $false
    $script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
    $script:activeBmTransportConfig = $null
    Set-OfflineDisplay -Reason '串口和核心已断开。'
    Set-ConnectionButtonState
    return $true
}

function Disconnect-UiSerialCombo {
    if ($script:serialDisconnectPending -or $script:closingAfterStop -or $script:stopTask) { return $false }
    if ($script:queuedQuickCall) {
        [void](Clear-UiQueuedQuickCall -Result cancelled -ErrorCode serial_disconnect_requested `
            -Message '正在断开串口与核心；排队取消，没有发送激活请求。')
    }
    $script:serialDisconnectCatStopRequested = $false
    $script:bmConnectAfterCoreReady = $false
    if ($script:preparationStarted) {
        $script:serialDisconnectPending = $true
        $script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
        Set-MainText -Name 'FooterText' -Text '正在取消核心准备并收好串口。'
        Begin-PreparationStop
        Set-ConnectionButtonState
        return $true
    }
    if (-not ($script:supervisor -and -not $script:supervisor.HasExited)) {
        if (-not $script:radioCatSessionRequested -and -not $script:radioCatOperationPowerShell) { return $true }
        $script:serialDisconnectPending = $true
        $script:serialDisconnectDeadlineUtc = [DateTime]::MinValue
        return [bool](Complete-UiSerialDisconnectAfterBm)
    }
    $script:serialDisconnectPending = $true
    $script:serialDisconnectCoreStopIssued = $false
    $script:serialDisconnectCatStopRequested = $false
    $script:serialDisconnectDeadlineUtc = [DateTime]::UtcNow.AddSeconds(15)
    if ($script:bmConnectionNativeCapability -and $script:controlConfirmed) {
        if (-not $script:bmConnectionSnapshot) {
            Request-UiControlStatus
            Set-MainText -Name 'FooterText' -Text '正在读取 BM 状态，确认网络关闭后再停止 HRI。'
            Set-ConnectionButtonState
            return $true
        }
        $state = $script:bmConnectionSnapshot
        if ([bool]$state.requested_enabled -or [bool]$state.resolving -or [bool]$state.transport_open -or
            [string]$state.bm_state -cne 'stopped') {
            [void](Set-UiBmConnectionEnabled -Enabled $false)
            Set-ConnectionButtonState
            return $true
        }
    }
    [void](Complete-UiSerialDisconnectAfterBm)
    return $true
}

function Set-ConnectionConfigLocked {
    $operationLocked=[bool]($script:preparationStarted -or $script:stopTask -or $script:prepareStopAsync -or $script:nativeExitCleanupPending -or
        $script:channelMutationSafetyStopPending)
    $coreActive = [bool]($script:supervisor -and -not $script:supervisor.HasExited)
    $deviceLocked = ($operationLocked -or $coreActive)
    $catSessionLocked = ([bool]$script:radioCatSessionRequested -or [bool]$script:radioCatOperationPowerShell -or
        [bool]$script:radioCatSessionShutdown)
    $catPortLocked = ($deviceLocked -or $catSessionLocked)
    $deviceRefreshLocked = ($deviceLocked -or $catSessionLocked)
    $bmLocked = ($operationLocked -or (Test-UiBmTransportFieldsLocked))
    foreach ($name in @('SerialBox','WaveInEndpointBox','WaveOutEndpointBox')) {
        $control=if ($script:mainWindow) { $script:mainWindow.FindName($name) } else { $null }
        if ($control) { $control.IsEnabled=-not $deviceLocked }
    }
    $refreshControl=if ($script:mainWindow) { $script:mainWindow.FindName('RefreshDevicesButton') } else { $null }
    if ($refreshControl) { $refreshControl.IsEnabled=-not $deviceRefreshLocked }
    foreach ($name in @('CatPortBox','CatBaudRateBox')) {
        $control=if ($script:mainWindow) { $script:mainWindow.FindName($name) } else { $null }
        if ($control) { $control.IsEnabled=-not $catPortLocked }
    }
    foreach ($name in @('CallsignBox','SourceBox','DeviceNumberBox','MasterPresetBox','MasterBox','MasterPortBox','PasswordBox')) {
        $control=if ($script:mainWindow) { $script:mainWindow.FindName($name) } else { $null }
        if ($control) { $control.IsEnabled=-not $bmLocked }
    }
    $apiKeyControl = if ($script:mainWindow) { $script:mainWindow.FindName('BmApiKeyBox') } else { $null }
    if ($apiKeyControl) { $apiKeyControl.IsEnabled=-not $operationLocked }
    $saveBlocked = [bool]($script:preparationStarted -or $script:stopTask -or $script:prepareStopAsync -or
        $script:nativeExitCleanupPending -or $script:channelMutationSafetyStopPending -or (Test-UiRadioCatUserActionBusy))
    $saveButton = if ($script:mainWindow) { $script:mainWindow.FindName('SaveSettingsButton') } else { $null }
    if ($saveButton) { $saveButton.IsEnabled = -not $saveBlocked }
    $lockSummary = if ($operationLocked) { '设备操作中，配置暂时锁定' }
        elseif ($coreActive -and (Test-UiBmTransportFieldsLocked)) { 'BM连接中，传输配置已锁定' }
        elseif ($coreActive) { 'HRI/音频设备已占用；BM配置可单独保存' }
        else { '' }
    $lockText = if ($script:mainWindow) { $script:mainWindow.FindName('ConnectionLockValue') } else { $null }
    if ($lockText) { $lockText.Text=$lockSummary }
    if (Get-Command Set-BmManagementUiControlState -ErrorAction SilentlyContinue) { Set-BmManagementUiControlState }
    Update-UiAudioGainControls
}

function Set-ConnectionButtonState {
    if (-not $script:mainWindow) { return }
    Set-ConnectionConfigLocked
    $operationBusy=[bool]($script:preparationStarted -or $script:stopTask -or $script:prepareStopAsync -or
        $script:nativeExitCleanupPending -or $script:channelMutationSafetyStopPending -or $script:serialDisconnectPending)
    $coreActive=[bool]($script:supervisor -and -not $script:supervisor.HasExited)
    $connectBm=$script:mainWindow.FindName('ConnectButton')
    if (Get-Command -Name Update-UiSerialConnectButton -ErrorAction SilentlyContinue) {
        Update-UiSerialConnectButton
    }
    $bmState=$script:bmConnectionSnapshot
    $bmRequested=($bmState -and [bool]$bmState.requested_enabled)
    $bmTransportOpen=($bmState -and [bool]$bmState.transport_open)
    $bmResolving=($bmState -and [bool]$bmState.resolving)
    $bmDisconnected=($bmState -and -not [bool]$bmState.requested_enabled -and -not [bool]$bmState.resolving -and
        -not [bool]$bmState.transport_open -and [string]$bmState.bm_state -ceq 'stopped')
    $bmCapabilityReady=($coreActive -and $script:controlConfirmed -and $script:bmConnectionNativeCapability -and -not $script:controlDiagnostic)
    if ($connectBm) {
        if (-not $coreActive) {
            $connectBm.Content='连接BM'
            $connectBm.IsEnabled=(-not $operationBusy -and -not (Test-UiRadioCatUserActionBusy))
        } elseif (-not $script:bmConnectionNativeCapability -or $script:controlDiagnostic) {
            $connectBm.Content='连接BM'
            $connectBm.IsEnabled=$false
        } elseif ($script:bmConnectionPendingRequest -and -not [bool]$script:bmConnectionPendingRequest.ack_received) {
            $connectBm.Content=if ([bool]$script:bmConnectionPendingRequest.enabled) { '正在连接BM' } else { '正在断开BM' }
            $connectBm.IsEnabled=$false
        } elseif (-not $bmDisconnected) {
            $connectBm.Content='断开BM'
            $canReverseRequest=($script:bmConnectionPendingRequest -and [bool]$script:bmConnectionPendingRequest.ack_received -and [bool]$script:bmConnectionPendingRequest.enabled)
            $connectBm.IsEnabled=(-not $operationBusy -and $bmCapabilityReady -and
                ($bmRequested -or $bmResolving -or $bmTransportOpen -or $canReverseRequest) -and
                -not ($script:bmConnectionPendingRequest -and -not [bool]$script:bmConnectionPendingRequest.enabled) -and
                -not (Test-UiRadioCatUserActionBusy))
        } else {
            $connectBm.Content='连接BM'
            $connectBm.IsEnabled=(-not $operationBusy -and -not (Test-UiRadioCatUserActionBusy))
        }
    }
    $stopButton=$script:mainWindow.FindName('StopButton')
    if ($stopButton) { $stopButton.IsEnabled=(-not $script:closingAfterStop -and -not $script:allowWindowClose) }
}

function Initialize-SettingsWindow {
    if ($script:settingsWindow) { return $script:settingsWindow }
    $script:settingsWindow=Import-WpfWindow -Path $script:settingsXamlPath
    $script:settingsWindow.Owner=$script:mainWindow; Fit-WpfWindowToWorkArea -Window $script:settingsWindow
    $script:settingsWindow.Add_Closed({
        param($sender,$eventArgs)
        if ([object]::ReferenceEquals($script:settingsWindow,$sender)) { $script:settingsWindow=$null }
    })
    $script:settingsWindow.FindName('CancelSettingsButton').Add_Click({ $script:settingsWindow.Close() })
    return $script:settingsWindow
}

function Show-SettingsWindow {
    if (-not $script:settingsWindow) { [void](Initialize-SettingsWindow) }
    $null=$script:settingsWindow.ShowDialog()
}

function Save-SettingsFromWindow {
    [CmdletBinding()] param([switch]$ConnectAfterSave)
    try {
        if (-not $script:portableConfig) { throw '统一配置尚未加载。' }
        if ((Test-UiRadioCatUserActionBusy) -or $script:stopTask -or $script:nativeExitCleanupPending -or $script:channelMutationSafetyStopPending) { throw '请等待当前设备操作结束后再保存。' }
        if (-not $script:gatewayIdentityState) { [void](Set-UiGatewayIdentityState -Config $script:portableConfig) }
        $candidate = Copy-UiPortableConfigValue -Value $script:portableConfig
        $c=$candidate.connection; $d=$candidate.devices; $a=$candidate.audio
        $c.callsign=([string](Get-UiControl 'CallsignBox').Text).Trim()
        $identity = Get-UiGatewayIdentityForSave -SourceText ([string](Get-UiControl 'SourceBox').Text) `
            -DeviceNumberText ([string](Get-UiControl 'DeviceNumberBox').Text) -State $script:gatewayIdentityState
        $c.gateway_id=[uint64]$identity.gateway_id
        $c.source_id=[uint64]$identity.source_id
        $c.master=([string](Get-UiControl 'MasterBox').Text).Trim()
        $c.master_port=ConvertTo-UiOptionalUnsigned -Text ([string](Get-UiControl 'MasterPortBox').Text) -Maximum 65535 -Label 'UDP 端口'
        $c.password=[string](Get-UiControl 'PasswordBox').Password; $c.api_key=[string](Get-UiControl 'BmApiKeyBox').Password
        $server=Get-UiControl 'MasterPresetBox'; $serverValue=Get-UiComboValue -Combo $server
        $candidateBmServerSelectionPreferenceId = [string]$script:bmServerSelectionPreferenceId
        if ($serverValue) { $candidateBmServerSelectionPreferenceId=$serverValue }
        $candidate.ui.bm_server_selection_id = $candidateBmServerSelectionPreferenceId
        $serial=Get-UiComboValue -Combo (Get-UiControl 'SerialBox'); if ($serial) { $d.hri_port=$serial }
        $waveIn=Get-UiComboValue -Combo (Get-UiControl 'WaveInEndpointBox'); if ($waveIn) { $d.wave_in_endpoint_id=$waveIn }
        $waveOut=Get-UiComboValue -Combo (Get-UiControl 'WaveOutEndpointBox'); if ($waveOut) { $d.wave_out_endpoint_id=$waveOut }
        $cat=Get-UiControl 'CatPortBox'
        $catPortValue = if ($cat.SelectedItem) { Get-UiComboValue -Combo $cat } else { ([string]$cat.Text).Trim() }
        if ($catPortValue) { $d.cat_port=$catPortValue }
        $baud=Get-UiComboValue -Combo (Get-UiControl 'CatBaudRateBox'); if ($baud) { $d.cat_baud_rate=[int]$baud }; $d.cat_stop_bits='Two'
        $runtimeConnected = ($script:supervisor -and -not $script:supervisor.HasExited)
        if (-not $runtimeConnected) {
            $play=Get-UiControl 'PlaybackGainSlider'; if ($play) { $a.radio_playback_gain=[Math]::Round([decimal]$play.Value,3) }
            $mic=Get-UiControl 'TransmitGainSlider'; if ($mic) { $a.mic_transmit_gain=[Math]::Round([decimal]$mic.Value,3) }
        }
        if ($script:radioControlPreferences -and $script:radioControlPreferences.desired_power_watts) { $d.desired_power_watts=[int]$script:radioControlPreferences.desired_power_watts }
        $d.cat_stop_bits='Two'
        $savedConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $candidate
        $script:portableConfig=$savedConfig
        [void](Set-UiGatewayIdentityState -Config $savedConfig)
        $savedDeviceNumberBox=Get-UiControl 'DeviceNumberBox'
        if ($savedDeviceNumberBox) { $savedDeviceNumberBox.Text=[string]$script:gatewayIdentityState.device_number }
        $script:bmServerSelectionPreferenceId=$candidateBmServerSelectionPreferenceId
        $script:storedProfile=$null
        if ($c.callsign -and [uint64]$c.gateway_id -gt 0 -and [uint64]$c.source_id -gt 0 -and @($script:channels).Count -gt 0) {
            try { $script:storedProfile=ConvertFrom-UiPortableConfigToProfile -Config $savedConfig } catch { $script:storedProfile=$null }
        }
        Update-UiPlaybackGainDisplay -Record $null; Update-UiChannelDisplays; Set-ConnectionButtonState
        Set-MainText -Name 'FooterText' -Text '设置已保存。'
        if ($ConnectAfterSave) { Start-BridgeRun }; return $true
    } catch {
        $safeError = Get-UiSafeSettingsSaveErrorText -Exception $_.Exception
        Set-UiTransientStatus -Message $safeError -Failed $true -Restart
        if (Get-Command -Name 'Add-UiEvent' -ErrorAction SilentlyContinue) { Add-UiEvent ('配置保存失败：' + $_.Exception.GetType().Name) }
        return $false
    }
}

function ConvertTo-UiOptionalUnsigned {
    param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][uint64]$Maximum,[Parameter(Mandatory=$true)][string]$Label)
    $normalized=([string]$Text).Trim()
    if (-not $normalized) { return [uint64]0 }
    $value=[uint64]0
    if (-not [uint64]::TryParse($normalized,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or
        $value -gt $Maximum) { throw ($Label + ' 必须是有效的无符号整数。') }
    return $value
}

function Save-UiAudioSettings {
    if (-not $script:portableConfig -or -not $script:mainWindow) { return $false }
    if ($script:supervisor -and -not $script:supervisor.HasExited) { return $false }
    try {
        $play=[Math]::Round([decimal](Get-UiControl 'PlaybackGainSlider').Value,3)
        $mic=[Math]::Round([decimal](Get-UiControl 'TransmitGainSlider').Value,3)
        if ([decimal]$script:portableConfig.audio.radio_playback_gain -eq $play -and
            [decimal]$script:portableConfig.audio.mic_transmit_gain -eq $mic) { return $true }
        $script:portableConfig.audio.radio_playback_gain=$play
        $script:portableConfig.audio.mic_transmit_gain=$mic
        $script:portableConfig=Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
        $script:savedPlaybackGainMilli=Convert-UiGainSliderToMilli -Value ([double]$play)
        $script:savedTransmitGainMilli=Convert-UiGainSliderToMilli -Value ([double]$mic)
        Update-UiAudioGainValueLabels
        return $true
    } catch {
        Set-UiChannelStatus -Text '音量设置保存失败。' -Failed $true
        return $false
    }
}

function Save-UiCatDesiredPower {
    if (-not $script:portableConfig -or -not $script:radioControlPreferences) { return $false }
    $watts=[int]$script:radioControlPreferences.desired_power_watts
    if ($watts -lt 5 -or $watts -gt 50 -or [int]$script:portableConfig.devices.desired_power_watts -eq $watts) { return $true }
    try {
        $script:portableConfig.devices.desired_power_watts=$watts
        $script:portableConfig=Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
        return $true
    } catch {
        Set-UiChannelStatus -Text 'CAT 功率设置保存失败。' -Failed $true
        return $false
    }
}

function Complete-UiRadioCatOperationAndPersist {
    $operation=[string]$script:radioCatOperationKind
    $completed=[bool](Complete-UiRadioCatOperation)
    if ($completed -and $operation -ceq 'setPower' -and $script:radioCatLastOperationStatus -ceq 'confirmed') {
        [void](Save-UiCatDesiredPower)
    }
    return $completed
}

function Test-UiMouseOriginWithinElement {
    param([AllowNull()][object]$Origin,[Parameter(Mandatory=$true)][System.Windows.DependencyObject]$Element)
    $current = $Origin -as [System.Windows.DependencyObject]
    while ($current) {
        if ([object]::ReferenceEquals($current,$Element)) { return $true }
        if ($current -is [System.Windows.Media.Visual] -or $current -is [System.Windows.Media.Media3D.Visual3D]) {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        } elseif ($current -is [System.Windows.ContentElement]) {
            $current = [System.Windows.ContentOperations]::GetParent($current)
        } else {
            $current = [System.Windows.LogicalTreeHelper]::GetParent($current)
        }
    }
    return $false
}

function Add-UiComboOpenHandlers {
    param([System.Windows.Window]$Window)
    foreach ($name in @('MasterPresetBox','SerialBox','WaveInEndpointBox','WaveOutEndpointBox','CatPortBox',
            'CatBaudRateBox','ChannelIdBox','ChannelKindBox','CatMainModeBox','CatMainFrequencyMHzBox','CatPowerBox')) {
        $combo=$Window.FindName($name); if (-not $combo) { continue }
        if ($combo.IsEditable) {
            [void]$combo.ApplyTemplate()
            $combo.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent,[System.Windows.Input.MouseButtonEventHandler]{
                param($sender,$eventArgs)
                $comboOwner=[System.Windows.Controls.ComboBox]$sender
                $textBox=$comboOwner.Template.FindName('PART_EditableTextBox',$comboOwner)
                $mouseOrigin=$eventArgs.OriginalSource
                if (-not $mouseOrigin) { $mouseOrigin=$eventArgs.Source }
                if ($textBox -isnot [System.Windows.Controls.TextBox] -or
                    -not (Test-UiMouseOriginWithinElement -Origin $mouseOrigin -Element $textBox)) { return }
                $openScript={ if ($comboOwner.IsEnabled -and $comboOwner.IsVisible) { $comboOwner.IsDropDownOpen=$true } }.GetNewClosure()
                [void]$comboOwner.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input,[Action]$openScript)
            },$true)
            $combo.AddHandler([System.Windows.UIElement]::MouseLeftButtonUpEvent,[System.Windows.Input.MouseButtonEventHandler]{
                param($sender,$eventArgs)
                $comboOwner=[System.Windows.Controls.ComboBox]$sender
                $textBox=$comboOwner.Template.FindName('PART_EditableTextBox',$comboOwner)
                $mouseOrigin=$eventArgs.OriginalSource
                if (-not $mouseOrigin) { $mouseOrigin=$eventArgs.Source }
                if ($textBox -isnot [System.Windows.Controls.TextBox] -or
                    -not (Test-UiMouseOriginWithinElement -Origin $mouseOrigin -Element $textBox)) { return }
                $openScript={ if ($comboOwner.IsEnabled -and $comboOwner.IsVisible) { $comboOwner.IsDropDownOpen=$true } }.GetNewClosure()
                [void]$comboOwner.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input,[Action]$openScript)
            },$true)
        } else {
            $combo.Add_PreviewMouseLeftButtonDown({ param($sender,$eventArgs)
                if (-not $sender.IsDropDownOpen) { $sender.IsDropDownOpen=$true; $eventArgs.Handled=$true }
            })
        }
    }
}

function Clear-UiSessionTemp {
    $candidate=[string]$script:sessionTempDirectory
    if ([string]::IsNullOrWhiteSpace($candidate)) { $script:sessionPasswordPath=''; return $true }
    try {
        $tempRoot=[System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        $full=[System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
        $parent=[System.IO.Path]::GetDirectoryName($full).TrimEnd('\')
        $leaf=[System.IO.Path]::GetFileName($full)
        if (-not [string]::Equals($parent,$tempRoot,[StringComparison]::OrdinalIgnoreCase) -or $leaf -cnotmatch '^wirex-bridge-session-[a-f0-9]{32}$') {
            throw '临时材料目录不符合本次会话路径约定。'
        }
        if ([System.IO.Directory]::Exists($full)) {
            $info=New-Object System.IO.DirectoryInfo($full)
            if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw '临时材料目录不能是重解析点。' }
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        }
        if ([System.IO.Directory]::Exists($full)) { throw '临时材料目录仍然存在。' }
        $script:sessionTempDirectory=''; $script:sessionPasswordPath=''
        return $true
    } catch {
        Add-UiEvent '本次会话临时材料清理失败；关闭或重新连接前会再次尝试'
        return $false
    }
}

function Update-DynamicGroupControls { Update-UiChannelDisplays }
function Set-DynamicGroupStatus { param([string]$Text,[bool]$Failed=$false); Set-UiChannelStatus -Text $Text -Failed $Failed }
function Set-SettingsPolicyLists { return }
function Set-RoutingEditorStatus { param([string]$Text,[bool]$Failed=$false); Set-UiChannelStatus -Text $Text -Failed $Failed }
function Set-RoutingMutationControls { param([bool]$Enabled); Update-UiChannelDisplays }
function Set-RoutingMutationPendingState { param([bool]$Pending); Update-UiChannelDisplays }
function Update-TxTargetButtonState { return }
function Update-RoutingDisplays { Update-UiChannelDisplays }

function Set-ActiveRoutingSnapshot {
    param([object]$Routing,[switch]$Force,[switch]$SyncAllEditor,[switch]$SyncRxEditor,[switch]$SyncTxEditor)
    if (-not (Test-UiRoutingSnapshot -Routing $Routing)) { throw '核心返回的路由设置格式无效。' }
    if ($script:portableConfig -and [uint64]$Routing.local_source_id -ne [uint64]$script:portableConfig.connection.source_id) { throw '核心返回的本机 ID 与统一配置不一致。' }
    if (-not $Force -and $script:activeRouting -and
        ([uint64]$Routing.rx_policy_revision -lt [uint64]$script:activeRouting.rx_policy_revision -or
         [uint64]$Routing.tx_policy_revision -lt [uint64]$script:activeRouting.tx_policy_revision)) { return $false }
    $script:activeRouting=$Routing; $script:routingLastUpdateUtc=[DateTime]::UtcNow
    Update-UiChannelDisplays
    return $true
}

function Invoke-UiRoutingMutation {
    param([Parameter(Mandatory=$true)][ValidateSet('rx_policy.replace','tx_policy.replace')][string]$Command,
        [Parameter(Mandatory=$true)][object]$PolicyOrTarget)
    if ($script:channelMutationSafetyStopPending) { throw '频道目标状态未确认；停止完成前不能提交路由修改。' }
    if ($script:pendingRoutingMutation -or $script:routingMutationFence) { throw '上一项频道设置仍在处理中。' }
    if (-not $script:supervisor -or $script:supervisor.HasExited) { throw '当前没有连接核心。' }
    if (-not $script:controlConfirmed -or -not $script:routingCapabilities -or -not $script:activeRouting) { throw '核心尚未准备好接收频道设置。' }
    $mediaOwner=[string]$script:activeRouting.media_owner
    if ($Command -ceq 'tx_policy.replace' -and @('tx_active','tx_draining','fault') -ccontains $mediaOwner) {
        throw '请等待当前发射与清理结束后再切换 PTT 目标。'
    }
    if ($Command -ceq 'rx_policy.replace' -and @('idle','rx_active','rx_draining','rx_stopping') -cnotcontains $mediaOwner) {
        throw '当前核心状态不能替换监听频道。'
    }
    $revision=if ($Command -ceq 'rx_policy.replace') { [uint64]$script:activeRouting.rx_policy_revision } else { [uint64]$script:activeRouting.tx_policy_revision }
    if ($Command -ceq 'rx_policy.replace') {
        if (-not (Test-UiRxPolicy -Policy $PolicyOrTarget -LocalSourceId ([uint64]$script:portableConfig.connection.source_id))) { throw '由频道生成的收听策略无效。' }
        $payload=[ordered]@{expected_revision=$revision;rx_policy=(Copy-UiRxPolicy -Policy $PolicyOrTarget)}
    } else {
        if (-not (Test-UiControlUnsigned -Value $PolicyOrTarget.destination_id -Minimum 1 -Maximum 16777215) -or
            [string]$PolicyOrTarget.kind -cnotin @('group','private') -or -not (Test-UiControlUnsigned -Value $PolicyOrTarget.slot -Minimum 1 -Maximum 2)) { throw 'PTT频道设置无效。' }
        $target=[pscustomobject][ordered]@{destination_id=[uint64]$PolicyOrTarget.destination_id;kind=[string]$PolicyOrTarget.kind;slot=[uint64]$PolicyOrTarget.slot}
        $payload=[ordered]@{expected_revision=$revision;tx_target=$target;transmit_enabled=$true}
    }
    $requestId=[guid]::NewGuid().ToString('D'); $json=ConvertTo-Json -InputObject $payload -Depth 8 -Compress
    $script:pendingRoutingMutation=[pscustomobject]@{request_id=$requestId;command=$Command;expected_revision=$revision;target=$(if ($Command -ceq 'tx_policy.replace') {$payload.tx_target} else {$null});started_utc=[DateTime]::UtcNow}
    $script:pendingControlRequests[$requestId]=$Command
    Set-UiChannelStatus -Text '正在应用频道设置；收到核心确认前保留当前列表。'
    Update-UiChannelDisplays
    if (-not $script:supervisor.SendControlCommand($requestId,$Command,$json)) {
        [void]$script:pendingControlRequests.Remove($requestId); $script:pendingRoutingMutation=$null
        Set-UiChannelStatus -Text '核心没有接收频道设置；当前频道列表保持不变。' -Failed $true
        Update-UiChannelDisplays; throw '命令发送失败。'
    }
}

function Complete-UiChannelMutationFailure {
    param([string]$Message)
    $script:pendingChannelMutation=$null; $script:pendingRoutingMutation=$null
    Set-UiChannelStatus -Text $Message -Failed $true; Update-UiChannelDisplays
}

$script:bmManagementUiPath = Join-Path $script:uiRoot 'BmManagementUi.ps1'
if ([System.IO.File]::Exists($script:bmManagementUiPath)) { . $script:bmManagementUiPath }
$script:radioCatUiPath = Join-Path $script:uiRoot 'RadioCatUi.ps1'
if ([System.IO.File]::Exists($script:radioCatUiPath)) { . $script:radioCatUiPath }
$script:mainWindow = Import-WpfWindow -Path $script:mainXamlPath
Fit-WpfWindowToWorkArea -Window $script:mainWindow
$script:radioCatControllerInitialized = $false
$script:application.MainWindow = $script:mainWindow
[void](Import-UiPortableConfig)
Apply-UiPortableConfigToControls
Initialize-UiRadioCatController
Set-OfflineDisplay
$script:startupNeedsSettings = ($null -eq $script:storedProfile)
if ($script:portableConfigError) { Set-MainText -Name 'FooterText' -Text $script:portableConfigError }
Add-UiComboOpenHandlers -Window $script:mainWindow
Register-UiSetupLinks
(Get-UiControl 'ConnectButton').Add_Click({ [void](Toggle-UiBmConnection) })
(Get-UiControl 'SaveSettingsButton').Add_Click({ [void](Save-SettingsFromWindow) })
(Get-UiControl 'StopButton').Add_Click({ Request-StopAndExit })
(Get-UiControl 'AddChannelButton').Add_Click({ Add-UiChannelFromInputs })
$pagePreviousButton = $script:mainWindow.FindName('ChannelPagePreviousButton')
if ($pagePreviousButton) { $pagePreviousButton.Add_Click({ Set-UiChannelPage -Delta -1 }) }
$pageNextButton = $script:mainWindow.FindName('ChannelPageNextButton')
if ($pageNextButton) { $pageNextButton.Add_Click({ Set-UiChannelPage -Delta 1 }) }
(Get-UiControl 'RefreshDevicesButton').Add_Click({
    try { Start-UiDeviceDiscovery } catch { Set-MainText -Name 'FooterText' -Text '设备刷新失败，请重试。' }
})
(Get-UiControl 'MasterPresetBox').Add_SelectionChanged({
    if ($script:loadingSettings) { return }
    $selection=Get-UiComboValue -Combo (Get-UiControl 'MasterPresetBox')
    if ($selection -ceq 'bm-china-4602') {
        (Get-UiControl 'MasterBox').Text='43.129.83.124'
        (Get-UiControl 'MasterPortBox').Text='62031'
    }
})
(Get-UiControl 'PlaybackGainSlider').Add_ValueChanged({ On-UiAudioGainValueChanged })
(Get-UiControl 'TransmitGainSlider').Add_ValueChanged({ On-UiAudioGainValueChanged })
Initialize-UiChannelInputHandlers
(Get-UiControl 'CallHistoryList').Add_SelectionChanged({
    if (-not $script:historyPageRendering) {
        $selected = (Get-UiControl 'CallHistoryList').SelectedItem
        $script:selectedCallHistoryKey = if ($selected -and $selected.PSObject.Properties['key']) { [string]$selected.key } else { '' }
    }
    Update-UiCallHistoryActionState
})
$historyPreviousButton=$script:mainWindow.FindName('CallHistoryPagePreviousButton')
if ($historyPreviousButton) { $historyPreviousButton.Add_Click({ Set-UiCallHistoryPage -Delta -1 }) }
$historyNextButton=$script:mainWindow.FindName('CallHistoryPageNextButton')
if ($historyNextButton) { $historyNextButton.Add_Click({ Set-UiCallHistoryPage -Delta 1 }) }
$historyTarget=$script:mainWindow.FindName('SetHistoryCallTargetButton')
if ($historyTarget) { $historyTarget.Add_Click({
    $entry=(Get-UiControl 'CallHistoryList').SelectedItem; if (-not $entry) { return }
    try { $target=New-UiCallTargetFromHistoryEntry -Entry $entry; Invoke-UiSetCallTarget -Target $target -Description ('历史呼叫 ' + $entry.source_id) }
    catch { Set-UiChannelStatus -Text $_.Exception.Message -Failed $true }
}) }
if (Get-Command -Name Initialize-BmManagementUi -ErrorAction SilentlyContinue) {
    Initialize-BmManagementUi -Window $script:mainWindow; $script:bmManagementUiInitialized=$true
}
$script:mainWindow.Add_Closing({
    param($sender, $eventArgs)
    if ((Get-Command -Name Dispose-BmManagementUi -ErrorAction SilentlyContinue) -and $script:bmManagementUiInitialized -and -not $script:bmManagementUiDisposed) {
        $disposed = [bool](Dispose-BmManagementUi)
        if (-not $disposed) {
            $eventArgs.Cancel = $true
            $script:bmCloseWhenDisposed = $true
            return
        }
        $script:bmManagementUiDisposed = $true
    }
    if (Get-Command -Name Stop-UiRadioCatSession -ErrorAction SilentlyContinue) {
        $catShutdownComplete = [bool](Stop-UiRadioCatSession -Reason app_shutdown)
        if (-not $catShutdownComplete) {
            $eventArgs.Cancel = $true
            $script:radioCatCloseMainAfterOperation = $true
        }
    }
    if ($script:radioCatOperationPowerShell) {
        $eventArgs.Cancel = $true
        if (($script:supervisor -and -not $script:supervisor.HasExited) -or $script:preparationStarted -or $script:stopTask) {
            Request-StopAndExit
        } else {
            $script:radioCatCloseMainAfterOperation = $true
        }
        return
    }
    if ($script:allowWindowClose -and -not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery -and -not $script:identityQuery) {
        if (-not (Clear-UiSessionTemp)) { $eventArgs.Cancel=$true; Set-MainText -Name 'FooterText' -Text '本次连接的临时材料仍被占用；清理完成后再关闭。' }
        return
    }
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
    if (-not (Clear-UiSessionTemp)) {
        $eventArgs.Cancel=$true
        Set-MainText -Name 'FooterText' -Text '本次连接的临时材料仍被占用；清理完成后再关闭。'
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
    Add-UiComboOpenHandlers -Window $script:mainWindow
    if ($UiTestFixture) {
        Set-OfflineDisplay -Reason '隔离 UI 测试没有启动设备或网络。'; Set-ConnectionButtonState; return
    }
    if ($RoutingDiagnostic -and $RoutingDiagnosticAutoTest) {
        Start-BridgeRun
        return
    }
    if ($RenderOnly -or $OfflinePreview -or $NoAutoConnect) {
        Set-OfflineDisplay -Reason '离线预览：没有连接设备或网络。'
        Set-ConnectionButtonState; return
    }
    try {
        Start-UiDeviceDiscovery
        if ($script:storedProfile) { Start-BridgeRun }
        else { Set-MainText -Name 'FooterText' -Text '请填写呼号、Gateway ID、本机 DMR ID，并加入至少一个频道。' }
    } catch {
        Set-OfflineDisplay -Reason '配置需要修正。'; Set-MainText -Name 'FooterText' -Text '请检查统一配置和设备选择。'
    }
})

$script:uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:uiTimer.Add_Tick({ On-UiTimerTick })
$script:uiTimer.Start()

if ($UiTestFixture) {
    Initialize-UiConsoleTestFixture | Out-Null
    return
}

if ($RenderOnly) {
    if (-not $RenderOutputDirectory) { throw '-RenderOnly 需要 -RenderOutputDirectory。' }
    $script:uiTimer.Stop()
    $renderDirectory=[System.IO.Path]::GetFullPath($RenderOutputDirectory)
    [System.IO.Directory]::CreateDirectory($renderDirectory) | Out-Null
    $script:portableConfig.connection.source_id=[uint64]3149876
    $script:channels=@(
        (New-UiChannelRecord -Id 91 -Kind group -Slot 2),
        (New-UiChannelRecord -Id 9990 -Kind private -Slot 2 -Name ('测试长频道名称' * 8)),
        (New-UiChannelRecord -Id 460997 -Kind private -Slot 2)
    )
    $script:txChannelKey='group:91:2'
    $script:mutedChannelKeys=@{}
    Update-UiChannelDisplays
    $script:mainWindow.FindName('CatOperatingPanel').Visibility=[Windows.Visibility]::Visible
    $script:mainWindow.FindName('CatObservedMainModeText').Text='FM'
    $script:mainWindow.FindName('CatObservedFrequencyText').Text='145.500 MHz'
    $script:mainWindow.FindName('CatObservedPowerText').Text='25 W'
    $script:mainWindow.FindName('CatObservedPanel').Visibility=[Windows.Visibility]::Visible
    $script:callIdentityCache['460997']=[pscustomobject]@{source_id=[uint32]460997;id=[uint32]460997;callsign='N0T';name='短呼号测试者';status='found';display_name='N0T'}
    $script:callHistoryModel.Clear(); $script:callHistoryKeys=@{}; $script:selectedCallHistoryKey=''; $script:callHistoryPageIndex=0
    for ($historyIndex=1; $historyIndex -le 8; $historyIndex++) {
        $historyKey='render-fixture|' + $historyIndex
        $historyEntry=[pscustomobject][ordered]@{
            key=$historyKey;run_id='render-fixture';generation=[uint64]$historyIndex;source_id=[uint64]460997
            destination_id=[uint64](3149876+$historyIndex);slot=[uint64]2;kind='private';timestamp=[DateTime]::Now.AddMinutes(-$historyIndex)
            source_label='N0T · 短呼号测试者';identity_details='';text=('来话 {0} · 私呼 · 来源 N0T' -f $historyIndex)
        }
        $script:callHistoryModel.Add($historyEntry); $script:callHistoryKeys[$historyKey]=$true
    }
    Render-UiCallHistoryPage
    $catPanel=$script:mainWindow.FindName('RadioCatPanel');if($catPanel){$catPanel.Visibility=[Windows.Visibility]::Visible}
    Set-UiTransientStatus -Message 'RenderOnly 离线界面检查提示' -Restart
    $script:mainWindow.Show(); Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
    Set-MainText -Name 'BmValue' -Text '已连接'
    $script:mainWindow.FindName('BmRttValue').Text='42 ms · 3 次'
    $script:mainWindow.FindName('BmRttValue').Visibility=[Windows.Visibility]::Visible
    $script:mainWindow.FindName('BmRttMetric').Visibility=[Windows.Visibility]::Visible
    $script:latestStatus=[pscustomobject][ordered]@{
        run_id='render-fixture';bm_state='ready';bm_rtt_valid=$true;bm_rtt_last_ms=[double]42;bm_rtt_sample_count=[uint64]3
        rx_session_dmrd_valid=$true;rx_session_dmrd_expected=[uint64]100;rx_session_dmrd_received=[uint64]97;rx_session_dmrd_loss_pct=[double]3
        current_call_valid=$true;current_call_generation=[uint64]1;current_call_source_id=[uint64]460997
        current_call_destination_id=[uint64]3149876;current_call_slot=[uint64]2;current_call_kind='P'
    }
    $script:lastStatusUtc=[DateTime]::UtcNow
    Update-UiReceiveMetricsDisplay -Record $script:latestStatus
    Update-UiChannelDisplays
    if ($script:bmManagementUiInitialized) {
        $script:activeProfile=[pscustomobject][ordered]@{ connection=[pscustomobject][ordered]@{ gateway_id=[uint64]12345 } }
        $script:bmManagementUiWindow=$script:mainWindow
        $script:bmManagementUiPageSize=3
        $script:bmManagementUiPageIndex=0
        $script:bmManagementStatus='loaded'
        $script:bmManagementObservedDeviceId='12345'
        $script:bmManagementObservedApiKey=''
        $script:bmManagementGroups=@(
            [pscustomobject][ordered]@{ type='static'; device_id='12345'; talkgroup=[uint64]91; slot=1; text='TG 91' },
            [pscustomobject][ordered]@{ type='static'; device_id='12345'; talkgroup=[uint64]92; slot=1; text='TG 92' },
            [pscustomobject][ordered]@{ type='static'; device_id='12345'; talkgroup=[uint64]93; slot=2; text='TG 93' },
            [pscustomobject][ordered]@{ type='static'; device_id='12345'; talkgroup=[uint64]94; slot=2; text='TG 94' }
        )
        Update-BmManagementUiVisiblePage
        $bmStaticFirstPageCount=@($script:bmManagementUiControls['BmStaticGroupsList'].Items).Count
        $bmStaticFirstPageText=[string]$script:bmManagementUiControls['BmStaticGroupPageText'].Text
        [void](Set-BmManagementUiPage -PageIndex 1)
        $bmStaticSecondPageCount=@($script:bmManagementUiControls['BmStaticGroupsList'].Items).Count
        $bmStaticSecondPageText=[string]$script:bmManagementUiControls['BmStaticGroupPageText'].Text
        [void](Set-BmManagementUiPage -PageIndex 0)
        $bmStaticPanel=$script:mainWindow.FindName('BmStaticGroupPanel')
        if ($bmStaticPanel) { $bmStaticPanel.Visibility=[Windows.Visibility]::Visible }
        foreach ($name in @('BmStaticGroupsList','BmStaticGroupPagePreviousButton','BmStaticGroupPageText','BmStaticGroupPageNextButton')) {
            $control=$script:mainWindow.FindName($name)
            if ($control) { $control.Visibility=[Windows.Visibility]::Visible }
        }
        $bmSource=$script:mainWindow.FindName('BmStaticGroupSourceValue')
        if ($bmSource) { $bmSource.Text='设备 12345'; $bmSource.Visibility=[Windows.Visibility]::Visible }
        foreach ($name in @('RefreshBmStaticGroupsButton','RemoveBmStaticGroupButton','BmStaticGroupIdBox','AddBmStaticGroupButton')) {
            $control=$script:mainWindow.FindName($name)
            if ($control) { $control.Visibility=[Windows.Visibility]::Visible; $control.IsEnabled=$false }
        }
    } else {
        $bmStaticFirstPageCount=0; $bmStaticFirstPageText=''; $bmStaticSecondPageCount=0; $bmStaticSecondPageText=''
    }
    if ($script:bmManagementUiInitialized) {
        $script:bmManagementStatus='unavailable'
        $script:bmManagementGroups=@()
        $script:bmManagementAddContext=$null
        $script:bmManagementObservedDeviceId=''
        $script:bmManagementObservedApiKey=''
        $script:bmManagementUiPageIndex=0
        Update-BmManagementUiVisiblePage
        Set-BmManagementUiControlState
    }
    $bmStaticGroupTexts=@()
    $historyFirstPageKeys=@((Get-UiControl 'CallHistoryList').Items | ForEach-Object { [string]$_.key })
    Set-UiCallHistoryPage -Delta 1
    $historySecondPageKeys=@((Get-UiControl 'CallHistoryList').Items | ForEach-Object { [string]$_.key })
    $historyPageProbe=[pscustomobject][ordered]@{first_page_count=$historyFirstPageKeys.Count;second_page_count=$historySecondPageKeys.Count;second_page_text=$script:mainWindow.FindName('CallHistoryPageText').Text}
    Set-UiCallHistoryPage -Delta -1
    $historyPageVisualProbe=Get-UiCallHistoryVisualPageProbe -Window $script:mainWindow
    $historyPageProbe | Add-Member -NotePropertyName visual -NotePropertyValue $historyPageVisualProbe -Force
    $bmStaticGroupTexts=@(Get-UiVisualTextValues -Root ($script:mainWindow.FindName('BmStaticGroupsList')))
    Update-UiChannelDisplays
    $catPort=$script:mainWindow.FindName('CatPortBox');$oldCatPort=if($catPort){[string]$catPort.Text}else{''}
    $catPortProbe=$null
    if($catPort -and $catPort.IsVisible){
        $catPort.Text='COM77'
        $catPortProbe=Test-UiComboMouseOpen -Combo $catPort -UseEditableTextBox
        $catPortProbe.editable_text_preserved=([string]$catPort.Text -ceq 'COM77')
        $catPort.Text=$oldCatPort
    }
    Set-UiTransientStatus -Message 'RenderOnly 离线界面检查提示' -Restart
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $renderDirectory 'main-window.png')
    $comboContrast=@(foreach($name in @('MasterPresetBox','ChannelKindBox','CatPortBox','CatBaudRateBox','CatMainModeBox','CatMainFrequencyMHzBox','CatPowerBox','ChannelIdBox')) { $combo=$script:mainWindow.FindName($name); if($combo -and $combo.IsVisible) { Get-UiComboContrastEvidence -Combo $combo } })
    $settings=Initialize-SettingsWindow
    $settings.Show(); Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
    Save-RenderedWindow -Window $settings -Path (Join-Path $renderDirectory 'settings-window.png')
    $callerIdentitySamples=[ordered]@{}
    $savedCallerIdentity=$script:callIdentityCache['460997']
    $hadRenderOpenUri=$script:uiTestHooks.ContainsKey('OpenUri')
    $savedRenderOpenUri=if($hadRenderOpenUri){$script:uiTestHooks['OpenUri']}else{$null}
    $script:renderCapturedCallerUris=New-Object 'System.Collections.Generic.List[string]'
    $script:uiTestHooks['OpenUri']={ param($Uri) $script:renderCapturedCallerUris.Add([string]$Uri) }
    foreach($sample in @(
        [pscustomobject]@{key='short';callsign='N0T';name='短呼号测试者'},
        [pscustomobject]@{key='long';callsign='BG1ABCDEFG';name='长呼号测试者'}
    )) {
        $script:callIdentityCache['460997']=[pscustomobject]@{
            source_id=[uint32]460997;id=[uint32]460997;callsign=[string]$sample.callsign
            name=[string]$sample.name;status='found';display_name=([string]$sample.callsign + ' · ' + [string]$sample.name)
        }
        Update-UiChannelDisplays
        Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
        $sampleCard=@($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object {
            -not $_.Tag.blank -and [string]$_.Tag.channel_key -ceq 'private:460997:2'
        }) | Select-Object -First 1
        $sampleArea=@($sampleCard.Child.Children | Where-Object {
            $_ -is [System.Windows.Controls.Border] -and [string]$_.Tag -ceq 'ChannelCallArea'
        }) | Select-Object -First 1
        $sampleTextBlocks=@($sampleArea.Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })
        $sampleCallsignLink=@($sampleTextBlocks[0].Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] }) | Select-Object -First 1
        $sampleIdLink=@($sampleTextBlocks[1].Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] }) | Select-Object -First 1
        if (-not $sampleCallsignLink -or -not $sampleIdLink) { throw 'RenderOnly 来话身份样本缺少呼号或 DMR ID 链接。' }
        $callsignStart=$script:renderCapturedCallerUris.Count
        $sampleCallsignLink.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent))
        $callsignUri=if($script:renderCapturedCallerUris.Count -gt $callsignStart){[string]$script:renderCapturedCallerUris[$script:renderCapturedCallerUris.Count-1]}else{''}
        $dmrStart=$script:renderCapturedCallerUris.Count
        $sampleIdLink.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent))
        $dmrUri=if($script:renderCapturedCallerUris.Count -gt $dmrStart){[string]$script:renderCapturedCallerUris[$script:renderCapturedCallerUris.Count-1]}else{''}
        $callerIdentitySamples[[string]$sample.key]=[pscustomobject][ordered]@{
            callsign=[string]$sample.callsign;name=[string]$sample.name
            visual_text=@(Get-UiVisualTextValues -Root $sampleArea)
            callsign_uri=$callsignUri
            dmr_id_text=([System.Windows.Documents.TextRange]::new($sampleTextBlocks[1].ContentStart,$sampleTextBlocks[1].ContentEnd)).Text.Trim()
            dmr_profile_uri=$dmrUri
            callsign_link_color=[string]$sampleCallsignLink.Foreground
            dmr_link_color=[string]$sampleIdLink.Foreground
        }
    }
    $script:callIdentityCache['460997']=$savedCallerIdentity
    [void]$script:uiTestHooks.Remove('OpenUri')
    if ($hadRenderOpenUri) { $script:uiTestHooks['OpenUri']=$savedRenderOpenUri }
    $script:renderCapturedCallerUris=$null
    Update-UiChannelDisplays
    Invoke-UiDispatcherPriority -Priority ([System.Windows.Threading.DispatcherPriority]::Render)
    $channelCardsEvidence=@($script:mainWindow.FindName('ChannelCardsPanel').Children | ForEach-Object {
        if ($_.Tag.blank) {
            $blankCardBounds=(Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $_).actual
            [pscustomobject]@{blank=$true;channel_key='';height=[double]$_.ActualHeight;card_bounds=$blankCardBounds;card_title=$null;card_body_width=0;call_area_width=0;action_area_width=0;action_area_height=0;call_active=$false;call_area_height=0;call_area_bounds=$null;action_area_bounds=$null;action_count=0;buttons=@();buttons_bounds=@();text=@()}
        } else {
            $cardBounds=(Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $_).actual
            $titleElement=@($_.Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and [string]$_.Name -ceq 'ChannelCardTitle' }) | Select-Object -First 1
            $titleEvidence=$null
            if ($titleElement) {
                $titleOrigin=$titleElement.TranslatePoint([System.Windows.Point]::new(0,0),$script:mainWindow)
                $titleBounds=Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $titleElement
                $naturalTitle = New-Object System.Windows.Controls.TextBlock
                $naturalTitle.Text = [string]$titleElement.Text
                $naturalTitle.FontFamily = $titleElement.FontFamily
                $naturalTitle.FontSize = $titleElement.FontSize
                $naturalTitle.FontStretch = $titleElement.FontStretch
                $naturalTitle.FontStyle = $titleElement.FontStyle
                $naturalTitle.FontWeight = $titleElement.FontWeight
                $naturalTitle.TextWrapping = $titleElement.TextWrapping
                $naturalTitle.TextTrimming = [Windows.TextTrimming]::None
                $naturalTitle.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
                $titleEvidence=[pscustomobject][ordered]@{
                    name=[string]$titleElement.Name;text=[string]$titleElement.Text;tooltip=[string]$titleElement.ToolTip
                    tag=$titleElement.Tag;x=[double]$titleOrigin.X;y=[double]$titleOrigin.Y
                    width=[double]$titleElement.ActualWidth;height=[double]$titleElement.ActualHeight
                    desired_height=[double]$naturalTitle.DesiredSize.Height
                    text_trimming=[string]$titleElement.TextTrimming;text_wrapping=[string]$titleElement.TextWrapping
                    bounds=$titleBounds.actual
                }
            }
            $callArea=@($_.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Border] -and [string]$_.Tag -ceq 'ChannelCallArea' }) | Select-Object -First 1
            $actions=@($_.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Primitives.UniformGrid] }) | Select-Object -First 1
            $callBounds=(Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $callArea).actual
            $actionBounds=(Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $actions).actual
            $buttonBounds=@(foreach($button in @($actions.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })) {
                $origin=$button.TranslatePoint([System.Windows.Point]::new(0,0),$script:mainWindow)
                [pscustomobject][ordered]@{
                    name=[string]$button.Name;action=$(if($button.Tag){[string]$button.Tag.action}else{''})
                    text=@(Get-UiVisualTextValues -Root $button);x=[double]$origin.X;y=[double]$origin.Y
                    width=[double]$button.ActualWidth;height=[double]$button.ActualHeight;visible=[bool]$button.IsVisible
                }
            })
            [pscustomobject]@{blank=$false;channel_key=[string]$_.Tag.channel_key;height=[double]$_.ActualHeight;min_height=[double]$_.MinHeight;card_bounds=$cardBounds;card_title=$titleEvidence;card_body_width=[double]$_.Child.ActualWidth;call_area_width=[double]$callArea.ActualWidth;action_area_width=[double]$actions.ActualWidth;action_area_height=[double]$actions.ActualHeight;call_active=[bool]$_.Tag.call_active;call_area_height=[double]$callArea.ActualHeight;call_area_bounds=$callBounds;action_area_bounds=$actionBounds;action_count=[int]$actions.Children.Count;buttons=@(Get-UiVisualButtonTexts -Root $_);buttons_bounds=$buttonBounds;text=@(Get-UiVisualTextValues -Root $_)}
        }
    })
    $selectedChannel = Get-UiChannelByKey -Key $script:txChannelKey
    $selectedPresentation = if ($selectedChannel) { Get-UiChannelCardPresentation -Channel $selectedChannel } else { $null }
    $savedActiveRouting = $script:activeRouting
    if ($selectedChannel) {
        $script:activeRouting = [pscustomobject]@{
            media_owner='tx_active'
            tx_target=[pscustomobject]@{ destination_id=[uint64]$selectedChannel.id; kind=[string]$selectedChannel.kind; slot=[uint64]$selectedChannel.slot }
        }
        $activeTxPresentation = Get-UiChannelCardPresentation -Channel $selectedChannel
        $script:activeRouting = $savedActiveRouting
        $selectedKey = Get-UiChannelKey -Channel $selectedChannel
        $savedMutedKeys = $script:mutedChannelKeys
        $script:mutedChannelKeys = @{}; $script:mutedChannelKeys[$selectedKey] = $true
        $mutedSelectedPresentation = Get-UiChannelCardPresentation -Channel $selectedChannel
        $script:mutedChannelKeys = $savedMutedKeys
    } else { $activeTxPresentation=$null; $mutedSelectedPresentation=$null }
    $receiveCard = @($script:mainWindow.FindName('ChannelCardsPanel').Children | Where-Object {
        -not $_.Tag.blank -and $_.Tag.channel_key -ceq 'private:460997:2'
    }) | Select-Object -First 1
    $receiveCallerText = if ($receiveCard) { @(Get-UiVisualTextValues -Root $receiveCard) -join ' · ' } else { '' }
    $staticPanelEvidence = Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $script:mainWindow.FindName('BmStaticGroupPanel')
    $staticPromptControl = $script:mainWindow.FindName('StaticApiRequiredText')
    $staticPromptOverlay = $script:mainWindow.FindName('StaticApiRequiredOverlay')
    $staticPromptEvidence = Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $staticPromptOverlay
    $transientControl = $script:mainWindow.FindName('TransientStatusText')
    $transientEvidence = Get-WpfElementLayoutEvidence -Window $script:mainWindow -Element $transientControl
    $controlNames=@(
        'MainTitleText','ConsoleTop','DashboardPanel','ConnectionConfigPanel','ConnectionConfigTitleText','DailyControlsPanel',
        'BmStatusCard','BmValue','BmRttMetric','BmRttValue','BmLossMetric','BmLossValue','TransientStatusText','StopButton',
        'ConnectionRowSerial','SerialBox','SerialConnectButton','CatOperatingPanel','RadioCatPanel','CatPortBox','CatBaudRateBox',
        'ConnectionRowAudio','AudioDevicePanel','WaveInEndpointBox','WaveOutEndpointBox','VolumeControlsPanel',
        'ConnectionRowIdentity','ConnectionRowServer','ConnectionRowSecrets','ConnectionRowActions','CallsignBox','SourceBox','DeviceNumberBox',
        'MasterPresetBox','MasterPortBox','MasterBox','BmApiKeyBox','PasswordBox',
        'ConnectButton','SaveSettingsButton','RefreshDevicesButton',
        'ChannelConsolePanel','ChannelCardsScroll','ChannelCardsPanel','ChannelPageNav',
        'ChannelPagePreviousButton','ChannelPageText','ChannelPageNextButton','ChannelIdBox','ChannelKindBox','AddChannelButton',
        'BmStaticGroupPanel','StaticApiRequiredOverlay','StaticApiRequiredText','BmStaticGroupsList','BmStaticGroupSourceValue','BmStaticGroupPagePreviousButton','BmStaticGroupPageText','BmStaticGroupPageNextButton',
        'BmStaticGroupIdBox','AddBmStaticGroupButton','RefreshBmStaticGroupsButton','RemoveBmStaticGroupButton',
        'RadioDetailsExpander','CallHistoryList','CallHistoryPagePreviousButton','CallHistoryPageText','CallHistoryPageNextButton','SetHistoryCallTargetButton',
        'CatObservedPanel','CatObservedMainModeText','CatObservedFrequencyText','CatObservedPowerText','CatModeCaptionText','CatFrequencyCaptionText','CatPowerCaptionText',
        'CatMainModeBox','CatMainFrequencyMHzBox','CatPowerBox','ApplyCatSettingsButton',
        'PlaybackGainValueText','TransmitGainValueText','PlaybackGainSlider','TransmitGainSlider'
    )
    $layout=[pscustomobject][ordered]@{
        render_only=$true; work_area_width=$script:workAreaWidth; work_area_height=$script:workAreaHeight
        max_window_width=$script:maxWindowWidth; max_window_height=$script:maxWindowHeight
        main=(Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames $controlNames)
        settings=(Get-WpfWindowLayoutInfo -Window $settings -ControlNames @('CancelSettingsButton'))
        combo_contrast=@($comboContrast)
        combo_interaction=[pscustomobject][ordered]@{cat_port=$catPortProbe}
        caller_identity_samples=[pscustomobject]$callerIdentitySamples
        channel_cards=@($script:channels | ForEach-Object { [pscustomobject]@{key=(Get-UiChannelKey -Channel $_);title=('{0} {1}' -f $_.kind,$_.id)} })
        channel_card_layout=$channelCardsEvidence;channel_list_present=($null -ne $script:mainWindow.FindName('ChannelListPanel'))
        channel_state=[pscustomobject][ordered]@{
            selected_tx_background=[string]$selectedPresentation.background;selected_tx_border=[string]$selectedPresentation.border
            active_tx_background=[string]$activeTxPresentation.background;active_tx_border=[string]$activeTxPresentation.border
            muted_selected_background=[string]$mutedSelectedPresentation.background;receive_caller_text=$receiveCallerText
        }
        page_navigation=[pscustomobject][ordered]@{visible=$script:mainWindow.FindName('ChannelPageNav').IsVisible;text=$script:mainWindow.FindName('ChannelPageText').Text;slot_count=$script:mainWindow.FindName('ChannelCardsPanel').Children.Count}
        history_count=$script:callHistoryModel.Count;history_visible_count=@((Get-UiControl 'CallHistoryList').Items).Count
        history_page_text=$script:mainWindow.FindName('CallHistoryPageText').Text;history_page_probe=$historyPageProbe
        bm_static_group_count=@($script:bmManagementGroups).Count;bm_static_group_visible_count=@($script:mainWindow.FindName('BmStaticGroupsList').Items).Count
        bm_static_group_page_text=$script:mainWindow.FindName('BmStaticGroupPageText').Text
        bm_static_group_page_probe=[pscustomobject][ordered]@{first_page_count=$bmStaticFirstPageCount;first_page_text=$bmStaticFirstPageText;second_page_count=$bmStaticSecondPageCount;second_page_text=$bmStaticSecondPageText}
        bm_static_group_text=$bmStaticGroupTexts
        bm_static_group_panel=[pscustomobject][ordered]@{visible=[bool]$script:mainWindow.FindName('BmStaticGroupPanel').IsVisible;bounds=$staticPanelEvidence.actual}
        static_api_required=[pscustomobject][ordered]@{text=[string]$staticPromptControl.Text;visible=[bool]$staticPromptOverlay.IsVisible;bounds=$staticPromptEvidence.actual}
        transient_status=[pscustomobject][ordered]@{text=[string]$transientControl.Text;visible=[bool]$transientControl.IsVisible;bounds=$transientEvidence.actual}
        bm_loss_valid=[bool]$script:bmLossValid
        caller_card_text=@(Get-UiVisualTextValues -Root (Get-UiControl 'ChannelCardsPanel'))
        favorites_present=$false; transmit_enabled_control_present=$false; stop_bits_control_present=($null -ne $script:mainWindow.FindName('CatStopBitsBox'))
        ui_test_config_path=$script:portableConfigPath
    }
    [System.IO.File]::WriteAllText((Join-Path $renderDirectory 'layout-info.json'),(ConvertTo-Json -InputObject $layout -Depth 6),(New-Object System.Text.UTF8Encoding($false)))
    if ($settings.IsVisible) { $settings.Close() }; $script:mainWindow.Close()
    return
}

[void]$script:application.Run($script:mainWindow)
$script:uiTimer.Stop()
Clear-UiSessionTemp | Out-Null
if ($script:statusStream) { $script:statusStream.Dispose() }
if ($script:supervisor) { $script:supervisor.Dispose() }
if ($script:preparePowerShell -and -not $script:abandonPreparationAtShutdown) { $script:preparePowerShell.Dispose() }
