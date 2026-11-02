[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

function Assert-RadioUi {
    param([bool]$Condition,[string]$Message)
    $script:radioUiAssertionCount++
    if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$mainXamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
$xamlPath = Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'
$radioCatUiPath = Join-Path $repoRoot 'ui\windows\RadioCatUi.ps1'
$portableConfigModulePath = Join-Path $repoRoot 'ui\windows\PortableConfig.psm1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$parseErrors)
Assert-RadioUi ($parseErrors.Count -eq 0) 'bridge-ui.ps1 无法解析。'
$catTokens = $null
$catParseErrors = $null
$catAst = [System.Management.Automation.Language.Parser]::ParseFile($radioCatUiPath,[ref]$catTokens,[ref]$catParseErrors)
Assert-RadioUi ($catParseErrors.Count -eq 0) 'RadioCatUi.ps1 无法解析。'
$definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true)
$catDefinitions = $catAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true)
Invoke-Expression ((@($definitions) + @($catDefinitions) | ForEach-Object { $_.Extent.Text }) -join "`r`n")
$script:productionStartBridgeRun = (Get-Command -Name Start-BridgeRun -CommandType Function).ScriptBlock
Import-Module -Name (Join-Path $repoRoot 'tools\bridge-user-config.psm1') -Force
Import-Module -Name $portableConfigModulePath -Force
$script:productionRejectedReadbackValidator = (Get-Command Test-UiRadioCatRejectedPowerReadback).ScriptBlock
$script:radioCatRejectedPowerReadbackInput = $null
$script:radioCatRejectedPowerReadbackValid = $false
function Test-UiRadioCatRejectedPowerReadback {
    param([Parameter(Mandatory=$true)][object]$Result,[Parameter(Mandatory=$true)][string]$ExpectedPort)
    $script:radioCatRejectedPowerReadbackInput = $Result
    $script:radioCatRejectedPowerReadbackValid = [bool](& $script:productionRejectedReadbackValidator -Result $Result -ExpectedPort $ExpectedPort)
    return $script:radioCatRejectedPowerReadbackValid
}

$script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-r116-ui-cat-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:testRoot)
$script:radioControlPreferencesPath = ''
$script:portableConfigDirectory = $script:testRoot
$script:portableConfigPath = Join-Path $script:testRoot 'config.json'
$script:profilePath = Join-Path $script:testRoot 'connection-profile.json'
$script:audioSettingsPath = Join-Path $script:testRoot 'audio-settings.json'
$script:passwordPointerPath = Join-Path $script:testRoot 'password-path.txt'
$script:mainXamlPath = $mainXamlPath
$script:settingsXamlPath = $xamlPath
$script:radioCatModulePath = Join-Path $script:testRoot 'RadioCat.psm1'
$script:radioCatLogPath = Join-Path $script:testRoot 'operations.log'
$script:radioUiAssertionCount = 0
$script:maxWindowWidth = 1280
$script:maxWindowHeight = 900
$script:RenderOnly = $true
$global:RenderOnly = $true
$script:radioCatModuleAvailable = $true
$script:radioControlPreferencesError = ''
$script:deviceDiscoveryState = 'not_started'
$script:deviceDiscoveryPowerShell = $null
$script:deviceAudioQuery = $null
$script:deviceCatalog = $null
$script:mainWindow = $null
$script:supervisor = $null
$script:latestStatus = $null
$script:lastStatusUtc = [DateTime]::UtcNow
$script:activeHriPortName = 'COM5'
$script:activeProfile = $null
$script:effectiveProfile = $null
$script:storedProfile = $null
$script:activeRouting = $null
$script:pendingCallTarget = $null
$script:routingDraftPreservedAfterTimeout = $false
$script:routingDraftAfterTimeout = $null
$script:profileEditable = $true
$script:profileWriteAllowed = $true
$script:radioCatOperationKind = ''
$script:radioCatOperationPowerShell = $null
$script:radioCatOperationAsync = $null
$script:radioCatOperationStopAsync = $null
$script:radioCatOperationCancelled = $false
$script:radioCatOperationStartedUtc = [DateTime]::MinValue
$script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
$script:radioCatObserved = $null
$script:radioCatResult = $null
$script:radioCatObservedConnectionKey = ''
$script:radioCatObservedPortName = ''
$script:radioModeApplyAfterStop = $null
$script:radioModePreviousHriPortName = ''
$script:stopTask = $null
$script:closingAfterStop = $false
$script:reconnectAfterStop = $false
$script:allowWindowClose = $false
$script:radioCatCloseMainAfterOperation = $false
$script:radioCatCloseSettingsAfterOperation = $false
$script:testStartBridgeRunCalls = 0
$script:testUiEvents = New-Object 'System.Collections.Generic.List[string]'

$testConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
$testConfig.connection.callsign = 'N0TEST'
$testConfig.connection.gateway_id = [uint64]12345
$testConfig.connection.source_id = [uint64]123456
$testConfig.devices.cat_port = 'COM11'
$testConfig.devices.cat_baud_rate = 38400
$testConfig.devices.cat_stop_bits = 'Two'
$testConfig.devices.desired_power_watts = 40
$null = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $testConfig
[System.IO.File]::WriteAllText($script:radioCatLogPath,'',(New-Object System.Text.UTF8Encoding($false)))

$fakeModule = @'
function Invoke-Ftx1CatOperation {
    [CmdletBinding()]
    param([string]$Operation,[string]$PortName,[string]$PortRole,[string]$HriPortName,[int]$BaudRate,[string]$StopBits,[int]$TimeoutMs,[int]$PowerWatts,[string]$Side,[string]$Mode,[long]$FrequencyHz)
    $log = $env:WIREX_R116_UI_CAT_LOG
    [System.IO.File]::AppendAllText($log,('BEGIN|' + $Operation + "`n"),(New-Object System.Text.UTF8Encoding($false)))
    try {
        if ($env:WIREX_R116_UI_CAT_DELAY -ceq $Operation) {
            $delayMs = 0
            [void][int]::TryParse([string]$env:WIREX_R116_UI_CAT_DELAY_MS,[ref]$delayMs)
            if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs } else { Start-Sleep -Seconds 12 }
        }
        $argumentLine = 'ARGS|{0}|Port={1}|Role={2}|HRI={3}|Baud={4}|StopBits={5}|Side={6}|Mode={7}|FrequencyHz={8}|PowerWatts={9}' -f `
            $Operation,$PortName,$PortRole,$HriPortName,$BaudRate,$StopBits,$Side,$Mode,$FrequencyHz,$PowerWatts
        [System.IO.File]::AppendAllText($log,($argumentLine + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        if ($Operation -ceq 'setPower') { [System.IO.File]::AppendAllText($log,('WRITE|' + $Operation + "`n"),(New-Object System.Text.UTF8Encoding($false))) }
        $source = 'CAT test transport'
        $now = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $path = if ($Operation -ceq 'setPower') { 'FieldHead' } else { [string]$env:WIREX_R116_UI_CAT_PATH }
        if (-not $path) { $path = 'Spa1' }
        $max = if ($path -ceq 'FieldHead') { 10 } else { 50 }
        $powerWattsObserved = if ($Operation -ceq 'setPower' -and $PowerWatts -ge 5 -and $PowerWatts -le $max) { $PowerWatts } elseif ($path -ceq 'FieldHead') { 5 } else { 25 }
        $mainFrequencyHz = [long]123456
        $mainMode = 'FM'
        if ($Operation -ceq 'query') {
            switch ([string]$env:WIREX_R116_UI_CAT_SAMPLE) {
                '1' { $mainFrequencyHz = [long]145100000; $mainMode = 'C4FM-DN' }
                '2' { $mainFrequencyHz = [long]145200000; $mainMode = 'FM-N' }
                '3' { $mainFrequencyHz = [long]145300000; $mainMode = 'C4FM-VW' }
                '4' { $mainFrequencyHz = [long]145400000; $mainMode = 'FM' }
            }
        }
        $identityValue = if ($env:WIREX_R116_UI_CAT_BAD_ID -eq '1') { '9999' } else { '0840' }
        $observed = [ordered]@{
            radio_id = [pscustomobject]@{ value=$identityValue; source=$source; updated_at_utc=$now }
            auto_information_enabled = [pscustomobject]@{ value=$false; source=$source; updated_at_utc=$now }
            tx_state = [pscustomobject]@{ value=[int]0; source=$source; updated_at_utc=$now }
            main_frequency_hz = [pscustomobject]@{ value=$mainFrequencyHz; source=$source; updated_at_utc=$now }
            sub_frequency_hz = [pscustomobject]@{ value=[long]234567; source=$source; updated_at_utc=$now }
            main_mode = [pscustomobject]@{ value=[pscustomobject]@{ side='Main'; side_code='0'; mode_code='4'; mode=$mainMode }; source=$source; updated_at_utc=$now }
            sub_mode = [pscustomobject]@{ value=[pscustomobject]@{ side='Sub'; side_code='1'; mode_code='4'; mode='FM' }; source=$source; updated_at_utc=$now }
            power = [pscustomobject]@{ value=[pscustomobject]@{ path=$path; path_code=$(if ($path -ceq 'FieldHead') { '1' } else { '2' }); watts=$powerWattsObserved }; source=$source; updated_at_utc=$now }
        }
        $status = 'confirmed'
        if ($Operation -ceq 'setPower' -and ($PowerWatts -lt 5 -or $PowerWatts -gt $max)) { $status = 'rejected' }
        if ($env:WIREX_R116_UI_CAT_BAD_ID -eq '1') { $status = 'unknown' }
        $caps = [pscustomobject]@{
            query = [pscustomobject]@{ supported=$true; available=$true }
            set_mode = [pscustomobject]@{ supported=$true; available=$true }
            set_frequency = [pscustomobject]@{ supported=$true; available=$true; target_side='Main'; minimum_hz=[long]30000; maximum_hz=[long]470000000; step_hz=1 }
            set_power = [pscustomobject]@{ supported=$true; available=($status -ceq 'confirmed'); readable=$true; active_path=$path; minimum_watts=5; maximum_watts=$max; step_watts=1; unavailable_reason=$null; value_semantics='CAT setting' }
        }
        return [pscustomobject][ordered]@{
            schema_version=1; operation=$Operation; status=$status; source=$source; port_name=$PortName; port_role='CAT-1'
            started_at_utc=$now; updated_at_utc=$now; desired=$null; prior=$null; observed=[pscustomobject]$observed
            capabilities=$caps; cleanup_status='closed'; error_code=$(if ($status -ceq 'rejected') { 'power_out_of_range' } elseif ($status -ceq 'unknown') { 'identity_mismatch' } else { $null })
            error_message=$(if ($status -ceq 'rejected') { 'FieldHead path rejected requested power.' } elseif ($status -ceq 'unknown') { 'Identity is invalid.' } else { $null })
        }
    } finally {
        [System.IO.File]::AppendAllText($log,('CLEANUP|' + $Operation + "`n"),(New-Object System.Text.UTF8Encoding($false)))
    }
}
Export-ModuleMember -Function Invoke-Ftx1CatOperation
'@
[System.IO.File]::WriteAllText($script:radioCatModulePath,$fakeModule,(New-Object System.Text.UTF8Encoding($true)))
$env:WIREX_R116_UI_CAT_LOG = $script:radioCatLogPath
$env:WIREX_R116_UI_CAT_MODULE_PATH = $script:radioCatModulePath
$script:isolatedUiMode = $true
$script:NoAutoConnect = $false
$script:uiTestHooks = $null
$isolatedConnectBlocked = -not (Connect-UiRadioCatSession -Automatic)
$isolatedOperationBlocked = $false
try { Start-UiRadioCatOperation -Operation query }
catch { $isolatedOperationBlocked = $_.Exception.Message -match '隔离界面禁止' }
Assert-RadioUi ($isolatedConnectBlocked -and $isolatedOperationBlocked -and -not $script:radioCatOperationPowerShell) `
    'RenderOnly式隔离模式没有在串口worker启动前拒绝CAT自动连接和真实操作。'
$script:uiTestHooks = @{ CatOperation = {
    param([object]$Context)
    Import-Module -Name $env:WIREX_R116_UI_CAT_MODULE_PATH -Force
    $operationParameters = $Context.parameters
    Invoke-Ftx1CatOperation @operationParameters
} }
$script:NoAutoConnect = $true
$noAutoConnectBlocksAuto = -not (Connect-UiRadioCatSession -Automatic)
$noAutoConnectAllowsManual = Test-UiRadioCatHardwareAccessAllowed
$script:NoAutoConnect = $false
Assert-RadioUi ($noAutoConnectBlocksAuto -and $noAutoConnectAllowsManual) `
    'NoAutoConnect 应禁止 CAT 自动连接，同时保留 CAT 手动连接所需的真实运行模式。'
Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
Remove-Item Env:\WIREX_R116_UI_CAT_PATH -ErrorAction SilentlyContinue
Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue

# Isolate unrelated profile/audio behavior while exercising the actual WPF load and CAT functions.
function Read-BridgeUserConnectionProfile { param([string]$Path) return $null }
function Read-BridgeAudioSettings { param([string]$Path) return [pscustomobject]@{ RadioPlaybackGainMilli=[uint32]1000; MicTransmitGainMilli=[uint32]16000 } }
function Write-BridgeAudioSettings {
    param([string]$Path,[uint32]$RadioPlaybackGainMilli,[uint32]$MicTransmitGainMilli)
    $record = [pscustomobject]@{ RadioPlaybackGainMilli=$RadioPlaybackGainMilli; MicTransmitGainMilli=$MicTransmitGainMilli }
    [System.IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $record -Depth 3),(New-Object System.Text.UTF8Encoding($false)))
}
function Update-CallTargetChoices { }
function Update-UiPlaybackGainDisplay { param([object]$Record) }
function Get-UiReceiveEditorState {
    param([object]$Profile)
    $result = [pscustomobject]@{ status_name = 'test' }
    return $result
}
function Get-UiProfileMigrationSourceSchema { param([object]$Profile) return $null }
function Copy-UiRxPolicy {
    param([object]$Policy)
    return [pscustomobject][ordered]@{
        group_mode = 'selected'; private_mode = 'disabled'; allow_groups = @(); allow_private_peers = @()
        local_private_routes = @(); blocked_groups = @(); blocked_source_ids = @()
    }
}
function Read-CurrentPasswordPath { return '' }
function Set-GainValueLabel { param([string]$SliderName,[string]$LabelName) }
function Set-SettingsDeviceControls { }
function Set-SettingsPolicyLists { }
function Invalidate-UiDeviceDiscoveryForWindow { param([object]$Window) }
function Set-MainText { param([string]$Name,[string]$Text) }
function Set-MainTargetSummary { param([object]$Profile,[string]$OverallLabel) }
function Set-ConnectionButtonState { }
function Set-OfflineDisplay { param([string]$Reason) }
function Add-UiEvent { param([string]$Text) [void]$script:testUiEvents.Add($Text) }
function Clear-UiIdentityQueryQueue { }
function Update-DynamicGroupControls { }
function Update-UiReceiveMetricsDisplay { param([object]$Record) }
function Set-UiIdentityRowVisibility { param([string]$Row,[System.Windows.Visibility]$Visibility) }
function Update-UiIdentityActionState { }
function Start-BridgeRun {
    param([switch]$BmStartDisconnected)
    $script:testStartBridgeRunCalls++
    $script:testLastBmStartDisconnected=[bool]$BmStartDisconnected
}
function Set-UiControl { param([string]$Name,[object]$Value) }

