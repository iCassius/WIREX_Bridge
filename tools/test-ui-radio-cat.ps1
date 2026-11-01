[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

function Assert-RadioUi {
    param([bool]$Condition,[string]$Message)
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
        $powerWattsObserved = if ($path -ceq 'FieldHead') { 5 } else { 25 }
        $identityValue = if ($env:WIREX_R116_UI_CAT_BAD_ID -eq '1') { '9999' } else { '0840' }
        $observed = [ordered]@{
            radio_id = [pscustomobject]@{ value=$identityValue; source=$source; updated_at_utc=$now }
            auto_information_enabled = [pscustomobject]@{ value=$false; source=$source; updated_at_utc=$now }
            tx_state = [pscustomobject]@{ value='TX0'; source=$source; updated_at_utc=$now }
            main_frequency_hz = [pscustomobject]@{ value=[long]123456; source=$source; updated_at_utc=$now }
            sub_frequency_hz = [pscustomobject]@{ value=[long]234567; source=$source; updated_at_utc=$now }
            main_mode = [pscustomobject]@{ value=[pscustomobject]@{ side='Main'; side_code='0'; mode_code='4'; mode='FM' }; source=$source; updated_at_utc=$now }
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
function Start-BridgeRun { $script:testStartBridgeRunCalls++ }
function Set-UiControl { param([string]$Name,[object]$Value) }

function New-TestRadioSupervisor {
    $source = New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
    $supervisor = [pscustomobject]@{ HasExited=$false; StopSource=$source; DisposeCount=0; StopCallCount=0; Disposed=$false }
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name StopAsync -Value { param([int]$TimeoutMs) $this.StopCallCount++; return $this.StopSource.Task } | Out-Null
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++; $this.Disposed=$true } | Out-Null
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
function Complete-TestBridgeStop {
    $results = @(Complete-BridgeStop)
    if ($results.Count -eq 0) { return $false }
    return [bool]$results[$results.Count - 1]
}
function Wait-TestRadioCatLog {
    param([Parameter(Mandatory=$true)][string]$Pattern,[int]$TimeoutMs=2000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            if ([System.IO.File]::ReadAllText($script:radioCatLogPath) -match $Pattern) { $watch.Stop(); return $true }
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
            $count = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),$Pattern)).Count
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

    # A regular poll must keep the visible controls and current readout steady.
    # The three write buttons are explicitly disabled while the query worker runs.
    $modeControl = Get-SettingsControl 'CatMainModeBox'
    $frequencyControl = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $slider = Get-SettingsControl 'CatPowerSlider'
    $observedPanel = Get-SettingsControl 'CatObservedPanel'
    $operatingPanel = Get-SettingsControl 'CatOperatingPanel'
    $powerButton = Get-SettingsControl 'ApplyCatPowerButton'
    $modeControl.Add_IsEnabledChanged({ $script:testModeEnableChanges++ })
    $frequencyControl.Add_IsEnabledChanged({ $script:testFrequencyEnableChanges++ })
    $slider.Add_IsEnabledChanged({ $script:testSliderEnableChanges++ })
    $slider.Add_ValueChanged({ $script:testSliderValueChanges++ })
    $script:testModeEnableChanges = 0
    $script:testFrequencyEnableChanges = 0
    $script:testSliderEnableChanges = 0
    $script:testSliderValueChanges = 0
    $slider.Value = 6
    $script:testSliderValueChanges = 0
    $readoutBeforePoll = @(
        [string](Get-SettingsControl 'CatObservedMainModeText').Text,
        [string](Get-SettingsControl 'CatObservedFrequencyText').Text,
        [string](Get-SettingsControl 'CatObservedPowerText').Text
    ) -join '|'
    $modeSelectionBeforePoll = [string]$modeControl.SelectedItem.Tag
    $frequencyTextBeforePoll = [string]$frequencyControl.Text
    $editorVisibilityBeforePoll = @(
        [string]$modeControl.Visibility,[string]$frequencyControl.Visibility,[string]$slider.Visibility
    ) -join '|'
    $sliderValueBeforePoll = [double]$slider.Value
    $sliderMaximumBeforePoll = [double]$slider.Maximum
    $script:radioCatPollingActive = $true
    $script:radioCatPollingConnectionKey = Get-UiRadioCatConnectionKey
    $script:radioCatPollNextUtc = [DateTime]::MinValue
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '400'
    [void](Invoke-UiRadioCatPollTick -Force)
    Assert-RadioUi ($script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'query') '周期 CAT query 没有保持为唯一在途操作。'
    Assert-RadioUi ($observedPanel.Visibility -eq [System.Windows.Visibility]::Visible -and
        $operatingPanel.Visibility -eq [System.Windows.Visibility]::Visible) '周期 query 期间 CAT 控制面板或观测面板被隐藏。'
    Assert-RadioUi ($modeControl.IsEnabled -and $frequencyControl.IsEnabled -and $slider.IsEnabled) '周期 query 期间 MAIN 输入和功率滑块闪烁式禁用。'
    Assert-RadioUi (-not (Get-SettingsControl 'ReadRadioButton').IsEnabled -and
        -not (Get-SettingsControl 'ApplyCatModeButton').IsEnabled -and
        -not (Get-SettingsControl 'ApplyCatFrequencyButton').IsEnabled -and -not $powerButton.IsEnabled) `
        'query worker 在途时，读取按钮和三种 CAT 写入按钮必须明确禁用。'
    $writeCountBeforePollBusy = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'WRITE\|setPower')).Count
    $writeDuringQueryRejected = $false
    try { Start-UiRadioCatOperation -Operation setPower -PowerWatts 6 }
    catch { $writeDuringQueryRejected = $_.Exception.Message -match '另一项 CAT-1 操作' }
    Assert-RadioUi ($writeDuringQueryRejected -and
        ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'WRITE\|setPower')).Count -eq $writeCountBeforePollBusy) `
        'query worker 在途时，程序入口仍允许 CAT 写入。'
    for ($stableTick = 0; $stableTick -lt 4; $stableTick++) {
        [void](Update-UiRadioCatControls)
        [void](Update-UiRadioCatObservationDisplay)
    }
    Assert-RadioUi ($observedPanel.Visibility -eq [System.Windows.Visibility]::Visible -and
        $operatingPanel.Visibility -eq [System.Windows.Visibility]::Visible -and
        (@([string](Get-SettingsControl 'CatObservedMainModeText').Text,[string](Get-SettingsControl 'CatObservedFrequencyText').Text,
            [string](Get-SettingsControl 'CatObservedPowerText').Text) -join '|') -ceq $readoutBeforePoll -and
        [string]$modeControl.SelectedItem.Tag -ceq $modeSelectionBeforePoll -and
        [string]$frequencyControl.Text -ceq $frequencyTextBeforePoll -and
        (@([string]$modeControl.Visibility,[string]$frequencyControl.Visibility,[string]$slider.Visibility) -join '|') -ceq $editorVisibilityBeforePoll -and
        [double]$slider.Value -eq $sliderValueBeforePoll -and [double]$slider.Maximum -eq $sliderMaximumBeforePoll -and
        $script:testModeEnableChanges -eq 0 -and $script:testFrequencyEnableChanges -eq 0 -and
        $script:testSliderEnableChanges -eq 0 -and $script:testSliderValueChanges -eq 0) `
        '重复 dispatcher 更新期间观测文字、滑块范围或滑块值发生变化。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and
        [int]$slider.Value -eq 6 -and [int]$script:radioCatEditDraft.power -eq 6 -and $powerButton.IsEnabled -and
        [string]$modeControl.SelectedItem.Tag -ceq $modeSelectionBeforePoll -and [string]$frequencyControl.Text -ceq $frequencyTextBeforePoll) `
        '周期 query 完成后没有刷新确认状态，或覆盖用户保留的功率草稿。'
    Set-UiRadioCatDraft -Field power -Value $null
    [void](Update-UiRadioCatControls)

    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ callsign=''; gateway_id=''; source_id=''; master=''; master_port=''; color_code=1 }; tx_target=[pscustomobject]@{ destination_id=91; kind='group'; slot=2 }; rx_policy=$null; transmit_enabled=$true }
    $initialSaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedPreference = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ($initialSaveSucceeded -and [int]$savedPreference.devices.desired_power_watts -eq 40) `
        ('保存设置没有成功，或将超范围目标功率静默改成滑块值。 saved={0}, power={1}, path={2}' -f $initialSaveSucceeded,$savedPreference.devices.desired_power_watts,$script:portableConfigPath)
    Assert-RadioUi ([object]::ReferenceEquals($script:mainWindow,$script:testRootMainWindow) -and -not $script:testRootMainWindow.Closed) `
        '保存统一配置不应关闭主窗口或改变其所有权。'

    # A real slider edit creates a write draft without changing the saved preference.
    $slider.Value = 9
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 9 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 40 -and -not $script:radioCatPowerNeedsUserChoice) `
        'MainWindow 功率滑块明确改到 9 W 后应形成独立草稿并保留 40 W 偏好。'
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
    Assert-RadioUi ([int]$script:radioControlPreferences.desired_power_watts -eq 40 -and
        $null -eq $script:radioCatEditDraft.power -and -not $script:radioCatPowerNeedsUserChoice -and
        -not (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '重开后 FieldHead 首读应保留偏好、没有功率草稿且禁止无草稿写入。'

    # Exercise the actual bound WPF ValueChanged and Apply Button handlers after explicit selection.
    $slider.Value = 6
    Assert-RadioUi ($null -ne $script:radioCatEditDraft.power -and [int]$script:radioCatEditDraft.power -eq 6 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 40 -and -not $script:radioCatPowerNeedsUserChoice) '真实 WPF 滑块操作没有创建 6 W 草稿或改写了已保存偏好。'
    $setPowerButton = Get-SettingsControl 'ApplyCatPowerButton'
    Assert-RadioUi $setPowerButton.IsEnabled '用户选择 6 W 后应用功率按钮应启用。'
    $script:lastStatusUtc = [DateTime]::UtcNow
    $clickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$setPowerButton)
    $setPowerButton.RaiseEvent($clickArgs)
    Assert-RadioUi (Wait-TestRadioCatLog -Pattern 'ARGS\|setPower\|.*PowerWatts=6' -TimeoutMs 1000) `
        ('WPF 应用按钮没有把用户明确选择的 6 W 传给 CAT worker。 status={0}, result={1}, button={2}, operation={3}' -f `
            [string]$script:radioCatLastOperationStatus,[string]$script:radioCatResult.status,[bool]$setPowerButton.IsEnabled,
            [string]$script:radioCatOperationKind)
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed') `
        ('范围内的 WPF 功率应用没有通过读回流程确认。 status={0}, operation={1}, result={2}, cancelled={3}, cleanup={4}' -f `
            [string]$script:radioCatLastOperationStatus,[string]$script:radioCatOperationKind,
            [string]$script:radioCatResult.status,[bool]$script:radioCatOperationCancelled,
            [string]$script:radioCatResult.cleanup_status)

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
    $savedPowerWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'ARGS\|setPower')).Count
    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ callsign=''; gateway_id=''; source_id=''; master=''; master_port=''; color_code=1 }; tx_target=[pscustomobject]@{ destination_id=91; kind='group'; slot=2 }; rx_policy=$null; transmit_enabled=$true }
    $dirtySaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedDirtyPreference = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ([int]$savedDirtyPreference.devices.desired_power_watts -eq 25 -and
        ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'ARGS\|setPower')).Count -eq $savedPowerWriteCount -and
        $dirtySaveSucceeded) ('FieldHead 保存未成功或把未应用草稿写进偏好/发起CAT操作：saved={0}, args={1}/{2}, pref={3}, draft={4}, value={5}, needsChoice={6}' -f $savedDirtyPreference.devices.desired_power_watts,([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'ARGS\|setPower')).Count,$savedPowerWriteCount,$script:radioControlPreferences.desired_power_watts,$script:radioCatEditDraft.power,$slider.Value,$script:radioCatPowerNeedsUserChoice)
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
    $logBeforeStop = [System.IO.File]::ReadAllText($script:radioCatLogPath)
    Assert-RadioUi ($logBeforeStop -notmatch 'BEGIN\|setMode') 'StopAsync 尚未完成就启动了 CAT 模式设置。'
    Assert-RadioUi (-not (Complete-TestBridgeStop)) 'StopAsync 未完成时被 UI 当成完成。'
    Assert-RadioUi ([System.IO.File]::ReadAllText($script:radioCatLogPath) -notmatch 'BEGIN\|setMode') '等待 StopAsync 期间发起 CAT 模式设置。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $script:stopTask = $testSupervisor.StopSource.Task
    $script:supervisor = $testSupervisor
    $script:mainWindow = New-TestMainWindow
    Assert-RadioUi (Complete-TestBridgeStop) '停止失败测试没有进入 UI 停止失败分支。'
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and [System.IO.File]::ReadAllText($script:radioCatLogPath) -notmatch 'BEGIN\|setMode' -and
        $testSupervisor.StopCallCount -eq 1 -and $testSupervisor.DisposeCount -eq 0 -and -not $testSupervisor.Disposed) 'StopAsync 已完成但核心未退出时仍写入模式或错误释放 supervisor。'
    Restore-TestMainWindow

    $frequencyBox = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $frequencyBox.Text = '145.200000'
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    Invoke-UiRadioModeOrFrequencyApply -Operation setFrequency
    Assert-RadioUi ($script:radioModeApplyAfterStop -and $script:radioModeApplyAfterStop.frequency_hz -eq 145200000) 'FA 请求没有冻结成明确的 MAIN Hz 值。'
    Assert-RadioUi ([System.IO.File]::ReadAllText($script:radioCatLogPath) -notmatch 'BEGIN\|setFrequency') 'Stop 未完成时发出了 FA 设置。'
    Assert-RadioUi (-not (Complete-TestBridgeStop)) 'FA 请求在 StopAsync 完成前结束了等待。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $script:stopTask = $testSupervisor.StopSource.Task
    $script:mainWindow = New-TestMainWindow
    Assert-RadioUi (Complete-TestBridgeStop) 'FA Stop 失败没有进入停止未完成路径。'
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and $testSupervisor.DisposeCount -eq 0 -and
        [System.IO.File]::ReadAllText($script:radioCatLogPath) -notmatch 'BEGIN\|setFrequency') '停止未退出时仍执行 FA 或提前释放 supervisor。'
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
    $setModeCountBeforeSuccess = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setMode')).Count
    $queryCountBeforeModeRead = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|query')).Count
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '确认进程退出后没有完成断开流程。'
    Assert-RadioUi ($testSupervisor.Disposed -and $testSupervisor.DisposeCount -eq 1 -and -not $script:supervisor) 'CAT 请求启动前没有先释放已退出的 supervisor。'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeModeRead + 1) -TimeoutMs 1500) 'HRI 退出后没有启动 CAT 状态查询。'
    $afterModeStopLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
    Assert-RadioUi (([regex]::Matches($afterModeStopLog,'BEGIN\|query')).Count -eq ($queryCountBeforeModeRead + 1) -and
        ([regex]::Matches($afterModeStopLog,'BEGIN\|setMode')).Count -eq $setModeCountBeforeSuccess) 'HRI 退出后必须先查询 CAT 状态，确认前不能直接写入模式。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $modeStartedAfterQuery = Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($setModeCountBeforeSuccess + 1) -TimeoutMs 1500
    Assert-RadioUi $modeStartedAfterQuery ('CAT 查询确认后没有启动唯一冻结的 C4FM-DN MAIN 请求。 catStatus={0}, operation={1}, result={2}, pending={3}, observedKey={4}, currentKey={5}' -f `
        $script:radioCatLastOperationStatus,$script:radioCatOperationKind, $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
        [bool]$script:radioCatPendingModeFrequencyRequest,$script:radioCatObservedConnectionKey,(Get-UiRadioCatConnectionKey))
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setMode' -and $script:radioCatLastOperationStatus -ceq 'confirmed') 'CAT 查询未确认，但自动启动了 MAIN 模式设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $afterModeLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
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
    $setFrequencyCountBeforeSuccess = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setFrequency')).Count
    $queryCountBeforeFrequencyRead = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|query')).Count
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) 'MAIN 频率请求没有完成核心停止。'
    Assert-RadioUi ($testSupervisor.Disposed -and -not $script:supervisor) 'MAIN 频率 CAT 请求启动前没有释放已退出的 supervisor。'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeFrequencyRead + 1) -TimeoutMs 1500) 'HRI 退出后没有启动 CAT 状态查询。'
    $afterFrequencyStopLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
    Assert-RadioUi (([regex]::Matches($afterFrequencyStopLog,'BEGIN\|query')).Count -eq ($queryCountBeforeFrequencyRead + 1) -and
        ([regex]::Matches($afterFrequencyStopLog,'BEGIN\|setFrequency')).Count -eq $setFrequencyCountBeforeSuccess) 'HRI 退出后必须先查询 CAT 状态，确认前不能直接写入频率。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setFrequency' -MinimumCount ($setFrequencyCountBeforeSuccess + 1) -TimeoutMs 1500) 'CAT 查询确认后没有启动唯一冻结的 MAIN FA 请求。'
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setFrequency' -and $script:radioCatLastOperationStatus -ceq 'confirmed') 'CAT 查询未确认，但自动启动了 MAIN 频率设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $afterFrequencyLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
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
    $queryCountBeforeClose = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|query')).Count
    Invoke-UiRadioModeOrFrequencyApply -Operation setMode
    $pendingModeBeforeClose = $script:radioModeApplyAfterStop
    $setModeCountBeforeClose = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setMode')).Count
    Cancel-SettingsWindow
    Assert-RadioUi ($null -eq $script:settingsWindow -and [object]::ReferenceEquals($script:radioModeApplyAfterStop,$pendingModeBeforeClose)) '关闭路由弹窗没有保留由主窗发起、等待核心停止的 MAIN 模式请求。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '关闭设置窗后没有完成等待中的核心停止。'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeClose + 1) -TimeoutMs 1500) '保留的 MAIN 模式请求没有先启动 CAT 查询。'
    $afterCloseStopLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
    Assert-RadioUi ($testSupervisor.Disposed -and ([regex]::Matches($afterCloseStopLog,'BEGIN\|setMode')).Count -eq $setModeCountBeforeClose -and
        $null -eq $script:radioModeApplyAfterStop -and $script:radioCatPendingModeFrequencyRequest) '关闭路由弹窗后，CAT 查询前的待执行 MAIN 模式意图丢失或过早写入。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($setModeCountBeforeClose + 1) -TimeoutMs 1500) '关闭路由弹窗后，确认的 CAT 查询没有继续执行保留的 MAIN 模式请求。'
    Assert-RadioUi ($script:radioCatOperationKind -ceq 'setMode' -and $null -eq $script:radioCatPendingModeFrequencyRequest) 'MAIN 模式请求没有在 CAT query 确认后进入唯一写入阶段。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $afterCloseModeLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and
        $afterCloseModeLog -match ('ARGS\|setMode\|Port=COM11\|Role=CAT-1\|HRI=COM5\|Baud=38400\|StopBits=Two\|Side=Main\|Mode={0}' -f [regex]::Escape([string]$pendingModeBeforeClose.mode)) -and
        $afterCloseModeLog -match 'CLEANUP\|setMode') '保留的 MAIN 模式请求未按冻结参数完成 CAT 写入和清理。'

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
    $setModeCountBeforeStopExit = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setMode')).Count
    $script:mainWindow = New-TestMainWindow
    Request-StopAndExit
    Assert-RadioUi ($null -eq $script:radioModeApplyAfterStop -and $script:closingAfterStop) '停止并退出没有撤销待执行模式请求。'
    [void]$testSupervisor.StopSource.TrySetResult(0)
    $testSupervisor.HasExited = $true
    $script:stopTask = $testSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '停止并退出没有完成核心停止。'
    Assert-RadioUi ($script:mainWindow.Closed -and $testSupervisor.Disposed -and ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setMode')).Count -eq $setModeCountBeforeStopExit) '停止并退出后仍应用了 CAT 待办或没有在核心退出后关闭主窗。'
    Restore-TestMainWindow

    # Closing the routing modal must not cancel a CAT worker owned by MainWindow.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '350'
    $queryCountBeforeCancel = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|query')).Count
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
    $cancelLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
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
    $queryCountBeforeDeadline = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|query')).Count
    $observedBeforeDeadline = $script:radioCatObserved
    Start-UiRadioCatOperation -Operation query
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeDeadline + 1) -TimeoutMs 1500) '期限测试没有启动 fake query worker。'
    Start-Sleep -Milliseconds 100
    $script:radioCatOperationStartedUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Assert-RadioUi (-not (Complete-UiRadioCatOperation) -and $script:radioCatOperationCancelled -and $script:radioCatOperationStopAsync) 'CAT 期限到达后没有要求停止 fake worker。'
    [void](Complete-TestCatRunspace -TimeoutMs 2800)
    $deadlineLog = [System.IO.File]::ReadAllText($script:radioCatLogPath)
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
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $slider.Value = 6
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 6 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and
        (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled) '过期测试应先通过真实滑块建立合法 6 W 草稿并启用功率应用，同时保留已保存偏好。'
    $env:WIREX_R116_UI_CAT_DELAY = 'setPower'
    $writeCountBeforeStale = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'WRITE\|setPower')).Count
    $beginCountBeforeStale = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setPower')).Count
    $observedBeforeStale = $script:radioCatObserved
    $stalePowerButton = Get-SettingsControl 'ApplyCatPowerButton'
    $staleClickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$stalePowerButton)
    $stalePowerButton.RaiseEvent($staleClickArgs)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setPower' -MinimumCount ($beginCountBeforeStale + 1) -TimeoutMs 1000) '状态过期测试没有启动真实 WPF Apply 按钮创建的 fake CAT worker。'
    Start-Sleep -Milliseconds 100
    Assert-RadioUi (([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'BEGIN\|setPower')).Count -gt $beginCountBeforeStale) '状态过期测试没有观察到新启动的功率操作。'
    $script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Set-StaleDisplay
    Assert-RadioUi ($script:radioCatOperationCancelled -and $null -ne $script:radioCatOperationStopAsync) '状态过期后，timer没有取消在途功率设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 2800)
    $writesAfterStale = ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'WRITE\|setPower')).Count
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and $writesAfterStale -eq $writeCountBeforeStale -and
        $script:radioCatLastOperationStatus -ceq 'unknown' -and $null -eq $script:radioCatResult -and
        [object]::ReferenceEquals($script:radioCatObserved,$observedBeforeStale)) '核心状态过期后仍发生新写入、UI接受晚结果、runspace未释放，或丢弃了此前仍有效的 CAT 读值。'
    Start-Sleep -Milliseconds 100
    [void](Complete-UiRadioCatOperation)
    Assert-RadioUi ($null -eq $script:radioCatResult -and [object]::ReferenceEquals($script:radioCatObserved,$observedBeforeStale) -and
        ([regex]::Matches([System.IO.File]::ReadAllText($script:radioCatLogPath),'WRITE\|setPower')).Count -eq $writeCountBeforeStale) '取消后的 CAT 晚结果覆盖了未知状态或继续写入。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue

    Write-Output '通过：周期 CAT query 不切换编辑控件启用态、不隐藏观测面板、不改变读值或滑块草稿；query 在途时读取和写入按钮禁用且单worker拒绝写入；R118功率范围、拒绝读回、重连清理和fresh-query授权回归均由真实 WPF 控件与fake CAT worker执行。'
} finally {
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue
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