function New-TestRadioSupervisor {
    param([bool]$HriSerialOpen=$true)
    $source = New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
    $supervisor = [pscustomobject]@{ HasExited=$false; StopSource=$source; DisposeCount=0; StopCallCount=0; Disposed=$false }
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name StopAsync -Value { param([int]$TimeoutMs) $this.StopCallCount++; return $this.StopSource.Task } | Out-Null
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++; $this.Disposed=$true } | Out-Null
    $script:latestStatus = [pscustomobject]@{
        hri_serial_open=$HriSerialOpen; hri_ready=$HriSerialOpen
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    return $supervisor
}
function New-TestBmSupervisor {
    $source=New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
    $supervisor=[pscustomobject]@{
        HasExited=$false; StopSource=$source; StopCallCount=0
        SentCommands=(New-Object 'System.Collections.Generic.List[object]')
    }
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$Parameters='')
        [void]$this.SentCommands.Add([pscustomobject]@{request_id=$RequestId;command=$Command;parameters=$Parameters})
        return $true
    } | Out-Null
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name StopAsync -Value {
        param([int]$TimeoutMs)
        $this.StopCallCount++
        return $this.StopSource.Task
    } | Out-Null
    return $supervisor
}
function New-TestMainWindow {
    $window = Import-WpfWindow -Path $script:mainXamlPath
    $window | Add-Member -NotePropertyName Closed -NotePropertyValue $false
    $window.Add_Closed({ $window.Closed = $true }.GetNewClosure())
    return $window
}
function Restore-TestMainWindow {
    if ($script:mainWindow -and $script:mainWindow -is [System.Windows.Window] -and
        -not [object]::ReferenceEquals($script:mainWindow,$script:testRootMainWindow)) {
        try { $script:mainWindow.Close() } catch { }
    }
    $script:mainWindow = $script:testRootMainWindow
}
function Cancel-SettingsWindow {
    if (-not $script:settingsWindow) { return }
    $script:testClosedSettingsWindow = $script:settingsWindow
    $button = $script:settingsWindow.FindName('CancelSettingsButton')
    if (-not $button) { throw '测试设置窗缺少 CancelSettingsButton。' }
    $args = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
    $button.RaiseEvent($args)
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}
function Complete-TestCatRunspace {
    param([int]$TimeoutMs=3000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:radioCatOperationPowerShell -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($script:radioCatOperationAsync -and $script:radioCatOperationAsync.IsCompleted) {
            [void](Complete-UiRadioCatOperation)
            break
        }
        if ($script:radioCatOperationStopAsync -and $script:radioCatOperationStopAsync.IsCompleted) {
            [void](Complete-UiRadioCatOperation)
            break
        }
        Start-Sleep -Milliseconds 25
    }
    $watch.Stop()
    return $watch.ElapsedMilliseconds
}
function Complete-TestCatActionSequence {
    param([int]$TimeoutMs=5000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:radioCatOperationPowerShell -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = [Math]::Max(100,$TimeoutMs - [int]$watch.ElapsedMilliseconds)
        [void](Complete-TestCatRunspace -TimeoutMs $remaining)
        if ($script:radioCatOperationPowerShell -and $script:radioCatOperationAsync -and -not $script:radioCatOperationAsync.IsCompleted) {
            Start-Sleep -Milliseconds 20
        }
    }
    $watch.Stop()
    return ($null -eq $script:radioCatOperationPowerShell)
}
function Complete-TestBridgeStop {
    $results = @(Complete-BridgeStop)
    if ($results.Count -eq 0) { return $false }
    return [bool]$results[$results.Count - 1]
}
function Get-TestRadioCatLog {
    param([int]$RetryMs=1000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $text = [System.IO.File]::ReadAllText([string]$script:radioCatLogPath)
            $watch.Stop()
            return $text
        } catch [System.IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge $RetryMs) { $watch.Stop(); throw }
            Start-Sleep -Milliseconds 20
        }
    }
}
function Wait-TestRadioCatLog {
    param([Parameter(Mandatory=$true)][string]$Pattern,[int]$TimeoutMs=2000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            if ((Get-TestRadioCatLog) -match $Pattern) { $watch.Stop(); return $true }
        } catch [System.IO.IOException] { }
        Start-Sleep -Milliseconds 20
    }
    $watch.Stop()
    return $false
}
function Wait-TestRadioCatLogCount {
    param([Parameter(Mandatory=$true)][string]$Pattern,[Parameter(Mandatory=$true)][int]$MinimumCount,[int]$TimeoutMs=2000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $count = ([regex]::Matches((Get-TestRadioCatLog),$Pattern)).Count
            if ($count -ge $MinimumCount) { $watch.Stop(); return $true }
        } catch [System.IO.IOException] { }
        Start-Sleep -Milliseconds 20
    }
    $watch.Stop()
    return $false
}

try {
    # CAT controls and preferences now live in MainWindow.xaml and config.json.
    $script:mainWindow = Import-WpfWindow -Path $script:mainXamlPath
    $script:mainWindow.Opacity = 0
    $script:mainWindow.Show()
    $script:channels = @((New-UiChannelRecord -Id 460997 -Kind private -Slot 2))
    $script:txChannelKey = 'private:460997:2'
    $script:mutedChannelKeys = @{}
    $script:pendingRoutingMutation = $null
    $script:pendingChannelMutation = $null
    $script:pendingChannelStopMutation = $null
    $script:routingMutationFence = $false
    $script:supervisor = $null
    $script:controlConfirmed = $false
    $script:routingCapabilities = $null
    $script:activeRouting = $null
    $script:portableConfigPath = [System.IO.Path]::GetFullPath($script:portableConfigPath)
    $script:radioControlPreferencesPath = ''
    $script:bmServerSelectionPreferenceId = 'bm-china-4602'
    Import-UiPortableConfig | Out-Null
    Apply-UiPortableConfigToControls
    $script:radioControlPreferences = [pscustomobject][ordered]@{
        schema_version=1; cat_port=[string]$script:portableConfig.devices.cat_port
        baud_rate=[int]$script:portableConfig.devices.cat_baud_rate; stop_bits='Two'
        desired_power_watts=[int]$script:portableConfig.devices.desired_power_watts
    }
    [void](Initialize-SettingsWindow)
    $script:mainWindow.Hide()
    $script:mainWindow.Opacity = 1
    $script:testRootMainWindow = $script:mainWindow
    Initialize-UiRadioCatController
    Set-UiRadioCatDeviceControls
    $slider = Get-SettingsControl 'CatPowerSlider'
    Assert-RadioUi ([int]$slider.Value -eq 40) '主窗没有载入隔离 config.json 中的 40 W。'
    Assert-RadioUi ($script:radioControlPreferencesPath -ceq '' -and -not [System.IO.File]::Exists((Join-Path $script:testRoot 'radio-control-preferences.json'))) `
        'CAT 设置仍不得创建独立偏好文件。'
    Assert-RadioUi (-not $script:radioCatPowerPreferenceDirty -and [int]$script:radioControlPreferences.desired_power_watts -eq 40) '打开设置窗时回填滑块错误标记了用户修改。'

    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{
        serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic Enhanced'; CatMatchRank=100; IsHri=$false },[pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI'; CatMatchRank=0; IsHri=$true })
        hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' })
        wave_inputs=@(); wave_outputs=@()
    }
    Set-UiRadioCatDeviceControls
    Assert-RadioUi ((Get-UiRadioCatSelectedPort) -ceq 'COM11') 'CAT 候选端口未使用已枚举的 COM11。'
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow

    # A real query runs in the UI-created PowerShell worker and updates the WPF controls from its result.
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '350'
    Start-UiRadioCatOperation -Operation query
    $concurrencyRejected = $false
    try { Start-UiRadioCatOperation -Operation query } catch { $concurrencyRejected = $_.Exception.Message -match '另一项 CAT-1 操作' }
    Assert-RadioUi $concurrencyRejected 'UI 没有阻止第二个并发 CAT 查询。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed') 'fake CAT query 没有通过 UI 完成流程。'
    Assert-RadioUi ([int]$slider.Maximum -eq 10 -and [double]$slider.Value -ge 5 -and [double]$slider.Value -le 10 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 40 -and -not $script:radioCatPowerPreferenceDirty -and
        -not $script:radioCatPowerNeedsUserChoice -and $null -eq $script:radioCatEditDraft.power) ('FieldHead 首读应显示实测值、保留 40 W 偏好，并且不把它当作待发草稿。 max={0}, value={1}, target={2}, dirty={3}, needsChoice={4}, draft={5}' -f
        $slider.Maximum,$slider.Value,$script:radioControlPreferences.desired_power_watts,$script:radioCatPowerPreferenceDirty,$script:radioCatPowerNeedsUserChoice,$script:radioCatEditDraft.power)
    Assert-RadioUi ([int]$script:radioControlPreferences.desired_power_watts -eq 40 -and -not $script:radioCatPowerPreferenceDirty -and
        $null -eq $script:radioCatEditDraft.power -and -not (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '无草稿首读不得覆盖 40 W 偏好或启用功率写入。'

    # A connected CAT session keeps its controls and values stable across completed poll cycles.
    $modeControl = Get-SettingsControl 'CatMainModeBox'
    $frequencyControl = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $slider = Get-SettingsControl 'CatPowerSlider'
    $observedPanel = Get-SettingsControl 'CatObservedPanel'
    $operatingPanel = Get-SettingsControl 'CatOperatingPanel'
    $powerButton = Get-SettingsControl 'ApplyCatPowerButton'
    $script:actionEnableChanged = 0
    foreach ($name in @('ApplyCatModeButton','ApplyCatFrequencyButton','ApplyCatPowerButton')) {
        (Get-SettingsControl $name).Add_IsEnabledChanged({ $script:actionEnableChanged++ })
    }
    $modeControl.Add_IsEnabledChanged({ $script:testModeEnableChanges++ })
    $frequencyControl.Add_IsEnabledChanged({ $script:testFrequencyEnableChanges++ })
    $slider.Add_IsEnabledChanged({ $script:testSliderEnableChanges++ })
    $slider.Add_ValueChanged({ $script:testSliderValueChanges++ })
    $script:testModeEnableChanges = 0
    $script:testFrequencyEnableChanges = 0
    $script:testSliderEnableChanges = 0
    $script:testSliderValueChanges = 0
    $script:actionEnableChanged = 0
    $script:radioCatSessionRequested = $false
    $script:radioCatPollingActive = $false
    $script:radioCatManualDisconnect = $false
    $catConnectStarted = Connect-UiRadioCatSession
    Assert-RadioUi ($script:radioCatSessionRequested -and $script:radioCatPollingActive -and
        $script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'query' -and $catConnectStarted) 'CAT会话控制没有启动CAT会话和首读。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ((Get-UiRadioCatSessionState).requested -and (Get-UiRadioCatSessionState).connected -and
        (Get-UiRadioCatSessionState).polling -and -not $script:supervisor) 'CAT首读成功后没有保持独立会话，或启动了HRI核心。'
    Assert-RadioUi ((Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11') -and
        -not (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM5')) 'HRI冲突检查没有区分CAT会话实际占用的COM11与不同COM5。'
    [void](Set-UiRadioCatDraft -Field mode -Value 'C4FM-DN')
    $modeControl.SelectedItem = @($modeControl.Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    $frequencyControl.Text = '145.600'
    $slider.Value = 6
    $script:testSliderValueChanges = 0
    $script:radioCatEditDraft.power = 6
    Update-UiRadioCatControls
    $actionEnableChanged = 0
    $script:testReadoutTextChanges = 0
    $script:testSliderRangeChanges = 0
    $script:testModeSelectionChanges = 0
    $script:testFrequencyTextChanges = 0
    $script:testModeEnableChanges = 0
    $script:testFrequencyEnableChanges = 0
    $script:testSliderEnableChanges = 0
    $script:testSliderValueChanges = 0
    $snapshotNames = @('RadioCatPanel','CatOperatingPanel','CatObservedPanel','CatSessionStatusText','CatPortBox','CatBaudRateBox','CatMainModeBox',
        'CatMainFrequencyMHzBox','CatPowerSlider','ApplyCatModeButton','ApplyCatFrequencyButton','ApplyCatPowerButton')
    function Get-TestRadioCatSnapshot {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($name in $snapshotNames) {
            $control = Get-SettingsControl $name
            $parts.Add(('{0}|{1}|{2}' -f $name,[string]$control.IsEnabled,[string]$control.Visibility))
            if ($control -is [System.Windows.Controls.TextBlock] -or $control -is [System.Windows.Controls.TextBox]) { $parts.Add([string]$control.Text) }
            if ($control -is [System.Windows.Controls.Button]) { $parts.Add([string]$control.Content) }
            if ($control -is [System.Windows.Controls.ComboBox]) {
                $selectedValue = if ($control.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$control.SelectedItem.Tag } else { '' }
                $parts.Add(('selected={0};text={1}' -f $selectedValue,[string]$control.Text))
            }
            if ($control -is [System.Windows.Controls.Primitives.RangeBase]) {
                $parts.Add(('min={0};max={1};value={2}' -f [double]$control.Minimum,[double]$control.Maximum,[double]$control.Value))
            }
        }
        $parts.Add(('draft={0}|{1}|{2};session={3};generation={4}' -f $script:radioCatEditDraft.mode,$script:radioCatEditDraft.frequency,
            $script:radioCatEditDraft.power,$script:radioCatSessionState,$script:radioCatSessionGeneration))
        return ($parts -join "`n")
    }
    $readoutControls = @('CatObservedMainModeText','CatObservedFrequencyText','CatObservedPowerText') | ForEach-Object { Get-SettingsControl $_ }
    $script:testReadoutTextChanges = 0
    $textDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.TextBlock]::TextProperty,[System.Windows.Controls.TextBlock])
    foreach ($readout in $readoutControls) { $textDescriptor.AddValueChanged($readout,[System.EventHandler]{ $script:testReadoutTextChanges++ }) }
    $script:testSliderRangeChanges = 0
    $rangeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.Primitives.RangeBase]::MaximumProperty,[System.Windows.Controls.Primitives.RangeBase])
    $rangeDescriptor.AddValueChanged($slider,[System.EventHandler]{ $script:testSliderRangeChanges++ })
    $script:testModeSelectionChanges = 0
    $modeControl.Add_SelectionChanged({ $script:testModeSelectionChanges++ })
    $script:testFrequencyTextChanges = 0
    $frequencyControl.Add_TextChanged({ $script:testFrequencyTextChanges++ })
    $baselineSnapshot = Get-TestRadioCatSnapshot
    $expectedReadoutChangeTotal = 0
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '80'
    for ($pollCycle = 0; $pollCycle -lt 4; $pollCycle++) {
        $sampleNumber = $pollCycle + 1
        $env:WIREX_R116_UI_CAT_SAMPLE = [string]$sampleNumber
        $previousModeReadout = [string](Get-SettingsControl 'CatObservedMainModeText').Text
        $previousFrequencyReadout = [string](Get-SettingsControl 'CatObservedFrequencyText').Text
        $readoutChangeCountBefore = [int]$script:testReadoutTextChanges
        $startedPoll = Invoke-UiRadioCatPollTick -Force
        Assert-RadioUi ($startedPoll -and $script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'query') ('第{0}轮CAT query没有保持为唯一在途操作。' -f ($pollCycle + 1))
        Assert-RadioUi ((Get-TestRadioCatSnapshot) -ceq $baselineSnapshot) ('第{0}轮CAT query在途时读值、编辑器、滑块或action按钮发生变化。' -f ($pollCycle + 1))
        [void](Update-UiRadioCatControls)
        [void](Update-UiRadioCatObservationDisplay)
        Assert-RadioUi ((Get-TestRadioCatSnapshot) -ceq $baselineSnapshot) ('第{0}轮重复dispatcher刷新改变了CAT控件属性。' -f ($pollCycle + 1))
        [void](Complete-TestCatRunspace -TimeoutMs 3000)
        $expectedSample = switch ($sampleNumber) {
            1 { [pscustomobject]@{ mode='C4FM-DN'; frequency_hz=[long]145100000 } }
            2 { [pscustomobject]@{ mode='FM-N'; frequency_hz=[long]145200000 } }
            3 { [pscustomobject]@{ mode='C4FM-VW'; frequency_hz=[long]145300000 } }
            4 { [pscustomobject]@{ mode='FM'; frequency_hz=[long]145400000 } }
        }
        $expectedFrequencyReadout = (Format-UiFrequencyMHz -FrequencyHz ([long]$expectedSample.frequency_hz)) + ' MHz'
        $readoutChangesExpected = [int]($previousModeReadout -cne [string]$expectedSample.mode) +
            [int]($previousFrequencyReadout -cne $expectedFrequencyReadout)
        $readoutChangeCountDelta = [int]$script:testReadoutTextChanges - $readoutChangeCountBefore
        $expectedReadoutChangeTotal += $readoutChangesExpected
        Assert-RadioUi ((Get-TestRadioCatSnapshot) -ceq $baselineSnapshot -and
            [string](Get-SettingsControl 'CatObservedMainModeText').Text -ceq [string]$expectedSample.mode -and
            [string](Get-SettingsControl 'CatObservedFrequencyText').Text -ceq $expectedFrequencyReadout -and
            [string](Get-SettingsControl 'CatObservedPowerText').Text -ceq '5 W' -and
            $readoutChangeCountDelta -eq $readoutChangesExpected) `
            ('第{0}轮CAT worker完成后应只把新观测写到读数一次，并保持编辑器、滑块、状态文案、range和action按钮稳定。 readoutDelta={1}/{2}, mode={3}, frequency={4}' -f `
                $sampleNumber,$readoutChangeCountDelta,$readoutChangesExpected,[string](Get-SettingsControl 'CatObservedMainModeText').Text,
                [string](Get-SettingsControl 'CatObservedFrequencyText').Text)
        $baselineSnapshot = Get-TestRadioCatSnapshot
    }
    Assert-RadioUi ($script:actionEnableChanged -eq 0 -and $script:testReadoutTextChanges -eq $expectedReadoutChangeTotal -and $script:testSliderRangeChanges -eq 0 -and
        $script:testModeSelectionChanges -eq 0 -and $script:testFrequencyTextChanges -eq 0 -and
        $script:testModeEnableChanges -eq 0 -and $script:testFrequencyEnableChanges -eq 0 -and
        $script:testSliderEnableChanges -eq 0 -and $script:testSliderValueChanges -eq 0) `
        '多轮CAT query重复写入了观测文字、滑块range/value、editor选中项或action按钮状态。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and
        [int]$slider.Value -eq 6 -and [int]$script:radioCatEditDraft.power -eq 6 -and $powerButton.IsEnabled) `
        '周期 query 完成后没有刷新确认状态，或覆盖用户保留的功率草稿。'

    # A user write clicked during a poll is frozen, then starts exactly once after the query result is validated.
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '400'
    [void](Invoke-UiRadioCatPollTick -Force)
    $writeCountBeforeQueuedAction = ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count
    $powerClick = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$powerButton)
    $powerButton.RaiseEvent($powerClick)
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setPower' -and
        [int]$script:radioCatQueuedAction.power_watts -eq 6 -and [string]$script:radioCatQueuedAction.port_name -ceq 'COM11' -and
        [int]$script:radioCatQueuedAction.generation -eq [int]$script:radioCatSessionGeneration -and
        ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count -eq $writeCountBeforeQueuedAction) `
        'query在途时的功率按钮没有冻结唯一动作或提前写入。'
    Assert-RadioUi (-not $powerButton.IsEnabled -and -not (Get-SettingsControl 'ApplyCatModeButton').IsEnabled -and
        -not (Get-SettingsControl 'ApplyCatFrequencyButton').IsEnabled) '显式动作待执行期间没有冻结其他写按钮。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'WRITE\|setPower' -MinimumCount ($writeCountBeforeQueuedAction + 1) -TimeoutMs 1500) `
        'fresh query通过UI授权后，fake CAT worker没有发送唯一功率写入。'
    $queuedWritesAfterQuery = ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count
    Assert-RadioUi ($script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'setPower' -and
        $null -eq $script:radioCatQueuedAction -and $queuedWritesAfterQuery -eq ($writeCountBeforeQueuedAction + 1)) `
        ('fresh query确认后没有只执行一次冻结的功率写入。 operation={0}, queued={1}, writes={2}/{3}, status={4}, session={5}, generation={6}/{7}' -f `
            [string]$script:radioCatOperationKind,[bool]$script:radioCatQueuedAction,$queuedWritesAfterQuery,$writeCountBeforeQueuedAction,
            [string]$script:radioCatLastOperationStatus,[string]$script:radioCatSessionState,[int]$script:radioCatOperationSessionGeneration,
            [int]$script:radioCatSessionGeneration)
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and $null -eq $script:radioCatEditDraft.power) `
        '排队功率设置没有按确认读回清除草稿。'
    Set-UiRadioCatDraft -Field power -Value $null
    Set-UiRadioCatDraft -Field mode -Value $null
    Set-UiRadioCatDraft -Field frequency -Value $null
    [void](Update-UiRadioCatControls)

    # Disconnect cancels only CAT, latches against implicit reconnect, and an explicit Connect starts a new generation.
    $generationBeforeDisconnect = [int]$script:radioCatSessionGeneration
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    Assert-RadioUi ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell) 'CAT disconnect test did not start its in-flight query.'
    Assert-RadioUi (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11') 'CAT in-flight session did not expose its port to the HRI conflict check.'
    $script:radioCatEditDraft.power = 6
    Invoke-UiRadioCatAction -Operation setPower
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setPower' -and
        [int]$script:radioCatQueuedAction.power_watts -eq 6) 'CAT disconnect test did not freeze the explicit power action behind its in-flight query.'
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi (-not $script:radioCatSessionRequested -and -not $script:radioCatPollingActive -and
        $script:radioCatManualDisconnect -and $script:radioCatOperationCancelled -and $script:radioCatOperationStopAsync -and
        $null -eq $script:radioCatQueuedAction -and
        [int]$script:radioCatSessionGeneration -gt $generationBeforeDisconnect -and -not $script:supervisor) `
        'CAT断开没有撤销请求和单槽动作、取消worker、记录手动断开或隔离于核心生命周期。'
    Assert-RadioUi (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11') 'manual disconnect stopped protecting the CAT worker port before worker cleanup finished.'
    Assert-RadioUi (-not (Connect-UiRadioCatSession -Automatic) -and -not $script:radioCatSessionRequested) `
        '手动断开后auto reconnect仍能重新启动CAT。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and -not $script:radioCatSessionRequested -and
        [string]$script:radioCatSessionState -ceq 'disconnected' -and $script:radioCatResult -eq $null) `
        'CAT断开后仍有worker、旧授权结果或轮询请求。'
    Assert-RadioUi (-not (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11')) 'CAT port remained reserved after disconnect worker cleanup completed.'
    [void](Connect-UiRadioCatSession)
    Assert-RadioUi ($script:radioCatSessionRequested -and -not $script:radioCatManualDisconnect -and
        $script:radioCatOperationPowerShell -and [int]$script:radioCatOperationSessionGeneration -gt $generationBeforeDisconnect) `
        '用户明确再次连接没有解除本次应用手动断开锁存或开始新代CAT查询。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ((Get-UiRadioCatSessionState).connected -and (Get-UiRadioCatSessionState).polling) `
        '显式再次连接没有恢复CAT查询会话。'
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi (-not (Get-UiRadioCatSessionState).requested -and $script:radioCatManualDisconnect -and
        -not $script:radioCatOperationPowerShell) '后续单项 CAT 操作测试没有通过用户断开结束周期会话。'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (-not (Get-UiRadioCatSessionState).requested -and $script:radioCatResult -and
        [string]$script:radioCatResult.operation -ceq 'query') 'CAT断开后的单次显式读取没有独立完成。'

    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ callsign=''; gateway_id=''; source_id=''; master=''; master_port=''; color_code=1 }; tx_target=[pscustomobject]@{ destination_id=91; kind='group'; slot=2 }; rx_policy=$null; transmit_enabled=$true }
    $script:portableConfig.ui['r121_unknown_probe'] = [ordered]@{ keep='synthetic-unknown-field' }
    $scalarTagCombo = New-Object System.Windows.Controls.ComboBox
    $scalarTagItem = New-Object System.Windows.Controls.ComboBoxItem
    $scalarTagItem.Tag = 'synthetic-scalar-tag'
    [void]$scalarTagCombo.Items.Add($scalarTagItem)
    $scalarTagCombo.SelectedItem = $scalarTagItem
    $rawObjectCombo = New-Object System.Windows.Controls.ComboBox
    [void]$rawObjectCombo.Items.Add([pscustomobject]@{ Value='synthetic-raw-object-value' })
    $rawObjectCombo.SelectedIndex = 0
    Assert-RadioUi ((Get-UiComboValue -Combo $scalarTagCombo) -ceq 'synthetic-scalar-tag' -and
        (Get-UiComboValue -Combo $rawObjectCombo) -ceq 'synthetic-raw-object-value') `
        'ComboBox 字符串 Tag 或直接对象 Value 未读取为稳定值。'
    $syntheticHriPorts = @([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI'; IsHri=$true })
    $syntheticSerialOptions = Get-UiSerialOptions -AllPorts $syntheticHriPorts -HriPorts $syntheticHriPorts -SavedPort 'auto'
    $serialCombo = Get-UiControl 'SerialBox'
    Set-UiDeviceComboOptions -Combo $serialCombo -Options $syntheticSerialOptions.Items -SelectedValue 'auto'
    Assert-RadioUi ((Set-UiComboValue -Combo $serialCombo -Value 'auto') -and (Get-UiComboValue -Combo $serialCombo) -ceq 'auto') `
        '设备选项对象 Tag 未能将 auto 值回写到串口 ComboBox。'
    Assert-RadioUi ((Set-UiComboValue -Combo $serialCombo -Value 'COM5') -and (Get-UiComboValue -Combo $serialCombo) -ceq 'COM5') `
        '设备选项对象 Tag 未能将 COM5 值回写到串口 ComboBox。'
    $syntheticInputOptions = @((New-UiDeviceOption -Label 'Synthetic input' -Value 'synthetic-input-1' -IsAvailable $true -Kind 'input'))
    $syntheticOutputOptions = @((New-UiDeviceOption -Label 'Synthetic output' -Value 'synthetic-output-1' -IsAvailable $true -Kind 'output'))
    Set-UiDeviceComboOptions -Combo (Get-UiControl 'WaveInEndpointBox') -Options $syntheticInputOptions -SelectedValue 'synthetic-input-1'
    Set-UiDeviceComboOptions -Combo (Get-UiControl 'WaveOutEndpointBox') -Options $syntheticOutputOptions -SelectedValue 'synthetic-output-1'
    Assert-RadioUi ((Get-UiComboValue -Combo (Get-UiControl 'WaveInEndpointBox')) -ceq 'synthetic-input-1' -and
        (Get-UiComboValue -Combo (Get-UiControl 'WaveOutEndpointBox')) -ceq 'synthetic-output-1') `
        '音频设备选项对象 Tag 未能读取稳定值。'
    $hriSaveValue = Get-UiComboValue -Combo (Get-UiControl 'SerialBox')
    $reproducedSaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedDeviceValues = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ($reproducedSaveSucceeded -and $hriSaveValue -ceq 'COM5' -and
        $savedDeviceValues.devices.hri_port -ceq 'COM5' -and
        $savedDeviceValues.devices.wave_in_endpoint_id -ceq 'synthetic-input-1' -and
        $savedDeviceValues.devices.wave_out_endpoint_id -ceq 'synthetic-output-1' -and
        $savedDeviceValues.ui.r121_unknown_probe.keep -ceq 'synthetic-unknown-field') `
        ('R121 fake 配置没有保存稳定设备值或未知字段：success={0}, hri={1}, in={2}, out={3}, unknown={4}' -f `
            $reproducedSaveSucceeded,$savedDeviceValues.devices.hri_port,$savedDeviceValues.devices.wave_in_endpoint_id,
            $savedDeviceValues.devices.wave_out_endpoint_id,$savedDeviceValues.ui.r121_unknown_probe.keep)
    $script:portableConfig=Get-WirexPortableConfig -Path $script:portableConfigPath
    [void](Import-UiPortableConfig)
    Apply-UiPortableConfigToControls
    Assert-RadioUi ((Get-UiComboValue -Combo (Get-UiControl 'SerialBox')) -ceq 'COM5' -and
        (Get-UiComboValue -Combo (Get-UiControl 'WaveInEndpointBox')) -ceq 'synthetic-input-1' -and
        (Get-UiComboValue -Combo (Get-UiControl 'WaveOutEndpointBox')) -ceq 'synthetic-output-1' -and
        $script:storedProfile.devices.serial_port -ceq 'COM5') `
        '自动启动重新加载已保存配置时，没有沿用与手动保存相同的COM和音频稳定值。'
    $initialSaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedPreference = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ($initialSaveSucceeded -and [int]$savedPreference.devices.desired_power_watts -eq 6) `
        ('保存设置没有成功，或没有保留先前明确应用并确认的 6 W 目标。 saved={0}, power={1}, path={2}' -f $initialSaveSucceeded,$savedPreference.devices.desired_power_watts,$script:portableConfigPath)
    $masterBox = Get-UiControl 'MasterBox'
    $apiBox = Get-UiControl 'BmApiKeyBox'
    $savedMaster = [string]$savedPreference.connection.master
    $savedApiKey = [string]$savedPreference.connection.api_key
    $storedProfileBeforeRejectedSave = $script:storedProfile
    $serverSelectionBeforeRejectedSave = [string]$script:bmServerSelectionPreferenceId
    $masterBox.Text = 'invalid host name'
    $apiSentinel = 'R121_FAKE_API_SECRET_MUST_NOT_APPEAR'
    $apiBox.Password = $apiSentinel
    $invalidSaveSucceeded = [bool](Save-SettingsFromWindow)
    $saveErrorText = [string](Get-UiControl 'SettingsErrorText').Text
    $savedAfterRejectedSave = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi (-not $invalidSaveSucceeded -and $saveErrorText -match 'BM 服务器或认证字段格式无效' -and
        $saveErrorText -cnotlike ('*' + $apiSentinel + '*') -and
        $savedAfterRejectedSave.connection.master -ceq $savedMaster -and
        $savedAfterRejectedSave.connection.api_key -ceq $savedApiKey -and
        $script:portableConfig.connection.master -ceq $savedMaster -and
        $script:portableConfig.connection.api_key -ceq $savedApiKey -and
        [object]::ReferenceEquals($script:storedProfile,$storedProfileBeforeRejectedSave) -and
        [string]$script:bmServerSelectionPreferenceId -ceq $serverSelectionBeforeRejectedSave) `
        '无效的 BM 主机没有显示具体但不含密钥的安全错误，或失败保存改动了磁盘/内存设置。'
    $masterBox.Text = $savedMaster
    $apiBox.Password = $savedApiKey
    Assert-RadioUi ([bool](Save-SettingsFromWindow)) '修正 BM 主机后设置未能保存，或错误提示没有清除。'
    Assert-RadioUi ((Get-UiControl 'SettingsErrorText').Visibility -eq [System.Windows.Visibility]::Collapsed) '保存恢复成功后仍显示旧错误。'
    Assert-RadioUi ([object]::ReferenceEquals($script:mainWindow,$script:testRootMainWindow) -and -not $script:testRootMainWindow.Closed) `
        '保存统一配置不应关闭主窗口或改变其所有权。'

    # A real slider edit creates a write draft without changing the saved preference.
    $slider.Value = 9
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 9 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 6 -and -not $script:radioCatPowerNeedsUserChoice) `
        'MainWindow 功率滑块明确改到 9 W 后应形成独立草稿并保留先前确认的 6 W 偏好。'
    Assert-RadioUi ((Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '合法的 9 W 草稿形成后应用按钮应可用。'
    Set-UiRadioCatDraft -Field power -Value $null
    [void](Update-UiRadioCatControls)

    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{
        serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic Enhanced'; CatMatchRank=100; IsHri=$false },[pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI'; CatMatchRank=0; IsHri=$true })
        hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' })
        wave_inputs=@(); wave_outputs=@()
    }
    Set-UiRadioCatDeviceControls
    $slider = Get-SettingsControl 'CatPowerSlider'
    Assert-RadioUi ((Get-UiRadioCatSelectedPort) -ceq 'COM11') ('重开设置窗后 CAT 端口选择无效：port={0}, discovery={1}, pref={2}' -f (Get-UiRadioCatSelectedPort),$script:deviceDiscoveryState,$script:radioControlPreferences.cat_port)
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ([int]$script:radioControlPreferences.desired_power_watts -eq 6 -and
        $null -eq $script:radioCatEditDraft.power -and -not $script:radioCatPowerNeedsUserChoice -and
        -not (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '重开后 FieldHead 首读应保留偏好、没有功率草稿且禁止无草稿写入。'

    # Exercise the actual bound WPF ValueChanged and Apply Button handlers after explicit selection.
    $slider.Value = 6
    Assert-RadioUi ($null -ne $script:radioCatEditDraft.power -and [int]$script:radioCatEditDraft.power -eq 6 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 6 -and -not $script:radioCatPowerNeedsUserChoice) '真实 WPF 滑块操作没有创建 6 W 草稿或改写了已保存偏好。'
    $setPowerButton = Get-SettingsControl 'ApplyCatPowerButton'
    Assert-RadioUi $setPowerButton.IsEnabled '用户选择 6 W 后应用功率按钮应启用。'
    $script:lastStatusUtc = [DateTime]::UtcNow
    $explicitSetPowerBeginsBefore = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $clickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$setPowerButton)
    $setPowerButton.RaiseEvent($clickArgs)
    $setPowerSequenceReady = Complete-TestCatActionSequence -TimeoutMs 6000
    $explicitSetPowerLog = (Get-TestRadioCatLog)
    Assert-RadioUi ($setPowerSequenceReady -and
        ([regex]::Matches($explicitSetPowerLog,'BEGIN\|setPower')).Count -eq ($explicitSetPowerBeginsBefore + 1) -and
        $explicitSetPowerLog -match 'ARGS\|setPower\|.*PowerWatts=6' -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and [int]$script:radioCatObserved.power.value.watts -eq 6) `
        ('范围内的 WPF 功率按钮没有完成唯一的 6 W fresh-query/write/readback 序列。 status={0}, operation={1}, result={2}, cancelled={3}, cleanup={4}, begin={5}/{6}' -f `
            [string]$script:radioCatLastOperationStatus,[string]$script:radioCatOperationKind,
            [string]$script:radioCatResult.status,[bool]$script:radioCatOperationCancelled,
            [string]$script:radioCatResult.cleanup_status,([regex]::Matches($explicitSetPowerLog,'BEGIN\|setPower')).Count,$explicitSetPowerBeginsBefore)

    # A closed, identity-confirmed rejection can refresh path limits and current PC readback without becoming success.
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ([int]$slider.Maximum -eq 50) 'SPA-1 readback没有刷新功率范围。'
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    Start-UiRadioCatOperation -Operation setPower -PowerWatts 25
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'rejected' -and [string]$script:radioCatResult.status -ceq 'rejected') `
        ('功率设置拒绝被错误显示为成功。 last={0}, result={1}, observedPower={2}, rawError={3}, rawCleanup={4}, readbackValid={5}, raw={6}' -f $script:radioCatLastOperationStatus,
            $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
            $(if ($script:radioCatObserved) { [string]$script:radioCatObserved.power.value.watts } else { '<null>' }),
            [string]$script:radioCatRejectedPowerReadbackInput.error_code,[string]$script:radioCatRejectedPowerReadbackInput.cleanup_status,
            $script:radioCatRejectedPowerReadbackValid,
            (ConvertTo-Json -InputObject $script:radioCatRejectedPowerReadbackInput -Depth 5 -Compress))
    Assert-RadioUi ([int]$slider.Maximum -eq 10 -and -not (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '拒绝结果没有刷新 FieldHead 上限或仍允许继续写入。'
    Assert-RadioUi (([string](Get-SettingsControl 'CatObservedPowerText').Text) -match '5 W') '拒绝结果中的 PC 当前读值没有显示。'
    Assert-RadioUi ($script:radioCatResult.cleanup_status -ceq 'closed' -and $script:radioCatResult.source -ceq 'CAT test transport' -and
        $script:radioCatResult.port_name -ceq 'COM11' -and $script:radioCatObserved.radio_id.value -ceq '0840' -and
        $script:radioCatObserved.power.value.path -ceq 'FieldHead' -and $script:radioCatObserved.power.value.watts -eq 5 -and
        $script:radioCatResult.capabilities.set_power.maximum_watts -eq 10) 'rejected 结果应保留 closed/ID0840/FieldHead 的新鲜 PC 读值及 10 W 上限。'
    $env:WIREX_R116_UI_CAT_BAD_ID = '1'
    Start-UiRadioCatOperation -Operation setPower -PowerWatts 25
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($null -eq $script:radioCatResult -and -not (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '身份无效时，UI仍保留旧功率能力并允许继续操作。'
    Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue

    # A dirty 40 W preference from SPA-1 remains 40 W when FieldHead lowers the capability.
    $script:portableConfig.devices.cat_port = 'COM11'
    $script:portableConfig.devices.cat_baud_rate = 38400
    $script:portableConfig.devices.cat_stop_bits = 'Two'
    $script:portableConfig.devices.desired_power_watts = 25
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    $script:radioControlPreferences = [pscustomobject][ordered]@{
        schema_version=1; cat_port=[string]$script:portableConfig.devices.cat_port
        baud_rate=[int]$script:portableConfig.devices.cat_baud_rate; stop_bits='Two'
        desired_power_watts=[int]$script:portableConfig.devices.desired_power_watts
    }
    $script:radioCatObserved = $null
    $script:radioCatEditDraft.power = $null
    $script:radioCatPowerPreferenceDirty = $false
    Set-UiRadioCatPowerSliderRange -Maximum 50
    Set-UiRadioCatDeviceControls
    Assert-RadioUi ([int]$slider.Value -eq 25 -and [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and -not $script:radioCatPowerPreferenceDirty) '第二种偏好用例没有从 25 W 干净回填。'
    $slider.Value = 40
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 40 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and -not $script:radioCatPowerPreferenceDirty) '用户从 SPA-1 范围明确选 40 W 后应只创建草稿，不提前改写已保存偏好。'
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ([int]$slider.Maximum -eq 50 -and [int]$script:radioCatEditDraft.power -eq 40 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 25) 'SPA-1 读回应保留用户 40 W 草稿和独立 25 W 偏好。'
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ([int]$slider.Maximum -eq 10 -and [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and
        [int]$script:radioCatEditDraft.power -eq 40 -and $script:radioCatPowerNeedsUserChoice -and
        -not (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) 'FieldHead cap 降低后应保留 dirty 40 W 并要求重新选择、禁用应用。'
    $savedPowerWriteCount = ([regex]::Matches((Get-TestRadioCatLog),'ARGS\|setPower')).Count
    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ callsign=''; gateway_id=''; source_id=''; master=''; master_port=''; color_code=1 }; tx_target=[pscustomobject]@{ destination_id=91; kind='group'; slot=2 }; rx_policy=$null; transmit_enabled=$true }
    $dirtySaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedDirtyPreference = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ([int]$savedDirtyPreference.devices.desired_power_watts -eq 25 -and
        ([regex]::Matches((Get-TestRadioCatLog),'ARGS\|setPower')).Count -eq $savedPowerWriteCount -and
        $dirtySaveSucceeded) ('FieldHead 保存未成功或把未应用草稿写进偏好/发起CAT操作：saved={0}, args={1}/{2}, pref={3}, draft={4}, value={5}, needsChoice={6}' -f $savedDirtyPreference.devices.desired_power_watts,([regex]::Matches((Get-TestRadioCatLog),'ARGS\|setPower')).Count,$savedPowerWriteCount,$script:radioControlPreferences.desired_power_watts,$script:radioCatEditDraft.power,$slider.Value,$script:radioCatPowerNeedsUserChoice)
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls

    # While a mode request waits for HRI shutdown, the module cannot be called before successful process exit.
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $modeBox = Get-SettingsControl 'CatMainModeBox'
    $modeBox.SelectedItem = @($modeBox.Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    Assert-RadioUi ($script:radioModeApplyAfterStop -and $script:radioModeApplyAfterStop.cat_port -ceq 'COM11') '断开流程没有冻结 CAT 端口。'
    $logBeforeStop = (Get-TestRadioCatLog)
    Assert-RadioUi ($logBeforeStop -notmatch 'BEGIN\|setMode') 'StopAsync 尚未完成就启动了 CAT 模式设置。'
    Assert-RadioUi (-not (Complete-TestBridgeStop)) 'StopAsync 未完成时被 UI 当成完成。'
    Assert-RadioUi ((Get-TestRadioCatLog) -notmatch 'BEGIN\|setMode') '等待 StopAsync 期间发起 CAT 模式设置。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $script:stopTask = $testSupervisor.StopSource.Task
    $script:supervisor = $testSupervisor
    $script:mainWindow = New-TestMainWindow
    Assert-RadioUi (Complete-TestBridgeStop) '停止失败测试没有进入 UI 停止失败分支。'
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and (Get-TestRadioCatLog) -notmatch 'BEGIN\|setMode' -and
        $testSupervisor.StopCallCount -eq 1 -and $testSupervisor.DisposeCount -eq 0 -and -not $testSupervisor.Disposed) 'StopAsync 已完成但核心未退出时仍写入模式或错误释放 supervisor。'
    Restore-TestMainWindow

    $frequencyBox = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $frequencyBox.Text = '145.200000'
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    Invoke-UiRadioModeOrFrequencyApply -Operation setFrequency
    Assert-RadioUi ($script:radioModeApplyAfterStop -and $script:radioModeApplyAfterStop.frequency_hz -eq 145200000) 'FA 请求没有冻结成明确的 MAIN Hz 值。'
    Assert-RadioUi ((Get-TestRadioCatLog) -notmatch 'BEGIN\|setFrequency') 'Stop 未完成时发出了 FA 设置。'
    Assert-RadioUi (-not (Complete-TestBridgeStop)) 'FA 请求在 StopAsync 完成前结束了等待。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $script:stopTask = $testSupervisor.StopSource.Task
    $script:mainWindow = New-TestMainWindow
    Assert-RadioUi (Complete-TestBridgeStop) 'FA Stop 失败没有进入停止未完成路径。'
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and $testSupervisor.DisposeCount -eq 0 -and
        (Get-TestRadioCatLog) -notmatch 'BEGIN\|setFrequency') '停止未退出时仍执行 FA 或提前释放 supervisor。'
    Restore-TestMainWindow

    # A live core must stop before a MAIN write even if its fresh status says the
    # HRI serial handle has not opened yet.
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $testSupervisor = New-TestRadioSupervisor -HriSerialOpen:$false
    $script:supervisor = $testSupervisor
    $setModeCountBeforeLiveCore = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    Assert-RadioUi ($script:radioModeApplyAfterStop -and $testSupervisor.StopCallCount -eq 1 -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeCountBeforeLiveCore) `
        '活核心的 hri_serial_open=false 状态绕过了核心停止，过早写入 MAIN 模式。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '活核心尚未打开 HRI 时没有完成必要的核心停止。'
    Assert-RadioUi ($testSupervisor.Disposed -and $script:radioCatOperationKind -ceq 'query') '停止活核心后没有先启动 CAT fresh query。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($setModeCountBeforeLiveCore + 1) -TimeoutMs 1500) `
        '停止活核心后的 fresh CAT query 没有启动 fake MAIN 模式 worker。'
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setMode' -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq ($setModeCountBeforeLiveCore + 1)) `
        ('活核心退出后的 fresh CAT query 没有唯一授权 MAIN 模式写入。 operation={0}, status={1}, pending={2}, setCount={3}/{4}, catGen={5}, requestGen={6}, supervisor={7}, queryStatus={8}' -f `
            [string]$script:radioCatOperationKind,[string]$script:radioCatLastOperationStatus,[bool]$script:radioCatPendingModeFrequencyRequest,
            ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count,$setModeCountBeforeLiveCore,
            [int]$script:radioCatSessionGeneration,$(if($script:radioCatPendingModeFrequencyRequest){$script:radioCatPendingModeFrequencyRequest.cat_generation}else{-1}),
            [bool]$script:supervisor,$(if($script:radioCatResult){[string]$script:radioCatResult.status}else{'<null>'}))
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and -not $script:supervisor) '活核心退出后的 MAIN 模式写入没有确认或错误重连。'
    Restore-TestMainWindow

    # A live core with stale or incomplete status must reject the action before Stop or CAT write.
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $testSupervisor = New-TestRadioSupervisor -HriSerialOpen:$false
    $script:supervisor = $testSupervisor
    $script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
    $setModeCountBeforeStaleCore = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $staleCoreRejected = $false
    try { Invoke-UiRadioModeOrFrequencyApply -Operation setMode }
    catch { $staleCoreRejected = $_.Exception.Message -match '空闲' }
    Assert-RadioUi ($staleCoreRejected -and $testSupervisor.StopCallCount -eq 0 -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeCountBeforeStaleCore) `
        '活核心状态过期时没有拒绝 MAIN 写入，或已经发起了 CAT setMode。'
    $testSupervisor.HasExited = $true
    $testSupervisor.Dispose()
    $script:supervisor = $null
    $script:lastStatusUtc = [DateTime]::UtcNow
    Restore-TestMainWindow

    # A successful stop starts one frozen mode operation and does not restart the bridge.
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    $setModeCountBeforeSuccess = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $queryCountBeforeModeRead = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '确认进程退出后没有完成断开流程。'
    Assert-RadioUi ($testSupervisor.Disposed -and $testSupervisor.DisposeCount -eq 1 -and -not $script:supervisor) 'CAT 请求启动前没有先释放已退出的 supervisor。'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeModeRead + 1) -TimeoutMs 1500) 'HRI 退出后没有启动 CAT 状态查询。'
    $afterModeStopLog = (Get-TestRadioCatLog)
    Assert-RadioUi (([regex]::Matches($afterModeStopLog,'BEGIN\|query')).Count -eq ($queryCountBeforeModeRead + 1) -and
        ([regex]::Matches($afterModeStopLog,'BEGIN\|setMode')).Count -eq $setModeCountBeforeSuccess) 'HRI 退出后必须先查询 CAT 状态，确认前不能直接写入模式。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $modeStartedAfterQuery = Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($setModeCountBeforeSuccess + 1) -TimeoutMs 1500
    Assert-RadioUi $modeStartedAfterQuery ('CAT 查询确认后没有启动唯一冻结的 C4FM-DN MAIN 请求。 catStatus={0}, operation={1}, result={2}, pending={3}, observedKey={4}, currentKey={5}' -f `
        $script:radioCatLastOperationStatus,$script:radioCatOperationKind, $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
        [bool]$script:radioCatPendingModeFrequencyRequest,$script:radioCatObservedConnectionKey,(Get-UiRadioCatConnectionKey))
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setMode' -and $script:radioCatLastOperationStatus -ceq 'confirmed') 'CAT 查询未确认，但自动启动了 MAIN 模式设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $afterModeLog = (Get-TestRadioCatLog)
    Assert-RadioUi (([regex]::Matches($afterModeLog,'BEGIN\|setMode')).Count -eq ($setModeCountBeforeSuccess + 1) -and
        $afterModeLog -match 'ARGS\|setMode\|Port=COM11\|Role=CAT-1\|HRI=COM5\|Baud=38400\|StopBits=Two\|Side=Main\|Mode=C4FM-DN' -and
        $afterModeLog -match 'CLEANUP\|setMode') ('确认退出后没有执行唯一冻结的 C4FM-DN MAIN 请求或清理 fake worker。 count={0}/{1}, args={2}, cleanup={3}, status={4}, operation={5}, result={6}, observedKey={7}, currentKey={8}' -f `
            ([regex]::Matches($afterModeLog,'BEGIN\|setMode')).Count,($setModeCountBeforeSuccess + 1),
            ($afterModeLog -match 'ARGS\|setMode\|Port=COM11\|Role=CAT-1\|HRI=COM5\|Baud=38400\|StopBits=Two\|Side=Main\|Mode=C4FM-DN'),
            ($afterModeLog -match 'CLEANUP\|setMode'),$script:radioCatLastOperationStatus,$script:radioCatOperationKind,
            $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
            $script:radioCatObservedConnectionKey,(Get-UiRadioCatConnectionKey))
    Assert-RadioUi ($script:testStartBridgeRunCalls -eq 0 -and -not $script:reconnectAfterStop -and -not $script:supervisor) '断开设置完成后 UI 自动重连。'
    Restore-TestMainWindow

    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $frequencyBox = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $frequencyBox.Text = '145.200000'
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    Invoke-UiRadioModeOrFrequencyApply -Operation setFrequency
    $setFrequencyCountBeforeSuccess = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $queryCountBeforeFrequencyRead = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) 'MAIN 频率请求没有完成核心停止。'
    Assert-RadioUi ($testSupervisor.Disposed -and -not $script:supervisor) 'MAIN 频率 CAT 请求启动前没有释放已退出的 supervisor。'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeFrequencyRead + 1) -TimeoutMs 3000) `
        ('HRI退出后没有启动CAT状态查询。 kind={0}, worker={1}, pending={2}, queryCount={3}/{4}' -f `
            [string]$script:radioCatOperationKind,[bool]$script:radioCatOperationPowerShell,[bool]$script:radioCatPendingModeFrequencyRequest,
            ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count,$queryCountBeforeFrequencyRead)
    $afterFrequencyStopLog = (Get-TestRadioCatLog)
    Assert-RadioUi (([regex]::Matches($afterFrequencyStopLog,'BEGIN\|query')).Count -eq ($queryCountBeforeFrequencyRead + 1) -and
        ([regex]::Matches($afterFrequencyStopLog,'BEGIN\|setFrequency')).Count -eq $setFrequencyCountBeforeSuccess) 'HRI 退出后必须先查询 CAT 状态，确认前不能直接写入频率。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setFrequency' -MinimumCount ($setFrequencyCountBeforeSuccess + 1) -TimeoutMs 3000) 'CAT 查询确认后没有启动唯一冻结的 MAIN FA 请求。'
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setFrequency' -and $script:radioCatLastOperationStatus -ceq 'confirmed') 'CAT 查询未确认，但自动启动了 MAIN 频率设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $afterFrequencyLog = (Get-TestRadioCatLog)
    Assert-RadioUi (([regex]::Matches($afterFrequencyLog,'BEGIN\|setFrequency')).Count -eq ($setFrequencyCountBeforeSuccess + 1) -and
        $afterFrequencyLog -match 'ARGS\|setFrequency\|Port=COM11\|Role=CAT-1\|HRI=COM5\|Baud=38400\|StopBits=Two\|Side=Main\|Mode=\|FrequencyHz=145200000' -and
        $afterFrequencyLog -match 'CLEANUP\|setFrequency') '确认退出后没有执行唯一冻结的 145.2 MHz MAIN FA 请求。'
    Assert-RadioUi ($script:testStartBridgeRunCalls -eq 0 -and -not $script:reconnectAfterStop -and -not $script:supervisor) 'MAIN 频率设置后 UI 自动重连。'
    Restore-TestMainWindow

    # Closing Settings while a mode stop is pending revokes the frozen request.
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    $queryCountBeforeClose = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    $pendingModeBeforeClose = $script:radioModeApplyAfterStop
    $setModeCountBeforeClose = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    Cancel-SettingsWindow
    Assert-RadioUi ($null -eq $script:settingsWindow -and [object]::ReferenceEquals($script:radioModeApplyAfterStop,$pendingModeBeforeClose)) '关闭路由弹窗没有保留由主窗发起、等待核心停止的 MAIN 模式请求。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '关闭设置窗后没有完成等待中的核心停止。'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeClose + 1) -TimeoutMs 1500) '保留的 MAIN 模式请求没有先启动 CAT 查询。'
    $afterCloseStopLog = (Get-TestRadioCatLog)
    Assert-RadioUi ($testSupervisor.Disposed -and ([regex]::Matches($afterCloseStopLog,'BEGIN\|setMode')).Count -eq $setModeCountBeforeClose -and
        $null -eq $script:radioModeApplyAfterStop -and $script:radioCatPendingModeFrequencyRequest) '关闭路由弹窗后，CAT 查询前的待执行 MAIN 模式意图丢失或过早写入。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($setModeCountBeforeClose + 1) -TimeoutMs 1500) '关闭路由弹窗后，确认的 CAT 查询没有继续执行保留的 MAIN 模式请求。'
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setMode' -and $null -eq $script:radioCatPendingModeFrequencyRequest) 'MAIN 模式请求没有在 CAT query 确认后进入唯一写入阶段。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $afterCloseModeLog = (Get-TestRadioCatLog)
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and
        $afterCloseModeLog -match ('ARGS\|setMode\|Port=COM11\|Role=CAT-1\|HRI=COM5\|Baud=38400\|StopBits=Two\|Side=Main\|Mode={0}' -f [regex]::Escape([string]$pendingModeBeforeClose.mode)) -and
        $afterCloseModeLog -match 'CLEANUP\|setMode') '保留的 MAIN 模式请求未按冻结参数完成 CAT 写入和清理。'

    # CAT Disconnect during a live-core mode transaction clears the bridge-owned stop intent,
    # but leaves the already-requested Wires-X stop alone.
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $cancelStopModeBox = Get-SettingsControl 'CatMainModeBox'
    $cancelStopModeBox.SelectedItem = @($cancelStopModeBox.Items | Where-Object { [string]$_.Tag -ceq 'FM' })[0]
    $cancelStopSupervisor = New-TestRadioSupervisor
    $script:supervisor = $cancelStopSupervisor
    $queryCountBeforeCatDisconnectDuringStop = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    $setModeCountBeforeCatDisconnectDuringStop = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    Assert-RadioUi ($script:radioModeApplyAfterStop -and $cancelStopSupervisor.StopCallCount -eq 1) `
        'Disconnect/stop cancel test没有进入待停止的 MAIN 模式事务。'
    $generationBeforeCatDisconnectDuringStop = [int]$script:radioCatSessionGeneration
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and $null -eq $script:radioCatPendingModeFrequencyRequest -and
        $null -eq $script:radioCatQueuedAction -and [int]$script:radioCatSessionGeneration -gt $generationBeforeCatDisconnectDuringStop -and
        [object]::ReferenceEquals($script:supervisor,$cancelStopSupervisor) -and $cancelStopSupervisor.StopCallCount -eq 1) `
        'CAT Disconnect没有撤销bridge冻结请求/提升CAT代，或它额外停止了Wires核心。'
    [void]$cancelStopSupervisor.StopSource.TrySetResult(0)
    $cancelStopSupervisor.HasExited = $true
    $script:stopTask = $cancelStopSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) 'CAT Disconnect后已被用户请求的Wires stop没有完成。'
    Assert-RadioUi (-not $script:supervisor -and -not $script:radioCatOperationPowerShell -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count -eq $queryCountBeforeCatDisconnectDuringStop -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeCountBeforeCatDisconnectDuringStop -and
        -not $script:radioCatSessionRequested -and $script:radioCatManualDisconnect) `
        '普通 Wires stop 在 CAT Disconnect 后复活了 CAT query/write 或重新连接会话。'

    # CAT Disconnect while the post-stop fresh query is in flight cancels its generation-bound request.
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $cancelFreshModeBox = Get-SettingsControl 'CatMainModeBox'
    $cancelFreshModeBox.SelectedItem = @($cancelFreshModeBox.Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    $cancelFreshSupervisor = New-TestRadioSupervisor
    $script:supervisor = $cancelFreshSupervisor
    $queryCountBeforeCatDisconnectDuringFreshQuery = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    $setModeCountBeforeCatDisconnectDuringFreshQuery = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    [void]$cancelFreshSupervisor.StopSource.TrySetResult(0)
    $cancelFreshSupervisor.HasExited = $true
    $script:stopTask = $cancelFreshSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) 'MAIN 模式事务没有完成先停 Wires 的阶段。'
    $freshQueryLogStarted = Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeCatDisconnectDuringFreshQuery + 1) -TimeoutMs 1500
    Assert-RadioUi ($script:radioCatPendingModeFrequencyRequest -and $script:radioCatOperationPowerShell -and
        [string]$script:radioCatOperationKind -ceq 'query' -and
        $freshQueryLogStarted -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count -eq ($queryCountBeforeCatDisconnectDuringFreshQuery + 1)) `
        ('核心停止后没有启动 generation-bound CAT fresh query。 pending={0}, operation={1}/{2}, supervisor={3}, stopTask={4}, queryCount={5}/{6}, request={7}, session={8}' -f `
            [bool]$script:radioCatPendingModeFrequencyRequest,[bool]$script:radioCatOperationPowerShell,[string]$script:radioCatOperationKind,
            [bool]$script:supervisor,[bool]$script:stopTask,([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count,
            $queryCountBeforeCatDisconnectDuringFreshQuery,$script:radioModeApplyAfterStop,(Get-UiRadioCatSessionState).state)
    $generationBeforeCatDisconnectDuringFreshQuery = [int]$script:radioCatSessionGeneration
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi (-not $script:radioCatSessionRequested -and $null -eq $script:radioCatPendingModeFrequencyRequest -and
        $null -eq $script:radioModeApplyAfterStop -and $script:radioCatOperationCancelled -and
        [int]$script:radioCatSessionGeneration -gt $generationBeforeCatDisconnectDuringFreshQuery -and -not $script:supervisor) `
        'CAT Disconnect没有撤销fresh-query待写请求并取消旧代worker。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and $null -eq $script:radioCatPendingModeFrequencyRequest -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeCountBeforeCatDisconnectDuringFreshQuery -and
        (Get-UiRadioCatSessionState).state -eq 'disconnected') `
        '被CAT Disconnect撤销的旧fresh query仍然启动了MAIN write或留下CAT worker。'

    # Stop and Exit also revokes the queued mode request and closes only after the supervisor exits.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $modeBox = Get-SettingsControl 'CatMainModeBox'
    $modeBox.SelectedItem = @($modeBox.Items | Where-Object { [string]$_.Tag -ceq 'FM' })[0]
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    $setModeCountBeforeStopExit = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $script:mainWindow = New-TestMainWindow
    Request-StopAndExit
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and $script:closingAfterStop) '停止并退出没有撤销待执行模式请求。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '停止并退出没有完成核心停止。'
    Assert-RadioUi ($script:mainWindow.Closed -and $testSupervisor.Disposed -and ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeCountBeforeStopExit) '停止并退出后仍应用了 CAT 待办或没有在核心退出后关闭主窗。'
    Restore-TestMainWindow
    # This fixture simulates app shutdown but continues running further isolated checks.
    $script:radioCatSessionShutdown = $false
    $script:radioCatSessionRequested = $false
    $script:radioCatSessionConnected = $false
    $script:radioCatPollingActive = $false
    $script:radioCatSessionState = 'disconnected'
    $script:radioCatSessionError = ''
    $script:radioCatQueuedAction = $null
    Update-UiRadioCatSessionControls

    # Closing the routing modal must not cancel a CAT worker owned by MainWindow.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '350'
    $queryCountBeforeCancel = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    Start-UiRadioCatOperation -Operation query
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeCancel + 1) -TimeoutMs 1500) '设置窗取消测试没有启动 fake query worker。'
    Start-Sleep -Milliseconds 100
    $cancelTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Cancel-SettingsWindow
    Assert-RadioUi ($script:radioCatOperationPowerShell -and -not $script:radioCatOperationCancelled -and
        [object]::ReferenceEquals($script:radioCatOperationOwnerWindow,$script:testRootMainWindow) -and $null -eq $script:settingsWindow) `
        '关闭路由弹窗取消了归 MainWindow 所有的 CAT 查询。'
    $closedSettingsWindow = $script:testClosedSettingsWindow
    $operationPowerShellBeforeReopen = $script:radioCatOperationPowerShell
    $reopenedSettingsWindow = Initialize-SettingsWindow
    Assert-RadioUi ($reopenedSettingsWindow -and -not [object]::ReferenceEquals($reopenedSettingsWindow,$closedSettingsWindow) -and
        [object]::ReferenceEquals($script:settingsWindow,$reopenedSettingsWindow) -and
        [object]::ReferenceEquals($script:radioCatOperationPowerShell,$operationPowerShellBeforeReopen) -and
        -not $script:radioCatOperationCancelled) '关闭并重开配置窗替换了Window实例或取消了由主窗口持有的CAT任务。'
    $cleanupElapsed = Complete-TestCatRunspace -TimeoutMs 2800
    $cancelTimer.Stop()
    Assert-RadioUi ($cleanupElapsed -lt 2800 -and $null -eq $script:radioCatOperationPowerShell -and
        [object]::ReferenceEquals($script:settingsWindow,$reopenedSettingsWindow)) '关闭并重开配置窗后，CAT runspace 没有在 fake worker 完成后及时清理或新窗口丢失。'
    $cancelLog = (Get-TestRadioCatLog)
    Assert-RadioUi (([regex]::Matches($cancelLog,'BEGIN\|query')).Count -gt $queryCountBeforeCancel -and $cancelLog -match 'CLEANUP\|query' -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and $script:radioCatResult -and $script:radioCatObserved) `
        '路由弹窗关闭后应完成 CAT fake worker，并接受仍属 MainWindow 的查询结果。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue

    # Hitting the CAT deadline also requests cancellation and discards any eventual worker result.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $queryCountBeforeDeadline = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    $observedBeforeDeadline = $script:radioCatObserved
    Start-UiRadioCatOperation -Operation query
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeDeadline + 1) -TimeoutMs 1500) '期限测试没有启动 fake query worker。'
    Start-Sleep -Milliseconds 100
    $script:radioCatOperationStartedUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Assert-RadioUi (-not (Complete-UiRadioCatOperation) -and $script:radioCatOperationCancelled -and $script:radioCatOperationStopAsync) 'CAT 期限到达后没有要求停止 fake worker。'
    [void](Complete-TestCatRunspace -TimeoutMs 2800)
    $deadlineLog = (Get-TestRadioCatLog)
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and $script:radioCatLastOperationStatus -ceq 'unknown' -and
        $null -eq $script:radioCatResult -and [object]::ReferenceEquals($script:radioCatObserved,$observedBeforeDeadline) -and
        ([regex]::Matches($deadlineLog,'BEGIN\|query')).Count -gt $queryCountBeforeDeadline -and $deadlineLog -match 'CLEANUP\|query') ('CAT 期限取消后仍保留结果或未清理 fake worker。 powerShell={0}, status={1}, result={2}, observed={3}, canceled={4}, cleanup={5}, queryCount={6}/{7}' -f `
            [bool]$script:radioCatOperationPowerShell,$script:radioCatLastOperationStatus,
            $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
            [bool]$script:radioCatObserved,$script:radioCatOperationCancelled,($deadlineLog -match 'CLEANUP\|query'),
            ([regex]::Matches($deadlineLog,'BEGIN\|query')).Count,$queryCountBeforeDeadline)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue

    # Expired core idle status is cancelled by the timer's stale-display path, even with no new status record.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$false; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
        hri_serial_open=$true; hri_ready=$true
        bm_state='stopped'; bm_connection=[pscustomobject]@{requested_enabled=$false;revision=[uint64]0;transport_open=$false}
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $pausedCoreIdleStatus=$script:latestStatus
    Assert-RadioUi ((Test-UiRadioCatRunIdle -RequireFreshStatus) -and
        (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled -and
        (Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'tx_state').value -eq 0) `
        'HRI ready 且 BM 暂停时，released/空闲状态与新鲜 CAT TX=0 应允许电台功率操作。'
    $script:latestStatus=$pausedCoreIdleStatus.PSObject.Copy(); $script:latestStatus.ptt_last_state='pressed'
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) 'BM paused 状态不能绕过明确的 PTT pressed 状态。'
    $script:latestStatus=$pausedCoreIdleStatus.PSObject.Copy(); $script:latestStatus.ptt_gate_tx_active=$true
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) 'BM paused 状态不能绕过 Native 报告的活动发射状态。'
    $script:latestStatus=$pausedCoreIdleStatus.PSObject.Copy(); $script:latestStatus.rx_queue_playback_frames=[uint64]1
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) 'BM paused 状态不能绕过未清空的接收媒体队列。'
    $script:latestStatus=$pausedCoreIdleStatus
    $slider = Get-SettingsControl 'CatPowerSlider'
    $slider.Value = 6
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 6 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and
        (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) ((('过期测试应先通过真实滑块建立合法 6 W 草稿并启用功率应用，同时保留已保存偏好。 draft={0}, pref={1}, enabled={2}, max={3}, result={4}, key={5}/{6}, core={7}, statusAge={8}' -f `
            $script:radioCatEditDraft.power,$script:radioControlPreferences.desired_power_watts,
            [bool](Get-SettingsControl 'ApplyCatPowerButton').IsEnabled,[double]$slider.Maximum,
            $(if($script:radioCatResult){[string]$script:radioCatResult.status}else{'<null>'}),
            [string]$script:radioCatObservedConnectionKey,(Get-UiRadioCatConnectionKey),[bool]$script:supervisor,
            [int]([DateTime]::UtcNow - $script:lastStatusUtc).TotalMilliseconds) +
        (' detail: needsChoice={0}, operation={1}/{2}, queued={3}, pendingMode={4}, idle={5}, conflict={6}, port={7}, session={8}' -f `
            [bool]$script:radioCatPowerNeedsUserChoice,[bool]$script:radioCatOperationPowerShell,[string]$script:radioCatOperationKind,
            [bool]$script:radioCatQueuedAction,[bool]$script:radioCatPendingModeFrequencyRequest,(Test-UiRadioCatRunIdle -RequireFreshStatus),
            (Test-UiRadioCatSelectedPortConflict),(Get-UiRadioCatSelectedPort),(Get-UiRadioCatSessionState).state)))
    $env:WIREX_R116_UI_CAT_DELAY = 'setPower'
    $writeCountBeforeStale = ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count
    $beginCountBeforeStale = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $stalePowerButton = Get-SettingsControl 'ApplyCatPowerButton'
    [void](Start-UiRadioCatOperation -Operation query)
    $staleClickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$stalePowerButton)
    $stalePowerButton.RaiseEvent($staleClickArgs)
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setPower') `
        '过期状态取消测试没有先冻结用户明确的 6 W 请求。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $observedSnapshotBeforeStale = ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setPower' -MinimumCount ($beginCountBeforeStale + 1) -TimeoutMs 1000) '状态过期测试没有启动真实 WPF Apply 按钮创建的 fake CAT worker。'
    Start-Sleep -Milliseconds 100
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -gt $beginCountBeforeStale) '状态过期测试没有观察到新启动的功率操作。'
    $script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Set-StaleDisplay
    Assert-RadioUi ($script:radioCatOperationCancelled -and $null -ne $script:radioCatOperationStopAsync) '状态过期后，timer没有取消在途功率设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 2800)
    $writesAfterStale = ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and $writesAfterStale -eq $writeCountBeforeStale -and
        $script:radioCatLastOperationStatus -ceq 'unknown' -and $null -eq $script:radioCatResult -and
        (ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress) -ceq $observedSnapshotBeforeStale) `
        ('核心状态过期后仍发生新写入、UI接受晚结果、runspace未释放，或丢弃了此前仍有效的 CAT 读值。 operation={0}/{1}, canceled={2}, stop={3}, status={4}, result={5}, observedSame={6}, writes={7}/{8}' -f `
            [bool]$script:radioCatOperationPowerShell,[string]$script:radioCatOperationKind,[bool]$script:radioCatOperationCancelled,
            [bool]$script:radioCatOperationStopAsync,[string]$script:radioCatLastOperationStatus,
            $(if($script:radioCatResult){[string]$script:radioCatResult.status}else{'<null>'}),
            ((ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress) -ceq $observedSnapshotBeforeStale),$writesAfterStale,$writeCountBeforeStale)
    Start-Sleep -Milliseconds 100
    [void](Complete-UiRadioCatOperation)
    Assert-RadioUi ($null -eq $script:radioCatResult -and
        (ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress) -ceq $observedSnapshotBeforeStale -and
        ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count -eq $writeCountBeforeStale) '取消后的 CAT 晚结果覆盖了未知状态或继续写入。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue

    # Application shutdown drains CAT without stopping a live HRI supervisor.
    $script:supervisor = $null
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    $script:radioCatSessionShutdown = $false
    $script:radioCatSessionRequested = $true
    $script:radioCatPollingActive = $true
    Assert-RadioUi ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell) 'app shutdown test did not start the CAT worker.'
    $shutdownCompletedImmediately = Stop-UiRadioCatSession -Reason app_shutdown
    Assert-RadioUi (-not $shutdownCompletedImmediately -and (Get-UiRadioCatSessionState).shutdown -and
        -not (Get-UiRadioCatSessionState).requested -and -not (Get-UiRadioCatSessionState).polling -and
        $script:radioCatOperationStopAsync -and -not $script:supervisor) 'app shutdown did not request CAT worker cleanup independently.'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and (Get-UiRadioCatSessionState).shutdown -and
        -not (Connect-UiRadioCatSession)) 'app shutdown left a CAT worker or allowed a new session.'

    # RenderOnly call-history coverage uses the production model and WPF pager with synthetic status only.
    $script:radioCatSessionShutdown=$false
    $script:callHistoryModel=New-Object 'System.Collections.Generic.List[object]'
    $script:callHistoryKeys=@{}
    $script:selectedCallHistoryKey=''
    $script:callHistoryPageIndex=0
    if ($null -eq $script:callIdentityCache) { $script:callIdentityCache=@{} }
    $script:radioIdentityModuleLoaded=$true
    function Resolve-RadioIdentity {
        param([uint32]$RadioId,[string]$CachePath)
        return $script:callIdentityCache[[string]$RadioId]
    }
    $script:identityNativeCallRefreshKeys=@{}
    $historyWindow=$script:testRootMainWindow
    $script:mainWindow=$historyWindow
    for ($historyGeneration=1; $historyGeneration -le 5; $historyGeneration++) {
        $script:identityNativeCallRefreshKeys[('history-test|{0}|460997' -f $historyGeneration)]=$true
        $historyRecord=[pscustomobject][ordered]@{
            run_id='history-test';current_call_valid=$true;current_call_generation=[uint64]$historyGeneration
            current_call_source_id=[uint64]460997;current_call_destination_id=[uint64](3149876+$historyGeneration)
            current_call_slot=[uint64]2;current_call_kind='P';timestamp_utc_ms=[int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }
        Add-UiCallHistoryRecord -Record $historyRecord
    }
    $historyList=$historyWindow.FindName('CallHistoryList')
    Assert-RadioUi ($script:callHistoryModel.Count -eq 5 -and $historyList.Items.Count -eq 2 -and
        $script:callHistoryPageIndex -eq 1 -and $historyWindow.FindName('CallHistoryPageText').Text -ceq '2 / 2') `
        '超过三条来话后，完整模型、保留选中记录的第二页和页码未正确建立。'
    [void](Set-UiCallHistoryPage -Delta -1)
    $historyList.SelectedIndex=0
    $selectedHistoryKey=Get-UiCallHistorySelectedKey
    $selectedHistoryTarget=New-UiCallTargetFromHistoryEntry -Entry $historyList.SelectedItem
    Assert-RadioUi ($selectedHistoryKey -ceq 'history-test|5' -and $selectedHistoryTarget.destination_id -eq 460997 -and
        $selectedHistoryTarget.kind -ceq 'private' -and $selectedHistoryTarget.slot -eq 2) `
        '当前页选中的记录没有按其呼叫 key 生成 PTT 目标。'
    $offPageKey='history-test|1'
    $script:callIdentityCache['460997']=[pscustomobject]@{source_id=[uint32]460997;id=[uint32]460997;callsign='N1PAGE';name='Synthetic Page';status='found';display_name='N1PAGE'}
    Assert-RadioUi (Update-UiIdentityHistoryEntry -HistoryKey $offPageKey -Identity $script:callIdentityCache['460997']) `
        '身份查询没有按历史 record key 找到完整模型中的离页记录。'
    $offPageRecord=@($script:callHistoryModel | Where-Object { $_.key -ceq $offPageKey })[0]
    Assert-RadioUi ($offPageRecord.source_label -match 'N1PAGE' -and $historyList.Items.Count -eq 3 -and
        (Get-UiCallHistorySelectedKey) -ceq $selectedHistoryKey) ('离页身份回写丢失呼号、改变当前页或改写选中 key。 label={0}, count={1}, selected={2}/{3}' -f `
            $offPageRecord.source_label,$historyList.Items.Count,(Get-UiCallHistorySelectedKey),$selectedHistoryKey)
    $historyIncoming=[pscustomobject][ordered]@{
        run_id='history-test';current_call_valid=$true;current_call_generation=[uint64]6
        current_call_source_id=[uint64]460997;current_call_destination_id=[uint64]3149882
        current_call_slot=[uint64]2;current_call_kind='P';timestamp_utc_ms=[int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    }
    $script:identityNativeCallRefreshKeys['history-test|6|460997']=$true
    Add-UiCallHistoryRecord -Record $historyIncoming
    Assert-RadioUi ($script:callHistoryModel.Count -eq 6 -and
        (Get-UiCallHistorySelectedKey) -ceq $selectedHistoryKey -and
        [string]$historyList.SelectedItem.key -ceq $selectedHistoryKey) `
        '新来话插入后，列表没有保留用户选中的历史记录 key。'
    Add-UiCallHistoryRecord -Record $historyIncoming
    Assert-RadioUi ($script:callHistoryModel.Count -eq 6) '相同 run/generation 的来话重复进入完整模型。'
    for ($historyGeneration=7; $historyGeneration -le 55; $historyGeneration++) {
        $script:identityNativeCallRefreshKeys[('history-test|{0}|460997' -f $historyGeneration)]=$true
        $boundedHistoryRecord=[pscustomobject][ordered]@{
            run_id='history-test';current_call_valid=$true;current_call_generation=[uint64]$historyGeneration
            current_call_source_id=[uint64]460997;current_call_destination_id=[uint64](3149882+$historyGeneration)
            current_call_slot=[uint64]2;current_call_kind='P';timestamp_utc_ms=[int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }
        Add-UiCallHistoryRecord -Record $boundedHistoryRecord
    }
    Assert-RadioUi ($script:callHistoryModel.Count -eq 50 -and $script:callHistoryModel[0].key -ceq 'history-test|55' -and
        $script:callHistoryModel[49].key -ceq 'history-test|6' -and $historyList.Items.Count -eq 3) `
        '完整历史模型没有按呼叫 key 去重并保留最近五十条记录。'

    # 真实 Start-BridgeRun 参数准备走临时 fake launcher，不经过 UiTestFixture 的 supervisor factory。
    $pausedConfig=Get-WirexPortableConfig -Path $script:portableConfigPath
    $pausedConfig.connection.password=''
    $script:portableConfig=Save-WirexPortableConfig -Path $script:portableConfigPath -Config $pausedConfig
    [void](Import-UiPortableConfig)
    $passwordBoxForRealPrepare=$script:testRootMainWindow.FindName('PasswordBox')
    $passwordBoxForRealPrepare.Password=''
    $fakePrepareDirectory=Join-Path $script:testRoot 'actual-ui-prepare'
    [System.IO.Directory]::CreateDirectory($fakePrepareDirectory) | Out-Null
    $fakeUiLauncherPath=Join-Path $fakePrepareDirectory 'fake-ui-preparer.ps1'
    $fakeUiNativePath=Join-Path $fakePrepareDirectory 'wirex_bridge.exe'
    $uiPrepareCapturePath=Join-Path $fakePrepareDirectory 'captured-parameters.json'
    [System.IO.File]::WriteAllBytes($fakeUiNativePath,[byte[]]@(0x4D,0x5A))
    $fakeUiLauncher=@'
param([string]$Preset,[string]$ConnectionProfilePath,[string]$AudioSettingsPath,[string]$StatusDirectory,[string]$PreparationOutputPath,[switch]$PrepareOnly,[switch]$NoInteractive,[switch]$BmStartDisconnected,[switch]$RequirePasswordFile,[string]$PasswordFile)
$ErrorActionPreference='Stop'
$capture=[ordered]@{
    bound_names=[string[]]@($PSBoundParameters.Keys)
    paused=[bool]$BmStartDisconnected
    password_file_bound=[bool]$PSBoundParameters.ContainsKey('PasswordFile')
    require_password_file_bound=[bool]$PSBoundParameters.ContainsKey('RequirePasswordFile')
}
[System.IO.File]::WriteAllText((Join-Path $StatusDirectory 'captured-parameters.json'),(ConvertTo-Json -InputObject $capture -Depth 3 -Compress),(New-Object System.Text.UTF8Encoding($false)))
$status=Join-Path $StatusDirectory 'fake-status.jsonl'
$routing=Join-Path $StatusDirectory 'routing-state.json'
[System.IO.File]::WriteAllText($routing,'{}',(New-Object System.Text.UTF8Encoding($false)))
$record=[ordered]@{schema_version=1;executable='fake-native.exe';arguments=[string[]]@('--run','--ui-pipe','--ui-control-version','2','--bm-start-disconnected');status_path=$status;routing_state_path=$routing}
[System.IO.File]::WriteAllText($PreparationOutputPath,(ConvertTo-Json -InputObject $record -Depth 4 -Compress),(New-Object System.Text.UTF8Encoding($false)))
'@
    [System.IO.File]::WriteAllText($fakeUiLauncherPath,$fakeUiLauncher,(New-Object System.Text.UTF8Encoding($true)))
    $script:UiTestFixture=$false
    $script:configDirectory=$script:testRoot
    $script:releaseDirectory=$fakePrepareDirectory
    $script:releaseLauncher=$fakeUiLauncherPath
    $script:nativeExecutable=$fakeUiNativePath
    $script:mainWindow=$script:testRootMainWindow
    $script:supervisor=$null; $script:stopTask=$null; $script:preparePowerShell=$null; $script:prepareAsync=$null
    $script:preparationStarted=$false; $script:sessionTempDirectory=''; $script:sessionPasswordPath=''
    $script:serialDisconnectPending=$false; $script:nativeExitCleanupPending=$false
    $script:bmConnectAfterCoreReady=$false; $script:serialConnectCatAfterCoreReady=$false
    & $script:productionStartBridgeRun -BmStartDisconnected
    $prepareWatch=[System.Diagnostics.Stopwatch]::StartNew()
    while ($script:prepareAsync -and -not $script:prepareAsync.IsCompleted -and $prepareWatch.ElapsedMilliseconds -lt 5000) {
        Start-Sleep -Milliseconds 10
    }
    $prepareWatch.Stop()
    $uiPrepareCapturePath=Join-Path $script:preparedRunDirectory 'captured-parameters.json'
    Assert-RadioUi ($script:prepareAsync -and $script:prepareAsync.IsCompleted -and $script:preparationStarted -and
        $script:sessionTempDirectory -and [System.IO.Directory]::Exists($script:sessionTempDirectory)) `
        '真实 Start-BridgeRun 没有完成隔离的 BM 暂停预检参数准备。'
    [void]$script:preparePowerShell.EndInvoke($script:prepareAsync)
    Assert-RadioUi (-not $script:preparePowerShell.HadErrors -and [System.IO.File]::Exists($uiPrepareCapturePath) -and
        [System.IO.File]::Exists((Join-Path $script:preparedRunDirectory 'preparation.json'))) `
        'fake preparer 没有捕获真实 Start-BridgeRun 参数或生成合成记录。'
    $uiPrepareCapture=ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($uiPrepareCapturePath,[System.Text.Encoding]::UTF8))
    Assert-RadioUi ($uiPrepareCapture.paused -and -not $uiPrepareCapture.password_file_bound -and
        -not $uiPrepareCapture.require_password_file_bound -and
        @($uiPrepareCapture.bound_names | Where-Object { $_ -ceq 'BmStartDisconnected' }).Count -eq 1 -and
        -not [System.IO.File]::Exists((Join-Path $script:sessionTempDirectory 'bm-device-password.txt'))) `
        '空密码的真实 UI 准备链仍传入密码文件要求，或创建了空密码文件。'
    [void](Clear-UiSessionTemp)
    $script:preparePowerShell.Dispose(); $script:preparePowerShell=$null; $script:prepareAsync=$null
    $script:preparationStarted=$false; $script:sessionTempDirectory=''; $script:sessionPasswordPath=''

    # The visible serial button uses the paused-core lifecycle and a fake launcher stub.
    if ($script:radioCatOperationPowerShell) { [void](Complete-TestCatRunspace -TimeoutMs 5000) }
    $script:mainWindow=$script:testRootMainWindow
    $script:supervisor=$null; $script:stopTask=$null; $script:preparationStarted=$false
    $script:serialDisconnectPending=$false; $script:radioCatSessionShutdown=$false
    $script:radioCatManualDisconnect=$false; $script:radioCatSessionRequested=$false
    $script:serialConnectCatAfterCoreReady=$false; $script:bmConnectAfterCoreReady=$false
    $script:radioCatQueuedAction=$false; $script:radioCatPendingModeFrequencyRequest=$null; $script:radioModeApplyAfterStop=$null
    Assert-RadioUi (-not (Get-UiRadioCatSessionState).user_action_busy) `
        '伪设备 CAT worker 未在串口/BM 按钮生命周期测试前收尾。'
    $script:testStartBridgeRunCalls=0; $script:testLastBmStartDisconnected=$false
    $passwordBoxForLifecycle=Get-UiControl 'PasswordBox'
    $passwordBoxForLifecycle.Password=''
    $serialConnectButton=$script:mainWindow.FindName('SerialConnectButton')
    $serialConnectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialConnectButton)))
    Assert-RadioUi ($script:testStartBridgeRunCalls -eq 1 -and $script:testLastBmStartDisconnected -and
        $script:serialConnectCatAfterCoreReady -and -not $script:supervisor -and -not $script:radioCatOperationPowerShell) `
        '串口连接按钮没有用BM暂停参数启动核心并将CAT连接排到HRI就绪后。'
    $script:serialConnectCatAfterCoreReady=$false; $script:bmConnectAfterCoreReady=$false
    $script:testStartBridgeRunCalls=0; $script:testLastBmStartDisconnected=$false
    $blankPasswordBmResult=Connect-UiBmFromButton
    Assert-RadioUi (-not $blankPasswordBmResult -and $script:testStartBridgeRunCalls -eq 0 -and
        -not $script:bmConnectAfterCoreReady -and -not $script:serialConnectCatAfterCoreReady -and
        $script:testUiEvents.Count -gt 0 -and $script:testUiEvents[$script:testUiEvents.Count-1] -ceq 'BM 密码未填写，未发起连接。') `
        ('BM 密码为空时连接按钮没有显示字段错误并阻止启动或发送连接请求。 result={0}, calls={1}, bmAfter={2}, catAfter={3}, passwordEmpty={4}, footer=[{5}]' -f `
            $blankPasswordBmResult,$script:testStartBridgeRunCalls,$script:bmConnectAfterCoreReady,$script:serialConnectCatAfterCoreReady,
            [string]::IsNullOrWhiteSpace([string]$script:portableConfig.connection.password),[string](Get-UiControl 'FooterText').Text),
            (' action={0}, prep={1}, stopTask={2}, disconnect={3}' -f (Get-UiRadioCatSessionState).user_action_busy,$script:preparationStarted,[bool]$script:stopTask,$script:serialDisconnectPending)
    $passwordBoxForLifecycle.Password='ui-test-fixture-only'
    Assert-RadioUi (Connect-UiBmFromButton) '没有核心时，BM连接按钮没有复用串口准备流程。'
    Assert-RadioUi ($script:testStartBridgeRunCalls -eq 1 -and $script:testLastBmStartDisconnected -and
        $script:bmConnectAfterCoreReady -and $script:serialConnectCatAfterCoreReady -and -not $script:supervisor) `
        '无核心时的BM连接没有先准备HRI+CAT并将BM连接排到就绪后。'
    $script:bmConnectAfterCoreReady=$false; $script:serialConnectCatAfterCoreReady=$false

    # Fake v2 supervisor covers BM-only toggles, pending UDP teardown, and the serial-disconnect cancellation boundary.
    $bmSupervisor=New-TestBmSupervisor
    $script:supervisor=$bmSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:serialDisconnectPending=$false
    $script:controlConfirmed=$true; $script:controlDiagnostic=$false; $script:bmConnectionNativeCapability=$true
    $script:pendingControlRequests=@{}
    $script:bmConnectionRevision=[uint64]0; $script:bmConnectionPendingRequest=$null
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]0;transport_open=$false;resolving=$false;error='none';bm_state='stopped'
    }
    $script:latestStatus=[pscustomobject]@{ hri_ready=$true; hri_y_zero_ready=$true }
    $script:lastStatusUtc=[DateTime]::UtcNow
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $true) '已有HRI核心时BM独立连接请求没有送到fake supervisor。'
    $bmConnectCommand=$bmSupervisor.SentCommands[0]
    $bmConnectPayload=ConvertFrom-Json -InputObject ([string]$bmConnectCommand.parameters)
    $bmConnectProperties=@($bmConnectPayload.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-RadioUi ($bmConnectCommand.command -ceq 'bm.connection.set' -and $bmConnectPayload.enabled -and
        $bmConnectPayload.revision -eq 1 -and $bmConnectProperties.Count -eq 2 -and
        $bmConnectProperties -ccontains 'enabled' -and $bmConnectProperties -ccontains 'revision') `
        'BM独立连接命令没有只发送递增revision和enabled，不得携带密码、主站或配置。'
    $script:bmConnectionPendingRequest.ack_received=$true
    $script:bmConnectionRevision=[uint64]1
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$true;revision=[uint64]1;transport_open=$false}) `
        -BmState 'stopped' -Resolving $true -ErrorCode 'none' -Source ack)
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $false) 'BM解析期间用户关闭BM未能提交独立断开请求。'
    $bmDisconnectCommand=$bmSupervisor.SentCommands[1]
    $bmDisconnectPayload=ConvertFrom-Json -InputObject ([string]$bmDisconnectCommand.parameters)
    Assert-RadioUi ($bmDisconnectCommand.command -ceq 'bm.connection.set' -and -not $bmDisconnectPayload.enabled -and
        $bmDisconnectPayload.revision -eq 2 -and $bmSupervisor.StopCallCount -eq 0) `
        'BM断开按钮没有独立提交新revision，或误停了HRI核心。'
    $script:bmConnectionPendingRequest.ack_received=$true
    $script:bmConnectionRevision=[uint64]2
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]2;transport_open=$true}) `
        -BmState 'ready' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi ($script:bmConnectionSnapshot.requested_enabled -eq $false -and
        $script:bmConnectionSnapshot.transport_open -and $script:bmConnectionSnapshot.bm_state -ceq 'ready' -and
        $bmSupervisor.StopCallCount -eq 0) 'BM断开ACK被误当作UDP已关闭，或触发了核心停止。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]2;transport_open=$false}) `
        -BmState 'stopped' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi ($script:bmConnectionSnapshot.bm_state -ceq 'stopped' -and -not $script:bmConnectionSnapshot.transport_open -and
        -not $script:bmConnectionPendingRequest -and $bmSupervisor.StopCallCount -eq 0) '完整BM断开快照没有确认BM关闭并保留HRI核心。'

    $backoffSupervisor=New-TestBmSupervisor
    $script:supervisor=$backoffSupervisor; $script:controlConfirmed=$true; $script:controlDiagnostic=$false
    $script:bmConnectionNativeCapability=$true; $script:pendingControlRequests=@{}; $script:pendingStatusRequestId=''
    $script:bmConnectionRevision=[uint64]4
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$true;revision=[uint64]4;ack_received=$true}
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$true;revision=[uint64]4;transport_open=$true;resolving=$false;error='none';bm_state='backoff'
    }
    $script:latestStatus=[pscustomobject]@{hri_ready=$true;hri_y_zero_ready=$true}
    $script:lastStatusUtc=[DateTime]::UtcNow; $script:bmStatusNextRequestUtc=[DateTime]::MinValue
    for ($backoffTick=0; $backoffTick -lt 510; $backoffTick++) {
        [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
            requested_enabled=$true;revision=[uint64]4;transport_open=$true
        }) -BmState 'backoff' -Resolving $false -ErrorCode 'none' -Source status_jsonl)
        Update-UiBmConnectionPoll
    }
    Assert-RadioUi ($backoffSupervisor.SentCommands.Count -eq 0 -and $backoffSupervisor.StopCallCount -eq 0 -and
        $script:bmConnectionPendingRequest -and [bool]$script:bmConnectionPendingRequest.ack_received) `
        'BM backoff期间新鲜JSONL持续报告状态时，超过510次timer tick仍不应发送额外status或停止HRI。'
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $false) 'BM backoff期间仍不能提交独立断开操作。'
    $backoffDisconnect=ConvertFrom-Json -InputObject ([string]$backoffSupervisor.SentCommands[0].parameters)
    Assert-RadioUi ($backoffSupervisor.SentCommands.Count -eq 1 -and -not $backoffDisconnect.enabled -and
        $backoffDisconnect.revision -eq 5 -and $backoffSupervisor.StopCallCount -eq 0) `
        '长期BM backoff后仍应能独立断开BM，且不能停止HRI核心。'

    $recoverySupervisor=New-TestBmSupervisor
    $script:supervisor=$recoverySupervisor; $script:controlConfirmed=$true; $script:controlDiagnostic=$false
    $script:bmConnectionNativeCapability=$true; $script:pendingControlRequests=@{}; $script:pendingStatusRequestId=''
    $script:bmConnectionRevision=[uint64]10
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$true;revision=[uint64]10;ack_received=$true}
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$true;revision=[uint64]10;transport_open=$true;resolving=$false;error='none';bm_state='backoff'
    }
    $script:bmStatusRecoveryCount=0; $script:bmStatusRecoveryStartedUtc=[DateTime]::MinValue
    $script:bmStatusNextRequestUtc=[DateTime]::MinValue; $script:lastBmSnapshotUtc=[DateTime]::MinValue
    for ($missingJsonlTick=0; $missingJsonlTick -lt 520; $missingJsonlTick++) {
        $script:lastBmSnapshotUtc=[DateTime]::MinValue
        $script:bmStatusNextRequestUtc=[DateTime]::MinValue
        $script:pendingStatusRequestId=''
        $beforeRecoverySend=$recoverySupervisor.SentCommands.Count
        Update-UiBmConnectionPoll
        if ($recoverySupervisor.SentCommands.Count -gt $beforeRecoverySend) {
            $script:pendingStatusRequestId=''
            [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
                requested_enabled=$true;revision=[uint64]10;transport_open=$true
            }) -BmState 'backoff' -Resolving $false -ErrorCode 'none' -Source control_status)
        }
    }
    Assert-RadioUi ($recoverySupervisor.SentCommands.Count -eq 3 -and $script:bmStatusRecoveryCount -eq 3 -and
        $script:bmConnectionPendingRequest -and $recoverySupervisor.StopCallCount -eq 0) `
        ('JSONL缺失时，成功的control_status回包不得反复重置总恢复额度；520个tick只允许3次status请求。 sent={0}, recovery={1}, pending={2}, stop={3}' -f `
            $recoverySupervisor.SentCommands.Count,$script:bmStatusRecoveryCount,[bool]$script:bmConnectionPendingRequest,$recoverySupervisor.StopCallCount)
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $false) '恢复额度耗尽后，用户仍不能反向断开BM。'
    $recoveryDisconnect=ConvertFrom-Json -InputObject ([string]$recoverySupervisor.SentCommands[$recoverySupervisor.SentCommands.Count-1].parameters)
    Assert-RadioUi ($recoverySupervisor.SentCommands.Count -eq 4 -and -not $recoveryDisconnect.enabled -and
        $recoveryDisconnect.revision -eq 11 -and $script:bmStatusRecoveryCount -eq 0 -and
        $recoverySupervisor.StopCallCount -eq 0) `
        '新的BM断开请求没有建立新的有界恢复周期，或误停了HRI核心。'

    $script:supervisor=$bmSupervisor; $script:pendingControlRequests=@{}
    $script:bmConnectionPendingRequest=$null; $script:lastBmSnapshotUtc=[DateTime]::UtcNow
    $script:bmConnectionRevision=[uint64]3
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$true;revision=[uint64]3;transport_open=$true;resolving=$false;error='none';bm_state='ready'
    }
    $script:radioCatSessionShutdown=$false; $script:radioCatSessionRequested=$true
    $script:radioCatSessionConnected=$true; $script:radioCatPollingActive=$true; $script:radioCatSessionState='connected'
    $script:radioCatManualDisconnect=$false; $script:radioCatSessionGeneration=[int]$script:radioCatSessionGeneration + 1
    $script:radioCatPendingModeFrequencyRequest=[pscustomobject]@{operation='setMode';mode='C4FM-DN'}
    $script:radioModeApplyAfterStop=[pscustomobject]@{operation='setMode';mode='C4FM-DN'}
    $script:radioCatQueuedAction=[pscustomobject]@{operation='setPower';power_watts=6}
    $setModeLogBeforeSerialDisconnect=([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $env:WIREX_R116_UI_CAT_DELAY='query'; $env:WIREX_R116_UI_CAT_DELAY_MS='700'
    Assert-RadioUi ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell) `
        '组合串口断开测试没有先启动fake CAT query。'
    $serialDisconnectGeneration=[int]$script:radioCatSessionGeneration
    $serialDisconnectButton=$script:mainWindow.FindName('SerialDisconnectButton')
    $serialDisconnectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialDisconnectButton)))
    $serialBmDisableCommand=$bmSupervisor.SentCommands[$bmSupervisor.SentCommands.Count - 1]
    $serialBmDisable=ConvertFrom-Json -InputObject ([string]$serialBmDisableCommand.parameters)
    Assert-RadioUi ($script:serialDisconnectPending -and -not $script:radioCatManualDisconnect -and
        $script:radioCatSessionRequested -and $script:radioCatOperationPowerShell -and
        -not $serialBmDisable.enabled -and $bmSupervisor.StopCallCount -eq 0) `
        ('串口断开没有先请求BM关闭并等待真实关闭，同时暂存CAT清理和核心停止。 pending={0}, catRequested={1}, worker={2}, manual={3}, stop={4}, sent={5}, last={6}' -f `
            [bool]$script:serialDisconnectPending,[bool]$script:radioCatSessionRequested,[bool]$script:radioCatOperationPowerShell,
            [bool]$script:radioCatManualDisconnect,$bmSupervisor.StopCallCount,$bmSupervisor.SentCommands.Count,
            $(if($bmSupervisor.SentCommands.Count){$bmSupervisor.SentCommands[$bmSupervisor.SentCommands.Count-1].parameters}else{'<none>'}))
    $script:bmConnectionPendingRequest.ack_received=$true
    $script:bmConnectionRevision=[uint64]4
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]4;transport_open=$true}) `
        -BmState 'ready' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi ($script:radioCatSessionRequested -and $bmSupervisor.StopCallCount -eq 0) `
        'Native accepted disconnect ACK 尚未关闭UDP时，CAT与HRI被提前断开。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]4;transport_open=$false}) `
        -BmState 'stopped' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi (-not $script:radioCatSessionRequested -and $script:radioCatOperationPowerShell -and
        $null -eq $script:radioCatPendingModeFrequencyRequest -and $null -eq $script:radioModeApplyAfterStop -and
        $null -eq $script:radioCatQueuedAction -and $bmSupervisor.StopCallCount -eq 0 -and
        [int]$script:radioCatSessionGeneration -gt $serialDisconnectGeneration) `
        'BM确认关闭后串口收尾没有撤销MAIN等待事务/功率动作，或在CAT worker清理前停止了HRI。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    [void](Complete-UiSerialDisconnectAfterBm)
    Assert-RadioUi ($bmSupervisor.StopCallCount -eq 1 -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeLogBeforeSerialDisconnect -and
        -not $script:radioCatSessionRequested -and -not $script:radioCatOperationPowerShell) `
        'CAT worker清理后串口断开没有只停止HRI一次，或迟到事务恢复了MAIN写入。'
    [void]$bmSupervisor.StopSource.TrySetResult(0)
    $bmSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false

    # An uncached status can report a completed disconnect together with a stale failure code.
    $closedErrorSupervisor=New-TestBmSupervisor
    $script:supervisor=$closedErrorSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:controlConfirmed=$true; $script:bmConnectionNativeCapability=$true
    $script:pendingControlRequests=@{}; $script:pendingStatusRequestId=''
    $script:bmConnectionRevision=[uint64]0; $script:bmConnectionPendingRequest=$null
    $script:bmConnectionSnapshot=$null
    $script:serialDisconnectPending=$false; $script:serialDisconnectCoreStopIssued=$false
    $script:serialDisconnectCatStopRequested=$false
    $script:radioCatSessionShutdown=$false; $script:radioCatManualDisconnect=$false
    $script:radioCatSessionRequested=$false; $script:radioCatSessionConnected=$false
    $script:radioCatPollingActive=$false; $script:radioCatOperationPowerShell=$null
    $script:radioCatSessionState='disconnected'
    $serialDisconnectButton=$script:mainWindow.FindName('SerialDisconnectButton')
    $serialDisconnectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialDisconnectButton)))
    Assert-RadioUi ($script:serialDisconnectPending -and -not $script:bmConnectionSnapshot -and
        $closedErrorSupervisor.SentCommands.Count -eq 1 -and
        $closedErrorSupervisor.SentCommands[0].command -ceq 'status' -and
        $closedErrorSupervisor.StopCallCount -eq 0) `
        '没有BM缓存状态时，串口断开没有等待Native状态快照。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]0;transport_open=$false
    }) -BmState 'stopped' -Resolving $false -ErrorCode 'password_required' -Source status)
    Assert-RadioUi ($script:bmConnectionSnapshot.error -ceq 'password_required' -and
        $script:serialDisconnectPending -and $script:serialDisconnectCatStopRequested -and
        $script:serialDisconnectCoreStopIssued -and $closedErrorSupervisor.StopCallCount -eq 1 -and
        -not $script:radioCatSessionRequested) `
        'BM已关闭快照携带旧密码错误时，UI仍阻止CAT和HRI核心收尾。'
    [void]$closedErrorSupervisor.StopSource.TrySetResult(0)
    $closedErrorSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false

    $mediaSupervisor=New-TestBmSupervisor
    $script:supervisor=$mediaSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:serialDisconnectPending=$true; $script:serialDisconnectCoreStopIssued=$false
    $script:serialDisconnectCatStopRequested=$false; $script:serialDisconnectDeadlineUtc=[DateTime]::UtcNow.AddSeconds(15)
    $script:bmConnectionRevision=[uint64]5
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$false;revision=[uint64]5;ack_received=$true}
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]5;transport_open=$true;resolving=$false;error='none';bm_state='ready'
    }
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]5;transport_open=$true
    }) -BmState 'ready' -Resolving $false -ErrorCode 'media_cleanup_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:bmConnectionPendingRequest -and
        -not $script:serialDisconnectCoreStopIssued -and $mediaSupervisor.StopCallCount -eq 0) `
        'BM媒体清理超时且UDP仍打开时，串口断开意图未等待Native后续关包。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]5;transport_open=$false
    }) -BmState 'stopped' -Resolving $false -ErrorCode 'media_cleanup_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:serialDisconnectCoreStopIssued -and
        -not $script:bmConnectionPendingRequest -and $mediaSupervisor.StopCallCount -eq 1) `
        'BM媒体错误保留到UDP关闭后，串口断开仍未继续停止HRI。'
    [void]$mediaSupervisor.StopSource.TrySetResult(0); $mediaSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false
    $script:serialDisconnectDeadlineUtc=[DateTime]::MinValue

    $resolverSupervisor=New-TestBmSupervisor
    $script:supervisor=$resolverSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:serialDisconnectPending=$true; $script:serialDisconnectCoreStopIssued=$false
    $script:serialDisconnectCatStopRequested=$false; $script:serialDisconnectDeadlineUtc=[DateTime]::UtcNow.AddSeconds(15)
    $script:bmConnectionRevision=[uint64]6
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$false;revision=[uint64]6;ack_received=$true}
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]6;transport_open=$false
    }) -BmState 'stopped' -Resolving $true -ErrorCode 'resolver_cancel_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:bmConnectionPendingRequest -and
        -not $script:serialDisconnectCoreStopIssued -and $resolverSupervisor.StopCallCount -eq 0) `
        'DNS取消清理超时但仍 resolving 时，串口断开意图未等待Native关闭解析器。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]6;transport_open=$false
    }) -BmState 'stopped' -Resolving $false -ErrorCode 'resolver_cancel_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:serialDisconnectCoreStopIssued -and
        -not $script:bmConnectionPendingRequest -and $resolverSupervisor.StopCallCount -eq 1) `
        'DNS取消错误保留到解析结束后，串口断开仍未继续停止HRI。'
    [void]$resolverSupervisor.StopSource.TrySetResult(0); $resolverSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false
    $script:serialDisconnectDeadlineUtc=[DateTime]::MinValue

    $deadlineSupervisor=New-TestBmSupervisor
    $script:supervisor=$deadlineSupervisor; $script:serialDisconnectPending=$true
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false
    $script:serialDisconnectDeadlineUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]7;transport_open=$false;resolving=$true;error='resolver_cancel_timeout';bm_state='stopped'
    }
    $script:bmConnectionPendingRequest=$null; $script:bmConnectionRevision=[uint64]7
    $script:bmConnectionNativeCapability=$true; $script:controlConfirmed=$true
    $script:pendingStatusRequestId=''; $script:bmStatusNextRequestUtc=[DateTime]::MinValue
    Update-UiBmConnectionPoll
    Assert-RadioUi (-not $script:serialDisconnectPending -and $deadlineSupervisor.StopCallCount -eq 0 -and
        $script:testUiEvents.Count -gt 0 -and $script:testUiEvents[$script:testUiEvents.Count-1] -ceq '串口断开等待超时；HRI 和 CAT 仍保持连接') `
        ('断串口等待超过期限时没有失败退出并如实显示当前解析/连接状态。 pending={0}, stop={1}, deadline={2}, footer=[{3}]' -f `
            [bool]$script:serialDisconnectPending,$deadlineSupervisor.StopCallCount,$script:serialDisconnectDeadlineUtc,
            [string]$script:mainWindow.FindName('FooterText').Text)
    $deadlineSupervisor.HasExited=$true; $script:supervisor=$null; $script:stopTask=$null

    Write-Output ('通过：四轮fake CAT轮询/写入及复核、COM和音频选值保存、无副作用安全失败、串口/BM暂停连接路线、旧错误与异步收尾快照下双口关闭及等待超时、50条呼号模型去重/分页/离页身份回写、CAT取消和退出清理均已验证。断言数：{0}' -f $script:radioUiAssertionCount)
} finally {
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_MODULE_PATH -ErrorAction SilentlyContinue
    if ($script:radioCatOperationPowerShell) {
        try {
            if ($script:radioCatOperationAsync -and -not $script:radioCatOperationAsync.IsCompleted) {
                $stop = $script:radioCatOperationPowerShell.BeginStop($null,$null)
                if ($stop.AsyncWaitHandle.WaitOne(3000)) { $script:radioCatOperationPowerShell.EndStop($stop) }
            }
        } catch { }
        try { $script:radioCatOperationPowerShell.Dispose() } catch { }
    }
    if ($script:settingsWindow) { try { $script:settingsWindow.Close() } catch { } }
    if ($script:mainWindow -is [System.Windows.Window]) { try { $script:mainWindow.Close() } catch { } }
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $testRootFullPath = [System.IO.Path]::GetFullPath([string]$script:testRoot)
    $testRootName = [System.IO.Path]::GetFileName($testRootFullPath)
    $testRootIsOwned = $testRootFullPath.StartsWith($temporaryRoot,[System.StringComparison]::OrdinalIgnoreCase) -and
        $testRootName -match '^wirex-r116-ui-cat-[0-9a-f]{32}$'
    if ($testRootIsOwned -and [System.IO.Directory]::Exists($testRootFullPath)) {
        Remove-Item -LiteralPath $testRootFullPath -Recurse -Force
    } elseif ([System.IO.Directory]::Exists($testRootFullPath)) {
        Write-Warning ('测试目录未删除，因为路径不符合本脚本创建的临时目录格式：' + $testRootFullPath)
    }
}
